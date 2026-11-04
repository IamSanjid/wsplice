//! Tests of the body edit: what is copied, what is re-encoded, and the failures.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const spec = @import("../../spec.zig");
const SectionId = spec.SectionId;
const Module = @import("../../Module.zig");
const Patch = @import("../../Patch.zig");
const Diagnostics = @import("../../Diagnostics.zig");
const errors = @import("../../errors.zig");
const EncodeError = errors.EncodeError;
const Body = @import("../../payload/Body.zig");
const SetBodies = @import("../../edit/SetBodies.zig");
const code = @import("../../payload/code.zig");
const operators = @import("../../payload/operators.zig");
const emit_mod = @import("../../emit.zig");
const t = @import("../support.zig");
const fixtures = @import("../fixtures/fixtures.zig");

const emit = emit_mod.emit;
const outputLen = emit_mod.outputLen;
const header = t.header;
const sec = t.sec;

// ---------------------------------------------------------------- helpers

fn patchSet(edit: SetBodies) !Patch {
    var p = Patch.empty;
    try p.setPayload(.code, .{ .set_bodies = edit });
    return p;
}

/// A failing edit must: return `expected_err` from emit and outputLen, write nothing, and record
/// the same error, the code section, and the detail.
fn expectEditFails(
    base: []const u8,
    edit: SetBodies,
    expected_err: anyerror,
    expected_detail: Diagnostics.Detail,
) !void {
    const m = try Module.parse(base);
    const p = try patchSet(edit);
    var buf: [256]u8 = undefined;

    var d: Diagnostics = .{};
    var w1: Io.Writer = .fixed(&buf);
    try testing.expectError(expected_err, emit(&m, &p, &w1, .{ .diag = &d }));
    try testing.expectEqual(@as(usize, 0), w1.buffered().len); // atomic: nothing reached the writer
    try testing.expectEqual(@as(?anyerror, expected_err), d.err);
    try testing.expectEqual(@as(?SectionId, .code), d.section);
    try testing.expectEqualDeep(expected_detail, d.detail);

    try testing.expectError(expected_err, outputLen(&m, &p, .{}));

    var w2: Io.Writer = .fixed(&buf); // no diagnostics: same error, still nothing written
    try testing.expectError(expected_err, emit(&m, &p, &w2, .{}));
    try testing.expectEqual(@as(usize, 0), w2.buffered().len);
}

// ---------------------------------------------------------------- fixtures

const one_type = sec(1, &.{ 1, 0x60, 0, 0 });
const empty_body = [_]u8{ 0x00, 0x0B }; // no locals, end
const two_functions = header ++ one_type ++ sec(3, &.{ 2, 0, 0 }) ++
    sec(10, &([_]u8{ 2, 2 } ++ empty_body ++ [_]u8{2} ++ empty_body));
const no_code = header ++ one_type ++ sec(3, &.{ 1, 0 });
const import_section = sec(2, &([_]u8{1} ++ t.importEntry("e", "f", &.{ 0x00, 0 })));
const with_import = header ++ one_type ++ import_section ++
    sec(3, &.{ 1, 0 }) ++ sec(10, &.{ 1, 2, 0x00, 0x0B });
/// One function with one i32 local; its body is `local.get 0; end`.
const with_locals = header ++ one_type ++ sec(3, &.{ 1, 0 }) ++
    sec(10, &.{ 1, 0x06, 0x01, 0x01, 0x7F, 0x20, 0x00, 0x0B });

// ---------------------------------------------------------------- bodies

const body_42: Body = .{
    .locals = .{ .replace = &.{} },
    .mode = .{ .replace = &.{.{ .i32_const = 42 }} },
};
const body_m1: Body = .{
    .locals = .{ .replace = &.{} },
    .mode = .{ .replace = &.{.{ .i64_const = -1 }} },
};
const body_locals: Body = .{
    .locals = .{ .replace = &.{.{ .count = 2, .valtype = .{ .number_or_vector = .i32 } }} },
    .mode = .{ .replace = &.{.{ .local_get = 1 }} },
};

