//! Reads and writes the `limits` structure that table and memory types share.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Cursor = @import("../Cursor.zig");
const spec = @import("../spec.zig");
const errors = @import("../errors.zig");
const EncodeError = errors.EncodeError;
const PayloadError = errors.PayloadError;
const fromCursor = errors.fromCursor;

/// Reads `flags`, `min`, and `max` if `has_max`; 64-bit limits use u64 LEBs. Absent `max` is 0, so
/// check `flags.has_max`, not `max`. Unknown flag bits are `UnsupportedFeature`.
///
/// Structural validation (`min <= max`, shared-memory rules, engine limits) is external. A failed
/// read restores the cursor.
pub fn read(cursor: *Cursor) PayloadError!spec.Limits {
    const start = cursor.pos;
    errdefer cursor.pos = start;

    const byte = cursor.readByte() catch |err| return fromCursor(err);
    const flags: spec.Limits.Flags = @bitCast(byte);
    // Unknown bits (0x08 is custom page sizes) change what follows, so guessing would desync
    // every later entry. Refuse instead.
    if (flags.reserved != 0) return error.UnsupportedFeature;

    var result: spec.Limits = .{ .flags = flags, .min = 0, .max = 0 };
    if (flags.is_64bit) {
        result.min = cursor.readUleb(u64) catch |err| return fromCursor(err);
        if (flags.has_max) result.max = cursor.readUleb(u64) catch |err| return fromCursor(err);
    } else {
        result.min = cursor.readUleb(u32) catch |err| return fromCursor(err);
        if (flags.has_max) result.max = cursor.readUleb(u32) catch |err| return fromCursor(err);
    }

    assert(cursor.pos > start);
    if (!flags.has_max) {
        assert(result.max == 0);
    }
    return result;
}

/// Writes `flags`, `min`, and `max` if `has_max`; 32-bit limits refuse values that do not fit, and
/// reserved flags are `UnsupportedFeature`. Structural validity is external.
pub fn write(limits: spec.Limits, writer: *Io.Writer) EncodeError!void {
    if (limits.flags.reserved != 0) return error.UnsupportedFeature;

    const flags: u8 = @bitCast(limits.flags);
    try writer.writeByte(flags);
    if (limits.flags.is_64bit) {
        try writer.writeLeb128(limits.min);
        if (limits.flags.has_max) try writer.writeLeb128(limits.max);
    } else {
        try writer.writeLeb128(std.math.cast(u32, limits.min) orelse return error.Overflow);
        if (limits.flags.has_max) {
            try writer.writeLeb128(std.math.cast(u32, limits.max) orelse return error.Overflow);
        }
    }
}

const testing = std.testing;

const Row = if (@import("builtin").is_test) struct {
    bytes: []const u8,
    has_max: bool = false,
    shared: bool = false,
    is_64bit: bool = false,
    min: u64,
    max: u64 = 0, // 0 when the input has none
} else @compileError("Should be used only in tests.");

const valid_rows = if (@import("builtin").is_test) [_]Row{
    .{ .bytes = &.{ 0x00, 5 }, .min = 5 },
    .{ .bytes = &.{ 0x01, 1, 4 }, .has_max = true, .min = 1, .max = 4 },
    .{ .bytes = &.{ 0x02, 3 }, .shared = true, .min = 3 },
    .{ .bytes = &.{ 0x03, 1, 2 }, .has_max = true, .shared = true, .min = 1, .max = 2 },
    .{ .bytes = &.{ 0x04, 7 }, .is_64bit = true, .min = 7 },
    .{ .bytes = &.{ 0x05, 1, 9 }, .has_max = true, .is_64bit = true, .min = 1, .max = 9 },
    .{ .bytes = &.{ 0x06, 3 }, .shared = true, .is_64bit = true, .min = 3 },
    .{
        .bytes = &.{ 0x07, 1, 2 },
        .has_max = true,
        .shared = true,
        .is_64bit = true,
        .min = 1,
        .max = 2,
    },
} else @compileError("Should be used only in tests.");

