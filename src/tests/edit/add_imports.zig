//! Tests of the import section edit: appended entries, verbatim old bytes, and failures.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const spec = @import("../../spec.zig");
const SectionId = spec.SectionId;
const AddImports = @import("../../edit/AddImports.zig");
const Diagnostics = @import("../../Diagnostics.zig");
const Module = @import("../../Module.zig");
const Patch = @import("../../Patch.zig");
const emit_mod = @import("../../emit.zig");
const t = @import("../support.zig");

const emit = emit_mod.emit;
const header = t.header;
const sec = t.sec;

fn limits(min: u64, max: ?u64) spec.Limits {
    return .{
        .flags = .{ .has_max = max != null, .is_shared = false, .is_64bit = false },
        .min = min,
        .max = max orelse 0,
    };
}

fn patchAdd(entries: []const AddImports.Entry) !Patch {
    var p = Patch.empty;
    try p.setPayload(.import, .{ .add_imports = .{ .entries = entries } });
    return p;
}

/// The edit fails with `expected_err`, writes nothing, and records the import section; the offset
/// must match (`null` when the failure has none).
fn expectEditFails(
    base: []const u8,
    entries: []const AddImports.Entry,
    expected_err: anyerror,
    expected_offset: ?u32,
) !void {
    const m = try Module.parse(base);
    const p = try patchAdd(entries);
    var buf: [64]u8 = undefined;

    var d: Diagnostics = .{};
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(expected_err, emit(&m, &p, &w, .{ .diag = &d }));
    try testing.expectEqual(@as(usize, 0), w.buffered().len); // atomic
    try testing.expectEqual(@as(?anyerror, expected_err), d.err);
    try testing.expectEqual(@as(?SectionId, .import), d.section);
    try testing.expectEqual(expected_offset, d.offset);
    try testing.expectError(expected_err, emit_mod.outputLen(&m, &p, .{}));
}

// ------------------------------------------------------------------- bytes

test "AddImports: creates the import section when the input has none" {
    const entries = [_]AddImports.Entry{.{
        .module = "env",
        .field = "mem",
        .desc = .{ .memory = limits(1, 4) },
    }};
    // count 1, "env", "mem", kind memory, limits: has_max, min 1, max 4
    const expected = header ++
        sec(2, &.{ 1, 3, 'e', 'n', 'v', 3, 'm', 'e', 'm', 2, 0x01, 1, 4 });
    const patch = try patchAdd(&entries);
    try t.expectEmit(&header, &patch, &expected);
}

test "AddImports: appends after the old entries, which are copied verbatim" {
    // A padded count, then one function import with a padded type index.
    const old_count = [_]u8{ 0x81, 0x80, 0x00 };
    const old_entry = [_]u8{ 1, 'e', 1, 'f', 0x00, 0x80, 0x00 };
    const old_payload = old_count ++ old_entry;
    const base = header ++ sec(2, &old_payload);

    const entries = [_]AddImports.Entry{.{
        .module = "m",
        .field = "g",
        .desc = .{ .global = .{
            .valtype = .{ .number_or_vector = .i32 },
            .mutability = .immutable,
        } },
    }};
    // Canonical count 2, then the old bytes exactly as they were, then the new global.
    const new_entry = [_]u8{ 1, 'm', 1, 'g', 0x03, 0x7F, 0x00 };
    const new_payload = [_]u8{2} ++ old_entry ++ new_entry;
    const expected = header ++ sec(2, &new_payload);
    const patch = try patchAdd(&entries);
    try t.expectEmit(&base, &patch, &expected);
}

test "AddImports: every descriptor shape" {
    const base = header ++ sec(1, &.{ 1, 0x60, 0, 0 }); // one type, so index 0 exists
    const entries = [_]AddImports.Entry{
        .{ .module = "e", .field = "f", .desc = .{ .function = .{ .input = 0 } } },
        .{ .module = "e", .field = "t", .desc = .{ .tag = .{ .input = 0 } } },
        .{ .module = "e", .field = "m", .desc = .{ .memory = limits(1, null) } },
        .{ .module = "e", .field = "g", .desc = .{ .global = .{
            .valtype = .{ .number_or_vector = .i32 },
            .mutability = .mutable,
        } } },
        .{ .module = "e", .field = "b", .desc = .{ .table = .{
            .reftype = .func,
            .limits = limits(2, 10),
        } } },
    };
    const expected_payload = [_]u8{5} ++
        [_]u8{ 1, 'e', 1, 'f', 0x00, 0x00 } ++ // function, type 0
        [_]u8{ 1, 'e', 1, 't', 0x04, 0x00, 0x00 } ++ // tag, attribute 0, type 0
        [_]u8{ 1, 'e', 1, 'm', 0x02, 0x00, 0x01 } ++ // memory, min 1
        [_]u8{ 1, 'e', 1, 'g', 0x03, 0x7F, 0x01 } ++ // global, i32 mutable
        [_]u8{ 1, 'e', 1, 'b', 0x01, 0x70, 0x01, 0x02, 0x0A }; // table, min 2 max 10
    const expected = base ++ sec(2, &expected_payload);
    const patch = try patchAdd(&entries);
    try t.expectEmit(&base, &patch, &expected);
}

test "AddImports: an appended type index resolves after the input's types" {
    const base = header ++ sec(1, &.{ 2, 0x60, 0, 0, 0x60, 0, 0 }); // two input types
    const entries = [_]AddImports.Entry{.{
        .module = "m",
        .field = "f",
        .desc = .{ .function = .{ .appended = 0 } },
    }};
    const expected = base ++ sec(2, &.{ 1, 1, 'm', 1, 'f', 0x00, 0x02 });
    const patch = try patchAdd(&entries);
    try t.expectEmit(&base, &patch, &expected);
}

