//! Appends globals, creating the global section when absent.
//!
//! New globals are re-encoded; old entries are copied byte for byte, padded LEBs included. Nothing
//! checks that an initializer produces its declared type: `wasm-validate` does.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Module = @import("../Module.zig");
const Options = @import("../Options.zig");
const Diagnostics = @import("../Diagnostics.zig");
const EncodeError = @import("../errors.zig").EncodeError;
const Plan = @import("../Plan.zig");
const globals = @import("../payload/globals.zig");
const const_expr = @import("../payload/const_expr.zig");

/// One global to add. The initializer borrows its bytes until `emit`.
pub const Global = struct {
    global_type: globals.Type,
    init: const_expr.Expr,
};

/// Caller-owned; the slice and everything the initializers borrow must outlive `emit`.
entries: []const Global,

const AddGlobals = @This();

pub fn encode(
    self: *const AddGlobals,
    module: *const Module,
    plan: *const Plan,
    writer: *Io.Writer,
    options: Options,
) EncodeError!void {
    _ = plan; // no initializer variant carries an index; raw bytes are opaque
    const old = try readOld(module, options);
    const count_new = std.math.cast(u32, self.entries.len) orelse return error.Overflow;
    const count_total = std.math.add(u32, old.count, count_new) catch return error.Overflow;

    try writer.writeLeb128(count_total); // canonical count, even if the old one was padded
    try writer.writeAll(old.entries); // old globals are copied verbatim, not re-encoded
    for (self.entries) |*entry| {
        try globals.writeType(entry.global_type, writer);
        try entry.init.encode(writer);
    }
}

const Old = struct { count: u32 = 0, entries: []const u8 = &.{} };

/// Reads the whole old section, so a broken one is rejected instead of copied.
fn readOld(module: *const Module, options: Options) EncodeError!Old {
    const payload = module.payloadCursor(.global) orelse return .{};
    var iterator = globals.Iterator.init(payload) catch |err|
        return Diagnostics.fail(options.diag, err, .{ .section = .global, .offset = payload.pos });

    while (true) {
        const entry = iterator.next() catch |err| return Diagnostics.fail(options.diag, err, .{
            .section = .global,
            .offset = iterator.cursor.pos,
        });
        if (entry == null) break;
    }
    assert(iterator.yielded == iterator.count); // only a null result ends the loop
    return .{ .count = iterator.count, .entries = iterator.entries.slice(module.bytes) };
}
