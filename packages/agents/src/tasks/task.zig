//! Task files (E13.F03.S01.T01): Markdown with properties in
//! `.zigguro/tasks/T-0042-<slug>.md`, readable in any editor and in
//! Obsidian. The frontmatter is parsed with the notes parser
//! (`zg_frontmatter`); a file never fails to load, a bad one carries a
//! `problem`. Format: docs/formats/tasks.md.

const std = @import("std");
const zg_frontmatter = @import("zg_frontmatter");
const ids = @import("ids.zig");

const Allocator = std.mem.Allocator;
const fm = zg_frontmatter.frontmatter;

pub const TaskId = ids.TaskId;
pub const Date = fm.Date;

/// Board columns, in order.
pub const Status = enum {
    backlog,
    ready,
    in_progress,
    review,
    blocked,
    done,
    cancelled,

    /// Accepts `in_progress`, `in-progress` and `in progress`, any case.
    pub fn parse(s: []const u8) ?Status {
        var buf: [16]u8 = undefined;
        if (s.len > buf.len) return null;
        for (s, 0..) |c, i| buf[i] = switch (c) {
            '-', ' ' => '_',
            else => std.ascii.toLower(c),
        };
        return std.meta.stringToEnum(Status, buf[0..s.len]);
    }

    pub fn finished(s: Status) bool {
        return s == .done or s == .cancelled;
    }
};

/// The frontmatter properties the board reads; everything else is kept
/// untouched.
pub const props = struct {
    pub const id = "id";
    pub const title = "title";
    pub const status = "status";
    pub const priority = "priority";
    pub const assignee = "assignee";
    pub const labels = "labels";
    pub const depends_on = "depends_on";
    pub const due = "due";
    pub const created = "created";
    pub const rank = "rank";
    pub const claimed_by = "claimed_by";
    pub const github = "github";
    pub const project = "project";
};

pub const Task = struct {
    /// 0 when the file has no valid `id`.
    id: TaskId,
    /// File name inside the tasks directory.
    path: []const u8,
    title: []const u8,
    status: Status = .backlog,
    /// 0 (P0, most urgent) to 3.
    priority: u2 = 2,
    /// A person, or `agent:<definition>`.
    assignee: ?[]const u8 = null,
    labels: []const []const u8 = &.{},
    depends_on: []const TaskId = &.{},
    due: ?Date = null,
    /// As written (a date or a datetime).
    created: ?[]const u8 = null,
    /// Fractional order within a column (`rank.zig`).
    rank: ?[]const u8 = null,
    /// The run holding the claim (its id).
    claimed_by: ?[]const u8 = null,
    /// `owner/repo#123` when synced with GitHub Issues.
    github: ?[]const u8 = null,
    /// The E13.F09 project slug.
    project: ?[]const u8 = null,
    /// Why the file is not a valid task (it is still listed).
    problem: ?[]const u8 = null,

    pub fn hasLabel(t: *const Task, l: []const u8) bool {
        for (t.labels) |x| if (std.ascii.eqlIgnoreCase(x, l)) return true;
        return false;
    }

    /// Deep copy into `a`.
    pub fn clone(t: *const Task, a: Allocator) Allocator.Error!Task {
        var c = t.*;
        c.path = try a.dupe(u8, t.path);
        c.title = try a.dupe(u8, t.title);
        if (t.assignee) |s| c.assignee = try a.dupe(u8, s);
        const labels = try a.alloc([]const u8, t.labels.len);
        for (labels, t.labels) |*d, s| d.* = try a.dupe(u8, s);
        c.labels = labels;
        c.depends_on = try a.dupe(TaskId, t.depends_on);
        if (t.created) |s| c.created = try a.dupe(u8, s);
        if (t.rank) |s| c.rank = try a.dupe(u8, s);
        if (t.claimed_by) |s| c.claimed_by = try a.dupe(u8, s);
        if (t.github) |s| c.github = try a.dupe(u8, s);
        if (t.project) |s| c.project = try a.dupe(u8, s);
        if (t.problem) |s| c.problem = try a.dupe(u8, s);
        return c;
    }
};

/// Only the start of a file is read for the index.
pub const index_read_bytes = 16 * 1024;

