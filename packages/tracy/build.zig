const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profiler_optimize = std.builtin.OptimizeMode.ReleaseSafe;

    const fmt_step = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    b.getInstallStep().dependOn(&fmt_step.step);

    const tracy_dep = b.dependency("tracy", .{ .target = target, .optimize = profiler_optimize });
    const tracy_exe = tracy_dep.artifact("tracy-profiler");
    const tracy_lib = tracy_dep.artifact("tracy");
    b.installArtifact(tracy_lib);
    b.installArtifact(tracy_exe);

    const tracy_mod = b.addModule("tracy", .{
        .root_source_file = b.path("src/tracy.zig"),
        .target = target,
        .optimize = optimize,
    });
    tracy_mod.addIncludePath(tracy_dep.path("public/tracy"));
    tracy_mod.linkLibrary(tracy_lib);

    const run_step = b.addRunArtifact(tracy_exe);
    if (b.args) |a| run_step.addArgs(a);
    run_step.step.dependOn(b.getInstallStep());
    const run = b.step("run", "Run");
    run.dependOn(&run_step.step);
}
