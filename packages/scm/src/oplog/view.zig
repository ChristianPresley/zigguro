//! A view: the repository's state as of one operation. It records the
//! visible heads, bookmarks, remote bookmarks, tags, git refs and HEAD,
//! each workspace's working-copy commit, and agent lanes. Views are
//! immutable `view` objects in the store; `ViewBuilder` is the editable
//! form used by transactions and the three-way view merge.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const merge_mod = @import("../merge/merge.zig");
const ObjectId = id_mod.ObjectId;
const Kind = id_mod.Kind;
const Extra = object.Extra;
const ValidateError = object.ValidateError;
const Allocator = std.mem.Allocator;

/// Where a ref points: absent, one commit, or a conflict between several
/// (a `Merge(?ObjectId)`, adds and removes alternating).
pub const RefTarget = struct {
    terms: []const ?ObjectId,

    const absent_terms = [_]?ObjectId{null};

    pub const absent: RefTarget = .{ .terms = &absent_terms };

    /// A normal target over an ID the caller keeps alive.
    pub fn normal(id: *const ?ObjectId) RefTarget {
        return .{ .terms = id[0..1] };
    }

    pub fn asMerge(t: RefTarget) merge_mod.Merge(?ObjectId) {
        return .{ .values = t.terms };
    }

    pub fn isAbsent(t: RefTarget) bool {
        return t.terms.len == 1 and t.terms[0] == null;
    }

    pub fn isConflicted(t: RefTarget) bool {
        return t.terms.len > 1;
    }

    /// The commit of a normal target.
    pub fn asNormal(t: RefTarget) ?ObjectId {
        return if (t.terms.len == 1) t.terms[0] else null;
    }

    pub fn eql(a: RefTarget, b: RefTarget) bool {
        if (a.terms.len != b.terms.len) return false;
        for (a.terms, b.terms) |x, y| if (!optEql(x, y)) return false;
        return true;
    }

    pub fn validate(t: RefTarget) ValidateError!void {
        if (t.terms.len % 2 != 1) return error.InvalidView;
    }
};

pub fn optEql(a: ?ObjectId, b: ?ObjectId) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

/// A named ref (bookmark, tag or git ref).
pub const NamedRef = struct {
    name: []const u8,
    target: RefTarget,
};

pub const RemoteBookmark = struct {
    remote: []const u8,
    name: []const u8,
    target: RefTarget,
    /// Tracked by the local bookmark of the same name.
    tracked: bool,
};

pub const WcCommit = struct {
    workspace: []const u8,
    commit: ObjectId,
};

/// An agent lane's record (F03.S03 fills in the meaning of the fields).
pub const LaneRecord = struct {
    name: []const u8,
    workspace: []const u8,
    /// Who owns it: a user, or an agent session ID.
    owner: []const u8,
    /// The commit the lane started from.
    base: ?ObjectId,
    status: []const u8,
    policy: []const u8,
    /// Milliseconds since the epoch of the last change; the newer record
    /// wins when concurrent operations both changed a lane.
    updated_ms: i64,
    extra: []const Extra,
};

