//! Value types: one byte for every number and vector type, and one byte for a reference type in its
//! shorthand form (`ref null ht`).
//!
//! The prefixed reference forms (0x63/0x64 followed by a heap type) are legal wasm but are not
//! representable by `ValueType`, so they are refused rather than read as if they were one byte: a
//! reader that guessed their length would desync everything after the type.
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Cursor = @import("../Cursor.zig");
const spec = @import("../spec.zig");
const errors = @import("../errors.zig");
const EncodeError = errors.EncodeError;
const PayloadError = errors.PayloadError;
const fromCursor = errors.fromCursor;

pub const ValueType = spec.ValueType;

/// Reads one value type. Fails closed: a prefixed reference type is `UnsupportedFeature`, and any
/// byte that names no single-byte value type is `InvalidValue`. A failed read leaves the cursor
/// where it was.
pub fn read(cursor: *Cursor) PayloadError!ValueType {
    const start = cursor.pos;
    errdefer cursor.pos = start;

    const byte = try readTypeByte(cursor);
    const value_type = ValueType.fromByte(byte) orelse return error.InvalidValue;

    assert(cursor.pos == start + 1); // a value type is exactly one byte
    assert(value_type.toByte() == byte); // what came back is the byte that was read
    return value_type;
}

/// Reads a reference type: the one-byte shorthand, which is exactly one abstract heap type. A
/// prefixed form is `UnsupportedFeature`; a byte that names no heap type is `InvalidValue`, because
/// a number or vector type cannot be a reference type in any version of wasm.
pub fn readReference(cursor: *Cursor) PayloadError!spec.AbstractHeapType {
    const start = cursor.pos;
    errdefer cursor.pos = start;

    const byte = try readTypeByte(cursor);
    const heap_type = spec.AbstractHeapType.fromByte(byte) orelse return error.InvalidValue;

    assert(cursor.pos == start + 1); // a reference type in this form is exactly one byte
    assert(@backingInt(heap_type) == byte);
    return heap_type;
}

/// Reads the one byte both kinds of type start with, and refuses the two prefixes that would make
/// it the first of several. What the byte means is the caller's question.
fn readTypeByte(cursor: *Cursor) PayloadError!u8 {
    const byte = cursor.readByte() catch |err| return fromCursor(err);
    if (byte == spec.ref_prefix_nullable or byte == spec.ref_prefix_non_nullable)
        return error.UnsupportedFeature;
    return byte;
}

/// Writes the one byte the type is. There is no second byte to forget: a prefixed form cannot be
/// constructed, so it cannot be produced by mistake.
pub fn write(value: ValueType, writer: *Io.Writer) EncodeError!void {
    try writer.writeByte(value.toByte());
}

const testing = std.testing;

test "valtype: every single-byte type reads and writes back" {
    var accepted: u32 = 0;
    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        const value_type = spec.ValueType.fromByte(byte) orelse continue;
        accepted += 1;

        var cursor = try Cursor.init(&[_]u8{byte});
        try testing.expectEqualDeep(value_type, try read(&cursor));
        try testing.expect(cursor.atEnd());

        var buf: [1]u8 = undefined;
        var writer: Io.Writer = .fixed(&buf);
        try write(value_type, &writer);
        try testing.expectEqualSlices(u8, &[_]u8{byte}, writer.buffered());
    }
    try testing.expectEqual(17, accepted);
}

test "valtype: everything else is refused, and the cursor does not move" {
    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        if (spec.ValueType.fromByte(byte) != null) continue;

        var cursor = try Cursor.init(&[_]u8{byte});
        if (byte == spec.ref_prefix_nullable or byte == spec.ref_prefix_non_nullable) {
            try testing.expectError(error.UnsupportedFeature, read(&cursor));
        } else {
            try testing.expectError(error.InvalidValue, read(&cursor));
        }
        try testing.expectEqual(0, cursor.pos);
    }
}

test "valtype: an empty input is truncated" {
    var cursor = try Cursor.init(&.{});
    try testing.expectError(error.Truncated, read(&cursor));
}

test "valtype: positions are absolute, and the window end is respected" {
    const buffer = [_]u8{ 0xAA, 0x7F, 0xEE };
    var cursor = try Cursor.init(&buffer);
    try cursor.skip(1);
    try testing.expectEqualDeep(spec.ValueType{ .number_or_vector = .i32 }, try read(&cursor));
    try testing.expectEqual(2, cursor.pos);

    // An empty window has no type byte, though the buffer has one just past it.
    var whole = try Cursor.init(&buffer);
    var window = try whole.sub(0);
    try testing.expectError(error.Truncated, read(&window));
    try testing.expectEqual(0, window.pos);
}

test "valtype: a short writer fails instead of panicking" {
    var buf: [0]u8 = .{};
    var writer: Io.Writer = .fixed(&buf);
    try testing.expectError(error.WriteFailed, write(.{ .reference = .func }, &writer));
}

test "valtype: every heap type reads back as a reference type" {
    inline for (@typeInfo(spec.AbstractHeapType).@"enum".field_values) |value| {
        var cursor = try Cursor.init(&[_]u8{value});
        const expected = spec.AbstractHeapType.fromByte(value).?;
        try testing.expectEqual(expected, try readReference(&cursor));
        try testing.expect(cursor.atEnd());
    }
}

test "valtype: reference types refuse numbers, vectors, prefixes and unknown bytes" {
    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        if (spec.AbstractHeapType.fromByte(byte) != null) continue;

        var cursor = try Cursor.init(&[_]u8{byte});
        if (byte == spec.ref_prefix_nullable or byte == spec.ref_prefix_non_nullable) {
            try testing.expectError(error.UnsupportedFeature, readReference(&cursor));
        } else {
            try testing.expectError(error.InvalidValue, readReference(&cursor));
        }
        try testing.expectEqual(0, cursor.pos);
    }
}

test "valtype: reference types are one byte, and the window end is respected" {
    var empty = try Cursor.init(&.{});
    try testing.expectError(error.Truncated, readReference(&empty));

    const buffer = [_]u8{ 0xAA, 0x70, 0xEE };
    var cursor = try Cursor.init(&buffer);
    try cursor.skip(1);
    try testing.expectEqual(spec.AbstractHeapType.func, try readReference(&cursor));
    try testing.expectEqual(2, cursor.pos);
}
