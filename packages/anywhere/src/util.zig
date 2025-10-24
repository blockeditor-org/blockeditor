const std = @import("std");

pub const AnyPtr = struct {
    id: [*]const u8,
    val: *anyopaque,
    pub fn from(comptime T: type, value: *const T) AnyPtr {
        return .{ .id = @typeName(T), .val = @ptrCast(@constCast(value)) };
    }
    pub fn to(self: AnyPtr, comptime T: type) *T {
        std.debug.assert(self.id == @typeName(T));
        return @ptrCast(@alignCast(self.val));
    }
    pub fn toConst(self: AnyPtr, comptime T: type) *const T {
        std.debug.assert(self.id == @typeName(T));
        return @ptrCast(@alignCast(self.val));
    }
};

pub const testing = struct {
    var mutex = std.Thread.Mutex{};
    var _initialized: std.atomic.Value(bool) = .init(false);
    var _should_update: bool = undefined;
    pub fn snap(src: std.builtin.SourceLocation, expected: []const u8, actual: []const u8) !void {
        if (!_initialized.load(.acquire)) {
            mutex.lock();
            defer mutex.unlock();

            // inside mutex so it's ok to view .raw
            if (_initialized.raw == false) blk: {
                const env_val = std.process.getEnvVarOwned(std.testing.allocator, "ZIG_UPDATE_SNAPSHOT") catch {
                    _should_update = false;
                    break :blk;
                };
                defer std.testing.allocator.free(env_val);
                _should_update = true;
            }
            _initialized.raw = true;
        }
        if (_should_update and !std.mem.eql(u8, expected, actual)) {
            mutex.lock();
            defer mutex.unlock();

            // needs update!
            std.log.err("needs update:\n  module: \"{f}\"\n  file: \"{f}\"\n  pos: {d}:{d}", .{ std.zig.fmtString(src.module), std.zig.fmtString(src.file), src.line, src.column });

            return;
        }
        try std.testing.expectEqualStrings(expected, actual);

        // TODO:
        // - the env var will contain a file
        // - we will append serialized update information to the file:
        //   - what module, what file, what pos, what was the old value, what is the new value
        // - an 'update snapshot' script will read this file and:
        //   - for each file:
        //     - convert all lyn:col to byte offset
        //     - sort so the highest byte offsets are first
        //     - deduplicate any values with the same byte offset
        //       - if they are not identical, remove them entirely & error
        //     - at the source location, validate that the expected string appears:
        //       "@src(),\n", then count whitespace, then expect "\\\\"
        //     - parse the existing string. if it is not equal to the old value, error
        //     - replace it with the new string.
        // - (alternatively) we can have the update happen in the snap mutex:
        //   - will have to write every time anything changes
        //   - we keep a cache of what the original was here, then for every update we generate out the new
        //     and write it
    }
};

