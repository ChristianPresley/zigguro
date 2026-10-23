//! The automation runner (E13.F02.S01.T03): turns scheduler and trigger
//! fires into runs. A fire becomes a `RunSpec` with `origin =
//! .automation`, the automation's profile, isolation and budgets, a title
//! of "<name> · <local time>", and the prompt with its template variables
//! expanded. Trigger payloads (file lists, SCM events, task JSON) go into
//! `untrusted_payload`, never into the prompt text, except the file list
//! a prompt asks for with `{{trigger.files}}`.
//!
//! Template variables: `{{now}}` (local `YYYY-MM-DD HH:MM`), `{{date}}`
//! (`YYYY-MM-DD`), `{{last_run_at}}`, `{{last_run_summary}}` (the
//! automation's previous run), `{{trigger.files}}` (comma list) and
//! `{{trigger.event}}`. Unknown variables are left as written.

const std = @import("std");
const runs = @import("../runs/root.zig");
const zone_mod = @import("zone.zig");
const auto = @import("automation.zig");
const Scheduler = @import("scheduler.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const RunId = runs.RunId;
const RunSpec = runs.run.RunSpec;
const RunRegistry = runs.RunRegistry;
const Automation = auto.Automation;

/// Starts and stops runs (the `RunHost`, or a fake).
pub const StartPort = struct {
    ctx: *anyopaque,
    start: *const fn (ctx: *anyopaque, spec: RunSpec) anyerror!RunId,
    stop: *const fn (ctx: *anyopaque, id: RunId) void,

    pub fn fromHost(h: *runs.RunHost) StartPort {
        return .{ .ctx = h, .start = hostStart, .stop = hostStop };
    }

    fn hostStart(ctx: *anyopaque, spec: RunSpec) anyerror!RunId {
        const h: *runs.RunHost = @ptrCast(@alignCast(ctx));
        return h.start(spec);
    }

    fn hostStop(ctx: *anyopaque, id: RunId) void {
        const h: *runs.RunHost = @ptrCast(@alignCast(ctx));
        h.stop(id, .graceful);
    }
};

/// Starts a workflow run (E13.F08); null until workflows exist.
pub const WorkflowPort = struct {
    ctx: *anyopaque,
    start: *const fn (ctx: *anyopaque, action: auto.WorkflowAction, base: RunSpec) anyerror!RunId,
};

/// Shows a warning to the user (the notification router).
pub const WarnPort = struct {
    ctx: *anyopaque,
    warn: *const fn (ctx: *anyopaque, automation: []const u8, message: []const u8) void,
};

pub const Options = struct {
    workflows: ?WorkflowPort = null,
    warn: ?WarnPort = null,
    /// Wall-clock unix ms (tests); null reads the real clock.
    clock: ?Scheduler.Clock = null,
};

const AutomationRunner = @This();

gpa: Allocator,
io: Io,
reg: *RunRegistry,
starter: StartPort,
zone: zone_mod.ZoneResolver,
o: Options,

pub fn init(gpa: Allocator, io: Io, reg: *RunRegistry, starter: StartPort, z: zone_mod.ZoneResolver, o: Options) AutomationRunner {
    return .{ .gpa = gpa, .io = io, .reg = reg, .starter = starter, .zone = z, .o = o };
}

pub fn iface(r: *AutomationRunner) Scheduler.RunnerIface {
    return .{ .ctx = r, .vtable = &vtable };
}

const vtable: Scheduler.RunnerIface.VTable = .{
    .fire = fireFn,
    .isRunning = isRunningFn,
    .stopRunning = stopRunningFn,
    .monthCostMicros = monthCostFn,
    .warn = warnFn,
};

fn nowMs(r: *const AutomationRunner) i64 {
    if (r.o.clock) |c| return c.nowRealMs(c.ctx);
    return @intCast(@divFloor(Io.Clock.real.now(r.io).nanoseconds, std.time.ns_per_ms));
}

fn isAutomation(rec: *const runs.RunRecord, name: []const u8) bool {
    return switch (rec.spec.origin) {
        .automation => |a| std.mem.eql(u8, a.name, name),
        else => false,
    };
}

/// Starts the run for `req`. Returns its id.
pub fn fire(r: *AutomationRunner, a: *const Automation, req: Scheduler.FireRequest, payload: ?[]const u8) !?RunId {
    var arena: std.heap.ArenaAllocator = .init(r.gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const spec = try r.buildSpec(ar, a, req, payload);
    return switch (a.action) {
        .agent => try r.starter.start(r.starter.ctx, spec),
        .workflow => |w| if (r.o.workflows) |p| try p.start(p.ctx, w, spec) else error.WorkflowsUnavailable,
    };
}

/// The spec `fire` starts, in `arena` (public for tests and `zg
/// automation show`).
pub fn buildSpec(r: *AutomationRunner, arena: Allocator, a: *const Automation, req: Scheduler.FireRequest, payload: ?[]const u8) !RunSpec {
    const now = r.nowMs();
    const local = r.zone.toLocal(r.zone.ctx, @divFloor(now, 1000));
    var vars: Vars = .{
        .now = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ local.year, local.month, local.day, local.hour, local.minute }),
        .date = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ local.year, local.month, local.day }),
    };
    if (r.lastRun(arena, a.name)) |last| {
        const l = r.zone.toLocal(r.zone.ctx, @divFloor(last.at_ms, 1000));
        vars.last_run_at = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ l.year, l.month, l.day, l.hour, l.minute });
        vars.last_run_summary = last.summary;
    }
    if (payload) |p| payloadVars(arena, p, &vars);
    const prompt_src = switch (a.action) {
        .agent => |g| g.prompt,
        .workflow => "",
    };
    var fire_buf: [20]u8 = undefined;
    const fire_id = std.fmt.bufPrint(&fire_buf, "{d}", .{req.fire_id}) catch unreachable;
    return .{
        .kind = if (req.reason == .triggered) .triggered else .scheduled,
        .title = try std.fmt.allocPrint(arena, "{s} · {s}", .{ a.name, vars.now }),
        .prompt = try expand(arena, prompt_src, &vars),
        .agent_def = switch (a.action) {
            .agent => |g| g.agent_def,
            .workflow => null,
        },
        .model = switch (a.action) {
            .agent => |g| g.model,
            .workflow => null,
        },
        .profile = a.profile,
        .isolation = a.isolation,
        .origin = .{ .automation = .{ .name = a.name, .fire_id = try arena.dupe(u8, fire_id) } },
        .budgets = .{ .max_turns = a.budgets.max_turns, .max_wall_ms = a.budgets.max_wall_ms, .max_cost_micros = a.budgets.max_cost_micro_usd },
        .tags = &.{"automation"},
        .untrusted_payload = payload,
    };
}

