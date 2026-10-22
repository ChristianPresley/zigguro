const std = @import("std");
const model = @import("../model/root.zig");
const apply = @import("../apply/root.zig");
const rules = @import("rules.zig");
const policy = @import("policy.zig");

const testing = std.testing;
const gpa = testing.allocator;
const ReviewPolicy = policy.ReviewPolicy;
const ChangeSet = model.changeset.ChangeSet;

/// A fake E16: per-path answers, one mode.
const Fake = struct {
    mode: policy.Mode = .default,
    deny: []const u8 = "",
    managed_ask: []const u8 = "",

    fn probe(ctx: *anyopaque, _: ?u128, path: []const u8, _: rules.Op) policy.ProbeResult {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        if (f.deny.len > 0 and std.mem.eql(u8, path, f.deny)) return .{ .kind = .deny, .layer = .deny_rule, .message = "denied by rule Edit(secret.txt)" };
        if (f.managed_ask.len > 0 and std.mem.eql(u8, path, f.managed_ask)) return .{ .kind = .ask, .layer = .managed };
        return .{ .kind = .ask, .layer = .default };
    }

    fn modeOf(ctx: *anyopaque, _: ?u128) policy.Mode {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        return f.mode;
    }

    fn security(f: *Fake) policy.SecurityProbe {
        return .{ .ctx = f, .probe = probe, .mode = modeOf };
    }
};

const settings: rules.Settings = .{
    .rules = &.{
        .{ .paths = &.{"docs/**/*.md"}, .agents = &.{"docs-writer"}, .max_changed_lines = 200, .action = .auto_accept },
        .{ .paths = &.{ "**/*.lock", "zig-pkg/**" }, .action = .review_required },
        .{ .origins = &.{.lsp}, .tools = &.{"format"}, .action = .auto_accept },
        .{ .paths = &.{"gen/**"}, .ops = &.{ .create, .modify, .delete }, .action = .auto_accept },
        .{ .paths = &.{"docs/drafts/**"}, .action = .review },
        .{ .paths = &.{"docs/{a,b"}, .action = .auto_accept },
    },
    .protected = &.{"secrets/**"},
};

const Row = struct {
    name: []const u8,
    mode: policy.Mode = .default,
    deny: []const u8 = "",
    managed_ask: []const u8 = "",
    s: rules.Subject,
    want: policy.Action,
    step: policy.Step,
};

fn subj(path: []const u8, op: rules.Op) rules.Subject {
    return .{ .path = path, .op = op, .origin = .agent, .agent = "docs-writer", .tool = "edit_file", .changed_lines = 3 };
}

fn with(s: rules.Subject, comptime field: []const u8, v: anytype) rules.Subject {
    var x = s;
    @field(x, field) = v;
    return x;
}

