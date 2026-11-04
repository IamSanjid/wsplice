//! Tests of the AddExports edit, through the public emit API.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const spec = @import("../../spec.zig");
const SectionId = spec.SectionId;
const Cursor = @import("../../Cursor.zig");
const Module = @import("../../Module.zig");
const Patch = @import("../../Patch.zig");
const Diagnostics = @import("../../Diagnostics.zig");
const exports = @import("../../payload/exports.zig");
const AddExports = @import("../../edit/AddExports.zig");
const Entry = AddExports.Entry; // what this edit appends
const ReadEntry = exports.Entry; // what the section reader yields
const index = @import("../../index.zig");
const emit_mod = @import("../../emit.zig");
const t = @import("../support.zig");
const fixtures = @import("../fixtures/fixtures.zig");
const Counts = @import("../../payload/Counts.zig");
const Kind = spec.ExternalKind;

const emit = emit_mod.emit;
const outputLen = emit_mod.outputLen;
const header = t.header;
const sec = t.sec;
const ent = t.exportEntry;
const pre = header ++ t.entities;
const imp = t.importEntry;

// ---------------------------------------------------------------- helpers

fn patchAdd(entries: []const Entry) !Patch {
    var p = Patch.empty;
    try p.setPayload(.@"export", .{ .add_exports = .{ .entries = entries } });
    return p;
}

/// One entry that exports an entity the input module already has.
fn existing(name: []const u8, kind: spec.ExternalKind, input_index: u32) Entry {
    return .{ .name = name, .target = index.Target.input(kind, input_index) };
}

/// The reader's view of an entry that exports an existing entity, for comparing what was written.
fn asRead(added: Entry) ReadEntry {
    return .{
        .name = added.name,
        .kind = added.target.kind(),
        .index = added.target.inputIndex().?,
    };
}

/// Reads the export entries of `module_bytes` into `buf`. The entries borrow from `module_bytes`.
fn collect(module_bytes: []const u8, buf: []ReadEntry) ![]const ReadEntry {
    const m = try Module.parse(module_bytes);
    var it = try exports.Iterator.init(m.payloadCursor(.@"export").?);
    var n: usize = 0;
    while (try it.next()) |read| : (n += 1) buf[n] = read;
    return buf[0..n];
}

fn expectExportsAre(module_bytes: []const u8, expected: []const ReadEntry) !void {
    const m = try Module.parse(module_bytes);
    var it = try exports.Iterator.init(m.payloadCursor(.@"export").?);
    try testing.expectEqual(@as(u32, @intCast(expected.len)), it.count);
    for (expected) |want| {
        const got = (try it.next()).?;
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqual(want.index, got.index);
    }
    try testing.expectEqual(null, try it.next());
}

/// A failing edit must: return `expected_err` from emit and outputLen (with and without diagnostics),
/// write nothing, and record the same error, the export section, the offending name and the offset.
fn expectEditFails(
    base: []const u8,
    add: []const Entry,
    expected_err: anyerror,
    expected_name: []const u8,
    expected_offset: ?u32,
) !void {
    const m = try Module.parse(base);
    const p = try patchAdd(add);
    var buf: [512]u8 = undefined;

    var d: Diagnostics = .{};
    var w1: Io.Writer = .fixed(&buf);
    try testing.expectError(expected_err, emit(&m, &p, &w1, .{ .diag = &d }));
    try testing.expectEqual(@as(usize, 0), w1.buffered().len); // atomic: nothing reached the writer
    try testing.expectEqual(@as(?anyerror, expected_err), d.err);
    try testing.expectEqual(@as(?SectionId, .@"export"), d.section);
    try testing.expectEqualStrings(expected_name, d.name());
    try testing.expectEqual(expected_offset, d.offset);
    try testing.expectEqualDeep(Diagnostics.Detail.none, d.detail);

    try testing.expectError(expected_err, outputLen(&m, &p, .{}));

    var w2: Io.Writer = .fixed(&buf); // no diagnostics: same error, still nothing written
    try testing.expectError(expected_err, emit(&m, &p, &w2, .{}));
    try testing.expectEqual(@as(usize, 0), w2.buffered().len);
}

// ------------------------------------------------------------ exact bytes

const Layout = struct {
    name: []const u8,
    base: []const u8,
    add: []const Entry,
    expected: []const u8,
};

fn expectLayouts(cases: []const Layout) !void {
    for (cases) |c| {
        const p = try patchAdd(c.add);
        t.expectEmit(c.base, &p, c.expected) catch |err| {
            std.debug.print("case failed: {s}\n", .{c.name});
            return err;
        };
    }
}

