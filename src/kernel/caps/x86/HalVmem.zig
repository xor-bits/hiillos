const abi = @import("abi");
const std = @import("std");

const addr = @import("../../addr.zig");
const arch = @import("../../arch.zig");
const caps = @import("../../caps.zig");
const lock = @import("../../lock.zig");
const main = @import("../../main.zig");
const pmem = @import("../../pmem.zig");

const Error = abi.sys.Error;
const conf = abi.conf;
const log = std.log.scoped(.x86halvmem);

const HalVmem = @This();

//

pml4: addr.Phys = .{ .raw = 0 },
active_pcids: []PcidEntry,

pub const PcidEntry = packed struct {
    pcid: u12 = 0,
    is_null: bool = true,

    pub fn write(self: *@This(), pcid: u12) void {
        self.is_null = false;
        self.pcid = pcid;
    }

    pub fn read(self: *@This()) ?u12 {
        return if (self.is_null)
            null
        else
            self.pcid;
    }
};

comptime {
    std.debug.assert(@sizeOf(PcidEntry) == 2);
}

// assumes that old HalVmems might have had the same CR3 physical pages,
// but the current HalVmem with it either has an outdated pcid (cr3 phys page mismatch)
// or the pcid is up to date (cr3 phys page match + pcid match)
//
// if the same cr3 is allocated, the specific PCID will be null
pub const PcidLru = struct {
    lock: lock.TrackingSpinMutex = .{},
    lru: abi.IdLru(u12, 0x1000),
    cur_or_prev_cr3: *[0x1000]u32,

    pub fn init(alloc: std.mem.Allocator) !@This() {
        return .{
            .lru = try .init(alloc),
            .cur_or_prev_cr3 = try alloc.create([0x1000]u32),
        };
    }

    pub fn update(self: *@This(), entry: *PcidEntry, for_cr3: u32) u12 {
        self.lock.lock();
        defer self.lock.unlock();

        const pcid = entry.read() orelse {
            @branchHint(.cold);

            // this CPU has never used this HalVmem yet
            const pcid = self.lru.allocate();
            entry.write(pcid);
            arch.x86_64.flushTlbPcid(pcid);
            self.cur_or_prev_cr3[pcid] = for_cr3;
            return pcid;
        };

        if (self.cur_or_prev_cr3[pcid] != for_cr3) {
            @branchHint(.cold);

            // this CPU has reused the PCID for something else
            self.lru.update(pcid);
            arch.x86_64.flushTlbPcid(pcid);
            self.cur_or_prev_cr3[pcid] = for_cr3;
            return pcid;
        }

        // CR3 could match only if it is the old correct PCID OR
        // if the HalVmem is newly allocated and happens to have reused the same CR3
        // BUT if the HalVmem was newly allocated, the PCID would have been null
        return pcid;
    }
};

//

pub fn init_global() !void {
    const cr3 = arch.x86_64.Cr3.read();
    const level4: *volatile PageTable = @ptrFromInt(addr.physPageToVirt(cr3.pml4_phys_base));

    for (256..512) |i| {
        try deepClone(level4.entries[i], &kernel_table.entries[i], 4);
    }

    readonly_zero_huge_page_table = try allocTable();
    readonly_zero_giant_page_table = try allocTable();

    const fake_huge_page_table = readonly_zero_huge_page_table
        .toHhdm().toPtr(*volatile PageTable);
    const fake_giant_page_table = readonly_zero_giant_page_table
        .toHhdm().toPtr(*volatile PageTable);
    const fake_table_flags: abi.sys.MapFlags = .{
        .user = true,
        .read = true,
        .write = false,
        .exec = true,
    };
    @memset(&fake_huge_page_table.entries, Entry.fromParts(
        true,
        false,
        caps.readonly_zero_page,
        fake_table_flags,
    ));
    @memset(&fake_giant_page_table.entries, Entry.fromParts(
        true,
        false,
        readonly_zero_huge_page_table,
        fake_table_flags,
    ));
}

