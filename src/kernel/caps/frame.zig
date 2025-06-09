const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const spin = @import("../spin.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const Frame = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    is_physical: bool,
    lock: spin.Mutex = .new(),
    pages: []u32,
    // mappings: caps.Mapping,

    pub fn init(size_bytes: usize) !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Frame.init size={}", .{size_bytes});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.frame);

        if (size_bytes == 0)
            return Error.InvalidArgument;

        const size_pages = std.math.divCeil(usize, size_bytes, 0x1000) catch unreachable;
        if (size_pages > std.math.maxInt(u32)) return error.OutOfMemory;

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        const pages = try caps.slab_allocator.allocator().alloc(u32, size_pages);

        @memset(pages, 0);

        obj.* = .{
            .is_physical = false,
            .lock = .newLocked(),
            .pages = pages,
        };
        obj.lock.unlock();

        return obj;
    }

    pub fn initPhysical(paddr: addr.Phys, size_bytes: usize) !*@This() {
        if (!pmem.isInMemoryKind(paddr, size_bytes, .reserved) and
            !pmem.isInMemoryKind(paddr, size_bytes, .acpi_nvs) and
            !pmem.isInMemoryKind(paddr, size_bytes, .framebuffer) and
            !pmem.isInMemoryKind(paddr, size_bytes, null))
        {
            log.warn("user-space tried to create a frame to memory that isn't one of: [ reserved, acpi_nvs, framebuffer ]", .{});
            return Error.InvalidAddress;
        }

        const aligned_paddr: usize = std.mem.alignBackward(usize, paddr.raw, 0x1000);
        const aligned_size: usize = std.mem.alignForward(usize, size_bytes, 0x1000);

        if (aligned_paddr == 0)
            return Error.InvalidAddress;

        const frame = try Frame.init(aligned_size);
        // just a memory barrier, is_physical is not supposed to be atomic
        @atomicStore(bool, &frame.is_physical, true, .release);

        for (frame.pages, 0..) |*page, i| {
            page.* = addr.Phys.fromInt(aligned_paddr + i * 0x1000).toParts().page;
        }

        return frame;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Frame.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.frame);

        if (!self.is_physical) {
            for (self.pages) |page| {
                if (page == 0) continue;

                pmem.deallocChunk(
                    addr.Phys.fromParts(.{ .page = page }),
                    .@"4KiB",
                );
            }
        }

        caps.slab_allocator.allocator().free(self.pages);
        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Frame.clone", .{});

        self.refcnt.inc();
        return self;
    }

    pub fn write(self: *@This(), offset_bytes: usize, source: []const volatile u8) Error!void {
        var bytes = source;

        if (conf.LOG_OBJ_CALLS)
            log.info("Frame.write offset_bytes={} source.len={}", .{
                offset_bytes,
                source.len,
            });

        const limit = std.math.divCeil(usize, offset_bytes + bytes.len, 0x1000) catch
            return Error.OutOfBounds;

        {
            self.lock.lock();
            defer self.lock.unlock();

            if (limit > self.pages.len)
                return Error.OutOfBounds;
        }

        var it = self.data(offset_bytes, true);
        while (try it.next()) |dst_chunk| {
            if (dst_chunk.len == bytes.len) {
                @memcpy(dst_chunk, bytes);
                break;
            } else if (dst_chunk.len > bytes.len) {
                @memcpy(dst_chunk[0..bytes.len], bytes);
                break;
            } else { // dst_chunk.len < bytes.len
                @memcpy(dst_chunk, bytes[0..dst_chunk.len]);
                bytes = bytes[dst_chunk.len..];
            }
        }
    }

    pub fn read(self: *@This(), offset_bytes: usize, dest: []volatile u8) Error!void {
        var bytes = dest;

        if (conf.LOG_OBJ_CALLS)
            log.info("Frame.read offset_bytes={} dest.len={}", .{
                offset_bytes,
                dest.len,
            });

        const limit = std.math.divCeil(usize, offset_bytes + bytes.len, 0x1000) catch
            return Error.OutOfBounds;

        {
            self.lock.lock();
            defer self.lock.unlock();

            if (limit > self.pages.len)
                return Error.OutOfBounds;
        }

        var it = self.data(offset_bytes, false);
        while (try it.next()) |src_chunk| {
            // log.info("chunk [ 0x{x}..0x{x} ]", .{
            //     @intFromPtr(src_chunk.ptr),
            //     @intFromPtr(src_chunk.ptr) + src_chunk.len,
            // });

            if (src_chunk.len == bytes.len) {
                @memcpy(bytes, src_chunk);
                break;
            } else if (src_chunk.len > bytes.len) {
                @memcpy(bytes, src_chunk[0..bytes.len]);
                break;
            } else { // src_chunk.len < bytes.len
                @memcpy(bytes[0..src_chunk.len], src_chunk);
                bytes = bytes[src_chunk.len..];
            }
        }
    }

    pub const DataIterator = struct {
        frame: *Frame,
        offset_within_first: ?u32,
        idx: u32,
        is_write: bool,

        pub fn next(self: *@This()) !?[]volatile u8 {
            if (self.idx >= self.frame.pages.len)
                return null;

            defer self.idx += 1;
            defer self.offset_within_first = null;

            const page = try self.frame.page_hit(self.idx, self.is_write);

            return addr.Phys.fromParts(.{ .page = page })
                .toHhdm()
                .toPtr([*]volatile u8)[self.offset_within_first orelse 0 .. 0x1000];
        }
    };

    pub fn data(self: *@This(), offset_bytes: usize, is_write: bool) DataIterator {
        if (offset_bytes >= self.pages.len * 0x1000) {
            return .{
                .frame = self,
                .offset_within_first = null,
                .idx = @intCast(self.pages.len),
                .is_write = is_write,
            };
        }

        const first_byte = std.mem.alignBackward(usize, offset_bytes, 0x1000);
        const offset_within_page: ?u32 = if (first_byte == offset_bytes)
            null
        else
            @intCast(offset_bytes - first_byte);

        return .{
            .frame = self,
            .offset_within_first = offset_within_page,
            .idx = @intCast(first_byte / 0x1000),
            .is_write = is_write,
        };
    }

    pub fn page_hit(self: *@This(), idx: u32, is_write: bool) !u32 {
        self.lock.lock();
        defer self.lock.unlock();

        std.debug.assert(idx < self.pages.len);
        const page = &self.pages[idx];

        // const readonly_zero_page_now = readonly_zero_page.load(.monotonic);
        _ = is_write;

        // TODO: (page.* == readonly_zero_page_now or page.* == 0) and is_write
        if (page.* == 0) {
            // writing to a lazy allocated zeroed page
            // => allocate a new exclusive page and set it be the mapping
            // FIXME: modify existing mappings

            const new_page = pmem.allocChunk(.@"4KiB") orelse return error.OutOfMemory;
            page.* = new_page.toParts().page;
            return page.*;
        } else {
            // already mapped AND write to a page that isnt readonly_zero_page or read from any page
            // => use the existing page
            return page.*;
        }

        // else { // page.* == 0
        //     // not mapped and isnt write
        //     // => use the shared readonly zero page

        //     page.* = readonly_zero_page_now;
        //     return page.*;
        // }
    }
};
