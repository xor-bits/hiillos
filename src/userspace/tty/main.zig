const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.tty);
const Error = abi.sys.Error;

//

pub export var manifest = abi.loader.Manifest.new(.{
    .name = "tty",
});

pub export var export_tty = abi.loader.Resource.new(.{
    .name = "hiillos.tty.ipc",
    .ty = .receiver,
});

pub export var import_fb = abi.loader.Resource.new(.{
    .name = "hiillos.root.fb",
    .ty = .frame,
});

pub export var import_fb_info = abi.loader.Resource.new(.{
    .name = "hiillos.root.fb_info",
    .ty = .frame,
});

pub export var import_ps2 = abi.loader.Resource.new(.{
    .name = "hiillos.ps2.ipc",
    .ty = .sender,
});

pub export var import_pm = abi.loader.Resource.new(.{
    .name = "hiillos.pm.ipc",
    .ty = .sender,
});

//

pub fn main() !void {
    log.info("hello from tty", .{});

    const vmem = try caps.Vmem.self();
    defer vmem.close();

    const fb_frame = caps.Frame{ .cap = import_fb.handle };
    const fb_addr = try vmem.map(
        fb_frame,
        0,
        0,
        0,
        .{ .writable = true },
        .{ .cache = .write_combining },
    );

    const fb_info_frame = caps.Frame{ .cap = import_fb_info.handle };
    const fb_info_addr = try vmem.map(
        fb_info_frame,
        0,
        0,
        0,
        .{},
        .{},
    );

    const fb_info: *const abi.FramebufferInfoFrame = @ptrFromInt(fb_info_addr);
    const fb = @as([*]volatile u32, @ptrFromInt(fb_addr))[0 .. fb_info.pitch * fb_info.height];
    abi.util.fillVolatile(u32, fb, 0);

    var tty1 = try Tty.new(fb_addr, fb_info);
    tty1.writeBytes("hello from tty1");
    tty1.flush();

    const stdin = try abi.ring.Ring(u8).new(0x8000);
    defer stdin.deinit();
    const stdout = try abi.ring.Ring(u8).new(0x8000);
    defer stdout.deinit();
    const stderr = try abi.ring.Ring(u8).new(0x8000);
    defer stderr.deinit();

    @memset(stdin.storage(), 0);
    @memset(stdout.storage(), 0);
    @memset(stderr.storage(), 0);

    try abi.thread.spawn(kb_reader, .{stdin});

    _ = try abi.lpc.call(
        abi.PmProtocol.ExecElfRequest,
        .{
            .path = comptime abi.fs.Path.new("initfs:///sbin/coreutils") catch unreachable,
            .stdio = .{
                .stdin = .{ .ring = try stdin.share() },
                .stdout = .{ .ring = try stdout.share() },
                .stderr = .{ .ring = try stderr.share() },
            },
        },
        .{ .cap = import_pm.handle },
    );

    var buf: [0x1000]u8 = undefined;
    while (true) {
        const recv = try stdout.readWait(&buf);
        tty1.writeBytes(recv);
        tty1.flush();
    }
}

pub fn kb_reader(stdin: abi.ring.Ring(u8)) !void {
    const ps2 = abi.Ps2Protocol.Client().init(.{ .cap = import_ps2.handle });

    var shift = false;
    while (true) {
        const res, const code: abi.input.KeyCode, const state: abi.input.KeyState = try ps2.call(
            .nextKey,
            {},
        );
        try res;

        if (state == .release) continue;

        if (code == .left_shift or code == .left_shift) shift = !shift;

        if (if (shift) code.toCharShift() else code.toChar()) |ch| {
            try stdin.push(ch);
        }
    }
}

