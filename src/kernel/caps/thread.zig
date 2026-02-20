const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

/// thread information
pub const Thread = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt align(16) = .{},

    proc: *caps.Process,

    // debug lock for executing the thread
    exec_lock: abi.lock.DebugLock = .locked(),
    /// all context data, except fx
    trap: arch.TrapRegs = .{},
    /// fx context data, switched lazily
    fx: arch.FxRegs = .{},
    /// extra ipc registers
    /// controlled by Receiver and Sender
    // TODO: allocationless
    extra_regs: std.MultiArrayList(CapOrVal) = .{},
    /// IPC reply target
    reply: ?*Thread = null,
    message: abi.sys.Message = .{},

    // lock for modifying the thread
    lock: abi.lock.SpinMutex = .locked(),
    /// scheduler priority
    priority: u2 = 0,
    cpu_time: u64 = 0,
    /// is the thread stopped/running/ready/waiting
    status: abi.sys.ThreadStatus = .stopped,
    prev_status: abi.sys.ThreadStatus = .stopped,
    exit_code: usize = 0,
    exit_waiters: Queue = .{},
    // TODO: IPC buffer Frame where the userspace can write data freely
    // and on send, the kernel copies it (with CoW) to the destination IPC buffer
    // and replaces all handles with the target handles (u32 -> handle -> giveCap -> handle -> u32)
    /// signal handler instruction pointer
    signal_handler: usize = 0,
    /// if a signal handler is running, this is the return address
    signal: ?abi.sys.Signal = null,

    /// might point to a queue that this thread is not in anymore,
    /// but after locking it, the `scheduler_queue_node` is allowed to be read
    /// and it tells that the node is not present in the tree.
    current_or_previous_queue: ?*Queue = null,
    current_or_previous_queue_lock: ?*abi.lock.SpinMutex = null,
    // current_queue_kind: enum {
    //     thread_exit_waiters,
    //     process_exit_waiters,
    //     scheduler,
    //     futex,
    //     channel_recv,
    //     channel_send,
    //     notify_wait,
    //     frame_transient_sleep,
    // },
    /// scheduler linked list,
    /// requires holding the correct queue's lock to use instead of this thread's lock
    scheduler_queue_node: Queue.Node = .{},
    /// process threads linked list,
    /// requires holding the correct process' lock to use instead of this thread's lock
    process_threads_node: abi.util.QueueNode(@This()) = .{},

    pub const Queue = @import("thread/Queue.zig");
    pub const UserHandle = abi.caps.Thread;

    pub const CapOrVal = union(enum) {
        cap: caps.CapabilitySlot,
        val: u64,

        pub fn deinit(self: @This()) void {
            switch (self) {
                .cap => |cap| cap.deinit(),
                else => {},
            }
        }
    };

    pub fn init(from_proc: *caps.Process) !*@This() {
        errdefer from_proc.deinit();

        caps.incCount(.thread, .{ .process = from_proc });

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{ .proc = from_proc };

        try obj.extra_regs.resize(caps.slab_allocator.allocator(), 128);
        for (0..128) |i| obj.extra_regs.set(i, .{ .val = 0 });

        obj.lock.unlock();
        obj.exec_lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;
        caps.decCount(.thread);

        self.exit(0);

        std.debug.assert(self.lock.tryLock());
        std.debug.assert(self.exec_lock.tryLock());

        std.debug.assert(self.scheduler_queue_node.inner.extra.isolated);
        std.debug.assert(self.process_threads_node.next == null);
        std.debug.assert(self.process_threads_node.prev == null);
        self.discardReplyLockedExec();

        self.proc.deinit();

        for (0..128) |i| self.getExtraLockedExec(@truncate(i)).deinit();
        self.extra_regs.deinit(caps.slab_allocator.allocator());

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        self.refcnt.inc();
        return self;
    }

    pub fn switchTo(
        self: *@This(),
        trap: *arch.TrapRegs,
    ) void {
        self.exec_lock.lock();
        trap.* = self.trap;
        self.fx.restore();

        self.proc.vmem.switchTo();
    }

    pub fn switchFrom(
        self: *@This(),
        trap: *const arch.TrapRegs,
    ) void {
        self.fx.save();
        self.trap = trap.*;
        self.exec_lock.unlock();
    }

    pub fn start(self: *@This()) !void {
        try self.proc.start(self);

        if (conf.LOG_ENTRYPOINT_CODE) {
            // dump the entrypoint code
            var it = self.proc.vmem.data(addr.Virt.fromInt(self.trap.rip), false);
            defer it.deinit();

            log.info("{}", .{self.trap});

            var len: usize = 200;
            while (it.next() catch null) |chunk| {
                const limit = @min(len, chunk.len);
                len -= limit;

                log.info("{f}", .{abi.util.hex(@volatileCast(chunk[0..limit]))});
                if (len == 0) break;
            }
        }

        self.lock.lock();
        switch (self.status) {
            .stopped => {
                self.prev_status = self.status;
                self.status = .running;

                self.lock.unlock();
                proc.start(self.clone());
            },
            else => {
                self.lock.unlock();
                return Error.NotStopped;
            },
        }
    }

    pub fn stop(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
    ) !void {
        {
            self.lock.lock();
            defer self.lock.unlock();
            // FIXME: atomic status, because the scheduler might be reading/writing this
            if (self.status != .ready and
                self.status != .running and
                self.status != .waiting)
                return Error.NotRunning;
            self.prev_status = self.status;
            self.status = .stopped;
        }

        if (self == thread) {
            proc.switchFrom(trap, thread);
        }
        // proc.stop(thread);
    }

    pub fn exit(
        self: *@This(),
        exit_code: usize,
    ) void {
        self.proc.exit(exit_code, self);
        self.exitRemote(exit_code);
    }

    pub fn exitRemote(
        self: *@This(),
        exit_code: usize,
    ) void {
        self.lock.lock();
        self.prev_status = self.status;
        self.status = .dead;
        self.exit_code = exit_code;
        self.lock.unlock();

        self.onExit(exit_code);
    }

    fn onExit(self: *@This(), exit_code: usize) void {
        self.lock.lock();
        defer self.lock.unlock();
        while (self.exit_waiters.popFirstLocked(
            &self.lock,
            .ready,
        )) |waiter| {
            waiter.lock.lock();
            waiter.trap.arg0 = exit_code;
            waiter.lock.unlock();

            // log.info("exit waiter notified", .{});

            proc.ready(waiter);
        }
    }

    pub fn waitExit(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
    ) void {
        if (self == thread) {
            trap.syscall_id = abi.sys.encode(Error.PermissionDenied);
            return;
        }

        // early block the thread (or cancel)
        proc.switchFrom(trap, thread);

        {
            self.lock.lock();
            defer self.lock.unlock();
            thread.lock.lock();
            defer thread.lock.unlock();

            if (self.status != .dead) {
                self.exit_waiters.pushLockedThreadLocked(
                    &self.lock,
                    thread,
                    0,
                    .waiting,
                );
                return;
            }

            trap.arg0 = self.exit_code;
        }
        proc.switchUndo(thread);
    }

    pub fn getExtraLockedExec(self: *@This(), idx: u7) CapOrVal {
        self.exec_lock.assertIsLocked();

        const val = self.extra_regs.get(idx);
        self.extra_regs.set(idx, .{ .val = 0 });
        return val;
    }

    pub fn setExtraLockedExec(self: *@This(), idx: u7, data: CapOrVal) void {
        self.exec_lock.assertIsLocked();

        self.extra_regs.get(idx).deinit();
        self.extra_regs.set(idx, data);
    }

    /// prepareExtras has to be called for `dst` first
    pub inline fn moveExtraLockedExec(src: *@This(), dst: *@This(), count: u7) void {
        src.exec_lock.assertIsLocked();
        dst.exec_lock.assertIsLocked();

        // effectively always inline this check here
        // but call if count is above 0
        if (count == 0) {
            return;
        } else {
            @branchHint(.cold);
        }

        for (0..count) |idx| {
            const val = src.getExtraLockedExec(@truncate(idx));
            dst.setExtraLockedExec(@truncate(idx), val);
        }
    }

    pub fn readRegs(self: *@This()) abi.sys.ThreadRegs {
        // FIXME: incorrect, the exec lock should be held not this lock
        self.lock.lock();
        defer self.lock.unlock();

        var regs: abi.sys.ThreadRegs = undefined;
        inline for (@typeInfo(abi.sys.ThreadRegs).@"struct".fields) |field| {
            @field(regs, field.name) = @field(self.trap, field.name);
        }
        return regs;
    }

    pub fn writeRegs(self: *@This(), regs: abi.sys.ThreadRegs) void {
        // FIXME: incorrect, the exec lock should be held not this lock
        self.lock.lock();
        defer self.lock.unlock();

        // only iretq preserves rcx and r11
        self.trap.return_mode = .iretq;
        inline for (@typeInfo(abi.sys.ThreadRegs).@"struct".fields) |field| {
            @field(self.trap, field.name) = @field(regs, field.name);
        }
    }

    pub fn setReplyLockedExec(self: *@This(), target: *Thread) void {
        self.exec_lock.assertIsLocked();

        std.debug.assert(self.reply == null);
        std.debug.assert(self != target);
        self.reply = target;
    }

    pub fn takeReply(self: *@This()) ?*Thread {
        self.exec_lock.lock();
        defer self.exec_lock.unlock();
        return self.takeReplyLockedExec();
    }

    pub fn takeReplyLockedExec(self: *@This()) ?*Thread {
        self.exec_lock.assertIsLocked();

        const sender = self.reply orelse {
            @branchHint(.cold);
            return null;
        };
        self.reply = null;
        return sender;
    }

    pub fn discardReplyLockedExec(self: *@This()) void {
        self.exec_lock.assertIsLocked();

        if (self.reply) |discarded| {
            @branchHint(.cold);
            self.reply = null;
            // FIXME: exec_lock?
            discarded.trap.syscall_id = abi.sys.encode(Error.NoReply);
            proc.ready(discarded);
        }
    }

    pub fn unhandledPageFault(
        self: *@This(),
        target_addr: usize,
        caused_by: abi.sys.FaultCause,
        ip: usize,
        sp: usize,
        reason: anyerror,
        trap: *arch.TrapRegs,
    ) void {
        if (self.signal_handler != 0) {
            self.signal = abi.sys.Signal{
                .ip = ip,
                .sp = sp,
                .target_addr = target_addr,
                .caused_by = caused_by,
                .signal = .segv,
            };
            trap.rip = self.signal_handler;
            return;
        }

        log.warn(
            \\unhandled page fault 0x{x} (user) ({})
            \\ - thread: {*}
            \\ - caused by: {}
            \\ - ip: 0x{x}
            \\ - sp: 0x{x}
        , .{
            target_addr,
            reason,
            self,
            caused_by,
            ip,
            sp,
        });
        self.proc.vmem.dump();

        while (conf.DEBUG_UNHANDLED_FAULT) {}

        proc.switchFrom(trap, self);
        proc.switchNow(trap);
    }
};
