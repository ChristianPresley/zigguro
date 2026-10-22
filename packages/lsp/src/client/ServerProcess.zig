//! A language server (or debug adapter) process, or a TCP connection to
//! one, wired to a `Transport` for `zg_jsonrpc.Endpoint`.
//!
//! - **Spawn**: `std.process.spawn` with piped stdio, `create_no_window`,
//!   and (POSIX) a new process group so `terminate` can kill the whole tree.
//!   Windows tree-kill needs the E01 Job Object helper (E01.F06.S03.T01);
//!   until it lands only the server process itself is killed there.
//! - **Policy**: an optional `SpawnPolicy` (E16) may deny the spawn, prepend
//!   a sandbox wrapper or filter the environment.
//! - **stderr** is drained continuously into a bounded ring (a blocked
//!   stderr pipe deadlocks many servers) and logged at debug level.
//! - **Exit**: a watcher reaps the child and sets `exitEvent`. The Endpoint
//!   sees end of input on stdout independently; the client treats either as
//!   a crash unless it is shutting down.
//! - **Transports**: `stdio` (stdin/stdout), `tcp_connect` (connect to a
//!   running server; spawn `argv` first if it is not empty) and
//!   `tcp_listen_child` (pick a free loopback port, substitute it for
//!   `{port}` in `argv`, spawn, then connect with retries).
//!
//! Every call blocks and must run off the UI thread (`rt.assertNotUi`).

const ServerProcess = @This();
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const Subsystem = zg_core.runtime.Subsystem;
const Transport = @import("../transport/Transport.zig");
const StdioTransport = @import("../transport/stdio.zig").StdioTransport;
const tcp = @import("../transport/tcp.zig");

const log = std.log.scoped(.lsp_server);
const is_windows = builtin.os.tag == .windows;

pub const TransportKind = union(enum) {
    stdio,
    tcp_connect: struct { host: []const u8 = "127.0.0.1", port: u16 },
    /// `{port}` in any `argv` entry is replaced by the chosen port.
    tcp_listen_child,
};

pub const LaunchSpec = struct {
    /// Empty only for `tcp_connect` to a server started elsewhere.
    argv: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    env_add: []const [2][]const u8 = &.{},
    env_remove: []const []const u8 = &.{},
    /// The environment that `env_add` / `env_remove` and policy rules
    /// apply to (normally the process environment). Without changes the
    /// child inherits ours and this may be null.
    base_env: ?*const std.process.Environ.Map = null,
    transport: TransportKind = .stdio,
    /// Allow non-loopback `tcp_connect` hosts (`lsp.allowRemote`).
    allow_remote: bool = false,
    /// How long TCP transports retry refused connections.
    connect_timeout: Io.Duration = .fromSeconds(5),
    /// Log scope prefix, e.g. "zls".
    name: []const u8 = "server",
};

/// The E16 spawn policy, as consumed here (the shape follows
/// E01.F06.S02.T01's `SpawnPolicy`; rlimits are not supported by
/// `std.process.spawn` and are left to E01).
pub const SpawnPolicy = struct {
    ctx: ?*anyopaque = null,
    decideFn: *const fn (ctx: ?*anyopaque, argv: []const []const u8, cwd: ?[]const u8) Decision,

    pub const Decision = union(enum) {
        allow: Rules,
        /// The reason shown to the user.
        deny: []const u8,
    };

    pub const Rules = struct {
        /// Keep only these variables (null keeps all).
        env_allow: ?[]const []const u8 = null,
        env_set: []const [2][]const u8 = &.{},
        /// Prepended to argv (sandbox wrapper).
        wrapper_argv: ?[]const []const u8 = null,
    };

    pub fn decide(p: *const SpawnPolicy, argv: []const []const u8, cwd: ?[]const u8) Decision {
        return p.decideFn(p.ctx, argv, cwd);
    }
};

/// Extra failure detail from `start`.
pub const StartDiag = struct {
    /// Set on `error.SpawnDenied`; owned by the policy.
    deny_reason: ?[]const u8 = null,
};

pub const default_stderr_cap = 256 << 10;

