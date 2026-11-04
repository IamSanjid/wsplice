//! Tests of the global section reader and writer.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const spec = @import("../../spec.zig");
const Cursor = @import("../../Cursor.zig");
const Module = @import("../../Module.zig");
const globals = @import("../../payload/globals.zig");
const Iterator = globals.Iterator;
const fixtures = @import("../fixtures/fixtures.zig");
const support = @import("../support.zig");

fn iterOver(payload: []const u8) !Iterator {
    return Iterator.init(try Cursor.init(payload));
}

fn expectEntry(
    it: *Iterator,
    value_type: spec.ValueType,
    mutability: spec.Mutability,
    instructions: []const u8,
) !void {
    const entry = (try it.next()).?;
    try testing.expectEqualDeep(value_type, entry.global_type.valtype);
    try testing.expectEqual(mutability, entry.global_type.mutability);
    try testing.expectEqualSlices(u8, instructions, entry.instructions);
}

/// The first error reading the whole payload produces, or null if it reads cleanly.
fn firstError(payload: []const u8) ?anyerror {
    var it = Iterator.init(Cursor.init(payload) catch |e| return e) catch |e| return e;
    while (it.next() catch |e| return e) |_| {}
    return null;
}

fn inside(buf: []const u8, s: []const u8) bool {
    const start = @intFromPtr(buf.ptr);
    const p = @intFromPtr(s.ptr);
    return p >= start and p + s.len <= start + buf.len;
}

// ----------------------------------------------------------- real modules

test "globals reader: the fixtures match wasm-objdump -s -j Global" {
    {
        const m = try Module.parse(fixtures.minimal);
        var it = try Iterator.init(m.payloadCursor(.global).?);
        try testing.expectEqual(@as(u32, 1), it.count);
        try expectEntry(&it, .{ .number_or_vector = .i32 }, .mutable, &.{ 0x41, 0x2A });
        try testing.expectEqual(null, try it.next());
    }
    {
        // Two globals, both `i32.const 1048576`: the immediate is a four-byte LEB, not two.
        const m = try Module.parse(fixtures.zig_basic);
        var it = try Iterator.init(m.payloadCursor(.global).?);
        try testing.expectEqual(@as(u32, 2), it.count);
        try expectEntry(
            &it,
            .{ .number_or_vector = .i32 },
            .mutable,
            &.{ 0x41, 0x80, 0x80, 0xC0, 0x00 },
        );
        try expectEntry(
            &it,
            .{ .number_or_vector = .i32 },
            .immutable,
            &.{ 0x41, 0x80, 0x80, 0xC0, 0x00 },
        );
        try testing.expectEqual(null, try it.next());
    }
    {
        // Only the module's own global is in the section; the two imported ones are not.
        const m = try Module.parse(fixtures.imports);
        var it = try Iterator.init(m.payloadCursor(.global).?);
        try testing.expectEqual(@as(u32, 1), it.count);
        try expectEntry(&it, .{ .number_or_vector = .i32 }, .immutable, &.{ 0x41, 0x07 });
        try testing.expectEqual(null, try it.next());
    }
}

// ------------------------------------------------------- entries, argument

test "globals reader: every value type, both mutabilities" {
    var seen: u32 = 0;
    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        const value_type = spec.ValueType.fromByte(byte) orelse continue;
        seen += 1;
        for ([_]spec.Mutability{ .immutable, .mutable }) |mutability| {
            const payload = [_]u8{ 1, byte, @backingInt(mutability), 0x41, 0x00, 0x0B };
            var it = try iterOver(&payload);
            try expectEntry(&it, value_type, mutability, &.{ 0x41, 0x00 });
            try testing.expectEqual(null, try it.next());
        }
    }
    try testing.expectEqual(17, seen); // five number/vector types and twelve heap types
}

test "globals reader: a padded count moves the entries span, and the entries copy verbatim" {
    const payload = [_]u8{ 0x82, 0x80, 0x00 } ++
        support.globalEntry(0x7F, .mutable, &.{ 0x41, 0x01 }) ++
        support.globalEntry(0x70, .immutable, &.{ 0xD0, 0x70 });
    var it = try iterOver(&payload);
    try testing.expectEqual(@as(u32, 2), it.count);
    try testing.expectEqual(@as(u32, 3), it.entries.start);
    try testing.expectEqual(@as(u32, @intCast(payload.len)), it.entries.end);
    // The span is what an edit copies to keep the old globals: byte for byte, count excluded.
    try testing.expectEqualSlices(u8, payload[3..], it.entries.slice(&payload));

    try expectEntry(&it, .{ .number_or_vector = .i32 }, .mutable, &.{ 0x41, 0x01 });
    try expectEntry(&it, .{ .reference = .func }, .immutable, &.{ 0xD0, 0x70 });
    try testing.expectEqual(null, try it.next());
}

