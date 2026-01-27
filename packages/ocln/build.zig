const std = @import("std");
const beui_app = @import("beui_app");
const anywhere = @import("anywhere");

pub fn build(b: *std.Build) void {
    defer beui_app.fixAndroidLibc(b);
    const opts = beui_app.standardAppOptions(b);
    const target = opts.target(b);
    const optimize = opts.optimize;

    const beui_dep = b.dependency("beui", .{ .target = target, .optimize = optimize });

    const anywhere_dep = b.dependency("anywhere", .{});
    const loadimage_dep = b.dependency("loadimage", .{ .target = target, .optimize = optimize });
    const ocln = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "anywhere", .module = anywhere_dep.module("anywhere") },
            .{ .name = "beui", .module = beui_dep.module("beui") },
            .{ .name = "loadimage", .module = loadimage_dep.module("loadimage") },
        },
    });

    const ocln_test = b.addTest(.{ .name = "test_ocln", .root_module = ocln });
    if (opts.platform != .android) b.installArtifact(ocln_test);

    const run_test_step = b.addRunArtifact(ocln_test);

    const test_step = b.step("test", "");
    test_step.dependOn(&run_test_step.step);

    const ocln_app = beui_app.addApp(b, "ocln", .{
        .name = "ocln",
        .opts = opts,
        .module = ocln,
    });

    const ocln_app_install = beui_app.installApp(b, ocln_app);
    const run_step = beui_app.addRunApp(b, ocln_app, ocln_app_install);
    if (b.args) |args| run_step.addArgs(args);
    run_step.step.dependOn(b.getInstallStep());
    const run = b.step("run", "Run");
    run.dependOn(&run_step.step);
}
