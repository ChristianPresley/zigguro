//! The task store (E13.F03.S01.T01): the files of `.zigguro/tasks`,
//! parsed in parallel into immutable `TasksView`s, written back
//! byte-preservingly, and the events their changes make.
//!
//! Writes by people (`via = .user`) go to the editor when the file is
//! open there (`DocumentPort`, so undo works) and otherwise replace the
//! file atomically. Writes by agents become E12 changesets for review
//! (`ChangePort`), except edits that touch only the auto-applied fields
//! (default `status` and `claimed_by`), which are written directly.
//! External changes reach the store through `fileChanged` (the E08 bus
//! adapter) or `rescan`.

const std = @import("std");
const zg_frontmatter = @import("zg_frontmatter");
const runs = @import("../runs/root.zig");
const task_mod = @import("task.zig");
const ids = @import("ids.zig");
const view_mod = @import("view.zig");
const deps = @import("deps.zig");
const events = @import("events.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const fm = zg_frontmatter.frontmatter;
const fm_writer = zg_frontmatter.fm_writer;

pub const Task = task_mod.Task;
pub const TaskId = task_mod.TaskId;
pub const Status = task_mod.Status;
pub const Date = task_mod.Date;
pub const TasksView = view_mod.TasksView;
pub const TaskEvent = events.TaskEvent;
pub const Listener = events.Listener;

pub const dir_default = ".zigguro/tasks";
pub const state_default = ".zigguro/state";
pub const trash_dir = ".trash";

pub const WriteVia = union(enum) {
    user,
    agent: struct { run: runs.RunId, session: ?u128 = null },
};

pub const NewTask = struct {
    title: []const u8,
    status: Status = .backlog,
    priority: u2 = 2,
    assignee: ?[]const u8 = null,
    labels: []const []const u8 = &.{},
    depends_on: []const TaskId = &.{},
    due: ?Date = null,
    body: []const u8 = "",
};

/// Null leaves a field alone; for optional fields `@as(?T, null)` clears.
pub const TaskPatch = struct {
    status: ?Status = null,
    priority: ?u2 = null,
    assignee: ??[]const u8 = null,
    labels: ?[]const []const u8 = null,
    depends_on: ?[]const TaskId = null,
    due: ??Date = null,
    title: ?[]const u8 = null,
    /// Replaces everything after the frontmatter.
    body: ?[]const u8 = null,
    rank: ??[]const u8 = null,
    claimed_by: ??[]const u8 = null,
    github: ??[]const u8 = null,
};

/// What a write did.
pub const Outcome = union(enum) {
    /// The file changed (or the editor has the change).
    applied,
    /// An E12 changeset waits for review.
    changeset: u64,
};

/// E12: proposes a file change as a reviewable changeset.
pub const ChangePort = struct {
    ctx: *anyopaque,
    propose: *const fn (ctx: *anyopaque, req: ChangeRequest) anyerror!u64,
};

pub const ChangeRequest = struct {
    /// Workspace-relative, `/`-separated.
    path: []const u8,
    /// Null for a new file.
    before: ?[]const u8,
    /// Null for a deletion.
    after: ?[]const u8,
    run: runs.RunId,
    session: ?u128,
    summary: []const u8,
};

/// E05: applies new bytes to the file's open document, if there is one.
pub const DocumentPort = struct {
    ctx: *anyopaque,
    /// False when the file is not open (the store writes it then).
    apply: *const fn (ctx: *anyopaque, path: []const u8, bytes: []const u8) anyerror!bool,
};

pub const Clock = struct {
    ctx: ?*anyopaque = null,
    nowRealMs: *const fn (ctx: ?*anyopaque) i64,
};

pub const Options = struct {
    dir_rel: []const u8 = dir_default,
    state_rel: []const u8 = state_default,
    changes: ?ChangePort = null,
    documents: ?DocumentPort = null,
    /// Properties agents may change without review (E16 policy
    /// `agents.tasks.auto_apply_fields`).
    auto_apply: []const []const u8 = &.{ task_mod.props.status, task_mod.props.claimed_by },
    clock: ?Clock = null,
    /// Files parsed per parallel batch.
    batch: u32 = 256,
};

pub const Error = error{ TaskNotFound, ReviewUnavailable, InvalidTask } || Allocator.Error;

const Entry = struct {
    arena: *std.heap.ArenaAllocator,
    task: Task,
};

const TaskStore = @This();

gpa: Allocator,
io: Io,
ws: Io.Dir,
dir: Io.Dir,
state: Io.Dir,
o: Options,
mutex: Io.Mutex = .init,
files: std.StringArrayHashMapUnmanaged(Entry) = .empty,
current: *TasksView,
version: u64 = 0,
next_id: TaskId = 1,
listeners: events.Listeners = .{},

/// Opens (creating) the tasks directory under `ws` and indexes it.
pub fn open(gpa: Allocator, io: Io, ws: Io.Dir, o: Options) !*TaskStore {
    const s = try gpa.create(TaskStore);
    errdefer gpa.destroy(s);
    const dir = try ws.createDirPathOpen(io, o.dir_rel, .{ .open_options = .{ .iterate = true } });
    errdefer dir.close(io);
    const state = try ws.createDirPathOpen(io, o.state_rel, .{});
    errdefer state.close(io);
    s.* = .{ .gpa = gpa, .io = io, .ws = ws, .dir = dir, .state = state, .o = o, .current = try TasksView.build(gpa, &.{}, 0) };
    s.next_id = ids.loadNext(io, state);
    try s.rescan();
    return s;
}

pub fn close(s: *TaskStore) void {
    s.clearFiles();
    s.files.deinit(s.gpa);
    s.release(s.current);
    s.listeners.deinit(s.gpa);
    s.dir.close(s.io);
    s.state.close(s.io);
    s.gpa.destroy(s);
}

fn clearFiles(s: *TaskStore) void {
    for (s.files.keys(), s.files.values()) |k, e| {
        s.gpa.free(k);
        e.arena.deinit();
        s.gpa.destroy(e.arena);
    }
    s.files.clearRetainingCapacity();
}

/// The current view; `release` it when done.
pub fn view(s: *TaskStore) *const TasksView {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    _ = s.current.refs.fetchAdd(1, .monotonic);
    return s.current;
}

pub fn release(s: *TaskStore, v: *const TasksView) void {
    _ = s;
    const mv: *TasksView = @constCast(v);
    if (mv.refs.fetchSub(1, .acq_rel) == 1) mv.destroy();
}

pub fn subscribe(s: *TaskStore, l: Listener) !events.ListenerId {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.listeners.add(s.gpa, l);
}

pub fn unsubscribe(s: *TaskStore, id: events.ListenerId) void {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    s.listeners.remove(id);
}

// ---- indexing ----

const Parsed = struct {
    name: []const u8,
    entry: ?Entry = null,
    err: bool = false,
};

/// Re-reads every task file (in parallel batches).
pub fn rescan(s: *TaskStore) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| s.gpa.free(n);
        names.deinit(s.gpa);
    }
    var it = s.dir.iterate();
    while (try it.next(s.io)) |e| {
        if (e.kind != .file or !isTaskFile(e.name)) continue;
        try names.append(s.gpa, try s.gpa.dupe(u8, e.name));
    }
    const parsed = try s.gpa.alloc(Parsed, names.items.len);
    defer s.gpa.free(parsed);
    for (parsed, names.items) |*p, n| p.* = .{ .name = n };
    var i: usize = 0;
    while (i < parsed.len) {
        const end = @min(parsed.len, i + s.o.batch);
        var g: Io.Group = .init;
        for (parsed[i..end]) |*p| g.async(s.io, parseOne, .{ s, p });
        g.await(s.io) catch {};
        i = end;
    }
    var new_files: std.StringArrayHashMapUnmanaged(Entry) = .empty;
    errdefer {
        for (new_files.keys(), new_files.values()) |k, e| {
            s.gpa.free(k);
            e.arena.deinit();
            s.gpa.destroy(e.arena);
        }
        new_files.deinit(s.gpa);
    }
    var failed = false;
    for (parsed) |*p| {
        const e = p.entry orelse {
            failed = failed or p.err;
            continue;
        };
        p.entry = null;
        try new_files.put(s.gpa, try s.gpa.dupe(u8, p.name), e);
    }
    s.mutex.lockUncancelable(s.io);
    const old_view = s.current;
    _ = old_view.refs.fetchAdd(1, .monotonic);
    defer s.release(old_view);
    s.clearFiles();
    s.files.deinit(s.gpa);
    s.files = new_files;
    new_files = .empty;
    const nv = s.rebuildLocked() catch |e| {
        s.mutex.unlock(s.io);
        return e;
    };
    s.mutex.unlock(s.io);
    s.notify(old_view, nv, null);
    if (failed) return error.OutOfMemory;
}

