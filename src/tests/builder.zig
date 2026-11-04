//! Tests of the builder: ordinals, patch assembly, and an export of a global that the input does
//! not have yet. Everything is checked through the public emit API.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const spec = @import("../spec.zig");
const AddImports = @import("../edit/AddImports.zig");
const Body = @import("../payload/Body.zig");
const Builder = @import("../Builder.zig");
const Counts = @import("../payload/Counts.zig");
const Diagnostics = @import("../Diagnostics.zig");
const Module = @import("../Module.zig");
const AddGlobals = @import("../edit/AddGlobals.zig");
const exports = @import("../payload/exports.zig");
const globals = @import("../payload/globals.zig");
const index = @import("../index.zig");
const tables = @import("../payload/tables.zig");
const emit_mod = @import("../emit.zig");
const t = @import("support.zig");
const fixtures = @import("fixtures/fixtures.zig");

const emit = emit_mod.emit;
const header = t.header;
const sec = t.sec;

// ---------------------------------------------------------------- helpers

const i32_const_42: AddGlobals.Global = .{
    .global_type = .{
        .valtype = .{ .number_or_vector = .i32 },
        .mutability = .mutable,
    },
    .init = .{ .i32 = 42 },
};

const funcref_null: AddGlobals.Global = .{
    .global_type = .{
        .valtype = .{ .reference = .func },
        .mutability = .immutable,
    },
    .init = .{ .ref_null = .func },
};

const added_global: AddGlobals.Global = .{
    .global_type = .{
        .valtype = .{ .number_or_vector = .i32 },
        .mutability = .mutable,
    },
    .init = .{ .i32 = 9 },
};

fn findExport(m: *const Module, name: []const u8) !?exports.Entry {
    const payload = m.payloadCursor(.@"export") orelse return null;
    var iterator = try exports.Iterator.init(payload);
    while (try iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

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

/// Adds one import of `kind`, with a name derived from the kind.
fn addImportOfKind(b: *Builder, kind: spec.ExternalKind) !index.Target {
    const desc: AddImports.Desc = switch (kind) {
        .function => .{ .function = .{ .input = 0 } },
        .table => .{ .table = .{ .reftype = .func, .limits = limits(1, null) } },
        .memory => .{ .memory = limits(1, null) },
        .global => .{ .global = .{
            .valtype = .{ .number_or_vector = .i32 },
            .mutability = .immutable,
        } },
        .tag => .{ .tag = .{ .input = 0 } },
    };
    return b.addImport(std.testing.allocator, "env", @tagName(kind), desc);
}

// ------------------------------------------------------------------- empty

test "Builder: an empty builder patches nothing" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    const patch = try b.patch();
    try testing.expect(patch.isEmpty());
    try testing.expectEqual(@as(u8, 0), patch.count());
}

// ----------------------------------------------------------------- globals

test "Builder: addGlobal numbers the globals it adds and patches only the global section" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    const first = try b.addGlobal(testing.allocator, i32_const_42);
    const second = try b.addGlobal(testing.allocator, funcref_null);
    try testing.expectEqual(@as(u32, 0), first.appended);
    try testing.expectEqual(@as(u32, 1), second.appended);
    try testing.expectEqual(index.Space.global, index.Global.space);

    const patch = try b.patch();
    try testing.expectEqual(@as(u8, 1), patch.count());
    try testing.expectEqual(null, patch.get(.@"export")); // nothing was exported

    const edit = patch.get(.global).?;
    try testing.expectEqual(@as(usize, 2), edit.add_globals.entries.len);
    try testing.expectEqualDeep(i32_const_42, edit.add_globals.entries[0]);
    try testing.expectEqualDeep(funcref_null, edit.add_globals.entries[1]);

    // 42 mutable, then a null funcref: both entries are re-encoded, and the section is created.
    const expected = header ++ sec(6, &([_]u8{2} ++
        t.globalEntry(0x7F, .mutable, &.{ 0x41, 0x2A }) ++
        t.globalEntry(0x70, .immutable, &.{ 0xD0, 0x70 })));
    try t.expectEmit(&header, &patch, &expected);
}

// ----------------------------------------------------------------- exports

test "Builder: addExport keeps the name and the target, and patches only the export section" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    // `entities` gives every space 8 entities, so function 7 exists.
    const target = index.Target.input(.function, 7);
    try b.addExport(testing.allocator, "x", target);

    const patch = try b.patch();
    try testing.expectEqual(@as(u8, 1), patch.count());
    try testing.expectEqual(null, patch.get(.global)); // nothing was added

    const edit = patch.get(.@"export").?;
    try testing.expectEqual(@as(usize, 1), edit.add_exports.entries.len);
    try testing.expectEqualStrings("x", edit.add_exports.entries[0].name);
    try testing.expectEqualDeep(target, edit.add_exports.entries[0].target);

    const base = header ++ t.entities;
    const expected = base ++ sec(7, &([_]u8{1} ++ t.exportEntry("x", 0, 7)));
    try t.expectEmit(&base, &patch, &expected);
}

