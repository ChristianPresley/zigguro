//! Revset tests: the parse table (precedence, printing, errors with
//! spans), evaluation of every function on a small fixture graph, alias
//! expansion limits, deadlines, and the parser fuzz target.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const enc = @import("../store/encode.zig");
const index = @import("index.zig");
const test_repo = @import("test_repo.zig");
const view_mod = @import("../oplog/view.zig");
const revset = @import("revset.zig");
const functions = revset.functions;
const ObjectId = id_mod.ObjectId;
const Pos = index.Pos;
const t = std.testing;

fn printed(arena: std.mem.Allocator, src: []const u8) ![]const u8 {
    var diag: revset.ParseError = .{};
    const n = revset.parse(arena, src, &diag) catch |e| {
        std.debug.print("parse failed for `{s}`: {f}\n", .{ src, diag });
        return e;
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try revset.ast.format(n, &aw.writer);
    // Printing parses back to the same tree.
    const again = try revset.parse(arena, aw.written(), &diag);
    try t.expect(revset.ast.eql(n, again));
    return aw.written();
}

test "revset: parse table" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ok = [_][2][]const u8{
        .{ "main", "main" },
        .{ "@", "@" },
        .{ "@-", "@-" },
        .{ "@--+", "@--+" },
        .{ "ws@", "ws@" },
        .{ "main@origin", "main@origin" },
        .{ "release-1.2", "release-1.2" },
        .{ "release-1.2-", "release-1.2-" },
        .{ "feature/x", "feature/x" },
        .{ "\"a b\"", "\"a b\"" },
        .{ "'raw\\n'", "\"raw\\\\n\"" },
        .{ "\"q\\\"x\"", "\"q\\\"x\"" },
        .{ "\"a b\"@origin", "\"a b\"@origin" },
        .{ "a | b", "a | b" },
        .{ "a & b", "a & b" },
        .{ "a ~ b", "a ~ b" },
        .{ "a | b & c", "a | (b & c)" },
        .{ "a & b | c", "(a & b) | c" },
        .{ "a | b ~ c", "a | (b ~ c)" },
        .{ "a ~ b & c", "a ~ (b & c)" },
        .{ "a & b ~ c", "(a & b) ~ c" },
        .{ "a ~ b ~ c", "(a ~ b) ~ c" },
        .{ "a | b | c", "(a | b) | c" },
        .{ "~a", "~a" },
        .{ "~a & b", "(~a) & b" },
        .{ "~~a", "~(~a)" },
        .{ "a & ~b", "a & (~b)" },
        .{ "a ~ ~b", "a ~ (~b)" },
        .{ "~a::b", "~(a::b)" },
        .{ "::a", "::a" },
        .{ "a::", "a::" },
        .{ "a::b", "a::b" },
        .{ "..a", "..a" },
        .{ "a..", "a.." },
        .{ "a..b", "a..b" },
        .{ "::", "::" },
        .{ ":: & a", "(::) & a" },
        .{ "::a-", "::(a-)" },
        .{ "a-::b+", "(a-)::(b+)" },
        .{ "(a..b)-", "(a..b)-" },
        .{ "a:: | b", "(a::) | b" },
        .{ "a.. & b", "(a..) & b" },
        .{ "(a | b) & c", "(a | b) & c" },
        .{ "((a))", "a" },
        .{ "all()", "all()" },
        .{ "heads(a | b)", "heads(a | b)" },
        .{ "ancestors(@, 3)", "ancestors(@, 3)" },
        .{ "description(glob:\"fix*\")", "description(glob:\"fix*\")" },
        .{ "author(exact:alice)", "author(exact:\"alice\")" },
        .{ "files(\"src/main.zig\")", "files(src/main.zig)" },
        .{ "f( a , b )", "f(a, b)" },
        .{ "f(g(h()))", "f(g(h()))" },
        .{ "trunk()..@", "trunk()..@" },
        .{ "(trunk()..@)::", "(trunk()..@)::" },
        .{ "abc123", "abc123" },
        .{ "kxyz", "kxyz" },
        .{ "  a  ", "a" },
        .{ "a+-", "a+-" },
        .{ "\"\\x41\"", "A" },
        .{ "x::y & z", "(x::y) & z" },
    };
    for (ok) |c| {
        const got = try printed(a, c[0]);
        t.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("input: {s}\n", .{c[0]});
            return e;
        };
    }

    const bad = [_]struct { []const u8, u32, u32 }{
        .{ "", 0, 0 },
        .{ "a |", 3, 3 },
        .{ "| a", 0, 1 },
        .{ "a b", 2, 3 },
        .{ "(a", 2, 2 },
        .{ "a)", 1, 2 },
        .{ "f(a", 3, 3 },
        .{ "f(a,)", 4, 5 },
        .{ "a::b::c", 4, 6 },
        .{ "a..b..c", 4, 6 },
        .{ "::a::b", 3, 5 },
        .{ "..", 0, 2 },
        .{ "a $ b", 2, 3 },
        .{ "\"open", 0, 5 },
        .{ "\"bad\\q\"", 4, 6 },
        .{ "glob:", 5, 5 },
        .{ "a &", 3, 3 },
        .{ "~", 1, 1 },
        .{ "a , b", 2, 3 },
        .{ "@@", 1, 2 },
    };
    for (bad) |c| {
        var diag: revset.ParseError = .{};
        try t.expectError(error.ParseFailed, revset.parse(a, c[0], &diag));
        t.expectEqual([2]u32{ c[1], c[2] }, diag.span) catch |e| {
            std.debug.print("input: `{s}`: {f}\n", .{ c[0], diag });
            return e;
        };
        try t.expect(diag.message.len > 0);
    }

    // Deep nesting is refused, not a stack overflow.
    const deep = try a.alloc(u8, 2000);
    @memset(deep[0..1000], '(');
    @memset(deep[1000..], ')');
    var diag: revset.ParseError = .{};
    try t.expectError(error.ParseFailed, revset.parse(a, deep, &diag));
}

