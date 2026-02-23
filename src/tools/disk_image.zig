const std = @import("std");
const gpt = @import("gpt.zig");
const fat32 = @import("fat32.zig");

pub var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() !void {
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len != 3)
        return error.@"usage: disk-image <virtual-efi-system-root> <hiillos-img>";

    const virtual_efi_system_root = args[1];
    const hiillos_img = args[2];

    // std.debug.print("root={s}\nimg={s}\n", .{ virtual_efi_system_root, hiillos_img });

    const cwd = std.fs.cwd();

    const root = try cwd.openDir(
        virtual_efi_system_root,
        .{ .iterate = true },
    );

    const disk_img = try cwd.createFile(
        hiillos_img,
        .{},
    );
    defer disk_img.close();

    var buffer: [0x10000]u8 = undefined;
    var writer = disk_img.writer(&buffer);

    const esp_lba_first = 2048;
    const sector_size = 512;
    try writer.seekTo(esp_lba_first * sector_size);
    const size_sectors = try fat32.writePartition(
        alloc,
        &writer,
        root,
        sector_size,
        esp_lba_first,
    );
    const esp_lba_last = esp_lba_first + size_sectors - 1;

    try gpt.writePartitionTable(
        &writer,
        &.{.{
            .part_ty = .fat32,
            .lba_first = esp_lba_first,
            .lba_last = esp_lba_last,
            .name = "EFI System",
        }},
        sector_size,
    );

    try writer.interface.flush();
}

// fn estimateSize() void {
//     var size = 256 * 1024 * 1024;
//     const min_fat32_size = 65525 * 512;
//     const min_gpt_size = 68 * 512;
//
// }

// pub fn createDiskImage(
//     b: *std.Build,
//     efi_system: anytype,
// ) std.Build.LazyPath {
//     _ = b;
//     iterDir(efi_system);
//     std.debug.panic("{any}\n", .{efi_system});
// }

// fn iterDir(dir: anytype) void {
//     inline for (@typeInfo(@TypeOf(dir)).@"struct".fields) |field| {
//         if (field.type == std.Build.LazyPath) {
//             std.debug.print("{s}\n", .{field.name});
//         } else {
//             std.debug.print("go up to {s}\n", .{field.name});
//             iterDir(@field(dir, field.name));
//             std.debug.print("go down from {s}\n", .{field.name});
//         }
//     }
// }
