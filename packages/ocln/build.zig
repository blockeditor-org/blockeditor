const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const anywhere = b.dependency("anywhere", .{ .target = target, .optimize = optimize });
    const ocln = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "anywhere", .module = anywhere.module("anywhere") },
        },
    });

    const ocln_test = b.addTest(.{ .name = "test_ocln", .root_module = ocln });
    b.installArtifact(ocln_test);

    const run_test_step = b.addRunArtifact(ocln_test);

    const test_step = b.step("test", "");
    test_step.dependOn(&run_test_step.step);
}
