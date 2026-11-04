const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const wsplice = b.addModule("wsplice", .{
        .root_source_file = b.path("src/wsplice.zig"),
        .target = target,
        .optimize = optimize,
    });

    const wsplice_test = b.addTest(.{
        .name = "wsplice_test",
        .root_module = wsplice,
    });
    const test_run_art = b.addRunArtifact(wsplice_test);
    const test_step = b.step("test", "Run the test");
    test_step.dependOn(&test_run_art.step);
}
