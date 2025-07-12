const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

pub fn main() !void {
    try abi.process.init();

    const stdio = try (try abi.lpc.call(
        abi.PmProtocol.GetStdioRequest,
        .{},
        .{ .cap = 1 },
    )).asErrorUnion();

    const stdout = try abi.ring.Ring(u8)
        .fromShared(stdio.stdout.ring, null);

    const stdout_writer = stdout.writer();

    try stdout_writer.print("hello from wm", .{});

    const seat_result = try abi.lpc.call(
        abi.TtyProtocol.SeatRequest,
        .{},
        abi.caps.COMMON_TTY,
    );
    const seat = try seat_result.asErrorUnion();
    defer seat.fb.close();
    defer seat.fb_info.close();
    defer seat.input.close();

    // const wm_socket_rx = try caps.Receiver.create();
    // const wm_socket_tx = try caps.Sender.create(wm_socket_rx, 0);

    // const res = try abi.lpc.call(abi.VfsProtocol.LinkRequest, .{
    //     .path = try abi.fs.Path.new("fs:///wm.sock"),
    //     .socket = caps.Handle{ .cap = wm_socket_tx.cap },
    // }, abi.caps.COMMON_VFS);
    // try res.asErrorUnion();

    var fb_info: abi.FramebufferInfoFrame = undefined;
    try seat.fb_info.read(0, std.mem.asBytes(&fb_info));

    const vmem = try caps.Vmem.self();
    defer vmem.close();

    const fb_addr = try vmem.map(
        seat.fb,
        0,
        0,
        0,
        .{ .writable = true },
        .{ .cache = .write_combining },
    );

    const fb_backbuf_frame = try caps.Frame.create(fb_info.pitch * fb_info.height);
    defer fb_backbuf_frame.close();

    const fb_backbuf_addr = try vmem.map(
        fb_backbuf_frame,
        0,
        0,
        fb_info.pitch * fb_info.height,
        .{ .writable = true },
        .{},
    );
    defer vmem.unmap(fb_backbuf_addr, fb_info.pitch * fb_info.height) catch unreachable;

    const fb = abi.util.Image([*]volatile u8){
        .width = @intCast(fb_info.width),
        .height = @intCast(fb_info.height),
        .pitch = @intCast(fb_info.pitch),
        .bits_per_pixel = fb_info.bpp,
        .pixel_array = @ptrFromInt(fb_addr),
    };

    const fb_backbuf = abi.util.Image([*]u8){
        .width = @intCast(fb_info.width),
        .height = @intCast(fb_info.height),
        .pitch = @intCast(fb_info.pitch),
        .bits_per_pixel = fb_info.bpp,
        .pixel_array = @ptrFromInt(fb_backbuf_addr),
    };

    var system: System = .{
        .fb_backbuf = fb_backbuf,
        .fb = fb,
        .fb_info = fb_info,
    };
    system.draw();

    while (true) {
        const ev_result = try abi.lpc.call(
            abi.Ps2Protocol.Next,
            .{},
            seat.input,
        );
        const ev = try ev_result.asErrorUnion();

        system.event(ev);
    }
}

const System = struct {
    // recv: caps.Receiver,

    cursor: struct {
        x: u32 = 100,
        y: u32 = 100,
    } = .{},

    window: struct {
        x: u32 = 100,
        y: u32 = 100,
        w: u32 = 300,
        h: u32 = 500,
    } = .{},

    // damage: struct {
    //     x_min: u32 = 0,
    //     x_max: u32 = 0,
    //     y_min: u32 = 0,
    //     y_max: u32 = 0,
    // } = .{},

    alt_held: bool = false,
    window_held: ?struct {
        x: u32,
        y: u32,
    } = null,

    fb_backbuf: abi.util.Image([*]u8),
    fb: abi.util.Image([*]volatile u8),
    fb_info: abi.FramebufferInfoFrame,

    fn event(self: *@This(), ev: abi.input.Event) void {
        switch (ev) {
            .keyboard => |kb_ev| self.keyboardEvent(kb_ev),
            .mouse => |m_ev| self.mouseEvent(m_ev),
        }
    }

    fn keyboardEvent(self: *@This(), ev: abi.input.KeyEvent) void {
        if (ev.code != .left_alt) return;

        if (ev.state == .press) self.alt_held = true;
        if (ev.state == .release) self.alt_held = false;
    }

    fn mouseEvent(self: *@This(), ev: abi.input.MouseEvent) void {
        switch (ev) {
            .button => |btn| self.mouseButtonEvent(btn),
            .motion => |mot| self.mouseMotionEvent(mot),
        }
    }

    fn mouseButtonEvent(self: *@This(), ev: abi.input.MouseButtonEvent) void {
        if (ev.button == .left and ev.state == .press and
            self.alt_held and
            self.cursor.x >= self.window.x and self.cursor.x <= self.window.x + self.window.w and
            self.cursor.y >= self.window.y and self.cursor.y <= self.window.y + self.window.h)
        {
            self.window_held = .{
                .x = self.cursor.x - self.window.x,
                .y = self.cursor.y - self.window.y,
            };
        }
        if (ev.button == .left and ev.state == .release and self.window_held != null) {
            self.window_held = null;
        }
    }

    fn mouseMotionEvent(self: *@This(), ev: abi.input.MouseMotionEvent) void {
        self.cursor.x = addSigned(self.cursor.x, ev.delta_x);
        self.cursor.y = addSigned(self.cursor.y, -ev.delta_y);
        self.cursor.x = @min(@max(self.cursor.x, 0), self.fb_info.width - 10);
        self.cursor.y = @min(@max(self.cursor.y, 0), self.fb_info.height - 10);

        if (self.window_held) |grab_pos| {
            self.window.x = self.cursor.x - grab_pos.x;
            self.window.y = self.cursor.y - grab_pos.y;
            self.window.x = @min(@max(self.window.x, 0), self.fb_info.width - self.window.w);
            self.window.y = @min(@max(self.window.y, 0), self.fb_info.height - self.window.h);
        }

        self.draw();

        // std.log.info("cursor {}", .{self.cursor});
    }

    fn draw(self: *@This()) void {
        defer self.fb_backbuf.copyTo(&self.fb) catch unreachable;
        self.fb_backbuf.fill(0x1A1A27);

        if (self.fb_info.width <= 10 or self.fb_info.height <= 10) return;

        const window_img = self.fb_backbuf.subimage(
            @intCast(self.window.x),
            @intCast(self.window.y),
            self.window.w,
            self.window.h,
        ) catch return;
        window_img.fill(0);

        const cursor_img = self.fb_backbuf.subimage(
            @intCast(self.cursor.x),
            @intCast(self.cursor.y),
            10,
            10,
        ) catch return;
        cursor_img.fill(0xFFFFFF);
    }
};

fn Signed(comptime T: type) type {
    var same_int = @typeInfo(T).int;
    same_int.signedness = .signed;
    return @Type(.{ .int = same_int });
}

fn addSigned(a: anytype, b: Signed(@TypeOf(a))) @TypeOf(a) {
    if (b > 0) {
        return a +| @as(@TypeOf(a), @intCast(b));
    } else {
        return a -| @as(@TypeOf(a), @intCast(-b));
    }
}
