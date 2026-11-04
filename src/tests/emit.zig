//! Tests of the public emit API: replace, insert, sizes, fixtures, sweeps.
//! Tests that need private functions (emitWalk, sectionHeaderLen, writeSection) stay in emit.zig.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const spec = @import("../spec.zig");
const SectionId = spec.SectionId;
const section_id_count = spec.section_id_count;
const Module = @import("../Module.zig");
const Patch = @import("../Patch.zig");
const Run = @import("../Run.zig");
const Edit = @import("../edit.zig").Edit;
const emit_mod = @import("../emit.zig");
const t = @import("support.zig");
const fixtures = @import("fixtures/fixtures.zig");

const emit = emit_mod.emit;
const outputLen = emit_mod.outputLen;
const header = t.header;
const sec = t.sec;
const rawEdit = t.rawEdit;
const expectEmit = t.expectEmit;

fn patchOne(id: SectionId, bytes: []const u8) !Patch {
    var p = Patch.empty;
    try p.setPayload(id, rawEdit(bytes));
    return p;
}

/// Payload for section `id` is { id, 0xEE }: unique per section, so a wrong slot shows up in the bytes.
fn fillStore(store: *[section_id_count][2]u8) void {
    for (store, 0..) |*p, i| p.* = .{ @intCast(i), 0xEE };
}

fn expectExactFit(bytes: []const u8, patch: *const Patch, expected_len: u32) !void {
    const m = try Module.parse(bytes);
    const need = try outputLen(&m, patch, .{});
    try testing.expectEqual(expected_len, need);

    var buf: [64]u8 = undefined;
    var w1: Io.Writer = .fixed(buf[0..need]);
    try emit(&m, patch, &w1, .{});
    try testing.expectEqual(need, w1.buffered().len);

    var w2: Io.Writer = .fixed(buf[0 .. need - 1]);
    try testing.expectError(error.WriteFailed, emit(&m, patch, &w2, .{}));
}

fn expectDeterministic(bytes: []const u8, patch: *const Patch) !void {
    const m = try Module.parse(bytes);
    var a: Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    try emit(&m, patch, &a.writer, .{});
    try emit(&m, patch, &b.writer, .{});
    try testing.expectEqualSlices(u8, a.written(), b.written());
}

/// Every section of `before` appears unchanged and in order in `after`. Sections `before` lacks are the
/// new ones: there must be exactly `added_count` of them. Only for insert-only patches.
fn expectOriginalsUntouched(before: Module, after: Module, added_count: u32) !void {
    var a_it = before.iterator();
    var b_it = after.iterator();
    var added: u32 = 0;
    while (try b_it.next()) |b| {
        if (b.id != .custom and before.section(b.id) == null) {
            added += 1;
            continue;
        }
        const a = (try a_it.next()).?;
        try testing.expectEqual(a.id, b.id);
        try testing.expectEqualSlices(u8, a.whole().slice(before.bytes), b.whole().slice(after.bytes));
    }
    try testing.expectEqual(null, try a_it.next());
    try testing.expectEqual(added_count, added);
}

fn expectIdentity(bytes: []const u8) !void {
    const m = try Module.parse(bytes);
    const patch = Patch.empty;

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try emit(&m, &patch, &out.writer, .{});

    try testing.expectEqualSlices(u8, bytes, out.written());
    try testing.expectEqual(@as(u32, @intCast(bytes.len)), try outputLen(&m, &patch, .{}));
    try t.expectTiles(out.written());
}

test "emit: identity on hand-built modules" {
    const cases = [_][]const u8{
        &t.header, // header only: outputLen is 8
        &(t.header ++ t.sec(1, &.{ 0x60, 0, 0 })),
        &(t.header ++ t.sec(0, &.{1}) ++ t.sec(0, &.{2})), // customs only
        &(t.header ++ [_]u8{ 1, 0x83, 0x80, 0x80, 0x80, 0x00, 1, 2, 3 }), // padded size LEB
        &(t.header ++ t.sec(1, &.{1}) ++ t.sec(3, &.{2}) ++ t.sec(0, &.{3}) ++ t.sec(10, &.{4}) ++ t.sec(0, &.{5})),
    };
    for (cases) |bytes| try expectIdentity(bytes);
}

