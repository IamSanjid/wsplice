//! The `dylink.0` custom-section payload. It is deliberately name-agnostic: callers may use it on
//! a section named "dylink.0" or on any custom name whose data follows the same format.
//!
//! Format (all sizes/counts are LEB u32):
//!   data        ::= subsection*
//!   subsection  ::= kind:u8 size:u32 payload:bytes
//!   kind 1      ::= memory_size memory_alignment_log2 table_size table_alignment_log2
//!   kind 2      ::= vec(name)
//!
//! `Update.write` rewrites mem_info and needed and copies every other subsection byte-for-byte.
//! `Info.write` creates mem_info and an optional needed vector. Neither allocates: both stream to
//! the writer passed by `emit`.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Cursor = @import("../Cursor.zig");
const errors = @import("../errors.zig");
const PayloadError = errors.PayloadError;
const EncodeError = errors.EncodeError;
const fromCursor = errors.fromCursor;

/// The conventional custom-section name. `read`/`write` do not require it.
pub const name = "dylink.0";

/// Dylink subsection kinds. The trailing `_` keeps unknown kinds representable so future kinds can
/// be added without making every switch exhaustive over the old set.
const SubsectionKind = enum(u8) {
    mem_info = 1,
    needed = 2,
    _,
};

pub const MemInfo = struct {
    memory_size: u32 = 0,
    /// The binary stores log2(alignment); keeping it as log2 avoids a lossy conversion.
    memory_alignment_log2: u32 = 0,
    table_size: u32 = 0,
    table_alignment_log2: u32 = 0,
};

/// A validated needed vector borrowed from a custom section.
pub const Needed = struct {
    /// Complete `vec(name)` encoding: count plus every name vector.
    encoded: []const u8,

    /// Number of names in the vector. `encoded` must come from `read`/validation.
    pub fn count(self: Needed) PayloadError!u32 {
        var cursor = try cursorFor(self.encoded);
        return cursor.readUleb(u32) catch |err| return fromCursor(err);
    }

    /// Iterates the names in order. `encoded` must come from `read`/validation.
    pub fn iterator(self: Needed) PayloadError!NeededIter {
        var cursor = try cursorFor(self.encoded);
        const name_count = cursor.readUleb(u32) catch |err| return fromCursor(err);
        return .{ .cursor = cursor, .remaining = name_count };
    }
};

pub const NeededIter = struct {
    cursor: Cursor,
    remaining: u32,

    /// Borrowed name bytes; null after the last entry. Trailing bytes are an error.
    pub fn next(self: *NeededIter) PayloadError!?[]const u8 {
        if (self.remaining == 0) {
            if (!self.cursor.atEnd()) return error.TrailingBytes;
            return null;
        }
        const len = self.cursor.readUleb(u32) catch |err| return fromCursor(err);
        const item = self.cursor.take(len) catch |err| return fromCursor(err);
        self.remaining -= 1;
        return item;
    }
};

/// What to do with the needed subsection. Names and encoded bytes are borrowed until `emit`.
pub const NeededSource = union(enum) {
    /// No needed subsection. In `Info`, omit it; in `Update`, remove it.
    none,
    /// Re-encode this caller-owned list.
    names: []const []const u8,
    /// Complete `vec(name)` encoding, count included. Validated before writing.
    encoded: []const u8,
};

pub const View = struct {
    mem_info: ?MemInfo,
    needed: ?Needed,
    /// Borrowed data, after the custom-section name.
    data: []const u8,
};

/// Reads the known dylink.0 metadata without allocating. Unknown subsections are skipped.
/// Duplicate mem_info or needed subsections are `InvalidValue`; a malformed needed vector is a
/// payload error.
pub fn read(data: []const u8) PayloadError!View {
    var mem_info: ?MemInfo = null;
    var needed: ?Needed = null;
    var cursor = try cursorFor(data);
    while (!cursor.atEnd()) {
        const kind: SubsectionKind = @fromBackingInt(
            cursor.readByte() catch |err| return fromCursor(err),
        );
        const size = cursor.readUleb(u32) catch |err| return fromCursor(err);
        const payload = cursor.take(size) catch |err| return fromCursor(err);
        switch (kind) {
            .mem_info => {
                if (mem_info != null) return error.InvalidValue;
                mem_info = try parseMemInfo(payload);
            },
            .needed => {
                if (needed != null) return error.InvalidValue;
                needed = try parseNeeded(payload);
            },
            _ => {},
        }
    }
    assert(cursor.atEnd());
    return .{ .mem_info = mem_info, .needed = needed, .data = data };
}

