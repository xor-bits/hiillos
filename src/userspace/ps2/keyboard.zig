const std = @import("std");
const abi = @import("abi");

const main = @import("main.zig");

const caps = abi.caps;

const log = std.log.scoped(.ps2kb);
const KeyEvent = abi.input.KeyEvent;
const KeyCode = abi.input.KeyCode;
const KeyState = abi.input.KeyState;

//

pub fn run(controller: *main.Controller) !void {
    var keyboard = try Keyboard.init(controller);
    try keyboard.run();
}

pub const Keyboard = struct {
    controller: *main.Controller,

    state: enum {
        ready,
        ext1,
        ext2,
        release,
        ext1release,
        ext2release,
    } = .ready,

    shift: bool = false,
    caps: bool = false,

    pub fn init(controller: *main.Controller) !@This() {
        log.debug("keyboard init", .{});
        const self = @This(){ .controller = controller };

        log.debug("setting scancode set", .{});
        for (0..3) |_| {
            try self.controller.writeKeyboard(0xf0); // set current scan code set
            if (try check(try self.controller.readWaitKeyboard()) == .resend) continue;
            try self.controller.writeKeyboard(2); // to 2
            if (try check(try self.controller.readWaitKeyboard()) == .resend) continue;
            // log.debug("{}", .{try self.readWait()});
            break;
        } else {
            return error.BadKeyboard;
        }

        log.debug("setting typematic byte", .{});
        for (0..3) |_| {
            try self.controller.writeKeyboard(0xf3); // set current typematic
            if (try check(try self.controller.readWaitKeyboard()) == .resend) continue;
            try self.controller.writeKeyboard(0b0_01_00010); // to 25hz, 500ms
            if (try check(try self.controller.readWaitKeyboard()) == .resend) continue;
            break;
        } else {
            return error.BadKeyboard;
        }

        log.debug("resetting LEDs", .{});
        for (0..3) |_| {
            try self.controller.writeKeyboard(0xed); // set LEDs
            if (try check(try self.controller.readWaitKeyboard()) == .resend) continue;
            try self.controller.writeKeyboard(0b000); // to all off
            if (try check(try self.controller.readWaitKeyboard()) == .resend) continue;
            break;
        } else {
            return error.BadKeyboard;
        }

        try enableOutput(controller);

        return self;
    }

    pub fn disableOutput(controller: *main.Controller) !void {
        log.debug("disable scanning", .{});
        for (0..3) |_| {
            try controller.writeKeyboard(0xf5);
            if (try check(try controller.readWaitKeyboard()) == .resend) continue;
            break;
        } else {
            return error.BadKeyboard;
        }

        controller.ackKeyboard() catch {};
        try controller.flush();
    }

    pub fn enableOutput(controller: *main.Controller) !void {
        log.debug("enable scanning", .{});
        for (0..3) |_| {
            try controller.writeKeyboard(0xF4);
            if (try check(try controller.readWaitKeyboard()) == .resend) continue;
            break;
        } else {
            return error.BadKeyboard;
        }
    }

    pub fn reset(controller: *main.Controller) !void {
        log.debug("reset keyboard", .{});
        try controller.writeKeyboard(0xff);
        const res0 = try controller.readWaitKeyboard();
        if (res0 == 0xfc)
            return error.KeyboardSelfTestFail;
        const res1 = try controller.readWaitKeyboard();
        if (res1 == 0xfc)
            return error.KeyboardSelfTestFail;
        if (!(res0 == 0xfa and res1 == 0xaa) and !(res1 == 0xfa and res0 == 0xaa))
            return error.KeyboardSelfTestFail;

        try controller.flush();
        _ = try identify(controller);
        try controller.flush();
    }

    pub fn identify(controller: *main.Controller) !main.Controller.DeviceType {
        log.debug("identifying keyboard", .{});
        for (0..3) |_| {
            try controller.writeKeyboard(0xf2);
            if (try check(try controller.readWaitKeyboard()) == .resend) continue;

            const device_id = try controller.identify(main.Controller.readWaitKeyboard);
            log.info("keyboard type: {}", .{device_id});
            return device_id;
        } else {
            return error.BadKeyboard;
        }
    }

    /// decode a response byte
    fn check(byte: u8) error{
        BufferOverrun,
        KeyDetectionError,
        UnexpectedResponse,
    }!enum {
        ack,
        resend,
    } {
        switch (byte) {
            0xfa => return .ack,
            0xfe => return .resend,
            0x00 => return error.BufferOverrun,
            0xff => return error.KeyDetectionError,
            else => {
                log.err("unexpected response: 0x{x}", .{byte});
                return error.UnexpectedResponse;
            },
        }
    }

    pub fn run(self: *@This()) !void {
        while (true) {
            const inb = try self.controller.readWaitKeyboard();
            if (try self.runOn(inb)) |ev| {
                if (abi.conf.LOG_KEYS)
                    log.info("keyboard ev: {}", .{ev});

                if (ev.code == .print_screen and abi.conf.KERNEL_PANIC_SYSCALL)
                    abi.sys.kernelPanic();

                main.pushEvent(.{ .keyboard = ev });
                // log.info("key event {}", .{ev});
            }
        }
    }

    fn runOn(self: *@This(), byte: u8) !?KeyEvent {
        switch (self.state) {
            .ready => {
                if (byte == 0xe0) {
                    self.state = .ext1;
                    return null;
                }
                if (byte == 0xe1) {
                    self.state = .ext2;
                    return null;
                }
                if (byte == 0xf0) {
                    self.state = .release;
                    return null;
                }

                const code = KeyCode.fromScancode0(byte) orelse return null;
                if (code == .too_many_keys or code == .power_on) {
                    return .{ .code = code, .state = .single };
                } else {
                    return .{ .code = code, .state = .press };
                }
            },
            .ext1 => {
                if (byte == 0xf0) {
                    self.state = .ext1release;
                    return null;
                }
                self.state = .ready;
                const code = KeyCode.fromScancode1(byte) orelse return null;
                return .{ .code = code, .state = .press };
            },
            .ext2 => {
                if (byte == 0xf0) {
                    self.state = .ext2release;
                    return null;
                }
                self.state = .ready;
                const code = KeyCode.fromScancode2(byte) orelse return null;
                return .{ .code = code, .state = .press };
            },
            .release => {
                self.state = .ready;
                const code = KeyCode.fromScancode0(byte) orelse return null;
                return .{ .code = code, .state = .release };
            },
            .ext1release => {
                self.state = .ready;
                const code = KeyCode.fromScancode1(byte) orelse return null;
                return .{ .code = code, .state = .release };
            },
            .ext2release => {
                self.state = .ready;
                const code = KeyCode.fromScancode2(byte) orelse return null;
                return .{ .code = code, .state = .release };
            },
        }
    }
};
