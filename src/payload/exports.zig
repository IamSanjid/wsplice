//! Reads the export section: each entry is a name, external kind, and index.
const std = @import("std");
const assert = std.debug.assert;

const Cursor = @import("../Cursor.zig");
const spec = @import("../spec.zig");
const Span = @import("../section.zig").Span;
const errors = @import("../errors.zig");
const PayloadError = errors.PayloadError;
const fromCursor = errors.fromCursor;

pub const Entry = struct {
    name: []const u8, // raw bytes, borrowed from the module; not checked for UTF-8
    kind: spec.ExternalKind,
    index: u32,
};

pub const Iterator = struct {
    cursor: Cursor, // a private copy, positioned at the next entry
    entries: Span, // everything after the count LEB, for verbatim copying
    count: u32,
    yielded: u32 = 0,

    /// An entry needs at least an empty name (1 byte), a kind (1) and an index (1).
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
    pub fn next(self: *Iterator) PayloadError!?Entry {
        assert(self.yielded <= self.count);
        const cursor = &self.cursor;
        if (self.yielded == self.count) {
            if (!cursor.atEnd()) return error.TrailingBytes;
            return null;
        }

        const start = cursor.pos;
        errdefer cursor.pos = start; // a failed call leaves the iterator where it was

        const name_len = cursor.readUleb(u32) catch |err| return fromCursor(err);
        const name = cursor.take(name_len) catch |err| return fromCursor(err);
        const kind_byte = cursor.readByte() catch |err| return fromCursor(err);
        const kind = std.enums.fromInt(spec.ExternalKind, kind_byte) orelse
            return error.InvalidKind;
        const index = cursor.readUleb(u32) catch |err| return fromCursor(err);

        self.yielded += 1;
        assert(cursor.pos > start);
        return .{ .name = name, .kind = kind, .index = index };
    }
};

const testing = std.testing;
const Io = std.Io;
const Module = @import("../Module.zig");

/// One entry with a one-byte name length and index (both < 128): name_len, name, kind, index.
fn entry(comptime name: []const u8, comptime kind: u8, comptime index: u8) [name.len + 3]u8 {
    if (!@import("builtin").is_test) {
        @compileError("Should be used only in tests.");
    }
    comptime assert(name.len < 0x80);
    comptime assert(index < 0x80);
    return [_]u8{@intCast(name.len)} ++ name[0..name.len].* ++ [_]u8{ kind, index };
}

fn expectNext(it: *Iterator, name: []const u8, kind: spec.ExternalKind, index: u32) !void {
    if (!@import("builtin").is_test) {
        @compileError("Should be used only in tests.");
    }
    const e = (try it.next()).?;
    try testing.expectEqualStrings(name, e.name);
    try testing.expectEqual(kind, e.kind);
    try testing.expectEqual(index, e.index);
}

fn iterOver(payload: []const u8) !Iterator {
    if (!@import("builtin").is_test) {
        @compileError("Should be used only in tests.");
    }
    return Iterator.init(try Cursor.init(payload));
}

test "exports reader: a padded count LEB moves the entries span" {
    // Count 2, encoded in three bytes.
    const payload = [_]u8{ 0x82, 0x80, 0x00 } ++ entry("a", 0, 0) ++ entry("b", 3, 1);
    var it = try iterOver(&payload);
    try testing.expectEqual(@as(u32, 2), it.count);
    try testing.expectEqual(@as(u32, 3), it.entries.start);
    try testing.expectEqual(@as(u32, payload.len), it.entries.end);
    try expectNext(&it, "a", .function, 0);
    try expectNext(&it, "b", .global, 1);
    try testing.expectEqual(null, try it.next());
}

test "exports reader: zero entries" {
    var it = try iterOver(&.{0});
    try testing.expectEqual(@as(u32, 0), it.count);
    try testing.expectEqual(null, try it.next());
}

test "exports reader: every kind parses, tag included" {
    const payload = [_]u8{5} ++
        entry("f", 0, 0) ++
        entry("t", 1, 1) ++
        entry("m", 2, 2) ++
        entry("g", 3, 3) ++
        entry("e", 4, 4);
    var it = try iterOver(&payload);
    try expectNext(&it, "f", .function, 0);
    try expectNext(&it, "t", .table, 1);
    try expectNext(&it, "m", .memory, 2);
    try expectNext(&it, "g", .global, 3);
    try expectNext(&it, "e", .tag, 4);
    try testing.expectEqual(null, try it.next());
}

