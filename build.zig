const std = @import("std");

//

const Opts = struct {
    native_target: std.Build.ResolvedTarget,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    display: bool,
    debug: u2,
    use_ovmf: bool,
    ovmf_fd: []const u8,
    gdb: enum { false, true, wait },
    testing: bool,
    cpus: u8,
    kvm: bool,
    sound: bool,
};

fn options(b: *std.Build, target: std.Build.ResolvedTarget) Opts {
    return .{
        .native_target = b.standardTargetOptions(.{}),
        .target = target,
        .optimize = b.standardOptimizeOption(.{}),

        // QEMU gui true/false
        .display = b.option(bool, "display", "QEMU gui true/false") orelse
            true,

        // QEMU debug level
        .debug = b.option(u2, "debug", "QEMU debug level") orelse
            1,

        // use OVMF UEFI to boot in QEMU (OVMF is slower, but has more features)
        .use_ovmf = b.option(bool, "uefi", "use OVMF UEFI to boot in QEMU (OVMF is slower, but has more features) (default: false)") orelse
            false,

        // OVMF.fd path
        .ovmf_fd = b.option([]const u8, "ovmf", "OVMF.fd path") orelse b: {
            if (std.posix.getenvZ("OVMF_FD")) |override| {
                break :b override[0..];
            } else {
                break :b "/usr/share/ovmf/x64/OVMF.fd";
            }
        },

        // use GDB
        .gdb = b.option(@TypeOf(@as(Opts, undefined).gdb), "gdb", "use GDB") orelse
            .false,

        // include test runner
        .testing = b.option(bool, "test", "include test runner") orelse
            true,

        // number of SMP processors, 0 means QEMU default
        .cpus = b.option(u8, "cpus", "number of SMP processors") orelse
            4,

        // QEMU KVM hardware acceleration
        .kvm = b.option(bool, "kvm", "QEMU KVM hardware acceleration") orelse
            true,

        // QEMU virtio-sound device
        .sound = b.option(bool, "sound", "Add virtio-sound device to QEMU") orelse
            true,
    };
}

//

pub fn build(b: *std.Build) !void {
    const Target = std.Target;
    const Feature = Target.x86.Feature;

    // kernel mode code cannot use fpu so use software impl instead
    var enabled_features = Target.Cpu.Feature.Set.empty;
    enabled_features.addFeature(@intFromEnum(Feature.soft_float));

    // kernel mode code cannot use these features (except maybe after they are enabled)
    var disabled_features = Target.Cpu.Feature.Set.empty;
    disabled_features.addFeature(@intFromEnum(Feature.mmx));
    disabled_features.addFeature(@intFromEnum(Feature.sse));
    disabled_features.addFeature(@intFromEnum(Feature.sse2));
    disabled_features.addFeature(@intFromEnum(Feature.avx));
    disabled_features.addFeature(@intFromEnum(Feature.avx2));
    disabled_features.addFeature(@intFromEnum(Feature.mmx));

    const opts = options(b, b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = enabled_features,
        .cpu_features_sub = disabled_features,
    }));

    const abi = createAbi(b, &opts);
    const root_bin = createRootBin(b, &opts, abi);
    const kernel_elf = try createKernelElf(b, &opts, abi);
    const initfs_tar_zst = createInitfsTarZst(b, &opts, abi);
    const os_iso = createIso(b, &opts, kernel_elf, initfs_tar_zst, root_bin);

    runQemu(b, &opts, os_iso);
}

