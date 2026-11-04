//! Reading instructions out of a function body: where each one starts, where it ends, and how
//! deeply it nests.
//!
//! This is a reader, not a validator. Immediates are skipped by their binary width and never
//! decoded, and what `wasm-validate` checks (an `else` without an `if`, a branch past the
//! outermost label, a wrong operand type) is not checked here. What is guaranteed is that every
//! boundary found is the boundary a decoder would find, and that a body is consumed exactly.
//!
//! Depth: `Op.depth` counts the constructs that enclose an instruction, so the first instruction of
//! a body is at 0, the instructions inside a `block` are at 1, and that `block`'s own `end` is
//! also at 1. The body's final `end` is at 0: it is consumed to end the iteration, never yielded,
//! and bytes after it are `TrailingBytes`.
//!
//! Supported: the base instruction set `std.wasm.Opcode` names, the core instructions it does not
//! name (`spec.ExtraOpcode`), and the prefixed families `std.wasm` names: `0xFC` (saturating
//! truncation and bulk memory), `0xFD` (SIMD, relaxed SIMD included) and `0xFE` (atomics).
//! Refused with `UnsupportedFeature`: `0xFB` (GC), which `std.wasm` does not name, and the legacy
//! exception-handling instructions (`try`, `catch`, `rethrow`, `delegate`, `catch_all`), which the
//! 3.0 instruction set replaced with `try_table`. Each is a table to fill in, not a redesign.
const std = @import("std");
const assert = std.debug.assert;

const Cursor = @import("../Cursor.zig");
const spec = @import("../spec.zig");
const errors = @import("../errors.zig");
const PayloadError = errors.PayloadError;
const fromCursor = errors.fromCursor;

const prefix_misc: u8 = 0xFC;
const prefix_gc: u8 = 0xFB;
const prefix_simd: u8 = 0xFD;
const prefix_atomics: u8 = 0xFE;

/// `std.enums.fromInt` accepts any value for a non-exhaustive enum (both opcode enumerations have
/// an unnamed `_` slot), so a byte is turned into an opcode through these tables instead: a byte is
/// an instruction only if an enumeration names it.
const opcode_from_byte: [256]?spec.BaseOpcode = blk: {
    var table: [256]?spec.BaseOpcode = @splat(null);
    const info = @typeInfo(spec.BaseOpcode);
    for (info.@"enum".field_names, info.@"enum".field_values) |name, value| {
        table[value] = @field(spec.BaseOpcode, name);
    }
    break :blk table;
};

const extra_from_byte: [256]?spec.ExtraOpcode = blk: {
    var table: [256]?spec.ExtraOpcode = @splat(null);
    const info = @typeInfo(spec.ExtraOpcode);
    for (info.@"enum".field_names, info.@"enum".field_values) |name, value| {
        table[value] = @field(spec.ExtraOpcode, name);
    }
    break :blk table;
};

/// Prefixed instruction families, indexed by sub-opcode. SIMD is the widest: its relaxed operations
/// go up to 0x114, so the table covers every value a named sub-opcode can have.
const simd_from_sub: [0x115]?std.wasm.SimdOpcode = blk: {
    var table: [0x115]?std.wasm.SimdOpcode = @splat(null);
    const info = @typeInfo(std.wasm.SimdOpcode);
    for (info.@"enum".field_names, info.@"enum".field_values) |name, value| {
        if (value >= table.len) @compileError("std.wasm.SimdOpcode." ++ name ++ " is out of range");
        table[value] = @field(std.wasm.SimdOpcode, name);
    }
    break :blk table;
};

const atomics_from_sub: [0x4F]?std.wasm.AtomicsOpcode = blk: {
    var table: [0x4F]?std.wasm.AtomicsOpcode = @splat(null);
    const info = @typeInfo(std.wasm.AtomicsOpcode);
    for (info.@"enum".field_names, info.@"enum".field_values) |name, value| {
        if (value >= table.len)
            @compileError("std.wasm.AtomicsOpcode." ++ name ++ " is out of range");
        table[value] = @field(std.wasm.AtomicsOpcode, name);
    }
    break :blk table;
};