test "policy: precedence table" {
    const p = try ReviewPolicy.init(gpa, settings);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.diagnostics.len);
    const rows = [_]Row{
        .{ .name = "default review", .s = subj("src/main.zig", .modify), .want = .review, .step = .default },
        .{ .name = "auto_accept rule", .s = subj("docs/a/b.md", .modify), .want = .auto_apply, .step = .rule },
        .{ .name = "auto_accept needs the agent", .s = with(subj("docs/a.md", .modify), "agent", @as(?[]const u8, "coder")), .want = .review, .step = .default },
        .{ .name = "auto_accept line limit", .s = with(subj("docs/a.md", .modify), "changed_lines", @as(?u32, 201)), .want = .review, .step = .default },
        .{ .name = "unknown lines never auto", .s = with(subj("docs/a.md", .modify), "changed_lines", @as(?u32, null)), .want = .review, .step = .default },
        .{ .name = "review_required beats a later auto_accept", .s = subj("gen/deps.lock", .modify), .want = .review, .step = .rule },
        .{ .name = "review_required under docs", .s = subj("docs/x.lock", .modify), .want = .review, .step = .rule },
        .{ .name = "origin and tool rule", .s = with(with(subj("src/a.zig", .modify), "origin", rules.OriginKind.lsp), "tool", @as(?[]const u8, "format")), .want = .auto_apply, .step = .rule },
        .{ .name = "origin rule needs the origin", .s = with(subj("src/a.zig", .modify), "tool", @as(?[]const u8, "format")), .want = .review, .step = .default },
        .{ .name = "ops mask allows delete", .s = subj("gen/out.txt", .delete), .want = .auto_apply, .step = .rule },
        .{ .name = "ops mask excludes rename", .s = with(subj("gen/b.txt", .rename), "from", @as(?[]const u8, "gen/a.txt")), .want = .review, .step = .default },
        .{ .name = "explicit review rule", .s = with(subj("docs/drafts/x.txt", .modify), "agent", @as(?[]const u8, null)), .want = .review, .step = .rule },
        .{ .name = "first matching rule wins", .s = subj("docs/drafts/x.md", .modify), .want = .auto_apply, .step = .rule },
        .{ .name = "protected default", .s = subj(".zigguro/settings.zon", .modify), .want = .review, .step = .protected_path },
        .{ .name = "protected env anywhere", .s = subj("docs/.env.local", .modify), .want = .review, .step = .protected_path },
        .{ .name = "protected build.zig", .s = subj("build.zig", .modify), .want = .review, .step = .protected_path },
        .{ .name = "protected from settings", .s = subj("secrets/k.md", .modify), .want = .review, .step = .protected_path },
        .{ .name = "protected beats accept_edits", .mode = .accept_edits, .s = subj(".git/config", .modify), .want = .review, .step = .protected_path },
        .{ .name = "rename from a protected path", .s = with(subj("docs/a.md", .rename), "from", @as(?[]const u8, ".github/workflows/ci.yml")), .want = .review, .step = .protected_path },
        .{ .name = "accept_edits auto-applies edits", .mode = .accept_edits, .s = subj("src/main.zig", .modify), .want = .auto_apply, .step = .mode },
        .{ .name = "accept_edits auto-applies creates", .mode = .accept_edits, .s = subj("src/new.zig", .create), .want = .auto_apply, .step = .mode },
        .{ .name = "accept_edits leaves deletes to the rules", .mode = .accept_edits, .s = subj("src/old.zig", .delete), .want = .review, .step = .default },
        .{ .name = "accept_edits: outside the workspace", .mode = .accept_edits, .s = subj("../other/x.zig", .modify), .want = .review, .step = .default },
        .{ .name = "bypass auto-applies", .mode = .bypass, .s = subj("src/main.zig", .modify), .want = .auto_apply, .step = .mode },
        .{ .name = "mode beats review_required", .mode = .accept_edits, .s = subj("x.lock", .modify), .want = .auto_apply, .step = .mode },
        .{ .name = "dont_ask queues", .mode = .dont_ask, .s = subj("docs/a.md", .modify), .want = .review, .step = .mode },
        .{ .name = "plan mode denies", .mode = .plan, .s = subj("docs/a.md", .modify), .want = .deny, .step = .plan_mode },
        .{ .name = "E16 deny", .deny = "docs/a.md", .s = subj("docs/a.md", .modify), .want = .deny, .step = .security_deny },
        .{ .name = "E16 deny beats bypass", .mode = .bypass, .deny = "src/a.zig", .s = subj("src/a.zig", .modify), .want = .deny, .step = .security_deny },
        .{ .name = "E16 deny on a rename source", .deny = "docs/old.md", .s = with(subj("docs/a.md", .rename), "from", @as(?[]const u8, "docs/old.md")), .want = .deny, .step = .security_deny },
        .{ .name = "managed ask forces review", .managed_ask = "docs/a.md", .s = subj("docs/a.md", .modify), .want = .review, .step = .managed },
        .{ .name = "managed ask beats accept_edits", .mode = .accept_edits, .managed_ask = "src/a.zig", .s = subj("src/a.zig", .modify), .want = .review, .step = .managed },
    };
    for (rows) |r| {
        var fake: Fake = .{ .mode = r.mode, .deny = r.deny, .managed_ask = r.managed_ask };
        const v = p.decide(.{ .origin = r.s.origin, .security = fake.security() }, r.s);
        testing.expectEqual(r.want, v.action) catch |e| {
            std.debug.print("row \"{s}\": {t} by {t} ({s})\n", .{ r.name, v.action, v.step, v.reason });
            return e;
        };
        testing.expectEqual(r.step, v.step) catch |e| {
            std.debug.print("row \"{s}\": step {t}\n", .{ r.name, v.step });
            return e;
        };
    }
}

