//! Tests of the type section reader and the shared signature writer.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const Cursor = @import("../../Cursor.zig");
const spec = @import("../../spec.zig");
const types = @import("../../payload/types.zig");

const Iterator = types.Iterator;
const Values = types.Values;

fn iterOver(payload: []const u8) !Iterator {
    return Iterator.init(try Cursor.init(payload));
}

fn expectValue(value: ?spec.ValueType, expected: spec.ValueType) !void {
    try testing.expect(value != null);
    try testing.expectEqualDeep(expected, value.?);
}

test "types Signature: encoded and typed values write the same bytes" {
    const i32_type = spec.ValueType{ .number_or_vector = .i32 };
    const i64_type = spec.ValueType{ .number_or_vector = .i64 };
    const signatures = [_]types.Signature{
        types.Signature.fromEntry(.{
            .params = &.{0x7F},
            .results = &.{ 0x7F, 0x7E },
        }),
        types.Signature.typed(&.{i32_type}, &.{ i32_type, i64_type }),
    };

    for (signatures) |signature| {
        try testing.expectEqual(@as(u32, 1), try signature.paramCount());
        try testing.expectEqual(@as(u32, 2), try signature.resultCount());

        var out: Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try signature.params.write(&out.writer);
        try signature.results.write(&out.writer);
        try testing.expectEqualSlices(u8, &.{ 1, 0x7F, 2, 0x7F, 0x7E }, out.written());
    }
}

test "types reader: zero entries" {
    var it = try iterOver(&.{0});
    try testing.expectEqual(@as(u32, 0), it.count);
    try testing.expectEqual(null, try it.next());
}

test "types Signature: encoded values are counted per byte, not with a count LEB" {
    const signature = types.Signature.fromEntry(.{
        .params = &.{ 0x7F, 0x7E }, // i32, i64: two value types, two bytes
        .results = &.{},
    });
    try testing.expectEqual(@as(u32, 2), try signature.paramCount());
    try testing.expectEqual(@as(u32, 0), try signature.resultCount());

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try signature.params.write(&out.writer);
    try signature.results.write(&out.writer);
    // `write` generates the vector count; the encoded slice did not contain it.
    try testing.expectEqualSlices(u8, &.{ 2, 0x7F, 0x7E, 0 }, out.written());
}

test "types reader: parameters, results, and the values iterator" {
    // one function type: (i32) -> (i32, i64)
    const payload = [_]u8{ 1, 0x60, 1, 0x7F, 2, 0x7F, 0x7E };
    var it = try iterOver(&payload);
    const entry = (try it.next()).?;

    try testing.expectEqualSlices(u8, &.{0x7F}, entry.params);
    try testing.expectEqualSlices(u8, &.{ 0x7F, 0x7E }, entry.results);

    var params = entry.paramValues();
    try expectValue(params.next(), .{ .number_or_vector = .i32 });
    try testing.expectEqual(null, params.next());

    var results = entry.resultValues();
    try expectValue(results.next(), .{ .number_or_vector = .i32 });
    try expectValue(results.next(), .{ .number_or_vector = .i64 });
    try testing.expectEqual(null, results.next());
    try testing.expectEqual(null, try it.next());
}

test "types reader: an empty function type and several entries" {
    const payload = [_]u8{
        2, 0x60, 0, 0, // () -> ()
        0x60, 1, 0x7F, 0, // (i32) -> ()
    };
    var it = try iterOver(&payload);
    try testing.expectEqual(@as(u32, 2), it.count);
    try testing.expectEqual(@as(u32, 1), it.entries.start);
    try testing.expectEqual(@as(u32, payload.len), it.entries.end);

    const first = (try it.next()).?;
    try testing.expectEqual(@as(usize, 0), first.params.len);
    try testing.expectEqual(@as(usize, 0), first.results.len);

    const second = (try it.next()).?;
    try testing.expectEqualSlices(u8, &.{0x7F}, second.params);
    try testing.expectEqual(@as(usize, 0), second.results.len);
    try testing.expectEqual(null, try it.next());
}

test "types reader: padded counts are accepted" {
    // count 1 padded, params count 1 padded, results count 0 padded
    const payload = [_]u8{ 0x81, 0x00, 0x60, 0x81, 0x00, 0x7F, 0x80, 0x00 };
    var it = try iterOver(&payload);
    try testing.expectEqual(@as(u32, 1), it.count);
    try testing.expectEqual(@as(u32, 2), it.entries.start);

    const entry = (try it.next()).?;
    try testing.expectEqualSlices(u8, &.{0x7F}, entry.params);
    try testing.expectEqual(@as(usize, 0), entry.results.len);
    try testing.expectEqual(null, try it.next());
}

