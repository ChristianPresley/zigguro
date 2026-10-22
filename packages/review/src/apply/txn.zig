//! One all-or-nothing batch of file writes and deletes (E12.F02.S03.T02),
//! shared by the applier, undo accept and checkpoint restore.
//!
//! Every path is read once (`read`) before anything is written; those
//! preimages are what `run` reverts to, newest first, when an operation
//! fails. `saveImages` puts the pre and post contents in `Blobs` so that
//! the `History` record made from `records` can be reverted later.

const std = @import("std");
const model = @import("../model/root.zig");
const files_mod = @import("files.zig");

const Allocator = std.mem.Allocator;
const Files = files_mod.Files;
const Entry = files_mod.Entry;

pub const Op = struct {
    path: []const u8,
    /// Null deletes.
    new: ?[]const u8,
    /// Null keeps the mode (or the default for a new file).
    exec: ?bool = null,
    /// The write is the new side of a rename from this path.
    from: ?[]const u8 = null,
};

pub const Failure = struct {
    path: []const u8,
    err: anyerror,
    rolled_back: bool,
};

pub const Txn = struct {
    /// Holds the preimages and operations; outlives the transaction.
    arena: Allocator,
    files: Files,
    pre: std.StringArrayHashMapUnmanaged(?Entry) = .empty,
    ops: std.ArrayList(Op) = .empty,

    pub fn init(arena: Allocator, files: Files) Txn {
        return .{ .arena = arena, .files = files };
    }

    /// The content of `path` before the transaction (read once).
    pub fn read(t: *Txn, path: []const u8) !?Entry {
        const gop = try t.pre.getOrPut(t.arena, path);
        if (!gop.found_existing) gop.value_ptr.* = try t.files.read(t.arena, path);
        return gop.value_ptr.*;
    }

    /// Queues `op`; its path must have been `read`.
    pub fn add(t: *Txn, op: Op) Allocator.Error!void {
        std.debug.assert(t.pre.contains(op.path));
        try t.ops.append(t.arena, op);
    }

    /// Stores every preimage and new content in `blobs`.
    pub fn saveImages(t: *const Txn, blobs: model.Blobs) anyerror!void {
        for (t.pre.values()) |e| if (e) |x| {
            _ = try blobs.put(x.bytes);
        };
        for (t.ops.items) |op| if (op.new) |b| {
            _ = try blobs.put(b);
        };
    }

    /// Runs the operations in order; on a failure reverts the ones done
    /// and reports it.
    pub fn run(t: *const Txn) ?Failure {
        for (t.ops.items, 0..) |op, i| {
            const r = if (op.new) |b| t.files.write(op.path, b, op.exec) else t.files.delete(op.path);
            r catch |err| return .{ .path = op.path, .err = err, .rolled_back = t.revert(t.ops.items[0..i]) };
        }
        return null;
    }

    fn revert(t: *const Txn, done: []const Op) bool {
        var ok = true;
        var i = done.len;
        while (i > 0) {
            i -= 1;
            const path = done[i].path;
            const before = t.pre.get(path) orelse null;
            const r = if (before) |b| t.files.write(path, b.bytes, b.executable) else t.files.delete(path);
            r catch |e| {
                std.log.scoped(.zg_review).warn("rollback: {s} not restored: {t}", .{ path, e });
                ok = false;
            };
        }
        return ok;
    }

    /// The `History` files of the operations (allocated in the arena).
    pub fn records(t: *const Txn) Allocator.Error![]model.ApplyFile {
        const recs = try t.arena.alloc(model.ApplyFile, t.ops.items.len);
        for (t.ops.items, recs) |op, *r| {
            const before = t.pre.get(op.path) orelse null;
            const was_exec = if (before) |b| b.executable else false;
            r.* = .{
                .path = op.path,
                .from = op.from,
                .pre = if (before) |b| model.blobHash(b.bytes) else null,
                .post = if (op.new) |b| model.blobHash(b) else null,
                .pre_exec = was_exec,
                .post_exec = if (op.new != null) op.exec orelse was_exec else false,
            };
        }
        return recs;
    }
};

test "txn: a failing operation reverts the earlier ones" {
    const gpa = std.testing.allocator;
    var m: files_mod.MemFiles = .init(gpa);
    defer m.deinit();
    try m.put("a", "1", true);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var t: Txn = .init(arena.allocator(), m.files());
    _ = try t.read("a");
    _ = try t.read("b");
    try t.add(.{ .path = "a", .new = "2", .exec = false });
    try t.add(.{ .path = "b", .new = "3" });
    try t.add(.{ .path = "a", .new = null });
    m.fail_at = 2;
    const f = t.run().?;
    try std.testing.expect(f.rolled_back);
    try std.testing.expectEqualStrings("a", f.path);
    try std.testing.expectEqualStrings("1", m.get("a").?);
    try std.testing.expect(m.isExec("a"));
    try std.testing.expectEqual(@as(?[]const u8, null), m.get("b"));
    const recs = try t.records();
    try std.testing.expect(recs[0].pre_exec and !recs[0].post_exec);
    try std.testing.expectEqual(@as(?model.BlobHash, null), recs[1].pre);
}