test "emit: identity on the fixtures" {
    for (fixtures.all) |f| try expectIdentity(f.bytes);
}

test "emit: with an empty patch, an exact-size writer succeeds and one byte short fails" {
    const bytes = t.header ++ t.sec(1, &.{ 1, 2, 3 }) ++ t.sec(3, &.{4});
    const m = try Module.parse(&bytes);
    const patch = Patch.empty;

    var exact: [bytes.len]u8 = undefined;
    var w1: Io.Writer = .fixed(&exact);
    try emit(&m, &patch, &w1, .{});
    try testing.expectEqualSlices(u8, &bytes, w1.buffered());

    var short: [bytes.len - 1]u8 = undefined;
    var w2: Io.Writer = .fixed(&short);
    try testing.expectError(error.WriteFailed, emit(&m, &patch, &w2, .{}));
}

test "emit: an edit that fails in the measure pass writes nothing" {
    // One defined function, so the only valid function index is 0.
    const bytes = t.header ++ t.sec(3, &t.vec(1, &.{0}));
    const m = try Module.parse(&bytes);

    var patch = Patch.empty;
    try patch.setPayload(.@"export", .{ .add_exports = .{ .entries = &.{.{
        .name = "f",
        .target = .{ .function = .{ .input = 1 } },
    }} } });

    // The measure pass runs every edit before the first byte is written, so a bad patch cannot
    // leave a half-written module behind. `WriteFailed` is the only error a writer can cause.
    var buf: [64]u8 = @splat(0xAA);
    const before = buf;
    var writer: Io.Writer = .fixed(&buf);

    try testing.expectError(error.IndexOutOfRange, emit(&m, &patch, &writer, .{}));
    try testing.expectEqual(0, writer.buffered().len);
    try testing.expectEqualSlices(u8, &before, &buf);
}

test "emit: any mutated input that still parses is reproduced exactly by an empty patch" {
    var accepted: u32 = 0;
    var rejected: u32 = 0;
    var buf: [t.mutation_base.len]u8 = t.mutation_base;
    var out: [t.mutation_base.len]u8 = undefined;
    for (0..buf.len) |i| {
        const original = t.mutation_base[i];
        for ([_]u8{ 0x00, 0xFF, original ^ 0x80, original +% 1 }) |value| {
            buf[i] = value;
            const m = Module.parse(&buf) catch {
                rejected += 1;
                continue;
            };
            accepted += 1;
            var w: Io.Writer = .fixed(&out);
            try emit(&m, &Patch.empty, &w, .{});
            try testing.expectEqualSlices(u8, &buf, w.buffered());
        }
        buf[i] = original;
    }
    try testing.expect(accepted > 0); // the identity check actually ran
    try testing.expect(rejected > 0); // the gate actually rejected things
}

// ------------------------------------------------------------ case tables

const SectionEdit = struct { id: SectionId, bytes: []const u8 };

const Case = struct {
    name: []const u8,
    base: []const u8,
    edits: []const SectionEdit,
    expected: []const u8,
};

fn expectCases(cases: []const Case) !void {
    for (cases) |c| {
        var p = Patch.empty;
        for (c.edits) |e| try p.setPayload(e.id, rawEdit(e.bytes));
        expectEmit(c.base, &p, c.expected) catch |err| {
            std.debug.print("case failed: {s}\n", .{c.name});
            return err;
        };
    }
}

const base_a = header ++ sec(1, &.{ 0xAA, 0xBB, 0xCC }) ++ sec(3, &.{0x11});
const base_b = base_a ++ sec(10, &.{0x22});
const base_c = header ++ sec(1, &.{}) ++ sec(3, &.{1});
const base_d = header ++ sec(1, &.{ 0xAA, 0xBB }) ++ sec(3, &.{0x11}) ++ sec(10, &.{ 1, 2, 3 });
const base_g = header ++ sec(1, &.{1}) ++ sec(3, &.{2}) ++ sec(10, &.{3});

const type_padded = [_]u8{ 1, 0x83, 0x80, 0x80, 0x80, 0x00, 1, 2, 3 }; // size 3 in five bytes
const func_padded = [_]u8{ 3, 0x82, 0x80, 0x00, 9, 9 }; // size 2 in three bytes
const base_e = header ++ type_padded ++ func_padded;

