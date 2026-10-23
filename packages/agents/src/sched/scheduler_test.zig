//! The scheduler with a fake clock and a fake runner: `poll` is driven by
//! hand, so every case is deterministic. One case runs the real loop.

const std = @import("std");
const runs = @import("../runs/root.zig");
const zone = @import("zone.zig");
const auto = @import("automation.zig");
const history = @import("history.zig");
const state = @import("state.zig");
const Scheduler = @import("scheduler.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const Automation = auto.Automation;

const FakeClock = struct {
    ms: i64,

    fn clock(c: *FakeClock) Scheduler.Clock {
        return .{ .ctx = c, .nowRealMs = now };
    }

    fn now(ctx: ?*anyopaque) i64 {
        const c: *FakeClock = @ptrCast(@alignCast(ctx.?));
        return c.ms;
    }
};

const FakeRunner = struct {
    fires: std.ArrayList(Scheduler.FireRequest) = .empty,
    payloads: std.ArrayList(?[]const u8) = .empty,
    running: bool = false,
    stops: u32 = 0,
    cost: u64 = 0,
    warnings: u32 = 0,
    fail: bool = false,

    fn iface(r: *FakeRunner) Scheduler.RunnerIface {
        return .{ .ctx = r, .vtable = &vt };
    }

    const vt: Scheduler.RunnerIface.VTable = .{ .fire = fire, .isRunning = isRunning, .stopRunning = stopRunning, .monthCostMicros = monthCost, .warn = warn };

    fn fire(ctx: *anyopaque, _: *const Automation, req: Scheduler.FireRequest, payload: ?[]const u8) anyerror!?runs.RunId {
        const r: *FakeRunner = @ptrCast(@alignCast(ctx));
        if (r.fail) return error.Boom;
        try r.fires.append(gpa, req);
        try r.payloads.append(gpa, payload);
        return .fromInt(r.fires.items.len);
    }
    fn isRunning(ctx: *anyopaque, _: []const u8) bool {
        const r: *FakeRunner = @ptrCast(@alignCast(ctx));
        return r.running;
    }
    fn stopRunning(ctx: *anyopaque, _: []const u8) void {
        const r: *FakeRunner = @ptrCast(@alignCast(ctx));
        r.stops += 1;
        r.running = false;
    }
    fn monthCost(ctx: *anyopaque, _: []const u8) u64 {
        const r: *FakeRunner = @ptrCast(@alignCast(ctx));
        return r.cost;
    }
    fn warn(ctx: *anyopaque, _: []const u8, _: []const u8) void {
        const r: *FakeRunner = @ptrCast(@alignCast(ctx));
        r.warnings += 1;
    }

    fn deinit(r: *FakeRunner) void {
        r.fires.deinit(gpa);
        r.payloads.deinit(gpa);
    }
};

const minute = std.time.ms_per_min;
/// 2026-10-23 08:00:00 UTC.
const t0: i64 = 1_792_742_400_000;

fn every(name: []const u8, comptime expr: []const u8) Automation {
    return .{
        .name = name,
        .triggers = &.{.{ .schedule = .{ .cron = expr, .jitter_s = 0 } }},
        .action = .{ .agent = .{ .prompt = "hi" } },
        .budgets = .{ .max_cost_micro_usd = 1000 },
    };
}

const Fx = struct {
    tmp: testing.TmpDir,
    hist: std.Io.Dir,
    clock: FakeClock = .{ .ms = t0 },
    runner: FakeRunner = .{},
    s: *Scheduler = undefined,

    fn init(f: *Fx, o: Scheduler.Options) !void {
        f.* = .{ .tmp = testing.tmpDir(.{}), .hist = undefined };
        f.hist = try f.tmp.dir.createDirPathOpen(io, "hist", .{});
        var opts = o;
        opts.clock = f.clock.clock();
        f.s = try Scheduler.init(gpa, io, zone.utcZone(), f.tmp.dir, f.hist, f.runner.iface(), opts);
    }

    fn deinit(f: *Fx) void {
        f.s.deinit();
        f.runner.deinit();
        f.hist.close(io);
        f.tmp.cleanup();
    }

    fn at(f: *Fx, ms: i64) i64 {
        f.clock.ms = ms;
        return f.s.poll();
    }

    fn records(f: *Fx, arena: std.mem.Allocator, name: []const u8) ![]history.Record {
        return history.readTail(arena, io, f.hist, name, 1000);
    }
};

test "fires_at_due_time_once" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    try f.s.setAutomations(&.{every("tick", "*/5 * * * *")});
    // 08:00 exactly is not after now: the first due is 08:05.
    const sleep = f.at(t0 + 1000);
    try testing.expectEqual(@as(i64, 60_000), sleep);
    try testing.expectEqual(@as(i64, 60_000), f.at(t0 + minute));
    try testing.expectEqual(minute, f.at(t0 + 4 * minute));
    _ = f.at(t0 + 5 * minute - 1);
    try testing.expectEqual(@as(usize, 0), f.runner.fires.items.len);
    _ = f.at(t0 + 5 * minute + 200);
    _ = f.at(t0 + 5 * minute + 400);
    try testing.expectEqual(@as(usize, 1), f.runner.fires.items.len);
    const r = f.runner.fires.items[0];
    try testing.expectEqual(t0 + 5 * minute, r.due_unix_ms);
    try testing.expectEqual(Scheduler.FireReason.scheduled, r.reason);
    try testing.expectEqual(@as(u64, 1), r.fire_id);
    var out: [3]i64 = undefined;
    try testing.expectEqual(@as(usize, 3), f.s.nextFires("tick", &out));
    try testing.expectEqual(t0 + 10 * minute, out[0]);
    try testing.expectEqual(t0 + 20 * minute, out[2]);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const recs = try f.records(arena.allocator(), "tick");
    try testing.expectEqual(@as(usize, 1), recs.len);
    try testing.expect(recs[0].run.?.eql(.fromInt(1)));
}

