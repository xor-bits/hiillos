const std = @import("std");
const abi = @import("abi");

const addr = @import("../addr.zig");
const apic = @import("../apic.zig");
const boot = @import("../boot.zig");
const call = @import("../call.zig");
const caps = @import("../caps.zig");
const logs = @import("../logs.zig");
const main = @import("../main.zig");
const pmem = @import("../pmem.zig");
const proc = @import("../proc.zig");

const log = std.log.scoped(.arch);
const conf = abi.conf;
const Error = abi.sys.Error;

//

pub const IA32_APIC_BASE: u32 = 0x1B;
pub const IA32_PAT_MSR: u32 = 0x277;
pub const IA32_X2APIC: u32 = 0x800; // the low MSR, goes from 0x800 to 0x8FF
pub const IA32_TCS_AUX: u32 = 0xC0000103;
pub const EFER: u32 = 0xC0000080;
pub const STAR: u32 = 0xC0000081;
pub const LSTAR: u32 = 0xC0000082;
pub const SFMASK: u32 = 0xC0000084;
pub const GS_BASE: u32 = 0xC0000101;
pub const KERNELGS_BASE: u32 = 0xC0000102;

pub const IA32_PERFEVTSEL0: u32 = 0x186;
pub const IA32_PMC0: u32 = 0xC1;
pub const IA32_FIXED_CTR_CTRL: u32 = 0x38d;
pub const IA32_PERF_GLOBAL_CTRL: u32 = 0x38f;
pub const MSR_K7_EVNTSEL0: u32 = 0xC0010000;
pub const MSR_K7_PERFCTR0: u32 = 0xC0010004;

//

var next: std.atomic.Value(usize) = .init(0);

//

pub fn earlyInit() void {
    // interrupts are always disabled in the kernel
    // there is just one exception to this:
    // waiting while the CPU is out of tasks
    //
    // initializing GDT also requires interrupts to be disabled
    ints.disable();

    // logging uses the GS register to print the cpu id
    // and the GS register contents might be undefined on boot
    // so quickly reset it to 0 temporarily
    wrmsr(GS_BASE, 0);
}

pub fn initCpu(id: u32, mp_info: ?*boot.LimineMpInfo) !void {
    const lapic_id = if (mp_info) |i|
        i.lapic_id
    else if (boot.mp.response) |resp|
        resp.bsp_lapic_id
    else
        0;

    const tls = &main.all_cpu_locals[id];
    tls.* = .{
        .self_ptr = tls,
        .cpu_config = undefined,
        .id = id,
        .lapic_id = @truncate(lapic_id),
        .pcid_lru = null,
        .initialized = .init(false),
    };
    std.debug.assert(std.mem.isAligned(@intFromPtr(tls), 0x1000));

    try CpuConfig.init(&tls.cpu_config, id);

    wrmsr(GS_BASE, @intFromPtr(tls));
    wrmsr(KERNELGS_BASE, 0);
    tls.initialized.store(true, .release);

    // the PAT MSR value is set so that the old modes stay the same
    // log.info("default PAT = 0x{x}", .{rdmsr(IA32_PAT_MSR)});
    wrmsr(IA32_PAT_MSR, abi.sys.CacheType.patMsr());
    // log.info("PAT = 0x{x}", .{abi.sys.CacheType.patMsr()});

    log.info("CPU vendor: {s}", .{CpuFeatures.readVendor()});

    const avail_features = CpuFeatures.read();
    // avail_features.assertExists(.acpi);
    // avail_features.assertExists(.apic);
    // avail_features.assertExists(.osxsave);
    // avail_features.assertExists(.xsave);
    // avail_features.assertExists(.pcid);
    avail_features.assertExists(.pat);
    // avail_features.assertExists(.rdrand);
    // avail_features.assertExists(.tsc_ecx);
    // avail_features.assertExists(.tsc_edx);
    // avail_features.assertExists(.x2apic);}

    if (avail_features.pcid) {
        // TODO: move all CR0/CR4 manipulation to initCpu (here)
        var cr4 = Cr4.read();
        cr4.pcid_enable = 1;
        cr4.write();

        tls.pcid_lru = try caps.PcidLru.init(pmem.page_allocator);
        tls.pcid_lru.?.lock.unlock();
    }

    if (conf.IPC_BENCHMARK) {
        PerfEvtSel.write();
    }
}

// launch 2 next processors (snowball)
pub fn smpInit() void {
    if (boot.mp.response) |resp| {
        var idx = next.fetchAdd(2, .monotonic);
        const cpus = resp.cpus();

        if (idx >= cpus.len) return;
        if (cpus[idx].lapic_id != resp.bsp_lapic_id)
            cpus[idx].goto_address.store(_smpstart, .release);

        idx += 1;
        if (idx >= resp.cpus().len) return;
        if (cpus[idx].lapic_id != resp.bsp_lapic_id)
            cpus[idx].goto_address.store(_smpstart, .release);
    }
}

fn _smpstart(smpinfo: *boot.LimineMpInfo) callconv(.c) noreturn {
    earlyInit();
    main.smpmain(smpinfo);
}

pub fn cpuLocal() *main.CpuLocalStorage {
    return asm volatile (std.fmt.comptimePrint(
            \\ movq %gs:{d}, %[cls]
        , .{@offsetOf(main.CpuLocalStorage, "self_ptr")})
        : [cls] "={rax}" (-> *main.CpuLocalStorage),
    );
}

pub fn cpuIdSafe() ?u32 {
    const gs = rdmsr(GS_BASE);
    if (gs == 0) return null;
    return cpuLocal().id;
}

pub fn cpuCount() u32 {
    return @intCast((boot.mp.response orelse return 1).cpu_count);
}

pub fn swapgs() void {
    asm volatile (
        \\ swapgs
    );
}

pub const ints = struct {
    pub inline fn disable() void {
        asm volatile (
            \\ cli
        );
    }

    // FIXME: idk how to disable red-zone in zig
    /// UB to enable interrupts in redzone context
    pub inline fn enable() void {
        asm volatile (
            \\ sti
        );
    }

    /// wait for the next interrupt
    pub fn wait() callconv(.c) void {
        // TODO: check held lock count before waiting, as as debug info
        asm volatile (
            \\ sti
            \\ hlt
            \\ cli
        );
    }

    pub inline fn int3() void {
        asm volatile (
            \\ int3
        );
    }
};

pub inline fn hcf() noreturn {
    while (true) {
        asm volatile (
            \\ cli
            \\ hlt
        );
    }
}

