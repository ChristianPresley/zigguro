//! Tests for the describe pipeline (`describe.zig`).

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const op_mod = @import("../oplog/operation.zig");
const repo_mod = @import("../oplog/repo.zig");
const preview = @import("../oplog/preview.zig");
const fx = @import("../oplog/test_fixture.zig");
const ports = @import("ports.zig");
const describe = @import("describe.zig");
const fake_model = @import("testing/fake_model.zig");
const fake_review = @import("testing/fake_review.zig");
const lt = @import("landing_test.zig");
const ObjectId = id_mod.ObjectId;
const Repo = repo_mod.Repo;
const Allocator = std.mem.Allocator;
const t = std.testing;

const Files = []const [2][]const u8;

/// Trunk `main`: root, "Add parser" (src), "Update docs" (docs), "Fix
/// lexer" (src); then the change to describe on top, as the working copy.
const Built = struct {
    repos: [2]*Repo,
    change: ObjectId,

    fn repo(b: *const Built) *Repo {
        return b.repos[1];
    }

    fn close(b: *Built) void {
        b.repos[1].close();
        b.repos[0].close();
    }
};

fn setup(f: *fx.Fixture, change_files: Files, description: []const u8) !Built {
    const r0 = try f.initRepo();
    errdefer r0.close();
    var tx = try r0.startTransaction(fx.meta("setup"));
    const m = tx.mutRepo();
    const base = [_][2][]const u8{ .{ "src/a.zig", "fn a() void {}\n" }, .{ "docs/x.md", "x\n" } };
    const root = try lt.commit(m, &.{}, "root", &base);
    const c1 = try lt.commit(m, &.{root}, "Add parser", &.{ .{ "src/a.zig", "fn a() void {}\nfn parse() void {}\n" }, .{ "docs/x.md", "x\n" } });
    const c2 = try lt.commit(m, &.{c1}, "Update docs", &.{ .{ "src/a.zig", "fn a() void {}\nfn parse() void {}\n" }, .{ "docs/x.md", "y\n" } });
    const c3 = try lt.commit(m, &.{c2}, "Fix lexer\n\nDetails.", &.{ .{ "src/a.zig", "fn a() void {}\nfn parse() void {}\nfn lex() void {}\n" }, .{ "docs/x.md", "y\n" } });
    var main: ?ObjectId = c3;
    try m.setBookmark("main", fx.target(&main));
    const change = try lt.commit(m, &.{c3}, description, change_files);
    try m.setWcCommit("default", change);
    const r1 = try tx.commit();
    return .{ .repos = .{ r0, r1 }, .change = change };
}

const Stub = struct {
    sessions: []const describe.SessionInfo,

    fn port(s: *Stub) describe.IntentPort {
        return .{ .ctx = s, .sessions = get };
    }

    fn get(ctx: *anyopaque, arena: Allocator, _: ObjectId, _: *const object.Change) anyerror![]const describe.SessionInfo {
        const s: *Stub = @ptrCast(@alignCast(ctx));
        return arena.dupe(describe.SessionInfo, s.sessions);
    }
};

/// Masks "sk-" followed by letters and digits.
const Masker = struct {
    fn port() describe.SecretPort {
        return .{ .ctx = undefined, .redact = redact };
    }

    fn redact(_: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
        if (std.mem.indexOf(u8, text, "sk-") == null) return text;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, "sk-")) |at| {
            try out.appendSlice(arena, text[i..at]);
            try out.appendSlice(arena, "[secret]");
            i = at + 3;
            while (i < text.len and std.ascii.isAlphanumeric(text[i])) i += 1;
        }
        try out.appendSlice(arena, text[i..]);
        return out.items;
    }
};

fn message(ctx: *const describe.DescribeContext) []const u8 {
    return ctx.request.messages[0].text;
}

