//! The pieces of one client request: options, the cancel token, errors and
//! the in-flight `Call`, which receives the transport's callbacks and
//! implements the timeout rules (CANCEL "Timeouts"): a soft deadline that
//! each progress notification resets, capped by a hard deadline.
//!
//! Every transport reports exactly one terminal callback per request
//! (`onResponse` or `onError`), also after `cancel` and `close`, so a
//! `Call` stays alive until that callback even when its caller gave up;
//! late responses are dropped there.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_jsonrpc = @import("zg_jsonrpc");
const protocol = @import("../protocol/root.zig");
const Transport = @import("../transport/Transport.zig");
const headers = @import("../transport/headers.zig");

const Deadline = zg_core.runtime.Deadline;
const message = zg_jsonrpc.message;
const Value = std.json.Value;

/// Why a request failed.
pub const RequestError = error{
    Timeout,
    Canceled,
    /// The connection went away, or a modern stream broke on a request
    /// that is not safe to re-issue (`tools/call`).
    ConnectionClosed,
    ProcessExited,
    /// Legacy: the session expired and the request is not replayed
    /// (`tools/call`); the client has already re-initialized.
    SessionExpired,
    UnsupportedRevision,
    /// `-32021`; `ErrorInfo.required_capabilities` names them.
    MissingRequiredClientCapability,
    /// `-32020`: the `Mcp-*` headers disagreed with the body.
    HeaderMismatch,
    /// Any other JSON-RPC error (see `ErrorInfo`) or HTTP failure status.
    ServerError,
    /// The server broke the protocol (bad result, unknown `resultType`).
    ProtocolViolation,
    /// The server asked for input (MRTR) and no handler supplied it.
    InputDeclined,
    TooManyInputRounds,
    /// The method does not exist in the negotiated revision.
    MethodNotAllowed,
    /// Caller `_meta` used a reserved or malformed key.
    InvalidMetaKey,
    ReservedMetaKey,
    OutOfMemory,
};

/// Details of a failure, for the UI and logs. Strings and values live in
/// `CallOptions.arena`.
pub const ErrorInfo = struct {
    code: ?i64 = null,
    message: []const u8 = "",
    data: ?Value = null,
    http_status: ?u16 = null,
    exit: ?Transport.ExitInfo = null,
    /// `-32021` `data.requiredCapabilities`.
    required_capabilities: ?protocol.Capabilities = null,
    /// Free text from the transport (`protocol` errors).
    detail: []const u8 = "",
};

/// Receives `notifications/progress` for one request.
pub const ProgressCallback = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, p: protocol.messages.Progress) void,
};

/// Answers MRTR `inputRequests` (F03.S03 plugs the InputBroker in here).
/// Returns null to decline. Memory comes from `arena`.
pub const InputHandler = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, arena: Allocator, requests: protocol.messages.InputRequests) anyerror!?protocol.messages.InputResponses,
};

/// Per-call options.
pub const CallOptions = struct {
    /// Owns the result and `ErrorInfo` contents.
    arena: Allocator,
    /// Soft timeout; null uses `Client.Options.default_timeout`.
    timeout: ?Io.Duration = null,
    /// Hard cap however much progress arrives; null uses `Client.Options.max_timeout`.
    max_timeout: ?Io.Duration = null,
    cancel: ?*CancelToken = null,
    on_progress: ?ProgressCallback = null,
    input: ?InputHandler = null,
    max_input_rounds: u32 = 8,
    log_level: ?protocol.messages.LoggingLevel = null,
    traceparent: ?[]const u8 = null,
    tracestate: ?[]const u8 = null,
    /// `Mcp-Param-*` headers (modern HTTP) from the tool's `x-mcp-header` map.
    param_headers: []const headers.ParamHeader = &.{},
    error_info: ?*ErrorInfo = null,
};

/// Cancels the request it is passed to (`CallOptions.cancel`), from any
/// thread. One token can serve several sequential requests; once
/// canceled, later requests using it fail at once.
pub const CancelToken = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    canceled: bool = false,
    reason: ?[]const u8 = null,
    call: ?*Call = null,

    /// A token that is not canceled.
    pub fn init(io: Io) CancelToken {
        return .{ .io = io };
    }

    /// Cancels: the waiting request sends the transport's cancellation and
    /// returns `error.Canceled`. `reason` must outlive the request.
    pub fn cancel(t: *CancelToken, reason: ?[]const u8) void {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        t.canceled = true;
        t.reason = reason;
        if (t.call) |c| c.requestCancel();
    }

    /// Whether `cancel` was called.
    pub fn isCanceled(t: *CancelToken) bool {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        return t.canceled;
    }

    /// Binds the token to `c`; false when already canceled.
    pub fn attach(t: *CancelToken, c: *Call) bool {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        if (t.canceled) return false;
        t.call = c;
        return true;
    }

    /// Unbinds the token (before the call is freed).
    pub fn detach(t: *CancelToken) void {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        t.call = null;
    }
};

