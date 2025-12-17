const abi = @import("abi");
const std = @import("std");

const apic = @import("../../apic.zig");
const arch = @import("../../arch.zig");
const caps = @import("../../caps.zig");

const Error = abi.sys.Error;
const conf = abi.conf;
const log = std.log.scoped(.x86ioport);

//

// FIXME: prevent reordering so that the offset would be same on all objects
refcnt: abi.epoch.RefCnt = .{},

port: u16,

pub const UserHandle = abi.caps.X86IoPort;

// only borrows the `*X86IoPortAllocator`
pub fn init(_: *X86IoPortAllocator, port: u16) Error!*@This() {
    if (conf.LOG_OBJ_CALLS)
        log.info("X86IoPort.init", .{});
    if (conf.LOG_OBJ_STATS)
        caps.incCount(.x86_ioport);

    try allocPort(&port_bitmap, port);

    const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
    obj.* = .{ .port = port };

    return obj;
}

pub fn deinit(self: *@This()) void {
    if (!self.refcnt.dec()) return;

    if (conf.LOG_OBJ_CALLS)
        log.info("X86IoPort.deinit", .{});
    if (conf.LOG_OBJ_STATS)
        caps.decCount(.x86_ioport);

    freePort(&port_bitmap, self.port) catch
        unreachable;

    caps.slab_allocator.allocator().destroy(self);
}

pub fn clone(self: *@This()) *@This() {
    if (conf.LOG_OBJ_CALLS)
        log.info("X86IoPort.clone", .{});

    self.refcnt.inc();
    return self;
}

// TODO: IOPB
// pub fn enable() void {}
// pub fn disable() void {}

pub fn inb(self: *@This()) u32 {
    const byte = arch.x86_64.inb(self.port);

    if (conf.LOG_OBJ_CALLS)
        log.info("X86IoPort.inb port={} byte={}", .{ self.port, byte });

    return byte;
}

pub fn outb(self: *@This(), byte: u8) void {
    if (conf.LOG_OBJ_CALLS)
        log.info("X86IoPort.outb port={} byte={}", .{ self.port, byte });

    arch.x86_64.outb(self.port, byte);
}

//

pub const X86IoPortAllocator = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    pub const UserHandle = abi.caps.X86IoPortAllocator;

    pub fn init() !*@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("X86IoPortAllocator.init", .{});
        if (conf.LOG_OBJ_STATS)
            caps.incCount(.x86_ioport_allocator);

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{};

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("X86IoPortAllocator.deinit", .{});
        if (conf.LOG_OBJ_STATS)
            caps.decCount(.x86_ioport_allocator);

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("X86IoPortAllocator.clone", .{});

        self.refcnt.inc();
        return self;
    }
};

// 0=free 1=used
const port_bitmap_len = 0x300 / 8;
var port_bitmap: [port_bitmap_len]std.atomic.Value(u8) = b: {
    var bitmap: [port_bitmap_len]std.atomic.Value(u8) = .{std.atomic.Value(u8).init(0xFF)} ** port_bitmap_len;

    // https://wiki.osdev.org/I/O_Ports

    // the PIT
    for (0x0040..0x0048) |port|
        freePort(&bitmap, @truncate(port)) catch unreachable;
    // PS/2 controller
    for (0x0060..0x0065) |port|
        freePort(&bitmap, @truncate(port)) catch unreachable;
    // CMOS and RTC registers
    for (0x0070..0x0072) |port|
        freePort(&bitmap, @truncate(port)) catch unreachable;
    // second serial port
    for (0x02F8..0x0300) |port|
        freePort(&bitmap, @truncate(port)) catch unreachable;

    break :b bitmap;
};

fn allocPort(bitmap: *[port_bitmap_len]std.atomic.Value(u8), port: u16) Error!void {
    if (port >= 0x300)
        return Error.AlreadyMapped;
    const byte = &bitmap[port / 8];
    if (byte.bitSet(@truncate(port % 8), .acquire) == 1)
        return Error.AlreadyMapped;
}

fn freePort(bitmap: *[port_bitmap_len]std.atomic.Value(u8), port: u16) Error!void {
    if (port >= 0x300)
        return Error.NotMapped;
    const byte = &bitmap[port / 8];
    if (byte.bitReset(@truncate(port % 8), .release) == 0)
        return Error.NotMapped;
}
