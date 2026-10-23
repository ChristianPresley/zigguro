//! Task tools for agents (E13.F03.S02.T01), exported through zg_ai's
//! foreign-tool contract:
//!
//! - `task_list`, `task_get`: read the board (read-only).
//! - `task_create`, `task_update`: propose a task file or a change to one
//!   as an E12 changeset (task files are reviewable); `TaskCreated` hooks
//!   may block a creation.
//! - `task_claim`, `task_claim_next`, `task_progress`, `task_complete`,
//!   `task_release`: coordination, applied at once (status, claim and the
//!   append-only agent log); `TaskCompleted` hooks may block completion.
//!
//! The app makes one exporter per agent run (`Source.run`), so claims and
//! log lines name the run that called.

const std = @import("std");
const zg_ai = @import("zg_ai");
const runs = @import("../runs/root.zig");
const task_mod = @import("task.zig");
const ids = @import("ids.zig");
const query_mod = @import("query.zig");
const hooks_mod = @import("hooks.zig");
const TaskStore = @import("store.zig");
const ClaimManager = @import("claim.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const foreign = zg_ai.tools.adapters.foreign;
const RunId = runs.RunId;
const TaskId = task_mod.TaskId;
const Task = task_mod.Task;

/// Reports progress to the run (its one-line summary in Mission Control).
pub const ProgressPort = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, run: RunId, note: []const u8) void,
};

pub const Source = struct {
    store: *TaskStore,
    claims: ?*ClaimManager = null,
    /// The calling run; null: the claim tools refuse.
    run: ?RunId = null,
    /// Its agent definition (for hooks).
    agent: ?[]const u8 = null,
    hooks: ?hooks_mod.HookPort = null,
    progress: ?ProgressPort = null,
    lease_s: u32 = ClaimManager.default_lease_s,
    max_output: usize = 32 << 10,
    /// `task_list` rows at most.
    max_rows: u32 = 200,
};

pub const schemas = struct {
    const id = "\"id\":{\"type\":\"string\",\"description\":\"A task id such as T-0042.\"}";
    const priority = "\"priority\":{\"enum\":[\"P0\",\"P1\",\"P2\",\"P3\"],\"description\":\"P0 is the most urgent.\"}";
    const fields = "\"title\":{\"type\":\"string\"},\"body\":{\"type\":\"string\",\"description\":\"Markdown after the properties.\"}," ++
        "\"labels\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"depends_on\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}," ++
        priority ++ ",\"due\":{\"type\":\"string\",\"description\":\"YYYY-MM-DD\"},\"assignee\":{\"type\":\"string\",\"description\":\"A person or agent:<definition>; empty to unassign.\"}";
    const query = "\"query\":{\"type\":\"string\",\"description\":\"Task query, e.g. status:ready label:docs -blocked:true sort:priority (docs/formats/tasks.md).\"}";
    pub const list = "{\"type\":\"object\",\"properties\":{" ++ query ++ ",\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":500}},\"additionalProperties\":false}";
    pub const get = "{\"type\":\"object\",\"required\":[\"id\"],\"properties\":{" ++ id ++ "},\"additionalProperties\":false}";
    pub const create = "{\"type\":\"object\",\"required\":[\"title\"],\"properties\":{" ++ fields ++ "},\"additionalProperties\":false}";
    pub const update = "{\"type\":\"object\",\"required\":[\"id\"],\"properties\":{" ++ id ++ "," ++ fields ++ "},\"additionalProperties\":false}";
    pub const claim = get;
    pub const claim_next = "{\"type\":\"object\",\"properties\":{" ++ query ++ "},\"additionalProperties\":false}";
    pub const progress = "{\"type\":\"object\",\"required\":[\"id\",\"note\"],\"properties\":{" ++ id ++ ",\"note\":{\"type\":\"string\"}},\"additionalProperties\":false}";
    pub const complete = "{\"type\":\"object\",\"required\":[\"id\",\"summary\",\"outcome\"],\"properties\":{" ++ id ++ ",\"summary\":{\"type\":\"string\"},\"outcome\":{\"enum\":[\"review\",\"done\"],\"description\":\"review when a person should check the work.\"}},\"additionalProperties\":false}";
    pub const release = "{\"type\":\"object\",\"required\":[\"id\",\"reason\"],\"properties\":{" ++ id ++ ",\"reason\":{\"type\":\"string\"}},\"additionalProperties\":false}";
};

