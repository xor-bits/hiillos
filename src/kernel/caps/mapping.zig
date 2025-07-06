const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

/// internal mapping managed by `Frame` and `Vmem` with `n:m` relationship
///
/// they are sorted by address by Vmem but are unsorted by Frame
pub const Mapping = struct {
    // only accessed through Frame while holding its lock \/

    /// NOT refcounted, this `Mapping` is deleted if `vmem` is deleted
    vmem: *caps.Vmem,

    // only accessed through Vmem while holding its lock \/

    /// IS refcounted, this `Mapping` is deleted if `frame` is deleted
    frame: *caps.Frame,
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
        /// frame IS owned
        frame: *caps.Frame,
        /// vmem is NOT owned
        vmem: *caps.Vmem,
        frame_first_page: u32,
        vaddr: addr.Virt,
        pages: u32,
        rights: abi.sys.Rights,
        flags: abi.sys.MapFlags,
    ) !*@This() {
        const mapping = try caps.slab_allocator.allocator().create(@This());
        mapping.* = .{
            .frame = frame,
            .vmem = vmem,
            .frame_first_page = frame_first_page,
            .pages = pages,
            .target = .{
                .rights = rights,
                .flags = flags,
                .page = @truncate(vaddr.raw >> 12),
            },
        };

        return mapping;
    }

    pub fn deinit(self: *@This()) void {
        self.frame.deinit();
        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *const @This()) !*@This() {
        const mapping = try caps.slab_allocator.allocator().create(@This());
        mapping.* = self.*;
        mapping.frame.refcnt.inc();

        return mapping;
    }

    pub fn eql(self: *const @This(), other: *const @This()) void {
        return std.mem.eql(u8, std.mem.asBytes(self), std.mem.asBytes(other));
    }

    pub fn ______clone(self: *const @This()) @This() {
        self.frame.refcnt.inc();
        self.vmem.refcnt.inc();
        return self.*;
    }

    pub fn ______deinitCloned(self: @This()) void {
        self.frame.deinit();
        self.vmem.deinit();
    }

    /// doesnt take a normal Mapping, but one where `frame` and `vmem` are owned by the passed struct
    pub fn ______remove(self: @This()) void {
        defer self.frame.deinit();
        defer self.vmem.deinit();

        self.frame.lock.lock();
        self.vmem.lock.lock();

        const frame_mapping_i: ?usize = for (self.frame.mappings.items, 0..) |mapping, i| {
            // TODO: binary search
            if (std.mem.eql(u8, std.mem.asBytes(mapping), std.mem.asBytes(&self))) {
                break i;
            }
        } else null;

        if (frame_mapping_i) |i| {
            _ = self.frame.mappings.swapRemove(i);
        }

        self.frame.lock.unlock();

        const vmem_mapping_i: ?usize = for (self.vmem.mappings.items, 0..) |mapping, i| {
            // TODO: binary search
            if (std.mem.eql(u8, std.mem.asBytes(mapping), std.mem.asBytes(&self))) {
                break i;
            }
        } else null;

        if (vmem_mapping_i) |i| {
            _ = self.vmem.mappings.orderedRemove(i);
        }

        self.vmem.lock.unlock();

        const remove_count = @as(u32, @intFromBool(vmem_mapping_i != null)) +
            @as(u32, @intFromBool(frame_mapping_i != null));
        std.debug.assert(remove_count != 1);
        std.debug.assert(remove_count == 0 or remove_count == 2);

        if (remove_count == 2) {
            // this mapping was successfully removed from both, so deinit the Mapping itself
            self.frame.deinit();
        }
    }

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