fn parseOne(s: *TaskStore, p: *Parsed) void {
    p.entry = s.readEntry(p.name) catch |e| {
        p.err = e == error.OutOfMemory;
        return;
    };
}

fn readEntry(s: *TaskStore, name: []const u8) !Entry {
    const arena = try s.gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(s.gpa);
    errdefer {
        arena.deinit();
        s.gpa.destroy(arena);
    }
    const a = arena.allocator();
    const f = try s.dir.openFile(s.io, name, .{});
    defer f.close(s.io);
    var buf: [4096]u8 = undefined;
    var r = f.reader(s.io, &buf);
    const bytes = try a.alloc(u8, task_mod.index_read_bytes);
    const n = try r.interface.readSliceShort(bytes);
    const t = try task_mod.parse(a, try a.dupe(u8, name), bytes[0..n]);
    return .{ .arena = arena, .task = t };
}

/// One file changed on disk (`rel` is workspace-relative, either
/// separator). Files outside the tasks directory are ignored.
pub fn fileChanged(s: *TaskStore, rel: []const u8) !void {
    var buf: [1024]u8 = undefined;
    if (rel.len > buf.len) return;
    for (rel, 0..) |c, i| buf[i] = if (c == '\\') '/' else c;
    const p = buf[0..rel.len];
    if (!std.mem.startsWith(u8, p, s.o.dir_rel) or p.len <= s.o.dir_rel.len + 1 or p[s.o.dir_rel.len] != '/') return;
    const name = p[s.o.dir_rel.len + 1 ..];
    if (std.mem.indexOfScalar(u8, name, '/') != null or !isTaskFile(name)) return;
    try s.reloadFile(name);
}

