// based on: https://github.com/crossbeam-rs/crossbeam/blob/master/crossbeam-epoch/

const std = @import("std");
const root = @import("root");
const builtin = @import("builtin");

const conf = @import("conf.zig");
const mem = @import("mem.zig");
const ring = @import("ring.zig");
const lock = @import("lock.zig");

//

pub fn init_thread() void {
    const l = locals();
    l.* = .{
        .hazard = .{std.ArrayList(DeferFunc).init(allocator())} ** 3,
    };

    var all_locals_now = all_locals.load(.monotonic);

    while (true) {
        l.next.val = all_locals_now;
        if (all_locals.cmpxchgStrong(
            all_locals_now,
            l,
            .release,
            .monotonic,
        )) |fail| {
            all_locals_now = fail;
        } else {
            break;
        }
    }

    l.added = true;
}

pub fn pin() Guard {
    const l = locals();
    std.debug.assert(l.added);

    var global = global_epoch.val.load(.monotonic);
    global <<= 1; // local epoch is at bits 1..
    global |= 1; // mark as pinned

    const res = l.epoch.val.cmpxchgStrong(
        0,
        global,
        .seq_cst,
        .seq_cst,
    );
    // thread cannot be pinned twice at the same time
    std.debug.assert(res == null);

    // seqcst fence
    _ = l.epoch.val.load(.seq_cst);

    const guard = Guard{
        .epoch = @truncate(global >> 1),
        .locals = l,
    };

    l.count +%= 1; // lol
    if (conf.IS_DEBUG or l.count % 32 == 0) {
        @branchHint(.cold);
        collect(guard);
    }

    return guard;
}

pub fn unpin(guard: Guard) void {
    guard.locals.epoch.val.store(0, .release);
}

pub fn collect(guard: Guard) void {
    const new_epoch = tryAdvance();
    const expired = (new_epoch + 1) % 3;

    for (guard.locals.hazard[expired].items) |*deferred| {
        deferred.func(&deferred.data);
    }

    guard.locals.hazard[expired].clearRetainingCapacity();
}

fn tryAdvance() usize {
    const epoch: usize = global_epoch.val.load(.monotonic);

    // seqcst fence
    _ = global_epoch.val.load(.seq_cst);

    var next_locals = all_locals.load(.acquire);
    while (next_locals) |current_locals| {
        const thread_epoch: usize = current_locals.epoch.val.load(.monotonic);
        const is_pinned = thread_epoch & 1 == 1;

        if (is_pinned and thread_epoch != (epoch << 1) | 1) {
            // some thread is pinned and in another epoch
            return epoch;
        }

        next_locals = current_locals.next.val;
    }

    const new_epoch = (epoch + 1) % 3;
    global_epoch.val.store(new_epoch, .release);
    return new_epoch;
}

pub fn deferDeinit(guard: Guard, alloc: std.mem.Allocator, ptr: anytype) void {
    const Obj = struct {
        allocator: std.mem.Allocator,
        ptr: @TypeOf(ptr),

        fn func(data: *[3]usize) void {
            const self: *@This() = @ptrCast(data);
            self.allocator.destroy(self.ptr);
        }
    };

    std.debug.assert(@sizeOf(Obj) <= @sizeOf([3]usize));
    std.debug.assert(@alignOf(Obj) <= @sizeOf([3]usize));

    var data: [3]usize = undefined;
    @as(*Obj, @ptrCast(&data)).* = Obj{
        .allocator = alloc,
        .ptr = ptr,
    };

    deferFunc(guard, Obj.func, data);
}

pub fn deferCtxFunc(guard: Guard, ctx: anytype, comptime func: fn (ctx: @TypeOf(ctx)) void) !void {
    const T: type = @TypeOf(ctx);
    std.debug.assert(@sizeOf(T) <= @sizeOf([3]usize));
    std.debug.assert(@alignOf(T) <= @sizeOf([3]usize));

    const Wrapper = struct {
        fn wrapper(data: *[3]usize) void {
            func(@as(*T, @ptrCast(data)).*);
        }
    };

    var data: [3]usize = undefined;
    @as(*T, @ptrCast(&data)).* = ctx;

    try deferFunc(guard, Wrapper.wrapper, data);
}

