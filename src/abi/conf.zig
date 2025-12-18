const builtin = @import("builtin");
const config = @import("config");

// make these into zig build options

pub const ENABLE_FB_LOG: bool = config.fb_log;

pub const LOG_EVERYTHING: bool = false;
pub const LOG_STATS: bool = LOG_EVERYTHING or false;
pub const LOG_GENERIC: bool = LOG_EVERYTHING or false;
pub const LOG_USER: bool = LOG_EVERYTHING or false;

pub const LOG_SYSCALL_STATS: bool = LOG_STATS or false;
pub const LOG_OBJ_STATS: bool = LOG_STATS or false;
pub const LOG_SYSCALLS: bool = LOG_GENERIC or false;
pub const LOG_OBJ_CALLS: bool = LOG_GENERIC or false;
pub const LOG_CAP_CHANGES: bool = LOG_GENERIC or false;
pub const LOG_VMEM: bool = LOG_GENERIC or false;
pub const LOG_CTX_SWITCHES: bool = LOG_GENERIC or false;
pub const LOG_WAITING: bool = LOG_GENERIC or false;
pub const LOG_APIC: bool = LOG_GENERIC or false;
pub const LOG_INTERRUPTS: bool = LOG_GENERIC or false;
pub const LOG_EXCEPTIONS: bool = LOG_GENERIC or false;
pub const LOG_ENTRYPOINT_CODE: bool = LOG_GENERIC or false;
pub const LOG_PAGE_FAULTS: bool = LOG_GENERIC or false;
pub const LOG_FUTEX: bool = LOG_GENERIC or false;
pub const LOG_SERVERS: bool = LOG_USER or false;
pub const LOG_KEYS: bool = LOG_USER or false;

pub const KERNEL_PANIC_SYSCALL: bool = true;
pub const STACK_TRACE: bool = true;
pub const KERNEL_PANIC_RSOD: bool = true;
pub const KERNEL_PANIC_ON_USER_FAULT: bool = false;
pub const KERNEL_PANIC_SOURCE_INFO: bool = IS_DEBUG or false;
/// crash the kernel and provide a good stack trace if
/// some kernel object gets a high ref count (a likely ref leak)
pub const KERNEL_PANIC_ON_HIGH_REFCNT: usize = 0;
pub const ANTI_TLB_MODE: bool = false;
pub const NO_LAZY_REMAP: bool = false;
/// freeze the kernel when an unhandled user-space fault happens, for easier debugging with gdb
pub const DEBUG_UNHANDLED_FAULT: bool = false;
/// FIFO vs. FILO physical memory free lists
pub const CYCLE_PHYSICAL_MEMORY: bool = false;

pub const IPC_BENCHMARK: bool = false;
pub const IPC_BENCHMARK_PERFMON: bool = false;
pub const SCHED_STRESS_TEST: bool = false;
pub const FUTEX_STRESS_TEST: bool = false;

pub const IS_DEBUG = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