// -------------------------------------------------------------- one module

// All of the output, built from the input: the two sections stay where they are and gain one
// entry each. Anything wrong with either edit shows up as a byte difference.
test "Builder: a global added to imports.wasm is exported as global 3" {
    const input = fixtures.imports;
    const m = try Module.parse(input);
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    const added = try b.addGlobal(testing.allocator, added_global);
    try b.addExport(testing.allocator, "added", .{ .global = added });
    const patch = try b.patch();

    const global_entry = t.globalEntry(0x7F, .mutable, &.{ 0x41, 0x09 });
    const export_entry = [8]u8{ 5, 'a', 'd', 'd', 'e', 'd', 3, 3 };

    const global_section = m.section(.global).?;
    const export_section = m.section(.@"export").?;
    const old_globals = global_section.payload.slice(input);
    const old_exports = export_section.payload.slice(input);

    var expected: Io.Writer.Allocating = .init(testing.allocator);
    defer expected.deinit();
    const w = &expected.writer;
    try w.writeAll(input[0..global_section.start]);
    try w.writeByte(6);
    try w.writeLeb128(@as(u32, @intCast(1 + (old_globals.len - 1) + global_entry.len)));
    try w.writeByte(2); // two globals: the one the input has, and the added one
    try w.writeAll(old_globals[1..]); // the input's count is one byte
    try w.writeAll(&global_entry);
    try w.writeAll(input[global_section.whole().end..export_section.start]);
    try w.writeByte(7);
    try w.writeLeb128(@as(u32, @intCast(1 + (old_exports.len - 1) + export_entry.len)));
    try w.writeByte(4); // four exports: f, g, own, and the added one
    try w.writeAll(old_exports[1..]); // the input's count is one byte
    try w.writeAll(&export_entry);
    try w.writeAll(input[export_section.whole().end..]);

    try t.expectEmit(input, &patch, expected.written());

    // The input has 2 imported globals and 1 defined, so the added global is index 3.
    const m2 = try Module.parse(expected.written());
    const entry = (try findExport(&m2, "added")).?;
    try testing.expectEqual(spec.ExternalKind.global, entry.kind);
    try testing.expectEqual(@as(u32, 3), entry.index);
}

// ------------------------------------------------------------- every input

test "Builder: an added global's index is the input's global total, for every fixture" {
    for (fixtures.all) |fixture| {
        const m = try Module.parse(fixture.bytes);
        const counts = try Counts.of(&m, .{});
        const total = counts.total(.global);

        var b = Builder.init();
        defer b.deinit(testing.allocator);
        const added = try b.addGlobal(testing.allocator, added_global);
        try testing.expectEqual(@as(u32, 0), added.appended);
        try b.addExport(testing.allocator, "wsplice_added", .{ .global = added });
        const patch = try b.patch();

        var out: Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try emit(&m, &patch, &out.writer, .{});
        try testing.expectEqual(@as(u32, @intCast(out.written().len)), try emit_mod.outputLen(&m, &patch, .{}));
        try t.expectTiles(out.written());

        const m2 = try Module.parse(out.written());
        const entry = (try findExport(&m2, "wsplice_added")).?;
        try testing.expectEqual(spec.ExternalKind.global, entry.kind);
        try testing.expectEqual(total, entry.index);

        // The added global is the last one, and reads back as the one that was added.
        const old_count = if (m.payloadCursor(.global)) |payload|
            (try globals.Iterator.init(payload)).count
        else
            0;
        var iterator = try globals.Iterator.init(m2.payloadCursor(.global).?);
        try testing.expectEqual(old_count + 1, iterator.count);
        var last: ?globals.Entry = null;
        while (try iterator.next()) |global| last = global;
        const global = last.?;
        try testing.expectEqualDeep(
            spec.ValueType{ .number_or_vector = .i32 },
            global.global_type.valtype,
        );
        try testing.expectEqual(spec.Mutability.mutable, global.global_type.mutability);
        try testing.expectEqualSlices(u8, &.{ 0x41, 0x09 }, global.instructions);
    }
}

// ------------------------------------------------------------------- twice

test "Builder: asking for the patch twice gives two equal patches" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);
    _ = try b.addGlobal(testing.allocator, i32_const_42);
    try b.addExport(testing.allocator, "twice", .{ .global = .{ .appended = 0 } });

    const first = try b.patch();
    const second = try b.patch();
    try testing.expectEqual(first.count(), second.count());

    const base = header;
    const m = try Module.parse(&base);
    var out_a: Io.Writer.Allocating = .init(testing.allocator);
    defer out_a.deinit();
    var out_b: Io.Writer.Allocating = .init(testing.allocator);
    defer out_b.deinit();
    try emit(&m, &first, &out_a.writer, .{});
    try emit(&m, &second, &out_b.writer, .{});
    try testing.expectEqualSlices(u8, out_a.written(), out_b.written());
}

