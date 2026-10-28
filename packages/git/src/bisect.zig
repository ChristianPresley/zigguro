//! `git bisect` (E09.F07): finding the commit that introduced a change by
//! binary search, with git's own state (`.git/BISECT_*`,
//! `refs/bisect/*`), so git can carry on a bisection started here and
//! the other way around.
//!
//! The commit to test is chosen the way git's `find_bisection` chooses
//! it: of the commits reachable from the bad one and from no good one,
//! the one whose ancestors in that set are closest to half of it (the
//! first found half-way, walking from the oldest). Skipped commits are
//! stepped around with git's pseudo-random `skip_away`. Pathspecs
//! (`git bisect start -- <paths>`), `--no-checkout`, `--first-parent`
//! and `bisect run` are not supported.

const std = @import("std");
const commit_mod = @import("commit.zig");
const revparse = @import("revparse.zig");
const revwalk = @import("revwalk.zig");
const checkout = @import("checkout.zig");
const Repository = @import("repository.zig").Repository;
const Oid = @import("oid.zig").Oid;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Terms = struct { bad: []const u8 = "bad", good: []const u8 = "good" };

pub const StartOptions = struct {
    /// The bad commit and the good ones, as given (revisions).
    bad: ?[]const u8 = null,
    goods: []const []const u8 = &.{},
    terms: Terms = .{},
    tz_offset_min: i32 = 0,
};

/// Where a bisection stands after a step.
pub const Next = union(enum) {
    /// Waiting for a bad commit, good commits, or both.
    waiting,
    /// This commit is checked out for testing.
    testing: Oid,
    /// The first bad commit (the caller shows it like `git show --stat`).
    found: Oid,
    /// Only skipped commits are left; the first bad one is among them.
    only_skipped,
};

pub const Mark = enum { bad, good, skip };

/// Whether a bisection is in progress.
pub fn inProgress(repo: *Repository) bool {
    _ = repo.git_dir.statFile(repo.io, "BISECT_START", .{}) catch return false;
    return true;
}

/// The terms of the bisection in progress (owned by `a`).
pub fn terms(repo: *Repository, a: Allocator) !Terms {
    const text = repo.git_dir.readFileAlloc(repo.io, "BISECT_TERMS", a, .limited(4096)) catch return .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    const bad = it.next() orelse return .{};
    const good = it.next() orelse return .{};
    if (bad.len == 0 or good.len == 0) return .{};
    return .{ .bad = bad, .good = good };
}

/// `git bisect start [<bad> [<good>...]]`: a bisection already in
/// progress is reset first. `out` gets what git prints.
pub fn start(repo: *Repository, gpa: Allocator, opts: StartOptions, out: *Writer) !Next {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (inProgress(repo)) try reset(repo, gpa, null, opts.tz_offset_min, null);
    for ([_][]const u8{ opts.terms.bad, opts.terms.good }) |t| if (!validTerm(t)) return error.InvalidTerm;
    if (std.mem.eql(u8, opts.terms.bad, opts.terms.good)) return error.InvalidTerm;

    // Resolve everything before writing any state.
    const bad: ?Oid = if (opts.bad) |b| try revparse.resolveCommit(repo, b) else null;
    const goods = try a.alloc(Oid, opts.goods.len);
    for (opts.goods, goods) |s, *g| g.* = try revparse.resolveCommit(repo, s);

    const head_name = if (try repo.headRef(a)) |r|
        (if (std.mem.startsWith(u8, r, "refs/heads/")) r["refs/heads/".len..] else r)
    else blk: {
        var hb: [64]u8 = undefined;
        const h = (try repo.head()) orelse return error.UnbornHead;
        break :blk try a.dupe(u8, h.hex(&hb));
    };
    try writeState(repo, "BISECT_START", try std.fmt.allocPrint(a, "{s}\n", .{head_name}));
    // The terms are written once a commit is marked (or chosen).
    const custom = !std.mem.eql(u8, opts.terms.bad, "bad") or !std.mem.eql(u8, opts.terms.good, "good");
    if (custom or bad != null or goods.len > 0) try writeTerms(repo, a, opts.terms);
    try writeState(repo, "BISECT_NAMES", "\n");

    var log: std.ArrayList(u8) = .empty;
    if (bad) |b| {
        try setRef(repo, a, opts.terms.bad, b, true);
        try logMark(repo, a, &log, opts.terms.bad, b);
    }
    for (goods) |g| {
        try setRef(repo, a, opts.terms.good, g, false);
        try logMark(repo, a, &log, opts.terms.good, g);
    }
    try log.appendSlice(a, "git bisect start");
    if (!std.mem.eql(u8, opts.terms.bad, "bad")) try log.print(a, " '--term-new={s}'", .{opts.terms.bad});
    if (!std.mem.eql(u8, opts.terms.good, "good")) try log.print(a, " '--term-old={s}'", .{opts.terms.good});
    if (opts.bad) |s| try log.print(a, " '{s}'", .{s});
    for (opts.goods) |s| try log.print(a, " '{s}'", .{s});
    try log.append(a, '\n');
    try writeState(repo, "BISECT_LOG", log.items);
    // With nothing given, the status goes to the log too.
    if (bad == null or goods.len == 0) return status(repo, a, opts.terms, out, bad != null, goods.len);
    return next(repo, a, opts.terms, opts.tz_offset_min, out);
}