/// Re-reads one file of the tasks directory (removed if gone).
pub fn reloadFile(s: *TaskStore, name: []const u8) !void {
    const entry: ?Entry = s.readEntry(name) catch |e| switch (e) {
        error.FileNotFound => null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return e,
    };
    s.mutex.lockUncancelable(s.io);
    const old_view = s.current;
    _ = old_view.refs.fetchAdd(1, .monotonic);
    defer s.release(old_view);
    if (s.files.fetchSwapRemove(name)) |kv| {
        s.gpa.free(kv.key);
        kv.value.arena.deinit();
        s.gpa.destroy(kv.value.arena);
    }
    if (entry) |e| {
        const key = s.gpa.dupe(u8, name) catch |err| {
            e.arena.deinit();
            s.gpa.destroy(e.arena);
            s.mutex.unlock(s.io);
            return err;
        };
        s.files.put(s.gpa, key, e) catch |err| {
            s.gpa.free(key);
            e.arena.deinit();
            s.gpa.destroy(e.arena);
            s.mutex.unlock(s.io);
            return err;
        };
    }
    const nv = s.rebuildLocked() catch |e| {
        s.mutex.unlock(s.io);
        return e;
    };
    s.mutex.unlock(s.io);
    s.notify(old_view, nv, null);
}

/// Builds and installs a new view from `files`; returns it with a
/// reference for the caller's notifications.
fn rebuildLocked(s: *TaskStore) !*TasksView {
    const list = try s.gpa.alloc(Task, s.files.count());
    defer s.gpa.free(list);
    for (list, s.files.values()) |*d, e| d.* = e.task;
    s.version += 1;
    const nv = try TasksView.build(s.gpa, list, s.version);
    const old = s.current;
    s.current = nv;
    _ = nv.refs.fetchAdd(1, .monotonic);
    s.release(old);
    return nv;
}

/// Emits the differences between two views, then drops `nv`'s extra
/// reference.
fn notify(s: *TaskStore, old: *const TasksView, nv: *TasksView, via: ?WriteVia) void {
    defer s.release(nv);
    _ = via;
    var list: std.ArrayList(TaskEvent) = .empty;
    defer list.deinit(s.gpa);
    events.diff(s.gpa, old, nv, &list) catch return;
    if (list.items.len == 0) return;
    var copy: std.ArrayList(Listener) = .empty;
    defer copy.deinit(s.gpa);
    {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        copy.appendSlice(s.gpa, s.listeners.items()) catch return;
    }
    for (list.items) |ev| for (copy.items) |l| l.f(l.ctx, ev, nv);
}