pub fn outb(port: u16, byte: u8) void {
    asm volatile (
        \\ outb %[byte], %[port]
        :
        : [byte] "{al}" (byte),
          [port] "N{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile (
        \\ inb %[port], %[byte]
        : [byte] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub fn ioWait() void {
    outb(0x80, 0);
}

pub fn lgdt(v: u64) void {
    asm volatile (
        \\ lgdtq (%[v])
        :
        : [v] "N{dx}" (v),
    );
}

pub fn lidt(v: u64) void {
    asm volatile (
        \\ lidtq (%[v])
        :
        : [v] "N{dx}" (v),
    );
}

pub fn ltr(v: u16) void {
    asm volatile (
        \\ ltr %[v]
        :
        : [v] "r" (v),
    );
}

pub fn setCs(sel: u64) void {
    asm volatile (
        \\ pushq %[v]
        \\ leaq .reload_CS(%rip), %rax
        \\ pushq %rax
        \\ lretq
        \\ .reload_CS:
        :
        : [v] "N{dx}" (sel),
        : .{ .rax = true });
}

pub fn setSs(sel: u16) void {
    asm volatile (
        \\ movw %[v], %ss
        :
        : [v] "r" (sel),
    );
}

pub fn setDs(sel: u16) void {
    asm volatile (
        \\ movw %[v], %ds
        :
        : [v] "r" (sel),
    );
}

pub fn setEs(sel: u16) void {
    asm volatile (
        \\ movw %[v], %es
        :
        : [v] "r" (sel),
    );
}

pub fn setFs(sel: u16) void {
    asm volatile (
        \\ movw %[v], %fs
        :
        : [v] "r" (sel),
    );
}

pub fn setGs(sel: u16) void {
    asm volatile (
        \\ movw %[v], %gs
        :
        : [v] "r" (sel),
    );
}

pub fn wrmsr(msr: u32, val: usize) void {
    const hi: u32 = @truncate(val >> 32);
    const lo: u32 = @truncate(val);

    asm volatile (
        \\ wrmsr
        :
        : [val_hi] "{edx}" (hi),
          [val_lo] "{eax}" (lo),
          [msr] "{ecx}" (msr),
          // : [byte] "={al}" (-> u8),
          // : [port] "N{dx}" (port),
    );
}

pub fn rdmsr(msr: u32) usize {
    var hi: u32 = undefined;
    var lo: u32 = undefined;

    asm volatile (
        \\ rdmsr
        : [val_hi] "={edx}" (hi),
          [val_lo] "={eax}" (lo),
        : [msr] "{ecx}" (msr),
    );

    const hi64: usize = @intCast(hi);
    const lo64: usize = @intCast(lo);

    return lo64 | (hi64 << 32);
}

pub fn rdpid() usize {
    return asm volatile (
        \\ rdpid %[pid]
        : [pid] "={rax}" (-> usize),
    );
}

pub const RdTscpRes = struct { counter: u64, pid: u32 };
pub fn rdtscp() RdTscpRes {
    var hi: u32 = undefined;
    var lo: u32 = undefined;
    var pid: u32 = undefined;

    asm volatile (
        \\ rdtscp
        : [counter_hi] "={edx}" (hi),
          [counter_lo] "={eax}" (lo),
          [pid] "={ecx}" (pid),
    );

    const hi64: usize = @intCast(hi);
    const lo64: usize = @intCast(lo);

    return .{
        .counter = lo64 | (hi64 << 32),
        .pid = pid,
    };
}

pub fn rdpmc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    const pmc: u32 = 0;
    asm volatile (
        \\rdpmc
        : [val_hi] "={edx}" (hi),
          [val_lo] "={eax}" (lo),
        : [pmc] "{ecx}" (pmc),
    );
    return @bitCast([2]u32{ lo, hi });
}

pub const Cpuid = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

/// cpuid instruction
pub fn cpuid(branch: u32, leaf: u32) Cpuid {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile (
        \\ cpuid
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [branch] "{eax}" (branch),
          [leaf] "{ecx}" (leaf),
    );
    return .{
        .eax = eax,
        .ebx = ebx,
        .ecx = ecx,
        .edx = edx,
    };
}

pub const CpuFeatures = packed struct {
    sse3: bool,
    pclmul: bool,
    dtes64: bool,
    monitor: bool,
    ds_cpl: bool,
    vmx: bool,
    smx: bool,
    est: bool,
    tm2: bool,
    ssse3: bool,
    cid: bool,
    sdbg: bool,
    fma: bool,
    cx16: bool,
    xtpr: bool,
    pdcm: bool,
    _reserved0: bool,
    pcid: bool,
    dca: bool,
    sse4_1: bool,
    sse4_2: bool,
    x2apic: bool,
    movbe: bool,
    popcnt: bool,
    tsc_ecx: bool,
    aes: bool,
    xsave: bool,
    osxsave: bool,
    avx: bool,
    f16c: bool,
    rdrand: bool,
    hypervisor: bool,
    fpu: bool,
    vme: bool,
    de: bool,
    pse: bool,
    tsc_edx: bool,
    msr: bool,
    pae: bool,
    mce: bool,
    cx8: bool,
    apic: bool,
    _reserved1: bool,
    sep: bool,
    mtrr: bool,
    pge: bool,
    mca: bool,
    cmov: bool,
    pat: bool,
    pse36: bool,
    psn: bool,
    clflush: bool,
    _reserved2: bool,
    ds: bool,
    acpi: bool,
    mmx: bool,
    fxsr: bool,
    sse: bool,
    sse2: bool,
    ss: bool,
    htt: bool,
    tm: bool,
    ia64: bool,
    pbe: bool,

    pub fn readVendor() [12]u8 {
        const result = cpuid(0, 0);
        return @bitCast([3]u32{ result.ebx, result.edx, result.ecx });
    }

    pub fn read() @This() {
        const result = cpuid(1, 0);
        return @bitCast([2]u32{ result.ecx, result.edx });
    }

    pub fn assertExists(self: @This(), name: @TypeOf(.enum_literal)) void {
        if (@field(self, @tagName(name))) {
            return;
        }
        log.err("missing CPU feature: {}", .{name});
        @panic("missing CPU features");
    }
};

pub const ArchitecturalPerformanceMonitoringLeaf = packed struct {
    version: u8,
    counters_per_cpu: u8,
    counter_bit_width: u8,
    ebx_length: u8,

    pub fn read() @This() {
        const result = cpuid(0x0A, 0);
        return @bitCast([1]u32{result.eax});
    }
};

pub fn wrcr3(sel: u64) void {
    asm volatile (
        \\ mov %[v], %cr3
        :
        : [v] "N{rdx}" (sel),
        : .{ .memory = true });
}

pub fn rdcr3() u64 {
    return asm volatile (
        \\ mov %cr3, %[v]
        : [v] "={rdx}" (-> u64),
    );
}

pub fn flushTlb() void {
    wrcr3(rdcr3());
}

pub fn flushTlbAddr(vaddr: usize) void {
    if (conf.ANTI_TLB_MODE) return flushTlb();

    asm volatile (
        \\ invlpg (%[v])
        :
        : [v] "r" (vaddr),
        : .{ .memory = true });
}

const InvPcidDesc = packed struct {
    pcid: u12 = 0,
    _: u52 = 0,
    addr: u64 = 0,
};

fn invpcid(kind: u64, desc: *const InvPcidDesc) void {
    asm volatile (
        \\ invpcid (%[desc]), %[kind]
        :
        : [kind] "r" (kind),
          [desc] "r" (desc),
        : .{ .memory = true });
}

pub fn flushTlbPcidAll() void {
    if (conf.ANTI_TLB_MODE) return flushTlb();

    const desc: InvPcidDesc = .{};
    invpcid(3, &desc);
}

pub fn flushTlbPcid(pcid: u12) void {
    if (conf.ANTI_TLB_MODE) return flushTlb();

    const desc: InvPcidDesc = .{ .pcid = pcid };
    invpcid(1, &desc);
}

pub fn flushTlbPcidAddr(vaddr: usize, pcid: u12) void {
    if (conf.ANTI_TLB_MODE) return flushTlb();

    const desc: InvPcidDesc = .{
        .pcid = pcid,
        .addr = vaddr,
    };
    invpcid(0, &desc);
}

/// processor ID
pub fn cpuId() u32 {
    return cpuLocal().id;
}

pub fn reset() void {
    log.info("triple fault reset", .{});
    ints.disable();
    // load 0 size IDT
    var idt = Idt.new();
    idt.load(0);
    // enable interrupts
    ints.enable();
    // and cause a triple fault if it hasn't already happened
    ints.int3();
}

pub const GdtDescriptor = packed struct {
    raw: u64 = 0,

    pub const Self = @This();

    pub fn new(raw: u64) Self {
        return .{ .raw = raw };
    }

    pub const accessed = new(1 << 40);
    pub const writable = new(1 << 41);
    pub const conforming = new(1 << 42);
    pub const executable = new(1 << 43);
    pub const user = new(1 << 44);
    pub const ring_3 = new(3 << 45);
    pub const present = new(1 << 47);

    pub const limit_0_15 = new(0xffff);
    pub const limit_16_19 = new(0xF << 48);

    pub const long_mode = new(1 << 53);
    pub const default_size = new(1 << 54);
    pub const granularity = new(1 << 55);

    pub const common = new(accessed.raw | writable.raw | present.raw | user.raw | limit_0_15.raw | limit_16_19.raw | granularity.raw);

    pub const kernel_data = new(common.raw | default_size.raw);
    pub const kernel_code = new(common.raw | executable.raw | long_mode.raw);
    pub const user_data = new(kernel_data.raw | ring_3.raw);
    pub const user_code = new(kernel_code.raw | ring_3.raw);

    pub const kernel_code_selector: u8 = (1 << 3);
    pub const kernel_data_selector: u8 = (2 << 3);
    pub const user_data_selector: u8 = (3 << 3) | 3;
    pub const user_code_selector: u8 = (4 << 3) | 3;

    pub const tss_selector: u8 = (5 << 3);

    pub fn tss(_tss: *const Tss) [2]Self {
        const tss_ptr: u64 = @intFromPtr(_tss);
        const limit: u16 = @truncate(@sizeOf(Tss) - 1);
        const base_0_23: u24 = @truncate(tss_ptr);
        const base_24_32: u8 = @truncate(tss_ptr >> 24);
        const low = present.raw | limit | (@as(u64, base_0_23) << 16) | (@as(u64, base_24_32) << 56) | (@as(u64, 0b1001) << 40);
        const high = tss_ptr >> 32;
        return .{
            .{ .raw = low },
            .{ .raw = high },
        };
    }
};

pub const DescriptorTablePtr = extern struct {
    _pad: [3]u16 = undefined,
    limit: u16,
    base: u64,
};

pub const Gdt = extern struct {
    ptr: DescriptorTablePtr,
    null_descriptor: GdtDescriptor = .{},
    descriptors: [6]GdtDescriptor,

    pub const Self = @This();

    pub fn new(tss: *const Tss) Self {
        return Self{
            .ptr = undefined,
            .descriptors = .{
                GdtDescriptor.kernel_code,
                GdtDescriptor.kernel_data,
                GdtDescriptor.user_data,
                GdtDescriptor.user_code,
            } ++
                GdtDescriptor.tss(tss),
        };
    }

    pub fn load(self: *Self) void {
        self.ptr = .{
            .base = @intFromPtr(&self.null_descriptor),
            .limit = 7 * @sizeOf(GdtDescriptor) - 1,
        };
        loadRaw(&self.ptr.limit);
    }

    fn loadRaw(ptr: *anyopaque) void {
        lgdt(@intFromPtr(ptr));
        setCs(GdtDescriptor.kernel_code_selector);
        setSs(GdtDescriptor.kernel_data_selector);
        setDs(GdtDescriptor.kernel_data_selector);
        setEs(GdtDescriptor.kernel_data_selector);
        setFs(GdtDescriptor.kernel_data_selector);
        setGs(GdtDescriptor.kernel_data_selector);
        ltr(GdtDescriptor.tss_selector);
    }
};

pub const Tss = extern struct {
    reserved0: u32 = 0,
    privilege_stacks: [3]u64 align(4) = std.mem.zeroes([3]u64),
    reserved1: u64 align(4) = 0,
    interrupt_stacks: [7]u64 align(4) = std.mem.zeroes([7]u64),
    reserved2: u64 align(4) = 0,
    reserved3: u16 = 0,
    iomap_base: u16 = @sizeOf(@This()), // no iomap base

    fn new() !@This() {
        const Stack = [0x8000]u8;

        var res = @This(){};

        var stack: *Stack = try pmem.page_allocator.create(Stack);
        res.privilege_stacks[0] = @sizeOf(Stack) + @intFromPtr(stack);
        stack = try pmem.page_allocator.create(Stack);
        res.privilege_stacks[1] = @sizeOf(Stack) + @intFromPtr(stack);
        stack = try pmem.page_allocator.create(Stack);
        res.interrupt_stacks[0] = @sizeOf(Stack) + @intFromPtr(stack);
        stack = try pmem.page_allocator.create(Stack);
        res.interrupt_stacks[1] = @sizeOf(Stack) + @intFromPtr(stack);

        return res;
    }
};

pub const PageFaultError = packed struct {
    /// page protection violation instead of a missing page
    page_protection: bool,
    caused_by_write: bool,
    user_mode: bool,
    malformed_table: bool,
    instruction_fetch: bool,
    protection_key: bool,
    shadow_stack: bool,
    _unused1: u8,
    sgx: bool,
    _unused2: u15,
    rmp: bool,
    _unused3: u32,
};

pub const Entry = packed struct {
    offset_0_15: u16,
    segment_selector: u16,
    interrupt_stack: u3,
    reserved2: u5 = 0,
    gate_type: u1,
    _1: u3 = 0b111,
    _0: u1 = 0,
    dpl: u2,
    present: u1,
    offset_16_31: u16,
    offset_32_63: u32,
    reserved1: u32 = 0,

    const Self = @This();

    pub fn new(int_handler: *const fn (
        *const InterruptStackFrame,
    ) callconv(.{ .x86_64_interrupt = .{} }) void) Self {
        const isr = @intFromPtr(int_handler);
        return Self.newAny(isr);
    }

    pub fn newWithEc(int_handler: *const fn (
        *const InterruptStackFrame,
        u64,
    ) callconv(.{ .x86_64_interrupt = .{} }) void) Self {
        const isr = @intFromPtr(int_handler);
        return Self.newAny(isr);
    }

    /// LLVM generated ISR
    pub fn generate(comptime handler: anytype) Self {
        const HandlerWrapper = struct {
            fn interrupt(
                interrupt_stack_frame: *const InterruptStackFrame,
            ) callconv(.{ .x86_64_interrupt = .{} }) void {
                const is_user = interrupt_stack_frame.code_segment_selector == @as(u16, GdtDescriptor.user_code_selector);
                if (is_user) swapgs();
                defer if (is_user) swapgs();

                handler.handler(interrupt_stack_frame);
            }
        };

        return Self.new(HandlerWrapper.interrupt);
    }

    /// LLVM generated ISR
    pub fn generateWithEc(comptime handler: anytype) Self {
        const HandlerWrapper = struct {
            fn interrupt(
                interrupt_stack_frame: *const InterruptStackFrame,
                ec: u64,
            ) callconv(.{ .x86_64_interrupt = .{} }) void {
                const is_user = interrupt_stack_frame.code_segment_selector == @as(u16, GdtDescriptor.user_code_selector);
                if (is_user) swapgs();
                defer if (is_user) swapgs();

                handler.handler(interrupt_stack_frame, ec);
            }
        };

        return Self.newWithEc(HandlerWrapper.interrupt);
    }

    /// custom ISR with `*arch.TrapRegs` support
    pub fn generateTrap(comptime handler: anytype) Self {
        const HandlerWrapper = struct {
            fn interrupt() callconv(.naked) noreturn {
                TrapRegs.isrEntry(true);

                asm volatile (
                    \\ call %[f:P]
                    :
                    : [f] "X" (&wrapper),
                );

                TrapRegs.exit();
            }

            fn wrapper(trap: *TrapRegs) callconv(.c) void {
                if (conf.IS_DEBUG and rdmsr(GS_BASE) < 0x8000_0000_0000) {
                    swapgs();
                    @panic("swapgs desync, kernel code should always run with the correct GS_BASE");
                }

                handler.handler(trap);
            }
        };

        return Self.newAny(@intFromPtr(&HandlerWrapper.interrupt));
    }

    /// custom ISR with `*arch.TrapRegs` support
    pub fn generateTrapWithEc(comptime handler: anytype) Self {
        const HandlerWrapper = struct {
            fn interrupt() callconv(.naked) noreturn {
                TrapRegs.isrEntry(false);

                asm volatile (
                    \\ call %[f:P]
                    :
                    : [f] "X" (&wrapper),
                );

                TrapRegs.exit();
            }

            fn wrapper(trap: *TrapRegs) callconv(.c) void {
                if (conf.IS_DEBUG and rdmsr(GS_BASE) < 0x8000_0000_0000) {
                    swapgs();
                    @panic("swapgs desync, kernel code should always run with the correct GS_BASE");
                }

                handler.handler(trap);
            }
        };

        return Self.newAny(@intFromPtr(&HandlerWrapper.interrupt));
    }

    fn newAny(isr: usize) Self {
        // log.info("interrupt at : {x}", .{isr});
        return Self{
            .offset_0_15 = @truncate(isr & 0xFFFF),
            .segment_selector = GdtDescriptor.kernel_code_selector,
            .interrupt_stack = 0,
            .gate_type = 0, // 0 for interrupt gate, 1 for trap gate
            .dpl = 0,
            .present = 1,
            .offset_16_31 = @truncate((isr >> 16) & 0xFFFF),
            .offset_32_63 = @truncate((isr >> 32) & 0xFFFFFFFF),
        };
    }

    fn missing() Self {
        return Self{
            .offset_0_15 = 0,
            .segment_selector = 0,
            .interrupt_stack = 0,
            .gate_type = 0,
            .dpl = 0,
            .present = 0,
            .offset_16_31 = 0,
            .offset_32_63 = 0,
        };
    }

    pub fn withStack(self: Self, stack: u3) Self {
        var s = self;
        s.interrupt_stack = stack;
        return s;
    }

    pub fn asInt(self: Self) u128 {
        return @bitCast(self);
    }
};

pub const Idt = extern struct {
    ptr: DescriptorTablePtr,
    entries: [256]u128,

    const Self = @This();

    pub fn new() Self {
        var entries = std.mem.zeroes([256]u128);

        // division error
        entries[0] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EXCEPTIONS) log.debug("division error interrupt", .{});

                log.err("division error\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // debug
        entries[1] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EXCEPTIONS) log.debug("debug interrupt", .{});

                log.err("debug\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // non-maskable interrupt
        entries[2] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EXCEPTIONS) log.debug("non-maskable interrupt", .{});

                log.info("non-maskable interrupt\nframe: {any}", .{interrupt_stack_frame});
            }
        }).asInt();
        // breakpoint
        entries[3] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EXCEPTIONS) log.debug("breakpoint interrupt", .{});

                log.info("breakpoint\nframe: {any}", .{interrupt_stack_frame});
            }
        }).asInt();
        // overflow
        entries[4] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EXCEPTIONS) log.debug("overflow interrupt", .{});

                log.err("overflow\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // bound range exceeded
        entries[5] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EXCEPTIONS) log.debug("bound range exceeded interrupt", .{});

                log.err("bound range exceeded\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // invalid opcode
        entries[6] = Entry.generateTrap(struct {
            fn handler(trap: *TrapRegs) void {
                if (conf.LOG_EXCEPTIONS) log.debug("invalid opcode interrupt", .{});

                if (!trap.isUser() or cpuLocal().current_thread == null) std.debug.panic(
                    \\invalid opcode
                    \\ - user: {any}
                    \\ - ip: 0x{x}
                    \\ - sp: 0x{x}
                    \\ - line:
                    \\{f}
                , .{
                    trap.isUser(),
                    trap.rip,
                    trap.rsp,
                    logs.Addr2Line{ .addr = trap.rip },
                });

                log.warn(
                    \\invalid opcode
                    \\ - user: true
                    \\ - ip: 0x{x}
                    \\ - sp: 0x{x}
                , .{
                    trap.rip,
                    trap.rsp,
                });

                while (conf.DEBUG_UNHANDLED_FAULT) {}

                const thread = cpuLocal().current_thread.?;
                thread.prev_status = thread.status;
                thread.status = .stopped;
                proc.switchFrom(trap, thread);
                proc.enter();
            }
        }).asInt();
        // device not available
        entries[7] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EXCEPTIONS) log.debug("device not available interrupt", .{});

                log.err("device not available\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // double fault
        entries[8] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_EXCEPTIONS) log.debug("double fault interrupt", .{});

                log.err("double fault (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // coprocessor segment overrun (useless)
        entries[9] = Entry.missing().asInt();
        // invalid tss
        entries[10] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_EXCEPTIONS) log.debug("invalid TSS interrupt", .{});

                log.err("invalid tss (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // segment not present
        entries[11] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_EXCEPTIONS) log.debug("segment not present interrupt", .{});

                log.err("segment not present (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // stack-segment fault
        entries[12] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_EXCEPTIONS) log.debug("stack-segment fault interrupt", .{});

                log.err("stack-segment fault (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // general protection fault
        entries[13] = Entry.generateTrapWithEc(struct {
            fn handler(trap: *TrapRegs) void {
                if (conf.LOG_EXCEPTIONS) log.debug("general protection fault interrupt", .{});

                if (!trap.isUser() or cpuLocal().current_thread == null) std.debug.panic(
                    \\unhandled general protection fault (0x{x})
                    \\ - user: {any}
                    \\ - ip: 0x{x}
                    \\ - sp: 0x{x}
                    \\ - line:
                    \\{f}
                , .{
                    trap.error_code,
                    trap.isUser(),
                    trap.rip,
                    trap.rsp,
                    logs.Addr2Line{ .addr = trap.rip },
                });

                log.warn(
                    \\general protection fault (0x{x})
                    \\ - user: true
                    \\ - ip: 0x{x}
                    \\ - sp: 0x{x}
                , .{
                    trap.error_code,
                    trap.rip,
                    trap.rsp,
                });

                while (conf.DEBUG_UNHANDLED_FAULT) {}

                const thread = cpuLocal().current_thread.?;
                thread.prev_status = thread.status;
                thread.status = .stopped;
                proc.switchFrom(trap, thread);
                proc.enter();
            }
        }).withStack(2).asInt();
        // page fault
        entries[14] = Entry.generateTrapWithEc(struct {
            fn handler(trap: *TrapRegs) void {
                const pfec: PageFaultError = @bitCast(trap.error_code);
                const target_addr = Cr2.read().page_fault_addr;

                if (conf.LOG_EXCEPTIONS) log.debug("page fault exception", .{});

                const caused_by: abi.sys.FaultCause = if (pfec.caused_by_write)
                    .write
                else if (pfec.instruction_fetch)
                    .exec
                else
                    .read;

                if (!pfec.user_mode or cpuLocal().current_thread == null) std.debug.panic(
                    \\unhandled page fault 0x{x}
                    \\ - thread: {*}
                    \\ - user: {any}
                    \\ - caused by write: {any}
                    \\ - instruction fetch: {any}
                    \\ - ip: 0x{x}
                    \\ - sp: 0x{x}
                    \\ - pfec: {}
                    \\ - line:
                    \\{f}
                , .{
                    target_addr,
                    cpuLocal().current_thread,
                    pfec.user_mode,
                    pfec.caused_by_write,
                    pfec.instruction_fetch,
                    trap.rip,
                    trap.rsp,
                    pfec,
                    logs.Addr2Line{ .addr = trap.rip },
                });

                // log.warn(
                //     \\page fault 0x{x}
                //     \\ - user: {any}
                //     \\ - caused by write: {any}
                //     \\ - instruction fetch: {any}
                //     \\ - ip: 0x{x}
                //     \\ - sp: 0x{x}
                //     \\ - pfec: {}
                // , .{
                //     target_addr,
                //     pfec.user_mode,
                //     pfec.caused_by_write,
                //     pfec.instruction_fetch,
                //     trap.rip,
                //     trap.rsp,
                //     pfec,
                // });

                const thread = cpuLocal().current_thread.?;

                const vaddr = addr.Virt.fromUser(target_addr) catch |err| {
                    thread.unhandledPageFault(
                        target_addr,
                        caused_by,
                        trap.rip,
                        trap.rsp,
                        err,
                        trap,
                    );
                    return;
                };

                thread.proc.vmem.pageFault(
                    caused_by,
                    vaddr,
                    trap,
                    thread,
                ) catch |err| switch (err) {
                    Error.Retry => proc.switchNow(trap),
                    else => thread.unhandledPageFault(
                        target_addr,
                        caused_by,
                        trap.rip,
                        trap.rsp,
                        err,
                        trap,
                    ),
                };
            }
        }).withStack(1).asInt();
        // reserved
        entries[15] = Entry.missing().asInt();
        // x87 fp exception
        entries[16] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EXCEPTIONS) log.debug("x87 fp exception interrupt", .{});

                log.err("x87 fp exception\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // alignment check
        entries[17] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_EXCEPTIONS) log.debug("alignment check interrupt", .{});

                log.err("alignment check (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // machine check
        entries[18] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EXCEPTIONS) log.debug("machine check interrupt", .{});

                log.err("machine check\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // simd fp exception
        entries[19] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EXCEPTIONS) log.debug("simd fp exception interrupt", .{});

                const mxcsr = MxCsr.read();
                log.err("simd fp exception: {}\nframe: {any}", .{ mxcsr, interrupt_stack_frame });
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // virtualization exception
        entries[20] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EXCEPTIONS) log.debug("virtualization exception interrupt", .{});

                log.err("virtualization exception\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // control protection exception
        entries[21] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_EXCEPTIONS) log.debug("control protection exception interrupt", .{});

                log.err("control protection exce (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled GPF", .{});
            }
        }).asInt();
        // reserved
        for (entries[22..27]) |*e| {
            e.* = Entry.missing().asInt();
        }
        // hypervisor injection exception
        entries[28] = Entry.generate(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame) void {
                if (conf.LOG_EXCEPTIONS) log.debug("hypervisor injection exception interrupt", .{});

                log.err("hypervisor injection exception\nframe: {any}", .{interrupt_stack_frame});
                std.debug.panic("unhandled CPU exception", .{});
            }
        }).asInt();
        // vmm communication exception
        entries[29] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_EXCEPTIONS) log.debug("vmm communication exception interrupt", .{});

                log.err("vmm communication excep (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled GPF", .{});
            }
        }).asInt();
        // security exception
        entries[30] = Entry.generateWithEc(struct {
            fn handler(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) void {
                if (conf.LOG_EXCEPTIONS) log.debug("security exception interrupt", .{});

                log.err("security exception (0x{x})\nframe: {any}", .{ ec, interrupt_stack_frame });
                std.debug.panic("unhandled GPF", .{});
            }
        }).asInt();
        // reserved
        entries[31] = Entry.missing().asInt();
        // triple fault, non catchable

        // spurious PIC interrupts
        for (entries[32..41]) |*entry| {
            entry.* = Entry.generate(struct {
                fn handler(_: *const InterruptStackFrame) void {}
            }).asInt();
        }

        entries[apic.IRQ_SPURIOUS] = Entry.generate(struct {
            fn handler(_: *const InterruptStackFrame) void {
                if (conf.LOG_INTERRUPTS) log.debug("APIC spurious interrupt", .{});

                apic.eoi();
            }
        }).asInt();
        entries[apic.IRQ_TIMER] = Entry.generateTrap(struct {
            fn handler(trap: *TrapRegs) void {
                if (conf.LOG_INTERRUPTS) log.debug("APIC timer interrupt", .{});

                if (trap.code_segment_selector == GdtDescriptor.user_code_selector) {
                    // only userspace can preempt
                    // log.debug("time slice preempt", .{});
                    proc.yield(trap);
                }

                apic.eoi();
            }
        }).asInt();
        entries[apic.IRQ_IPI_EOI] = Entry.generateTrap(struct {
            fn handler(_: *TrapRegs) void {
                if (conf.LOG_INTERRUPTS) log.debug("APIC IPI EOI interrupt", .{});

                apic.eoi();
                cpuLocal().lapic.ackIpi();
            }
        }).asInt();
        entries[apic.IRQ_IPI_PREEMPT] = Entry.generateTrap(struct {
            fn handler(trap: *TrapRegs) void {
                if (conf.LOG_INTERRUPTS) log.debug("APIC IPI interrupt", .{});

                if (trap.code_segment_selector == GdtDescriptor.user_code_selector) {
                    // only userspace can preempt
                    // log.debug("preempt", .{});
                    proc.yield(trap);
                }

                apic.eoi();
            }
        }).asInt();
        entries[apic.IRQ_IPI_PANIC] = Entry.generate(struct {
            fn handler(_: *const InterruptStackFrame) void {
                if (conf.LOG_INTERRUPTS) log.debug("kernel panic interrupt", .{});

                // log.err("CPU-{} done", .{cpuLocal().id});
                hcf();
            }
        }).asInt();
        entries[apic.IRQ_IPI_TLB_SHOOTDOWN] = Entry.generate(struct {
            fn handler(_: *const InterruptStackFrame) void {
                if (conf.LOG_INTERRUPTS) log.debug("TLB shootdown interrupt", .{});

                caps.TlbShootdown.flushAll();
                apic.eoi();
            }
        }).asInt();

        inline for (0..apic.IRQ_AVAIL_COUNT) |i| {
            entries[i + apic.IRQ_AVAIL_LOW] = Entry.generate(struct {
                pub fn handler(_: *const InterruptStackFrame) void {
                    if (conf.LOG_INTERRUPTS) log.debug("user-space {} interrupt", .{i});

                    // log.info("extra interrupt i=0x{x}", .{i + IRQ_AVAIL_LOW});

                    cpuLocal().lapic.inFlight(i + apic.IRQ_AVAIL_LOW);
                    // apic.eoi();

                    // no EOI as it is handled by userspace ACKs sent to caps.X86Irq
                }
            }).asInt();
        }

        return Self{
            .ptr = undefined,
            .entries = entries,
        };
    }

    pub fn load(self: *Self, size_override: ?u16) void {
        self.ptr = .{
            .base = @intFromPtr(&self.entries),
            .limit = size_override orelse (self.entries.len * @sizeOf(Entry) - 1),
        };
        loadRaw(&self.ptr.limit);
    }

    fn loadRaw(ptr: *anyopaque) void {
        lidt(@intFromPtr(ptr));
    }
};