pub const tool_list = [_]foreign.ForeignTool{
    .{ .name = "task_list", .description = "List tasks on the workspace's task board matching a query (default: every open task), most urgent first.", .input_schema_json = schemas.list, .read_only = true },
    .{ .name = "task_get", .description = "A task's properties, dependencies, claim and Markdown body.", .input_schema_json = schemas.get, .read_only = true },
    .{ .name = "task_create", .description = "Propose a new task. A person reviews it before it is added.", .input_schema_json = schemas.create, .mutates = true },
    .{ .name = "task_update", .description = "Propose changes to a task's title, body, labels, dependencies, priority, due date or assignee. A person reviews them.", .input_schema_json = schemas.update, .mutates = true },
    .{ .name = "task_claim", .description = "Claim a ready task before working on it, so no other agent takes it. Fails if it is taken, blocked by unfinished tasks or not ready.", .input_schema_json = schemas.claim },
    .{ .name = "task_claim_next", .description = "Claim the most urgent ready, unblocked task matching a query (default status:ready).", .input_schema_json = schemas.claim_next },
    .{ .name = "task_progress", .description = "Add a progress note to a task you claimed (its agent log).", .input_schema_json = schemas.progress },
    .{ .name = "task_complete", .description = "Finish a task you claimed: outcome review (a person checks it) or done.", .input_schema_json = schemas.complete },
    .{ .name = "task_release", .description = "Give a claimed task back (it returns to ready) with the reason.", .input_schema_json = schemas.release },
};

/// Must not move after `exporter`.
pub const ToolExporter = struct {
    src: Source,

    pub fn exporter(self: *ToolExporter) foreign.Exporter {
        return .{ .name = "tasks", .kind = .agents, .ctx = self, .list = listFn, .call = callFn };
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
    const eq = std.mem.eql;
    if (eq(u8, tool, "task_list")) return listTool(src, arena, input, msg);
    if (eq(u8, tool, "task_get")) return getTool(src, arena, input, msg);
    if (eq(u8, tool, "task_create")) return createTool(src, arena, input, msg, cs);
    if (eq(u8, tool, "task_update")) return updateTool(src, arena, input, msg, cs);
    if (eq(u8, tool, "task_claim")) return claimTool(src, arena, input, msg);
    if (eq(u8, tool, "task_claim_next")) return claimNextTool(src, arena, input, msg);
    if (eq(u8, tool, "task_progress")) return progressTool(src, arena, input, msg);
    if (eq(u8, tool, "task_complete")) return completeTool(src, arena, input, msg);
    if (eq(u8, tool, "task_release")) return releaseTool(src, arena, input, msg);
    return error.UnknownTool;
}

fn bad(arena: Allocator, msg: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    msg.* = std.fmt.allocPrint(arena, fmt, args) catch "invalid input";
    return error.BadInput;
}

fn parseInput(comptime T: type, arena: Allocator, input: []const u8, msg: *[]const u8) Error!T {
    return std.json.parseFromSliceLeaky(T, arena, input, .{}) catch |e| bad(arena, msg, "invalid input: {t}", .{e});
}

fn taskId(arena: Allocator, s: []const u8, msg: *[]const u8) Error!TaskId {
    return ids.parse(s) orelse bad(arena, msg, "{s} is not a task id (T-0042)", .{s});
}

fn claimsOf(src: *Source, arena: Allocator, msg: *[]const u8) Error!struct { c: *ClaimManager, run: RunId } {
    const c = src.claims orelse return bad(arena, msg, "claims are not available here", .{});
    const r = src.run orelse return bad(arena, msg, "only agent runs can claim tasks", .{});
    return .{ .c = c, .run = r };
}

const Row = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    priority: []const u8,
    assignee: ?[]const u8,
    labels: []const []const u8,
    due: ?[]const u8,
    depends_on: []const []const u8,
    blocked: bool,
    claimed_by: ?[]const u8,
    problem: ?[]const u8,
};

fn row(arena: Allocator, v: *const @import("view.zig").TasksView, t: *const Task) !Row {
    const deps = try arena.alloc([]const u8, t.depends_on.len);
    for (deps, t.depends_on) |*d, x| d.* = try arena.dupe(u8, ids.format(x).slice());
    return .{
        .id = if (t.id == 0) t.path else try arena.dupe(u8, ids.format(t.id).slice()),
        .title = t.title,
        .status = @tagName(t.status),
        .priority = ([_][]const u8{ "P0", "P1", "P2", "P3" })[t.priority],
        .assignee = t.assignee,
        .labels = t.labels,
        .due = if (t.due) |d| try std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2}", .{ d.y, d.m, d.d }) else null,
        .depends_on = deps,
        .blocked = v.isBlocked(t),
        .claimed_by = t.claimed_by,
        .problem = t.problem,
    };
}

