//! A full-duplex DAP peer: requests numbered by `seq` with a pending table,
//! responses matched by `request_seq`, events and reverse requests
//! dispatched strictly in wire order, the `cancel` request, and
//! per-command timeouts. It reuses the zg_jsonrpc Content-Length framer and
//! the zg_lsp transports, but not the JSON-RPC message model.
//!
//! Threads. `start` runs a reader loop, a dispatcher loop, a writer loop
//! and a timer loop. The reader only frames and queues; the dispatcher
//! decodes and delivers responses, events and reverse requests one at a
//! time, so a `stopped` event is never handled before the `continue`
//! response that preceded it. Session logic runs on the dispatcher: keep
//! callbacks short, never block on another request from inside one, and
//! never call `close` or `deinit` from one. Timeouts are delivered on the
//! timer loop.
//!
//! seq. Starts at 1 and is shared by our requests and our responses to
//! reverse requests. Numbering and queueing happen under one lock, so
//! frames go out in seq order.

const DapConnection = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_jsonrpc = @import("zg_jsonrpc");
const zg_lsp = @import("zg_lsp");
const Subsystem = zg_core.runtime.Subsystem;
const framing = zg_jsonrpc.framing;
const protocol = @import("../gen/protocol.zig");
const message = @import("message.zig");
const Transport = zg_lsp.transport.Transport;
const Trace = zg_lsp.client.trace.Trace;

pub const RawJson = message.RawJson;
const log = std.log.scoped(.dap);

pub const Timeouts = struct {
    initialize: Io.Duration = .fromSeconds(10),
    /// `launch` and `attach`.
    launch: Io.Duration = .fromSeconds(60),
    default: Io.Duration = .fromSeconds(15),

    fn forCommand(t: Timeouts, command: []const u8) Io.Duration {
        if (std.mem.eql(u8, command, "initialize")) return t.initialize;
        if (std.mem.eql(u8, command, "launch") or std.mem.eql(u8, command, "attach")) return t.launch;
        return t.default;
    }
};

pub const Options = struct {
    timeouts: Timeouts = .{},
    /// Records every message sent and received.
    trace: ?*Trace = null,
    framing: framing.Options = .{},
    /// Frames queued for the writer loop before senders block.
    write_queue: u32 = 1024,
    /// Frames read but not yet dispatched before the reader blocks.
    read_queue: u32 = 1024,
};

/// A response to one of our requests.
pub const Response = struct {
    request_seq: u32,
    success: bool,
    command: []const u8,
    /// Short failure reason, e.g. `cancelled` or `notStopped`.
    message: ?[]const u8,
    body: ?RawJson,
    /// `body.error` of a failed response.
    error_body: ?protocol.Message,
};

/// A response and the arena that owns it.
pub const OwnedResponse = struct {
    response: Response,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: OwnedResponse) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }

    /// The text to show for a failed response: the formatted `body.error`
    /// if present, else `message`.
    pub fn errorText(self: OwnedResponse) []const u8 {
        if (self.response.error_body) |e|
            return message.formatMessage(self.arena.allocator(), e) catch e.format;
        return self.response.message orelse "request failed";
    }
};

/// The outcome of a request, before typed decoding.
pub const RawResult = union(enum) {
    /// `success: true`.
    ok: OwnedResponse,
    /// `success: false`.
    failed: OwnedResponse,
    timeout,
    /// The connection closed first.
    closed,

    pub fn deinit(self: RawResult) void {
        switch (self) {
            .ok, .failed => |r| r.deinit(),
            else => {},
        }
    }
};

pub const RawRespCb = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, r: RawResult) void,
};

/// A decoded body and the response that owns it.
pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        resp: OwnedResponse,

        pub fn deinit(self: @This()) void {
            self.resp.deinit();
        }
    };
}

/// The outcome of request `cmd`. Call `deinit` on every result.
pub fn Result(comptime cmd: protocol.Command) type {
    return union(enum) {
        ok: Owned(protocol.RequestInfo(cmd).ResponseBody),
        failed: OwnedResponse,
        /// `success: true` with a body that does not match the protocol.
        invalid: OwnedResponse,
        timeout,
        closed,

        pub fn deinit(self: @This()) void {
            switch (self) {
                .ok => |o| o.deinit(),
                .failed, .invalid => |r| r.deinit(),
                else => {},
            }
        }
    };
}

