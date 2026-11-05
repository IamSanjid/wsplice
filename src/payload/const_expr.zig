//! Constant expressions: instructions terminated by `end`, with the terminator excluded from the
//! stored form.
//!
//! Reading measures where an expression ends so unchanged initializers copy as bytes; writing
//! produces typed values. `Expr` omits `global.get`/`ref.func` because their indices need the
//! resolver, but `take` still recognizes them in existing modules.
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Cursor = @import("../Cursor.zig");
const spec = @import("../spec.zig");
const errors = @import("../errors.zig");
const EncodeError = errors.EncodeError;
const PayloadError = errors.PayloadError;
const fromCursor = errors.fromCursor;

/// `ref.null` and `ref.func` are absent from `std.wasm.Opcode`; handle them before the switch.
const opcode_ref_null: u8 = @backingInt(spec.ExtraOpcode.ref_null);
const opcode_ref_func: u8 = @backingInt(spec.ExtraOpcode.ref_func);

/// The only SIMD instruction a constant expression may contain.
const simd_v128_const: u32 = @backingInt(spec.SimdOpcode.v128_const);

/// Immediate widths in bytes: five hold any `u32`, `s32` or `s33`; ten hold any `s64`.
const immediate_leb32_max = 5;
const immediate_leb64_max = 10;

/// Immediates that are not LEBs: a float's bit pattern, and a whole vector.
const f32_bytes = 4;
const f64_bytes = 8;
const v128_bytes = 16;

/// A constant expression to write. `f32`/`f64` are bit patterns so NaN payloads survive.
///
/// `global.get` and `ref.func` are deliberately absent: their immediates are indices that may need
/// resolving against the patch. `take` still recognizes them in existing modules.
pub const Expr = union(enum) {
    i32: i32,
    i64: i64,
    f32: u32,
    f64: u64,

    /// `ref.null ht` for an abstract heap type, one byte: `funcref`, `externref`, and the rest. A
    /// concrete type index needs the prefixed form and is not expressible here.
    ref_null: spec.AbstractHeapType,

    /// Instructions only, no `end`, written verbatim and never relocated. This is not scanned for a
    /// terminator: in `{ 0x41, 0x0B }` the `0x0B` is `i32.const`'s immediate.
    raw: []const u8,

    /// Writes the instructions, then exactly one terminating `end`. This runs at emit time because
    /// the LEB width depends on the final value.
    pub fn encode(self: *const Expr, writer: *Io.Writer) EncodeError!void {
        switch (self.*) {
            .i32 => |value| {
                try writer.writeByte(@backingInt(spec.BaseOpcode.i32_const));
                try writer.writeLeb128(value);
            },
            .i64 => |value| {
                try writer.writeByte(@backingInt(spec.BaseOpcode.i64_const));
                try writer.writeLeb128(value);
            },
            .f32 => |bits| {
                var bytes: [f32_bytes]u8 = undefined;
                std.mem.writeInt(u32, &bytes, bits, .little);
                try writer.writeByte(@backingInt(spec.BaseOpcode.f32_const));
                try writer.writeAll(&bytes);
            },
            .f64 => |bits| {
                var bytes: [f64_bytes]u8 = undefined;
                std.mem.writeInt(u64, &bytes, bits, .little);
                try writer.writeByte(@backingInt(spec.BaseOpcode.f64_const));
                try writer.writeAll(&bytes);
            },
            .ref_null => |heap_type| {
                try writer.writeByte(opcode_ref_null);
                try writer.writeByte(@backingInt(heap_type)); // the heap type is the byte
            },
            .raw => |instructions| try writer.writeAll(instructions),
        }
        // Exactly one, and last: the terminator the instructions were stripped of.
        try writer.writeByte(@backingInt(spec.BaseOpcode.end));
    }
};

