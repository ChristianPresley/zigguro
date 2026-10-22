//! Preview (detached) operations: a transaction written to the store as an
//! operation that is not an op head. Detached operations hold AI
//! proposals (F06), drag-to-rebase dry runs (F11), lane-landing previews
//! and E12 review previews; approving one adopts it (`adopt.zig`).
//!
//! Each detached operation has an empty marker file,
//! `detached/<op-hex>`, next to `op_heads/`. Markers survive restarts, are
//! GC roots (`Repo.gcRoots`) until discarded or expired, and are how
//! read models list pending proposals. Everything else (base operation,
//! purpose, creation time) is read from the operation itself.
//!
//! `viewDiff` compares two views, for previews and the op log's detail
//! pane.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const enc = @import("../store/encode.zig");
const store_mod = @import("../store/store.zig");
const op_mod = @import("operation.zig");
const view_mod = @import("view.zig");
const repo_mod = @import("repo.zig");
const tx_mod = @import("transaction.zig");
const ObjectId = id_mod.ObjectId;
const Store = store_mod.Store;
const Operation = op_mod.Operation;
const View = view_mod.View;
const NamedRef = view_mod.NamedRef;
const RefTarget = view_mod.RefTarget;
const LaneRecord = view_mod.LaneRecord;
const Repo = repo_mod.Repo;
const Transaction = tx_mod.Transaction;
const Allocator = std.mem.Allocator;

/// The operation tag recording a detached operation's purpose.
pub const purpose_tag = "preview";

/// How long a detached operation stays a GC root (`scm.preview.ttl`).
pub const default_ttl_ms: i64 = 7 * std.time.ms_per_day;

pub const DetachedOp = struct {
    op: ObjectId,
    /// The operation the preview was made on (its first parent).
    base_op: ObjectId,
    created_ms: i64,
    purpose: Purpose,

    pub const Purpose = enum { proposal, dry_run, landing, checkpoint };
};

/// Writes `tx` as a detached operation (store only; `op_heads/` is not
/// touched) and records its marker. The transaction is finished either
/// way.
pub fn commitDetached(tx: *Transaction, purpose: DetachedOp.Purpose) !DetachedOp {
    defer tx.discard();
    const r = tx.repo;
    tx.meta = try tx.meta.withTag(tx.arena(), purpose_tag, @tagName(purpose));
    const id = try tx.writeOp();
    try addMarker(r.io, r.repo_dir, id);
    return .{ .op = id, .base_op = tx.parents.items[0], .created_ms = tx.meta.end_ms, .purpose = purpose };
}

/// The detached operation `op`, read back from the store. Fails with
/// `NotDetached` when it has no marker (discarded, expired or adopted).
pub fn get(repo: *const Repo, op: ObjectId) !DetachedOp {
    if (!try hasMarker(repo.io, repo.repo_dir, op)) return error.NotDetached;
    return describe(repo.store, repo.gpa, op);
}

