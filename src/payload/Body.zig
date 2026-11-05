//! The assembler side of a function body: locals policy, mode, and instructions wsplice can write.
//!
//! Each `Instr` carries its operands, so the bytes are produced rather than echoed; `Instr.raw` is
//! the escape hatch. `operators.zig` is the reader: `Opcode` reports what was found, `Instr` what
//! will be written. `encodeWith` writes the terminating `end`; validation is external.
//!
//! The body owns none of its bytes: inputs, instructions, and rewriter contexts must outlive
//! `emit`.
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Cursor = @import("../Cursor.zig");
const Module = @import("../Module.zig");
const Options = @import("../Options.zig");
const Diagnostics = @import("../Diagnostics.zig");
const errors = @import("../errors.zig");
const EncodeError = errors.EncodeError;
const fromCursor = errors.fromCursor;
const spec = @import("../spec.zig");
const Counts = @import("Counts.zig");
const valtype = @import("valtype.zig");
const index = @import("../index.zig");
const Plan = @import("../Plan.zig");
const operators = @import("operators.zig");

/// One instruction wsplice can assemble.
pub const Instr = union(enum) {
    /// `call f`.
    call: index.Function,
    /// `call_indirect type table`; the table element index is the last operand.
    call_indirect: struct {
        type: index.Type,
        table: index.Table,
    },
    /// `i32.const value`
    i32_const: i32,
    /// `i64.const value`
    i64_const: i64,
    /// `f32.const value`, written as its IEEE 754 bits in little-endian order.
    f32_const: f32,
    /// `f64.const value`, written as its IEEE 754 bits in little-endian order.
    f64_const: f64,
    /// `local.get local`: parameters come first, then declared locals. Checked only when `Owner`
    /// supplies the parameter count; raw bytes are never checked.
    local_get: u32,
    /// `global.get global`
    global_get: index.Global,
    /// Bytes written as-is, never parsed or remapped. `block`/`end` balance is the caller's, and
    /// these bytes must not include the body's final `end`.
    raw: []const u8,
};

/// One run of locals: how many, and the type they all have, exactly like the binary vector.
pub const LocalDecl = struct {
    count: u32,
    valtype: spec.ValueType,
};

/// The body's declared locals; parameters live in the function type. The input's vector is raw
/// bytes (`code.Entry.locals`), so keeping it is a copy, not a decode.
pub const Locals = union(enum) {
    /// Keep the input body's vector. A body with no input body has nothing to keep
    /// (`error.NoInputBody`).
    keep,
    /// Replace it with exactly these runs: one run per declaration, no merging.
    replace: []const LocalDecl,
    /// Keep the input body's runs, then these. With no input body, these alone are the vector.
    append: []const LocalDecl,
    /// These bytes, verbatim: the whole vector, run count included.
    raw: []const u8,
};

/// What the body does with its instructions. `encodeWith` writes the terminating `end` after them.
pub const Mode = union(enum) {
    /// Write these instructions.
    replace: []const Instr,
    /// Run a caller's code over the input body's instructions.
    rewrite: Rewriter,
    /// Instruction bytes without the final `end`. Not parsed, so opcodes the reader refuses can be
    /// copied, and indices are never remapped; must be self-contained and depth-neutral.
    raw: []const u8,
};

/// The body this one replaces. `keep` copies instruction spans from `body.bytes` because `Op`
/// offsets are absolute; `locals` and `body` are what `.keep` locals and `.rewrite` work from.
pub const Input = struct {
    locals: []const u8,
    body: Cursor,
};

/// The function a body belongs to: its final index and its parameter count. A null count leaves
/// local indices unchecked.
pub const Owner = struct {
    emitted_function: u32,
    parameter_count: ?u32,
};

/// Type-erased rewriting. The user type has
///
///     pub fn rewrite(self: *const T, body: operators.BodyIter, out: *Out) EncodeError!void
///
/// `from(&value)` stores a context pointer and a function pointer. The context must outlive `emit`
/// at a stable address (a loop-local is overwritten before emit), and the callback must be
/// deterministic because emit runs it twice.
pub const Rewriter = struct {
    context: *const anyopaque,
    function: *const fn (
        context: *const anyopaque,
        body: operators.BodyIter,
        out: *Out,
    ) EncodeError!void,

    /// Erases the type of `context`, which is `*const T`, to the stored function pointer.
    pub fn from(context: anytype) Rewriter {
        const info = @typeInfo(@TypeOf(context));
        if (info != .pointer) @compileError("Rewriter.from takes a pointer: pass &.value");
        const Context = info.pointer.child;
        return .{
            .context = @ptrCast(context),
            .function = struct {
                fn shim(
                    erased: *const anyopaque,
                    body: operators.BodyIter,
                    out: *Out,
                ) EncodeError!void {
                    const self: *const Context = @ptrCast(@alignCast(erased));
                    return self.rewrite(body, out);
                }
            }.shim,
        };
    }

    fn rewrite(self: Rewriter, body: operators.BodyIter, out: *Out) EncodeError!void {
        return self.function(self.context, body, out);
    }
};

