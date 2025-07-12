const std = @import("std");
const abi = @import("abi");

const addr = @import("../addr.zig");
const apic = @import("../apic.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");

//

const conf = abi.conf;
const log = std.log.scoped(.ioport);
const Error = abi.sys.Error;
const volat = abi.util.volat;

//

pub fn init() !void {
    const cr3 = arch.Cr3.read();
    const level4 = addr.Phys.fromInt(cr3.pml4_phys_base << 12)
        .toHhdm().toPtr(*Vmem);
    // TODO: make a deep copy instead and make every higher half mapping global
    abi.util.copyForwardsVolatile(Entry, kernel_table.entries[256..], level4.entries[256..]);
}

//

// FIXME: flush TLB + IPI other CPUs to prevent race conditions
/// a `Thread` points to this
pub const Vmem = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn init(self: addr.Phys) void {
        const ptr = self.toHhdm().toPtr(*volatile @This());
        abi.util.fillVolatile(Entry, ptr.entries[0..256], .{});
        abi.util.copyForwardsVolatile(Entry, ptr.entries[256..], kernel_table.entries[256..]);
    }

    pub fn alloc(_: ?abi.ChunkSize) Error!addr.Phys {
        return pmem.alloc(@sizeOf(@This())) orelse return Error.OutOfMemory;
    }

    pub fn switchTo(self: addr.Phys) void {
        const cur = arch.Cr3.read();
        if (cur.pml4_phys_base == self.toParts().page) {
            if (conf.LOG_CTX_SWITCHES)
                log.debug("context switch avoided", .{});
            return;
        }

        (arch.Cr3{
            .pml4_phys_base = self.toParts().page,
        }).write();

        if (conf.LOG_CTX_SWITCHES)
            log.debug("context switched", .{});
    }

    pub fn printMappings(self: *volatile @This()) !void {
        // go through every single page in this address space,
        // and print contiguous similar chunks.

        const Current = struct {
            base: addr.Virt,
            target: addr.Phys,
            write: bool,
            exec: bool,
            user: bool,

            fn fromEntry(from: addr.Virt, e: Entry) @This() {
                return .{
                    .base = from,
                    .target = addr.Phys.fromParts(.{ .page = e.page_index }),
                    .write = e.writable != 0,
                    .exec = e.no_execute == 0,
                    .user = e.user_accessible != 0,
                };
            }

            fn isContiguous(a: @This(), b: @This()) bool {
                if (a.write != b.write or a.exec != b.exec or a.user != b.user) {
                    return false;
                }

                const a_diff: i128 = @truncate(@as(i128, a.base.raw) - @as(i128, a.target.raw));
                const b_diff: i128 = @truncate(@as(i128, a.base.raw) - @as(i128, a.target.raw));

                return a_diff == b_diff;
            }

            fn printRange(from: @This(), to: addr.Virt) void {
                const size = to.raw - from.base.raw;
                log.info(" - {s}R{s}{s} [ 0x{x:0>16}..0x{x:0>16} ] => 0x{x:0>16} (0x{x}B)", .{
                    if (from.user) "U" else "-",
                    if (from.write) "W" else "-",
                    if (from.exec) "X" else "-",
                    from.base.raw,
                    to.raw,
                    from.target.raw,
                    size,
                });
            }

            fn missing(s: *?@This(), vaddr: addr.Virt) void {
                if (s.*) |base| {
                    base.printRange(vaddr);
                    s.* = null;
                }
            }

            fn present(s: *?@This(), vaddr: addr.Virt, entry: Entry) void {
                const cur = @This().fromEntry(vaddr, entry);
                const base: @This() = s.* orelse {
                    s.* = cur;
                    return;
                };

                if (!base.isContiguous(cur)) {
                    base.printRange(vaddr);
                    s.* = cur;
                    return;
                }
            }
        };

        var maybe_base: ?Current = null;

        for (0..256) |l4| {
            const colossial = addr.Virt.fromParts(.{
                .level4 = @truncate(l4),
            });

            if (volat(&self.entries[l4]).*.present == 0) {
                Current.missing(&maybe_base, colossial);
                continue;
            }

            for (0..512) |l3| {
                const giant = addr.Virt.fromParts(.{
                    .level4 = @truncate(l4),
                    .level3 = @truncate(l3),
                });

                if ((try self.entryGiantFrame(giant)).*.present == 0) {
                    Current.missing(&maybe_base, giant);
                    continue;
                }

                for (0..512) |l2| {
                    const huge = addr.Virt.fromParts(.{
                        .level4 = @truncate(l4),
                        .level3 = @truncate(l3),
                        .level2 = @truncate(l2),
                    });

                    if ((try self.entryHugeFrame(huge)).*.present == 0) {
                        Current.missing(&maybe_base, huge);
                        continue;
                    }

                    for (0..512) |l1| {
                        const vaddr = addr.Virt.fromParts(.{
                            .level4 = @truncate(l4),
                            .level3 = @truncate(l3),
                            .level2 = @truncate(l2),
                            .level1 = @truncate(l1),
                        });
                        const frame = (try self.entryFrame(vaddr)).*;

                        if (frame.present == 0) {
                            Current.missing(&maybe_base, vaddr);
                            continue;
                        }

                        Current.present(&maybe_base, vaddr, frame);
                    }
                }
            }
        }

        Current.missing(&maybe_base, addr.Virt.fromParts(.{
            .level4 = 256,
        }));
    }

    pub fn entryGiantFrame(self: *volatile @This(), vaddr: addr.Virt) Error!*volatile Entry {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.entryGiantFrame(vaddr);
    }

    pub fn entryHugeFrame(self: *volatile @This(), vaddr: addr.Virt) Error!*volatile Entry {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.entryHugeFrame(vaddr);
    }

    pub fn entryFrame(self: *volatile @This(), vaddr: addr.Virt) Error!*volatile Entry {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.entryFrame(vaddr);
    }

    pub fn mapGiantFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        try next.mapGiantFrame(paddr, vaddr, rights, flags);
    }

    pub fn mapHugeFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        try next.mapHugeFrame(paddr, vaddr, rights, flags);
    }

    pub fn mapFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        try next.mapFrame(paddr, vaddr, rights, flags);
    }

    pub fn canMapGiantFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.canMapGiantFrame(vaddr);
    }

    pub fn canMapHugeFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.canMapHugeFrame(vaddr);
    }

    pub fn canMapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.canMapFrame(vaddr);
    }

    pub fn unmapGiantFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const current, const i = .{ &self.entries, vaddr.toParts().level4 };
        const next = (try nextLevel(true, current, i)).toHhdm().toPtr(*volatile PageTableLevel3);
        if (next.unmapGiantFrame(vaddr))
            deallocLevel(current, i);
    }

    pub fn unmapHugeFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const current, const i = .{ &self.entries, vaddr.toParts().level4 };
        const next = (try nextLevel(true, current, i)).toHhdm().toPtr(*volatile PageTableLevel3);
        if (try next.unmapHugeFrame(vaddr))
            deallocLevel(current, i);
    }

    pub fn unmapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const current, const i = .{ &self.entries, vaddr.toParts().level4 };
        const next = (try nextLevel(true, current, i)).toHhdm().toPtr(*volatile PageTableLevel3);
        if (try next.unmapFrame(vaddr))
            deallocLevel(current, i);
    }

    pub fn canUnmapGiantFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.canUnmapGiantFrame(paddr, vaddr);
    }

    pub fn canUnmapHugeFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.canUnmapHugeFrame(paddr, vaddr);
    }

    pub fn canUnmapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*volatile PageTableLevel3);
        return next.canUnmapFrame(vaddr);
    }
};

