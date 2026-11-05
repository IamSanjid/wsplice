const std = @import("std");
const Io = std.Io;

const Module = @import("Module.zig");

const Plan = @import("Plan.zig");
const EncodeError = @import("errors.zig").EncodeError;
const Raw = @import("edit/Raw.zig");
const AddExports = @import("edit/AddExports.zig");
const AddFunctions = @import("edit/AddFunctions.zig");
const AddGlobals = @import("edit/AddGlobals.zig");
const AddImports = @import("edit/AddImports.zig");
const AddTypes = @import("edit/AddTypes.zig");
const SetBodies = @import("edit/SetBodies.zig");
const SetTables = @import("edit/SetTables.zig");
const Options = @import("Options.zig");

const spec = @import("spec.zig");

/// Every buffer an `Edit` variant references must outlive the edit; the edit does not own it.
pub const Edit = union(enum) {
    raw: Raw, // replace the whole payload with these bytes
    add_exports: AddExports,
    add_functions: AddFunctions,
    add_globals: AddGlobals,
    add_imports: AddImports,
    add_types: AddTypes,
    set_bodies: SetBodies,
    set_tables: SetTables,

    const Self = @This();

    /// Writes the section payload. `plan` carries the plan-wide context `emit` computed.
    pub fn encode(
        self: *const Self,
        module: *const Module,
        plan: *const Plan,
        writer: *Io.Writer,
        options: Options,
    ) EncodeError!void {
        switch (self.*) {
            .raw => |raw| {
                return raw.encode(module, plan, writer, options);
            },
            .add_exports => |add_exports| {
                return add_exports.encode(module, plan, writer, options);
            },
            .add_functions => |add_functions| {
                return add_functions.encode(module, plan, writer, options);
            },
            .add_globals => |add_globals| {
                return add_globals.encode(module, plan, writer, options);
            },
            .add_imports => |add_imports| {
                return add_imports.encode(module, plan, writer, options);
            },
            .add_types => |add_types| {
                return add_types.encode(module, plan, writer, options);
            },
            .set_bodies => |set_bodies| {
                return set_bodies.encode(module, plan, writer, options);
            },
            .set_tables => |set_tables| {
                return set_tables.encode(module, plan, writer, options);
            },
        }
    }

    pub fn encodedLen(
        self: *const Self,
        module: *const Module,
        plan: *const Plan,
        options: Options,
    ) EncodeError!u32 {
        var counter = Io.Writer.Discarding.init(&.{});
        try self.encode(module, plan, &counter.writer, options);
        const len = counter.fullCount();
        return std.math.cast(u32, len) orelse error.Overflow;
    }
};

comptime {
    const type_info = @typeInfo(Edit).@"union";
    for (type_info.field_types, type_info.field_names) |FieldType, name| {
        if (!@hasDecl(FieldType, "encode"))
            @compileError("Edit." ++ name ++ " needs an encode method");
        const Want = fn (
            *const FieldType,
            *const Module,
            *const Plan,
            *Io.Writer,
            Options,
        ) EncodeError!void;
        if (@TypeOf(@field(FieldType, "encode")) != Want)
            @compileError("Edit." ++ name ++ ".encode has the wrong signature, expected: " ++
                @typeName(Want) ++ ", got: " ++ @typeName(@TypeOf(@field(FieldType, "encode"))));
    }
}

const entities_module = if (@import("builtin").is_test) spec.magic ++ spec.version ++ [_]u8{
    3, 2, 1, 0, // function: 1
    4, 4, 1, 0x70, 0, 1, // table: 1
    5, 3, 1, 0, 1, // memory: 1
    13, 3, 1, 0, 0, // tag: 1
    6, 6, 1, 0x7F, 0, 0x41, 0, 0x0B, // global: 1
} else @compileError("Shouldn't be accessed outside of tests");

