//! Pseudo-terminals for the terminal (E06) and agent tools (E10): spawn a
//! child on a PTY, read and write it, resize it, and wait for or kill it.
//! Linux uses `/dev/ptmx` (`pty_linux.zig`); Windows uses ConPTY
//! (`pty_windows.zig`, Windows 10 1809+).

const std = @import("std");
const builtin = @import("builtin");

/// Terminal size in cells, with an optional pixel size for image protocols.
pub const PtySize = struct {
    /// Columns.
    cols: u16,
    /// Rows.
    rows: u16,
    /// Width in pixels, or 0.
    px_w: u16 = 0,
    /// Height in pixels, or 0.
    px_h: u16 = 0,
};

/// A resource limit applied in the child before exec.
pub const Rlimit = struct {
    /// Which limit.
    resource: std.os.linux.rlimit_resource,
    /// Soft limit.
    soft: u64,
    /// Hard limit.
    hard: u64,
};

/// Spawn restrictions supplied by the sandbox (E16). This task defines the
/// shape; E16 fills it in.
pub const SpawnPolicy = struct {
    /// When set, only these variables pass from the caller's environment.
    env_allow: ?[]const []const u8 = null,
    /// Variables set (or overridden) in the child.
    env_set: []const [2][]const u8 = &.{},
    /// A sandbox launcher prepended to argv, such as `bwrap ... --`.
    wrapper_argv: ?[]const []const u8 = null,
    /// Limits applied before exec (Linux).
    rlimits: []const Rlimit = &.{},
    /// Start a new session (always true for PTY children).
    new_session: bool = true,
};

/// Options for `Pty.spawn`.
pub const SpawnOptions = struct {
    /// Program and arguments; `argv[0]` is searched on `PATH` when it has
    /// no slash.
    argv: []const []const u8,
    /// Working directory, or null to inherit.
    cwd: ?[]const u8 = null,
    /// The environment to start from (callers pass `init.environ_map`).
    env: *const std.process.Environ.Map,
    /// Initial size.
    size: PtySize = .{ .cols = 80, .rows = 24 },
    /// `TERM` for the child.
    term: []const u8 = "xterm-256color",
    /// Sandbox policy (E16), if any.
    policy: ?*const SpawnPolicy = null,
};

/// How a child ended.
pub const ExitStatus = union(enum) {
    /// Exited with this status code.
    exited: u8,
    /// Killed by this signal number (Linux) or terminated (Windows).
    signaled: u32,
};

/// How `Pty.kill` stops the child.
pub const KillMode = enum {
    /// Close the master: the session gets SIGHUP.
    hangup,
    /// Ask the child to exit (SIGTERM).
    terminate,
    /// Kill the child's whole process tree (SIGKILL to the session).
    kill_tree,
};

/// Errors from PTY operations.
pub const Error = @import("spawn_linux.zig").SpawnError || error{
    /// A non-blocking read or write would block; wait for readiness.
    WouldBlock,
    /// The master was closed (after `kill(.hangup)` or child exit).
    Closed,
    /// PTYs are not available on this OS yet.
    Unsupported,
};

const Impl = switch (builtin.os.tag) {
    .linux => @import("pty_linux.zig").LinuxPty,
    .windows => @import("pty_windows.zig").WindowsPty,
    else => void,
};

/// What `writer` and `exitHandle` return: a descriptor on Linux, a
/// `HANDLE` on Windows.
pub const Handle = if (builtin.os.tag == .windows) *anyopaque else std.os.linux.fd_t;