/// `git bisect bad|good|skip [<rev>...]` (HEAD when none is given).
pub fn mark(repo: *Repository, gpa: Allocator, m: Mark, revs: []const []const u8, tz_offset_min: i32, out: *Writer) !Next {
    if (!inProgress(repo)) return error.NotBisecting;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try terms(repo, a);
    var ids: std.ArrayList(Oid) = .empty;
    if (revs.len == 0) {
        try ids.append(a, (try repo.head()) orelse return error.UnbornHead);
    } else for (revs) |r| try ids.append(a, try revparse.resolveCommit(repo, r));
    if (m == .bad and ids.items.len > 1) return error.OneBadCommit;
    var log: std.ArrayList(u8) = .empty;
    const term = switch (m) {
        .bad => t.bad,
        .good => t.good,
        .skip => "skip",
    };
    if (m != .skip) if (repo.git_dir.statFile(repo.io, "BISECT_TERMS", .{})) |_| {} else |_| try writeTerms(repo, a, t);
    for (ids.items) |id| {
        switch (m) {
            .bad => try setRef(repo, a, t.bad, id, true),
            .good => try setRef(repo, a, t.good, id, false),
            .skip => try setRef(repo, a, "skip", id, false),
        }
        try logMark(repo, a, &log, term, id);
        var hb: [64]u8 = undefined;
        try log.print(a, "git bisect {s} {s}\n", .{ term, id.hex(&hb) });
    }
    try appendLog(repo, a, log.items);
    const bad = try repo.refs.resolve(try std.fmt.allocPrint(a, "refs/bisect/{s}", .{t.bad}));
    const goods = try listRefs(repo, a, t.good);
    if (bad == null or goods.len == 0) return status(repo, a, t, out, bad != null, goods.len);
    return next(repo, a, t, tz_offset_min, out);
}

/// `git bisect reset [<commit>]`: back to the branch the bisection began
/// on (or `commit`), and the state is removed. `out` gets nothing (git
/// prints the checkout's own messages to stderr).
pub fn reset(repo: *Repository, gpa: Allocator, commit: ?[]const u8, tz_offset_min: i32, out: ?*Writer) !void {
    _ = out;
    if (!inProgress(repo)) return error.NotBisecting;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const orig = std.mem.trimEnd(u8, try repo.git_dir.readFileAlloc(repo.io, "BISECT_START", a, .limited(4096)), "\n");
    const target = commit orelse orig;
    if (target.len > 0) {
        const branch_ref = try std.fmt.allocPrint(a, "refs/heads/{s}", .{target});
        const head_ref = try repo.headRef(a);
        const on_it = if (head_ref) |r| std.mem.eql(u8, r, branch_ref) else blk: {
            // Detached at the commit asked for: git leaves HEAD alone.
            if ((try repo.refs.resolve(branch_ref)) != null) break :blk false;
            const want = revparse.resolveCommit(repo, target) catch break :blk false;
            break :blk if (try repo.head()) |h| h.eql(want) else false;
        };
        // Already there: nothing to do.
        if (!on_it) _ = try checkout.switchTo(repo, a, target, .{ .tz_offset_min = tz_offset_min });
    }
    try clean(repo, a);
}

