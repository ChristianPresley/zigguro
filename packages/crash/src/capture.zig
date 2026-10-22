//! Crash capture (E17.F05.S01.T02, Linux): `install`, the std segfault
//! hook, ABRT/TRAP/SYS handlers and the panic hook, all funnelling into
//! `cp_captureAndWrite`, which writes one `.zgcrash` with raw syscalls into
//! preallocated buffers.
//!
//! The crash path (`cp_*` here and in linux.zig) is checked by the
//! "crash path: syscall allowlist" test below.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_release = @import("zg_release");
const format = @import("format.zig");
const annotations = @import("annotations.zig");
const timefmt = @import("timefmt.zig");
const lx = @import("linux.zig");

const linux = std.os.linux;
const is_linux = builtin.os.tag == .linux;
const CpuContextPtr = std.debug.CpuContextPtr;
const Native = std.debug.cpu_context.Native;

/// Bytes of stack copied above the stack pointer.
pub const stack_window = 16 * 1024;
/// Bytes below the stack pointer (the x86_64 red zone).
pub const red_zone = 128;
pub const max_frames = 128;
pub const max_modules = 256;
pub const max_threads = 128;
pub const max_named_threads = 64;

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

pub const InstallError = error{ Unsupported, NameTooLong, CrashDirUnavailable };

const State = enum(u32) { idle = 0, writing = 1, done = 2 };

var state: std.atomic.Value(u32) = .init(@intFromEnum(State.idle));
var owner_tid: std.atomic.Value(u32) = .init(0);
var installed: bool = false;
var crash_dirfd: i32 = -1;
var state_dirfd: i32 = -1;
var announce: bool = true;
var start_mono_ms: i64 = 0;

var crash_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var crash_dir_len: usize = 0;
var product_buf: [32]u8 = undefined;
var product_len: usize = 0;
var install_kind_buf: [32]u8 = undefined;
var install_kind_len: usize = 0;
var os_release_buf: [64]u8 = undefined;
var os_release_len: usize = 0;

// Preallocated crash-time memory.
var write_buf: [256 * 1024]u8 align(8) = undefined;
var maps_buf: [128 * 1024]u8 = undefined;
var addr_buf: [max_frames]usize = undefined;
var modules: [max_modules]lx.ModuleSlot = undefined;
var tids: [max_threads]u32 = undefined;
var dirent_buf: [8 * 1024]u8 align(8) = undefined;
var ann_pairs: [annotations.max_keys]annotations.Pair = undefined;
var ann_storage: annotations.SnapshotStorage = .{};
var meta_buf: [1024]u8 = undefined;
var name_buf: [timefmt.max_name_len + 1]u8 = undefined;
var comm_buf: [16]u8 = undefined;
var msg_buf: [std.fs.max_path_bytes + 128]u8 = undefined;

fn copyInto(buf: []u8, len: *usize, s: []const u8) InstallError!void {
    if (s.len > buf.len) return error.NameTooLong;
    @memcpy(buf[0..s.len], s);
    len.* = s.len;
}

/// Installs the crash handlers. Call once, early in `main` (before the
/// runtime starts threads). Not async-signal-safe; never allocates.
pub fn install(opts: Options) InstallError!void {
    if (!is_linux) return error.Unsupported;
    try copyInto(&crash_dir_buf, &crash_dir_len, opts.crash_dir);
    try copyInto(&product_buf, &product_len, opts.product);
    try copyInto(&install_kind_buf, &install_kind_len, opts.install_kind);
    announce = opts.announce;
    crash_dirfd = try openDirP(opts.crash_dir);
    if (opts.state_dir) |sd| {
        state_dirfd = openDirP(sd) catch -1;
        // The boot marker's directory must exist before a crash.
        if (state_dirfd >= 0) _ = linux.mkdirat(state_dirfd, "update", 0o700);
    }
    const rel = lx.cp_readFile(linux.AT.FDCWD, "/proc/sys/kernel/osrelease", &os_release_buf);
    os_release_len = std.mem.trimEnd(u8, rel, "\n").len;
    start_mono_ms = lx.cp_monoMs();

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
    zg_core.report.setCrashHook(onPanic);
    installed = true;
}