const base_f = header ++
    sec(0, &.{1}) ++ sec(1, &.{0xAA}) ++ sec(0, &.{ 2, 2 }) ++ sec(3, &.{0xBB}) ++
    sec(0, &.{3}) ++ sec(10, &.{0xCC}) ++ sec(0, &.{4});

const replace_cases = [_]Case{
    .{
        .name = "shorter payload",
        .base = &base_a,
        .edits = &.{.{ .id = .type, .bytes = &.{ 1, 2 } }},
        .expected = &(header ++ sec(1, &.{ 1, 2 }) ++ sec(3, &.{0x11})),
    },
    .{
        .name = "longer payload",
        .base = &base_a,
        .edits = &.{.{ .id = .type, .bytes = &.{ 1, 2, 3, 4, 5, 6 } }},
        .expected = &(header ++ sec(1, &.{ 1, 2, 3, 4, 5, 6 }) ++ sec(3, &.{0x11})),
    },
    // Same length, different bytes: a length check is blind here, only the bytes can see a wrong flush or skip.
    .{
        .name = "same length, function section",
        .base = &base_b,
        .edits = &.{.{ .id = .function, .bytes = &.{0x99} }},
        .expected = &(header ++ sec(1, &.{ 0xAA, 0xBB, 0xCC }) ++ sec(3, &.{0x99}) ++ sec(10, &.{0x22})),
    },
    .{
        .name = "same length, type section",
        .base = &base_b,
        .edits = &.{.{ .id = .type, .bytes = &.{ 1, 2, 3 } }},
        .expected = &(header ++ sec(1, &.{ 1, 2, 3 }) ++ sec(3, &.{0x11}) ++ sec(10, &.{0x22})),
    },
    .{
        .name = "empty becomes non-empty",
        .base = &base_c,
        .edits = &.{.{ .id = .type, .bytes = "abc" }},
        .expected = &(header ++ sec(1, "abc") ++ sec(3, &.{1})),
    },
    .{
        .name = "non-empty becomes empty",
        .base = &base_c,
        .edits = &.{.{ .id = .function, .bytes = "" }},
        .expected = &(header ++ sec(1, &.{}) ++ sec(3, &.{})),
    },
    .{
        .name = "own payloads give back the input",
        .base = &base_d,
        .edits = &.{
            .{ .id = .type, .bytes = &.{ 0xAA, 0xBB } },
            .{ .id = .function, .bytes = &.{0x11} },
            .{ .id = .code, .bytes = &.{ 1, 2, 3 } },
        },
        .expected = &base_d,
    },
    .{
        .name = "an untouched section keeps its padded size LEB",
        .base = &base_e,
        .edits = &.{.{ .id = .function, .bytes = &.{7} }},
        .expected = &(header ++ type_padded ++ sec(3, &.{7})),
    },
    .{
        .name = "a patched section gets a canonical size LEB",
        .base = &base_e,
        .edits = &.{.{ .id = .type, .bytes = &.{ 1, 2, 3 } }},
        .expected = &(header ++ sec(1, &.{ 1, 2, 3 }) ++ func_padded),
    },
    .{
        .name = "first and last section, customs everywhere around them",
        .base = &base_f,
        .edits = &.{
            .{ .id = .type, .bytes = &.{ 1, 2 } },
            .{ .id = .code, .bytes = &.{ 9, 9, 9 } },
        },
        .expected = &(header ++
            sec(0, &.{1}) ++ sec(1, &.{ 1, 2 }) ++ sec(0, &.{ 2, 2 }) ++ sec(3, &.{0xBB}) ++
            sec(0, &.{3}) ++ sec(10, &.{ 9, 9, 9 }) ++ sec(0, &.{4})),
    },
    .{
        .name = "right after the header and at the very end",
        .base = &base_g,
        .edits = &.{
            .{ .id = .type, .bytes = "ab" },
            .{ .id = .code, .bytes = "cde" },
        },
        .expected = &(header ++ sec(1, "ab") ++ sec(3, &.{2}) ++ sec(10, "cde")),
    },
    .{
        .name = "every section replaced at once",
        .base = &base_g,
        .edits = &.{
            .{ .id = .type, .bytes = "a" },
            .{ .id = .function, .bytes = "bb" },
            .{ .id = .code, .bytes = "ccc" },
        },
        .expected = &(header ++ sec(1, "a") ++ sec(3, "bb") ++ sec(10, "ccc")),
    },
};

