//! Tests of the body assembler: exact bytes, index resolution, the modes, and the failures.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const spec = @import("../../spec.zig");
const Module = @import("../../Module.zig");
const Cursor = @import("../../Cursor.zig");
const Counts = @import("../../payload/Counts.zig");
const Diagnostics = @import("../../Diagnostics.zig");
const errors = @import("../../errors.zig");
const EncodeError = errors.EncodeError;
const index = @import("../../index.zig");
const Plan = @import("../../Plan.zig");
const Body = @import("../../payload/Body.zig");
const Instr = Body.Instr;
const LocalDecl = Body.LocalDecl;
const operators = @import("../../payload/operators.zig");
const t = @import("../support.zig");

const header = t.header;
const entities = header ++ t.entities;
/// `entities` plus two types, so `call_indirect` has a type space and a table space.
const typed = header ++ t.sec(1, &t.vec(2, &.{ 0x60, 0, 0 })) ++ t.entities;
const no_locals: []const LocalDecl = &.{};
const no_instructions: []const Instr = &.{};
/// A body on its own resolves against the input only: the plan adds no imports in these tests.
const no_plan: Plan = .{};

/// The input body a replacement works against: no module needed, the cursor carries its bytes.
fn input(locals: []const u8, expression: []const u8) !Body.Input {
    return .{ .locals = locals, .body = try Cursor.init(expression) };
}

fn expectBody(module_bytes: []const u8, body: Body, expected: []const u8) !void {
    const m = try Module.parse(module_bytes);
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try body.encode(&m, &out.writer, .{});
    try testing.expectEqualSlices(u8, expected, out.written());
}

/// `body` replaces the input body `source`, and its frame is exactly `expected`.
fn expectBodyWithInput(
    module_bytes: []const u8,
    source: Body.Input,
    body: Body,
    expected: []const u8,
) !void {
    const m = try Module.parse(module_bytes);
    const counts = try Counts.of(&m, .{});
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try body.encodeWith(&counts, &no_plan, null, source, &out.writer, .{});
    try testing.expectEqualSlices(u8, expected, out.written());
    try testing.expectEqual(
        @as(u32, @intCast(expected.len)),
        try body.encodedLen(&counts, &no_plan, null, source, .{}),
    );
}

/// The same, with the plan's added imports: the module supplies the input's counts.
fn expectBodyWithAddedImports(
    module_bytes: []const u8,
    shifts: *const index.AddedImports,
    body: Body,
    expected: []const u8,
) !void {
    const plan: Plan = .{ .added_imports = shifts.* };
    const m = try Module.parse(module_bytes);
    const counts = try Counts.of(&m, .{});
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try body.encodeWith(&counts, &plan, null, null, &out.writer, .{});
    try testing.expectEqualSlices(u8, expected, out.written());
}

fn expectBodyError(
    module_bytes: []const u8,
    source: ?Body.Input,
    body: Body,
    expected_error: anyerror,
    expected_detail: Diagnostics.Detail,
) !void {
    const m = try Module.parse(module_bytes);
    const counts = try Counts.of(&m, .{});
    var diag: Diagnostics = .{};
    var buf: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try testing.expectError(
        expected_error,
        body.encodeWith(&counts, &no_plan, null, source, &writer, .{ .diag = &diag }),
    );
    try testing.expectEqual(@as(?anyerror, expected_error), diag.err);
    try testing.expectEqual(@as(?spec.SectionId, .code), diag.section);
    try testing.expectEqualDeep(expected_detail, diag.detail);
}

/// One instruction and no locals: the encoded body is `00`, the instruction, and `end`.
fn expectOne(instr: Instr, instruction_bytes: []const u8) !void {
    const instructions = [_]Instr{instr};
    var expected: [32]u8 = undefined;
    expected[0] = 0x00; // no locals
    @memcpy(expected[1..][0..instruction_bytes.len], instruction_bytes);
    expected[1 + instruction_bytes.len] = 0x0B;
    try expectBody(
        &header,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &instructions } },
        expected[0 .. 2 + instruction_bytes.len],
    );
}

// ------------------------------------------------------------------- bytes

test "Body: an empty body is a zero locals vector and end" {
    try expectBody(
        &header,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = no_instructions } },
        &.{ 0x00, 0x0B },
    );
}

test "Body: .replace writes each declaration as one run" {
    const locals = [_]LocalDecl{
        .{ .count = 2, .valtype = .{ .number_or_vector = .i32 } },
        .{ .count = 1, .valtype = .{ .number_or_vector = .v128 } },
        .{ .count = 1, .valtype = .{ .reference = .func } },
    };
    try expectBody(
        &header,
        .{ .locals = .{ .replace = &locals }, .mode = .{ .replace = no_instructions } },
        &.{ 0x03, 0x02, 0x7F, 0x01, 0x7B, 0x01, 0x70, 0x0B },
    );
}