/// a `PageTableLevel4` points to multiple of these
pub const PageTableLevel3 = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn entryGiantFrame(self: *volatile @This(), vaddr: addr.Virt) *volatile Entry {
        return &self.entries[vaddr.toParts().level3];
    }

    pub fn entryHugeFrame(self: *volatile @This(), vaddr: addr.Virt) Error!*volatile Entry {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        return next.entryHugeFrame(vaddr);
    }

    pub fn entryFrame(self: *volatile @This(), vaddr: addr.Virt) Error!*volatile Entry {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        return next.entryFrame(vaddr);
    }

    pub fn mapGiantFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const entry = Entry.fromParts(true, false, rights, paddr, flags);
        volat(&self.entries[vaddr.toParts().level3]).* = entry;
    }

    pub fn mapHugeFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        try next.mapHugeFrame(paddr, vaddr, rights, flags);
    }

    pub fn mapFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        try next.mapFrame(paddr, vaddr, rights, flags);
    }

    pub fn canMapGiantFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const entry = volat(&self.entries[vaddr.toParts().level3]).*;
        if (entry.present == 1) return Error.MappingOverlap;
    }

    pub fn canMapHugeFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        return next.canMapHugeFrame(vaddr);
    }

    pub fn canMapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        return next.canMapFrame(vaddr);
    }

    pub fn unmapGiantFrame(self: *volatile @This(), vaddr: addr.Virt) bool {
        volat(&self.entries[vaddr.toParts().level3]).* = .{};
        return isEmpty(&self.entries);
    }

    pub fn unmapHugeFrame(self: *volatile @This(), vaddr: addr.Virt) Error!bool {
        const current, const i = .{ &self.entries, vaddr.toParts().level3 };
        const next = (try nextLevel(true, current, i)).toHhdm().toPtr(*volatile PageTableLevel2);
        if (next.unmapHugeFrame(vaddr))
            deallocLevel(current, i);
        return isEmpty(&self.entries);
    }

    pub fn unmapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!bool {
        const current, const i = .{ &self.entries, vaddr.toParts().level3 };
        const next = (try nextLevel(true, current, i)).toHhdm().toPtr(*volatile PageTableLevel2);
        if (try next.unmapFrame(vaddr))
            deallocLevel(current, i);
        return isEmpty(&self.entries);
    }

    pub fn canUnmapGiantFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt) Error!void {
        const entry = volat(&self.entries[vaddr.toParts().level3]).*;
        if (entry.present != 1) return Error.NotMapped;
        if (entry.huge_page_or_pat != 1) return Error.NotMapped;
        if (entry.page_index & 0xFFFF_FFFE != paddr.toParts().page) return Error.NotMapped;
    }

    pub fn canUnmapHugeFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        return next.canUnmapHugeFrame(paddr, vaddr);
    }

    pub fn canUnmapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*volatile PageTableLevel2);
        return next.canUnmapFrame(vaddr);
    }
};

