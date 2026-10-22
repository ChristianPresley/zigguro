//! Windows crash capture (E17.F05.S01.T03): the OS layer behind
//! capture.zig.
//!
//! - `SetUnhandledExceptionFilter` catches every exception nothing else
//!   handled (last chance, so first-chance exceptions a driver handles
//!   with SEH never reach us).
//! - A vectored handler added last reacts only to
//!   `EXCEPTION_STACK_OVERFLOW`: by the time the filter would run, the
//!   overflowing thread has no stack left.
//! - Both hand the crash to a writer thread created at install with its
//!   own 256 KiB stack. The faulting thread records its id and TEB stack
//!   bounds, signals the writer and waits (10 s at most); the exception
//!   record and context stay valid while it waits.
//! - The writer unwinds the faulting thread itself (`RtlVirtualUnwind`
//!   bounded by that thread's stack), lists modules from the PEB loader
//!   list with their CodeView (PDB 7.0) ids and threads from
//!   `NtQuerySystemInformation` into a preallocated buffer.
//!
//! Fail-fast exceptions (`__fastfail`, `STATUS_STACK_BUFFER_OVERRUN`) end
//! the process without running any handler, so they leave no report (see
//! docs/crash-reports.md).
//!
//! `cp_*` functions call Win32 only through `win.*` (win_bindings.zig),
//! checked by the "crash path: syscall allowlist" test in capture.zig.
//! Apps must keep std's own vectored segfault handler off on Windows
//! (`.enable_segfault_handler = builtin.os.tag != .windows`): it runs
//! before the filter and exits without a report.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const format = @import("format.zig");
const capture = @import("capture.zig");
const pe = @import("pe.zig");
const win = @import("win_bindings.zig");
const windows = std.os.windows;
const Native = std.debug.cpu_context.Native;

/// Exit status used when a second crashing thread gives up waiting
/// (std's `abort` status on Windows).
pub const stuck_exit_status = 3;
/// x64 Windows has no red zone; a little below SP is still useful.
pub const red_zone = 128;
pub const max_modules = 256;
pub const max_threads = 128;
/// Stack of the writer thread.
pub const writer_stack = 256 * 1024;
/// How long a faulting thread waits for its report.
pub const handoff_timeout_ms = 10_000;
/// Stack kept for the overflow handler on the installing thread.
pub const stack_guarantee = 64 * 1024;

const max_path_w = std.fs.max_path_bytes;

var crash_dir_w: [max_path_w]u16 = undefined;
var crash_dir_w_len: usize = 0;
var marker_w: [max_path_w]u16 = undefined;
var have_marker = false;
var report_path_w: [max_path_w + 64]u16 = undefined;

var go_event: ?win.HANDLE = null;
var done_event: ?win.HANDLE = null;
var writer_tid: u32 = 0;

/// What the faulting thread hands the writer.
const Pending = struct {
    info: *win.EXCEPTION_POINTERS,
    tid: u32,
    stack_limit: usize,
    stack_base: usize,
};
var pending: Pending = undefined;

// Preallocated crash-time memory.
var native_ctx: Native = undefined;
var unwind_ctx: windows.CONTEXT = undefined;
var history: windows.UNWIND_HISTORY_TABLE = undefined;
var trace_buf: [capture.max_frames]usize = undefined;
var path_utf8: [max_path_w * 3]u8 = undefined;
var spi_buf: [1 << 20]u8 align(8) = undefined;

/// Converts the directories, reads the OS version, creates the writer
/// thread and installs the filter, the overflow handler and the panic
/// hook.
pub fn installOs(opts: capture.Options) capture.InstallError!void {
    try setDirs(opts.crash_dir, opts.state_dir);
    osVersion();

    go_event = win.CreateEventW(null, .FALSE, .FALSE, null) orelse return error.SystemResources;
    done_event = win.CreateEventW(null, .FALSE, .FALSE, null) orelse return error.SystemResources;
    const thread = win.CreateThread(null, writer_stack, writerMain, null, 0, &writer_tid) orelse return error.SystemResources;
    _ = win.NtClose(thread);

    guardCurrentThread();
    _ = win.SetErrorMode(win.SEM_FAILCRITICALERRORS | win.SEM_NOGPFAULTERRORBOX);
    _ = win.AddVectoredExceptionHandler(0, onVectored);
    _ = win.SetUnhandledExceptionFilter(onUnhandled);
    zg_core.report.setCrashHook(capture.onPanic);
}