rt: *zg_core.Runtime,
gpa: Allocator,
io: Io,
name: []u8,
child: ?std.process.Child = null,
child_pid: ?std.process.Child.Id = null,
/// POSIX process group of the server (its pid).
pgid: ?std.posix.pid_t = null,
stdin_file: ?Io.File = null,
/// Only until the stdio transport takes it over.
stdout_file: ?Io.File = null,
stderr_file: ?Io.File = null,
transport_impl: *Transport,
stderr_mutex: Io.Mutex = .init,
stderr_ring: zg_core.containers.RingBuffer(u8),
exit_mutex: Io.Mutex = .init,
exit_event: Io.Event = .unset,
term: ?std.process.Child.Term = null,
watcher: Subsystem,
drain: Subsystem,

/// Spawns and/or connects per `spec`. `stderr_cap` bounds the stderr ring
/// (rounded up to a power of two).
pub fn start(rt: *zg_core.Runtime, spec: LaunchSpec, policy: ?*const SpawnPolicy, stderr_cap: usize) !*ServerProcess {
    return startDiag(rt, spec, policy, stderr_cap, null);
}

/// `start`, reporting why a spawn was denied.
pub fn startDiag(rt: *zg_core.Runtime, spec: LaunchSpec, policy: ?*const SpawnPolicy, stderr_cap: usize, diag: ?*StartDiag) !*ServerProcess {
    rt.assertNotUi();
    const gpa = rt.gpa;
    const io = rt.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (spec.argv.len == 0 and spec.transport != .tcp_connect) return error.EmptyArgv;

    // Policy and the final argv/env.
    var argv: []const []const u8 = spec.argv;
    var rules: SpawnPolicy.Rules = .{};
    if (spec.argv.len > 0) if (policy) |p| switch (p.decide(spec.argv, spec.cwd)) {
        .allow => |r| rules = r,
        .deny => |reason| {
            if (diag) |d| d.deny_reason = reason;
            return error.SpawnDenied;
        },
    };
    var port: u16 = 0;
    switch (spec.transport) {
        .stdio => {},
        .tcp_connect => |t| port = t.port,
        .tcp_listen_child => {
            port = try tcp.pickFreePort(io);
            const port_text = try std.fmt.allocPrint(arena, "{d}", .{port});
            const out = try arena.alloc([]const u8, argv.len);
            for (argv, out) |a, *o| o.* = try std.mem.replaceOwned(u8, arena, a, "{port}", port_text);
            argv = out;
        },
    }
    if (rules.wrapper_argv) |w| {
        const out = try arena.alloc([]const u8, w.len + argv.len);
        @memcpy(out[0..w.len], w);
        @memcpy(out[w.len..], argv);
        argv = out;
    }
    const env = try buildEnv(arena, spec, rules);

    const p = try gpa.create(ServerProcess);
    p.* = .{
        .rt = rt,
        .gpa = gpa,
        .io = io,
        .name = &.{},
        .transport_impl = undefined,
        .stderr_ring = .{ .buf = &.{} },
        .watcher = .init(io),
        .drain = .init(io),
    };
    p.launch(spec, argv, env, port, stderr_cap) catch |err| {
        p.cleanupFailed();
        return err;
    };
    return p;
}

fn launch(p: *ServerProcess, spec: LaunchSpec, argv: []const []const u8, env: ?*const std.process.Environ.Map, port: u16, stderr_cap: usize) !void {
    const gpa = p.gpa;
    const io = p.io;
    p.name = try gpa.dupe(u8, spec.name);
    p.stderr_ring = try .init(gpa, std.math.ceilPowerOfTwo(usize, @max(stderr_cap, 4096)) catch return error.OutOfMemory);

    if (spec.argv.len > 0) {
        const stdio = spec.transport == .stdio;
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = if (spec.cwd) |c| .{ .path = c } else .inherit,
            .environ_map = env,
            .stdin = .pipe,
            .stdout = if (stdio) .pipe else .ignore,
            .stderr = .pipe,
            .pgid = if (is_windows) null else 0,
            .create_no_window = true,
        });
        // Own the pipes so that reaping (which closes Child's files) never
        // races with our readers and writers.
        p.stdin_file = child.stdin;
        p.stdout_file = child.stdout;
        p.stderr_file = child.stderr;
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;
        p.child_pid = child.id;
        if (!is_windows) p.pgid = child.id;
        p.child = child;
        try p.drain.spawnLoop(drainStderr, .{p});
        p.watcher.spawnLoop(watchExit, .{p}) catch |err| {
            // Nothing will reap the child: kill and reap it here.
            p.killTree();
            _ = p.child.?.wait(io) catch {};
            p.exit_event.set(io);
            return err;
        };
    } else {
        p.exit_event.set(io);
    }

    switch (spec.transport) {
        .stdio => {
            const s = try StdioTransport.create(gpa, io, p.stdin_file.?, p.stdout_file.?);
            p.stdin_file = null;
            p.stdout_file = null;
            p.transport_impl = &s.transport;
        },
        .tcp_connect, .tcp_listen_child => {
            const host = if (spec.transport == .tcp_connect) spec.transport.tcp_connect.host else "127.0.0.1";
            const t = try p.connectTcp(host, port, spec);
            p.transport_impl = &t.transport;
        },
    }
}

