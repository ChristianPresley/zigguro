//! Tests for pending agent changes: per-hunk accept/reject and rebasing
//! through user edits.

const std = @import("std");
const store_mod = @import("store.zig");
const pending_mod = @import("pending.zig");
const pt = @import("../buffer/piece_tree.zig");
const ChangeSet = @import("../edit/change_set.zig").ChangeSet;
const document = @import("../document.zig");

const testing = std.testing;
const Document = document.Document;
const DecorationStore = store_mod.DecorationStore;
const PendingChange = pending_mod.PendingChange;

const Fixture = struct {
    doc: *Document,
    store: DecorationStore,
    p: ?*PendingChange = null,
    owner: store_mod.OwnerId = undefined,

    fn init(f: *Fixture, text: []const u8) !void {
        f.p = null;
        f.doc = try Document.initBytes(testing.allocator, @enumFromInt(1), text);
        f.store = .init(testing.allocator, f.doc);
        _ = try f.doc.subscribe(f.store.listener());
        _ = try f.doc.subscribe(.{ .ctx = f, .onChange = onChange });
        f.owner = try f.store.registerOwner("ai.pending", 30);
    }

    fn deinit(f: *Fixture) void {
        if (f.p) |p| p.destroy();
        f.store.deinit();
        f.doc.deinit();
    }

    fn onChange(ctx: *anyopaque, ev: *const document.ChangeEvent) void {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        if (f.p) |p| p.onChange(ev) catch unreachable;
    }

    /// Proposes `edits` against the current version.
    fn propose(f: *Fixture, edits: []const pt.Edit) !void {
        try f.proposeAt(f.doc.version, f.doc.len(), edits);
    }

    fn proposeAt(f: *Fixture, version: u64, len: u64, edits: []const pt.Edit) !void {
        var cs = try ChangeSet.fromEdits(testing.allocator, len, edits);
        defer cs.deinit();
        f.p = try PendingChange.create(testing.allocator, f.doc, &f.store, f.owner, &cs, version, "Agent 1 edit_file", .{ .agent = 1 }, .{});
    }

    fn edit(f: *Fixture, edits: []const pt.Edit) !void {
        var cs = try ChangeSet.fromEdits(testing.allocator, f.doc.len(), edits);
        defer cs.deinit();
        try f.doc.applyChangeSet(&cs, .{ .user = 0 });
    }

    fn expectText(f: *Fixture, want: []const u8) !void {
        const t = try f.doc.tree.copyRange(testing.allocator, .{ .start = 0, .end = f.doc.len() });
        defer testing.allocator.free(t);
        try testing.expectEqualStrings(want, t);
    }

    fn oldText(f: *Fixture, id: u32) ![]u8 {
        return f.doc.tree.copyRange(testing.allocator, f.p.?.hunks()[id].old_range);
    }
};

const text0 = "one\ntwo\nthree\nfour\n";

test "pending: accept one hunk leaves others pending with rebased ranges" {
    var f: Fixture = undefined;
    try f.init(text0);
    defer f.deinit();
    try f.propose(&.{
        .{ .range = .{ .start = 0, .end = 3 }, .text = "ONE" },
        .{ .range = .{ .start = 8, .end = 13 }, .text = "3\n3.5" },
    });
    try testing.expectEqual(@as(usize, 2), f.p.?.hunks().len);
    try testing.expect(f.store.count() > 0);
    try f.p.?.acceptHunk(1);
    try f.expectText("one\ntwo\n3\n3.5\nfour\n");
    try testing.expectEqual(pending_mod.HunkState.accepted, f.p.?.hunks()[1].state);
    try testing.expectEqual(pending_mod.HunkState.pending, f.p.?.hunks()[0].state);
    const old = try f.oldText(0);
    defer testing.allocator.free(old);
    try testing.expectEqualStrings("one", old);
    try f.p.?.acceptHunk(0);
    try f.expectText("ONE\ntwo\n3\n3.5\nfour\n");
    try testing.expect(f.p.?.resolved());
    try testing.expectEqual(@as(usize, 0), f.store.count());
}

test "pending: user edit elsewhere keeps hunks valid" {
    var f: Fixture = undefined;
    try f.init(text0);
    defer f.deinit();
    try f.propose(&.{.{ .range = .{ .start = 14, .end = 18 }, .text = "FOUR" }});
    try f.edit(&.{.{ .range = .{ .start = 0, .end = 0 }, .text = "zero\n" }});
    try f.edit(&.{.{ .range = .{ .start = 9, .end = 12 }, .text = "" }}); // "two"
    try testing.expectEqual(pending_mod.HunkState.pending, f.p.?.hunks()[0].state);
    const old = try f.oldText(0);
    defer testing.allocator.free(old);
    try testing.expectEqualStrings("four", old);
    try f.p.?.acceptAll();
    try f.expectText("zero\none\n\nthree\nFOUR\n");
}

test "pending: user edit inside hunk marks conflicted" {
    var f: Fixture = undefined;
    try f.init(text0);
    defer f.deinit();
    try f.propose(&.{
        .{ .range = .{ .start = 4, .end = 7 }, .text = "TWO" },
        .{ .range = .{ .start = 14, .end = 18 }, .text = "FOUR" },
    });
    try f.edit(&.{.{ .range = .{ .start = 5, .end = 6 }, .text = "W" }});
    try testing.expectEqual(pending_mod.HunkState.conflicted, f.p.?.hunks()[0].state);
    try testing.expectError(error.Conflicted, f.p.?.acceptHunk(0));
    // Accept all applies only the clean hunk.
    try f.p.?.acceptAll();
    try f.expectText("one\ntWo\nthree\nFOUR\n");
    try testing.expect(!f.p.?.resolved());
    f.p.?.rejectHunk(0);
    try testing.expect(f.p.?.resolved());
}

test "pending: proposal against an older version is rebased" {
    var f: Fixture = undefined;
    try f.init(text0);
    defer f.deinit();
    const v0 = f.doc.version;
    const len0 = f.doc.len();
    try f.edit(&.{.{ .range = .{ .start = 0, .end = 0 }, .text = "// header\n" }});
    try f.edit(&.{.{ .range = .{ .start = 19, .end = 20 }, .text = "R" }}); // inside "three"
    try f.proposeAt(v0, len0, &.{
        .{ .range = .{ .start = 4, .end = 7 }, .text = "TWO" },
        .{ .range = .{ .start = 8, .end = 13 }, .text = "THREE" },
    });
    try testing.expectEqual(pending_mod.HunkState.pending, f.p.?.hunks()[0].state);
    try testing.expectEqual(pending_mod.HunkState.conflicted, f.p.?.hunks()[1].state);
    try f.p.?.acceptHunk(0);
    try f.expectText("// header\none\nTWO\ntRree\nfour\n");
}

test "pending: reject all leaves buffer unchanged" {
    var f: Fixture = undefined;
    try f.init(text0);
    defer f.deinit();
    try f.propose(&.{
        .{ .range = .{ .start = 0, .end = 3 }, .text = "1" },
        .{ .range = .{ .start = 4, .end = 4 }, .text = "inserted\nlines\n" },
    });
    const v = f.doc.version;
    try testing.expect(f.p.?.hunks()[0].intraline.len > 0);
    f.p.?.rejectAll();
    try testing.expectEqual(v, f.doc.version);
    try f.expectText(text0);
    try testing.expect(f.p.?.resolved());
    try testing.expectEqual(@as(usize, 0), f.store.count());
}
