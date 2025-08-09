const abi = @import("abi");
const std = @import("std");

const arch = @import("arch.zig");
const addr = @import("addr.zig");
const caps = @import("caps.zig");
const main = @import("main.zig");
const copy = @import("copy.zig");
const proc = @import("proc.zig");

const futex = @import("call/futex.zig");

const log = std.log.scoped(.call);
const conf = abi.conf;
const Error = abi.sys.Error;

var syscall_stats: std.EnumArray(abi.sys.Id, std.atomic.Value(usize)) = .initFill(.init(0));

//

pub fn syscall(trap: *arch.TrapRegs) void {
    defer std.debug.assert(arch.cpuLocal().current_thread != null);

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
        log.debug("syscall: {s} from {*}", .{ @tagName(id), thread });
    defer if (conf.LOG_SYSCALLS and id != .selfYield)
        log.debug("syscall: {s} done", .{@tagName(id)});

    if (conf.LOG_SYSCALL_STATS) {
        _ = syscall_stats.getPtr(id).fetchAdd(1, .monotonic);
    }

    if (conf.LOG_SYSCALL_STATS and id == .log) {
        log.debug("syscalls:", .{});
        var it = syscall_stats.iterator();
        while (it.next()) |e| {
            const v = e.value.load(.monotonic);
            log.debug(" - {}: {}", .{ e.key, v });
        }
    }

    handle_syscall(id, thread, trap) catch |err| {
        @branchHint(.cold);
        if (err != Error.Retry)
            log.warn("syscall error {}: {}", .{ id, err });
        trap.syscall_id = abi.sys.encode(err);
    };
}

