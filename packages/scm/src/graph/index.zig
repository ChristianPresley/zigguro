//! The commit index: a compact, memory-mapped, append-only map from dense
//! positions to commits, with parents, generation numbers, change IDs and
//! predecessor (evolution) edges. It is derived from the object store and
//! can always be rebuilt from it.
//!
//! Files live in the index directory: immutable `<checksum>.zgx` segments
//! (see `index_segment.zig`) and `HEAD`, naming the newest. Each update
//! writes one segment holding the new commits, first absorbing parent
//! segments that are not much bigger (as Jujutsu does), so the chain stays
//! logarithmic in length and positions never move.
//!
//! Readers work on a `View`: an immutable, ref-counted segment chain.
//! `CommitIndex.acquire` hands one out; queries on the `CommitIndex` itself
//! use the current view and are meant for the thread that updates it.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const enc = @import("../store/encode.zig");
const store_mod = @import("../store/store.zig");
const mapped = @import("../store/mapped.zig");
const seg = @import("index_segment.zig");
const ancestry = @import("ancestry.zig");
const ObjectId = id_mod.ObjectId;
const ChangeId = id_mod.ChangeId;
const Store = store_mod.Store;
const Allocator = std.mem.Allocator;

pub const Flags = seg.Flags;

/// A dense index position, stable for the life of the index (rebuilds may
/// renumber).
pub const Pos = enum(u32) {
    _,

    pub fn of(v: u32) Pos {
        return @enumFromInt(v);
    }

    pub fn int(p: Pos) u32 {
        return @intFromEnum(p);
    }
};

/// Parents or predecessors of an entry.
pub const PosList = struct {
    it: seg.PosIter,

    pub fn next(l: *PosList) ?Pos {
        return if (l.it.next()) |v| Pos.of(v) else null;
    }

    pub fn len(l: PosList) u32 {
        return l.it.len();
    }
};

/// Everything the index knows about one commit.
pub const Entry = struct {
    id: ObjectId,
    change_id: ChangeId,
    parents: PosList,
    predecessors: PosList,
    /// Topological level: 1 for roots, else 1 + the highest parent level
    /// (git commit-graph generation v1).
    level: u32,
    /// max(commit time, max(parent corrected time) + 1), in milliseconds
    /// (generation v2).
    corrected_time: u64,
    /// Committer time, milliseconds since the epoch.
    time_ms: i64,
    flags: Flags,
};

