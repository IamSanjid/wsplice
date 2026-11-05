//! Tests of reading a module: function bodies, function types, and copying a body.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const index = @import("../index.zig");
const spec = @import("../spec.zig");
const Module = @import("../Module.zig");
const Patch = @import("../Patch.zig");
const Query = @import("../Query.zig");
const SetBodies = @import("../edit/SetBodies.zig");
const operators = @import("../payload/operators.zig");
const tables = @import("../payload/tables.zig");
const types = @import("../payload/types.zig");
const emit_mod = @import("../emit.zig");
const t = @import("support.zig");
const fixtures = @import("fixtures/fixtures.zig");

const emit = emit_mod.emit;
const one_type = t.sec(1, &.{ 1, 0x60, 0, 0 });

fn tableLimits(min: u64, max: ?u64) spec.Limits {
    return .{
        .flags = .{ .has_max = max != null, .is_shared = false, .is_64bit = false },
        .min = min,
        .max = max orelse 0,
    };
}

test "Query: bodies and types from imports.wasm" {
    const m = try Module.parse(fixtures.imports);
    const query = try m.query(.{});

    // function 0 is imported: it has a type but no body
    try testing.expect((try query.functionBody(0)) == null);
    try testing.expectEqual(index.Type{ .input = 0 }, (try query.functionType(0)).?);

    const f = (try query.functionBody(1)).?;
    try testing.expectEqualSlices(u8, &.{0x00}, f.locals);
    try testing.expectEqualSlices(u8, &.{ 0x20, 0x00 }, f.bodyRaw());

    var instructions = f.instructions();
    try testing.expectEqual(
        operators.Opcode{ .base = .local_get },
        (try instructions.next()).?.opcode,
    );
    try testing.expectEqual(null, try instructions.next());

    const g = (try query.functionBody(2)).?;
    try testing.expectEqualSlices(u8, &.{ 0x20, 0x00, 0x10, 0x00 }, g.bodyRaw());
    try testing.expectEqual(index.Type{ .input = 0 }, (try query.functionType(1)).?);
    try testing.expectEqual(index.Type{ .input = 0 }, (try query.functionType(2)).?);

    // past the last function index
    try testing.expect((try query.functionBody(3)) == null);
    try testing.expectEqual(@as(?index.Type, null), try query.functionType(3));
}

test "Query: functionInfo carries origin, type, signature and body" {
    const m = try Module.parse(fixtures.imports);
    const query = try m.query(.{});

    const imported = (try query.functionInfo(0)).?;
    try testing.expectEqual(Query.Origin.imported, imported.origin);
    try testing.expectEqual(index.Type{ .input = 0 }, imported.type_ref.?);
    try testing.expect(imported.signature != null);
    try testing.expect(imported.body == null);

    const defined = (try query.functionInfo(1)).?;
    try testing.expectEqual(Query.Origin.defined, defined.origin);
    try testing.expectEqual(index.Type{ .input = 0 }, defined.type_ref.?);
    try testing.expect(defined.signature != null);
    try testing.expect(defined.body != null);

    try testing.expectEqual(@as(?Query.FunctionInfo, null), try query.functionInfo(3));
}

test "Query: functionInfo keeps a defined function with no code entry" {
    // two functions declared, one code entry
    const bytes = t.header ++ one_type ++
        t.sec(3, &.{ 2, 0, 0 }) ++ t.sec(10, &.{ 1, 2, 0, 0x0B });
    const m = try Module.parse(&bytes);
    const query = try m.query(.{});

    const info = (try query.functionInfo(1)).?;
    try testing.expectEqual(Query.Origin.defined, info.origin);
    try testing.expectEqual(index.Type{ .input = 0 }, info.type_ref.?);
    try testing.expect(info.signature != null);
    try testing.expect(info.body == null);
}