/// Reads a task from a file's bytes (or their first `index_read_bytes`).
/// Fails only on allocation; strings point into `bytes` or `arena`.
pub fn parse(arena: Allocator, path: []const u8, bytes: []const u8) Allocator.Error!Task {
    var t: Task = .{ .id = 0, .path = path, .title = "" };
    const loc = fm.findFrontmatter(bytes);
    var body: []const u8 = bytes;
    if (loc) |l| {
        body = bytes[l.block[1]..];
        const root = fm.parseRange(arena, bytes, l.body, null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        try readProps(arena, bytes, &t, &root);
    } else {
        t.problem = "no frontmatter";
    }
    if (t.title.len == 0) t.title = firstHeading(body) orelse ids.titleFromPath(path);
    if (t.id == 0 and t.problem == null) t.problem = "missing or invalid id";
    return t;
}

fn readProps(arena: Allocator, bytes: []const u8, t: *Task, root: *const fm.Node) Allocator.Error!void {
    if (fm.get(root, props.id)) |n| {
        if (scalarText(bytes, n)) |s| t.id = ids.parse(s) orelse 0;
    }
    if (fm.get(root, props.title)) |n| if (scalarText(bytes, n)) |s| {
        t.title = std.mem.trim(u8, s, " \t");
    };
    if (fm.get(root, props.status)) |n| {
        if (scalarText(bytes, n)) |s| {
            if (Status.parse(std.mem.trim(u8, s, " \t"))) |st| t.status = st else t.problem = "unknown status";
        }
    }
    if (fm.get(root, props.priority)) |n| t.priority = parsePriority(n) orelse blk: {
        t.problem = "priority must be P0 to P3";
        break :blk 2;
    };
    if (fm.get(root, props.assignee)) |n| if (scalarText(bytes, n)) |s| {
        if (s.len > 0) t.assignee = s;
    };
    if (fm.get(root, props.labels)) |n| t.labels = try stringList(arena, n);
    if (fm.get(root, props.depends_on)) |n| {
        const list = try stringList(arena, n);
        var out: std.ArrayList(TaskId) = .empty;
        for (list) |s| {
            if (ids.parse(s)) |id| try out.append(arena, id) else t.problem = "depends_on lists something that is not a task id";
        }
        t.depends_on = out.items;
    }
    if (fm.get(root, props.due)) |n| switch (n.value) {
        .date => |d| t.due = d,
        .datetime => |dt| t.due = dt.date,
        .null => {},
        else => t.problem = "due must be a date (YYYY-MM-DD)",
    };
    if (fm.get(root, props.created)) |n| t.created = scalarText(bytes, n);
    if (fm.get(root, props.rank)) |n| t.rank = scalarText(bytes, n);
    if (fm.get(root, props.claimed_by)) |n| if (scalarText(bytes, n)) |s| {
        if (s.len > 0) t.claimed_by = s;
    };
    if (fm.get(root, props.github)) |n| t.github = scalarText(bytes, n);
    if (fm.get(root, props.project)) |n| t.project = scalarText(bytes, n);
}

/// A scalar's text (numbers and dates as written), null for empty and
/// collections.
fn scalarText(bytes: []const u8, n: *const fm.Node) ?[]const u8 {
    return switch (n.value) {
        .string => |s| s,
        .null, .list, .map => null,
        .raw => |r| r,
        else => bytes[n.src[0]..n.src[1]],
    };
}

fn parsePriority(n: *const fm.Node) ?u2 {
    return switch (n.value) {
        .int => |i| if (i >= 0 and i <= 3) @intCast(i) else null,
        .string => |s| blk: {
            const t = std.mem.trim(u8, s, " \t");
            if (t.len == 2 and (t[0] == 'P' or t[0] == 'p') and t[1] >= '0' and t[1] <= '3') break :blk @intCast(t[1] - '0');
            break :blk null;
        },
        .null => 2,
        else => null,
    };
}

/// A list, or one comma-separated string (`labels: bug, docs`).
fn stringList(arena: Allocator, n: *const fm.Node) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (n.value) {
        .list => |items| for (items) |it| switch (it.value) {
            .string => |s| if (s.len > 0) try out.append(arena, s),
            .int => |i| try out.append(arena, try std.fmt.allocPrint(arena, "{d}", .{i})),
            else => {},
        },
        .string => |s| {
            var it = std.mem.tokenizeAny(u8, s, ", ");
            while (it.next()) |x| try out.append(arena, x);
        },
        else => {},
    }
    return out.items;
}

/// The first `# ` heading.
fn firstHeading(body: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "# ")) {
            const t = std.mem.trim(u8, line[2..], " \t");
            if (t.len > 0) return t;
        }
    }
    return null;
}

/// The Markdown after the frontmatter.
pub fn bodyOf(bytes: []const u8) []const u8 {
    const loc = fm.findFrontmatter(bytes) orelse return bytes;
    return bytes[loc.block[1]..];
}