test "Body: .replace does not merge equal adjacent declarations" {
    const locals = [_]LocalDecl{
        .{ .count = 1, .valtype = .{ .number_or_vector = .i32 } },
        .{ .count = 1, .valtype = .{ .number_or_vector = .i32 } },
    };
    // two runs of one, not one run of two: exactly what was asked for
    try expectBody(
        &header,
        .{ .locals = .{ .replace = &locals }, .mode = .{ .replace = no_instructions } },
        &.{ 0x02, 0x01, 0x7F, 0x01, 0x7F, 0x0B },
    );
}

// ------------------------------------------------------------- locals modes

test "Body: .keep copies the input body's vector as it is" {
    // one run, its length encoded in three bytes
    const old = [_]u8{ 0x01, 0x81, 0x80, 0x00, 0x7F };
    const body: Body = .{
        .locals = .keep,
        .mode = .{ .replace = &.{.{ .i32_const = 7 }} },
    };
    try expectBodyWithInput(
        &header,
        try input(&old, &.{0x0B}),
        body,
        &([_]u8{ 0x01, 0x81, 0x80, 0x00, 0x7F, 0x41, 0x07, 0x0B }),
    );
}

test "Body: .keep without an input body is NoInputBody" {
    const body: Body = .{ .locals = .keep, .mode = .{ .replace = no_instructions } };
    try expectBodyError(&header, null, body, error.NoInputBody, .none);
}

test "Body: .replace ignores the input body's vector" {
    const old = [_]u8{ 0x01, 0x01, 0x7F };
    const body: Body = .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = no_instructions } };
    try expectBodyWithInput(&header, try input(&old, &.{0x0B}), body, &.{ 0x00, 0x0B });
}

test "Body: .append appends the new runs after the input's" {
    const old = [_]u8{ 0x02, 0x02, 0x7F, 0x01, 0x7B }; // 2 x i32, 1 x v128
    const added = [_]LocalDecl{
        .{ .count = 2, .valtype = .{ .number_or_vector = .i32 } },
    };
    const body: Body = .{ .locals = .{ .append = &added }, .mode = .{ .replace = no_instructions } };
    try expectBodyWithInput(
        &header,
        try input(&old, &.{0x0B}),
        body,
        &([_]u8{ 0x03, 0x02, 0x7F, 0x01, 0x7B } ++ [_]u8{ 0x02, 0x7F, 0x0B }),
    );
}

test "Body: .append leaves the input's run bytes alone, count included" {
    // the input's run length is a padded LEB: only the vector's run count is rewritten
    const old = [_]u8{ 0x01, 0x81, 0x80, 0x00, 0x7F };
    const added = [_]LocalDecl{.{ .count = 1, .valtype = .{ .reference = .func } }};
    const body: Body = .{ .locals = .{ .append = &added }, .mode = .{ .replace = no_instructions } };
    try expectBodyWithInput(
        &header,
        try input(&old, &.{0x0B}),
        body,
        &([_]u8{ 0x02, 0x81, 0x80, 0x00, 0x7F } ++ [_]u8{ 0x01, 0x70, 0x0B }),
    );
}

test "Body: .append does not merge into the input's last run" {
    const old = [_]u8{ 0x01, 0x01, 0x7F }; // one i32
    const added = [_]LocalDecl{.{ .count = 1, .valtype = .{ .number_or_vector = .i32 } }};
    const body: Body = .{ .locals = .{ .append = &added }, .mode = .{ .replace = no_instructions } };
    // two separate i32 runs, not one run of two: valid, not canonical
    try expectBodyWithInput(
        &header,
        try input(&old, &.{0x0B}),
        body,
        &.{ 0x02, 0x01, 0x7F, 0x01, 0x7F, 0x0B },
    );
}

test "Body: .append without an input body writes its own declarations" {
    const added = [_]LocalDecl{
        .{ .count = 2, .valtype = .{ .number_or_vector = .i32 } },
    };
    const body: Body = .{ .locals = .{ .append = &added }, .mode = .{ .replace = no_instructions } };
    try expectBody(&header, body, &.{ 0x01, 0x02, 0x7F, 0x0B });
}

test "Body: .append needs the input vector's run count to be readable" {
    const body: Body = .{ .locals = .{ .append = no_locals }, .mode = .{ .replace = no_instructions } };
    const m = try Module.parse(&header);
    const counts = try Counts.of(&m, .{});
    var buf: [8]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const source = try input(&.{0x80}, &.{0x0B});
    try testing.expectError(error.Truncated, body.encodeWith(&counts, &no_plan, null, source, &writer, .{}));
}

test "Body: .raw locals are the whole vector, verbatim" {
    // two runs: 1 x i32 with a padded run length, then 1 x v128
    const raw = [_]u8{ 0x02, 0x81, 0x80, 0x00, 0x7F, 0x01, 0x7B };
    const body: Body = .{ .locals = .{ .raw = &raw }, .mode = .{ .replace = no_instructions } };
    try expectBody(&header, body, &(raw ++ [_]u8{0x0B}));
}

