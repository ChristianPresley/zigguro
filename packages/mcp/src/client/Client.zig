//! The MCP client core: `connect` (era detection, revision selection and,
//! for legacy servers, the `initialize` lifecycle) and `request`, the typed
//! pipeline every client feature uses: per-request `_meta`, timeouts with a
//! progress reset and hard cap, cancellation, MRTR rounds, re-issue of
//! idempotent requests after a broken modern stream, transparent
//! re-initialization after a legacy session expires, and error mapping.
//!
//! Threading: every public function blocks and asserts it is not on the UI
//! thread; the host runs them in subsystem tasks. Requests may run
//! concurrently. `close` must not race requests still in flight.

const Client = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_jsonrpc = @import("zg_jsonrpc");
const zg_net = @import("zg_net");
const protocol = @import("../protocol/root.zig");
const transport_mod = @import("../transport/root.zig");
const era_mod = @import("era.zig");
const meta_mod = @import("meta.zig");
const request_mod = @import("request.zig");

const Transport = transport_mod.Transport;
const Revision = protocol.Revision;
const Era = protocol.revision.Era;
const Method = protocol.Method;
const Call = request_mod.Call;
const message = zg_jsonrpc.message;
const codec = protocol.codec;
const messages = protocol.messages;

pub const EraDetection = era_mod.EraDetection;
pub const RequestError = request_mod.RequestError;
pub const CallOptions = request_mod.CallOptions;
pub const CancelToken = request_mod.CancelToken;
pub const ErrorInfo = request_mod.ErrorInfo;

/// How to reach the server.
pub const TransportFactory = union(enum) {
    stdio: transport_mod.StdioOptions,
    http: struct {
        /// Shared; must outlive the client.
        client: *zg_net.http.Client,
        opts: transport_mod.HttpOptions,
        allow_http_sse_fallback: bool = true,
    },
    /// Owned by the caller; must outlive the client.
    in_process: *transport_mod.InProcPair,
};

/// What `connect` learned about the server. Memory belongs to the client.
pub const ServerInfo = struct {
    revision: Revision,
    era: Era,
    capabilities: protocol.ServerCapabilities,
    server_info: ?protocol.Implementation,
    instructions: ?[]const u8,
    detection: EraDetection,
};

/// Receives server notifications that belong to no request's progress
/// (list changes, log messages, resource updates, ...). Runs on transport
/// tasks; copy what you keep.
pub const NotificationHandler = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, n: protocol.Notification) void,
};

/// The answer to a legacy server request.
pub const ServerReply = union(enum) {
    /// The JSON `result`.
    result: []const u8,
    err: struct { code: i32, message: []const u8 },
};

/// Answers legacy server-to-client requests (sampling, elicitation, roots;
/// F03.S03 adapts these to the InputBroker). `ping` is answered by the
/// client itself. Runs on its own task; memory comes from `arena`.
pub const ServerRequestHandler = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, arena: Allocator, method: []const u8, params: ?std.json.Value) anyerror!ServerReply,
};

/// Called after a legacy session was re-established: catalogs are stale
/// and subscriptions must be renewed (F03.S01.T02, F03.S02.T02).
pub const SessionResetHandler = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, c: *Client) void,
};

/// Connection options.
pub const Options = struct {
    client_info: protocol.Implementation,
    features: protocol.capabilities.ClientFeatures = .{},
    /// The revisions we accept, any order.
    revisions: []const Revision = &protocol.revision.supported_newest_first,
    /// Privacy: false withholds `clientInfo` from modern requests.
    send_client_info: bool = true,
    discover_timeout: Io.Duration = .fromSeconds(5),
    default_timeout: Io.Duration = .fromSeconds(60),
    max_timeout: Io.Duration = .fromSeconds(600),
    /// A cached detection (F07): skips the probe, falling back to full
    /// detection when the server answers in a way the hinted era cannot.
    era_hint: ?EraDetection = null,
    on_notification: ?NotificationHandler = null,
    on_server_request: ?ServerRequestHandler = null,
    on_session_reset: ?SessionResetHandler = null,
};

/// Errors from `connect`.
pub const ConnectError = RequestError || error{ CommandNotFound, AccessDenied, SpawnFailed };

