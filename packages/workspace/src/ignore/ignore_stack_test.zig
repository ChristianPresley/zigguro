//! IgnoreStack tests, including the golden corpus under testdata/ignore/
//! whose expected.txt files are `git ls-files --others --cached
//! --exclude-standard` output for the same tree and ignore files.

const std = @import("std");
const IgnoreStack = @import("ignore_stack.zig").IgnoreStack;
const RootId = @import("../ids.zig").RootId;
const testdata = @import("../testing/testdata.zig");

const r0: RootId = .of(0);

fn loadCase(gpa: std.mem.Allocator, st: *IgnoreStack, ignores: []const u8) !void {
    var it = std.mem.splitSequence(u8, ignores, "=== ");
    while (it.next()) |section| {
        if (section.len == 0) continue;
        const nl = std.mem.indexOfScalar(u8, section, '\n') orelse continue;
        const path = section[0..nl];
        const body = section[nl + 1 ..];
        if (std.mem.eql(u8, path, ".git/info/exclude")) {
            try st.setGlobal(r0, body, null, &.{});
        } else if (std.mem.endsWith(u8, path, ".gitignore")) {
            const dir = std.mem.trimEnd(u8, path[0 .. path.len - ".gitignore".len], "/");
            try st.loadDir(r0, dir, body, null);
        } else return error.UnknownIgnoreFile;
    }
    _ = gpa;
}

test "ignore_stack: golden corpus" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = try testdata.openDir("testdata/ignore");
    defer dir.close(io);
    var cases: usize = 0;
    var verdicts: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        cases += 1;
        var buf: [256]u8 = undefined;
        const tree = try dir.readFileAlloc(io, try std.fmt.bufPrint(&buf, "{s}/tree.txt", .{e.name}), gpa, .limited(1 << 20));
        defer gpa.free(tree);
        const ignores = try dir.readFileAlloc(io, try std.fmt.bufPrint(&buf, "{s}/ignores.txt", .{e.name}), gpa, .limited(1 << 20));
        defer gpa.free(ignores);
        const expected = try dir.readFileAlloc(io, try std.fmt.bufPrint(&buf, "{s}/expected.txt", .{e.name}), gpa, .limited(1 << 20));
        defer gpa.free(expected);

        const st = try IgnoreStack.init(gpa, io, 1);
        defer st.deinit();
        try loadCase(gpa, st, ignores);
        var want: std.StringHashMapUnmanaged(void) = .empty;
        defer want.deinit(gpa);
        var ei = std.mem.splitScalar(u8, expected, '\n');
        while (ei.next()) |l| if (l.len > 0) try want.put(gpa, l, {});
        var ti = std.mem.splitScalar(u8, tree, '\n');
        while (ti.next()) |p| {
            if (p.len == 0) continue;
            verdicts += 1;
            const visible = !st.isIgnored(r0, p, false).isIgnored();
            if (visible != want.contains(p)) {
                failures += 1;
                const why = try st.explain(r0, p, false, gpa);
                defer gpa.free(why);
                std.debug.print("ignore golden {s}: '{s}' visible={} want={} ({s})\n", .{ e.name, p, visible, want.contains(p), why });
            }
        }
    }
    try std.testing.expect(cases >= 20);
    try std.testing.expect(verdicts >= 300);
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "ignore_stack: parent excluded cannot be re-included" {
    const st = try IgnoreStack.init(std.testing.allocator, std.testing.io, 1);
    defer st.deinit();
    try st.loadDir(r0, "", "build/\n!build/keep.txt\n", null);
    try std.testing.expect(st.isIgnored(r0, "build", true).isIgnored());
    try std.testing.expect(st.isIgnored(r0, "build/keep.txt", false).isIgnored());
    // Asked without the ancestor walk, the file's own rule re-includes it.
    try std.testing.expectEqual(.included, st.isIgnoredInVisibleDir(r0, "build/keep.txt", false).state);
}

test "ignore_stack: zgignore overrides gitignore" {
    const st = try IgnoreStack.init(std.testing.allocator, std.testing.io, 1);
    defer st.deinit();
    try st.loadDir(r0, "", "*.log\n", "!keep.log\nsecret.txt\n");
    try std.testing.expect(st.isIgnored(r0, "a.log", false).isIgnored());
    try std.testing.expect(!st.isIgnored(r0, "keep.log", false).isIgnored());
    try std.testing.expect(st.isIgnored(r0, "sub/secret.txt", false).isIgnored());
    // A deeper .gitignore does not beat a root .zgignore.
    try st.loadDir(r0, "sub", "!secret.txt\n", null);
    try std.testing.expect(st.isIgnored(r0, "sub/secret.txt", false).isIgnored());
}

test "ignore_stack: settings, info/exclude and excludesFile precedence" {
    const st = try IgnoreStack.init(std.testing.allocator, std.testing.io, 1);
    defer st.deinit();
    try st.setGlobal(r0, "*.tmp\n!keep.bak\n", "*.bak\n*.swp\n", &.{ "**/{dist,out}", "./top.txt" });
    try std.testing.expect(st.isIgnored(r0, "x.tmp", false).isIgnored());
    try std.testing.expect(!st.isIgnored(r0, "keep.bak", false).isIgnored());
    try std.testing.expect(st.isIgnored(r0, "a.bak", false).isIgnored());
    try std.testing.expect(st.isIgnored(r0, "dist/a.js", false).isIgnored());
    try std.testing.expect(st.isIgnored(r0, "pkg/out", true).isIgnored());
    try std.testing.expect(st.isIgnored(r0, "top.txt", false).isIgnored());
    try std.testing.expect(!st.isIgnored(r0, "sub/top.txt", false).isIgnored());
    // .gitignore beats info/exclude; settings beat a .gitignore negation.
    try st.loadDir(r0, "", "!x.tmp\n!dist/\n", null);
    try std.testing.expect(!st.isIgnored(r0, "x.tmp", false).isIgnored());
    try std.testing.expect(st.isIgnored(r0, "dist", true).isIgnored());
}