pub fn deferFunc(guard: Guard, func: *const fn (data: *[3]usize) void, data: [3]usize) !void {
    try guard.locals.hazard[guard.epoch].append(DeferFunc{
        .func = func,
        .data = data,
    });
}

pub const Guard = struct {
    epoch: u2,
    locals: *Locals,
};

/// thread local storage for the EBMR system
pub const Locals = struct {
    // bit 0    => is_active
    // bits 1.. => epoch counter
    epoch: CachePadded(std.atomic.Value(usize)) = .init(.init(0)),

    // the rest are only for the owner thread

    next: CachePadded(?*Locals) = .init(null),
    added: bool = false,
    count: usize = 0,
    hazard: [3]std.ArrayList(DeferFunc) = undefined,
};

//

pub const RefCnt = struct {
    refcnt: std.atomic.Value(usize) = .init(1),

    pub const MAX: usize = std.math.maxInt(usize) >> 1;

    pub fn inc(self: *@This()) void {
        // log.info("inc refcnt", .{});
        const old = self.refcnt.fetchAdd(1, .monotonic);
        if (old >= MAX) @panic("too many ref counts");

        if (conf.IS_DEBUG and old % 100 == 0 and old != 0) {
            std.log.warn("a high refcount detected: {}", .{old});
        }

        if (conf.KERNEL_PANIC_ON_HIGH_REFCNT != 0 and old >= conf.KERNEL_PANIC_ON_HIGH_REFCNT)
            @panic("high ref count");
    }

    /// returns true if the item should be freed
    pub fn dec(self: *@This()) bool {
        // log.info("dec refcnt", .{});
        const old_cnt = self.refcnt.fetchSub(1, .release);
        std.debug.assert(old_cnt < MAX);
        std.debug.assert(old_cnt != 0);

        if (old_cnt == 1) {
            @branchHint(.cold);
        } else {
            return false;
        }

        // fence
        _ = self.refcnt.load(.acquire);

        return true;
    }

    pub fn load(self: *@This()) usize {
        return self.refcnt.load(.seq_cst);
    }

    pub fn isUnique(self: *@This()) bool {
        return self.refcnt.load(.acquire) == 1;
    }
};

pub fn RefCntHandle(comptime T: type) type {
    // a refcnt field is needed
    std.debug.assert(@FieldType(T, "refcnt") == RefCnt);
    // a deinit function is needed
    std.debug.assert(@hasDecl(T, "deinit"));

    return packed struct {
        ptr: *T,

        pub fn init(p: *T) @This() {
            return .{ .ptr = p };
        }

        pub fn clone(self: *const @This()) void {
            self.ptr.refcnt.inc();
        }

        pub fn deinit(self: @This()) void {
            if (!self.ptr.refcnt.dec()) return;
            self.ptr.deinit();
        }
    };
}

//

var global_epoch: CachePadded(std.atomic.Value(usize)) = .{ .val = .init(0) };
// var hazard_lists: [3]HazardList = .{HazardList{}} ** 3;
var all_locals: std.atomic.Value(?*Locals) = .init(null);

const DeferFunc = struct {
    func: *const fn (data: *[3]usize) void,
    data: [3]usize,
};

// const HazardList = struct {
//     mutex: lock.YieldMutex = .new(),
//     arr: std.ArrayList(DeferFunc) = .init(mem.slab_allocator),
// };

fn CachePadded(comptime T: type) type {
    return extern struct {
        val: T align(std.atomic.cache_line),

        fn init(val: T) @This() {
            return .{ .val = val };
        }
    };
}

var single_thread_test_locals: Locals = .{};

fn locals() *Locals {
    if (builtin.is_test) return &single_thread_test_locals;

    return root.epoch_locals();
}

fn allocator() std.mem.Allocator {
    if (builtin.is_test) return mem.slab_allocator;

    return root.epoch_allocator;
}
