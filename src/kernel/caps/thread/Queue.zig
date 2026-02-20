// thread queue lock ordering: queue first, thread second

const std = @import("std");
const abi = @import("abi");
const rbtree = @import("rbtree");

const Thread = @import("../thread.zig").Thread;
const log = std.log.scoped(.queue);

//

inner: rbtree.RedBlackTree = .{},

pub const Node = struct {
    key: Key = .{},
    inner: rbtree.RedBlackTree.Node = .{},
};

pub const Key = struct {
    futex_addr: usize = 0,
    priority: u2 = 0,
    cpu_time: u64 = 0,
};

// pub const DebugCause = enum {
//     not_started,
//     starving,
//     other_thread_exit,
//     other_process_exit,
//     unmap_tlb_shootdown,
//     transient_page_fault,
//     notify_wait,
//     ipc_recv,
//     ipc_call0,
//     ipc_call1,
//     signal,
//     futex,
//     cancel_stop,
// };

pub fn formatNode(
    node: *const rbtree.RedBlackTree.Node,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const thread: *const Node = @fieldParentPtr("inner", node);
    try writer.print("{*}", .{thread});
}

pub fn priorityComparator(
    lhs_node: *const rbtree.RedBlackTree.Node,
    rhs_node: *const rbtree.RedBlackTree.Node,
) std.math.Order {
    const lhs: *const Node = @fieldParentPtr("inner", lhs_node);
    const rhs: *const Node = @fieldParentPtr("inner", rhs_node);

    var order: std.math.Order = undefined;

    order = std.math.order(lhs.key.futex_addr, rhs.key.futex_addr);
    if (order != .eq) return order;

    order = std.math.order(lhs.key.priority, rhs.key.priority);
    if (order != .eq) return order;

    order = std.math.order(lhs.key.cpu_time, rhs.key.cpu_time);
    if (order != .eq) return order;

    order = std.math.order(@intFromPtr(lhs), @intFromPtr(rhs));
    std.debug.assert(order != .eq);
    return order;
}

pub fn fetcherComparator(
    lhs_node: *const rbtree.RedBlackTree.Node,
    rhs_node: *const rbtree.RedBlackTree.Node,
) std.math.Order {
    const lhs: *const Node = @fieldParentPtr("inner", lhs_node);
    const rhs: *const Node = @fieldParentPtr("inner", rhs_node);

    var order: std.math.Order = undefined;

    order = std.math.order(lhs.key.futex_addr, rhs.key.futex_addr);
    if (order != .eq) return order;

    order = std.math.order(lhs.key.priority, rhs.key.priority);
    if (order != .eq) return order;

    return std.math.order(lhs.key.cpu_time, rhs.key.cpu_time);
}

pub fn pushThread(
    self: *@This(),
    // self_refcnt: *abi.epoch.RefCnt,
    self_lock: *abi.lock.SpinMutex,
    thread: *Thread,
    futex_addr: usize,
    queue_status: abi.sys.ThreadStatus,
) void {
    self_lock.lock();
    const cleanup = self.pushThreadLocked(
        self_lock,
        thread,
        futex_addr,
        queue_status,
    );
    self_lock.unlock();
    cleanup.run();
}

pub fn pushThreadLocked(
    self: *@This(),
    // self_refcnt: *abi.epoch.RefCnt,
    self_lock: *abi.lock.SpinMutex,
    thread: *Thread,
    futex_addr: usize,
    queue_status: abi.sys.ThreadStatus,
) Cleanup {
    std.debug.assert(self_lock.isLocked());
    thread.lock.lock();
    defer thread.lock.unlock();
    return self.pushLockedThreadLocked(
        self_lock,
        thread,
        futex_addr,
        queue_status,
    );
}

pub fn pushLockedThreadLocked(
    self: *@This(),
    // self_refcnt: *abi.epoch.RefCnt,
    self_lock: *abi.lock.SpinMutex,
    thread: *Thread,
    futex_addr: usize,
    queue_status: abi.sys.ThreadStatus,
) Cleanup {
    std.debug.assert(queue_status.isQueued());
    std.debug.assert(self_lock.isLocked());
    std.debug.assert(thread.lock.isLocked());
    thread.exec_lock.assertIsUnlocked();
    std.debug.assert(thread.current_or_previous_queue == null);
    std.debug.assert(thread.current_or_previous_queue_lock == null);
    const node = &thread.scheduler_queue_node;
    std.debug.assert(node.inner.extra.isolated);

    if (thread.status.shouldNotQueue()) {
        // the thread was interrupted by another thread right before
        // trying to push it to a queue
        @branchHint(.cold);
        if (thread.status == .stopping) thread.status = .stopped;
        if (thread.status == .killing) thread.status = .dead;
        return .{ .thread = thread };
    }

    node.key.cpu_time = thread.cpu_time;
    node.key.priority = thread.priority;
    node.key.futex_addr = futex_addr;

    const prev = self.inner.put(priorityComparator, &node.inner);
    std.debug.assert(prev == null);

    thread.current_or_previous_queue = self;
    thread.current_or_previous_queue_lock = self_lock;
    thread.status = queue_status;
    return .{};
}

