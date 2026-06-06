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

pub const Vmem = struct {
    base: caps.Object = .{ .type = .vmem },

    lock: lock.TrackingSpinMutex = .{},
    hal_vmem: caps.HalVmem,
    mappings: std.ArrayList(*caps.Mapping) = .{},
    // bitset of all cpus that have used this vmem
    // cpus: u256 = 0,

    pub const UserHandle = abi.caps.Vmem;

    pub fn init() Error!*@This() {
        const hal_vmem: caps.HalVmem = try .init();
        errdefer hal_vmem.deinit();

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{ .hal_vmem = hal_vmem };

        caps.incCount(.vmem, .{});
        return obj;
    }

    pub fn deinitFull(self: *@This()) void {
        caps.decCount(.vmem);

        std.debug.assert(self.lock.tryLock());
        self.lock.giveOwnership();

        const alloc = caps.slab_allocator.allocator();
        for (self.mappings.items) |mapping| mapping.deinit();
        self.mappings.deinit(alloc);
        self.hal_vmem.deinit();

        alloc.destroy(self);
    }

    pub fn deinit(self: *@This()) void {
        if (!self.base.refcnt.dec()) return;
        self.deinitFull();
    }

    pub fn DataIterator(comptime is_write: bool) type {
        return struct {
            vmem: *caps.Vmem,
            vaddr: addr.Virt,
            cur_frame: ?caps.Frame.DataIterator(is_write) = null,

            const Slice = if (is_write) []volatile u8 else []const volatile u8;
            const DataError = error{ InvalidAddress, Retry };

            pub fn next(self: *@This()) DataError!?Slice {
                if (self.cur_frame) |*cur_frame| {
                    if (try cur_frame.next()) |chunk| {
                        // log.debug("vmem_{s} chunk.ptr={*} chunk.len={} @0x{x}", .{
                        //     if (is_write) "write" else "read",
                        //     chunk.ptr,
                        //     chunk.len,
                        //     self.vaddr.raw,
                        // });
                        self.vaddr.raw += chunk.len;
                        return chunk;
                    } else {
                        cur_frame.deinit();
                        self.cur_frame = null;
                    }
                }

                try self.fetchFrame() orelse return null;
                return self.next();
            }

            fn fetchFrame(self: *@This()) DataError!?void {
                self.vmem.lock.lock();
                defer self.vmem.lock.unlock();

                const idx = self.vmem.find(self.vaddr) orelse return null;
                const mapping = self.vmem.mappings.items[idx];

                // log.debug("Vmem.DataIterator.next mapping=0x{x}..0x{x} first={}", .{
                //     mapping.getVaddr().raw,
                //     mapping.getVaddr().raw + mapping.pages * 0x1000,
                //     mapping.frame_first_page,
                // });

                // FIXME: why wouldnt the return be null
                if (!mapping.overlaps(self.vaddr, 1)) return Error.InvalidAddress;

                self.cur_frame = mapping.frame.data(
                    self.vaddr.raw - mapping.start().raw +
                        mapping.frame_first_chunk * mapping.frame.chunk_size.sizeBytes(),
                    is_write,
                );
            }

            pub fn deinit(self: *@This()) void {
                if (self.cur_frame) |*f| f.deinit();
            }
        };
    }

    pub fn data(self: *@This(), vaddr: addr.Virt, comptime is_write: bool) DataIterator(is_write) {
        return .{
            .vmem = self,
            .vaddr = vaddr,
        };
    }

    pub fn switchTo(self: *@This()) void {
        // self.cpus |= 1 << arch.cpuId();

        const current_vmem_ptr = &arch.cpuLocal().current_vmem;
        if (current_vmem_ptr.* == self) {
            return;
        }

        // keep the previous vmem alive until after the switch, and then delete the reference
        // also clone the new vmem into local storage to keep it always alive
        const previous_vmem = current_vmem_ptr.*;
        current_vmem_ptr.* = self;
        self.base.clone();
        defer if (previous_vmem) |prev| prev.deinit();

        self.hal_vmem.switchTo();
    }

    pub fn map(
        self: *@This(),
        frame: *caps.Frame,
        frame_offset: usize,
        vaddr_unaligned: addr.Virt,
        length: usize,
        flags: abi.sys.MapFlags,
    ) Error!addr.Virt {
        std.debug.assert(self.check());
        defer std.debug.assert(self.check());

        // locking order: Vmem -> Frame
        self.lock.lock();
        defer self.lock.unlock();
        frame.lock.lock();
        defer frame.lock.unlock();

        const chunk_bytes = frame.chunk_size.sizeBytes();
        const frame_first_chunk_usize = frame_offset / chunk_bytes;
        if (frame_first_chunk_usize >= frame.chunks.len) {
            return Error.OutOfBounds;
        }
        const frame_first_chunk: u32 = @intCast(frame_first_chunk_usize);

        const chunks = if (length == 0)
            @as(u32, @intCast(frame.chunks.len)) - frame_first_chunk
        else
            std.math.cast(u32, ((length - 1) / chunk_bytes) + 1) orelse {
                return Error.OutOfBounds;
            };

        if (@as(usize, chunks) + frame_first_chunk > frame.chunks.len) {
            return Error.OutOfBounds;
        }

        const vaddr_aligned = vaddr_unaligned.alignBackward(chunk_bytes);

        const mapped_vaddr: addr.Virt = if (flags.fixed) b: {
            break :b try self.mapFixed(
                frame,
                frame_first_chunk,
                vaddr_aligned,
                chunks,
                flags,
            );
        } else b: {
            break :b try self.mapHint(
                frame,
                frame_first_chunk,
                vaddr_aligned,
                chunks,
                flags,
            );
        };

        return mapped_vaddr;
    }

    pub fn mapFixed(
        self: *@This(),
        frame: *caps.Frame,
        frame_first_chunk: u32,
        fixed_vaddr: addr.Virt,
        chunks: u32,
        flags: abi.sys.MapFlags,
    ) Error!addr.Virt {
        const chunk_bytes = frame.chunk_size.sizeBytes();
        const gpa = caps.slab_allocator.allocator();

        if (conf.LOG_OBJ_CALLS) {
            log.info(
                \\Vmem.map
                \\ - frame={*}
                \\ - frame_first_chunk={}
                \\ - vaddr=0x{x}
                \\ - chunks={}
                \\ - flags={}"
            , .{
                frame,
                frame_first_chunk,
                fixed_vaddr.raw,
                chunks,
                flags,
            });
        }

        errdefer if (conf.LOG_OBJ_CALLS) {
            log.info("Vmem.map successful", .{});
        };

        if (fixed_vaddr.raw == 0) {
            return Error.InvalidAddress;
        }
        if (fixed_vaddr.raw +| @as(usize, chunk_bytes) * chunks > 0x8000_0000_0000) {
            return Error.InvalidAddress;
        }

        const mapping = try caps.Mapping.init(
            frame,
            self,
            frame_first_chunk,
            fixed_vaddr,
            chunks,
            flags,
        );

        try frame.mappings.ensureUnusedCapacity(gpa, 1);

        if (self.find(fixed_vaddr)) |idx| {
            const old_mapping = self.mappings.items[idx];
            if (old_mapping.overlaps(fixed_vaddr, @as(usize, chunks) * chunk_bytes)) {
                return Error.InvalidAddress;
            } else if (old_mapping.getVaddr().raw < fixed_vaddr.raw) {
                // log.debug("insert new mapping after 0x{x}", .{old_mapping.getVaddr().raw});
                // insert new mapping
                try self.mappings.insert(gpa, idx + 1, mapping);
            } else {
                // log.debug("insert new mapping before {} 0x{x}", .{ idx, old_mapping.getVaddr().raw });
                // insert new mapping
                try self.mappings.insert(gpa, idx, mapping);
            }
        } else {
            // log.debug("push new mapping", .{});
            // push new mapping
            try self.mappings.append(gpa, mapping);
        }

        // NOTE: ensureUnusedCapacity above
        frame.mappings.appendAssumeCapacity(mapping);

        if (conf.LOG_OBJ_CALLS) {
            log.info("Vmem.map successful", .{});
        }

        return fixed_vaddr;
    }

    pub fn mapHint(
        self: *@This(),
        frame: *caps.Frame,
        frame_first_chunk: u32,
        hint_vaddr: addr.Virt,
        chunks: u32,
        flags: abi.sys.MapFlags,
    ) Error!addr.Virt {
        if (self.mappings.items.len == 0) {
            return try self.mapFixed(
                frame,
                frame_first_chunk,
                hint_vaddr,
                chunks,
                flags,
            );
        }

        const mid_idx = self.find(hint_vaddr) orelse 0;
        // log.info("map with hint, mid_idx={}", .{mid_idx});
        // self.dump();

        for (mid_idx..self.mappings.items.len) |idx| {
            const slot_beg = self.mappings.items[idx].end();
            const slot_end = nextBoundry(self.mappings.items, idx);

            if (try self.trySlot(
                frame,
                chunks,
                frame_first_chunk,
                flags,
                slot_beg,
                slot_end,
            )) |mapped_addr| {
                return mapped_addr;
            }
        }

        for (0..mid_idx) |idx| {
            const slot_beg = prevBoundry(self.mappings.items, idx);
            const slot_end = self.mappings.items[idx].start();

            if (try self.trySlot(
                frame,
                chunks,
                frame_first_chunk,
                flags,
                slot_beg,
                slot_end,
            )) |mapped_addr| {
                return mapped_addr;
            }
        }

        return Error.OutOfVirtualMemory;
    }

    fn trySlot(
        self: *@This(),
        frame: *caps.Frame,
        chunks: u32,
        frame_first_chunk: u32,
        flags: abi.sys.MapFlags,
        slot_beg: addr.Virt,
        slot_end: addr.Virt,
    ) Error!?addr.Virt {
        const chunk_bytes = frame.chunk_size.sizeBytes();
        const slot_beg_aligned = slot_beg.alignForward(chunk_bytes);
        const slot_end_aligned = slot_end.alignBackward(chunk_bytes);

        // log.info("trying slot 0x{x}", .{slot.raw});
        if (slot_end_aligned.raw <= slot_beg_aligned.raw) return null;
        if (slot_end_aligned.raw - slot_beg_aligned.raw < @as(usize, chunks) * chunk_bytes) return null;

        return try self.mapFixed(
            frame,
            frame_first_chunk,
            slot_beg_aligned,
            chunks,
            flags,
        );
    }

    /// previous mapping, or a fake mapping that represents the address space boundry
    fn prevBoundry(mappings: []*caps.Mapping, idx: usize) addr.Virt {
        if (idx == 0) return .{ .raw = 0x1000 };
        return mappings[idx - 1].end();
    }

    /// next mapping, or a fake mapping that represents the address space boundry
    fn nextBoundry(mappings: []*caps.Mapping, idx: usize) addr.Virt {
        if (idx + 1 == mappings.len) return .{ .raw = 0x8000_0000_0000 };
        return mappings[idx + 1].start();
    }

    /// will most likely switch processes returning Error.Yield
    pub fn unmap(
        self: *@This(),
        trap: *arch.TrapRegs,
        thread: *caps.Thread,
        vaddr: addr.Virt,
    ) Error!void {
        std.debug.assert(self.check());
        defer std.debug.assert(self.check());

        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.unmap vaddr=0x{x}", .{vaddr.raw});
        defer if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.unmap returned", .{});

        // locking order: Vmem -> Frame
        //   0 or more Frames are locked in case 4 and after all cases
        self.lock.lock();

        const idx = self.find(vaddr) orelse {
            self.lock.unlock();
            return Error.NotMapped;
        };
        if (idx >= self.mappings.items.len) {
            self.lock.unlock();
            return Error.NotMapped;
        }
        const mapping = self.mappings.items[idx];
        if (mapping.target.unmapping) {
            self.lock.unlock();
            return Error.NotMapped;
        }

        const shootdown = caps.slab_allocator
            .allocator().create(caps.TlbShootdown) catch |err| {
            self.lock.unlock();
            return err;
        };
        mapping.target.unmapping = true;

        const vaddr_mapping = mapping.start();
        const mapping_chunk_size = mapping.frame.chunk_size.sizeBytes();

        // FIXME: save CPU LAPIC IDs for targetted TLB shootdown IPIs
        const ipi_bitmap: u256 = ~@as(u256, 0);

        for (0..mapping.chunks) |chunk_idx| {
            // already checked to be in bounds
            const vaddr_chunk = vaddr_mapping.add(chunk_idx * mapping_chunk_size);
            self.hal_vmem.disable(mapping.frame.chunk_size, vaddr_chunk);
        }
        self.lock.unlock();

        self.base.clone();
        shootdown.* = .{ .operation = .{ .unmap = .{
            .mapping = mapping,
            .thread = thread,
        } } };
        caps.incCount(.tlb_shootdown, .{});

        proc.switchFrom(trap, thread);

        // tests cannot yield or do IPIs or other stuff rn
        const id_self = arch.cpuId();
        for (main.all_cpu_locals, 0..) |*_locals, i| {
            // no need to send an IPI to self
            if (i == id_self) continue;
            const locals = _locals.load(.acquire) orelse continue;

            // no need to send an IPI to a CPU that has not used this Vmem
            if (ipi_bitmap & (@as(u256, 1) << @as(u8, @intCast(i))) == 0) continue;

            shootdown.refcnt.inc();
            locals.tlb_shootdown_queue.push(shootdown);

            // log.debug("issuing a TLB shootdown from unmap", .{});
            apic.interProcessorInterrupt(
                locals.lapic_id,
                apic.irqs.ipi_tlb_shootdown,
            );
        }

        if (shootdown.deinit(null)) |this_thread| {
            @branchHint(.likely);
            std.debug.assert(this_thread == thread);
            proc.switchUndo(thread);
        } else {
            return Error.Retry;
        }
    }

    /// update every `idx` chunk mapped from `frame` that is mapped into this vmem
    ///
    /// the mapping is removed from the hardware page tables but not from the mapping table
    /// so it is updated once a page fault happens
    pub fn refresh(
        self: *@This(),
        frame: *caps.Frame,
        idx: u32,
        dont_lock_if: ?*caps.Vmem,
    ) !void {
        // this function might or might not be ran on the
        // same vmem that started the cross-vmem page refresh
        if (self != dont_lock_if) self.lock.lock();
        defer if (self != dont_lock_if) self.lock.unlock();

        const chunk_size = frame.chunk_size;
        for (self.mappings.items) |mapping| {
            if (mapping.frame != frame) continue;

            std.debug.assert(idx >= mapping.frame_first_chunk);
            std.debug.assert(idx < mapping.frame_first_chunk + mapping.chunks);

            self.hal_vmem.disable(
                chunk_size,
                mapping.getVaddr(),
            );
        }
    }

    pub fn pageFault(
        self: *@This(),
        caused_by: abi.sys.FaultCause,
        vaddr_unaligned: addr.Virt,
        trap: *arch.TrapRegs,
        thread: *caps.Thread,
    ) Error!void {
        if (conf.LOG_PAGE_FAULTS)
            log.info("pf @0x{x}", .{vaddr_unaligned.raw});

        // locking order: Vmem -> Frame
        self.lock.lock();
        defer self.lock.unlock();

        // for (self.mappings.items) |mapping| {
        //     const va = mapping.getVaddr().raw;
        //     log.info("mapping [ 0x{x:0>16}..0x{x:0>16} ]", .{
        //         va,
        //         va + 0x1000 * mapping.pages,
        //     });
        // }

        // check if it was user error
        const idx = self.find(vaddr_unaligned) orelse
            return Error.NotMapped;

        const mapping = self.mappings.items[idx];

        // check if it was user error
        if (!mapping.overlaps(vaddr_unaligned, 1))
            return Error.NotMapped;

        // check if it was user error
        switch (caused_by) {
            .read => {
                if (!mapping.target.flags.read) return Error.ReadFault;
            },
            .write => {
                if (!mapping.target.flags.write) return Error.WriteFault;
            },
            .exec => {
                if (!mapping.target.flags.exec) return Error.ExecFault;
            },
        }

        const chunk_size = mapping.frame.chunk_size;
        switch (chunk_size) {
            .@"4KiB",
            .@"2MiB",
            .@"1GiB",
            => |page_size| {
                try self.pageFaultSized(
                    chunk_size,
                    page_size,
                    mapping,
                    caused_by,
                    vaddr_unaligned,
                    trap,
                    thread,
                );
            },
            else => unreachable,
        }
    }

    fn pageFaultSized(
        self: *@This(),
        chunk_size: abi.ChunkSize,
        page_size: abi.ChunkSize,
        mapping: *caps.Mapping,
        caused_by: abi.sys.FaultCause,
        vaddr_unaligned: addr.Virt,
        trap: *arch.TrapRegs,
        thread: *caps.Thread,
    ) Error!void {
        std.debug.assert(@intFromEnum(page_size) <= @intFromEnum(mapping.frame.chunk_size));

        const entry = self.hal_vmem.get(vaddr_unaligned);
        if (caused_by != .write and entry != null) {
            // already resolved by another thread
            return;
        }

        const addr_within_mapping = vaddr_unaligned.raw - mapping.getVaddr().raw;
        const mapping_chunk_offs: u32 = @intCast(addr_within_mapping % chunk_size.sizeBytes());
        const mapping_chunk_idx: u32 = @intCast(addr_within_mapping / chunk_size.sizeBytes());
        const page_offs: u32 = @intCast(addr_within_mapping % page_size.sizeBytes());
        // const page_idx: u32 = @intCast(addr_within_mapping / page_size.sizeBytes());

        const frame_update = try mapping.frame.pageFault(
            mapping_chunk_idx + mapping.frame_first_chunk,
            caused_by == .write,
            self,
            trap,
            thread,
        );

        const vaddr = vaddr_unaligned.sub(page_offs);
        const paddr = frame_update.page.add(mapping_chunk_offs).sub(page_offs);
        const page_state = frame_update.page_state;

        std.debug.assert(page_state != .uninit);
        if (caused_by == .write) std.debug.assert(page_state != .readonly_zero);

        // if (conf.LOG_PAGE_FAULTS) {
        //     log.debug(
        //         "vaddr_unaligned=0x{x} vaddr=0x{x} cause={t} paddr=0x{x} prev={any} page_state={t}",
        //         .{ vaddr_unaligned.raw, vaddr.raw, caused_by, paddr.raw, entry, page_state },
        //     );
        // }

        if (page_state == .readonly_zero) {
            // mapping 4KiB readonly pages
            try self.hal_vmem.insert(
                vaddr,
                null,
                page_size,
                mapping.target.flags.intersection(.urx),
            );
            return;
        }
        if (vaddr.raw % page_size.sizeBytes() != 0 or paddr.raw % page_size.sizeBytes() != 0) {
            log.debug("addr_within_mapping=0x{x} vaddr_unaligned=0x{x} vaddr=0x{x} paddr=0x{x} page_size={t} chunk_size={t}", .{
                addr_within_mapping,
                vaddr_unaligned.raw,
                vaddr.raw,
                paddr.raw,
                page_size,
                chunk_size,
            });
        }

        std.debug.assert(vaddr.raw % page_size.sizeBytes() == 0);
        std.debug.assert(paddr.raw % page_size.sizeBytes() == 0);

        const flags = if (page_state != .readonly_zero)
            mapping.target.flags.intersection(.urwx)
        else
            mapping.target.flags.intersection(.urx);

        if (entry != null) {
            log.debug("remapping with more rights", .{});
        }

        try self.hal_vmem.insert(
            vaddr,
            paddr,
            page_size,
            flags,
        );
    }

    pub fn dump(self: *@This()) void {
        self.lock.lock();
        defer self.lock.unlock();

        for (self.mappings.items) |mapping| {
            log.info("[ 0x{x:0>16} .. 0x{x:0>16} ]", .{
                mapping.start().raw,
                mapping.end().raw,
            });
        }
    }

    pub fn check(self: *@This()) bool {
        return self.checkInner(false);
    }

    fn checkInner(self: *@This(), comptime print: bool) bool {
        if (!conf.IS_DEBUG) return true;

        var ok = true;

        {
            self.lock.lock();
            defer self.lock.unlock();

            var prev: usize = 0;
            if (print) log.debug("checking vmem", .{});
            for (self.mappings.items) |mapping| {
                // make sure mappings are ordered
                const start = mapping.start();
                const end = mapping.end();
                if (start.raw < prev) ok = false;
                prev = end.raw;

                // make sure mappings are non-zero length
                if (mapping.chunks == 0) ok = false;

                if (print) log.debug("[ 0x{x:0>16} .. 0x{x:0>16} ] {s}", .{
                    start.raw,
                    end.raw,
                    if (ok) "ok" else "err",
                });
            }
        }

        if (!print and !ok)
            _ = self.checkInner(true);

        return ok;
    }

    // FIXME: this is a confusing function
    pub fn find(self: *@This(), vaddr: addr.Virt) ?usize {
        // log.info("find 0x{x}", .{vaddr.raw});
        // self.dump();

        const idx = std.sort.partitionPoint(
            *const caps.Mapping,
            self.mappings.items,
            vaddr,
            struct {
                fn pred(target_vaddr: addr.Virt, val: *const caps.Mapping) bool {
                    return val.end().raw <= target_vaddr.raw;
                }
            }.pred,
        );

        if (idx >= self.mappings.items.len)
            return null;

        // log.info("found [ 0x{x:0>16} .. 0x{x:0>16} ]", .{
        //     self.mappings.items[idx].start().raw,
        //     self.mappings.items[idx].end().raw,
        // });

        return idx;
    }
};