// --------------------------------------------------------------- functions

const empty_body: Body = .{ .locals = .{ .replace = &.{} }, .mode = .{ .replace = &.{} } };

test "Builder: addFunction numbers functions and patches the function and code sections" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    const first = try b.addFunction(testing.allocator, .{ .input = 0 });
    const second = try b.addFunction(testing.allocator, .{ .input = 0 });
    try testing.expectEqual(@as(u32, 0), first.appended);
    try testing.expectEqual(@as(u32, 1), second.appended);

    const second_body: Body = .{
        .locals = .{ .replace = &.{} },
        .mode = .{ .replace = &.{.{ .i32_const = 2 }} },
    };
    try b.setBody(testing.allocator, first, empty_body);
    try b.setBody(testing.allocator, second, second_body);

    const patch = try b.patch();
    try testing.expectEqual(@as(u8, 2), patch.count());

    const function_edit = patch.get(.function).?;
    try testing.expectEqual(@as(usize, 2), function_edit.add_functions.types.len);
    try testing.expectEqual(index.Type{ .input = 0 }, function_edit.add_functions.types[0]);
    try testing.expectEqual(index.Type{ .input = 0 }, function_edit.add_functions.types[1]);

    const body_edit = patch.get(.code).?;
    try testing.expectEqual(@as(usize, 2), body_edit.set_bodies.added.len);
    try testing.expectEqualDeep(empty_body, body_edit.set_bodies.added[0]);
    try testing.expectEqualDeep(second_body, body_edit.set_bodies.added[1]);
}

test "Builder: addType numbers types and patches the type section" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    const first = try b.addType(testing.allocator, .{});
    const second = try b.addType(testing.allocator, .{
        .params = .{ .typed = &.{.{ .number_or_vector = .i32 }} },
        .results = .{ .typed = &.{.{ .number_or_vector = .i64 }} },
    });
    try testing.expectEqual(@as(u32, 0), first.appended);
    try testing.expectEqual(@as(u32, 1), second.appended);

    const patch = try b.patch();
    try testing.expectEqual(@as(u8, 1), patch.count());

    const edit = patch.get(.type).?;
    try testing.expectEqual(@as(usize, 2), edit.add_types.signatures.len);
    try testing.expectEqual(@as(u32, 0), try edit.add_types.signatures[0].params.count());
    try testing.expectEqual(@as(u32, 1), try edit.add_types.signatures[1].params.count());
    try testing.expectEqualDeep(
        spec.ValueType{ .number_or_vector = .i32 },
        edit.add_types.signatures[1].params.typed[0],
    );
    try testing.expectEqualDeep(
        spec.ValueType{ .number_or_vector = .i64 },
        edit.add_types.signatures[1].results.typed[0],
    );
}

test "Builder: a function can name an added type, and it resolves after the input's types" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    const wrapper_type = try b.addType(testing.allocator, .{});
    const wrapper = try b.addFunction(testing.allocator, wrapper_type);
    try b.setBody(testing.allocator, wrapper, empty_body);
    const patch = try b.patch();

    const expected = header ++
        sec(1, &.{ 1, 0x60, 0, 0 }) ++ // the added type: () -> ()
        sec(3, &.{ 1, 0 }) ++ // the added function uses type 0
        sec(10, &.{ 1, 2, 0, 0x0B }); // its empty body
    try t.expectEmit(&header, &patch, &expected);
}

test "Builder: patchWith rejects a function whose added type was never added" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    const wrapper = try b.addFunction(testing.allocator, .{ .appended = 0 });
    try b.setBody(testing.allocator, wrapper, empty_body);

    var d: Diagnostics = .{};
    try testing.expectError(error.UnknownType, b.patchWith(.{ .diag = &d }));
    try testing.expectEqual(@as(?anyerror, error.UnknownType), d.err);
    try testing.expectEqual(@as(?spec.SectionId, null), d.section); // a plan error
    try testing.expectEqualDeep(
        Diagnostics.Detail{ .out_of_range = .{ .space = .type, .value = 0, .limit = 0 } },
        d.detail,
    );
}

test "Builder: an added function's declaration and body are emitted and read back" {
    const input = fixtures.imports;
    const m = try Module.parse(input);
    const query = try m.query(.{});
    const source = (try query.functionBody(2)).?; // g

    var b = Builder.init();
    defer b.deinit(testing.allocator);
    const added = try b.addFunction(testing.allocator, .{ .input = 0 });
    try b.setBody(testing.allocator, added, source.body());
    const patch = try b.patch();

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try emit(&m, &patch, &out.writer, .{});
    try testing.expectEqual(
        @as(u32, @intCast(out.written().len)),
        try emit_mod.outputLen(&m, &patch, .{}),
    );
    try t.expectTiles(out.written());

    const m2 = try Module.parse(out.written());
    const query2 = try m2.query(.{});
    const counts = try Counts.of(&m2, .{});
    const new_index = counts.total(.function) - 1; // the added function comes last
    try testing.expectEqual(
        index.Type{ .input = 0 },
        (try query2.functionType(new_index)).?,
    );
    const copied = (try query2.functionBody(new_index)).?;
    try testing.expectEqualSlices(u8, source.locals, copied.locals);
    try testing.expectEqualSlices(u8, source.bodyRaw(), copied.bodyRaw());
}

