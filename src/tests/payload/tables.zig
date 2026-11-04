//! Tests of the table section reader and writer.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const spec = @import("../../spec.zig");
const Cursor = @import("../../Cursor.zig");
const tables = @import("../../payload/tables.zig");

fn limits(min: u64, max: ?u64, is_64bit: bool) spec.Limits {
    return .{
        .flags = .{ .has_max = max != null, .is_shared = false, .is_64bit = is_64bit },
        .min = min,
        .max = max orelse 0,
    };
}

fn iterOver(payload: []const u8) !tables.Iterator {
    return tables.Iterator.init(try Cursor.init(payload));
}

/// The first error reading the whole payload produces, or null if it reads cleanly.
fn firstError(payload: []const u8) ?anyerror {
    var it = tables.Iterator.init(Cursor.init(payload) catch |e| return e) catch |e| return e;
    while (it.next() catch |e| return e) |_| {}
    return null;
}

fn expectEntry(it: *tables.Iterator, expected: tables.Type, expected_bytes: []const u8) !void {
    const entry = (try it.next()).?;
    try testing.expectEqualDeep(expected, entry.table_type);
    try testing.expectEqualSlices(u8, expected_bytes, entry.bytes);
}

// ---------------------------------------------------------------- reading

test "tables reader: every table type shape" {
    const func_min = tables.Type{ .reftype = .func, .limits = limits(1, null, false) };
    const extern_max = tables.Type{ .reftype = .@"extern", .limits = limits(2, 10, false) };
    const func_64 = tables.Type{ .reftype = .func, .limits = limits(1, null, true) };

    const payload = [_]u8{3} ++
        [_]u8{ 0x70, 0x00, 1 } ++
        [_]u8{ 0x6F, 0x01, 2, 10 } ++
        [_]u8{ 0x70, 0x04, 1 };
    var it = try iterOver(&payload);
    try testing.expectEqual(@as(u32, 3), it.count);
    try expectEntry(&it, func_min, &.{ 0x70, 0x00, 1 });
    try expectEntry(&it, extern_max, &.{ 0x6F, 0x01, 2, 10 });
    try expectEntry(&it, func_64, &.{ 0x70, 0x04, 1 });
    try testing.expectEqual(null, try it.next());
}

test "tables reader: padded counts and limits are kept in the entry bytes" {
    const payload = [_]u8{ 0x82, 0x80, 0x00 } ++
        [_]u8{ 0x70, 0x00, 0x81, 0x80, 0x00 } ++
        [_]u8{ 0x6F, 0x01, 2, 4 };
    var it = try iterOver(&payload);
    try testing.expectEqual(@as(u32, 2), it.count);
    try expectEntry(&it, .{ .reftype = .func, .limits = limits(1, null, false) }, &.{
        0x70, 0x00, 0x81, 0x80, 0x00,
    });
    try expectEntry(&it, .{ .reftype = .@"extern", .limits = limits(2, 4, false) }, &.{
        0x6F, 0x01, 2, 4,
    });
    try testing.expectEqual(null, try it.next());
}

test "tables reader: zero entries and the smallest entry" {
    var empty = try iterOver(&.{0});
    try testing.expectEqual(@as(u32, 0), empty.count);
    try testing.expectEqual(null, try empty.next());

    var smallest = try iterOver(&.{ 1, 0x70, 0x00, 0 }); // funcref, min 0
    try expectEntry(&smallest, .{ .reftype = .func, .limits = limits(0, null, false) }, &.{
        0x70, 0x00, 0,
    });
    try testing.expectEqual(null, try smallest.next());
}

test "tables reader: entry bytes are exactly the entry's own encoding" {
    const payload = [_]u8{ 1, 0x70, 0x00, 1, 0xEE };
    var whole = try iterOver(&payload);
    const entry = (try whole.next()).?;
    try testing.expectEqualSlices(u8, payload[1..4], entry.bytes);
    try testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(entry.bytes.ptr) - @intFromPtr(payload[1..].ptr),
    );
}

test "tables reader: every strict prefix of a valid payload is truncated" {
    const payload = [_]u8{ 2, 0x70, 0x00, 1, 0x6F, 0x01, 2, 4 };
    for (0..payload.len) |len| {
        try testing.expectEqual(@as(?anyerror, error.Truncated), firstError(payload[0..len]));
    }
    try testing.expectEqual(@as(?anyerror, null), firstError(&payload));
}