/// What each body's instructions are written through, made fresh per body per pass. A rewriter only
/// needs `write`/`keep`; the other fields are encoder context.
pub const Out = struct {
    writer: *Io.Writer,
    /// The input module's bytes: `Op` offsets are absolute, so `keep` slices these.
    bytes: []const u8,
    counts: *const Counts,
    /// The plan's added imports and types; indices resolve against it.
    plan: *const Plan,
    /// The owning function's final index, for diagnostics; null when the body has no owner.
    emitted_function: ?u32,
    /// One past the last valid local index; null when the bound is unknown.
    local_limit: ?u32,
    options: Options,

    /// Writes instructions, resolving the indices they name.
    pub fn write(self: *Out, instructions: []const Instr) EncodeError!void {
        for (instructions) |instruction| try encodeInstr(self, instruction);
    }

    /// Writes `op` exactly as it is in the input: same bytes, same indices, padded LEBs included.
    pub fn keep(self: *Out, op: operators.Op) EncodeError!void {
        assert(op.at <= op.end);
        assert(op.end <= self.bytes.len);
        try self.writer.writeAll(self.bytes[op.at..op.end]);
    }
};

/// How to produce one body's frame: the locals vector, then the instructions, then the final `end`.
locals: Locals = .keep,
mode: Mode,

const Body = @This();

/// Writes a body with no input body: locals, instructions, and the final `end`. Emit runs this
/// twice, so it must be pure. With no plan or owner, added imports and local bounds are absent;
/// `SetBodies` passes both to `encodeWith`.
pub fn encode(
    self: *const Body,
    module: *const Module,
    writer: *Io.Writer,
    options: Options,
) EncodeError!void {
    const counts = try Counts.of(module, options);
    const plan: Plan = .{}; // a body on its own has no plan imports or additions to resolve
    try self.encodeWith(&counts, &plan, null, null, writer, options);
}

/// `encode` with counts already in hand, plus the input body this one replaces. `input` null means
/// no input body: `.keep` locals is `NoInputBody`, `.append` writes only its own declarations, and
/// `.rewrite` sees an empty instruction stream. `plan` supplies the added imports, types and
/// functions symbolic indices resolve against. `owner` supplies the local bound; null skips it.
pub fn encodeWith(
    self: *const Body,
    counts: *const Counts,
    plan: *const Plan,
    owner: ?Owner,
    input: ?Input,
    writer: *Io.Writer,
    options: Options,
) EncodeError!void {
    const declared_locals = try encodeLocals(writer, self.locals, input, owner, options);
    var out: Out = .{
        .writer = writer,
        .bytes = if (input) |source| source.body.bytes else &.{},
        .counts = counts,
        .plan = plan,
        .emitted_function = if (owner) |function| function.emitted_function else null,
        .local_limit = localLimit(owner, declared_locals),
        .options = options,
    };
    switch (self.mode) {
        .replace => |instructions| try out.write(instructions),
        .rewrite => |rewriter| {
            const body: operators.BodyIter = if (input) |source|
                operators.BodyIter.init(source.body)
            else
                operators.BodyIter.init(empty_body);
            rewriter.rewrite(body, &out) catch |err| return Diagnostics.fail(options.diag, err, .{
                .section = .code,
                .function = out.emitted_function,
            });
        },
        .raw => |bytes| try writer.writeAll(bytes),
    }
    try writer.writeByte(@backingInt(spec.BaseOpcode.end)); // the expression's terminator
}

/// One past the last valid local index, or null when the count is unknown or the sum exceeds u32.
fn localLimit(owner: ?Owner, declared_locals: u64) ?u32 {
    const function = owner orelse return null;
    const parameters = function.parameter_count orelse return null;
    const limit = @as(u64, parameters) + declared_locals;
    return std.math.cast(u32, limit);
}

