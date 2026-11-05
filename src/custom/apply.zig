//! The emit-side half of custom-section editing: match input custom sections, measure replacement
//! and removal sizes, write appends and replacements, and produce custom-section diagnostics.
//! `emit.zig` keeps only the section walk and calls these functions, so the custom rules live
//! beside the custom edit types instead of inside the general emitter.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Diagnostics = @import("../Diagnostics.zig");
const EmitError = @import("../errors.zig").EmitError;
const Module = @import("../Module.zig");
const Options = @import("../Options.zig");
const Patch = @import("../Patch.zig");
const Run = @import("../Run.zig");
const custom_edit = @import("edit.zig");
const custom_payload = @import("../payload/custom.zig");
const section_mod = @import("../section.zig");
const SectionId = @import("../spec.zig").SectionId;

const InputEdit = union(enum) {
    replace: struct {
        entry: custom_payload.Entry,
        source: custom_edit.Source,
    },
    remove,
};

pub fn measureDelta(
    module: *const Module,
    patch: *const Patch,
    options: Options,
) EmitError!i64 {
    assert(patch.custom.len != 0);
    try checkEdits(module, patch, options);

    var delta: i64 = 0;
    if (hasInputEdit(patch)) {
        var iterator = module.iterator();
        while (iterator.next() catch unreachable) |section| {
            if (section.id != .custom) continue;
            const matched = (try findInputEdit(module, section, patch, options)) orelse continue;
            const old_len: i64 = @intCast(section.whole().len());
            switch (matched) {
                .replace => |replacement| {
                    const new_payload_len = try payloadLen(
                        replacement.entry.name,
                        &replacement.source,
                        replacement.entry.data,
                        .{
                            .section = .custom,
                            .offset = section.start,
                            .name = replacement.entry.name,
                        },
                        options,
                    );
                    const new_len = section_mod.headerLen(new_payload_len) + new_payload_len;
                    delta += @as(i64, @intCast(new_len)) - old_len;
                },
                .remove => delta -= old_len,
            }
        }
    }

    for (patch.custom) |*edit| switch (edit.*) {
        .replace, .remove => {},
        .append => |append| {
            const len = try payloadLen(append.name, &append.source, null, .{
                .section = .custom,
                .name = append.name,
            }, options);
            delta += @as(i64, @intCast(section_mod.headerLen(len) + len));
        },
    };
    return delta;
}

/// Writes every `.start` append after the module header.
pub fn writeStart(run: *Run, patch: *const Patch, options: Options) EmitError!void {
    try writeAppends(run, patch, .start, options);
}

/// Writes every `.end` append after all input bytes.
pub fn writeEnd(run: *Run, patch: *const Patch, options: Options) EmitError!void {
    try writeAppends(run, patch, .end, options);
}

/// Applies the replace or remove edit selecting `section`, if any. A replace writes a new section;
/// a remove writes nothing and skips the whole old section.
pub fn writeInputEdit(
    run: *Run,
    module: *const Module,
    section: Module.Section,
    patch: *const Patch,
    options: Options,
) EmitError!void {
    assert(section.id == .custom);
    assert(section.whole().end <= module.bytes.len);
    const matched = (try findInputEdit(module, section, patch, options)) orelse return;
    try run.flush(section.start);
    switch (matched) {
        .replace => |replacement| try writeCustomSection(
            run.writer,
            replacement.entry.name,
            &replacement.source,
            replacement.entry.data,
            .{
                .section = .custom,
                .offset = section.start,
                .name = replacement.entry.name,
            },
            options,
        ),
        .remove => {},
    }
    run.skip(section.whole().end);
    assert(run.start == section.whole().end);
}

fn customEntry(
    module: *const Module,
    section: Module.Section,
    options: Options,
) EmitError!custom_payload.Entry {
    assert(section.id == .custom);
    assert(section.payload.start <= section.payload.end);
    assert(section.payload.end <= module.bytes.len);
    return custom_payload.read(module.bytes, section.payload) catch |err|
        return Diagnostics.fail(options.diag, err, .{
            .section = .custom,
            .offset = section.start,
        });
}

fn payloadLen(
    name: []const u8,
    source: *const custom_edit.Source,
    original: ?[]const u8,
    where: Diagnostics.Where,
    options: Options,
) EmitError!u32 {
    return custom_edit.payloadLen(name, source, original) catch |err|
        return Diagnostics.fail(options.diag, err, where);
}

fn writeCustomSection(
    writer: *Io.Writer,
    name: []const u8,
    source: *const custom_edit.Source,
    original: ?[]const u8,
    where: Diagnostics.Where,
    options: Options,
) EmitError!void {
    assert(name.len <= std.math.maxInt(u32));
    const len = try payloadLen(name, source, original, where, options);
    try writer.writeByte(@backingInt(@as(SectionId, .custom)));
    try writer.writeLeb128(len);
    custom_edit.writePayload(name, source, original, writer) catch |err|
        return Diagnostics.fail(options.diag, err, where);
}

