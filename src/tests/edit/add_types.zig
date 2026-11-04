//! Tests of the type section edit: appended signatures, verbatim old entries, and failures.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const spec = @import("../../spec.zig");
const SectionId = spec.SectionId;
const Module = @import("../../Module.zig");
const Patch = @import("../../Patch.zig");
const Diagnostics = @import("../../Diagnostics.zig");
const AddTypes = @import("../../edit/AddTypes.zig");
const types = @import("../../payload/types.zig");
const emit_mod = @import("../../emit.zig");
const t = @import("../support.zig");

const emit = emit_mod.emit;
const header = t.header;
const sec = t.sec;

const i32_type = spec.ValueType{ .number_or_vector = .i32 };
const i64_type = spec.ValueType{ .number_or_vector = .i64 };
const f64_type = spec.ValueType{ .number_or_vector = .f64 };

fn patchAdd(signatures: []const AddTypes.Signature) !Patch {
    var p = Patch.empty;
    try p.setPayload(.type, .{ .add_types = .{ .signatures = signatures } });
    return p;
}

/// The edit must fail with `expected_err`, write nothing, and record the type section and offset.
fn expectEditFails(
    base: []const u8,
    signatures: []const AddTypes.Signature,
    expected_err: anyerror,
    expected_offset: u32,
) !void {
    const m = try Module.parse(base);
    const p = try patchAdd(signatures);
    var buf: [64]u8 = undefined;

    var d: Diagnostics = .{};
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(expected_err, emit(&m, &p, &w, .{ .diag = &d }));
    try testing.expectEqual(@as(usize, 0), w.buffered().len); // atomic
    try testing.expectEqual(@as(?anyerror, expected_err), d.err);
    try testing.expectEqual(@as(?SectionId, .type), d.section);
    try testing.expectEqual(@as(?u32, expected_offset), d.offset);
    try testing.expectError(expected_err, emit_mod.outputLen(&m, &p, .{}));
}

// ------------------------------------------------------------------- bytes

test "AddTypes: creates the type section when the input has none" {
    const signatures = [_]AddTypes.Signature{.{
        .params = .{ .typed = &.{i32_type} },
        .results = .{ .typed = &.{i64_type} },
    }};
    const expected = header ++ sec(1, &.{ 1, 0x60, 1, 0x7F, 1, 0x7E });
    const patch = try patchAdd(&signatures);
    try t.expectEmit(&header, &patch, &expected);
}

test "AddTypes: an encoded signature is copied without decoding" {
    const signatures = [_]AddTypes.Signature{types.Signature.fromEntry(.{
        .params = &.{0x7F},
        .results = &.{0x7E},
    })};
    const expected = header ++ sec(1, &.{ 1, 0x60, 1, 0x7F, 1, 0x7E });
    const patch = try patchAdd(&signatures);
    try t.expectEmit(&header, &patch, &expected);
}

test "AddTypes: appends after the input's entries" {
    const base = header ++ sec(1, &.{ 1, 0x60, 0, 0 });
    const signatures = [_]AddTypes.Signature{.{}};
    const expected = header ++
        sec(1, &.{ 2, 0x60, 0, 0, 0x60, 0, 0 });
    const patch = try patchAdd(&signatures);
    try t.expectEmit(&base, &patch, &expected);
}

test "AddTypes: parameters and results are written in order" {
    const signatures = [_]AddTypes.Signature{.{
        .params = .{ .typed = &.{ i32_type, i64_type } },
        .results = .{ .typed = &.{f64_type} },
    }};
    const expected = header ++ sec(1, &.{ 1, 0x60, 2, 0x7F, 0x7E, 1, 0x7C });
    const patch = try patchAdd(&signatures);
    try t.expectEmit(&header, &patch, &expected);
}

test "AddTypes: old entries are copied verbatim, count canonicalized" {
    // count 1 in three bytes, then one empty function type
    const base = header ++ sec(1, &.{ 0x81, 0x80, 0x00, 0x60, 0x00, 0x00 });
    const signatures = [_]AddTypes.Signature{.{}};
    const expected = header ++
        sec(1, &.{ 2, 0x60, 0x00, 0x00, 0x60, 0x00, 0x00 });
    const patch = try patchAdd(&signatures);
    try t.expectEmit(&base, &patch, &expected);
}

test "AddTypes: an empty edit copies the section" {
    const base = header ++ sec(1, &.{ 2, 0x60, 0, 0, 0x60, 1, 0x7F, 0 });
    const signatures = [_]AddTypes.Signature{};
    const patch = try patchAdd(&signatures);
    try t.expectEmit(&base, &patch, &base);
}

// ----------------------------------------------------------------- failures

test "AddTypes: a broken old type section is reported before anything is written" {
    // one function type whose results vector has no count
    const base = header ++ sec(1, &.{ 1, 0x60, 1, 0x7F });
    try expectEditFails(&base, &.{}, error.Truncated, 11); // the entry, after the count
}

test "AddTypes: a count the payload cannot hold is caught at the section start" {
    const base = header ++ sec(1, &.{1});
    try expectEditFails(&base, &.{}, error.Truncated, 10); // the payload start
}

test "AddTypes: a GC type in the input is reported as unsupported" {
    const base = header ++ sec(1, &.{ 1, 0x5E, 0x00, 0x00 }); // array type
    try expectEditFails(&base, &.{}, error.UnsupportedFeature, 11);
}