/// Keeps every input instruction: rewriting an entry this way reproduces it.
const KeepAll = struct {
    pub fn rewrite(_: *const KeepAll, body: operators.BodyIter, out: *Body.Out) EncodeError!void {
        var iter = body;
        while (try iter.next()) |op| try out.keep(op);
    }
};

/// Ignores the input instructions and writes one constant.
const Emit7 = struct {
    pub fn rewrite(_: *const Emit7, body: operators.BodyIter, out: *Body.Out) EncodeError!void {
        _ = body;
        try out.write(&.{.{ .i32_const = 7 }});
    }
};
/// The encoded frames, size prefixes included.
const frame_42 = [_]u8{ 4, 0x00, 0x41, 0x2A, 0x0B };
const frame_m1 = [_]u8{ 4, 0x00, 0x42, 0x7F, 0x0B };
const frame_locals = [_]u8{ 6, 0x01, 0x02, 0x7F, 0x20, 0x01, 0x0B };
const frame_empty = [_]u8{ 2, 0x00, 0x0B };

// ------------------------------------------------------------ exact bytes

test "SetBodies: an empty edit copies every entry verbatim" {
    const patch = try patchSet(.{});
    try t.expectEmit(&two_functions, &patch, &two_functions);
}

test "SetBodies: replaces one body, the other entry is copied verbatim" {
    const edit: SetBodies = .{ .existing = &.{.{ .function = 1, .body = body_42 }} };
    const expected = header ++ one_type ++ sec(3, &.{ 2, 0, 0 }) ++
        sec(10, &([_]u8{2} ++ frame_empty ++ frame_42));
    const patch = try patchSet(edit);
    try t.expectEmit(&two_functions, &patch, &expected);
}

test "SetBodies: a replaced body is re-encoded, locals included" {
    const edit: SetBodies = .{ .existing = &.{.{ .function = 0, .body = body_locals }} };
    const expected = header ++ one_type ++ sec(3, &.{ 2, 0, 0 }) ++
        sec(10, &([_]u8{2} ++ frame_locals ++ frame_empty));
    const patch = try patchSet(edit);
    try t.expectEmit(&two_functions, &patch, &expected);
}

test "SetBodies: .keep preserves the input body's locals" {
    const edit: SetBodies = .{ .existing = &.{.{ .function = 0, .body = .{
        .locals = .keep,
        .mode = .{ .replace = &.{.{ .i32_const = 42 }} },
    } }} };
    // the vector is copied as it was; only the instructions and the size change
    const expected = header ++ one_type ++ sec(3, &.{ 1, 0 }) ++
        sec(10, &([_]u8{ 1, 0x06, 0x01, 0x01, 0x7F, 0x41, 0x2A, 0x0B }));
    const patch = try patchSet(edit);
    try t.expectEmit(&with_locals, &patch, &expected);
}

test "SetBodies: .append appends to the input body's locals" {
    const edit: SetBodies = .{
        .existing = &.{.{
            .function = 0,
            .body = .{
                .locals = .{
                    .append = &.{.{ .count = 1, .valtype = .{ .number_or_vector = .i64 } }},
                },
                .mode = .{ .replace = &.{.{ .local_get = 1 }} }, // the first added local
            },
        }},
    };
    const expected = header ++ one_type ++ sec(3, &.{ 1, 0 }) ++
        sec(10, &([_]u8{ 1, 0x08, 0x02, 0x01, 0x7F, 0x01, 0x7E, 0x20, 0x01, 0x0B }));
    const patch = try patchSet(edit);
    try t.expectEmit(&with_locals, &patch, &expected);
}

test "SetBodies: .append on an added body writes its own locals" {
    const edit: SetBodies = .{ .added = &.{.{
        .locals = .{ .append = &.{.{ .count = 1, .valtype = .{ .number_or_vector = .i64 } }} },
        .mode = .{ .replace = &.{.{ .local_get = 0 }} },
    }} };
    const expected = header ++ one_type ++ sec(3, &.{ 1, 0 }) ++
        sec(10, &([_]u8{1} ++ [_]u8{ 6, 0x01, 0x01, 0x7E, 0x20, 0x00, 0x0B }));
    const patch = try patchSet(edit);
    try t.expectEmit(&no_code, &patch, &expected);
}