test "revset: unknown functions suggest a name" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var al = try revset.Aliases.withDefaults(t.allocator);
    defer al.deinit();
    const cases = [_]struct { []const u8, ?[]const u8, [2]u32 }{
        .{ "x & descendents(y)", "descendants", .{ 4, 15 } },
        .{ "hed(x)", "heads", .{ 0, 3 } },
        .{ "mutabl()", "mutable", .{ 0, 6 } },
        .{ "frobnicate()", null, .{ 0, 10 } },
    };
    for (cases) |c| {
        var diag: revset.ParseError = .{};
        const n = try revset.parse(a, c[0], &diag);
        try t.expectError(error.ParseFailed, al.expand(a, n, &diag));
        try t.expectEqual(c[2], diag.span);
        if (c[1]) |s| try t.expectEqualStrings(s, diag.suggestion.?) else try t.expect(diag.suggestion == null);
    }
    var diag: revset.ParseError = .{};
    try t.expectError(error.ParseFailed, al.expand(a, try revset.parse(a, "heads()", &diag), &diag));
    try t.expectEqualStrings("`heads` takes 1 argument", diag.message);
    try t.expectError(error.ParseFailed, al.expand(a, try revset.parse(a, "ancestors(a, 1, 2)", &diag), &diag));
    try t.expectEqualStrings("`ancestors` takes 1 to 2 arguments", diag.message);
}

test "revset: aliases recursion limit" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var al = revset.Aliases.init(t.allocator);
    defer al.deinit();
    var diag: revset.ParseError = .{};
    try al.put("f(x)", "f(x) | x", &diag);
    try al.put("ping", "pong", &diag);
    try al.put("pong", "ping", &diag);
    try al.put("twice(x)", "x | x", &diag);
    try al.put("my_head", "heads(twice(main))", &diag);

    try t.expectError(error.ParseFailed, al.expand(a, try revset.parse(a, "f(a)", &diag), &diag));
    try t.expect(std.mem.indexOf(u8, diag.message, "32 levels") != null);
    try t.expectEqual([2]u32{ 0, 4 }, diag.span);
    try t.expectError(error.ParseFailed, al.expand(a, try revset.parse(a, "x | ping", &diag), &diag));
    try t.expectEqual([2]u32{ 4, 8 }, diag.span);

    const out = try al.expand(a, try revset.parse(a, "my_head & twice(@)", &diag), &diag);
    var aw: std.Io.Writer.Allocating = .init(a);
    try revset.ast.format(out, &aw.writer);
    try t.expectEqualStrings("heads(main | main) & (@ | @)", aw.written());

    // Bad declarations and bodies.
    try t.expectError(error.ParseFailed, al.put("g(x, x)", "x", &diag));
    try t.expectError(error.ParseFailed, al.put("g(", "x", &diag));
    try t.expectError(error.ParseFailed, al.put("h", "a |", &diag));
    // Wrong arity for an alias-only name.
    try t.expectError(error.ParseFailed, al.expand(a, try revset.parse(a, "twice()", &diag), &diag));
    // Errors inside an alias body point at the use site.
    try al.put("broken()", "nosuchfn()", &diag);
    try t.expectError(error.ParseFailed, al.expand(a, try revset.parse(a, "a | broken()", &diag), &diag));
    try t.expectEqual([2]u32{ 4, 12 }, diag.span);
    try t.expect(std.mem.startsWith(u8, diag.message, "in alias `broken`"));
}

