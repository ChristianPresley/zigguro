//! Crash capture core (E17.F05.S01.T02/T03): `install`, the re-entrancy
//! guard and the platform-independent report writer. The OS layers in
//! linux.zig and windows.zig install the hooks and provide files, modules,
//! stack and threads; every hook funnels into `cp_write`.
//!
//! The crash path (`cp_*` here and in the OS layers) is checked by the
//! "crash path: syscall allowlist" test below.

const std = @import("std");
const builtin = @import("builtin");
const zg_release = @import("zg_release");
const format = @import("format.zig");
const annotations = @import("annotations.zig");
const timefmt = @import("timefmt.zig");
const lx = @import("linux.zig");
const wx = @import("windows.zig");
const win = @import("win_bindings.zig");

const is_linux = builtin.os.tag == .linux;
const is_windows = builtin.os.tag == .windows;
const CpuContextPtr = std.debug.CpuContextPtr;
const Native = std.debug.cpu_context.Native;

/// The OS layer for this target.
const osl = if (is_linux) lx else if (is_windows) wx else struct {};

/// Bytes of stack copied above the stack pointer.
pub const stack_window = 16 * 1024;
pub const max_frames = 128;

pub const Options = struct {
    /// Directory reports are written to; created if missing.
    crash_dir: []const u8,
    /// State directory; `update/boot-crashed` is written under it when
    /// the `boot_pending` annotation is "1" (E17.F04.S02.T02).
    state_dir: ?[]const u8 = null,
    /// META `.product`.
    product: []const u8 = "zigguro",
    /// META `.install_kind` (E17.F02/F03: msix, portable, appimage, ...).
    install_kind: []const u8 = "unknown",
    /// Print the report path to stderr after a crash.
    announce: bool = true,
};

pub const InstallError = error{ Unsupported, NameTooLong, CrashDirUnavailable, SystemResources };

/// What a hook knows about a crash.
pub const Crash = struct {
    kind: format.ReportKind,
    /// Signal number or NTSTATUS.
    os_code: u32,
    si_code: i32 = 0,
    fault: ?usize = null,
    access: format.Access = .none,
    ctx: ?CpuContextPtr = null,
    panic_msg: ?[]const u8 = null,
    /// Skip trace frames until this return address (panics).
    first_addr: ?usize = null,
    /// The crashing thread (the writer may be another thread on Windows).
    tid: u32,
    /// Stack bounds of the crashing thread when known (Windows TEB).
    stack_limit: usize = 0,
    stack_base: usize = 0,
    /// Trace captured by the caller (Windows panics); null to unwind here.
    trace: ?std.debug.StackTrace = null,
};

const State = enum(u32) { idle = 0, writing = 1, done = 2 };

var state: std.atomic.Value(u32) = .init(@intFromEnum(State.idle));
var owner_tid: std.atomic.Value(u32) = .init(0);
pub var installed: bool = false;
pub var announce: bool = true;
var start_mono_ms: i64 = 0;

pub var crash_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
pub var crash_dir_len: usize = 0;
pub var product_buf: [32]u8 = undefined;
pub var product_len: usize = 0;
var install_kind_buf: [32]u8 = undefined;
var install_kind_len: usize = 0;
/// Filled by the OS layer at install.
pub var os_release_buf: [64]u8 = undefined;
pub var os_release_len: usize = 0;

// Preallocated crash-time memory.
var write_buf: [256 * 1024]u8 align(8) = undefined;
var addr_buf: [max_frames]usize = undefined;
var ann_pairs: [annotations.max_keys]annotations.Pair = undefined;
var ann_storage: annotations.SnapshotStorage = .{};
var meta_buf: [1024]u8 = undefined;
var name_buf: [timefmt.max_name_len + 1]u8 = undefined;
var msg_buf: [std.fs.max_path_bytes + 128]u8 = undefined;

fn copyInto(buf: []u8, len: *usize, s: []const u8) InstallError!void {
    if (s.len > buf.len) return error.NameTooLong;
    @memcpy(buf[0..s.len], s);
    len.* = s.len;
}

