const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const log = std.log.scoped(.wm);

//

pub fn main() !void {
    try abi.process.init();
    try abi.io.init();

    log.info("hello from wm", .{});

    const seat_result = try abi.lpc.call(
        abi.TtyProtocol.SeatRequest,
        .{},
        abi.caps.COMMON_TTY,
    );
    const seat = try seat_result.asErrorUnion();
    defer seat.fb.close();
    defer seat.fb_info.close();
    defer seat.input.close();

    const wm_socket_rx = try caps.Receiver.create();
    const wm_socket_tx = try caps.Sender.create(wm_socket_rx, 0);

    const res = try abi.lpc.call(abi.VfsProtocol.LinkRequest, .{
        .path = try abi.fs.Path.new("fs:///wm.sock"),
        .socket = caps.Handle{ .cap = wm_socket_tx.cap },
    }, abi.caps.COMMON_VFS);
    try res.asErrorUnion();

    exec("initfs:///sbin/term") catch |err| {
        log.err("failed to exec initial app: {}", .{err});
    };

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

    const cursor_fb = abi.util.Image([*]const u8){
        .width = 16,
        .height = 16,
        .pitch = 64,
        .bits_per_pixel = 32,
        .pixel_array = std.mem.asBytes(&cursor_pixels),
    };

    system_lock = try .newLocked();
    system = .{
        .fb_backbuf = fb_backbuf,
        .fb = fb,
        .fb_info = fb_info,

        .cursor_fb = cursor_fb,

        // damage everything initially, so that everything is drawn
        .damage = .{
            .min = .{
                .x = 0,
                .y = 0,
            },
            .max = .{
                .x = @min(std.math.maxInt(i32), fb_info.width),
                .y = @min(std.math.maxInt(i32), fb_info.height),
            },
        },
    };
    system_lock.unlock();

    try abi.thread.spawn(connectionThreadMain, .{wm_socket_rx});
    try abi.thread.spawn(inputThreadMain, .{seat.input});
    try compositorThreadMain();
}

var cursor_pixels = b: {
    var pixels: [16 * 16]u32 = [1]u32{0} ** (16 * 16);

    for (0..16) |yo| {
        for (0..16) |xo| {
            if (xo <= yo and (xo * xo) + (yo * yo) <= 15 * 15 - 1) {
                if (xo == 0 or xo == yo or (xo * xo) + (yo * yo) >= 14 * 14 + 1) {
                    pixels[xo + yo * 16] = 0xff_ffffff;
                } else {
                    pixels[xo + yo * 16] = 0xff_000000;
                }
            }
        }
    }

    break :b pixels;
};

fn exec(path: []const u8) !void {
    const initial_app = try abi.lpc.call(abi.PmProtocol.ExecElfRequest, .{
        .arg_map = try caps.Frame.init(path),
        .env_map = try caps.Frame.init("WM_SOCKET=fs:///wm.sock"),
        .stdio = .{
            .stdin = .{ .none = {} },
            .stdout = .{ .none = {} },
            .stderr = .{ .none = {} },
        },
    }, abi.caps.COMMON_PM);
    _ = try initial_app.asErrorUnion();
}

fn compositorThreadMain() !void {
    const frametime_ns: u32 = 16_666_667;
    const _nanos = try abi.caps.COMMON_HPET.call(.timestamp, {});
    var nanos: u128 = _nanos.@"0";
    while (true) {
        system_lock.lock();
        system.draw();
        system_lock.unlock();

        nanos += frametime_ns;
        _ = abi.caps.COMMON_HPET.call(.sleepDeadline, .{nanos}) catch break;
    }
}

fn inputThreadMain(input: caps.Sender) !void {
    while (true) {
        const ev_result = try abi.lpc.call(
            abi.Ps2Protocol.Next,
            .{},
            input,
        );
        const ev = try ev_result.asErrorUnion();

        system_lock.lock();
        system.event(ev) catch |err| {
            log.err("event handler failure: {}", .{err});
        };
        system_lock.unlock();
    }
}

