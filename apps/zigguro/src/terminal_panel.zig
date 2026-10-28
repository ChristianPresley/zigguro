//! The workbench's terminal panel until E06's session layer (F01) lands:
//! one shell on a PTY (Linux), shown through `zg_terminal_view`.
//!
//! A worker reads the PTY and queues output under a mutex, posting one
//! drain to the UI thread at a time; the UI thread feeds the terminal.
//! Input goes straight to the PTY from the UI thread. Elsewhere the panel
//! shows why no shell started (ConPTY arrives with #267).
//!
//! Old scrollback is compacted (and deflated) on a worker: the UI thread
//! only copies the rows out and swaps the result in (`zg_terminal`'s
//! `Compactor`).
//!
//! Shells zigguro has scripts for (bash, zsh, fish, PowerShell, cmd) start
//! with them loaded, so their prompts and commands become command blocks
//! (`zg_terminal.shell`).
//!
//! Several panels live side by side (E06.F07), so a panel waits only for
//! its own workers when torn down, and a drain still queued then reaches
//! a ref-counted `Poster` that outlives the panel instead of the panel.

const std = @import("std");
const builtin = @import("builtin");
const zg_gui = @import("zg_gui");
const zg_platform = @import("zg_platform");
const zg_terminal = @import("zg_terminal");
const zg_terminal_view = @import("zg_terminal_view");

const Pty = zg_platform.process.Pty;
const inject = zg_terminal.shell.inject;
const TerminalView = zg_terminal_view.TerminalView;

