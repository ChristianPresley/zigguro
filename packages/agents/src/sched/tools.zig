//! Automation tools for agents (E13.F02.S01.T03): `automation_list`,
//! `automation_history` (read-only), `automation_create` and
//! `automation_update`, which never write: they propose the `.zon` file
//! as an E12 changeset through `ChangePort` (pending review) and return
//! the changeset id with the computed next fire times; and
//! `automation_run`, which fires an automation now (the registry asks the
//! user first, as for every non-read-only tool). Exported through zg_ai's
//! foreign-tool contract:
//!
//! ```zig
//! var x: zg_agents.sched.tools.ToolExporter = .{ .src = .{ ... } };
//! services.agents = x.exporter();
//! ```

const std = @import("std");
const zg_ai = @import("zg_ai");
const auto = @import("automation.zig");
const loader = @import("loader.zig");
const history = @import("history.zig");
const describe_mod = @import("describe.zig");
const cron = @import("cron.zig");
const zone_mod = @import("zone.zig");
const Scheduler = @import("scheduler.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Automation = auto.Automation;
const foreign = zg_ai.tools.adapters.foreign;

/// One proposed file change: `base` null creates the file.
pub const FileChange = struct { path: []const u8, base: ?[]const u8, new: []const u8 };

/// Submits agent changes as one E12 changeset (agent actor, pending
/// review).
pub const ChangePort = struct {
    ctx: *anyopaque,
    propose: *const fn (ctx: *anyopaque, label: []const u8, tool: []const u8, changes: []const FileChange) anyerror!u64,
};

pub const Source = struct {
    gpa: Allocator,
    io: Io,
    /// `.zigguro/automations` (read; writes go through `changes`).
    dir: Io.Dir,
    history_dir: ?Io.Dir = null,
    scheduler: ?*Scheduler = null,
    /// Null: the create and update tools fail (read-only callers).
    changes: ?ChangePort = null,
    trust: ?loader.TrustPort = null,
    zone: zone_mod.ZoneResolver,
    workspace_key: []const u8 = "",
    clock: ?Scheduler.Clock = null,
    max_output: usize = 32 << 10,
    /// Per-run cost cap given to automations created without one.
    default_max_cost_micro_usd: u64 = 500_000,

    fn nowMs(s: *const Source) i64 {
        if (s.clock) |c| return c.nowRealMs(c.ctx);
        return @intCast(@divFloor(Io.Clock.real.now(s.io).nanoseconds, std.time.ns_per_ms));
    }
};

pub const schemas = struct {
    const fields =
        \\"description":{"type":"string"},
        \\"cron":{"type":"string","description":"Five-field cron expression in local time (or @daily, @hourly, ...)."},
        \\"once":{"type":"string","description":"Run once at this local time, YYYY-MM-DD HH:MM."},
        \\"files":{"type":"array","items":{"type":"string"},"description":"Run when files matching these globs change (! excludes)."},
        \\"scm":{"type":"array","items":{"enum":["change_created","op_committed","lane_landed","conflict_detected","git_fetched","bookmark_moved"]}},
        \\"task":{"type":"array","items":{"enum":["created","status_changed","assigned","commented"]}},
        \\"prompt":{"type":"string","description":"What the agent is asked to do. May use {{now}}, {{date}}, {{last_run_at}}, {{last_run_summary}}, {{trigger.files}}."},
        \\"workflow":{"type":"string"},
        \\"profile":{"type":"string","description":"Permission profile: unattended-readonly (default), unattended-notes-write or unattended-lane-write."},
        \\"max_cost_micro_usd":{"type":"integer","minimum":1},
        \\"enabled":{"type":"boolean"}
    ;
    pub const list = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";
    pub const create = "{\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\",\"pattern\":\"^[a-z0-9][a-z0-9-]{0,63}$\"}," ++ fields ++ "},\"additionalProperties\":false}";
    pub const update = "{\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"}," ++ fields ++ "},\"additionalProperties\":false}";
    pub const run = "{\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"}},\"additionalProperties\":false}";
    pub const history = "{\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":200}},\"additionalProperties\":false}";
};

