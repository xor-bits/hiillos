const std = @import("std");

pub fn writePartition(
    alloc: std.mem.Allocator,
    writer: *std.fs.File.Writer,
    root: std.fs.Dir,
    sector_size: u16,
    physical_sector: u32,
) !usize {
    var info: Info = .{
        .sector_size = sector_size,
        .sectors_per_cluster = 1,
        .bytes_per_cluster = 1 * sector_size,
        .physical_sector = physical_sector,
    };

    var tree = try collectTree(
        alloc,
        root,
        info.bytes_per_cluster,
    );
    defer tree.deinit(alloc);

    info.total_clusters = @max(tree.clustersNeeded(), 65525);
    // std.debug.print("{} clusters\n", .{info.total_clusters});

    // calculate how big the FATs can be,
    // it can grows all the way to the cluster alignment
    const reserved_sectors = 2;
    const fat_region_min_bytes = info.total_clusters * @sizeOf(u32) * 2;
    const fat_region_min_sectors = ceilDiv(fat_region_min_bytes, info.sector_size);
    const fat_region_start_sector = reserved_sectors;
    const fat_region_end_sector = ceilMultipleOf(
        reserved_sectors + fat_region_min_sectors,
        info.sectors_per_cluster,
    );
    const fat_region_sectors = fat_region_end_sector - fat_region_start_sector;
    std.debug.assert(ceilMultipleOf(fat_region_sectors, 2) == fat_region_sectors);
    info.fat_table_sectors = @divExact(fat_region_sectors, 2);
    info.fat_table_len = info.fat_table_sectors * sector_size / @sizeOf(u32);

    var sector_alloc: Bump = .{};
    info.boot_record_sector = sector_alloc.alloc(1);
    info.fs_info_sector = sector_alloc.alloc(1);
    info.fat_region_sector = sector_alloc.alloc(fat_region_sectors);
    info.data_region_sector = sector_alloc.next;
    std.debug.assert(ceilMultipleOf(
        info.data_region_sector,
        info.sectors_per_cluster,
    ) == info.data_region_sector);
    std.debug.assert(info.boot_record_sector == 0);
    const data_region_sectors = @as(u64, info.total_clusters) * info.sectors_per_cluster;
    info.total_sectors = info.data_region_sector + data_region_sectors;

    var cluster_alloc: Bump = .{};
    _ = cluster_alloc.alloc(2);
    for (tree.dirs.items) |*dir| {
        dir.cluster = cluster_alloc.alloc(1);
    }
    for (tree.files.items) |*file| {
        file.cluster = cluster_alloc.alloc(file.clusters);
    }

    std.debug.assert(writer.pos + writer.interface.end ==
        (info.boot_record_sector + info.physical_sector) * info.sector_size);
    try writeBootRecord(
        &writer.interface,
        info,
    );
    std.debug.assert(writer.pos + writer.interface.end ==
        (info.fs_info_sector + info.physical_sector) * info.sector_size);
    try writeFsInfo(
        &writer.interface,
        info,
    );
    std.debug.assert(writer.pos + writer.interface.end ==
        (info.fat_region_sector + info.physical_sector) * info.sector_size);
    try writeFatRegion(
        &writer.interface,
        info,
        &tree,
    );
    std.debug.assert(writer.pos + writer.interface.end ==
        (info.data_region_sector + info.physical_sector) * info.sector_size);
    try writeDataRegion(
        &writer.interface,
        info,
        &tree,
    );

    return info.total_sectors;
}

fn ceilDiv(num: u32, denom: u32) u32 {
    return std.math.divCeil(
        u32,
        num,
        denom,
    ) catch unreachable;
}

fn ceilMultipleOf(v: u32, base: u32) u32 {
    return ceilDiv(v, base) * base;
}