/// a `PageTableLevel3` points to multiple of these
pub const PageTableLevel2 = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn entryHugeFrame(self: *volatile @This(), vaddr: addr.Virt) *volatile Entry {
        return &self.entries[vaddr.toParts().level2];
    }

    pub fn entryFrame(self: *volatile @This(), vaddr: addr.Virt) Error!*volatile Entry {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level2)).toHhdm().toPtr(*volatile PageTableLevel1);
        return next.entryFrame(vaddr);
    }

    pub fn mapHugeFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const entry = Entry.fromParts(true, false, rights, paddr, flags);
        volat(&self.entries[vaddr.toParts().level2]).* = entry;
    }

    pub fn mapFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level2)).toHhdm().toPtr(*volatile PageTableLevel1);
        next.mapFrame(paddr, vaddr, rights, flags);
    }

    pub fn canMapHugeFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const entry = volat(&self.entries[vaddr.toParts().level2]).*;
        if (entry.present == 1) return Error.MappingOverlap;
    }

    pub fn canMapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level2)).toHhdm().toPtr(*volatile PageTableLevel1);
        return next.canMapFrame(vaddr);
    }

    pub fn unmapHugeFrame(self: *volatile @This(), vaddr: addr.Virt) bool {
        volat(&self.entries[vaddr.toParts().level2]).* = .{};
        return isEmpty(&self.entries);
    }

    pub fn unmapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!bool {
        const current, const i = .{ &self.entries, vaddr.toParts().level2 };
        const next = (try nextLevel(true, current, i)).toHhdm().toPtr(*volatile PageTableLevel1);
        if (next.unmapFrame(vaddr))
            deallocLevel(current, i);
        return isEmpty(&self.entries);
    }

    pub fn canUnmapHugeFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt) Error!void {
        const entry: Entry = volat(&self.entries[vaddr.toParts().level2]).*;
        if (entry.present != 1) return Error.NotMapped;
        if (entry.huge_page_or_pat != 1) return Error.NotMapped;
        if (entry.page_index & 0xFFFF_FFFE != paddr.toParts().page) return Error.NotMapped;
    }

    pub fn canUnmapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const next = (try nextLevel(true, &self.entries, vaddr.toParts().level2)).toHhdm().toPtr(*volatile PageTableLevel1);
        return next.canUnmapFrame(vaddr);
    }
};

