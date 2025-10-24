const std = @import("std");
const zig_gamedev = @import("zig_gamedev");
const beui_app = @import("beui_app");

pub fn build(b: *std.Build) !void {
    defer beui_app.fixAndroidLibc(b);
    const opts = beui_app.standardAppOptions(b);
    const target = opts.target(b);
    const optimize = opts.optimize;

    const format_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&format_step.step);

    const emu_mod = b.dependency("minigamer_emulator", .{}).module("emu");
    const sponge_mod = b.createModule(.{ .root_source_file = b.dependency("minigamer_sponge", .{ .optimize = .ReleaseFast }).artifact("sponge.cart").getEmittedBin() });

    const anywhere_mod = b.dependency("anywhere", .{}).module("anywhere");
    const blocks_dep = b.dependency("blocks", .{ .target = target, .optimize = optimize });
    const blocks_net_dep = b.dependency("blocks_net", .{ .target = target, .optimize = optimize });
    const beui_dep = b.dependency("beui", .{ .target = target, .optimize = optimize });

    const app_mod = b.addModule("blockeditor", .{
        .root_source_file = b.path("src/App.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "anywhere", .module = anywhere_mod },
            .{ .name = "blocks", .module = blocks_dep.module("blocks") },
            .{ .name = "blocks_net", .module = blocks_net_dep.module("client") },
            .{ .name = "beui", .module = beui_dep.module("beui") },
            .{ .name = "minigamer", .module = emu_mod },
            .{ .name = "sponge.cart", .module = sponge_mod },
        },
    });

    const app_test = b.addTest(.{
        .root_module = app_mod,
    });
    if (opts.platform != .android) b.installArtifact(app_test);

    const app_test_run = b.addRunArtifact(app_test);
    app_test_run.step.dependOn(b.getInstallStep());
    const test_run = b.step("test", "Test");
    test_run.dependOn(&app_test_run.step);

    const blockeditor_app = beui_app.addApp(b, "blockeditor", .{
        .name = "blockeditor",
        .opts = opts,
        .module = app_mod,
    });

    const beui_app_install = beui_app.installApp(b, blockeditor_app);
    const run_step = beui_app.addRunApp(b, blockeditor_app, beui_app_install);
    if (b.args) |args| run_step.addArgs(args);
    run_step.step.dependOn(b.getInstallStep());
    const run = b.step("run", "Run");
    run.dependOn(&run_step.step);
}
