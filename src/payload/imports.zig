//! Reader for the import section payload. Borrows the bytes it reads; allocates nothing.
const std = @import("std");
const assert = std.debug.assert;

const Cursor = @import("../Cursor.zig");
const spec = @import("../spec.zig");
const Span = @import("../section.zig").Span;
const read_limits = @import("limits.zig").read;
const globals = @import("globals.zig");
const tables = @import("tables.zig");
const valtype = @import("valtype.zig");
const errors = @import("../errors.zig");
const PayloadError = errors.PayloadError;
const fromCursor = errors.fromCursor;

/// Table and global descriptors reuse the typed payload shapes. `valtype.zig` is the only reader of
/// their encoding, so a type accepted here is one the rest of the library knows.
pub const Table = tables.Type;
pub const Global = globals.Type;

pub const Desc = union(spec.ExternalKind) {
    function: u32, // type index
    table: Table,
    memory: spec.Limits,
    global: Global,
    tag: u32, // type index
};

pub const Entry = struct {
    module: []const u8, // raw bytes, borrowed from the module; not checked for UTF-8
    field: []const u8,
    desc: Desc,
};

pub const Iterator = struct {
    cursor: Cursor, // a private copy, positioned at the next entry
    entries: Span, // everything after the count LEB, for verbatim copying
    count: u32,
    yielded: u32 = 0,

    /// The smallest possible entry: two empty names, a kind byte and a one-byte type index.
    const entry_len_min = 4;

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

    /// The next entry, or null after `count` entries; trailing bytes are an error.
    pub fn next(self: *Iterator) PayloadError!?Entry {
        assert(self.yielded <= self.count);
        const cursor = &self.cursor;
        if (self.yielded == self.count) {
            if (!cursor.atEnd()) return error.TrailingBytes;
            return null;
        }

        const start = cursor.pos;
        errdefer cursor.pos = start;

        const module = try readName(cursor);
        const field = try readName(cursor);
        const kind_byte = cursor.readByte() catch |err| return fromCursor(err);
        const kind = std.enums.fromInt(spec.ExternalKind, kind_byte) orelse
            return error.InvalidKind;
        const desc = try readDesc(cursor, kind);

        self.yielded += 1;
        assert(cursor.pos > start);
        return .{
            .module = module,
            .field = field,
            .desc = desc,
        };
    }
};

fn readName(cursor: *Cursor) PayloadError![]const u8 {
    const len = cursor.readUleb(u32) catch |err| return fromCursor(err);
    return cursor.take(len) catch |err| return fromCursor(err);
}

fn readByte(cursor: *Cursor) PayloadError!u8 {
    return cursor.readByte() catch |err| fromCursor(err);
}

fn readDesc(cursor: *Cursor, kind: spec.ExternalKind) PayloadError!Desc {
    switch (kind) {
        .function => {
            return .{ .function = cursor.readUleb(u32) catch |err| return fromCursor(err) };
        },
        .table => {
            return .{
                .table = .{
                    .reftype = try valtype.readReference(cursor),
                    .limits = try read_limits(cursor),
                },
            };
        },
        .memory => return .{ .memory = try read_limits(cursor) },
        .global => {
            const value_type = try valtype.read(cursor);
            const mutability = std.enums.fromInt(spec.Mutability, try readByte(cursor)) orelse
                return error.InvalidValue;
            return .{
                .global = .{
                    .valtype = value_type,
                    .mutability = mutability,
                },
            };
        },
        .tag => {
            // The attribute byte: only 0 (exception) exists.
            if (try readByte(cursor) != 0) return error.InvalidValue;
            return .{ .tag = cursor.readUleb(u32) catch |err| return fromCursor(err) };
        },
    }
}
