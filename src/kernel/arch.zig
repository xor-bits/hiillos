const std = @import("std");
const builtin = @import("builtin");

pub const x86_64 = @import("arch/x86_64.zig");

//

var cpu_id_next = std.atomic.Value(u32).init(0);
pub fn nextCpuId() u32 {
    return cpu_id_next.fetchAdd(1, .monotonic);
}

pub const earlyInit = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64.earlyInit,
    else => @compileError("unsupported target"),
};

pub const initCpu = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64.initCpu,
    else => @compileError("unsupported target"),
};

pub const smpInit = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64.smpInit,
    else => @compileError("unsupported target"),
};

pub const cpuLocal = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64.cpuLocal,
    else => @compileError("unsupported target"),
};

pub const cpuIdSafe = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64.cpuIdSafe,
    else => @compileError("unsupported target"),
};

pub const cpuCount = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64.cpuCount,
    else => @compileError("unsupported target"),
};

pub const hcf = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64.hcf,
    else => @compileError("unsupported target"),
};

pub const ints = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64.ints,
    else => @compileError("unsupported target"),
};

pub const CpuFeatures = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64.CpuFeatures,
    else => @compileError("unsupported target"),
};

pub const cpuId = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64.cpuId,
    else => @compileError("unsupported target"),
};

pub const reset = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64.reset,
    else => @compileError("unsupported target"),
};

pub const CpuConfig = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64.CpuConfig,
    else => @compileError("unsupported target"),
};

pub const TrapRegs = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64.TrapRegs,
    else => @compileError("unsupported target"),
};

// FIXME: shouldn't be here
pub const FxRegs = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64.FxRegs,
    else => @compileError("unsupported target"),
};
