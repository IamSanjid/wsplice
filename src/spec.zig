const std = @import("std");
const assert = std.debug.assert;
const wasm = std.wasm;

/// The base opcode table: `std.wasm.Opcode`, which names the MVP instructions and prefix markers.
/// `ExtraOpcode` fills in the core bytes it does not name.
pub const BaseOpcode = wasm.Opcode;
pub const MiscOpcode = wasm.MiscOpcode;
pub const SimdOpcode = wasm.SimdOpcode;
pub const AtomicsOpcode = wasm.AtomicsOpcode;
pub const magic = wasm.magic;
pub const version = wasm.version;
pub const header_len = magic.len + version.len;
pub const function_type = wasm.function_type;

/// Abstract heap types, one byte each; used alone, a byte is also a complete nullable reference
/// type (`0x70` is `funcref`).
///
/// These are the binary format's abstract heap type encodings, not type indices: as s33 they are
/// negative (-23 to -12). Only a non-negative s33 is a type index, which is why a concrete type
/// needs the prefixed form.
pub const AbstractHeapType = enum(u8) {
    exn = 0x69,
    array = 0x6A,
    @"struct" = 0x6B,
    i31 = 0x6C,
    eq = 0x6D,
    any = 0x6E,
    @"extern" = 0x6F,
    func = 0x70,
    none = 0x71,
    noextern = 0x72,
    nofunc = 0x73,
    noexn = 0x74,

    /// The abstract heap type `byte` names, or null if it names none; these twelve are the only
    /// single-byte heap types.
    pub fn fromByte(byte: u8) ?AbstractHeapType {
        return std.enums.fromInt(AbstractHeapType, byte);
    }
};

/// Prefixes for a reference type that is not the one-byte shorthand. Each is followed by a heap
/// type, which is one byte (above) or a type index as a positive signed LEB.
pub const ref_prefix_nullable: u8 = 0x63; // `ref null ht`
pub const ref_prefix_non_nullable: u8 = 0x64; // `ref ht`

comptime {
    // std's reference types are heap types we agree with
    assert(@backingInt(AbstractHeapType.func) == @backingInt(wasm.RefType.funcref));
    assert(@backingInt(AbstractHeapType.@"extern") == @backingInt(wasm.RefType.externref));

    // A one-byte heap type must never be mistaken for a number type, a vector type, or one of the
    // two prefixes: a collision would change how many bytes a reader consumes.
    const type_info = @typeInfo(AbstractHeapType);
    for (type_info.@"enum".field_names, type_info.@"enum".field_values) |field_name, value| {
        for (@typeInfo(wasm.Valtype).@"enum".field_values) |valtype| {
            if (value == valtype)
                @compileError(
                    "AbstractHeapType." ++ field_name ++ " collides with std.wasm.Valtype",
                );
        }
        if (value == ref_prefix_nullable or value == ref_prefix_non_nullable)
            @compileError(
                "AbstractHeapType." ++ field_name ++ " collides with a reference type prefix",
            );
    }
}

test "AbstractHeapType: bytes, and what is deliberately not a heap type" {
    try std.testing.expectEqual(@as(u8, 0x70), @backingInt(AbstractHeapType.func));
    try std.testing.expectEqual(@as(u8, 0x69), @backingInt(AbstractHeapType.exn));
    try std.testing.expectEqual(@as(u8, 0x74), @backingInt(AbstractHeapType.noexn));

    // Every heap type byte has bit 6 set, so as a one-byte s33 each one is negative: that is what
    // keeps them apart from a type index, which must be non-negative.
    inline for (@typeInfo(AbstractHeapType).@"enum".field_values) |value| {
        try std.testing.expect(value & 0x40 != 0);
    }

    // 0x63 and 0x64 are prefixes, and 0x61..0x68 are reserved or used by unfinished proposals
    for ([_]u8{ 0x00, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x75, 0x7F, 0xFF }) |byte| {
        try std.testing.expectEqual(null, std.enums.fromInt(AbstractHeapType, byte));
        try std.testing.expectEqual(null, AbstractHeapType.fromByte(byte));
    }
    for (0x69..0x75) |byte| {
        const heap_type = std.enums.fromInt(AbstractHeapType, @as(u8, @intCast(byte)));
        try std.testing.expect(heap_type != null);
    }
}

/// A global's mutability: the `mut` byte of a global type, 0 for `const` and 1 for `var`.
pub const Mutability = enum(u8) {
    immutable = 0x00,
    mutable = 0x01,
};

/// A value type: what a global or local holds, and what a function takes and returns.
///
/// The reference case is one abstract heap type, the shorthand for `ref null ht`. Prefixed forms
/// have a different shape and are not represented; nothing here can construct one.
pub const ValueType = union(enum) {
    number_or_vector: wasm.Valtype,
    reference: AbstractHeapType,

    /// The type `byte` names, or null if it names no single-byte value type; `0x63`/`0x64` are
    /// prefixes, not types.
    pub fn fromByte(byte: u8) ?ValueType {
        if (std.enums.fromInt(wasm.Valtype, byte)) |number_or_vector| {
            return .{ .number_or_vector = number_or_vector };
        }
        if (AbstractHeapType.fromByte(byte)) |reference| return .{ .reference = reference };
        return null;
    }

    /// The one byte the type is; the inverse of `fromByte` for every type it accepts.
    pub fn toByte(self: ValueType) u8 {
        return switch (self) {
            .number_or_vector => |number_or_vector| @backingInt(number_or_vector),
            .reference => |reference| @backingInt(reference),
        };
    }
};