fn isTaskFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".md") and name[0] != '.';
}

// ---- writes ----

pub fn create(s: *TaskStore, t: NewTask, via: WriteVia) !struct { id: TaskId, outcome: Outcome } {
    if (std.mem.trim(u8, t.title, " \t\r\n").len == 0) return error.InvalidTask;
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const id = blk: {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const id = @max(s.next_id, s.current.maxId() + 1);
        s.next_id = id + 1;
        ids.saveNext(s.io, s.state, s.next_id) catch {};
        break :blk id;
    };
    const idf = ids.format(id);
    const eol = "\n";
    const seed = try std.fmt.allocPrint(a, "# {s}{s}{s}{s}", .{ oneLine(t.title), eol, if (t.body.len > 0) eol else "", t.body });
    var edits: std.ArrayList(fm_writer.PropEdit) = .empty;
    try edits.append(a, .{ .set = .{ .name = task_mod.props.id, .value = .{ .string = idf.slice() } } });
    try edits.append(a, .{ .set = .{ .name = task_mod.props.title, .value = .{ .string = oneLine(t.title) } } });
    try edits.append(a, .{ .set = .{ .name = task_mod.props.status, .value = .{ .string = @tagName(t.status) } } });
    try edits.append(a, .{ .set = .{ .name = task_mod.props.priority, .value = .{ .string = priorityText(t.priority) } } });
    if (t.assignee) |x| try edits.append(a, .{ .set = .{ .name = task_mod.props.assignee, .value = .{ .string = x } } });
    if (t.labels.len > 0) try edits.append(a, .{ .set = .{ .name = task_mod.props.labels, .value = try stringListValue(a, t.labels) } });
    if (t.depends_on.len > 0) try edits.append(a, .{ .set = .{ .name = task_mod.props.depends_on, .value = try idListValue(a, t.depends_on) } });
    if (t.due) |d| try edits.append(a, .{ .set = .{ .name = task_mod.props.due, .value = .{ .date = d } } });
    try edits.append(a, .{ .set = .{ .name = task_mod.props.created, .value = .{ .datetime = s.nowDateTime() } } });
    const bytes = try fm_writer.applyPropEdits(a, seed, edits.items);
    const name = try ids.fileName(a, id, t.title);
    switch (via) {
        .user => {
            try s.writeFile(name, bytes);
            try s.reloadFile(name);
            return .{ .id = id, .outcome = .applied };
        },
        .agent => |ag| {
            const cp = s.o.changes orelse return error.ReviewUnavailable;
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ s.o.dir_rel, name });
            const summary = try std.fmt.allocPrint(a, "Create task {s}: {s}", .{ idf.slice(), oneLine(t.title) });
            const cs = try cp.propose(cp.ctx, .{ .path = path, .before = null, .after = bytes, .run = ag.run, .session = ag.session, .summary = summary });
            return .{ .id = id, .outcome = .{ .changeset = cs } };
        },
    }
}

pub fn update(s: *TaskStore, id: TaskId, p: TaskPatch, via: WriteVia) !Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const name = try s.pathOf(a, id);
    const before = try s.dir.readFileAlloc(s.io, name, a, .limited(16 << 20));
    var edits: std.ArrayList(fm_writer.PropEdit) = .empty;
    var fields: std.ArrayList([]const u8) = .empty;
    const P = task_mod.props;
    if (p.status) |x| try setEdit(a, &edits, &fields, P.status, .{ .string = @tagName(x) });
    if (p.priority) |x| try setEdit(a, &edits, &fields, P.priority, .{ .string = priorityText(x) });
    if (p.assignee) |x| try optEdit(a, &edits, &fields, P.assignee, if (x) |v| fm.Value{ .string = v } else null);
    if (p.labels) |x| try setEdit(a, &edits, &fields, P.labels, try stringListValue(a, x));
    if (p.depends_on) |x| try setEdit(a, &edits, &fields, P.depends_on, try idListValue(a, x));
    if (p.due) |x| try optEdit(a, &edits, &fields, P.due, if (x) |d| fm.Value{ .date = d } else null);
    if (p.title) |x| try setEdit(a, &edits, &fields, P.title, .{ .string = oneLine(x) });
    if (p.rank) |x| try optEdit(a, &edits, &fields, P.rank, if (x) |v| fm.Value{ .string = v } else null);
    if (p.claimed_by) |x| try optEdit(a, &edits, &fields, P.claimed_by, if (x) |v| fm.Value{ .string = v } else null);
    if (p.github) |x| try optEdit(a, &edits, &fields, P.github, if (x) |v| fm.Value{ .string = v } else null);
    var after = try fm_writer.applyPropEdits(a, before, edits.items);
    if (p.body) |b| {
        try fields.append(a, "body");
        const loc = fm.findFrontmatter(after);
        const head = if (loc) |l| after[0..l.block[1]] else "";
        after = try std.mem.concat(a, u8, &.{ head, b });
    }
    if (std.mem.eql(u8, before, after)) return .applied;
    return s.write(a, id, name, before, after, fields.items, via);
}

