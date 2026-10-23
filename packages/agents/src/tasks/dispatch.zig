//! Starting an agent on a task (E13.F03.S02.T01): the board's "Start
//! agent" (S) and Mission Control's dispatch. The dispatcher picks the
//! run's id, claims the task for it (failing fast when it is taken,
//! blocked or not ready), then starts the run with the task as its
//! prompt: the task file and the notes its body links to are named as
//! context, the assignee's agent definition runs it, and tasks labelled
//! `code` get their own lane.

const std = @import("std");
const runs = @import("../runs/root.zig");
const task_mod = @import("task.zig");
const ids = @import("ids.zig");
const TaskStore = @import("store.zig");
const ClaimManager = @import("claim.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const RunId = runs.RunId;
const RunSpec = runs.RunSpec;
const TaskId = task_mod.TaskId;
const Task = task_mod.Task;

/// Starts a run under a chosen id (`RunHost.startWithId`).
pub const StartPort = struct {
    ctx: *anyopaque,
    start: *const fn (ctx: *anyopaque, id: RunId, spec: RunSpec) anyerror!void,

    pub fn fromHost(h: *runs.RunHost) StartPort {
        return .{ .ctx = h, .start = hostStart };
    }

    fn hostStart(ctx: *anyopaque, id: RunId, spec: RunSpec) anyerror!void {
        const h: *runs.RunHost = @ptrCast(@alignCast(ctx));
        _ = try h.startWithId(id, spec);
    }
};

pub const DispatchOpts = struct {
    /// A person asked: backlog tasks may start too.
    by_user: bool = true,
    /// Overrides the assignee's agent definition.
    agent_def: ?[]const u8 = null,
    model: ?[]const u8 = null,
    profile: []const u8 = "default",
    /// Overrides the label rule.
    isolation: ?runs.Isolation = null,
};

pub const prompt_template =
    \\Work on task {id}: {title}
    \\
    \\{body}
    \\
    \\The task file is {file}.{links}
    \\Use task_progress for notes along the way. When finished call task_complete with outcome "review" (or "done" when nothing needs checking); if you cannot finish, call task_release with the reason.
;

pub const Error = error{ TaskNotFound, TaskTaken, TaskBlocked, TaskNotReady };

pub const Dispatcher = struct {
    gpa: Allocator,
    io: Io,
    store: *TaskStore,
    claims: *ClaimManager,
    starter: StartPort,
    lease_s: u32 = ClaimManager.default_lease_s,
    /// Labels that put the run in its own lane.
    lane_labels: []const []const u8 = &.{"code"},
    /// Settings: every task run gets a lane.
    lane_always: bool = false,
    /// Ids for new runs (tests set it).
    next_id: ?*const fn () RunId = null,

    /// Claims task `id` for a new run and starts it.
    pub fn startForTask(d: *Dispatcher, id: TaskId, opts: DispatchOpts) !RunId {
        const run = if (d.next_id) |f| f() else RunId.generate(d.io);
        switch (try d.claims.claimWith(id, run, d.lease_s, .{ .allow_backlog = opts.by_user })) {
            .ok => {},
            .taken_by => return error.TaskTaken,
            .blocked => return error.TaskBlocked,
            .not_ready => return error.TaskNotReady,
            .not_found => return error.TaskNotFound,
        }
        var arena_state: std.heap.ArenaAllocator = .init(d.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const spec = blk: {
            const v = d.store.view();
            defer d.store.release(v);
            const t = v.get(id) orelse return error.TaskNotFound;
            const bytes = d.store.dir.readFileAlloc(d.store.io, t.path, a, .limited(1 << 20)) catch "";
            break :blk try d.specFor(a, t, task_mod.bodyOf(bytes), opts);
        };
        d.starter.start(d.starter.ctx, run, spec) catch |e| {
            d.claims.release(id, run, .failed, "the run could not start") catch {};
            return e;
        };
        return run;
    }

    /// The run for task `t` with body `body`; strings in `a`.
    pub fn specFor(d: *const Dispatcher, a: Allocator, t: *const Task, body: []const u8, opts: DispatchOpts) !RunSpec {
        const idf = ids.format(t.id);
        const file = try std.fmt.allocPrint(a, "{s}/{s}", .{ d.store.o.dir_rel, t.path });
        var links: std.Io.Writer.Allocating = .init(a);
        var n: usize = 0;
        var it = wikiLinks(body);
        while (it.next()) |l| : (n += 1) try links.writer.print("{s}[[{s}]]", .{ if (n == 0) "\nLinked notes: " else ", ", l });
        const prompt = try fill(a, prompt_template, &.{
            .{ "{id}", idf.slice() },
            .{ "{title}", t.title },
            .{ "{body}", std.mem.trim(u8, body, " \t\r\n") },
            .{ "{file}", file },
            .{ "{links}", links.written() },
        });
        const agent_def = opts.agent_def orelse if (t.assignee) |x| (if (std.mem.startsWith(u8, x, "agent:")) x[6..] else null) else null;
        var lane = d.lane_always;
        for (d.lane_labels) |l| if (t.hasLabel(l)) {
            lane = true;
        };
        var tags: std.ArrayList([]const u8) = .empty;
        try tags.append(a, "task");
        for (t.labels) |l| try tags.append(a, l);
        return .{
            .kind = .task,
            .title = try std.fmt.allocPrint(a, "{s} \u{00B7} {s}", .{ idf.slice(), t.title }),
            .prompt = prompt,
            .agent_def = agent_def,
            .model = opts.model,
            .profile = opts.profile,
            .isolation = opts.isolation orelse if (lane) .lane else .shared,
            .origin = .{ .task = .{ .id = try a.dupe(u8, idf.slice()) } },
            .tags = tags.items,
        };
    }
};

fn fill(a: Allocator, tmpl: []const u8, vars: []const [2][]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var i: usize = 0;
    outer: while (i < tmpl.len) {
        if (tmpl[i] == '{') for (vars) |v| if (std.mem.startsWith(u8, tmpl[i..], v[0])) {
            try out.writer.writeAll(v[1]);
            i += v[0].len;
            continue :outer;
        };
        try out.writer.writeByte(tmpl[i]);
        i += 1;
    }
    return out.written();
}

/// The targets of `[[links]]` in Markdown (without `|alias` or `#heading`).
pub fn wikiLinks(body: []const u8) WikiLinks {
    return .{ .s = body };
}

pub const WikiLinks = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(w: *WikiLinks) ?[]const u8 {
        while (std.mem.indexOfPos(u8, w.s, w.i, "[[")) |open| {
            const close = std.mem.indexOfPos(u8, w.s, open + 2, "]]") orelse return null;
            w.i = close + 2;
            var target = w.s[open + 2 .. close];
            if (std.mem.indexOfScalar(u8, target, '\n') != null) continue;
            if (std.mem.indexOfAny(u8, target, "|#")) |k| target = target[0..k];
            target = std.mem.trim(u8, target, " ");
            if (target.len > 0) return target;
        }
        return null;
    }
};

test "wiki links" {
    var it = wikiLinks("See [[Design notes|the design]] and [[api#Auth]], not [[\n]] or [[ ]].");
    try std.testing.expectEqualStrings("Design notes", it.next().?);
    try std.testing.expectEqualStrings("api", it.next().?);
    try std.testing.expect(it.next() == null);
}
