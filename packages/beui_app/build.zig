const std = @import("std");
const anywhere = @import("anywhere");
const beui_impl_android = @import("beui_impl_android");
const beui_impl_glfw_wgpu = @import("beui_impl_glfw_wgpu");
const beui_impl_web = @import("beui_impl_web");

const Platform = enum { android, web, glfw_wgpu };
pub const App = struct {
    name: []const u8,
    bin_name: []const u8,
    kind: Platform,
    emitted_file: std.Build.LazyPath,

    dep: ?*std.Build.Dependency,
    pdb: ?struct { name: []const u8, path: std.Build.LazyPath } = null,
};

const _targethack = struct {
    var th: std.array_list.Managed(std.Build.ResolvedTarget) = undefined;
    var th_rev: std.StringArrayHashMap(usize) = undefined;
    var th_initialized = false;
    fn minit(b: *std.Build) void {
        if (!_targethack.th_initialized) {
            _targethack.th = .init(b.allocator);
            _targethack.th_rev = .init(b.allocator);
            _targethack.th_initialized = true;
        }
    }
    fn targetToString(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
        return b.fmt("{s}:{s}", .{
            target.query.zigTriple(b.allocator) catch @panic("oom"),
            target.query.serializeCpuAlloc(b.allocator) catch @panic("oom"),
        });
    }
};
fn putTargetHack(b: *std.Build, value: std.Build.ResolvedTarget) usize {
    _targethack.minit(b);
    const rev_val = _targethack.th_rev.getOrPut(_targethack.targetToString(b, value)) catch @panic("oom");
    if (!rev_val.found_existing) {
        rev_val.value_ptr.* = _targethack.th.items.len;
        _targethack.th.append(value) catch @panic("oom");
    }
    return rev_val.value_ptr.*;
}
fn getTargetHack(b: *std.Build, itm: usize) std.Build.ResolvedTarget {
    _targethack.minit(b);
    return _targethack.th.items[itm];
}

pub fn fixAndroidLibc(b: *std.Build) void {
    return beui_impl_android.fixAndroidLibc(b);
}

pub const AppCfg = struct {
    opts: AppOpts,

    module: *std.Build.Module,
    name: []const u8,
};
pub const AppOpts = struct {
    target_hack: usize,
    optimize: std.builtin.OptimizeMode,

    platform: Platform,

    // glfw_wgpu
    tracy: bool = false,

    // web
    port: u16 = 3556,

    // android
    android: ?beui_impl_android.BuildCache = null,

    pub fn passIn(self: *const AppOpts, b: *std.Build) []const u8 {
        var w = std.Io.Writer.Allocating.init(b.allocator);
        defer w.deinit();
        std.json.Stringify.value(self, .{ .whitespace = .indent_4 }, &w.writer) catch |e| {
            std.log.warn("failed to stringify json: {s}", .{@errorName(e)});
            @panic("failure");
        };
        return w.toOwnedSlice() catch @panic("oom");
    }
    pub fn target(self: AppOpts, b: *std.Build) std.Build.ResolvedTarget {
        return getTargetHack(b, self.target_hack);
    }
};

pub fn standardAppOptions(b: *std.Build) AppOpts {
    if (b.option([]const u8, "opts", "")) |opts_val| {
        return std.json.parseFromSliceLeaky(AppOpts, b.allocator, opts_val, .{}) catch @panic("bad opts arg");
    }
    const platform: Platform = b.option(Platform, "platform", "Platform to build app for") orelse .glfw_wgpu;
    if (platform == .android) {
        // to block these options from showing up in help
        const android = beui_impl_android.buildCacheOptions(b);
        const target, const optimize = android.getTargetOptimize(b);
        return .{
            .target_hack = putTargetHack(b, target),
            .optimize = optimize,
            .platform = .android,
            .android = android,
        };
    }
    var target: std.Build.ResolvedTarget = undefined;
    if (platform == .web) {
        target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
            .abi = .musl,
        });
    } else {
        target = b.standardTargetOptions(.{});
    }

    const tracy = b.option(bool, "tracy", "[glfw-wgpu] Use tracy?") orelse false;
    var optimize = b.standardOptimizeOption(.{});
    if (tracy and optimize == .Debug) {
        std.log.warn("-Dtracy must have -Doptimize set to a release mode. Setting to ReleaseSafe.", .{});
        optimize = .ReleaseSafe;
    }

    return .{
        .target_hack = putTargetHack(b, target),
        .optimize = optimize,
        .platform = platform,
        .tracy = tracy,
        .port = b.option(u16, "port", "[web] Port to serve from?") orelse 3556,
    };
}