test "AddImports: an empty edit copies the section and canonicalizes its count" {
    const old_count = [_]u8{ 0x81, 0x80, 0x00 };
    const old_entry = [_]u8{ 1, 'e', 1, 'f', 0x00, 0x00 };
    const old_payload = old_count ++ old_entry;
    const base = header ++ sec(2, &old_payload);
    const new_payload = [_]u8{1} ++ old_entry;
    const expected = header ++ sec(2, &new_payload);

    const patch = try patchAdd(&.{});
    try t.expectEmit(&base, &patch, &expected);
}

test "AddImports: names are bytes, not text" {
    // module "a\0b", field 0xFF: neither is valid UTF-8, and the edit must not judge them.
    const payload = [_]u8{1} ++ [_]u8{ 3, 'a', 0x00, 'b', 1, 0xFF, 0x00, 0x00 };
    const base = header ++ sec(2, &payload);

    const patch = try patchAdd(&.{});
    try t.expectEmit(&base, &patch, &base);
}

// ---------------------------------------------------------------- failures

test "AddImports: planAddedImports counts the entries per kind" {
    const entries = [_]AddImports.Entry{
        .{ .module = "m", .field = "f", .desc = .{ .function = .{ .input = 0 } } },
        .{ .module = "m", .field = "t", .desc = .{ .tag = .{ .input = 0 } } },
        .{ .module = "m", .field = "g", .desc = .{ .global = .{
            .valtype = .{ .number_or_vector = .i32 },
            .mutability = .immutable,
        } } },
        .{ .module = "m", .field = "f2", .desc = .{ .function = .{ .input = 0 } } },
        .{ .module = "m", .field = "m", .desc = .{ .memory = .{
            .flags = .{ .has_max = false, .is_shared = false, .is_64bit = false },
            .min = 1,
            .max = 0,
        } } },
    };
    const edit: AddImports = .{ .entries = &entries };
    const shifts = edit.planAddedImports();
    try testing.expectEqual(@as(u32, 2), shifts.count(.function));
    try testing.expectEqual(@as(u32, 1), shifts.count(.tag));
    try testing.expectEqual(@as(u32, 1), shifts.count(.global));
    try testing.expectEqual(@as(u32, 1), shifts.count(.memory));
    try testing.expectEqual(@as(u32, 0), shifts.count(.table));
}

test "AddImports: a broken old import section is reported before anything is written" {
    const base = header ++ sec(2, &.{}); // no count at all
    try expectEditFails(&base, &.{}, error.Truncated, 10); // the payload start
}

test "AddImports: a count the payload cannot hold is caught at the section start" {
    const base = header ++ sec(2, &.{5}); // count 5, but four bytes is one entry at most
    try expectEditFails(&base, &.{}, error.Truncated, 10);
}

test "AddImports: a truncated entry is reported at its start" {
    // count 1, module "e", field "f", kind function, then no type index
    const base = header ++ sec(2, &.{ 1, 1, 'e', 1, 'f', 0x00 });
    try expectEditFails(&base, &.{}, error.Truncated, 11);
}

test "AddImports: an unknown kind is reported at the entry's start" {
    const base = header ++ sec(2, &.{ 1, 1, 'e', 1, 'f', 0x05, 0x00 });
    try expectEditFails(&base, &.{}, error.InvalidKind, 11);
}

test "AddImports: bytes after the last entry are trailing, not ignored" {
    const base = header ++ sec(2, &.{ 1, 1, 'e', 1, 'f', 0x00, 0x00, 0xFF });
    try expectEditFails(&base, &.{}, error.TrailingBytes, 17); // after the entry
}

test "AddImports: an input type index outside the input's types is refused" {
    const entries = [_]AddImports.Entry{.{
        .module = "m",
        .field = "f",
        .desc = .{ .function = .{ .input = 0 } },
    }};
    const m = try Module.parse(&header);
    const p = try patchAdd(&entries);
    var buf: [64]u8 = undefined;

    var d: Diagnostics = .{};
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(error.IndexOutOfRange, emit(&m, &p, &w, .{ .diag = &d }));
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
    try testing.expectEqual(@as(?anyerror, error.IndexOutOfRange), d.err);
    try testing.expectEqual(@as(?SectionId, .import), d.section);
    try testing.expectEqual(@as(?u32, null), d.offset);
    try testing.expectEqualDeep(
        Diagnostics.Detail{ .out_of_range = .{ .space = .type, .value = 0, .limit = 0 } },
        d.detail,
    );
}

test "AddImports: invalid limits are reported before anything is written" {
    const reserved = [_]AddImports.Entry{.{
        .module = "m",
        .field = "m",
        .desc = .{ .memory = .{
            .flags = .{
                .has_max = false,
                .is_shared = false,
                .is_64bit = false,
                .reserved = 1,
            },
            .min = 1,
            .max = 0,
        } },
    }};
    try expectEditFails(&header, &reserved, error.UnsupportedFeature, null);

    const too_wide = [_]AddImports.Entry{.{
        .module = "m",
        .field = "m",
        .desc = .{ .memory = .{
            .flags = .{ .has_max = false, .is_shared = false, .is_64bit = false },
            .min = @as(u64, std.math.maxInt(u32)) + 1,
            .max = 0,
        } },
    }};
    try expectEditFails(&header, &too_wide, error.Overflow, null);
}
