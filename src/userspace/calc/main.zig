const std = @import("std");
const abi = @import("abi");
const gui = @import("gui");

const caps = abi.caps;
const log = std.log.scoped(.calc);

pub const std_options = abi.std_options;
pub const panic = abi.panic;
comptime {
    abi.rt.installRuntime();
}

const background_col = gui.Colour.hex("#000000") catch unreachable;
const button_col = gui.Colour.hex("#353535") catch unreachable;
const text_col = gui.Colour.hex("#ffffff") catch unreachable;

//

const Key = enum {
    num0,
    num1,
    num2,
    num3,
    num4,
    num5,
    num6,
    num7,
    num8,
    num9,

    div,
    mul,
    sub,
    add,
    equ,
    dot,

    c,
    back,
    open,
    close,
    sqrt,
    percent,
    one_over,

    pub fn label(self: @This()) []const u8 {
        return switch (self) {
            .num0 => "0",
            .num1 => "1",
            .num2 => "2",
            .num3 => "3",
            .num4 => "4",
            .num5 => "5",
            .num6 => "6",
            .num7 => "7",
            .num8 => "8",
            .num9 => "9",

            .div => "/",
            .mul => "*",
            .sub => "-",
            .add => "+",
            .equ => "=",
            .dot => ".",

            .c => "C",
            .back => "<-",
            .open => "(",
            .close => ")",
            .sqrt => "v/-", // TODO: unicode text rendering
            .percent => "%",
            .one_over => "1/x",
        };
    }
};

fn margin(rect: gui.Rect) gui.Rect {
    return gui.Rect{
        .pos = rect.pos +| @as(gui.Pos, @splat(5)),
        .size = rect.size -| @as(gui.Size, @splat(10)),
    };
}

fn button(calc: *Calculator, rect: gui.Rect, key: Key) !void {
    const aabb = rect.asAabb();
    aabb.draw(calc.fb.image, button_col);

    var label_area = rect;
    label_area.pos +|= @as(gui.Pos, @splat(5));

    label_area.drawLabel(
        calc.fb.image,
        key.label(),
        text_col,
        button_col,
    );

    if (calc.clicked and aabb.contains(calc.cursor)) {
        log.debug("{s} clicked", .{key.label()});

        switch (key) {
            .equ => solve(calc),
            .c => calc.text_len = 0,
            .back => calc.text_len -|= 1,
            .sqrt => {},
            .one_over => {
                prepend(calc, '(');
                prepend(calc, '/');
                prepend(calc, '1');
                append(calc, ')');
            },

            else => append(calc, key.label()[0]),
        }
    }
}

fn prepend(calc: *Calculator, ch: u8) void {
    if (calc.text_len == calc.text.len) return;
    if (calc.text_len == 1 and calc.text[0] == 'E') calc.text_len = 0;

    std.mem.rotate(u8, calc.text[0 .. calc.text_len + 1], calc.text_len);
    calc.text[0] = ch;
    calc.text_len += 1;
}

fn append(calc: *Calculator, ch: u8) void {
    if (calc.text_len == calc.text.len) return;
    if (calc.text_len == 1 and calc.text[0] == 'E') calc.text_len = 0;
    calc.text[calc.text_len] = ch;
    calc.text_len += 1;
}

fn solve(calc: *Calculator) void {
    const input = calc.text[0..calc.text_len];
    log.debug("solving {s}", .{input});
    var tokens = Tokenizer{ .input = input };

    if (solveRoot(&tokens)) |ok| {
        comptime std.debug.assert(calc.text.len >= std.fmt.float.bufferSize(.decimal, f64));

        const result = std.fmt.float.render(calc.text[0..], ok, .{
            .mode = .decimal,
        }) catch unreachable;
        calc.text_len = @intCast(result.len);
    } else |_| {
        calc.text[0] = 'E';
        calc.text_len = 1;
    }
}

const Calculator = struct {
    clicked: bool = false,
    cursor: gui.Pos = .{ 0, 0 },

    text_len: u8 = 0,
    text: [0x1ff]u8 = undefined,

    fb: gui.MappedFramebuffer,
};

