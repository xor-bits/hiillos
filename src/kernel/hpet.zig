const std = @import("std");
const abi = @import("abi");

const acpi = @import("acpi.zig");
const addr = @import("addr.zig");
const arch = @import("arch.zig");
const caps = @import("caps.zig");
const lazy = @import("lazy.zig");
const spin = @import("spin.zig");
const util = @import("util.zig");

const log = std.log.scoped(.hpet);

//

var hpet_once: spin.Once = .{};

pub fn init(hpet: *const Hpet) !void {
    if (!hpet_once.tryRun()) {
        hpet_once.wait();
        return;
    }

    log.info("found HPET addr: 0x{x}", .{hpet.address});

    hpet_frame = try caps.Frame.initPhysical(addr.Phys.fromInt(hpet.address), 0x1000);

    const regs: *volatile HpetRegs = addr.Phys.fromParts(.{ .page = hpet_frame.?.pages[0] })
        .toHhdm().toPtr(*volatile HpetRegs);

    const config = @as(*volatile Config, &regs.config);
    var tmp = config.*;
    tmp.enable_config = 1;
    config.* = tmp;

    hpet_once.complete();

    log.info("HPET speed: 1ms = {d} ticks", .{1_000_000_000_000 / @as(u64, @as(*volatile u32, &regs.caps_and_id.counter_period_femtoseconds).*)});
}

// TODO: something useful could be done while waiting
// + only one CPU has to measure the APIC timer speed afaik
pub fn hpetSpinWait(micros: u32, just_before: anytype) void {
    const regs: *volatile HpetRegs = addr.Phys.fromParts(.{ .page = hpet_frame.?.pages[0] })
        .toHhdm().toPtr(*volatile HpetRegs);

    const ticks = (@as(u64, micros) * 1_000_000_000) / @as(*volatile u32, &regs.caps_and_id.counter_period_femtoseconds).*;

    just_before.run();
    const deadline = @as(*volatile u64, &regs.main_counter_value).* + ticks;
    while (@as(*volatile u64, &regs.main_counter_value).* <= deadline) {
        std.atomic.spinLoopHint();
    }
}

pub fn bootInfoInstallHpet(boot_info: *caps.Frame, thread: *caps.Thread) !void {
    const frame = hpet_frame orelse return;

    const id = try thread.proc.pushCapability(.init(frame.clone()));
    try boot_info.initialWrite(
        @offsetOf(abi.BootInfo, "hpet"),
        std.mem.asBytes(&abi.caps.Frame{ .cap = id }),
    );
}

pub var hpet_frame: ?*caps.Frame = null;

const Hpet = extern struct {
    header: acpi.SdtHeader align(1),
    flags: Flags align(1),
    hardware_rev_id: u8 align(1),
    pci_vendor_id: u16 align(1),
    address_space_id: u8 align(1),
    address_register_bit_width: u8 align(1),
    address_register_bit_offset: u8 align(1),
    address_reserved: u8 align(1),
    address: u64 align(1),
    hpet_number: u8 align(1),
    minimum_tick: u16 align(1),
    page_protection: u8 align(1),
};

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
    interrupt_status: u64,
    pad2: [25]u64,
    main_counter_value: u64,
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