/// create a deep copy of the higher half mappings
/// NOTE: does not copy any target pages
fn deepClone(from: Entry, to: *volatile Entry, comptime level: u8) !void {
    if (!from.present) return;

    var tmp: Entry = undefined;

    if (level != 1 and !from.huge_page_or_pat) {
        // a table, not a 4kib frame, 2mib frame, 1gib frame nor a 512gib frame

        const to_addr = try allocTable();
        const from_addr = from.getAddr(false);
        const to_table = to_addr.toHhdm().toPtr(*volatile [512]Entry);
        const from_table = from_addr.toHhdm().toPtr(*const volatile [512]Entry);

        for (0..512) |i| {
            try deepClone(from_table[i], &to_table[i], level - 1);
        }

        tmp = Entry.fromParts(
            false,
            false,
            to_addr,
            from.getFlags(false),
        );
    } else if (level == 1) {
        // last level, 4kib frame

        tmp = Entry.fromParts(
            false,
            true,
            from.getAddr(true),
            from.getFlags(true),
        );
        tmp.global = true;
    } else {
        // some higher size page

        tmp = Entry.fromParts(
            true,
            false,
            from.getAddr(true),
            from.getFlags(false),
        );
        tmp.global = true;
    }

    to.* = tmp;
}

pub fn init() !@This() {
    const active_pcids = try caps.slab_allocator.allocator().alloc(PcidEntry, arch.cpuCount());
    const self: @This() = .{
        .pml4 = try allocTable(),
        .active_pcids = active_pcids,
    };

    const lvl4 = self.pml4.toHhdm().toPtr(*volatile PageTable);
    abi.util.fillVolatile(Entry, lvl4.entries[0..256], .{});
    abi.util.copyForwardsVolatile(Entry, lvl4.entries[256..], kernel_table.entries[256..]);

    caps.incCount(.hal_vmem, .{});
    if (conf.LOG_CTX_SWITCHES)
        log.debug("new context 0x{x}", .{self.pml4.raw});

    return self;
}

pub fn deinit(_: *const HalVmem) void {
    caps.decCount(.hal_vmem);
}

pub fn switchTo(self: *@This()) void {
    const cpu_local = arch.cpuLocal();
    const pml4_phys_base = self.pml4.parts.page;

    const new_cr3: arch.x86_64.Cr3 = if (cpu_local.pcid_lru) |*pcid_lru| b: {
        const pcid = pcid_lru.update(&self.active_pcids[cpu_local.id], pml4_phys_base);
        break :b .{
            .pml4_phys_base = pml4_phys_base,
            .pcid = pcid,
        };
    } else b: {
        break :b .{
            .pml4_phys_base = pml4_phys_base,
        };
    };

    if (conf.IS_DEBUG) {
        // switching to the same address space should be avoided by
        // the higher level of abstraction (`Vmem.switchTo`)
        const cur_cr3 = arch.x86_64.Cr3.read();
        std.debug.assert(cur_cr3 != new_cr3);
    }

    new_cr3.write();
    if (conf.LOG_CTX_SWITCHES)
        log.debug("context switched to 0x{x}", .{self.pml4.raw});
}

pub fn printMappings(self: *@This()) !void {
    // go through every single page in this address space,
    // and print contiguous similar chunks.

    var it = self.mappings(true);
    while (try it.next()) |mapping| {
        log.info(" - {f}", .{mapping});
    }
}

pub fn mappings(self: *@This(), include_kernel: bool) MappingIterator {
    return .{
        .vmem = self,
        .include_kernel = include_kernel,
    };
}

pub const GetResult = struct {
    start_vaddr: addr.Virt,
    start_paddr: addr.Phys,
    size: abi.ChunkSize,
    flags: abi.sys.MapFlags,
};

pub fn get(
    self: *volatile @This(),
    /// virtual address anywhere within a page
    vaddr: addr.Virt,
) ?GetResult {
    const levels = vaddr.parts.page.levels;
    const pml4: *volatile PageTable = @ptrFromInt(self.pml4.toHhdm().raw);
    var start_vaddr: addr.Virt = .{ .raw = 0 };

    const pml3 = pml4.get(.level4, levels.level4) orelse
        return null;
    start_vaddr.parts.page.levels.level4 = levels.level4;
    switch (pml3) {
        .frame => unreachable,
        .next => {},
    }

    const pml2 = pml3.next.get(.level3, levels.level3) orelse
        return null;
    start_vaddr.parts.page.levels.level3 = levels.level3;
    switch (pml2) {
        .frame => |frame| return .{
            .start_vaddr = start_vaddr,
            .start_paddr = frame.paddr,
            .size = .@"1GiB",
            .flags = frame.flags,
        },
        .next => {},
    }

    const pml1 = pml2.next.get(.level2, levels.level2) orelse
        return null;
    start_vaddr.parts.page.levels.level2 = levels.level2;
    switch (pml1) {
        .frame => |frame| return .{
            .start_vaddr = start_vaddr,
            .start_paddr = frame.paddr,
            .size = .@"2MiB",
            .flags = frame.flags,
        },
        .next => {},
    }

    const page = pml1.next.get(.level1, levels.level1) orelse
        return null;
    start_vaddr.parts.page.levels.level1 = levels.level1;
    switch (page) {
        .frame => |frame| return .{
            .start_vaddr = start_vaddr,
            .start_paddr = frame.paddr,
            .size = .@"4KiB",
            .flags = frame.flags,
        },
        .next => unreachable,
    }
}

