//! This is supposed to be a wasm spec respected Cursor not a general purpose Cursor.
const std = @import("std");
const assert = std.debug.assert;

bytes: []const u8,
pos: u32, // always an absolute offset into `bytes`
end: u32, // reads may not go past this

const Cursor = @This();

pub fn init(bytes: []const u8) error{TooLarge}!Cursor {
    const len = std.math.cast(u32, bytes.len) orelse return error.TooLarge;
    return .{ .bytes = bytes, .pos = 0, .end = len };
}

/// `pos` and `end` are absolute offsets into `bytes`, and `end` is a window edge, so it may sit
/// before the end of the buffer. Both facts hold after every method that moves `pos`.
fn assertInvariants(self: *const Cursor) void {
    assert(self.pos <= self.end);
    assert(self.end <= self.bytes.len);
}

pub fn remaining(self: *const Cursor) u32 {
    self.assertInvariants();
    return self.end - self.pos; // can't underflow, given the invariant
}

pub fn atEnd(self: *const Cursor) bool {
    return self.remaining() == 0;
}

test "atEnd + remaining" {
    var c = try Cursor.init(&[_]u8{ 0x01, 0x02, 0x03 });
    try std.testing.expect(!c.atEnd());
    try std.testing.expectEqual(3, c.remaining());
    _ = try c.readByte();
    try std.testing.expect(!c.atEnd());
    try std.testing.expectEqual(2, c.remaining());
    _ = try c.readByte();
    try std.testing.expect(!c.atEnd());
    try std.testing.expectEqual(1, c.remaining());
    _ = try c.readByte();
    try std.testing.expect(c.atEnd());
    try std.testing.expectEqual(0, c.remaining());
}

pub fn peekByte(self: *const Cursor) error{EndOfStream}!u8 {
    self.assertInvariants();
    if (self.pos == self.end) return error.EndOfStream;
    return self.bytes[self.pos];
}

test peekByte {
    {
        var c = try Cursor.init(&[_]u8{ 0x01, 0x02, 0x03 });
        try std.testing.expectEqual(0x01, c.peekByte());
        try std.testing.expectEqual(0, c.pos);
        try std.testing.expectEqual(0x01, c.peekByte());
        try std.testing.expectEqual(0, c.pos);
    }
    {
        var c = try Cursor.init(&[_]u8{});
        try std.testing.expectError(error.EndOfStream, c.peekByte());
        try std.testing.expectEqual(0, c.pos);
    }
}

pub fn readByte(self: *Cursor) error{EndOfStream}!u8 {
    const byte = try self.peekByte();
    self.pos += 1;
    self.assertInvariants();
    return byte;
}

test readByte {
    {
        var c = try Cursor.init(&[_]u8{ 0x01, 0x02, 0x03 });
        try std.testing.expectEqual(0x01, c.readByte());
        try std.testing.expectEqual(1, c.pos);
        try std.testing.expectEqual(0x02, c.readByte());
        try std.testing.expectEqual(2, c.pos);
        try std.testing.expectEqual(0x03, c.readByte());
        try std.testing.expectEqual(3, c.pos);
        try std.testing.expectError(error.EndOfStream, c.readByte());
    }
    {
        var c = try Cursor.init(&[_]u8{});
        try std.testing.expectError(error.EndOfStream, c.readByte());
        try std.testing.expectEqual(0, c.pos);
    }
}

pub fn take(self: *Cursor, n: u32) error{EndOfStream}![]const u8 {
    self.assertInvariants();
    if (n > self.remaining()) return error.EndOfStream;

    const start = self.pos;
    self.pos += n; // cannot overflow: n <= end - pos
    const result = self.bytes[start..self.pos];

    assert(result.len == n);
    self.assertInvariants();
    return result;
}

test take {
    {
        var c = try Cursor.init(&[_]u8{ 0x01, 0x02, 0x03 });
        const slice1 = try c.take(2);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, slice1);
        try std.testing.expectEqual(2, c.pos);
        const slice2 = try c.take(1);
        try std.testing.expectEqualSlices(u8, &[_]u8{0x03}, slice2);
        try std.testing.expectEqual(3, c.pos);
        try std.testing.expectError(error.EndOfStream, c.take(1));
    }
    {
        var c = try Cursor.init(&[_]u8{});
        try std.testing.expectError(error.EndOfStream, c.take(1));
        try std.testing.expectEqual(0, c.pos);
    }
}

pub fn skip(self: *Cursor, n: u32) error{EndOfStream}!void {
    _ = try self.take(n);
}

