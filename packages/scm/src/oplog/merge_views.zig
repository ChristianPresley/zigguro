//! Three-way merge of views: `left + (right - base)`. Used when load finds
//! several op heads (concurrent writers) and by undo, which applies an
//! operation's inverse onto the current view.
//!
//! - heads: start from base; add what either side added, drop what either
//!   side dropped (a rewrite hides the old commit in that side).
//! - bookmarks, tags, git refs, HEAD, remote bookmarks: per name, the
//!   `Merge` of the targets, simplified; two different moves leave a
//!   conflicted target.
//! - working-copy commits: per workspace; the side that changed wins, and
//!   when both changed, `right`.
//! - lanes: per name; the side that changed wins, and when both changed,
//!   the newer `updated_ms` (ties: `right`).

const std = @import("std");
const id_mod = @import("../store/id.zig");
const enc = @import("../store/encode.zig");
const merge_mod = @import("../merge/merge.zig");
const view_mod = @import("view.zig");
const ObjectId = id_mod.ObjectId;
const View = view_mod.View;
const RefTarget = view_mod.RefTarget;
const ViewBuilder = view_mod.ViewBuilder;
const LaneRecord = view_mod.LaneRecord;
const Allocator = std.mem.Allocator;

const RefMerge = merge_mod.Merge(?ObjectId);
const refEql = merge_mod.defaultEql(?ObjectId);

/// `left + (right - base)` for one ref, simplified (allocated in `arena`).
pub fn mergeRef(arena: Allocator, base: RefTarget, left: RefTarget, right: RefTarget) Allocator.Error!RefTarget {
    if (left.eql(right) or right.eql(base)) return left;
    if (left.eql(base)) return right;
    const flat = try RefMerge.flatten(arena, .{ .values = &.{ left.asMerge(), base.asMerge(), right.asMerge() } });
    const s = try flat.simplify(arena, refEql);
    return .{ .terms = s.values };
}

fn namedMaps(b: *ViewBuilder) [3]*std.StringArrayHashMapUnmanaged(RefTarget) {
    return .{ &b.bookmarks, &b.tags, &b.git_refs };
}

/// Merges `left` and `right` against `base`. The result lives in `arena`.
pub fn mergeViews(gpa: Allocator, arena: Allocator, base: View, left: View, right: View) !View {
    var out = try ViewBuilder.fromView(gpa, left);
    defer out.deinit();
    var b = try ViewBuilder.fromView(gpa, base);
    defer b.deinit();
    var r = try ViewBuilder.fromView(gpa, right);
    defer r.deinit();

    // Heads.
    for (right.heads) |h| {
        if (!b.heads.contains(h)) try out.heads.put(gpa, h, {});
    }
    for (base.heads) |h| {
        if (!r.heads.contains(h)) _ = out.heads.swapRemove(h);
    }

    // Named refs.
    const outs = namedMaps(&out);
    const bases = namedMaps(&b);
    const rights = namedMaps(&r);
    for (outs, bases, rights) |o, bm, rm| {
        var names: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer names.deinit(gpa);
        for (bm.keys()) |k| try names.put(gpa, k, {});
        for (rm.keys()) |k| try names.put(gpa, k, {});
        for (names.keys()) |name| {
            const bt = bm.get(name) orelse RefTarget.absent;
            const rt = rm.get(name) orelse RefTarget.absent;
            const lt = o.get(name) orelse RefTarget.absent;
            const m = try mergeRef(arena, bt, lt, rt);
            try out.setNamed(o, try arena.dupe(u8, name), m);
        }
    }
    out.git_head = try mergeRef(arena, base.git_head, left.git_head, right.git_head);

    // Remote bookmarks.
    {
        var keys: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer keys.deinit(gpa);
        for (b.remote_bookmarks.keys()) |k| try keys.put(gpa, k, {});
        for (r.remote_bookmarks.keys()) |k| try keys.put(gpa, k, {});
        for (keys.keys()) |k| {
            const bv = b.remote_bookmarks.get(k);
            const rv = r.remote_bookmarks.get(k);
            const lv = out.remote_bookmarks.get(k);
            const any = (rv orelse bv).?;
            const absent: view_mod.RemoteBookmark = .{ .remote = any.remote, .name = any.name, .target = .absent, .tracked = false };
            const bb = bv orelse absent;
            const rr = rv orelse absent;
            const ll = lv orelse absent;
            const tracked = if (ll.tracked == bb.tracked) rr.tracked else ll.tracked;
            try out.putRemote(.{
                .remote = try arena.dupe(u8, any.remote),
                .name = try arena.dupe(u8, any.name),
                .target = try mergeRef(arena, bb.target, ll.target, rr.target),
                .tracked = tracked,
            });
        }
    }

    // Working-copy commits.
    {
        var keys: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer keys.deinit(gpa);
        for (b.wc_commits.keys()) |k| try keys.put(gpa, k, {});
        for (r.wc_commits.keys()) |k| try keys.put(gpa, k, {});
        for (keys.keys()) |k| {
            const bv = b.wc_commits.get(k);
            const rv = r.wc_commits.get(k);
            const lv = out.wc_commits.get(k);
            const pick: ?ObjectId = if (view_mod.optEql(rv, bv)) lv else rv;
            const key = try arena.dupe(u8, k);
            if (pick) |c| try out.wc_commits.put(gpa, key, c) else _ = out.wc_commits.orderedRemove(k);
        }
    }

    // Lanes.
    {
        var keys: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer keys.deinit(gpa);
        for (b.lanes.keys()) |k| try keys.put(gpa, k, {});
        for (r.lanes.keys()) |k| try keys.put(gpa, k, {});
        for (keys.keys()) |k| {
            const bv = b.lanes.get(k);
            const rv = r.lanes.get(k);
            const lv = out.lanes.get(k);
            const pick: ?LaneRecord = blk: {
                if (try laneEql(gpa, rv, bv)) break :blk lv;
                if (try laneEql(gpa, lv, bv)) break :blk rv;
                // Both changed.
                if (lv == null) break :blk rv;
                if (rv == null) break :blk lv;
                break :blk if (lv.?.updated_ms > rv.?.updated_ms) lv else rv;
            };
            if (pick) |l| try out.lanes.put(gpa, try arena.dupe(u8, k), l) else _ = out.lanes.orderedRemove(k);
        }
    }
    return out.toView(arena);
}

fn laneEql(gpa: Allocator, a: ?LaneRecord, b: ?LaneRecord) !bool {
    if (a == null or b == null) return a == null and b == null;
    const x = try enc.encodeAlloc(gpa, LaneRecord, a.?);
    defer gpa.free(x);
    const y = try enc.encodeAlloc(gpa, LaneRecord, b.?);
    defer gpa.free(y);
    return std.mem.eql(u8, x, y);
}
