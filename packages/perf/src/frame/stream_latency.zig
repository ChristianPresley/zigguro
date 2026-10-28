//! `ai.chunk_to_photon` and `ai.tool_dispatch_overhead` (E14.F02.S01.T03):
//! the agent pane held to the same "instant" standard as typing.
//!
//! A stream chunk's receive time comes from the network worker through a
//! lock-free SPSC ring; the UI thread notes which frame applied it, and
//! when that frame's presentation time is known every chunk it showed is
//! recorded, coalesced chunks each with their own receive time.

const std = @import("std");
const zg_core = @import("zg_core");
const histogram = @import("histogram.zig");

const LatencyHistogram = histogram.LatencyHistogram;

/// Pending chunk slots.
pub const capacity = 1024;

const Recv = struct { chunk_id: u64, t_recv_ns: u64 };
const Pending = struct { chunk_id: u64 = 0, t_recv_ns: u64 = 0, frame_seq: u64 = 0, used: bool = false };

/// Chunk-to-photon tracking for one stream consumer (no allocation).
pub const StreamLatency = struct {
    inbox: zg_core.containers.SpscRing(Recv, capacity) = .empty,
    slots: [capacity]Pending = @splat(.{}),
    /// Real presentation times.
    chunk_to_photon: LatencyHistogram = .{},
    /// Estimated presentation times (no feedback).
    chunk_to_photon_estimated: LatencyHistogram = .{},
    /// Chunks evicted because every slot was pending (UI thread).
    dropped: u64 = 0,
    /// Chunks lost because the inbox was full (network worker).
    inbox_full: std.atomic.Value(u64) = .init(0),

    /// An empty tracker.
    pub fn init() StreamLatency {
        return .{};
    }

    /// Network worker: chunk `chunk_id` arrived at `t_recv_ns`.
    pub fn onChunkReceived(s: *StreamLatency, chunk_id: u64, t_recv_ns: u64) void {
        if (!s.inbox.push(.{ .chunk_id = chunk_id, .t_recv_ns = t_recv_ns })) _ = s.inbox_full.fetchAdd(1, .monotonic);
    }

    fn drain(s: *StreamLatency) void {
        while (s.inbox.pop()) |r| {
            var free: ?usize = null;
            var oldest: usize = 0;
            for (&s.slots, 0..) |*p, i| {
                if (!p.used) {
                    free = i;
                    break;
                }
                if (p.t_recv_ns < s.slots[oldest].t_recv_ns) oldest = i;
            }
            const i = free orelse blk: {
                s.dropped += 1;
                break :blk oldest;
            };
            s.slots[i] = .{ .chunk_id = r.chunk_id, .t_recv_ns = r.t_recv_ns, .used = true };
        }
    }

    /// UI thread: the chunk's text entered the view model in `frame_seq`.
    pub fn onChunkApplied(s: *StreamLatency, chunk_id: u64, frame_seq: u64) void {
        s.drain();
        for (&s.slots) |*p| if (p.used and p.chunk_id == chunk_id) {
            p.frame_seq = frame_seq;
            return;
        };
    }

    /// UI thread (from `FrameTimeline`): frame `frame_seq` was presented.
    pub fn onFramePresented(s: *StreamLatency, frame_seq: u64, t_presented_ns: u64, estimated: bool) void {
        s.drain();
        for (&s.slots) |*p| if (p.used and p.frame_seq == frame_seq and frame_seq != 0) {
            const v = t_presented_ns -| p.t_recv_ns;
            if (estimated) s.chunk_to_photon_estimated.record(v) else s.chunk_to_photon.record(v);
            zg_core.trace.counter("perf.ai_chunk_to_photon_ns", @intCast(v));
            p.* = .{};
        };
    }
};

/// Process-wide `ai.tool_dispatch_overhead` histogram (any thread).
pub const ToolDispatch = struct {
    lock: std.atomic.Value(bool) = .init(false),
    hist: LatencyHistogram = .{},

    /// Records `total_ns - exec_ns`.
    pub fn record(t: *ToolDispatch, total_ns: u64, exec_ns: u64) void {
        const v = total_ns -| exec_ns;
        while (t.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        t.hist.record(v);
        t.lock.store(false, .release);
        zg_core.trace.counter("perf.ai_tool_dispatch_overhead_ns", @intCast(v));
    }

    /// A copy of the histogram.
    pub fn snapshot(t: *ToolDispatch) LatencyHistogram {
        while (t.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        defer t.lock.store(false, .release);
        return t.hist;
    }
};

/// The process-wide tool dispatch histogram.
pub var tool_dispatch: ToolDispatch = .{};

/// E10, at the end of each tool call: harness overhead = total - exec.
pub fn toolDispatchOverhead(total_ns: u64, exec_ns: u64) void {
    tool_dispatch.record(total_ns, exec_ns);
}

test "stream_latency: chunk received -> applied -> presented gives exact latency" {
    var s = StreamLatency.init();
    s.onChunkReceived(1, 1_000_000);
    s.onChunkApplied(1, 7);
    s.onFramePresented(7, 6_000_000, false);
    try std.testing.expectEqual(@as(u64, 1), s.chunk_to_photon.total);
    try std.testing.expectEqual(@as(u64, 5_000_000), s.chunk_to_photon.max);
}

test "stream_latency: coalesced chunks each recorded" {
    var s = StreamLatency.init();
    s.onChunkReceived(1, 1_000_000);
    s.onChunkReceived(2, 2_000_000);
    s.onChunkReceived(3, 3_000_000);
    for ([_]u64{ 1, 2, 3 }) |c| s.onChunkApplied(c, 9);
    s.onFramePresented(9, 10_000_000, false);
    try std.testing.expectEqual(@as(u64, 3), s.chunk_to_photon.total);
    try std.testing.expectEqual(@as(u64, 9_000_000), s.chunk_to_photon.max);
    try std.testing.expectEqual(@as(u64, 7_000_000), s.chunk_to_photon.min);
}

test "stream_latency: estimated frames go to separate histogram" {
    var s = StreamLatency.init();
    s.onChunkReceived(1, 0);
    s.onChunkApplied(1, 2);
    s.onFramePresented(2, 4_000_000, true);
    try std.testing.expectEqual(@as(u64, 0), s.chunk_to_photon.total);
    try std.testing.expectEqual(@as(u64, 1), s.chunk_to_photon_estimated.total);
}

test "stream_latency: ring overflow drops oldest and counts drops" {
    var s = StreamLatency.init();
    for (0..capacity) |i| {
        s.onChunkReceived(i + 1, 1000 + i);
        s.onChunkApplied(i + 1, 0); // applied to no frame yet: stays pending
    }
    s.onChunkReceived(99_999, 5_000_000);
    s.onChunkApplied(99_999, 3);
    try std.testing.expectEqual(@as(u64, 1), s.dropped);
    // Chunk 1 (the oldest) was evicted; the newest one is tracked.
    s.onChunkApplied(1, 3);
    s.onFramePresented(3, 6_000_000, false);
    try std.testing.expectEqual(@as(u64, 1), s.chunk_to_photon.total);
    try std.testing.expectEqual(@as(u64, 1_000_000), s.chunk_to_photon.max);
}

test "stream_latency: tool dispatch overhead" {
    var t: ToolDispatch = .{};
    t.record(1_500_000, 1_000_000);
    t.record(100, 200);
    const h = t.snapshot();
    try std.testing.expectEqual(@as(u64, 2), h.total);
    try std.testing.expectEqual(@as(u64, 500_000), h.max);
}
