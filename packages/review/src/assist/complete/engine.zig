//! The completion engine (E12.F07.S01.T01): the scheduler, the cache and a
//! `FimProvider` put together. Everything here runs on the UI thread except
//! the provider call, which runs on its own task (`io.concurrent`); its text
//! comes back through `Host.post`.
//!
//! The host reports edits, cursor moves, invokes and accepts, arms one
//! timer from `nextDeadline` and calls `tick` when it fires. When a trigger
//! is due the engine takes a snapshot of the document from the host,
//! answers from the cache when it can, and otherwise builds the request and
//! starts the provider. The host's `deliver` gets the completion as it
//! streams: the text so far, how many leading bytes the user already typed
//! (hide them), and whether it is final. Results for a request that a newer
//! one replaced, or that an edit cancelled, are never delivered.

const std = @import("std");
const context = @import("context.zig");
const scheduler = @import("scheduler.zig");
const cache_mod = @import("cache.zig");
const providers = @import("providers.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Snapshot = struct {
    /// The document's text, valid as long as the arena it was made in.
    text: []const u8,
    cursor: usize,
    version: u64,
    /// Path, language, scopes and neighbours for `buildRequest`.
    options: context.Options,
};

/// A completion for the controller (T04).
pub const Delivery = struct {
    doc: u64,
    version: u64,
    /// The completion so far, valid during the call.
    text: []const u8,
    /// Leading bytes of `text` the user has already typed.
    hide: u32,
    final: bool,
    from_cache: bool = false,
};

/// The UI side, bound by the app.
pub const Host = struct {
    ctx: *anyopaque,
    /// The document as it is now, copied into `arena` (or `null` when it is
    /// gone).
    snapshot: *const fn (ctx: *anyopaque, doc: u64, arena: Allocator) anyerror!?Snapshot,
    /// Runs `f(arg)` on the UI thread soon; callable from any thread.
    post: *const fn (ctx: *anyopaque, f: *const fn (*anyopaque) void, arg: *anyopaque) void,
    deliver: *const fn (ctx: *anyopaque, d: Delivery) void,
    /// The provider failed (status bar); `null` when it recovered.
    failed: ?*const fn (ctx: *anyopaque, err: anyerror) void = null,
};

pub const CompletionEngine = struct {
    gpa: Allocator,
    io: Io,
    provider: providers.FimProvider,
    host: Host,
    sched: scheduler.Scheduler,
    cache: cache_mod.Cache,
    /// Keys the cache by model.
    model_id: u32,
    next_id: u64 = 1,
    requests: std.AutoHashMapUnmanaged(u64, *Request) = .empty,

    pub fn init(gpa: Allocator, io: Io, provider: providers.FimProvider, host: Host, opts: scheduler.EngineOptions, model_id: u32) CompletionEngine {
        return .{
            .gpa = gpa,
            .io = io,
            .provider = provider,
            .host = host,
            .sched = .init(gpa, opts),
            .cache = .init(gpa, opts.cache_entries, opts.cache_bytes),
            .model_id = model_id,
        };
    }

    /// Cancels every request.
    pub fn deinit(e: *CompletionEngine) void {
        var it = e.requests.valueIterator();
        while (it.next()) |r| r.*.abandon();
        e.requests.deinit(e.gpa);
        e.sched.deinit();
        e.cache.deinit();
    }

    pub fn open(e: *CompletionEngine, doc: u64, version: u64) !void {
        try e.sched.open(doc, version);
    }

    pub fn close(e: *CompletionEngine, doc: u64) void {
        e.apply(e.sched.cancelInflight(doc));
        e.sched.close(doc);
        e.cache.invalidateDoc(@truncate(doc));
    }

    /// The first reason not to complete here (`.ok`: go ahead).
    pub fn gate(e: *const CompletionEngine, in: scheduler.GateInput) scheduler.Gate {
        _ = e;
        return scheduler.gate(in);
    }

    /// An edit to `doc`. A non-typing edit also drops the document's cached
    /// completions.
    pub fn onEdit(e: *CompletionEngine, doc: u64, edit: scheduler.Edit, now: u64) void {
        if (edit.origin != .user) e.cache.invalidateDoc(@truncate(doc));
        e.apply(e.sched.onEdit(doc, edit, now));
    }

    /// The user typed `text` while a request may be streaming: keeps it
    /// (the shown text hides what was typed) or cancels it.
    pub fn typed(e: *CompletionEngine, doc: u64, text: []const u8) void {
        const id = e.sched.inflight(doc) orelse return;
        const r = e.requests.get(id) orelse return;
        const act = e.sched.typed(doc, text, r.shown.items);
        switch (act) {
            .keep => |n| e.host.deliver(e.host.ctx, .{ .doc = doc, .version = r.version, .text = r.shown.items, .hide = n, .final = false }),
            else => e.apply(act),
        }
    }

    pub fn onCursorMove(e: *CompletionEngine, doc: u64, same_line: bool, now: u64) void {
        e.sched.onCursorMove(doc, same_line, now);
    }

    pub fn invoke(e: *CompletionEngine, doc: u64, now: u64) void {
        e.sched.invoke(doc, now);
    }

    pub fn accepted(e: *CompletionEngine, doc: u64, version: u64, now: u64) void {
        e.sched.accepted(doc, version, now);
    }

    /// Focus left the editor or the gate closed: nothing pending, nothing
    /// in flight.
    pub fn dismiss(e: *CompletionEngine, doc: u64) void {
        e.sched.disarm(doc);
        e.apply(e.sched.cancelInflight(doc));
    }

    pub fn nextDeadline(e: *const CompletionEngine) ?u64 {
        return e.sched.nextDeadline();
    }

    /// Starts the requests that are due at `now`.
    pub fn tick(e: *CompletionEngine, now: u64) !void {
        var due: [8]scheduler.Trigger = undefined;
        const n = e.sched.poll(now, &due);
        for (due[0..n]) |t| try e.start(t);
    }

    /// Requests in flight (tests, status).
    pub fn running(e: *const CompletionEngine) usize {
        return e.requests.count();
    }

    fn apply(e: *CompletionEngine, act: scheduler.InflightAction) void {
        switch (act) {
            .cancel => |id| if (e.requests.fetchRemove(id)) |kv| kv.value.abandon(),
            else => {},
        }
    }

    fn start(e: *CompletionEngine, t: scheduler.Trigger) !void {
        const r = try e.gpa.create(Request);
        r.* = .{ .engine = e, .arena = .init(e.gpa), .doc = t.doc, .version = t.version };
        var started = false;
        defer if (!started) r.destroy();
        const arena = r.arena.allocator();
        const snap = (try e.host.snapshot(e.host.ctx, t.doc, arena)) orelse return;
        if (snap.version != t.version) return;
        r.key = .of(@truncate(t.doc), snap.text[0..snap.cursor], snap.text[snap.cursor..], e.model_id);
        if (e.cache.get(r.key)) |hit| {
            e.host.deliver(e.host.ctx, .{ .doc = t.doc, .version = t.version, .text = hit, .hide = 0, .final = true, .from_cache = true });
            return;
        }
        var o = snap.options;
        o.doc = t.doc;
        o.explicit = t.explicit;
        r.req = try context.buildRequest(arena, snap.text, snap.cursor, o);

        const id = e.next_id;
        e.next_id += 1;
        r.id = id;
        try e.requests.ensureUnusedCapacity(e.gpa, 1);
        r.future = try e.io.concurrent(Request.run, .{r});
        started = true;
        e.requests.putAssumeCapacity(id, r);
        if (e.sched.started(t, id)) |old| e.apply(.{ .cancel = old });
    }

    /// A request's text reached the UI thread.
    fn drained(e: *CompletionEngine, r: *Request, final: bool, err: ?anyerror) void {
        if (e.sched.inflight(r.doc) != r.id) return;
        if (!final) {
            e.host.deliver(e.host.ctx, .{ .doc = r.doc, .version = r.version, .text = r.shown.items, .hide = e.sched.typedLen(r.doc), .final = false });
            return;
        }
        const hide = e.sched.finished(r.doc, r.id) orelse return;
        if (err) |x| {
            if (e.host.failed) |f| f(e.host.ctx, x);
            return;
        }
        e.cache.put(r.key, r.shown.items) catch {};
        e.host.deliver(e.host.ctx, .{ .doc = r.doc, .version = r.version, .text = r.shown.items, .hide = hide, .final = true });
    }
};