test "types reader: a two-byte parameter count" {
    var payload: [135]u8 = undefined;
    payload[0] = 1; // one entry
    payload[1] = 0x60;
    payload[2] = 0x82; // 130 parameters
    payload[3] = 0x01;
    @memset(payload[4..][0..130], 0x7F);
    payload[4 + 130] = 0; // no results

    var it = try iterOver(&payload);
    const entry = (try it.next()).?;
    try testing.expectEqual(@as(usize, 130), entry.params.len);

    var values = entry.paramValues();
    var count: u32 = 0;
    while (values.next()) |value| {
        try testing.expectEqualDeep(spec.ValueType{ .number_or_vector = .i32 }, value);
        count += 1;
    }
    try testing.expectEqual(@as(u32, 130), count);
}

test "types reader: errors at init" {
    try testing.expectError(error.Truncated, iterOver(&.{})); // empty payload

    const six_byte_count = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 };
    try testing.expectError(error.MalformedLeb, iterOver(&six_byte_count));

    // count 2, room for one smallest entry
    try testing.expectError(error.Truncated, iterOver(&.{ 2, 0x60, 0, 0 }));

    const count_u32_max = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
    try testing.expectError(error.Truncated, iterOver(&count_u32_max));
}

test "types reader: only function types are accepted" {
    // the GC forms are features, not arbitrary invalid bytes
    for ([_]u8{ 0x4E, 0x50, 0x5E, 0x5F }) |form| {
        const payload = [_]u8{ 1, form, 0, 0 };
        var it = try iterOver(&payload);
        try testing.expectError(error.UnsupportedFeature, it.next());
    }
    var invalid = try iterOver(&.{ 1, 0x61, 0, 0 });
    try testing.expectError(error.InvalidValue, invalid.next());
}

test "types reader: truncated and invalid vectors" {
    // params end before the results count
    var cut = try iterOver(&.{ 1, 0x60, 1, 0x7F });
    try testing.expectError(error.Truncated, cut.next());

    // results claim one value with no byte behind it
    var results_cut = try iterOver(&.{ 1, 0x60, 0, 1 });
    try testing.expectError(error.Truncated, results_cut.next());

    // a byte that names no value type
    var bad_type = try iterOver(&.{ 1, 0x60, 1, 0x00 });
    try testing.expectError(error.InvalidValue, bad_type.next());

    // a prefixed reference type: legal wasm, not representable here
    var prefixed = try iterOver(&.{ 1, 0x60, 1, 0x63 });
    try testing.expectError(error.UnsupportedFeature, prefixed.next());

    // a six-byte parameter count
    var long_count = try iterOver(&.{ 1, 0x60, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00, 0 });
    try testing.expectError(error.MalformedLeb, long_count.next());
}

test "types reader: a failed next does not advance, and fails the same way again" {
    const payload = [_]u8{ 1, 0x60, 0, 1 }; // results count 1, nothing behind it
    var it = try iterOver(&payload);
    try testing.expectEqual(@as(u32, 1), it.cursor.pos); // right after the count

    try testing.expectError(error.Truncated, it.next());
    try testing.expectEqual(@as(u32, 1), it.cursor.pos);
    try testing.expectEqual(@as(u32, 0), it.yielded);
    try testing.expectError(error.Truncated, it.next());
}

test "types reader: trailing bytes" {
    var empty = try iterOver(&.{ 0, 0xFF }); // count 0 with data after it
    try testing.expectError(error.TrailingBytes, empty.next());

    const after_entry = [_]u8{ 1, 0x60, 0, 0, 0xFF };
    var it = try iterOver(&after_entry);
    try testing.expect((try it.next()) != null);
    try testing.expectError(error.TrailingBytes, it.next());
}

test "types reader: bytes outside the payload window are never read" {
    const buf = [_]u8{ 1, 0x60, 1, 0x7F, 0, 0xEE }; // one entry, then a stray byte

    // a window that cuts the results count: the entry is still an entry by its size
    var a = try Cursor.init(&buf);
    var cut = try Iterator.init(try a.sub(4));
    try testing.expectError(error.Truncated, cut.next());

    // a window that ends exactly after the entry: the stray byte is not trailing
    var b = try Cursor.init(&buf);
    var exact = try Iterator.init(try b.sub(5));
    try testing.expect((try exact.next()) != null);
    try testing.expectEqual(null, try exact.next());
}
