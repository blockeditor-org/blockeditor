const std = @import("std");

pub const Target = std.Target.Query{
    .cpu_arch = .riscv32,
    .cpu_model = .{
        .explicit = &std.Target.riscv.cpu.generic_rv32, // a, c, d, m
    },
    .cpu_features_add = std.Target.Cpu.Feature.FeatureSetFns(std.Target.riscv.Feature).featureSet(&.{
        .m, // multiplication
        // .d, // 64-bit float
        // .f, // 32-bit float

        // TODO: c (compressed instructions) (16 bits for common instructions)
        // TODO: a (atomics) : we don't need this yet really
    }),

    .os_tag = .freestanding,

    .abi = .none,
};
pub fn build(b: *std.Build) !void {
    const anywhere_dep = b.dependency("anywhere", .{});
    const rvemu_mod = b.addModule("rvemu", .{
        .root_source_file = b.path("src/rvemu.zig"),
        .imports = &.{
            .{ .name = "anywhere", .module = anywhere_dep.module("anywhere") },
        },
    });

    const rv_target = b.resolveTargetQuery(Target);
    {
        var tests_dir = try std.fs.cwd().openDir(b.path("tests").getPath(b), .{ .iterate = true });
        defer tests_dir.close();

        var exe_bins = std.array_list.Managed(struct { std.Build.LazyPath, std.Build.LazyPath }).init(b.allocator);

        var it = tests_dir.iterateAssumeFirstIteration();
        while (try it.next()) |ent| {
            if (!std.mem.endsWith(u8, ent.name, ".zig")) continue;
            const mod = b.createModule(.{
                .target = rv_target,
                .optimize = .ReleaseSafe,
                .root_source_file = b.path("tests").path(b, ent.name),
                .single_threaded = true,
            });
            const exe = b.addExecutable(.{ .name = ent.name, .root_module = mod });
            try exe_bins.append(.{ exe.getEmittedBin(), b.path("tests").path(b, b.fmt("{s}.snap", .{ent.name})) });
        }

        const runner = b.addExecutable(.{ .name = "test_runner", .root_module = b.createModule(.{
            .root_source_file = b.path("tests/lib/test_runner.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = .Debug,
            .imports = &.{.{ .name = "rvemu", .module = rvemu_mod }},
        }) });
        b.installArtifact(runner);
        const runner_run = b.addRunArtifact(runner);
        runner_run.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            if (args.len == 1 and std.mem.eql(u8, args[0], "-u")) {
                runner_run.addArg("-u");
            }
        }
        runner_run.addFileArg(b.path("tests/_hashes.txt"));
        for (exe_bins.items) |exe_bin| {
            runner_run.addFileArg(exe_bin[0]);
            runner_run.addFileArg(exe_bin[1]);
        }

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&runner_run.step);
        // how 2 share this test step with the root level build.zig?
    }
}