/// `mkdir -p` then open as a directory fd.
fn openDirP(path: []const u8) InstallError!i32 {
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
    return lx.cp_open(linux.AT.FDCWD, @ptrCast(&z), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0) orelse
        error.CrashDirUnavailable;
}

/// Whether `install` succeeded.
pub fn isInstalled() bool {
    return installed;
}

// ---------------------------------------------------------------------------
// Hooks

/// `root.debug.handleSegfault` for both apps (SEGV/ILL/BUS/FPE on Linux,
/// vectored exceptions on Windows). Writes a report, then terminates
/// with the original signal.
pub fn handleSegfault(addr: ?usize, name: []const u8, opt_ctx: ?CpuContextPtr) noreturn {
    if (!is_linux) std.debug.defaultHandleSegfault(addr, name, opt_ctx);
    if (!installed) std.debug.defaultHandleSegfault(addr, name, opt_ctx);
    std.Options.debug_io.vtable.crashHandler(std.Options.debug_io.userdata);
    const c = cp_classify(name);
    cp_captureAndWrite(c.kind, @intFromEnum(c.sig), 0, addr, opt_ctx, null, null);
    lx.cp_reraise(c.sig);
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
    cp_captureAndWrite(kind, @intFromEnum(sig), info.code, null, if (ctx) |*c| c else null, null, null);
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
    cp_captureAndWrite(kind, @intFromEnum(sig), info.code, fault, if (ctx) |*c| c else null, null, null);
    lx.cp_reraise(sig);
}

/// E00 crash hook: runs in normal context on the first panic.
fn onPanic(msg: []const u8, ret_addr: ?usize) void {
    cp_captureAndWrite(.panic, 0, 0, null, null, msg, ret_addr orelse @returnAddress());
}

// ---------------------------------------------------------------------------
// Capture

/// Takes the writer role. False when another report is done or this thread
/// re-entered; a second thread waits up to 2 s for the owner, then exits.
fn cp_enter() bool {
    const tid = lx.cp_tid();
    if (state.cmpxchgStrong(@intFromEnum(State.idle), @intFromEnum(State.writing), .acq_rel, .acquire) == null) {
        owner_tid.store(tid, .release);
        return true;
    }
    const deadline = lx.cp_monoMs() + 2000;
    while (state.load(.acquire) == @intFromEnum(State.writing)) {
        if (owner_tid.load(.acquire) == tid) return false;
        if (lx.cp_monoMs() > deadline) lx.cp_exit(lx.stuck_exit_status);
        lx.cp_yield();
    }
    return false;
}

const FdSink = struct {
    fd: i32,

    fn cp_write(ctx: *anyopaque, bytes: []const u8) bool {
        const s: *FdSink = @ptrCast(@alignCast(ctx));
        return lx.cp_writeAll(s.fd, bytes);
    }

    fn cp_sync(ctx: *anyopaque) void {
        const s: *FdSink = @ptrCast(@alignCast(ctx));
        lx.cp_fsync(s.fd);
    }
};

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
    w.writeAll(lx.cp_fmtDec(&d, v)) catch return;
    w.writeAll(",") catch return;
}

