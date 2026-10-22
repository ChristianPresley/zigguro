//! Process creation on Linux with raw syscalls: `clone3(CLONE_PIDFD)` (or
//! `fork` + `pidfd_open` on old kernels), then a child path that uses only
//! async-signal-safe syscalls and allocates nothing. Everything the child
//! needs (path, argv, envp, cwd, rlimits) is prepared by the parent.

const std = @import("std");
const linux = std.os.linux;
const pty = @import("pty.zig");
const env_mod = @import("env.zig");

/// A spawned child.
pub const Child = struct {
    /// Process id; also the session and process group id when the child
    /// started a new session.
    pid: linux.pid_t,
    /// A pidfd for the child: poll-able, readable once it exits.
    pidfd: linux.fd_t,
};

/// How a standard stream of a non-PTY child is set up.
pub const Stdio = union(enum) {
    /// Keep the parent's descriptor.
    inherit,
    /// Use this descriptor (it is duplicated; the caller keeps ownership).
    fd: linux.fd_t,
    /// Open `/dev/null`.
    null,
};

/// Errors from spawning.
pub const SpawnError = error{
    /// The program was not found on `PATH` or `execve` reported ENOENT.
    FileNotFound,
    /// `execve` was refused (EACCES, EPERM).
    AccessDenied,
    /// The program is not a valid executable (ENOEXEC).
    InvalidExe,
    /// The working directory could not be entered.
    BadCwd,
    /// A resource limit could not be applied.
    RlimitFailed,
    /// The kernel refused a process, fd or pty.
    SystemResources,
    /// `argv` is empty.
    EmptyArgv,
    /// Another errno from the child before exec.
    Unexpected,
} || std.mem.Allocator.Error;

/// What the child does to its descriptors before exec.
pub const ChildSetup = struct {
    /// The PTY slave to make the controlling terminal and stdio, if any.
    pty_slave: ?linux.fd_t = null,
    /// Stdio for non-PTY children (ignored with `pty_slave`).
    stdin: Stdio = .inherit,
    /// See `stdin`.
    stdout: Stdio = .inherit,
    /// See `stdin`.
    stderr: Stdio = .inherit,
    /// Call `setsid` (always true with a PTY).
    new_session: bool = true,
};

/// Everything the child needs, prepared in the parent.
pub const Prepared = struct {
    path: [*:0]const u8,
    argv: [:null]?[*:0]const u8,
    envp: [:null]?[*:0]const u8,
    cwd: ?[*:0]const u8,
    rlimits: []const pty.Rlimit,
};

/// Builds argv (with the policy's wrapper in front), resolves the program
/// on `PATH` and builds envp, all in `arena`.
pub fn prepare(
    arena: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env: *const std.process.Environ.Map,
    policy: ?*const pty.SpawnPolicy,
    term: ?[]const u8,
) SpawnError!Prepared {
    const wrapper: []const []const u8 = if (policy) |p| p.wrapper_argv orelse &.{} else &.{};
    const total = wrapper.len + argv.len;
    if (total == 0) return error.EmptyArgv;
    const av = try arena.allocSentinel(?[*:0]const u8, total, null);
    for (wrapper, 0..) |s, i| av[i] = (try arena.dupeZ(u8, s)).ptr;
    for (argv, 0..) |s, i| av[wrapper.len + i] = (try arena.dupeZ(u8, s)).ptr;
    const prog = std.mem.span(av[0].?);
    return .{
        .path = try resolvePath(arena, prog, env.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin"),
        .argv = av,
        .envp = try env_mod.buildEnvp(arena, env, policy, term),
        .cwd = if (cwd) |c| (try arena.dupeZ(u8, c)).ptr else null,
        .rlimits = if (policy) |p| p.rlimits else &.{},
    };
}

/// `prog` itself when it contains a slash; otherwise the first executable
/// match on `path_var`.
pub fn resolvePath(arena: std.mem.Allocator, prog: [:0]const u8, path_var: []const u8) SpawnError![*:0]const u8 {
    if (std.mem.indexOfScalar(u8, prog, '/') != null) return prog.ptr;
    var it = std.mem.tokenizeScalar(u8, path_var, ':');
    while (it.next()) |dir| {
        const full = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir, prog }, 0);
        if (linux.errno(linux.faccessat(linux.AT.FDCWD, full, linux.X_OK, 0)) == .SUCCESS) return full.ptr;
    }
    return error.FileNotFound;
}

const CloneArgs = extern struct {
    flags: u64 = 0,
    pidfd: u64 = 0,
    child_tid: u64 = 0,
    parent_tid: u64 = 0,
    exit_signal: u64 = 0,
    stack: u64 = 0,
    stack_size: u64 = 0,
    tls: u64 = 0,
    set_tid: u64 = 0,
    set_tid_size: u64 = 0,
    cgroup: u64 = 0,

    comptime {
        std.debug.assert(@sizeOf(CloneArgs) == 88);
    }
};

const CLONE_PIDFD = 0x1000;

