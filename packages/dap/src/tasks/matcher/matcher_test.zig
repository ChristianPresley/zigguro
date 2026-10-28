//! Problem matchers: the built-ins against captured tool output
//! (testdata/matchers/<name>.txt, expected events in
//! <name>.expected.zon), then the engine's rules one by one.

const std = @import("std");
const options = @import("zg_options");
const pm = @import("ProblemMatcher.zig");
const ansi = @import("ansi_strip.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Allocator = std.mem.Allocator;

/// What a sink saw, in order (the golden's shape).
const Event = union(enum) {
    begin,
    end,
    problem: P,

    const P = struct {
        file: []const u8,
        line: u32 = 0,
        column: u32 = 0,
        end_line: u32 = 0,
        end_column: u32 = 0,
        severity: pm.Severity,
        code: []const u8 = "",
        message: []const u8,
        related: []const pm.Related = &.{},
    };
};

const Rec = struct {
    arena: Allocator,
    events: std.ArrayList(Event) = .empty,

    fn sink(r: *Rec) pm.ProblemSink {
        return .{ .ctx = r, .problem = problem, .cycle = cycle };
    }

    fn problem(ctx: *anyopaque, p: *const pm.Problem) void {
        const r: *Rec = @ptrCast(@alignCast(ctx));
        const a = r.arena;
        const rel = a.alloc(pm.Related, p.related.len) catch unreachable;
        for (p.related, rel) |x, *y| y.* = .{ .file = a.dupe(u8, x.file) catch unreachable, .line = x.line, .column = x.column, .message = a.dupe(u8, x.message) catch unreachable };
        r.events.append(a, .{ .problem = .{
            .file = a.dupe(u8, p.file) catch unreachable,
            .line = p.line,
            .column = p.column,
            .end_line = p.end_line,
            .end_column = p.end_column,
            .severity = p.severity,
            .code = a.dupe(u8, p.code) catch unreachable,
            .message = a.dupe(u8, p.message) catch unreachable,
            .related = rel,
        } }) catch unreachable;
    }

    fn cycle(ctx: *anyopaque, ev: pm.Cycle) void {
        const r: *Rec = @ptrCast(@alignCast(ctx));
        r.events.append(r.arena, switch (ev) {
            .begin => .begin,
            .end => .end,
        }) catch unreachable;
    }

    fn zon(r: *const Rec) ![]const u8 {
        var w: std.Io.Writer.Allocating = .init(r.arena);
        try std.zon.stringify.serialize(r.events.items, .{ .emit_default_optional_fields = false }, &w.writer);
        try w.writer.writeByte('\n');
        return w.written();
    }
};

fn readFixture(a: Allocator, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(a, &.{ options.package_root, "testdata", "matchers", name });
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(1 << 20));
}

/// Runs matcher `name` over fixture `fixture` (fed in `chunk`-byte
/// pieces, 0: at once) and compares with its golden.
fn expectFixture(name: []const u8, fixture: []const u8, cwd: []const u8, style: pm.PathStyle, chunk: usize) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try readFixture(a, try std.mem.concat(a, u8, &.{ fixture, ".txt" }));
    var m = try pm.Matcher.init(gpa, pm.builtinNamed(name).?, cwd, .{ .style = style });
    defer m.deinit();
    var rec: Rec = .{ .arena = a };
    if (chunk == 0) {
        m.feedBytes(text, rec.sink());
    } else {
        var i: usize = 0;
        while (i < text.len) : (i += chunk) m.feedBytes(text[i..@min(text.len, i + chunk)], rec.sink());
    }
    m.finish(rec.sink());
    const got = try rec.zon();
    const want = readFixture(a, try std.mem.concat(a, u8, &.{ fixture, ".expected.zon" })) catch |e| {
        std.debug.print("no golden for {s}; got:\n{s}", .{ fixture, got });
        return e;
    };
    try testing.expectEqualStrings(try std.mem.replaceOwned(u8, a, want, "\r\n", "\n"), got);
}

const posix_cwd = "/home/dev/proj";

test "matcher: $zig fixtures (build-exe, zig build verbose, zig build minimal, watch cycles)" {
    try expectFixture("$zig", "zig_build_exe", posix_cwd, .posix, 0);
    try expectFixture("$zig", "zig_build_verbose", posix_cwd, .posix, 0);
    try expectFixture("$zig", "zig_build_minimal", posix_cwd, .posix, 0);
    // A rebuild that passes prints only its summary: an empty cycle.
    try expectFixture("$zig-watch", "zig_watch", posix_cwd, .posix, 0);
    // minimal_clear: the clear-screen begins each update.
    try expectFixture("$zig-watch", "zig_watch_minimal_clear", posix_cwd, .posix, 0);
    // Lines split anywhere across reads match the same.
    for ([_]usize{ 1, 7, 64 }) |n| try expectFixture("$zig-watch", "zig_watch_minimal_clear", posix_cwd, .posix, n);
}

