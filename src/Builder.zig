//! Builds a patch from symbolic additions, so callers never write an index by hand.
//!
//! The builder is unmanaged and borrows the entries the patch references; it must outlive the patch
//! and not change while the patch is in use. An appended entity is `.appended = n`; an added import
//! is `.added_import = n` because imports precede the module's own entities.
const std = @import("std");
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

const AddExports = @import("edit/AddExports.zig");
const AddGlobals = @import("edit/AddGlobals.zig");
const AddImports = @import("edit/AddImports.zig");
const AddTypes = @import("edit/AddTypes.zig");
const Body = @import("payload/Body.zig");
const custom_edit = @import("custom/edit.zig");
const Diagnostics = @import("Diagnostics.zig");
const Edit = @import("edit.zig").Edit;
const Options = @import("Options.zig");
const Patch = @import("Patch.zig");
const SetBodies = @import("edit/SetBodies.zig");
const SetTables = @import("edit/SetTables.zig");
const errors = @import("errors.zig");
const index = @import("index.zig");
const spec = @import("spec.zig");
const tables = @import("payload/tables.zig");

/// What the adding calls can fail with.
pub const Error = Allocator.Error || errors.BuilderError;

/// The additions, in call order; each list becomes one section edit.
globals: std.ArrayList(AddGlobals.Global) = .empty,
exports: std.ArrayList(AddExports.Entry) = .empty,
/// Added signatures; `types[n]` is `.appended = n`.
types: std.ArrayList(AddTypes.Signature) = .empty,
/// Added imports, in call order; each precedes the module's own entities.
imports: std.ArrayList(AddImports.Entry) = .empty,
/// Added imports per kind; also the shift every edit applies.
added_imports: index.AddedImports = .{},
/// Added function type indices; `function_types[n]` is `.appended = n`.
function_types: std.ArrayList(index.Type) = .empty,
/// Bodies by appended ordinal; `bodies_set` marks filled slots.
added_bodies: std.ArrayList(Body) = .empty,
bodies_set: std.ArrayList(bool) = .empty,
/// Bodies replacing input functions.
existing_bodies: std.ArrayList(SetBodies.Replacement) = .empty,
/// Table-type replacements by input table.
table_replacements: std.ArrayList(SetTables.Replacement) = .empty,
/// Custom appends and replacements; these do not use `Patch.slots`.
custom_edits: std.ArrayList(custom_edit.Edit) = .empty,

const Builder = @This();

/// A plan that adds nothing: no allocation and no deinit required, though `deinit` stays legal.
pub fn init() Builder {
    return .{};
}

/// Frees the entry lists; the bytes they borrow belong to the caller.
pub fn deinit(self: *Builder, allocator: Allocator) void {
    self.globals.deinit(allocator);
    self.exports.deinit(allocator);
    self.types.deinit(allocator);
    self.imports.deinit(allocator);
    self.function_types.deinit(allocator);
    self.added_bodies.deinit(allocator);
    self.bodies_set.deinit(allocator);
    self.existing_bodies.deinit(allocator);
    self.table_replacements.deinit(allocator);
    self.custom_edits.deinit(allocator);
}

/// Adds a signature and returns `.appended = n`; the type section is written at `patch` time.
pub fn addType(
    self: *Builder,
    allocator: Allocator,
    signature: AddTypes.Signature,
) Error!index.Type {
    try self.types.append(allocator, signature);
    // A list of more than 2^32 signatures would take over 100 GiB, so the ordinal always fits.
    return .{ .appended = @intCast(self.types.items.len - 1) };
}

/// Adds `module.field` and returns the target naming it. Names are borrowed until `emit`; the
/// import shifts the indices of its space.
pub fn addImport(
    self: *Builder,
    allocator: Allocator,
    module: []const u8,
    field: []const u8,
    desc: AddImports.Desc,
) Error!index.Target {
    const kind = std.meta.activeTag(desc);
    const ordinal = self.added_imports.count(kind);
    try self.imports.append(allocator, .{ .module = module, .field = field, .desc = desc });
    self.added_imports.add(kind);
    return index.Target.addedImport(kind, ordinal);
}

/// Adds `global` and returns `.appended = n`, so an export can name it before any module has it.
pub fn addGlobal(
    self: *Builder,
    allocator: Allocator,
    global: AddGlobals.Global,
) Error!index.Global {
    try self.globals.append(allocator, global);
    // A list of more than 2^32 globals would take 80 GiB, so the ordinal always fits.
    return .{ .appended = @intCast(self.globals.items.len - 1) };
}