fn interruptEc(interrupt_stack_frame: *const InterruptStackFrame, ec: u64) callconv(.Interrupt) void {
    log.err("default interrupt: {any} {any}", .{ interrupt_stack_frame, ec });
}

fn interrupt(interrupt_stack_frame: *const InterruptStackFrame) callconv(.Interrupt) void {
    log.err("default interrupt: {any} ", .{interrupt_stack_frame});
}

pub const CpuConfig = struct {
    // KernelGS:0 here
    rsp_kernel: u64,
    rsp_user: u64,

    gdt: Gdt,
    tss: Tss,
    idt: Idt,

    pub fn init(self: *@This(), id: u32) !void {
        self.tss = try Tss.new();
        self.gdt = Gdt.new(&self.tss);
        self.idt = Idt.new();

        // initialize GDT (, TSS) and IDT
        // log.debug("loading new GDT", .{});
        self.gdt.load();
        // log.debug("loading new IDT", .{});
        self.idt.load(null);
        // ints.enable();

        // enable/disable some features
        var cr0 = Cr0.read();
        cr0.emulate_coprocessor = 0;
        cr0.monitor_coprocessor = 1;
        cr0.task_switched = 0;
        cr0.write();
        log.debug("cr0={}", .{Cr0.read()});
        var cr4 = Cr4.read();
        cr4.osfxsr = 1;
        cr4.osxmmexcpt = 1;
        cr4.page_global_enable = 1;
        // cr4.machine_check_exception = 1;
        cr4.performance_monitoring_counter_enable = 1;
        cr4.write();
        log.debug("cr4={}", .{Cr4.read()});

        // // initialize CPU identification for scheduling purposes
        // wrmsr(IA32_TCS_AUX, this_cpu_id);
        // log.info("CPU ID set: {d}", .{cpuId()});

        self.rsp_kernel = self.tss.privilege_stacks[0];
        self.rsp_user = 0;

        // initialize syscall and sysret instructions
        wrmsr(
            STAR,
            (@as(u64, GdtDescriptor.user_data_selector - 8) << 48) |
                (@as(u64, GdtDescriptor.kernel_code_selector) << 32),
        );

        // RIP of the syscall jump destination
        wrmsr(LSTAR, @intFromPtr(&syscallHandlerWrapperWrapper));

        // bits that are 1 clear a bit from rflags when a syscall happens
        // setting interrupt_enable here disables interrupts on syscall
        wrmsr(SFMASK, @bitCast(Rflags{ .interrupt_enable = 1 }));

        const efer_flags: u64 = @bitCast(EferFlags{ .system_call_extensions = 1 });
        wrmsr(EFER, rdmsr(EFER) | efer_flags);
        log.info("syscalls initialized for CPU-{}", .{id});
    }
};

