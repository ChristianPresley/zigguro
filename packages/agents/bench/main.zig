//! Benchmarks for zg_agents; run with `zig build bench` at the repo root.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_agents = @import("zg_agents");
const bench = zg_core.bench;

const runs = zg_agents.runs;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    try registerRuns(b);
    try registerMission(b);
    try registerNotify(b);
    try registerSched(b);
}

/// `cron/next`: the next fire time of a weekday-office-hours expression
/// in a fixed zone (budget 2 us).
fn registerSched(b: *bench.Bench) !void {
    const sched = zg_agents.sched;
    const Ctx = struct { c: sched.CronExpr, z: sched.FixedZone };
    const ctx: Ctx = .{ .c = try sched.CronExpr.parse("*/15 9-17 * * mon-fri"), .z = .{ .offset_s = 5 * 3600 + 1800 } };
    try b.run("cron/next", &ctx, struct {
        fn f(c: *const Ctx, s: *bench.State) void {
            const zr = c.z.resolver();
            var t: i64 = 1_790_000_000;
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                // Step by an odd number of minutes to land everywhere.
                t = (c.c.next(zr, t + 7 * 3600 + 13 * 60) orelse unreachable);
                bench.doNotOptimizeAway(t);
            }
        }
    }.f);
}

/// `notify/decide`: the policy and coalescing decision `post` makes
/// under its lock (budget 10 us).
fn registerNotify(b: *bench.Bench) !void {
    const notify = zg_agents.notify;
    var rt: zg_core.Runtime = undefined;
    try rt.initBorrowed(std.heap.smp_allocator, b.io, 64);
    defer _ = rt.deinit();
    const r = try notify.NotificationRouter.init(std.heap.smp_allocator, &rt, null, null, .{}, .{ .inline_delivery = true });
    defer r.deinit();
    try b.run("notify/decide", r, struct {
        fn f(router: *notify.NotificationRouter, s: *bench.State) void {
            var i: u64 = 0;
            var key: [24]u8 = undefined;
            while (i < s.iterations()) : (i += 1) {
                const n: notify.Notification = .{
                    .key = std.fmt.bufPrint(&key, "run:{d}", .{i % 512}) catch unreachable,
                    .group = if (i % 4 == 0) "wf:bench" else null,
                    .severity = .success,
                    .title = "Done",
                };
                bench.doNotOptimizeAway(router.decide(&n) catch unreachable);
            }
        }
    }.f);
}

/// `mission/open_500`: Mission Control's first frame over 500 runs (budget
/// 16 ms); `mission/stream_50`: 50 working runs each report a summary and
/// the view-model catches up (one frame; budget 1 ms).
fn registerMission(b: *bench.Bench) !void {
    const mission = zg_agents.mission;
    const Ctx = struct { reg: *runs.RunRegistry, ids: []runs.RunId, vm: *mission.MissionVM };
    const gpa = std.heap.smp_allocator;
    const io = b.io;
    const reg = try runs.RunRegistry.init(gpa, io, null, .{});
    const ids = try gpa.alloc(runs.RunId, 500);
    for (ids, 0..) |*id, i| {
        id.* = try reg.createWithId(.fromInt(@as(u128, i + 1) << 80), .{ .kind = .background, .title = "bench run", .prompt = "summarise the logs" });
        // 50 working, 30 waiting, the rest done.
        if (i < 80) {
            try reg.update(id.*, .{ .status = .starting });
            try reg.update(id.*, .{ .status = .working });
            if (i >= 50) {
                try reg.update(id.*, .{ .question = "Allow the command?" });
                try reg.update(id.*, .{ .status = .needs_input });
            }
        } else if (i % 7 != 0) {
            try reg.update(id.*, .{ .status = .starting });
            try reg.update(id.*, .{ .status = .working });
            try reg.update(id.*, .{ .summary = "Done: 3 files changed" });
            try reg.update(id.*, .{ .status = .completed });
        }
    }
    var vm: mission.MissionVM = .init(gpa);
    const ctx: Ctx = .{ .reg = reg, .ids = ids, .vm = &vm };
    try b.run("mission/open_500", ctx, struct {
        fn f(c: Ctx, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                var m: mission.MissionVM = .init(std.heap.smp_allocator);
                const v = c.reg.snapshot();
                m.apply(v, .none, 1_000) catch unreachable;
                bench.doNotOptimizeAway(m.rows().len);
                c.reg.release(v);
                m.deinit();
            }
        }
    }.f);
    {
        const v = reg.snapshot();
        try vm.apply(v, .none, 1_000);
        reg.release(v);
    }
    try b.run("mission/stream_50", ctx, struct {
        fn f(c: Ctx, s: *bench.State) void {
            var i: u64 = 0;
            var buf: [32]u8 = undefined;
            while (i < s.iterations()) : (i += 1) {
                const text = std.fmt.bufPrint(&buf, "step {d}", .{i}) catch unreachable;
                for (c.ids[0..50]) |id| c.reg.update(id, .{ .summary = text }) catch unreachable;
                const v = c.reg.snapshot();
                c.vm.apply(v, .none, @intCast(2_000 + i)) catch unreachable;
                bench.doNotOptimizeAway(c.vm.rows().len);
                c.reg.release(v);
            }
        }
    }.f);
    vm.deinit();
    reg.deinit();
    gpa.free(ids);
}

/// `runs/update_500`: one cost update (copy-on-write record + view
/// publish) with 500 runs; `runs/snapshot`: retain and release the view.
fn registerRuns(b: *bench.Bench) !void {
    const Ctx = struct { reg: *runs.RunRegistry, ids: []runs.RunId };
    const gpa = std.heap.smp_allocator;
    const io = b.io;
    const reg = try runs.RunRegistry.init(gpa, io, null, .{});
    const ids = try gpa.alloc(runs.RunId, 500);
    for (ids, 0..) |*id, i| {
        id.* = try reg.createWithId(.fromInt(@as(u128, i + 1) << 80), .{ .kind = .background, .title = "bench run", .prompt = "p" });
    }
    const ctx: Ctx = .{ .reg = reg, .ids = ids };
    try b.run("runs/update_500", ctx, struct {
        fn f(c: Ctx, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                c.reg.update(c.ids[i % c.ids.len], .{ .cost = .{ .micros = i } }) catch unreachable;
            }
        }
    }.f);
    try b.run("runs/snapshot", ctx, struct {
        fn f(c: Ctx, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                const v = c.reg.snapshot();
                bench.doNotOptimizeAway(v.runs.len);
                c.reg.release(v);
            }
        }
    }.f);
    reg.deinit();
    gpa.free(ids);
}
