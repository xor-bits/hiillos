const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

pub fn main(_: @import("main.zig").Ctx) !void {
    const stdin = abi.io.stdin.reader();
    const stdout = abi.io.stdout.writer();

    try stdout.print("{}", .{Prompt{}});

    var command: [0x100]u8 = undefined;
    var command_len: usize = 0;

    while (true) {
        const ch = try stdin.readSingle();

        if (std.ascii.isPrint(ch) or ch == '\n') {
            try stdout.writeAll(&.{ch});
        }

        if (ch == 8) { // backspace
            if (command_len == 0) continue;
            command_len -= 1;
            command[command_len] = ' ';
            try stdout.print("{} {}", .{
                abi.escape.cursorLeft(1),
                abi.escape.cursorLeft(1),
            });
            continue;
        }

        if (ch != '\n' and command_len < command.len) {
            command[command_len] = ch;
            command_len += 1;
        }

        if (ch != '\n') continue;

        const raw_cli = command[0..command_len];
        command_len = 0;
        try runScript(stdout, raw_cli);
    }
}

const Prompt = struct {
    exit_code: usize = 0,

    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (self.exit_code == 0) {
            try writer.print(
                "> ",
                .{},
            );
        } else {
            try writer.print(
                "({}) > ",
                .{self.exit_code},
            );
        }
    }
};

fn runScript(
    stdout: abi.io.File.Writer,
    script: []const u8,
) !void {
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |line| {
        try runLine(stdout, line);
    }
}

fn runLine(
    stdout: abi.io.File.Writer,
    raw_cli: []const u8,
) !void {
    const cli = std.mem.trimRight(u8, raw_cli, " \t\n\r");

    if (cli.len == 0) {
        try stdout.print("\n{}", .{Prompt{}});
        return;
    }

    var parts = std.mem.splitScalar(u8, cli, ' ');
    const cmd = parts.next().?;

    const arg_map = createArgMap(cli) catch |err| {
        try stdout.print("could not find command: {s} ({})\n\n{}", .{
            cmd, err, Prompt{},
        });
        return;
    };

    const result = try abi.lpc.call(abi.PmProtocol.ExecElfRequest, .{
        .arg_map = arg_map,
        .env_map = try caps.COMMON_ENV_MAP.clone(),
        .stdio = try abi.io.stdio.clone(),
    }, .{
        .cap = 1,
    });

    const proc = result.asErrorUnion() catch |err| {
        try stdout.print("unknown command: {s} ({})\n\n{}", .{
            cmd, err, Prompt{},
        });
        return;
    };

    const exit_code = try proc.main_thread.wait();
    try stdout.print("\n{}", .{Prompt{ .exit_code = exit_code }});
}

fn createArgMap(cli: []const u8) !caps.Frame {
    const args = try caps.Frame.create(0x1000);
    errdefer args.close();

    var args_stream = args.stream();
    var args_buffered_stream = std.io.bufferedWriter(args_stream.writer());
    var args_writer = args_buffered_stream.writer();

    const path = abi.process.env("PATH") orelse return error.MissingPathEnv;
    try args_writer.writeAll(path);

    var input_arg_it = std.mem.splitScalar(u8, cli, ' ');
    while (input_arg_it.next()) |input_arg| {
        if (input_arg.len == 0) continue;

        try args_writer.writeAll(input_arg);
        try args_writer.writeAll(&.{0});
    }

    try args_buffered_stream.flush();

    return args;
}