/// Takes one constant expression, leaving `cursor` past its `end`, and returns the instructions
/// without that `end`. `.{ .raw = take(...) }` therefore reproduces an initializer exactly.
///
/// Nothing is decoded: each immediate is skipped by its widest encoding. Anything whose width is
/// unknown is `UnsupportedFeature`; an over-long LEB is `MalformedLeb`. The scan is bounded by the
/// remaining bytes because every instruction consumes at least one.
pub fn take(cursor: *Cursor) PayloadError![]const u8 {
    const start = cursor.pos;
    errdefer cursor.pos = start; // a failed call leaves the cursor where it was

    // Every instruction consumes at least one byte, so a complete expression cannot take more
    // steps than there are bytes left.
    const steps_max = cursor.remaining();
    var steps: u32 = 0;

    while (true) {
        const byte = cursor.readByte() catch |err| return fromCursor(err);
        steps += 1;
        assert(steps <= steps_max); // one byte per step: more steps than bytes is impossible

        if (byte == opcode_ref_null or byte == opcode_ref_func) {
            // `ref.null` carries a heaptype, `ref.func` a function index: one LEB of at most five
            // bytes. The heaptype may be a negative s33 (abstract) or a concrete index; both skip
            // the same way.
            try skipImmediate(cursor, immediate_leb32_max);
            continue;
        }

        const opcode = std.enums.fromInt(spec.BaseOpcode, byte) orelse
            return error.UnsupportedFeature;
        switch (opcode) {
            .end => {
                const instructions = cursor.bytes[start .. cursor.pos - 1]; // all but the `end`
                assert(instructions.len + 1 == @as(usize, cursor.pos - start));
                return instructions;
            },
            .i32_const => try skipImmediate(cursor, immediate_leb32_max),
            .i64_const => try skipImmediate(cursor, immediate_leb64_max),
            .f32_const => try skipBytes(cursor, f32_bytes),
            .f64_const => try skipBytes(cursor, f64_bytes),
            .global_get => try skipImmediate(cursor, immediate_leb32_max),
            .simd_prefix => {
                const sub_opcode = cursor.readUleb(u32) catch |err| return fromCursor(err);
                if (sub_opcode != simd_v128_const) return error.UnsupportedFeature;
                try skipBytes(cursor, v128_bytes);
            },
            // The extended-const arithmetic: an operand on the stack, no bytes in the stream.
            .i32_add, .i32_sub, .i32_mul, .i64_add, .i64_sub, .i64_mul => {},
            else => return error.UnsupportedFeature,
        }
    }
}

/// Skips one LEB immediate of at most `max_bytes`; only its width matters.
fn skipImmediate(cursor: *Cursor, comptime max_bytes: u8) PayloadError!void {
    cursor.skipLeb(max_bytes) catch |err| return fromCursor(err);
}

/// Skips bytes that carry no structure, such as a float's bit pattern or a vector.
fn skipBytes(cursor: *Cursor, n: u32) PayloadError!void {
    cursor.skip(n) catch |err| return fromCursor(err);
}

const testing = std.testing;

/// One constant expression per case, `end` included; `take` must return all but that last byte.
const valid_expressions = if (@import("builtin").is_test) [_][]const u8{
    // `end` alone: no instructions at all, which validation rejects, but its bytes parse.
    &.{0x0B},
    // `i32.const`: zero, a negative, a value needing two bytes, a padded LEB, and both 5-byte ends.
    &.{ 0x41, 0x00, 0x0B },
    &.{ 0x41, 0x7F, 0x0B },
    &.{ 0x41, 0xFF, 0x00, 0x0B },
    &.{ 0x41, 0x85, 0x00, 0x0B },
    &.{ 0x41, 0x80, 0x80, 0x80, 0x80, 0x78, 0x0B },
    &.{ 0x41, 0xFF, 0xFF, 0xFF, 0xFF, 0x07, 0x0B },
    // `i64.const`: ten bytes is its widest immediate.
    &.{ 0x42, 0x7F, 0x0B },
    &.{ 0x42, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0x0B },
    // `f32.const` and `f64.const`: four and eight bytes, one of them a NaN.
    &.{ 0x43, 0x01, 0x00, 0xC0, 0x7F, 0x0B },
    &.{ 0x44, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x7F, 0x0B },
    // `v128.const`: the 0xFD prefix, sub-opcode 0x0C, sixteen bytes.
    &.{ 0xFD, 0x0C, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0x0B },
    // `global.get` and `ref.func`: one u32 index each.
    &.{ 0x23, 0xAC, 0x02, 0x0B },
    &.{ 0xD2, 0x07, 0x0B },
    // `ref.null`: the abstract shorthand, then a concrete type index as a positive s33.
    &.{ 0xD0, 0x70, 0x0B },
    &.{ 0xD0, 0x00, 0x0B },
    // The six extended-const arithmetic opcodes, each one byte with no immediate.
    &.{ 0x6A, 0x6B, 0x6C, 0x7C, 0x7D, 0x7E, 0x0B },
    // A sequence that mixes widths, the way a real initializer does.
    &.{ 0x41, 0x01, 0x41, 0x02, 0x6A, 0x0B },
} else @compileError("Should be used only in tests.");