test "matcher: $gcc/$msCompile/$rustc/$go/$tsc/$eslint-stylish/$python fixtures" {
    try expectFixture("$gcc", "gcc", posix_cwd, .posix, 0);
    // MSVC and ESLint output is hand-written from their documented formats
    // (no MSVC or ESLint where the fixtures were captured); the rest is
    // captured.
    try expectFixture("$msCompile", "mscompile", "C:\\src\\demo", .windows, 0);
    try expectFixture("$rustc", "rustc", posix_cwd, .posix, 0);
    try expectFixture("$go", "go", posix_cwd, .posix, 0);
    try expectFixture("$tsc", "tsc", posix_cwd, .posix, 0);
    try expectFixture("$eslint-stylish", "eslint_stylish", posix_cwd, .posix, 0);
    try expectFixture("$python", "python", posix_cwd, .posix, 0);
}

/// Feeds `lines` to `def` and returns the problems' "file:line:col msg".
fn run(a: Allocator, def: *const pm.MatcherDef, cwd: []const u8, style: pm.PathStyle, lines: []const []const u8) ![]const []const u8 {
    var m = try pm.Matcher.init(gpa, def, cwd, .{ .style = style });
    defer m.deinit();
    var rec: Rec = .{ .arena = a };
    for (lines) |l| m.feed(l, rec.sink());
    m.finish(rec.sink());
    var out: std.ArrayList([]const u8) = .empty;
    for (rec.events.items) |e| switch (e) {
        .problem => |p| try out.append(a, try std.fmt.allocPrint(a, "{s}:{d}:{d}{s}{s} {s}", .{
            p.file,
            p.line,
            p.column,
            if (p.end_line > 0) try std.fmt.allocPrint(a, "-{d}:{d}", .{ p.end_line, p.end_column }) else "",
            if (p.code.len > 0) try std.fmt.allocPrint(a, " [{s}]", .{p.code}) else "",
            p.message,
        })),
        .begin => try out.append(a, "begin"),
        .end => try out.append(a, "end"),
    };
    return out.items;
}

fn expectLines(want: []const []const u8, got: []const []const u8) !void {
    testing.expectEqual(want.len, got.len) catch |e| {
        for (got) |g| std.debug.print("  got: {s}\n", .{g});
        return e;
    };
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

const two_line: pm.MatcherDef = .{
    .name = "t",
    .owner = "t",
    .patterns = &.{
        .{ .regexp = "^FILE (\\S+)$", .file = 1 },
        .{ .regexp = "^  (\\d+):(\\d+) (.*)$", .line = 1, .column = 2, .message = 3 },
    },
};

test "matcher: multi-line reset on mismatch" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const got = try run(arena.allocator(), &two_line, "/w", .posix, &.{
        "FILE a.c",
        "noise", // breaks the candidate
        "  1:2 lost",
        "FILE b.c",
        "FILE c.c", // a failed second line is tried as a first line
        "  3:4 kept",
        "  5:6 no loop", // the candidate ended
    });
    try expectLines(&.{"/w/c.c:3:4 kept"}, got);
}

test "matcher: loop" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var def = two_line;
    def.patterns = &.{ two_line.patterns[0], blk: {
        var p = two_line.patterns[1];
        p.loop = true;
        break :blk p;
    } };
    const got = try run(arena.allocator(), &def, "/w", .posix, &.{
        "FILE a.c",
        "  1:2 one",
        "  3:4 two",
        "",
        "  5:6 orphan",
        "FILE b.c",
        "  7:8 three",
    });
    try expectLines(&.{ "/w/a.c:1:2 one", "/w/a.c:3:4 two", "/w/b.c:7:8 three" }, got);
}

test "matcher: location group forms" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const def: pm.MatcherDef = .{
        .name = "t",
        .owner = "t",
        .file_location = .absolute,
        .patterns = &.{.{ .regexp = "^(\\S+)\\(([\\d,]+)\\): (\\w+) (.*)$", .file = 1, .location = 2, .severity = 3, .message = 4 }},
    };
    const got = try run(arena.allocator(), &def, "/w", .posix, &.{
        "/a.c(7): warning line only",
        "/a.c(7,3): error line and column",
        "/a.c(8,3,9,12): info a range",
    });
    try expectLines(&.{ "/a.c:7:0 line only", "/a.c:7:3 line and column", "/a.c:8:3-9:12 a range" }, got);
}

