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

    var fb_info: abi.FramebufferInfoFrame = undefined;
    try seat.fb_info.read(0, std.mem.asBytes(&fb_info));

    const fb = @as([*]volatile u32, @ptrFromInt(fb_addr))[0 .. fb_info.pitch * fb_info.height];
    abi.util.fillVolatile(u32, fb, 0xFF8000);
}
