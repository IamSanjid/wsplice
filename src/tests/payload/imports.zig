//! Tests of the import section reader.
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;

const spec = @import("../../spec.zig");
const Cursor = @import("../../Cursor.zig");
const Module = @import("../../Module.zig");
const imports = @import("../../payload/imports.zig");
const Iterator = imports.Iterator;
const Desc = imports.Desc;
const fixtures = @import("../fixtures/fixtures.zig");
const support = @import("../support.zig");

// ---------------------------------------------------------------- helpers

const imp = support.importEntry;

fn iterOver(payload: []const u8) !Iterator {
    return Iterator.init(try Cursor.init(payload));
}

/// The first error reading the whole payload produces, or null if it reads cleanly.
fn firstError(payload: []const u8) ?anyerror {
    var it = Iterator.init(Cursor.init(payload) catch |e| return e) catch |e| return e;
    while (it.next() catch |e| return e) |_| {}
    return null;
}

fn limits(min: u64, max: ?u64, shared: bool, is64: bool) spec.Limits {
    return .{
        .flags = .{ .has_max = max != null, .is_shared = shared, .is_64bit = is64 },
        .min = min,
        .max = max orelse 0,
    };
}

fn expectNext(it: *Iterator, module: []const u8, field: []const u8, desc: Desc) !void {
    const e = (try it.next()).?;
    try testing.expectEqualStrings(module, e.module);
    try testing.expectEqualStrings(field, e.field);
    try testing.expectEqualDeep(desc, e.desc);
}

/// A one-entry payload whose entry has the given kind byte and descriptor.
fn expectDesc(comptime rest: []const u8, expected: Desc) !void {
    const payload = [_]u8{1} ++ imp("m", "f", rest);
    var it = try iterOver(&payload);
    try expectNext(&it, "m", "f", expected);
    try testing.expectEqual(null, try it.next()); // the entry used exactly its bytes
}

// The same five imports as imports.wat, written byte by byte.
const sample = [_]u8{5} ++
    imp("env", "log", &.{ 0x00, 0 }) ++
    imp("env", "table", &.{ 0x01, 0x70, 0x01, 2, 10 }) ++
    imp("env", "memory", &.{ 0x02, 0x01, 1, 4 }) ++
    imp("env", "counter", &.{ 0x03, 0x7F, 0x01 }) ++
    imp("env", "limit", &.{ 0x03, 0x7F, 0x00 });

// ----------------------------------------------------------- real module

test "imports reader: imports.wasm matches wasm-objdump -x" {
    const m = try Module.parse(fixtures.imports);
    const payload = m.section(.import).?.payload;
    var it = try Iterator.init(m.payloadCursor(.import).?);

    try testing.expectEqual(@as(u32, 5), it.count);
    try testing.expectEqual(payload.start + 1, it.entries.start); // the count is one byte; offsets are absolute
    try testing.expectEqual(payload.end, it.entries.end);

    try expectNext(&it, "env", "log", .{ .function = 0 });
    try expectNext(&it, "env", "table", .{ .table = .{
        .reftype = .func,
        .limits = limits(2, 10, false, false),
    } });
    try expectNext(&it, "env", "memory", .{ .memory = limits(1, 4, false, false) });
    try expectNext(&it, "env", "counter", .{ .global = .{
        .valtype = .{ .number_or_vector = .i32 },
        .mutability = .mutable,
    } });
    try expectNext(&it, "env", "limit", .{ .global = .{
        .valtype = .{ .number_or_vector = .i32 },
        .mutability = .immutable,
    } });
    try testing.expectEqual(null, try it.next());
}

// Two independent routes to the same bytes: wabt wrote one, we wrote the other by hand.
test "imports reader: the hand-built sample is byte-identical to the fixture's import payload" {
    const m = try Module.parse(fixtures.imports);
    try testing.expectEqualSlices(u8, &sample, m.section(.import).?.payload.slice(m.bytes));
}

test "imports reader: modules without an import section have none" {
    for ([_][]const u8{ fixtures.minimal, fixtures.zig_basic }) |bytes| {
        const m = try Module.parse(bytes);
        try testing.expect(m.section(.import) == null);
    }
}

// ------------------------------------------------------- descriptor shapes

