//! Tree merges (E09.F04.S01.T02), for rebasing (lane landing, the F04
//! rewrite engine) and resolving. `mergeTrees` merges any `Merge` of trees
//! (side, base, side, ...) lazily: identical subtrees are never loaded,
//! and each name resolves on its own:
//!
//! - trivially, when the terms cancel out or every side made the same
//!   change (`Merge.resolveTrivial`);
//! - directories that are directories on every side (and absent or
//!   directories in every base) merge recursively;
//! - text files on every side go through the line merge
//!   (`content_merge.zig`), with their file/executable kind merged
//!   separately, so a mode change on one side and an edit on the other
//!   both apply;
//! - anything else (binary files, symlinks, file vs directory, delete vs
//!   modify, overlapping edits) stays a conflict.
//!
//! A conflicted result is a `Merge` of whole trees with the same terms as
//! the input: every term holds the resolved entries, plus that term's own
//! value at each conflicted path (Jujutsu's first-class conflicts).
//! `merge3` is the three-term case for callers that only want a clean
//! tree: it reports the conflicted paths and returns null.
//!
//! Results are memoized in an optional `MergeCache`, keyed by the input
//! IDs, so rebasing a stack reuses merges of unchanged subtrees. Merged
//! trees and blobs are written to the caller's batch. The batch cannot be
//! read until it commits, so the merger keeps what it wrote and reads its
//! own objects from there; a tree merged earlier can be a later input.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const enc = @import("../store/encode.zig");
const store_mod = @import("../store/store.zig");
const chunker = @import("../store/chunker.zig");
const merge_mod = @import("merge.zig");
const content_merge = @import("content_merge.zig");
const ObjectId = id_mod.ObjectId;
const Tree = object.Tree;
const TreeEntry = object.TreeEntry;
const Merge = merge_mod.Merge;
const Allocator = std.mem.Allocator;

/// Directory merge results by input terms. The trees it names live in
/// the batch the merges wrote to: keep a cache only as long as that batch
/// (or the store it commits to) and drop it (`clear`) when the batch is
/// aborted. Not thread-safe.
pub const MergeCache = struct {
    arena_state: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged([]const ?ObjectId) = .empty,
    hits: usize = 0,

    pub fn init(gpa: Allocator) MergeCache {
        return .{ .arena_state = .init(gpa) };
    }

    pub fn deinit(c: *MergeCache) void {
        c.arena_state.deinit();
    }

    pub fn clear(c: *MergeCache) void {
        c.map = .empty;
        _ = c.arena_state.reset(.retain_capacity);
    }

    fn key(buf: []u8, terms: []const ?ObjectId, content: bool) []const u8 {
        var n: usize = 0;
        buf[n] = @intFromBool(content);
        n += 1;
        for (terms) |t| {
            if (t) |id| {
                buf[n] = 1;
                @memcpy(buf[n + 1 ..][0..id.bytes.len], &id.bytes);
                n += 1 + id.bytes.len;
            } else {
                buf[n] = 0;
                n += 1;
            }
        }
        return buf[0..n];
    }

    fn get(c: *MergeCache, k: []const u8) ?[]const ?ObjectId {
        const v = c.map.get(k) orelse return null;
        c.hits += 1;
        return v;
    }

    fn put(c: *MergeCache, k: []const u8, v: []const ?ObjectId) !void {
        const a = c.arena_state.allocator();
        try c.map.put(a, try a.dupe(u8, k), try a.dupe(?ObjectId, v));
    }
};