pub const Cr0 = packed struct {
    protected_mode_enable: u1,
    monitor_coprocessor: u1,
    emulate_coprocessor: u1,
    task_switched: u1,
    extension_type: u1,
    numeric_error: u1,
    reserved0: u10,
    write_protect: u1,
    reserved1: u1,
    alignment_mask: u1,
    reserved2: u10,
    not_write_through: u1,
    cache_disable: u1,
    paging: u1,
    reserved: u32,

    const Self = @This();

    pub fn write(val: Self) void {
        const v: u64 = @bitCast(val);
        asm volatile (
            \\ mov %[v], %cr0
            :
            : [v] "r" (v),
        );
    }

    pub fn read() Self {
        return @bitCast(asm volatile (
            \\mov %cr0, %[v]
            : [v] "={rax}" (-> u64),
        ));
    }
};

pub const Cr2 = packed struct {
    page_fault_addr: u64,

    const Self = @This();

    pub fn write(val: Self) void {
        const v: u64 = @bitCast(val);
        asm volatile (
            \\ mov %[v], %cr2
            :
            : [v] "r" (v),
        );
    }

    pub fn read() Self {
        return @bitCast(asm volatile (
            \\ mov %cr2, %[v]
            : [v] "={rax}" (-> u64),
        ));
    }
};

