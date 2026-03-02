const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const coreutils = @import("main.zig");
const Ctx = coreutils.Ctx;

//

pub fn main(ctx: Ctx) anyerror!void {
    const subcmd_name = ctx.args.next() orelse {
        try help(ctx);
        return;
    };

    const prog_flag = "--coreutils-prog=";
    if (std.mem.eql(u8, subcmd_name, "install")) {
        try install();

        try ctx.stdout.print(
            \\coreutils installed
            \\
        , .{});

        const opt_arg = ctx.args.next() orelse return;
        if (!std.mem.eql(u8, "--sh", opt_arg)) return;

        _ = try abi.lpc.call(abi.PmProtocol.ExecElfRequest, .{
            .arg_map = try caps.Frame.init("initfs:///sbin/sh"),
            .env_map = try caps.COMMON_ENV_MAP.clone(),
            .stdio = try abi.io.stdio.clone(),
        }, .{
            .cap = 1,
        });
    } else if (std.mem.startsWith(u8, subcmd_name, prog_flag)) {
        const cmd_name = subcmd_name[prog_flag.len..];
        const cmd = try coreutils.pick(ctx.stdout, cmd_name) orelse return;
        if (cmd == .coreutils) {
            try ctx.stdout.print(coreutils.not_part_of_coreutils, .{cmd_name});
            return;
        }
        try coreutils.run(cmd, ctx);
    } else {
        try help(ctx);
    }
}

fn install() !void {
    const variants = @typeInfo(coreutils.Command).@"enum".fields;
    inline for (variants) |cmd| {
        if (comptime std.mem.eql(u8, cmd.name, "coreutils")) continue;
        try installAs(cmd.name);
    }
}

fn list() []const u8 {
    var built_in: []const u8 = "";
    const variants = @typeInfo(coreutils.Command).@"enum".fields;
    inline for (variants) |cmd| {
        built_in = built_in ++ cmd.name;
    }
    return built_in;
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

fn help(ctx: Ctx) !void {
    try ctx.stdout.print(
        \\Hiillos Coreutils v0.0.2
        \\usage: coreutils [install]
        \\       coreutils --coreutils-prog=built-in-program [params]...
        \\
        \\Built-in programs:
        \\
    ++ list() ++ "\n", .{});
}
