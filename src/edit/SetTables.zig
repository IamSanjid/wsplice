//! Replaces table types in the table section; the section's count never changes.
//!
//!     table     ::= vec(tabletype)
//!     tabletype ::= reftype limits
//!
//! A replacement names an input table by index. Imported tables have no entry here, so they are
//! refused; added tables are not supported yet (there is no `addTable`). Entries the plan does not
//! replace are copied verbatim, padded LEBs included; a replacement is re-encoded canonically.
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

/// One input table whose type is replaced. `table` is an input table index; it must name a
/// defined table (at or after the input's imported table count).
pub const Replacement = struct {
    table: u32,
    table_type: tables.Type,
};

/// Caller-owned. `SetTables.encode` copies entries it does not name from the module.
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

/// Checks every replacement before the first byte is written. `limit` is how many input table
/// indices the input's table section can cover: with a consistent input it equals the table
/// space's size, and with an inconsistent one it is the number that is really there.
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

/// `tables.write` can fail for the caller's data: reserved limit flags, or a 32-bit value that
/// does not fit. Those are diagnosed here; `WriteFailed` is not, because it may leave bytes.
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
