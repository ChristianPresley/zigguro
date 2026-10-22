//! The stdio transport: the server is a child process; each JSON-RPC
//! message is one line on its stdin/stdout (NDJSON). stderr is logging, kept
//! in a ring buffer for the manager UI and crash reports, never treated as
//! failure.
//!
//! - Responses are matched to requests by id; every other server message
//!   (notifications, legacy server requests) goes to the inbound sink.
//! - `cancel` sends `notifications/cancelled` (mandatory on stdio).
//! - Exit is detected by a waiter task: pending requests fail with
//!   `process_exited`, flagged `during_startup` before the first response.
//! - Shutdown (MCP stdio "Shutdown"): close stdin, wait `grace_stdin_close`,
//!   SIGTERM the process group, wait `grace_term`, SIGKILL it. The child is
//!   its own process group (`pgid = 0`), so grandchildren go too. On
//!   Windows the fallback is `Child.kill` until the E01.F06 job helper lands.
//!
//! Windows command resolution: 0.16 `std.process.spawn` already searches
//! PATH x PATHEXT and quotes `.bat`/`.cmd` arguments for cmd.exe
//! (rejecting CR/LF/NUL with `InvalidBatchScriptArg`), so no resolver of our
//! own exists yet.
//!
//! This transport does not use `zg_jsonrpc.Endpoint`: callers hand it
//! complete serialized messages with their own ids (the `Transport`
//! contract), so it only frames lines and routes by id.

const StdioTransport = @This();
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_jsonrpc = @import("zg_jsonrpc");
const protocol = @import("../protocol/root.zig");
const Transport = @import("Transport.zig");
const common = @import("http_common.zig");

const RequestId = protocol.RequestId;
const message = zg_jsonrpc.message;
const framing = zg_jsonrpc.framing;
const posix_groups = builtin.os.tag != .windows;

/// Spawn and shutdown options.
pub const StdioOptions = struct {
    command: []const u8,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    /// The full child environment (already merged by the host); null
    /// inherits ours.
    env: ?*const std.process.Environ.Map = null,
    stderr_ring_bytes: u32 = 64 * 1024,
    max_line_bytes: u32 = 16 * 1024 * 1024,
    grace_stdin_close: Io.Duration = .fromSeconds(2),
    grace_term: Io.Duration = .fromSeconds(2),
    /// E16 SpawnPolicy (opaque here).
    spawn_policy: ?*const anyopaque = null,
};

/// Why `start` failed.
pub const StartError = error{ CommandNotFound, AccessDenied, SpawnFailed, OutOfMemory, ConcurrencyUnavailable };

/// Receives each stderr line (without the newline; long lines arrive in
/// pieces). Runs on the stderr task; copy what you keep.
pub const LineCallback = struct { ctx: ?*anyopaque, func: *const fn (?*anyopaque, line: []const u8) void };

const Pending = struct { id: RequestId, sink: *Transport.RequestSink };

rt: *zg_core.Runtime,
gpa: Allocator,
io: Io,
opts: StdioOptions,
child: std.process.Child,
child_pid: ?std.process.Child.Id,
/// The child's process group (its pid; POSIX), kept after it exits so
/// grandchildren can still be signalled.
group: if (posix_groups) ?std.posix.pid_t else void,
stdin: ?Io.File,
stdout: Io.File,
stderr: Io.File,
write_mutex: Io.Mutex = .init,
write_buf: [4096]u8 = undefined,
writer: Io.File.Writer = undefined,
mutex: Io.Mutex = .init,
pending: std.ArrayList(Pending) = .empty,
inbound: ?*Transport.InboundSink = null,
ring: []u8,
ring_pos: usize = 0,
ring_full: bool = false,
line_cb: ?LineCallback = null,
got_response: bool = false,
exit: ?Transport.ExitInfo = null,
exited: Io.Event = .unset,
closing: bool = false,
/// The stdout and stderr readers.
readers: zg_core.runtime.Subsystem,
/// The `Child.wait` task.
waiter: zg_core.runtime.Subsystem,