fn runQemu(b: *std.Build, opts: *const Opts, os_iso: std.Build.LazyPath) void {
    // run the os in qemu
    const qemu_step = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-machine",
        "q35",
        "-cpu",
        "qemu64,+rdrand,+rdseed,+rdtscp,+rdpid",
        "-m",
        "1g", // 3m is the absolute minimum right now
        // "-M",
        // "smm=off,accel=kvm",
        "-no-reboot",
        "-serial",
        "stdio",
        "-rtc",
        "base=localtime",
        "-vga",
        "std",
        "-usb",
        "-device",
        "usb-tablet",
        "-drive",
    });

    qemu_step.addPrefixedFileArg("format=raw,file=", os_iso);

    if (opts.sound) {
        qemu_step.addArgs(&.{ "-device", "virtio-sound" });
    }

    if (opts.kvm) {
        qemu_step.addArgs(&.{
            "-enable-kvm",
            "-M",
            "smm=off,accel=kvm",
        });
    }

    if (opts.cpus >= 2) {
        qemu_step.addArgs(&.{
            "-smp",
            b.fmt("{}", .{opts.cpus}),
        });
    }

    if (opts.display) {
        qemu_step.addArgs(&.{
            "-display",
            "gtk,show-cursor=off",
        });
    } else {
        qemu_step.addArgs(&.{
            "-display",
            "none",
        });
    }

    switch (opts.debug) {
        0 => {},
        1 => qemu_step.addArgs(&.{ "-d", "guest_errors" }),
        2 => qemu_step.addArgs(&.{ "-d", "cpu_reset,guest_errors" }),
        3 => qemu_step.addArgs(&.{ "-d", "int,cpu_reset,guest_errors" }),
    }

    if (opts.use_ovmf) {
        const ovmf_fd = opts.ovmf_fd;
        qemu_step.addArgs(&.{ "-bios", ovmf_fd });
    }

    switch (opts.gdb) {
        .false => {},
        .true => {
            qemu_step.addArgs(&.{"-s"});
        },
        .wait => {
            qemu_step.addArgs(&.{ "-s", "-S" });
        },
    }

    std.debug.print("qemu cmd: '", .{});
    std.debug.print("{s}", .{qemu_step.argv.items[0].bytes});
    for (qemu_step.argv.items) |arg| switch (arg) {
        .bytes => |s| std.debug.print(" {s}", .{s}),
        else => std.debug.print(" <..>", .{}),
    };
    std.debug.print("'\n", .{});

    const run_step = b.step("run", "Run in QEMU");
    run_step.dependOn(&qemu_step.step);
    run_step.dependOn(b.getInstallStep());
}

