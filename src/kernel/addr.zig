const std = @import("std");
const abi = @import("abi");

const main = @import("main.zig");
const Error = abi.sys.Error;

//

pub const Phys = struct {
    raw: usize,

    pub const Self = @This();

    pub const Parts = packed struct {
        offset: u12 = 0,
        page: u32 = 0,
        reserved0: u8 = 0,
        reserved1: u12 = 0,
    };

    pub fn fromInt(i: usize) Self {
        return Self{ .raw = i };
    }

    pub fn toHhdm(self: Self) Virt {
        return .{ .raw = self.raw + main.hhdm_offset };
    }

    pub fn fromParts(parts: Parts) Self {
        return fromInt(@as(usize, @bitCast(parts)));
    }

    pub fn toParts(self: Self) Parts {
        return @bitCast(self.raw);
    }

    pub fn add(self: Self, offset: usize) Self {
        return .{ .raw = self.raw + offset };
    }

    pub fn sub(self: Self, offset: usize) Self {
        return .{ .raw = self.raw - offset };
    }

    pub fn isNull(self: Self) bool {
        return self.raw == 0;
    }
};

pub const Virt = struct {
    raw: usize,

    pub const Self = @This();

    pub const Parts = packed struct {
        offset: u12 = 0,
        level1: u9 = 0,
        level2: u9 = 0,
        level3: u9 = 0,
        level4: u9 = 0,
        _extra: u16 = 0,
    };

    pub fn fromUser(i: u64) Error!Self {
        if (i >= 0x8000_0000_0000) {
            return Error.InvalidAddress;
        } else {
            return fromInt(i);
        }
    }

    pub fn fromInt(i: usize) Self {
        return .{ .raw = i };
    }

    pub fn fromPtr(ptr: anytype) Self {
        return .{ .raw = @intFromPtr(ptr) };
    }

    pub fn hhdmToPhys(self: Self) Phys {
        std.debug.assert(self.raw >= main.hhdm_offset and self.raw < 0xFFFF_FFFF_8000_0000);
        std.debug.assert(self.raw != 0);
        std.debug.assert(self.raw != main.hhdm_offset);
        return .{ .raw = self.raw - main.hhdm_offset };
    }

    pub fn toPtr(self: Self, comptime T: type) T {
        return @ptrFromInt(self.raw);
    }

    pub fn fromParts(parts: Parts) Self {
        return fromInt(@bitCast(parts));
    }

    pub fn toParts(self: Self) Parts {
        return @bitCast(self.raw);
    }

    pub fn add(self: Self, offset: usize) Self {
        const result = self.raw + offset;
        std.debug.assert(result < 0x8000_0000_0000 or 0xFFFF_8000_0000_0000 <= result);
        return .{ .raw = result };
    }

    pub fn sub(self: Self, offset: usize) Self {
        const result = self.raw - offset;
        std.debug.assert(result < 0x8000_0000_0000 or 0xFFFF_8000_0000_0000 <= result);
        return .{ .raw = result };
    }

    pub fn isNull(self: Self) bool {
        return self.raw == 0;
    }
};