pub fn main() !void {
    try abi.rt.init();

    const vmem = caps.Vmem.self;

    const wm_display = try gui.WmDisplay.connect();
    defer wm_display.deinit();

    var window = try wm_display.createWindow(.{
        .size = .{ 250, 400 },
    });
    defer window.deinit();

    var display_keypad: [3]gui.Rect = undefined;
    var key_rows: [9]gui.Rect = undefined;
    var keys: [5][9]gui.Rect = undefined;
    var shift: bool = false;

    var calc = Calculator{
        .fb = try gui.MappedFramebuffer.init(window.fb, vmem),
    };

    while (true) {
        calc.fb.image.fill(@bitCast(background_col));

        const rect = margin(gui.Rect{
            .pos = .{ 0, 0 },
            .size = calc.fb.fb.size,
        });

        rect.split(.vertical, &[_]gui.Constraint{
            .{ .weight = 2 },
            .{ .pixels = 5 },
            .{ .weight = 5 },
        }, &display_keypad);
        const display = display_keypad[0];
        const keypad = display_keypad[2];

        keypad.split(.vertical, &[_]gui.Constraint{
            .{ .weight = 1 },
            .{ .pixels = 5 },
            .{ .weight = 1 },
            .{ .pixels = 5 },
            .{ .weight = 1 },
            .{ .pixels = 5 },
            .{ .weight = 1 },
            .{ .pixels = 5 },
            .{ .weight = 1 },
        }, &key_rows);

        for (0..5) |i| {
            key_rows[i * 2].split(.horizontal, &[_]gui.Constraint{
                .{ .weight = 1 },
                .{ .pixels = 5 },
                .{ .weight = 1 },
                .{ .pixels = 5 },
                .{ .weight = 1 },
                .{ .pixels = 5 },
                .{ .weight = 1 },
                .{ .pixels = 5 },
                .{ .weight = 1 },
            }, &keys[i]);
        }

        try button(&calc, keys[0][0], .back);
        try button(&calc, keys[0][2], .c);
        try button(&calc, keys[0][4], .open);
        try button(&calc, keys[0][6], .close);
        try button(&calc, keys[0][8], .sqrt);

        try button(&calc, keys[1][0], .num7);
        try button(&calc, keys[1][2], .num8);
        try button(&calc, keys[1][4], .num9);
        try button(&calc, keys[1][6], .div);
        try button(&calc, keys[1][8], .percent);

        try button(&calc, keys[2][0], .num4);
        try button(&calc, keys[2][2], .num5);
        try button(&calc, keys[2][4], .num6);
        try button(&calc, keys[2][6], .mul);
        try button(&calc, keys[2][8], .one_over);

        try button(&calc, keys[3][0], .num1);
        try button(&calc, keys[3][2], .num2);
        try button(&calc, keys[3][4], .num3);
        try button(&calc, keys[3][6], .sub);
        try button(&calc, keys[4][4], .dot);
        try button(&calc, keys[4][6], .add);

        const zero = keys[4][0].asAabb().merge(keys[4][2].asAabb()).asRect();
        const equ = keys[3][8].asAabb().merge(keys[4][8].asAabb()).asRect();
        try button(&calc, zero, .num0);
        try button(&calc, equ, .equ);

        const aabb = display.asAabb();
        aabb.draw(calc.fb.image, button_col);

        var label_area = display;
        label_area.pos +|= @as(gui.Pos, @splat(5));

        label_area.drawLabel(
            calc.fb.image,
            calc.text[0..calc.text_len],
            text_col,
            button_col,
        );

        try window.damage(wm_display, null);

        calc.clicked = false;
        const ev = try wm_display.nextEvent();
        switch (ev) {
            .window => |wev| switch (wev.event) {
                .resize => |new_fb| {
                    try calc.fb.update(new_fb, vmem);
                },
                .cursor_moved => |pos| calc.cursor = pos,
                .mouse_button => |mbe| {
                    if (mbe.button == .left and mbe.state != .release) calc.clicked = true;
                },
                .keyboard_input => |key| {
                    if (key.code == .left_shift or key.code == .right_shift) {
                        shift = key.state != .release;
                        continue;
                    }

                    if (key.state == .release) {
                        continue;
                    }

                    if (key.code == .enter) {
                        solve(&calc);
                        continue;
                    }

                    if (key.code == .backspace) {
                        calc.text_len -|= 1;
                        continue;
                    }

                    if (key.code == .escape) {
                        abi.process.exit(0);
                    }

                    if (shift) {
                        if (key.code.toCharShift()) |ch| {
                            append(&calc, ch);
                        }
                    } else {
                        if (key.code.toChar()) |ch| {
                            append(&calc, ch);
                        }
                    }
                },

                else => {},
            },
            else => {},
        }
    }
}