const old_a = [_]u8{1} ++ ent("a", 0, 0); // payload: count 1, entry "a"
const old_a_padded = [_]u8{ 0x81, 0x80, 0x00 } ++ ent("a", 0, 0); // count 1 written in three bytes
const with_a = pre ++ sec(7, &old_a);
const with_a_padded = pre ++ sec(7, &old_a_padded);
const with_bad_old_name = pre ++ sec(7, &([_]u8{1} ++ ent("\xFF", 0, 0)));

const layout_cases = [_]Layout{
    .{
        .name = "append to an existing section",
        .base = &with_a,
        .add = &.{existing("b", .global, 1)},
        .expected = &(pre ++ sec(7, &([_]u8{2} ++ ent("a", 0, 0) ++ ent("b", 3, 1)))),
    },
    .{
        .name = "create the section in a header-only module",
        .base = &pre,
        .add = &.{existing("f", .function, 0)},
        .expected = &(pre ++ sec(7, &([_]u8{1} ++ ent("f", 0, 0)))),
    },
    .{
        .name = "create the section before a later section",
        .base = &(pre ++ sec(10, &.{0})),
        .add = &.{existing("f", .function, 0)},
        .expected = &(pre ++ sec(7, &([_]u8{1} ++ ent("f", 0, 0))) ++ sec(10, &.{0})),
    },
    .{
        .name = "create the section at the tail, a trailing custom stays last",
        .base = &(pre ++ sec(0, &.{9})),
        .add = &.{existing("f", .function, 0)},
        .expected = &(pre ++ sec(7, &([_]u8{1} ++ ent("f", 0, 0))) ++ sec(0, &.{9})),
    },
    .{
        .name = "nothing to add leaves an existing section as it was",
        .base = &with_a,
        .add = &.{},
        .expected = &with_a,
    },
    .{
        .name = "nothing to add still writes a canonical count",
        .base = &with_a_padded,
        .add = &.{},
        .expected = &with_a,
    },
    .{
        .name = "a padded count is replaced, the old entry bytes are copied verbatim",
        .base = &with_a_padded,
        .add = &.{existing("b", .function, 1)},
        .expected = &(pre ++ sec(7, &([_]u8{2} ++ ent("a", 0, 0) ++ ent("b", 0, 1)))),
    },
    .{
        // A design decision, pinned here so a change is deliberate: the edit always yields a section.
        .name = "nothing to add to a module without exports creates an empty section",
        .base = &pre,
        .add = &.{},
        .expected = &(pre ++ sec(7, &.{0})),
    },
    .{
        .name = "an old section with zero entries",
        .base = &(pre ++ sec(7, &.{0})),
        .add = &.{existing("a", .function, 0)},
        .expected = &with_a,
    },
    .{
        .name = "every kind, tag included",
        .base = &pre,
        .add = &.{
            existing("f", .function, 0),
            existing("t", .table, 1),
            existing("m", .memory, 2),
            existing("g", .global, 3),
            existing("x", .tag, 4),
        },
        .expected = &(pre ++ sec(7, &([_]u8{5} ++
            ent("f", 0, 0) ++ ent("t", 1, 1) ++ ent("m", 2, 2) ++ ent("g", 3, 3) ++ ent("x", 4, 4)))),
    },
    .{
        .name = "names are bytes: empty, NUL, multi-byte UTF-8, prefixes, and case alone makes them distinct",
        .base = &pre,
        .add = &.{
            existing("", .function, 0),
            existing("a\x00b", .memory, 0),
            existing("h\xC3\xA9llo", .global, 1),
            existing("\u{1F600}", .function, 1),
            existing("ADD", .function, 2),
            existing("add", .function, 3),
            existing("a", .function, 4),
            existing("a\x00", .function, 5),
        },
        .expected = &(pre ++ sec(7, &([_]u8{8} ++
            ent("", 0, 0) ++ ent("a\x00b", 2, 0) ++ ent("h\xC3\xA9llo", 3, 1) ++ ent("\u{1F600}", 0, 1) ++
            ent("ADD", 0, 2) ++ ent("add", 0, 3) ++ ent("a", 0, 4) ++ ent("a\x00", 0, 5)))),
    },
    .{
        .name = "old names are not judged, only new ones are",
        .base = &with_bad_old_name,
        .add = &.{existing("a", .function, 0)},
        .expected = &(pre ++ sec(7, &([_]u8{2} ++ ent("\xFF", 0, 0) ++ ent("a", 0, 0)))),
    },
};

test "AddExports: exact bytes" {
    try expectLayouts(&layout_cases);
}