pub fn RespCb(comptime cmd: protocol.Command) type {
    return struct {
        ctx: ?*anyopaque,
        func: *const fn (ctx: ?*anyopaque, r: Result(cmd)) void,
    };
}

/// Receives every event, in wire order, on the dispatcher. `body` is valid
/// only during the call.
pub const EventListener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, c: *DapConnection, event: []const u8, body: ?RawJson, seq: u32) void,
};

/// A request from the adapter (`runInTerminal`, `startDebugging`).
pub const ReverseRequest = struct {
    seq: u32,
    command: []const u8,
    arguments: ?RawJson,
};

/// Handles a reverse request on the dispatcher. It must eventually call
/// `respond` (possibly later, from another thread); `req` and `arena` are
/// valid only during the call.
pub const ReverseHandler = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, c: *DapConnection, req: ReverseRequest, arena: Allocator) void,
};

/// Called once when the connection closes.
pub const CloseListener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, c: *DapConnection) void,
};

const Pending = struct {
    seq: u32,
    command: []const u8,
    cb: RawRespCb,
};

const Deadline = struct { at: i96, seq: u32 };

fn deadlineOrder(_: void, a: Deadline, b: Deadline) std.math.Order {
    return std.math.order(a.at, b.at);
}

/// A frame read but not yet dispatched.
const Inbound = struct {
    arena: *std.heap.ArenaAllocator,
    bytes: []const u8,
};

rt: *zg_core.Runtime,
gpa: Allocator,
io: Io,
opts: Options,
frames: framing.ContentLengthReader,
writer: *Io.Writer,
out: Io.Queue([]u8),
out_buf: [][]u8,
in: Io.Queue(Inbound),
in_buf: []Inbound,
writer_loop: Subsystem,
loops: Subsystem,
dispatch_loop: Subsystem,
/// Guards `pending`, `deadlines`.
mutex: Io.Mutex = .init,
/// Serializes seq numbering with queueing.
send_mutex: Io.Mutex = .init,
pending: std.AutoHashMapUnmanaged(u32, Pending) = .empty,
deadlines: std.PriorityQueue(Deadline, void, deadlineOrder) = .empty,
timer_event: Io.Event = .unset,
next_seq: u32 = 1,
listeners: std.ArrayList(EventListener) = .empty,
reverse_handlers: std.StringHashMapUnmanaged(ReverseHandler) = .empty,
close_listener: ?CloseListener = null,
supports_cancel: std.atomic.Value(bool) = .init(false),
started: bool = false,
closing: std.atomic.Value(bool) = .init(false),
finished: std.atomic.Value(bool) = .init(false),

/// Creates a connection over `t` (owned by the caller; it must outlive
/// the connection).
pub fn init(rt: *zg_core.Runtime, t: *Transport, opts: Options) !*DapConnection {
    const gpa = rt.gpa;
    const c = try gpa.create(DapConnection);
    errdefer gpa.destroy(c);
    const out_buf = try gpa.alloc([]u8, opts.write_queue);
    errdefer gpa.free(out_buf);
    const in_buf = try gpa.alloc(Inbound, opts.read_queue);
    c.* = .{
        .rt = rt,
        .gpa = gpa,
        .io = rt.io,
        .opts = opts,
        .frames = .init(t.reader, opts.framing),
        .writer = t.writer,
        .out = .init(out_buf),
        .out_buf = out_buf,
        .in = .init(in_buf),
        .in_buf = in_buf,
        .writer_loop = .init(rt.io),
        .loops = .init(rt.io),
        .dispatch_loop = .init(rt.io),
    };
    return c;
}

/// Adds an event listener. Call before `start`.
pub fn onEvent(c: *DapConnection, l: EventListener) !void {
    std.debug.assert(!c.started);
    try c.listeners.append(c.gpa, l);
}

/// Registers the handler of reverse request `command`. Call before
/// `start`. Unhandled reverse requests are answered `not supported`.
pub fn onReverseRequest(c: *DapConnection, command: []const u8, h: ReverseHandler) !void {
    std.debug.assert(!c.started);
    try c.reverse_handlers.put(c.gpa, command, h);
}

/// Sets the close listener. Call before `start`.
pub fn onClose(c: *DapConnection, l: CloseListener) void {
    std.debug.assert(!c.started);
    c.close_listener = l;
}

/// Whether the adapter supports `cancel` (`supportsCancelRequest`).
pub fn setSupportsCancel(c: *DapConnection, yes: bool) void {
    c.supports_cancel.store(yes, .release);
}