test "revset: patterns" {
    const P = functions.Pattern;
    try t.expect((try P.parse("", "fix")).matches("a fix here"));
    try t.expect(!(try P.parse("exact", "fix")).matches("a fix here"));
    try t.expect((try P.parse("exact-i", "FIX")).matches("fix"));
    try t.expect((try P.parse("substring-i", "FIX")).matches("a fix"));
    try t.expectError(error.Unavailable, P.parse("regex", "x"));
    try t.expectError(error.UnknownPatternKind, P.parse("blob", "x"));
    const g = functions.globMatch;
    try t.expect(g("*.zig", "main.zig", false));
    try t.expect(!g("*.zig", "src/main.zig", false));
    try t.expect(g("**/*.zig", "src/main.zig", false));
    try t.expect(g("**/*.zig", "main.zig", false));
    try t.expect(g("src/**", "src/a/b/c", false));
    try t.expect(g("s?c/[a-m]ain.zig", "src/main.zig", false));
    try t.expect(!g("s?c/[!m]ain.zig", "src/main.zig", false));
    try t.expect(g("FIX*", "fix-1", true));
    try t.expect(!g("a*b", "a/b", false));
    try t.expect(g("a**b", "a/x/b", false));
    try t.expect(g("", "", false));
    try t.expect(!g("", "x", false));
    const pp: P = .{ .kind = .exact, .text = "src", .path_prefix = true };
    try t.expect(pp.matches("src") and pp.matches("src/a.zig") and !pp.matches("srcs/a.zig"));
}

