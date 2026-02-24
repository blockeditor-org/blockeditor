const std = @import("std");
const anywhere = @import("anywhere");
const util = anywhere.util;
const math = util.math;
const Grid = anywhere.util.grid.Grid;
const zpool = anywhere.util.zpool;
const print = @import("print.zig");
const loadimage = @import("loadimage");
const vec = util.vec;

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

            fn direction(this: *const Segment) enum { x, y } {
                const s1, const s2 = this.sides;
                if (s1[0] == s2[0] and s1[1] == s2[1]) unreachable; // segments must have at least one length
                std.debug.assert(@reduce(.And, s1 <= s2));
                if (s1[0] == s2[0]) return .x;
                if (s1[1] == s2[1]) return .y;
                unreachable; // segments must be either horizontal or vertical
            }
            fn canMergeWith(this: *const Segment, other: *const Segment) bool {
                return this.direction() == other.direction() and this.user.canMergeWith(&other.user);
            }
            fn hasSide(this: *const Segment, side: vec.by2i32) bool {
                for (&this.sides) |*our_side| {
                    if (@reduce(.And, our_side.* == side)) return true;
                }
                return false;
            }
        };
        const SegmentPool = zpool.Pool(16, 16, Segment, struct { ptr: Segment });

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
        pub fn getSegments(this: *@This(), pos: vec.by2i32) [segment_ref_count]SegmentPool.Handle {
            return this.coordinate_to_segments_map.get(pos) orelse return @splat(.nil);
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
            const segments = this.getSegments(pos);
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
            var w1: SegmentPool.Handle = .nil;
            var w2: SegmentPool.Handle = .nil;
            for (this.getSegments(shared_point)) |segment| {
                if (segment.id == SegmentPool.Handle.nil.id) continue;
                for ([_]*SegmentPool.Handle{ &w1, &w2 }) |w| {
                    if (w.*.id == SegmentPool.Handle.nil.id) {
                        w.* = segment;
                        break;
                    }
                } else return; // can't merge; too many segments
            }
            if (w1.id == SegmentPool.Handle.nil.id or w2.id == SegmentPool.Handle.nil.id) return; // can't merge; not enough segments
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
    };
}