test "Builder: setBody on an input function replaces its body and adds no declaration" {
    const input = fixtures.imports;
    const m = try Module.parse(input);
    const query = try m.query(.{});
    const source = (try query.functionBody(2)).?;

    var b = Builder.init();
    defer b.deinit(testing.allocator);
    try b.setBody(testing.allocator, .{ .input = 1 }, source.body());
    const patch = try b.patch();
    try testing.expectEqual(@as(u8, 1), patch.count());
    try testing.expectEqual(null, patch.get(.function)); // no function was added

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try emit(&m, &patch, &out.writer, .{});
    try t.expectTiles(out.written());

    const m2 = try Module.parse(out.written());
    const query2 = try m2.query(.{});
    const replaced = (try query2.functionBody(1)).?;
    try testing.expectEqualSlices(u8, source.locals, replaced.locals);
    try testing.expectEqualSlices(u8, source.bodyRaw(), replaced.bodyRaw());
}

test "Builder: setBody rejects an unknown added function and a second body" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    try testing.expectError(
        error.UnknownFunction,
        b.setBody(testing.allocator, .{ .appended = 0 }, empty_body),
    );

    const added = try b.addFunction(testing.allocator, .{ .appended = 0 });
    try b.setBody(testing.allocator, added, empty_body);
    try testing.expectError(
        error.DuplicateBody,
        b.setBody(testing.allocator, added, empty_body),
    );
}

test "Builder: setBody rejects a second body for an input function" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    try b.setBody(testing.allocator, .{ .input = 0 }, empty_body);
    try testing.expectError(
        error.DuplicateBody,
        b.setBody(testing.allocator, .{ .input = 0 }, empty_body),
    );
}

test "Builder: patch refuses an added function without a body" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);
    _ = try b.addFunction(testing.allocator, .{ .input = 0 });
    try testing.expectError(error.MissingBody, b.patch());
}

test "Builder: patchWith names the added function that has no body" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    const first = try b.addFunction(testing.allocator, .{ .input = 0 });
    _ = try b.addFunction(testing.allocator, .{ .input = 0 }); // ordinal 1: no body
    const third = try b.addFunction(testing.allocator, .{ .input = 0 });
    try b.setBody(testing.allocator, first, empty_body);
    try b.setBody(testing.allocator, third, empty_body);

    var d: Diagnostics = .{};
    try testing.expectError(error.MissingBody, b.patchWith(.{ .diag = &d }));
    try testing.expectEqual(@as(?anyerror, error.MissingBody), d.err);
    try testing.expectEqual(@as(?spec.SectionId, null), d.section); // a plan error, not input
    try testing.expectEqual(@as(?u32, null), d.offset);
    try testing.expectEqualDeep(
        Diagnostics.Detail{ .missing_body = .{ .ordinal = 1 } },
        d.detail,
    );
}

// ------------------------------------------------------------------ imports

const typed_base = header ++ sec(1, &.{ 1, 0x60, 0, 0 });
/// One function import of type 0: module "e", field "f".
const function_import_payload = [_]u8{ 1, 1, 'e', 1, 'f', 0x00, 0x00 };
const defined_function_base = header ++
    sec(1, &.{ 1, 0x60, 0, 0 }) ++
    sec(3, &.{ 1, 0 }) ++
    sec(10, &.{ 1, 2, 0, 0x0B });
const import_and_defined_base = header ++
    sec(1, &.{ 1, 0x60, 0, 0 }) ++
    sec(2, &function_import_payload) ++
    sec(3, &.{ 1, 0 }) ++
    sec(10, &.{ 1, 2, 0, 0x0B });

test "Builder: addImport stores the entry and returns the import's target" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    const target = try b.addImport(testing.allocator, "env", "mem", .{
        .memory = limits(1, 4),
    });
    try testing.expectEqualDeep(index.Target.addedImport(.memory, 0), target);

    const patch = try b.patch();
    try testing.expectEqual(@as(u8, 1), patch.count());
    try testing.expectEqual(null, patch.get(.type)); // nothing else was added

    const edit = patch.get(.import).?;
    try testing.expectEqual(@as(usize, 1), edit.add_imports.entries.len);
    try testing.expectEqualStrings("env", edit.add_imports.entries[0].module);
    try testing.expectEqualStrings("mem", edit.add_imports.entries[0].field);
    try testing.expectEqualDeep(
        AddImports.Desc{ .memory = limits(1, 4) },
        edit.add_imports.entries[0].desc,
    );

    const payload = [_]u8{ 1, 3, 'e', 'n', 'v', 3, 'm', 'e', 'm', 0x02, 0x01, 1, 4 };
    const expected = header ++ sec(2, &payload);
    try t.expectEmit(&header, &patch, &expected);
}