test "SetBodies: a body added with .keep locals is NoInputBody" {
    const edit: SetBodies = .{ .added = &.{.{
        .locals = .keep,
        .mode = .{ .replace = &.{.{ .i32_const = 1 }} },
    }} };
    try expectEditFails(&no_code, edit, error.NoInputBody, .none);
}

test "SetBodies: appends a body, creating the code section" {
    const edit: SetBodies = .{ .added = &.{body_42} };
    const expected = header ++ one_type ++ sec(3, &.{ 1, 0 }) ++
        sec(10, &([_]u8{1} ++ frame_42));
    const patch = try patchSet(edit);
    try t.expectEmit(&no_code, &patch, &expected);
}

test "SetBodies: appended bodies come after the entries the input has" {
    const edit: SetBodies = .{ .added = &.{ body_42, body_m1 } };
    const expected = header ++ one_type ++ sec(3, &.{ 2, 0, 0 }) ++
        sec(10, &([_]u8{4} ++ frame_empty ++ frame_empty ++ frame_42 ++ frame_m1));
    const patch = try patchSet(edit);
    try t.expectEmit(&two_functions, &patch, &expected);
}

test "SetBodies: a replaced body and appended bodies can come in one edit" {
    const edit: SetBodies = .{
        .existing = &.{.{ .function = 1, .body = body_m1 }},
        .added = &.{body_42},
    };
    const expected = header ++ one_type ++ sec(3, &.{ 2, 0, 0 }) ++
        sec(10, &([_]u8{3} ++ frame_empty ++ frame_m1 ++ frame_42));
    const patch = try patchSet(edit);
    try t.expectEmit(&two_functions, &patch, &expected);
}

// ------------------------------------------------------------- padded LEBs

test "SetBodies: a copied entry keeps its padded size LEB, a replaced one does not" {
    // entry 0's size is 2, encoded in three bytes
    const padded = header ++ one_type ++ sec(3, &.{ 2, 0, 0 }) ++
        sec(10, &([_]u8{ 2, 0x82, 0x80, 0x00 } ++ empty_body ++ [_]u8{2} ++ empty_body));

    {
        // replace the second entry: the padded one is copied byte for byte
        const edit: SetBodies = .{ .existing = &.{.{ .function = 1, .body = body_42 }} };
        const expected = header ++ one_type ++ sec(3, &.{ 2, 0, 0 }) ++
            sec(10, &([_]u8{ 2, 0x82, 0x80, 0x00 } ++ empty_body ++ frame_42));
        const patch = try patchSet(edit);
        try t.expectEmit(&padded, &patch, &expected);
    }
    {
        // replace the first entry: its size becomes canonical
        const edit: SetBodies = .{ .existing = &.{.{ .function = 0, .body = body_42 }} };
        const expected = header ++ one_type ++ sec(3, &.{ 2, 0, 0 }) ++
            sec(10, &([_]u8{2} ++ frame_42 ++ [_]u8{2} ++ empty_body));
        const patch = try patchSet(edit);
        try t.expectEmit(&padded, &patch, &expected);
    }
}

test "SetBodies: a body at the size LEB boundary gets a two-byte prefix" {
    const nops: [126]u8 = @splat(0x01); // 126 nops, so the frame is 128 bytes
    const body: Body = .{ .locals = .{ .replace = &.{} }, .mode = .{ .replace = &.{.{ .raw = &nops }} } };
    const edit: SetBodies = .{ .added = &.{body} };

    var expected: Io.Writer.Allocating = .init(testing.allocator);
    defer expected.deinit();
    const w = &expected.writer;
    try w.writeAll(&no_code);
    try w.writeByte(10); // code
    try w.writeLeb128(@as(u32, 1 + 2 + 128)); // count, size prefix, frame
    try w.writeByte(1); // one entry
    try w.writeLeb128(@as(u32, 128)); // the frame is too big for a one-byte LEB
    try w.writeByte(0x00); // no locals
    try w.writeAll(&nops);
    try w.writeByte(0x0B);

    const patch = try patchSet(edit);
    try t.expectEmit(&no_code, &patch, expected.written());
}

