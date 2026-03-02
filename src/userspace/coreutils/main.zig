const abi = @import("abi");
const std = @import("std");

//

const log = std.log.scoped(.coreutils);
const Error = abi.sys.Error;

pub const std_options = abi.std_options;
pub const panic = abi.panic;
comptime {
    abi.rt.installRuntime();
}

//

pub const Command = enum {
    cat,
    coreutils,
    echo,
    hexdump,
    ls,
    sh,
    sleep,
    uptime,
    yes,
};

const commands = .{
    .cat = @import("cat.zig"),
    .coreutils = @import("coreutils.zig"),
    .echo = @import("echo.zig"),
    .hexdump = @import("hexdump.zig"),
    .ls = @import("ls.zig"),
    .sh = @import("sh.zig"),
    .sleep = @import("sleep.zig"),
    .uptime = @import("uptime.zig"),
    .yes = @import("yes.zig"),
};

pub const Ctx = struct {
    args: *abi.process.ArgIterator,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

//

pub fn main() !void {
    try abi.rt.init();
    // std.log.info("hello from coreutils", .{});

    var args = abi.process.args();

    var stdin_buffer: [512]u8 = undefined;
    var stdout_buffer: [512]u8 = undefined;
    var stderr_buffer: [512]u8 = undefined;

    var stdin_writer = abi.io.stdin.reader(&stdin_buffer);
    var stdout_writer = abi.io.stdout.writer(&stdout_buffer);
    var stderr_writer = abi.io.stderr.writer(&stderr_buffer);

    const stdin = &stdin_writer.interface;
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    const cmd_name = std.fs.path.basename(args.next().?);
    const cmd = try pick(stdout, cmd_name) orelse return;
    const ctx = Ctx{
        .args = &args,
        .stdin = stdin,
        .stdout = stdout,
        .stderr = stderr,
    };

    try run(cmd, ctx);
}

pub const not_part_of_coreutils = "{s} is not part of coreutils\n";

pub fn pick(stdout: *std.Io.Writer, cmd_name: []const u8) !?Command {
    const cmd = std.meta.stringToEnum(Command, cmd_name);
    if (cmd == null) {
        try stdout.print(not_part_of_coreutils, .{cmd_name});
    }
    return cmd;
}

pub fn run(cmd: Command, ctx: Ctx) !void {
    switch (cmd) {
        inline else => |c| {
            // std.log.info("coreutils {}", .{c});
            const tool = @field(commands, @tagName(c));
            try tool.main(ctx);
        },
    }
}