fn createIso(
    b: *std.Build,
    opts: *const Opts,
    kernel_elf: std.Build.LazyPath,
    initfs_tar_zst: std.Build.LazyPath,
    root_bin: std.Build.LazyPath,
) std.Build.LazyPath {

    // clone & configure limine (WARNING: this runs a Makefile from a dependency at compile time)
    const limine_bootloader_pkg = b.dependency("limine_bootloader", .{});
    // const limine_step = b.addSystemCommand(&.{
    //     "make", "-C",
    // });
    // limine_step.addDirectoryArg(limine_bootloader_pkg.path("."));
    // // limine_step.addPrefixedFileArg("_IGNORED=", limine_bootloader_pkg.path(".").path(b, "limine.c"));
    // limine_step.has_side_effects = false;

    // tool that generates the ISO file with everything
    const wrapper = b.addExecutable(.{
        .name = "xorriso_limine_wrapper",
        .root_source_file = b.path("src/tools/xorriso_limine_wrapper.zig"),
        .target = b.graph.host,
    });

    // create virtual iso root
    const wf = b.addNamedWriteFiles("create virtual iso root");
    _ = wf.addCopyFile(kernel_elf, "boot/kernel");
    _ = wf.addCopyFile(initfs_tar_zst, "boot/initfs.tar.zst");
    _ = wf.addCopyFile(root_bin, "boot/root.bin");
    _ = wf.addCopyFile(b.path("cfg/limine.conf"), "boot/limine/limine.conf");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-bios.sys"), "boot/limine/limine-bios.sys");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-bios-cd.bin"), "boot/limine/limine-bios-cd.bin");
    if (opts.use_ovmf) {
        _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-uefi-cd.bin"), "boot/limine/limine-uefi-cd.bin");
        _ = wf.addCopyFile(limine_bootloader_pkg.path("BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
        _ = wf.addCopyFile(limine_bootloader_pkg.path("BOOTIA32.EFI"), "EFI/BOOT/BOOTIA32.EFI");
    }

    // create the ISO file (WARNING: this runs a binary from a dependency (limine_bootloader) at compile time)
    const wrapper_run = b.addRunArtifact(wrapper);
    wrapper_run.addDirectoryArg(limine_bootloader_pkg.path("."));
    wrapper_run.addDirectoryArg(wf.getDirectory());
    const os_iso = wrapper_run.addOutputFileArg("os.iso");
    wrapper_run.addArg(if (opts.use_ovmf) "y" else "n");
    // wrapper_run.step.dependOn(&limine_step.step);

    const install_iso = b.addInstallFile(os_iso, "os.iso");
    b.getInstallStep().dependOn(&install_iso.step);

    return os_iso;
}

fn createInitfsTarZst(
    b: *std.Build,
    opts: *const Opts,
    abi: *std.Build.Module,
) std.Build.LazyPath {
    const initfs_processes = .{
        "coreutils",
        "hpet",
        "init",
        "pci",
        "pm",
        "ps2",
        "term",
        "tty",
        "vfs",
        "wm",
    };

    // create virtual initfs.tar.zst root
    const initfs = b.addNamedWriteFiles("create virtual initfs root");

    inline for (initfs_processes) |name| {
        const source = std.fmt.comptimePrint("src/userspace/{s}/main.zig", .{name});
        const path = std.fmt.comptimePrint("sbin/{s}", .{name});

        const proc = b.addModule(name, .{
            .root_source_file = b.path(source),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        proc.addImport("abi", abi);

        const wf = b.addWriteFiles();
        const userspace_entry_wrapper_zig = wf.add("userspace_entry_wrapper.zig",
            \\pub usingnamespace @import("proc");
            \\comptime { @import("abi").rt.installRuntime(); }
            \\pub const std_options = @import("abi").std_options;
            \\pub const panic = @import("abi").panic;
        );

        const userspace_entry_wrapper = b.addExecutable(.{
            .name = name,
            .root_source_file = userspace_entry_wrapper_zig,
            .target = opts.target,
            // FIXME: manifest/imports/exports rely on symtab
            .optimize = opts.optimize,
            .pic = true,
            .strip = false,
        });
        userspace_entry_wrapper.root_module.addImport("abi", abi);
        userspace_entry_wrapper.root_module.addImport("proc", proc);

        b.installArtifact(userspace_entry_wrapper);

        _ = initfs.addCopyFile(userspace_entry_wrapper.getEmittedBin(), path);
    }

    const initfs_tar_zst = b.addSystemCommand(&.{
        "tar",
        "c",
        "-Izstd -19 -T1",
        "-f",
    });
    const initfs_tar_zst_file = initfs_tar_zst.addOutputFileArg("initfs.tar.zst");
    initfs_tar_zst.addArg("-C");
    initfs_tar_zst.addDirectoryArg(initfs.getDirectory());
    initfs_tar_zst.addArg(".");

    const install_initfs_tar_zst = b.addInstallFile(initfs_tar_zst_file, "initfs.tar.zst");
    b.getInstallStep().dependOn(&install_initfs_tar_zst.step);

    return initfs_tar_zst_file;
}

fn appendSources(b: *std.Build, writer: anytype, sub_path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(sub_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const file = try entry.dir.openFile(entry.basename, .{});
        defer file.close();

        try std.fmt.format(writer,
            \\    "{s}",
            \\
        , .{entry.path});
    }
}

fn generateSourcesZig(
    b: *std.Build,
    opts: *const Opts,
) !*std.Build.Module {
    // collect all kernel source files for the stack tracer

    var sources_zig_contents = std.ArrayList(u8).init(b.allocator);
    errdefer sources_zig_contents.deinit();

    const sources_zig_writer = sources_zig_contents.writer();
    try sources_zig_writer.writeAll(
        \\pub const sources: []const []const u8 = &.{
        \\
    );
    try appendSources(b, sources_zig_writer, "src/kernel");
    try sources_zig_writer.writeAll(
        \\};
        \\
    );

    const kernel_source = b.addWriteFiles();
    const sources_zig = kernel_source.add(
        "sources.zig",
        sources_zig_contents.items,
    );

    return b.addModule("sources", .{
        .target = opts.target,
        .optimize = opts.optimize,
        .root_source_file = sources_zig,
    });
}

fn createKernelElf(
    b: *std.Build,
    opts: *const Opts,
    abi: *std.Build.Module,
) !std.Build.LazyPath {
    const git_rev_run = b.addSystemCommand(&.{ "git", "rev-parse", "HEAD" });
    const git_rev = git_rev_run.captureStdOut();
    const git_rev_mod = b.createModule(.{
        .root_source_file = git_rev,
    });

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(git_rev, .prefix, "git-rev").step);

    const kernel_module = b.addModule("kernel", .{
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .code_model = .kernel,
    });
    kernel_module.addImport("limine", b.dependency("limine", .{}).module("limine"));
    kernel_module.addImport("abi", abi);
    kernel_module.addImport("git-rev", git_rev_mod);
    kernel_module.addImport("sources", try generateSourcesZig(b, opts));

    if (opts.testing) {
        const testkernel_elf_step = b.addTest(.{
            .name = "kernel",
            // .target = target,
            // .optimize = optimize,
            // .test_runner = .{ .path = b.path("src/kernel/main.zig"), .mode = .simple },
            // .root_source_file = b.path("src/kernel/test.zig"),
            .test_runner = .{ .path = b.path("src/kernel/test.zig"), .mode = .simple },
            .root_module = kernel_module,
        });

        testkernel_elf_step.setLinkerScript(b.path("src/kernel/link/x86_64.ld"));
        // testkernel_elf_step.want_lto = false;
        testkernel_elf_step.pie = false;
        testkernel_elf_step.root_module.addImport("kernel", kernel_module);

        b.installArtifact(testkernel_elf_step);

        return testkernel_elf_step.getEmittedBin();
    } else {
        const kernel_elf_step = b.addExecutable(.{
            .name = "kernel",
            .root_module = kernel_module,
        });

        kernel_elf_step.setLinkerScript(b.path("src/kernel/link/x86_64.ld"));
        // kernel_elf_step.want_lto = false;
        kernel_elf_step.pie = false;

        b.installArtifact(kernel_elf_step);

        return kernel_elf_step.getEmittedBin();
    }
}

// create the embedded root.bin
fn createRootBin(
    b: *std.Build,
    opts: *const Opts,
    abi: *std.Build.Module,
) std.Build.LazyPath {
    const root_elf_step = b.addExecutable(.{
        .name = "root",
        .root_source_file = b.path("src/userspace/root/main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    root_elf_step.root_module.addImport("abi", abi);
    root_elf_step.setLinkerScript(b.path("src/userspace/root/link.ld"));

    const root_bin_step = b.addObjCopy(root_elf_step.getEmittedBin(), .{
        .format = .bin,
    });
    root_bin_step.step.dependOn(&root_elf_step.step);

    b.installArtifact(root_elf_step);

    const install_root_bin = b.addInstallFile(root_bin_step.getOutput(), "root.bin");
    b.getInstallStep().dependOn(&install_root_bin.step);

    return root_bin_step.getOutput();
}

// create the shared ABI library
fn createAbi(b: *std.Build, opts: *const Opts) *std.Build.Module {
    const syscall_generator_tool = b.addExecutable(.{
        .name = "generate_syscall_wrapper",
        .root_source_file = b.path("src/tools/generate_syscall_wrapper.zig"),
        .target = b.graph.host,
    });

    const syscall_generator_tool_run = b.addRunArtifact(syscall_generator_tool);
    const syscall_zig = syscall_generator_tool_run.addOutputFileArg("syscall.zig");
    syscall_generator_tool_run.has_side_effects = false;

    const font = createFont(b);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/abi/lib.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    mod.addAnonymousImport("syscall", .{ .root_source_file = syscall_zig });
    mod.addImport("font", font);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/abi/lib.zig"),
        .target = b.graph.host,
        .optimize = opts.optimize,
    });
    test_mod.addAnonymousImport("syscall", .{ .root_source_file = syscall_zig });
    test_mod.addImport("font", font);

    const tests = b.addTest(.{
        .name = "abi-unit-test",
        .root_module = test_mod,
    });
    const tests_step = b.step("test", "run unit tests");
    const run_tests_step = b.addRunArtifact(tests);
    tests_step.dependOn(&run_tests_step.step);

    return mod;
}

// convert the font.bmp into a more usable format
fn createFont(b: *std.Build) *std.Build.Module {
    const font_tool = b.addExecutable(.{
        .name = "generate_font",
        .root_source_file = b.path("src/tools/generate_font.zig"),
        .target = b.graph.host,
    });

    const font_tool_run = b.addRunArtifact(font_tool);
    font_tool_run.addFileArg(b.path("asset/font.bmp"));
    const font_zig = font_tool_run.addOutputFileArg("font.zig");
    font_tool_run.has_side_effects = false;

    return b.createModule(.{
        .root_source_file = font_zig,
    });
}
