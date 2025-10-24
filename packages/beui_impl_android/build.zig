const std = @import("std");
const anywhere = @import("anywhere");

const TargetInfo = struct {
    query: std.Target.Query,
    dir: []const u8,
};

const target_map = std.StaticStringMap(TargetInfo).initComptime(.{
    .{ "armeabi-v7a", TargetInfo{ .query = .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .androideabi }, .dir = "arm-linux-androideabi" } },
    .{ "arm64-v8a", TargetInfo{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android }, .dir = "aarch64-linux-android" } },
    .{ "x86", TargetInfo{ .query = .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .android }, .dir = "i686-linux-android" } },
    .{ "x86_64", TargetInfo{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .android }, .dir = "x86_64-linux-android" } },
});

pub const BuildCache = struct {
    INCLUDE_DIR: ?[]const u8 = null,
    CRT1_PATH: ?[]const u8 = null,
    CMAKE_ANDROID_ARCH_ABI: ?[]const u8 = null,
    ANDROID_LIB: ?[]const u8 = null,
    ANDROID_PLATFORM: ?[]const u8 = null,
    LOG_LIB: ?[]const u8 = null,
    GLESV3_LIB: ?[]const u8 = null,

    pub fn toJson(opts: BuildCache, arena: std.mem.Allocator) []const u8 {
        var w = std.Io.Writer.Allocating.init(arena);
        defer w.deinit();
        std.json.Stringify.value(opts, .{ .whitespace = .indent_4 }, &w.writer) catch |e| {
            std.log.warn("failed to stringify json: {s}", .{@errorName(e)});
            @panic("failure");
        };
        return w.toOwnedSlice() catch @panic("oom");
    }
    pub fn fromJsonAllocIfNeeded(arena: std.mem.Allocator, cache_text: []const u8) ?BuildCache {
        return std.json.parseFromSliceLeaky(BuildCache, arena, cache_text, .{ .allocate = .alloc_if_needed }) catch |e| {
            std.log.warn("malformatted build-options-cache: {s}", .{@errorName(e)});
            return null;
        };
    }

    pub fn getTargetOptimize(opts: BuildCache, b: *std.Build) struct { std.Build.ResolvedTarget, std.builtin.OptimizeMode } {
        if (!std.mem.startsWith(u8, opts.ANDROID_PLATFORM.?, "android-")) std.debug.panic("bad ANDROID_PLATFORM={s}", .{opts.ANDROID_PLATFORM.?});
        const target_info = target_map.get(opts.CMAKE_ANDROID_ARCH_ABI.?) orelse @panic("TODO support android arch abi");
        var target_query: std.Target.Query = target_info.query;
        target_query.android_api_level = std.fmt.parseInt(u32, opts.ANDROID_PLATFORM.?["android-".len..], 10) catch std.debug.panic("bad ANDROID_PLATFORM={s}", .{opts.ANDROID_PLATFORM.?});
        const target = b.resolveTargetQuery(target_query);
        const optimize: std.builtin.OptimizeMode = .Debug;
        return .{ target, optimize };
    }
};

pub fn buildCacheOptions(b: *std.Build) BuildCache {
    // consider moving into .zig-cache/ of the root
    const cache_file_path = ".build-options-cache.json";
    var opts: BuildCache = blk: {
        const cache_text = b.cache_root.handle.readFileAlloc(b.allocator, cache_file_path, 1000 * 1000) catch |e| {
            std.log.warn("no existing build-options-cache: {s}", .{@errorName(e)});
            break :blk .{};
        };
        break :blk BuildCache.fromJsonAllocIfNeeded(b.allocator, cache_text) orelse .{};
    };

    opts.INCLUDE_DIR = b.option([]const u8, "INCLUDE_DIR", "") orelse opts.INCLUDE_DIR orelse {
        std.log.err(
            \\Android-specific build options have not been provided (missing INCLUDE_DIR).
            \\
            \\  - The first build from Android Studio will cache these build options.
            \\  - After this, `zig build` may be used for error checking.
            \\
        , .{});
        std.process.exit(1);
    };
    opts.CRT1_PATH = b.option([]const u8, "CRT1_PATH", "") orelse opts.CRT1_PATH orelse @panic("missing CRT1_PATH");

    opts.CMAKE_ANDROID_ARCH_ABI = b.option([]const u8, "CMAKE_ANDROID_ARCH_ABI", "") orelse opts.CMAKE_ANDROID_ARCH_ABI orelse @panic("missing CMAKE_ANDROID_ARCH_ABI");
    opts.ANDROID_LIB = b.option([]const u8, "ANDROID_LIB", "") orelse opts.ANDROID_LIB orelse @panic("missing ANDROID_LIB");
    opts.ANDROID_PLATFORM = b.option([]const u8, "ANDROID_PLATFORM", "") orelse opts.ANDROID_PLATFORM orelse @panic("missing ANDROID_PLATFORM");
    opts.LOG_LIB = b.option([]const u8, "LOG_LIB", "") orelse opts.LOG_LIB orelse @panic("missing LOG_LIB");
    opts.GLESV3_LIB = b.option([]const u8, "GLESV3_LIB", "") orelse opts.GLESV3_LIB orelse @panic("missing GLESV3_LIB");

    blk: {
        const printed = opts.toJson(b.allocator);
        var buf: [4096]u8 = @splat(0);
        var atomic_file = b.cache_root.handle.atomicFile(cache_file_path, .{ .write_buffer = &buf }) catch |e| {
            std.log.warn("failed to open json output file: {s}", .{@errorName(e)});
            break :blk;
        };
        defer atomic_file.deinit();
        atomic_file.file_writer.interface.writeAll(printed) catch |e| {
            std.log.warn("failed to writeAll build-options-cache.json: {s}", .{@errorName(e)});
            break :blk;
        };
        atomic_file.file_writer.interface.flush() catch |e| {
            std.log.warn("failed to writeAll build-options-cache.json: {s}", .{@errorName(e)});
            break :blk;
        };
        atomic_file.finish() catch |e| {
            std.log.warn("failed to finish json output file: {s}", .{@errorName(e)});
            break :blk;
        };
    }

    return opts;
}