test "Query: tableInfo carries origin and type" {
    {
        const m = try Module.parse(fixtures.imports);
        const query = try m.query(.{});
        const imported = (try query.tableInfo(0)).?;
        try testing.expectEqual(Query.Origin.imported, imported.origin);
        try testing.expectEqualDeep(
            tables.Type{ .reftype = .func, .limits = tableLimits(2, 10) },
            imported.table_type.?,
        );
        try testing.expectEqual(@as(?Query.TableInfo, null), try query.tableInfo(1));
    }
    {
        const bytes = t.header ++ t.entities;
        const m = try Module.parse(&bytes);
        const query = try m.query(.{});
        const defined = (try query.tableInfo(0)).?;
        try testing.expectEqual(Query.Origin.defined, defined.origin);
        try testing.expectEqualDeep(
            tables.Type{ .reftype = .func, .limits = tableLimits(1, null) },
            defined.table_type.?,
        );
        try testing.expectEqual(@as(?Query.TableInfo, null), try query.tableInfo(8));
    }
}

test "Query: function signatures decode parameters and results" {
    const m = try Module.parse(fixtures.imports);
    const query = try m.query(.{});

    // type 0 is (i32) -> i32, for an imported and a defined function alike
    const signature = (try query.functionSignature(1)).?;
    try testing.expectEqualSlices(u8, &.{0x7F}, signature.params.encoded.bytes);
    try testing.expectEqualSlices(u8, &.{0x7F}, signature.results.encoded.bytes);

    var params = types.Values.init(signature.params.encoded.bytes);
    try testing.expectEqualDeep(
        spec.ValueType{ .number_or_vector = .i32 },
        params.next().?,
    );
    try testing.expectEqual(null, params.next());

    const imported = (try query.functionSignature(0)).?;
    try testing.expectEqualSlices(u8, signature.params.encoded.bytes, imported.params.encoded.bytes);

    const by_index = (try query.typeSignature(0)).?;
    try testing.expectEqualSlices(u8, signature.params.encoded.bytes, by_index.params.encoded.bytes);
    try testing.expectEqualSlices(u8, signature.results.encoded.bytes, by_index.results.encoded.bytes);

    // past the type count, or a function that does not exist
    try testing.expectEqual(null, try query.typeSignature(1));
    try testing.expect((try query.functionSignature(99)) == null);
}

test "Query: a function whose type index is not in the type section has no signature" {
    // one type declared, but the function names type 5
    const bytes = t.header ++ one_type ++ t.sec(3, &.{ 1, 5 });
    const m = try Module.parse(&bytes);
    const query = try m.query(.{});
    try testing.expectEqual(index.Type{ .input = 5 }, (try query.functionType(0)).?);
    try testing.expect((try query.functionSignature(0)) == null);
}

test "Query: a malformed type section is reported" {
    // one function type whose results vector has no count
    const bytes = t.header ++ t.sec(1, &.{ 1, 0x60, 1, 0x7F });
    const m = try Module.parse(&bytes);
    const query = try m.query(.{});
    try testing.expectError(error.Truncated, query.typeSignature(0));
}

test "Query: a module with no functions has no bodies or types" {
    const m = try Module.parse(&t.header);
    const query = try m.query(.{});
    try testing.expect((try query.functionBody(0)) == null);
    try testing.expectEqual(@as(?index.Type, null), try query.functionType(0));
}

test "Query: a defined function with no code entry is null" {
    // two functions declared, one code entry
    const bytes = t.header ++ one_type ++
        t.sec(3, &.{ 2, 0, 0 }) ++ t.sec(10, &.{ 1, 2, 0, 0x0B });
    const m = try Module.parse(&bytes);
    const query = try m.query(.{});

    try testing.expect((try query.functionBody(0)) != null);
    try testing.expect((try query.functionBody(1)) == null);
    try testing.expectEqual(index.Type{ .input = 0 }, (try query.functionType(1)).?);
}

test "Query: a defined function's type comes from the function section" {
    const two_types = t.sec(1, &t.vec(2, &.{ 0x60, 0, 0 }));
    const bytes = t.header ++ two_types ++
        t.sec(3, &.{ 2, 0, 1 }) ++
        t.sec(10, &([_]u8{ 2, 2, 0, 0x0B, 2, 0, 0x0B }));
    const m = try Module.parse(&bytes);
    const query = try m.query(.{});

    try testing.expectEqual(index.Type{ .input = 0 }, (try query.functionType(0)).?);
    try testing.expectEqual(index.Type{ .input = 1 }, (try query.functionType(1)).?);
}

