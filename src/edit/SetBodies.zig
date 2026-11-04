//! Sets function bodies: replaces the body of an existing function, or appends one for a function
//! the plan adds.
//!
//! The code section has one entry per defined function. An entry this edit does not name is copied
//! verbatim, padded LEBs included; a named one gets a canonical size prefix, its locals follow the
//! body's `Body.Locals` mode, and its instructions are replaced, rewritten from the input, or
//! copied raw. Local indices are checked when the owning function's type is known. Nothing checks
//! that the bodies match the functions the plan adds, or that an instruction type-checks: that is
//! validation, and `wasm-validate` does it.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Body = @import("../payload/Body.zig");
const Counts = @import("../payload/Counts.zig");
const Module = @import("../Module.zig");
const Options = @import("../Options.zig");
const Diagnostics = @import("../Diagnostics.zig");
const EncodeError = @import("../errors.zig").EncodeError;
const Plan = @import("../Plan.zig");
const Query = @import("../Query.zig");
const index = @import("../index.zig");
const code = @import("../payload/code.zig");

/// A replacement body for an existing function.
pub const Replacement = struct {
    /// A function index in the input module. An imported function has no body, so an index below
    /// the imported function count is refused.
    function: u32,
    body: Body,
};

/// Replace the body of these functions, in any order.
existing: []const Replacement = &.{},
/// Append one body per function the plan adds: `added[n]` is the body of function `.appended = n`.
added: []const Body = &.{},

const SetBodies = @This();

pub fn encode(
    self: *const SetBodies,
    module: *const Module,
    plan: *const Plan,
    writer: *Io.Writer,
    options: Options,
) EncodeError!void {
    const counts = try Counts.of(module, options);
    const old = try readOld(module, options);
    const imported = counts.importedCount(.function);
    try check(self, imported, old.count, options);
    const query = Query.initWithCounts(module, counts);
    const function_layout = index.Layout.of(&counts, .function, &plan.added_imports);

    const count_new = std.math.cast(u32, self.added.len) orelse return error.Overflow;
    const count_total = std.math.add(u32, old.count, count_new) catch return error.Overflow;
    try writer.writeLeb128(count_total); // canonical count, even if the old one was padded

    if (module.payloadCursor(.code)) |payload| {
        var iterator = try code.Iterator.init(payload); // readOld already walked it
        var ordinal: u32 = 0;
        while (try iterator.next()) |entry| : (ordinal += 1) {
            assert(ordinal < old.count);
            if (self.bodyFor(ordinal + imported)) |body| {
                const owner = try ownerForInput(
                    &query,
                    ordinal + imported,
                    function_layout,
                    options,
                );
                try writeBody(writer, body, &counts, plan, owner, .{
                    .locals = entry.locals,
                    .body = entry.body,
                }, options);
            } else {
                try writer.writeAll(entry.bytes); // copied verbatim, not re-encoded
            }
        }
        assert(ordinal == old.count);
    }
    for (self.added, 0..) |*body, added_ordinal| {
        const owner = try ownerForAdded(
            &query,
            plan,
            @intCast(added_ordinal),
            function_layout,
            options,
        );
        try writeBody(writer, body, &counts, plan, owner, null, options);
    }
}

const Old = struct { count: u32 = 0 };

/// Reads the whole old section, so a broken one is rejected instead of copied.
fn readOld(module: *const Module, options: Options) EncodeError!Old {
    const payload = module.payloadCursor(.code) orelse return .{};
    var iterator = code.Iterator.init(payload) catch |err|
        return Diagnostics.fail(options.diag, err, .{ .section = .code, .offset = payload.pos });
    while (true) {
        const entry = iterator.next() catch |err| return Diagnostics.fail(options.diag, err, .{
            .section = .code,
            .offset = iterator.cursor.pos,
        });
        if (entry == null) break;
    }
    return .{ .count = iterator.count };
}

/// Checks every existing entry before the first byte is written. `limit` is how many function
/// indices the input's code section can cover: with a consistent input it equals the function
/// space's size, and with an inconsistent one it is the number that is really there.
fn check(self: *const SetBodies, imported: u32, old_count: u32, options: Options) EncodeError!void {
    const limit = std.math.add(u32, imported, old_count) catch return error.Overflow;
    for (self.existing, 0..) |*entry, i| {
        if (entry.function < imported) {
            return Diagnostics.fail(options.diag, error.ImportedFunction, .{ .section = .code });
        }
        if (entry.function >= limit) {
            return Diagnostics.fail(options.diag, error.IndexOutOfRange, .{
                .section = .code,
                .detail = .{ .out_of_range = .{
                    .space = .function,
                    .value = entry.function,
                    .limit = limit,
                } },
            });
        }
        for (self.existing[0..i]) |*earlier| {
            if (earlier.function == entry.function) {
                return Diagnostics.fail(options.diag, error.DuplicateBody, .{ .section = .code });
            }
        }
    }
}

/// The body the plan gives this function, if it gives one. `function` is an input index.
fn bodyFor(self: *const SetBodies, function: u32) ?*const Body {
    for (self.existing) |*entry| {
        if (entry.function == function) return &entry.body;
    }
    return null;
}

/// The owning function and parameter count for an input function's replacement body.
fn ownerForInput(
    query: *const Query,
    function: u32,
    layout: index.Layout,
    options: Options,
) EncodeError!Body.Owner {
    const final = (index.Function{ .input = function }).resolve(layout) catch |err|
        return Diagnostics.fail(options.diag, err, .{ .section = .code });
    const parameters = if (try query.functionSignature(function)) |signature|
        try signature.params.count()
    else
        null;
    return .{ .emitted_function = final, .parameter_count = parameters };
}

/// The owning function and parameter count for an added function's body, when the plan supplied
/// the type context. A body without context is still emitted; its local indices are not checked.
fn ownerForAdded(
    query: *const Query,
    plan: *const Plan,
    ordinal: u32,
    layout: index.Layout,
    options: Options,
) EncodeError!Body.Owner {
    const final = (index.Function{ .appended = ordinal }).resolve(layout) catch |err|
        return Diagnostics.fail(options.diag, err, .{ .section = .code });
    return .{
        .emitted_function = final,
        .parameter_count = try parametersForAdded(query, plan, ordinal),
    };
}

fn parametersForAdded(
    query: *const Query,
    plan: *const Plan,
    ordinal: u32,
) EncodeError!?u32 {
    if (ordinal >= plan.added_functions.len) return null;
    switch (plan.added_functions[ordinal]) {
        .input => |type_index| {
            const signature = (try query.typeSignature(type_index)) orelse return null;
            return try signature.params.count();
        },
        .appended => |type_ordinal| {
            if (type_ordinal >= plan.added_types.len) return null;
            const signature = plan.added_types[type_ordinal];
            return try signature.params.count();
        },
        .added_import => return null,
    }
}

/// Writes one code entry: the body's size, then the body. `input` is the input body it replaces.
fn writeBody(
    writer: *Io.Writer,
    body: *const Body,
    counts: *const Counts,
    plan: *const Plan,
    owner: ?Body.Owner,
    input: ?Body.Input,
    options: Options,
) EncodeError!void {
    try writer.writeLeb128(try body.encodedLen(counts, plan, owner, input, options));
    try body.encodeWith(counts, plan, owner, input, writer, options);
}