const Owner = union(enum) {
    stdio: *transport_mod.StdioTransport,
    modern: *transport_mod.HttpModernTransport,
    legacy: *transport_mod.HttpLegacyTransport,
    sse: *transport_mod.HttpSseTransport,
    in_process: *transport_mod.InProcPair,
};

const State = enum { connecting, initializing, ready, closed };

rt: *zg_core.Runtime,
gpa: Allocator,
io: Io,
opts: Options,
/// Owns the options' strings, the capabilities and the server info.
arena: std.heap.ArenaAllocator,
owner: Owner,
modern_caps: protocol.ClientCapabilities,
info: ServerInfo,
next_id: std.atomic.Value(i64) = .init(1),
mutex: Io.Mutex = .init,
calls: std.ArrayList(*Call) = .empty,
inbound: Transport.InboundSink,
state: State = .connecting,
/// Set while requests may flow (cleared during legacy re-initialization).
ready: Io.Event = .unset,
reinit_mutex: Io.Mutex = .init,
/// Bumped by every successful (re-)initialization.
generation: std.atomic.Value(u32) = .init(0),
handlers: zg_core.runtime.Subsystem,

/// Connects to the server and detects its era. Blocks; not on the UI thread.
pub fn connect(rt: *zg_core.Runtime, gpa: Allocator, factory: TransportFactory, opts: Options) ConnectError!*Client {
    rt.assertNotUi();
    const c = try gpa.create(Client);
    c.* = .{
        .rt = rt,
        .gpa = gpa,
        .io = rt.io,
        .opts = opts,
        .arena = .init(gpa),
        .owner = undefined,
        .modern_caps = undefined,
        .info = .{
            .revision = protocol.revision.Revision.latest,
            .era = .modern,
            .capabilities = .empty,
            .server_info = null,
            .instructions = null,
            .detection = .{ .era = .modern, .revision = protocol.revision.Revision.latest, .transport = .in_process, .reason = "" },
        },
        .inbound = .{ .ctx = undefined, .onNotification = inboundNotification, .onServerRequest = inboundServerRequest, .onClosed = inboundClosed },
        .handlers = .init(rt.io),
    };
    c.inbound.ctx = c;
    errdefer {
        c.handlers.shutdown();
        c.calls.deinit(gpa);
        c.arena.deinit();
        gpa.destroy(c);
    }
    const a = c.arena.allocator();
    c.opts.revisions = try a.dupe(Revision, opts.revisions);
    c.opts.client_info = try dupeImpl(a, opts.client_info);
    c.modern_caps = try protocol.capabilities.defaultClient(a, opts.features);

    switch (factory) {
        .stdio => |so| {
            const t = transport_mod.StdioTransport.start(rt, gpa, so) catch |err| return switch (err) {
                error.CommandNotFound => error.CommandNotFound,
                error.AccessDenied => error.AccessDenied,
                error.OutOfMemory => error.OutOfMemory,
                error.SpawnFailed, error.ConcurrencyUnavailable => error.SpawnFailed,
            };
            c.adopt(.{ .stdio = t });
            errdefer c.dropTransport();
            try c.detectStream();
        },
        .in_process => |pair| {
            c.adopt(.{ .in_process = pair });
            errdefer c.dropTransport();
            try c.detectStream();
        },
        .http => |h| try c.detectHttp(h.client, h.opts, h.allow_http_sse_fallback),
    }
    c.state = .ready;
    c.ready.set(c.io);
    return c;
}

/// Cancels whatever is left, closes the transport and frees the client.
/// Requests must have returned (the host cancels their tasks first).
pub fn close(c: *Client) void {
    c.mutex.lockUncancelable(c.io);
    c.state = .closed;
    c.mutex.unlock(c.io);
    c.ready.set(c.io); // Wake requests waiting for a re-initialization.
    c.handlers.shutdown();
    c.dropTransport();
    c.calls.deinit(c.gpa);
    c.arena.deinit();
    c.gpa.destroy(c);
}

/// What `connect` learned.
pub fn serverInfo(c: *const Client) *const ServerInfo {
    return &c.info;
}

/// The active transport.
pub fn transport(c: *const Client) Transport {
    return switch (c.owner) {
        inline else => |t| t.transport(),
    };
}

/// The capabilities this client declares to modern servers.
pub fn clientCapabilities(c: *const Client) protocol.ClientCapabilities {
    return c.modern_caps;
}

