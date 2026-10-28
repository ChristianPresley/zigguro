//! Commit graph walks (E09.F07): merge bases, ahead/behind counts,
//! ancestry checks and the log, painting commits in committer-date order
//! the way git's `paint_down_to_common` does.

const std = @import("std");
const commit_mod = @import("commit.zig");
const Repository = @import("repository.zig").Repository;
const Oid = @import("oid.zig").Oid;
const Allocator = std.mem.Allocator;

/// Parsed commit headers, cached for one walk.
pub const Graph = struct {
    repo: *Repository,
    arena: std.heap.ArenaAllocator,
    nodes: std.AutoHashMapUnmanaged(Oid, Node) = .empty,

    pub const Node = struct { parents: []const Oid, time: i64 };

    pub fn init(repo: *Repository) Graph {
        return .{ .repo = repo, .arena = .init(repo.gpa) };
    }

    pub fn deinit(g: *Graph) void {
        g.nodes.deinit(g.repo.gpa);
        g.arena.deinit();
    }

    pub fn node(g: *Graph, id: Oid) !Node {
        if (g.nodes.get(id)) |n| return n;
        const a = g.arena.allocator();
        var obj = try g.repo.odb.read(g.repo.gpa, id);
        defer obj.deinit(g.repo.gpa);
        if (obj.type != .commit) return error.NotACommit;
        const c = try commit_mod.parseCommit(a, g.repo.format, obj.data);
        const n: Node = .{ .parents = try a.dupe(Oid, c.parents), .time = c.committer.time };
        try g.nodes.put(g.repo.gpa, id, n);
        return n;
    }
};

const flag_a: u8 = 1;
const flag_b: u8 = 2;
const flag_stale: u8 = 4;
const flag_result: u8 = 8;

const Item = struct { id: Oid, time: i64 };

fn newer(_: void, x: Item, y: Item) std.math.Order {
    return std.math.order(y.time, x.time);
}

/// Paints from `a` (flag A) and `b` (flag B) until only stale commits
/// remain; returns the flags of every commit seen.
fn paint(g: *Graph, a: Oid, b: Oid, flags: *std.AutoHashMapUnmanaged(Oid, u8), bases: ?*std.ArrayList(Oid)) !void {
    const gpa = g.repo.gpa;
    var q: std.PriorityQueue(Item, void, newer) = .empty;
    defer q.deinit(gpa);
    try flags.put(gpa, a, flag_a);
    try q.push(gpa, .{ .id = a, .time = (try g.node(a)).time });
    const fb = (flags.get(b) orelse 0) | flag_b;
    try flags.put(gpa, b, fb);
    if (!a.eql(b)) try q.push(gpa, .{ .id = b, .time = (try g.node(b)).time });
    while (q.pop()) |it| {
        var f = flags.get(it.id).?;
        if (f & (flag_a | flag_b) == (flag_a | flag_b) and f & flag_stale == 0) {
            if (f & flag_result == 0) {
                f |= flag_result;
                if (bases) |bs| try bs.append(gpa, it.id);
            }
            f |= flag_stale;
            try flags.put(gpa, it.id, f);
        }
        for ((try g.node(it.id)).parents) |p| {
            const old = flags.get(p) orelse 0;
            const nf = old | (f & (flag_a | flag_b | flag_stale));
            if (nf == old) continue;
            try flags.put(gpa, p, nf);
            try q.push(gpa, .{ .id = p, .time = (try g.node(p)).time });
        }
        if (allStale(&q, flags)) break;
    }
}

fn allStale(q: anytype, flags: *const std.AutoHashMapUnmanaged(Oid, u8)) bool {
    for (q.items) |x| if ((flags.get(x.id) orelse 0) & flag_stale == 0) return false;
    return true;
}

