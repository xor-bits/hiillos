const std = @import("std");
const abi = @import("abi");
const builtin = @import("builtin");
const limine = @import("limine");

const main = @import("main.zig");
const arch = @import("arch.zig");
const addr = @import("addr.zig");
const util = @import("util.zig");

const log = std.log.scoped(.pmem);
const conf = abi.conf;

//

pub export var memory: limine.MemoryMapRequest = .{};

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
    const memory_response: *limine.MemoryMapResponse = memory.response orelse {
        return;
    };

    var usable_memory: usize = 0;
    var kernel_usage: usize = 0;
    var reclaimable: usize = 0;
    for (memory_response.entries()) |memory_map_entry| {
        const from = memory_map_entry.base;
        const to = memory_map_entry.base + memory_map_entry.length;
        const len = memory_map_entry.length;

        if (memory_map_entry.kind == .kernel_and_modules) {
            kernel_usage += len;
        } else if (memory_map_entry.kind == .usable) {
            usable_memory += len;
        } else if (memory_map_entry.kind == .bootloader_reclaimable) {
            reclaimable += len;
        }

        const ty = @tagName(memory_map_entry.kind);
        log.info("{s:>22}: [ 0x{x:0>16}..0x{x:0>16} ]", .{ ty, from, to });
    }

    var overhead: usize = 0;
    var it = bitmaps.iterator();
    while (it.next()) |level| {
        overhead += level.value.bitmap.len * @sizeOf(u64);
    }

    log.info("usable memory: {0any}B ({0any:.1024}B)", .{
        util.NumberPrefix(usize, .binary).new(usable_memory),
    });
    log.info("bootloader (reclaimable) overhead: {any}B", .{
        util.NumberPrefix(usize, .binary).new(reclaimable),
    });
    log.info("page allocator overhead: {any}B", .{
        util.NumberPrefix(usize, .binary).new(overhead),
    });
    log.info("kernel code overhead: {any}B", .{
        util.NumberPrefix(usize, .binary).new(kernel_usage),
    });
}

pub fn printBits(comptime print: bool) usize {
    var total_unused: usize = 0;

    var it = bitmaps.iterator();
    while (it.next()) |level| {
        var unused: usize = 0;
        for (level.value.bitmap) |*bucket| {
            unused += @popCount(bucket.load(.unordered));
        }
        total_unused += unused * level.key.sizeBytes();

        if (print)
            log.info("free {}B chunks: {}", .{
                util.NumberPrefix(usize, .binary).new(level.key.sizeBytes()),
                unused,
            });
    }

    if (print)
        log.info("total free: {}B", .{
            util.NumberPrefix(usize, .binary).new(total_unused),
        });

    return total_unused;
}

pub fn usedPages() usize {
    return used.load(.monotonic);
}

pub fn freePages() usize {
    return totalPages() - usedPages();
}

pub fn totalPages() usize {
    return usable.load(.monotonic);
}

pub fn isInitialized() bool {
    return pmem_ready;
}

//

/// tells if the frame allocator can be used already internally (debugging)
var initialized = if (conf.IS_DEBUG) false else {};

/// tells if the frame allocator can be used already by other parts of the kernel
var pmem_ready = false;

/// approximately 2 bits for each 4KiB page to track
/// 4KiB, 8KiB, 16KiB, 32KiB, .. 2MiB, 4MiB, .., 512MiB and 1GiB chunks
///
/// 1 bit to tell if the chunk is free or allocated
/// and each chunk (except 4KiB) has 2 chunks 'under' it
var bitmaps: std.EnumArray(abi.ChunkSize, Level) = .initFill(.{});

const Level = struct {
    bitmap: []std.atomic.Value(u64) = &.{},

    // avail: std.atomic.Value(u32) = .init(0),

    /// just an atomic index hint to rotate around the memory instead of starting the
    /// finding process from 0 every time, because pages arent usually freed almost instantly
    next: std.atomic.Value(u32) = .init(0),
};

/// how many pages are currently in use (approx)
var used = std.atomic.Value(u32).init(0);

/// how many pages are usable
var usable = std.atomic.Value(u32).init(0);

