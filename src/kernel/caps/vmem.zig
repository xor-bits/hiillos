const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const apic = @import("../apic.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const main = @import("../main.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const Vmem = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    lock: abi.lock.SpinMutex = .{},
    cr3: u32,
    mappings: std.ArrayList(*caps.Mapping),
    // bitset of all cpus that have used this vmem
    // cpus: u256 = 0,

    pub fn init() Error!*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.vmem);

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{
            .lock = .locked(),
            .cr3 = 0,
            .mappings = .init(caps.slab_allocator.allocator()),
        };
        obj.lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.vmem);

        for (self.mappings.items) |mapping| {
            mapping.frame.deinit();
        }

        self.mappings.deinit();
        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.clone", .{});

        self.refcnt.inc();
        return self;
    }

    pub fn halPageTable(self: *const @This()) *volatile caps.HalVmem {
        return addr.Phys.fromParts(.{ .page = self.cr3 })
            .toHhdm()
            .toPtr(*volatile caps.HalVmem);
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
                    self.vaddr.raw - mapping.getVaddr().raw + mapping.frame_first_page * 0x1000,
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
            if (conf.LOG_CTX_SWITCHES)
                log.debug("context switch avoided", .{});
            return;
        }

        // keep the previous vmem alive until after the switch, and then delete the reference
        // also clone the new vmem into local storage to keep it always alive
        const previous_vmem = current_vmem_ptr.*;
        current_vmem_ptr.* = self.clone();
        defer if (previous_vmem) |prev| prev.deinit();

        std.debug.assert(self.cr3 != 0);
        caps.HalVmem.switchTo(addr.Phys.fromParts(
            .{ .page = self.cr3 },
        ));
    }

    pub fn start(self: *@This()) Error!void {
        if (self.cr3 == 0) {
            @branchHint(.cold);

            const new_cr3 = try caps.HalVmem.alloc(null);
            caps.HalVmem.init(new_cr3);
            self.cr3 = new_cr3.toParts().page;
        }
    }

    pub fn map(
        self: *@This(),
        frame: *caps.Frame,
        frame_first_page: u32,
        vaddr: addr.Virt,
        pages: u32,
        rights: abi.sys.Rights,
        flags: abi.sys.MapFlags,
    ) Error!addr.Virt {
        errdefer frame.deinit();
        std.debug.assert(self.check());
        defer std.debug.assert(self.check());

        if (conf.LOG_OBJ_CALLS)
            log.info(
                \\Vmem.map
                \\ - frame={*}
                \\ - frame_first_page={}
                \\ - vaddr=0x{x}
                \\ - pages={}
                \\ - rights={}
                \\ - flags={}"
            , .{
                frame,
                frame_first_page,
                vaddr.raw,
                pages,
                rights,
                flags,
            });

        if (pages == 0) return Error.InvalidArgument;

        std.debug.assert(vaddr.toParts().offset == 0);
        try @This().assert_userspace(vaddr, pages);

        {
            frame.lock.lock();
            defer frame.lock.unlock();
            if (pages + frame_first_page > frame.pages.len)
                return Error.OutOfBounds;
        }

        // locking order: Vmem -> Frame
        self.lock.lock();
        defer self.lock.unlock();
        frame.lock.lock();
        defer frame.lock.unlock();

        const mapped_vaddr: addr.Virt = if (flags.fixed) b: {
            break :b try self.mapFixed(
                frame,
                frame_first_page,
                vaddr,
                pages,
                rights,
                flags,
            );
        } else b: {
            break :b try self.mapHint(
                frame,
                frame_first_page,
                vaddr,
                pages,
                rights,
                flags,
            );
        };

        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.map returned 0x{x}", .{mapped_vaddr.raw});

        return mapped_vaddr;
    }

    pub fn mapFixed(
        self: *@This(),
        frame: *caps.Frame,
        frame_first_page: u32,
        fixed_vaddr: addr.Virt,
        pages: u32,
        rights: abi.sys.Rights,
        flags: abi.sys.MapFlags,
    ) Error!addr.Virt {
        if (fixed_vaddr.raw == 0)
            return Error.InvalidAddress;

        const mapping = try caps.Mapping.init(
            frame.clone(),
            self,
            frame_first_page,
            fixed_vaddr,
            pages,
            rights,
            flags,
        );

        try frame.mappings.ensureUnusedCapacity(1);

        if (self.find(fixed_vaddr)) |idx| {
            const old_mapping = self.mappings.items[idx];
            if (old_mapping.overlaps(fixed_vaddr, pages * 0x1000)) {
                @panic("todo");

                // FIXME: unmap only the specific part
                // log.debug("replace old mapping", .{});
                // replace old mapping
                // old_mapping.frame.deinit();
                // old_mapping.* = mapping;
            } else if (old_mapping.getVaddr().raw < fixed_vaddr.raw) {
                // log.debug("insert new mapping after 0x{x}", .{old_mapping.getVaddr().raw});
                // insert new mapping
                try self.mappings.insert(idx + 1, mapping);
            } else {
                // log.debug("insert new mapping before {} 0x{x}", .{ idx, old_mapping.getVaddr().raw });
                // insert new mapping
                try self.mappings.insert(idx, mapping);
            }
        } else {
            // log.debug("push new mapping", .{});
            // push new mapping
            try self.mappings.append(mapping);
        }

        frame.mappings.append(mapping) catch unreachable; // NOTE: ensureUnusedCapacity above

        return fixed_vaddr;
    }

    pub fn mapHint(
        self: *@This(),
        frame: *caps.Frame,
        frame_first_page: u32,
        hint_vaddr: addr.Virt,
        pages: u32,
        rights: abi.sys.Rights,
        flags: abi.sys.MapFlags,
    ) Error!addr.Virt {
        if (self.mappings.items.len == 0) {
            return try self.mapFixed(
                frame,
                frame_first_page,
                hint_vaddr,
                pages,
                rights,
                flags,
            );
        }

        const mid_idx = self.find(hint_vaddr) orelse 0;
        // log.info("map with hint, mid_idx={}", .{mid_idx});
        // self.dump();

        for (mid_idx..self.mappings.items.len) |idx| {
            const slot = self.mappings.items[idx].end();
            const slot_size = nextBoundry(self.mappings.items, idx).raw - slot.raw;

            // log.info("trying slot 0x{x}", .{slot.raw});
            if (slot_size < pages * 0x1000) continue;

            return try self.mapFixed(
                frame,
                frame_first_page,
                slot,
                pages,
                rights,
                flags,
            );
        }

        for (0..mid_idx) |idx| {
            const slot = prevBoundry(self.mappings.items, idx);
            const slot_size = slot.raw - self.mappings.items[idx].start().raw;

            // log.info("trying slot 0x{x}", .{slot.raw});
            if (slot_size < pages * 0x1000) continue;

            return try self.mapFixed(
                frame,
                frame_first_page,
                slot,
                pages,
                rights,
                flags,
            );
        }

        return Error.OutOfVirtualMemory;
    }

    /// previous mapping, or a fake mapping that represents the address space boundry
    fn prevBoundry(mappings: []*caps.Mapping, idx: usize) addr.Virt {
        if (idx == 0) return addr.Virt.fromInt(0x1000);
        return mappings[idx - 1].end();
    }

    /// next mapping, or a fake mapping that represents the address space boundry
    fn nextBoundry(mappings: []*caps.Mapping, idx: usize) addr.Virt {
        if (idx + 1 == mappings.len) return addr.Virt.fromInt(0x8000_0000_0000);
        return mappings[idx + 1].start();
    }

    /// will most likely switch processes returning Error.Yield
    pub fn unmap(
        self: *@This(),
        trap: *arch.TrapRegs,
        thread: *caps.Thread,
        unaligned_vaddr: addr.Virt,
        pages: u32,
        comptime is_test: bool,
    ) Error!void {
        std.debug.assert(self.check());
        defer std.debug.assert(self.check());

        const vaddr: addr.Virt = .fromInt(std.mem.alignBackward(usize, unaligned_vaddr.raw, 0x1000));

        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.unmap vaddr=0x{x} pages={}", .{ vaddr.raw, pages });
        defer if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.unmap returned", .{});

        if (pages == 0)
            return;
        std.debug.assert(vaddr.toParts().offset == 0);
        try @This().assert_userspace(vaddr, pages);

        // locking order: Vmem -> Frame
        //   0 or more Frames are locked in case 4 and after all cases
        self.lock.lock();
        defer self.lock.unlock();

        var idx = self.find(vaddr) orelse
            return;

        while (true) {
            if (idx >= self.mappings.items.len)
                break;
            const mapping = self.mappings.items[idx];

            // cut the mapping into 0, 1 or 2 mappings

            const a_beg: usize = mapping.getVaddr().raw;
            const a_end: usize = mapping.getVaddr().raw + mapping.pages * 0x1000;
            const b_beg: usize = vaddr.raw;
            const b_end: usize = vaddr.raw + pages * 0x1000;

            if (a_end <= b_beg or b_end <= a_beg) {
                // case 0: no overlaps

                // log.debug("unmap case 0", .{});
                break;
            } else if (b_beg <= a_beg and b_end <= a_end) {
                // case 1:
                // b: |---------|
                // a:      |=====-----|

                // log.debug("unmap case 1", .{});
                const shift: u32 = @intCast((b_end - a_beg) / 0x1000);
                mapping.setVaddr(addr.Virt.fromInt(b_end));
                mapping.pages -= shift;
                mapping.frame_first_page += shift;
            } else if (a_beg >= b_beg and a_end <= a_end) {
                // case 2:
                // b: |---------------------|
                // a:      |==========|

                // log.debug("unmap case 2", .{});
                mapping.pages = 0;
            } else if (b_beg >= a_beg and b_end >= a_end) {
                // case 3:
                // b:            |---------|
                // a:      |-----=====|

                // log.debug("unmap case 3", .{});
                const trunc: u32 = @intCast((a_end - b_beg) / 0x1000);
                mapping.pages -= trunc;
            } else {
                std.debug.assert(a_beg < b_beg);
                std.debug.assert(a_end > b_end);
                // case 4:
                // b:      |----------|
                // a: |----============-----|
                // cases 1,2,3 already cover equal start/end bounds

                // log.debug("unmap case 4", .{});
                try self.mappings.ensureUnusedCapacity(1);
                try mapping.frame.mappings.ensureUnusedCapacity(1);

                const cloned = try mapping.clone();

                const trunc: u32 = @intCast((a_end - b_beg) / 0x1000);
                mapping.pages -= trunc;

                const shift: u32 = @intCast((b_end - a_beg) / 0x1000);
                cloned.setVaddr(addr.Virt.fromInt(b_end));
                cloned.pages -= shift;
                cloned.frame_first_page += shift;

                cloned.frame.lock.lock();
                cloned.frame.mappings.append(cloned) catch unreachable;
                cloned.frame.lock.unlock();
                self.mappings.insert(idx + 1, cloned) catch unreachable;

                break;
            }

            if (mapping.pages == 0) {
                self.orderedRemoveMappingLocked(idx);
                // TODO: batch remove
            } else {
                idx += 1;
            }
        }

        if (self.cr3 == 0)
            return;
        const hal_vmem = self.halPageTable();

        // FIXME: save CPU LAPIC IDs for targetted TLB shootdown IPIs
        const ipi_bitmap: u256 = ~@as(u256, 0);

        for (0..pages) |page_idx| {
            // already checked to be in bounds
            const page_vaddr = addr.Virt.fromInt(vaddr.raw + page_idx * 0x1000);
            hal_vmem.unmapFrame(page_vaddr) catch |err| {
                log.warn("unmap err: {}, should be ok", .{err});
            };
        }

        const shootdown = try caps.TlbShootdown.init(
            .{ .unmap = thread },
            .{ .range = .{
                vaddr,
                addr.Virt.fromInt(vaddr.raw + pages * 0x1000),
            } },
        );
        thread.status = .waiting;
        thread.waiting_cause = .unmap_tlb_shootdown;
        proc.switchFrom(trap, thread);

        // tests cannot yield or do IPIs or other stuff rn
        if (!is_test) for (main.all_cpu_locals, 0..) |*locals, i| {
            // no need to send an IPI to self
            if (locals == arch.cpuLocal()) continue;

            if (ipi_bitmap & (@as(u256, 1) << @as(u8, @intCast(i))) != 0) {
                locals.pushTlbShootdown(shootdown.clone());

                // log.debug("issuing a TLB shootdown from unmap", .{});
                apic.interProcessorInterrupt(
                    locals.lapic_id,
                    apic.IRQ_IPI_TLB_SHOOTDOWN,
                );
            } else {}
        };

        if (shootdown.deinit()) |this_thread| {
            @branchHint(.likely);
            std.debug.assert(this_thread == thread);
            this_thread.status = .running;
            proc.switchUndo(thread);
        } else {
            return Error.Retry;
        }
    }

    /// update every `idx` page mapped from `frame` that is mapped into this vmem
    ///
    /// the mapping is removed from the hardware page tables but not from the mapping table
    /// so it is updated once a page fault happens
    pub fn refresh(
        self: *@This(),
        frame: *caps.Frame,
        idx: u32,
        ipi_bitmap: *u256,
        dont_lock_if: ?*caps.Vmem,
    ) !void {
        // this function might or might not be ran on the
        // same vmem that started the cross-vmem page refresh
        if (self != dont_lock_if) self.lock.lock();
        defer if (self != dont_lock_if) self.lock.unlock();

        if (self.cr3 == 0)
            return;

        const hal_vmem = self.halPageTable();

        for (self.mappings.items) |mapping| {
            if (mapping.frame != frame) continue;

            // check if the `idx` is within this mapping
            const mapping_idx = std.math.sub(
                u32,
                idx,
                mapping.frame_first_page,
            ) catch continue;
            if (mapping_idx >= mapping.pages) continue;

            const vaddr = addr.Virt.fromInt(mapping.getVaddr().raw + 0x1000 * mapping_idx);

            try refreshPageAndTlbShootdown(
                frame,
                hal_vmem,
                vaddr,
                ipi_bitmap,
            );
        }

        // FIXME: save CPU LAPIC IDs for targetted TLB shootdown IPIs
    }

    fn refreshPageAndTlbShootdown(
        frame: *caps.Frame,
        hal_vmem: *volatile caps.HalVmem,
        vaddr: addr.Virt,
        ipi_bitmap: *u256,
    ) !void {
        hal_vmem.canUnmapFrame(vaddr) catch |err| {
            // not mapped = no need to unmap and tlb shootdown it
            if (err == Error.NotMapped) return;
            return err;
        };
        try hal_vmem.unmapFrame(vaddr);

        // TODO: atomically swap the frame entry,
        // swapping in the empty entry and acquiring the `accessed` and `dirty` bits

        // log.debug("found a stale TLB entry", .{});

        const shootdown = try caps.TlbShootdown.init(
            .{ .transient = frame.clone() },
            .{ .individual = vaddr },
        );
        defer _ = shootdown.deinit();

        for (main.all_cpu_locals, 0..) |*locals, i| {
            if (!locals.initialized.load(.acquire)) continue;

            if (locals == arch.cpuLocal()) {
                // no need to send a self IPI
                arch.flushTlbAddr(vaddr.raw);
            } else {
                locals.pushTlbShootdown(shootdown.clone());
                ipi_bitmap.* |= @as(u256, 1) << @as(u8, @intCast(i));
            }
        }
    }

    fn orderedRemoveMappingLocked(self: *@This(), idx: usize) void {
        const mapping = self.mappings.orderedRemove(idx);

        // remove the mapping from the mapped frame also
        mapping.frame.lock.lock();
        for (mapping.frame.mappings.items, 0..) |same, i| {
            if (same == mapping) {
                _ = mapping.frame.mappings.swapRemove(i);
                break;
            }
        }
        for (mapping.frame.mappings.items) |same| {
            std.debug.assert(same != mapping); // no duplicates
        }
        mapping.frame.lock.unlock();

        mapping.deinit();
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

        const vaddr: addr.Virt = addr.Virt.fromInt(std.mem.alignBackward(
            usize,
            vaddr_unaligned.raw,
            0x1000,
        ));

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
        const idx = self.find(vaddr) orelse
            return Error.NotMapped;

        const mapping = self.mappings.items[idx];

        // check if it was user error
        if (!mapping.overlaps(vaddr, 1))
            return Error.NotMapped;

        // check if it was user error
        switch (caused_by) {
            .read => {
                if (!mapping.target.rights.readable)
                    return Error.ReadFault;
            },
            .write => {
                if (!mapping.target.rights.writable)
                    return Error.WriteFault;
            },
            .exec => {
                if (!mapping.target.rights.executable)
                    return Error.ExecFault;
            },
        }

        // check if it is lazy mapping

        const page_offs: u32 = @intCast((vaddr.raw - mapping.getVaddr().raw) / 0x1000);
        std.debug.assert(page_offs < mapping.pages);
        std.debug.assert(self.cr3 != 0);

        const hal_vmem = self.halPageTable();
        const entry = (try hal_vmem.entryFrame(vaddr)).*;

        // accessing a page with a write also immediately makes it readable/executable
        // log.debug("caused_by={} entry={}", .{ caused_by, entry });
        if (caused_by != .write and entry.present != 0) {
            // already resolved by another thread
            return;
        }

        // read, exec => was mapped but only now accessed using a read/exec
        // write      => was mapped but only now accessed using a write
        const wanted_page_index = try mapping.frame.pageFault(
            mapping.frame_first_page + page_offs,
            caused_by == .write,
            self,
            trap,
            thread,
        );

        if (conf.LOG_PAGE_FAULTS)
            log.debug("vaddr=0x{x} cause={s} wanted={} prev={}", .{
                vaddr.raw,
                @tagName(caused_by),
                wanted_page_index,
                entry,
            });

        // if the wanted_page_index is the same as the existing page,
        // then the cause must be a write after it was already mapped with read
        // and remapping the same page with new rights is fine without TLB shootdown IPIs

        const rights = if (caused_by == .write)
            mapping.target.rights
        else
            mapping.target.rights.intersection(comptime abi.sys.Rights.parse("urx").?);

        if (conf.LOG_PAGE_FAULTS and wanted_page_index == entry.page_index)
            log.debug("remapping with more rights: {}", .{rights});

        try hal_vmem.mapFrame(
            addr.Phys.fromParts(.{ .page = wanted_page_index }),
            vaddr,
            rights,
            mapping.target.flags,
        );
        arch.flushTlbAddr(vaddr.raw);
    }

    pub fn dump(self: *@This()) void {
        for (self.mappings.items) |mapping| {
            log.info("[ 0x{x:0>16} .. 0x{x:0>16} ]", .{
                mapping.getVaddr().raw,
                mapping.getVaddr().raw + mapping.pages * 0x1000,
            });
        }
    }

    pub fn check(self: *@This()) bool {
        if (!conf.IS_DEBUG) return true;

        var ok = true;

        var prev: usize = 0;
        // log.debug("checking vmem", .{});
        for (self.mappings.items) |mapping| {
            if (mapping.getVaddr().raw < prev) ok = false;
            prev = mapping.getVaddr().raw + mapping.pages * 0x1000;

            // log.debug("[ 0x{x:0>16} .. 0x{x:0>16} ] {s}", .{
            //     mapping.getVaddr().raw,
            //     mapping.getVaddr().raw + mapping.pages * 0x1000,
            //     if (ok) "ok" else "err",
            // });
        }

        return ok;
    }

    fn assert_userspace(vaddr: addr.Virt, pages: u32) Error!void {
        const upper_bound: usize = std.math.add(
            usize,
            vaddr.raw,
            std.math.mul(
                usize,
                pages,
                0x1000,
            ) catch return Error.OutOfBounds,
        ) catch return Error.OutOfBounds;
        if (upper_bound > 0x8000_0000_0000) {
            return Error.OutOfBounds;
        }
    }

    // FIXME: this is a confusing function
    fn find(self: *@This(), vaddr: addr.Virt) ?usize {
        // log.info("find 0x{x}", .{vaddr.raw});
        // self.dump();

        const idx = std.sort.partitionPoint(
            *const caps.Mapping,
            self.mappings.items,
            vaddr,
            struct {
                fn pred(target_vaddr: addr.Virt, val: *const caps.Mapping) bool {
                    return (val.getVaddr().raw + 0x1000 * val.pages) <= target_vaddr.raw;
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