test skip {
    {
        var c = try Cursor.init(&[_]u8{ 0x01, 0x02, 0x03 });
        try c.skip(2);
        try std.testing.expectEqual(2, c.pos);
        try c.skip(1);
        try std.testing.expectEqual(3, c.pos);
        try std.testing.expectError(error.EndOfStream, c.skip(1));
    }
    {
        var c = try Cursor.init(&[_]u8{});
        try std.testing.expectError(error.EndOfStream, c.skip(1));
        try std.testing.expectEqual(0, c.pos);
    }
}

pub fn sub(self: *Cursor, n: u32) error{EndOfStream}!Cursor {
    self.assertInvariants();
    if (n > self.remaining()) return error.EndOfStream;

    const child: Cursor = .{
        .bytes = self.bytes, // same buffer, so positions stay absolute
        .pos = self.pos,
        .end = self.pos + n,
    };
    self.pos += n;

    assert(child.end == self.pos); // the child's end meets the parent's new position
    child.assertInvariants();
    return child;
}

test sub {
    {
        var c = try Cursor.init(&[_]u8{ 0x01, 0x02, 0x03, 0x04 });
        const child = try c.sub(2);
        try std.testing.expectEqual(2, c.pos);
        try std.testing.expectEqual(0, child.pos);
        try std.testing.expectEqual(2, child.end);
        try std.testing.expectEqualSlices(
            u8,
            &[_]u8{ 0x01, 0x02 },
            child.bytes[child.pos..child.end],
        );
    }
    {
        var c = try Cursor.init(&[_]u8{});
        try std.testing.expectError(error.EndOfStream, c.sub(1));
    }
}

test "window refuses to read past its end" {
    var c = try Cursor.init(&[_]u8{ 1, 2, 3, 4 });
    var child = try c.sub(2);
    try std.testing.expectEqual(1, try child.readByte());
    try std.testing.expectEqual(2, try child.readByte());
    // bytes[2] exists in the buffer but is outside the window
    try std.testing.expectError(error.EndOfStream, child.readByte());
    try std.testing.expectError(error.EndOfStream, child.peekByte());
    try std.testing.expectError(error.EndOfStream, child.take(1));
    try std.testing.expectEqual(2, child.pos);
    // the parent continues right after the window
    try std.testing.expectEqual(3, try c.readByte());
}

test "sub keeps absolute positions, including nested" {
    var c = try Cursor.init(&[_]u8{ 0, 1, 2, 3, 4, 5 });
    try c.skip(3);
    var child = try c.sub(2);
    try std.testing.expectEqual(3, child.pos);
    try std.testing.expectEqual(5, child.end);
    try std.testing.expectEqual(3, try child.readByte());

    var inner = try child.sub(1);
    try std.testing.expectEqual(4, inner.pos);
    try std.testing.expectEqual(4, try inner.readByte());
    try std.testing.expectError(error.EndOfStream, inner.readByte());
    try std.testing.expect(child.atEnd());
}

test "failed take/skip/sub leave pos unchanged" {
    var c = try Cursor.init(&[_]u8{ 1, 2, 3 });
    try c.skip(1);
    try std.testing.expectError(error.EndOfStream, c.take(5));
    try std.testing.expectError(error.EndOfStream, c.skip(5));
    try std.testing.expectError(error.EndOfStream, c.sub(5));
    try std.testing.expectEqual(1, c.pos);
}

test "huge n cannot overflow" {
    var c = try Cursor.init(&[_]u8{ 1, 2, 3 });
    try c.skip(1);
    // pos + n would wrap in u32; the remaining() comparison must catch it
    try std.testing.expectError(error.EndOfStream, c.take(std.math.maxInt(u32)));
    try std.testing.expectError(error.EndOfStream, c.sub(std.math.maxInt(u32)));
    try std.testing.expectEqual(1, c.pos);
}

test "zero-length operations at the end" {
    var c = try Cursor.init(&[_]u8{1});
    try c.skip(1);
    try std.testing.expectEqual(0, (try c.take(0)).len);
    try c.skip(0);
    const child = try c.sub(0);
    try std.testing.expect(child.atEnd());
}