// FIXME: return error{OutOfMemory}!addr.Phys
pub fn allocChunk(size: abi.ChunkSize) ?addr.Phys {
    if (debugAssertInitialized()) return null;

    const bitmap: []std.atomic.Value(u64) = bitmaps.get(size).bitmap;
    for (bitmap, 0..) |*bucket, i| {
        // bucket contains 64 bits, each controlling one chunk

        // quickly skip over 64 chunks at a time if none of them is free
        const now = bucket.load(.acquire);
        if (now == 0) continue;

        // const lowest = @as(u64, 2) << @intCast(@ctz(now));
        const highest = @as(u64, 0x8000000000000000) >> @intCast(@clz(now));

        std.debug.assert(@popCount(highest) == 1);
        const now2 = bucket.fetchAnd(~highest, .acquire);

        if (now2 & highest != 0) {
            // success: bit set to 0 from 1 before anyone else
            const result = addr.Phys.fromInt((std.math.log2_int(u64, highest) + 64 * i) * size.sizeBytes());
            if (conf.IS_DEBUG) {
                std.debug.assert(isInMemoryKind(result, size.sizeBytes(), .usable));
                std.crypto.secureZero(u64, result.toHhdm().toPtr([*]volatile u64)[0..512]);
            }
            return result;
        }
    }

    // NOTE: the max recursion is controlled by `ChunkSize`
    const parent_chunk = allocChunk(size.next() orelse return null) orelse return null;
    // split it in 2, free the first one and return the second

    const chunk_id = parent_chunk.raw / size.sizeBytes();
    const bucket_id = chunk_id / 64;
    const bit_id: u6 = @truncate(chunk_id % 64);

    const bucket = &bitmap[bucket_id];
    _ = bucket.fetchOr(@as(usize, 1) << bit_id, .monotonic); // maybe monotonic instead of release, because nothing is written into it

    const result = addr.Phys.fromInt(parent_chunk.raw + size.sizeBytes());
    if (conf.IS_DEBUG) {
        std.debug.assert(isInMemoryKind(result, size.sizeBytes(), .usable));
        std.crypto.secureZero(u64, result.toHhdm().toPtr([*]volatile u64)[0..512]);
    }
    return result;
}

pub fn deallocChunk(ptr: addr.Phys, size: abi.ChunkSize) void {
    std.debug.assert(ptr.toParts().page != 0);

    // if the buddy chunk is also free, allocate it and free the parent chunk
    // if the buddy chunk is not free, then just free the current chunk
    //
    // illustration: (0=allocated, left side is the buddy and right side is the current chunk)
    // 00 -> 01 (parent: 0->0), 10 -> 00 (parent: 0->1)

    if (debugAssertInitialized()) return;

    const chunk_id = ptr.raw / size.sizeBytes();
    const bucket_id = chunk_id / 64;
    const bit_id: u6 = @truncate(chunk_id % 64);

    const bitmap: []std.atomic.Value(u64) = bitmaps.get(size).bitmap;
    const bucket = &bitmap[bucket_id];

    std.debug.assert((bucket.load(.acquire) & (@as(usize, 1) << bit_id)) == 0);

    // 2 cases:
    // the buddy is on the right side
    // the buddy is on the left side
    const buddy_id: u6 = if (bit_id % 2 == 0) bit_id + 1 else bit_id - 1;

    // if (size == .@"4KiB") {
    //     log.info("freeing chunk_id={} bucket_id={} bit_id={} buddy_id={}", .{
    //         chunk_id, bucket_id, bit_id, buddy_id,
    //     });
    // }
    // log.info("freeing {}", .{size});

    const next_size = size.next() orelse size;
    const is_next_size = size.next() != null;

    while (true) {
        const now = bucket.load(.acquire);

        if ((now & (@as(usize, 1) << buddy_id)) != 0 and is_next_size) {
            // buddy is free => allocate the buddy and free the parent

            if (null == bucket.cmpxchgWeak(now, now & ~(@as(usize, 1) << buddy_id), .release, .monotonic)) {
                const parent_ptr = addr.Phys.fromInt(std.mem.alignBackward(usize, ptr.raw, next_size.sizeBytes()));
                deallocChunk(parent_ptr, next_size);
                return; // tail call optimization hopefully?
            }

            // retry when some other bit was changed or a sporadic failure happened
        } else {
            // buddy is allocated => free the current

            if (null == bucket.cmpxchgWeak(now, now | (@as(usize, 1) << bit_id), .release, .monotonic)) {
                return;
            }

            // retry when some other bit was changed or a sporadic failure happened
        }
    }
}

