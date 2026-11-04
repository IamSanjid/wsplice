const std = @import("std");
const spec = @import("../spec.zig");
const SectionId = spec.SectionId;
const Cursor = @import("../Cursor.zig");
const Module = @import("../Module.zig");
const Diagnostics = @import("../Diagnostics.zig");
const section = @import("../section.zig");
const Span = section.Span;
const Section = section.Section;
const support = @import("support.zig");
const fixtures = @import("fixtures/fixtures.zig");

const header = support.header;
const sec = support.sec;
const expectTiles = support.expectTiles;
const mutation_base = support.mutation_base;

test "Module.parse: header only" {
    const m = try Module.parse(&header);
    for (m.sections) |s| try std.testing.expectEqual(null, s);
    try expectTiles(&header);
}

test "Module.parse: one section of each kind, in rank order" {
    const bytes = header ++
        sec(1, &.{1}) ++ sec(2, &.{2}) ++ sec(3, &.{3}) ++ sec(4, &.{4}) ++ sec(5, &.{5}) ++
        sec(13, &.{13}) ++ sec(6, &.{6}) ++ sec(7, &.{7}) ++ sec(8, &.{8}) ++ sec(9, &.{9}) ++
        sec(12, &.{12}) ++ sec(10, &.{10}) ++ sec(11, &.{11});
    const m = try Module.parse(&bytes);

    const order = [_]SectionId{
        .type,      .import, .function, .table,      .memory, .tag,  .global,
        .@"export", .start,  .element,  .data_count, .code,   .data,
    };
    for (order, 0..) |id, k| {
        const s = m.section(id).?;
        const start: u32 = @intCast(spec.header_len + 3 * k); // every section here is 3 bytes
        try std.testing.expectEqual(id, s.id);
        try std.testing.expectEqual(start, s.start);
        try std.testing.expectEqual(Span{ .start = start + 2, .end = start + 3 }, s.payload);
        // the payload byte equals the id, so a wrong slot would show up here
        try std.testing.expectEqual(@backingInt(id), m.bytes[s.payload.start]);
    }
    try expectTiles(&bytes);
}

test "Module.parse: valid orders" {
    // tag sits between memory and global
    _ = try Module.parse(&(header ++ sec(5, &.{1}) ++ sec(13, &.{2}) ++ sec(6, &.{3})));
    // data_count comes before code
    _ = try Module.parse(&(header ++ sec(12, &.{1}) ++ sec(10, &.{2})));
    // sparse: only some sections present
    _ = try Module.parse(&(header ++ sec(1, &.{1}) ++ sec(7, &.{2}) ++ sec(11, &.{3})));
}

test "Module.parse: custom sections anywhere and not indexed" {
    const bytes = header ++
        sec(0, &.{1}) ++
        sec(0, &.{2}) ++ // before the first, several in a row
        sec(1, &.{3}) ++
        sec(0, &.{4}) ++ // between
        sec(3, &.{5}) ++
        sec(0, &.{6}); // after the last
    const m = try Module.parse(&bytes);
    try std.testing.expectEqual(null, m.sections[0]);
    try std.testing.expectEqual(14, m.section(.type).?.start);
    try std.testing.expectEqual(20, m.section(.function).?.start);
    try expectTiles(&bytes);
}

test "Module.parse: duplicate sections" {
    try std.testing.expectError(
        error.DuplicateSection,
        Module.parse(&(header ++ sec(1, &.{1}) ++ sec(1, &.{2}))),
    );
    // the duplicate has a lower rank than `import`, so this checks the duplicate test runs first
    try std.testing.expectError(
        error.DuplicateSection,
        Module.parse(&(header ++ sec(1, &.{1}) ++ sec(2, &.{2}) ++ sec(1, &.{3}))),
    );
    try std.testing.expectError(
        error.DuplicateSection,
        Module.parse(&(header ++ sec(13, &.{1}) ++ sec(13, &.{2}))),
    );
}

