//! A full-duplex JSON-RPC 2.0 peer: the LSP client, the MCP client and the
//! MCP server SDK all sit on one of these.
//!
//! Threads. `start` runs a reader loop, a writer loop and a timer loop, each
//! on its own unit of concurrency (`Subsystem.spawnLoop`). Any thread may
//! send: frames are serialized by the caller and queued (`std.Io.Queue`), so
//! no lock is held during I/O. Incoming requests run as `Subsystem.spawn`
//! tasks, each with its own arena. Notification handlers run inline on the
//! reader loop and must be quick. Callbacks (`requestAsync`, `onClose`) run
//! on the reader or timer loop; reach the UI only through `Runtime.post`.
//!
//! Ownership. A `RawJson` handed to a handler is valid only during the
//! handler (or, for deferred requests, until `respond`); copy what you keep.
//! An `OwnedResponse` owns its memory; the receiver calls `deinit`.
//!
//! Ids. Outgoing ids are a monotonically increasing `i64`. A caller may pass
//! its own (MCP retries). Responses for unknown or cancelled ids are dropped.
//!
//! Batches. Requests inside an incoming batch are answered one by one, not
//! as a batch array (LSP never batches; MCP no longer does).

const Endpoint = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const Subsystem = zg_core.runtime.Subsystem;
const framing = @import("framing.zig");
const message = @import("message.zig");
const dialect = @import("dialect.zig");
const Id = message.Id;

pub const Dialect = dialect.Dialect;

pub const Config = struct {
    framing: framing.Framing,
    dialect: Dialect,
    /// Outgoing requests awaiting a response; more give `error.TooManyInFlight`.
    max_in_flight: u32 = 4096,
    default_timeout: ?Io.Duration = null,
    opts: framing.Options = .{},
    /// Frames queued for the writer loop before senders block.
    write_queue: u32 = 1024,
};

pub const CallOptions = struct {
    timeout: ?Io.Duration = null,
    /// A caller-chosen id (must not be in flight).
    id: ?i64 = null,
};

/// A response together with the arena that owns it.
pub const OwnedResponse = struct {
    response: message.Response,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: OwnedResponse) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

pub const Result = union(enum) { ok: OwnedResponse, err: anyerror };

/// Receives a `Result`. Runs on the reader or timer loop.
pub const Callback = struct { ctx: ?*anyopaque, func: *const fn (?*anyopaque, Result) void };

pub const HandlerResult = union(enum) {
    result: message.RawJson,
    err: message.ErrorObject,
    /// The handler will call `respond` / `respondError` later.
    deferred,
};

/// Handles one incoming request. `arena` lives until the reply is sent.
pub const Handler = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, ep: *Endpoint, req: message.Request, arena: Allocator) HandlerResult,
};

/// Handles one incoming notification, inline on the reader loop.
pub const NotificationHandler = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, ep: *Endpoint, n: message.Notification, arena: Allocator) void,
};

const Pending = struct {
    id: i64,
    seq: u64 = 0,
    event: Io.Event = .unset,
    result: ?Result = null,
    cb: ?Callback = null,
};

const Incoming = struct {
    arena: std.heap.ArenaAllocator,
    req: message.Request,
    handler: Handler,
    canceled: std.atomic.Value(bool) = .init(false),
};

const Deadline = struct { at: i96, id: i64, seq: u64 };

fn deadlineOrder(_: void, a: Deadline, b: Deadline) std.math.Order {
    return std.math.order(a.at, b.at);
}

const IdContext = struct {
    pub fn hash(_: IdContext, id: Id) u64 {
        return id.hash();
    }
    pub fn eql(_: IdContext, a: Id, b: Id) bool {
        return a.eql(b);
    }
};

rt: *zg_core.Runtime,
gpa: Allocator,
io: Io,
cfg: Config,
frames: framing.FrameReader,
writer: *Io.Writer,
out: Io.Queue([]u8),
out_buf: [][]u8,
loops: Subsystem,
writer_loop: Subsystem,
tasks: Subsystem,
mutex: Io.Mutex = .init,
pending: std.AutoHashMapUnmanaged(i64, *Pending) = .empty,
deadlines: std.PriorityQueue(Deadline, void, deadlineOrder) = .empty,
timer_event: Io.Event = .unset,
incoming: std.HashMapUnmanaged(Id, *Incoming, IdContext, 80) = .empty,
request_handlers: std.StringHashMapUnmanaged(Handler) = .empty,
notification_handlers: std.StringHashMapUnmanaged(NotificationHandler) = .empty,
close_cb: ?Callback = null,
scratch: std.heap.ArenaAllocator,
next_id: std.atomic.Value(i64) = .init(1),
next_seq: std.atomic.Value(u64) = .init(1),
closed: std.atomic.Value(bool) = .init(false),
closing: std.atomic.Value(bool) = .init(false),
finished: std.atomic.Value(bool) = .init(false),
started: bool = false,

