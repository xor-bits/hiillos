const std = @import("std");
const abi = @import("abi");
const gui = @import("gui");

const caps = abi.caps;
const log = std.log.scoped(.wm);
const gpa = abi.mem.slab_allocator;

/// in pixels
const window_borders = 1;

/// in pixels
const min_window_size: gui.Pos = @splat(10);

const unfocused_border_colour = gui.Colour{
    .red = 0x25,
    .green = 0x25,
    .blue = 0x25,
};

const focused_border_colour = gui.Colour{
    .red = 0x31,
    .green = 0xc0,
    .blue = 0xf0,
};

const background_colour = gui.Colour{
    .red = 0x1a,
    .green = 0x1a,
    .blue = 0x27,
};

const WindowNode = std.DoublyLinkedList(Window).Node;

//

pub fn main() !void {
    try abi.rt.init();

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

    const cursor_fb = try gui.openImage(
        abi.mem.slab_allocator,
        "initfs:///cursor.qoi",
    );

    system = .{
        .fb_backbuf = fb_backbuf,
        .fb = fb,
        .fb_info = fb_info,

        // damage everything initially, so that everything is drawn
        .damage = .full(),

        .display = .{
            .min = @splat(0),
            .max = .{
                @min(std.math.maxInt(i32), fb_info.width),
                @min(std.math.maxInt(i32), fb_info.height),
            },
        },

        .cursor_fb = cursor_fb,
        .cursor_size = .{ cursor_fb.width, cursor_fb.height },
    };
    system_lock.unlock();

    try abi.thread.spawn(connectionThreadMain, .{wm_socket_rx});
    try abi.thread.spawn(inputThreadMain, .{seat.input});
    compositorThreadMain();
}

fn exec(path: []const u8) !void {
    const initial_app = try abi.lpc.call(abi.PmProtocol.ExecElfRequest, .{
        .arg_map = try caps.Frame.init(path),
        .env_map = try abi.process.deriveEnvMap(&.{}, &[_]abi.process.Var{.{
            .name = "WM_SOCKET",
            .value = "fs:///wm.sock",
        }}),
        .stdio = .{
            .stdin = .{ .none = {} },
            .stdout = .{ .none = {} },
            .stderr = .{ .none = {} },
        },
    }, abi.caps.COMMON_PM);
    _ = try initial_app.asErrorUnion();
}

fn compositorThreadMain() noreturn {
    const frametime_ns: u32 = 16_666_667;
    var nanos = abi.time.nanoTimestamp();
    while (true) {
        system_lock.lock();
        system.draw();
        system_lock.unlock();

        nanos += frametime_ns;
        abi.time.sleepDeadline(nanos);
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
        defer system_lock.unlock();

        system.event(ev) catch |err| {
            log.err("event handler failure: {}", .{err});
        };
    }
}

fn connectionThreadMain(rx: caps.Receiver) !void {
    abi.lpc.daemon(ConnectionContext{
        .recv = rx,
    });
}

fn connectRequest(
    _: *abi.lpc.Daemon(ConnectionContext),
    handler: abi.lpc.Handler(gui.WmProtocol.Connect),
) !void {
    errdefer handler.reply.send(.{ .err = .internal });

    const rx = try caps.Receiver.create();
    const tx = try caps.Sender.create(rx, 0);

    try abi.thread.spawn(clientConnectionThreadMain, .{rx});

    handler.reply.send(.{ .ok = .{
        .sender = tx,
    } });
}

const ConnectionContext = struct {
    recv: caps.Receiver,

    pub const routes = .{
        connectRequest,
    };
    pub const Request = gui.WmProtocol.Request;
};

fn clientConnectionThreadMain(rx: caps.Receiver) !void {
    abi.lpc.daemon(DisplayContext{
        .recv = rx,
        .conn = .{},
    });
}

fn createWindowRequest(
    daemon: *abi.lpc.Daemon(DisplayContext),
    handler: abi.lpc.Handler(gui.WmDisplayProtocol.CreateWindow),
) !void {
    const shmem = gui.Framebuffer.init(handler.req.size) catch |err| {
        log.warn("could not create window framebuffer shmem: {}", .{err});
        return handler.reply.send(.{ .err = .internal });
    };
    // wm server doesnt use the shmem frame handle after it is mapped,
    // it is either replaced or unmapped after the mapping
    // -> it can be sent via IPC without cloning

    system_lock.lock();
    defer system_lock.unlock();

    const result = system.addWindow(&daemon.ctx.conn, shmem) catch |err| {
        log.err("internal error while trying to create a window: {}", .{err});
        return handler.reply.send(.{ .err = .out_of_memory });
    };

    handler.reply.send(.{ .ok = .{
        .fb = shmem,
        .window_id = result.client_id,
    } });
}