/// Sends request `M` and returns its complete result (memory in
/// `o.arena`). Handles `_meta`, timeouts, cancellation, MRTR rounds,
/// broken modern streams and expired legacy sessions.
pub fn request(c: *Client, comptime M: Method, params: messages.ParamsType(M), o: CallOptions) RequestError!messages.ResultType(M) {
    c.rt.assertNotUi();
    const zone = zg_core.trace.zone(@src(), "mcp.request");
    defer zone.end();
    if (!protocol.revision.methodAllowed(c.info.revision, M, .client_to_server)) return error.MethodNotAllowed;
    var p = params;
    var rounds: u32 = 0;
    var reissued = false;
    var reinitialized = false;
    while (true) {
        if (M != .ping) try c.waitReady(o);
        // Each attempt gets a fresh progress token with its new id.
        p.meta = params.meta;
        const generation = c.generation.load(.acquire);
        const call = try c.exchange(M, &p, c.info.revision, c.info.era, &o, false);
        defer call.destroy();
        switch (call.outcome) {
            .pending => unreachable,
            .failure => |f| switch (f) {
                .stream_broken => if (c.info.era == .modern and request_mod.isIdempotent(M) and !reissued) {
                    // CL2026 item 9: a new request with a new id.
                    reissued = true;
                    continue;
                } else return request_mod.mapFailure(o.arena, f, o.error_info),
                .session_expired => if (c.info.era == .legacy and !reinitialized) {
                    reinitialized = true;
                    try c.reinitialize(generation);
                    // Never replay a tool call: it may have run.
                    if (M == .tools_call) return error.SessionExpired;
                    continue;
                } else return request_mod.mapFailure(o.arena, f, o.error_info),
                else => return request_mod.mapFailure(o.arena, f, o.error_info),
            },
            .response => |r| {
                if (r.err) |e| return request_mod.mapRpcError(o.arena, e.code, e.message, e.data, o.error_info);
                const raw = r.result orelse return error.ProtocolViolation;
                var diag: codec.Diagnostic = .{};
                const decoded = codec.decodeResult(messages.ResultType(M), o.arena, .{ .bytes = raw }, .{ .diag = &diag }) catch |err| {
                    if (o.error_info) |info| info.detail = o.arena.dupe(u8, diag.pointer()) catch "";
                    return if (err == error.OutOfMemory) error.OutOfMemory else error.ProtocolViolation;
                };
                switch (decoded) {
                    .complete => |v| return v,
                    .task => return error.ProtocolViolation, // Only with allow_task (F03.S04).
                    .input_required => |ir| if (comptime request_mod.mrtrAllowed(M)) {
                        rounds += 1;
                        if (rounds > o.max_input_rounds) return error.TooManyInputRounds;
                        const reqs = ir.input_requests orelse messages.InputRequests{};
                        for (reqs.entries) |e| if (!request_mod.inputDeclared(c.modern_caps, e.value)) {
                            if (o.error_info) |info| info.detail = std.fmt.allocPrint(o.arena, "undeclared input request {s} ({s})", .{ e.key, e.value.method() }) catch "";
                            return error.ProtocolViolation;
                        };
                        // Only `requestState`: retry at once.
                        var answers: ?messages.InputResponses = null;
                        if (reqs.entries.len > 0) {
                            const h = o.input orelse return error.InputDeclined;
                            answers = (h.func(h.ctx, o.arena, reqs) catch |err| return switch (err) {
                                error.Canceled => error.Canceled,
                                error.OutOfMemory => error.OutOfMemory,
                                else => error.InputDeclined,
                            }) orelse return error.InputDeclined;
                        }
                        // A new id (exchange), the original params, the
                        // answers and `requestState` byte for byte.
                        p.input_responses = answers;
                        p.request_state = if (ir.request_state) |s| try o.arena.dupe(u8, s) else null;
                    } else return error.ProtocolViolation,
                }
            },
        }
    }
}

/// Sends notification `n` (era-appropriate `_meta` is the caller's).
pub fn notify(c: *Client, n: protocol.Notification) RequestError!void {
    return c.notifyOrdered(n, false);
}