/// A child process on a pseudo-terminal.
pub const Pty = struct {
    impl: Impl,

    /// Spawns `opts.argv` on a new PTY.
    pub fn spawn(gpa: std.mem.Allocator, io: std.Io, opts: SpawnOptions) Error!Pty {
        if (Impl == void) return error.Unsupported;
        if (builtin.os.tag == .windows) return .{ .impl = try Impl.spawn(gpa, io, opts) };
        return .{ .impl = try Impl.spawn(gpa, opts) };
    }

    /// The master descriptor to poll for output (Linux; non-blocking). On
    /// Windows, wait with `waitReadable` instead.
    pub fn reader(self: *Pty) std.os.linux.fd_t {
        return self.impl.master;
    }

    /// Where input is written: the master (Linux) or the input pipe's
    /// write end (Windows).
    pub fn writer(self: *Pty) Handle {
        if (builtin.os.tag == .windows) return self.impl.in_write.?;
        return self.impl.master;
    }

    /// Signalled when the child exits: a pidfd (Linux) or the process
    /// handle (Windows).
    pub fn exitHandle(self: *Pty) Handle {
        if (builtin.os.tag == .windows) return self.impl.process;
        return self.impl.child.pidfd;
    }

    /// Reads available output. Returns 0 at end of output (the child side
    /// closed) and `error.WouldBlock` when nothing is available.
    pub fn read(self: *Pty, buf: []u8) Error!usize {
        return self.impl.read(buf);
    }

    /// Writes input; may write fewer bytes than given.
    pub fn write(self: *Pty, bytes: []const u8) Error!usize {
        return self.impl.write(bytes);
    }

    /// Blocks until output is readable or `timeout_ns` passes; returns
    /// whether it is readable.
    pub fn waitReadable(self: *Pty, timeout_ns: ?u64) bool {
        return self.impl.waitReadable(timeout_ns);
    }

    /// Changes the terminal size; the foreground job gets SIGWINCH (Linux)
    /// or the console resizes (Windows).
    pub fn resize(self: *Pty, size: PtySize) Error!void {
        return self.impl.resize(size);
    }

    /// Blocks until the child exits and returns how it ended.
    pub fn wait(self: *Pty) Error!ExitStatus {
        return self.impl.wait();
    }

    /// The exit status if the child has exited, else null. Never blocks.
    pub fn tryWait(self: *Pty) Error!?ExitStatus {
        return self.impl.tryWait();
    }

    /// Stops the child; see `KillMode`.
    pub fn kill(self: *Pty, how: KillMode) void {
        self.impl.kill(how);
    }

    /// Releases the master and pidfd. Call `wait` first, or the child
    /// stays a zombie until zigguro exits. On Windows, closes the
    /// pseudoconsole and ends the child's tree if still running.
    pub fn close(self: *Pty) void {
        self.impl.close();
    }
};

const testing = std.testing;

const Run = struct {
    out: std.ArrayList(u8) = .empty,
    status: ExitStatus = undefined,

    fn deinit(r: *Run) void {
        r.out.deinit(testing.allocator);
    }
};

/// Reads until EOF (bounded by 5 s), writing `input` once the first output
/// arrives, then waits for the child.
fn runOn(p: *Pty, input: ?[]const u8) !Run {
    var r: Run = .{};
    errdefer r.deinit();
    var sent = input == null;
    var buf: [4096]u8 = undefined;
    var rounds: u32 = 0;
    while (rounds < 500) : (rounds += 1) {
        if (!p.waitReadable(10 * std.time.ns_per_ms)) continue;
        const n = p.read(&buf) catch |e| switch (e) {
            error.WouldBlock => continue,
            else => return e,
        };
        if (n == 0) break;
        try r.out.appendSlice(testing.allocator, buf[0..n]);
        if (!sent) {
            _ = try p.write(input.?);
            sent = true;
        }
    }
    r.status = try p.wait();
    return r;
}

fn testEnv(a: std.mem.Allocator) !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(a);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HOME", "/tmp");
    try env.put("ZG_SECRET", "hidden");
    try env.put("KEEP", "yes");
    return env;
}

test "spawn /bin/sh -c 'tty; stty size'" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try testEnv(testing.allocator);
    defer env.deinit();
    var p = try Pty.spawn(testing.allocator, testing.io, .{ .argv = &.{ "/bin/sh", "-c", "tty; stty size" }, .env = &env });
    defer p.close();
    var r = try runOn(&p, null);
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.out.items, "/dev/pts/") != null);
    try testing.expect(std.mem.indexOf(u8, r.out.items, "24 80") != null);
    try testing.expectEqual(ExitStatus{ .exited = 0 }, r.status);
}

