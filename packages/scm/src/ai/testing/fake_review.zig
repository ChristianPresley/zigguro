//! A `ReviewPort` for tests: it records every proposal and answers
//! `status` from its mode (approve all, deny all, or leave pending),
//! unless a test decided an item with `decide`.

const std = @import("std");
const ports = @import("../ports.zig");
const id_mod = @import("../../store/id.zig");
const preview = @import("../../oplog/preview.zig");
const Allocator = std.mem.Allocator;

pub const Mode = enum { approve_all, deny_all, pending };

pub const Item = struct {
    kind: ports.ProposalKind,
    preview_op: preview.DetachedOp,
    summary: []u8,
    lane: []u8,
    changes: []id_mod.ObjectId,
    actor_kind: @import("../../oplog/operation.zig").ActorKind,
    /// Set by `decide`; otherwise the mode answers.
    decided: ?ports.ReviewStatus = null,
};

pub const FakeReview = struct {
    gpa: Allocator,
    mode: Mode,
    /// Item `i` has review ID `i + 1`.
    items: std.ArrayList(Item) = .empty,
    /// When set, `submit` fails with this error.
    fail_submit: ?anyerror = null,

    pub fn init(gpa: Allocator, mode: Mode) FakeReview {
        return .{ .gpa = gpa, .mode = mode };
    }

    pub fn deinit(f: *FakeReview) void {
        for (f.items.items) |it| {
            f.gpa.free(it.summary);
            f.gpa.free(it.lane);
            f.gpa.free(it.changes);
        }
        f.items.deinit(f.gpa);
    }

    pub fn port(f: *FakeReview) ports.ReviewPort {
        return .{ .ctx = f, .submit = submit, .status = status };
    }

    pub fn item(f: *FakeReview, id: ports.ReviewId) ?*Item {
        if (id == 0 or id > f.items.items.len) return null;
        return &f.items.items[@intCast(id - 1)];
    }

    /// Decides item `id`, overriding the mode.
    pub fn decide(f: *FakeReview, id: ports.ReviewId, s: ports.ReviewStatus) void {
        if (f.item(id)) |it| it.decided = s;
    }

    fn submit(ctx: *anyopaque, p: *const ports.Proposal) anyerror!ports.ReviewId {
        const f: *FakeReview = @ptrCast(@alignCast(ctx));
        if (f.fail_submit) |e| return e;
        const summary = try f.gpa.dupe(u8, p.summary);
        errdefer f.gpa.free(summary);
        const lane = try f.gpa.dupe(u8, p.lane);
        errdefer f.gpa.free(lane);
        const changes = try f.gpa.dupe(id_mod.ObjectId, p.changes);
        errdefer f.gpa.free(changes);
        try f.items.append(f.gpa, .{
            .kind = p.kind,
            .preview_op = p.preview_op,
            .summary = summary,
            .lane = lane,
            .changes = changes,
            .actor_kind = p.provenance.actor.kind,
        });
        return f.items.items.len;
    }

    fn status(ctx: *anyopaque, id: ports.ReviewId) ports.ReviewStatus {
        const f: *FakeReview = @ptrCast(@alignCast(ctx));
        const it = f.item(id) orelse return .unknown;
        if (it.decided) |s| return s;
        return switch (f.mode) {
            .approve_all => .approved,
            .deny_all => .rejected,
            .pending => .in_review,
        };
    }
};

const testing = std.testing;

test "fake review: modes, decisions and recorded proposals" {
    const gpa = testing.allocator;
    var r = FakeReview.init(gpa, .pending);
    defer r.deinit();
    const p: ports.Proposal = .{
        .kind = .describe,
        .preview_op = .{ .op = .{ .bytes = @splat(1) }, .base_op = .{ .bytes = @splat(2) }, .created_ms = 5, .purpose = .proposal },
        .summary = "Describe abc",
        .changes = &.{.{ .bytes = @splat(3) }},
        .provenance = .{ .actor = .agent("s1", "t1", "c1"), .model = "m" },
    };
    const port = r.port();
    const a = try port.submitProposal(&p);
    const b = try port.submitProposal(&p);
    try testing.expectEqual(ports.ReviewStatus.in_review, port.statusOf(a));
    r.decide(b, .approved);
    try testing.expectEqual(ports.ReviewStatus.approved, port.statusOf(b));
    try testing.expectEqual(ports.ReviewStatus.unknown, port.statusOf(99));
    r.mode = .deny_all;
    try testing.expectEqual(ports.ReviewStatus.rejected, port.statusOf(a));
    try testing.expectEqualStrings("Describe abc", r.item(a).?.summary);
    try testing.expectEqual(@import("../../oplog/operation.zig").ActorKind.agent, r.item(a).?.actor_kind);
    r.fail_submit = error.QueueFull;
    try testing.expectError(error.QueueFull, port.submitProposal(&p));
}