pub const Cr3 = packed struct {
    // reserved0: u3,
    // page_Level_write_through: u1,
    // page_level_cache_disable: u1,
    // reserved1: u7,
    pcid: u12 = 0,
    pml4_phys_base: u52 = 0,

    const Self = @This();

    pub fn write(val: Self) void {
        const v: u64 = @bitCast(val);
        asm volatile (
            \\ mov %[v], %cr3
            :
            : [v] "r" (v),
        );
    }

    pub fn read() Self {
        return @bitCast(asm volatile (
            \\ mov %cr3, %[v]
            : [v] "={rax}" (-> u64),
        ));
    }
};

pub const Cr4 = packed struct {
    virtual_8086_mode_extensions: u1,
    protected_mode_virtual_interrupts: u1,
    tsc_in_kernel_only: u1,
    debugging_extensions: u1,
    page_size_extension: u1,
    physical_address_extension: u1,
    machine_check_exception: u1,
    page_global_enable: u1,
    performance_monitoring_counter_enable: u1,
    osfxsr: u1,
    osxmmexcpt: u1,
    user_mode_instruction_prevention: u1,
    reserved0: u1,
    virtual_machine_extensions_enable: u1,
    safer_mode_extensions_enable: u1,
    reserved1: u1,
    fsgsbase: u1,
    pcid_enable: u1,
    osxsave_enable: u1,
    reserved2: u1,
    supervisor_mode_executions_protection_enable: u1,
    supervisor_mode_access_protection_enable: u1,
    protection_key_enable: u1,
    controlflow_enforcement_technology: u1,
    protection_keys_for_supervisor: u1,
    reserved3: u39,

    const Self = @This();

    pub fn write(val: Self) void {
        const v: u64 = @bitCast(val);
        asm volatile (
            \\ mov %[v], %cr4
            :
            : [v] "r" (v),
        );
    }

    pub fn read() Self {
        return @bitCast(asm volatile (
            \\ mov %cr4, %[v]
            : [v] "={rax}" (-> u64),
        ));
    }
};

