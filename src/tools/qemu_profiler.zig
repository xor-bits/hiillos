const std = @import("std");

//

pub var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() !void {
    const args = try std.process.argsAlloc(gpa.allocator()); // leak the args so that the threads can use it
    if (args.len != 3)
        return error.@"usage: qemu_profiler <os-iso> <kernel-elf>";

    var qemu = std.process.Child.init(&.{
        "qemu-system-x86_64",
        "-machine",
        "q35",
        "-cpu",
        "qemu64,+rdrand,+rdseed,+rdtscp,+rdpid",
        "-m",
        "1g", // 3m is the absolute minimum right now
        "-enable-kvm",
        "-M",
        "smm=off,accel=kvm",
        "-no-reboot",
        "-monitor",
        "stdio",
        "-serial",
        "none",
        "-rtc",
        "base=localtime",
        "-vga",
        "std",
        "-usb",
        "-device",
        "usb-tablet",
        "-display",
        "none",
        "-drive",
        try std.fmt.allocPrint(
            gpa.allocator(),
            "format=raw,file={s}",
            .{args[1]},
        ), // leak is fine here
    }, gpa.allocator());

    qemu.stdin_behavior = .Pipe;
    qemu.stdout_behavior = .Pipe;
    qemu.stderr_behavior = .Inherit;

    try qemu.spawn();

    const stdin_job = try std.Thread.spawn(
        .{},
        stdinJob,
        .{qemu.stdin.?},
    );
    stdin_job.detach();

    const stdout_job = try std.Thread.spawn(
        .{},
        stdoutJob,
        .{ qemu.stdout.?, args },
    );
    stdout_job.detach();

    const qemu_code = try qemu.wait();
    if ((qemu_code == .Exited and qemu_code.Exited == 0) or qemu_code != .Exited) {
        return error.@"qemu error";
    }
}

fn stdinJob(stdin: std.fs.File) !void {
    std.Thread.sleep(1_000_000_000); // delay 1s
    while (true) {
        stdin.writeAll("info registers\n") catch return;
        std.Thread.sleep(100_000); // every 0.1ms
    }
}

fn stdoutJob(stdout: std.fs.File, args: []const [:0]const u8) !void {
    var address_map: std.AutoArrayHashMap(usize, usize) = .init(gpa.allocator());
    defer address_map.deinit();

    var timer = try std.time.Timer.start();

    var buf: [0x1000]u8 = undefined;
    while (true) {
        const line = stdout.reader().readUntilDelimiter(&buf, '\n') catch return;
        // std.log.info("readline: '{s}'", .{line});
        const rip_eq = std.mem.indexOf(u8, line, "RIP=") orelse continue;
        const rip_val = line[rip_eq + 4 ..];
        if (rip_val.len < 16) continue;

        const rip = try std.fmt.parseInt(usize, rip_val[0..16], 16);

        // skip user-space, this is a kernel profiler
        if (rip <= 0x8000_0000_0000) continue;

        const slot = try address_map.getOrPut(rip);
        if (!slot.found_existing) slot.value_ptr.* = 0;
        slot.value_ptr.* += 1;

        if (timer.read() >= 5_000_000_000) {
            timer.reset();
            // print the 50 (approximately) hottest instructions every 5 seconds
            try printHotSpots(&address_map, args);
        }
    }
}

fn printHotSpots(
    address_map: *std.AutoArrayHashMap(usize, usize),
    args: []const [:0]const u8,
) !void {
    const entries = &address_map.unmanaged.entries;
    const T = @TypeOf(entries);

    const unknown = "<unknown>";

    address_map.sort((struct {
        entries: T,
        pub fn lessThan(self: @This(), a_index: usize, b_index: usize) bool {
            return self.entries.get(a_index).value >= self.entries.get(b_index).value;
        }
    }){ .entries = entries });

    std.debug.print("\n50 most hit addresses:\n", .{});
    const count = @min(entries.len, 50);
    var source_lines: [50]std.ArrayListUnmanaged(u8) = [1]std.ArrayListUnmanaged(u8){.{}} ** 50;
    var addr2line_processes: [50]?std.process.Child = undefined;
    for (0..count) |i| {
        const entry = entries.get(i);
        var rip_buf: [100]u8 = undefined;
        var rip_buf_writer = std.io.fixedBufferStream(&rip_buf);
        try std.fmt.format(
            rip_buf_writer.writer(),
            "0x{x}",
            .{entry.key},
        );
        const rip_str = rip_buf_writer.getWritten();

        var addr2line = std.process.Child.init(&.{
            "addr2line",
            "-e",
            args[2],
            rip_str,
        }, gpa.allocator());
        addr2line.stdin_behavior = .Close;
        addr2line.stdout_behavior = .Pipe;
        addr2line.stderr_behavior = .Pipe;
        addr2line.spawn() catch {
            addr2line_processes[i] = null;
            try source_lines[i].appendSlice(gpa.allocator(), unknown);
            continue;
        };
        addr2line_processes[i] = addr2line;
    }
    for (0..count) |i| {
        const addr2line = &(addr2line_processes[i] orelse continue);
        addr2line.collectOutput(
            gpa.allocator(),
            &source_lines[i],
            &source_lines[i],
            std.math.maxInt(usize),
        ) catch {
            try source_lines[i].appendSlice(gpa.allocator(), unknown);
            continue;
        };
    }
    for (0..count) |i| {
        const entry = entries.get(i);
        const source_line = source_lines[i].items;
        std.debug.print("  {} hits @ 0x{x} {s}\n", .{
            entry.value,
            entry.key,
            std.mem.trim(u8, source_line, "\n"),
        });
    }
}