test "Builder: addImport numbers each kind and keeps the call order" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    const first = try b.addImport(testing.allocator, "m", "a", .{ .memory = limits(1, null) });
    const second = try b.addImport(testing.allocator, "m", "b", .{ .global = .{
        .valtype = .{ .number_or_vector = .i32 },
        .mutability = .immutable,
    } });
    const third = try b.addImport(testing.allocator, "m", "c", .{ .memory = limits(2, null) });
    try testing.expectEqualDeep(index.Target.addedImport(.memory, 0), first);
    try testing.expectEqualDeep(index.Target.addedImport(.global, 0), second);
    try testing.expectEqualDeep(index.Target.addedImport(.memory, 1), third);

    const patch = try b.patch();
    const entries = patch.get(.import).?.add_imports.entries;
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("a", entries[0].field);
    try testing.expectEqualStrings("b", entries[1].field);
    try testing.expectEqualStrings("c", entries[2].field);

    const payload = [_]u8{
        3,
        1, 'm', 1, 'a', 0x02, 0x00, 0x01, // memory, min 1
        1, 'm', 1, 'b', 0x03, 0x7F, 0x00, // global, i32 immutable
        1, 'm', 1, 'c', 0x02, 0x00, 0x02, // memory, min 2
    };
    const expected = header ++ sec(2, &payload);
    try t.expectEmit(&header, &patch, &expected);
}

test "Builder: an import can name a type the plan adds" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    const added_type = try b.addType(testing.allocator, .{});
    const target = try b.addImport(testing.allocator, "m", "f", .{ .function = added_type });
    try testing.expectEqualDeep(index.Target.addedImport(.function, 0), target);

    const patch = try b.patch();
    try testing.expectEqual(@as(u8, 2), patch.count());

    const expected = header ++
        sec(1, &.{ 1, 0x60, 0, 0 }) ++
        sec(2, &.{ 1, 1, 'm', 1, 'f', 0x00, 0x00 });
    try t.expectEmit(&header, &patch, &expected);
}

test "Builder: patchWith rejects an import whose added type was never added" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    _ = try b.addImport(testing.allocator, "m", "f", .{ .tag = .{ .appended = 0 } });

    var d: Diagnostics = .{};
    try testing.expectError(error.UnknownType, b.patchWith(.{ .diag = &d }));
    try testing.expectEqual(@as(?anyerror, error.UnknownType), d.err);
    try testing.expectEqual(@as(?spec.SectionId, null), d.section);
    try testing.expectEqualDeep(
        Diagnostics.Detail{ .out_of_range = .{ .space = .type, .value = 0, .limit = 0 } },
        d.detail,
    );
}

test "Builder: addImport returns a target of the import's kind" {
    inline for (@typeInfo(spec.ExternalKind).@"enum".field_values) |value| {
        const kind: spec.ExternalKind = @fromBackingInt(value);
        var b = Builder.init();
        defer b.deinit(testing.allocator);

        const target = try addImportOfKind(&b, kind);
        try testing.expectEqual(kind, target.kind());
        try testing.expectEqualDeep(index.Target.addedImport(kind, 0), target);
    }
}

test "Builder: exports of added imports resolve after the input's imports" {
    const m = try Module.parse(&import_and_defined_base); // one input function import
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    const function_import = try b.addImport(testing.allocator, "env", "log", .{
        .function = .{ .input = 0 },
    });
    const memory_import = try b.addImport(testing.allocator, "env", "mem", .{
        .memory = limits(1, null),
    });
    try b.addExport(testing.allocator, "fn", function_import);
    try b.addExport(testing.allocator, "mem", memory_import);
    const patch = try b.patch();

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try emit(&m, &patch, &out.writer, .{});
    try testing.expectEqual(
        @as(u32, @intCast(out.written().len)),
        try emit_mod.outputLen(&m, &patch, .{}),
    );
    try t.expectTiles(out.written());

    const m2 = try Module.parse(out.written());
    const fn_export = (try findExport(&m2, "fn")).?;
    try testing.expectEqual(spec.ExternalKind.function, fn_export.kind);
    try testing.expectEqual(@as(u32, 1), fn_export.index); // after the input's 1 function import

    const mem_export = (try findExport(&m2, "mem")).?;
    try testing.expectEqual(spec.ExternalKind.memory, mem_export.kind);
    try testing.expectEqual(@as(u32, 0), mem_export.index); // the input has no memory imports
}

