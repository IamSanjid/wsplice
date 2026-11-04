//! Tests of the AddGlobals edit, through the public emit API.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const spec = @import("../../spec.zig");
const SectionId = spec.SectionId;
const Cursor = @import("../../Cursor.zig");
const Module = @import("../../Module.zig");
const Patch = @import("../../Patch.zig");
const Diagnostics = @import("../../Diagnostics.zig");
const globals = @import("../../payload/globals.zig");
const AddGlobals = @import("../../edit/AddGlobals.zig");
const Global = AddGlobals.Global;
const emit_mod = @import("../../emit.zig");
const t = @import("../support.zig");
const fixtures = @import("../fixtures/fixtures.zig");

const emit = emit_mod.emit;
const outputLen = emit_mod.outputLen;
const header = t.header;
const sec = t.sec;

// ---------------------------------------------------------------- helpers

fn patchAdd(entries: []const Global) !Patch {
    var p = Patch.empty;
    try p.setPayload(.global, .{ .add_globals = .{ .entries = entries } });
    return p;
}

/// `n` copies of `item`, concatenated: the entry bytes of a payload, without its count.
fn repeat(comptime n: usize, comptime item: []const u8) [n * item.len]u8 {
    var result: [n * item.len]u8 = undefined;
    for (0..n) |i| result[i * item.len ..][0..item.len].* = item[0..item.len].*;
    return result;
}

/// A failing edit must: return `expected_err` from emit and outputLen (with and without
/// diagnostics), write nothing, and record the same error, the global section, and the offset.
fn expectEditFails(
    base: []const u8,
    add: []const Global,
    expected_err: anyerror,
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
    try testing.expectEqual(@as(?SectionId, .global), d.section);
    try testing.expectEqual(expected_offset, d.offset);
    try testing.expectEqualDeep(Diagnostics.Detail.none, d.detail);

    try testing.expectError(expected_err, outputLen(&m, &p, .{}));

    var w2: Io.Writer = .fixed(&buf); // no diagnostics: same error, still nothing written
    try testing.expectError(expected_err, emit(&m, &p, &w2, .{}));
    try testing.expectEqual(@as(usize, 0), w2.buffered().len);
}

// ------------------------------------------------------------- the entries

const i32_const_42: Global = .{
    .global_type = .{
        .valtype = .{ .number_or_vector = .i32 },
        .mutability = .mutable,
    },
    .init = .{ .i32 = 42 },
};
const funcref_null: Global = .{
    .global_type = .{
        .valtype = .{ .reference = .func },
        .mutability = .immutable,
    },
    .init = .{ .ref_null = .func },
};

const i32_global = t.globalEntry(0x7F, .immutable, &.{ 0x41, 0x00 }); // i32 const 0
const i32_42_global = t.globalEntry(0x7F, .mutable, &.{ 0x41, 0x2A }); // i32 mut 42
const funcref_global = t.globalEntry(0x70, .immutable, &.{ 0xD0, 0x70 }); // ref.null func
/// An old initializer whose immediate is a padded LEB: copying it must not re-encode it.
const padded_global = t.globalEntry(0x7F, .immutable, &.{ 0x41, 0x80, 0x00 });

const old_eight = repeat(8, &i32_global);
const old_eight_payload = [_]u8{8} ++ old_eight;
const base_eight = header ++ sec(6, &old_eight_payload);

const one_more_payload = [_]u8{9} ++ old_eight ++ i32_42_global;
const eleven_payload = [_]u8{10} ++ old_eight ++ i32_42_global ++ funcref_global;

// ------------------------------------------------------------ exact bytes

const Layout = struct {
    name: []const u8,
    base: []const u8,
    add: []const Global,
    expected: []const u8,
};