fn listTool(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const In = struct { query: ?[]const u8 = null, limit: ?u32 = null };
    const in = try parseInput(In, arena, input, msg);
    const qtext = in.query orelse "-status:done,cancelled sort:priority";
    const q = query_mod.parseQuery(arena, qtext) catch return bad(arena, msg, "invalid query: {s}", .{qtext});
    const v = src.store.view();
    defer src.store.release(v);
    var idx: std.ArrayList(u32) = .empty;
    try query_mod.evalQueryAt(v, &q, src.store.today(), &idx, arena);
    const n = @min(idx.items.len, in.limit orelse src.max_rows);
    const rows = try arena.alloc(Row, n);
    for (rows, idx.items[0..n]) |*r, i| r.* = try row(arena, v, &v.tasks[i]);
    const Out = struct { total: usize, tasks: []const Row };
    return std.json.Stringify.valueAlloc(arena, Out{ .total = idx.items.len, .tasks = rows }, .{ .emit_null_optional_fields = false });
}

fn getTool(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const In = struct { id: []const u8 };
    const in = try parseInput(In, arena, input, msg);
    const id = try taskId(arena, in.id, msg);
    const v = src.store.view();
    defer src.store.release(v);
    const t = v.get(id) orelse return bad(arena, msg, "no task {s}", .{in.id});
    const bytes = src.store.dir.readFileAlloc(src.store.io, t.path, arena, .limited(1 << 20)) catch "";
    var blocked_by: std.ArrayList(TaskId) = .empty;
    try v.blockedBy(id, &blocked_by, arena);
    const bb = try arena.alloc([]const u8, blocked_by.items.len);
    for (bb, blocked_by.items) |*d, x| d.* = try arena.dupe(u8, ids.format(x).slice());
    const Out = struct { task: Row, file: []const u8, blocked_by: []const []const u8, body: []const u8 };
    const file = try std.fmt.allocPrint(arena, "{s}/{s}", .{ src.store.o.dir_rel, t.path });
    return std.json.Stringify.valueAlloc(arena, Out{ .task = try row(arena, v, t), .file = file, .blocked_by = bb, .body = task_mod.bodyOf(bytes) }, .{ .emit_null_optional_fields = false });
}

const Fields = struct {
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    labels: ?[]const []const u8 = null,
    depends_on: ?[]const []const u8 = null,
    priority: ?[]const u8 = null,
    due: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
};

fn priorityOf(arena: Allocator, s: []const u8, msg: *[]const u8) Error!u2 {
    if (s.len == 2 and (s[0] == 'P' or s[0] == 'p') and s[1] >= '0' and s[1] <= '3') return @intCast(s[1] - '0');
    return bad(arena, msg, "priority must be P0 to P3", .{});
}

fn depsOf(arena: Allocator, list: []const []const u8, msg: *[]const u8) ![]const TaskId {
    const out = try arena.alloc(TaskId, list.len);
    for (out, list) |*o, s| o.* = try taskId(arena, s, msg);
    return out;
}

fn dateOf(arena: Allocator, s: []const u8, msg: *[]const u8) Error!task_mod.Date {
    if (s.len == 10 and s[4] == '-' and s[7] == '-') {
        const y = std.fmt.parseInt(i32, s[0..4], 10) catch 0;
        const m = std.fmt.parseInt(u4, s[5..7], 10) catch 0;
        const d = std.fmt.parseInt(u5, s[8..10], 10) catch 0;
        if (y > 0 and m >= 1 and m <= 12 and d >= 1 and d <= 31) return .{ .y = y, .m = m, .d = d };
    }
    return bad(arena, msg, "due must be YYYY-MM-DD", .{});
}

fn agentVia(src: *const Source) TaskStore.WriteVia {
    return .{ .agent = .{ .run = src.run orelse .zero } };
}

fn hook(src: *Source, arena: Allocator, ev: hooks_mod.Event, in: hooks_mod.Input, msg: *[]const u8) !void {
    const h = src.hooks orelse return;
    var i = in;
    i.run = src.run;
    i.agent = src.agent;
    if (try h.run(h.ctx, arena, ev, i)) |reason| return bad(arena, msg, "blocked by a {s} hook: {s}", .{ if (ev == .created) "TaskCreated" else "TaskCompleted", reason });
}