test "describe: context budget respected (property over random diffs)" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var b = try setup(&f, &.{.{ "src/a.zig", "x\n" }}, "wip");
    defer b.close();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(42);
    const r = prng.random();
    var m = fake_model.FakeModel.init(t.allocator, &.{});
    defer m.deinit();
    var d: describe.Describer = .{ .repo = b.repo(), .model = m.port() };

    var repo = b.repo();
    var opened: std.ArrayList(*Repo) = .empty;
    defer for (opened.items) |x| x.close();
    for (0..25) |round| {
        // A random change: up to 8 files of up to 400 lines each.
        const n_files = r.intRangeAtMost(usize, 1, 8);
        const files = try a.alloc([2][]const u8, n_files);
        for (files, 0..) |*file, i| {
            var text: std.ArrayList(u8) = .empty;
            const lines = r.uintLessThan(usize, 400);
            for (0..lines) |l| try text.print(a, "pub fn f{d}_{d}() u32 {{ return {d}; }}\n", .{ i, l, r.int(u16) });
            file.* = .{ try std.fmt.allocPrint(a, "{s}/f{d}.zig", .{ if (i % 2 == 0) "src" else "lib", i }), text.items };
        }
        var tx = try repo.startTransaction(fx.meta("change"));
        const mr = tx.mutRepo();
        const desc = try std.fmt.allocPrint(a, "round {d}", .{round});
        const c = try lt.commit(mr, &.{b.change}, desc, files);
        repo = try tx.commit();
        try opened.append(a, repo);
        d.repo = repo;
        const max = r.intRangeAtMost(u32, 1200, 12_000);
        const ctx = try d.buildContext(a, c, .{ .max_input_tokens = max });
        try t.expect(ctx.tokens <= max);
        try t.expectEqual(@as(u32, @intCast(n_files + 1)), ctx.stats.files); // + src/a.zig deleted
    }
}

test "describe: lockfiles dropped first" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var lock: std.ArrayList(u8) = .empty;
    for (0..3000) |i| try lock.print(a, "[[package]]\nname = \"crate{d}\"\nversion = \"1.{d}.0\"\n", .{ i, i });
    var b = try setup(&f, &.{
        .{ "Cargo.lock", lock.items },
        .{ "docs/x.md", "y\n" },
        .{ "src/a.zig", "fn a() void {}\nfn parse() void {}\nfn lex() void {}\nfn changed() void {}\n" },
    }, "wip");
    defer b.close();
    var m = fake_model.FakeModel.init(t.allocator, &.{});
    defer m.deinit();
    var d: describe.Describer = .{ .repo = b.repo(), .model = m.port() };
    const ctx = try d.buildContext(a, b.change, .{ .max_input_tokens = 4000 });
    const msg = message(&ctx);
    try t.expect(std.mem.indexOf(u8, msg, "@@ Cargo.lock: +9000 -0 (omitted, generated)") != null);
    try t.expect(std.mem.indexOf(u8, msg, "+fn changed() void {}") != null);
    try t.expect(ctx.tokens <= 4000);
    // With room for everything, the lockfile stays.
    const big = try d.buildContext(a, b.change, .{ .max_input_tokens = 200_000 });
    try t.expect(std.mem.indexOf(u8, message(&big), "+name = \"crate2999\"") != null);
    try t.expectEqual(@as(u32, 0), big.omitted_hunks);
}

test "describe: intent included from session registry stub" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var b = try setup(&f, &.{ .{ "src/a.zig", "fn a() void {}\nfn faster() void {}\n" }, .{ "docs/x.md", "y\n" } }, "wip");
    defer b.close();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var stub: Stub = .{ .sessions = &.{.{ .id = "sess-1", .title = "Parser work", .task_statement = "Make the parser faster", .final_summary = "Inlined the hot loop", .model = "model-x" }} };
    var m = fake_model.FakeModel.init(t.allocator, &.{.{ .json = "{\"subject\":\"Speed up the parser\",\"body\":\"The hot loop is inlined.\",\"trailers\":[{\"key\":\"Agent-Session\",\"value\":\"made-up\"},{\"key\":\"Reviewed-by\",\"value\":\"Ana\"}],\"confidence\":0.8}" }});
    defer m.deinit();
    var d: describe.Describer = .{ .repo = b.repo(), .model = m.port(), .intent = stub.port() };
    const ctx = try d.buildContext(a, b.change, .{});
    const msg = message(&ctx);
    try t.expect(std.mem.indexOf(u8, msg, "### Parser work\nTask: Make the parser faster\nSummary: Inlined the hot loop\n") != null);
    try t.expect(std.mem.indexOf(u8, msg, "## Current description\nwip\n") != null);
    // Conventions: trunk subjects touching src/ (not the docs-only one).
    try t.expect(std.mem.indexOf(u8, msg, "- Fix lexer\n- Add parser\n") != null);
    try t.expect(std.mem.indexOf(u8, msg, "Update docs") == null);
    try t.expectEqualStrings(describe.reply_schema, ctx.request.json_schema.?);

    // "describe: trailers come from provenance": the model's
    // Agent-Session is dropped; the session's ID and model are added.
    const v = try d.generate(a, &ctx, .{}, null);
    try t.expect(!v.issues.any());
    const trs = v.output.trailers;
    try t.expectEqual(@as(usize, 3), trs.len);
    try t.expectEqualStrings("Reviewed-by", trs[0].key);
    try t.expectEqualStrings("Agent-Session", trs[1].key);
    try t.expectEqualStrings("sess-1", trs[1].value);
    try t.expectEqualStrings("Model", trs[2].key);
    try t.expectEqualStrings("model-x", trs[2].value);
    try t.expectEqualStrings("Speed up the parser\n\nThe hot loop is inlined.\n\nReviewed-by: Ana\nAgent-Session: sess-1\nModel: model-x\n", try v.output.text(a));
    // Without trailers, none.
    const plain = try d.generate(a, &ctx, .{ .add_trailers = false }, null);
    try t.expectEqual(@as(usize, 0), plain.output.trailers.len);
}