const customs_only = header ++ sec(0, &.{1}) ++ sec(0, &.{2});

const insert_cases = [_]Case{
    .{
        .name = "a leading custom stays first, the new section goes after it",
        .base = &(header ++ sec(0, &.{1}) ++ sec(5, &.{2}) ++ sec(10, &.{3})),
        .edits = &.{.{ .id = .type, .bytes = "T" }},
        .expected = &(header ++ sec(0, &.{1}) ++ sec(1, "T") ++ sec(5, &.{2}) ++ sec(10, &.{3})),
    },
    .{
        .name = "a trailing custom stays last, the new section goes before it",
        .base = &(header ++ sec(1, &.{1}) ++ sec(10, &.{2}) ++ sec(0, &.{3})),
        .edits = &.{.{ .id = .data, .bytes = "D" }},
        .expected = &(header ++ sec(1, &.{1}) ++ sec(10, &.{2}) ++ sec(11, "D") ++ sec(0, &.{3})),
    },
    .{
        .name = "several trailing customs all stay after the new section",
        .base = &(header ++ sec(1, &.{1}) ++ sec(0, &.{5}) ++ sec(0, &.{6})),
        .edits = &.{.{ .id = .data, .bytes = "D" }},
        .expected = &(header ++ sec(1, &.{1}) ++ sec(11, "D") ++ sec(0, &.{5}) ++ sec(0, &.{6})),
    },
    .{
        .name = "a custom in the gap stays before the new section",
        .base = &(header ++ sec(1, &.{1}) ++ sec(0, &.{2}) ++ sec(10, &.{3})),
        .edits = &.{.{ .id = .function, .bytes = "F" }},
        .expected = &(header ++ sec(1, &.{1}) ++ sec(0, &.{2}) ++ sec(3, "F") ++ sec(10, &.{3})),
    },
    .{
        .name = "header-only module",
        .base = &header,
        .edits = &.{.{ .id = .memory, .bytes = "M" }},
        .expected = &(header ++ sec(5, "M")),
    },
    .{
        .name = "customs-only module: no anchor, appended at the end",
        .base = &customs_only,
        .edits = &.{.{ .id = .type, .bytes = "T" }},
        .expected = &(customs_only ++ sec(1, "T")),
    },
    .{
        .name = "before everything",
        .base = &(header ++ sec(3, &.{1}) ++ sec(10, &.{2})),
        .edits = &.{.{ .id = .type, .bytes = "T" }},
        .expected = &(header ++ sec(1, "T") ++ sec(3, &.{1}) ++ sec(10, &.{2})),
    },
    .{
        .name = "after everything",
        .base = &(header ++ sec(1, &.{1})),
        .edits = &.{.{ .id = .data, .bytes = "D" }},
        .expected = &(header ++ sec(1, &.{1}) ++ sec(11, "D")),
    },
    .{
        .name = "tag goes between memory and global",
        .base = &(header ++ sec(5, &.{1}) ++ sec(6, &.{2})),
        .edits = &.{.{ .id = .tag, .bytes = "G" }},
        .expected = &(header ++ sec(5, &.{1}) ++ sec(13, "G") ++ sec(6, &.{2})),
    },
    .{
        .name = "tag goes before export when there is no global",
        .base = &(header ++ sec(5, &.{1}) ++ sec(7, &.{2})),
        .edits = &.{.{ .id = .tag, .bytes = "G" }},
        .expected = &(header ++ sec(5, &.{1}) ++ sec(13, "G") ++ sec(7, &.{2})),
    },
    .{
        .name = "data_count goes before code",
        .base = &(header ++ sec(10, &.{1})),
        .edits = &.{.{ .id = .data_count, .bytes = "N" }},
        .expected = &(header ++ sec(12, "N") ++ sec(10, &.{1})),
    },
    .{
        .name = "two inserts at the same position keep rank order and overwrite nothing",
        .base = &(header ++ sec(3, &.{9}) ++ sec(10, &.{8})),
        .edits = &.{
            .{ .id = .type, .bytes = "T" },
            .{ .id = .import, .bytes = "I" },
        },
        .expected = &(header ++ sec(1, "T") ++ sec(2, "I") ++ sec(3, &.{9}) ++ sec(10, &.{8})),
    },
    .{
        .name = "inserts spread over several gaps and the tail",
        .base = &(header ++ sec(3, &.{9}) ++ sec(10, &.{8})),
        .edits = &.{
            .{ .id = .type, .bytes = "T" },
            .{ .id = .table, .bytes = "B" },
            .{ .id = .data, .bytes = "D" },
        },
        .expected = &(header ++ sec(1, "T") ++ sec(3, &.{9}) ++ sec(4, "B") ++ sec(10, &.{8}) ++ sec(11, "D")),
    },
    .{
        .name = "several tail inserts keep rank order (set in the wrong order), trailing custom last",
        .base = &(header ++ sec(1, &.{1}) ++ sec(0, &.{7})),
        .edits = &.{
            .{ .id = .data, .bytes = "D" },
            .{ .id = .code, .bytes = "C" },
        },
        .expected = &(header ++ sec(1, &.{1}) ++ sec(10, "C") ++ sec(11, "D") ++ sec(0, &.{7})),
    },
    .{
        .name = "two inserts in the same gap, behind a custom",
        .base = &(header ++ sec(1, &.{1}) ++ sec(0, &.{5}) ++ sec(10, &.{3})),
        .edits = &.{
            .{ .id = .function, .bytes = "F" },
            .{ .id = .table, .bytes = "B" },
        },
        .expected = &(header ++ sec(1, &.{1}) ++ sec(0, &.{5}) ++ sec(3, "F") ++ sec(4, "B") ++ sec(10, &.{3})),
    },
};