test "ignore_stack: explain() names file and line" {
    const gpa = std.testing.allocator;
    const st = try IgnoreStack.init(gpa, std.testing.io, 1);
    defer st.deinit();
    try st.loadDir(r0, "src", "# c\n\n*.o\n", null);
    try st.loadDir(r0, "", "\nbuild/\n", null);
    const a = try st.explain(r0, "build", true, gpa);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("ignored by .gitignore:2 `build/`", a);
    const b = try st.explain(r0, "src/x/m.o", false, gpa);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("ignored by src/.gitignore:3 `*.o`", b);
    const c = try st.explain(r0, "build/x.c", false, gpa);
    defer gpa.free(c);
    try std.testing.expectEqualStrings("ignored because its parent directory build/ is by .gitignore:2 `build/`", c);
    const d = try st.explain(r0, "main.zig", false, gpa);
    defer gpa.free(d);
    try std.testing.expectEqualStrings("not ignored", d);
}

test "ignore_stack: hard ignores .git .zg .zigguro/review cannot be re-included" {
    const st = try IgnoreStack.init(std.testing.allocator, std.testing.io, 1);
    defer st.deinit();
    try st.loadDir(r0, "", "!.git\n!.git/\n!.zg/\n!.zigguro/\n!.zigguro/review/\n", "!.git/\n!.zg\n!/.zigguro/review/**\n");
    try st.setGlobal(r0, null, null, &.{"!.git"});
    for ([_][]const u8{ ".git", "sub/.git", ".zg", ".zigguro/review" }) |p| {
        const v = st.isIgnored(r0, p, true);
        try std.testing.expect(v.isIgnored());
        try std.testing.expect(v.hard);
    }
    try std.testing.expect(st.isIgnored(r0, ".git/config", false).isIgnored());
    try std.testing.expect(st.isIgnored(r0, ".zigguro/review/q/1.json", false).isIgnored());
    // .zigguro itself and its other contents stay visible.
    try std.testing.expect(!st.isIgnored(r0, ".zigguro/workspace.zon", false).isIgnored());
    // Built-in soft rules can be negated.
    try std.testing.expect(st.isIgnored(r0, ".DS_Store", false).isIgnored());
    try st.loadDir(r0, "", "!.DS_Store\n", null);
    try std.testing.expect(!st.isIgnored(r0, ".DS_Store", false).isIgnored());
}

test "ignore_stack: case-insensitive roots fold ASCII" {
    const st = try IgnoreStack.init(std.testing.allocator, std.testing.io, 1);
    defer st.deinit();
    try st.loadDir(r0, "", "Build/\n*.LOG\n", null);
    try std.testing.expect(!st.isIgnored(r0, "build", true).isIgnored());
    st.setCaseInsensitive(r0, true);
    try std.testing.expect(st.isIgnored(r0, "build", true).isIgnored());
    try std.testing.expect(st.isIgnored(r0, "a.log", false).isIgnored());
}

test "ignore_stack: concurrent isIgnored during reload" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const st = try IgnoreStack.init(gpa, io, 1);
    defer st.deinit();
    try st.loadDir(r0, "", "*.o\n", null);
    var stop: std.atomic.Value(bool) = .init(false);
    var bad: std.atomic.Value(u32) = .init(0);
    const Reader = struct {
        fn run(s: *IgnoreStack, stop_flag: *std.atomic.Value(bool), bad_count: *std.atomic.Value(u32)) void {
            while (!stop_flag.load(.acquire)) {
                // Both versions of the file ignore *.o; neither ignores main.zig.
                if (!s.isIgnored(r0, "src/a.o", false).isIgnored()) _ = bad_count.fetchAdd(1, .monotonic);
                if (s.isIgnored(r0, "src/main.zig", false).isIgnored()) _ = bad_count.fetchAdd(1, .monotonic);
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Reader.run, .{ st, &stop, &bad });
    for (0..500) |i| {
        try st.loadDir(r0, "", if (i % 2 == 0) "*.o\nbuild/\n" else "*.o\n", null);
        try st.loadDir(r0, "src", if (i % 2 == 0) "*.tmp\n" else null, null);
    }
    stop.store(true, .release);
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 0), bad.load(.acquire));
}

test "ignore_stack: watch filter adapter" {
    const st = try IgnoreStack.init(std.testing.allocator, std.testing.io, 2);
    defer st.deinit();
    try st.loadDir(.of(1), "", "node_modules/\n", null);
    const f0 = st.asWatchFilter(.of(0));
    const f1 = st.asWatchFilter(.of(1));
    try std.testing.expect(!f0.isIgnored(f0.ctx, "node_modules", true));
    try std.testing.expect(f1.isIgnored(f1.ctx, "node_modules", true));
    try std.testing.expect(f1.isIgnored(f1.ctx, ".git", true));
}