test "resize then stty size" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try testEnv(testing.allocator);
    defer env.deinit();
    var p = try Pty.spawn(testing.allocator, testing.io, .{ .argv = &.{ "/bin/sh", "-c", "read x; stty size" }, .env = &env });
    defer p.close();
    try p.resize(.{ .cols = 120, .rows = 40 });
    _ = try p.write("go\n");
    var r = try runOn(&p, null);
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.out.items, "40 120") != null);
}

test "exit code propagated" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try testEnv(testing.allocator);
    defer env.deinit();
    var p = try Pty.spawn(testing.allocator, testing.io, .{ .argv = &.{ "sh", "-c", "exit 42" }, .env = &env });
    defer p.close();
    var r = try runOn(&p, null);
    defer r.deinit();
    try testing.expectEqual(ExitStatus{ .exited = 42 }, r.status);
}

test "exec failure reports ENOENT" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try testEnv(testing.allocator);
    defer env.deinit();
    try testing.expectError(error.FileNotFound, Pty.spawn(testing.allocator, testing.io, .{ .argv = &.{"/zg/missing/shell"}, .env = &env }));
    try testing.expectError(error.FileNotFound, Pty.spawn(testing.allocator, testing.io, .{ .argv = &.{"zg-missing-shell"}, .env = &env }));
}

test "no fd leaks into child" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try testEnv(testing.allocator);
    defer env.deinit();
    var p = try Pty.spawn(testing.allocator, testing.io, .{ .argv = &.{ "/bin/sh", "-c", "ls /proc/self/fd | tr '\\n' ' '" }, .env = &env });
    defer p.close();
    var r = try runOn(&p, null);
    defer r.deinit();
    // stdin, stdout, stderr, and the fd `ls` opens to read the directory.
    try testing.expectEqualStrings("0 1 2 3 ", std.mem.trim(u8, r.out.items, "\r\n"));
}

test "env allow-list" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try testEnv(testing.allocator);
    defer env.deinit();
    const policy: SpawnPolicy = .{ .env_allow = &.{ "PATH", "KEEP", "ZG_SECRET" }, .env_set = &.{.{ "ADDED", "1" }} };
    var p = try Pty.spawn(testing.allocator, testing.io, .{ .argv = &.{ "/bin/sh", "-c", "echo \"[$KEEP][$HOME][$ZG_SECRET][$ADDED][$TERM]\"" }, .env = &env, .policy = &policy, .term = "xterm-zg" });
    defer p.close();
    var r = try runOn(&p, null);
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.out.items, "[yes][][][1][xterm-zg]") != null);
}

test "Ctrl+C (write 0x03) interrupts sleep 10" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try testEnv(testing.allocator);
    defer env.deinit();
    // exec so sleep is the foreground process that receives SIGINT.
    var p = try Pty.spawn(testing.allocator, testing.io, .{ .argv = &.{ "/bin/sh", "-c", "echo ready; exec sleep 10" }, .env = &env });
    defer p.close();
    var r = try runOn(&p, "\x03");
    defer r.deinit();
    try testing.expectEqual(ExitStatus{ .signaled = @intFromEnum(std.os.linux.SIG.INT) }, r.status);
}

test "kill_tree and tryWait" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try testEnv(testing.allocator);
    defer env.deinit();
    var p = try Pty.spawn(testing.allocator, testing.io, .{ .argv = &.{ "/bin/sh", "-c", "sleep 10 & sleep 10" }, .env = &env });
    defer p.close();
    try testing.expectEqual(null, try p.tryWait());
    p.kill(.kill_tree);
    try testing.expectEqual(ExitStatus{ .signaled = @intFromEnum(std.os.linux.SIG.KILL) }, try p.wait());
}