/// One mapped segment file, shared by the views that include it.
pub const SegmentFile = struct {
    refs: std.atomic.Value(u32) = .init(1),
    gpa: Allocator,
    io: std.Io,
    file: mapped.MappedFile,
    seg: seg.Segment,
    /// Reverse edges of this segment, built on first use: `parent << 32 |
    /// child` for every parent edge, sorted.
    kids: []u64 = &.{},
    kids_built: std.atomic.Value(bool) = .init(false),
    kids_mutex: std.Io.Mutex = .init,

    fn open(gpa: Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !*SegmentFile {
        var file = try mapped.MappedFile.open(gpa, io, dir, name);
        errdefer file.close(gpa, io);
        const s = try seg.Segment.parse(file.bytes);
        const sf = try gpa.create(SegmentFile);
        sf.* = .{ .gpa = gpa, .io = io, .file = file, .seg = s };
        return sf;
    }

    fn retain(sf: *SegmentFile) void {
        _ = sf.refs.fetchAdd(1, .monotonic);
    }

    fn release(sf: *SegmentFile) void {
        if (sf.refs.fetchSub(1, .acq_rel) != 1) return;
        sf.gpa.free(sf.kids);
        sf.file.close(sf.gpa, sf.io);
        sf.gpa.destroy(sf);
    }

    fn ensureKids(sf: *SegmentFile) Allocator.Error!void {
        if (sf.kids_built.load(.acquire)) return;
        sf.kids_mutex.lockUncancelable(sf.io);
        defer sf.kids_mutex.unlock(sf.io);
        if (sf.kids_built.load(.acquire)) return;
        const s = &sf.seg;
        var edges: std.ArrayList(u64) = .empty;
        errdefer edges.deinit(sf.gpa);
        for (0..s.count) |k| {
            const i: u32 = @intCast(k);
            var ps = s.parents(i);
            while (ps.next()) |p| try edges.append(sf.gpa, @as(u64, p) << 32 | (s.base + i));
        }
        std.mem.sort(u64, edges.items, {}, std.sort.asc(u64));
        sf.kids = try edges.toOwnedSlice(sf.gpa);
        sf.kids_built.store(true, .release);
    }

    /// The sorted edges whose parent is `p` (`ensureKids` first).
    fn kidsOf(sf: *const SegmentFile, p: u32) []const u64 {
        const lo_key = @as(u64, p) << 32;
        const lo = std.sort.lowerBound(u64, sf.kids, lo_key, orderU64);
        var hi = lo;
        while (hi < sf.kids.len and sf.kids[hi] >> 32 == p) hi += 1;
        return sf.kids[lo..hi];
    }

    /// File name: the checksum in hex.
    fn fileName(sf: *const SegmentFile, buf: *[68]u8) []const u8 {
        return segmentName(sf.seg.checksum(), buf);
    }
};

fn orderU64(key: u64, x: u64) std.math.Order {
    return std.math.order(key, x);
}

fn segmentName(sum: [seg.checksum_len]u8, buf: *[68]u8) []const u8 {
    const hex = std.fmt.bytesToHex(sum, .lower);
    @memcpy(buf[0..64], &hex);
    @memcpy(buf[64..68], ".zgx");
    return buf;
}

/// Children of one commit: each segment at or after the parent's holds
/// its own reverse edges.
pub const ChildIter = struct {
    view: *const View,
    p: u32,
    seg_k: usize,
    edges: []const u64 = &.{},
    i: usize = 0,
    visible: ?*const ancestry.VisibleSet,

    pub fn next(it: *ChildIter) ?Pos {
        while (true) {
            while (it.i < it.edges.len) {
                const c = Pos.of(@truncate(it.edges[it.i]));
                it.i += 1;
                if (it.visible) |vs| if (!vs.contains(c)) continue;
                return c;
            }
            if (it.seg_k >= it.view.segs.len) return null;
            it.edges = it.view.segs[it.seg_k].kidsOf(it.p);
            it.i = 0;
            it.seg_k += 1;
        }
    }
};

/// Result of `View.resolvePrefix`. Free with `deinit`.
pub const PrefixResult = union(enum) {
    /// Not hex and not reverse hex, empty, or too long.
    invalid,
    none,
    commit: Pos,
    change: ChangeId,
    /// Up to `max_candidates` matching commits.
    ambiguous_commits: []Pos,
    /// Up to `max_candidates` matching change IDs.
    ambiguous_changes: []ChangeId,

    pub const max_candidates = 16;

    pub fn deinit(r: PrefixResult, gpa: Allocator) void {
        switch (r) {
            .ambiguous_commits => |c| gpa.free(c),
            .ambiguous_changes => |c| gpa.free(c),
            else => {},
        }
    }
};

/// An immutable segment chain. Safe to share between threads.
pub const View = struct {
    refs: std.atomic.Value(u32) = .init(1),
    gpa: Allocator,
    io: std.Io,
    /// Oldest first; segs[i] covers [base, base + count).
    segs: []*SegmentFile,
    count: u32,

    fn create(gpa: Allocator, io: std.Io, segs: []*SegmentFile) !*View {
        const v = try gpa.create(View);
        var count: u32 = 0;
        if (segs.len > 0) count = segs[segs.len - 1].seg.base + segs[segs.len - 1].seg.count;
        v.* = .{ .gpa = gpa, .io = io, .segs = segs, .count = count };
        return v;
    }

    pub fn retain(v: *View) void {
        _ = v.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(v: *View) void {
        if (v.refs.fetchSub(1, .acq_rel) != 1) return;
        for (v.segs) |sf| sf.release();
        v.gpa.free(v.segs);
        v.gpa.destroy(v);
    }

    const Loc = struct { s: *const seg.Segment, i: u32 };

    inline fn locate(v: *const View, p: Pos) Loc {
        const x = p.int();
        std.debug.assert(x < v.count);
        var k = v.segs.len - 1;
        while (v.segs[k].seg.base > x) k -= 1;
        const s = &v.segs[k].seg;
        return .{ .s = s, .i = x - s.base };
    }

    /// The position of `id`, if indexed.
    pub fn pos(v: *const View, oid: ObjectId) ?Pos {
        var k = v.segs.len;
        while (k > 0) {
            k -= 1;
            const s = &v.segs[k].seg;
            if (s.find(oid)) |i| return Pos.of(s.base + i);
        }
        return null;
    }

    pub fn entry(v: *const View, p: Pos) Entry {
        const l = v.locate(p);
        return .{
            .id = l.s.idAt(l.i),
            .change_id = l.s.changeIdAt(l.i),
            .parents = .{ .it = l.s.parents(l.i) },
            .predecessors = .{ .it = l.s.preds(l.i) },
            .level = l.s.levelAt(l.i),
            .corrected_time = l.s.ctimeAt(l.i),
            .time_ms = l.s.timeAt(l.i),
            .flags = l.s.flagsAt(l.i),
        };
    }

    pub fn id(v: *const View, p: Pos) ObjectId {
        const l = v.locate(p);
        return l.s.idAt(l.i);
    }

    pub fn changeId(v: *const View, p: Pos) ChangeId {
        const l = v.locate(p);
        return l.s.changeIdAt(l.i);
    }

    pub fn level(v: *const View, p: Pos) u32 {
        const l = v.locate(p);
        return l.s.levelAt(l.i);
    }

    pub fn correctedTime(v: *const View, p: Pos) u64 {
        const l = v.locate(p);
        return l.s.ctimeAt(l.i);
    }

    pub fn parents(v: *const View, p: Pos) PosList {
        const l = v.locate(p);
        return .{ .it = l.s.parents(l.i) };
    }

    pub fn predecessors(v: *const View, p: Pos) PosList {
        const l = v.locate(p);
        return .{ .it = l.s.preds(l.i) };
    }

    /// Every position carrying change `cid` (visible or not; the caller
    /// filters by view), ascending. Caller frees.
    pub fn byChangeId(v: *const View, gpa: Allocator, cid: ChangeId) Allocator.Error![]Pos {
        var out: std.ArrayList(u32) = .empty;
        defer out.deinit(gpa);
        var local: std.ArrayList(u32) = .empty;
        defer local.deinit(gpa);
        for (v.segs) |sf| {
            local.clearRetainingCapacity();
            try sf.seg.findChange(cid, &local, gpa);
            for (local.items) |i| try out.append(gpa, sf.seg.base + i);
        }
        const res = try gpa.alloc(Pos, out.items.len);
        for (res, out.items) |*r, x| r.* = Pos.of(x);
        return res;
    }

    /// Resolves a user-typed prefix: hex digits name commits, reverse hex
    /// ('k'..'z') names changes.
    pub fn resolvePrefix(v: *const View, gpa: Allocator, text: []const u8) Allocator.Error!PrefixResult {
        const which = classify(text) orelse return .invalid;
        var nib: [64]u4 = undefined;
        for (text, 0..) |c, i| nib[i] = switch (which) {
            .commit => @intCast(std.fmt.charToDigit(c, 16) catch unreachable),
            .change => @intCast('z' - c),
        };
        const n = nib[0..text.len];
        switch (which) {
            .commit => {
                var found: std.ArrayList(Pos) = .empty;
                defer found.deinit(gpa);
                for (v.segs) |sf| {
                    var it = PrefixScan.init(&sf.seg, .id, n);
                    while (it.next()) |i| {
                        if (found.items.len == PrefixResult.max_candidates) break;
                        try found.append(gpa, Pos.of(sf.seg.base + i));
                    }
                }
                return switch (found.items.len) {
                    0 => .none,
                    1 => .{ .commit = found.items[0] },
                    else => .{ .ambiguous_commits = try found.toOwnedSlice(gpa) },
                };
            },
            .change => {
                var found: std.ArrayList(ChangeId) = .empty;
                defer found.deinit(gpa);
                outer: for (v.segs) |sf| {
                    var it = PrefixScan.init(&sf.seg, .change_id, n);
                    while (it.next()) |i| {
                        const cid = sf.seg.changeIdAt(i);
                        for (found.items) |f| {
                            if (f.eql(cid)) break;
                        } else {
                            if (found.items.len == PrefixResult.max_candidates) break :outer;
                            try found.append(gpa, cid);
                        }
                    }
                }
                return switch (found.items.len) {
                    0 => .none,
                    1 => .{ .change = found.items[0] },
                    else => .{ .ambiguous_changes = try found.toOwnedSlice(gpa) },
                };
            },
        }
    }

    /// The length of the shortest hex prefix naming `p`'s commit uniquely,
    /// at least `min`.
    pub fn shortestUniqueCommit(v: *const View, p: Pos, min: u8) u8 {
        const target = v.id(p);
        var common: u8 = 0;
        for (v.segs) |sf| common = @max(common, neighbourCommon(&sf.seg, .id, &target.bytes));
        return @max(min, @min(common + 1, 64));
    }

    /// The same for `p`'s change ID in reverse hex (other commits with the
    /// same change ID do not count).
    pub fn shortestUniqueChange(v: *const View, p: Pos, min: u8) u8 {
        const target = v.changeId(p);
        var common: u8 = 0;
        for (v.segs) |sf| common = @max(common, neighbourCommon(&sf.seg, .change_id, &target.bytes));
        return @max(min, @min(common + 1, 32));
    }

    /// Builds the reverse edges of every segment (once per segment file).
    pub fn ensureChildren(v: *const View) Allocator.Error!void {
        for (v.segs) |sf| try sf.ensureKids();
    }

    /// Positions of `p`'s children, ascending, optionally restricted to
    /// `visible`.
    pub fn children(v: *const View, p: Pos, visible: ?*const ancestry.VisibleSet) Allocator.Error!ChildIter {
        try v.ensureChildren();
        return v.childrenBuilt(p, visible);
    }

    /// `children` once `ensureChildren` has run.
    pub fn childrenBuilt(v: *const View, p: Pos, visible: ?*const ancestry.VisibleSet) ChildIter {
        var k: usize = v.segs.len;
        while (k > 0 and v.segs[k - 1].seg.base + v.segs[k - 1].seg.count > p.int()) k -= 1;
        return .{ .view = v, .p = p.int(), .seg_k = k, .visible = visible };
    }
};

const Field = enum { id, change_id };

fn classify(text: []const u8) ?enum { commit, change } {
    if (text.len == 0) return null;
    var hex = true;
    var rev = true;
    for (text) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) hex = false;
        if (c < 'k' or c > 'z') rev = false;
    }
    if (hex and text.len <= 64) return .commit;
    if (rev and text.len <= 32) return .change;
    return null;
}

