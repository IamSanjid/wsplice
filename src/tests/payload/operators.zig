//! Tests of the instruction reader: boundaries, depth, and what it refuses.
const std = @import("std");
const testing = std.testing;

const spec = @import("../../spec.zig");
const Cursor = @import("../../Cursor.zig");
const operators = @import("../../payload/operators.zig");
const Opcode = operators.Opcode;
const Op = operators.Op;
const BodyIter = operators.BodyIter;

fn expectOpcode(expected: Opcode, actual: Opcode) !void {
    try testing.expect(std.meta.eql(expected, actual));
}

/// Runs `body` to the end and returns the instructions. Fails if the body does not end with its
/// final `end` and nothing after it.
fn collect(body: []const u8, out: []Op) ![]const Op {
    var iter = BodyIter.init(try Cursor.init(body));
    var count: usize = 0;
    while (try iter.next()) |op| {
        try testing.expect(count < out.len);
        out[count] = op;
        count += 1;
    }
    try testing.expect(iter.finished);
    return out[0..count];
}

/// Body `bytes` followed by `ends` `end` bytes; checks the first instruction's extent, identity and
/// depth, and that the rest of the body is exactly those `end`s.
fn expectOne(bytes: []const u8, expected_opcode: Opcode, ends: u8) !void {
    var body: [64]u8 = undefined;
    try testing.expect(bytes.len + ends <= body.len);
    @memcpy(body[0..bytes.len], bytes);
    @memset(body[bytes.len..][0..ends], 0x0B);

    var storage: [8]Op = undefined;
    const ops = try collect(body[0 .. bytes.len + ends], &storage);
    try testing.expectEqual(@as(usize, ends), ops.len);

    const first = ops[0];
    try testing.expectEqual(@as(u32, 0), first.at);
    try testing.expectEqual(@as(u32, @intCast(bytes.len)), first.end);
    try testing.expectEqual(@as(u32, 0), first.depth);
    try expectOpcode(expected_opcode, first.opcode);

    // everything after the instruction is its `end`s, each one level shallower
    for (ops[1..], 1..) |op, i| {
        try expectOpcode(.{ .base = .end }, op.opcode);
        try testing.expectEqual(@as(u32, @intCast(bytes.len + i - 1)), op.at);
        try testing.expectEqual(@as(u32, @intCast(@as(usize, ends) - i)), op.depth);
    }
}

/// The first error the body produces, or a test failure if it parses cleanly.
fn expectParseError(body: []const u8, expected: anyerror) !void {
    var iter = BodyIter.init(try Cursor.init(body));
    while (true) {
        const maybe_op = iter.next() catch |err| {
            try testing.expectEqual(expected, err);
            return;
        };
        if (maybe_op == null) return error.TestExpectedError;
    }
}

// --------------------------------------------------------------- the shape

test "operators: an empty body has no instructions" {
    var storage: [2]Op = undefined;
    const ops = try collect(&.{0x0B}, &storage);
    try testing.expectEqual(@as(usize, 0), ops.len);

    var iter = BodyIter.init(try Cursor.init(&.{0x0B}));
    try testing.expectEqual(null, try iter.next());
    try testing.expect(iter.finished);
    try testing.expect(iter.cursor.atEnd());
}

test "operators: depth counts the constructs an instruction is inside" {
    const body = [_]u8{
        0x02, 0x40, // block
        0x01, //       nop
        0x02, 0x40, // block
        0x01, //       nop
        0x0B, //       end of the inner block
        0x0B, //       end of the outer block
        0x0B, //       end of the body, not yielded
    };
    var storage: [8]Op = undefined;
    const ops = try collect(&body, &storage);

    const expected_at = [_]u32{ 0, 2, 3, 5, 6, 7 };
    const expected_depth = [_]u32{ 0, 1, 1, 2, 2, 1 };
    try testing.expectEqual(expected_at.len, ops.len);
    for (ops, expected_at, expected_depth) |op, at, depth| {
        try testing.expectEqual(at, op.at);
        try testing.expectEqual(depth, op.depth);
        try testing.expect(op.end > op.at); // every instruction consumes at least its opcode
    }
    // The two ends are at the depth of the body they close.
    try expectOpcode(.{ .base = .block }, ops[0].opcode);
    try expectOpcode(.{ .base = .block }, ops[2].opcode);
    try expectOpcode(.{ .base = .end }, ops[4].opcode);
    try expectOpcode(.{ .base = .end }, ops[5].opcode);
}

