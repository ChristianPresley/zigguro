//! Linux crash-path primitives (E17.F05.S01.T02): raw syscalls, the
//! `/proc/self/maps` parser, build ids read from memory and the thread list.
//!
//! Functions named `cp_*` run inside signal handlers. They use only the
//! syscalls in `crash_path_syscalls`, never allocate, never touch `std.Io`
//! or `std.log`, and call only other `cp_*` functions (checked by the
//! "crash path: syscall allowlist" test in capture.zig).

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const format = @import("format.zig");
const capture = @import("capture.zig");
const linux = std.os.linux;
const CpuContextPtr = std.debug.CpuContextPtr;
const Native = std.debug.cpu_context.Native;

/// The only `std.os.linux` functions a `cp_*` function may call. All are
/// async-signal-safe (signal-safety(7)); `sigaction` and `sigprocmask`
/// re-raise a fault signal with its default action, and `exit_group`
/// gives up on a stuck writer.
pub const crash_path_syscalls = [_][]const u8{
    "openat",        "write",       "read",       "fsync",  "close",
    "clock_gettime", "getpid",      "gettid",     "tgkill", "sched_yield",
    "getdents64",    "sigprocmask", "exit_group", "errno",  "sigemptyset",
    "sigaddset",     "sigaction",
};

/// Exit status used when a second crashing thread gives up waiting.
pub const stuck_exit_status = 134;

fn cp_ok(rc: usize) bool {
    return linux.errno(rc) == .SUCCESS;
}

/// `openat`, retrying on EINTR; null on failure.
pub fn cp_open(dirfd: i32, path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) ?i32 {
    while (true) {
        const rc = linux.openat(dirfd, path, flags, mode);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return null,
        }
    }
}

/// Opens `path` under `dirfd` read-only.
pub fn cp_openRead(dirfd: i32, path: [*:0]const u8) ?i32 {
    return cp_open(dirfd, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
}

pub fn cp_close(fd: i32) void {
    _ = linux.close(fd);
}

/// Writes all of `bytes`, handling EINTR and short writes.
pub fn cp_writeAll(fd: i32, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
                off += rc;
            },
            .INTR => {},
            else => return false,
        }
    }
    return true;
}

pub fn cp_fsync(fd: i32) void {
    _ = linux.fsync(fd);
}

/// Reads until `buf` is full, end of file or an error; returns the length.
pub fn cp_readUpTo(fd: i32, buf: []u8) usize {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.read(fd, buf[off..].ptr, buf.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                off += rc;
            },
            .INTR => {},
            else => break,
        }
    }
    return off;
}

/// Reads `path` (under `dirfd`) into `buf`, truncating; empty on failure.
pub fn cp_readFile(dirfd: i32, path: [*:0]const u8, buf: []u8) []u8 {
    const fd = cp_openRead(dirfd, path) orelse return buf[0..0];
    defer cp_close(fd);
    return buf[0..cp_readUpTo(fd, buf)];
}

