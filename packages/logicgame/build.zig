const std = @import("std");
pub fn build(b: *std.Build) void {
    const tool_target = b.resolveTargetQuery(.{});
    const tool_optimize = std.builtin.OptimizeMode.Debug;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const snapshot = b.addExecutable(.{
        .name = "snapshot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/snapshot.zig"),
            .target = tool_target,
            .optimize = tool_optimize,
        }),
    });
    b.installArtifact(snapshot);

    const dat = b.createModule(.{
        .root_source_file = b.path("src/dat.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dat_test = b.addTest(.{
        .root_module = dat,
        .use_llvm = false, // https://github.com/ziglang/zig/issues/25247
    });

    b.installArtifact(dat_test);

    const run_step = b.step("test", "test");
    const run = b.addRunArtifact(snapshot);
    run.step.dependOn(b.getInstallStep());
    run.addArgs(b.args orelse &.{});
    run.addFileArg(dat_test.getEmittedBin());
    run_step.dependOn(&run.step);
}
