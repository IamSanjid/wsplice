//! Replaces table types; the table count never changes.
//!
//! Imported tables and added tables are refused. Unnamed entries are copied verbatim; replacements
//! are re-encoded canonically.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Counts = @import("../payload/Counts.zig");
const Diagnostics = @import("../Diagnostics.zig");
const EncodeError = @import("../errors.zig").EncodeError;
const Module = @import("../Module.zig");
const Options = @import("../Options.zig");
const Plan = @import("../Plan.zig");
const tables = @import("../payload/tables.zig");

/// One input table whose type is replaced. `table` must name a defined table.
pub const Replacement = struct {
    table: u32,
    table_type: tables.Type,
};

/// Caller-owned; entries not named here are copied from the module.
entries: []const Replacement = &.{},

const SetTables = @This();

pub fn encode(
    self: *const SetTables,
    module: *const Module,
    plan: *const Plan,
    writer: *Io.Writer,
    options: Options,
) EncodeError!void {
    _ = plan; // the table section names no indices; only table types live here
    // First, so a broken import section is reported before anything else.
    const counts = try Counts.of(module, options);
    const old_count = try readOldCount(module, options);
    const imported = counts.importedCount(.table);
    try check(self, imported, old_count, options);

    try writer.writeLeb128(old_count); // canonical count; no table is added
    if (module.payloadCursor(.table)) |payload| {
        var iterator = try tables.Iterator.init(payload); // readOld already walked it
        var ordinal: u32 = 0;
        while (try iterator.next()) |entry| : (ordinal += 1) {
            assert(ordinal < old_count);
            if (self.replacementFor(imported + ordinal)) |replacement| {
                try writeTableType(writer, replacement.table_type, options);
            } else {
                try writer.writeAll(entry.bytes); // copied verbatim, not re-encoded
            }
        }
        assert(ordinal == old_count);
    }
}

/// Reads the whole old section, so a broken one is rejected instead of copied. Returns its count.
fn readOldCount(module: *const Module, options: Options) EncodeError!u32 {
    const payload = module.payloadCursor(.table) orelse return 0;
    var iterator = tables.Iterator.init(payload) catch |err| return Diagnostics.fail(
        options.diag,
        err,
        .{ .section = .table, .offset = payload.pos },
    );
    while (true) {
        const entry = iterator.next() catch |err| return Diagnostics.fail(options.diag, err, .{
            .section = .table,
            .offset = iterator.cursor.pos,
        });
        if (entry == null) break;
    }
    return iterator.count;
}

/// Checks every replacement before the first byte is written. `limit` is what the input's table
/// section can cover: the table space's size when consistent, the real entry count otherwise.
fn check(self: *const SetTables, imported: u32, old_count: u32, options: Options) EncodeError!void {
    const limit = std.math.add(u32, imported, old_count) catch return error.Overflow;
    for (self.entries, 0..) |*entry, i| {
        if (entry.table < imported) {
            return Diagnostics.fail(options.diag, error.ImportedTable, .{ .section = .table });
        }
        if (entry.table >= limit) {
            return Diagnostics.fail(options.diag, error.IndexOutOfRange, .{
                .section = .table,
                .detail = .{ .out_of_range = .{
                    .space = .table,
                    .value = entry.table,
                    .limit = limit,
                } },
            });
        }
        for (self.entries[0..i]) |*earlier| {
            if (earlier.table == entry.table) {
                return Diagnostics.fail(options.diag, error.DuplicateTable, .{ .section = .table });
            }
        }
    }
}

/// The replacement for this input table index, if the plan has one.
fn replacementFor(self: *const SetTables, table: u32) ?*const Replacement {
    for (self.entries) |*entry| {
        if (entry.table == table) return entry;
    }
    return null;
}

/// `tables.write` can fail for caller data: reserved flags or values that do not fit. Those are
/// diagnosed here; `WriteFailed` is not, because it may leave bytes.
fn writeTableType(writer: *Io.Writer, table_type: tables.Type, options: Options) EncodeError!void {
    tables.write(table_type, writer) catch |err| switch (err) {
        error.UnsupportedFeature, error.Overflow => return Diagnostics.fail(
            options.diag,
            err,
            .{ .section = .table },
        ),
        else => return err,
    };
}