test "wall_clock_jump_forward_backward" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    try f.s.setAutomations(&.{every("tick", "* * * * *")});
    _ = f.at(t0 + 1 * minute + 10);
    try testing.expectEqual(@as(usize, 1), f.runner.fires.items.len);
    // Back 30 s: 08:01 is not fired again.
    _ = f.at(t0 + 1 * minute - 30_000);
    _ = f.at(t0 + 1 * minute + 20);
    try testing.expectEqual(@as(usize, 1), f.runner.fires.items.len);
    // Forward within the grace: the 08:02 fire runs as scheduled.
    _ = f.at(t0 + 2 * minute + 50_000);
    try testing.expectEqual(@as(usize, 2), f.runner.fires.items.len);
    try testing.expectEqual(Scheduler.FireReason.scheduled, f.runner.fires.items[1].reason);
    // Forward two hours: one catch-up for the latest, no burst.
    _ = f.at(t0 + 122 * minute + 5_000);
    try testing.expectEqual(@as(usize, 3), f.runner.fires.items.len);
    try testing.expectEqual(Scheduler.FireReason.catch_up, f.runner.fires.items[2].reason);
    try testing.expectEqual(t0 + 122 * minute, f.runner.fires.items[2].due_unix_ms);
    // Back three hours: the schedule restarts from the new time.
    _ = f.at(t0 - 58 * minute + 1000);
    try testing.expectEqual(@as(usize, 3), f.runner.fires.items.len);
    _ = f.at(t0 - 57 * minute + 1000);
    try testing.expectEqual(@as(usize, 4), f.runner.fires.items.len);
}

