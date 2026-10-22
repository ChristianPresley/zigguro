//! Conflicts between pending changesets (E12.F02.S04.T01): an index of
//! open file changes by path, the pairs that collide, sibling rebase when
//! one of them lands, the warning agents see before they edit a path
//! another session has pending changes on, and an acceptance order.
//!
//! Index: per path, the open hunks and whole-file operations of every
//! open changeset, sorted by (base hash, first line). Hunks are compared
//! only when their bases are the same text: different bases mean one is
//! stale, and the rebase that fixes it updates the index. Recomputing
//! after a change touches only that changeset's paths: O(items on the
//! path) plus the colliding pairs.
//!
//! Kinds: `overlap` (line ranges intersect, or two insertions at one
//! point), `adjacent` (they touch: a soft warning, since a three-way
//! merge treats it as a conflict), `same_change` (identical replacement
//! of the same lines, or two identical creates or deletes),
//! `create_create`, `delete_modify` and `rename_target` (a rename onto a
//! path another change creates or renames onto).
//!
//! The index follows queue events. Rebasing changes other changesets, so
//! it cannot happen inside an event: `applied` events are queued, and
//! the owner calls `rebaseApplied` after the Applier returns.

const std = @import("std");
const model = @import("../model/root.zig");
const closed_file = @import("closed_file.zig");

const Allocator = std.mem.Allocator;
const ChangesetId = model.ChangesetId;
const HunkRef = model.HunkRef;
const BlobHash = model.BlobHash;
const FileChange = model.FileChange;

pub const ConflictKind = enum { overlap, adjacent, same_change, create_create, delete_modify, rename_target };

pub const ConflictPair = struct {
    /// The earlier item of the path's order.
    a: HunkRef,
    b: HunkRef,
    kind: ConflictKind,
};

/// `HunkRef.hunk` of a whole-file operation (create, delete, rename,
/// binary change).
pub const whole_file: u32 = std.math.maxInt(u32);

/// Display names of agent sessions (the E10 session registry).
pub const SessionNames = struct {
    ctx: *anyopaque,
    name: *const fn (ctx: *anyopaque, session: u128) ?[]const u8,
};

pub const Options = struct {
    /// Where `rebaseApplied` finds what an apply wrote.
    history: ?*const model.History = null,
    names: ?SessionNames = null,
};

pub const RebaseReport = struct {
    /// Sibling files rebased onto the new content.
    files: u32 = 0,
    clean: u32 = 0,
    conflicted: u32 = 0,
    /// Already in the new content: applied without a write.
    resolved: u32 = 0,
    stale: u32 = 0,
    /// Files whose rebase failed (logged; the Applier refuses them with
    /// `BaseMoved` until something rebases them).
    failed: u32 = 0,
};

pub const Stats = struct {
    /// Paths whose pairs were computed again.
    path_recomputes: u64 = 0,
};

/// Whole-file kinds first: `wholeKind` and the sort rely on the order.
const ItemKind = enum { create, delete, rename_to, hunk };

const Item = struct {
    kind: ItemKind,
    /// The text the change was made against; null for creates and rename
    /// targets.
    base: ?BlobHash,
    lines: model.LineRange = .{ .start = 0, .count = 0 },
    /// Equal keys: the same replacement.
    key: u64 = 0,
    ref: HunkRef,
    session: ?u128,

    fn order(_: void, x: Item, y: Item) bool {
        const kx = @intFromBool(x.kind == .hunk);
        const ky = @intFromBool(y.kind == .hunk);
        if (kx != ky) return kx < ky;
        if (x.base != null and y.base != null) switch (std.mem.order(u8, &x.base.?, &y.base.?)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        } else if ((x.base == null) != (y.base == null)) return x.base == null;
        if (x.lines.start != y.lines.start) return x.lines.start < y.lines.start;
        if (x.lines.count != y.lines.count) return x.lines.count < y.lines.count;
        return @intFromEnum(x.ref.cs) < @intFromEnum(y.ref.cs);
    }
};