test "globals reader: zero globals, and the smallest possible entry" {
    var empty = try iterOver(&.{0});
    try testing.expectEqual(@as(u32, 0), empty.count);
    try testing.expectEqual(null, try empty.next());
    try testing.expectEqual(empty.entries.start, empty.entries.end);

    // A value type, a mutability, and `end`: three bytes, the least an entry can take. Structurally
    // complete; validation rejects an initializer that produces no value.
    var smallest = try iterOver(&[_]u8{ 1, 0x7F, 0x00, 0x0B });
    try expectEntry(&smallest, .{ .number_or_vector = .i32 }, .immutable, &.{});
    try testing.expectEqual(null, try smallest.next());
}

// ------------------------------------------------------------------ errors

test "globals reader: errors at init" {
    try testing.expectError(error.Truncated, iterOver(&.{})); // empty payload

    // A six-byte count.
    const six_byte_count = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 };
    try testing.expectError(error.MalformedLeb, iterOver(&six_byte_count));

    try testing.expectError(error.Truncated, iterOver(&.{ 1, 0x7F })); // count 1, one byte left
    try testing.expectError(error.Truncated, iterOver(&.{ 5, 0x7F, 0, 0x41, 0, 0x0B })); // room for one
    const count_u32_max = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
    try testing.expectError(error.Truncated, iterOver(&count_u32_max));
}

const Bad = struct { name: []const u8, payload: []const u8, err: anyerror };

fn bad(comptime name: []const u8, comptime rest: []const u8, comptime err: anyerror) Bad {
    return .{ .name = name, .payload = &([_]u8{1} ++ rest[0..rest.len].*), .err = err };
}

const bad_cases = [_]Bad{
    bad("type byte 0", &.{ 0x00, 0x00, 0x0B }, error.InvalidValue),
    bad("type byte 0x7A", &.{ 0x7A, 0x00, 0x0B }, error.InvalidValue),
    bad("type byte 0xFF", &.{ 0xFF, 0x00, 0x0B }, error.InvalidValue),
    bad("ref null ht", &.{ 0x63, 0x00, 0x00, 0x0B }, error.UnsupportedFeature),
    bad("ref ht", &.{ 0x64, 0x00, 0x00, 0x0B }, error.UnsupportedFeature),

    bad("mutability 2", &.{ 0x7F, 0x02, 0x0B }, error.InvalidValue),
    bad("mutability 0xFF", &.{ 0x7F, 0xFF, 0x0B }, error.InvalidValue),

    bad("no mutability", &.{0x7F}, error.Truncated),
    bad("no initializer", &.{ 0x7F, 0x00 }, error.Truncated),
    bad("no immediate after i32.const", &.{ 0x7F, 0x00, 0x41 }, error.Truncated),
    bad("no `end`", &.{ 0x7F, 0x00, 0x41, 0x00 }, error.Truncated),

    bad("an instruction a constant may not use", &.{ 0x7F, 0x00, 0x20, 0x00, 0x0B }, error.UnsupportedFeature),
    bad("the GC prefix", &.{ 0x7F, 0x00, 0xFB, 0x0B }, error.UnsupportedFeature),
    bad("a six-byte immediate", &.{
        0x7F, 0x00, 0x41, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00, 0x0B,
    }, error.MalformedLeb),
};

test "globals reader: malformed and unsupported entries" {
    for (bad_cases) |c| {
        testing.expectEqual(@as(?anyerror, c.err), firstError(c.payload)) catch |err| {
            std.debug.print("case failed: {s}\n", .{c.name});
            return err;
        };
    }
}

const sample = [_]u8{3} ++
    support.globalEntry(0x7F, .mutable, &.{ 0x41, 0x2A }) ++
    support.globalEntry(0x70, .immutable, &.{ 0xD0, 0x70 }) ++
    support.globalEntry(0x7B, .immutable, &.{
        0xFD, 0x0C, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    });

test "globals reader: every strict prefix of the sample is truncated" {
    for (0..sample.len) |len| {
        try testing.expectEqual(@as(?anyerror, error.Truncated), firstError(sample[0..len]));
    }
    try testing.expectEqual(@as(?anyerror, null), firstError(&sample));
}

