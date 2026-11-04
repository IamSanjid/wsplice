const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const spec = @import("../spec.zig");
const Module = @import("../Module.zig");
const Edit = @import("../edit.zig").Edit;
const Patch = @import("../Patch.zig");
const emit_mod = @import("../emit.zig");

pub const header = if (@import("builtin").is_test)
    spec.magic ++ spec.version
else
    @compileError("Shouldn't be acessing outside of test block.");

/// Builds one section: id byte, one-byte size, payload. Payload must be < 128 bytes.
pub fn sec(comptime id: u8, comptime payload: []const u8) [2 + payload.len]u8 {
    if (!@import("builtin").is_test) {
        @compileError("Should be called inside of a test block.");
    }
    comptime assert(payload.len < 0x80);
    return [_]u8{ id, @intCast(payload.len) } ++ payload[0..payload.len].*;
}

/// Parses `bytes` and checks that the sections tile the file exactly.
/// Reused by the fixture tests later.
pub fn expectTiles(bytes: []const u8) !void {
    if (!@import("builtin").is_test) {
        @compileError("Should be called inside of a test block.");
    }
    const m = try Module.parse(bytes);
    var it = m.iterator();
    var expected_start: u32 = spec.header_len;
    while (try it.next()) |s| {
        try std.testing.expectEqual(expected_start, s.start);
        expected_start = s.whole().end;
    }
    try std.testing.expectEqual(bytes.len, expected_start);
}

/// A small valid module that the mutation sweeps start from.
pub const mutation_base = if (@import("builtin").is_test) header ++
    sec(0, &.{1}) ++ sec(1, &.{ 0x60, 0, 0 }) ++ sec(3, &.{ 1, 0 }) ++
    sec(7, &.{0}) ++ sec(10, &.{0}) else @compileError("Shouldn't access without test block.");

pub fn rawEdit(bytes: []const u8) Edit {
    return .{ .raw = .{ .bytes = bytes } };
}

/// Emits with `patch` and checks what every successful emit must satisfy:
/// exact output bytes, `outputLen` agreeing with what was written, and a parseable, tiling result.
pub fn expectEmit(bytes: []const u8, patch: *const Patch, expected: []const u8) !void {
    const m = try Module.parse(bytes);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try emit_mod.emit(&m, patch, &out.writer, .{});
    try std.testing.expectEqualSlices(u8, expected, out.written());
    try std.testing.expectEqual(@as(u32, @intCast(expected.len)), try emit_mod.outputLen(&m, patch, .{}));
    try expectTiles(out.written());
}

/// One export entry with a one-byte name length and index (both < 128): name_len, name, kind, index.
pub fn exportEntry(comptime name: []const u8, comptime kind: u8, comptime index: u8) [name.len + 3]u8 {
    comptime assert(name.len < 0x80 and index < 0x80);
    return [_]u8{@intCast(name.len)} ++ name[0..name.len].* ++ [_]u8{ kind, index };
}

/// One import entry with short names (< 128 bytes). `rest` is everything after the field name:
/// the kind byte and the descriptor.
pub fn importEntry(comptime module: []const u8, comptime field: []const u8, comptime rest: []const u8) [2 + module.len + field.len + rest.len]u8 {
    comptime assert(module.len < 0x80 and field.len < 0x80);
    return [_]u8{@intCast(module.len)} ++ module[0..module.len].* ++
        [_]u8{@intCast(field.len)} ++ field[0..field.len].* ++ rest[0..rest.len].*;
}

/// One global entry: the value type byte, the mutability byte, the initializer's instructions, and
/// the `end` that terminates them.
pub fn globalEntry(
    comptime valtype_byte: u8,
    comptime mutability: spec.Mutability,
    comptime instructions: []const u8,
) [instructions.len + 3]u8 {
    comptime assert(valtype_byte < 0x80);
    return [_]u8{ valtype_byte, @backingInt(mutability) } ++
        instructions[0..instructions.len].* ++ [_]u8{0x0B};
}

fn multiplyArr(comptime n: u8, comptime arr: []const u8) [n * arr.len]u8 {
    // Zero, not `undefined`: a helper bug should produce visibly wrong bytes, never bytes that
    // differ between two reads of the same value.
    var result: [n * arr.len]u8 = @splat(0);
    for (0..n) |copy| {
        for (arr, 0..) |b, i| result[copy * arr.len + i] = b;
    }
    return result;
}

/// A vector payload: the count `n`, then `n` copies of `item`.
pub fn vec(comptime n: u8, comptime item: []const u8) [1 + (n * item.len)]u8 {
    comptime assert(n < 0x80);
    return [_]u8{n} ++ (multiplyArr(n, item));
}

/// Sections that give every index space 8 entities, so indices 0..7 are valid for every kind
/// (function, table, memory, tag, global). The contents are only as valid as `Counts` needs,
/// since it reads the declared counts. No export section: tests add or replace that themselves.
pub const entities =
    sec(3, &vec(8, &.{0})) ++ // function: 8 type indices
    sec(4, &vec(8, &.{ 0x70, 0, 1 })) ++ // table: 8 x funcref, min 1
    sec(5, &vec(8, &.{ 0, 1 })) ++ // memory: 8 x min 1
    sec(13, &vec(8, &.{ 0, 0 })) ++ // tag: 8 x type 0
    sec(6, &vec(8, &.{ 0x7F, 0, 0x41, 0, 0x0B })); // global: 8 x i32 const 0
