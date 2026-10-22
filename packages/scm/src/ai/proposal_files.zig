//! The files a proposal changes (E09.F06 read model for E12's review
//! items): for each commit the proposal creates or rewrites, the text of
//! every path it changes, before and after.
//!
//! "Before" is the commit's predecessor (what it rewrites) or, for a new
//! commit, its first parent. A path changed by several of the proposal's
//! commits appears once, from its first "before" to its last "after".
//! A `describe` proposal changes only descriptions: each described commit
//! gives one path, `.zigguro/scm/description/<change id>` (reverse hex),
//! with the old and new description. Other kinds list that path too when
//! a commit's description changed.
//!
//! Texts are for display only: binary files (with a NUL in the first 8 KiB)
//! and files over `max_file_bytes` become a one-line placeholder, a
//! symlink shows its target and a submodule its commit.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const store_mod = @import("../store/store.zig");
const chunker = @import("../store/chunker.zig");
const op_mod = @import("../oplog/operation.zig");
const ports = @import("ports.zig");
const ObjectId = id_mod.ObjectId;
const Store = store_mod.Store;
const Change = object.Change;
const Tree = object.Tree;
const TreeEntry = object.TreeEntry;
const Proposal = ports.Proposal;
const Allocator = std.mem.Allocator;

/// The prefix of a description's pseudo-path.
pub const description_prefix = ".zigguro/scm/description/";

/// One changed path. `base` is null when the proposal creates the path,
/// `new` when it deletes it.
pub const FileChange = struct {
    path: []const u8,
    base: ?[]const u8 = null,
    new: ?[]const u8 = null,
};

pub const ProposalFiles = struct {
    store: *Store,
    /// Larger files show as a placeholder.
    max_file_bytes: u64 = 4 << 20,

    /// The changed paths of `p`, sorted, allocated in `arena`.
    pub fn files(pf: *const ProposalFiles, arena: Allocator, p: *const Proposal) ![]const FileChange {
        var acc: Acc = .{ .pf = pf, .arena = arena };
        for (p.changes) |id| {
            const c = try op_mod.read(Change, pf.store, arena, id);
            const pred: ?Change = if (c.predecessors.len > 0) try op_mod.read(Change, pf.store, arena, c.predecessors[0]) else null;
            const old_desc: ?[]const u8 = if (pred) |x| x.description else null;
            if (p.kind == .describe or old_desc == null or !std.mem.eql(u8, old_desc.?, c.description)) {
                var buf: [32]u8 = undefined;
                const path = try std.mem.concat(arena, u8, &.{ description_prefix, c.change_id.reverseHex(&buf) });
                if (p.kind == .describe or pred != null) try acc.add(path, old_desc, c.description);
            }
            if (p.kind == .describe) continue;
            const before: ?Change = pred orelse if (c.parents.len > 0) try op_mod.read(Change, pf.store, arena, c.parents[0]) else null;
            const before_tree: ?ObjectId = if (before) |b| treeOf(b) else null;
            try acc.diff("", before_tree, treeOf(c));
        }
        return sorted(acc.list.items);
    }

    /// The paths that differ between trees `before` and `after` (null:
    /// empty), sorted, allocated in `arena`.
    pub fn diffTrees(pf: *const ProposalFiles, arena: Allocator, before: ?ObjectId, after: ?ObjectId) ![]const FileChange {
        var acc: Acc = .{ .pf = pf, .arena = arena };
        try acc.diff("", before, after);
        return sorted(acc.list.items);
    }

    /// The `PreviewFiles`-shaped callback for E12 (`ctx` is the
    /// `*ProposalFiles`).
    pub fn filesFn(ctx: *anyopaque, arena: Allocator, p: *const Proposal) anyerror![]const FileChange {
        const pf: *const ProposalFiles = @ptrCast(@alignCast(ctx));
        return pf.files(arena, p);
    }
};

