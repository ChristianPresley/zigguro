//! `ProjectStore` (E13.F09.S01.T01): the projects of a workspace under
//! `.zigguro/projects/<slug>/`, published as immutable reference-counted
//! views, plus the active project (persisted per workspace through a
//! state port).
//!
//! Writes by the user replace `project.zon` / `instructions.md`
//! atomically (or go to the open document); writes by agents become E12
//! changesets (E12 protects `.zigguro/**`, so they always need review).
//! The store does not watch files itself: the app calls `reload` on file
//! events under `.zigguro/projects/` (E08), and listeners hear about every
//! new view.
//!
//! `instructions` reads `instructions.md` lazily, caps it at 32 KiB and
//! expands `@path` imports (as E10 memory files do: relative to the file,
//! then the workspace root; at most 4 deep; cycles and paths outside the
//! workspace are skipped).

const std = @import("std");
const project = @import("project.zig");
const tasks_store = @import("../tasks/store.zig");
const zg_ai = @import("zg_ai");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Project = project.Project;
const Problem = project.Problem;

pub const WriteVia = tasks_store.WriteVia;
pub const ChangePort = tasks_store.ChangePort;
pub const DocumentPort = tasks_store.DocumentPort;
pub const ChangeRequest = tasks_store.ChangeRequest;

/// E15 per-workspace state.
pub const StatePort = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, arena: Allocator, key: []const u8) ?[]const u8,
    put: *const fn (ctx: *anyopaque, key: []const u8, value: ?[]const u8) anyerror!void,
};

pub const active_key = "agents.activeProject";

pub const Options = struct {
    changes: ?ChangePort = null,
    document: ?DocumentPort = null,
    state: ?StatePort = null,
};

/// A project directory whose `project.zon` does not load.
pub const LoadProblem = struct { slug: []const u8, problem: Problem };

pub const ProjectsView = struct {
    arena: std.heap.ArenaAllocator,
    /// Pinned first, then by title.
    projects: []const Project,
    problems: []const LoadProblem,
    gen: u64,
    refs: std.atomic.Value(u32) = .init(1),

    pub fn get(v: *const ProjectsView, slug: []const u8) ?*const Project {
        for (v.projects) |*p| if (std.mem.eql(u8, p.slug, slug)) return p;
        return null;
    }
};

pub const NewProject = struct {
    slug: []const u8,
    title: []const u8,
    description: []const u8 = "",
    knowledge: []const project.KnowledgeItem = &.{},
    defaults: project.Defaults = .{},
    pinned: bool = false,
    instructions: []const u8 = "",
};

/// Null leaves a field alone.
pub const ProjectPatch = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    knowledge: ?[]const project.KnowledgeItem = null,
    defaults: ?project.Defaults = null,
    pinned: ?bool = null,
    instructions: ?[]const u8 = null,
};

pub const Outcome = union(enum) {
    applied,
    /// E12 changesets waiting for review (null: that file did not change).
    changesets: struct { project: ?u64 = null, instructions: ?u64 = null },
};

pub const Listener = struct {
    ctx: *anyopaque,
    /// Called after a new view is published (any thread).
    changed: *const fn (ctx: *anyopaque) void,
};

pub const Instructions = struct {
    text: []const u8,
    truncated: bool = false,
    /// Imports that could not be read.
    skipped: []const []const u8 = &.{},
};

pub const Error = error{ InvalidSlug, Exists, UnknownProject, Invalid, ReviewUnavailable };

const ProjectStore = @This();

gpa: Allocator,
io: Io,
root: Io.Dir,
o: Options,
mutex: Io.Mutex = .init,
current: *ProjectsView,
gen: u64 = 0,
active_slug: ?[]u8 = null,
listeners: std.ArrayList(?Listener) = .empty,