test "take: returns the instructions, `end` excluded, and consumes that `end`" {
    for (valid_expressions) |bytes| {
        try testing.expectEqual(0x0B, bytes[bytes.len - 1]); // every case ends with `end`

        var cursor = try Cursor.init(bytes);
        const instructions = try take(&cursor);

        try testing.expectEqualSlices(u8, bytes[0 .. bytes.len - 1], instructions);
        try testing.expectEqual(bytes.len, cursor.pos); // one byte past the last instruction
        try testing.expect(cursor.atEnd());
    }
}

test "take: every strict prefix is truncated, and moves nothing" {
    for (valid_expressions) |bytes| {
        // A strict prefix has no terminating `end`, so the scan can only run out of bytes.
        for (0..bytes.len) |len| {
            var cursor = try Cursor.init(bytes[0..len]);
            try testing.expectError(error.Truncated, take(&cursor));
            try testing.expectEqual(0, cursor.pos);
        }
    }
}

test "take: refuses what a constant expression may not contain" {
    for ([_][]const u8{
        &.{ 0x00, 0x0B }, // unreachable
        &.{ 0x20, 0x00, 0x0B }, // local.get: fine in a body, not here
        &.{ 0x45, 0x0B }, // i32.eqz
        &.{ 0xFB, 0x0B }, // the GC prefix
        &.{ 0xFC, 0x00, 0x0B }, // the misc prefix
        &.{ 0xFD, 0x00, 0x0B }, // v128.load: a SIMD instruction that is not v128.const
        &.{ 0xFD, 0xFF, 0x00, 0x0B }, // a padded sub-opcode that is not v128.const
    }) |bytes| {
        var cursor = try Cursor.init(bytes);
        try testing.expectError(error.UnsupportedFeature, take(&cursor));
        try testing.expectEqual(0, cursor.pos);
    }
}

test "take: an over-long LEB is malformed, not truncated" {
    // Six bytes cannot be a u32 (or an s33), and eleven cannot be an s64.
    const i32_six = [_]u8{ 0x41, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00, 0x0B };
    const i64_eleven = [_]u8{
        0x42, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00, 0x0B,
    };
    const heaptype_six = [_]u8{ 0xD0, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00, 0x0B };
    for ([_][]const u8{ &i32_six, &i64_eleven, &heaptype_six }) |bytes| {
        var cursor = try Cursor.init(bytes);
        try testing.expectError(error.MalformedLeb, take(&cursor));
        try testing.expectEqual(0, cursor.pos);
    }
}

test "take: positions are absolute, and the window end is respected" {
    const buffer = [_]u8{ 0xAA, 0x41, 0x01, 0x0B, 0xEE };
    var cursor = try Cursor.init(&buffer);
    try cursor.skip(1);

    const instructions = try take(&cursor);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x01 }, instructions);
    try testing.expectEqual(4, cursor.pos);
    try testing.expectEqual(0xEE, try cursor.readByte()); // the byte after the expression is next

    // The `end` is in the buffer but outside this window, so the expression cannot be measured.
    var whole = try Cursor.init(&buffer);
    try whole.skip(1);
    var window = try whole.sub(2);
    try testing.expectError(error.Truncated, take(&window));
    try testing.expectEqual(1, window.pos); // restored to the window's start, not to zero

    // A window that ends exactly after the `end` is enough to measure the expression.
    var exact_whole = try Cursor.init(&buffer);
    try exact_whole.skip(1);
    var exact = try exact_whole.sub(3); // `0x41 0x01 0x0B`
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x01 }, try take(&exact));
    try testing.expectEqual(4, exact.pos);
}

test "encode: integers are signed LEBs, and one `end` follows" {
    const cases = [_]struct { expr: Expr, bytes: []const u8 }{
        .{ .expr = .{ .i32 = 0 }, .bytes = &.{ 0x41, 0x00, 0x0B } },
        .{ .expr = .{ .i32 = -1 }, .bytes = &.{ 0x41, 0x7F, 0x0B } },
        .{ .expr = .{ .i32 = 127 }, .bytes = &.{ 0x41, 0xFF, 0x00, 0x0B } },
        .{ .expr = .{ .i32 = -64 }, .bytes = &.{ 0x41, 0x40, 0x0B } },
        .{ .expr = .{ .i32 = -65 }, .bytes = &.{ 0x41, 0xBF, 0x7F, 0x0B } },
        .{
            .expr = .{ .i32 = std.math.minInt(i32) },
            .bytes = &.{ 0x41, 0x80, 0x80, 0x80, 0x80, 0x78, 0x0B },
        },
        .{
            .expr = .{ .i32 = std.math.maxInt(i32) },
            .bytes = &.{ 0x41, 0xFF, 0xFF, 0xFF, 0xFF, 0x07, 0x0B },
        },
        .{ .expr = .{ .i64 = -1 }, .bytes = &.{ 0x42, 0x7F, 0x0B } },
        .{
            .expr = .{ .i64 = std.math.minInt(i64) },
            .bytes = &.{
                0x42, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7F, 0x0B,
            },
        },
    };
    var buffer: [64]u8 = undefined;
    for (cases) |row| {
        var writer: Io.Writer = .fixed(&buffer);
        try row.expr.encode(&writer);
        try testing.expectEqualSlices(u8, row.bytes, writer.buffered());
    }
}