test "imports reader: every descriptor shape" {
    // function
    try expectDesc(&.{ 0x00, 7 }, .{ .function = 7 });
    try expectDesc(&.{ 0x00, 0x80, 0x01 }, .{ .function = 128 }); // a two-byte type index
    try expectDesc(&.{ 0x00, 0x85, 0x00 }, .{ .function = 5 }); // a padded one

    // table
    try expectDesc(&.{ 0x01, 0x70, 0x00, 1 }, .{ .table = .{
        .reftype = .func,
        .limits = limits(1, null, false, false),
    } });
    try expectDesc(&.{ 0x01, 0x6F, 0x01, 2, 10 }, .{ .table = .{
        .reftype = .@"extern",
        .limits = limits(2, 10, false, false),
    } });
    try expectDesc(&.{ 0x01, 0x70, 0x05, 1, 9 }, .{ .table = .{
        .reftype = .func,
        .limits = limits(1, 9, false, true),
    } });

    // memory
    try expectDesc(&.{ 0x02, 0x00, 1 }, .{ .memory = limits(1, null, false, false) });
    try expectDesc(&.{ 0x02, 0x01, 1, 4 }, .{ .memory = limits(1, 4, false, false) });
    try expectDesc(&.{ 0x02, 0x03, 1, 2 }, .{ .memory = limits(1, 2, true, false) });
    try expectDesc(&.{ 0x02, 0x05, 1, 9 }, .{ .memory = limits(1, 9, false, true) });
    try expectDesc(&.{ 0x02, 0x04, 0x80, 0x80, 0x80, 0x80, 0x10 }, .{ .memory = limits(@as(u64, 1) << 32, null, false, true) });

    // global: every value type, both mutabilities
    try expectDesc(&.{ 0x03, 0x7F, 0x00 }, .{ .global = .{
        .valtype = .{ .number_or_vector = .i32 },
        .mutability = .immutable,
    } });
    try expectDesc(&.{ 0x03, 0x7E, 0x01 }, .{ .global = .{
        .valtype = .{ .number_or_vector = .i64 },
        .mutability = .mutable,
    } });
    try expectDesc(&.{ 0x03, 0x7D, 0x00 }, .{ .global = .{
        .valtype = .{ .number_or_vector = .f32 },
        .mutability = .immutable,
    } });
    try expectDesc(&.{ 0x03, 0x7C, 0x01 }, .{ .global = .{
        .valtype = .{ .number_or_vector = .f64 },
        .mutability = .mutable,
    } });
    try expectDesc(&.{ 0x03, 0x7B, 0x00 }, .{ .global = .{
        .valtype = .{ .number_or_vector = .v128 },
        .mutability = .immutable,
    } });
    try expectDesc(&.{ 0x03, 0x70, 0x00 }, .{ .global = .{
        .valtype = .{ .reference = .func },
        .mutability = .immutable,
    } });
    try expectDesc(&.{ 0x03, 0x6F, 0x01 }, .{ .global = .{
        .valtype = .{ .reference = .@"extern" },
        .mutability = .mutable,
    } });

    // tag
    try expectDesc(&.{ 0x04, 0x00, 3 }, .{ .tag = 3 });
}

test "imports reader: every abstract heap type is a valid table element type and global type" {
    inline for (@typeInfo(spec.AbstractHeapType).@"enum".field_values) |value| {
        const heap_type: spec.AbstractHeapType = @fromBackingInt(value);
        try expectDesc(&.{ 0x01, value, 0x00, 1 }, .{ .table = .{
            .reftype = heap_type,
            .limits = limits(1, null, false, false),
        } });
        try expectDesc(&.{ 0x03, value, 0x00 }, .{ .global = .{
            .valtype = .{ .reference = heap_type },
            .mutability = .immutable,
        } });
        try expectDesc(&.{ 0x03, value, 0x01 }, .{ .global = .{
            .valtype = .{ .reference = heap_type },
            .mutability = .mutable,
        } });
    }
}

// ------------------------------------------------------------ names, counts

test "imports reader: names are raw bytes" {
    const payload = [_]u8{3} ++
        imp("", "", &.{ 0x00, 0 }) ++
        imp("a\x00b", "\xFF\xFE", &.{ 0x00, 1 }) ++ // not UTF-8: the reader does not judge
        imp("env", "", &.{ 0x00, 2 });
    var it = try iterOver(&payload);
    try expectNext(&it, "", "", .{ .function = 0 });
    try expectNext(&it, "a\x00b", "\xFF\xFE", .{ .function = 1 });
    try expectNext(&it, "env", "", .{ .function = 2 });
    try testing.expectEqual(null, try it.next());
}