/// The fixture:
///
///     d       (@, head)        x   (side, head)
///     |                        |
///     m   merge of b and c     |
///    / \                       |
///   b   c (empty)   h (hidden) |
///    \ /           /           |
///     a ----------'            |
///     |                        |
///     r  root  -----------------'
const Fixture = struct {
    repo: *test_repo.Repo,
    ix: *index.CommitIndex,
    view: view_mod.View,
    names: std.AutoHashMapUnmanaged(ObjectId, []const u8) = .empty,
    ids: std.StringHashMapUnmanaged(ObjectId) = .empty,
    arena_state: std.heap.ArenaAllocator,
    terms: [16]?ObjectId = undefined,
    ref_ids: [8]?ObjectId = undefined,

    fn init(gpa: std.mem.Allocator) !*Fixture {
        const f = try gpa.create(Fixture);
        errdefer gpa.destroy(f);
        const r = try test_repo.Repo.init(gpa);
        f.* = .{ .repo = r, .ix = undefined, .view = .empty, .arena_state = .init(gpa) };
        const a = f.arena_state.allocator();

        // Trees: t1 = {src/main.zig}, t2 = {README, src/main.zig (changed)}.
        if (r.batch == null) r.batch = r.store.batch();
        const b = &r.batch.?;
        const blob1 = try b.put(.blob, "one");
        const blob2 = try b.put(.blob, "two");
        const readme = try b.put(.blob, "readme");
        const src1 = try putTree(gpa, b, &.{.{ .name = "main.zig", .kind = .file, .id = blob1 }});
        const src2 = try putTree(gpa, b, &.{.{ .name = "main.zig", .kind = .file, .id = blob2 }});
        const t1 = try putTree(gpa, b, &.{.{ .name = "src", .kind = .tree, .id = src1 }});
        const t2 = try putTree(gpa, b, &.{ .{ .name = "README", .kind = .file, .id = readme }, .{ .name = "src", .kind = .tree, .id = src2 } });
        const t0 = try putTree(gpa, b, &.{});

        const root = try f.add("r", .{ .tree_terms = &.{t0}, .time_ms = 1, .description = "root" });
        const ca = try f.add("a", .{ .parents = &.{root}, .tree_terms = &.{t1}, .time_ms = 2, .description = "add main" });
        const cb = try f.add("b", .{ .parents = &.{ca}, .tree_terms = &.{t2}, .time_ms = 3, .description = "fix readme", .signed = true });
        const cc = try f.add("c", .{ .parents = &.{ca}, .tree_terms = &.{t1}, .time_ms = 5, .description = "nothing" });
        const cm = try f.add("m", .{ .parents = &.{ cb, cc }, .tree_terms = &.{t2}, .time_ms = 6, .description = "merge" });
        const cd = try f.add("d", .{ .parents = &.{cm}, .tree_terms = &.{t2}, .time_ms = 7, .description = "work in progress" });
        const ch = try f.add("h", .{ .parents = &.{ca}, .tree_terms = &.{t2}, .time_ms = 4, .description = "hidden fix" });
        const cx = try f.add("x", .{ .parents = &.{root}, .tree_terms = &.{t1}, .time_ms = 8, .description = "side quest", .preds = &.{ch} });
        try r.flush();
        f.ix = try r.openIndex(null);
        try f.ix.ensureIndexed(&.{ cd, cx, ch });

        f.terms = .{ cm, cx, cb, ca, cd, null, cx, ca, cb, null, null, null, null, null, null, null };
        var heads = [_]ObjectId{ cd, cx };
        std.mem.sort(ObjectId, &heads, {}, ObjectId.lessThan);
        f.view.heads = try a.dupe(ObjectId, &heads);
        f.view.bookmarks = try a.dupe(view_mod.NamedRef, &.{
            .{ .name = "conflicted", .target = .{ .terms = f.terms[6..9] } },
            .{ .name = "main", .target = .normal(&f.terms[0]) },
            .{ .name = "side", .target = .normal(&f.terms[1]) },
        });
        f.view.remote_bookmarks = try a.dupe(view_mod.RemoteBookmark, &.{
            .{ .remote = "origin", .name = "main", .target = .normal(&f.terms[2]), .tracked = false },
            .{ .remote = "upstream", .name = "side", .target = .normal(&f.terms[1]), .tracked = true },
        });
        f.view.tags = try a.dupe(view_mod.NamedRef, &.{.{ .name = "v1", .target = .normal(&f.terms[3]) }});
        // Git refs named after the commits, so tests can write `a` instead
        // of an ID (single letters would otherwise be ID prefixes).
        var refs: std.ArrayList(view_mod.NamedRef) = .empty;
        for ([_][]const u8{ "a", "b", "c", "d", "h", "m", "r", "x" }, 0..) |name, k| {
            f.ref_ids[k] = f.ids.get(name).?;
            try refs.append(a, .{ .name = name, .target = .normal(&f.ref_ids[k]) });
        }
        f.view.git_refs = refs.items;
        f.view.wc_commits = try a.dupe(view_mod.WcCommit, &.{ .{ .workspace = "default", .commit = cd }, .{ .workspace = "other", .commit = cc } });
        f.view.lanes = try a.dupe(view_mod.LaneRecord, &.{.{ .name = "lane-1", .workspace = "other", .owner = "agent", .base = root, .status = "", .policy = "", .updated_ms = 0, .extra = &.{} }});
        return f;
    }

    fn deinit(f: *Fixture, gpa: std.mem.Allocator) void {
        f.names.deinit(gpa);
        f.ids.deinit(gpa);
        f.ix.close();
        f.repo.deinit();
        f.arena_state.deinit();
        gpa.destroy(f);
    }

    fn add(f: *Fixture, name: []const u8, c: test_repo.Repo.Commit) !ObjectId {
        const gpa = f.repo.gpa;
        const id = try f.repo.commit(c);
        try f.names.put(gpa, id, name);
        try f.ids.put(gpa, name, id);
        return id;
    }

    fn ctx(f: *Fixture) revset.EvalContext {
        return .{ .graph = f.ix.view, .view = &f.view, .store = f.repo.store, .io = t.io, .user_email = "t@example.com" };
    }

    /// Evaluates `src` and returns the commit names, space separated.
    fn names_of(f: *Fixture, src: []const u8, c: *const revset.EvalContext) ![]const u8 {
        var diag: revset.ParseError = .{};
        var it = revset.evaluate(t.allocator, c, src, &diag) catch |e| {
            std.debug.print("`{s}`: {f}\n", .{ src, diag });
            return e;
        };
        defer it.deinit();
        const ps = try it.collect(t.allocator, null);
        defer t.allocator.free(ps);
        var out: std.ArrayList(u8) = .empty;
        const a = f.arena_state.allocator();
        for (ps, 0..) |p, i| {
            if (i > 0) try out.append(a, ' ');
            try out.appendSlice(a, f.names.get(f.ix.view.id(p)).?);
        }
        return out.items;
    }
};