test "Module.parse: out-of-order sections" {
    const cases = [_][]const u8{
        &(header ++ sec(7, &.{1}) ++ sec(3, &.{2})), // export before function
        &(header ++ sec(10, &.{1}) ++ sec(12, &.{2})), // code before data_count
        &(header ++ sec(6, &.{1}) ++ sec(13, &.{2})), // tag after global
        &(header ++ sec(11, &.{1}) ++ sec(10, &.{2})), // data before code
        &(header ++ sec(8, &.{1}) ++ sec(7, &.{2})), // start before export
    };
    for (cases) |bytes| {
        try std.testing.expectError(error.SectionOrder, Module.parse(bytes));
    }
}

test "Module.parse: errors from the iterator pass through" {
    try std.testing.expectError(
        error.BadMagic,
        Module.parse(&[_]u8{ 0x00, 0x61, 0x73, 0x6E, 1, 0, 0, 0 }),
    );
    try std.testing.expectError(error.Truncated, Module.parse(header[0..5]));
    try std.testing.expectError(error.Truncated, Module.parse(&(header ++ [_]u8{ 1, 5, 0xAA })));
    try std.testing.expectError(error.UnknownSection, Module.parse(&(header ++ [_]u8{ 14, 0 })));
}

/// `parseWith` must return `expected_err` and record it with the given section and offset.
fn expectParseFail(
    bytes: []const u8,
    expected_err: anyerror,
    expected_section: ?SectionId,
    expected_offset: ?u32,
) !void {
    var d: Diagnostics = .{};
    try std.testing.expectError(expected_err, Module.parseWith(bytes, .{ .diag = &d }));
    try std.testing.expectEqual(@as(?anyerror, expected_err), d.err);
    try std.testing.expectEqual(expected_section, d.section);
    try std.testing.expectEqual(expected_offset, d.offset);
}

test "Module.parseWith: header failures point at the header field" {
    try expectParseFail(
        &[_]u8{ 0x00, 0x61, 0x73, 0x6E, 1, 0, 0, 0 },
        error.BadMagic,
        null,
        0,
    );
    try expectParseFail(&(spec.magic ++ [_]u8{ 2, 0, 0, 0 }), error.BadVersion, null, 4);
    try expectParseFail(header[0..5], error.Truncated, null, 0);
}

test "Module.parseWith: section failures point at the section frame" {
    // the unknown id byte sits at the first section's start
    try expectParseFail(&(header ++ [_]u8{ 14, 0 }), error.UnknownSection, null, 8);
    // a size that runs past the end: the frame starts at 8
    try expectParseFail(&(header ++ [_]u8{ 1, 5, 0xAA }), error.Truncated, null, 8);
    // order and duplicates point at the section they are about
    try expectParseFail(
        &(header ++ sec(7, &.{1}) ++ sec(3, &.{2})),
        error.SectionOrder,
        .function,
        11,
    );
    try expectParseFail(
        &(header ++ sec(1, &.{1}) ++ sec(1, &.{2})),
        error.DuplicateSection,
        .type,
        11,
    );
}

test "Module.parseWith: a clean parse records nothing" {
    var d: Diagnostics = .{};
    _ = try Module.parseWith(&header, .{ .diag = &d });
    try std.testing.expect(!d.hasFailure());
}

test "Module.payloadCursor: absolute positions and absent sections" {
    const bytes = header ++ sec(1, &.{ 0xAA, 0xBB }) ++ sec(3, &.{0xCC});
    const m = try Module.parse(&bytes);

    var type_c = m.payloadCursor(.type).?;
    try std.testing.expectEqual(10, type_c.pos);
    try std.testing.expectEqual(12, type_c.end);
    try std.testing.expectEqual(0xAA, try type_c.readByte());
    try std.testing.expectEqual(0xBB, try type_c.readByte());
    try std.testing.expect(type_c.atEnd());

    var func_c = m.payloadCursor(.function).?;
    try std.testing.expectEqual(14, func_c.pos); // absolute, not 0
    try std.testing.expectEqual(0xCC, try func_c.readByte());
    try std.testing.expectError(error.EndOfStream, func_c.readByte()); // window enforced

    try std.testing.expect(m.payloadCursor(.table) == null);
    try std.testing.expect(m.section(.table) == null);
}

