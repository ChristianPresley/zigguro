const std = @import("std");
const zg_scm = @import("zg_scm");
const model = @import("../model/root.zig");
const port_mod = @import("port.zig");
const RegionReview = @import("resolve_review.zig").RegionReview;

const testing = std.testing;
const gpa = testing.allocator;
const ChangesetId = model.ChangesetId;
const resolve = zg_scm.ai.resolve;

fn scmMeta(description: []const u8) zg_scm.OpMeta {
    return .{ .start_ms = 0, .end_ms = 0, .description = description, .user = "tester", .host = "host", .workspace = "default", .actor = .human, .tags = &.{} };
}

fn changeId(description: []const u8) zg_scm.ChangeId {
    var cid: zg_scm.ChangeId = undefined;
    const h = std.hash.Wyhash.hash(11, description);
    std.mem.writeInt(u64, cid.bytes[0..8], h, .little);
    std.mem.writeInt(u64, cid.bytes[8..16], std.hash.int(h), .little);
    return cid;
}

fn tree(m: *zg_scm.mutable_repo.MutableRepo, files: []const [2][]const u8) !zg_scm.ObjectId {
    var tm = zg_scm.tree_merge.TreeMerger.init(gpa, m.batch.store, m.batch);
    defer tm.deinit();
    return zg_scm.tree_merge.testTree(&tm, files);
}

/// A change with `terms` (one tree, or three for a conflict).
fn change(m: *zg_scm.mutable_repo.MutableRepo, parents: []const zg_scm.ObjectId, description: []const u8, terms: []const zg_scm.ObjectId) !zg_scm.ObjectId {
    const sig: zg_scm.Signature = .{ .name = "t", .email = "t@example.com", .time_ms = 1_700_000_000_000, .tz_offset_min = 0 };
    return m.writeChange(.{
        .parents = try m.arena.dupe(zg_scm.ObjectId, parents),
        .tree_terms = try m.arena.dupe(zg_scm.ObjectId, terms),
        .change_id = changeId(description),
        .predecessors = &.{},
        .author = sig,
        .committer = sig,
        .description = try m.arena.dupe(u8, description),
        .provenance = null,
        .extra = &.{},
        .sig = null,
    });
}

/// Answers every region with `reply` (thread-safe: no state).
const Model = struct {
    reply: []const u8,

    fn port(m: *Model) zg_scm.ai.ports.ModelPort {
        return .{ .ctx = m, .complete = complete };
    }

    fn complete(ctx: *anyopaque, _: *const zg_scm.ai.ports.AiRequest, sink: *zg_scm.ai.ports.AiSink) anyerror!void {
        const m: *Model = @ptrCast(@alignCast(ctx));
        sink.json(m.reply);
        sink.done(.end, .{});
    }
};

const Fx = struct {
    tmp: testing.TmpDir,
    store: *zg_scm.Store,
    repos: [2]*zg_scm.Repo,
    merged: zg_scm.ObjectId,

    /// base → left, right; a merge of both whose terms conflict in a text
    /// file `f` and a binary `img`, and a working-copy child.
    fn init(fx: *Fx) !void {
        fx.tmp = testing.tmpDir(.{ .iterate = true });
        fx.store = try zg_scm.Store.open(gpa, testing.io, fx.tmp.dir, .{ .fsync = false, .rescan_interval_ms = 0 });
        fx.repos[0] = try zg_scm.Repo.init(gpa, testing.io, fx.tmp.dir, fx.store, .{}, scmMeta("init"));
        var tx = try fx.repos[0].startTransaction(scmMeta("setup"));
        var m = tx.mutRepo();
        const tb = try tree(m, &.{ .{ "f", "a\nx\nz\n" }, .{ "img", "a\x00b" } });
        const tl = try tree(m, &.{ .{ "f", "a\nXL\nz\n" }, .{ "img", "l\x00b" } });
        const tr = try tree(m, &.{ .{ "f", "a\nXR\nz\n" }, .{ "img", "r\x00b" } });
        const root = try change(m, &.{}, "root", &.{try tree(m, &.{.{ "README", "r" }})});
        const b = try change(m, &.{root}, "base", &.{tb});
        const l = try change(m, &.{b}, "left side", &.{tl});
        const r = try change(m, &.{b}, "right side", &.{tr});
        fx.merged = try change(m, &.{ l, r }, "merge", &.{ tl, tb, tr });
        const child = try change(m, &.{fx.merged}, "child", &.{try tree(m, &.{ .{ "f", "a\nXL\nz\n" }, .{ "img", "l\x00b" }, .{ "c", "c" } })});
        try m.setWcCommit("default", child);
        fx.repos[1] = try tx.commit();
    }

    fn deinit(fx: *Fx) void {
        fx.repos[1].close();
        fx.repos[0].close();
        fx.store.close();
        fx.tmp.cleanup();
    }

    fn repo(fx: *Fx) *zg_scm.Repo {
        return fx.repos[1];
    }
};

