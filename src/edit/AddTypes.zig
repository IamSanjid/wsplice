//! Appends function types to the type section; creates the section when absent.
//!
//!     type     ::= vec(functype)
//!     functype ::= 0x60 vec(valtype) vec(valtype)
//!
//! New types are written from shared `types.Signature` values: either typed values a plan
//! constructs or encoded values borrowed from an existing `types.Entry`. The input's entries are
//! copied verbatim, padded LEBs included. A type this plan adds is named `.appended = n`, and
//! `AddFunctions` resolves that after the input's type count.
const std = @import("std");
const Io = std.Io;

const Module = @import("../Module.zig");
const Options = @import("../Options.zig");
const Diagnostics = @import("../Diagnostics.zig");
const EncodeError = @import("../errors.zig").EncodeError;
const Plan = @import("../Plan.zig");
const types = @import("../payload/types.zig");

/// One function type to add. Its slices are borrowed until `emit` returns.
pub const Signature = types.Signature;

/// One signature per added type, in added-ordinal order.
signatures: []const Signature = &.{},

const AddTypes = @This();

pub fn encode(
    self: *const AddTypes,
    module: *const Module,
    plan: *const Plan,
    writer: *Io.Writer,
    options: Options,
) EncodeError!void {
    _ = plan; // types are not imported, so a type index never shifts
    const old = try readOld(module, options);

    const count_new = std.math.cast(u32, self.signatures.len) orelse return error.Overflow;
    const count_total = std.math.add(u32, old.count, count_new) catch return error.Overflow;
    try writer.writeLeb128(count_total); // canonical count, even if the old one was padded
    try writer.writeAll(old.entries); // old types are copied verbatim, not re-encoded
    for (self.signatures) |*signature| try writeSignature(writer, signature);
}

fn writeSignature(writer: *Io.Writer, signature: *const Signature) EncodeError!void {
    try writer.writeByte(types.form_func);
    try signature.params.write(writer);
    try signature.results.write(writer);
}

const Old = struct { count: u32 = 0, entries: []const u8 = &.{} };

/// Reads the whole old section, so a broken one is rejected instead of copied.
fn readOld(module: *const Module, options: Options) EncodeError!Old {
    const payload = module.payloadCursor(.type) orelse return .{};
    var iterator = types.Iterator.init(payload) catch |err| return Diagnostics.fail(
        options.diag,
        err,
        .{ .section = .type, .offset = payload.pos },
    );
    while (true) {
        const entry = iterator.next() catch |err| return Diagnostics.fail(options.diag, err, .{
            .section = .type,
            .offset = iterator.cursor.pos,
        });
        if (entry == null) break;
    }
    return .{ .count = iterator.count, .entries = iterator.entries.slice(module.bytes) };
}
