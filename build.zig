const std = @import("std");

pub const deps = struct {
    pub const tree_sitter = @import("tree_sitter");
    pub const beui_app = @import("beui_app");
};

pub fn build(b: *std.Build) void {
    defer deps.beui_app.fixAndroidLibc(b);
    const opts = deps.beui_app.standardAppOptions(b);
    const target = opts.target(b);
    const optimize = opts.optimize;

    const fmt_all = b.addFmt(.{
        .paths = &.{
            "packages",
            "build.zig",
            "build.zig.zon",
        },
        .check = b.option(bool, "ci", "") orelse false,
    });
    b.getInstallStep().dependOn(&fmt_all.step);

    const anywhere_dep = b.dependency("anywhere", .{ .target = target, .optimize = optimize });
    const beui_dep = b.dependency("beui", .{ .target = target, .optimize = optimize });
    const blockeditor_dep = b.dependency("blockeditor", .{ .opts = opts.passIn(b) });
    const blocks_dep = b.dependency("blocks", .{ .target = target, .optimize = optimize, .tracy = opts.tracy });
    const blocks_net_dep = b.dependency("blocks_net", .{ .target = target, .optimize = optimize });
    const cvl_dep = b.dependency("cvl", .{ .target = target, .optimize = optimize });
    const loadimage_dep = b.dependency("loadimage", .{ .target = target, .optimize = optimize });
    const loadimage_wasm_dep = b.dependency("loadimage_wasm", .{});
    const logicgame_dep = b.dependency("logicgame", .{ .target = target, .optimize = optimize });
    const minigamer_3ds_dep = b.dependency("minigamer_3ds", .{ .optimize = optimize });
    const sheen_bidi_dep = b.dependency("sheen_bidi", .{ .target = target, .optimize = optimize });
    const texteditor_dep = b.dependency("texteditor", .{ .target = target, .optimize = optimize });
    const tracy_dep = b.dependency("tracy", .{ .target = b.resolveTargetQuery(.{}), .optimize = .ReleaseSafe });
    const unicode_segmentation_2_dep = b.dependency("unicode_segmentation_2", .{ .target = target, .optimize = optimize });

    const blockeditor_app = deps.beui_app.app(blockeditor_dep, "blockeditor");
    const blockeditor_app_install = deps.beui_app.installApp(b, blockeditor_app);
    b.installArtifact(blocks_net_dep.artifact("server"));
    b.getInstallStep().dependOn(&b.addInstallBinFile(minigamer_3ds_dep.namedLazyPath("minigamer.3dsx"), "mingamer.3dsx").step);
    // b.installArtifact(texteditor_dep.artifact("zls")); // disabled because zls isn't used so it's a bit of a waste of time to compile
    b.installArtifact(blocks_dep.artifact("bench"));
    b.installArtifact(loadimage_wasm_dep.artifact("loadimage_wasm"));
    if (opts.tracy) b.getInstallStep().dependOn(&b.addInstallArtifact(tracy_dep.artifact("tracy"), .{ .dest_dir = .{ .override = .{ .custom = "tool" } } }).step); // tracy exe has system dependencies and cannot be compiled for all targets

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&b.addRunArtifact(anywhere_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(beui_dep.artifact("test")).step);
    if (!opts.target(b).result.abi.isAndroid()) test_step.dependOn(&b.addRunArtifact(blockeditor_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(blocks_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(blocks_net_dep.artifact("test")).step);
    const cvl_test_run = b.addRunArtifact(cvl_dep.artifact("test"));
    cvl_test_run.setCwd(b.path("packages/cvl"));
    cvl_test_run.addFileInput(b.path("packages/cvl/src/tests/zig.cvl"));
    test_step.dependOn(&cvl_test_run.step);
    test_step.dependOn(&b.addRunArtifact(loadimage_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(logicgame_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(sheen_bidi_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(texteditor_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(unicode_segmentation_2_dep.artifact("test")).step);

    const run_blockeditor = deps.beui_app.addRunApp(b, blockeditor_app, blockeditor_app_install);
    if (b.args) |args| run_blockeditor.addArgs(args);
    run_blockeditor.step.dependOn(b.getInstallStep());
    const run_blockeditor_step = b.step("run", "Run");
    run_blockeditor_step.dependOn(&run_blockeditor.step);

    const run_server = b.addRunArtifact(blocks_net_dep.artifact("server"));
    run_server.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_server.addArgs(args);
    const run_server_step = b.step("server", "Run server");
    run_server_step.dependOn(&run_server.step);
}
