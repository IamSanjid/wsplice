const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Cursor = @import("Cursor.zig");
const errors = @import("errors.zig");
const ParseError = errors.ParseError;

const spec = @import("spec.zig");
const SectionId = spec.SectionId;
const section_id_count = spec.section_id_count;

/// A byte range in the module: absolute, end-exclusive; `start <= end`.
pub const Span = struct {
    start: u32,
    end: u32,

    pub fn len(self: Span) u32 {
        assert(self.start <= self.end);
        return self.end - self.start;
    }

    /// Turn the offsets into bytes. The caller supplies the buffer.
    pub fn slice(self: Span, bytes: []const u8) []const u8 {
        assert(self.start <= self.end);
        assert(self.end <= bytes.len);
        return bytes[self.start..self.end];
    }
};

/// One section as it sits in the file. `start` is the id byte; `payload` follows the size LEB.
/// Invariant: `start < payload.start <= payload.end`.
pub const Section = struct {
    id: SectionId,
    start: u32,
    /// The payload of the section; the id and size bytes are not included.
    payload: Span,

    /// The whole section: id byte through the last payload byte.
    pub fn whole(self: Section) Span {
        assert(self.start < self.payload.start);
        return .{ .start = self.start, .end = self.payload.end };
    }
};

/// Bytes before a payload: the id byte plus a canonical size LEB, from the same encoder the writer
/// uses.
pub fn headerLen(payload_len: u32) u32 {
    var bytes: [5]u8 = undefined; // a u32 LEB128 is at most 5 bytes
    var writer: Io.Writer = .fixed(&bytes);
    // Any u32 fits in 5 bytes: a bound, not input-dependent.
    writer.writeLeb128(payload_len) catch unreachable;
    return 1 + @as(u32, @intCast(writer.buffered().len));
}

pub const SectionIter = struct {
    cursor: Cursor,

    const Self = @This();

    pub fn init(bytes: []const u8) ParseError!SectionIter {
        var cursor = try Cursor.init(bytes); // TooLarge is already in ParseError
        const header = cursor.take(spec.header_len) catch |err| return errors.fromCursor(err);
        if (!std.mem.eql(u8, header[0..4], &spec.magic)) return error.BadMagic;
        if (!std.mem.eql(u8, header[4..8], &spec.version)) return error.BadVersion;
        assert(cursor.pos == 8);
        return .{ .cursor = cursor };
    }

    pub fn next(self: *SectionIter) ParseError!?Section {
        const cursor = &self.cursor;
        if (cursor.atEnd()) return null;

        const start = cursor.pos;
        errdefer cursor.pos = start; // a failed call leaves the iterator where it was

        const id_byte = cursor.readByte() catch |err| return errors.fromCursor(err);
        const id = std.enums.fromInt(SectionId, id_byte) orelse return error.UnknownSection;
        const size = cursor.readUleb(u32) catch |err| return errors.fromCursor(err);
        // Fails if the size runs past the end of the input.
        const payload = cursor.sub(size) catch |err| return errors.fromCursor(err);

        assert(cursor.pos >= start + 2); // progress: at least id plus one size byte
        assert(payload.end == cursor.pos); // the payload ends exactly where the iterator now stands
        assert(payload.pos > start);

        return .{
            .id = id,
            .start = start,
            .payload = .{ .start = payload.pos, .end = payload.end },
        };
    }
};

fn expectInitError(expected: anyerror, bytes: []const u8) !void {
    if (!@import("builtin").is_test) @compileError("Should be used only in tests.");
    try std.testing.expectError(expected, SectionIter.init(bytes));
}

fn expectNextError(expected: anyerror, bytes: []const u8) !void {
    if (!@import("builtin").is_test) @compileError("Should be used only in tests.");
    var iter = try SectionIter.init(bytes);
    try std.testing.expectError(expected, iter.next());
}

test "SectionIter: Header Only" {
    const header = spec.magic ++ spec.version;
    var iter = try SectionIter.init(header[0..]);
    try std.testing.expectEqual(null, try iter.next());
}