test "Query: a body without its final end is truncated" {
    // entry size 3: no locals, `i32.const 7`, and no `end`
    const bytes = t.header ++ one_type ++
        t.sec(3, &.{ 1, 0 }) ++ t.sec(10, &.{ 1, 3, 0, 0x41, 0x07 });
    const m = try Module.parse(&bytes);
    const query = try m.query(.{});
    try testing.expectError(error.Truncated, query.functionBody(0));
}

test "Query: a body with no expression is truncated" {
    // entry size 1: the locals vector only
    const bytes = t.header ++ one_type ++
        t.sec(3, &.{ 1, 0 }) ++ t.sec(10, &.{ 1, 1, 0x00 });
    const m = try Module.parse(&bytes);
    const query = try m.query(.{});
    try testing.expectError(error.Truncated, query.functionBody(0));
}

test "Query: a broken code section is reported, not copied" {
    // one entry whose size claims nine bytes, with two behind it
    const bytes = t.header ++ one_type ++
        t.sec(3, &.{ 1, 0 }) ++ t.sec(10, &.{ 1, 9, 0x00, 0x0B });
    const m = try Module.parse(&bytes);
    const query = try m.query(.{});
    try testing.expectError(error.Truncated, query.functionBody(0));
}

test "Query: a broken import section fails the query, not a body read" {
    const broken_imports = t.header ++ t.sec(2, &.{ 1, 0 });
    const m = try Module.parse(&broken_imports);
    try testing.expectError(error.Truncated, m.query(.{}));
}

test "Query: a copied body keeps padded LEBs" {
    // locals: run count 1, then one i32 with a padded run count; instructions: padded i32.const
    const bytes = t.header ++ one_type ++
        t.sec(3, &.{ 1, 0 }) ++
        t.sec(10, &.{ 1, 9, 0x01, 0x81, 0x80, 0x00, 0x7F, 0x41, 0x80, 0x00, 0x0B });
    const m = try Module.parse(&bytes);
    const query = try m.query(.{});
    const source = (try query.functionBody(0)).?;

    try testing.expectEqualSlices(u8, &.{ 0x01, 0x81, 0x80, 0x00, 0x7F }, source.locals);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x80, 0x00 }, source.bodyRaw());

    const edit: SetBodies = .{ .existing = &.{.{ .function = 0, .body = source.body() }} };
    var patch = Patch.empty;
    try patch.setPayload(.code, .{ .set_bodies = edit });
    try t.expectEmit(&bytes, &patch, &bytes);
}

test "Query: a body copied between functions is the same body" {
    const m = try Module.parse(fixtures.imports);
    const query = try m.query(.{});
    const source = (try query.functionBody(2)).?;

    const edit: SetBodies = .{ .existing = &.{.{ .function = 1, .body = source.body() }} };
    var patch = Patch.empty;
    try patch.setPayload(.code, .{ .set_bodies = edit });
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try emit(&m, &patch, &out.writer, .{});

    const m2 = try Module.parse(out.written());
    const query2 = try m2.query(.{});
    const copied = (try query2.functionBody(1)).?;
    try testing.expectEqualSlices(u8, source.locals, copied.locals);
    try testing.expectEqualSlices(u8, source.bodyRaw(), copied.bodyRaw());
    try t.expectTiles(out.written());

    // f and g have the same type, so the frame is two identical entries
    const code_start = m.section(.code).?.start;
    const entry = [_]u8{ 6, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0B };
    var expected: Io.Writer.Allocating = .init(testing.allocator);
    defer expected.deinit();
    try expected.writer.writeAll(fixtures.imports[0..code_start]);
    try expected.writer.writeAll(&([_]u8{ 0x0A, 0x0F, 0x02 })); // code, 15 bytes, two entries
    try expected.writer.writeAll(&entry);
    try expected.writer.writeAll(&entry);
    try testing.expectEqualSlices(u8, expected.written(), out.written());
}

