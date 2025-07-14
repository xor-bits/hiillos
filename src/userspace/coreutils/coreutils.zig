const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const Subcommand = enum {
    install,
};

//

pub fn main(ctx: @import("main.zig").Ctx) !void {
    const subcmd_name = ctx.args.next() orelse {
        try help(ctx.stdout_writer);
        return;
    };
    const subcmd = std.meta.stringToEnum(Subcommand, subcmd_name) orelse {
        try help(ctx.stdout_writer);
        return;
    };

    switch (subcmd) {
        .install => {
            try install();

            try std.fmt.format(ctx.stdout_writer,
                \\coreutils installed
                \\
            , .{});
            std.log.info("coreutils installed", .{});

            const opt_arg = ctx.args.next() orelse return;
            if (!std.mem.eql(u8, "--sh", opt_arg)) return;

            _ = try abi.lpc.call(abi.PmProtocol.ExecElfRequest, .{
                .arg_map = try caps.Frame.init("initfs:///sbin/sh"),
                .env_map = try caps.COMMON_ENV_MAP.clone(),
                .stdio = try @import("main.zig").stdio.clone(),
            }, .{
                .cap = 1,
            });
        },
    }
}

fn install() !void {
    const variants = @typeInfo(
        @import("main.zig").Command,
    ).@"enum".fields;

    inline for (variants) |cmd| {
        if (comptime std.mem.eql(u8, cmd.name, "coreutils")) continue;
        try installAs(cmd.name);
    }
}

fn installAs(comptime name: []const u8) !void {
    const result = try abi.lpc.call(abi.VfsProtocol.SymlinkRequest, .{
        .oldpath = try abi.fs.Path.new("initfs:///sbin/coreutils"),
        .newpath = try abi.fs.Path.new("initfs:///sbin/" ++ name),
    }, .{
        .cap = 4,
    });
    try result.asErrorUnion();
}

fn help(stdout_writer: abi.ring.Ring(u8).Writer) !void {
    try std.fmt.format(stdout_writer,
        \\Hiillos Coreutils v0.0.2
        \\usage: coreutils [install]
    , .{});
}
