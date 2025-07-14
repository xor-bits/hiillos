const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const log = std.log.scoped(.term);

//

pub fn main() !void {
    try abi.process.init();

    const vmem = try caps.Vmem.self();
    defer vmem.close();

    const stdio = try (try abi.lpc.call(
        abi.PmProtocol.GetStdioRequest,
        .{},
        .{ .cap = 1 },
    )).asErrorUnion();

    const stdout = switch (stdio.stdout) {
        .ring => |ring| try abi.ring.Ring(u8)
            .fromShared(ring, null),
        else => null,
    };

    const stdout_writer = if (stdout) |s| s.writer() else null;

    const wm_sock_addr = abi.process.env("WM_SOCKET") orelse {
        if (stdout_writer) |writer|
            try writer.print("could not find WM_SOCKET", .{});
        log.err("could not find WM_SOCKET", .{});
        abi.sys.selfStop(1);
    };

    log.info("found WM_SOCKET={s}", .{wm_sock_addr});
    if (stdout_writer) |writer|
        try writer.print("found WM_SOCKET={s}", .{wm_sock_addr});

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
            .width = 900,
            .height = 600,
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
        if (i % 4 == 3) {
            b.* = 255; // max alpha
        } else {
            b.* = @truncate(i);
        }
    }
}
