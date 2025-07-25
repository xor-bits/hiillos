const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const Process = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    vmem: *caps.Vmem,
    lock: abi.lock.SpinMutex = .newLocked(),
    caps: std.ArrayListUnmanaged(caps.CapabilitySlot),

    pub fn init(from_vmem: *caps.Vmem) !*@This() {
        errdefer from_vmem.deinit();

        if (conf.LOG_OBJ_CALLS)
            log.info("Process.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.process);

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{
            .vmem = from_vmem,
            .caps = .{},
        };
        obj.lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Process.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.process);

        for (self.caps.items) |*cap_slot| {
            cap_slot.deinit();
        }

        self.caps.deinit(caps.slab_allocator.allocator());
        self.vmem.deinit();

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Process.clone", .{});

        self.refcnt.inc();
        return self;
    }

    pub fn pushCapability(self: *@This(), cap: caps.Capability) Error!u32 {
        // std.debug.assert(cap.type != .null);

        // TODO: free list

        self.lock.lock();
        defer self.lock.unlock();

        const handle_usize = self.caps.items.len + 1;
        if (handle_usize > std.math.maxInt(u32)) return Error.OutOfBounds;
        const handle: u32 = @intCast(handle_usize);

        try self.caps.append(
            caps.slab_allocator.allocator(),
            caps.CapabilitySlot.init(cap),
        );

        return handle;
    }

    pub fn getCapability(self: *@This(), handle: u32) Error!caps.Capability {
        if (handle == 0) return Error.NullHandle;

        self.lock.lock();
        defer self.lock.unlock();

        if (handle - 1 >= self.caps.items.len) return Error.BadHandle;
        const slot = &self.caps.items[handle - 1];

        return slot.get() orelse return Error.BadHandle;
    }

    pub fn takeCapability(self: *@This(), handle: u32) Error!caps.Capability {
        if (handle == 0) return Error.NullHandle;

        // TODO: free list

        self.lock.lock();
        defer self.lock.unlock();

        if (handle - 1 >= self.caps.items.len) return Error.BadHandle;
        const slot = &self.caps.items[handle - 1];

        return slot.take() orelse return Error.BadHandle;
    }

    pub fn replaceCapability(self: *@This(), handle: u32, cap: caps.Capability) Error!?caps.Capability {
        if (handle == 0) return Error.NullHandle;

        self.lock.lock();
        defer self.lock.unlock();

        if (handle - 1 >= self.caps.items.len) return Error.BadHandle;
        const slot = &self.caps.items[handle - 1];

        const old_cap = slot.take();
        slot.set(cap);
        return old_cap;
    }

    pub fn getObject(self: *@This(), comptime T: type, handle: u32) Error!*T {
        const cap = try self.getCapability(handle);
        errdefer cap.deinit();

        return cap.as(T) orelse return Error.InvalidCapability;
    }

    pub fn takeObject(self: *@This(), comptime T: type, handle: u32) Error!*T {
        const cap = (try self.replaceCapability(handle, .{})) orelse {
            return Error.BadHandle;
        };

        // place it back if an error occurs
        errdefer std.debug.assert(null == self.replaceCapability(handle, cap) catch unreachable);

        // TODO: free list

        return cap.as(caps.Reply) orelse return Error.InvalidCapability;
    }
};