// ------------------------------------------------------------ instruction modes

test "Mode.raw writes its instruction bytes verbatim" {
    const instructions = [_]u8{ 0x41, 0x80, 0x00 }; // i32.const 0 with a padded LEB
    const body: Body = .{ .locals = .{ .replace = no_locals }, .mode = .{ .raw = &instructions } };
    try expectBody(&header, body, &.{ 0x00, 0x41, 0x80, 0x00, 0x0B });
}

test "Mode.raw may be empty" {
    const body: Body = .{ .locals = .{ .replace = no_locals }, .mode = .{ .raw = &.{} } };
    try expectBody(&header, body, &.{ 0x00, 0x0B });
}

/// Keeps every instruction, or drops `nop`s, and writes a preface before them.
const Rewrite = struct {
    drop_nops: bool = false,
    preface: []const Instr = &.{},

    pub fn rewrite(self: *const Rewrite, body: operators.BodyIter, out: *Body.Out) EncodeError!void {
        var iter = body;
        try out.write(self.preface);
        while (try iter.next()) |op| {
            if (self.drop_nops and isNop(op)) continue;
            try out.keep(op);
        }
    }

    fn isNop(op: operators.Op) bool {
        return switch (op.opcode) {
            .base => |base| base == .nop,
            else => false,
        };
    }
};

/// Asserts the stream is empty, then writes one instruction: what an added function's rewriter gets.
const EmitOnly = struct {
    pub fn rewrite(_: *const EmitOnly, body: operators.BodyIter, out: *Body.Out) EncodeError!void {
        var iter = body;
        if (try iter.next() != null) return error.InvalidValue;
        try out.write(&.{.{ .i32_const = 5 }});
    }
};

const Failing = struct {
    pub fn rewrite(_: *const Failing, body: operators.BodyIter, out: *Body.Out) EncodeError!void {
        _ = body;
        _ = out;
        return error.InvalidValue;
    }
};

test "Mode.rewrite keeps, skips, and writes instructions" {
    const old = [_]u8{ 0x01, 0x01, 0x7F }; // one i32 local
    const expression = [_]u8{ 0x01, 0x41, 0x07, 0x01, 0x0B }; // nop, i32.const 7, nop, end
    const rewriter = Rewrite{ .drop_nops = true, .preface = &.{.{ .i32_const = 1 }} };
    const body: Body = .{
        .locals = .keep,
        .mode = .{ .rewrite = Body.Rewriter.from(&rewriter) },
    };
    try expectBodyWithInput(
        &header,
        try input(&old, &expression),
        body,
        &([_]u8{ 0x01, 0x01, 0x7F, 0x41, 0x01, 0x41, 0x07, 0x0B }),
    );
}

test "Mode.rewrite: keep copies the input bytes, padded LEBs and blocks included" {
    const expression = [_]u8{
        0x02, 0x40, //       block
        0x41, 0x80, 0x00, // i32.const 0, padded LEB
        0x01, //             nop
        0x0B, //             end of the block
        0x0B, //             end of the body
    };
    const rewriter = Rewrite{};
    const body: Body = .{
        .locals = .{ .raw = &.{0x00} },
        .mode = .{ .rewrite = Body.Rewriter.from(&rewriter) },
    };
    try expectBodyWithInput(
        &header,
        try input(&.{0x00}, &expression),
        body,
        &([_]u8{0x00} ++ expression),
    );
}

test "Mode.rewrite on an added body gets an empty stream" {
    const rewriter = EmitOnly{};
    const body: Body = .{
        .locals = .{ .replace = no_locals },
        .mode = .{ .rewrite = Body.Rewriter.from(&rewriter) },
    };
    try expectBody(&header, body, &.{ 0x00, 0x41, 0x05, 0x0B });
}

test "Mode.rewrite returns the callback's error, with the section" {
    const rewriter = Failing{};
    const body: Body = .{
        .locals = .{ .replace = no_locals },
        .mode = .{ .rewrite = Body.Rewriter.from(&rewriter) },
    };
    try expectBodyError(&header, null, body, error.InvalidValue, .none);
}

test "Mode.rewrite on a truncated input body is truncated" {
    const rewriter = Rewrite{};
    const body: Body = .{
        .locals = .{ .replace = no_locals },
        .mode = .{ .rewrite = Body.Rewriter.from(&rewriter) },
    };
    // i32.const 7 with no final `end`
    const source = try input(&.{0x00}, &.{ 0x41, 0x07 });
    try expectBodyError(&header, source, body, error.Truncated, .none);
}