// ------------------------------------------------------- added entities

test "AddExports: an added target resolves after the input's last index" {
    // `pre` has eight of every kind, so the plan's first added entity of any kind is index 8.
    const add = [_]Entry{
        .{ .name = "fn", .target = index.Target.appended(.function, 0) },
        .{ .name = "gl", .target = index.Target.appended(.global, 0) },
    };
    const p = try patchAdd(&add);
    const expected = pre ++ sec(7, &([_]u8{2} ++ ent("fn", 0, 8) ++ ent("gl", 3, 8)));
    try t.expectEmit(&pre, &p, &expected);
}

test "AddExports: an added global lands after the imported ones, not after the defined ones" {
    // Two imported globals and one defined: the index space is 3, so the plan's first added global
    // is 3. Counting only the defined section would say 1.
    const base = header ++
        sec(2, &([_]u8{2} ++
            imp("e", "a", &.{ 0x03, 0x7F, 0x01 }) ++
            imp("e", "b", &.{ 0x03, 0x7F, 0x00 }))) ++
        sec(6, &([_]u8{1} ++ t.globalEntry(0x7F, .immutable, &.{ 0x41, 0x07 })));

    const p = try patchAdd(&.{.{ .name = "new", .target = index.Target.appended(.global, 0) }});
    try t.expectEmit(&base, &p, &(base ++ sec(7, &([_]u8{1} ++ ent("new", 3, 3)))));
}

// ------------------------------------------------------------- LEB widths

/// One-byte names {i + 1}, function, index i. Names are unique for i < 127.
fn syntheticEntry(w: *Io.Writer, i: u8) !void {
    try w.writeAll(&[_]u8{ 1, i + 1, 0, i });
}

const Grow = struct {
    old_n: u8,
    add: []const Entry,
    add_bytes: []const u8, // the same entries, hand-encoded
    // All four LEBs are hard-coded, so these tests never lean on the encoder under test.
    old_count_leb: []const u8,
    old_size_leb: []const u8,
    new_count_leb: []const u8,
    new_size_leb: []const u8,
};

fn expectGrow(g: Grow) !void {
    var base: Io.Writer.Allocating = .init(testing.allocator);
    defer base.deinit();
    var expected: Io.Writer.Allocating = .init(testing.allocator);
    defer expected.deinit();

    try base.writer.writeAll(&pre);
    try base.writer.writeByte(7);
    try base.writer.writeAll(g.old_size_leb);
    try base.writer.writeAll(g.old_count_leb);
    for (0..g.old_n) |i| try syntheticEntry(&base.writer, @intCast(i));

    try expected.writer.writeAll(&pre);
    try expected.writer.writeByte(7);
    try expected.writer.writeAll(g.new_size_leb);
    try expected.writer.writeAll(g.new_count_leb);
    for (0..g.old_n) |i| try syntheticEntry(&expected.writer, @intCast(i));
    try expected.writer.writeAll(g.add_bytes);

    const p = try patchAdd(g.add);
    try t.expectEmit(base.written(), &p, expected.written());
}

test "AddExports: the count and size LEBs grow exactly at their boundaries" {
    try expectGrow(.{
        // 127 old entries: the count 0x7F (one byte) becomes 128 (two bytes). Old payload: 1 + 508 = 509.
        .old_n = 127,
        .add = &.{existing("zz", .function, 0)},
        .add_bytes = &.{ 2, 'z', 'z', 0, 0 },
        .old_count_leb = &.{0x7F},
        .old_size_leb = &.{ 0xFD, 0x03 }, // 509
        .new_count_leb = &.{ 0x80, 0x01 }, // 128
        .new_size_leb = &.{ 0x83, 0x04 }, // 2 + 508 + 5 = 515
    });
    try expectGrow(.{
        // 30 old entries: payload 1 + 120 = 121 (a one-byte size); two new entries make it 129 (two bytes).
        .old_n = 30,
        .add = &.{
            existing("p", .function, 0),
            existing("q", .function, 0),
        },
        .add_bytes = &.{ 1, 'p', 0, 0, 1, 'q', 0, 0 },
        .old_count_leb = &.{30},
        .old_size_leb = &.{121},
        .new_count_leb = &.{32},
        .new_size_leb = &.{ 0x81, 0x01 }, // 129
    });
}

// ----------------------------------------------------------------- failures

const Failure = struct {
    name: []const u8,
    base: []const u8,
    add: []const Entry,
    err: anyerror,
    bad_name: []const u8 = "", // what the diagnostics must say; empty when no name applies
    offset: ?u32 = null, // absolute input offset; null when the failure has none
};

