//! Maps platform presentation feedback to the frame timeline's present ids
//! (E14.F03.S02.T01). Backends report feedback in submit order
//! (`Event.present_feedback`) without our ids, so each window keeps the
//! ids of its last submits in a FIFO.
//!
//! The clock contract (docs/perf/latency.md section 1) needs presentation
//! times on `zg_core.time.nowNs`. A time is plausible when it is not in
//! the future and at most a second old; one implausible time (a virtual
//! clock, another clock domain) marks the window's feedback bad for good,
//! and its frames finalize as estimated. Frames expect feedback only once
//! a plausible one has arrived.

const std = @import("std");

/// How far back a plausible timestamp may be.
pub const max_age_ns: u64 = std.time.ns_per_s;

/// Whether `t` (nanoseconds) can be on the same clock as `now`.
pub fn plausible(t: u64, now: u64) bool {
    return t != 0 and t <= now and now - t <= max_age_ns;
}

/// `PresentFlags.discarded`.
pub const flag_discarded = @import("zg_platform").event.PresentFlags.discarded;

/// One window's feedback mapping.
pub const FeedbackMap = struct {
    pub const State = enum { unknown, ok, bad };
    pub const capacity = 16;

    ids: [capacity]u64 = undefined,
    head: u8 = 0,
    len: u8 = 0,
    state: State = .unknown,

    /// Feedback for one present id.
    pub const Mapped = struct { present_id: u64, presented_ns: u64, flags: u8, discarded: bool };

    /// Whether frames submitted now should wait for feedback.
    pub fn expectFeedback(m: *const FeedbackMap) bool {
        return m.state == .ok;
    }

    /// Remembers a submitted frame (the oldest is dropped when full: its
    /// backend sends no feedback).
    pub fn submitted(m: *FeedbackMap, present_id: u64) void {
        if (m.len == capacity) {
            m.head = (m.head + 1) % capacity;
            m.len -= 1;
        }
        m.ids[(m.head + m.len) % capacity] = present_id;
        m.len += 1;
    }

    /// The frame `presented_ns` belongs to, if the timeline should hear of
    /// it (`now` is `nowNs` when the event was read).
    pub fn feedback(m: *FeedbackMap, presented_ns: u64, flags: u8, now: u64) ?Mapped {
        if (m.len == 0) return null;
        const id = m.ids[m.head];
        m.head = (m.head + 1) % capacity;
        m.len -= 1;
        const discarded = flags & flag_discarded != 0;
        if (!discarded) {
            if (m.state == .bad) return null;
            if (!plausible(presented_ns, now)) {
                m.state = .bad;
                return null;
            }
            m.state = .ok;
        }
        return .{ .present_id = id, .presented_ns = presented_ns, .flags = flags, .discarded = discarded };
    }
};

test "present feedback: plausible window" {
    const now = 10 * std.time.ns_per_s;
    try std.testing.expect(plausible(now, now));
    try std.testing.expect(plausible(now - max_age_ns, now));
    try std.testing.expect(!plausible(now - max_age_ns - 1, now));
    try std.testing.expect(!plausible(now + 1, now));
    try std.testing.expect(!plausible(0, now));
}

test "present feedback: fifo mapping and states" {
    const now = 10 * std.time.ns_per_s;
    var m: FeedbackMap = .{};
    try std.testing.expect(!m.expectFeedback());
    try std.testing.expect(m.feedback(now, 1, now) == null);
    m.submitted(1);
    m.submitted(2);
    m.submitted(3);
    const a = m.feedback(now - 5_000, 1, now).?;
    try std.testing.expectEqual(@as(u64, 1), a.present_id);
    try std.testing.expect(m.expectFeedback());
    const b = m.feedback(0, flag_discarded, now).?;
    try std.testing.expect(b.discarded and b.present_id == 2);
    // A virtual clock: bad from now on.
    try std.testing.expect(m.feedback(16_666_667, 1, now) == null);
    try std.testing.expectEqual(FeedbackMap.State.bad, m.state);
    try std.testing.expect(!m.expectFeedback());
    m.submitted(4);
    try std.testing.expect(m.feedback(now, 1, now) == null);
}

test "present feedback: full fifo drops the oldest" {
    var m: FeedbackMap = .{};
    for (1..FeedbackMap.capacity + 3) |i| m.submitted(i);
    try std.testing.expectEqual(@as(u8, FeedbackMap.capacity), m.len);
    try std.testing.expectEqual(@as(u64, 3), m.feedback(5, 0, 10).?.present_id);
}