fn notifyOrdered(c: *Client, n: protocol.Notification, ordered: bool) RequestError!void {
    c.rt.assertNotUi();
    var aw: Io.Writer.Allocating = .init(c.gpa);
    defer aw.deinit();
    n.write(&aw.writer) catch return error.OutOfMemory;
    c.transport().notify(.{ .method_str = n.method(), .body = aw.written(), .revision = c.info.revision, .ordered = ordered }) catch |err|
        return mapSendError(err);
}

// ---------------------------------------------------------------- exchange

/// Sends one request and waits for its outcome. On `.done` the caller
/// owns (and destroys) the returned call; on timeout or cancellation the
/// transport's cancellation is sent and an error returned.
fn exchange(c: *Client, comptime M: Method, p: *messages.ParamsType(M), rev: Revision, era: Era, o: *const CallOptions, probe: bool) RequestError!*Call {
    const id_num = c.next_id.fetchAdd(1, .monotonic);
    const id: protocol.RequestId = .{ .int = id_num };
    p.meta = try meta_mod.merge(p.meta, era, .{
        .revision = rev,
        .client_capabilities = c.modern_caps,
        .client_info = if (c.opts.send_client_info) c.opts.client_info else null,
        .log_level = o.log_level,
        .progress_token = if (probe) null else .{ .int = id_num },
        .traceparent = o.traceparent,
        .tracestate = o.tracestate,
    });
    const token = if (p.meta) |m| m.progress_token else null;
    const timeout = if (probe) c.opts.discover_timeout else o.timeout orelse c.opts.default_timeout;
    const max = if (probe) c.opts.discover_timeout else o.max_timeout orelse c.opts.max_timeout;
    const call = try Call.create(c.gpa, c.io, id, token, .{ .ctx = c, .onNotification = callNotification, .onServerRequest = callServerRequest }, o.on_progress, timeout, max);
    errdefer call.destroy();

    var aw: Io.Writer.Allocating = .init(call.arena.allocator());
    message.writeRequest(&aw.writer, id, M.string(), codec.json(p.*)) catch return error.OutOfMemory;
    const P = messages.ParamsType(M);
    const name: ?[]const u8 = if (@hasField(P, "name")) p.name else if (@hasField(P, "uri")) p.uri else null;

    try c.register(call);
    if (o.cancel) |t| if (!t.attach(call)) {
        c.unregister(call);
        return error.Canceled;
    };
    defer if (o.cancel) |t| t.detach();
    const t = c.transport();
    t.request(.{
        .id = id,
        .method = M,
        .method_str = M.string(),
        .name_for_header = name,
        .param_headers = o.param_headers,
        .body = aw.written(),
        .revision = rev,
        .timeout = timeout,
    }, &call.sink) catch |err| {
        c.unregister(call);
        return mapSendError(err);
    };
    const r = call.wait();
    switch (r) {
        .done => {
            c.unregister(call);
            return call;
        },
        .timeout, .canceled => {
            const reason: ?[]const u8 = if (r == .timeout) "timeout" else if (o.cancel) |tok| tok.reason else null;
            t.cancel(id, reason);
            call.waitFinal(); // Late responses land here and are dropped.
            c.unregister(call);
            return if (r == .timeout) error.Timeout else error.Canceled;
        },
    }
}

fn register(c: *Client, call: *Call) RequestError!void {
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    if (c.state == .closed) return error.ConnectionClosed;
    try c.calls.append(c.gpa, call);
}

fn unregister(c: *Client, call: *Call) void {
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    for (c.calls.items, 0..) |x, i| if (x == call) {
        _ = c.calls.swapRemove(i);
        return;
    };
}

fn waitReady(c: *Client, o: CallOptions) RequestError!void {
    if (c.ready.isSet()) return;
    c.ready.waitTimeout(c.io, .{ .duration = .{ .raw = o.timeout orelse c.opts.default_timeout, .clock = .awake } }) catch return error.Timeout;
    if (c.state == .closed) return error.ConnectionClosed;
}

fn mapSendError(err: Transport.SendError) RequestError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Closed, error.ConcurrencyUnavailable => error.ConnectionClosed,
        error.InvalidMessage => error.ProtocolViolation,
    };
}

// ---------------------------------------------------------------- era detection

fn adopt(c: *Client, o: Owner) void {
    c.owner = o;
    c.transport().setInbound(&c.inbound);
}

