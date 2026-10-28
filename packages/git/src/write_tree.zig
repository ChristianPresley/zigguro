//! `git write-tree` (E09.F07.S03.T01): the index's merged entries as
//! tree objects, written to the object database. Intent-to-add entries
//! are left out; conflict stages fail with `error.UnmergedEntries`.

const std = @import("std");
const tree_mod = @import("tree.zig");
const index_mod = @import("index/index.zig");
const Repository = @import("repository.zig").Repository;
const Oid = @import("oid.zig").Oid;
const Index = index_mod.Index;
const Allocator = std.mem.Allocator;

/// Writes the trees of `ix` and returns the root tree's id.
pub fn writeTree(repo: *Repository, ix: *const Index) !Oid {
    for (ix.entries.items) |e| if (e.flags.stage != 0) return error.UnmergedEntries;
    var arena: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena.deinit();
    var files: std.ArrayList(index_mod.Entry) = .empty;
    for (ix.entries.items) |e| if (!e.flags.intent_to_add) try files.append(arena.allocator(), e);
    return writeLevel(repo, arena.allocator(), files.items, 0);
}

/// The tree of `entries`, which all share their first `prefix` bytes
/// (a directory path plus '/').
fn writeLevel(repo: *Repository, a: Allocator, entries: []const index_mod.Entry, prefix: usize) !Oid {
    var out: std.ArrayList(tree_mod.TreeEntry) = .empty;
    var i: usize = 0;
    while (i < entries.len) {
        const rest = entries[i].path[prefix..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const name = rest[0..slash];
            // Every entry under this directory.
            var j = i + 1;
            while (j < entries.len) : (j += 1) {
                const r = entries[j].path[prefix..];
                if (!(r.len > slash and std.mem.eql(u8, r[0..slash], name) and r[slash] == '/')) break;
            }
            const sub = try writeLevel(repo, a, entries[i..j], prefix + slash + 1);
            try out.append(a, .{ .mode = tree_mod.mode_tree, .name = name, .oid = sub });
            i = j;
        } else {
            try out.append(a, .{ .mode = entries[i].mode, .name = rest, .oid = entries[i].oid });
            i += 1;
        }
    }
    tree_mod.sortEntries(out.items);
    var aw: std.Io.Writer.Allocating = .init(a);
    try tree_mod.serializeTree(out.items, &aw.writer);
    return repo.odb.writeLoose(.tree, aw.written());
}

const testing = std.testing;
const stage = @import("stage.zig");
const status_mod = @import("status.zig");

test "write-tree: nested directories round-trip through the tree reader" {
    const gpa = testing.allocator;
    const io = testing.io;
    const t = try stage.TestRepo.init(gpa, io);
    defer t.deinit(gpa);
    const d = t.tmp.dir;
    try d.createDirPath(io, "a/b");
    try d.createDirPath(io, "a-b");
    try d.writeFile(io, .{ .sub_path = "a/b/c.txt", .data = "c\n" });
    try d.writeFile(io, .{ .sub_path = "a/x.txt", .data = "x\n" });
    try d.writeFile(io, .{ .sub_path = "a-b/y.txt", .data = "y\n" });
    try d.writeFile(io, .{ .sub_path = "a.txt", .data = "a\n" });
    _ = try stage.add(t.repo, &.{}, .{});
    var ix = try t.repo.readIndex();
    defer ix.deinit();
    const root = try writeTree(t.repo, &ix);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const files = try status_mod.flattenTree(t.repo, arena.allocator(), root);
    try testing.expectEqual(@as(usize, 4), files.len);
    for (files, ix.entries.items) |f, e| {
        try testing.expectEqualStrings(e.path, f.path);
        try testing.expect(f.oid.eql(e.oid));
    }
    // git's id for this tree (git 2.43, same files).
    var hb: [64]u8 = undefined;
    try testing.expectEqualStrings("3f8d4f91a4c619bbcc90e10b12d7e01826c6f67a", root.hex(&hb));
}
