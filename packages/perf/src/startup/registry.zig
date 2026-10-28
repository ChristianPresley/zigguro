//! `InitRegistry` (E14.F05.S01.T02): named services with a phase and
//! dependencies.
//!
//! - `critical` services run in dependency order on the calling (UI)
//!   thread before the first frame. Ones flagged `parallel_ok` start on a
//!   worker instead, and anything that depends on them waits for them.
//! - `after_first_frame` services run on one worker once
//!   `scheduleDeferred` is called (at the first presented frame), highest
//!   priority first.
//! - `idle` services run after those, once the activity signal reads idle.
//! - `on_demand` services run only through `ensure`.
//!
//! Every run is timed (`timings`, by name) and traced as the zone
//! `init.service`.
//! In `dry_run` mode nothing runs; the startup allowlist test uses it to
//! read the app's critical path.

const std = @import("std");
const zg_core = @import("zg_core");
const activity = @import("../runtime/activity.zig");

const log = std.log.scoped(.zg_perf_startup);

pub const InitPhase = enum { critical, after_first_frame, idle, on_demand };

pub const InitFn = *const fn (ctx: ?*anyopaque, io: std.Io) anyerror!void;

/// One service run.
pub const InitTiming = struct {
    name: []const u8,
    phase: InitPhase,
    start_ns: u64,
    dur_ns: u64,
    thread: enum { ui, worker },
    failed: bool = false,
};

/// A service registration.
pub const Service = struct {
    name: []const u8,
    phase: InitPhase,
    deps: []const []const u8 = &.{},
    ctx: ?*anyopaque = null,
    f: ?InitFn = null,
    /// Critical services: may run on a worker alongside the UI thread.
    parallel_ok: bool = false,
    /// Deferred services: higher runs first.
    priority: i32 = 0,
};

const State = enum(u8) { pending, running, done, failed };

