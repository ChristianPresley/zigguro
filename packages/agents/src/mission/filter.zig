//! Mission Control's filter grammar (E13.F01.S02.T01). Whitespace-separated
//! terms: `s:<status|group>`, `k:<kind>`, `n:<text>` (title or first
//! prompt), `o:<text>` (summary or outputs), `cost>N` / `cost<N` (USD),
//! `#tag`, `a:<automation or workflow name>`, `p:<project slug>` or
//! `p:none` (E13.F09); a bare word is `n:`, and so
//! is a term with an unknown prefix. A value may be double-quoted
//! (`n:"two words"`). Terms of different kinds are ANDed; several `s:`,
//! `k:` or `p:` terms form one set (a run matches any of them). Text matches are
//! case-insensitive substrings. Pure.

const std = @import("std");
const run = @import("../runs/run.zig");

const Allocator = std.mem.Allocator;
const RunStatus = run.RunStatus;
const RunKind = run.RunKind;

/// Mission Control's groups, in display order.
pub const Group = enum { pinned, needs_input, ready_for_review, working, queued_paused, done };

pub const Filter = struct {
    states: std.EnumSet(RunStatus) = .initEmpty(),
    groups: std.EnumSet(Group) = .initEmpty(),
    kinds: std.EnumSet(RunKind) = .initEmpty(),
    names: []const []const u8 = &.{},
    outputs: []const []const u8 = &.{},
    min_cost_micro: ?u64 = null,
    max_cost_micro: ?u64 = null,
    tags: []const []const u8 = &.{},
    origins: []const []const u8 = &.{},
    /// Project slugs (matched exactly, ignoring case).
    projects: []const []const u8 = &.{},
    /// `p:none`: runs outside any project.
    no_project: bool = false,

    pub const all: Filter = .{};

    pub fn isEmpty(f: *const Filter) bool {
        return f.states.count() == 0 and f.groups.count() == 0 and f.kinds.count() == 0 and
            f.names.len == 0 and f.outputs.len == 0 and f.min_cost_micro == null and
            f.max_cost_micro == null and f.tags.len == 0 and f.origins.len == 0 and
            f.projects.len == 0 and !f.no_project;
    }

    pub fn matches(f: *const Filter, s: Subject) bool {
        // A status term and a group term are one set: `s:working s:paused`.
        if (f.states.count() + f.groups.count() > 0 and !f.states.contains(s.status) and !f.groups.contains(s.group))
            return false;
        if (f.kinds.count() > 0 and !f.kinds.contains(s.kind)) return false;
        for (f.names) |n| if (!has(s.title, n) and !has(s.prompt, n)) return false;
        for (f.outputs) |o| if (!has(s.summary, o) and !has(s.outputs, o)) return false;
        if (f.min_cost_micro) |c| if (s.cost_micro <= c) return false;
        if (f.max_cost_micro) |c| if (s.cost_micro >= c) return false;
        for (f.tags) |t| {
            for (s.tags) |st| {
                if (std.ascii.eqlIgnoreCase(st, t)) break;
            } else return false;
        }
        for (f.origins) |o| if (!has(s.origin, o)) return false;
        if (f.projects.len > 0 or f.no_project) if (!f.projectMatches(s.project)) return false;
        return true;
    }

    fn projectMatches(f: *const Filter, project: ?[]const u8) bool {
        const p = project orelse return f.no_project;
        for (f.projects) |x| if (std.ascii.eqlIgnoreCase(x, p)) return true;
        return false;
    }
};

/// What a filter looks at in one run.
pub const Subject = struct {
    status: RunStatus,
    group: Group,
    kind: RunKind,
    title: []const u8 = "",
    prompt: []const u8 = "",
    summary: []const u8 = "",
    /// Output labels, newline-separated.
    outputs: []const u8 = "",
    cost_micro: u64 = 0,
    tags: []const []const u8 = &.{},
    /// The automation's name, the workflow step or the workflow's title.
    origin: []const u8 = "",
    /// The run's project slug.
    project: ?[]const u8 = null,
};

fn has(hay: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}

/// Parses `text`; strings point into `text` or `arena`.
pub fn parseFilter(text: []const u8, arena: Allocator) Allocator.Error!Filter {
    var f: Filter = .{};
    var names: std.ArrayList([]const u8) = .empty;
    var outputs: std.ArrayList([]const u8) = .empty;
    var tags: std.ArrayList([]const u8) = .empty;
    var origins: std.ArrayList([]const u8) = .empty;
    var projects: std.ArrayList([]const u8) = .empty;
    var it: Terms = .{ .s = text };
    while (it.next()) |term| {
        if (term.prefix) |p| {
            if (std.mem.eql(u8, p, "s")) {
                if (statusOrGroup(term.value)) |sg| switch (sg) {
                    .status => |st| f.states.insert(st),
                    .group => |g| f.groups.insert(g),
                } else try names.append(arena, term.raw);
                continue;
            }
            if (std.mem.eql(u8, p, "k")) {
                if (kindOf(term.value)) |k| f.kinds.insert(k) else try names.append(arena, term.raw);
                continue;
            }
            if (term.value.len == 0) {
                try names.append(arena, term.raw);
                continue;
            }
            if (std.mem.eql(u8, p, "n")) try names.append(arena, term.value) //
            else if (std.mem.eql(u8, p, "o")) try outputs.append(arena, term.value) //
            else if (std.mem.eql(u8, p, "a")) try origins.append(arena, term.value) //
            else if (std.mem.eql(u8, p, "p")) {
                if (std.ascii.eqlIgnoreCase(term.value, "none")) f.no_project = true else try projects.append(arena, term.value);
            } //
            else try names.append(arena, term.raw);
            continue;
        }
        const w = term.value;
        if (w.len > 1 and w[0] == '#') {
            try tags.append(arena, w[1..]);
            continue;
        }
        if (costTerm(w)) |c| {
            switch (c.op) {
                .gt => f.min_cost_micro = c.micros,
                .lt => f.max_cost_micro = c.micros,
            }
            continue;
        }
        try names.append(arena, w);
    }
    f.names = try names.toOwnedSlice(arena);
    f.outputs = try outputs.toOwnedSlice(arena);
    f.tags = try tags.toOwnedSlice(arena);
    f.origins = try origins.toOwnedSlice(arena);
    f.projects = try projects.toOwnedSlice(arena);
    return f;
}