const layout_cases = [_]Layout{
    .{
        .name = "append one global",
        .base = &base_eight,
        .add = &.{i32_const_42},
        .expected = &(header ++ sec(6, &one_more_payload)),
    },
    .{
        .name = "append two globals of different types",
        .base = &base_eight,
        .add = &.{ i32_const_42, funcref_null },
        .expected = &(header ++ sec(6, &eleven_payload)),
    },
    .{
        .name = "create the section in a header-only module",
        .base = &header,
        .add = &.{i32_const_42},
        .expected = &(header ++ sec(6, &([_]u8{1} ++ i32_42_global))),
    },
    .{
        .name = "create the section before a later one",
        .base = &(header ++ sec(7, &.{0})),
        .add = &.{i32_const_42},
        .expected = &(header ++ sec(6, &([_]u8{1} ++ i32_42_global)) ++ sec(7, &.{0})),
    },
    .{
        .name = "create the section at the tail, a trailing custom stays last",
        .base = &(header ++ sec(1, &.{1}) ++ sec(0, &.{9})),
        .add = &.{i32_const_42},
        .expected = &(header ++ sec(1, &.{1}) ++
            sec(6, &([_]u8{1} ++ i32_42_global)) ++ sec(0, &.{9})),
    },
    .{
        .name = "nothing to add leaves an existing section as it was",
        .base = &base_eight,
        .add = &.{},
        .expected = &base_eight,
    },
    .{
        .name = "nothing to add still writes a canonical count",
        .base = &(header ++ sec(6, &([_]u8{ 0x88, 0x80, 0x00 } ++ old_eight))),
        .add = &.{},
        .expected = &base_eight,
    },
    .{
        // A design decision, pinned here so a change is deliberate: the edit always yields a section.
        .name = "nothing to add to a module without globals creates an empty section",
        .base = &header,
        .add = &.{},
        .expected = &(header ++ sec(6, &.{0})),
    },
    .{
        .name = "an old section with zero entries",
        .base = &(header ++ sec(6, &.{0})),
        .add = &.{i32_const_42},
        .expected = &(header ++ sec(6, &([_]u8{1} ++ i32_42_global))),
    },
    .{
        .name = "a padded old initializer is copied verbatim, not re-encoded",
        .base = &(header ++ sec(6, &([_]u8{1} ++ padded_global))),
        .add = &.{i32_const_42},
        .expected = &(header ++ sec(6, &([_]u8{2} ++ padded_global ++ i32_42_global))),
    },
};

test "AddGlobals: exact bytes" {
    for (layout_cases) |row| {
        const p = try patchAdd(row.add);
        t.expectEmit(row.base, &p, row.expected) catch |err| {
            std.debug.print("case failed: {s}\n", .{row.name});
            return err;
        };
    }
}

// ------------------------------------------------------------- LEB widths

const many_entries = repeat(127, &i32_global); // 635 bytes
const many_payload = [_]u8{127} ++ many_entries; // 636: a two-byte size
const many_base = header ++ [_]u8{ 6, 0xFC, 0x04 } ++ many_payload;

test "AddGlobals: the count LEB grows exactly at 127 -> 128" {
    const p = try patchAdd(&.{i32_const_42});
    // count 128 = 0x80 0x01; payload 2 + 635 + 5 = 642 = 0x82 0x05
    const expected = header ++ [_]u8{ 6, 0x82, 0x05, 0x80, 0x01 } ++ many_entries ++ i32_42_global;
    try t.expectEmit(&many_base, &p, &expected);
}

const size_entries = repeat(25, &i32_global); // 125 bytes
const size_payload = [_]u8{25} ++ size_entries; // 126: a one-byte size
const size_base = header ++ [_]u8{ 6, 126 } ++ size_payload;

test "AddGlobals: the section size LEB grows exactly at 127 -> 128" {
    const p = try patchAdd(&.{i32_const_42});
    // payload 1 + 125 + 5 = 131 = 0x83 0x01; count 26
    const expected = header ++ [_]u8{ 6, 0x83, 0x01, 26 } ++ size_entries ++ i32_42_global;
    try t.expectEmit(&size_base, &p, &expected);
}

// ----------------------------------------------------------------- failures