/// Creates an endpoint on `reader` / `writer`; register handlers, then `start`.
pub fn init(rt: *zg_core.Runtime, cfg: Config, reader: *Io.Reader, writer: *Io.Writer) !*Endpoint {
    const gpa = rt.gpa;
    const ep = try gpa.create(Endpoint);
    errdefer gpa.destroy(ep);
    const out_buf = try gpa.alloc([]u8, cfg.write_queue);
    ep.* = .{
        .rt = rt,
        .gpa = gpa,
        .io = rt.io,
        .cfg = cfg,
        .frames = .init(cfg.framing, reader, cfg.opts),
        .writer = writer,
        .out = .init(out_buf),
        .out_buf = out_buf,
        .loops = .init(rt.io),
        .writer_loop = .init(rt.io),
        .tasks = .init(rt.io),
        .scratch = .init(gpa),
    };
    return ep;
}

/// Registers a request handler. Call before `start`.
pub fn onRequest(self: *Endpoint, method: []const u8, h: Handler) !void {
    std.debug.assert(!self.started);
    try self.request_handlers.put(self.gpa, method, h);
}

/// Registers a notification handler. Call before `start`.
pub fn onNotification(self: *Endpoint, method: []const u8, h: NotificationHandler) !void {
    std.debug.assert(!self.started);
    try self.notification_handlers.put(self.gpa, method, h);
}

/// Called once when the connection closes, with `error.ConnectionClosed`.
pub fn onClose(self: *Endpoint, cb: Callback) void {
    self.close_cb = cb;
}

/// Starts the reader, writer and timer loops.
pub fn start(self: *Endpoint) !void {
    self.started = true;
    try self.writer_loop.spawnLoop(writerLoop, .{self});
    errdefer self.writer_loop.shutdown();
    try self.loops.spawnLoop(readerLoop, .{self});
    try self.loops.spawnLoop(timerLoop, .{self});
}

/// Sends a request and blocks until the response, a timeout or
/// cancellation. Never call on the UI thread.
pub fn request(self: *Endpoint, method: []const u8, params: anytype, opts: CallOptions) !OwnedResponse {
    self.rt.assertNotUi();
    var p: Pending = .{ .id = 0 };
    const id = try self.register(&p, opts.id);
    self.sendRequest(id, method, params) catch |err| {
        _ = self.unregister(id);
        return err;
    };
    const timeout: Io.Timeout = if (opts.timeout orelse self.cfg.default_timeout) |d|
        .{ .duration = .{ .raw = d, .clock = .awake } }
    else
        .none;
    p.event.waitTimeout(self.io, timeout) catch |err| {
        if (self.unregister(id) != null) {
            self.sendCancel(.{ .int = id }) catch {};
            return err;
        }
        // The reader already took it and is about to resolve it.
        p.event.waitUncancelable(self.io);
    };
    return switch (p.result.?) {
        .ok => |r| r,
        .err => |e| e,
    };
}

/// Sends a request; `cb` receives the result on the reader or timer loop.
/// Returns the request id (for `cancel`).
pub fn requestAsync(self: *Endpoint, method: []const u8, params: anytype, opts: CallOptions, cb: Callback) !i64 {
    const p = try self.gpa.create(Pending);
    p.* = .{ .id = 0, .cb = cb, .seq = self.next_seq.fetchAdd(1, .monotonic) };
    const id = self.register(p, opts.id) catch |err| {
        self.gpa.destroy(p);
        return err;
    };
    if (opts.timeout orelse self.cfg.default_timeout) |d| {
        const at = Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds + d.nanoseconds;
        self.mutex.lockUncancelable(self.io);
        const pushed = self.deadlines.push(self.gpa, .{ .at = at, .id = id, .seq = p.seq });
        self.mutex.unlock(self.io);
        pushed catch {
            _ = self.unregister(id);
            self.gpa.destroy(p);
            return error.OutOfMemory;
        };
        self.timer_event.set(self.io);
    }
    self.sendRequest(id, method, params) catch |err| {
        if (self.unregister(id)) |q| self.gpa.destroy(q);
        return err;
    };
    return id;
}

