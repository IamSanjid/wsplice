const std = @import("std");
const assert = std.debug.assert;

const Cursor = @import("Cursor.zig");
const Diagnostics = @import("Diagnostics.zig");
const Options = @import("Options.zig");
const Query = @import("Query.zig");

const errors = @import("errors.zig");
pub const ParseError = errors.ParseError;
const PayloadError = errors.PayloadError;

const section_mod = @import("section.zig");
pub const Span = section_mod.Span;
pub const Section = section_mod.Section;
pub const SectionIter = section_mod.SectionIter;

const spec = @import("spec.zig");
const SectionId = spec.SectionId;
const section_id_count = spec.section_id_count;

/// Must be a valid WebAssembly module, and must not be changed while the Module is alive.
/// The Module does not own the bytes, and does not copy them, merely references them.
bytes: []const u8,
/// Indexed by @backingInt(SectionId). Slot 0 (custom) is never used:
/// custom sections can repeat and are found by iteration.
sections: [section_id_count]?Section,

const Module = @This();

pub fn parse(bytes: []const u8) ParseError!Module {
    return parseWith(bytes, .{});
}

/// Parses like `parse`, recording the first failure and where it was when `options.diag` is set.
/// Failures in a section frame point at the frame's start; a failure inside a payload is the
/// section reader's to report.
pub fn parseWith(bytes: []const u8, options: Options) ParseError!Module {
    var iter = SectionIter.init(bytes) catch |err|
        return Diagnostics.fail(options.diag, err, .{ .offset = headerFailOffset(err) });

    const len: u32 = @intCast(bytes.len); // SectionIter.init rejected anything over 4 GiB
    assert(len >= spec.header_len); // the header survived init

    var module: Module = .{ .bytes = bytes, .sections = @splat(null) };

    var rank_prev: u8 = 0; // rank of the previous non-custom section
    var end_prev: u32 = spec.header_len; // where the previous section ended (tiling)

    // The smallest section is an id byte plus a one-byte size, so this bounds the count.
    const sections_max = @divFloor(len - spec.header_len, 2);
    var count: u32 = 0;

    while (iter.next() catch |err| return Diagnostics.fail(options.diag, err, .{
        .offset = iter.cursor.pos, // the failing frame's start: `next` restored the cursor
    })) |s| {
        count += 1;
        assert(count <= sections_max);
        assert(s.start == end_prev); // sections tile the file with no gaps
        end_prev = s.whole().end;

        if (s.id == .custom) continue; // custom sections: any place, any number, no order

        const slot = &module.sections[@backingInt(s.id)];
        if (slot.* != null) {
            // check this FIRST: a duplicate whose rank also went backwards is still a duplicate
            return Diagnostics.fail(options.diag, error.DuplicateSection, .{
                .section = s.id,
                .offset = s.start,
            });
        }
        const rank = s.id.rank();
        if (rank < rank_prev) {
            return Diagnostics.fail(options.diag, error.SectionOrder, .{
                .section = s.id,
                .offset = s.start,
            });
        }
        assert(rank > rank_prev); // ranks are unique, so equal is impossible here

        slot.* = s;
        rank_prev = rank;
    }

    assert(end_prev == len); // the iterator reached the end: the file is fully covered
    assert(count <= sections_max);
    module.assertInvariants();
    return module;
}

/// Where a header failure sits: the magic starts at 0 and the version follows it.
fn headerFailOffset(err: ParseError) ?u32 {
    return switch (err) {
        error.TooLarge => null, // the input is too long to have "a byte" to point at
        error.BadVersion => @intCast(spec.magic.len),
        else => 0, // BadMagic, and a truncated header points at its start
    };
}

/// Reads this module through `Query`: the counts are computed once, here.
pub fn query(self: *const Module, options: Options) PayloadError!Query {
    return Query.init(self, options);
}

fn assertInvariants(self: *const Module) void {
    assert(self.bytes.len <= std.math.maxInt(u32));
    assert(self.sections[0] == null); // custom sections are never indexed

    for (self.sections, 0..) |maybe_section_a, slot| {
        const section_a = maybe_section_a orelse continue;
        assert(@backingInt(section_a.id) == slot);
        assert(section_a.start >= spec.header_len);
        assert(section_a.start < section_a.payload.start);
        assert(section_a.payload.start <= section_a.payload.end);
        assert(section_a.payload.end <= self.bytes.len);

        for (self.sections) |maybe_section_b| {
            const section_b = maybe_section_b orelse continue;
            if (section_a.id == section_b.id) continue;
            // Rank order and file order must agree.
            if (section_a.id.rank() < section_b.id.rank()) {
                assert(section_a.start < section_b.start);
            } else {
                assert(section_a.start > section_b.start);
            }
        }
    }
}

pub fn section(self: *const Module, id: SectionId) ?Section {
    assert(id != .custom);
    return self.sections[@backingInt(id)];
}

pub fn payloadCursor(self: *const Module, id: SectionId) ?Cursor {
    const s = self.section(id) orelse return null;
    return .{
        .bytes = self.bytes,
        .pos = s.payload.start,
        .end = s.payload.end,
    };
}

pub fn iterator(self: *const Module) SectionIter {
    // `parse` already validated the header and the length fits in u32.
    return .{
        .cursor = .{
            .bytes = self.bytes,
            .pos = spec.header_len,
            .end = @intCast(self.bytes.len),
        },
    };
}
