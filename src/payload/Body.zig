//! The assembler side of a function body: a locals policy, a mode, and the instructions wsplice can
//! build.
//!
//! Each `Instr` variant is one instruction and carries the operands that would otherwise be left
//! in its bytes. Adding a variant is the whole extension procedure: `encodeInstr` switches over the
//! union exhaustively, so a new variant does not compile until it is handled, and nothing else has
//! to change. `Instr.raw` is the escape hatch for everything not modeled yet.
//!
//! This is the opposite trade from `operators.zig`. That reader reports every instruction
//! as an `Opcode` and a byte span and leaves the operands to the caller; here there is no span to
//! echo, because an operand is a value, so the bytes are produced rather than copied. Rule of
//! thumb: `operators.Opcode` is what a reader found, `Body.Instr` is what a writer will produce.
//!
//! The expression's terminating `end` is written by `encodeWith`, so no mode and no `Instr` is one.
//! Nothing checks that the instructions type-check or leave the stack right: that is validation,
//! and `wasm-validate` does it.
//!
//! The body owns none of its bytes: the input body, the locals, the instructions, and everything
//! they borrow (raw spans, the rewriter's context) must stay alive until `emit` returns.
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
    /// `call f`: calls `f`, and whatever it returns becomes the values of the call.
    call: index.Function,
    /// `call_indirect (type t) (table tbl)`: the arguments, then the table element index, are
    /// pushed before it, so the element index is the last value on the stack.
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
    /// `local.get local`: a function's local space is its parameters first, then the locals this
    /// body declares; parameters are in the function's type, not in the body. The assembler does
    /// not read the type: it checks the index only when a `Body.Owner` supplies the parameter
    /// count. `Instr.raw` bytes are never checked.
    local_get: u32,
    /// `global.get global`
    global_get: index.Global,
    /// Bytes emitted as they are: the escape hatch, and the only way to write an instruction
    /// without a variant above. They are not inspected, so nothing in them can be relabeled or
    /// remapped; `block`/`end` balance is the caller's responsibility, and the bytes must not
    /// include the body's terminating `end`, which `encodeWith` adds.
    raw: []const u8,
};

/// One run of locals: how many, and the type they all have, exactly like the binary vector.
pub const LocalDecl = struct {
    count: u32,
    valtype: spec.ValueType,
};

/// What the body declares for its locals. Parameters are in the function's type, not here. The
/// input body's vector is raw bytes (`code.Entry.locals`), so keeping it is a copy, not a decode.
pub const Locals = union(enum) {
    /// Keep the input body's vector as it is. A body with no input body has nothing to keep, so
    /// this is `error.NoInputBody` there.
    keep,
    /// Replace it with exactly these runs: one run per declaration, no merging.
    replace: []const LocalDecl,
    /// Keep the input body's runs, then these. With no input body, these alone are the vector.
    append: []const LocalDecl,
    /// These bytes, verbatim: the whole vector, run count included.
    raw: []const u8,
};

/// What the body does with its instructions. The terminating `end` belongs to none of these:
/// `encodeWith` writes it after them.
pub const Mode = union(enum) {
    /// Write these instructions.
    replace: []const Instr,
    /// Run a caller's code over the input body's instructions.
    rewrite: Rewriter,
    /// Instruction bytes without the final `end`, written as they are. They are not parsed, so
    /// opcodes the reader refuses can still be copied, and their indices are never remapped; they
    /// must be self-contained and depth-neutral, as `Instr.raw` must be.
    raw: []const u8,
};

/// The body this one replaces. `keep` copies instruction spans out of `body.bytes`, because `Op`
/// offsets are absolute into the module; `locals` and `body` are what `.keep` locals and `.rewrite`
/// are relative to.
pub const Input = struct {
    locals: []const u8,
    body: Cursor,
};

