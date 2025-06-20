const abi = @import("abi");
const builtin = @import("builtin");
const std = @import("std");

const acpi = @import("acpi.zig");
const addr = @import("addr.zig");
const arch = @import("arch.zig");
const caps = @import("caps.zig");
const hpet = @import("hpet.zig");
const lazy = @import("lazy.zig");
const main = @import("main.zig");
const pmem = @import("pmem.zig");
const spin = @import("spin.zig");

const log = std.log.scoped(.apic);
const conf = abi.conf;

//

pub const IRQ_TIMER: u8 = 43;
pub const IRQ_IPI_PREEMPT: u8 = 44;
pub const IRQ_IPI_PANIC: u8 = 45;
pub const IRQ_IPI_TLB_SHOOTDOWN: u8 = 46;
pub const IRQ_SPURIOUS: u8 = 255;

pub const IRQ_AVAIL_LOW: u8 = 47;
pub const IRQ_AVAIL_HIGH: u8 = 254;
pub const IRQ_AVAIL_COUNT = IRQ_AVAIL_HIGH - IRQ_AVAIL_LOW + 1;

pub const APIC_SW_ENABLE: u32 = 1 << 8;
pub const APIC_DISABLE: u32 = 1 << 16;
pub const APIC_NMI: u32 = 4 << 8;
pub const APIC_TIMER_MODE_ONESHOT: u32 = 0;
pub const APIC_TIMER_MODE_PERIODIC: u32 = 0b01 << 17;
pub const APIC_TIMER_MODE_TSC_DEADLINE: u32 = 0b10 << 17;

// const APIC_TIMER_DIV: u32 = 0b1011; // div by 1
// const APIC_TIMER_DIV: u32 = 0b0000; // div by 2
// const APIC_TIMER_DIV: u32 = 0b0001; // div by 4
const APIC_TIMER_DIV: u32 = 0b0010; // div by 8
// const APIC_TIMER_DIV: u32 = 0b0011; // div by 16
// const APIC_TIMER_DIV: u32 = 0b1000; // div by 32
// const APIC_TIMER_DIV: u32 = 0b1001; // div by 64
// const APIC_TIMER_DIV: u32 = 0b1010; // div by 128

//

/// all I/O APICs
var ioapics = std.ArrayList(IoApicInfo).init(pmem.page_allocator);
var ioapic_lock: spin.Mutex = .{};
/// all Local APIC IDs that I/O APICs can use as interrupt destinations
var ioapic_lapics = std.ArrayList(IoApicLapic).init(pmem.page_allocator);

var ioapic_lapic_lock: spin.Mutex = .{};

//

// pub const Handler = std.atomic.Value(?*caps.Notify);
pub const Handler = struct {
    lock: spin.Mutex = .{},
    notify: ?*caps.Notify = null,

    pub fn load(self: *@This()) ?*caps.Notify {
        self.lock.lock();
        defer self.lock.unlock();

        const notify = self.notify orelse return null;
        if (notify.refcnt.isUnique()) {
            @branchHint(.cold);

            // this handler is the only one holding the Notify cap
            // so notifying it does nothing and its unobtainable
            // => free it
            notify.deinit();

            self.notify = null;
            return null;
        }

        notify.refcnt.inc();
        return notify;
    }
};

pub const ApicRegs = union(enum) {
    xapic: *LocalXApicRegs,
    x2apic: *LocalX2ApicRegs,
    none: void,
};

const IoApicLapic = struct {
    lapic_id: u4,
    handlers: *[IRQ_AVAIL_COUNT]Handler,
};

//