fn expectFailures(cases: []const Failure) !void {
    for (cases) |c| {
        expectEditFails(c.base, c.add, c.err, c.bad_name, c.offset) catch |err| {
            std.debug.print("case failed: {s}\n", .{c.name});
            return err;
        };
    }
}

const dup_base = pre ++ sec(7, &([_]u8{2} ++ ent("add", 0, 0) ++ ent("mem", 2, 0)));
const empty_name_base = pre ++ sec(7, &([_]u8{1} ++ ent("", 0, 0)));

const duplicate_cases = [_]Failure{
    .{
        .name = "same name and kind as an old entry",
        .base = &dup_base,
        .add = &.{existing("add", .function, 5)},
        .err = error.DuplicateExportName,
        .bad_name = "add",
    },
    .{
        .name = "new function against an old memory of the same name",
        .base = &dup_base,
        .add = &.{existing("mem", .function, 1)},
        .err = error.DuplicateExportName,
        .bad_name = "mem",
    },
    .{
        .name = "new global against an old function of the same name",
        .base = &dup_base,
        .add = &.{existing("add", .global, 0)},
        .err = error.DuplicateExportName,
        .bad_name = "add",
    },
    .{
        .name = "second new entry repeats the first, across kinds",
        .base = &dup_base,
        .add = &.{
            existing("x", .function, 0),
            existing("x", .global, 1),
        },
        .err = error.DuplicateExportName,
        .bad_name = "x",
    },
    .{
        .name = "third new entry repeats the first, the second is fine",
        .base = &dup_base,
        .add = &.{
            existing("a", .function, 0),
            existing("b", .function, 1),
            existing("a", .function, 2),
        },
        .err = error.DuplicateExportName,
        .bad_name = "a",
    },
    .{
        .name = "only the clashing entry is reported among fine ones",
        .base = &dup_base,
        .add = &.{
            existing("fine1", .function, 0),
            existing("mem", .function, 1),
            existing("fine2", .function, 2),
        },
        .err = error.DuplicateExportName,
        .bad_name = "mem",
    },
    .{
        .name = "empty name twice, in a module without exports",
        .base = &pre,
        .add = &.{
            existing("", .function, 0),
            existing("", .global, 0),
        },
        .err = error.DuplicateExportName,
    },
    .{
        .name = "empty name against an old empty name",
        .base = &empty_name_base,
        .add = &.{existing("", .function, 1)},
        .err = error.DuplicateExportName,
    },
    .{
        .name = "a name with an embedded NUL is compared whole",
        .base = &pre,
        .add = &.{
            existing("a\x00b", .function, 0),
            existing("a\x00b", .function, 1),
        },
        .err = error.DuplicateExportName,
        .bad_name = "a\x00b",
    },
};

const bad_name_cases = [_]Failure{
    .{
        .name = "a lone 0xFF byte",
        .base = &pre,
        .add = &.{existing("\xFF", .function, 0)},
        .err = error.InvalidExportName,
        .bad_name = "\xFF",
    },
    .{
        .name = "overlong encoding of NUL",
        .base = &pre,
        .add = &.{existing("\xC0\x80", .function, 0)},
        .err = error.InvalidExportName,
        .bad_name = "\xC0\x80",
    },
    .{
        .name = "an encoded UTF-16 surrogate",
        .base = &pre,
        .add = &.{existing("\xED\xA0\x80", .function, 0)},
        .err = error.InvalidExportName,
        .bad_name = "\xED\xA0\x80",
    },
    .{
        .name = "above U+10FFFF",
        .base = &pre,
        .add = &.{existing("\xF4\x90\x80\x80", .function, 0)},
        .err = error.InvalidExportName,
        .bad_name = "\xF4\x90\x80\x80",
    },
    .{
        .name = "a truncated multi-byte sequence",
        .base = &pre,
        .add = &.{existing("ab\xE3\x81", .function, 0)},
        .err = error.InvalidExportName,
        .bad_name = "ab\xE3\x81",
    },
    .{
        .name = "a bad name after good ones, in a module with exports",
        .base = &dup_base,
        .add = &.{
            existing("ok", .function, 0),
            existing("\xFF", .function, 1),
        },
        .err = error.InvalidExportName,
        .bad_name = "\xFF",
    },
    .{
        // The new name is invalid AND equals an old (unjudged) name: the encoding error comes first.
        .name = "invalid new name equal to an old invalid name",
        .base = &with_bad_old_name,
        .add = &.{existing("\xFF", .function, 0)},
        .err = error.InvalidExportName,
        .bad_name = "\xFF",
    },
};

