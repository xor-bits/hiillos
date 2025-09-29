const std = @import("std");
const abi = @import("abi");
const builtin = @import("builtin");

const main = @import("main.zig");
const boot = @import("boot.zig");
const arch = @import("arch.zig");
const addr = @import("addr.zig");

const log = std.log.scoped(.pmem);
const conf = abi.conf;
const volat = abi.util.volat;

//

pub const page_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &page_allocator_vtable,
};
const page_allocator_vtable = std.mem.Allocator.VTable{
    .alloc = &_alloc,
    .resize = &_resize,
    .free = &_free,
    .remap = &_remap,
};

//

pub const Page = [512]u64;

//

pub fn printInfo() void {
    pmem_lock.lock();
    defer pmem_lock.unlock();

    // using boot.memory requires the pmem_lock
    const memory_response = boot.memory.response orelse {
        return;
    };

    var usable_memory: usize = 0;
    var kernel_usage: usize = 0;
    var reclaimable: usize = 0;
    for (memory_response.entries()) |memory_map_entry| {
        const from = memory_map_entry.base;
        const to = memory_map_entry.base + memory_map_entry.len;
        const len = memory_map_entry.len;

        if (memory_map_entry.ty == .executable_and_modules) {
            kernel_usage += len;
        } else if (memory_map_entry.ty == .usable) {
            usable_memory += len;
        } else if (memory_map_entry.ty == .bootloader_reclaimable) {
            reclaimable += len;
        }

        log.info("{t:>22}: [ 0x{x:0>16}..0x{x:0>16} ]", .{ memory_map_entry.ty, from, to });
    }

    var overhead: usize = 0;
    var it = levels.iterator();
    while (it.next()) |level| {
        overhead += level.value.bitmap.len * @sizeOf(u64);
    }

    log.info("usable memory: {0any}B ({0any:.1024}B)", .{
        abi.util.NumberPrefix(usize, .binary).new(usable_memory),
    });
    log.info("bootloader (reclaimable) overhead: {any}B", .{
        abi.util.NumberPrefix(usize, .binary).new(reclaimable),
    });
    log.info("page allocator overhead: {any}B", .{
        abi.util.NumberPrefix(usize, .binary).new(overhead),
    });
    log.info("kernel code overhead: {any}B", .{
        abi.util.NumberPrefix(usize, .binary).new(kernel_usage),
    });
}

pub fn printBits(comptime print: bool) usize {
    pmem_lock.lock();
    defer pmem_lock.unlock();

    var total_unused: usize = 0;

    var it = levels.iterator();
    while (it.next()) |level| {
        var unused: usize = 0;
        for (level.value.bitmap) |*bucket| {
            unused += @popCount(bucket.*);
        }
        total_unused += unused * level.key.sizeBytes();

        if (print)
            log.info("free {}B chunks: {}", .{
                abi.util.NumberPrefix(usize, .binary).new(level.key.sizeBytes()),
                unused,
            });
    }

    if (print)
        log.info("total free: {}B", .{
            abi.util.NumberPrefix(usize, .binary).new(total_unused),
        });

    return total_unused;
}

pub fn usedPages() usize {
    pmem_lock.lock();
    defer pmem_lock.unlock();
    return used_pages;
}

pub fn freePages() usize {
    pmem_lock.lock();
    defer pmem_lock.unlock();
    return usable_pages - used_pages;
}

pub fn totalPages() usize {
    pmem_lock.lock();
    defer pmem_lock.unlock();
    return usable_pages;
}

pub fn isInitialized() bool {
    pmem_lock.lock();
    defer pmem_lock.unlock();
    return pmem_ready;
}

//

var pmem_lock: abi.lock.SpinMutex = .{};

/// tells if the frame allocator can be used already by other parts of the kernel
var pmem_ready = false;

/// how many 4kib pages are currently in use
var used_pages: u32 = 0;
/// how many of the 4kib pages are usable memory
var usable_pages: u32 = 0;

/// approximately 2 bits for each 4KiB page to track
/// 4KiB, 8KiB, 16KiB, 32KiB, .. 2MiB, 4MiB, .., 512MiB and 1GiB chunks
///
/// 1 bit to tell if the chunk is free or allocated
/// and each chunk (except 4KiB) has 2 chunks 'under' it
///
/// additionally each level has a doubly linked list to store
/// free chunks for fast allocations
var levels: std.EnumArray(abi.ChunkSize, Level) = .initFill(.{});

const Level = struct {
    bitmap: []u64 = &.{},
    freelist: std.DoublyLinkedList = .{},
};

const ChunkMetadata = struct {
    freelist_node: std.DoublyLinkedList.Node = .{},
};