/// Changes to an existing dylink.0 section.
pub const Update = struct {
    memory_size: ?u32 = null,
    memory_alignment_log2: ?u32 = null,
    table_size: ?u32 = null,
    table_alignment_log2: ?u32 = null,
    /// null: keep the existing needed subsection. `.none`: remove it. `.names`/`.encoded`:
    /// replace it, appending when the input has no needed subsection.
    needed: ?NeededSource = null,

    /// Streams the updated data after the custom-section name. `original` is required: an update
    /// without an input section is `InvalidValue` (use `Info` to create one).
    pub fn write(self: *const Update, original: ?[]const u8, writer: *Io.Writer) EncodeError!void {
        const data = original orelse return error.InvalidValue;
        var cursor = try cursorFor(data);
        var saw_mem_info = false;
        var saw_needed = false;

        while (!cursor.atEnd()) {
            const start = cursor.pos;
            const kind: SubsectionKind = @fromBackingInt(
                cursor.readByte() catch |err| return fromCursor(err),
            );
            const size = cursor.readUleb(u32) catch |err| return fromCursor(err);
            const payload = cursor.take(size) catch |err| return fromCursor(err);
            assert(start <= cursor.pos);
            assert(cursor.pos <= cursor.end);

            switch (kind) {
                .mem_info => {
                    if (saw_mem_info) return error.InvalidValue;
                    saw_mem_info = true;
                    var info = try parseMemInfo(payload);
                    if (self.memory_size) |value| info.memory_size = value;
                    if (self.memory_alignment_log2) |value| info.memory_alignment_log2 = value;
                    if (self.table_size) |value| info.table_size = value;
                    if (self.table_alignment_log2) |value| info.table_alignment_log2 = value;
                    try writeMemInfoSubsection(info, writer);
                },
                .needed => {
                    if (saw_needed) return error.InvalidValue;
                    saw_needed = true;
                    if (self.needed) |source| {
                        switch (source) {
                            .none => {},
                            .names => |names| try writeNeededNames(names, writer),
                            .encoded => |encoded| try writeNeededEncoded(encoded, writer),
                        }
                    } else {
                        try writer.writeAll(data[start..cursor.pos]);
                    }
                },
                _ => try writer.writeAll(data[start..cursor.pos]),
            }
        }

        if (!saw_mem_info) return error.InvalidValue;
        if (!saw_needed) {
            if (self.needed) |source| switch (source) {
                .none => {},
                .names => |names| try writeNeededNames(names, writer),
                .encoded => |encoded| try writeNeededEncoded(encoded, writer),
            };
        }
        assert(cursor.atEnd());
    }
};

/// A new dylink.0 payload: mem_info and an optional needed vector.
pub const Info = struct {
    mem_info: MemInfo = .{},
    /// `.none` omits the needed subsection. `.names`/`.encoded` create it.
    needed: NeededSource = .none,

    /// Streams new data after the custom-section name. `original` is unused; this is the append
    /// source. Names and encoded bytes are borrowed and must outlive `emit`.
    pub fn write(self: *const Info, original: ?[]const u8, writer: *Io.Writer) EncodeError!void {
        _ = original;
        try writeMemInfoSubsection(self.mem_info, writer);
        switch (self.needed) {
            .none => {},
            .names => |names| try writeNeededNames(names, writer),
            .encoded => |encoded| try writeNeededEncoded(encoded, writer),
        }
    }
};

fn cursorFor(data: []const u8) PayloadError!Cursor {
    const len = std.math.cast(u32, data.len) orelse return error.InvalidValue;
    return .{ .bytes = data, .pos = 0, .end = len };
}

fn parseMemInfo(payload: []const u8) PayloadError!MemInfo {
    var cursor = try cursorFor(payload);
    const info: MemInfo = .{
        .memory_size = cursor.readUleb(u32) catch |err| return fromCursor(err),
        .memory_alignment_log2 = cursor.readUleb(u32) catch |err| return fromCursor(err),
        .table_size = cursor.readUleb(u32) catch |err| return fromCursor(err),
        .table_alignment_log2 = cursor.readUleb(u32) catch |err| return fromCursor(err),
    };
    if (!cursor.atEnd()) return error.TrailingBytes;
    if (info.memory_alignment_log2 > 31 or info.table_alignment_log2 > 31)
        return error.InvalidValue;
    return info;
}

