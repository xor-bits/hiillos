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
    lock: abi.lock.SpinMutex = .locked(),
    caps: std.ArrayListUnmanaged(caps.CapabilitySlot),
    free: u32 = 0,
    status: abi.sys.ProcessStatus = .stopped,

    pub const UserHandle = abi.caps.Process;

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

    fn allocSlotLocked(self: *@This()) Error!u32 {
        const free = self.free;

        if (free != 0) {
            // use the free list

            self.free = self.caps.items[free - 1].nextFree();
            return free;
        } else {
            // allocate more

            const handle_usize = self.caps.items.len + 1;
            if (handle_usize > std.math.maxInt(u32)) return Error.OutOfMemory;
            try self.caps.append(
                caps.slab_allocator.allocator(),
                caps.CapabilitySlot{},
            );

            return @intCast(handle_usize);
        }
    }

    fn freeSlotLocked(self: *@This(), handle: u32) void {
        self.caps.items[handle - 1] = caps.CapabilitySlot.initFree(self.free);
        self.free = handle;
    }

    pub fn pushCapability(self: *@This(), cap: caps.Capability) Error!u32 {
        // std.debug.assert(cap.type != .null);

        self.lock.lock();
        defer self.lock.unlock();

        const handle: u32 = try self.allocSlotLocked();
        std.debug.assert(handle != 0);
        const slot = &self.caps.items[handle - 1];

        if (conf.LOG_CAP_CHANGES)
            log.debug("push {} to {}", .{ cap.type, handle });

        std.debug.assert(slot.type == .null);
        slot.* = caps.CapabilitySlot.init(cap);

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

    pub fn restrictCapability(self: *@This(), handle: u32, mask: abi.sys.Rights) Error!void {
        if (handle == 0) return Error.NullHandle;

        self.lock.lock();
        defer self.lock.unlock();

        if (handle - 1 >= self.caps.items.len) return Error.BadHandle;
        const slot = &self.caps.items[handle - 1];

        _ = slot.getBorrow() orelse return Error.BadHandle;
        slot.rights = slot.rights.intersect(mask);
    }

    pub fn takeCapability(self: *@This(), handle: u32, min_rights: ?abi.sys.Rights) Error!caps.Capability {
        if (handle == 0) return Error.NullHandle;

        self.lock.lock();
        defer self.lock.unlock();

        if (handle - 1 >= self.caps.items.len) return Error.BadHandle;
        const slot = &self.caps.items[handle - 1];

        if (min_rights) |_min_rights|
            if (!slot.rights.contains(_min_rights))
                return Error.PermissionDenied;

        const cap = slot.take() orelse return Error.BadHandle;
        self.freeSlotLocked(handle);
        if (conf.LOG_CAP_CHANGES)
            log.debug("take {} from {}", .{ cap.type, handle });
        return cap;
    }

    pub fn replaceCapability(self: *@This(), handle: u32, cap: caps.Capability) Error!?caps.Capability {
        if (handle == 0) return Error.NullHandle;

        self.lock.lock();
        defer self.lock.unlock();

        if (handle - 1 >= self.caps.items.len) return Error.BadHandle;
        const slot = &self.caps.items[handle - 1];

        const old_cap = slot.take();
        slot.set(cap);
        if (conf.LOG_CAP_CHANGES)
            log.debug("replace {any} with {} in {}", .{ old_cap, cap.type, handle });
        return old_cap;
    }

    pub fn getObject(self: *@This(), comptime T: type, handle: u32) Error!struct { *T, abi.sys.Rights } {
        const cap = try self.getCapability(handle);
        errdefer cap.deinit();

        const ptr = cap.as(T) orelse return Error.InvalidCapability;
        const rights = cap.rights;
        return .{ ptr, rights };
    }

    pub fn takeObject(self: *@This(), comptime T: type, handle: u32) Error!struct { *T, abi.sys.Rights } {
        const cap = (try self.replaceCapability(handle, .{})) orelse {
            return Error.BadHandle;
        };

        // place it back if an error occurs
        errdefer std.debug.assert(null == self.replaceCapability(handle, cap) catch unreachable);

        const ptr = cap.as(caps.Reply) orelse return Error.InvalidCapability;
        const rights = cap.rights;
        self.freeSlotLocked(handle);
        return .{ ptr, rights };
    }
};
