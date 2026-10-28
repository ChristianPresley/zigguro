//! Oracle tests for rev parsing, graph walks, switching, reset, restore,
//! clean, branches and tags against the system git (skipped without it).

const std = @import("std");
const builtin = @import("builtin");
const Repository = @import("repository.zig").Repository;
const Oid = @import("oid.zig").Oid;
const revparse = @import("revparse.zig");
const revwalk = @import("revwalk.zig");
const checkout = @import("checkout.zig");
const branch = @import("branch.zig");
const helpers = @import("status_test.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// main: base -> m1 -> m2; feature (from base): f1 -> f2; a merge of the
/// two on `both`; origin/main and origin/topic as remote-tracking refs;
/// an annotated tag v1 on base.
const history =
    "git init -q -b main && git remote add origin ../nowhere && " ++
    "printf 'a\\n' > a.txt && mkdir d && printf 'b\\n' > d/b.txt && printf 'k\\n' > keep.txt && git add -A && git commit -qm base && " ++
    "git tag -a v1 -m 'version one' && " ++
    "git checkout -qb feature && printf 'f\\n' > f.txt && git add f.txt && git commit -qm f1 && " ++
    "printf 'b2\\n' > d/b.txt && git commit -qam f2 && " ++
    "git checkout -q main && printf 'a2\\n' > a.txt && git commit -qam m1 && printf 'a3\\n' > a.txt && git commit -qam m2 && " ++
    "git checkout -qb both && git merge -q --no-edit feature && git checkout -q main && " ++
    "git update-ref refs/remotes/origin/main HEAD~1 && git update-ref refs/remotes/origin/topic feature~1 && " ++
    "printf '*.log\\n' > .gitignore && git add .gitignore && git commit -qm ignore";

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    dir: []u8,
    env: std.process.Environ.Map,
    repo: *Repository,

    fn init(gpa: Allocator, io: Io) !?*Fixture {
        if (builtin.os.tag == .windows) return null;
        const f = try gpa.create(Fixture);
        errdefer gpa.destroy(f);
        f.tmp = testing.tmpDir(.{ .iterate = true });
        errdefer f.tmp.cleanup();
        f.root = try f.tmp.dir.realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(f.root);
        f.env = .init(gpa);
        errdefer f.env.deinit();
        try f.env.put("PATH", "/usr/local/bin:/usr/bin:/bin");
        try f.env.put("HOME", f.root);
        try f.env.put("GIT_CONFIG_NOSYSTEM", "1");
        try f.env.put("GIT_CEILING_DIRECTORIES", f.root);
        try f.env.put("GIT_AUTHOR_NAME", "A");
        try f.env.put("GIT_AUTHOR_EMAIL", "a@example.com");
        try f.env.put("GIT_COMMITTER_NAME", "C");
        try f.env.put("GIT_COMMITTER_EMAIL", "c@example.com");
        if (!helpers.gitAvailable(gpa, io, &f.env)) {
            f.env.deinit();
            gpa.free(f.root);
            f.tmp.cleanup();
            gpa.destroy(f);
            return null;
        }
        gpa.free(try helpers.sh(gpa, io, f.root, &f.env, "mkdir r && cd r && " ++ history));
        f.dir = try std.fs.path.join(gpa, &.{ f.root, "r" });
        errdefer gpa.free(f.dir);
        f.repo = (try Repository.discover(gpa, io, f.dir, .{ .env = &f.env })).?;
        return f;
    }

    fn deinit(f: *Fixture, gpa: Allocator) void {
        f.repo.close();
        gpa.free(f.dir);
        f.env.deinit();
        gpa.free(f.root);
        f.tmp.cleanup();
        gpa.destroy(f);
    }

    /// Runs a shell script in the repository and returns its stdout.
    fn git(f: *Fixture, gpa: Allocator, script: []const u8) ![]u8 {
        return helpers.sh(gpa, f.repo.io, f.dir, &f.env, script);
    }

    fn expectGit(f: *Fixture, script: []const u8, want: []const u8) !void {
        const out = try f.git(testing.allocator, script);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(want, out);
    }

    fn hex(f: *Fixture, gpa: Allocator, id: Oid) ![]u8 {
        var b: [64]u8 = undefined;
        _ = f;
        return std.fmt.allocPrint(gpa, "{s}\n", .{id.hex(&b)});
    }
};