test "AddGlobals: a malformed old section is rejected, never copied, and the offset is absolute" {
    const one = [_]Global{i32_const_42};
    // The payload starts at byte 10 in all of these: 8 header + id + size. Offsets are absolute.
    try expectEditFails(&(header ++ sec(6, &.{})), &one, error.Truncated, 10);
    try expectEditFails(
        &(header ++ sec(6, &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 })),
        &one,
        error.MalformedLeb,
        10,
    );
    try expectEditFails(
        &(header ++ sec(6, &.{ 5, 0x7F, 0, 0x41, 0, 0x0B })),
        &one,
        error.Truncated,
        10,
    );
    try expectEditFails(&(header ++ sec(6, &.{ 1, 0x7F })), &one, error.Truncated, 10); // the init bound
    try expectEditFails(&(header ++ sec(6, &.{ 1, 0x7F, 0x02, 0x0B })), &one, error.InvalidValue, 11);
    try expectEditFails(&(header ++ sec(6, &.{ 1, 0x63, 0, 0 })), &one, error.UnsupportedFeature, 11);
    try expectEditFails(&(header ++ sec(6, &.{ 1, 0x7F, 0, 0x41, 0 })), &one, error.Truncated, 11);
    // a stray byte after the last entry: the offset points at it, not at the entry
    try expectEditFails(
        &(header ++ sec(6, &.{ 1, 0x7F, 0, 0x41, 0, 0x0B, 0xFF })),
        &one,
        error.TrailingBytes,
        16,
    );
}

test "AddGlobals: a failing edit leaves the writer empty, whatever the other edits are" {
    const base = header ++ sec(1, &.{1}) ++ sec(6, &.{ 1, 0x7F }) ++ sec(10, &.{2});
    const m = try Module.parse(&base);
    const one = [_]Global{i32_const_42};

    const others = [_]struct { id: SectionId, bytes: []const u8 }{
        .{ .id = .type, .bytes = "ok" }, // a replace EARLIER in the file than the failing edit
        .{ .id = .code, .bytes = "ok" }, // a replace LATER in the file
        .{ .id = .function, .bytes = "F" }, // an insert between the replace and the failing edit
        .{ .id = .data, .bytes = "D" }, // an insert at the tail
    };
    for (others) |other| {
        var p = try patchAdd(&one);
        try p.setPayload(other.id, t.rawEdit(other.bytes));

        var buf: [256]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        try testing.expectError(error.Truncated, emit(&m, &p, &w, .{}));
        try testing.expectEqual(@as(usize, 0), w.buffered().len);
        try testing.expectError(error.Truncated, outputLen(&m, &p, .{}));
    }
}

// ----------------------------------------------------------------- fixtures

fn expectAdded(
    it: *globals.Iterator,
    value_type: spec.ValueType,
    mutability: spec.Mutability,
    instructions: []const u8,
) !void {
    const got = (try it.next()).?;
    try testing.expectEqualDeep(
        globals.Type{ .valtype = value_type, .mutability = mutability },
        got.global_type,
    );
    try testing.expectEqualSlices(u8, instructions, got.instructions);
}

