const std = @import("std");
const abi = @import("abi");

const main = @import("main.zig");

const caps = abi.caps;

const log = std.log.scoped(.ps2kb);

//

pub fn run(controller: *main.Controller) !void {
    _ = controller;
    // var mouse = try Mouse.init(controller);
    // try mouse.run();
}
