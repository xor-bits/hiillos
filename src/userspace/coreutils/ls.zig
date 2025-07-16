const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const Ctx = @import("main.zig").Ctx;

//

pub fn main(ctx: Ctx) !void {
    if (ctx.args.next()) |path| {
        try tryLsPath(path);
    } else {
        try tryLsPath("initfs:///sbin/");
        return;
    }

    while (ctx.args.next()) |path| {
        try tryLsPath(path);
    }
}

fn tryLsPath(path: []const u8) !void {
    lsPath(path) catch |err| {
        try abi.io.stdout.writer().print(
            "cannot open {s}: {}\n",
            .{ path, err },
        );
    };
}

fn lsPath(path: []const u8) !void {
    const result = try abi.lpc.call(abi.VfsProtocol.OpenDirRequest, .{
        .path = try abi.fs.Path.new(path),
        .open_opts = .{ .mode = .read_only },
    }, .{
        .cap = 4,
    });

    const dir_ents = try result.asErrorUnion();

    var it = try abi.fs.Dir.iterator(dir_ents.data, dir_ents.count);
    while (it.next()) |entry| {
        try abi.io.stdout.writer().print(
            "{s}\n",
            .{entry.name},
        );
    }
}
