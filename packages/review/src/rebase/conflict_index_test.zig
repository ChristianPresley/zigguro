const std = @import("std");
const model = @import("../model/root.zig");
const apply = @import("../apply/root.zig");
const ci_mod = @import("conflict_index.zig");

const testing = std.testing;
const gpa = testing.allocator;
const ChangesetId = model.ChangesetId;
const ConflictIndex = ci_mod.ConflictIndex;
const ConflictKind = ci_mod.ConflictKind;

const base10 = "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\n";

const Fx = struct {
    blobs: model.MemBlobs,
    disk: apply.MemFiles,
    history: model.History,
    q: *model.Queue,
    ap: apply.Applier,
    ci: *ConflictIndex,
    created: i64 = 0,

    fn init(fx: *Fx) !void {
        fx.* = .{ .blobs = .init(gpa), .disk = .init(gpa), .history = .init(gpa, null), .q = undefined, .ap = undefined, .ci = undefined };
        fx.q = try model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = fx.blobs.blobs() });
        fx.ap = .init(gpa, testing.io, fx.q, fx.disk.files(), &fx.history);
        fx.ci = try ConflictIndex.init(gpa, fx.q, .{ .history = &fx.history, .names = .{ .ctx = fx, .name = name } });
    }

    fn deinit(fx: *Fx) void {
        fx.ci.deinit();
        fx.q.deinit();
        fx.history.deinit();
        fx.disk.deinit();
        fx.blobs.deinit();
    }

    fn name(_: *anyopaque, session: u128) ?[]const u8 {
        return if (session == 2) "reviewer" else null;
    }

    fn begin(fx: *Fx, session: u128) !model.BatchId {
        fx.created += 1;
        return fx.q.beginBatch(.{
            .origin = .{ .agent = .{ .ref = .{ .session = session }, .turn = 1, .model = "m" } },
            .label = "Turn 1",
            .workspace = "/w",
            .created_ms = fx.created,
        });
    }

    /// Session `session` proposes `new` for `path`, whose text is `base`.
    fn edit(fx: *Fx, session: u128, path: []const u8, base: []const u8, new: []const u8) !ChangesetId {
        const b = try fx.begin(session);
        var e = try model.merge3.lineChangeSet(gpa, base, new);
        defer e.deinit();
        try fx.q.addEdit(b, path, base, null, &e);
        return fx.q.commitBatch(b, .{});
    }

    fn create(fx: *Fx, session: u128, path: []const u8, bytes: []const u8) !ChangesetId {
        const b = try fx.begin(session);
        try fx.q.addCreate(b, path, bytes);
        return fx.q.commitBatch(b, .{});
    }

    fn delete(fx: *Fx, session: u128, path: []const u8, base: []const u8) !ChangesetId {
        const b = try fx.begin(session);
        try fx.q.addDelete(b, path, base);
        return fx.q.commitBatch(b, .{});
    }

    fn rename(fx: *Fx, session: u128, from: []const u8, to: []const u8) !ChangesetId {
        const b = try fx.begin(session);
        try fx.q.addRename(b, from, to);
        return fx.q.commitBatch(b, .{});
    }

    fn only(fx: *Fx, a: ChangesetId, b: ChangesetId) !?ConflictKind {
        const ps = fx.ci.conflictsOf(a);
        if (ps.len == 0) return null;
        for (ps) |p| try testing.expect((p.a.cs == a and p.b.cs == b) or (p.a.cs == b and p.b.cs == a));
        return ps[0].kind;
    }

    fn text(fx: *Fx, id: ChangesetId, arena: std.mem.Allocator) ![]u8 {
        const t = fx.q.get(id).?.files[0].content.text;
        const base = (try fx.blobs.blobs().get(arena, t.base.?.hash)).?;
        return t.edits.applyToSlice(arena, base);
    }
};