test "describe: validation/truncation" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const long = "Make the parser handle deeply nested generic parameter lists without recursion";
    var v = try describe.validateDescription(a, .{ .subject = long }, .{}, null);
    try t.expect(v.issues.subject_truncated);
    try t.expectEqualStrings("Make the parser handle deeply nested generic parameter lists without", v.output.subject);
    try t.expect(v.output.subject.len <= 72);

    v = try describe.validateDescription(a, .{ .subject = "Fix it\nbecause it broke", .body = "More." }, .{}, null);
    try t.expect(v.issues.multiline_subject);
    try t.expectEqualStrings("Fix it", v.output.subject);
    try t.expectEqualStrings("because it broke\n\nMore.", v.output.body);

    v = try describe.validateDescription(a, .{ .subject = "  " }, .{}, null);
    try t.expect(v.issues.empty_subject);

    v = try describe.validateDescription(a, .{ .subject = "update parser" }, .{ .style = .conventional }, null);
    try t.expect(v.issues.bad_type);
    v = try describe.validateDescription(a, .{ .subject = "feat(parser)!: drop the old API" }, .{ .style = .conventional }, null);
    try t.expect(!v.issues.any());
    v = try describe.validateDescription(a, .{ .subject = "wip(parser): x" }, .{ .style = .conventional }, null);
    try t.expect(v.issues.bad_type);

    v = try describe.validateDescription(a, .{ .subject = "Rotate key", .body = "Old key sk-abc123 is gone.", .trailers = &.{.{ .key = "Note", .value = "sk-zzz" }} }, .{}, Masker.port());
    try t.expect(v.issues.secret);
    try t.expectEqualStrings("Old key [secret] is gone.", v.output.body);
    try t.expectEqualStrings("[secret]", v.output.trailers[0].value);

    // Secrets never reach the prompt.
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var b = try setup(&f, &.{ .{ "src/a.zig", "const key = \"sk-live123\";\n" }, .{ "docs/x.md", "y\n" } }, "wip");
    defer b.close();
    var m = fake_model.FakeModel.init(t.allocator, &.{.{ .text = "Rotate the key\n\nIt leaked." }});
    defer m.deinit();
    var d: describe.Describer = .{ .repo = b.repo(), .model = m.port(), .secrets = Masker.port() };
    const ctx = try d.buildContext(a, b.change, .{});
    try t.expect(std.mem.indexOf(u8, message(&ctx), "sk-live123") == null);
    try t.expect(std.mem.indexOf(u8, message(&ctx), "+const key = \"[secret]\";") != null);
    // A plain-text reply parses as subject and body, streamed to the UI.
    var ui = fake_model.Collector.init(t.allocator);
    defer ui.deinit();
    var sink = ui.sink();
    const got = try d.generate(a, &ctx, .{}, &sink);
    try t.expectEqualStrings("Rotate the key", got.output.subject);
    try t.expectEqualStrings("It leaked.", got.output.body);
    try t.expectEqualStrings("Rotate the key\n\nIt leaked.", ui.text.items);
    try t.expectEqual(ports.StopReason.end, ui.stop.?);
}

