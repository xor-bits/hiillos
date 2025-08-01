const std = @import("std");

const util = @import("util.zig");

//

pub fn parser(reader: anytype) Parser(@TypeOf(reader)) {
    return .{ .inner = reader };
}

pub fn Parser(comptime T: type) type {
    return struct {
        inner: T,

        pub const Error = T.Error;

        pub fn next(self: *@This()) Error!?Control {
            const State = enum {
                restart,
                start,
                /// \x1b
                esc,
                /// \x1b[
                csi,
                /// \x1b[..m
                cmd_sgr,
                /// \x1b[..A/B/C/D/s/u
                cmd_cursor,
            };

            var numbers: NumArrayBuilder = undefined;
            var byte: u8 = undefined;

            state: switch (State.restart) {
                .restart => {
                    // discard the whole sequence and restart
                    byte = try self.pop() orelse return null;
                    numbers = .{};
                    continue :state .start;
                },
                .start => {
                    switch (byte) {
                        0x1b => {
                            byte = try self.pop() orelse return null;
                            continue :state .esc;
                        },
                        else => return .{ .ch = byte },
                    }
                },
                .esc => {
                    if (byte == '[') {
                        byte = try self.pop() orelse return null;
                        continue :state .csi;
                    }

                    continue :state .restart;
                },
                .csi => {
                    if (std.ascii.isDigit(byte)) {
                        numbers.pushDigit(byte - '0');
                        byte = try self.pop() orelse return null;
                        continue :state .csi;
                    }

                    numbers.push();
                    switch (byte) {
                        ';' => {
                            byte = try self.pop() orelse return null;
                            continue :state .csi;
                        },
                        'm' => continue :state .cmd_sgr,
                        'A' => continue :state .cmd_cursor,
                        'B' => continue :state .cmd_cursor,
                        'C' => continue :state .cmd_cursor,
                        'D' => continue :state .cmd_cursor,
                        's' => continue :state .cmd_cursor,
                        'u' => continue :state .cmd_cursor,
                        else => continue :state .restart,
                    }
                },
                .cmd_sgr => {
                    const args = numbers.all();
                    std.debug.assert(args.len != 0);

                    // https://en.wikipedia.org/wiki/ANSI_escape_code#Select_Graphic_Rendition_parameters
                    const sgr = args[0] orelse 0;

                    switch (sgr) {
                        0 => return .{ .reset = {} },
                        38 => {
                            if (args.len == 3 and args[1] == '5') {
                                // 5;n
                                // TODO: indexed colours
                                continue :state .restart;
                            } else if (args.len == 5 and args[1] == '2') {
                                // 2;r;g;b
                                return .{ .fg_colour = util.Pixel{
                                    .red = @truncate(args[2] orelse 0),
                                    .green = @truncate(args[3] orelse 0),
                                    .blue = @truncate(args[4] orelse 0),
                                } };
                            } else {
                                continue :state .restart;
                            }
                        },
                        48 => {
                            if (args.len == 3 and args[1] == '5') {
                                // 5;n
                                // TODO: indexed colours
                                continue :state .restart;
                            } else if (args.len == 5 and args[1] == '2') {
                                // 2;r;g;b
                                return .{ .bg_colour = util.Pixel{
                                    .red = @truncate(args[2] orelse 0),
                                    .green = @truncate(args[3] orelse 0),
                                    .blue = @truncate(args[4] orelse 0),
                                } };
                            } else {
                                continue :state .restart;
                            }
                        },

                        // TODO: implement more of these
                        else => continue :state .restart,
                    }
                },
                .cmd_cursor => {
                    const args = numbers.all();
                    std.debug.assert(args.len != 0);

                    const count = args[0] orelse 1;

                    switch (byte) {
                        'A' => return .{ .cursor_up = count },
                        'B' => return .{ .cursor_down = count },
                        'C' => return .{ .cursor_right = count },
                        'D' => return .{ .cursor_left = count },
                        's' => return .cursor_push,
                        'u' => return .cursor_pop,
                        else => continue :state .restart,
                    }
                },
            }
        }

        fn pop(self: *@This()) Error!?u8 {
            var ch: [1]u8 = undefined;
            const n: usize = try self.inner.read(&ch);
            if (n == 0) return null;
            return ch[0];
        }
    };
}

