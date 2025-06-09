const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const spin = @import("../spin.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

/// internal mapping managed by `Frame` and `Vmem` with `n:m` relationship
///
/// they are sorted by address by Vmem but are unsorted by Frame
pub const Mapping = struct {
    /// NOT refcounted, this `Mapping` is deleted if `frame` is deleted
    frame: *caps.Frame,
    /// NOT refcounted, this `Mapping` is deleted if `vmem` is deleted
    // vmem: *caps.Vmem,

    /// page offset within the Frame object
    frame_first_page: u32,
    /// number of bytes (rounded up to pages) mapped
    pages: u32,
    target: packed struct {
        /// mapping rights
        rights: abi.sys.Rights,
        /// mapping flags
        flags: abi.sys.MapFlags,
        /// virtual address destination of the mapping
        /// `Vmem.mappings` is sorted by this
        page: u40,
    },

    pub fn init(
        frame: *caps.Frame,
        frame_first_page: u32,
        vaddr: addr.Virt,
        pages: u32,
        rights: abi.sys.Rights,
        flags: abi.sys.MapFlags,
    ) @This() {
        return .{
            .frame = frame,
            .frame_first_page = frame_first_page,
            .pages = pages,
            .target = .{
                .rights = rights,
                .flags = flags,
                .page = @truncate(vaddr.raw >> 12),
            },
        };
    }

    pub fn deinit() void {}

    pub fn setVaddr(self: *@This(), vaddr: addr.Virt) void {
        self.target.page = @truncate(vaddr.raw >> 12);
    }

    pub fn getVaddr(self: *const @This()) addr.Virt {
        return addr.Virt.fromInt(@as(u64, self.target.page) << 12);
    }

    pub fn start(self: *const @This()) addr.Virt {
        return self.getVaddr();
    }

    pub fn end(self: *const @This()) addr.Virt {
        return addr.Virt.fromInt(self.getVaddr().raw + self.pages * 0x1000);
    }

    /// this is a `any(self AND other)`
    pub fn overlaps(self: *const @This(), vaddr: addr.Virt, bytes: u32) bool {
        const a_beg: usize = self.getVaddr().raw;
        const a_end: usize = self.getVaddr().raw + self.pages * 0x1000;
        const b_beg: usize = vaddr.raw;
        const b_end: usize = vaddr.raw + bytes;

        if (a_end <= b_beg)
            return false;
        if (b_end <= a_beg)
            return false;
        return true;
    }

    pub fn isEmpty(self: *const @This()) bool {
        return self.pages == 0;
    }
};
