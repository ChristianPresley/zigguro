//! The agent event bus: one producer (the agent's turn task), many
//! subscribers. Each event gets a per-agent sequence number.
//!
//! `inline_` subscribers run on the producer thread and must be O(1).
//! `queued` subscribers get their own bounded ring and drainer task, so a
//! slow subscriber never delays the others. When a ring is more than 75%
//! full, adjacent text/thinking deltas of the same block merge into one
//! event (their slices are contiguous in the transcript arena); structural
//! events are never merged or dropped. A full ring blocks the producer,
//! which only happens with a hung subscriber.
//!
//! Callbacks must not unsubscribe themselves.

const std = @import("std");
const zg_core = @import("zg_core");
const ev = @import("events.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Envelope = ev.Envelope;

pub const SubscriptionId = u32;

pub const Subscriber = struct {
    ctx: *anyopaque,
    on_events: *const fn (ctx: *anyopaque, batch: []const Envelope) void,
    mode: enum { inline_, queued } = .queued,
    capacity: u32 = 4096,
    coalesce_text: bool = true,
};

const max_batch = 256;

const Slot = struct {
    id: SubscriptionId,
    sub: Subscriber,
    // Queued mode only:
    ring: []Envelope = &.{},
    batch: []Envelope = &.{},
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,
    mutex: Io.Mutex = .init,
    not_empty: Io.Condition = .init,
    not_full: Io.Condition = .init,
    drainer: ?Io.Future(void) = null,

    fn push(s: *Slot, io: Io, e: Envelope) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        if (s.sub.coalesce_text and s.len * 4 > s.ring.len * 3 and s.len > 0 and e.ev.isDelta()) {
            const last = &s.ring[(s.head + s.len - 1) % s.ring.len];
            if (merge(&last.ev, e.ev)) return;
        }
        while (s.len == s.ring.len) s.not_full.waitUncancelable(io, &s.mutex);
        s.ring[(s.head + s.len) % s.ring.len] = e;
        s.len += 1;
        s.not_empty.signal(io);
    }

    fn closeLocked(s: *Slot, io: Io) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        s.closed = true;
        s.not_empty.broadcast(io);
    }

    fn drain(s: *Slot, io: Io) void {
        while (true) {
            const n = blk: {
                s.mutex.lockUncancelable(io);
                defer s.mutex.unlock(io);
                while (s.len == 0 and !s.closed) s.not_empty.waitUncancelable(io, &s.mutex);
                if (s.len == 0) return;
                const n = @min(s.len, s.batch.len);
                for (0..n) |i| s.batch[i] = s.ring[(s.head + i) % s.ring.len];
                s.head = (s.head + n) % s.ring.len;
                s.len -= n;
                s.not_full.broadcast(io);
                break :blk n;
            };
            s.sub.on_events(s.sub.ctx, s.batch[0..n]);
        }
    }
};

/// Merges delta `b` into `a` when both extend the same block and their
/// texts are adjacent in memory.
fn merge(a: *ev.AgentEvent, b: ev.AgentEvent) bool {
    if (a.* != .stream or b != .stream) return false;
    switch (a.stream) {
        .text_delta => |*d| if (b.stream == .text_delta) return extend(d.index, &d.text, b.stream.text_delta.index, b.stream.text_delta.text),
        .thinking_delta => |*d| if (b.stream == .thinking_delta) return extend(d.index, &d.text, b.stream.thinking_delta.index, b.stream.thinking_delta.text),
        else => {},
    }
    return false;
}

fn extend(ia: u32, ta: *[]const u8, ib: u32, tb: []const u8) bool {
    if (ia != ib or ta.ptr + ta.len != tb.ptr) return false;
    ta.* = ta.ptr[0 .. ta.len + tb.len];
    return true;
}

