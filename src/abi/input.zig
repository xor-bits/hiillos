pub const Event = union(enum) {
    mouse: MouseEvent,
    keyboard: KeyEvent,
};

pub const KeyState = enum(u8) {
    press,
    release,
    single,
};

pub const MouseEvent = union(enum) {
    motion: MouseMotionEvent,
    button: MouseButtonEvent,
};

pub const MouseMotionEvent = struct {
    delta_x: i16,
    delta_y: i16,
    delta_z: i16,
};

pub const MouseButtonEvent = struct {
    button: Button,
    state: KeyState,
};

pub const Button = enum(u8) {
    left,
    middle,
    right,
    mb4,
    mb5,
};

pub const KeyEvent = struct {
    code: KeyCode,
    state: KeyState,
};

pub const KeyCode = enum(u8) {
    escape,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,

    print_screen,
    sysrq,
    scroll_lock,
    pause_break,

    /// backtick `~
    oem8,
    key1,
    key2,
    key3,
    key4,
    key5,
    key6,
    key7,
    key8,
    key9,
    key0,
    /// -_
    oem_minus,
    /// =+
    oem_plus,
    backspace,

    insert,
    home,
    page_up,

    numpad_lock,
    numpad_div,
    numpad_mul,
    numpad_sub,

    tab,
    q,
    w,
    e,
    r,
    t,
    y,
    u,
    i,
    o,
    p,
    /// [{
    oem4,
    /// ]}
    oem6,
    /// \|
    oem5,
    /// #~ ISO layout
    oem7,

    delete,
    end,
    page_down,

    numpad7,
    numpad8,
    numpad9,
    numpad_add,

    caps_lock,
    a,
    s,
    d,
    f,
    g,
    h,
    j,
    k,
    l,
    /// ;:
    oem1,
    /// '"
    oem3,

    enter,

    numpad4,
    numpad5,
    numpad6,

    left_shift,
    z,
    x,
    c,
    v,
    b,
    n,
    m,
    /// ,<
    oem_comma,
    /// .>
    oem_period,
    /// /?
    oem2,
    right_shift,

    arrow_up,

    numpad1,
    numpad2,
    numpad3,
    numpad_enter,

    left_control,
    left_super,
    left_alt,
    space,
    right_altgr,
    right_super,
    menu,
    right_control,

    arrow_left,
    arrow_down,
    arrow_right,

    numpad0,
    numpad_period,

    oem9,
    oem10,
    oem11,
    oem12,
    oem13,

    prev_track,
    next_track,
    mute,
    calculator,
    play,
    stop,
    volume_down,
    volume_up,
    browser,

    power_on,
    too_many_keys,
    right_control2,
    right_alt2,

    pub fn fromScancode0(code: u8) ?@This() {
        return switch (code) {
            0x00 => .too_many_keys,
            0x01 => .f9,
            0x03 => .f5,
            0x04 => .f3,
            0x05 => .f1,
            0x06 => .f2,
            0x07 => .f12,
            0x09 => .f10,
            0x0a => .f8,
            0x0b => .f6,
            0x0c => .f4,
            0x0d => .tab,
            0x0e => .oem8,
            0x11 => .left_alt,
            0x12 => .left_shift,
            0x13 => .oem11,
            0x14 => .left_control,
            0x15 => .q,
            0x16 => .key1,
            0x1a => .z,
            0x1b => .s,
            0x1c => .a,
            0x1d => .w,
            0x1e => .key2,
            0x21 => .c,
            0x22 => .x,
            0x23 => .d,
            0x24 => .e,
            0x25 => .key4,
            0x26 => .key3,
            0x29 => .space,
            0x2a => .v,
            0x2b => .f,
            0x2c => .t,
            0x2d => .r,
            0x2e => .key5,
            0x31 => .n,
            0x32 => .b,
            0x33 => .h,
            0x34 => .g,
            0x35 => .y,
            0x36 => .key6,
            0x3a => .m,
            0x3b => .j,
            0x3c => .u,
            0x3d => .key7,
            0x3e => .key8,
            0x41 => .oem_comma,
            0x42 => .k,
            0x43 => .i,
            0x44 => .o,
            0x45 => .key0,
            0x46 => .key9,
            0x49 => .oem_period,
            0x4a => .oem2,
            0x4b => .l,
            0x4c => .oem1,
            0x4d => .p,
            0x4e => .oem_minus,
            0x51 => .oem12,
            0x52 => .oem3,
            0x54 => .oem4,
            0x55 => .oem_plus,
            0x58 => .caps_lock,
            0x59 => .right_shift,
            0x5a => .enter,
            0x5b => .oem6,
            0x5d => .oem7,
            0x61 => .oem5,
            0x64 => .oem10,
            0x66 => .backspace,
            0x67 => .oem9,
            0x69 => .numpad1,
            0x6a => .oem13,
            0x6b => .numpad4,
            0x6c => .numpad7,
            0x70 => .numpad0,
            0x71 => .numpad_period,
            0x72 => .numpad2,
            0x73 => .numpad5,
            0x74 => .numpad6,
            0x75 => .numpad8,
            0x76 => .escape,
            0x77 => .numpad_lock,
            0x78 => .f11,
            0x79 => .numpad_add,
            0x7a => .numpad3,
            0x7b => .numpad_sub,
            0x7c => .numpad_mul,
            0x7d => .numpad9,
            0x7e => .scroll_lock,
            0x7f => .sysrq,
            0x83 => .f7,
            0xaa => .power_on,
            else => null,
        };
    }

    /// prefixed with 0xe0
    pub fn fromScancode1(code: u8) ?@This() {
        return switch (code) {
            0x11 => .right_altgr,
            0x12 => .right_alt2,
            0x14 => .right_control,
            0x15 => .prev_track,
            0x1f => .left_super,
            0x21 => .volume_down,
            0x23 => .mute,
            0x27 => .right_super,
            0x2b => .calculator,
            0x2f => .menu,
            0x32 => .volume_up,
            0x34 => .play,
            0x3a => .browser,
            0x3b => .stop,
            0x4a => .numpad_div,
            0x4d => .next_track,
            0x5a => .numpad_enter,
            0x69 => .end,
            0x6b => .arrow_left,
            0x6c => .home,
            0x70 => .insert,
            0x71 => .delete,
            0x72 => .arrow_down,
            0x74 => .arrow_right,
            0x75 => .arrow_up,
            0x7a => .page_down,
            0x7c => .print_screen,
            0x7d => .page_up,
            else => null,
        };
    }

    /// prefixed with 0xe1
    pub fn fromScancode2(code: u8) ?@This() {
        return switch (code) {
            0x14 => .right_control2,
            else => null,
        };
    }

    pub fn toChar(self: @This()) ?u8 {
        return switch (self) {
            .oem8 => '`',
            .key1 => '1',
            .key2 => '2',
            .key3 => '3',
            .key4 => '4',
            .key5 => '5',
            .key6 => '6',
            .key7 => '7',
            .key8 => '8',
            .key9 => '9',
            .key0 => '0',
            .oem_minus => '-',
            .oem_plus => '=',
            .backspace => 8,

            .numpad_div => '/',
            .numpad_mul => '*',
            .numpad_sub => '-',

            .tab => '\t',
            .q => 'q',
            .w => 'w',
            .e => 'e',
            .r => 'r',
            .t => 't',
            .y => 'y',
            .u => 'u',
            .i => 'i',
            .o => 'o',
            .p => 'p',
            .oem4 => '[',
            .oem6 => ']',
            .oem5 => '\\',
            .oem7 => '#',

            .numpad7 => '7',
            .numpad8 => '8',
            .numpad9 => '9',
            .numpad_add => '+',

            .a => 'a',
            .s => 's',
            .d => 'd',
            .f => 'f',
            .g => 'g',
            .h => 'h',
            .j => 'j',
            .k => 'k',
            .l => 'l',
            .oem1 => ';',
            .oem3 => '\'',
            .enter => '\n',

            .numpad4 => '4',
            .numpad5 => '5',
            .numpad6 => '6',

            .z => 'z',
            .x => 'x',
            .c => 'c',
            .v => 'v',
            .b => 'b',
            .n => 'n',
            .m => 'm',
            .oem_comma => ',',
            .oem_period => '.',
            .oem2 => '/',

            .numpad1 => '1',
            .numpad2 => '2',
            .numpad3 => '3',
            .numpad_enter => '\n',

            .space => ' ',

            .numpad0 => '0',
            .numpad_period => '.',

            else => null,
        };
    }

    pub fn toCharShift(self: @This()) ?u8 {
        return switch (self) {
            .oem8 => '~',
            .key1 => '!',
            .key2 => '@',
            .key3 => '#',
            .key4 => '$',
            .key5 => '%',
            .key6 => '^',
            .key7 => '&',
            .key8 => '*',
            .key9 => '(',
            .key0 => ')',
            .oem_minus => '_',
            .oem_plus => '+',

            .numpad_div => '/',
            .numpad_mul => '*',
            .numpad_sub => '-',

            .q => 'Q',
            .w => 'W',
            .e => 'E',
            .r => 'R',
            .t => 'T',
            .y => 'Y',
            .u => 'U',
            .i => 'I',
            .o => 'O',
            .p => 'P',
            .oem4 => '{',
            .oem6 => '}',
            .oem5 => '|',
            .oem7 => '~',

            .numpad7 => '7',
            .numpad8 => '8',
            .numpad9 => '9',
            .numpad_add => '+',

            .a => 'A',
            .s => 'S',
            .d => 'D',
            .f => 'F',
            .g => 'G',
            .h => 'H',
            .j => 'J',
            .k => 'K',
            .l => 'L',
            .oem1 => ':',
            .oem3 => '\"',
            .enter => '\n',

            .numpad4 => '4',
            .numpad5 => '5',
            .numpad6 => '6',

            .z => 'Z',
            .x => 'X',
            .c => 'C',
            .v => 'V',
            .b => 'B',
            .n => 'N',
            .m => 'M',
            .oem_comma => '<',
            .oem_period => '>',
            .oem2 => '?',

            .numpad1 => '1',
            .numpad2 => '2',
            .numpad3 => '3',
            .numpad_enter => '\n',

            .space => ' ',

            .numpad0 => '0',
            .numpad_period => '.',

            else => null,
        };
    }
};
