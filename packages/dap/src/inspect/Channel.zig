//! The inspection models' mailbox (E07.F06.S04.T01): requests go out
//! through a `Port` (normally a debug session) and their results, with the
//! session changes the app forwards, queue here until the UI thread takes
//! them (`take`). The models themselves are UI-thread only.
//!
//! Every request carries the generation it was sent in; the models drop
//! results whose generation is no longer theirs.

const Channel = @This();
const std = @import("std");
const zg_perf = @import("zg_perf");
const protocol = @import("../gen/protocol.zig");
const DapConnection = @import("../conn/DapConnection.zig");
const DebugSession = @import("../session/DebugSession.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// What a result is for.
pub const Tag = struct {
    kind: Kind,
    /// Kind-specific: a thread, frame, node id or source reference.
    a: u64 = 0,
    b: u64 = 0,
    c: u64 = 0,

    pub const Kind = enum { stack_page, scopes, variables, lazy, set_value, source, evaluate, completions, exception_info };
};

/// One queued item: a request's result or a session change.
pub const Item = struct {
    what: union(enum) {
        result: Result,
        change: Change,
    },

    pub const Result = struct {
        tag: Tag,
        gen: u64,
        ok: bool,
        /// The response body (`{}` when it had none) or, on failure, the
        /// error text.
        bytes: []u8,
    };

    pub const Change = struct {
        change: DebugSession.Change,
        /// The `invalidated` body.
        bytes: []u8 = &.{},
    };

    pub fn deinit(it: Item, gpa: Allocator) void {
        switch (it.what) {
            .result => |r| gpa.free(r.bytes),
            .change => |c| gpa.free(c.bytes),
        }
    }
};

/// Where requests go. `send` calls `cb` later (on any thread) unless it
/// returns false.
pub const Port = struct {
    ctx: ?*anyopaque,
    send: *const fn (ctx: ?*anyopaque, command: []const u8, args: []const u8, cb: DapConnection.RawRespCb) bool,
    caps: *const fn (ctx: ?*anyopaque) protocol.Capabilities,
    /// The session's id (for `dap-source:` documents).
    id: u32 = 0,

    pub fn ofSession(s: *DebugSession) Port {
        return .{ .ctx = s, .send = sessionSend, .caps = sessionCaps, .id = s.id };
    }

    fn sessionSend(ctx: ?*anyopaque, command: []const u8, args: []const u8, cb: DapConnection.RawRespCb) bool {
        const s: *DebugSession = @ptrCast(@alignCast(ctx.?));
        return s.sendRequest(command, args, cb);
    }

    fn sessionCaps(ctx: ?*anyopaque) protocol.Capabilities {
        const s: *DebugSession = @ptrCast(@alignCast(ctx.?));
        return s.caps();
    }

    /// Sends nothing (benchmarks and model tests feed results by hand).
    pub const none: Port = .{ .ctx = null, .send = noSend, .caps = noCaps };

    fn noSend(_: ?*anyopaque, _: []const u8, _: []const u8, _: DapConnection.RawRespCb) bool {
        return false;
    }

    fn noCaps(_: ?*anyopaque) protocol.Capabilities {
        return .{};
    }
};

/// Called when an item is queued (any thread, with the mailbox's lock
/// held: keep it short, e.g. post a coalesced wake to the UI thread).
pub const Waker = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque) void,
};

/// Shared with the request callbacks; freed by the last reference.
const Shared = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    items: std.ArrayList(Item) = .empty,
    refs: std.atomic.Value(u32) = .init(1),
    inflight: std.atomic.Value(u32) = .init(0),
    /// Set when an item is queued.
    event: Io.Event = .unset,
    closed: bool = false,
    waker: ?Waker = null,

    fn release(sh: *Shared) void {
        if (sh.refs.fetchSub(1, .acq_rel) != 1) return;
        for (sh.items.items) |it| it.deinit(sh.gpa);
        sh.items.deinit(sh.gpa);
        sh.gpa.destroy(sh);
    }

    fn push(sh: *Shared, it: Item) void {
        sh.mutex.lockUncancelable(sh.io);
        if (sh.closed) {
            sh.mutex.unlock(sh.io);
            return it.deinit(sh.gpa);
        }
        sh.items.append(sh.gpa, it) catch {
            sh.mutex.unlock(sh.io);
            return it.deinit(sh.gpa);
        };
        // Under the lock: after `deinit` no waker runs.
        if (sh.waker) |w| w.func(w.ctx);
        sh.mutex.unlock(sh.io);
        sh.event.set(sh.io);
    }
};

const Pending = struct {
    sh: *Shared,
    tag: Tag,
    gen: u64,
};

shared: *Shared,
port: Port,