const Tree = struct {
    arena: std.heap.ArenaAllocator,
    dirs: std.ArrayList(Dir) = .{},
    files: std.ArrayList(File) = .{},
    // absolute_path: []const u8,
    // lookup: std.StringArrayHashMapUnmanaged() = .{},

    fn parentDir(
        self: *@This(),
        alloc: std.mem.Allocator,
        full_path: [:0]const u8,
    ) !u16 {
        const dir_path = std.fs.path.dirname(full_path) orelse
            return error.InvalidPath;
        // const relative_path = try std.fs.path.relative(
        //     alloc,
        //     self.absolute_path,
        //     dir_path,
        // );
        // defer alloc.free(relative_path);

        // std.debug.print("full_path={s}\ndir_path={s}\nrelative_path={s}\nbase_path={s}\n", .{
        //     full_path, dir_path, relative_path, self.absolute_path,
        // });

        if (self.dirs.items.len == 0) {
            try self.dirs.append(alloc, .{
                .basename = "",
                .parent = 0,
            });
        }

        var it = try std.fs.path.componentIterator(dir_path);
        var cur: u16 = 0;
        while (it.next()) |dir| {
            cur = self.findDir(cur, dir.name) orelse
                try self.pushDir(alloc, cur, .{
                    .basename = try self.arena.allocator()
                        .dupe(u8, dir.name),
                    .parent = cur,
                });
        }
        return cur;
    }

    fn findDir(
        self: *const @This(),
        dir: u16,
        next: []const u8,
    ) ?u16 {
        const d = self.dirs.items[dir];
        for (d.dirs[0..d.dirs_count]) |subdir| {
            const sd = self.dirs.items[subdir];
            if (std.mem.eql(u8, sd.basename, next)) {
                return subdir;
            }
        }
        return null;
    }

    fn pushDir(
        self: *@This(),
        alloc: std.mem.Allocator,
        dir: u16,
        subdir: Dir,
    ) !u16 {
        try self.dirs.ensureUnusedCapacity(alloc, 1);

        const d = &self.dirs.items[dir];
        if (d.dirs_count == 128) return error.TooManySubdirectories;

        const id: u16 = @intCast(self.dirs.items.len);
        self.dirs.append(alloc, subdir) catch unreachable;

        d.dirs[d.dirs_count] = id;
        d.dirs_count += 1;
        return id;
    }

    fn pushFile(
        self: *@This(),
        alloc: std.mem.Allocator,
        dir: u16,
        file: File,
    ) !u16 {
        const d = &self.dirs.items[dir];
        if (d.files_count == 128) return error.TooManyFiles;

        const id: u16 = @intCast(self.files.items.len);
        try self.files.append(alloc, file);

        d.files[d.files_count] = id;
        d.files_count += 1;
        return id;
    }

    fn clustersNeeded(
        self: *const @This(),
    ) u32 {
        var clusters: u32 = @intCast(self.dirs.items.len);
        for (self.files.items) |file| {
            clusters += file.clusters;
        }
        return clusters;
    }

    fn deinit(
        self: *@This(),
        alloc: std.mem.Allocator,
    ) void {
        for (self.files.items) |f|
            f.inner.close();
        self.dirs.deinit(alloc);
        self.files.deinit(alloc);
        self.arena.deinit();
    }
};

const Dir = struct {
    basename: []const u8,
    dirs: [128]u16 = undefined,
    dirs_count: u8 = 0,
    files: [128]u16 = undefined,
    files_count: u8 = 0,
    parent: u16,
    cluster: u32 = 0,
};

const File = struct {
    basename: []const u8,
    inner: std.fs.File,
    clusters: u32,
    size: u32 = 0,
    parent: u16,
    cluster: u32 = 0,
};

