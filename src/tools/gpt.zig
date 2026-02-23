const std = @import("std");

pub const Partition = struct {
    part_ty: enum {
        fat32,
    },
    lba_first: u64,
    lba_last: u64,
    // attribs: packed struct {
    //     _: u64 = 0,
    // } = .{},
    name: []const u8,
};

pub fn writePartitionTable(
    writer: *std.fs.File.Writer,
    partitions: []const Partition,
    sector_size: u64,
) !void {
    std.debug.assert(sector_size >= 512);
    std.debug.assert(@popCount(sector_size) == 1);

    var info: Info = .{
        .sector_size = sector_size,
        .primary = .{
            .header = 1,
            .entries = .{ .first = 2, .last = 33 },
        },
        .partitions = .{ .first = 34, .last = 0 },
    };

    for (partitions) |part| {
        std.debug.assert(part.lba_first <= part.lba_last);
        std.debug.assert(part.lba_first >= 34);
        // info.partitions.first = @min(info.partitions.first, part.lba_first);
        info.partitions.last = @max(info.partitions.last, part.lba_last);
    }
    if (partitions.len == 0) {
        // info.partitions.first = info.primary.entries.last + 1;
        info.partitions.last = info.partitions.first;
        // return error.NoPartitions;
    }

    std.debug.assert(info.partitions.first <= info.partitions.last);
    std.debug.assert(info.primary.entries.last < info.partitions.first);

    info.secondary.entries.first = info.partitions.last + 1;
    info.secondary.entries.last = info.secondary.entries.first + 31;
    info.secondary.header = info.secondary.entries.last + 1;

    try writer.interface.flush();
    try writer.seekTo(0);
    try writeProtectiveMasterBootRecord(&writer.interface, info);

    try writer.interface.flush();
    try writer.seekTo(info.primary.entries.first * info.sector_size);
    const entries_crc32 = try writeEntries(
        &writer.interface,
        partitions,
    );

    try writer.interface.flush();
    try writer.seekTo(info.primary.header * info.sector_size);
    try writePartitionTableHeader(
        &writer.interface,
        partitions,
        info,
        entries_crc32,
        .primary,
    );

    try writer.interface.flush();
    try writer.seekTo(info.secondary.entries.first * info.sector_size);
    _ = try writeEntries(
        &writer.interface,
        partitions,
    );

    try writer.interface.flush();
    try writer.seekTo(info.secondary.header * info.sector_size);
    try writePartitionTableHeader(
        &writer.interface,
        partitions,
        info,
        entries_crc32,
        .secondary,
    );
}

const Info = struct {
    sector_size: u64,
    max_entries: u32 = 0,
    primary: GptInfo = .{},
    secondary: GptInfo = .{},
    partitions: LbaRange = .{},
};

const GptInfo = struct {
    header: u64 = 0,
    entries: LbaRange = .{},
};

const LbaRange = struct {
    first: u64 = 0,
    last: u64 = 0,
};

fn writeProtectiveMasterBootRecord(
    writer: *std.Io.Writer,
    info: Info,
) !void {
    try writer.writeStruct(ProtectiveMasterBootRecord{
        .ending_lba = @min(info.secondary.header, std.math.maxInt(u32)),
    }, .little);
    const pad = info.sector_size - @sizeOf(ProtectiveMasterBootRecord);
    _ = try writer.splatByteAll('\x00', pad);
}

fn writePartitionTableHeader(
    writer: *std.Io.Writer,
    partitions: []const Partition,
    info: Info,
    entries_crc32: u32,
    which: enum { primary, secondary },
) !void {
    _ = partitions;
    var header: PartitionTableHeader = .{
        .lba_current_header = info.primary.header,
        .lba_backup_header = info.secondary.header,
        .lba_start_partitions = info.partitions.first,
        .lba_end_partitions = info.partitions.last,
        .disk_guid = Guid.disk_default,
        .lba_start_entries = info.primary.entries.first,
        .num_entries = 128, // @intCast(partitions.len),
        .entries_crc32 = entries_crc32,
    };
    if (which == .secondary) {
        header.lba_start_entries = info.secondary.entries.first;
        std.mem.swap(
            u64,
            &header.lba_current_header,
            &header.lba_backup_header,
        );
    }

    var crc32: Crc32Writer = .{ .limit = header.header_size };
    try crc32.interface.writeStruct(header, .little);
    header.header_crc32 = crc32.finish();

    try writer.writeStruct(header, .little);
    const pad = info.sector_size - @sizeOf(PartitionTableHeader);
    _ = try writer.splatByteAll('\x00', pad);
}

