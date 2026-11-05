//! The first failure, as plain data owned by the caller and recorded by `record`/`fail`.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const SectionId = @import("spec.zig").SectionId;
const IndexSpace = @import("spec.zig").IndexSpace;

err: ?anyerror = null, // set means a failure was recorded and returned
section: ?SectionId = null,
offset: ?u32 = null,
/// The owning function's final index, a locator like `section`/`offset`; null outside a body.
function: ?u32 = null,
detail: Detail = .none,
name_truncated: bool = false,
name_len: u8 = 0,
name_buf: [name_len_max]u8 = @splat(0),

/// The error's numbers, not its location: `Where` carries the section, offset and owning function.
pub const Detail = union(enum) {
    none,
    /// An index outside its space; valid values are 0..limit-1.
    out_of_range: struct {
        space: IndexSpace,
        value: u32,
        limit: u32,
    },
    /// An added function without a body, by its appended ordinal. Plan-time failures have no input
    /// location; this is the entity they are about.
    missing_body: struct {
        ordinal: u32,
    },
    /// Which custom section a selector named. The name itself is in `Where.name`.
    custom_section: struct {
        occurrence: u32,
    },
};

const Diagnostics = @This();

pub const name_len_max = 64;

comptime {
    assert(name_len_max <= std.math.maxInt(u8)); // name_len is a u8
    assert(@sizeOf(Diagnostics) <= 128); // cheap to keep on the stack
}

pub const Where = struct {
    section: ?SectionId = null,
    offset: ?u32 = null,
    /// The owning function's final index, a locator like `section`/`offset`; null outside a body.
    function: ?u32 = null,
    detail: Detail = .none,
    /// A name from the plan (e.g. an export): copied, truncated to `name_len_max`.
    name: []const u8 = "",
};

/// First failure wins: a failure can unwind through several layers, and only the
/// innermost one knows the real cause. Accepts null so call sites need no `if`.
pub fn record(maybe: ?*Diagnostics, err: anyerror, where: Where) void {
    const self = maybe orelse return;
    self.assertInvariants();
    if (self.err != null) return;

    const n: u8 = @intCast(@min(where.name.len, name_len_max));
    @memcpy(self.name_buf[0..n], where.name[0..n]);

    self.err = err;
    self.section = where.section;
    self.offset = where.offset;
    self.function = where.function;
    self.detail = where.detail;
    self.name_len = n;
    self.name_truncated = where.name.len > name_len_max;

    assert(self.err != null);
    self.assertInvariants();
}

/// Records `err` and returns it, so a failure site reads:
///     return Diagnostics.fail(ctx.diag, error.IndexOutOfRange, .{ .section = .code });
pub fn fail(maybe: ?*Diagnostics, err: anytype, where: Where) @TypeOf(err) {
    comptime assert(@typeInfo(@TypeOf(err)) == .error_set);
    record(maybe, err, where);
    return err;
}

pub fn hasFailure(self: *const Diagnostics) bool {
    return self.err != null;
}

/// Raw bytes, not a C string: embedded zeros are preserved, and valid UTF-8 is not guaranteed.
pub fn name(self: *const Diagnostics) []const u8 {
    return self.name_buf[0..self.name_len];
}

pub fn reset(self: *Diagnostics) void {
    self.* = .{};
}

pub fn format(self: *const Diagnostics, w: *Io.Writer) Io.Writer.Error!void {
    const err = self.err orelse return w.writeAll("no failure recorded");
    try w.writeAll(@errorName(err));
    if (self.section) |section| try w.print(" in {s} section", .{@tagName(section)});
    if (self.name_len > 0) {
        try w.print(", name \"{s}\"{s}", .{ self.name(), if (self.name_truncated) "..." else "" });
    }
    if (self.function) |function| try w.print(", function {d}", .{function});
    if (self.offset) |offset| try w.print(", at byte 0x{x}", .{offset});
    switch (self.detail) {
        .none => {},
        .out_of_range => |detail| try w.print(
            " ({s} index {d}, but only {d} exist)",
            .{ @tagName(detail.space), detail.value, detail.limit },
        ),
        .missing_body => |detail| try w.print(
            " (added function {d} has no body)",
            .{detail.ordinal},
        ),
        .custom_section => |detail| try w.print(
            " (custom section occurrence {d})",
            .{detail.occurrence},
        ),
    }
}