test "suspend_resume_catch_up_latest_only" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    try f.s.setAutomations(&.{every("hourly", "0 * * * *")});
    // Asleep from 08:30 to 11:30: 09:00, 10:00 and 11:00 were missed.
    _ = f.at(t0 + 30 * minute);
    _ = f.at(t0 + 210 * minute);
    try testing.expectEqual(@as(usize, 1), f.runner.fires.items.len);
    try testing.expectEqual(Scheduler.FireReason.catch_up, f.runner.fires.items[0].reason);
    try testing.expectEqual(t0 + 180 * minute, f.runner.fires.items[0].due_unix_ms);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const recs = try f.records(arena.allocator(), "hourly");
    try testing.expectEqual(@as(usize, 3), recs.len);
    try testing.expectEqual(history.Skip.asleep_discarded, recs[0].skip.?);
    try testing.expectEqual(t0 + 60 * minute, recs[0].due);
    try testing.expectEqual(history.Skip.asleep_discarded, recs[1].skip.?);
    try testing.expect(recs[2].skip == null and recs[2].run != null);
    // The next one is 12:00.
    var next: [1]i64 = undefined;
    try testing.expectEqual(@as(usize, 1), f.s.nextFires("hourly", &next));
    try testing.expectEqual(t0 + 240 * minute, next[0]);
    // catch_up = none: nothing runs after a sleep.
    var a = every("hourly", "0 * * * *");
    a.catch_up = .none;
    a.description = "changed";
    try f.s.setAutomations(&.{a});
    _ = f.at(t0 + 400 * minute);
    try testing.expectEqual(@as(usize, 1), f.runner.fires.items.len);
}

test "app_closed_catch_up_from_state" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    try f.s.setAutomations(&.{every("daily", "0 9 * * *")});
    _ = f.at(t0 + 60 * minute + 1);
    try testing.expectEqual(@as(usize, 1), f.runner.fires.items.len);
    f.s.deinit();
    // Reopened two days later: one catch-up.
    f.clock.ms = t0 + 2 * std.time.ms_per_day + 120 * minute;
    f.s = try Scheduler.init(gpa, io, zone.utcZone(), f.tmp.dir, f.hist, f.runner.iface(), .{ .clock = f.clock.clock() });
    try f.s.setAutomations(&.{every("daily", "0 9 * * *")});
    _ = f.s.poll();
    try testing.expectEqual(@as(usize, 2), f.runner.fires.items.len);
    try testing.expectEqual(Scheduler.FireReason.catch_up, f.runner.fires.items[1].reason);
    try testing.expectEqual(t0 + 2 * std.time.ms_per_day + 60 * minute, f.runner.fires.items[1].due_unix_ms);
    // Fire ids continue.
    try testing.expectEqual(@as(u64, 2), f.runner.fires.items[1].fire_id);
}

test "overlap_skip_queue_replace" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    var a = every("job", "* * * * *");
    f.runner.running = true;
    try f.s.setAutomations(&.{a});
    _ = f.at(t0 + minute);
    try testing.expectEqual(@as(usize, 0), f.runner.fires.items.len);
    // Queue: held until the run ends.
    a.overlap = .queue;
    try f.s.setAutomations(&.{a});
    _ = f.at(t0 + 2 * minute);
    _ = f.at(t0 + 3 * minute);
    try testing.expectEqual(@as(usize, 0), f.runner.fires.items.len);
    f.runner.running = false;
    _ = f.at(t0 + 3 * minute + 500);
    try testing.expectEqual(@as(usize, 1), f.runner.fires.items.len);
    // The newest waiting fire went; the older one gave way.
    try testing.expectEqual(t0 + 3 * minute, f.runner.fires.items[0].due_unix_ms);
    // Replace: the old run is stopped and the new one starts.
    a.overlap = .replace;
    try f.s.setAutomations(&.{a});
    f.runner.running = true;
    _ = f.at(t0 + 4 * minute);
    try testing.expectEqual(@as(u32, 1), f.runner.stops);
    try testing.expectEqual(@as(usize, 2), f.runner.fires.items.len);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var overlaps: usize = 0;
    for (try f.records(arena.allocator(), "job")) |r| {
        if (r.skip == .overlap) overlaps += 1;
    }
    try testing.expectEqual(@as(usize, 2), overlaps);
}

test "rate_limit_window" {
    var f: Fx = undefined;
    try f.init(.{ .global_max_runs_per_hour = 5 });
    defer f.deinit();
    var a = every("busy", "* * * * *");
    a.max_runs_per_hour = 3;
    try f.s.setAutomations(&.{ a, every("other", "* * * * *") });
    var m: i64 = 1;
    while (m <= 10) : (m += 1) _ = f.at(t0 + m * minute);
    var busy: usize = 0;
    for (f.runner.fires.items) |r| {
        if (std.mem.eql(u8, r.automation, "busy")) busy += 1;
    }
    try testing.expectEqual(@as(usize, 3), busy);
    // Global cap: 5 in the hour.
    try testing.expectEqual(@as(usize, 5), f.runner.fires.items.len);
    // An hour later the window has moved on.
    _ = f.at(t0 + 62 * minute);
    try testing.expectEqual(@as(usize, 7), f.runner.fires.items.len);
}

