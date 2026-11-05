//! Custom section framing: `name:name data:bytes`. This module only understands the name vector;
//! the data is opaque and belongs to a typed codec under `custom/`.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Cursor = @import("../Cursor.zig");
const errors = @import("../errors.zig");
const PayloadError = errors.PayloadError;
const EncodeError = errors.EncodeError;
const fromCursor = errors.fromCursor;
const Span = @import("../section.zig").Span;

pub const Entry = struct {
    /// Borrowed name bytes; not checked for UTF-8.
    name: []const u8,
    /// Everything after the name vector.
    data: []const u8,
};

/// Reads one custom section payload. `bytes` is the module; `payload` is its payload window.
pub fn read(bytes: []const u8, payload: Span) PayloadError!Entry {
    assert(payload.start <= payload.end);
    assert(payload.end <= bytes.len);
    var cursor: Cursor = .{
        .bytes = bytes,
        .pos = payload.start,
        .end = payload.end,
    };
    const name_len = cursor.readUleb(u32) catch |err| return fromCursor(err);
    const name = cursor.take(name_len) catch |err| return fromCursor(err);
    assert(cursor.pos <= payload.end);
    return .{ .name = name, .data = bytes[cursor.pos..payload.end] };
}

/// Encoded size of the custom-section payload, name vector included.
pub fn encodedLen(entry: *const Entry) EncodeError!u32 {
    var counter = Io.Writer.Discarding.init(&.{});
    try write(entry, &counter.writer);
    return std.math.cast(u32, counter.fullCount()) orelse error.Overflow;
}

/// Writes the custom-section payload, name vector included.
pub fn write(entry: *const Entry, writer: *Io.Writer) EncodeError!void {
    assert(entry.name.len <= std.math.maxInt(u32));
    try writer.writeLeb128(@as(u32, @intCast(entry.name.len)));
    try writer.writeAll(entry.name);
    try writer.writeAll(entry.data);
}

const testing = std.testing;

test "custom: reads a name and the remaining data" {
    const bytes = [_]u8{ 4, 't', 'e', 's', 't', 0xAA, 0xBB };
    const entry = try read(&bytes, .{ .start = 0, .end = bytes.len });
    try testing.expectEqualStrings("test", entry.name);
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, entry.data);
}

test "custom: empty name and empty data are valid" {
    const empty_name = [_]u8{0};
    const a = try read(&empty_name, .{ .start = 0, .end = empty_name.len });
    try testing.expectEqual(@as(usize, 0), a.name.len);
    try testing.expectEqual(@as(usize, 0), a.data.len);

    const empty_data = [_]u8{ 4, 'n', 'a', 'm', 'e' };
    const b = try read(&empty_data, .{ .start = 0, .end = empty_data.len });
    try testing.expectEqualStrings("name", b.name);
    try testing.expectEqual(@as(usize, 0), b.data.len);
}

test "custom: a truncated name is Truncated" {
    const bytes = [_]u8{ 4, 't', 'e' };
    try testing.expectError(error.Truncated, read(&bytes, .{ .start = 0, .end = bytes.len }));
}

test "custom: an empty payload is Truncated" {
    try testing.expectError(error.Truncated, read(&.{}, .{ .start = 0, .end = 0 }));
}

test "custom: write and encodedLen agree" {
    const entry: Entry = .{ .name = "abc", .data = &.{ 1, 2, 3 } };
    var buf: [32]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try write(&entry, &writer);
    try testing.expectEqualSlices(u8, &.{ 3, 'a', 'b', 'c', 1, 2, 3 }, writer.buffered());
    try testing.expectEqual(@as(u32, @intCast(writer.buffered().len)), try encodedLen(&entry));
}