/// Installs the crash handlers. Call once, early in `main` (before the
/// runtime starts threads). Never allocates.
pub fn install(opts: Options) InstallError!void {
    if (!is_linux and !is_windows) return error.Unsupported;
    try copyInto(&crash_dir_buf, &crash_dir_len, opts.crash_dir);
    try copyInto(&product_buf, &product_len, opts.product);
    try copyInto(&install_kind_buf, &install_kind_len, opts.install_kind);
    announce = opts.announce;
    start_mono_ms = osl.cp_monoMs();
    try osl.installOs(opts);
    installed = true;
}

/// Reserves stack for the overflow handler on the calling thread
/// (Windows; a no-op elsewhere, where handlers run on the signal stack).
/// Call first thing on threads that should report their own overflows.
pub fn guardCurrentThread() void {
    if (is_windows) wx.guardCurrentThread();
}

/// Whether `install` succeeded.
pub fn isInstalled() bool {
    return installed;
}

/// `root.debug.handleSegfault` for both apps. On Linux it writes a report
/// and terminates with the original signal; elsewhere (Windows replaces
/// std's handler, see windows.zig) it falls back to std's default.
pub fn handleSegfault(addr: ?usize, name: []const u8, opt_ctx: ?CpuContextPtr) noreturn {
    if (is_linux) lx.handleSegfault(addr, name, opt_ctx) else std.debug.defaultHandleSegfault(addr, name, opt_ctx);
}

/// E00 crash hook: runs in normal context on the first panic.
pub fn onPanic(msg: []const u8, ret_addr: ?usize) void {
    const tid = osl.cp_tid();
    if (!cp_enter(tid)) return;
    defer cp_done();
    cp_write(&.{ .kind = .panic, .os_code = 0, .panic_msg = msg, .first_addr = ret_addr orelse @returnAddress(), .tid = tid });
}

// ---------------------------------------------------------------------------
// Capture

/// Takes the writer role for thread `tid`. False when a report is already
/// done or this thread re-entered; another thread waits up to 2 s for the
/// owner, then exits the process.
pub fn cp_enter(tid: u32) bool {
    if (!installed) return false;
    if (state.cmpxchgStrong(@intFromEnum(State.idle), @intFromEnum(State.writing), .acq_rel, .acquire) == null) {
        owner_tid.store(tid, .release);
        return true;
    }
    const deadline = osl.cp_monoMs() + 2000;
    while (state.load(.acquire) == @intFromEnum(State.writing)) {
        if (owner_tid.load(.acquire) == tid) return false;
        if (osl.cp_monoMs() > deadline) osl.cp_exit(osl.stuck_exit_status);
        osl.cp_yield();
    }
    return false;
}

/// Ends the writer role.
pub fn cp_done() void {
    state.store(@intFromEnum(State.done), .release);
}

const Regs = struct { pc: u64 = 0, sp: u64 = 0 };

fn cp_regs(ctx: ?CpuContextPtr) Regs {
    const c = ctx orelse return .{};
    return switch (builtin.cpu.arch) {
        .x86_64 => .{ .pc = c.gprs.get(.rip), .sp = c.gprs.get(.rsp) },
        .aarch64 => .{ .pc = c.pc, .sp = c.sp },
        else => .{},
    };
}

/// Appends `s` to `w` as ZON string contents, dropping quotes, backslashes
/// and control bytes.
fn cp_zonStr(w: *std.Io.Writer, s: []const u8) void {
    for (s) |c| {
        if (c < 0x20 or c == '"' or c == '\\' or c == 0x7f) continue;
        w.writeByte(c) catch return;
    }
}

fn cp_zonField(w: *std.Io.Writer, name: []const u8, value: []const u8) void {
    w.writeAll(" .") catch return;
    w.writeAll(name) catch return;
    w.writeAll(" = \"") catch return;
    cp_zonStr(w, value);
    w.writeAll("\",") catch return;
}