fn dropTransport(c: *Client) void {
    switch (c.owner) {
        .in_process => |p| {
            // The pair belongs to the caller: detach without closing it.
            p.mutex.lockUncancelable(p.io);
            p.inbound = null;
            p.mutex.unlock(p.io);
        },
        .stdio => |t| t.deinit(),
        .modern => |t| t.deinit(),
        .legacy => |t| t.deinit(),
        .sse => |t| t.deinit(),
    }
}

/// The outcome of one probe exchange, reduced to what era detection needs.
const Probe = union(enum) {
    era: era_mod.ProbeResponse,
    /// An HTTP status without a modern error body.
    http_status: u16,
    /// A failure that is not about the era (process exit, network down).
    fatal: RequestError,
};

fn probeDiscover(c: *Client, rev: Revision, scratch: Allocator) RequestError!Probe {
    var p: messages.BaseParams = .{};
    const o: CallOptions = .{ .arena = scratch };
    const call = c.exchange(.server_discover, &p, rev, .modern, &o, true) catch |err| switch (err) {
        error.Timeout => return .{ .era = .no_response },
        else => return err,
    };
    defer call.destroy();
    return c.classify(messages.DiscoverResult, call, scratch, true);
}

fn classify(c: *Client, comptime T: type, call: *Call, arena: Allocator, keep: bool) RequestError!Probe {
    switch (call.outcome) {
        .pending => unreachable,
        .failure => |f| return switch (f) {
            .http_status => |h| .{ .http_status = h.status },
            .timeout, .protocol => .{ .era = .no_response },
            else => .{ .fatal = request_mod.mapFailure(arena, f, null) },
        },
        .response => |r| {
            if (r.err) |e| {
                const data: ?std.json.Value = if (e.data) |d| std.json.parseFromSliceLeaky(std.json.Value, arena, d, .{}) catch null else null;
                return .{ .era = .{ .rpc_error = .{ .code = e.code, .data = data } } };
            }
            const raw = r.result orelse return .{ .era = .no_response };
            const a = if (keep) c.arena.allocator() else arena;
            const decoded = codec.decodeResult(T, a, .{ .bytes = try a.dupe(u8, raw) }, .{}) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .era = .no_response };
            };
            if (decoded != .complete) return .{ .era = .no_response };
            if (T == messages.DiscoverResult) return .{ .era = .{ .result = decoded.complete } };
            return .{ .era = .no_response };
        },
    }
}

/// stdio and in-process detection.
fn detectStream(c: *Client) ConnectError!void {
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const s = scratch.allocator();
    if (c.opts.era_hint) |h| if (h.era == .legacy) {
        if (try c.legacyInit(h.revision, "cached era hint")) |_| return;
        // The hint was wrong: detect from scratch.
    };
    var asked = era_mod.newestModern(c.opts.revisions) orelse {
        const l = era_mod.newestLegacy(c.opts.revisions) orelse return error.UnsupportedRevision;
        return c.requireLegacy(l, "client speaks only legacy revisions");
    };
    var probes: u32 = 0;
    while (true) : (probes += 1) {
        const probe = try c.probeDiscover(asked, s);
        const resp: era_mod.ProbeResponse = switch (probe) {
            .era => |e| e,
            .http_status => .no_response,
            .fatal => |err| return err,
        };
        switch (era_mod.decide(c.opts.revisions, asked, resp)) {
            .modern => |r| return c.setModern(r, resp.result, "server/discover succeeded"),
            .retry_modern => |r| {
                if (probes > 0) return error.UnsupportedRevision;
                asked = r;
            },
            .legacy => |r| return c.requireLegacy(r, legacyReason(resp)),
            .missing_capability => return error.MissingRequiredClientCapability,
            .unsupported => return error.UnsupportedRevision,
        }
    }
}

fn legacyReason(resp: era_mod.ProbeResponse) []const u8 {
    return switch (resp) {
        .result => "server/discover listed only legacy revisions",
        .rpc_error => "server/discover returned an error",
        .no_response => "server/discover went unanswered",
    };
}