pub fn readUleb(self: *Cursor, comptime T: type) error{ EndOfStream, Overflow }!T {
    comptime assert(T == u32 or T == u64);
    const bits = @bitSizeOf(T);
    const max_bytes = @divFloor(bits + 6, 7); // ceil(bits / 7): 5 for u32, 10 for u64
    const last_bits = bits - 7 * (max_bytes - 1); // data bits allowed in the final byte: 4 or 1
    const last_mask: u8 = (1 << last_bits) - 1;

    const start = self.pos;
    errdefer self.pos = start; // a failed read must not move the cursor

    var result: T = 0;
    for (0..max_bytes) |i| {
        const byte = try self.readByte();
        const payload: u8 = byte & 0x7f;

        // On the final byte, data bits beyond the type's width would be lost.
        if (i == max_bytes - 1) {
            if ((payload & ~last_mask) != 0) return error.Overflow;
        }

        result |= @as(T, payload) << @intCast(i * 7);
        if (byte & 0x80 == 0) return result; // continue bit clear: finished
    }
    assert(self.pos - start <= max_bytes);
    return error.Overflow; // the final byte still said "more"
}

test readUleb {
    {
        var c = try Cursor.init(&[_]u8{0x00});
        try std.testing.expectEqual(0, c.readUleb(u32));
        try std.testing.expect(c.atEnd());
    }
    {
        var c = try Cursor.init(&[_]u8{0x7F});
        try std.testing.expectEqual(127, c.readUleb(u32));
        try std.testing.expect(c.atEnd());
    }
    {
        var c = try Cursor.init(&[_]u8{ 0x80, 0x01 });
        try std.testing.expectEqual(128, c.readUleb(u32));
        try std.testing.expect(c.atEnd());
    }
    {
        var c = try Cursor.init(&[_]u8{ 0xE5, 0x8E, 0x26 });
        try std.testing.expectEqual(624485, c.readUleb(u32));
        try std.testing.expect(c.atEnd());
    }
}

test "readUleb padded" {
    var c = try Cursor.init(&[_]u8{ 0x85, 0x00 }); // padded
    try std.testing.expectEqual(5, c.readUleb(u32));
    try std.testing.expect(c.atEnd());
}

test "readUleb max u32" {
    var c = try Cursor.init(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F }); // max u32
    try std.testing.expectEqual(std.math.maxInt(u32), c.readUleb(u32));
    try std.testing.expect(c.atEnd());
    try std.testing.expectError(error.EndOfStream, c.readUleb(u32));
}

test "readUleb overflow u32" {
    var c = try Cursor.init(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x1F }); // overflow u32
    try std.testing.expectError(error.Overflow, c.readUleb(u32));
    try std.testing.expectEqual(0, c.pos);
}

test "readUleb too many bytes (std's takeLeb128 would accept this)" {
    // Overflow u32, but enough bytes to read.
    var c = try Cursor.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 });
    try std.testing.expectError(error.Overflow, c.readUleb(u32));
    try std.testing.expectEqual(0, c.pos);
}

test "readUleb incomplete" {
    var c = try Cursor.init(&[_]u8{0x80}); // incomplete
    try std.testing.expectError(error.EndOfStream, c.readUleb(u32));
    try std.testing.expectEqual(0, c.pos);
}

test "readUleb max u64" {
    const max_u64 = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
    var c = try Cursor.init(&max_u64);
    try std.testing.expectEqual(std.math.maxInt(u64), c.readUleb(u64));
    try std.testing.expect(c.atEnd());
    try std.testing.expectError(error.EndOfStream, c.readUleb(u64));
}

test "readUleb overflow u64" {
    const overflow_u64 = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02 };
    var c = try Cursor.init(&overflow_u64);
    try std.testing.expectError(error.Overflow, c.readUleb(u64));
    try std.testing.expectEqual(0, c.pos);
}

test "readUleb restores pos to where it started, not to zero" {
    var c = try Cursor.init(&[_]u8{ 0xAA, 0xFF, 0xFF, 0xFF, 0xFF, 0x1F });
    try c.skip(1);
    try std.testing.expectError(error.Overflow, c.readUleb(u32));
    try std.testing.expectEqual(1, c.pos);
}

test "readUleb consumes exactly its encoding" {
    var c = try Cursor.init(&[_]u8{ 0x85, 0x00, 0x7F }); // padded 5, then 127
    try std.testing.expectEqual(5, c.readUleb(u32));
    try std.testing.expectEqual(2, c.pos);
    try std.testing.expectEqual(127, c.readUleb(u32));
    try std.testing.expectEqual(3, c.pos);
}

test "readUleb respects the window end" {
    var c = try Cursor.init(&[_]u8{ 0x80, 0x01 });
    var child = try c.sub(1); // window covers only the first byte
    try std.testing.expectError(error.EndOfStream, child.readUleb(u32));
    try std.testing.expectEqual(0, child.pos);
}