test "Module.iterator: file order, custom included, matches the index" {
    const bytes = header ++
        sec(0, &.{1}) ++ sec(1, &.{2}) ++ sec(0, &.{3}) ++ sec(3, &.{4}) ++ sec(10, &.{5});
    const m = try Module.parse(&bytes);

    const expected_ids = [_]SectionId{ .custom, .type, .custom, .function, .code };
    var it = m.iterator();
    var count: usize = 0;
    while (try it.next()) |s| : (count += 1) {
        try std.testing.expectEqual(expected_ids[count], s.id);
        if (s.id != .custom) try std.testing.expectEqual(s, m.section(s.id).?);
    }
    try std.testing.expectEqual(expected_ids.len, count);
}

// (hand-made module now; fixtures reuse expectTiles later)
test "Module.parse: sections tile the file, padded size LEB included" {
    // size 3 written as the padded five-byte LEB 83 80 80 80 00
    const padded = header ++ [_]u8{ 1, 0x83, 0x80, 0x80, 0x80, 0x00, 1, 2, 3 } ++ sec(3, &.{4});
    try expectTiles(&padded);
    const m = try Module.parse(&padded);
    try std.testing.expectEqual(14, m.section(.type).?.payload.start);
}

test "Module.parse: single-byte mutations never crash" {
    var accepted: u32 = 0;
    var rejected: u32 = 0;
    var buf: [mutation_base.len]u8 = mutation_base;
    for (0..buf.len) |i| {
        const original = mutation_base[i];
        for ([_]u8{ 0x00, 0xFF, original ^ 0x80, original +% 1 }) |value| {
            buf[i] = value;
            if (Module.parse(&buf)) |_| {
                accepted += 1;
                try expectTiles(&buf); // anything that parses must still tile the file
            } else |_| {
                rejected += 1;
            }
        }
        buf[i] = original;
    }
    try std.testing.expect(accepted > 0); // the tiling check actually ran
    try std.testing.expect(rejected > 0); // the gate actually rejected things
}

test "Module.parse: every prefix is handled without crashing" {
    var accepted: u32 = 0;
    var rejected: u32 = 0;
    for (0..mutation_base.len + 1) |len| {
        const prefix = mutation_base[0..len];
        if (Module.parse(prefix)) |_| {
            accepted += 1;
            try expectTiles(prefix);
        } else |_| {
            rejected += 1;
        }
    }
    try std.testing.expect(accepted > 0); // the tiling check actually ran
    try std.testing.expect(rejected > 0 and rejected < mutation_base.len + 1); // the gate actually rejected things
}

