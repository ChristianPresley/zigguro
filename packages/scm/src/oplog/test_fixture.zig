//! Test helper for the op log: a scratch directory holding a store and an
//! op log, plus shortcuts for operation metadata and changes.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const enc = @import("../store/encode.zig");
const store_mod = @import("../store/store.zig");
const op_mod = @import("operation.zig");
const view_mod = @import("view.zig");
const repo_mod = @import("repo.zig");
const mutable_mod = @import("mutable_repo.zig");
const ObjectId = id_mod.ObjectId;
const ChangeId = id_mod.ChangeId;
const Store = store_mod.Store;
const Repo = repo_mod.Repo;
const Allocator = std.mem.Allocator;

pub const store_options: store_mod.Options = .{ .fsync = false, .rescan_interval_ms = 0 };

pub const Fixture = struct {
    gpa: Allocator,
    io: std.Io,
    tmp: std.testing.TmpDir,
    store: *Store,

    pub fn init(gpa: Allocator) !Fixture {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const store = try Store.open(gpa, io, tmp.dir, store_options);
        return .{ .gpa = gpa, .io = io, .tmp = tmp, .store = store };
    }

    pub fn deinit(f: *Fixture) void {
        f.store.close();
        f.tmp.cleanup();
    }

    /// Creates the op log and returns the repo at its root operation.
    pub fn initRepo(f: *Fixture) !*Repo {
        return Repo.init(f.gpa, f.io, f.tmp.dir, f.store, .{}, meta("init"));
    }

    pub fn load(f: *Fixture, at: repo_mod.AtOp) !*Repo {
        return Repo.load(f.gpa, f.io, f.tmp.dir, f.store, .{}, at);
    }
};

pub fn meta(description: []const u8) op_mod.OpMeta {
    return .{
        .start_ms = 0,
        .end_ms = 0,
        .description = description,
        .user = "tester",
        .host = "host",
        .workspace = "default",
        .actor = .human,
        .tags = &.{},
    };
}

/// Writes a change named `description` on `parents`.
pub fn change(m: *mutable_mod.MutableRepo, parents: []const ObjectId, description: []const u8) !ObjectId {
    const empty_tree = [1]ObjectId{try enc.idOf(m.gpa, object.Tree, .{ .entries = &.{} })};
    const sig: object.Signature = .{ .name = "t", .email = "t@example.com", .time_ms = 1_700_000_000_000, .tz_offset_min = 0 };
    var cid: ChangeId = undefined;
    const h = std.hash.Wyhash.hash(7, description);
    std.mem.writeInt(u64, cid.bytes[0..8], h, .little);
    std.mem.writeInt(u64, cid.bytes[8..16], std.hash.int(h), .little);
    return m.writeChange(.{
        .parents = parents,
        .tree_terms = &empty_tree,
        .change_id = cid,
        .predecessors = &.{},
        .author = sig,
        .committer = sig,
        .description = description,
        .provenance = null,
        .extra = &.{},
        .sig = null,
    });
}

/// A normal ref target (the ID is copied by the `MutableRepo` setters).
pub fn target(id: *const ?ObjectId) view_mod.RefTarget {
    return .normal(id);
}
