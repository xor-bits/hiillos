const std = @import("std");
const abi = @import("abi");

const main = @import("main.zig");

const caps = abi.caps;

const log = std.log.scoped(.ps2m);
const MouseEvent = abi.input.MouseEvent;
const Button = abi.input.Button;
const KeyState = abi.input.KeyState;

//

pub fn run(controller: *main.Controller) !void {
    if (!controller.is_dual) return;

    var mouse = try Mouse.init(controller);
    try mouse.run();
}

pub const Mouse = struct {
    controller: *main.Controller,

    state: enum {
        cmd,
        x,
        y,
        z,
    } = .cmd,

    last_cmd: Cmd = @bitCast(@as(u8, 0)),
    cmd: Cmd = @bitCast(@as(u8, 0)),
    last_z5byte: Z5Byte = @bitCast(@as(u8, 0)),
    x: u8 = 0,
    y: u8 = 0,
    z: u8 = 0,

    has_z: bool = false,
    has_5btn: bool = false,

    pub fn init(controller: *main.Controller) !@This() {
        log.debug("mouse init", .{});
        var self = @This(){ .controller = controller };

        if (!self.controller.is_dual) return self;

        try resetSettings(self.controller);

        self.has_z = try enableZAxis(self.controller);
        if (self.has_z) self.has_5btn = try enable5Buttons(self.controller);

        try enableOutput(controller);

        return self;
    }

    pub fn resetSettings(controller: *main.Controller) !void {
        log.debug("reset to default mouse settings", .{});
        for (0..3) |_| {
            try controller.writeMouse(0xf6); // reset to defaults
            if (try check(try controller.readWaitMouse()) == .resend) continue;
            break;
        } else {
            return error.BadMouse;
        }
    }

    pub fn setSampleRate(controller: *main.Controller, rate: u8) !void {
        log.debug("setting mouse sample rate", .{});
        for (0..3) |_| {
            try controller.writeMouse(0xf3); // set sample rate
            if (try check(try controller.readWaitMouse()) == .resend) continue;
            try controller.writeMouse(rate); // to `rate`
            if (try check(try controller.readWaitMouse()) == .resend) continue;
            break;
        } else {
            return error.BadMouse;
        }
    }

    pub fn enableZAxis(controller: *main.Controller) !bool {
        // check for z-axis support

        try setSampleRate(controller, 200);
        try setSampleRate(controller, 100);
        try setSampleRate(controller, 80);
        const mouse_id = try identify(controller);

        if (mouse_id == 0) {
            return false;
        } else if (mouse_id == 3) {
            return true;
        } else {
            log.err("invalid mouse id: {}", .{mouse_id});
            return error.BadMouse;
        }
    }

    pub fn enable5Buttons(controller: *main.Controller) !bool {
        // check for 5btn support, requires z-axis to already be enabled

        try setSampleRate(controller, 200);
        try setSampleRate(controller, 200);
        try setSampleRate(controller, 80);
        const mouse_id = try identify(controller);

        if (mouse_id == 3) {
            return false;
        } else if (mouse_id == 4) {
            return true;
        } else {
            log.err("invalid mouse id: {}", .{mouse_id});
            return error.BadMouse;
        }
    }

    pub fn disableOutput(controller: *main.Controller) !void {
        if (!controller.is_dual) return;

        log.debug("disable scanning", .{});
        for (0..3) |_| {
            try controller.writeMouse(0xf5);
            if (try check(try controller.readWaitMouse()) == .resend) continue;
            break;
        } else {
            return error.BadMouse;
        }

        try controller.flush();
    }

    pub fn enableOutput(controller: *main.Controller) !void {
        if (!controller.is_dual) return;

        log.debug("enable scanning", .{});
        for (0..3) |_| {
            try controller.writeMouse(0xF4);
            if (try check(try controller.readWaitMouse()) == .resend) continue;
            break;
        } else {
            return error.BadMouse;
        }
    }

    pub fn reset(controller: *main.Controller) !void {
        if (!controller.is_dual) return;

        log.debug("reset mouse", .{});
        try controller.writeMouse(0xff);
        const res0 = try controller.readWaitMouse();
        if (res0 == 0xfc) {
            controller.is_dual = false;
            return;
        }
        const res1 = try controller.readWaitMouse();
        if (res1 == 0xfc) {
            controller.is_dual = false;
            return;
        }
        if (!(res0 == 0xfa and res1 == 0xaa) and !(res1 == 0xfa and res0 == 0xaa)) {
            controller.is_dual = false;
            return;
        }

        try controller.flush();
        _ = try identify(controller);
        try controller.flush();
    }

    pub fn identify(controller: *main.Controller) !u8 {
        log.debug("identifying mouse", .{});
        for (0..3) |_| {
            try controller.writeMouse(0xf2);
            if (try check(try controller.readWaitMouse()) == .resend) continue;

            const device_id = try controller.readWaitMouse();
            log.info("mouse type: {}", .{device_id});
            return device_id;
        } else {
            return error.BadMouse;
        }
    }

    /// decode a response byte
    fn check(byte: u8) error{
        BufferOverrun,
        ButtonDetectionError,
        UnexpectedResponse,
    }!enum {
        ack,
        resend,
    } {
        switch (byte) {
            0xfa => return .ack,
            0xfe => return .resend,
            0x00 => return error.BufferOverrun,
            0xff => return error.ButtonDetectionError,
            else => {
                log.err("unexpected response: 0x{x}", .{byte});
                return error.UnexpectedResponse;
            },
        }
    }

    pub fn run(self: *@This()) !void {
        while (true) {
            const inb = try self.controller.readWaitMouse();
            try self.runOn(inb);
        }
    }

    fn runOn(self: *@This(), byte: u8) !void {
        switch (self.state) {
            .cmd => {
                self.cmd = @bitCast(byte);
                self.state = .x;
            },
            .x => {
                self.x = byte;
                self.state = .y;
            },
            .y => {
                self.y = byte;
                self.state = if (self.has_z) .z else .cmd;
            },
            .z => {
                self.z = byte;
                self.state = .cmd;
            },
        }

        if (self.state != .cmd) return;

        const last_cmd: Cmd = self.last_cmd;
        const last_z5byte: Z5Byte = self.last_z5byte;

        const cmd: Cmd = self.cmd;
        const z5byte: Z5Byte = @bitCast(self.z);
        const x: i16 = @bitCast(@as(u16, self.x) | if (cmd.x_sign) @as(u16, 0xFF00) else 0);
        const y: i16 = @bitCast(@as(u16, self.y) | if (cmd.y_sign) @as(u16, 0xFF00) else 0);
        const z: i16 = if (self.has_5btn)
            z5byte.z_axis
        else
            @as(i8, @bitCast(self.z));

        if (!cmd.one or cmd.x_overflow or cmd.y_overflow) return;

        self.last_cmd = cmd;
        self.last_z5byte = z5byte;
        const cmd_diff: Cmd = @bitCast(@as(u8, @bitCast(cmd)) ^ @as(u8, @bitCast(last_cmd)));
        const z5byte_diff: Z5Byte = @bitCast(@as(u8, @bitCast(z5byte)) ^ @as(u8, @bitCast(last_z5byte)));

        if (cmd_diff.left_btn)
            try sendEvent(.{ .button = .{
                .button = .left,
                .state = if (cmd.left_btn) .press else .release,
            } });

        if (cmd_diff.middle_btn)
            try sendEvent(.{ .button = .{
                .button = .middle,
                .state = if (cmd.middle_btn) .press else .release,
            } });

        if (cmd_diff.right_btn)
            try sendEvent(.{ .button = .{
                .button = .right,
                .state = if (cmd.right_btn) .press else .release,
            } });

        if (z5byte_diff.btn_4)
            try sendEvent(.{ .button = .{
                .button = .mb4,
                .state = if (z5byte.btn_4) .press else .release,
            } });

        if (z5byte_diff.btn_5)
            try sendEvent(.{ .button = .{
                .button = .mb5,
                .state = if (z5byte.btn_5) .press else .release,
            } });

        if (x != 0 or y != 0 or z != 0)
            try sendEvent(.{ .motion = .{
                .delta_x = x,
                .delta_y = y,
                .delta_z = z,
            } });
    }

    fn sendEvent(ev: MouseEvent) !void {
        if (abi.conf.LOG_KEYS)
            log.info("mouse ev: {}", .{ev});

        main.waiting_lock.lock();
        defer main.waiting_lock.unlock();

        for (main.waiting.items) |*reply| {
            reply.send(
                .{ .ok = .{ .mouse = ev } },
            ) catch |err| {
                log.warn("ps2 failed to reply: {}", .{err});
            };
        }
        main.waiting.clearRetainingCapacity();
        // log.info("key event {}", .{ev});
    }
};

const Cmd = packed struct {
    left_btn: bool,
    right_btn: bool,
    middle_btn: bool,
    one: bool,
    x_sign: bool,
    y_sign: bool,
    x_overflow: bool,
    y_overflow: bool,
};

const Z5Byte = packed struct {
    z_axis: i4,
    btn_4: bool,
    btn_5: bool,
    _: u2 = 0,
};
