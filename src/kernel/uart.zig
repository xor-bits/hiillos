const std = @import("std");
const abi = @import("abi");

const arch = @import("arch.zig");

//

const outb = arch.x86_64.outb;
const inb = arch.x86_64.inb;
const hcf = arch.hcf;

//

pub fn print(comptime fmt: []const u8, args: anytype) void {
    init();
    if (!initialized.load(.acquire)) return;

    const Uart = struct {
        interface: std.io.Writer,

        const vtable: std.io.Writer.VTable = .{
            .drain = drain,
        };

        pub fn init(buffer: []u8) @This() {
            return .{ .interface = .{
                .vtable = &vtable,
                .buffer = buffer,
            } };
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
            writeBytes(w.buffer[0..w.end]);
            w.end = 0;

            const pattern = data[data.len - 1];
            var n: usize = 0;

            for (data[0 .. data.len - 1]) |bytes| {
                writeBytes(bytes);
                n += bytes.len;
            }
            for (0..splat) |_| {
                writeBytes(pattern);
            }
            return n + splat * pattern.len;
        }
    };

    var buffer: [256]u8 = undefined;
    var uart = Uart.init(&buffer);
    const writer = &uart.interface;

    writer.print(fmt, args) catch {};
    writer.flush() catch {};
}

const PORT: u16 = 0x3f8;
var initialized: std.atomic.Value(bool) = .init(false);

var once: abi.lock.Once(abi.lock.SpinMutex) = .{};
fn init() void {
    if (!once.tryRun()) {
        once.wait();
        return;
    }
    defer once.complete();

    outb(PORT + 1, 0x00);
    outb(PORT + 3, 0x80);
    outb(PORT + 0, 0x03);
    outb(PORT + 1, 0x00);
    outb(PORT + 3, 0x03);
    outb(PORT + 2, 0xc7);
    outb(PORT + 4, 0x0b);
    outb(PORT + 4, 0x1e);
    outb(PORT + 0, 0xae);

    if (inb(PORT + 0) != 0xAE)
        return; // serial port unavailable

    outb(PORT + 4, 0x0f);
    initialized.store(true, .release);
}

fn readByte() u8 {
    while (inb(PORT + 5) & 1 == 0) {}
    return inb(PORT);
}

fn writeByte(byte: u8) void {
    while (inb(PORT + 5) & 0x20 == 0) {}
    outb(PORT, byte);
}

fn writeBytes(bytes: []const u8) void {
    for (bytes) |byte| {
        writeByte(byte);
    }
}