fn replaceLine(arena: std.mem.Allocator, line: usize, with: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, base10[0 .. base10.len - 1], '\n');
    var i: usize = 0;
    while (it.next()) |l| : (i += 1) {
        try out.appendSlice(arena, if (i == line) with else l);
        try out.append(arena, '\n');
    }
    return out.items;
}

test "conflicts: overlap/adjacent/same_change/create_create/delete_modify/rename_target detection table" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const Case = struct { a: []const u8, b: []const u8, want: ?ConflictKind };
    const cases = [_]Case{
        .{ .a = "e2:A", .b = "e2:B", .want = .overlap },
        .{ .a = "e2:A", .b = "e3:B", .want = .adjacent },
        .{ .a = "e2:A", .b = "e2:A", .want = .same_change },
        .{ .a = "e2:A", .b = "e6:B", .want = null },
        .{ .a = "c:one", .b = "c:two", .want = .create_create },
        .{ .a = "c:one", .b = "c:one", .want = .same_change },
        .{ .a = "d", .b = "e5:B", .want = .delete_modify },
        .{ .a = "d", .b = "d", .want = .same_change },
        .{ .a = "r:x", .b = "r:y", .want = .rename_target },
        .{ .a = "r:x", .b = "c:one", .want = .rename_target },
    };
    for (cases) |c| {
        var fx: Fx = undefined;
        try fx.init();
        defer fx.deinit();
        var ids: [2]ChangesetId = undefined;
        for ([_][]const u8{ c.a, c.b }, &ids, 0..) |spec, *id, s| {
            const session: u128 = s + 1;
            id.* = switch (spec[0]) {
                'e' => try fx.edit(session, "f.txt", base10, try replaceLine(ar, spec[1] - '0', spec[3..])),
                'c' => try fx.create(session, "f.txt", spec[2..]),
                'd' => try fx.delete(session, "f.txt", base10),
                'r' => try fx.rename(session, spec[2..], "f.txt"),
                else => unreachable,
            };
        }
        const got = try fx.only(ids[0], ids[1]);
        testing.expectEqual(c.want, got) catch |e| {
            std.debug.print("case {s} vs {s}\n", .{ c.a, c.b });
            return e;
        };
        try testing.expectEqual(fx.ci.conflictsOf(ids[0]).len, fx.ci.conflictsOf(ids[1]).len);
    }
}

test "conflicts: different base hashes are not compared until rebased" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const a = try fx.edit(1, "f.txt", "a\nb\n", "A\nb\n");
    const b = try fx.edit(2, "f.txt", "a\nB\n", "X\nB\n");
    try testing.expectEqual(@as(usize, 0), fx.ci.conflictsOf(a).len);
    try testing.expectEqual(@as(usize, 0), fx.ci.conflictsOf(b).len);
    try testing.expectEqual(@as(usize, 2), fx.ci.pendingOnPath("f.txt").len);
}

test "conflicts: apply A → B rebased; non-overlap clean, overlap conflicted(sibling)" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("f.txt", base10, false);
    const a = try fx.edit(1, "f.txt", base10, try replaceLine(ar, 2, "A"));
    const b = try fx.edit(2, "f.txt", base10, "l0\nl1\nB\nl3\nl4\nl5\nl6\nl7\nB8\nl9\n");
    const c = try fx.edit(3, "f.txt", base10, try replaceLine(ar, 6, "C"));
    try testing.expectEqual(ConflictKind.overlap, fx.ci.conflictsOf(a)[0].kind);
    try testing.expectEqual(@as(usize, 1), fx.ci.conflictsOf(b).len);

    _ = try fx.ap.acceptAll(a);
    const r = try fx.ci.rebaseApplied();
    try testing.expectEqual(@as(u32, 2), r.files);
    try testing.expectEqual(@as(u32, 1), r.clean);
    try testing.expectEqual(@as(u32, 1), r.conflicted);
    try testing.expectEqual(@as(usize, 0), fx.ci.conflictsOf(a).len);

    // C lands on top of A.
    const res = try fx.ap.acceptAll(c);
    try testing.expect(res == .ok);
    try testing.expectEqualStrings("l0\nl1\nA\nl3\nl4\nl5\nC\nl7\nl8\nl9\n", fx.disk.get("f.txt").?);
    _ = try fx.ci.rebaseApplied();

    // B keeps its text; the line A changed is marked.
    try testing.expectEqualStrings("l0\nl1\nB\nl3\nl4\nl5\nC\nl7\nB8\nl9\n", try fx.text(b, ar));
    const hs = fx.q.get(b).?.files[0].hunks;
    try testing.expectEqual(@as(usize, 2), hs.len);
    const conflict = hs[0].conflict.?;
    try testing.expectEqual(model.ConflictKind.sibling_changeset, conflict.kind);
    try testing.expectEqual(@as(?ChangesetId, a), conflict.other);
    try testing.expectEqualStrings("A\n", conflict.theirs_text);
    try testing.expectEqual(@as(?model.ConflictInfo, null), hs[1].conflict);
    // Accepting the conflicted hunk takes B's line.
    _ = try fx.ap.acceptAll(b);
    try testing.expectEqualStrings("l0\nl1\nB\nl3\nl4\nl5\nC\nl7\nB8\nl9\n", fx.disk.get("f.txt").?);
}

