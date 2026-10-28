//! Head-vs-base comparison (E14.F06.S02.T01). One `Row` per bench result
//! present on either side, with a verdict:
//!
//! - `missing`: absent on one side.
//! - `regressed`: allocations went up against the stored baseline (more
//!   than 0.5 alloc/op, or 5 % bytes; deterministic), or Mann–Whitney
//!   says head is slower with p < 0.01 and the median moved by more than
//!   the budget's `regression_tolerance_pct` (10 % by default). Needs at
//!   least 5 samples a side.
//! - `improved`: the same test the other way.
//! - `noisy`: a side's coefficient of variation is over 15 %.
//! - `budget_fail`: the head value breaks the bound budget on its own
//!   machine class (or the budget is machine-independent).
//! - `budget_warn`: it breaks the budget scaled by the calibration on
//!   another machine class (advisory).
//! - `pass`.
//!
//! A row blocks when its budget's gate is `block` and the verdict is
//! `regressed` or `budget_fail`, unless the PR is labelled accepted and
//! changes that suite's baseline file.

const std = @import("std");
const zg_perf = @import("zg_perf");
const stats = @import("stats.zig");
const baseline = @import("baseline.zig");

const schema = zg_perf.budget.schema;
const Budget = schema.Budget;

pub const Verdict = enum { pass, regressed, improved, noisy, missing, budget_fail, budget_warn };

pub const Row = struct {
    suite: []const u8,
    name: []const u8,
    budget_id: ?[]const u8 = null,
    base_median_ns: ?f64 = null,
    head_median_ns: ?f64 = null,
    delta_pct: ?f64 = null,
    p_value: ?f64 = null,
    verdict: Verdict = .pass,
    gate: schema.Gate = .warn,
    allocs_base: ?f64 = null,
    allocs_head: ?f64 = null,
    /// The head value checked against the budget, in its unit.
    budget_observed: ?f64 = null,
    budget_limit: ?f64 = null,
    note: []const u8 = "",
    blocking: bool = false,
};

pub const Options = struct {
    machine: schema.MachineClass = .ci_linux_x64,
    /// The calibration scale (this machine vs the reference laptop).
    scale: f64 = 1,
    accepted: bool = false,
    /// Baseline files the PR changes (`perf/baselines/<machine>/<suite>.json`).
    changed_baselines: []const []const u8 = &.{},
    baselines: baseline.Baselines = .{},
    alpha: f64 = 0.01,
    min_samples: usize = 5,
    noisy_cv: f64 = 0.15,
    budgets: []const Budget = zg_perf.budget.all,
};

fn samplesOf(r: *const baseline.BenchResult) []const f64 {
    if (r.samples_ns) |s| if (s.len > 0) return s;
    return (&r.ns_per_op)[0..1];
}

fn budgetFor(budgets: []const Budget, suite: []const u8, name: []const u8) ?*const Budget {
    for (budgets) |*b| switch (b.source) {
        .bench => |s| if (std.mem.eql(u8, s.suite, suite) and std.mem.eql(u8, s.name, name)) return b,
        else => {},
    };
    return null;
}

fn baselinePath(arena: std.mem.Allocator, machine: schema.MachineClass, suite: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "perf/baselines/{t}/{s}.json", .{ machine, suite });
}

/// Compares `head` against `base`.
pub fn compare(arena: std.mem.Allocator, base: baseline.Set, head: baseline.Set, opts: Options) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    for (head.files) |f| for (f.results) |*r| {
        try rows.append(arena, try row(arena, f.package, r.name, base.find(f.package, r.name), r, opts));
    };
    for (base.files) |f| for (f.results) |*r| {
        if (head.find(f.package, r.name) == null) try rows.append(arena, try row(arena, f.package, r.name, r, null, opts));
    };
    return rows.items;
}