const PathEntry = struct {
    items: std.ArrayList(Item) = .empty,
    refs: std.ArrayList(HunkRef) = .empty,
    pairs: std.ArrayList(ConflictPair) = .empty,

    fn deinit(e: *PathEntry, gpa: Allocator) void {
        e.items.deinit(gpa);
        e.refs.deinit(gpa);
        e.pairs.deinit(gpa);
    }
};

const Applied = struct { cs: ChangesetId, apply: u64 };

pub const ConflictIndex = struct {
    gpa: Allocator,
    q: *model.Queue,
    opts: Options,
    listener: model.events.ListenerId,
    /// Keys are owned.
    paths: std.StringArrayHashMapUnmanaged(PathEntry) = .empty,
    /// The paths each changeset has items on (keys of `paths`).
    cs_paths: std.AutoHashMapUnmanaged(ChangesetId, []const []const u8) = .empty,
    by_cs: std.AutoHashMapUnmanaged(ChangesetId, std.ArrayList(ConflictPair)) = .empty,
    applied: std.ArrayList(Applied) = .empty,
    stats: Stats = .{},

    /// Indexes the queue's open changesets and follows its events.
    pub fn init(gpa: Allocator, q: *model.Queue, o: Options) !*ConflictIndex {
        const ci = try gpa.create(ConflictIndex);
        errdefer gpa.destroy(ci);
        ci.* = .{ .gpa = gpa, .q = q, .opts = o, .listener = undefined };
        errdefer ci.free();
        for (q.changesets.keys()) |id| try ci.refresh(id);
        ci.listener = try q.subscribe(.{ .ctx = ci, .on = onEvent });
        return ci;
    }

    pub fn deinit(ci: *ConflictIndex) void {
        ci.q.unsubscribe(ci.listener);
        ci.free();
        ci.gpa.destroy(ci);
    }

    fn free(ci: *ConflictIndex) void {
        const gpa = ci.gpa;
        for (ci.paths.keys(), ci.paths.values()) |k, *e| {
            e.deinit(gpa);
            gpa.free(k);
        }
        ci.paths.deinit(gpa);
        var it = ci.cs_paths.valueIterator();
        while (it.next()) |v| gpa.free(v.*);
        ci.cs_paths.deinit(gpa);
        var bt = ci.by_cs.valueIterator();
        while (bt.next()) |v| v.deinit(gpa);
        ci.by_cs.deinit(gpa);
        ci.applied.deinit(gpa);
    }

    // ------------------------------------------------------ queries

    /// The pairs `cs` is part of. Valid until the next queue event.
    pub fn conflictsOf(ci: *const ConflictIndex, cs: ChangesetId) []const ConflictPair {
        const l = ci.by_cs.getPtr(cs) orelse return &.{};
        return l.items;
    }

    /// The open hunks and whole-file changes on `path`.
    pub fn pendingOnPath(ci: *const ConflictIndex, path: []const u8) []const HunkRef {
        const e = ci.paths.getPtr(path) orelse return &.{};
        return e.refs.items;
    }

    /// One line for an agent about to read or edit `path`: the other
    /// sessions' pending changesets on it. Null when there are none.
    pub fn warningFor(ci: *const ConflictIndex, path: []const u8, session: ?u128, gpa: Allocator) Allocator.Error!?[]u8 {
        const e = ci.paths.getPtr(path) orelse return null;
        var seen: std.ArrayList(ChangesetId) = .empty;
        defer seen.deinit(gpa);
        for (e.items.items) |it| {
            const s = it.session orelse continue;
            if (session != null and s == session.?) continue;
            if (std.mem.indexOfScalar(ChangesetId, seen.items, it.ref.cs) == null) try seen.append(gpa, it.ref.cs);
        }
        if (seen.items.len == 0) return null;
        std.mem.sort(ChangesetId, seen.items, {}, idLess);
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        const out = &w.writer;
        out.print("Other agents have unreviewed changes to {s}:", .{path}) catch return error.OutOfMemory;
        for (seen.items, 0..) |id, i| {
            const cs = ci.q.get(id) orelse continue;
            const s = cs.prov.origin.agentRef().?.session;
            const name = if (ci.opts.names) |n| n.name(n.ctx, s) else null;
            out.print("{s} {f} \"{s}\" ({s})", .{ if (i == 0) "" else ",", id, cs.prov.label, name orelse "another session" }) catch return error.OutOfMemory;
        }
        out.writeAll(". Your edit may conflict with them.") catch return error.OutOfMemory;
        return try w.toOwnedSlice();
    }

    /// A suggested order to accept `set` in: fewest conflicts with the
    /// rest of the set first, then older first. Allocated with `gpa`.
    pub fn acceptOrder(ci: *const ConflictIndex, set: []const ChangesetId, gpa: Allocator) Allocator.Error![]ChangesetId {
        const Entry = struct { id: ChangesetId, n: u32, created: i64 };
        const es = try gpa.alloc(Entry, set.len);
        defer gpa.free(es);
        for (set, es) |id, *e| {
            var n: u32 = 0;
            for (ci.conflictsOf(id)) |p| {
                const other = if (p.a.cs == id) p.b.cs else p.a.cs;
                if (std.mem.indexOfScalar(ChangesetId, set, other) != null) n += 1;
            }
            e.* = .{ .id = id, .n = n, .created = if (ci.q.get(id)) |cs| cs.created_ms else 0 };
        }
        std.mem.sort(Entry, es, {}, struct {
            fn lt(_: void, x: Entry, y: Entry) bool {
                if (x.n != y.n) return x.n < y.n;
                if (x.created != y.created) return x.created < y.created;
                return @intFromEnum(x.id) < @intFromEnum(y.id);
            }
        }.lt);
        const out = try gpa.alloc(ChangesetId, set.len);
        for (es, out) |e, *o| o.* = e.id;
        return out;
    }

    // ------------------------------------------------------ rebase

    /// Owner thread, outside queue events: rebases the siblings of every
    /// apply seen since the last call.
    pub fn rebaseApplied(ci: *ConflictIndex) !RebaseReport {
        var r: RebaseReport = .{};
        while (ci.applied.items.len > 0) {
            const a = ci.applied.orderedRemove(0);
            const one = try ci.onApplied(a.cs, a.apply);
            inline for (std.meta.fields(RebaseReport)) |f| @field(r, f.name) += @field(one, f.name);
        }
        return r;
    }

    /// Rebases every other open changeset's change on the paths apply
    /// record `apply_id` of `cs` wrote, onto what it wrote. Siblings whose
    /// hunks collide get `ConflictInfo{ .sibling_changeset, other = cs }`;
    /// one that made the same change is applied without a write.
    pub fn onApplied(ci: *ConflictIndex, cs: ChangesetId, apply_id: u64) !RebaseReport {
        var r: RebaseReport = .{};
        const history = ci.opts.history orelse return r;
        const rec = history.get(apply_id) orelse return r;
        var arena_state: std.heap.ArenaAllocator = .init(ci.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // The record may move while siblings are journaled; copy it.
        const files = try arena.alloc(model.ApplyFile, rec.files.len);
        for (rec.files, files) |f, *o| o.* = .{ .path = try arena.dupe(u8, f.path), .pre = f.pre, .post = f.post };
        for (files) |f| {
            const now: ?[]const u8 = if (f.post) |h| try ci.q.blobs.get(arena, h) orelse return error.MissingBlob else null;
            var sibs: std.ArrayList(ChangesetId) = .empty;
            if (ci.paths.getPtr(f.path)) |e| for (e.items.items) |it| {
                if (it.ref.cs == cs or std.mem.indexOfScalar(ChangesetId, sibs.items, it.ref.cs) != null) continue;
                try sibs.append(arena, it.ref.cs);
            };
            for (sibs.items) |sid| try ci.rebaseSibling(sid, f.path, now, cs, &r);
        }
        return r;
    }

    fn rebaseSibling(ci: *ConflictIndex, id: ChangesetId, path: []const u8, now: ?[]const u8, other: ChangesetId, r: *RebaseReport) !void {
        const cs = ci.q.getMut(id) orelse return;
        if (!isOpenCs(cs.state)) return;
        var changed = false;
        for (cs.files) |*fc| {
            if (!isOpenFile(fc.state) or !std.mem.eql(u8, srcPath(fc), path)) continue;
            var arena = cs.arena.promote(ci.gpa);
            defer cs.arena = arena.state;
            const out = closed_file.rebaseFile(ci.gpa, ci.q.blobs, arena.allocator(), fc, now, .{
                .hunk_options = ci.q.hunk_options,
                .conflict_kind = .sibling_changeset,
                .other = other,
            }) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                std.log.scoped(.zg_review).warn("rebasing {f} {s} failed: {t}", .{ id, path, e });
                r.failed += 1;
                continue;
            };
            switch (out) {
                .unchanged => continue,
                .clean => r.clean += 1,
                .conflicted => r.conflicted += 1,
                .dropped_empty => r.resolved += 1,
                .stale => r.stale += 1,
            }
            r.files += 1;
            changed = true;
        }
        if (!changed) return;
        const from = cs.state;
        const to = model.state.derivedState(cs);
        if (to != from) {
            try model.transition(cs, to);
            if (to == .applied) cs.decided_ms = nowMs(ci.q.io);
        }
        ci.q.persist(id);
        ci.q.emit(.{ .updated = id });
        if (to != from) ci.q.emit(.{ .state = .{ .cs = id, .from = from, .to = to } });
    }

    // ------------------------------------------------------ index

    fn onEvent(ctx: *anyopaque, ev: *const model.Event) void {
        const ci: *ConflictIndex = @ptrCast(@alignCast(ctx));
        const id = switch (ev.*) {
            .submitted, .updated, .removed => |id| id,
            .state => |s| s.cs,
            .applied => |a| {
                ci.applied.append(ci.gpa, .{ .cs = a.cs, .apply = a.apply }) catch
                    std.log.scoped(.zg_review).warn("conflict index: out of memory; {f} siblings not rebased", .{a.cs});
                return;
            },
        };
        ci.refresh(id) catch std.log.scoped(.zg_review).warn("conflict index: out of memory while indexing {f}", .{id});
    }

    /// Indexes `id` again (gone or closed: removes it) and recomputes the
    /// paths it was or is on.
    fn refresh(ci: *ConflictIndex, id: ChangesetId) Allocator.Error!void {
        const gpa = ci.gpa;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var new: std.ArrayList(PathItem) = .empty;
        if (ci.q.get(id)) |cs| if (isOpenCs(cs.state)) try itemsOf(arena, cs, &new);
        if (new.items.len == 0 and !ci.cs_paths.contains(id)) return;

        // The affected paths: old ones, then new ones.
        var affected: std.ArrayList([]const u8) = .empty;
        if (ci.cs_paths.get(id)) |old| try affected.appendSlice(arena, old);
        for (new.items) |pi| if (!containsStr(affected.items, pi.path)) try affected.append(arena, pi.path);

        // Drop old items.
        for (affected.items) |p| if (ci.paths.getPtr(p)) |e| {
            var k: usize = 0;
            for (e.items.items) |it| if (it.ref.cs != id) {
                e.items.items[k] = it;
                k += 1;
            };
            e.items.shrinkRetainingCapacity(k);
        };
        // Add new ones, with owned path keys.
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(gpa);
        for (new.items) |pi| {
            const g = try ci.paths.getOrPut(gpa, pi.path);
            if (!g.found_existing) {
                g.key_ptr.* = gpa.dupe(u8, pi.path) catch |e| {
                    _ = ci.paths.pop();
                    return e;
                };
                g.value_ptr.* = .{};
            }
            try g.value_ptr.items.append(gpa, pi.item);
            if (!containsStr(keys.items, g.key_ptr.*)) try keys.append(gpa, g.key_ptr.*);
        }
        if (ci.cs_paths.fetchRemove(id)) |old| gpa.free(old.value);
        if (keys.items.len > 0) {
            const owned = try gpa.dupe([]const u8, keys.items);
            ci.cs_paths.put(gpa, id, owned) catch |e| {
                gpa.free(owned);
                return e;
            };
        }

        // Recompute the paths; collect the changesets whose pairs moved.
        var touched: std.ArrayList(ChangesetId) = .empty;
        try touched.append(arena, id);
        for (affected.items) |p| {
            const e = ci.paths.getPtr(p) orelse continue;
            for (e.pairs.items) |pr| try addId(arena, &touched, pr);
            try ci.recompute(e);
            for (e.pairs.items) |pr| try addId(arena, &touched, pr);
        }
        for (touched.items) |c| try ci.rebuildPairs(c);
        // Drop paths nothing is pending on (no changeset lists them).
        for (affected.items) |p| {
            const e = ci.paths.getPtr(p) orelse continue;
            if (e.items.items.len > 0) continue;
            const kv = ci.paths.fetchSwapRemove(p).?;
            var v = kv.value;
            v.deinit(gpa);
            gpa.free(kv.key);
        }
    }

    fn recompute(ci: *ConflictIndex, e: *PathEntry) Allocator.Error!void {
        const gpa = ci.gpa;
        ci.stats.path_recomputes += 1;
        const items = e.items.items;
        std.mem.sort(Item, items, {}, Item.order);
        e.refs.clearRetainingCapacity();
        e.pairs.clearRetainingCapacity();
        for (items) |it| try e.refs.append(gpa, it.ref);
        // Whole-file items come first and are few: compare with all.
        var n_whole: usize = 0;
        while (n_whole < items.len and items[n_whole].kind != .hunk) n_whole += 1;
        for (items[0..n_whole], 0..) |a, i| for (items[i + 1 ..]) |b| {
            if (a.ref.cs == b.ref.cs) continue;
            if (wholeKind(a, b)) |k| try e.pairs.append(gpa, .{ .a = a.ref, .b = b.ref, .kind = k });
        };
        // Hunks: sorted by base and first line, so the scan stops at the
        // first one past the end.
        const hunks = items[n_whole..];
        for (hunks, 0..) |a, i| for (hunks[i + 1 ..]) |b| {
            if (!std.mem.eql(u8, &a.base.?, &b.base.?)) break;
            if (b.lines.start > a.lines.end()) break;
            if (a.ref.cs == b.ref.cs) continue;
            if (hunkKind(a, b)) |k| try e.pairs.append(gpa, .{ .a = a.ref, .b = b.ref, .kind = k });
        };
    }

    fn rebuildPairs(ci: *ConflictIndex, id: ChangesetId) Allocator.Error!void {
        const gpa = ci.gpa;
        const g = try ci.by_cs.getOrPut(gpa, id);
        if (!g.found_existing) g.value_ptr.* = .empty;
        const l = g.value_ptr;
        l.clearRetainingCapacity();
        if (ci.cs_paths.get(id)) |ps| for (ps) |p| {
            const e = ci.paths.getPtr(p) orelse continue;
            for (e.pairs.items) |pr| if (pr.a.cs == id or pr.b.cs == id) try l.append(gpa, pr);
        };
        if (l.items.len == 0) {
            l.deinit(gpa);
            _ = ci.by_cs.remove(id);
        }
    }
};