/// Sends a notification.
pub fn notify(self: *Endpoint, method: []const u8, params: anytype) !void {
    var aw: Io.Writer.Allocating = .init(self.gpa);
    errdefer aw.deinit();
    message.writeNotification(&aw.writer, method, params) catch return error.OutOfMemory;
    try self.enqueue(try aw.toOwnedSlice());
}

/// Cancels an outgoing request: sends the dialect's cancel notification and
/// resolves it locally with `error.Canceled`. A late reply is dropped.
pub fn cancel(self: *Endpoint, id: i64) void {
    const p = self.unregister(id) orelse return;
    self.sendCancel(.{ .int = id }) catch {};
    self.resolve(p, .{ .err = error.Canceled });
}

/// Replies to an incoming request (for handlers that returned `.deferred`).
pub fn respond(self: *Endpoint, id: Id, result: anytype) !void {
    var aw: Io.Writer.Allocating = .init(self.gpa);
    errdefer aw.deinit();
    message.writeResult(&aw.writer, id, result) catch return error.OutOfMemory;
    const frame = try aw.toOwnedSlice();
    self.finishIncoming(id);
    try self.enqueue(frame);
}

/// Replies to an incoming request with an error.
pub fn respondError(self: *Endpoint, id: Id, code: i32, msg: []const u8) !void {
    return self.respondErrorObject(id, .{ .code = code, .message = msg });
}

/// True once the peer cancelled incoming request `id`; long handlers poll it.
pub fn isCanceled(self: *Endpoint, id: Id) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const inc = self.incoming.get(id) orelse return true;
    return inc.canceled.load(.acquire);
}

/// Serializes `value` into `arena` as a `RawJson` result for handlers.
pub fn raw(arena: Allocator, value: anytype) !message.RawJson {
    return .{ .bytes = try std.json.Stringify.valueAlloc(arena, value, .{}) };
}

/// Stops the endpoint: writes the frames already queued, stops the loops
/// and handler tasks, and fails pending requests with
/// `error.ConnectionClosed`. Idempotent. Blocks until queued frames drain.
pub fn close(self: *Endpoint) void {
    if (self.closing.swap(true, .acq_rel)) return;
    self.closed.store(true, .release);
    self.out.close(self.io);
    if (self.started) {
        self.writer_loop.join() catch {};
        self.loops.shutdown();
        self.tasks.shutdown();
    }
    self.finish(error.ConnectionClosed);
}

/// Closes and frees the endpoint.
pub fn deinit(self: *Endpoint) void {
    self.close();
    const gpa = self.gpa;
    var it = self.incoming.valueIterator();
    while (it.next()) |inc| {
        inc.*.arena.deinit();
        gpa.destroy(inc.*);
    }
    self.incoming.deinit(gpa);
    self.pending.deinit(gpa);
    self.deadlines.deinit(gpa);
    self.request_handlers.deinit(gpa);
    self.notification_handlers.deinit(gpa);
    self.frames.deinit(gpa);
    self.scratch.deinit();
    // Frames queued after the writer loop stopped.
    var left: [16][]u8 = undefined;
    while (true) {
        const n = self.out.getUncancelable(self.io, &left, 0) catch break;
        if (n == 0) break;
        for (left[0..n]) |f| gpa.free(f);
    }
    gpa.free(self.out_buf);
    gpa.destroy(self);
}

fn register(self: *Endpoint, p: *Pending, want: ?i64) !i64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.closed.load(.acquire)) return error.ConnectionClosed;
    if (self.pending.count() >= self.cfg.max_in_flight) return error.TooManyInFlight;
    const id = want orelse self.next_id.fetchAdd(1, .monotonic);
    const gop = try self.pending.getOrPut(self.gpa, id);
    if (gop.found_existing) return error.DuplicateId;
    p.id = id;
    gop.value_ptr.* = p;
    return id;
}

fn unregister(self: *Endpoint, id: i64) ?*Pending {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const kv = self.pending.fetchRemove(id) orelse return null;
    return kv.value;
}

/// Delivers `result` to a pending request the caller has unregistered.
fn resolve(self: *Endpoint, p: *Pending, result: Result) void {
    if (p.cb) |cb| {
        self.gpa.destroy(p);
        cb.func(cb.ctx, result);
    } else {
        p.result = result;
        p.event.set(self.io);
    }
}

