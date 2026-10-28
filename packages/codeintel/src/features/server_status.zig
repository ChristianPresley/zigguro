//! What the language servers are doing, for the status bar and the
//! server commands (E07.F01.S02.T06): each server's state and its latest
//! work-done progress (`$/progress`, followed through the manager's
//! `ProgressTracker`), a status label (`zls ✓`, `zls: indexing 42%`,
//! `zls ✗ restarting in 3 s`), the servers of a document (missing and
//! disabled ones included, so the user sees why nothing answers), a
//! details report and a logs report (stderr tail and protocol trace).
//!
//! Progress arrives on reader threads and is kept under a mutex; the UI
//! reads it when it builds. `generation` changes with every event, and
//! the waker is asked at most 10 times a second.

const ServerStatus = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");

const protocol = zg_lsp.protocol;
const progress = zg_lsp.client.progress;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const Server = Manager.Server;

/// One running piece of work-done progress.
pub const Progress = struct {
    title: []const u8 = "",
    message: []const u8 = "",
    percentage: ?u32 = null,
    cancellable: bool = false,
};

const Active = struct {
    server: u32,
    token: protocol.ProgressToken,
    /// Owned: the token string, title, message.
    strings: std.heap.ArenaAllocator,
    p: Progress,
};

gpa: Allocator,
io: Io,
mgr: *Manager,
waker: zg_core.runtime.Waker,
mutex: Io.Mutex = .init,
active: std.ArrayList(Active) = .empty,
generation: std.atomic.Value(u64) = .init(0),
last_wake_ns: i96 = 0,
/// More lines for `details` (ZLS's toolchain and build-on-save).
extra_details: ?DetailsHook = null,

pub const DetailsHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, s: *const Server, w: *Io.Writer) Io.Writer.Error!void,
};

/// `st` must not move (it listens to the manager's progress).
pub fn init(st: *ServerStatus, mgr: *Manager, waker: zg_core.runtime.Waker) !void {
    st.* = .{ .gpa = mgr.gpa, .io = mgr.rt.io, .mgr = mgr, .waker = waker };
    try mgr.progress.subscribe(.{ .ctx = st, .func = onProgress });
}

/// After `Manager.deinit`.
pub fn deinit(st: *ServerStatus) void {
    for (st.active.items) |*a| a.strings.deinit();
    st.active.deinit(st.gpa);
}

pub fn gen(st: *const ServerStatus) u64 {
    return st.generation.load(.acquire);
}

fn sameToken(a: protocol.ProgressToken, b: protocol.ProgressToken) bool {
    return switch (a) {
        .integer => |x| b == .integer and b.integer == x,
        .string => |x| b == .string and std.mem.eql(u8, b.string, x),
    };
}

// Reader threads.
fn onProgress(ctx: ?*anyopaque, e: progress.ProgressEvent) void {
    const st: *ServerStatus = @ptrCast(@alignCast(ctx.?));
    const wake = blk: {
        st.mutex.lockUncancelable(st.io);
        defer st.mutex.unlock(st.io);
        const i = for (st.active.items, 0..) |a, k| {
            if (a.server == e.server and sameToken(a.token, e.token)) break k;
        } else null;
        if (e.kind == .end) {
            if (i) |k| {
                st.active.items[k].strings.deinit();
                _ = st.active.orderedRemove(k);
            }
        } else st.update(i, e) catch {};
        const now = Io.Clock.Timestamp.now(st.io, .awake).raw.nanoseconds;
        if (now - st.last_wake_ns < 100 * std.time.ns_per_ms and e.kind == .report) break :blk false;
        st.last_wake_ns = now;
        break :blk true;
    };
    _ = st.generation.fetchAdd(1, .release);
    if (wake) st.waker.wake();
}

fn update(st: *ServerStatus, i: ?usize, e: progress.ProgressEvent) !void {
    var a: Active = if (i) |k| st.active.items[k] else .{
        .server = e.server,
        .token = e.token,
        .strings = .init(st.gpa),
        .p = .{},
    };
    const al = a.strings.allocator();
    if (i == null) {
        errdefer a.strings.deinit();
        a.token = switch (e.token) {
            .integer => e.token,
            .string => |s| .{ .string = try al.dupe(u8, s) },
        };
        if (e.title) |t| a.p.title = try al.dupe(u8, t);
        a.p.cancellable = e.cancellable orelse false;
    }
    // A report repeats nothing it leaves out.
    if (e.message) |m| a.p.message = try al.dupe(u8, m);
    if (e.percentage) |pc| a.p.percentage = @min(pc, 100);
    if (e.cancellable) |c| a.p.cancellable = c;
    if (i) |k| st.active.items[k] = a else try st.active.append(st.gpa, a);
}

