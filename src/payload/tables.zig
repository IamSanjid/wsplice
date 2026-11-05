//! Reads and writes the table section: one table type (`reftype limits`) per table.
//!
//! Reference types use the one-byte shorthand; prefixed forms are refused. `Entry.bytes` preserves
//! the exact encoding for entries an edit copies unchanged.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Cursor = @import("../Cursor.zig");
const spec = @import("../spec.zig");
const errors = @import("../errors.zig");
const EncodeError = errors.EncodeError;
const PayloadError = errors.PayloadError;
const fromCursor = errors.fromCursor;
const limits = @import("limits.zig");
const valtype = @import("valtype.zig");

/// One table type: an element reference type and its limits.
pub const Type = struct {
    reftype: spec.AbstractHeapType,
    limits: spec.Limits,
};

/// One table type and the exact bytes it was encoded as.
pub const Entry = struct {
    table_type: Type,
    bytes: []const u8, // borrows the module: this entry's own encoding
};

pub const Iterator = struct {
    cursor: Cursor, // a private copy, positioned at the next table type
    count: u32,
    yielded: u32 = 0,

    /// The smallest possible entry: a reference type byte, a flags byte and a one-byte minimum.
    const entry_len_min = 3;

    /// `payload` is the section's payload window (e.g. from `Module.payloadCursor`). Not modified.
    pub fn init(payload: Cursor) PayloadError!Iterator {
        var cursor = payload;
        const count = cursor.readUleb(u32) catch |err| return fromCursor(err);
        // A tiny payload cannot hold a huge count; checking up front bounds the work.
        if (count > @divFloor(cursor.remaining(), entry_len_min)) return error.Truncated;
        return .{ .cursor = cursor, .count = count };
    }

    /// The next table type, or null after `count` entries; trailing bytes are an error.
    pub fn next(self: *Iterator) PayloadError!?Entry {
        assert(self.yielded <= self.count);
        if (self.yielded == self.count) {
            if (!self.cursor.atEnd()) return error.TrailingBytes;
            return null;
        }

        const start = self.cursor.pos;
        errdefer self.cursor.pos = start; // a failed call leaves the iterator where it was

        const reftype = try valtype.readReference(&self.cursor);
        const table_limits = try limits.read(&self.cursor);

        self.yielded += 1;
        assert(self.cursor.pos > start);
        return .{
            .table_type = .{ .reftype = reftype, .limits = table_limits },
            .bytes = self.cursor.bytes[start..self.cursor.pos],
        };
    }
};

/// Writes one table type. `limits.write` can fail for caller data; the edit diagnoses those.
pub fn write(table_type: Type, writer: *Io.Writer) EncodeError!void {
    try writer.writeByte(@backingInt(table_type.reftype));
    try limits.write(table_type.limits, writer);
}