const PathItem = struct { path: []const u8, item: Item };

/// The index items of an open changeset.
fn itemsOf(arena: Allocator, cs: *const model.Changeset, out: *std.ArrayList(PathItem)) Allocator.Error!void {
    const session: ?u128 = if (cs.prov.origin.agentRef()) |r| r.session else null;
    for (cs.files, 0..) |*fc, fi| {
        if (!isOpenFile(fc.state)) continue;
        const whole: HunkRef = .{ .cs = cs.id, .file = @intCast(fi), .hunk = whole_file };
        switch (fc.op) {
            .create => {
                try out.append(arena, .{ .path = fc.path, .item = .{ .kind = .create, .base = null, .key = contentKey(fc), .ref = whole, .session = session } });
                continue;
            },
            .delete => {
                try out.append(arena, .{ .path = fc.path, .item = .{ .kind = .delete, .base = if (fc.base) |b| b.hash else null, .ref = whole, .session = session } });
                continue;
            },
            .rename => try out.append(arena, .{ .path = fc.path, .item = .{ .kind = .rename_to, .base = null, .ref = whole, .session = session } }),
            .modify, .set_executable => {},
        }
        switch (fc.content) {
            .text => |t| {
                const base = (t.base orelse continue).hash;
                for (fc.hunks) |h| {
                    if (h.decision != .undecided) continue;
                    try out.append(arena, .{ .path = srcPath(fc), .item = .{
                        .kind = .hunk,
                        .base = base,
                        .lines = h.base_lines,
                        .key = h.key,
                        .ref = .{ .cs = cs.id, .file = @intCast(fi), .hunk = h.id },
                        .session = session,
                    } });
                }
            },
            .binary => |b| try out.append(arena, .{ .path = srcPath(fc), .item = .{
                .kind = .hunk,
                .base = b.base orelse continue,
                .lines = .{ .start = 0, .count = std.math.maxInt(u32) / 2 },
                .key = std.mem.readInt(u64, b.new[0..8], .little),
                .ref = whole,
                .session = session,
            } }),
            .none => {},
        }
    }
}