/// The bisection's log, as `git bisect log` prints it (owned by `gpa`).
pub fn readLog(repo: *Repository, gpa: Allocator) ![]u8 {
    if (!inProgress(repo)) return error.NotBisecting;
    return repo.git_dir.readFileAlloc(repo.io, "BISECT_LOG", gpa, .limited(64 << 20));
}

fn validTerm(t: []const u8) bool {
    if (t.len == 0) return false;
    for ([_][]const u8{ "help", "start", "skip", "next", "reset", "visualize", "view", "replay", "log", "run", "terms" }) |r| if (std.mem.eql(u8, t, r)) return false;
    for (t) |c| if (c <= ' ' or c == '/' or c == '\\' or c == ':' or c == '~' or c == '^') return false;
    return true;
}

fn writeState(repo: *Repository, name: []const u8, data: []const u8) !void {
    try repo.git_dir.writeFile(repo.io, .{ .sub_path = name, .data = data });
}

fn writeTerms(repo: *Repository, a: Allocator, t: Terms) !void {
    try writeState(repo, "BISECT_TERMS", try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ t.bad, t.good }));
}

fn appendLog(repo: *Repository, a: Allocator, text: []const u8) !void {
    const old = repo.git_dir.readFileAlloc(repo.io, "BISECT_LOG", a, .limited(64 << 20)) catch "";
    try writeState(repo, "BISECT_LOG", try std.mem.concat(a, u8, &.{ old, text }));
}

/// refs/bisect/<term> (the bad one) or refs/bisect/<term>-<id>.
fn setRef(repo: *Repository, a: Allocator, term: []const u8, id: Oid, single: bool) !void {
    var hb: [64]u8 = undefined;
    const name = if (single)
        try std.fmt.allocPrint(a, "refs/bisect/{s}", .{term})
    else
        try std.fmt.allocPrint(a, "refs/bisect/{s}-{s}", .{ term, id.hex(&hb) });
    var tx = repo.refs.transaction();
    defer tx.deinit();
    try tx.update(name, .{ .direct = id }, null, "", .{ .name = "", .email = "", .time = 0, .tz = "+0000" });
    try tx.commit();
}

/// The commits of refs/bisect/<prefix>-*.
fn listRefs(repo: *Repository, a: Allocator, prefix: []const u8) ![]Oid {
    const p = try std.fmt.allocPrint(a, "refs/bisect/{s}-", .{prefix});
    var list = try repo.refs.iterate(a, p);
    defer list.deinit();
    var out: std.ArrayList(Oid) = .empty;
    for (list.refs) |r| if (try repo.refs.resolve(r.name)) |id| try out.append(a, id);
    return out.items;
}

fn subjectOf(repo: *Repository, a: Allocator, id: Oid) ![]const u8 {
    const obj = try repo.odb.read(a, id);
    if (obj.type != .commit) return error.NotACommit;
    const c = try commit_mod.parseCommit(a, repo.format, obj.data);
    // %s: the first paragraph, its lines joined by spaces.
    const end = std.mem.indexOf(u8, c.message, "\n\n") orelse c.message.len;
    const para = std.mem.trimEnd(u8, c.message[0..end], "\n");
    const s = try a.dupe(u8, para);
    std.mem.replaceScalar(u8, s, '\n', ' ');
    return s;
}

/// "# <term>: [<id>] <subject>\n".
fn logMark(repo: *Repository, a: Allocator, log: *std.ArrayList(u8), term: []const u8, id: Oid) !void {
    var hb: [64]u8 = undefined;
    try log.print(a, "# {s}: [{s}] {s}\n", .{ term, id.hex(&hb), try subjectOf(repo, a, id) });
}

fn status(repo: *Repository, a: Allocator, t: Terms, out: *Writer, have_bad: bool, goods: usize) !Next {
    var line: std.ArrayList(u8) = .empty;
    if (!have_bad and goods == 0) {
        try line.print(a, "status: waiting for both {s} and {s} commits\n", .{ t.good, t.bad });
    } else if (!have_bad) {
        try line.print(a, "status: waiting for {s} commit, {d} {s} commit{s} known\n", .{ t.bad, goods, t.good, if (goods == 1) "" else "s" });
    } else {
        try line.print(a, "status: waiting for {s} commit(s), {s} commit known\n", .{ t.good, t.bad });
    }
    try out.writeAll(line.items);
    try appendLog(repo, a, try std.mem.concat(a, u8, &.{ "# ", line.items }));
    return .waiting;
}