fn columnBytes(s: *const seg.Segment, comptime f: Field, local: u32) []const u8 {
    return switch (f) {
        .id => s.bytes[s.layout.ids + 32 * @as(usize, local) ..][0..32],
        .change_id => s.bytes[s.layout.change_ids + 16 * @as(usize, local) ..][0..16],
    };
}

fn tables(s: *const seg.Segment, comptime f: Field) struct { fanout: usize, prefix: usize, pos: usize } {
    return switch (f) {
        .id => .{ .fanout = s.layout.id_fanout, .prefix = s.layout.id_prefix, .pos = s.layout.id_pos },
        .change_id => .{ .fanout = s.layout.cid_fanout, .prefix = s.layout.cid_prefix, .pos = s.layout.cid_pos },
    };
}

inline fn nibbleAt(bytes: []const u8, i: usize) u4 {
    const b = bytes[i / 2];
    return @intCast(if (i % 2 == 0) b >> 4 else b & 15);
}

fn commonNibbles(a: []const u8, b: []const u8) u8 {
    var n: u8 = 0;
    while (n < 2 * a.len and nibbleAt(a, n) == nibbleAt(b, n)) n += 1;
    return n;
}

/// Walks the sorted table of one segment over entries matching a nibble
/// prefix.
const PrefixScan = struct {
    s: *const seg.Segment,
    t: @TypeOf(tables(undefined, .id)),
    field: Field,
    nib: []const u4,
    k: u32,

    fn init(s: *const seg.Segment, f: Field, nib: []const u4) PrefixScan {
        var key: u64 = 0;
        for (0..16) |i| key = key << 4 | (if (i < nib.len) nib[i] else 0);
        const t = switch (f) {
            inline else => |ff| tables(s, ff),
        };
        const first: u8 = @truncate(key >> 56);
        return .{ .s = s, .t = t, .field = f, .nib = nib, .k = s.lowerBound(t.fanout, t.prefix, first, key) };
    }

    fn next(it: *PrefixScan) ?u32 {
        while (it.k < it.s.count) {
            const local = it.s.u32At(it.t.pos, it.k) -% it.s.base;
            it.k += 1;
            if (local >= it.s.count) continue;
            const bytes = switch (it.field) {
                inline else => |ff| columnBytes(it.s, ff, local),
            };
            for (it.nib, 0..) |n, i| {
                if (nibbleAt(bytes, i) != n) {
                    it.k = it.s.count;
                    return null;
                }
            }
            return local;
        }
        return null;
    }
};

