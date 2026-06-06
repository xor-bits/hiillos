const abi = @import("abi");
const std = @import("std");

const apic = @import("../../apic.zig");
const caps = @import("../../caps.zig");

const Error = abi.sys.Error;
const conf = abi.conf;
const log = std.log.scoped(.x86irq);

//

base: caps.Object = .{ .type = .x86_irq },

notify: *caps.Notify,

irq: u8,
handler: ?struct {
    vector: u8,
    locals: *apic.Locals,
} = null,

pub const UserHandle = abi.caps.X86Irq;

// only borrows the X86IrqAllocator
pub fn init(_: *X86IrqAllocator, irq: u8) Error!*@This() {
    try allocIrq(&irq_bitmap, irq);
    errdefer freeIrq(&irq_bitmap, irq) catch unreachable;

    const notify = try caps.Notify.init();
    errdefer notify.deinit();

    const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
    obj.* = .{
        .irq = irq,
        .notify = notify,
    };

    caps.incCount(.x86_irq, .{ .irq = irq });
    return obj;
}

pub fn deinitFull(self: *@This()) void {
    caps.decCount(.x86_irq);

    self.notify.deinit();

    freeIrq(&irq_bitmap, self.irq) catch
        unreachable;

    caps.slab_allocator.allocator().destroy(self);
}

pub fn deinit(self: *@This()) void {
    if (!self.base.refcnt.dec()) return;
    self.deinitFull();
}

pub fn subscribe(self: *@This()) Error!*caps.Notify {
    if (conf.LOG_OBJ_CALLS)
        log.info("X86Irq.subscribe", .{});

    if (self.handler == null) {
        const result = try apic.registerExternalInterrupt(self);
        self.base.clone();
        self.handler = .{ .vector = result.vector, .locals = result.locals };

        log.debug("X86Irq registered vec={} irq={}", .{
            result.vector,
            self.irq,
        });
    }

    self.notify.base.clone();
    return self.notify;
}

//

pub const X86IrqAllocator = struct {
    base: caps.Object = .{ .type = .x86_irq_allocator },

    pub const UserHandle = abi.caps.X86IrqAllocator;

    pub fn init() !*@This() {
        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{};

        caps.incCount(.x86_irq_allocator, .{});
        return obj;
    }

    pub fn deinitFull(self: *@This()) void {
        caps.decCount(.x86_irq_allocator);

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn deinit(self: *@This()) void {
        if (!self.base.refcnt.dec()) return;
        self.deinitFull();
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