test "tables reader: malformed and unsupported table types" {
    const cases = [_]struct { payload: []const u8, err: anyerror }{
        .{ .payload = &.{ 1, 0x7F, 0x00, 1 }, .err = error.InvalidValue }, // number, not a reftype
        .{ .payload = &.{ 1, 0x63, 0x00, 0x00, 1 }, .err = error.UnsupportedFeature }, // prefixed
        .{ .payload = &.{ 1, 0x70, 0x08, 1 }, .err = error.UnsupportedFeature }, // reserved flag
        .{ .payload = &.{ 1, 0x70, 0x01, 2 }, .err = error.Truncated }, // no max
        .{ .payload = &.{ 1, 0x70, 0x00, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }, .err = error.MalformedLeb },
        .{ .payload = &.{1}, .err = error.Truncated }, // no table
    };
    for (cases) |case| {
        try testing.expectEqual(@as(?anyerror, case.err), firstError(case.payload));
    }
}

test "tables reader: errors at init" {
    try testing.expectError(error.Truncated, iterOver(&.{}));
    try testing.expectError(error.MalformedLeb, iterOver(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }));
    // count 1, only two bytes left; the smallest entry is three bytes.
    try testing.expectError(error.Truncated, iterOver(&.{ 1, 0x70, 0x00 }));
}

test "tables reader: trailing bytes and a failed next() does not advance" {
    var trailing = try iterOver(&.{ 0, 0xFF });
    try testing.expectError(error.TrailingBytes, trailing.next());

    const payload = [_]u8{ 1, 0x70, 0x08, 1 }; // reserved limits flag
    var it = try iterOver(&payload);
    const start = it.cursor.pos;
    try testing.expectError(error.UnsupportedFeature, it.next());
    try testing.expectEqual(start, it.cursor.pos);
    try testing.expectEqual(@as(u32, 0), it.yielded);
}

test "tables reader: bytes outside the payload window are never read" {
    const buffer = [_]u8{ 1, 0x70, 0x00, 0x80, 0xEE };
    var whole = try Cursor.init(&buffer);
    const window = try whole.sub(4); // cuts the minimum byte off
    var it = try tables.Iterator.init(window);
    try testing.expectError(error.Truncated, it.next());
}

// ---------------------------------------------------------------- writing

const rows = [_]struct { table_type: tables.Type, bytes: []const u8 }{
    .{
        .table_type = .{ .reftype = .func, .limits = limits(1, null, false) },
        .bytes = &.{ 0x70, 0x00, 1 },
    },
    .{
        .table_type = .{ .reftype = .@"extern", .limits = limits(2, 10, false) },
        .bytes = &.{ 0x6F, 0x01, 2, 10 },
    },
    .{
        .table_type = .{ .reftype = .func, .limits = limits(1, 9, true) },
        .bytes = &.{ 0x70, 0x05, 1, 9 },
    },
};

test "tables writer: every shape is exactly its bytes" {
    var buffer: [16]u8 = undefined;
    for (rows) |row| {
        var writer: Io.Writer = .fixed(&buffer);
        try tables.write(row.table_type, &writer);
        try testing.expectEqualSlices(u8, row.bytes, writer.buffered());
    }
}

test "tables writer: what it writes reads back" {
    for (rows) |row| {
        var buffer: [16]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        try tables.write(row.table_type, &writer);
        const written = writer.buffered();

        var payload: [17]u8 = undefined;
        payload[0] = 1;
        @memcpy(payload[1..][0..written.len], written);
        var it = try iterOver(payload[0 .. 1 + written.len]);
        try expectEntry(&it, row.table_type, written);
        try testing.expectEqual(null, try it.next());
    }
}

test "tables writer: a bad limit fails and a short writer fails cleanly" {
    var buffer: [16]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    const reserved = tables.Type{
        .reftype = .func,
        .limits = .{
            .flags = .{ .has_max = false, .is_shared = false, .is_64bit = false, .reserved = 1 },
            .min = 0,
            .max = 0,
        },
    };
    try testing.expectError(error.UnsupportedFeature, tables.write(reserved, &writer));

    const narrow = tables.Type{
        .reftype = .func,
        .limits = .{
            .flags = .{ .has_max = false, .is_shared = false, .is_64bit = false },
            .min = @as(u64, std.math.maxInt(u32)) + 1,
            .max = 0,
        },
    };
    try testing.expectError(error.Overflow, tables.write(narrow, &writer));

    var tiny: [1]u8 = undefined;
    var short: Io.Writer = .fixed(&tiny);
    try testing.expectError(error.WriteFailed, tables.write(rows[0].table_type, &short));
}
