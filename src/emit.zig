const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Edit = @import("edit.zig").Edit;
const EmitError = @import("errors.zig").EmitError;
const Module = @import("Module.zig");
const Patch = @import("Patch.zig");
const Plan = @import("Plan.zig");
const Run = @import("Run.zig");
const custom_apply = @import("custom/apply.zig");

const spec = @import("spec.zig");
const SectionId = spec.SectionId;
const section_id_count = spec.section_id_count;

const section_mod = @import("section.zig");
const Section = section_mod.Section;
const Options = @import("Options.zig");

/// `Patch.empty` is legal and copies the input through unchanged. A caller that already knows the
/// patch is empty should copy the file itself, which skips the measure pass.
pub fn emit(
    module: *const Module,
    patch: *const Patch,
    writer: *Io.Writer,
    options: Options,
) EmitError!void {
    return emitWalk(module, patch, writer, options);
}

/// Exact size of what `emit` would write. One encode per patched section, zero bytes written.
pub fn outputLen(
    module: *const Module,
    patch: *const Patch,
    options: Options,
) EmitError!u32 {
    const plan: Plan = .fromPatch(patch);
    return (try measure(module, patch, &plan, options)).len_total;
}

fn writeSection(
    writer: *Io.Writer,
    module: *const Module,
    id: SectionId,
    payload_len: u32,
    edit: *const Edit,
    plan: *const Plan,
    options: Options,
) EmitError!void {
    assert(id != .custom);
    try writer.writeByte(@backingInt(id));
    // A canonical (shortest) size LEB, even if the old one was padded.
    try writer.writeLeb128(payload_len);
    try edit.encode(module, plan, writer, options);
}

fn emitWalk(
    module: *const Module,
    patch: *const Patch,
    writer: *Io.Writer,
    options: Options,
) EmitError!void {
    const plan: Plan = .fromPatch(patch);
    const measured = try measure(module, patch, &plan, options); // nothing written yet
    const len: u32 = @intCast(module.bytes.len); // Module.parse guarantees this fits
    var run: Run = .{ .bytes = module.bytes, .writer = writer };

    try run.flush(spec.header_len);
    try custom_apply.writeStart(&run, patch, options);
    assert(run.start == spec.header_len); // start appends write only, they do not consume input

    var iterator = module.iterator();
    var end_prev: u32 = spec.header_len;
    var tail_pos: u32 = len; // where sections that belong after the last existing one go
    var rank_next: u8 = 1; // the lowest rank that has not been settled yet
    var applied: u8 = 0;
    // The same bytes already passed through this iterator inside `Module.parse`, so it cannot fail.
    while (iterator.next() catch unreachable) |section| {
        assert(section.start == end_prev); // sections tile the file
        end_prev = section.whole().end;
        if (section.id == .custom) {
            try custom_apply.writeInputEdit(&run, module, section, patch, options);
            continue; // unmatched customs ride along inside the run
        }

        const rank = section.id.rank();
        assert(rank >= rank_next); // Module.parse enforced strictly increasing ranks
        applied += try insertMissing(&run, module, patch, &measured, .{
            .rank_from = rank_next,
            .rank_to = rank,
            .at = section.start,
        }, &plan, options);
        rank_next = rank + 1;
        tail_pos = section.whole().end;

        const edit = patch.get(section.id) orelse continue; // untouched sections ride along too
        // measure() filled the payload size of every patched slot.
        const payload_len = measured.payload_len[@backingInt(section.id)].?;
        try spliceSection(&run, module, section, payload_len, edit, &plan, options);
        applied += 1;
    }
    assert(end_prev == len);

    const rank_end: u8 = section_id_count;
    applied += try insertMissing(&run, module, patch, &measured, .{
        .rank_from = rank_next,
        .rank_to = rank_end,
        .at = tail_pos,
    }, &plan, options);
    assert(applied == patch.count()); // every patched section was replaced or inserted once

    try run.flush(len); // the last run, including any trailing customs
    try custom_apply.writeEnd(&run, patch, options);
    assert(run.start == len);
}

fn spliceSection(
    run: *Run,
    module: *const Module,
    section: Section,
    payload_len: u32,
    edit: *const Edit,
    plan: *const Plan,
    options: Options,
) EmitError!void {
    try run.flush(section.start); // everything before this section, unchanged
    try writeSection(run.writer, module, section.id, payload_len, edit, plan, options);
    run.skip(section.whole().end); // the old bytes of this section are dropped
}

