//! One live connection to a language server: the lifecycle state machine,
//! the `initialize` handshake, the typed async request API every feature
//! service uses, shutdown, and crash detection.
//!
//! States: `spawning -> initializing -> running -> shutting_down ->
//! stopped`; any state goes to `crashed` when the connection ends without
//! a requested shutdown. Restarting (backoff, re-sync, `disabled`) is the
//! supervisor's job (`restart.zig`); a restarted server is a new Client.
//!
//! Requests made while `initializing` are queued and sent after
//! `initialized` (servers answer anything else with -32002 before the
//! `initialize` response). Each request first checks `ServerCaps.supports`
//! and fails with `.unsupported` without wire traffic.
//!
//! Callbacks run on the endpoint's reader or timer loop: keep them short
//! and reach the UI only through `Runtime.post`. No Client lock is held
//! while a callback runs.

const Client = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_jsonrpc = @import("zg_jsonrpc");
const Endpoint = zg_jsonrpc.Endpoint;
const message = zg_jsonrpc.message;
const protocol = @import("../gen/protocol.zig");
const ServerProcess = @import("ServerProcess.zig");
const caps_mod = @import("caps.zig");
const client_capabilities = @import("client_capabilities.zig");
const position = @import("../proto/position.zig");
const trace_mod = @import("trace.zig");
const DocMatch = @import("doc_selector.zig").DocMatch;

const log = std.log.scoped(.lsp);

pub const ClientState = enum(u8) { spawning, initializing, running, shutting_down, stopped, crashed, disabled };

/// What `initialize` sends and how the client behaves.
pub const InitContext = struct {
    /// Our process id (`processId`); null if unknown.
    process_id: ?i32 = null,
    client_version: []const u8 = "0.0.0",
    locale: ?[]const u8 = null,
    /// Deprecated `rootUri`, still sent for old servers.
    root_uri: ?[]const u8 = null,
    workspace_folders: []const protocol.WorkspaceFolder = &.{},
    /// Workspace folder paths, for document selectors with string patterns.
    roots: []const []const u8 = &.{},
    initialization_options: ?std.json.Value = null,
    trace: protocol.TraceValue = .Off,
    enabled: caps_mod.EnabledFeatures = .initFull(),
    cap_opts: client_capabilities.CapOpts = .{},
    init_timeout: Io.Duration = .fromSeconds(30),
    /// Default timeout of requests without their own (null: none).
    request_timeout: ?Io.Duration = null,
    trace_capacity: usize = 2000,
    /// Keep message bodies in the trace ring (`lsp.trace = verbose`).
    trace_bodies: bool = false,
    /// Extra handlers for server-to-client requests and notifications
    /// (E07.F01.S02.T03 services). They replace the built-in ones.
    request_handlers: []const NamedHandler = &.{},
    notification_handlers: []const NamedNotificationHandler = &.{},
};

pub const NamedHandler = struct { method: []const u8, handler: Endpoint.Handler };
pub const NamedNotificationHandler = struct { method: []const u8, handler: Endpoint.NotificationHandler };

pub const ReqOpts = struct {
    /// The document the request is about, for capability checks.
    doc: ?DocMatch = null,
    timeout: ?Io.Duration = null,
    priority: enum { interactive, background } = .interactive,
};

/// A request in flight, for `cancel`.
pub const ReqHandle = struct { token: u64 };

/// An LSP error response (`code`, `message`); `deinit` frees it.
pub const LspError = struct {
    code: i32,
    message: []const u8,
    resp: Endpoint.OwnedResponse,

    pub fn deinit(e: LspError) void {
        e.resp.deinit();
    }
};

/// A decoded result and the arena that owns it.
pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        resp: Endpoint.OwnedResponse,

        pub fn deinit(self: @This()) void {
            self.resp.deinit();
        }
    };
}

/// The outcome of request `M`. Call `deinit` on every result.
pub fn Result(comptime M: protocol.Method) type {
    return union(enum) {
        ok: Owned(protocol.RequestInfo(M).Result),
        lsp_error: LspError,
        /// -32800 RequestCancelled, -32802 ServerCancelled, or `cancel`.
        canceled,
        /// -32801 ContentModified.
        content_modified,
        /// The connection ended first.
        server_gone,
        timeout,
        /// The server does not provide this feature for the document.
        unsupported,

        pub fn deinit(self: @This()) void {
            switch (self) {
                .ok => |o| o.deinit(),
                .lsp_error => |e| e.deinit(),
                else => {},
            }
        }
    };
}