test "SectionIter: One Section" {
    const header = spec.magic ++ spec.version;
    const one_section = header ++ [_]u8{ 1, 3, 0xAA, 0xBB, 0xCC };
    var iter = try SectionIter.init(one_section[0..]);
    const sn = try iter.next();
    try std.testing.expect(sn != null);
    const s = sn.?;
    try std.testing.expectEqual(SectionId.type, s.id);
    try std.testing.expectEqual(8, s.start);
    try std.testing.expectEqual(Span{ .start = 10, .end = 13 }, s.payload);
    try std.testing.expectEqual(null, try iter.next());

    try std.testing.expectEqual(Span{ .start = 8, .end = 13 }, s.whole());
    try std.testing.expectEqualSlices(
        u8,
        &.{ 1, 3, 0xAA, 0xBB, 0xCC },
        s.whole().slice(one_section[0..]),
    );
}

test "SectionIter: Two Sections, tiling" {
    const header = spec.magic ++ spec.version;
    const two_sections = header ++ [_]u8{
        1, 3, 0xAA, 0xBB, 0xCC,
        2, 2, 0xDD, 0xEE,
    };
    var iter = try SectionIter.init(two_sections[0..]);
    const s1n = try iter.next();
    try std.testing.expect(s1n != null);
    const s1 = s1n.?;
    try std.testing.expectEqual(SectionId.type, s1.id);
    try std.testing.expectEqual(8, s1.start);
    try std.testing.expectEqual(Span{ .start = 10, .end = 13 }, s1.payload);
    const s2n = try iter.next();
    try std.testing.expect(s2n != null);
    const s2 = s2n.?;
    try std.testing.expectEqual(SectionId.import, s2.id);
    try std.testing.expectEqual(13, s2.start);
    try std.testing.expectEqual(Span{ .start = 15, .end = 17 }, s2.payload);
    try std.testing.expectEqual(null, try iter.next());
    // tiling
    try std.testing.expect(s2.start == s1.payload.end);
    try std.testing.expect(s2.whole().start == s1.whole().end);
}

test "SectionIter: custom sections repeat and come back like any other" {
    const header = spec.magic ++ spec.version;
    const bytes = header ++ [_]u8{ 0, 2, 0xAA, 0xBB, 0, 1, 0xCC };
    var iter = try SectionIter.init(&bytes);

    const a = (try iter.next()).?;
    try std.testing.expectEqual(SectionId.custom, a.id);
    try std.testing.expectEqual(8, a.start);
    try std.testing.expectEqual(Span{ .start = 10, .end = 12 }, a.payload);

    const b = (try iter.next()).?;
    try std.testing.expectEqual(SectionId.custom, b.id);
    try std.testing.expectEqual(12, b.start);
    try std.testing.expectEqual(Span{ .start = 14, .end = 15 }, b.payload);

    try std.testing.expectEqual(null, try iter.next());
}

test "SectionIter: applies no order rules (that is Module.parse's job)" {
    const header = spec.magic ++ spec.version;
    const bytes = header ++ [_]u8{ 10, 1, 0xAA, 1, 1, 0xBB }; // code, then type
    var iter = try SectionIter.init(&bytes);
    try std.testing.expectEqual(SectionId.code, (try iter.next()).?.id);
    try std.testing.expectEqual(SectionId.type, (try iter.next()).?.id);
    try std.testing.expectEqual(null, try iter.next());
}

test "SectionIter: padded size LEB is accepted and moves payload.start" {
    const header = spec.magic ++ spec.version;
    // size = 5 encoded in five bytes, then 5 payload bytes
    const bytes = header ++ [_]u8{ 1, 0x85, 0x80, 0x80, 0x80, 0x00, 1, 2, 3, 4, 5 };
    var iter = try SectionIter.init(&bytes);
    const s = (try iter.next()).?;
    try std.testing.expectEqual(8, s.start);
    try std.testing.expectEqual(Span{ .start = 14, .end = 19 }, s.payload);
    try std.testing.expectEqual(null, try iter.next());
}