/// What one instruction is, as far as reading it can tell: its opcode, and which of the five
/// encodings names it. `std.wasm.Opcode` does not name the instructions the reference-types,
/// tail-call and exception proposals added, so the core byte space is split between two
/// enumerations; the tag says which one, so an instruction's identity is never a bare number.
pub const Opcode = union(enum) {
    /// An opcode `std.wasm.Opcode` names.
    base: spec.BaseOpcode,
    /// A core opcode `std.wasm.Opcode` does not name; `spec.ExtraOpcode` has the rest.
    extra: spec.ExtraOpcode,
    /// An opcode behind the `0xFC` prefix.
    misc: std.wasm.MiscOpcode,
    /// An opcode behind the `0xFD` prefix.
    simd: std.wasm.SimdOpcode,
    /// An opcode behind the `0xFE` prefix.
    atomics: std.wasm.AtomicsOpcode,
};

/// One instruction and where it sits: `at` is its first byte, `end` one past its last immediate,
/// both absolute offsets into the module. `opcode` says what it is; the operands stay in the bytes
/// between `at` and `end`, for the caller to read if it needs them.
pub const Op = struct {
    at: u32,
    end: u32,
    depth: u32,
    opcode: Opcode,
};

/// Walks a body's instructions. `body` starts at the first instruction, after the locals vector,
/// and ends with the final `end`, which is consumed but not yielded. A failed call leaves the
/// iterator where it was.
pub const BodyIter = struct {
    cursor: Cursor,
    depth: u32 = 0,
    finished: bool = false,

    pub fn init(body: Cursor) BodyIter {
        return .{ .cursor = body };
    }

    pub fn next(self: *BodyIter) PayloadError!?Op {
        const cursor = &self.cursor;
        if (self.finished) return null;
        if (cursor.atEnd()) return error.Truncated; // the body has no final `end`

        const at = cursor.pos;
        errdefer cursor.pos = at; // a failed call leaves the iterator where it was

        const opcode = try takeOpcode(cursor);
        if (isRefused(opcode)) return error.UnsupportedFeature;
        try skipImmediate(cursor, immediateOf(opcode));

        const depth = self.depth;
        switch (opcode) {
            .base => |base| switch (base) {
                .block, .loop, .@"if" => self.depth = open(depth),
                .end => {
                    if (depth == 0) {
                        if (!cursor.atEnd()) return error.TrailingBytes;
                        self.finished = true;
                        return null; // the body's terminator is the encoder's to write
                    }
                    self.depth = depth - 1;
                },
                else => {},
            },
            .extra => |extra| {
                if (extra == .try_table) self.depth = open(depth);
            },
            .misc, .simd, .atomics => {},
        }
        return .{ .at = at, .end = cursor.pos, .depth = depth, .opcode = opcode };
    }
};

/// Reads one instruction's opcode and leaves its immediates in the cursor. A failed read does not
/// move the cursor.
pub fn takeOpcode(cursor: *Cursor) PayloadError!Opcode {
    const start = cursor.pos;
    errdefer cursor.pos = start;

    const byte = try readByte(cursor);
    if (byte == prefix_misc) {
        const sub = try readU32(cursor);
        const opcode = miscOpcode(sub) orelse return error.InvalidValue;
        return .{ .misc = opcode };
    }
    if (byte == prefix_simd) {
        const sub = try readU32(cursor);
        const opcode = simdOpcode(sub) orelse return error.InvalidValue;
        return .{ .simd = opcode };
    }
    if (byte == prefix_atomics) {
        const sub = try readU32(cursor);
        const opcode = atomicsOpcode(sub) orelse return error.InvalidValue;
        return .{ .atomics = opcode };
    }
    if (byte == prefix_gc) return error.UnsupportedFeature;
    if (opcode_from_byte[byte]) |opcode| return .{ .base = opcode };
    if (extra_from_byte[byte]) |opcode| return .{ .extra = opcode };
    return error.InvalidValue;
}

/// Turns a `0xFC` sub-opcode into an instruction. `std.wasm.MiscOpcode` is non-exhaustive, so
/// `std.enums.fromInt` would accept a number nobody named; only the named values are instructions.
fn miscOpcode(sub: u32) ?std.wasm.MiscOpcode {
    const info = @typeInfo(std.wasm.MiscOpcode);
    inline for (info.@"enum".field_names, info.@"enum".field_values) |name, value| {
        if (sub == value) return @field(std.wasm.MiscOpcode, name);
    }
    return null;
}

fn simdOpcode(sub: u32) ?std.wasm.SimdOpcode {
    return if (sub < simd_from_sub.len) simd_from_sub[sub] else null;
}