pub fn insert(
    self: *volatile @This(),
    vaddr: addr.Virt,
    /// has to be aligned to `page_size`,
    /// null means readonly zero pages
    paddr: ?addr.Phys,
    page_size: abi.ChunkSize,
    flags: abi.sys.MapFlags,
) Error!void {
    if (conf.LOG_HAL_VMEM) {
        log.debug("insert HalVmem mapping 0x{x} {t}", .{ vaddr.raw, page_size });
    }

    const levels = vaddr.parts.page.levels;
    const pml4: *volatile PageTable = @ptrFromInt(self.pml4.toHhdm().raw);

    const pml3 = try pml4.getOrCreateTable(
        .level4,
        levels.level4,
    );

    if (page_size == .@"1GiB") {
        pml3.insert(
            .level3,
            levels.level3,
            paddr,
            flags,
        );
        return;
    }

    const pml2 = try pml3.getOrCreateTable(
        .level3,
        levels.level3,
    );

    if (page_size == .@"2MiB") {
        pml2.insert(
            .level2,
            levels.level2,
            paddr,
            flags,
        );
        return;
    }

    const pml1 = try pml2.getOrCreateTable(
        .level2,
        levels.level2,
    );

    std.debug.assert(page_size == .@"4KiB");
    pml1.insert(
        .level1,
        levels.level1,
        paddr,
        flags,
    );
}

/// disables a mapping but does not deallocate it yet,
/// flushes local TLB but does not do remote TLB flushes
pub fn disable(
    self: *volatile @This(),
    page_size: abi.ChunkSize,
    vaddr: addr.Virt,
) void {
    if (conf.LOG_HAL_VMEM) {
        log.debug("disable HalVmem mapping 0x{x} {t}", .{ vaddr.raw, page_size });
    }

    const levels = vaddr.parts.page.levels;
    const pml4: *volatile PageTable = @ptrFromInt(self.pml4.toHhdm().raw);

    const pml3 = pml4.get(.level4, levels.level4) orelse
        return;
    std.debug.assert(pml3 != .frame);

    const pml2 = pml3.next.get(.level3, levels.level3) orelse
        return;
    if (page_size == .@"1GiB") {
        pml3.next.entries[levels.level3].present = false;
        flushOne(.level3, vaddr, pml2);
        return;
    }
    std.debug.assert(pml2 != .frame);

    const pml1 = pml2.next.get(.level2, levels.level2) orelse
        return;
    if (page_size == .@"2MiB") {
        pml2.next.entries[levels.level2].present = false;
        flushOne(.level2, vaddr, pml1);
        return;
    }
    std.debug.assert(pml1 != .frame);

    const frame = pml1.next.get(.level1, levels.level1) orelse
        return;
    std.debug.assert(page_size == .@"4KiB");
    std.debug.assert(frame == .frame);
    pml1.next.entries[levels.level1].present = false;
    flushOne(.level1, vaddr, frame);
}

/// flushes local TLB but does not do remote TLB flushes
pub fn flushLocalTlb(
    self: *volatile @This(),
    page_size: abi.ChunkSize,
    vaddr: addr.Virt,
) void {
    if (conf.LOG_HAL_VMEM) {
        log.debug("flushLocalTlb HalVmem 0x{x} {t}", .{ vaddr.raw, page_size });
    }

    const levels = vaddr.parts.page.levels;
    const pml4: *volatile PageTable = @ptrFromInt(self.pml4.toHhdm().raw);

    const pml3 = pml4.get(.level4, levels.level4) orelse
        return;
    std.debug.assert(pml3 != .frame);

    const pml2 = pml3.next.get(.level3, levels.level3) orelse
        return;
    if (page_size == .@"1GiB") {
        flushOne(.level3, vaddr, pml2);
        return;
    }
    std.debug.assert(pml2 != .frame);

    const pml1 = pml2.next.get(.level2, levels.level2) orelse
        return;
    if (page_size == .@"2MiB") {
        flushOne(.level2, vaddr, pml1);
        return;
    }
    std.debug.assert(pml1 != .frame);

    const frame = pml1.next.get(.level1, levels.level1) orelse
        return;
    std.debug.assert(page_size == .@"4KiB");
    std.debug.assert(frame == .frame);
    flushOne(.level1, vaddr, frame);
}