pub const TreeMerger = struct {
    arena_state: std.heap.ArenaAllocator,
    store: *store_mod.Store,
    batch: *store_mod.WriteBatch,
    /// Trees this merger wrote, by ID.
    written: std.AutoHashMapUnmanaged(ObjectId, Tree) = .empty,
    /// Conflicting paths found so far (across calls).
    conflicts: std.ArrayList([]const u8) = .empty,
    /// Blobs this merger wrote (unreadable from the batch until it
    /// commits).
    blobs: std.AutoHashMapUnmanaged(ObjectId, []const u8) = .empty,
    /// Merge text files changed on both sides by lines.
    content: bool = true,
    /// Decided entries by full path (null: deleted), used where a path
    /// changed on several sides and would otherwise merge or conflict
    /// (the resolve proposer's decisions). Merges are not cached while
    /// overrides are set.
    overrides: ?*const std.StringHashMapUnmanaged(?TreeEntry) = null,
    cache: ?*MergeCache = null,
    /// Trees read from the store (not from this merger's writes).
    loaded: usize = 0,

    pub fn init(gpa: Allocator, store: *store_mod.Store, batch: *store_mod.WriteBatch) TreeMerger {
        return .{ .arena_state = .init(gpa), .store = store, .batch = batch };
    }

    pub fn deinit(tm: *TreeMerger) void {
        tm.arena_state.deinit();
    }

    fn arena(tm: *TreeMerger) Allocator {
        return tm.arena_state.allocator();
    }

    /// Reads tree `id`, from this merger's writes or the store.
    pub fn read(tm: *TreeMerger, id: ObjectId) !Tree {
        if (tm.written.get(id)) |t| return t;
        const r = try tm.store.read(id);
        defer r.release();
        if (r.kind != .tree) return error.WrongKind;
        tm.loaded += 1;
        const bytes = try tm.arena().dupe(u8, r.bytes);
        return enc.decode(Tree, tm.arena(), bytes) catch error.CorruptObject;
    }

    /// Writes `entries` (any order) as a tree.
    pub fn write(tm: *TreeMerger, entries: []TreeEntry) !ObjectId {
        Tree.sort(entries);
        const t: Tree = .{ .entries = entries };
        const bytes = try enc.encodeAlloc(tm.arena(), Tree, t);
        const id = try tm.batch.put(.tree, bytes);
        try tm.written.put(tm.arena(), id, t);
        return id;
    }

    /// Writes a blob, keeping it readable for later merges.
    pub fn putBlob(tm: *TreeMerger, bytes: []const u8) !ObjectId {
        const id = try tm.batch.put(.blob, bytes);
        try tm.blobs.put(tm.arena(), id, try tm.arena().dupe(u8, bytes));
        return id;
    }

    /// A blob's bytes, or null when it cannot be read (not committed yet).
    fn readBlob(tm: *TreeMerger, id: ObjectId) !?[]const u8 {
        if (tm.blobs.get(id)) |b| return b;
        var buf: [16 << 10]u8 = undefined;
        var br = chunker.blobReader(tm.store, id, &buf) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return null,
        };
        defer br.deinit();
        return br.interface.readAlloc(tm.arena(), @intCast(br.size)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    }

    fn emptyTree(tm: *TreeMerger) !ObjectId {
        var none: [0]TreeEntry = .{};
        return tm.write(&none);
    }

    /// Merges the changes from `base` to `right` into `left` (null base:
    /// the empty tree). Null when a path conflicts; the paths are added to
    /// `conflicts`.
    pub fn merge3(tm: *TreeMerger, base: ?ObjectId, left: ObjectId, right: ObjectId) !?ObjectId {
        const r = try tm.mergeDir("", &.{ left, base, right });
        if (r.len != 1) return null;
        return r[0] orelse try tm.emptyTree();
    }

    /// Merges the trees `m` (side, base, side, ...): a single tree when
    /// it resolves, otherwise one tree per remaining term. Conflicted
    /// paths are added to `conflicts`.
    pub fn mergeTrees(tm: *TreeMerger, m: Merge(ObjectId)) !Merge(ObjectId) {
        const a = tm.arena();
        const s = try m.simplify(a, idEql);
        const terms = try a.alloc(?ObjectId, s.values.len);
        for (terms, s.values) |*t, v| t.* = v;
        const r = try tm.mergeDir("", terms);
        const out = try a.alloc(ObjectId, r.len);
        for (out, r) |*o, x| o.* = x orelse try tm.emptyTree();
        return .{ .values = out };
    }

    /// The values `m` of one path (side, base, side, ...) merged: a
    /// single value when it resolves, otherwise `m` itself. Conflicted
    /// paths below a directory are added to `conflicts`.
    pub fn mergeEntry(tm: *TreeMerger, path: []const u8, m: Merge(?TreeEntry)) !Merge(?TreeEntry) {
        const a = tm.arena();
        const name = std.fs.path.basenamePosix(path);
        if (m.resolveTrivial(.accept, entryEql)) |v| return resolvedEntry(a, v);
        if (tm.overrides) |ov| if (ov.get(path)) |o| {
            var e = o orelse return resolvedEntry(a, null);
            e.name = name;
            return resolvedEntry(a, e);
        };
        if (isDirMerge(m)) {
            const ids = try a.alloc(?ObjectId, m.values.len);
            for (ids, m.values) |*id, v| id.* = if (v) |e| e.id else null;
            const r = try tm.mergeDir(path, ids);
            if (r.len == 1) return resolvedEntry(a, if (r[0]) |id| TreeEntry{ .name = name, .kind = .tree, .id = id } else null);
            const vals = try a.alloc(?TreeEntry, r.len);
            for (vals, r) |*v, x| v.* = if (x) |id| .{ .name = name, .kind = .tree, .id = id } else null;
            return .{ .values = vals };
        }
        if (try tm.mergeFile(name, m)) |e| return resolvedEntry(a, e);
        try tm.conflicts.append(a, try a.dupe(u8, path));
        return m;
    }

    /// Merges directories `terms` (null: absent). One ID (null when the
    /// result is empty) when it resolves, otherwise one per term.
    fn mergeDir(tm: *TreeMerger, prefix: []const u8, terms: []const ?ObjectId) anyerror![]const ?ObjectId {
        const a = tm.arena();
        const m: Merge(?ObjectId) = .{ .values = terms };
        if (m.resolveTrivial(.accept, optIdEql)) |v| return a.dupe(?ObjectId, &.{v});

        var key_buf: [1 + 33 * 32]u8 = undefined;
        const cache = if (tm.overrides == null and terms.len <= 32) tm.cache else null;
        const key = if (cache != null) MergeCache.key(&key_buf, terms, tm.content) else "";
        if (cache) |c| if (c.get(key)) |hit| return hit;

        const trees = try a.alloc(Tree, terms.len);
        for (trees, terms) |*t, id| t.* = if (id) |x| try tm.read(x) else .{ .entries = &.{} };
        var names: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (trees) |t| for (t.entries) |e| try names.put(a, e.name, {});

        var common: std.ArrayList(TreeEntry) = .empty;
        const Conflicted = struct { name: []const u8, values: []const ?TreeEntry };
        var conflicted: std.ArrayList(Conflicted) = .empty;
        const vals = try a.alloc(?TreeEntry, terms.len);
        for (names.keys()) |name| {
            for (vals, trees) |*v, t| v.* = t.find(name);
            const path = if (prefix.len == 0) name else try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, name });
            const r = try tm.mergeEntry(path, .{ .values = vals });
            if (r.values.len == 1) {
                if (r.values[0]) |e| try common.append(a, e);
            } else {
                try conflicted.append(a, .{ .name = name, .values = try a.dupe(?TreeEntry, r.values) });
            }
        }

        var out: []?ObjectId = undefined;
        if (conflicted.items.len == 0) {
            out = try a.alloc(?ObjectId, 1);
            out[0] = if (common.items.len == 0) null else try tm.write(common.items);
        } else {
            out = try a.alloc(?ObjectId, terms.len);
            for (out, 0..) |*o, i| {
                var entries: std.ArrayList(TreeEntry) = .empty;
                try entries.appendSlice(a, common.items);
                for (conflicted.items) |c| if (c.values[i]) |e| {
                    var x = e;
                    x.name = c.name;
                    try entries.append(a, x);
                };
                o.* = if (entries.items.len == 0) null else try tm.write(entries.items);
            }
        }
        if (cache) |c| try c.put(key, out);
        return out;
    }

    /// Text files on every side, merged; null when they cannot be.
    fn mergeFile(tm: *TreeMerger, name: []const u8, m: Merge(?TreeEntry)) !?TreeEntry {
        if (!tm.content) return null;
        const a = tm.arena();
        const v = m.values;
        for (v, 0..) |x, i| {
            if (x) |e| {
                if (!isText(e)) return null;
            } else if (i % 2 == 0) return null; // deleted on a side
        }
        // The kind: from the bases when every base has one, else every
        // side must agree.
        const kinds = try a.alloc(object.EntryKind, v.len);
        var bases_present = true;
        for (kinds, v, 0..) |*k, x, i| {
            if (x) |e| k.* = e.kind else {
                bases_present = false;
                k.* = v[i - 1].?.kind;
            }
        }
        const kind: object.EntryKind = if (bases_present)
            (Merge(object.EntryKind){ .values = kinds }).resolveTrivial(.accept, kindEql) orelse return null
        else blk: {
            for (v) |x| if (x) |e| if (e.kind != v[0].?.kind) return null;
            break :blk v[0].?.kind;
        };
        // The content: trivially when it can, else by lines.
        const ids = try a.alloc(?ObjectId, v.len);
        for (ids, v) |*id, x| id.* = if (x) |e| e.id else null;
        if ((Merge(?ObjectId){ .values = ids }).resolveTrivial(.accept, optIdEql)) |id|
            return .{ .name = name, .kind = kind, .id = id.? };
        const texts = try a.alloc([]const u8, v.len);
        for (texts, v) |*t, x| {
            t.* = if (x) |e| (try tm.readBlob(e.id)) orelse return null else "";
            if (content_merge.isBinary(t.*)) return null;
        }
        const res = try content_merge.mergeContent(a, .{ .values = texts }, .{});
        return .{ .name = name, .kind = kind, .id = try tm.putBlob(res.clean orelse return null) };
    }
};

