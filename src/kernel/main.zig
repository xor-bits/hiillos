const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");

const acpi = @import("acpi.zig");
const addr = @import("addr.zig");
const apic = @import("apic.zig");
const arch = @import("arch.zig");
const args = @import("args.zig");
const boot = @import("boot.zig");
const call = @import("call.zig");
const caps = @import("caps.zig");
const copy = @import("copy.zig");
const init = @import("init.zig");
const logs = @import("logs.zig");
const pmem = @import("pmem.zig");
const proc = @import("proc.zig");

//

const conf = abi.conf;
pub const std_options = logs.std_options;
pub const panic = logs.panic;
const Error = abi.sys.Error;
const volat = abi.util.volat;

//

pub var all_cpu_locals: []CpuLocalStorage = &.{};
pub var hhdm_offset: usize = 0xFFFF_8000_0000_0000;

pub const CpuLocalStorage = struct {
    _: void align(0x1000) = {},

    // used to read the pointer to this struct through GS
    self_ptr: *CpuLocalStorage,

    cpu_config: arch.CpuConfig,

    /// used to keep the active address space from
    /// being deallocated while not having a thread
    current_vmem: ?*caps.Vmem = null,
    /// used to track the current thread
    current_thread: ?*caps.Thread = null,
    /// cpu id, highest cpu id is always `cpu_count - 1`
    id: u32,
    /// cached local apic id of the cpu
    lapic_id: u32,
    lapic: apic.Locals = .{},

    // pcid_lru: ?caps.PcidLru,

    tlb_shootdown_queue: [16]*caps.TlbShootdown = undefined,
    tlb_shootdown_queue_head: u4 = 0,
    tlb_shootdown_queue_len: u4 = 0,
    tlb_shootdown_queue_lock: abi.lock.SpinMutex = .{},

    initialized: std.atomic.Value(bool),

    // TODO: arena allocator that forgets everything when the CPU enters the syscall handler

    pub fn popTlbShootdown(self: *@This()) *caps.TlbShootdown {
        var backoff: abi.lock.Backoff = .{};

        while (true) {
            if (self.tryPopTlbShootdown()) |owned_ptr| return owned_ptr;
            backoff.spin();
        }
    }

    pub fn tryPopTlbShootdown(self: *@This()) ?*caps.TlbShootdown {
        self.tlb_shootdown_queue_lock.lock();
        defer self.tlb_shootdown_queue_lock.unlock();

        if (self.tlb_shootdown_queue_len == 0) return null;
        self.tlb_shootdown_queue_len -= 1;
        defer self.tlb_shootdown_queue_head +%= 1;

        defer self.tlb_shootdown_queue[self.tlb_shootdown_queue_head] = undefined;
        return self.tlb_shootdown_queue[self.tlb_shootdown_queue_head];
    }

    pub fn pushTlbShootdown(self: *@This(), owned_ptr: *caps.TlbShootdown) void {
        var backoff: abi.lock.Backoff = .{};

        while (true) {
            if (self.tryPushTlbShootdown(owned_ptr)) return;
            backoff.spin();
        }
    }

    pub fn tryPushTlbShootdown(self: *@This(), owned_ptr: *caps.TlbShootdown) bool {
        self.tlb_shootdown_queue_lock.lock();
        defer self.tlb_shootdown_queue_lock.unlock();

        if (self.tlb_shootdown_queue_len == self.tlb_shootdown_queue.len) return false;
        const idx = (self.tlb_shootdown_queue_head + self.tlb_shootdown_queue_len) % self.tlb_shootdown_queue.len;
        self.tlb_shootdown_queue[idx] = owned_ptr;
        self.tlb_shootdown_queue_len += 1;
        return true;
    }
};

//

export fn _start() callconv(.c) noreturn {
    arch.earlyInit();
    main();
}

pub fn main() noreturn {
    const log = std.log.scoped(.main);

    // crash if bootloader is unsupported
    if (!boot.base_revision.isSupported()) {
        log.err("bootloader unsupported", .{});
        arch.hcf();
    }

    const hhdm_response = boot.hhdm.response orelse {
        log.err("no HHDM", .{});
        arch.hcf();
    };
    hhdm_offset = hhdm_response.offset;

    log.info("kernel main", .{});
    log.info("zig version: {s}", .{builtin.zig_version_string});
    log.info("kernel version: 0.0.2{s}", .{if (builtin.is_test) "-testing" else ""});
    log.info("kernel git revision: {s}", .{comptime std.mem.trimRight(u8, @embedFile("git-rev"), "\n\r")});

    log.info("CPUID features: {}", .{arch.CpuFeatures.read()});

    log.info("initializing physical memory allocator", .{});
    pmem.init() catch |err| {
        std.debug.panic("failed to initialize PMM: {}", .{err});
    };

    volat(&all_cpu_locals).* = pmem.page_allocator.alloc(CpuLocalStorage, arch.cpuCount()) catch |err| {
        std.debug.panic("failed to CPU locals: {}", .{err});
    };
    for (all_cpu_locals) |*locals| locals.initialized.store(false, .release);

    // boot up a few processors
    arch.smpInit();

    // set up arch specific things: GDT, TSS, IDT, syscalls, ...
    const id = arch.nextCpuId();
    log.info("initializing CPU-{}", .{id});
    arch.initCpu(id, null) catch |err| {
        std.debug.panic("failed to initialize CPU-{}: {}", .{ id, err });
    };

    log.info("parsing kernel cmdline", .{});
    const a = args.parse() catch |err| {
        std.debug.panic("failed to parse kernel cmdline: {}", .{err});
    };

    // initialize ACPI specific things: APIC, HPET, ...
    log.info("initializing ACPI for CPU-{}", .{id});
    acpi.init() catch |err| {
        std.debug.panic("failed to initialize ACPI CPU-{}: {any}", .{ id, err });
    };

    // set things (like the global kernel address space) up for the capability system
    log.info("initializing caps", .{});
    caps.init() catch |err| {
        std.debug.panic("failed to initialize caps: {}", .{err});
    };

    if (builtin.is_test) {
        log.info("running tests", .{});
        const fail_count = @import("root").runTests();
        if (fail_count != 0) {
            log.err("{} test(s) failed", .{fail_count});
        }
    }

    // initialize and execute the root process
    log.info("initializing root", .{});
    init.exec(a) catch |err| {
        std.debug.panic("failed to set up root: {}", .{err});
    };

    log.info("entering user-space", .{});
    proc.enter();
}

// the actual _smpstart is in arch/x86_64.zig
pub fn smpmain(smpinfo: *boot.LimineMpInfo) noreturn {
    const log = std.log.scoped(.main);

    // boot up a few processors
    arch.smpInit();

    // set up arch specific things: GDT, TSS, IDT, syscalls, ...
    const id = arch.nextCpuId();
    log.info("initializing CPU-{}", .{id});
    arch.initCpu(id, smpinfo) catch |err| {
        std.debug.panic("failed to initialize CPU-{}: {}", .{ id, err });
    };

    // initialize ACPI specific things: APIC, HPET, ...
    log.info("initializing ACPI for CPU-{}", .{id});
    acpi.init() catch |err| {
        std.debug.panic("failed to initialize ACPI CPU-{}: {any}", .{ id, err });
    };

    log.info("entering user-space", .{});
    proc.enter();
}

test "trivial test" {
    try std.testing.expect(builtin.target.cpu.arch == .x86_64);
    try std.testing.expect(builtin.target.abi == .none);
}
