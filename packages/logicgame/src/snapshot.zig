const std = @import("std");

const Encoder = struct {
    rem: []u8,
    fn InputType(comptime T: type) type {
        return *const T;
    }
    pub const ArgType = []u8;
    pub const OutputType = void;
    pub fn init(arg: ArgType) Encoder {
        return .{ .rem = arg };
    }
    fn int(xc: *Encoder, comptime T: type, intval: *const T) !void {
        std.mem.writeInt(u64, xc.rem[0..@sizeOf(T)], intval.*, .little);
        xc.rem = xc.rem[@sizeOf(T)..];
    }
    fn sizedSlice(xs: *Encoder, len: usize, txt: *const []const u8) !void {
        std.debug.assert(len == txt.len);
        @memcpy(xs.rem[0..txt.len], txt.*);
        xs.rem = xs.rem[txt.len..];
    }

    fn result(xs: *Encoder) void {
        std.debug.assert(xs.rem.len == 0);
        return {};
    }
};
const EncoderCounter = struct {
    count: usize,
    fn InputType(comptime T: type) type {
        return *const T;
    }
    pub const ArgType = void;
    pub const OutputType = usize;
    pub fn init(_: ArgType) EncoderCounter {
        return .{ .count = 0 };
    }
    inline fn int(xc: *EncoderCounter, comptime T: type, _: *const T) !void {
        xc.count += @sizeOf(T);
    }
    inline fn sizedSlice(xc: *EncoderCounter, len: usize, txt: *const []const u8) !void {
        std.debug.assert(len == txt.len);
        xc.count += txt.len;
    }

    inline fn result(xc: *EncoderCounter) usize {
        return xc.count;
    }
};
const Decoder = struct {
    rem: []const u8,
    slen: usize,
    pub const ArgType = []const u8;
    fn InputType(comptime T: type) type {
        return *T;
    }
    pub const OutputType = error{Decode}!usize;
    pub fn init(arg: ArgType) Decoder {
        return .{ .rem = arg, .slen = arg.len };
    }
    fn readSlice(xc: *Decoder, len: usize) ![]const u8 {
        if (xc.rem.len < len) return error.Decode;
        defer xc.rem = xc.rem[len..];
        return xc.rem[0..len];
    }
    fn readArray(xc: *Decoder, comptime len: usize) !*const [len]u8 {
        return (try xc.readSlice(len))[0..len];
    }
    fn int(xc: *Decoder, comptime T: type, res: *T) !void {
        const val = try xc.readArray(@sizeOf(T));
        res.* = std.mem.readInt(T, val, .little);
    }
    fn sizedSlice(xc: *Decoder, len: usize, txt: *[]const u8) !void {
        txt.* = try xc.readSlice(len);
    }
    fn result(xc: *Decoder) usize {
        return xc.slen - xc.rem.len;
    }
};

fn XS(comptime Mode: XcodeMode) type {
    return struct {
        const Backing = switch (Mode) {
            .count => EncoderCounter,
            .encode => Encoder,
            .decode => Decoder,
        };
        backing: Backing,
        const XSelf = @This();
        pub const ArgType = Backing.ArgType;
        pub const InputType = Backing.InputType;
        pub const OutputType = Backing.OutputType;
        inline fn init(arg: Backing.ArgType) XSelf {
            return .{ .backing = .init(arg) };
        }
        inline fn int(xc: *XSelf, comptime T: type, intval: Backing.InputType(T)) !void {
            try xc.backing.int(T, intval);
        }
        inline fn sizedSlice(xs: *XSelf, len: usize, txt: Backing.InputType([]const u8)) !void {
            try xs.backing.sizedSlice(len, txt);
        }
        fn slice(xc: *XSelf, txt: Backing.InputType([]const u8)) !void {
            var len: usize = txt.len;
            try xc.int(u64, &len);
            try xc.sizedSlice(len, txt);
        }
        inline fn result(xc: *XSelf) Backing.OutputType {
            return xc.backing.result();
        }
    };
}