/// Starts the reader, dispatcher, writer and timer loops.
pub fn start(c: *DapConnection) !void {
    c.started = true;
    try c.writer_loop.spawnLoop(writerLoop, .{c});
    errdefer c.writer_loop.shutdown();
    try c.dispatch_loop.spawnLoop(dispatcherLoop, .{c});
    errdefer c.dispatch_loop.shutdown();
    try c.loops.spawnLoop(readerLoop, .{c});
    try c.loops.spawnLoop(timerLoop, .{c});
}

/// Sends request `cmd`; `cb` gets the typed result. Returns the seq.
pub fn request(c: *DapConnection, comptime cmd: protocol.Command, args: protocol.RequestInfo(cmd).Arguments, cb: RespCb(cmd)) !u32 {
    const Args = protocol.RequestInfo(cmd).Arguments;
    var args_buf: Io.Writer.Allocating = .init(c.gpa);
    defer args_buf.deinit();
    const args_json: ?[]const u8 = if (Args == void) null else blk: {
        std.json.Stringify.value(args, .{}, &args_buf.writer) catch return error.OutOfMemory;
        break :blk args_buf.written();
    };
    const box = try c.gpa.create(Thunk(cmd));
    box.* = .{ .cb = cb, .gpa = c.gpa };
    errdefer c.gpa.destroy(box);
    return c.requestRaw(@tagName(cmd), args_json, .{ .ctx = box, .func = Thunk(cmd).done });
}

fn Thunk(comptime cmd: protocol.Command) type {
    return struct {
        cb: RespCb(cmd),
        gpa: Allocator,

        const Body = protocol.RequestInfo(cmd).ResponseBody;

        fn done(ctx: ?*anyopaque, r: RawResult) void {
            const box: *@This() = @ptrCast(@alignCast(ctx.?));
            const cb = box.cb;
            box.gpa.destroy(box);
            cb.func(cb.ctx, decode(r));
        }

        fn decode(r: RawResult) Result(cmd) {
            return switch (r) {
                .failed => |o| .{ .failed = o },
                .timeout => .timeout,
                .closed => .closed,
                .ok => |o| blk: {
                    const value: Body = if (Body == void) {} else body: {
                        const b = o.response.body orelse break :blk .{ .invalid = o };
                        break :body b.parseLeaky(Body, o.arena.allocator(), .{ .allocate = .alloc_always }) catch break :blk .{ .invalid = o };
                    };
                    break :blk .{ .ok = .{ .value = value, .resp = o } };
                },
            };
        }
    };
}

/// Sends an adapter-specific request. `args_json` is JSON text or null.
/// Returns the seq.
pub fn requestRaw(c: *DapConnection, command: []const u8, args_json: ?[]const u8, cb: RawRespCb) !u32 {
    const timeout = c.opts.timeouts.forCommand(command);
    c.send_mutex.lockUncancelable(c.io);
    defer c.send_mutex.unlock(c.io);
    if (c.finished.load(.acquire) or c.closing.load(.acquire)) return error.ConnectionClosed;
    const seq = c.next_seq;
    var aw: Io.Writer.Allocating = .init(c.gpa);
    errdefer aw.deinit();
    message.writeRequest(&aw.writer, seq, command, args_json) catch return error.OutOfMemory;
    const frame = try aw.toOwnedSlice();
    {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        c.pending.put(c.gpa, seq, .{ .seq = seq, .command = command, .cb = cb }) catch |err| {
            c.gpa.free(frame);
            return err;
        };
        const at = Io.Clock.Timestamp.now(c.io, .awake).raw.nanoseconds + timeout.nanoseconds;
        c.deadlines.push(c.gpa, .{ .at = at, .seq = seq }) catch {};
    }
    c.timer_event.set(c.io);
    c.record(.send, .request, command, seq, frame);
    c.enqueue(frame) catch |err| {
        c.mutex.lockUncancelable(c.io);
        _ = c.pending.remove(seq);
        c.mutex.unlock(c.io);
        return err;
    };
    c.next_seq += 1;
    return seq;
}

/// Asks the adapter to cancel `request_seq` (only when it supports
/// `cancel`). Best effort: the request still gets its response, possibly
/// failed with `cancelled`.
pub fn cancel(c: *DapConnection, request_seq: u32) void {
    if (!c.supports_cancel.load(.acquire)) return;
    var buf: [48]u8 = undefined;
    const args = std.fmt.bufPrint(&buf, "{{\"requestId\":{d}}}", .{request_seq}) catch unreachable;
    _ = c.requestRaw("cancel", args, .{ .ctx = null, .func = ignoreResult }) catch {};
}