const one_new = [_]Entry{existing("new", .function, 0)};

// The payload starts at input offset 10 in all of these: 8 header + 1 id + 1 size. Offsets are absolute.
const bad_old_cases = [_]Failure{
    .{ .name = "empty payload", .base = &(header ++ sec(7, &.{})), .add = &one_new, .err = error.Truncated, .offset = 10 },
    .{
        .name = "six-byte count",
        .base = &(header ++ sec(7, &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 })),
        .add = &one_new,
        .err = error.MalformedLeb,
        .offset = 10,
    },
    .{ .name = "count larger than the data", .base = &(header ++ sec(7, &.{ 5, 0, 0, 0 })), .add = &one_new, .err = error.Truncated, .offset = 10 },
    .{ .name = "truncated name", .base = &(header ++ sec(7, &.{ 1, 5, 'a', 'b' })), .add = &one_new, .err = error.Truncated, .offset = 11 },
    .{ .name = "truncated index", .base = &(header ++ sec(7, &.{ 1, 1, 'a', 0 })), .add = &one_new, .err = error.Truncated, .offset = 11 },
    .{ .name = "unknown kind", .base = &(header ++ sec(7, &.{ 1, 1, 'a', 9, 0 })), .add = &one_new, .err = error.InvalidKind, .offset = 11 },
    .{
        .name = "a stray byte after the last entry",
        .base = &(header ++ sec(7, &.{ 1, 1, 'a', 0, 0, 0xFF })),
        .add = &one_new,
        .err = error.TrailingBytes,
        .offset = 15,
    },
    .{
        .name = "a second entry beyond the count",
        .base = &(header ++ sec(7, &.{ 1, 1, 'a', 0, 0, 1, 'b', 0, 0 })),
        .add = &one_new,
        .err = error.TrailingBytes,
        .offset = 15,
    },
};

test "AddExports: duplicate names fail, and say which" {
    try expectFailures(&duplicate_cases);
}

test "AddExports: invalid new names fail, and say which" {
    try expectFailures(&bad_name_cases);
}

test "AddExports: a malformed old section is rejected, never copied, and the offset is absolute" {
    try expectFailures(&bad_old_cases);
}