// fn bitmapToggle(bitmap: []u64, paddr: addr.Phys, size: abi.ChunkSize) void {
//     const chunk_id = paddr.raw / size.sizeBytes();
//     const bucket_id = chunk_id / 64;
//     const bit_id: u6 = @truncate(chunk_id % 64);

//     const bucket = &bitmap[bucket_id];
//     bucket ^= @as(usize, 1) << bit_id;
// }

const BitmapIndex = struct {
    bucket_id: u58,
    bit_id: u6,
};

fn bitmapIndex(paddr: addr.Phys, size: abi.ChunkSize) BitmapIndex {
    const chunk_id = paddr.raw / size.sizeBytes();
    return .{
        .bucket_id = @truncate(chunk_id / 64),
        .bit_id = @truncate(chunk_id % 64),
    };
}

fn bitmapBuddy(idx: BitmapIndex) BitmapIndex {
    return .{
        .bucket_id = idx.bucket_id,
        .bit_id = idx.bit_id ^ 1,
    };
}

fn bitmapLeftBuddy(idx: BitmapIndex) BitmapIndex {
    return .{
        .bucket_id = idx.bucket_id,
        .bit_id = idx.bit_id & ~@as(u6, 1),
    };
}

fn bitmapAddrOfIndex(idx: BitmapIndex, size: abi.ChunkSize) addr.Phys {
    return addr.Phys.fromInt((@as(u64, idx.bucket_id) * 64 + @as(u64, idx.bit_id)) *
        size.sizeBytes());
}

fn bitmapSet(bitmap: []u64, idx: BitmapIndex) void {
    const bucket = &bitmap[idx.bucket_id];
    bucket.* |= @as(usize, 1) << idx.bit_id;
}

fn bitmapUnset(bitmap: []u64, idx: BitmapIndex) void {
    const bucket = &bitmap[idx.bucket_id];
    bucket.* &= ~(@as(usize, 1) << idx.bit_id);
}

fn bitmapGet(bitmap: []u64, idx: BitmapIndex) bool {
    const bucket = &bitmap[idx.bucket_id];
    return (bucket.* & @as(usize, 1) << idx.bit_id) != 0;
}

fn freelistPop(l: *std.DoublyLinkedList) ?*std.DoublyLinkedList.Node {
    return l.popFirst();
}

fn freelistPush(l: *std.DoublyLinkedList, new_node: *std.DoublyLinkedList.Node) void {
    if (conf.CYCLE_PHYSICAL_MEMORY) {
        l.append(new_node);
    } else {
        l.prepend(new_node);
    }
}

fn debugZeroAllocs(result: addr.Phys, size: abi.ChunkSize) void {
    if (conf.IS_DEBUG) {
        std.debug.assert(isInMemoryKind(result, size.sizeBytes(), .usable));
        std.crypto.secureZero(u64, result.toHhdm().toPtr([*]u64)[0 .. size.sizeBytes() / 8]);
    }
}

// FIXME: return error{OutOfMemory}!addr.Phys
pub fn allocChunk(size: abi.ChunkSize) ?addr.Phys {
    pmem_lock.lock();
    defer pmem_lock.unlock();

    if (debugAssertInitialized()) return null;

    return allocChunkInner(size);
}

fn allocChunkInner(size: abi.ChunkSize) ?addr.Phys {
    const minimum_level = levels.getPtr(size);
    if (freelistPop(&minimum_level.freelist)) |free_chunk| {
        const chunk_metadata: *ChunkMetadata = @fieldParentPtr("freelist_node", free_chunk);
        std.crypto.secureZero(u8, std.mem.asBytes(chunk_metadata));

        const this_chunk = addr.Virt.fromPtr(chunk_metadata).hhdmToPhys();
        bitmapUnset(minimum_level.bitmap, bitmapIndex(this_chunk, size));

        debugZeroAllocs(this_chunk, size);
        return this_chunk;
    }

    // NOTE: the max recursion is controlled by `ChunkSize`
    const parent_chunk_size = size.next() orelse {
        log.warn("out of memory", .{});
        return null;
    };
    const parent_chunk = allocChunkInner(parent_chunk_size) orelse return null;
    // split it in 2, free the first one and return the second

    const buddy_chunk = parent_chunk;
    const buddy_idx = bitmapIndex(buddy_chunk, size);
    const buddy_meta = buddy_chunk.toHhdm().toPtr(*ChunkMetadata);
    const this_chunk = addr.Phys.fromInt(parent_chunk.raw + size.sizeBytes());

    bitmapSet(minimum_level.bitmap, buddy_idx);
    freelistPush(&minimum_level.freelist, &buddy_meta.freelist_node);

    return this_chunk;
}