/// a `PageTableLevel2` points to multiple of these
pub const PageTableLevel1 = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn entryFrame(self: *volatile @This(), vaddr: addr.Virt) *volatile Entry {
        return &self.entries[vaddr.toParts().level1];
    }

    pub fn mapFrame(self: *volatile @This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) void {
        const entry = Entry.fromParts(false, true, rights, paddr, flags);
        volat(&self.entries[vaddr.toParts().level1]).* = entry;
    }

    pub fn canMapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const entry: Entry = volat(&self.entries[vaddr.toParts().level1]).*;
        if (entry.present == 1) return Error.MappingOverlap;
    }

    pub fn unmapFrame(self: *volatile @This(), vaddr: addr.Virt) bool {
        volat(&self.entries[vaddr.toParts().level1]).* = Entry{};
        return isEmpty(&self.entries);
    }

    pub fn canUnmapFrame(self: *volatile @This(), vaddr: addr.Virt) Error!void {
        const entry: Entry = volat(&self.entries[vaddr.toParts().level1]).*;
        if (entry.present != 1) return Error.NotMapped;
    }
};

// just x86_64 rn
pub const Entry = packed struct {
    present: u1 = 0,
    writable: u1 = 0,
    user_accessible: u1 = 0,
    write_through: u1 = 0,
    cache_disable: u1 = 0,
    accessed: u1 = 0,
    dirty: u1 = 0,
    huge_page_or_pat: u1 = 0,
    global: u1 = 0,

    // more custom bits
    _free_to_use1: u3 = 0,

    page_index: u32 = 0,
    reserved: u8 = 0,

    // custom bits
    _free_to_use0: u7 = 0,

    protection_key: u4 = 0,
    no_execute: u1 = 0,

    pub fn getCacheMode(self: @This(), comptime is_last_level: bool) abi.sys.CacheType {
        var idx: u3 = 0;
        if (is_last_level)
            idx |= @as(u3, self.huge_page_or_pat) << 2
        else
            idx |= @as(u3, @truncate(self.page_index & 0b1)) << 2;
        idx |= @as(u3, self.cache_disable) << 1;
        idx |= @as(u3, self.write_through) << 0;
        return std.meta.intToEnum(abi.sys.CacheType, idx) catch unreachable;
    }

    pub fn fromParts(
        comptime is_huge: bool,
        comptime is_last_level: bool,
        rights: abi.sys.Rights,
        frame: addr.Phys,
        flags: abi.sys.MapFlags,
    ) Entry {
        std.debug.assert(frame.toParts().reserved0 == 0);
        std.debug.assert(frame.toParts().reserved1 == 0);

        var page_index = frame.toParts().page;
        var pwt: u1 = 0;
        var pcd: u1 = 0;
        var huge_page_or_pat: u1 = 0;
        const pat_index = @as(u3, @truncate(@intFromEnum(flags.cache)));
        if (is_last_level) {
            if (pat_index & 0b001 != 0) pwt = 1;
            if (pat_index & 0b010 != 0) pcd = 1;
            if (pat_index & 0b100 != 0) huge_page_or_pat = 1;
        } else if (is_huge) {
            if (pat_index & 0b001 != 0) pwt = 1;
            if (pat_index & 0b010 != 0) pcd = 1;
            if (pat_index & 0b100 != 0) page_index |= 1;
            huge_page_or_pat = 1;
        } else {
            // huge on last level is illegal
            // and intermediary tables dont have cache modes (prob)
        }

        return Entry{
            .present = 1,
            .writable = @intFromBool(rights.writable),
            .user_accessible = @intFromBool(rights.user_accessible),
            .write_through = pwt,
            .cache_disable = pcd,
            .huge_page_or_pat = huge_page_or_pat,
            .global = 0,
            .page_index = page_index,
            .protection_key = 0,
            .no_execute = @intFromBool(!rights.executable),
        };
    }
};