fn row(arena: std.mem.Allocator, suite: []const u8, name: []const u8, base_r: ?*const baseline.BenchResult, head_r: ?*const baseline.BenchResult, opts: Options) !Row {
    var out: Row = .{ .suite = suite, .name = name };
    const budget = budgetFor(opts.budgets, suite, name);
    if (budget) |b| {
        out.budget_id = b.id;
        out.gate = b.gate;
    }
    if (base_r) |b| {
        out.base_median_ns = try stats.median(arena, samplesOf(b));
        out.allocs_base = b.allocs_per_op;
    }
    if (head_r) |h| {
        out.head_median_ns = try stats.median(arena, samplesOf(h));
        out.allocs_head = h.allocs_per_op;
    }
    const h = head_r orelse {
        out.verdict = .missing;
        out.note = "not in head";
        return out;
    };

    // Allocations against the stored baseline: deterministic.
    if (opts.baselines.find(suite, name)) |e| {
        out.allocs_base = e.allocs_per_op;
        if (h.allocs_per_op > e.allocs_per_op + 0.5 or h.bytes_alloc_per_op > e.bytes_alloc_per_op * 1.05 + 1) {
            out.verdict = .regressed;
            out.note = try std.fmt.allocPrint(arena, "allocations {d:.2}/op ({d:.0} B) vs baseline {d:.2}/op ({d:.0} B)", .{ h.allocs_per_op, h.bytes_alloc_per_op, e.allocs_per_op, e.bytes_alloc_per_op });
        }
    }

    if (base_r) |b| {
        const bs = samplesOf(b);
        const hs = samplesOf(h);
        const bm = out.base_median_ns.?;
        const hm = out.head_median_ns.?;
        // Higher-is-better samples (not ns) flip the test.
        const flip = if (budget) |bb| bb.direction == .higher_is_better and switch (bb.source) {
            .bench => |s| s.field != .throughput_bps,
            else => false,
        } else false;
        if (bm != 0) out.delta_pct = (hm - bm) / bm * 100;
        const tol = if (budget) |bb| bb.regression_tolerance_pct else 10;
        if (out.verdict == .pass) {
            if (stats.cv(bs) > opts.noisy_cv or stats.cv(hs) > opts.noisy_cv) {
                out.verdict = .noisy;
                out.note = "coefficient of variation over 15 %";
            } else if (bs.len >= opts.min_samples and hs.len >= opts.min_samples) {
                const m = try stats.mannWhitneyU(arena, bs, hs);
                const worse_p = if (flip) m.p_one_sided_less else m.p_one_sided_greater;
                const better_p = if (flip) m.p_one_sided_greater else m.p_one_sided_less;
                const worse_delta = if (flip) -(out.delta_pct orelse 0) else (out.delta_pct orelse 0);
                if (worse_p < opts.alpha and worse_delta > tol) {
                    out.verdict = .regressed;
                    out.p_value = worse_p;
                } else if (better_p < opts.alpha and -worse_delta > tol) {
                    out.verdict = .improved;
                    out.p_value = better_p;
                } else out.p_value = @min(worse_p, better_p);
            } else if (out.note.len == 0) out.note = "too few samples for a verdict";
        }
    }

    // The budget, on the head value.
    if (budget) |bb| if (switch (bb.source) {
        .bench => |s| zg_perf.budget.bench_bind.extract(h, s.field),
        else => null,
    }) |v| {
        const own = bb.machine == opts.machine or zg_perf.budget.check.machineIndependent(bb);
        const e = zg_perf.budget.check.evaluateScaled(bb, v, if (own) 1 else opts.scale, 1);
        out.budget_observed = v;
        out.budget_limit = e.scaled_limit;
        if (e.verdict == .fail and out.verdict != .regressed) out.verdict = if (own) .budget_fail else .budget_warn;
    };

    if (out.gate == .block and (out.verdict == .regressed or out.verdict == .budget_fail)) {
        out.blocking = true;
        if (opts.accepted) {
            const p = try baselinePath(arena, opts.machine, suite);
            for (opts.changed_baselines) |c| if (std.mem.eql(u8, std.mem.trim(u8, c, " \r"), p)) {
                out.blocking = false;
                out.note = "accepted: the PR updates the baseline";
            };
        }
    }
    return out;
}