/// Checks that the good commits are ancestors of the bad one (testing a
/// merge base first when one is not), then picks the next commit.
fn next(repo: *Repository, a: Allocator, t: Terms, tz: i32, out: *Writer) !Next {
    const bad = (try repo.refs.resolve(try std.fmt.allocPrint(a, "refs/bisect/{s}", .{t.bad}))).?;
    const goods = try listRefs(repo, a, t.good);
    const skips = try listRefs(repo, a, "skip");
    var hb: [64]u8 = undefined;

    const ok = if (repo.git_dir.statFile(repo.io, "BISECT_ANCESTORS_OK", .{})) |_| true else |_| false;
    if (!ok) {
        for (goods) |g| {
            const bases = try revwalk.mergeBases(repo, a, bad, g);
            for (bases) |mb| {
                if (mb.eql(bad)) {
                    // git says which on stderr: a bug fixed between the
                    // two, or good and bad swapped.
                    const expected = repo.git_dir.readFileAlloc(repo.io, "BISECT_EXPECTED_REV", a, .limited(256)) catch "";
                    return if (std.mem.eql(u8, std.mem.trimEnd(u8, expected, "\n"), bad.hex(&hb))) error.MergeBaseIsBad else error.GoodNotAncestorOfBad;
                }
                if (contains(goods, mb) or contains(skips, mb)) continue;
                try out.writeAll("Bisecting: a merge base must be tested\n");
                try testCommit(repo, a, mb, tz, out);
                return .{ .testing = mb };
            }
        }
        try writeState(repo, "BISECT_ANCESTORS_OK", "");
    }

    // The candidates: reachable from bad, from no good; oldest first.
    const listed = try revwalk.log(repo, a, &.{bad}, goods, 0);
    std.mem.reverse(Oid, listed);
    var g: revwalk.Graph = .init(repo);
    defer g.deinit();
    if (listed.len == 0) {
        try out.print("{s} was both {s} and {s}\n", .{ bad.hex(&hb), t.good, t.bad });
        return error.BothGoodAndBad;
    }
    const pick = try findBisection(a, &g, listed, skips.len > 0);
    var chosen: ?Oid = pick.list[0];
    if (skips.len > 0) chosen = managedSkipped(pick.list, skips, bad);
    const c = chosen orelse return onlySkipped(repo, a, pick.list, skips, bad, t, out);
    if (c.eql(bad)) {
        // Skipped candidates could be the first bad commit as well.
        for (pick.list) |x| if (contains(skips, x)) {
            chosen = null;
            break;
        };
        if (chosen == null) return onlySkipped(repo, a, pick.list, skips, bad, t, out);
        try out.print("{s} is the first {s} commit\n", .{ c.hex(&hb), t.bad });
        try appendLog(repo, a, try std.fmt.allocPrint(a, "# first {s} commit: [{s}] {s}\n", .{ t.bad, c.hex(&hb), try subjectOf(repo, a, c) }));
        return .{ .found = c };
    }
    const left = pick.all - pick.reaches - 1;
    const steps = estimateSteps(pick.all);
    try out.print("Bisecting: {d} revision{s} left to test after this (roughly {d} step{s})\n", .{
        left, if (left == 1) "" else "s", steps, if (steps == 1) "" else "s",
    });
    try testCommit(repo, a, c, tz, out);
    return .{ .testing = c };
}