fn sendRequest(self: *Endpoint, id: i64, method: []const u8, params: anytype) !void {
    var aw: Io.Writer.Allocating = .init(self.gpa);
    errdefer aw.deinit();
    message.writeRequest(&aw.writer, .{ .int = id }, method, params) catch return error.OutOfMemory;
    try self.enqueue(try aw.toOwnedSlice());
}

fn sendCancel(self: *Endpoint, id: Id) !void {
    if (self.cfg.dialect == .plain) return;
    var aw: Io.Writer.Allocating = .init(self.gpa);
    errdefer aw.deinit();
    dialect.writeCancel(self.cfg.dialect, &aw.writer, id, "cancelled by client") catch return error.OutOfMemory;
    try self.enqueue(try aw.toOwnedSlice());
}

fn respondErrorObject(self: *Endpoint, id: Id, e: message.ErrorObject) !void {
    var aw: Io.Writer.Allocating = .init(self.gpa);
    errdefer aw.deinit();
    message.writeError(&aw.writer, id, e.code, e.message, e.data) catch return error.OutOfMemory;
    const frame = try aw.toOwnedSlice();
    self.finishIncoming(id);
    try self.enqueue(frame);
}

/// Queues an owned frame for the writer loop (frees it on failure).
fn enqueue(self: *Endpoint, frame: []u8) !void {
    self.out.putOneUncancelable(self.io, frame) catch {
        self.gpa.free(frame);
        return error.ConnectionClosed;
    };
}

fn finishIncoming(self: *Endpoint, id: Id) void {
    self.mutex.lockUncancelable(self.io);
    const kv = self.incoming.fetchRemove(id);
    self.mutex.unlock(self.io);
    if (kv) |e| {
        e.value.arena.deinit();
        self.gpa.destroy(e.value);
    }
}

fn writerLoop(self: *Endpoint) Io.Cancelable!void {
    var batch: [32][]u8 = undefined;
    var failed = false;
    while (true) {
        const n = self.out.get(self.io, &batch, 1) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
        for (batch[0..n]) |frame| {
            if (!failed) framing.writeFrameUnflushed(self.cfg.framing, self.writer, frame) catch |err| {
                if (err != error.EmbeddedNewline) failed = true;
            };
            self.gpa.free(frame);
        }
        if (!failed) self.writer.flush() catch {
            failed = true;
        };
    }
}

fn readerLoop(self: *Endpoint) Io.Cancelable!void {
    defer self.finish(error.ConnectionClosed);
    while (true) {
        _ = self.scratch.reset(.retain_capacity);
        const body = self.frames.next(self.gpa) catch |err| {
            if (framing.isFatal(err)) return;
            const code: message.ErrorCode = if (err == error.MessageTooLarge) .invalid_request else .parse_error;
            self.respondErrorObject(.null, .{ .code = code.int(), .message = @errorName(err) }) catch {};
            continue;
        };
        self.handleFrame(body);
    }
}

fn handleFrame(self: *Endpoint, body: []const u8) void {
    const arena = self.scratch.allocator();
    switch (message.parse(arena, body)) {
        .single => |m| self.handleMessage(m),
        .batch => |entries| for (entries) |e| switch (e) {
            .message => |m| self.handleMessage(m),
            .invalid => |eo| self.respondErrorObject(.null, eo) catch {},
        },
        .invalid => |eo| self.respondErrorObject(.null, eo) catch {},
    }
}

fn handleMessage(self: *Endpoint, m: message.Message) void {
    switch (m) {
        .response => |r| self.handleResponse(r),
        .request => |req| self.handleRequest(req),
        .notification => |n| self.handleNotification(n),
    }
}

fn handleResponse(self: *Endpoint, r: message.Response) void {
    if (r.id != .int) return;
    const p = self.unregister(r.id.int) orelse return; // late or unknown: drop
    const owned = copyResponse(self.gpa, r) catch |err| return self.resolve(p, .{ .err = err });
    self.resolve(p, .{ .ok = owned });
}

fn copyResponse(gpa: Allocator, r: message.Response) !OwnedResponse {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    const a = arena.allocator();
    var out: message.Response = .{ .id = r.id };
    if (r.result) |x| out.result = .{ .bytes = try a.dupe(u8, x.bytes) };
    if (r.err) |e| out.err = .{
        .code = e.code,
        .message = try a.dupe(u8, e.message),
        .data = if (e.data) |d| .{ .bytes = try a.dupe(u8, d.bytes) } else null,
    };
    return .{ .response = out, .arena = arena };
}

