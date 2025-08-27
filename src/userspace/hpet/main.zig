const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.hpet);
const Error = abi.sys.Error;

//

pub export var manifest = abi.loader.Manifest.new(.{
    .name = "hpet",
});

pub export var export_hpet = abi.loader.Resource.new(.{
    .name = "hiillos.hpet.ipc",
    .ty = .receiver,
});

pub export var import_hpet_frame = abi.loader.Resource.new(.{
    .name = "hiillos.root.hpet",
    .ty = .frame,
});

pub export var import_hpet_pit_port = abi.loader.Resource.new(.{
    .name = "hiillos.hpet.pit_cmd_port",
    .ty = .x86_ioport,
    .note = 0x43,
});

pub export var import_hpet_irq_allocator = abi.loader.Resource.new(.{
    .name = "hiillos.hpet.irq_allocator",
    .ty = .x86_irq_allocator,
});

//

var hpet_regs: ?*volatile HpetRegs = null;
var irqs: [24]bool = .{false} ** 24;

var timer_count: u8 = 0;
var timers: [32]Timer = .{Timer{}} ** 32;

//

pub fn main() !void {
    try abi.caps.init();
    log.info("hello from hpet", .{});

    const vmem = caps.Vmem.self;

    const hpet_frame = caps.Frame{ .cap = import_hpet_frame.handle };
    defer hpet_frame.close();

    const pit_cmd = caps.X86IoPort{ .cap = import_hpet_pit_port.handle };

    const irq_allocator = caps.X86IrqAllocator{ .cap = import_hpet_irq_allocator.handle };

    const hpet_addr = try vmem.map(
        hpet_frame,
        0,
        0,
        0x1000,
        .{
            .cache = .uncacheable,
            .write = true,
        },
    );

    // disable PIT
    try pit_cmd.outb(0b00_00_001); // ch 0, latch count val cmd, one-shot
    try pit_cmd.outb(0b01_00_001); // ch 1, latch count val cmd, one-shot
    try pit_cmd.outb(0b10_00_001); // ch 2, latch count val cmd, one-shot

    // enable HPET
    hpet_regs = @ptrFromInt(hpet_addr);
    timer_count = @as(*volatile Caps, &hpet_regs.?.caps_and_id).*.n_timers_minus_one + 1;

    const config = @as(*volatile Config, &hpet_regs.?.config);
    var tmp = config.*;
    tmp.enable_config = 1;
    config.* = tmp;

    // set up the interrupts
    for (0..timer_count) |timer_idx| {
        const timer = hpet_regs.?.timer(timer_idx);

        var conf = @as(*volatile TimerNConfigAndCaps, &timer.config_and_caps).*;
        for (3..24) |irq_idx| {
            if (conf.int_route_cap & (@as(u32, 1) << @as(u5, @truncate(irq_idx))) == 0) continue;

            if (!irqs[irq_idx]) {
                const irq = try caps.X86Irq.create(irq_allocator, @truncate(irq_idx));
                errdefer irq.close();
                const notify = try irq.subscribe();
                errdefer notify.close();
                try abi.thread.spawn(hpetThreadMain, .{ irq, notify });
            }
            irqs[irq_idx] = true;

            log.info("timer hooked up to IRQ{}", .{irq_idx});

            // log.info("default timer conf {}", .{conf});
            conf = TimerNConfigAndCaps{
                .int_route_cap = conf.int_route_cap,
                .int_route_config = @as(u5, @truncate(irq_idx)),
            };
            break;
        } else {
            log.err("cannot use timer {} interrupts: 0b{b} {}", .{ timer_idx, conf.int_route_cap, conf });
        }
        @as(*volatile TimerNConfigAndCaps, &timer.config_and_caps).* = conf;
    }

    var ctx: Context = .{};
    const server = abi.HpetProtocol.Server(.{
        .Context = *Context,
        .scope = if (abi.conf.LOG_SERVERS) .hpet else null,
    }, .{
        .timestamp = timestampHandler,
        .sleep = sleepHandler,
        .sleepDeadline = sleepDeadlineHandler,
    }).init(&ctx, .{ .cap = export_hpet.handle });

    log.info("HPET server listening", .{});
    var msg = try server.rx.recv();
    while (true) {
        server.ctx.dont_reply = false;
        try server.process(&msg);

        if (!server.ctx.dont_reply)
            msg = try server.rx.replyRecv(msg)
        else
            msg = try server.rx.recv();
    }
}