fn flushOne(
    comptime level: Level,
    vaddr_unaligned: addr.Virt,
    result: PageTable.PageTableGetResult,
) void {
    const chunk_size = level.pageSize();
    const vaddr_aligned = vaddr_unaligned.alignBackward(chunk_size.sizeBytes());
    if (level != .level1 and result == .next) {
        // readonly zero pages mapped as a 1GiB/2MiB/4KiB page
        for (0..chunk_size.sizePages()) |i| {
            arch.x86_64.flushTlbAddr(vaddr_aligned.add(0x1000 * i).raw);
        }
        // flush everything instead
        // arch.x86_64.flushTlb();
    } else {
        // a normal giant page
        arch.x86_64.flushTlbAddr(vaddr_aligned.raw);
    }
}

/// deallocates a disabled mapping and empty tables
/// the mapping is assumed to have been disabled first
pub fn remove(
    self: *volatile @This(),
    page_size: abi.ChunkSize,
    vaddr: addr.Virt,
) void {
    if (conf.LOG_HAL_VMEM) {
        log.debug("remove HalVmem mapping 0x{x} {t}", .{ vaddr.raw, page_size });
    }

    const levels = vaddr.parts.page.levels;
    const pml4: *volatile PageTable = @ptrFromInt(self.pml4.toHhdm().raw);

    const pml3 = pml4.get(.level4, levels.level4) orelse
        return;
    std.debug.assert(pml3 != .frame);
    // FIXME: deallocating tables safely is really complicated while
    // avoiding allocations during page faults or unmaps
    // defer pml4.deleteTableIfEmpty(levels.level4);

    const pml2 = pml3.next.get(.level3, levels.level3) orelse
        return;
    if (page_size == .@"1GiB") {
        // if it points to a real allocated page => deallocation is managed externally
        // if it points to the readonly giant table => it is never deallocated
        pml3.next.entries[levels.level3] = .{};
        return;
    }
    // defer pml3.next.deleteTableIfEmpty(levels.level3);
    std.debug.assert(pml2 != .frame);

    const pml1 = pml2.next.get(.level2, levels.level2) orelse
        return;
    // defer pml2.next.deleteTableIfEmpty(levels.level2);
    if (page_size == .@"2MiB") {
        // if it points to a real allocated page => deallocation is managed externally
        // if it points to the readonly huge table => it is never deallocated
        pml2.next.entries[levels.level2] = .{};
        return;
    }
    std.debug.assert(pml1 != .frame);

    const frame = pml1.next.get(.level1, levels.level1) orelse
        return;
    // defer pml1.next.deleteTableIfEmpty(levels.level1);
    std.debug.assert(page_size == .@"4KiB");
    std.debug.assert(frame == .frame);
    // if it points to a real allocated page => deallocation is managed externally
    // if it points to the readonly page => it is never deallocated
    pml1.next.entries[levels.level1] = .{};
}

pub const Level = enum {
    level4,
    level3,
    level2,
    level1,

    const Self = @This();

    pub fn readIndex(
        self: Self,
        vaddr: addr.Virt,
    ) u9 {
        switch (self) {
            inline else => |field_name| return @field(
                vaddr,
                @tagName(field_name),
            ),
        }
    }

    pub fn deeper(
        self: Self,
    ) ?Self {
        if (self == .level1) return null;
        return @enumFromInt(@intFromEnum(self) + 1);
    }

    pub fn pageSize(
        self: Self,
    ) abi.ChunkSize {
        return switch (self) {
            .level4 => unreachable,
            .level3 => .@"1GiB",
            .level2 => .@"2MiB",
            .level1 => .@"4KiB",
        };
    }

    pub fn readonlyPage(
        self: Self,
    ) addr.Phys {
        return switch (self) {
            .level4 => unreachable,
            .level3 => readonly_zero_giant_page_table,
            .level2 => readonly_zero_huge_page_table,
            .level1 => caps.readonly_zero_page,
        };
    }
};