fn dupeId(a: Allocator, id: Id) !Id {
    return switch (id) {
        .str => |s| .{ .str = try a.dupe(u8, s) },
        else => id,
    };
}

fn handleRequest(self: *Endpoint, req: message.Request) void {
    const h = self.request_handlers.get(req.method) orelse {
        self.respondErrorObject(req.id, .{ .code = message.ErrorCode.method_not_found.int(), .message = "Method not found" }) catch {};
        return;
    };
    const inc = self.gpa.create(Incoming) catch return self.internalError(req.id);
    inc.* = .{ .arena = .init(self.gpa), .req = undefined, .handler = h };
    const a = inc.arena.allocator();
    inc.req = .{
        .id = dupeId(a, req.id) catch return self.dropIncoming(inc, req.id),
        .method = a.dupe(u8, req.method) catch return self.dropIncoming(inc, req.id),
        .params = if (req.params) |p| .{ .bytes = a.dupe(u8, p.bytes) catch return self.dropIncoming(inc, req.id) } else null,
    };
    self.mutex.lockUncancelable(self.io);
    const gop = self.incoming.getOrPut(self.gpa, inc.req.id) catch {
        self.mutex.unlock(self.io);
        return self.dropIncoming(inc, req.id);
    };
    if (gop.found_existing) {
        self.mutex.unlock(self.io);
        inc.arena.deinit();
        self.gpa.destroy(inc);
        self.respondErrorObject(req.id, .{ .code = message.ErrorCode.invalid_request.int(), .message = "Duplicate request id" }) catch {};
        return;
    }
    gop.value_ptr.* = inc;
    self.mutex.unlock(self.io);
    self.tasks.spawn(runHandler, .{ self, inc });
}

fn dropIncoming(self: *Endpoint, inc: *Incoming, id: Id) void {
    inc.arena.deinit();
    self.gpa.destroy(inc);
    self.internalError(id);
}

fn internalError(self: *Endpoint, id: Id) void {
    self.respondErrorObject(id, .{ .code = message.ErrorCode.internal_error.int(), .message = "Out of memory" }) catch {};
}

fn runHandler(self: *Endpoint, inc: *Incoming) void {
    const res = inc.handler.func(inc.handler.ctx, self, inc.req, inc.arena.allocator());
    switch (res) {
        .result => |r| self.respond(inc.req.id, r) catch {},
        .err => |e| self.respondErrorObject(inc.req.id, e) catch {},
        .deferred => {},
    }
}

fn handleNotification(self: *Endpoint, n: message.Notification) void {
    const arena = self.scratch.allocator();
    if (dialect.cancelledId(self.cfg.dialect, arena, n)) |id| {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.incoming.get(id)) |inc| inc.canceled.store(true, .release);
        return;
    }
    const h = self.notification_handlers.get(n.method) orelse return;
    h.func(h.ctx, self, n, arena);
}

fn timerLoop(self: *Endpoint) Io.Cancelable!void {
    while (true) {
        var expired: [64]*Pending = undefined;
        var n: usize = 0;
        var next: ?i96 = null;
        const now = Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (self.deadlines.peek()) |d| {
                if (d.at > now) {
                    next = d.at;
                    break;
                }
                if (n == expired.len) {
                    next = now;
                    break;
                }
                _ = self.deadlines.pop();
                const p = self.pending.get(d.id) orelse continue;
                if (p.seq != d.seq) continue;
                _ = self.pending.remove(d.id);
                expired[n] = p;
                n += 1;
            }
        }
        for (expired[0..n]) |p| {
            self.sendCancel(.{ .int = p.id }) catch {};
            self.resolve(p, .{ .err = error.Timeout });
        }
        const t: Io.Timeout = if (next) |at|
            .{ .deadline = .{ .raw = .{ .nanoseconds = at }, .clock = .awake } }
        else
            .none;
        self.timer_event.waitTimeout(self.io, t) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
        self.timer_event.reset();
    }
}