fn resolvedEntry(a: Allocator, v: ?TreeEntry) !Merge(?TreeEntry) {
    return .{ .values = try a.dupe(?TreeEntry, &.{v}) };
}

/// Every side a directory, every base a directory or absent.
fn isDirMerge(m: Merge(?TreeEntry)) bool {
    for (m.values, 0..) |x, i| {
        if (x) |e| {
            if (e.kind != .tree) return false;
        } else if (i % 2 == 0) return false;
    }
    return true;
}

fn isText(e: TreeEntry) bool {
    return e.kind == .file or e.kind == .executable;
}

fn idEql(a: ObjectId, b: ObjectId) bool {
    return a.eql(b);
}

fn optIdEql(a: ?ObjectId, b: ?ObjectId) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

fn kindEql(a: object.EntryKind, b: object.EntryKind) bool {
    return a == b;
}

fn entryEql(a: ?TreeEntry, b: ?TreeEntry) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.kind == b.?.kind and a.?.id.eql(b.?.id);
}

const testing = std.testing;

/// Builds trees from "path=content" specs (content "" omitted) for tests.
pub fn testTree(tm: *TreeMerger, files: []const [2][]const u8) !ObjectId {
    return testDir(tm, "", files);
}

fn testDir(tm: *TreeMerger, prefix: []const u8, files: []const [2][]const u8) !ObjectId {
    const a = tm.arena();
    var entries: std.ArrayList(TreeEntry) = .empty;
    var dirs: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (files) |f| {
        if (!std.mem.startsWith(u8, f[0], prefix)) continue;
        const rest = f[0][prefix.len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            try dirs.put(a, rest[0..slash], {});
        } else {
            try entries.append(a, .{ .name = rest, .kind = .file, .id = try tm.putBlob(f[1]) });
        }
    }
    for (dirs.keys()) |d| {
        const sub = try testDir(tm, try std.fmt.allocPrint(a, "{s}{s}/", .{ prefix, d }), files);
        try entries.append(a, .{ .name = d, .kind = .tree, .id = sub });
    }
    return tm.write(entries.items);
}

