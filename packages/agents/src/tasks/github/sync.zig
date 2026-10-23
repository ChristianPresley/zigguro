//! Two-way sync between the task board and GitHub Issues
//! (E13.F03.S03.T02).
//!
//! - `pull` imports new open issues as tasks (`github: owner/repo#N`) and
//!   brings remote changes to linked tasks, asking only for issues updated
//!   since the last pull; an unchanged repository costs one 304.
//! - `push` sends local changes of linked tasks.
//! - `publish` creates an issue for a task. Only a person's explicit
//!   "Publish to GitHub" does this: neither pull nor push ever creates one.
//!
//! Each field merges three ways against the last state both sides agreed
//! on (`state.zig`): a change on one side goes to the other; a change on
//! both sides to different values is a conflict, sent for review
//! (`ConflictPort`, E12) and never overwritten. Label sets merge (what
//! either side added is in, what either removed is out). The mapping is in
//! `map.zig`.
//!
//! Network I/O runs on the caller's thread, never the UI thread.

const std = @import("std");
const zg_core = @import("zg_core");
const task_mod = @import("../task.zig");
const ids = @import("../ids.zig");
const TaskStore = @import("../store.zig");
const client_mod = @import("client.zig");
const types = @import("types.zig");
const map = @import("map.zig");
const state_mod = @import("state.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const GitHubClient = client_mod.GitHubClient;
const Repo = types.Repo;
const Issue = types.Issue;
const TaskId = task_mod.TaskId;
const Task = task_mod.Task;
const Fields = map.Fields;
const Base = state_mod.Base;
const IssueState = state_mod.IssueState;

pub const SyncConfig = struct {
    repo: Repo,
    /// Only issues with all these labels sync; published tasks get them.
    labels_filter: []const []const u8 = &.{},
    direction: enum { pull, push, both } = .both,
    interval_s: u32 = 300,
};

pub const SyncReport = struct {
    /// Tasks imported from issues.
    created: u32 = 0,
    updated_local: u32 = 0,
    updated_remote: u32 = 0,
    /// Fields changed on both sides (raised for review once each).
    conflicts: u32 = 0,
    /// Issues or tasks left alone: closed issues not yet imported, tasks
    /// deleted locally, issues deleted on GitHub (their tasks are unlinked).
    skipped: u32 = 0,
    requests: u32 = 0,

    fn add(r: *SyncReport, o: SyncReport) void {
        inline for (@typeInfo(SyncReport).@"struct".fields) |f| @field(r, f.name) += @field(o, f.name);
    }
};

/// One field changed on both sides.
pub const ConflictItem = struct {
    task: TaskId,
    /// Workspace-relative path of the task file.
    path: []const u8,
    number: u32,
    repo: Repo,
    /// `title`, `body`, `state` or `assignee`.
    field: []const u8,
    local: []const u8,
    remote: []const u8,
    /// The task file now, and with GitHub's value: accepting the review
    /// takes GitHub's side, rejecting keeps the local one.
    before: []const u8,
    after: []const u8,
};

/// E12: raises a conflict for review; returns the review item's id.
pub const ConflictPort = struct {
    ctx: *anyopaque,
    raise: *const fn (ctx: *anyopaque, c: ConflictItem) anyerror!u64,

    /// A conflict as an E12 changeset through the store's `ChangePort`.
    pub fn viaChanges(cp: *const TaskStore.ChangePort) ConflictPort {
        return .{ .ctx = @constCast(cp), .raise = changesRaise };
    }

    fn changesRaise(ctx: *anyopaque, c: ConflictItem) anyerror!u64 {
        const cp: *const TaskStore.ChangePort = @ptrCast(@alignCast(ctx));
        var buf: [512]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{s}/{s}#{d} and {s} both changed the {s}: accept to take GitHub's", .{
            c.repo.owner, c.repo.name, c.number, ids.format(c.task).slice(), c.field,
        }) catch "GitHub sync conflict";
        return cp.propose(cp.ctx, .{ .path = c.path, .before = c.before, .after = c.after, .run = .zero, .session = null, .summary = summary });
    }
};

