const std = @import("std");
const abi = @import("abi");

const keyboard = @import("keyboard.zig");
const mouse = @import("mouse.zig");

const caps = abi.caps;

//

pub const log_level = .info;

const log = std.log.scoped(.ps2);
const Error = abi.sys.Error;
const KeyEvent = abi.input.KeyEvent;
const KeyCode = abi.input.KeyCode;
const KeyState = abi.input.KeyState;

var controller: Controller = undefined;

//

pub export var manifest = abi.loader.Manifest.new(.{
    .name = "ps2",
});

pub export var export_ps2 = abi.loader.Resource.new(.{
    .name = "hiillos.ps2.ipc",
    .ty = .receiver,
});

pub export var import_ps2_primary_irq = abi.loader.Resource.new(.{
    .name = "hiillos.ps2.primary_irq",
    .ty = .x86_irq,
    .note = 1,
});

pub export var import_ps2_secondary_irq = abi.loader.Resource.new(.{
    .name = "hiillos.ps2.secondary_irq",
    .ty = .x86_irq,
    .note = 12,
});

pub export var import_ps2_data_port = abi.loader.Resource.new(.{
    .name = "hiillos.ps2.data_port",
    .ty = .x86_ioport,
    .note = 0x60,
});

pub export var import_ps2_status_port = abi.loader.Resource.new(.{
    .name = "hiillos.ps2.status_port",
    .ty = .x86_ioport,
    .note = 0x64,
});

//

pub fn main() !void {
    log.info("hello from ps2", .{});
    waiting_lock = try .newLocked();
    waiting_lock.unlock();
    controller = try Controller.init();

    log.info("spawning keyboard thread", .{});
    try abi.thread.spawn(keyboard.run, .{&controller});
    log.info("spawning mouse thread", .{});
    try abi.thread.spawn(mouse.run, .{&controller});

    log.info("ps2 init done, server listening", .{});
    abi.lpc.daemon(System{
        .recv = caps.Receiver{ .cap = export_ps2.handle },
    });
}

var waiting_lock: abi.lock.CapMutex = undefined;
var waiting: std.ArrayList(abi.lpc.DetachedReply(abi.Ps2Protocol.Next.Response)) = .init(abi.mem.slab_allocator);
var event_queue: std.fifo.LinearFifo(abi.input.Event, .Dynamic) = .init(abi.mem.slab_allocator);

pub fn pushEvent(ev: abi.input.Event) void {
    waiting_lock.lock();
    defer waiting_lock.unlock();

    if (waiting.items.len != 0) {
        for (waiting.items) |*reply| {
            reply.send(.{ .ok = ev }) catch |err| {
                log.warn("failed to send input event reply: {}", .{err});
            };
        }
        waiting.clearRetainingCapacity();
        return;
    }

    event_queue.writeItem(ev) catch |err| {
        log.warn("input event dropped: {}", .{err});
    };
}

pub fn popEvent(reply: *abi.lpc.Reply(abi.Ps2Protocol.Next.Response)) void {
    waiting_lock.lock();
    defer waiting_lock.unlock();

    if (event_queue.readItem()) |ev| {
        reply.send(.{ .ok = ev });
        return;
    }

    const new = waiting.addOne() catch |err| {
        log.warn("input waiter dropped: {}", .{err});
        reply.send(.{ .err = .out_of_memory });
        return;
    };

    new.* = reply.detach() catch |err| {
        log.warn("input waiter dropped: {}", .{err});
        reply.send(.{ .err = .out_of_memory });
        _ = waiting.pop();
        return;
    };
}

fn next(
    _: *abi.lpc.Daemon(System),
    handler: abi.lpc.Handler(abi.Ps2Protocol.Next),
) !void {
    // TODO: create IPC pipes for each input listener
    popEvent(handler.reply);
}

const System = struct {
    recv: caps.Receiver,

    pub const routes = .{
        next,
    };
    pub const Request = abi.Ps2Protocol.Request;
};

//

