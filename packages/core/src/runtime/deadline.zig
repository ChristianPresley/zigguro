//! Deadlines on the monotonic `.awake` clock and `withDeadline`, which races
//! a function against a timer through `std.Io.Select`.
//!
//! `std.Io.Timeout` payloads are clock-tagged (`Io.Clock.Duration`,
//! `Io.Clock.Timestamp`), not bare `Io.Duration`; convert explicitly. For a
//! single blocking primitive prefer its native timeout parameter
//! (`Event.waitTimeout(io, d.timeout())`) over `withDeadline`.

const std = @import("std");
const Io = std.Io;

/// An absolute point in time on the `.awake` clock.
pub const Deadline = struct {
    at: Io.Clock.Timestamp,

    /// The deadline `d` from now.
    pub fn after(io: Io, d: Io.Duration) Deadline {
        return .{ .at = .fromNow(io, .{ .raw = d, .clock = .awake }) };
    }

    /// True once the deadline has passed.
    pub fn expired(self: Deadline, io: Io) bool {
        return self.remaining(io).nanoseconds == 0;
    }

    /// Time left, clamped at zero.
    pub fn remaining(self: Deadline, io: Io) Io.Duration {
        const d = self.at.durationFromNow(io).raw;
        return if (d.nanoseconds < 0) .zero else d;
    }

    /// The deadline as an `Io.Timeout`.
    pub fn timeout(self: Deadline) Io.Timeout {
        return .{ .deadline = self.at };
    }
};

/// The payload type of `func`'s return type (error unions unwrapped).
pub fn ReturnPayload(comptime func: anytype) type {
    const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |eu| eu.payload,
        else => R,
    };
}

fn ReturnType(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}

/// Runs `func(args...)` and returns its result, or `error.Timeout` if
/// `deadline` passes first (the call is then canceled and awaited). `func`
/// must observe cancellation (any `Io` call is a cancelation point) and must
/// not be a long-lived loop: `Select.async` may run it inline.
pub fn withDeadline(io: Io, deadline: Deadline, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !ReturnPayload(func) {
    const U = union(enum) { done: ReturnType(func), timed_out: Io.Cancelable!void };
    var buf: [2]U = undefined;
    var sel = Io.Select(U).init(io, &buf);
    sel.async(.timed_out, Io.Clock.Timestamp.wait, .{ deadline.at, io });
    sel.async(.done, func, args);
    const first = sel.await() catch |err| {
        sel.cancelDiscard();
        return err;
    };
    switch (first) {
        .done => |r| {
            sel.cancelDiscard();
            return r;
        },
        .timed_out => {
            // The function may have completed inline before the timer fired.
            while (sel.cancel()) |late| switch (late) {
                .done => |r| if (@typeInfo(ReturnType(func)) == .error_union) {
                    if (r) |v| return v else |e| if (e != error.Canceled) return e;
                } else return r,
                .timed_out => {},
            };
            return error.Timeout;
        },
    }
}

test "deadline: after/expired/remaining" {
    const io = std.testing.io;
    const d = Deadline.after(io, .fromSeconds(60));
    try std.testing.expect(!d.expired(io));
    try std.testing.expect(d.remaining(io).nanoseconds > 0);
    const past = Deadline.after(io, .zero);
    try std.testing.expect(past.expired(io));
    try std.testing.expect(past.timeout() == .deadline);
}

fn slowAdd(io: Io, x: u32) !u32 {
    try io.sleep(.fromSeconds(10), .awake);
    return x + 1;
}

fn fastAdd(x: u32) u32 {
    return x + 1;
}

test "runtime: withDeadline returns Timeout" {
    const io = std.testing.io;
    try std.testing.expectError(error.Timeout, withDeadline(io, .after(io, .fromMilliseconds(20)), slowAdd, .{ io, 1 }));
    try std.testing.expectEqual(@as(u32, 2), try withDeadline(io, .after(io, .fromSeconds(5)), fastAdd, .{1}));
}