pub const PageTable = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub const PageTableGetResult = union(enum) {
        frame: struct {
            paddr: addr.Phys,
            flags: abi.sys.MapFlags,
        },
        next: *volatile PageTable,
    };

    // const FreeToUse0 = packed struct(u10) {
    //     _free_to_use1: u3,
    //     _free_to_use0: u7,
    // };

    // /// returns the old count
    // pub fn fetchIncUsedEntryCount(
    //     self: *volatile @This(),
    // ) u10 {
    //     var entry = self.entries[0];
    //     const count: u10 = @bitCast(FreeToUse0{
    //         ._free_to_use1 = entry._free_to_use1,
    //         ._free_to_use0 = entry._free_to_use0,
    //     });
    //     std.debug.assert(count != 512);
    //     const new_bits: FreeToUse0 = @bitCast(count + 1);
    //     entry._free_to_use1 = new_bits._free_to_use1;
    //     entry._free_to_use0 = new_bits._free_to_use0;
    //     // FIXME: dirty and accessed bits might be lost here
    //     // but those are not yet used in hiillos
    //     self.entries[0] = entry;
    //     return count;
    // }

    // /// returns the old count
    // pub fn fetchDecUsedEntryCount(
    //     self: *volatile @This(),
    // ) u10 {
    //     var entry = self.entries[0];
    //     const count: u10 = @bitCast(FreeToUse0{
    //         ._free_to_use1 = entry._free_to_use1,
    //         ._free_to_use0 = entry._free_to_use0,
    //     });
    //     std.debug.assert(count != 0);
    //     const new_bits: FreeToUse0 = @bitCast(count - 1);
    //     entry._free_to_use1 = new_bits._free_to_use1;
    //     entry._free_to_use0 = new_bits._free_to_use0;
    //     // FIXME: dirty and accessed bits might be lost here
    //     // but those are not yet used in hiillos
    //     self.entries[0] = entry;
    //     return count;
    // }

    pub fn getOrCreateTable(
        self: *volatile @This(),
        comptime level: Level,
        i: u9,
    ) Error!*volatile PageTable {
        std.debug.assert(level != .level1);

        const result = self.get(level, i);
        if (result != null) switch (result.?) {
            .frame => unreachable,
            .next => |t| return t,
        };
        return try self.insertTable(i);
    }

    pub fn nextNextTableOrTryMap(
        self: *volatile @This(),
        comptime level: Level,
        i: u9,
        can_map: bool,
        paddr: addr.Phys,
        flags: abi.sys.MapFlags,
    ) Error!?*volatile PageTable {
        const get_result = self.get(level, i) orelse {
            if (can_map) {
                self.insert(
                    level,
                    i,
                    paddr.alignBackward(level.pageSize().?.sizeBytes()),
                    flags,
                );
                return null;
            }

            return try self.insertTable(i);
        };

        // assumed to be already checked to be unmapped
        std.debug.assert(get_result != .frame);
        return get_result.next;
    }

    pub fn get(
        self: *volatile @This(),
        comptime level: Level,
        i: u9,
    ) ?PageTableGetResult {
        const entry = self.entries[i];

        if (!entry.actually_present) {
            return null;
        } else if (level != .level1 and entry.huge_page_or_pat) {
            // huge pages carry one of the PAT bits in the LSB
            const page = entry.page_index & ~@as(u32, 1);
            return .{ .frame = .{
                .paddr = .{ .parts = .{ .page = page } },
                .flags = entry.getFlags(false),
            } };
        } else if (level != .level1) {
            const page = entry.page_index;
            return .{ .next = @ptrFromInt(addr.physPageToVirt(page)) };
        } else {
            const page = entry.page_index;
            return .{ .frame = .{
                .paddr = .{ .parts = .{ .page = page } },
                .flags = entry.getFlags(true),
            } };
        }
    }

    pub fn insertTable(
        self: *volatile @This(),
        i: u9,
    ) Error!*volatile PageTable {
        if (conf.IS_DEBUG) {
            const entry = self.entries[i];
            std.debug.assert(!entry.actually_present);
            std.debug.assert(!entry.present);
        }

        const table = try allocTable();
        self.entries[i] = Entry.fromParts(
            false,
            false,
            table,
            .{ .write = true, .exec = true },
        );
        // _ = self.fetchIncUsedEntryCount();
        return @ptrFromInt(table.toHhdm().raw);
    }

    pub fn deleteTableIfEmpty(
        self: *volatile @This(),
        i: u9,
    ) void {
        const entry = self.entries[i];
        std.debug.assert(entry.actually_present);
        std.debug.assert(!entry.huge_page_or_pat);

        const next: *volatile @This() = @ptrFromInt(addr.physPageToVirt(entry.page_index));

        for (next.entries) |sub_entry| {
            if (sub_entry.actually_present) return;
        }

        // the entry was already marked not present,
        // other CPUs were notified and they acknowledged,
        // and relevant TLB entries from all CPUs were flushed
        freeTable(.{ .parts = .{
            .page = entry.page_index,
        } });
        self.entries[i] = .{};
    }

    pub fn insert(
        self: *volatile @This(),
        comptime level: Level,
        i: u9,
        paddr_opt: ?addr.Phys,
        flags: abi.sys.MapFlags,
    ) void {
        const paddr_readonly = level.readonlyPage();
        const page_size_bytes = level.pageSize().sizeBytes();
        const entry = self.entries[i];
        if (paddr_opt) |paddr| {
            if (conf.IS_DEBUG) {
                std.debug.assert(!entry.actually_present or
                    entry.page_index == paddr_readonly.parts.page);
            }

            std.debug.assert(paddr.isAligned(page_size_bytes));
            self.entries[i] = Entry.fromParts(
                true,
                level == .level1,
                paddr,
                flags,
            );
        } else {
            if (conf.IS_DEBUG) {
                std.debug.assert(!entry.actually_present);
            }

            // the mapped *thing* might be a shared table
            self.entries[i] = Entry.fromParts(
                false,
                level == .level1,
                paddr_readonly,
                flags,
            );
        }
        // _ = self.fetchIncUsedEntryCount();
    }

    pub fn disableRecurse(
        self: *volatile @This(),
        comptime level: Level,
        i: u9,
    ) void {
        const result = self.get(level, i) orelse
            return;
        switch (result) {
            .next => |next| {
                const next_level = (comptime level.deeper()) orelse
                    comptime unreachable;
                for (0..512) |j| {
                    next.disableRecurse(next_level, @intCast(j));
                }
            },
            .frame => self.disable(i),
        }
    }

    pub fn disable(
        self: *volatile @This(),
        i: u9,
    ) void {
        self.entries[i].present = false;
    }

    pub fn remove(
        self: *volatile @This(),
        i: u9,
    ) void {
        self.entries[i] = .{};
    }
};