/// Forks and execs `p`. On return the child is running the new program, or
/// the child's pre-exec errno has been mapped to an error and the child
/// reaped.
pub fn spawn(p: *const Prepared, setup: ChildSetup) SpawnError!Child {
    var errpipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&errpipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.SystemResources;
    defer _ = linux.close(errpipe[0]);
    var err_w_open = true;
    defer if (err_w_open) {
        _ = linux.close(errpipe[1]);
    };

    var pidfd: linux.fd_t = -1;
    var args: CloneArgs = .{ .flags = CLONE_PIDFD, .pidfd = @intFromPtr(&pidfd), .exit_signal = @intFromEnum(linux.SIG.CHLD) };
    var rc = linux.syscall2(.clone3, @intFromPtr(&args), @sizeOf(CloneArgs));
    var use_pidfd_open = false;
    if (linux.errno(rc) == .NOSYS) {
        rc = linux.fork();
        use_pidfd_open = true;
    }
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.SystemResources,
    }
    if (rc == 0) childAfterFork(p, setup, errpipe[1]);

    const pid: linux.pid_t = @intCast(rc);
    if (use_pidfd_open) {
        const r = linux.pidfd_open(pid, 0);
        if (linux.errno(r) != .SUCCESS) {
            _ = linux.kill(pid, .KILL);
            reapPid(pid);
            return error.SystemResources;
        }
        pidfd = @intCast(r);
    }
    _ = linux.close(errpipe[1]);
    err_w_open = false;

    var buf: [4]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const n = linux.read(errpipe[0], buf[got..].ptr, buf.len - got);
        switch (linux.errno(n)) {
            .SUCCESS => {},
            .INTR => continue,
            else => break,
        }
        if (n == 0) break;
        got += n;
    }
    if (got == 0) return .{ .pid = pid, .pidfd = pidfd };

    // The child failed before exec and exits with 127; reap it.
    reapPidfd(pidfd);
    _ = linux.close(pidfd);
    const code = std.mem.readInt(u32, &buf, .little);
    const stage: u8 = @truncate(code >> 24);
    const e: linux.E = @enumFromInt(@as(u16, @truncate(code)));
    return switch (stage) {
        stage_cwd => error.BadCwd,
        stage_rlimit => error.RlimitFailed,
        stage_exec => switch (e) {
            .NOENT, .NOTDIR => error.FileNotFound,
            .ACCES, .PERM => error.AccessDenied,
            .NOEXEC => error.InvalidExe,
            else => error.Unexpected,
        },
        else => error.Unexpected,
    };
}

const stage_setup: u8 = 1;
const stage_cwd: u8 = 2;
const stage_rlimit: u8 = 3;
const stage_exec: u8 = 4;

/// The child side. Only raw syscalls, no allocation, no locks.
fn childAfterFork(p: *const Prepared, setup: ChildSetup, errfd: i32) noreturn {
    if (setup.new_session or setup.pty_slave != null) _ = linux.setsid();
    if (setup.pty_slave) |slave| {
        if (linux.errno(linux.ioctl(slave, linux.T.IOCSCTTY, 0)) != .SUCCESS) childFail(errfd, stage_setup, linux.E.NOTTY);
        for (0..3) |i| _ = linux.dup2(slave, @intCast(i));
    } else {
        childStdio(setup.stdin, 0, linux.O{ .ACCMODE = .RDONLY }, errfd);
        childStdio(setup.stdout, 1, linux.O{ .ACCMODE = .WRONLY }, errfd);
        childStdio(setup.stderr, 2, linux.O{ .ACCMODE = .WRONLY }, errfd);
    }
    closeOthers(errfd);

    // Default signal mask and dispositions.
    const empty = linux.sigemptyset();
    _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
    const dfl: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
    var sig: u32 = 1;
    while (sig < linux.NSIG) : (sig += 1) {
        if (sig == @intFromEnum(linux.SIG.KILL) or sig == @intFromEnum(linux.SIG.STOP)) continue;
        _ = linux.sigaction(@enumFromInt(sig), &dfl, null);
    }

    if (p.cwd) |c| {
        const r = linux.chdir(c);
        if (linux.errno(r) != .SUCCESS) childFail(errfd, stage_cwd, linux.errno(r));
    }
    for (p.rlimits) |l| {
        const r = linux.setrlimit(l.resource, &.{ .cur = l.soft, .max = l.hard });
        if (linux.errno(r) != .SUCCESS) childFail(errfd, stage_rlimit, linux.errno(r));
    }
    const r = linux.execve(p.path, p.argv.ptr, p.envp.ptr);
    childFail(errfd, stage_exec, linux.errno(r));
}

fn childStdio(s: Stdio, target: i32, null_flags: linux.O, errfd: i32) void {
    switch (s) {
        .inherit => {},
        .fd => |fd| if (fd != target) {
            _ = linux.dup2(fd, target);
        },
        .null => {
            const r = linux.open("/dev/null", null_flags, 0);
            if (linux.errno(r) != .SUCCESS) childFail(errfd, stage_setup, linux.errno(r));
            const fd: i32 = @intCast(r);
            if (fd != target) {
                _ = linux.dup2(fd, target);
                _ = linux.close(fd);
            }
        },
    }
}