test "policy: without settings or E16 everything is reviewed" {
    const p = try ReviewPolicy.init(gpa, .{});
    defer p.deinit();
    for ([_]rules.Op{ .create, .modify, .delete, .rename, .mode }) |op| {
        const v = p.decide(.{ .origin = .agent }, subj("src/a.zig", op));
        try testing.expectEqual(policy.Action.review, v.action);
    }
}

test "policy: a delete counts every line of the file" {
    const p = try ReviewPolicy.init(gpa, .{ .rules = &.{.{ .paths = &.{"gen/**"}, .max_changed_lines = 10, .action = .auto_accept }} });
    defer p.deinit();
    const Lines = struct {
        n: ?u32,
        fn lines(ctx: *anyopaque, _: model.BaseRef) ?u32 {
            const l: *@This() = @ptrCast(@alignCast(ctx));
            return l.n;
        }
    };
    var fc: model.FileChange = .{ .path = "gen/a.txt", .op = .delete, .content = .none, .base = .of("x\n") };
    for ([_]struct { n: ?u32, want: policy.Action }{ .{ .n = 5, .want = .auto_apply }, .{ .n = 50, .want = .review }, .{ .n = null, .want = .review } }) |c| {
        var l: Lines = .{ .n = c.n };
        const ctx: policy.PolicyCtx = .{ .origin = .agent, .lines = .{ .ctx = &l, .lines = Lines.lines } };
        try testing.expectEqual(c.want, p.decide(ctx, policy.subjectOf(ctx, &fc)).action);
    }
    // No counter: unknown.
    try testing.expectEqual(policy.Action.review, p.decide(.{ .origin = .agent }, policy.subjectOf(.{ .origin = .agent }, &fc)).action);
}

test "policy: autoApply lands auto files, rejects denied ones, and is revertible" {
    const p = try ReviewPolicy.init(gpa, .{ .rules = &.{.{ .paths = &.{"docs/**"}, .action = .auto_accept }} });
    defer p.deinit();
    var blobs: model.MemBlobs = .init(gpa);
    defer blobs.deinit();
    var disk: apply.MemFiles = .init(gpa);
    defer disk.deinit();
    var history: model.History = .init(gpa, null);
    defer history.deinit();
    const q = try model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = blobs.blobs() });
    defer q.deinit();
    var ap: apply.Applier = .init(gpa, testing.io, q, disk.files(), &history);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    try disk.put("docs/a.md", "a\n", false);
    try disk.put("src/b.zig", "b\n", false);
    const b = try q.beginBatch(.{ .origin = .{ .agent = .{ .ref = .{ .session = 9 }, .turn = 1, .model = "m" } }, .label = "Turn 1", .workspace = "/w", .created_ms = 1 });
    var e: ChangeSet = try .fromEdits(gpa, 2, &.{.{ .range = .{ .start = 0, .end = 1 }, .text = "A" }});
    defer e.deinit();
    try q.addEdit(b, "docs/a.md", "a\n", null, &e);
    try q.addEdit(b, "src/b.zig", "b\n", null, &e);
    try q.addCreate(b, "secret.txt", "s\n");
    const id = try q.commitBatch(b, .{});

    var fake: Fake = .{ .deny = "secret.txt" };
    var ctx: policy.PolicyCtx = .of(q.get(id).?);
    ctx.security = fake.security();
    const r = try policy.autoApply(p, ctx, &ap, id, arena.allocator());
    try testing.expectEqual(@as(u32, 1), r.auto_applied);
    try testing.expectEqual(@as(u32, 1), r.denied);
    try testing.expectEqualStrings("A\n", disk.get("docs/a.md").?);
    try testing.expectEqualStrings("b\n", disk.get("src/b.zig").?);
    try testing.expectEqual(@as(?[]const u8, null), disk.get("secret.txt"));
    const cs = q.get(id).?;
    try testing.expect(cs.auto_applied);
    try testing.expectEqual(model.State.partially_applied, cs.state);
    try testing.expectEqual(model.FileState.pending, cs.files[1].state);
    try testing.expectEqual(model.FileState.rejected, cs.files[2].state);

    var recent: std.ArrayList(model.ChangesetId) = .empty;
    defer recent.deinit(gpa);
    try policy.recentlyAutoApplied(q, cs.decided_ms orelse cs.created_ms, std.time.ms_per_day, gpa, &recent);
    try testing.expectEqual(@as(usize, 1), recent.items.len);
    // One-click revert.
    const u = try ap.undoApply(arena.allocator(), r.apply.?);
    try testing.expect(u == .ok);
    try testing.expectEqualStrings("a\n", disk.get("docs/a.md").?);
}