test "Mutability: the two bytes the binary format defines" {
    try std.testing.expectEqual(@as(u8, 0x00), @backingInt(Mutability.immutable));
    try std.testing.expectEqual(@as(u8, 0x01), @backingInt(Mutability.mutable));
    try std.testing.expectEqual(null, std.enums.fromInt(Mutability, @as(u8, 2)));
    try std.testing.expectEqual(null, std.enums.fromInt(Mutability, @as(u8, 0xFF)));
}

test "ValueType: 17 single-byte types, and fromByte/toByte are inverses" {
    var accepted: u32 = 0;
    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        if (ValueType.fromByte(byte)) |value_type| {
            accepted += 1;
            try std.testing.expectEqual(byte, value_type.toByte());
        }
    }
    // Five number/vector types and twelve heap types, none of them overlapping.
    try std.testing.expectEqual(17, accepted);
    try std.testing.expectEqual(null, ValueType.fromByte(ref_prefix_nullable));
    try std.testing.expectEqual(null, ValueType.fromByte(ref_prefix_non_nullable));
}

test "ValueType: each byte comes from the enumeration it belongs to" {
    const i32_type = ValueType.fromByte(0x7F).?;
    try std.testing.expectEqual(wasm.Valtype.i32, i32_type.number_or_vector);

    const v128_type = ValueType.fromByte(0x7B).?;
    try std.testing.expectEqual(wasm.Valtype.v128, v128_type.number_or_vector);

    const funcref_type = ValueType.fromByte(0x70).?;
    try std.testing.expectEqual(AbstractHeapType.func, funcref_type.reference);

    const exnref_type = ValueType.fromByte(0x69).?;
    try std.testing.expectEqual(AbstractHeapType.exn, exnref_type.reference);
}

pub const SectionId = enum(u8) {
    custom = 0,
    type = 1,
    import = 2,
    function = 3,
    table = 4,
    memory = 5,
    global = 6,
    @"export" = 7,
    start = 8,
    element = 9,
    code = 10,
    data = 11,
    data_count = 12,
    tag = 13,

    pub fn rank(id: SectionId) u8 {
        assert(id != .custom); // custom sections have no position
        return switch (id) {
            .custom => unreachable,
            .type => 1,
            .import => 2,
            .function => 3,
            .table => 4,
            .memory => 5,
            .tag => 6,
            .global => 7,
            .@"export" => 8,
            .start => 9,
            .element => 10,
            .data_count => 11,
            .code => 12,
            .data => 13,
        };
    }

    pub fn fromRank(section_rank: u8) SectionId {
        assert(section_rank >= 1);
        assert(section_rank <= by_rank.len);
        return by_rank[section_rank - 1];
    }
};
pub const section_id_count = @typeInfo(SectionId).@"enum".field_names.len;
const by_rank: [section_id_count - 1]SectionId = blk: {
    var slots: [section_id_count - 1]?SectionId = @splat(null);
    const type_info = @typeInfo(SectionId);
    for (type_info.@"enum".field_names, type_info.@"enum".field_values) |name, value| {
        const id: SectionId = @fromBackingInt(value);
        if (id == .custom) continue;
        const slot_index = id.rank() - 1;
        if (slots[slot_index] != null) @compileError("two sections share rank " ++ name);
        slots[slot_index] = id;
    }
    var result: [section_id_count - 1]SectionId = undefined;
    for (slots, 0..) |slot, slot_index| {
        result[slot_index] = slot orelse @compileError("a rank has no section");
    }
    break :blk result;
};

comptime {
    const type_info = @typeInfo(wasm.Section);
    for (type_info.@"enum".field_names, type_info.@"enum".field_values) |field_name, value| {
        if (@backingInt(@field(SectionId, field_name)) != value)
            @compileError("SectionId." ++ field_name ++ " disagrees with std.wasm.Section");
    }
}

comptime {
    var seen: [section_id_count]bool = @splat(false);
    var count: u8 = 0;
    const type_info = @typeInfo(SectionId);
    for (type_info.@"enum".field_names, type_info.@"enum".field_values) |name, value| {
        const id: SectionId = @fromBackingInt(value);
        if (id == .custom) continue;
        const rank = id.rank();
        if (rank < 1) @compileError("rank below 1 for " ++ name);
        if (rank >= section_id_count) @compileError("rank past the last slot for " ++ name);
        if (seen[rank]) @compileError("duplicate rank for " ++ name);
        seen[rank] = true;
        count += 1;
    }
    assert(count == section_id_count - 1); // every non-custom section was ranked
}