/// The function a body belongs to: its final index in the emitted module, and its parameter count.
/// `parameter_count` null means the count is not known, so local indices are not checked.
pub const Owner = struct {
    emitted_function: u32,
    parameter_count: ?u32,
};

/// Type-erased rewriting. The user type has
///
///     pub fn rewrite(self: *const T, body: operators.BodyIter, out: *Out) EncodeError!void
///
/// and `from(&value)` stores one context pointer and one function pointer. The context must outlive
/// `emit`, and the callback must be deterministic: a frame is measured and then written, and emit
/// runs both twice.
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

/// What each body's instructions are written through. It is made fresh for each body per pass, so
/// validation can land in `write`/`keep` without changing a callback. A rewriter only needs
/// `write`/`keep`; the other fields are the encoder's context.
pub const Out = struct {
    writer: *Io.Writer,
    /// The input module's bytes: `Op` offsets are absolute, so `keep` slices these.
    bytes: []const u8,
    counts: *const Counts,
    /// The plan's added imports and types; indices resolve against it.
    plan: *const Plan,
    /// The owning function's emitted index, for diagnostics; null when the body has no owner.
    emitted_function: ?u32,
    /// One past the last valid local index; null when the bound is unknown.
    local_limit: ?u32,
    options: Options,

    /// Writes instructions, resolving the indices they name.
    pub fn write(self: *Out, instructions: []const Instr) EncodeError!void {
        for (instructions) |instruction| try encodeInstr(self, instruction);
    }

    /// Writes `op` exactly as it is in the input body: the same bytes, the same indices, padded
    /// LEBs included.
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

/// Writes the code entry's body of a function that has no input body: the locals vector, the
/// instructions, and the final `end`. Emit runs this twice, so it must be pure. A body on its own
/// has no plan imports: `.added_import` and the added-import part of `.input` resolve as if the
/// plan added none. It also has no owner, so local indices are not checked. `SetBodies` passes the
/// plan's added imports and the owning function to `encodeWith`.
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

/// `encode` with counts the caller already has, and with the input body it replaces. `input` null
/// means there is no input body: `.keep` locals is `NoInputBody`, `.append` writes only its own
/// declarations, and `.rewrite` gets an empty instruction stream. `plan` carries the plan's added
/// imports, types and functions, which is what makes an `.input`, `.appended` or `.added_import`
/// index resolve. `owner` supplies the parameter count for local-index bounds; null skips the
/// check.
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

/// One past the last valid local index, or null when the count is unknown or the sum cannot fit
/// in a u32 (in which case no u32 local index can exceed it).
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
        index.Layout.of(out.counts, .function, &out.plan.added_imports),
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
        index.Layout.of(out.counts, .table, &out.plan.added_imports),
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
        index.Layout.of(out.counts, .global, &out.plan.added_imports),
    ));
}

/// The number an index resolves to, or the out-of-range diagnostic for the one case that fails.
/// Only `.input` is checked: an `.appended` or `.added_import` ordinal is the plan's to hand out,
/// and `wasm-validate` is the gate for it.
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

/// Checks a local index against the precomputed bound. A body with no owner, or one whose
/// parameter count is unknown, has no bound and leaves it unchecked.
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

/// The instruction stream of a body with nothing to rewrite: just the terminator, so the iterator
/// can end at it as it does on any other body.
const empty_expression = [_]u8{0x0B};
const empty_body: Cursor = .{ .bytes = &empty_expression, .pos = 0, .end = 1 };

/// Writes the locals vector the body asks for and returns how many locals it declares. `input` is
/// the input body's vector and expression, relative to which `.keep` and `.append` work; null means
/// there is no input body.
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

/// The number of locals a `vec(locals)` declares, parsing and validating it. Used for the raw and
/// kept vectors, which are written verbatim and otherwise would not be decoded.
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

/// The input's runs, then the new ones. Only the run count is rewritten: the input's run bytes are
/// copied, so a padded LEB survives and equal runs on both sides stay separate.
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
