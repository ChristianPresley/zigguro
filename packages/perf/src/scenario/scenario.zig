//! Macro scenarios (E14.F06.S01.T02): a scenario drives the composed app
//! through one workload. The runner calls `setup` once, `run` once per
//! repeat and `teardown` once; the body records its samples on the
//! `Context`. Every result name must bind to a budget in `budgets.zon`.

const std = @import("std");
const Context = @import("context.zig").Context;

pub const Fn = *const fn (*Context) anyerror!void;

pub const Scenario = struct {
    name: []const u8,
    /// Budget ids the results feed (for `zig build test` and the docs).
    budgets: []const []const u8 = &.{},
    repeats: u32 = 5,
    /// Repeats in quick mode.
    quick_repeats: u32 = 2,
    /// Untimed repeats before the measured ones.
    warmup: u32 = 0,
    setup: ?Fn = null,
    run: Fn,
    teardown: ?Fn = null,
};

/// Runs `s` on `c`: setup, warm-up and measured repeats, teardown (also
/// after a failed repeat). Samples recorded during warm-up are dropped.
pub fn runScenario(s: Scenario, c: *Context) !void {
    c.scenario = s.name;
    if (s.setup) |f| try f(c);
    defer if (s.teardown) |f| f(c) catch |e| std.log.warn("scenario {s}: teardown failed: {t}", .{ s.name, e });
    const repeats = if (c.quick) s.quick_repeats else s.repeats;
    var i: u32 = 0;
    c.discard = true;
    while (i < s.warmup) : (i += 1) {
        c.repeat = i;
        s.run(c) catch |e| {
            c.discard = false;
            return e;
        };
    }
    c.discard = false;
    i = 0;
    while (i < repeats) : (i += 1) {
        c.repeat = i;
        try s.run(c);
    }
}

/// The scenario called `name` in `all`.
pub fn find(all: []const Scenario, name: []const u8) ?*const Scenario {
    for (all) |*s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

const T = struct {
    var setups: u32 = 0;
    var teardowns: u32 = 0;
    fn setup(_: *Context) !void {
        setups += 1;
    }
    fn teardown(_: *Context) !void {
        teardowns += 1;
    }
    fn run(c: *Context) !void {
        try c.record("op", 100 + c.repeat);
    }
};

test "scenario: setup, warm-up, repeats, teardown" {
    var c: Context = .init(std.testing.allocator, std.testing.io);
    defer c.deinit();
    const s: Scenario = .{ .name = "demo", .repeats = 4, .warmup = 2, .setup = T.setup, .run = T.run, .teardown = T.teardown };
    try runScenario(s, &c);
    try std.testing.expectEqual(@as(u32, 1), T.setups);
    try std.testing.expectEqual(@as(u32, 1), T.teardowns);
    const got = c.samples("demo.op").?;
    try std.testing.expectEqualSlices(u64, &.{ 100, 101, 102, 103 }, got);
    c.quick = true;
    try runScenario(s, &c);
    try std.testing.expectEqual(@as(usize, 6), c.samples("demo.op").?.len);
    try std.testing.expect(find(&.{s}, "demo") != null);
}