/// parse Multiple APIC Description Table
pub fn init(madt: *const acpi.Madt) !void {
    log.info("init APIC-{}", .{arch.cpuId()});

    if (builtin.target.cpu.arch == .x86_64) {
        disablePic();
    }

    // cpu0 also sets up all I/O APICs
    if (arch.cpuId() == 0)
        ioapic_lock.lock();
    defer if (arch.cpuId() == 0)
        ioapic_lock.unlock();

    var lapic_addr: u64 = madt.lapic_addr;

    var it = madt.iterator();
    while (it.next()) |anyentry| {
        switch (anyentry) {
            .processor_local_apic => {}, // this is not important
            .ioapic => |entry| {
                if (arch.cpuId() != 0) continue;

                log.info("found I/O APIC addr: 0x{x}", .{entry.io_apic_addr});
                try ioapics.append(.{
                    .addr = addr.Phys.fromInt(entry.io_apic_addr).toHhdm().toPtr(*IoApicRegs),
                    .io_apic_id = entry.io_apic_id,
                    .global_system_interrupt_base = entry.global_system_interrupt_base,
                });
            },
            .ioapic_interrupt_source_override => |entry| {
                if (arch.cpuId() != 0) continue;

                // FIXME: this is prob important
                log.err("I/O APIC interrupt source override detected but not yet handled: {}", .{entry});
            },
            .ioapic_nmi_source => {}, // this might be important
            .lapic_nmis => {}, // this could be important
            .lapic_addr_override => |entry| {
                lapic_addr = entry.lapic_addr;
            },
            .processor_lx2apic => {}, // this may be important
        }
    }

    if (arch.cpuId() == 0)
        log.info("found Local APIC addr: 0x{x}", .{lapic_addr});
    const locals = arch.cpuLocal();

    const cpu_features = arch.CpuFeatures.read();
    if (cpu_features.x2apic) {
        log.info("x2APIC mode", .{});
        locals.apic_regs = .{ .x2apic = @ptrFromInt(arch.IA32_X2APIC) };
    } else if (cpu_features.apic) {
        log.info("legacy xAPIC mode", .{});
        locals.apic_regs = .{ .xapic = addr.Phys.fromInt(lapic_addr).toHhdm().toPtr(*LocalXApicRegs) };
    } else {
        log.err("CPU doesn't support x2APIC nor xAPIC", .{});
        arch.hcf();
    }
}

pub fn enable() !void {
    const locals = arch.cpuLocal();
    switch (locals.apic_regs) {
        .xapic => |regs| try enableAny(locals, regs, .enabled_xapic),
        .x2apic => |regs| try enableAny(locals, regs, .enabled_x2apic),
        .none => unreachable,
    }
}

fn enableAny(
    locals: *main.CpuLocalStorage,
    regs: anytype,
    comptime mode: @TypeOf(@as(ApicBaseMsr, undefined).lapic_mode),
) !void {
    // enable APIC
    var base = ApicBaseMsr.read();
    base.lapic_mode = mode;
    base.write();

    // install this as a usable I/O APIC LAPIC target
    const lapic_id: u32 = regs.lapic_id.read();
    if (lapic_id <= 0xF) {
        ioapic_lapic_lock.lock();
        defer ioapic_lapic_lock.unlock();
        try ioapic_lapics.append(.{
            .lapic_id = @truncate(lapic_id),
            .handlers = &arch.cpuLocal().interrupt_handlers,
        });
    }

    // reset APIC to a well-known state
    if (mode == .enabled_xapic) {
        regs.destination_format.write(0xFFFF_FFFF);
        regs.logical_destination.write(0x00FF_FFFF);
    }
    regs.lvt_timer.write(APIC_DISABLE);
    regs.lvt_performance_monitoring_counters.write(APIC_NMI);
    regs.lvt_lint0.write(APIC_DISABLE);
    regs.lvt_lint1.write(APIC_DISABLE);
    regs.task_priority.write(0);

    // enable
    regs.spurious_interrupt_vector.write(APIC_SW_ENABLE | @as(u32, IRQ_SPURIOUS));

    // enable timer interrupts
    const period = measureApicTimerSpeed(locals, regs) * 500;
    regs.divide_configuration.write(APIC_TIMER_DIV);
    regs.lvt_timer.write(IRQ_TIMER | APIC_TIMER_MODE_PERIODIC);
    regs.initial_count.write(period);
    regs.lvt_thermal_sensor.write(0);
    regs.lvt_error.write(0);
    regs.divide_configuration.write(APIC_TIMER_DIV); // buggy hardware fix

    if (locals.id == 0)
        log.info("APIC initialized", .{});
}