/// The body's length in bytes: what a code entry's size prefix counts.
pub fn encodedLen(
    self: *const Body,
    counts: *const Counts,
    plan: *const Plan,
    owner: ?Owner,
    input: ?Input,
    options: Options,
) EncodeError!u32 {
    var counter = Io.Writer.Discarding.init(&.{});
    try self.encodeWith(counts, plan, owner, input, &counter.writer, options);
    const len = counter.fullCount();
    return std.math.cast(u32, len) orelse error.Overflow;
}

fn encodeInstr(out: *Out, instruction: Instr) EncodeError!void {
    switch (instruction) {
        .call => |function| try encodeCall(out, function),
        .call_indirect => |call| try encodeCallIndirect(out, call.type, call.table),
        .i32_const => |value| try encodeI32Const(out, value),
        .i64_const => |value| try encodeI64Const(out, value),
        .f32_const => |value| try encodeF32Const(out, value),
        .f64_const => |value| try encodeF64Const(out, value),
        .local_get => |local| try encodeLocalGet(out, local),
        .global_get => |global| try encodeGlobalGet(out, global),
        .raw => |bytes| try out.writer.writeAll(bytes),
    }
}

fn encodeCall(out: *Out, function: index.Function) EncodeError!void {
    try out.writer.writeByte(@backingInt(spec.BaseOpcode.call));
    try out.writer.writeLeb128(try checkedIndex(
        out,
        function,
        .function,
        index.Layout.of(.function, out.counts, &out.plan.added_imports),
    ));
}

fn encodeCallIndirect(out: *Out, call_type: index.Type, table: index.Table) EncodeError!void {
    try out.writer.writeByte(@backingInt(spec.BaseOpcode.call_indirect));
    try out.writer.writeLeb128(try checkedIndex(
        out,
        call_type,
        .type,
        index.Layout.types(out.counts),
    ));
    try out.writer.writeLeb128(try checkedIndex(
        out,
        table,
        .table,
        index.Layout.of(.table, out.counts, &out.plan.added_imports),
    ));
}

fn encodeI32Const(out: *Out, value: i32) EncodeError!void {
    try out.writer.writeByte(@backingInt(spec.BaseOpcode.i32_const));
    try out.writer.writeLeb128(value); // signed LEB, as the binary format wants it
}

fn encodeI64Const(out: *Out, value: i64) EncodeError!void {
    try out.writer.writeByte(@backingInt(spec.BaseOpcode.i64_const));
    try out.writer.writeLeb128(value);
}

fn encodeF32Const(out: *Out, value: f32) EncodeError!void {
    try out.writer.writeByte(@backingInt(spec.BaseOpcode.f32_const));
    try out.writer.writeInt(u32, @bitCast(value), .little);
}

fn encodeF64Const(out: *Out, value: f64) EncodeError!void {
    try out.writer.writeByte(@backingInt(spec.BaseOpcode.f64_const));
    try out.writer.writeInt(u64, @bitCast(value), .little);
}

fn encodeLocalGet(out: *Out, local: u32) EncodeError!void {
    try checkLocal(out, local);
    try out.writer.writeByte(@backingInt(spec.BaseOpcode.local_get));
    try out.writer.writeLeb128(local);
}

fn encodeGlobalGet(out: *Out, global: index.Global) EncodeError!void {
    try out.writer.writeByte(@backingInt(spec.BaseOpcode.global_get));
    try out.writer.writeLeb128(try checkedIndex(
        out,
        global,
        .global,
        index.Layout.of(.global, out.counts, &out.plan.added_imports),
    ));
}

/// The number an index resolves to, or the out-of-range diagnostic. Only `.input` is checked;
/// plan ordinals are the plan's to hand out.
fn checkedIndex(
    out: *Out,
    reference: anytype,
    space: spec.IndexSpace,
    layout: index.Layout,
) EncodeError!u32 {
    switch (reference) {
        .input => |used| {
            if (used >= layout.input_total) {
                return Diagnostics.fail(out.options.diag, error.IndexOutOfRange, .{
                    .section = .code,
                    .function = out.emitted_function,
                    .detail = .{
                        .out_of_range = .{
                            .space = space,
                            .value = used,
                            .limit = layout.input_total,
                        },
                    },
                });
            }
        },
        .appended, .added_import => {},
    }
    return reference.resolve(layout);
}

/// Checks a local index against the precomputed bound; no bound means no check.
fn checkLocal(out: *Out, local: u32) EncodeError!void {
    const limit = out.local_limit orelse return;
    if (local >= limit) {
        return Diagnostics.fail(out.options.diag, error.IndexOutOfRange, .{
            .section = .code,
            .function = out.emitted_function,
            .detail = .{ .out_of_range = .{
                .space = .local,
                .value = local,
                .limit = limit,
            } },
        });
    }
}

