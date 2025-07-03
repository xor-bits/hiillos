const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

pub fn main(
    args: *abi.process.ArgIterator,
    stdin: *const abi.ring.Ring(u8),
    stdout_writer: abi.ring.RingWriter,
) !void {
    _ = stdin;

    const subcmd_name = args.next() orelse {
        try help(stdout_writer);
        return;
    };
    const subcmd = std.meta.stringToEnum(Subcommand, subcmd_name) orelse {
        try help(stdout_writer);
        return;
    };

    switch (subcmd) {
        .install => {
            const result = try abi.lpc.call(abi.VfsProtocol.SymlinkRequest, .{
                .oldpath = try abi.fs.Path.new("initfs:///sbin/coreutils"),
                .newpath = try abi.fs.Path.new("initfs:///sbin/sh"),
            }, .{
                .cap = 4,
            });
            try result.asErrorUnion();

            try std.fmt.format(stdout_writer,
                \\coreutils installed
            , .{});
            std.log.info("coreutils installed", .{});

            if (args.next()) |opt_arg| if (std.mem.eql(u8, "--sh", opt_arg)) {
                _ = try abi.lpc.call(abi.PmProtocol.ExecElfRequest, .{
                    .arg_map = try caps.Frame.init("initfs:///sbin/sh"),
                    .env_map = try caps.Frame.create(0x1000),
                    .stdio = try @import("main.zig").stdio.clone(),
                }, .{
                    .cap = 1,
                });
            };
        },
    }
}

const Subcommand = enum {
    install,
};

fn help(stdout_writer: abi.ring.RingWriter) !void {
    try std.fmt.format(stdout_writer,
        \\Hiillos Coreutils v0.0.2
        \\usage: coreutils [install]
    , .{});
}
