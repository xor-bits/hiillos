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
    /// chunk offset within the Frame object
    frame_first_chunk: u32,
    /// number of bytes (rounded up to chunks) mapped
    chunks: u32,
    target: packed struct {
        /// mapping flags
        flags: abi.sys.MapFlags,
        /// virtual address destination of the mapping
        /// `Vmem.mappings` is sorted by this
        page: u36,
    },

    pub fn init(
        /// frame IS owned
        frame: *caps.Frame,
        /// vmem is NOT owned
        vmem: *caps.Vmem,
        frame_first_chunk: u32,
        vaddr: addr.Virt,
        chunks: u32,
        flags: abi.sys.MapFlags,
    ) !*@This() {
        std.debug.assert(chunks != 0);
        std.debug.assert(vaddr.isAligned(frame.chunk_size.sizeBytes()));

        const mapping = try caps.slab_allocator.allocator().create(@This());
        mapping.* = .{
            .frame = frame,
            .vmem = vmem,
            .frame_first_chunk = frame_first_chunk,
            .chunks = chunks,
            .target = .{
                .flags = flags,
                .page = vaddr.parts.page.index,
            },
        };

        return mapping;
    }

    pub fn deinit(self: *@This()) void {
        // remove the mapping from the list of mappings tracked by the frame
        self.frame.lock.lock();
        for (self.frame.mappings.items, 0..) |same, i| {
            if (same == self) {
                _ = self.frame.mappings.swapRemove(i);
                break;
            }
        }
        for (self.frame.mappings.items) |same| {
            std.debug.assert(same != self); // no duplicates
        }
        self.frame.lock.unlock();

        self.frame.deinit();
        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *const @This()) !*@This() {
        const mapping = try caps.slab_allocator.allocator().create(@This());
        mapping.* = self.*;
        mapping.frame.base.clone();
        return mapping;
    }

    pub fn eql(self: *const @This(), other: *const @This()) void {
        return std.mem.eql(u8, std.mem.asBytes(self), std.mem.asBytes(other));
    }

    pub fn setVaddr(self: *@This(), vaddr: addr.Virt) void {
        self.target.page = @truncate(vaddr.raw >> 12);
    }

    pub fn getVaddr(self: *const @This()) addr.Virt {
        return .{ .parts = .{ .page = .{
            .index = self.target.page,
        } } };
    }

    pub fn start(self: *const @This()) addr.Virt {
        return self.getVaddr();
    }

    pub fn end(self: *const @This()) addr.Virt {
        return self.getVaddr().add(self.chunks * self.frame.chunk_size.sizeBytes());
    }

    /// this is a `any(self AND other)`
    pub fn overlaps(self: *const @This(), vaddr: addr.Virt, bytes: usize) bool {
        const a_beg: usize = self.getVaddr().raw;
        const a_end: usize = self.getVaddr().raw + self.chunks * self.frame.chunk_size.sizeBytes();
        const b_beg: usize = vaddr.raw;
        const b_end: usize = vaddr.raw + bytes;

        if (a_end <= b_beg)
            return false;
        if (b_end <= a_beg)
            return false;
        return true;
    }

    pub fn isEmpty(self: *const @This()) bool {
        return self.chunks == 0;
    }
};