/// The longest nibble prefix `target` shares with a different value in
/// segment `s`'s sorted table.
fn neighbourCommon(s: *const seg.Segment, comptime f: Field, target: []const u8) u8 {
    if (s.count == 0) return 0;
    const t = tables(s, f);
    const k = s.lowerBound(t.fanout, t.prefix, target[0], seg.prefix64(target));
    var best: u8 = 0;
    // Backwards to the first different value, forwards likewise.
    var j = k;
    while (j > 0) {
        j -= 1;
        const other = columnBytes(s, f, s.u32At(t.pos, j) - s.base);
        if (!std.mem.eql(u8, other, target)) {
            best = @max(best, commonNibbles(target, other));
            break;
        }
    }
    j = k;
    while (j < s.count) : (j += 1) {
        const other = columnBytes(s, f, s.u32At(t.pos, j) - s.base);
        if (!std.mem.eql(u8, other, target)) {
            best = @max(best, commonNibbles(target, other));
            break;
        }
    }
    return best;
}

pub const Options = struct {
    /// fsync segments before publishing them.
    fsync: bool = true,
    /// Squash older segments once a chain is longer than this.
    max_segments: u32 = 16,
    /// Asserts index work stays off the UI thread.
    runtime: ?*const @import("zg_core").Runtime = null,
};