test "SectionIter: zero-size section" {
    const header = spec.magic ++ spec.version;
    const bytes = header ++ [_]u8{ 1, 0 };
    var iter = try SectionIter.init(&bytes);
    const s = (try iter.next()).?;
    try std.testing.expectEqual(Span{ .start = 10, .end = 10 }, s.payload);
    try std.testing.expectEqual(null, try iter.next());
}

test "SectionIter: header errors" {
    const header = spec.magic ++ spec.version;

    try expectInitError(error.Truncated, &[_]u8{});
    try expectInitError(error.Truncated, header[0..7]);
    try expectInitError(error.BadMagic, &[_]u8{ 0x00, 0x61, 0x73, 0x6E, 1, 0, 0, 0 });
    try expectInitError(error.BadVersion, &(spec.magic ++ [_]u8{ 2, 0, 0, 0 }));
}

test "SectionIter: unknown section ids" {
    const header = spec.magic ++ spec.version;

    try expectNextError(error.UnknownSection, &(header ++ [_]u8{ 14, 0 }));
    try expectNextError(error.UnknownSection, &(header ++ [_]u8{ 0xFF, 0 }));
}

test "SectionIter: truncated sections" {
    const header = spec.magic ++ spec.version;

    // Id, no size.
    try expectNextError(error.Truncated, &(header ++ [_]u8{1}));
    // Incomplete size LEB.
    try expectNextError(error.Truncated, &(header ++ [_]u8{ 1, 0x80 }));
    // Payload too short.
    try expectNextError(error.Truncated, &(header ++ [_]u8{ 1, 5, 0xAA }));
}

test "SectionIter: size LEB errors" {
    const header = spec.magic ++ spec.version;

    // Six bytes: over the 5-byte limit even though the value is 0.
    const six_byte_size = header ++ [_]u8{ 1, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 };
    try expectNextError(error.MalformedLeb, &six_byte_size);
    // u32 max as the size on a tiny buffer: must fail cleanly, not overflow.
    const size_u32_max = header ++ [_]u8{ 1, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0xAA };
    try expectNextError(error.Truncated, &size_u32_max);
}

test "SectionIter: a failed next() leaves the iterator at that section's start" {
    const header = spec.magic ++ spec.version;
    // good section (start 8), then one whose payload is cut short (start 11)
    {
        const bytes = header ++ [_]u8{ 1, 1, 0xAA, 2, 5, 0xBB };
        var iter = try SectionIter.init(&bytes);
        _ = (try iter.next()).?;
        try std.testing.expectError(error.Truncated, iter.next());
        try std.testing.expectEqual(11, iter.cursor.pos);
        try std.testing.expectError(error.Truncated, iter.next()); // same error again
        try std.testing.expectEqual(11, iter.cursor.pos);
    }
    // good section, then an unknown id (start 10): the id byte must not stay consumed
    {
        const bytes = header ++ [_]u8{ 1, 0, 14, 0 };
        var iter = try SectionIter.init(&bytes);
        _ = (try iter.next()).?;
        try std.testing.expectError(error.UnknownSection, iter.next());
        try std.testing.expectEqual(10, iter.cursor.pos);
    }
}

test "SectionIter: every prefix of a valid module is handled without crashing" {
    // This one finds crashes. Cut a valid module at every possible length,
    // and each prefix must either parse or return an error, never panic.
    // The inner `assert`s are what gets exercised, so if they fail, the test will panic.
    const header = spec.magic ++ spec.version;
    const full = header ++ [_]u8{ 1, 3, 0xAA, 0xBB, 0xCC, 0, 2, 0xDD, 0xEE, 10, 1, 0xFF };
    for (0..full.len + 1) |len| {
        var iter = SectionIter.init(full[0..len]) catch continue;
        while (true) {
            const s = iter.next() catch break;
            if (s == null) break;
        }
    }
}
