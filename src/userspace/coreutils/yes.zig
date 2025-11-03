const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;
const Ctx = @import("main.zig").Ctx;

//

pub fn main(ctx: Ctx) !void {
    while (true) {
        try ctx.stdout.writeAll("y\n");
        abi.time.sleep(100_000);
        // abi.sys.selfYield();
    }
}