/// Marks the endpoint closed and fails every pending request. Idempotent.
fn finish(self: *Endpoint, err: anyerror) void {
    if (self.finished.swap(true, .acq_rel)) return;
    self.closed.store(true, .release);
    self.mutex.lockUncancelable(self.io);
    var old = self.pending;
    self.pending = .empty;
    self.deadlines.deinit(self.gpa);
    self.deadlines = .empty;
    self.mutex.unlock(self.io);
    var it = old.valueIterator();
    while (it.next()) |p| self.resolve(p.*, .{ .err = err });
    old.deinit(self.gpa);
    if (self.close_cb) |cb| cb.func(cb.ctx, .{ .err = err });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const PipePair = @import("testing.zig").PipePair;
const ScriptedPeer = @import("testing.zig").ScriptedPeer;

const Fixture = struct {
    rt: zg_core.Runtime,
    pipe: *PipePair,
    ep: *Endpoint,

    fn init(f: *Fixture, cfg: Config) !void {
        f.rt.initTesting();
        f.pipe = try PipePair.init(testing.allocator, testing.io, 1 << 20);
        f.ep = try Endpoint.init(&f.rt, cfg, f.pipe.a_reader, f.pipe.a_writer);
    }

    fn deinit(f: *Fixture) void {
        f.pipe.closeB();
        f.ep.deinit();
        f.pipe.deinit();
        _ = f.rt.deinit();
    }

    fn peer(f: *Fixture, fr: framing.Framing) ScriptedPeer {
        return .init(testing.allocator, fr, f.pipe.b_reader, f.pipe.b_writer);
    }
};

const Collector = struct {
    mutex: Io.Mutex = .init,
    done: Io.Event = .unset,
    want: u32,
    got: u32 = 0,
    errors: u32 = 0,
    last_err: ?anyerror = null,
    sum: i64 = 0,

    fn callback(c: *Collector) Callback {
        return .{ .ctx = c, .func = onResult };
    }

    fn onResult(ctx: ?*anyopaque, r: Result) void {
        const c: *Collector = @ptrCast(@alignCast(ctx.?));
        c.mutex.lockUncancelable(testing.io);
        defer c.mutex.unlock(testing.io);
        switch (r) {
            .ok => |o| {
                if (o.response.result) |x| c.sum += std.fmt.parseInt(i64, x.bytes, 10) catch 0;
                o.deinit();
            },
            .err => |e| {
                c.errors += 1;
                c.last_err = e;
            },
        }
        c.got += 1;
        if (c.got == c.want) c.done.set(testing.io);
    }
};

/// Reads `n` NDJSON requests from the pipe and answers each with its id as
/// the result, in reverse order.
fn reverseEcho(pipe: *PipePair, n: usize) Io.Cancelable!void {
    const gpa = testing.allocator;
    var nd: framing.NdjsonReader = .init(pipe.b_reader, .{});
    defer nd.deinit(gpa);
    const ids = gpa.alloc(i64, n) catch return;
    defer gpa.free(ids);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (ids) |*id| {
        const body = nd.next(gpa) catch return;
        id.* = message.parse(arena.allocator(), body).single.request.id.int;
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        var buf: [128]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        message.writeResult(&w, .{ .int = ids[i] }, ids[i]) catch return;
        framing.writeNdjson(pipe.b_writer, w.buffered()) catch return;
    }
}

test "endpoint: 1000 concurrent requests from 8 threads" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.init(.{ .framing = .ndjson, .dialect = .lsp });
    defer f.deinit();
    try f.ep.start();
    var c: Collector = .{ .want = 1000 };
    var echo = try io.concurrent(reverseEcho, .{ f.pipe, 1000 });
    defer echo.cancel(io) catch {};
    const Sender = struct {
        fn run(ep: *Endpoint, col: *Collector) Io.Cancelable!void {
            for (0..125) |_| _ = ep.requestAsync("echo", .{}, .{}, col.callback()) catch {};
        }
    };
    var g: Io.Group = .init;
    for (0..8) |_| try g.concurrent(io, Sender.run, .{ f.ep, &c });
    try g.await(io);
    try c.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try testing.expectEqual(@as(u32, 0), c.errors);
    try testing.expectEqual(@as(i64, 1000 * 1001 / 2), c.sum);
}

test "endpoint: lsp cancel sends $/cancelRequest and drops late reply" {
    var f: Fixture = undefined;
    try f.init(.{ .framing = .content_length, .dialect = .lsp });
    defer f.deinit();
    try f.ep.start();
    var c: Collector = .{ .want = 1 };
    const id = try f.ep.requestAsync("textDocument/hover", .{ .x = 1 }, .{}, c.callback());
    f.ep.cancel(id);
    var peer = f.peer(.content_length);
    defer peer.deinit();
    try peer.run(
        \\< {"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{"x":1}}
        \\< {"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":1}}
        \\> {"jsonrpc":"2.0","id":1,"result":42}
    );
    try c.done.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try testing.expectEqual(@as(u32, 1), c.errors);
    try testing.expectEqual(error.Canceled, c.last_err.?);
}

