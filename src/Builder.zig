//! Assembles a patch from named additions, so a caller never writes an index by hand.
//!
//! A builder is unmanaged: `init` needs nothing, and every call that may allocate takes the
//! allocator, so a plan is not tied to one allocator policy. The entries it gathers are borrowed
//! by the patch it hands out: the builder must outlive that patch, and must not be changed while
//! the patch is in use.
//!
//! Nothing can be removed, which is what makes an appended entity cheap: the n-th entity of a kind
//! this plan appends is always `.appended = n`, whatever the input contains. An import is named
//! `.added_import = n` instead: imports go before the module's own entities.
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

/// The additions, in call order. Each list becomes one section's edit.
globals: std.ArrayList(AddGlobals.Global) = .empty,
exports: std.ArrayList(AddExports.Entry) = .empty,
/// The signature of each added type: `types[n]` declares `.appended = n`.
types: std.ArrayList(AddTypes.Signature) = .empty,
/// The imports, in call order. Each one is placed before the module's own entities.
imports: std.ArrayList(AddImports.Entry) = .empty,
/// How many imports of each kind were added, by kind. This is also the shift every edit applies.
added_imports: index.AddedImports = .{},
/// The type of each added function: `function_types[n]` declares `.appended = n`.
function_types: std.ArrayList(index.Type) = .empty,
/// The body of each added function, by appended ordinal; `bodies_set` says which slots are filled.
added_bodies: std.ArrayList(Body) = .empty,
bodies_set: std.ArrayList(bool) = .empty,
/// One body per input function the plan replaces.
existing_bodies: std.ArrayList(SetBodies.Replacement) = .empty,
/// One replacement per input table the plan sets.
table_replacements: std.ArrayList(SetTables.Replacement) = .empty,
/// Custom-section appends and replacements, in call order. These do not use `Patch.slots`.
custom_edits: std.ArrayList(custom_edit.Edit) = .empty,

const Builder = @This();

/// A plan that adds nothing: no allocation, nothing to free, though `deinit` stays legal.
pub fn init() Builder {
    return .{};
}

/// Frees the entry lists. The bytes the entries borrow are the caller's, not the builder's.
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

/// Adds `signature` and returns the reference that names it: the first type added is
/// `.appended = 0`. `addFunction` can name the result; the type section is written at `patch` time.
pub fn addType(
    self: *Builder,
    allocator: Allocator,
    signature: AddTypes.Signature,
) Error!index.Type {
    try self.types.append(allocator, signature);
    // A list of more than 2^32 signatures would take over 100 GiB, so the ordinal always fits.
    return .{ .appended = @intCast(self.types.items.len - 1) };
}

/// Adds the import `module.field` and returns the target that names it. The names are borrowed and
/// must stay alive until `emit` returns. An import is placed before the module's own entities, so
/// it shifts the indices of its space; `emit` applies that shift to every reference the library
/// emits.
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

/// Adds `global`, and returns the index that names it: the first global added is
/// `.appended = 0`, so an export can name a global before it exists in any module.
pub fn addGlobal(
    self: *Builder,
    allocator: Allocator,
    global: AddGlobals.Global,
) Error!index.Global {
    try self.globals.append(allocator, global);
    // A list of more than 2^32 globals would take 80 GiB, so the ordinal always fits.
    return .{ .appended = @intCast(self.globals.items.len - 1) };
}

/// Adds a function of type `function_type` and returns the reference that names it. Its body is
/// set by `setBody`, so the body can name this same reference (recursion, self-reference).
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

/// Sets `function`'s body. An `.appended` ordinal must come from `addFunction`
/// (`UnknownFunction`), and a function takes exactly one body (`DuplicateBody`). A function the
/// plan imports has no body (`ImportedFunction`). The body borrows its bytes, and any rewriter
/// context it carries, until `emit` returns: a context local to a loop iteration is overwritten
/// before `emit`, even though `setBody` succeeds. Keep it in an arena or storage outside the loop.
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

/// Replaces the type of input table `table`: its reference type and its limits. An imported table
/// has no table-section entry (`ImportedTable`), and no table can be added yet, so an `.appended`
/// index is `UnknownTable`. A table takes at most one replacement (`DuplicateTable`).
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

/// Appends a custom section at `placement`. `.start` puts it immediately after the wasm header,
/// before every section; `.end` puts it after all input bytes, including trailing custom sections.
/// The name and source are borrowed until `emit`; a streaming source's context must also have a
/// stable address.
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

/// Replaces the data of the input custom section matching `name` and `occurrence`, preserving its
/// name and position. The source's rewriter receives the original data. The name and source are
/// borrowed until `emit`; a streaming source's context must also have a stable address. A missing
/// selector is `UnknownCustomSection` at emit; a selector already used by a replace or remove is
/// `DuplicateCustomSection`.
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

/// Deletes the input custom section matching `name` and `occurrence`, including its section frame.
/// The name is borrowed until `emit`. Occurrences are input-relative, so removing earlier sections
/// does not renumber this selector. A missing selector is `UnknownCustomSection` at emit; a
/// selector already used by a replace or remove is `DuplicateCustomSection`.
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

/// `patch` with a diagnostics sink. An added function without a body is `MissingBody`, and the
/// detail names its appended ordinal: emitting the declaration without the body would shift every
/// later body onto the wrong function. A function or import that names an `.appended` type the plan
/// never added is `UnknownType`. The patch borrows the entries, so it is valid only until the next
/// call that changes the builder, or `deinit`.
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

/// Rejects an `.appended` type ordinal the plan never handed out. An `.input` one is checked
/// against the input at emit time, where the input's type count is known.
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

/// `Patch.setPayload` fails only on a second write to one slot, and `patch` writes each slot at
/// most once into a patch it has just made, so the error is unreachable rather than ignored.
fn setPayload(result: *Patch, id: spec.SectionId, edit: Edit) void {
    result.setPayload(id, edit) catch unreachable;
}