fn cp_zonInt(w: *std.Io.Writer, name: []const u8, v: u64) void {
    var d: [20]u8 = undefined;
    w.writeAll(" .") catch return;
    w.writeAll(name) catch return;
    w.writeAll(" = ") catch return;
    w.writeAll(cp_fmtDec(&d, v)) catch return;
    w.writeAll(",") catch return;
}

/// Formats `v` in decimal into `buf`.
pub fn cp_fmtDec(buf: []u8, v: u64) []const u8 {
    var tmp: [20]u8 = undefined;
    var i: usize = tmp.len;
    var x = v;
    while (true) {
        i -= 1;
        tmp[i] = @intCast('0' + x % 10);
        x /= 10;
        if (x == 0) break;
    }
    const n = @min(buf.len, tmp.len - i);
    @memcpy(buf[0..n], tmp[i..][0..n]);
    return buf[0..n];
}

fn cp_meta(kind: format.ReportKind, boot_pending: bool, pid: u32, mono_ms: i64) []const u8 {
    const bi = &zg_release.current;
    var w: std.Io.Writer = .fixed(&meta_buf);
    w.writeAll(".{") catch {};
    cp_zonField(&w, "product", product_buf[0..product_len]);
    cp_zonField(&w, "version", bi.version_string);
    cp_zonField(&w, "channel", @tagName(bi.channel));
    cp_zonField(&w, "commit", bi.commit);
    cp_zonField(&w, "target", bi.target);
    cp_zonField(&w, "optimize", @tagName(bi.optimize));
    cp_zonField(&w, "os_version", os_release_buf[0..os_release_len]);
    cp_zonInt(&w, "pid", pid);
    cp_zonInt(&w, "uptime_ms", @intCast(@max(0, mono_ms - start_mono_ms)));
    w.writeAll(if (boot_pending) " .boot_pending = true," else " .boot_pending = false,") catch {};
    cp_zonField(&w, "report_kind", cp_kindName(kind));
    cp_zonField(&w, "install_kind", install_kind_buf[0..install_kind_len]);
    w.writeAll(" }") catch {};
    return w.buffered();
}

fn cp_kindName(kind: format.ReportKind) []const u8 {
    return std.enums.tagName(format.ReportKind, kind) orelse "unknown";
}

/// A segfault within 64 KiB of the stack pointer is a stack overflow
/// (the guard page sits just below the stack mapping).
fn cp_isStackOverflow(fault: ?usize, sp: u64) bool {
    const f = fault orelse return false;
    if (sp == 0) return false;
    const d = if (f > sp) f - sp else sp - f;
    return d < 64 * 1024;
}