test "endpoint: mcp cancel sends notifications/cancelled" {
    var f: Fixture = undefined;
    try f.init(.{ .framing = .ndjson, .dialect = .mcp });
    defer f.deinit();
    try f.ep.start();
    var c: Collector = .{ .want = 1 };
    const id = try f.ep.requestAsync("tools/call", .{}, .{ .id = 77 }, c.callback());
    try testing.expectEqual(@as(i64, 77), id);
    f.ep.cancel(id);
    var peer = f.peer(.ndjson);
    defer peer.deinit();
    try peer.run(
        \\< {"jsonrpc":"2.0","id":77,"method":"tools/call","params":{}}
        \\< {"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":77,"reason":"cancelled by client"}}
    );
}

test "endpoint: unknown method -> -32601" {
    var f: Fixture = undefined;
    try f.init(.{ .framing = .ndjson, .dialect = .plain });
    defer f.deinit();
    try f.ep.start();
    var peer = f.peer(.ndjson);
    defer peer.deinit();
    try peer.run(
        \\> {"jsonrpc":"2.0","id":5,"method":"nope"}
        \\< {"jsonrpc":"2.0","id":5,"error":{"code":-32601,"message":"Method not found"}}
        \\> not json
        \\< {"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
    );
}

test "endpoint: notification handler invoked, no reply" {
    var f: Fixture = undefined;
    try f.init(.{ .framing = .ndjson, .dialect = .lsp });
    defer f.deinit();
    const State = struct {
        seen: Io.Event = .unset,
        value: i64 = 0,
        fn handle(ctx: ?*anyopaque, _: *Endpoint, n: message.Notification, arena: Allocator) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            const P = struct { v: i64 };
            s.value = (n.params.?.parseLeaky(P, arena, .{}) catch return).v;
            s.seen.set(testing.io);
        }
        fn echo(_: ?*anyopaque, _: *Endpoint, req: message.Request, arena: Allocator) HandlerResult {
            return .{ .result = Endpoint.raw(arena, req.method) catch unreachable };
        }
    };
    var s: State = .{};
    try f.ep.onNotification("tick", .{ .ctx = &s, .func = State.handle });
    try f.ep.onRequest("ping", .{ .ctx = null, .func = State.echo });
    try f.ep.start();
    var peer = f.peer(.ndjson);
    defer peer.deinit();
    try peer.run(
        \\> {"jsonrpc":"2.0","method":"tick","params":{"v":9}}
        \\> {"jsonrpc":"2.0","id":1,"method":"ping"}
        \\< {"jsonrpc":"2.0","id":1,"result":"ping"}
    );
    try s.seen.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try testing.expectEqual(@as(i64, 9), s.value);
}

test "endpoint: timeout -> error.Timeout + cancel sent" {
    var f: Fixture = undefined;
    try f.init(.{ .framing = .ndjson, .dialect = .lsp });
    defer f.deinit();
    try f.ep.start();
    try testing.expectError(error.Timeout, f.ep.request("slow", .{}, .{ .timeout = .fromMilliseconds(20) }));
    var c: Collector = .{ .want = 1 };
    _ = try f.ep.requestAsync("slow", .{}, .{ .timeout = .fromMilliseconds(20) }, c.callback());
    try c.done.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try testing.expectEqual(error.Timeout, c.last_err.?);
    var peer = f.peer(.ndjson);
    defer peer.deinit();
    try peer.run(
        \\< {"jsonrpc":"2.0","id":1,"method":"slow","params":{}}
        \\< {"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":1}}
        \\< {"jsonrpc":"2.0","id":2,"method":"slow","params":{}}
        \\< {"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":2}}
    );
}

test "endpoint: sync request gets the response" {
    var f: Fixture = undefined;
    try f.init(.{ .framing = .content_length, .dialect = .lsp });
    defer f.deinit();
    try f.ep.start();
    const io = testing.io;
    var echo = try io.concurrent(struct {
        fn run(pipe: *PipePair) Io.Cancelable!void {
            var peer: ScriptedPeer = .init(testing.allocator, .content_length, pipe.b_reader, pipe.b_writer);
            defer peer.deinit();
            peer.run(
                \\< {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null}}
                \\> {"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}
            ) catch {};
        }
    }.run, .{f.pipe});
    defer echo.cancel(io) catch {};
    const r = try f.ep.request("initialize", .{ .processId = @as(?i32, null) }, .{ .timeout = .fromSeconds(5) });
    defer r.deinit();
    try testing.expectEqualStrings("{\"capabilities\":{}}", r.response.result.?.bytes);
}