test "matcher: fileLocation absolute/relative/autoDetect (windows+linux paths)" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var def: pm.MatcherDef = .{
        .name = "t",
        .owner = "t",
        .patterns = &.{.{ .regexp = "^(.+):(\\d+): (.*)$", .file = 1, .line = 2, .message = 3 }},
    };
    const lines = &[_][]const u8{ "src/a.zig:1: rel", "./b.zig:2: dot", "/abs/c.zig:3: abs" };
    def.file_location = .{ .auto_detect = null };
    try expectLines(&.{ "/w/src/a.zig:1:0 rel", "/w/b.zig:2:0 dot", "/abs/c.zig:3:0 abs" }, try run(a, &def, "/w/", .posix, lines));
    def.file_location = .{ .relative = "/base" };
    try expectLines(&.{ "/base/src/a.zig:1:0 rel", "/base/b.zig:2:0 dot", "/base//abs/c.zig:3:0 abs" }, try run(a, &def, "/w", .posix, lines));
    def.file_location = .absolute;
    try expectLines(&.{ "src/a.zig:1:0 rel", "./b.zig:2:0 dot", "/abs/c.zig:3:0 abs" }, try run(a, &def, "/w", .posix, lines));
    // Windows: drive letters and either slash; results use backslashes.
    def.file_location = .{ .auto_detect = null };
    try expectLines(&.{ "C:\\w\\src\\a.zig:1:0 rel", "D:\\x\\y.zig:4:0 drive", "C:\\w\\z.zig:5:0 dot" }, try run(a, &def, "C:\\w", .windows, &.{ "src/a.zig:1: rel", "D:/x/y.zig:4: drive", ".\\z.zig:5: dot" }));
}

/// Keeps one owner's problems the way the diagnostics store does: a
/// cycle's problems replace the previous set only at its end.
const Swap = struct {
    shown: std.ArrayList([]const u8) = .empty,
    pending: std.ArrayList([]const u8) = .empty,
    a: Allocator,
    /// The shown set was never empty mid-cycle.
    flicker: bool = false,

    fn sink(s: *Swap) pm.ProblemSink {
        return .{ .ctx = s, .problem = problem, .cycle = cycle };
    }
    fn problem(ctx: *anyopaque, p: *const pm.Problem) void {
        const s: *Swap = @ptrCast(@alignCast(ctx));
        s.pending.append(s.a, s.a.dupe(u8, p.message) catch unreachable) catch unreachable;
        if (s.shown.items.len == 0) s.flicker = true;
    }
    fn cycle(ctx: *anyopaque, ev: pm.Cycle) void {
        const s: *Swap = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .begin => s.pending.clearRetainingCapacity(),
            .end => {
                s.shown.clearRetainingCapacity();
                s.shown.appendSlice(s.a, s.pending.items) catch unreachable;
            },
        }
    }
};

test "matcher: background replace atomically" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var m = try pm.Matcher.init(gpa, pm.builtinNamed("zig-watch").?, "/w", .{ .style = .posix });
    defer m.deinit();
    var s: Swap = .{ .a = arena.allocator() };
    const feed = struct {
        fn f(mm: *pm.Matcher, sw: *Swap, text: []const u8) void {
            mm.feedBytes(text, sw.sink());
        }
    }.f;
    feed(&m, &s, "a.zig:1:1: error: first\nBuild Summary: 0/3 steps succeeded (1 failed)\n");
    try testing.expectEqual(@as(usize, 1), s.shown.items.len);
    // The next update: the old problem stays shown until it ends.
    s.flicker = false;
    feed(&m, &s, "compile exe demo Debug native 1 errors\nb.zig:2:2: error: second\n");
    try testing.expectEqualStrings("first", s.shown.items[0]);
    try testing.expect(!s.flicker);
    feed(&m, &s, "Build Summary: 0/3 steps succeeded (1 failed)\n");
    try testing.expectEqualStrings("second", s.shown.items[0]);
    // A clean rebuild clears.
    feed(&m, &s, "Build Summary: 3/3 steps succeeded\n");
    try testing.expectEqual(@as(usize, 0), s.shown.items.len);
}