/// Receives a `Result(M)`; runs on a worker.
pub fn ResultCb(comptime M: protocol.Method) type {
    return struct {
        ctx: ?*anyopaque,
        func: *const fn (ctx: ?*anyopaque, r: Result(M)) void,
    };
}

/// Observes a client. Runs on whichever thread changed the state.
pub const ClientListener = struct {
    ctx: ?*anyopaque,
    on_state: *const fn (ctx: ?*anyopaque, c: *Client, s: ClientState) void,
};

/// One request, from `request` until its callback ran.
const Req = struct {
    client: *Client,
    token: u64,
    method: []const u8,
    /// Serialized params, owned.
    params: []u8,
    timeout: ?Io.Duration,
    /// The typed callback, erased.
    cb_ctx: ?*anyopaque,
    cb_func: *const anyopaque,
    finish: *const fn (r: *Req, res: Endpoint.Result) void,
    reject: *const fn (r: *Req, why: Rejection) void,
    feature: ?caps_mod.Feature,
    doc: ?DocMatch,
    ep_id: ?i64 = null,
    sent_ns: i96 = 0,
};

const Rejection = enum { unsupported, server_gone, canceled };

rt: *zg_core.Runtime,
gpa: Allocator,
io: Io,
proc: *ServerProcess,
ep: *Endpoint,
ctx: InitContext,
mutex: Io.Mutex = .init,
state_: std.atomic.Value(ClientState) = .init(.spawning),
caps_: ?caps_mod.ServerCaps = null,
encoding_: position.PositionEncoding = .utf16,
server_name: ?[]u8 = null,
server_version: ?[]u8 = null,
/// Requests waiting for `initialized`.
queued: std.ArrayList(*Req) = .empty,
/// Requests sent and not yet answered, by token.
inflight: std.AutoHashMapUnmanaged(u64, *Req) = .empty,
next_token: u64 = 1,
listeners: std.ArrayList(ClientListener) = .empty,
trace: trace_mod.Trace,
/// Set once `initialize` finished (either way).
init_done: Io.Event = .unset,
init_error: ?anyerror = null,
/// The endpoint closed.
closed: std.atomic.Value(bool) = .init(false),

/// Wires a client to `proc`'s transport. Call `subscribe` as needed, then
/// `start`. Worker only.
pub fn create(rt: *zg_core.Runtime, proc: *ServerProcess, ctx: InitContext) !*Client {
    rt.assertNotUi();
    const gpa = rt.gpa;
    const c = try gpa.create(Client);
    errdefer gpa.destroy(c);
    const t = proc.transport();
    const ep = try Endpoint.init(rt, .{
        .framing = .content_length,
        .dialect = .lsp,
        .default_timeout = ctx.request_timeout,
    }, t.reader, t.writer);
    errdefer ep.deinit();
    c.* = .{
        .rt = rt,
        .gpa = gpa,
        .io = rt.io,
        .proc = proc,
        .ep = ep,
        .ctx = ctx,
        .trace = try .init(gpa, rt.io, ctx.trace_capacity, ctx.trace_bodies),
    };
    errdefer c.trace.deinit();
    try c.registerBuiltins();
    for (ctx.request_handlers) |h| try ep.onRequest(h.method, h.handler);
    for (ctx.notification_handlers) |h| try ep.onNotification(h.method, h.handler);
    ep.onClose(.{ .ctx = c, .func = onEndpointClosed });
    return c;
}

/// Frees the client. Shut it down first (or let it crash); the
/// `ServerProcess` is the caller's.
pub fn deinit(c: *Client) void {
    c.ep.deinit();
    c.failAll(.server_gone);
    if (c.caps_) |*cp| cp.deinit();
    if (c.server_name) |s| c.gpa.free(s);
    if (c.server_version) |s| c.gpa.free(s);
    c.queued.deinit(c.gpa);
    c.inflight.deinit(c.gpa);
    c.listeners.deinit(c.gpa);
    c.trace.deinit();
    c.gpa.destroy(c);
}

/// Adds a listener. Call before `start`.
pub fn subscribe(c: *Client, l: ClientListener) !void {
    try c.listeners.append(c.gpa, l);
}

