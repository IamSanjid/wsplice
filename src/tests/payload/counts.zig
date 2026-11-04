//! Tests of Counts: how many entities each index space has.
const std = @import("std");
const testing = std.testing;

const spec = @import("../../spec.zig");
const SectionId = spec.SectionId;
const Kind = spec.ExternalKind;
const Cursor = @import("../../Cursor.zig");
const Module = @import("../../Module.zig");
const Counts = @import("../../payload/Counts.zig");
const Diagnostics = @import("../../Diagnostics.zig");
const exports = @import("../../payload/exports.zig");
const support = @import("../support.zig");
const fixtures = @import("../fixtures/fixtures.zig");

const header = support.header;
const sec = support.sec;
const imp = support.importEntry;

// Arrays below are ordered by kind: function, table, memory, global, tag.
const Per = [5]u32;

fn expectCounts(bytes: []const u8, imported: Per, defined: Per) !void {
    const m = try Module.parse(bytes);
    const got = try Counts.of(&m, .{});
    try testing.expectEqualSlices(u32, &imported, &got.imported);
    try testing.expectEqualSlices(u32, &defined, &got.defined);
    for (0..5) |i| {
        const kind: Kind = @fromBackingInt(@intCast(i));
        try testing.expectEqual(imported[i] + defined[i], got.total(kind));
        try testing.expectEqual(imported[i], got.importedCount(kind));
    }
}

// ----------------------------------------------------------- real modules

test "Counts: the fixtures match wasm-objdump -x" {
    try expectCounts(fixtures.minimal, .{ 0, 0, 0, 0, 0 }, .{ 1, 0, 1, 1, 0 });
    try expectCounts(fixtures.zig_basic, .{ 0, 0, 0, 0, 0 }, .{ 3, 1, 1, 2, 0 });
    try expectCounts(fixtures.imports, .{ 1, 1, 1, 2, 0 }, .{ 2, 0, 0, 1, 0 });
}

test "Counts: the type section's declared count is the size of the type space" {
    const expected = [_]u32{ 1, 2, 1 }; // wasm-objdump -x: minimal, zig_basic, imports
    for (fixtures.all, expected) |f, types| {
        const m = try Module.parse(f.bytes);
        try testing.expectEqual(types, (try Counts.of(&m, .{})).typeCount());
    }

    const bytes = header ++ sec(1, &.{ 2, 0x60, 0, 0, 0x60, 0, 0 });
    const m = try Module.parse(&bytes);
    try testing.expectEqual(@as(u32, 2), (try Counts.of(&m, .{})).typeCount());
    try expectFails(&(header ++ sec(1, &.{})), error.Truncated, .type, 10);
}

// If imports were not counted, `own` (global 2 in imports.wasm) would be out of range.
test "Counts: every export of every fixture is inside its index space, imported entities included" {
    for (fixtures.all) |f| {
        const m = try Module.parse(f.bytes);
        const counts = try Counts.of(&m, .{});
        var it = try exports.Iterator.init(m.payloadCursor(.@"export").?);
        while (try it.next()) |e| {
            try testing.expect(e.index < counts.total(e.kind));
        }
    }

    const m = try Module.parse(fixtures.imports);
    const counts = try Counts.of(&m, .{});
    try testing.expectEqual(@as(u32, 3), counts.total(.global)); // `own` is global 2: the last valid index
    try testing.expectEqual(@as(u32, 3), counts.total(.function)); // `g` is function 2
}

// -------------------------------------------------------------- hand-built

test "Counts: a module with nothing has nothing" {
    try expectCounts(&header, .{ 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0 });
    try expectCounts(&(header ++ sec(0, &.{1})), .{ 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0 }); // customs only
}

test "Counts: each defined section counts for its own space (and the code section for none)" {
    const bytes = header ++
        sec(3, &.{ 2, 0, 0 }) ++ // function: 2
        sec(4, &.{ 1, 0x70, 0, 1 }) ++ // table: 1
        sec(5, &.{ 1, 0, 1 }) ++ // memory: 1
        sec(13, &.{ 1, 0, 0 }) ++ // tag: 1
        sec(6, &.{ 1, 0x7F, 0, 0x41, 0, 0x0B }) ++ // global: 1
        sec(10, &.{ 9, 0, 0, 0, 0, 0, 0, 0, 0, 0 }); // code: claims 9, must not matter
    try expectCounts(&bytes, .{ 0, 0, 0, 0, 0 }, .{ 2, 1, 1, 1, 1 });
}

// function x2, table x1, memory x1, global x3, tag x2
const many_imports = [_]u8{9} ++
    imp("e", "f1", &.{ 0x00, 0 }) ++ imp("e", "f2", &.{ 0x00, 1 }) ++
    imp("e", "t", &.{ 0x01, 0x70, 0x00, 1 }) ++
    imp("e", "m", &.{ 0x02, 0x00, 1 }) ++
    imp("e", "g1", &.{ 0x03, 0x7F, 0x00 }) ++ imp("e", "g2", &.{ 0x03, 0x7E, 0x01 }) ++ imp("e", "g3", &.{ 0x03, 0x70, 0x00 }) ++
    imp("e", "x1", &.{ 0x04, 0x00, 0 }) ++ imp("e", "x2", &.{ 0x04, 0x00, 1 });

test "Counts: imports are counted per kind, tags included" {
    try expectCounts(&(header ++ sec(2, &many_imports)), .{ 2, 1, 1, 3, 2 }, .{ 0, 0, 0, 0, 0 });
}

