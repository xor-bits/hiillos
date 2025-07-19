const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const input = abi.input;
const lpc = abi.lpc;
const sys = abi.sys;

const log = std.log.scoped(.gui);

//

pub const Colour = extern struct {
    blue: u8,
    green: u8,
    red: u8,
    alpha: u8 = 0xff,

    pub const white: @This() = .{ .red = 0xff, .green = 0xff, .blue = 0xff };
    pub const black: @This() = .{ .red = 0x00, .green = 0x00, .blue = 0x00 };
};

pub const Pos = @Vector(2, i32);

pub fn clamp(pos: Pos, area: Aabb) Pos {
    const one: @Vector(2, i32) = @splat(1);
    return @min(@max(area.min, pos), area.max -| one);
}

pub fn absDiff(a: Pos, b: Pos) Size {
    const Pos64 = @Vector(2, i64);
    return @intCast(@abs(@as(Pos64, a) - @as(Pos64, b)));
}

pub const Size = @Vector(2, u32);

pub const Rect = struct {
    pos: Pos,
    size: Size,

    pub fn asAabb(
        self: @This(),
    ) Aabb {
        const size_limit: @Vector(2, i32) = @splat(std.math.maxInt(i32));
        return .{
            .min = self.pos,
            .max = self.pos +| @min(size_limit, self.size),
        };
    }

    pub fn border(
        self: @This(),
        size: i32,
    ) @This() {
        return self.asAabb().border(size).asRect();
    }

    pub fn middle(
        self: @This(),
    ) Pos {
        const two: @Vector(2, u32) = @splat(2);
        return self.pos +| @as(Pos, @intCast(self.size / two));
    }

    pub fn move(
        self: @This(),
        by: Pos,
    ) @This() {
        return .{
            .pos = self.pos +| by,
            .size = self.size,
        };
    }
};

pub const Aabb = struct {
    min: Pos,
    max: Pos,

    pub fn asRect(
        self: @This(),
    ) Rect {
        // TODO: use std.math.lossyCast() everywhere
        return .{
            .pos = self.min,
            .size = absDiff(self.max, self.min),
        };
    }

    pub fn border(
        self: @This(),
        size: i32,
    ) @This() {
        const border_size: @Vector(2, i32) = @splat(size);
        return .{
            .min = self.min -| border_size,
            .max = self.max +| border_size,
        };
    }

    /// lossy union operation
    pub fn merge(
        self: @This(),
        other: @This(),
    ) @This() {
        if (self.min[0] == self.max[0] or self.min[1] == self.max[1]) {
            // the damage was previously zero,
            // so instead of extending from the [0,0],
            // move the damage to the added damage

            return other;
        }

        return .{
            .min = @min(self.min, other.min),
            .max = @max(self.max, other.max),
        };
    }

    /// boolean and
    pub fn intersect(
        self: @This(),
        other: @This(),
    ) ?@This() {
        const selection: @This() = .{
            .min = @max(self.min, other.min),
            .max = @min(self.max, other.max),
        };
        if (selection.isEmpty()) return null;
        return selection;
    }

    pub fn middle(
        self: @This(),
    ) Pos {
        return self.asRect().middle();
    }

    pub fn move(
        self: @This(),
        by: Pos,
    ) @This() {
        return .{
            .min = self.min +| by,
            .max = self.max +| by,
        };
    }

    pub fn fix(
        self: @This(),
    ) @This() {
        return .{
            .min = @min(self.min, self.max),
            .max = @max(self.min, self.max),
        };
    }

    pub fn isEmpty(
        self: @This(),
    ) bool {
        return @reduce(.Or, self.min >= self.max);
    }

    pub fn subimage(
        self: @This(),
        image: anytype,
    ) ?@TypeOf(image) {
        const zero: @Vector(2, i32) = @splat(0);
        const image_size: @Vector(2, i32) = .{
            @min(std.math.maxInt(i32), image.width),
            @min(std.math.maxInt(i32), image.height),
        };

        const min: @Vector(2, u32) =
            @intCast(std.math.clamp(self.min, zero, image_size));
        const max: @Vector(2, u32) =
            @intCast(std.math.clamp(self.max, zero, image_size));

        if (@reduce(.Or, min >= max)) return null;
        const size = max - min;

        return image.subimage(min[0], min[1], size[0], size[1]) catch unreachable;
    }

    pub fn draw(
        self: @This(),
        image: anytype,
        col: Colour,
    ) void {
        const selection = self.subimage(image) orelse return;
        selection.fill(@bitCast(col));
    }

    pub fn drawHollow(
        self: @This(),
        image: anytype,
        col: Colour,
        border_width: u16,
    ) void {
        if (self.isEmpty() or border_width == 0)
            return;

        const size = self.max - self.min;

        if (@reduce(.Or, @as(Pos, @splat(border_width * 2)) >= size))
            return self.draw(image, col);

        // AAAAAAAAAAAAA
        //
        // B           C
        // B           C
        // B           C
        //
        // DDDDDDDDDDDDD

        const a = Aabb{
            .min = self.min,
            .max = .{ self.max[0], self.min[1] + border_width },
        };
        a.draw(image, col);

        const d = Aabb{
            .min = .{ self.min[0], self.max[1] - border_width },
            .max = self.max,
        };
        d.draw(image, col);

        const b = Aabb{
            .min = .{ self.min[0], self.min[1] + border_width },
            .max = .{ self.min[0] + border_width, self.max[1] - border_width },
        };
        b.draw(image, col);

        const c = Aabb{
            .min = .{ self.max[0] - border_width, self.min[1] + border_width },
            .max = .{ self.max[0], self.max[1] - border_width },
        };
        c.draw(image, col);
    }
};