fn putTree(gpa: std.mem.Allocator, b: anytype, entries: []const object.TreeEntry) !ObjectId {
    const bytes = try enc.encodeAlloc(gpa, object.Tree, .{ .entries = entries });
    defer gpa.free(bytes);
    return b.put(.tree, bytes);
}

const FakeProv = struct {
    agent_commit: ObjectId,

    fn hasAgentLines(ctx: *anyopaque, commit: ObjectId, p: ?functions.Pattern) anyerror!bool {
        const s: *FakeProv = @ptrCast(@alignCast(ctx));
        if (!commit.eql(s.agent_commit)) return false;
        return p == null or p.?.matches("claude");
    }

    fn inSession(ctx: *anyopaque, commit: ObjectId, session: []const u8) anyerror!bool {
        const s: *FakeProv = @ptrCast(@alignCast(ctx));
        return commit.eql(s.agent_commit) and std.mem.eql(u8, session, "s1");
    }

    fn isReviewed(ctx: *anyopaque, commit: ObjectId) anyerror!bool {
        const s: *FakeProv = @ptrCast(@alignCast(ctx));
        return !commit.eql(s.agent_commit);
    }

    fn blame(ctx: *anyopaque, arena: std.mem.Allocator, path: []const u8, line: u32) anyerror![]const ObjectId {
        const s: *FakeProv = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, path, "src/main.zig") or line != 1) return &.{};
        return arena.dupe(ObjectId, &.{s.agent_commit});
    }
};