pub fn state(c: *const Client) ClientState {
    return c.state_.load(.acquire);
}

/// The server's capabilities; valid once `running`.
pub fn caps(c: *Client) ?*const caps_mod.ServerCaps {
    if (c.caps_) |*cp| return cp;
    return null;
}

pub fn encoding(c: *const Client) position.PositionEncoding {
    return c.encoding_;
}

pub const ServerInfo = struct { name: []const u8, version: ?[]const u8 };

/// Name and version from the `initialize` result.
pub fn serverInfo(c: *const Client) ?ServerInfo {
    const name = c.server_name orelse return null;
    return .{ .name = name, .version = c.server_version };
}

/// The protocol trace ring.
pub fn traceRing(c: *Client) *trace_mod.Trace {
    return &c.trace;
}

fn setState(c: *Client, s: ClientState) void {
    const prev = c.state_.swap(s, .acq_rel);
    if (prev == s) return;
    for (c.listeners.items) |l| l.on_state(l.ctx, c, s);
}

fn nowNs(c: *Client) i96 {
    return Io.Clock.Timestamp.now(c.io, .awake).raw.nanoseconds;
}

// ------------------------------------------------------------- lifecycle

/// Starts the endpoint and sends `initialize`. Returns at once; the
/// client moves to `running` when the handshake completes (see
/// `waitInitialized`).
pub fn start(c: *Client) !void {
    c.setState(.initializing);
    try c.ep.start();
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const params: protocol.InitializeParams = .{
        .processId = c.ctx.process_id,
        .clientInfo = .{ .name = "zigguro", .version = c.ctx.client_version },
        .locale = c.ctx.locale,
        .rootUri = c.ctx.root_uri,
        .capabilities = try client_capabilities.buildClientCapabilities(a, c.ctx.enabled, c.ctx.cap_opts),
        .initializationOptions = c.ctx.initialization_options,
        .trace = c.ctx.trace,
        .workspaceFolders = if (c.ctx.workspace_folders.len > 0) c.ctx.workspace_folders else null,
    };
    const body = try std.json.Stringify.valueAlloc(a, params, .{});
    c.trace.record(.{ .dir = .send, .kind = .request, .method = "initialize", .size = body.len, .at_ns = c.nowNs(), .body = body });
    _ = c.ep.requestAsync("initialize", message.RawJson{ .bytes = body }, .{ .timeout = c.ctx.init_timeout }, .{ .ctx = c, .func = onInitialized }) catch |e| {
        const err = if (e == error.ConnectionClosed) error.ServerGone else e;
        c.init_error = err;
        c.init_done.set(c.io);
        return err;
    };
}

/// Blocks until the handshake finished; returns its error, if any.
pub fn waitInitialized(c: *Client, timeout: Io.Duration) !void {
    c.rt.assertNotUi();
    try c.init_done.waitTimeout(c.io, .{ .duration = .{ .raw = timeout, .clock = .awake } });
    if (c.init_error) |e| return e;
}

fn onInitialized(ctx: ?*anyopaque, r: Endpoint.Result) void {
    const c: *Client = @ptrCast(@alignCast(ctx.?));
    c.finishInitialize(r) catch |err| {
        log.warn("initialize failed: {t}", .{err});
        c.init_error = err;
        c.init_done.set(c.io);
        c.failAll(.server_gone);
        // The connection is useless without a handshake.
        c.ep.close();
        return;
    };
    c.init_done.set(c.io);
}