test "fixtures: sections match wasm-objdump -h" {
    const Expected = struct {
        id: SectionId,
        payload_start: u32,
        payload_end: u32,
        count: ?u32 = null, // vector count from `-h`; null for custom sections
    };
    const Case = struct { bytes: []const u8, sections: []const Expected };

    // Pasted from: wasm-objdump -h minimal.wasm
    const minimal_sections = [_]Expected{
        .{ .id = .type, .payload_start = 0x0a, .payload_end = 0x11, .count = 1 },
        .{ .id = .function, .payload_start = 0x13, .payload_end = 0x15, .count = 1 },
        .{ .id = .memory, .payload_start = 0x17, .payload_end = 0x1b, .count = 1 },
        .{ .id = .global, .payload_start = 0x1d, .payload_end = 0x23, .count = 1 },
        .{ .id = .@"export", .payload_start = 0x25, .payload_end = 0x3f, .count = 3 },
        .{ .id = .code, .payload_start = 0x41, .payload_end = 0x4a, .count = 1 },
        .{ .id = .data, .payload_start = 0x4c, .payload_end = 0x57, .count = 1 },
        .{ .id = .custom, .payload_start = 0x59, .payload_end = 0x77 },
    };

    // Pasted from: wasm-objdump -h zig_basic.wasm
    // (type 2, function 3, table 1, memory 1, global 2, export 6, code 3, data 1)
    const zig_basic_sections = [_]Expected{
        .{ .id = .type, .payload_start = 0x0a, .payload_end = 0x15, .count = 2 },
        .{ .id = .function, .payload_start = 0x17, .payload_end = 0x1b, .count = 3 },
        .{ .id = .table, .payload_start = 0x1d, .payload_end = 0x22, .count = 1 },
        .{ .id = .memory, .payload_start = 0x24, .payload_end = 0x27, .count = 1 },
        .{ .id = .global, .payload_start = 0x29, .payload_end = 0x3a, .count = 2 },
        .{ .id = .@"export", .payload_start = 0x3c, .payload_end = 0x77, .count = 6 },
        .{ .id = .code, .payload_start = 0x79, .payload_end = 0xb3, .count = 3 },
        .{ .id = .data, .payload_start = 0xb5, .payload_end = 0xc3, .count = 1 },
    };

    // Pasted from: wasm-objdump -h imports.wasm
    const imports_sections = [_]Expected{
        .{ .id = .type, .payload_start = 0x0a, .payload_end = 0x10, .count = 1 },
        .{ .id = .import, .payload_start = 0x12, .payload_end = 0x57, .count = 5 },
        .{ .id = .function, .payload_start = 0x59, .payload_end = 0x5c, .count = 2 },
        .{ .id = .global, .payload_start = 0x5e, .payload_end = 0x64, .count = 1 },
        .{ .id = .@"export", .payload_start = 0x66, .payload_end = 0x75, .count = 3 },
        .{ .id = .code, .payload_start = 0x77, .payload_end = 0x84, .count = 2 },
    };

    const cases = [_]Case{
        .{ .bytes = fixtures.minimal, .sections = &minimal_sections },
        .{ .bytes = fixtures.zig_basic, .sections = &zig_basic_sections },
        .{ .bytes = fixtures.imports, .sections = &imports_sections },
    };

    for (cases) |case| {
        const m = try Module.parse(case.bytes);
        var it = m.iterator();
        var end_prev: u32 = spec.header_len;

        for (case.sections) |e| {
            const s = (try it.next()).?;
            try std.testing.expectEqual(e.id, s.id);
            try std.testing.expectEqual(e.payload_start, s.payload.start);
            try std.testing.expectEqual(e.payload_end, s.payload.end);

            // one id byte + one size byte, since every size here is < 128
            try std.testing.expectEqual(s.payload.start - 2, s.start);
            try std.testing.expectEqual(@backingInt(e.id), case.bytes[s.start]);
            try std.testing.expectEqual(end_prev, s.start); // tiling
            end_prev = s.whole().end;

            if (e.id != .custom) { // custom sections are not in the index
                try std.testing.expectEqual(s, m.section(e.id).?);
                if (e.count) |n| {
                    var c = m.payloadCursor(e.id).?;
                    try std.testing.expectEqual(n, try c.readUleb(u32));
                }
            }
        }
        try std.testing.expectEqual(null, try it.next());
        try std.testing.expectEqual(case.bytes.len, end_prev);

        for (1..spec.section_id_count) |r| {
            const id = SectionId.fromRank(@intCast(r));
            var listed = false;
            for (case.sections) |e| {
                if (e.id == id) listed = true;
            }
            if (!listed) try std.testing.expect(m.section(id) == null);
        }
    }
}

test "fixtures: minimal's trailing custom section is named \"name\"" {
    const m = try Module.parse(fixtures.minimal);
    var it = m.iterator();
    var custom: ?Section = null;
    while (try it.next()) |s| {
        if (s.id == .custom) custom = s;
    }
    const s = custom.?;

    var c: Cursor = .{ .bytes = m.bytes, .pos = s.payload.start, .end = s.payload.end };
    const name_len = try c.readUleb(u32);
    try std.testing.expectEqualStrings("name", try c.take(name_len));
    try std.testing.expectEqual(25, c.remaining()); // the name subsections, untouched
}