/// Keeps `stack_guarantee` bytes for the overflow handler on this thread
/// (the installing thread gets it from `install`).
pub fn guardCurrentThread() void {
    var guarantee: u32 = stack_guarantee;
    _ = win.SetThreadStackGuarantee(&guarantee);
}

/// Converts and creates the crash directory, and the boot marker's
/// directory under `state_dir`.
fn setDirs(crash_dir: []const u8, state_dir: ?[]const u8) capture.InstallError!void {
    crash_dir_w_len = try toWide(&crash_dir_w, crash_dir);
    try mkdirP(crash_dir_w[0..crash_dir_w_len]);
    have_marker = false;
    const sd = state_dir orelse return;
    var n = try toWide(&marker_w, sd);
    const dir = "\\update";
    const file = "\\boot-crashed";
    if (n + dir.len + file.len >= marker_w.len) return error.NameTooLong;
    for (dir) |c| {
        marker_w[n] = c;
        n += 1;
    }
    marker_w[n] = 0;
    // The boot marker's directory must exist before a crash.
    mkdirP(marker_w[0..n]) catch return;
    for (file) |c| {
        marker_w[n] = c;
        n += 1;
    }
    marker_w[n] = 0;
    have_marker = true;
}

/// UTF-8 `path` into `buf` as a NUL-terminated wide string with
/// backslashes; returns its length.
fn toWide(buf: []u16, path: []const u8) capture.InstallError!usize {
    if (path.len == 0 or path.len >= buf.len) return error.NameTooLong;
    const n = std.unicode.wtf8ToWtf16Le(buf[0 .. buf.len - 1], path) catch return error.NameTooLong;
    for (buf[0..n]) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    // No trailing separator: report names are appended after one.
    var len = n;
    while (len > 1 and buf[len - 1] == '\\') len -= 1;
    buf[len] = 0;
    return len;
}

/// `mkdir -p` for a NUL-terminated wide path (the NUL is at `path.len`).
fn mkdirP(path: []u16) capture.InstallError!void {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '\\') {
            const saved = path.ptr[i];
            path.ptr[i] = 0;
            // Skips "C:" and "\\server" prefixes: those fail harmlessly.
            _ = win.CreateDirectoryW(@ptrCast(path.ptr), null);
            path.ptr[i] = saved;
        }
    }
    const h = win.CreateFileW(@ptrCast(path.ptr), 0, 7, null, 3, 0x0200_0000, null);
    if (h == win.INVALID_HANDLE_VALUE) return error.CrashDirUnavailable;
    _ = win.NtClose(h);
}

/// "10.0.22631" into the META `os_version`.
fn osVersion() void {
    var v: windows.RTL_OSVERSIONINFOW = undefined;
    v.dwOSVersionInfoSize = @sizeOf(windows.RTL_OSVERSIONINFOW);
    if (win.RtlGetVersion(&v) != .SUCCESS) return;
    var w: std.Io.Writer = .fixed(&capture.os_release_buf);
    w.print("{d}.{d}.{d}", .{ v.dwMajorVersion, v.dwMinorVersion, v.dwBuildNumber }) catch {};
    capture.os_release_len = w.buffered().len;
}

// ---------------------------------------------------------------------------
// Hooks

fn onUnhandled(info: *win.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    cp_handOff(info);
    return win.EXCEPTION_EXECUTE_HANDLER;
}

fn onVectored(info: *win.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    if (info.ExceptionRecord.ExceptionCode != win.status.stack_overflow) return win.EXCEPTION_CONTINUE_SEARCH;
    cp_handOff(info);
    _ = win.TerminateProcess(win.GetCurrentProcess(), win.status.stack_overflow);
    return win.EXCEPTION_CONTINUE_SEARCH;
}