test "imports reader: a 128-byte module name and a two-byte type index" {
    const long: [128]u8 = @splat('m');
    var w: Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();
    try w.writer.writeByte(1); // count
    try w.writer.writeLeb128(@as(u32, 128)); // name length: 0x80 0x01
    try w.writer.writeAll(&long);
    try w.writer.writeAll(&.{ 1, 'f', 0x00 }); // field, function
    try w.writer.writeLeb128(@as(u32, 300)); // type index

    var it = try iterOver(w.written());
    try expectNext(&it, &long, "f", .{ .function = 300 });
    try testing.expectEqual(null, try it.next());
}

test "imports reader: a padded count moves the entries span" {
    const payload = [_]u8{ 0x82, 0x80, 0x00 } ++ imp("e", "a", &.{ 0x00, 0 }) ++ imp("e", "b", &.{ 0x00, 1 });
    var it = try iterOver(&payload);
    try testing.expectEqual(@as(u32, 2), it.count);
    try testing.expectEqual(@as(u32, 3), it.entries.start);
    try testing.expectEqual(@as(u32, payload.len), it.entries.end);
    try expectNext(&it, "e", "a", .{ .function = 0 });
    try expectNext(&it, "e", "b", .{ .function = 1 });
    try testing.expectEqual(null, try it.next());
}

test "imports reader: zero entries, and the smallest possible entry" {
    var empty = try iterOver(&.{0});
    try testing.expectEqual(@as(u32, 0), empty.count);
    try testing.expectEqual(null, try empty.next());

    var smallest = try iterOver(&.{ 1, 0, 0, 0, 0 }); // "" "" function type 0: four bytes
    try expectNext(&smallest, "", "", .{ .function = 0 });
    try testing.expectEqual(null, try smallest.next());
}

// ------------------------------------------------------------------ errors

test "imports reader: errors at init" {
    try testing.expectError(error.Truncated, iterOver(&.{})); // empty payload
    try testing.expectError(error.MalformedLeb, iterOver(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 })); // six-byte count
    try testing.expectError(error.Truncated, iterOver(&.{ 1, 0, 0, 0 })); // count 1, room for none (3 < 4 bytes)
    try testing.expectError(error.Truncated, iterOver(&.{ 5, 0, 0, 0, 0 })); // count 5, room for one
    try testing.expectError(error.Truncated, iterOver(&.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F })); // count u32 max
}

const Bad = struct { name: []const u8, payload: []const u8, err: anyerror };

fn bad(comptime name: []const u8, comptime rest: []const u8, comptime err: anyerror) Bad {
    return .{ .name = name, .payload = &([_]u8{1} ++ imp("e", "f", rest)), .err = err };
}

const bad_cases = [_]Bad{
    bad("unknown kind 5", &.{ 0x05, 0 }, error.InvalidKind),
    bad("unknown kind 0xFF", &.{ 0xFF, 0 }, error.InvalidKind),

    bad("table: a typed reference", &.{ 0x01, 0x63, 0x00, 1 }, error.UnsupportedFeature),
    bad("table: a value type, not a reference type", &.{ 0x01, 0x7F, 0x00, 1 }, error.InvalidValue),
    bad("table: type byte 0", &.{ 0x01, 0x00, 0x00, 1 }, error.InvalidValue),
    bad("global: ref null <heap type>", &.{ 0x03, 0x63, 0x00 }, error.UnsupportedFeature),
    bad("global: ref <heap type>", &.{ 0x03, 0x64, 0x00 }, error.UnsupportedFeature),
    bad("global: type byte 0", &.{ 0x03, 0x00, 0x00 }, error.InvalidValue),
    bad("global: type byte 0xFF", &.{ 0x03, 0xFF, 0x00 }, error.InvalidValue),

    bad("global: mutability 2", &.{ 0x03, 0x7F, 0x02 }, error.InvalidValue),
    bad("global: mutability 0xFF", &.{ 0x03, 0x7F, 0xFF }, error.InvalidValue),
    bad("tag: attribute 1", &.{ 0x04, 0x01, 0 }, error.InvalidValue),

    bad("memory: custom page sizes flag", &.{ 0x02, 0x08, 1 }, error.UnsupportedFeature),
    bad("table: unknown limits flag", &.{ 0x01, 0x70, 0x10, 1 }, error.UnsupportedFeature),

    bad("function: six-byte type index", &.{ 0x00, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }, error.MalformedLeb),
    bad("memory: six-byte min", &.{ 0x02, 0x00, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }, error.MalformedLeb),

    bad("function: no type index", &.{0x00}, error.Truncated),
    bad("table: no element type", &.{0x01}, error.Truncated),
    bad("table: no limits", &.{ 0x01, 0x70 }, error.Truncated),
    bad("memory: no limits", &.{0x02}, error.Truncated),
    bad("global: no type", &.{0x03}, error.Truncated),
    bad("global: no mutability", &.{ 0x03, 0x7F }, error.Truncated),
    bad("tag: no attribute", &.{0x04}, error.Truncated),
    bad("tag: no type index", &.{ 0x04, 0x00 }, error.Truncated),
};

