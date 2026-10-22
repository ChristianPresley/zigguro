//! Budgets: turns, wall time (awake clock), cost and tokens. Checked
//! before each model request (with the request's projected cost) and
//! before each tool batch. A stop finishes the turn gracefully; it never
//! interrupts a running tool.

const std = @import("std");
const proto = @import("zg_ai_proto");
const pricing = @import("../models/pricing.zig");

pub const Kind = enum { turns, wall_time, cost, input_tokens, output_tokens };

pub const Budgets = struct {
    max_turns: ?u32 = null,
    max_wall_ms: ?u64 = null,
    max_cost_micros: ?u64 = null,
    max_input_tokens: ?u64 = null,
    max_output_tokens: ?u64 = null,
    /// Warn at this fraction of a limit, in thousandths.
    warn_fraction_milli: u16 = 800,
    /// Count subagent spend toward this agent.
    include_subagents: bool = true,
};

/// What has been spent so far.
pub const Used = struct {
    turns: u32 = 0,
    wall_ms: u64 = 0,
    cost_micros: u64 = 0,
    usage: proto.Usage = .{},
};

/// The next request, for cost projection.
pub const Projection = struct {
    est_input: u64,
    max_output: u32,
    /// Cache reads of the last request (the prefix is assumed unchanged).
    expected_cache_read: u64 = 0,
    price: ?pricing.Price = null,
};

pub const Check = union(enum) {
    ok,
    warn: Kind,
    stop: Kind,
};

fn over(limit: ?u64, value: u64) bool {
    return if (limit) |l| value >= l else false;
}

fn warnAt(b: *const Budgets, limit: ?u64, value: u64) bool {
    const l = limit orelse return false;
    return value * 1000 >= l * b.warn_fraction_milli;
}

/// Before a model request. `used.turns` counts requests already made.
pub fn beforeRequest(b: *const Budgets, used: Used, p: Projection) Check {
    if (b.max_turns) |m| if (used.turns >= m) return .{ .stop = .turns };
    if (over(b.max_wall_ms, used.wall_ms)) return .{ .stop = .wall_time };
    if (over(b.max_input_tokens, used.usage.totalInput())) return .{ .stop = .input_tokens };
    if (over(b.max_output_tokens, used.usage.output)) return .{ .stop = .output_tokens };
    const projected: u64 = if (p.price) |price| pricing.costOf(price, .{
        .input = p.est_input -| p.expected_cache_read,
        .cache_read = @min(p.expected_cache_read, p.est_input),
        .output = p.max_output,
    }).micros else 0;
    if (b.max_cost_micros) |m| if (used.cost_micros + projected > m) return .{ .stop = .cost };
    return warnings(b, used, used.cost_micros + projected);
}

/// Before running a tool batch.
pub fn beforeTools(b: *const Budgets, used: Used) Check {
    if (over(b.max_wall_ms, used.wall_ms)) return .{ .stop = .wall_time };
    if (over(b.max_cost_micros, used.cost_micros)) return .{ .stop = .cost };
    return warnings(b, used, used.cost_micros);
}

fn warnings(b: *const Budgets, used: Used, cost: u64) Check {
    if (b.max_turns) |m| if (warnAt(b, m, used.turns + 1)) return .{ .warn = .turns };
    if (warnAt(b, b.max_wall_ms, used.wall_ms)) return .{ .warn = .wall_time };
    if (warnAt(b, b.max_cost_micros, cost)) return .{ .warn = .cost };
    if (warnAt(b, b.max_input_tokens, used.usage.totalInput())) return .{ .warn = .input_tokens };
    if (warnAt(b, b.max_output_tokens, used.usage.output)) return .{ .warn = .output_tokens };
    return .ok;
}

/// Fires each warning kind once.
pub const WarnOnce = struct {
    fired: std.EnumSet(Kind) = .{},

    /// True the first time `k` is seen.
    pub fn first(w: *WarnOnce, k: Kind) bool {
        if (w.fired.contains(k)) return false;
        w.fired.insert(k);
        return true;
    }
};

/// Wall time on the awake clock (sleep and suspend not counted).
pub const WallClock = struct {
    t0: std.Io.Timestamp,

    pub fn start(io: std.Io) WallClock {
        return .{ .t0 = std.Io.Timestamp.now(io, .awake) };
    }

    pub fn elapsedMs(w: WallClock, io: std.Io) u64 {
        const d = w.t0.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
        return @intCast(@max(d, 0));
    }
};

const testing = std.testing;

test "turn_limit" {
    const b: Budgets = .{ .max_turns = 3 };
    try testing.expect(beforeRequest(&b, .{ .turns = 0 }, .{ .est_input = 0, .max_output = 0 }) == .ok);
    try testing.expectEqual(Check{ .warn = .turns }, beforeRequest(&b, .{ .turns = 2 }, .{ .est_input = 0, .max_output = 0 }));
    try testing.expectEqual(Check{ .stop = .turns }, beforeRequest(&b, .{ .turns = 3 }, .{ .est_input = 0, .max_output = 0 }));
}

test "cost_projection_blocks_request" {
    const price: pricing.Price = .{ .input_per_mtok_micros = 2_000_000, .output_per_mtok_micros = 10_000_000 };
    const b: Budgets = .{ .max_cost_micros = 100_000 };
    // 10k input ($0.02) + 8k output ($0.08) = 100_000 micros: over by spend of 1.
    try testing.expectEqual(Check{ .stop = .cost }, beforeRequest(&b, .{ .cost_micros = 1 }, .{ .est_input = 10_000, .max_output = 8_000, .price = price }));
    // Expected cache reads make it cheaper: 2k uncached + 8k read.
    const c = beforeRequest(&b, .{ .cost_micros = 1 }, .{ .est_input = 10_000, .max_output = 8_000, .expected_cache_read = 8_000, .price = price });
    try testing.expectEqual(Check{ .warn = .cost }, c);
    try testing.expect(beforeRequest(&b, .{}, .{ .est_input = 1_000, .max_output = 1_000, .price = price }) == .ok);
    try testing.expectEqual(Check{ .stop = .cost }, beforeTools(&b, .{ .cost_micros = 100_000 }));
}

test "token and wall limits" {
    const b: Budgets = .{ .max_input_tokens = 1000, .max_output_tokens = 100, .max_wall_ms = 5000 };
    try testing.expectEqual(Check{ .stop = .input_tokens }, beforeRequest(&b, .{ .usage = .{ .input = 500, .cache_read = 500 } }, .{ .est_input = 0, .max_output = 0 }));
    try testing.expectEqual(Check{ .stop = .output_tokens }, beforeRequest(&b, .{ .usage = .{ .output = 100 } }, .{ .est_input = 0, .max_output = 0 }));
    try testing.expectEqual(Check{ .stop = .wall_time }, beforeTools(&b, .{ .wall_ms = 5000 }));
    try testing.expectEqual(Check{ .warn = .wall_time }, beforeTools(&b, .{ .wall_ms = 4500 }));
}

test "warn_once_per_kind" {
    var w: WarnOnce = .{};
    try testing.expect(w.first(.cost));
    try testing.expect(!w.first(.cost));
    try testing.expect(w.first(.turns));
}

test "wall_time_awake_clock" {
    const w = WallClock.start(testing.io);
    try testing.io.sleep(.fromMilliseconds(15), .awake);
    try testing.expect(w.elapsedMs(testing.io) >= 14);
}