pub const View = struct {
    /// Visible heads, sorted, unique.
    heads: []const ObjectId,
    /// Sorted by name; none absent.
    bookmarks: []const NamedRef,
    /// Sorted by (remote, name).
    remote_bookmarks: []const RemoteBookmark,
    tags: []const NamedRef,
    git_refs: []const NamedRef,
    git_head: RefTarget,
    /// Sorted by workspace.
    wc_commits: []const WcCommit,
    /// Sorted by name.
    lanes: []const LaneRecord,
    extra: []const Extra,

    pub const kind: Kind = .view;

    pub const empty: View = .{
        .heads = &.{},
        .bookmarks = &.{},
        .remote_bookmarks = &.{},
        .tags = &.{},
        .git_refs = &.{},
        .git_head = .absent,
        .wc_commits = &.{},
        .lanes = &.{},
        .extra = &.{},
    };

    pub fn validate(v: View) ValidateError!void {
        for (1..@max(1, v.heads.len)) |i| if (!ObjectId.lessThan({}, v.heads[i - 1], v.heads[i])) return error.InvalidView;
        try validateNamed(v.bookmarks);
        try validateNamed(v.tags);
        try validateNamed(v.git_refs);
        for (v.remote_bookmarks, 0..) |r, i| {
            try r.target.validate();
            if (i > 0) {
                const p = v.remote_bookmarks[i - 1];
                const o = std.mem.order(u8, p.remote, r.remote);
                if (o == .gt or (o == .eq and std.mem.order(u8, p.name, r.name) != .lt)) return error.InvalidView;
            }
        }
        try v.git_head.validate();
        for (1..@max(1, v.wc_commits.len)) |i| {
            if (std.mem.order(u8, v.wc_commits[i - 1].workspace, v.wc_commits[i].workspace) != .lt) return error.InvalidView;
        }
        for (v.lanes, 0..) |l, i| {
            try object.validateExtra(l.extra);
            if (i > 0 and std.mem.order(u8, v.lanes[i - 1].name, l.name) != .lt) return error.InvalidView;
        }
        try object.validateExtra(v.extra);
    }

    pub fn bookmark(v: View, name: []const u8) RefTarget {
        return findNamed(v.bookmarks, name);
    }

    pub fn tag(v: View, name: []const u8) RefTarget {
        return findNamed(v.tags, name);
    }

    pub fn wcCommit(v: View, workspace: []const u8) ?ObjectId {
        for (v.wc_commits) |w| if (std.mem.eql(u8, w.workspace, workspace)) return w.commit;
        return null;
    }

    pub fn lane(v: View, name: []const u8) ?LaneRecord {
        for (v.lanes) |l| if (std.mem.eql(u8, l.name, name)) return l;
        return null;
    }

    pub fn hasHead(v: View, id: ObjectId) bool {
        return std.sort.binarySearch(ObjectId, v.heads, id, orderId) != null;
    }
};

fn orderId(key: ObjectId, x: ObjectId) std.math.Order {
    return key.order(x);
}

fn validateNamed(refs: []const NamedRef) ValidateError!void {
    for (refs, 0..) |r, i| {
        try r.target.validate();
        if (r.target.isAbsent()) return error.InvalidView;
        if (i > 0 and std.mem.order(u8, refs[i - 1].name, r.name) != .lt) return error.InvalidView;
    }
}

fn findNamed(refs: []const NamedRef, name: []const u8) RefTarget {
    for (refs) |r| if (std.mem.eql(u8, r.name, name)) return r.target;
    return .absent;
}

