const abi = @import("abi");
const std = @import("std");

const apic = @import("../../apic.zig");
const caps = @import("../../caps.zig");

const Error = abi.sys.Error;
const conf = abi.conf;
const log = std.log.scoped(.x86irq);

//

// FIXME: prevent reordering so that the offset would be same on all objects
refcnt: abi.epoch.RefCnt = .{},

notify: *caps.Notify,

irq: u8,
handler: ?struct {
    vector: u8,
    locals: *apic.Locals,
} = null,

pub const UserHandle = abi.caps.X86Irq;

// only borrows the X86IrqAllocator
pub fn init(_: *X86IrqAllocator, irq: u8) Error!*@This() {
    if (conf.LOG_OBJ_CALLS)
        log.info("X86Irq.init", .{});
    if (conf.LOG_OBJ_STATS)
        caps.incCount(.x86_irq);

    try allocIrq(&irq_bitmap, irq);
    errdefer freeIrq(&irq_bitmap, irq) catch unreachable;

    const notify = try caps.Notify.init();
    errdefer notify.deinit();

    const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
    obj.* = .{
        .irq = irq,
        .notify = notify,
    };

    return obj;
}

pub fn deinit(self: *@This()) void {
    if (!self.refcnt.dec()) return;

    if (conf.LOG_OBJ_CALLS)
        log.info("X86Irq.deinit", .{});
    if (conf.LOG_OBJ_STATS)
        caps.decCount(.x86_irq);

    self.notify.deinit();

    freeIrq(&irq_bitmap, self.irq) catch
        unreachable;

    caps.slab_allocator.allocator().destroy(self);
}

pub fn clone(self: *@This()) *@This() {
    if (conf.LOG_OBJ_CALLS)
        log.info("X86Irq.clone", .{});

    self.refcnt.inc();
    return self;
}

pub fn subscribe(self: *@This()) Error!*caps.Notify {
    if (conf.LOG_OBJ_CALLS)
        log.info("X86Irq.subscribe", .{});

    if (self.handler == null) {
        const result = try apic.registerExternalInterrupt(self.clone());
        self.handler = .{ .vector = result.vector, .locals = result.locals };

        log.debug("X86Irq registered vec={} irq={}", .{
            result.vector,
            self.irq,
        });
    }

    return self.notify.clone();
}

pub fn ack(self: *@This()) Error!void {
    if (conf.LOG_OBJ_CALLS)
        log.info("X86Irq.ack", .{});

    const handler = self.handler orelse {
        return Error.IrqNotReady;
    };

    if (!handler.locals.ack(handler.vector)) {
        return Error.IrqNotReady;
    }
}

//

pub const X86IrqAllocator = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    pub const UserHandle = abi.caps.X86IrqAllocator;

    pub fn init() !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("X86IrqAllocator.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.x86_irq_allocator);

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{};

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("X86IrqAllocator.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.x86_irq_allocator);

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("X86IrqAllocator.clone", .{});

        self.refcnt.inc();
        return self;
    }
};

const irq_bitmap_len = 0x100 / 8;
var irq_bitmap: [irq_bitmap_len]std.atomic.Value(u8) = b: {
    var bitmap: [irq_bitmap_len]std.atomic.Value(u8) = .{std.atomic.Value(u8).init(0xFF)} ** irq_bitmap_len;

    for (0..apic.IRQ_AVAIL_COUNT + 1) |i|
        freeIrq(&bitmap, @truncate(i)) catch unreachable;

    break :b bitmap;
};

fn allocIrq(bitmap: *[irq_bitmap_len]std.atomic.Value(u8), irq: u8) Error!void {
    const byte = &bitmap[irq / 8];
    if (byte.bitSet(@truncate(irq % 8), .acquire) == 1)
        return Error.AlreadyMapped;
}

fn freeIrq(bitmap: *[irq_bitmap_len]std.atomic.Value(u8), irq: u8) Error!void {
    const byte = &bitmap[irq / 8];
    if (byte.bitReset(@truncate(irq % 8), .release) == 0)
        return Error.NotMapped;
}
