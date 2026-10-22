const std = @import("std");
const model = @import("../model/root.zig");
const apply = @import("../apply/root.zig");
const overlay_fs = @import("overlay_fs.zig");
const agent_view = @import("agent_view.zig");
const ConflictIndex = @import("../rebase/conflict_index.zig").ConflictIndex;

const testing = std.testing;
const gpa = testing.allocator;
const ChangesetId = model.ChangesetId;
const OverlayFs = overlay_fs.OverlayFs;
const DirEntry = overlay_fs.DirEntry;

const Fx = struct {
    blobs: model.MemBlobs,
    disk: apply.MemFiles,
    q: *model.Queue,
    fs: OverlayFs,
    arena: std.heap.ArenaAllocator,

    fn init(fx: *Fx) !void {
        fx.* = .{ .blobs = .init(gpa), .disk = .init(gpa), .q = undefined, .fs = undefined, .arena = .init(gpa) };
        fx.q = try model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = fx.blobs.blobs() });
        fx.fs = .{ .q = fx.q, .files = fx.disk.files(), .lister = .{ .ctx = &fx.disk, .list = list } };
    }

    fn deinit(fx: *Fx) void {
        fx.q.deinit();
        fx.disk.deinit();
        fx.blobs.deinit();
        fx.arena.deinit();
    }

    fn a(fx: *Fx) std.mem.Allocator {
        return fx.arena.allocator();
    }

    /// Lists MemFiles paths as a directory tree.
    fn list(ctx: *anyopaque, arena: std.mem.Allocator, dir: []const u8) anyerror![]const DirEntry {
        const m: *apply.MemFiles = @ptrCast(@alignCast(ctx));
        var out: std.ArrayList(DirEntry) = .empty;
        for (m.map.keys()) |p| {
            const rest = if (dir.len == 0) p else if (std.mem.startsWith(u8, p, dir) and p.len > dir.len and p[dir.len] == '/') p[dir.len + 1 ..] else continue;
            const e: DirEntry = if (std.mem.indexOfScalar(u8, rest, '/')) |i| .{ .name = rest[0..i], .kind = .directory } else .{ .name = rest, .kind = .file };
            for (out.items) |o| {
                if (std.mem.eql(u8, o.name, e.name)) break;
            } else try out.append(arena, e);
        }
        return out.items;
    }

    fn begin(fx: *Fx, session: u128, agent: u32) !model.BatchId {
        return fx.q.beginBatch(.{
            .origin = .{ .agent = .{ .ref = .{ .session = session, .agent = agent }, .turn = 1, .model = "m" } },
            .label = "Turn 1",
            .workspace = "/w",
            .created_ms = 0,
        });
    }

    fn edit(fx: *Fx, session: u128, agent: u32, path: []const u8, base: []const u8, new: []const u8) !ChangesetId {
        const b = try fx.begin(session, agent);
        var e = try model.merge3.lineChangeSet(gpa, base, new);
        defer e.deinit();
        try fx.q.addEdit(b, path, base, null, &e);
        return fx.q.commitBatch(b, .{});
    }

    fn text(fx: *Fx, view: overlay_fs.ViewSpec, path: []const u8) !?[]const u8 {
        const r = try fx.fs.read(fx.a(), view, path) orelse return null;
        return r.text;
    }

    fn names(fx: *Fx, view: overlay_fs.ViewSpec, dir: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (try fx.fs.listDir(fx.a(), view, dir)) |e| {
            if (out.items.len > 0) try out.append(fx.a(), ' ');
            try out.appendSlice(fx.a(), e.name);
            if (e.kind == .directory) try out.append(fx.a(), '/');
        }
        return out.items;
    }
};

const s1: overlay_fs.ViewSpec = .{ .agent = .{ .session = 1 } };
const s2: overlay_fs.ViewSpec = .{ .agent = .{ .session = 2 } };

test "overlay: agent sees own pending edit, other agent does not" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("a.txt", "a\nb\n", false);
    const id = try fx.edit(1, 0, "a.txt", "a\nb\n", "A\nb\n");

    const mine = (try fx.fs.read(fx.a(), s1, "a.txt")).?;
    try testing.expectEqualStrings("A\nb\n", mine.text);
    try testing.expectEqualSlices(ChangesetId, &.{id}, mine.includes_pending);
    try testing.expect(!mine.stale);
    const theirs = (try fx.fs.read(fx.a(), s2, "a.txt")).?;
    try testing.expectEqualStrings("a\nb\n", theirs.text);
    try testing.expectEqualSlices(ChangesetId, &.{id}, theirs.others_pending);
    try testing.expectEqualStrings("a\nb\n", (try fx.text(.disk, "a.txt")).?);
    try testing.expectEqualStrings("A\nb\n", (try fx.text(.{ .changeset = id }, "a.txt")).?);
    try testing.expectEqualStrings("A\nb\n", (try fx.text(.all_pending, "a.txt")).?);
}