fn finishInitialize(c: *Client, r: Endpoint.Result) !void {
    const resp = switch (r) {
        .ok => |o| o,
        .err => |e| return if (e == error.ConnectionClosed) error.ServerGone else e,
    };
    defer resp.deinit();
    c.trace.record(.{
        .dir = .recv,
        .kind = if (resp.response.err != null) .error_response else .response,
        .method = "initialize",
        .size = if (resp.response.result) |x| x.bytes.len else 0,
        .at_ns = c.nowNs(),
        .body = traceBody(resp),
    });
    if (resp.response.err) |e| {
        log.warn("initialize error {d}: {s}", .{ e.code, e.message });
        return error.InitializeFailed;
    }
    const raw = resp.response.result orelse return error.InitializeFailed;
    const a = resp.arena.allocator();
    const result = try raw.parseLeaky(protocol.InitializeResult, a, .{ .allocate = .alloc_always });
    var sc = try caps_mod.ServerCaps.fromInitializeResult(c.gpa, &result.capabilities, .{ .roots = c.ctx.roots });
    errdefer sc.deinit();

    // Position encoding, honouring clangd's legacy `offsetEncoding`.
    var offered: std.ArrayList(position.PositionEncoding) = .empty;
    defer offered.deinit(c.gpa);
    try offered.appendSlice(c.gpa, &.{ .utf8, .utf16 });
    if (c.ctx.cap_opts.offer_utf32) try offered.append(c.gpa, .utf32);
    var choice: ?[]const u8 = if (result.capabilities.positionEncoding) |pe| pe.toString() else null;
    if (choice == null) choice = legacyOffsetEncoding(a, raw.bytes);
    const enc = position.negotiate(offered.items, choice);

    const name: ?[]u8 = if (result.serverInfo) |si| try c.gpa.dupe(u8, si.name) else null;
    errdefer if (name) |n| c.gpa.free(n);
    const version: ?[]u8 = if (result.serverInfo) |si| (if (si.version) |v| try c.gpa.dupe(u8, v) else null) else null;

    c.mutex.lockUncancelable(c.io);
    c.caps_ = sc;
    c.encoding_ = enc;
    c.server_name = name;
    c.server_version = version;
    c.mutex.unlock(c.io);

    try c.ep.notify("initialized", protocol.InitializedParams{});
    c.trace.record(.{ .dir = .send, .kind = .notification, .method = "initialized", .size = 2, .at_ns = c.nowNs(), .body = "{}" });
    if (c.state() == .initializing) c.setState(.running);
    c.flushQueued();
}

/// clangd before 21 answers `offsetEncoding` at the top level of the
/// result.
fn legacyOffsetEncoding(a: Allocator, result_json: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, result_json, .{}) catch return null;
    if (v != .object) return null;
    const oe = v.object.get("offsetEncoding") orelse return null;
    return if (oe == .string) oe.string else null;
}

fn onEndpointClosed(ctx: ?*anyopaque, _: Endpoint.Result) void {
    const c: *Client = @ptrCast(@alignCast(ctx.?));
    // Runs once, also when our own `ep.close` races end of input.
    if (c.closed.swap(true, .acq_rel)) return;
    switch (c.state()) {
        .shutting_down, .stopped => c.setState(.stopped),
        .crashed, .disabled => {},
        else => {
            log.info("{s}: connection lost", .{if (c.server_name) |n| n else "server"});
            c.setState(.crashed);
        },
    }
    if (!c.init_done.isSet()) {
        c.init_error = error.ServerGone;
        c.init_done.set(c.io);
    }
    c.failAll(.server_gone);
}

/// `shutdown` (2 s), `exit`, then terminate the process if it has not
/// exited within 1 s.
/// Worker only.
pub fn shutdown(c: *Client) void {
    c.rt.assertNotUi();
    switch (c.state()) {
        .stopped, .crashed, .disabled => {
            c.proc.terminate(.fromSeconds(1));
            return;
        },
        else => {},
    }
    c.setState(.shutting_down);
    c.failQueued(.server_gone);
    const sent_ns = c.nowNs();
    c.trace.record(.{ .dir = .send, .kind = .request, .method = "shutdown", .at_ns = sent_ns });
    if (c.ep.request("shutdown", {}, .{ .timeout = .fromSeconds(2) })) |r| {
        defer r.deinit();
        const now = c.nowNs();
        c.trace.record(.{
            .dir = .recv,
            .kind = if (r.response.err != null) .error_response else .response,
            .method = "shutdown",
            .latency_ns = @intCast(@max(0, now - sent_ns)),
            .at_ns = now,
            .body = traceBody(r),
        });
    } else |err| log.debug("shutdown: {t}", .{err});
    c.ep.notify("exit", {}) catch {};
    c.trace.record(.{ .dir = .send, .kind = .notification, .method = "exit", .at_ns = c.nowNs() });
    // Let the server exit on its own before our side of the pipe closes.
    c.proc.exitEvent().waitTimeout(c.io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } }) catch {};
    c.proc.terminate(.fromMilliseconds(100));
    c.ep.close();
    c.setState(.stopped);
}