pub const build = struct {
    fn arbitraryName(b: *std.Build, name: []const u8, comptime ty: type) []const u8 {
        return b.fmt("__exposearbitrary_{d}_{s}_{d}", .{ @intFromPtr(b), name, @intFromPtr(@typeName(ty)) });
    }
    pub fn expose(b: *std.Build, name: []const u8, comptime ty: type, val: ty) void {
        const valdupe = dupeOne(b.allocator, val) catch @panic("oom");
        const valv = b.allocator.create(AnyPtr) catch @panic("oom");
        valv.* = .from(ty, valdupe);
        const name_fmt = arbitraryName(b, name, ty);
        b.named_lazy_paths.putNoClobber(name_fmt, .{ .cwd_relative = @as([*]u8, @ptrCast(valv))[0..1] }) catch @panic("oom");
    }
    pub fn find(dep: *std.Build.Dependency, comptime ty: type, name: []const u8) ty {
        const name_fmt = arbitraryName(dep.builder, name, ty);
        const modv = dep.builder.named_lazy_paths.get(name_fmt).?;
        const anyptr: *const AnyPtr = @ptrCast(@alignCast(modv.cwd_relative.ptr));
        std.debug.assert(anyptr.id == @typeName(ty));
        return anyptr.to(ty).*;
    }

    pub const LibcFileOptions = struct {
        /// The directory that contains `stdlib.h`.
        /// On POSIX-like systems, include directories be found with: `cc -E -Wp,-v -xc /dev/null`
        include_dir: ?std.Build.LazyPath,
        /// The system-specific include directory. May be the same as `include_dir`.
        /// On Windows it's the directory that includes `vcruntime.h`.
        /// On POSIX it's the directory that includes `sys/errno.h`.
        sys_include_dir: ?std.Build.LazyPath,
        /// The directory that contains `crt1.o` or `crt2.o`.
        /// On POSIX, can be found with `cc -print-file-name=crt1.o`.
        /// Not needed when targeting MacOS.
        crt_dir: ?std.Build.LazyPath,
        /// The directory that contains `vcruntime.lib`.
        /// Only needed when targeting MSVC on Windows.
        msvc_lib_dir: ?std.Build.LazyPath,
        /// The directory that contains `kernel32.lib`.
        /// Only needed when targeting MSVC on Windows.
        kernel32_lib_dir: ?std.Build.LazyPath,
        /// The directory that contains `crtbeginS.o` and `crtendS.o`
        /// Only needed when targeting Haiku.
        gcc_dir: ?std.Build.LazyPath,
    };
    pub fn genLibCFile(b: *std.Build, anywhere_dep: *std.Build.Dependency, libc_file_options: LibcFileOptions) std.Build.LazyPath {
        const make_libc_file = b.addRunArtifact(anywhere_dep.artifact("libc_file_builder"));
        inline for (@typeInfo(LibcFileOptions).@"struct".fields) |field| {
            if (@field(libc_file_options, field.name)) |val| {
                make_libc_file.addPrefixedDirectoryArg(field.name ++ "=", val);
            } else {
                make_libc_file.addArg(field.name ++ "=");
            }
        }
        const make_libc_stdout = make_libc_file.captureStdOut();
        return make_libc_stdout;
    }
};

pub fn DistinctUUID(comptime Distinct: type) type {
    return enum(u128) {
        const Self = @This();
        pub const _distinct = Distinct;
        _,

        /// must use crypto secure prng!
        pub fn fromRandom(csprng: std.Random) Self {
            return @enumFromInt(csprng.int(u128));
        }

        const chars = "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz";
        const chars_bits = std.math.log2_int(usize, chars.len);
        comptime {
            std.debug.assert(chars_bits == std.math.log2_int_ceil(usize, chars.len));
            var prev: u8 = 0;
            for (chars) |char| {
                if (char <= prev) {
                    @compileLog(char);
                    @compileLog(prev);
                    @compileError("char <= prev. see compile logs below.");
                }
                prev = char;
            }
        }

        pub fn format(value: Self, writer: *std.Io.Writer) !void {
            const value_u128: u128 = @intFromEnum(value);
            comptime std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
            const value_bytes = std.mem.sliceAsBytes(&[_]u128{value_u128});
            var reader_fbs = std.Io.fixedBufferStream(value_bytes);
            var reader_bits = @import("deprecated/bit_reader.zig").bitReader(.little, reader_fbs.reader());
            var result_buffer: [24]u8 = [_]u8{0} ** 24;
            result_buffer[0] = '-';
            result_buffer[23] = '-';
            for (1..23) |i| {
                var actual_bits: u16 = 0;
                const read_bits = reader_bits.readBits(usize, chars_bits, &actual_bits) catch @panic("fbs error");
                result_buffer[i] = chars[read_bits];
            }

            // assert at end
            {
                var actual_bits: u16 = 0;
                _ = reader_bits.readBits(u1, 1, &actual_bits) catch @panic("fbs error");
                std.debug.assert(actual_bits == 0);
            }

            try writer.writeAll(&result_buffer);
        }
    };
}