/// The index over one store. `ensureIndexed` and `rebuild` serialize on an
/// internal mutex.
pub const CommitIndex = struct {
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    store: *Store,
    opts: Options,
    /// Serializes updates and the shared walker.
    mutex: std.Io.Mutex = .init,
    /// Guards swapping and acquiring `view`.
    view_mutex: std.Io.Mutex = .init,
    view: *View,
    walker: ancestry.Walker,
    /// `open` found the index missing or corrupt and started empty; the
    /// next `ensureIndexed` (or a `rebuild`) fills it again.
    recovered: bool = false,
    empty_tree: ObjectId,

    /// Opens the index in `dir` (which the caller keeps open). Only headers
    /// are read. A corrupt or missing chain gives an empty index with
    /// `recovered` set.
    pub fn open(gpa: Allocator, io: std.Io, dir: std.Io.Dir, store: *Store, opts: Options) !*CommitIndex {
        const ix = try gpa.create(CommitIndex);
        errdefer gpa.destroy(ix);
        const empty_tree = try enc.idOf(gpa, object.Tree, .{ .entries = &.{} });
        ix.* = .{ .gpa = gpa, .io = io, .dir = dir, .store = store, .opts = opts, .view = undefined, .walker = .init(gpa), .empty_tree = empty_tree };
        ix.view = loadHead(gpa, io, dir) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.FileNotFound => try View.create(gpa, io, try gpa.alloc(*SegmentFile, 0)),
            else => blk: {
                ix.recovered = true;
                break :blk try View.create(gpa, io, try gpa.alloc(*SegmentFile, 0));
            },
        };
        return ix;
    }

    pub fn close(ix: *CommitIndex) void {
        ix.view.release();
        ix.walker.deinit();
        ix.gpa.destroy(ix);
    }

    /// The current view, retained: release it when done. Safe from any
    /// thread.
    pub fn acquire(ix: *CommitIndex) *View {
        ix.view_mutex.lockUncancelable(ix.io);
        defer ix.view_mutex.unlock(ix.io);
        ix.view.retain();
        return ix.view;
    }

    fn swap(ix: *CommitIndex, v: *View) void {
        ix.view_mutex.lockUncancelable(ix.io);
        const old = ix.view;
        ix.view = v;
        ix.view_mutex.unlock(ix.io);
        old.release();
    }

    /// Number of indexed commits.
    pub fn count(ix: *const CommitIndex) u32 {
        return ix.view.count;
    }

    pub fn pos(ix: *const CommitIndex, oid: ObjectId) ?Pos {
        return ix.view.pos(oid);
    }

    pub fn entry(ix: *const CommitIndex, p: Pos) Entry {
        return ix.view.entry(p);
    }

    /// Caller frees.
    pub fn byChangeId(ix: *const CommitIndex, gpa: Allocator, cid: ChangeId) Allocator.Error![]Pos {
        return ix.view.byChangeId(gpa, cid);
    }

    pub fn resolvePrefix(ix: *const CommitIndex, gpa: Allocator, text: []const u8) Allocator.Error!PrefixResult {
        return ix.view.resolvePrefix(gpa, text);
    }

    /// Whether `a` is an ancestor of `b` (or equal to it).
    pub fn isAncestor(ix: *CommitIndex, a: Pos, b: Pos) Allocator.Error!bool {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        return ix.walker.isAncestor(ix.view, a, b);
    }

    /// The best common ancestors of `a` and `b`. Caller frees.
    pub fn mergeBases(ix: *CommitIndex, gpa: Allocator, a: Pos, b: Pos) Allocator.Error![]Pos {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        return ix.walker.mergeBases(ix.view, gpa, a, b);
    }

    /// Re-reads `HEAD` and adopts another process's newer chain.
    pub fn refresh(ix: *CommitIndex) !void {
        const v = loadHead(ix.gpa, ix.io, ix.dir) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return,
        };
        if (v.count <= ix.view.count) {
            v.release();
            return;
        }
        ix.swap(v);
    }

    /// Indexes every commit reachable from `heads` (through parents and
    /// predecessors) that is not indexed yet. Runs on a worker.
    pub fn ensureIndexed(ix: *CommitIndex, heads: []const ObjectId) !void {
        if (ix.opts.runtime) |rt| rt.assertNotUi();
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        for (heads) |h| {
            if (ix.view.pos(h) == null) break;
        } else return;
        try ix.refresh();

        var b: Builder = .{ .ix = ix, .view = ix.view, .mode = .incremental, .arena_state = .init(ix.gpa) };
        defer b.deinit();
        for (heads) |h| try b.visitFrom(h);
        if (b.order.items.len == 0) return;
        try ix.publish(&b, false);
    }

    /// Re-indexes every change in the store from scratch, decoding segments
    /// in parallel, and replaces the chain with one segment.
    pub fn rebuild(ix: *CommitIndex) !void {
        if (ix.opts.runtime) |rt| rt.assertNotUi();
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        const empty = try View.create(ix.gpa, ix.io, try ix.gpa.alloc(*SegmentFile, 0));
        defer empty.release();
        var b: Builder = .{ .ix = ix, .view = empty, .mode = .preloaded, .arena_state = .init(ix.gpa) };
        defer b.deinit();
        try b.loadAll();
        // Roots in ID order so the result does not depend on store layout.
        const ids = try ix.gpa.alloc(ObjectId, b.pending.items.len);
        defer ix.gpa.free(ids);
        for (ids, b.pending.items) |*d, p| d.* = p.id;
        std.mem.sort(ObjectId, ids, {}, ObjectId.lessThan);
        for (ids) |h| try b.visitFrom(h);
        try ix.publish(&b, true);
        ix.recovered = false;
    }

    /// Writes the builder's commits as a new segment (absorbing small
    /// parents, or everything when `replace_all`), then `HEAD`.
    fn publish(ix: *CommitIndex, b: *Builder, replace_all: bool) !void {
        const gpa = ix.gpa;
        const view = b.view;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var keep: usize = view.segs.len;
        var total: usize = b.order.items.len;
        if (!replace_all) {
            while (keep > 0 and (view.segs[keep - 1].seg.count <= 2 * total or keep >= ix.opts.max_segments)) {
                keep -= 1;
                total += view.segs[keep].seg.count;
            }
        } else keep = 0;

        var entries: std.ArrayList(seg.NewEntry) = try .initCapacity(gpa, total);
        defer entries.deinit(gpa);
        for (view.segs[keep..]) |sf| {
            const s = &sf.seg;
            for (0..s.count) |k| {
                const i: u32 = @intCast(k);
                entries.appendAssumeCapacity(.{
                    .id = s.idAt(i),
                    .change_id = s.changeIdAt(i),
                    .time_ms = s.timeAt(i),
                    .ctime = s.ctimeAt(i),
                    .level = s.levelAt(i),
                    .parents = try collect(arena, s.parents(i)),
                    .preds = try collect(arena, s.preds(i)),
                    .flags = s.flagsAt(i),
                });
            }
        }
        for (b.order.items) |pi| entries.appendAssumeCapacity(b.pending.items[pi].out);

        const base: u32 = if (keep == 0) 0 else view.segs[keep - 1].seg.base + view.segs[keep - 1].seg.count;
        const parent: ?[seg.checksum_len]u8 = if (keep == 0) null else view.segs[keep - 1].seg.checksum();
        const bytes = try seg.write(gpa, base, parent, entries.items);
        defer gpa.free(bytes);
        const parsed = try seg.Segment.parse(bytes);
        var name_buf: [68]u8 = undefined;
        const name = segmentName(parsed.checksum(), &name_buf);
        try writeFile(ix, name, bytes, false);
        var head: [64]u8 = undefined;
        @memcpy(&head, name[0..64]);
        try writeFile(ix, "HEAD", &head, true);

        const sf = try SegmentFile.open(gpa, ix.io, ix.dir, name);
        errdefer sf.release();
        const segs = try gpa.alloc(*SegmentFile, keep + 1);
        errdefer gpa.free(segs);
        for (view.segs[0..keep], segs[0..keep]) |old, *d| {
            old.retain();
            d.* = old;
        }
        segs[keep] = sf;
        const v = View.create(gpa, ix.io, segs) catch |e| {
            for (segs[0..keep]) |old| old.release();
            return e;
        };
        ix.swap(v);
    }

    fn writeFile(ix: *CommitIndex, name: []const u8, bytes: []const u8, replace: bool) !void {
        var af = try ix.dir.createFileAtomic(ix.io, name, .{ .replace = replace });
        defer af.deinit(ix.io);
        try af.file.writePositionalAll(ix.io, bytes, 0);
        if (ix.opts.fsync) try af.file.sync(ix.io);
        if (replace) return af.replace(ix.io);
        af.link(ix.io) catch |e| switch (e) {
            // Same name, so the same checksum: normally the same bytes, but
            // replace a damaged copy.
            error.PathAlreadyExists => {
                const same = blk: {
                    var m = mapped.MappedFile.open(ix.gpa, ix.io, ix.dir, name) catch break :blk false;
                    defer m.close(ix.gpa, ix.io);
                    break :blk std.mem.eql(u8, m.bytes, bytes);
                };
                if (!same) {
                    try ix.dir.deleteFile(ix.io, name);
                    try af.link(ix.io);
                }
            },
            else => return e,
        };
    }

    /// Deletes segment files that the current chain does not use and that
    /// are older than `grace_ns` (other processes may still read them).
    pub fn prune(ix: *CommitIndex, grace_ns: u64) !usize {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        const gpa = ix.gpa;
        var live: std.StringHashMapUnmanaged(void) = .empty;
        defer live.deinit(gpa);
        var names: std.ArrayList([68]u8) = .empty;
        defer names.deinit(gpa);
        try names.resize(gpa, ix.view.segs.len);
        for (ix.view.segs, names.items) |sf, *n| try live.put(gpa, sf.fileName(n), {});
        const now = std.Io.Timestamp.now(ix.io, .real).nanoseconds;
        var victims: std.ArrayList([]u8) = .empty;
        defer {
            for (victims.items) |v| gpa.free(v);
            victims.deinit(gpa);
        }
        var it = ix.dir.iterate();
        while (try it.next(ix.io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".zgx") or live.contains(e.name)) continue;
            try victims.append(gpa, try gpa.dupe(u8, e.name));
        }
        var removed: usize = 0;
        for (victims.items) |n| {
            const st = ix.dir.statFile(ix.io, n, .{}) catch continue;
            if (now - st.mtime.nanoseconds < grace_ns) continue;
            ix.dir.deleteFile(ix.io, n) catch continue;
            removed += 1;
        }
        return removed;
    }

    /// Checks every segment's checksum and stored positions (fsck).
    pub fn verify(ix: *const CommitIndex) bool {
        var expect_base: u32 = 0;
        for (ix.view.segs) |sf| {
            if (sf.seg.base != expect_base or !sf.seg.verify()) return false;
            expect_base += sf.seg.count;
        }
        return true;
    }
};