const Src = struct {
    module: []const u8,
    file: []const u8,
    fn_name: []const u8,
    actual: []const u8,
    line: u64,
    column: u64,

    fn lessThan(_: void, lhs: Src, rhs: Src) bool {
        if (std.mem.order(u8, lhs.module, rhs.module) == .lt) return true;
        if (std.mem.order(u8, lhs.file, rhs.file) == .lt) return true;
        if (lhs.line < rhs.line) return true;
        return lhs.column < rhs.column;
    }
};
const XcodeMode = enum {
    count,
    encode,
    decode,
};
fn xcodeSrc(
    comptime mode: XcodeMode,
    arg: XS(mode).ArgType,
    value: XS(mode).InputType(Src),
) XS(mode).OutputType {
    var xc = XS(mode).init(arg);

    try xc.slice(&value.module);
    try xc.slice(&value.file);
    try xc.slice(&value.fn_name);
    try xc.slice(&value.actual);
    try xc.int(u64, &value.line);
    try xc.int(u64, &value.column);

    return xc.result();
}

pub fn main() !u8 {
    if (@import("builtin").target.os.tag == .windows) {
        _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
    }
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const gpa = debug_allocator.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) return error.NoArgs;
    const last_arg = args[args.len - 1];
    const middle_args = args[1 .. args.len - 1];
    var update_snapshots = false;
    var spawn_args: std.ArrayList([]const u8) = .empty;
    defer spawn_args.deinit(gpa);
    for (middle_args) |arg| {
        if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--update-snapshots")) {
            update_snapshots = true;
        } else {
            return error.BadArgs;
        }
    }
    try spawn_args.append(gpa, last_arg);

    if (!update_snapshots) {
        if (std.process.can_execv) {
            return std.process.execv(gpa, spawn_args.items);
        } else {
            var proc = std.process.Child.init(spawn_args.items, gpa);
            const term = try proc.spawnAndWait();

            if (term != .Exited) return 1;
            return term.Exited;
        }
    }

    var proc = std.process.Child.init(spawn_args.items, gpa);
    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();
    var rd: [16]u8 = undefined;
    var dprng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    dprng.fill(&rd);
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/znapshot_{x}", .{&rd});
    defer gpa.free(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "" });
    defer std.fs.cwd().deleteFile(path) catch {};
    try env_map.put("ZIG_ZNAPSHOT_FILE", path);
    proc.env_map = &env_map;

    const term = try proc.spawnAndWait();

    const fcont = try std.fs.cwd().readFileAlloc(gpa, path, std.math.maxInt(usize));
    defer gpa.free(fcont);
    var rem = fcont;
    var sourcs = std.array_list.Managed(Src).init(gpa);
    defer sourcs.deinit();
    while (rem.len > 0) {
        var res: Src = undefined;
        const dec_len = try xcodeSrc(.decode, rem, &res);
        rem = rem[dec_len..];
        try sourcs.append(res);
    }
    std.mem.sort(Src, sourcs.items, {}, Src.lessThan);
    var open_file_cont: ?[]const u8 = null;
    defer if (open_file_cont) |of| gpa.free(of);
    var open_file_full_path: ?[]const u8 = null;
    defer if (open_file_full_path) |offp| gpa.free(offp);
    var open_file_new_cont = std.ArrayList(u8).empty;
    defer open_file_new_cont.deinit(gpa);
    var renderres = std.ArrayList(u8).empty;
    defer renderres.deinit(gpa);
    var open_file_module: ?[]const u8 = null;
    var open_file_path: ?[]const u8 = null;
    var open_file_index: usize = 0;
    var open_file_line: usize = 1;
    var open_file_col: usize = 1;
    var open_file_uncommitted: usize = 0;
    for (sourcs.items) |sourc| {
        std.log.debug("src: {any}", .{sourc});
        if (open_file_cont == null or !std.mem.eql(u8, sourc.module, open_file_module.?) or !std.mem.eql(u8, sourc.file, open_file_path.?)) {
            std.log.err("module: {s}", .{sourc.module});
            if (std.mem.eql(u8, "root", sourc.module)) {
                if (open_file_full_path) |offp| {
                    gpa.free(offp);
                    open_file_full_path = null;
                }
                open_file_full_path = try std.fs.path.join(gpa, &.{ "src", sourc.file });
                if (open_file_cont != null) {
                    try finishAndWrite(&open_file_index, &open_file_cont, &open_file_new_cont, gpa, &open_file_uncommitted, &renderres, open_file_full_path);
                }
                open_file_cont = try std.fs.cwd().readFileAlloc(gpa, open_file_full_path.?, std.math.maxInt(usize));
                open_file_new_cont.clearRetainingCapacity();
            } else {
                return error.Err;
            }
            open_file_module = sourc.module;
            open_file_path = sourc.file;
            open_file_index = 0;
            open_file_line = 1;
            open_file_col = 1;
            open_file_uncommitted = 0;
        }

        // alternate, maybe simpler impl:
        // - in the ast tree, find the `@src()` node with the specified lyn/col (this might be trivial? like maybe you scan the tokens array or something)
        // - find the next node after the comma and it to the omit list
        //   - first make sure it's either 'null' or a multiline string
        // - then have add to the print after list
        // - this would use the Fixups api in Ast.render()

        while (open_file_index <= open_file_cont.?.len) {
            std.debug.assert(open_file_line <= sourc.line);
            if (open_file_line == sourc.line) {
                std.debug.assert(open_file_col <= sourc.column);
                if (open_file_col == sourc.column) {
                    // 1. commit up to this point
                    try commitRem(&open_file_new_cont, gpa, open_file_cont, &open_file_uncommitted, open_file_index);
                    // 2. skip /^@src\(\),(\s*null|(\s*\\[^\n]*)+)/
                    const got_len = getLength(open_file_cont.?[open_file_index..]) orelse return error.Bad;
                    for (open_file_cont.?[open_file_index..][0..got_len]) |byte| switch (byte) {
                        '\n' => {
                            open_file_col = 1;
                            open_file_line += 1;
                        },
                        else => open_file_col += 1,
                    };
                    open_file_index += got_len;
                    open_file_uncommitted = open_file_index;
                    // 3. write new text
                    try open_file_new_cont.appendSlice(gpa, "@src(),\n");
                    var iter = std.mem.splitScalar(u8, sourc.actual, '\n');
                    while (iter.next()) |line| {
                        // todo: indent of parent line plus one. or let zig fmt deal with it.
                        try open_file_new_cont.appendSlice(gpa, "\\\\");
                        try open_file_new_cont.appendSlice(gpa, line);
                        try open_file_new_cont.appendSlice(gpa, "\n");
                    }
                    break;
                }
            }

            if (open_file_index == open_file_cont.?.len) break;
            const byte = open_file_cont.?[open_file_index];
            if (byte == '\n') {
                open_file_col = 1;
                open_file_line += 1;
            } else {
                open_file_col += 1;
            }
            open_file_index += 1;
        }
    }
    if (open_file_cont != null) {
        try finishAndWrite(&open_file_index, &open_file_cont, &open_file_new_cont, gpa, &open_file_uncommitted, &renderres, open_file_full_path);
    }

    std.log.info("{d} snapshots updated", .{sourcs.items.len});

    if (term != .Exited) return 1;
    return term.Exited;
}
fn commitRem(open_file_new_cont: *std.ArrayList(u8), gpa: std.mem.Allocator, open_file_cont: ?[]const u8, open_file_uncommitted: *usize, open_file_index: usize) !void {
    try open_file_new_cont.appendSlice(gpa, open_file_cont.?[open_file_uncommitted.*..open_file_index]);
    open_file_uncommitted.* = open_file_index;
}
fn finishAndWrite(open_file_index: *usize, open_file_cont: *?[]const u8, open_file_new_cont: *std.ArrayList(u8), gpa: std.mem.Allocator, open_file_uncommitted: *usize, renderres: *std.ArrayList(u8), open_file_full_path: ?[]const u8) !void {
    // commit and write
    open_file_index.* = open_file_cont.*.?.len;
    try commitRem(open_file_new_cont, gpa, open_file_cont.*, open_file_uncommitted, open_file_index.*);
    try open_file_new_cont.append(gpa, 0);
    var tree = try std.zig.Ast.parse(gpa, open_file_new_cont.items[0 .. open_file_new_cont.items.len - 1 :0], .zig);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return error.UpdErr;
    renderres.clearRetainingCapacity();

    {
        var writer = std.io.Writer.Allocating.fromArrayList(gpa, renderres);
        defer renderres.* = writer.toArrayList();
        try tree.render(gpa, &writer.writer, .{});
    }
    try std.fs.cwd().writeFile(.{ .sub_path = open_file_full_path.?, .data = renderres.items });
    gpa.free(open_file_cont.*.?);
    open_file_cont.* = null;
}