/// Writes one report for `c`. The caller holds the writer role
/// (`cp_enter`). Safe in a signal handler; failures end the report early.
pub fn cp_write(c: *const Crash) void {
    const now = osl.cp_nowMs();
    const pid = osl.cp_pid();
    const name = timefmt.reportName(name_buf[0..timefmt.max_name_len], now, pid);
    name_buf[name.len] = 0;
    var file = osl.cp_createReport(name) orelse return;
    var w: format.Writer = .{ .buf = &write_buf, .sink = osl.cp_reportSink(&file) };

    var regs = cp_regs(c.ctx);
    if (c.ctx == null) regs = .{ .pc = c.first_addr orelse 0, .sp = @frameAddress() };
    const kind: format.ReportKind = if (c.kind == .segfault and cp_isStackOverflow(c.fault, regs.sp)) .stack_overflow else c.kind;

    const n_ann = annotations.snapshot(&ann_pairs, &ann_storage);
    var boot_pending = false;
    for (ann_pairs[0..n_ann]) |p| {
        if (std.mem.eql(u8, p.key, "boot_pending") and std.mem.eql(u8, p.value, "1")) boot_pending = true;
    }

    w.begin(now);
    w.writeSection(.meta, cp_meta(kind, boot_pending, pid, osl.cp_monoMs()));
    {
        var s = w.section(.exception);
        s.writeStruct(format.Exception{
            .kind = @intFromEnum(kind),
            .os_code = c.os_code,
            .si_code = c.si_code,
            .has_fault_addr = @intFromBool(c.fault != null),
            .access = @intFromEnum(c.access),
            .fault_addr = c.fault orelse 0,
            .thread_id = c.tid,
            .pc = regs.pc,
            .sp = regs.sp,
        });
        s.end();
    }
    if (c.panic_msg) |m| w.writeSection(.panic_message, m);
    {
        var s = w.section(.annotations);
        annotations.encode(ann_pairs[0..n_ann], &s);
        s.end();
    }
    if (c.ctx) |ctx| {
        var s = w.section(.context);
        s.writeInt(u16, @intFromEnum(builtin.cpu.arch));
        s.writeInt(u16, @sizeOf(Native));
        s.write(std.mem.asBytes(ctx));
        s.end();
    }
    {
        const trace = c.trace orelse std.debug.captureCurrentStackTrace(.{
            .context = c.ctx,
            .first_address = if (c.ctx == null) c.first_addr else null,
            .allow_unsafe_unwind = true,
        }, &addr_buf);
        format.writeTrace(&w, trace.return_addresses, @intFromEnum(trace.skipped));
    }
    osl.cp_writeModules(&w);
    osl.cp_writeStack(&w, regs.sp, c);
    osl.cp_writeThreads(&w, c);
    w.finish();
    osl.cp_closeReport(&file);

    if (boot_pending) osl.cp_writeBootMarker(zg_release.current.version_string);
    if (announce) cp_announce(name);
}

/// Appends a STACK section copying `[start, end)`.
pub fn cp_stackSection(w: *format.Writer, start: usize, end: usize) void {
    if (end <= start) return;
    var s = w.section(.stack);
    s.writeInt(u64, start);
    s.write(@as([*]const u8, @ptrFromInt(start))[0 .. end - start]);
    s.end();
}