fn collect(arena: Allocator, it0: seg.PosIter) ![]const u32 {
    var it = it0;
    const out = try arena.alloc(u32, it.len());
    for (out) |*o| o.* = it.next().?;
    return out;
}

/// Reads `HEAD` and maps its chain, oldest first.
fn loadHead(gpa: Allocator, io: std.Io, dir: std.Io.Dir) !*View {
    var head: [64]u8 = undefined;
    const f = try dir.openFile(io, "HEAD", .{});
    const n = blk: {
        defer f.close(io);
        break :blk try f.readPositionalAll(io, &head, 0);
    };
    if (n != 64) return error.CorruptIndex;
    var sum: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&sum, &head) catch return error.CorruptIndex;

    var chain: std.ArrayList(*SegmentFile) = .empty;
    errdefer {
        for (chain.items) |sf| sf.release();
        chain.deinit(gpa);
    }
    var next: ?[32]u8 = sum;
    while (next) |want| {
        if (chain.items.len > 64) return error.CorruptIndex;
        var buf: [68]u8 = undefined;
        const sf = SegmentFile.open(gpa, io, dir, segmentName(want, &buf)) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return error.CorruptIndex,
        };
        try chain.append(gpa, sf);
        if (!std.mem.eql(u8, &sf.seg.checksum(), &want)) return error.CorruptIndex;
        next = sf.seg.parent();
        if (next == null and sf.seg.base != 0) return error.CorruptIndex;
    }
    std.mem.reverse(*SegmentFile, chain.items);
    var expect: u32 = 0;
    for (chain.items) |sf| {
        if (sf.seg.base != expect) return error.CorruptIndex;
        expect += sf.seg.count;
    }
    const segs = try chain.toOwnedSlice(gpa);
    errdefer gpa.free(segs);
    return View.create(gpa, io, segs);
}

