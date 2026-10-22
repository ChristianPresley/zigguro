//! The workbench's terminal panel until E06's session layer (F01) lands:
//! one shell on a PTY (Linux), shown through `zg_terminal_view`.
//!
//! A worker reads the PTY and queues output under a mutex, posting one
//! drain to the UI thread at a time; the UI thread feeds the terminal.
//! Input goes straight to the PTY from the UI thread. Elsewhere the panel
//! shows why no shell started (ConPTY arrives with #267).

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_platform = @import("zg_platform");
const zg_terminal = @import("zg_terminal");
const zg_terminal_view = @import("zg_terminal_view");

const Pty = zg_platform.process.Pty;
const TerminalView = zg_terminal_view.TerminalView;

/// See the module doc.
pub const TerminalPanel = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: *zg_gui.App,
    env: *const std.process.Environ.Map,
    term: zg_terminal.Terminal,
    view: TerminalView,
    pty: ?Pty = null,
    /// Guards `pending`.
    mutex: std.Io.Mutex = .init,
    pending: std.ArrayList(u8) = .empty,
    /// A drain is queued on the UI thread.
    posted: std.atomic.Value(bool) = .init(false),
    /// Tells the reader to stop.
    stop: std.atomic.Value(bool) = .init(false),
    /// The child side closed.
    ended: std.atomic.Value(bool) = .init(false),
    /// Set once torn down; drains still queued then do nothing.
    closed: bool = false,
    /// Why no shell runs, or how it ended (shown in the panel header).
    note: [96]u8 = undefined,
    note_len: usize = 0,
    /// Called after output arrives (the workbench repaints).
    on_output: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void } = null,

    /// A panel with an 80x24 terminal; `start` spawns the shell.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, app: *zg_gui.App, env: *const std.process.Environ.Map) !*TerminalPanel {
        const p = try gpa.create(TerminalPanel);
        errdefer gpa.destroy(p);
        p.* = .{ .gpa = gpa, .io = io, .app = app, .env = env, .term = undefined, .view = undefined };
        p.term = try .init(gpa, .{ .cols = 80, .rows = 24 });
        p.view = .init(gpa, &p.term, .{});
        p.view.sink = .{ .ctx = p, .write = write };
        p.view.on_resize = .{ .ctx = p, .f = onResize };
        return p;
    }

    /// Stops the reader, ends the shell and frees everything.
    pub fn destroy(p: *TerminalPanel) void {
        p.stop.store(true, .release);
        if (p.pty) |*pty| pty.kill(.hangup);
        // The reader polls `stop` every 50 ms.
        p.app.joinWork();
        if (p.pty) |*pty| {
            _ = pty.tryWait() catch {};
            pty.close();
        }
        p.closed = true;
        p.pending.deinit(p.gpa);
        p.view.deinit();
        p.term.deinit();
        p.gpa.destroy(p);
    }

    fn setNote(p: *TerminalPanel, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&p.note, fmt, args) catch p.note[0..0];
        p.note_len = s.len;
    }

    /// What the header shows next to the title.
    pub fn noteText(p: *const TerminalPanel) []const u8 {
        return p.note[0..p.note_len];
    }

    /// Spawns `$SHELL` (or /bin/sh) on a PTY and starts reading it.
    pub fn start(p: *TerminalPanel) void {
        if (p.pty != null) return;
        const shell = p.env.get("SHELL") orelse "/bin/sh";
        const argv = [_][]const u8{shell};
        p.pty = Pty.spawn(p.gpa, p.io, .{
            .argv = &argv,
            .env = p.env,
            .size = .{ .cols = p.term.cols(), .rows = p.term.rows() },
        }) catch |e| {
            p.setNote("no shell: {t}", .{e});
            return;
        };
        p.note_len = 0;
        p.app.spawn(readLoop, .{p});
    }

    fn readLoop(p: *TerminalPanel) void {
        var buf: [64 << 10]u8 = undefined;
        const pty = &p.pty.?;
        while (!p.stop.load(.acquire)) {
            if (!pty.waitReadable(50 * std.time.ns_per_ms)) continue;
            const n = pty.read(&buf) catch |e| switch (e) {
                error.WouldBlock => continue,
                else => 0,
            };
            if (n == 0) p.ended.store(true, .release);
            if (n > 0) {
                p.mutex.lockUncancelable(p.io);
                defer p.mutex.unlock(p.io);
                p.pending.appendSlice(p.gpa, buf[0..n]) catch {};
            }
            if (!p.posted.swap(true, .acq_rel)) p.app.post(.{ .ctx = p, .f = drain }) catch p.posted.store(false, .release);
            if (n == 0) return;
        }
    }

    fn drain(ctx: *anyopaque, _: *zg_gui.App) void {
        const p: *TerminalPanel = @ptrCast(@alignCast(ctx));
        if (p.closed) return;
        p.posted.store(false, .release);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(p.gpa);
        {
            p.mutex.lockUncancelable(p.io);
            defer p.mutex.unlock(p.io);
            std.mem.swap(std.ArrayList(u8), &bytes, &p.pending);
        }
        if (bytes.items.len > 0) p.view.feed(bytes.items);
        if (p.ended.load(.acquire) and p.note_len == 0) {
            const status = if (p.pty) |*pty| (pty.tryWait() catch null) else null;
            if (status) |s| switch (s) {
                .exited => |c| p.setNote("shell exited ({d})", .{c}),
                .signaled => |sig| p.setNote("shell killed (signal {d})", .{sig}),
            } else p.setNote("shell exited", .{});
        }
        if (p.on_output) |h| h.f(h.ctx);
    }

    fn write(ctx: *anyopaque, bytes: []const u8) void {
        const p: *TerminalPanel = @ptrCast(@alignCast(ctx));
        const pty = &(p.pty orelse return);
        var i: usize = 0;
        var spins: u32 = 0;
        while (i < bytes.len and spins < 1000) {
            const n = pty.write(bytes[i..]) catch |e| switch (e) {
                error.WouldBlock => {
                    spins += 1;
                    std.atomic.spinLoopHint();
                    continue;
                },
                else => return,
            };
            i += n;
        }
    }

    fn onResize(ctx: *anyopaque, cols: u16, rows: u16, px_w: u16, px_h: u16) void {
        const p: *TerminalPanel = @ptrCast(@alignCast(ctx));
        if (p.pty) |*pty| pty.resize(.{ .cols = cols, .rows = rows, .px_w = px_w, .px_h = px_h }) catch {};
    }
};