test "imports reader: malformed and unsupported descriptors" {
    for (bad_cases) |c| {
        testing.expectEqual(@as(?anyerror, c.err), firstError(c.payload)) catch |err| {
            std.debug.print("case failed: {s}\n", .{c.name});
            return err;
        };
    }
}

test "imports reader: every strict prefix of the sample is truncated" {
    for (0..sample.len) |len| {
        try testing.expectEqual(@as(?anyerror, error.Truncated), firstError(sample[0..len]));
    }
    try testing.expectEqual(@as(?anyerror, null), firstError(&sample));
}

test "imports reader: trailing bytes" {
    const after_entry = [_]u8{1} ++ imp("e", "f", &.{ 0x00, 0 }) ++ [_]u8{0xFF};
    var it = try iterOver(&after_entry);
    try expectNext(&it, "e", "f", .{ .function = 0 }); // the entry itself is fine
    try testing.expectError(error.TrailingBytes, it.next());

    var empty = try iterOver(&.{ 0, 0xFF }); // count 0 with data after it
    try testing.expectError(error.TrailingBytes, empty.next());
}

test "imports reader: a failed next() does not advance, and fails the same way again" {
    const payload = [_]u8{1} ++ imp("e", "f", &.{ 0x03, 0x7F, 0x02 }); // mutability 2
    var it = try iterOver(&payload);
    try testing.expectEqual(@as(u32, 1), it.cursor.pos); // right after the count

    try testing.expectError(error.InvalidValue, it.next());
    try testing.expectEqual(@as(u32, 1), it.cursor.pos);
    try testing.expectEqual(@as(u32, 0), it.yielded);

    try testing.expectError(error.InvalidValue, it.next());
    try testing.expectEqual(@as(u32, 1), it.cursor.pos);
}

test "imports reader: bytes outside the payload window are never read" {
    const buf = [_]u8{1} ++ imp("e", "f", &.{ 0x00, 0 }) ++ [_]u8{0xEE}; // 7 payload bytes, then a stray one

    var c1 = try Cursor.init(&buf);
    var it1 = try Iterator.init(try c1.sub(6)); // cuts the type index off
    try testing.expectError(error.Truncated, it1.next());

    var c2 = try Cursor.init(&buf);
    var it2 = try Iterator.init(try c2.sub(7)); // ends exactly after the entry
    try expectNext(&it2, "e", "f", .{ .function = 0 });
    try testing.expectEqual(null, try it2.next()); // the stray byte is not "trailing"
}

// ------------------------------------------------------------------ sweep

fn inside(buf: []const u8, s: []const u8) bool {
    const start = @intFromPtr(buf.ptr);
    const p = @intFromPtr(s.ptr);
    return p >= start and p + s.len <= start + buf.len;
}

test "imports reader: every value of every byte of the sample is read cleanly or rejected" {
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

            // anything accepted yielded `count` entries, whose names lie inside the buffer
            var it = try iterOver(&buf);
            var n: u32 = 0;
            while (try it.next()) |e| : (n += 1) {
                try testing.expect(inside(&buf, e.module));
                try testing.expect(inside(&buf, e.field));
            }
            try testing.expectEqual(it.count, n);
        }
        buf[i] = original;
    }
    try testing.expect(accepted > 0); // the checks on accepted input actually ran
    try testing.expect(rejected > 0); // the reader actually rejected things
}