pub const Bus = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    slots: std.ArrayList(*Slot) = .empty,
    seq: u64 = 0,
    next_id: SubscriptionId = 1,

    pub fn init(gpa: Allocator, io: Io) Bus {
        return .{ .gpa = gpa, .io = io };
    }

    /// Unsubscribes everyone (queued subscribers drain first).
    pub fn deinit(b: *Bus) void {
        while (true) {
            const id = blk: {
                b.mutex.lockUncancelable(b.io);
                defer b.mutex.unlock(b.io);
                if (b.slots.items.len == 0) break;
                break :blk b.slots.items[0].id;
            };
            b.unsubscribe(id);
        }
        b.slots.deinit(b.gpa);
    }

    /// Publishes one event to every subscriber, in order. Single producer.
    pub fn publish(b: *Bus, e: ev.AgentEvent) void {
        const z = zg_core.trace.zone(@src(), "ai.bus.publish");
        defer z.end();
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        b.seq += 1;
        const env: Envelope = .{ .seq = b.seq, .ev = e };
        for (b.slots.items) |s| switch (s.sub.mode) {
            .inline_ => s.sub.on_events(s.sub.ctx, (&env)[0..1]),
            .queued => s.push(b.io, env),
        };
    }

    /// Continues numbering after `seq` (a resumed session), so new events
    /// and session records never reuse a sequence number. Call before the
    /// first publish.
    pub fn startAt(b: *Bus, seq: u64) void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        b.seq = @max(b.seq, seq);
    }

    /// The last sequence number published.
    pub fn lastSeq(b: *Bus) u64 {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        return b.seq;
    }

    pub fn subscribe(b: *Bus, sub: Subscriber) (Allocator.Error || Io.ConcurrentError)!SubscriptionId {
        const s = try b.gpa.create(Slot);
        errdefer b.gpa.destroy(s);
        s.* = .{ .id = 0, .sub = sub };
        if (sub.mode == .queued) {
            s.ring = try b.gpa.alloc(Envelope, @max(sub.capacity, 4));
            errdefer b.gpa.free(s.ring);
            s.batch = try b.gpa.alloc(Envelope, @min(s.ring.len, max_batch));
            errdefer b.gpa.free(s.batch);
            s.drainer = try b.io.concurrent(Slot.drain, .{ s, b.io });
        }
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        s.id = b.next_id;
        b.next_id += 1;
        b.slots.append(b.gpa, s) catch |e| {
            if (s.drainer) |*d| {
                s.closeLocked(b.io);
                d.await(b.io);
            }
            return e;
        };
        return s.id;
    }

    /// Removes a subscriber; a queued one receives everything already
    /// published before this returns.
    pub fn unsubscribe(b: *Bus, id: SubscriptionId) void {
        const s = blk: {
            b.mutex.lockUncancelable(b.io);
            defer b.mutex.unlock(b.io);
            for (b.slots.items, 0..) |s, i| if (s.id == id) {
                _ = b.slots.orderedRemove(i);
                break :blk s;
            };
            return;
        };
        if (s.drainer) |*d| {
            s.closeLocked(b.io);
            d.await(b.io);
            b.gpa.free(s.ring);
            b.gpa.free(s.batch);
        }
        b.gpa.destroy(s);
    }
};

/// Posts UI messages; `zg_core.Runtime.post` in the app.
pub const Poster = struct {
    ctx: *anyopaque,
    post: *const fn (ctx: *anyopaque, msg: zg_core.runtime.UiMsg) zg_core.runtime.Runtime.PostError!void,
};

/// Bridges an agent's events to the UI thread: buffers events and posts
/// at most one `UiMsg` until the UI drains, bounding UI work to one batch
/// per frame.
pub const UiBridge = struct {
    gpa: Allocator,
    io: Io,
    poster: Poster,
    msg: zg_core.runtime.UiMsg,
    mutex: Io.Mutex = .init,
    buf: std.ArrayList(Envelope) = .empty,
    pending: std.atomic.Value(bool) = .init(false),
    posts: std.atomic.Value(u32) = .init(0),

    pub fn init(gpa: Allocator, io: Io, poster: Poster, msg: zg_core.runtime.UiMsg) UiBridge {
        return .{ .gpa = gpa, .io = io, .poster = poster, .msg = msg };
    }

    pub fn deinit(u: *UiBridge) void {
        u.buf.deinit(u.gpa);
    }

    /// An inline subscriber feeding this bridge.
    pub fn subscriber(u: *UiBridge) Subscriber {
        return .{ .ctx = u, .on_events = onEvents, .mode = .inline_ };
    }

    fn onEvents(ctx: *anyopaque, batch: []const Envelope) void {
        const u: *UiBridge = @ptrCast(@alignCast(ctx));
        {
            u.mutex.lockUncancelable(u.io);
            defer u.mutex.unlock(u.io);
            u.buf.appendSlice(u.gpa, batch) catch return;
        }
        if (u.pending.swap(true, .acq_rel)) return;
        u.poster.post(u.poster.ctx, u.msg) catch {
            // Mailbox full or closed: the next event retries.
            u.pending.store(false, .release);
            return;
        };
        _ = u.posts.fetchAdd(1, .monotonic);
    }

    /// Called on the UI thread: moves every buffered event into `out`.
    pub fn drain(u: *UiBridge, gpa: Allocator, out: *std.ArrayList(Envelope)) Allocator.Error!void {
        u.mutex.lockUncancelable(u.io);
        defer u.mutex.unlock(u.io);
        try out.appendSlice(gpa, u.buf.items);
        u.buf.clearRetainingCapacity();
        u.pending.store(false, .release);
    }
};