/// Loads every project under `root/.zigguro/projects/`.
pub fn open(gpa: Allocator, io: Io, root: Io.Dir, o: Options) !*ProjectStore {
    const s = try gpa.create(ProjectStore);
    errdefer gpa.destroy(s);
    s.* = .{ .gpa = gpa, .io = io, .root = root, .o = o, .current = undefined };
    s.current = try s.load();
    if (o.state) |st| {
        var buf: [256]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        if (st.get(st.ctx, fba.allocator(), active_key)) |slug| {
            if (project.validSlug(slug)) s.active_slug = try gpa.dupe(u8, slug);
        }
    }
    return s;
}

pub fn deinit(s: *ProjectStore) void {
    s.releaseView(s.current);
    if (s.active_slug) |a| s.gpa.free(a);
    s.listeners.deinit(s.gpa);
    s.gpa.destroy(s);
}

/// The current view; pass it to `release`.
pub fn view(s: *ProjectStore) *const ProjectsView {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    _ = s.current.refs.fetchAdd(1, .monotonic);
    return s.current;
}

pub fn release(s: *ProjectStore, v: *const ProjectsView) void {
    s.releaseView(@constCast(v));
}

fn releaseView(s: *ProjectStore, v: *ProjectsView) void {
    if (v.refs.fetchSub(1, .acq_rel) != 1) return;
    v.arena.deinit();
    s.gpa.destroy(v);
}

/// Re-reads every project and publishes a new view.
pub fn reload(s: *ProjectStore) !void {
    const v = try s.load();
    const old = blk: {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const old = s.current;
        s.current = v;
        break :blk old;
    };
    s.releaseView(old);
    s.notify();
}

fn load(s: *ProjectStore) !*ProjectsView {
    const v = try s.gpa.create(ProjectsView);
    errdefer s.gpa.destroy(v);
    v.* = .{ .arena = .init(s.gpa), .projects = &.{}, .problems = &.{}, .gen = 0 };
    errdefer v.arena.deinit();
    const a = v.arena.allocator();
    var list: std.ArrayList(Project) = .empty;
    var problems: std.ArrayList(LoadProblem) = .empty;
    var dir = s.root.openDir(s.io, project.dir_rel, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => {
            v.gen = s.nextGen();
            return v;
        },
        else => return e,
    };
    defer dir.close(s.io);
    var it = dir.iterate();
    while (try it.next(s.io)) |e| {
        if (e.kind != .directory) continue;
        if (!project.validSlug(e.name)) continue;
        const slug = try a.dupe(u8, e.name);
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ slug, project.file_name });
        const bytes = dir.readFileAllocOptions(s.io, path, a, .limited(256 * 1024), .of(u8), 0) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try problems.append(a, .{ .slug = slug, .problem = .{ .message = try std.fmt.allocPrint(a, "cannot read {s}: {t}", .{ project.file_name, err }) } });
            continue;
        };
        var pr: Problem = .{ .message = "" };
        const p = project.parse(a, slug, bytes, &pr) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => {
                try problems.append(a, .{ .slug = slug, .problem = pr });
                continue;
            },
        };
        try list.append(a, p);
    }
    std.mem.sort(Project, list.items, {}, struct {
        fn lt(_: void, x: Project, y: Project) bool {
            if (x.pinned != y.pinned) return x.pinned;
            return switch (std.ascii.orderIgnoreCase(x.title, y.title)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, x.slug, y.slug) == .lt,
            };
        }
    }.lt);
    v.projects = list.items;
    v.problems = problems.items;
    v.gen = s.nextGen();
    return v;
}

fn nextGen(s: *ProjectStore) u64 {
    s.gen += 1;
    return s.gen;
}

// ---- writes ----

pub fn create(s: *ProjectStore, np: NewProject, via: WriteVia) !Outcome {
    if (!project.validSlug(np.slug)) return error.InvalidSlug;
    {
        const v = s.view();
        defer s.release(v);
        if (v.get(np.slug) != null) return error.Exists;
    }
    const f: project.ProjectFile = .{ .title = np.title, .description = np.description, .knowledge = np.knowledge, .defaults = np.defaults, .pinned = np.pinned };
    if (project.validateFile(&f) != null) return error.Invalid;
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const zon = try project.writeAlloc(arena.allocator(), f);
    return s.writeFiles(arena.allocator(), np.slug, zon, np.instructions, true, via, "Create");
}