fn assertInvariants(self: *const Diagnostics) void {
    assert(self.name_len <= name_len_max);
    if (self.err == null) {
        assert(self.section == null);
        assert(self.offset == null);
        assert(self.function == null);
        assert(self.detail == .none);
        if (!self.name_truncated) {
            assert(self.name_len == 0);
        }
    }
}

test "Diagnostics: fresh value has no failure" {
    const d: Diagnostics = .{};
    try std.testing.expect(!d.hasFailure());
    try std.testing.expectEqual(@as(?anyerror, null), d.err);
    try std.testing.expectEqual(null, d.section);
    try std.testing.expectEqual(@as(usize, 0), d.name().len);
}

test "Diagnostics: record stores every field" {
    var d: Diagnostics = .{};
    Diagnostics.record(&d, error.DuplicateExportName, .{
        .section = .@"export",
        .offset = 0x3c,
        .name = "add",
    });
    try std.testing.expect(d.hasFailure());
    try std.testing.expectEqual(@as(?anyerror, error.DuplicateExportName), d.err);
    try std.testing.expectEqual(@as(?SectionId, .@"export"), d.section);
    try std.testing.expectEqual(@as(?u32, 0x3c), d.offset);
    try std.testing.expectEqualStrings("add", d.name());
    try std.testing.expect(!d.name_truncated);
}

test "Diagnostics: the first failure wins, including its error" {
    var d: Diagnostics = .{};
    Diagnostics.record(&d, error.First, .{ .section = .code, .name = "first" });
    const snapshot = d;
    Diagnostics.record(&d, error.Second, .{ .section = .data, .offset = 99, .name = "second" });
    try std.testing.expectEqualDeep(snapshot, d);
    try std.testing.expectEqual(@as(?anyerror, error.First), d.err);
}

test "Diagnostics: record with null is a no-op" {
    Diagnostics.record(null, error.Anything, .{ .section = .code });
}

test "Diagnostics: an error alone is a failure" {
    var d: Diagnostics = .{};
    Diagnostics.record(&d, error.Truncated, .{});
    try std.testing.expect(d.hasFailure());
    try std.testing.expectEqual(null, d.section);
    try std.testing.expectEqual(@as(usize, 0), d.name().len);
}

test "Diagnostics: name truncation at the boundary" {
    const exact: [name_len_max]u8 = @splat('a');
    const over: [name_len_max + 1]u8 = @splat('b');

    var d1: Diagnostics = .{};
    Diagnostics.record(&d1, error.E, .{ .name = &exact });
    try std.testing.expectEqualStrings(&exact, d1.name());
    try std.testing.expect(!d1.name_truncated);

    var d2: Diagnostics = .{};
    Diagnostics.record(&d2, error.E, .{ .name = &over });
    try std.testing.expectEqualStrings(over[0..name_len_max], d2.name());
    try std.testing.expect(d2.name_truncated);
}

test "Diagnostics: names are bytes, so embedded zeros survive" {
    var d: Diagnostics = .{};
    Diagnostics.record(&d, error.E, .{ .name = "a\x00b" });
    try std.testing.expectEqualSlices(u8, "a\x00b", d.name());
}

test "Diagnostics: reset allows a new failure" {
    var d: Diagnostics = .{};
    Diagnostics.record(&d, error.Old, .{ .section = .code, .name = "x" });
    d.reset();
    try std.testing.expect(!d.hasFailure());
    Diagnostics.record(&d, error.New, .{ .section = .data });
    try std.testing.expectEqual(@as(?anyerror, error.New), d.err);
    try std.testing.expectEqual(@as(usize, 0), d.name().len);
}