/// Every detached operation, oldest first.
pub fn list(repo: *const Repo, gpa: Allocator) ![]DetachedOp {
    const ids = try repo_mod.listMarkers(gpa, repo.io, repo.repo_dir);
    defer gpa.free(ids);
    var out: std.ArrayList(DetachedOp) = .empty;
    errdefer out.deinit(gpa);
    for (ids) |id| {
        // A marker whose operation is gone (GC after a crash between
        // writing and marking cannot happen, but a hand-deleted store can)
        // is skipped.
        const d = describe(repo.store, gpa, id) catch |e| switch (e) {
            error.NotFound, error.WrongKind, error.CorruptObject, error.NotDetached => continue,
            else => return e,
        };
        try out.append(gpa, d);
    }
    std.mem.sort(DetachedOp, out.items, {}, struct {
        fn lt(_: void, a: DetachedOp, b: DetachedOp) bool {
            return if (a.created_ms != b.created_ms) a.created_ms < b.created_ms else ObjectId.lessThan({}, a.op, b.op);
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

/// A read-only repo at detached operation `op` (like `--at-op`).
pub fn loadDetached(gpa: Allocator, io: std.Io, repo_dir: std.Io.Dir, store: *Store, opts: repo_mod.Options, op: ObjectId) !*Repo {
    if (!try hasMarker(io, repo_dir, op)) return error.NotDetached;
    return Repo.load(gpa, io, repo_dir, store, opts, .{ .op = op });
}

/// Drops a detached operation: its marker goes, and GC collects what only
/// it referenced once the store's grace period has passed.
pub fn discard(repo: *const Repo, op: ObjectId) void {
    removeMarker(repo.io, repo.repo_dir, op);
}

/// Discards detached operations created more than `ttl_ms` before
/// `now_ms`. Returns how many went.
pub fn expire(repo: *const Repo, now_ms: i64, ttl_ms: i64) !usize {
    const gpa = repo.gpa;
    const all = try list(repo, gpa);
    defer gpa.free(all);
    var n: usize = 0;
    for (all) |d| {
        if (now_ms - d.created_ms < ttl_ms) continue;
        discard(repo, d.op);
        n += 1;
    }
    return n;
}

/// Keeps a detached operation alive in this process even without its
/// marker (while a preview is on screen).
pub const PinHandle = struct {
    store: *Store,
    op: ObjectId,

    pub fn release(h: PinHandle) void {
        h.store.unpin(h.op);
    }
};

pub fn pinDetached(store: *Store, d: DetachedOp) Allocator.Error!PinHandle {
    try store.pin(d.op);
    return .{ .store = store, .op = d.op };
}

fn describe(store: *Store, gpa: Allocator, op: ObjectId) !DetachedOp {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const o = try op_mod.read(Operation, store, arena_state.allocator(), op);
    if (o.parents.len == 0) return error.NotDetached;
    const purpose = std.meta.stringToEnum(DetachedOp.Purpose, o.meta.tag(purpose_tag) orelse "") orelse return error.NotDetached;
    return .{ .op = op, .base_op = o.parents[0], .created_ms = o.meta.end_ms, .purpose = purpose };
}

fn addMarker(io: std.Io, repo_dir: std.Io.Dir, id: ObjectId) !void {
    var dir = try repo_dir.createDirPathOpen(io, repo_mod.detached_dir_name, .{});
    defer dir.close(io);
    var buf: [64]u8 = undefined;
    const f = dir.createFile(io, id.hex(&buf), .{}) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        else => return e,
    };
    f.close(io);
}

fn hasMarker(io: std.Io, repo_dir: std.Io.Dir, id: ObjectId) !bool {
    var buf: [64]u8 = undefined;
    var path: [repo_mod.detached_dir_name.len + 65]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "{s}/{s}", .{ repo_mod.detached_dir_name, id.hex(&buf) }) catch unreachable;
    _ = repo_dir.statFile(io, p, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    return true;
}

pub fn removeMarker(io: std.Io, repo_dir: std.Io.Dir, id: ObjectId) void {
    var buf: [64]u8 = undefined;
    var dir = repo_dir.openDir(io, repo_mod.detached_dir_name, .{}) catch return;
    defer dir.close(io);
    dir.deleteFile(io, id.hex(&buf)) catch {};
}

pub const RefChange = struct {
    name: []const u8,
    old: RefTarget,
    new: RefTarget,
};

pub const RemoteRefChange = struct {
    remote: []const u8,
    name: []const u8,
    old: RefTarget,
    new: RefTarget,
    old_tracked: bool,
    new_tracked: bool,
};

pub const WcChange = struct {
    workspace: []const u8,
    old: ?ObjectId,
    new: ?ObjectId,
};

pub const LaneChange = struct {
    name: []const u8,
    old: ?LaneRecord,
    new: ?LaneRecord,
};

/// What changed from view `a` to view `b`. Lists are sorted like the
/// views. Names and targets point into the two views, which must outlive
/// the diff.
pub const ViewDiff = struct {
    arena_state: std.heap.ArenaAllocator,
    heads_added: []const ObjectId = &.{},
    heads_removed: []const ObjectId = &.{},
    bookmarks: []const RefChange = &.{},
    tags: []const RefChange = &.{},
    git_refs: []const RefChange = &.{},
    remote_bookmarks: []const RemoteRefChange = &.{},
    git_head: ?RefChange = null,
    wc_commits: []const WcChange = &.{},
    lanes: []const LaneChange = &.{},

    pub fn deinit(d: *ViewDiff) void {
        d.arena_state.deinit();
    }

    pub fn isEmpty(d: *const ViewDiff) bool {
        return d.heads_added.len == 0 and d.heads_removed.len == 0 and d.bookmarks.len == 0 and
            d.tags.len == 0 and d.git_refs.len == 0 and d.remote_bookmarks.len == 0 and
            d.git_head == null and d.wc_commits.len == 0 and d.lanes.len == 0;
    }

    /// One line per change, IDs shortened to 12 hex digits:
    /// `+head 1a2b…`, `bookmark main: 1a2b… -> 3c4d…`, and so on.
    pub fn format(d: *const ViewDiff, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (d.heads_added) |h| try w.print("+head {f}\n", .{short(h)});
        for (d.heads_removed) |h| try w.print("-head {f}\n", .{short(h)});
        const groups = [_]struct { []const u8, []const RefChange }{
            .{ "bookmark", d.bookmarks }, .{ "tag", d.tags }, .{ "git_ref", d.git_refs },
        };
        for (groups) |g| for (g[1]) |c| {
            try w.print("{s} {s}: ", .{ g[0], c.name });
            try writeChange(w, c.old, c.new);
        };
        for (d.remote_bookmarks) |c| {
            try w.print("remote_bookmark {s}@{s}: ", .{ c.name, c.remote });
            try writeTarget(w, c.old);
            if (c.old_tracked) try w.writeAll(" (tracked)");
            try w.writeAll(" -> ");
            try writeTarget(w, c.new);
            if (c.new_tracked) try w.writeAll(" (tracked)");
            try w.writeByte('\n');
        }
        if (d.git_head) |c| {
            try w.writeAll("git_head: ");
            try writeChange(w, c.old, c.new);
        }
        for (d.wc_commits) |c| {
            try w.print("wc {s}: ", .{c.workspace});
            try writeOpt(w, c.old);
            try w.writeAll(" -> ");
            try writeOpt(w, c.new);
            try w.writeByte('\n');
        }
        for (d.lanes) |c| {
            const what = if (c.old == null) "added" else if (c.new == null) "removed" else "changed";
            try w.print("lane {s}: {s}\n", .{ c.name, what });
        }
    }
};

const Short = struct {
    id: ObjectId,
    pub fn format(s: Short, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [64]u8 = undefined;
        try w.writeAll(s.id.hex(&buf)[0..12]);
    }
};

fn short(id: ObjectId) Short {
    return .{ .id = id };
}

fn writeOpt(w: *std.Io.Writer, id: ?ObjectId) !void {
    if (id) |x| try w.print("{f}", .{short(x)}) else try w.writeAll("(none)");
}

fn writeTarget(w: *std.Io.Writer, t: RefTarget) !void {
    if (t.terms.len == 1) return writeOpt(w, t.terms[0]);
    try w.writeByte('{');
    for (t.terms, 0..) |x, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeByte(if (i % 2 == 0) '+' else '-');
        try writeOpt(w, x);
    }
    try w.writeByte('}');
}

fn writeChange(w: *std.Io.Writer, old: RefTarget, new: RefTarget) !void {
    try writeTarget(w, old);
    try w.writeAll(" -> ");
    try writeTarget(w, new);
    try w.writeByte('\n');
}

/// Compares `a` with `b` by merge-joining their sorted lists.
pub fn viewDiff(gpa: Allocator, a: *const View, b: *const View) !ViewDiff {
    var d: ViewDiff = .{ .arena_state = .init(gpa) };
    errdefer d.deinit();
    const arena = d.arena_state.allocator();

    {
        var added: std.ArrayList(ObjectId) = .empty;
        var removed: std.ArrayList(ObjectId) = .empty;
        var i: usize = 0;
        var j: usize = 0;
        while (i < a.heads.len or j < b.heads.len) {
            const o: std.math.Order = if (i == a.heads.len) .gt else if (j == b.heads.len) .lt else a.heads[i].order(b.heads[j]);
            switch (o) {
                .lt => {
                    try removed.append(arena, a.heads[i]);
                    i += 1;
                },
                .gt => {
                    try added.append(arena, b.heads[j]);
                    j += 1;
                },
                .eq => {
                    i += 1;
                    j += 1;
                },
            }
        }
        d.heads_added = added.items;
        d.heads_removed = removed.items;
    }

    d.bookmarks = try diffNamed(arena, a.bookmarks, b.bookmarks);
    d.tags = try diffNamed(arena, a.tags, b.tags);
    d.git_refs = try diffNamed(arena, a.git_refs, b.git_refs);
    if (!a.git_head.eql(b.git_head)) d.git_head = .{ .name = "HEAD", .old = a.git_head, .new = b.git_head };

    {
        var out: std.ArrayList(RemoteRefChange) = .empty;
        const x = a.remote_bookmarks;
        const y = b.remote_bookmarks;
        var i: usize = 0;
        var j: usize = 0;
        while (i < x.len or j < y.len) {
            const o: std.math.Order = if (i == x.len) .gt else if (j == y.len) .lt else switch (std.mem.order(u8, x[i].remote, y[j].remote)) {
                .eq => std.mem.order(u8, x[i].name, y[j].name),
                else => |r| r,
            };
            switch (o) {
                .lt => {
                    try out.append(arena, .{ .remote = x[i].remote, .name = x[i].name, .old = x[i].target, .new = .absent, .old_tracked = x[i].tracked, .new_tracked = false });
                    i += 1;
                },
                .gt => {
                    try out.append(arena, .{ .remote = y[j].remote, .name = y[j].name, .old = .absent, .new = y[j].target, .old_tracked = false, .new_tracked = y[j].tracked });
                    j += 1;
                },
                .eq => {
                    if (!x[i].target.eql(y[j].target) or x[i].tracked != y[j].tracked)
                        try out.append(arena, .{ .remote = x[i].remote, .name = x[i].name, .old = x[i].target, .new = y[j].target, .old_tracked = x[i].tracked, .new_tracked = y[j].tracked });
                    i += 1;
                    j += 1;
                },
            }
        }
        d.remote_bookmarks = out.items;
    }

    {
        var out: std.ArrayList(WcChange) = .empty;
        const x = a.wc_commits;
        const y = b.wc_commits;
        var i: usize = 0;
        var j: usize = 0;
        while (i < x.len or j < y.len) {
            const o: std.math.Order = if (i == x.len) .gt else if (j == y.len) .lt else std.mem.order(u8, x[i].workspace, y[j].workspace);
            switch (o) {
                .lt => {
                    try out.append(arena, .{ .workspace = x[i].workspace, .old = x[i].commit, .new = null });
                    i += 1;
                },
                .gt => {
                    try out.append(arena, .{ .workspace = y[j].workspace, .old = null, .new = y[j].commit });
                    j += 1;
                },
                .eq => {
                    if (!x[i].commit.eql(y[j].commit)) try out.append(arena, .{ .workspace = x[i].workspace, .old = x[i].commit, .new = y[j].commit });
                    i += 1;
                    j += 1;
                },
            }
        }
        d.wc_commits = out.items;
    }

    {
        var out: std.ArrayList(LaneChange) = .empty;
        const x = a.lanes;
        const y = b.lanes;
        var i: usize = 0;
        var j: usize = 0;
        while (i < x.len or j < y.len) {
            const o: std.math.Order = if (i == x.len) .gt else if (j == y.len) .lt else std.mem.order(u8, x[i].name, y[j].name);
            switch (o) {
                .lt => {
                    try out.append(arena, .{ .name = x[i].name, .old = x[i], .new = null });
                    i += 1;
                },
                .gt => {
                    try out.append(arena, .{ .name = y[j].name, .old = null, .new = y[j] });
                    j += 1;
                },
                .eq => {
                    const ex = try enc.encodeAlloc(arena, LaneRecord, x[i]);
                    const ey = try enc.encodeAlloc(arena, LaneRecord, y[j]);
                    if (!std.mem.eql(u8, ex, ey)) try out.append(arena, .{ .name = x[i].name, .old = x[i], .new = y[j] });
                    i += 1;
                    j += 1;
                },
            }
        }
        d.lanes = out.items;
    }
    return d;
}

fn diffNamed(arena: Allocator, x: []const NamedRef, y: []const NamedRef) ![]const RefChange {
    var out: std.ArrayList(RefChange) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < x.len or j < y.len) {
        const o: std.math.Order = if (i == x.len) .gt else if (j == y.len) .lt else std.mem.order(u8, x[i].name, y[j].name);
        switch (o) {
            .lt => {
                try out.append(arena, .{ .name = x[i].name, .old = x[i].target, .new = .absent });
                i += 1;
            },
            .gt => {
                try out.append(arena, .{ .name = y[j].name, .old = .absent, .new = y[j].target });
                j += 1;
            },
            .eq => {
                if (!x[i].target.eql(y[j].target)) try out.append(arena, .{ .name = x[i].name, .old = x[i].target, .new = y[j].target });
                i += 1;
                j += 1;
            },
        }
    }
    return out.items;
}