test "tree merge: disjoint, same, recursive, deletions and conflicts" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s = try store_mod.Store.open(gpa, testing.io, tmp.dir, .{ .fsync = false });
    defer s.close();
    var b = s.batch();
    defer b.abort();
    var tm = TreeMerger.init(gpa, s, &b);
    defer tm.deinit();

    const base = try testTree(&tm, &.{ .{ "a.txt", "a" }, .{ "src/x.zig", "x" }, .{ "src/y.zig", "y" }, .{ "gone/z", "z" } });
    // Left: edits src/x.zig, adds b.txt. Right: edits src/y.zig, deletes
    // gone/z, makes the same new file as left.
    const left = try testTree(&tm, &.{ .{ "a.txt", "a" }, .{ "b.txt", "b" }, .{ "src/x.zig", "x2" }, .{ "src/y.zig", "y" }, .{ "gone/z", "z" } });
    const right = try testTree(&tm, &.{ .{ "a.txt", "a" }, .{ "b.txt", "b" }, .{ "src/x.zig", "x" }, .{ "src/y.zig", "y2" } });
    const merged = (try tm.merge3(base, left, right)).?;
    const want = try testTree(&tm, &.{ .{ "a.txt", "a" }, .{ "b.txt", "b" }, .{ "src/x.zig", "x2" }, .{ "src/y.zig", "y2" } });
    try testing.expect(merged.eql(want));
    try testing.expectEqual(@as(usize, 0), tm.conflicts.items.len);

    // Trivial cases return an input unchanged.
    try testing.expect((try tm.merge3(base, base, right)).?.eql(right));
    try testing.expect((try tm.merge3(base, left, base)).?.eql(left));

    // Both edit src/x.zig: a conflict at that path.
    const other = try testTree(&tm, &.{ .{ "a.txt", "a" }, .{ "src/x.zig", "x3" }, .{ "src/y.zig", "y" }, .{ "gone/z", "z" } });
    try testing.expectEqual(@as(?ObjectId, null), try tm.merge3(base, left, other));
    try testing.expectEqualStrings("src/x.zig", tm.conflicts.items[0]);

    // No base (unrelated additions) merges by name.
    const one = try testTree(&tm, &.{.{ "p", "1" }});
    const two = try testTree(&tm, &.{.{ "q", "2" }});
    const both = try testTree(&tm, &.{ .{ "p", "1" }, .{ "q", "2" } });
    try testing.expect((try tm.merge3(null, one, two)).?.eql(both));
}

