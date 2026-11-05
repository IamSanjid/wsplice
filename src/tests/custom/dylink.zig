//! Integration tests: dylink.0 through Query, Builder, the custom editor, and emit.
const std = @import("std");
const testing = std.testing;

const Builder = @import("../../Builder.zig");
const Module = @import("../../Module.zig");
const dylink = @import("../../custom/dylink.zig");
const t = @import("../support.zig");

const one_type = t.sec(1, &.{ 1, 0x60, 0, 0 });
const dylink_name = "dylink.0";
const arbitrary_name = "game.dylink";

/// Custom payload for `name`, followed by `data`. Both must stay below 128 bytes.
fn customPayload(comptime name: []const u8, comptime data: []const u8) [1 + name.len + data.len]u8 {
    return [_]u8{@intCast(name.len)} ++ name[0..name.len].* ++ data[0..data.len].*;
}

test "dylink: add a missing section at the start" {
    const input = t.header ++ one_type;
    const section = t.sec(0, &customPayload(dylink_name, &.{ 1, 4, 1, 2, 3, 4 }));
    const expected = t.header ++ section ++ one_type;

    var info: dylink.Info = .{
        .mem_info = .{
            .memory_size = 1,
            .memory_alignment_log2 = 2,
            .table_size = 3,
            .table_alignment_log2 = 4,
        },
    };
    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.addCustomSection(testing.allocator, .start, dylink_name, .from(&info));
    const patch = try builder.patch();
    try t.expectEmit(&input, &patch, &expected);

    const m = try Module.parse(&expected);
    const query = try m.query(.{});
    const custom = (try query.customSection(dylink_name)).?;
    try testing.expectEqualStrings(dylink_name, custom.name);
    const view = try dylink.read(custom.data);
    try testing.expectEqual(@as(u32, 1), view.mem_info.?.memory_size);
    try testing.expectEqual(@as(u32, 4), view.mem_info.?.table_alignment_log2);
}

test "dylink: copy needed from another module by encoded bytes" {
    const source_data = [_]u8{
        1, 4, 9, 9, 9, 9, // source mem_info
        2, 6, 2, 1, 'a', 2, 'b', 'c', // source needed: "a", "bc"
    };
    const target_data = [_]u8{ 1, 4, 1, 2, 3, 4 };
    const expected_data = [_]u8{
        1,   4,   1, 2, 3,   4,
        2,   6,   2, 1, 'a', 2,
        'b', 'c',
    };
    const source_bytes = t.header ++ t.sec(0, &customPayload(dylink_name, &source_data));
    const input = t.header ++
        t.sec(0, &customPayload(dylink_name, &target_data)) ++
        one_type;
    const expected = t.header ++
        t.sec(0, &customPayload(dylink_name, &expected_data)) ++
        one_type;

    const source_module = try Module.parse(&source_bytes);
    const source_query = try source_module.query(.{});
    const source_custom = (try source_query.customSection(dylink_name)).?;
    const source_view = try dylink.read(source_custom.data);
    const source_needed = source_view.needed.?;

    var changes: dylink.Update = .{ .needed = .{ .encoded = source_needed.encoded } };
    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.setCustomSection(testing.allocator, dylink_name, 0, .from(&changes));
    const patch = try builder.patch();
    try t.expectEmit(&input, &patch, &expected);

    const m = try Module.parse(&expected);
    const query = try m.query(.{});
    const custom = (try query.customSection(dylink_name)).?;
    const view = try dylink.read(custom.data);
    try testing.expectEqual(@as(u32, 2), try view.needed.?.count());
    var iterator = try view.needed.?.iterator();
    try testing.expectEqualStrings("a", (try iterator.next()).?);
    try testing.expectEqualStrings("bc", (try iterator.next()).?);
    try testing.expectEqual(@as(?[]const u8, null), try iterator.next());
}

test "dylink: update an arbitrary-named section and preserve unknown subsections" {
    const original_data = [_]u8{ 1, 4, 1, 2, 3, 4, 9, 2, 0xAA, 0xBB };
    const expected_data = [_]u8{ 1, 4, 9, 2, 3, 4, 9, 2, 0xAA, 0xBB };
    const input = t.header ++
        t.sec(0, &customPayload(arbitrary_name, &original_data)) ++
        one_type;
    const expected = t.header ++
        t.sec(0, &customPayload(arbitrary_name, &expected_data)) ++
        one_type;

    var changes: dylink.Update = .{ .memory_size = 9 };
    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.setCustomSection(testing.allocator, arbitrary_name, 0, .from(&changes));
    const patch = try builder.patch();
    try t.expectEmit(&input, &patch, &expected);

    const m = try Module.parse(&expected);
    const query = try m.query(.{});
    const custom = (try query.customSection(arbitrary_name)).?;
    const view = try dylink.read(custom.data);
    try testing.expectEqual(@as(u32, 9), view.mem_info.?.memory_size);
    try testing.expectEqualSlices(u8, &expected_data, custom.data);
}
