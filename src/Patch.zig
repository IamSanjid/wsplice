//! At most one edit per non-custom section. An edit writes its section's whole payload, so two
//! edits for the same section cannot be chained: a plan with two operations for one section folds
//! them into one edit, and `setPayload` refuses a second write rather than replacing the first.
//! Custom sections are a separate list because they repeat and have no rank.
const std = @import("std");
const assert = std.debug.assert;

const Edit = @import("edit.zig").Edit;
const CustomEdit = @import("custom/edit.zig").Edit;

const PatchError = @import("errors.zig").PatchError;

const spec = @import("spec.zig");
const SectionId = spec.SectionId;
const section_id_count = spec.section_id_count;

slots: [section_id_count]?Edit, // indexed by @backingInt(id); slot 0 (custom) stays null
/// Custom-section edits are a list, not slots: custom sections repeat and have no rank. Borrowed
/// from the builder, or set directly by a hand-built patch.
custom: []const CustomEdit = &.{},

const Patch = @This();

pub const empty: Patch = .{ .slots = @splat(null) };

comptime {
    // Patch is passed around by pointer, but it should stay cheap to copy.
    // If a future Edit variant makes this fail, shrink the variant (borrow, don't embed).
    assert(@sizeOf(Patch) <= 1024);
}

/// Asserts `id != .custom` (custom sections are not patchable).
pub fn setPayload(self: *Patch, id: SectionId, edit: Edit) PatchError!void {
    assert(id != .custom);
    self.assertInvariants();

    const slot = &self.slots[@backingInt(id)];
    if (slot.* != null) return error.SectionAlreadyPatched; // the first edit stays

    slot.* = edit;
    assert(self.slots[@backingInt(id)] != null);
    self.assertInvariants();
}

/// Asserts `id != .custom`. The edit is borrowed: the pointer stays valid until this slot is set
/// again, and the patch must outlive it.
pub fn get(self: *const Patch, id: SectionId) ?*const Edit {
    assert(id != .custom);
    self.assertInvariants();
    const slot = &self.slots[@backingInt(id)];
    return if (slot.*) |*edit| edit else null;
}

pub fn count(self: *const Patch) u8 {
    var slots_set: u8 = 0;
    for (self.slots) |slot| {
        if (slot != null) slots_set += 1;
    }
    assert(slots_set < section_id_count); // at most 13: slot 0 can never be set
    return slots_set;
}

pub fn isEmpty(self: *const Patch) bool {
    return self.count() == 0 and self.custom.len == 0;
}

fn assertInvariants(self: *const Patch) void {
    assert(self.slots[0] == null); // custom sections are never patched
}

fn raw(bytes: []const u8) Edit {
    if (!@import("builtin").is_test) {
        @compileError("Should be used only in tests.");
    }
    return .{ .raw = .{ .bytes = bytes } };
}

// `expectEqual` on slices compares pointers, not contents, so compare the bytes explicitly.
fn expectRaw(expected: []const u8, actual: ?*const Edit) !void {
    if (!@import("builtin").is_test) {
        @compileError("Should be used only in tests.");
    }
    try std.testing.expect(actual != null);
    const edit = actual.?;
    try std.testing.expectEqual(std.meta.Tag(Edit).raw, std.meta.activeTag(edit.*));
    try std.testing.expectEqualStrings(expected, edit.raw.bytes);
}

test "Patch: empty" {
    const p = Patch.empty;
    try std.testing.expect(p.isEmpty());
    try std.testing.expectEqual(@as(u8, 0), p.count());
    for (p.slots) |slot| try std.testing.expectEqual(null, slot);
}

test "Patch: set then get returns the same edit" {
    var p = Patch.empty;
    try p.setPayload(.@"export", raw("abc"));
    try expectRaw("abc", p.get(.@"export"));
    try std.testing.expect(!p.isEmpty());
    try std.testing.expectEqual(@as(u8, 1), p.count());
}

test "Patch: two sections are independent" {
    var p = Patch.empty;
    try p.setPayload(.type, raw("t"));
    try p.setPayload(.code, raw("c"));
    try expectRaw("t", p.get(.type));
    try expectRaw("c", p.get(.code));
    try std.testing.expectEqual(@as(u8, 2), p.count());
}

test "Patch: patching the same section twice fails and keeps the first edit" {
    var p = Patch.empty;
    try p.setPayload(.table, raw("first"));
    try std.testing.expectError(error.SectionAlreadyPatched, p.setPayload(.table, raw("second")));
    try expectRaw("first", p.get(.table));
    try std.testing.expectEqual(@as(u8, 1), p.count());
}

test "Patch: get on an unpatched section is null even when others are patched" {
    var p = Patch.empty;
    try p.setPayload(.type, raw("t"));
    try std.testing.expectEqual(null, p.get(.function));
    try std.testing.expectEqual(null, p.get(.tag)); // id 13: the last slot
    try std.testing.expectEqual(null, p.get(.data_count));
}

// 6: also catches indexing by rank instead of by id
test "Patch: every non-custom section can be patched, each keeps its own edit" {
    var store: [section_id_count][1]u8 = undefined;
    var p = Patch.empty;

    for (1..section_id_count) |r| {
        const id = SectionId.fromRank(@intCast(r));
        store[@backingInt(id)] = .{@backingInt(id)}; // payload byte = the section's id
        try p.setPayload(id, raw(&store[@backingInt(id)]));
    }
    try std.testing.expectEqual(@as(u8, section_id_count - 1), p.count()); // 13

    for (1..section_id_count) |r| {
        const id = SectionId.fromRank(@intCast(r));
        try expectRaw(&.{@backingInt(id)}, p.get(id));
    }
    try std.testing.expectEqual(null, p.slots[0]); // custom slot untouched
}

test "Patch: a copy is independent of the original" {
    var a = Patch.empty;
    try a.setPayload(.type, raw("a"));

    var b = a; // copies the slots
    try b.setPayload(.code, raw("b"));

    try std.testing.expectEqual(@as(u8, 1), a.count());
    try std.testing.expectEqual(@as(u8, 2), b.count());
    try std.testing.expectEqual(null, a.get(.code));
    try expectRaw("a", b.get(.type)); // the copy kept what was set before copying

    try std.testing.expect(Patch.empty.isEmpty()); // the shared constant is untouched
}

test "Patch: failed sets never change count or other slots" {
    var p = Patch.empty;
    try p.setPayload(.import, raw("i"));
    const before = p;

    for (0..3) |_| {
        try std.testing.expectError(error.SectionAlreadyPatched, p.setPayload(.import, raw("x")));
    }
    try std.testing.expectEqual(before.count(), p.count());
    try expectRaw("i", p.get(.import));
    for (before.slots, p.slots) |x, y| {
        try std.testing.expectEqual(x == null, y == null);
    }
}