fn cp_announce(name: []const u8) void {
    var w: std.Io.Writer = .fixed(&msg_buf);
    w.writeAll(product_buf[0..product_len]) catch {};
    w.writeAll(": crashed; report written to ") catch {};
    w.writeAll(crash_dir_buf[0..crash_dir_len]) catch {};
    w.writeAll("/") catch {};
    w.writeAll(name) catch {};
    w.writeAll("\n") catch {};
    osl.cp_writeStderr(w.buffered());
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "capture: overflow heuristic, meta, decimal" {
    try testing.expect(cp_isStackOverflow(0x7ffd0000_0ff8, 0x7ffd0000_1000));
    try testing.expect(!cp_isStackOverflow(0x10, 0x7ffd0000_1000));
    try testing.expect(!cp_isStackOverflow(null, 0x7ffd0000_1000));

    try copyInto(&product_buf, &product_len, "zig\"guro");
    defer product_len = 0;
    const meta = cp_meta(.panic, true, 4242, start_mono_ms + 5);
    try testing.expect(std.mem.startsWith(u8, meta, ".{ .product = \"zigguro\","));
    try testing.expect(std.mem.indexOf(u8, meta, ".report_kind = \"panic\"") != null);
    try testing.expect(std.mem.indexOf(u8, meta, ".boot_pending = true") != null);
    try testing.expect(std.mem.indexOf(u8, meta, ".pid = 4242, .uptime_ms = 5,") != null);
    try testing.expect(std.mem.endsWith(u8, meta, " }"));
    var b: [20]u8 = undefined;
    try testing.expectEqualStrings("0", cp_fmtDec(&b, 0));
    try testing.expectEqualStrings("18446744073709551615", cp_fmtDec(&b, std.math.maxInt(u64)));
}

/// The OS functions a crash-path file may call: `<ns>.<name>(...)` with
/// `name` in `allow`.
const OsCalls = struct { ns: []const u8, allow: []const []const u8 };
const linux_calls: OsCalls = .{ .ns = "linux", .allow = &lx.crash_path_syscalls };
const win_calls: OsCalls = .{ .ns = "win", .allow = &win.crash_path_calls };

/// Walks every `cp_*` function in `source` and checks that it calls only
/// allowlisted OS functions and other `cp_*` functions of `source`, and
/// never names `std.Io`'s runtime, `std.log`, an allocator or a raw
/// kernel32/ntdll binding.
fn checkCrashPath(gpa: std.mem.Allocator, source: [:0]const u8, file: []const u8, os: OsCalls, verbose: bool) !void {
    var tree = try std.zig.Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);

    // Functions declared in this file.
    var local: std.StringHashMapUnmanaged(void) = .empty;
    defer local.deinit(gpa);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .fn_decl) continue;
        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, @enumFromInt(i)) orelse continue;
        const name_tok = proto.name_token orelse continue;
        try local.put(gpa, tree.tokenSlice(name_tok), {});
    }

    const tags = tree.tokens.items(.tag);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .fn_decl) continue;
        const node: std.zig.Ast.Node.Index = @enumFromInt(i);
        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, node) orelse continue;
        const fn_name = tree.tokenSlice(proto.name_token orelse continue);
        if (!std.mem.startsWith(u8, fn_name, "cp_")) continue;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        var t = first;
        while (t < last) : (t += 1) {
            if (tags[t] != .identifier) continue;
            const id = tree.tokenSlice(t);
            const forbidden = [_][]const u8{ "log", "Allocator", "Threaded", "kernel32", "ntdll" };
            if (for (forbidden) |f| {
                if (std.mem.eql(u8, id, f)) break true;
            } else false) {
                if (verbose) std.debug.print("{s}: {s} names {s}\n", .{ file, fn_name, id });
                return error.CrashPathViolation;
            }
            const is_call = t + 1 <= last and tags[t + 1] == .l_paren;
            if (!is_call) continue;
            const qualified = t >= 2 and tags[t - 1] == .period;
            if (qualified and tags[t - 2] == .identifier and std.mem.eql(u8, tree.tokenSlice(t - 2), os.ns)) {
                for (os.allow) |ok| {
                    if (std.mem.eql(u8, ok, id)) break;
                } else {
                    if (verbose) std.debug.print("{s}: {s} calls {s}.{s}\n", .{ file, fn_name, os.ns, id });
                    return error.CrashPathViolation;
                }
            } else if (!qualified and local.contains(id) and !std.mem.startsWith(u8, id, "cp_")) {
                if (verbose) std.debug.print("{s}: {s} calls non-crash-path {s}\n", .{ file, fn_name, id });
                return error.CrashPathViolation;
            }
        }
    }
}

test "crash path: syscall allowlist" {
    try checkCrashPath(testing.allocator, @embedFile("linux.zig"), "linux.zig", linux_calls, true);
    try checkCrashPath(testing.allocator, @embedFile("capture.zig"), "capture.zig", linux_calls, true);
    try checkCrashPath(testing.allocator, @embedFile("windows.zig"), "windows.zig", win_calls, true);
    try checkCrashPath(testing.allocator, @embedFile("pe.zig"), "pe.zig", win_calls, true);
    // The checker catches a violation.
    try testing.expectError(error.CrashPathViolation, checkCrashPath(testing.allocator,
        \\const linux = @import("std").os.linux;
        \\fn cp_bad() void { _ = linux.mmap(null, 0, 0, 0, -1, 0); }
    , "fixture", linux_calls, false));
    try testing.expectError(error.CrashPathViolation, checkCrashPath(testing.allocator,
        \\fn cp_bad() void { _ = win.HeapAlloc(null, 0, 16); }
    , "fixture", win_calls, false));
    try testing.expectError(error.CrashPathViolation, checkCrashPath(testing.allocator,
        \\fn cp_bad() void { _ = std.os.windows.kernel32.ExitProcess(0); }
    , "fixture", win_calls, false));
    try testing.expectError(error.CrashPathViolation, checkCrashPath(testing.allocator,
        \\fn helper() void {}
        \\fn cp_bad() void { helper(); }
    , "fixture", linux_calls, false));
}