pub const Damage = struct {
    aabb: ?Aabb = null,

    pub fn full() @This() {
        return .{ .aabb = .{
            .min = @splat(std.math.minInt(i32)),
            .max = @splat(std.math.maxInt(i32)),
        } };
    }

    pub fn reset(
        self: *@This(),
    ) void {
        self.aabb = null;
    }

    pub fn take(
        self: *@This(),
    ) ?Aabb {
        const aabb = self.aabb orelse return null;
        self.reset();
        return aabb;
    }

    pub fn addRect(
        self: *@This(),
        rect: Rect,
    ) void {
        self.addAabb(rect.asAabb());
    }

    pub fn addAabb(
        self: *@This(),
        aabb: Aabb,
    ) void {
        if (self.aabb) |*v| {
            v.* = v.merge(aabb);
        } else {
            self.aabb = aabb;
        }
    }
};

pub const WmDisplay = struct {
    sender: caps.Sender,

    pub fn connect() !@This() {

        // find the IPC socket address using WM_SOCKET env var
        const wm_sock_addr = abi.process.env("WM_SOCKET") orelse {
            log.err("could not find WM_SOCKET", .{});
            abi.sys.selfStop(1);
        };
        log.debug("found WM_SOCKET={s}", .{wm_sock_addr});

        // open the IPC socket
        const wm_sock_result = try abi.lpc.call(abi.VfsProtocol.ConnectRequest, .{
            .path = try abi.fs.Path.new(wm_sock_addr),
        }, caps.COMMON_VFS);
        const wm_sock_raw = try wm_sock_result.asErrorUnion();

        std.debug.assert(wm_sock_raw.identify() == .sender);
        const wm_sock = caps.Sender{ .cap = wm_sock_raw.cap };

        // send a connection request to the window manager
        const wm_display_result = try abi.lpc.call(
            WmProtocol.Connect,
            .{},
            wm_sock,
        );
        return try wm_display_result.asErrorUnion();
    }

    pub fn deinit(self: @This()) void {
        self.sender.close();
    }

    pub fn clone(self: @This()) sys.Error!@This() {
        const new = try self.sender.clone();
        return .{ .sender = new };
    }

    pub fn createWindow(self: @This(), info: WindowInfo) !Window {
        const window_result = try abi.lpc.call(WmDisplayProtocol.CreateWindow, .{
            .size = info.size,
        }, self.sender);
        return try window_result.asErrorUnion();
    }

    pub fn nextEvent(self: @This()) !Event {
        const ev_result = try abi.lpc.call(
            WmDisplayProtocol.NextEvent,
            .{},
            self.sender,
        );
        const ev = try ev_result.asErrorUnion();

        return ev;
    }
};