fn createTool(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8, cs: *?u64) ![]const u8 {
    const in = try parseInput(Fields, arena, input, msg);
    const title = std.mem.trim(u8, in.title orelse "", " \t\r\n");
    if (title.len == 0) return bad(arena, msg, "a task needs a title", .{});
    var nt: TaskStore.NewTask = .{ .title = title, .status = .backlog, .body = in.body orelse "" };
    if (in.priority) |p| nt.priority = try priorityOf(arena, p, msg);
    if (in.labels) |l| nt.labels = l;
    if (in.depends_on) |d| nt.depends_on = try depsOf(arena, d, msg);
    if (in.due) |d| nt.due = try dateOf(arena, d, msg);
    if (in.assignee) |a| if (a.len > 0) {
        nt.assignee = a;
    };
    try hook(src, arena, .created, .{ .title = title, .description = nt.body }, msg);
    const r = src.store.create(nt, agentVia(src)) catch |e| switch (e) {
        error.ReviewUnavailable => return bad(arena, msg, "task changes need review, which is not available here", .{}),
        else => return e,
    };
    switch (r.outcome) {
        .changeset => |c| cs.* = c,
        .applied => {},
    }
    return std.fmt.allocPrint(arena, "Proposed task {s} \"{s}\" for review (changeset {d}).", .{ ids.format(r.id).slice(), title, cs.* orelse 0 });
}

fn updateTool(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8, cs: *?u64) ![]const u8 {
    const In = struct {
        id: []const u8,
        title: ?[]const u8 = null,
        body: ?[]const u8 = null,
        labels: ?[]const []const u8 = null,
        depends_on: ?[]const []const u8 = null,
        priority: ?[]const u8 = null,
        due: ?[]const u8 = null,
        assignee: ?[]const u8 = null,
    };
    const in = try parseInput(In, arena, input, msg);
    const id = try taskId(arena, in.id, msg);
    var p: TaskStore.TaskPatch = .{ .title = in.title, .body = in.body, .labels = in.labels };
    if (in.depends_on) |d| p.depends_on = try depsOf(arena, d, msg);
    if (in.priority) |x| p.priority = try priorityOf(arena, x, msg);
    if (in.due) |d| p.due = if (d.len == 0) @as(?task_mod.Date, null) else try dateOf(arena, d, msg);
    if (in.assignee) |a| p.assignee = if (a.len == 0) @as(?[]const u8, null) else a;
    const out = src.store.update(id, p, agentVia(src)) catch |e| switch (e) {
        error.TaskNotFound => return bad(arena, msg, "no task {s}", .{in.id}),
        error.ReviewUnavailable => return bad(arena, msg, "task changes need review, which is not available here", .{}),
        else => return e,
    };
    switch (out) {
        .changeset => |c| {
            cs.* = c;
            return std.fmt.allocPrint(arena, "Proposed the change to {s} for review (changeset {d}).", .{ ids.format(id).slice(), c });
        },
        .applied => return bad(arena, msg, "nothing to change in {s}", .{ids.format(id).slice()}),
    }
}

fn claimTool(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const In = struct { id: []const u8 };
    const in = try parseInput(In, arena, input, msg);
    const id = try taskId(arena, in.id, msg);
    const cl = try claimsOf(src, arena, msg);
    const idf = ids.format(id);
    return switch (try cl.c.claim(id, cl.run, src.lease_s)) {
        .ok => |c| std.fmt.allocPrint(arena, "Claimed {s}; the claim lasts {d} minutes and is renewed while you run. Call task_complete when finished.", .{ idf.slice(), @divFloor(c.until_s - @divFloor(src.store.nowMs(), 1000), 60) }),
        .taken_by => |r| bad(arena, msg, "{s} is already claimed by run {f}", .{ idf.slice(), r }),
        .blocked => |b| blk: {
            var w: std.Io.Writer.Allocating = .init(arena);
            for (b, 0..) |x, i| try w.writer.print("{s}{s}", .{ if (i > 0) ", " else "", ids.format(x).slice() });
            break :blk bad(arena, msg, "{s} waits for unfinished tasks: {s}", .{ idf.slice(), w.written() });
        },
        .not_ready => |s| bad(arena, msg, "{s} is {t}, not ready", .{ idf.slice(), s }),
        .not_found => bad(arena, msg, "no task {s}", .{idf.slice()}),
    };
}