test "budget_exhausted_skips_and_warns_once" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    var a = every("pricey", "* * * * *");
    a.budgets.monthly_cap_micro_usd = 100;
    f.runner.cost = 100;
    try f.s.setAutomations(&.{a});
    _ = f.at(t0 + minute);
    _ = f.at(t0 + 2 * minute);
    try testing.expectEqual(@as(usize, 0), f.runner.fires.items.len);
    try testing.expectEqual(@as(u32, 1), f.runner.warnings);
}

test "lease_only_one_fires" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // One state dir (and lock file), as two processes would share it.
    const d1 = tmp.dir;
    const d2 = tmp.dir;
    var clock: FakeClock = .{ .ms = t0 };
    var r1: FakeRunner = .{};
    var r2: FakeRunner = .{};
    defer r1.deinit();
    defer r2.deinit();
    const s1 = try Scheduler.init(gpa, io, zone.utcZone(), d1, null, r1.iface(), .{ .clock = clock.clock() });
    var s1_live = true;
    defer if (s1_live) s1.deinit();
    const s2 = try Scheduler.init(gpa, io, zone.utcZone(), d2, null, r2.iface(), .{ .clock = clock.clock() });
    defer s2.deinit();
    try s1.setAutomations(&.{every("tick", "* * * * *")});
    try s2.setAutomations(&.{every("tick", "* * * * *")});
    var m: i64 = 1;
    while (m <= 3) : (m += 1) {
        clock.ms = t0 + m * minute;
        _ = s1.poll();
        // Without the lease it waits for the retry interval.
        try testing.expect(s2.poll() <= 30_000);
    }
    try testing.expectEqual(@as(usize, 3), r1.fires.items.len);
    try testing.expectEqual(@as(usize, 0), r2.fires.items.len);
    try testing.expect(s1.leased() and !s2.leased());
    s1.deinit();
    s1_live = false;
    // The next retry takes over.
    clock.ms = t0 + 4 * minute;
    _ = s2.poll();
    try testing.expect(s2.leased());
    try testing.expectEqual(@as(usize, 1), r2.fires.items.len);
}

test "set_automations_wakes_loop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var r: FakeRunner = .{};
    defer r.deinit();
    const s = try Scheduler.init(gpa, io, zone.utcZone(), tmp.dir, null, r.iface(), .{});
    defer s.deinit();
    try s.start();
    // The loop is asleep for up to a minute; a new automation wakes it.
    try io.sleep(.fromMilliseconds(50), .awake);
    const before = s.wakeups.load(.monotonic);
    try s.setAutomations(&.{every("x", "0 0 1 1 *")});
    var i: u32 = 0;
    while (s.wakeups.load(.monotonic) == before and i < 400) : (i += 1) try io.sleep(.fromMilliseconds(5), .awake);
    try testing.expect(s.wakeups.load(.monotonic) > before);
    s.stop();
}

test "idle_wakeups_bounded" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    // 100 automations, none due in the next hour: a 60 s sanity tick.
    var list: [100]Automation = undefined;
    var names: [100][8]u8 = undefined;
    for (&list, 0..) |*a, i| a.* = every(std.fmt.bufPrint(&names[i], "a{d}", .{i}) catch unreachable, "0 3 * * *");
    try f.s.setAutomations(&list);
    var t = t0;
    var wakes: u32 = 0;
    while (t < t0 + std.time.ms_per_hour) : (wakes += 1) t += f.at(t);
    try testing.expect(wakes <= 61);
    try testing.expectEqual(@as(usize, 0), f.runner.fires.items.len);
}

