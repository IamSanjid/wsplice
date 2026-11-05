//! Appends imports, creating the section when absent.
//!
//! Names are written verbatim. Function and tag descriptors carry symbolic type indices; table,
//! memory and global descriptors are complete. Old entries and padded LEBs are copied unchanged;
//! the count is canonical. Added imports shift their space's indices; raw bytes are never remapped.
const std = @import("std");
const Io = std.Io;

const Counts = @import("../payload/Counts.zig");
const Diagnostics = @import("../Diagnostics.zig");
const EncodeError = @import("../errors.zig").EncodeError;
const Module = @import("../Module.zig");
const Options = @import("../Options.zig");
const Plan = @import("../Plan.zig");
const globals = @import("../payload/globals.zig");
const imports = @import("../payload/imports.zig");
const index = @import("../index.zig");
const limits = @import("../payload/limits.zig");
const spec = @import("../spec.zig");

/// One import to add. The names borrow bytes and must stay alive until `emit` returns.
pub const Entry = struct {
    module: []const u8, // raw bytes, not checked for UTF-8
    field: []const u8,
    desc: Desc,
};

/// The entity an import brings in. Function/tag descriptors name a type symbolically.
pub const Desc = union(spec.ExternalKind) {
    function: index.Type,
    table: imports.Table,
    memory: spec.Limits,
    global: imports.Global,
    tag: index.Type,
};

/// One entry per added import, in added-import order.
entries: []const Entry = &.{},

const AddImports = @This();

pub fn encode(
    self: *const AddImports,
    module: *const Module,
    plan: *const Plan,
    writer: *Io.Writer,
    options: Options,
) EncodeError!void {
    _ = plan; // this edit's indices are type indices, which never shift
    // First, so a broken import section is reported before anything else.
    const counts = try Counts.of(module, options);
    const old = try readOld(module, options);

    const count_new = std.math.cast(u32, self.entries.len) orelse return error.Overflow;
    const count_total = std.math.add(u32, old.count, count_new) catch return error.Overflow;
    try writer.writeLeb128(count_total); // canonical count, even if the old one was padded
    try writer.writeAll(old.entries); // old imports are copied verbatim, not re-encoded
    for (self.entries) |*entry| try writeEntry(writer, entry, &counts, options);
}

/// How many imports of each kind these entries add; `emit` computes this once for the plan.
pub fn planAddedImports(self: *const AddImports) index.AddedImports {
    var result: index.AddedImports = .{};
    for (self.entries) |*entry| result.add(std.meta.activeTag(entry.desc));
    return result;
}

fn writeEntry(
    writer: *Io.Writer,
    entry: *const Entry,
    counts: *const Counts,
    options: Options,
) EncodeError!void {
    try writeName(writer, entry.module);
    try writeName(writer, entry.field);

    const kind = std.meta.activeTag(entry.desc);
    try writer.writeByte(@backingInt(kind));
    switch (entry.desc) {
        .function => |type_ref| {
            try writer.writeLeb128(try checkedTypeIndex(type_ref, counts, options));
        },
        .table => |table| {
            try writer.writeByte(@backingInt(table.reftype));
            try writeLimits(writer, table.limits, options);
        },
        .memory => |memory| try writeLimits(writer, memory, options),
        .global => |global| try globals.writeType(global, writer),
        .tag => |type_ref| {
            try writer.writeByte(0); // the attribute byte: only 0 (exception) exists
            try writer.writeLeb128(try checkedTypeIndex(type_ref, counts, options));
        },
    }
}

fn writeName(writer: *Io.Writer, name: []const u8) EncodeError!void {
    try writer.writeLeb128(std.math.cast(u32, name.len) orelse return error.Overflow);
    try writer.writeAll(name);
}

/// `limits.write` can fail for caller data: reserved flag bits or values that do not fit. Those are
/// diagnosed here; `WriteFailed` is not, because it may leave bytes in the writer.
fn writeLimits(writer: *Io.Writer, value: spec.Limits, options: Options) EncodeError!void {
    limits.write(value, writer) catch |err| switch (err) {
        error.UnsupportedFeature, error.Overflow => return Diagnostics.fail(
            options.diag,
            err,
            .{ .section = .import },
        ),
        else => return err,
    };
}

const Old = struct { count: u32 = 0, entries: []const u8 = &.{} };

/// Reads the whole old section, so a broken one is rejected instead of copied.
fn readOld(module: *const Module, options: Options) EncodeError!Old {
    const payload = module.payloadCursor(.import) orelse return .{};
    var iterator = imports.Iterator.init(payload) catch |err| return Diagnostics.fail(
        options.diag,
        err,
        .{ .section = .import, .offset = payload.pos },
    );
    while (true) {
        const entry = iterator.next() catch |err| return Diagnostics.fail(options.diag, err, .{
            .section = .import,
            .offset = iterator.cursor.pos,
        });
        if (entry == null) break;
    }
    return .{ .count = iterator.count, .entries = iterator.entries.slice(module.bytes) };
}

/// The number a type index resolves to, or the out-of-range diagnostic. Only `.input` is checked;
/// `.appended`/`.added_import` ordinals are the plan's to hand out.
fn checkedTypeIndex(
    type_ref: index.Type,
    counts: *const Counts,
    options: Options,
) EncodeError!u32 {
    const layout = index.Layout.types(counts);
    switch (type_ref) {
        .input => |used| {
            if (used >= layout.input_total) {
                return Diagnostics.fail(options.diag, error.IndexOutOfRange, .{
                    .section = .import,
                    .detail = .{
                        .out_of_range = .{
                            .space = .type,
                            .value = used,
                            .limit = layout.input_total,
                        },
                    },
                });
            }
        },
        .appended, .added_import => {},
    }
    return type_ref.resolve(layout);
}