/// The latest progress of `server`, copied into `buf` (title, then
/// message).
pub fn progressOf(st: *ServerStatus, server: u32, buf: []u8) ?Progress {
    st.mutex.lockUncancelable(st.io);
    defer st.mutex.unlock(st.io);
    var i = st.active.items.len;
    while (i > 0) {
        i -= 1;
        const a = st.active.items[i];
        if (a.server != server) continue;
        const tl = @min(a.p.title.len, buf.len);
        @memcpy(buf[0..tl], a.p.title[0..tl]);
        const ml = @min(a.p.message.len, buf.len - tl);
        @memcpy(buf[tl..][0..ml], a.p.message[0..ml]);
        return .{ .title = buf[0..tl], .message = buf[tl..][0..ml], .percentage = a.p.percentage, .cancellable = a.p.cancellable };
    }
    return null;
}

/// Cancels `server`'s latest cancellable progress; false when there is
/// none.
pub fn cancelProgress(st: *ServerStatus, server: u32) bool {
    var tok_buf: [256]u8 = undefined;
    const tok: protocol.ProgressToken = blk: {
        st.mutex.lockUncancelable(st.io);
        defer st.mutex.unlock(st.io);
        var i = st.active.items.len;
        while (i > 0) {
            i -= 1;
            const a = st.active.items[i];
            if (a.server != server or !a.p.cancellable) continue;
            break :blk switch (a.token) {
                .integer => a.token,
                .string => |s| if (s.len <= tok_buf.len) str: {
                    @memcpy(tok_buf[0..s.len], s);
                    break :str .{ .string = tok_buf[0..s.len] };
                } else return false,
            };
        }
        return false;
    };
    st.mgr.progress.cancel(server, tok);
    return true;
}

/// The servers for `h`: those it is attached to, and those of its
/// language that are missing, failed, stopped or disabled (one per
/// definition), in start order.
pub fn serversOf(st: *const ServerStatus, h: DocHandle, out: []*Server) usize {
    const match = st.mgr.docMatch(h);
    var n: usize = 0;
    for (st.mgr.serverList()) |s| {
        if (n == out.len) break;
        const mine = s.hasDoc(h) or if (match) |mt| handles(s, mt.language_id) else false;
        if (!mine) continue;
        // One entry per definition: the one with the document wins.
        const dup = for (out[0..n]) |o| {
            if (o.def == s.def) break true;
        } else false;
        if (dup) continue;
        out[n] = s;
        n += 1;
    }
    return n;
}

fn handles(s: *const Server, language: []const u8) bool {
    for (s.def.languages) |l| if (std.mem.eql(u8, l, language)) return true;
    return false;
}

/// The short status of `s` for the status bar.
pub fn label(st: *ServerStatus, s: *const Server, buf: []u8) []const u8 {
    const name = s.def.id;
    var pb: [160]u8 = undefined;
    return switch (s.status) {
        .running => if (st.progressOf(s.id, &pb)) |p| (if (p.percentage) |pc|
            std.fmt.bufPrint(buf, "{s}: {s} {d: >3}%", .{ name, progressText(p), pc })
        else
            std.fmt.bufPrint(buf, "{s}: {s}", .{ name, progressText(p) })) else std.fmt.bufPrint(buf, "{s} \u{2713}", .{name}),
        .starting => std.fmt.bufPrint(buf, "{s}: starting\u{2026}", .{name}),
        .crashed => if (s.restart_due_ns) |due| std.fmt.bufPrint(buf, "{s} \u{2717} restarting in {d} s", .{ name, secondsUntil(st.io, due) }) else std.fmt.bufPrint(buf, "{s} \u{2717}", .{name}),
        .failed => std.fmt.bufPrint(buf, "{s} \u{2717}", .{name}),
        .disabled => std.fmt.bufPrint(buf, "{s} \u{2298}", .{name}),
        .stopped => std.fmt.bufPrint(buf, "{s}: stopped", .{name}),
        .missing => std.fmt.bufPrint(buf, "{s}: not installed", .{name}),
    } catch name;
}

fn progressText(p: Progress) []const u8 {
    return if (p.title.len > 0) p.title else if (p.message.len > 0) p.message else "working";
}