pub fn update(s: *ProjectStore, slug: []const u8, patch: ProjectPatch, via: WriteVia) !Outcome {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const zon: ?[]const u8 = blk: {
        const v = s.view();
        defer s.release(v);
        const p = v.get(slug) orelse return error.UnknownProject;
        if (patch.title == null and patch.description == null and patch.knowledge == null and patch.defaults == null and patch.pinned == null) break :blk null;
        var f = p.file();
        if (patch.title) |t| f.title = t;
        if (patch.description) |d| f.description = d;
        if (patch.knowledge) |k| f.knowledge = k;
        if (patch.defaults) |d| f.defaults = d;
        if (patch.pinned) |pn| f.pinned = pn;
        if (project.validateFile(&f) != null) return error.Invalid;
        break :blk try project.writeAlloc(a, f);
    };
    return s.writeFiles(a, slug, zon, patch.instructions, false, via, "Update");
}

fn writeFiles(s: *ProjectStore, a: Allocator, slug: []const u8, zon: ?[]const u8, ins_text: ?[]const u8, new: bool, via: WriteVia, verb: []const u8) !Outcome {
    const zon_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ project.dir_rel, slug, project.file_name });
    const ins_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ project.dir_rel, slug, project.instructions_name });
    // A new project always gets an instructions file, even an empty one.
    const ins: ?[]const u8 = if (new) ins_text orelse "" else ins_text;
    switch (via) {
        .user => {
            const dir_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ project.dir_rel, slug });
            try s.root.createDirPath(s.io, dir_path);
            if (zon) |z| try s.writeUser(zon_path, z);
            if (ins) |t| try s.writeUser(ins_path, t);
            try s.reload();
            return .applied;
        },
        .agent => |ag| {
            const cp = s.o.changes orelse return error.ReviewUnavailable;
            var out: Outcome = .{ .changesets = .{} };
            const summary = try std.fmt.allocPrint(a, "{s} project {s}", .{ verb, slug });
            if (zon) |z| out.changesets.project = try cp.propose(cp.ctx, .{ .path = zon_path, .before = s.readOrNull(a, zon_path), .after = z, .run = ag.run, .session = ag.session, .summary = summary });
            if (ins) |t| out.changesets.instructions = try cp.propose(cp.ctx, .{ .path = ins_path, .before = s.readOrNull(a, ins_path), .after = t, .run = ag.run, .session = ag.session, .summary = summary });
            return out;
        },
    }
}

fn readOrNull(s: *ProjectStore, a: Allocator, path: []const u8) ?[]const u8 {
    return s.root.readFileAlloc(s.io, path, a, .limited(1 << 20)) catch null;
}

fn writeUser(s: *ProjectStore, path: []const u8, bytes: []const u8) !void {
    if (s.o.document) |d| if (try d.apply(d.ctx, path, bytes)) return;
    var af = try s.root.createFileAtomic(s.io, path, .{ .replace = true });
    defer af.deinit(s.io);
    try af.file.writeStreamingAll(s.io, bytes);
    try af.replace(s.io);
}

// ---- active project ----

/// The active project's slug (owned by the store until the next
/// `setActive`); objects created now get its tag.
pub fn active(s: *ProjectStore) ?[]const u8 {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.active_slug;
}

/// Sets (or clears) the active project and persists it.
pub fn setActive(s: *ProjectStore, slug: ?[]const u8) !void {
    const copy: ?[]u8 = if (slug) |x| blk: {
        if (!project.validSlug(x)) return error.InvalidSlug;
        break :blk try s.gpa.dupe(u8, x);
    } else null;
    {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.active_slug) |old| s.gpa.free(old);
        s.active_slug = copy;
    }
    if (s.o.state) |st| try st.put(st.ctx, active_key, slug);
    s.notify();
}