pub const tool_list = [_]foreign.ForeignTool{
    .{ .name = "automation_list", .description = "List the workspace's automations: schedule in words, next fire time, enabled state, last status and any file problems.", .input_schema_json = schemas.list, .read_only = true },
    .{ .name = "automation_history", .description = "Recent fires and skips of an automation, with run ids.", .input_schema_json = schemas.history, .read_only = true },
    .{ .name = "automation_create", .description = "Propose a new automation (a cron, one-off, file, SCM or task trigger that runs an agent prompt or workflow unattended). Nothing is written until a human approves the change. Returns the next fire times.", .input_schema_json = schemas.create, .mutates = true },
    .{ .name = "automation_update", .description = "Propose changes to an automation's fields (schedule, prompt, profile, budget, enabled). Applied only after review.", .input_schema_json = schemas.update, .mutates = true },
    .{ .name = "automation_run", .description = "Run an automation now.", .input_schema_json = schemas.run },
};

/// Must not move after `exporter`.
pub const ToolExporter = struct {
    src: Source,

    pub fn exporter(self: *ToolExporter) foreign.Exporter {
        return .{ .name = "automations", .kind = .agents, .ctx = self, .list = listFn, .call = callFn };
    }

    fn listFn(_: *anyopaque, arena: Allocator) anyerror![]const foreign.ForeignTool {
        return arena.dupe(foreign.ForeignTool, &tool_list);
    }

    fn callFn(ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!foreign.Result {
        _ = io;
        const self: *ToolExporter = @ptrCast(@alignCast(ctx));
        const r = try run(&self.src, arena, tool, input_json);
        return .{ .json = r.json, .changeset = r.changeset };
    }
};

pub const Output = struct { json: []const u8, changeset: ?u64 = null, is_error: bool = false };

pub const Error = error{BadInput};

/// Runs `tool` and wraps its output as a `CallToolResult`.
pub fn run(src: *Source, arena: Allocator, tool: []const u8, input_json: []const u8) !Output {
    var msg: []const u8 = "";
    var cs: ?u64 = null;
    const body = runTool(src, arena, tool, if (input_json.len == 0) "{}" else input_json, &msg, &cs) catch |e| switch (e) {
        error.OutOfMemory, error.UnknownTool => return e,
        error.BadInput => null,
        else => blk: {
            msg = try std.fmt.allocPrint(arena, "{s} failed: {t}", .{ tool, e });
            break :blk null;
        },
    };
    var text = body orelse msg;
    if (text.len > src.max_output) text = text[0..src.max_output];
    const Block = struct { type: []const u8 = "text", text: []const u8 };
    const R = struct { content: []const Block, isError: bool };
    const json = try std.json.Stringify.valueAlloc(arena, R{ .content = &.{.{ .text = text }}, .isError = body == null }, .{});
    return .{ .json = json, .changeset = cs, .is_error = body == null };
}

fn runTool(src: *Source, arena: Allocator, tool: []const u8, input: []const u8, msg: *[]const u8, cs: *?u64) ![]const u8 {
    if (std.mem.eql(u8, tool, "automation_list")) return list(src, arena);
    if (std.mem.eql(u8, tool, "automation_history")) return historyTool(src, arena, input, msg);
    if (std.mem.eql(u8, tool, "automation_create")) return write(src, arena, input, msg, cs, true);
    if (std.mem.eql(u8, tool, "automation_update")) return write(src, arena, input, msg, cs, false);
    if (std.mem.eql(u8, tool, "automation_run")) return runNow(src, arena, input, msg);
    return error.UnknownTool;
}

fn bad(arena: Allocator, msg: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    msg.* = std.fmt.allocPrint(arena, fmt, args) catch "invalid input";
    return error.BadInput;
}

/// Local `YYYY-MM-DD HH:MM` of each time.
pub fn localTimes(src: *const Source, arena: Allocator, times: []const i64) ![]const []const u8 {
    const out = try arena.alloc([]const u8, times.len);
    for (times, out) |t, *o| {
        const l = src.zone.toLocal(src.zone.ctx, @divFloor(t, 1000));
        o.* = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ l.year, l.month, l.day, l.hour, l.minute });
    }
    return out;
}