test "Diagnostics: format" {
    var buf: [128]u8 = undefined;

    var d: Diagnostics = .{};
    var w0: Io.Writer = .fixed(&buf);
    try d.format(&w0);
    try std.testing.expectEqualStrings("no failure recorded", w0.buffered());

    Diagnostics.record(&d, error.DuplicateExportName, .{
        .section = .@"export",
        .offset = 0x3c,
        .name = "add",
    });
    var w1: Io.Writer = .fixed(&buf);
    try d.format(&w1);
    try std.testing.expectEqualStrings(
        "DuplicateExportName in export section, name \"add\", at byte 0x3c",
        w1.buffered(),
    );

    var bare: Diagnostics = .{};
    Diagnostics.record(&bare, error.Truncated, .{});
    var w2: Io.Writer = .fixed(&buf);
    try bare.format(&w2);
    try std.testing.expectEqualStrings("Truncated", w2.buffered());
}

test "Diagnostics: format prints a missing body's ordinal" {
    var buf: [128]u8 = undefined;
    var d: Diagnostics = .{};
    Diagnostics.record(&d, error.MissingBody, .{
        .detail = .{ .missing_body = .{ .ordinal = 2 } },
    });

    var w: Io.Writer = .fixed(&buf);
    try d.format(&w);
    try std.testing.expectEqualStrings(
        "MissingBody (added function 2 has no body)",
        w.buffered(),
    );
}

test "Diagnostics: format prints the owning function and a local index" {
    var buf: [160]u8 = undefined;
    var d: Diagnostics = .{};
    Diagnostics.record(&d, error.IndexOutOfRange, .{
        .section = .code,
        .function = 7,
        .detail = .{ .out_of_range = .{ .space = .local, .value = 3, .limit = 2 } },
    });

    var w: Io.Writer = .fixed(&buf);
    try d.format(&w);
    try std.testing.expectEqualStrings(
        "IndexOutOfRange in code section, function 7 (local index 3, but only 2 exist)",
        w.buffered(),
    );
}

test "Diagnostics: format prints a custom section occurrence" {
    var buf: [192]u8 = undefined;
    var d: Diagnostics = .{};
    Diagnostics.record(&d, error.UnknownCustomSection, .{
        .section = .custom,
        .name = "dylink.0",
        .detail = .{ .custom_section = .{ .occurrence = 1 } },
    });

    var w: Io.Writer = .fixed(&buf);
    try d.format(&w);
    try std.testing.expectEqualStrings(
        "UnknownCustomSection in custom section, name \"dylink.0\" " ++
            "(custom section occurrence 1)",
        w.buffered(),
    );
}

test "Diagnostics: fail records the error and returns the same one" {
    var d: Diagnostics = .{};
    const e = Diagnostics.fail(&d, error.OutOfRange, .{ .section = .code });
    try std.testing.expectEqual(error.OutOfRange, e);
    try std.testing.expectEqual(@as(?anyerror, error.OutOfRange), d.err);
}

test "Diagnostics: fail without diagnostics still returns the error" {
    const e = Diagnostics.fail(null, error.OutOfRange, .{});
    try std.testing.expectEqual(error.OutOfRange, e);
}

fn failingSite(diag: ?*Diagnostics) error{ OutOfRange, Other }!void {
    return Diagnostics.fail(diag, error.OutOfRange, .{ .section = .@"export", .name = "dup" });
}

test "Diagnostics: fail composes with a declared error set (the real call-site shape)" {
    var d: Diagnostics = .{};
    try std.testing.expectError(error.OutOfRange, failingSite(&d));
    try std.testing.expectEqual(@as(?anyerror, error.OutOfRange), d.err);
    try std.testing.expectEqualStrings("dup", d.name());
    try std.testing.expectError(error.OutOfRange, failingSite(null)); // no diagnostics: same error
}

