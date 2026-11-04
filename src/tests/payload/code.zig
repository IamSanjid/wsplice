//! Tests of the code-section frame reader.
const std = @import("std");
const testing = std.testing;

const spec = @import("../../spec.zig");
const Cursor = @import("../../Cursor.zig");
const Module = @import("../../Module.zig");
const Counts = @import("../../payload/Counts.zig");
const code = @import("../../payload/code.zig");
const operators = @import("../../payload/operators.zig");
const fixtures = @import("../fixtures/fixtures.zig");

fn iterOver(payload: []const u8) !code.Iterator {
    return code.Iterator.init(try Cursor.init(payload));
}

fn bodyBytes(entry: code.Entry) []const u8 {
    return entry.body.bytes[entry.body.pos..entry.body.end];
}

fn expectEntry(it: *code.Iterator, bytes: []const u8, locals: []const u8, body: []const u8) !void {
    const entry = (try it.next()).?;
    try testing.expectEqualSlices(u8, bytes, entry.bytes);
    try testing.expectEqualSlices(u8, locals, entry.locals);
    try testing.expectEqualSlices(u8, body, bodyBytes(entry));
}

// --------------------------------------------------------------- structure

test "code reader: an empty section has no entries" {
    var it = try iterOver(&.{0});
    try testing.expectEqual(@as(u32, 0), it.count);
    try testing.expectEqual(null, try it.next());
}

test "code reader: an entry with no locals" {
    // count 1, size 2, locals 0, end
    var it = try iterOver(&.{ 1, 2, 0x00, 0x0B });
    try testing.expectEqual(@as(u32, 1), it.count);
    try expectEntry(&it, &.{ 2, 0x00, 0x0B }, &.{0x00}, &.{0x0B});
    try testing.expectEqual(null, try it.next());
}

test "code reader: locals are runs, and the body starts after them" {
    // two runs: 2 x i32, then 1 x v128
    const payload = [_]u8{ 1, 6, 0x02, 0x02, 0x7F, 0x01, 0x7B, 0x0B };
    var it = try iterOver(&payload);
    const entry = (try it.next()).?;
    try testing.expectEqualSlices(u8, &.{ 6, 0x02, 0x02, 0x7F, 0x01, 0x7B, 0x0B }, entry.bytes);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x02, 0x7F, 0x01, 0x7B }, entry.locals);
    try testing.expectEqualSlices(u8, &.{0x0B}, bodyBytes(entry));
    // The body window is absolute: it starts right after the locals and ends with the entry.
    try testing.expectEqual(@as(u32, 7), entry.body.pos);
    try testing.expectEqual(@as(u32, 8), entry.body.end);
    try testing.expectEqual(null, try it.next());
}

test "code reader: entries tile the payload after the count" {
    // entry 0: size 2, no locals; entry 1: size 4, one i32 local
    const payload = [_]u8{ 2, 2, 0x00, 0x0B, 4, 0x01, 0x01, 0x7F, 0x0B };
    var it = try iterOver(&payload);
    try testing.expectEqual(@as(u32, 2), it.count);
    try testing.expectEqual(@as(u32, 1), it.cursor.pos); // right after the count

    const first = (try it.next()).?;
    try testing.expectEqualSlices(u8, &.{ 2, 0x00, 0x0B }, first.bytes);
    try testing.expectEqual(@as(u32, 4), it.cursor.pos);

    const second = (try it.next()).?;
    try testing.expectEqualSlices(u8, &.{ 4, 0x01, 0x01, 0x7F, 0x0B }, second.bytes);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x01, 0x7F }, second.locals);
    try testing.expectEqual(@as(u32, payload.len), it.cursor.pos);

    try testing.expectEqual(null, try it.next());
}

test "code reader: a padded size LEB is part of the entry" {
    // size 2, encoded in three bytes
    const payload = [_]u8{ 1, 0x82, 0x80, 0x00, 0x00, 0x0B };
    var it = try iterOver(&payload);
    try expectEntry(&it, &.{ 0x82, 0x80, 0x00, 0x00, 0x0B }, &.{0x00}, &.{0x0B});
    try testing.expectEqual(null, try it.next());
}

test "code reader: a padded run count is part of the locals" {
    // one run, its count encoded in three bytes
    const payload = [_]u8{ 1, 6, 0x01, 0x81, 0x80, 0x00, 0x7F, 0x0B };
    var it = try iterOver(&payload);
    const entry = (try it.next()).?;
    try testing.expectEqualSlices(u8, &.{ 6, 0x01, 0x81, 0x80, 0x00, 0x7F, 0x0B }, entry.bytes);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x81, 0x80, 0x00, 0x7F }, entry.locals);
    try testing.expectEqualSlices(u8, &.{0x0B}, bodyBytes(entry));
    try testing.expectEqual(null, try it.next());
}

test "code reader: every representable value type is accepted as a local" {
    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        const payload = [_]u8{ 1, 4, 0x01, 0x01, byte, 0x0B };
        var it = try iterOver(&payload);
        if (spec.ValueType.fromByte(byte) != null) {
            const entry = (try it.next()).?;
            try testing.expectEqualSlices(u8, &.{ 0x01, 0x01, byte }, entry.locals);
            try testing.expectEqualSlices(u8, &.{0x0B}, bodyBytes(entry));
        } else if (byte == spec.ref_prefix_nullable or byte == spec.ref_prefix_non_nullable) {
            try testing.expectError(error.UnsupportedFeature, it.next());
        } else {
            try testing.expectError(error.InvalidValue, it.next());
        }
    }
}

