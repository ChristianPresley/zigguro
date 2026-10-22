const std = @import("std");
const zg_scm = @import("zg_scm");
const model = @import("../model/root.zig");
const apply = @import("../apply/root.zig");
const port_mod = @import("port.zig");

const testing = std.testing;
const gpa = testing.allocator;
const ScmReviewPort = port_mod.ScmReviewPort;
const ScmDecision = port_mod.ScmDecision;
const PreviewFile = port_mod.PreviewFile;
const Item = port_mod.Item;
const ChangesetId = model.ChangesetId;

const Fake = struct {
    files: []const PreviewFile = &.{},
    outcome: port_mod.Outcome = .done,
    decisions: std.ArrayList(struct { review: u64, approve: bool, text: ?[]const u8 }) = .empty,

    fn previewFiles(f: *Fake) port_mod.PreviewFiles {
        return .{ .ctx = f, .files = filesFn };
    }

    fn actions(f: *Fake) port_mod.ScmActions {
        return .{ .ctx = f, .decide = decideFn };
    }

    fn filesFn(ctx: *anyopaque, arena: std.mem.Allocator, p: *const zg_scm.Proposal) anyerror![]const PreviewFile {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        _ = p;
        return arena.dupe(PreviewFile, f.files);
    }

    fn decideFn(ctx: *anyopaque, it: *const Item, d: ScmDecision) anyerror!port_mod.Outcome {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        const text: ?[]const u8 = switch (d) {
            .describe => |x| switch (x) {
                .approve => |t| t,
                .reject => null,
            },
            else => null,
        };
        try f.decisions.append(gpa, .{ .review = it.review, .approve = d.approves(), .text = text });
        return f.outcome;
    }
};

const Fx = struct {
    blobs: model.MemBlobs,
    q: *model.Queue,
    fake: Fake = .{},
    port: ScmReviewPort,

    fn init(fx: *Fx) !void {
        fx.* = .{ .blobs = .init(gpa), .q = undefined, .port = undefined };
        fx.q = try model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = fx.blobs.blobs() });
        fx.port = .init(gpa, fx.q, fx.fake.previewFiles(), fx.fake.actions(), .{ .workspace = "/w" });
    }

    fn deinit(fx: *Fx) void {
        fx.port.deinit();
        fx.fake.decisions.deinit(gpa);
        fx.q.deinit();
        fx.blobs.deinit();
    }

    fn propose(fx: *Fx, kind: zg_scm.ai.ports.ProposalKind, summary: []const u8, lane: []const u8) !ChangesetId {
        const proposal: zg_scm.Proposal = .{
            .kind = kind,
            .preview_op = .{ .op = .zero, .base_op = .zero, .created_ms = 0, .purpose = if (kind == .land) .landing else .proposal },
            .summary = summary,
            .changes = &.{},
            .provenance = .{ .actor = .agent("s1", "3", ""), .model = "m" },
            .rationale = "because",
            .lane = lane,
        };
        const p = fx.port.port();
        return @enumFromInt(try p.submitProposal(&proposal));
    }
};

test "scm_port: describe proposal → editable description diff; edited approve forwards text" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    fx.fake.files = &.{.{ .path = ".zigguro/scm/description/kxyz", .base = "old text\n", .new = "Fix the parser\n\nLonger body.\n" }};
    const id = try fx.propose(.describe, "AI description for change kxyz", "");
    const cs = fx.q.get(id).?;
    try testing.expectEqualStrings("AI description for change kxyz", cs.prov.label);
    try testing.expectEqualStrings("because", cs.prov.rationale.?);
    try testing.expectEqual(@intFromEnum(id), cs.prov.origin.scm_proposal.review);
    try testing.expectEqual(model.provenance.ScmKind.describe, cs.prov.origin.scm_proposal.kind);
    try testing.expectEqualStrings(".zigguro/scm/description/kxyz", cs.files[0].path);
    try testing.expect(cs.files[0].hunks.len > 0);
    try testing.expectEqual(zg_scm.ReviewStatus.in_review, fx.port.port().statusOf(@intFromEnum(id)));

    // The wrong kind of decision is refused.
    try testing.expectError(error.WrongKind, fx.port.decide(id, .{ .split = .approve }));
    try testing.expectEqual(.done, try fx.port.decide(id, .{ .describe = .{ .approve = "Fix the parser properly\n" } }));
    try testing.expectEqualStrings("Fix the parser properly\n", fx.fake.decisions.items[0].text.?);
    try testing.expectEqual(zg_scm.ReviewStatus.approved, fx.port.port().statusOf(@intFromEnum(id)));
    try testing.expectError(error.NotOpen, fx.port.decide(id, .{ .describe = .reject }));
}