/// Runs on the faulting thread: takes the writer role and waits for the
/// writer thread. Returns at once when the writer itself faulted.
fn cp_handOff(info: *win.EXCEPTION_POINTERS) void {
    const tid = win.GetCurrentThreadId();
    if (tid == writer_tid) return;
    if (!capture.cp_enter(tid)) return;
    const tib = &windows.teb().NtTib;
    pending = .{
        .info = info,
        .tid = tid,
        .stack_limit = @intFromPtr(tib.StackLimit),
        .stack_base = @intFromPtr(tib.StackBase),
    };
    if (win.SetEvent(go_event.?).toBool()) _ = win.WaitForSingleObject(done_event.?, handoff_timeout_ms);
    capture.cp_done();
}

fn writerMain(_: ?*anyopaque) callconv(.winapi) u32 {
    while (win.WaitForSingleObject(go_event.?, std.math.maxInt(u32)) == win.WAIT_OBJECT_0) {
        cp_writePending();
        _ = win.SetEvent(done_event.?);
    }
    return 0;
}

const Classified = struct {
    kind: format.ReportKind,
    fault: ?usize = null,
    access: format.Access = .none,
};

fn cp_classify(rec: *const windows.EXCEPTION_RECORD) Classified {
    const s = win.status;
    return switch (rec.ExceptionCode) {
        s.access_violation, s.in_page_error => .{
            .kind = .segfault,
            .fault = if (rec.NumberParameters >= 2) rec.ExceptionInformation[1] else null,
            .access = if (rec.NumberParameters >= 1) switch (rec.ExceptionInformation[0]) {
                0 => .read,
                1 => .write,
                8 => .exec,
                else => .none,
            } else .none,
        },
        s.stack_overflow => .{ .kind = .stack_overflow },
        s.illegal_instruction, s.privileged_instruction => .{ .kind = .illegal_instruction },
        s.int_divide_by_zero, s.int_overflow, s.flt_divide_by_zero => .{ .kind = .arithmetic },
        s.breakpoint => .{ .kind = .trap },
        s.datatype_misalignment => .{ .kind = .bus_error },
        else => .{ .kind = .windows_exception },
    };
}

/// Runs on the writer thread.
fn cp_writePending() void {
    const p = pending;
    const rec = p.info.ExceptionRecord;
    const c = cp_classify(rec);
    native_ctx = std.debug.cpu_context.fromWindowsContext(p.info.ContextRecord);
    const n = cp_unwind(p.info.ContextRecord, p.stack_limit, p.stack_base, &trace_buf);
    capture.cp_write(&.{
        .kind = c.kind,
        .os_code = rec.ExceptionCode,
        .fault = c.fault,
        .access = c.access,
        .ctx = &native_ctx,
        .tid = p.tid,
        .stack_limit = p.stack_limit,
        .stack_base = p.stack_base,
        .trace = .{ .return_addresses = trace_buf[0..n.count], .skipped = if (n.complete) .none else .unknown },
    });
}

const Unwound = struct { count: usize, complete: bool };

/// The faulting PC (+1, like std's traces) and the return addresses
/// `RtlVirtualUnwind` finds while SP stays inside `[limit, base]`.
fn cp_unwind(ctx: *const windows.CONTEXT, limit: usize, base: usize, out: []usize) Unwound {
    unwind_ctx = ctx.*;
    history = std.mem.zeroes(windows.UNWIND_HISTORY_TABLE);
    var n: usize = 0;
    out[n] = unwind_ctx.getRegs().ip +| 1;
    n += 1;
    while (n < out.len) {
        const regs = unwind_ctx.getRegs();
        var image_base: usize = 0;
        if (win.RtlLookupFunctionEntry(regs.ip, &image_base, &history)) |f| {
            var handler_data: ?*anyopaque = null;
            var establisher: usize = 0;
            _ = win.RtlVirtualUnwind(0, image_base, regs.ip, f, &unwind_ctx, &handler_data, &establisher, null);
        } else {
            // A leaf function: the return address is at SP.
            if (regs.sp < limit or regs.sp + @sizeOf(usize) > base) return .{ .count = n, .complete = true };
            unwind_ctx.setIp(@as(*const usize, @ptrFromInt(regs.sp)).*);
            unwind_ctx.setSp(regs.sp + @sizeOf(usize));
        }
        const next = unwind_ctx.getRegs();
        if (next.ip <= 1 or next.sp < limit or next.sp > base or next.sp <= regs.sp) return .{ .count = n, .complete = true };
        out[n] = next.ip;
        n += 1;
    }
    return .{ .count = n, .complete = false };
}

