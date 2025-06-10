const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const limine = @import("limine");

const acpi = @import("acpi.zig");
const addr = @import("addr.zig");
const apic = @import("apic.zig");
const arch = @import("arch.zig");
const args = @import("args.zig");
const caps = @import("caps.zig");
const init = @import("init.zig");
const logs = @import("logs.zig");
const pmem = @import("pmem.zig");
const proc = @import("proc.zig");
const spin = @import("spin.zig");
const util = @import("util.zig");

//

const conf = abi.conf;
pub const std_options = logs.std_options;
pub const panic = logs.panic;
const Error = abi.sys.Error;

//

pub export var base_revision: limine.BaseRevision = .{ .revision = 2 };
pub export var hhdm: limine.HhdmRequest = .{};
pub var cpus_initialized: std.atomic.Value(usize) = .{ .raw = 0 };
pub var all_cpus_ininitalized: std.atomic.Value(bool) = .{ .raw = false };

pub var hhdm_offset: usize = 0xFFFF_8000_0000_0000;

pub const CpuLocalStorage = struct {
    // used to read the pointer to this struct through GS
    self_ptr: *CpuLocalStorage,

    cpu_config: arch.CpuConfig,

    current_thread: ?*caps.Thread = null,
    id: u32,
    lapic_id: u32,
    apic_regs: apic.ApicRegs = .{ .none = {} },

    // FIXME: remove notify caps from here
    interrupt_handlers: [apic.IRQ_AVAIL_COUNT]apic.Handler =
        .{apic.Handler{}} ** apic.IRQ_AVAIL_COUNT,

    epoch_locals: abi.epoch.Locals = .{},

    // TODO: arena allocator that forgets everything when the CPU enters the syscall handler
};

pub fn epoch_locals() *abi.epoch.Locals {
    return &arch.cpuLocal().epoch_locals;
}

pub const epoch_allocator: std.mem.Allocator = pmem.page_allocator;

//

export fn _start() callconv(.C) noreturn {
    arch.earlyInit();
    main();
}