fn sorted(out: []FileChange) []const FileChange {
    std.mem.sort(FileChange, out, {}, struct {
        fn lt(_: void, a: FileChange, b: FileChange) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lt);
    return out;
}

/// A conflicted commit shows its first term.
pub fn treeOf(c: Change) ?ObjectId {
    return if (c.tree_terms.len == 0) null else c.tree_terms[0];
}

const Acc = struct {
    pf: *const ProposalFiles,
    arena: Allocator,
    list: std.ArrayList(FileChange) = .empty,
    at: std.StringHashMapUnmanaged(usize) = .empty,

    fn add(acc: *Acc, path: []const u8, base: ?[]const u8, new: ?[]const u8) !void {
        if (acc.at.get(path)) |i| {
            acc.list.items[i].new = new;
            return;
        }
        try acc.at.put(acc.arena, path, acc.list.items.len);
        try acc.list.append(acc.arena, .{ .path = path, .base = base, .new = new });
    }

    fn tree(acc: *Acc, id: ?ObjectId) !Tree {
        const tid = id orelse return .{ .entries = &.{} };
        return op_mod.read(Tree, acc.pf.store, acc.arena, tid);
    }

    fn diff(acc: *Acc, prefix: []const u8, a_id: ?ObjectId, b_id: ?ObjectId) anyerror!void {
        if (a_id != null and b_id != null and a_id.?.eql(b_id.?)) return;
        const a = try acc.tree(a_id);
        const b = try acc.tree(b_id);
        var names: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (a.entries) |e| try names.put(acc.arena, e.name, {});
        for (b.entries) |e| try names.put(acc.arena, e.name, {});
        for (names.keys()) |name| {
            const x = a.find(name);
            const y = b.find(name);
            if (x != null and y != null and x.?.kind == y.?.kind and x.?.id.eql(y.?.id)) continue;
            const path = if (prefix.len == 0) name else try std.fmt.allocPrint(acc.arena, "{s}/{s}", .{ prefix, name });
            const xd = x != null and x.?.kind == .tree;
            const yd = y != null and y.?.kind == .tree;
            // A file replaced by a directory (or back) is a deleted or
            // added file plus the directory's contents.
            if (xd or yd) try acc.diff(path, if (xd) x.?.id else null, if (yd) y.?.id else null);
            const xf: ?TreeEntry = if (x != null and !xd) x else null;
            const yf: ?TreeEntry = if (y != null and !yd) y else null;
            if (xf == null and yf == null) continue;
            try acc.add(path, if (xf) |e| try acc.text(e) else null, if (yf) |e| try acc.text(e) else null);
        }
    }

    fn text(acc: *Acc, e: TreeEntry) ![]const u8 {
        var hex: [64]u8 = undefined;
        switch (e.kind) {
            .gitlink => return std.fmt.allocPrint(acc.arena, "Subproject commit {s}\n", .{e.id.hex(&hex)}),
            .tree => unreachable,
            else => {},
        }
        var buf: [16 << 10]u8 = undefined;
        var br = try chunker.blobReader(acc.pf.store, e.id, &buf);
        defer br.deinit();
        if (br.size > acc.pf.max_file_bytes) return std.fmt.allocPrint(acc.arena, "(file too large to show: {d} bytes)\n", .{br.size});
        const bytes = try br.interface.readAlloc(acc.arena, @intCast(br.size));
        if (e.kind != .symlink and std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, 8 << 10)], 0) != null)
            return std.fmt.allocPrint(acc.arena, "(binary file: {d} bytes)\n", .{bytes.len});
        return bytes;
    }
};

// ---------------------------------------------------------------- tests

const fx = @import("../oplog/test_fixture.zig");
const preview = @import("../oplog/preview.zig");
const rebase = @import("../oplog/rebase.zig");
const lt = @import("landing_test.zig");
const t = std.testing;

test "proposal files: describe, rewrite and new commits" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r0 = try f.initRepo();
    defer r0.close();
    var tx = try r0.startTransaction(fx.meta("setup"));
    var m = tx.mutRepo();
    const root = try lt.commit(m, &.{}, "root", &.{ .{ "a.txt", "one\n" }, .{ "keep", "k" } });
    const c1 = try lt.commit(m, &.{root}, "wip", &.{ .{ "a.txt", "two\n" }, .{ "keep", "k" }, .{ "bin", "x\x00y" } });
    try m.setWcCommit("default", c1);
    const r1 = try tx.commit();
    defer r1.close();
    var pf: ProposalFiles = .{ .store = f.store };

    // describe: only the description path.
    tx = try r1.startTransaction(fx.meta("describe"));
    m = tx.mutRepo();
    var ch = try m.readChange(tx.arena(), c1);
    ch.description = "Add two\n\nBecause.";
    const c2 = try m.rewriteChange(c1, ch);
    _ = try m.rebaseDescendants(rebase.reparent, null);
    const d = try preview.commitDetached(tx, .proposal);
    var p: Proposal = .{ .kind = .describe, .preview_op = d, .summary = "describe", .changes = &.{c2}, .provenance = .{ .actor = .{ .kind = .agent } } };
    var got = try pf.files(arena, &p);
    try t.expectEqual(@as(usize, 1), got.len);
    try t.expect(std.mem.startsWith(u8, got[0].path, description_prefix));
    try t.expectEqualStrings("wip", got[0].base.?);
    try t.expectEqualStrings("Add two\n\nBecause.", got[0].new.?);

    // A new commit (no predecessor) diffs against its parent: modified,
    // binary, and the description stays out.
    p.kind = .split;
    p.changes = &.{c1};
    got = try pf.files(arena, &p);
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("a.txt", got[0].path);
    try t.expectEqualStrings("one\n", got[0].base.?);
    try t.expectEqualStrings("two\n", got[0].new.?);
    try t.expectEqualStrings("bin", got[1].path);
    try t.expectEqual(@as(?[]const u8, null), got[1].base);
    try t.expectEqualStrings("(binary file: 3 bytes)\n", got[1].new.?);

    // A rewrite with new content diffs against its predecessor, with a
    // directory added and a file deleted; two commits touching a.txt
    // merge into one entry.
    tx = try r1.startTransaction(fx.meta("resolve"));
    m = tx.mutRepo();
    const c3 = try lt.commit(m, &.{root}, "wip", &.{ .{ "a.txt", "three\n" }, .{ "dir/x.zig", "x" } });
    ch = try m.readChange(tx.arena(), c3);
    ch.predecessors = &.{c1};
    const c3r = try m.rewriteChange(c1, ch);
    const c4 = try lt.commit(m, &.{c3r}, "more", &.{ .{ "a.txt", "four\n" }, .{ "dir/x.zig", "x" } });
    const d2 = try preview.commitDetached(tx, .proposal);
    p = .{ .kind = .resolve, .preview_op = d2, .summary = "resolve", .changes = &.{ c3r, c4 }, .provenance = .{ .actor = .{ .kind = .agent } } };
    got = try pf.files(arena, &p);
    var paths: std.ArrayList(u8) = .empty;
    for (got) |g| try paths.print(arena, "{s}:{s}>{s};", .{ g.path, g.base orelse "-", g.new orelse "-" });
    try t.expectEqualStrings("a.txt:two\n>four\n;bin:(binary file: 3 bytes)\n>-;dir/x.zig:->x;keep:k>-;", paths.items);
}