test "scm_port: split proposal renders stack files display-only; Applier never writes" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    fx.fake.files = &.{
        .{ .path = "src/a.zig", .base = "a\nb\n", .new = "a\nB\n" },
        .{ .path = "src/new.zig", .new = "fresh\n" },
        .{ .path = "src/gone.zig", .base = "bye\n" },
    };
    const id = try fx.propose(.split, "Split change kxyz into 2", "");
    const cs = fx.q.get(id).?;
    try testing.expectEqual(@as(usize, 3), cs.files.len);
    try testing.expectEqual(std.meta.Tag(model.FileOp).create, std.meta.activeTag(cs.files[1].op));
    try testing.expectEqual(std.meta.Tag(model.FileOp).delete, std.meta.activeTag(cs.files[2].op));

    var disk: apply.MemFiles = .init(gpa);
    defer disk.deinit();
    try disk.put("src/a.zig", "a\nb\n", false);
    var history: model.History = .init(gpa, null);
    defer history.deinit();
    var ap: apply.Applier = .init(gpa, testing.io, fx.q, disk.files(), &history);
    try testing.expectError(error.ScmProposal, ap.acceptAll(id));
    try testing.expectEqualStrings("a\nb\n", disk.get("src/a.zig").?);
    try testing.expectEqual(model.State.pending, cs.state);

    // A preview that no longer adopts cleanly leaves the item open.
    fx.fake.outcome = .conflicted;
    try testing.expectEqual(.conflicted, try fx.port.decide(id, .{ .split = .approve }));
    try testing.expectEqual(model.State.pending, cs.state);
    fx.fake.outcome = .done;
    _ = try fx.port.decide(id, .{ .split = .reject });
    try testing.expectEqual(zg_scm.ReviewStatus.rejected, fx.port.status(@intFromEnum(id)));
}

test "scm_port: land approve forwards the decision; states mirrored; returned_conflict reopens" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    fx.fake.files = &.{.{ .path = "src/fix.zig", .base = "x\n", .new = "y\n" }};
    const id = try fx.propose(.land, "Land agent/fix-123 onto main", "agent/fix-123");
    const review: u64 = @intFromEnum(id);
    try testing.expectEqualStrings("agent/fix-123", fx.port.item(id).?.lane);
    try testing.expectEqualStrings("agent/fix-123", fx.q.get(id).?.prov.lane.?);

    _ = try fx.port.decide(id, .{ .land = .{ .verdict = .approve, .reviewer = "dana" } });
    try testing.expect(fx.fake.decisions.items[0].approve);
    try fx.port.onLanding(review, .rebasing, "");
    try fx.port.onLanding(review, .checking, "");
    try testing.expectEqual(zg_scm.ai.landing.LandingState.checking, fx.port.item(id).?.landing.?.state);
    try testing.expectEqual(model.State.applied, fx.q.get(id).?.state);

    try fx.port.onLanding(review, .returned_conflict, "src/fix.zig");
    try testing.expectEqual(model.State.pending, fx.q.get(id).?.state);
    try testing.expectEqualStrings("src/fix.zig", fx.port.item(id).?.landing.?.reason);
    try testing.expectEqual(zg_scm.ReviewStatus.in_review, fx.port.status(review));

    // Approved again, it lands.
    _ = try fx.port.decide(id, .{ .land = .{ .verdict = .approve, .reviewer = "dana" } });
    try fx.port.onLanding(review, .landed, "landed as 1a2b");
    try testing.expectEqual(model.State.applied, fx.q.get(id).?.state);
    // Unknown reviews are ignored.
    try fx.port.onLanding(999, .landed, "");
}

test "scm_port: status mapping table" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const id = try fx.propose(.resolve, "Resolve 2 conflicts", "");
    const cs = fx.q.getMut(id).?;
    const review: u64 = @intFromEnum(id);
    const rows = [_]struct { model.State, zg_scm.ReviewStatus }{
        .{ .pending, .in_review }, .{ .partially_applied, .in_review }, .{ .applied, .approved },
        .{ .rejected, .rejected }, .{ .superseded, .cancelled },        .{ .discarded, .cancelled },
    };
    for (rows) |r| {
        cs.state = r[0];
        try testing.expectEqual(r[1], fx.port.status(review));
    }
    try testing.expectEqual(zg_scm.ReviewStatus.unknown, fx.port.status(review + 1));
    // A changeset that is not a proposal is unknown to the port.
    const b = try fx.q.beginBatch(.{ .origin = .{ .user_bulk = .{ .command = "x" } }, .label = "x", .workspace = "/w", .created_ms = 0 });
    try fx.q.addCreate(b, "f", "1\n");
    const other = try fx.q.commitBatch(b, .{});
    try testing.expectEqual(zg_scm.ReviewStatus.unknown, fx.port.status(@intFromEnum(other)));
    try testing.expectError(error.NotScmProposal, fx.port.decide(other, .{ .resolve = .approve }));
}
