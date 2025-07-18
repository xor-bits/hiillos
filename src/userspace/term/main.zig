const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const log = std.log.scoped(.term);

//

pub fn main() !void {
    try abi.process.init();
    try abi.io.init();

    term_lock = try .new();
    term_lock.lock();

    const vmem = try caps.Vmem.self();
    // intentionally leak `vmem`

    const wm_sock_addr = abi.process.env("WM_SOCKET") orelse {
        log.err("could not find WM_SOCKET", .{});
        abi.sys.selfStop(1);
    };

    log.info("found WM_SOCKET={s}", .{wm_sock_addr});

    const wm_sock_result = try abi.lpc.call(abi.VfsProtocol.ConnectRequest, .{
        .path = try abi.fs.Path.new(wm_sock_addr),
    }, caps.COMMON_VFS);
    const wm_sock_raw = try wm_sock_result.asErrorUnion();

    std.debug.assert(wm_sock_raw.identify() == .sender);
    const wm_sock = caps.Sender{ .cap = wm_sock_raw.cap };

    const wm_display_result = try abi.lpc.call(
        abi.WmProtocol.ConnectRequest,
        .{},
        wm_sock,
    );
    const wm_display = try wm_display_result.asErrorUnion();

    const window_result = try abi.lpc.call(abi.WmDisplayProtocol.CreateWindowRequest, .{
        .size = .{
            .width = 600,
            .height = 400,
        },
    }, wm_display);
    const window = try window_result.asErrorUnion();

    const shmem_size = try window.fb.shmem.getSize();
    const shmem_addr = try vmem.map(
        window.fb.shmem,
        0,
        0,
        shmem_size,
        .{ .writable = true },
        .{},
    );

    const shmem = @as([*]volatile u8, @ptrFromInt(shmem_addr))[0..shmem_size];
    for (shmem, 0..) |*b, i| {
        // const x = (i % @as(usize, window.fb.pitch)) / 4;
        // const y = i / @as(usize, window.fb.pitch);
        if (i % 4 == 3) {
            b.* = 255; // max alpha
            // } else if (i % 4 == 2) {
            //     b.* = @intFromFloat(@as(f32, @floatFromInt(x)) / 900.0 * 255.0);
            // } else if (i % 4 == 1) {
            //     b.* = @intFromFloat(@as(f32, @floatFromInt(y)) / 600.0 * 255.0);
        } else {
            b.* = 0;
        }
    }

    term = try Terminal.new(
        vmem,
        window.fb,
        wm_display,
        window.window_id,
    );
    term_lock.unlock();

    const sh_stdin = try abi.ring.Ring(u8).new(0x8000);
    defer sh_stdin.deinit();
    const sh_stdout = try abi.ring.Ring(u8).new(0x8000);
    defer sh_stdout.deinit();
    const sh_stderr = try abi.ring.Ring(u8).new(0x8000);
    defer sh_stderr.deinit();

    @memset(sh_stdin.storage(), 0);
    @memset(sh_stdout.storage(), 0);
    @memset(sh_stderr.storage(), 0);

    try abi.thread.spawn(eventThread, .{
        sh_stdin,
        try wm_display.clone(),
    });

    _ = try abi.lpc.call(abi.PmProtocol.ExecElfRequest, .{
        .arg_map = try caps.Frame.init("initfs:///sbin/sh"),
        .env_map = try caps.COMMON_ENV_MAP.clone(),
        .stdio = .{
            .stdin = .{ .ring = try sh_stdin.share() },
            .stdout = .{ .ring = try sh_stdout.share() },
            .stderr = .{ .ring = try sh_stderr.share() },
        },
    }, caps.COMMON_PM);

    var stdout_reader = abi.escape.parser(
        std.io.bufferedReader(sh_stdout.reader()),
    );

    while (try stdout_reader.next()) |_token| {
        const token: abi.escape.Control = _token;
        // std.log.debug("token '{token}' ({})", .{
        //     token,
        //     std.meta.activeTag(token),
        // });
        switch (token) {
            .ch => |byte| {
                term_lock.lock();
                defer term_lock.unlock();

                term.writeByte(byte);
                term.flush();
            },
            .fg_colour => {},
            .bg_colour => {},
            .reset => {},
            .cursor_up => term.cursor.y -|= 1,
            .cursor_down => term.cursor.y +|= 1,
            .cursor_right => term.cursor.x +|= 1,
            .cursor_left => term.cursor.x -|= 1,
        }
    }
}