test "revparse: names resolve like git rev-parse" {
    const gpa = testing.allocator;
    const f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    const short = try f.git(gpa, "git rev-parse --short=7 feature");
    defer gpa.free(short);
    const specs = [_][]const u8{ "HEAD", "@", "main", "HEAD~1", "main~2", "HEAD^", "both^2", "both^1", "feature~1", "v1", "v1^{commit}", "v1^{tree}", "origin/main", "refs/remotes/origin/topic", "main:a.txt", "HEAD:d", "feature:d/b.txt", "both^2~1", std.mem.trimEnd(u8, short, "\n") };
    for (specs) |s| {
        var cmd: [128]u8 = undefined;
        const want = try f.git(gpa, try std.fmt.bufPrint(&cmd, "git rev-parse --verify -q '{s}'", .{s}));
        defer gpa.free(want);
        const got = try f.hex(gpa, try revparse.resolve(f.repo, s));
        defer gpa.free(got);
        testing.expectEqualStrings(want, got) catch |e| {
            std.debug.print("spec {s}\n", .{s});
            return e;
        };
    }
    try testing.expectError(error.UnknownRevision, revparse.resolve(f.repo, "nope"));
    try testing.expectError(error.NoUpstream, revparse.resolve(f.repo, "@{u}"));
}

test "revwalk: merge base, ancestry, ahead/behind and log match git" {
    const gpa = testing.allocator;
    const f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    const main = try revparse.resolve(f.repo, "main");
    const feature = try revparse.resolve(f.repo, "feature");
    const both = try revparse.resolve(f.repo, "both");
    const mb = try f.git(gpa, "git merge-base main feature");
    defer gpa.free(mb);
    const got = try f.hex(gpa, (try revwalk.mergeBase(f.repo, main, feature)).?);
    defer gpa.free(got);
    try testing.expectEqualStrings(mb, got);
    try testing.expect(try revwalk.isAncestor(f.repo, feature, both));
    try testing.expect(!try revwalk.isAncestor(f.repo, feature, main));
    const counts = try f.git(gpa, "git rev-list --left-right --count main...feature");
    defer gpa.free(counts);
    const ab = try revwalk.aheadBehind(f.repo, main, feature);
    const ab_text = try std.fmt.allocPrint(gpa, "{d}\t{d}\n", .{ ab.ahead, ab.behind });
    defer gpa.free(ab_text);
    try testing.expectEqualStrings(counts, ab_text);
    const want_log = try f.git(gpa, "git rev-list both ^main");
    defer gpa.free(want_log);
    const ids = try revwalk.log(f.repo, gpa, &.{both}, &.{main}, 0);
    defer gpa.free(ids);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    for (ids) |id| {
        var b: [64]u8 = undefined;
        try aw.writer.print("{s}\n", .{id.hex(&b)});
    }
    // Same commits; order among equal timestamps may differ.
    const a_lines = try sortedText(gpa, want_log);
    defer gpa.free(a_lines);
    const b_lines = try sortedText(gpa, aw.written());
    defer gpa.free(b_lines);
    try testing.expectEqualStrings(a_lines, b_lines);
}

fn sortedText(gpa: Allocator, text: []const u8) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(gpa, l);
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return std.mem.join(gpa, "\n", lines.items);
}