/// Frees whatever `launch` set up before it failed (no transport yet).
fn cleanupFailed(p: *ServerProcess) void {
    if (p.stdin_file) |f| f.close(p.io);
    if (p.stdout_file) |f| f.close(p.io);
    if (p.child != null) {
        p.killTree();
        p.waitExited();
    }
    p.watcher.join() catch {};
    p.drain.shutdown();
    if (p.stderr_file) |f| f.close(p.io);
    if (p.stderr_ring.buf.len > 0) p.stderr_ring.deinit(p.gpa);
    p.gpa.free(p.name);
    p.gpa.destroy(p);
}

fn buildEnv(arena: Allocator, spec: LaunchSpec, rules: SpawnPolicy.Rules) !?*const std.process.Environ.Map {
    const changes = spec.env_add.len + spec.env_remove.len + rules.env_set.len > 0 or rules.env_allow != null;
    if (!changes) return null;
    const base = spec.base_env orelse return error.MissingBaseEnv;
    const env = try arena.create(std.process.Environ.Map);
    env.* = try base.clone(arena);
    if (rules.env_allow) |allow| {
        var i: usize = 0;
        while (i < env.count()) {
            const key = env.keys()[i];
            const keep = for (allow) |k| {
                if (std.mem.eql(u8, k, key)) break true;
            } else false;
            if (keep) i += 1 else _ = env.swapRemove(key);
        }
    }
    for (spec.env_remove) |k| _ = env.swapRemove(k);
    for (spec.env_add) |kv| try env.put(kv[0], kv[1]);
    for (rules.env_set) |kv| try env.put(kv[0], kv[1]);
    return env;
}

fn connectTcp(p: *ServerProcess, host: []const u8, port: u16, spec: LaunchSpec) !*tcp.TcpTransport {
    const deadline = zg_core.runtime.Deadline.after(p.io, spec.connect_timeout);
    while (true) {
        if (p.child != null and p.exit_event.isSet()) return error.ServerExited;
        return tcp.TcpTransport.connect(p.gpa, p.io, host, port, .{ .allow_remote = spec.allow_remote }) catch |err| switch (err) {
            error.ConnectionRefused => {
                if (deadline.expired(p.io)) return err;
                try p.io.sleep(.fromMilliseconds(50), .awake);
                continue;
            },
            else => return err,
        };
    }
}

fn drainStderr(p: *ServerProcess) Io.Cancelable!void {
    const f = p.stderr_file orelse return;
    var buf: [4096]u8 = undefined;
    var r = f.readerStreaming(p.io, &buf);
    var line: [512]u8 = undefined;
    var line_len: usize = 0;
    while (true) {
        const data = r.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => {
                if (r.err) |e| if (e == error.Canceled) return error.Canceled;
                return;
            },
        };
        {
            p.stderr_mutex.lockUncancelable(p.io);
            defer p.stderr_mutex.unlock(p.io);
            for (data) |c| p.stderr_ring.pushOverwrite(c);
        }
        for (data) |c| {
            if (c == '\n' or line_len == line.len) {
                log.debug("{s}: {s}", .{ p.name, std.mem.trimEnd(u8, line[0..line_len], "\r") });
                line_len = 0;
                if (c == '\n') continue;
            }
            line[line_len] = c;
            line_len += 1;
        }
        r.interface.toss(data.len);
    }
}