test "tree merge: mode + content, file vs dir, binary" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s = try store_mod.Store.open(gpa, testing.io, tmp.dir, .{ .fsync = false });
    defer s.close();
    var b = s.batch();
    defer b.abort();
    var tm = TreeMerger.init(gpa, s, &b);
    defer tm.deinit();

    // Both sides edit different lines of f; the right side also makes it
    // executable.
    const base = try testTree(&tm, &.{.{ "f", "1\n2\n3\n4\n5\n" }});
    const left = try testTree(&tm, &.{.{ "f", "one\n2\n3\n4\n5\n" }});
    const rt = try tm.read(try testTree(&tm, &.{.{ "f", "1\n2\n3\n4\nfive\n" }}));
    const rentries = try tm.arena().dupe(TreeEntry, rt.entries);
    rentries[0].kind = .executable;
    const right = try tm.write(rentries);
    const merged = (try tm.merge3(base, left, right)).?;
    const mt = try tm.read(merged);
    try testing.expectEqual(object.EntryKind.executable, mt.entries[0].kind);
    try testing.expectEqualStrings("one\n2\n3\n4\nfive\n", (try tm.readBlob(mt.entries[0].id)).?);

    // Overlapping edits still conflict.
    const clash = try testTree(&tm, &.{.{ "f", "ONE\n2\n3\n4\n5\n" }});
    try testing.expectEqual(@as(?ObjectId, null), try tm.merge3(base, left, clash));

    // A file on one side and a directory on the other.
    const dir = try testTree(&tm, &.{.{ "f/inner", "x" }});
    tm.conflicts.clearRetainingCapacity();
    try testing.expectEqual(@as(?ObjectId, null), try tm.merge3(base, left, dir));
    try testing.expectEqualStrings("f", tm.conflicts.items[0]);

    // Binary files are never line-merged.
    const bbase = try testTree(&tm, &.{.{ "f", "1\n\x00\n3\n" }});
    const bl = try testTree(&tm, &.{.{ "f", "x\n\x00\n3\n" }});
    const br = try testTree(&tm, &.{.{ "f", "1\n\x00\ny\n" }});
    try testing.expectEqual(@as(?ObjectId, null), try tm.merge3(bbase, bl, br));

    // With content merging off, any two-sided edit conflicts.
    tm.content = false;
    try testing.expectEqual(@as(?ObjectId, null), try tm.merge3(base, left, right));

    // Overrides decide two-sided paths, deletions included.
    var ov: std.StringHashMapUnmanaged(?TreeEntry) = .empty;
    try ov.put(tm.arena(), "f", .{ .name = "", .kind = .file, .id = try tm.putBlob("decided\n") });
    tm.overrides = &ov;
    const decided = try tm.read((try tm.merge3(base, left, clash)).?);
    try testing.expectEqualStrings("f", decided.entries[0].name);
    try testing.expectEqualStrings("decided\n", (try tm.readBlob(decided.entries[0].id)).?);
    ov.putAssumeCapacity("f", null);
    try testing.expectEqual(@as(usize, 0), (try tm.read((try tm.merge3(base, left, dir)).?)).entries.len);
}