fn collectTree(
    alloc: std.mem.Allocator,
    root: std.fs.Dir,
    bytes_per_cluster: u64,
) !Tree {
    var tree: Tree = .{
        .arena = .init(alloc),
        // .absolute_path = "",
    };
    // tree.absolute_path = try root.realpathAlloc(
    //     tree.arena.allocator(),
    //     ".",
    // );

    var walker = try root.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const file = try entry.dir.openFile(
                    entry.basename,
                    .{},
                );
                errdefer file.close();
                const stat = try file.stat();
                const clusters = std.math.divCeil(
                    u64,
                    stat.size,
                    bytes_per_cluster,
                ) catch unreachable;

                const dir_id = try tree.parentDir(
                    alloc,
                    entry.path,
                );
                _ = try tree.pushFile(alloc, dir_id, .{
                    .basename = try tree.arena.allocator()
                        .dupe(u8, entry.basename),
                    .clusters = @intCast(clusters),
                    .size = @intCast(stat.size),
                    .inner = file,
                    .parent = dir_id,
                });
            },
            else => {},
        }
    }

    for (tree.files.items) |file| {
        // std.debug.print("{s}", .{file.basename});
        var cur = file.parent;
        while (cur != 0) {
            const parent = tree.dirs.items[cur];
            // std.debug.print(" -> {s}", .{parent.basename});
            cur = parent.parent;
        }
        // std.debug.print("\n", .{});
    }

    return tree;
}

fn estimateSize(
    alloc: std.mem.Allocator,
    root: std.fs.Dir,
    bytes_per_cluster: u64,
) !SizeEstimation {
    var walker = try root.walk(alloc);
    defer walker.deinit();

    var size: SizeEstimation = .{};
    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const stat = try entry.dir.statFile(
                    entry.basename,
                );
                const clusters = std.math.divCeil(
                    u64,
                    stat.size,
                    bytes_per_cluster,
                ) catch unreachable;

                size.files += 1;
                size.clusters_for_files += @intCast(clusters);
            },
            .directory => {
                size.dirs += 1;
            },
            else => {},
        }
    }
    return size;
}

const SizeEstimation = struct {
    dirs: u32 = 0,
    files: u32 = 0,
    clusters_for_files: u32 = 0,

    fn merge(a: @This(), b: @This()) @This() {
        return .{
            .dirs = a.dirs + b.dirs,
            .files = a.files + b.files,
            .clusters_for_files = a.clusters_for_files + b.clusters_for_files,
        };
    }
};

const Info = struct {
    sector_size: u16,
    sectors_per_cluster: u8,
    bytes_per_cluster: u32,
    physical_sector: u32,

    total_clusters: u32 = 0,
    total_sectors: u64 = 0,
    fat_table_len: u32 = 0,
    fat_table_sectors: u32 = 0,
    boot_record_sector: u32 = 0,
    fs_info_sector: u32 = 0,
    fat_region_sector: u32 = 0,
    data_region_sector: u32 = 0,
};

const Bump = struct {
    next: u32 = 0,

    fn alloc(self: *@This(), n: u32) u32 {
        defer self.next += n;
        return self.next;
    }
};

fn writeFatRegion(
    writer: *std.Io.Writer,
    info: Info,
    tree: *const Tree,
) !void {
    const fat_table = try std.heap.page_allocator.alloc(u32, info.fat_table_len);
    defer std.heap.page_allocator.free(fat_table);

    const last_cluster = 0x0fff_fff8;
    const free_cluster = 0;
    @memset(fat_table, free_cluster);
    fat_table[0] = 0x0fff_fff8; // hard disk media, not "last cluster"
    fat_table[1] = 0x0fff_ffff; // reserved

    for (tree.dirs.items) |dir| {
        std.debug.assert(dir.cluster >= 2);
        fat_table[dir.cluster] = last_cluster;
    }
    for (tree.files.items) |file| {
        std.debug.assert(file.cluster >= 2);
        for (0..file.clusters) |i| {
            const next = if (i == file.clusters)
                last_cluster
            else
                file.cluster + @as(u32, @intCast(i)) + 1;
            fat_table[file.cluster + i] = next;
        }
    }

    try writer.writeAll(std.mem.sliceAsBytes(fat_table));
    try writer.writeAll(std.mem.sliceAsBytes(fat_table));
}