fn atomicsOpcode(sub: u32) ?std.wasm.AtomicsOpcode {
    return if (sub < atomics_from_sub.len) atomics_from_sub[sub] else null;
}

/// The legacy exception-handling instructions are named (`spec.ExtraOpcode`) but not read: the 3.0
/// instruction set kept `throw` and `throw_ref` and replaced the rest with `try_table`.
fn isRefused(opcode: Opcode) bool {
    return switch (opcode) {
        .extra => |extra| switch (extra) {
            .@"try", .@"catch", .rethrow, .delegate, .catch_all => true,
            .throw,
            .throw_ref,
            .return_call,
            .return_call_indirect,
            .call_ref,
            .return_call_ref,
            .select_t,
            .try_table,
            .table_get,
            .table_set,
            .ref_null,
            .ref_is_null,
            .ref_func,
            .ref_eq,
            .ref_as_non_null,
            .br_on_null,
            .br_on_non_null,
            .gc_prefix,
            => false, // no `else`: a new ExtraOpcode must decide here
        },
        .base, .misc, .simd, .atomics => false,
    };
}

/// Opens one construct, for the instructions inside it. One opcode byte per construct bounds the
/// depth by the module length, which `Module.parse` keeps under 4 GiB, so this cannot overflow.
fn open(depth: u32) u32 {
    assert(depth < std.math.maxInt(u32));
    return depth + 1;
}

/// What has to be skipped after an opcode. The `_and_` values are the instructions that name two
/// index spaces in a row.
const Immediate = enum {
    none,
    block_type,
    label,
    br_table,
    function,
    call_indirect,
    type_index,
    local,
    global,
    table,
    memory,
    memory_argument,
    i32_const,
    i64_const,
    f32_const,
    f64_const,
    select_types,
    heap_type,
    tag,
    try_table,
    data,
    elem,
    data_and_memory,
    memory_pair,
    elem_and_table,
    table_pair,
    v128_const,
    shuffle,
    lane,
    memory_argument_lane,
    atomic_fence,
};

fn immediateOf(opcode: Opcode) Immediate {
    return switch (opcode) {
        // `takeOpcode` only produces named opcodes, and the compile-time check below proves that
        // every named one has a classification, so these cannot be null.
        .base => |base| immediateOfCoreByte(@backingInt(base)) orelse unreachable,
        .extra => |extra| immediateOfCoreByte(@backingInt(extra)) orelse unreachable,
        .misc => |misc| immediateOfMisc(misc),
        .simd => |simd| immediateOfSimd(@backingInt(simd)) orelse unreachable,
        .atomics => |atomics| immediateOfAtomics(@backingInt(atomics)) orelse unreachable,
    };
}

/// The immediates of the whole core byte space, keyed by opcode byte. `null` means no instruction
/// uses that byte: unassigned, or a prefix, which `takeOpcode` handles before this table.
fn immediateOfCoreByte(byte: u8) ?Immediate {
    return switch (byte) {
        0x00, 0x01 => .none, // unreachable, nop
        0x02, 0x03, 0x04, 0x06 => .block_type, // block, loop, if, try
        0x05, 0x0B, 0x0F => .none, // else, end, return
        0x07, 0x08 => .tag, // catch, throw
        0x09, 0x18 => .label, // rethrow, delegate
        0x0A, 0x19, 0x1A, 0x1B => .none, // throw_ref, catch_all, drop, select
        0xD1, 0xD3, 0xD4 => .none, // ref.is_null, ref.eq, ref.as_non_null
        0x0C, 0x0D, 0xD5, 0xD6 => .label, // br, br_if, br_on_null, br_on_non_null
        0x0E => .br_table,
        0x10, 0x12, 0xD2 => .function, // call, return_call, ref.func
        0x11, 0x13 => .call_indirect, // call_indirect, return_call_indirect
        0x14, 0x15 => .type_index, // call_ref, return_call_ref
        0x1C => .select_types,
        0x1F => .try_table,
        0x20...0x22 => .local,
        0x23, 0x24 => .global,
        0x25, 0x26 => .table,
        0x28...0x3E => .memory_argument,
        0x3F, 0x40 => .memory,
        0x41 => .i32_const,
        0x42 => .i64_const,
        0x43 => .f32_const,
        0x44 => .f64_const,
        0x45...0xC4 => .none, // every numeric instruction, and sign extension
        0xD0 => .heap_type,
        else => null,
    };
}