test "Counts: imported and defined entities add up" {
    const bytes = header ++
        sec(2, &many_imports) ++
        sec(3, &.{ 1, 0 }) ++ // one more function
        sec(6, &.{ 2, 0x7F, 0, 0x41, 0, 0x0B, 0x7F, 0, 0x41, 1, 0x0B }); // two more globals
    try expectCounts(&bytes, .{ 2, 1, 1, 3, 2 }, .{ 1, 0, 0, 2, 0 });
}

test "Counts: padded count LEBs" {
    try expectCounts(&(header ++ sec(3, &.{ 0x82, 0x80, 0x00, 0, 0 })), .{ 0, 0, 0, 0, 0 }, .{ 2, 0, 0, 0, 0 });
    try expectCounts(&(header ++ sec(2, &([_]u8{ 0x81, 0x80, 0x00 } ++ imp("e", "f", &.{ 0x00, 0 })))), .{ 1, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0 });
}

// Pins down the "declared, not verified" decision: the count is believed as long as it could be true.
test "Counts: a count that fits the bytes is believed, whatever the bytes are" {
    try expectCounts(&(header ++ sec(6, &.{ 1, 0xFF, 0xFF })), .{ 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 1, 0 });
    try expectCounts(&(header ++ sec(3, &.{ 0, 0xFF })), .{ 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0 }); // zero entities, stray byte
}

// ------------------------------------------------------------------ errors

/// The error comes back with and without diagnostics, and the diagnostics say where.
fn expectFails(bytes: []const u8, err: anyerror, section: SectionId, offset: u32) !void {
    const m = try Module.parse(bytes);
    var d: Diagnostics = .{};
    try testing.expectError(err, Counts.of(&m, .{ .diag = &d }));
    try testing.expectEqual(@as(?anyerror, err), d.err);
    try testing.expectEqual(@as(?SectionId, section), d.section);
    try testing.expectEqual(@as(?u32, offset), d.offset);
    try testing.expectError(err, Counts.of(&m, .{}));
}

const one_entry = imp("e", "f", &.{ 0x00, 0 });

test "Counts: a broken count in a defined section" {
    // payload offsets are absolute: 8 header + 1 id + 1 size = 10
    try expectFails(&(header ++ sec(3, &.{})), error.Truncated, .function, 10);
    try expectFails(&(header ++ sec(4, &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 })), error.MalformedLeb, .table, 10);
    try expectFails(&(header ++ sec(5, &.{ 3, 0, 1 })), error.Truncated, .memory, 10); // count 3, room for 2
    try expectFails(&(header ++ sec(6, &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F })), error.Truncated, .global, 10);
    try expectFails(&(header ++ sec(13, &.{})), error.Truncated, .tag, 10);
}

test "Counts: a broken import section says where, and which kind of broken" {
    try expectFails(&(header ++ sec(2, &.{})), error.Truncated, .import, 10);
    try expectFails(&(header ++ sec(2, &.{ 5, 0, 0, 0, 0 })), error.Truncated, .import, 10);
    // an entry that starts right after the one-byte count
    try expectFails(&(header ++ sec(2, &([_]u8{1} ++ imp("e", "f", &.{ 0x03, 0x7F, 0x02 })))), error.InvalidValue, .import, 11);
    try expectFails(&(header ++ sec(2, &([_]u8{1} ++ imp("e", "f", &.{ 0x03, 0x63, 0x00 })))), error.UnsupportedFeature, .import, 11);
    try expectFails(&(header ++ sec(2, &([_]u8{1} ++ imp("e", "f", &.{ 0x05, 0 })))), error.InvalidKind, .import, 11);
    // a valid entry, then a stray byte: the error points just after the entry
    try expectFails(&(header ++ sec(2, &([_]u8{1} ++ one_entry ++ [_]u8{0xFF}))), error.TrailingBytes, .import, 11 + one_entry.len);
}

test "Counts: the import section is read first, so its error wins over a later section's" {
    const bytes = header ++ sec(2, &([_]u8{1} ++ imp("e", "f", &.{ 0x03, 0x7F, 0x02 }))) ++ sec(3, &.{});
    try expectFails(&bytes, error.InvalidValue, .import, 11);
}

test "Counts: only the first failure is recorded" {
    const m = try Module.parse(&(header ++ sec(3, &.{}) ++ sec(4, &.{})));
    var d: Diagnostics = .{};
    try testing.expectError(error.Truncated, Counts.of(&m, .{ .diag = &d }));
    try testing.expectEqual(@as(?SectionId, .function), d.section); // function is read before table
}

// ------------------------------------------------------------------ sweep

fn firstLeb(payload: []const u8) !u32 {
    var c = try Cursor.init(payload);
    return c.readUleb(u32);
}

test "Counts: every value of every byte of an import payload is counted consistently or rejected" {
    var accepted: u32 = 0;
    var rejected: u32 = 0;

    const m0 = try Module.parse(fixtures.imports);
    const payload = m0.section(.import).?.payload;
    const buf = try testing.allocator.dupe(u8, fixtures.imports);
    defer testing.allocator.free(buf);

    for (payload.start..payload.end) |i| {
        const original = fixtures.imports[i];
        for (0..256) |value| {
            buf[i] = @intCast(value);
            const m = try Module.parse(buf); // only payload bytes changed: the container is intact
            const counts = Counts.of(&m, .{}) catch {
                rejected += 1;
                continue;
            };
            accepted += 1;

            var sum: u32 = 0;
            for (counts.imported) |n| sum += n;
            try testing.expectEqual(try firstLeb(m.section(.import).?.payload.slice(m.bytes)), sum);
            // the defined sections were not touched
            try testing.expectEqualSlices(u32, &[_]u32{ 2, 0, 0, 1, 0 }, &counts.defined);
        }
        buf[i] = original;
    }
    try testing.expect(accepted > 0); // the consistency checks actually ran
    try testing.expect(rejected > 0); // the reader actually rejected things
}
