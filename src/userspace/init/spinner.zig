const abi = @import("abi");
const std = @import("std");

const main = @import("main.zig");

//

const log = std.log.scoped(.spinner);
const caps = abi.caps;
const Error = abi.sys.Error;
const dark_mode: bool = true;
const msaa: u16 = 2;
const frametime_ns: u32 = 16_666_667;
// const frametime_ns: u32 = 1_000_000;
const speed: f32 = 0.001;
const dot_count: u16 = 18;
const radius: u16 = 60;
const trail: u8 = 10;
const color: u32 = 0xFF8000;
// const color: u32 = 0x0080FF;
// const color: u32 = 0x00FFFF;
// const color: u32 = 0x00FF80;
// const color: u32 = 0x80FF00;
// const color: u32 = 0xFFFFFF;
// const color: u32 = 0x000000;

const pm = abi.PmProtocol.Client().init(caps.Sender{ .cap = 1 });
const hpet = abi.HpetProtocol.Client().init(caps.Sender{ .cap = 2 });
const ps2 = abi.Ps2Protocol.Client().init(caps.Sender{ .cap = 3 });
const vfs = abi.VfsProtocol.Client().init(caps.Sender{ .cap = 4 });
const fb_frame = caps.Frame{ .cap = 5 };
const fb_info_frame = caps.Frame{ .cap = 6 };

//

pub fn spinnerMain() !void {
    const vmem = try caps.Vmem.self();

    // {
    //     const thread = try caps.Thread.self();
    //     defer thread.close();
    //     try thread.setPrio(1); // lower the spinner priority
    // }

    const fb_addr = try vmem.map(
        fb_frame,
        0,
        0,
        0,
        .{ .writable = true },
        .{ .cache = .write_combining },
    );

    const fb_info_addr = try vmem.map(
        fb_info_frame,
        0,
        0,
        0,
        .{},
        .{},
    );

    try abi.thread.spawn(tickKey, .{});

    framebufferSplash(
        vmem,
        @ptrFromInt(fb_addr),
        @ptrFromInt(fb_info_addr),
    ) catch |err| {
        log.warn("spinner failed: {}", .{err});
    };
}

var dir: std.atomic.Value(i32) = .init(1);

fn tickKey() !void {
    var local_dir: i32 = 1;

    while (true) {
        const res, _, const state: abi.input.KeyState = try ps2.call(
            .nextKey,
            {},
        );
        try res;

        if (state == .release) continue;

        local_dir = -local_dir;
        dir.store(local_dir, .monotonic);
    }
}

fn framebufferSplash(
    vmem: caps.Vmem,
    framebuffer: [*]volatile u32,
    framebuffer_info: *const abi.FramebufferInfoFrame,
) !void {
    if (framebuffer_info.bpp != 32) {
        log.warn("unrecognized framebuffer format", .{});
        return;
    }

    const width = framebuffer_info.width;
    const height = framebuffer_info.height;
    const pitch = framebuffer_info.pitch / 4;

    const backbuffer_frame = try caps.Frame.create(@as(usize, 4) * FbInfo.width * FbInfo.height);
    defer backbuffer_frame.close();

    const backbuffer_addr = try vmem.map(
        backbuffer_frame,
        0,
        0,
        0,
        .{ .writable = true },
        .{},
    );

    const fb_info: FbInfo = .{
        .buffer = @as([*]u32, @ptrFromInt(backbuffer_addr))[0 .. FbInfo.width * FbInfo.height],
        .fb_width = width,
        .fb_height = height,
        .fb_pitch = pitch,
        .fb = framebuffer[0 .. width * pitch],
    };

    @memset(fb_info.fb, if (dark_mode) 0x0 else 0xFFFFFF);
    @memset(fb_info.buffer, if (dark_mode) 0x0 else 0xFFFFFF);

    const mid_x = width / 2;
    const mid_y = height / 2;

    const _nanos = try hpet.call(.timestamp, {});
    var nanos: u128 = _nanos.@"0";
    var phase: i128 = 0;
    while (true) {
        drawFrame(
            &fb_info,
            mid_x,
            mid_y,
            @floatCast(@as(f64, @floatFromInt(phase)) / 1_000_000.0),
        );

        phase += dir.load(.monotonic) * frametime_ns;
        nanos += frametime_ns;
        _ = hpet.call(.sleepDeadline, .{nanos}) catch break;
    }
}