test "readUleb u64 above 32 bits, same bytes overflow as u32" {
    const bytes = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x10 }; // 1 << 32
    var a = try Cursor.init(&bytes);
    try std.testing.expectEqual(@as(u64, 1) << 32, a.readUleb(u64));
    var b = try Cursor.init(&bytes);
    try std.testing.expectError(error.Overflow, b.readUleb(u32));
}

test "readUleb round-trips std's writeLeb128 for u64" {
    var buf: [10]u8 = undefined;
    var shift: u7 = 0;
    while (shift < 64) : (shift += 1) {
        const base: u64 = @as(u64, 1) << @intCast(shift);
        for ([_]u64{ base -% 1, base, base +% 1 }) |v| {
            var w: std.Io.Writer = .fixed(&buf);
            try w.writeLeb128(v);
            var c = try Cursor.init(w.buffered());
            try std.testing.expectEqual(v, try c.readUleb(u64));
            try std.testing.expect(c.atEnd()); // consumed the whole canonical encoding
        }
    }
}

test "readUleb round-trips std's writeLeb128 for u32" {
    var buf: [10]u8 = undefined;
    var shift: u7 = 0;
    while (shift < 32) : (shift += 1) {
        const base: u32 = @as(u32, 1) << @intCast(shift);
        for ([_]u32{ base -% 1, base, base +% 1 }) |v| {
            var w: std.Io.Writer = .fixed(&buf);
            try w.writeLeb128(v);
            var c = try Cursor.init(w.buffered());
            try std.testing.expectEqual(v, try c.readUleb(u32));
            try std.testing.expect(c.atEnd()); // consumed the whole canonical encoding
        }
    }
}

pub fn skipLeb(self: *Cursor, comptime max_bytes: u8) error{ EndOfStream, Overflow }!void {
    comptime assert(max_bytes >= 1);
    const start = self.pos;
    errdefer self.pos = start;

    for (0..max_bytes) |_| {
        const byte = try self.readByte();
        if (byte & 0x80 == 0) return;
    }
    return error.Overflow;
}

test "skipLeb skips one value at a time" {
    var c = try Cursor.init(&[_]u8{ 0x00, 0x7F, 0x80, 0x01 });
    try c.skipLeb(5);
    try std.testing.expectEqual(1, c.pos);
    try c.skipLeb(5);
    try std.testing.expectEqual(2, c.pos);
    try c.skipLeb(5); // two-byte value
    try std.testing.expectEqual(4, c.pos);
    try std.testing.expect(c.atEnd());
}

test "skipLeb fails on incomplete" {
    var c = try Cursor.init(&[_]u8{0x80});
    try std.testing.expectError(error.EndOfStream, c.skipLeb(5));
    try std.testing.expectEqual(0, c.pos);
}

test "skipLeb fails on overflow" {
    var c = try Cursor.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }); // overflow u32
    try std.testing.expectError(error.Overflow, c.skipLeb(5));
    try std.testing.expectEqual(0, c.pos);
}

test "skipLeb skips but readUleb fails on overflow" {
    var c = try Cursor.init(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x7F });
    try c.skipLeb(5);
    try std.testing.expectEqual(5, c.pos);
    c.pos = 0; // rewind to the start
    try std.testing.expectError(error.Overflow, c.readUleb(u32));
}

test "skipLeb restores pos to where it started" {
    var c = try Cursor.init(&[_]u8{ 0xAA, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 });
    try c.skip(1);
    try std.testing.expectError(error.Overflow, c.skipLeb(5));
    try std.testing.expectEqual(1, c.pos);
}

test "skipLeb respects the window end" {
    var c = try Cursor.init(&[_]u8{ 0x80, 0x01 });
    var child = try c.sub(1);
    try std.testing.expectError(error.EndOfStream, child.skipLeb(5));
    try std.testing.expectEqual(0, child.pos);
}

test "skipLeb with max_bytes 10" {
    var c = try Cursor.init(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 });
    try c.skipLeb(10);
    try std.testing.expect(c.atEnd());
}

test "skipLeb and readUleb stop at the same place for valid input" {
    const inputs = [_][]const u8{
        &.{0x00},
        &.{0x7F},
        &.{ 0x80, 0x01 },
        &.{ 0x85, 0x00 },
        &.{ 0xE5, 0x8E, 0x26 },
        &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F },
    };
    for (inputs) |bytes| {
        var a = try Cursor.init(bytes);
        var b = try Cursor.init(bytes);
        _ = try a.readUleb(u32);
        try b.skipLeb(5);
        try std.testing.expectEqual(a.pos, b.pos);
    }
}