pub const Cleanup = struct {
    thread: ?*Thread = null,

    pub fn run(self: @This()) void {
        if (self.thread) |thread| {
            thread.lock.lock();
            thread.onStopLocked();
            thread.onExitLocked();
            thread.lock.unlock();
            thread.deinit();
        }
    }
};

pub fn popFirst(
    self: *@This(),
    // self_refcnt: *abi.epoch.RefCnt,
    self_lock: *abi.lock.SpinMutex,
    running_status: abi.sys.ThreadStatus,
) ?*Thread {
    self_lock.lock();
    defer self_lock.unlock();
    return self.popFirstLocked(self_lock, running_status);
}

pub fn popFirstLocked(
    self: *@This(),
    // self_refcnt: *abi.epoch.RefCnt,
    self_lock: *abi.lock.SpinMutex,
    running_status: abi.sys.ThreadStatus,
) ?*Thread {
    std.debug.assert(self_lock.isLocked());
    const first = self.inner.first orelse return null;
    self.inner.remove(first);

    return popFinish(
        self,
        self_lock,
        first,
        running_status,
    );
}

pub fn popFutexAddr(
    self: *@This(),
    // self_refcnt: *abi.epoch.RefCnt,
    self_lock: *abi.lock.SpinMutex,
    futex_addr: usize,
    running_status: abi.sys.ThreadStatus,
) ?*Thread {
    self_lock.lock();
    defer self_lock.unlock();
    return self.popFutexAddrLocked(self_lock, futex_addr, running_status);
}

pub fn popFutexAddrLocked(
    self: *@This(),
    // self_refcnt: *abi.epoch.RefCnt,
    self_lock: *abi.lock.SpinMutex,
    futex_addr: usize,
    running_status: abi.sys.ThreadStatus,
) ?*Thread {
    std.debug.assert(self_lock.isLocked());

    const fetcher: Node = .{ .key = .{
        .futex_addr = futex_addr,
        .priority = 0,
        .cpu_time = 0,
    } };
    const found = self.inner.getEntryOrLarger(
        fetcherComparator,
        &fetcher.inner,
    ) orelse return null;
    self.inner.remove(found);

    return popFinish(
        self,
        self_lock,
        found,
        running_status,
    );
}

fn popFinish(
    self: *@This(),
    // self_refcnt: *abi.epoch.RefCnt,
    self_lock: *abi.lock.SpinMutex,
    rb_node: *rbtree.RedBlackTree.Node,
    running_status: abi.sys.ThreadStatus,
) *Thread {
    const node: *Node = @fieldParentPtr("inner", rb_node);
    const thread: *Thread = @alignCast(@fieldParentPtr("scheduler_queue_node", node));

    thread.lock.lock();
    defer thread.lock.unlock();
    self.popFinishLockedThread(
        self_lock,
        thread,
        running_status,
    );
    return thread;
}

fn popFinishLockedThread(
    self: *@This(),
    // self_refcnt: *abi.epoch.RefCnt,
    self_lock: *abi.lock.SpinMutex,
    thread: *Thread,
    running_status: abi.sys.ThreadStatus,
) void {
    std.debug.assert(thread.lock.isLocked());
    std.debug.assert(thread.current_or_previous_queue == self);
    std.debug.assert(thread.current_or_previous_queue_lock == self_lock);
    thread.current_or_previous_queue = null;
    thread.current_or_previous_queue_lock = null;
    thread.status = running_status;
}

pub fn removeThread(
    thread: *Thread,
    running_status: abi.sys.ThreadStatus,
) error{Retry}!void {
    thread.lock.lock();
    defer thread.lock.unlock();
    try removeLockedThread(thread, running_status);
}

pub fn removeLockedThread(
    thread: *Thread,
    running_status: abi.sys.ThreadStatus,
) error{Retry}!void {
    std.debug.assert(thread.lock.isLocked());

    const current_queue = thread.current_or_previous_queue orelse return;
    const current_queue_lock = thread.current_or_previous_queue_lock.?;

    if (!current_queue_lock.tryLock()) return error.Retry;
    defer current_queue_lock.unlock();

    std.debug.assert(!thread.scheduler_queue_node.inner.extra.isolated);
    current_queue.inner.remove(&thread.scheduler_queue_node.inner);
    // there has to be at least 2 owners: whoever called this and the
    // queue that held the thread
    std.debug.assert(!thread.refcnt.dec());

    current_queue.popFinishLockedThread(
        current_queue_lock,
        thread,
        running_status,
    );
}