fn connectionThreadMain(rx: caps.Receiver) !void {
    abi.lpc.daemon(ConnectionContext{
        .recv = rx,
    });
}

fn connectRequest(
    _: *abi.lpc.Daemon(ConnectionContext),
    handler: abi.lpc.Handler(abi.WmProtocol.ConnectRequest),
) !void {
    errdefer handler.reply.send(.{ .err = .internal });

    const rx = try caps.Receiver.create();
    const tx = try caps.Sender.create(rx, 0);

    try abi.thread.spawn(clientConnectionThreadMain, .{rx});

    handler.reply.send(.{ .ok = tx });
}

const ConnectionContext = struct {
    recv: caps.Receiver,

    pub const routes = .{
        connectRequest,
    };
    pub const Request = abi.WmProtocol.Request;
};

fn clientConnectionThreadMain(rx: caps.Receiver) !void {
    abi.lpc.daemon(DisplayContext{
        .recv = rx,
        .conn = .{},
    });
}

fn createWindowRequest(
    daemon: *abi.lpc.Daemon(DisplayContext),
    handler: abi.lpc.Handler(abi.WmDisplayProtocol.CreateWindowRequest),
) !void {
    const shmem = createShmem(handler.req.size) catch |err| {
        log.warn("could not create window framebuffer shmem: {}", .{err});
        return handler.reply.send(.{ .err = .internal });
    };
    // wm server doesnt use the shmem frame handle after it is mapped,
    // it is either replaced or unmapped after the mapping
    // -> it can be sent via IPC without cloning

    system_lock.lock();
    defer system_lock.unlock();

    const client_id = daemon.ctx.conn.next_client_window_id;
    daemon.ctx.conn.next_client_window_id += 1;
    const server_id = system.next_server_window_id;
    system.next_server_window_id += 1;

    var window = Window{
        .client_id = client_id,
        .server_id = server_id,
        .pos = .{
            .x = 100,
            .y = 100,
        },
        .size = shmem.size,

        // the window is closed before the connection, so the pointer stays valid
        .conn = &daemon.ctx.conn,
    };
    window.attach(shmem) catch |err| {
        log.warn("could not attach window framebuffer shmem: {}", .{err});
        daemon.ctx.conn.next_client_window_id = client_id;
        system.next_server_window_id = server_id;
        return handler.reply.send(.{ .err = .internal });
    };

    system.windows.putNoClobber(server_id, window) catch {
        daemon.ctx.conn.next_client_window_id = client_id;
        system.next_server_window_id = server_id;
        handler.reply.send(.{ .err = .out_of_memory });
        return;
    };

    daemon.ctx.conn.window_server_ids.putNoClobber(client_id, server_id) catch {
        daemon.ctx.conn.next_client_window_id = client_id;
        system.next_server_window_id = server_id;
        _ = system.windows.remove(server_id);
        handler.reply.send(.{ .err = .out_of_memory });
        return;
    };

    system.addWindowDamage(window.pos, shmem.size);

    handler.reply.send(.{ .ok = .{
        .fb = shmem,
        .window_id = client_id,
    } });
}

fn shmemInfo(w: u32, h: u32) error{Overflow}!struct { pitch: u32, bytes: u32 } {
    const real_width = try std.math.ceilPowerOfTwo(u32, w);
    const bytes = try std.math.mul(
        u32,
        try std.math.mul(
            u32,
            real_width,
            try std.math.ceilPowerOfTwo(u32, h),
        ),
        4,
    );

    return .{ .pitch = real_width * 4, .bytes = bytes };
}

fn createShmem(size: abi.WmDisplayProtocol.Size) !abi.WmDisplayProtocol.NewFramebuffer {
    const shmem_info = try shmemInfo(
        size.width,
        size.height,
    );

    const shmem = try caps.Frame.create(shmem_info.bytes);

    log.debug("new shmem for fb", .{});

    return .{
        .shmem = shmem,
        .size = size,
        .pitch = shmem_info.pitch,
        .bytes = shmem_info.bytes,
    };
}