pub const Options = struct {
    /// Checks that sync never runs on the UI thread.
    rt: ?*zg_core.Runtime = null,
    conflicts: ?ConflictPort = null,
};

pub const Error = error{
    /// The state belongs to another repository.
    RepoChanged,
    AlreadyLinked,
    TaskNotFound,
};

pub const Status = struct {
    repo: []const u8,
    linked: u32,
    last_pull_iso: ?[]const u8,
    /// Linked tasks with local changes not pushed yet.
    pending_push: u32,
    /// Conflicts waiting for review.
    conflicts: u32,
};

pub const SyncEngine = struct {
    gpa: Allocator,
    io: Io,
    client: *GitHubClient,
    store: *TaskStore,
    state_dir: Io.Dir,
    cfg: SyncConfig,
    o: Options,
    /// One operation at a time.
    mutex: Io.Mutex = .init,
    stop: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: Allocator, io: Io, client: *GitHubClient, store: *TaskStore, state_dir: Io.Dir, cfg: SyncConfig, o: Options) SyncEngine {
        return .{ .gpa = gpa, .io = io, .client = client, .store = store, .state_dir = state_dir, .cfg = cfg, .o = o };
    }

    /// Remote to local: imports new open issues and applies remote changes.
    pub fn pull(s: *SyncEngine) !SyncReport {
        return s.op(.pull, 0);
    }

    /// Local to remote, for linked tasks with local changes.
    pub fn push(s: *SyncEngine) !SyncReport {
        return s.op(.push, 0);
    }

    /// Creates an issue for task `id` and links it; the issue number.
    /// Only for a person's explicit "Publish to GitHub".
    pub fn publish(s: *SyncEngine, id: TaskId) !u32 {
        var rep: SyncReport = .{};
        _ = try s.opInto(.publish, id, &rep);
        return rep.created;
    }

    /// Pull then push, as configured.
    pub fn syncOnce(s: *SyncEngine) !SyncReport {
        var r: SyncReport = .{};
        if (s.cfg.direction != .push) r.add(try s.pull());
        if (s.cfg.direction != .pull) r.add(try s.push());
        return r;
    }

    /// The background loop: syncs every `interval_s` until `requestStop`.
    /// The client's pacing holds requests for `x-poll-interval` and rate
    /// limits. Run it on a worker.
    pub fn run(s: *SyncEngine) void {
        while (!s.stop.load(.acquire)) {
            _ = s.syncOnce() catch |e| if (e == error.Canceled) return;
            var waited: u32 = 0;
            while (waited < s.cfg.interval_s and !s.stop.load(.acquire)) : (waited += 1)
                s.io.sleep(.fromSeconds(1), .awake) catch return;
        }
    }

    pub fn requestStop(s: *SyncEngine) void {
        s.stop.store(true, .release);
    }

    /// What the state says, without the network. Strings in `a`.
    pub fn status(s: *SyncEngine, a: Allocator) !Status {
        const st = try state_mod.load(s.io, a, s.state_dir);
        var pending: u32 = 0;
        var conflicts: u32 = 0;
        for (st.issues) |e| {
            conflicts += @intCast(e.conflicts.len);
            const cur = s.localFields(a, e.task_id) catch continue orelse continue;
            if (localChanged(cur.fields, e.base)) pending += 1;
        }
        return .{
            .repo = if (st.repo.len > 0) st.repo else try repoText(a, s.cfg.repo),
            .linked = @intCast(st.issues.len),
            .last_pull_iso = st.last_pull_iso,
            .pending_push = pending,
            .conflicts = conflicts,
        };
    }

    const Kind = enum { pull, push, publish };

    fn op(s: *SyncEngine, kind: Kind, id: TaskId) !SyncReport {
        var rep: SyncReport = .{};
        _ = try s.opInto(kind, id, &rep);
        return rep;
    }

    fn opInto(s: *SyncEngine, kind: Kind, id: TaskId, rep: *SyncReport) !void {
        if (s.o.rt) |rt| rt.assertNotUi();
        s.mutex.lock(s.io) catch return error.Canceled;
        defer s.mutex.unlock(s.io);
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var st = try state_mod.load(s.io, a, s.state_dir);
        const repo_text = try repoText(a, s.cfg.repo);
        if (st.repo.len == 0) st.repo = repo_text;
        if (!std.ascii.eqlIgnoreCase(st.repo, repo_text)) return error.RepoChanged;
        var list: std.ArrayList(IssueState) = .empty;
        try list.appendSlice(a, st.issues);
        const before = s.client.requests.load(.monotonic);
        defer rep.requests = s.client.requests.load(.monotonic) - before;
        switch (kind) {
            .pull => try s.pullInto(a, &st, &list, rep),
            .push => try s.pushInto(a, &list, rep),
            .publish => rep.created = try s.publishInto(a, &list, id),
        }
        st.issues = list.items;
        try state_mod.save(s.io, a, s.state_dir, st);
    }

    // ---- pull ----

    fn pullInto(s: *SyncEngine, a: Allocator, st: *state_mod.SyncState, list: *std.ArrayList(IssueState), rep: *SyncReport) !void {
        const labels = if (s.cfg.labels_filter.len > 0) try std.mem.join(a, ",", s.cfg.labels_filter) else null;
        const since = st.list_since;
        var r = try s.client.listIssues(a, s.cfg.repo, .{ .since = since, .labels = labels }, if (since != null) st.list_etag else null);
        st.last_pull_iso = try nowIso(a, s.io);
        if (r == .not_modified) return;
        const first_etag = r.page.etag;
        var newest = since;
        while (true) {
            for (r.page.items) |*issue| {
                if (newest == null or std.mem.order(u8, issue.updated_at, newest.?) == .gt) newest = issue.updated_at;
                try s.pullIssue(a, list, issue, rep);
            }
            r = try s.client.nextPage(a, r.page.next_url orelse break);
            if (r == .not_modified) break;
        }
        // The ETag belongs to the URL just fetched: it serves the next pull
        // only when that asks with the same `since`.
        st.list_etag = if (optEql(newest, since)) first_etag else null;
        st.list_since = newest;
    }

    fn pullIssue(s: *SyncEngine, a: Allocator, list: *std.ArrayList(IssueState), issue: *const Issue, rep: *SyncReport) !void {
        const remote = try map.fromIssue(a, issue);
        const idx = for (list.items, 0..) |e, i| {
            if (e.number == issue.number) break i;
        } else null;
        const entry = if (idx) |i| &list.items[i] else blk: {
            if (try s.linkedTask(a, issue.number)) |id| {
                // Linked by hand: the local file is the starting point.
                const cur = try s.localFields(a, id) orelse return;
                try list.append(a, .{ .number = issue.number, .task_id = id, .base = try baseOf(a, cur.fields) });
                break :blk &list.items[list.items.len - 1];
            }
            if (remote.state != .open) {
                rep.skipped += 1;
                return;
            }
            const id = try s.import(a, issue, remote);
            try list.append(a, .{ .number = issue.number, .task_id = id, .base = try baseOf(a, remote) });
            rep.created += 1;
            return;
        };
        const cur = try s.localFields(a, entry.task_id) orelse {
            rep.skipped += 1;
            return;
        };
        try s.reconcile(a, entry, cur, remote, false, rep);
    }

    fn import(s: *SyncEngine, a: Allocator, issue: *const Issue, f: Fields) !TaskId {
        const made = try s.store.create(.{
            .title = if (f.title.len > 0) f.title else try std.fmt.allocPrint(a, "Issue {d}", .{issue.number}),
            .status = map.SyncState.open.toStatus(.backlog),
            .labels = f.labels,
            .assignee = f.assignee,
            .body = if (f.body.len > 0) try std.mem.concat(a, u8, &.{ f.body, "\n" }) else "",
        }, .user);
        _ = try s.store.update(made.id, .{ .github = try map.linkText(a, s.cfg.repo, issue.number) }, .user);
        return made.id;
    }

    // ---- push ----

    fn pushInto(s: *SyncEngine, a: Allocator, list: *std.ArrayList(IssueState), rep: *SyncReport) !void {
        var i: usize = 0;
        while (i < list.items.len) {
            const entry = &list.items[i];
            const cur = try s.localFields(a, entry.task_id) orelse {
                rep.skipped += 1;
                i += 1;
                continue;
            };
            if (!localChanged(cur.fields, entry.base)) {
                i += 1;
                continue;
            }
            const got = s.client.getIssue(a, s.cfg.repo, entry.number, null) catch |e| switch (e) {
                error.NotFound, error.Gone => {
                    // Deleted or transferred on GitHub: unlink, keep the task.
                    _ = try s.store.update(entry.task_id, .{ .github = @as(?[]const u8, null) }, .user);
                    _ = list.orderedRemove(i);
                    rep.skipped += 1;
                    continue;
                },
                else => return e,
            };
            entry.etag = got.found.etag;
            try s.reconcile(a, entry, cur, try map.fromIssue(a, &got.found.issue), true, rep);
            i += 1;
        }
    }

    // ---- publish ----

    fn publishInto(s: *SyncEngine, a: Allocator, list: *std.ArrayList(IssueState), id: TaskId) !u32 {
        const cur = try s.localFields(a, id) orelse return error.TaskNotFound;
        if (cur.task.github) |g| if (map.parseLink(g, s.cfg.repo) != null) return error.AlreadyLinked;
        for (list.items) |e| if (e.task_id == id) return error.AlreadyLinked;
        var labels: std.ArrayList([]const u8) = .empty;
        try labels.appendSlice(a, cur.fields.labels);
        try labels.appendSlice(a, s.cfg.labels_filter);
        const label_set = try map.labelSet(a, labels.items);
        var issue = try s.client.createIssue(a, s.cfg.repo, .{
            .title = cur.fields.title,
            .body = cur.fields.body,
            .labels = label_set,
            .assignees = if (cur.fields.assignee) |x| try a.dupe([]const u8, &.{x}) else null,
        });
        if (cur.fields.state != .open) {
            const sf = cur.fields.state.issueFields();
            issue = try s.client.updateIssue(a, s.cfg.repo, issue.number, .{ .state = sf.state, .state_reason = sf.reason });
        }
        _ = try s.store.update(id, .{
            .github = try map.linkText(a, s.cfg.repo, issue.number),
            .labels = if (map.labelsEqual(label_set, cur.fields.labels)) null else label_set,
        }, .user);
        const now = (try s.localFields(a, id)).?;
        try list.append(a, .{ .number = issue.number, .task_id = id, .base = try agreed(a, now.fields, try map.fromIssue(a, &issue), .{}) });
        return issue.number;
    }

    // ---- the merge ----

    const Local = struct { task: Task, bytes: []const u8, fields: Fields };

    /// Task `id`'s synced fields, or null when it no longer exists.
    fn localFields(s: *SyncEngine, a: Allocator, id: TaskId) !?Local {
        const t = blk: {
            const v = s.store.view();
            defer s.store.release(v);
            const t = v.get(id) orelse return null;
            break :blk try t.clone(a);
        };
        const bytes = s.store.dir.readFileAlloc(s.io, t.path, a, .limited(16 << 20)) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        return .{ .task = t, .bytes = bytes, .fields = try map.fromTask(a, &t, bytes) };
    }

    fn linkedTask(s: *SyncEngine, a: Allocator, number: u32) !?TaskId {
        _ = a;
        const v = s.store.view();
        defer s.store.release(v);
        for (v.tasks) |*t| if (t.github) |g| if (map.parseLink(g, s.cfg.repo) == number) return t.id;
        return null;
    }

    /// Merges `cur` and `remote` against `entry.base`: applies remote-only
    /// changes locally, raises conflicts, and (when `send`) PATCHes
    /// local-only changes. Updates the base to what both sides now agree on.
    fn reconcile(s: *SyncEngine, a: Allocator, entry: *IssueState, cur: Local, remote: Fields, send: bool, rep: *SyncReport) !void {
        const b = entry.base;
        const l = cur.fields;
        const agent_assignee = if (cur.task.assignee) |x| map.isAgent(x) else false;
        var patch: TaskStore.TaskPatch = .{};
        var write: types.IssueWrite = .{};
        var conflicts: std.ArrayList([]const u8) = .empty;
        var next_l = l;

        switch (map.decide(map.hash(l.title) != b.title_hash, map.hash(remote.title) != b.title_hash, std.mem.eql(u8, l.title, remote.title))) {
            .same => {},
            .take_remote => next_l.title = remote.title,
            .take_local => write.title = l.title,
            .conflict => try conflicts.append(a, "title"),
        }
        switch (map.decide(map.hash(l.body) != b.body_hash, map.hash(remote.body) != b.body_hash, std.mem.eql(u8, l.body, remote.body))) {
            .same => {},
            .take_remote => next_l.body = remote.body,
            .take_local => write.body = l.body,
            .conflict => try conflicts.append(a, "body"),
        }
        switch (map.decide(l.state != b.state, remote.state != b.state, l.state == remote.state)) {
            .same => {},
            .take_remote => next_l.state = remote.state,
            .take_local => {
                const sf = l.state.issueFields();
                write.state = sf.state;
                write.state_reason = sf.reason;
            },
            .conflict => try conflicts.append(a, "state"),
        }
        const merged = try map.mergeLabels(a, b.labels, l.labels, remote.labels);
        next_l.labels = merged;
        if (!map.labelsEqual(merged, remote.labels)) write.labels = merged;
        if (!agent_assignee) switch (map.decide(!map.optEqual(l.assignee, b.assignee), !map.optEqual(remote.assignee, b.assignee), map.optEqual(l.assignee, remote.assignee))) {
            .same => {},
            .take_remote => next_l.assignee = remote.assignee,
            .take_local => write.assignees = if (l.assignee) |x| try a.dupe([]const u8, &.{x}) else &.{},
            .conflict => try conflicts.append(a, "assignee"),
        };

        // Local changes from GitHub.
        if (!std.mem.eql(u8, next_l.title, l.title)) patch.title = next_l.title;
        if (!std.mem.eql(u8, next_l.title, l.title) or !std.mem.eql(u8, next_l.body, l.body))
            patch.body = try map.composeBody(a, cur.bytes, next_l.title, next_l.body);
        if (next_l.state != l.state) patch.status = next_l.state.toStatus(cur.task.status);
        if (!map.labelsEqual(next_l.labels, l.labels)) patch.labels = next_l.labels;
        if (!map.optEqual(next_l.assignee, l.assignee)) patch.assignee = next_l.assignee;
        if (!isEmptyPatch(patch)) {
            _ = try s.store.update(entry.task_id, patch, .user);
            rep.updated_local += 1;
        }

        // Conflicts, each raised once per remote value.
        var kept: std.ArrayList(state_mod.Conflict) = .empty;
        for (conflicts.items) |field| {
            const rv = try fieldText(a, remote, field);
            const rh = map.hash(rv);
            const known = for (entry.conflicts) |c| {
                if (std.mem.eql(u8, c.field, field) and c.remote_hash == rh) break c;
            } else null;
            rep.conflicts += 1;
            if (known) |c| {
                try kept.append(a, c);
                continue;
            }
            const review = try s.raise(a, entry, cur, remote, field, try fieldText(a, l, field), rv);
            try kept.append(a, .{ .field = field, .remote_hash = rh, .review = review });
        }
        entry.conflicts = kept.items;

        var remote_now = remote;
        if (send and !isEmptyWrite(write)) {
            const updated = try s.client.updateIssue(a, s.cfg.repo, entry.number, write);
            remote_now = try map.fromIssue(a, &updated);
            rep.updated_remote += 1;
        }
        entry.base = try agreed(a, next_l, remote_now, b);
    }

    fn raise(s: *SyncEngine, a: Allocator, entry: *const IssueState, cur: Local, remote: Fields, field: []const u8, local_text: []const u8, remote_text: []const u8) !u64 {
        const port = s.o.conflicts orelse return 0;
        var patch: TaskStore.TaskPatch = .{};
        if (std.mem.eql(u8, field, "title")) {
            patch.title = remote.title;
            patch.body = try map.composeBody(a, cur.bytes, remote.title, cur.fields.body);
        } else if (std.mem.eql(u8, field, "body")) {
            patch.body = try map.composeBody(a, cur.bytes, cur.fields.title, remote.body);
        } else if (std.mem.eql(u8, field, "state")) {
            patch.status = remote.state.toStatus(cur.task.status);
        } else {
            patch.assignee = remote.assignee;
        }
        const r = try s.store.render(a, entry.task_id, patch);
        return port.raise(port.ctx, .{
            .task = entry.task_id,
            .path = try std.fmt.allocPrint(a, "{s}/{s}", .{ s.store.o.dir_rel, r.name }),
            .number = entry.number,
            .repo = s.cfg.repo,
            .field = field,
            .local = local_text,
            .remote = remote_text,
            .before = r.before,
            .after = r.after,
        });
    }
};