pub const InitRegistry = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dry_run: bool = false,
    services: std.ArrayList(Service) = .empty,
    states: std.ArrayList(std.atomic.Value(State)) = .empty,
    timing_list: std.ArrayList(InitTiming) = .empty,
    /// Guards `timing_list` and `ensure` bookkeeping.
    mutex: std.Io.Mutex = .init,
    group: std.Io.Group = .init,
    /// The idle signal (the process's by default; tests pass their own).
    signal: *activity.ActivitySignal = &activity.global,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) InitRegistry {
        return .{ .gpa = gpa, .io = io };
    }

    /// Waits for deferred work and frees the registry.
    pub fn deinit(r: *InitRegistry) void {
        r.group.cancel(r.io);
        r.services.deinit(r.gpa);
        r.states.deinit(r.gpa);
        r.timing_list.deinit(r.gpa);
    }

    /// Adds a service. Names are unique.
    pub fn register(r: *InitRegistry, s: Service) !void {
        if (r.find(s.name) != null) return error.DuplicateService;
        try r.services.append(r.gpa, s);
        try r.states.append(r.gpa, .init(.pending));
    }

    pub fn find(r: *const InitRegistry, name: []const u8) ?usize {
        for (r.services.items, 0..) |s, i| if (std.mem.eql(u8, s.name, name)) return i;
        return null;
    }

    /// Indices of `phase`'s services in dependency order (Kahn), ties by
    /// priority then registration. Dependencies outside `phase` must be
    /// in an earlier phase. A cycle is an error naming its services.
    pub fn order(r: *const InitRegistry, gpa: std.mem.Allocator, phase: InitPhase) ![]usize {
        const n = r.services.items.len;
        var indeg = try gpa.alloc(u32, n);
        defer gpa.free(indeg);
        @memset(indeg, 0);
        for (r.services.items, 0..) |s, i| {
            if (s.phase != phase) continue;
            for (s.deps) |d| {
                const j = r.find(d) orelse {
                    log.warn("service {s} depends on unknown {s}", .{ s.name, d });
                    return error.UnknownDependency;
                };
                const dp = r.services.items[j].phase;
                if (dp == phase) {
                    indeg[i] += 1;
                } else if (@intFromEnum(dp) > @intFromEnum(phase)) {
                    log.warn("{t} service {s} depends on later {t} service {s}", .{ phase, s.name, dp, d });
                    return error.DependencyOnLaterPhase;
                }
            }
        }
        var out: std.ArrayList(usize) = .empty;
        errdefer out.deinit(gpa);
        var used = try gpa.alloc(bool, n);
        defer gpa.free(used);
        @memset(used, false);
        var count: usize = 0;
        for (r.services.items) |s| count += @intFromBool(s.phase == phase);
        while (out.items.len < count) {
            // The ready service with the highest priority.
            var best: ?usize = null;
            for (r.services.items, 0..) |s, i| {
                if (s.phase != phase or used[i] or indeg[i] != 0) continue;
                if (best == null or s.priority > r.services.items[best.?].priority) best = i;
            }
            const b = best orelse {
                var names: [256]u8 = undefined;
                var w: std.Io.Writer = .fixed(&names);
                for (r.services.items, 0..) |s, i| if (s.phase == phase and !used[i]) w.print(" {s}", .{s.name}) catch {};
                log.warn("init dependency cycle among:{s}", .{w.buffered()});
                return error.DependencyCycle;
            };
            used[b] = true;
            try out.append(gpa, b);
            const bn = r.services.items[b].name;
            for (r.services.items, 0..) |s, i| {
                if (s.phase != phase or used[i]) continue;
                for (s.deps) |d| if (std.mem.eql(u8, d, bn)) {
                    indeg[i] -= 1;
                };
            }
        }
        return out.toOwnedSlice(gpa);
    }

    fn runOne(r: *InitRegistry, i: usize, thread: @FieldType(InitTiming, "thread")) void {
        const s = r.services.items[i];
        const st = &r.states.items[i];
        if (st.cmpxchgStrong(.pending, .running, .acq_rel, .acquire) != null) return;
        const t0 = zg_core.time.nowNs(r.io);
        var ok = true;
        if (!r.dry_run) if (s.f) |f| {
            // One zone for all services; `timings` names them.
            const zone = zg_core.trace.zone(@src(), "init.service");
            defer zone.end();
            f(s.ctx, r.io) catch |e| {
                log.err("init {s} failed: {t}", .{ s.name, e });
                ok = false;
            };
        };
        const dur = zg_core.time.nowNs(r.io) -| t0;
        st.store(if (ok) .done else .failed, .release);
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.timing_list.append(r.gpa, .{ .name = s.name, .phase = s.phase, .start_ns = t0, .dur_ns = dur, .thread = thread, .failed = !ok }) catch {};
    }

    fn parallelTask(r: *InitRegistry, i: usize) std.Io.Cancelable!void {
        r.runOne(i, .worker);
    }

    /// Runs the critical services; returns once all finished.
    pub fn runCritical(r: *InitRegistry) !void {
        const ord = try r.order(r.gpa, .critical);
        defer r.gpa.free(ord);
        var par: std.Io.Group = .init;
        var par_running = false;
        defer par.await(r.io) catch {};
        for (ord) |i| {
            const s = r.services.items[i];
            // Wait for parallel services this one depends on.
            if (par_running) for (s.deps) |d| {
                const j = r.find(d).?;
                const st = r.states.items[j].load(.acquire);
                if (r.services.items[j].parallel_ok and st != .done and st != .failed) {
                    par.await(r.io) catch {};
                    par_running = false;
                    break;
                }
            };
            if (s.parallel_ok and !r.dry_run) {
                par.concurrent(r.io, parallelTask, .{ r, i }) catch {
                    r.runOne(i, .ui);
                    continue;
                };
                par_running = true;
            } else r.runOne(i, .ui);
        }
    }

    /// Starts the deferred services on a worker: `after_first_frame` now,
    /// `idle` once the activity signal reads idle. Call at the first
    /// presented frame.
    pub fn scheduleDeferred(r: *InitRegistry) void {
        r.group.concurrent(r.io, deferredTask, .{r}) catch {
            log.info("no concurrency: deferred services run inline", .{});
            r.deferredTask() catch {};
        };
    }

    fn deferredTask(r: *InitRegistry) std.Io.Cancelable!void {
        if (r.order(r.gpa, .after_first_frame)) |ord| {
            defer r.gpa.free(ord);
            for (ord) |i| r.runOne(i, .worker);
        } else |_| {}
        const idle_ord = r.order(r.gpa, .idle) catch return;
        defer r.gpa.free(idle_ord);
        if (idle_ord.len == 0) return;
        while (r.signal.level() != .idle) {
            r.signal.waitUntilNot(r.io, r.signal.level(), null) catch |e| switch (e) {
                error.Timeout => {},
                error.Canceled => return error.Canceled,
            };
        }
        for (idle_ord) |i| r.runOne(i, .worker);
    }

    /// Runs an `on_demand` service (and pending dependencies) on a worker.
    pub fn ensure(r: *InitRegistry, name: []const u8) void {
        const i = r.find(name) orelse return;
        if (r.states.items[i].load(.acquire) != .pending) return;
        r.group.concurrent(r.io, ensureTask, .{ r, i }) catch r.runWithDeps(i, 0);
    }

    fn ensureTask(r: *InitRegistry, i: usize) std.Io.Cancelable!void {
        r.runWithDeps(i, 0);
    }

    fn runWithDeps(r: *InitRegistry, i: usize, depth: u32) void {
        if (depth > 32) return;
        for (r.services.items[i].deps) |d| if (r.find(d)) |j| r.runWithDeps(j, depth + 1);
        r.runOne(i, .worker);
    }

    /// Runs so far (copy; caller frees).
    pub fn timings(r: *InitRegistry, gpa: std.mem.Allocator) ![]InitTiming {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        return gpa.dupe(InitTiming, r.timing_list.items);
    }

    /// Whether `name` finished.
    pub fn isDone(r: *const InitRegistry, name: []const u8) bool {
        const i = r.find(name) orelse return false;
        return r.states.items[i].load(.acquire) == .done;
    }

    /// Names of the critical services (the allowlist test).
    pub fn criticalNames(r: *const InitRegistry, gpa: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (r.services.items) |s| if (s.phase == .critical) try out.append(gpa, s.name);
        return out.toOwnedSlice(gpa);
    }
};