// ---------------------------------------------------------------- indexes

test "SetBodies: a body resolves appended indices against the input's counts" {
    const body: Body = .{ .locals = .{ .replace = &.{} }, .mode = .{ .replace = &.{.{ .call = .{ .appended = 0 } }} } };
    const edit: SetBodies = .{ .added = &.{body} };
    // two functions in the input, so `.appended = 0` is function 2
    const expected = header ++ one_type ++ sec(3, &.{ 2, 0, 0 }) ++
        sec(10, &([_]u8{3} ++ frame_empty ++ frame_empty ++
            [_]u8{ 4, 0x00, 0x10, 0x02, 0x0B }));
    const patch = try patchSet(edit);
    try t.expectEmit(&two_functions, &patch, &expected);
}

test "SetBodies: an imported function has no body" {
    const edit: SetBodies = .{ .existing = &.{.{ .function = 0, .body = body_42 }} };
    try expectEditFails(&with_import, edit, error.ImportedFunction, .none);
}

test "SetBodies: the defined function after an import is index 1" {
    const edit: SetBodies = .{ .existing = &.{.{ .function = 1, .body = body_42 }} };
    const expected = header ++ one_type ++ import_section ++
        sec(3, &.{ 1, 0 }) ++ sec(10, &([_]u8{1} ++ frame_42));
    const patch = try patchSet(edit);
    try t.expectEmit(&with_import, &patch, &expected);
}

test "SetBodies: a function index the code section cannot cover is out of range" {
    const edit: SetBodies = .{ .existing = &.{.{ .function = 2, .body = body_42 }} };
    try expectEditFails(
        &two_functions,
        edit,
        error.IndexOutOfRange,
        .{ .out_of_range = .{ .space = .function, .value = 2, .limit = 2 } },
    );
}

test "SetBodies: a declared function with no code entry is out of range" {
    // The function section declares two functions, but the input has no code section.
    const declared = header ++ one_type ++ sec(3, &.{ 2, 0, 0 });
    const edit: SetBodies = .{ .existing = &.{.{ .function = 0, .body = body_42 }} };
    try expectEditFails(
        &declared,
        edit,
        error.IndexOutOfRange,
        .{ .out_of_range = .{ .space = .function, .value = 0, .limit = 0 } },
    );
}

test "SetBodies: two entries for one function are refused" {
    const edit: SetBodies = .{ .existing = &.{
        .{ .function = 0, .body = body_42 },
        .{ .function = 0, .body = body_m1 },
    } };
    try expectEditFails(&two_functions, edit, error.DuplicateBody, .none);
}

