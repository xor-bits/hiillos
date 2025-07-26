const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

pub fn main(ctx: @import("main.zig").Ctx) !void {
    const stdin = abi.io.stdin.reader();
    const stdout = abi.io.stdout.writer();

    const flag = ctx.args.next() orelse {
        try runInteractive(stdin, stdout);
        return;
    };

    if (std.mem.eql(u8, flag, "-c")) {
        const exit_code = try runLine(stdout, ctx.args.rest());
        abi.sys.selfStop(exit_code);
        return;
    }

    if (std.mem.eql(u8, flag, "--help")) {
        try help();
        return;
    }

    if (flag.len != 0 and flag[0] == '-') {
        try abi.io.stdout.writer().print("sh: {s}: invalid option\n", .{
            flag,
        });
        try help();
        return;
    }

    const script_file = try openFile(flag);
    defer script_file.close();

    const script_file_len = try script_file.getSize();

    const vmem = try caps.Vmem.self();
    defer vmem.close();

    const script_file_addr = try vmem.map(
        script_file,
        0,
        0,
        0,
        .{},
        .{},
    );
    defer vmem.unmap(script_file_addr, script_file_len) catch unreachable;

    const script = @as([*]const u8, @ptrFromInt(script_file_addr))[0..script_file_len];
    try runScript(stdout, script);
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

fn openFile(path: []const u8) !caps.Frame {
    const file_resp = try abi.lpc.call(
        abi.VfsProtocol.OpenFileRequest,
        .{ .path = abi.fs.Path.new(
            path,
        ) catch unreachable, .open_opts = .{
            .mode = .read_only,
            .file_policy = .use_existing,
            .dir_policy = .use_existing,
        } },
        caps.COMMON_VFS,
    );
    return try file_resp.asErrorUnion();
}

fn runInteractive(
    stdin: abi.io.File.Reader,
    stdout: abi.io.File.Writer,
) !void {
    var command: [0x100]u8 = undefined;
    var command_len: usize = 0;

    try stdout.print("{}", .{Prompt{}});

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

        try stdout.print("\n{}", .{Prompt{}});
    }
}

fn runScript(
    stdout: abi.io.File.Writer,
    script: []const u8,
) !void {
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |line| {
        _ = try runLine(stdout, line);
    }
}

fn runLine(
    stdout: abi.io.File.Writer,
    raw_cli: []const u8,
) !usize {
    const cli = std.mem.trimRight(u8, raw_cli, " \t\n\r");

    if (cli.len == 0) {
        return 0;
    }

    if (cli[0] == '#') {
        return 0;
    }

    var parts = std.mem.splitScalar(u8, cli, ' ');
    const cmd = parts.next().?;

    const arg_map = createArgMap(cli) catch |err| {
        try stdout.print("could not find command: {s} ({})\n", .{
            cmd, err,
        });
        return 0;
    };

    const result = try abi.lpc.call(abi.PmProtocol.ExecElfRequest, .{
        .arg_map = arg_map,
        .env_map = try caps.COMMON_ENV_MAP.clone(),
        .stdio = try abi.io.stdio.clone(),
    }, .{
        .cap = 1,
    });

    const proc = result.asErrorUnion() catch |err| {
        try stdout.print("unknown command: {s} ({})\n", .{
            cmd, err,
        });
        return 0;
    };

    return try proc.main_thread.wait();
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

fn help() !void {
    try abi.io.stdout.writer().print(
        \\usage: sh [-c command]
        \\       sh script-file
        \\
    , .{});
}