fn watchExit(p: *ServerProcess) Io.Cancelable!void {
    if (is_windows) {
        // Wait without reaping, so `killTree` never uses a closed handle:
        // reaping happens under `exit_mutex`.
        const infinite: std.os.windows.LARGE_INTEGER = std.math.minInt(std.os.windows.LARGE_INTEGER);
        _ = std.os.windows.ntdll.NtWaitForSingleObject(p.child.?.id.?, .FALSE, &infinite);
    }
    p.exit_mutex.lockUncancelable(p.io);
    defer p.exit_mutex.unlock(p.io);
    const prev = p.io.swapCancelProtection(.blocked);
    defer _ = p.io.swapCancelProtection(prev);
    p.term = p.child.?.wait(p.io) catch |err| blk: {
        log.warn("{s}: wait failed: {t}", .{ p.name, err });
        break :blk .{ .unknown = 0 };
    };
    p.exit_event.set(p.io);
}

/// Kills the server and (POSIX) everything in its process group.
fn killTree(p: *ServerProcess) void {
    if (is_windows) {
        p.exit_mutex.lockUncancelable(p.io);
        defer p.exit_mutex.unlock(p.io);
        if (p.exit_event.isSet()) return;
        if (p.child_pid) |h| _ = std.os.windows.ntdll.NtTerminateProcess(h, @enumFromInt(1));
    } else if (p.pgid) |g| {
        std.posix.kill(-g, .KILL) catch {};
    }
}

fn waitExited(p: *ServerProcess) void {
    const prev = p.io.swapCancelProtection(.blocked);
    defer _ = p.io.swapCancelProtection(prev);
    p.exit_event.waitUncancelable(p.io);
}

/// The connection to the server.
pub fn transport(p: *ServerProcess) *Transport {
    return p.transport_impl;
}

/// Copies the last `max_lines` lines of stderr (at most the ring's
/// capacity) into `out`. Thread-safe.
pub fn stderrTail(p: *ServerProcess, out: *std.ArrayList(u8), max_lines: u32) Allocator.Error!void {
    p.stderr_mutex.lockUncancelable(p.io);
    defer p.stderr_mutex.unlock(p.io);
    const ring = &p.stderr_ring;
    const len = ring.len();
    if (len == 0 or max_lines == 0) return;
    // Walk back from the end, skipping a trailing newline.
    var lines: u32 = 0;
    var i = len;
    if (ring.peek(len - 1).? == '\n') i -= 1;
    while (i > 0) : (i -= 1) {
        if (ring.peek(i - 1).? == '\n') {
            lines += 1;
            if (lines == max_lines) break;
        }
    }
    try out.ensureUnusedCapacity(p.gpa, len - i);
    for (i..len) |j| out.appendAssumeCapacity(ring.peek(j).?);
}

/// Set once the server process has exited (immediately for a
/// `tcp_connect` without a process).
pub fn exitEvent(p: *ServerProcess) *Io.Event {
    return &p.exit_event;
}

/// How the process ended, once `exitEvent` is set.
pub fn exitStatus(p: *const ServerProcess) ?std.process.Child.Term {
    if (!p.exit_event.isSet()) return null;
    return p.term;
}

/// The server's process id (Windows: process handle), if spawned.
pub fn pid(p: *const ServerProcess) ?std.process.Child.Id {
    return p.child_pid;
}

/// Closes our side of the connection (servers exit on end of input),
/// waits up to `grace` for the process to exit, then kills the process
/// tree and waits for it. Idempotent.
pub fn terminate(p: *ServerProcess, grace: Io.Duration) void {
    p.rt.assertNotUi();
    p.transport_impl.close();
    if (p.stdin_file) |f| {
        f.close(p.io);
        p.stdin_file = null;
    }
    if (p.child == null) return;
    const prev = p.io.swapCancelProtection(.blocked);
    defer _ = p.io.swapCancelProtection(prev);
    p.exit_event.waitTimeout(p.io, zg_core.runtime.Deadline.after(p.io, grace).timeout()) catch {};
    // Kill the group even after a clean exit: the server's own children
    // may still be running.
    p.killTree();
    p.waitExited();
}

/// Terminates (without grace) if needed and frees everything. Call once
/// nothing uses the transport any more.
pub fn deinit(p: *ServerProcess) void {
    p.terminate(.zero);
    p.watcher.join() catch {};
    // The drain loop ends at end of input; cancel it in case another
    // process still holds the write end.
    p.drain.shutdown();
    if (p.stderr_file) |f| f.close(p.io);
    p.transport_impl.deinit();
    p.stderr_ring.deinit(p.gpa);
    p.gpa.free(p.name);
    p.gpa.destroy(p);
}