fn writeEntries(
    writer: *std.Io.Writer,
    partitions: []const Partition,
) !u32 {
    comptime std.debug.assert(@sizeOf(Entry) == 128);

    var crc32: Crc32Writer = .{};
    for (partitions, 0..) |part, i| {
        var name: [36]u16 = [_]u16{0} ** 36;
        for (part.name[0..@min(part.name.len, 36)], 0..) |b, j| {
            name[j] = b;
        }

        const entry: Entry = .{
            .type_guid = switch (part.part_ty) {
                .fat32 => comptime Guid.parse("C12A7328-F81F-11D2-BA4B-00A0C93EC93B") catch unreachable,
            },
            .part_guid = Guid.part_default.add(i),
            .lba_first = part.lba_first,
            .lba_last = part.lba_last,
            // .attribs = part.attribs,
            .name = name,
        };
        try crc32.interface.writeStruct(entry, .little);
        try writer.writeStruct(entry, .little);
    }
    for (0..128 - partitions.len) |_| {
        const entry: Entry = .{
            .type_guid = Guid.nil,
            .part_guid = Guid.nil,
            .lba_first = 0,
            .lba_last = 0,
            .name = [_]u16{0} ** 36,
        };
        try crc32.interface.writeStruct(entry, .little);
        try writer.writeStruct(entry, .little);
    }
    return crc32.finish();
}

const Crc32Writer = struct {
    crc32: std.hash.Crc32 = .init(),
    limit: ?usize = null,
    interface: std.Io.Writer = .{
        .vtable = &vtable,
        .buffer = &.{},
    },

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
    };

    fn drain(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *@This() = @fieldParentPtr("interface", w);

        const pattern = data[data.len - 1];
        var n: usize = 0;

        for (data[0 .. data.len - 1]) |bytes| {
            self.update(bytes);
            n += bytes.len;
        }
        for (0..splat) |_| {
            self.update(pattern);
        }
        return n + splat * pattern.len;
    }

    fn update(self: *@This(), bytes: []const u8) void {
        const limit = self.limit orelse {
            self.crc32.update(bytes);
            return;
        };
        const n = @min(bytes.len, limit);
        self.crc32.update(bytes[0..n]);
        self.limit = limit - n;
    }

    fn finish(self: @This()) u32 {
        return self.crc32.final();
    }
};

const ProtectiveMasterBootRecord = packed struct {
    _0: u3568 = 0,
    boot_indicator: u8 = 0, // not legacy bootable
    starting_chs: u24 = 0x200, // GPT partition header in CHS
    os_type: u8 = 0xee, // GPT protective
    ending_chs: u24 = 0xffffff,
    starting_lba: u32 = 1, // GPT partition header in LBA
    ending_lba: u32,
    _1: u384 = 0,
    boot_sign_0: u8 = 0x55,
    boot_sign_1: u8 = 0xaa,
};

const PartitionTableHeader = extern struct {
    signature: [8]u8 = "EFI PART".*,
    header_rev: u32 = 0x10000,
    header_size: u32 = 92,
    header_crc32: u32 = 0,
    _0: u32 = 0,
    lba_current_header: u64,
    lba_backup_header: u64,
    lba_start_partitions: u64,
    lba_end_partitions: u64,
    disk_guid: Guid,
    lba_start_entries: u64,
    num_entries: u32 = 128,
    entry_size: u32 = 128,
    entries_crc32: u32 = 0,
    _1: u32 = 0,
};

const Entry = extern struct {
    type_guid: Guid,
    part_guid: Guid,
    lba_first: u64,
    lba_last: u64,
    attribs: packed struct {
        _: u64 = 0,
    } = .{},
    name: [36]u16,
};

const Guid = extern struct {
    p1: u32 = 0,
    p2: u16 = 0,
    p3: u16 = 0,
    p4: [8]u8 = [_]u8{0} ** 8,

    // chosen by fair dice roll.
    // guaranteed to be random.
    const disk_default: @This() = Guid.parse("81e4949b-7093-4aa9-85fb-a4abcbfca62d") catch unreachable;
    const part_default: @This() = Guid.parse("456db5a4-3434-4fd8-a68b-68f4e30ad1e4") catch unreachable;
    const nil: @This() = .{};

    fn add(self: @This(), n: u128) @This() {
        return @bitCast(@as(u128, @bitCast(self)) +% n);
    }

    fn parse(s: []const u8) !@This() {
        if (s.len != 36) return error.InvalidLength;
        const p1 = s[0..8];
        const p2 = s[9..13];
        const p3 = s[14..18];
        const p41 = s[19..23];
        const p42 = s[24..36];
        var p4: [8]u8 = undefined;
        inline for (0..2) |i| {
            p4[i] = try std.fmt.parseInt(u8, p41[i * 2 ..][0..2], 16);
        }
        inline for (0..6) |i| {
            p4[i + 2] = try std.fmt.parseInt(u8, p42[i * 2 ..][0..2], 16);
        }
        return .{
            .p1 = try std.fmt.parseInt(u32, p1, 16),
            .p2 = try std.fmt.parseInt(u16, p2, 16),
            .p3 = try std.fmt.parseInt(u16, p3, 16),
            .p4 = p4,
        };
    }
};
