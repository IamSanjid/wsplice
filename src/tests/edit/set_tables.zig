//! Tests of the table section edit: replaced types, verbatim old entries, and failures.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const spec = @import("../../spec.zig");
const SectionId = spec.SectionId;
const Diagnostics = @import("../../Diagnostics.zig");
const Module = @import("../../Module.zig");
const Patch = @import("../../Patch.zig");
const SetTables = @import("../../edit/SetTables.zig");
const emit_mod = @import("../../emit.zig");
const tables = @import("../../payload/tables.zig");
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

fn tableType(reftype: spec.AbstractHeapType, min: u64, max: ?u64) tables.Type {
    return .{ .reftype = reftype, .limits = limits(min, max) };
}

fn patchSet(entries: []const SetTables.Replacement) !Patch {
    var p = Patch.empty;
    try p.setPayload(.table, .{ .set_tables = .{ .entries = entries } });
    return p;
}

/// The edit fails with `expected_err`, writes nothing, and records the table section; the offset
/// must match (`null` when the failure has none).
fn expectEditFails(
    base: []const u8,
    entries: []const SetTables.Replacement,
    expected_err: anyerror,
    expected_offset: ?u32,
) !void {
    const m = try Module.parse(base);
    const p = try patchSet(entries);
    var buf: [64]u8 = undefined;

    var d: Diagnostics = .{};
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(expected_err, emit(&m, &p, &w, .{ .diag = &d }));
    try testing.expectEqual(@as(usize, 0), w.buffered().len); // atomic
    try testing.expectEqual(@as(?anyerror, expected_err), d.err);
    try testing.expectEqual(@as(?SectionId, .table), d.section);
    try testing.expectEqual(expected_offset, d.offset);
    try testing.expectError(expected_err, emit_mod.outputLen(&m, &p, .{}));
}

// ------------------------------------------------------------------- bytes

const one_table = header ++ sec(4, &.{ 1, 0x70, 0x00, 1 });
const two_tables = header ++ sec(4, &.{ 2, 0x70, 0x00, 1, 0x6F, 0x01, 2, 4 });
const table_import_payload = [_]u8{ 1, 1, 'e', 1, 't', 0x01, 0x70, 0x00, 1 };
const imported_and_defined = header ++
    sec(2, &table_import_payload) ++
    sec(4, &.{ 2, 0x70, 0x00, 1, 0x6F, 0x01, 2, 4 });

test "SetTables: replaces the table type and canonicalizes the section" {
    const entries = [_]SetTables.Replacement{.{
        .table = 0,
        .table_type = tableType(.func, 1, 4),
    }};
    const expected = header ++ sec(4, &.{ 1, 0x70, 0x01, 1, 4 });
    const patch = try patchSet(&entries);
    try t.expectEmit(&one_table, &patch, &expected);
}

test "SetTables: copies the entries it does not replace verbatim" {
    const old_count = [_]u8{ 0x82, 0x80, 0x00 };
    const first = [_]u8{ 0x70, 0x00, 0x81, 0x80, 0x00 }; // min 1, padded
    const second = [_]u8{ 0x6F, 0x01, 2, 4 };
    const old_payload = old_count ++ first ++ second;
    const base = header ++ sec(4, &old_payload);

    const entries = [_]SetTables.Replacement{.{ // input table 1: the second entry
        .table = 1,
        .table_type = tableType(.func, 3, 5),
    }};
    const new_payload = [_]u8{2} ++ first ++ [_]u8{ 0x70, 0x01, 3, 5 };
    const expected = header ++ sec(4, &new_payload);
    const patch = try patchSet(&entries);
    try t.expectEmit(&base, &patch, &expected);
}

test "SetTables: an imported table shifts the defined indices it names" {
    // The input's table 0 is imported; tables 1 and 2 are the two section entries.
    const entries = [_]SetTables.Replacement{.{
        .table = 2,
        .table_type = tableType(.func, 1, null),
    }};
    const expected_payload = [_]u8{ 2, 0x70, 0x00, 1, 0x70, 0x00, 1 };
    const expected = header ++
        sec(2, &table_import_payload) ++
        sec(4, &expected_payload);
    const patch = try patchSet(&entries);
    try t.expectEmit(&imported_and_defined, &patch, &expected);
}