fn writeDataRegion(
    writer: *std.Io.Writer,
    info: Info,
    tree: *const Tree,
) !void {
    // every cluster in the tree is in order,
    // all dirs first in order, then all files in order

    var next: u32 = 2;
    for (tree.dirs.items, 0..) |dir, i| {
        std.debug.assert(next == dir.cluster);
        next = dir.cluster + 1;

        // std.debug.print("building dir {s} (i={})\n", .{ dir.basename, i });

        var entries: u32 = 0;
        if (i != 0) {
            // root is i=0
            // std.debug.print(". = {}\n", .{dir.cluster});
            entries += try writeDirEntry(
                writer,
                ".",
                dir.cluster,
                null,
            );
            const real_parent = tree.dirs.items[dir.parent].cluster;
            const parent = if (real_parent == 2) 0 else real_parent;
            // std.debug.print(".. = {}\n", .{parent});
            entries += try writeDirEntry(
                writer,
                "..",
                parent,
                null,
            );
        }

        for (dir.dirs[0..dir.dirs_count]) |subdir_id| {
            const subdir = tree.dirs.items[subdir_id];
            // std.debug.print("subdir {s} (i={})\n", .{ subdir.basename, subdir_id });
            entries += try writeDirEntry(
                writer,
                subdir.basename,
                subdir.cluster,
                null,
            );
        }
        for (dir.files[0..dir.files_count]) |file_id| {
            const file = tree.files.items[file_id];
            // std.debug.print("file {s} (i={})\n", .{ file.basename, file_id });
            entries += try writeDirEntry(
                writer,
                file.basename,
                file.cluster,
                file.size,
            );
        }
        const pad = info.bytes_per_cluster - entries * @sizeOf(DirEntry);
        // std.debug.print("dir padding {} (for {} entries bpc{})\n", .{
        //     pad, entries, info.bytes_per_cluster,
        // });
        try writer.splatByteAll('\x00', pad);
    }
    for (tree.files.items) |file| {
        std.debug.assert(next == file.cluster);
        next = file.cluster + file.clusters;

        var file_reader = file.inner.reader(&.{});
        const written = try file_reader.interface.streamRemaining(writer);

        if (written != file.size)
            return error.FileChangedWhileReading;

        const pad = file.clusters * info.bytes_per_cluster - written;
        try writer.splatByteAll('\x00', pad);
    }
}

/// returns the number of entries actually written
fn writeDirEntry(
    writer: *std.Io.Writer,
    basename: []const u8,
    cluster: u32,
    file_size: ?u32,
) !u5 {
    var entry: DirEntry = .{
        .attibs = .{ .subdir = file_size == null },
        .first_cluster_high = @truncate(cluster >> 16),
        .first_cluster_low = @truncate(cluster),
        .file_size = file_size orelse 0,
    };
    const lfn_entries = try entry.setupName(writer, basename);
    try writer.writeStruct(entry, .little);
    return lfn_entries + 1;
}

fn writeBootRecord(
    writer: *std.Io.Writer,
    info: Info,
) !void {
    const total_sectors_u16_or_null = std.math.cast(u16, info.total_sectors);
    const total_sectors_u32_or_null = std.math.cast(u32, info.total_sectors);

    // std.debug.print("info={any}\n", .{info});

    try writer.writeStruct(BootRecord{
        .bpb = .{
            .bytes_per_sector = info.sector_size,
            .sectors_per_cluster = info.sectors_per_cluster,
            .total_sectors_or_zero = total_sectors_u16_or_null orelse 0,
            .total_sectors = total_sectors_u32_or_null orelse 0,
        },
        .ext = .{
            .sectors_per_fat = info.fat_table_sectors,
            .fs_info_sector = @intCast(info.fs_info_sector),
        },
    }, .little);
    const pad = info.sector_size - @sizeOf(BootRecord);
    _ = try writer.splatByteAll('\x00', pad);
}