pub const Context = struct {
    dont_reply: bool = false,
};

fn timestampHandler(_: *Context, _: u32, _: void) struct { u128 } {
    return .{timestampNanos()};
}

fn sleepHandler(ctx: *Context, _: u32, req: struct { u128 }) struct { void } {
    ctx.dont_reply = true;

    const deadline_nanos = req.@"0" + timestampNanos();
    const reply = caps.Reply.create() catch unreachable;

    sleepDeadline(reply, deadline_nanos);
    return .{{}};
}

fn sleepDeadlineHandler(ctx: *Context, _: u32, req: struct { u128 }) struct { void } {
    ctx.dont_reply = true;

    const deadline_nanos = req.@"0";
    const reply = caps.Reply.create() catch unreachable;

    sleepDeadline(reply, deadline_nanos);
    return .{{}};
}

fn hpetThreadMain(irq: caps.X86Irq, notify: caps.Notify) !void {
    // log.debug("HPET timer thread", .{});

    const regs = hpet_regs.?;
    while (true) {
        _ = notify.wait();
        try irq.ack();

        // log.debug("HPET INTERRUPT", .{});

        const main_counter = regs.readMainCounter();

        for (timers[0..timer_count], 0..) |*timer, i| {
            timer.lock.lock();
            defer timer.lock.unlock();

            const timer_comparator = @as(*volatile u64, &regs.timer(i).comparator_value);
            const current = timer.current orelse continue;

            // wake up the current waiter
            if (current.deadline <= main_counter) {
                timer.current = null;
                current.reply.reply(.{}) catch |err| {
                    log.err("invalid reply cap: {}", .{err});
                };
            } else {
                continue;
            }

            // wake up every waiter that has its deadline completed
            while (timer.deadlines.removeOrNull()) |next| {
                if (next.deadline <= main_counter) {
                    // wake it up if its ready
                    next.reply.reply(.{}) catch |err| {
                        log.err("invalid reply cap: {}", .{err});
                    };
                } else {
                    // or set it as the timers current target and stop
                    timer.current = next;
                    timer_comparator.* = next.deadline;
                    break;
                }
            }
        }
    }
}

pub fn now() u64 {
    return hpet_regs.?.readMainCounter();
}

pub fn asNanos(t: u64) u128 {
    const regs = hpet_regs.?;
    return @as(u128, t) * regs.readSpeed() / 1_000_000;
}

pub fn elapsedNanos(from_then: u64) u128 {
    const regs = hpet_regs.?;
    return @as(u128, regs.readMainCounter() - from_then) * regs.readSpeed() / 1_000_000;
}

pub fn timestampNanos() u128 {
    const regs = hpet_regs.?;
    return @as(u128, regs.readMainCounter()) * regs.readSpeed() / 1_000_000;
}

pub fn hpetSpinWait(micros: u32) void {
    const regs: *volatile HpetRegs = hpet_regs.?;

    const ticks = (@as(u64, micros) * 1_000_000_000) / @as(u128, regs.readSpeed());

    const deadline = regs.readMainCounter() + ticks;
    while (regs.readMainCounter() <= deadline) {
        abi.sys.yield();
    }
}