test "revset: eval on fixture graph" {
    const gpa = t.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const c = f.ctx();
    const cases = [_][2][]const u8{
        .{ "all()", "x d m c b a r" },
        .{ "::", "x d m c b a r" },
        .{ "none()", "" },
        .{ "@", "d" },
        .{ "@-", "m" },
        .{ "@--", "c b" },
        .{ "other@", "c" },
        .{ "main", "m" },
        .{ "v1", "a" },
        .{ "main@origin", "b" },
        .{ "conflicted", "x b" },
        .{ "root()", "r" },
        .{ "visible_heads()", "x d" },
        .{ "heads(all())", "x d" },
        .{ "heads(a | b | c)", "c b" },
        .{ "roots(b | c | m)", "c b" },
        .{ "roots(all())", "r" },
        .{ "parents(m | x)", "c b r" },
        .{ "children(a)", "c b" },
        .{ "children(r)", "x a" },
        .{ "a+", "c b" },
        .{ "ancestors(m)", "m c b a r" },
        .{ "ancestors(m, 2)", "m c b" },
        .{ "ancestors(m, 0)", "" },
        .{ "descendants(b)", "d m b" },
        .{ "descendants(a, 2)", "c b a" },
        .{ "::b", "b a r" },
        .{ "b::", "d m b" },
        .{ "a::m", "m c b a" },
        .{ "b..d", "d m c" },
        .{ "..b", "b a" },
        .{ "m..", "x d" },
        .{ "~(::m)", "x d" },
        .{ "a | x", "x a" },
        .{ "all() & ::b", "b a r" },
        .{ "all() ~ ::b", "x d m c" },
        .{ "description(fix)", "b" },
        .{ "description(exact:merge)", "m" },
        .{ "description(glob:\"*progress\")", "d" },
        .{ "description(substring-i:FIX)", "b" },
        .{ "author(t)", "x d m c b a r" },
        .{ "committer(nobody)", "" },
        .{ "mine()", "x d m c b a r" },
        .{ "empty()", "d c r" },
        .{ "conflicts()", "" },
        .{ "signed()", "b" },
        .{ "files(src)", "x b a" },
        .{ "files(README)", "b" },
        .{ "files(glob:\"**/*.zig\")", "x b a" },
        .{ "files(exact:\"src/main.zig\")", "x b a" },
        .{ "bookmarks()", "x m b" },
        .{ "bookmarks(exact:main)", "m" },
        .{ "remote_bookmarks()", "x b" },
        .{ "remote_bookmarks(main, origin)", "b" },
        .{ "remote_bookmarks(side, origin)", "" },
        .{ "untracked_remote_bookmarks()", "b" },
        .{ "tags()", "a" },
        .{ "tags(v2)", "" },
        .{ "trunk()", "b" },
        .{ "immutable()", "b a r" },
        .{ "mutable()", "x d m c" },
        .{ "stack()", "d m c" },
        .{ "stack(c)", "d m c" },
        .{ "present(nosuch)", "" },
        .{ "present(main)", "m" },
        .{ "latest(all())", "x" },
        .{ "latest(a | b | c, 2)", "c b" },
        .{ "fork_point(d | x)", "r" },
        .{ "fork_point(b | c)", "a" },
        .{ "fork_point(m)", "m" },
        .{ "divergent()", "" },
        .{ "lane()", "c a" },
        .{ "lane(nope)", "" },
        .{ "evolog(x)", "x h" },
        .{ "a..d & empty()", "d c" },
        .{ "(b | c) & description(fix)", "b" },
    };
    for (cases) |cs| {
        const got = try f.names_of(cs[0], &c);
        t.expectEqualStrings(cs[1], got) catch |e| {
            std.debug.print("revset `{s}`\n", .{cs[0]});
            return e;
        };
    }

    // Commit and change ID prefixes.
    const vw = f.ix.view;
    var hex: [64]u8 = undefined;
    const b_id = f.ids.get("b").?;
    const b_hex = b_id.hex(&hex)[0..12];
    try t.expectEqualStrings("b", try f.names_of(b_hex, &c));
    const cid = vw.changeId(vw.pos(f.ids.get("m").?).?);
    var cbuf: [32]u8 = undefined;
    const cid_text = cid.reverseHex(&cbuf);
    try t.expectEqualStrings("m", try f.names_of(cid_text[0..12], &c));
    // The hidden commit resolves by commit ID, not by change ID.
    const h_id = f.ids.get("h").?;
    try t.expectEqualStrings("h", try f.names_of(h_id.hex(&hex), &c));
    const h_cid = vw.changeId(vw.pos(h_id).?);
    var diag: revset.ParseError = .{};
    try t.expectError(error.UnknownSymbol, revset.evaluate(gpa, &c, h_cid.reverseHex(&cbuf), &diag));

    // Unknown symbols suggest a bookmark or tag.
    try t.expectError(error.UnknownSymbol, revset.evaluate(gpa, &c, "x | mian", &diag));
    try t.expectEqual([2]u32{ 4, 8 }, diag.span);
    try t.expectEqualStrings("main", diag.suggestion.?);
    try t.expectError(error.UnknownSymbol, revset.evaluate(gpa, &c, "main@orgin", &diag));
    try t.expectEqualStrings("main@origin", diag.suggestion.?);
    try t.expectError(error.UnknownSymbol, revset.evaluate(gpa, &c, "nows@", &diag));
    try t.expectError(error.InvalidArgument, revset.evaluate(gpa, &c, "description(blob:x)", &diag));
    try t.expectEqualStrings("glob", diag.suggestion.?);
    try t.expectError(error.Unavailable, revset.evaluate(gpa, &c, "description(regex:x)", &diag));
    try t.expectError(error.InvalidArgument, revset.evaluate(gpa, &c, "ancestors(@, many)", &diag));

    // Providers.
    for ([_][]const u8{ "agent()", "human()", "session(s1)", "reviewed()", "unreviewed()", "why(a, 1)" }) |src| {
        try t.expectError(error.Unavailable, revset.evaluate(gpa, &c, src, &diag));
    }
    var fake: FakeProv = .{ .agent_commit = f.ids.get("b").? };
    const prov: functions.ProvenanceQuery = .{ .ctx = &fake, .hasAgentLines = FakeProv.hasAgentLines, .inSession = FakeProv.inSession };
    const review: functions.ReviewQuery = .{ .ctx = &fake, .isReviewed = FakeProv.isReviewed };
    const search: functions.HistorySearch = .{ .ctx = &fake, .blame = FakeProv.blame };
    var c2 = c;
    c2.prov = &prov;
    c2.review = &review;
    c2.search = &search;
    try t.expectEqualStrings("b", try f.names_of("agent()", &c2));
    try t.expectEqualStrings("b", try f.names_of("agent(claude)", &c2));
    try t.expectEqualStrings("", try f.names_of("agent(gpt)", &c2));
    try t.expectEqualStrings("x d m c a r", try f.names_of("human()", &c2));
    try t.expectEqualStrings("b", try f.names_of("session(s1)", &c2));
    try t.expectEqualStrings("b", try f.names_of("unreviewed()", &c2));
    try t.expectEqualStrings("m c", try f.names_of("reviewed() & (b | c | m)", &c2));
    try t.expectEqualStrings("b", try f.names_of("why(\"src/main.zig\", 1)", &c2));

    // Aliases from the caller replace the defaults.
    var al = try revset.Aliases.withDefaults(gpa);
    defer al.deinit();
    try al.put("trunk()", "side", &diag);
    try al.put("wip", "description(progress)", &diag);
    var c3 = c;
    c3.aliases = &al;
    try t.expectEqualStrings("x b a r", try f.names_of("immutable()", &c3));
    try t.expectEqualStrings("x", try f.names_of("trunk()", &c3));
    try t.expectEqualStrings("d", try f.names_of("wip", &c3));
}