/// The best common ancestors of `a` and `b` (usually one).
pub fn mergeBases(repo: *Repository, gpa: Allocator, a: Oid, b: Oid) ![]Oid {
    var g: Graph = .init(repo);
    defer g.deinit();
    var flags: std.AutoHashMapUnmanaged(Oid, u8) = .empty;
    defer flags.deinit(repo.gpa);
    var bases: std.ArrayList(Oid) = .empty;
    defer bases.deinit(repo.gpa);
    if (a.eql(b)) return gpa.dupe(Oid, &.{a});
    try paint(&g, a, b, &flags, &bases);
    // Drop candidates that are ancestors of other candidates.
    var out: std.ArrayList(Oid) = .empty;
    errdefer out.deinit(gpa);
    for (bases.items, 0..) |c, i| {
        var redundant = false;
        for (bases.items, 0..) |o, j| {
            if (i == j) continue;
            if (try reaches(&g, o, c)) {
                redundant = true;
                break;
            }
        }
        if (!redundant) try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

/// One merge base, or null for unrelated histories.
pub fn mergeBase(repo: *Repository, a: Oid, b: Oid) !?Oid {
    const all = try mergeBases(repo, repo.gpa, a, b);
    defer repo.gpa.free(all);
    return if (all.len > 0) all[0] else null;
}

/// Whether `from` reaches `to` through parents (or is it).
fn reaches(g: *Graph, from: Oid, to: Oid) !bool {
    if (from.eql(to)) return true;
    const gpa = g.repo.gpa;
    const limit = (try g.node(to)).time;
    var seen: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    defer seen.deinit(gpa);
    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, from);
    while (stack.pop()) |c| {
        if (c.eql(to)) return true;
        if ((try seen.getOrPut(gpa, c)).found_existing) continue;
        const n = try g.node(c);
        // Commits older than the target cannot lead to it (allowing a day
        // of clock skew).
        if (n.time + 86400 < limit) continue;
        for (n.parents) |p| try stack.append(gpa, p);
    }
    return false;
}

/// Whether `ancestor` is reachable from `descendant`.
pub fn isAncestor(repo: *Repository, ancestor: Oid, descendant: Oid) !bool {
    var g: Graph = .init(repo);
    defer g.deinit();
    return reaches(&g, descendant, ancestor);
}

pub const AheadBehind = struct { ahead: u32, behind: u32 };

/// Commits in `local` but not `upstream` (ahead) and the reverse.
pub fn aheadBehind(repo: *Repository, local: Oid, upstream: Oid) !AheadBehind {
    if (local.eql(upstream)) return .{ .ahead = 0, .behind = 0 };
    var g: Graph = .init(repo);
    defer g.deinit();
    var flags: std.AutoHashMapUnmanaged(Oid, u8) = .empty;
    defer flags.deinit(repo.gpa);
    // Walk everything, not just to the first common commit.
    try paintAll(&g, local, upstream, &flags);
    var r: AheadBehind = .{ .ahead = 0, .behind = 0 };
    var it = flags.iterator();
    while (it.next()) |e| switch (e.value_ptr.* & (flag_a | flag_b)) {
        flag_a => r.ahead += 1,
        flag_b => r.behind += 1,
        else => {},
    };
    return r;
}

/// Like `paint`, but stops only when the queue holds stale commits, so
/// commits reachable from one side alone are all marked.
fn paintAll(g: *Graph, a: Oid, b: Oid, flags: *std.AutoHashMapUnmanaged(Oid, u8)) !void {
    const gpa = g.repo.gpa;
    var q: std.PriorityQueue(Item, void, newer) = .empty;
    defer q.deinit(gpa);
    try flags.put(gpa, a, flag_a);
    try flags.put(gpa, b, (flags.get(b) orelse 0) | flag_b);
    try q.push(gpa, .{ .id = a, .time = (try g.node(a)).time });
    try q.push(gpa, .{ .id = b, .time = (try g.node(b)).time });
    while (q.pop()) |it| {
        var f = flags.get(it.id).?;
        if (f & (flag_a | flag_b) == (flag_a | flag_b)) f |= flag_stale;
        try flags.put(gpa, it.id, f);
        for ((try g.node(it.id)).parents) |p| {
            const old = flags.get(p) orelse 0;
            const nf = old | (f & (flag_a | flag_b | flag_stale));
            if (nf == old) continue;
            try flags.put(gpa, p, nf);
            try q.push(gpa, .{ .id = p, .time = (try g.node(p)).time });
        }
        if (allStale(&q, flags)) break;
    }
}

/// Commits reachable from `starts`, newest committer date first, at most
/// `limit` (0: no limit), excluding those reachable from `hide`.
pub fn log(repo: *Repository, gpa: Allocator, starts: []const Oid, hide: []const Oid, limit: usize) ![]Oid {
    var g: Graph = .init(repo);
    defer g.deinit();
    var hidden: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    defer hidden.deinit(repo.gpa);
    if (hide.len > 0) {
        var stack: std.ArrayList(Oid) = .empty;
        defer stack.deinit(repo.gpa);
        try stack.appendSlice(repo.gpa, hide);
        while (stack.pop()) |c| {
            if ((try hidden.getOrPut(repo.gpa, c)).found_existing) continue;
            for ((try g.node(c)).parents) |p| try stack.append(repo.gpa, p);
        }
    }
    var out: std.ArrayList(Oid) = .empty;
    errdefer out.deinit(gpa);
    var seen: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    defer seen.deinit(repo.gpa);
    var q: std.PriorityQueue(Item, void, newer) = .empty;
    defer q.deinit(repo.gpa);
    for (starts) |s| if (!(try seen.getOrPut(repo.gpa, s)).found_existing) try q.push(repo.gpa, .{ .id = s, .time = (try g.node(s)).time });
    while (q.pop()) |it| {
        if (limit != 0 and out.items.len >= limit) break;
        if (!hidden.contains(it.id)) try out.append(gpa, it.id);
        for ((try g.node(it.id)).parents) |p| {
            if ((try seen.getOrPut(repo.gpa, p)).found_existing) continue;
            try q.push(repo.gpa, .{ .id = p, .time = (try g.node(p)).time });
        }
    }
    return out.toOwnedSlice(gpa);
}
