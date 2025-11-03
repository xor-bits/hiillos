const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const Ctx = @import("main.zig").Ctx;

//

pub fn main(ctx: Ctx) !void {
    if (ctx.args.next()) |path| {
        try tryLsPath(ctx, path);
    } else {
        try tryLsPath(ctx, "initfs:///sbin/");
        return;
    }

    while (ctx.args.next()) |path| {
        try tryLsPath(ctx, path);
    }
}

fn tryLsPath(ctx: Ctx, path: []const u8) !void {
    lsPath(ctx, path) catch |err| {
        try ctx.stderr.print(
            "cannot open {s}: {}\n",
            .{ path, err },
        );
    };
}

fn lsPath(ctx: Ctx, path: []const u8) !void {
    const dir = try abi.fs.openDirAbsolute(path, .{});
    defer dir.deinit();

    var it = try dir.iterate();
    defer it.deinit();

    while (it.next()) |entry| {
        try ctx.stdout.print(
            "{s}\n",
            .{entry.name},
        );
    }
}