test "encode: f32 and f64 are bit patterns, little-endian, NaN payloads intact" {
    var buffer: [16]u8 = undefined;

    const signalling_nan: Expr = .{ .f32 = 0x7FC0_0001 };
    var w32: Io.Writer = .fixed(&buffer);
    try signalling_nan.encode(&w32);
    try testing.expectEqualSlices(u8, &.{ 0x43, 0x01, 0x00, 0xC0, 0x7F, 0x0B }, w32.buffered());

    const negative_zero: Expr = .{ .f64 = 0x8000_0000_0000_0000 };
    var w64: Io.Writer = .fixed(&buffer);
    try negative_zero.encode(&w64);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x0B },
        w64.buffered(),
    );
}

test "encode: ref.null writes the opcode and one heap-type byte, for all twelve" {
    var buffer: [8]u8 = undefined;
    inline for (@typeInfo(spec.AbstractHeapType).@"enum".field_values) |value| {
        const heap_type: spec.AbstractHeapType = @fromBackingInt(value);
        const expr: Expr = .{ .ref_null = heap_type };
        var writer: Io.Writer = .fixed(&buffer);
        try expr.encode(&writer);
        try testing.expectEqualSlices(u8, &.{ 0xD0, value, 0x0B }, writer.buffered());
    }
}

test "encode: raw is written verbatim, then exactly one `end`" {
    const cases = [_]struct { instructions: []const u8, bytes: []const u8 }{
        .{ .instructions = &.{}, .bytes = &.{0x0B} }, // no instructions: `end` alone
        .{ .instructions = &.{ 0x41, 0x01 }, .bytes = &.{ 0x41, 0x01, 0x0B } },
        // The 0x0B here is the immediate of `i32.const 11`, not a terminator: raw is not scanned.
        .{ .instructions = &.{ 0x41, 0x0B }, .bytes = &.{ 0x41, 0x0B, 0x0B } },
        .{
            .instructions = &.{ 0xFD, 0x0C, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
            .bytes = &.{
                0xFD, 0x0C, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0x0B,
            },
        },
    };
    var buffer: [32]u8 = undefined;
    for (cases) |row| {
        const expr: Expr = .{ .raw = row.instructions };
        var writer: Io.Writer = .fixed(&buffer);
        try expr.encode(&writer);
        try testing.expectEqualSlices(u8, row.bytes, writer.buffered());
    }
}

test "encode then take: what was written is measured back exactly" {
    const exprs = [_]Expr{
        .{ .i32 = 0 },
        .{ .i32 = std.math.minInt(i32) },
        .{ .i64 = std.math.minInt(i64) },
        .{ .f32 = 0x7FC0_0001 },
        .{ .f64 = 0x8000_0000_0000_0000 },
        .{ .ref_null = .noexn },
        .{ .raw = &.{} },
        .{ .raw = &.{ 0x41, 0x0B } }, // the 0x0B is an immediate: take must not stop there
        .{
            .raw = &.{ 0xFD, 0x0C, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        },
    };
    for (exprs) |expr| {
        var buffer: [64]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        try expr.encode(&writer);
        const written = writer.buffered();
        try testing.expectEqual(0x0B, written[written.len - 1]);

        var cursor = try Cursor.init(written);
        const instructions = try take(&cursor);
        try testing.expectEqualSlices(u8, written[0 .. written.len - 1], instructions);
        try testing.expect(cursor.atEnd());
    }
}

test "encode: a short writer fails instead of panicking" {
    var tiny: [2]u8 = undefined;
    var writer: Io.Writer = .fixed(&tiny);
    const expr: Expr = .{ .i32 = std.math.minInt(i32) }; // seven bytes in all
    try testing.expectError(error.WriteFailed, expr.encode(&writer));
}
