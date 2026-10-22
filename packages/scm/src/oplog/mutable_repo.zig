//! The editable repository inside a transaction: new changes go into a
//! store write batch, and the view is edited in a `ViewBuilder`.
//! Rewriting a change hides the old commit (it leaves the heads) and
//! records the old → new mapping, so the F04 rewrite engine can rebase
//! descendants before the transaction commits.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const enc = @import("../store/encode.zig");
const store_mod = @import("../store/store.zig");
const view_mod = @import("view.zig");
const ObjectId = id_mod.ObjectId;
const Change = object.Change;
const RefTarget = view_mod.RefTarget;
const Allocator = std.mem.Allocator;

pub const MutableRepo = struct {
    gpa: Allocator,
    /// Owns strings and slices put into the view.
    arena: Allocator,
    batch: *store_mod.WriteBatch,
    view: view_mod.ViewBuilder,
    /// Old commit → its replacement, for rewritten changes.
    rewritten: std.AutoArrayHashMapUnmanaged(ObjectId, ObjectId) = .empty,
    /// Commits abandoned in this transaction.
    abandoned: std.AutoArrayHashMapUnmanaged(ObjectId, void) = .empty,

    pub fn deinit(m: *MutableRepo) void {
        m.view.deinit();
        m.rewritten.deinit(m.gpa);
        m.abandoned.deinit(m.gpa);
    }

    /// Stores `c` and makes it a head in place of its parents.
    pub fn writeChange(m: *MutableRepo, c: Change) !ObjectId {
        const bytes = try enc.encodeAlloc(m.gpa, Change, c);
        defer m.gpa.free(bytes);
        const id = try m.batch.put(.change, bytes);
        for (c.parents) |p| _ = m.view.heads.swapRemove(p);
        try m.view.heads.put(m.gpa, id, {});
        return id;
    }

    /// Stores `new` as the rewrite of `old`: `old` is added to `new`'s
    /// predecessors when missing, leaves the heads, and maps to the new
    /// commit in `rewritten`.
    pub fn rewriteChange(m: *MutableRepo, old: ObjectId, new: Change) !ObjectId {
        var c = new;
        for (c.predecessors) |p| {
            if (p.eql(old)) break;
        } else {
            const preds = try m.arena.alloc(ObjectId, c.predecessors.len + 1);
            @memcpy(preds[0..c.predecessors.len], c.predecessors);
            preds[c.predecessors.len] = old;
            c.predecessors = preds;
        }
        _ = m.view.heads.swapRemove(old);
        const id = try m.writeChange(c);
        try m.rewritten.put(m.gpa, old, id);
        return id;
    }

    /// Hides `id`: it leaves the heads and its parents take its place.
    /// Descendants are rebased by the rewrite engine (F04).
    pub fn abandon(m: *MutableRepo, id: ObjectId, parents: []const ObjectId) !void {
        if (m.view.heads.swapRemove(id)) {
            for (parents) |p| try m.view.heads.put(m.gpa, p, {});
        }
        try m.abandoned.put(m.gpa, id, {});
    }

    /// Makes `id` visible (for example a commit imported from git).
    pub fn addHead(m: *MutableRepo, id: ObjectId) !void {
        try m.view.heads.put(m.gpa, id, {});
    }

    pub fn removeHead(m: *MutableRepo, id: ObjectId) void {
        _ = m.view.heads.swapRemove(id);
    }

    /// Sets bookmark `name`; an absent target deletes it. The target's
    /// terms must outlive the transaction (copy them into `arena`).
    pub fn setBookmark(m: *MutableRepo, name: []const u8, t: RefTarget) !void {
        try m.view.setNamed(&m.view.bookmarks, try m.arena.dupe(u8, name), try m.own(t));
    }

    pub fn setTag(m: *MutableRepo, name: []const u8, t: RefTarget) !void {
        try m.view.setNamed(&m.view.tags, try m.arena.dupe(u8, name), try m.own(t));
    }

    pub fn setGitRef(m: *MutableRepo, name: []const u8, t: RefTarget) !void {
        try m.view.setNamed(&m.view.git_refs, try m.arena.dupe(u8, name), try m.own(t));
    }

    pub fn setGitHead(m: *MutableRepo, t: RefTarget) !void {
        m.view.git_head = try m.own(t);
    }

    pub fn setRemoteBookmark(m: *MutableRepo, remote: []const u8, name: []const u8, t: RefTarget, tracked: bool) !void {
        try m.view.putRemote(.{ .remote = try m.arena.dupe(u8, remote), .name = try m.arena.dupe(u8, name), .target = try m.own(t), .tracked = tracked });
    }

    /// Sets the working-copy commit of `workspace`, or forgets the
    /// workspace with null.
    pub fn setWcCommit(m: *MutableRepo, workspace: []const u8, id: ?ObjectId) !void {
        if (id) |c| {
            try m.view.wc_commits.put(m.gpa, try m.arena.dupe(u8, workspace), c);
        } else _ = m.view.wc_commits.orderedRemove(workspace);
    }

    /// Adds or replaces a lane record (its strings must outlive the
    /// transaction).
    pub fn setLane(m: *MutableRepo, rec: view_mod.LaneRecord) !void {
        try m.view.lanes.put(m.gpa, try m.arena.dupe(u8, rec.name), rec);
    }

    pub fn removeLane(m: *MutableRepo, name: []const u8) void {
        _ = m.view.lanes.orderedRemove(name);
    }

    fn own(m: *MutableRepo, t: RefTarget) !RefTarget {
        return .{ .terms = try m.arena.dupe(?ObjectId, t.terms) };
    }
};