const mixed_cases = [_]Case{
    .{
        .name = "replace and insert in the same patch",
        .base = &base_g,
        .edits = &.{
            .{ .id = .function, .bytes = "ff" },
            .{ .id = .table, .bytes = "B" },
        },
        .expected = &(header ++ sec(1, &.{1}) ++ sec(3, "ff") ++ sec(4, "B") ++ sec(10, &.{3})),
    },
    .{
        .name = "the section right after the insertion point is replaced",
        .base = &(header ++ sec(1, &.{1}) ++ sec(10, &.{3})),
        .edits = &.{
            .{ .id = .function, .bytes = "F" },
            .{ .id = .code, .bytes = "CC" },
        },
        .expected = &(header ++ sec(1, &.{1}) ++ sec(3, "F") ++ sec(10, "CC")),
    },
    .{
        .name = "the section right before the insertion point is replaced",
        .base = &(header ++ sec(1, &.{1}) ++ sec(10, &.{3})),
        .edits = &.{
            .{ .id = .type, .bytes = "TT" },
            .{ .id = .function, .bytes = "F" },
        },
        .expected = &(header ++ sec(1, "TT") ++ sec(3, "F") ++ sec(10, &.{3})),
    },
    // These two used to be the "missing section is an error" test.
    .{
        .name = "a missing section is inserted",
        .base = &(header ++ sec(1, &.{1}) ++ sec(10, &.{2})),
        .edits = &.{.{ .id = .table, .bytes = "x" }},
        .expected = &(header ++ sec(1, &.{1}) ++ sec(4, "x") ++ sec(10, &.{2})),
    },
    .{
        .name = "an earlier replace plus a later insert",
        .base = &(header ++ sec(1, &.{1}) ++ sec(10, &.{2})),
        .edits = &.{
            .{ .id = .type, .bytes = "ok" },
            .{ .id = .data, .bytes = "x" },
        },
        .expected = &(header ++ sec(1, "ok") ++ sec(10, &.{2}) ++ sec(11, "x")),
    },
};

test "emit replace: exact bytes" {
    try expectCases(&replace_cases);
}

test "emit insert: exact bytes and placement" {
    try expectCases(&insert_cases);
}

test "emit replace and insert together" {
    try expectCases(&mixed_cases);
}

// ------------------------------------------------- tests with their own structure