pub fn main() noreturn {
    const log = std.log.scoped(.main);

    // crash if bootloader is unsupported
    if (!base_revision.is_supported()) {
        log.err("bootloader unsupported", .{});
        arch.hcf();
    }

    const hhdm_response = hhdm.response orelse {
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

    log.info("initializing DWARF info", .{});
    logs.init() catch |err| {
        std.debug.panic("failed to initialize DWARF info: {}", .{err});
    };

    // boot up a few processors
    arch.smpInit();

    // set up arch specific things: GDT, TSS, IDT, syscalls, ...
    const id = arch.nextCpuId();
    log.info("initializing CPU-{}", .{id});
    arch.initCpu(id, null) catch |err| {
        std.debug.panic("failed to initialize CPU-{}: {}", .{ id, err });
    };

    // initialize kernel object garbage collector
    abi.epoch.init_thread();

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
        @import("root").runTests() catch |err| {
            std.debug.panic("failed to run tests: {}", .{err});
        };
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
pub fn smpmain(smpinfo: *limine.SmpInfo) noreturn {
    const log = std.log.scoped(.main);

    // boot up a few processors
    arch.smpInit();

    // set up arch specific things: GDT, TSS, IDT, syscalls, ...
    const id = arch.nextCpuId();
    log.info("initializing CPU-{}", .{id});
    arch.initCpu(id, smpinfo) catch |err| {
        std.debug.panic("failed to initialize CPU-{}: {}", .{ id, err });
    };

    // initialize kernel object garbage collector
    abi.epoch.init_thread();

    // initialize ACPI specific things: APIC, HPET, ...
    log.info("initializing ACPI for CPU-{}", .{id});
    acpi.init() catch |err| {
        std.debug.panic("failed to initialize ACPI CPU-{}: {any}", .{ id, err });
    };

    log.info("entering user-space", .{});
    proc.enter();
}

var syscall_stats: std.EnumArray(abi.sys.Id, std.atomic.Value(usize)) = .initFill(.init(0));

pub fn syscall(trap: *arch.SyscallRegs) void {
    const log = std.log.scoped(.syscall);
    // log.info("syscall from cpu={} ip=0x{x} sp=0x{x}", .{ arch.cpuLocal().id, trap.user_instr_ptr, trap.user_stack_ptr });
    // defer log.info("syscall done", .{});

    // TODO: once every CPU has reached this, bootloader_reclaimable memory could be freed
    // just some few things need to be copied, but the page map(s) and stack(s) are already copied

    const id = std.meta.intToEnum(abi.sys.Id, trap.syscall_id) catch {
        @branchHint(.cold);
        log.warn("invalid syscall: {x}", .{trap.syscall_id});
        trap.syscall_id = abi.sys.encode(abi.sys.Error.InvalidSyscall);
        return;
    };

    const locals = arch.cpuLocal();
    const thread = locals.current_thread.?;

    if (conf.LOG_SYSCALLS and id != .selfYield)
        log.debug("syscall: {s}", .{@tagName(id)});
    defer if (conf.LOG_SYSCALLS and id != .selfYield)
        log.debug("syscall: {s} done", .{@tagName(id)});

    if (conf.LOG_SYSCALL_STATS) {
        _ = syscall_stats.getPtr(id).fetchAdd(1, .monotonic);

        log.debug("syscalls:", .{});
        var it = syscall_stats.iterator();
        while (it.next()) |e| {
            const v = e.value.load(.monotonic);
            log.debug(" - {}: {}", .{ e.key, v });
        }
    }

    handle_syscall(locals, thread, id, trap) catch |err| {
        @branchHint(.cold);
        trap.syscall_id = abi.sys.encode(err);
    };
}

fn handle_syscall(
    locals: *CpuLocalStorage,
    thread: *caps.Thread,
    id: abi.sys.Id,
    trap: *arch.SyscallRegs,
) Error!void {
    const log = std.log.scoped(.syscall);

    errdefer log.warn("syscall error {}", .{id});

    _ = locals;

    switch (id) {
        .log => {
            // FIXME: disable on release builds

            // log syscall
            if (trap.arg1 > 0x1000)
                return Error.InvalidArgument;

            _ = std.math.add(u64, trap.arg0, trap.arg1) catch
                return Error.InvalidArgument;

            const vaddr = try addr.Virt.fromUser(trap.arg0);

            var buf: [0x1000]u8 = undefined;
            try thread.proc.vmem.read(vaddr, buf[0..trap.arg1]);
            const msg = buf[0..trap.arg1];

            var lines = std.mem.splitAny(u8, msg, "\n\r");
            while (lines.next()) |line| {
                if (line.len == 0) {
                    continue;
                }
                _ = log.info("{s}", .{line});
            }

            trap.syscall_id = abi.sys.encode(0);
        },
        .kernel_panic => {
            if (!conf.KERNEL_PANIC_SYSCALL)
                return abi.sys.Error.InvalidSyscall;

            @panic("manual kernel panic");
        },

        .frame_create => {
            const size_bytes = trap.arg0;
            const frame = try caps.Frame.init(size_bytes);
            errdefer frame.deinit();

            const handle = try thread.proc.pushCapability(caps.Capability.init(frame));
            trap.syscall_id = abi.sys.encode(handle);
        },
        .frame_get_size => {
            const frame = try thread.proc.getObject(caps.Frame, @truncate(trap.arg0));
            defer frame.deinit();

            trap.syscall_id = abi.sys.encode(@as(u32, @intCast(frame.pages.len)));
        },
        .frame_read => {
            var vaddr = try addr.Virt.fromUser(trap.arg2);
            var bytes = trap.arg3;
            const frame = try thread.proc.getObject(caps.Frame, @truncate(trap.arg0));
            defer frame.deinit();
            var offset_bytes = trap.arg1;

            // TODO: direct copy, instead of double copy
            var buf: [0x1000]u8 = undefined;
            while (bytes != 0) {
                const limit = @min(0x1000, bytes);

                try frame.read(offset_bytes, buf[0..limit]);
                try thread.proc.vmem.write(vaddr, buf[0..limit]);

                vaddr.raw += limit;
                offset_bytes += limit;
                bytes -= limit;
            }

            trap.syscall_id = abi.sys.encode(0);
        },
        .frame_write => {
            var vaddr = try addr.Virt.fromUser(trap.arg2);
            var bytes = trap.arg3;
            const frame = try thread.proc.getObject(caps.Frame, @truncate(trap.arg0));
            defer frame.deinit();
            var offset_bytes = trap.arg1;

            // TODO: direct copy, instead of double copy
            var buf: [0x1000]u8 = undefined;
            while (bytes != 0) {
                const limit = @min(0x1000, bytes);

                try thread.proc.vmem.read(vaddr, buf[0..limit]);
                try frame.write(offset_bytes, buf[0..limit]);

                vaddr.raw += limit;
                offset_bytes += limit;
                bytes -= limit;
            }

            trap.syscall_id = abi.sys.encode(0);
        },

        .vmem_create => {
            const vmem = try caps.Vmem.init();
            errdefer vmem.deinit();

            const handle = try thread.proc.pushCapability(caps.Capability.init(vmem));
            trap.syscall_id = abi.sys.encode(handle);
        },
        .vmem_self => {
            const vmem_self = thread.proc.vmem.clone();
            errdefer vmem_self.deinit();

            const handle = try thread.proc.pushCapability(caps.Capability.init(vmem_self));
            trap.syscall_id = abi.sys.encode(handle);
        },
        .vmem_map => {
            const frame_first_page: u32 = @truncate(trap.arg2 / 0x1000);
            const vaddr = try addr.Virt.fromUser(trap.arg3);
            const vmem = try thread.proc.getObject(caps.Vmem, @truncate(trap.arg0));
            defer vmem.deinit();
            const frame = try thread.proc.getObject(caps.Frame, @truncate(trap.arg1));
            // map takes ownership of the frame
            const pages: u32 = if (trap.arg4 == 0)
                @intCast(@max(frame.pages.len, frame_first_page) - frame_first_page)
            else
                @truncate(std.math.divCeil(usize, trap.arg4, 0x1000) catch unreachable);
            const rights, const flags = abi.sys.unpackRightsFlags(@truncate(trap.arg5));

            // TODO: search, maybe
            const mapped_vaddr = try vmem.map(
                frame,
                frame_first_page,
                vaddr,
                pages,
                rights,
                flags,
            );

            std.debug.assert(mapped_vaddr.raw < 0x8000_0000_0000);
            trap.syscall_id = abi.sys.encode(mapped_vaddr.raw);
        },
        .vmem_unmap => {
            const pages: u32 = @truncate(std.math.divCeil(usize, trap.arg2, 0x1000) catch unreachable);
            if (pages == 0) {
                trap.syscall_id = abi.sys.encode(0);
                return;
            }
            const vaddr = try addr.Virt.fromUser(trap.arg1);
            const vmem = try thread.proc.getObject(caps.Vmem, @truncate(trap.arg0));
            defer vmem.deinit();

            try vmem.unmap(vaddr, pages);
            trap.syscall_id = abi.sys.encode(0);
        },
        .vmem_read => {
            var dst_vaddr = try addr.Virt.fromUser(trap.arg2);
            var src_vaddr = try addr.Virt.fromUser(trap.arg1);
            var bytes = trap.arg3;
            const vmem = try thread.proc.getObject(caps.Vmem, @truncate(trap.arg0));
            defer vmem.deinit();

            // TODO: direct copy, instead of double copy
            var buf: [0x1000]u8 = undefined;
            while (bytes != 0) {
                const limit = @min(0x1000, bytes);

                try vmem.read(src_vaddr, buf[0..limit]);
                try thread.proc.vmem.write(dst_vaddr, buf[0..limit]);

                src_vaddr.raw += limit;
                dst_vaddr.raw += limit;
                bytes -= limit;
            }

            trap.syscall_id = abi.sys.encode(0);
        },
        .vmem_write => {
            var src_vaddr = try addr.Virt.fromUser(trap.arg2);
            var dst_vaddr = try addr.Virt.fromUser(trap.arg1);
            var bytes = trap.arg3;
            const vmem = try thread.proc.getObject(caps.Vmem, @truncate(trap.arg0));
            defer vmem.deinit();

            // TODO: direct copy, instead of double copy
            var buf: [0x1000]u8 = undefined;
            while (bytes != 0) {
                const limit = @min(0x1000, bytes);

                try thread.proc.vmem.read(src_vaddr, buf[0..limit]);
                try vmem.write(dst_vaddr, buf[0..limit]);

                src_vaddr.raw += limit;
                dst_vaddr.raw += limit;
                bytes -= limit;
            }

            trap.syscall_id = abi.sys.encode(0);
        },

        .proc_create => {
            const from_vmem = try thread.proc.getObject(caps.Vmem, @truncate(trap.arg0));
            const new_proc = try caps.Process.init(from_vmem);
            errdefer new_proc.deinit();

            const handle = try thread.proc.pushCapability(caps.Capability.init(new_proc));
            trap.syscall_id = abi.sys.encode(handle);
        },
        .proc_self => {
            const proc_self = thread.proc.clone();
            errdefer proc_self.deinit();

            const handle = try thread.proc.pushCapability(caps.Capability.init(proc_self));
            trap.syscall_id = abi.sys.encode(handle);
        },
        .proc_give_cap => {
            const target_proc = try thread.proc.getObject(caps.Process, @truncate(trap.arg0));
            defer target_proc.deinit();

            const handle = try target_proc.pushCapability(.{});
            const cap = try thread.proc.takeCapability(@truncate(trap.arg1));
            const null_cap = target_proc.replaceCapability(handle, cap) catch unreachable;
            std.debug.assert(null_cap == null);

            trap.syscall_id = abi.sys.encode(handle);
        },

        .thread_create => {
            const from_proc = try thread.proc.getObject(caps.Process, @truncate(trap.arg0));
            const new_thread = try caps.Thread.init(from_proc);
            errdefer new_thread.deinit();

            const handle = try thread.proc.pushCapability(caps.Capability.init(new_thread));
            trap.syscall_id = abi.sys.encode(handle);
        },
        .thread_self => {
            const thread_self = thread.clone();
            errdefer thread_self.deinit();

            const handle = try thread.proc.pushCapability(caps.Capability.init(thread_self));
            trap.syscall_id = abi.sys.encode(handle);
        },
        .thread_read_regs => {
            const regs_ptr = try addr.Virt.fromUser(trap.arg1);
            const target_thread = try thread.proc.getObject(caps.Thread, @truncate(trap.arg0));
            defer target_thread.deinit();

            var regs: abi.sys.ThreadRegs = undefined;

            target_thread.lock.lock();
            regs = @bitCast(target_thread.trap);
            target_thread.lock.unlock();

            try thread.proc.vmem.write(regs_ptr, std.mem.asBytes(&regs));
            trap.syscall_id = abi.sys.encode(0);
        },
        .thread_write_regs => {
            const regs_ptr = try addr.Virt.fromUser(trap.arg1);
            const target_thread = try thread.proc.getObject(caps.Thread, @truncate(trap.arg0));
            defer target_thread.deinit();

            var regs: abi.sys.ThreadRegs = undefined;

            try thread.proc.vmem.read(regs_ptr, std.mem.asBytes(&regs));

            target_thread.lock.lock();
            target_thread.trap = @bitCast(regs);
            target_thread.lock.unlock();
            trap.syscall_id = abi.sys.encode(0);
        },
        .thread_start => {
            const target_thread = try thread.proc.getObject(caps.Thread, @truncate(trap.arg0));
            errdefer target_thread.deinit();

            {
                target_thread.lock.lock();
                defer target_thread.lock.unlock();
                if (target_thread.status != .stopped)
                    return Error.NotStopped;
            }

            if (conf.LOG_ENTRYPOINT_CODE) {
                // dump the entrypoint code
                var buf: [50]u8 = undefined;
                _ = target_thread.proc.vmem.read(addr.Virt.fromInt(target_thread.trap.user_instr_ptr), buf[0..]) catch {};
                var it = std.mem.window(u8, buf[0..], 16, 16);
                while (it.next()) |bytes| {
                    log.info("{}", .{util.hex(bytes)});
                }
            }

            try target_thread.proc.vmem.start();
            proc.start(target_thread);
            trap.syscall_id = abi.sys.encode(0);
        },
        .thread_stop => {
            const target_thread = try thread.proc.getObject(caps.Thread, @truncate(trap.arg0));
            defer target_thread.deinit();

            {
                target_thread.lock.lock();
                defer target_thread.lock.unlock();
                // FIXME: atomic status, because the scheduler might be reading/writing this
                if (target_thread.status == .stopped)
                    return Error.IsStopped;
            }

            proc.stop(target_thread);
            trap.syscall_id = abi.sys.encode(0);

            if (thread.status == .stopped) {
                proc.yield(trap);
            }
        },
        .thread_set_prio => {
            const target_thread = try thread.proc.getObject(caps.Thread, @truncate(trap.arg0));
            defer target_thread.deinit();

            target_thread.lock.lock();
            defer target_thread.lock.unlock();

            target_thread.priority = @truncate(trap.arg1);
            trap.syscall_id = abi.sys.encode(0);
        },

        .receiver_create => {
            const recv = try caps.Receiver.init();
            errdefer recv.deinit();

            const handle = try thread.proc.pushCapability(caps.Capability.init(recv));
            trap.syscall_id = abi.sys.encode(handle);
        },
        .receiver_recv => {
            const recv = try thread.proc.getObject(caps.Receiver, @truncate(trap.arg0));
            defer recv.deinit();

            trap.syscall_id = abi.sys.encode(0);
            try recv.recv(thread, trap);
        },
        .receiver_reply => {
            var msg = trap.readMessage();

            msg.cap_or_stamp = 0; // call doesnt get to know the Receiver capability id
            try caps.Receiver.reply(thread, msg);

            trap.syscall_id = abi.sys.encode(0);
        },
        .receiver_reply_recv => {
            @branchHint(.likely);
            var msg = trap.readMessage();

            const recv = try thread.proc.getObject(caps.Receiver, msg.cap_or_stamp);
            defer recv.deinit();

            msg.cap_or_stamp = 0; // call doesnt get to know the Receiver capability id
            try recv.replyRecv(thread, trap, msg);
        },

        .reply_create => {
            const reply = try caps.Reply.init(thread);
            errdefer reply.deinit();

            const handle = try thread.proc.pushCapability(caps.Capability.init(reply));
            trap.syscall_id = abi.sys.encode(handle);
        },
        .reply_reply => {
            var msg = trap.readMessage();

            const reply = try thread.proc.takeObject(caps.Reply, msg.cap_or_stamp);
            defer reply.deinit(); // destroys the object

            msg.cap_or_stamp = 0; // call doesnt get to know the Receiver capability id
            // the only error is allowed to destroy the object, so the defer deinit ↑ is fine
            try reply.reply(thread, msg);

            trap.syscall_id = abi.sys.encode(0);
        },

        .sender_create => {
            const recv = try thread.proc.getObject(caps.Receiver, @truncate(trap.arg0));
            defer recv.deinit();

            const sender = try caps.Sender.init(recv, @truncate(trap.arg1));
            const handle = try thread.proc.pushCapability(caps.Capability.init(sender));
            trap.syscall_id = abi.sys.encode(handle);
        },
        .sender_call => {
            @branchHint(.likely);
            var msg = trap.readMessage();
            trap.writeMessage(msg);

            const sender = try thread.proc.getObject(caps.Sender, @truncate(trap.arg0));
            defer sender.deinit();

            // log.info("set stamp={}", .{sender.stamp});

            msg.cap_or_stamp = sender.stamp;
            try sender.call(thread, trap, msg);
        },

        .notify_create => {
            const notify = try caps.Notify.init();
            errdefer notify.deinit();

            const handle = try thread.proc.pushCapability(caps.Capability.init(notify));
            trap.syscall_id = abi.sys.encode(handle);
        },
        .notify_wait => {
            const notify = try thread.proc.getObject(caps.Notify, @truncate(trap.arg0));
            defer notify.deinit();

            trap.syscall_id = abi.sys.encode(0);
            notify.wait(thread, trap);
        },
        .notify_poll => {
            const notify = try thread.proc.getObject(caps.Notify, @truncate(trap.arg0));
            defer notify.deinit();

            trap.syscall_id = abi.sys.encode(@intFromBool(notify.poll()));
        },
        .notify_notify => {
            const notify = try thread.proc.getObject(caps.Notify, @truncate(trap.arg0));
            defer notify.deinit();

            trap.syscall_id = abi.sys.encode(@intFromBool(notify.notify()));
        },

        .x86_ioport_create => {
            const allocator = try thread.proc.getObject(caps.X86IoPortAllocator, @truncate(trap.arg0));
            defer allocator.deinit();

            const ioport = try caps.X86IoPort.init(allocator, @truncate(trap.arg1));
            errdefer ioport.deinit();

            const handle = try thread.proc.pushCapability(caps.Capability.init(ioport));
            trap.syscall_id = abi.sys.encode(handle);
        },
        .x86_ioport_inb => {
            const ioport = try thread.proc.getObject(caps.X86IoPort, @truncate(trap.arg0));
            defer ioport.deinit();

            trap.syscall_id = abi.sys.encode(ioport.inb());
        },
        .x86_ioport_outb => {
            const ioport = try thread.proc.getObject(caps.X86IoPort, @truncate(trap.arg0));
            defer ioport.deinit();

            ioport.outb(@truncate(trap.arg1));
            trap.syscall_id = abi.sys.encode(0);
        },

        .x86_irq_create => {
            const allocator = try thread.proc.getObject(caps.X86IrqAllocator, @truncate(trap.arg0));
            defer allocator.deinit();

            const irq = try caps.X86Irq.init(allocator, @truncate(trap.arg1));
            errdefer irq.deinit();

            const handle = try thread.proc.pushCapability(caps.Capability.init(irq));
            trap.syscall_id = abi.sys.encode(handle);
        },
        .x86_irq_subscribe => {
            const irq = try thread.proc.getObject(caps.X86Irq, @truncate(trap.arg0));
            defer irq.deinit();

            const notify = try irq.subscribe();
            errdefer notify.deinit();

            const handle = try thread.proc.pushCapability(caps.Capability.init(notify));
            trap.syscall_id = abi.sys.encode(handle);
        },

        .handle_identify => {
            const cap = try thread.proc.getCapability(@truncate(trap.arg0));
            defer cap.deinit();

            trap.syscall_id = abi.sys.encode(@intFromEnum(cap.type));
        },
        .handle_duplicate => {
            const cap = try thread.proc.getCapability(@truncate(trap.arg0));
            errdefer cap.deinit();

            const handle = try thread.proc.pushCapability(cap);
            trap.syscall_id = abi.sys.encode(handle);
        },
        .handle_close => {
            const cap = try thread.proc.takeCapability(@truncate(trap.arg0));
            cap.deinit();

            trap.syscall_id = abi.sys.encode(0);
        },

        .selfYield => {
            proc.yield(trap);
        },
        .selfStop => {
            proc.stop(thread);
            proc.yield(trap);
        },
        .self_set_extra => {
            const idx: u7 = @truncate(trap.arg0);
            const val: u64 = @truncate(trap.arg1);
            const is_cap: bool = trap.arg2 != 0;

            if (is_cap) {
                const cap = try thread.proc.takeCapability(@truncate(val));

                thread.setExtra(
                    idx,
                    .{ .cap = caps.CapabilitySlot.init(cap) },
                );
            } else {
                thread.setExtra(
                    idx,
                    .{ .val = val },
                );
            }

            trap.syscall_id = abi.sys.encode(0);
        },
        .self_get_extra => {
            const idx: u7 = @truncate(trap.arg0);

            const data = thread.getExtra(idx);
            errdefer thread.setExtra(idx, data);

            switch (data) {
                .cap => |cap| {
                    const handle = try thread.proc.pushCapability(cap.unwrap().?);
                    trap.arg0 = handle;
                    trap.syscall_id = abi.sys.encode(1);
                },
                .val => |val| {
                    trap.arg0 = val;
                    trap.syscall_id = abi.sys.encode(0);
                },
            }
        },
    }
}

test "trivial test" {
    try std.testing.expect(builtin.target.cpu.arch == .x86_64);
    try std.testing.expect(builtin.target.abi == .none);
}