//

var kernel_table: Vmem = undefined;

fn allocPage() addr.Phys {
    return pmem.allocChunk(.@"4KiB") orelse std.debug.panic("OOM", .{});
}

fn allocTable() addr.Phys {
    const table = allocPage();
    const entries: []volatile Entry = table.toHhdm().toPtr([*]volatile Entry)[0..512];
    abi.util.fillVolatile(Entry, entries, .{});
    return table;
}

fn nextLevel(comptime create: bool, current: *volatile [512]Entry, i: u9) Error!addr.Phys {
    return nextLevelFromEntry(create, &current[i]);
}

fn deallocLevel(current: *volatile [512]Entry, i: u9) void {
    const entry = volat(&current[i]).*;
    volat(&current[i]).* = .{};
    pmem.deallocChunk(addr.Phys.fromParts(.{ .page = entry.page_index }), .@"4KiB");
}

fn nextLevelFromEntry(comptime create: bool, entry: *volatile Entry) Error!addr.Phys {
    const entry_r = entry.*;
    if (entry_r.present == 0 and create) {
        const table = allocTable();
        entry.* = Entry.fromParts(
            false,
            false,
            .{
                .writable = true,
                .executable = true,
            },
            table,
            .{},
        );
        return table;
    } else if (entry_r.present == 0) {
        return error.EntryNotPresent;
    } else if (entry_r.huge_page_or_pat == 1) {
        return error.EntryIsHuge;
    } else {
        return addr.Phys.fromParts(.{ .page = entry_r.page_index });
    }
}

fn isEmpty(entries: *volatile [512]Entry) bool {
    for (entries) |*entry| {
        if (volat(entry).*.present == 1)
            return false;
    }
    return true;
}

//

pub const X86IoPortAllocator = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    pub fn init() !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("X86IoPortAllocator.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.x86_ioport_allocator);

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{};

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("X86IoPortAllocator.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.x86_ioport_allocator);

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("X86IoPortAllocator.clone", .{});

        self.refcnt.inc();
        return self;
    }
};

// TODO: use IOPB in the TSS for this
pub const X86IoPort = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    port: u16,

    // only borrows the `*X86IoPortAllocator`
    pub fn init(_: *X86IoPortAllocator, port: u16) Error!*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("X86IoPort.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.x86_ioport);

        try allocPort(&port_bitmap, port);

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{ .port = port };

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("X86IoPort.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.x86_ioport);

        freePort(&port_bitmap, self.port) catch
            unreachable;

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("X86IoPort.clone", .{});

        self.refcnt.inc();
        return self;
    }

    // TODO: IOPB
    // pub fn enable() void {}
    // pub fn disable() void {}

    pub fn inb(self: *@This()) u32 {
        const byte = arch.inb(self.port);

        if (conf.LOG_OBJ_CALLS)
            log.info("X86IoPort.inb port={} byte={}", .{ self.port, byte });

        return byte;
    }

    pub fn outb(self: *@This(), byte: u8) void {
        if (conf.LOG_OBJ_CALLS)
            log.info("X86IoPort.outb port={} byte={}", .{ self.port, byte });

        arch.outb(self.port, byte);
    }
};

pub const X86IrqAllocator = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    pub fn init() !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("X86IrqAllocator.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.x86_irq_allocator);

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{};

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("X86IrqAllocator.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.x86_irq_allocator);

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("X86IrqAllocator.clone", .{});

        self.refcnt.inc();
        return self;
    }
};

