const std = @import("std");
const abi = @import("abi");

const addr = @import("../addr.zig");
const apic = @import("../apic.zig");
const arch = @import("../arch.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const Receiver = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    // TODO: remove a thread from here if gets stopped
    /// the currently waiting receiver thread
    receiver: std.atomic.Value(?*caps.Thread) = .init(null),

    /// a linked list of waiting callers
    queue_lock: abi.lock.SpinMutex = .newLocked(),
    queue: abi.util.Queue(caps.Thread, "next", "prev") = .{},

    pub fn init() !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Receiver.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.receiver);

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{};
        obj.queue_lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Receiver.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.receiver);

        if (self.receiver.load(.monotonic)) |receiver| {
            receiver.deinit();
        }
        while (self.queue.popFront()) |waiter| {
            waiter.deinit();
        }

        caps.slab_allocator.allocator().destroy(self);
    }

    /// block until something sends
    /// returns true if the current thread went to sleep
    pub fn recv(self: *@This(), thread: *caps.Thread, trap: *arch.TrapRegs) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("Receiver.recv", .{});

        if (thread.reply) |discarded| discarded.deinit();
        thread.reply = null;

        if (self.recvNoFail(thread, trap)) {
            proc.switchNow(trap);
        }
    }

    // might block the user-space thread (kernel-space should only ever block after a syscall is complete)
    /// returns true if the current thread went to sleep
    fn recvNoFail(self: *@This(), thread: *caps.Thread, trap: *arch.TrapRegs) bool {
        // stop the thread early to hold the lock for a shorter time
        thread.status = .waiting;
        thread.trap = trap.*;

        // check if a sender is already waiting
        self.queue_lock.lock();
        if (self.queue.popFront()) |immediate| {
            self.queue_lock.unlock();

            if (conf.LOG_WAITING)
                log.debug("IPC wake {*}", .{immediate});

            // copy over the message
            const msg = immediate.trap.readMessage();
            trap.writeMessage(msg);
            immediate.moveExtra(thread, @truncate(msg.extra));

            // save the reply target
            std.debug.assert(thread.reply == null);
            thread.reply = immediate;

            // undo stopping the thread
            thread.status = .running;
            return false;
        }

        if (null != self.receiver.cmpxchgStrong(null, thread, .seq_cst, .monotonic)) {
            unreachable; // the receiver cannot be cloned ... _yet_
        }
        self.queue_lock.unlock();

        arch.cpuLocal().current_thread = null;
        return true;
    }

    pub fn reply(thread: *caps.Thread, msg: abi.sys.Message) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("Receiver.reply", .{});

        const sender = try Receiver.replyGetSender(thread, msg);
        std.debug.assert(sender != thread);

        // set the original caller thread as ready to run again, but return to the current thread
        proc.ready(sender);
    }

    fn replyGetSender(thread: *caps.Thread, msg: abi.sys.Message) Error!*caps.Thread {
        const sender = thread.takeReply() orelse
            return Error.InvalidCapability;

        try replyToSender(thread, msg, sender);
        return sender;
    }

    fn replyToSender(thread: *caps.Thread, msg: abi.sys.Message, sender: *caps.Thread) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("replying {} from {*}", .{ msg, thread });

        // copy over the reply message
        sender.trap.writeMessage(msg);
        thread.moveExtra(sender, @truncate(msg.extra));
    }

    pub fn replyRecv(self: *@This(), thread: *caps.Thread, trap: *arch.TrapRegs, msg: abi.sys.Message) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("Receiver.replyRecv", .{});

        const sender = try Receiver.replyGetSender(thread, msg);
        std.debug.assert(sender != thread);

        // push the receiver thread into the ready queue
        // if there was a sender queued
        if (self.recvNoFail(thread, trap)) {
            // if the receiver went to sleep, switch to the original caller thread
            proc.switchTo(trap, sender);
        } else {
            @branchHint(.cold);
            // return back to the server, which is prob more important
            // and keeps the TLB cache warm
            // + ready up the caller thread
            proc.ready(sender);
        }
    }
};