test "Mode.rewrite is deterministic across encodes" {
    const expression = [_]u8{ 0x01, 0x41, 0x07, 0x0B };
    const rewriter = Rewrite{ .drop_nops = true };
    const body: Body = .{
        .locals = .{ .replace = no_locals },
        .mode = .{ .rewrite = Body.Rewriter.from(&rewriter) },
    };
    const m = try Module.parse(&header);
    const counts = try Counts.of(&m, .{});
    const source = try input(&.{0x00}, &expression);

    var a: Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    try body.encodeWith(&counts, &no_plan, null, source, &a.writer, .{});
    try body.encodeWith(&counts, &no_plan, null, source, &b.writer, .{});
    try testing.expectEqualSlices(u8, a.written(), b.written());
}

test "Body: a body of every supported instruction, exact bytes" {
    const locals = [_]LocalDecl{
        .{ .count = 2, .valtype = .{ .number_or_vector = .i32 } },
    };
    const instructions = [_]Instr{
        .{ .i32_const = 7 },
        .{ .i64_const = -1 },
        .{ .f32_const = 1.0 },
        .{ .f64_const = 1.0 },
        .{ .local_get = 0 },
        .{ .local_get = 1 },
        .{ .call = .{ .input = 0 } },
        .{ .global_get = .{ .input = 2 } },
    };
    try expectBody(
        &entities,
        .{ .locals = .{ .replace = &locals }, .mode = .{ .replace = &instructions } },
        &([_]u8{ 0x01, 0x02, 0x7F } ++ // one run: two i32
            [_]u8{ 0x41, 0x07, 0x42, 0x7F, 0x43, 0x00, 0x00, 0x80, 0x3F } ++ // i32 7, i64 -1, f32 1.0
            [_]u8{ 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F } ++ // f64 1.0
            [_]u8{ 0x20, 0x00, 0x20, 0x01, 0x10, 0x00, 0x23, 0x02, 0x0B }),
    );
}

test "Body: i32.const is a signed LEB, including both edges of every width" {
    const Case = struct { value: i32, bytes: []const u8 };
    const cases = [_]Case{
        .{ .value = 0, .bytes = &.{0x00} },
        .{ .value = 42, .bytes = &.{0x2A} },
        .{ .value = 63, .bytes = &.{0x3F} },
        .{ .value = 64, .bytes = &.{ 0xC0, 0x00 } },
        .{ .value = 127, .bytes = &.{ 0xFF, 0x00 } },
        .{ .value = -1, .bytes = &.{0x7F} },
        .{ .value = -64, .bytes = &.{0x40} },
        .{ .value = -65, .bytes = &.{ 0xBF, 0x7F } },
        .{ .value = -128, .bytes = &.{ 0x80, 0x7F } },
        .{ .value = std.math.maxInt(i32), .bytes = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x07 } },
        .{ .value = std.math.minInt(i32), .bytes = &.{ 0x80, 0x80, 0x80, 0x80, 0x78 } },
    };
    for (cases) |case| {
        var bytes: [10]u8 = undefined;
        bytes[0] = 0x41; // i32.const
        @memcpy(bytes[1..][0..case.bytes.len], case.bytes);
        try expectOne(.{ .i32_const = case.value }, bytes[0 .. 1 + case.bytes.len]);
    }
}

test "Body: i64.const is a signed LEB, including both edges of every width" {
    const Case = struct { value: i64, bytes: []const u8 };
    const cases = [_]Case{
        .{ .value = 0, .bytes = &.{0x00} },
        .{ .value = 42, .bytes = &.{0x2A} },
        .{ .value = 64, .bytes = &.{ 0xC0, 0x00 } },
        .{ .value = -1, .bytes = &.{0x7F} },
        .{ .value = -65, .bytes = &.{ 0xBF, 0x7F } },
        .{ .value = -128, .bytes = &.{ 0x80, 0x7F } },
        .{ .value = std.math.maxInt(i64), .bytes = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 } },
        .{ .value = std.math.minInt(i64), .bytes = &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7F } },
    };
    for (cases) |case| {
        var bytes: [12]u8 = undefined;
        bytes[0] = 0x42; // i64.const
        @memcpy(bytes[1..][0..case.bytes.len], case.bytes);
        try expectOne(.{ .i64_const = case.value }, bytes[0 .. 1 + case.bytes.len]);
    }
}

test "Body: f32.const and f64.const are little-endian IEEE 754" {
    const F32 = struct { value: f32, bytes: []const u8 };
    const f32_cases = [_]F32{
        .{ .value = 0.0, .bytes = &.{ 0x00, 0x00, 0x00, 0x00 } },
        .{ .value = 1.0, .bytes = &.{ 0x00, 0x00, 0x80, 0x3F } },
        .{ .value = -1.0, .bytes = &.{ 0x00, 0x00, 0x80, 0xBF } },
        .{ .value = 1.5, .bytes = &.{ 0x00, 0x00, 0xC0, 0x3F } },
        .{ .value = -0.0, .bytes = &.{ 0x00, 0x00, 0x00, 0x80 } },
    };
    for (f32_cases) |case| {
        var bytes: [5]u8 = undefined;
        bytes[0] = 0x43; // f32.const
        @memcpy(bytes[1..], case.bytes);
        try expectOne(.{ .f32_const = case.value }, &bytes);
    }

    const F64 = struct { value: f64, bytes: []const u8 };
    const f64_cases = [_]F64{
        .{ .value = 0.0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .value = 1.0, .bytes = &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F } },
        .{ .value = -2.0, .bytes = &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0 } },
        .{ .value = 1.5, .bytes = &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F } },
    };
    for (f64_cases) |case| {
        var bytes: [9]u8 = undefined;
        bytes[0] = 0x44; // f64.const
        @memcpy(bytes[1..], case.bytes);
        try expectOne(.{ .f64_const = case.value }, &bytes);
    }
}