/// Rows that block the gate.
pub fn blockingCount(rows: []const Row) usize {
    var n: usize = 0;
    for (rows) |r| n += @intFromBool(r.blocking);
    return n;
}

// Tests.

const test_budgets = [_]Budget{
    .{ .id = "t.fast", .owner = "E14", .spec = "E14", .metric = .duration_ns, .stat = .p50, .limit = 1000, .machine = .ci_linux_x64, .source = .{ .bench = .{ .suite = "zg_t", .name = "fast", .field = .p50_ns } } },
    .{ .id = "t.rate", .owner = "E14", .spec = "E14", .metric = .per_second, .stat = .mean, .direction = .higher_is_better, .limit = 1, .machine = .ci_linux_x64, .source = .{ .bench = .{ .suite = "zg_t", .name = "rate", .field = .ns_per_op } } },
};

fn lognormalSamples(r: std.Random, out: []f64, center: f64, sigma: f64) void {
    for (out) |*o| {
        // Box-Muller.
        const uu1 = @max(r.float(f64), 1e-12);
        const uu2 = r.float(f64);
        const z = @sqrt(-2 * @log(uu1)) * @cos(2 * std.math.pi * uu2);
        o.* = center * @exp(sigma * z);
    }
}

fn set1(arena: std.mem.Allocator, name: []const u8, samples: []const f64, allocs: f64) !baseline.Set {
    const res = try arena.alloc(baseline.BenchResult, 1);
    const med = try stats.median(arena, samples);
    res[0] = .{ .name = name, .iters = samples.len, .ns_per_op = med, .p50_ns = med, .p99_ns = med, .allocs_per_op = allocs, .bytes_alloc_per_op = allocs * 32, .samples_ns = try arena.dupe(f64, samples) };
    const files = try arena.alloc(baseline.BenchFile, 1);
    files[0] = .{ .schema = 1, .package = "zg_t", .zig = "0.16.0", .target = "x86_64-linux", .optimize = "ReleaseFast", .results = res };
    return .{ .files = files };
}

test "compare: injected 15 % regression flagged" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(42);
    var bs: [7]f64 = undefined;
    var hs: [7]f64 = undefined;
    lognormalSamples(prng.random(), &bs, 500, 0.02);
    lognormalSamples(prng.random(), &hs, 575, 0.02);
    const rows = try compare(a, try set1(a, "fast", &bs, 0), try set1(a, "fast", &hs, 0), .{ .budgets = &test_budgets });
    try std.testing.expectEqual(Verdict.regressed, rows[0].verdict);
    try std.testing.expect(rows[0].blocking);
    try std.testing.expectEqual(@as(usize, 1), blockingCount(rows));
    // The other way round is an improvement.
    const rev = try compare(a, try set1(a, "fast", &hs, 0), try set1(a, "fast", &bs, 0), .{ .budgets = &test_budgets });
    try std.testing.expectEqual(Verdict.improved, rev[0].verdict);
}

test "compare: A/A random noise false-positive rate" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(7);
    var fp: u32 = 0;
    for (0..1000) |_| {
        var bs: [5]f64 = undefined;
        var hs: [5]f64 = undefined;
        lognormalSamples(prng.random(), &bs, 500, 0.05);
        lognormalSamples(prng.random(), &hs, 500, 0.05);
        const rows = try compare(a, try set1(a, "fast", &bs, 0), try set1(a, "fast", &hs, 0), .{ .budgets = &test_budgets });
        fp += @intFromBool(rows[0].verdict == .regressed);
    }
    try std.testing.expect(fp <= 15);
}

test "compare: alloc regression deterministic" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = [_]f64{ 500, 501, 499, 500, 502 };
    const base = try set1(a, "fast", &s, 2);
    const head = try set1(a, "fast", &s, 3);
    const bl = try baseline.fromSet(a, base, "ci_linux_x64");
    const rows = try compare(a, base, head, .{ .budgets = &test_budgets, .baselines = .{ .files = bl } });
    try std.testing.expectEqual(Verdict.regressed, rows[0].verdict);
    try std.testing.expect(rows[0].blocking);
}