var term: Terminal = undefined;
var term_lock: abi.lock.CapMutex = undefined;

fn eventThread(sh_stdin: abi.ring.Ring(u8), wm_display: caps.Sender) !void {
    defer wm_display.close();

    while (true) {
        const ev_result = try abi.lpc.call(
            abi.WmDisplayProtocol.NextEventRequest,
            .{},
            wm_display,
        );
        const ev = try ev_result.asErrorUnion();
        try event(sh_stdin, ev);
    }
}

fn event(sh_stdin: abi.ring.Ring(u8), ev: abi.WmDisplayProtocol.Event) !void {
    switch (ev) {
        .window => |w_ev| try windowEvent(sh_stdin, w_ev),
    }
}

var shift: bool = false;
fn windowEvent(sh_stdin: abi.ring.Ring(u8), ev: abi.WmDisplayProtocol.WindowEvent) !void {
    switch (ev.event) {
        .resize => |new_fb| {
            term_lock.lock();
            defer term_lock.unlock();

            term.resize(new_fb) catch |err| {
                log.err("failed to resize terminal: {}", .{err});
            };
        },
        .keyboard_input => |kb_ev| {
            const is_shift = kb_ev.code == .left_shift or kb_ev.code == .left_shift;
            if (kb_ev.state == .press and is_shift) shift = true;
            if (kb_ev.state == .release and is_shift) shift = false;

            if (kb_ev.state == .release) return;

            if (if (shift) kb_ev.code.toCharShift() else kb_ev.code.toChar()) |ch| {
                try sh_stdin.push(ch);
            }
        },
        else => {},
    }
}

fn mapFb(vmem: caps.Vmem, fb: abi.WmDisplayProtocol.NewFramebuffer) ![]volatile u8 {
    const shmem_size = try fb.shmem.getSize();
    const shmem_addr = try vmem.map(
        fb.shmem,
        0,
        0,
        shmem_size,
        .{ .writable = true },
        .{},
    );

    // fill with opaque black
    const shmem = @as([*]volatile u8, @ptrFromInt(shmem_addr))[0..shmem_size];
    for (shmem, 0..) |*b, i| {
        if (i % 4 == 3) {
            b.* = 255; // max alpha
        } else {
            b.* = 0;
        }
    }

    return shmem;
}