/// What a create would write, for `same_change`.
fn contentKey(fc: *const FileChange) u64 {
    return switch (fc.content) {
        .text => |t| blk: {
            var h: std.hash.XxHash3 = .init(0);
            for (t.edits.replaces) |r| h.update(r.text);
            break :blk h.final();
        },
        .binary => |b| std.mem.readInt(u64, b.new[0..8], .little),
        .none => 0,
    };
}

fn wholeKind(a: Item, b: Item) ?ConflictKind {
    const x, const y = if (@intFromEnum(a.kind) <= @intFromEnum(b.kind)) .{ a, b } else .{ b, a };
    return switch (x.kind) {
        .create => switch (y.kind) {
            .create => if (x.key == y.key) .same_change else .create_create,
            .rename_to => .rename_target,
            else => null,
        },
        .delete => switch (y.kind) {
            .delete => if (sameBase(x, y)) .same_change else null,
            .hunk => if (sameBase(x, y)) .delete_modify else null,
            else => null,
        },
        .rename_to => if (y.kind == .rename_to) .rename_target else null,
        .hunk => null,
    };
}

fn sameBase(a: Item, b: Item) bool {
    const x = a.base orelse return true;
    const y = b.base orelse return true;
    return std.mem.eql(u8, &x, &y);
}

