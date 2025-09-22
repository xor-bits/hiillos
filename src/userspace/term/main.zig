const std = @import("std");
const abi = @import("abi");
const gui = @import("gui");

const caps = abi.caps;
const log = std.log.scoped(.term);

//

pub fn main() !void {
    try abi.rt.init();

    term_lock.lock();

    const wm_display = try gui.WmDisplay.connect();

    const window = try wm_display.createWindow(.{
        .size = .{ 600, 400 },
    });

    term = try Terminal.new(
        window.fb,
        wm_display,
        window,
    );
    term_lock.unlock();

    const sh_stdin = try abi.ring.Ring(u8).new(0x8000);
    defer sh_stdin.deinit();
    const sh_stdout = try abi.ring.Ring(u8).new(0x8000);
    defer sh_stdout.deinit();
    const sh_stderr = sh_stdout;
    // const sh_stderr = try abi.ring.Ring(u8).new(0x8000);
    // defer sh_stderr.deinit();

    @memset(sh_stdin.storage(), 0);
    @memset(sh_stdout.storage(), 0);
    // @memset(sh_stderr.storage(), 0);

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

        term_lock.lock();
        defer term_lock.unlock();

        // std.log.debug("token '{token}' ({})", .{
        //     token,
        //     std.meta.activeTag(token),
        // });
        switch (token) {
            .ch => |byte| {
                term.writeByte(byte);
                term.flush(false);
            },
            .fg_colour => {},
            .bg_colour => {},
            .reset => {},
            .cursor_up => term.cursor.y -|= 1,
            .cursor_down => term.cursor.y +|= 1,
            .cursor_right => term.cursor.x +|= 1,
            .cursor_left => term.cursor.x -|= 1,
            .cursor_next_line => |count| {
                term.cursor.y +|= std.math.lossyCast(u32, count);
                term.cursor.x = 0;
            },
            .cursor_prev_line => |count| {
                term.cursor.y -|= std.math.lossyCast(u32, count);
                term.cursor.x = 0;
            },
            .erase_in_display => |mode| {
                term.wrapCursor();
                const area_to_clear = switch (mode) {
                    .cursor_to_end => term.terminal_buf_front[term.cursor.x + term.cursor.y * term.size.width ..],
                    .start_to_cursor => term.terminal_buf_front[0 .. term.cursor.x + term.cursor.y * term.size.width],
                    .start_to_end => term.terminal_buf_front,
                };
                @memset(area_to_clear, ' ');
            },
            .cursor_push => term.cursor_store = term.cursor,
            .cursor_pop => term.cursor = term.cursor_store,
        }
    }
}

var term: Terminal = undefined;
var term_lock: abi.thread.Mutex = .{};

fn eventThread(sh_stdin: abi.ring.Ring(u8), wm_display: gui.WmDisplay) !void {
    defer wm_display.deinit();

    while (true) {
        const ev = try wm_display.nextEvent();
        try event(sh_stdin, ev);
    }
}

fn event(sh_stdin: abi.ring.Ring(u8), ev: gui.Event) !void {
    switch (ev) {
        .window => |w_ev| try windowEvent(sh_stdin, w_ev),
        else => {},
    }
}

var shift: bool = false;
var ctrl: bool = false;
fn windowEvent(sh_stdin: abi.ring.Ring(u8), ev: gui.WindowEvent) !void {
    switch (ev.event) {
        .resize => |new_fb| {
            term_lock.lock();
            defer term_lock.unlock();

            term.resize(new_fb) catch |err| {
                log.err("failed to resize terminal: {}", .{err});
            };
        },
        .keyboard_input => |kb_ev| {
            const is_shift = kb_ev.code == .left_shift or kb_ev.code == .right_shift;
            const is_ctrl = kb_ev.code == .left_control or kb_ev.code == .right_control;
            if (is_shift) shift = kb_ev.state != .release;
            if (is_ctrl) ctrl = kb_ev.state != .release;

            if (kb_ev.state == .release) return;

            const ch = if (!shift and !ctrl)
                kb_ev.code.toChar()
            else if (shift and !ctrl)
                kb_ev.code.toCharShift()
            else if (!shift and ctrl)
                kb_ev.code.toCharCtrl()
            else
                null;

            if (ch) |byte| {
                if (std.ascii.isPrint(byte) or byte == '\n') {
                    term_lock.lock();
                    defer term_lock.unlock();

                    term.writeByte(byte);
                    term.flush(false);
                }

                try sh_stdin.push(byte);
            }
        },
        else => {},
    }
}