fn onlySkipped(repo: *Repository, a: Allocator, list: []const Oid, skips: []const Oid, bad: Oid, t: Terms, out: *Writer) !Next {
    var hb: [64]u8 = undefined;
    var log: std.ArrayList(u8) = .empty;
    try log.appendSlice(a, "# only skipped commits left to test\n");
    try log.print(a, "# possible first {s} commit: [{s}] {s}\n", .{ t.bad, bad.hex(&hb), try subjectOf(repo, a, bad) });
    for (list) |x| if (contains(skips, x)) try log.print(a, "# possible first {s} commit: [{s}] {s}\n", .{ t.bad, x.hex(&hb), try subjectOf(repo, a, x) });
    try appendLog(repo, a, log.items);
    try out.print("There are only 'skip'ped commits left to test.\nThe first {s} commit could be any of:\n", .{t.bad});
    for (list) |x| if (contains(skips, x)) try out.print("{s}\n", .{x.hex(&hb)});
    try out.print("{s}\nWe cannot bisect more!\n", .{bad.hex(&hb)});
    return .only_skipped;
}

/// Checks out `id` (detached) and prints "[<id>] <subject>".
fn testCommit(repo: *Repository, a: Allocator, id: Oid, tz: i32, out: *Writer) !void {
    var hb: [64]u8 = undefined;
    const hex = id.hex(&hb);
    try writeState(repo, "BISECT_EXPECTED_REV", try std.fmt.allocPrint(a, "{s}\n", .{hex}));
    _ = try checkout.switchTo(repo, a, hex, .{ .detach = true, .tz_offset_min = tz });
    try out.print("[{s}] {s}\n", .{ hex, try subjectOf(repo, a, id) });
}

fn contains(list: []const Oid, id: Oid) bool {
    for (list) |x| if (x.eql(id)) return true;
    return false;
}

/// Removes the state files and refs/bisect/*.
fn clean(repo: *Repository, a: Allocator) !void {
    var list = try repo.refs.iterate(a, "refs/bisect/");
    defer list.deinit();
    if (list.refs.len > 0) {
        var tx = repo.refs.transaction();
        defer tx.deinit();
        for (list.refs) |r| try tx.delete(r.name, null, "");
        try tx.commit();
    }
    for ([_][]const u8{ "BISECT_EXPECTED_REV", "BISECT_ANCESTORS_OK", "BISECT_LOG", "BISECT_TERMS", "BISECT_NAMES", "BISECT_RUN", "BISECT_FIRST_PARENT", "BISECT_HEAD", "BISECT_START" }) |f|
        repo.git_dir.deleteFile(repo.io, f) catch {};
}

/// git's `estimate_bisect_steps`.
pub fn estimateSteps(all: usize) usize {
    if (all < 3) return 0;
    const n = std.math.log2_int(usize, all);
    const e = @as(usize, 1) << @intCast(n);
    const x = all - e;
    return if (e < 3 * x) n else n - 1;
}

const Pick = struct {
    /// The best commit first; with `all_sorted`, every candidate by
    /// distance (best first, ties by id).
    list: []Oid,
    all: usize,
    /// How many candidates the best one reaches (itself included).
    reaches: usize,
};

/// git's `find_bisection` over `list` (oldest first).
fn findBisection(a: Allocator, g: *revwalk.Graph, list: []const Oid, find_all: bool) !Pick {
    const nr = list.len;
    var index: std.AutoHashMapUnmanaged(Oid, usize) = .empty;
    for (list, 0..) |id, i| try index.put(a, id, i);
    const weights = try a.alloc(i64, nr);
    var counted: usize = 0;
    for (list, 0..) |id, i| {
        var n: usize = 0;
        for ((try g.node(id)).parents) |p| {
            if (index.contains(p)) n += 1;
        }
        switch (n) {
            0 => {
                weights[i] = 1;
                counted += 1;
            },
            1 => weights[i] = -1,
            else => weights[i] = -2,
        }
    }
    // Merges: count what they reach.
    for (list, 0..) |id, i| {
        if (weights[i] != -2) continue;
        weights[i] = @intCast(try countDistance(a, g, &index, id));
        if (!find_all and halfway(weights[i], nr)) return .{ .list = try a.dupe(Oid, &.{id}), .all = nr, .reaches = @intCast(weights[i]) };
        counted += 1;
    }
    // One parent in the set: one more than it.
    while (counted < nr) {
        for (list, 0..) |id, i| {
            if (weights[i] >= 0) continue;
            var pw: ?i64 = null;
            for ((try g.node(id)).parents) |p| {
                const pi = index.get(p) orelse continue;
                if (weights[pi] >= 0) {
                    pw = weights[pi];
                    break;
                }
            }
            const w = pw orelse continue;
            weights[i] = w + 1;
            counted += 1;
            if (!find_all and halfway(weights[i], nr)) return .{ .list = try a.dupe(Oid, &.{id}), .all = nr, .reaches = @intCast(weights[i]) };
        }
    }
    const Dist = struct { id: Oid, d: i64, w: i64 };
    const ds = try a.alloc(Dist, nr);
    for (list, weights, ds) |id, w, *d| d.* = .{ .id = id, .d = @min(w, @as(i64, @intCast(nr)) - w), .w = w };
    if (!find_all) {
        // The first with the greatest distance.
        var best: usize = 0;
        for (ds, 0..) |d, i| if (d.d > ds[best].d) {
            best = i;
        };
        return .{ .list = try a.dupe(Oid, &.{ds[best].id}), .all = nr, .reaches = @intCast(ds[best].w) };
    }
    std.mem.sort(Dist, ds, {}, struct {
        fn lt(_: void, x: Dist, y: Dist) bool {
            if (x.d != y.d) return x.d > y.d;
            return std.mem.order(u8, x.id.slice(), y.id.slice()) == .lt;
        }
    }.lt);
    const out = try a.alloc(Oid, nr);
    for (ds, out) |d, *o| o.* = d.id;
    return .{ .list = out, .all = nr, .reaches = @intCast(ds[0].w) };
}