/// Spawns the server. Worker threads only.
pub fn start(rt: *zg_core.Runtime, gpa: Allocator, opts: StdioOptions) StartError!*StdioTransport {
    rt.assertNotUi();
    const io = rt.io;
    const argv = try gpa.alloc([]const u8, opts.args.len + 1);
    defer gpa.free(argv);
    argv[0] = opts.command;
    @memcpy(argv[1..], opts.args);
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (opts.cwd) |p| .{ .path = p } else .inherit,
        .environ_map = opts.env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (posix_groups) 0 else null,
        .create_no_window = true,
    }) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir, error.InvalidExe, error.IsDir => error.CommandNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.OutOfMemory => error.OutOfMemory,
        else => error.SpawnFailed,
    };
    const self = gpa.create(StdioTransport) catch |e| {
        child.kill(io);
        return e;
    };
    self.* = .{
        .rt = rt,
        .gpa = gpa,
        .io = io,
        .opts = opts,
        .child = child,
        .child_pid = child.id,
        .group = if (posix_groups) child.id else {},
        .stdin = child.stdin,
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
        .ring = &.{},
        .readers = .init(io),
        .waiter = .init(io),
    };
    // We own the pipes: `wait` must not close them under the readers.
    self.child.stdin = null;
    self.child.stdout = null;
    self.child.stderr = null;
    self.writer = self.stdin.?.writerStreaming(io, &self.write_buf);
    errdefer {
        self.waiter.shutdown();
        self.child.kill(io);
        self.destroy();
    }
    self.ring = try gpa.alloc(u8, opts.stderr_ring_bytes);
    try self.waiter.spawnLoop(waitLoop, .{self});
    try self.readers.spawnLoop(stdoutLoop, .{self});
    try self.readers.spawnLoop(stderrLoop, .{self});
    return self;
}

/// The `Transport` interface.
pub fn transport(self: *StdioTransport) Transport {
    return .{ .ptr = self, .vtable = &vtable };
}

/// The process id, while the process runs.
pub fn pid(self: *const StdioTransport) ?std.process.Child.Id {
    return self.child_pid;
}

/// How the process ended, once it has.
pub fn exitInfo(self: *const StdioTransport) ?Transport.ExitInfo {
    return self.exit;
}

/// Calls `cb` for every later stderr line.
pub fn onStderrLine(self: *StdioTransport, cb: LineCallback) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.line_cb = cb;
}

/// The last `stderr_ring_bytes` of stderr, oldest first, starting at a
/// character boundary, with invalid UTF-8 replaced by U+FFFD.
pub fn stderrSnapshot(self: *StdioTransport, gpa: Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    const raw = try self.ringCopy(gpa);
    self.mutex.unlock(self.io);
    defer gpa.free(raw);
    return sanitize(gpa, raw);
}

fn ringCopy(self: *StdioTransport, gpa: Allocator) ![]u8 {
    if (!self.ring_full) return gpa.dupe(u8, self.ring[0..self.ring_pos]);
    const out = try gpa.alloc(u8, self.ring.len);
    const tail = self.ring[self.ring_pos..];
    @memcpy(out[0..tail.len], tail);
    @memcpy(out[tail.len..], self.ring[0..self.ring_pos]);
    return out;
}

fn sanitize(gpa: Allocator, raw: []const u8) ![]u8 {
    var s = raw;
    // The ring may start inside a character.
    while (s.len > 0 and s[0] & 0xC0 == 0x80) s = s[1..];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (n > 0 and i + n <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + n])) {
            try out.appendSlice(gpa, s[i .. i + n]);
            i += n;
        } else {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

const vtable: Transport.VTable = .{
    .request = vRequest,
    .notify = vNotify,
    .respond = vRespond,
    .cancel = vCancel,
    .setInbound = vSetInbound,
    .close = vClose,
    .kind = vKind,
};

fn vRequest(ptr: *anyopaque, req: Transport.OutgoingRequest, sink: *Transport.RequestSink) Transport.SendError!void {
    const self: *StdioTransport = @ptrCast(@alignCast(ptr));
    const id: RequestId = switch (req.id) {
        .str => |s| .{ .str = try self.gpa.dupe(u8, s) },
        else => req.id,
    };
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closing or self.exit != null) {
            freeId(self.gpa, id);
            return error.Closed;
        }
        self.pending.append(self.gpa, .{ .id = id, .sink = sink }) catch |e| {
            freeId(self.gpa, id);
            return e;
        };
    }
    self.writeLine(req.body) catch |err| {
        if (self.takePending(id)) |p| freeId(self.gpa, p.id);
        return err;
    };
}

fn vNotify(ptr: *anyopaque, n: Transport.OutgoingNotification) Transport.SendError!void {
    const self: *StdioTransport = @ptrCast(@alignCast(ptr));
    return self.writeLine(n.body);
}

fn vRespond(ptr: *anyopaque, body: []const u8, _: protocol.Revision) Transport.SendError!void {
    const self: *StdioTransport = @ptrCast(@alignCast(ptr));
    return self.writeLine(body);
}

