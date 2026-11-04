//! Reader for the type section payload: one function type per entry.
//!
//!     type     ::= vec(functype)
//!     functype ::= 0x60 vec(valtype) vec(valtype)
//!
//! Only function types are representable here. The GC forms (rec, sub, struct, array) are refused
//! with `UnsupportedFeature`, like every other GC feature in the library. Parameters and results
//! are kept as their encoded one-byte value types, so reading a signature allocates nothing;
//! `Values` decodes them lazily.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Cursor = @import("../Cursor.zig");
const Span = @import("../section.zig").Span;
const spec = @import("../spec.zig");
const valtype = @import("valtype.zig");
const errors = @import("../errors.zig");
const EncodeError = errors.EncodeError;
const PayloadError = errors.PayloadError;
const fromCursor = errors.fromCursor;

/// The one type form this library reads and writes.
pub const form_func: u8 = 0x60;

/// The other forms the binary format assigns. They are GC types, so they are refused as a feature
/// rather than reported as an arbitrary invalid byte.
const gc_forms = [_]u8{ 0x4E, 0x50, 0x5E, 0x5F }; // rec, sub, array, struct

/// One function type. `params` and `results` are the value type bytes, one per parameter or
/// result, without their vector counts; `params.len` and `results.len` are the counts.
pub const Entry = struct {
    params: []const u8,
    results: []const u8,

    pub fn paramValues(self: Entry) Values {
        return .init(self.params);
    }

    pub fn resultValues(self: Entry) Values {
        return .init(self.results);
    }
};

/// A function type's parameters or results for a plan: either encoded value types borrowed from a
/// `types.Entry`, or typed values a plan constructs.
///
/// The wasm grammar allows multi-byte value types (the prefixed `ref null ht`/`ref ht` forms);
/// this library only represents the one-byte forms and refuses prefixes with `UnsupportedFeature`.
/// `EncodedValues.value_count` is therefore authoritative rather than `bytes.len`, so the shape
/// does not silently break if prefixed value types are added later.
pub const SignatureValues = union(enum) {
    /// Encoded value types, one per value, without the vector count.
    encoded: EncodedValues,
    /// Typed values; the slice length is the count.
    typed: []const spec.ValueType,

    pub fn count(self: *const SignatureValues) EncodeError!u32 {
        const length: u64 = switch (self.*) {
            .encoded => |values| values.value_count,
            .typed => |values| values.len,
        };
        return std.math.cast(u32, length) orelse error.Overflow;
    }

    /// Writes `vec(valtype)` with a canonical count.
    pub fn write(self: *const SignatureValues, writer: *Io.Writer) EncodeError!void {
        try writer.writeLeb128(try self.count());
        switch (self.*) {
            .encoded => |values| try writer.writeAll(values.bytes),
            .typed => |values| for (values) |value| try valtype.write(value, writer),
        }
    }
};

/// Encoded value types plus their count. `fromOneByteEntryValues` is the checked path for the
/// current one-byte subset; direct construction trusts the caller, like raw instruction bytes.
pub const EncodedValues = struct {
    /// Value type bytes only; the vector count is not included.
    bytes: []const u8,
    /// The number of value types in `bytes`. In the current one-byte-only subset this equals
    /// `bytes.len`, but it stays authoritative if multi-byte value types are added.
    value_count: u32,

    /// Wraps the value bytes of a current `types.Entry`, where every value type is one byte. The
    /// entry's usize count already fits in `u32`.
    pub fn fromOneByteEntryValues(bytes: []const u8) EncodedValues {
        return .{ .bytes = bytes, .value_count = @intCast(bytes.len) };
    }
};

/// A function type a plan can add. `fromEntry` copies an existing one without decoding; `typed`
/// builds a new one from value types.
pub const Signature = struct {
    params: SignatureValues = .{ .typed = &.{} },
    results: SignatureValues = .{ .typed = &.{} },

    pub fn fromEntry(entry: Entry) Signature {
        return .{
            .params = .{ .encoded = EncodedValues.fromOneByteEntryValues(entry.params) },
            .results = .{ .encoded = EncodedValues.fromOneByteEntryValues(entry.results) },
        };
    }

    pub fn typed(
        params: []const spec.ValueType,
        results: []const spec.ValueType,
    ) Signature {
        return .{
            .params = .{ .typed = params },
            .results = .{ .typed = results },
        };
    }

    pub fn paramCount(self: *const Signature) EncodeError!u32 {
        return self.params.count();
    }

    pub fn resultCount(self: *const Signature) EncodeError!u32 {
        return self.results.count();
    }
};

/// Decodes a validated value type span. Every byte is exactly one `spec.ValueType`; the reader
/// checked that before handing the span out, so a malformed byte is a caller error here.
pub const Values = struct {
    bytes: []const u8,
    pos: u32 = 0,

    pub fn init(bytes: []const u8) Values {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Values) ?spec.ValueType {
        if (self.pos == self.bytes.len) return null;
        const byte = self.bytes[self.pos];
        self.pos += 1;
        return spec.ValueType.fromByte(byte) orelse unreachable;
    }
};

pub const Iterator = struct {
    cursor: Cursor, // a private copy, positioned at the next type form
    entries: Span, // everything after the count LEB, for verbatim copying
    count: u32,
    yielded: u32 = 0,

    /// The smallest possible entry: a form byte and two empty vectors.
    const entry_len_min = 3;

    /// `payload` is the section's payload window (e.g. from `Module.payloadCursor`). Not modified.
    pub fn init(payload: Cursor) PayloadError!Iterator {
        var cursor = payload;
        const count = cursor.readUleb(u32) catch |err| return fromCursor(err);
        // A tiny payload cannot hold a huge count; checking up front bounds the work.
        if (count > @divFloor(cursor.remaining(), entry_len_min)) return error.Truncated;
        return .{
            .cursor = cursor,
            .entries = .{ .start = cursor.pos, .end = cursor.end },
            .count = count,
        };
    }

    /// The next function type, or null after `count` entries (and only if the payload ends there).
    /// A failed call leaves the iterator where it was.
    pub fn next(self: *Iterator) PayloadError!?Entry {
        assert(self.yielded <= self.count);
        const cursor = &self.cursor;
        if (self.yielded == self.count) {
            if (!cursor.atEnd()) return error.TrailingBytes;
            return null;
        }

        const start = cursor.pos;
        errdefer cursor.pos = start; // a failed call leaves the iterator where it was

        const form = cursor.readByte() catch |err| return fromCursor(err);
        if (form != form_func) {
            for (gc_forms) |gc_form| if (form == gc_form) return error.UnsupportedFeature;
            return error.InvalidValue;
        }
        const params = try takeValues(cursor);
        const results = try takeValues(cursor);

        self.yielded += 1;
        assert(cursor.pos > start);
        return .{ .params = params, .results = results };
    }
};

/// Reads `vec(valtype)` and returns the value type bytes without their count.
fn takeValues(cursor: *Cursor) PayloadError![]const u8 {
    const count = cursor.readUleb(u32) catch |err| return fromCursor(err);
    // A value type is one byte, so a count past the remaining bytes cannot be true.
    if (count > cursor.remaining()) return error.Truncated;
    const start = cursor.pos;
    var i: u32 = 0;
    while (i < count) : (i += 1) _ = try valtype.read(cursor); // validates the byte and advances it
    return cursor.bytes[start..cursor.pos];
}
