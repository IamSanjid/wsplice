//! Declared entity counts per index space; whether section contents match is validation's job.
const std = @import("std");
const assert = std.debug.assert;

const spec = @import("../spec.zig");
const SectionId = spec.SectionId;
const ExternalKind = spec.ExternalKind;
const Module = @import("../Module.zig");
const Options = @import("../Options.zig");
const Diagnostics = @import("../Diagnostics.zig");
const errors = @import("../errors.zig");
const PayloadError = errors.PayloadError;
const fromCursor = errors.fromCursor;
const imports = @import("imports.zig");

/// Indexed by `@backingInt(kind)`.
imported: [kind_count]u32,
defined: [kind_count]u32,
/// The type section's declared count. Types are an index space but not an `ExternalKind`, and
/// cannot be imported, so there is no imported half.
types: u32,

const Counts = @This();

const kind_count = @typeInfo(ExternalKind).@"enum".field_names.len;

/// Reads the import section and each defined section's count LEB. No allocation.
pub fn of(module: *const Module, options: Options) PayloadError!Counts {
    var result: Counts = .{ .imported = @splat(0), .defined = @splat(0), .types = 0 };
    // First, so a broken import section is reported before anything else.
    try countImports(module, options, &result);
    for (0..kind_count) |kind_index| {
        const kind: ExternalKind = @fromBackingInt(@intCast(kind_index));
        result.defined[kind_index] = try definedCount(module, sectionOf(kind), options);
    }
    result.types = try definedCount(module, .type, options);
    return result;
}

/// Size of the index space: valid indices for `kind` are 0..total-1.
pub fn total(self: *const Counts, kind: ExternalKind) u32 {
    const kind_index = @backingInt(kind);
    const sum: u64 = self.imported[kind_index] + self.defined[kind_index];
    // For a Counts made by `of` this cannot fail: imports take at least 4 bytes and defined
    // entities at least 1, in disjoint sections of a module under 4 GiB.
    assert(sum <= std.math.maxInt(u32));
    return @intCast(sum);
}

/// How many of this space's entities are imported; a defined entity's section position is its
/// index minus this count.
pub fn importedCount(self: *const Counts, kind: ExternalKind) u32 {
    return self.imported[@backingInt(kind)];
}

/// Size of the type index space: valid type indices are 0..typeCount-1.
pub fn typeCount(self: *const Counts) u32 {
    return self.types;
}

fn sectionOf(kind: ExternalKind) SectionId {
    return switch (kind) { // no `else`: a new kind must get a section here
        .function => .function,
        .table => .table,
        .memory => .memory,
        .global => .global,
        .tag => .tag,
    };
}

fn countImports(module: *const Module, options: Options, result: *Counts) PayloadError!void {
    const payload = module.payloadCursor(.import) orelse return;
    var iterator = imports.Iterator.init(payload) catch |err|
        return Diagnostics.fail(options.diag, err, .{ .section = .import, .offset = payload.pos });

    var counted: u32 = 0;
    while (true) {
        const entry = iterator.next() catch |err| return Diagnostics.fail(options.diag, err, .{
            .section = .import,
            .offset = iterator.cursor.pos,
        });
        const imported = entry orelse break;
        result.imported[@backingInt(std.meta.activeTag(imported.desc))] += 1;
        counted += 1;
    }
    assert(counted == iterator.count);
}

fn definedCount(module: *const Module, id: SectionId, options: Options) PayloadError!u32 {
    var cursor = module.payloadCursor(id) orelse return 0;
    const start = cursor.pos;
    // readUleb puts the cursor back on error, so this does not have to.
    const count = cursor.readUleb(u32) catch |err| return Diagnostics.fail(
        options.diag,
        fromCursor(err),
        .{ .section = id, .offset = start },
    );
    // Every entity takes at least one byte, so a count beyond the remaining bytes cannot be true.
    if (count > cursor.remaining()) {
        return Diagnostics.fail(options.diag, error.Truncated, .{ .section = id, .offset = start });
    }
    return count;
}
