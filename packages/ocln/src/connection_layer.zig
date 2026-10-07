const std = @import("std");
const anywhere = @import("anywhere");
const util = anywhere.util;
const math = util.math;
const Grid = anywhere.util.grid.Grid;
const zpool = anywhere.util.zpool;
const print = @import("print.zig");
const loadimage = @import("loadimage");
const vec = util.vec;
const main = @import("main.zig");

const segment_ref_count = 4;

/// represents a layer of connection-type buildings,
/// eg power wires / pipes / logic wires / storage wires / etc
/// would be nice to make this moddable eventually, ie to allow the user to define their own custom layers
/// but for now it will be like this
pub fn ConnectionLayer(comptime User: type, comptime Context: type) type {
    return struct {
        pub const Segment = struct {
            /// technically could save a byte and make safer by using {x,y,len} with a direction flag in len
            /// that way it wouldn't be able to store invalid states. but that seems complicated.
            /// sides[0] <= sides[1]. sides[0] != sides[1]. (min[0] == max[0]) != (min[1] == max[1])
            sides: [2]vec.by2i32,
            user: User,

            pub fn direction(this: *const Segment) enum { x, y } {
                const s1, const s2 = this.sides;
                if (s1[0] == s2[0] and s1[1] == s2[1]) unreachable; // segments must have at least one length
                std.debug.assert(@reduce(.And, s1 <= s2));
                if (s1[0] == s2[0]) return .y;
                if (s1[1] == s2[1]) return .x;
                unreachable; // segments must be either horizontal or vertical
            }
            fn canMergeWith(this: *const Segment, other: *const Segment) bool {
                return this.direction() == other.direction() and this.user.canMergeWith(&other.user);
            }
            pub fn hasSide(this: *const Segment, side: vec.by2i32) bool {
                for (&this.sides) |*our_side| {
                    if (@reduce(.And, our_side.* == side)) return true;
                }
                return false;
            }
        };
        pub const SegmentPool = zpool.Pool(16, 16, Segment, struct { ptr: Segment });

        gpa: std.mem.Allocator,
        coordinate_to_segments_map: std.AutoArrayHashMapUnmanaged(vec.by2i32, [segment_ref_count]SegmentPool.Handle),
        segments: SegmentPool,

        pub fn init(gpa: std.mem.Allocator) @This() {
            return .{
                .gpa = gpa,
                .coordinate_to_segments_map = .empty,
                .segments = .init(gpa),
            };
        }
        pub fn deinit(this: *@This()) void {
            this.coordinate_to_segments_map.deinit(this.gpa);
            this.segments.deinit();
        }

        fn setSegmentRefRange(this: *@This(), fromPos: vec.by2i32, toPos: vec.by2i32, removeHandle: SegmentPool.Handle, addHandle: SegmentPool.Handle) !void {
            std.debug.assert(@reduce(.And, fromPos <= toPos));
            var y: i32 = fromPos[1];
            while (y <= toPos[1]) : (y += 1) {
                var x: i32 = fromPos[0];
                while (x <= toPos[0]) : (x += 1) {
                    try this.setSegmentRef(.{ x, y }, removeHandle, addHandle);
                }
            }
        }
        fn setSegmentRef(this: *@This(), pos: vec.by2i32, remove: SegmentPool.Handle, add: SegmentPool.Handle) !void {
            if (remove.id == add.id) return; // nothing to change
            const gpres = try this.coordinate_to_segments_map.getOrPutValue(this.gpa, pos, @splat(.nil));
            const value = gpres.value_ptr;

            var new_value_buf: [segment_ref_count]SegmentPool.Handle = @splat(.nil);
            var new_value = std.ArrayList(SegmentPool.Handle).initBuffer(&new_value_buf);

            for (value) |item| {
                if (item.id == remove.id) continue; // ignore the item
                if (item.id == add.id) continue; // ignore the item
                if (item.id == SegmentPool.Handle.nil.id) continue; // ignore the item
                new_value.appendAssumeCapacity(item);
            }
            if (add.id != SegmentPool.Handle.nil.id) new_value.appendAssumeCapacity(add);

            // check empy
            if (new_value.items.len == 0) {
                // remove
                std.debug.assert(this.coordinate_to_segments_map.swapRemove(pos)); // invalidates value ptr
                return;
            }

            // update list
            @memcpy(value, &new_value_buf);
        }
        /// returned slice is valid until coordinate_to_segments_map changes
        pub fn getSegments(this: *@This(), pos: vec.by2i32) []SegmentPool.Handle {
            const res = this.coordinate_to_segments_map.getPtr(pos) orelse return &.{};
            const end = for (res, 0..) |*itm, i| {
                if (itm.id == SegmentPool.Handle.nil.id) break i;
            } else res.len;
            for (res[end..]) |*itm| std.debug.assert(itm.id == SegmentPool.Handle.nil.id);
            return res[0..end];
        }
        pub const SegmentDisplay = enum(u8) {
            none = 0b0000,
            all = 0b1111,
            cross_x_over_y = 0b10000,
            cross_y_over_x = 0b10001,
            _,
            const Init = packed struct(u4) {
                left: bool,
                up: bool,
                right: bool,
                down: bool,
            };
            fn init(value: Init) SegmentDisplay {
                return @enumFromInt(@as(u4, @bitCast(value)));
            }
            pub fn toInit(value: SegmentDisplay) Init {
                return switch (value) {
                    .cross_x_over_y, .cross_y_over_x => @bitCast(0b1111),
                    else => @bitCast(@as(u4, @intCast(value.toInt()))),
                };
            }
            pub fn toInt(value: SegmentDisplay) u8 {
                return @intFromEnum(value);
            }
        };
        pub fn getSegmentDisplay(this: *@This(), pos: vec.by2i32) SegmentDisplay {
            const segments = this.getSegments(pos);
            var result: SegmentDisplay.Init = .{
                .left = false,
                .up = false,
                .right = false,
                .down = false,
            };
            for (segments) |segment_handle| {
                const segment: *Segment = this.segments.getColumnPtrAssumeLive(segment_handle, .ptr);
                const bl_eq = @reduce(.And, segment.sides[0] == pos);
                const ur_eq = @reduce(.And, segment.sides[1] == pos);
                switch (segment.direction()) {
                    .x => {
                        if (!bl_eq) result.left = true;
                        if (!ur_eq) result.right = true;
                    },
                    .y => {
                        if (!bl_eq) result.down = true;
                        if (!ur_eq) result.up = true;
                    },
                }
            }
            // in the future we could assign an index to each segment and base it on which index is higher
            if (result.left and result.up and result.right and result.down and segments.len == 2) {
                return .cross_x_over_y;
            }
            return .init(result);
        }
        fn trySplitOneSegment(this: *@This(), w1: SegmentPool.Handle, split_pos: vec.by2i32) !void {
            const w1_data: *Segment = this.segments.getColumnPtrAssumeLive(w1, .ptr);
            var w2_data: Segment = w1_data.*;
            if (w1_data.hasSide(split_pos)) return; // can't split at an endpoint

            w1_data.sides[1] = split_pos;
            w2_data.sides[0] = split_pos;

            const w2 = try this.segments.add(.{ .ptr = w2_data });

            try this.setSegmentRefRange(w2_data.sides[0], w2_data.sides[1], w1, w2);
            // add back w1 to the split point
            try this.setSegmentRef(split_pos, .nil, w1);
        }
        fn trySplitSegments(this: *@This(), context: Context, pos: vec.by2i32) !void {

            // determine if wants split, split
            const segments = this.coordinate_to_segments_map.get(pos) orelse return;
            const wants_split = wants_split: {
                if (context.hasIntrinsic(pos)) break :wants_split true;
                for (segments) |seg| {
                    if (seg.id == SegmentPool.Handle.nil.id) continue;
                    const seg_data: *Segment = this.segments.getColumnPtrAssumeLive(seg, .ptr);
                    if (seg_data.hasSide(pos)) {
                        break :wants_split true;
                    }
                }
                break :wants_split false;
            };
            if (wants_split) {
                for (segments) |seg| {
                    if (!this.segments.isLiveHandle(seg)) continue; // after splitting, the segments list may update. also, seg may be nil.
                    try this.trySplitOneSegment(seg, pos);
                }
            }
        }
        fn tryMergeSegments(this: *@This(), context: Context, shared_point: vec.by2i32) !void {
            const w1, const w2 = blk: {
                const segments = this.getSegments(shared_point);
                if (segments.len < 2) return; // can't merge; not enough segments
                if (segments.len > 2) return; // can't merge; too many segments
                break :blk .{ segments[0], segments[1] };
            };

            if (context.hasIntrinsic(shared_point)) return; // can't merge; there is a machine receiving power at the shared point

            const w1_data: *Segment = this.segments.getColumnPtrAssumeLive(w1, .ptr);
            const w2_data: *Segment = this.segments.getColumnPtrAssumeLive(w2, .ptr);

            if (!w1_data.canMergeWith(w2_data)) return; // can't merge; not same side or not same material

            // can merge
            w1_data.sides[0] = @min(w1_data.sides[0], w2_data.sides[0]);
            w1_data.sides[1] = @max(w1_data.sides[1], w2_data.sides[1]);
            try this.setSegmentRefRange(w2_data.sides[0], w2_data.sides[1], w2, w1);
            this.segments.removeAssumeLive(w2);
            // no need to update materials, they are unchanged.
        }
        pub fn createSegment(this: *@This(), context: Context, segment_in: Segment) !void {
            {
                // create the new segment
                const new_segment = try this.segments.add(.{ .ptr = segment_in });
                const segment: *Segment = this.segments.getColumnPtrAssumeLive(new_segment, .ptr);

                // keep mirrored data in sync
                try this.setSegmentRefRange(segment.sides[0], segment.sides[1], .nil, new_segment);
            }

            // update affected tiles, splitting or merging as needed
            var iter = vec.Iterator(2, i32).minMaxInclusive(segment_in.sides[0], segment_in.sides[1]);
            while (iter.next()) |pos| try this.syncSegments(context, pos);
        }
        pub fn deleteSegment(this: *@This(), context: Context, min: vec.by2i32, max: vec.by2i32) !void {
            // - split at min
            // - split at max
            try this.trySplitSegments(context, min);
            try this.trySplitSegments(context, max);
            // - now iterate and remove
            @compileError("TODO");
        }
        pub fn syncSegments(this: *@This(), context: Context, pos: vec.by2i32) !void {
            try this.trySplitSegments(context, pos);
            try this.tryMergeSegments(context, pos);
        }

        pub fn printCustomFormat(printer: *print.Printer, arg: print.DetailedAny) error{WriteFailed}!void {
            // sort, then print
            const this = arg.cast(@This());
            const gpa = this.gpa;
            var handle_iter = this.segments.liveHandles();
            var segments = std.ArrayList(SegmentPool.Handle).initCapacity(gpa, this.segments.liveHandleCount()) catch return error.WriteFailed;
            defer segments.deinit(gpa);
            while (handle_iter.next()) |handle| segments.appendAssumeCapacity(handle);
            std.mem.sort(SegmentPool.Handle, segments.items, this, lessThanSegmentHandle);

            try printer.setColor(.bright_black);
            try printer.print("ConnectionLayer:", .{});
            try printer.setColor(.reset);
            printer.indent();
            defer printer.dedent();
            for (segments.items) |segment| {
                try printer.newline();
                const ptr = this.segments.getColumnPtrAssumeLive(segment, .ptr);
                try printer.print("{d} <--> {d}: ", .{ ptr.sides[0], ptr.sides[1] });
                try printer.dump(.fromAuto(&ptr.user));
            }
            if (segments.items.len == 0) {
                try printer.print(" (no fields)", .{});
            }
        }
        fn lessThanSegmentHandle(this: *align(1) const @This(), lhs: SegmentPool.Handle, rhs: SegmentPool.Handle) bool {
            const lhs_ptr = this.segments.getColumnPtrAssumeLive(lhs, .ptr);
            const rhs_ptr = this.segments.getColumnPtrAssumeLive(rhs, .ptr);
            if (lhs_ptr.sides[0][1] < rhs_ptr.sides[0][1]) return true;
            if (lhs_ptr.sides[0][1] > rhs_ptr.sides[0][1]) return false;
            if (lhs_ptr.sides[1][1] < rhs_ptr.sides[1][1]) return true;
            if (lhs_ptr.sides[1][1] > rhs_ptr.sides[1][1]) return false;
            if (lhs_ptr.sides[0][0] < rhs_ptr.sides[0][0]) return true;
            if (lhs_ptr.sides[0][0] > rhs_ptr.sides[0][0]) return false;
            if (lhs_ptr.sides[1][0] < rhs_ptr.sides[1][0]) return true;
            if (lhs_ptr.sides[1][0] > rhs_ptr.sides[1][0]) return false;
            unreachable; // there shouldn't be multiple identical segments in the list. uh oh!
        }

        pub fn serdes(comptime mode: util.SerializeDeserialize.Mode, sd: *mode.Value(), v: *@This(), gpa: std.mem.Allocator) !void {
            if (comptime mode.out()) v.* = .{
                .coordinate_to_segments_map = .empty,
                .segments = undefined,
                .gpa = gpa,
            };

            var pool: main.PoolSerdes(SegmentPool, mode) = try .begin(sd, "segments", &.{ .gpa = gpa }, &v.segments);
            defer pool.deinit(&.{ .gpa = gpa });

            try sd.begin("segments.items");
            while (pool.serdesNext()) |handle| {
                try sd.begin("Segment");
                const value = v.segments.getColumnPtrAssumeLive(handle, .ptr);
                if (comptime mode.out()) value.* = .{
                    .sides = undefined,
                    .user = undefined,
                };
                try sd.value2("sides", &value.sides);
                try sd.begin("user");
                try User.serdes(mode, sd, &value.user, &.{ .gpa = gpa });
                try sd.end();
                try sd.end();
            }
            try sd.end();

            if (comptime mode.out()) {
                // keep coordinate_to_segments_map synced
                var iter = v.segments.liveHandles();
                while (iter.next()) |handle| {
                    const seg: *Segment = v.segments.getColumnPtrAssumeLive(handle, .ptr);
                    try v.setSegmentRefRange(seg.sides[0], seg.sides[1], .nil, handle);
                }
            }
            // TODO: validate that the connection layer adheres to the requirements
            // - maybe instead of using the segment PoolSerdes, we could iterate over segments
            //   and create them during deserialization
        }
    };
}