test "emit: the size LEB changes width exactly at the boundaries, replacing and inserting" {
    const prefix = header ++ sec(1, &.{1});
    const suffix = sec(10, &.{3});
    const with_function = prefix ++ sec(3, &.{2}) ++ suffix; // the section exists: replace
    const without_function = prefix ++ suffix; // it does not: insert

    const cases = [_]struct { n: usize, leb: []const u8 }{
        .{ .n = 0, .leb = &.{0x00} },
        .{ .n = 1, .leb = &.{0x01} },
        .{ .n = 127, .leb = &.{0x7F} },
        .{ .n = 128, .leb = &.{ 0x80, 0x01 } },
        .{ .n = 16383, .leb = &.{ 0xFF, 0x7F } },
        .{ .n = 16384, .leb = &.{ 0x80, 0x80, 0x01 } },
    };
    for ([_][]const u8{ &with_function, &without_function }) |base| {
        for (cases) |c| {
            const payload = try testing.allocator.alloc(u8, c.n);
            defer testing.allocator.free(payload);
            @memset(payload, 0xAB);
            const p = try patchOne(.function, payload);

            var expected: Io.Writer.Allocating = .init(testing.allocator);
            defer expected.deinit();
            try expected.writer.writeAll(&prefix);
            try expected.writer.writeByte(3); // function section id
            try expected.writer.writeAll(c.leb);
            try expected.writer.writeAll(payload);
            try expected.writer.writeAll(&suffix);

            try expectEmit(base, &p, expected.written());
        }
    }
}

test "emit: all thirteen sections inserted into a header-only module come out in binary order" {
    var store: [section_id_count][2]u8 = undefined;
    fillStore(&store);
    var p = Patch.empty;
    var expected: Io.Writer.Allocating = .init(testing.allocator);
    defer expected.deinit();
    try expected.writer.writeAll(&header);

    for (1..section_id_count) |r| {
        const id = SectionId.fromRank(@intCast(r));
        try p.setPayload(id, rawEdit(&store[@backingInt(id)])); // set in id order, not rank order
    }
    for (1..section_id_count) |r| { // expected: rank order
        const id = SectionId.fromRank(@intCast(r));
        try expected.writer.writeByte(@backingInt(id));
        try expected.writer.writeByte(2);
        try expected.writer.writeAll(&store[@backingInt(id)]);
    }
    try expectEmit(&header, &p, expected.written());
}

test "emit: all thirteen patched where two of them already exist" {
    var store: [section_id_count][2]u8 = undefined;
    fillStore(&store);
    const base = header ++ sec(1, &.{9}) ++ sec(10, &.{9});
    var p = Patch.empty;
    var expected: Io.Writer.Allocating = .init(testing.allocator);
    defer expected.deinit();
    try expected.writer.writeAll(&header);

    for (1..section_id_count) |r| {
        const id = SectionId.fromRank(@intCast(r));
        try p.setPayload(id, rawEdit(&store[@backingInt(id)]));
        try expected.writer.writeByte(@backingInt(id));
        try expected.writer.writeByte(2);
        try expected.writer.writeAll(&store[@backingInt(id)]);
    }
    try expectEmit(&base, &p, expected.written()); // type and code were replaced, the rest inserted
}

test "emit: exact-size writer succeeds, one byte short fails (replace and insert)" {
    const replace_base = header ++ sec(1, &.{ 1, 2, 3 }) ++ sec(3, &.{4});
    const replace_patch = try patchOne(.type, &.{ 9, 9, 9, 9, 9 });
    try expectExactFit(&replace_base, &replace_patch, 18); // 8 + (1 + 1 + 5) + (1 + 1 + 1)

    const insert_base = header ++ sec(1, &.{1}) ++ sec(10, &.{2});
    const insert_patch = try patchOne(.table, "xyz");
    try expectExactFit(&insert_base, &insert_patch, 19); // 8 + 3 + 3 + (1 + 1 + 3)
}

test "emit: running twice gives identical output (replace and insert)" {
    const base = header ++ sec(1, &.{1}) ++ sec(10, &.{2});
    var p = Patch.empty;
    try p.setPayload(.type, rawEdit("xyz")); // replace
    try p.setPayload(.table, rawEdit("B")); // insert
    try p.setPayload(.data, rawEdit("D")); // insert at the tail
    try expectDeterministic(&base, &p);
}

// ----------------------------------------------------------------- fixtures

