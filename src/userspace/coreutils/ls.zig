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
        try std.fmt.format(
            ctx.stdout_writer,
            "cannot open {s}: {}\n",
            .{ path, err },
        );
    };
}

fn lsPath(ctx: Ctx, path: []const u8) !void {
    const result = try abi.lpc.call(abi.VfsProtocol.OpenDirRequest, .{
        .path = try abi.fs.Path.new(path),
        .open_opts = .{ .mode = .read_only },
    }, .{
        .cap = 4,
    });

    const dir_ents = try result.asErrorUnion();

    var it = try abi.fs.Dir.iterator(dir_ents.data, dir_ents.count);
    while (it.next()) |entry| {
        try std.fmt.format(
            ctx.stdout_writer,
            "{s}\n",
            .{entry.name},
        );
    }
}
