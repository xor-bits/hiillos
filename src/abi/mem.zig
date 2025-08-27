const std = @import("std");

const rt = @import("rt.zig");
const abi = @import("lib.zig");

//

pub const server_page_allocator = std.mem.Allocator{
    .ptr = @ptrFromInt(0x1000),
    .vtable = &.{
        .alloc = ServerPageAllocator.alloc,
        .resize = ServerPageAllocator.resize,
        .remap = ServerPageAllocator.remap,
        .free = ServerPageAllocator.free,
    },
};

pub const slab_allocator = slab_allocator_inst.allocator();
var slab_allocator_inst: SlabAllocator = .init(server_page_allocator);

const ServerPageAllocator = struct {
    fn alloc(_: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        const vmem = abi.caps.Vmem.self;

        const size = std.mem.alignForward(usize, len, 0x1000);

        const frame = abi.caps.Frame.create(size) catch return null;
        defer frame.close();

        const addr = vmem.map(
            frame,
            0,
            0,
            0,
            .{
                .fixed = false,
                .write = true,
            },
        ) catch return null;

        if (abi.conf.IS_DEBUG)
            abi.util.fillVolatile(
                u8,
                @as([*]u8, @ptrFromInt(addr))[0..size],
                0xFA,
            );

        return @ptrFromInt(addr);
    }

    fn resize(_: *anyopaque, mem: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        const n = abi.ChunkSize.of(mem.len) orelse return false;
        return n.sizeBytes() >= new_len;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
        const vmem = abi.caps.Vmem.self;

        const size = std.mem.alignForward(usize, buf.len, 0x1000);

        if (abi.conf.IS_DEBUG)
            abi.util.fillVolatile(u8, buf.ptr[0..size], 0xFA);

        vmem.unmap(
            @intFromPtr(buf.ptr),
            size,
        ) catch return;
    }
};

pub const SlabAllocator = struct {
    page_allocator: std.mem.Allocator,

    // chunks broken into smaller pieces
    locks: [9]abi.lock.SpinMutex = .{abi.lock.SpinMutex{}} ** 9,
    slabs: [9]FreeList = .{FreeList{}} ** 9,

    // // bigger chunks
    // chunk_locks: [18]abi.thread.Mutex = .{abi.thread.Mutex{}} ** 18,
    // chunks: [18]FreeList = .{FreeList{}} ** 18,

    const Self = @This();

    pub fn init(page_allocator: std.mem.Allocator) Self {
        return Self{
            .page_allocator = page_allocator,
        };
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .alloc = Self.alloc,
                .resize = Self.resize,
                .remap = Self.remap,
                .free = Self.free,
            },
        };
    }

    fn alloc(p: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(p));

        if (SlabSize.of(len)) |slab_size| {
            const i = @intFromEnum(slab_size);
            const lock = &self.locks[i];
            const slab = &self.slabs[i];

            {
                lock.lock();
                defer lock.unlock();

                if (slab.next) |next| {
                    slab.next = next.next;
                    return @ptrCast(next);
                }
            }

            // 4 pages per chunk
            const chunk: []u8 = self.page_allocator.alloc(u8, 0x4000) catch return null;

            // form a linked list out of the items
            // but keep one of them
            for (1..0x4000 / slab_size.sizeBytes() - 1) |item_idx| {
                const prev = @as(*FreeList, @alignCast(@ptrCast(&chunk[item_idx * slab_size.sizeBytes()])));
                const next = @as(*FreeList, @alignCast(@ptrCast(&chunk[(item_idx + 1) * slab_size.sizeBytes()])));
                prev.next = next;
            }

            const first = @as(*FreeList, @alignCast(@ptrCast(&chunk[0])));
            const second = @as(*FreeList, @alignCast(@ptrCast(&chunk[1 * slab_size.sizeBytes()])));
            const last = @as(*FreeList, @alignCast(@ptrCast(&chunk[(0x4000 / slab_size.sizeBytes() - 1) * slab_size.sizeBytes()])));

            lock.lock();
            defer lock.unlock();

            last.next = slab.next;
            slab.next = second;

            if (abi.conf.IS_DEBUG)
                abi.util.fillVolatile(u8, @as([*]u8, @ptrCast(first))[0..slab_size.sizeBytes()], 0xFA);

            return @ptrCast(first);
        } else {
            return self.page_allocator.rawAlloc(len, alignment, ret_addr);
        }
    }

    fn resize(p: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(p));

        if (SlabSize.of(mem.len)) |slab_size| {
            return slab_size.sizeBytes() >= new_len;
        } else {
            return self.page_allocator.rawResize(mem, alignment, new_len, ret_addr);
        }
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        // const self: *Self = @ptrCast(@alignCast(p));

        return null;
    }

    fn free(p: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(p));

        if (SlabSize.of(mem.len)) |slab_size| {
            const i = @intFromEnum(slab_size);
            const lock = &self.locks[i];
            const slab = &self.slabs[i];

            if (abi.conf.IS_DEBUG)
                abi.util.fillVolatile(u8, mem.ptr[0..slab_size.sizeBytes()], 0xFA);

            const new_head: *FreeList = @alignCast(@ptrCast(mem.ptr));

            lock.lock();
            defer lock.unlock();

            new_head.next = slab.next;
            slab.next = new_head;
        } else {
            return self.page_allocator.rawFree(mem, alignment, ret_addr);
        }
    }
};

const FreeList = struct {
    next: ?*FreeList = null,
};

pub const SlabSize = enum(u5) {
    @"8B",
    @"16B",
    @"32B",
    @"64B",
    @"128B",
    @"256B",
    @"512B",
    @"1KiB",
    @"2KiB",

    pub fn of(n_bytes: usize) ?SlabSize {
        const slab_size = @max(3, std.math.log2_int_ceil(usize, n_bytes)) - 3;
        if (slab_size >= 9) return null;
        return @enumFromInt(slab_size);
    }

    pub fn next(self: @This()) ?@This() {
        return std.meta.intToEnum(@This(), @intFromEnum(self) + 1) catch return null;
    }

    pub fn sizeBytes(self: @This()) usize {
        return @as(usize, 8) << @intFromEnum(self);
    }
};
