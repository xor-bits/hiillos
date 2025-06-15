const std = @import("std");
const caps = @import("caps.zig");
const loader = @import("loader.zig");
const builtin = @import("builtin");

const page_size = 0x1000;
const buf_cap = page_size / @sizeOf(u64); // 4 KiB (512 q-words)

/// architecture-specific relative relocation type used in .rel[a] sections
const rel_type_relative: u32 = switch (builtin.target.cpu.arch) {
    .x86_64 => @intFromEnum(std.elf.R_X86_64.RELATIVE),
    else => @compileError("unsupported architecture for relocator"),
};

pub inline fn r_sym(comptime T: type, info: T) u32 {
    return switch (@sizeOf(T)) {
        8 => @intCast((@as(u64, info) >> 32)),
        4 => @intCast((@as(u32, info) >> 8)),
        else => @compileError("unsupported r_info size"),
    };
}

/// extract relocation type from `r_info`
pub inline fn r_type(comptime T: type, info: T) u32 {
    return switch (@sizeOf(T)) {
        8 => @intCast((@as(u64, info) & 0xffff_ffff)),
        4 => @intCast((@as(u32, info) & 0xff)),
        else => @compileError("unsupported r_info size"),
    };
}

/// compose a 32-bit `r_info` value
pub inline fn elf32_r_info(sym: u32, typ: u8) u32 {
    return (sym << 8) | typ;
}

/// compose a 64-bit `r_info` value
pub inline fn elf64_r_info(sym: u32, typ: u32) u64 {
    return (@as(u64, sym) << 32) | typ;
}

/// picks 32- vs 64-bit based on pointer size
pub inline fn r_info(sym: u32, typ: u32) std.elf.Addr {
    return switch (@sizeOf(std.elf.Addr)) {
        4 => elf32_r_info(sym, @intCast(typ)),
        8 => elf64_r_info(sym, @intCast(typ)),
        else => @compileError("unsupported Addr size"),
    };
}

pub fn relocate(vmem: caps.Vmem, bin: []const u8, base: usize) !void {
    var elf = try loader.Elf.init(bin);

    for (try elf.getSections()) |sh| switch (sh.sh_type) {
        std.elf.SHT_RELA => try handleRela(&elf, vmem, sh, base),
        std.elf.SHT_REL => try handleRel(&elf, vmem, sh, base),
        else => {},
    };
}

inline fn flush(
    vmem: caps.Vmem,
    addr: usize,
    new_qwords: []const u64,
    scratch: []u64,
) !void {
    if (new_qwords.len == 0) return;

    std.log.info("relocator write to 0x{x}", .{addr});

    const scratch_bytes = scratch[0..new_qwords.len]; // same u64 view
    try vmem.read(addr, std.mem.sliceAsBytes(scratch_bytes));

    if (std.mem.eql(u64, scratch_bytes, new_qwords))
        return; // no change

    try vmem.write(addr, std.mem.sliceAsBytes(new_qwords));
}

// rela
fn handleRela(
    elf: *loader.Elf,
    vmem: caps.Vmem,
    sh: std.elf.Elf64_Shdr,
    base: usize,
) !void {
    std.log.info("found rela", .{});
    const raw = try loader.Elf.getSectionData(elf.data, sh);
    if (raw.len == 0) return;

    const Entry = std.elf.Elf64_Rela;
    const rela_entries = try bytesAsEntries(Entry, raw);

    var write_buffer: [buf_cap]u64 = undefined;
    var compare_buffer: [buf_cap]u64 = undefined;
    var block_start_addr: usize = 0;
    var qword_count: usize = 0;

    for (rela_entries) |rela| {
        if (r_type(u64, rela.r_info) != rel_type_relative)
            return error.UnsupportedRelocationType;

        const dst_addr = base + @as(usize, @intCast(rela.r_offset));
        const new_val = base + @as(usize, @intCast(rela.r_addend));

        const contiguous = qword_count != 0 and dst_addr == block_start_addr + qword_count * 8;
        const same_page = qword_count == 0 or ((dst_addr ^ block_start_addr) & ~(@as(usize, page_size - 1))) == 0;

        if (!contiguous or !same_page or qword_count == buf_cap) {
            try flush(vmem, block_start_addr, write_buffer[0..qword_count], &compare_buffer);
            block_start_addr = dst_addr;
            qword_count = 0;
        }

        write_buffer[qword_count] = new_val;
        qword_count += 1;
    }
    try flush(vmem, block_start_addr, write_buffer[0..qword_count], &compare_buffer);
}