pub const Tty = struct {
    /// currently visible text data
    terminal_buf_front: []u8 = &.{},
    /// new text data, before a flush
    terminal_buf_back: []u8 = &.{},

    /// terminal size
    size: struct {
        width: u32 = 0,
        height: u32 = 0,
    } = .{},
    /// cursor position
    cursor: struct {
        x: u32 = 0,
        y: u32 = 0,
    } = .{},

    /// cpu accessible pixel buffer
    framebuffer: abi.util.Image([*]volatile u8),

    skipping_escape: bool = false,

    pub fn new(fb_addr: usize, fb_info: *const abi.FramebufferInfoFrame) !@This() {
        var self: @This() = .{
            .framebuffer = abi.util.Image([*]volatile u8){
                .width = @intCast(fb_info.width),
                .height = @intCast(fb_info.height),
                .pitch = @intCast(fb_info.pitch),
                .bits_per_pixel = fb_info.bpp,
                .pixel_array = @ptrFromInt(fb_addr),
            },
        };

        self.size = .{
            .width = @truncate(fb_info.width / 8),
            .height = @truncate(fb_info.height / 16),
        };
        const terminal_buf_size = self.size.width * self.size.height;
        const whole_terminal_buf = try abi.mem.slab_allocator.alloc(u8, terminal_buf_size * 2);

        for (whole_terminal_buf) |*b| {
            b.* = ' ';
        }

        self.terminal_buf_front = whole_terminal_buf[0..terminal_buf_size];
        self.terminal_buf_back = whole_terminal_buf[terminal_buf_size..];

        return self;
    }

    pub const TtyWriter = struct {
        tty: *Tty,

        pub const Error = error{};
        pub const Self = @This();

        pub fn writeAll(self: *const Self, bytes: []const u8) !void {
            self.tty.writeBytes(bytes);
        }

        pub fn writeBytesNTimes(self: *const Self, bytes: []const u8, n: usize) !void {
            for (0..n) |_| {
                self.tty.writeBytes(bytes);
            }
        }
    };

    pub fn writer(self: *@This()) TtyWriter {
        return .{ .tty = self };
    }

    pub fn writeBytes(self: *@This(), bytes: []const u8) void {
        for (bytes) |byte| {
            self.writeByte(byte);
        }
    }

    pub fn writeByte(self: *@This(), byte: u8) void {
        if (self.skipping_escape and byte != 'm') {
            return;
        } else if (self.skipping_escape) {
            self.skipping_escape = false;
            return;
        }

        switch (byte) {
            '\x1B' => {
                self.skipping_escape = true;
                return;
            },
            '\n' => {
                self.cursor.x = self.size.width;
            },
            ' ' => {
                self.cursor.x += 1;
            },
            '\t' => {
                self.cursor.x = std.mem.alignForward(u32, self.cursor.x + 1, 4);
            },
            else => {
                // uart.print("writing {d} to {d},{d}", .{ byte, cursor_x, cursor_y });
                self.terminal_buf_front[self.cursor.x + self.cursor.y * self.size.width] = byte;
                self.cursor.x += 1;
            },
        }

        if (self.cursor.x >= self.size.width) {
            // wrap back to a new line
            self.cursor.x = 0;
            self.cursor.y += 1;
        }
        if (self.cursor.y >= self.size.height) {
            // scroll down, because the cursor went off screen
            const len = self.terminal_buf_front.len;
            self.cursor.y -= 1;

            std.mem.copyForwards(
                u8,
                self.terminal_buf_front[0..],
                self.terminal_buf_front[self.size.width..],
            );
            for (self.terminal_buf_front[len - self.size.width ..]) |*b| {
                b.* = ' ';
            }
        }
    }

    pub fn flush(self: *@This()) void {
        // var nth: usize = 0;
        for (0..self.size.height) |_y| {
            for (0..self.size.width) |_x| {
                const x: u32 = @truncate(_x);
                const y: u32 = @truncate(_y);

                const i = x + y * self.size.width;
                if (self.terminal_buf_front[i] == self.terminal_buf_back[i]) {
                    continue;
                }
                self.terminal_buf_back[i] = self.terminal_buf_front[i];

                // update the physical pixel
                const letter = &abi.font.glyphs[self.terminal_buf_front[i]];
                var to = self.framebuffer.subimage(x * 8, y * 16, 8, 16) catch {
                    return;
                };
                to.fillGlyph(letter, 0xFFFFFF, 0x000000);
            }
        }
    }
};