/// Whether the local side moved away from the base.
fn localChanged(l: Fields, b: Base) bool {
    return map.hash(l.title) != b.title_hash or map.hash(l.body) != b.body_hash or l.state != b.state or
        !map.labelsEqual(l.labels, b.labels) or !map.optEqual(l.assignee, b.assignee);
}

/// The new base: each field where both sides now agree, else the old base.
fn agreed(a: Allocator, l: Fields, r: Fields, old: Base) !Base {
    return .{
        .title_hash = if (std.mem.eql(u8, l.title, r.title)) map.hash(l.title) else old.title_hash,
        .body_hash = if (std.mem.eql(u8, l.body, r.body)) map.hash(l.body) else old.body_hash,
        .state = if (l.state == r.state) l.state else old.state,
        .labels = if (map.labelsEqual(l.labels, r.labels)) try dupeList(a, l.labels) else old.labels,
        .assignee = if (map.optEqual(l.assignee, r.assignee)) l.assignee else old.assignee,
    };
}

fn baseOf(a: Allocator, f: Fields) !Base {
    return agreed(a, f, f, .{});
}

fn dupeList(a: Allocator, xs: []const []const u8) ![]const []const u8 {
    return a.dupe([]const u8, xs);
}

fn fieldText(a: Allocator, f: Fields, field: []const u8) ![]const u8 {
    if (std.mem.eql(u8, field, "title")) return f.title;
    if (std.mem.eql(u8, field, "body")) return f.body;
    if (std.mem.eql(u8, field, "state")) return @tagName(f.state);
    _ = a;
    return f.assignee orelse "";
}

fn isEmptyPatch(p: TaskStore.TaskPatch) bool {
    return p.title == null and p.body == null and p.status == null and p.labels == null and p.assignee == null;
}

fn isEmptyWrite(w: types.IssueWrite) bool {
    return w.title == null and w.body == null and w.state == null and w.labels == null and w.assignees == null;
}

fn optEql(x: ?[]const u8, y: ?[]const u8) bool {
    return map.optEqual(x, y);
}

fn repoText(a: Allocator, r: Repo) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ r.owner, r.name });
}

fn nowIso(a: Allocator, io: Io) ![]const u8 {
    const secs: u64 = @intCast(@max(0, @divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s)));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}
