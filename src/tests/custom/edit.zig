//! Tests for custom-section appends and replacements.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const Builder = @import("../../Builder.zig");
const Module = @import("../../Module.zig");
const emit_mod = @import("../../emit.zig");
const errors = @import("../../errors.zig");
const t = @import("../support.zig");

const one_type = t.sec(1, &.{ 1, 0x60, 0, 0 });

const Rewrite = struct {
    suffix: []const u8,

    pub fn write(
        self: *const Rewrite,
        original: ?[]const u8,
        writer: *Io.Writer,
    ) errors.EncodeError!void {
        try writer.writeAll(original.?);
        try writer.writeAll(self.suffix);
    }
};

test "custom edit: append at the end, after an existing custom section" {
    const input = t.header ++ one_type ++ t.sec(0, &.{ 1, 'x', 0xAA });
    const expected = input ++ t.sec(0, &.{ 1, 'y', 0xBB });

    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.addCustomSection(testing.allocator, .end, "y", .{ .bytes = &.{0xBB} });
    const patch = try builder.patch();
    try t.expectEmit(&input, &patch, &expected);
}

test "custom edit: append at the start" {
    const input = t.header ++ one_type;
    const expected = t.header ++ t.sec(0, &.{ 1, 'y', 0xCC }) ++ one_type;

    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.addCustomSection(testing.allocator, .start, "y", .{ .bytes = &.{0xCC} });
    const patch = try builder.patch();
    try t.expectEmit(&input, &patch, &expected);
}

test "custom edit: replace the second occurrence and preserve its position" {
    const input = t.header ++
        t.sec(0, &.{ 1, 'x', 0xAA }) ++
        one_type ++
        t.sec(0, &.{ 1, 'x', 0xBB });
    const expected = t.header ++
        t.sec(0, &.{ 1, 'x', 0xAA }) ++
        one_type ++
        t.sec(0, &.{ 1, 'x', 0xCC });

    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.setCustomSection(testing.allocator, "x", 1, .{ .bytes = &.{0xCC} });
    const patch = try builder.patch();
    try t.expectEmit(&input, &patch, &expected);
}

test "custom edit: a streaming source receives the original data" {
    const input = t.header ++ t.sec(0, &.{ 1, 'x', 'a', 'b' });
    const expected = t.header ++ t.sec(0, &.{ 1, 'x', 'a', 'b', '!' });

    var rewrite: Rewrite = .{ .suffix = "!" };
    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.setCustomSection(testing.allocator, "x", 0, .from(&rewrite));
    const patch = try builder.patch();
    try t.expectEmit(&input, &patch, &expected);
}

test "custom edit: duplicate replacement selector fails at build time" {
    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.setCustomSection(testing.allocator, "x", 0, .{ .bytes = "" });
    try testing.expectError(
        error.DuplicateCustomSection,
        builder.setCustomSection(testing.allocator, "x", 0, .{ .bytes = "" }),
    );
}

test "custom edit: remove the second occurrence" {
    const input = t.header ++
        t.sec(0, &.{ 1, 'x', 0xAA }) ++
        one_type ++
        t.sec(0, &.{ 1, 'x', 0xBB });
    const expected = t.header ++ t.sec(0, &.{ 1, 'x', 0xAA }) ++ one_type;

    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.removeCustomSection(testing.allocator, "x", 1);
    const patch = try builder.patch();
    try t.expectEmit(&input, &patch, &expected);
}

test "custom edit: remove the first occurrence" {
    const input = t.header ++
        t.sec(0, &.{ 1, 'x', 0xAA }) ++
        one_type ++
        t.sec(0, &.{ 1, 'x', 0xBB });
    const expected = t.header ++ one_type ++ t.sec(0, &.{ 1, 'x', 0xBB });

    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.removeCustomSection(testing.allocator, "x", 0);
    const patch = try builder.patch();
    try t.expectEmit(&input, &patch, &expected);
}

test "custom edit: remove every occurrence with input-relative selectors" {
    const input = t.header ++
        t.sec(0, &.{ 1, 'x', 0xAA }) ++
        one_type ++
        t.sec(0, &.{ 1, 'x', 0xBB });
    const expected = t.header ++ one_type;

    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.removeCustomSection(testing.allocator, "x", 0);
    try builder.removeCustomSection(testing.allocator, "x", 1);
    const patch = try builder.patch();
    try t.expectEmit(&input, &patch, &expected);
}

test "custom edit: remove and append the same name are independent" {
    const input = t.header ++ t.sec(0, &.{ 1, 'x', 0xAA });
    const expected = t.header ++ t.sec(0, &.{ 1, 'x', 0xBB });

    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.removeCustomSection(testing.allocator, "x", 0);
    try builder.addCustomSection(testing.allocator, .end, "x", .{ .bytes = &.{0xBB} });
    const patch = try builder.patch();
    try t.expectEmit(&input, &patch, &expected);
}

test "custom edit: replace and remove cannot share a selector" {
    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.setCustomSection(testing.allocator, "x", 0, .{ .bytes = "" });
    try testing.expectError(
        error.DuplicateCustomSection,
        builder.removeCustomSection(testing.allocator, "x", 0),
    );
}

test "custom edit: an unknown remove selector fails at emit" {
    const input = t.header;
    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.removeCustomSection(testing.allocator, "missing", 0);
    const patch = try builder.patch();

    const m = try Module.parse(&input);
    try testing.expectError(
        error.UnknownCustomSection,
        emit_mod.outputLen(&m, &patch, .{}),
    );
}

test "custom edit: an unknown replacement selector fails at emit" {
    const input = t.header;
    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.setCustomSection(testing.allocator, "missing", 0, .{ .bytes = "" });
    const patch = try builder.patch();

    const m = try Module.parse(&input);
    try testing.expectError(
        error.UnknownCustomSection,
        emit_mod.outputLen(&m, &patch, .{}),
    );
}
