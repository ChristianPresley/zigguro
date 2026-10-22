//! Tests for `zg_ignore.wildmatch`: git's t3070 expectation table, fast-path
//! classification, POSIX classes, pathological patterns and a randomized
//! comparison against a slow reference matcher written from gitignore(5).

const std = @import("std");
const zg_ignore = @import("zg_ignore");
const zg_core = @import("zg_core");
const wm = zg_ignore.wildmatch;
const testdata = @import("../testing/testdata.zig");

const Row = struct { pattern: []const u8, text: []const u8, glob: bool, iglob: bool, path: bool, ipath: bool };

fn check(arena: std.mem.Allocator, pattern: []const u8, text: []const u8, pathname: bool, fold: bool) !bool {
    const p = wm.compile(arena, pattern, .{ .pathname = pathname }) catch |err| switch (err) {
        error.InvalidPattern => return false,
        else => return err,
    };
    return wm.match(&p, text, .{ .casefold = fold });
}

test "wildmatch: git t3070 table" {
    // testdata/wildmatch/t3070.zon is transcribed from git's t/t3070-wildmatch.sh.
    const gpa = std.testing.allocator;
    const src = try testdata.read(gpa, "testdata/wildmatch/t3070.zon");
    defer gpa.free(src);
    const rows = try std.zon.parse.fromSliceAlloc([]const Row, gpa, src, null, .{});
    defer std.zon.parse.free(gpa, rows);
    try std.testing.expect(rows.len >= 180);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failures: usize = 0;
    for (rows) |r| {
        const got = [4]bool{
            try check(arena, r.pattern, r.text, true, false),
            try check(arena, r.pattern, r.text, true, true),
            try check(arena, r.pattern, r.text, false, false),
            try check(arena, r.pattern, r.text, false, true),
        };
        const want = [4]bool{ r.glob, r.iglob, r.path, r.ipath };
        if (!std.mem.eql(bool, &got, &want)) {
            failures += 1;
            std.debug.print("t3070 mismatch: pattern '{s}' text '{s}' want {any} got {any}\n", .{ r.pattern, r.text, want, got });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "wildmatch: fast path classification table" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { []const u8, wm.Pattern.Kind, []const u8 };
    const cases = [_]Case{
        .{ "foo", .literal, "foo" },
        .{ "a\\*b", .literal, "a*b" },
        .{ "*.o", .extension, ".o" },
        .{ "*.tar.gz", .suffix, ".tar.gz" },
        .{ "*abc", .suffix, "abc" },
        .{ "abc*", .prefix, "abc" },
        .{ "*abc*", .contains, "abc" },
        .{ "a/*.o", .general, "" },
        .{ "**/foo", .general, "" },
        .{ "f?o", .general, "" },
        .{ "[ab]", .general, "" },
        .{ "[", .never, "" },
        .{ "[[:nope:]]", .never, "" },
    };
    for (cases) |c| {
        const p = try wm.compile(arena, c[0], .{});
        try std.testing.expectEqual(c[1], p.kind);
        try std.testing.expectEqualStrings(c[2], p.literal);
    }
    try std.testing.expectError(error.InvalidPattern, wm.compile(arena, "abc\\", .{}));
    // Fast paths agree with the general program.
    const ext = try wm.compile(arena, "*.o", .{});
    try std.testing.expect(wm.match(&ext, "main.o", .{}));
    try std.testing.expect(!wm.match(&ext, "dir/main.o", .{}));
    try std.testing.expect(wm.match(&ext, "MAIN.O", .{ .casefold = true }));
    const pre = try wm.compile(arena, "abc*", .{});
    try std.testing.expect(wm.match(&pre, "abcdef", .{}));
    try std.testing.expect(!wm.match(&pre, "abc/def", .{}));
}

test "wildmatch: pathological patterns complete under 1 ms" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try arena.alloc(u8, 10 * 1024);
    @memset(text, 'a');
    const pats = [_][]const u8{ "*a*a*a*a*a*a*a*b", "**/*a*a*a*a*b", "*?*?*?*?*?*b", "**a**a**a**a**b" };
    for (pats) |ps| {
        inline for (.{ true, false }) |pathname| {
            const p = try wm.compile(arena, ps, .{ .pathname = pathname });
            var sw = zg_core.time.Stopwatch.start(std.testing.io);
            try std.testing.expect(!wm.match(&p, text, .{}));
            const ns = sw.readNs(std.testing.io);
            if (@import("builtin").mode != .Debug) try std.testing.expect(ns < std.time.ns_per_ms);
        }
    }
}

test "wildmatch: posix classes and casefold" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const T = struct { []const u8, []const u8, bool, bool };
    const cases = [_]T{
        .{ "[[:alpha:]]", "q", true, true },
        .{ "[[:digit:]]x", "7x", true, true },
        .{ "[[:upper:]]", "a", false, true },
        .{ "[[:lower:]]", "A", false, true },
        .{ "[[:space:]]", "\t", true, true },
        .{ "[[:xdigit:]]", "F", true, true },
        .{ "[[:punct:]]", "!", true, true },
        .{ "[[:alnum:][:blank:]]", " ", true, true },
        .{ "[A-Z]", "q", false, true },
        .{ "[!a-z]", "Q", true, false },
        .{ "README", "readme", false, true },
        .{ "*.MD", "notes.md", false, true },
        .{ "[[:alpha:]]", "\xc3", false, false },
        .{ "[a/]", "/", false, false },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c[2], try check(a, c[0], c[1], true, false));
        try std.testing.expectEqual(c[3], try check(a, c[0], c[1], true, true));
    }
}