pub fn ThreadQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        _raw_queue: Queue(T),
        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{
                ._raw_queue = .init(alloc),
                .mutex = .{},
                .condition = .{},
            };
        }
        pub fn deinit(self: *Self) void {
            if (!self.mutex.tryLock()) @panic("cannot deinit while another thread uses the queue");
            self._raw_queue.deinit();
        }

        pub fn write(self: *Self, value: T) void {
            self.writeMany(&.{value});
        }
        pub fn writeMany(self: *Self, value: []const T) void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                self._raw_queue.write(value) catch @panic("oom");
            }
            self.signal();
        }
        pub fn kill(self: *Self) void {
            self.kill_thread.store(true, .monotonic);
            self.condition.signal();
        }
        /// returns null if there is no item available at this moment
        pub fn tryRead(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self._raw_queue.readItem();
        }
        /// returns null if should_kill is true (must signal())
        pub fn waitRead(self: *Self, should_kill: *std.atomic.Value(bool)) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (true) {
                if (should_kill.load(.monotonic)) return null;
                if (self._raw_queue.readableLength() != 0) break;
                self.condition.wait(&self.mutex);
            }

            return self._raw_queue.readItem().?;
        }
        /// call this after changing should_kill
        pub fn signal(self: *Self) void {
            self.condition.signal();
        }
    };
}

pub fn Queue(comptime T: type) type {
    return @import("deprecated/fifo.zig").LinearFifo(T, .Dynamic);
}

pub fn Callback(comptime Arg_: type, comptime Ret_: type) type {
    // callback2: pub const ArgsTuple = std.meta.Tuple(Args);
    return struct {
        const Self = @This();
        cb: *const fn (data: usize, arg: Arg) Ret,
        data: usize,

        pub const Arg = Arg_;
        pub const Ret = Ret_;
        pub fn from(data: anytype, comptime cb: fn (data: @TypeOf(data), arg: Arg) Ret) Self {
            comptime std.debug.assert(@sizeOf(@TypeOf(data)) == @sizeOf(usize));
            const data_usz: usize = @intFromPtr(data);
            const update_fn = struct {
                fn update_fn(data_: usize, arg: Arg) Ret {
                    return cb(@ptrFromInt(data_), arg);
                }
            }.update_fn;
            return .{ .cb = &update_fn, .data = data_usz };
        }
        pub fn call(self: Self, arg: Arg) Ret {
            return self.cb(self.data, arg);
        }
        pub fn eql(self: Self, other: Self) bool {
            return self.cb == other.cb and self.data == other.data;
        }
    };
}

pub fn CallbackList(comptime cb_type: type) type {
    return struct {
        const Self = @This();
        callbacks: std.array_list.Managed(cb_type),
        pub fn init(alloc: std.mem.Allocator) Self {
            return .{
                .callbacks = std.array_list.Managed(cb_type).init(alloc),
            };
        }
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.callbacks.items.len == 0);
            self.callbacks.deinit();
        }

        pub fn addListener(self: *Self, cb: cb_type) void {
            self.callbacks.append(cb) catch @panic("oom");
        }
        pub fn removeListener(self: *Self, cb: cb_type) void {
            const i = for (self.callbacks.items, 0..) |ufn, i| {
                if (ufn.eql(cb)) break i;
            } else return; // already removed
            _ = self.callbacks.swapRemove(i); // unordered should be okay
        }
        pub fn emit(self: *Self, arg: cb_type.Arg) void {
            if (cb_type.Ret != void) @compileLog(cb_type.Ret);
            for (self.callbacks.items) |cb| {
                cb.call(arg);
            }
        }
    };
}

// is Align necessary? can we skip it and make asPtr return *align(4) T?
pub fn AnySized(comptime Size: comptime_int, comptime Align: comptime_int) type {
    return struct {
        data: [Size]u8 align(Align),
        ty: if (std.debug.runtime_safety) [*:0]const u8 else void,

        pub fn from(comptime T: type, value: T) @This() {
            comptime {
                std.debug.assert(@sizeOf(T) <= Size);
                std.debug.assert(@alignOf(T) <= Align);
            }
            var result_bytes: [Size]u8 = [_]u8{0} ** Size;
            const bytes = std.mem.asBytes(&value);
            @memcpy(result_bytes[0..bytes.len], bytes);
            return .{
                .data = result_bytes,
                .ty = if (std.debug.runtime_safety) @typeName(T) else void,
            };
        }
        pub fn asPtr(self: *@This(), comptime T: type) *T {
            if (std.debug.runtime_safety) std.debug.assert(self.ty == @typeName(T));
            return std.mem.bytesAsValue(T, &self.data);
        }
        pub fn as(self: @This(), comptime T: type) T {
            if (std.debug.runtime_safety) std.debug.assert(self.ty == @typeName(T));
            return std.mem.bytesAsValue(T, &self.data).*;
        }
    };
}
test AnySized {
    const Any = AnySized(16, 16);

    var my_any = Any.from(u32, 25);
    try std.testing.expectEqual(@as(u32, 25), my_any.as(u32));
    my_any.asPtr(u32).* += 12;
    try std.testing.expectEqual(@as(u32, 25 + 12), my_any.as(u32));
}

