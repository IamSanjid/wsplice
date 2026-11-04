const std = @import("std");

pub const minimal = @embedFile("minimal.wasm"); // path is relative to this file
pub const zig_basic = @embedFile("zig_basic.wasm");
pub const imports = @embedFile("imports.wasm");

pub const Fixture = struct { name: []const u8, bytes: []const u8 };

pub const all = [_]Fixture{
    .{ .name = "minimal", .bytes = minimal },
    .{ .name = "zig_basic", .bytes = zig_basic },
    .{ .name = "imports", .bytes = imports },
};