pub const Sender = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    recv: *Receiver,
    stamp: u32,

    pub fn init(recv: *Receiver, stamp: u32) !*@This() {
        errdefer recv.deinit(); // FIXME: errdefer in the caller instead

        if (conf.LOG_OBJ_CALLS)
            log.info("Sender.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.sender);

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{
            .recv = recv,
            .stamp = stamp,
        };

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Sender.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.sender);

        self.recv.deinit();

        caps.slab_allocator.allocator().destroy(self);
    }

    // block until the receiver is free, then switch to the receiver
    pub fn call(self: *@This(), thread: *caps.Thread, trap: *arch.TrapRegs, msg: abi.sys.Message) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("Sender.call {}", .{msg});

        // acquire a listener or switch threads
        const listener = self.recv.receiver.swap(null, .seq_cst) orelse {
            @branchHint(.cold);

            // first push the thread into the sleep queue
            if (conf.LOG_WAITING)
                log.debug("IPC sleep {*}", .{thread});

            thread.status = .waiting;
            thread.trap = trap.*;
            thread.trap.writeMessage(msg);
            arch.cpuLocal().current_thread = null;

            self.recv.queue_lock.lock();
            self.recv.queue.pushBack(thread);
            self.recv.queue_lock.unlock();

            proc.switchNow(trap);
            return;
        };
        std.debug.assert(listener.status == .waiting);

        // copy over the message
        listener.trap.writeMessage(msg);
        thread.moveExtra(listener, @truncate(msg.extra));

        // save the reply target
        std.debug.assert(listener.reply == null);
        listener.reply = thread;

        // switch to the listener
        thread.status = .waiting;
        thread.trap = trap.*;

        proc.switchTo(trap, listener);
    }
};

pub const Reply = struct {
    // TODO: this shouldn't be cloneable
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},
    sender: std.atomic.Value(?*caps.Thread),

    /// only borrows `thread`
    pub fn init(thread: *caps.Thread) !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Reply.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.reply);

        const sender = thread.takeReply() orelse {
            @branchHint(.cold);
            return Error.InvalidCapability;
        };

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{ .sender = .init(null) };
        obj.sender.store(sender, .release);

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Reply.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.reply);

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn reply(self: *@This(), thread: *caps.Thread, msg: abi.sys.Message) Error!void {
        if (conf.LOG_OBJ_CALLS)
            log.debug("Reply.reply", .{});

        const sender = self.sender.swap(null, .acquire) orelse {
            // reply cap will be destroyed and its fine
            return Error.BadHandle;
        };

        Receiver.replyToSender(thread, msg, sender) catch unreachable;

        // set the original caller thread as ready to run again, but return to the current thread
        proc.ready(sender);
    }
};

pub const Notify = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    notified: std.atomic.Value(bool) = .init(false),

    // waiter queue
    queue_lock: abi.lock.SpinMutex = .newLocked(),
    queue: abi.util.Queue(caps.Thread, "next", "prev") = .{},

    pub fn init() !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Notify.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.notify);

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{};
        obj.queue_lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Notify.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.notify);

        while (self.queue.popFront()) |waiter| {
            waiter.deinit();
        }

        caps.slab_allocator.allocator().destroy(self);
    }

    /// returns true if the current thread went to sleep
    pub fn wait(self: *@This(), thread: *caps.Thread, trap: *arch.TrapRegs) void {
        // early test if its active
        if (self.poll()) {
            return;
        }

        // save the state and go to sleep
        thread.status = .waiting;
        thread.trap = trap.*;
        self.queue_lock.lock();
        self.queue.pushBack(thread);

        // while holding the lock: if it became active before locking but after the swap, then test it again
        if (self.poll()) {
            self.queue_lock.unlock();
            // revert
            std.debug.assert(self.queue.popBack() == thread);
            std.debug.assert(thread.status == .waiting);
            thread.status = .running;
            return;
        }
        self.queue_lock.unlock();

        proc.switchNow(trap);
    }

    pub fn poll(self: *@This()) bool {
        return self.notified.swap(false, .acquire);
    }

    pub fn notify(self: *@This()) bool {
        self.queue_lock.lock();
        if (self.queue.popFront()) |waiter| {
            self.queue_lock.unlock();

            proc.ready(waiter);
            return false;
        } else {
            defer self.queue_lock.unlock();

            return null != self.notified.cmpxchgStrong(false, true, .monotonic, .monotonic);
        }
    }
};
