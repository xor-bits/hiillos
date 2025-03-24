const std = @import("std");
const abi = @import("abi");

const arch = @import("arch.zig");
const addr = @import("addr.zig");

const log = std.log.scoped(.caps);

//

// just x86_64 rn
pub const Entry = packed struct {
    present: u1 = 0,
    writable: u1 = 0,
    user_accessible: u1 = 0,
    write_through: u1 = 0,
    cache_disable: u1 = 0,
    accessed: u1 = 0,
    dirty: u1 = 0,
    // page_attribute_table: u1 = 0,
    huge_page: u1 = 0,
    global: u1 = 0,

    // more custom bits
    _free_to_use1: u3 = 0,

    page_index: u32 = 0,
    reserved: u8 = 0,

    // custom bits
    _free_to_use0: u7 = 0,

    protection_key: u4 = 0,
    no_execute: u1 = 0,

    pub fn fromParts(rights: abi.sys.Rights, frame: addr.Phys, flags: abi.sys.MapFlags) Entry {
        std.debug.assert(frame.toParts().reserved0 == 0);
        std.debug.assert(frame.toParts().reserved1 == 0);

        return Entry{
            .present = 1,
            .writable = @intFromBool(rights.writable),
            .user_accessible = 1,
            .write_through = @intFromBool(flags.write_through),
            .cache_disable = @intFromBool(flags.cache_disable),
            .huge_page = @intFromBool(flags.huge_page),
            .global = @intFromBool(flags.global),
            .page_index = frame.toParts().page,
            .protection_key = @truncate(flags.protection_key),
            .no_execute = @intFromBool(!rights.executable),
        };
    }
};

// kernel objects \/

/// forms a tree of capabilities
pub const Capabilities = struct {
    // N capabilities based on how many can fit in a page
    caps: [0x1000 / @sizeOf(Object)]Object,
};

pub const BootInfo = struct {};

/// raw physical memory that can be used to allocate
/// things like more `CapabilityNode`s or things
pub const Memory = struct {
    pub fn call(
        _: addr.Phys,
        thread: *Thread,
        args: abi.sys.Args,
    ) abi.sys.Error!void {
        @import("init.zig").alloc();
    }
};

/// thread information
pub const Thread = struct {
    trap: arch.SyscallRegs = .{},
    caps: Ref(Capabilities),
    vmem: Ref(PageTableLevel4),
    priority: u2 = 1,
};

fn nextLevel(current: *[512]Entry, i: u9) !addr.Phys {
    if (current[i].present == 0) return error.Level4EntryNotPresent;
    if (current[i].huge_page == 1) return error.Level4EntryIsHuge;
    return addr.Phys.fromParts(.{ .page = current[i].page_index });
}

pub fn init() !void {
    debug_type(Object);
    debug_type(Capabilities);
    std.log.info("Capabilities: len={}", .{@as(Capabilities, undefined).caps.len});
    debug_type(Thread);
    debug_type(Frame);

    const cr3 = arch.Cr3.read();
    const level4 = addr.Phys.fromInt(cr3.pml4_phys_base << 12)
        .toHhdm().toPtr(*PageTableLevel4);
    std.mem.copyForwards(Entry, kernel_table[0..], level4.entries[256..]);
}

var kernel_table: [256]Entry = undefined;