/// The triggers in words.
pub fn summarizeTriggers(arena: Allocator, a: *const Automation) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (a.triggers, 0..) |t, i| {
        if (i > 0) try out.writer.writeAll("; ");
        switch (t) {
            .schedule => |s| if (cron.CronExpr.parse(s.cron)) |c| try describe_mod.describe(&c, &out.writer) else |_| try out.writer.print("cron {s}", .{s.cron}),
            .once => |o| try out.writer.print("once at {s}", .{o.at}),
            .files => |f| {
                try out.writer.writeAll("when files change: ");
                for (f.globs, 0..) |g, k| try out.writer.print("{s}{s}", .{ if (k > 0) ", " else "", g });
            },
            .scm => |s| {
                try out.writer.writeAll("on SCM events: ");
                for (s.events, 0..) |e, k| try out.writer.print("{s}{t}", .{ if (k > 0) ", " else "", e });
            },
            .task => |s| {
                try out.writer.writeAll("on task events: ");
                for (s.events, 0..) |e, k| try out.writer.print("{s}{t}", .{ if (k > 0) ", " else "", e });
            },
        }
    }
    return out.written();
}

/// One automation as `automation_list` and `zg automation list` show it.
pub const Row = struct {
    name: []const u8,
    description: []const u8 = "",
    enabled: bool = false,
    needs_approval: bool = false,
    triggers: []const u8 = "",
    /// Local `YYYY-MM-DD HH:MM`.
    next_fires: []const []const u8 = &.{},
    last_status: ?[]const u8 = null,
    /// `file:line:column: message`.
    problem: ?[]const u8 = null,
};

/// The rows for every automation file, in `arena`.
pub fn listRows(src: *const Source, arena: Allocator) ![]Row {
    var res = try loader.loadAll(src.io, src.gpa, src.dir, src.trust);
    defer res.deinit();
    var rows: std.ArrayList(Row) = .empty;
    const now = src.nowMs();
    for (res.items) |it| {
        var row: Row = .{ .name = try arena.dupe(u8, it.name), .needs_approval = it.needs_approval };
        if (it.problem) |p| {
            row.problem = try std.fmt.allocPrint(arena, "{s}:{d}:{d}: {s}", .{ it.file, p.line, p.column, p.message });
        }
        if (it.automation) |a| {
            row.description = try arena.dupe(u8, a.description);
            row.enabled = a.enabled and !it.needs_approval;
            row.triggers = try summarizeTriggers(arena, &a);
            var times: [3]i64 = undefined;
            const n = if (row.enabled) Scheduler.upcoming(&a, src.zone, src.workspace_key, now, &times) else 0;
            row.next_fires = try localTimes(src, arena, times[0..n]);
            if (src.history_dir) |hd| {
                const last = history.readTail(arena, src.io, hd, a.name, 1) catch &.{};
                if (last.len > 0) row.last_status = if (last[0].skip) |sk| @tagName(sk) else "fired";
            }
        }
        try rows.append(arena, row);
    }
    return rows.items;
}

fn list(src: *Source, arena: Allocator) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{ .automations = try listRows(src, arena) }, .{ .emit_null_optional_fields = false });
}

fn historyTool(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const In = struct { name: []const u8, limit: u32 = 20 };
    const in = std.json.parseFromSliceLeaky(In, arena, input, .{}) catch |e| return bad(arena, msg, "invalid input: {t}", .{e});
    const hd = src.history_dir orelse return bad(arena, msg, "no automation history in this workspace", .{});
    if (!auto.validName(in.name)) return bad(arena, msg, "no automation named \"{s}\"", .{in.name});
    const recs = try history.readTail(arena, src.io, hd, in.name, @min(in.limit, 200));
    return std.json.Stringify.valueAlloc(arena, .{ .name = in.name, .records = recs }, .{});
}

const WriteIn = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    cron: ?[]const u8 = null,
    once: ?[]const u8 = null,
    files: ?[]const []const u8 = null,
    scm: ?[]const auto.ScmEventKind = null,
    task: ?[]const auto.TaskEventKind = null,
    prompt: ?[]const u8 = null,
    workflow: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    max_cost_micro_usd: ?u64 = null,
    enabled: ?bool = null,
};