test "limits: every flag combination, consuming exactly its bytes" {
    for (valid_rows) |row| {
        var c = try Cursor.init(row.bytes);
        const got = try read(&c);
        try testing.expectEqual(row.has_max, got.flags.has_max);
        try testing.expectEqual(row.shared, got.flags.is_shared);
        try testing.expectEqual(row.is_64bit, got.flags.is_64bit);
        try testing.expectEqual(row.min, got.min);
        try testing.expectEqual(row.max, got.max);
        try testing.expect(c.atEnd());
    }
}

test "limits: multi-byte values" {
    // 32-bit: u32 max in both fields
    var a = try Cursor.init(&.{ 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F });
    const got_a = try read(&a);
    try testing.expectEqual(@as(u64, std.math.maxInt(u32)), got_a.min);
    try testing.expectEqual(@as(u64, std.math.maxInt(u32)), got_a.max);
    try testing.expect(a.atEnd());

    // 64-bit: 1 << 32, and u64 max
    var b = try Cursor.init(&.{
        0x05, 0x80, 0x80, 0x80, 0x80, 0x10,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x01,
    });
    const got_b = try read(&b);
    try testing.expectEqual(@as(u64, 1) << 32, got_b.min);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), got_b.max);
    try testing.expect(b.atEnd());
}

test "limits: the 64-bit flag decides how wide the values may be" {
    const wide = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x1F }; // 0x1_FFFF_FFFF: needs 33 bits
    var narrow = try Cursor.init(&([_]u8{0x00} ++ wide));
    try testing.expectError(error.MalformedLeb, read(&narrow));
    try testing.expectEqual(0, narrow.pos);

    var wide_c = try Cursor.init(&([_]u8{0x04} ++ wide));
    const got = try read(&wide_c);
    try testing.expectEqual(@as(u64, 0x1_FFFF_FFFF), got.min);
}

test "limits: padded LEBs are fine, over-long ones are not" {
    var padded = try Cursor.init(&.{ 0x01, 0x85, 0x00, 0x87, 0x80, 0x00 }); // min 5, max 7
    const got = try read(&padded);
    try testing.expectEqual(@as(u64, 5), got.min);
    try testing.expectEqual(@as(u64, 7), got.max);
    try testing.expect(padded.atEnd());

    var six_min = try Cursor.init(&.{ 0x00, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 });
    try testing.expectError(error.MalformedLeb, read(&six_min));
    var six_max = try Cursor.init(&.{ 0x01, 1, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 });
    try testing.expectError(error.MalformedLeb, read(&six_max));
    const eleven_byte_leb = [_]u8{
        0x04, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00,
    };
    var eleven = try Cursor.init(&eleven_byte_leb);
    try testing.expectError(error.MalformedLeb, read(&eleven));
}

test "limits: unsupported flag bits" {
    for ([_]u8{ 0x08, 0x09, 0x10, 0x20, 0x40, 0x80, 0xFF }) |flags| {
        const bytes = [_]u8{ flags, 5, 6 };
        var c = try Cursor.init(&bytes);
        try testing.expectError(error.UnsupportedFeature, read(&c));
        try testing.expectEqual(0, c.pos); // cursor is unchanged on error
    }
}

// Every byte value as the flags byte, followed by bytes that fit either width.
test "limits: all 256 flag bytes" {
    var accepted: u32 = 0;
    var rejected: u32 = 0;
    for (0..256) |i| {
        const flags: u8 = @intCast(i);
        const bytes = [_]u8{ flags, 5, 6, 0xEE };
        var c = try Cursor.init(&bytes);
        if (read(&c)) |got| {
            accepted += 1;
            try testing.expect(flags & 0xF8 == 0);
            try testing.expectEqual(@as(u32, if (got.flags.has_max) 3 else 2), c.pos);
            try testing.expectEqual(@as(u64, 5), got.min);
            try testing.expectEqual(@as(u64, if (got.flags.has_max) 6 else 0), got.max);
        } else |err| {
            rejected += 1;
            try testing.expect(err == error.UnsupportedFeature);
            try testing.expect(flags & 0xF8 != 0);
            try testing.expectEqual(0, c.pos);
        }
    }
    try testing.expectEqual(8, accepted);
    try testing.expectEqual(248, rejected);
}