// ------------------------------------------------------------- requests

/// The feature `M` belongs to, if capability-gated.
fn featureOf(comptime M: protocol.Method) ?caps_mod.Feature {
    inline for (comptime std.enums.values(caps_mod.Feature)) |f| {
        if (comptime std.mem.eql(u8, caps_mod.spec(f).method, @tagName(M))) return f;
    }
    return null;
}

fn Thunk(comptime M: protocol.Method) type {
    return struct {
        const T = protocol.RequestInfo(M).Result;

        fn callback(r: *Req) ResultCb(M) {
            return .{ .ctx = r.cb_ctx, .func = @ptrCast(@alignCast(r.cb_func)) };
        }

        fn finish(r: *Req, res: Endpoint.Result) void {
            callback(r).func(r.cb_ctx, decode(res));
        }

        fn reject(r: *Req, why: Rejection) void {
            callback(r).func(r.cb_ctx, switch (why) {
                .unsupported => .unsupported,
                .server_gone => .server_gone,
                .canceled => .canceled,
            });
        }

        fn decode(res: Endpoint.Result) Result(M) {
            const resp = switch (res) {
                .ok => |o| o,
                .err => |e| return switch (e) {
                    error.Canceled => .canceled,
                    error.Timeout => .timeout,
                    else => .server_gone,
                },
            };
            if (resp.response.err) |e| {
                switch (e.code) {
                    -32800, -32802 => {
                        resp.deinit();
                        return .canceled;
                    },
                    -32801 => {
                        resp.deinit();
                        return .content_modified;
                    },
                    else => return .{ .lsp_error = .{ .code = e.code, .message = e.message, .resp = resp } },
                }
            }
            const value: T = blk: {
                if (T == void) break :blk {};
                const raw = resp.response.result orelse {
                    if (@typeInfo(T) == .optional) break :blk null;
                    return invalid(resp);
                };
                break :blk raw.parseLeaky(T, resp.arena.allocator(), .{ .allocate = .alloc_always }) catch return invalid(resp);
            };
            return .{ .ok = .{ .value = value, .resp = resp } };
        }

        fn invalid(resp: Endpoint.OwnedResponse) Result(M) {
            return .{ .lsp_error = .{ .code = message.ErrorCode.parse_error.int(), .message = "result does not match the protocol", .resp = resp } };
        }
    };
}

/// Sends request `M` (queued while initializing); `cb` gets the result on
/// a worker. Cheap enough for the UI thread: serializes `params` and
/// enqueues the frame.
pub fn request(c: *Client, comptime M: protocol.Method, params: protocol.RequestInfo(M).Params, opts: ReqOpts, cb: ResultCb(M)) !ReqHandle {
    const Th = Thunk(M);
    const body = try std.json.Stringify.valueAlloc(c.gpa, params, .{});
    errdefer c.gpa.free(body);
    const r = try c.gpa.create(Req);
    r.* = .{
        .client = c,
        .token = 0,
        .method = @tagName(M),
        .params = body,
        .timeout = opts.timeout,
        .cb_ctx = cb.ctx,
        .cb_func = @ptrCast(cb.func),
        .finish = Th.finish,
        .reject = Th.reject,
        .feature = comptime featureOf(M),
        .doc = opts.doc,
    };
    c.mutex.lockUncancelable(c.io);
    r.token = c.next_token;
    c.next_token += 1;
    const st = c.state();
    if (st == .spawning or st == .initializing) {
        c.queued.append(c.gpa, r) catch |err| {
            c.mutex.unlock(c.io);
            c.freeReq(r);
            return err;
        };
        c.mutex.unlock(c.io);
        return .{ .token = r.token };
    }
    c.mutex.unlock(c.io);
    if (st != .running) {
        c.rejectReq(r, .server_gone);
        return .{ .token = r.token };
    }
    c.send(r);
    return .{ .token = r.token };
}

fn freeReq(c: *Client, r: *Req) void {
    c.gpa.free(r.params);
    c.gpa.destroy(r);
}

fn rejectReq(c: *Client, r: *Req, why: Rejection) void {
    r.reject(r, why);
    c.freeReq(r);
}

