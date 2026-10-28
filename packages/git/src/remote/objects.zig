//! What to send: the objects reachable from new tips that the other
//! side cannot have, given the tips it has (E09.F08 push and the pack
//! for a local fetch). Trees and blobs of the boundary commits (parents
//! of sent commits that are not sent) are left out and offered as thin
//! bases.

const std = @import("std");
const revwalk = @import("../revwalk.zig");
const commit_mod = @import("../commit.zig");
const tree_mod = @import("../tree.zig");
const tag_mod = @import("../tag.zig");
const Repository = @import("../repository.zig").Repository;
const Oid = @import("../oid.zig").Oid;
const Allocator = std.mem.Allocator;

pub const Item = struct { id: Oid, path: []const u8 };

pub const Plan = struct {
    send: []const Item,
    /// Objects the receiver has that deltas may use.
    thin_bases: []const Oid,
};

/// Plans the objects for `tips` (commits or tags) against `haves` (the
/// receiver's tips; ones missing locally are ignored).
pub fn plan(repo: *Repository, a: Allocator, tips: []const Oid, haves: []const Oid) !Plan {
    var present: std.ArrayList(Oid) = .empty;
    for (haves) |h| if (repo.odb.exists(h)) try present.append(a, try peelToCommit(repo, a, h) orelse continue);
    var send: std.ArrayList(Item) = .empty;
    var seen: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    var commits: std.ArrayList(Oid) = .empty;
    for (tips) |t0| {
        var t = t0;
        // Annotated tags travel themselves, then what they point at.
        while (true) {
            const obj = try repo.odb.read(a, t);
            if (obj.type != .tag) break;
            if (!(try seen.getOrPut(a, t)).found_existing) try send.append(a, .{ .id = t, .path = "" });
            t = (try tag_mod.parseTag(a, repo.format, obj.data)).object;
        }
        const hdr = try repo.odb.readHeader(t);
        switch (hdr.type) {
            .commit => try commits.append(a, t),
            .tree => try walkTree(repo, a, t, "", &seen, &send),
            else => if (!(try seen.getOrPut(a, t)).found_existing) try send.append(a, .{ .id = t, .path = "" }),
        }
    }
    const list = try revwalk.log(repo, a, commits.items, present.items, 0);
    var in_list: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    for (list) |c| try in_list.put(a, c, {});
    // Boundary: everything their trees hold is on the other side.
    var bases: std.ArrayList(Oid) = .empty;
    var excluded: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    for (list) |c| {
        const cc = try readCommit(repo, a, c);
        for (cc.parents) |p| {
            if (in_list.contains(p) or excluded.contains(p)) continue;
            try excluded.put(a, p, {});
            const pt = (try readCommit(repo, a, p)).tree;
            try markTree(repo, a, pt, &seen, &bases);
        }
    }
    for (list) |c| {
        if ((try seen.getOrPut(a, c)).found_existing) continue;
        try send.append(a, .{ .id = c, .path = "" });
        try walkTree(repo, a, (try readCommit(repo, a, c)).tree, "", &seen, &send);
    }
    return .{ .send = send.items, .thin_bases = bases.items };
}

fn readCommit(repo: *Repository, a: Allocator, id: Oid) !commit_mod.Commit {
    const obj = try repo.odb.read(a, id);
    return commit_mod.parseCommit(a, repo.format, obj.data);
}

fn peelToCommit(repo: *Repository, a: Allocator, id0: Oid) !?Oid {
    var id = id0;
    while (true) {
        const obj = try repo.odb.read(a, id);
        switch (obj.type) {
            .commit => return id,
            .tag => id = (try tag_mod.parseTag(a, repo.format, obj.data)).object,
            else => return null,
        }
    }
}

fn walkTree(repo: *Repository, a: Allocator, id: Oid, prefix: []const u8, seen: *std.AutoHashMapUnmanaged(Oid, void), out: *std.ArrayList(Item)) !void {
    if ((try seen.getOrPut(a, id)).found_existing) return;
    try out.append(a, .{ .id = id, .path = prefix });
    const obj = try repo.odb.read(a, id);
    var it: tree_mod.TreeIterator = .{ .data = obj.data, .format = repo.format };
    while (try it.next()) |e| {
        if (e.mode == tree_mod.mode_gitlink) continue;
        const path = if (prefix.len == 0) e.name else try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, e.name });
        if (e.mode == tree_mod.mode_tree) {
            try walkTree(repo, a, e.oid, path, seen, out);
        } else if (!(try seen.getOrPut(a, e.oid)).found_existing) try out.append(a, .{ .id = e.oid, .path = path });
    }
}

/// Marks a tree the receiver has: its objects are not sent, and become
/// thin-pack bases.
fn markTree(repo: *Repository, a: Allocator, id: Oid, seen: *std.AutoHashMapUnmanaged(Oid, void), bases: *std.ArrayList(Oid)) !void {
    if ((try seen.getOrPut(a, id)).found_existing) return;
    try bases.append(a, id);
    const obj = try repo.odb.read(a, id);
    var it: tree_mod.TreeIterator = .{ .data = obj.data, .format = repo.format };
    while (try it.next()) |e| {
        if (e.mode == tree_mod.mode_gitlink) continue;
        if (e.mode == tree_mod.mode_tree) {
            try markTree(repo, a, e.oid, seen, bases);
        } else if (!(try seen.getOrPut(a, e.oid)).found_existing) try bases.append(a, e.oid);
    }
}