pub const Rflags = packed struct {
    carry_flag: u1 = 0,
    reserved0: u1 = 1,
    parity_flag: u1 = 0,
    reserved1: u1 = 0,
    auxliary_carry_flag: u1 = 0,
    reserved2: u1 = 0,
    zero_flag: u1 = 0,
    sign_flag: u1 = 0,
    trap_flag: u1 = 0,
    interrupt_enable: u1 = 0,
    direction_flag: u1 = 0,
    overflow_flag: u1 = 0,
    io_privilege_flag: u2 = 0,
    nested_task: u1 = 0,
    reserved3: u1 = 0,
    resume_flag: u1 = 0,
    virtual_8086_mode: u1 = 0,
    alignment_check_or_access_control: u1 = 0,
    virtual_interrupt_flag: u1 = 0,
    virtual_interrupt_pending: u1 = 0,
    id_flag: u1 = 0,
    reserved4: u42 = 0,
};

pub const EferFlags = packed struct {
    system_call_extensions: u1 = 0,
    reserved: u63 = 0,
};

pub const InterruptStackFrame = extern struct {
    /// the instruction right after the instruction that caused this interrupt
    rip: u64,
    /// code privilege level before the interrupt
    code_segment_selector: u16,
    rflags: Rflags,
    /// stack pointer before the interrupt
    rsp: u64,
    /// stack(data) privilege level before the interrupt
    stack_segment_selector: u16,
};