/// Closes every descriptor from 3 up except `keep` (the CLOEXEC error
/// pipe, which exec closes).
fn closeOthers(keep: i32) void {
    const max: linux.fd_t = std.math.maxInt(linux.fd_t);
    const a = linux.syscall3(.close_range, 3, @intCast(keep - 1), 0);
    if (linux.errno(a) == .NOSYS) {
        var lim: linux.rlimit = undefined;
        const top: i32 = if (linux.errno(linux.getrlimit(.NOFILE, &lim)) == .SUCCESS) @intCast(@min(lim.cur, 65536)) else 1024;
        var fd: i32 = 3;
        while (fd < top) : (fd += 1) {
            if (fd != keep) _ = linux.close(fd);
        }
        return;
    }
    _ = linux.syscall3(.close_range, @intCast(keep + 1), @as(usize, @intCast(max)), 0);
}

fn childFail(errfd: i32, stage: u8, e: linux.E) noreturn {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, (@as(u32, stage) << 24) | @intFromEnum(e), .little);
    _ = linux.write(errfd, &buf, buf.len);
    linux.exit_group(127);
}

/// Blocks until the child behind `pidfd` exits, discarding its status.
pub fn reapPidfd(pidfd: linux.fd_t) void {
    var info: linux.siginfo_t = undefined;
    while (linux.errno(linux.waitid(.PIDFD, pidfd, &info, linux.W.EXITED, null)) == .INTR) {}
}

fn reapPid(pid: linux.pid_t) void {
    var info: linux.siginfo_t = undefined;
    while (linux.errno(linux.waitid(.PID, pid, &info, linux.W.EXITED, null)) == .INTR) {}
}

/// Waits for (or, with `nohang`, checks on) the child behind `pidfd`.
/// Returns null when `nohang` is set and it is still running.
pub fn waitPidfd(pidfd: linux.fd_t, nohang: bool) error{Unexpected}!?pty.ExitStatus {
    var info: linux.siginfo_t = undefined;
    info.fields.common.first.piduid.pid = 0;
    const flags: u32 = linux.W.EXITED | if (nohang) @as(u32, linux.W.NOHANG) else 0;
    while (true) {
        switch (linux.errno(linux.waitid(.PIDFD, pidfd, &info, flags, null))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
    if (info.fields.common.first.piduid.pid == 0) return null;
    const status = info.fields.common.second.sigchld.status;
    const code: linux.CLD = @enumFromInt(info.code);
    return switch (code) {
        .EXITED => .{ .exited = @intCast(status & 0xff) },
        .KILLED, .DUMPED => .{ .signaled = @intCast(status) },
        else => .{ .exited = 255 },
    };
}

/// Spawns a child without a PTY (agent tools under an E16 policy).
pub fn spawnProcess(
    arena: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env: *const std.process.Environ.Map,
    policy: ?*const pty.SpawnPolicy,
    stdio: struct { stdin: Stdio = .inherit, stdout: Stdio = .inherit, stderr: Stdio = .inherit },
) SpawnError!Child {
    const prep = try prepare(arena, argv, cwd, env, policy, null);
    return spawn(&prep, .{
        .stdin = stdio.stdin,
        .stdout = stdio.stdout,
        .stderr = stdio.stderr,
        .new_session = if (policy) |p| p.new_session else false,
    });
}

const testing = std.testing;

test "resolvePath searches PATH and keeps slashes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("./x", std.mem.span(try resolvePath(a, "./x", "/bin")));
    try testing.expectEqualStrings("/bin/sh", std.mem.span(try resolvePath(a, "sh", "/nonexistent:/bin")));
    try testing.expectError(error.FileNotFound, resolvePath(a, "zg-no-such-program", "/bin:/usr/bin"));
}

test "spawnProcess: exit code, wrapper argv and stdout pipe" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    try env.put("PATH", "/usr/bin:/bin");
    var pipe: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })));
    defer _ = linux.close(pipe[0]);
    const policy: pty.SpawnPolicy = .{ .wrapper_argv = &.{ "/bin/sh", "-c", "echo wrapped \"$0\"; exit 7" } };
    const child = try spawnProcess(a, &.{"arg0"}, null, &env, &policy, .{ .stdout = .{ .fd = pipe[1] } });
    _ = linux.close(pipe[1]);
    var buf: [64]u8 = undefined;
    const n = linux.read(pipe[0], &buf, buf.len);
    try testing.expectEqualStrings("wrapped arg0\n", buf[0..n]);
    try testing.expectEqual(pty.ExitStatus{ .exited = 7 }, (try waitPidfd(child.pidfd, false)).?);
    _ = linux.close(child.pidfd);
}

test "spawnProcess: bad cwd and missing program" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    try testing.expectError(error.BadCwd, spawnProcess(a, &.{"/bin/true"}, "/zg/no/such/dir", &env, null, .{}));
    try testing.expectError(error.FileNotFound, spawnProcess(a, &.{"/zg/no/such/program"}, null, &env, null, .{}));
}