pub fn fpsToMspf(fps: f64) f64 {
    return (1.0 / fps) * 1000.0;
}
pub const FixedTimestep = struct {
    start_ms: f64,
    last_update_ms: f64,
    total_updates_applied: usize,
    /// to change this, do fixed_timestep = .init(new_mspf);
    target_mspf: f64,
    pub fn init(target_mspf: f64) FixedTimestep {
        return .{ .start_ms = 0, .last_update_ms = 0, .total_updates_applied = 0, .target_mspf = target_mspf };
    }
    fn reset(self: *FixedTimestep, now_ms: f64) void {
        self.start_ms = now_ms;
        self.last_update_ms = now_ms;
        self.total_updates_applied = 0;
    }
    pub fn advance(self: *FixedTimestep, now_ms: f64) usize {
        self.last_update_ms = now_ms;

        const expected_update_count = @floor((self.last_update_ms - self.start_ms) / self.target_mspf);
        const actual_update_count: f64 = @floatFromInt(self.total_updates_applied);

        const expected_vs_actual_diff = expected_update_count - actual_update_count;

        if (expected_vs_actual_diff < 0) {
            // went backwards in time
            self.reset(now_ms);
            return 1;
        }
        if (expected_vs_actual_diff > 4) {
            // lagging or behind for more than four frames
            self.reset(now_ms);
            return 1;
        }
        const result: usize = @intFromFloat(expected_vs_actual_diff);
        self.total_updates_applied += result;
        return result;
    }
};

pub const SerializeDeserialize = struct {
    pub const Mode = enum { count, serialize, deserialize };

    pub fn Value(comptime T: type, comptime mode: Mode) type {
        return switch (mode) {
            .count => struct {
                src: *const T,
                count: usize = 0,
                pub inline fn int(self: *@This(), comptime Int: type, comptime endian: std.builtin.Endian, _: Int) error{}!void {
                    _ = endian;
                    self.count += @sizeOf(Int);
                }
                pub inline fn slice(self: *@This(), comptime Entry: type, value: []align(1) const Entry) error{}!void {
                    self.count += value.len * @sizeOf(Entry);
                }
                pub const Ret = usize;
            },
            .serialize => struct {
                src: *const T,
                res: []u8,
                fn _get(self: *@This(), n: usize) []u8 {
                    if (self.res.len < n) unreachable;
                    const res = self.res[0..n];
                    self.res = self.res[n..];
                    return res;
                }
                fn _getC(self: *@This(), comptime n: usize) *[n]u8 {
                    if (self.res.len < n) unreachable;
                    const res = self.res[0..n];
                    self.res = self.res[n..];
                    return res;
                }
                pub fn int(self: *@This(), comptime Int: type, comptime endian: std.builtin.Endian, value: Int) !Int {
                    std.mem.writeInt(Int, self._getC(@sizeOf(Int)), value, endian);
                    return value;
                }
                pub fn slice(self: *@This(), comptime Entry: type, value: []align(1) const Entry) ![]align(1) const Entry {
                    comptime std.debug.assert(std.meta.hasUniqueRepresentation(Entry));
                    const res = self._get(value.len * @sizeOf(Entry));
                    @memcpy(res, std.mem.sliceAsBytes(value));
                    return value;
                }
                pub const Ret = void;
            },
            .deserialize => struct {
                src_txt: []const u8,
                fn _get(self: *@This(), n: usize) ![]const u8 {
                    if (self.src_txt.len < n) return error.DeserializeError;
                    const res = self.src_txt[0..n];
                    self.src_txt = self.src_txt[n..];
                    return res;
                }
                fn _getC(self: *@This(), comptime n: usize) !*const [n]u8 {
                    if (self.src_txt.len < n) return error.DeserializeError;
                    const res = self.src_txt[0..n];
                    self.src_txt = self.src_txt[n..];
                    return res;
                }
                pub fn int(self: *@This(), comptime Int: type, comptime endian: std.builtin.Endian, _: void) !Int {
                    return std.mem.readInt(Int, try self._getC(@sizeOf(Int)), endian);
                }
                pub fn slice(self: *@This(), comptime Entry: type, len: usize) ![]align(1) const Entry {
                    comptime std.debug.assert(std.meta.hasUniqueRepresentation(Entry));
                    const res = try self._get(len * @sizeOf(Entry));
                    return std.mem.bytesAsSlice(Entry, res);
                }
                pub const Ret = T;
            },
        };
    }
};

