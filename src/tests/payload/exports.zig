const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const Cursor = @import("../../Cursor.zig");
const Module = @import("../../Module.zig");

const Iterator = @import("../../payload/exports.zig").Iterator;
const spec = @import("../../spec.zig");

const fixtures = @import("../fixtures/fixtures.zig");

fn iterOver(payload: []const u8) !Iterator {
    return Iterator.init(try Cursor.init(payload));
}

fn expectNext(it: *Iterator, name: []const u8, kind: spec.ExternalKind, index: u32) !void {
    const e = (try it.next()).?;
    try testing.expectEqualStrings(name, e.name);
    try testing.expectEqual(kind, e.kind);
    try testing.expectEqual(index, e.index);
}

/// True when the whole payload reads without an error.
fn parses(payload: []const u8) bool {
    var it = Iterator.init(Cursor.init(payload) catch return false) catch return false;
    while (it.next() catch return false) |_| {}
    return true;
}

fn reencode(payload: []const u8, out: *Io.Writer) !void {
    var it = try iterOver(payload);
    try out.writeLeb128(it.count);
    while (try it.next()) |e| {
        try out.writeLeb128(@as(u32, @intCast(e.name.len)));
        try out.writeAll(e.name);
        try out.writeByte(@backingInt(e.kind));
        try out.writeLeb128(e.index);
    }
}

/// Same entries, whatever the LEB widths.
fn expectSameEntries(a_bytes: []const u8, b_bytes: []const u8) !void {
    var a = try iterOver(a_bytes);
    var b = try iterOver(b_bytes);
    try testing.expectEqual(a.count, b.count);
    while (try a.next()) |x| {
        const y = (try b.next()).?;
        try testing.expectEqualStrings(x.name, y.name);
        try testing.expectEqual(x.kind, y.kind);
        try testing.expectEqual(x.index, y.index);
    }
    try testing.expectEqual(null, try b.next());
}

test "exports reader: zig_basic matches wasm-objdump -x" {
    const m = try Module.parse(fixtures.zig_basic);
    const payload = m.section(.@"export").?.payload;
    var it = try Iterator.init(m.payloadCursor(.@"export").?);

    try testing.expectEqual(@as(u32, 6), it.count);
    try testing.expectEqual(payload.start + 1, it.entries.start); // the count is one byte; offsets are absolute
    try testing.expectEqual(payload.end, it.entries.end);

    try expectNext(&it, "memory", .memory, 0);
    try expectNext(&it, "__stack_pointer", .global, 0);
    try expectNext(&it, "bump", .function, 0);
    try expectNext(&it, "apply", .function, 1);
    try expectNext(&it, "add", .function, 2);
    try expectNext(&it, "message", .global, 1);
    try testing.expectEqual(null, try it.next());
}

test "exports reader: minimal" {
    const m = try Module.parse(fixtures.minimal);
    var it = try Iterator.init(m.payloadCursor(.@"export").?);
    try testing.expectEqual(@as(u32, 3), it.count);
    try expectNext(&it, "add", .function, 0);
    try expectNext(&it, "memory", .memory, 0);
    try expectNext(&it, "counter", .global, 0);
    try testing.expectEqual(null, try it.next());
}

test "exports reader: mutated fixture payloads are rejected, or re-encode to the same entries" {
    var accepted: u32 = 0;
    var rejected: u32 = 0;
    for (fixtures.all) |f| {
        const m = try Module.parse(f.bytes);
        const original = m.section(.@"export").?.payload.slice(m.bytes);
        const buf = try testing.allocator.dupe(u8, original);
        defer testing.allocator.free(buf);

        for (0..buf.len) |i| {
            const orig_byte = original[i];
            for ([_]u8{ 0x00, 0xFF, orig_byte ^ 0x80, orig_byte +% 1 }) |value| {
                buf[i] = value;
                if (!parses(buf)) {
                    rejected += 1;
                    continue;
                }
                accepted += 1;

                var out: Io.Writer.Allocating = .init(testing.allocator);
                defer out.deinit();
                try reencode(buf, &out.writer);
                try expectSameEntries(buf, out.written());
            }
            buf[i] = orig_byte;
        }
    }
    try testing.expect(accepted > 0); // the re-encode check actually ran
    try testing.expect(rejected > 0); // the reader actually rejected things
}