test "Body: Instr.raw bytes are emitted verbatim" {
    const instructions = [_]Instr{
        .{ .raw = &.{ 0x41, 0x80, 0x00 } }, // i32.const 0 with a padded LEB: not re-encoded
        .{ .i32_const = 1 },
        .{ .raw = &.{0x6A} }, // i32.add, which has no variant yet
    };
    try expectBody(
        &header,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &instructions } },
        &.{ 0x00, 0x41, 0x80, 0x00, 0x41, 0x01, 0x6A, 0x0B },
    );
}

test "Body: the Instr.raw escape hatch may be empty" {
    const instructions = [_]Instr{
        .{ .raw = &.{} },
        .{ .i32_const = 0 },
        .{ .raw = &.{} },
    };
    try expectBody(
        &header,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &instructions } },
        &.{ 0x00, 0x41, 0x00, 0x0B },
    );
}

// -------------------------------------------------------------- resolution

test "Body: call resolves an input function index" {
    try expectBody(
        &entities,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &.{.{ .call = .{ .input = 7 } }} } },
        &.{ 0x00, 0x10, 0x07, 0x0B },
    );
}

test "Body: call resolves an appended function index after the input's functions" {
    // 8 defined functions, so the first function this plan adds is index 8.
    try expectBody(
        &entities,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &.{.{ .call = .{ .appended = 0 } }} } },
        &.{ 0x00, 0x10, 0x08, 0x0B },
    );
    try expectBody(
        &entities,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &.{.{ .call = .{ .appended = 2 } }} } },
        &.{ 0x00, 0x10, 0x0A, 0x0B },
    );
    // no functions at all: the first added one is index 0
    try expectBody(
        &header,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &.{.{ .call = .{ .appended = 0 } }} } },
        &.{ 0x00, 0x10, 0x00, 0x0B },
    );
}

test "Body: global.get resolves input and appended global indices" {
    try expectBody(
        &entities,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &.{.{ .global_get = .{ .input = 3 } }} } },
        &.{ 0x00, 0x23, 0x03, 0x0B },
    );
    // 8 defined globals, so the second global this plan adds is index 9.
    try expectBody(
        &entities,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &.{.{ .global_get = .{ .appended = 1 } }} } },
        &.{ 0x00, 0x23, 0x09, 0x0B },
    );
}

test "Body: call_indirect resolves its type and table indices" {
    try expectBody(
        &typed,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &.{.{ .call_indirect = .{
            .type = .{ .input = 1 },
            .table = .{ .input = 0 },
        } }} } },
        &.{ 0x00, 0x11, 0x01, 0x00, 0x0B },
    );
    // 2 types and 8 tables, so the first added type is 2 and the first added table is 8.
    try expectBody(
        &typed,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &.{.{ .call_indirect = .{
            .type = .{ .appended = 0 },
            .table = .{ .appended = 0 },
        } }} } },
        &.{ 0x00, 0x11, 0x02, 0x08, 0x0B },
    );
}

test "Body: added imports shift tables and globals, but never types" {
    // One imported table, one imported global, one defined table, one defined global.
    const import_payload = [_]u8{
        2,
        1, 'e', 1, 't', 0x01, 0x70, 0x00, 1, // table: funcref, min 1
        1, 'e', 1, 'g', 0x03, 0x7F, 0x00, // global: i32, immutable
    };
    const module_bytes = header ++
        t.sec(1, &.{ 1, 0x60, 0, 0 }) ++
        t.sec(2, &import_payload) ++
        t.sec(4, &.{ 1, 0x70, 0x00, 1 }) ++ // one defined table
        t.sec(6, &.{ 1, 0x7F, 0x00, 0x41, 0x00, 0x0B }); // one defined global

    var shifts: index.AddedImports = .{};
    shifts.add(.table);
    shifts.add(.table);
    shifts.add(.global);

    const instructions = [_]Instr{
        // type .appended is not shifted; table 0 is an input import, so it stays.
        .{ .call_indirect = .{ .type = .{ .appended = 0 }, .table = .{ .input = 0 } } },
        // table 1 is defined: 1 + 2 added table imports = 3.
        .{ .call_indirect = .{ .type = .{ .input = 0 }, .table = .{ .input = 1 } } },
        // the second added table import: 1 input import + 1 = 2.
        .{ .call_indirect = .{ .type = .{ .input = 0 }, .table = .{ .added_import = 1 } } },
        // global 0 is an input import; global 1 is defined and shifts by one.
        .{ .global_get = .{ .input = 0 } },
        .{ .global_get = .{ .input = 1 } },
        .{ .global_get = .{ .added_import = 0 } },
    };
    try expectBodyWithAddedImports(
        &module_bytes,
        &shifts,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &instructions } },
        &.{
            0x00, // no locals
            0x11, 0x01, 0x00, // call_indirect type 1 (input types + 0), table 0
            0x11, 0x00, 0x03, // call_indirect type 0, table 3
            0x11, 0x00, 0x02, // call_indirect type 0, table 2 (the added import)
            0x23, 0x00, // global.get 0 (input import)
            0x23, 0x02, // global.get 2 (defined, shifted)
            0x23, 0x01, // global.get 1 (added import)
            0x0B,
        },
    );
}

