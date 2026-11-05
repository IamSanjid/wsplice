//! Appends exports, creating the export section when absent.
//!
//! Targets are resolved here: this is where the input's counts and the plan's added imports first
//! meet. The patch carries no counters, so it stays independent of the input it is emitted against.
const std = @import("std");
const Io = std.Io;

const Cursor = @import("../Cursor.zig");
const Counts = @import("../payload/Counts.zig");
const Module = @import("../Module.zig");
const Options = @import("../Options.zig");
const Diagnostics = @import("../Diagnostics.zig");
const EncodeError = @import("../errors.zig").EncodeError;
const Plan = @import("../Plan.zig");
const exports = @import("../payload/exports.zig");
const index = @import("../index.zig");

pub const Entry = struct {
    name: []const u8,
    target: index.Target,
};

/// Caller-owned. Names are borrowed and must stay alive until `emit` returns.
entries: []const Entry,

const AddExports = @This();

pub fn encode(
    self: *const AddExports,
    module: *const Module,
    plan: *const Plan,
    writer: *Io.Writer,
    options: Options,
) EncodeError!void {
    // First, so a broken import section is reported before anything else.
    const counts = try Counts.of(module, options);
    const old = try readOld(module, options);

    const old_payload = module.payloadCursor(.@"export");
    var count_new: u32 = 0;
    for (self.entries, 0..) |*entry, ordinal| {
        try checkNewEntry(self.entries, ordinal, entry, old_payload, &counts, plan, options);
        count_new = std.math.add(u32, count_new, 1) catch return error.Overflow;
    }
    const count_total = std.math.add(u32, old.count, count_new) catch return error.Overflow;

    try writer.writeLeb128(count_total); // canonical count, even if the old one was padded
    try writer.writeAll(old.entries); // old entries are copied verbatim, not re-encoded
    for (self.entries) |*entry| {
        const name_len = std.math.cast(u32, entry.name.len) orelse return error.Overflow;
        try writer.writeLeb128(name_len);
        try writer.writeAll(entry.name);
        try writer.writeByte(@backingInt(entry.target.kind()));
        try writer.writeLeb128(try checkedIndex(entry, &counts, plan, options));
    }
}

const Old = struct { count: u32 = 0, entries: []const u8 = &.{} };

/// Reads the whole old section, so a broken one is rejected instead of copied.
fn readOld(module: *const Module, options: Options) EncodeError!Old {
    const payload = module.payloadCursor(.@"export") orelse return .{};
    const where: Diagnostics.Where = .{ .section = .@"export", .offset = payload.pos };
    var iterator = exports.Iterator.init(payload) catch |err|
        return Diagnostics.fail(options.diag, err, where);
    while (true) {
        const entry = iterator.next() catch |err| return Diagnostics.fail(options.diag, err, .{
            .section = .@"export",
            .offset = iterator.cursor.pos,
        });
        if (entry == null) break;
    }
    return .{ .count = iterator.count, .entries = iterator.entries.slice(module.bytes) };
}

/// The index this entry will export, or the out-of-range diagnostic for the one case that fails.
fn checkedIndex(
    entry: *const Entry,
    counts: *const Counts,
    plan: *const Plan,
    options: Options,
) EncodeError!u32 {
    const kind = entry.target.kind();
    const layout = index.Layout.of(kind, counts, &plan.added_imports);
    // Checked here so the diagnostic can name the number used. Only `.input` can fail; plan
    // ordinals are the plan's to hand out.
    if (entry.target.inputIndex()) |used| {
        if (used >= layout.input_total) {
            return Diagnostics.fail(options.diag, error.IndexOutOfRange, .{
                .section = .@"export",
                .name = entry.name,
                .detail = .{ .out_of_range = .{
                    .space = kind.indexSpace(),
                    .value = used,
                    .limit = layout.input_total,
                } },
            });
        }
    }
    return entry.target.resolve(counts, &plan.added_imports);
}

fn checkNewEntry(
    entries: []const Entry,
    ordinal: usize,
    entry: *const Entry,
    old_payload: ?Cursor,
    counts: *const Counts,
    plan: *const Plan,
    options: Options,
) EncodeError!void {
    const where: Diagnostics.Where = .{ .section = .@"export", .name = entry.name };
    if (!std.unicode.utf8ValidateSlice(entry.name)) {
        return Diagnostics.fail(options.diag, error.InvalidExportName, where);
    }

    // Against the new entries before this one: names are unique across all kinds.
    for (entries[0..ordinal]) |*previous| {
        if (std.mem.eql(u8, previous.name, entry.name)) {
            return Diagnostics.fail(options.diag, error.DuplicateExportName, where);
        }
    }

    // Against the old entries, which readOld already checked for well-formedness.
    if (old_payload) |payload| {
        var iterator = try exports.Iterator.init(payload);
        while (try iterator.next()) |existing| {
            if (std.mem.eql(u8, existing.name, entry.name)) {
                return Diagnostics.fail(options.diag, error.DuplicateExportName, where);
            }
        }
    }

    _ = try checkedIndex(entry, counts, plan, options);
}
