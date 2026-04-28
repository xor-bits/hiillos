const std = @import("std");
const abi = @import("../lib.zig");

const Threaded = @This();

pub const InitOptions = struct {};

pub const init_single_threaded: Threaded = init: {
    // const env_block: process.Environ.Block = if (is_windows) .global else .empty;
    break :init .{
        // .allocator = .failing,
        // .stack_size = std.Thread.SpawnConfig.default_stack_size,
        // .async_limit = .nothing,
        // .cpu_count_error = null,
        // .concurrent_limit = .nothing,
        // .old_sig_io = undefined,
        // .old_sig_pipe = undefined,
        // .have_signal_handler = false,
        // .argv0 = .empty,
        // .environ_initialized = env_block.isEmpty(),
        // .environ = .{ .process_environ = .{ .block = env_block } },
        // .worker_threads = .init(null),
        // .disable_memory_mapping = false,
    };
};

var global_single_threaded_instance: Threaded = .init_single_threaded;
pub const global_single_threaded: *Threaded = &global_single_threaded_instance;

stderr_writer: std.Io.File.Writer = .{
    .io = undefined,
    .interface = std.Io.File.Writer.initInterface(&.{}),
    .file = .{
        .handle = 2,
        .flags = .{ .nonblocking = false },
    },
    .mode = .streaming,
},
stderr_mode: std.Io.Terminal.Mode = .no_color,
stderr_writer_initialized: bool = false,
stderr_mutex: std.Io.Mutex = .init,
// stderr_mutex_locker: std.Thread.Id = Thread.invalid_id,
// stderr_mutex_lock_count: usize = 0,

env: struct {
    NO_COLOR: bool = false,
    CLICOLOR_FORCE: bool = false,
} = .{},

pub fn init(
    gpa: std.mem.Allocator,
    options: InitOptions,
) Threaded {
    std.start;
    _ = gpa;
    _ = options;
}

fn scanEnv(
    self: *Threaded,
) void {
    var it = abi.process.envs();
    while (it.next()) |env_var| {
        if (std.mem.eql(u8, env_var.name, "NO_COLOR")) {
            self.env.NO_COLOR = true;
        } else if (std.mem.eql(u8, env_var.name, "CLICOLOR_FORCE")) {
            self.env.CLICOLOR_FORCE = true;
        }
    }
}

fn swapCancelProtection(
    userdata: ?*anyopaque,
    policy: std.Io.CancelProtection,
) std.Io.CancelProtection {
    const self: *Threaded = @ptrCast(@alignCast(userdata));
    _ = self;
    _ = policy;
    return .blocked;
}

fn futexWait(
    _: ?*anyopaque,
    addr: *const u32,
    expected: u32,
    timeout: std.Io.Timeout,
) error{Canceled}!void {
    // FIXME: futex timeouts
    _ = timeout;
    abi.sys.futexWait(addr, expected, .{
        .size = .bits32,
        .private = false,
    }) catch |err| std.debug.panic(
        "unhandled futexWait error: {}",
        .{err},
    );
}

fn futexWaitUncancelable(
    _: ?*anyopaque,
    addr: *const u32,
    expected: u32,
) void {
    abi.sys.futexWait(addr, expected, .{
        .size = .bits32,
        .private = false,
    }) catch |err| std.debug.panic(
        "unhandled futexWaitUncancelable error: {}",
        .{err},
    );
}

fn futexWake(
    _: ?*anyopaque,
    addr: *const u32,
    count: u32,
) void {
    abi.sys.futexWake(addr, count, .{
        .size = .bits32,
        .private = false,
    }) catch |err| std.debug.panic(
        "unhandled futexWake error: {}",
        .{err},
    );
}