test "globals reader: trailing bytes" {
    const after_entry = [_]u8{1} ++
        support.globalEntry(0x7F, .mutable, &.{ 0x41, 0x00 }) ++ [_]u8{0xFF};
    var it = try iterOver(&after_entry);
    try expectEntry(&it, .{ .number_or_vector = .i32 }, .mutable, &.{ 0x41, 0x00 });
    try testing.expectError(error.TrailingBytes, it.next());

    var empty = try iterOver(&.{ 0, 0xFF }); // count 0 with data after it
    try testing.expectError(error.TrailingBytes, empty.next());
}

test "globals reader: a failed next() does not advance, and fails the same way again" {
    const payload = [_]u8{ 1, 0x7F, 0x02, 0x0B }; // mutability 2
    var it = try iterOver(&payload);
    try testing.expectEqual(@as(u32, 1), it.cursor.pos); // right after the count

    try testing.expectError(error.InvalidValue, it.next());
    try testing.expectEqual(@as(u32, 1), it.cursor.pos);
    try testing.expectEqual(@as(u32, 0), it.yielded);

    try testing.expectError(error.InvalidValue, it.next());
    try testing.expectEqual(@as(u32, 1), it.cursor.pos);
}

test "globals reader: bytes outside the payload window are never read" {
    const buf = [_]u8{ 1, 0x7F, 0x00, 0x41, 0x2A, 0x0B, 0xEE };

    var c1 = try Cursor.init(&buf);
    var it1 = try Iterator.init(try c1.sub(5)); // cuts the initializer's `end` off
    try testing.expectError(error.Truncated, it1.next());

    var c2 = try Cursor.init(&buf);
    var it2 = try Iterator.init(try c2.sub(6)); // ends exactly after the entry
    try expectEntry(&it2, .{ .number_or_vector = .i32 }, .immutable, &.{ 0x41, 0x2A });
    try testing.expectEqual(null, try it2.next()); // the stray byte is not "trailing"
}

// ------------------------------------------------------------------ writer

test "globals writer: every global type shape" {
    const cases = [_]struct {
        global_type: globals.Type,
        bytes: []const u8,
    }{
        .{
            .global_type = .{
                .valtype = .{ .number_or_vector = .i32 },
                .mutability = .immutable,
            },
            .bytes = &.{ 0x7F, 0x00 },
        },
        .{
            .global_type = .{
                .valtype = .{ .number_or_vector = .i64 },
                .mutability = .mutable,
            },
            .bytes = &.{ 0x7E, 0x01 },
        },
        .{
            .global_type = .{
                .valtype = .{ .number_or_vector = .f32 },
                .mutability = .immutable,
            },
            .bytes = &.{ 0x7D, 0x00 },
        },
        .{
            .global_type = .{
                .valtype = .{ .number_or_vector = .f64 },
                .mutability = .mutable,
            },
            .bytes = &.{ 0x7C, 0x01 },
        },
        .{
            .global_type = .{
                .valtype = .{ .number_or_vector = .v128 },
                .mutability = .immutable,
            },
            .bytes = &.{ 0x7B, 0x00 },
        },
        .{
            .global_type = .{
                .valtype = .{ .reference = .func },
                .mutability = .mutable,
            },
            .bytes = &.{ 0x70, 0x01 },
        },
        .{
            .global_type = .{
                .valtype = .{ .reference = .@"extern" },
                .mutability = .immutable,
            },
            .bytes = &.{ 0x6F, 0x00 },
        },
    };

    for (cases) |case| {
        var out: Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try globals.writeType(case.global_type, &out.writer);
        try testing.expectEqualSlices(u8, case.bytes, out.written());
    }
}

// ------------------------------------------------------------------ sweep

test "globals reader: every value of every byte of the sample is read cleanly or rejected" {
    var accepted: u32 = 0;
    var rejected: u32 = 0;
    var buf: [sample.len]u8 = sample;

    for (0..buf.len) |i| {
        const original = sample[i];
        for (0..256) |value| {
            buf[i] = @intCast(value);
            if (firstError(&buf) != null) {
                rejected += 1;
                continue;
            }
            accepted += 1;

            // Anything accepted yielded `count` entries whose instructions lie inside the buffer.
            var it = try iterOver(&buf);
            var n: u32 = 0;
            while (try it.next()) |entry| : (n += 1) {
                try testing.expect(inside(&buf, entry.instructions));
            }
            try testing.expectEqual(it.count, n);
        }
        buf[i] = original;
    }
    try testing.expect(accepted > 0); // the checks on accepted input actually ran
    try testing.expect(rejected > 0); // the reader actually rejected things
}