test "Builder: existing export targets shift past added imports" {
    const m = try Module.parse(&import_and_defined_base); // 1 function import, 1 defined
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    _ = try b.addImport(testing.allocator, "env", "log", .{ .function = .{ .input = 0 } });
    try b.addExport(testing.allocator, "import", index.Target.input(.function, 0));
    try b.addExport(testing.allocator, "defined", index.Target.input(.function, 1));
    const patch = try b.patch();

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try emit(&m, &patch, &out.writer, .{});

    const m2 = try Module.parse(out.written());
    const import_export = (try findExport(&m2, "import")).?;
    try testing.expectEqual(@as(u32, 0), import_export.index); // an input import keeps its place
    const defined_export = (try findExport(&m2, "defined")).?;
    try testing.expectEqual(@as(u32, 2), defined_export.index); // 1 + the added import
}

test "Builder: an added function's export shifts past added imports" {
    const m = try Module.parse(&typed_base);
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    _ = try b.addImport(testing.allocator, "env", "log", .{ .function = .{ .input = 0 } });
    const added = try b.addFunction(testing.allocator, .{ .input = 0 });
    try b.setBody(testing.allocator, added, empty_body);
    try b.addExport(testing.allocator, "wrap", .{ .function = added });
    const patch = try b.patch();

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try emit(&m, &patch, &out.writer, .{});

    const m2 = try Module.parse(out.written());
    const fn_export = (try findExport(&m2, "wrap")).?;
    try testing.expectEqual(spec.ExternalKind.function, fn_export.kind);
    try testing.expectEqual(@as(u32, 1), fn_export.index); // 0 input functions + 1 import + 0
}

test "Builder: a type the plan adds is not shifted by imports" {
    const m = try Module.parse(&typed_base); // one input type
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    _ = try b.addImport(testing.allocator, "env", "log", .{ .function = .{ .input = 0 } });
    const added_type = try b.addType(testing.allocator, .{});
    const added = try b.addFunction(testing.allocator, added_type);
    try b.setBody(testing.allocator, added, empty_body);
    const patch = try b.patch();

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try emit(&m, &patch, &out.writer, .{});

    const m2 = try Module.parse(out.written());
    const query = try m2.query(.{});
    const added_type_index = (try query.functionType(1)).?; // after the added import
    try testing.expectEqual(index.Type{ .input = 1 }, added_type_index); // input types + 0
}

test "Builder: an added global's export shifts past added global imports" {
    const m = try Module.parse(&typed_base);
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    _ = try b.addImport(testing.allocator, "env", "g", .{ .global = .{
        .valtype = .{ .number_or_vector = .i32 },
        .mutability = .immutable,
    } });
    const added = try b.addGlobal(testing.allocator, added_global);
    try b.addExport(testing.allocator, "g", .{ .global = added });
    const patch = try b.patch();

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try emit(&m, &patch, &out.writer, .{});

    const m2 = try Module.parse(out.written());
    const global_export = (try findExport(&m2, "g")).?;
    try testing.expectEqual(spec.ExternalKind.global, global_export.kind);
    try testing.expectEqual(@as(u32, 1), global_export.index); // the added import, then the global
}

test "Builder: a body's input, appended and added-import indices all remap" {
    const m = try Module.parse(&import_and_defined_base); // 1 input import, 1 defined function
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    const added_import = try b.addImport(testing.allocator, "env", "log", .{
        .function = .{ .input = 0 },
    });
    const added_function = try b.addFunction(testing.allocator, .{ .input = 0 });
    try b.setBody(testing.allocator, added_function, empty_body);

    const instructions = [_]Body.Instr{
        .{ .call = .{ .input = 0 } }, // input import: 0
        .{ .call = .{ .input = 1 } }, // input defined: 1 + 1 = 2
        .{ .call = added_import.function }, // added import: 1 + 0 = 1
        .{ .call = added_function }, // added function: 2 + 1 + 0 = 3
    };
    try b.setBody(testing.allocator, .{ .input = 1 }, .{
        .locals = .{ .replace = &.{} },
        .mode = .{ .replace = &instructions },
    });
    const patch = try b.patch();

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try emit(&m, &patch, &out.writer, .{});

    const m2 = try Module.parse(out.written());
    const query = try m2.query(.{});
    // The output has 2 function imports, so function 2 is the input defined one, now replaced.
    const body = (try query.functionBody(2)).?;
    try testing.expectEqualSlices(u8, &.{
        0x10, 0x00, // call 0: the input's import
        0x10, 0x02, // call 2: the input's defined function
        0x10, 0x01, // call 1: the import the plan adds
        0x10, 0x03, // call 3: the function the plan adds
    }, body.bodyRaw());
}

test "Builder: setBody rejects a function the plan imports" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    const target = try b.addImport(testing.allocator, "env", "log", .{
        .function = .{ .input = 0 },
    });
    try testing.expectError(
        error.ImportedFunction,
        b.setBody(testing.allocator, target.function, empty_body),
    );
}