test "revset: touched_by_op and divergence" {
    const gpa = t.allocator;
    const fx = @import("../oplog/test_fixture.zig");
    const op_mod = @import("../oplog/operation.zig");
    var f = try fx.Fixture.init(gpa);
    defer f.deinit();
    const r0 = try f.initRepo();
    var tx = try r0.startTransaction(fx.meta("one"));
    const c1 = try fx.change(tx.mutRepo(), &.{}, "one");
    const r1 = try tx.commit();
    r0.close();
    defer r1.close();
    tx = try r1.startTransaction(fx.meta("two"));
    const c2 = try fx.change(tx.mutRepo(), &.{c1}, "two");
    const r2 = try tx.commit();
    defer r2.close();
    // A second commit with c2's change ID: divergent.
    tx = try r2.startTransaction(fx.meta("dup"));
    var dup = try op_mod.read(object.Change, f.store, tx.arena(), c2);
    dup.description = "two, again";
    const c3 = try tx.mutRepo().writeChange(dup);
    try tx.mutRepo().addHead(c2);
    const r3 = try tx.commit();
    defer r3.close();

    var ix_dir = try f.tmp.dir.createDirPathOpen(f.io, "index", .{ .open_options = .{ .iterate = true } });
    defer ix_dir.close(f.io);
    const ix = try index.CommitIndex.open(gpa, f.io, ix_dir, f.store, .{ .fsync = false });
    defer ix.close();
    try ix.ensureIndexed(r3.view().heads);
    const c: revset.EvalContext = .{ .graph = ix.view, .view = r3.view(), .store = f.store, .io = f.io };
    var hex: [64]u8 = undefined;
    var buf: [128]u8 = undefined;
    const src = try std.fmt.bufPrint(&buf, "touched_by_op({s})", .{r3.op().hex(&hex)});
    var diag: revset.ParseError = .{};
    var it = try revset.evaluate(gpa, &c, src, &diag);
    defer it.deinit();
    const ps = try it.collect(gpa, null);
    defer gpa.free(ps);
    try t.expectEqual(@as(usize, 1), ps.len);
    try t.expect(ix.view.id(ps[0]).eql(c3));

    var it2 = try revset.evaluate(gpa, &c, "divergent()", &diag);
    defer it2.deinit();
    const ds = try it2.collect(gpa, null);
    defer gpa.free(ds);
    try t.expectEqual(@as(usize, 2), ds.len);
    try t.expectError(error.InvalidArgument, revset.evaluate(gpa, &c, "touched_by_op(abc)", &diag));
}

