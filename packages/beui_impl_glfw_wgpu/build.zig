const std = @import("std");
const anywhere = @import("anywhere");
const zig_gamedev = @import("zig_gamedev");

pub fn createApp(name: []const u8, self_dep: *std.Build.Dependency, app_mod: *std.Build.Module) struct { []const u8, []const u8, std.Build.LazyPath, ?struct { name: []const u8, path: std.Build.LazyPath } } {
    const b = self_dep.builder;

    const options = anywhere.util.build.find(self_dep, Options, "options");
    const target = options.target;
    const optimize = options.optimize;
    const enable_tracy = options.enable_tracy;

    const beui_dep = b.dependency("beui", .{ .target = target, .optimize = optimize });
    const anywhere_mod = b.dependency("anywhere", .{}).module("anywhere");
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_tracy", enable_tracy);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/beui_impl.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "beui", .module = beui_dep.module("beui") },
                .{ .name = "anywhere", .module = anywhere_mod },
                .{ .name = "app", .module = app_mod },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });

    if (enable_tracy) {
        const tracy_dep = b.dependency("tracy", .{
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("tracy__impl", tracy_dep.module("tracy"));
    }

    // disabled https://github.com/zig-gamedev/zgui/issues/75
    // const zgui = b.dependency("zgui", .{
    //     .backend = .glfw_wgpu,
    //     .shared = false,
    //     .with_implot = false,
    //     .target = target,
    //     .optimize = optimize,
    // });
    // exe.root_module.addImport("zgui", zgui.module("root"));
    // exe.linkLibrary(zgui.artifact("imgui"));

    const zglfw = b.dependency("zglfw", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("zglfw", zglfw.module("root"));
    exe.linkLibrary(zglfw.artifact("glfw"));

    const zgpu = b.dependency("zgpu", .{ .target = target, .optimize = optimize });
    {
        // workaround so zgpu will fetch dawn from its own build.zig.zon
        const prev_owner = exe.step.owner;
        defer exe.step.owner = prev_owner;
        exe.step.owner = zgpu.builder;
        @import("zgpu").addLibraryPathsTo(exe);
    }
    exe.root_module.addImport("zgpu", zgpu.module("root"));
    exe.linkLibrary(zgpu.artifact("zdawn"));

    return .{ exe.name, exe.out_filename, exe.getEmittedBin(), if (exe.producesPdbFile()) .{
        .name = b.fmt("{s}.pdb", .{exe.name}),
        .path = exe.getEmittedPdb(),
    } else null };
}

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enable_tracy: bool,
};

pub fn runApp(self_dep: *std.Build.Dependency, app: std.Build.LazyPath) *std.Build.Step.Run {
    const b = self_dep.builder;

    const options = anywhere.util.build.find(self_dep, Options, "options");
    const target = options.target;
    const optimize = options.optimize;
    const enable_tracy = options.enable_tracy;
    const multirun_exe = self_dep.artifact("multirun");

    const run_step = std.Build.Step.Run.create(b, b.fmt("beui_impl_glfw_wgpu_runApp: {s}", .{app.getDisplayName()}));

    if (enable_tracy) {
        if (optimize == .Debug) {
            b.getInstallStep().dependOn(&b.addFail("To use tracy, -Doptimize must be set to a release mode").step);
        }

        const tracy_dep = b.dependency("tracy", .{
            .target = target,
            .optimize = optimize,
        });

        run_step.addArtifactArg(multirun_exe);

        run_step.addArg("|-|");
        run_step.addArtifactArg(tracy_dep.artifact("tracy"));
        run_step.addArg("-a");
        run_step.addArg("127.0.0.1");

        run_step.addArg("|-|");
    }

    run_step.addFileArg(app);

    return run_step;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_tracy = b.option(bool, "tracy", "Enable tracy?") orelse false;

    anywhere.util.build.expose(b, "options", Options, .{ .target = target, .optimize = optimize, .enable_tracy = enable_tracy });

    const format_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&format_step.step);

    const multirun_exe = b.addExecutable(.{
        .name = "multirun",
        .root_module = b.createModule(.{
            .root_source_file = b.path("multirun.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = .Debug,
        }),
    });
    b.installArtifact(multirun_exe);
}