/// One provider call. The worker appends to `pending`; the UI thread moves
/// it to `shown` when the posted drain runs.
const Request = struct {
    engine: *CompletionEngine,
    arena: std.heap.ArenaAllocator,
    doc: u64,
    version: u64,
    id: u64 = 0,
    key: cache_mod.CacheKey = undefined,
    req: context.CompletionRequest = undefined,
    future: Io.Future(void) = undefined,
    mutex: Io.Mutex = .init,
    pending: std.ArrayList(u8) = .empty,
    done: bool = false,
    err: ?anyerror = null,
    /// A drain is posted and has not run yet.
    posted: std.atomic.Value(bool) = .init(false),
    /// Removed from the engine; the next drain frees it.
    abandoned: bool = false,
    shown: std.ArrayList(u8) = .empty,

    fn run(r: *Request) void {
        var call_arena: std.heap.ArenaAllocator = .init(r.engine.gpa);
        defer call_arena.deinit();
        const io = r.engine.io;
        const result = r.engine.provider.complete(io, call_arena.allocator(), &r.req, .{ .ctx = r, .text = onText });
        r.mutex.lockUncancelable(io);
        r.done = true;
        if (result) |_| {} else |err| r.err = err;
        r.mutex.unlock(io);
        if (result) |_| {} else |err| if (err == error.Canceled) return;
        r.schedule();
    }

    fn onText(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
        const r: *Request = @ptrCast(@alignCast(ctx.?));
        const io = r.engine.io;
        {
            r.mutex.lockUncancelable(io);
            defer r.mutex.unlock(io);
            try r.pending.appendSlice(r.engine.gpa, bytes);
        }
        r.schedule();
    }

    fn schedule(r: *Request) void {
        if (r.posted.swap(true, .acq_rel)) return;
        r.engine.host.post(r.engine.host.ctx, drainFn, r);
    }

    fn drainFn(ctx: *anyopaque) void {
        const r: *Request = @ptrCast(@alignCast(ctx));
        r.posted.store(false, .release);
        if (r.abandoned) return r.destroy();
        const e = r.engine;
        const io = e.io;
        r.mutex.lockUncancelable(io);
        const done = r.done;
        const err = r.err;
        const moved = r.shown.appendSlice(e.gpa, r.pending.items);
        r.pending.clearRetainingCapacity();
        r.mutex.unlock(io);
        moved catch {};
        if (done) {
            r.future.await(io);
            _ = e.requests.remove(r.id);
            e.drained(r, true, err);
            r.destroy();
        } else {
            e.drained(r, false, null);
        }
    }

    /// Stops the call; frees now unless a drain is still posted.
    fn abandon(r: *Request) void {
        r.abandoned = true;
        r.future.cancel(r.engine.io);
        if (!r.posted.load(.acquire)) r.destroy();
    }

    fn destroy(r: *Request) void {
        const gpa = r.engine.gpa;
        r.pending.deinit(gpa);
        r.shown.deinit(gpa);
        r.arena.deinit();
        gpa.destroy(r);
    }
};