pub fn safeAlignCast(comptime alignment: std.mem.Alignment, slice: []const u8) ![]align(alignment.toByteUnits()) const u8 {
    const ptr_casted = try std.math.alignCast(alignment, slice.ptr);
    return ptr_casted[0..slice.len];
}
pub fn safeAlignCastMut(comptime alignment: std.mem.Alignment, slice: []u8) ![]align(alignment.toByteUnits()) u8 {
    const ptr_casted = try std.math.alignCast(alignment, slice.ptr);
    return ptr_casted[0..slice.len];
}
pub fn safePtrCast(comptime T: type, slice: []const u8) !*const T {
    // 1. aligncast
    const aligned = try safeAlignCast(.of(T), slice);
    // 2. check size
    if (aligned.len != @sizeOf(T)) return error.BadSize;
    // 3. ok
    return @ptrCast(aligned);
}
pub fn safePtrCastMut(comptime T: type, slice: []u8) !*T {
    // 1. aligncast
    const aligned = try safeAlignCastMut(.of(T), slice);
    // 2. check size
    if (aligned.len != @sizeOf(T)) return error.BadSize;
    // 3. ok
    return @ptrCast(aligned);
}
pub fn safeSliceCast(comptime T: type, slice: []const u8) ![]const T {
    // 1. aligncast
    const aligned = try safeAlignCast(.of(T), slice);
    // 2. check size
    if (@rem(aligned.len, @sizeOf(T)) != 0) return error.BadSize;
    // 3. ok
    return std.mem.bytesAsSlice(T, aligned);
}
pub fn safeStarSliceCast(comptime T: type, slice: []const u8) ![]const T {
    // 1. aligncast
    const aligned = try safeAlignCast(.of(T), slice);
    // 2. fit size
    const new_size = @divFloor(aligned.len, @sizeOf(T)) * @sizeOf(T);
    // 3. ok
    return std.mem.bytesAsSlice(T, aligned[0..new_size]);
}
pub fn dupeOne(allocator: std.mem.Allocator, value: anytype) !*@TypeOf(value) {
    const value_ptr = try allocator.create(@TypeOf(value));
    value_ptr.* = value;
    return value_ptr;
}

pub fn centerIn(container_max: f32, item_height: f32) f32 {
    return (container_max - item_height) / 2;
}

