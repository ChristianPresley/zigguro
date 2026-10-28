//! Budget evaluation: turns an observed value into a verdict, scaled for
//! the machine and the build mode (E14.F01.S01.T02).

const std = @import("std");
const builtin = @import("builtin");
const schema = @import("schema.zig");
const registry = @import("registry.zig");

const log = std.log.scoped(.perf);

/// The outcome of comparing an observation with a budget.
pub const Verdict = enum { pass, warn, fail };

/// A full evaluation result.
pub const Evaluation = struct {
    /// The evaluated budget.
    budget: *const schema.Budget,
    /// The observed value, in the budget's unit.
    observed: f64,
    /// `limit` after machine and build-mode scaling.
    scaled_limit: f64,
    /// The verdict (always `pass` for `gate = .track`).
    verdict: Verdict,
    /// Distance to the limit as a percentage of it; negative when over.
    headroom_pct: f64,
};

/// How much slower each build mode is allowed to be than ReleaseFast.
pub const BuildScale = struct {
    debug: f64 = 20,
    release_safe: f64 = 1.5,
    release_fast: f64 = 1,
    release_small: f64 = 1.3,
};

/// The build-mode factor for the current compilation.
pub fn buildModeScale() f64 {
    const s: BuildScale = .{};
    return switch (builtin.mode) {
        .Debug => s.debug,
        .ReleaseSafe => s.release_safe,
        .ReleaseFast => s.release_fast,
        .ReleaseSmall => s.release_small,
    };
}

/// True when `b` measures something no machine or build mode changes
/// (counts, and wakeups or allocations on `machine = .any`).
pub fn machineIndependent(b: *const schema.Budget) bool {
    return b.metric == .count or b.machine == .any;
}

/// Evaluates `observed` against `b`. `machine_scale` is 1.0 on the
/// budget's machine class and > 1 on a slower machine. Never allocates.
pub fn evaluate(b: *const schema.Budget, observed: f64, machine_scale: f64) Evaluation {
    return evaluateScaled(b, observed, machine_scale, buildModeScale());
}

/// `evaluate` with an explicit build-mode factor (tests, perfgate).
pub fn evaluateScaled(b: *const schema.Budget, observed: f64, machine_scale: f64, mode_scale: f64) Evaluation {
    const scale = if (machineIndependent(b)) 1.0 else machine_scale * mode_scale;
    var e: Evaluation = .{ .budget = b, .observed = observed, .scaled_limit = b.limit, .verdict = .pass, .headroom_pct = 0 };
    switch (b.direction) {
        .lower_is_better => {
            e.scaled_limit = b.limit * scale;
            e.headroom_pct = (e.scaled_limit - observed) / e.scaled_limit * 100;
            if (observed > e.scaled_limit) {
                e.verdict = .fail;
            } else if (b.target) |t| {
                if (observed > t * scale) e.verdict = .warn;
            }
        },
        .higher_is_better => {
            e.scaled_limit = b.limit / scale;
            e.headroom_pct = (observed - e.scaled_limit) / e.scaled_limit * 100;
            if (observed < e.scaled_limit) {
                e.verdict = .fail;
            } else if (b.target) |t| {
                if (observed < t / scale) e.verdict = .warn;
            }
        },
    }
    if (b.gate == .track) e.verdict = .pass;
    return e;
}

/// Test helper: fails with `error.BudgetExceeded` when `observed` breaks
/// budget `id` on this build mode (machine scale 1). Logs the numbers.
pub fn expectWithin(comptime id: []const u8, observed: f64) error{BudgetExceeded}!void {
    const b = comptime registry.get(id);
    const e = evaluate(b, observed, 1.0);
    if (e.verdict == .fail) {
        log.info("budget {s}: observed {d} (limit {d}, scale {d})", .{ id, observed, b.limit, e.scaled_limit / b.limit });
        return error.BudgetExceeded;
    }
}