test "compare: accepted with baseline change passes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = [_]f64{ 500, 501, 499, 500, 502 };
    const base = try set1(a, "fast", &s, 2);
    const head = try set1(a, "fast", &s, 3);
    const bl = try baseline.fromSet(a, base, "ci_linux_x64");
    // Label alone is not enough.
    const label_only = try compare(a, base, head, .{ .budgets = &test_budgets, .baselines = .{ .files = bl }, .accepted = true });
    try std.testing.expect(label_only[0].blocking);
    const rows = try compare(a, base, head, .{ .budgets = &test_budgets, .baselines = .{ .files = bl }, .accepted = true, .changed_baselines = &.{"perf/baselines/ci_linux_x64/zg_t.json"} });
    try std.testing.expectEqual(Verdict.regressed, rows[0].verdict);
    try std.testing.expect(!rows[0].blocking);
}

test "compare: higher-is-better throughput" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Samples are the rate itself: dropping 20 % is the regression.
    const bs = [_]f64{ 100, 101, 99, 100, 102, 100 };
    const hs = [_]f64{ 80, 81, 79, 80, 82, 80 };
    const rows = try compare(a, try set1(a, "rate", &bs, 0), try set1(a, "rate", &hs, 0), .{ .budgets = &test_budgets });
    try std.testing.expectEqual(Verdict.regressed, rows[0].verdict);
    const up = try compare(a, try set1(a, "rate", &hs, 0), try set1(a, "rate", &bs, 0), .{ .budgets = &test_budgets });
    try std.testing.expectEqual(Verdict.improved, up[0].verdict);
}

test "compare: budgets, missing rows and single samples" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const slow = [_]f64{ 2000, 2001, 1999, 2000, 2002 };
    const rows = try compare(a, try set1(a, "fast", &slow, 0), try set1(a, "fast", &slow, 0), .{ .budgets = &test_budgets });
    try std.testing.expectEqual(Verdict.budget_fail, rows[0].verdict);
    // On another machine class the calibration makes it advisory.
    const other = try compare(a, try set1(a, "fast", &slow, 0), try set1(a, "fast", &slow, 0), .{ .budgets = &test_budgets, .machine = .ci_windows_x64, .scale = 1.5 });
    try std.testing.expectEqual(Verdict.budget_warn, other[0].verdict);
    try std.testing.expect(!other[0].blocking);
    const one = [_]f64{500};
    const gone = try compare(a, try set1(a, "fast", &one, 0), try set1(a, "other", &one, 0), .{ .budgets = &test_budgets });
    try std.testing.expectEqual(@as(usize, 2), gone.len);
    try std.testing.expectEqual(Verdict.missing, gone[1].verdict);
    try std.testing.expectEqual(Verdict.pass, gone[0].verdict);
}

test "compare: 2 000 rows under a second" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(9);
    const res = try a.alloc(baseline.BenchResult, 2000);
    for (res, 0..) |*r, i| {
        var s: [10]f64 = undefined;
        lognormalSamples(prng.random(), &s, 1000, 0.03);
        r.* = .{ .name = try std.fmt.allocPrint(a, "b{d}", .{i}), .iters = 10, .ns_per_op = 1000, .p50_ns = 1000, .p99_ns = 1000, .allocs_per_op = 0, .bytes_alloc_per_op = 0, .samples_ns = try a.dupe(f64, &s) };
    }
    const files = [_]baseline.BenchFile{.{ .schema = 1, .package = "zg_t", .zig = "0.16.0", .target = "x", .optimize = "ReleaseFast", .results = res }};
    const set: baseline.Set = .{ .files = &files };
    const io = std.testing.io;
    const t0 = std.Io.Clock.awake.now(io).nanoseconds;
    const rows = try compare(a, set, set, .{ .budgets = &test_budgets });
    const dt = std.Io.Clock.awake.now(io).nanoseconds - t0;
    try std.testing.expectEqual(@as(usize, 2000), rows.len);
    try std.testing.expect(dt < std.time.ns_per_s);
}