/// Bytes of `out` with VT escape sequences (CSI and OSC) removed, so the
/// ConPTY tests can look for plain text.
fn stripVt(out: []const u8, buf: []u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        if (out[i] == 0x1b and i + 1 < out.len) {
            i += 1;
            if (out[i] == '[') {
                while (i + 1 < out.len and !(out[i + 1] >= 0x40 and out[i + 1] <= 0x7e)) i += 1;
                i += 1;
            } else if (out[i] == ']') {
                while (i + 1 < out.len and out[i + 1] != 0x07 and out[i + 1] != 0x1b) i += 1;
                i += 1;
            }
            continue;
        }
        if (n < buf.len) {
            buf[n] = out[i];
            n += 1;
        }
    }
    return buf[0..n];
}

/// Wine 9's pseudoconsole spawns and reaps the child but never delivers its
/// output, so the tests that read output skip there; they run on Windows.
fn underWine() bool {
    if (builtin.os.tag != .windows) return false;
    const k32 = @import("../win32/bindings/kernel32.zig");
    const ntdll = k32.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("ntdll.dll")) orelse return false;
    return k32.GetProcAddress(ntdll, "wine_get_version") != null;
}

fn winEnv(a: std.mem.Allocator) !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(a);
    try env.put("SystemRoot", "C:\\windows");
    try env.put("PATH", "C:\\windows\\system32;C:\\windows");
    try env.put("ZG_SECRET", "hidden");
    return env;
}

test "conpty: cmd /c echo hello, exit code 3" {
    if (builtin.os.tag != .windows or underWine()) return error.SkipZigTest;
    var env = try winEnv(testing.allocator);
    defer env.deinit();
    var p = try Pty.spawn(testing.allocator, testing.io, .{ .argv = &.{ "cmd.exe", "/c", "echo hello & exit 3" }, .env = &env });
    defer p.close();
    var r = try runOn(&p, null);
    defer r.deinit();
    var plain: [4096]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, stripVt(r.out.items, &plain), "hello") != null);
    try testing.expectEqual(ExitStatus{ .exited = 3 }, r.status);
}

test "conpty: input reaches the child, resize, missing program" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var env = try winEnv(testing.allocator);
    defer env.deinit();
    try testing.expectError(error.FileNotFound, Pty.spawn(testing.allocator, testing.io, .{ .argv = &.{"zg-missing-shell.exe"}, .env = &env }));
    if (underWine()) return error.SkipZigTest;
    var p = try Pty.spawn(testing.allocator, testing.io, .{ .argv = &.{ "cmd.exe", "/c", "set /p X=name? & echo got-%X%" }, .env = &env, .size = .{ .cols = 100, .rows = 30 } });
    defer p.close();
    try p.resize(.{ .cols = 120, .rows = 40 });
    var r = try runOn(&p, "zig\r\n");
    defer r.deinit();
    var plain: [4096]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, stripVt(r.out.items, &plain), "got-zig") != null);
}

test "conpty: exit code without reading" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var env = try winEnv(testing.allocator);
    defer env.deinit();
    var p = try Pty.spawn(testing.allocator, testing.io, .{ .argv = &.{ "cmd.exe", "/c", "exit 3" }, .env = &env });
    defer p.close();
    try testing.expectEqual(ExitStatus{ .exited = 3 }, try p.wait());
}

test "conpty: close ends a running tree" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var env = try winEnv(testing.allocator);
    defer env.deinit();
    var p = try Pty.spawn(testing.allocator, testing.io, .{ .argv = &.{ "cmd.exe", "/c", "ping -n 30 127.0.0.1" }, .env = &env });
    try testing.expectEqual(null, try p.tryWait());
    p.kill(.kill_tree);
    _ = try p.wait();
    p.close();
}

test "stripVt" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("hello\r\n", stripVt("\x1b[?25l\x1b]0;title\x07hel\x1b[1mlo\r\n", &buf));
}