fn updateShmem(
    old: abi.WmDisplayProtocol.NewFramebuffer,
    new: abi.WmDisplayProtocol.Size,
) !?abi.WmDisplayProtocol.NewFramebuffer {
    const new_info = try shmemInfo(new.width, new.height);
    if (old.bytes >= new_info.bytes) {
        // the old shmem can already hold the new framebuffer
        return null;
    }

    return try createShmem(new);
}

fn nextEventRequest(
    daemon: *abi.lpc.Daemon(DisplayContext),
    handler: abi.lpc.Handler(abi.WmDisplayProtocol.NextEventRequest),
) !void {
    system_lock.lock();
    defer system_lock.unlock();

    try daemon.ctx.conn.popEvent(handler.reply);
}

fn damage(
    daemon: *abi.lpc.Daemon(DisplayContext),
    handler: abi.lpc.Handler(abi.WmDisplayProtocol.Damage),
) !void {
    const min_x = @min(handler.req.min.x, handler.req.max.x);
    const max_x = @max(handler.req.min.x, handler.req.max.x);
    const min_y = @min(handler.req.min.y, handler.req.max.y);
    const max_y = @max(handler.req.min.y, handler.req.max.y);

    if (min_x == max_x or min_y == max_y) {
        handler.reply.send(.{ .ok = {} });
        return;
    }

    system_lock.lock();
    defer system_lock.unlock();

    const window_id: usize = daemon.ctx.conn.window_server_ids
        .get(handler.req.window_id) orelse {
        handler.reply.send(.{ .err = .bad_handle });
        return;
    };

    const window = system.windows.get(window_id) orelse {
        log.err("server_id resolved from a client_id does not match any window", .{});
        handler.reply.send(.{ .err = .internal });
        return;
    };

    const clipped_min_x: i32 = @max(min_x, 0);
    const clipped_max_x: i32 = @min(max_x, @min(std.math.maxInt(i32), window.size.width));
    const clipped_min_y: i32 = @max(min_y, 0);
    const clipped_max_y: i32 = @min(max_y, @min(std.math.maxInt(i32), window.size.height));

    system.addDamage(.{
        .x = window.pos.x +| clipped_min_x,
        .y = window.pos.y +| clipped_min_y,
    }, .{
        .x = window.pos.x +| clipped_max_x,
        .y = window.pos.y +| clipped_max_y,
    });

    handler.reply.send(.{ .ok = {} });
}

const DisplayContext = struct {
    recv: caps.Receiver,
    conn: Connection,

    pub const routes = .{
        createWindowRequest,
        nextEventRequest,
        damage,
    };
    pub const Request = abi.WmDisplayProtocol.Request;
};

var system: System = undefined;
var system_lock: abi.lock.CapMutex = undefined;

const Connection = struct {
    next_client_window_id: usize = 1,
    window_server_ids: std.AutoHashMap(usize, usize) = .init(abi.mem.slab_allocator),

    event_queue: std.fifo.LinearFifo(abi.WmDisplayProtocol.Event, .Dynamic) = .init(abi.mem.slab_allocator),
    reply: ?abi.lpc.DetachedReply(abi.WmDisplayProtocol.NextEventRequest.Response) = null,

    pub fn pushEvent(self: *@This(), ev: abi.WmDisplayProtocol.Event) void {
        if (self.reply) |*reply| {
            reply.send(.{ .ok = ev }) catch |err| {
                log.warn("failed to send input event reply: {}", .{err});
            };
            self.reply = null;
            return;
        }

        self.event_queue.writeItem(ev) catch |err| {
            log.warn("input event dropped: {}", .{err});
        };
    }

    pub fn popEvent(self: *@This(), reply: *abi.lpc.Reply(abi.WmDisplayProtocol.NextEventRequest.Response)) !void {
        if (self.reply != null) {
            reply.send(.{ .err = .thread_safety });
            return;
        }

        if (self.event_queue.readItem()) |ev| {
            reply.send(.{ .ok = ev });
            return;
        }

        self.reply = try reply.detach();
    }
};