/// `a` starts at or before `b` and both have the same base.
fn hunkKind(a: Item, b: Item) ?ConflictKind {
    const al = a.lines;
    const bl = b.lines;
    if (al.start == bl.start and al.count == bl.count and a.key == b.key) return .same_change;
    if (bl.start < al.end()) return .overlap;
    if (bl.start == al.start) return .overlap; // insertions at one point
    if (bl.start == al.end()) return .adjacent;
    return null;
}

fn addId(arena: Allocator, l: *std.ArrayList(ChangesetId), p: ConflictPair) Allocator.Error!void {
    for ([_]ChangesetId{ p.a.cs, p.b.cs }) |id|
        if (std.mem.indexOfScalar(ChangesetId, l.items, id) == null) try l.append(arena, id);
}

fn containsStr(l: []const []const u8, s: []const u8) bool {
    for (l) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn idLess(_: void, a: ChangesetId, b: ChangesetId) bool {
    return @intFromEnum(a) < @intFromEnum(b);
}

fn isOpenCs(s: model.State) bool {
    return s == .pending or s == .partially_applied;
}

fn isOpenFile(s: model.FileState) bool {
    return s == .pending or s == .partially_applied;
}

fn nowMs(io: std.Io) i64 {
    const now = std.Io.Clock.real.now(io);
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms));
}

fn srcPath(fc: *const FileChange) []const u8 {
    return switch (fc.op) {
        .rename => |r| r.from,
        else => fc.path,
    };
}