/// Wall-clock time in Unix milliseconds (vDSO `clock_gettime`).
pub fn cp_nowMs() i64 {
    var ts: linux.timespec = undefined;
    if (!cp_ok(linux.clock_gettime(.REALTIME, &ts))) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Monotonic time in milliseconds.
pub fn cp_monoMs() i64 {
    var ts: linux.timespec = undefined;
    if (!cp_ok(linux.clock_gettime(.MONOTONIC, &ts))) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

pub fn cp_pid() u32 {
    return @bitCast(linux.getpid());
}

pub fn cp_tid() u32 {
    return @bitCast(linux.gettid());
}

pub fn cp_yield() void {
    _ = linux.sched_yield();
}

pub fn cp_exit(status: i32) noreturn {
    linux.exit_group(status);
}

/// Restores the default action for `sig`, sends it to the calling thread
/// and unblocks it, so it terminates the process with its own status
/// right away (or when the current handler returns).
pub fn cp_reraise(sig: linux.SIG) void {
    const dfl: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(sig, &dfl, null);
    _ = linux.tgkill(linux.getpid(), linux.gettid(), sig);
    var set = linux.sigemptyset();
    linux.sigaddset(&set, sig);
    _ = linux.sigprocmask(linux.SIG.UNBLOCK, &set, null);
}

// ---------------------------------------------------------------------------
// /proc/self/maps

/// One `/proc/self/maps` line.
pub const MapEntry = struct {
    start: usize,
    end: usize,
    offset: u64,
    readable: bool,
    exec: bool,
    /// File path, `[vdso]`-style pseudo name or empty. A ` (deleted)`
    /// suffix is removed.
    path: []const u8,
};

fn cp_hex(s: []const u8) ?u64 {
    if (s.len == 0 or s.len > 16) return null;
    var v: u64 = 0;
    for (s) |c| {
        const d: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        v = (v << 4) | d;
    }
    return v;
}

fn cp_field(line: []const u8, pos: *usize) []const u8 {
    while (pos.* < line.len and line[pos.*] == ' ') pos.* += 1;
    const start = pos.*;
    while (pos.* < line.len and line[pos.*] != ' ') pos.* += 1;
    return line[start..pos.*];
}

/// Parses `start-end perms offset dev inode [path]` (proc_pid_maps(5)).
pub fn cp_parseMapsLine(line: []const u8) ?MapEntry {
    var pos: usize = 0;
    const range = cp_field(line, &pos);
    const perms = cp_field(line, &pos);
    const offset = cp_field(line, &pos);
    _ = cp_field(line, &pos); // dev
    const inode = cp_field(line, &pos);
    if (inode.len == 0 or perms.len < 4) return null;
    const dash = std.mem.indexOfScalar(u8, range, '-') orelse return null;
    const start = cp_hex(range[0..dash]) orelse return null;
    const end = cp_hex(range[dash + 1 ..]) orelse return null;
    if (end <= start) return null;
    while (pos < line.len and line[pos] == ' ') pos += 1;
    var path = line[pos..];
    const deleted = " (deleted)";
    if (std.mem.endsWith(u8, path, deleted)) path = path[0 .. path.len - deleted.len];
    return .{
        .start = @intCast(start),
        .end = @intCast(end),
        .offset = cp_hex(offset) orelse return null,
        .readable = perms[0] == 'r',
        .exec = perms[2] == 'x',
        .path = path,
    };
}

/// Line cursor over maps text.
pub const MapsCursor = struct {
    text: []const u8,
    pos: usize = 0,
};

/// The next parsable line, skipping malformed ones (and a final line cut
/// off by the read buffer).
pub fn cp_nextMap(c: *MapsCursor) ?MapEntry {
    while (c.pos < c.text.len) {
        const nl = std.mem.indexOfScalarPos(u8, c.text, c.pos, '\n') orelse {
            c.pos = c.text.len;
            return null;
        };
        const line = c.text[c.pos..nl];
        c.pos = nl + 1;
        if (cp_parseMapsLine(line)) |e| return e;
    }
    return null;
}

/// The mapping that contains `addr`.
pub fn cp_findMapping(maps: []const u8, addr: usize) ?MapEntry {
    var c: MapsCursor = .{ .text = maps };
    while (cp_nextMap(&c)) |e| if (addr >= e.start and addr < e.end) return e;
    return null;
}

pub const max_build_id_len = 64;

/// A loaded module assembled from its mappings.
pub const ModuleSlot = struct {
    path: []const u8,
    /// Lowest start of an offset-0 mapping (or the first mapping).
    base: usize,
    end: usize,
    /// End of the mapping that starts at `base` (where the ELF header is).
    base_map_end: usize,
    base_readable: bool,
    have_base: bool,
    id_len: u8 = 0,
    id: [max_build_id_len]u8 = undefined,

    pub fn buildId(m: *const ModuleSlot) []const u8 {
        return m.id[0..m.id_len];
    }
};

fn cp_isModulePath(path: []const u8) bool {
    return (path.len > 0 and path[0] == '/') or std.mem.eql(u8, path, "[vdso]");
}

/// Groups file-backed mappings (and `[vdso]`) by path into `out`; returns
/// the count. Paths point into `maps`.
pub fn cp_collectModules(maps: []const u8, out: []ModuleSlot) usize {
    var n: usize = 0;
    var c: MapsCursor = .{ .text = maps };
    outer: while (cp_nextMap(&c)) |e| {
        if (!cp_isModulePath(e.path)) continue;
        for (out[0..n]) |*m| {
            if (!std.mem.eql(u8, m.path, e.path)) continue;
            if (e.offset == 0 and (!m.have_base or e.start < m.base)) {
                m.base = e.start;
                m.base_map_end = e.end;
                m.base_readable = e.readable;
                m.have_base = true;
            }
            m.end = @max(m.end, e.end);
            continue :outer;
        }
        if (n == out.len) continue;
        out[n] = .{
            .path = e.path,
            .base = e.start,
            .end = e.end,
            .base_map_end = e.end,
            .base_readable = e.readable,
            .have_base = e.offset == 0,
        };
        n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// ELF build ids

const NT_GNU_BUILD_ID = 3;
const PT_LOAD = 1;
const PT_NOTE = 4;
const ehdr_size = 64;
const phdr_size = 56;

fn cp_rd(comptime T: type, bytes: []const u8, off: usize) T {
    return std.mem.readInt(T, bytes[off..][0..@sizeOf(T)], .little);
}

/// Finds the GNU build id in a run of ELF notes.
pub fn cp_findGnuBuildId(notes: []const u8) ?[]const u8 {
    var off: usize = 0;
    while (notes.len - off >= 12) {
        const namesz = cp_rd(u32, notes, off);
        const descsz = cp_rd(u32, notes, off + 4);
        const ntype = cp_rd(u32, notes, off + 8);
        const name_off = off + 12;
        const desc_off = name_off + std.mem.alignForward(usize, namesz, 4);
        const next = desc_off + std.mem.alignForward(usize, descsz, 4);
        if (namesz > notes.len or descsz > notes.len or next > notes.len) return null;
        if (ntype == NT_GNU_BUILD_ID and namesz == 4 and std.mem.eql(u8, notes[name_off..][0..4], "GNU\x00")) {
            if (descsz == 0 or descsz > max_build_id_len) return null;
            return notes[desc_off..][0..descsz];
        }
        off = next;
    }
    return null;
}

fn cp_isElf64(ehdr: []const u8) bool {
    return ehdr.len >= ehdr_size and std.mem.eql(u8, ehdr[0..4], "\x7fELF") and ehdr[4] == 2 and ehdr[5] == 1;
}

/// Reads the build id of the ELF image mapped at `base`, touching only
/// `[base, base_map_end)`: the header, program headers and notes must lie
/// in that first mapping, which holds them for every usual linker layout.
pub fn cp_buildIdFromMemory(base: usize, base_map_end: usize) ?[]const u8 {
    if (base_map_end <= base or base_map_end - base < ehdr_size) return null;
    const image: []const u8 = @as([*]const u8, @ptrFromInt(base))[0 .. base_map_end - base];
    if (!cp_isElf64(image)) return null;
    const phoff = cp_rd(u64, image, 32);
    const phentsize = cp_rd(u16, image, 54);
    const phnum = cp_rd(u16, image, 56);
    if (phentsize < phdr_size or phoff > image.len or @as(u64, phnum) * phentsize > image.len - phoff) return null;
    // Load bias: base minus the page-aligned vaddr of the first PT_LOAD.
    var bias: ?usize = null;
    for (0..phnum) |i| {
        const ph = image[@intCast(phoff + i * phentsize)..][0..phdr_size];
        if (cp_rd(u32, ph, 0) == PT_LOAD) {
            const vaddr = cp_rd(u64, ph, 16);
            const off = cp_rd(u64, ph, 8);
            if (off > vaddr) return null;
            bias = base -% @as(usize, @intCast(vaddr - off));
            break;
        }
    }
    const b = bias orelse return null;
    for (0..phnum) |i| {
        const ph = image[@intCast(phoff + i * phentsize)..][0..phdr_size];
        if (cp_rd(u32, ph, 0) != PT_NOTE) continue;
        const addr = b +% @as(usize, @intCast(cp_rd(u64, ph, 16)));
        const size: usize = @intCast(cp_rd(u64, ph, 32));
        if (addr < base or addr >= base_map_end or size > base_map_end - addr) continue;
        if (cp_findGnuBuildId(image[addr - base ..][0..size])) |id| return id;
    }
    return null;
}

/// Reads the build id from an ELF file's bytes (PT_NOTE by file offset).
/// Not crash-path: used by tests and tools.
pub fn buildIdFromFile(file: []const u8) ?[]const u8 {
    if (!cp_isElf64(file)) return null;
    const phoff = cp_rd(u64, file, 32);
    const phentsize = cp_rd(u16, file, 54);
    const phnum = cp_rd(u16, file, 56);
    if (phentsize < phdr_size or phoff > file.len or @as(u64, phnum) * phentsize > file.len - phoff) return null;
    for (0..phnum) |i| {
        const ph = file[@intCast(phoff + i * phentsize)..][0..phdr_size];
        if (cp_rd(u32, ph, 0) != PT_NOTE) continue;
        const off: usize = @intCast(cp_rd(u64, ph, 8));
        const size: usize = @intCast(cp_rd(u64, ph, 32));
        if (off > file.len or size > file.len - off) continue;
        if (cp_findGnuBuildId(file[off..][0..size])) |id| return id;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Threads

/// Lists the tids in `/proc/self/task` into `out`; returns the count.
pub fn cp_listThreads(dirent_buf: []u8, out: []u32) usize {
    const fd = cp_open(linux.AT.FDCWD, "/proc/self/task", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0) orelse return 0;
    defer cp_close(fd);
    var n: usize = 0;
    while (n < out.len) {
        const rc = linux.getdents64(fd, dirent_buf.ptr, dirent_buf.len);
        if (!cp_ok(rc) or rc == 0) break;
        var off: usize = 0;
        while (off < rc and n < out.len) {
            // struct linux_dirent64: ino u64, off i64, reclen u16, type u8, name.
            const reclen = std.mem.readInt(u16, dirent_buf[off + 16 ..][0..2], .native);
            if (reclen == 0) break;
            const name = std.mem.sliceTo(dirent_buf[off + 19 .. off + reclen], 0);
            if (cp_parseDec(name)) |tid| {
                out[n] = tid;
                n += 1;
            }
            off += reclen;
        }
    }
    return n;
}

fn cp_parseDec(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 10) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return std.math.cast(u32, v);
}

/// Reads `/proc/self/task/<tid>/comm` (without the newline) into `buf`.
pub fn cp_threadName(tid: u32, buf: []u8) []const u8 {
    var path: [64]u8 = undefined;
    const prefix = "/proc/self/task/";
    @memcpy(path[0..prefix.len], prefix);
    const d = capture.cp_fmtDec(path[prefix.len..], tid);
    const suffix = "/comm\x00";
    @memcpy(path[prefix.len + d.len ..][0..suffix.len], suffix);
    const name = cp_readFile(linux.AT.FDCWD, @ptrCast(&path), buf);
    return std.mem.trimEnd(u8, name, "\n");
}

// ---------------------------------------------------------------------------
// OS layer for capture.zig

/// Bytes below the stack pointer copied into STACK (the x86_64 red zone).
pub const red_zone = 128;
pub const max_modules = 256;
pub const max_threads = 128;
pub const max_named_threads = 64;

var crash_dirfd: i32 = -1;
var state_dirfd: i32 = -1;
var report_maps: [128 * 1024]u8 = undefined;
var report_maps_len: usize = 0;
var modules: [max_modules]ModuleSlot = undefined;
var report_tids: [max_threads]u32 = undefined;
var report_dirents: [8 * 1024]u8 align(8) = undefined;
var comm_buf: [16]u8 = undefined;

/// Opens the directories, reads the kernel release and installs the
/// signal handlers and the panic hook.
pub fn installOs(opts: capture.Options) capture.InstallError!void {
    crash_dirfd = try openDirP(opts.crash_dir);
    if (opts.state_dir) |sd| {
        state_dirfd = openDirP(sd) catch -1;
        // The boot marker's directory must exist before a crash.
        if (state_dirfd >= 0) _ = linux.mkdirat(state_dirfd, "update", 0o700);
    }
    const rel = cp_readFile(linux.AT.FDCWD, "/proc/sys/kernel/osrelease", &capture.os_release_buf);
    capture.os_release_len = std.mem.trimEnd(u8, rel, "\n").len;

    for ([_]linux.SIG{ .ABRT, .TRAP, .SYS }) |sig| {
        const act: linux.Sigaction = .{
            .handler = .{ .sigaction = onSignal },
            .mask = linux.sigemptyset(),
            .flags = linux.SA.SIGINFO | linux.SA.ONSTACK | linux.SA.RESETHAND,
        };
        _ = linux.sigaction(sig, &act, null);
    }
    // Replace std's fault handler: it uses SA_RESETHAND, so a second
    // thread faulting before the first one finished its report would kill
    // the process mid-write. Ours stays installed; later faults wait in
    // `cp_enter`, and `cp_reraise` restores the default action itself.
    for ([_]linux.SIG{ .SEGV, .ILL, .BUS, .FPE }) |sig| {
        const act: linux.Sigaction = .{
            .handler = .{ .sigaction = onFault },
            .mask = linux.sigemptyset(),
            .flags = linux.SA.SIGINFO | linux.SA.ONSTACK,
        };
        _ = linux.sigaction(sig, &act, null);
    }
    zg_core.report.setCrashHook(capture.onPanic);
}

/// `mkdir -p` then open as a directory fd.
fn openDirP(path: []const u8) capture.InstallError!i32 {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len == 0 or path.len >= z.len) return error.NameTooLong;
    @memcpy(z[0..path.len], path);
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            z[i] = 0;
            _ = linux.mkdirat(linux.AT.FDCWD, @ptrCast(&z), 0o700);
            if (i < path.len) z[i] = '/';
        }
    }
    z[path.len] = 0;
    return cp_open(linux.AT.FDCWD, @ptrCast(&z), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0) orelse
        error.CrashDirUnavailable;
}

/// std's SEGV/ILL/BUS/FPE handler calls this (via `capture.handleSegfault`)
/// for faults before `install`.
pub fn handleSegfault(addr: ?usize, name: []const u8, opt_ctx: ?CpuContextPtr) noreturn {
    if (!capture.installed) std.debug.defaultHandleSegfault(addr, name, opt_ctx);
    std.Options.debug_io.vtable.crashHandler(std.Options.debug_io.userdata);
    const c = cp_classify(name);
    const tid = cp_tid();
    if (capture.cp_enter(tid)) {
        capture.cp_write(&.{ .kind = c.kind, .os_code = @intFromEnum(c.sig), .fault = addr, .ctx = opt_ctx, .tid = tid });
        capture.cp_done();
    }
    cp_reraise(c.sig);
    std.process.abort();
}

const Classified = struct { kind: format.ReportKind, sig: linux.SIG };

fn cp_classify(name: []const u8) Classified {
    if (std.mem.eql(u8, name, "Illegal instruction")) return .{ .kind = .illegal_instruction, .sig = .ILL };
    if (std.mem.eql(u8, name, "Bus error")) return .{ .kind = .bus_error, .sig = .BUS };
    if (std.mem.eql(u8, name, "Arithmetic exception")) return .{ .kind = .arithmetic, .sig = .FPE };
    // "Segmentation fault" and "General protection exception".
    return .{ .kind = .segfault, .sig = .SEGV };
}

fn onSignal(sig: linux.SIG, info: *const linux.siginfo_t, uctx: ?*anyopaque) callconv(.c) void {
    std.Options.debug_io.vtable.crashHandler(std.Options.debug_io.userdata);
    const kind: format.ReportKind = switch (sig) {
        .ABRT => .abort,
        .TRAP => .trap,
        .SYS => .bad_syscall,
        else => .unknown,
    };
    const ctx: ?Native = std.debug.cpu_context.fromPosixSignalContext(uctx);
    const tid = cp_tid();
    if (capture.cp_enter(tid)) {
        capture.cp_write(&.{ .kind = kind, .os_code = @intFromEnum(sig), .si_code = info.code, .ctx = if (ctx) |*c| c else null, .tid = tid });
        capture.cp_done();
    }
    // SA_RESETHAND restored the default action; the signal is blocked
    // until we return, then it terminates the process.
    _ = linux.tgkill(linux.getpid(), linux.gettid(), sig);
}

/// SEGV/ILL/BUS/FPE after `install` (std's handler before it, through
/// `handleSegfault`).
fn onFault(sig: linux.SIG, info: *const linux.siginfo_t, uctx: ?*anyopaque) callconv(.c) void {
    std.Options.debug_io.vtable.crashHandler(std.Options.debug_io.userdata);
    const kind: format.ReportKind = switch (sig) {
        .ILL => .illegal_instruction,
        .BUS => .bus_error,
        .FPE => .arithmetic,
        else => .segfault,
    };
    // x86_64 reports no address for a general protection fault (SI_KERNEL).
    const si_kernel = 0x80;
    const fault: ?usize = if (builtin.cpu.arch == .x86_64 and sig == .SEGV and info.code == si_kernel)
        null
    else
        @intFromPtr(info.fields.sigfault.addr);
    const ctx: ?Native = std.debug.cpu_context.fromPosixSignalContext(uctx);
    const tid = cp_tid();
    if (capture.cp_enter(tid)) {
        capture.cp_write(&.{ .kind = kind, .os_code = @intFromEnum(sig), .si_code = info.code, .fault = fault, .ctx = if (ctx) |*c| c else null, .tid = tid });
        capture.cp_done();
    }
    cp_reraise(sig);
}

/// An open report file.
pub const Report = struct {
    fd: i32,

    fn cp_write(ctx: *anyopaque, bytes: []const u8) bool {
        const r: *Report = @ptrCast(@alignCast(ctx));
        return cp_writeAll(r.fd, bytes);
    }

    fn cp_sync(ctx: *anyopaque) void {
        const r: *Report = @ptrCast(@alignCast(ctx));
        cp_fsync(r.fd);
    }
};

/// Creates `name` (NUL-terminated in its buffer) in the crash directory.
pub fn cp_createReport(name: []const u8) ?Report {
    const z: [*:0]const u8 = @ptrCast(name.ptr);
    std.debug.assert(name.ptr[name.len] == 0);
    const fd = cp_open(crash_dirfd, z, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600) orelse return null;
    return .{ .fd = fd };
}

pub fn cp_reportSink(r: *Report) format.RawSink {
    return .{ .ctx = r, .write = Report.cp_write, .sync = Report.cp_sync };
}

pub fn cp_closeReport(r: *Report) void {
    cp_close(r.fd);
}

/// MODULES from /proc/self/maps (kept for `cp_writeStack`).
pub fn cp_writeModules(w: *format.Writer) void {
    const maps = cp_readFile(linux.AT.FDCWD, "/proc/self/maps", &report_maps);
    report_maps_len = maps.len;
    const n = cp_collectModules(maps, &modules);
    var s = w.section(.modules);
    s.writeInt(u32, @intCast(n));
    s.writeInt(u32, 0);
    for (modules[0..n]) |*m| {
        const is_vdso = std.mem.eql(u8, m.path, "[vdso]");
        const id: ?[]const u8 = if (is_vdso or !m.have_base or !m.base_readable) null else cp_buildIdFromMemory(m.base, m.base_map_end);
        format.writeModule(&s, .{
            .base = m.base,
            .size = m.end - m.base,
            .id_kind = if (id != null) .gnu_build_id else .none,
            .id = id orelse "",
            .path = m.path[0..@min(m.path.len, std.math.maxInt(u16))],
        });
    }
    s.end();
}

/// STACK: `[sp - red_zone, sp + window)` clamped to sp's mapping.
pub fn cp_writeStack(w: *format.Writer, sp: u64, _: *const capture.Crash) void {
    if (sp == 0) return;
    const m = cp_findMapping(report_maps[0..report_maps_len], @intCast(sp)) orelse return;
    if (!m.readable) return;
    const start = @max(m.start, @as(usize, @intCast(sp)) -| red_zone);
    const end = @min(m.end, @as(usize, @intCast(sp)) +| capture.stack_window);
    capture.cp_stackSection(w, start, end);
}

/// THREADS from /proc/self/task with comm names.
pub fn cp_writeThreads(w: *format.Writer, _: *const capture.Crash) void {
    const n = cp_listThreads(&report_dirents, &report_tids);
    var s = w.section(.threads);
    s.writeInt(u32, @intCast(n));
    s.writeInt(u32, 0);
    for (report_tids[0..n], 0..) |tid, i| {
        const name = if (i < max_named_threads) cp_threadName(tid, &comm_buf) else "";
        s.writeInt(u64, tid);
        s.write(&.{@intCast(name.len)});
        s.write(name);
        s.alignData();
    }
    s.end();
}

/// `<state>/update/boot-crashed` holding the crashed version.
pub fn cp_writeBootMarker(version: []const u8) void {
    if (state_dirfd < 0) return;
    const fd = cp_open(state_dirfd, "update/boot-crashed", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600) orelse return;
    _ = cp_writeAll(fd, version);
    cp_fsync(fd);
    cp_close(fd);
}

pub fn cp_writeStderr(bytes: []const u8) void {
    _ = cp_writeAll(2, bytes);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "linux: classify" {
    try testing.expectEqual(format.ReportKind.segfault, cp_classify("General protection exception").kind);
    try testing.expectEqual(linux.SIG.FPE, cp_classify("Arithmetic exception").sig);
}

test "linux: maps parser" {
    const fixture =
        \\55d0c8a00000-55d0c8a02000 r--p 00000000 08:01 1234                       /usr/bin/zigguro
        \\55d0c8a02000-55d0c8a10000 r-xp 00002000 08:01 1234                       /usr/bin/zigguro
        \\55d0c8a10000-55d0c8a12000 rw-p 00010000 08:01 1234                       /usr/bin/zigguro
        \\55d0c9000000-55d0c9021000 rw-p 00000000 00:00 0                          [heap]
        \\7f0000000000-7f0000001000 r--p 00000000 08:01 99                         /home/u/My Apps/lib two.so (deleted)
        \\7f0000001000-7f0000003000 r-xp 00001000 08:01 99                         /home/u/My Apps/lib two.so (deleted)
        \\7f0000010000-7f0000011000 rw-p 00000000 00:00 0
        \\7ffd00000000-7ffd00021000 rw-p 00000000 00:00 0                          [stack]
        \\7ffd00100000-7ffd00102000 r-xp 00000000 00:00 0                          [vdso]
        \\garbage line
        \\7ffd00200000-7ffd002
    ;
    const e = cp_parseMapsLine("55d0c8a02000-55d0c8a10000 r-xp 00002000 08:01 1234   /usr/bin/zigguro").?;
    try testing.expectEqual(@as(usize, 0x55d0c8a02000), e.start);
    try testing.expectEqual(@as(u64, 0x2000), e.offset);
    try testing.expect(e.exec and e.readable);
    try testing.expectEqualStrings("/usr/bin/zigguro", e.path);
    try testing.expectEqualStrings("", cp_parseMapsLine("7f0000010000-7f0000011000 rw-p 00000000 00:00 0 ").?.path);
    try testing.expect(cp_parseMapsLine("garbage line") == null);
    try testing.expect(cp_parseMapsLine("1000-0800 r--p 0 0:0 0") == null);

    var mods: [8]ModuleSlot = undefined;
    const n = cp_collectModules(fixture, &mods);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("/usr/bin/zigguro", mods[0].path);
    try testing.expectEqual(@as(usize, 0x55d0c8a00000), mods[0].base);
    try testing.expectEqual(@as(usize, 0x55d0c8a12000), mods[0].end);
    try testing.expectEqual(@as(usize, 0x55d0c8a02000), mods[0].base_map_end);
    try testing.expectEqualStrings("/home/u/My Apps/lib two.so", mods[1].path);
    try testing.expectEqual(@as(usize, 0x3000), mods[1].end - mods[1].base);
    try testing.expectEqualStrings("[vdso]", mods[2].path);

    // Capacity is respected.
    try testing.expectEqual(@as(usize, 1), cp_collectModules(fixture, mods[0..1]));

    const stack = cp_findMapping(fixture, 0x7ffd00020000).?;
    try testing.expectEqualStrings("[stack]", stack.path);
    try testing.expect(cp_findMapping(fixture, 0x10) == null);
}

test "linux: build-id note parser" {
    const notes = "\x04\x00\x00\x00\x10\x00\x00\x00\x01\x00\x00\x00GNU\x00" ++ "\x00" ** 16 ++
        "\x04\x00\x00\x00\x04\x00\x00\x00\x03\x00\x00\x00GNU\x00" ++ "\xde\xad\xbe\xef";
    try testing.expectEqualSlices(u8, "\xde\xad\xbe\xef", cp_findGnuBuildId(notes).?);
    try testing.expect(cp_findGnuBuildId(notes[0..30]) == null);
    try testing.expect(cp_findGnuBuildId("\xff\xff\xff\xff\x00\x00\x00\x00\x03\x00\x00\x00") == null);
}

test "linux: build-id from memory equals build-id from file" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var maps_buf: [128 * 1024]u8 = undefined;
    const maps = cp_readFile(linux.AT.FDCWD, "/proc/self/maps", &maps_buf);
    var mods: [256]ModuleSlot = undefined;
    const n = cp_collectModules(maps, &mods);
    const self = cp_findMapping(maps, @intFromPtr(&cp_collectModules)).?;
    const m = for (mods[0..n]) |*m| {
        if (std.mem.eql(u8, m.path, self.path)) break m;
    } else return error.TestUnexpectedResult;
    const from_mem = cp_buildIdFromMemory(m.base, m.base_map_end);

    const io = testing.io;
    const file = try std.Io.Dir.cwd().readFileAlloc(io, self.path, testing.allocator, .limited(1 << 30));
    defer testing.allocator.free(file);
    const from_file = buildIdFromFile(file);
    if (from_file) |id| {
        try testing.expectEqualSlices(u8, id, from_mem.?);
    } else {
        // Test binaries are linked without --build-id; the crasher tests
        // cover the populated case.
        try testing.expect(from_mem == null);
    }
}

test "linux: thread list and names" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var dents: [4096]u8 = undefined;
    var tids: [128]u32 = undefined;
    const n = cp_listThreads(&dents, &tids);
    try testing.expect(n >= 1);
    try testing.expect(std.mem.indexOfScalar(u32, tids[0..n], cp_tid()) != null);
    var name_buf: [32]u8 = undefined;
    try testing.expect(cp_threadName(cp_tid(), &name_buf).len > 0);
}

test "linux: clock, decimal parsing" {
    try testing.expect(cp_nowMs() > 1_700_000_000_000);
    try testing.expectEqual(@as(?u32, 4242), cp_parseDec("4242"));
    try testing.expectEqual(@as(?u32, null), cp_parseDec("."));
}
