const std = @import("std");

//

pub var gpa = std.heap.GeneralPurposeAllocator(.{}){};

//

pub fn main() !void {
    const args = try std.process.argsAlloc(gpa.allocator());
    if (args.len != 5)
        return error.@"usage: xorriso_limine_wrapper <limine-dir> <iso-root> <iso-file> <use-efi-y/n>";

    std.debug.print("running xorriso and limine\n", .{});

    const make_efi = std.mem.eql(u8, args[4], "y");

    var xorriso = std.process.Child.init(if (make_efi) &.{
        "xorriso",
        "-as",
        "mkisofs",
        "-b",
        "boot/limine/limine-bios-cd.bin",
        "-no-emul-boot",
        "-boot-load-size",
        "4",
        "-boot-info-table",
        "--efi-boot",
        "boot/limine/limine-uefi-cd.bin",
        "-efi-boot-part",
        "--efi-boot-image",
        "--protective-msdos-label",
        args[2],
        "-o",
        args[3],
    } else &.{
        "xorriso",
        "-as",
        "mkisofs",
        "-b",
        "boot/limine/limine-bios-cd.bin",
        "-no-emul-boot",
        "-boot-load-size",
        "4",
        "-boot-info-table",
        args[2],
        "-o",
        args[3],
    }, gpa.allocator());

    const xorriso_term = try xorriso.spawnAndWait();
    switch (xorriso_term) {
        .Exited => |code| {
            if (code != 0)
                return error.@"xorriso failed";
        },
        else => return error.@"xorriso failed",
    }

    const limine_exec = try std.fs.path.join(
        gpa.allocator(),
        &.{ args[1], "limine" },
    );

    var limine_make = std.process.Child.init(&.{
        "make",  "-C",
        args[1],
    }, gpa.allocator());

    switch (try limine_make.spawnAndWait()) {
        .Exited => |code| {
            if (code != 0)
                return error.@"make failed";
        },
        else => return error.@"make failed",
    }

    var limine = std.process.Child.init(&.{
        limine_exec,
        "bios-install",
        args[3],
    }, gpa.allocator());

    const limine_term = try limine.spawnAndWait();
    switch (limine_term) {
        .Exited => |code| {
            if (code != 0)
                return error.@"limine failed";
        },
        else => return error.@"limine failed",
    }
    // if (limine_term != std.process.Child.Term{ .Exited = 0 }) {
    //     return error.@"limine failed";
    // }
}