/// Moves the file to `.zigguro/tasks/.trash/` (people) or proposes its
/// deletion (agents).
pub fn delete(s: *TaskStore, id: TaskId, via: WriteVia) !Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const name = try s.pathOf(a, id);
    switch (via) {
        .user => {
            try s.dir.createDirPath(s.io, trash_dir);
            const to = try std.fmt.allocPrint(a, "{s}/{s}", .{ trash_dir, name });
            try s.dir.rename(name, s.dir, to, s.io);
            try s.reloadFile(name);
            return .applied;
        },
        .agent => |ag| {
            const cp = s.o.changes orelse return error.ReviewUnavailable;
            const before = try s.dir.readFileAlloc(s.io, name, a, .limited(16 << 20));
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ s.o.dir_rel, name });
            const summary = try std.fmt.allocPrint(a, "Delete task {s}", .{ids.format(id).slice()});
            return .{ .changeset = try cp.propose(cp.ctx, .{ .path = path, .before = before, .after = null, .run = ag.run, .session = ag.session, .summary = summary }) };
        },
    }
}

/// Moves a task the user deleted back from the trash (the board's undo).
pub fn restore(s: *TaskStore, id: TaskId) !void {
    var trash = s.dir.openDir(s.io, trash_dir, .{ .iterate = true }) catch return error.TaskNotFound;
    defer trash.close(s.io);
    var it = trash.iterate();
    const idf = ids.format(id);
    var name_buf: [256]u8 = undefined;
    const name = while (try it.next(s.io)) |e| {
        if (e.kind != .file or !isTaskFile(e.name) or e.name.len > name_buf.len) continue;
        const rest = if (std.mem.startsWith(u8, e.name, idf.slice())) e.name[idf.slice().len..] else continue;
        if (rest.len > 0 and rest[0] != '-' and rest[0] != '.') continue;
        @memcpy(name_buf[0..e.name.len], e.name);
        break name_buf[0..e.name.len];
    } else return error.TaskNotFound;
    try trash.rename(name, s.dir, name, s.io);
    try s.reloadFile(name);
}

fn write(s: *TaskStore, a: Allocator, id: TaskId, name: []const u8, before: []const u8, after: []const u8, fields: []const []const u8, via: WriteVia) !Outcome {
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ s.o.dir_rel, name });
    switch (via) {
        .user => {
            const in_editor = if (s.o.documents) |d| try d.apply(d.ctx, path, after) else false;
            if (!in_editor) try s.writeFile(name, after);
            // The editor's save reaches us as a file event; index the
            // change now either way.
            if (in_editor) try s.reloadWith(name, after) else try s.reloadFile(name);
            return .applied;
        },
        .agent => |ag| {
            if (s.autoApplies(fields)) {
                try s.writeFile(name, after);
                try s.reloadFile(name);
                return .applied;
            }
            const cp = s.o.changes orelse return error.ReviewUnavailable;
            const summary = try std.fmt.allocPrint(a, "Update task {s} ({s})", .{ ids.format(id).slice(), try std.mem.join(a, ", ", fields) });
            return .{ .changeset = try cp.propose(cp.ctx, .{ .path = path, .before = before, .after = after, .run = ag.run, .session = ag.session, .summary = summary }) };
        },
    }
}

fn autoApplies(s: *const TaskStore, fields: []const []const u8) bool {
    for (fields) |f| {
        const ok = for (s.o.auto_apply) |x| {
            if (std.mem.eql(u8, x, f)) break true;
        } else false;
        if (!ok) return false;
    }
    return fields.len > 0;
}

fn writeFile(s: *TaskStore, name: []const u8, bytes: []const u8) !void {
    var af = try s.dir.createFileAtomic(s.io, name, .{ .replace = true });
    defer af.deinit(s.io);
    try af.file.writeStreamingAll(s.io, bytes);
    try af.replace(s.io);
}