pub const Entry = packed struct {
    present: bool = false,
    writable: bool = false,
    user_accessible: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    huge_page_or_pat: bool = false,
    global: bool = false,

    /// hardware mapping is marked as not present,
    /// but the entry is kept until no other CPU
    /// might access it or have a stale TLB entry
    actually_present: bool = false,
    // more custom bits
    _free_to_use1: u2 = 0,

    page_index: u32 = 0,
    reserved: u8 = 0,

    // custom bits
    _free_to_use0: u7 = 0,

    protection_key: u4 = 0,
    no_execute: bool = false,

    pub fn getCacheMode(
        self: @This(),
        comptime is_last_level: bool,
    ) abi.sys.CacheType {
        var idx: u3 = 0;
        if (is_last_level)
            idx |= @as(u3, @intFromBool(self.huge_page_or_pat)) << 2
        else
            idx |= @as(u3, @truncate(self.page_index & 0b1)) << 2;
        idx |= @as(u3, @intFromBool(self.cache_disable)) << 1;
        idx |= @as(u3, @intFromBool(self.write_through)) << 0;
        return std.meta.intToEnum(abi.sys.CacheType, idx) catch unreachable;
    }

    pub fn getFlags(
        self: @This(),
        comptime is_last_level: bool,
    ) abi.sys.MapFlags {
        return .{
            .cache = self.getCacheMode(is_last_level),
            .write = self.writable,
            .exec = !self.no_execute,
            .user = self.user_accessible,
        };
    }

    pub fn getAddr(
        self: @This(),
        comptime is_last_level: bool,
    ) addr.Phys {
        const page = if (is_last_level)
            self.page_index
        else if (self.huge_page_or_pat)
            self.page_index & ~@as(u32, 1) // huge pages carry one of the PAT bits in the LSB
        else
            self.page_index;
        return .{ .parts = .{ .page = page } };
    }

    pub fn fromParts(
        comptime is_huge: bool,
        comptime is_last_level: bool,
        frame: addr.Phys,
        flags: abi.sys.MapFlags,
    ) Entry {
        std.debug.assert(frame.parts.reserved0 == 0);
        std.debug.assert(frame.parts.reserved1 == 0);

        var page_index = frame.parts.page;
        var pwt = false;
        var pcd = false;
        var huge_page_or_pat = false;
        const pat_index = @as(u3, @truncate(@intFromEnum(flags.cache)));
        if (is_last_level) {
            if (pat_index & 0b001 != 0) pwt = true;
            if (pat_index & 0b010 != 0) pcd = true;
            if (pat_index & 0b100 != 0) huge_page_or_pat = true;
        } else if (is_huge) {
            if (pat_index & 0b001 != 0) pwt = true;
            if (pat_index & 0b010 != 0) pcd = true;
            if (pat_index & 0b100 != 0) page_index |= 1;
            huge_page_or_pat = true;
        } else {
            // huge on last level is illegal
            // and intermediary tables dont have cache modes (prob)
        }

        return .{
            .present = true,
            .actually_present = true,
            .writable = flags.write,
            .user_accessible = flags.user,
            .write_through = pwt,
            .cache_disable = pcd,
            .huge_page_or_pat = huge_page_or_pat,
            .global = false,
            .page_index = page_index,
            .protection_key = 0,
            .no_execute = !flags.exec,
        };
    }
};