const Recorder = struct {
    var log_buf: [16][]const u8 = undefined;
    var n: std.atomic.Value(usize) = .init(0);
    fn reset() void {
        n.store(0, .monotonic);
    }
    fn names() []const []const u8 {
        return log_buf[0..n.load(.acquire)];
    }
    fn run(ctx: ?*anyopaque, _: std.Io) anyerror!void {
        const name: *const []const u8 = @ptrCast(@alignCast(ctx.?));
        log_buf[n.fetchAdd(1, .acq_rel)] = name.*;
    }
};

fn svc(comptime name: []const u8, phase: InitPhase, deps: []const []const u8) Service {
    const S = struct {
        const n: []const u8 = name;
    };
    return .{ .name = name, .phase = phase, .deps = deps, .ctx = @ptrCast(@constCast(&S.n)), .f = Recorder.run };
}

test "registry: topo order and cycle detection" {
    var r: InitRegistry = .init(std.testing.allocator, std.testing.io);
    defer r.deinit();
    try r.register(svc("workbench", .critical, &.{ "window", "config" }));
    try r.register(svc("window", .critical, &.{"platform"}));
    try r.register(svc("platform", .critical, &.{}));
    try r.register(svc("config", .critical, &.{}));
    Recorder.reset();
    try r.runCritical();
    const got = Recorder.names();
    try std.testing.expectEqual(@as(usize, 4), got.len);
    const pos = struct {
        fn f(xs: []const []const u8, x: []const u8) usize {
            for (xs, 0..) |y, i| if (std.mem.eql(u8, x, y)) return i;
            unreachable;
        }
    }.f;
    try std.testing.expect(pos(got, "platform") < pos(got, "window"));
    try std.testing.expect(pos(got, "window") < pos(got, "workbench"));
    try std.testing.expect(pos(got, "config") < pos(got, "workbench"));

    var c: InitRegistry = .init(std.testing.allocator, std.testing.io);
    defer c.deinit();
    try c.register(svc("a", .critical, &.{"b"}));
    try c.register(svc("b", .critical, &.{"a"}));
    try std.testing.expectError(error.DependencyCycle, c.runCritical());
    try std.testing.expectError(error.DuplicateService, c.register(svc("a", .idle, &.{})));
    var l: InitRegistry = .init(std.testing.allocator, std.testing.io);
    defer l.deinit();
    try l.register(svc("early", .critical, &.{"late"}));
    try l.register(svc("late", .idle, &.{}));
    try std.testing.expectError(error.DependencyOnLaterPhase, l.runCritical());
}