fn claimNextTool(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const In = struct { query: ?[]const u8 = null };
    const in = try parseInput(In, arena, input, msg);
    const cl = try claimsOf(src, arena, msg);
    const qtext = in.query orelse "status:ready";
    const q = query_mod.parseQuery(arena, qtext) catch return bad(arena, msg, "invalid query: {s}", .{qtext});
    const id = try cl.c.claimNext(cl.run, &q, src.lease_s) orelse return bad(arena, msg, "no ready, unblocked task matches {s}", .{qtext});
    const v = src.store.view();
    defer src.store.release(v);
    const title = if (v.get(id)) |t| t.title else "";
    return std.fmt.allocPrint(arena, "Claimed {s} \"{s}\". Read it with task_get; call task_complete when finished.", .{ ids.format(id).slice(), title });
}

/// The calling run must hold the task.
fn mustHold(src: *Source, arena: Allocator, id: TaskId, holder: RunId, msg: *[]const u8) !void {
    const v = src.store.view();
    defer src.store.release(v);
    const t = v.get(id) orelse return bad(arena, msg, "no task {s}", .{ids.format(id).slice()});
    var rb: [32]u8 = undefined;
    const rt = std.fmt.bufPrint(&rb, "{f}", .{holder}) catch unreachable;
    if (t.claimed_by == null or !std.mem.eql(u8, t.claimed_by.?, rt)) return bad(arena, msg, "{s} is not claimed by you; claim it first", .{ids.format(id).slice()});
}

fn progressTool(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const In = struct { id: []const u8, note: []const u8 };
    const in = try parseInput(In, arena, input, msg);
    const id = try taskId(arena, in.id, msg);
    const cl = try claimsOf(src, arena, msg);
    try mustHold(src, arena, id, cl.run, msg);
    const note = std.mem.trim(u8, in.note, " \t\r\n");
    if (note.len == 0) return bad(arena, msg, "the note is empty", .{});
    const line = try std.fmt.allocPrint(arena, "{f}: {s}", .{ cl.run, note });
    try src.store.appendAgentLog(id, line);
    if (src.progress) |p| p.f(p.ctx, cl.run, note);
    return std.fmt.allocPrint(arena, "Noted on {s}.", .{ids.format(id).slice()});
}

fn completeTool(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const In = struct { id: []const u8, summary: []const u8, outcome: enum { review, done } };
    const in = try parseInput(In, arena, input, msg);
    const id = try taskId(arena, in.id, msg);
    const cl = try claimsOf(src, arena, msg);
    try mustHold(src, arena, id, cl.run, msg);
    {
        const v = src.store.view();
        defer src.store.release(v);
        const t = v.get(id).?;
        try hook(src, arena, .completed, .{ .id = id, .title = t.title, .description = in.summary }, msg);
    }
    const line = try std.fmt.allocPrint(arena, "{f} finished ({t}): {s}", .{ cl.run, in.outcome, std.mem.trim(u8, in.summary, " \t\r\n") });
    try src.store.appendAgentLog(id, line);
    cl.c.release(id, cl.run, if (in.outcome == .done) .done else .review, null) catch |e| switch (e) {
        error.NotClaimed => return bad(arena, msg, "{s} is not claimed by you", .{ids.format(id).slice()}),
        else => return e,
    };
    if (src.progress) |p| p.f(p.ctx, cl.run, in.summary);
    return std.fmt.allocPrint(arena, "{s} is now {s}.", .{ ids.format(id).slice(), if (in.outcome == .done) "done" else "in review" });
}

fn releaseTool(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const In = struct { id: []const u8, reason: []const u8 };
    const in = try parseInput(In, arena, input, msg);
    const id = try taskId(arena, in.id, msg);
    const cl = try claimsOf(src, arena, msg);
    cl.c.release(id, cl.run, .abandoned, std.mem.trim(u8, in.reason, " \t\r\n")) catch |e| switch (e) {
        error.NotClaimed => return bad(arena, msg, "{s} is not claimed by you", .{ids.format(id).slice()}),
        error.TaskNotFound => return bad(arena, msg, "no task {s}", .{in.id}),
        else => return e,
    };
    return std.fmt.allocPrint(arena, "Released {s}; it is ready again.", .{ids.format(id).slice()});
}