//

var kernel_table: PageTable = .{};
// TODO: make a real 2MiB zero page when there is enough memory
/// the actual readonly zero page is only 4KiB, this is a table
/// that repeats that same 4KiB page 512 times creating a fake huge page
var readonly_zero_huge_page_table: addr.Phys = undefined;
/// the actual readonly zero page is only 4KiB, this is a table
/// that repeats that same 4KiB page 512*512 times creating a fake giant page
var readonly_zero_giant_page_table: addr.Phys = undefined;

var table_pool: std.SinglyLinkedList = .{};
var table_pool_lock: lock.TrackingSpinMutex = .unlocked;

pub const AllocationHeader = struct {
    meta: [255]TableMetadata align(0x1000),
};

pub const TableMetadata = struct {
    node: std.SinglyLinkedList.Node = .{},
    present_entries: usize = 0,

    comptime {
        std.debug.assert(@sizeOf(TableMetadata) <= 16);
    }

    /// this allows a single 1MiB allocation to be split
    /// into 255 4KiB tables and a single 4KiB meta array
    const tables_per_alloc = 255;
    const alloc_size: abi.ChunkSize = .@"1MiB";
};

fn metaFromTable(
    paddr: addr.Phys,
) *TableMetadata {
    const alloc_size = TableMetadata.alloc_size.sizeBytes();

    const table_addr = paddr.toHhdm();
    const header_addr = table_addr.alignBackward(alloc_size);

    const nth_table = @divExact(table_addr.raw - header_addr.raw - 0x1000, 0x1000);

    const header = header_addr.toPtr(*AllocationHeader);
    return &header.meta[nth_table];
}

fn tableFromMeta(
    meta: *TableMetadata,
) addr.Phys {
    const alloc_size = TableMetadata.alloc_size.sizeBytes();

    const meta_addr = addr.Virt.fromPtr(meta);
    const header_addr = meta_addr.alignBackward(alloc_size);

    const nth_table = @divExact(meta_addr.raw - header_addr.raw, @sizeOf(TableMetadata));

    return header_addr.add(0x1000 + nth_table * 0x1000).hhdmToPhys();
}

pub fn allocTable() Error!addr.Phys {
    table_pool_lock.lock();
    defer table_pool_lock.unlock();

    if (table_pool.first == null) {
        const alloc = pmem.allocChunk(.@"1MiB") orelse return Error.OutOfMemory;
        for (0..TableMetadata.tables_per_alloc) |i| {
            const table = alloc.add((i + 1) * 0x1000);
            freeTableLocked(table);
        }
    }

    const node = table_pool.popFirst().?;

    const meta: *TableMetadata = @fieldParentPtr("node", node);
    meta.* = .{};
    return tableFromMeta(meta);
}

pub fn freeTable(paddr: addr.Phys) void {
    table_pool_lock.lock();
    defer table_pool_lock.unlock();
    freeTableLocked(paddr);
}

fn freeTableLocked(paddr: addr.Phys) void {
    std.debug.assert(table_pool_lock.isLockedByMe());

    const table = paddr.toHhdm().toPtr([*]u64);
    std.crypto.secureZero(u64, table[0..512]);
    const meta = metaFromTable(paddr);
    meta.* = .{};
    table_pool.prepend(&meta.node);
}

//