/// A commit decoded but not yet indexed.
const Pending = struct {
    id: ObjectId,
    parents: []const ObjectId,
    preds: []const ObjectId,
    tree: ?ObjectId,
    out: seg.NewEntry,
    state: enum(u8) { new, open, done } = .new,
    pos: u32 = 0,
};

/// Decodes a change into a `Pending`; slices are copied into `arena`.
fn decodePending(arena: Allocator, oid: ObjectId, bytes: []const u8) !Pending {
    var scratch_buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&scratch_buf);
    var fallback: std.heap.ArenaAllocator = .init(arena);
    defer fallback.deinit();
    const scratch = if (bytes.len * 2 <= scratch_buf.len) fba.allocator() else fallback.allocator();
    const c = enc.decode(object.Change, scratch, bytes) catch return error.CorruptObject;
    return .{
        .id = oid,
        .parents = try arena.dupe(ObjectId, c.parents),
        .preds = try arena.dupe(ObjectId, c.predecessors),
        .tree = c.tree(),
        .out = .{
            .id = oid,
            .change_id = c.change_id,
            .time_ms = c.committer.time_ms,
            .ctime = 0,
            .level = 0,
            .parents = &.{},
            .preds = &.{},
            .flags = .{
                .conflict = c.tree_terms.len > 1,
                .signed = c.sig != null,
                .ai_touched = c.provenance != null,
                .merge = c.parents.len > 1,
            },
        },
    };
}

/// Decodes the changes of one store segment (rebuild).
const LoadTask = struct {
    gpa: Allocator,
    sg: *store_mod.Segment,
    arena: std.heap.ArenaAllocator = undefined,
    out: std.ArrayList(Pending) = .empty,
    err: ?anyerror = null,

    fn run(t: *LoadTask) void {
        t.arena = .init(t.gpa);
        t.load() catch |e| {
            t.err = e;
        };
    }

    fn load(t: *LoadTask) !void {
        const ix = t.sg.index;
        var inflate_buf: std.ArrayList(u8) = .empty;
        defer inflate_buf.deinit(t.gpa);
        for (0..ix.count) |k| {
            const i: u32 = @intCast(k);
            if ((t.sg.kindAt(i) catch continue) != .change) continue;
            const rec = try t.sg.record(i);
            var bytes = rec.payload;
            if (rec.deflated()) {
                try inflate_buf.resize(t.gpa, rec.raw_len);
                try store_mod.inflateRaw(rec.payload, inflate_buf.items);
                bytes = inflate_buf.items;
            }
            try t.out.append(t.gpa, try decodePending(t.arena.allocator(), ix.id(i), bytes));
        }
    }

    fn deinit(t: *LoadTask) void {
        t.out.deinit(t.gpa);
        t.arena.deinit();
    }
};