/// returns the apic period for 1ms
fn measureApicTimerSpeed(locals: *main.CpuLocalStorage, regs: anytype) u32 {
    regs.divide_configuration.write(APIC_TIMER_DIV);

    hpet.hpetSpinWait(1_000, struct {
        regs: @TypeOf(regs),
        pub fn run(s: *const @This()) void {
            s.regs.initial_count.write(0xFFFF_FFFF);
        }
    }{ .regs = regs });

    regs.lvt_timer.write(APIC_DISABLE);
    const count = 0xFFFF_FFFF - regs.current_count.read();

    if (locals.id == 0)
        log.info("APIC timer speed: 1ms = {d} ticks", .{count});

    return count;
}

// TODO: the mode could be comptime here,
// the ISR would be selected dynamically
pub fn eoi() void {
    const locals = arch.cpuLocal();
    // log.info("{?*}", .{locals.current_thread});
    switch (locals.apic_regs) {
        .xapic => |regs| regs.eoi.write(0),
        .x2apic => |regs| regs.eoi.write(0),
        .none => unreachable,
    }
}

pub fn interProcessorInterrupt(target_lapic_id: u32, vector: u8) void {
    switch (arch.cpuLocal().apic_regs) {
        .xapic => |regs| {
            if (target_lapic_id > std.math.maxInt(u8)) {
                log.err("tried to IPI a processor ({}) that doesn't exist", .{target_lapic_id});
                return;
            }

            const icr_high = XApicIcrHigh{
                .destination = @truncate(target_lapic_id),
            };
            const icr_low = XApicIcrLow{
                .vector = vector,
                .delivery_mode = .fixed,
                .destination_mode = .physical,
                .level = .assert,
                .trigger_mode = .edge,
                .destination_shorthand = .no_shorthand,
            };

            regs.interrupt_command[1].write(@bitCast(icr_high));
            regs.interrupt_command[0].write(@bitCast(icr_low));
        },
        .x2apic => |regs| {
            const icr = X2ApicIcr{
                .vector = vector,
                .delivery_mode = .fixed,
                .destination_mode = .physical,
                .level = .assert,
                .trigger_mode = .edge,
                .destination_shorthand = .no_shorthand,
                .destination = target_lapic_id,
            };

            regs.interrupt_command.writeIcr(@bitCast(icr));
        },
        .none => unreachable,
    }
}

/// source IRQ would be the source like keyboard at 1
/// destination IRQ would be the IDT handler index
pub fn registerExternalInterrupt(
    source_irq: u8,
) !?*caps.Notify {
    // log.info("registering interrupt {}", .{source_irq});

    ioapic_lapic_lock.lock();
    defer ioapic_lapic_lock.unlock();
    ioapic_lock.lock();
    defer ioapic_lock.unlock();

    // FIXME: read the overrides

    const lapic_id, const notify, const i = try findUsableHandler() orelse return null;
    errdefer notify.deinit();
    const ioapic, const low_index = findUsableRedirectEntry(source_irq) orelse return null;
    const high_index = low_index + 1;

    // log.info("lapic_id={} i={}", .{
    //     source_irq, i,
    // });

    var low = ioapicRead(ioapic, low_index);
    var high = ioapicRead(ioapic, high_index);

    var val = @as(IoApicRedirect, @bitCast([2]u32{ low, high }));
    val.mask = .enable;
    val.destination_mode = .physical;
    val.delivery_mode = .fixed;
    val.vector = i + IRQ_AVAIL_LOW;
    val._reserved0 = 0;
    val._reserved1 = 0;
    val.destination_apic_id = lapic_id;

    low, high = @as([2]u32, @bitCast(val));

    ioapicWrite(ioapic, high_index, high);
    ioapicWrite(ioapic, low_index, low);

    return notify;
}

/// `ioapic_lapic_lock` has to be held
fn findUsableHandler() !?struct { u4, *caps.Notify, u8 } {
    for (ioapic_lapics.items) |lapic| {
        for (lapic.handlers[0..], 0..) |*handler, i| {
            handler.lock.lock();
            defer handler.lock.unlock();

            if (handler.notify != null) continue;

            const notify = try caps.Notify.init();
            handler.notify = notify;
            notify.refcnt.inc();

            return .{ lapic.lapic_id, notify, @truncate(i) };
        }
    }

    for (ioapic_lapics.items) |lapic| {
        for (lapic.handlers[0..], 0..) |*handler, i| {
            handler.lock.lock();
            defer handler.lock.unlock();

            const notify = handler.notify orelse b: {
                const notify = try caps.Notify.init();
                handler.notify = notify;
                break :b notify;
            };

            notify.refcnt.inc();

            return .{ lapic.lapic_id, notify, @truncate(i) };
        }
    }

    return null;
}