/// HTTP detection: modern POST, then legacy Streamable HTTP, then HTTP+SSE.
fn detectHttp(c: *Client, client: *zg_net.http.Client, ho: transport_mod.HttpOptions, allow_sse: bool) ConnectError!void {
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const s = scratch.allocator();
    const hint = c.opts.era_hint;
    const legacy_rev = era_mod.newestLegacy(c.opts.revisions);
    if (hint == null or hint.?.era == .modern) if (era_mod.newestModern(c.opts.revisions)) |first| {
        const t = transport_mod.HttpModernTransport.init(c.rt, client, c.gpa, ho) catch |err| return mapInitError(err);
        c.adopt(.{ .modern = t });
        var asked = first;
        var probes: u32 = 0;
        const decision: era_mod.Decision, const resp: era_mod.ProbeResponse = while (true) : (probes += 1) {
            const probe = c.probeDiscover(asked, s) catch |err| {
                c.dropTransport();
                return err;
            };
            const resp: era_mod.ProbeResponse = switch (probe) {
                .era => |e| e,
                .http_status => |st| if (st / 100 == 4) .no_response else {
                    c.dropTransport();
                    return error.ServerError;
                },
                .fatal => |err| {
                    c.dropTransport();
                    return err;
                },
            };
            const d = era_mod.decide(c.opts.revisions, asked, resp);
            if (d == .retry_modern and probes == 0) {
                asked = d.retry_modern;
                continue;
            }
            break .{ d, resp };
        };
        switch (decision) {
            .modern => |r| return c.setModern(r, resp.result, "server/discover succeeded"),
            .legacy => c.dropTransport(),
            .missing_capability => {
                c.dropTransport();
                return error.MissingRequiredClientCapability;
            },
            .unsupported, .retry_modern => {
                c.dropTransport();
                return error.UnsupportedRevision;
            },
        }
    };
    const rev = if (hint) |h| (if (h.era == .legacy) h.revision else legacy_rev) else legacy_rev;
    const lr = rev orelse return error.UnsupportedRevision;
    if (hint == null or hint.?.transport != .http_sse) {
        const t = transport_mod.HttpLegacyTransport.init(c.rt, client, c.gpa, ho, lr) catch |err| return mapInitError(err);
        c.adopt(.{ .legacy = t });
        const failed = c.legacyInitOutcome(lr, "server/discover was refused; initialize succeeded") catch |err| {
            c.dropTransport();
            return err;
        };
        const failure = failed orelse {
            t.openGetStream() catch {};
            return;
        };
        c.dropTransport();
        const status = failure.http_status orelse return error.UnsupportedRevision;
        if (!(allow_sse and era_mod.isSseFallbackStatus(status))) return error.UnsupportedRevision;
    }
    if (!allow_sse) return error.UnsupportedRevision;
    const t = transport_mod.HttpSseTransport.connect(c.rt, client, c.gpa, ho) catch |err| return mapInitError(err);
    c.adopt(.{ .sse = t });
    const ok = c.legacyInit(lr, "Streamable HTTP refused; HTTP+SSE endpoint found") catch |err| {
        c.dropTransport();
        return err;
    };
    if (ok == null) {
        c.dropTransport();
        return error.UnsupportedRevision;
    }
}

fn mapInitError(err: anyerror) ConnectError {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.ConnectionClosed;
}

fn setModern(c: *Client, r: Revision, d: messages.DiscoverResult, reason: []const u8) void {
    c.info = .{
        .revision = r,
        .era = .modern,
        .capabilities = d.capabilities,
        .server_info = if (d.meta) |m| m.server_info else null,
        .instructions = d.instructions,
        .detection = .{ .era = .modern, .revision = r, .transport = c.transport().kind(), .reason = reason },
    };
    _ = c.generation.fetchAdd(1, .release);
}

fn requireLegacy(c: *Client, r: Revision, reason: []const u8) ConnectError!void {
    if (try c.legacyInit(r, reason)) |_| return;
    return error.UnsupportedRevision;
}

/// Legacy `initialize`; null when the server answered in a way no legacy
/// server would (the caller tries another era).
fn legacyInit(c: *Client, r: Revision, reason: []const u8) ConnectError!?void {
    const failed = try c.legacyInitOutcome(r, reason);
    if (failed == null) return {};
    return null;
}

/// An `initialize` that failed in a way no legacy server would answer.
const InitFailure = struct { http_status: ?u16 = null };

