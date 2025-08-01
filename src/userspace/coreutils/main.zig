const abi = @import("abi");
const std = @import("std");

//

const log = std.log.scoped(.coreutils);
const Error = abi.sys.Error;

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
};

//

pub fn main() !void {
    try abi.rt.init();
    // std.log.info("hello from coreutils", .{});

    var args = abi.process.args();
    const cmd_name = std.fs.path.basename(args.next().?);
    const cmd = std.meta.stringToEnum(Command, cmd_name) orelse {
        try abi.io.stdout.writer().print(
            "{s} is not part of coreutils\n",
            .{cmd_name},
        );
        return;
    };

    switch (cmd) {
        inline else => |c| {
            // std.log.info("coreutils {}", .{c});

            try @field(commands, @tagName(c))
                .main(Ctx{
                .args = &args,
            });
        },
    }
}