test "matcher: ANSI stripping" {
    const cases = [_][2][]const u8{
        .{ "\x1b[1m\x1b[31merror\x1b[0m: x", "error: x" },
        .{ "a\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\b", "alinkb" },
        .{ "t\x1b]0;title\x07u", "tu" },
        .{ "p\x1bPq#0;2;0;0;0\x1b\\q", "pq" },
        .{ "crlf\r\nnext", "crlf\nnext" },
        .{ "\x1b[2J\x1b[3J\x1b[Hcleared", "cleared" },
    };
    for (cases) |c| {
        const got = try ansi.strip(gpa, c[0]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
    // The clear-screen is reported with the line after it.
    var sp: ansi.LineSplitter = try .init(gpa);
    defer sp.deinit(gpa);
    var seen: [3]bool = undefined;
    var n: usize = 0;
    const Ctx = struct { seen: *[3]bool, n: *usize };
    sp.feed("one\n\x1b[2Jtwo\nthree\n", Ctx{ .seen = &seen, .n = &n }, struct {
        fn f(c: Ctx, _: []const u8, cleared: bool) void {
            c.seen[c.n.*] = cleared;
            c.n.* += 1;
        }
    }.f);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(bool, &.{ false, true, false }, &seen);
    // Overlong lines are cut, not split.
    const long = try gpa.alloc(u8, ansi.max_line + 100);
    defer gpa.free(long);
    @memset(long, 'x');
    long[long.len - 1] = '\n';
    const cut = try ansi.strip(gpa, long);
    defer gpa.free(cut);
    try testing.expectEqual(@as(usize, ansi.max_line + 1), cut.len);
}

test "matcher: dedup same file/line/col" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const got = try run(arena.allocator(), pm.builtinNamed("gcc").?, "/w", .posix, &.{
        "a.c:3:10: error: 'y' undeclared",
        "a.c:3:10: error: 'y' undeclared (again, from another include)",
        "a.c:3:11: error: next column",
    });
    try expectLines(&.{ "/w/a.c:3:10 'y' undeclared", "/w/a.c:3:11 next column" }, got);
}

test "matcher: idle releases a held error" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var m = try pm.Matcher.init(gpa, pm.builtinNamed("zig").?, "/w", .{ .style = .posix });
    defer m.deinit();
    var rec: Rec = .{ .arena = arena.allocator() };
    m.feed("a.zig:1:1: error: waits for its notes", rec.sink());
    try testing.expectEqual(@as(usize, 0), rec.events.items.len);
    m.idle(rec.sink());
    try testing.expectEqual(@as(usize, 1), rec.events.items.len);
    // A note with nothing before it stands alone, as info.
    m.feed("a.zig:2:1: note: alone", rec.sink());
    m.finish(rec.sink());
    try testing.expectEqual(pm.Severity.info, rec.events.items[1].problem.severity);
}

test "matcher: every built-in compiles" {
    for (pm.builtins) |*d| {
        var m = try pm.Matcher.init(gpa, d, "/w", .{});
        m.deinit();
    }
}

fn fuzzFeed(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const n = smith.slice(&buf);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for ([_][]const u8{ "zig-watch", "rustc", "eslint-stylish", "python" }) |name| {
        var m = try pm.Matcher.init(gpa, pm.builtinNamed(name).?, "/w", .{});
        defer m.deinit();
        var rec: Rec = .{ .arena = arena.allocator() };
        m.feedBytes(buf[0..n], rec.sink());
        m.finish(rec.sink());
    }
}

test "fuzz-matcher-feed: arbitrary output never crashes the matchers" {
    try std.testing.fuzz({}, fuzzFeed, .{});
}

test "matcher: $zig hand split agrees with the regex" {
    const zon_re = pm.builtinNamed("zig").?.patterns[0];
    const zg_regex = @import("zg_regex");
    var re = try zg_regex.Regex.compile(gpa, zon_re.regexp, .{});
    defer re.deinit(gpa);
    var cache = try re.newCache(gpa);
    defer cache.deinit();
    var caps = try re.newCaptures(gpa);
    defer caps.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var lines: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "zig_build_exe", "zig_build_verbose", "zig_watch" }) |f| {
        var it = std.mem.splitScalar(u8, try readFixture(a, try std.mem.concat(a, u8, &.{ f, ".txt" })), '\n');
        while (it.next()) |l| try lines.append(a, l);
    }
    try lines.appendSlice(a, &.{
        "a:b:1:2: error: colon in the name",
        "C:\\x\\y.zig:1:2: warning: drive letter",
        "x:1:2: error: y:3:4: note: two in one",
        "x:1:2: errors: not a word",
        "x::2: error: no line",
        "x:1:2:  error: two spaces",
        ":1:2: error: no file",
        "x:1:2: note: ",
        "x:1:2: error:",
    });
    // Random lines over the characters that matter.
    var prng: std.Random.DefaultPrng = .init(5);
    const alphabet = "ab:12 enrotwig";
    for (0..5000) |_| {
        const n = prng.random().uintLessThan(usize, 40);
        const l = try a.alloc(u8, n);
        for (l) |*c| c.* = alphabet[prng.random().uintLessThan(usize, alphabet.len)];
        try lines.append(a, l);
        try lines.append(a, try std.mem.concat(a, u8, &.{ l, ":1:2: error: m" }));
    }
    for (lines.items) |l| {
        const want = re.captures(&cache, .fromSlice(l), &caps);
        const got = pm.splitShape(zon_re.shape.?, l);
        try testing.expectEqual(want, got != null);
        if (!want) continue;
        for (1..6) |g| {
            const m = caps.get(g).?;
            try testing.expectEqual(@as(u32, @intCast(m.start)), got.?[g][0]);
            try testing.expectEqual(@as(u32, @intCast(m.end)), got.?[g][1]);
        }
    }
}
