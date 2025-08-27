const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const main = @import("../main.zig");
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

    // lock for modifying the thread
    lock: abi.lock.SpinMutex = .locked(),
    /// scheduler priority
    priority: u2 = 1,
    /// is the thread stopped/running/ready/waiting
    status: union(enum) {
        stopped: void,
        running: struct {
            /// the cpu that is currently running this thread
            current_cpu: *main.CpuLocalStorage,
        },
        ready: struct {
            /// scheduler priority at the time when the
            /// thread was added to the ready queue
            priority: u2,
        },
        waiting: union(enum) {
            other_thread_exit: struct {
                /// is ref counted
                obj: *caps.Thread,
            },
            other_process_exit: struct {
                /// is ref counted
                obj: *caps.Process,
            },
            unmap_tlb_shootdown: struct {
                i
            },
            transient_page_fault: struct {
                /// is ref counted
                obj: *caps.Frame,
            },
            notify: struct {
                /// is ref counted
                obj: *caps.Notify,
            },
            recv_queue: struct {
                /// is ref counted
                obj: *caps.Receiver,
            },
            send_queue: struct {
                /// is ref counted
                obj: *caps.Sender,
            },
            reply: struct {
                /// the receiver thread that gives the reply
                ///
                /// is ref counted
                from: *@This(),
            },
            futex: struct {
                // TODO: make futex use Frame caps instead
                paddr: addr.Phys,
            },
        },
        dead: struct {
            /// thread specific exit code
            exit_code: u64 = 0,
        },
    },
    exit_waiters: Queue = .{},
    // TODO: IPC buffer Frame where the userspace can write data freely
    // and on send, the kernel copies it (with CoW) to the destination IPC buffer
    // and replaces all handles with the target handles (u32 -> handle -> giveCap -> handle -> u32)
    /// extra ipc registers
    /// controlled by Receiver and Sender
    extra_regs: std.MultiArrayList(CapOrVal) = .{},
    /// signal handler instruction pointer
    signal_handler: usize = 0,
    /// if a signal handler is running, this is the return address
    signal: ?abi.sys.Signal = null,
    /// IPC reply target
    reply: ?*Thread = null,

    /// scheduler linked list, the lock is the specific ready/wait queue's lock
    scheduler_queue_node: abi.util.QueueNode(@This()) = .{},
    /// process threads linked list, the lock is the owner process' lock
    process_threads_node: abi.util.QueueNode(@This()) = .{},

    pub const Queue = ThreadQueue;

    pub const Cause = enum {
        none,
        other_thread_exit,
        other_process_exit,
        unmap_tlb_shootdown,
        transient_page_fault,
        notify_wait,
        ipc_recv,
        ipc_call0,
        ipc_call1,
        signal,
        futex,
    };

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

        if (conf.LOG_OBJ_CALLS)
            log.info("Thread.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.thread);

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

        if (conf.LOG_OBJ_CALLS)
            log.info("Thread.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.thread);

        self.exit(0);

        std.debug.assert(self.scheduler_queue_node.next == null);
        std.debug.assert(self.scheduler_queue_node.prev == null);
        std.debug.assert(self.process_threads_node.next == null);
        std.debug.assert(self.process_threads_node.prev == null);
        if (self.reply) |reply| reply.deinit();

        self.proc.deinit();

        for (0..128) |i| self.getExtra(@truncate(i)).deinit();
        self.extra_regs.deinit(caps.slab_allocator.allocator());

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Thread.clone", .{});

        self.refcnt.inc();
        return self;
    }

    pub fn switchTo(
        self: *@This(),
        trap: *arch.TrapRegs,
    ) void {
        self.lock.lock();
        self.current_cpu = arch.cpuLocal();
        self.lock.unlock();

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

        self.lock.lock();
        self.current_cpu = null;
        self.lock.unlock();
    }

    /// start the thread and push it to the ready queue,
    /// if the thread was already started (in a ready queue,
    /// in a wait queue, actively running or currently starting/stopping),
    /// `Error.NotStopped` is returned
    pub fn start(self: *@This()) !void {
        {
            self.lock.lock();
            defer self.lock.unlock();
            log.debug("status={}", .{self.status});
            self.queue;
            self.queue_lock;
            self.status;
            if (self.status != .stopped)
                return Error.NotStopped;
        }

        if (conf.LOG_ENTRYPOINT_CODE) {
            // dump the entrypoint code
            var it = self.proc.vmem.data(addr.Virt.fromInt(self.trap.rip), false);
            defer it.deinit();

            log.info("{}", .{self.trap});

            var len: usize = 200;
            while (it.next() catch null) |chunk| {
                const limit = @min(len, chunk.len);
                len -= limit;

                log.info("{}", .{abi.util.hex(@volatileCast(chunk[0..limit]))});
                if (len == 0) break;
            }
        }

        log.debug("pre next={s} prev={s}", .{
            if (self.process_threads_node.next == null) "null" else "some",
            if (self.process_threads_node.prev == null) "null" else "some",
        });
        log.debug("pre head={s} tail={s} eq={}", .{
            if (self.proc.active_threads.head == null) "null" else "some",
            if (self.proc.active_threads.tail == null) "null" else "some",
            self.proc.active_threads.head == self.proc.active_threads.tail,
        });
        try self.proc.start(self);
        log.debug("post next={s} prev={s}", .{
            if (self.process_threads_node.next == null) "null" else "some",
            if (self.process_threads_node.prev == null) "null" else "some",
        });
        log.debug("post head={s} tail={s} eq={}", .{
            if (self.proc.active_threads.head == null) "null" else "some",
            if (self.proc.active_threads.tail == null) "null" else "some",
            self.proc.active_threads.head == self.proc.active_threads.tail,
        });
        proc.start(self);
    }

    /// stop a thread to remove it from any ready queues, wait queues and
    /// interrupts the processor if its actively running on one
    pub fn stop(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
    ) !void {
        self.removeFromQueue() catch |_| {
            return Error.NotRunning;
        };
        // status is now also set to stopped

        {
            self.lock.lock();
            defer self.lock.unlock();
            errdefer log.debug("status was {}", .{self.status});
            // FIXME: atomic status, because the scheduler might be reading/writing this
            if (self.status != .ready and
                self.status != .running and
                self.status != .waiting)
                return Error.NotRunning;
            self.status = .stopped;
        }

        proc.stop(thread);
        if (self == thread) {
            proc.switchNow(trap);
        }
    }

    pub fn exit(
        self: *@This(),
        exit_code: usize,
    ) void {
        log.debug("exit head={s} tail={s} eq={}", .{
            if (self.proc.active_threads.head == null) "null" else "some",
            if (self.proc.active_threads.tail == null) "null" else "some",
            self.proc.active_threads.head == self.proc.active_threads.tail,
        });
        log.debug("exit next={s} prev={s}", .{
            if (self.process_threads_node.next == null) "null" else "some",
            if (self.process_threads_node.prev == null) "null" else "some",
        });
        self.proc.exit(exit_code, self);

        self.lock.lock();
        self.status = .dead;
        self.exit_code = exit_code;
        self.lock.unlock();

        // TODO: swap with empty, unlock and then process

        while (popFromQueue(&self.exit_waiters, &self.lock)) |waiter| {
            // TODO: reduce the lock,unlock,lock,unlock,lock,unlock spam,
            // as the state can change between unlock and lock
            waiter.lock.lock();
            waiter.trap.arg0 = exit_code;
            waiter.lock.unlock();

            proc.ready(waiter);
        }
    }

    pub fn waitExit(
        self: *@This(),
        thread: *caps.Thread,
        trap: *arch.TrapRegs,
    ) Error!void {
        if (self == thread)
            return Error.PermissionDenied;

        self.lock.lock();
        if (self.status == .dead) {
            self.lock.unlock();
            trap.arg0 = self.exit_code;
            return;
        }

        thread.status = .waiting;
        thread.waiting_cause = .other_thread_exit;
        self.lock.unlock();

        proc.switchFrom(trap, thread);
        thread.pushToQueue(&self.exit_waiters, &self.lock);
        proc.switchNow(trap);
    }

    pub fn getExtra(self: *@This(), idx: u7) CapOrVal {
        self.lock.lock();
        defer self.lock.unlock();

        const val = self.extra_regs.get(idx);
        self.extra_regs.set(idx, .{ .val = 0 });
        return val;
    }

    pub fn setExtra(self: *@This(), idx: u7, data: CapOrVal) void {
        self.lock.lock();
        defer self.lock.unlock();

        self.extra_regs.get(idx).deinit();
        self.extra_regs.set(idx, data);
    }

    /// prepareExtras has to be called for `dst` first
    pub fn moveExtra(src: *@This(), dst: *@This(), count: u7) void {
        if (count == 0) {
            return;
        } else {
            @branchHint(.cold);
        }

        src.lock.lock();
        defer src.lock.unlock();
        dst.lock.lock();
        defer dst.lock.unlock();

        for (0..count) |idx| {
            const val = src.extra_regs.get(@truncate(idx));
            src.extra_regs.set(@truncate(idx), .{ .val = 0 });

            const old_val = dst.extra_regs.get(idx);
            dst.extra_regs.set(@truncate(idx), val);

            old_val.deinit();
        }
    }

    pub fn readRegs(self: *@This()) abi.sys.ThreadRegs {
        self.lock.lock();
        defer self.lock.unlock();

        var regs: abi.sys.ThreadRegs = undefined;
        inline for (@typeInfo(abi.sys.ThreadRegs).@"struct".fields) |field| {
            @field(regs, field.name) = @field(self.trap, field.name);
        }
        return regs;
    }

    pub fn writeRegs(self: *@This(), regs: abi.sys.ThreadRegs) void {
        self.lock.lock();
        defer self.lock.unlock();

        // only iretq preserves rcx and r11
        self.trap.return_mode = .iretq;
        inline for (@typeInfo(abi.sys.ThreadRegs).@"struct".fields) |field| {
            @field(self.trap, field.name) = @field(regs, field.name);
        }
    }

    pub fn takeReply(self: *@This()) ?*Thread {
        const sender = self.reply orelse return null;
        std.debug.assert(sender.status == .waiting);
        self.reply = null;
        return sender;
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
            \\ - caused by: {}
            \\ - ip: 0x{x}
            \\ - sp: 0x{x}
        , .{
            target_addr,
            reason,
            caused_by,
            ip,
            sp,
        });
        self.proc.vmem.dump();

        while (conf.DEBUG_UNHANDLED_FAULT) {}

        // TODO: sigsegv

        proc.switchFrom(trap, self);
        proc.switchNow(trap);
    }
};