pub const X86Irq = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    notify: *caps.Notify,

    irq: u8,
    handler: ?struct {
        vector: u8,
        locals: *apic.Locals,
    } = null,

    // only borrows the X86IrqAllocator
    pub fn init(_: *X86IrqAllocator, irq: u8) Error!*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("X86Irq.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.x86_irq);

        try allocIrq(&irq_bitmap, irq);
        errdefer freeIrq(&irq_bitmap, irq) catch unreachable;

        const notify = try caps.Notify.init();
        errdefer notify.deinit();

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{
            .irq = irq,
            .notify = notify,
        };

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("X86Irq.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.x86_irq);

        self.notify.deinit();

        freeIrq(&irq_bitmap, self.irq) catch
            unreachable;

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("X86Irq.clone", .{});

        self.refcnt.inc();
        return self;
    }

    pub fn subscribe(self: *@This()) Error!*caps.Notify {
        if (conf.LOG_OBJ_CALLS)
            log.info("X86Irq.subscribe", .{});

        if (self.handler == null) {
            const result = try apic.registerExternalInterrupt(self.clone());
            self.handler = .{ .vector = result.vector, .locals = result.locals };

            log.debug("X86Irq registered vec={} irq={}", .{
                result.vector,
                self.irq,
            });
        }

        return self.notify.clone();
    }

    pub fn ack(self: *@This()) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.info("X86Irq.ack", .{});

        const handler = self.handler orelse {
            return Error.IrqNotReady;
        };

        if (!handler.locals.ack(handler.vector)) {
            return Error.IrqNotReady;
        }
    }
};

//

// 0=free 1=used
const port_bitmap_len = 0x300 / 8;
var port_bitmap: [port_bitmap_len]std.atomic.Value(u8) = b: {
    var bitmap: [port_bitmap_len]std.atomic.Value(u8) = .{std.atomic.Value(u8).init(0xFF)} ** port_bitmap_len;

    // https://wiki.osdev.org/I/O_Ports

    // the PIT
    for (0x0040..0x0048) |port|
        freePort(&bitmap, @truncate(port)) catch unreachable;
    // PS/2 controller
    for (0x0060..0x0065) |port|
        freePort(&bitmap, @truncate(port)) catch unreachable;
    // CMOS and RTC registers
    for (0x0070..0x0072) |port|
        freePort(&bitmap, @truncate(port)) catch unreachable;
    // second serial port
    for (0x02F8..0x0300) |port|
        freePort(&bitmap, @truncate(port)) catch unreachable;

    break :b bitmap;
};

const irq_bitmap_len = 0x100 / 8;
var irq_bitmap: [irq_bitmap_len]std.atomic.Value(u8) = b: {
    var bitmap: [irq_bitmap_len]std.atomic.Value(u8) = .{std.atomic.Value(u8).init(0xFF)} ** irq_bitmap_len;

    for (0..apic.IRQ_AVAIL_COUNT + 1) |i|
        freeIrq(&bitmap, @truncate(i)) catch unreachable;

    break :b bitmap;
};

fn allocPort(bitmap: *[port_bitmap_len]std.atomic.Value(u8), port: u16) Error!void {
    if (port >= 0x300)
        return Error.AlreadyMapped;
    const byte = &bitmap[port / 8];
    if (byte.bitSet(@truncate(port % 8), .acquire) == 1)
        return Error.AlreadyMapped;
}

fn freePort(bitmap: *[port_bitmap_len]std.atomic.Value(u8), port: u16) Error!void {
    if (port >= 0x300)
        return Error.NotMapped;
    const byte = &bitmap[port / 8];
    if (byte.bitReset(@truncate(port % 8), .release) == 0)
        return Error.NotMapped;
}

fn allocIrq(bitmap: *[irq_bitmap_len]std.atomic.Value(u8), irq: u8) Error!void {
    const byte = &bitmap[irq / 8];
    if (byte.bitSet(@truncate(irq % 8), .acquire) == 1)
        return Error.AlreadyMapped;
}

fn freeIrq(bitmap: *[irq_bitmap_len]std.atomic.Value(u8), irq: u8) Error!void {
    const byte = &bitmap[irq / 8];
    if (byte.bitReset(@truncate(irq % 8), .release) == 0)
        return Error.NotMapped;
}