pub const Controller = struct {
    /// port 0x60
    data: caps.X86IoPort,
    /// port 0x64
    status: caps.X86IoPort,
    is_dual: bool = false,

    /// irq 1
    primary_irq: caps.X86Irq,
    primary_notify: caps.Notify,
    /// irq 12
    secondary_irq: caps.X86Irq,
    secondary_notify: caps.Notify,

    lock: abi.lock.CapMutex,

    pub fn init() !@This() {
        const data = caps.X86IoPort{ .cap = import_ps2_data_port.handle };
        errdefer data.close();
        const status = caps.X86IoPort{ .cap = import_ps2_status_port.handle };
        errdefer status.close();

        const primary_irq = caps.X86Irq{ .cap = import_ps2_primary_irq.handle };
        errdefer primary_irq.close();
        const primary_notify = try primary_irq.subscribe();
        errdefer primary_notify.close();

        const secondary_irq = caps.X86Irq{ .cap = import_ps2_secondary_irq.handle };
        errdefer secondary_irq.close();
        const secondary_notify = try secondary_irq.subscribe();
        errdefer secondary_notify.close();

        var self = @This(){
            .data = data,
            .status = status,
            .primary_irq = primary_irq,
            .primary_notify = primary_notify,
            .secondary_irq = secondary_irq,
            .secondary_notify = secondary_notify,
            .lock = try abi.lock.CapMutex.new(),
        };
        errdefer self.lock.deinit();

        log.debug("disabling keyboard and mouse temporarily", .{});
        try self.writeCmd(0xad); // disable keyboard
        try self.writeCmd(0xa7); // disable mouse

        try self.flush();

        log.debug("reading controller config", .{});
        try self.writeCmd(0x20);
        log.debug("reading result", .{});
        var config: ControllerConfig = @bitCast(try self.readPoll());
        log.debug("controller config = {}", .{config});
        config.keyboard_translation = .disable;
        config.keyboard_interrupt = .disable;
        try self.writeCmd(0x60);
        try self.writeData(@bitCast(config));

        self.ackKeyboard() catch {};
        self.ackMouse() catch {};

        // log.debug("checking mouse support", .{});
        // try self.writeCmd(0xa8); // check mouse support
        // try self.writeCmd(0x20);
        // config = @bitCast(try self.readPoll());
        // if (config.mouse_clock == .enable) {
        //     log.debug("has mouse", .{});
        //     config.mouse_interrupt = .disable;
        //     config.mouse_clock = .disable;
        //     try self.writeCmd(0xa7);
        //     try self.writeCmd(0x60);
        //     try self.writeData(@bitCast(config));
        //     self.is_dual = true;
        // }
        // the above is too unreliable
        self.is_dual = true;

        log.debug("keyboard self test", .{});
        try self.writeCmd(0xab);
        if (try self.readPoll() != 0)
            return error.KeyboardSelfTestFail;
        if (self.is_dual) {
            log.debug("mouse self test", .{});
            try self.writeCmd(0xa9);
            if (try self.readPoll() != 0) {
                log.warn("mouse self test fail", .{});
                self.is_dual = false;
            }
        }

        log.debug("enable interrupts", .{});
        try self.writeCmd(0x20);
        config = @bitCast(try self.readPoll());
        config.keyboard_interrupt = .enable;
        if (self.is_dual)
            config.mouse_interrupt = .enable;
        try self.writeCmd(0x60);
        try self.writeData(@bitCast(config));

        log.debug("enable keyboard and mouse", .{});
        try self.writeCmd(0xae);
        if (self.is_dual)
            try self.writeCmd(0xa8);

        log.debug("disable output", .{});
        try self.flush();
        try keyboard.Keyboard.disableOutput(&self);
        if (self.is_dual)
            try mouse.Mouse.disableOutput(&self);

        log.debug("reset keyboard and mouse", .{});
        try self.flush();
        try keyboard.Keyboard.reset(&self);
        if (self.is_dual)
            try mouse.Mouse.reset(&self);

        log.debug("disable output", .{});
        try self.flush();
        try keyboard.Keyboard.disableOutput(&self);
        if (self.is_dual)
            try mouse.Mouse.disableOutput(&self);

        try self.flush();
        return self;
    }

    /// write controller commands
    pub fn writeCmd(self: *@This(), byte: u8) !void {
        self.lock.lock();
        defer self.lock.unlock();

        while (!try self.isInputEmptyLocked()) abi.sys.selfYield();
        try self.status.outb(byte);
    }

    /// write data to the keyboard
    pub fn writeKeyboard(self: *@This(), byte: u8) !void {
        self.lock.lock();
        defer self.lock.unlock();

        while (!try self.isInputEmptyLocked()) abi.sys.selfYield();
        try self.data.outb(byte);
    }

    /// write data to the mouse
    pub fn writeMouse(self: *@This(), byte: u8) !void {
        self.lock.lock();
        defer self.lock.unlock();

        while (!try self.isInputEmptyLocked()) abi.sys.selfYield();
        try self.status.outb(0xd4);
        try self.data.outb(byte);
    }

    /// write data what ever wants it
    pub fn writeData(self: *@This(), byte: u8) !void {
        try self.writeKeyboard(byte);
    }

    /// discard all data output
    pub fn flush(self: *@This()) !void {
        log.debug("flushing output", .{});
        while (try self.read()) |_| {}
    }

    /// read a byte from the output without blocking
    pub fn read(self: *@This()) !?u8 {
        self.lock.lock();
        defer self.lock.unlock();

        if (!try self.isOutputEmptyLocked()) {
            const b = try self.data.inb();
            log.debug("got byte 0x{x}", .{b});
            return b;
        } else {
            return null;
        }
    }

    /// read a byte from the output by waiting for keyboard interrupts
    pub fn readWaitKeyboard(self: *@This()) !u8 {
        self.waitKeyboard();
        const byte = try self.read() orelse {
            log.warn("keyboard byte dropped", .{});
            return error.KeyboardByteDropped;
        };
        try self.ackKeyboard();
        return byte;

        // if (try self.read()) |byte| return byte;

        // while (true) {
        //     self.waitKeyboard();
        //     const byte = try self.read() orelse {
        //         log.warn("keyboard byte dropped", .{});
        //         continue;
        //     };
        //     try self.ackKeyboard();
        //     return byte;
        // }
    }

    /// read a byte from the output by waiting for mouse interrupts
    pub fn readWaitMouse(self: *@This()) !u8 {
        self.waitMouse();
        const byte = try self.read() orelse {
            log.warn("mouse byte dropped", .{});
            return error.MouseByteDropped;
        };
        try self.ackMouse();

        return byte;
    }

    /// read a byte from the output by polling (with a yield)
    pub fn readPoll(self: *@This()) !u8 {
        while (true) {
            if (try self.read()) |byte| return byte;
            abi.sys.selfYield();
        }
    }

    /// check if bytes can be read
    pub fn isOutputEmptyLocked(self: *@This()) !bool {
        return try self.status.inb() & 0b01 == 0;
    }

    /// check if bytes can be written
    pub fn isInputEmptyLocked(self: *@This()) !bool {
        return try self.status.inb() & 0b10 == 0;
    }

    /// wait for keyboard interrupts
    pub fn waitKeyboard(self: *@This()) void {
        log.debug("waiting for keyboard interrupts", .{});
        _ = self.primary_notify.wait();
    }

    /// ACK the keyboard interrupt
    pub fn ackKeyboard(self: *@This()) !void {
        try self.primary_irq.ack();
    }

    /// wait for mouse interrupts
    pub fn waitMouse(self: *@This()) void {
        log.debug("waiting for mouse interrupts", .{});
        _ = self.secondary_notify.wait();
    }

    /// ACK the mouse interrupt
    pub fn ackMouse(self: *@This()) !void {
        try self.secondary_irq.ack();
    }

    pub const DeviceType = enum {
        standard_ps2_mouse,
        scroll_wheel_mouse,
        five_button_mouse,
        keyboard,
        unknown,
    };

    pub fn identify(
        self: *@This(),
        comptime readFn: anytype,
    ) !DeviceType {
        return switch (try readFn(self)) {
            0x00 => .standard_ps2_mouse,
            0x03 => .scroll_wheel_mouse,
            0x04 => .five_button_mouse,
            0xab => switch (try readFn(self)) {
                0x83, 0xc1, 0x84, 0x85, 0x86, 0x90, 0x91, 0x92 => .keyboard,
                else => .unknown,
            },
            0xac => switch (try readFn(self)) {
                0xa1 => .keyboard,
                else => .unknown,
            },
            else => .unknown,
        };
    }
};

const ControllerConfig = packed struct {
    keyboard_interrupt: enum(u1) { disable, enable },
    mouse_interrupt: enum(u1) { disable, enable },
    system_flag: enum(u1) { post_pass, post_fail },
    zero0: u1 = 0,
    keyboard_clock: enum(u1) { enable, disable }, // yes, they are flipped
    mouse_clock: enum(u1) { enable, disable },
    keyboard_translation: enum(u1) { disable, enable },
    zero1: u1 = 0,
};
