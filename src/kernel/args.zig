const std = @import("std");

const boot = @import("boot.zig");

const log = std.log.scoped(.args);

//

pub fn parse() !Args {
    const kernel_file_response = boot.kernel_file.response orelse {
        return error.NoKernelFile;
    };

    const cmdline = std.mem.sliceTo(kernel_file_response.executable_file.cmdline(), 0);
    log.info("cmdline: {s}", .{cmdline});

    var args: Args = .{};

    var args_iter = std.mem.splitScalar(u8, cmdline, ' ');
    while (args_iter.next()) |_arg| {
        var arg = std.mem.splitScalar(u8, _arg, '=');
        const first = arg.next() orelse {
            continue;
        };
        const second = arg.rest();

        if (std.mem.eql(u8, first, "root")) {
            args.root_path = second;
        } else if (std.mem.eql(u8, first, "initfs")) {
            args.initfs_path = second;
        }
    }

    const modules_response = boot.modules.response orelse {
        return error.MissingModules;
    };

    for (modules_response.modules()) |module| {
        const path = std.mem.sliceTo(module.path, 0);

        if (std.mem.eql(u8, args.root_path, path)) {
            args.root_data = module.data();
        } else if (std.mem.eql(u8, args.initfs_path, path)) {
            args.initfs_data = module.data();
        }
    }

    if (args.initfs_data.len == 0) {
        return error.MissingInitfs;
    } else if (args.root_data.len == 0) {
        return error.MissingRoot;
    }

    return args;
}

//

pub const Args = struct {
    root_path: []const u8 = "",
    root_data: []const u8 = "",
    initfs_path: []const u8 = "",
    initfs_data: []const u8 = "",
};