fn immediateOfMisc(opcode: std.wasm.MiscOpcode) Immediate {
    return switch (opcode) {
        .i32_trunc_sat_f32_s,
        .i32_trunc_sat_f32_u,
        .i32_trunc_sat_f64_s,
        .i32_trunc_sat_f64_u,
        .i64_trunc_sat_f32_s,
        .i64_trunc_sat_f32_u,
        .i64_trunc_sat_f64_s,
        .i64_trunc_sat_f64_u,
        => .none,
        .memory_init => .data_and_memory,
        .data_drop => .data,
        .memory_copy => .memory_pair,
        .memory_fill => .memory,
        .table_init => .elem_and_table,
        .elem_drop => .elem,
        .table_copy => .table_pair,
        .table_grow, .table_size, .table_fill => .table,
        _ => unreachable, // takeOpcode only builds a MiscOpcode that std.enums.fromInt accepted
    };
}

/// SIMD immediates: memory arguments for loads and stores, sixteen bytes for a constant or a
/// shuffle, one lane byte for extract and replace, and a memory argument plus a lane for the lane
/// loads and stores. Everything else, relaxed operations included, takes nothing.
fn immediateOfSimd(byte: u32) ?Immediate {
    return switch (byte) {
        0x00...0x0B, 0x5C, 0x5D => .memory_argument, // loads, store, the zero-extending loads
        0x0C => .v128_const,
        0x0D => .shuffle,
        0x0E...0x14 => .none, // swizzle and splats
        0x15...0x22 => .lane,
        0x23...0x53 => .none,
        0x54...0x5B => .memory_argument_lane,
        0x5E...0x114 => .none,
        else => null,
    };
}

/// Atomic immediates: a memory argument for every access, and one reserved byte for `atomic.fence`.
fn immediateOfAtomics(byte: u32) ?Immediate {
    return switch (byte) {
        0x00...0x02 => .memory_argument, // notify, wait32, wait64
        0x03 => .atomic_fence,
        0x10...0x4E => .memory_argument, // loads, stores, read-modify-writes
        else => null,
    };
}

fn skipImmediate(cursor: *Cursor, immediate: Immediate) PayloadError!void {
    switch (immediate) {
        .none => {},
        .block_type => try skipBlockType(cursor),
        .label,
        .function,
        .type_index,
        .local,
        .global,
        .table,
        .memory,
        .tag,
        .data,
        .elem,
        => try skipU32(cursor),
        .br_table => try skipBrTable(cursor),
        .call_indirect,
        .data_and_memory,
        .memory_pair,
        .elem_and_table,
        .table_pair,
        => {
            try skipU32(cursor);
            try skipU32(cursor);
        },
        .memory_argument => try skipMemoryArgument(cursor),
        .v128_const, .shuffle => try skipBytes(cursor, 16),
        .lane, .atomic_fence => try skipBytes(cursor, 1),
        .memory_argument_lane => {
            try skipMemoryArgument(cursor);
            try skipBytes(cursor, 1);
        },
        .i32_const, .heap_type => try skipLeb(cursor, 5),
        .i64_const => try skipLeb(cursor, 10),
        .f32_const => try skipBytes(cursor, 4),
        .f64_const => try skipBytes(cursor, 8),
        .select_types => try skipSelectTypes(cursor),
        .try_table => try skipTryTable(cursor),
    }
}

/// A block type is `0x40`, one value type, or a type index. All but a prefixed reference type and a
/// type index of 64 or more fit in the one byte that started it.
fn skipBlockType(cursor: *Cursor) PayloadError!void {
    const byte = try readByte(cursor);
    if (byte & 0x80 != 0) {
        try skipLeb(cursor, 4); // a type index of 64 or more: the LEB continues
    } else if (byte == spec.ref_prefix_nullable or byte == spec.ref_prefix_non_nullable) {
        try skipHeapType(cursor);
    }
}

/// A heap type is one negative byte, or a type index: a non-negative s33, whose first byte says
/// whether the encoding continues.
fn skipHeapType(cursor: *Cursor) PayloadError!void {
    const byte = try readByte(cursor);
    if (byte & 0x80 != 0) try skipLeb(cursor, 4);
}

/// A value type is one byte, or a reference-type prefix followed by a heap type.
fn skipValueType(cursor: *Cursor) PayloadError!void {
    const byte = try readByte(cursor);
    if (byte == spec.ref_prefix_nullable or byte == spec.ref_prefix_non_nullable) {
        try skipHeapType(cursor);
    }
}

