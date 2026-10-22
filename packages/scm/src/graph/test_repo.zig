//! Test helper: a scratch store plus commit index, and a random DAG
//! generator writing change objects into it.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const enc = @import("../store/encode.zig");
const store_mod = @import("../store/store.zig");
const index = @import("index.zig");
const ObjectId = id_mod.ObjectId;
const ChangeId = id_mod.ChangeId;
const Store = store_mod.Store;
const Allocator = std.mem.Allocator;

pub const Repo = struct {
    gpa: Allocator,
    io: std.Io,
    tmp: std.testing.TmpDir,
    store: *Store,
    ix_dir: std.Io.Dir,
    batch: ?store_mod.WriteBatch = null,

    pub fn init(gpa: Allocator) !*Repo {
        const io = std.testing.io;
        const r = try gpa.create(Repo);
        errdefer gpa.destroy(r);
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const store = try Store.open(gpa, io, tmp.dir, .{ .fsync = false, .rescan_interval_ms = 0 });
        errdefer store.close();
        const ix_dir = try tmp.dir.createDirPathOpen(io, "index", .{ .open_options = .{ .iterate = true } });
        r.* = .{ .gpa = gpa, .io = io, .tmp = tmp, .store = store, .ix_dir = ix_dir };
        return r;
    }

    pub fn deinit(r: *Repo) void {
        if (r.batch) |*b| b.abort();
        r.ix_dir.close(r.io);
        r.store.close();
        r.tmp.cleanup();
        r.gpa.destroy(r);
    }

    /// Opens a commit index in `sub` (another directory than the default
    /// one gives an independent index over the same store).
    pub fn openIndex(r: *Repo, sub: ?[]const u8) !*index.CommitIndex {
        const dir = if (sub) |s| try r.tmp.dir.createDirPathOpen(r.io, s, .{ .open_options = .{ .iterate = true } }) else r.ix_dir;
        return index.CommitIndex.open(r.gpa, r.io, dir, r.store, .{ .fsync = false });
    }

    pub const Commit = struct {
        parents: []const ObjectId = &.{},
        preds: []const ObjectId = &.{},
        change_id: ?ChangeId = null,
        time_ms: i64 = 0,
        tree_terms: ?[]const ObjectId = null,
        provenance: ?ObjectId = null,
        signed: bool = false,
        description: []const u8 = "",
    };

    /// Writes a change object (buffered until `flush`).
    pub fn commit(r: *Repo, c: Commit) !ObjectId {
        if (r.batch == null) r.batch = r.store.batch();
        const default_tree = [1]ObjectId{try enc.idOf(r.gpa, object.Tree, .{ .entries = &.{} })};
        const sig: object.Signature = .{ .name = "t", .email = "t@example.com", .time_ms = c.time_ms, .tz_offset_min = 0 };
        var cid = c.change_id orelse undefined;
        if (c.change_id == null) {
            var h = std.hash.Wyhash.init(0x5eed);
            h.update(c.description);
            for (c.parents) |p| h.update(&p.bytes);
            h.update(std.mem.asBytes(&c.time_ms));
            const a = h.final();
            std.mem.writeInt(u64, cid.bytes[0..8], a, .little);
            std.mem.writeInt(u64, cid.bytes[8..16], std.hash.int(a), .little);
        }
        const ch: object.Change = .{
            .parents = c.parents,
            .tree_terms = c.tree_terms orelse &default_tree,
            .change_id = cid,
            .predecessors = c.preds,
            .author = sig,
            .committer = sig,
            .description = c.description,
            .provenance = c.provenance,
            .extra = &.{},
            .sig = if (c.signed) .{ .format = "test", .data = "sig" } else null,
        };
        const bytes = try enc.encodeAlloc(r.gpa, object.Change, ch);
        defer r.gpa.free(bytes);
        return r.batch.?.put(.change, bytes);
    }

    /// Publishes buffered commits.
    pub fn flush(r: *Repo) !void {
        if (r.batch) |*b| {
            try b.commit();
            r.batch = null;
        }
    }
};

/// A random DAG of `n` commits in topological order: each picks 0 to 3
/// parents among recent commits; times mostly rise, with some clock skew.
pub fn randomDag(r: *Repo, rng: std.Random, n: usize) ![]ObjectId {
    const ids = try r.gpa.alloc(ObjectId, n);
    errdefer r.gpa.free(ids);
    const parents = try r.gpa.alloc(ObjectId, 3);
    defer r.gpa.free(parents);
    var time: i64 = 1_700_000_000_000;
    for (ids, 0..) |*id, i| {
        var np: usize = if (i == 0) 0 else switch (rng.uintLessThan(u8, 20)) {
            0 => 0,
            1...14 => 1,
            15...18 => 2,
            else => 3,
        };
        var k: usize = 0;
        while (k < np) {
            const back = 1 + @min(i - 1, rng.uintLessThan(usize, if (rng.boolean()) 4 else 200));
            const cand = ids[i - back];
            for (parents[0..k]) |p| {
                if (p.eql(cand)) break;
            } else {
                parents[k] = cand;
                k += 1;
                continue;
            }
            np -= 1;
        }
        time += rng.intRangeAtMost(i64, -5000, 60_000);
        var desc: [16]u8 = undefined;
        id.* = try r.commit(.{ .parents = parents[0..k], .time_ms = time, .description = std.fmt.bufPrint(&desc, "c{d}", .{i}) catch unreachable });
    }
    try r.flush();
    return ids;
}
