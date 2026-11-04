//! Tests of the function section reader: one type index per defined function.
const std = @import("std");
const testing = std.testing;

const Cursor = @import("../../Cursor.zig");
const functions = @import("../../payload/functions.zig");

const Iterator = functions.Iterator;

fn iterOver(payload: []const u8) !Iterator {
    return Iterator.init(try Cursor.init(payload));
}

test "functions reader: zero entries" {
    var it = try iterOver(&.{0});
    try testing.expectEqual(@as(u32, 0), it.count);
    try testing.expectEqual(null, try it.next());
}

test "functions reader: type indices, including multi-byte and padded ones" {
    // Count 3 in two bytes; indices 0, 300 (two bytes), and 1 (padded to two bytes).
    const payload = [_]u8{ 0x83, 0x00, 0, 0xAC, 0x02, 0x81, 0x00 };
    var it = try iterOver(&payload);
    try testing.expectEqual(@as(u32, 3), it.count);
    try testing.expectEqual(@as(?u32, 0), try it.next());
    try testing.expectEqual(@as(?u32, 300), try it.next());
    try testing.expectEqual(@as(?u32, 1), try it.next());
    try testing.expectEqual(null, try it.next());
}

test "functions reader: errors at init" {
    try testing.expectError(error.Truncated, iterOver(&.{})); // empty payload

    const six_byte_count = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 };
    try testing.expectError(error.MalformedLeb, iterOver(&six_byte_count));

    // two entries, one byte behind the count
    try testing.expectError(error.Truncated, iterOver(&.{ 2, 0 }));

    const count_u32_max = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
    try testing.expectError(error.Truncated, iterOver(&count_u32_max));
}

test "functions reader: errors while iterating do not advance" {
    const truncated = [_]u8{ 1, 0x80 }; // a one-byte type index cut after its first byte
    var it = try iterOver(&truncated);
    try testing.expectEqual(@as(u32, 1), it.cursor.pos); // right after the count
    try testing.expectError(error.Truncated, it.next());
    try testing.expectEqual(@as(u32, 1), it.cursor.pos);
    try testing.expectEqual(@as(u32, 0), it.yielded);
    try testing.expectError(error.Truncated, it.next());

    const six_byte_index = [_]u8{ 1, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 };
    var long = try iterOver(&six_byte_index);
    try testing.expectError(error.MalformedLeb, long.next());
}

test "functions reader: trailing bytes" {
    var empty = try iterOver(&.{ 0, 0xFF }); // count 0 with data after it
    try testing.expectError(error.TrailingBytes, empty.next());

    var after_entry = try iterOver(&.{ 1, 0, 0xFF });
    try testing.expectEqual(@as(?u32, 0), try after_entry.next());
    try testing.expectError(error.TrailingBytes, after_entry.next());
}

test "functions reader: bytes outside the payload window are never read" {
    const buf = [_]u8{ 1, 0, 0xEE }; // one entry, then a stray byte in the buffer
    var whole = try Cursor.init(&buf);
    var it = try Iterator.init(try whole.sub(2));
    try testing.expectEqual(@as(?u32, 0), try it.next());
    try testing.expectEqual(null, try it.next());
}
