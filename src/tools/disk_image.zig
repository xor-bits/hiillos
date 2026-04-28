const std = @import("std");
const gpt = @import("gpt.zig");
const fat32 = @import("fat32.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 3)
        return error.@"usage: disk-image <virtual-efi-system-root> <hiillos-img>";

    const virtual_efi_system_root = args[1];
    const hiillos_img = args[2];

    // std.debug.print("root={s}\nimg={s}\n", .{ virtual_efi_system_root, hiillos_img });

    const cwd = std.Io.Dir.cwd();

    const root = try cwd.openDir(
        io,
        virtual_efi_system_root,
        .{ .iterate = true },
    );
    defer root.close(io);

    const disk_img = try cwd.createFile(
        io,
        hiillos_img,
        .{},
    );
    defer disk_img.close(io);

    var buffer: [0x10000]u8 = undefined;
    var writer = disk_img.writer(io, &buffer);

    const esp_lba_first = 2048;
    const sector_size = 512;
    try writer.seekTo(esp_lba_first * sector_size);
    const size_sectors = try fat32.writePartition(
        io,
        std.heap.smp_allocator,
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