fn findUsableRedirectEntry(source_irq: u32) ?struct { *IoApicRegs, u32 } {
    for (ioapics.items) |ioapic| {
        const min = ioapic.global_system_interrupt_base;
        const max = @as(IoApicVer, @bitCast(ioapicRead(ioapic.addr, 1))).num_irqs_minus_one + 1 + min;

        if (min > source_irq) continue;
        if (max <= source_irq) continue;

        const low_index = 0x10 + (source_irq - min) * 2;
        const high_index = low_index + 1;

        const low = ioapicRead(ioapic.addr, low_index);
        const high = ioapicRead(ioapic.addr, high_index);

        const val = @as(IoApicRedirect, @bitCast([2]u32{ low, high }));

        // log.info("ioapic={*} entry={} val={}", .{ ioapic.addr, source_irq - min, val });

        if (val.vector == 0) {
            // log.info("slot {}", .{source_irq - min});
            return .{ ioapic.addr, low_index };
        }
    }

    return null;
}

fn ioapicRead(ioapic: *IoApicRegs, reg: u32) u32 {
    ioapic.register_select.write(reg);
    return ioapic.register_data.read();
}

fn ioapicWrite(ioapic: *IoApicRegs, reg: u32, val: u32) void {
    ioapic.register_select.write(reg);
    ioapic.register_data.write(val);
}

//

pub const IoApicInfo = struct {
    addr: *IoApicRegs,
    io_apic_id: u8,
    global_system_interrupt_base: u32,
};

pub const ApicBaseMsr = packed struct {
    reserved0: u8,
    is_bsp: bool,
    reserved1: u1,
    lapic_mode: enum(u2) {
        disabled = 0b00,
        enabled_xapic = 0b10,
        enabled_x2apic = 0b11,
    },
    apic_base: u24,
    reserved2: u28,

    pub fn read() @This() {
        return @bitCast(arch.rdmsr(arch.IA32_APIC_BASE));
    }

    pub fn write(self: @This()) void {
        arch.wrmsr(arch.IA32_APIC_BASE, @bitCast(self));
    }
};

// I/O APIC register structs

/// I/O APIC register index 0
pub const IoApicId = packed struct {
    _reserved0: u24,
    apic_id: u4,
    _reserved1: u4,
};

/// I/O APIC register index 1
pub const IoApicVer = packed struct {
    io_apic_version: u8,
    _reserved0: u8,
    num_irqs_minus_one: u8,
    _reserved1: u8,
};

/// I/O APIC register index 2
pub const IoApicArb = packed struct {
    _reserved0: u24,
    apic_arbitration_id: u4,
    _reserved1: u4,
};

/// I/O APIC register index N and N+1
pub const IoApicRedirect = packed struct {
    vector: u8, // destination IDT index
    delivery_mode: DeliveryMode,
    destination_mode: DestinationMode,
    delivery_status: DeliveryStatus = .idle,
    pin_polarity: enum(u1) {
        active_high,
        active_low,
    } = .active_high,
    remote_irr: u1 = 0, // idk
    trigger_mode: TriggerMode = .edge,
    mask: enum(u1) {
        enable,
        disable,
    } = .enable,
    _reserved0: u39 = 0,
    destination_apic_id: u4,
    _reserved1: u4 = 0,
};

// LAPIC register structs

pub const XApicIcrHigh = packed struct {
    reserved: u24 = 0,
    destination: u8,
};

pub const XApicIcrLow = packed struct {
    vector: u8,
    delivery_mode: DeliveryMode,
    destination_mode: DestinationMode,
    delivery_status: DeliveryStatus = .idle,
    _reserved0: u1 = 0,
    level: enum(u1) {
        deassert,
        assert,
    },
    trigger_mode: TriggerMode,
    _reserved1: u2 = 0,
    destination_shorthand: enum(u2) {
        no_shorthand,
        self,
        all_including_self,
        all_excluding_self,
    },
    _reserved2: u12 = 0,
};