/// Where a call forwards messages that are not its own outcome.
pub const Hooks = struct {
    ctx: ?*anyopaque,
    /// A notification on this request's stream that is not its progress.
    onNotification: *const fn (ctx: ?*anyopaque, n: protocol.Notification, raw: message.Notification) void,
    /// A legacy server request on this request's stream.
    onServerRequest: *const fn (ctx: ?*anyopaque, r: message.Request) void,
};

/// A JSON-RPC error response, copied.
pub const RpcError = struct { code: i64, message: []const u8, data: ?[]const u8 };

/// The terminal outcome of a call.
pub const Outcome = union(enum) {
    pending,
    /// Bytes copied into the call's arena.
    response: struct { result: ?[]const u8, err: ?RpcError },
    failure: Failure,
};

/// `Transport.TransportError` with its payload copied.
pub const Failure = union(enum) {
    http_status: struct { status: u16, body: []const u8 },
    stream_broken,
    session_expired,
    process_exited: Transport.ExitInfo,
    timeout,
    canceled,
    protocol: []const u8,
    io: anyerror,
};

/// What `Call.wait` ended with.
pub const WaitResult = enum { done, timeout, canceled };

/// One in-flight request. Created by the client, which registers it for
/// progress routing before handing `sink` to the transport.
pub const Call = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    id: protocol.RequestId,
    progress_token: ?protocol.ProgressToken,
    hooks: Hooks,
    on_progress: ?ProgressCallback,
    mutex: Io.Mutex = .init,
    wake: Io.Event = .unset,
    /// The terminal callback arrived.
    final: Io.Event = .unset,
    outcome: Outcome = .pending,
    cancel_requested: bool = false,
    soft: Deadline,
    hard: Deadline,
    soft_len: Io.Duration,
    sink: Transport.RequestSink,

    /// Heap-allocates a call; `timeout` starts now.
    pub fn create(gpa: Allocator, io: Io, id: protocol.RequestId, token: ?protocol.ProgressToken, hooks: Hooks, on_progress: ?ProgressCallback, timeout: Io.Duration, max_timeout: Io.Duration) Allocator.Error!*Call {
        const c = try gpa.create(Call);
        c.* = .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
            .id = id,
            .progress_token = token,
            .hooks = hooks,
            .on_progress = on_progress,
            .soft = .after(io, timeout),
            .hard = .after(io, max_timeout),
            .soft_len = timeout,
            .sink = .{ .ctx = undefined, .onNotification = sinkNotification, .onServerRequest = sinkServerRequest, .onResponse = sinkResponse, .onError = sinkError },
        };
        c.sink.ctx = c;
        return c;
    }

    /// Frees the call (after the terminal callback, or when the transport
    /// refused the request).
    pub fn destroy(c: *Call) void {
        c.arena.deinit();
        c.gpa.destroy(c);
    }

    /// Asks the waiter to cancel (CancelToken).
    pub fn requestCancel(c: *Call) void {
        c.mutex.lockUncancelable(c.io);
        c.cancel_requested = true;
        c.mutex.unlock(c.io);
        c.wake.set(c.io);
    }

    /// A progress notification for this call: resets the soft deadline
    /// (never past the hard one) and forwards it.
    pub fn progress(c: *Call, p: protocol.messages.Progress) void {
        c.mutex.lockUncancelable(c.io);
        c.soft = .after(c.io, c.soft_len);
        c.mutex.unlock(c.io);
        if (c.on_progress) |cb| cb.func(cb.ctx, p);
    }

    /// Whether `t` is this call's progress token.
    pub fn ownsToken(c: *const Call, t: protocol.ProgressToken) bool {
        const mine = c.progress_token orelse return false;
        return mine.eql(t);
    }

    /// Waits for the outcome, a cancel request or the deadline.
    pub fn wait(c: *Call) WaitResult {
        while (true) {
            c.mutex.lockUncancelable(c.io);
            if (c.outcome != .pending) {
                c.mutex.unlock(c.io);
                return .done;
            }
            if (c.cancel_requested) {
                c.mutex.unlock(c.io);
                return .canceled;
            }
            // The earlier of the soft and hard deadlines.
            const until = if (c.soft.at.compare(.lt, c.hard.at)) c.soft else c.hard;
            c.wake.reset();
            c.mutex.unlock(c.io);
            if (until.expired(c.io)) {
                // A progress notification may have moved the soft deadline.
                c.mutex.lockUncancelable(c.io);
                const moved = c.outcome != .pending or c.cancel_requested or
                    (!c.soft.expired(c.io) and !c.hard.expired(c.io));
                c.mutex.unlock(c.io);
                if (!moved) return .timeout;
                continue;
            }
            c.wake.waitTimeout(c.io, until.timeout()) catch {};
        }
    }

    /// Waits for the terminal callback (after `Transport.cancel`).
    pub fn waitFinal(c: *Call) void {
        c.final.waitUncancelable(c.io);
    }

    fn finish(c: *Call, o: Outcome) void {
        c.mutex.lockUncancelable(c.io);
        c.outcome = o;
        c.mutex.unlock(c.io);
        c.wake.set(c.io);
        c.final.set(c.io);
    }

    fn sinkNotification(ctx: ?*anyopaque, n: protocol.Notification, raw: message.Notification) void {
        const c: *Call = @ptrCast(@alignCast(ctx.?));
        if (n == .progress and c.ownsToken(n.progress.progress_token)) return c.progress(n.progress);
        c.hooks.onNotification(c.hooks.ctx, n, raw);
    }

    fn sinkServerRequest(ctx: ?*anyopaque, r: message.Request) void {
        const c: *Call = @ptrCast(@alignCast(ctx.?));
        c.hooks.onServerRequest(c.hooks.ctx, r);
    }

    fn sinkResponse(ctx: ?*anyopaque, r: message.Response) void {
        const c: *Call = @ptrCast(@alignCast(ctx.?));
        const a = c.arena.allocator();
        const copy: Outcome = blk: {
            const result = if (r.result) |res| a.dupe(u8, res.bytes) catch break :blk .{ .failure = .{ .io = error.OutOfMemory } } else null;
            const err: ?RpcError = if (r.err) |e| .{
                .code = @as(i64, e.code),
                .message = a.dupe(u8, e.message) catch "",
                .data = if (e.data) |d| a.dupe(u8, d.bytes) catch null else null,
            } else null;
            break :blk .{ .response = .{ .result = result, .err = err } };
        };
        c.finish(copy);
    }

    fn sinkError(ctx: ?*anyopaque, e: Transport.TransportError) void {
        const c: *Call = @ptrCast(@alignCast(ctx.?));
        const a = c.arena.allocator();
        const f: Failure = switch (e) {
            .http_status => |h| .{ .http_status = .{ .status = h.status, .body = a.dupe(u8, h.body) catch "" } },
            .stream_broken => .stream_broken,
            .session_expired => .session_expired,
            .process_exited => |x| blk: {
                var info = x;
                info.stderr_tail = a.dupe(u8, x.stderr_tail) catch "";
                break :blk .{ .process_exited = info };
            },
            .timeout => .timeout,
            .canceled => .canceled,
            .protocol => |m| .{ .protocol = a.dupe(u8, m) catch "" },
            .io => |err| .{ .io = err },
        };
        c.finish(.{ .failure = f });
    }
};