test "operators: else is at the depth of the if's body" {
    const body = [_]u8{
        0x04, 0x40, // if
        0x01, //       nop
        0x05, //       else
        0x01, //       nop
        0x0B, //       end of the if
        0x0B, //       end of the body, not yielded
    };
    var storage: [8]Op = undefined;
    const ops = try collect(&body, &storage);

    const expected_depth = [_]u32{ 0, 1, 1, 1, 1 };
    try testing.expectEqual(expected_depth.len, ops.len);
    for (ops, expected_depth) |op, depth| try testing.expectEqual(depth, op.depth);
    try expectOpcode(.{ .base = .@"else" }, ops[2].opcode);
}

// ------------------------------------------------------------- immediates

const Case = struct {
    name: []const u8,
    bytes: []const u8,
    opcode: Opcode,
    ends: u8 = 1, // two for the instructions that open a construct
};

const cases = [_]Case{
    .{ .name = "block, void", .bytes = &.{ 0x02, 0x40 }, .opcode = .{ .base = .block }, .ends = 2 },
    .{ .name = "block, value type", .bytes = &.{ 0x02, 0x7F }, .opcode = .{ .base = .block }, .ends = 2 },
    .{ .name = "block, reference type", .bytes = &.{ 0x02, 0x63, 0x70 }, .opcode = .{ .base = .block }, .ends = 2 },
    .{ .name = "block, type index 64", .bytes = &.{ 0x02, 0xC0, 0x00 }, .opcode = .{ .base = .block }, .ends = 2 },
    .{ .name = "loop", .bytes = &.{ 0x03, 0x40 }, .opcode = .{ .base = .loop }, .ends = 2 },
    .{ .name = "if", .bytes = &.{ 0x04, 0x40 }, .opcode = .{ .base = .@"if" }, .ends = 2 },
    .{ .name = "br", .bytes = &.{ 0x0C, 0x05 }, .opcode = .{ .base = .br } },
    .{ .name = "br_table", .bytes = &.{ 0x0E, 0x02, 0x00, 0x01, 0x02 }, .opcode = .{ .base = .br_table } },
    .{ .name = "call", .bytes = &.{ 0x10, 0x03 }, .opcode = .{ .base = .call } },
    .{ .name = "call_indirect", .bytes = &.{ 0x11, 0x00, 0x00 }, .opcode = .{ .base = .call_indirect } },
    .{ .name = "call_ref", .bytes = &.{ 0x14, 0x00 }, .opcode = .{ .extra = .call_ref } },
    .{ .name = "select, one type", .bytes = &.{ 0x1C, 0x01, 0x7F }, .opcode = .{ .extra = .select_t } },
    .{ .name = "select, reference type", .bytes = &.{ 0x1C, 0x01, 0x63, 0x70 }, .opcode = .{ .extra = .select_t } },
    .{ .name = "local.get", .bytes = &.{ 0x20, 0x00 }, .opcode = .{ .base = .local_get } },
    .{ .name = "global.set", .bytes = &.{ 0x24, 0x00 }, .opcode = .{ .base = .global_set } },
    .{ .name = "table.get", .bytes = &.{ 0x25, 0x00 }, .opcode = .{ .extra = .table_get } },
    .{ .name = "i32.load", .bytes = &.{ 0x28, 0x00, 0x00 }, .opcode = .{ .base = .i32_load } },
    // multi-memory: bit 6 of the alignment means a memory index sits before the offset
    .{ .name = "i32.load, memory index", .bytes = &.{ 0x28, 0x42, 0x01, 0x05 }, .opcode = .{ .base = .i32_load } },
    .{ .name = "memory.size", .bytes = &.{ 0x3F, 0x00 }, .opcode = .{ .base = .memory_size } },
    .{ .name = "i32.const, -1", .bytes = &.{ 0x41, 0x7F }, .opcode = .{ .base = .i32_const } },
    .{
        .name = "i64.const, padded",
        .bytes = &.{ 0x42, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 },
        .opcode = .{ .base = .i64_const },
    },
    .{ .name = "f32.const", .bytes = &.{ 0x43, 0, 0, 0, 0 }, .opcode = .{ .base = .f32_const } },
    .{ .name = "f64.const", .bytes = &.{ 0x44, 0, 0, 0, 0, 0, 0, 0, 0 }, .opcode = .{ .base = .f64_const } },
    .{ .name = "ref.null func", .bytes = &.{ 0xD0, 0x70 }, .opcode = .{ .extra = .ref_null } },
    .{ .name = "ref.null, type index 65", .bytes = &.{ 0xD0, 0xC1, 0x00 }, .opcode = .{ .extra = .ref_null } },
    .{ .name = "ref.func", .bytes = &.{ 0xD2, 0x00 }, .opcode = .{ .extra = .ref_func } },
    .{ .name = "br_on_null", .bytes = &.{ 0xD5, 0x00 }, .opcode = .{ .extra = .br_on_null } },
    .{ .name = "throw", .bytes = &.{ 0x08, 0x00 }, .opcode = .{ .extra = .throw } },
    .{ .name = "try_table, catch_all", .bytes = &.{ 0x1F, 0x40, 0x01, 0x02, 0x00 }, .opcode = .{ .extra = .try_table }, .ends = 2 },
    .{ .name = "try_table, catch", .bytes = &.{ 0x1F, 0x40, 0x01, 0x00, 0x00, 0x00 }, .opcode = .{ .extra = .try_table }, .ends = 2 },
    .{ .name = "memory.init", .bytes = &.{ 0xFC, 0x08, 0x00, 0x00 }, .opcode = .{ .misc = .memory_init } },
    .{ .name = "memory.copy", .bytes = &.{ 0xFC, 0x0A, 0x00, 0x00 }, .opcode = .{ .misc = .memory_copy } },
    .{ .name = "memory.fill", .bytes = &.{ 0xFC, 0x0B, 0x00 }, .opcode = .{ .misc = .memory_fill } },
    .{ .name = "table.init", .bytes = &.{ 0xFC, 0x0C, 0x00, 0x00 }, .opcode = .{ .misc = .table_init } },
    .{ .name = "table.copy", .bytes = &.{ 0xFC, 0x0E, 0x00, 0x00 }, .opcode = .{ .misc = .table_copy } },
    .{ .name = "table.grow", .bytes = &.{ 0xFC, 0x0F, 0x00 }, .opcode = .{ .misc = .table_grow } },
    .{ .name = "i32.trunc_sat_f32_s", .bytes = &.{ 0xFC, 0x00 }, .opcode = .{ .misc = .i32_trunc_sat_f32_s } },
    // SIMD: five immediate shapes, and a relaxed operation with a two-byte sub-opcode
    .{ .name = "v128.load", .bytes = &.{ 0xFD, 0x00, 0x00, 0x00 }, .opcode = .{ .simd = .v128_load } },
    .{
        .name = "v128.const",
        .bytes = &.{ 0xFD, 0x0C, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .opcode = .{ .simd = .v128_const },
    },
    .{
        .name = "i8x16.shuffle",
        .bytes = &.{ 0xFD, 0x0D, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .opcode = .{ .simd = .i8x16_shuffle },
    },
    .{ .name = "i8x16.extract_lane_s", .bytes = &.{ 0xFD, 0x15, 0x00 }, .opcode = .{ .simd = .i8x16_extract_lane_s } },
    .{ .name = "v128.load8_lane", .bytes = &.{ 0xFD, 0x54, 0x00, 0x00, 0x00 }, .opcode = .{ .simd = .v128_load8_lane } },
    .{ .name = "v128.load32_zero", .bytes = &.{ 0xFD, 0x5C, 0x00, 0x00 }, .opcode = .{ .simd = .v128_load32_zero } },
    .{ .name = "f32x4.relaxed_dot_bf16x8_add_f32x4", .bytes = &.{ 0xFD, 0x94, 0x02 }, .opcode = .{ .simd = .f32x4_relaxed_dot_bf16x8_add_f32x4 } },
    // atomics: a memory argument, and the one-byte fence
    .{ .name = "memory.atomic.notify", .bytes = &.{ 0xFE, 0x00, 0x00, 0x00 }, .opcode = .{ .atomics = .memory_atomic_notify } },
    .{ .name = "atomic.fence", .bytes = &.{ 0xFE, 0x03, 0x00 }, .opcode = .{ .atomics = .atomic_fence } },
    .{ .name = "i64.atomic.rmw32.cmpxchg_u", .bytes = &.{ 0xFE, 0x4E, 0x00, 0x00 }, .opcode = .{ .atomics = .i64_atomic_rmw32_cmpxchg_u } },
};

test "operators: every immediate is skipped exactly" {
    for (cases) |case| {
        expectOne(case.bytes, case.opcode, case.ends) catch |err| {
            std.debug.print("case failed: {s}\n", .{case.name});
            return err;
        };
    }
}

// ------------------------------------------- every prefixed sub-opcode

const simd_count = @typeInfo(std.wasm.SimdOpcode).@"enum".field_names.len;
const atomics_count = @typeInfo(std.wasm.AtomicsOpcode).@"enum".field_names.len;

/// Every named sub-opcode, as a runtime array. `field_values` is comptime-only, and the test wants
/// a loop rather than 257 unrolled copies of its body.
const simd_subs: [simd_count]u32 = blk: {
    var subs: [simd_count]u32 = undefined;
    for (@typeInfo(std.wasm.SimdOpcode).@"enum".field_values, 0..) |value, i| subs[i] = value;
    break :blk subs;
};

const atomics_subs: [atomics_count]u32 = blk: {
    var subs: [atomics_count]u32 = undefined;
    for (@typeInfo(std.wasm.AtomicsOpcode).@"enum".field_values, 0..) |value, i| subs[i] = value;
    break :blk subs;
};

fn writeUleb(out: []u8, value: u32) usize {
    var remaining = value;
    var i: usize = 0;
    while (true) {
        const byte: u8 = @intCast(remaining & 0x7F);
        remaining >>= 7;
        out[i] = if (remaining == 0) byte else byte | 0x80;
        i += 1;
        if (remaining == 0) return i;
    }
}

/// The immediate bytes the test feeds a SIMD instruction: zeros, so a memory argument is align 0
/// and offset 0, a lane is lane 0, and a constant or shuffle is sixteen zero bytes.
fn simdImmediateLen(sub: u32) usize {
    return switch (sub) {
        0x00...0x0B, 0x5C, 0x5D => 2, // memory argument
        0x0C, 0x0D => 16, // v128.const, i8x16.shuffle
        0x0E...0x14 => 0, // swizzle and splats
        0x15...0x22 => 1, // lane
        0x23...0x53 => 0,
        0x54...0x5B => 3, // memory argument and lane
        0x5E...0x114 => 0,
        else => unreachable, // every named sub-opcode is in these ranges
    };
}

fn atomicsImmediateLen(sub: u32) usize {
    return switch (sub) {
        0x00...0x02, 0x10...0x4E => 2, // memory argument
        0x03 => 1, // atomic.fence's reserved byte
        else => unreachable, // every named sub-opcode is in these ranges
    };
}

test "operators: every named SIMD and atomics sub-opcode parses at the right length" {
    try testing.expectEqual(@as(usize, 257), simd_count); // pinned: a std upgrade is deliberate
    try testing.expectEqual(@as(usize, 67), atomics_count);

    var body: [24]u8 = undefined;
    var storage: [4]Op = undefined;

    for (simd_subs) |sub| {
        var len: usize = 0;
        body[len] = 0xFD;
        len += 1;
        len += writeUleb(body[len..], sub);
        const immediate_len = simdImmediateLen(sub);
        @memset(body[len..][0..immediate_len], 0x00);
        len += immediate_len;
        body[len] = 0x0B;
        len += 1;

        const ops = try collect(body[0..len], &storage);
        try testing.expectEqual(@as(usize, 1), ops.len);
        try testing.expectEqual(@as(u32, 0), ops[0].at);
        try testing.expectEqual(@as(u32, @intCast(len - 1)), ops[0].end);
        try testing.expectEqual(std.meta.Tag(Opcode).simd, std.meta.activeTag(ops[0].opcode));
        try testing.expectEqual(sub, @backingInt(ops[0].opcode.simd));
    }

    for (atomics_subs) |sub| {
        var len: usize = 0;
        body[len] = 0xFE;
        len += 1;
        len += writeUleb(body[len..], sub);
        const immediate_len = atomicsImmediateLen(sub);
        @memset(body[len..][0..immediate_len], 0x00);
        len += immediate_len;
        body[len] = 0x0B;
        len += 1;

        const ops = try collect(body[0..len], &storage);
        try testing.expectEqual(@as(usize, 1), ops.len);
        try testing.expectEqual(@as(u32, 0), ops[0].at);
        try testing.expectEqual(@as(u32, @intCast(len - 1)), ops[0].end);
        try testing.expectEqual(std.meta.Tag(Opcode).atomics, std.meta.activeTag(ops[0].opcode));
        try testing.expectEqual(sub, @backingInt(ops[0].opcode.atomics));
    }
}

// ------------------------------------------------------- failures and limits

test "operators: what is not an instruction" {
    try expectParseError(&.{0x27}, error.InvalidValue); // unassigned
    try expectParseError(&.{0xFF}, error.InvalidValue);
    try expectParseError(&.{ 0xFC, 0x12 }, error.InvalidValue); // unassigned 0xFC sub-opcode
    try expectParseError(&.{ 0xFC, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F }, error.InvalidValue);

    try expectParseError(&.{0xFB}, error.UnsupportedFeature); // GC
    try expectParseError(&.{0xFD}, error.Truncated); // a prefix: it needs a sub-opcode
    try expectParseError(&.{0xFE}, error.Truncated);
    try expectParseError(&.{ 0xFD, 0x80, 0x04 }, error.InvalidValue); // 0x200: no such SIMD opcode
    try expectParseError(&.{ 0xFE, 0x4F }, error.InvalidValue); // no such atomic opcode
    inline for ([_]u8{ 0x06, 0x07, 0x09, 0x18, 0x19 }) |byte| { // legacy exception handling
        try expectParseError(&.{byte}, error.UnsupportedFeature);
    }
}

test "operators: a body that ends early, or does not end, is an error" {
    try expectParseError(&.{}, error.Truncated); // no body at all
    try expectParseError(&.{0x41}, error.Truncated); // i32.const without its immediate
    try expectParseError(&.{ 0x28, 0x00 }, error.Truncated); // load without its offset
    try expectParseError(&.{0x02}, error.Truncated); // block without its block type
    try expectParseError(&.{ 0x0B, 0x0B }, error.TrailingBytes); // after the final end
    try expectParseError(&.{ 0x0B, 0x01 }, error.TrailingBytes);
    try expectParseError(&.{ 0x1F, 0x40, 0x01, 0x04, 0x00 }, error.InvalidValue); // catch kind 4
}

test "operators: a bogus count cannot make the reader run away" {
    // br_table count u32 max
    try expectParseError(&.{ 0x0E, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F }, error.Truncated);
    // select count u32 max
    try expectParseError(&.{ 0x1C, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F }, error.Truncated);
    // try_table catch count u32 max
    try expectParseError(&.{ 0x1F, 0x40, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F }, error.Truncated);
}

test "operators: a failed next leaves the iterator where it was" {
    // `block` is complete; the `i32.const` inside it is not.
    var iter = BodyIter.init(try Cursor.init(&.{ 0x02, 0x40, 0x41 }));
    const block = (try iter.next()).?;
    try testing.expectEqual(@as(u32, 0), block.at);
    try testing.expectEqual(@as(u32, 1), iter.depth);

    try testing.expectError(error.Truncated, iter.next());
    try testing.expectEqual(@as(u32, 2), iter.cursor.pos); // at the failing instruction
    try testing.expectEqual(@as(u32, 1), iter.depth);
    try testing.expect(!iter.finished);
    try testing.expectError(error.Truncated, iter.next()); // and it fails the same way again
}

/// The bytes `std.wasm.Opcode` and `spec.ExtraOpcode` name, built independently of the reader's own
/// tables: the oracle for "only named bytes are instructions".
const named_std: [256]?spec.BaseOpcode = blk: {
    var table: [256]?spec.BaseOpcode = @splat(null);
    const info = @typeInfo(spec.BaseOpcode);
    for (info.@"enum".field_names, info.@"enum".field_values) |name, value| {
        table[value] = @field(spec.BaseOpcode, name);
    }
    break :blk table;
};

const named_extra: [256]?spec.ExtraOpcode = blk: {
    var table: [256]?spec.ExtraOpcode = @splat(null);
    const info = @typeInfo(spec.ExtraOpcode);
    for (info.@"enum".field_names, info.@"enum".field_values) |name, value| {
        table[value] = @field(spec.ExtraOpcode, name);
    }
    break :blk table;
};

test "operators: every named byte is an instruction and nothing else is" {
    var accepted: u32 = 0;
    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        var cursor = try Cursor.init(&[_]u8{byte});
        const from_std = named_std[byte];
        const from_extra = named_extra[byte];
        const result = operators.takeOpcode(&cursor);

        if (byte == 0xFC or byte == 0xFD or byte == 0xFE) {
            try testing.expectError(error.Truncated, result); // a prefix: it needs a sub-opcode
            try testing.expectEqual(@as(u32, 0), cursor.pos);
        } else if (byte == 0xFB) {
            try testing.expectError(error.UnsupportedFeature, result);
        } else if (from_std) |opcode| {
            accepted += 1;
            try expectOpcode(.{ .base = opcode }, try result);
            try testing.expectEqual(@as(u32, 1), cursor.pos);
        } else if (from_extra) |opcode| {
            accepted += 1;
            try expectOpcode(.{ .extra = opcode }, try result);
            try testing.expectEqual(@as(u32, 1), cursor.pos);
        } else {
            try testing.expectError(error.InvalidValue, result);
            try testing.expectEqual(@as(u32, 0), cursor.pos); // a failed read restores the cursor
        }
    }
    // 177 std opcodes (three of them prefixes) and 22 extra ones, one of them the GC prefix.
    try testing.expectEqual(@as(u32, 199), accepted);
}

// ---------------------------------------------------------------- mutations

test "operators: a mutated body either parses into contiguous instructions or fails cleanly" {
    const base = [_]u8{
        0x02, 0x40, // block
        0x41, 0x00, // i32.const 0
        0x0C, 0x00, // br 0
        0x0B, //       end
        0x1C, 0x01, 0x7F, // select (result i32)
        0x0E, 0x01, 0x00, 0x00, // br_table 0 [0]
        0x0B, //       end of the body
    };
    var buf: [base.len]u8 = base;
    var storage: [16]Op = undefined;
    var accepted: u32 = 0;
    var rejected: u32 = 0;

    for (0..buf.len) |i| {
        const original = base[i];
        for ([_]u8{ 0x00, 0xFF, original ^ 0x80, original +% 1 }) |value| {
            buf[i] = value;
            const ops = collect(&buf, &storage) catch |err| {
                rejected += 1;
                switch (err) {
                    error.Truncated,
                    error.MalformedLeb,
                    error.TrailingBytes,
                    error.InvalidValue,
                    error.UnsupportedFeature,
                    => {},
                    else => return err,
                }
                continue;
            };
            accepted += 1;
            try testing.expect(ops.len > 0);
            try testing.expectEqual(@as(u32, 0), ops[0].at);
            for (ops[0 .. ops.len - 1], ops[1..]) |prev, next| {
                try testing.expectEqual(prev.end, next.at); // contiguous, no gaps
            }
            // The last instruction ends where the body's terminator starts; the terminator itself
            // is consumed by the iterator, not yielded.
            try testing.expectEqual(@as(u32, @intCast(buf.len - 1)), ops[ops.len - 1].end);
        }
        buf[i] = original;
    }
    try testing.expect(accepted > 0); // the success checks actually ran
    try testing.expect(rejected > 0); // the gate actually rejected things
}