comptime {
    for (by_rank, 1..) |id, rank| assert(id.rank() == rank);
}

test "rank follows the binary order, not the id order" {
    try std.testing.expect(SectionId.memory.rank() < SectionId.tag.rank());
    try std.testing.expect(SectionId.tag.rank() < SectionId.global.rank());
    try std.testing.expect(SectionId.element.rank() < SectionId.data_count.rank());
    try std.testing.expect(SectionId.data_count.rank() < SectionId.code.rank());
    try std.testing.expect(SectionId.code.rank() < SectionId.data.rank());
    try std.testing.expectEqual(1, SectionId.type.rank());
    try std.testing.expectEqual(13, SectionId.data.rank());
}

test "by_rank is the binary section order" {
    const expected = [_]SectionId{
        .type,      .import, .function, .table,      .memory, .tag,  .global,
        .@"export", .start,  .element,  .data_count, .code,   .data,
    };
    try std.testing.expectEqualSlices(SectionId, &expected, &by_rank);
    for (expected, 1..) |id, r| try std.testing.expectEqual(id, SectionId.fromRank(@intCast(r)));
}

/// The index spaces a plan can name. `type` has no `ExternalKind`; element and data are not
/// referenceable yet. `local` is a function body's own space: parameters first, then locals.
pub const IndexSpace = enum { type, function, table, memory, global, tag, local };

pub const ExternalKind = enum(u8) {
    function = 0,
    table = 1,
    memory = 2,
    global = 3,
    tag = 4,

    /// The space entities of this kind live in. Every kind has exactly one.
    pub fn indexSpace(self: ExternalKind) IndexSpace {
        return switch (self) {
            .function => .function,
            .table => .table,
            .memory => .memory,
            .global => .global,
            .tag => .tag,
        };
    }
};

comptime {
    const type_info = @typeInfo(wasm.ExternalKind);
    for (type_info.@"enum".field_names, type_info.@"enum".field_values) |field_name, value| {
        if (@backingInt(@field(ExternalKind, field_name)) != value)
            @compileError("ExternalKind." ++ field_name ++ " disagrees with std.wasm.ExternalKind");
    }
}

test "IndexSpace: every ExternalKind has its own space, named the same" {
    inline for (
        @typeInfo(ExternalKind).@"enum".field_names,
        @typeInfo(ExternalKind).@"enum".field_values,
    ) |name, value| {
        const kind: ExternalKind = @fromBackingInt(value);
        try std.testing.expectEqual(@field(IndexSpace, name), kind.indexSpace());
    }
}

pub const Limits = struct {
    flags: Flags,
    min: u64,
    max: u64,

    pub const Flags = packed struct(u8) {
        has_max: bool,
        is_shared: bool,
        is_64bit: bool,
        reserved: u5 = 0,
    };
};

comptime {
    {
        const f: Limits.Flags = .{ .has_max = true, .is_shared = false, .is_64bit = false };
        assert(@as(u8, @bitCast(f)) == 0x01);
    }
    {
        const f: Limits.Flags = .{ .has_max = false, .is_shared = true, .is_64bit = false };
        assert(@as(u8, @bitCast(f)) == 0x02);
    }
    {
        const f: Limits.Flags = .{ .has_max = false, .is_shared = false, .is_64bit = true };
        assert(@as(u8, @bitCast(f)) == 0x04);
    }
}

pub const ExtraOpcode = enum(u8) {
    @"try" = 0x06,
    @"catch" = 0x07,
    throw = 0x08,
    rethrow = 0x09,
    throw_ref = 0x0A,
    return_call = 0x12,
    return_call_indirect = 0x13,
    call_ref = 0x14,
    return_call_ref = 0x15,
    delegate = 0x18,
    catch_all = 0x19,
    select_t = 0x1C,
    try_table = 0x1F,
    table_get = 0x25,
    table_set = 0x26,
    ref_null = 0xD0,
    ref_is_null = 0xD1,
    ref_func = 0xD2,
    ref_eq = 0xD3,
    ref_as_non_null = 0xD4,
    br_on_null = 0xD5,
    br_on_non_null = 0xD6,
    gc_prefix = 0xFB,
};

comptime {
    const std_opcode_table: [256]bool = blk: {
        var table: [256]bool = @splat(false);
        for (@typeInfo(wasm.Opcode).@"enum".field_values) |value| table[value] = true;
        break :blk table;
    };
    const type_info = @typeInfo(ExtraOpcode);
    for (type_info.@"enum".field_names, type_info.@"enum".field_values) |field_name, value| {
        if (std_opcode_table[value])
            @compileError("ExtraOpcode." ++ field_name ++ " overlaps with std.wasm.Opcode");
    }
}

test "Fact check" {
    try std.testing.expectEqual(0xFB, @backingInt(ExtraOpcode.gc_prefix));
    try std.testing.expectEqual(13, @backingInt(SectionId.tag));
    try std.testing.expectEqual(4, @backingInt(ExternalKind.tag));
}
