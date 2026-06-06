const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const lock = @import("../lock.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const Process = struct {
    base: caps.Object = .{ .type = .process },

    vmem: *caps.Vmem,
    lock: lock.TrackingSpinMutex = .{},
    caps: std.ArrayList(caps.CapabilitySlot) = .{},
    free: u32 = 0,
    status: abi.sys.ProcessStatus = .stopped,
    exit_code: usize = 0,
    exit_waiters: caps.Thread.Queue = .{},
    active_threads: abi.util.Queue(caps.Thread, "process_threads_node") = .{},

    pub const UserHandle = abi.caps.Process;

    pub fn init(from_vmem: *caps.Vmem) !*@This() {
        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{ .vmem = from_vmem };

        caps.incCount(.process, .{ .vmem = from_vmem });
        return obj;
    }

    pub fn deinitFull(self: *@This()) void {
        caps.decCount(.process);

        std.debug.assert(self.lock.tryLock());
        self.lock.giveOwnership();
        std.debug.assert(self.active_threads.isEmpty());

        self.closeAllCaps();

        self.caps.deinit(caps.slab_allocator.allocator());
        self.vmem.deinit();

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn deinit(self: *@This()) void {
        if (!self.base.refcnt.dec()) return;
        self.deinitFull();
    }

    fn closeAllCaps(
        self: *@This(),
    ) void {
        for (self.caps.items) |*cap_slot| {
            cap_slot.deinit();
        }
        self.caps.clearRetainingCapacity();
    }

    pub fn start(self: *@This()) !void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.status == .dead)
            return Error.ProcessDead;
        self.status = .running;
    }

    /// if `thread` is null, then the whole process exits
    pub fn exit(
        self: *@This(),
        exit_code: usize,
        exited_thread: ?*caps.Thread,
    ) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (exited_thread) |thread| {
            self.active_threads.remove(thread);
            if (!self.active_threads.isEmpty()) {
                return;
            }
        }

        self.status = .dead;
        self.exit_code = exit_code;
        self.closeAllCaps();

        var it = self.active_threads.iterator();
        while (it.next()) |active_thread| {
            active_thread.exitRemote(exit_code);
        }
    }

    pub fn waitExit(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
    ) error{PermissionDenied}!void {
        if (self == thread.proc) {
            return error.PermissionDenied;
        }

        // early block the thread (or cancel)
        proc.switchFrom(trap, thread);

        self.lock.lock();
        if (self.status == .dead) {
            self.lock.unlock();
            proc.switchUndo(thread);
            trap.arg0 = self.exit_code;
            return;
        }

        if (conf.IS_DEBUG and thread.dbg_filter) {
            log.debug("wait cause: procWaitExit", .{});
        }
        const cleanup = self.exit_waiters.pushThreadLocked(
            &self.lock,
            thread,
            0,
            .waiting,
        );
        self.lock.unlock();
        cleanup.run();
    }

    pub fn allocSlot(
        self: *@This(),
    ) Error!u32 {
        self.lock.lock();
        defer self.lock.unlock();
        return try self.allocSlotLocked();
    }

    fn allocSlotLocked(
        self: *@This(),
    ) Error!u32 {
        std.debug.assert(self.lock.isLockedByMe());

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
                .initFree(undefined),
            );

            return @intCast(handle_usize);
        }
    }

    pub fn freeSlot(
        self: *@This(),
        handle: u32,
    ) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.freeSlotLocked(handle);
    }

    fn freeSlotLocked(
        self: *@This(),
        handle: u32,
    ) void {
        std.debug.assert(self.lock.isLockedByMe());
        self.caps.items[handle - 1] = .initFree(self.free);
        self.free = handle;
    }

    pub fn pushCapabilitiesDefaultRights(
        self: *@This(),
        comptime n: usize,
        objects: anytype,
        handles: *[n]u32,
    ) Error!void {
        self.lock.lock();
        defer self.lock.unlock();

        comptime var n_objects = 0;
        inline for (objects) |_| {
            n_objects += 1;
        }
        comptime std.debug.assert(n == n_objects);

        @memset(handles, 0);
        errdefer for (handles) |handle| {
            if (handle == 0) continue;
            self.freeSlotLocked(handle);
        };

        for (handles) |*handle| {
            handle.* = try self.allocSlotLocked();
        }

        inline for (objects, handles) |obj, handle| {
            const base: *caps.Object = &obj.base;
            const rights = @typeInfo(@TypeOf(obj)).pointer.child.UserHandle.default_rights;
            self.insertCapabilityLocked(handle, base, rights);
        }
    }

    pub fn pushCapabilityDefaultRights(
        self: *@This(),
        obj: anytype,
    ) Error!u32 {
        const base: *caps.Object = &obj.base;
        const rights = @typeInfo(@TypeOf(obj)).pointer.child.UserHandle.default_rights;
        return self.pushCapability(base, rights);
    }

    pub fn pushCapability(
        self: *@This(),
        object: *caps.Object,
        rights: abi.sys.Rights,
    ) Error!u32 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.pushCapabilityLocked(object, rights);
    }

    fn pushCapabilityLocked(
        self: *@This(),
        object: *caps.Object,
        rights: abi.sys.Rights,
    ) Error!u32 {
        std.debug.assert(self.lock.isLockedByMe());
        // std.debug.assert(cap.type != .null);

        const handle: u32 = try self.allocSlotLocked();
        self.insertCapabilityLocked(handle, object, rights);
        return handle;
    }

    pub fn insertCapability(
        self: *@This(),
        handle: u32,
        object: *caps.Object,
        rights: abi.sys.Rights,
    ) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.insertCapabilityLocked(handle, object, rights);
    }

    fn insertCapabilityLocked(
        self: *@This(),
        handle: u32,
        object: *caps.Object,
        rights: abi.sys.Rights,
    ) void {
        std.debug.assert(self.lock.isLockedByMe());
        std.debug.assert(handle != 0);
        const slot = &self.caps.items[handle - 1];

        if (conf.LOG_CAP_CHANGES) {
            log.debug("push {} to {}", .{ object.type, handle });
        }

        std.debug.assert(slot.object == null);
        slot.* = .initUsed(object, rights);
    }

    const Opt = struct {
        min_rights: ?abi.sys.Rights = null,
        match_ty: ?abi.ObjectType = null,
    };

    fn checkSlotLocked(
        self: *@This(),
        handle: u32,
        opt: Opt,
    ) Error!*caps.CapabilitySlot {
        std.debug.assert(self.lock.isLockedByMe());
        std.debug.assert(handle != 0);

        if (handle - 1 >= self.caps.items.len) return Error.BadHandle;
        const slot = &self.caps.items[handle - 1];

        if (opt.min_rights) |min_rights|
            if (!slot.rights.contains(min_rights))
                return Error.PermissionDenied;

        if (slot.object == null) return Error.BadHandle;

        if (opt.match_ty) |match_ty|
            if (slot.object.?.type != match_ty)
                return Error.BadHandle;

        return slot;
    }

    pub fn getCapabilityAs(
        self: *@This(),
        handle: u32,
        comptime ty: abi.ObjectType,
        opt: Opt,
    ) Error!*caps.Object.typeOf(ty) {
        const T = caps.Object.typeOf(ty);
        const base_cap = try self.getCapability(handle, .{
            .match_ty = T.UserHandle.object_type,
            .min_rights = opt.min_rights,
        });
        return base_cap.downcast(T);
    }

    pub fn getCapability(
        self: *@This(),
        handle: u32,
        opt: Opt,
    ) Error!*caps.Object {
        if (handle == 0) return Error.NullHandle;

        self.lock.lock();
        defer self.lock.unlock();
        return self.getCapabilityLocked(handle, opt);
    }

    fn getCapabilityLocked(
        self: *@This(),
        handle: u32,
        opt: Opt,
    ) Error!*caps.Object {
        std.debug.assert(self.lock.isLockedByMe());

        const slot = try self.checkSlotLocked(handle, opt);
        slot.object.?.clone();
        return slot.object.?;
    }

    pub fn getCapabilityRights(
        self: *@This(),
        handle: u32,
        opt: Opt,
    ) Error!abi.sys.Rights {
        if (handle == 0) return Error.NullHandle;

        self.lock.lock();
        defer self.lock.unlock();
        const slot = try self.checkSlotLocked(handle, opt);
        return slot.rights;
    }

    // pub fn getObjectAndRights(
    //     self: *@This(),
    //     handle: u32,
    //     opt: Opt,
    // ) Error!struct { *caps.Object, abi.sys.Rights } {
    //     if (handle == 0) return Error.NullHandle;

    //     self.lock.lock();
    //     defer self.lock.unlock();
    //     const slot = try self.checkSlotLocked(handle, opt);
    //     slot.object.?.clone();
    //     return .{ slot.object.?, slot.rights };
    // }

    pub fn restrictCapability(
        self: *@This(),
        handle: u32,
        mask: abi.sys.Rights,
    ) Error!void {
        if (handle == 0) return Error.NullHandle;

        self.lock.lock();
        defer self.lock.unlock();
        return self.restrictCapabilityLocked(handle, mask);
    }

    fn restrictCapabilityLocked(
        self: *@This(),
        handle: u32,
        mask: abi.sys.Rights,
    ) Error!void {
        const slot = try self.checkSlotLocked(handle, .{});
        slot.rights = slot.rights.intersect(mask);
    }

    pub fn takeCapabilityAs(
        self: *@This(),
        handle: u32,
        comptime ty: abi.ObjectType,
        opt: Opt,
    ) Error!*caps.Object.typeOf(ty) {
        const T = caps.Object.typeOf(ty);
        const base_cap, _ = try self.takeCapability(handle, .{
            .match_ty = ty,
            .min_rights = opt.min_rights,
        });
        return base_cap.downcast(T);
    }

    pub fn takeCapability(
        self: *@This(),
        handle: u32,
        opt: Opt,
    ) Error!struct { *caps.Object, abi.sys.Rights } {
        if (handle == 0) return Error.NullHandle;

        self.lock.lock();
        defer self.lock.unlock();
        return self.takeCapabilityLocked(handle, opt);
    }

    fn takeCapabilityLocked(
        self: *@This(),
        handle: u32,
        opt: Opt,
    ) Error!struct { *caps.Object, abi.sys.Rights } {
        const slot = try self.checkSlotLocked(handle, opt);

        const object = slot.object.?;
        const rights = slot.rights;
        self.freeSlotLocked(handle);
        if (conf.LOG_CAP_CHANGES) {
            log.debug("take {} from {}", .{
                object.type, handle,
            });
        }
        return .{ object, rights };
    }

    pub fn closeCapability(
        self: *@This(),
        handle: u32,
    ) void {
        const cap, _ = self.takeCapability(
            handle,
            .{},
        ) catch return;
        cap.deinit();
    }

    pub fn transferCapability(
        from: *@This(),
        to: *@This(),
        handle: u32,
    ) Error!u32 {
        if (from == to) {
            @branchHint(.cold);
            from.lock.lock();
            defer from.lock.unlock();
            _ = try from.checkSlotLocked(handle, .{ .min_rights = .{
                .transfer = true,
            } });
            return handle;
        }

        var a = from;
        var b = to;
        if (@intFromPtr(a) > @intFromPtr(b)) {
            std.mem.swap(*caps.Process, &a, &b);
        }

        a.lock.lock();
        defer a.lock.unlock();

        b.lock.lock();
        defer b.lock.unlock();

        const slot_from = try from.checkSlotLocked(handle, .{ .min_rights = .{
            .transfer = true,
        } });
        const object = slot_from.object.?;
        const rights = slot_from.rights;
        const handle_to = try to.allocSlotLocked();

        from.freeSlotLocked(handle);
        to.insertCapabilityLocked(handle_to, object, rights);

        return handle_to;
    }

    pub fn cloneCapability(
        self: *@This(),
        handle: u32,
    ) Error!u32 {
        if (handle == 0) return Error.NullHandle;

        self.lock.lock();
        defer self.lock.unlock();

        const slot_from = try self.checkSlotLocked(handle, .{ .min_rights = .{
            .clone = true,
        } });
        const object = slot_from.object.?;
        const rights = slot_from.rights;
        const handle_to = try self.allocSlotLocked();

        object.clone();
        self.insertCapabilityLocked(handle_to, object, rights);

        return handle_to;
    }

    pub fn replaceCapability(
        self: *@This(),
        handle: u32,
        with: caps.Handle(caps.Object),
    ) Error!?caps.Handle(caps.Object) {
        if (handle == 0) return Error.NullHandle;

        self.lock.lock();
        defer self.lock.unlock();
        return self.replaceCapabilityLocked(handle, with);
    }

    fn replaceCapabilityLocked(
        self: *@This(),
        handle: u32,
        with: caps.Handle(caps.Object),
    ) Error!?caps.Handle(caps.Object) {
        std.debug.assert(self.lock.isLockedByMe());
        std.debug.assert(handle != 0);

        if (handle - 1 >= self.caps.items.len) return Error.BadHandle;
        const slot = &self.caps.items[handle - 1];

        const old_cap = slot.getBorrow();
        slot.* = .initUsed(with.ptr, with.rights);
        if (conf.LOG_CAP_CHANGES) {
            log.debug("replace {any} with {} in {}", .{
                old_cap, with.type, handle,
            });
        }
        return old_cap;
    }
};