pub fn replaceInvalidUtf8(str_in: []u8) void {
    const replacement_char = '?';
    var str = str_in;
    while (str.len > 0) {
        // disallow null byte
        if (str[0] == '\x00') {
            str[0] = replacement_char;
            str = str[1..];
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(str[0]) catch {
            str[0] = replacement_char;
            str = str[1..];
            continue;
        };
        if (str.len < seq_len) {
            str[0] = replacement_char;
            str = str[1..];
            continue;
        }
        _ = std.unicode.utf8Decode(str[0..seq_len]) catch {
            str[0] = replacement_char;
            str = str[1..];
            continue;
        };
        str = str[seq_len..];
    }
}

const unicode = struct {
    pub const Encoding = enum {
        utf8_replace_invalid,
        fn Unit(self: Encoding) type {
            return switch (self) {
                .utf8_replace_invalid => u8,
            };
        }
        fn isWtf8(self: Encoding) bool {
            return switch (self) {
                .utf8_replace_invalid => false,
            };
        }
        fn isAssert(self: Encoding) bool {
            return switch (self) {
                .utf8_replace_invalid => false,
            };
        }
    };
    pub const first_high_surrogate = 0xD800;
    pub const last_high_surrogate = 0xDBFF;
    pub const first_low_surrogate = 0xDC00;
    pub const last_low_surrogate = 0xDFFF;
    pub const replacement_character = 0xFFFD;
    pub const DecodeResult = struct { codepoint: u21, advance: u2 };
    pub inline fn decodeFirst(comptime encoding: unicode.Encoding, slice: []const encoding.Unit()) ?DecodeResult {
        // inline is used because it significantly improves performance
        // another perf improvement is to use u32 for codepoint & u32 for advance. but we are skipping that one because
        // it's clearly a zig bug.
        if (slice.len == 0) return null;
        const s0 = slice[0];
        // consider changing the advance in failure based on eg '[4][x][x][1]' could be [0xFFFD][1] rather than [0xFFFD][0xFFFD][0xFFFD][1]
        const failure: DecodeResult = .{ .codepoint = replacement_character, .advance = 1 };
        switch (encoding) {
            .utf8_replace_invalid => {
                const T = i32;
                const len: u32 = switch (s0) {
                    0b0000_0000...0b0111_1111 => return .{ .codepoint = s0, .advance = 1 },
                    0b1100_0000...0b1101_1111 => 2,
                    0b1110_0000...0b1110_1111 => 3,
                    0b1111_0000...0b1111_0111 => 4,
                    else => {
                        if (comptime encoding.isAssert()) unreachable;
                        return failure;
                    },
                };
                if (len > slice.len) {
                    if (comptime encoding.isAssert()) unreachable;
                    // this means (0b11110)(0b10)(0b10)(0b0) will read as (?)(?)(?)(ascii)
                    // alternatively, here we could read the actual number of trail bytes like TextDecoder does
                    // to convert to (?)(ascii), two fewer 0xFFFD bytes
                    return failure;
                    // and below, rather than break :failure, we can return .advance = (number of trail bytes read)
                    // this would not match node
                }

                const s1 = slice[1];
                if ((s1 & 0xC0) != 0x80) {
                    if (comptime encoding.isAssert()) unreachable;
                    return failure;
                }
                if (len == 2) {
                    const cp = @as(T, s0 & 0x1F) << 6 | @as(T, s1 & 0x3F);
                    if (cp < 0x80) {
                        if (comptime encoding.isAssert()) unreachable;
                        return failure;
                    }
                    return .{ .codepoint = cp, .advance = 2 };
                }

                const s2 = slice[2];
                if ((s2 & 0xC0) != 0x80) {
                    if (comptime encoding.isAssert()) unreachable;
                    return failure;
                }
                if (len == 3) {
                    const cp = (@as(T, s0 & 0x0F) << 12) | (@as(T, s1 & 0x3F) << 6) | (@as(T, s2 & 0x3F));
                    if (cp < 0x800) {
                        if (comptime encoding.isAssert()) unreachable;
                        return failure;
                    }
                    if (!encoding.isWtf8()) {
                        if (cp >= first_high_surrogate and cp <= last_high_surrogate or cp >= first_low_surrogate and cp <= last_low_surrogate) {
                            if (comptime encoding.isAssert()) unreachable;
                            return failure;
                        }
                    }
                    return .{ .codepoint = cp, .advance = 3 };
                }

                const s3 = slice[3];
                if ((s3 & 0xC0) != 0x80) {
                    if (comptime encoding.isAssert()) unreachable;
                    return failure;
                }
                {
                    const cp = (@as(T, s0 & 0x07) << 18) | (@as(T, s1 & 0x3F) << 12) | (@as(T, s2 & 0x3F) << 6) | (@as(T, s3 & 0x3F));
                    if (cp < 0x10000 or cp > 0x10FFFF) {
                        if (comptime encoding.isAssert()) unreachable;
                        return failure;
                    }
                    return .{ .codepoint = cp, .advance = 4 };
                }

                unreachable;
            },
        }
    }
};
