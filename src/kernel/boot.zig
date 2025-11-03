const std = @import("std");
const builtin = @import("builtin");

//

const limine_common_magic: [2]u64 = .{
    0xc7b1dd30df4c8b88, 0x0a82e883a194f07b,
};

//

pub export var base_revision: BaseRevision = .{};

pub const BaseRevision = extern struct {
    id: [2]u64 = .{
        0xf9562b2d5c95a6c8, 0x6a7b384944536bdc,
    },
    revision: u64 = 2,

    pub fn isSupported(self: *const @This()) bool {
        return self.revision == 0;
    }
};

//

pub export var hhdm: LimineHhdmRequest = .{};

pub const LimineHhdmRequest = extern struct {
    id: [4]u64 = limine_common_magic ++ .{
        0x48dcf1cb8ad2b852, 0x63984e959a98244b,
    },
    revision: u64 = 0,
    response: ?*LimineHhdmResponse = null,
};

pub const LimineHhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

//

pub export var memory: LimineMemmapRequest = .{};

pub const LimineMemmapRequest = extern struct {
    id: [4]u64 = limine_common_magic ++ .{
        0x67cf3d9d378a806f, 0xe304acdfc50c3c62,
    },
    revision: u64 = 0,
    response: ?*LimineMemmapResponse = null,
};

pub const LimineMemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    raw_entries: [*]*LimineMemmapEntry,

    pub fn entries(self: *const @This()) []*LimineMemmapEntry {
        return self.raw_entries[0..self.entry_count];
    }
};

pub const LimineMemmapEntry = extern struct {
    base: u64,
    len: u64,
    ty: LimineMemmapType,
};

pub const LimineMemmapType = enum(u64) {
    usable,
    reserved,
    acpi_reclaimable,
    acpi_nvs,
    bad_memory,
    bootloader_reclaimable,
    executable_and_modules,
    framebuffer,
    acpi_tables,
    _,
};

//

pub export var framebuffer: LimineFramebufferRequest = .{};

pub const LimineFramebufferRequest = extern struct {
    id: [4]u64 = limine_common_magic ++ .{
        0x9d5827dcd881dd75, 0xa3148604f6fab11b,
    },
    revision: u64 = 0,
    response: ?*LimineFramebufferResponse = null,
};

pub const LimineFramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    raw_framebuffers: [*]*LimineFramebuffer,

    pub fn framebuffers(self: *const @This()) []*LimineFramebuffer {
        return self.raw_framebuffers[0..self.framebuffer_count];
    }
};

pub const LimineFramebuffer = extern struct {
    address: [*]u8,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: enum(u8) {
        rgb = 1,
        _,
    },
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    _: [7]u8,
    edid_size: u64,
    edid: ?[*]u8,

    // response revision 1
    // mode_count: u64;
    // modes: [*]*LimineVideoMode,
};

//

pub export var cmdline: LimineExecutableCmdlineRequest = .{};

pub const LimineExecutableCmdlineRequest = extern struct {
    id: [4]u64 = limine_common_magic ++ .{
        0x4b161536e598651e, 0xb390ad4a2f1f303a,
    },
    revision: u64 = 0,
    response: ?*LimineExecutableCmdlineResponse = null,
};

pub const LimineExecutableCmdlineResponse = extern struct {
    revision: u64 = 0,
    cmdline: [*:0]u8,
};

//

pub export var kernel_file: LimineExecutableFileRequest = .{};

pub const LimineExecutableFileRequest = extern struct {
    id: [4]u64 = limine_common_magic ++ .{
        0xad97e90e83f1ed67, 0x31eb5d1c5ff23b69,
    },
    revision: u64 = 0,
    response: ?*LimineExecutableFileResponse = null,
};

pub const LimineExecutableFileResponse = extern struct {
    revision: u64 = 0,
    executable_file: *LimineFile,
};

//

pub export var modules: LimineModuleRequest = .{};

pub const LimineModuleRequest = extern struct {
    id: [4]u64 = limine_common_magic ++ .{
        0x3e7e279702be32af, 0xca1c4f3bd1280cee,
    },
    revision: u64 = 0,
    response: ?*LimineModuleResponse = null,

    internal_module_count: u64 = 0,
    internal_modules: [*c]*anyopaque = null,
};

pub const LimineModuleResponse = extern struct {
    revision: u64,
    module_count: u64,
    raw_modules: [*]*LimineFile,

    pub fn modules(self: *const @This()) []*LimineFile {
        return self.raw_modules[0..self.module_count];
    }
};

//

pub const LimineFile = extern struct {
    revision: u64,
    address: [*]u8,
    len: u64,
    path: [*:0]u8,
    string: [*:0]u8,
    media_type: enum(u32) {
        generic,
        optical,
        tftp,
        _,
    },
    _: u32,
    tftp_ip: u32,
    tftp_port: u32,
    partition_index: u32,
    mbr_disk_id: u32,
    gpt_disk_uuid: LimineUuid,
    gpt_part_uuid: LimineUuid,
    disk_uuid: LimineUuid,

    pub fn data(self: *const @This()) []u8 {
        return self.address[0..self.len];
    }

    pub fn cmdline(self: *const @This()) [*:0]u8 {
        return self.string;
    }
};

pub const LimineUuid = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: u64,
};

//

pub export var mp: LimineMpRequest = .{
    .flags = .{ .request_x86_64_x2apic = true },
};

pub const LimineMpRequest = extern struct {
    id: [4]u64 = limine_common_magic ++ .{
        0x95a67b819a1b857e, 0xa0b61b723b6a73e0,
    },
    revision: u64 = 0,
    response: ?*LimineMpResponse = null,
    flags: packed struct {
        request_x86_64_x2apic: bool,
        _: u63 = 0,
    },
};

pub const LimineMpResponse = switch (builtin.cpu.arch) {
    .x86_64 => extern struct {
        revision: u64,
        flags: u32,
        bsp_lapic_id: u32,
        cpu_count: u64,
        cpus_raw: [*]*LimineMpInfo,

        pub fn cpus(self: *const @This()) []*LimineMpInfo {
            return self.cpus_raw[0..self.cpu_count];
        }
    },
    else => @compileError("unsupported target"),
};

pub const LimineMpInfo = extern struct {
    processor_id: u32,
    lapic_id: u32,
    reserved: u64,
    goto_address: std.atomic.Value(*const fn (mp_info: *LimineMpInfo) callconv(.c) void),
    extra_arg: u64,
};

//

pub export var rsdp: LimineRsdpRequest = .{};

pub const LimineRsdpRequest = extern struct {
    id: [4]u64 = limine_common_magic ++ .{
        0xc5e77b6b397e7b43, 0x27637845accdcf3c,
    },
    revision: u64 = 0,
    response: ?*LimineRsdpResponse = null,
};

pub const LimineRsdpResponse = extern struct {
    revision: u64,
    address: [*]u8,
};