const Term = struct {
    /// Before the first `:` (a known one-letter prefix or any word).
    prefix: ?[]const u8,
    /// After the prefix, unquoted.
    value: []const u8,
    /// The whole term, unquoted (an unknown prefix searches for it all).
    raw: []const u8,
};

const Terms = struct {
    s: []const u8,
    i: usize = 0,

    fn next(t: *Terms) ?Term {
        while (t.i < t.s.len and std.ascii.isWhitespace(t.s[t.i])) t.i += 1;
        if (t.i >= t.s.len) return null;
        const start = t.i;
        var colon: ?usize = null;
        var quote: ?usize = null;
        while (t.i < t.s.len) : (t.i += 1) {
            const c = t.s[t.i];
            if (quote == null and std.ascii.isWhitespace(c)) break;
            if (c == '"') {
                if (quote == null) {
                    quote = t.i;
                } else {
                    t.i += 1;
                    break;
                }
            } else if (c == ':' and colon == null and quote == null) colon = t.i;
        }
        const tok = t.s[start..t.i];
        const prefix: ?[]const u8 = if (colon) |c| t.s[start..c] else null;
        const value_start = if (colon) |c| c + 1 - start else 0;
        const value = unquote(tok[value_start..]);
        return .{
            .prefix = if (prefix) |p| (if (p.len > 0) p else null) else null,
            .value = value,
            .raw = if (prefix == null) value else tok,
        };
    }
};

fn unquote(s: []const u8) []const u8 {
    if (s.len == 0 or s[0] != '"') return s;
    const end = if (s.len > 1 and s[s.len - 1] == '"') s.len - 1 else s.len;
    return s[1..end];
}

const StatusOrGroup = union(enum) { status: RunStatus, group: Group };

fn statusOrGroup(v: []const u8) ?StatusOrGroup {
    var buf: [32]u8 = undefined;
    if (v.len == 0 or v.len > buf.len) return null;
    const n = normalise(&buf, v);
    // Group names win where they overlap (`working` includes `starting`).
    const aliases = [_]struct { []const u8, StatusOrGroup }{
        .{ "review", .{ .group = .ready_for_review } },
        .{ "ready", .{ .group = .ready_for_review } },
        .{ "running", .{ .group = .working } },
        .{ "active", .{ .group = .working } },
        .{ "waiting", .{ .group = .needs_input } },
        .{ "input", .{ .group = .needs_input } },
        .{ "queued_paused", .{ .group = .queued_paused } },
        .{ "pinned", .{ .group = .pinned } },
        .{ "done", .{ .group = .done } },
    };
    for (aliases) |a| if (std.mem.eql(u8, n, a[0])) return a[1];
    if (std.meta.stringToEnum(Group, n)) |g| return .{ .group = g };
    if (std.meta.stringToEnum(RunStatus, n)) |st| return .{ .status = st };
    return null;
}

fn kindOf(v: []const u8) ?RunKind {
    var buf: [32]u8 = undefined;
    if (v.len == 0 or v.len > buf.len) return null;
    const n = normalise(&buf, v);
    if (std.mem.eql(u8, n, "worker")) return .workflow_worker;
    if (std.mem.eql(u8, n, "bg")) return .background;
    return std.meta.stringToEnum(RunKind, n);
}

/// Lower case, `-` as `_`.
fn normalise(buf: []u8, v: []const u8) []const u8 {
    for (v, buf[0..v.len]) |c, *o| o.* = if (c == '-') '_' else std.ascii.toLower(c);
    return buf[0..v.len];
}

const Cost = struct { op: enum { gt, lt }, micros: u64 };

fn costTerm(w: []const u8) ?Cost {
    if (w.len < 6 or !std.ascii.eqlIgnoreCase(w[0..4], "cost")) return null;
    const op: @FieldType(Cost, "op") = switch (w[4]) {
        '>' => .gt,
        '<' => .lt,
        else => return null,
    };
    var num = w[5..];
    if (num.len > 0 and num[0] == '$') num = num[1..];
    const usd = std.fmt.parseFloat(f64, num) catch return null;
    if (!(usd >= 0) or usd > 1e12) return null;
    return .{ .op = op, .micros = @intFromFloat(@round(usd * 1_000_000)) };
}
