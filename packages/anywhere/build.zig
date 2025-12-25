const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt_step = b.addFmt(.{ .paths = &.{ "src", "build.zig" } });
    b.getInstallStep().dependOn(&fmt_step.step);

    const zpool = b.dependency("zpool", .{});
    const mod = b.addModule("anywhere", .{
        .root_source_file = b.path("build.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zpool", .module = zpool.module("root") },
        },
    });

    const block_test = b.addTest(.{ .root_module = mod });

    b.installArtifact(block_test);
    const run_block_tests = b.addRunArtifact(block_test);
    run_block_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Test");
    test_step.dependOn(&run_block_tests.step);

    const libc_file_builder = b.addExecutable(.{
        .name = "libc_file_builder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/libc_file_builder.zig"),
            .target = b.resolveTargetQuery(.{}), // native
            .optimize = .Debug,
        }),
    });
    b.installArtifact(libc_file_builder);
}

// TODO:
// - make build.zig the root source file of anywhere mod
// - expose everything directly here
const lib = @import("src/anywhere.zig");
pub const zgui = lib.zgui;
pub const tracy = lib.tracy;
pub const util = lib.util;
pub const AnywhereCfg = lib.AnywhereCfg;

test "refAllDecls" {
    std.testing.refAllDeclsRecursive(lib);
}