fn row(direction: schema.Direction, limit: f64, target: ?f64) schema.Budget {
    return .{ .id = "t.x", .owner = "E14", .spec = "E14", .metric = .duration_ns, .stat = .p99, .direction = direction, .limit = limit, .target = target, .source = .{ .runtime = "pending" } };
}

test "check: lower is better pass/warn/fail" {
    const b = row(.lower_is_better, 100, 50);
    try std.testing.expectEqual(Verdict.pass, evaluateScaled(&b, 40, 1, 1).verdict);
    try std.testing.expectEqual(Verdict.warn, evaluateScaled(&b, 60, 1, 1).verdict);
    try std.testing.expectEqual(Verdict.fail, evaluateScaled(&b, 101, 1, 1).verdict);
    try std.testing.expectApproxEqAbs(@as(f64, 60), evaluateScaled(&b, 40, 1, 1).headroom_pct, 1e-9);
    // A machine twice as slow doubles the limit.
    try std.testing.expectEqual(Verdict.warn, evaluateScaled(&b, 150, 2, 1).verdict);
}

test "check: higher is better throughput" {
    var b = row(.higher_is_better, 500e6, 1e9);
    b.metric = .bytes_per_second;
    try std.testing.expectEqual(Verdict.pass, evaluateScaled(&b, 1.2e9, 1, 1).verdict);
    try std.testing.expectEqual(Verdict.warn, evaluateScaled(&b, 700e6, 1, 1).verdict);
    try std.testing.expectEqual(Verdict.fail, evaluateScaled(&b, 400e6, 1, 1).verdict);
    // Half-speed machine: the limit halves, the target too.
    try std.testing.expectEqual(Verdict.warn, evaluateScaled(&b, 300e6, 2, 1).verdict);
    try std.testing.expectApproxEqAbs(@as(f64, 20), evaluateScaled(&b, 600e6, 1, 1).headroom_pct, 1e-9);
    b.gate = .track;
    try std.testing.expectEqual(Verdict.pass, evaluateScaled(&b, 1, 1, 1).verdict);
}

test "check: machine-independent not scaled" {
    var b = row(.lower_is_better, 8, null);
    b.metric = .count;
    try std.testing.expectEqual(Verdict.fail, evaluateScaled(&b, 9, 3, 20).verdict);
    b.metric = .per_second;
    b.machine = .any;
    try std.testing.expectEqual(@as(f64, 8), evaluateScaled(&b, 0, 3, 20).scaled_limit);
}

test "check: debug scale applied" {
    const b = row(.lower_is_better, 100, null);
    const e = evaluate(&b, 150, 1);
    if (builtin.mode == .Debug) {
        try std.testing.expectEqual(@as(f64, 2000), e.scaled_limit);
        try std.testing.expectEqual(Verdict.pass, e.verdict);
    } else {
        try std.testing.expect(e.scaled_limit < 2000);
    }
    try expectWithin("input.key_to_photon", 1_000_000);
    try std.testing.expectError(error.BudgetExceeded, expectWithin("idle.wakeups", 5));
}

test "check: zg_core mailbox post+drain within core.mailbox_push_pop" {
    const zg_core = @import("zg_core");
    const io = std.testing.io;
    var mb = try zg_core.runtime.Mailbox.init(std.testing.allocator, 1024);
    defer mb.deinit(std.testing.allocator);
    var out: [1]zg_core.runtime.UiMsg = undefined;
    // Best of 8 batches of 512 round trips: robust against a preempted batch.
    var best: f64 = std.math.inf(f64);
    for (0..8) |_| {
        const t0 = zg_core.time.nowNs(io);
        for (0..512) |i| {
            try mb.post(io, .{ .kind = 1, .a = i }, false);
            std.mem.doNotOptimizeAway(mb.drain(io, &out));
        }
        best = @min(best, @as(f64, @floatFromInt(zg_core.time.nowNs(io) - t0)) / 512.0);
    }
    try expectWithin("core.mailbox_push_pop", best);
}