fn writeFsInfo(
    writer: *std.Io.Writer,
    info: Info,
) !void {
    try writer.writeStruct(FsInfo{}, .little);
    const pad = info.sector_size - @sizeOf(FsInfo);
    _ = try writer.splatByteAll('\x00', pad);
}

const BootRecord = packed struct {
    bpb: BiosParameterBlock,
    ext: ExtendedBootRecord,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 512);
    }
};

const BiosParameterBlock = packed struct {
    infinite_loop_code: u24 = 0x90_feeb,
    oem: u64 = 0x3233_7461_662e_6968, // hi.fat32
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16 = 2,
    file_allocation_tables: u8 = 2,
    root_directory_entries: u16 = 0,
    // zero means it is in total_sectors
    total_sectors_or_zero: u16,
    media_descriptor_type: u8 = 0xf8,
    _: u16 = 0,
    sectors_per_track: u16 = 63,
    heads: u16 = 32,
    hidden_sectors: u32 = 0,
    total_sectors: u32,
};

const ExtendedBootRecord = packed struct {
    sectors_per_fat: u32,
    flags: u16 = 0,
    fat_version_minor: u8 = 0,
    fat_version_major: u8 = 0,
    root_directory_cluster: u32 = 2,
    fs_info_sector: u16,
    backup_boot_sector: u16 = 0,
    _0: u96 = 0,
    drive_number: u8 = 0x80,
    _1: u8 = 0,
    signature: u8 = 0x29,
    volume_id: u32 = 1,
    volume_label: u88 = 0x20_6d65_7473_7953_2049_4645, // "EFI System "
    system_identifier: u64 = 0x2020_2032_3354_4146, // "FAT32   "
    boot_code: u3360 = 0,
    bootable_partition_signature: u16 = 0xaa55,
};

const FsInfo = extern struct {
    signature_a: u32 = 0x4161_5252,
    _0: [480]u8 = [_]u8{0} ** 480,
    signature_b: u32 = 0x6141_7272,
    volume_cluster_count_hint: u32 = 0xffff_ffff,
    volume_cluster_start_hint: u32 = 0xffff_ffff,
    _1: [3]u32 = [_]u32{0} ** 3,
    signature_c: u32 = 0xaa55_0000,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 512);
    }
};

