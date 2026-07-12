const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const apic = @import("../apic.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const lock = @import("../lock.zig");
const main = @import("../main.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const PageState = enum {
    /// initial state
    ///  - read simply changes the state to `readonly_zero`
    ///    and returns the readonly zero page
    ///  - write simply changes the state to `init`
    ///    and returns the allocated page
    uninit,
    /// state when first read from but not written to
    ///  - read simply returns the readonly zero page
    ///  - write requires a complex remap, switches to the
    ///    `init` state and returns the allocated page once
    ///    the remap is complete
    readonly_zero,
    /// fully initialized state
    ///  - both read and write simply returns the allocated page
    init,
};

pub const Frame = struct {
    base: caps.Object = .{ .type = .frame },

    // flag that tells if this frame is being modified while the lock is not held
    // TODO: a small hashmap style functionality, where each bit locks 1/8 of all pages
    is_transient: bool = false,
    transient_sleep_queue: caps.Thread.Queue = .{},
    tlb_shootdown_refcnt: abi.epoch.RefCnt = .{ .refcnt = .init(0) },

    is_physical: bool,
    lock: lock.TrackingSpinMutex = .{},
    chunks: []u32,
    chunk_size: abi.ChunkSize,
    size_bytes: usize,
    mappings: std.ArrayList(*const caps.Mapping),

    pub const UserHandle = abi.caps.Frame;

    pub fn init(
        size_bytes: usize,
        flags: abi.sys.FrameCreateFlags,
    ) !*@This() {
        const alloc = caps.slab_allocator.allocator();

        if (size_bytes == 0)
            return Error.InvalidArgument;

        const chunk_size = flags.page_size_hint.hardwarePageSize();

        const size_chunks = std.math.divCeil(
            usize,
            size_bytes,
            chunk_size.sizeBytes(),
        ) catch unreachable;
        if (size_chunks > std.math.maxInt(u32)) return error.OutOfMemory;

        const obj: *@This() = try alloc.create(@This());
        errdefer alloc.destroy(obj);
        const chunks = try alloc.alloc(u32, size_chunks);
        @memset(chunks, 0);

        obj.* = .{
            .is_physical = false,
            .chunks = chunks,
            .chunk_size = chunk_size,
            .size_bytes = size_bytes,
            .mappings = .{},
        };

        caps.incCount(.frame, .{
            .size_bytes = size_bytes,
            .chunk_size = chunk_size,
        });
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

        if (size_bytes == 0)
            return Error.InvalidArgument;

        const aligned_paddr: usize = std.mem.alignBackward(usize, paddr.raw, 0x1000);
        const aligned_size: usize = std.mem.alignForward(usize, size_bytes, 0x1000);

        if (aligned_paddr == 0)
            return Error.InvalidAddress;

        var chunk_size: abi.ChunkSize = .@"4KiB";
        for ([_]abi.ChunkSize{ .@"2MiB", .@"1GiB" }) |next| {
            const next_size = next.sizeBytes();
            if (!std.mem.isAligned(aligned_paddr, next_size)) break;
            if (!std.mem.isAligned(aligned_size, next_size)) break;
            chunk_size = next;
        }

        const frame = try Frame.init(
            aligned_size,
            .{ .page_size_hint = chunk_size },
        );
        const first_page: u32 = @intCast(@divExact(aligned_paddr, 0x1000));
        for (frame.chunks, 0..) |*page, i| {
            page.* = first_page + @as(u32, @intCast(i)) * chunk_size.sizePages();
        }

        // just a memory barrier, is_physical is not supposed to be atomic
        @atomicStore(bool, &frame.is_physical, true, .release);
        return frame;
    }

    pub fn deinitFull(self: *@This()) void {
        caps.decCount(.frame);

        std.debug.assert(self.lock.tryLock());
        self.lock.giveOwnership();

        if (!self.is_physical) {
            for (self.chunks) |page| {
                if (page == 0) continue;

                pmem.deallocChunk(
                    .{ .parts = .{ .page = page } },
                    self.chunk_size,
                );
            }
        }

        std.debug.assert(self.mappings.items.len == 0);
        self.mappings.deinit(caps.slab_allocator.allocator());

        caps.slab_allocator.allocator().free(self.chunks);
        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn deinit(self: *@This()) void {
        if (!self.base.refcnt.dec()) return;
        self.deinitFull();
    }

    pub fn forceInitialize(
        self: *@This(),
        offset_byte: usize,
        length: usize,
    ) !void {
        if (length == 0) return;

        self.lock.lock();
        defer self.lock.unlock();

        std.debug.assert(self.mappings.items.len == 0);
        std.debug.assert(!self.is_transient);

        const idx_beg: usize = std.math.divFloor(
            usize,
            offset_byte,
            self.chunk_size.sizeBytes(),
        ) catch unreachable;
        const idx_end: usize = std.math.divCeil(
            usize,
            offset_byte + length - 1,
            self.chunk_size.sizeBytes(),
        ) catch unreachable;

        for (self.chunks[idx_beg..idx_end]) |*page| {
            if (page.* != 0) continue; // FIXME: handle readonly zero pages

            const new_page = pmem.allocChunk(self.chunk_size) orelse
                return Error.OutOfMemory;
            page.* = new_page.parts.page;
        }
    }

    pub fn initialWrite(
        self: *@This(),
        offset_byte: usize,
        _bytes: []const u8,
    ) !void {
        var bytes = _bytes;
        if (bytes.len == 0) return;

        try self.forceInitialize(offset_byte, bytes.len);

        var it = self.data(offset_byte, true);
        defer it.deinit();

        while (try it.next()) |chunk| {
            const limit = @min(bytes.len, chunk.len);
            @memcpy(chunk[0..limit], bytes[0..limit]);
            bytes = bytes[limit..];

            if (bytes.len == 0) return;
        }
    }

    // TODO: std.Io.Writer/std.Io.Reader API works here now
    pub fn DataIterator(comptime is_write: bool) type {
        return struct {
            frame: *Frame,
            offset_within_first: ?u32,
            idx: u32,

            const Slice = if (is_write) []volatile u8 else []const volatile u8;

            pub fn next(self: *@This()) !?Slice {
                if (self.idx >= self.frame.chunks.len)
                    return null;

                defer self.idx += 1;
                defer self.offset_within_first = null;

                const page = try self.frame.pageFaultDryrunLocked(
                    self.idx,
                    is_write,
                );

                // log.info("Frame.DataIterator.next frame={*} idx={} page=0x{x} offs=0x{x} {s}", .{
                //     self.frame,
                //     self.idx,
                //     page,
                //     self.offset_within_first orelse 0,
                //     if (page == caps.readonly_zero_page.load(.monotonic)) "rozp" else "",
                // });

                const from = self.offset_within_first orelse 0;
                const to = self.frame.chunk_size.sizeBytes();
                const ptr: [*]volatile u8 = @ptrFromInt(addr.physPageToVirt(page));
                return ptr[from..to];
            }

            pub fn deinit(self: *@This()) void {
                self.frame.lock.unlock();
            }
        };
    }

    pub fn data(self: *@This(), offset_bytes: usize, comptime is_write: bool) DataIterator(is_write) {
        self.lock.lock();

        if (offset_bytes >= self.chunks.len * self.chunk_size.sizeBytes()) {
            return .{
                .frame = self,
                .offset_within_first = null,
                .idx = @intCast(self.chunks.len),
            };
        }

        const first_byte = std.mem.alignBackward(usize, offset_bytes, self.chunk_size.sizeBytes());
        const offset_within_page: ?u32 = if (first_byte == offset_bytes)
            null
        else
            @intCast(offset_bytes - first_byte);

        return .{
            .frame = self,
            .offset_within_first = offset_within_page,
            .idx = @intCast(first_byte / self.chunk_size.sizeBytes()),
        };
    }

    pub fn pageFaultDryrunLocked(
        self: *@This(),
        idx: u32,
        is_write: bool,
    ) error{Retry}!u32 {
        if (self.is_transient) return Error.Retry;

        const page = self.chunks[idx];

        std.debug.assert(caps.readonly_zero_page.parts.page != 0);

        const is_uninit = page == 0;
        const is_not_init = page == caps.readonly_zero_page.parts.page or is_uninit;

        // trying to write, but it is not allocated yet
        // (either not initialized or intitialized to read-only)
        if (is_not_init and is_write) return Error.Retry;

        // trying to read or exec while it is not allocated yet
        if (is_not_init) return caps.readonly_zero_page.parts.page;

        // it is allocated
        return page;
    }

    pub const PageFaultResult = struct {
        page: addr.Phys,
        page_state: PageState,
    };

    // pub const Operation = enum {
    //     commit,
    //     decommit,
    // };

    // pub fn opRange(
    //     self: *@This(),
    //     from: u32,
    //     to: u32,
    //     trap: *arch.TrapRegs,
    //     thread: *caps.Thread,
    // ) void {
    //     self.lock.lock();
    //     defer self.lock.unlock();

    //     if (self.is_transient) {
    //         @branchHint(.cold);
    //         const cleanup = self.transientQueueSleep(trap, thread);
    //         return .{ .is_transient = .{
    //             .cleanup = cleanup,
    //         } };
    //     }
    //     self.is_transient = true;

    //     self.mappings.items;

    //     self.chunks;

    //     self.is_transient;
    // }

    /// returning Error.Retry means switching away from the thread from a page fault handler
    /// or using userspace logic to initialize the used page and retrying
    pub fn pageFault(
        self: *@This(),
        idx: u32,
        is_write: bool,
        dont_lock_if: ?*caps.Vmem,
        trap: *arch.TrapRegs,
        thread: *caps.Thread,
    ) Error!PageFaultResult {
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

        const result = try self.updatePage(
            idx,
            is_write,
            trap,
            thread,
        );

        switch (result) {
            .reused => |v| return v,
            .is_transient => |info| {
                info.cleanup.run();
                return Error.Retry;
            },
            .remap => |info| {
                info.cleanup.run();

                // the `caps.TlbShootdown` holds a ref to this `caps.Frame`, keeping it alive
                // the `caps.Frame` holds a ref to this thread in the transient sleep queue,
                // keeping it alive too, so the tlb shootdown itself cannot become a
                // dangling pointer
                self.base.clone();
                thread.tlb_shootdown = .initRemap(info.updates, self, idx);
                const shootdown = &thread.tlb_shootdown;

                const ipi_bitmap: u256 = ~@as(u256, 0);
                var prev: ?*caps.Vmem = null;
                for (info.updates) |vmem_with_old_mappings| {
                    // filter out duplicates
                    if (prev == vmem_with_old_mappings) continue;
                    prev = vmem_with_old_mappings;

                    try vmem_with_old_mappings.refresh(
                        self,
                        idx,
                        dont_lock_if,
                    );
                }

                const cant_be_non_null = shootdown.deinit(dont_lock_if);
                std.debug.assert(cant_be_non_null == null);

                const id_self = arch.cpuId();
                for (main.all_cpu_locals, 0..) |*_locals, i| {
                    if (i == id_self) continue; // no need to send a self IPI
                    const locals = _locals.load(.acquire) orelse continue;
                    if (ipi_bitmap & (@as(u256, 1) << @as(u8, @intCast(i))) == 0) continue;

                    shootdown.refcnt.inc();
                    locals.tlb_shootdown_queue.push(shootdown);
                    apic.interProcessorInterrupt(
                        locals.lapic_id,
                        apic.irqs.ipi_tlb_shootdown,
                    );
                }

                // log.debug("retry cause: IPI ACK wait", .{});
                return Error.Retry;
            },
        }

        // TODO: better page table HAL where remap and unmap ops do the TLB shootdown
    }

    const UpdatePageResult = union(enum) {
        /// the page was already set as it should have been and is safe to use immediately
        reused: PageFaultResult,
        /// the page might be moving right now, so this thread has to go sleep
        is_transient: struct {
            cleanup: caps.Thread.Queue.Cleanup,
        },
        /// the old page needs to be copied (copy-on-write and lazy-alloc) and all active
        /// mappings need to be updated
        remap: struct {
            updates: []*caps.Vmem,
            cleanup: caps.Thread.Queue.Cleanup,
        },
    };

    fn updatePage(
        self: *@This(),
        idx: u32,
        is_write: bool,
        trap: *arch.TrapRegs,
        thread: *caps.Thread,
    ) !UpdatePageResult {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.is_transient) {
            @branchHint(.cold);
            const cleanup = self.transientQueueSleep(trap, thread);
            return .{ .is_transient = .{
                .cleanup = cleanup,
            } };
        }

        const page = &self.chunks[idx];

        const readonly_page: addr.Phys = caps.readonly_zero_page;
        const current_page: addr.Phys = .{ .parts = .{
            .page = page.*,
        } };

        const page_state = if (current_page.isNull())
            PageState.uninit
        else if (current_page.raw == readonly_page.raw)
            PageState.readonly_zero
        else
            PageState.init;

        if (conf.NO_LAZY_REMAP) {
            if (page_state == .uninit) {
                const alloc = pmem.allocChunk(self.chunk_size) orelse
                    return error.OutOfMemory;
                page.* = alloc.parts.page;
            }

            return .{ .reused = .{
                .page = .{ .parts = .{ .page = page.* } },
                .page_state = .init,
            } };
        }

        switch (page_state) {
            .init => {
                // already usable
                return .{ .reused = .{
                    .page = current_page,
                    .page_state = .init,
                } };
            },
            .uninit => if (!is_write) {
                // easily usable - read zeroes
                page.* = readonly_page.parts.page;
                return .{ .reused = .{
                    .page = readonly_page,
                    .page_state = .readonly_zero,
                } };
            } else {
                // easily usable - write
                const alloc = pmem.allocChunk(self.chunk_size) orelse
                    return error.OutOfMemory;
                page.* = alloc.parts.page;
                return .{ .reused = .{
                    .page = alloc,
                    .page_state = .init,
                } };
            },
            .readonly_zero => if (!is_write) {
                // already usable - read only
                return .{ .reused = .{
                    .page = current_page,
                    .page_state = .readonly_zero,
                } };
            } else {
                // worst case - remap as write
                @branchHint(.cold);
                std.debug.assert(is_write);

                const alloc = pmem.allocChunk(self.chunk_size) orelse
                    return error.OutOfMemory;
                errdefer pmem.deallocChunk(alloc, self.chunk_size);
                const old = try self.collectOldMappingsLocked(idx);

                page.* = alloc.parts.page;
                self.is_transient = true;
                const cleanup = self.transientQueueSleep(trap, thread);

                return .{ .remap = .{
                    .updates = old,
                    .cleanup = cleanup,
                } };
            },
        }

        comptime unreachable;
    }

    fn collectOldMappingsLocked(
        self: *@This(),
        idx: u32,
    ) ![]*caps.Vmem {
        var count: usize = 0;
        for (self.mappings.items) |mapping| {
            if (idx < mapping.frame_first_chunk) continue;
            if (idx >= mapping.frame_first_chunk + mapping.chunks) continue;
            std.debug.assert(mapping.frame == self);

            count += 1;
        }

        const old = try caps.slab_allocator.allocator().alloc(*caps.Vmem, count);
        var i: usize = 0;
        for (self.mappings.items) |mapping| {
            if (idx < mapping.frame_first_chunk) continue;
            if (idx >= mapping.frame_first_chunk + mapping.chunks) continue;
            std.debug.assert(mapping.frame == self);

            mapping.vmem.base.clone();
            old[i] = mapping.vmem;
            i += 1;
        }

        std.sort.pdq(*caps.Vmem, old, {}, struct {
            fn lessThanFn(_: void, lhs: *caps.Vmem, rhs: *caps.Vmem) bool {
                return @intFromPtr(lhs) < @intFromPtr(rhs);
            }
        }.lessThanFn);

        return old;
    }

    fn transientQueueSleep(
        self: *@This(),
        trap: *arch.TrapRegs,
        thread: *caps.Thread,
    ) caps.Thread.Queue.Cleanup {
        // save the current thread that might or might not go to sleep
        proc.switchFrom(trap, thread);

        // FIXME: self.lock is held longer than necessary

        if (conf.IS_DEBUG and thread.dbg_filter) {
            log.debug("wait cause: transientQueueSleep", .{});
        }

        return self.transient_sleep_queue.pushThreadLocked(
            &self.lock,
            thread,
            0,
            .waiting,
        );
    }
};

/// kernel internal object
pub const TlbShootdown = struct {
    refcnt: abi.epoch.RefCnt = .{},

    // tlb_ranges: [32]TlbRange = undefined,
    // tlb_ranges_len: u8 = 0,

    // page_table_limbo: ,

    operation: union(enum) {
        unmap: struct {
            /// a ref of `caps.Vmem` is held and this mapping is marked as unmapping
            /// to prevent it from being deallocated and this becoming a dangling pointer
            mapping: *caps.Mapping,
            /// a thread that called `unmap` and is waiting for the op to complete
            thread: *caps.Thread,
        },
        remap: struct {
            /// refs of `caps.Vmem`s are owned
            mappings: []*caps.Vmem,
            /// `caps.Frame` ref is owned, a page fault caused this frame to get
            /// modified and it is currently in a transient state and will be unlocked
            frame: *caps.Frame,
            idx: u32,
        },
    },

    pub const TlbRange = struct {
        start: addr.Virt,
        count: u32,
        chunk_size: abi.ChunkSize,
    };

    pub const Completion = union(enum) {
        /// a page fault caused the frame to get modified, unlock the frame
        transient: *caps.Frame,
        /// a thread called `unmap` and is waiting for the op to complete
        unmap: *caps.Thread,
    };

    // TODO: PCID
    pub const Target = union(enum) {
        whole,
        range: *caps.Mapping,
    };

    pub fn initUnmap(
        mapping: *caps.Mapping,
        thread: *caps.Thread,
    ) @This() {
        if (conf.LOG_TLB_SHOOTDOWNS) {
            log.debug("tlb shootdown from unmap 0x{x} count={} size={t}", .{
                mapping.start().raw, mapping.chunks, mapping.frame.chunk_size,
            });
        }
        caps.incCount(.tlb_shootdown, .{
            .mapping = mapping,
            .thread = thread,
        });
        return .{ .operation = .{ .unmap = .{
            .mapping = mapping,
            .thread = thread,
        } } };
    }

    pub fn initRemap(
        mappings: []*caps.Vmem,
        frame: *caps.Frame,
        idx: u32,
    ) @This() {
        if (conf.LOG_TLB_SHOOTDOWNS) {
            log.debug("tlb shootdown from remap {*} idx={}", .{
                frame, idx,
            });
        }
        caps.incCount(.tlb_shootdown, .{
            .mappings = mappings,
            .frame = frame,
            .idx = idx,
        });
        return .{ .operation = .{ .remap = .{
            .mappings = mappings,
            .frame = frame,
            .idx = idx,
        } } };
    }

    fn remapFlush(
        self: *const @This(),
        dont_lock_if: ?*caps.Vmem,
    ) void {
        std.debug.assert(self.operation == .remap);
        const remap = self.operation.remap;

        const chunk_size = remap.frame.chunk_size;
        var prev: ?*caps.Vmem = null;
        for (remap.mappings) |vmem| {
            // filter out duplicates
            if (prev == vmem) continue;
            prev = vmem;

            if (dont_lock_if != vmem) vmem.lock.lock();
            defer if (dont_lock_if != vmem) vmem.lock.unlock();

            for (vmem.mappings.items) |mapping| {
                if (mapping.frame != remap.frame) continue;

                std.debug.assert(remap.idx >= mapping.frame_first_chunk);
                std.debug.assert(remap.idx < mapping.frame_first_chunk + mapping.chunks);

                vmem.hal_vmem.flushLocalTlb(
                    chunk_size,
                    mapping.getVaddr(),
                );
            }
        }
    }

    fn remapFinish(
        self: *const @This(),
        dont_lock_if: ?*caps.Vmem,
    ) ?*caps.Thread {
        std.debug.assert(self.operation == .remap);
        const remap = self.operation.remap;

        const chunk_size = remap.frame.chunk_size;
        var prev: ?*caps.Vmem = null;
        for (remap.mappings) |vmem| {
            // filter out duplicates
            if (prev == vmem) continue;
            prev = vmem;

            if (dont_lock_if != vmem) vmem.lock.lock();
            defer if (dont_lock_if != vmem) vmem.lock.unlock();

            for (vmem.mappings.items) |mapping| {
                if (mapping.frame != remap.frame) continue;

                std.debug.assert(remap.idx >= mapping.frame_first_chunk);
                std.debug.assert(remap.idx < mapping.frame_first_chunk + mapping.chunks);

                vmem.hal_vmem.remove(
                    chunk_size,
                    mapping.getVaddr(),
                );
            }
        }

        defer {
            for (remap.mappings) |vmem| vmem.deinit();
            remap.frame.deinit();
            caps.slab_allocator.allocator().free(remap.mappings);
        }

        remap.frame.lock.lock();
        defer remap.frame.lock.unlock();
        remap.frame.is_transient = false;

        while (remap.frame.transient_sleep_queue.popFirstLocked(
            &remap.frame.lock,
            .running,
        )) |sleeper| {
            proc.ready(sleeper);
        }

        return null;
    }

    fn unmapFlush(
        self: *const @This(),
        dont_lock_if: ?*caps.Vmem,
    ) void {
        std.debug.assert(self.operation == .unmap);
        const unmap = self.operation.unmap;

        const vaddr_mapping = unmap.mapping.start();
        const chunk_size = unmap.mapping.frame.chunk_size;
        const chunk_bytes = chunk_size.sizeBytes();
        const vmem = unmap.mapping.vmem;

        // NOTE: locking is not needed because it is illegal to remove
        // or modify the mappings before the last tlb flush has ran (?)

        _ = dont_lock_if;
        // vmem.lock.lock();
        // defer vmem.lock.unlock();

        for (0..unmap.mapping.chunks) |chunk_idx| {
            // already checked to be in bounds
            const vaddr_chunk = vaddr_mapping.add(chunk_idx * chunk_bytes);
            vmem.hal_vmem.flushLocalTlb(chunk_size, vaddr_chunk);
        }
    }

    fn unmapFinish(
        self: *const @This(),
        dont_lock_if: ?*caps.Vmem,
    ) *caps.Thread {
        std.debug.assert(self.operation == .unmap);
        const unmap = self.operation.unmap;

        const vmem = unmap.mapping.vmem;
        const vaddr_mapping = unmap.mapping.start();
        const chunk_size = unmap.mapping.frame.chunk_size;
        const chunk_bytes = chunk_size.sizeBytes();

        defer vmem.deinit();
        if (dont_lock_if != vmem) vmem.lock.lock();
        defer if (dont_lock_if != vmem) vmem.lock.unlock();

        for (0..unmap.mapping.chunks) |chunk_idx| {
            // already checked to be in bounds
            const vaddr_chunk = vaddr_mapping.add(chunk_idx * chunk_bytes);
            vmem.hal_vmem.remove(chunk_size, vaddr_chunk);
        }

        const idx = unmap.mapping.vmem.find(unmap.mapping.start()).?;
        const removed_mapping = vmem.mappings.orderedRemove(idx);
        std.debug.assert(removed_mapping == unmap.mapping);
        std.debug.assert(removed_mapping.target.unmapping);

        return unmap.thread;
    }

    pub fn deinit(
        self: *@This(),
        dont_lock_if: ?*caps.Vmem,
    ) ?*caps.Thread {
        // log.debug("TLB (partial) flush", .{});
        switch (self.operation) {
            .remap => self.remapFlush(dont_lock_if),
            .unmap => self.unmapFlush(dont_lock_if),
        }

        if (!self.refcnt.dec()) return null;
        caps.decCount(.tlb_shootdown);
        defer self.* = undefined;

        return switch (self.operation) {
            .remap => self.remapFinish(dont_lock_if),
            .unmap => self.unmapFinish(dont_lock_if),
        };
    }

    pub fn flushAll() void {
        const locals = arch.cpuLocal();
        while (locals.tlb_shootdown_queue.tryPop()) |shootdown| {
            // log.debug("one TLB shootdown complete for {*}", .{shootdown});
            if (shootdown.deinit(null)) |thread| {
                // log.debug("TLB shootdowns complete for {*}", .{thread});
                proc.ready(thread);
            }
        }
    }
};