/// Runs `initialize` + `notifications/initialized`. Returns null on
/// success, or the era-inconsistent failure.
fn legacyInitOutcome(c: *Client, r: Revision, reason: []const u8) ConnectError!?InitFailure {
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const s = scratch.allocator();
    const a = c.arena.allocator();
    c.state = .initializing;
    var p: messages.InitializeParams = .{
        .protocol_version = r.string(),
        .capabilities = try legacyCapabilities(a, r, c.opts.features),
        .client_info = c.opts.client_info,
    };
    const o: CallOptions = .{ .arena = s, .timeout = c.opts.default_timeout };
    const call = c.exchange(.initialize, &p, r, .legacy, &o, false) catch |err| switch (err) {
        error.Timeout => return .{},
        else => return err,
    };
    defer call.destroy();
    const result: messages.InitializeResult = switch (call.outcome) {
        .pending => unreachable,
        .failure => |f| switch (f) {
            .http_status => |h| return .{ .http_status = h.status },
            .timeout, .protocol => return .{},
            else => return request_mod.mapFailure(s, f, null),
        },
        .response => |resp| blk: {
            if (resp.err != null) return .{};
            const raw = resp.result orelse return .{};
            const d = codec.decodeResult(messages.InitializeResult, a, .{ .bytes = try a.dupe(u8, raw) }, .{}) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{};
            };
            if (d != .complete) return .{};
            break :blk d.complete;
        },
    };
    // L1125: accept a legacy revision we implement, else disconnect.
    const negotiated = protocol.negotiate.legacyNegotiate(r, result.protocol_version) catch return error.UnsupportedRevision;
    if (std.mem.indexOfScalar(Revision, c.opts.revisions, negotiated) == null) return error.UnsupportedRevision;
    c.info = .{
        .revision = negotiated,
        .era = .legacy,
        .capabilities = result.capabilities,
        .server_info = result.server_info,
        .instructions = result.instructions,
        .detection = .{ .era = .legacy, .revision = negotiated, .transport = c.transport().kind(), .reason = reason },
    };
    switch (c.owner) {
        .legacy => |t| t.setRevision(negotiated),
        else => {},
    }
    // Ordered: no request may reach the server before `initialized`.
    try c.notifyOrdered(.{ .initialized = .{} }, true);
    _ = c.generation.fetchAdd(1, .release);
    return null;
}

/// The legacy client capability shape for revision `r` (L1125).
pub fn legacyCapabilities(arena: Allocator, r: Revision, f: protocol.capabilities.ClientFeatures) Allocator.Error!protocol.ClientCapabilities {
    const has = protocol.revision.has;
    var b: protocol.capabilities.Builder = .init(arena);
    if (f.roots) try b.set("roots.listChanged", .{ .bool = true });
    if (f.sampling) try b.set(if (f.sampling_tools and has(r, .sampling_tools)) "sampling.tools" else "sampling", null);
    if (has(r, .elicitation_url)) {
        if (f.elicitation_form) try b.set("elicitation.form", null);
        if (f.elicitation_url) try b.set("elicitation.url", null);
    } else if (has(r, .elicitation_form) and f.elicitation_form) {
        try b.set("elicitation", null);
    }
    if (f.tasks and has(r, .tasks_core)) {
        if (f.sampling) try b.set("tasks.requests.sampling.createMessage", null);
        if (f.elicitation_form or f.elicitation_url) try b.set("tasks.requests.elicitation.create", null);
    }
    return b.finish();
}

/// Re-runs `initialize` after the session expired, once per expiry: the
/// first request to notice does it while the others wait on `ready`.
fn reinitialize(c: *Client, seen_generation: u32) RequestError!void {
    c.reinit_mutex.lockUncancelable(c.io);
    defer c.reinit_mutex.unlock(c.io);
    if (c.generation.load(.acquire) != seen_generation) return; // Someone else already did.
    c.ready.reset();
    defer c.ready.set(c.io);
    const ok = c.legacyInit(c.info.revision, "session expired; re-initialized") catch |err| return switch (err) {
        error.CommandNotFound, error.AccessDenied, error.SpawnFailed => error.ConnectionClosed,
        else => |e| e,
    };
    if (ok == null) return error.SessionExpired;
    c.state = .ready;
    if (c.opts.on_session_reset) |h| h.func(h.ctx, c);
}

