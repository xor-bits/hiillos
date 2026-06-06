const std = @import("std");
const abi = @import("abi");

const main = @import("main.zig");
const Error = abi.sys.Error;

//

pub fn physPageToVirt(
    page: usize,
) usize {
    return physAddrToVirt(page * 0x1000);
}

pub fn physAddrToVirt(
    phys: usize,
) usize {
    const hhdm_offset = main.hhdm_offset;
    if (hhdm_offset != 0xFFFF_8000_0000_0000) {
        @branchHint(.cold);
    }

    const result = phys + hhdm_offset;
    std.debug.assert(result < 0x8000_0000_0000 or 0xFFFF_8000_0000_0000 <= result);
    return result;
}

pub fn virtAddrToPhys(
    hhdm: usize,
) usize {
    const hhdm_offset = main.hhdm_offset;
    if (hhdm_offset != 0xFFFF_8000_0000_0000) {
        @branchHint(.cold);
    }

    std.debug.assert(hhdm >= hhdm_offset);
    std.debug.assert(hhdm < 0xFFFF_FFFF_8000_0000);
    return hhdm - hhdm_offset;
}

pub const Phys = packed union {
    raw: usize,
    parts: Parts,

    pub const Self = @This();

    pub const Parts = packed struct {
        offset: u12 = 0,
        page: u32 = 0,
        reserved0: u8 = 0,
        reserved1: u12 = 0,
    };

    pub fn toHhdm(
        self: Self,
    ) Virt {
        return .{ .raw = physAddrToVirt(self.raw) };
    }

    pub fn alignForward(
        self: Self,
        alignment: usize,
    ) Self {
        return .{ .raw = std.mem.alignForward(
            usize,
            self.raw,
            alignment,
        ) };
    }

    pub fn alignBackward(
        self: Self,
        alignment: usize,
    ) Self {
        return .{ .raw = std.mem.alignBackward(
            usize,
            self.raw,
            alignment,
        ) };
    }

    pub fn isAligned(
        self: Self,
        alignment: usize,
    ) bool {
        return std.mem.isAligned(self.raw, alignment);
    }

    pub fn add(
        self: Self,
        offset: usize,
    ) Self {
        return .{ .raw = self.raw + offset };
    }

    pub fn sub(
        self: Self,
        offset: usize,
    ) Self {
        return .{ .raw = self.raw - offset };
    }

    pub fn distance(
        a: Self,
        b: Self,
    ) usize {
        std.debug.assert(b.raw >= a.raw);
        return b.raw - a.raw;
    }

    pub fn isNull(
        self: Self,
    ) bool {
        return self.raw == 0;
    }
};

pub const Virt = packed union {
    raw: usize,
    parts: Parts,

    pub const Self = @This();

    pub const Parts = packed struct(usize) {
        offset: u12 = 0,
        page: packed union {
            index: u36,
            levels: packed struct(u36) {
                level1: u9 = 0,
                level2: u9 = 0,
                level3: u9 = 0,
                level4: u9 = 0,
            },
        } = .{ .index = 0 },
        _extra: u16 = 0,
    };

    pub fn fromUser(
        i: usize,
    ) Error!Self {
        if (i >= 0x8000_0000_0000) {
            return Error.InvalidAddress;
        } else {
            return .{ .raw = i };
        }
    }

    pub fn fromPtr(
        ptr: anytype,
    ) Self {
        return .{ .raw = @intFromPtr(ptr) };
    }

    pub fn toPtr(
        self: Self,
        comptime T: type,
    ) T {
        return @ptrFromInt(self.raw);
    }

    pub fn hhdmToPhys(
        self: Self,
    ) Phys {
        return .{ .raw = virtAddrToPhys(self.raw) };
    }

    pub fn alignForward(
        self: Self,
        alignment: usize,
    ) Self {
        return .{ .raw = std.mem.alignForward(
            usize,
            self.raw,
            alignment,
        ) };
    }

    pub fn alignBackward(
        self: Self,
        alignment: usize,
    ) Self {
        return .{ .raw = std.mem.alignBackward(
            usize,
            self.raw,
            alignment,
        ) };
    }

    pub fn isAligned(
        self: Self,
        alignment: usize,
    ) bool {
        return std.mem.isAligned(self.raw, alignment);
    }

    pub fn add(
        self: Self,
        offset: usize,
    ) Self {
        const result = self.raw + offset;
        std.debug.assert(result < 0x8000_0000_0000 or 0xFFFF_8000_0000_0000 <= result);
        return .{ .raw = result };
    }

    pub fn sub(
        self: Self,
        offset: usize,
    ) Self {
        const result = self.raw - offset;
        std.debug.assert(result < 0x8000_0000_0000 or 0xFFFF_8000_0000_0000 <= result);
        return .{ .raw = result };
    }

    pub fn distance(
        a: Self,
        b: Self,
    ) usize {
        std.debug.assert(b.raw >= a.raw);
        return b.raw - a.raw;
    }

    pub fn distancePages(
        a: Self,
        b: Self,
    ) u32 {
        return @intCast(a.distance(b) / 0x1000);
    }

    pub fn isNull(
        self: Self,
    ) bool {
        return self.raw == 0;
    }
};