pub fn deallocChunk(comptime zero: bool, ptr: addr.Phys, size: abi.ChunkSize) void {
    std.debug.assert(ptr.toParts().page != 0);

    if (zero)
        std.crypto.secureZero(u64, ptr.toHhdm().toPtr([*]u64)[0 .. size.sizeBytes() / 8]);

    pmem_lock.lock();
    defer pmem_lock.unlock();

    if (debugAssertInitialized()) return;

    return deallocChunkInner(ptr, size);
}

fn deallocChunkInner(ptr: addr.Phys, size: abi.ChunkSize) void {
    // if the buddy chunk is also free, allocate it and free the parent chunk
    // if the buddy chunk is not free, then just free the current chunk
    //
    // illustration: (0=allocated, left side is the buddy and right side is the current chunk)
    // 00 -> 01 (parent: 0->0), 10 -> 00 (parent: 0->1)

    const level = levels.getPtr(size);

    const this_idx = bitmapIndex(ptr, size);
    const this_meta = ptr.toHhdm().toPtr(*ChunkMetadata);
    const buddy_idx = bitmapBuddy(this_idx);
    const buddy_chunk = bitmapAddrOfIndex(buddy_idx, size);
    const buddy_meta = buddy_chunk.toHhdm().toPtr(*ChunkMetadata);

    if (conf.IS_DEBUG) {
        const current_state = bitmapGet(level.bitmap, this_idx);
        std.debug.assert(!current_state);
    }

    if (size.next()) |parent_size| {
        if (bitmapGet(level.bitmap, buddy_idx)) {
            // buddy is free => allocate the buddy and free the parent

            bitmapUnset(level.bitmap, buddy_idx);
            level.freelist.remove(&buddy_meta.freelist_node);
            std.crypto.secureZero(u8, std.mem.asBytes(buddy_meta));

            const left_idx = bitmapLeftBuddy(this_idx);
            const parent_addr = bitmapAddrOfIndex(left_idx, size);

            return deallocChunkInner(parent_addr, parent_size);
        }
    }

    // buddy is allocated / largest size => free the current
    bitmapSet(level.bitmap, this_idx);
    freelistPush(&level.freelist, &this_meta.freelist_node);
}

//

pub fn init() !void {
    pmem_lock.lock();
    defer pmem_lock.unlock();

    if (conf.IS_DEBUG and pmem_ready) {
        return error.PmmAlreadyInitialized;
    }

    var usable_memory: usize = 0;
    var memory_top: usize = 0;
    const memory_response = boot.memory.response orelse {
        return error.NoMemoryResponse;
    };

    for (memory_response.entries()) |memory_map_entry| {
        // const from = std.mem.alignBackward(usize, memory_map_entry.base, 1 << 12);
        // const to = std.mem.alignForward(usize, memory_map_entry.base + memory_map_entry.length, 1 << 12);
        // const len = to - from;
        const to = memory_map_entry.base + memory_map_entry.len;
        const len = memory_map_entry.len;

        // const ty = @tagName(memory_map_entry.kind);
        // log.info("{s:>22}: [ 0x{x:0>16}..0x{x:0>16} ]", .{ ty, from, to });

        if (memory_map_entry.ty == .usable) {
            usable_memory += len;
            memory_top = @max(to, memory_top);
        } else if (memory_map_entry.ty == .bootloader_reclaimable) {
            memory_top = @max(to, memory_top);
        }
    }

    log.info("allocating bitmaps", .{});
    var it = levels.iterator();
    while (it.next()) |level| {
        const bits = memory_top / level.key.sizeBytes();
        if (bits == 0) continue;

        // log.debug("bits for {}B chunks: {}", .{
        //     util.NumberPrefix(usize, .binary).new(@as(usize, 0x1000) << @truncate(i)),
        //     bits,
        // });

        const bytes = std.math.divCeil(usize, bits, 8) catch bits / 8;
        const buckets = std.math.divCeil(usize, bytes, 8) catch bytes / 8;

        const bitmap_bytes = initAlloc(memory_response.entries(), buckets * @sizeOf(u64), @alignOf(u64)) orelse {
            return error.NotEnoughContiguousMemory;
        };
        const bitmap: []u64 = @as([*]u64, @ptrCast(@alignCast(bitmap_bytes)))[0..buckets];

        // log.info("bitmap from 0x{x} to 0x{x}", .{
        //     @intFromPtr(bitmap.ptr),
        //     @intFromPtr(bitmap.ptr) + bitmap.len * @sizeOf(std.atomic.Value(u64)),
        // });

        // fill with zeroes, so that everything is allocated
        std.crypto.secureZero(u64, @ptrCast(bitmap));

        level.value.* = .{
            .bitmap = bitmap,
        };
    }

    log.info("freeing usable memory", .{});
    for (memory_response.entries()) |memory_map_entry| {
        if (memory_map_entry.ty == .usable) {
            // FIXME: a faster way would be to repeatedly deallocate chunks
            // from smallest to biggest and then to smallest again
            // ex: 1,2,3,7,8,8,8,8,8,8,8,8,8,8,5,4,1

            const base = std.mem.alignForward(usize, memory_map_entry.base, 0x1000);
            const waste = base - memory_map_entry.base;
            memory_map_entry.base += waste;
            memory_map_entry.len -= waste;
            memory_map_entry.len = std.mem.alignBackward(usize, memory_map_entry.len, 0x1000);

            const first_page: u32 = addr.Phys.fromInt(memory_map_entry.base).toParts().page;
            const n_pages: u32 = @truncate(memory_map_entry.len >> 12);
            for (first_page..first_page + n_pages) |page| {
                if (page == 0) {
                    // make sure the 0 phys page is not free
                    // phys addr values of 0 are treated as null
                    @branchHint(.cold);
                    continue;
                }

                deallocChunkInner(addr.Phys.fromParts(.{ .page = @truncate(page) }), .@"4KiB");
            }

            usable_pages += n_pages;
        }
    }

    pmem_ready = true;
}