test "revset: deadline stops eval" {
    const gpa = t.allocator;
    const r = try test_repo.Repo.init(gpa);
    defer r.deinit();
    var prng: std.Random.DefaultPrng = .init(5);
    const ids = try test_repo.randomDag(r, prng.random(), 20_000);
    defer gpa.free(ids);
    const ix = try r.openIndex(null);
    defer ix.close();
    try ix.ensureIndexed(ids);
    // Every commit is a head, so all() is the whole DAG.
    const heads = try gpa.dupe(ObjectId, ids);
    defer gpa.free(heads);
    std.mem.sort(ObjectId, heads, {}, ObjectId.lessThan);
    var v: view_mod.View = .empty;
    v.heads = heads;
    var c: revset.EvalContext = .{ .graph = ix.view, .view = &v, .store = r.store, .io = t.io, .deadline = .after(t.io, .zero) };
    var diag: revset.ParseError = .{};
    var it = try revset.evaluate(gpa, &c, "all() & description(nothing-matches-this)", &diag);
    defer it.deinit();
    try t.expectError(error.DeadlineExceeded, it.collect(gpa, null));
    // Without a deadline it completes.
    c.deadline = null;
    var it2 = try revset.evaluate(gpa, &c, "::", &diag);
    defer it2.deinit();
    const all = try it2.collect(gpa, null);
    defer gpa.free(all);
    try t.expectEqual(@as(usize, 20_000), all.len);
    for (1..all.len) |i| try t.expect(all[i - 1].int() > all[i].int());
}

test "revset: lazy range walks match materialized sets (random DAG)" {
    const gpa = t.allocator;
    const r = try test_repo.Repo.init(gpa);
    defer r.deinit();
    var prng: std.Random.DefaultPrng = .init(17);
    const rng = prng.random();
    const ids = try test_repo.randomDag(r, rng, 3000);
    defer gpa.free(ids);
    const ix = try r.openIndex(null);
    defer ix.close();
    try ix.ensureIndexed(ids);
    const vw = ix.view;
    // Ancestor bitsets from the parents.
    const sets = try gpa.alloc(std.DynamicBitSetUnmanaged, vw.count);
    defer {
        for (sets) |*s| s.deinit(gpa);
        gpa.free(sets);
    }
    for (sets, 0..) |*s, k| {
        s.* = try .initEmpty(gpa, vw.count);
        s.set(k);
        var ps = vw.parents(Pos.of(@intCast(k)));
        while (ps.next()) |p| s.setUnion(sets[p.int()]);
    }
    var heads = [_]ObjectId{ids[ids.len - 1]};
    var v: view_mod.View = .empty;
    v.heads = &heads;
    const c: revset.EvalContext = .{ .graph = vw, .view = &v, .store = r.store, .io = t.io };
    var hex: [2][64]u8 = undefined;
    var buf: [200]u8 = undefined;
    for (0..200) |_| {
        const x = rng.uintLessThan(u32, vw.count);
        const y = rng.uintLessThan(u32, vw.count);
        const src = try std.fmt.bufPrint(&buf, "{s}..{s}", .{ vw.id(Pos.of(x)).hex(&hex[0]), vw.id(Pos.of(y)).hex(&hex[1]) });
        var diag: revset.ParseError = .{};
        var it = try revset.evaluate(gpa, &c, src, &diag);
        defer it.deinit();
        const got = try it.collect(gpa, null);
        defer gpa.free(got);
        var want: std.ArrayList(Pos) = .empty;
        defer want.deinit(gpa);
        var k: u32 = vw.count;
        while (k > 0) {
            k -= 1;
            if (sets[y].isSet(k) and !sets[x].isSet(k)) try want.append(gpa, Pos.of(k));
        }
        try t.expectEqualSlices(Pos, want.items, got);
    }
}

test "fuzz: scm-revset" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
            defer arena_state.deinit();
            const a = arena_state.allocator();
            var diag: revset.ParseError = .{};
            const n = revset.parse(a, input, &diag) catch |e| switch (e) {
                error.ParseFailed => {
                    try t.expect(diag.span[0] <= diag.span[1] and diag.span[1] <= input.len);
                    return;
                },
                else => return e,
            };
            // Printing parses back to the same tree.
            var aw: std.Io.Writer.Allocating = .init(a);
            try revset.ast.format(n, &aw.writer);
            const again = try revset.parse(a, aw.written(), &diag);
            try t.expect(revset.ast.eql(n, again));
            // Alias expansion never panics either.
            var al = try revset.Aliases.withDefaults(t.allocator);
            defer al.deinit();
            _ = al.expand(a, n, &diag) catch |e| if (e != error.ParseFailed) return e;
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "scm-revset") });
}