test "conflicts: same_change auto-resolves on accept" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.disk.put("f.txt", base10, false);
    const new = try replaceLine(ar, 4, "same");
    const a = try fx.edit(1, "f.txt", base10, new);
    const b = try fx.edit(2, "f.txt", base10, new);
    try testing.expectEqual(ConflictKind.same_change, fx.ci.conflictsOf(b)[0].kind);
    _ = try fx.ap.acceptAll(a);
    const r = try fx.ci.rebaseApplied();
    try testing.expectEqual(@as(u32, 1), r.resolved);
    try testing.expectEqual(model.State.applied, fx.q.get(b).?.state);
    try testing.expectEqual(@as(usize, 0), fx.ci.pendingOnPath("f.txt").len);
}

test "conflicts: warningFor lists other sessions only" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const a = try fx.edit(1, "f.txt", "a\nb\n", "A\nb\n");
    const b = try fx.edit(2, "f.txt", "a\nb\n", "a\nB\n");
    _ = a;
    const w1 = (try fx.ci.warningFor("f.txt", 1, gpa)).?;
    defer gpa.free(w1);
    var want: [64]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, w1, try std.fmt.bufPrint(&want, "{f} \"Turn 1\" (reviewer)", .{b})) != null);
    try testing.expect(std.mem.indexOf(u8, w1, "#1 ") == null);
    const w3 = (try fx.ci.warningFor("f.txt", 3, gpa)).?;
    defer gpa.free(w3);
    try testing.expect(std.mem.indexOf(u8, w3, "another session") != null);
    try testing.expectEqual(@as(?[]u8, null), try fx.ci.warningFor("g.txt", 1, gpa));
}

test "conflicts: incremental update touches only affected paths" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    _ = try fx.edit(1, "a.txt", "a\n", "A\n");
    _ = try fx.edit(2, "b.txt", "b\n", "B\n");
    _ = try fx.edit(3, "c.txt", "c\n", "C\n");
    const before = fx.ci.stats.path_recomputes;
    _ = try fx.edit(4, "a.txt", "a\n", "X\n");
    try testing.expectEqual(before + 1, fx.ci.stats.path_recomputes);
}

test "conflicts: accept order puts the least conflicting first" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const a = try fx.edit(1, "f.txt", base10, "l0\nl1\nA\nl3\nl4\nl5\nA\nl7\nl8\nl9\n");
    const b = try fx.edit(2, "f.txt", base10, try replaceLine(ar, 2, "B"));
    const c = try fx.edit(3, "f.txt", base10, try replaceLine(ar, 6, "C"));
    const order = try fx.ci.acceptOrder(&.{ a, b, c }, gpa);
    defer gpa.free(order);
    try testing.expectEqualSlices(ChangesetId, &.{ b, c, a }, order);
}
