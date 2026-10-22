//! `guarded()`: a `Provider` decorator adding rate limiting and retries
//! around `stream`, `count_tokens` and `list_models`.
//!
//! The outer sink sees exactly one attempt: events before the first
//! content event are held back (and dropped if that attempt is retried),
//! and the final `provider_error` is only forwarded when the call gives up.
//! Once content has reached the sink a failure is never retried here; the
//! agent loop's recovery decides with the partial message.

const std = @import("std");
const proto = @import("zg_ai_proto");
const Provider = @import("Provider.zig");
const events = @import("events.zig");
const request = @import("request.zig");
const retry = @import("retry.zig");
const ratelimit = @import("ratelimit.zig");

const Allocator = std.mem.Allocator;
const StreamError = Provider.StreamError;

/// One scheduled retry, for the agent event bus.
pub const Retrying = struct {
    attempt: u8,
    delay_ms: u64,
    status: ?u16,
    err: StreamError,
};

pub const RetryListener = struct {
    ctx: *anyopaque,
    on_retry: *const fn (ctx: *anyopaque, r: Retrying) void,
};

pub const Options = struct {
    /// Provider instance name used for lanes and the concurrency cap.
    instance: []const u8,
    policy: retry.RetryPolicy = .{},
    clock: ratelimit.Clock = .real,
    /// Jitter seed; 0 seeds from the `Io` random source.
    seed: u64 = 0,
    listener: ?RetryListener = null,
};

pub const Guarded = struct {
    gpa: Allocator,
    inner: Provider,
    limiter: *ratelimit.RateLimiter,
    opts: Options,
    instance: []u8,
    rng: std.Random.DefaultPrng,
    rng_lock: std.atomic.Mutex = .unlocked,
    seeded: bool,

    /// Wraps `inner`, taking ownership of it.
    pub fn create(gpa: Allocator, inner: Provider, limiter: *ratelimit.RateLimiter, opts: Options) Allocator.Error!*Guarded {
        const g = try gpa.create(Guarded);
        errdefer gpa.destroy(g);
        const name = try gpa.dupe(u8, opts.instance);
        g.* = .{ .gpa = gpa, .inner = inner, .limiter = limiter, .opts = opts, .instance = name, .rng = .init(opts.seed), .seeded = opts.seed != 0 };
        g.opts.instance = name;
        return g;
    }

    pub fn provider(g: *Guarded) Provider {
        return .{ .ptr = g, .vtable = &vtable, .id = g.inner.id, .caps = g.inner.caps };
    }

    const vtable: Provider.VTable = .{ .stream = stream, .count_tokens = countTokens, .list_models = listModels, .deinit = deinit };

    fn deinit(ptr: *anyopaque) void {
        const g: *Guarded = @ptrCast(@alignCast(ptr));
        g.inner.deinit();
        g.gpa.free(g.instance);
        g.gpa.destroy(g);
    }

    fn delay(g: *Guarded, io: std.Io, d: retry.Decision, attempt: u8, retry_after_ms: ?u64) ?u64 {
        while (!g.rng_lock.tryLock()) std.atomic.spinLoopHint();
        defer g.rng_lock.unlock();
        if (!g.seeded) {
            var seed: [8]u8 = undefined;
            io.random(&seed);
            g.rng = .init(std.mem.readInt(u64, &seed, .little));
            g.seeded = true;
        }
        return g.opts.policy.delayMs(d, attempt, retry_after_ms, g.rng.random());
    }

    /// Sleeps before the next attempt, or returns false to give up. The
    /// retry is announced to the listener and to `sink` (the caller's
    /// stream, so the agent can show it and a cancel can interrupt it).
    fn backoff(g: *Guarded, io: std.Io, err: StreamError, status: ?u16, retry_after_ms: ?u64, attempt: u8, sink: ?events.EventSink) error{Canceled}!bool {
        const d = g.opts.policy.classify(err, status, retry_after_ms != null);
        const ms = g.delay(io, d, attempt, retry_after_ms) orelse return false;
        if (g.opts.listener) |li| li.on_retry(li.ctx, .{ .attempt = attempt + 1, .delay_ms = ms, .status = status, .err = err });
        if (sink) |s| s.send(.{ .retrying = .{ .attempt = attempt + 2, .delay_ms = ms, .status = status, .err = @errorName(err) } });
        try g.opts.clock.sleep(io, ms);
        return true;
    }

    fn permit(g: *Guarded, io: std.Io, lane: ratelimit.Lane, est: u64) StreamError!ratelimit.Permit {
        return g.limiter.acquire(io, lane, est) catch |e| switch (e) {
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn stream(ptr: *anyopaque, io: std.Io, arena: Allocator, req: *const request.Request, sink: events.EventSink) StreamError!request.Response {
        const g: *Guarded = @ptrCast(@alignCast(ptr));
        const lane: ratelimit.Lane = .{ .provider = g.instance, .model_class = req.model, .kind = .messages };
        const est = estimateInputTokens(req);
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            var tap: Tap = .{ .g = g, .io = io, .arena = arena, .lane = lane, .outer = sink };
            const p = try g.permit(io, lane, est);
            const result = g.inner.stream(io, arena, req, tap.sink());
            p.release(io);
            if (result) |resp| {
                tap.flush();
                return resp;
            } else |err| {
                if (tap.content or tap.oom) return tap.giveUp(err);
                const status: ?u16 = if (tap.last_error) |e| (if (e.status != 0) e.status else null) else null;
                const ra = if (tap.last_error) |e| e.retry_after_ms else null;
                if (!(try g.backoff(io, err, status, ra, attempt, sink))) return tap.giveUp(err);
            }
        }
    }

    fn countTokens(ptr: *anyopaque, io: std.Io, arena: Allocator, req: *const request.Request) Provider.CountError!u64 {
        const g: *Guarded = @ptrCast(@alignCast(ptr));
        const lane: ratelimit.Lane = .{ .provider = g.instance, .model_class = req.model, .kind = .count_tokens };
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            const p = try g.permit(io, lane, 0);
            const r = g.inner.countTokens(io, arena, req);
            p.release(io);
            if (r) |n| return n else |err| {
                if (err == error.Unsupported or !(try g.backoff(io, err, null, null, attempt, null))) return err;
            }
        }
    }

    fn listModels(ptr: *anyopaque, io: std.Io, arena: Allocator) StreamError![]Provider.ModelInfo {
        const g: *Guarded = @ptrCast(@alignCast(ptr));
        const lane: ratelimit.Lane = .{ .provider = g.instance, .kind = .models };
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            const p = try g.permit(io, lane, 0);
            const r = g.inner.listModels(io, arena);
            p.release(io);
            if (r) |ms| return ms else |err| {
                if (err == error.Unsupported or !(try g.backoff(io, err, null, null, attempt, null))) return err;
            }
        }
    }
};