//

pub fn init() !void {
    if (conf.IS_DEBUG and initialized) {
        return error.PmmAlreadyInitialized;
    }

    var usable_memory: usize = 0;
    var memory_top: usize = 0;
    const memory_response: *limine.MemoryMapResponse = memory.response orelse {
        return error.NoMemoryResponse;
    };

    for (memory_response.entries()) |memory_map_entry| {
        // const from = std.mem.alignBackward(usize, memory_map_entry.base, 1 << 12);
        // const to = std.mem.alignForward(usize, memory_map_entry.base + memory_map_entry.length, 1 << 12);
        // const len = to - from;
        const to = memory_map_entry.base + memory_map_entry.length;
        const len = memory_map_entry.length;

        // const ty = @tagName(memory_map_entry.kind);
        // log.info("{s:>22}: [ 0x{x:0>16}..0x{x:0>16} ]", .{ ty, from, to });

        if (memory_map_entry.kind == .usable) {
            usable_memory += len;
            memory_top = @max(to, memory_top);
        } else if (memory_map_entry.kind == .bootloader_reclaimable) {
            memory_top = @max(to, memory_top);
        }
    }

    log.info("allocating bitmaps", .{});
    var it = bitmaps.iterator();
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
        const bitmap: []std.atomic.Value(u64) = @as([*]std.atomic.Value(u64), @alignCast(@ptrCast(bitmap_bytes)))[0..buckets];

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

    util.volat(&initialized).* = if (conf.IS_DEBUG) true else {};

    log.info("freeing usable memory", .{});
    for (memory_response.entries()) |memory_map_entry| {
        if (memory_map_entry.kind == .usable) {
            // FIXME: a faster way would be to repeatedly deallocate chunks
            // from smallest to biggest and then to smallest again
            // ex: 1,2,3,7,8,8,8,8,8,8,8,8,8,8,5,4,1

            const base = std.mem.alignForward(usize, memory_map_entry.base, 0x1000);
            const waste = base - memory_map_entry.base;
            memory_map_entry.base += waste;
            memory_map_entry.length -= waste;
            memory_map_entry.length = std.mem.alignBackward(usize, memory_map_entry.length, 0x1000);

            const first_page: u32 = addr.Phys.fromInt(memory_map_entry.base).toParts().page;
            const n_pages: u32 = @truncate(memory_map_entry.length >> 12);
            for (first_page..first_page + n_pages) |page| {
                if (page == 0) {
                    // make sure the 0 phys page is not free
                    // phys addr values of 0 are treated as null
                    @branchHint(.cold);
                    continue;
                }

                deallocChunk(addr.Phys.fromParts(.{ .page = @truncate(page) }), .@"4KiB");
            }

            _ = usable.fetchAdd(n_pages, .monotonic);
        }
    }

    util.volat(&pmem_ready).* = true;

    printInfo();
}

fn initAlloc(entries: []*limine.MemoryMapEntry, size: usize, alignment: usize) ?[*]u8 {
    for (entries) |memory_map_entry| {
        if (memory_map_entry.kind != .usable) {
            continue;
        }

        const base = std.mem.alignForward(usize, memory_map_entry.base, alignment);
        const wasted = base - memory_map_entry.base;
        if (wasted + size > memory_map_entry.length) continue;

        memory_map_entry.length -= wasted + size;
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
    return deallocChunk(chunk, _size);
}

pub fn isInMemoryKind(paddr: addr.Phys, size: usize, exp: ?limine.MemoryMapEntryType) bool {
    for (memory.response.?.entries()) |entry| {
        if (entry.kind != exp) continue;

        // TODO: also check if it even collides with some other entries

        if (paddr.raw >= entry.base and paddr.raw + size <= entry.base + entry.length) {
            return true;
        }
    }

    return exp == null;
}

pub fn memoryKind(paddr: addr.Phys, size: usize) bool {
    for (memory.response.?.entries()) |entry| {

        // TODO: also check if it even collides with some other entries

        if (paddr.raw >= entry.base and paddr.raw + size <= entry.base + entry.length) {
            return entry.kind;
        }
    }

    return false;
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
    if (conf.IS_DEBUG and !initialized) {
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
