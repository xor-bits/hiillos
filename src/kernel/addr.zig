const std = @import("std");
const abi = @import("abi");

const main = @import("main.zig");
const Error = abi.sys.Error;

//

pub const Phys = struct {
    raw: usize,

    pub const Parts = packed struct {
        offset: u12 = 0,
        page: u32 = 0,
        reserved0: u8 = 0,
        reserved1: u12 = 0,
    };

    pub fn fromInt(i: usize) Phys {
        return Phys{ .raw = i };
    }

    pub fn toHhdm(self: Phys) Virt {
        return Virt{ .raw = self.raw + main.hhdm_offset };
    }

    pub fn fromParts(parts: Parts) Phys {
        return fromInt(@as(usize, @bitCast(parts)));
    }

    pub fn toParts(self: Phys) Parts {
        return @bitCast(self.raw);
    }
};

pub const Virt = struct {
    raw: usize,

    pub const Parts = packed struct {
        offset: u12 = 0,
        level1: u9 = 0,
        level2: u9 = 0,
        level3: u9 = 0,
        level4: u9 = 0,
        _extra: u16 = 0,
    };

    pub fn fromUser(i: u64) Error!Virt {
        if (i >= 0x8000_0000_0000) {
            return Error.InvalidAddress;
        } else {
            return fromInt(i);
        }
    }

    pub fn fromInt(i: usize) Virt {
        return Virt{ .raw = i };
    }

    pub fn fromPtr(ptr: anytype) Virt {
        return Virt{ .raw = @intFromPtr(ptr) };
    }

    pub fn hhdmToPhys(self: Virt) Phys {
        std.debug.assert(self.raw >= main.hhdm_offset and self.raw < 0xFFFF_FFFF_8000_0000);
        std.debug.assert(self.raw != 0);
        std.debug.assert(self.raw != main.hhdm_offset);
        return Phys{
            .raw = self.raw - main.hhdm_offset,
        };
    }

    pub fn toPtr(self: Virt, comptime T: type) T {
        return @ptrFromInt(self.raw);
    }

    pub fn fromParts(parts: Parts) Virt {
        return fromInt(@bitCast(parts));
    }

    pub fn toParts(self: Virt) Parts {
        return @bitCast(self.raw);
    }
};
