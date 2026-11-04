//! Appends function declarations to the function section; creates the section when absent.
//!
//!     function ::= vec(typeidx)
//!
//! The new declarations are symbolic `index.Type`s, resolved against the input's type count.
//! `.appended` type ordinals are not checked: the type section that would define them arrives with
//! the type encoder. A function's body is the code section's business (`SetBodies`), so a plan that
//! adds a function writes two edits, one per section.
const std = @import("std");
const Io = std.Io;

const Counts = @import("../payload/Counts.zig");
const functions = @import("../payload/functions.zig");
const index = @import("../index.zig");
const Module = @import("../Module.zig");
const Options = @import("../Options.zig");
const Diagnostics = @import("../Diagnostics.zig");
const EncodeError = @import("../errors.zig").EncodeError;
const Plan = @import("../Plan.zig");

/// One type index per function to add, in appended-ordinal order.
types: []const index.Type = &.{},

const AddFunctions = @This();

pub fn encode(
    self: *const AddFunctions,
    module: *const Module,
    plan: *const Plan,
    writer: *Io.Writer,
    options: Options,
) EncodeError!void {
    _ = plan; // declarations name types, and type indices never shift
    // First, so a broken import section is reported before anything else.
    const counts = try Counts.of(module, options);
    const old = try readOld(module, options);

    const count_new = std.math.cast(u32, self.types.len) orelse return error.Overflow;
    const count_total = std.math.add(u32, old.count, count_new) catch return error.Overflow;
    try writer.writeLeb128(count_total); // canonical count, even if the old one was padded
    try writer.writeAll(old.entries); // old declarations are copied verbatim, not re-encoded
    for (self.types) |function_type| {
        try writer.writeLeb128(try checkedIndex(function_type, &counts, options));
    }
}

const Old = struct { count: u32 = 0, entries: []const u8 = &.{} };

/// Reads the whole old section, so a broken one is rejected instead of copied.
fn readOld(module: *const Module, options: Options) EncodeError!Old {
    const payload = module.payloadCursor(.function) orelse return .{};
    var iterator = functions.Iterator.init(payload) catch |err| return Diagnostics.fail(
        options.diag,
        err,
        .{ .section = .function, .offset = payload.pos },
    );
    while (true) {
        const entry = iterator.next() catch |err| return Diagnostics.fail(options.diag, err, .{
            .section = .function,
            .offset = iterator.cursor.pos,
        });
        if (entry == null) break;
    }
    return .{ .count = iterator.count, .entries = iterator.entries.slice(module.bytes) };
}

/// The number a type index resolves to, or the out-of-range diagnostic. Only `.input` is
/// checked: an `.appended` or `.added_import` ordinal is the plan's to hand out, and the type
/// section is not read here.
fn checkedIndex(
    function_type: index.Type,
    counts: *const Counts,
    options: Options,
) EncodeError!u32 {
    const layout = index.Layout.types(counts);
    switch (function_type) {
        .input => |used| {
            if (used >= layout.input_total) {
                return Diagnostics.fail(options.diag, error.IndexOutOfRange, .{
                    .section = .function,
                    .detail = .{
                        .out_of_range = .{
                            .space = .type,
                            .value = used,
                            .limit = layout.input_total,
                        },
                    },
                });
            }
        },
        .appended, .added_import => {},
    }
    return function_type.resolve(layout);
}
