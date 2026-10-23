//! The task query language (E13.F03.S01.T01), used by the board filter,
//! task tools and task triggers. Terms are separated by spaces and all
//! must hold; a leading `-` negates one. Keys and values ignore case.
//!
//!   status:ready            status:ready,review
//!   label:docs              assignee:alice   assignee:agent:*   -assignee:*
//!   priority:P1             priority:>=P1 (P0 or P1; also <=, >, <)
//!   due:<2026-11-01         due:today   due:overdue   (also <=, >, >=, =)
//!   blocked:true            claimed:false
//!   text:"foo bar"          id:T-0042
//!   sort:priority|due|id|created|title   (`-` before the key reverses)
//!   words or "a phrase"     the title contains it
//!
//! Grammar: docs/formats/tasks.md.

const std = @import("std");
const task_mod = @import("task.zig");
const view_mod = @import("view.zig");
const ids = @import("ids.zig");
const zg_frontmatter = @import("zg_frontmatter");

const Allocator = std.mem.Allocator;
const Task = task_mod.Task;
const Status = task_mod.Status;
const Date = task_mod.Date;
const TasksView = view_mod.TasksView;

pub const Error = error{ InvalidQuery, OutOfMemory };

pub const Op = enum { eq, lt, le, gt, ge };

pub const Term = struct {
    negate: bool = false,
    kind: Kind,

    pub const Kind = union(enum) {
        status: []const Status,
        label: []const u8,
        /// `*` any, `prefix*` a prefix, else exact.
        assignee: []const u8,
        priority: struct { op: Op, value: u2 },
        due: struct { op: Op, when: When },
        blocked: bool,
        claimed: bool,
        text: []const u8,
        id: task_mod.TaskId,
    };

    pub const When = union(enum) { date: Date, today, overdue };
};

pub const SortKey = enum { id, priority, due, created, title };

pub const Query = struct {
    terms: []const Term = &.{},
    sort: SortKey = .id,
    descending: bool = false,
};

pub fn parseQuery(arena: Allocator, q: []const u8) Error!Query {
    var terms: std.ArrayList(Term) = .empty;
    var r: Query = .{};
    var i: usize = 0;
    while (true) {
        while (i < q.len and (q[i] == ' ' or q[i] == '\t')) i += 1;
        if (i >= q.len) break;
        const start = i;
        var in_quote = false;
        while (i < q.len and (in_quote or (q[i] != ' ' and q[i] != '\t'))) : (i += 1) {
            if (q[i] == '"') in_quote = !in_quote;
        }
        if (in_quote) return error.InvalidQuery;
        var tok = q[start..i];
        var negate = false;
        if (tok.len > 1 and tok[0] == '-') {
            negate = true;
            tok = tok[1..];
        }
        const colon = std.mem.indexOfScalar(u8, tok, ':');
        if (colon == null or tok[0] == '"') {
            try terms.append(arena, .{ .negate = negate, .kind = .{ .text = try unquote(arena, tok) } });
            continue;
        }
        const key = tok[0..colon.?];
        const val = tok[colon.? + 1 ..];
        if (val.len == 0) return error.InvalidQuery;
        if (eqlI(key, "sort")) {
            var v = val;
            if (v[0] == '-') {
                r.descending = true;
                v = v[1..];
            }
            r.sort = enumI(SortKey, v) orelse return error.InvalidQuery;
            continue;
        }
        const kind: Term.Kind = if (eqlI(key, "status")) blk: {
            var list: std.ArrayList(Status) = .empty;
            var it = std.mem.splitScalar(u8, val, ',');
            while (it.next()) |s| try list.append(arena, Status.parse(s) orelse return error.InvalidQuery);
            break :blk .{ .status = list.items };
        } else if (eqlI(key, "label"))
            .{ .label = try unquote(arena, val) }
        else if (eqlI(key, "assignee"))
            .{ .assignee = try unquote(arena, val) }
        else if (eqlI(key, "priority")) blk: {
            const o = splitOp(val);
            const p = o.rest;
            if (p.len != 2 or (p[0] != 'P' and p[0] != 'p') or p[1] < '0' or p[1] > '3') return error.InvalidQuery;
            break :blk .{ .priority = .{ .op = o.op, .value = @intCast(p[1] - '0') } };
        } else if (eqlI(key, "due")) blk: {
            const o = splitOp(val);
            const when: Term.When = if (eqlI(o.rest, "today"))
                .today
            else if (eqlI(o.rest, "overdue"))
                .overdue
            else
                .{ .date = zg_frontmatter.frontmatter.parseDate(o.rest) orelse return error.InvalidQuery };
            break :blk .{ .due = .{ .op = o.op, .when = when } };
        } else if (eqlI(key, "blocked"))
            .{ .blocked = try boolVal(val) }
        else if (eqlI(key, "claimed"))
            .{ .claimed = try boolVal(val) }
        else if (eqlI(key, "text"))
            .{ .text = try unquote(arena, val) }
        else if (eqlI(key, "id"))
            .{ .id = ids.parse(val) orelse return error.InvalidQuery }
        else
            return error.InvalidQuery;
        try terms.append(arena, .{ .negate = negate, .kind = kind });
    }
    r.terms = terms.items;
    return r;
}

