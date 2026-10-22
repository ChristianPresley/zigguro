//! Three-way tree merges, for rebasing (lane landing, the F04 rewrite
//! engine). Each name resolves trivially when at most one side changed
//! it, or when both sides made the same change; directories changed on
//! both sides merge recursively. A text file changed on both sides goes
//! through the line merge (`content_merge.zig`), with its file/executable
//! kind merged separately, so a mode change on one side and an edit on
//! the other both apply. Anything else changed on both sides (binary
//! files, symlinks, file vs directory, delete vs modify, overlapping
//! edits) is a conflict: the merge reports its path and produces no tree.
//!
//! Merged trees are written to the caller's batch. The batch cannot be
//! read until it commits, so the merger keeps what it wrote and reads its
//! own trees from there; a tree merged earlier can be a later input.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const enc = @import("../store/encode.zig");
const store_mod = @import("../store/store.zig");
const chunker = @import("../store/chunker.zig");
const content_merge = @import("content_merge.zig");
const ObjectId = id_mod.ObjectId;
const Tree = object.Tree;
const TreeEntry = object.TreeEntry;
const Allocator = std.mem.Allocator;

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

    /// A text file changed on both sides, merged; null when it cannot be.
    fn mergeFile(tm: *TreeMerger, name: []const u8, b: ?TreeEntry, l: ?TreeEntry, r: ?TreeEntry) !?TreeEntry {
        if (!tm.content) return null;
        const le = l orelse return null;
        const re = r orelse return null;
        if (!isText(le) or !isText(re)) return null;
        if (b) |x| if (!isText(x)) return null;
        const kind: object.EntryKind = if (le.kind == re.kind)
            le.kind
        else if (b != null and b.?.kind == le.kind)
            re.kind
        else if (b != null and b.?.kind == re.kind)
            le.kind
        else
            return null;
        const id: ObjectId = if (le.id.eql(re.id))
            le.id
        else if (b != null and b.?.id.eql(le.id))
            re.id
        else if (b != null and b.?.id.eql(re.id))
            le.id
        else blk: {
            const bt: []const u8 = if (b) |x| (try tm.readBlob(x.id)) orelse return null else "";
            const lt = (try tm.readBlob(le.id)) orelse return null;
            const rt = (try tm.readBlob(re.id)) orelse return null;
            for ([_][]const u8{ bt, lt, rt }) |x| if (content_merge.isBinary(x)) return null;
            const vals = try tm.arena().dupe([]const u8, &.{ lt, bt, rt });
            const res = try content_merge.mergeContent(tm.arena(), .{ .values = vals }, .{});
            break :blk try tm.putBlob(res.clean orelse return null);
        };
        return .{ .name = name, .kind = kind, .id = id };
    }

    /// Merges the changes from `base` to `right` into `left` (null base:
    /// the empty tree). Null when a path conflicts; the paths are added to
    /// `conflicts`.
    pub fn merge3(tm: *TreeMerger, base: ?ObjectId, left: ObjectId, right: ObjectId) !?ObjectId {
        return tm.mergeAt("", base, left, right);
    }

    fn mergeAt(tm: *TreeMerger, prefix: []const u8, base: ?ObjectId, left: ObjectId, right: ObjectId) anyerror!?ObjectId {
        if (left.eql(right)) return left;
        if (base) |b| {
            if (b.eql(left)) return right;
            if (b.eql(right)) return left;
        }
        const a = tm.arena();
        const bt: Tree = if (base) |b| try tm.read(b) else .{ .entries = &.{} };
        const lt = try tm.read(left);
        const rt = try tm.read(right);

        var names: std.StringArrayHashMapUnmanaged(void) = .empty;
        for ([_]Tree{ bt, lt, rt }) |t| for (t.entries) |e| try names.put(a, e.name, {});

        var out: std.ArrayList(TreeEntry) = .empty;
        var ok = true;
        for (names.keys()) |name| {
            const b = byName(bt, name);
            const l = byName(lt, name);
            const r = byName(rt, name);
            const pick: ?TreeEntry = if (sameEntry(l, r))
                l
            else if (sameEntry(b, l))
                r
            else if (sameEntry(b, r))
                l
            else if (isDir(l) and isDir(r) and (b == null or isDir(b))) blk: {
                const path = try join(a, prefix, name);
                const sub = (try tm.mergeAt(path, if (b) |x| x.id else null, l.?.id, r.?.id)) orelse {
                    ok = false;
                    continue;
                };
                if ((try tm.read(sub)).entries.len == 0) break :blk null;
                break :blk .{ .name = name, .kind = .tree, .id = sub };
            } else if (try tm.mergeFile(name, b, l, r)) |e|
                e
            else {
                try tm.conflicts.append(a, try join(a, prefix, name));
                ok = false;
                continue;
            };
            if (pick) |e| try out.append(a, e);
        }
        if (!ok) return null;
        return try tm.write(out.items);
    }
};

/// The entry named `name`; a tree has at most one per name.
fn byName(t: Tree, name: []const u8) ?TreeEntry {
    return t.find(name);
}

fn isText(e: TreeEntry) bool {
    return e.kind == .file or e.kind == .executable;
}

fn isDir(e: ?TreeEntry) bool {
    return if (e) |x| x.kind == .tree else false;
}

fn sameEntry(a: ?TreeEntry, b: ?TreeEntry) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.kind == b.?.kind and a.?.id.eql(b.?.id);
}

fn join(a: Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    if (prefix.len == 0) return a.dupe(u8, name);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, name });
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
}