// ---------------------------------------------------------------------------
// OS layer for capture.zig

pub fn cp_tid() u32 {
    return win.GetCurrentThreadId();
}

pub fn cp_pid() u32 {
    return win.GetCurrentProcessId();
}

pub fn cp_monoMs() i64 {
    return @intCast(win.GetTickCount64());
}

/// Unix milliseconds.
pub fn cp_nowMs() i64 {
    var ft: win.FILETIME = undefined;
    win.GetSystemTimeAsFileTime(&ft);
    const t: u64 = (@as(u64, ft.hi) << 32) | ft.lo;
    const unix_epoch_100ns: u64 = 116_444_736_000_000_000;
    return @intCast((t -| unix_epoch_100ns) / 10_000);
}

pub fn cp_yield() void {
    _ = win.SwitchToThread();
}

pub fn cp_exit(code: u32) noreturn {
    _ = win.TerminateProcess(win.GetCurrentProcess(), code);
    unreachable;
}

/// An open report file.
pub const Report = struct {
    h: win.HANDLE,

    fn cp_write(ctx: *anyopaque, bytes: []const u8) bool {
        const r: *Report = @ptrCast(@alignCast(ctx));
        return cp_writeAll(r.h, bytes);
    }

    fn cp_sync(ctx: *anyopaque) void {
        const r: *Report = @ptrCast(@alignCast(ctx));
        _ = win.FlushFileBuffers(r.h);
    }
};

fn cp_writeAll(h: win.HANDLE, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        var n: u32 = 0;
        const chunk: u32 = @intCast(@min(rest.len, 1 << 30));
        if (!win.WriteFile(h, rest.ptr, chunk, &n, null).toBool() or n == 0) return false;
        rest = rest[n..];
    }
    return true;
}

/// Creates `name` (ASCII) in the crash directory.
pub fn cp_createReport(name: []const u8) ?Report {
    const dir = crash_dir_w[0..crash_dir_w_len];
    if (dir.len + 1 + name.len >= report_path_w.len) return null;
    @memcpy(report_path_w[0..dir.len], dir);
    report_path_w[dir.len] = '\\';
    for (name, 0..) |c, i| report_path_w[dir.len + 1 + i] = c;
    report_path_w[dir.len + 1 + name.len] = 0;
    const h = win.CreateFileW(@ptrCast(&report_path_w), win.GENERIC_WRITE, 0, null, win.CREATE_NEW, win.FILE_ATTRIBUTE_NORMAL, null);
    if (h == win.INVALID_HANDLE_VALUE) return null;
    return .{ .h = h };
}

pub fn cp_reportSink(r: *Report) format.RawSink {
    return .{ .ctx = r, .write = Report.cp_write, .sync = Report.cp_sync };
}

pub fn cp_closeReport(r: *Report) void {
    _ = win.NtClose(r.h);
}

/// MODULES from the PEB loader list, with CodeView ids.
pub fn cp_writeModules(w: *format.Writer) void {
    const head = &windows.peb().Ldr.InMemoryOrderModuleList;
    var n: u32 = 0;
    var link = head.Flink;
    while (link != head and n < max_modules) : (link = link.Flink) n += 1;

    var s = w.section(.modules);
    s.writeInt(u32, n);
    s.writeInt(u32, 0);
    link = head.Flink;
    var i: u32 = 0;
    while (link != head and i < n) : (link = link.Flink) {
        i += 1;
        const e: *const windows.LDR.DATA_TABLE_ENTRY = @fieldParentPtr("InMemoryOrderLinks", link);
        const base = @intFromPtr(e.DllBase);
        const image = @as([*]const u8, @ptrCast(e.DllBase))[0..e.SizeOfImage];
        const id = pe.cp_codeViewId(image, .memory);
        const name = e.FullDllName;
        const wide: []const u16 = if (name.Buffer) |b| b[0 .. name.Length / 2] else &.{};
        const path = cp_utf8(wide, &path_utf8);
        format.writeModule(&s, .{
            .base = base,
            .size = e.SizeOfImage,
            .id_kind = if (id != null) .pdb70 else .none,
            .id = if (id) |d| d else "",
            .path = path[0..@min(path.len, std.math.maxInt(u16))],
        });
    }
    s.end();
}