fn parseNeeded(payload: []const u8) PayloadError!Needed {
    var cursor = try cursorFor(payload);
    const count = cursor.readUleb(u32) catch |err| return fromCursor(err);
    const entries_start = cursor.pos;
    var remaining = count;
    while (remaining != 0) : (remaining -= 1) {
        const len = cursor.readUleb(u32) catch |err| return fromCursor(err);
        _ = cursor.take(len) catch |err| return fromCursor(err);
    }
    if (!cursor.atEnd()) return error.TrailingBytes;
    assert(entries_start <= payload.len);
    assert(cursor.atEnd());
    return .{ .encoded = payload };
}

fn checkMemInfo(info: MemInfo) PayloadError!void {
    if (info.memory_alignment_log2 > 31 or info.table_alignment_log2 > 31)
        return error.InvalidValue;
}

fn writeMemInfo(info: MemInfo, writer: *Io.Writer) EncodeError!void {
    try checkMemInfo(info);
    try writer.writeLeb128(info.memory_size);
    try writer.writeLeb128(info.memory_alignment_log2);
    try writer.writeLeb128(info.table_size);
    try writer.writeLeb128(info.table_alignment_log2);
}

fn writeMemInfoSubsection(info: MemInfo, writer: *Io.Writer) EncodeError!void {
    var buf: [20]u8 = undefined; // four u32 LEBs are at most 20 bytes
    var counter: Io.Writer = .fixed(&buf);
    try writeMemInfo(info, &counter);
    try writeSubsection(writer, .mem_info, counter.buffered());
}

fn writeSubsection(writer: *Io.Writer, kind: SubsectionKind, payload: []const u8) EncodeError!void {
    assert(payload.len <= std.math.maxInt(u32));
    try writer.writeByte(@backingInt(kind));
    try writer.writeLeb128(std.math.cast(u32, payload.len) orelse return error.Overflow);
    try writer.writeAll(payload);
}

fn writeNeededNames(names: []const []const u8, writer: *Io.Writer) EncodeError!void {
    const count = std.math.cast(u32, names.len) orelse return error.Overflow;
    const payload_len = try neededPayloadLen(names);
    try writer.writeByte(@backingInt(@as(SubsectionKind, .needed)));
    try writer.writeLeb128(payload_len);
    try writer.writeLeb128(count);
    for (names) |item| {
        const item_len = std.math.cast(u32, item.len) orelse return error.Overflow;
        try writer.writeLeb128(item_len);
        try writer.writeAll(item);
    }
}

fn writeNeededEncoded(encoded: []const u8, writer: *Io.Writer) EncodeError!void {
    _ = try parseNeeded(encoded); // validate before writing
    try writeSubsection(writer, .needed, encoded);
}

fn neededPayloadLen(names: []const []const u8) EncodeError!u32 {
    assert(names.len <= std.math.maxInt(u32));
    var total: u64 = lebLen(std.math.cast(u32, names.len) orelse return error.Overflow);
    for (names) |item| {
        const item_len = std.math.cast(u32, item.len) orelse return error.Overflow;
        total += lebLen(item_len) + item_len;
    }
    return std.math.cast(u32, total) orelse error.Overflow;
}

fn lebLen(value: u32) u32 {
    var remaining = value;
    var len: u32 = 1;
    while (remaining >= 0x80) : (remaining >>= 7) len += 1;
    return len;
}

const testing = std.testing;

const mem_info_only = [_]u8{ 1, 4, 1, 2, 3, 4 };
const needed_section = [_]u8{ 2, 6, 2, 1, 'a', 2, 'b', 'c' };
const needed_encoded = [_]u8{ 2, 1, 'a', 2, 'b', 'c' };

test "dylink: read mem_info and needed" {
    const data = mem_info_only ++ needed_section;
    const view = try read(&data);
    const info = view.mem_info.?;
    try testing.expectEqual(@as(u32, 1), info.memory_size);
    try testing.expectEqual(@as(u32, 2), info.memory_alignment_log2);
    try testing.expectEqual(@as(u32, 3), info.table_size);
    try testing.expectEqual(@as(u32, 4), info.table_alignment_log2);

    const needed = view.needed.?;
    try testing.expectEqual(@as(u32, 2), try needed.count());
    try testing.expectEqualSlices(u8, &needed_encoded, needed.encoded);
    var iterator = try needed.iterator();
    try testing.expectEqualStrings("a", (try iterator.next()).?);
    try testing.expectEqualStrings("bc", (try iterator.next()).?);
    try testing.expectEqual(@as(?[]const u8, null), try iterator.next());
}

