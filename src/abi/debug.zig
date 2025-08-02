const std = @import("std");

//

pub fn printPanic(
    allocator: std.mem.Allocator,
    writer: anytype,
    name: []const u8,
    msg: []const u8,
    iter: *std.debug.StackIterator,
    dwarf_info: anyerror!std.debug.Dwarf,
    sources: []const SourceFile,
) !void {
    try writer.print("{s} panicked: {s}\nstack trace:\n", .{ name, msg });

    var dwarf = dwarf_info catch |err| {
        try writer.print("failed to open DWARF info: {}\n", .{err});
        while (iter.next()) |r_addr| {
            try writer.print("  \x1B[90m0x{x:0>16}\x1B[0m\n", .{r_addr});
        }
        return;
    };
    defer dwarf.deinit(allocator);

    while (iter.next()) |r_addr| {
        try printSourceAtAddress(
            allocator,
            writer,
            &dwarf,
            r_addr,
            sources,
        );
    }
}

pub fn printSourceAtAddress(
    allocator: std.mem.Allocator,
    writer: anytype,
    debug_info: *std.debug.Dwarf,
    address: usize,
    sources: []const SourceFile,
) !void {
    const sym = debug_info.getSymbol(allocator, address) catch {
        try std.fmt.format(writer, "\x1B[90m0x{x}\x1B[0m\n", .{address});
        return;
    };
    defer if (sym.source_location) |loc| allocator.free(loc.file_name);

    try std.fmt.format(writer, "\x1B[1m", .{});

    if (sym.source_location) |*sl| {
        try std.fmt.format(
            writer,
            "{s}:{d}:{d}",
            .{ sl.file_name, sl.line, sl.column },
        );
    } else {
        try std.fmt.format(writer, "???:?:?", .{});
    }

    try std.fmt.format(
        writer,
        "\x1B[0m: \x1B[90m0x{x} in {s} ({s})\x1B[0m\n",
        .{ address, sym.name, sym.compile_unit_name },
    );

    // std.debug.printSourceAtAddress(debug_info: *SelfInfo, out_stream: anytype, address: usize, tty_config: io.tty.Config)

    const loc = sym.source_location orelse return;
    const source_file = findSourceFile(loc.file_name, sources) orelse return;

    var source_line: []const u8 = "<out-of-bounds>";
    var lines_iter = std.mem.splitScalar(u8, source_file.contents, '\n');
    for (0..loc.line) |_| {
        source_line = lines_iter.next() orelse "<out-of-bounds>";
    }

    try std.fmt.format(writer, "{s}\n", .{source_line});

    const space_needed = @as(usize, @intCast(@max(loc.column, 1) - 1));

    try writer.writeBytesNTimes(" ", space_needed);
    try writer.writeAll("\x1B[92m^\x1B[0m\n");
}

pub fn findSourceFile(
    path: []const u8,
    sources: []const SourceFile,
) ?SourceFile {
    for_loop: for (sources) |s| {
        // b path is a full absolute path,
        // while a is relative to the git repo

        var a = std.fs.path.componentIterator(s.path) catch
            continue;
        var b = std.fs.path.componentIterator(path) catch
            continue;

        const a_last = a.last() orelse continue;
        const b_last = b.last() orelse continue;

        if (!std.mem.eql(u8, a_last.name, b_last.name)) continue;

        while (a.previous()) |a_part| {
            const b_part = b.previous() orelse continue :for_loop;
            if (!std.mem.eql(u8, a_part.name, b_part.name)) continue :for_loop;
        }

        return s;
    }

    return null;
}

pub const SourceFile = struct {
    path: []const u8,
    contents: []const u8,
};

pub fn getSelfDwarf(
    allocator: std.mem.Allocator,
    elf_bin: []const u8,
) !std.debug.Dwarf {
    var elf = std.io.fixedBufferStream(elf_bin);

    const header = try std.elf.Header.read(&elf);

    var sections = std.debug.Dwarf.null_section_array;

    for (sectionsHeaders(elf_bin, header)) |shdr| {
        const name = getString(elf_bin, header, shdr.sh_name);
        // std.log.info("shdr: {s}", .{name});

        if (std.mem.eql(u8, name, ".debug_info")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_info)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_abbrev")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_abbrev)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_str")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_str)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_line")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_line)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_ranges")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_ranges)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".eh_frame")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.eh_frame)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".eh_frame_hdr")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.eh_frame_hdr)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        }
    }

    var dwarf: std.debug.Dwarf = .{
        .endian = .little,
        .sections = sections,
        .is_macho = false,
    };

    try dwarf.open(allocator);
    return dwarf;
}

fn getString(bin: []const u8, header: std.elf.Header, off: u32) []const u8 {
    const strtab = getSectionData(
        bin,
        sectionsHeaders(bin, header)[header.shstrndx],
    );
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(strtab.ptr + off)), 0);
}

fn getSectionData(bin: []const u8, shdr: std.elf.Elf64_Shdr) []const u8 {
    return bin[shdr.sh_offset..][0..shdr.sh_size];
}

fn sectionsHeaders(bin: []const u8, header: std.elf.Header) []const std.elf.Elf64_Shdr {
    // FIXME: bounds checking maybe
    const section_headers: [*]const std.elf.Elf64_Shdr = @alignCast(@ptrCast(bin.ptr + header.shoff));
    return section_headers[0..header.shnum];
}

fn sectionFromSym(start: *const u8, end: *const u8) std.debug.Dwarf.Section {
    const size = @intFromPtr(end) - @intFromPtr(start);
    const addr = @as([*]const u8, @ptrCast(start));
    return .{
        .data = addr[0..size],
        .owned = false,
    };
}