const NumArrayBuilder = struct {
    n: usize = 0,
    n_len: u8 = 0,

    numbers: [8]?usize = [1]?usize{null} ** 8,
    numbers_len: u8 = 0,

    fn pushDigit(self: *@This(), d: u8) void {
        self.n *%= 10;
        self.n +%= d;
        self.n_len +|= 1;
    }

    fn push(self: *@This()) void {
        if (self.numbers_len == self.numbers.len) {
            // discard earlier numbers, data loss
            std.mem.rotate(?usize, &self.numbers, 1);
            self.numbers_len -= 1;
        }

        self.numbers[self.numbers_len] = if (self.n_len == 0) null else self.n;
        self.numbers_len += 1;
    }

    fn pop(self: *@This()) ?usize {
        if (self.numbers_len == 0) return null;

        const num = self.numbers[0];
        std.mem.rotate(usize, self.numbers, 1);
        self.numbers_len -= 1;
        return num;
    }

    fn all(self: *const @This()) []const ?usize {
        return self.numbers[0..self.numbers_len];
    }
};

pub fn setForeground(col: util.Pixel) Control {
    return .{ .fg_colour = col };
}

pub fn setBackground(col: util.Pixel) Control {
    return .{ .bg_colour = col };
}

pub fn cursorUp(count: usize) Control {
    return .{ .cursor_up = count };
}

pub fn cursorDown(count: usize) Control {
    return .{ .cursor_down = count };
}

pub fn cursorRight(count: usize) Control {
    return .{ .cursor_right = count };
}

pub fn cursorLeft(count: usize) Control {
    return .{ .cursor_left = count };
}

pub fn cursorPush() Control {
    return .cursor_push;
}

pub fn cursorPop() Control {
    return .cursor_pop;
}

pub const Control = union(enum) {
    /// printable ascii character
    ch: u8,

    /// \x1b[38;2;<r>;<g>;<b>m
    fg_colour: util.Pixel,
    /// \x1b[48;2;<r>;<g>;<b>m
    bg_colour: util.Pixel,
    /// \x1b[m
    reset,

    /// \x1b[<n>A
    cursor_up: usize,
    /// \x1b[<n>B
    cursor_down: usize,
    /// \x1b[<n>C
    cursor_right: usize,
    /// \x1b[<n>D
    cursor_left: usize,

    /// \x1b[s
    cursor_push,
    /// \x1b[u
    cursor_pop,

    // TODO: https://en.wikipedia.org/wiki/ANSI_escape_code#CSIsection

    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .ch => |c| try writer.writeAll(&.{c}),

            .fg_colour => |c| try std.fmt.format(
                writer,
                "\x1b[38;2;{};{};{}m",
                .{ c.red, c.green, c.blue },
            ),
            .bg_colour => |c| try std.fmt.format(
                writer,
                "\x1b[48;2;{};{};{}m",
                .{ c.red, c.green, c.blue },
            ),
            .reset => try std.fmt.format(
                writer,
                "\x1b[m",
                .{},
            ),

            .cursor_up => |c| try std.fmt.format(
                writer,
                "\x1b[{}A",
                .{c},
            ),
            .cursor_down => |c| try std.fmt.format(
                writer,
                "\x1b[{}B",
                .{c},
            ),
            .cursor_right => |c| try std.fmt.format(
                writer,
                "\x1b[{}C",
                .{c},
            ),
            .cursor_left => |c| try std.fmt.format(
                writer,
                "\x1b[{}D",
                .{c},
            ),

            .cursor_push => try std.fmt.format(
                writer,
                "\x1b[s",
                .{},
            ),
            .cursor_pop => try std.fmt.format(
                writer,
                "\x1b[u",
                .{},
            ),
        }
    }
};

test "simple cursor_right decode" {
    const input: []const u8 = "\x1b[4C";
    var input_stream = std.io.fixedBufferStream(input);
    var output = parser(input_stream.reader());

    try std.testing.expect((try output.next()).?.cursor_right == 4);
}

test "escape fuzz" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            var input_stream = std.io.fixedBufferStream(input);
            var output = parser(input_stream.reader());

            while (try output.next()) |tok| {
                _ = tok;
            }
        }
    }.testOne, .{});
}