pub const FxRegs = extern struct {
    fpu_control: u16 = 0,
    fpu_status: u16 = 0,
    fpu_tag: u8 = 0,
    _reserved0: u8 = 0,
    fpu_opcode: u16 = 0,
    fpu_instruction_pointer_offset: u64 = 0,
    fpu_data_pointer_offset: u64 = 0,
    mxcsr_mask: MxCsr = .{
        .invalid_operation_mask = true,
        .denormal_mask = true,
        .divide_by_zero_mask = true,
        .overflow_mask = true,
        .underflow_mask = true,
        .precision_mask = true,
    },
    mxcsr: MxCsr = .{
        .invalid_operation_mask = true,
        .denormal_mask = true,
        .divide_by_zero_mask = true,
        .overflow_mask = true,
        .underflow_mask = true,
        .precision_mask = true,
    },
    mmx_regs: [8]u128 = [_]u128{0} ** 8,
    xmm_regs: [16]u128 = [_]u128{0} ** 16,
    _reserved1: [3]u128 = [_]u128{0} ** 3,
    available: [3]u128 = [_]u128{0} ** 3,

    pub fn restore(self: *@This()) void {
        asm volatile (
            \\ fxrstor64 (%[v])
            :
            : [v] "r" (self),
        );
    }

    pub fn save(self: *@This()) void {
        return asm volatile (
            \\ fxsave64 (%[v])
            :
            : [v] "r" (self),
        );
    }
};

pub const MxCsr = packed struct {
    invalid_operation: bool = false,
    denormal: bool = false,
    divide_by_zero: bool = false,
    overflow: bool = false,
    underflow: bool = false,
    precision: bool = false,
    denormals_are_zeros: bool = false,
    invalid_operation_mask: bool = false,
    denormal_mask: bool = false,
    divide_by_zero_mask: bool = false,
    overflow_mask: bool = false,
    underflow_mask: bool = false,
    precision_mask: bool = false,
    rounding_control: enum(u2) {
        nearest,
        negative,
        positive,
        zero,
    } = .nearest,
    flush_to_zero: bool = false,
    _: u16 = 0,

    const Self = @This();

    pub fn write(val: Self) void {
        const v: u32 = @bitCast(val);
        asm volatile (
            \\ ldmxcsr (%[v])
            :
            : [v] "m" (v),
        );
    }

    pub fn read() Self {
        var val: u32 = undefined;
        asm volatile (
            \\ stmxcsr %[v]
            :
            : [v] "m" (&val),
        );
        return @bitCast(val);
    }
};

