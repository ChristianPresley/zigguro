//! Reverting files to earlier contents while keeping later edits
//! (E12.F02.S03.T02 undo accept, E12.F04.S01.T02 restore).
//!
//! A target is one file and the steps to undo, oldest first: each names
//! the content before (`pre`) and after (`post`) one apply. Starting from
//! the current content, the steps are undone newest first, in memory:
//! - the content is already `pre`: nothing to undo (the executable bit
//!   still follows);
//! - the content is `post`: it becomes `pre` (no file if `pre` is none);
//! - the file was created (`pre` none) and edited since, deleted (`post`
//!   none) and recreated since, or deleted by the user: a conflict;
//! - otherwise `merge3(base = post, ours = content, theirs = pre)`: a
//!   clean merge goes on, an overlapping one is a conflict.
//! A file with a conflict is left as it is. Others get one write (or
//! delete) when the result differs from what is there. Because each step
//! is undone against its own pre and post, edits the user made between
//! two applies, on other lines, survive too.

const std = @import("std");
const model = @import("../model/root.zig");
const txn_mod = @import("txn.zig");

const Allocator = std.mem.Allocator;
const BlobHash = model.BlobHash;
const Txn = txn_mod.Txn;

pub const Step = struct {
    pre: ?BlobHash,
    pre_exec: bool = false,
    post: ?BlobHash,
    post_exec: bool = false,
};

pub const Target = struct {
    path: []const u8,
    /// Oldest first.
    steps: []const Step,
};

pub const ConflictKind = enum {
    /// The user changed the same lines (or edited a file the change created).
    user_edit_overlaps,
    /// The user deleted a file the change modified.
    file_deleted_by_user,
    /// A file is now where the change had deleted one.
    target_exists,
};

pub const Conflict = struct {
    path: []const u8,
    kind: ConflictKind,
    /// Overlapping regions (merge conflicts only).
    regions: u32 = 0,
};

pub const Plan = struct {
    /// Files that get an operation.
    reverted: []const []const u8,
    conflicts: []const Conflict,
};

/// Reads every target into `t` and queues the operations that revert
/// them; conflicted files get none. Allocates in `t.arena`.
pub fn plan(gpa: Allocator, blobs: model.Blobs, t: *Txn, targets: []const Target) !Plan {
    const arena = t.arena;
    var reverted: std.ArrayList([]const u8) = .empty;
    var conflicts: std.ArrayList(Conflict) = .empty;
    for (targets) |tg| {
        const cur = try t.read(tg.path);
        var bytes: ?[]const u8 = if (cur) |c| c.bytes else null;
        var exec = if (cur) |c| c.executable else false;
        var conflict: ?Conflict = null;
        var i = tg.steps.len;
        while (i > 0 and conflict == null) {
            i -= 1;
            const st = tg.steps[i];
            const h: ?BlobHash = if (bytes) |x| model.blobHash(x) else null;
            if (eql(h, st.pre)) {
                if (bytes != null and exec == st.post_exec) exec = st.pre_exec;
                continue;
            }
            const kind: ?ConflictKind = if (st.pre == null)
                (if (eql(h, st.post)) null else .user_edit_overlaps)
            else if (st.post == null)
                (if (bytes == null) null else .target_exists)
            else if (bytes == null) .file_deleted_by_user else null;
            if (kind) |k| {
                conflict = .{ .path = tg.path, .kind = k };
                break;
            }
            const pre_bytes: ?[]const u8 = if (st.pre) |x| try blobs.get(arena, x) orelse return error.MissingBlob else null;
            if (st.post == null or eql(h, st.post)) {
                bytes = pre_bytes;
                exec = st.pre_exec;
                continue;
            }
            const post_bytes = try blobs.get(arena, st.post.?) orelse return error.MissingBlob;
            var m = try model.merge3.merge(gpa, post_bytes, bytes.?, pre_bytes.?, .{});
            defer m.deinit(gpa);
            if (m.conflicts.len > 0) {
                conflict = .{ .path = tg.path, .kind = .user_edit_overlaps, .regions = @intCast(m.conflicts.len) };
                break;
            }
            bytes = try arena.dupe(u8, m.text);
            if (exec == st.post_exec) exec = st.pre_exec;
        }
        if (conflict) |c| {
            try conflicts.append(arena, c);
            continue;
        }
        const same = if (cur) |c| (bytes != null and std.mem.eql(u8, c.bytes, bytes.?) and c.executable == exec) else bytes == null;
        if (same) continue;
        try t.add(.{ .path = tg.path, .new = bytes, .exec = if (bytes != null) exec else null });
        try reverted.append(arena, tg.path);
    }
    return .{ .reverted = reverted.items, .conflicts = conflicts.items };
}

