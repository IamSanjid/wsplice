//! A pending stretch of input to copy unchanged. `start` is the first byte not yet written or
//! skipped.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

bytes: []const u8, // the whole input module
writer: *Io.Writer,
start: u32 = 0,

const Run = @This();

/// Write input[start..end] to the output, then move `start` to `end`.
pub fn flush(self: *Run, end: u32) Io.Writer.Error!void {
    self.assertInvariants();
    assert(end >= self.start);
    assert(end <= self.bytes.len);

    try self.writer.writeAll(self.bytes[self.start..end]);
    self.start = end;
    self.assertInvariants();
}

/// Drop input[start..to] (the old bytes of a section that is being replaced).
pub fn skip(self: *Run, to: u32) void {
    self.assertInvariants();
    assert(to >= self.start);
    assert(to <= self.bytes.len);

    self.start = to;
    self.assertInvariants();
}

fn assertInvariants(self: *const Run) void {
    assert(self.start <= self.bytes.len);
    assert(self.bytes.len <= std.math.maxInt(u32)); // `start` is a u32 offset
}

const testing = std.testing;

fn seq(comptime len: usize) [len]u8 {
    if (!@import("builtin").is_test) {
        @compileError("Should be used only in tests.");
    }
    var bytes: [len]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(index);
    return bytes;
}

// Top-level const: evaluated at comptime.
const input16 = if (@import("builtin").is_test)
    seq(16)
else
    @compileError("Should be accessed only in tests.");

test "Run: successive flushes concatenate to the input" {
    var buf: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var run: Run = .{ .bytes = &input16, .writer = &w };

    try run.flush(5);
    try testing.expectEqual(5, run.start);
    try run.flush(5); // empty range
    try run.flush(11);
    try run.flush(16);

    try testing.expectEqualSlices(u8, &input16, w.buffered());
    try testing.expectEqual(16, run.start);
}

test "Run: flushing nothing writes nothing, even into a zero-capacity writer" {
    var buf: [0]u8 = .{};
    var w: Io.Writer = .fixed(&buf);

    var mid: Run = .{ .bytes = &input16, .writer = &w, .start = 7 };
    try mid.flush(7);
    try testing.expectEqual(7, mid.start);

    var empty: Run = .{ .bytes = &[_]u8{}, .writer = &w }; // empty input
    try empty.flush(0);
    try testing.expectEqual(0, w.buffered().len);
}

test "Run: flush, skip, flush leaves out exactly the skipped range" {
    var buf: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var run: Run = .{ .bytes = &input16, .writer = &w };

    try run.flush(4);
    run.skip(9); // drops input[4..9]
    try run.flush(16);

    const expected = input16[0..4] ++ input16[9..16];
    try testing.expectEqualSlices(u8, expected, w.buffered());
}

test "Run: skip to the current position is a no-op, skip to the end leaves nothing" {
    var buf: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var run: Run = .{ .bytes = &input16, .writer = &w, .start = 3 };

    run.skip(3);
    try testing.expectEqual(3, run.start);

    run.skip(16);
    try run.flush(16);
    try testing.expectEqual(0, w.buffered().len);
}

test "Run: every cut point, and every skipped range" {
    const len: u32 = input16.len;

    // identity at every single cut point
    var k: u32 = 0;
    while (k <= len) : (k += 1) {
        var buf: [16]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        var run: Run = .{ .bytes = &input16, .writer = &w };
        try run.flush(k);
        try run.flush(len);
        try testing.expectEqualSlices(u8, &input16, w.buffered());
    }

    // flush(a), skip(b), flush(len) for every a <= b
    var a: u32 = 0;
    while (a <= len) : (a += 1) {
        var b: u32 = a;
        while (b <= len) : (b += 1) {
            var buf: [16]u8 = undefined;
            var w: Io.Writer = .fixed(&buf);
            var run: Run = .{ .bytes = &input16, .writer = &w };
            try run.flush(a);
            run.skip(b);
            try run.flush(len);

            var expected: [16]u8 = undefined;
            const tail = len - b;
            @memcpy(expected[0..a], input16[0..a]);
            @memcpy(expected[a .. a + tail], input16[b..len]);
            try testing.expectEqualSlices(u8, expected[0 .. a + tail], w.buffered());
        }
    }
}

test "Run: a too-small writer makes flush fail, an exact one succeeds" {
    var small: [3]u8 = undefined;
    var w1: Io.Writer = .fixed(&small);
    var run1: Run = .{ .bytes = &input16, .writer = &w1 };
    try testing.expectError(error.WriteFailed, run1.flush(4));

    var fit: [3]u8 = undefined;
    var w2: Io.Writer = .fixed(&fit);
    var run2: Run = .{ .bytes = &input16, .writer = &w2 };
    try run2.flush(3);
    try testing.expectEqualSlices(u8, input16[0..3], w2.buffered());
}
