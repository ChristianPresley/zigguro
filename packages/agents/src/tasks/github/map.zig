//! How a task file and a GitHub issue correspond (E13.F03.S03.T02).
//!
//! | Task | Issue |
//! | --- | --- |
//! | `title` (and the body's first `# ` heading) | `title` |
//! | the body below it, without `## Agent log` | `body` |
//! | `done` / `cancelled` / anything else | closed `completed` / closed `not_planned` / open |
//! | `labels` | label names (a set, ignoring case) |
//! | `assignee` (a person) | the first assignee |
//!
//! The agent log stays local, and so does an `agent:*` assignee. Every
//! other property and every other issue field is left alone.

const std = @import("std");
const task_mod = @import("../task.zig");
const store_mod = @import("../store.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Status = task_mod.Status;
const Issue = types.Issue;

/// The open/closed side of a status.
pub const SyncState = enum {
    open,
    done,
    cancelled,

    pub fn ofStatus(s: Status) SyncState {
        return switch (s) {
            .done => .done,
            .cancelled => .cancelled,
            else => .open,
        };
    }

    pub fn ofIssue(i: *const Issue) SyncState {
        if (i.state == .open) return .open;
        const r = i.state_reason orelse return .done;
        return if (std.mem.eql(u8, r, "not_planned") or std.mem.eql(u8, r, "duplicate")) .cancelled else .done;
    }

    /// The local status for remote state `st`, given the current one: an
    /// open issue keeps the task's open status (a finished task reopens
    /// as `ready`).
    pub fn toStatus(st: SyncState, current: Status) Status {
        return switch (st) {
            .done => .done,
            .cancelled => .cancelled,
            .open => if (current.finished()) .ready else current,
        };
    }

    /// The issue's `state` and `state_reason`.
    pub fn issueFields(st: SyncState) struct { state: []const u8, reason: ?[]const u8 } {
        return switch (st) {
            .open => .{ .state = "open", .reason = "reopened" },
            .done => .{ .state = "closed", .reason = "completed" },
            .cancelled => .{ .state = "closed", .reason = "not_planned" },
        };
    }
};

/// The synced fields of one side.
pub const Fields = struct {
    title: []const u8,
    /// Normalized: LF line ends, trimmed.
    body: []const u8,
    state: SyncState,
    /// Sorted ignoring case, without duplicates.
    labels: []const []const u8,
    /// A person (never `agent:*`).
    assignee: ?[]const u8,
};

/// A task's synced fields from its file bytes.
pub fn fromTask(a: Allocator, t: *const task_mod.Task, bytes: []const u8) Allocator.Error!Fields {
    return .{
        .title = t.title,
        .body = try localBody(a, bytes),
        .state = .ofStatus(t.status),
        .labels = try labelSet(a, t.labels),
        .assignee = if (t.assignee) |x| (if (isAgent(x)) null else x) else null,
    };
}

/// An issue's synced fields.
pub fn fromIssue(a: Allocator, i: *const Issue) Allocator.Error!Fields {
    return .{
        .title = std.mem.trim(u8, i.title, " \t\r\n"),
        .body = try normalize(a, i.body orelse ""),
        .state = .ofIssue(i),
        .labels = try labelSet(a, i.labels),
        .assignee = if (i.assignees.len > 0) i.assignees[0] else null,
    };
}

pub fn isAgent(assignee: []const u8) bool {
    return std.mem.startsWith(u8, assignee, "agent:");
}

/// The text a body or title is compared by.
pub fn hash(s: []const u8) u64 {
    return std.hash.XxHash3.hash(0, s);
}

pub fn labelsEqual(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.ascii.eqlIgnoreCase(p, q)) return false;
    return true;
}

pub fn optEqual(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}

/// `labels` sorted ignoring case, duplicates and blanks dropped.
pub fn labelSet(a: Allocator, labels: []const []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (labels) |l| {
        const t = std.mem.trim(u8, l, " ");
        if (t.len > 0) try out.append(a, t);
    }
    std.mem.sort([]const u8, out.items, {}, lessIgnoreCase);
    var n: usize = 0;
    for (out.items) |l| {
        if (n > 0 and std.ascii.eqlIgnoreCase(out.items[n - 1], l)) continue;
        out.items[n] = l;
        n += 1;
    }
    return out.items[0..n];
}

fn lessIgnoreCase(_: void, x: []const u8, y: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(x, y);
}

fn has(set: []const []const u8, l: []const u8) bool {
    for (set) |x| if (std.ascii.eqlIgnoreCase(x, l)) return true;
    return false;
}

/// The three-way merge of label sets: what either side added is in, what
/// either side removed is out. Never conflicts.
pub fn mergeLabels(a: Allocator, base: []const []const u8, local: []const []const u8, remote: []const []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (base) |l| if (has(local, l) and has(remote, l)) try out.append(a, l);
    for (local) |l| if (!has(base, l)) try out.append(a, l);
    for (remote) |l| if (!has(base, l)) try out.append(a, l);
    return labelSet(a, out.items);
}