test "SetBodies: a broken old code section is reported before anything is written" {
    // One entry whose size claims five bytes, with room for two.
    const broken = header ++ sec(10, &.{ 1, 5, 0x00, 0x0B });
    const m = try Module.parse(&broken);
    const patch = try patchSet(.{});

    var d: Diagnostics = .{};
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(error.Truncated, emit(&m, &patch, &w, .{ .diag = &d }));
    try testing.expectEqual(@as(?anyerror, error.Truncated), d.err);
    try testing.expectEqual(@as(?SectionId, .code), d.section);
    try testing.expectEqual(@as(?u32, 11), d.offset); // the entry's size prefix
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

// --------------------------------------------------------------- rewriting

test "SetBodies: .rewrite of an existing body can copy it exactly" {
    const keep = KeepAll{};
    const edit: SetBodies = .{ .existing = &.{.{ .function = 0, .body = .{
        .locals = .keep,
        .mode = .{ .rewrite = Body.Rewriter.from(&keep) },
    } }} };
    const patch = try patchSet(edit);
    try t.expectEmit(&with_locals, &patch, &with_locals);
}

test "SetBodies: .rewrite can replace the input instructions" {
    // `f` is function 1: imports.wasm has one imported function. Its type is (i32) -> i32, so a
    // body of one constant is valid on its own.
    const emitter = Emit7{};
    const edit: SetBodies = .{ .existing = &.{.{ .function = 1, .body = .{
        .locals = .keep,
        .mode = .{ .rewrite = Body.Rewriter.from(&emitter) },
    } }} };
    const input = fixtures.imports;
    const m = try Module.parse(input);
    const code_start = m.section(.code).?.start;

    const new_entry = [_]u8{ 4, 0x00, 0x41, 0x07, 0x0B };
    const old_entry = [_]u8{ 6, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0B };

    var expected: Io.Writer.Allocating = .init(testing.allocator);
    defer expected.deinit();
    try expected.writer.writeAll(input[0..code_start]);
    try expected.writer.writeAll(&([_]u8{ 0x0A, 0x0D, 0x02 })); // code, 13 bytes, two entries
    try expected.writer.writeAll(&new_entry);
    try expected.writer.writeAll(&old_entry);

    const patch = try patchSet(edit);
    try t.expectEmit(input, &patch, expected.written());
}

test "SetBodies: Mode.raw copies instruction bytes verbatim" {
    const instructions = [_]u8{ 0x41, 0x80, 0x00 }; // i32.const 0 with a padded LEB
    const edit: SetBodies = .{ .existing = &.{.{ .function = 0, .body = .{
        .locals = .{ .replace = &.{} },
        .mode = .{ .raw = &instructions },
    } }} };
    const expected = header ++ one_type ++ sec(3, &.{ 2, 0, 0 }) ++
        sec(10, &([_]u8{2} ++ [_]u8{ 5, 0x00, 0x41, 0x80, 0x00, 0x0B } ++ frame_empty));
    const patch = try patchSet(edit);
    try t.expectEmit(&two_functions, &patch, &expected);
}

// --------------------------------------------------------------- read back

test "SetBodies: a replaced body reads back through the readers" {
    // `f` is function 1: imports.wasm has one imported function. Its new body is `x + 1`; the
    // function's only local is its parameter, which is in the type, not in the body.
    const edit: SetBodies = .{
        .existing = &.{.{
            .function = 1,
            .body = .{
                .locals = .{ .replace = &.{} },
                .mode = .{
                    .replace = &.{
                        .{ .local_get = 0 },
                        .{ .i32_const = 1 },
                        .{ .raw = &.{0x6A} }, // i32.add
                    },
                },
            },
        }},
    };
    const input = fixtures.imports;
    const m = try Module.parse(input);
    const code_start = m.section(.code).?.start;

    const new_entry = [_]u8{ 7, 0x00, 0x20, 0x00, 0x41, 0x01, 0x6A, 0x0B };
    const old_entry = [_]u8{ 6, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0B };

    var expected: Io.Writer.Allocating = .init(testing.allocator);
    defer expected.deinit();
    try expected.writer.writeAll(input[0..code_start]);
    try expected.writer.writeAll(&([_]u8{ 0x0A, 0x10, 0x02 })); // code, 16 bytes, two entries
    try expected.writer.writeAll(&new_entry);
    try expected.writer.writeAll(&old_entry);

    const patch = try patchSet(edit);
    try t.expectEmit(input, &patch, expected.written());

    const m2 = try Module.parse(expected.written());
    var it = try code.Iterator.init(m2.payloadCursor(.code).?);
    try testing.expectEqual(@as(u32, 2), it.count);

    const first = (try it.next()).?;
    try testing.expectEqualSlices(u8, &new_entry, first.bytes);

    var ops = operators.BodyIter.init(first.body);
    const expected_ops = [_]operators.Opcode{
        .{ .base = .local_get },
        .{ .base = .i32_const },
        .{ .base = .i32_add },
    };
    for (expected_ops) |expected_op| {
        const op = (try ops.next()).?;
        try testing.expectEqual(expected_op, op.opcode);
    }
    try testing.expectEqual(null, try ops.next());

    // The second entry is the input's, unchanged.
    const second = (try it.next()).?;
    try testing.expectEqualSlices(u8, &old_entry, second.bytes);
    try testing.expectEqual(null, try it.next());
}