fn vCancel(ptr: *anyopaque, id: RequestId, reason: ?[]const u8) void {
    const self: *StdioTransport = @ptrCast(@alignCast(ptr));
    const p = self.takePending(id) orelse return;
    defer freeId(self.gpa, p.id);
    p.sink.onError(p.sink.ctx, .canceled);
    const body = common.cancelledBody(self.gpa, id, reason) catch return;
    defer self.gpa.free(body);
    self.writeLine(body) catch {};
}

fn vSetInbound(ptr: *anyopaque, inbound: *Transport.InboundSink) void {
    const self: *StdioTransport = @ptrCast(@alignCast(ptr));
    self.inbound = inbound;
}

fn vKind(_: *anyopaque) Transport.Kind {
    return .stdio;
}

fn vClose(ptr: *anyopaque) void {
    const self: *StdioTransport = @ptrCast(@alignCast(ptr));
    self.deinit();
}

fn writeLine(self: *StdioTransport, body: []const u8) Transport.SendError!void {
    self.write_mutex.lockUncancelable(self.io);
    defer self.write_mutex.unlock(self.io);
    if (self.stdin == null) return error.Closed;
    framing.writeNdjson(&self.writer.interface, body) catch |err| return switch (err) {
        error.EmbeddedNewline => error.InvalidMessage,
        else => error.Closed,
    };
}

fn freeId(gpa: Allocator, id: RequestId) void {
    switch (id) {
        .str => |s| gpa.free(s),
        else => {},
    }
}

fn takePending(self: *StdioTransport, id: RequestId) ?Pending {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.pending.items, 0..) |p, i| if (p.id.eql(id)) return self.pending.swapRemove(i);
    return null;
}

fn failPending(self: *StdioTransport, e: Transport.TransportError) void {
    self.mutex.lockUncancelable(self.io);
    const all = self.pending.toOwnedSlice(self.gpa) catch &.{};
    self.mutex.unlock(self.io);
    defer self.gpa.free(all);
    for (all) |p| {
        p.sink.onError(p.sink.ctx, e);
        freeId(self.gpa, p.id);
    }
}

fn stdoutLoop(self: *StdioTransport) void {
    var buf: [64 * 1024]u8 = undefined;
    var r = self.stdout.readerStreaming(self.io, &buf);
    var lines: framing.NdjsonReader = .init(&r.interface, .{ .max_message_bytes = self.opts.max_line_bytes });
    defer lines.deinit(self.gpa);
    while (true) {
        const line = lines.next(self.gpa) catch |err| switch (err) {
            error.MessageTooLarge => {
                // The stream cannot be trusted any more: fail and stop.
                self.failPending(.{ .protocol = "message line exceeds max_line_bytes" });
                if (self.inbound) |in| in.onClosed(in.ctx, .{ .protocol = "message line exceeds max_line_bytes" });
                self.killServer();
                return;
            },
            else => return, // EOF or read failure: the waiter reports the exit.
        };
        self.route(line);
    }
}

fn route(self: *StdioTransport, line: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const msg = switch (message.parse(a, line)) {
        .single => |m| m,
        .batch, .invalid => return, // Not ours to answer; servers must not batch.
    };
    switch (msg) {
        .response => |resp| {
            const p = self.takePending(resp.id) orelse return; // Late or unknown.
            defer freeId(self.gpa, p.id);
            self.got_response = true;
            p.sink.onResponse(p.sink.ctx, resp);
        },
        .notification => |n| if (self.inbound) |in| {
            const typed = protocol.Notification.decode(a, n.method, n.params, .{}) catch
                protocol.Notification{ .unknown = .{ .method = n.method, .params = null } };
            in.onNotification(in.ctx, typed, n);
        },
        .request => |req| if (self.inbound) |in| in.onServerRequest(in.ctx, req),
    }
}

fn stderrLoop(self: *StdioTransport) void {
    var buf: [4096]u8 = undefined;
    var line: [4096]u8 = undefined;
    var line_len: usize = 0;
    while (true) {
        const n = self.stderr.readStreaming(self.io, &.{&buf}) catch return;
        if (n == 0) return;
        const chunk = buf[0..n];
        self.mutex.lockUncancelable(self.io);
        self.ringAppend(chunk);
        const cb = self.line_cb;
        self.mutex.unlock(self.io);
        const f = cb orelse continue;
        for (chunk) |c| {
            if (c == '\n' or line_len == line.len) {
                f.func(f.ctx, std.mem.trimEnd(u8, line[0..line_len], "\r"));
                line_len = 0;
                if (c == '\n') continue;
            }
            line[line_len] = c;
            line_len += 1;
        }
    }
}