/// Adds a function of type `function_type` and returns its reference. Set the body separately so
/// the body can name the function (recursion, self-reference).
pub fn addFunction(
    self: *Builder,
    allocator: Allocator,
    function_type: index.Type,
) Error!index.Function {
    // The three lists stay the same length; a failure part-way through undoes what it appended.
    try self.added_bodies.append(allocator, undefined);
    errdefer self.added_bodies.items.len -= 1;
    try self.bodies_set.append(allocator, false);
    errdefer self.bodies_set.items.len -= 1;
    try self.function_types.append(allocator, function_type);
    return .{ .appended = @intCast(self.function_types.items.len - 1) };
}

/// Adds an export named `name`. The name is borrowed and must stay alive until `emit` returns.
pub fn addExport(
    self: *Builder,
    allocator: Allocator,
    name: []const u8,
    target: index.Target,
) Error!void {
    try self.exports.append(allocator, .{ .name = name, .target = target });
}

/// Sets `function`'s body. An `.appended` ordinal must come from `addFunction` (`UnknownFunction`);
/// a function takes one body (`DuplicateBody`), and an imported function has none
/// (`ImportedFunction`). The body and any rewriter context must stay alive until `emit`: a context
/// local to a loop iteration is overwritten before then even though `setBody` succeeds. Keep it in
/// an arena or outside the loop.
pub fn setBody(
    self: *Builder,
    allocator: Allocator,
    function: index.Function,
    body: Body,
) Error!void {
    switch (function) {
        .input => |input_index| {
            for (self.existing_bodies.items) |*entry| {
                if (entry.function == input_index) return error.DuplicateBody;
            }
            try self.existing_bodies.append(allocator, .{
                .function = input_index,
                .body = body,
            });
        },
        .appended => |ordinal| {
            if (ordinal >= self.function_types.items.len) return error.UnknownFunction;
            if (self.bodies_set.items[ordinal]) return error.DuplicateBody;
            self.added_bodies.items[ordinal] = body;
            self.bodies_set.items[ordinal] = true;
        },
        .added_import => return error.ImportedFunction,
    }
}

/// Replaces an input table's type. Imported tables and `.appended` indices are refused
/// (`ImportedTable`/`UnknownTable`), and a table takes one replacement (`DuplicateTable`).
pub fn setTable(
    self: *Builder,
    allocator: Allocator,
    table: index.Table,
    table_type: tables.Type,
) Error!void {
    switch (table) {
        .input => |input_index| {
            for (self.table_replacements.items) |*entry| {
                if (entry.table == input_index) return error.DuplicateTable;
            }
            try self.table_replacements.append(allocator, .{
                .table = input_index,
                .table_type = table_type,
            });
        },
        .appended => return error.UnknownTable,
        .added_import => return error.ImportedTable,
    }
}

/// Appends at `.start` (after the wasm header) or `.end` (after all input bytes). The name and
/// source are borrowed until `emit`; a streaming source's context needs a stable address.
pub fn addCustomSection(
    self: *Builder,
    allocator: Allocator,
    placement: custom_edit.Placement,
    name: []const u8,
    source: custom_edit.Source,
) Error!void {
    try self.custom_edits.append(allocator, .{ .append = .{
        .placement = placement,
        .name = name,
        .source = source,
    } });
}

/// Replaces the selected input section's data, keeping its name and position. The source's rewriter
/// receives the original data. The name and source are borrowed until `emit`; a missing selector is
/// `UnknownCustomSection` at emit, and a duplicate selector is `DuplicateCustomSection`.
pub fn setCustomSection(
    self: *Builder,
    allocator: Allocator,
    name: []const u8,
    occurrence: u32,
    source: custom_edit.Source,
) Error!void {
    const selector: custom_edit.Selector = .{ .name = name, .occurrence = occurrence };
    if (self.customTargetInUse(&selector)) return error.DuplicateCustomSection;
    try self.custom_edits.append(allocator, .{ .replace = .{
        .selector = selector,
        .source = source,
    } });
}

/// Deletes the selected input section, including its frame. Occurrences are input-relative, so
/// removing earlier sections does not renumber this selector. A missing selector is
/// `UnknownCustomSection` at emit; a duplicate selector is `DuplicateCustomSection`.
pub fn removeCustomSection(
    self: *Builder,
    allocator: Allocator,
    name: []const u8,
    occurrence: u32,
) Error!void {
    const selector: custom_edit.Selector = .{ .name = name, .occurrence = occurrence };
    if (self.customTargetInUse(&selector)) return error.DuplicateCustomSection;
    try self.custom_edits.append(allocator, .{ .remove = selector });
}

