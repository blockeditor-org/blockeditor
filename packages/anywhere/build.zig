const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native = b.resolveTargetQuery(.{});

    const fmt_step = b.addFmt(.{ .paths = &.{ "src", "build.zig" } });
    b.getInstallStep().dependOn(&fmt_step.step);

    const zpool = b.dependency("zpool", .{});
    const anywhere = b.addModule("anywhere", .{
        .root_source_file = b.path("build.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zpool", .module = zpool.module("root") },
        },
    });

    const block_test = b.addTest(.{ .root_module = anywhere });

    b.installArtifact(block_test);

    const libc_file_builder = b.addExecutable(.{
        .name = "libc_file_builder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/libc_file_builder.zig"),
            .target = native,
            .optimize = .Debug,
        }),
    });
    b.installArtifact(libc_file_builder);

    const snapshot_runner = b.addExecutable(.{
        .name = "snapshot_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/snapshot_runner.zig"),
            .target = native,
            .optimize = .Debug,
            .imports = &.{.{ .name = "anywhere", .module = anywhere }},
        }),
    });
    b.installArtifact(snapshot_runner);

    const run_block_tests = addRunTest(b, block_test, addUpdateSnapshotsOption(b, snapshot_runner));
    run_block_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Test");
    test_step.dependOn(&run_block_tests.step);
}

pub fn addUpdateSnapshotsOption(b: *std.Build, update_snapshots: *std.Build.Step.Compile) ?*std.Build.Step.Compile {
    if (b.option(bool, "update_snapshots", "updat snapshots?") orelse false) return update_snapshots;
    return null;
}
pub fn addRunTest(b: *std.Build, exe: *std.Build.Step.Compile, update_snapshots: ?*std.Build.Step.Compile) *std.Build.Step.Run {
    const step_name = if (exe.kind.isTest() and std.mem.eql(u8, exe.name, "test"))
        b.fmt("run {s}", .{@tagName(exe.kind)})
    else
        b.fmt("run {s} {s}", .{ @tagName(exe.kind), exe.name });

    const run_step = std.Build.Step.Run.create(b, step_name);
    run_step.producer = exe;
    if (update_snapshots) |us| {
        run_step.addArtifactArg(us);
        run_step.addPrefixedFileArg(b.fmt("-M{s}=", .{"root"}), exe.root_module.root_source_file.?);
    }
    run_step.addArtifactArg(exe);

    return run_step;
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