const Tokenizer = struct {
    input: []const u8,
    discard_ch: ?u8 = null,
    discard_tok: ?Token = null,

    fn discard(self: *@This(), tok: Token) void {
        std.debug.assert(self.discard_tok == null);
        self.discard_tok = tok;
        log.debug("discard: {any}", .{tok});
    }

    fn pop(self: *@This()) ?u8 {
        const ch = self.popInner();
        log.debug("ch pop: {?c}", .{ch});
        return ch;
    }

    fn popInner(self: *@This()) ?u8 {
        if (self.discard_ch) |discarded| {
            self.discard_ch = null;

            return discarded;
        }

        if (self.input.len != 0) {
            defer self.input = self.input[1..];
            return self.input[0];
        }

        return null;
    }

    fn next(self: *@This()) ?Token {
        const tok = self.nextInner();
        log.debug("token next: {any}", .{tok});
        return tok;
    }

    fn nextInner(self: *@This()) ?Token {
        if (self.discard_tok) |discarded| {
            self.discard_tok = null;
            return discarded;
        }

        var num: f64 = 0.0;
        var dot: ?u8 = null;

        const State = enum {
            pre_start,
            start,
            pre_number,
            number,
        };

        var ch: u8 = undefined;
        loop: switch (State.pre_start) {
            .pre_start => {
                ch = self.pop() orelse return null;
                continue :loop .start;
            },

            .start => switch (ch) {
                ' ', '\t', '\n' => continue :loop .pre_start,
                '+' => return .add,
                '-' => return .sub,
                '*' => return .mul,
                '/' => return .div,
                '(' => return .open,
                ')' => return .close,
                '%' => return .percent,
                '.', '0'...'9' => continue :loop .number,
                else => return .err,
            },

            .pre_number => {
                ch = self.pop() orelse return .{ .number = num };
                continue :loop .number;
            },

            .number => switch (ch) {
                '_', ' ', '\t', '\n' => continue :loop .pre_number,
                '0'...'9' => {
                    const digit: f64 = @floatFromInt(ch - '0');
                    if (dot) |place| {
                        num += digit * std.math.pow(f64, 10.0, -@as(f64, @floatFromInt(place)));
                        dot = place + 1;
                    } else {
                        num *= 10.0;
                        num += digit;
                    }

                    continue :loop .pre_number;
                },
                '.' => {
                    if (dot != null) {
                        std.debug.assert(self.discard_ch == null);
                        self.discard_ch = ch;
                        return .{ .number = num };
                    }
                    dot = 1;

                    continue :loop .pre_number;
                },
                else => {
                    std.debug.assert(self.discard_ch == null);
                    self.discard_ch = ch;
                    return .{ .number = num };
                },
            },
        }
    }
};

const Token = union(enum) {
    number: f64,
    add,
    sub,
    mul,
    div,
    open,
    close,
    percent,
    err,
};

const Error = error{Syntax};

fn solveRoot(tokens: *Tokenizer) Error!f64 {
    const result = try solveSum(tokens);
    if (tokens.next() != null) return Error.Syntax;
    return result;
}

fn solveSum(tokens: *Tokenizer) Error!f64 {
    var current = try solveProduct(tokens);

    while (tokens.next()) |tok| switch (tok) {
        .add => current += try solveProduct(tokens),
        .sub => current -= try solveProduct(tokens),
        else => {
            tokens.discard(tok);
            break;
        },
    };

    return current;
}

fn solveProduct(tokens: *Tokenizer) Error!f64 {
    var current = try solveAtom(tokens);

    while (tokens.next()) |tok| switch (tok) {
        .mul => current *= try solveAtom(tokens),
        .div => current /= try solveAtom(tokens),
        .percent => current *= 0.01,
        else => {
            tokens.discard(tok);
            break;
        },
    };

    return current;
}

fn solveAtom(tokens: *Tokenizer) Error!f64 {
    const tok = tokens.next() orelse return Error.Syntax;

    return switch (tok) {
        .number => |num| num,
        .open => {
            const num = try solveSum(tokens);
            const close = tokens.next() orelse return Error.Syntax;
            if (close != .close) return Error.Syntax;
            return num;
        },
        else => Error.Syntax,
    };
}