test "emit: Run flushed at every real section boundary reproduces the input" {
    for (fixtures.all) |f| {
        const m = try Module.parse(f.bytes);
        var out: Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();

        var run: Run = .{ .bytes = m.bytes, .writer = &out.writer };
        var it = m.iterator();
        while (try it.next()) |s| {
            try run.flush(s.start);
            try run.flush(s.payload.start);
            try run.flush(s.whole().end);
        }
        try run.flush(@intCast(m.bytes.len));
        try testing.expectEqualSlices(u8, f.bytes, out.written());
    }
}

test "emit: replacing any section of a fixture with its own payload is the identity" {
    for (fixtures.all) |f| {
        const m = try Module.parse(f.bytes);
        var it = m.iterator();
        while (try it.next()) |s| {
            if (s.id == .custom) continue;
            const p = try patchOne(s.id, s.payload.slice(m.bytes));
            try expectEmit(f.bytes, &p, f.bytes); // fixtures use canonical size LEBs
        }
    }
}

test "emit: all sections of a fixture replaced at once with their own payloads" {
    for (fixtures.all) |f| {
        const m = try Module.parse(f.bytes);
        var patch = Patch.empty;
        var it = m.iterator();
        while (try it.next()) |s| {
            if (s.id == .custom) continue;
            try patch.setPayload(s.id, rawEdit(s.payload.slice(m.bytes)));
        }
        try expectEmit(f.bytes, &patch, f.bytes);
    }
}

// The test with the most teeth: lengths are equal, so only the bytes can reveal a wrong flush or skip.
test "emit: same-length replacement changes exactly the payload bytes and nothing else" {
    for (fixtures.all) |f| {
        const m = try Module.parse(f.bytes);
        var it = m.iterator();
        while (try it.next()) |s| {
            if (s.id == .custom) continue;

            const flipped = try testing.allocator.dupe(u8, s.payload.slice(m.bytes));
            defer testing.allocator.free(flipped);
            for (flipped) |*b| b.* ^= 0x5A;

            const patch = try patchOne(s.id, flipped);
            var out: Io.Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            try emit(&m, &patch, &out.writer, .{});

            const got = out.written();
            try testing.expectEqual(f.bytes.len, got.len);
            try testing.expectEqualSlices(u8, f.bytes[0..s.payload.start], got[0..s.payload.start]);
            try testing.expectEqualSlices(u8, flipped, got[s.payload.start..s.payload.end]);
            try testing.expectEqualSlices(u8, f.bytes[s.payload.end..], got[s.payload.end..]);
        }
    }
}

test "emit: replacing a fixture section changes only that section" {
    const new_payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01 };
    for (fixtures.all) |f| {
        const m = try Module.parse(f.bytes);
        var it = m.iterator();
        while (try it.next()) |s| {
            if (s.id == .custom) continue;

            const patch = try patchOne(s.id, &new_payload);
            var out: Io.Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            try emit(&m, &patch, &out.writer, .{});
            try testing.expectEqual(@as(u32, @intCast(out.written().len)), try outputLen(&m, &patch, .{}));

            const m2 = try Module.parse(out.written());
            try testing.expectEqualSlices(u8, &new_payload, m2.section(s.id).?.payload.slice(m2.bytes));

            // every other section, customs included, is byte-identical and in the same order
            var before = m.iterator();
            var after = m2.iterator();
            while (try before.next()) |a| {
                const b = (try after.next()).?;
                try testing.expectEqual(a.id, b.id);
                if (a.id == s.id) continue;
                try testing.expectEqualSlices(u8, a.whole().slice(m.bytes), b.whole().slice(m2.bytes));
            }
            try testing.expectEqual(null, try after.next());
        }
    }
}

test "emit insert: any single missing section into a fixture leaves every original untouched" {
    var store: [section_id_count][2]u8 = undefined;
    fillStore(&store);
    for (fixtures.all) |f| {
        const m = try Module.parse(f.bytes);
        for (1..section_id_count) |r| {
            const id = SectionId.fromRank(@intCast(r));
            if (m.section(id) != null) continue;

            const patch = try patchOne(id, &store[@backingInt(id)]);
            var out: Io.Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            try emit(&m, &patch, &out.writer, .{});
            try testing.expectEqual(@as(u32, @intCast(out.written().len)), try outputLen(&m, &patch, .{}));

            const m2 = try Module.parse(out.written()); // also proves the rank order is legal
            try testing.expectEqualSlices(u8, &store[@backingInt(id)], m2.section(id).?.payload.slice(m2.bytes));
            try expectOriginalsUntouched(m, m2, 1);
        }
    }
}