/// "d{i}/s{j}/f{k}" for a grid of files, with `changed` entries' content
/// replaced.
fn gridFiles(a: Allocator, n: usize, changed: []const [2][]const u8) ![]const [2][]const u8 {
    var out: std.ArrayList([2][]const u8) = .empty;
    for (0..n) |i| for (0..n) |j| for (0..n) |k| {
        const path = try std.fmt.allocPrint(a, "d{d}/s{d}/f{d}", .{ i, j, k });
        var content = try std.fmt.allocPrint(a, "{s}\n", .{path});
        for (changed) |c| {
            if (std.mem.eql(u8, c[0], path)) content = try a.dupe(u8, c[1]);
        }
        try out.append(a, .{ path, content });
    };
    return out.items;
}

test "tree merge: lazy (counts loaded trees)" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s = try store_mod.Store.open(gpa, testing.io, tmp.dir, .{ .fsync = false });
    defer s.close();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // 10 x 10 x 10 files, three levels deep; left changes 2 files, right
    // 1 (in a directory left also changed).
    var b1 = s.batch();
    var tm1 = TreeMerger.init(gpa, s, &b1);
    defer tm1.deinit();
    const base = try testTree(&tm1, try gridFiles(a, 10, &.{}));
    const lc = [_][2][]const u8{ .{ "d1/s2/f3", "left\n" }, .{ "d4/s4/f4", "left\n" } };
    const rc = [_][2][]const u8{.{ "d1/s7/f0", "right\n" }};
    const left = try testTree(&tm1, try gridFiles(a, 10, &lc));
    const right = try testTree(&tm1, try gridFiles(a, 10, &rc));
    const want = try testTree(&tm1, try gridFiles(a, 10, &(lc ++ rc)));
    try b1.commit();

    var b2 = s.batch();
    defer b2.abort();
    var tm = TreeMerger.init(gpa, s, &b2);
    defer tm.deinit();
    try testing.expect((try tm.merge3(base, left, right)).?.eql(want));
    // Only the roots and d1 (changed on both sides) are read: d1/s2,
    // d1/s7 and d4 changed on one side and resolve by ID.
    const depth = 3;
    const changed = 3;
    try testing.expect(tm.loaded <= 3 * depth * changed);
    try testing.expectEqual(@as(usize, 6), tm.loaded);
}