/// `align offset`, with the multi-memory extension: bit 6 of the alignment says a memory index
/// comes between the alignment and the offset. A valid alignment exponent never reaches 64, so the
/// bit cannot mean anything else.
fn skipMemoryArgument(cursor: *Cursor) PayloadError!void {
    const alignment = try readU32(cursor);
    if (alignment & 0x40 != 0) try skipU32(cursor);
    try skipU32(cursor); // offset
}

/// `count`, then `count + 1` labels: the table's targets and its default.
fn skipBrTable(cursor: *Cursor) PayloadError!void {
    const count = try readU32(cursor);
    // Every label is at least one byte, so a larger count is a truncation, and the bound also keeps
    // the loop from running away on a bogus count.
    if (count >= cursor.remaining()) return error.Truncated;
    var i: u32 = 0;
    while (i <= count) : (i += 1) try skipU32(cursor);
}

/// `count` value types. Every one is at least a byte, so a larger count is a truncation.
fn skipSelectTypes(cursor: *Cursor) PayloadError!void {
    const count = try readU32(cursor);
    if (count > cursor.remaining()) return error.Truncated;
    var i: u32 = 0;
    while (i < count) : (i += 1) try skipValueType(cursor);
}

/// `blocktype`, then the catch clauses: `0x00`/`0x01` name a tag and a label, `0x02`/`0x03` only a
/// label.
fn skipTryTable(cursor: *Cursor) PayloadError!void {
    try skipBlockType(cursor);
    const count = try readU32(cursor);
    if (count > cursor.remaining()) return error.Truncated;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const kind = try readByte(cursor);
        switch (kind) {
            0x00, 0x01 => {
                try skipU32(cursor); // tag
                try skipU32(cursor); // label
            },
            0x02, 0x03 => try skipU32(cursor), // label
            else => return error.InvalidValue,
        }
    }
}

/// A signed LEB, skipped by width. `max_bytes` is 5 for an s33 and 10 for an s64.
fn skipLeb(cursor: *Cursor, comptime max_bytes: u8) PayloadError!void {
    cursor.skipLeb(max_bytes) catch |err| return fromCursor(err);
}

fn skipBytes(cursor: *Cursor, n: u32) PayloadError!void {
    _ = cursor.take(n) catch |err| return fromCursor(err);
}

fn skipU32(cursor: *Cursor) PayloadError!void {
    _ = try readU32(cursor);
}

fn readU32(cursor: *Cursor) PayloadError!u32 {
    return cursor.readUleb(u32) catch |err| return fromCursor(err);
}

fn readByte(cursor: *Cursor) PayloadError!u8 {
    return cursor.readByte() catch |err| return fromCursor(err);
}

comptime {
    // A Zig upgrade that names an opcode nobody classified would otherwise be skipped as "no
    // immediate", which desynchronises every later instruction boundary. Fail here instead.
    @setEvalBranchQuota(10_000); // ~530 named opcodes, and the range switches they hit
    const std_type = @typeInfo(spec.BaseOpcode);
    for (std_type.@"enum".field_names, std_type.@"enum".field_values) |field_name, field_value| {
        if (field_value == prefix_misc or field_value == prefix_simd or
            field_value == prefix_atomics) continue;
        if (immediateOfCoreByte(@intCast(field_value)) == null)
            @compileError("spec.BaseOpcode." ++ field_name ++ " has no immediate classification");
    }
    const extra_type = @typeInfo(spec.ExtraOpcode);
    for (extra_type.@"enum".field_names, extra_type.@"enum".field_values) |name, value| {
        if (value == prefix_gc) continue;
        if (immediateOfCoreByte(@intCast(value)) == null)
            @compileError("spec.ExtraOpcode." ++ name ++ " has no immediate classification");
    }
    const simd_type = @typeInfo(std.wasm.SimdOpcode);
    for (simd_type.@"enum".field_names, simd_type.@"enum".field_values) |name, value| {
        if (immediateOfSimd(@intCast(value)) == null)
            @compileError("std.wasm.SimdOpcode." ++ name ++ " has no immediate classification");
    }
    const atomics_type = @typeInfo(std.wasm.AtomicsOpcode);
    for (atomics_type.@"enum".field_names, atomics_type.@"enum".field_values) |name, value| {
        if (immediateOfAtomics(@intCast(value)) == null)
            @compileError("std.wasm.AtomicsOpcode." ++ name ++ " has no immediate classification");
    }
}