fn initAlloc(entries: []*boot.LimineMemmapEntry, size: usize, alignment: usize) ?[*]u8 {
    for (entries) |memory_map_entry| {
        if (memory_map_entry.ty != .usable) {
            continue;
        }

        const base = std.mem.alignForward(usize, memory_map_entry.base, alignment);
        const wasted = base - memory_map_entry.base;
        if (wasted + size > memory_map_entry.len) continue;

        memory_map_entry.len -= wasted + size;
        memory_map_entry.base = base + size;

        // log.debug("init alloc 0x{x} B from 0x{x}", .{ size, base });

        return addr.Phys.fromInt(base).toHhdm().toPtr([*]u8);
    }

    return null;
}

//

pub fn alloc(size: usize) ?addr.Phys {
    if (size == 0)
        return addr.Phys.fromInt(0);

    const _size = abi.ChunkSize.of(size) orelse return null;
    return allocChunk(_size);
}

pub fn free(chunk: addr.Phys, size: usize) void {
    if (size == 0)
        return;

    const _size = abi.ChunkSize.of(size) orelse {
        log.err("trying to free a chunk that could not have been allocated", .{});
        return;
    };
    return deallocChunk(true, chunk, _size);
}

pub fn isInMemoryKind(paddr: addr.Phys, size: usize, exp: ?boot.LimineMemmapType) bool {
    for (boot.memory.response.?.entries()) |entry| {
        if (entry.ty != exp) continue;

        // TODO: also check if it even collides with some other entries

        if (paddr.raw >= entry.base and paddr.raw + size <= entry.base + entry.len) {
            return true;
        }
    }

    return exp == null;
}

fn _alloc(_: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const paddr = alloc(len) orelse return null;
    return paddr.toHhdm().toPtr([*]u8);
}

fn _resize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    const chunk_size = abi.ChunkSize.of(buf.len) orelse return false;
    if (chunk_size.sizeBytes() >= new_len) return true;
    return false;
}

fn _free(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
    free(addr.Virt.fromPtr(buf.ptr).hhdmToPhys(), buf.len);
}

fn _remap(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    // physical memory cant be remapped

    const chunk_size = abi.ChunkSize.of(buf.len) orelse return null;
    if (chunk_size.sizeBytes() >= new_len) return buf.ptr;

    return null;
}

fn debugAssertInitialized() bool {
    if (conf.IS_DEBUG and !pmem_ready) {
        log.err("physical memory manager not initialized", .{});
        return true;
    } else {
        return false;
    }
}

test "no collisions" {
    const unused_before = printBits(false);
    var pages: [0x1000]?*Page = undefined;

    // allocate all 4096 pages
    for (&pages) |*page| {
        page.* = page_allocator.create(Page) catch null;
    }

    // zero all of them
    for (&pages) |_page| {
        const page = _page orelse continue;
        std.crypto.secureZero(u64, @ptrCast(page[0..]));
    }

    // check for duplicates
    for (&pages) |_page| {
        // check for duplicates (non-null)
        const page = _page orelse continue;
        var dupe_count: usize = 0;
        for (&pages) |page2| {
            if (page == page2) dupe_count += 1;
        }
        try std.testing.expect(dupe_count == 1);
    }

    // free all of them
    for (&pages) |_page| {
        const page = _page orelse continue;
        page_allocator.destroy(page);
    }

    if (arch.cpuCount() == 1)
        try std.testing.expect(unused_before == printBits(false));
}