fn customTargetInUse(self: *const Builder, selector: *const custom_edit.Selector) bool {
    for (self.custom_edits.items) |*edit| switch (edit.*) {
        .append => {},
        .replace => |existing| {
            if (custom_edit.Selector.eql(&existing.selector, selector)) return true;
        },
        .remove => |existing| {
            if (custom_edit.Selector.eql(&existing, selector)) return true;
        },
    };
    return false;
}

/// A patch that adds everything added so far. `patchWith` with no diagnostics sink.
pub fn patch(self: *const Builder) Error!Patch {
    return self.patchWith(.{});
}

/// `patch` with a diagnostics sink. An added function without a body is `MissingBody`, with its
/// ordinal in the detail; an `.appended` type the plan never added is `UnknownType`. The patch
/// borrows the builder's entries until the next change or `deinit`.
pub fn patchWith(self: *const Builder, options: Options) Error!Patch {
    self.assertInvariants();
    for (self.bodies_set.items, 0..) |set, ordinal| {
        if (!set) {
            // More than 2^32 bodies cannot fit in memory, so the ordinal fits in the detail.
            return Diagnostics.fail(options.diag, error.MissingBody, .{
                .detail = .{ .missing_body = .{ .ordinal = @intCast(ordinal) } },
            });
        }
    }
    for (self.function_types.items) |function_type| {
        try self.checkAddedType(function_type, options);
    }
    for (self.imports.items) |*entry| {
        switch (entry.desc) {
            .function => |type_ref| try self.checkAddedType(type_ref, options),
            .tag => |type_ref| try self.checkAddedType(type_ref, options),
            .table, .memory, .global => {},
        }
    }

    var result = Patch.empty;
    if (self.types.items.len != 0) {
        setPayload(&result, .type, .{ .add_types = .{
            .signatures = self.types.items,
        } });
    }
    if (self.imports.items.len != 0) {
        setPayload(&result, .import, .{ .add_imports = .{
            .entries = self.imports.items,
        } });
    }
    if (self.function_types.items.len != 0) {
        setPayload(&result, .function, .{ .add_functions = .{
            .types = self.function_types.items,
        } });
    }
    if (self.table_replacements.items.len != 0) {
        setPayload(&result, .table, .{ .set_tables = .{
            .entries = self.table_replacements.items,
        } });
    }
    if (self.existing_bodies.items.len != 0 or self.added_bodies.items.len != 0) {
        setPayload(&result, .code, .{ .set_bodies = .{
            .existing = self.existing_bodies.items,
            .added = self.added_bodies.items,
        } });
    }
    if (self.globals.items.len != 0) {
        setPayload(&result, .global, .{ .add_globals = .{ .entries = self.globals.items } });
    }
    if (self.exports.items.len != 0) {
        setPayload(&result, .@"export", .{ .add_exports = .{ .entries = self.exports.items } });
    }
    result.custom = self.custom_edits.items;
    return result;
}

/// Rejects an `.appended` type ordinal the builder never handed out; `.input` is checked at emit.
fn checkAddedType(self: *const Builder, type_ref: index.Type, options: Options) Error!void {
    switch (type_ref) {
        .input, .added_import => {},
        .appended => |ordinal| {
            if (ordinal >= self.types.items.len) {
                return Diagnostics.fail(options.diag, error.UnknownType, .{
                    .detail = .{ .out_of_range = .{
                        .space = .type,
                        .value = ordinal,
                        .limit = @intCast(self.types.items.len),
                    } },
                });
            }
        },
    }
}

fn assertInvariants(self: *const Builder) void {
    assert(self.added_bodies.items.len == self.function_types.items.len);
    assert(self.bodies_set.items.len == self.function_types.items.len);

    var counted: index.AddedImports = .{};
    for (self.imports.items) |*entry| counted.add(std.meta.activeTag(entry.desc));
    assert(std.meta.eql(counted, self.added_imports));
}

/// `setPayload` cannot fail here: `patch` writes each slot once into a fresh patch.
fn setPayload(result: *Patch, id: spec.SectionId, edit: Edit) void {
    result.setPayload(id, edit) catch unreachable;
}