/// Whether one task matches. `today` is needed by `due:today` and
/// `due:overdue` (which match nothing without it); `v` by `blocked:`.
pub fn matches(q: *const Query, t: *const Task, v: ?*const TasksView, today: ?Date) bool {
    for (q.terms) |*term| if (termMatches(term, t, v, today) == term.negate) return false;
    return true;
}

fn termMatches(term: *const Term, t: *const Task, v: ?*const TasksView, today: ?Date) bool {
    return switch (term.kind) {
        .status => |list| std.mem.indexOfScalar(Status, list, t.status) != null,
        .label => |l| t.hasLabel(l),
        .assignee => |p| if (t.assignee) |a| globI(p, a) else false,
        // Lower numbers are more urgent: `>=P1` means P1 or more urgent.
        .priority => |p| switch (p.op) {
            .eq => t.priority == p.value,
            .ge => t.priority <= p.value,
            .gt => t.priority < p.value,
            .le => t.priority >= p.value,
            .lt => t.priority > p.value,
        },
        .due => |d| blk: {
            const due = t.due orelse break :blk false;
            switch (d.when) {
                .overdue => {
                    const now = today orelse break :blk false;
                    break :blk cmpDate(due, now) == .lt and !t.status.finished();
                },
                .today => {
                    const now = today orelse break :blk false;
                    break :blk opHolds(d.op, cmpDate(due, now));
                },
                .date => |x| break :blk opHolds(d.op, cmpDate(due, x)),
            }
        },
        .blocked => |b| if (v) |vv| vv.isBlocked(t) == b else !b,
        .claimed => |b| (t.claimed_by != null) == b,
        .text => |s| std.ascii.indexOfIgnoreCase(t.title, s) != null,
        .id => |id| t.id == id,
    };
}

/// Indexes into `v.tasks` of the matches, in the query's order.
pub fn evalQuery(v: *const TasksView, q: *const Query, out: *std.ArrayList(u32), gpa: Allocator) !void {
    return evalQueryAt(v, q, null, out, gpa);
}