test "policy: E05 ApplyPolicy for open documents" {
    const p = try ReviewPolicy.init(gpa, settings);
    defer p.deinit();
    const Ctxs = struct {
        fake: Fake = .{},
        fn ctxOf(ctx: *anyopaque, _: u64, tool: []const u8) policy.PolicyCtx {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            return .{ .origin = .agent, .agent_name = "docs-writer", .tool = tool, .security = c.fake.security() };
        }
    };
    var c: Ctxs = .{};
    var ep: policy.EditorPolicy = .{ .root = "/w", .ctx_of = Ctxs.ctxOf, .ctx = &c };
    const ap = p.editorPolicy(&ep);
    const sum = struct {
        fn of(uri: []const u8) @import("zg_editor").model.api.agent_edit.ProposalSummary {
            return .{ .tool = "edit_file", .uri = uri, .hunks = 1, .inserted_bytes = 1, .deleted_bytes = 0 };
        }
    }.of;
    const h: @import("zg_editor").model.api.registry.DocHandle = undefined;
    // The line limit is unknown for open documents: the rule does not apply.
    try testing.expectEqual(.pending, ap.decide(ap.ctx, 1, h, sum("file:///w/docs/a.md")));
    c.fake.mode = .accept_edits;
    try testing.expectEqual(.apply, ap.decide(ap.ctx, 1, h, sum("/w/src/main.zig")));
    try testing.expectEqual(.pending, ap.decide(ap.ctx, 1, h, sum("/elsewhere/x.zig")));
    c.fake.mode = .plan;
    try testing.expectEqual(.deny, ap.decide(ap.ctx, 1, h, sum("/w/src/main.zig")));
}

test "policy: decisions are fast" {
    var many: [50]rules.RuleConfig = undefined;
    var names: [50][16]u8 = undefined;
    var paths: [50][1][]const u8 = undefined;
    for (&many, &names, &paths, 0..) |*r, *n, *pp, i| {
        pp[0] = std.fmt.bufPrint(n, "dir{d}/**/*.txt", .{i}) catch unreachable;
        r.* = .{ .paths = &pp.*, .action = if (i % 2 == 0) .auto_accept else .review_required };
    }
    const p = try ReviewPolicy.init(gpa, .{ .rules = &many });
    defer p.deinit();
    const t0 = std.Io.Clock.awake.now(testing.io);
    var auto: u32 = 0;
    for (0..10_000) |i| {
        var buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "dir{d}/sub/file{d}.txt", .{ i % 60, i }) catch unreachable;
        if (p.decide(.{ .origin = .agent }, subj(path, .modify)).action == .auto_apply) auto += 1;
    }
    const ns = t0.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds;
    try testing.expect(auto > 0);
    // 10k decisions with 50 rules; generous for Debug builds and CI.
    try testing.expect(ns < 2 * std.time.ns_per_s);
}