pub const MappingIterator = struct {
    maybe_base: ?Current = null,
    l4: u16 = 0,
    l3: u16 = 0,
    l2: u16 = 0,
    l1: u16 = 0,
    vmem: *HalVmem,
    state: enum {
        l4,
        l3,
        l2,
        l1,
    } = .l4,
    include_kernel: bool = false,

    pub const Mapping = struct {
        from: addr.Virt,
        to: addr.Virt,
        target: addr.Phys,
        size: usize,
        write: bool,
        exec: bool,
        user: bool,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) !void {
            try writer.print("{s}R{s}{s} [ 0x{x:0>16}..0x{x:0>16} ] => 0x{x:0>16} (0x{x}B)", .{
                if (self.user) "U" else "-",
                if (self.write) "W" else "-",
                if (self.exec) "X" else "-",
                self.from.raw,
                self.to.raw,
                self.target.raw,
                self.size,
            });
        }
    };

    const Current = struct {
        base: addr.Virt,
        target: addr.Phys,
        write: bool,
        exec: bool,
        user: bool,

        fn fromEntry(from: addr.Virt, e: GetResult) @This() {
            return .{
                .base = from,
                .target = e.start_paddr,
                .write = e.flags.write,
                .exec = e.flags.exec,
                .user = e.flags.user,
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
    };

    pub fn next(self: *@This()) !?Mapping {
        while (true) {
            if (self.l4 >= self.l4limit()) break;
            if (try self.tryNext()) |mapping| return mapping;
        }

        return missing(&self.maybe_base, .{ .parts = .{
            .page = .{ .levels = .{
                .level4 = if (self.include_kernel) 0 else 256,
            } },
            ._extra = if (self.include_kernel) 1 else 0,
        } });
    }

    fn l4limit(self: *const @This()) u16 {
        return if (self.include_kernel) 512 else 256;
    }

    fn tryNext(self: *@This()) !?Mapping {
        switch (self.state) {
            .l4 => {
                if (self.l4 >= self.l4limit()) {
                    self.l4 = self.l4limit();
                    return null;
                }

                const colossial: addr.Virt = .{ .parts = .{ .page = .{ .levels = .{
                    .level4 = @truncate(self.l4),
                } } } };
                const entry = self.vmem.get(colossial);

                if (entry == null) {
                    self.l4 += 1;
                    return missing(&self.maybe_base, colossial);
                } else {
                    self.state = .l3;
                    return null;
                }
            },
            .l3 => {
                if (self.l3 >= 512) {
                    self.l3 = 0;
                    self.l4 += 1;
                    self.state = .l4;
                    return null;
                }

                const giant: addr.Virt = .{ .parts = .{ .page = .{ .levels = .{
                    .level4 = @truncate(self.l4),
                    .level3 = @truncate(self.l3),
                } } } };
                const entry = self.vmem.get(giant);

                if (entry == null) {
                    self.l3 += 1;
                    return missing(&self.maybe_base, giant);
                } else if (entry.?.size == .@"1GiB") {
                    self.l3 += 1;
                    return present(&self.maybe_base, giant, entry.?);
                } else {
                    self.state = .l2;
                    return null;
                }
            },
            .l2 => {
                if (self.l2 >= 512) {
                    self.l2 = 0;
                    self.l3 += 1;
                    self.state = .l3;
                    return null;
                }

                const huge: addr.Virt = .{ .parts = .{ .page = .{ .levels = .{
                    .level4 = @truncate(self.l4),
                    .level3 = @truncate(self.l3),
                    .level2 = @truncate(self.l2),
                } } } };
                const entry = self.vmem.get(huge);

                if (entry == null) {
                    self.l2 += 1;
                    return missing(&self.maybe_base, huge);
                } else if (entry.?.size == .@"2MiB") {
                    self.l2 += 1;
                    return present(&self.maybe_base, huge, entry.?);
                } else {
                    self.state = .l1;
                    return null;
                }
            },
            .l1 => {
                if (self.l1 >= 512) {
                    self.l1 = 0;
                    self.l2 += 1;
                    self.state = .l2;
                    return null;
                }

                const page: addr.Virt = .{ .parts = .{ .page = .{ .levels = .{
                    .level4 = @truncate(self.l4),
                    .level3 = @truncate(self.l3),
                    .level2 = @truncate(self.l2),
                    .level1 = @truncate(self.l1),
                } } } };
                const entry = self.vmem.get(page);

                if (entry == null) {
                    self.l1 += 1;
                    return missing(&self.maybe_base, page);
                } else {
                    self.l1 += 1;
                    return present(&self.maybe_base, page, entry.?);
                }
            },
        }
    }

    fn missing(maybe_base: *?Current, vaddr: addr.Virt) ?Mapping {
        const base: Current = maybe_base.* orelse {
            return null;
        };

        defer maybe_base.* = null;
        return Mapping{
            .from = base.base,
            .to = vaddr,
            .target = base.target,
            .size = vaddr.raw - base.base.raw,
            .write = base.write,
            .exec = base.exec,
            .user = base.user,
        };
    }

    fn present(maybe_base: *?Current, vaddr: addr.Virt, entry: GetResult) ?Mapping {
        const cur = Current.fromEntry(vaddr, entry);
        const base: Current = maybe_base.* orelse {
            maybe_base.* = cur;
            return null;
        };

        if (!base.isContiguous(cur)) {
            defer maybe_base.* = cur;
            return Mapping{
                .from = base.base,
                .to = vaddr,
                .target = base.target,
                .size = vaddr.raw - base.base.raw,
                .write = base.write,
                .exec = base.exec,
                .user = base.user,
            };
        }

        return null;
    }
};