pub fn evalQueryAt(v: *const TasksView, q: *const Query, today: ?Date, out: *std.ArrayList(u32), gpa: Allocator) !void {
    const start = out.items.len;
    // Narrow by a positive status term through the index.
    var narrowed = false;
    for (q.terms) |*term| if (!term.negate and term.kind == .status) {
        for (std.meta.tags(Status)) |s| {
            if (std.mem.indexOfScalar(Status, term.kind.status, s) == null) continue;
            for (v.byStatus(s)) |i| if (matches(q, &v.tasks[i], v, today)) try out.append(gpa, i);
        }
        narrowed = true;
        break;
    };
    if (!narrowed) for (v.tasks, 0..) |*t, i| if (matches(q, t, v, today)) try out.append(gpa, @intCast(i));
    const Ctx = struct { v: *const TasksView, q: *const Query };
    std.mem.sort(u32, out.items[start..], Ctx{ .v = v, .q = q }, struct {
        fn less(c: Ctx, a: u32, b: u32) bool {
            const ta = &c.v.tasks[a];
            const tb = &c.v.tasks[b];
            const o = order(c.q.sort, ta, tb);
            // Ties keep board order either way.
            if (o == .eq) return a < b;
            return if (c.q.descending) o == .gt else o == .lt;
        }
    }.less);
}

fn order(k: SortKey, a: *const Task, b: *const Task) std.math.Order {
    return switch (k) {
        // Board order already is id order; files without an id last.
        .id => std.math.order(idKey(a.id), idKey(b.id)),
        .priority => std.math.order(a.priority, b.priority),
        .due => blk: {
            // Undated last.
            if (a.due == null and b.due == null) break :blk .eq;
            if (a.due == null) break :blk .gt;
            if (b.due == null) break :blk .lt;
            break :blk cmpDate(a.due.?, b.due.?);
        },
        .created => std.mem.order(u8, a.created orelse "", b.created orelse ""),
        .title => std.ascii.orderIgnoreCase(a.title, b.title),
    };
}

fn idKey(id: task_mod.TaskId) u64 {
    return if (id == 0) std.math.maxInt(u64) else id;
}

pub fn cmpDate(a: Date, b: Date) std.math.Order {
    if (a.y != b.y) return std.math.order(a.y, b.y);
    if (a.m != b.m) return std.math.order(a.m, b.m);
    return std.math.order(a.d, b.d);
}

fn opHolds(op: Op, o: std.math.Order) bool {
    return switch (op) {
        .eq => o == .eq,
        .lt => o == .lt,
        .le => o != .gt,
        .gt => o == .gt,
        .ge => o != .lt,
    };
}

fn splitOp(v: []const u8) struct { op: Op, rest: []const u8 } {
    const ops = [_]struct { []const u8, Op }{ .{ ">=", .ge }, .{ "<=", .le }, .{ ">", .gt }, .{ "<", .lt }, .{ "=", .eq } };
    for (ops) |o| if (std.mem.startsWith(u8, v, o[0])) return .{ .op = o[1], .rest = v[o[0].len..] };
    return .{ .op = .eq, .rest = v };
}

fn boolVal(v: []const u8) Error!bool {
    if (eqlI(v, "true") or eqlI(v, "yes")) return true;
    if (eqlI(v, "false") or eqlI(v, "no")) return false;
    return error.InvalidQuery;
}

fn unquote(arena: Allocator, s: []const u8) Error![]const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return arena.dupe(u8, s[1 .. s.len - 1]);
    if (std.mem.indexOfScalar(u8, s, '"') != null) {
        // `text:"foo bar"`: the quotes are inside the token.
        var out: std.ArrayList(u8) = .empty;
        for (s) |c| if (c != '"') try out.append(arena, c);
        return out.items;
    }
    return arena.dupe(u8, s);
}

fn eqlI(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn enumI(comptime E: type, s: []const u8) ?E {
    inline for (@typeInfo(E).@"enum".fields) |f| if (eqlI(s, f.name)) return @enumFromInt(f.value);
    return null;
}

/// Case-insensitive match with a trailing `*` wildcard.
fn globI(p: []const u8, s: []const u8) bool {
    if (std.mem.endsWith(u8, p, "*")) {
        const pre = p[0 .. p.len - 1];
        return s.len >= pre.len and eqlI(s[0..pre.len], pre);
    }
    return eqlI(p, s);
}
