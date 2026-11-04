//! Reader for the function section payload: one type index per defined function.
//!
//!     function ::= vec(typeidx)
//!
//! The section only names types. A defined function's body is in the code section at the same
//! ordinal, and its parameters and results are in the type its index names.
const std = @import("std");
const assert = std.debug.assert;

const Cursor = @import("../Cursor.zig");
const Span = @import("../section.zig").Span;
const errors = @import("../errors.zig");
const PayloadError = errors.PayloadError;
const fromCursor = errors.fromCursor;

pub const Iterator = struct {
    cursor: Cursor, // a private copy, positioned at the next type index
    entries: Span, // everything after the count LEB, for verbatim copying
    count: u32,
    yielded: u32 = 0,

    /// The smallest entry is a one-byte type index.
    const entry_len_min = 1;

    /// `payload` is the section's payload window (e.g. from `Module.payloadCursor`). Not modified.
    pub fn init(payload: Cursor) PayloadError!Iterator {
        var cursor = payload;
        const count = cursor.readUleb(u32) catch |err| return fromCursor(err);
        // A tiny payload cannot hold a huge count; checking up front bounds the work.
        if (count > cursor.remaining()) return error.Truncated;
        return .{
            .cursor = cursor,
            .entries = .{ .start = cursor.pos, .end = cursor.end },
            .count = count,
        };
    }

    /// The next type index, or null after `count` entries (and only if the payload ends there).
    /// A failed call leaves the iterator where it was.
    pub fn next(self: *Iterator) PayloadError!?u32 {
        assert(self.yielded <= self.count);
        const cursor = &self.cursor;
        if (self.yielded == self.count) {
            if (!cursor.atEnd()) return error.TrailingBytes;
            return null;
        }

        const start = cursor.pos;
        errdefer cursor.pos = start; // a failed call leaves the iterator where it was

        const type_index = cursor.readUleb(u32) catch |err| return fromCursor(err);

        self.yielded += 1;
        assert(cursor.pos > start);
        return type_index;
    }
};