pub fn init(gpa: Allocator, io: Io, port: Port) Allocator.Error!Channel {
    const sh = try gpa.create(Shared);
    sh.* = .{ .gpa = gpa, .io = io };
    return .{ .shared = sh, .port = port };
}

/// Wakes the UI thread when items arrive (null: nothing to call).
pub fn setWaker(ch: *Channel, w: ?Waker) void {
    const sh = ch.shared;
    sh.mutex.lockUncancelable(sh.io);
    defer sh.mutex.unlock(sh.io);
    sh.waker = w;
}

/// Results still in flight are dropped when they arrive.
pub fn deinit(ch: *Channel) void {
    const sh = ch.shared;
    sh.mutex.lockUncancelable(sh.io);
    sh.closed = true;
    sh.mutex.unlock(sh.io);
    sh.release();
    ch.* = undefined;
}

/// Sends `command` with `args` (JSON text); the result is queued with
/// `tag` and `gen`. False when it could not be sent.
pub fn send(ch: *Channel, command: []const u8, args: []const u8, tag: Tag, gen: u64) bool {
    const sh = ch.shared;
    const p = sh.gpa.create(Pending) catch return false;
    p.* = .{ .sh = sh, .tag = tag, .gen = gen };
    _ = sh.refs.fetchAdd(1, .acq_rel);
    _ = sh.inflight.fetchAdd(1, .acq_rel);
    if (!ch.port.send(ch.port.ctx, command, args, .{ .ctx = p, .func = onResult })) {
        _ = sh.inflight.fetchSub(1, .acq_rel);
        sh.gpa.destroy(p);
        sh.release();
        return false;
    }
    return true;
}

fn onResult(ctx: ?*anyopaque, r: DapConnection.RawResult) void {
    const p: *Pending = @ptrCast(@alignCast(ctx.?));
    defer r.deinit();
    const sh = p.sh;
    const tag = p.tag;
    const gen = p.gen;
    sh.gpa.destroy(p);
    defer sh.release();
    const ok, const text: []const u8 = switch (r) {
        .ok => |o| .{ true, if (o.response.body) |b| b.bytes else "{}" },
        .failed => |o| .{ false, o.errorText() },
        .timeout => .{ false, "the debug adapter did not answer" },
        .closed => .{ false, "the debug session ended" },
    };
    if (sh.gpa.dupe(u8, text)) |bytes| {
        sh.push(.{ .what = .{ .result = .{ .tag = tag, .gen = gen, .ok = ok, .bytes = bytes } } });
    } else |_| {}
    _ = sh.inflight.fetchSub(1, .acq_rel);
    sh.event.set(sh.io);
}

/// Queues a session change (from a `DebugManager` listener, any thread).
pub fn post(ch: *Channel, change: DebugSession.Change, bytes: []const u8) void {
    const sh = ch.shared;
    const copy = sh.gpa.dupe(u8, bytes) catch return;
    sh.push(.{ .what = .{ .change = .{ .change = change, .bytes = copy } } });
}

/// Takes the queued items (free each with `Item.deinit`, then the slice).
pub fn take(ch: *Channel) Allocator.Error![]Item {
    const sh = ch.shared;
    sh.mutex.lockUncancelable(sh.io);
    defer sh.mutex.unlock(sh.io);
    sh.event.reset();
    return sh.items.toOwnedSlice(sh.gpa);
}

/// Requests whose results have not been queued yet.
pub fn inflight(ch: *const Channel) u32 {
    return ch.shared.inflight.load(.acquire);
}

/// Waits up to `timeout` for an item.
pub fn wait(ch: *Channel, timeout: Io.Duration) void {
    const sh = ch.shared;
    sh.event.waitTimeout(sh.io, .{ .duration = .{ .raw = timeout, .clock = .awake } }) catch {};
    zg_perf.idle.noteWake("dap.inspect.wait", .signal);
}

pub fn caps(ch: *const Channel) protocol.Capabilities {
    return ch.port.caps(ch.port.ctx);
}

test "waker runs on every queued item, not after deinit" {
    const gpa = std.testing.allocator;
    var ch: Channel = try .init(gpa, std.testing.io, .none);
    var n: u32 = 0;
    const W = struct {
        fn f(ctx: ?*anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ctx.?));
            c.* += 1;
        }
    };
    ch.setWaker(.{ .ctx = &n, .func = W.f });
    ch.post(.stack, "");
    ch.post(.continued, "");
    try std.testing.expectEqual(@as(u32, 2), n);
    const items = try ch.take();
    for (items) |it| it.deinit(gpa);
    gpa.free(items);
    ch.setWaker(null);
    ch.post(.stack, "");
    try std.testing.expectEqual(@as(u32, 2), n);
    ch.deinit();
}