fn runtimeError(diag: ?*Diagnostics, e: error{ A, B }) error{ A, B } {
    if (!@import("builtin").is_test) {
        @compileError("Shouldn't be called outside of a test");
    }
    return Diagnostics.fail(diag, e, .{});
}

test "Diagnostics: fail records a runtime error value, not just literals" {
    var a: Diagnostics = .{};
    try std.testing.expectEqual(error.A, runtimeError(&a, error.A));
    try std.testing.expectEqual(@as(?anyerror, error.A), a.err);

    var b: Diagnostics = .{};
    try std.testing.expectEqual(error.B, runtimeError(&b, error.B));
    try std.testing.expectEqual(@as(?anyerror, error.B), b.err);
}

test "Diagnostics: fail after an earlier failure keeps the earlier record" {
    var d: Diagnostics = .{};
    Diagnostics.fail(&d, error.First, .{ .section = .type }) catch {};
    const second = Diagnostics.fail(&d, error.Second, .{ .section = .code });
    try std.testing.expectEqual(error.Second, second); // the caller still gets its own error back
    try std.testing.expectEqual(@as(?anyerror, error.First), d.err); // the record keeps the first
}

test "Diagnostics: no detail unless one is given" {
    var d: Diagnostics = .{};
    try std.testing.expectEqualDeep(Diagnostics.Detail.none, d.detail);
    Diagnostics.record(&d, error.E, .{ .section = .code });
    try std.testing.expectEqualDeep(Diagnostics.Detail.none, d.detail);
}

test "Diagnostics: the detail is stored, and the first failure keeps its own" {
    var d: Diagnostics = .{};
    Diagnostics.record(&d, error.First, .{
        .detail = .{ .out_of_range = .{ .space = .function, .value = 9, .limit = 3 } },
    });
    Diagnostics.record(&d, error.Second, .{
        .detail = .{ .out_of_range = .{ .space = .global, .value = 1, .limit = 2 } },
    });
    try std.testing.expectEqualDeep(
        Diagnostics.Detail{ .out_of_range = .{ .space = .function, .value = 9, .limit = 3 } },
        d.detail,
    );
}

test "Diagnostics: reset clears the detail, and fail carries it" {
    var d: Diagnostics = .{};
    Diagnostics.fail(&d, error.E, .{
        .detail = .{ .out_of_range = .{ .space = .table, .value = 5, .limit = 4 } },
    }) catch {};
    try std.testing.expectEqualDeep(
        Diagnostics.Detail{ .out_of_range = .{ .space = .table, .value = 5, .limit = 4 } },
        d.detail,
    );
    d.reset();
    try std.testing.expectEqualDeep(Diagnostics.Detail.none, d.detail);
    try std.testing.expect(!d.hasFailure());
}

test "Diagnostics: format prints the out-of-range detail last" {
    var buf: [160]u8 = undefined;

    var d1: Diagnostics = .{};
    Diagnostics.record(&d1, error.IndexOutOfRange, .{
        .section = .@"export",
        .name = "f",
        .detail = .{ .out_of_range = .{ .space = .function, .value = 9, .limit = 3 } },
    });
    var w1: Io.Writer = .fixed(&buf);
    try d1.format(&w1);
    try std.testing.expectEqualStrings(
        "IndexOutOfRange in export section, name \"f\" (function index 9, but only 3 exist)",
        w1.buffered(),
    );

    var d2: Diagnostics = .{};
    Diagnostics.record(&d2, error.IndexOutOfRange, .{
        .section = .@"export",
        .name = "f",
        .offset = 0x3c,
        .detail = .{ .out_of_range = .{ .space = .function, .value = 0, .limit = 0 } },
    });
    var w2: Io.Writer = .fixed(&buf);
    try d2.format(&w2);
    try std.testing.expectEqualStrings(
        "IndexOutOfRange in export section, name \"f\", at byte 0x3c " ++
            "(function index 0, but only 0 exist)",
        w2.buffered(),
    );
}
