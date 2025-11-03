const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const Ctx = @import("main.zig").Ctx;

//

pub fn main(ctx: Ctx) !void {
    var first = true;

    while (ctx.args.next()) |arg| {
        if (!first) {
            try ctx.stdout.print(" ", .{});
        }
        first = false;
        try ctx.stdout.print("{s}", .{arg});
    }

    try ctx.stdout.print("\n", .{});
}