// ---------------------------------------------------------------- inbound

fn findCallByToken(c: *Client, token: protocol.ProgressToken) ?*Call {
    for (c.calls.items) |call| if (call.ownsToken(token)) return call;
    return null;
}

fn inboundNotification(ctx: ?*anyopaque, n: protocol.Notification, raw: message.Notification) void {
    const c: *Client = @ptrCast(@alignCast(ctx.?));
    if (n == .progress) {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        // Under the lock: the call cannot be unregistered and freed meanwhile.
        if (c.findCallByToken(n.progress.progress_token)) |call| return call.progress(n.progress);
        return;
    }
    callNotification(ctx, n, raw);
}

fn callNotification(ctx: ?*anyopaque, n: protocol.Notification, _: message.Notification) void {
    const c: *Client = @ptrCast(@alignCast(ctx.?));
    if (n == .progress) return; // Not this call's token: stale.
    if (c.opts.on_notification) |h| h.func(h.ctx, n);
}

fn inboundServerRequest(ctx: ?*anyopaque, r: message.Request) void {
    callServerRequest(ctx, r);
}

fn inboundClosed(ctx: ?*anyopaque, _: Transport.TransportError) void {
    const c: *Client = @ptrCast(@alignCast(ctx.?));
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    if (c.state == .ready) c.state = .closed;
}

/// A legacy server request (on the inbound stream or a POST's stream).
fn callServerRequest(ctx: ?*anyopaque, r: message.Request) void {
    const c: *Client = @ptrCast(@alignCast(ctx.?));
    if (std.mem.eql(u8, r.method, "ping")) return c.reply(r.id, .{ .result = "{}" });
    const h = c.opts.on_server_request orelse return c.reply(r.id, .{ .err = .{ .code = protocol.errors.method_not_found, .message = "Method not found" } });
    const job = Job.create(c, r) catch return c.reply(r.id, .{ .err = .{ .code = protocol.errors.internal_error, .message = "out of memory" } });
    c.handlers.spawnLoop(Job.run, .{ job, h }) catch {
        job.destroy();
        c.reply(r.id, .{ .err = .{ .code = protocol.errors.internal_error, .message = "client busy" } });
    };
}

/// A server request copied off the transport's task.
const Job = struct {
    c: *Client,
    arena: std.heap.ArenaAllocator,
    id: protocol.RequestId,
    method: []const u8,
    params: ?std.json.Value,

    fn create(c: *Client, r: message.Request) !*Job {
        const j = try c.gpa.create(Job);
        j.* = .{ .c = c, .arena = .init(c.gpa), .id = undefined, .method = undefined, .params = null };
        errdefer j.destroy();
        const a = j.arena.allocator();
        j.id = switch (r.id) {
            .str => |s| .{ .str = try a.dupe(u8, s) },
            else => r.id,
        };
        j.method = try a.dupe(u8, r.method);
        if (r.params) |p| j.params = try codec.parseValue(a, p.bytes);
        return j;
    }

    fn destroy(j: *Job) void {
        j.arena.deinit();
        j.c.gpa.destroy(j);
    }

    fn run(j: *Job, h: ServerRequestHandler) void {
        defer j.destroy();
        const reply_v = h.func(h.ctx, j.arena.allocator(), j.method, j.params) catch
            ServerReply{ .err = .{ .code = protocol.errors.internal_error, .message = "handler failed" } };
        j.c.reply(j.id, reply_v);
    }
};

fn reply(c: *Client, id: protocol.RequestId, r: ServerReply) void {
    var aw: Io.Writer.Allocating = .init(c.gpa);
    defer aw.deinit();
    switch (r) {
        .result => |res| message.writeResult(&aw.writer, id, message.RawJson{ .bytes = res }) catch return,
        .err => |e| message.writeError(&aw.writer, id, e.code, e.message, null) catch return,
    }
    c.transport().respond(aw.written(), c.info.revision) catch {};
}

fn dupeImpl(a: Allocator, i: protocol.Implementation) Allocator.Error!protocol.Implementation {
    var out = i;
    out.name = try a.dupe(u8, i.name);
    out.version = try a.dupe(u8, i.version);
    if (i.title) |t| out.title = try a.dupe(u8, t);
    return out;
}