/// Methods safe to re-issue after a broken modern stream (CL2026 item 9):
/// they have no side effects.
pub fn isIdempotent(m: protocol.Method) bool {
    return switch (m) {
        .tools_list, .resources_list, .resources_templates_list, .prompts_list, .tasks_list, .resources_read, .prompts_get, .server_discover, .completion_complete, .ping => true,
        else => false,
    };
}

/// Maps a JSON-RPC error response to an error, filling `info`.
pub fn mapRpcError(arena: Allocator, code: i64, msg: []const u8, data_bytes: ?[]const u8, info: ?*ErrorInfo) RequestError {
    const data: ?Value = if (data_bytes) |d| std.json.parseFromSliceLeaky(Value, arena, d, .{}) catch null else null;
    if (info) |i| {
        i.code = code;
        i.message = arena.dupe(u8, msg) catch "";
        i.data = data;
    }
    if (code == protocol.errors.missing_required_client_capability) {
        if (info) |i| if (data) |d| if (d == .object) if (d.object.get("requiredCapabilities")) |rc| if (rc == .object) {
            i.required_capabilities = .{ .value = rc };
        };
        return error.MissingRequiredClientCapability;
    }
    if (code == protocol.errors.header_mismatch) return error.HeaderMismatch;
    if (code == protocol.errors.unsupported_protocol_version) return error.UnsupportedRevision;
    return error.ServerError;
}