fn write(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8, cs: *?u64, create: bool) ![]const u8 {
    const in = std.json.parseFromSliceLeaky(WriteIn, arena, input, .{}) catch |e| return bad(arena, msg, "invalid input: {t}", .{e});
    if (!auto.validName(in.name)) return bad(arena, msg, "name must match [a-z0-9][a-z0-9-]{{0,63}}", .{});
    const file = try std.fmt.allocPrint(arena, "{s}.zon", .{in.name});
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ loader.dir_path, file });
    var base: ?[]const u8 = null;
    var a: Automation = undefined;
    if (create) {
        if (src.dir.access(src.io, file, .{})) |_| {
            return bad(arena, msg, "automation \"{s}\" already exists; use automation_update", .{in.name});
        } else |_| {}
        if (in.prompt == null and in.workflow == null) return bad(arena, msg, "give a prompt or a workflow", .{});
        a = .{
            .name = in.name,
            .triggers = &.{},
            .action = undefined,
            .budgets = .{ .max_cost_micro_usd = src.default_max_cost_micro_usd },
        };
    } else {
        const l = try loader.loadOne(src.io, arena, src.dir, file, null);
        if (l.source.len == 0 and l.problem != null) return bad(arena, msg, "no automation named \"{s}\"", .{in.name});
        a = l.automation orelse return bad(arena, msg, "{s} is invalid ({s}); fix the file first", .{ file, l.problem.?.message });
        base = l.source;
    }
    if (in.description) |d| a.description = d;
    if (in.profile) |p| a.profile = p;
    if (in.max_cost_micro_usd) |m| a.budgets.max_cost_micro_usd = m;
    if (in.enabled) |e| a.enabled = e;
    if (in.prompt) |p| a.action = .{ .agent = .{ .prompt = p } };
    if (in.workflow) |w| a.action = .{ .workflow = .{ .workflow = w } };
    // Triggers given replace the triggers of that kind.
    var triggers: std.ArrayList(auto.Trigger) = .empty;
    for (a.triggers) |t| {
        const replaced = switch (t) {
            .schedule => in.cron != null,
            .once => in.once != null,
            .files => in.files != null,
            .scm => in.scm != null,
            .task => in.task != null,
        };
        if (!replaced) try triggers.append(arena, t);
    }
    if (in.cron) |c| try triggers.append(arena, .{ .schedule = .{ .cron = c } });
    if (in.once) |o| try triggers.append(arena, .{ .once = .{ .at = o } });
    if (in.files) |f| try triggers.append(arena, .{ .files = .{ .globs = f } });
    if (in.scm) |s| try triggers.append(arena, .{ .scm = .{ .events = s } });
    if (in.task) |k| try triggers.append(arena, .{ .task = .{ .events = k } });
    a.triggers = triggers.items;
    if (auto.validate(&a, in.name)) |problem| return bad(arena, msg, "{s}", .{problem});
    const zon = try auto.toZon(arena, &a);
    const label = try std.fmt.allocPrint(arena, "{s} automation {s}", .{ if (create) "Create" else "Update", in.name });
    const changes = src.changes orelse return bad(arena, msg, "automations cannot be changed in this session", .{});
    const id = try changes.propose(changes.ctx, label, if (create) "automation_create" else "automation_update", &.{.{ .path = path, .base = base, .new = zon }});
    cs.* = id;
    var times: [5]i64 = undefined;
    const n = Scheduler.upcoming(&a, src.zone, src.workspace_key, src.nowMs(), &times);
    return std.json.Stringify.valueAlloc(arena, .{
        .path = path,
        .changeset = id,
        .status = "pending review",
        .triggers = try summarizeTriggers(arena, &a),
        .next_fires = try localTimes(src, arena, times[0..n]),
    }, .{});
}

fn runNow(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const In = struct { name: []const u8 };
    const in = std.json.parseFromSliceLeaky(In, arena, input, .{}) catch |e| return bad(arena, msg, "invalid input: {t}", .{e});
    const s = src.scheduler orelse return bad(arena, msg, "automations are not running in this session", .{});
    const id = s.fireNow(in.name) catch |e| switch (e) {
        error.UnknownAutomation => return bad(arena, msg, "no automation named \"{s}\"", .{in.name}),
        error.AlreadyRunning => return bad(arena, msg, "\"{s}\" is already running", .{in.name}),
        else => return e,
    };
    return std.json.Stringify.valueAlloc(arena, .{ .name = in.name, .fire_id = id }, .{});
}