test "describe: proposal requires approval (deny-all review port)" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var b = try setup(&f, &.{ .{ "src/a.zig", "fn b() void {}\n" }, .{ "docs/x.md", "y\n" } }, "wip");
    defer b.close();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var m = fake_model.FakeModel.init(t.allocator, &.{.{ .json = "{\"subject\":\"Rename a to b\",\"body\":\"\",\"trailers\":[],\"confidence\":0.9}" }});
    defer m.deinit();
    var review = fake_review.FakeReview.init(t.allocator, .deny_all);
    defer review.deinit();
    var d: describe.Describer = .{ .repo = b.repo(), .model = m.port(), .review = review.port() };
    const p = try d.propose(a, b.change, .{ .model = "model-x" }, fx.meta("describe"), null);
    try t.expectEqual(@as(ports.ReviewId, 1), p.outcome.in_review);
    const it = review.item(1).?;
    try t.expectEqual(ports.ProposalKind.describe, it.kind);
    try t.expectEqualStrings("Rename a to b", it.summary);
    try t.expect(it.changes[0].eql(p.commit));
    try t.expectEqual(ports.ReviewStatus.rejected, review.port().statusOf(1));
    // Nothing visible changed: the working copy keeps its description.
    const repo = b.repo();
    const wc = try op_mod.read(object.Change, f.store, a, repo.view().wcCommit("default").?);
    try t.expectEqualStrings("wip", wc.description);
    const pending = try preview.list(repo, t.allocator);
    defer t.allocator.free(pending);
    try t.expectEqual(@as(usize, 1), pending.len);
    // In the preview, the description is the proposal.
    const c = try op_mod.read(object.Change, f.store, a, p.commit);
    try t.expectEqualStrings("Rename a to b\n", c.description);
    // Without a review port (and no auto_apply), nothing is proposed.
    d.review = null;
    try t.expectError(error.NoReviewPort, d.propose(a, b.change, .{}, fx.meta("describe"), null));
}

test "describe: auto_apply path" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var b = try setup(&f, &.{ .{ "src/a.zig", "fn b() void {}\n" }, .{ "docs/x.md", "y\n" } }, "wip");
    defer b.close();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var stub: Stub = .{ .sessions = &.{.{ .id = "sess-9", .model = "model-y" }} };
    var m = fake_model.FakeModel.init(t.allocator, &.{ .{ .json = "{\"subject\":\"Rename a to b\"," }, .{ .json = "\"body\":\"Clearer.\",\"trailers\":[],\"confidence\":0.9}" } });
    defer m.deinit();
    var d: describe.Describer = .{ .repo = b.repo(), .model = m.port(), .intent = stub.port() };
    const p = try d.propose(a, b.change, .{ .auto_apply = true }, fx.meta("describe"), null);
    const head = p.outcome.applied;
    const r2 = try b.repo().reopen(head, false);
    defer r2.close();
    const wc = try op_mod.read(object.Change, f.store, a, r2.view().wcCommit("default").?);
    try t.expectEqualStrings("Rename a to b\n\nClearer.\n\nAgent-Session: sess-9\nModel: model-y\n", wc.description);
    try t.expectEqualSlices(ObjectId, &.{b.change}, wc.predecessors);
    const left = try preview.list(r2, t.allocator);
    defer t.allocator.free(left);
    try t.expectEqual(@as(usize, 0), left.len);
}

test "describe: golden prompt render" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var b = try setup(&f, &.{ .{ "src/a.zig", "fn a() void {}\nfn parse() void {}\nfn lex2() void {}\n" }, .{ "docs/x.md", "y\n" } }, "");
    defer b.close();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var m = fake_model.FakeModel.init(t.allocator, &.{});
    defer m.deinit();
    var d: describe.Describer = .{ .repo = b.repo(), .model = m.port() };
    const ctx = try d.buildContext(a, b.change, .{ .style = .conventional, .max_subject = 50, .language = "English" });
    try t.expectEqualStrings(
        \\Write the description of one change in a version-controlled repository.
        \\
        \\Say why the change was made, not only what it does: the problem, the
        \\approach, and anything a reviewer should know. Do not invent issue
        \\numbers, links, people or test results that the context below does not
        \\show.
        \\
        \\Write the subject as a Conventional Commit, `type(scope): summary`, where
        \\type is one of feat, fix, docs, style, refactor, perf, test, build, ci,
        \\chore or revert.
        \\The subject is one line of at most 50 characters, in the
        \\imperative mood, with no trailing period. The body explains the change in
        \\short wrapped paragraphs; leave it empty for a trivial change.
        \\Write in English.
        \\
        \\Reply with JSON matching the schema: `subject`, `body`, `trailers` (a list
        \\of `{key, value}`; leave out session and model trailers, they are added
        \\for you) and `confidence` (0 to 1).
        \\
        \\## Change
        \\1 file changed, 1 insertion(+), 1 deletion(-)
        \\
        \\## Recent subjects in the same directories (match their style)
        \\- Fix lexer
        \\- Add parser
        \\
        \\
        \\## Diff
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -1,3 +1,3 @@
        \\ fn a() void {}
        \\ fn parse() void {}
        \\-fn lex() void {}
        \\+fn lex2() void {}
        \\
        \\
    , message(&ctx));
}