pub const TrapRegs = extern struct {
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    r11: u64 = 0,
    /// r10
    arg5: u64 = 0,
    /// r9
    arg4: u64 = 0,
    /// r8
    arg3: u64 = 0,
    rbp: u64 = 0,
    /// rsi
    arg1: u64 = 0,
    /// rdi
    arg0: u64 = 0,
    /// rdx
    arg2: u64 = 0,
    rcx: u64 = 0,
    rbx: u64 = 0,
    /// rax, also the return register
    syscall_id: u64 = 0,

    return_mode: enum(u64) {
        sysretq = 0,
        iretq = 1,
        _,
    } = .iretq,

    error_code: u64 = 0,

    // automatically pushed by the CPU on interrupt:

    /// the instruction right after the instruction that caused this interrupt
    /// rcx from syscalls
    rip: u64 = 0,
    /// code privilege level before the interrupt
    code_segment_selector: u16 = GdtDescriptor.user_code_selector,
    /// r11 from syscalls
    rflags: Rflags = Rflags{ .interrupt_enable = 1 },
    /// stack pointer before the interrupt
    rsp: u64 = 0,
    /// stack(data) privilege level before the interrupt
    stack_segment_selector: u16 = GdtDescriptor.user_data_selector,

    fn isUser(self: *const @This()) bool {
        return self.code_segment_selector == GdtDescriptor.user_code_selector;
    }

    pub fn readMessage(self: *const @This()) abi.sys.Message {
        return @bitCast([6]u64{
            self.arg0,
            self.arg1,
            self.arg2,
            self.arg3,
            self.arg4,
            self.arg5,
        });
    }

    pub fn writeMessage(self: *@This(), msg: abi.sys.Message) void {
        const regs: [6]u64 = @bitCast(msg);
        self.arg0 = regs[0];
        self.arg1 = regs[1];
        self.arg2 = regs[2];
        self.arg3 = regs[3];
        self.arg4 = regs[4];
        self.arg5 = regs[5];
    }

    pub inline fn isrEntry(comptime dummy_error_code: bool) void {
        if (dummy_error_code) asm volatile (
            \\ pushq $0
            ::: .{ .memory = true });

        asm volatile (std.fmt.comptimePrint(
                // return type: iretq
                \\ pushq $1
                // push all scratch + general purpose registers
                \\ pushq %rax
                \\ pushq %rbx
                \\ pushq %rcx
                \\ pushq %rdx
                \\ pushq %rdi
                \\ pushq %rsi
                \\ pushq %rbp
                \\ movq %rsp, %rbp
                \\ pushq %r8
                \\ pushq %r9
                \\ pushq %r10
                \\ pushq %r11
                \\ pushq %r12
                \\ pushq %r13
                \\ pushq %r14
                \\ pushq %r15
                // optional swapgs if coming from user-space
                \\ cmpq ${[user_code]d}, {[code]d}(%rsp)
                \\ jne 1f
                \\ swapgs
                \\ 1:
                // zero base pointer for zig
                // \\ xorq %rbp, %rbp
                // set up the *TrapRegs argument
                \\ movq %rsp, %rdi
            , .{
                .code = @offsetOf(@This(), "code_segment_selector"),
                .user_code = GdtDescriptor.user_code_selector,
            }) ::: .{ .memory = true });
    }

    pub inline fn syscallEntry() void {
        asm volatile (std.fmt.comptimePrint(
                // acquire the kernel stack without losing the user stack using KernelGS
                \\ swapgs
                \\ movq %rsp, %gs:{[rsp_user]d}
                \\ movq %gs:{[rsp_kernel]d}, %rsp
                // push a fake interrupt stack frame
                \\ pushq ${[user_data]d}
                \\ pushq %gs:{[rsp_user]d}
                \\ pushq %r11
                \\ pushq ${[user_code]d}
                \\ pushq %rcx
                // dummy error code
                \\ pushq $0
                // return type: sysretq
                \\ pushq $0
                // push all scratch + general purpose registers and dummy values where syscallq clobbered them
                \\ pushq %rax
                \\ pushq %rbx
                \\ pushq $0
                \\ pushq %rdx
                \\ pushq %rdi
                \\ pushq %rsi
                \\ pushq %rbp
                \\ movq %rsp, %rbp
                \\ pushq %r8
                \\ pushq %r9
                \\ pushq %r10
                \\ pushq $0
                \\ pushq %r12
                \\ pushq %r13
                \\ pushq %r14
                \\ pushq %r15
                // zero base pointer for zig
                // \\ xorq %rbp, %rbp
                // set up the *TrapRegs argument
                \\ movq %rsp, %rdi
            , .{
                .rsp_user = @offsetOf(main.CpuLocalStorage, "cpu_config") + @offsetOf(CpuConfig, "rsp_user"),
                .rsp_kernel = @offsetOf(main.CpuLocalStorage, "cpu_config") + @offsetOf(CpuConfig, "rsp_kernel"),
                .user_code = GdtDescriptor.user_code_selector,
                .user_data = GdtDescriptor.user_data_selector,
            }) ::: .{ .memory = true });
    }

    pub fn exitNow(trap: *const @This()) noreturn {
        // log.info("abnormal return to user-space, ctx={}", .{trap});

        asm volatile (""
            :
            : [trap] "{rsp}" (trap),
            : .{ .memory = true });

        exit();
        unreachable;
    }

    pub inline fn exit() void {
        if (comptime conf.ANTI_TLB_MODE) asm volatile (
            \\ movq %cr3, %rax
            \\ movq %rax, %cr3
        );

        asm volatile (std.fmt.comptimePrint(
                // push all scratch + general purpose registers
                \\ popq %r15
                \\ popq %r14
                \\ popq %r13
                \\ popq %r12
                \\ popq %r11
                \\ popq %r10
                \\ popq %r9
                \\ popq %r8
                \\ popq %rbp
                \\ popq %rsi
                \\ popq %rdi
                \\ popq %rdx
                \\ popq %rcx
                \\ popq %rbx
                // \\ popq %rax
                // \\ addq $8, %rsp
                // discard rax, the error code and the return mode
                \\ addq $24, %rsp
                // check which return method to use
                \\ movq -16(%rsp), %rax
                \\ testq %rax, %rax
                // now read rax again after its not needed anymore
                \\ movq -24(%rsp), %rax
                // ZF is now: sysretq => 1, iretq => 0
                // use the ZF set earlier to branch
                \\ jne 1f

                // sysretq return
                // decode the isf frame into a sysretq frame
                \\ popq %rcx
                \\ addq $8, %rsp
                \\ popq %r11
                \\ popq %gs:{[rsp_user]d}
                \\ movq %gs:{[rsp_user]d}, %rsp
                \\ swapgs
                // and finally the actual sysretq
                // FIXME: NMI,MCE interrupt race condition
                // (https://wiki.osdev.org/SYSENTER#Security_of_SYSRET)
                \\ sysretq
                \\ ud2
                \\ ud2
                \\ ud2

                // iretq return
                \\ 1:
                // optional swapgs if returning to user-space
                \\ cmpq ${[user_code]d}, 8(%rsp)
                \\ jne 2f
                \\ swapgs
                \\ 2:
                \\ iretq
                \\ ud2
                \\ ud2
                \\ ud2
            , .{
                // .return_mode = @offsetOf(@This(), "return_mode"),
                .rsp_user = @offsetOf(main.CpuLocalStorage, "cpu_config") + @offsetOf(CpuConfig, "rsp_user"),
                .user_code = GdtDescriptor.user_code_selector,
            }) ::: .{ .memory = true });
    }
};

fn syscallHandlerWrapperWrapper() callconv(.naked) noreturn {
    TrapRegs.syscallEntry();

    asm volatile (
        \\ call %[f:P]
        :
        : [f] "X" (&syscallHandlerWrapper),
    );

    TrapRegs.exit();
}

fn syscallHandlerWrapper(args: *TrapRegs) callconv(.c) void {
    if (conf.IS_DEBUG and rdmsr(GS_BASE) < 0x8000_0000_0000) {
        swapgs();
        @panic("swapgs desync, kernel code should always run with the correct GS_BASE");
    }

    call.syscall(args);
}

pub const PerfEvtSel = packed struct {
    event_select: enum(u8) {
        unhalted_core_cycles_intel = 0x3c,
        unhalted_core_cycles_amd = 0x76,
        _,
    },
    unit_mask: enum(u8) {
        unhalted_core_cycles = 0x00,
        _,
    } = .unhalted_core_cycles,
    user_mode: bool = true,
    kernel_mode: bool = true,
    edge_detect: bool = false,
    pin_control: bool = false,
    overflow_apic_interrupt_enable: bool = false,
    _pad0: bool = false,
    enable_counters: bool = true,
    invert_counter_mask: bool = false,
    counter_mask: u8 = 0,
    _pad1: u32 = 0,

    pub fn write() void {
        const is_amd = std.mem.eql(u8, &CpuFeatures.readVendor(), "AuthenticAMD");
        const version = ArchitecturalPerformanceMonitoringLeaf.read().version;

        const msr = if (is_amd and version <= 1)
            MSR_K7_EVNTSEL0
        else
            IA32_PERFEVTSEL0;

        const event_select: @FieldType(PerfEvtSel, "event_select") = if (is_amd)
            .unhalted_core_cycles_amd
        else
            .unhalted_core_cycles_intel;

        // log.debug("perfevtsel is_amd={} version={}", .{ is_amd, version });

        wrmsr(msr, @bitCast(PerfEvtSel{
            .event_select = event_select,
        }));

        if (!is_amd and version >= 2) {
            // wrmsr(IA32_FIXED_CTR_CTRL, @bitCast(FixedCtrCtrl{}));
            wrmsr(IA32_PERF_GLOBAL_CTRL, @bitCast(PerfGlobalCtrl{}));
        }
    }
};

const FixedCtrCtrl = packed struct {
    counter0_enable: enum(u2) {
        disable,
        kernel,
        user,
        all,
    } = .disable,
    _pad0: u1 = 0,
    counter0_overflow_interrupt: bool = false,
    counter1_enable: enum(u2) {
        disable,
        kernel,
        user,
        all,
    } = .disable,
    _pad1: u1 = 0,
    counter1_overflow_interrupt: bool = false,
    counter2_enable: enum(u2) {
        disable,
        kernel,
        user,
        all,
    } = .disable,
    _pad2: u1 = 0,
    counter2_overflow_interrupt: bool = false,
    _pad3: u52 = 0,
};

const PerfGlobalCtrl = packed struct {
    pmc0_enable: bool = true,
    pmc1_enable: bool = false,
    _pad0: u30 = 0,
    fixed_counter0_enable: bool = false,
    fixed_counter1_enable: bool = false,
    fixed_counter2_enable: bool = false,
    _pad1: u29 = 0,
};

test "structure sizes" {
    try std.testing.expectEqual(8, @sizeOf(GdtDescriptor));
    try std.testing.expectEqual(16, @sizeOf(Entry));
    try std.testing.expectEqual(8, @sizeOf(PageFaultError));
}
