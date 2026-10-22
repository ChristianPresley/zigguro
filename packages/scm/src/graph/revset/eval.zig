//! Revset evaluation. A revset becomes a tree of lazy iterators, each
//! yielding commit index positions in descending order. Positions are a
//! topological order (parents before children), so descending is
//! children first, as `jj log` prints.
//!
//! - Set operations merge-join their sorted inputs.
//! - Ancestor walks (`::x`, `x..y`, `x..`, `all()`) share one walker: a
//!   max-heap of positions coloured "included" or "excluded", which stops
//!   as soon as only excluded commits remain queued, as `git rev-list
//!   x..y` does. It reads its start sets lazily too, so `trunk()..@`
//!   touches only the commits between the two.
//! - Predicates (`description()`, `author()`, `empty()`...) filter a
//!   stream. Intersecting with a predicate filters the other side
//!   instead of scanning every visible commit.
//! - Functions that need a whole set (`parents()`, `roots()`,
//!   `descendants()`, `latest()`...) materialize it first.
//!
//! The deadline, when set, is checked every 4096 visited commits.

const std = @import("std");
const zg_core = @import("zg_core");
const id_mod = @import("../../store/id.zig");
const object = @import("../../store/object.zig");
const enc = @import("../../store/encode.zig");
const store_mod = @import("../../store/store.zig");
const index_mod = @import("../index.zig");
const ancestry = @import("../ancestry.zig");
const view_mod = @import("../../oplog/view.zig");
const op_mod = @import("../../oplog/operation.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const functions = @import("functions.zig");
const aliases_mod = @import("aliases.zig");
const ObjectId = id_mod.ObjectId;
const ChangeId = id_mod.ChangeId;
const Pos = index_mod.Pos;
const Node = ast.Node;
const ParseError = parser.ParseError;
const Pattern = functions.Pattern;
const RefTarget = view_mod.RefTarget;
const Allocator = std.mem.Allocator;

pub const EvalContext = struct {
    /// The commit index view; every commit the repo view names must be
    /// indexed.
    graph: *const index_mod.View,
    /// The repo view (op log): heads, refs, working copies, lanes.
    view: *const view_mod.View,
    store: *store_mod.Store,
    io: std.Io,
    /// Whose working-copy commit `@` is.
    workspace: []const u8 = "default",
    /// For `mine()`.
    user_email: []const u8 = "",
    prov: ?*const functions.ProvenanceQuery = null,
    review: ?*const functions.ReviewQuery = null,
    search: ?*const functions.HistorySearch = null,
    deadline: ?zg_core.runtime.Deadline = null,
    /// Null: the default aliases.
    aliases: ?*const aliases_mod.Aliases = null,
};

pub const Error = error{
    ParseFailed,
    /// A symbol names no bookmark, tag, git ref or commit.
    UnknownSymbol,
    /// An ID prefix matches several commits or changes.
    AmbiguousSymbol,
    /// The function needs a provider that is not available.
    Unavailable,
    InvalidArgument,
    /// A commit the view names is not in the commit index.
    NotIndexed,
    DeadlineExceeded,
};

const deadline_interval = 4096;

/// The result of an evaluation: positions in descending order.
pub const RevIter = struct {
    ev: *Evaluator,
    root: *Iter,

    pub fn next(it: *RevIter) !?Pos {
        return it.root.next(it.ev);
    }

    /// Up to `limit` positions (all when null), owned by the caller.
    pub fn collect(it: *RevIter, gpa: Allocator, limit: ?u32) ![]Pos {
        var out: std.ArrayList(Pos) = .empty;
        errdefer out.deinit(gpa);
        while (limit == null or out.items.len < limit.?) {
            const p = try it.next() orelse break;
            try out.append(gpa, p);
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn deinit(it: *RevIter) void {
        it.ev.deinit();
    }
};

/// Parses, expands aliases and builds the iterator for `src`. On failure
/// `diag` has the span, message and any suggestion.
pub fn evaluate(gpa: Allocator, ctx: *const EvalContext, src: []const u8, diag: *ParseError) !RevIter {
    const ev = try Evaluator.create(gpa, ctx, diag);
    errdefer ev.deinit();
    // Runs first: the diagnostic's text lives in the arena freed above.
    errdefer diag.keep();
    const a = ev.arena();
    const tree = try parser.parse(a, src, diag);
    var defaults: ?aliases_mod.Aliases = null;
    defer if (defaults) |*d| d.deinit();
    const al: *const aliases_mod.Aliases = ctx.aliases orelse blk: {
        defaults = try aliases_mod.Aliases.withDefaults(gpa);
        break :blk &defaults.?;
    };
    const expanded = try al.expand(a, tree, diag);
    return .{ .ev = ev, .root = try ev.build(expanded) };
}

const Flag = struct {
    const queued: u8 = 1;
    const inc: u8 = 2;
    const exc: u8 = 4;
    const done: u8 = 8;
};

/// Commits reachable from `include` and not from `exclude`, descending.
const Walk = struct {
    include: *Iter,
    exclude: ?*Iter,
    heap: std.PriorityQueue(u32, void, maxFirst) = .empty,
    flags: []u8,
    /// Queued commits that are included and not excluded.
    live: usize = 0,

    fn maxFirst(_: void, a: u32, b: u32) std.math.Order {
        return std.math.order(b, a);
    }

    fn mark(w: *Walk, ev: *Evaluator, p: u32, bit: u8) !void {
        const old = w.flags[p];
        if (old & Flag.done != 0) return;
        const new = old | bit | Flag.queued;
        if (new == old) return;
        const was_live = old & Flag.queued != 0 and old & Flag.inc != 0 and old & Flag.exc == 0;
        const now_live = new & Flag.inc != 0 and new & Flag.exc == 0;
        w.flags[p] = new;
        if (old & Flag.queued == 0) try w.heap.push(ev.gpa, p);
        if (now_live and !was_live) w.live += 1;
        if (was_live and !now_live) w.live -= 1;
    }

    /// Takes start commits at or above the heap top.
    fn pull(w: *Walk, ev: *Evaluator, it: *Iter, bit: u8) !void {
        while (try it.peek(ev)) |p| {
            if (w.heap.items.len > 0 and p.int() < w.heap.items[0]) break;
            _ = try it.next(ev);
            try w.mark(ev, p.int(), bit);
        }
    }

    fn next(w: *Walk, ev: *Evaluator) !?Pos {
        while (true) {
            // An empty heap takes one include start, then whatever is at
            // or above it.
            if (w.heap.items.len == 0) {
                const p = try w.include.next(ev) orelse return null;
                try w.mark(ev, p.int(), Flag.inc);
            }
            try w.pull(ev, w.include, Flag.inc);
            if (w.exclude) |x| try w.pull(ev, x, Flag.exc);
            if (w.live == 0 and try w.include.peek(ev) == null) return null;
            const p = w.heap.pop() orelse return null;
            try ev.tick();
            const f = w.flags[p];
            w.flags[p] = (f & ~Flag.queued) | Flag.done;
            const keep = f & Flag.exc == 0;
            if (keep) w.live -= 1;
            var ps = ev.ctx.graph.parents(Pos.of(p));
            while (ps.next()) |q| try w.mark(ev, q.int(), if (keep) Flag.inc else Flag.exc);
            if (keep) return Pos.of(p);
        }
    }

    fn deinit(w: *Walk, gpa: Allocator) void {
        w.heap.deinit(gpa);
    }
};

const SetOp = enum { @"union", inter, diff };

const Pred = union(enum) {
    description: Pattern,
    author: Pattern,
    committer: Pattern,
    mine,
    empty,
    conflicts,
    signed,
    not_root,
    files: Pattern,
    agent: ?Pattern,
    human,
    session: []const u8,
    reviewed: bool,
};

const Iter = struct {
    peeked: ?Pos = null,
    has_peek: bool = false,
    impl: Impl,

    const Impl = union(enum) {
        list: struct { items: []const Pos, i: usize = 0 },
        walk: Walk,
        merge: struct { op: SetOp, a: *Iter, b: *Iter },
        filter: struct { inner: *Iter, pred: Pred, over_all: bool },
    };

    fn peek(it: *Iter, ev: *Evaluator) anyerror!?Pos {
        if (!it.has_peek) {
            it.peeked = try it.raw(ev);
            it.has_peek = true;
        }
        return it.peeked;
    }

    fn next(it: *Iter, ev: *Evaluator) anyerror!?Pos {
        if (it.has_peek) {
            it.has_peek = false;
            return it.peeked;
        }
        return it.raw(ev);
    }

    fn raw(it: *Iter, ev: *Evaluator) anyerror!?Pos {
        switch (it.impl) {
            .list => |*l| {
                if (l.i >= l.items.len) return null;
                l.i += 1;
                return l.items[l.i - 1];
            },
            .walk => |*w| return w.next(ev),
            .merge => |m| switch (m.op) {
                .@"union" => {
                    const pa = try m.a.peek(ev);
                    const pb = try m.b.peek(ev);
                    if (pa == null) return m.b.next(ev);
                    if (pb == null) return m.a.next(ev);
                    if (pa.?.int() == pb.?.int()) {
                        _ = try m.b.next(ev);
                        return m.a.next(ev);
                    }
                    return if (pa.?.int() > pb.?.int()) m.a.next(ev) else m.b.next(ev);
                },
                .inter => while (true) {
                    const pa = try m.a.peek(ev) orelse return null;
                    const pb = try m.b.peek(ev) orelse return null;
                    if (pa.int() == pb.int()) {
                        _ = try m.b.next(ev);
                        return m.a.next(ev);
                    }
                    if (pa.int() > pb.int()) _ = try m.a.next(ev) else _ = try m.b.next(ev);
                },
                .diff => while (true) {
                    const pa = try m.a.peek(ev) orelse return null;
                    const pb = try m.b.peek(ev) orelse return m.a.next(ev);
                    if (pa.int() > pb.int()) return m.a.next(ev);
                    if (pa.int() == pb.int()) {
                        _ = try m.a.next(ev);
                        _ = try m.b.next(ev);
                        continue;
                    }
                    _ = try m.b.next(ev);
                },
            },
            .filter => |f| while (true) {
                const p = try f.inner.next(ev) orelse return null;
                try ev.tick();
                if (try ev.matches(f.pred, p)) return p;
            },
        }
    }
};

const Evaluator = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    /// Reset for every decoded commit.
    scratch: std.heap.ArenaAllocator,
    ctx: *const EvalContext,
    diag: *ParseError,
    ticks: u32 = 0,
    walks: std.ArrayList(*Walk) = .empty,
    roots_cache: ?[]const Pos = null,

    fn create(gpa: Allocator, ctx: *const EvalContext, diag: *ParseError) !*Evaluator {
        const ev = try gpa.create(Evaluator);
        ev.* = .{ .gpa = gpa, .arena_state = .init(gpa), .scratch = .init(gpa), .ctx = ctx, .diag = diag };
        return ev;
    }

    fn deinit(ev: *Evaluator) void {
        for (ev.walks.items) |w| w.deinit(ev.gpa);
        ev.scratch.deinit();
        ev.arena_state.deinit();
        ev.gpa.destroy(ev);
    }

    fn arena(ev: *Evaluator) Allocator {
        return ev.arena_state.allocator();
    }

    fn tick(ev: *Evaluator) !void {
        ev.ticks +%= 1;
        if (ev.ticks % deadline_interval != 0) return;
        if (ev.ctx.deadline) |d| if (d.expired(ev.ctx.io)) return error.DeadlineExceeded;
    }

    fn fail(ev: *Evaluator, err: Error, span: ast.Span, comptime fmt: []const u8, args: anytype) anyerror {
        const msg = std.fmt.allocPrint(ev.arena(), fmt, args) catch |e| return e;
        ev.diag.* = .{ .span = span, .message = msg };
        return err;
    }

    // Iterator constructors.

    fn iter(ev: *Evaluator, impl: Iter.Impl) !*Iter {
        const it = try ev.arena().create(Iter);
        it.* = .{ .impl = impl };
        return it;
    }

    fn list(ev: *Evaluator, items: []const Pos) !*Iter {
        return ev.iter(.{ .list = .{ .items = items } });
    }

    fn empty(ev: *Evaluator) !*Iter {
        return ev.list(&.{});
    }

    fn walk(ev: *Evaluator, include: *Iter, exclude: ?*Iter) !*Iter {
        const flags = try ev.arena().alloc(u8, ev.ctx.graph.count);
        @memset(flags, 0);
        const it = try ev.iter(.{ .walk = .{ .include = include, .exclude = exclude, .flags = flags } });
        try ev.walks.append(ev.arena(), &it.impl.walk);
        return it;
    }

    fn merge(ev: *Evaluator, op: SetOp, a: *Iter, b: *Iter) !*Iter {
        // Intersecting with a predicate over all() filters the other side.
        if (op == .inter) {
            if (overAll(b)) |pred| return ev.iter(.{ .filter = .{ .inner = a, .pred = pred, .over_all = false } });
            if (overAll(a)) |pred| return ev.iter(.{ .filter = .{ .inner = b, .pred = pred, .over_all = false } });
        }
        return ev.iter(.{ .merge = .{ .op = op, .a = a, .b = b } });
    }

    fn overAll(it: *Iter) ?Pred {
        return switch (it.impl) {
            .filter => |f| if (f.over_all) f.pred else null,
            else => null,
        };
    }

    fn all(ev: *Evaluator) !*Iter {
        return ev.walk(try ev.list(try ev.visibleHeads()), null);
    }

    fn filterAll(ev: *Evaluator, pred: Pred) !*Iter {
        return ev.iter(.{ .filter = .{ .inner = try ev.all(), .pred = pred, .over_all = true } });
    }

    /// Drains `it` into a descending slice.
    fn materialize(ev: *Evaluator, it: *Iter) ![]Pos {
        var out: std.ArrayList(Pos) = .empty;
        while (try it.next(ev)) |p| try out.append(ev.arena(), p);
        return out.items;
    }

    fn sortDesc(items: []Pos) []Pos {
        std.mem.sort(Pos, items, {}, struct {
            fn gt(_: void, a: Pos, b: Pos) bool {
                return a.int() > b.int();
            }
        }.gt);
        var n: usize = 0;
        for (items) |p| {
            if (n > 0 and items[n - 1].int() == p.int()) continue;
            items[n] = p;
            n += 1;
        }
        return items[0..n];
    }

    fn posOf(ev: *Evaluator, id: ObjectId) !Pos {
        return ev.ctx.graph.pos(id) orelse {
            var hex: [64]u8 = undefined;
            return ev.fail(error.NotIndexed, .{ 0, 0 }, "commit {s} is not in the commit index", .{id.hex(&hex)});
        };
    }

    fn visibleHeads(ev: *Evaluator) ![]const Pos {
        const heads = ev.ctx.view.heads;
        const out = try ev.arena().alloc(Pos, heads.len);
        for (heads, out) |h, *p| p.* = try ev.posOf(h);
        return sortDesc(out);
    }

    fn targetPositions(ev: *Evaluator, out: *std.ArrayList(Pos), t: RefTarget) !void {
        // A conflicted target contributes every added side.
        var i: usize = 0;
        while (i < t.terms.len) : (i += 2) {
            if (t.terms[i]) |id| try out.append(ev.arena(), try ev.posOf(id));
        }
    }

    fn isVisible(ev: *Evaluator, p: Pos) !bool {
        var w: ancestry.Walker = .init(ev.gpa);
        defer w.deinit();
        for (try ev.visibleHeads()) |h| if (try w.isAncestor(ev.ctx.graph, p, h)) return true;
        return false;
    }

    // Building.

    fn build(ev: *Evaluator, n: *Node) anyerror!*Iter {
        switch (n.kind) {
            .all => return ev.all(),
            .symbol => |s| return ev.list(try ev.resolveSymbol(n, s)),
            .working_copy => |ws| {
                const name = if (ws.len == 0) ev.ctx.workspace else ws;
                const c = ev.ctx.view.wcCommit(name) orelse return ev.fail(error.UnknownSymbol, n.span, "workspace `{s}` has no working-copy commit", .{name});
                const out = try ev.arena().alloc(Pos, 1);
                out[0] = try ev.posOf(c);
                return ev.list(out);
            },
            .remote_symbol => |r| {
                for (ev.ctx.view.remote_bookmarks) |rb| {
                    if (!std.mem.eql(u8, rb.name, r.name) or !std.mem.eql(u8, rb.remote, r.remote)) continue;
                    var out: std.ArrayList(Pos) = .empty;
                    try ev.targetPositions(&out, rb.target);
                    return ev.list(sortDesc(out.items));
                }
                var cands: std.ArrayList([]const u8) = .empty;
                for (ev.ctx.view.remote_bookmarks) |rb| try cands.append(ev.arena(), try std.fmt.allocPrint(ev.arena(), "{s}@{s}", .{ rb.name, rb.remote }));
                ev.diag.* = .{
                    .span = n.span,
                    .message = try std.fmt.allocPrint(ev.arena(), "remote bookmark `{s}@{s}` doesn't exist", .{ r.name, r.remote }),
                    .suggestion = parser.suggest(try std.fmt.allocPrint(ev.arena(), "{s}@{s}", .{ r.name, r.remote }), cands.items),
                };
                return error.UnknownSymbol;
            },
            .pattern => return ev.fail(error.InvalidArgument, n.span, "a string pattern is not a revision", .{}),
            .prefix => |p| {
                const x = try ev.build(p.operand);
                return switch (p.op) {
                    .negate => ev.merge(.diff, try ev.all(), x),
                    .dag_to => ev.walk(x, null),
                    .range_to => ev.iter(.{ .filter = .{ .inner = try ev.walk(x, null), .pred = .not_root, .over_all = false } }),
                };
            },
            .postfix => |p| {
                const x = try ev.build(p.operand);
                return switch (p.op) {
                    .parents => ev.parentsOf(x),
                    .children => ev.childrenOf(x, 1),
                    .dag_from => ev.descendantsOf(x, null),
                    .range_from => ev.walk(try ev.list(try ev.visibleHeads()), x),
                };
            },
            .binary => |b| {
                const x = try ev.build(b.lhs);
                const y = try ev.build(b.rhs);
                return switch (b.op) {
                    .@"union" => ev.merge(.@"union", x, y),
                    .intersection => ev.merge(.inter, x, y),
                    .difference => ev.merge(.diff, x, y),
                    .range => ev.walk(y, x),
                    .dag_range => ev.merge(.inter, try ev.descendantsOf(x, null), try ev.walk(y, null)),
                };
            },
            .call => |c| return ev.call(n, c.name, c.args),
        }
    }

    fn resolveSymbol(ev: *Evaluator, n: *Node, s: []const u8) ![]const Pos {
        const v = ev.ctx.view;
        var out: std.ArrayList(Pos) = .empty;
        const t = v.tag(s);
        if (!t.isAbsent()) {
            try ev.targetPositions(&out, t);
            return sortDesc(out.items);
        }
        const b = v.bookmark(s);
        if (!b.isAbsent()) {
            try ev.targetPositions(&out, b);
            return sortDesc(out.items);
        }
        for (v.git_refs) |r| if (std.mem.eql(u8, r.name, s)) {
            try ev.targetPositions(&out, r.target);
            return sortDesc(out.items);
        };
        const g = ev.ctx.graph;
        const res = try g.resolvePrefix(ev.gpa, s);
        defer res.deinit(ev.gpa);
        switch (res) {
            .commit => |p| {
                try out.append(ev.arena(), p);
                return out.items;
            },
            .change => |cid| {
                const all_ps = try g.byChangeId(ev.gpa, cid);
                defer ev.gpa.free(all_ps);
                for (all_ps) |p| if (try ev.isVisible(p)) try out.append(ev.arena(), p);
                if (out.items.len > 0) return sortDesc(out.items);
            },
            .ambiguous_commits => return ev.fail(error.AmbiguousSymbol, n.span, "commit ID prefix `{s}` is ambiguous", .{s}),
            .ambiguous_changes => return ev.fail(error.AmbiguousSymbol, n.span, "change ID prefix `{s}` is ambiguous", .{s}),
            .none, .invalid => {},
        }
        var cands: std.ArrayList([]const u8) = .empty;
        for (v.bookmarks) |r| try cands.append(ev.arena(), r.name);
        for (v.tags) |r| try cands.append(ev.arena(), r.name);
        ev.diag.* = .{
            .span = n.span,
            .message = try std.fmt.allocPrint(ev.arena(), "revision `{s}` doesn't exist", .{s}),
            .suggestion = parser.suggest(s, cands.items),
        };
        return error.UnknownSymbol;
    }

    // Set-shaped functions.

    fn parentsOf(ev: *Evaluator, x: *Iter) !*Iter {
        var out: std.ArrayList(Pos) = .empty;
        while (try x.next(ev)) |p| {
            try ev.tick();
            var ps = ev.ctx.graph.parents(p);
            while (ps.next()) |q| try out.append(ev.arena(), q);
        }
        return ev.list(sortDesc(out.items));
    }

    /// Children up to `depth` generations (x itself excluded), visible
    /// only.
    fn childrenOf(ev: *Evaluator, x: *Iter, depth: u32) !*Iter {
        const g = ev.ctx.graph;
        try g.ensureChildren();
        var frontier = try ev.materialize(x);
        var out: std.ArrayList(Pos) = .empty;
        var d: u32 = 0;
        while (d < depth and frontier.len > 0) : (d += 1) {
            var nextf: std.ArrayList(Pos) = .empty;
            for (frontier) |p| {
                try ev.tick();
                var it = g.childrenBuilt(p, null);
                while (it.next()) |c| try nextf.append(ev.arena(), c);
            }
            frontier = sortDesc(nextf.items);
            try out.appendSlice(ev.arena(), frontier);
        }
        return ev.merge(.inter, try ev.list(sortDesc(out.items)), try ev.all());
    }

    /// Descendants of x, x included, within `depth` generations (x is
    /// generation 1), visible only.
    fn descendantsOf(ev: *Evaluator, x: *Iter, depth: ?u32) !*Iter {
        if (depth) |dd| {
            if (dd == 0) return ev.empty();
            const xs = try ev.materialize(x);
            const kids = try ev.materialize(try ev.childrenOf(try ev.list(xs), dd - 1));
            return ev.merge(.inter, try ev.merge(.@"union", try ev.list(xs), try ev.list(kids)), try ev.all());
        }
        const xs = try ev.materialize(x);
        if (xs.len == 0) return ev.empty();
        const g = ev.ctx.graph;
        const min = xs[xs.len - 1].int();
        var in = try std.DynamicBitSetUnmanaged.initEmpty(ev.arena(), g.count - min);
        for (xs) |p| in.set(p.int() - min);
        var out: std.ArrayList(Pos) = .empty;
        var k: u32 = min;
        while (k < g.count) : (k += 1) {
            try ev.tick();
            if (!in.isSet(k - min)) {
                var ps = g.parents(Pos.of(k));
                while (ps.next()) |q| {
                    if (q.int() >= min and in.isSet(q.int() - min)) {
                        in.set(k - min);
                        break;
                    }
                }
            }
            if (in.isSet(k - min)) try out.append(ev.arena(), Pos.of(k));
        }
        std.mem.reverse(Pos, out.items);
        return ev.merge(.inter, try ev.list(out.items), try ev.all());
    }

    fn ancestorsDepth(ev: *Evaluator, x: *Iter, depth: u32) !*Iter {
        if (depth == 0) return ev.empty();
        var frontier = try ev.materialize(x);
        var out: std.ArrayList(Pos) = .empty;
        try out.appendSlice(ev.arena(), frontier);
        var d: u32 = 1;
        while (d < depth and frontier.len > 0) : (d += 1) {
            frontier = try ev.materialize(try ev.parentsOf(try ev.list(frontier)));
            try out.appendSlice(ev.arena(), frontier);
        }
        return ev.list(sortDesc(out.items));
    }

    /// x ~ ::(x-): members that are not ancestors of other members.
    fn headsOf(ev: *Evaluator, x: *Iter) !*Iter {
        const xs = try ev.materialize(x);
        return ev.merge(.diff, try ev.list(xs), try ev.walk(try ev.parentsOf(try ev.list(xs)), null));
    }

    /// Members with no ancestor among the other members.
    fn rootsOf(ev: *Evaluator, x: *Iter) !*Iter {
        const xs = try ev.materialize(x);
        if (xs.len == 0) return ev.empty();
        const g = ev.ctx.graph;
        const min = xs[xs.len - 1].int();
        const max = xs[0].int();
        const span = max - min + 1;
        var in = try std.DynamicBitSetUnmanaged.initEmpty(ev.arena(), span);
        var below = try std.DynamicBitSetUnmanaged.initEmpty(ev.arena(), span);
        for (xs) |p| in.set(p.int() - min);
        var out: std.ArrayList(Pos) = .empty;
        var k = min;
        while (k <= max) : (k += 1) {
            try ev.tick();
            var ps = g.parents(Pos.of(k));
            while (ps.next()) |q| {
                if (q.int() < min) continue;
                const qi = q.int() - min;
                if (in.isSet(qi) or below.isSet(qi)) {
                    below.set(k - min);
                    break;
                }
            }
            if (in.isSet(k - min) and !below.isSet(k - min)) try out.append(ev.arena(), Pos.of(k));
        }
        std.mem.reverse(Pos, out.items);
        return ev.list(out.items);
    }

    fn roots(ev: *Evaluator) !*Iter {
        if (ev.roots_cache == null) {
            const g = ev.ctx.graph;
            var out: std.ArrayList(Pos) = .empty;
            var k: u32 = g.count;
            while (k > 0) {
                k -= 1;
                try ev.tick();
                if (g.parents(Pos.of(k)).len() == 0) try out.append(ev.arena(), Pos.of(k));
            }
            ev.roots_cache = out.items;
        }
        return ev.merge(.inter, try ev.list(ev.roots_cache.?), try ev.all());
    }

    // Calls.

    fn arg(ev: *Evaluator, args: []const *Node, i: usize) !*Iter {
        return ev.build(args[i]);
    }

    fn patternArg(ev: *Evaluator, n: *Node, default_kind: []const u8) !Pattern {
        const kind, const text = switch (n.kind) {
            .pattern => |p| .{ p.kind, p.text },
            .symbol => |s| .{ default_kind, s },
            else => return ev.fail(error.InvalidArgument, n.span, "expected a string pattern", .{}),
        };
        const k = if (kind.len == 0) default_kind else kind;
        if (std.mem.eql(u8, k, "prefix")) return .{ .kind = .exact, .text = text, .case_insensitive = false, .path_prefix = true };
        return Pattern.parse(k, text) catch |e| switch (e) {
            error.Unavailable => return ev.fail(error.Unavailable, n.span, "regex patterns need zg-regex (E05.F03), which is not available yet", .{}),
            error.UnknownPatternKind => {
                ev.diag.* = .{
                    .span = n.span,
                    .message = try std.fmt.allocPrint(ev.arena(), "unknown pattern kind `{s}`", .{k}),
                    .suggestion = parser.suggest(k, &functions.pattern_kinds),
                };
                return error.InvalidArgument;
            },
        };
    }

    fn intArg(ev: *Evaluator, n: *Node) !u32 {
        const s = switch (n.kind) {
            .symbol => |s| s,
            else => return ev.fail(error.InvalidArgument, n.span, "expected a number", .{}),
        };
        return std.fmt.parseInt(u32, s, 10) catch return ev.fail(error.InvalidArgument, n.span, "expected a number, found `{s}`", .{s});
    }

    fn stringArg(ev: *Evaluator, n: *Node) ![]const u8 {
        return switch (n.kind) {
            .symbol => |s| s,
            else => return ev.fail(error.InvalidArgument, n.span, "expected a string", .{}),
        };
    }

    fn needs(ev: *Evaluator, present: bool, n: *Node, name: []const u8, what: []const u8) !void {
        if (!present) return ev.fail(error.Unavailable, n.span, "`{s}()` needs {s}, which is not available", .{ name, what });
    }

    fn call(ev: *Evaluator, n: *Node, name: []const u8, args: []const *Node) anyerror!*Iter {
        const eq = std.mem.eql;
        const v = ev.ctx.view;
        if (eq(u8, name, "all")) return ev.all();
        if (eq(u8, name, "none")) return ev.empty();
        if (eq(u8, name, "root")) return ev.roots();
        if (eq(u8, name, "visible_heads")) return ev.list(try ev.visibleHeads());
        if (eq(u8, name, "heads")) return ev.headsOf(try ev.arg(args, 0));
        if (eq(u8, name, "roots")) return ev.rootsOf(try ev.arg(args, 0));
        if (eq(u8, name, "parents")) return ev.parentsOf(try ev.arg(args, 0));
        if (eq(u8, name, "children")) return ev.childrenOf(try ev.arg(args, 0), 1);
        if (eq(u8, name, "ancestors")) {
            const x = try ev.arg(args, 0);
            if (args.len == 2) return ev.ancestorsDepth(x, try ev.intArg(args[1]));
            return ev.walk(x, null);
        }
        if (eq(u8, name, "descendants")) {
            const x = try ev.arg(args, 0);
            return ev.descendantsOf(x, if (args.len == 2) try ev.intArg(args[1]) else null);
        }
        if (eq(u8, name, "description")) return ev.filterAll(.{ .description = try ev.patternArg(args[0], "substring") });
        if (eq(u8, name, "author")) return ev.filterAll(.{ .author = try ev.patternArg(args[0], "substring") });
        if (eq(u8, name, "committer")) return ev.filterAll(.{ .committer = try ev.patternArg(args[0], "substring") });
        if (eq(u8, name, "mine")) return ev.filterAll(.mine);
        if (eq(u8, name, "empty")) return ev.filterAll(.empty);
        if (eq(u8, name, "conflicts")) return ev.filterAll(.conflicts);
        if (eq(u8, name, "signed")) return ev.filterAll(.signed);
        if (eq(u8, name, "files")) return ev.filterAll(.{ .files = try ev.patternArg(args[0], "prefix") });
        if (eq(u8, name, "bookmarks") or eq(u8, name, "tags")) {
            const p: ?Pattern = if (args.len > 0) try ev.patternArg(args[0], "substring") else null;
            var out: std.ArrayList(Pos) = .empty;
            for (if (eq(u8, name, "tags")) v.tags else v.bookmarks) |r| {
                if (p) |pp| if (!pp.matches(r.name)) continue;
                try ev.targetPositions(&out, r.target);
            }
            return ev.list(sortDesc(out.items));
        }
        if (eq(u8, name, "remote_bookmarks") or eq(u8, name, "untracked_remote_bookmarks")) {
            const untracked = eq(u8, name, "untracked_remote_bookmarks");
            const p: ?Pattern = if (args.len > 0) try ev.patternArg(args[0], "substring") else null;
            const rp: ?Pattern = if (args.len > 1) try ev.patternArg(args[1], "substring") else null;
            var out: std.ArrayList(Pos) = .empty;
            for (v.remote_bookmarks) |r| {
                if (untracked and r.tracked) continue;
                if (p) |pp| if (!pp.matches(r.name)) continue;
                if (rp) |pp| if (!pp.matches(r.remote)) continue;
                try ev.targetPositions(&out, r.target);
            }
            return ev.list(sortDesc(out.items));
        }
        if (eq(u8, name, "trunk")) {
            for ([_][]const u8{ "main", "master", "trunk" }) |b| {
                for (v.remote_bookmarks) |r| {
                    if (!eq(u8, r.remote, "origin") or !eq(u8, r.name, b) or r.target.isAbsent()) continue;
                    var out: std.ArrayList(Pos) = .empty;
                    try ev.targetPositions(&out, r.target);
                    return ev.list(sortDesc(out.items));
                }
            }
            return ev.roots();
        }
        if (eq(u8, name, "present")) {
            if (ev.build(args[0])) |it| return it else |e| {
                if (e == error.UnknownSymbol) return ev.empty();
                return e;
            }
        }
        if (eq(u8, name, "latest")) {
            const xs = try ev.materialize(try ev.arg(args, 0));
            const count = if (args.len == 2) try ev.intArg(args[1]) else 1;
            const g = ev.ctx.graph;
            std.mem.sort(Pos, xs, g, struct {
                fn newer(gg: *const index_mod.View, a: Pos, b: Pos) bool {
                    const ta = gg.entry(a).time_ms;
                    const tb = gg.entry(b).time_ms;
                    return if (ta != tb) ta > tb else a.int() > b.int();
                }
            }.newer);
            return ev.list(sortDesc(xs[0..@min(count, xs.len)]));
        }
        if (eq(u8, name, "fork_point")) {
            const xs = try ev.materialize(try ev.arg(args, 0));
            if (xs.len == 0) return ev.empty();
            var w: ancestry.Walker = .init(ev.gpa);
            defer w.deinit();
            var bases: []Pos = try ev.arena().dupe(Pos, xs[0..1]);
            for (xs[1..]) |x| {
                var nb: std.ArrayList(Pos) = .empty;
                for (bases) |b| {
                    const mb = try w.mergeBases(ev.ctx.graph, ev.gpa, b, x);
                    defer ev.gpa.free(mb);
                    try nb.appendSlice(ev.arena(), mb);
                }
                bases = sortDesc(nb.items);
            }
            return ev.headsOf(try ev.list(bases));
        }
        if (eq(u8, name, "divergent")) {
            const xs = try ev.materialize(try ev.all());
            var counts: std.AutoHashMapUnmanaged(ChangeId, u32) = .empty;
            defer counts.deinit(ev.gpa);
            for (xs) |p| {
                const gop = try counts.getOrPut(ev.gpa, ev.ctx.graph.changeId(p));
                gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
            }
            var out: std.ArrayList(Pos) = .empty;
            for (xs) |p| if (counts.get(ev.ctx.graph.changeId(p)).? > 1) try out.append(ev.arena(), p);
            return ev.list(out.items);
        }
        if (eq(u8, name, "agent")) {
            try ev.needs(ev.ctx.prov != null, n, name, "the provenance index (F05)");
            return ev.filterAll(.{ .agent = if (args.len > 0) try ev.patternArg(args[0], "substring") else null });
        }
        if (eq(u8, name, "human")) {
            try ev.needs(ev.ctx.prov != null, n, name, "the provenance index (F05)");
            return ev.filterAll(.human);
        }
        if (eq(u8, name, "session")) {
            try ev.needs(ev.ctx.prov != null, n, name, "the provenance index (F05)");
            return ev.filterAll(.{ .session = try ev.stringArg(args[0]) });
        }
        if (eq(u8, name, "reviewed") or eq(u8, name, "unreviewed")) {
            try ev.needs(ev.ctx.review != null, n, name, "the review adapter (E12)");
            return ev.filterAll(.{ .reviewed = eq(u8, name, "reviewed") });
        }
        if (eq(u8, name, "why")) {
            try ev.needs(ev.ctx.search != null, n, name, "history search (F05)");
            const s = ev.ctx.search.?;
            const ids = try s.blame(s.ctx, ev.arena(), try ev.stringArg(args[0]), try ev.intArg(args[1]));
            const out = try ev.arena().alloc(Pos, ids.len);
            for (ids, out) |id, *p| p.* = try ev.posOf(id);
            return ev.list(sortDesc(out));
        }
        if (eq(u8, name, "lane")) {
            const p: ?Pattern = if (args.len > 0) try ev.patternArg(args[0], "substring") else null;
            var acc = try ev.empty();
            for (v.lanes) |l| {
                if (p) |pp| if (!pp.matches(l.name)) continue;
                const wc = v.wcCommit(l.workspace) orelse continue;
                const inc = try ev.arena().alloc(Pos, 1);
                inc[0] = try ev.posOf(wc);
                var exc: ?*Iter = null;
                if (l.base) |b| {
                    const e = try ev.arena().alloc(Pos, 1);
                    e[0] = try ev.posOf(b);
                    exc = try ev.list(e);
                }
                acc = try ev.merge(.@"union", acc, try ev.walk(try ev.list(inc), exc));
            }
            return acc;
        }
        if (eq(u8, name, "evolog")) {
            const xs = try ev.materialize(try ev.arg(args, 0));
            var seen = try std.DynamicBitSetUnmanaged.initEmpty(ev.arena(), ev.ctx.graph.count);
            var stack: std.ArrayList(Pos) = .empty;
            var out: std.ArrayList(Pos) = .empty;
            try stack.appendSlice(ev.arena(), xs);
            while (stack.pop()) |p| {
                if (seen.isSet(p.int())) continue;
                seen.set(p.int());
                try ev.tick();
                try out.append(ev.arena(), p);
                var ps = ev.ctx.graph.predecessors(p);
                while (ps.next()) |q| try stack.append(ev.arena(), q);
            }
            return ev.list(sortDesc(out.items));
        }
        if (eq(u8, name, "touched_by_op")) {
            const text = try ev.stringArg(args[0]);
            const op_id = ObjectId.parseHex(text) catch return ev.fail(error.InvalidArgument, args[0].span, "expected a full operation ID", .{});
            const a = ev.arena();
            const o = op_mod.read(op_mod.Operation, ev.ctx.store, a, op_id) catch return ev.fail(error.UnknownSymbol, args[0].span, "operation `{s}` doesn't exist", .{text});
            const nv = try op_mod.read(view_mod.View, ev.ctx.store, a, o.view);
            var old: std.ArrayList(Pos) = .empty;
            for (o.parents) |pid| {
                const po = try op_mod.read(op_mod.Operation, ev.ctx.store, a, pid);
                const pv = try op_mod.read(view_mod.View, ev.ctx.store, a, po.view);
                for (pv.heads) |h| try old.append(a, try ev.posOf(h));
            }
            var new: std.ArrayList(Pos) = .empty;
            for (nv.heads) |h| try new.append(a, try ev.posOf(h));
            return ev.walk(try ev.list(sortDesc(new.items)), try ev.list(sortDesc(old.items)));
        }
        return ev.fail(error.InvalidArgument, n.span, "function `{s}` is not implemented", .{name});
    }

    // Predicates.

    fn matches(ev: *Evaluator, pred: Pred, p: Pos) !bool {
        const g = ev.ctx.graph;
        switch (pred) {
            .empty => return g.entry(p).flags.empty,
            .conflicts => return g.entry(p).flags.conflict,
            .signed => return g.entry(p).flags.signed,
            .not_root => return g.parents(p).len() > 0,
            .agent => |pat| {
                const pv = ev.ctx.prov.?;
                return pv.hasAgentLines(pv.ctx, g.id(p), pat);
            },
            .human => {
                const pv = ev.ctx.prov.?;
                return !try pv.hasAgentLines(pv.ctx, g.id(p), null);
            },
            .session => |s| {
                const pv = ev.ctx.prov.?;
                return pv.inSession(pv.ctx, g.id(p), s);
            },
            .reviewed => |want| {
                const r = ev.ctx.review.?;
                return try r.isReviewed(r.ctx, g.id(p)) == want;
            },
            else => {},
        }
        _ = ev.scratch.reset(.retain_capacity);
        const c = try ev.readChange(g.id(p));
        return switch (pred) {
            .description => |pat| pat.matches(c.description),
            .author => |pat| pat.matches(c.author.name) or pat.matches(c.author.email),
            .committer => |pat| pat.matches(c.committer.name) or pat.matches(c.committer.email),
            .mine => ev.ctx.user_email.len > 0 and std.ascii.eqlIgnoreCase(c.author.email, ev.ctx.user_email),
            .files => |pat| blk: {
                const tree = c.tree_terms[0];
                if (c.parents.len == 0) break :blk try ev.treeDiffMatches(null, tree, "", pat);
                // Merges compare against the first parent.
                const parent = try ev.readChange(c.parents[0]);
                break :blk try ev.treeDiffMatches(parent.tree_terms[0], tree, "", pat);
            },
            else => unreachable,
        };
    }

    fn readChange(ev: *Evaluator, id: ObjectId) !object.Change {
        return op_mod.read(object.Change, ev.ctx.store, ev.scratch.allocator(), id);
    }

    fn readTree(ev: *Evaluator, id: ?ObjectId) ![]const object.TreeEntry {
        const t = id orelse return &.{};
        return (try op_mod.read(object.Tree, ev.ctx.store, ev.scratch.allocator(), t)).entries;
    }

    /// Whether any path that differs between trees `a` and `b` matches.
    fn treeDiffMatches(ev: *Evaluator, a: ?ObjectId, b: ?ObjectId, prefix: []const u8, pat: Pattern) !bool {
        if (a != null and b != null and a.?.eql(b.?)) return false;
        const ea = try ev.readTree(a);
        const eb = try ev.readTree(b);
        const sa = ev.scratch.allocator();
        var names: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (ea) |e| try names.put(sa, e.name, {});
        for (eb) |e| try names.put(sa, e.name, {});
        for (names.keys()) |name| {
            const x = findEntry(ea, name);
            const y = findEntry(eb, name);
            if (x != null and y != null and x.?.kind == y.?.kind and x.?.id.eql(y.?.id)) continue;
            const path = if (prefix.len == 0) name else try std.fmt.allocPrint(sa, "{s}/{s}", .{ prefix, name });
            const x_tree = x != null and x.?.kind == .tree;
            const y_tree = y != null and y.?.kind == .tree;
            if ((x != null and !x_tree) or (y != null and !y_tree)) {
                if (pat.matches(path)) return true;
            }
            if (x_tree or y_tree) {
                if (try ev.treeDiffMatches(if (x_tree) x.?.id else null, if (y_tree) y.?.id else null, path, pat)) return true;
            }
        }
        return false;
    }

    fn findEntry(entries: []const object.TreeEntry, name: []const u8) ?object.TreeEntry {
        for (entries) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }
};
