const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

pub fn main(ctx: @import("main.zig").Ctx) !void {
    const stdin = abi.io.stdin.reader();
    const stdout = abi.io.stdout.writer();

    const path = abi.process.env("PATH") orelse "initfs:///sbin/";

    const flag = ctx.args.next() orelse {
        try runInteractive(stdin, stdout, path);
        return;
    };

    if (std.mem.eql(u8, flag, "-c")) {
        const exit_code = try runLine(stdout, path, ctx.args.rest());
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

    const script_file = try abi.fs.openFileAbsolute(flag, .{});
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
    try runScript(stdout, path, script);
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

fn runInteractive(
    stdin: abi.io.File.Reader,
    stdout: abi.io.File.Writer,
    path: []const u8,
) !void {
    var command: [0x100]u8 = undefined;
    var command_len: usize = 0;

    var has_suggestions = false;

    try stdout.print("{}", .{Prompt{}});

    const programs, const names = try findAvailPrograms(abi.mem.slab_allocator, path);
    defer abi.mem.slab_allocator.free(programs);
    defer abi.mem.slab_allocator.free(names);

    while (true) {
        const ch = try stdin.readSingle();

        if (has_suggestions) {
            has_suggestions = false;
            try stdout.print("{}{}{}{}", .{
                abi.escape.cursorPush(),
                abi.escape.cursorNextLine(1),
                abi.escape.eraseInDisplay(.cursor_to_end),
                abi.escape.cursorPop(),
            });
        }

        if (ch == std.ascii.control_code.bs) { // backspace
            if (command_len == 0) continue;
            command_len -= 1;
            command[command_len] = ' ';
            try stdout.print("{} {}", .{
                abi.escape.cursorLeft(1),
                abi.escape.cursorLeft(1),
            });
            continue;
        }

        if (ch == std.ascii.control_code.etx) { // ctrl+c
            if (command_len == 0) continue;
            command_len = 0;
            try stdout.print("\n\n{}", .{
                Prompt{},
            });
            continue;
        }

        if (ch == '\t') {
            var parts = std.mem.splitScalar(u8, command[0..command_len], ' ');
            const cmd_hint = parts.next().?;

            try stdout.print("{}{}", .{
                abi.escape.cursorPush(),
                abi.escape.cursorNextLine(1),
            });
            for (programs) |avail_program| {
                if (!std.mem.startsWith(u8, avail_program, cmd_hint)) continue;
                try stdout.print("{s} ", .{avail_program});
            }
            try stdout.print("{}", .{
                abi.escape.cursorPop(),
            });
            has_suggestions = true;
            if (getPrefix(programs, cmd_hint)) |autocomplete| {
                const limited_autocomplete = autocomplete[0..@min(autocomplete.len, command.len)];
                std.mem.copyForwards(u8, command[0..], limited_autocomplete);
                command_len = limited_autocomplete.len;
            }
            try stdout.print("{}{}{}{s}", .{
                abi.escape.cursorNextLine(1),
                abi.escape.cursorPrevLine(1),
                Prompt{},
                command[0..command_len],
            });

            continue;
        }

        if (std.ascii.isPrint(ch) and command_len < command.len) {
            command[command_len] = ch;
            command_len += 1;
        }

        if (ch != '\n') continue;

        const raw_cli = command[0..command_len];
        command_len = 0;
        try runScript(stdout, path, raw_cli);

        try stdout.print("\n{}", .{Prompt{}});
    }
}

/// find the maximum prefix of all strings that start with (at least) `starts_with`
/// ex: `getPrefix(&.{ "abc0", "abc", "abc1", "def" }, "ab") -> "abc"`
fn getPrefix(strings: []const []const u8, starts_with: []const u8) ?[]const u8 {
    if (strings.len == 0) return null;

    var current: ?[]const u8 = null;
    for (strings[0..]) |next| {
        if (!std.mem.startsWith(u8, next, starts_with)) continue;

        const cur = current orelse {
            current = next;
            continue;
        };

        const idx = std.mem.indexOfDiff(u8, cur, next) orelse cur.len;
        current = cur[0..idx];
        if (idx == 0) return null;
    }

    return current;
}

fn findAvailPrograms(
    allocator: std.mem.Allocator,
    path: []const u8,
) !struct { []const []const u8, []const u8 } {
    const dir = try abi.fs.openDirAbsolute(path, .{});
    defer dir.deinit();

    var it = try dir.iterate();
    defer it.deinit();

    var sum_lengths: usize = 0;
    var count: usize = 0;
    while (it.next()) |ent| {
        if (ent.type != .file) continue;

        sum_lengths += ent.name.len + 1;
        count += 1;
    }

    const names = try allocator.alloc(u8, sum_lengths);
    errdefer allocator.free(names);

    const names_list = try allocator.alloc([]const u8, count);
    errdefer allocator.free(names_list);

    it.reset();
    sum_lengths = 0;
    count = 0;
    while (it.next()) |ent| {
        if (ent.type != .file) continue;

        const name = names[sum_lengths..][0 .. ent.name.len + 1];
        std.mem.copyForwards(u8, name, ent.name);
        name[name.len - 1] = 0;
        names_list[count] = name[0 .. name.len - 1];

        sum_lengths += ent.name.len + 1;
        count += 1;
    }

    return .{ names_list, names };
}

fn runScript(
    stdout: abi.io.File.Writer,
    path: []const u8,
    script: []const u8,
) !void {
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |line| {
        _ = try runLine(stdout, path, line);
    }
}

fn runLine(
    stdout: abi.io.File.Writer,
    path: []const u8,
    raw_cli: []const u8,
) !usize {
    abi.syslog("running '{s}'", .{raw_cli});
    const cli = std.mem.trimRight(u8, raw_cli, " \t\n\r");

    if (cli.len == 0) {
        return 0;
    }

    if (cli[0] == '#') {
        return 0;
    }

    var parts = std.mem.splitScalar(u8, cli, ' ');
    const cmd = parts.next().?;

    const arg_map = createArgMap(path, cli) catch |err| {
        try stdout.print("could not find command: {s} ({})\n", .{
            cmd, err,
        });
        return 1;
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
        return 1;
    };

    return try proc.main_thread.wait();
}

fn createArgMap(
    path: []const u8,
    cli: []const u8,
) !caps.Frame {
    const args = try caps.Frame.create(0x1000);
    errdefer args.close();

    var args_stream = args.stream();
    var args_buffered_stream = std.io.bufferedWriter(args_stream.writer());
    var args_writer = args_buffered_stream.writer();

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
