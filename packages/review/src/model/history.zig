//! What review did to the disk (E12.F02.S03.T02, E12.F04): one `Apply`
//! record per transaction, with each touched file's content hash before
//! and after. Undo accept and checkpoint restore start from these; the
//! contents themselves are in `Blobs`.
//!
//! A rename is recorded as two files: the new path created, the old one
//! deleted.
//!
//! Owner thread only, like the queue. The store journals each record
//! (`Recorder`) and replays it with `restore`.

const std = @import("std");
const ids = @import("ids.zig");

const Allocator = std.mem.Allocator;
const BlobHash = ids.BlobHash;
const ChangesetId = ids.ChangesetId;

pub const ApplyFile = struct {
    path: []const u8,
    /// Null: there was no file.
    pre: ?BlobHash,
    /// Null: the file was deleted.
    post: ?BlobHash,
    pre_exec: bool = false,
    post_exec: bool = false,
};

pub const ApplyKind = enum(u8) {
    /// Accepted hunks or files landed.
    apply,
    /// An earlier apply was reverted (`undoes`).
    undo,
    /// Files went back to a checkpoint.
    restore,
};

pub const Apply = struct {
    /// Unique and increasing in the workspace; assigned by `record`.
    id: u64 = 0,
    kind: ApplyKind = .apply,
    /// The changeset applied or undone; none for a restore.
    cs: ?ChangesetId,
    undoes: ?u64 = null,
    /// The agent session whose change this was.
    session: ?u128 = null,
    created_ms: i64,
    files: []const ApplyFile,
};

/// Journals new records.
pub const Recorder = struct {
    ctx: *anyopaque,
    apply: *const fn (ctx: *anyopaque, a: *const Apply) void,
};

pub const History = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    applies: std.ArrayList(Apply) = .empty,
    recorder: ?Recorder = null,
    next_id: u64 = 1,

    pub fn init(gpa: Allocator, recorder: ?Recorder) History {
        return .{ .gpa = gpa, .arena = .init(gpa), .recorder = recorder };
    }

    pub fn deinit(h: *History) void {
        h.applies.deinit(h.gpa);
        h.arena.deinit();
        h.* = undefined;
    }

    /// Copies `a` in under a new id, journals it and returns the id.
    pub fn record(h: *History, a: Apply) Allocator.Error!u64 {
        var c = try h.copy(a);
        c.id = h.next_id;
        try h.applies.append(h.gpa, c);
        h.next_id += 1;
        if (h.recorder) |r| r.apply(r.ctx, &h.applies.items[h.applies.items.len - 1]);
        return c.id;
    }

    /// Takes `a` from the store (load or another process). Not journaled;
    /// a record with a known id is ignored.
    pub fn restore(h: *History, a: Apply) Allocator.Error!void {
        if (h.get(a.id) != null) return;
        const c = try h.copy(a);
        // Keep id order: other processes' records can arrive late.
        var i = h.applies.items.len;
        while (i > 0 and h.applies.items[i - 1].id > c.id) i -= 1;
        try h.applies.insert(h.gpa, i, c);
        h.next_id = @max(h.next_id, c.id + 1);
    }

    pub fn get(h: *const History, id: u64) ?*const Apply {
        for (h.applies.items) |*a| if (a.id == id) return a;
        return null;
    }

    /// Every record, oldest first.
    pub fn items(h: *const History) []const Apply {
        return h.applies.items;
    }

    /// The newest apply of `cs` that no later record undid.
    pub fn lastApplyOf(h: *const History, cs: ChangesetId) ?*const Apply {
        var i = h.applies.items.len;
        while (i > 0) {
            i -= 1;
            const a = &h.applies.items[i];
            if (a.kind != .apply or a.cs != cs) continue;
            if (!h.undone(a.id)) return a;
        }
        return null;
    }

    /// Whether a record undoes `id`.
    pub fn undone(h: *const History, id: u64) bool {
        for (h.applies.items) |a| if (a.kind == .undo and a.undoes == id) return true;
        return false;
    }

    fn copy(h: *History, a: Apply) Allocator.Error!Apply {
        const ar = h.arena.allocator();
        const files = try ar.alloc(ApplyFile, a.files.len);
        for (a.files, files) |f, *o| {
            o.* = f;
            o.path = try ar.dupe(u8, f.path);
        }
        var c = a;
        c.files = files;
        return c;
    }
};

const testing = std.testing;

test "history: ids increase, restore keeps order, undo hides an apply" {
    const Rec = struct {
        n: u32 = 0,
        fn on(ctx: *anyopaque, _: *const Apply) void {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            r.n += 1;
        }
    };
    var rec: Rec = .{};
    var h: History = .init(testing.allocator, .{ .ctx = &rec, .apply = Rec.on });
    defer h.deinit();
    const cs: ChangesetId = @enumFromInt(3);
    var path = "a.txt".*;
    const f = [_]ApplyFile{.{ .path = &path, .pre = null, .post = ids.blobHash("x") }};
    const a1 = try h.record(.{ .cs = cs, .created_ms = 1, .files = &f });
    path[0] = 'b';
    try testing.expectEqualStrings("a.txt", h.get(a1).?.files[0].path);
    try h.restore(.{ .id = 7, .cs = cs, .created_ms = 2, .files = &f });
    try h.restore(.{ .id = 5, .cs = null, .kind = .restore, .created_ms = 2, .files = &.{} });
    try h.restore(.{ .id = 5, .cs = null, .kind = .restore, .created_ms = 2, .files = &.{} });
    try testing.expectEqual(@as(usize, 3), h.items().len);
    try testing.expectEqual(@as(u64, 5), h.items()[1].id);
    try testing.expectEqual(@as(u32, 1), rec.n);
    try testing.expectEqual(@as(u64, 7), h.lastApplyOf(cs).?.id);
    const u = try h.record(.{ .kind = .undo, .cs = cs, .undoes = 7, .created_ms = 3, .files = &.{} });
    try testing.expectEqual(@as(u64, 8), u);
    try testing.expectEqual(a1, h.lastApplyOf(cs).?.id);
}
