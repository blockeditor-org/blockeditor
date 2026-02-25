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

    const snapshot = addUpdateSnapshotsOption(b, snapshot_runner);
    const run_block_tests = snapshot.addRunTest(b, block_test);
    run_block_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Test");
    test_step.dependOn(&run_block_tests.step);
}

const UpdateSnapshotsOption = struct {
    value: ?*std.Build.Step.Compile,

    pub fn addRunTest(self: *const UpdateSnapshotsOption, b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
        const run_step = b.addRunArtifact(exe);

        if (self.value) |us| {
            const idx = run_step.argv.items.len;
            run_step.addArtifactArg(us);
            run_step.addPrefixedFileArg(b.fmt("-M{s}=", .{"root"}), exe.root_module.root_source_file.?);
            const dup = b.allocator.dupe(std.Build.Step.Run.Arg, run_step.argv.items[idx..]) catch @panic("oom");
            run_step.argv.items.len = idx;
            run_step.argv.insertSlice(b.allocator, 0, dup) catch @panic("oom");
        }

        return run_step;
    }
};
pub fn addUpdateSnapshotsOption(b: *std.Build, update_snapshots: *std.Build.Step.Compile) UpdateSnapshotsOption {
    if (b.option(bool, "update_snapshots", "update snapshots?") orelse false) return .{ .value = update_snapshots };
    return .{ .value = null };
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