test "Builder: a raw body is not remapped and is no longer refused" {
    const m = try Module.parse(&defined_function_base);
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    _ = try b.addImport(testing.allocator, "env", "mem", .{ .memory = limits(1, null) });
    try b.setBody(testing.allocator, .{ .input = 0 }, .{
        .locals = .{ .replace = &.{} },
        .mode = .{ .raw = &.{0x01} }, // nop: bytes are the caller's, never remapped
    });
    const patch = try b.patch();

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try emit(&m, &patch, &out.writer, .{});

    const m2 = try Module.parse(out.written());
    const query = try m2.query(.{});
    const body = (try query.functionBody(0)).?;
    try testing.expectEqualSlices(u8, &.{0x01}, body.bodyRaw());
}

test "Builder: an import-only plan whose input names no shifted space emits" {
    const base = header ++
        sec(1, &.{ 1, 0x60, 0, 0 }) ++
        sec(3, &.{ 1, 0 }) ++
        sec(10, &.{ 1, 2, 0, 0x0B });

    var b = Builder.init();
    defer b.deinit(testing.allocator);
    _ = try b.addImport(testing.allocator, "env", "mem", .{ .memory = limits(1, null) });
    const patch = try b.patch();

    const import_payload = [_]u8{ 1, 3, 'e', 'n', 'v', 3, 'm', 'e', 'm', 0x02, 0x00, 0x01 };
    const expected = header ++
        sec(1, &.{ 1, 0x60, 0, 0 }) ++
        sec(2, &import_payload) ++
        sec(3, &.{ 1, 0 }) ++
        sec(10, &.{ 1, 2, 0, 0x0B });
    try t.expectEmit(&base, &patch, &expected);
}

test "Builder: an import of one kind does not shift another kind's references" {
    const base = header ++ sec(1, &.{ 1, 0x60, 0, 0 });

    var b = Builder.init();
    defer b.deinit(testing.allocator);
    _ = try b.addImport(testing.allocator, "env", "mem", .{ .memory = limits(1, null) });
    const added = try b.addFunction(testing.allocator, .{ .input = 0 });
    try b.setBody(testing.allocator, added, empty_body);
    try b.addExport(testing.allocator, "f", .{ .function = added });
    const patch = try b.patch();

    const import_payload = [_]u8{ 1, 3, 'e', 'n', 'v', 3, 'm', 'e', 'm', 0x02, 0x00, 0x01 };
    const expected = header ++
        sec(1, &.{ 1, 0x60, 0, 0 }) ++
        sec(2, &import_payload) ++
        sec(3, &.{ 1, 0 }) ++
        sec(7, &.{ 1, 1, 'f', 0x00, 0x00 }) ++
        sec(10, &.{ 1, 2, 0, 0x0B });
    try t.expectEmit(&base, &patch, &expected);
}

// -------------------------------------------------------------------- tables

const one_table = header ++ sec(4, &.{ 1, 0x70, 0x00, 1 });

test "Builder: setTable replaces an input table's type and patches the table section" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    try b.setTable(testing.allocator, .{ .input = 0 }, tableType(.func, 1, 4));
    const patch = try b.patch();
    try testing.expectEqual(@as(u8, 1), patch.count());

    const entries = patch.get(.table).?.set_tables.entries;
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(u32, 0), entries[0].table);
    try testing.expectEqualDeep(tableType(.func, 1, 4), entries[0].table_type);

    const expected = header ++ sec(4, &.{ 1, 0x70, 0x01, 1, 4 });
    try t.expectEmit(&one_table, &patch, &expected);
}

test "Builder: setTable rejects an added table, an imported table and a duplicate" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    try testing.expectError(
        error.UnknownTable,
        b.setTable(testing.allocator, .{ .appended = 0 }, tableType(.func, 1, null)),
    );
    try testing.expectError(
        error.ImportedTable,
        b.setTable(testing.allocator, .{ .added_import = 0 }, tableType(.func, 1, null)),
    );

    try b.setTable(testing.allocator, .{ .input = 0 }, tableType(.func, 1, null));
    try testing.expectError(
        error.DuplicateTable,
        b.setTable(testing.allocator, .{ .input = 0 }, tableType(.func, 2, null)),
    );
}

test "Builder: setTable addresses an input defined table while a table import is added" {
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    _ = try b.addImport(testing.allocator, "e", "t", .{ .table = .{
        .reftype = .func,
        .limits = limits(1, null),
    } });
    try b.setTable(testing.allocator, .{ .input = 0 }, tableType(.func, 2, 4));
    const patch = try b.patch();

    const import_payload = [_]u8{ 1, 1, 'e', 1, 't', 0x01, 0x70, 0x00, 1 };
    const expected = header ++
        sec(2, &import_payload) ++
        sec(4, &.{ 1, 0x70, 0x01, 2, 4 });
    try t.expectEmit(&one_table, &patch, &expected);
}

// --------------------------------------------------------------- local bounds

const param_base = header ++
    sec(1, &.{ 1, 0x60, 1, 0x7F, 0 }) ++ // (i32) -> ()
    sec(3, &.{ 1, 0 }) ++
    sec(10, &.{ 1, 2, 0, 0x0B });