pub fn createApp(b: *std.Build, cfg: AppCfg) *App {
    // choose
    const app_res = b.allocator.create(App) catch @panic("oom");
    const target = cfg.opts.target(b);
    switch (cfg.opts.platform) {
        .android => {
            // `zig build -Dplatform=android` -> error ("TODO setup & build instructions")
            // `zig build -Dplatform=android -D_android_options=....` (called from cmake) -> builds (that way we can eliminate
            //   beui_impl_android depending on blockeditor and instead have android build blockeditor for android)

            const beui_impl_android_dep = b.dependencyFromBuildZig(@This(), .{}).builder.dependencyFromBuildZig(beui_impl_android, .{ .android = cfg.opts.android.?.toJson(b.allocator) });

            const vname, const vbin_name, const vemitted_file = beui_impl_android.createApp(beui_impl_android_dep, cfg.module);
            app_res.* = .{
                .name = vname,
                .bin_name = vbin_name,
                .emitted_file = vemitted_file,
                .kind = .android,
                .dep = beui_impl_android_dep,
            };
        },
        .web => {
            const beui_impl_web_dep = b.dependencyFromBuildZig(@This(), .{}).builder.dependencyFromBuildZig(beui_impl_web, .{ .target = target, .optimize = cfg.opts.optimize, .port = cfg.opts.port });

            app_res.* = .{
                .name = b.dupe(cfg.name),
                .bin_name = b.fmt("{s}.site", .{cfg.name}),
                .emitted_file = beui_impl_web.createApp(cfg.name, beui_impl_web_dep, cfg.module),
                .kind = .web,
                .dep = beui_impl_web_dep,
            };
        },
        .glfw_wgpu => {
            const beui_impl_glfw_wgpu_dep = b.dependencyFromBuildZig(@This(), .{}).builder.dependencyFromBuildZig(beui_impl_glfw_wgpu, .{ .target = target, .optimize = cfg.opts.optimize, .tracy = cfg.opts.tracy });

            const vname, const vbin_name, const vemitted_file, const vpdb = beui_impl_glfw_wgpu.createApp(cfg.name, beui_impl_glfw_wgpu_dep, cfg.module);
            app_res.* = .{
                .name = vname,
                .bin_name = vbin_name,
                .emitted_file = vemitted_file,
                .kind = .glfw_wgpu,
                .dep = beui_impl_glfw_wgpu_dep,
                .pdb = if (vpdb) |vp| .{ .name = vp.name, .path = vp.path } else null,
            };
        },
    }
    return app_res;
}
pub fn addApp(b: *std.Build, name: []const u8, opts: AppCfg) *App {
    const app_res = createApp(b, opts);
    anywhere.util.build.expose(b, name, *App, app_res);
    return app_res;
}
pub fn app(dep: *std.Build.Dependency, name: []const u8) *App {
    return anywhere.util.build.find(dep, *App, name);
}

pub fn addInstallApp(b: *std.Build, the_app: *App, dir: std.Build.InstallDir) std.Build.LazyPath {
    const genf = b.allocator.create(std.Build.GeneratedFile) catch @panic("oom");
    if (the_app.kind == .web) {
        const id_step = b.addInstallDirectory(.{
            .source_dir = the_app.emitted_file,
            .install_dir = dir,
            .install_subdir = the_app.bin_name,
        });
        genf.* = .{ .step = &id_step.step, .path = b.getInstallPath(dir, the_app.bin_name) };
    } else {
        const if_step = b.addInstallFileWithDir(the_app.emitted_file, dir, the_app.bin_name);
        if (the_app.pdb) |pdb| {
            if_step.step.dependOn(&b.addInstallFileWithDir(pdb.path, dir, pdb.name).step);
        }
        genf.* = .{ .step = &if_step.step, .path = b.getInstallPath(dir, the_app.bin_name) };
    }
    return .{ .generated = .{ .file = genf } };
}
/// unlinke b.installArtifact(), this one returns *InstallApp instead of void because it is
/// needed to be passed into addRunApp
pub fn installApp(b: *std.Build, the_app: *App) std.Build.LazyPath {
    const lp = addInstallApp(b, the_app, if (the_app.kind == .android) .lib else .bin);
    lp.addStepDependencies(b.getInstallStep());
    return lp;
}
pub fn addRunApp(b: *std.Build, the_app: *App, install_step: ?std.Build.LazyPath) *std.Build.Step.Run {
    switch (the_app.kind) {
        .glfw_wgpu => return beui_impl_glfw_wgpu.runApp(the_app.dep.?, if (install_step) |s| s else the_app.emitted_file),
        .web => return beui_impl_web.runApp(the_app.dep.?, if (install_step) |s| s else the_app.emitted_file),
        else => {
            const res = std.Build.Step.Run.create(b, "fail");
            const fail_step = b.addFail(b.fmt("TODO addRunApp: {s}", .{@tagName(the_app.kind)}));
            the_app.emitted_file.addStepDependencies(&fail_step.step);
            if (install_step) |is| is.addStepDependencies(&fail_step.step);
            const fail_genf = b.allocator.create(std.Build.GeneratedFile) catch @panic("oom");
            fail_genf.* = .{ .step = &fail_step.step };
            res.addFileArg(.{ .generated = .{ .file = fail_genf } });
            return res;
        },
    }
}

pub fn build(b: *std.Build) !void {
    const format_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&format_step.step);
}