test "registry: deferred runs after first frame only" {
    var r: InitRegistry = .init(std.testing.allocator, std.testing.io);
    defer r.deinit();
    var sig: activity.ActivitySignal = .{};
    sig.install(std.testing.io);
    r.signal = &sig;
    try r.register(svc("ui", .critical, &.{}));
    try r.register(svc("lsp registry", .after_first_frame, &.{"ui"}));
    try r.register(svc("debugger", .on_demand, &.{}));
    Recorder.reset();
    try r.runCritical();
    try std.testing.expect(!r.isDone("lsp registry"));
    r.scheduleDeferred();
    var waited: u32 = 0;
    while (!r.isDone("lsp registry") and waited < 200) : (waited += 1) try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    try std.testing.expect(r.isDone("lsp registry"));
    try std.testing.expect(!r.isDone("debugger"));
    r.ensure("debugger");
    waited = 0;
    while (!r.isDone("debugger") and waited < 200) : (waited += 1) try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    try std.testing.expect(r.isDone("debugger"));
    const t = try r.timings(std.testing.allocator);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqual(@as(usize, 3), t.len);
    try std.testing.expect(t[0].thread == .ui and t[1].thread == .worker);
}

test "registry: idle waits for activity idle" {
    var r: InitRegistry = .init(std.testing.allocator, std.testing.io);
    defer r.deinit();
    var sig: activity.ActivitySignal = .{};
    sig.install(std.testing.io);
    r.signal = &sig;
    // Input just now: interactive for 2 s.
    sig.publish(.interactive, zg_core.time.nowNs(std.testing.io));
    try r.register(svc("trigram index", .idle, &.{}));
    r.scheduleDeferred();
    try std.testing.io.sleep(.fromMilliseconds(50), .awake);
    try std.testing.expect(!r.isDone("trigram index"));
    // Input long ago: idle.
    sig.publish(.interactive, 1);
    sig.publish(.idle, 1);
    var waited: u32 = 0;
    while (!r.isDone("trigram index") and waited < 600) : (waited += 1) try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    try std.testing.expect(r.isDone("trigram index"));
}

test "registry: parallel_ok overlaps" {
    const Sleep = struct {
        fn run(_: ?*anyopaque, io: std.Io) anyerror!void {
            try io.sleep(.fromMilliseconds(40), .awake);
        }
    };
    var r: InitRegistry = .init(std.testing.allocator, std.testing.io);
    defer r.deinit();
    try r.register(.{ .name = "gpu", .phase = .critical, .f = Sleep.run, .parallel_ok = true });
    try r.register(.{ .name = "window", .phase = .critical, .f = Sleep.run });
    try r.register(.{ .name = "first frame", .phase = .critical, .deps = &.{ "gpu", "window" } });
    const t0 = zg_core.time.nowNs(std.testing.io);
    try r.runCritical();
    const dt = zg_core.time.nowNs(std.testing.io) - t0;
    try std.testing.expect(r.isDone("first frame"));
    try std.testing.expect(r.isDone("gpu"));
    // Sequential would take 80 ms.
    try std.testing.expect(dt < 75 * std.time.ns_per_ms);
}