/// a `Thread` points to this
pub const PageTableLevel4 = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn init(self: *@This()) void {
        std.mem.copyForwards(Entry, self.entries[256..], kernel_table[0..]);
    }

    // pub fn call(self: *@This(), arg0: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) abi.sys.Error!void {
    //     const id = std.meta.intToEnum(abi.sys.IdPageMap, arg0) catch {
    //         log.warn("invalid PageTableLevel4 call: {x}", .{arg0});
    //         return abi.sys.Error.InvalidArgument;
    //     };

    //     const capability = ;

    //     const vaddr = addr.Virt.fromInt(arg2);
    //     const rights = @as(abi.sys.Rights, @bitCast(arg3));
    //     const flags = @as(abi.sys.MapFlags, @bitCast(arg4));

    //     Entry.fromParts(rights, frame: addr.Phys, flags);

    //     switch (id) {
    //         .map => {},
    //         .unmap => {},
    //     }
    // }

    pub fn map(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        self.entries[vaddr.toParts().level4] = Entry.fromParts(rights, paddr, flags);
    }

    pub fn map_level3(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        try self.map(paddr, vaddr, rights, flags);
    }

    pub fn map_level2(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*PageTableLevel3);
        try next.map_level2(paddr, vaddr, rights, flags);
    }

    pub fn map_level1(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*PageTableLevel3);
        try next.map_level1(paddr, vaddr, rights, flags);
    }

    pub fn map_giant_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*PageTableLevel3);
        try next.map_giant_frame(paddr, vaddr, rights, flags);
    }

    pub fn map_huge_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*PageTableLevel3);
        try next.map_huge_frame(paddr, vaddr, rights, flags);
    }

    pub fn map_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level4)).toHhdm().toPtr(*PageTableLevel3);
        try next.map_frame(paddr, vaddr, rights, flags);
    }
};
/// a `PageTableLevel4` points to multiple of these
pub const PageTableLevel3 = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn call(
        paddr: addr.Phys,
        thread: *Thread,
        args: abi.sys.Args,
    ) abi.sys.Error!void {
        const id = std.meta.intToEnum(abi.sys.IdPageMap, args.arg0) catch {
            log.warn("invalid PageTableLevel4 call: {x}", .{args.arg0});
            return abi.sys.Error.InvalidArgument;
        };

        const caps = &thread.caps.ptr().caps;
        if (args.arg1 >= caps.len) return abi.sys.Error.NotFound;

        if (caps[args.arg1].type != .page_table_level_4) return abi.sys.Error.InvalidType;
        const vmem = caps[args.arg1].paddr.toHhdm().toPtr(*PageTableLevel4);

        // const capability = arg1;

        const vaddr = addr.Virt.fromInt(args.arg2);
        const rights = @as(abi.sys.Rights, @bitCast(@as(u24, @truncate(args.arg3))));
        const flags = @as(abi.sys.MapFlags, @bitCast(@as(u40, @truncate(args.arg4))));

        try vmem.map_level3(paddr, vaddr, rights, flags);

        // Entry.fromParts(rights, frame: addr.Phys, flags);

        switch (id) {
            .map => {},
            .unmap => {},
        }
    }

    pub fn map(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) void {
        self.entries[vaddr.toParts().level3] = Entry.fromParts(rights, paddr, flags);
    }

    pub fn map_level2(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        self.map(paddr, vaddr, rights, flags);
    }

    pub fn map_level1(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*PageTableLevel2);
        try next.map_level1(paddr, vaddr, rights, flags);
    }

    pub fn map_giant_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        self.map(paddr, vaddr, rights, flags);
    }

    pub fn map_huge_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*PageTableLevel2);
        try next.map_huge_frame(paddr, vaddr, rights, flags);
    }

    pub fn map_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level3)).toHhdm().toPtr(*PageTableLevel2);
        try next.map_frame(paddr, vaddr, rights, flags);
    }
};
/// a `PageTableLevel3` points to multiple of these
pub const PageTableLevel2 = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn map(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) void {
        self.entries[vaddr.toParts().level2] = Entry.fromParts(rights, paddr, flags);
    }

    pub fn map_level1(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        self.map(paddr, vaddr, rights, flags);
    }

    pub fn map_huge_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        self.map(paddr, vaddr, rights, flags);
    }

    pub fn map_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        const next = (try nextLevel(&self.entries, vaddr.toParts().level2)).toHhdm().toPtr(*PageTableLevel1);
        try next.map_frame(paddr, vaddr, rights, flags);
    }
};
/// a `PageTableLevel2` points to multiple of these
pub const PageTableLevel1 = struct {
    entries: [512]Entry align(0x1000) = std.mem.zeroes([512]Entry),

    pub fn map(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) void {
        self.entries[vaddr.toParts().level1] = Entry.fromParts(rights, paddr, flags);
    }

    pub fn map_frame(self: *@This(), paddr: addr.Phys, vaddr: addr.Virt, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
        self.map(paddr, vaddr, rights, flags);
    }
};
/// a `PageTableLevel1` points to multiple of these
///
/// raw physical memory again, but now mappable
/// (and can't be used to allocate things)
pub const Frame = struct {
    data: [512]u64 align(0x1000) = std.mem.zeroes([512]u64),
};

pub fn Ref(comptime T: type) type {
    return struct {
        paddr: addr.Phys,

        const Self = @This();

        pub fn alloc() !Self {
            std.debug.assert(std.mem.isAligned(0x1000, @alignOf(T)));

            const paddr = try @import("init.zig").alloc(try std.math.divCeil(usize, @sizeOf(T), 0x1000));
            return Self{ .paddr = paddr };
        }

        pub fn ptr(self: @This()) *T {
            // recursive mapping instead of HHDM later (maybe)
            return self.paddr.toHhdm().toPtr(*T);
        }

        pub fn object(self: @This()) Object {
            var ty: ObjectType = undefined;
            switch (T) {
                Capabilities => ty = .capabilities,
                BootInfo => ty = .boot_info,
                Memory => ty = .memory,
                Thread => ty = .thread,
                PageTableLevel4 => ty = .page_table_level_4,
                PageTableLevel3 => ty = .page_table_level_3,
                PageTableLevel2 => ty = .page_table_level_2,
                PageTableLevel1 => ty = .page_table_level_1,
                Frame => ty = .frame,
                else => @compileError(std.fmt.comptimePrint("invalid Capability type: {}", .{@typeName(T)})),
            }

            return Object{
                .paddr = self.paddr,
                .type = ty,
            };
        }
    };
}

pub const Object = struct {
    paddr: addr.Phys = .{ .raw = 0 },
    type: ObjectType = .null,

    pub fn call(
        self: *@This(),
        thread: *Thread,
        args: abi.sys.Args,
    ) abi.sys.Error!void {
        switch (self.type) {
            .capabilities => {},
            .boot_info => {},
            .memory => {
                try Memory.call(
                    self.paddr,
                    thread,
                    args,
                );
            },
            .thread => {},
            .page_table_level_4 => {},
            .page_table_level_3 => {
                try PageTableLevel3.call(
                    self.paddr,
                    thread,
                    args,
                );
            },
            .page_table_level_2 => {},
            .page_table_level_1 => {},
            .frame => {},
            .null => {},
        }
    }
};

pub const ObjectType = enum {
    capabilities,
    boot_info,
    memory,
    thread,
    page_table_level_4,
    page_table_level_3,
    page_table_level_2,
    page_table_level_1,
    frame,
    null,
};

fn debug_type(comptime T: type) void {
    std.log.info("{s}: size={} align={}", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
}