fn secondsUntil(io: Io, due: i96) u64 {
    const now = Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    if (due <= now) return 0;
    return @intCast(@divFloor(due - now + std.time.ns_per_s - 1, std.time.ns_per_s));
}

/// A longer explanation of the state (tooltip, notices).
pub fn explain(s: *const Server, buf: []u8) []const u8 {
    return switch (s.status) {
        .running => std.fmt.bufPrint(buf, "{s} is running: click for server commands", .{s.def.id}),
        .starting => std.fmt.bufPrint(buf, "{s} is starting", .{s.def.id}),
        .crashed => std.fmt.bufPrint(buf, "{s} crashed ({d} time{s}); it restarts on its own", .{ s.def.id, s.crashes, if (s.crashes == 1) "" else "s" }),
        .failed => std.fmt.bufPrint(buf, "{s} failed to start: {s}", .{ s.def.id, if (s.err) |e| @errorName(e) else "unknown error" }),
        .disabled => std.fmt.bufPrint(buf, "{s} crashed {d} times and is disabled: Enable Language Server starts it again", .{ s.def.id, s.crashes }),
        .stopped => std.fmt.bufPrint(buf, "{s} was stopped: Restart Language Server starts it again", .{s.def.id}),
        .missing => std.fmt.bufPrint(buf, "{s} is not installed: {s}", .{ s.def.id, s.def.install_hint }),
    } catch s.def.id;
}

/// The details report of `s` (executable, roots, negotiated settings,
/// uptime, crashes).
pub fn details(st: *ServerStatus, s: *const Server, w: *Io.Writer) Io.Writer.Error!void {
    var b: [256]u8 = undefined;
    try w.print("{s}\n\nState: {s}\n", .{ s.def.id, explain(s, &b) });
    try w.print("Executable: {s}\n", .{if (s.exe.len > 0) s.exe else "(not found)"});
    try w.writeAll("Command:");
    for (s.def.command, 0..) |arg, i| try w.print(" {s}", .{if (i == 0 and s.exe.len > 0) s.exe else arg});
    try w.print("\nRoot: {s}\nLanguages:", .{if (s.root.len > 0) s.root else "(none)"});
    for (s.def.languages) |l| try w.print(" {s}", .{l});
    try w.print("\nCrashes: {d}\n", .{s.crashes});
    if (s.status == .running) if (s.client) |c| {
        if (c.serverInfo()) |si| try w.print("Server: {s} {s}\n", .{ si.name, si.version orelse "" });
        const now = Io.Clock.Timestamp.now(st.io, .awake).raw.nanoseconds;
        try w.print("Uptime: {d} s\n", .{@divFloor(now - s.ready_ns, std.time.ns_per_s)});
        try w.print("Position encoding: {t}\n", .{c.encoding()});
        if (c.caps()) |caps| {
            try w.print("Text sync: {t}\n", .{caps.sync_kind});
            try w.print("Dynamic registrations: {d}\n", .{caps.registrations.items.len});
        }
        try w.print("Documents: {d}\n", .{s.docs.items.len});
        if (s.too_large.items.len > 0) try w.print("Not synced (larger than lsp.maxFileSize): {d}\n", .{s.too_large.items.len});
        var pb: [160]u8 = undefined;
        if (st.progressOf(s.id, &pb)) |p| try w.print("Progress: {s} {s}\n", .{ p.title, p.message });
    };
    if (st.extra_details) |x| try x.f(x.ctx, s, w);
    if (s.status == .missing and s.def.install_hint.len > 0) try w.print("\nInstall: {s}\n", .{s.def.install_hint});
}

/// The logs report of `s`: the stderr tail (or the one kept at the last
/// crash) and the protocol trace.
pub fn logs(st: *ServerStatus, s: *Server, w: *Io.Writer) !void {
    try w.print("{s}: stderr\n\n", .{s.def.id});
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(st.gpa);
    if (s.status == .running) if (s.proc) |p| try p.stderrTail(&tail, 10_000);
    const text = if (tail.items.len > 0) tail.items else s.crash_log.items;
    try w.writeAll(if (text.len > 0) text else "(nothing)\n");
    if (text.len > 0 and text[text.len - 1] != '\n') try w.writeByte('\n');
    if (s.status != .running) return;
    const c = s.client orelse return;
    try w.print("\n{s}: protocol trace\n\n", .{s.def.id});
    var arena: std.heap.ArenaAllocator = .init(st.gpa);
    defer arena.deinit();
    try c.traceRing().dump(arena.allocator(), w);
}