// rel
fn handleRel(
    elf: *loader.Elf,
    vmem: caps.Vmem,
    sh: std.elf.Elf64_Shdr,
    base: usize,
) !void {
    std.log.info("found rel", .{});
    const raw = try loader.Elf.getSectionData(elf.data, sh);
    if (raw.len == 0) return;

    const Entry = std.elf.Elf64_Rel;
    const rel_entries = try bytesAsEntries(Entry, raw);

    var write_buffer: [buf_cap]u64 = undefined;
    var compare_buffer: [buf_cap]u64 = undefined;
    var block_start_addr: usize = 0;
    var qword_count: usize = 0;

    for (rel_entries) |rel| {
        if (r_type(u64, rel.r_info) != rel_type_relative)
            return error.UnsupportedRelocation;

        const dst_addr = base + @as(usize, @intCast(rel.r_offset));

        var tmp_val_qword: u64 = 0;
        try vmem.read(dst_addr, std.mem.asBytes(&tmp_val_qword));
        const new_val = base + @as(usize, @intCast(tmp_val_qword));

        const contiguous = qword_count != 0 and dst_addr == block_start_addr + qword_count * 8;
        const same_page = qword_count == 0 or ((dst_addr ^ block_start_addr) & ~(@as(usize, page_size - 1))) == 0;

        if (!contiguous or !same_page or qword_count == buf_cap) {
            try flush(vmem, block_start_addr, write_buffer[0..qword_count], &compare_buffer);
            block_start_addr = dst_addr;
            qword_count = 0;
        }

        write_buffer[qword_count] = new_val;
        qword_count += 1;
    }
    try flush(vmem, block_start_addr, write_buffer[0..qword_count], &compare_buffer);
}

fn bytesAsEntries(comptime Entry: type, raw: []const u8) ![]const Entry {
    if (raw.len % @sizeOf(Entry) != 0) return error.MalformedSection;
    const ptr = @as([*]const Entry, @alignCast(@ptrCast(raw.ptr)));
    return ptr[0 .. raw.len / @sizeOf(Entry)];
}

test "r_info 32-bit" {
    const sym: u32 = 0xABCD;
    const typ: u8 = 0x11;

    const pack = elf32_r_info(sym, typ);
    try std.testing.expectEqual(sym, r_sym(u32, pack));

    try std.testing.expectEqual(@as(u32, typ), r_type(u32, pack));
}

test "r_info 64-bit" {
    const sym: u32 = 0xDEAD_BEEF;
    const typ: u32 = 0x1234_5678;

    const pack = elf64_r_info(sym, typ);
    try std.testing.expectEqual(sym, r_sym(u64, pack));

    try std.testing.expectEqual(typ, r_type(u64, pack));
}

test "r_info wrapper" {
    const sym: u32 = 0x1357_9BDF;
    const typ: u32 = 0x2468_ACF0;

    const addr_type = @TypeOf(r_info(sym, typ));
    const pack = r_info(sym, typ);

    if (@sizeOf(addr_type) == 4) {
        try std.testing.expectEqual(elf32_r_info(sym, @intCast(typ)), pack);
    } else {
        try std.testing.expectEqual(elf64_r_info(sym, typ), pack);
    }
}