pub const X2ApicIcr = packed struct {
    vector: u8,
    delivery_mode: DeliveryMode,
    destination_mode: DestinationMode,
    _reserved0: u1 = 0,
    _reserved1: u1 = 0,
    level: enum(u1) {
        deassert,
        assert,
    },
    trigger_mode: TriggerMode,
    reserved1: u2 = 0,
    destination_shorthand: enum(u2) {
        no_shorthand,
        self,
        all_including_self,
        all_excluding_self,
    },
    reserved2: u12 = 0,
    destination: u32,
};

// Common stuff

pub const DeliveryMode = enum(u3) {
    fixed,
    lowest_priority, // this one is interesting for scheduling
    smi,
    reserved0,
    nmi,
    init,
    start_up,
    reserved1,
};

pub const DestinationMode = enum(u1) {
    physical,
    logical,
};

pub const DeliveryStatus = enum(u1) {
    idle,
    send_pending,
};

pub const TriggerMode = enum(u1) {
    edge,
    level,
};

pub const RegisterMode = enum {
    none,
    r,
    w,
    rw,
};

// x2APIC MSR registers

pub fn X2ApicReg(comptime mode: RegisterMode) type {
    return struct {
        _val: u8, // MSR address increment is 1, it isn't an actual memory address

        pub fn read(self: *@This()) u32 {
            return @truncate(readIcr(self));
        }

        pub fn write(self: *@This(), val: u32) void {
            self.writeIcr(val);
        }

        pub fn readIcr(self: *@This()) u64 {
            if (mode == .w) @compileError("cannot read from a write-only register");
            if (mode == .none) @compileError("cannot read from a reserved register");
            const msr: usize = @intFromPtr(&self._val);
            std.debug.assert(0x800 <= msr and msr <= 0x8FF);

            if (conf.LOG_APIC) log.debug("x2apic read from {x}H", .{msr});
            return arch.rdmsr(@truncate(msr));
        }

        pub fn writeIcr(self: *@This(), val: u64) void {
            if (mode == .r) @compileError("cannot write into a read-only register");
            if (mode == .none) @compileError("cannot write into a reserved register");
            const msr: usize = @intFromPtr(&self._val);
            std.debug.assert(0x800 <= msr and msr <= 0x8FF);

            if (conf.LOG_APIC) log.debug("x2apic write to {x}H", .{msr});
            arch.wrmsr(@truncate(msr), val);
        }
    };
}

pub const LocalX2ApicRegs = struct {
    _reserved0: [2]X2ApicReg(.none),
    lapic_id: X2ApicReg(.r),
    lapic_version: X2ApicReg(.r),
    _reserved1: [4]X2ApicReg(.none),
    task_priority: X2ApicReg(.rw),
    _reserved2: [1]X2ApicReg(.none),
    processor_priority: X2ApicReg(.r),
    eoi: X2ApicReg(.w),
    _reserved3: [1]X2ApicReg(.none),
    logical_destination: X2ApicReg(.r),
    _reserved4: [1]X2ApicReg(.none),
    spurious_interrupt_vector: X2ApicReg(.rw),
    in_service: [8]X2ApicReg(.r),
    trigger_mode: [8]X2ApicReg(.r),
    interrupt_request: [8]X2ApicReg(.r),
    error_status: X2ApicReg(.rw),
    _reserved5: [6]X2ApicReg(.none),
    lvt_corrected_machine_check_interrupt: X2ApicReg(.rw),
    interrupt_command: X2ApicReg(.rw),
    _reserved6: [1]X2ApicReg(.none),
    lvt_timer: X2ApicReg(.rw),
    lvt_thermal_sensor: X2ApicReg(.rw),
    lvt_performance_monitoring_counters: X2ApicReg(.rw),
    lvt_lint0: X2ApicReg(.rw),
    lvt_lint1: X2ApicReg(.rw),
    lvt_error: X2ApicReg(.rw),
    initial_count: X2ApicReg(.rw),
    current_count: X2ApicReg(.r),
    _reserved7: [4]X2ApicReg(.none),
    divide_configuration: X2ApicReg(.rw),
    self_ipi: X2ApicReg(.w),
};

// Legacy xAPIC and I/O APIC MMIO registers