fn handle_syscall(
    id: abi.sys.Id,
    thread: *caps.Thread,
    trap: *arch.TrapRegs,
) Error!void {
    switch (id) {
        .log => {
            // FIXME: disable on release builds

            const vaddr = try addr.Virt.fromUser(trap.arg0);

            // log syscall
            var len = trap.arg1;
            if (len > 0x1000)
                return Error.InvalidArgument;

            _ = std.math.add(u64, vaddr.raw, len) catch
                return Error.InvalidArgument;

            // log.debug("log of {} bytes from 0x{x}", .{
            //     len,
            //     vaddr.raw,
            // });

            var it = thread.proc.vmem.data(vaddr, false);
            defer it.deinit();

            var bytes: usize = 0;
            defer trap.arg0 = bytes;

            while (try it.next()) |chunk| {
                const limit = @min(len, chunk.len);
                len -= limit;
                bytes += limit;

                var lines = std.mem.splitAny(u8, @volatileCast(chunk[0..limit]), "\n\r");
                while (lines.next()) |line| {
                    if (line.len == 0) continue;
                    log.info("{s}", .{line});
                }

                if (len == 0) break;
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

            trap.syscall_id = abi.sys.encode(0);
            trap.arg0 = frame.size_bytes;
        },
        .frame_read => {
            const offset_bytes = trap.arg1;
            const vaddr = try addr.Virt.fromUser(trap.arg2);
            const bytes = trap.arg3;
            const frame = try thread.proc.getObject(caps.Frame, @truncate(trap.arg0));
            defer frame.deinit();

            var progress: usize = 0;
            defer trap.arg0 = progress;
            var dst = thread.proc.vmem.data(vaddr, true);
            defer dst.deinit();
            var src = frame.data(offset_bytes, false);
            defer src.deinit();

            try copy.tryInterAddressSpaceCopy(
                &src,
                &dst,
                bytes,
                &progress,
            );
            trap.syscall_id = abi.sys.encode(0);
        },
        .frame_write => {
            const offset_bytes = trap.arg1;
            const vaddr = try addr.Virt.fromUser(trap.arg2);
            const bytes = trap.arg3;
            const frame = try thread.proc.getObject(caps.Frame, @truncate(trap.arg0));
            defer frame.deinit();

            var progress: usize = 0;
            defer trap.arg0 = progress;
            var src = thread.proc.vmem.data(vaddr, false);
            defer src.deinit();
            var dst = frame.data(offset_bytes, true);
            defer dst.deinit();

            try copy.tryInterAddressSpaceCopy(
                &src,
                &dst,
                bytes,
                &progress,
            );
            trap.syscall_id = abi.sys.encode(0);
        },
        .frame_dummy_access => {
            const offset_byte = trap.arg1;
            const mode: abi.sys.FaultCause = std.meta.intToEnum(abi.sys.FaultCause, trap.arg2) catch {
                return Error.InvalidArgument;
            };
            const frame = try thread.proc.getObject(caps.Frame, @truncate(trap.arg0));
            defer frame.deinit();

            trap.syscall_id = abi.sys.encode(0);
            const res = frame.pageFault(
                @truncate(offset_byte / 0x1000),
                mode == .write,
                null,
                trap,
                thread,
            );
            if (res == Error.Retry) {
                proc.switchNow(trap);
            } else {
                _ = try res;
            }
        },
        .frame_dump => {
            const frame = try thread.proc.getObject(caps.Frame, @truncate(trap.arg0));
            defer frame.deinit();

            frame.lock.lock();
            defer frame.lock.unlock();

            log.info("frame: {*} is_transient={}", .{ frame, frame.is_transient });
            for (frame.pages) |p| {
                log.info(" - 0x{x}", .{p});
            }
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

            const mapped_vaddr = try vmem.map(
                frame,
                frame_first_page,
                vaddr,
                pages,
                rights,
                flags,
            );

            std.debug.assert(mapped_vaddr.raw < 0x8000_0000_0000);
            trap.syscall_id = abi.sys.encode(@truncate(mapped_vaddr.raw));
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

            trap.syscall_id = abi.sys.encode(0);
            vmem.unmap(
                trap,
                thread,
                vaddr,
                pages,
                false,
            ) catch |err| switch (err) {
                Error.Retry => proc.switchNow(trap),
                else => return err,
            };
        },
        .vmem_read => {
            const src_vaddr = try addr.Virt.fromUser(trap.arg1);
            const dst_vaddr = try addr.Virt.fromUser(trap.arg2);
            const bytes = trap.arg3;
            const vmem = try thread.proc.getObject(caps.Vmem, @truncate(trap.arg0));
            defer vmem.deinit();

            var progress: usize = 0;
            defer trap.arg0 = progress;
            var dst = vmem.data(dst_vaddr, true);
            defer dst.deinit();
            var src = thread.proc.vmem.data(src_vaddr, false);
            defer src.deinit();

            try copy.tryInterAddressSpaceCopy(
                &src,
                &dst,
                bytes,
                &progress,
            );
            trap.syscall_id = abi.sys.encode(0);
        },
        .vmem_write => {
            const dst_vaddr = try addr.Virt.fromUser(trap.arg1);
            const src_vaddr = try addr.Virt.fromUser(trap.arg2);
            const bytes = trap.arg3;
            const vmem = try thread.proc.getObject(caps.Vmem, @truncate(trap.arg0));
            defer vmem.deinit();

            var progress: usize = 0;
            defer trap.arg0 = progress;
            var dst = vmem.data(dst_vaddr, true);
            defer dst.deinit();
            var src = thread.proc.vmem.data(src_vaddr, false);
            defer src.deinit();

            try copy.tryInterAddressSpaceCopy(
                &src,
                &dst,
                bytes,
                &progress,
            );
            trap.syscall_id = abi.sys.encode(0);
        },
        .vmem_dummy_access => {
            const vaddr = try addr.Virt.fromUser(trap.arg1);
            const mode: abi.sys.FaultCause = std.meta.intToEnum(abi.sys.FaultCause, trap.arg2) catch {
                return Error.InvalidArgument;
            };
            const vmem = try thread.proc.getObject(caps.Vmem, @truncate(trap.arg0));
            defer vmem.deinit();

            trap.syscall_id = abi.sys.encode(0);
            const res = vmem.pageFault(
                mode,
                vaddr,
                trap,
                thread,
            );
            if (res == Error.Retry) {
                proc.switchNow(trap);
            } else {
                _ = try res;
            }
        },
        .vmem_dump => {
            const vmem = try thread.proc.getObject(caps.Vmem, @truncate(trap.arg0));
            defer vmem.deinit();

            vmem.lock.lock();
            defer vmem.lock.unlock();

            log.info("vmem: {*} cr3=0x{x}", .{ vmem, vmem.cr3 });
            for (vmem.mappings.items) |mapping| {
                log.info(" - [ 0x{x:0>16}..0x{x:0>16} ]: {*}", .{
                    mapping.getVaddr().raw,
                    mapping.getVaddr().raw + mapping.pages * 0x1000,
                    mapping.frame,
                });
            }
            log.info("halvmem", .{});
            try vmem.halPageTable().printMappings();
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

            const regs: abi.sys.ThreadRegs = target_thread.readRegs();
            var src = copy.SliceConst.fromSingle(&regs);
            defer src.deinit();
            var dst = thread.proc.vmem.data(regs_ptr, true);
            defer dst.deinit();

            var progress: usize = 0;
            try copy.tryInterAddressSpaceCopy(
                &src,
                &dst,
                @sizeOf(abi.sys.ThreadRegs),
                &progress,
            );
            trap.syscall_id = abi.sys.encode(0);
        },
        .thread_write_regs => {
            const regs_ptr = try addr.Virt.fromUser(trap.arg1);
            const target_thread = try thread.proc.getObject(caps.Thread, @truncate(trap.arg0));
            defer target_thread.deinit();

            var regs: abi.sys.ThreadRegs = undefined;
            var src = thread.proc.vmem.data(regs_ptr, false);
            defer src.deinit();
            var dst = copy.Slice.fromSingle(&regs);
            defer dst.deinit();

            var progress: usize = 0;
            try copy.tryInterAddressSpaceCopy(
                &src,
                &dst,
                @sizeOf(abi.sys.ThreadRegs),
                &progress,
            );
            target_thread.writeRegs(regs);
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
                var it = target_thread.proc.vmem.data(addr.Virt.fromInt(target_thread.trap.rip), false);
                defer it.deinit();

                log.info("{}", .{target_thread.trap});

                var len: usize = 200;
                while (it.next() catch null) |chunk| {
                    const limit = @min(len, chunk.len);
                    len -= limit;

                    log.info("{}", .{abi.util.hex(@volatileCast(chunk[0..limit]))});
                    if (len == 0) break;
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
                proc.switchNow(trap);
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
        .thread_wait => {
            const target_thread = try thread.proc.getObject(caps.Thread, @truncate(trap.arg0));
            defer target_thread.deinit();

            trap.syscall_id = abi.sys.encode(0);
            target_thread.waitExit(thread, trap);
        },
        .thread_set_sig_handler => {
            const target_thread = try thread.proc.getObject(caps.Thread, @truncate(trap.arg0));
            defer target_thread.deinit();

            target_thread.signal_handler = trap.arg1;
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
            sender.call(thread, trap, msg);
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
        .x86_irq_ack => {
            const irq = try thread.proc.getObject(caps.X86Irq, @truncate(trap.arg0));
            defer irq.deinit();

            try irq.ack();
            trap.syscall_id = abi.sys.encode(0);
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

        .futex_wait => try futex.wait(trap, thread),
        .futex_wake => try futex.wake(trap, thread),
        .futex_requeue => try futex.requeue(trap, thread),

        .self_yield => {
            proc.yield(trap);
        },
        .self_stop => {
            proc.switchFrom(trap, thread);
            thread.exit(trap.arg0);
            proc.switchNow(trap);
        },
        .self_dump => {
            log.info("selfDump: {}", .{trap.*});
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
        .self_get_signal => {
            const sig_ptr = try addr.Virt.fromUser(trap.arg0);

            const sig: abi.sys.Signal = thread.signal orelse return Error.NotMapped;
            var src = copy.SliceConst.fromSingle(&sig);
            defer src.deinit();
            var dst = thread.proc.vmem.data(sig_ptr, true);
            defer dst.deinit();

            var progress: usize = 0;
            try copy.tryInterAddressSpaceCopy(
                &src,
                &dst,
                @sizeOf(abi.sys.Signal),
                &progress,
            );

            thread.signal = null;
            trap.syscall_id = abi.sys.encode(0);
        },
    }
}