/// What a three-way field merge decided.
pub const Decision = enum {
    /// Both sides still equal the base, or equal each other.
    same,
    /// Only the remote changed: apply it locally.
    take_remote,
    /// Only the local side changed: send it.
    take_local,
    /// Both changed, differently.
    conflict,
};

pub fn decide(local_changed: bool, remote_changed: bool, sides_equal: bool) Decision {
    if (sides_equal) return .same;
    if (local_changed and remote_changed) return .conflict;
    if (remote_changed) return .take_remote;
    if (local_changed) return .take_local;
    // Neither changed from the base yet they differ: the base is stale.
    return .take_remote;
}

/// LF line ends, trimmed.
pub fn normalize(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (std.mem.indexOfScalar(u8, t, '\r') == null) return t;
    return std.mem.replaceOwned(u8, a, t, "\r\n", "\n");
}

/// The part of a task body that syncs: below the frontmatter, without a
/// leading `# ` heading and without the `## Agent log` section.
pub fn localBody(a: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    const parts = split(task_mod.bodyOf(bytes));
    const text = std.mem.trim(u8, parts.text, " \t\r\n");
    const after = std.mem.trim(u8, parts.after_log, " \t\r\n");
    const sep: []const u8 = if (text.len > 0 and after.len > 0) "\n\n" else "";
    return normalize(a, try std.mem.concat(a, u8, &.{ text, sep, after }));
}

const Parts = struct {
    /// The first `# ` line, if the body starts with one.
    heading: ?[]const u8,
    /// Between the heading and the agent log.
    text: []const u8,
    /// The agent log section itself.
    log: []const u8,
    /// Anything after the agent log section.
    after_log: []const u8,
};

fn split(body: []const u8) Parts {
    var rest = body;
    var heading: ?[]const u8 = null;
    const lead = std.mem.trimStart(u8, rest, " \t\r\n");
    if (std.mem.startsWith(u8, lead, "# ")) {
        const nl = std.mem.indexOfScalar(u8, lead, '\n') orelse lead.len;
        heading = std.mem.trimEnd(u8, lead[0..nl], "\r");
        rest = lead[@min(nl + 1, lead.len)..];
    }
    const log_at = findLine(rest, store_mod.agent_log_heading) orelse return .{ .heading = heading, .text = rest, .log = "", .after_log = "" };
    var end = rest.len;
    var j = log_at + store_mod.agent_log_heading.len;
    while (std.mem.indexOfPos(u8, rest, j, "\n#")) |p| : (j = p + 1) {
        const r = rest[p + 1 ..];
        if (std.mem.startsWith(u8, r, "# ") or std.mem.startsWith(u8, r, "## ")) {
            end = p + 1;
            break;
        }
    }
    return .{ .heading = heading, .text = rest[0..log_at], .log = rest[log_at..end], .after_log = rest[end..] };
}

fn findLine(s: []const u8, line: []const u8) ?usize {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, line)) |p| : (i = p + 1) {
        if (p == 0 or s[p - 1] == '\n') return p;
    }
    return null;
}

/// A new task body: `title` as its heading (when the old body had one),
/// then `text` (the synced part), then the old agent log, which moves to
/// the end. The file's line ends are kept.
pub fn composeBody(a: Allocator, old_bytes: []const u8, title: []const u8, text: []const u8) Allocator.Error![]const u8 {
    const old = task_mod.bodyOf(old_bytes);
    const crlf = std.mem.indexOf(u8, old_bytes, "\r\n") != null;
    const parts = split(old);
    var out: std.ArrayList(u8) = .empty;
    if (parts.heading != null or old.len == 0) try out.print(a, "# {s}\n", .{title});
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len > 0) {
        if (out.items.len > 0) try out.append(a, '\n');
        try out.appendSlice(a, t);
        try out.append(a, '\n');
    }
    if (parts.log.len > 0) {
        if (out.items.len > 0) try out.append(a, '\n');
        try out.appendSlice(a, std.mem.trimEnd(u8, parts.log, " \t\r\n"));
        try out.append(a, '\n');
    }
    const lf = try normalizeLines(a, out.items);
    return if (crlf) std.mem.replaceOwned(u8, a, lf, "\n", "\r\n") else lf;
}

fn normalizeLines(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\r') == null) return s;
    return std.mem.replaceOwned(u8, a, s, "\r\n", "\n");
}

/// `owner/repo#123` for the task's `github` property.
pub fn linkText(a: Allocator, repo: types.Repo, number: u32) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}#{d}", .{ repo.owner, repo.name, number });
}

/// The issue number a `github` property names in `repo`, or null.
pub fn parseLink(text: []const u8, repo: types.Repo) ?u32 {
    const hash_at = std.mem.lastIndexOfScalar(u8, text, '#') orelse return null;
    const slug = std.mem.trim(u8, text[0..hash_at], " ");
    const slash = std.mem.indexOfScalar(u8, slug, '/') orelse return null;
    if (!std.ascii.eqlIgnoreCase(slug[0..slash], repo.owner) or !std.ascii.eqlIgnoreCase(slug[slash + 1 ..], repo.name)) return null;
    return std.fmt.parseInt(u32, std.mem.trim(u8, text[hash_at + 1 ..], " "), 10) catch null;
}