fn ignoreResult(_: ?*anyopaque, r: RawResult) void {
    r.deinit();
}

/// Answers reverse request `request_seq`. `body_json` is JSON text or null.
pub fn respond(c: *DapConnection, request_seq: u32, command: []const u8, success: bool, body_json: ?[]const u8, msg: ?[]const u8) !void {
    c.send_mutex.lockUncancelable(c.io);
    defer c.send_mutex.unlock(c.io);
    if (c.finished.load(.acquire) or c.closing.load(.acquire)) return error.ConnectionClosed;
    var aw: Io.Writer.Allocating = .init(c.gpa);
    errdefer aw.deinit();
    message.writeResponse(&aw.writer, c.next_seq, request_seq, command, success, body_json, msg) catch return error.OutOfMemory;
    const frame = try aw.toOwnedSlice();
    c.record(.send, .response, command, c.next_seq, frame);
    try c.enqueue(frame);
    c.next_seq += 1;
}

/// Writes the frames already queued, stops the loops and fails pending
/// requests with `.closed`. Idempotent. Not from a callback.
pub fn close(c: *DapConnection) void {
    if (c.closing.swap(true, .acq_rel)) return;
    c.out.close(c.io);
    if (c.started) {
        c.writer_loop.join() catch {};
        c.loops.shutdown();
        c.in.close(c.io);
        c.dispatch_loop.shutdown();
    }
    c.finish();
}

/// Closes and frees the connection.
pub fn deinit(c: *DapConnection) void {
    c.close();
    const gpa = c.gpa;
    var left: [16][]u8 = undefined;
    while (true) {
        const n = c.out.getUncancelable(c.io, &left, 0) catch break;
        if (n == 0) break;
        for (left[0..n]) |f| gpa.free(f);
    }
    var inl: [16]Inbound = undefined;
    while (true) {
        const n = c.in.getUncancelable(c.io, &inl, 0) catch break;
        if (n == 0) break;
        for (inl[0..n]) |f| freeInbound(gpa, f);
    }
    c.pending.deinit(gpa);
    c.deadlines.deinit(gpa);
    c.listeners.deinit(gpa);
    c.reverse_handlers.deinit(gpa);
    c.frames.deinit(gpa);
    gpa.free(c.out_buf);
    gpa.free(c.in_buf);
    gpa.destroy(c);
}

fn record(c: *DapConnection, dir: zg_lsp.client.trace.Direction, kind: zg_lsp.client.trace.Kind, name: []const u8, seq: u32, body: []const u8) void {
    const t = c.opts.trace orelse return;
    t.record(.{
        .dir = dir,
        .kind = kind,
        .method = name,
        .id = seq,
        .size = body.len,
        .at_ns = Io.Clock.Timestamp.now(c.io, .awake).raw.nanoseconds,
        .body = body,
    });
}

fn enqueue(c: *DapConnection, frame: []u8) !void {
    c.out.putOneUncancelable(c.io, frame) catch {
        c.gpa.free(frame);
        return error.ConnectionClosed;
    };
}

fn freeInbound(gpa: Allocator, f: Inbound) void {
    f.arena.deinit();
    gpa.destroy(f.arena);
}

fn writerLoop(c: *DapConnection) Io.Cancelable!void {
    var batch: [32][]u8 = undefined;
    var failed = false;
    while (true) {
        const n = c.out.get(c.io, &batch, 1) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
        for (batch[0..n]) |frame| {
            if (!failed) framing.writeFrameUnflushed(.content_length, c.writer, frame) catch {
                failed = true;
            };
            c.gpa.free(frame);
        }
        if (!failed) c.writer.flush() catch {
            failed = true;
        };
    }
}

fn readerLoop(c: *DapConnection) Io.Cancelable!void {
    // End of input: let the dispatcher drain what was read, then finish.
    defer c.in.close(c.io);
    while (true) {
        const body = c.frames.next(c.gpa) catch |err| {
            if (framing.isFatal(err)) return;
            log.warn("dropping frame: {t}", .{err});
            continue;
        };
        const arena = c.gpa.create(std.heap.ArenaAllocator) catch continue;
        arena.* = .init(c.gpa);
        const bytes = arena.allocator().dupe(u8, body) catch {
            freeInbound(c.gpa, .{ .arena = arena, .bytes = "" });
            continue;
        };
        c.in.putOne(c.io, .{ .arena = arena, .bytes = bytes }) catch |err| {
            freeInbound(c.gpa, .{ .arena = arena, .bytes = bytes });
            switch (err) {
                error.Closed => return,
                error.Canceled => return error.Canceled,
            }
        };
    }
}