fn getSnapfile() ?[]const u8 {
    const static = struct {
        var _snapfile_written = false;
        var _snapfile: ?[]const u8 = null;
    };
    if (!static._snapfile_written) {
        const snapupd = std.process.getEnvMap(std.heap.smp_allocator) catch return null;
        static._snapfile = snapupd.get("ZIG_ZNAPSHOT_FILE");
        static._snapfile_written = true;
    }
    return static._snapfile;
}

pub fn formattedSnapshot(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype, src: std.builtin.SourceLocation, expected: ?[]const u8) !void {
    var buf = std.array_list.Managed(u8).init(gpa);
    defer buf.deinit();
    try buf.writer().print(fmt, args);
    try snapshot(buf.items, src, expected);
}

pub fn snapshot(actual: []const u8, src: std.builtin.SourceLocation, expected: ?[]const u8) !void {
    if (getSnapfile()) |snapfile| {
        if (expected == null or !std.mem.eql(u8, expected.?, actual)) {
            // waiting on https://github.com/ziglang/zig/issues/14375
            // temporary workaround until then
            var f = try std.fs.cwd().openFile(snapfile, .{ .mode = .read_write });
            defer f.close();
            try f.seekFromEnd(0);

            const srcval: Src = .{
                .module = src.module,
                .file = src.file,
                .fn_name = src.fn_name,
                .actual = actual,
                .line = src.line,
                .column = src.column,
            };
            const count = xcodeSrc(.count, {}, &srcval);
            const buf = try std.heap.smp_allocator.alloc(u8, count);
            defer std.heap.smp_allocator.free(buf);
            xcodeSrc(.encode, buf, &srcval);

            try f.writeAll(buf);

            return; // success (s'posedly)
        }
    }
    if (expected == null or !std.mem.eql(u8, expected.?, actual)) {
        std.log.err("use `-- -u` to update snapshots", .{});
        const EMPTY_SNAPSHOT = "[empty_snapshot]";
        try std.testing.expectEqualStrings(expected orelse if (std.mem.eql(u8, actual, EMPTY_SNAPSHOT)) EMPTY_SNAPSHOT ++ "_" else EMPTY_SNAPSHOT, actual);
    }
}