pub fn XApicReg(comptime mode: RegisterMode) type {
    return extern struct {
        _val: u32 align(16),

        pub fn read(self: *@This()) u32 {
            if (mode == .w) @compileError("cannot read from a write-only register");
            if (mode == .none) @compileError("cannot read from a reserved register");

            if (conf.LOG_APIC) log.debug("xapic read from {x}H", .{@intFromPtr(&self._val)});
            return @as(*volatile u32, &self._val).*;
        }

        pub fn write(self: *@This(), val: u32) void {
            if (mode == .r) @compileError("cannot write into a read-only register");
            if (mode == .none) @compileError("cannot write into a reserved register");

            if (conf.LOG_APIC) log.debug("xapic write to {x}H", .{@intFromPtr(&self._val)});
            @as(*volatile u32, &self._val).* = val;
        }
    };
}

pub const IoApicRegs = extern struct {
    register_select: XApicReg(.rw),
    register_data: XApicReg(.rw),
};

pub const LocalXApicRegs = extern struct {
    _reserved0: [2]XApicReg(.none),
    lapic_id: XApicReg(.r),
    lapic_version: XApicReg(.r),
    _reserved1: [4]XApicReg(.none),
    task_priority: XApicReg(.rw),
    arbitration_priority: XApicReg(.r),
    processor_priority: XApicReg(.r),
    eoi: XApicReg(.w),
    remote_read: XApicReg(.r),
    logical_destination: XApicReg(.rw),
    destination_format: XApicReg(.rw),
    spurious_interrupt_vector: XApicReg(.rw),
    in_service: [8]XApicReg(.r),
    trigger_mode: [8]XApicReg(.r),
    interrupt_request: [8]XApicReg(.r),
    error_status: XApicReg(.r),
    _reserved2: [6]XApicReg(.none),
    lvt_corrected_machine_check_interrupt: XApicReg(.rw),
    interrupt_command: [2]XApicReg(.rw),
    lvt_timer: XApicReg(.rw),
    lvt_thermal_sensor: XApicReg(.rw),
    lvt_performance_monitoring_counters: XApicReg(.rw),
    lvt_lint0: XApicReg(.rw),
    lvt_lint1: XApicReg(.rw),
    lvt_error: XApicReg(.rw),
    initial_count: XApicReg(.rw),
    current_count: XApicReg(.r),
    _reserved3: [4]XApicReg(.none),
    divide_configuration: XApicReg(.rw),
    _reserved4: [4]XApicReg(.none),
};

//

var pic_once: spin.Once = .{};

fn disablePic() void {
    if (!pic_once.tryRun()) {
        pic_once.wait();
        return;
    }
    defer pic_once.complete();

    log.info("obliterating PIC because PIC sucks", .{});
    const outb = arch.x86_64.outb;
    const ioWait = arch.x86_64.ioWait;

    // the PIC is shit (not APIC, APIC is great)
    // AND its enabled by default usually
    // AND it gives spurious interrupts
    // AND the interrupts it gives by default most likely
    // conflict with CPU exceptions (INTEL WTF WHY)
    const pic1 = 0x20;
    const pic2 = 0xA0;
    const pic1_cmd = pic1;
    const pic1_data = pic1 + 1;
    const pic2_cmd = pic2;
    const pic2_data = pic2 + 1;

    const icw1_icw4 = 0x1;
    const icw1_init = 0x10;
    const icw4_8086 = 0x1;

    // remap pic to discarded IRQs (32..47)
    outb(pic1_cmd, icw1_init | icw1_icw4);
    ioWait();
    outb(pic2_cmd, icw1_init | icw1_icw4);
    ioWait();
    outb(pic1_data, 32); // set master to IRQ32..IRQ39
    ioWait();
    outb(pic2_data, 40); // set master to IRQ40..IRQ47
    ioWait();
    outb(pic1_data, 4);
    ioWait();
    outb(pic2_data, 2);
    ioWait();
    outb(pic1_data, icw4_8086);
    ioWait();
    outb(pic2_data, icw4_8086);
    ioWait();

    // mask out all interrupts to limit the random useless spam from PIC
    outb(pic1_data, 0xFF);
    outb(pic2_data, 0xFF);

    log.info("PIC disabled", .{});
}