test "Query: an imported table's type" {
    const m = try Module.parse(fixtures.imports);
    const query = try m.query(.{});

    try testing.expectEqualDeep(
        tables.Type{ .reftype = .func, .limits = tableLimits(2, 10) },
        (try query.tableType(0)).?,
    );
    try testing.expectEqual(@as(?tables.Type, null), try query.tableType(1));
}

test "Query: defined table types" {
    const bytes = t.header ++ t.entities;
    const m = try Module.parse(&bytes);
    const query = try m.query(.{});

    const first = (try query.tableType(0)).?;
    try testing.expectEqualDeep(
        tables.Type{ .reftype = .func, .limits = tableLimits(1, null) },
        first,
    );
    try testing.expectEqualDeep(first, (try query.tableType(7)).?);
    try testing.expectEqual(@as(?tables.Type, null), try query.tableType(8));
}

test "Query: table types mix imported and defined entries" {
    const import_payload = [_]u8{ 1, 1, 'e', 1, 't', 0x01, 0x70, 0x00, 1 };
    const bytes = t.header ++
        t.sec(2, &import_payload) ++
        t.sec(4, &.{ 2, 0x6F, 0x01, 2, 4, 0x70, 0x00, 3 });
    const m = try Module.parse(&bytes);
    const query = try m.query(.{});

    try testing.expectEqualDeep(
        tables.Type{ .reftype = .func, .limits = tableLimits(1, null) },
        (try query.tableType(0)).?,
    );
    try testing.expectEqualDeep(
        tables.Type{ .reftype = .@"extern", .limits = tableLimits(2, 4) },
        (try query.tableType(1)).?,
    );
    try testing.expectEqualDeep(
        tables.Type{ .reftype = .func, .limits = tableLimits(3, null) },
        (try query.tableType(2)).?,
    );
    try testing.expectEqual(@as(?tables.Type, null), try query.tableType(3));
}

test "Query: a broken table section is a query error" {
    const bytes = t.header ++ t.sec(4, &.{ 1, 0x63, 0x00, 0x00, 1 }); // prefixed reftype
    const m = try Module.parse(&bytes);
    const query = try m.query(.{});
    try testing.expectError(error.UnsupportedFeature, query.tableType(0));
}

test "Query: custom sections iterate in file order" {
    const bytes = t.header ++
        t.sec(0, &.{ 1, 'a', 0xAA }) ++
        one_type ++
        t.sec(0, &.{ 1, 'b', 0xBB }) ++
        t.sec(0, &.{ 1, 'a', 0xCC });
    const m = try Module.parse(&bytes);
    const query = try m.query(.{});

    var iterator = query.customSections();
    const first = (try iterator.next()).?;
    try testing.expectEqualStrings("a", first.name);
    try testing.expectEqualSlices(u8, &.{0xAA}, first.data);
    try testing.expectEqual(spec.SectionId.custom, first.section.id);

    const second = (try iterator.next()).?;
    try testing.expectEqualStrings("b", second.name);
    try testing.expectEqualSlices(u8, &.{0xBB}, second.data);

    const third = (try iterator.next()).?;
    try testing.expectEqualStrings("a", third.name);
    try testing.expectEqualSlices(u8, &.{0xCC}, third.data);
    try testing.expectEqual(null, try iterator.next());

    const lookup = (try query.customSection("a")).?;
    try testing.expectEqualSlices(u8, &.{0xAA}, lookup.data);
    try testing.expectEqual(@as(?Query.CustomSection, null), try query.customSection("missing"));
}

test "Query: a malformed custom name is Truncated" {
    const bytes = t.header ++ t.sec(0, &.{ 5, 'a' });
    const m = try Module.parse(&bytes);
    const query = try m.query(.{});
    var iterator = query.customSections();
    try testing.expectError(error.Truncated, iterator.next());
}