test "limits: every strict prefix of a valid encoding is truncated and moves nothing" {
    for (valid_rows) |row| {
        for (0..row.bytes.len) |len| {
            var c = try Cursor.init(row.bytes[0..len]);
            try testing.expectError(error.Truncated, read(&c));
            try testing.expectEqual(0, c.pos);
        }
    }
    var cut_leb = try Cursor.init(&.{ 0x00, 0x80 }); // a continuation byte with nothing after it
    try testing.expectError(error.Truncated, read(&cut_leb));
    try testing.expectEqual(0, cut_leb.pos);
}

test "limits: absolute positions, and a failed read restores the start" {
    const buf = [_]u8{ 0xAA, 0x01, 5, 6, 0xEE, 0x00, 0x80 };
    var c = try Cursor.init(&buf);
    try c.skip(1);

    const got = try read(&c); // starts mid-buffer
    try testing.expectEqual(@as(u64, 5), got.min);
    try testing.expectEqual(@as(u64, 6), got.max);
    try testing.expectEqual(4, c.pos); // right after the limits: positions are absolute
    try testing.expectEqual(0xEE, try c.readByte()); // the byte after is untouched

    const before = c.pos;
    try testing.expectError(error.Truncated, read(&c)); // {0x00, 0x80}: a LEB that never ends
    try testing.expectEqual(before, c.pos);
}

test "limits: reads stay inside the window" {
    const buf = [_]u8{ 0x01, 5, 6 };
    var whole = try Cursor.init(&buf);
    var window = try whole.sub(2); // the max byte is in the buffer, outside the window
    try testing.expectError(error.Truncated, read(&window));
    try testing.expectEqual(0, window.pos);
}

test "limits: write reproduces every valid encoding" {
    var buffer: [16]u8 = undefined;
    for (valid_rows) |row| {
        const value: spec.Limits = .{
            .flags = .{
                .has_max = row.has_max,
                .is_shared = row.shared,
                .is_64bit = row.is_64bit,
            },
            .min = row.min,
            .max = row.max,
        };
        var writer: Io.Writer = .fixed(&buffer);
        try write(value, &writer);
        try testing.expectEqualSlices(u8, row.bytes, writer.buffered());
    }
}

test "limits: write refuses reserved flags and narrow values that do not fit" {
    var buffer: [16]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    const reserved: spec.Limits = .{
        .flags = .{ .has_max = false, .is_shared = false, .is_64bit = false, .reserved = 1 },
        .min = 0,
        .max = 0,
    };
    try testing.expectError(error.UnsupportedFeature, write(reserved, &writer));

    const narrow_min: spec.Limits = .{
        .flags = .{ .has_max = false, .is_shared = false, .is_64bit = false },
        .min = @as(u64, std.math.maxInt(u32)) + 1,
        .max = 0,
    };
    try testing.expectError(error.Overflow, write(narrow_min, &writer));

    const narrow_max: spec.Limits = .{
        .flags = .{ .has_max = true, .is_shared = false, .is_64bit = false },
        .min = 0,
        .max = @as(u64, std.math.maxInt(u32)) + 1,
    };
    try testing.expectError(error.Overflow, write(narrow_max, &writer));
}

test "limits: write with no room fails instead of panicking" {
    var none: [0]u8 = .{};
    var writer: Io.Writer = .fixed(&none);
    const value: spec.Limits = .{
        .flags = .{ .has_max = false, .is_shared = false, .is_64bit = false },
        .min = 0,
        .max = 0,
    };
    try testing.expectError(error.WriteFailed, write(value, &writer));
}