const reply = "{\"resolution\":\"XL\\nXR\\n\",\"rationale\":\"keeps both lines\",\"addresses_sides\":[true,true]}";

fn findRegion(rr: *const RegionReview, path: []const u8) usize {
    for (0..rr.count()) |i| if (std.mem.eql(u8, rr.region(i).path, path)) return i;
    unreachable;
}

test "resolve review: decide each region, submit, approve adopts the resolution" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    var m: Model = .{ .reply = reply };
    var res: resolve.Resolver = .{ .gpa = gpa, .io = testing.io, .store = fx.store, .model = m.port() };
    const run = try res.proposeForChange(fx.merged);
    defer run.deinit();

    var rr: RegionReview = try .init(gpa, run);
    defer rr.deinit();
    try testing.expectEqual(@as(usize, 2), rr.count());
    const f = findRegion(&rr, "f");
    const img = findRegion(&rr, "img");
    try testing.expectEqual(resolve.Status.ok, rr.proposal(f).status);
    try testing.expectEqual(resolve.Status.needs_human, rr.proposal(img).status);

    // Only the text region's proposal can be taken; the binary one needs a side.
    try testing.expectEqual(@as(usize, 1), rr.acceptProposed());
    try testing.expectError(error.NeedsHuman, rr.accept(img));
    try testing.expectError(error.NotText, rr.keepConflict(img));
    try testing.expectError(error.NotText, rr.edit(img, "x"));
    try testing.expectEqual(@as(usize, 1), rr.remaining());

    var blobs: model.MemBlobs = .init(gpa);
    defer blobs.deinit();
    const q = try model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = blobs.blobs() });
    defer q.deinit();
    var pf: zg_scm.ai.proposal_files.ProposalFiles = .{ .store = fx.store };
    var actions: port_mod.RepoActions = .{ .repo = fx.repo(), .meta = scmMeta("approve") };
    var port: port_mod.ScmReviewPort = .init(gpa, q, .ofRepo(&pf), actions.actions(), .{ .workspace = "/w" });
    defer port.deinit();
    const sub: RegionReview.Submit = .{ .summary = "Resolve merge", .provenance = .{ .actor = .human }, .meta = scmMeta("resolve") };
    try testing.expectError(error.MissingDecision, rr.submit(fx.repo(), &port, sub));

    try rr.side(img, 1);
    const id: ChangesetId = @enumFromInt(try rr.submit(fx.repo(), &port, sub));
    const it = port.item(id).?;
    try testing.expectEqual(zg_scm.ai.ports.ProposalKind.resolve, it.kind);
    try testing.expectEqualStrings("Resolve merge", q.get(id).?.prov.label);

    // The item shows the resolved files against the conflicted change.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const shown: zg_scm.Proposal = .{ .kind = .resolve, .preview_op = it.preview_op, .summary = "", .changes = &.{it.commit.?}, .provenance = .{ .actor = .human }, .rationale = "", .lane = "" };
    const files = try zg_scm.ai.proposal_files.ProposalFiles.filesFn(&pf, arena.allocator(), &shown);
    var saw: u32 = 0;
    for (files) |file| {
        if (std.mem.eql(u8, file.path, "f")) {
            try testing.expectEqualStrings("a\nXL\nXR\nz\n", file.new.?);
            saw += 1;
        }
        if (std.mem.eql(u8, file.path, "img")) {
            // Binary files show as a placeholder.
            try testing.expect(std.mem.startsWith(u8, file.new.?, "(binary file"));
            saw += 1;
        }
    }
    try testing.expectEqual(@as(u32, 2), saw);

    try testing.expectEqual(.done, try port.decide(id, .{ .resolve = .approve }));
    try testing.expectEqual(zg_scm.ReviewStatus.approved, port.status(@intFromEnum(id)));
}

test "resolve review: an edited region and a kept conflict" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    var m: Model = .{ .reply = reply };
    var res: resolve.Resolver = .{ .gpa = gpa, .io = testing.io, .store = fx.store, .model = m.port() };
    const run = try res.proposeForChange(fx.merged);
    defer run.deinit();
    var rr: RegionReview = try .init(gpa, run);
    defer rr.deinit();
    const f = findRegion(&rr, "f");
    const img = findRegion(&rr, "img");

    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "XR\nXL\n", .{});
    try rr.edit(f, text);
    @memset(&buf, 0);
    try rr.side(img, 0);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ds = try rr.decisions(arena.allocator());
    // The edited text is the review's own copy.
    try testing.expectEqualStrings("XR\nXL\n", ds[f].choice.edit);
    try testing.expectEqual(@as(u32, 0), ds[img].choice.side);

    try rr.keepConflict(f);
    rr.clear(img);
    try testing.expectEqual(@as(usize, 1), rr.remaining());
    try testing.expectError(error.MissingDecision, rr.decisions(arena.allocator()));
    try testing.expectError(error.NoSuchSide, rr.side(img, 2));
}