/// Whether any edit targets an input custom section. Appends do not need the input's names parsed.
fn hasInputEdit(patch: *const Patch) bool {
    for (patch.custom) |edit| switch (edit) {
        .append => {},
        .replace, .remove => return true,
    };
    return false;
}

fn occurrence(
    module: *const Module,
    target: Module.Section,
    name: []const u8,
    options: Options,
) EmitError!u32 {
    assert(target.id == .custom);
    var count: u32 = 0;
    var iterator = module.iterator();
    while (iterator.next() catch unreachable) |section| {
        if (section.start >= target.start) break;
        if (section.id != .custom) continue;
        const entry = try customEntry(module, section, options);
        if (std.mem.eql(u8, entry.name, name)) count += 1;
    }
    return count;
}

fn selectorExists(
    module: *const Module,
    selector: *const custom_edit.Selector,
    options: Options,
) EmitError!bool {
    var count: u32 = 0;
    var found = false;
    var iterator = module.iterator();
    while (iterator.next() catch unreachable) |section| {
        if (section.id != .custom) continue;
        const entry = try customEntry(module, section, options);
        if (!std.mem.eql(u8, entry.name, selector.name)) continue;
        if (count == selector.occurrence) found = true;
        count += 1;
    }
    return found;
}

/// Rejects duplicate input selectors and selectors naming no input section. A patch with only
/// appends never parses a custom-section name, so opaque custom payloads stay opaque.
fn checkEdits(module: *const Module, patch: *const Patch, options: Options) EmitError!void {
    for (patch.custom, 0..) |*edit, index| {
        const selector = (selectorOf(edit)) orelse continue;
        for (patch.custom[0..index]) |*previous| {
            const prior = (selectorOf(previous)) orelse continue;
            if (custom_edit.Selector.eql(&prior, &selector)) {
                return Diagnostics.fail(options.diag, error.DuplicateCustomSection, .{
                    .section = .custom,
                    .name = selector.name,
                    .detail = .{ .custom_section = .{ .occurrence = selector.occurrence } },
                });
            }
        }
        if (!try selectorExists(module, &selector, options)) {
            return Diagnostics.fail(options.diag, error.UnknownCustomSection, .{
                .section = .custom,
                .name = selector.name,
                .detail = .{ .custom_section = .{ .occurrence = selector.occurrence } },
            });
        }
    }
}

fn selectorOf(edit: *const custom_edit.Edit) ?custom_edit.Selector {
    return switch (edit.*) {
        .append => null,
        .replace => |replacement| replacement.selector,
        .remove => |selector| selector,
    };
}

fn hasInputEditName(patch: *const Patch, name: []const u8) bool {
    for (patch.custom) |*edit| switch (edit.*) {
        .append => {},
        .replace => |replacement| {
            if (std.mem.eql(u8, replacement.selector.name, name)) return true;
        },
        .remove => |selector| {
            if (std.mem.eql(u8, selector.name, name)) return true;
        },
    };
    return false;
}

fn findInputEdit(
    module: *const Module,
    section: Module.Section,
    patch: *const Patch,
    options: Options,
) EmitError!?InputEdit {
    assert(section.id == .custom);
    if (!hasInputEdit(patch)) return null;

    const entry = try customEntry(module, section, options);
    if (!hasInputEditName(patch, entry.name)) return null;
    const count = try occurrence(module, section, entry.name, options);
    for (patch.custom) |*edit| switch (edit.*) {
        .append => {},
        .replace => |replacement| {
            if (replacement.selector.occurrence != count) continue;
            if (!std.mem.eql(u8, replacement.selector.name, entry.name)) continue;
            return .{ .replace = .{ .entry = entry, .source = replacement.source } };
        },
        .remove => |selector| {
            if (selector.occurrence != count) continue;
            if (!std.mem.eql(u8, selector.name, entry.name)) continue;
            return .remove;
        },
    };
    return null;
}

fn writeAppends(
    run: *Run,
    patch: *const Patch,
    placement: custom_edit.Placement,
    options: Options,
) EmitError!void {
    for (patch.custom) |*edit| switch (edit.*) {
        .replace, .remove => {},
        .append => |append| {
            if (append.placement != placement) continue;
            try writeCustomSection(run.writer, append.name, &append.source, null, .{
                .section = .custom,
                .name = append.name,
            }, options);
        },
    };
}

const testing = std.testing;

test "apply: custom payload length includes the name vector" {
    const source: custom_edit.Source = .{ .bytes = &.{ 1, 2 } };
    try testing.expectEqual(@as(u32, 5), try custom_edit.payloadLen("ab", &source, null));
}