/// Maps a transport failure to an error, filling `info`.
pub fn mapFailure(arena: Allocator, f: Failure, info: ?*ErrorInfo) RequestError {
    switch (f) {
        .http_status => |h| {
            if (info) |i| {
                i.http_status = h.status;
                i.detail = arena.dupe(u8, h.body) catch "";
            }
            return error.ServerError;
        },
        .stream_broken, .io => return error.ConnectionClosed,
        .session_expired => return error.SessionExpired,
        .process_exited => |x| {
            if (info) |i| {
                var e = x;
                e.stderr_tail = arena.dupe(u8, x.stderr_tail) catch "";
                i.exit = e;
            }
            return error.ProcessExited;
        },
        .timeout => return error.Timeout,
        .canceled => return error.Canceled,
        .protocol => |m| {
            if (info) |i| i.detail = arena.dupe(u8, m) catch "";
            return error.ProtocolViolation;
        },
    }
}

const testing = std.testing;

fn noNote(_: ?*anyopaque, _: protocol.Notification, _: message.Notification) void {}
fn noReq(_: ?*anyopaque, _: message.Request) void {}
const no_hooks: Hooks = .{ .ctx = null, .onNotification = noNote, .onServerRequest = noReq };

test "request: timeout, progress resets, max cap enforced" {
    const io = testing.io;
    // No progress: times out after the soft timeout.
    {
        const t0 = Io.Clock.Timestamp.now(io, .awake);
        const c = try Call.create(testing.allocator, io, .{ .int = 1 }, .{ .int = 1 }, no_hooks, null, .fromMilliseconds(30), .fromSeconds(5));
        defer c.destroy();
        try testing.expectEqual(WaitResult.timeout, c.wait());
        const ms = t0.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
        try testing.expect(ms >= 30 and ms < 1000);
    }
    // Progress every 20 ms keeps a 50 ms soft timeout alive until the 200 ms cap.
    {
        const t0 = Io.Clock.Timestamp.now(io, .awake);
        const c = try Call.create(testing.allocator, io, .{ .int = 2 }, .{ .int = 2 }, no_hooks, null, .fromMilliseconds(50), .fromMilliseconds(200));
        defer c.destroy();
        const Ticker = struct {
            fn run(call: *Call, stop: *std.atomic.Value(bool)) void {
                while (!stop.load(.acquire)) {
                    call.progress(.{ .progress_token = .{ .int = 2 }, .progress = 1 });
                    call.io.sleep(.fromMilliseconds(20), .awake) catch return;
                }
            }
        };
        var stop: std.atomic.Value(bool) = .init(false);
        var f = try io.concurrent(Ticker.run, .{ c, &stop });
        const r = c.wait();
        const ms = t0.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
        stop.store(true, .release);
        f.await(io);
        try testing.expectEqual(WaitResult.timeout, r);
        try testing.expect(ms >= 200 and ms < 2000);
    }
}

test "request: cancel token wakes the waiter; response wins" {
    const io = testing.io;
    const c = try Call.create(testing.allocator, io, .{ .int = 1 }, null, no_hooks, null, .fromSeconds(10), .fromSeconds(10));
    defer c.destroy();
    var tok: CancelToken = .init(io);
    try testing.expect(tok.attach(c));
    const Canceler = struct {
        fn run(t: *CancelToken) void {
            t.io.sleep(.fromMilliseconds(10), .awake) catch {};
            t.cancel("user");
        }
    };
    var f = try io.concurrent(Canceler.run, .{&tok});
    try testing.expectEqual(WaitResult.canceled, c.wait());
    f.await(io);
    tok.detach();
    try testing.expect(tok.isCanceled());
    try testing.expect(!tok.attach(c));

    const d = try Call.create(testing.allocator, io, .{ .int = 2 }, null, no_hooks, null, .fromSeconds(10), .fromSeconds(10));
    defer d.destroy();
    d.sink.onResponse(d.sink.ctx, .{ .id = .{ .int = 2 }, .result = .{ .bytes = "{}" } });
    try testing.expectEqual(WaitResult.done, d.wait());
    try testing.expectEqualStrings("{}", d.outcome.response.result.?);
}

test "request: error mapping" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var info: ErrorInfo = .{};
    try testing.expectEqual(error.MissingRequiredClientCapability, mapRpcError(a, -32021, "need", "{\"requiredCapabilities\":{\"elicitation\":{}}}", &info));
    try testing.expect(info.required_capabilities.?.has("elicitation"));
    try testing.expectEqual(error.HeaderMismatch, mapRpcError(a, -32020, "x", null, null));
    try testing.expectEqual(error.ServerError, mapRpcError(a, -32601, "Method not found", null, &info));
    try testing.expectEqual(@as(?i64, -32601), info.code);
    try testing.expectEqual(error.ProcessExited, mapFailure(a, .{ .process_exited = .{ .code = 1 } }, &info));
    try testing.expectEqual(@as(?u32, 1), info.exit.?.code);
    try testing.expect(isIdempotent(.tools_list) and !isIdempotent(.tools_call));
}