test "endpoint: peer close fails pending" {
    var f: Fixture = undefined;
    try f.init(.{ .framing = .ndjson, .dialect = .lsp });
    defer f.deinit();
    var closed: Collector = .{ .want = 1 };
    f.ep.onClose(closed.callback());
    try f.ep.start();
    var c: Collector = .{ .want = 2 };
    _ = try f.ep.requestAsync("a", .{}, .{}, c.callback());
    _ = try f.ep.requestAsync("b", .{}, .{}, c.callback());
    f.pipe.closeB();
    try c.done.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try testing.expectEqual(@as(u32, 2), c.errors);
    try testing.expectEqual(error.ConnectionClosed, c.last_err.?);
    try closed.done.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try testing.expectError(error.ConnectionClosed, f.ep.requestAsync("c", .{}, .{}, c.callback()));
}

test "endpoint: deferred response" {
    var f: Fixture = undefined;
    try f.init(.{ .framing = .ndjson, .dialect = .mcp });
    defer f.deinit();
    const State = struct {
        id: ?Id = null,
        ready: Io.Event = .unset,
        fn handle(ctx: ?*anyopaque, _: *Endpoint, req: message.Request, _: Allocator) HandlerResult {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.id = req.id;
            s.ready.set(testing.io);
            return .deferred;
        }
    };
    var s: State = .{};
    try f.ep.onRequest("later", .{ .ctx = &s, .func = State.handle });
    try f.ep.start();
    var peer = f.peer(.ndjson);
    defer peer.deinit();
    try peer.run("> {\"jsonrpc\":\"2.0\",\"id\":\"q\",\"method\":\"later\"}");
    try s.ready.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try testing.expect(!f.ep.isCanceled(s.id.?));
    try peer.run("> {\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\"q\"}}");
    // Cancellation is cooperative: wait until the reader has seen it.
    for (0..500) |_| {
        if (f.ep.isCanceled(s.id.?)) break;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expect(f.ep.isCanceled(s.id.?));
    try f.ep.respond(s.id.?, .{ .done = true });
    try peer.run("< {\"jsonrpc\":\"2.0\",\"id\":\"q\",\"result\":{\"done\":true}}");
}

test "endpoint: string ids from peer echoed exactly" {
    var f: Fixture = undefined;
    try f.init(.{ .framing = .content_length, .dialect = .lsp });
    defer f.deinit();
    const H = struct {
        fn handle(_: ?*anyopaque, _: *Endpoint, _: message.Request, arena: Allocator) HandlerResult {
            return .{ .result = Endpoint.raw(arena, @as(?u8, null)) catch unreachable };
        }
    };
    try f.ep.onRequest("m", .{ .ctx = null, .func = H.handle });
    try f.ep.start();
    var peer = f.peer(.content_length);
    defer peer.deinit();
    try peer.run(
        \\> {"jsonrpc":"2.0","id":"a\"bé","method":"m"}
        \\< {"jsonrpc":"2.0","id":"a\"bé","result":null}
        \\> {"jsonrpc":"2.0","id":-9007199254740993,"method":"m"}
        \\< {"jsonrpc":"2.0","id":-9007199254740993,"result":null}
    );
}

test "endpoint: no leaks after close with work in flight" {
    var f: Fixture = undefined;
    try f.init(.{ .framing = .ndjson, .dialect = .lsp });
    defer f.deinit();
    const H = struct {
        fn handle(_: ?*anyopaque, _: *Endpoint, _: message.Request, _: Allocator) HandlerResult {
            return .deferred;
        }
    };
    try f.ep.onRequest("hang", .{ .ctx = null, .func = H.handle });
    try f.ep.start();
    var c: Collector = .{ .want = 3 };
    for (0..3) |_| _ = try f.ep.requestAsync("x", .{}, .{ .timeout = .fromSeconds(60) }, c.callback());
    var peer = f.peer(.ndjson);
    defer peer.deinit();
    try peer.run("> {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"hang\"}");
    f.ep.close();
    try testing.expectEqual(@as(u32, 3), c.errors);
}