/// The editable form of a view. Strings and slices put in it must outlive
/// it (transactions keep them in their arena).
pub const ViewBuilder = struct {
    gpa: Allocator,
    heads: std.AutoArrayHashMapUnmanaged(ObjectId, void) = .empty,
    bookmarks: std.StringArrayHashMapUnmanaged(RefTarget) = .empty,
    tags: std.StringArrayHashMapUnmanaged(RefTarget) = .empty,
    git_refs: std.StringArrayHashMapUnmanaged(RefTarget) = .empty,
    /// Keyed by "remote\x00name".
    remote_bookmarks: std.StringArrayHashMapUnmanaged(RemoteBookmark) = .empty,
    git_head: RefTarget = .absent,
    wc_commits: std.StringArrayHashMapUnmanaged(ObjectId) = .empty,
    lanes: std.StringArrayHashMapUnmanaged(LaneRecord) = .empty,
    extra: []const Extra = &.{},
    /// Owns the remote-bookmark keys.
    keys: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator) ViewBuilder {
        return .{ .gpa = gpa, .keys = .init(gpa) };
    }

    pub fn deinit(b: *ViewBuilder) void {
        const gpa = b.gpa;
        b.heads.deinit(gpa);
        b.bookmarks.deinit(gpa);
        b.tags.deinit(gpa);
        b.git_refs.deinit(gpa);
        b.remote_bookmarks.deinit(gpa);
        b.wc_commits.deinit(gpa);
        b.lanes.deinit(gpa);
        b.keys.deinit();
    }

    pub fn fromView(gpa: Allocator, v: View) Allocator.Error!ViewBuilder {
        var b: ViewBuilder = .init(gpa);
        errdefer b.deinit();
        for (v.heads) |h| try b.heads.put(gpa, h, {});
        for (v.bookmarks) |r| try b.bookmarks.put(gpa, r.name, r.target);
        for (v.tags) |r| try b.tags.put(gpa, r.name, r.target);
        for (v.git_refs) |r| try b.git_refs.put(gpa, r.name, r.target);
        for (v.remote_bookmarks) |r| try b.putRemote(r);
        b.git_head = v.git_head;
        for (v.wc_commits) |w| try b.wc_commits.put(gpa, w.workspace, w.commit);
        for (v.lanes) |l| try b.lanes.put(gpa, l.name, l);
        b.extra = v.extra;
        return b;
    }

    pub fn remoteKey(b: *ViewBuilder, remote: []const u8, name: []const u8) Allocator.Error![]const u8 {
        return std.mem.concat(b.keys.allocator(), u8, &.{ remote, "\x00", name });
    }

    pub fn putRemote(b: *ViewBuilder, r: RemoteBookmark) Allocator.Error!void {
        const key = try b.remoteKey(r.remote, r.name);
        if (r.target.isAbsent() and !r.tracked) {
            _ = b.remote_bookmarks.orderedRemove(key);
            return;
        }
        try b.remote_bookmarks.put(b.gpa, key, r);
    }

    /// Sets (or, with an absent target, removes) a named ref in `map`.
    pub fn setNamed(b: *ViewBuilder, map: *std.StringArrayHashMapUnmanaged(RefTarget), name: []const u8, t: RefTarget) Allocator.Error!void {
        if (t.isAbsent()) {
            _ = map.orderedRemove(name);
            return;
        }
        try map.put(b.gpa, name, t);
    }

    /// A sorted, validated `View` whose slices live in `arena`.
    pub fn toView(b: *const ViewBuilder, arena: Allocator) Allocator.Error!View {
        const heads = try arena.dupe(ObjectId, b.heads.keys());
        std.mem.sort(ObjectId, heads, {}, ObjectId.lessThan);
        const remotes = try arena.dupe(RemoteBookmark, b.remote_bookmarks.values());
        std.mem.sort(RemoteBookmark, remotes, {}, struct {
            fn lt(_: void, x: RemoteBookmark, y: RemoteBookmark) bool {
                return switch (std.mem.order(u8, x.remote, y.remote)) {
                    .lt => true,
                    .gt => false,
                    .eq => std.mem.order(u8, x.name, y.name) == .lt,
                };
            }
        }.lt);
        const wcs = try arena.alloc(WcCommit, b.wc_commits.count());
        for (wcs, b.wc_commits.keys(), b.wc_commits.values()) |*w, k, c| w.* = .{ .workspace = k, .commit = c };
        std.mem.sort(WcCommit, wcs, {}, struct {
            fn lt(_: void, x: WcCommit, y: WcCommit) bool {
                return std.mem.order(u8, x.workspace, y.workspace) == .lt;
            }
        }.lt);
        const lanes = try arena.dupe(LaneRecord, b.lanes.values());
        std.mem.sort(LaneRecord, lanes, {}, struct {
            fn lt(_: void, x: LaneRecord, y: LaneRecord) bool {
                return std.mem.order(u8, x.name, y.name) == .lt;
            }
        }.lt);
        return .{
            .heads = heads,
            .bookmarks = try namedSorted(arena, &b.bookmarks),
            .remote_bookmarks = remotes,
            .tags = try namedSorted(arena, &b.tags),
            .git_refs = try namedSorted(arena, &b.git_refs),
            .git_head = b.git_head,
            .wc_commits = wcs,
            .lanes = lanes,
            .extra = b.extra,
        };
    }
};

fn namedSorted(arena: Allocator, map: *const std.StringArrayHashMapUnmanaged(RefTarget)) Allocator.Error![]const NamedRef {
    const out = try arena.alloc(NamedRef, map.count());
    for (out, map.keys(), map.values()) |*o, k, v| o.* = .{ .name = k, .target = v };
    std.mem.sort(NamedRef, out, {}, struct {
        fn lt(_: void, x: NamedRef, y: NamedRef) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.lt);
    return out;
}

/// Every commit a view keeps alive: heads, ref targets, working-copy
/// commits and lane bases (GC roots and edges).
pub fn forEachCommit(v: View, ctx: anytype, comptime f: fn (@TypeOf(ctx), ObjectId) anyerror!void) anyerror!void {
    for (v.heads) |h| try f(ctx, h);
    for ([_][]const NamedRef{ v.bookmarks, v.tags, v.git_refs }) |refs| {
        for (refs) |r| for (r.target.terms) |x| if (x) |id| try f(ctx, id);
    }
    for (v.remote_bookmarks) |r| for (r.target.terms) |x| if (x) |id| try f(ctx, id);
    for (v.git_head.terms) |x| if (x) |id| try f(ctx, id);
    for (v.wc_commits) |w| try f(ctx, w.commit);
    for (v.lanes) |l| if (l.base) |id| try f(ctx, id);
}