test "AddExports: a failing edit leaves the writer empty, whatever the other edits are" {
    const base = header ++ sec(1, &.{ 1, 0x60, 0, 0 }) ++ sec(7, &old_a) ++ sec(10, &.{2});
    const clash = [_]Entry{existing("a", .function, 0)};
    const m = try Module.parse(&base);
    var buf: [256]u8 = undefined;

    const others = [_]struct { id: SectionId, bytes: []const u8 }{
        .{ .id = .type, .bytes = "ok" }, // a replace EARLIER in the file than the failing edit
        .{ .id = .code, .bytes = "ok" }, // a replace LATER in the file
        .{ .id = .function, .bytes = "F" }, // an insert between the replace and the failing edit
        .{ .id = .data, .bytes = "D" }, // an insert at the tail
    };
    for (others) |other| {
        var p = try patchAdd(&clash);
        try p.setPayload(other.id, t.rawEdit(other.bytes));

        var w: Io.Writer = .fixed(&buf);
        try testing.expectError(error.DuplicateExportName, emit(&m, &p, &w, .{}));
        try testing.expectEqual(@as(usize, 0), w.buffered().len);
        try testing.expectError(error.DuplicateExportName, outputLen(&m, &p, .{}));
    }

    var all = try patchAdd(&clash); // all four at once
    for (others) |other| try all.setPayload(other.id, t.rawEdit(other.bytes));
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(error.DuplicateExportName, emit(&m, &all, &w, .{}));
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

// ----------------------------------------------------------------- fixtures

test "AddExports: fixtures keep their old entries, gain the new ones, and every other section is untouched" {
    const added = [_]Entry{
        existing("added_fn", .function, 0),
        existing("added_global", .global, 0),
    };
    for (fixtures.all) |f| {
        const m = try Module.parse(f.bytes);
        const p = try patchAdd(&added);
        var out: Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try emit(&m, &p, &out.writer, .{});
        try testing.expectEqual(@as(u32, @intCast(out.written().len)), try outputLen(&m, &p, .{}));
        try t.expectTiles(out.written());

        // the entries read back as old ++ new
        var old_buf: [16]ReadEntry = undefined;
        const old = try collect(f.bytes, &old_buf);
        var want: [18]ReadEntry = undefined;
        @memcpy(want[0..old.len], old);
        for (added, 0..) |e, i| want[old.len + i] = asRead(e);
        try expectExportsAre(out.written(), want[0 .. old.len + added.len]);

        // the old entry bytes are copied verbatim, right after the new canonical count
        const m2 = try Module.parse(out.written());
        const old_it = try exports.Iterator.init(m.payloadCursor(.@"export").?);
        const new_it = try exports.Iterator.init(m2.payloadCursor(.@"export").?);
        try testing.expect(std.mem.startsWith(u8, new_it.entries.slice(m2.bytes), old_it.entries.slice(m.bytes)));

        // every other section, customs included, is byte-identical and in the same order
        var before = m.iterator();
        var after = m2.iterator();
        while (try before.next()) |a| {
            const b = (try after.next()).?;
            try testing.expectEqual(a.id, b.id);
            if (a.id == .@"export") continue;
            try testing.expectEqualSlices(u8, a.whole().slice(m.bytes), b.whole().slice(m2.bytes));
        }
        try testing.expectEqual(null, try after.next());
    }
}

// ------------------------------------------------------------------- sweep

const sweep_added = [_]Entry{
    existing("added_fn", .function, 0),
    existing("added_global", .global, 0),
};

fn payloadReadable(payload: []const u8) bool {
    var it = exports.Iterator.init(Cursor.init(payload) catch return false) catch return false;
    while (it.next() catch return false) |_| {}
    return true;
}

/// Returns true when the mutant's export section was readable, which means the edit had to succeed.
fn checkMutant(mutant: []const u8) !bool {
    const m = try Module.parse(mutant); // only payload bytes were changed: the container is intact
    const readable = payloadReadable(m.section(.@"export").?.payload.slice(m.bytes));
    const p = try patchAdd(&sweep_added);
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    if (!readable) {
        if (emit(&m, &p, &out.writer, .{})) |_| {
            return error.TestUnexpectedResult; // the edit accepted a section the reader rejects
        } else |err| switch (err) {
            error.Truncated, error.MalformedLeb, error.TrailingBytes, error.InvalidKind => {},
            else => return err,
        }
        try testing.expectEqual(@as(usize, 0), out.written().len);
        return false;
    }

    try emit(&m, &p, &out.writer, .{});
    try t.expectTiles(out.written());
    const m2 = try Module.parse(out.written());
    var old_it = try exports.Iterator.init(m.payloadCursor(.@"export").?);
    var new_it = try exports.Iterator.init(m2.payloadCursor(.@"export").?);
    try testing.expectEqual(old_it.count + sweep_added.len, new_it.count);
    while (try old_it.next()) |want| {
        const got = (try new_it.next()).?;
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqual(want.index, got.index);
    }
    for (sweep_added) |added| {
        const got = (try new_it.next()).?;
        const want = asRead(added);
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqual(want.index, got.index);
    }
    try testing.expectEqual(null, try new_it.next());
    return true;
}

test "AddExports: for every mutated export payload, the edit succeeds exactly when the reader does" {
    var accepted: u32 = 0;
    var rejected: u32 = 0;
    for (fixtures.all) |f| {
        const m = try Module.parse(f.bytes);
        const payload = m.section(.@"export").?.payload;
        const buf = try testing.allocator.dupe(u8, f.bytes);
        defer testing.allocator.free(buf);

        for (payload.start..payload.end) |i| {
            const original = f.bytes[i];
            for ([_]u8{ 0x00, 0xFF, original ^ 0x80, original +% 1 }) |value| {
                buf[i] = value;
                if (try checkMutant(buf)) accepted += 1 else rejected += 1;
            }
            buf[i] = original;
        }
    }
    try testing.expect(accepted > 0); // the success checks actually ran
    try testing.expect(rejected > 0); // the reader and the edit really rejected things
}

// ---------------------------------------------------------------- bounds

/// The edit must fail with IndexOutOfRange, write nothing, and say what was used and how many exist
/// in which space. The space comes from the entry, which is the one that fails.
fn expectOutOfRange(base: []const u8, add: []const Entry, name: []const u8, value: u32, limit: u32) !void {
    const m = try Module.parse(base);
    const p = try patchAdd(add);
    var buf: [512]u8 = undefined;

    var d: Diagnostics = .{};
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(error.IndexOutOfRange, emit(&m, &p, &w, .{ .diag = &d }));
    try testing.expectEqual(@as(usize, 0), w.buffered().len); // atomic
    try testing.expectEqual(@as(?anyerror, error.IndexOutOfRange), d.err);
    try testing.expectEqual(@as(?SectionId, .@"export"), d.section);
    try testing.expectEqualStrings(name, d.name());
    try testing.expectEqualDeep(Diagnostics.Detail{ .out_of_range = .{
        .space = add[0].target.kind().indexSpace(),
        .value = value,
        .limit = limit,
    } }, d.detail);
    try testing.expectError(error.IndexOutOfRange, outputLen(&m, &p, .{}));
}

test "AddExports: on 8 entities per space, 7 is the last valid index of every kind" {
    for (std.enums.values(Kind)) |kind| {
        const ok = [_]Entry{existing("n", kind, 7)};
        const p = try patchAdd(&ok);
        var out: Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try emit(&(try Module.parse(&pre)), &p, &out.writer, .{});

        var buf: [8]ReadEntry = undefined;
        const got = try collect(out.written(), &buf);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(kind, got[0].kind);
        try testing.expectEqual(@as(u32, 7), got[0].index);

        const bad = [_]Entry{existing("n", kind, 8)};
        try expectOutOfRange(&pre, &bad, "n", 8, 8);
    }
}

// imports.wasm, from wasm-objdump -x: function 3 (1 imported + 2), table 1, memory 1, global 3 (2 + 1), tag 0.
const imports_totals = [_]struct { kind: Kind, total: u32 }{
    .{ .kind = .function, .total = 3 },
    .{ .kind = .table, .total = 1 },
    .{ .kind = .memory, .total = 1 },
    .{ .kind = .global, .total = 3 },
    .{ .kind = .tag, .total = 0 },
};

test "AddExports: on imports.wasm the last index is total-1 for every kind, and total is rejected" {
    const m = try Module.parse(fixtures.imports);
    for (imports_totals) |row| {
        if (row.total > 0) {
            const ok = [_]Entry{existing("new", row.kind, row.total - 1)};
            const p = try patchAdd(&ok);
            var out: Io.Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            try emit(&m, &p, &out.writer, .{});

            var buf: [16]ReadEntry = undefined;
            const got = try collect(out.written(), &buf);
            try testing.expectEqual(@as(usize, 4), got.len); // f, g, own, and ours
            try testing.expectEqualStrings("new", got[3].name);
            try testing.expectEqual(row.kind, got[3].kind);
            try testing.expectEqual(row.total - 1, got[3].index);
        }
        const bad = [_]Entry{existing("new", row.kind, row.total)};
        try expectOutOfRange(fixtures.imports, &bad, "new", row.total, row.total);
    }
}

test "AddExports: imported entities can be exported" {
    // imports.wasm: function 0 and globals 0 and 1 are imports
    const add = [_]Entry{
        existing("log_again", .function, 0),
        existing("counter_again", .global, 0),
        existing("limit_again", .global, 1),
    };
    const m = try Module.parse(fixtures.imports);
    const p = try patchAdd(&add);
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try emit(&m, &p, &out.writer, .{});

    var old_buf: [16]ReadEntry = undefined;
    const old = try collect(fixtures.imports, &old_buf);
    var want: [16]ReadEntry = undefined;
    @memcpy(want[0..old.len], old);
    for (add, 0..) |e, i| want[old.len + i] = asRead(e);
    try expectExportsAre(out.written(), want[0 .. old.len + add.len]);
}

test "AddExports: with no function section and no imports, no function index is valid" {
    try expectOutOfRange(&header, &.{existing("f", .function, 0)}, "f", 0, 0);
    try expectOutOfRange(fixtures.imports, &.{existing("t", .tag, 0)}, "t", 0, 0);
}

test "AddExports: u32 max is rejected, and the diagnostic carries it exactly" {
    try expectOutOfRange(&pre, &.{existing("m", .function, std.math.maxInt(u32))}, "m", std.math.maxInt(u32), 8);
}

// A space big enough for a two-byte index LEB. Function section: size 302 = 0xAE 0x02, count 300 = 0xAC 0x02.
const big_functions = header ++ [_]u8{ 3, 0xAE, 0x02, 0xAC, 0x02 } ++ (@as([300]u8, @splat(0)));

test "AddExports: a two-byte index LEB at the last valid index of a 300-entry space" {
    const p = try patchAdd(&.{existing("a", .function, 299)});
    // 299 = 0xAB 0x02, hard-coded so the expectation does not lean on the encoder under test
    try t.expectEmit(&big_functions, &p, &(big_functions ++ sec(7, &.{ 1, 1, 'a', 0, 0xAB, 0x02 })));
    try expectOutOfRange(&big_functions, &.{existing("a", .function, 300)}, "a", 300, 300);
}

test "AddExports: a 128-byte name costs a two-byte length LEB" {
    const name: [128]u8 = @splat('n');
    const p = try patchAdd(&.{existing(&name, .function, 7)});
    // section size 133 = 1 (count) + (2 + 128 + 1 + 1) = 0x85 0x01; name length 128 = 0x80 0x01
    const expected = pre ++ [_]u8{ 7, 0x85, 0x01, 1, 0x80, 0x01 } ++ name ++ [_]u8{ 0, 7 };
    try t.expectEmit(&pre, &p, &expected);
}

// ----------------------------------------------------------------- order

test "AddExports: the checks for one entry run in a fixed order, and the first bad entry wins" {
    // one entry wrong in every way: encoding beats duplicate beats range
    try expectEditFails(&with_a, &.{existing("\xFF", .function, 99)}, error.InvalidExportName, "\xFF", null);
    try expectEditFails(&with_a, &.{existing("a", .function, 99)}, error.DuplicateExportName, "a", null);
    try expectOutOfRange(&with_a, &.{existing("b", .function, 99)}, "b", 99, 8);

    // an earlier entry's range failure beats a later entry's duplicate
    try expectOutOfRange(&with_a, &.{
        existing("x", .function, 99),
        existing("a", .function, 0),
    }, "x", 99, 8);
    // and an earlier duplicate beats a later range failure
    try expectEditFails(&with_a, &.{
        existing("a", .function, 0),
        existing("x", .function, 99),
    }, error.DuplicateExportName, "a", null);
}

test "AddExports: a broken import section is reported before a broken export section" {
    const base = header ++
        sec(2, &([_]u8{1} ++ imp("e", "f", &.{ 0x03, 0x7F, 0x02 }))) ++ // mutability 2
        sec(7, &.{ 1, 5, 'a', 'b' }); // a truncated export entry
    const m = try Module.parse(&base);
    const p = try patchAdd(&one_new);
    var d: Diagnostics = .{};
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(error.InvalidValue, emit(&m, &p, &w, .{ .diag = &d }));
    try testing.expectEqual(@as(?SectionId, .import), d.section);
    try testing.expectEqual(0, w.buffered().len);
}

test "AddExports: a range failure leaves the writer empty, whatever the other edits are" {
    const base = pre ++ sec(10, &.{2});
    const m = try Module.parse(&base);
    const bad = [_]Entry{existing("x", .function, 99)};
    var buf: [256]u8 = undefined;

    const others = [_]struct { id: SectionId, bytes: []const u8 }{
        .{ .id = .type, .bytes = "ok" }, // an insert earlier in the file than the failing edit
        .{ .id = .code, .bytes = "ok" }, // a replace later in the file
        .{ .id = .data, .bytes = "D" }, // an insert at the tail
    };
    for (others) |other| {
        var p = try patchAdd(&bad);
        try p.setPayload(other.id, t.rawEdit(other.bytes));
        var w: Io.Writer = .fixed(&buf);
        try testing.expectError(error.IndexOutOfRange, emit(&m, &p, &w, .{}));
        try testing.expectEqual(0, w.buffered().len);
    }
}

// ------------------------------------------------------------------ sweep

/// true: the edit succeeded; false: it failed with IndexOutOfRange and wrote nothing. Anything else fails the test.
fn tryExportFunction(m: *const Module, input_index: u32) !bool {
    const entry = [_]Entry{existing("probe", .function, input_index)};
    const p = try patchAdd(&entry);
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    emit(m, &p, &out.writer, .{}) catch |err| switch (err) {
        error.IndexOutOfRange => {
            try testing.expectEqual(0, out.written().len);
            return false;
        },
        else => return err,
    };
    return true;
}

test "AddExports: for every mutated import payload, the edit fails as Counts does, or checks the bounds Counts gives" {
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

            if (Counts.of(&m, .{})) |counts| {
                accepted += 1;
                const limit = counts.total(.function);
                try testing.expectEqual(false, try tryExportFunction(&m, limit)); // one past the end
                if (limit > 0) try testing.expectEqual(true, try tryExportFunction(&m, limit - 1));
            } else |err| {
                rejected += 1;
                const entry = [_]Entry{existing("probe", .function, 0)};
                const p = try patchAdd(&entry);
                var d: Diagnostics = .{};
                var out_buf: [256]u8 = undefined;
                var w: Io.Writer = .fixed(&out_buf);
                try testing.expectError(err, emit(&m, &p, &w, .{ .diag = &d })); // the very same error
                try testing.expectEqual(@as(?SectionId, .import), d.section);
                try testing.expectEqual(0, w.buffered().len);
            }
        }
        buf[i] = original;
    }
    try testing.expect(accepted > 0); // the bounds checks actually ran
    try testing.expect(rejected > 0); // Counts and the edit really rejected things
}