fn dispatcherLoop(c: *DapConnection) Io.Cancelable!void {
    defer c.finish();
    while (true) {
        const f = c.in.getOne(c.io) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
        c.dispatch(f);
    }
}

/// Handles one frame; frees it unless a response callback took it.
fn dispatch(c: *DapConnection, f: Inbound) void {
    const a = f.arena.allocator();
    const env = message.decode(a, f.bytes) catch |err| {
        log.warn("dropping message: {t}", .{err});
        return freeInbound(c.gpa, f);
    };
    switch (env.kind) {
        .response => {
            c.record(.recv, if (env.success) .response else .error_response, env.name, env.request_seq, f.bytes);
            const p = c.unregister(env.request_seq) orelse {
                log.debug("dropping late or unknown response to {d} ({s})", .{ env.request_seq, env.name });
                return freeInbound(c.gpa, f);
            };
            const resp: OwnedResponse = .{
                .response = .{
                    .request_seq = env.request_seq,
                    .success = env.success,
                    .command = env.name,
                    .message = env.message,
                    .body = env.body,
                    .error_body = if (env.success) null else message.errorBody(a, env.body),
                },
                .arena = f.arena,
            };
            p.cb.func(p.cb.ctx, if (env.success) .{ .ok = resp } else .{ .failed = resp });
        },
        .event => {
            defer freeInbound(c.gpa, f);
            c.record(.recv, .notification, env.name, env.seq, f.bytes);
            for (c.listeners.items) |l| l.func(l.ctx, c, env.name, env.body, env.seq);
        },
        .request => {
            defer freeInbound(c.gpa, f);
            c.record(.recv, .request, env.name, env.seq, f.bytes);
            if (c.reverse_handlers.get(env.name)) |h| {
                h.func(h.ctx, c, .{ .seq = env.seq, .command = env.name, .arguments = env.body }, a);
            } else {
                c.respond(env.seq, env.name, false, null, "not supported") catch {};
            }
        },
    }
}

fn unregister(c: *DapConnection, seq: u32) ?Pending {
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    const kv = c.pending.fetchRemove(seq) orelse return null;
    return kv.value;
}

fn timerLoop(c: *DapConnection) Io.Cancelable!void {
    while (true) {
        var expired: [64]Pending = undefined;
        var n: usize = 0;
        var next: ?i96 = null;
        const now = Io.Clock.Timestamp.now(c.io, .awake).raw.nanoseconds;
        {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            while (c.deadlines.peek()) |d| {
                if (d.at > now) {
                    next = d.at;
                    break;
                }
                if (n == expired.len) {
                    next = now;
                    break;
                }
                _ = c.deadlines.pop();
                const kv = c.pending.fetchRemove(d.seq) orelse continue;
                expired[n] = kv.value;
                n += 1;
            }
        }
        for (expired[0..n]) |p| {
            log.debug("{s} ({d}) timed out", .{ p.command, p.seq });
            p.cb.func(p.cb.ctx, .timeout);
        }
        const t: Io.Timeout = if (next) |at|
            .{ .deadline = .{ .raw = .{ .nanoseconds = at }, .clock = .awake } }
        else
            .none;
        c.timer_event.waitTimeout(c.io, t) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
        c.timer_event.reset();
    }
}

/// Fails every pending request with `.closed` and tells the close
/// listener. Idempotent.
fn finish(c: *DapConnection) void {
    if (c.finished.swap(true, .acq_rel)) return;
    c.send_mutex.lockUncancelable(c.io);
    c.send_mutex.unlock(c.io);
    c.mutex.lockUncancelable(c.io);
    var old = c.pending;
    c.pending = .empty;
    c.deadlines.deinit(c.gpa);
    c.deadlines = .empty;
    c.mutex.unlock(c.io);
    var it = old.valueIterator();
    while (it.next()) |p| p.cb.func(p.cb.ctx, .closed);
    old.deinit(c.gpa);
    if (c.close_listener) |l| l.func(l.ctx, c);
}
