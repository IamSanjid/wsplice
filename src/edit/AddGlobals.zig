//! Append globals to the global section; creates the section if the module has none.
//!
//! A global is a global type and a constant expression. The new ones are re-encoded from typed
//! values, the old ones are copied byte for byte, so a padded LEB inside an old initializer
//! survives unchanged while the count becomes canonical.
//!
//! Nothing here checks that an initializer produces its declared type, or that a `global.get`
//! smuggled through `Expr.raw` names an immutable import: that is validation, and `wasm-validate`
//! does it.
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

/// One global to add. Its initializer borrows whatever bytes it refers to, so it must stay alive
/// until `emit` returns.
pub const Global = struct {
    /// The declared global type: a value type and a mutability.
    global_type: globals.Type,
    init: const_expr.Expr,
};

/// Caller-owned. The slice, and everything the initializers borrow, must stay alive until `emit`
/// returns.
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