test "code reader: the frame reader does not read instructions" {
    // The expression is the GC prefix, which `operators` refuses. The frame is still an entry.
    const payload = [_]u8{ 1, 3, 0x00, 0xFB, 0x0B };
    var it = try iterOver(&payload);
    const entry = (try it.next()).?;
    try testing.expectEqualSlices(u8, &.{ 0xFB, 0x0B }, bodyBytes(entry));
    try testing.expectEqual(null, try it.next());

    var ops = operators.BodyIter.init(entry.body);
    try testing.expectError(error.UnsupportedFeature, ops.next());
}

// ------------------------------------------------------------------ errors

test "code reader: errors at init" {
    try testing.expectError(error.Truncated, iterOver(&.{}));

    // A six-byte count.
    const six_byte_count = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 };
    try testing.expectError(error.MalformedLeb, iterOver(&six_byte_count));

    // Count 2, room for one entry.
    try testing.expectError(error.Truncated, iterOver(&.{ 2, 2, 0, 0x0B }));

    // Count u32 max, no data.
    const count_u32_max = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
    try testing.expectError(error.Truncated, iterOver(&count_u32_max));
}

test "code reader: errors while iterating" {
    // A size that runs past the payload.
    {
        var it = try iterOver(&.{ 1, 5, 0x00, 0x0B });
        try testing.expectError(error.Truncated, it.next());
    }
    // No room for the locals count.
    {
        var it = try iterOver(&.{ 1, 0, 0x00, 0x00 });
        try testing.expectError(error.Truncated, it.next());
    }
    // A run count with no run behind it.
    {
        var it = try iterOver(&.{ 1, 1, 0x01, 0x00 });
        try testing.expectError(error.Truncated, it.next());
    }
    // A run with no type.
    {
        var it = try iterOver(&.{ 1, 2, 0x01, 0x01 });
        try testing.expectError(error.Truncated, it.next());
    }
    // More runs than the bytes left could hold.
    {
        var it = try iterOver(&.{ 1, 3, 0x05, 0x00, 0x0B });
        try testing.expectError(error.Truncated, it.next());
    }
    // A run count that is not a u32.
    {
        var it = try iterOver(&.{ 1, 8, 0x01, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00, 0x0B });
        try testing.expectError(error.MalformedLeb, it.next());
    }
    // A six-byte size LEB.
    {
        var it = try iterOver(&.{ 1, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00, 0x00, 0x0B });
        try testing.expectError(error.MalformedLeb, it.next());
    }
}

test "code reader: trailing bytes" {
    // count 0 with data after it
    var empty = try iterOver(&.{ 0, 0xFF });
    try testing.expectError(error.TrailingBytes, empty.next());

    // a complete entry, then a stray byte
    var after = try iterOver(&.{ 1, 2, 0x00, 0x0B, 0xFF });
    try expectEntry(&after, &.{ 2, 0x00, 0x0B }, &.{0x00}, &.{0x0B});
    try testing.expectError(error.TrailingBytes, after.next());
}

test "code reader: a failed next does not advance, and fails the same way again" {
    const payload = [_]u8{ 1, 3, 0x09, 0x00, 0x0B }; // size 3, locals claim 9 runs
    var it = try iterOver(&payload);
    try testing.expectEqual(@as(u32, 1), it.cursor.pos);

    try testing.expectError(error.Truncated, it.next());
    try testing.expectEqual(@as(u32, 1), it.cursor.pos);
    try testing.expectEqual(@as(u32, 0), it.yielded);

    try testing.expectError(error.Truncated, it.next());
    try testing.expectEqual(@as(u32, 1), it.cursor.pos);
}

test "code reader: bytes outside the payload window are never read" {
    // One entry whose size LEB is three bytes, then a stray byte in the buffer.
    const buf = [_]u8{ 1, 0x82, 0x80, 0x00, 0x00, 0x0B, 0xEE };

    // A window that cuts the entry short: the end byte exists in the buffer, but not in the window.
    var c1 = try Cursor.init(&buf);
    var it1 = try code.Iterator.init(try c1.sub(5));
    try testing.expectError(error.Truncated, it1.next());

    // A window that ends exactly after the entry: the stray byte after it is not "trailing".
    var c2 = try Cursor.init(&buf);
    var it2 = try code.Iterator.init(try c2.sub(6));
    try expectEntry(&it2, &.{ 0x82, 0x80, 0x00, 0x00, 0x0B }, &.{0x00}, &.{0x0B});
    try testing.expectEqual(null, try it2.next());
}

// ---------------------------------------------------------------- fixtures

test "code reader: every fixture body parses, and its entries tile the section" {
    for (fixtures.all) |fixture| {
        const m = try Module.parse(fixture.bytes);
        const payload = m.payloadCursor(.code) orelse continue;
        const counts = try Counts.of(&m, .{});
        var it = try code.Iterator.init(payload);

        // A defined function has exactly one code entry.
        try testing.expectEqual(counts.defined[@backingInt(spec.ExternalKind.function)], it.count);

        var used = it.cursor.pos - payload.pos; // the count LEB
        while (try it.next()) |entry| {
            used += @as(u32, @intCast(entry.bytes.len));
            try testing.expect(entry.bytes.len >= 3);

            var ops = operators.BodyIter.init(entry.body);
            while (try ops.next()) |op| {
                try testing.expect(op.at >= entry.body.pos);
                try testing.expect(op.end <= entry.body.end);
            }
            try testing.expect(ops.finished); // the body's final `end` was consumed
            try testing.expect(ops.cursor.atEnd());
        }
        try testing.expectEqual(payload.end - payload.pos, used);
    }
}