/// Collects new commits, orders them parents (and predecessors) first, and
/// fills in positions, levels and corrected times.
const Builder = struct {
    ix: *CommitIndex,
    view: *const View,
    mode: enum { incremental, preloaded },
    arena_state: std.heap.ArenaAllocator,
    pending: std.ArrayList(Pending) = .empty,
    map: std.AutoHashMapUnmanaged(ObjectId, u32) = .empty,
    missing: std.AutoHashMapUnmanaged(ObjectId, void) = .empty,
    /// Indexes into `pending`, in position order.
    order: std.ArrayList(u32) = .empty,
    /// Arenas holding preloaded decodes.
    keep: std.ArrayList(std.heap.ArenaAllocator) = .empty,

    fn deinit(b: *Builder) void {
        const gpa = b.ix.gpa;
        b.pending.deinit(gpa);
        b.map.deinit(gpa);
        b.missing.deinit(gpa);
        b.order.deinit(gpa);
        for (b.keep.items) |*a| a.deinit();
        b.keep.deinit(gpa);
        b.arena_state.deinit();
    }

    const Ref = union(enum) { indexed: Pos, pending: u32, missing };

    /// Where `oid` stands, decoding it from the store if needed.
    fn lookup(b: *Builder, oid: ObjectId) !Ref {
        if (b.view.pos(oid)) |p| return .{ .indexed = p };
        if (b.map.get(oid)) |i| return .{ .pending = i };
        if (b.mode == .preloaded or b.missing.contains(oid)) return .missing;
        const r = b.ix.store.read(oid) catch |e| switch (e) {
            error.NotFound => {
                try b.missing.put(b.ix.gpa, oid, {});
                return .missing;
            },
            else => return e,
        };
        defer r.release();
        if (r.kind != .change) return error.NotAChange;
        const i = try b.add(oid, r.bytes);
        return .{ .pending = i };
    }

    fn add(b: *Builder, oid: ObjectId, bytes: []const u8) !u32 {
        const gpa = b.ix.gpa;
        const arena = b.arena_state.allocator();
        const p = try decodePending(arena, oid, bytes);
        const i: u32 = @intCast(b.pending.items.len);
        try b.pending.append(gpa, p);
        try b.map.put(gpa, oid, i);
        return i;
    }

    /// Depth-first from `head`, parents then predecessors; a commit gets
    /// its position after all of them (post-order).
    fn visitFrom(b: *Builder, head: ObjectId) !void {
        const gpa = b.ix.gpa;
        const Frame = struct { i: u32, next: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(gpa);
        switch (try b.lookup(head)) {
            .indexed => return,
            .missing => return error.MissingCommit,
            .pending => |i| {
                if (b.pending.items[i].state != .new) return;
                b.pending.items[i].state = .open;
                try stack.append(gpa, .{ .i = i, .next = 0 });
            },
        }
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const p = &b.pending.items[top.i];
            const np: u32 = @intCast(p.parents.len);
            if (top.next < np + p.preds.len) {
                const k = top.next;
                top.next += 1;
                const child = if (k < np) p.parents[k] else p.preds[k - np];
                switch (try b.lookup(child)) {
                    .indexed => {},
                    .missing => if (k < np) return error.MissingParent,
                    .pending => |ci| {
                        const c = &b.pending.items[ci];
                        switch (c.state) {
                            .new => {
                                c.state = .open;
                                try stack.append(gpa, .{ .i = ci, .next = 0 });
                            },
                            .open => return error.CycleInHistory,
                            .done => {},
                        }
                    },
                }
                continue;
            }
            const i = top.i;
            stack.items.len -= 1;
            try b.finish(i);
        }
    }

    const Resolved = struct { pos: u32, level: u32, ctime: u64 };

    /// Position, level and corrected time of an indexed or finished commit.
    fn resolved(b: *Builder, oid: ObjectId) ?Resolved {
        if (b.view.pos(oid)) |p| return .{ .pos = p.int(), .level = b.view.level(p), .ctime = b.view.correctedTime(p) };
        const i = b.map.get(oid) orelse return null;
        const p = &b.pending.items[i];
        if (p.state != .done) return null;
        return .{ .pos = p.pos, .level = p.out.level, .ctime = p.out.ctime };
    }

    /// One parent and the same resolved tree, or a root with the empty
    /// tree.
    fn isEmpty(b: *Builder, p: *const Pending) !bool {
        const tree = p.tree orelse return false;
        switch (p.parents.len) {
            0 => return tree.eql(b.ix.empty_tree),
            1 => {},
            else => return false,
        }
        const parent_tree = blk: {
            if (b.map.get(p.parents[0])) |i| break :blk b.pending.items[i].tree;
            const r = b.ix.store.read(p.parents[0]) catch |e| switch (e) {
                error.NotFound => return false,
                else => return e,
            };
            defer r.release();
            var arena: std.heap.ArenaAllocator = .init(b.ix.gpa);
            defer arena.deinit();
            const c = enc.decode(object.Change, arena.allocator(), r.bytes) catch return false;
            break :blk c.tree();
        };
        return if (parent_tree) |t| t.eql(tree) else false;
    }

    /// Decodes every change in the store, one task per store segment.
    fn loadAll(b: *Builder) !void {
        const gpa = b.ix.gpa;
        const s = b.ix.store;
        try s.rescan();
        const segs = try s.snapshot(gpa);
        defer Store.releaseSnapshot(gpa, segs);
        const tasks = try gpa.alloc(LoadTask, segs.len);
        defer {
            for (tasks) |*t| t.deinit();
            gpa.free(tasks);
        }
        var g: std.Io.Group = .init;
        for (tasks, segs) |*t, sg| {
            t.* = .{ .gpa = gpa, .sg = sg };
            g.async(b.ix.io, LoadTask.run, .{t});
        }
        try g.await(b.ix.io);
        var total: usize = 0;
        for (tasks) |*t| {
            if (t.err) |e| return e;
            total += t.out.items.len;
        }
        try b.pending.ensureTotalCapacity(gpa, total);
        try b.map.ensureTotalCapacity(gpa, @intCast(total));
        for (tasks) |*t| {
            for (t.out.items) |p| {
                const gop = b.map.getOrPutAssumeCapacity(p.id);
                if (gop.found_existing) continue;
                gop.value_ptr.* = @intCast(b.pending.items.len);
                b.pending.appendAssumeCapacity(p);
            }
        }
        // The decoded slices live in the tasks' arenas; keep them.
        for (tasks) |*t| {
            try b.keep.append(gpa, t.arena);
            t.arena = .init(gpa);
        }
    }

    fn finish(b: *Builder, i: u32) !void {
        const gpa = b.ix.gpa;
        const arena = b.arena_state.allocator();
        const p = &b.pending.items[i];
        const position: u32 = b.view.count + @as(u32, @intCast(b.order.items.len));
        if (position >= seg.max_positions) return error.TooManyCommits;
        var level: u32 = 0;
        var ctime: u64 = 0;
        const ppos = try arena.alloc(u32, p.parents.len);
        for (p.parents, ppos) |par, *pp| {
            const r = b.resolved(par) orelse return error.MissingParent;
            pp.* = r.pos;
            level = @max(level, r.level);
            ctime = @max(ctime, r.ctime + 1);
        }
        var preds: std.ArrayList(u32) = .empty;
        for (p.preds) |pr| {
            if (b.resolved(pr)) |r| try preds.append(arena, r.pos);
        }
        p.out.parents = ppos;
        p.out.preds = preds.items;
        p.out.level = level + 1;
        p.out.ctime = @max(ctime, @as(u64, @intCast(@max(p.out.time_ms, 0))));
        p.out.flags.empty = try b.isEmpty(p);
        p.state = .done;
        p.pos = position;
        try b.order.append(gpa, i);
    }
};