pub fn sleepDeadline(reply: caps.Reply, timestamp_nanos: u128) void {
    const regs = hpet_regs.?;
    const _counter = timestamp_nanos * 1_000_000 / regs.readSpeed();
    if (_counter > std.math.maxInt(u64)) {
        @branchHint(.cold);
        log.err("FIXME: deadline val is bigger than max main counter val", .{});
        return;
    }
    const counter: u64 = @truncate(_counter);

    var least_used: u8 = 0;
    for (timers[0..timer_count], 0..) |*timer, i| {
        const active_deadline_count = timer.count();
        if (active_deadline_count <= timers[least_used].count()) {
            least_used = @truncate(i);
            if (active_deadline_count == 0) break;
        }
    }

    var new: Deadline = .{ .deadline = counter, .reply = reply };

    const timer = &timers[least_used];
    if (timer.current) |timer_current| {
        if (counter < timer_current.deadline) {
            // set a new comparator value if the new deadline is sooner than the current

            @as(*volatile u64, &regs.timer(least_used).comparator_value).* = new.deadline;
            new, timer.current = .{ timer_current, new };
        }

        timer.deadlines.add(new) catch |err| {
            log.err("lost track of timers: {}", .{err});
        };
    } else {
        @as(*volatile u64, &regs.timer(least_used).comparator_value).* = new.deadline;
        timer.current = new;
    }
}

//

const Timer = struct {
    _: void align(std.atomic.cache_line) = {},

    /// null means the timer is off, non null means the current comparator value (for faster read)
    lock: abi.thread.Mutex = .{},
    current: ?Deadline = null,
    deadlines: std.PriorityQueue(Deadline, void, struct {
        fn inner(_: void, a: Deadline, b: Deadline) std.math.Order {
            return std.math.order(a.deadline, b.deadline);
        }
    }.inner) = .init(abi.mem.slab_allocator, {}),

    fn count(self: *@This()) u64 {
        return self.deadlines.count() + @intFromBool(self.current != null);
    }
};

const Deadline = struct {
    deadline: u64,
    reply: caps.Reply,
};

//

const Flags = packed struct {
    comparator_count: u5,
    counter_size: u1,
    reserved: u1,
    legacy_replacement: u1,
};

const HpetRegs = extern struct {
    caps_and_id: Caps,
    pad0: u64,
    config: Config,
    pad1: u64,
    interrupt_status: InterruptStatus,
    pad2: [25]u64,
    main_counter_value: u64,

    fn readMainCounter(self: *volatile @This()) u64 {
        return @as(*volatile u64, &self.main_counter_value).*;
    }

    fn readSpeed(self: *volatile @This()) u32 {
        return @as(*volatile u32, &self.caps_and_id.counter_period_femtoseconds).*;
    }

    fn timer(self: *volatile @This(), n: usize) *volatile TimerRegs {
        const timer_base: usize = @intFromPtr(self);
        return @ptrFromInt(timer_base + 0x100 + 0x20 * n);
    }
};

const TimerRegs = extern struct {
    config_and_caps: TimerNConfigAndCaps,
    comparator_value: u64,
    // fsb_interrupt_route: FsbInterruptRoute,
};

const Caps = packed struct {
    rev_id: u8,
    n_timers_minus_one: u5,
    u64_capable: u1,
    reserved: u1,
    legacy_replacement_capable: u1,
    vendor_id: u16,
    counter_period_femtoseconds: u32,
};

const Config = packed struct {
    enable_config: u1,
    legacy_replacement_config: u1,
    reserved: u62,
};

const InterruptStatus = packed struct {
    timer_n_status: u32,
    reserved: u32,
};

const TimerNConfigAndCaps = packed struct {
    reserved0: u1 = 0,
    int_type_config: u1 = 0,
    int_enable_config: u1 = 1,
    type_config: u1 = 0,
    periodic_int_cap: u1 = 0,
    u64_cap: u1 = 0,
    value_set_config: u1 = 0,
    reserved1: u1 = 0,
    u32_mode_forced_config: u1 = 0,
    int_route_config: u5 = 2,
    fsb_enable_config: u1 = 0,
    fsb_interrupt_mapping_cap: u1 = 0,
    reserved2: u16 = 0,
    int_route_cap: u32,
};