const i32_type = spec.ValueType{ .number_or_vector = .i32 };

test "Builder: an existing body is checked against the input function's type" {
    const m = try Module.parse(&param_base);

    var invalid_b = Builder.init();
    defer invalid_b.deinit(testing.allocator);
    const invalid = [_]Body.Instr{.{ .local_get = 1 }}; // only parameter 0 exists
    try invalid_b.setBody(testing.allocator, .{ .input = 0 }, .{
        .locals = .{ .replace = &.{} },
        .mode = .{ .replace = &invalid },
    });
    const invalid_patch = try invalid_b.patch();

    var d: Diagnostics = .{};
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(
        error.IndexOutOfRange,
        emit(&m, &invalid_patch, &w, .{ .diag = &d }),
    );
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
    try testing.expectEqual(@as(?anyerror, error.IndexOutOfRange), d.err);
    try testing.expectEqual(@as(?spec.SectionId, .code), d.section);
    try testing.expectEqual(@as(?u32, 0), d.function); // the input function's final index
    try testing.expectEqualDeep(
        Diagnostics.Detail{ .out_of_range = .{ .space = .local, .value = 1, .limit = 1 } },
        d.detail,
    );

    var valid_b = Builder.init();
    defer valid_b.deinit(testing.allocator);
    const valid = [_]Body.Instr{.{ .local_get = 0 }};
    try valid_b.setBody(testing.allocator, .{ .input = 0 }, .{
        .locals = .{ .replace = &.{} },
        .mode = .{ .replace = &valid },
    });
    const patch = try valid_b.patch();

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try emit(&m, &patch, &out.writer, .{});
    const m2 = try Module.parse(out.written());
    const query = try m2.query(.{});
    try testing.expectEqualSlices(u8, &.{ 0x20, 0x00 }, (try query.functionBody(0)).?.bodyRaw());
}

test "Builder: a function import shifts an existing body's diagnostic index" {
    const m = try Module.parse(&param_base);
    var b = Builder.init();
    defer b.deinit(testing.allocator);

    _ = try b.addImport(testing.allocator, "env", "log", .{ .function = .{ .input = 0 } });
    const invalid = [_]Body.Instr{.{ .local_get = 1 }};
    try b.setBody(testing.allocator, .{ .input = 0 }, .{
        .locals = .{ .replace = &.{} },
        .mode = .{ .replace = &invalid },
    });
    const patch = try b.patch();

    var d: Diagnostics = .{};
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(error.IndexOutOfRange, emit(&m, &patch, &w, .{ .diag = &d }));
    try testing.expectEqual(@as(?u32, 1), d.function); // input function 0, after the added import
    try testing.expectEqualDeep(
        Diagnostics.Detail{ .out_of_range = .{ .space = .local, .value = 1, .limit = 1 } },
        d.detail,
    );
}

test "Builder: an added body's bound comes from its type" {
    const base = header ++ sec(1, &.{ 1, 0x60, 1, 0x7F, 0 });
    const m = try Module.parse(&base);

    var b = Builder.init();
    defer b.deinit(testing.allocator);
    const added_type = try b.addType(testing.allocator, .{
        .params = .{ .typed = &.{ i32_type, i32_type } },
        .results = .{ .typed = &.{} },
    });
    const added = try b.addFunction(testing.allocator, added_type);
    const invalid = [_]Body.Instr{.{ .local_get = 2 }}; // two parameters, no locals
    try b.setBody(testing.allocator, added, .{
        .locals = .{ .replace = &.{} },
        .mode = .{ .replace = &invalid },
    });
    const patch = try b.patch();

    var d: Diagnostics = .{};
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(error.IndexOutOfRange, emit(&m, &patch, &w, .{ .diag = &d }));
    try testing.expectEqual(@as(?u32, 0), d.function); // 0 input functions, 0 imports, ordinal 0
    try testing.expectEqualDeep(
        Diagnostics.Detail{ .out_of_range = .{ .space = .local, .value = 2, .limit = 2 } },
        d.detail,
    );
}

test "Builder: an added import shifts the function index in a local-bound diagnostic" {
    const base = header ++ sec(1, &.{ 1, 0x60, 1, 0x7F, 0 });
    const m = try Module.parse(&base);

    var b = Builder.init();
    defer b.deinit(testing.allocator);
    _ = try b.addImport(testing.allocator, "env", "log", .{ .function = .{ .input = 0 } });
    const added = try b.addFunction(testing.allocator, .{ .input = 0 });
    const invalid = [_]Body.Instr{.{ .local_get = 1 }};
    try b.setBody(testing.allocator, added, .{
        .locals = .{ .replace = &.{} },
        .mode = .{ .replace = &invalid },
    });
    const patch = try b.patch();

    var d: Diagnostics = .{};
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(error.IndexOutOfRange, emit(&m, &patch, &w, .{ .diag = &d }));
    try testing.expectEqual(@as(?u32, 1), d.function); // after the added function import
}