const LastRun = struct { at_ms: i64, summary: []const u8 };

fn lastRun(r: *AutomationRunner, arena: Allocator, name: []const u8) ?LastRun {
    const v = r.reg.snapshot();
    defer r.reg.release(v);
    // Newest first.
    for (v.runs) |rec| if (isAutomation(rec, name)) {
        return .{ .at_ms = rec.ended_ms orelse rec.started_ms orelse rec.created_ms, .summary = arena.dupe(u8, rec.summary) catch "" };
    };
    return null;
}

/// A run of `name` has not ended.
pub fn isRunning(r: *AutomationRunner, name: []const u8) bool {
    const v = r.reg.snapshot();
    defer r.reg.release(v);
    for (v.runs) |rec| if (isAutomation(rec, name) and !rec.status.isTerminal()) return true;
    return false;
}

/// `name`'s cost since the start of this local calendar month.
pub fn monthCostMicros(r: *AutomationRunner, name: []const u8) u64 {
    const now = r.nowMs();
    const l = r.zone.toLocal(r.zone.ctx, @divFloor(now, 1000));
    const start_s: i64 = switch (r.zone.fromLocal(r.zone.ctx, .{ .year = l.year, .month = l.month, .day = 1 })) {
        .unique => |t| t,
        .ambiguous => |t| t[0],
        .gap => |t| t,
    };
    const v = r.reg.snapshot();
    defer r.reg.release(v);
    var sum: u64 = 0;
    for (v.runs) |rec| if (isAutomation(rec, name) and rec.created_ms >= start_s * 1000) {
        sum += rec.cost.micros;
    };
    return sum;
}

