//! Tests of the function section edit: appended declarations, symbolic type indices, and failures.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const spec = @import("../../spec.zig");
const SectionId = spec.SectionId;
const Module = @import("../../Module.zig");
const Patch = @import("../../Patch.zig");
const Diagnostics = @import("../../Diagnostics.zig");
const index = @import("../../index.zig");
const emit_mod = @import("../../emit.zig");
const t = @import("../support.zig");

const emit = emit_mod.emit;
const header = t.header;
const sec = t.sec;
const one_type = sec(1, &.{ 1, 0x60, 0, 0 });
const two_types = sec(1, &t.vec(2, &.{ 0x60, 0, 0 }));

fn patchAdd(types: []const index.Type) !Patch {
    var p = Patch.empty;
    try p.setPayload(.function, .{ .add_functions = .{ .types = types } });
    return p;
}

/// The edit must fail with `expected_err`, write nothing, and record the function section and detail.
fn expectEditFails(
    base: []const u8,
    types: []const index.Type,
    expected_err: anyerror,
    expected_detail: Diagnostics.Detail,
) !void {
    const m = try Module.parse(base);
    const p = try patchAdd(types);
    var buf: [64]u8 = undefined;

    var d: Diagnostics = .{};
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(expected_err, emit(&m, &p, &w, .{ .diag = &d }));
    try testing.expectEqual(@as(usize, 0), w.buffered().len); // atomic
    try testing.expectEqual(@as(?anyerror, expected_err), d.err);
    try testing.expectEqual(@as(?SectionId, .function), d.section);
    try testing.expectEqualDeep(expected_detail, d.detail);
    try testing.expectError(expected_err, emit_mod.outputLen(&m, &p, .{}));
}

// ------------------------------------------------------------------- bytes

test "AddFunctions: appends declarations and keeps the old entries" {
    const base = header ++ two_types ++ sec(3, &.{ 2, 0, 1 });
    const types = [_]index.Type{ .{ .input = 1 }, .{ .appended = 0 } };
    // two old type indices, then 1 (input) and 2 (the first appended type)
    const expected = header ++ two_types ++ sec(3, &.{ 4, 0, 1, 1, 2 });
    const patch = try patchAdd(&types);
    try t.expectEmit(&base, &patch, &expected);
}

test "AddFunctions: creates the function section when the input has none" {
    const base = header ++ one_type;
    const types = [_]index.Type{.{ .input = 0 }};
    const expected = header ++ one_type ++ sec(3, &.{ 1, 0 });
    const patch = try patchAdd(&types);
    try t.expectEmit(&base, &patch, &expected);
}

test "AddFunctions: an empty edit copies the section, count canonicalized" {
    // count 2 in three bytes, then a type index 1 padded to two bytes
    const base = header ++ two_types ++ sec(3, &.{ 0x82, 0x80, 0x00, 0x00, 0x81, 0x00 });
    const types = [_]index.Type{};
    const expected = header ++ two_types ++ sec(3, &.{ 2, 0x00, 0x81, 0x00 });
    const patch = try patchAdd(&types);
    try t.expectEmit(&base, &patch, &expected);
}

test "AddFunctions: an appended type index needs no type section yet" {
    const types = [_]index.Type{.{ .appended = 0 }};
    const expected = header ++ sec(3, &.{ 1, 0 });
    const patch = try patchAdd(&types);
    try t.expectEmit(&header, &patch, &expected);
}

// ----------------------------------------------------------------- failures

test "AddFunctions: an input type index past the input's types is out of range" {
    try expectEditFails(
        &header,
        &.{.{ .input = 0 }},
        error.IndexOutOfRange,
        .{ .out_of_range = .{ .space = .type, .value = 0, .limit = 0 } },
    );
    try expectEditFails(
        &(header ++ one_type),
        &.{.{ .input = 1 }},
        error.IndexOutOfRange,
        .{ .out_of_range = .{ .space = .type, .value = 1, .limit = 1 } },
    );
    try expectEditFails(
        &(header ++ one_type),
        &.{.{ .input = std.math.maxInt(u32) }},
        error.IndexOutOfRange,
        .{ .out_of_range = .{ .space = .type, .value = std.math.maxInt(u32), .limit = 1 } },
    );
}

test "AddFunctions: a broken old function section is reported before anything is written" {
    // count says one; the entry is cut after its first byte
    const base = header ++ sec(3, &.{ 1, 0x80 });
    const m = try Module.parse(&base);
    const p = try patchAdd(&.{});

    var d: Diagnostics = .{};
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(error.Truncated, emit(&m, &p, &w, .{ .diag = &d }));
    try testing.expectEqual(@as(?anyerror, error.Truncated), d.err);
    try testing.expectEqual(@as(?SectionId, .function), d.section);
    try testing.expectEqual(@as(?u32, 11), d.offset); // the entry, after the count
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "AddFunctions: a count the payload cannot hold is caught at the section start" {
    const base = header ++ sec(3, &.{ 2, 0 });
    const m = try Module.parse(&base);
    const p = try patchAdd(&.{});

    var d: Diagnostics = .{};
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(error.Truncated, emit(&m, &p, &w, .{ .diag = &d }));
    try testing.expectEqual(@as(?SectionId, .function), d.section);
    try testing.expectEqual(@as(?u32, 10), d.offset); // the count LEB, at the payload start
}