// ---- listeners ----

pub fn subscribe(s: *ProjectStore, l: Listener) !u32 {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    for (s.listeners.items, 0..) |*x, i| if (x.* == null) {
        x.* = l;
        return @intCast(i);
    };
    try s.listeners.append(s.gpa, l);
    return @intCast(s.listeners.items.len - 1);
}

pub fn unsubscribe(s: *ProjectStore, id: u32) void {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    if (id < s.listeners.items.len) s.listeners.items[id] = null;
}

fn notify(s: *ProjectStore) void {
    var buf: [16]Listener = undefined;
    var n: usize = 0;
    {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.listeners.items) |x| if (x) |l| if (n < buf.len) {
            buf[n] = l;
            n += 1;
        };
    }
    for (buf[0..n]) |l| l.changed(l.ctx);
}

// ---- instructions ----

pub const max_import_depth = 4;

/// `instructions.md` of `slug` with its imports, capped at 32 KiB. Empty
/// when the file does not exist.
pub fn instructions(s: *ProjectStore, arena: Allocator, slug: []const u8) !Instructions {
    if (!project.validSlug(slug)) return error.InvalidSlug;
    const path = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ project.dir_rel, slug, project.instructions_name });
    var out: std.ArrayList(u8) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    const text = s.root.readFileAlloc(s.io, path, arena, .limited(4 << 20)) catch |e| switch (e) {
        error.FileNotFound => return .{ .text = "" },
        else => return e,
    };
    try stack.append(arena, path);
    try out.appendSlice(arena, text);
    try s.expand(arena, path, text, 1, &out, &skipped, &stack);
    var truncated = false;
    var t = out.items;
    if (t.len > project.max_instructions) {
        t = t[0..utf8Floor(t, project.max_instructions)];
        truncated = true;
    }
    return .{ .text = t, .truncated = truncated, .skipped = skipped.items };
}

fn expand(s: *ProjectStore, a: Allocator, from: []const u8, text: []const u8, depth: u32, out: *std.ArrayList(u8), skipped: *std.ArrayList([]const u8), stack: *std.ArrayList([]const u8)) !void {
    const imports = try zg_ai.context.imports.scan(a, text);
    for (imports) |imp| {
        const target = resolve(a, from, imp.path) catch null;
        const t = target orelse {
            try skipped.append(a, imp.path);
            continue;
        };
        var cyclic = false;
        for (stack.items) |x| if (std.mem.eql(u8, x, t)) {
            cyclic = true;
        };
        if (cyclic or depth > max_import_depth) {
            try skipped.append(a, imp.path);
            continue;
        }
        const body = s.root.readFileAlloc(s.io, t, a, .limited(1 << 20)) catch {
            try skipped.append(a, imp.path);
            continue;
        };
        try out.print(a, "\n\n<!-- @{s} -->\n", .{t});
        try out.appendSlice(a, body);
        try stack.append(a, t);
        try s.expand(a, t, body, depth + 1, out, skipped, stack);
        _ = stack.pop();
        if (out.items.len > project.max_instructions) return;
    }
}

/// `p` relative to the importing file's folder (`~/` and absolute paths
/// are not followed); null when it leaves the workspace.
fn resolve(a: Allocator, from: []const u8, p: []const u8) !?[]const u8 {
    if (p.len == 0 or p[0] == '/' or p[0] == '~' or std.mem.indexOfScalar(u8, p, '\\') != null) return null;
    const dir = std.fs.path.dirnamePosix(from) orelse "";
    const joined = try std.fs.path.resolvePosix(a, &.{ "/", dir, p });
    const rel = joined[1..];
    if (!@import("project.zig").relPath(rel)) return null;
    return rel;
}

fn utf8Floor(s: []const u8, n: usize) usize {
    var i = n;
    while (i > 0 and i < s.len and (s[i] & 0xC0) == 0x80) i -= 1;
    return i;
}
