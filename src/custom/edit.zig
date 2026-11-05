//! Custom-section edits. A custom section can repeat and has no rank, so these edits live in
//! `Patch.custom` instead of a `SectionId` slot. The source is either bytes already known or a
//! streaming rewriter; nothing here allocates or materializes the replacement payload.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const errors = @import("../errors.zig");
const EncodeError = errors.EncodeError;

/// Where a new custom section goes. Custom sections can appear anywhere; these are the two
/// placements the first version supports.
pub const Placement = enum { start, end };

/// Selects an input custom section by exact name bytes and 0-based occurrence in input file order.
/// `name` is borrowed until `emit`. Occurrences are input-relative: removing an earlier section
/// does not renumber later selections.
pub const Selector = struct {
    name: []const u8,
    occurrence: u32 = 0,

    pub fn eql(a: *const Selector, b: *const Selector) bool {
        return a.occurrence == b.occurrence and std.mem.eql(u8, a.name, b.name);
    }
};

/// Type-erased streaming writer for custom-section data (everything after the name vector).
pub const Rewriter = struct {
    context: *const anyopaque,
    function: *const fn (
        context: *const anyopaque,
        original: ?[]const u8,
        writer: *Io.Writer,
    ) EncodeError!void,

    /// Erases `context` to the stored function pointer. `context` must be `*const T`, and the
    /// pointed-to value must outlive `emit` at a stable address.
    pub fn from(context: anytype) Rewriter {
        const info = @typeInfo(@TypeOf(context));
        if (info != .pointer) @compileError("Rewriter.from takes a pointer: pass &.value");
        const Context = info.pointer.child;
        return .{
            .context = @ptrCast(context),
            .function = struct {
                fn shim(
                    erased: *const anyopaque,
                    original: ?[]const u8,
                    writer: *Io.Writer,
                ) EncodeError!void {
                    const self: *const Context = @ptrCast(@alignCast(erased));
                    return self.write(original, writer);
                }
            }.shim,
        };
    }

    fn write(self: Rewriter, original: ?[]const u8, writer: *Io.Writer) EncodeError!void {
        return self.function(self.context, original, writer);
    }
};

/// The data after a custom section's name. `bytes` is for a payload known at plan time;
/// `rewrite` streams one and receives the original data for a replacement or null for an append.
/// Bytes and rewriter contexts are borrowed until `emit` returns; a context must have a stable
/// address.
pub const Source = union(enum) {
    bytes: []const u8,
    rewrite: Rewriter,

    /// A source that streams through `context.write(original, writer)`.
    pub fn from(context: anytype) Source {
        return .{ .rewrite = Rewriter.from(context) };
    }

    pub fn write(self: *const Source, original: ?[]const u8, writer: *Io.Writer) EncodeError!void {
        switch (self.*) {
            .bytes => |bytes| try writer.writeAll(bytes),
            .rewrite => |rewriter| try rewriter.write(original, writer),
        }
    }

    /// Size of the data only, not the custom-section name or header.
    pub fn encodedLen(self: *const Source, original: ?[]const u8) EncodeError!u32 {
        return switch (self.*) {
            .bytes => |bytes| std.math.cast(u32, bytes.len) orelse error.Overflow,
            .rewrite => |rewriter| {
                var counter = Io.Writer.Discarding.init(&.{});
                try rewriter.write(original, &counter.writer);
                return std.math.cast(u32, counter.fullCount()) orelse error.Overflow;
            },
        };
    }
};

/// One custom-section edit. Names, sources and rewriter contexts are borrowed until `emit`.
pub const Edit = union(enum) {
    append: struct {
        placement: Placement,
        /// Borrowed until `emit`.
        name: []const u8,
        source: Source,
    },
    replace: struct {
        selector: Selector,
        source: Source,
    },
    /// Deletes the selected input custom section, including its id byte, size LEB, name and data.
    /// A replacement with an empty source would leave an empty section behind; this does not.
    remove: Selector,
};

/// Encoded size of a custom-section payload: name vector plus source data.
pub fn payloadLen(
    name: []const u8,
    source: *const Source,
    original: ?[]const u8,
) EncodeError!u32 {
    assert(name.len <= std.math.maxInt(u32));
    const name_len: u32 = @intCast(name.len);
    const data_len = try source.encodedLen(original);
    const total: u64 = lebLen(name_len) + name_len + data_len;
    return std.math.cast(u32, total) orelse error.Overflow;
}

fn lebLen(value: u32) u32 {
    var remaining = value;
    var len: u32 = 1;
    while (remaining >= 0x80) : (remaining >>= 7) len += 1;
    return len;
}

/// Writes a custom-section payload, including the name vector.
pub fn writePayload(
    name: []const u8,
    source: *const Source,
    original: ?[]const u8,
    writer: *Io.Writer,
) EncodeError!void {
    assert(name.len <= std.math.maxInt(u32));
    try writer.writeLeb128(@as(u32, @intCast(name.len)));
    try writer.writeAll(name);
    try source.write(original, writer);
}

const testing = std.testing;

test "CustomSections: bytes source writes payload and agrees with payloadLen" {
    const source: Source = .{ .bytes = &.{ 1, 2, 3 } };
    var buf: [32]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try writePayload("abc", &source, null, &writer);
    try testing.expectEqualSlices(u8, &.{ 3, 'a', 'b', 'c', 1, 2, 3 }, writer.buffered());
    try testing.expectEqual(@as(u32, 3), try source.encodedLen(null));
    try testing.expectEqual(
        @as(u32, @intCast(writer.buffered().len)),
        try payloadLen("abc", &source, null),
    );
}

test "CustomSections: rewrite source sees the original and writes a stream" {
    const Ctx = struct {
        suffix: []const u8,

        pub fn write(
            _: *const @This(),
            original: ?[]const u8,
            writer: *Io.Writer,
        ) EncodeError!void {
            try writer.writeAll(original.?);
            try writer.writeAll("!");
        }
    };
    var context: Ctx = .{ .suffix = "ignored" };
    const source: Source = .from(&context);
    try testing.expectEqual(@as(u32, 4), try source.encodedLen("abc"));
}
