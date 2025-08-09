const std = @import("std");
const abi = @import("abi");

const arch = @import("arch.zig");
const lazy = @import("lazy.zig");

//

const outb = arch.x86_64.outb;
const inb = arch.x86_64.inb;
const hcf = arch.hcf;

//

var uart_lazy_init = lazy.Lazy(void).new();
pub fn print(comptime fmt: []const u8, args: anytype) void {
    _ = uart_lazy_init.getOrInit(lazy.fnPtrAsInit(void, init)) orelse {
        return;
    };
    if (!initialized.load(.acquire)) return;

    const UartWriter = struct {
        pub const Error = error{};
        pub const Self = @This();

        pub fn writeAll(_: *const Self, bytes: []const u8) !void {
            writeBytes(bytes);
        }

        pub fn writeBytesNTimes(self: *const Self, bytes: []const u8, n: usize) !void {
            for (0..n) |_| {
                try self.writeAll(bytes);
            }
        }
    };

    std.fmt.format(UartWriter{}, fmt, args) catch {};
}

const PORT: u16 = 0x3f8;
var initialized: std.atomic.Value(bool) = .init(false);

fn init() void {
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