/// locking order (when holding both): Queue -> Thread
const ThreadQueue = struct {

    // TODO: the given thread should already be locked by the current thread,
    // TODO: and the lock will be released
    //
    /// used to push this thread to a ready/iowait queue
    pub fn pushToQueue(
        self: *@This(),
        self_lock: *abi.lock.SpinMutex,
        thread: *Thread,
    ) void {
        thread.lock.lock();
        thread.pushToQueuePrepare(self, self_lock);
        thread.lock.unlock();

        self_lock.lock();
        thread.pushToQueueFinish(self, self_lock);
        self_lock.unlock();
    }

    // TODO: the returned thread will be locked by the current thread
    //
    /// used with `popFromQueueFinish` to pop some thread off of a ready/iowait queue
    pub fn popFromQueue(
        self: *@This(),
        self_lock: *abi.lock.SpinMutex,
    ) ?*@This() {
        self_lock.lock();
        const _thread = popFromQueuePrepare(self, self_lock);
        self_lock.unlock();

        if (_thread) |thread| {
            thread.lock.lock();
            thread.popFromQueueFinish(self, self_lock);
            thread.lock.unlock();
        }

        return _thread;
    }

    /// used to push this with `pushToQueueFinish` thread to a ready/iowait queue
    pub fn pushToQueuePrepare(
        self: *@This(),
        self_lock: *abi.lock.SpinMutex,
        thread: *Thread,
    ) void {
        if (conf.IS_DEBUG) std.debug.assert(thread.lock.isLocked());
        std.debug.assert(thread.queue == null and thread.queue_lock == null);
        thread.queue = self;
        thread.queue_lock = self_lock;
    }

    /// used to push this with `pushToQueuePrepare` thread to a ready/iowait queue
    ///
    /// can also be used to cancel `popFromQueuePrepare`
    pub fn pushToQueueFinish(
        self: *@This(),
        self_lock: *abi.lock.SpinMutex,
        thread: *Thread,
    ) void {
        if (conf.IS_DEBUG) std.debug.assert(self_lock.isLocked());
        self.pushBack(thread);
    }

    /// used with `popFromQueueFinish` to pop some thread off of a ready/iowait queue
    pub fn popFromQueuePrepare(
        self: *@This(),
        self_lock: *abi.lock.SpinMutex,
    ) ?*@This() {
        if (conf.IS_DEBUG) std.debug.assert(self_lock.isLocked());
        return self.popFront();
    }

    /// used with `popFromQueuePrepare` to pop some thread off of a ready/iowait queue
    ///
    /// can also be used to cancel `pushToQueuePrepare`
    pub fn popFromQueueFinish(
        self: *@This(),
        self_lock: *abi.lock.SpinMutex,
        thread: *Thread,
    ) void {
        if (conf.IS_DEBUG) std.debug.assert(thread.lock.isLocked());
        std.debug.assert(thread.queue == self and thread.queue_lock == self_lock);
        thread.queue = null;
        thread.queue_lock = null;
    }

    /// used to interrupt a thread that is already in
    /// some ready/iowait queue and remove it from there
    pub fn removeFromQueue(
        thread: *Thread,
    ) error{NotInAQueue}!void {
        // TODO: this could cause performance issues
        // if something malicious is going on,
        // but rn locking order is more important
        while (true) {
            thread.lock.lock();
            const queue_lock = thread.queue_lock orelse
                return error.NotInAQueue;
            const queue = thread.queue.?;
            thread.lock.unlock();

            queue_lock.lock();
            defer queue_lock.unlock();

            thread.lock.lock();
            if (thread.queue_lock != queue_lock or thread.queue != queue) continue;
            thread.queue_lock = null;
            thread.queue = null;
            thread.status = .stopped;
            thread.lock.unlock();

            queue.remove(thread);
        }
    }

    /// pops a thread from one queue or pushes it to another
    pub fn atomicPopOrPush() void {}
};