test "Body: call parameters are pushed before the call" {
    // A call carries no parameter list: its arguments are the values already on the stack, so a
    // two-argument call is two pushes and then the call.
    const locals = [_]LocalDecl{
        .{ .count = 2, .valtype = .{ .number_or_vector = .i32 } },
    };
    const instructions = [_]Instr{
        .{ .local_get = 0 }, // argument 0
        .{ .local_get = 1 }, // argument 1
        .{ .call = .{ .input = 0 } },
    };
    try expectBody(
        &entities,
        .{ .locals = .{ .replace = &locals }, .mode = .{ .replace = &instructions } },
        &.{ 0x01, 0x02, 0x7F, 0x20, 0x00, 0x20, 0x01, 0x10, 0x00, 0x0B },
    );
}

test "Body: call_indirect takes the table element index after the arguments" {
    // Stack order: the arguments first, then the element index, then the instruction.
    const locals = [_]LocalDecl{.{ .count = 1, .valtype = .{ .number_or_vector = .i32 } }};
    const instructions = [_]Instr{
        .{ .local_get = 0 }, // argument
        .{ .i32_const = 3 }, // table element index, pushed last
        .{ .call_indirect = .{ .type = .{ .input = 0 }, .table = .{ .input = 0 } } },
    };
    try expectBody(
        &typed,
        .{ .locals = .{ .replace = &locals }, .mode = .{ .replace = &instructions } },
        &([_]u8{ 0x01, 0x01, 0x7F } ++ [_]u8{ 0x20, 0x00, 0x41, 0x03, 0x11, 0x00, 0x00, 0x0B }),
    );
}

test "Body: local.get is written as given, parameters included" {
    // The assembler does not know the function's parameters, so it does not bound the index.
    const two = [_]LocalDecl{
        .{ .count = 1, .valtype = .{ .number_or_vector = .i32 } },
        .{ .count = 1, .valtype = .{ .number_or_vector = .i64 } },
    };
    try expectBody(
        &header,
        .{ .locals = .{ .replace = &two }, .mode = .{ .replace = &.{.{ .local_get = 1 }} } },
        &.{ 0x02, 0x01, 0x7F, 0x01, 0x7E, 0x20, 0x01, 0x0B },
    );
    // local 0 can be a parameter even when the body declares no locals
    try expectBody(
        &header,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &.{.{ .local_get = 0 }} } },
        &.{ 0x00, 0x20, 0x00, 0x0B },
    );
}

// ---------------------------------------------------------------- failures

test "Body: an input function or global past the input's total is out of range" {
    try expectBodyError(
        &entities,
        null,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &.{.{ .call = .{ .input = 8 } }} } },
        error.IndexOutOfRange,
        .{ .out_of_range = .{ .space = .function, .value = 8, .limit = 8 } },
    );
    try expectBodyError(
        &entities,
        null,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &.{.{ .global_get = .{ .input = 8 } }} } },
        error.IndexOutOfRange,
        .{ .out_of_range = .{ .space = .global, .value = 8, .limit = 8 } },
    );
    try expectBodyError(
        &header,
        null,
        .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &.{.{ .call = .{ .input = 0 } }} } },
        error.IndexOutOfRange,
        .{ .out_of_range = .{ .space = .function, .value = 0, .limit = 0 } },
    );
}

test "Body: call_indirect indices are bounded by their spaces" {
    try expectBodyError(
        &typed,
        null,
        .{
            .locals = .{ .replace = no_locals },
            .mode = .{
                .replace = &.{.{
                    .call_indirect = .{
                        .type = .{ .input = 2 }, // only 2 types exist
                        .table = .{ .input = 0 },
                    },
                }},
            },
        },
        error.IndexOutOfRange,
        .{ .out_of_range = .{ .space = .type, .value = 2, .limit = 2 } },
    );
    try expectBodyError(
        &typed,
        null,
        .{
            .locals = .{ .replace = no_locals },
            .mode = .{
                .replace = &.{.{
                    .call_indirect = .{
                        .type = .{ .input = 0 },
                        .table = .{ .input = 8 }, // only 8 tables exist
                    },
                }},
            },
        },
        error.IndexOutOfRange,
        .{ .out_of_range = .{ .space = .table, .value = 8, .limit = 8 } },
    );
}