fn lockStderr(
    userdata: ?*anyopaque,
    mode: ?std.Io.Terminal.Mode,
) error{Canceled}!std.Io.LockedStderr {
    const self: *Threaded = @ptrCast(@alignCast(userdata));

    try self.stderr_mutex.lock(self.io());
    errdefer self.stderr_mutex.unlock(self.io());

    if (!self.stderr_writer_initialized) {
        self.stderr_writer_initialized = true;
        self.stderr_writer.io = self.io();
        self.scanEnv();
        self.stderr_mode = mode orelse try .detect(
            self.io(),
            self.stderr_writer.file,
            self.env.NO_COLOR,
            self.env.CLICOLOR_FORCE,
        );
    }

    return .{
        .file_writer = &self.stderr_writer,
        .terminal_mode = mode orelse .no_color,
    };
}

fn unlockStderr(userdata: ?*anyopaque) void {
    const self: *Threaded = @ptrCast(@alignCast(userdata));
    self.stderr_mutex.unlock(self.io());
}

pub fn io(
    self: *Threaded,
) std.Io {
    return .{
        .userdata = self,
        .vtable = &.{
            .crashHandler = std.Io.noCrashHandler,

            .async = std.Io.noAsync,
            .concurrent = std.Io.failingConcurrent,
            .await = std.Io.unreachableAwait,
            .cancel = std.Io.unreachableCancel,

            .groupAsync = std.Io.noGroupAsync,
            .groupConcurrent = std.Io.failingGroupConcurrent,
            .groupAwait = std.Io.unreachableGroupAwait,
            .groupCancel = std.Io.unreachableGroupCancel,

            .recancel = std.Io.unreachableRecancel,
            .swapCancelProtection = swapCancelProtection,
            .checkCancel = std.Io.unreachableCheckCancel,

            .futexWait = futexWait,
            .futexWaitUncancelable = futexWaitUncancelable,
            .futexWake = futexWake,

            .operate = std.Io.failingOperate,
            .batchAwaitAsync = std.Io.unreachableBatchAwaitAsync,
            .batchAwaitConcurrent = std.Io.unreachableBatchAwaitConcurrent,
            .batchCancel = std.Io.unreachableBatchCancel,

            .dirCreateDir = std.Io.failingDirCreateDir,
            .dirCreateDirPath = std.Io.failingDirCreateDirPath,
            .dirCreateDirPathOpen = std.Io.failingDirCreateDirPathOpen,
            .dirOpenDir = std.Io.failingDirOpenDir,
            .dirStat = std.Io.failingDirStat,
            .dirStatFile = std.Io.failingDirStatFile,
            .dirAccess = std.Io.failingDirAccess,
            .dirCreateFile = std.Io.failingDirCreateFile,
            .dirCreateFileAtomic = std.Io.failingDirCreateFileAtomic,
            .dirOpenFile = std.Io.failingDirOpenFile,
            .dirClose = std.Io.unreachableDirClose,
            .dirRead = std.Io.noDirRead,
            .dirRealPath = std.Io.failingDirRealPath,
            .dirRealPathFile = std.Io.failingDirRealPathFile,
            .dirDeleteFile = std.Io.failingDirDeleteFile,
            .dirDeleteDir = std.Io.failingDirDeleteDir,
            .dirRename = std.Io.failingDirRename,
            .dirRenamePreserve = std.Io.failingDirRenamePreserve,
            .dirSymLink = std.Io.failingDirSymLink,
            .dirReadLink = std.Io.failingDirReadLink,
            .dirSetOwner = std.Io.failingDirSetOwner,
            .dirSetFileOwner = std.Io.failingDirSetFileOwner,
            .dirSetPermissions = std.Io.failingDirSetPermissions,
            .dirSetFilePermissions = std.Io.failingDirSetFilePermissions,
            .dirSetTimestamps = std.Io.noDirSetTimestamps,
            .dirHardLink = std.Io.failingDirHardLink,

            .fileStat = std.Io.failingFileStat,
            .fileLength = std.Io.failingFileLength,
            .fileClose = std.Io.unreachableFileClose,
            .fileWritePositional = std.Io.failingFileWritePositional,
            .fileWriteFileStreaming = std.Io.noFileWriteFileStreaming,
            .fileWriteFilePositional = std.Io.noFileWriteFilePositional,
            .fileReadPositional = std.Io.failingFileReadPositional,
            .fileSeekBy = std.Io.failingFileSeekBy,
            .fileSeekTo = std.Io.failingFileSeekTo,
            .fileSync = std.Io.failingFileSync,
            .fileIsTty = std.Io.unreachableFileIsTty,
            .fileEnableAnsiEscapeCodes = std.Io.unreachableFileEnableAnsiEscapeCodes,
            .fileSupportsAnsiEscapeCodes = std.Io.unreachableFileSupportsAnsiEscapeCodes,
            .fileSetLength = std.Io.failingFileSetLength,
            .fileSetOwner = std.Io.failingFileSetOwner,
            .fileSetPermissions = std.Io.failingFileSetPermissions,
            .fileSetTimestamps = std.Io.noFileSetTimestamps,
            .fileLock = std.Io.failingFileLock,
            .fileTryLock = std.Io.failingFileTryLock,
            .fileUnlock = std.Io.unreachableFileUnlock,
            .fileDowngradeLock = std.Io.failingFileDowngradeLock,
            .fileRealPath = std.Io.failingFileRealPath,
            .fileHardLink = std.Io.failingFileHardLink,

            .fileMemoryMapCreate = std.Io.failingFileMemoryMapCreate,
            .fileMemoryMapDestroy = std.Io.unreachableFileMemoryMapDestroy,
            .fileMemoryMapSetLength = std.Io.unreachableFileMemoryMapSetLength,
            .fileMemoryMapRead = std.Io.unreachableFileMemoryMapRead,
            .fileMemoryMapWrite = std.Io.unreachableFileMemoryMapWrite,

            .processExecutableOpen = std.Io.failingProcessExecutableOpen,
            .processExecutablePath = std.Io.failingProcessExecutablePath,
            .lockStderr = lockStderr,
            .tryLockStderr = std.Io.noTryLockStderr,
            .unlockStderr = std.Io.unreachableUnlockStderr,
            .processCurrentPath = std.Io.failingProcessCurrentPath,
            .processSetCurrentDir = std.Io.failingProcessSetCurrentDir,
            .processSetCurrentPath = std.Io.failingProcessSetCurrentPath,
            .processReplace = std.Io.failingProcessReplace,
            .processReplacePath = std.Io.failingProcessReplacePath,
            .processSpawn = std.Io.failingProcessSpawn,
            .processSpawnPath = std.Io.failingProcessSpawnPath,
            .childWait = std.Io.unreachableChildWait,
            .childKill = std.Io.unreachableChildKill,

            .progressParentFile = std.Io.failingProgressParentFile,

            .random = std.Io.noRandom,
            .randomSecure = std.Io.failingRandomSecure,

            .now = std.Io.noNow,
            .clockResolution = std.Io.failingClockResolution,
            .sleep = std.Io.noSleep,

            .netListenIp = std.Io.failingNetListenIp,
            .netAccept = std.Io.failingNetAccept,
            .netBindIp = std.Io.failingNetBindIp,
            .netConnectIp = std.Io.failingNetConnectIp,
            .netListenUnix = std.Io.failingNetListenUnix,
            .netConnectUnix = std.Io.failingNetConnectUnix,
            .netSocketCreatePair = std.Io.failingNetSocketCreatePair,
            .netSend = std.Io.failingNetSend,
            .netRead = std.Io.failingNetRead,
            .netWrite = std.Io.failingNetWrite,
            .netWriteFile = std.Io.failingNetWriteFile,
            .netClose = std.Io.unreachableNetClose,
            .netShutdown = std.Io.failingNetShutdown,
            .netInterfaceNameResolve = std.Io.failingNetInterfaceNameResolve,
            .netInterfaceName = std.Io.unreachableNetInterfaceName,
            .netLookup = std.Io.failingNetLookup,
        },
    };
}