test "AddGlobals: fixtures keep their old globals byte for byte and gain the new ones" {
    const added = [_]Global{ i32_const_42, funcref_null };
    for (fixtures.all) |f| {
        const m = try Module.parse(f.bytes);
        const p = try patchAdd(&added);
        var out: Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try emit(&m, &p, &out.writer, .{});
        try testing.expectEqual(@as(u32, @intCast(out.written().len)), try outputLen(&m, &p, .{}));
        try t.expectTiles(out.written());

        const m2 = try Module.parse(out.written());
        const old_it = try globals.Iterator.init(m.payloadCursor(.global).?);
        const new_it = try globals.Iterator.init(m2.payloadCursor(.global).?);
        try testing.expectEqual(old_it.count + added.len, new_it.count);

        // the old entry bytes are copied verbatim, right after the new canonical count
        try testing.expect(std.mem.startsWith(
            u8,
            new_it.entries.slice(m2.bytes),
            old_it.entries.slice(m.bytes),
        ));

        // every old global reads back identically, then the two added ones
        var old_again = try globals.Iterator.init(m.payloadCursor(.global).?);
        var new_again = try globals.Iterator.init(m2.payloadCursor(.global).?);
        while (try old_again.next()) |want| {
            const got = (try new_again.next()).?;
            try testing.expectEqualDeep(want.global_type, got.global_type);
            try testing.expectEqualSlices(u8, want.instructions, got.instructions);
        }
        try expectAdded(&new_again, .{ .number_or_vector = .i32 }, .mutable, &.{ 0x41, 0x2A });
        try expectAdded(&new_again, .{ .reference = .func }, .immutable, &.{ 0xD0, 0x70 });
        try testing.expectEqual(null, try new_again.next());

        // every other section, customs included, is byte-identical and in the same order
        var before = m.iterator();
        var after = m2.iterator();
        while (try before.next()) |a| {
            const b = (try after.next()).?;
            try testing.expectEqual(a.id, b.id);
            if (a.id == .global) continue;
            try testing.expectEqualSlices(u8, a.whole().slice(m.bytes), b.whole().slice(m2.bytes));
        }
        try testing.expectEqual(null, try after.next());
    }
}

// -------------------------------------------------------------------- sweep

fn payloadReadable(payload: []const u8) bool {
    var it = globals.Iterator.init(Cursor.init(payload) catch return false) catch return false;
    while (it.next() catch return false) |_| {}
    return true;
}

test "AddGlobals: for every mutated global payload, the edit succeeds exactly when the reader does" {
    const added = [_]Global{i32_const_42};
    var accepted: u32 = 0;
    var rejected: u32 = 0;
    for (fixtures.all) |f| {
        const m = try Module.parse(f.bytes);
        const payload = m.section(.global).?.payload;
        const buf = try testing.allocator.dupe(u8, f.bytes);
        defer testing.allocator.free(buf);

        for (payload.start..payload.end) |i| {
            const original = f.bytes[i];
            for ([_]u8{ 0x00, 0xFF, original ^ 0x80, original +% 1 }) |value| {
                buf[i] = value;
                const mutant = try Module.parse(buf); // only payload bytes changed: the frame is intact
                const readable = payloadReadable(mutant.section(.global).?.payload.slice(mutant.bytes));
                const p = try patchAdd(&added);
                var out: Io.Writer.Allocating = .init(testing.allocator);
                defer out.deinit();

                if (emit(&mutant, &p, &out.writer, .{})) |_| {
                    try testing.expect(readable); // the edit accepted what the reader accepts
                    accepted += 1;
                    try t.expectTiles(out.written());
                } else |err| {
                    try testing.expect(!readable); // and rejected everything the reader rejects
                    rejected += 1;
                    switch (err) {
                        error.Truncated,
                        error.MalformedLeb,
                        error.TrailingBytes,
                        error.InvalidValue,
                        error.UnsupportedFeature,
                        => {},
                        else => return err,
                    }
                    try testing.expectEqual(@as(usize, 0), out.written().len);
                }
            }
            buf[i] = original;
        }
    }
    try testing.expect(accepted > 0); // the success checks actually ran
    try testing.expect(rejected > 0); // the edit really rejected things
}

// -------------------------------------------------------------------- order

test "AddGlobals: combines with other edits, and the section lands in rank order" {
    const base = header ++ sec(1, &.{1});
    const one = [_]Global{i32_const_42};

    var p = Patch.empty;
    try p.setPayload(.@"export", t.rawEdit("x"));
    try p.setPayload(.global, .{ .add_globals = .{ .entries = &one } });
    try p.setPayload(.memory, t.rawEdit("m"));

    // rank: type 1, memory 5, global 6, export 7
    const expected = header ++ sec(1, &.{1}) ++ sec(5, "m") ++
        sec(6, &([_]u8{1} ++ i32_42_global)) ++ sec(7, "x");
    try t.expectEmit(&base, &p, &expected);
}