/// See the module doc.
pub const TerminalPanel = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: *zg_gui.App,
    env: *const std.process.Environ.Map,
    term: zg_terminal.Terminal,
    view: TerminalView,
    /// The find bar shown over this terminal.
    find: zg_terminal_view.find_bar.FindBar,
    compactor: zg_terminal.term.Compactor = .{},
    pty: ?Pty = null,
    /// Guards `pending`.
    mutex: std.Io.Mutex = .init,
    pending: std.ArrayList(u8) = .empty,
    /// Where drains are posted; outlives the panel while one is queued.
    poster: *Poster = undefined,
    /// Workers running for this panel; `idle` is set when none runs.
    jobs_mutex: std.Io.Mutex = .init,
    jobs: u32 = 0,
    idle: std.Io.Event = .is_set,
    /// Tells the reader to stop.
    stop: std.atomic.Value(bool) = .init(false),
    /// The child side closed.
    ended: std.atomic.Value(bool) = .init(false),
    /// Why no shell runs, or how it ended (shown in the panel header).
    note: [96]u8 = undefined,
    note_len: usize = 0,
    /// Load zigguro's shell integration scripts into the shell
    /// (`terminal.integrated.shellIntegration.enabled`).
    shell_integration: bool = true,
    /// This machine's name: a shell's OSC 7 folder naming it is local.
    host: [256]u8 = undefined,
    /// The folder the shell starts in (null: zigguro's own).
    start_cwd: ?[]const u8 = null,
    /// This session's shell-integration nonce.
    nonce: [32]u8 = undefined,
    /// Called after output arrives (the workbench repaints).
    on_output: ?Hook = null,
    /// Called first thing in `destroy` (an agent's command learns that
    /// its terminal is gone).
    on_destroy: ?Hook = null,
    /// The kind of shell started (how to quote a `cd` for it).
    kind: inject.ShellKind = .other,
    /// Called on the reader thread with each chunk of output, before the
    /// terminal sees it (a task's problem matchers read it).
    on_bytes: ?BytesHook = null,
    /// Called once on the UI thread when the process ended, with its exit
    /// code (null when killed by a signal). With it set, the reader waits
    /// (up to 2 s) for the process after the output ends.
    on_exit: ?ExitHook = null,
    /// The process's status, set by the reader before `ended`.
    exit_status: ?zg_platform.process.pty.ExitStatus = null,
    exit_reported: bool = false,
    /// Not saved with the terminals (a task's).
    transient: bool = false,

    pub const Hook = struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void };
    pub const BytesHook = struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, bytes: []const u8) void };
    pub const ExitHook = struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, code: ?u8) void };

    /// A panel with an 80x24 terminal; `start` spawns the shell.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, app: *zg_gui.App, env: *const std.process.Environ.Map) !*TerminalPanel {
        const p = try gpa.create(TerminalPanel);
        errdefer gpa.destroy(p);
        p.* = .{ .gpa = gpa, .io = io, .app = app, .env = env, .term = undefined, .view = undefined, .find = try .init(gpa) };
        errdefer p.find.deinit();
        p.poster = try gpa.create(Poster);
        p.poster.* = .{ .gpa = gpa, .panel = p };
        errdefer gpa.destroy(p.poster);
        p.term = try .init(gpa, .{ .cols = 80, .rows = 24, .deflate_scrollback = true, .background_compaction = true });
        p.term.opts.hostname = p.hostName();
        p.view = .init(gpa, &p.term, .{});
        p.view.sink = .{ .ctx = p, .write = write };
        p.view.on_resize = .{ .ctx = p, .f = onResize };
        p.term.opts.graphics.io = io;
        p.term.opts.graphics.allow_file_media = true;
        p.term.opts.graphics.tmpdir = env.get("TMPDIR") orelse "";
        p.view.enableImages(app.gpa, &app.images) catch |e| {
            p.view.deinit();
            p.term.deinit();
            return e;
        };
        _ = p.view.enableBlocks(.{}) catch |e| {
            p.view.deinit();
            p.term.deinit();
            return e;
        };
        return p;
    }

    /// Stops the reader, ends the shell and frees everything.
    pub fn destroy(p: *TerminalPanel) void {
        if (p.on_destroy) |h| h.f(h.ctx);
        p.stop.store(true, .release);
        if (p.pty) |*pty| pty.kill(.hangup);
        // The reader polls `stop` every 50 ms.
        p.idle.waitUncancelable(p.io);
        if (p.pty) |*pty| {
            _ = pty.tryWait() catch {};
            pty.close();
        }
        p.compactor.deinit(&p.term);
        // UI thread, like the drains: none runs against the panel now.
        p.poster.panel = null;
        p.poster.release();
        p.pending.deinit(p.gpa);
        p.find.deinit();
        p.view.deinit();
        p.term.deinit();
        p.gpa.destroy(p);
    }

    fn hostName(p: *TerminalPanel) []const u8 {
        var buf: [256]u8 = undefined;
        const name: []const u8 = if (builtin.os.tag == .windows)
            p.env.get("COMPUTERNAME") orelse ""
        else
            std.posix.gethostname(buf[0..std.posix.HOST_NAME_MAX]) catch "";
        const n = @min(name.len, p.host.len);
        @memcpy(p.host[0..n], name[0..n]);
        return p.host[0..n];
    }

    pub fn setNote(p: *TerminalPanel, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&p.note, fmt, args) catch p.note[0..0];
        p.note_len = s.len;
    }

    /// What the header shows next to the title.
    pub fn noteText(p: *const TerminalPanel) []const u8 {
        return p.note[0..p.note_len];
    }

    /// Spawns `$SHELL` (or /bin/sh) on a PTY and starts reading it; on
    /// Windows, `%COMSPEC%` (or cmd.exe) on a ConPTY.
    pub fn start(p: *TerminalPanel) void {
        p.startShell(null, &.{});
    }

    /// `start` with `shell` (the `terminal.integrated.shell` setting;
    /// null or "" for the default) and its arguments.
    pub fn startShell(p: *TerminalPanel, shell_opt: ?[]const u8, args: []const []const u8) void {
        if (p.pty != null) return;
        const default_shell = if (builtin.os.tag == .windows)
            p.env.get("COMSPEC") orelse "cmd.exe"
        else
            p.env.get("SHELL") orelse "/bin/sh";
        const shell = if (shell_opt) |x| (if (x.len > 0) x else default_shell) else default_shell;
        var argv_buf: [33][]const u8 = undefined;
        argv_buf[0] = shell;
        const n = @min(args.len, argv_buf.len - 1);
        @memcpy(argv_buf[1..][0..n], args[0..n]);
        const argv = argv_buf[0 .. n + 1];
        p.kind = inject.kindOf(shell);
        var plan = if (p.shell_integration) p.integrationPlan(argv) else null;
        defer if (plan) |*x| x.deinit();
        const policy: zg_platform.process.pty.SpawnPolicy = .{ .env_set = if (plan) |x| x.env else &.{} };
        p.pty = Pty.spawn(p.gpa, p.io, .{
            .argv = if (plan) |x| x.argv else argv,
            .env = p.env,
            .cwd = p.start_cwd,
            .size = .{ .cols = p.term.cols(), .rows = p.term.rows() },
            .policy = &policy,
        }) catch |e| {
            p.setNote("no shell: {t}", .{e});
            return;
        };
        p.note_len = 0;
        p.startJob();
        p.app.spawnLoop(readLoop, .{p}) catch |e| {
            p.endJob();
            p.setNote("no reader thread: {t}", .{e});
            p.pty.?.kill(.hangup);
            _ = p.pty.?.tryWait() catch {};
            p.pty.?.close();
            p.pty = null;
        };
    }

    /// How to start `argv` with shell integration (zigguro's scripts
    /// loaded, a fresh nonce), or null for a shell it does not support or
    /// when the scripts cannot be written.
    fn integrationPlan(p: *TerminalPanel, argv: []const []const u8) ?inject.Plan {
        if (!inject.shouldInject(inject.kindOf(argv[0]), argv[1..])) return null;
        const root = (inject.cacheRoot(p.gpa, p.env) catch return null) orelse return null;
        defer p.gpa.free(root);
        const dir = inject.ensureExtracted(p.gpa, p.io, root) catch |e| {
            std.log.scoped(.terminal).warn("shell integration: cannot write the scripts: {t}", .{e});
            return null;
        };
        defer p.gpa.free(dir);
        p.nonce = inject.newNonce(p.io);
        p.term.opts.shell_nonce = &p.nonce;
        return inject.plan(p.gpa, argv, p.env, dir, &p.nonce) catch null;
    }

    fn startJob(p: *TerminalPanel) void {
        p.jobs_mutex.lockUncancelable(p.io);
        defer p.jobs_mutex.unlock(p.io);
        p.jobs += 1;
        p.idle.reset();
    }

    fn endJob(p: *TerminalPanel) void {
        p.jobs_mutex.lockUncancelable(p.io);
        defer p.jobs_mutex.unlock(p.io);
        p.jobs -= 1;
        if (p.jobs == 0) p.idle.set(p.io);
    }

    /// Queues one drain on the UI thread (any thread; one in flight).
    fn postDrain(p: *TerminalPanel) void {
        const q = p.poster;
        if (q.posted.swap(true, .acq_rel)) return;
        _ = q.refs.fetchAdd(1, .monotonic);
        p.app.post(.{ .ctx = q, .f = Poster.run }) catch {
            q.posted.store(false, .release);
            _ = q.refs.fetchSub(1, .monotonic);
        };
    }

    /// A posted drain's target: the panel until it is destroyed.
    const Poster = struct {
        gpa: std.mem.Allocator,
        refs: std.atomic.Value(u32) = .init(1),
        posted: std.atomic.Value(bool) = .init(false),
        /// Read and cleared on the UI thread only.
        panel: ?*TerminalPanel,

        fn release(q: *Poster) void {
            if (q.refs.fetchSub(1, .acq_rel) == 1) q.gpa.destroy(q);
        }

        fn run(ctx: *anyopaque, _: *zg_gui.App) void {
            const q: *Poster = @ptrCast(@alignCast(ctx));
            q.posted.store(false, .release);
            if (q.panel) |p| p.drain();
            q.release();
        }
    };

    fn readLoop(p: *TerminalPanel) void {
        defer p.endJob();
        var buf: [64 << 10]u8 = undefined;
        const pty = &p.pty.?;
        while (!p.stop.load(.acquire)) {
            if (!pty.waitReadable(50 * std.time.ns_per_ms)) {
                // A task's process can end before its output does (a
                // child keeps the terminal open; a ConPTY stays open).
                if (p.on_exit != null and p.exit_status == null) if (pty.tryWait() catch null) |st| {
                    p.exit_status = st;
                    // The console's last output, then EOF.
                    if (builtin.os.tag == .windows) {
                        pty.kill(.hangup);
                        continue;
                    }
                    p.ended.store(true, .release);
                    p.postDrain();
                    return;
                };
                continue;
            }
            const n = pty.read(&buf) catch |e| switch (e) {
                error.WouldBlock => continue,
                else => 0,
            };
            if (n == 0) {
                if (p.on_exit != null) p.awaitExit(pty);
                p.ended.store(true, .release);
            }
            if (n > 0) {
                if (p.on_bytes) |h| h.f(h.ctx, buf[0..n]);
                p.mutex.lockUncancelable(p.io);
                defer p.mutex.unlock(p.io);
                p.pending.appendSlice(p.gpa, buf[0..n]) catch {};
            }
            p.postDrain();
            if (n == 0) return;
        }
    }

    /// Reader thread, after the output ended: the exit status, polled
    /// until the process is reaped (or 2 s, or `stop`).
    fn awaitExit(p: *TerminalPanel, pty: *Pty) void {
        if (p.exit_status != null) return;
        var tries: u32 = 0;
        while (tries < 200 and !p.stop.load(.acquire)) : (tries += 1) {
            if (pty.tryWait() catch null) |st| {
                p.exit_status = st;
                return;
            }
            p.io.sleep(.fromMilliseconds(10), .awake) catch return;
        }
    }

    fn drain(p: *TerminalPanel) void {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(p.gpa);
        {
            p.mutex.lockUncancelable(p.io);
            defer p.mutex.unlock(p.io);
            std.mem.swap(std.ArrayList(u8), &bytes, &p.pending);
        }
        p.term.now_ms = p.app.now_ms;
        if (bytes.items.len > 0) p.view.feed(bytes.items);
        if (p.compactor.poll(&p.term)) {
            p.startJob();
            p.app.spawn(compactWork, .{p});
        }
        if (p.ended.load(.acquire) and !p.exit_reported) if (p.on_exit) |h| {
            p.exit_reported = true;
            h.f(h.ctx, if (p.exit_status) |st| switch (st) {
                .exited => |c| c,
                .signaled => null,
            } else null);
        };
        if (p.ended.load(.acquire) and p.note_len == 0) {
            const status = p.exit_status orelse if (p.pty) |*pty| (pty.tryWait() catch null) else null;
            if (status) |s| switch (s) {
                .exited => |c| p.setNote("shell exited ({d})", .{c}),
                .signaled => |sig| p.setNote("shell killed (signal {d})", .{sig}),
            } else p.setNote("shell exited", .{});
        }
        if (p.on_output) |h| h.f(h.ctx);
    }

    /// Worker: encodes the compaction job, then has the UI thread swap it in.
    fn compactWork(p: *TerminalPanel) void {
        defer p.endJob();
        p.compactor.work();
        p.postDrain();
    }

    /// Ends the shell (`.kill_tree`: with everything it started); the
    /// reader then sees the end.
    pub fn kill(p: *TerminalPanel, how: zg_platform.process.pty.KillMode) void {
        if (p.pty) |*pty| pty.kill(how);
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