test "exports reader: names are raw bytes (empty, NUL, non-UTF-8)" {
    const payload = [_]u8{3} ++ entry("", 0, 0) ++ entry("a\x00b", 2, 5) ++ entry("\xFF\xFE", 3, 9);
    var it = try iterOver(&payload);
    try expectNext(&it, "", .function, 0);
    try expectNext(&it, "a\x00b", .memory, 5);
    try expectNext(&it, "\xFF\xFE", .global, 9); // the reader does not judge UTF-8
    try testing.expectEqual(null, try it.next());
}

test "exports reader: a 128-byte name and a large index use multi-byte LEBs" {
    var name: [128]u8 = undefined;
    @memset(&name, 'n');
    var w: Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();
    try w.writer.writeByte(1); // count
    try w.writer.writeLeb128(@as(u32, 128)); // name length: 0x80 0x01
    try w.writer.writeAll(&name);
    try w.writer.writeByte(0); // function
    try w.writer.writeLeb128(@as(u32, 300)); // index: two bytes

    var it = try iterOver(w.written());
    try expectNext(&it, &name, .function, 300);
    try testing.expectEqual(null, try it.next());
}

test "exports reader: errors at init" {
    try testing.expectError(error.Truncated, iterOver(&.{})); // empty payload

    // A 6-byte count.
    const six_byte_count = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 };
    try testing.expectError(error.MalformedLeb, iterOver(&six_byte_count));

    // Count 5, room for one entry.
    try testing.expectError(error.Truncated, iterOver(&.{ 5, 0, 0, 0 }));

    // Count u32 max, no data.
    const count_u32_max = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
    try testing.expectError(error.Truncated, iterOver(&count_u32_max));
}

test "exports reader: errors while iterating" {
    // Truncated name, kind and index: the count passes the up-front check, but the entry is cut
    // short.
    {
        var it = try iterOver(&.{ 1, 5, 'a', 'b' });
        try testing.expectError(error.Truncated, it.next());
    }
    {
        var it = try iterOver(&.{ 1, 2, 'a', 'b' });
        try testing.expectError(error.Truncated, it.next());
    }
    {
        var it = try iterOver(&.{ 1, 1, 'a', 0 });
        try testing.expectError(error.Truncated, it.next());
    }
    // a six-byte index LEB
    {
        var it = try iterOver(&.{ 1, 0, 0, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 });
        try testing.expectError(error.MalformedLeb, it.next());
    }
    // unknown kinds
    inline for ([_]u8{ 5, 6, 0x80, 0xFF }) |kind| {
        const payload = [_]u8{1} ++ entry("a", kind, 0);
        var it = try iterOver(&payload);
        try testing.expectError(error.InvalidKind, it.next());
    }
}

test "exports reader: trailing bytes" {
    const after_entry = [_]u8{1} ++ entry("a", 0, 0) ++ [_]u8{0xFF};
    var it = try iterOver(&after_entry);
    try expectNext(&it, "a", .function, 0); // the entry itself is fine
    try testing.expectError(error.TrailingBytes, it.next());

    var empty = try iterOver(&.{ 0, 0xFF }); // count 0 with data after it
    try testing.expectError(error.TrailingBytes, empty.next());
}

test "exports reader: a failed next() does not advance, and fails the same way again" {
    const payload = [_]u8{1} ++ entry("a", 9, 0); // kind 9 does not exist
    var it = try iterOver(&payload);
    try testing.expectEqual(@as(u32, 1), it.cursor.pos); // right after the count

    try testing.expectError(error.InvalidKind, it.next());
    try testing.expectEqual(@as(u32, 1), it.cursor.pos);
    try testing.expectEqual(@as(u32, 0), it.yielded);

    try testing.expectError(error.InvalidKind, it.next());
    try testing.expectEqual(@as(u32, 1), it.cursor.pos);
}

test "exports reader: bytes outside the payload window are never read" {
    const buf = [_]u8{ 1, 1, 'a', 0, 0, 0xEE }; // one entry, then a stray byte in the buffer

    // A window that cuts the entry short: the index byte exists in the buffer, but not in the
    // window.
    var c1 = try Cursor.init(&buf);
    var it1 = try Iterator.init(try c1.sub(4));
    try testing.expectError(error.Truncated, it1.next());

    // a window that ends exactly after the entry: the stray byte after it is not "trailing"
    var c2 = try Cursor.init(&buf);
    var it2 = try Iterator.init(try c2.sub(5));
    try expectNext(&it2, "a", .function, 0);
    try testing.expectEqual(null, try it2.next());
}