/// Checks capabilities and sends `r` (state is `running`).
fn send(c: *Client, r: *Req) void {
    if (r.feature) |f| {
        const ok = if (c.caps_) |*cp| cp.supports(f, r.doc) else false;
        if (!ok) return c.rejectReq(r, .unsupported);
    }
    c.mutex.lockUncancelable(c.io);
    c.inflight.put(c.gpa, r.token, r) catch {
        c.mutex.unlock(c.io);
        return c.rejectReq(r, .server_gone);
    };
    c.mutex.unlock(c.io);
    r.sent_ns = c.nowNs();
    c.trace.record(.{ .dir = .send, .kind = .request, .method = r.method, .size = r.params.len, .at_ns = r.sent_ns, .body = r.params });
    const id = c.ep.requestAsync(r.method, message.RawJson{ .bytes = r.params }, .{ .timeout = r.timeout }, .{ .ctx = r, .func = onResponse }) catch {
        c.mutex.lockUncancelable(c.io);
        const still = c.inflight.remove(r.token);
        c.mutex.unlock(c.io);
        if (still) c.rejectReq(r, .server_gone);
        return;
    };
    c.mutex.lockUncancelable(c.io);
    r.ep_id = id;
    c.mutex.unlock(c.io);
}

fn onResponse(ctx: ?*anyopaque, res: Endpoint.Result) void {
    const r: *Req = @ptrCast(@alignCast(ctx.?));
    const c = r.client;
    c.mutex.lockUncancelable(c.io);
    _ = c.inflight.remove(r.token);
    c.mutex.unlock(c.io);
    const now = c.nowNs();
    switch (res) {
        .ok => |o| c.trace.record(.{
            .dir = .recv,
            .kind = if (o.response.err != null) .error_response else .response,
            .method = r.method,
            .id = r.ep_id,
            .size = if (o.response.result) |x| x.bytes.len else 0,
            .latency_ns = @intCast(@max(0, now - r.sent_ns)),
            .at_ns = now,
            .body = traceBody(o),
        }),
        .err => {},
    }
    r.finish(r, res);
    c.freeReq(r);
}

/// The trace body of a response: the result, or the error's code and
/// message.
fn traceBody(o: Endpoint.OwnedResponse) ?[]const u8 {
    if (o.response.err) |e| return std.json.Stringify.valueAlloc(o.arena.allocator(), .{
        .code = e.code,
        .message = e.message,
    }, .{}) catch null;
    return if (o.response.result) |x| x.bytes else null;
}

fn flushQueued(c: *Client) void {
    c.mutex.lockUncancelable(c.io);
    const list = c.queued;
    c.queued = .empty;
    c.mutex.unlock(c.io);
    var l = list;
    defer l.deinit(c.gpa);
    for (l.items) |r| c.send(r);
}

fn failQueued(c: *Client, why: Rejection) void {
    c.mutex.lockUncancelable(c.io);
    const list = c.queued;
    c.queued = .empty;
    c.mutex.unlock(c.io);
    var l = list;
    defer l.deinit(c.gpa);
    for (l.items) |r| c.rejectReq(r, why);
}

/// Fails queued requests; in-flight ones are failed by the endpoint.
fn failAll(c: *Client, why: Rejection) void {
    c.failQueued(why);
}

/// Cancels a request: sends `$/cancelRequest` if it was sent; the
/// callback gets `.canceled` (unless the response won the race).
pub fn cancel(c: *Client, h: ReqHandle) void {
    c.mutex.lockUncancelable(c.io);
    for (c.queued.items, 0..) |r, i| if (r.token == h.token) {
        _ = c.queued.orderedRemove(i);
        c.mutex.unlock(c.io);
        return c.rejectReq(r, .canceled);
    };
    const r = c.inflight.get(h.token);
    const id = if (r) |x| x.ep_id else null;
    c.mutex.unlock(c.io);
    if (id) |i| c.ep.cancel(i);
}