const DirEntry = extern struct {
    short_name: [8]u8 = [_]u8{' '} ** 8,
    short_ext: [3]u8 = [_]u8{' '} ** 3,
    attibs: packed struct {
        read_only: bool = false,
        hidden: bool = false,
        system: bool = false,
        volume_label: bool = false,
        subdir: bool = false,
        archive: bool = false,
        device: bool = false,
        _: bool = false,
    } = .{},
    extra_attribs: u8 = 0,
    _: u8 = 0,
    created_time: Time = .{},
    created_date: Date = .{},
    access_date: Date = .{},
    // access: packed struct {
    //     owner_delete_restrict: bool = 0,
    //     owner_execute_restrict: bool = 0,
    //     owner_write_restrict: bool = 0,
    //     owner_read_restrict: bool = 0,
    //     group_delete_restrict: bool = 0,
    //     group_execute_restrict: bool = 0,
    //     group_write_restrict: bool = 0,
    //     group_read_restrict: bool = 0,
    //     world_delete_restrict: bool = 0,
    //     world_execute_restrict: bool = 0,
    //     world_write_restrict: bool = 0,
    //     world_read_restrict: bool = 0,
    //     _: u4 = 0,
    // } = .{},
    first_cluster_high: u16,
    modified_time: Time = .{},
    modified_date: Date = .{},
    first_cluster_low: u16,
    file_size: u32,

    /// returns the number of extra LFN entries inserted
    fn setupName(
        self: *@This(),
        writer: *std.Io.Writer,
        basename: []const u8,
    ) !u5 {
        if (basename.len >= 255)
            return error.FilenameTooLong;

        if (std.mem.eql(u8, basename, ".") or
            std.mem.eql(u8, basename, ".."))
        {
            std.mem.copyForwards(u8, &self.short_name, basename);
            return 0;
        }

        const stem = std.fs.path.stem(basename);
        const ext_with_dot = std.fs.path.extension(basename);
        const ext_without_dot = if (ext_with_dot.len == 0)
            ext_with_dot
        else
            ext_with_dot[1..];

        const name_len = @min(stem.len, 8);
        const ext_len = @min(ext_without_dot.len, 3);

        @memcpy(self.short_name[0..name_len], stem[0..name_len]);
        @memcpy(self.short_ext[0..ext_len], ext_without_dot[0..ext_len]);

        for (&self.short_name) |*b|
            b.* = std.ascii.toUpper(b.*);
        for (&self.short_ext) |*b|
            b.* = std.ascii.toUpper(b.*);

        // insert LFN entries before the normal entry is inserted

        if (stem.len <= 8 and ext_without_dot.len <= 3) return 0;

        const checksum = LongFileNameEntry.dosNameChecksum(
            self.short_name,
            self.short_ext,
        );
        const len: u8 = @intCast(basename.len);

        const lfn_entries: u5 = @intCast(ceilDiv(len, 13));
        const last_lfn_entry_len = len - (lfn_entries - 1) * 13;

        var next_len = last_lfn_entry_len;
        var name_left = basename;
        var i = lfn_entries;
        while (i != 0) : (i -= 1) {
            const part = name_left[name_left.len - next_len ..];
            name_left = name_left[0 .. name_left.len - next_len];
            next_len = 13;

            var entry: LongFileNameEntry = .{
                .sequence = .{
                    .number = i,
                    .last_logical = i == lfn_entries,
                },
                .dos_name_checksum = checksum,
            };
            entry.setupName(part);
            try writer.writeStruct(entry, .little);
        }
        std.debug.assert(name_left.len == 0);
        return lfn_entries;
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

const LongFileNameEntry = extern struct {
    sequence: packed struct {
        number: u5,
        _0: bool = false,
        last_logical: bool,
        _1: bool = false,
    },
    name0: [5]u16 align(1) = [_]u16{0} ** 5,
    attribs: u8 = 0x0f,
    ty: u8 = 0,
    dos_name_checksum: u8,
    name1: [6]u16 = [_]u16{0} ** 6,
    first_cluster: u16 = 0,
    name2: [2]u16 = [_]u16{0} ** 2,

    fn setupName(
        self: *@This(),
        part: []const u8,
    ) void {
        for (part, 0..) |ch, i| {
            if (i < 5) {
                self.name0[i] = ch;
            } else if (i < 11) {
                self.name1[i - 5] = ch;
            } else {
                self.name2[i - 11] = ch;
            }
        }
        for (part.len..13) |i| {
            const ch: u16 = if (i == part.len) 0 else 0xffff;
            if (i < 5) {
                self.name0[i] = ch;
            } else if (i < 11) {
                self.name1[i - 5] = ch;
            } else {
                self.name2[i - 11] = ch;
            }
        }
    }

    fn dosNameChecksum(name: [8]u8, ext: [3]u8) u8 {
        const full = name ++ ext;
        var sum: u8 = 0;
        for (full) |ch| {
            sum = ((sum & 1) << 7) +% (sum >> 1) +% ch;
        }
        return sum;
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

const Time = packed struct {
    double_seconds: u5 = 0,
    minutes: u6 = 0,
    hours: u5 = 0,
};

const Date = packed struct {
    day: u5 = 1,
    month: u4 = 1,
    year_since_1980: u7 = 0,
};