// TODO: similar code is duplicated in userspace/tty/main.zig and kernel/fb.zig
pub const Terminal = struct {
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
    framebuffer: abi.util.Image([]volatile u8),

    /// wm ipc handle, to send damaged regions
    wm_display: caps.Sender,
    window_id: usize,

    vmem: caps.Vmem,

    pub fn new(
        vmem: caps.Vmem,
        info: abi.WmDisplayProtocol.NewFramebuffer,
        wm_display: caps.Sender,
        window_id: usize,
    ) !@This() {
        var self: @This() = .{
            .framebuffer = abi.util.Image([]volatile u8){
                .width = 0,
                .height = 0,
                .pitch = 0,
                .bits_per_pixel = 32,
                .pixel_array = &.{},
            },
            .wm_display = wm_display,
            .window_id = window_id,
            .vmem = vmem,
        };

        try self.resize(info);
        return self;
    }

    pub fn resize(
        self: *@This(),
        info: abi.WmDisplayProtocol.NewFramebuffer,
    ) !void {
        if (self.framebuffer.pixel_array.len != 0 and info.shmem.cap != 0) {
            try self.vmem.unmap(
                @intFromPtr(self.framebuffer.pixel_array.ptr),
                self.framebuffer.pixel_array.len,
            );
        }
        const fb =
            if (info.shmem.cap != 0)
                try mapFb(self.vmem, info)
            else
                self.framebuffer.pixel_array;
        try self.damage(
            0,
            0,
            info.size.width,
            info.size.height,
        );

        self.framebuffer = abi.util.Image([]volatile u8){
            .width = info.size.width,
            .height = info.size.height,
            .pitch = info.pitch,
            .bits_per_pixel = 32,
            .pixel_array = fb,
        };

        const old_size = self.size;
        self.size = .{
            .width = info.size.width / 8,
            .height = info.size.height / 16,
        };
        const terminal_buf_size = self.size.width * self.size.height;
        const whole_terminal_buf = try abi.mem.slab_allocator.alloc(u8, terminal_buf_size * 2);

        for (whole_terminal_buf) |*b| {
            b.* = ' ';
        }
        for (0..old_size.height) |_y| {
            for (0..old_size.width) |_x| {
                whole_terminal_buf[_x + _y * self.size.width] =
                    self.terminal_buf_front[_x + _y * old_size.width];
            }
        }

        self.terminal_buf_front = whole_terminal_buf[0..terminal_buf_size];
        self.terminal_buf_back = whole_terminal_buf[terminal_buf_size..];

        self.flush();
    }

    pub const Writer = struct {
        term: *Terminal,

        pub const Error = error{};
        pub const Self = @This();

        pub fn writeAll(self: *const Self, bytes: []const u8) !void {
            self.term.writeBytes(bytes);
        }

        pub fn writeBytesNTimes(self: *const Self, bytes: []const u8, n: usize) !void {
            for (0..n) |_| {
                self.term.writeBytes(bytes);
            }
        }
    };

    pub fn writer(self: *@This()) Writer {
        return .{ .term = self };
    }

    pub fn writeBytes(self: *@This(), bytes: []const u8) void {
        for (bytes) |byte| {
            self.writeByte(byte);
        }
    }

    pub fn writeByte(self: *@This(), byte: u8) void {
        switch (byte) {
            '\r' => {
                self.cursor.x = 0;
            },
            '\n' => {
                self.cursor.x = 0;
                self.cursor.y += 1;
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
        var damage_min_x: u32 = 0;
        var damage_max_x: u32 = 0;
        var damage_min_y: u32 = 0;
        var damage_max_y: u32 = 0;

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
                to.fillGlyph(letter, 0xFF_FFFFFF, 0xFF_000000);

                // TODO: refactor duplicated code: this and in wm.zig
                if (damage_min_x == damage_max_x or
                    damage_min_y == damage_max_y)
                {
                    damage_min_x = x * 8;
                    damage_min_y = y * 16;
                    damage_max_x = x * 8 + 8;
                    damage_max_y = y * 16 + 16;
                } else {
                    damage_min_x = @min(damage_min_x, x * 8);
                    damage_min_y = @min(damage_min_y, y * 16);
                    damage_max_x = @max(damage_max_x, x * 8 + 8);
                    damage_max_y = @max(damage_max_y, y * 16 + 16);
                }
            }
        }

        if (damage_min_x != damage_max_x and
            damage_min_y != damage_max_y)
        {
            self.damage(
                damage_min_x,
                damage_min_y,
                damage_max_x,
                damage_max_y,
            ) catch |err| {
                log.err("failed to damage regions: {}", .{err});
                return;
            };
        }
    }

    fn damage(
        self: *@This(),
        min_x: u32,
        min_y: u32,
        max_x: u32,
        max_y: u32,
    ) !void {
        const full_damage_result = try abi.lpc.call(abi.WmDisplayProtocol.Damage, .{
            .window_id = self.window_id,
            .min = .{ .x = @intCast(min_x), .y = @intCast(min_y) },
            .max = .{ .x = @intCast(max_x), .y = @intCast(max_y) },
        }, self.wm_display);
        try full_damage_result.asErrorUnion();
    }
};