const samples = if (@import("builtin").is_test) [_]Edit{
    .{ .raw = .{ .bytes = "" } },
    .{ .raw = .{ .bytes = "abc" } },
    .{ .raw = .{ .bytes = &(@as([128]u8, @splat(0x55))) } }, // 128: where a size LEB gets longer
    .{ .add_exports = .{ .entries = &.{.{
        .name = "a",
        .target = .{ .function = .{ .input = 0 } },
    }} } },
    .{ .add_exports = .{ .entries = &.{} } },
    .{ .add_functions = .{} },
    .{ .add_functions = .{ .types = &.{.{ .appended = 0 }} } },
    .{ .add_globals = .{ .entries = &.{
        .{
            .global_type = .{
                .valtype = .{ .number_or_vector = .i32 },
                .mutability = .mutable,
            },
            .init = .{ .i32 = 0 },
        },
        .{
            .global_type = .{
                .valtype = .{ .reference = .func },
                .mutability = .immutable,
            },
            .init = .{ .ref_null = .func },
        },
    } } },
    .{ .add_globals = .{ .entries = &.{} } },
    .{ .add_imports = .{} },
    .{ .add_imports = .{ .entries = &.{
        .{
            .module = "m",
            .field = "f",
            .desc = .{ .function = .{ .appended = 0 } },
        },
        .{
            .module = "env",
            .field = "mem",
            .desc = .{ .memory = .{
                .flags = .{ .has_max = true, .is_shared = false, .is_64bit = false },
                .min = 1,
                .max = 4,
            } },
        },
        .{
            .module = "env",
            .field = "g",
            .desc = .{ .global = .{
                .valtype = .{ .number_or_vector = .i32 },
                .mutability = .mutable,
            } },
        },
    } } },
    .{ .add_types = .{} },
    .{ .add_types = .{ .signatures = &.{.{
        .params = .{ .typed = &.{.{ .number_or_vector = .i32 }} },
        .results = .{ .typed = &.{.{ .number_or_vector = .i64 }} },
    }} } },
    .{ .set_bodies = .{} },
    .{ .set_bodies = .{ .added = &.{.{
        .locals = .{ .replace = &.{} },
        .mode = .{ .replace = &.{.{ .i32_const = 0 }} },
    }} } },
    .{ .set_tables = .{} },
    .{ .set_tables = .{ .entries = &.{.{
        .table = 0,
        .table_type = .{
            .reftype = .func,
            .limits = .{
                .flags = .{ .has_max = true, .is_shared = false, .is_64bit = false },
                .min = 1,
                .max = 4,
            },
        },
    }} } },
    // add one or more samples per new variant
} else @compileError("Shouldn't be accessed outside of tests");

test "contract: encoding is deterministic and encodedLen matches what is written" {
    const m = try Module.parse(&entities_module);
    const plan: Plan = .{}; // a standalone edit has no plan's imports or additions to resolve
    for (samples) |e| {
        var buf_a: [256]u8 = undefined;
        var buf_b: [256]u8 = undefined;
        var wa: Io.Writer = .fixed(&buf_a);
        var wb: Io.Writer = .fixed(&buf_b);
        try e.encode(&m, &plan, &wa, .{});
        try e.encode(&m, &plan, &wb, .{});
        try std.testing.expectEqualSlices(u8, wa.buffered(), wb.buffered());
        try std.testing.expectEqual(wa.buffered().len, try e.encodedLen(&m, &plan, .{}));
    }
}

test "contract: a too-small writer fails cleanly" {
    const m = try Module.parse(&entities_module);
    const plan: Plan = .{};
    for (samples) |e| {
        const need = try e.encodedLen(&m, &plan, .{});
        if (need == 0) continue; // nothing to overflow
        var buf: [256]u8 = undefined;
        var w: Io.Writer = .fixed(buf[0 .. need - 1]);
        try std.testing.expectError(error.WriteFailed, e.encode(&m, &plan, &w, .{}));
    }
}

test "contract: samples cover every variant" {
    inline for (@typeInfo(Edit).@"union".field_names) |name| {
        var found = false;
        for (samples) |e| {
            if (std.mem.eql(u8, @tagName(e), name)) found = true;
        }
        try std.testing.expect(found);
    }
}