/// Add one section that the input does not have, at input offset `at`. Nothing is skipped.
fn insertSection(
    run: *Run,
    module: *const Module,
    at: u32,
    id: SectionId,
    payload_len: u32,
    edit: *const Edit,
    plan: *const Plan,
    options: Options,
) EmitError!void {
    try run.flush(at);
    try writeSection(run.writer, module, id, payload_len, edit, plan, options);
}

/// A stretch of ranks the input has no sections for, and the input offset they belong at.
const MissingRange = struct {
    rank_from: u8,
    rank_to: u8,
    at: u32,
};

/// Writes every patched section with a rank in `[range.rank_from, range.rank_to)`, in rank order,
/// at `range.at`. Returns how many were written.
fn insertMissing(
    run: *Run,
    module: *const Module,
    patch: *const Patch,
    measured: *const Measured,
    range: MissingRange,
    plan: *const Plan,
    options: Options,
) EmitError!u8 {
    assert(range.rank_from >= 1);
    assert(range.rank_from <= range.rank_to);
    assert(range.rank_to <= section_id_count);
    var written: u8 = 0;
    var rank = range.rank_from;
    while (rank < range.rank_to) : (rank += 1) {
        const id = SectionId.fromRank(rank);
        const edit = patch.get(id) orelse continue;
        assert(module.section(id) == null); // no existing section has a rank in this range
        const payload_len = measured.payload_len[@backingInt(id)].?;
        try insertSection(run, module, range.at, id, payload_len, edit, plan, options);
        written += 1;
    }
    return written;
}

/// Everything that has to be known before the first output byte is written.
const Measured = struct {
    /// New payload size per section id; non-null exactly where the patch has an edit.
    payload_len: [section_id_count]?u32 = @splat(null),
    /// Size of the whole output module.
    len_total: u32,
};

/// Runs every edit once, into a counter. All edit errors surface here, so a failing edit leaves
/// the writer untouched.
fn measure(
    module: *const Module,
    patch: *const Patch,
    plan: *const Plan,
    options: Options,
) EmitError!Measured {
    var result: Measured = .{ .len_total = 0 };
    var len_total: u64 = module.bytes.len;

    for (1..section_id_count) |rank| {
        const id = SectionId.fromRank(@intCast(rank));
        const edit = patch.get(id) orelse continue;

        const payload_len = try edit.encodedLen(module, plan, options);
        result.payload_len[@backingInt(id)] = payload_len;

        // Absent: nothing to remove.
        const len_old: u64 = if (module.section(id)) |old| old.whole().len() else 0;
        const len_new: u64 = section_mod.headerLen(payload_len) + payload_len;
        assert(len_total >= len_old);
        len_total = len_total - len_old + len_new;
    }

    if (patch.custom.len != 0) {
        const delta = try custom_apply.measureDelta(module, patch, options);
        const adjusted = @as(i64, @intCast(len_total)) + delta;
        assert(adjusted >= 0);
        len_total = @intCast(adjusted);
    }

    result.len_total = std.math.cast(u32, len_total) orelse return error.Overflow;
    return result;
}

const testing = std.testing;

fn expectedSizeLebLen(value: u32) u32 {
    if (!@import("builtin").is_test) {
        @compileError("Should be used only in tests.");
    }
    var remaining = value;
    var len: u32 = 1;
    while (remaining >= 0x80) : (remaining >>= 7) len += 1;
    return len;
}

test "section header length matches an independent LEB length at every boundary" {
    const values = [_]u32{
        0, 1, 127, // 1 byte
        128, 16383, 16384, // 2 bytes, then 3
        2097151, 2097152, 268435455, // 3 bytes, then 4
        268435456, std.math.maxInt(u32), // 5 bytes
    };
    for (values) |value| {
        try testing.expectEqual(1 + expectedSizeLebLen(value), section_mod.headerLen(value));
    }
}

test "section header length agrees with what writeSection really writes" {
    const module = try Module.parse(&(spec.magic ++ spec.version));
    const plan: Plan = .{};
    for ([_]u32{ 0, 1, 127, 128, 300, 16383, 16384 }) |len| {
        const payload = try testing.allocator.alloc(u8, len);
        defer testing.allocator.free(payload);
        @memset(payload, 0xAB);

        const edit: Edit = .{ .raw = .{ .bytes = payload } };
        var out: Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try writeSection(&out.writer, &module, .type, len, &edit, &plan, .{});

        try testing.expectEqual(section_mod.headerLen(len) + len, out.written().len);
    }
}