const Window = struct {
    client_id: usize,
    server_id: usize,
    pos: abi.WmDisplayProtocol.Position,
    size: abi.WmDisplayProtocol.Size,

    fb: ?Framebuffer = null,

    conn: *Connection,

    pub fn deinit(self: @This()) void {
        if (self.fb) |fb| fb.deinit();
    }

    pub fn pushEvent(self: *const @This(), ev: abi.WmDisplayProtocol.WindowEvent.Inner) void {
        self.conn.pushEvent(.{ .window = .{
            .window_id = self.client_id,
            .event = ev,
        } });
    }

    pub fn attach(self: *@This(), shmem: abi.WmDisplayProtocol.NewFramebuffer) !void {
        if (self.fb) |old| old.deinit();
        self.fb = try Framebuffer.init(shmem);
    }

    pub fn resize(self: *@This()) !void {
        if (self.fb) |*fb| {
            try fb.resize(self.size, self.conn, self.client_id);
        } else {
            self.fb = try Framebuffer.init(try createShmem(self.size));
        }
    }
};

const Framebuffer = struct {
    /// frame field in shmem is not valid, it is always sent to the client
    shmem: abi.WmDisplayProtocol.NewFramebuffer,
    fb: abi.util.Image([*]volatile u8),

    pub fn init(shmem: abi.WmDisplayProtocol.NewFramebuffer) !@This() {
        const vmem = caps.Vmem.self() catch unreachable;
        defer vmem.close();

        const shmem_addr = try vmem.map(
            shmem.shmem,
            0,
            0,
            shmem.bytes,
            .{},
            .{},
        );

        const fb = abi.util.Image([*]volatile u8){
            .width = shmem.size.width,
            .height = shmem.size.height,
            .pitch = shmem.pitch,
            .bits_per_pixel = 32,
            .pixel_array = @ptrFromInt(shmem_addr),
        };

        return .{
            .fb = fb,
            .shmem = .{
                .shmem = .{},
                .pitch = shmem.pitch,
                .size = shmem.size,
                .bytes = shmem.bytes,
            },
        };
    }

    pub fn deinit(self: @This()) void {
        const vmem = caps.Vmem.self() catch unreachable;
        defer vmem.close();

        vmem.unmap(
            @intFromPtr(self.fb.pixel_array),
            self.shmem.bytes,
        ) catch unreachable;
    }

    pub fn resize(
        self: *@This(),
        size: abi.WmDisplayProtocol.Size,
        resize_event_conn: *Connection,
        resize_event_window_id: usize,
    ) !void {
        if (try updateShmem(self.shmem, size)) |new| {
            self.deinit();
            self.* = try Framebuffer.init(new);

            resize_event_conn.pushEvent(.{ .window = .{
                .window_id = resize_event_window_id,
                .event = .{ .resize = new },
            } });
        } else {
            self.fb.width = size.width;
            self.fb.height = size.height;
            self.shmem.size = size;

            resize_event_conn.pushEvent(.{ .window = .{
                .window_id = resize_event_window_id,
                .event = .{ .resize = self.shmem },
            } });
        }
    }
};

const HeldWindow = union(enum) {
    moving: struct {
        window_id: usize,
        // initial window-cursor relative dragging start position
        offs: abi.WmDisplayProtocol.Position,
    },
    resizing: struct {
        window_id: usize,
        init_cursor: abi.WmDisplayProtocol.Position,
        init_window_pos: abi.WmDisplayProtocol.Position,
        corner: Corner,
    },
    none: void,
};

const Corner = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
};