fn cp_meta(kind: format.ReportKind, boot_pending: bool) []const u8 {
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
    cp_zonInt(&w, "pid", lx.cp_pid());
    cp_zonInt(&w, "uptime_ms", @intCast(@max(0, lx.cp_monoMs() - start_mono_ms)));
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

/// Writes one report. Safe to call from a signal handler; any failure just
/// ends the report early.
pub fn cp_captureAndWrite(
    kind_in: format.ReportKind,
    os_code: u32,
    si_code: i32,
    fault: ?usize,
    ctx: ?CpuContextPtr,
    panic_msg: ?[]const u8,
    first_addr: ?usize,
) void {
    if (!is_linux) return;
    if (!installed or !cp_enter()) return;
    defer state.store(@intFromEnum(State.done), .release);

    const now = lx.cp_nowMs();
    const name = timefmt.reportName(name_buf[0..timefmt.max_name_len], now, lx.cp_pid());
    name_buf[name.len] = 0;
    const fd = lx.cp_open(crash_dirfd, @ptrCast(&name_buf), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600) orelse return;
    var sink_state: FdSink = .{ .fd = fd };
    var w: format.Writer = .{ .buf = &write_buf, .sink = .{ .ctx = &sink_state, .write = FdSink.cp_write, .sync = FdSink.cp_sync } };

    var regs = cp_regs(ctx);
    if (ctx == null) {
        regs = .{ .pc = first_addr orelse 0, .sp = @frameAddress() };
    }
    const kind: format.ReportKind = if (kind_in == .segfault and cp_isStackOverflow(fault, regs.sp)) .stack_overflow else kind_in;

    const n_ann = annotations.snapshot(&ann_pairs, &ann_storage);
    var boot_pending = false;
    for (ann_pairs[0..n_ann]) |p| {
        if (std.mem.eql(u8, p.key, "boot_pending") and std.mem.eql(u8, p.value, "1")) boot_pending = true;
    }

    w.begin(now);
    w.writeSection(.meta, cp_meta(kind, boot_pending));
    {
        var s = w.section(.exception);
        s.writeStruct(format.Exception{
            .kind = @intFromEnum(kind),
            .os_code = os_code,
            .si_code = si_code,
            .has_fault_addr = @intFromBool(fault != null),
            .access = @intFromEnum(format.Access.none),
            .fault_addr = fault orelse 0,
            .thread_id = lx.cp_tid(),
            .pc = regs.pc,
            .sp = regs.sp,
        });
        s.end();
    }
    if (panic_msg) |m| w.writeSection(.panic_message, m);
    {
        var s = w.section(.annotations);
        annotations.encode(ann_pairs[0..n_ann], &s);
        s.end();
    }
    if (ctx) |c| {
        var s = w.section(.context);
        s.writeInt(u16, @intFromEnum(builtin.cpu.arch));
        s.writeInt(u16, @sizeOf(Native));
        s.write(std.mem.asBytes(c));
        s.end();
    }
    {
        const trace = std.debug.captureCurrentStackTrace(.{
            .context = ctx,
            .first_address = if (ctx == null) first_addr else null,
            .allow_unsafe_unwind = true,
        }, &addr_buf);
        format.writeTrace(&w, trace.return_addresses, @intFromEnum(trace.skipped));
    }

    const maps = lx.cp_readFile(linux.AT.FDCWD, "/proc/self/maps", &maps_buf);
    cp_writeModules(&w, maps);
    cp_writeStack(&w, maps, regs.sp);
    cp_writeThreads(&w);
    w.finish();
    lx.cp_close(fd);

    if (boot_pending) cp_writeBootMarker();
    if (announce) cp_announce(name);
}

fn cp_writeModules(w: *format.Writer, maps: []const u8) void {
    const n = lx.cp_collectModules(maps, &modules);
    var s = w.section(.modules);
    s.writeInt(u32, @intCast(n));
    s.writeInt(u32, 0);
    for (modules[0..n]) |*m| {
        const is_vdso = std.mem.eql(u8, m.path, "[vdso]");
        const id: ?[]const u8 = if (is_vdso or !m.have_base or !m.base_readable) null else lx.cp_buildIdFromMemory(m.base, m.base_map_end);
        const path = m.path[0..@min(m.path.len, std.math.maxInt(u16))];
        format.writeModule(&s, .{
            .base = m.base,
            .size = m.end - m.base,
            .id_kind = if (id != null) .gnu_build_id else .none,
            .id = id orelse "",
            .path = path,
        });
    }
    s.end();
}

fn cp_writeStack(w: *format.Writer, maps: []const u8, sp: u64) void {
    if (sp == 0) return;
    const m = lx.cp_findMapping(maps, @intCast(sp)) orelse return;
    if (!m.readable) return;
    const start = @max(m.start, @as(usize, @intCast(sp)) -| red_zone);
    const end = @min(m.end, @as(usize, @intCast(sp)) +| stack_window);
    if (end <= start) return;
    var s = w.section(.stack);
    s.writeInt(u64, start);
    s.write(@as([*]const u8, @ptrFromInt(start))[0 .. end - start]);
    s.end();
}

fn cp_writeThreads(w: *format.Writer) void {
    const n = lx.cp_listThreads(&dirent_buf, &tids);
    var s = w.section(.threads);
    s.writeInt(u32, @intCast(n));
    s.writeInt(u32, 0);
    for (tids[0..n], 0..) |tid, i| {
        const name = if (i < max_named_threads) lx.cp_threadName(tid, &comm_buf) else "";
        s.writeInt(u64, tid);
        s.write(&.{@intCast(name.len)});
        s.write(name);
        s.alignData();
    }
    s.end();
}

fn cp_writeBootMarker() void {
    if (state_dirfd < 0) return;
    const fd = lx.cp_open(state_dirfd, "update/boot-crashed", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600) orelse return;
    _ = lx.cp_writeAll(fd, zg_release.current.version_string);
    lx.cp_fsync(fd);
    lx.cp_close(fd);
}

fn cp_announce(name: []const u8) void {
    var w: std.Io.Writer = .fixed(&msg_buf);
    w.writeAll(product_buf[0..product_len]) catch {};
    w.writeAll(": crashed; report written to ") catch {};
    w.writeAll(crash_dir_buf[0..crash_dir_len]) catch {};
    w.writeAll("/") catch {};
    w.writeAll(name) catch {};
    w.writeAll("\n") catch {};
    _ = lx.cp_writeAll(2, w.buffered());
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "capture: classify, overflow heuristic, meta" {
    try testing.expectEqual(format.ReportKind.segfault, cp_classify("General protection exception").kind);
    try testing.expectEqual(linux.SIG.FPE, cp_classify("Arithmetic exception").sig);
    try testing.expect(cp_isStackOverflow(0x7ffd0000_0ff8, 0x7ffd0000_1000));
    try testing.expect(!cp_isStackOverflow(0x10, 0x7ffd0000_1000));
    try testing.expect(!cp_isStackOverflow(null, 0x7ffd0000_1000));

    try copyInto(&product_buf, &product_len, "zig\"guro");
    defer product_len = 0;
    const meta = cp_meta(.panic, true);
    try testing.expect(std.mem.startsWith(u8, meta, ".{ .product = \"zigguro\","));
    try testing.expect(std.mem.indexOf(u8, meta, ".report_kind = \"panic\"") != null);
    try testing.expect(std.mem.indexOf(u8, meta, ".boot_pending = true") != null);
    try testing.expect(std.mem.endsWith(u8, meta, " }"));
}

/// Walks every `cp_*` function in `source` and checks that it calls only
/// allowlisted `linux.*` functions and other `cp_*` functions of `source`,
/// and never names `std.Io`'s runtime, `std.log` or an allocator.
fn checkCrashPath(gpa: std.mem.Allocator, source: [:0]const u8, file: []const u8, verbose: bool) !void {
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
            if (std.mem.eql(u8, id, "log") or std.mem.eql(u8, id, "Allocator") or std.mem.eql(u8, id, "Threaded")) {
                if (verbose) std.debug.print("{s}: {s} names {s}\n", .{ file, fn_name, id });
                return error.CrashPathViolation;
            }
            const is_call = t + 1 <= last and tags[t + 1] == .l_paren;
            if (!is_call) continue;
            const qualified = t >= 2 and tags[t - 1] == .period;
            if (qualified and tags[t - 2] == .identifier and std.mem.eql(u8, tree.tokenSlice(t - 2), "linux")) {
                for (lx.crash_path_syscalls) |ok| {
                    if (std.mem.eql(u8, ok, id)) break;
                } else {
                    if (verbose) std.debug.print("{s}: {s} calls linux.{s}\n", .{ file, fn_name, id });
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
    try checkCrashPath(testing.allocator, @embedFile("linux.zig"), "linux.zig", true);
    try checkCrashPath(testing.allocator, @embedFile("capture.zig"), "capture.zig", true);
    // The checker catches a violation.
    try testing.expectError(error.CrashPathViolation, checkCrashPath(testing.allocator,
        \\const linux = @import("std").os.linux;
        \\fn cp_bad() void { _ = linux.mmap(null, 0, 0, 0, -1, 0); }
    , "fixture", false));
    try testing.expectError(error.CrashPathViolation, checkCrashPath(testing.allocator,
        \\fn helper() void {}
        \\fn cp_bad() void { helper(); }
    , "fixture", false));
}