pub fn createApp(self_dep: *std.Build.Dependency, app_mod: *std.Build.Module) struct { []const u8, []const u8, std.Build.LazyPath } {
    const b = self_dep.builder;
    const pass_info = anywhere.util.build.find(self_dep, PassInfo, "pass_info");

    const target = pass_info.target;
    const optimize = pass_info.optimize;
    const opts = pass_info.opts;

    // https://github.com/ziglang/zig/issues/20327#issuecomment-2382059477 we need to specify a libc file
    // for every addStaticLibrary, addDynamicLibrary call otherwise this won't compile
    const beui_dep = b.dependency("beui", .{ .target = target, .optimize = optimize });

    const lib = b.addLibrary(.{
        .name = "zigpart",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
        }),
    });
    b.installArtifact(lib);

    fixAndroidLibcForCompile(lib);
    lib.linkLibC();
    if (target.result.cpu.arch == .x86) lib.link_z_notext = true; // https://github.com/ziglang/zig/issues/7935
    lib.addLibraryPath(.{ .cwd_relative = opts.CRT1_PATH.? });
    lib.linkSystemLibrary("android");
    lib.linkSystemLibrary("log");
    lib.linkSystemLibrary("GLESv3");
    lib.root_module.addImport("app", app_mod);
    lib.root_module.addImport("beui", beui_dep.module("beui"));

    return .{ lib.name, lib.out_filename, lib.getEmittedBin() };
}
var _fix_android_libc: ?std.Build.LazyPath = null;
pub fn fixAndroidLibc(b: *std.Build) void {
    if (_fix_android_libc) |_| {
        // HACK: fish out every dependency's Compile steps and set thier libc files (& depend on the step).
        // needed until zig has an answer for libc txt in pkg trees.
        var id_iter = b.graph.dependency_cache.valueIterator();
        while (id_iter.next()) |itm| {
            fixAndroidLibcForBuilder(itm.*.builder);
        }
        fixAndroidLibcForBuilder(b);
    }
}
fn fixAndroidLibcForBuilder(b: *std.Build) void {
    for (b.install_tls.step.dependencies.items) |dep_step| {
        const inst = dep_step.cast(std.Build.Step.InstallArtifact) orelse continue;
        fixAndroidLibcForCompile(inst.artifact);
    }
}
fn fixAndroidLibcForCompile(lib: *std.Build.Step.Compile) void {
    if (lib.libc_file != null) return; // already handled
    if (_fix_android_libc == null) return;
    if (lib.rootModuleTarget().abi.isAndroid()) {
        lib.setLibCFile(_fix_android_libc.?);
        _fix_android_libc.?.addStepDependencies(&lib.step); // work around bug where setLibCFile doesn't add the step dependency

        // fixPicForModule(b, &lib.root_module);
    }
}

const PassInfo = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    opts: BuildCache,
};

pub fn build(b: *std.Build) !void {
    const opts = BuildCache.fromJsonAllocIfNeeded(b.allocator, b.option([]const u8, "android", "android value").?).?;
    const target, const optimize = opts.getTargetOptimize(b);
    const target_info = target_map.get(opts.CMAKE_ANDROID_ARCH_ABI.?) orelse @panic("TODO support android arch abi");
    const SYS_INCLUDE_DIR = b.fmt("{s}/{s}", .{ opts.INCLUDE_DIR.?, target_info.dir });

    const anywhere_dep = b.dependency("anywhere", .{});
    const make_libc_stdout = anywhere.util.build.genLibCFile(b, anywhere_dep, .{
        .include_dir = .{ .cwd_relative = opts.INCLUDE_DIR.? },
        .sys_include_dir = .{ .cwd_relative = SYS_INCLUDE_DIR },
        .crt_dir = .{ .cwd_relative = opts.CRT1_PATH.? },
        .msvc_lib_dir = null,
        .kernel32_lib_dir = null,
        .gcc_dir = null,
    });

    if (_fix_android_libc != null) @panic("android libc twice!!! uh oh  oh oh");
    _fix_android_libc = make_libc_stdout;

    const format_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&format_step.step);

    anywhere.util.build.expose(b, "pass_info", PassInfo, .{
        .target = target,
        .optimize = optimize,
        .opts = opts,
    });
}