/// Indexes `bytes` as the content of `name` (an editor holds the change).
fn reloadWith(s: *TaskStore, name: []const u8, bytes: []const u8) !void {
    const arena = try s.gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(s.gpa);
    var owned = true;
    defer if (owned) {
        arena.deinit();
        s.gpa.destroy(arena);
    };
    const a = arena.allocator();
    const head = bytes[0..@min(bytes.len, task_mod.index_read_bytes)];
    const t = try task_mod.parse(a, try a.dupe(u8, name), try a.dupe(u8, head));
    s.mutex.lockUncancelable(s.io);
    const old_view = s.current;
    _ = old_view.refs.fetchAdd(1, .monotonic);
    defer s.release(old_view);
    const gp = s.files.getOrPut(s.gpa, name) catch |e| {
        s.mutex.unlock(s.io);
        return e;
    };
    if (gp.found_existing) {
        gp.value_ptr.arena.deinit();
        s.gpa.destroy(gp.value_ptr.arena);
    } else {
        gp.key_ptr.* = s.gpa.dupe(u8, name) catch |e| {
            s.files.swapRemoveAt(gp.index);
            s.mutex.unlock(s.io);
            return e;
        };
    }
    gp.value_ptr.* = .{ .arena = arena, .task = t };
    owned = false;
    const nv = s.rebuildLocked() catch |e| {
        s.mutex.unlock(s.io);
        return e;
    };
    s.mutex.unlock(s.io);
    s.notify(old_view, nv, null);
}

fn pathOf(s: *TaskStore, a: Allocator, id: TaskId) ![]const u8 {
    const v = s.view();
    defer s.release(v);
    const t = v.get(id) orelse return error.TaskNotFound;
    return a.dupe(u8, t.path);
}

fn nowDateTime(s: *const TaskStore) fm.DateTime {
    const ms = if (s.o.clock) |c| c.nowRealMs(c.ctx) else @as(i64, @intCast(@divFloor(Io.Clock.real.now(s.io).nanoseconds, std.time.ns_per_ms)));
    const secs = @divFloor(ms, 1000);
    const days = @divFloor(secs, 86_400);
    const rem: u32 = @intCast(secs - days * 86_400);
    const z = @import("../sched/zone.zig").civilFromDays(days);
    return .{ .date = .{ .y = z.year, .m = z.month, .d = z.day }, .h = @intCast(rem / 3600), .min = @intCast(rem / 60 % 60), .s = @intCast(rem % 60), .utc_offset_s = 0 };
}

/// Today in UTC, for `due:` queries.
pub fn today(s: *const TaskStore) Date {
    return s.nowDateTime().date;
}

fn oneLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    return t[0 .. std.mem.indexOfAny(u8, t, "\r\n") orelse t.len];
}

fn priorityText(p: u2) []const u8 {
    return switch (p) {
        0 => "P0",
        1 => "P1",
        2 => "P2",
        3 => "P3",
    };
}

fn stringListValue(a: Allocator, list: []const []const u8) !fm.Value {
    const nodes = try a.alloc(fm.Node, list.len);
    for (nodes, list) |*n, s| n.* = .{ .value = .{ .string = s }, .src = .{ 0, 0 }, .style = .plain };
    return .{ .list = nodes };
}

fn idListValue(a: Allocator, list: []const TaskId) !fm.Value {
    const nodes = try a.alloc(fm.Node, list.len);
    for (nodes, list) |*n, id| n.* = .{ .value = .{ .string = try a.dupe(u8, ids.format(id).slice()) }, .src = .{ 0, 0 }, .style = .plain };
    return .{ .list = nodes };
}

fn setEdit(a: Allocator, edits: *std.ArrayList(fm_writer.PropEdit), fields: *std.ArrayList([]const u8), name: []const u8, v: fm.Value) !void {
    try edits.append(a, .{ .set = .{ .name = name, .value = v } });
    try fields.append(a, name);
}

fn optEdit(a: Allocator, edits: *std.ArrayList(fm_writer.PropEdit), fields: *std.ArrayList([]const u8), name: []const u8, v: ?fm.Value) !void {
    if (v) |x| return setEdit(a, edits, fields, name, x);
    try edits.append(a, .{ .remove = name });
    try fields.append(a, name);
}