/// The instruction stream of a body with nothing to rewrite: just the terminator.
const empty_expression = [_]u8{0x0B};
const empty_body: Cursor = .{ .bytes = &empty_expression, .pos = 0, .end = 1 };

/// Writes the locals vector the body asks for and returns how many locals it declares. `input`
/// supplies the vector `.keep`/`.append` work from; null means there is no input body.
fn encodeLocals(
    writer: *Io.Writer,
    locals: Locals,
    input: ?Input,
    owner: ?Owner,
    options: Options,
) EncodeError!u64 {
    switch (locals) {
        .keep => {
            const source = input orelse return Diagnostics.fail(options.diag, error.NoInputBody, .{
                .section = .code,
                .function = if (owner) |function| function.emitted_function else null,
            });
            try writer.writeAll(source.locals);
            return checkedLocalsCount(source.locals, owner, options);
        },
        .replace => |declarations| {
            try writeDeclarations(writer, declarations);
            return declaredLocalsCount(declarations);
        },
        .append => |declarations| {
            try appendDeclarations(writer, input, declarations);
            const new_count = try declaredLocalsCount(declarations);
            if (input) |source| {
                const old_count = try checkedLocalsCount(source.locals, owner, options);
                return std.math.add(u64, old_count, new_count) catch return error.Overflow;
            }
            return new_count;
        },
        .raw => |bytes| {
            try writer.writeAll(bytes);
            return checkedLocalsCount(bytes, owner, options);
        },
    }
}

fn declaredLocalsCount(declarations: []const LocalDecl) EncodeError!u64 {
    var total: u64 = 0;
    for (declarations) |declaration| {
        total = std.math.add(u64, total, declaration.count) catch return error.Overflow;
    }
    return total;
}

/// The number of locals a `vec(locals)` declares, parsing and validating it. Used for raw and kept
/// vectors, which are written verbatim and otherwise would not be decoded.
fn localsCount(bytes: []const u8) EncodeError!u64 {
    var cursor = Cursor.init(bytes) catch return error.Overflow;
    const runs = cursor.readUleb(u32) catch |err| return fromCursor(err);
    var total: u64 = 0;
    var i: u32 = 0;
    while (i < runs) : (i += 1) {
        const count = cursor.readUleb(u32) catch |err| return fromCursor(err);
        _ = valtype.read(&cursor) catch |err| return err;
        total = std.math.add(u64, total, count) catch return error.Overflow;
    }
    if (!cursor.atEnd()) return error.TrailingBytes;
    return total;
}

/// `localsCount`, reporting a malformed vector as a code-section failure for this function.
fn checkedLocalsCount(bytes: []const u8, owner: ?Owner, options: Options) EncodeError!u64 {
    return localsCount(bytes) catch |err| return Diagnostics.fail(options.diag, err, .{
        .section = .code,
        .function = if (owner) |function| function.emitted_function else null,
    });
}

/// `vec(locals)`: the number of runs, then each run's count and type. Each declaration is one run.
fn writeDeclarations(writer: *Io.Writer, declarations: []const LocalDecl) EncodeError!void {
    try writer.writeLeb128(std.math.cast(u32, declarations.len) orelse return error.Overflow);
    try writeDeclarationBytes(writer, declarations);
}

/// The input's runs, then the new ones. Only the run count is rewritten; the input's run bytes are
/// copied, so padded LEBs survive and equal runs on both sides stay separate.
fn appendDeclarations(
    writer: *Io.Writer,
    input: ?Input,
    declarations: []const LocalDecl,
) EncodeError!void {
    var old_runs: u32 = 0;
    var old_bytes: []const u8 = &.{};
    if (input) |source| {
        var cursor = Cursor.init(source.locals) catch return error.Overflow;
        old_runs = cursor.readUleb(u32) catch |err| return fromCursor(err);
        old_bytes = cursor.bytes[cursor.pos..cursor.end];
    }
    const new_runs = std.math.cast(u32, declarations.len) orelse return error.Overflow;
    const runs = std.math.add(u32, old_runs, new_runs) catch return error.Overflow;
    try writer.writeLeb128(runs);
    try writer.writeAll(old_bytes);
    try writeDeclarationBytes(writer, declarations);
}

fn writeDeclarationBytes(writer: *Io.Writer, declarations: []const LocalDecl) EncodeError!void {
    for (declarations) |declaration| {
        try writer.writeLeb128(declaration.count);
        try valtype.write(declaration.valtype, writer);
    }
}
