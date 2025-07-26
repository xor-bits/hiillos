const std = @import("std");

const caps = @import("caps.zig");
const util = @import("util.zig");

//

pub fn args() ArgIterator {
    return argsOf(arg_map);
}

pub fn argsOf(override_arg_map: []const u8) ArgIterator {
    return .{ .inner = std.mem.splitScalar(
        u8,
        override_arg_map,
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

    pub fn rest(self: *const @This()) []const u8 {
        return self.inner.rest();
    }
};

pub fn env(name: []const u8) ?[]const u8 {
    return envOf(name, env_map);
}

pub fn envOf(name: []const u8, override_env_map: []const u8) ?[]const u8 {
    var it = envsOf(override_env_map);
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.value;
        }
    }
    return null;
}

pub fn envs() EnvIterator {
    return envsOf(env_map);
}

pub fn envsOf(override_env_map: []const u8) EnvIterator {
    return .{ .inner = std.mem.splitScalar(
        u8,
        override_env_map,
        0,
    ) };
}

pub const EnvIterator = struct {
    inner: std.mem.SplitIterator(u8, .scalar),

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

pub const Var = struct {
    name: []const u8,
    value: []const u8,
};

/// copies the current env map and then modifies it
///
/// `remove` is an array of environment keys to be removed
/// `insert` is an array of environment key val pairs to be inserted
pub fn deriveEnvMap(remove: []const []const u8, insert: []const Var) !caps.Frame {
    var size: usize = 0;

    var it = envs();
    while (it.next()) |env_var| {
        if (removeContains(env_var.name, remove) or
            insertContains(env_var.name, insert))
        {
            continue;
        }

        size += 2 + env_var.name.len + env_var.value.len;
    }

    for (insert) |env_var| {
        size += 2 + env_var.name.len + env_var.value.len;
    }

    var derived = try caps.Frame.create(size);
    var derived_stream = derived.stream();
    var derived_buf_stream = std.io.bufferedWriter(derived_stream.writer());
    const derived_writer = derived_buf_stream.writer();

    it = envs();
    while (it.next()) |env_var| {
        if (removeContains(env_var.name, remove) or
            insertContains(env_var.name, insert))
        {
            continue;
        }

        try derived_writer.print("{s}={s}\x00", .{
            env_var.name,
            env_var.value,
        });
    }

    for (insert) |env_var| {
        try derived_writer.print("{s}={s}\x00", .{
            env_var.name,
            env_var.value,
        });
    }

    try derived_buf_stream.flush();
    return derived;
}

fn removeContains(name: []const u8, remove: []const []const u8) bool {
    for (remove) |removed| {
        if (std.mem.eql(u8, name, removed))
            return true;
    }
    return false;
}

fn insertContains(name: []const u8, insert: []const Var) bool {
    for (insert) |inserted| {
        if (std.mem.eql(u8, name, inserted.name))
            return true;
    }
    return false;
}

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