/// `request`, waiting for the result (or `timeout`). Never on the UI
/// thread.
pub fn requestBlocking(c: *Client, comptime M: protocol.Method, params: protocol.RequestInfo(M).Params, opts: ReqOpts) !Result(M) {
    c.rt.assertNotUi();
    const Wait = struct {
        event: Io.Event = .unset,
        result: ?Result(M) = null,
        io_: Io,
        fn done(ctx: ?*anyopaque, res: Result(M)) void {
            const w: *@This() = @ptrCast(@alignCast(ctx.?));
            w.result = res;
            w.event.set(w.io_);
        }
    };
    var w: Wait = .{ .io_ = c.io };
    const h = try c.request(M, params, opts, .{ .ctx = &w, .func = Wait.done });
    if (opts.timeout) |d| {
        w.event.waitTimeout(c.io, .{ .duration = .{ .raw = d, .clock = .awake } }) catch {
            c.cancel(h);
            // The callback always runs, possibly with the real result.
            w.event.waitUncancelable(c.io);
            if (w.result.? == .canceled) return .timeout;
            return w.result.?;
        };
    } else {
        w.event.waitUncancelable(c.io);
    }
    return w.result.?;
}

/// Sends notification `N` (dropped unless `running`, except `exit`).
pub fn notify(c: *Client, comptime N: protocol.NotificationMethod, params: protocol.NotificationInfo(N).Params) !void {
    if (c.state() != .running) return error.NotRunning;
    const body = try std.json.Stringify.valueAlloc(c.gpa, params, .{});
    defer c.gpa.free(body);
    c.trace.record(.{ .dir = .send, .kind = .notification, .method = @tagName(N), .size = body.len, .at_ns = c.nowNs(), .body = body });
    try c.ep.notify(@tagName(N), message.RawJson{ .bytes = body });
}

// ------------------------------------------------------------- server requests

fn registerBuiltins(c: *Client) !void {
    try c.ep.onRequest("client/registerCapability", .{ .ctx = c, .func = onRegister });
    try c.ep.onRequest("client/unregisterCapability", .{ .ctx = c, .func = onUnregister });
    try c.ep.onRequest("window/workDoneProgress/create", .{ .ctx = c, .func = onNullResult });
    try c.ep.onRequest("workspace/configuration", .{ .ctx = c, .func = onConfiguration });
}

fn onRegister(ctx: ?*anyopaque, _: *Endpoint, req: message.Request, arena: Allocator) Endpoint.HandlerResult {
    const c: *Client = @ptrCast(@alignCast(ctx.?));
    const p = req.params orelse return invalidParams();
    const params = p.parseLeaky(protocol.RegistrationParams, arena, .{}) catch return invalidParams();
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    const cp = if (c.caps_) |*x| x else return .{ .err = .{ .code = message.ErrorCode.server_not_initialized.int(), .message = "not initialized" } };
    for (params.registrations) |reg| cp.addRegistration(reg) catch |err| {
        log.warn("registerCapability {s}: {t}", .{ reg.method, err });
    };
    return nullResult(arena);
}

fn onUnregister(ctx: ?*anyopaque, _: *Endpoint, req: message.Request, arena: Allocator) Endpoint.HandlerResult {
    const c: *Client = @ptrCast(@alignCast(ctx.?));
    const p = req.params orelse return invalidParams();
    const params = p.parseLeaky(protocol.UnregistrationParams, arena, .{}) catch return invalidParams();
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    if (c.caps_) |*cp| for (params.unregisterations) |u| cp.removeRegistration(u.id);
    return nullResult(arena);
}

fn onNullResult(_: ?*anyopaque, _: *Endpoint, _: message.Request, arena: Allocator) Endpoint.HandlerResult {
    return nullResult(arena);
}

/// Answers every item with null until the settings service (T03) exists.
fn onConfiguration(_: ?*anyopaque, _: *Endpoint, req: message.Request, arena: Allocator) Endpoint.HandlerResult {
    const p = req.params orelse return invalidParams();
    const params = p.parseLeaky(protocol.ConfigurationParams, arena, .{}) catch return invalidParams();
    const out = arena.alloc(?u8, params.items.len) catch return internal();
    @memset(out, null);
    const raw = Endpoint.raw(arena, out) catch return internal();
    return .{ .result = raw };
}

fn nullResult(arena: Allocator) Endpoint.HandlerResult {
    const raw = Endpoint.raw(arena, null) catch return internal();
    return .{ .result = raw };
}

fn invalidParams() Endpoint.HandlerResult {
    return .{ .err = .{ .code = message.ErrorCode.invalid_params.int(), .message = "invalid params" } };
}

fn internal() Endpoint.HandlerResult {
    return .{ .err = .{ .code = message.ErrorCode.internal_error.int(), .message = "out of memory" } };
}
