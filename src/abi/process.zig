const std = @import("std");

const caps = @import("caps.zig");
const util = @import("util.zig");

//

pub fn args() ArgIterator {
    return .{ .inner = std.mem.splitScalar(
        u8,
        arg_map,
        0,
    ) };
}

pub const ArgIterator = struct {
    inner: std.mem.SplitIterator(u8, .scalar),

    pub fn next(self: *@This()) ?[]const u8 {
        while (self.inner.next()) |arg| {
            if (arg.len == 0) continue;
            return arg;
        }
        return null;
    }
};

pub fn env(name: []const u8) ?[]const u8 {
    var it = envs();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.value;
        }
    }
    return null;
}

pub fn envs() EnvIterator {
    return .{ .inner = std.mem.splitScalar(
        u8,
        env_map,
        0,
    ) };
}

pub const EnvIterator = struct {
    inner: std.mem.SplitIterator(u8, .scalar),

    pub const Var = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn next(self: *@This()) ?Var {
        while (self.inner.next()) |entry| {
            if (entry.len == 0) continue;

            var it = std.mem.splitScalar(u8, entry, '=');
            return .{
                .name = it.next().?,
                .value = it.rest(),
            };
        }
        return null;
    }
};

var arg_map: []const u8 = &.{};
var env_map: []const u8 = &.{};

pub fn init() !void {
    const arg_map_frame: caps.Frame = .{ .cap = 5 };
    const env_map_frame: caps.Frame = .{ .cap = 6 };

    // FIXME: make the frames copy-on-write

    const vmem = try caps.Vmem.self();
    defer vmem.close();

    const arg_map_len = try arg_map_frame.getSize();
    const arg_map_addr = try vmem.map(
        arg_map_frame,
        0,
        0,
        0,
        .{},
        .{},
    );
    util.volat(&arg_map).* = @as([*]const u8, @ptrFromInt(arg_map_addr))[0..arg_map_len];

    const env_map_len = try arg_map_frame.getSize();
    const env_map_addr = try vmem.map(
        env_map_frame,
        0,
        0,
        0,
        .{},
        .{},
    );
    util.volat(&env_map).* = @as([*]const u8, @ptrFromInt(env_map_addr))[0..env_map_len];
}
