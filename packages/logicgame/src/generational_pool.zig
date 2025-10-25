const std = @import("std");

pub const MemoryPoolOptions = struct {
    /// The alignment of the memory pool items. Use `null` for natural alignment.
    alignment: ?Alignment = null,

    /// If `true`, the memory pool can allocate additional items after a initial setup.
    /// If `false`, the memory pool will not allocate further after a call to `initPreheated`.
    growable: bool = true,
};
pub const MemoryPoolError = error{OutOfMemory};
const Alignment = std.mem.Alignment;
/// modified stdlib memory pool to not set item memory to undefined
pub fn MemoryPoolExtra(comptime Item: type, comptime pool_options: MemoryPoolOptions) type {
    return struct {
        const Pool = @This();

        /// Size of the memory pool items. This is not necessarily the same
        /// as `@sizeOf(Item)` as the pool also uses the items for internal means.
        pub const item_size = @max(@sizeOf(Node), @sizeOf(Item));

        // This needs to be kept in sync with Node.
        const node_alignment: Alignment = .of(*anyopaque);

        /// Alignment of the memory pool items. This is not necessarily the same
        /// as `@alignOf(Item)` as the pool also uses the items for internal means.
        pub const item_alignment: Alignment = node_alignment.max(pool_options.alignment orelse .of(Item));

        const Node = struct {
            next: ?*align(item_alignment.toByteUnits()) @This(),
        };
        const NodePtr = *align(item_alignment.toByteUnits()) Node;
        const ItemPtr = *align(item_alignment.toByteUnits()) Item;

        arena: std.heap.ArenaAllocator,
        free_list: ?NodePtr = null,

        /// Creates a new memory pool.
        pub fn init(allocator: std.mem.Allocator) Pool {
            return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        }

        /// Creates a new memory pool and pre-allocates `initial_size` items.
        /// This allows the up to `initial_size` active allocations before a
        /// `OutOfMemory` error happens when calling `create()`.
        pub fn initPreheated(allocator: std.mem.Allocator, initial_size: usize) MemoryPoolError!Pool {
            var pool = init(allocator);
            errdefer pool.deinit();
            try pool.preheat(initial_size);
            return pool;
        }

        /// Destroys the memory pool and frees all allocated memory.
        pub fn deinit(pool: *Pool) void {
            pool.arena.deinit();
            pool.* = undefined;
        }

        /// Preheats the memory pool by pre-allocating `size` items.
        /// This allows up to `size` active allocations before an
        /// `OutOfMemory` error might happen when calling `create()`.
        pub fn preheat(pool: *Pool, size: usize) MemoryPoolError!void {
            var i: usize = 0;
            while (i < size) : (i += 1) {
                const raw_mem = try pool.allocNew();
                const free_node = @as(NodePtr, @ptrCast(raw_mem));
                free_node.* = Node{
                    .next = pool.free_list,
                };
                pool.free_list = free_node;
            }
        }

        pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

        /// Resets the memory pool and destroys all allocated items.
        /// This can be used to batch-destroy all objects without invalidating the memory pool.
        ///
        /// The function will return whether the reset operation was successful or not.
        /// If the reallocation  failed `false` is returned. The pool will still be fully
        /// functional in that case, all memory is released. Future allocations just might
        /// be slower.
        ///
        /// NOTE: If `mode` is `free_all`, the function will always return `true`.
        pub fn reset(pool: *Pool, mode: ResetMode) bool {
            // TODO: Potentially store all allocated objects in a list as well, allowing to
            //       just move them into the free list instead of actually releasing the memory.

            const reset_successful = pool.arena.reset(mode);

            pool.free_list = null;

            return reset_successful;
        }

        /// Creates a new item and adds it to the memory pool.
        pub fn create(pool: *Pool) !struct { bool, ItemPtr } {
            const node, const existing = if (pool.free_list) |item| blk: {
                pool.free_list = item.next;
                break :blk .{ item, true };
            } else if (pool_options.growable)
                .{ @as(NodePtr, @ptrCast(try pool.allocNew())), false }
            else
                return error.OutOfMemory;

            return .{ existing, @as(ItemPtr, @ptrCast(node)) };
        }

        /// Destroys a previously created item.
        /// Only pass items to `ptr` that were previously created with `create()` of the same memory pool!
        pub fn destroy(pool: *Pool, ptr: ItemPtr) void {
            const node = @as(NodePtr, @ptrCast(ptr));
            node.* = Node{
                .next = pool.free_list,
            };
            pool.free_list = node;
        }

        fn allocNew(pool: *Pool) MemoryPoolError!*align(item_alignment.toByteUnits()) [item_size]u8 {
            const mem = try pool.arena.allocator().alignedAlloc(u8, item_alignment, item_size);
            return mem[0..item_size]; // coerce slice to array pointer
        }
    };
}
pub fn GenerationalPool(comptime T: type, comptime cfg: struct {
    keep_list: enum { no, unordered, ordered } = .no,
}) type {
    return struct {
        const keep_list = cfg.keep_list;
        pool: MemoryPoolExtra(Val, .{}),
        list: if (keep_list != .no) std.array_list.Managed(ID) else void,
        pub const ID = struct { gen: u64, idx: *Val };
        const Val = struct { gen: u64, val: T };
        const Self = @This();

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .pool = .init(gpa), .list = if (keep_list != .no) .init(gpa) };
        }
        pub fn deinit(self: *Self) void {
            self.pool.deinit();
            if (keep_list != .no) self.list.deinit();
        }

        pub fn add(self: *Self, val: T) !ID {
            const existing, const val_ptr = try self.pool.create();
            if (!existing) val_ptr.gen = 0;
            val_ptr.* = .{
                .gen = val_ptr.gen,
                .val = val,
            };
            const id: ID = .{ .gen = val_ptr.gen, .idx = val_ptr };
            if (keep_list != .no) {
                try self.list.append(id);
            }
            return id;
        }
        pub fn remove(self: *Self, id: ID) void {
            if (id.gen != id.idx.gen) return; // double-remove
            // id.idx = @ptrInvalidate(id.idx)
            self.pool.destroy(id.idx);
            id.idx.gen += 1;
            if (keep_list != .no) {
                const idx = for (self.list.items, 0..) |it, i| {
                    if (it.gen == id.gen and it.val == id.val) break i;
                } else unreachable;
                if (keep_list == .unordered) {
                    try self.list.swapRemove(idx);
                } else {
                    try self.list.orderedRemove(idx);
                }
            }
        }
        /// the pointer is invalidated if the item is removed
        pub fn mut(_: *const Self, id: ID) ?*T {
            if (id.gen != id.idx.gen) return null;
            return &id.idx.val;
        }
    };
}
