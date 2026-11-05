//! Reads the code section: one self-delimiting `size:u32 func` entry per defined function, where
//! `func` is `locals:vec(locals) expr:expr`.
//!
//! Only the frame is read: the locals vector and the expression's bytes. An unchanged entry can be
//! copied without decoding its instructions.
const std = @import("std");
const assert = std.debug.assert;

const Cursor = @import("../Cursor.zig");
const valtype = @import("valtype.zig");
const errors = @import("../errors.zig");
const PayloadError = errors.PayloadError;
const fromCursor = errors.fromCursor;

pub const Entry = struct {
    /// The whole entry, size prefix included: copying it reproduces the entry.
    bytes: []const u8,
    /// The locals vector as encoded: the run count, then each run's count and type.
    locals: []const u8,
    /// The expression: everything after the locals, the terminating `end` included.
    body: Cursor,
};

pub const Iterator = struct {
    cursor: Cursor, // a private copy, positioned at the next entry's size prefix
    count: u32,
    yielded: u32 = 0,

    /// The smallest possible entry: a size LEB, a locals count and an `end`.
    const entry_len_min = 3;

    /// `payload` is the section's payload window (e.g. from `Module.payloadCursor`). Not modified.
    pub fn init(payload: Cursor) PayloadError!Iterator {
        var cursor = payload;
        const count = cursor.readUleb(u32) catch |err| return fromCursor(err);
        // A tiny payload cannot hold a huge count; checking up front bounds the work.
        if (count > @divFloor(cursor.remaining(), entry_len_min)) return error.Truncated;
        return .{ .cursor = cursor, .count = count };
    }

    /// The next entry, or null after `count` entries; trailing bytes are an error. A failed call
    /// leaves the iterator where it was.
    pub fn next(self: *Iterator) PayloadError!?Entry {
        assert(self.yielded <= self.count);
        const cursor = &self.cursor;
        if (self.yielded == self.count) {
            if (!cursor.atEnd()) return error.TrailingBytes;
            return null;
        }

        const start = cursor.pos;
        errdefer cursor.pos = start; // a failed call leaves the iterator where it was

        const size = cursor.readUleb(u32) catch |err| return fromCursor(err);
        var body = cursor.sub(size) catch |err| return fromCursor(err);
        const locals = try takeLocals(&body);

        self.yielded += 1;
        assert(cursor.pos > start);
        return .{ .bytes = cursor.bytes[start..cursor.pos], .locals = locals, .body = body };
    }
};

/// Reads the locals vector and leaves `cursor` at the first instruction. A type `valtype` refuses
/// is refused here too: the run's type is read, not skipped.
fn takeLocals(cursor: *Cursor) PayloadError![]const u8 {
    const start = cursor.pos;
    const runs = try readU32(cursor);
    // A run is a count LEB and a value type byte: at least two bytes.
    if (runs > @divFloor(cursor.remaining(), 2)) return error.Truncated;
    var i: u32 = 0;
    while (i < runs) : (i += 1) {
        _ = try readU32(cursor); // the run's count
        _ = try valtype.read(cursor); // a type the rest of the library can represent
    }
    return cursor.bytes[start..cursor.pos];
}

fn readU32(cursor: *Cursor) PayloadError!u32 {
    return cursor.readUleb(u32) catch |err| return fromCursor(err);
}