test "tree merge: N-way fold" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const s = try store_mod.Store.open(gpa, testing.io, tmp.dir, .{ .fsync = false });
    defer s.close();
    var b = s.batch();
    defer b.abort();
    var tm = TreeMerger.init(gpa, s, &b);
    defer tm.deinit();
    var cache = MergeCache.init(gpa);
    defer cache.deinit();
    tm.cache = &cache;

    // Three sides over one base, each changing another file.
    const base = try testTree(&tm, &.{ .{ "a", "1\n" }, .{ "b", "1\n" }, .{ "dir/c", "1\n" } });
    const s0 = try testTree(&tm, &.{ .{ "a", "2\n" }, .{ "b", "1\n" }, .{ "dir/c", "1\n" } });
    const s1 = try testTree(&tm, &.{ .{ "a", "1\n" }, .{ "b", "2\n" }, .{ "dir/c", "1\n" } });
    const s2 = try testTree(&tm, &.{ .{ "a", "1\n" }, .{ "b", "1\n" }, .{ "dir/c", "2\n" } });
    const clean = try tm.mergeTrees(.{ .values = &.{ s0, base, s1, base, s2 } });
    const want = try testTree(&tm, &.{ .{ "a", "2\n" }, .{ "b", "2\n" }, .{ "dir/c", "2\n" } });
    try testing.expectEqual(@as(usize, 1), clean.values.len);
    try testing.expect(clean.values[0].eql(want));

    // Each side changes `a` its own way, and s1 also changes b: the
    // result keeps five terms, each with b merged and its own `a`.
    const x0 = try testTree(&tm, &.{ .{ "a", "X\n" }, .{ "b", "1\n" }, .{ "dir/c", "1\n" } });
    const x1 = try testTree(&tm, &.{ .{ "a", "Y\n" }, .{ "b", "2\n" }, .{ "dir/c", "1\n" } });
    const x2 = try testTree(&tm, &.{ .{ "a", "Z\n" }, .{ "b", "1\n" }, .{ "dir/c", "1\n" } });
    tm.conflicts.clearRetainingCapacity();
    const conf = try tm.mergeTrees(.{ .values = &.{ x0, base, x1, base, x2 } });
    try testing.expectEqual(@as(usize, 5), conf.values.len);
    try testing.expectEqualStrings("a", tm.conflicts.items[0]);
    const wants = [_][]const u8{ "X\n", "1\n", "Y\n", "1\n", "Z\n" };
    for (conf.values, wants) |t, w| {
        const tr = try tm.read(t);
        try testing.expectEqualStrings(w, (try tm.readBlob(tr.find("a").?.id)).?);
        try testing.expectEqualStrings("2\n", (try tm.readBlob(tr.find("b").?.id)).?);
    }

    // Merging the same terms again comes from the cache.
    const hits = cache.hits;
    const again = try tm.mergeTrees(.{ .values = &.{ x0, base, x1, base, x2 } });
    try testing.expect(cache.hits > hits);
    for (again.values, conf.values) |p, q| try testing.expect(p.eql(q));

    // Terms that cancel simplify away: (s0 - base + base) is s0.
    const same = try tm.mergeTrees(.{ .values = &.{ s0, base, base } });
    try testing.expect(same.values.len == 1 and same.values[0].eql(s0));

    // mergeEntry on one path: a mode change and an edit both apply.
    const f1 = try tm.putBlob("1\n2\n3\n");
    const f2 = try tm.putBlob("one\n2\n3\n");
    const e = try tm.mergeEntry("f", .{ .values = &.{
        .{ .name = "f", .kind = .file, .id = f2 },
        .{ .name = "f", .kind = .file, .id = f1 },
        .{ .name = "f", .kind = .executable, .id = f1 },
    } });
    try testing.expectEqual(object.EntryKind.executable, e.values[0].?.kind);
    try testing.expect(e.values[0].?.id.eql(f2));
}
