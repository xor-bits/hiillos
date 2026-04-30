const std = @import("std");
const pmem = @import("pmem.zig");

pub const SelfInfo = @import("debug/SelfInfo.zig");

var arena: std.heap.ArenaAllocator = .init(pmem.page_allocator);
pub fn getDebugInfoAllocator() std.mem.Allocator {
    return arena.allocator();
}

pub fn printLineFromFile(
    _: std.Io,
    _: *std.Io.Writer,
    _: std.debug.SourceLocation,
) !void {
    return error.Unsupported;
}