// ---------------------------------------------------------------- repeats

test "Body: encoding the same body twice gives the same bytes" {
    const two = [_]LocalDecl{
        .{ .count = 1, .valtype = .{ .number_or_vector = .i32 } },
        .{ .count = 1, .valtype = .{ .reference = .func } },
    };
    const instructions = [_]Instr{
        .{ .i32_const = -1 },
        .{ .local_get = 0 },
        .{ .call = .{ .appended = 1 } },
    };
    const body: Body = .{ .locals = .{ .replace = &two }, .mode = .{ .replace = &instructions } };
    const m = try Module.parse(&entities);

    var a: Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    try body.encode(&m, &a.writer, .{});
    try body.encode(&m, &b.writer, .{});
    try testing.expectEqualSlices(u8, a.written(), b.written());
}

// ----------------------------------------------------------- counts reuse

test "Body: encodeWith writes what encode writes, against counts the caller has" {
    const m = try Module.parse(&entities);
    const counts = try Counts.of(&m, .{});
    const two = [_]LocalDecl{
        .{ .count = 1, .valtype = .{ .number_or_vector = .i32 } },
        .{ .count = 1, .valtype = .{ .reference = .func } },
    };
    const instructions = [_]Instr{ .{ .i32_const = -1 }, .{ .local_get = 1 } };
    const body: Body = .{ .locals = .{ .replace = &two }, .mode = .{ .replace = &instructions } };

    var a: Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    try body.encode(&m, &a.writer, .{});
    try body.encodeWith(&counts, &no_plan, null, null, &b.writer, .{});
    try testing.expectEqualSlices(u8, a.written(), b.written());
    try testing.expectEqual(
        @as(u32, @intCast(a.written().len)),
        try body.encodedLen(&counts, &no_plan, null, null, .{}),
    );
}

test "Body: encodedLen counts every byte the body writes" {
    const m = try Module.parse(&header);
    const counts = try Counts.of(&m, .{});
    const empty: Body = .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = no_instructions } };
    try testing.expectEqual(@as(u32, 2), try empty.encodedLen(&counts, &no_plan, null, null, .{})); // locals 0, end

    const nops: [126]u8 = @splat(0x01);
    const big: Body = .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &.{.{ .raw = &nops }} } };
    try testing.expectEqual(@as(u32, 128), try big.encodedLen(&counts, &no_plan, null, null, .{})); // locals, nops, end
}

// ------------------------------------------------------------- local bounds

const one_i32_local = [_]LocalDecl{.{ .count = 1, .valtype = .{ .number_or_vector = .i32 } }};

fn expectBodyOwned(
    plan: *const Plan,
    owner: ?Body.Owner,
    body: Body,
    expected: []const u8,
) !void {
    const m = try Module.parse(&header);
    const counts = try Counts.of(&m, .{});
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try body.encodeWith(&counts, plan, owner, null, &out.writer, .{});
    try testing.expectEqualSlices(u8, expected, out.written());
}

fn expectBodyOwnedInput(
    plan: *const Plan,
    owner: ?Body.Owner,
    source: Body.Input,
    body: Body,
    expected: []const u8,
) !void {
    const m = try Module.parse(&header);
    const counts = try Counts.of(&m, .{});
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try body.encodeWith(&counts, plan, owner, source, &out.writer, .{});
    try testing.expectEqualSlices(u8, expected, out.written());
}

test "Body: local.get is bounded by parameters plus declared locals" {
    const owner: Body.Owner = .{ .emitted_function = 5, .parameter_count = 2 };
    const valid = [_]Instr{.{ .local_get = 2 }};
    try expectBodyOwned(&no_plan, owner, .{
        .locals = .{ .replace = &one_i32_local },
        .mode = .{ .replace = &valid },
    }, &.{ 0x01, 0x01, 0x7F, 0x20, 0x02, 0x0B });

    const invalid = [_]Instr{.{ .local_get = 3 }};
    const m = try Module.parse(&header);
    const counts = try Counts.of(&m, .{});
    const body: Body = .{
        .locals = .{ .replace = &one_i32_local },
        .mode = .{ .replace = &invalid },
    };
    var d: Diagnostics = .{};
    try testing.expectError(
        error.IndexOutOfRange,
        body.encodedLen(&counts, &no_plan, owner, null, .{ .diag = &d }),
    );
    try testing.expectEqual(@as(?anyerror, error.IndexOutOfRange), d.err);
    try testing.expectEqual(@as(?spec.SectionId, .code), d.section);
    try testing.expectEqual(@as(?u32, 5), d.function);
    try testing.expectEqualDeep(
        Diagnostics.Detail{ .out_of_range = .{ .space = .local, .value = 3, .limit = 3 } },
        d.detail,
    );
}

