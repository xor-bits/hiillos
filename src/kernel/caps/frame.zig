const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const apic = @import("../apic.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const main = @import("../main.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");
const spin = @import("../spin.zig");
const util = @import("../util.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const Frame = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    // flag that tells if this frame is being modified while the lock is not held
    // TODO: a small hashmap style functionality, where each bit locks 1/8 of all pages
    is_transient: bool = false,
    transient_sleep_queue: util.Queue(caps.Thread, "next", "prev") = .{},
    tlb_shootdown_refcnt: abi.epoch.RefCnt = .{ .refcnt = .init(0) },

    is_physical: bool,
    lock: spin.Mutex = .new(),
    pages: []u32,
    mappings: std.ArrayList(*const caps.Mapping),

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
            .mappings = .init(caps.slab_allocator.allocator()),
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

        std.debug.assert(self.mappings.items.len == 0);
        self.mappings.deinit();

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

        try self.boundsCheck(offset_bytes, bytes.len);

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

        try self.boundsCheck(offset_bytes, bytes.len);

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

    fn boundsCheck(self: *@This(), offset_bytes: usize, len: usize) Error!void {
        const limit = std.math.divCeil(usize, offset_bytes + len, 0x1000) catch
            return Error.OutOfBounds;

        self.lock.lock();
        defer self.lock.unlock();

        if (limit > self.pages.len)
            return Error.OutOfBounds;
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

            const page = try self.frame.pageFault(
                self.idx,
                self.is_write,
                null,
            );

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

    /// returning Error.Retry means switching away from the thread from a page fault handler
    /// or using userspace logic to initialize the used page and retrying
    pub fn pageFault(
        self: *@This(),
        idx: u32,
        is_write: bool,
        dont_lock_if: ?*caps.Vmem,
    ) Error!u32 {
        //     1.  lock `Frame`
        //     2.  copy all mappings that reference the old page to a temporary list
        //     3.  set `is_transient` flag
        //     4.  unlock `Frame`
        //
        // (par).  between steps 4. and 12. another thread might page fault now and
        //         lock its own Vmem, and then lock this Frame but it sees the `is_transient`
        //         being set and adds itself to the `transient_sleep_queue` and switches contexts
        //
        //     5.  (maybe) sort all mappings in the temporary list by `Vmem` object address for locking order
        //     6.  for each vmem in the temporary list
        //     8.    lock the vmem
        //     9.    if mapping is no longer valid: skip
        //    10.    unmap the old page from page tables
        //    11.    save the CPUs that used this vmem in a bitmap
        //    12.    unlock the vmem
        //
        //    13.  send TLB shootdown IPIs to processors according to the bitmap
        //    14.  wait for all IPIs to execute
        //
        //    15.  for each vmem in the temporary list
        //    16.    lock the vmem
        //    17.    if mapping is no longer valid: skip
        //    18.    map the new page into page tables
        //    19.    unlock the vmem
        //
        //    20.  lock `Frame`
        //    21.  just a sanity check: debug assert `is_transient` is still set
        //    22.  unset `is_transient`
        //    23.  wake up all threads in the `transient_sleep_queue`
        //    24.  unlock `Frame`
        //

        const result = try self.updatePage(idx, is_write);

        switch (result) {
            .reused => |page| {
                @branchHint(.likely);
                return page;
            },
            .is_transient => {
                // log.debug("retry cause: is_transient", .{});
                return Error.Retry;
            },
            .remap => |info| {
                defer {
                    for (info.updates) |vmem| vmem.deinit();
                    caps.slab_allocator.allocator().free(info.updates);
                }

                std.sort.pdq(*caps.Vmem, info.updates, {}, struct {
                    fn lessThanFn(_: void, lhs: *caps.Vmem, rhs: *caps.Vmem) bool {
                        return @intFromPtr(lhs) < @intFromPtr(rhs);
                    }
                }.lessThanFn);

                var ipi_bitmap: u256 = 0;

                // this CPU owns a single manual tlb_shootdown_refcnt reference
                self.tlb_shootdown_refcnt.inc();

                var prev: ?*caps.Vmem = null;
                for (info.updates) |vmem_with_old_mappings| {
                    // filter out duplicates
                    if (prev == vmem_with_old_mappings) continue;
                    prev = vmem_with_old_mappings;

                    try vmem_with_old_mappings.refresh(
                        self,
                        idx,
                        &ipi_bitmap,
                        dont_lock_if,
                    );
                }

                ipi_bitmap &= ~(@as(u256, 1) << @as(u8, @intCast(arch.cpuLocal().lapic_id)));
                // const ipi_count = @popCount(ipi_bitmap);

                if (self.deinitTlbShootdown()) {
                    @branchHint(.likely);
                    return info.new_page;
                }
                // log.debug("tlb_shootdown_refcnt={}", .{self.tlb_shootdown_refcnt.load()});

                for (main.all_cpu_locals, 0..) |*locals, i| {
                    if (locals == arch.cpuLocal()) continue; // no need to send a self IPI

                    if (ipi_bitmap & (@as(u256, 1) << @as(u8, @intCast(i))) != 0) {
                        log.err("issuing a TCB shootdown from transient page", .{});
                        apic.interProcessorInterrupt(
                            locals.lapic_id,
                            apic.IRQ_IPI_TLB_SHOOTDOWN,
                        );
                    }
                }

                // log.debug("retry cause: IPI ACK wait", .{});
                return Error.Retry;
            },
        }

        // TODO: better page table HAL where remap and unmap ops do the TLB shootdown
    }

    /// returns true if the whole TLB shootdown process was complete
    pub fn deinitTlbShootdown(self: *@This()) bool {
        if (!self.tlb_shootdown_refcnt.dec()) return false;

        // all tlb shootdown objects executed,
        // make the frame as ready to use again

        self.lock.lock();
        defer self.lock.unlock();

        self.is_transient = false;
        while (self.transient_sleep_queue.popFront()) |sleeper| {
            proc.ready(sleeper);
        }

        return true;
    }

    const UpdatePageResult = union(enum) {
        /// the page was already set as it should have been and is safe to use immediately
        reused: u32,
        /// the page might be moving right now, so this thread has to go sleep
        is_transient: void,
        /// the old page needs to be copied (copy-on-write and lazy-alloc) and all active
        /// mappings need to be updated
        remap: struct {
            new_page: u32,
            old_page: u32,
            updates: []*caps.Vmem,
        },
    };

    fn updatePage(self: *@This(), idx: u32, is_write: bool) !UpdatePageResult {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.is_transient) return .{ .is_transient = {} };

        std.debug.assert(idx < self.pages.len);
        const page = &self.pages[idx];

        const readonly_zero_page_now = caps.readonly_zero_page.load(.monotonic);
        std.debug.assert(readonly_zero_page_now != 0);

        // TODO:
        if ((page.* == readonly_zero_page_now or page.* == 0) and is_write) {
            // writing to a lazy allocated zeroed page
            // => allocate a new exclusive page and set it be the mapping

            // save all old mappings that need to be updated
            // TODO: use a per-CPU arena allocator

            const alloc = pmem.allocChunk(.@"4KiB") orelse return error.OutOfMemory;
            errdefer pmem.deallocChunk(alloc, .@"4KiB");
            const old = try caps.slab_allocator.allocator().alloc(*caps.Vmem, self.mappings.items.len);

            const new_page = alloc.toParts().page;
            const old_page = page.*;

            page.* = new_page;
            self.is_transient = true;

            for (self.mappings.items, old) |a, *b| {
                b.* = a.vmem.clone();
            }

            return .{ .remap = .{
                .new_page = new_page,
                .old_page = old_page,
                .updates = old,
            } };
        } else if (!is_write and page.* == 0) {
            // not mapped and isnt write
            // => use the shared readonly zero page

            page.* = readonly_zero_page_now;
            return .{ .reused = readonly_zero_page_now };
        } else {

            // already mapped AND write to a page that isnt readonly_zero_page or read from any page
            // => use the existing page
            return .{ .reused = page.* };
        }
    }
};

/// kernel internal object
pub const TlbShootdown = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    completion: Completion,
    target: Target,

    next: ?*@This() = null,
    prev: ?*@This() = null,

    pub const Completion = union(enum) {
        transient: *caps.Frame,
        unmap: *caps.Thread,
    };

    // TODO: PCID
    pub const Target = union(enum) {
        individual: addr.Virt,
        range: [2]addr.Virt,
        whole: void,
    };

    pub fn init(
        completion: Completion,
        target: Target,
    ) !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("TlbShootdown.init completion={} target={}", .{ completion, target });

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{ .completion = completion, .target = target };

        switch (obj.completion) {
            .transient => |frame| frame.tlb_shootdown_refcnt.inc(),
            .unmap => |_| {},
        }

        return obj;
    }

    pub fn deinit(self: *@This()) ?*caps.Thread {
        // log.debug("TLB (partial) flush", .{});
        switch (self.target) {
            .individual => |vaddr| arch.flushTlbAddr(vaddr.raw),
            .range => |vaddr_range| {
                for (vaddr_range[0].raw..vaddr_range[1].raw) |vaddr|
                    arch.flushTlbAddr(vaddr);
            },
            .whole => arch.flushTlb(),
        }

        if (!self.refcnt.dec()) return null;

        defer caps.slab_allocator.allocator().destroy(self);

        if (conf.LOG_OBJ_CALLS)
            log.info("TlbShootdown.deinit", .{});

        switch (self.completion) {
            .transient => |frame| {
                defer frame.deinit();

                frame.lock.lock();
                defer frame.lock.unlock();

                _ = frame.deinitTlbShootdown();

                return null;
            },
            .unmap => |thread| {
                return thread;
            },
        }
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("TlbShootdown.clone", .{});

        self.refcnt.inc();
        return self;
    }
};
