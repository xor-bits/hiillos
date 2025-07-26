const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const Ctx = @import("main.zig").Ctx;

//

pub fn main(ctx: Ctx) !void {
    var writer = std.io.bufferedWriter(abi.io.stdout.writer());
    var out = writer.writer();
    var first = true;

    while (ctx.args.next()) |arg| {
        if (!first) {
            try out.print(" ", .{});
        }
        first = false;
        try out.print("{s}", .{arg});
    }

    try out.print("\n", .{});
    try writer.flush();
}
