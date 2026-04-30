const std = @import("std");
const builtin = @import("builtin");
const kernel = @import("kernel");

//

pub const std_options = kernel.std_options;
pub const panic = kernel.panic;
pub const debug = kernel.debug;
pub const std_options_debug_io = kernel.std_options_debug_io;

const log = std.log.scoped(.@"test");

//

pub fn runTests() usize {
    // help the LSP
    const test_fns: []const std.builtin.TestFn = builtin.test_functions;

    var errors: usize = 0;

    for (test_fns) |test_fn| {
        if (!isBeforeAll(test_fn)) continue;

        errdefer errors += 1;
        test_fn.func() catch |err|
            log.err("test '{s}' failed: {}", .{
                test_fn.name,
                err,
            });
    }

    for (test_fns) |test_fn| {
        if (isBeforeAll(test_fn) or isAfterAll(test_fn)) continue;

        errdefer errors += 1;
        test_fn.func() catch |err|
            log.err("test '{s}' failed: {}", .{
                test_fn.name,
                err,
            });
    }

    for (test_fns) |test_fn| {
        if (!isAfterAll(test_fn)) continue;

        errdefer errors += 1;
        test_fn.func() catch |err|
            log.err("test '{s}' failed: {}", .{
                test_fn.name,
                err,
            });
    }

    return errors;
}

fn isBeforeAll(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isAfterAll(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}