fn halfway(w: i64, nr: usize) bool {
    const diff = 2 * w - @as(i64, @intCast(nr));
    return diff >= -1 and diff <= 1;
}

fn countDistance(a: Allocator, g: *revwalk.Graph, index: *const std.AutoHashMapUnmanaged(Oid, usize), from: Oid) !usize {
    var seen: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    var stack: std.ArrayList(Oid) = .empty;
    try stack.append(a, from);
    while (stack.pop()) |c| {
        if (!index.contains(c)) continue;
        if ((try seen.getOrPut(a, c)).found_existing) continue;
        for ((try g.node(c)).parents) |p| try stack.append(a, p);
    }
    return seen.count();
}

/// git's `managed_skipped`: the best commit unless it is skipped, else
/// one picked by `skip_away` from the rest; null when all are skipped.
fn managedSkipped(sorted: []const Oid, skips: []const Oid, bad: Oid) ?Oid {
    var filtered: [256]Oid = undefined;
    var count: usize = 0;
    var skipped_first = false;
    for (sorted) |id| {
        if (contains(skips, id)) {
            skipped_first = true;
            continue;
        }
        if (!skipped_first) return id;
        if (count < filtered.len) filtered[count] = id;
        count += 1;
    }
    if (count == 0) return null;
    const n = @min(count, filtered.len);
    return skipAway(filtered[0..n], count, bad);
}

const prn_modulo: u32 = 32768;

fn skipAway(list: []const Oid, count: usize, bad: Oid) Oid {
    const c: u32 = @truncate(count);
    const prn = (c *% 1103515245 +% 12345) / 65536 % prn_modulo;
    const index = (@as(u64, c) * prn / prn_modulo) * @as(u64, @intCast(sqrti(prn))) / @as(u64, @intCast(sqrti(prn_modulo)));
    var prev: ?Oid = null;
    for (list, 0..) |id, i| {
        if (i == index) {
            if (!id.eql(bad)) return id;
            return prev orelse list[0];
        }
        prev = id;
    }
    return list[0];
}

/// git's float square root (it rounds the same way).
fn sqrti(val: u32) i32 {
    if (val == 0) return 0;
    const v: f32 = @floatFromInt(val);
    var x: f32 = v;
    while (true) {
        const y = (x + v / x) / 2;
        const d = if (y > x) y - x else x - y;
        x = y;
        if (d < 0.5) break;
    }
    return @intFromFloat(x);
}

test "bisect: steps and square roots like git" {
    try std.testing.expectEqual(@as(usize, 2), estimateSteps(7));
    try std.testing.expectEqual(@as(usize, 0), estimateSteps(2));
    try std.testing.expectEqual(@as(usize, 1), estimateSteps(3));
    try std.testing.expectEqual(@as(usize, 3), estimateSteps(12));
    try std.testing.expectEqual(@as(i32, 181), sqrti(32768));
}
