//! The workspace's merged task list (E07.F08.S01.T01): `.zigguro/tasks.zon`
//! first, then `.vscode/tasks.json`, then the `zig build` steps. A label
//! already taken keeps its first task and adds a warning. In an untrusted
//! workspace every task is listed disabled and `zig build -l` is not run
//! (it executes `build.zig`).
//!
//! `fromSources` builds a list from texts already read; `load` reads the
//! files and lists the steps (on a worker: it may run `zig`). `Cache`
//! keeps the last list and reloads it after a change to one of the four
//! files, re-running `zig build -l` only when `build.zig` or
//! `build.zig.zon` changed.

const std = @import("std");
const Task = @import("Task.zig");
const zig_build = @import("sources/zig_build.zig");
const tasks_zon = @import("sources/tasks_zon.zig");
const tasks_json = @import("sources/tasks_json.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const TaskList = @This();

arena: std.heap.ArenaAllocator,
tasks: []Task = &.{},
warnings: []const Warning = &.{},

pub const Warning = struct {
    /// Workspace-relative file the warning is about.
    file: []const u8,
    message: []const u8,
};

pub const WorkspaceView = struct {
    root: []const u8,
    trusted: bool,
};

pub const ZigToolchain = struct {
    exe_path: []const u8 = "zig",
    env: ?*const std.process.Environ.Map = null,
};

/// The files whose change reloads the list.
pub const watched = [_][]const u8{ tasks_zon.path, tasks_json.path, "build.zig", "build.zig.zon" };

pub const Inputs = struct {
    tasks_zon: ?[:0]const u8 = null,
    tasks_json: ?[]const u8 = null,
    /// `zig build -l` output.
    zig_steps: ?[]const u8 = null,
    zig_exe: []const u8 = "zig",
    os: std.Target.Os.Tag,
    trusted: bool,
};

pub const untrusted_reason = "workspace not trusted";

pub fn fromSources(gpa: Allocator, in: Inputs) Allocator.Error!TaskList {
    var l: TaskList = .{ .arena = .init(gpa) };
    errdefer l.arena.deinit();
    const a = l.arena.allocator();
    var found: std.ArrayList(Task) = .empty;
    var warnings: std.ArrayList(Warning) = .empty;
    // Tasks may point into the texts, so the list keeps its own copies.
    if (in.tasks_zon) |src| try tasks_zon.appendTasks(a, try a.dupeZ(u8, src), &found, &warnings);
    if (in.tasks_json) |src| try tasks_json.appendTasks(a, src, in.os, &found, &warnings);
    if (in.zig_steps) |text| try zig_build.appendTasks(a, try zig_build.parseSteps(a, try a.dupe(u8, text)), try a.dupe(u8, in.zig_exe), &found);

    // First label wins.
    var seen: std.StringHashMapUnmanaged(Task.Source) = .empty;
    var kept: std.ArrayList(Task) = try .initCapacity(a, found.items.len);
    for (found.items) |t| {
        const gop = try seen.getOrPut(a, t.label);
        if (gop.found_existing) {
            try warnings.append(a, .{
                .file = sourceFile(t.source),
                .message = try std.fmt.allocPrint(a, "task '{s}' has the label of a task in {s}, which is the one listed", .{ t.label, sourceFile(gop.value_ptr.*) }),
            });
            continue;
        }
        gop.value_ptr.* = t.source;
        kept.appendAssumeCapacity(t);
    }
    if (!in.trusted) for (kept.items) |*t| {
        t.enabled = false;
        t.disabled_reason = untrusted_reason;
    };
    l.tasks = kept.items;
    l.warnings = warnings.items;
    return l;
}

fn sourceFile(s: Task.Source) []const u8 {
    return switch (s) {
        .zon => tasks_zon.path,
        .vscode => tasks_json.path,
        .zig => "build.zig",
    };
}

/// Reads the task files under `ws.root` and, in a trusted workspace with
/// a `build.zig` and a toolchain, lists its steps.
pub fn load(gpa: Allocator, io: Io, ws: WorkspaceView, os: std.Target.Os.Tag, zig: ?ZigToolchain) !TaskList {
    var steps: ?[]u8 = null;
    defer if (steps) |s| gpa.free(s);
    if (ws.trusted) if (zig) |tc| {
        if (exists(io, ws.root, "build.zig")) steps = zig_build.listSteps(gpa, io, tc.exe_path, ws.root, tc.env);
    };
    return loadWithSteps(gpa, io, ws, os, if (zig) |tc| tc.exe_path else "zig", steps);
}

fn loadWithSteps(gpa: Allocator, io: Io, ws: WorkspaceView, os: std.Target.Os.Tag, zig_exe: []const u8, steps: ?[]const u8) !TaskList {
    const zon = try readFile(gpa, io, ws.root, tasks_zon.path);
    defer if (zon) |s| gpa.free(s);
    const json = try readFile(gpa, io, ws.root, tasks_json.path);
    defer if (json) |s| gpa.free(s);
    return fromSources(gpa, .{
        .tasks_zon = zon,
        .tasks_json = json,
        .zig_steps = steps,
        .zig_exe = zig_exe,
        .os = os,
        .trusted = ws.trusted,
    });
}

fn readFile(gpa: Allocator, io: Io, root: []const u8, rel: []const u8) !?[:0]u8 {
    var dir = Io.Dir.cwd().openDir(io, root, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer dir.close(io);
    return dir.readFileAllocOptions(io, rel, gpa, .limited(4 << 20), .of(u8), 0) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

fn exists(io: Io, root: []const u8, rel: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, root, .{}) catch return false;
    defer dir.close(io);
    _ = dir.statFile(io, rel, .{}) catch return false;
    return true;
}

pub fn deinit(l: *TaskList) void {
    l.arena.deinit();
    l.* = undefined;
}

pub fn all(l: *const TaskList) []const Task {
    return l.tasks;
}

pub fn byLabel(l: *const TaskList, label: []const u8) ?*const Task {
    for (l.tasks) |*t| if (std.mem.eql(u8, t.label, label)) return t;
    return null;
}

/// The first task of `group` marked default.
pub fn defaultFor(l: *const TaskList, group: enum { build, @"test" }) ?*const Task {
    const kind: Task.GroupKind = switch (group) {
        .build => .build,
        .@"test" => .@"test",
    };
    for (l.tasks) |*t| if (t.group) |g| {
        if (g.kind == kind and g.is_default) return t;
    };
    return null;
}

/// The first task tagged `tag` (`check` for build-on-save).
pub fn tagged(l: *const TaskList, tag: []const u8) ?*const Task {
    for (l.tasks) |*t| if (t.hasTag(tag)) return t;
    return null;
}

/// The last list, reloaded on demand after `fileChanged` reports a
/// change to a watched file (the E08 watch pipeline calls it). `zig build
/// -l` output is kept while `build.zig` and `build.zig.zon` keep their
/// modification times.
pub const Cache = struct {
    gpa: Allocator,
    ws: WorkspaceView,
    os: std.Target.Os.Tag,
    zig: ?ZigToolchain,
    list: ?TaskList = null,
    dirty: bool = true,
    steps: ?[]u8 = null,
    steps_key: [2]i96 = .{ 0, 0 },
    steps_valid: bool = false,
    runner: StepRunner = .default,

    /// How `zig build -l` runs (tests count calls with a fake).
    pub const StepRunner = struct {
        ctx: ?*anyopaque = null,
        run: *const fn (ctx: ?*anyopaque, gpa: Allocator, io: Io, zig_exe: []const u8, root: []const u8, env: ?*const std.process.Environ.Map) ?[]u8,

        pub const default: StepRunner = .{ .run = runReal };

        fn runReal(_: ?*anyopaque, gpa: Allocator, io: Io, zig_exe: []const u8, root: []const u8, env: ?*const std.process.Environ.Map) ?[]u8 {
            return zig_build.listSteps(gpa, io, zig_exe, root, env);
        }
    };

    pub fn init(gpa: Allocator, ws: WorkspaceView, os: std.Target.Os.Tag, zig: ?ZigToolchain) Cache {
        return .{ .gpa = gpa, .ws = ws, .os = os, .zig = zig };
    }

    pub fn deinit(c: *Cache) void {
        if (c.list) |*l| l.deinit();
        if (c.steps) |s| c.gpa.free(s);
        c.* = undefined;
    }

    /// The current list, reloaded first when a watched file changed.
    pub fn get(c: *Cache, io: Io) !*const TaskList {
        if (c.dirty or c.list == null) {
            const steps = c.currentSteps(io);
            var fresh = try loadWithSteps(c.gpa, io, c.ws, c.os, if (c.zig) |z| z.exe_path else "zig", steps);
            if (c.list) |*old| old.deinit();
            c.list = fresh;
            fresh = undefined;
            c.dirty = false;
        }
        return &c.list.?;
    }

    /// Trust changed: everything reloads.
    pub fn setTrusted(c: *Cache, trusted: bool) void {
        if (c.ws.trusted == trusted) return;
        c.ws.trusted = trusted;
        c.dirty = true;
        c.steps_valid = false;
    }

    /// A file changed (absolute, or relative to the workspace root).
    /// Returns whether it is one the list depends on.
    pub fn fileChanged(c: *Cache, path: []const u8) bool {
        var rel = path;
        if (std.mem.startsWith(u8, rel, c.ws.root)) {
            rel = rel[c.ws.root.len..];
            rel = std.mem.trimStart(u8, rel, "/\\");
        }
        for (watched) |w| {
            if (sameRel(rel, w)) {
                c.dirty = true;
                return true;
            }
        }
        return false;
    }

    fn sameRel(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            const xs = if (x == '\\') '/' else x;
            if (xs != y) return false;
        }
        return true;
    }

    fn currentSteps(c: *Cache, io: Io) ?[]const u8 {
        if (!c.ws.trusted) return null;
        const tc = c.zig orelse return null;
        const key = .{ mtime(io, c.ws.root, "build.zig") orelse return null, mtime(io, c.ws.root, "build.zig.zon") orelse 0 };
        if (c.steps_valid and c.steps_key[0] == key[0] and c.steps_key[1] == key[1]) return c.steps;
        if (c.steps) |s| c.gpa.free(s);
        c.steps = c.runner.run(c.runner.ctx, c.gpa, io, tc.exe_path, c.ws.root, tc.env);
        c.steps_key = key;
        c.steps_valid = true;
        return c.steps;
    }

    fn mtime(io: Io, root: []const u8, rel: []const u8) ?i96 {
        var dir = Io.Dir.cwd().openDir(io, root, .{}) catch return null;
        defer dir.close(io);
        const st = dir.statFile(io, rel, .{}) catch return null;
        return st.mtime.nanoseconds;
    }
};