fn fireFn(ctx: *anyopaque, a: *const Automation, req: Scheduler.FireRequest, payload: ?[]const u8) anyerror!?RunId {
    const r: *AutomationRunner = @ptrCast(@alignCast(ctx));
    return r.fire(a, req, payload);
}

fn isRunningFn(ctx: *anyopaque, name: []const u8) bool {
    const r: *AutomationRunner = @ptrCast(@alignCast(ctx));
    return r.isRunning(name);
}

fn stopRunningFn(ctx: *anyopaque, name: []const u8) void {
    const r: *AutomationRunner = @ptrCast(@alignCast(ctx));
    var ids: [16]RunId = undefined;
    var n: usize = 0;
    {
        const v = r.reg.snapshot();
        defer r.reg.release(v);
        for (v.runs) |rec| if (isAutomation(rec, name) and !rec.status.isTerminal() and n < ids.len) {
            ids[n] = rec.id;
            n += 1;
        };
    }
    for (ids[0..n]) |id| r.starter.stop(r.starter.ctx, id);
}

fn monthCostFn(ctx: *anyopaque, name: []const u8) u64 {
    const r: *AutomationRunner = @ptrCast(@alignCast(ctx));
    return r.monthCostMicros(name);
}

fn warnFn(ctx: *anyopaque, name: []const u8, message: []const u8) void {
    const r: *AutomationRunner = @ptrCast(@alignCast(ctx));
    if (r.o.warn) |w| w.warn(w.ctx, name, message);
}

// ---- templates ----

pub const Vars = struct {
    now: []const u8 = "",
    date: []const u8 = "",
    last_run_at: []const u8 = "never",
    last_run_summary: []const u8 = "",
    trigger_files: []const u8 = "",
    trigger_event: []const u8 = "",

    fn get(v: *const Vars, name: []const u8) ?[]const u8 {
        const table = .{
            .{ "now", "now" },
            .{ "date", "date" },
            .{ "last_run_at", "last_run_at" },
            .{ "last_run_summary", "last_run_summary" },
            .{ "trigger.files", "trigger_files" },
            .{ "trigger.event", "trigger_event" },
        };
        inline for (table) |e| if (std.mem.eql(u8, name, e[0])) return @field(v, e[1]);
        return null;
    }
};

/// Replaces `{{name}}` (spaces inside the braces allowed) with its value.
pub fn expand(arena: Allocator, src: []const u8, v: *const Vars) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        if (std.mem.startsWith(u8, src[i..], "{{")) {
            if (std.mem.indexOfPos(u8, src, i + 2, "}}")) |end| {
                const name = std.mem.trim(u8, src[i + 2 .. end], " ");
                if (v.get(name)) |val| {
                    try out.appendSlice(arena, val);
                    i = end + 2;
                    continue;
                }
            }
        }
        try out.append(arena, src[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// `event` and the `paths[].path` list of a trigger payload.
fn payloadVars(arena: Allocator, payload: []const u8, v: *Vars) void {
    const P = struct {
        event: []const u8 = "",
        paths: []const struct { path: []const u8 } = &.{},
    };
    const p = std.json.parseFromSliceLeaky(P, arena, payload, .{ .ignore_unknown_fields = true }) catch return;
    v.trigger_event = p.event;
    var files: std.ArrayList(u8) = .empty;
    for (p.paths, 0..) |e, i| {
        if (i > 0) files.appendSlice(arena, ", ") catch return;
        files.appendSlice(arena, e.path) catch return;
    }
    v.trigger_files = files.items;
}