test "once_trigger_autodisables" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    const a: Automation = .{
        .name = "remind",
        .triggers = &.{.{ .once = .{ .at = "2026-10-23 08:30" } }},
        .action = .{ .agent = .{ .prompt = "hi" } },
        .budgets = .{ .max_cost_micro_usd = 1000 },
    };
    try f.s.setAutomations(&.{a});
    try testing.expectEqual(@as(i64, 60_000), f.at(t0));
    try testing.expectEqual(@as(i64, 50_000), f.at(t0 + 29 * minute + 10_000));
    _ = f.at(t0 + 30 * minute + 10);
    _ = f.at(t0 + 90 * minute);
    try testing.expectEqual(@as(usize, 1), f.runner.fires.items.len);
    try testing.expectEqual(Scheduler.FireReason.once, f.runner.fires.items[0].reason);
    // Completed in the state: a reload does not fire it again.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const st = try state.load(arena.allocator(), io, f.tmp.dir);
    try testing.expect(state.find(st, "remind").?.completed);
    f.s.deinit();
    f.s = try Scheduler.init(gpa, io, zone.utcZone(), f.tmp.dir, f.hist, f.runner.iface(), .{ .clock = f.clock.clock() });
    try f.s.setAutomations(&.{a});
    _ = f.at(t0 + 100 * minute);
    try testing.expectEqual(@as(usize, 1), f.runner.fires.items.len);
}

test "manual and event fires share the policy" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    var a = every("ev", "0 0 1 1 *");
    a.max_chain_depth = 2;
    try f.s.setAutomations(&.{a});
    _ = f.at(t0);
    try testing.expectEqual(@as(u64, 1), try f.s.fireNow("ev"));
    try testing.expectEqual(Scheduler.FireReason.manual, f.runner.fires.items[0].reason);
    try testing.expectEqual(@as(?u64, 2), try f.s.fireEvent("ev", "{\"event\":\"files\"}", .{ .depth = 1 }));
    try testing.expectEqualStrings("{\"event\":\"files\"}", f.runner.payloads.items[1].?);
    try testing.expectEqual(@as(?u64, null), try f.s.fireEvent("ev", null, .{ .depth = 3 }));
    try testing.expectEqual(@as(u32, 1), f.runner.warnings);
    f.runner.running = true;
    try testing.expectError(error.AlreadyRunning, f.s.fireNow("ev"));
    try testing.expectEqual(@as(?u64, null), try f.s.fireEvent("ev", null, .{}));
    try testing.expectError(error.UnknownAutomation, f.s.fireNow("nope"));
    f.runner.running = false;
    a.enabled = false;
    try f.s.setAutomations(&.{a});
    try testing.expectError(error.Disabled, f.s.fireNow("ev"));
}

const ShiftedClock = struct {
    offset_ms: i64,

    fn clock(c: *ShiftedClock) Scheduler.Clock {
        return .{ .ctx = c, .nowRealMs = now };
    }

    fn real() i64 {
        return @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
    }

    fn now(ctx: ?*anyopaque) i64 {
        const c: *ShiftedClock = @ptrCast(@alignCast(ctx.?));
        return real() + c.offset_ms;
    }
};

test "realclock_fires_after_minute_boundary" {
    // The real loop and sleeps, on a clock shifted so that a minute
    // boundary is 1.5 s away.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var r: FakeRunner = .{};
    defer r.deinit();
    const real = ShiftedClock.real();
    var clock: ShiftedClock = .{ .offset_ms = (minute - @mod(real, minute)) - 1500 };
    const s = try Scheduler.init(gpa, io, zone.utcZone(), tmp.dir, null, r.iface(), .{ .clock = clock.clock() });
    defer s.deinit();
    try s.setAutomations(&.{every("tick", "* * * * *")});
    const boundary = clock.clock().nowRealMs(&clock) + 1500;
    try s.start();
    var i: u32 = 0;
    while (i < 800) : (i += 1) {
        try io.sleep(.fromMilliseconds(5), .awake);
        s.mutex.lockUncancelable(io);
        const n = r.fires.items.len;
        s.mutex.unlock(io);
        if (n > 0) break;
    }
    const fired_at = ShiftedClock.now(&clock);
    s.stop();
    try testing.expectEqual(@as(usize, 1), r.fires.items.len);
    try testing.expect(fired_at >= boundary - 50);
    // CI-tolerant: within 2 s of the boundary.
    try testing.expect(fired_at - boundary <= 2000);
}