/// unreviewed llm function:
/// Implement a zig function for this regex: `/^@src\(\),(\s*null|(\s*\\[^\n]*)+)/`
/// The function signature is `fn getLength(input: []const u8) ?usize`. It returns the
/// number of bytes of length of the regex match, or null for no match.
pub fn getLength(input: []const u8) ?usize {
    const prefix = "@src(),";

    // Check for the mandatory prefix /^@src\(\),/
    if (!std.mem.startsWith(u8, input, prefix)) {
        return null;
    }

    const rest = input[prefix.len..];
    var cursor: usize = 0;

    // First alternative: \s*null
    var temp_cursor = cursor;
    while (temp_cursor < rest.len and std.ascii.isWhitespace(rest[temp_cursor])) {
        temp_cursor += 1;
    }
    if (std.mem.startsWith(u8, rest[temp_cursor..], "null")) {
        return prefix.len + temp_cursor + "null".len;
    }

    // Second alternative: (\s*\\[^\n]*)+
    var match_found = false;
    while (cursor < rest.len) {
        var line_start = cursor;

        // Match \s*
        while (line_start < rest.len and std.ascii.isWhitespace(rest[line_start])) {
            line_start += 1;
        }

        if (line_start < rest.len and rest[line_start] == '\\') {
            match_found = true;
            var line_end = line_start + 1;

            // Match [^\n]*
            while (line_end < rest.len and rest[line_end] != '\n') {
                line_end += 1;
            }
            cursor = line_end;
        } else {
            break;
        }
    }

    if (match_found) {
        return prefix.len + cursor;
    }

    return null;
}