const System = struct {
    // recv: caps.Receiver,

    cursor: abi.WmDisplayProtocol.Position = .{
        .x = 100,
        .y = 100,
    },

    next_server_window_id: usize = 0,
    windows: std.AutoHashMap(usize, Window) = .init(abi.mem.slab_allocator),

    damage: struct {
        min: abi.WmDisplayProtocol.Position = .{ .x = 0, .y = 0 },
        max: abi.WmDisplayProtocol.Position = .{ .x = 0, .y = 0 },
    } = .{},

    alt_held: bool = false,
    held_window: HeldWindow = .{ .none = {} },

    fb_backbuf: abi.util.Image([*]u8),
    fb: abi.util.Image([*]volatile u8),
    fb_info: abi.FramebufferInfoFrame,

    cursor_fb: abi.util.Image([*]const u8),

    fn event(self: *@This(), ev: abi.input.Event) !void {
        switch (ev) {
            .keyboard => |kb_ev| self.keyboardEvent(kb_ev),
            .mouse => |m_ev| try self.mouseEvent(m_ev),
        }
    }

    fn keyboardEvent(self: *@This(), ev: abi.input.KeyEvent) void {
        if (ev.code == .left_alt and ev.state == .press) {
            self.alt_held = true;
        }
        if (ev.code == .left_alt and ev.state == .release) {
            self.alt_held = false;
        }
        if (ev.code == .enter and ev.state == .press and self.alt_held) {
            exec("initfs:///sbin/term") catch {};
            return;
        }

        const window = self.findHoveredWindow() orelse return;
        window.pushEvent(.{ .keyboard_input = ev });
    }

    fn mouseEvent(self: *@This(), ev: abi.input.MouseEvent) !void {
        switch (ev) {
            .button => |btn| self.mouseButtonEvent(btn),
            .motion => |mot| try self.mouseMotionEvent(mot),
        }
    }

    fn mouseButtonEvent(self: *@This(), ev: abi.input.MouseButtonEvent) void {
        if (ev.button == .left and ev.state == .press and self.alt_held) {
            self.moveWindow();
            return;
        }
        if (ev.button == .right and ev.state == .press and self.alt_held) {
            self.resizeWindow();
            return;
        }
        if ((ev.button == .left or ev.button == .right) and ev.state == .release) {
            self.held_window = .{ .none = {} };
            return;
        }

        const window = self.findHoveredWindow() orelse return;
        window.pushEvent(.{ .mouse_button = ev });
    }

    fn moveWindow(self: *@This()) void {
        if (self.findHoveredWindow()) |window| {
            self.held_window = .{ .moving = .{
                .window_id = window.server_id,
                .offs = .{
                    .x = self.cursor.x - window.pos.x,
                    .y = self.cursor.y - window.pos.y,
                },
            } };
        }
    }

    fn resizeWindow(self: *@This()) void {
        if (self.findHoveredWindow()) |window| {
            const middle_x = window.pos.x +| @as(i32, @intCast(window.size.width / 2));
            const middle_y = window.pos.y +| @as(i32, @intCast(window.size.height / 2));

            const corner = if (self.cursor.x < middle_x and self.cursor.y < middle_y)
                Corner.top_left
            else if (self.cursor.x >= middle_x and self.cursor.y < middle_y)
                Corner.top_right
            else if (self.cursor.x < middle_x and self.cursor.y >= middle_y)
                Corner.bottom_left
            else if (self.cursor.x >= middle_x and self.cursor.y >= middle_y)
                Corner.bottom_right
            else
                unreachable;

            self.held_window = .{ .resizing = .{
                .window_id = window.server_id,
                .init_cursor = self.cursor,
                .init_window_pos = window.pos,
                .corner = corner,
            } };
        }
    }

    /// the returned pointer is valid as long as the `windows` hashmap is not modified
    fn findHoveredWindow(self: *@This()) ?*Window {
        var it = self.windows.valueIterator();
        while (it.next()) |window| {
            if (self.cursor.x >= window.pos.x and
                self.cursor.y >= window.pos.y and
                @as(isize, self.cursor.x) <= @as(isize, window.pos.x) + window.size.width and
                @as(isize, self.cursor.y) <= @as(isize, window.pos.y) + window.size.height)
            {
                return window;
            }
        }

        return null;
    }

    fn mouseMotionEvent(self: *@This(), ev: abi.input.MouseMotionEvent) !void {
        if (ev.delta_z != 0) {
            self.forwardMouseWheel(ev.delta_z);
        }
        if (ev.delta_x != 0 or ev.delta_y != 0) {
            try self.cursorMoveEvent(ev.delta_x, ev.delta_y);
        }
    }

    fn cursorMoveEvent(self: *@This(), delta_x: i16, delta_y: i16) !void {
        self.addRectDamage(self.cursor, .{ .width = 16, .height = 16 });
        self.cursor.x +|= delta_x;
        self.cursor.y +|= -delta_y;
        self.cursor.x = @min(@max(self.cursor.x, 0), self.fb_info.width -| 1);
        self.cursor.y = @min(@max(self.cursor.y, 0), self.fb_info.height -| 1);
        self.addRectDamage(self.cursor, .{ .width = 16, .height = 16 });

        switch (self.held_window) {
            .moving => |moving| {
                const window = self.windows.getPtr(moving.window_id) orelse unreachable;
                system.addWindowDamage(window.pos, window.size);
                window.pos.x = self.cursor.x -| moving.offs.x;
                window.pos.y = self.cursor.y -| moving.offs.y;
                system.addWindowDamage(window.pos, window.size);
            },
            .resizing => |*resizing| {
                const window = self.windows.getPtr(resizing.window_id) orelse unreachable;
                system.addWindowDamage(window.pos, window.size);

                var min_x: i32 = window.pos.x;
                var min_y: i32 = window.pos.y;
                var max_x: i32 = window.pos.x +| @min(std.math.maxInt(i32), window.size.width);
                var max_y: i32 = window.pos.y +| @min(std.math.maxInt(i32), window.size.height);

                switch (resizing.corner) {
                    .top_left => {
                        min_x += self.cursor.x -| resizing.init_cursor.x;
                        min_y += self.cursor.y -| resizing.init_cursor.y;
                    },
                    .top_right => {
                        max_x += self.cursor.x -| resizing.init_cursor.x;
                        min_y += self.cursor.y -| resizing.init_cursor.y;
                    },
                    .bottom_left => {
                        min_x += self.cursor.x -| resizing.init_cursor.x;
                        max_y += self.cursor.y -| resizing.init_cursor.y;
                    },
                    .bottom_right => {
                        max_x += self.cursor.x -| resizing.init_cursor.x;
                        max_y += self.cursor.y -| resizing.init_cursor.y;
                    },
                }
                resizing.init_cursor = self.cursor;

                window.pos.x = min_x;
                window.pos.y = min_y;
                window.size.width = @intCast(@max(10, max_x - min_x));
                window.size.height = @intCast(@max(10, max_y - min_y));

                system.addWindowDamage(window.pos, window.size);
                try window.resize();
            },
            .none => {},
        }

        // log.info("cursor={}", .{self.cursor});
        self.forwardCursorMove();
    }

    fn forwardMouseWheel(self: *@This(), delta_z: i16) void {
        const window = self.findHoveredWindow() orelse return;
        window.pushEvent(.{ .mouse_wheel = delta_z });
    }

    fn forwardCursorMove(self: *@This()) void {
        const window = self.findHoveredWindow() orelse return;

        if (self.cursor.x < window.pos.x or self.cursor.y < window.pos.y)
            return;

        const window_relative_cursor: abi.WmDisplayProtocol.Position = .{
            .x = self.cursor.x - window.pos.x,
            .y = self.cursor.y - window.pos.y,
        };

        if (window_relative_cursor.x >= window.size.width or
            window_relative_cursor.y >= window.size.height)
            return;

        window.pushEvent(.{ .cursor_moved = window_relative_cursor });
    }

    fn addWindowDamage(
        self: *@This(),
        pos: abi.WmDisplayProtocol.Position,
        size: abi.WmDisplayProtocol.Size,
    ) void {
        self.addRectDamage(.{
            .x = pos.x -| 1,
            .y = pos.y -| 1,
        }, .{
            .width = size.width +| 2,
            .height = size.height +| 2,
        });
    }

    fn addRectDamage(
        self: *@This(),
        pos: abi.WmDisplayProtocol.Position,
        size: abi.WmDisplayProtocol.Size,
    ) void {
        self.addDamage(.{
            .x = pos.x,
            .y = pos.y,
        }, .{
            .x = pos.x +| @min(std.math.maxInt(i32), size.width),
            .y = pos.y +| @min(std.math.maxInt(i32), size.height),
        });
    }

    fn addDamage(
        self: *@This(),
        min: abi.WmDisplayProtocol.Position,
        max: abi.WmDisplayProtocol.Position,
    ) void {
        if (self.damage.min.x == self.damage.max.x or
            self.damage.min.y == self.damage.max.y)
        {
            // the damage was previously zero,
            // so instead of extending from the [0,0],
            // move the damage to the added damage

            self.damage.min = min;
            self.damage.max = max;
            return;
        }

        self.damage.min.x = @min(self.damage.min.x, min.x);
        self.damage.max.x = @max(self.damage.max.x, max.x);
        self.damage.min.y = @min(self.damage.min.y, min.y);
        self.damage.max.y = @max(self.damage.max.y, max.y);
    }

    fn draw(self: *@This()) void {
        const damage_x = @max(0, self.damage.min.x);
        const damage_y = @max(0, self.damage.min.y);
        const damage_width: u32 = @intCast(self.damage.max.x - self.damage.min.x);
        const damage_height: u32 = @intCast(self.damage.max.y - self.damage.min.y);
        self.damage = .{};
        if (damage_width == 0 or damage_height == 0) return;

        // log.debug("damage: pos=[{},{}] size=[{},{}]", .{
        //     damage_x,
        //     damage_y,
        //     damage_width,
        //     damage_height,
        // });

        const fb = self.fb.imageAabbIntersect(
            0,
            0,
            damage_width,
            damage_height,
            damage_x,
            damage_y,
        ) orelse return;
        const fb_backbuf = self.fb_backbuf.imageAabbIntersect(
            0,
            0,
            damage_width,
            damage_height,
            damage_x,
            damage_y,
        ) orelse return;

        // draw the background in the damaged area
        fb_backbuf.fill(0xFF1A1A27);

        // draw all windows in the damaged area
        var it = self.windows.valueIterator();
        while (it.next()) |window| {
            const window_fb = (window.fb orelse return).fb;

            // draw window borders
            if (fb_backbuf.imageAabbIntersect(
                damage_x,
                damage_y,
                window.size.width + 2,
                window.size.height + 2,
                window.pos.x -| 1,
                window.pos.y -| 1,
            )) |rect| {
                rect.fillHollow(0xff_353535, 1);
            }

            // draw window contents
            const visible_window = window_fb.subimage(
                0,
                0,
                @min(window_fb.width, window.size.width),
                @min(window_fb.height, window.size.height),
            ) catch continue;
            if (fb_backbuf.intersection(
                damage_x,
                damage_y,
                visible_window,
                window.pos.x,
                window.pos.y,
            )) |rects| {
                rects[1].blitTo(rects[0]) catch {};
            }
        }

        // draw cursor
        if (fb_backbuf.intersection(
            damage_x,
            damage_y,
            self.cursor_fb,
            self.cursor.x,
            self.cursor.y,
        )) |rects| {
            rects[1].blitTo(rects[0]) catch {};
        }

        // fb.fill(0xff_ff00ff);
        // for (0..2_000_000) |_| std.atomic.spinLoopHint();

        // copy the data to the actual framebuffer
        fb_backbuf.copyTo(&fb) catch unreachable;
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
