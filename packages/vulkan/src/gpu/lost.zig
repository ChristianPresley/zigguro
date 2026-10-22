//! Device-lost policy and fault injection (E02.F02.S02.T01).
//!
//! Every call that can return `VK_ERROR_DEVICE_LOST` goes through
//! `Gpu.checkLost`, which latches a flag and returns `error.DeviceLost`.
//! The renderer then calls `Recovery.onLost`, which tears the GPU stack
//! down without waiting on the device, recreates it, and switches to the
//! software renderer after `max_losses` losses within `window_ns`.

const std = @import("std");

pub const LostPolicy = struct {
    max_losses: u8 = 3,
    window_ns: u64 = 60 * std.time.ns_per_s,
};

/// What the renderer does to recover. `teardown` destroys everything in
/// reverse creation order without waiting on the device; `recreate`
/// probes and chooses again, recreates the device and resources, calls
/// every registered `TextureSource.reupload` and requests a full redraw;
/// `switchToSoftware` moves the target to the software renderer.
pub const Hooks = struct {
    ctx: *anyopaque,
    teardown: *const fn (ctx: *anyopaque) void,
    recreate: *const fn (ctx: *anyopaque) anyerror!void,
    switchToSoftware: *const fn (ctx: *anyopaque) anyerror!void,
};

pub const Outcome = enum { recovered, switched_to_software };

pub const Recovery = struct {
    policy: LostPolicy = .{},
    /// Loss times (monotonic ns), oldest first.
    times: [max_history]u64 = undefined,
    len: usize = 0,

    const max_history = 32;

    /// Records a loss at `now_ns` and decides: recover, or switch to
    /// software when the window holds `max_losses` losses. Pure.
    pub fn record(self: *Recovery, now_ns: u64) Outcome {
        if (self.len == max_history) {
            std.mem.copyForwards(u64, self.times[0 .. max_history - 1], self.times[1..]);
            self.len -= 1;
        }
        self.times[self.len] = now_ns;
        self.len += 1;
        var in_window: usize = 0;
        for (self.history()) |t| {
            if (now_ns -| t < self.policy.window_ns) in_window += 1;
        }
        return if (in_window >= self.policy.max_losses) .switched_to_software else .recovered;
    }

    /// Handles a loss at `now_ns`: tears down, then recreates or switches
    /// to software. A failed recreation also switches to software.
    pub fn onLost(self: *Recovery, now_ns: u64, hooks: Hooks) anyerror!Outcome {
        hooks.teardown(hooks.ctx);
        if (self.record(now_ns) == .recovered) {
            if (hooks.recreate(hooks.ctx)) return .recovered else |err| {
                std.log.scoped(.vk).info("GPU recreation after device loss failed: {s}", .{@errorName(err)});
            }
        }
        try hooks.switchToSoftware(hooks.ctx);
        return .switched_to_software;
    }

    /// Monotonic nanoseconds of the recorded losses.
    pub fn history(self: *const Recovery) []const u64 {
        return self.times[0..self.len];
    }
};

/// `ZG_VK_FAULT=lost@frame:N` or `lost@submit:N`: synthesise a device loss
/// at the Nth frame or submit (Debug and test builds only).
pub const Fault = struct {
    at: At,
    n: u32,
    count: std.atomic.Value(u32) = .init(0),

    pub const At = enum { frame, submit };

    pub const enabled = @import("builtin").mode == .Debug or @import("builtin").is_test;

    pub fn parse(spec: []const u8) ?Fault {
        const rest = if (std.mem.startsWith(u8, spec, "lost@")) spec[5..] else return null;
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
        const at = std.meta.stringToEnum(At, rest[0..colon]) orelse return null;
        const n = std.fmt.parseInt(u32, rest[colon + 1 ..], 10) catch return null;
        return .{ .at = at, .n = n };
    }

    /// Counts an `at` event; true exactly at the Nth one.
    pub fn tick(self: *Fault, at: At) bool {
        if (!enabled or at != self.at) return false;
        return self.count.fetchAdd(1, .monotonic) + 1 == self.n;
    }
};

test "lost: policy switches after 3 in 60s" {
    var r: Recovery = .{};
    const s = std.time.ns_per_s;
    try std.testing.expectEqual(Outcome.recovered, r.record(10 * s));
    try std.testing.expectEqual(Outcome.recovered, r.record(30 * s));
    try std.testing.expectEqual(Outcome.switched_to_software, r.record(69 * s));
    // Losses spread out are recovered every time.
    var r2: Recovery = .{};
    for (0..40) |i| try std.testing.expectEqual(Outcome.recovered, r2.record(i * 31 * s));
    try std.testing.expectEqual(@as(usize, 32), r2.history().len);
    try std.testing.expectEqual(@as(u64, 39 * 31 * s), r2.history()[31]);
}

const Counter = struct {
    teardowns: u32 = 0,
    recreates: u32 = 0,
    switches: u32 = 0,
    fail_recreate: bool = false,

    fn teardown(ctx: *anyopaque) void {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        c.teardowns += 1;
    }
    fn recreate(ctx: *anyopaque) anyerror!void {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        c.recreates += 1;
        if (c.fail_recreate) return error.NoSuitableDevice;
    }
    fn toSoftware(ctx: *anyopaque) anyerror!void {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        c.switches += 1;
    }
    fn hooks(c: *Counter) Hooks {
        return .{ .ctx = c, .teardown = teardown, .recreate = recreate, .switchToSoftware = toSoftware };
    }
};

test "lost: onLost recreates, then switches to software" {
    var c: Counter = .{};
    var r: Recovery = .{};
    try std.testing.expectEqual(Outcome.recovered, try r.onLost(1, c.hooks()));
    try std.testing.expectEqual(Outcome.recovered, try r.onLost(2, c.hooks()));
    try std.testing.expectEqual(Outcome.switched_to_software, try r.onLost(3, c.hooks()));
    try std.testing.expectEqual(Counter{ .teardowns = 3, .recreates = 2, .switches = 1 }, c);
    // A failed recreation falls back to software too.
    var c2: Counter = .{ .fail_recreate = true };
    var r2: Recovery = .{};
    try std.testing.expectEqual(Outcome.switched_to_software, try r2.onLost(1, c2.hooks()));
}

test "lost: fault injection spec" {
    var f = Fault.parse("lost@submit:3").?;
    try std.testing.expectEqual(Fault.At.submit, f.at);
    try std.testing.expect(!f.tick(.submit));
    try std.testing.expect(!f.tick(.frame));
    try std.testing.expect(!f.tick(.submit));
    try std.testing.expect(f.tick(.submit));
    try std.testing.expect(!f.tick(.submit));
    try std.testing.expectEqual(@as(?Fault, null), Fault.parse("lost@vsync:1"));
    try std.testing.expectEqual(@as(?Fault, null), Fault.parse("crash@frame:1"));
    try std.testing.expectEqual(@as(?Fault, null), Fault.parse("lost@frame:x"));
}