test "dylink: duplicate mem_info or needed is invalid" {
    const duplicate_mem = mem_info_only ++ mem_info_only;
    try testing.expectError(error.InvalidValue, read(&duplicate_mem));

    const empty_needed = [_]u8{ 2, 1, 0 };
    const duplicate_needed = mem_info_only ++ empty_needed ++ empty_needed;
    try testing.expectError(error.InvalidValue, read(&duplicate_needed));
}

test "dylink: a malformed needed vector is a payload error" {
    const truncated = [_]u8{ 1, 4, 1, 2, 3, 4, 2, 2, 2 };
    try testing.expectError(error.Truncated, read(&truncated));
}

test "dylink: update rewrites mem_info and preserves needed and unknown subsections" {
    const original = mem_info_only ++
        needed_section ++
        [_]u8{ 9, 2, 0xAA, 0xBB };
    var update: Update = .{ .memory_size = 9 };
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try update.write(&original, &out.writer);
    try testing.expectEqualSlices(
        u8,
        &([_]u8{ 1, 4, 9, 2, 3, 4 } ++ needed_section ++ [_]u8{ 9, 2, 0xAA, 0xBB }),
        out.written(),
    );
}

test "dylink: update can clear the needed subsection" {
    const original = mem_info_only ++ needed_section;
    var update: Update = .{ .needed = .none };
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try update.write(&original, &out.writer);
    try testing.expectEqualSlices(u8, &mem_info_only, out.written());
}

test "dylink: update can replace needed with names" {
    const original = mem_info_only ++ needed_section;
    const names = [_][]const u8{ "x", "yz" };
    var update: Update = .{ .needed = .{ .names = &names } };
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try update.write(&original, &out.writer);
    try testing.expectEqualSlices(
        u8,
        &(mem_info_only ++ [_]u8{ 2, 6, 2, 1, 'x', 2, 'y', 'z' }),
        out.written(),
    );
}

test "dylink: update can copy encoded needed and append it when absent" {
    const encoded = [_]u8{ 1, 1, 'q' };
    var update: Update = .{ .needed = .{ .encoded = &encoded } };
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try update.write(&mem_info_only, &out.writer);
    try testing.expectEqualSlices(
        u8,
        &(mem_info_only ++ [_]u8{ 2, 3, 1, 1, 'q' }),
        out.written(),
    );
}

test "dylink: invalid encoded needed is rejected" {
    var update: Update = .{ .needed = .{ .encoded = &.{} } };
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.Truncated, update.write(&mem_info_only, &out.writer));
}

test "dylink: update requires an existing mem_info" {
    var update: Update = .{ .memory_size = 1 };
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.InvalidValue, update.write(&.{}, &out.writer));
    try testing.expectError(error.InvalidValue, update.write(null, &out.writer));
}

test "dylink: Info can omit needed" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var omitted: Info = .{ .mem_info = .{ .memory_size = 1 } };
    try omitted.write(null, &out.writer);
    try testing.expectEqualSlices(u8, &.{ 1, 4, 1, 0, 0, 0 }, out.written());
}

test "dylink: Info creates names and encoded needed" {
    var names_out: Io.Writer.Allocating = .init(testing.allocator);
    defer names_out.deinit();
    var named: Info = .{
        .needed = .{ .names = &.{ "a", "bc" } },
    };
    try named.write(null, &names_out.writer);
    try testing.expectEqualSlices(
        u8,
        &(mem_info_zero() ++ needed_section),
        names_out.written(),
    );

    var encoded_out: Io.Writer.Allocating = .init(testing.allocator);
    defer encoded_out.deinit();
    var encoded: Info = .{ .needed = .{ .encoded = &needed_encoded } };
    try encoded.write(null, &encoded_out.writer);
    try testing.expectEqualSlices(
        u8,
        &(mem_info_zero() ++ needed_section),
        encoded_out.written(),
    );
}

fn mem_info_zero() [6]u8 {
    return .{ 1, 4, 0, 0, 0, 0 };
}