test "wildmatch: double star segments" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const T = struct { []const u8, []const u8, bool };
    const cases = [_]T{
        .{ "**/foo", "foo", true },
        .{ "**/foo", "a/b/foo", true },
        .{ "a/**/b", "a/b", true },
        .{ "a/**/b", "a/x/y/b", true },
        .{ "a/**", "a/x/y", true },
        .{ "a/**", "a", false },
        .{ "a**b", "a/b", false },
        .{ "a/*/b", "a/x/y/b", false },
        .{ "**", "x/y/z", true },
    };
    for (cases) |c| try std.testing.expectEqual(c[2], try check(a, c[0], c[1], true, false));
}

/// Slow reference matcher written directly from gitignore(5), for the
/// restricted alphabet the randomized tests use (no classes or escapes).
fn refMatch(p: []const u8, t: []const u8, pathname: bool) bool {
    return refAt(p, t, pathname, true);
}

fn refAt(p: []const u8, t: []const u8, pathname: bool, seg_start: bool) bool {
    if (p.len == 0) return t.len == 0;
    switch (p[0]) {
        '?' => return t.len > 0 and !(pathname and t[0] == '/') and refAt(p[1..], t[1..], pathname, false),
        '*' => {
            var run: usize = 0;
            while (run < p.len and p[run] == '*') run += 1;
            const rest = p[run..];
            const whole_seg = pathname and run >= 2 and seg_start and (rest.len == 0 or rest[0] == '/');
            if (!pathname or (whole_seg and rest.len == 0)) {
                // Matches any run of bytes.
                var k: usize = 0;
                while (k <= t.len) : (k += 1) if (refAt(rest, t[k..], pathname, false)) return true;
                return false;
            }
            if (whole_seg) {
                // "**/": zero or more leading directories (a prefix ending in '/').
                if (refAt(rest[1..], t, pathname, true)) return true;
                for (t, 0..) |c, k| if (c == '/' and refAt(rest[1..], t[k + 1 ..], pathname, true)) return true;
                return false;
            }
            var k: usize = 0;
            while (k <= t.len) : (k += 1) {
                if (refAt(rest, t[k..], pathname, false)) return true;
                if (k < t.len and t[k] == '/') break;
            }
            return false;
        },
        else => return t.len > 0 and t[0] == p[0] and refAt(p[1..], t[1..], pathname, p[0] == '/'),
    }
}

fn genPattern(r: std.Random, buf: []u8) []const u8 {
    const toks = [_][]const u8{ "a", "b", "/", "*", "**", "?", "**/", "/**" };
    var n: usize = 0;
    const count = r.uintAtMost(usize, 6);
    for (0..count) |_| {
        const tok = toks[r.uintLessThan(usize, toks.len)];
        if (n + tok.len > buf.len) break;
        @memcpy(buf[n..][0..tok.len], tok);
        n += tok.len;
    }
    return buf[0..n];
}

fn genText(r: std.Random, buf: []u8) []const u8 {
    const n = r.uintAtMost(usize, @min(buf.len, 9));
    for (buf[0..n]) |*c| c.* = "ab/"[r.uintLessThan(usize, 3)];
    return buf[0..n];
}

fn agree(arena: std.mem.Allocator, pattern: []const u8, text: []const u8) !void {
    for ([_]bool{ true, false }) |pathname| {
        const want = refMatch(pattern, text, pathname);
        const got = try check(arena, pattern, text, pathname, false);
        if (want != got) {
            std.debug.print("disagree: pattern '{s}' text '{s}' pathname={} ref={} got={}\n", .{ pattern, text, pathname, want, got });
            return error.TestUnexpectedResult;
        }
    }
}

test "wildmatch: agrees with the reference matcher on random pairs" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var prng: std.Random.DefaultPrng = .init(0x3070);
    const r = prng.random();
    var pb: [32]u8 = undefined;
    var tb: [16]u8 = undefined;
    for (0..20_000) |_| {
        _ = arena_state.reset(.retain_capacity);
        try agree(arena_state.allocator(), genPattern(r, &pb), genText(r, &tb));
    }
}

test "fuzz: wildmatch" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            const sep = std.mem.indexOfScalar(u8, input, 0) orelse input.len;
            var pat: [64]u8 = undefined;
            var n: usize = 0;
            // Keep the reference's alphabet: map every byte onto it.
            for (input[0..sep]) |c| {
                pat[n] = "ab/*?"[c % 5];
                n += 1;
            }
            var txt: [64]u8 = undefined;
            const rest = if (sep < input.len) input[sep + 1 ..] else "";
            for (rest, 0..) |c, i| txt[i] = "ab/"[c % 3];
            var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena_state.deinit();
            try agree(arena_state.allocator(), pat[0..n], txt[0..rest.len]);
            // Arbitrary bytes must never crash the compiler or matcher.
            const p = wm.compile(arena_state.allocator(), input[0..sep], .{}) catch return;
            _ = wm.match(&p, rest, .{ .casefold = true });
        }
    }.one, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "wildmatch") });
}