/// UTF-16 to UTF-8; unpaired surrogates become U+FFFD.
fn cp_utf8(src: []const u16, dst: []u8) []const u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        var cp: u21 = src[i];
        if (cp >= 0xD800 and cp <= 0xDBFF and i + 1 < src.len and src[i + 1] >= 0xDC00 and src[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (src[i + 1] - 0xDC00);
            i += 1;
        } else if (cp >= 0xD800 and cp <= 0xDFFF) {
            cp = 0xFFFD;
        }
        const len: usize = if (cp < 0x80) 1 else if (cp < 0x800) 2 else if (cp < 0x10000) 3 else 4;
        if (dst.len - o < len) break;
        switch (len) {
            1 => dst[o] = @intCast(cp),
            2 => {
                dst[o] = @intCast(0xC0 | (cp >> 6));
                dst[o + 1] = @intCast(0x80 | (cp & 0x3F));
            },
            3 => {
                dst[o] = @intCast(0xE0 | (cp >> 12));
                dst[o + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                dst[o + 2] = @intCast(0x80 | (cp & 0x3F));
            },
            else => {
                dst[o] = @intCast(0xF0 | (cp >> 18));
                dst[o + 1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
                dst[o + 2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                dst[o + 3] = @intCast(0x80 | (cp & 0x3F));
            },
        }
        o += len;
    }
    return dst[0..o];
}

/// STACK: `[sp - red_zone, sp + window)` clamped to the crashing thread's
/// stack (this thread's for a panic).
pub fn cp_writeStack(w: *format.Writer, sp: u64, c: *const capture.Crash) void {
    if (sp == 0) return;
    var limit = c.stack_limit;
    var base = c.stack_base;
    if (base == 0) {
        const tib = &windows.teb().NtTib;
        limit = @intFromPtr(tib.StackLimit);
        base = @intFromPtr(tib.StackBase);
    }
    const s: usize = @intCast(sp);
    if (s < limit or s > base) return;
    capture.cp_stackSection(w, @max(limit, s -| red_zone), @min(base, s +| capture.stack_window));
}

/// THREADS: this process's thread ids from `SystemProcessInformation`;
/// just the crashing thread when the buffer is too small. No names
/// (`GetThreadDescription` allocates).
pub fn cp_writeThreads(w: *format.Writer, c: *const capture.Crash) void {
    var tids: [max_threads]u32 = undefined;
    var n: usize = 0;
    if (@sizeOf(usize) == 8) n = cp_listThreads(&tids);
    if (n == 0) {
        tids[0] = c.tid;
        n = 1;
    }
    var s = w.section(.threads);
    s.writeInt(u32, @intCast(n));
    s.writeInt(u32, 0);
    for (tids[0..n]) |tid| {
        s.writeInt(u64, tid);
        s.write(&.{0});
        s.alignData();
    }
    s.end();
}

fn cp_listThreads(out: []u32) usize {
    var ret: u32 = 0;
    if (win.NtQuerySystemInformation(.Process, &spi_buf, spi_buf.len, &ret) != .SUCCESS) return 0;
    return cp_threadsOf(spi_buf[0..@min(ret, spi_buf.len)], win.GetCurrentProcessId(), out);
}

/// Thread ids of `pid` in a `SystemProcessInformation` buffer.
pub fn cp_threadsOf(buf: []const u8, pid: u32, out: []u32) usize {
    const L = win.spi;
    var at: usize = 0;
    while (at + L.size <= buf.len) {
        const rec = buf[at..];
        const next = std.mem.readInt(u32, rec[L.next_entry..][0..4], .little);
        const nt = std.mem.readInt(u32, rec[L.n_threads..][0..4], .little);
        const id = std.mem.readInt(u64, rec[L.pid..][0..8], .little);
        if (id == pid) {
            var n: usize = 0;
            while (n < nt and n < out.len) : (n += 1) {
                const t = L.size + n * L.thread_size + L.thread_tid;
                if (t + 8 > rec.len) break;
                out[n] = @truncate(std.mem.readInt(u64, rec[t..][0..8], .little));
            }
            return n;
        }
        if (next == 0) break;
        at += next;
    }
    return 0;
}

/// `<state>\update\boot-crashed` holding the crashed version.
pub fn cp_writeBootMarker(version: []const u8) void {
    if (!have_marker) return;
    const h = win.CreateFileW(@ptrCast(&marker_w), win.GENERIC_WRITE, 0, null, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
    if (h == win.INVALID_HANDLE_VALUE) return;
    _ = cp_writeAll(h, version);
    _ = win.FlushFileBuffers(h);
    _ = win.NtClose(h);
}

pub fn cp_writeStderr(bytes: []const u8) void {
    const h = win.GetStdHandle(win.STD_ERROR_HANDLE) orelse return;
    if (h == win.INVALID_HANDLE_VALUE) return;
    _ = cp_writeAll(h, bytes);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "windows: classify" {
    var rec = std.mem.zeroes(windows.EXCEPTION_RECORD);
    rec.ExceptionCode = win.status.access_violation;
    rec.NumberParameters = 2;
    rec.ExceptionInformation[0] = 1;
    rec.ExceptionInformation[1] = 0x10;
    const c = cp_classify(&rec);
    try testing.expectEqual(format.ReportKind.segfault, c.kind);
    try testing.expectEqual(format.Access.write, c.access);
    try testing.expectEqual(@as(?usize, 0x10), c.fault);
    rec.ExceptionInformation[0] = 8;
    try testing.expectEqual(format.Access.exec, cp_classify(&rec).access);
    rec.ExceptionCode = win.status.stack_overflow;
    try testing.expectEqual(format.ReportKind.stack_overflow, cp_classify(&rec).kind);
    rec.ExceptionCode = win.status.int_divide_by_zero;
    try testing.expectEqual(format.ReportKind.arithmetic, cp_classify(&rec).kind);
    rec.ExceptionCode = 0xE06D7363; // a C++ exception
    try testing.expectEqual(format.ReportKind.windows_exception, cp_classify(&rec).kind);
}

test "windows: UTF-16 paths, thread list, unwinding this thread" {
    var out: [16]u8 = undefined;
    const w = [_]u16{ 'C', ':', '\\', 0xE9, 0xD83D, 0xDE00, 0xD800 };
    try testing.expectEqualStrings("C:\\\u{e9}\u{1f600}\u{fffd}", cp_utf8(&w, &out));
    try testing.expectEqualStrings("C:\\\u{e9}", cp_utf8(&w, out[0..5]));

    var tids: [max_threads]u32 = undefined;
    const n = cp_listThreads(&tids);
    try testing.expect(n >= 1);
    try testing.expect(std.mem.indexOfScalar(u32, tids[0..n], cp_tid()) != null);

    var ctx: windows.CONTEXT = undefined;
    windows.ntdll.RtlCaptureContext(&ctx);
    const tib = &windows.teb().NtTib;
    var addrs: [32]usize = undefined;
    const u = cp_unwind(&ctx, @intFromPtr(tib.StackLimit), @intFromPtr(tib.StackBase), &addrs);
    try testing.expect(u.count >= 2);
}

test "windows: report file, stderr-free sink, boot marker paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const crashes = try std.fmt.bufPrint(&pbuf, "{s}/a/b/", .{dir});
    try setDirs(crashes, dir);
    var r = cp_createReport("x.zgcrash") orelse return error.CreateFailed;
    const sink = cp_reportSink(&r);
    try testing.expect(sink.write(sink.ctx, "hello"));
    sink.sync(sink.ctx);
    cp_closeReport(&r);
    // CREATE_NEW: a second report with the same name fails.
    try testing.expect(cp_createReport("x.zgcrash") == null);
    cp_writeBootMarker("1.2.3");
    var rb: [16]u8 = undefined;
    try testing.expectEqualStrings("hello", try tmp.dir.readFile(testing.io, "a/b/x.zgcrash", &rb));
    try testing.expectEqualStrings("1.2.3", try tmp.dir.readFile(testing.io, "update/boot-crashed", &rb));
}