pub const WindowInfo = struct {
    size: Size = .{ 640, 480 },
};

pub const Window = struct {
    window_id: usize,
    fb: Framebuffer,

    pub fn deinit(self: @This()) void {
        // TODO: window closing
        _ = self;
    }

    /// if `area == null`, then everything in the window is damaged
    pub fn damage(self: @This(), wm_display: WmDisplay, area: ?Aabb) !void {
        const full_damage_result = try abi.lpc.call(WmDisplayProtocol.Damage, .{
            .window_id = self.window_id,
            .area = area orelse .{
                .min = .{ 0, 0 },
                .max = @intCast(self.fb.size),
            },
        }, wm_display.sender);
        try full_damage_result.asErrorUnion();
    }
};

pub const Framebuffer = struct {
    shmem: caps.Frame,
    pitch: u32,
    size: Size,
    bytes: usize,

    pub fn init(size: Size) !@This() {
        const shmem_info = try calculateFrameSize(size);
        const shmem = try caps.Frame.create(shmem_info.bytes);

        return .{
            .shmem = shmem,
            .size = size,
            .pitch = shmem_info.pitch,
            .bytes = shmem_info.bytes,
        };
    }

    pub fn calculateFrameSize(size: Size) error{Overflow}!struct { pitch: u32, bytes: u32 } {
        const real_width = try std.math.ceilPowerOfTwo(u32, size[0]);
        const bytes = try std.math.mul(
            u32,
            try std.math.mul(
                u32,
                real_width,
                try std.math.ceilPowerOfTwo(u32, size[1]),
            ),
            4,
        );

        return .{ .pitch = real_width * 4, .bytes = bytes };
    }

    pub fn update(self: @This(), new: Size) !?@This() {
        const new_info = try calculateFrameSize(new);
        if (self.bytes >= new_info.bytes) {
            // the old shmem can already hold the new framebuffer
            return null;
        }

        return try .init(new);
    }
};

pub const WindowEvent = struct {
    window_id: usize,
    event: Inner,

    pub const Inner = union(enum) {
        resize: Framebuffer,
        close_requested: void,
        focused: bool,
        keyboard_input: input.KeyEvent,
        cursor_moved: Pos,
        mouse_wheel: i16,
        mouse_button: input.MouseButtonEvent,
        redraw: void,
    };
};

pub const Event = union(enum) {
    window: WindowEvent,
};

pub const WmProtocol = struct {
    pub const Connect = struct {
        pub const Response = abi.Result(WmDisplay, sys.ErrorEnum);
        pub const Union = Request;
    };

    pub const Request = lpc.Request(&.{
        Connect,
    });
};

pub const WmDisplayProtocol = struct {
    pub const CreateWindow = struct {
        size: Size,

        pub const Response = abi.Result(Window, sys.ErrorEnum);
        pub const Union = Request;
    };

    pub const NextEvent = struct {
        pub const Response = abi.Result(Event, sys.ErrorEnum);
        pub const Union = Request;
    };

    pub const Damage = struct {
        window_id: usize,
        area: Aabb,

        pub const Response = abi.Result(void, sys.ErrorEnum);
        pub const Union = Request;
    };

    pub const Request = lpc.Request(&.{
        CreateWindow, NextEvent, WmDisplayProtocol.Damage,
    });
};
