//! Writes `bytes` as the payload. No section id, no size prefix.

const std = @import("std");
const Io = std.Io;

const Module = @import("../Module.zig");

const EncodeError = @import("../errors.zig").EncodeError;
const Options = @import("../Options.zig");
const Plan = @import("../Plan.zig");

const spec = @import("../spec.zig");

bytes: []const u8,

const Raw = @This();

pub fn encode(
    self: *const Raw,
    module: *const Module,
    plan: *const Plan,
    writer: *Io.Writer,
    options: Options,
) EncodeError!void {
    _ = module; // unused
    _ = plan; // unused: raw bytes are not remapped
    _ = options; // unused
    return writer.writeAll(self.bytes);
}

const header_only = if (@import("builtin").is_test)
    spec.magic ++ spec.version
else
    @compileError("Should be accessed only in tests.");

const test_plan: Plan = .{};

test "Raw: writes exactly its bytes, with no id or size prefix" {
    const m = try Module.parse(&header_only);
    var buf: [8]u8 = @splat(0xEE);
    var w: Io.Writer = .fixed(&buf);

    const raw: Raw = .{ .bytes = "abc" };
    try raw.encode(&m, &test_plan, &w, .{});

    try std.testing.expectEqualSlices(u8, "abc", w.buffered());
    // nothing past the payload was touched
    try std.testing.expectEqualSlices(u8, &(@as([5]u8, @splat(0xEE))), buf[3..]);
}

test "Raw: empty payload writes nothing, even to a zero-capacity writer" {
    const m = try Module.parse(&header_only);
    var buf: [0]u8 = .{};
    var w: Io.Writer = .fixed(&buf);

    const raw: Raw = .{ .bytes = "" };
    try raw.encode(&m, &test_plan, &w, .{});
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "Raw: exact-fit writer succeeds, one byte short fails with WriteFailed" {
    const m = try Module.parse(&header_only);
    const raw: Raw = .{ .bytes = "abc" };

    var fit: [3]u8 = undefined;
    var w_fit: Io.Writer = .fixed(&fit);
    try raw.encode(&m, &test_plan, &w_fit, .{});
    try std.testing.expectEqualSlices(u8, "abc", w_fit.buffered());

    var short: [2]u8 = undefined;
    var w_short: Io.Writer = .fixed(&short);
    try std.testing.expectError(error.WriteFailed, raw.encode(&m, &test_plan, &w_short, .{}));
}

test "Raw: every byte value passes through unchanged" {
    const m = try Module.parse(&header_only);
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);

    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const raw: Raw = .{ .bytes = &all };
    try raw.encode(&m, &test_plan, &w, .{});
    try std.testing.expectEqualSlices(u8, &all, w.buffered());
}

test "Raw: large payload (crosses the 2- and 3-byte size LEB boundaries)" {
    const m = try Module.parse(&header_only);
    const src = try std.testing.allocator.alloc(u8, 70_000);
    defer std.testing.allocator.free(src);
    for (src, 0..) |*b, i| b.* = @truncate(i *% 31);

    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const raw: Raw = .{ .bytes = src };
    try raw.encode(&m, &test_plan, &aw.writer, .{});
    try std.testing.expectEqualSlices(u8, src, aw.written());
}

test "Raw: output does not depend on the module" {
    const with_section = header_only ++ [_]u8{ 1, 1, 0xAA };
    const m1 = try Module.parse(&header_only);
    const m2 = try Module.parse(&with_section);

    const raw: Raw = .{ .bytes = "payload" };
    var buf1: [16]u8 = undefined;
    var buf2: [16]u8 = undefined;
    var w1: Io.Writer = .fixed(&buf1);
    var w2: Io.Writer = .fixed(&buf2);
    try raw.encode(&m1, &test_plan, &w1, .{});
    try raw.encode(&m2, &test_plan, &w2, .{});
    try std.testing.expectEqualSlices(u8, w1.buffered(), w2.buffered());
}

test "Raw: borrows its bytes, so the caller must keep them alive until emit" {
    const m = try Module.parse(&header_only);
    var src = [_]u8{ 1, 2, 3 };
    const raw: Raw = .{ .bytes = &src };

    src[1] = 9; // changed after construction, before encoding
    var buf: [3]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try raw.encode(&m, &test_plan, &w, .{});
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 9, 3 }, w.buffered());
}