fn eql(a: ?BlobHash, b: ?BlobHash) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, &a.?, &b.?);
}

const testing = std.testing;

test "revert: each case" {
    const gpa = testing.allocator;
    const files_mod = @import("files.zig");
    var disk: files_mod.MemFiles = .init(gpa);
    defer disk.deinit();
    var mem: model.MemBlobs = .init(gpa);
    defer mem.deinit();
    const b = mem.blobs();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const H = model.blobHash;
    _ = try b.put("pre\n");
    _ = try b.put("a\nB\nc\n");
    _ = try b.put("a\nb\nc\n");
    try disk.put("same", "pre\n", false); // already reverted
    try disk.put("clean", "post\n", false); // untouched since
    try disk.put("merge", "a\nB\nC\n", false); // later edit elsewhere
    try disk.put("clash", "a\nX\nc\n", false); // later edit on the line
    try disk.put("made", "post\n", false); // created, unchanged
    try disk.put("made2", "edited\n", false); // created, then edited
    // "gone": deleted by the change, still gone.
    var t: Txn = .init(arena.allocator(), disk.files());
    const p = try plan(gpa, b, &t, &.{
        .{ .path = "same", .steps = &.{.{ .pre = H("pre\n"), .post = H("post\n") }} },
        .{ .path = "clean", .steps = &.{.{ .pre = H("pre\n"), .post = H("post\n"), .pre_exec = true }} },
        .{ .path = "merge", .steps = &.{.{ .pre = H("a\nb\nc\n"), .post = H("a\nB\nc\n") }} },
        .{ .path = "clash", .steps = &.{.{ .pre = H("a\nb\nc\n"), .post = H("a\nB\nc\n") }} },
        .{ .path = "made", .steps = &.{.{ .pre = null, .post = H("post\n") }} },
        .{ .path = "made2", .steps = &.{.{ .pre = null, .post = H("post\n") }} },
        .{ .path = "gone", .steps = &.{.{ .pre = H("pre\n"), .post = null }} },
        .{ .path = "lost", .steps = &.{.{ .pre = H("pre\n"), .post = H("post\n") }} },
    });
    try testing.expectEqual(@as(usize, 4), p.reverted.len);
    try testing.expectEqual(@as(usize, 3), p.conflicts.len);
    try testing.expectEqual(ConflictKind.user_edit_overlaps, p.conflicts[0].kind);
    try testing.expectEqual(@as(u32, 1), p.conflicts[0].regions);
    try testing.expectEqual(ConflictKind.file_deleted_by_user, p.conflicts[2].kind);
    try testing.expectEqual(@as(?txn_mod.Failure, null), t.run());
    try testing.expectEqualStrings("pre\n", disk.get("clean").?);
    try testing.expect(disk.isExec("clean"));
    try testing.expectEqualStrings("a\nb\nC\n", disk.get("merge").?);
    try testing.expectEqualStrings("a\nX\nc\n", disk.get("clash").?);
    try testing.expectEqual(@as(?[]const u8, null), disk.get("made"));
    try testing.expectEqualStrings("edited\n", disk.get("made2").?);
    try testing.expectEqualStrings("pre\n", disk.get("gone").?);
}