const FbInfo = struct {
    const width: usize = 3 * radius * msaa;
    const height: usize = 3 * radius * msaa;

    buffer: []u32,

    fb_width: usize,
    fb_height: usize,
    fb_pitch: usize,
    fb: []volatile u32,
};

fn drawFrame(fb: *const FbInfo, mid_x: usize, mid_y: usize, millis: f32) void {
    dim(fb);

    for (0..dot_count) |i| {
        const phase = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(dot_count));
        drawTriangleDot(
            fb,
            FbInfo.width / 2,
            FbInfo.height / 2,
            phase * 3.0 - millis * speed,
            millis,
            color,
        );
    }

    blit(fb, mid_x, mid_y);
}

fn dim(fb: *const FbInfo) void {
    for (0..FbInfo.height) |y| {
        for (0..FbInfo.width) |x| {
            var col: Pixel = @bitCast(fb.buffer[x + y * FbInfo.width]);
            if (dark_mode) {
                col.r = @max(col.r, trail) - trail;
                col.g = @max(col.g, trail) - trail;
                col.b = @max(col.b, trail) - trail;
            } else {
                col.r = @min(col.r, 255 - trail) + trail;
                col.g = @min(col.g, 255 - trail) + trail;
                col.b = @min(col.b, 255 - trail) + trail;
            }
            fb.buffer[x + y * FbInfo.width] = @bitCast(col);
        }
    }
}

fn blit(fb: *const FbInfo, mid_x: usize, mid_y: usize) void {
    for (0..FbInfo.height / msaa) |y| {
        for (0..FbInfo.width / msaa) |x| {
            var avg_r: u16 = 0;
            var avg_g: u16 = 0;
            var avg_b: u16 = 0;
            inline for (0..msaa) |msaa_y| {
                inline for (0..msaa) |msaa_x| {
                    const px: Pixel = @bitCast(
                        fb.buffer[(x * msaa + msaa_x) + (y * msaa + msaa_y) * FbInfo.width],
                    );
                    avg_r += px.r;
                    avg_g += px.g;
                    avg_b += px.b;
                }
            }

            const multisampled = Pixel{
                .r = @truncate(avg_r / msaa / msaa),
                .g = @truncate(avg_g / msaa / msaa),
                .b = @truncate(avg_b / msaa / msaa),
            };

            // const target_x = x;
            // const target_y = y;
            // _ = .{ mid_x, mid_y };
            const target_x = x + mid_x - FbInfo.width / 2 / msaa;
            const target_y = y + mid_y - FbInfo.height / 2 / msaa;
            fb.fb[target_x + target_y * fb.fb_pitch] =
                @bitCast(multisampled);
        }
    }
}

const Pixel = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    _p: u8 = 0,
};

fn drawTriangleDot(fb: *const FbInfo, mid_x: usize, mid_y: usize, t: f32, millis: f32, col: u32) void {
    const a = (std.math.floor(t) + millis * speed) * 2.0 * std.math.pi / 3.0;
    const b = (std.math.ceil(t) + millis * speed) * 2.0 * std.math.pi / 3.0;
    const ft = t - std.math.floor(t);

    const pt_x = ft * std.math.cos(b) + (1.0 - ft) * std.math.cos(a);
    const pt_y = ft * std.math.sin(b) + (1.0 - ft) * std.math.sin(a);

    const rad = @as(f32, @floatFromInt(radius * msaa));

    drawDot(
        fb,
        @as(usize, @intFromFloat(pt_x * rad + @as(f32, @floatFromInt(mid_x)))),
        @as(usize, @intFromFloat(pt_y * rad + @as(f32, @floatFromInt(mid_y)))),
        col,
    );
}

fn drawDot(fb: *const FbInfo, mid_x: usize, mid_y: usize, col: u32) void {
    const minx = @max(mid_x, msaa * 5) - msaa * 5;
    const miny = @max(mid_y, msaa * 5) - msaa * 5;
    const maxx = mid_x + msaa * 5 + 1;
    const maxy = mid_y + msaa * 5 + 1;

    for (miny..maxy) |y| {
        for (minx..maxx) |x| {
            const dx = if (mid_x > x) mid_x - x else x - mid_x;
            const dy = if (mid_y > y) mid_y - y else y - mid_y;
            const dsqr = dx * dx + dy * dy;
            const rad = 3 * msaa + 1;

            if (dsqr <= rad * rad - msaa + 1) {
                fb.buffer[x + y * FbInfo.width] = col;
            }
        }
    }
}