test "emit insert: every missing section into a fixture at once" {
    var store: [section_id_count][2]u8 = undefined;
    fillStore(&store);
    for (fixtures.all) |f| {
        const m = try Module.parse(f.bytes);
        var patch = Patch.empty;
        var missing: u32 = 0;
        for (1..section_id_count) |r| {
            const id = SectionId.fromRank(@intCast(r));
            if (m.section(id) != null) continue;
            try patch.setPayload(id, rawEdit(&store[@backingInt(id)]));
            missing += 1;
        }
        var out: Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try emit(&m, &patch, &out.writer, .{});
        try testing.expectEqual(@as(u32, @intCast(out.written().len)), try outputLen(&m, &patch, .{}));

        const m2 = try Module.parse(out.written());
        for (1..section_id_count) |r| { // all thirteen exist now; the added ones carry their payload
            const id = SectionId.fromRank(@intCast(r));
            const s = m2.section(id).?;
            if (m.section(id) == null) {
                try testing.expectEqualSlices(u8, &store[@backingInt(id)], s.payload.slice(m2.bytes));
            }
        }
        try expectOriginalsUntouched(m, m2, missing);
    }
}

// ------------------------------------------------------------------ sweeps

fn checkReplaceInMutant(m: Module) !void {
    const payloads = [_][]const u8{ "", "z", &(@as([130]u8, @splat(0x7A))) }; // 130: the size LEB goes from 1 to 2 bytes
    var it = m.iterator();
    while (try it.next()) |s| {
        if (s.id == .custom) continue;
        for (payloads) |p| {
            const patch = try patchOne(s.id, p);
            var out: Io.Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            try emit(&m, &patch, &out.writer, .{});

            try t.expectTiles(out.written());
            const m2 = try Module.parse(out.written());
            try testing.expectEqualSlices(u8, p, m2.section(s.id).?.payload.slice(m2.bytes));
            try testing.expectEqual(@as(u32, @intCast(out.written().len)), try outputLen(&m, &patch, .{}));
        }
    }
}

/// Returns how many sections it inserted.
fn checkInsertInMutant(m: Module, store: *const [section_id_count][2]u8) !u32 {
    var inserted: u32 = 0;
    for (1..section_id_count) |r| {
        const id = SectionId.fromRank(@intCast(r));
        if (m.section(id) != null) continue;

        const patch = try patchOne(id, &store[@backingInt(id)]);
        var out: Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try emit(&m, &patch, &out.writer, .{});

        try t.expectTiles(out.written());
        const m2 = try Module.parse(out.written());
        try testing.expectEqualSlices(u8, &store[@backingInt(id)], m2.section(id).?.payload.slice(m2.bytes));
        try testing.expectEqual(@as(u32, @intCast(out.written().len)), try outputLen(&m, &patch, .{}));
        inserted += 1;
    }
    return inserted;
}

test "emit: any mutant that parses can have each section replaced or inserted, and still parses and tiles" {
    var store: [section_id_count][2]u8 = undefined;
    fillStore(&store);
    var buf: [t.mutation_base.len]u8 = t.mutation_base;
    var accepted: u32 = 0;
    var rejected: u32 = 0;
    var inserted: u32 = 0;

    for (0..buf.len) |i| {
        const original = t.mutation_base[i];
        for ([_]u8{ 0x00, 0xFF, original ^ 0x80, original +% 1 }) |value| {
            buf[i] = value;
            const m = Module.parse(&buf) catch {
                rejected += 1;
                continue;
            };
            accepted += 1;
            try checkReplaceInMutant(m);
            inserted += try checkInsertInMutant(m, &store);
        }
        buf[i] = original;
    }
    try testing.expect(accepted > 0); // the replace and insert checks actually ran
    try testing.expect(rejected > 0); // the gate actually rejected things
    try testing.expect(inserted > 0);
}