test "Body: kept locals count toward the bound, parameters first" {
    const input_locals = [_]u8{ 1, 1, 0x7F }; // one i32 local
    const source: Body.Input = .{
        .locals = &input_locals,
        .body = try Cursor.init(&.{0x0B}),
    };
    const valid = [_]Instr{.{ .local_get = 1 }};
    try expectBodyOwnedInput(&no_plan, .{ .emitted_function = 1, .parameter_count = 1 }, source, .{
        .locals = .keep,
        .mode = .{ .replace = &valid },
    }, &.{ 1, 1, 0x7F, 0x20, 0x01, 0x0B });

    const invalid = [_]Instr{.{ .local_get = 2 }};
    const m = try Module.parse(&header);
    const counts = try Counts.of(&m, .{});
    const body: Body = .{ .locals = .keep, .mode = .{ .replace = &invalid } };
    var d: Diagnostics = .{};
    try testing.expectError(
        error.IndexOutOfRange,
        body.encodedLen(&counts, &no_plan, .{ .emitted_function = 1, .parameter_count = 1 }, source, .{
            .diag = &d,
        }),
    );
    try testing.expectEqual(
        Diagnostics.Detail{ .out_of_range = .{ .space = .local, .value = 2, .limit = 2 } },
        d.detail,
    );
}

test "Body: appended and raw locals both count toward the bound" {
    const input_locals = [_]u8{ 1, 1, 0x7F };
    const source: Body.Input = .{
        .locals = &input_locals,
        .body = try Cursor.init(&.{0x0B}),
    };
    const appended = [_]LocalDecl{.{ .count = 1, .valtype = .{ .number_or_vector = .i32 } }};
    const get = [_]Instr{.{ .local_get = 1 }};
    try expectBodyOwnedInput(&no_plan, .{ .emitted_function = 2, .parameter_count = 0 }, source, .{
        .locals = .{ .append = &appended },
        .mode = .{ .replace = &get },
    }, &.{ 2, 1, 0x7F, 1, 0x7F, 0x20, 0x01, 0x0B });

    const raw_locals = [_]u8{ 1, 1, 0x7F };
    const get0 = [_]Instr{.{ .local_get = 0 }};
    try expectBodyOwned(&no_plan, .{ .emitted_function = 3, .parameter_count = 0 }, .{
        .locals = .{ .raw = &raw_locals },
        .mode = .{ .replace = &get0 },
    }, &.{ 1, 1, 0x7F, 0x20, 0x00, 0x0B });
}

test "Body: local bounds are skipped without an owner or a parameter count" {
    const get = [_]Instr{.{ .local_get = 9 }};
    const body: Body = .{ .locals = .{ .replace = no_locals }, .mode = .{ .replace = &get } };
    try expectBodyOwned(&no_plan, null, body, &.{ 0x00, 0x20, 0x09, 0x0B });
    try expectBodyOwned(
        &no_plan,
        .{ .emitted_function = 1, .parameter_count = null },
        body,
        &.{ 0x00, 0x20, 0x09, 0x0B },
    );
}

test "Body: raw instruction bytes are never local-checked" {
    const raw = [_]u8{ 0x20, 0x09, 0x20, 0x08 };
    const expected = [_]u8{ 0x00, 0x20, 0x09, 0x20, 0x08, 0x0B };
    const owner: Body.Owner = .{ .emitted_function = 1, .parameter_count = 0 };

    try expectBodyOwned(&no_plan, owner, .{
        .locals = .{ .replace = no_locals },
        .mode = .{ .raw = &raw },
    }, &expected);

    const instrs = [_]Instr{.{ .raw = &raw }};
    try expectBodyOwned(&no_plan, owner, .{
        .locals = .{ .replace = no_locals },
        .mode = .{ .replace = &instrs },
    }, &expected);
}

test "Body: a malformed raw locals vector is a code error" {
    const raw = [_]u8{1}; // one run, but no run bytes
    const m = try Module.parse(&header);
    const counts = try Counts.of(&m, .{});
    const body: Body = .{
        .locals = .{ .raw = &raw },
        .mode = .{ .replace = no_instructions },
    };
    var d: Diagnostics = .{};
    try testing.expectError(error.Truncated, body.encodedLen(&counts, &no_plan, .{
        .emitted_function = 4,
        .parameter_count = 0,
    }, null, .{ .diag = &d }));
    try testing.expectEqual(@as(?anyerror, error.Truncated), d.err);
    try testing.expectEqual(@as(?spec.SectionId, .code), d.section);
    try testing.expectEqual(@as(?u32, 4), d.function);
    try testing.expectEqualDeep(Diagnostics.Detail.none, d.detail);
}