/// Wraps `inner` (taking ownership); `deinit` on the result frees both.
pub fn guarded(gpa: Allocator, inner: Provider, limiter: *ratelimit.RateLimiter, opts: Options) Allocator.Error!Provider {
    return (try Guarded.create(gpa, inner, limiter, opts)).provider();
}

/// Rough input size for rate limiting: request bytes at 4 bytes per token.
pub fn estimateInputTokens(req: *const request.Request) u64 {
    var bytes: u64 = 0;
    for (req.system) |s| bytes += s.text.len;
    for (req.tools) |t| bytes += t.name.len + t.description.len + t.input_schema_json.len;
    for (req.messages) |m| for (m.content) |b| {
        bytes += switch (b) {
            .text => |t| t.text.len,
            .tool_use => |t| t.input_json.len,
            .tool_result => |t| blk: {
                var n: u64 = 0;
                for (t.parts) |p| n += if (p == .text) p.text.len else 1000;
                break :blk n;
            },
            .thinking => |t| t.text.len,
            .provider_opaque => |o| o.raw_json.len,
            else => 1000,
        };
    };
    return bytes / 4;
}

/// Sits between the provider and the caller's sink for one attempt.
const Tap = struct {
    g: *Guarded,
    io: std.Io,
    arena: Allocator,
    lane: ratelimit.Lane,
    outer: events.EventSink,
    held: std.ArrayList(events.StreamEvent) = .empty,
    last_error: ?events.ErrorInfo = null,
    content: bool = false,
    oom: bool = false,

    fn sink(t: *Tap) events.EventSink {
        return .{ .ctx = t, .emit = emit };
    }

    fn emit(ctx: *anyopaque, ev: events.StreamEvent) void {
        const t: *Tap = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .rate_limit => |s| {
                t.g.limiter.update(t.io, t.lane, s);
                t.forward(ev);
            },
            .provider_error => |e| t.last_error = t.copyError(e) catch blk: {
                t.oom = true;
                break :blk e;
            },
            .message_start, .usage, .ping, .warning => if (t.content) t.outer.send(ev) else t.hold(ev),
            // A nested guard's notice: pass it on now.
            .retrying => t.outer.send(ev),
            else => {
                t.flush();
                t.content = true;
                t.outer.send(ev);
            },
        }
    }

    fn forward(t: *Tap, ev: events.StreamEvent) void {
        if (t.content) t.outer.send(ev) else t.hold(ev);
    }

    fn hold(t: *Tap, ev: events.StreamEvent) void {
        const copy: events.StreamEvent = switch (ev) {
            .message_start => |m| .{ .message_start = .{ .id = t.dupe(m.id), .model = t.dupe(m.model) } },
            .warning => |w| .{ .warning = t.dupe(w) },
            else => ev,
        };
        t.held.append(t.arena, copy) catch {
            // Can't hold it: deliver now and stop retrying this call.
            t.oom = true;
            t.outer.send(ev);
        };
    }

    fn dupe(t: *Tap, s: []const u8) []const u8 {
        return t.arena.dupe(u8, s) catch {
            t.oom = true;
            return "";
        };
    }

    fn copyError(t: *Tap, e: events.ErrorInfo) Allocator.Error!events.ErrorInfo {
        return .{
            .status = e.status,
            .kind = try t.arena.dupe(u8, e.kind),
            .message = try t.arena.dupe(u8, e.message),
            .retry_after_ms = e.retry_after_ms,
            .request_id = if (e.request_id) |r| try t.arena.dupe(u8, r) else null,
        };
    }

    fn flush(t: *Tap) void {
        for (t.held.items) |ev| t.outer.send(ev);
        t.held.clearRetainingCapacity();
    }

    fn giveUp(t: *Tap, err: StreamError) StreamError {
        t.flush();
        if (t.last_error) |e| t.outer.send(.{ .provider_error = e });
        return err;
    }
};