test "checkout: switch, tracking branches, detach and blocked switches" {
    const gpa = testing.allocator;
    const io = testing.io;
    const f = (try Fixture.init(gpa, io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const d = f.tmp.dir;

    // An unrelated local change and an untracked file carry over.
    try d.writeFile(io, .{ .sub_path = "r/keep.txt", .data = "local\n" });
    try d.writeFile(io, .{ .sub_path = "r/new.txt", .data = "n\n" });
    const out = try checkout.switchTo(f.repo, a, "feature", .{});
    try testing.expectEqualStrings("feature", out.branch.?);
    try f.expectGit("git symbolic-ref HEAD && git status --porcelain && cat d/b.txt && test ! -e .gitignore && echo gone", "refs/heads/feature\n M keep.txt\n?? new.txt\nb2\ngone\n");
    try f.expectGit("git reflog -1 --format=%gs", "checkout: moving from main to feature\n");

    // A local edit to a file the switch changes blocks it.
    try d.writeFile(io, .{ .sub_path = "r/d/b.txt", .data = "dirty\n" });
    var conflicts: std.ArrayList([]const u8) = .empty;
    defer {
        for (conflicts.items) |p| gpa.free(p);
        conflicts.deinit(gpa);
    }
    try testing.expectError(error.WouldOverwrite, checkout.switchTo(f.repo, a, "main", .{ .conflicts = &conflicts, .conflicts_gpa = gpa }));
    try testing.expectEqual(@as(usize, 1), conflicts.items.len);
    try testing.expectEqualStrings("d/b.txt", conflicts.items[0]);
    try f.expectGit("git symbolic-ref HEAD && cat d/b.txt", "refs/heads/feature\ndirty\n");

    // An untracked file in the target's way blocks it too.
    _ = try checkout.restore(f.repo, &.{"d/b.txt"}, .index);
    try d.writeFile(io, .{ .sub_path = "r/.gitignore", .data = "mine\n" });
    try testing.expectError(error.WouldOverwrite, checkout.switchTo(f.repo, a, "main", .{}));
    try d.deleteFile(io, "r/.gitignore");

    // `@{-1}` goes back; force throws local changes away.
    const back = try checkout.switchTo(f.repo, a, "@{-1}", .{ .force = true });
    try testing.expectEqualStrings("main", back.branch.?);
    try f.expectGit("git status --porcelain && cat d/b.txt", "?? new.txt\nb\n");

    // A remote branch's short name makes a tracking branch.
    const topic = try checkout.switchTo(f.repo, a, "topic", .{});
    try testing.expect(topic.created_tracking);
    try f.expectGit("git rev-parse --abbrev-ref topic@{u} && git rev-parse topic^{tree} | xargs git diff --quiet && git status --porcelain", "origin/topic\n?? new.txt\n");

    // -b creates; a tag detaches.
    _ = try checkout.switchTo(f.repo, a, "main", .{ .create = "work" });
    try f.expectGit("git symbolic-ref --short HEAD && git rev-parse work main | uniq | wc -l", "work\n1\n");
    const det = try checkout.switchTo(f.repo, a, "v1", .{});
    try testing.expect(det.branch == null);
    try f.expectGit("git symbolic-ref -q HEAD || echo detached; git status --porcelain; git fsck --no-progress 2>&1", "detached\n?? new.txt\n");
}

test "checkout: reset modes, restore and clean match git" {
    const gpa = testing.allocator;
    const io = testing.io;
    const f = (try Fixture.init(gpa, io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    const d = f.tmp.dir;
    const m1 = try revparse.resolveCommit(f.repo, "HEAD~2");

    try checkout.reset(f.repo, m1, .soft, "HEAD~2", 0);
    try f.expectGit("git status --porcelain && cat ORIG_HEAD 2>/dev/null; git reflog -1 --format=%gs", "A  .gitignore\nM  a.txt\nreset: moving to HEAD~2\n");
    try checkout.reset(f.repo, m1, .mixed, "HEAD", 0);
    try f.expectGit("git status --porcelain", " M a.txt\n?? .gitignore\n");
    try checkout.reset(f.repo, m1, .hard, "HEAD", 0);
    try f.expectGit("git status --porcelain --ignored; cat a.txt; git rev-parse --verify -q ORIG_HEAD >/dev/null && echo orig", "?? .gitignore\na2\norig\n");

    // restore from the index, and from a commit (index and worktree).
    try d.writeFile(io, .{ .sub_path = "r/a.txt", .data = "edited\n" });
    try testing.expectEqual(@as(usize, 1), try checkout.restore(f.repo, &.{"a.txt"}, .index));
    try f.expectGit("cat a.txt && git status --porcelain", "a2\n?? .gitignore\n");
    const base = try revparse.resolveCommit(f.repo, "v1");
    _ = try checkout.restore(f.repo, &.{ "a.txt", "d" }, .{ .commit = base });
    try f.expectGit("git status --porcelain && cat a.txt", "M  a.txt\n?? .gitignore\na\n");

    // clean: files, then directories and ignored files.
    try d.createDirPath(io, "r/junk/deep");
    try d.writeFile(io, .{ .sub_path = "r/junk/deep/x", .data = "x" });
    try d.writeFile(io, .{ .sub_path = "r/build.log", .data = "l" });
    try d.writeFile(io, .{ .sub_path = "r/.git/info/exclude", .data = "*.log\n" });
    const removed = try checkout.clean(f.repo, gpa, &.{}, false, false);
    defer {
        for (removed) |p| gpa.free(p);
        gpa.free(removed);
    }
    try testing.expectEqual(@as(usize, 1), removed.len);
    try f.expectGit("git status --porcelain --ignored", "M  a.txt\n?? junk/\n!! build.log\n");
    const removed2 = try checkout.clean(f.repo, gpa, &.{}, true, true);
    defer {
        for (removed2) |p| gpa.free(p);
        gpa.free(removed2);
    }
    try f.expectGit("git status --porcelain --ignored", "M  a.txt\n");
}

test "branch: create, rename, upstream, delete and tags; git agrees" {
    const gpa = testing.allocator;
    const f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    _ = try branch.create(f.repo, "side", "feature~1", false);
    try testing.expectError(error.BranchExists, branch.create(f.repo, "side", "HEAD", false));
    try testing.expectError(error.InvalidBranchName, branch.create(f.repo, "bad..name", "HEAD", false));
    try branch.setUpstream(f.repo, "side", "origin/topic");
    try f.expectGit("git rev-parse --abbrev-ref side@{u} && git reflog side --format=%gs", "origin/topic\nbranch: Created from feature~1\n");

    try branch.setUpstream(f.repo, "main", "origin/main");
    var l = try branch.list(f.repo, true);
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    for (l.items) |b| try names.print(gpa, "{s}{s} {?d}/{?d}\n", .{ if (b.head) "*" else "", b.name, b.ahead, b.behind });
    l.deinit();
    try testing.expectEqualStrings("both null/null\nfeature null/null\n*main 2/0\nside 0/0\norigin/main null/null\norigin/topic null/null\n", names.items);

    try branch.rename(f.repo, "side", "renamed", false);
    try f.expectGit("git rev-parse --abbrev-ref renamed@{u} && git show-ref --verify -q refs/heads/side || echo moved", "origin/topic\nmoved\n");
    try testing.expectError(error.BranchNotMerged, branch.delete(f.repo, "both", false));
    try branch.delete(f.repo, "renamed", false);
    try branch.delete(f.repo, "both", true);
    try testing.expectError(error.BranchIsCheckedOut, branch.delete(f.repo, "main", true));
    try f.expectGit("git branch --format='%(refname:short)' && git config --get-regexp '^branch\\.' || true", "feature\nmain\nbranch.main.remote origin\nbranch.main.merge refs/heads/main\n");

    _ = try branch.createTag(f.repo, "light", "feature", null, false, 0);
    _ = try branch.createTag(f.repo, "v2", "HEAD", "second\n\nnotes", false, 120);
    try testing.expectError(error.TagExists, branch.createTag(f.repo, "v2", "HEAD", null, false, 0));
    var t = try branch.tags(f.repo);
    try testing.expectEqual(@as(usize, 3), t.items.len);
    t.deinit();
    try f.expectGit("git cat-file -t v2 && git tag -l -n1 v2 && git rev-parse v2^{commit} light | tr '\\n' ' ' | wc -w && git fsck --strict --no-progress 2>&1", "tag\nv2              second\n2\n");
    try branch.deleteTag(f.repo, "light");
    try f.expectGit("git tag", "v1\nv2\n");
}
