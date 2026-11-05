//! Global section codec: reads entries, each a global type plus a constant expression, and writes
//! one global type.
//!
//! Initializers are measured, not decoded, because unchanged ones are copied as bytes. Initializer
//! typing is `wasm-validate`'s job.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Cursor = @import("../Cursor.zig");
const spec = @import("../spec.zig");
const Span = @import("../section.zig").Span;
const valtype = @import("valtype.zig");
const const_expr = @import("const_expr.zig");
const errors = @import("../errors.zig");
const EncodeError = errors.EncodeError;
const PayloadError = errors.PayloadError;
const fromCursor = errors.fromCursor;

/// A global's type: a value type and a mutability.
pub const Type = struct {
    valtype: valtype.ValueType,
    mutability: spec.Mutability,
};

pub const Entry = struct {
    global_type: Type,

    /// The initializer's instructions without the terminating `end`; `const_expr.Expr.raw` copies
    /// them unchanged.
    instructions: []const u8,
};

pub const Iterator = struct {
    cursor: Cursor, // a private copy, positioned at the next entry
    entries: Span, // everything after the count LEB, for verbatim copying
    count: u32,
    yielded: u32 = 0,

    /// The smallest possible entry: a value type, a mutability, and the `end` of an initializer.
    const entry_len_min = 3;

    /// `payload` is the section's payload window (e.g. from `Module.payloadCursor`). Not modified.
    pub fn init(payload: Cursor) PayloadError!Iterator {
        var cursor = payload;
        const count = cursor.readUleb(u32) catch |err| return fromCursor(err);
        // A tiny payload cannot hold a huge count; checking up front bounds the work.
        if (count > @divFloor(cursor.remaining(), entry_len_min)) return error.Truncated;
        return .{
            .cursor = cursor,
            .entries = .{ .start = cursor.pos, .end = cursor.end },
            .count = count,
        };
    }

    /// The next entry, or null after `count` entries (and only if the payload ends exactly there).
    /// A failed call leaves the iterator where it was.
    pub fn next(self: *Iterator) PayloadError!?Entry {
        assert(self.yielded <= self.count);
        const cursor = &self.cursor;
        if (self.yielded == self.count) {
            if (!cursor.atEnd()) return error.TrailingBytes;
            return null;
        }

        const start = cursor.pos;
        errdefer cursor.pos = start; // a failed call leaves the iterator where it was

        const value_type = try valtype.read(cursor);
        const mutability = try readMutability(cursor);
        const instructions = try const_expr.take(cursor);

        self.yielded += 1;
        assert(cursor.pos > start);
        return .{
            .global_type = .{
                .valtype = value_type,
                .mutability = mutability,
            },
            .instructions = instructions,
        };
    }
};

/// Writes one global type: the value type, then the mutability byte.
pub fn writeType(global_type: Type, writer: *Io.Writer) EncodeError!void {
    try valtype.write(global_type.valtype, writer);
    try writer.writeByte(@backingInt(global_type.mutability));
}

/// `mut` is one byte with exactly two legal values; anything else would change what follows, so it
/// is refused.
fn readMutability(cursor: *Cursor) PayloadError!spec.Mutability {
    const byte = cursor.readByte() catch |err| return fromCursor(err);
    return std.enums.fromInt(spec.Mutability, byte) orelse error.InvalidValue;
}