test "SetTables: multiple replacements share one canonical count" {
    const entries = [_]SetTables.Replacement{
        .{ .table = 0, .table_type = tableType(.@"extern", 2, 4) },
        .{ .table = 1, .table_type = tableType(.func, 3, null) },
    };
    const expected = header ++ sec(4, &.{ 2, 0x6F, 0x01, 2, 4, 0x70, 0x00, 3 });
    const patch = try patchSet(&entries);
    try t.expectEmit(&two_tables, &patch, &expected);
}

test "SetTables: an empty edit copies the section and canonicalizes its count" {
    const old_payload = [_]u8{ 0x81, 0x80, 0x00, 0x70, 0x00, 1 };
    const base = header ++ sec(4, &old_payload);
    const expected = header ++ sec(4, &.{ 1, 0x70, 0x00, 1 });

    const patch = try patchSet(&.{});
    try t.expectEmit(&base, &patch, &expected);
}

// ---------------------------------------------------------------- failures

test "SetTables: an imported table has no table-section entry" {
    const entries = [_]SetTables.Replacement{.{
        .table = 0, // the imported table
        .table_type = tableType(.func, 1, null),
    }};
    try expectEditFails(&imported_and_defined, &entries, error.ImportedTable, null);
}

test "SetTables: a table index outside the section is refused" {
    const entries = [_]SetTables.Replacement{.{
        .table = 1,
        .table_type = tableType(.func, 1, null),
    }};
    const m = try Module.parse(&one_table);
    const p = try patchSet(&entries);
    var buf: [64]u8 = undefined;

    var d: Diagnostics = .{};
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(error.IndexOutOfRange, emit(&m, &p, &w, .{ .diag = &d }));
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
    try testing.expectEqual(@as(?anyerror, error.IndexOutOfRange), d.err);
    try testing.expectEqual(@as(?SectionId, .table), d.section);
    try testing.expectEqual(@as(?u32, null), d.offset);
    try testing.expectEqualDeep(
        Diagnostics.Detail{ .out_of_range = .{ .space = .table, .value = 1, .limit = 1 } },
        d.detail,
    );
}

test "SetTables: a table takes at most one replacement" {
    const entries = [_]SetTables.Replacement{
        .{ .table = 0, .table_type = tableType(.func, 1, null) },
        .{ .table = 0, .table_type = tableType(.func, 2, null) },
    };
    try expectEditFails(&one_table, &entries, error.DuplicateTable, null);
}

test "SetTables: a module without a table section has no table 0" {
    const entries = [_]SetTables.Replacement{.{
        .table = 0,
        .table_type = tableType(.func, 1, null),
    }};
    try expectEditFails(&header, &entries, error.IndexOutOfRange, null);
}

test "SetTables: a broken old table section is reported before anything is written" {
    const base = header ++ sec(4, &.{ 1, 0x70, 0x00, 0x80 }); // min LEB never ends
    try expectEditFails(&base, &.{}, error.Truncated, 11); // the entry, after the count
}

test "SetTables: an unsupported old reference type is reported" {
    const base = header ++ sec(4, &.{ 1, 0x63, 0x00, 0x00, 1 }); // prefixed ref type
    try expectEditFails(&base, &.{}, error.UnsupportedFeature, 11);
}

test "SetTables: invalid replacement limits are reported before anything is written" {
    const entries = [_]SetTables.Replacement{.{
        .table = 0,
        .table_type = .{
            .reftype = .func,
            .limits = .{
                .flags = .{
                    .has_max = false,
                    .is_shared = false,
                    .is_64bit = false,
                    .reserved = 1,
                },
                .min = 1,
                .max = 0,
            },
        },
    }};
    try expectEditFails(&one_table, &entries, error.UnsupportedFeature, null);
}