fn ringAppend(self: *StdioTransport, bytes: []const u8) void {
    if (self.ring.len == 0) return;
    var b = bytes;
    if (b.len >= self.ring.len) {
        @memcpy(self.ring, b[b.len - self.ring.len ..]);
        self.ring_pos = 0;
        self.ring_full = true;
        return;
    }
    const first = @min(b.len, self.ring.len - self.ring_pos);
    @memcpy(self.ring[self.ring_pos..][0..first], b[0..first]);
    b = b[first..];
    self.ring_pos += first;
    if (self.ring_pos == self.ring.len) {
        self.ring_pos = 0;
        self.ring_full = true;
    }
    if (b.len > 0) {
        @memcpy(self.ring[0..b.len], b);
        self.ring_pos = b.len;
    }
}

fn waitLoop(self: *StdioTransport) void {
    const term = self.child.wait(self.io) catch return;
    var info: Transport.ExitInfo = .{ .during_startup = !self.got_response };
    switch (term) {
        .exited => |c| info.code = c,
        .signal => |s| info.signal = @intFromEnum(s),
        .stopped, .unknown => {},
    }
    self.mutex.lockUncancelable(self.io);
    self.exit = info;
    self.child_pid = null;
    const closing = self.closing;
    self.mutex.unlock(self.io);
    self.exited.set(self.io);
    if (closing) return;
    // Give the stderr reader a moment to drain the last lines.
    self.io.sleep(.fromMilliseconds(20), .awake) catch {};
    const tail = self.stderrSnapshot(self.gpa) catch "";
    defer if (tail.len > 0) self.gpa.free(tail);
    info.stderr_tail = tail;
    self.failPending(.{ .process_exited = info });
    if (self.inbound) |in| in.onClosed(in.ctx, .{ .process_exited = info });
}

fn signalGroup(self: *StdioTransport, sig: if (posix_groups) std.posix.SIG else void) void {
    if (!posix_groups) return;
    const g = self.group orelse return;
    std.posix.kill(-g, sig) catch {};
}

/// Hard-stops the server: SIGKILL to its process group on POSIX,
/// NtTerminateProcess on Windows (grandchildren survive there until a job
/// object owns the tree).
fn killServer(self: *StdioTransport) void {
    if (posix_groups) return self.signalGroup(.KILL);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    // Cleared once `wait` returned; the handle may already be closing
    // then, which makes the call a harmless invalid-handle failure.
    if (self.child_pid) |h| _ = std.os.windows.ntdll.NtTerminateProcess(h, @enumFromInt(1));
}

/// Shuts the server down (stdin close, SIGTERM, SIGKILL), fails pending
/// requests with `canceled` and frees the transport. Idempotent per
/// transport; any non-UI thread.
pub fn deinit(self: *StdioTransport) void {
    const io = self.io;
    self.mutex.lockUncancelable(io);
    self.closing = true;
    self.mutex.unlock(io);
    self.closeStdin();
    if (!self.waitExit(self.opts.grace_stdin_close)) {
        // Windows has no SIGTERM: go straight to the hard stop.
        if (!posix_groups or blk: {
            self.signalGroup(.TERM);
            break :blk !self.waitExit(self.opts.grace_term);
        }) {
            self.killServer();
            self.exited.waitUncancelable(io);
        }
    }
    // The leader is gone; take any grandchildren still in its group along.
    if (posix_groups) self.signalGroup(.KILL);
    self.waiter.shutdown();
    self.readers.shutdown();
    self.failPending(.canceled);
    self.destroy();
}

fn waitExit(self: *StdioTransport, d: Io.Duration) bool {
    self.exited.waitTimeout(self.io, .{ .duration = .{ .raw = d, .clock = .awake } }) catch return false;
    return true;
}

fn closeStdin(self: *StdioTransport) void {
    self.write_mutex.lockUncancelable(self.io);
    defer self.write_mutex.unlock(self.io);
    if (self.stdin) |f| {
        self.writer.interface.flush() catch {};
        f.close(self.io);
        self.stdin = null;
    }
}

fn destroy(self: *StdioTransport) void {
    self.closeStdin();
    self.stdout.close(self.io);
    self.stderr.close(self.io);
    self.pending.deinit(self.gpa);
    if (self.ring.len > 0) self.gpa.free(self.ring);
    self.gpa.destroy(self);
}
