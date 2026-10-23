//! Animation playback (E04.F06.S02.T02): which frame of an animated image
//! shows at a time, from the decoder's frame delays and loop count. The
//! player only moves when told the time (`advance`), so the image cache
//! decides when it runs: on app timers, while the image is visible and
//! reduced motion is off.

const std = @import("std");

/// One animation's position.
pub const AnimPlayer = struct {
    frame: u32 = 0,
    /// When the current frame ends; 0 until `start`.
    due_ms: u64 = 0,
    /// Completed loops.
    loops: u32 = 0,
    /// The last loop ended (a finite loop count): the frame stays.
    done: bool = false,

    /// Starts (or resumes after a pause) at `now_ms`: the current frame
    /// shows for its whole delay.
    pub fn start(p: *AnimPlayer, now_ms: u64, delays: []const u32) void {
        if (p.done or delays.len < 2) return;
        p.due_ms = now_ms + delays[p.frame];
    }

    /// Whether `start` has run since the last `pause`.
    pub fn running(p: *const AnimPlayer) bool {
        return p.due_ms != 0 and !p.done;
    }

    /// Stops the clock; the frame stays.
    pub fn pause(p: *AnimPlayer) void {
        p.due_ms = 0;
    }

    /// Moves to the frame showing at `now_ms`. `loop_count` 0 loops
    /// forever (the GIF NETSCAPE extension's count). Returns whether the
    /// frame changed. A long gap does not replay every frame it missed:
    /// at most one loop is skipped through.
    pub fn advance(p: *AnimPlayer, now_ms: u64, delays: []const u32, loop_count: u16) bool {
        if (!p.running() or delays.len < 2 or now_ms < p.due_ms) return false;
        const before = p.frame;
        var steps: usize = 0;
        while (now_ms >= p.due_ms and steps < delays.len) : (steps += 1) {
            if (p.frame + 1 == delays.len) {
                p.loops += 1;
                if (loop_count != 0 and p.loops >= loop_count) {
                    p.done = true;
                    break;
                }
                p.frame = 0;
            } else p.frame += 1;
            p.due_ms += @max(delays[p.frame], 1);
        }
        // Too far behind (a stall): restart the clock from now.
        if (now_ms >= p.due_ms) p.due_ms = now_ms + delays[p.frame];
        return p.frame != before;
    }
};

const testing = std.testing;

test "frames follow their delays and loop" {
    const delays = [_]u32{ 100, 50, 200 };
    var p: AnimPlayer = .{};
    p.start(1000, &delays);
    try testing.expect(!p.advance(1099, &delays, 0));
    try testing.expect(p.advance(1100, &delays, 0));
    try testing.expectEqual(@as(u32, 1), p.frame);
    try testing.expect(p.advance(1150, &delays, 0));
    try testing.expectEqual(@as(u32, 2), p.frame);
    try testing.expect(p.advance(1350, &delays, 0));
    try testing.expectEqual(@as(u32, 0), p.frame);
    try testing.expectEqual(@as(u32, 1), p.loops);
}

test "finite loop count stops on the last frame" {
    const delays = [_]u32{ 10, 10 };
    var p: AnimPlayer = .{};
    p.start(0, &delays);
    _ = p.advance(10, &delays, 1);
    try testing.expectEqual(@as(u32, 1), p.frame);
    _ = p.advance(20, &delays, 1);
    try testing.expect(p.done and !p.running());
    try testing.expectEqual(@as(u32, 1), p.frame);
}

test "pause keeps the frame; a stall skips ahead without replaying" {
    const delays = [_]u32{ 100, 100, 100 };
    var p: AnimPlayer = .{};
    p.start(0, &delays);
    _ = p.advance(100, &delays, 0);
    p.pause();
    try testing.expect(!p.advance(10_000, &delays, 0));
    try testing.expectEqual(@as(u32, 1), p.frame);
    p.start(10_000, &delays);
    _ = p.advance(1_000_000, &delays, 0);
    try testing.expect(p.due_ms > 1_000_000 and p.due_ms <= 1_000_100);
}
