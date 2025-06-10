const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const apic = @import("../apic.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const spin = @import("../spin.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const Vmem = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    lock: spin.Mutex = .new(),
    cr3: u32,
    mappings: std.ArrayList(*caps.Mapping),

    pub fn init() Error!*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.vmem);

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{
            .lock = .newLocked(),
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

    pub fn write(self: *@This(), vaddr: addr.Virt, source: []const volatile u8) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.write", .{});

        var bytes: []const volatile u8 = source;

        if (bytes.len == 0)
            return;

        // locking order: Vmem -> Frame
        //   mapping.frame.write locks a Frame
        self.lock.lock();
        defer self.lock.unlock();

        const idx_beg, const idx_end = try self.dataLocked(vaddr, bytes.len);

        for (idx_beg..idx_end) |idx| {
            std.debug.assert(bytes.len != 0);
            const mapping = self.mappings.items[idx];

            const offset_bytes: usize = if (idx == idx_beg)
                vaddr.raw - mapping.getVaddr().raw
            else
                0;
            const limit = @min(mapping.pages * 0x1000 - offset_bytes, bytes.len);

            try mapping.frame.write(
                mapping.frame_first_page * 0x1000 + offset_bytes,
                bytes[0..limit],
            );
            bytes = bytes[limit..];
        }
    }

    pub fn read(self: *@This(), vaddr: addr.Virt, dest: []volatile u8) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.read vaddr=0x{x} dest.len={}", .{ vaddr.raw, dest.len });

        var bytes: []volatile u8 = dest;

        if (bytes.len == 0)
            return;

        // locking order: Vmem -> Frame
        //   mapping.frame.read locks a Frame
        self.lock.lock();
        defer self.lock.unlock();

        const idx_beg, const idx_end = try self.dataLocked(vaddr, bytes.len);

        for (idx_beg..idx_end) |idx| {
            if (bytes.len == 0) break;
            const mapping = self.mappings.items[idx];

            // log.info("mapping [ 0x{x}..0x{x} ]", .{
            //     mapping.getVaddr().raw,
            //     mapping.getVaddr().raw + mapping.pages * 0x1000,
            // });

            const offset_bytes: usize = if (idx == idx_beg)
                vaddr.raw - mapping.getVaddr().raw
            else
                0;
            const limit = @min(mapping.pages * 0x1000 - offset_bytes, bytes.len);

            try mapping.frame.read(
                mapping.frame_first_page * 0x1000 + offset_bytes,
                bytes[0..limit],
            );
            bytes = bytes[limit..];
        }
    }

    fn dataLocked(self: *@This(), vaddr: addr.Virt, len: usize) Error!struct { usize, usize } {
        std.debug.assert(len != 0);

        if (self.mappings.items.len == 0)
            return Error.InvalidAddress;

        const vaddr_end_inclusive = try addr.Virt.fromUser(vaddr.raw + len - 1);

        const idx_beg: usize = self.find(vaddr) orelse return Error.InvalidAddress;
        const idx_end: usize = self.find(vaddr_end_inclusive) orelse return Error.InvalidAddress;

        if (!self.mappings.items[idx_beg].overlaps(vaddr, 1))
            return Error.InvalidAddress;
        if (!self.mappings.items[idx_end].overlaps(vaddr_end_inclusive, 1))
            return Error.InvalidAddress;

        // make sure the mappings are contiguous (no unmapped holes)
        for (idx_beg..idx_end) |idx| {
            const prev_mapping = self.mappings.items[idx];
            const next_mapping = self.mappings.items[idx + 1];

            errdefer log.warn("Vmem.write memory not contiguous", .{});
            if (prev_mapping.getVaddr().raw + prev_mapping.pages * 0x1000 != next_mapping.getVaddr().raw)
                return Error.InvalidAddress;
        }

        return .{ idx_beg, idx_end + 1 };
    }

    pub fn switchTo(self: *@This()) void {
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

    pub fn unmap(self: *@This(), vaddr: addr.Virt, pages: u32) Error!void {
        std.debug.assert(self.check());
        defer std.debug.assert(self.check());

        if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.unmap vaddr=0x{x} pages={}", .{ vaddr.raw, pages });
        defer if (conf.LOG_OBJ_CALLS)
            log.info("Vmem.unmap returned", .{});

        if (pages == 0) return;
        std.debug.assert(vaddr.toParts().offset == 0);
        try @This().assert_userspace(vaddr, pages);

        // locking order: Vmem -> Frame
        //   0 or more Frames are locked in case 4 and after all cases
        self.lock.lock();
        defer self.lock.unlock();

        var idx = self.find(vaddr) orelse return;

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
                break;
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

        const vmem = self.halPageTable();

        for (0..pages) |page_idx| {
            // already checked to be in bounds
            const page_vaddr = addr.Virt.fromInt(vaddr.raw + page_idx * 0x1000);
            vmem.unmapFrame(page_vaddr) catch |err| {
                log.warn("unmap err: {}, should be ok", .{err});
            };
            arch.flushTlbAddr(page_vaddr.raw);
        }

        // FIXME: targetted TLB shootdown
        // TODO: proper MMU lock, locking which forces all CPUs using it to context switch away
        for (0..255) |i| {
            apic.interProcessorInterrupt(@truncate(i), apic.IRQ_IPI_TLB_SHOOTDOWN);
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
        caused_by: arch.FaultCause,
        vaddr_unaligned: addr.Virt,
    ) Error!void {
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
                if (!mapping.target.rights.readable)
                    return Error.WriteFault;
            },
            .exec => {
                if (!mapping.target.rights.readable)
                    return Error.ExecFault;
            },
        }

        // check if it is lazy mapping

        const page_offs: u32 = @intCast((vaddr.raw - mapping.getVaddr().raw) / 0x1000);
        std.debug.assert(page_offs < mapping.pages);
        std.debug.assert(self.cr3 != 0);

        const vmem = self.halPageTable();

        const entry = (try vmem.entryFrame(vaddr)).*;

        switch (caused_by) {
            .read, .exec => {
                // was mapped but only now accessed using a read/exec
                std.debug.assert(entry.present == 0);

                const wanted_page_index = try mapping.frame.page_hit(
                    mapping.frame_first_page + page_offs,
                    false,
                );
                std.debug.assert(entry.page_index != wanted_page_index); // mapping error from a previous fault

                try vmem.mapFrame(
                    addr.Phys.fromParts(.{ .page = wanted_page_index }),
                    vaddr,
                    mapping.target.rights,
                    mapping.target.flags,
                );
                arch.flushTlbAddr(vaddr.raw);

                return;
            },
            .write => {
                // was mapped but only now accessed using a write

                // a read from a lazy
                const wanted_page_index = try mapping.frame.page_hit(
                    mapping.frame_first_page + page_offs,
                    true,
                );
                std.debug.assert(entry.page_index != wanted_page_index); // mapping error from a previous fault

                try vmem.mapFrame(
                    addr.Phys.fromParts(.{ .page = wanted_page_index }),
                    vaddr,
                    mapping.target.rights,
                    mapping.target.flags,
                );
                arch.flushTlbAddr(vaddr.raw);

                return;

                // TODO: copy on write maps
            },
        }

        // mapping has all rights and is present, the page fault should not have happened
        unreachable;
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