fn mapFb(vmem: caps.Vmem, fb: gui.Framebuffer) ![]volatile u8 {
    const shmem_size = try fb.shmem.getSize();
    const shmem_addr = try vmem.map(
        fb.shmem,
        0,
        0,
        shmem_size,
        .{ .write = true },
    );

    return @as([*]volatile u8, @ptrFromInt(shmem_addr))[0..shmem_size];
}

const Pos = struct {
    x: u32 = 0,
    y: u32 = 0,
};

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
    cursor: Pos = .{},
    cursor_store: Pos = .{},

    /// cpu accessible pixel buffer
    framebuffer: gui.MappedFramebuffer,

    /// wm ipc handle, to send damaged regions
    wm_display: gui.WmDisplay,
    window: gui.Window,

    pub fn new(
        info: gui.Framebuffer,
        wm_display: gui.WmDisplay,
        window: gui.Window,
    ) !@This() {
        var self: @This() = .{
            .framebuffer = try .init(info, caps.Vmem.self),
            .wm_display = wm_display,
            .window = window,
        };

        log.debug("initial resize", .{});
        try self.resize(null);
        return self;
    }

    pub fn resize(
        self: *@This(),
        info: ?gui.Framebuffer,
    ) !void {
        if (info) |new_info|
            try self.framebuffer.update(new_info, caps.Vmem.self);

        self.framebuffer.image.fill(0xff_000000);

        const old_size = self.size;
        const fb_size = self.framebuffer.fb.size;
        self.size = .{
            .width = fb_size[0] / 8,
            .height = fb_size[1] / 16,
        };
        const old_terminal_buf_size = old_size.width * old_size.height;
        const terminal_buf_size = self.size.width * self.size.height;
        const whole_terminal_buf = try abi.mem.server_page_allocator.alloc(u8, terminal_buf_size * 2);

        for (whole_terminal_buf) |*b| {
            b.* = ' ';
        }
        for (0..@min(old_size.height, self.size.height)) |_y| {
            for (0..@min(old_size.width, self.size.width)) |_x| {
                whole_terminal_buf[_x + _y * self.size.width] =
                    self.terminal_buf_front[_x + _y * old_size.width];
            }
        }

        if (old_terminal_buf_size != 0) {
            abi.mem.server_page_allocator.free(self.terminal_buf_front.ptr[0 .. old_terminal_buf_size * 2]);
        }
        self.terminal_buf_front = whole_terminal_buf[0..terminal_buf_size];
        self.terminal_buf_back = whole_terminal_buf[terminal_buf_size..];

        self.wrapCursor();
        self.flush(true);
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
                self.cursor.x += 1;
                self.wrapCursor();

                if (self.terminal_buf_front.len == 0) return;
                self.terminal_buf_front[self.cursor.x + self.cursor.y * self.size.width] = byte;
            },
        }

        self.wrapCursor();
    }

    pub fn wrapCursor(self: *@This()) void {
        if (self.size.width == 0 or self.size.height == 0) {
            self.cursor = .{};
            return;
        }

        if (self.cursor.x >= self.size.width) {
            // wrap back to a new line
            self.cursor.x = 0;
            self.cursor.y += 1;
        }
        while (self.cursor.y >= self.size.height) {
            // scroll down, because the cursor went off screen
            self.cursor.y -= 1;

            @memset(self.terminal_buf_front[0..self.size.width], ' ');
            std.mem.rotate(u8, self.terminal_buf_front, self.size.width);
        }
    }

    pub fn flush(self: *@This(), comptime full_damage: bool) void {
        var damage: gui.Damage = .{};

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
                var to = self.framebuffer.image.subimage(x * 8, y * 16, 8, 16) catch {
                    return;
                };
                to.fillGlyph(letter, 0xFF_FFFFFF, 0xFF_000000);

                damage.addRect(.{
                    .pos = .{ @as(i32, @intCast(x)) * 8, @as(i32, @intCast(y)) * 16 },
                    .size = .{ 8, 16 },
                });
            }
        }

        const damage_aabb = if (full_damage)
            null
        else
            damage.take() orelse return;

        self.window.damage(self.wm_display, damage_aabb) catch |err| {
            log.err("failed to damage regions: {}", .{err});
        };
    }
};