test "overlay: listDir includes pending create, hides pending delete and rename source" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("keep.txt", "k", false);
    try fx.disk.put("gone.txt", "g", false);
    try fx.disk.put("old.txt", "o", false);
    try fx.disk.put("src/main.zig", "m", false);
    const b = try fx.begin(1, 0);
    try fx.q.addCreate(b, "new.txt", "n\n");
    try fx.q.addCreate(b, "docs/guide/intro.md", "# Hi\n");
    try fx.q.addDelete(b, "gone.txt", "g");
    try fx.q.addRename(b, "old.txt", "src/renamed.txt");
    _ = try fx.q.commitBatch(b, .{});

    try testing.expectEqualStrings("gone.txt keep.txt old.txt src/", try fx.names(.disk, ""));
    try testing.expectEqualStrings("docs/ keep.txt new.txt src/", try fx.names(s1, ""));
    try testing.expectEqualStrings("main.zig renamed.txt", try fx.names(s1, "src"));
    try testing.expectEqualStrings("guide/", try fx.names(s1, "docs"));
    try testing.expectEqualStrings("gone.txt keep.txt old.txt src/", try fx.names(s2, ""));

    try testing.expectEqualStrings("n\n", (try fx.text(s1, "new.txt")).?);
    try testing.expectEqual(@as(?[]const u8, null), try fx.text(s1, "gone.txt"));
    try testing.expectEqual(@as(?[]const u8, null), try fx.text(s1, "old.txt"));
    try testing.expectEqualStrings("o", (try fx.text(s1, "src/renamed.txt")).?);
    const st = (try fx.fs.stat(fx.a(), s1, "new.txt")).?;
    try testing.expectEqual(@as(u64, 2), st.size);
    try testing.expect(st.pending);
}

test "overlay: subagent shares parent view; setting off isolates" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("a.txt", "a\n", false);
    _ = try fx.edit(1, 2, "a.txt", "a\n", "sub\n");
    try testing.expectEqualStrings("sub\n", (try fx.text(s1, "a.txt")).?);
    fx.fs.o.subagents_share_view = false;
    try testing.expectEqualStrings("a\n", (try fx.text(s1, "a.txt")).?);
    try testing.expectEqualStrings("sub\n", (try fx.text(.{ .agent = .{ .session = 1, .agent = 2 } }, "a.txt")).?);
}

test "overlay: proposal against pending text folds" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("a.txt", "a\nb\nc\n", false);
    const first = try fx.edit(1, 0, "a.txt", "a\nb\nc\n", "A\nb\nc\n");
    const v = agent_view.agentView(&fx.fs, .{ .session = 1 }, null);
    const base = (try v.baseFor(fx.a(), "a.txt")).?;
    _ = try fx.edit(1, 0, "a.txt", base, "A\nb\nC\n");
    try testing.expectEqualStrings("A\nb\nC\n", (try v.readText(fx.a(), "a.txt")).?.text);
    const r = (try v.readText(fx.a(), "a.txt")).?;
    try testing.expectEqualSlices(ChangesetId, &.{first}, r.includes_pending);
    try testing.expectEqual(@as(usize, 1), fx.q.get(first).?.files[0].folded_from.len);
}

test "overlay: base changed on disk is merged and marked stale" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("a.txt", "a\nb\nc\n", false);
    _ = try fx.edit(1, 0, "a.txt", "a\nb\nc\n", "A\nb\nc\n");
    try fx.disk.put("a.txt", "a\nb\nC\n", false);
    const r = (try fx.fs.read(fx.a(), s1, "a.txt")).?;
    try testing.expectEqualStrings("A\nb\nC\n", r.text);
    try testing.expect(r.stale);
}

test "overlay: open documents replace the disk" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("a.txt", "disk\n", true);
    const Docs = struct {
        fn snapshot(_: *anyopaque, _: std.mem.Allocator, path: []const u8) anyerror!?[]const u8 {
            return if (std.mem.eql(u8, path, "a.txt")) "typed\n" else null;
        }
    };
    var dummy: u8 = 0;
    fx.fs.docs = .{ .ctx = &dummy, .snapshot = Docs.snapshot };
    const r = (try fx.fs.read(fx.a(), .disk, "a.txt")).?;
    try testing.expectEqualStrings("typed\n", r.text);
    try testing.expect(r.executable);
}

test "overlay: zero disk writes with N pending changesets" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("a.txt", "0\n1\n2\n3\n4\n5\n6\n7\n", false);
    const before = fx.disk.mutations;
    var lines = [_]u8{ '0', '\n', '1', '\n', '2', '\n', '3', '\n', '4', '\n', '5', '\n', '6', '\n', '7', '\n' };
    for (0..8) |i| {
        lines[i * 2] = 'x';
        _ = try fx.edit(@intCast(i + 1), 0, "a.txt", "0\n1\n2\n3\n4\n5\n6\n7\n", &lines);
        lines[i * 2] = '0' + @as(u8, @intCast(i));
    }
    for (0..8) |i| _ = try fx.text(.{ .agent = .{ .session = @intCast(i + 1) } }, "a.txt");
    _ = try fx.text(.all_pending, "a.txt");
    _ = try fx.names(.all_pending, "");
    try testing.expectEqual(before, fx.disk.mutations);
}

test "overlay: agent view warns about other sessions" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const ci = try ConflictIndex.init(gpa, fx.q, .{});
    defer ci.deinit();
    try fx.disk.put("a.txt", "a\n", false);
    _ = try fx.edit(2, 0, "a.txt", "a\n", "b\n");
    const mine = agent_view.agentView(&fx.fs, .{ .session = 1 }, ci);
    const w = (try mine.pendingWarning(gpa, "a.txt")).?;
    defer gpa.free(w);
    try testing.expect(std.mem.indexOf(u8, w, "a.txt") != null);
    const theirs = agent_view.agentView(&fx.fs, .{ .session = 2 }, ci);
    try testing.expectEqual(@as(?[]u8, null), try theirs.pendingWarning(gpa, "a.txt"));
}