fn nextEventRequest(
    daemon: *abi.lpc.Daemon(DisplayContext),
    handler: abi.lpc.Handler(gui.WmDisplayProtocol.NextEvent),
) !void {
    system_lock.lock();
    defer system_lock.unlock();

    try daemon.ctx.conn.popEvent(handler.reply);
}

fn damage(
    daemon: *abi.lpc.Daemon(DisplayContext),
    handler: abi.lpc.Handler(gui.WmDisplayProtocol.Damage),
) !void {
    var relative_area = handler.req.area.fix();
    if (relative_area.isEmpty()) {
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

    const window = system.windows_map.get(window_id) orelse {
        log.err("server_id resolved from a client_id does not match any window", .{});
        handler.reply.send(.{ .err = .internal });
        return;
    };

    relative_area.min +|= window.rect.pos;
    relative_area.max +|= window.rect.pos;

    const clipped_area = relative_area.intersect(window.rect.asAabb()) orelse {
        handler.reply.send(.{ .ok = {} });
        return;
    };

    system.damage.addAabb(clipped_area);
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
    pub const Request = gui.WmDisplayProtocol.Request;
};

var system: System = undefined;
var system_lock: abi.thread.Mutex = .locked();

const Connection = struct {
    next_client_window_id: usize = 1,
    window_server_ids: std.AutoHashMap(usize, usize) = .init(abi.mem.slab_allocator),

    event_queue: std.fifo.LinearFifo(gui.Event, .Dynamic) = .init(abi.mem.slab_allocator),
    reply: ?abi.lpc.DetachedReply(gui.WmDisplayProtocol.NextEvent.Response) = null,

    pub fn pushEvent(
        self: *@This(),
        ev: gui.Event,
    ) void {
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

    pub fn popEvent(
        self: *@This(),
        reply: *abi.lpc.Reply(gui.WmDisplayProtocol.NextEvent.Response),
    ) !void {
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
    rect: gui.Rect,

    fb: ?Framebuffer = null,

    conn: *Connection,

    pub fn deinit(self: @This()) void {
        if (self.fb) |fb| fb.deinit();
    }

    pub fn pushEvent(self: *const @This(), ev: gui.WindowEvent.Inner) void {
        self.conn.pushEvent(.{ .window = .{
            .window_id = self.client_id,
            .event = ev,
        } });
    }

    pub fn attach(self: *@This(), shmem: gui.Framebuffer) !void {
        if (self.fb) |old| old.deinit();
        self.fb = try Framebuffer.init(shmem);
    }

    pub fn resize(self: *@This()) !void {
        if (self.fb) |*fb| {
            try fb.resize(self.rect.size, self.conn, self.client_id);
        } else {
            self.fb = try Framebuffer.init(try gui.Framebuffer.init(self.rect.size));
        }
    }
};

const Framebuffer = struct {
    /// frame field in shmem is not valid, it is always sent to the client
    shmem: gui.Framebuffer,
    fb: abi.util.Image([*]volatile u8),

    pub fn init(shmem: gui.Framebuffer) !@This() {
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
            .width = shmem.size[0],
            .height = shmem.size[1],
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
        size: gui.Size,
        resize_event_conn: *Connection,
        resize_event_window_id: usize,
    ) !void {
        if (@reduce(.And, self.shmem.size == size)) {
            return;
        } else if (try self.shmem.update(size)) |new| {
            self.deinit();
            self.* = try Framebuffer.init(new);

            resize_event_conn.pushEvent(.{ .window = .{
                .window_id = resize_event_window_id,
                .event = .{ .resize = new },
            } });
        } else {
            self.fb.width = size[0];
            self.fb.height = size[1];
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
        offs: gui.Pos,
    },
    resizing: struct {
        window_id: usize,
        init_cursor: gui.Pos,
        init_window_pos: gui.Pos,
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

    cursor: gui.Pos = .{ 100, 100 },

    next_server_window_id: usize = 0,
    windows_map: std.AutoHashMap(usize, *Window) = .init(abi.mem.slab_allocator),
    windows_list: std.DoublyLinkedList(Window) = .{},

    damage: gui.Damage = .{},

    alt_held: bool = false,
    held_window: HeldWindow = .{ .none = {} },

    fb_backbuf: abi.util.Image([*]u8),
    fb: abi.util.Image([*]volatile u8),
    fb_info: abi.FramebufferInfoFrame,
    display: gui.Aabb,

    cursor_fb: abi.util.Image([]u8),
    cursor_size: gui.Size,

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

        const window = self.focusedWindow() orelse return;
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
        self.focusWindow(window);
        window.pushEvent(.{ .mouse_button = ev });
    }

    fn moveWindow(self: *@This()) void {
        if (self.findHoveredWindow()) |window| {
            self.focusWindow(window);

            self.held_window = .{ .moving = .{
                .window_id = window.server_id,
                .offs = self.cursor -| window.rect.pos,
            } };
        }
    }

    fn resizeWindow(self: *@This()) void {
        if (self.findHoveredWindow()) |window| {
            self.focusWindow(window);

            const middle = window.rect.middle();

            const corner = if (self.cursor[0] < middle[0] and self.cursor[1] < middle[1])
                Corner.top_left
            else if (self.cursor[0] >= middle[0] and self.cursor[1] < middle[1])
                Corner.top_right
            else if (self.cursor[0] < middle[0] and self.cursor[1] >= middle[1])
                Corner.bottom_left
            else if (self.cursor[0] >= middle[0] and self.cursor[1] >= middle[1])
                Corner.bottom_right
            else
                unreachable;

            self.held_window = .{ .resizing = .{
                .window_id = window.server_id,
                .init_cursor = self.cursor,
                .init_window_pos = window.rect.pos,
                .corner = corner,
            } };
        }
    }

    /// the returned pointer is valid as long as the `windows` hashmap is not modified
    fn findHoveredWindow(self: *@This()) ?*Window {
        var it = self.windows_list.last;
        while (it) |node| {
            it = node.prev;
            const window = &node.data;

            const window_aabb = window.rect.asAabb();

            if (@reduce(.And, self.cursor >= window_aabb.min) and
                @reduce(.And, self.cursor <= window_aabb.max))
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
        self.damage.addRect(.{ .pos = self.cursor, .size = self.cursor_size });
        self.cursor +|= gui.Pos{ delta_x, -delta_y };
        self.cursor = gui.clamp(self.cursor, self.display);
        self.damage.addRect(.{ .pos = self.cursor, .size = self.cursor_size });

        switch (self.held_window) {
            .moving => |moving| {
                const window = self.windows_map.get(moving.window_id) orelse unreachable;
                system.damage.addAabb(window.rect.asAabb().border(window_borders));
                window.rect.pos = self.cursor -| moving.offs;
                system.damage.addAabb(window.rect.asAabb().border(window_borders));
            },
            .resizing => |*resizing| {
                const window = self.windows_map.get(resizing.window_id) orelse unreachable;
                system.damage.addAabb(window.rect.asAabb().border(window_borders));

                var window_aabb = window.rect.asAabb();

                switch (resizing.corner) {
                    .top_left => {
                        window_aabb.min += self.cursor -| resizing.init_cursor;
                        window_aabb.min = @min(window_aabb.min, window_aabb.max -| min_window_size);
                    },
                    .top_right => {
                        window_aabb.max[0] += self.cursor[0] -| resizing.init_cursor[0];
                        window_aabb.min[1] += self.cursor[1] -| resizing.init_cursor[1];
                        window_aabb.max[0] = @max(window_aabb.max[0], window_aabb.min[0] +| min_window_size[0]);
                        window_aabb.min[1] = @min(window_aabb.min[1], window_aabb.max[1] +| min_window_size[1]);
                    },
                    .bottom_left => {
                        window_aabb.min[0] += self.cursor[0] -| resizing.init_cursor[0];
                        window_aabb.max[1] += self.cursor[1] -| resizing.init_cursor[1];
                        window_aabb.min[0] = @max(window_aabb.min[0], window_aabb.max[0] +| min_window_size[0]);
                        window_aabb.max[1] = @min(window_aabb.max[1], window_aabb.min[1] +| min_window_size[1]);
                    },
                    .bottom_right => {
                        window_aabb.max += self.cursor -| resizing.init_cursor;
                        window_aabb.max = @max(window_aabb.max, window_aabb.min +| min_window_size);
                    },
                }
                resizing.init_cursor = self.cursor;
                window.rect = window_aabb.asRect();
                system.damage.addAabb(window.rect.asAabb().border(window_borders));
            },
            .none => {},
        }

        // log.info("cursor={}", .{self.cursor});
        self.forwardCursorMove();
    }

    fn forwardMouseWheel(self: *@This(), delta_z: i16) void {
        const window = self.focusedWindow() orelse return;
        window.pushEvent(.{ .mouse_wheel = delta_z });
    }

    fn forwardCursorMove(self: *@This()) void {
        const window = self.focusedWindow() orelse return;
        const window_aabb = window.rect.asAabb();

        if (@reduce(.Or, self.cursor < window_aabb.min))
            return;

        const window_relative_cursor: gui.Pos =
            self.cursor -| window.rect.pos;

        if (@reduce(.Or, window_relative_cursor >= window_aabb.max))
            return;

        window.pushEvent(.{ .cursor_moved = window_relative_cursor });
    }

    fn addWindow(
        self: *@This(),
        conn: *Connection,
        shmem: gui.Framebuffer,
    ) !struct {
        client_id: usize,
        server_id: usize,
    } {
        const client_id = conn.next_client_window_id;
        conn.next_client_window_id += 1;
        errdefer conn.next_client_window_id = client_id;

        const server_id = self.next_server_window_id;
        self.next_server_window_id += 1;
        errdefer self.next_server_window_id = server_id;

        const window_node = try gpa.create(WindowNode);
        errdefer gpa.destroy(window_node);

        const old_focused_window = self.focusedWindow();

        self.windows_list.append(window_node);
        errdefer std.debug.assert(self.windows_list.pop() == window_node);

        window_node.data = .{
            .client_id = client_id,
            .server_id = server_id,
            .rect = .{
                .pos = .{ 100, 100 },
                .size = shmem.size,
            },

            // the window is closed before the connection, so the pointer stays valid
            .conn = conn,
        };
        try window_node.data.attach(shmem);

        try self.windows_map.putNoClobber(server_id, &window_node.data);
        try conn.window_server_ids.putNoClobber(client_id, server_id);

        if (old_focused_window) |prev|
            self.damage.addRect(prev.rect.border(window_borders));
        system.damage.addRect(window_node.data.rect.border(window_borders));

        return .{ .client_id = client_id, .server_id = server_id };
    }

    fn focusWindow(
        self: *@This(),
        window: *Window,
    ) void {
        if (self.focusedWindow()) |prev|
            self.damage.addRect(prev.rect.border(window_borders));

        const node: *WindowNode = @fieldParentPtr("data", window);
        self.windows_list.remove(node);
        self.windows_list.append(node);
        self.damage.addRect(window.rect.border(window_borders));
    }

    fn focusedWindow(
        self: *@This(),
    ) ?*Window {
        const node = self.windows_list.last orelse return null;
        return &node.data;
    }

    fn draw(self: *@This()) void {
        const dmg_unrestricted = self.damage.take() orelse return;
        const dmg = dmg_unrestricted.intersect(self.display) orelse return;

        const fb: abi.util.Image([*]volatile u8) =
            dmg.subimage(self.fb) orelse return;
        const fb_backbuf: abi.util.Image([*]u8) =
            dmg.subimage(self.fb_backbuf) orelse return;

        // draw the background in the damaged area
        dmg.draw(self.fb_backbuf, background_colour);
        defer fb_backbuf.copyTo(fb) catch unreachable;

        // draw all windows in the damaged area
        var it = self.windows_list.first;
        while (it) |node| {
            it = node.next;
            const window = &node.data;
            window.resize() catch |err| {
                log.err("failed to resize a window: {}", .{err});
            };

            const window_fb = (window.fb orelse return).fb;

            const window_aabb = window.rect.asAabb();
            const window_border_aabb = window_aabb.border(window_borders);

            const border_colour = if (self.focusedWindow() == window)
                focused_border_colour
            else
                unfocused_border_colour;

            window_border_aabb.drawHollow(
                self.fb_backbuf,
                border_colour,
                window_borders,
            );

            if (window_aabb.intersect(dmg)) |damaged_window_aabb| {
                const dst = damaged_window_aabb.subimage(self.fb_backbuf).?;
                const src = damaged_window_aabb.move(-window.rect.pos).subimage(window_fb).?;
                src.blitTo(dst, false) catch {};
            }
        }

        // draw cursor
        if (dmg.intersect((gui.Rect{
            .pos = self.cursor,
            .size = self.cursor_size,
        }).asAabb())) |damaged_cursor_aabb| {
            const dst = damaged_cursor_aabb.subimage(self.fb_backbuf).?;
            const src = damaged_cursor_aabb.move(-self.cursor).subimage(self.cursor_fb).?;
            src.blitTo(dst, true) catch {};
        }
    }
};
