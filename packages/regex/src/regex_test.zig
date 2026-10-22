//! End-to-end regex tests: API behaviour, the differential test against the
//! backtracking reference, engine consistency, chunked inputs and
//! pathological patterns.

const std = @import("std");
const zg_core = @import("zg_core");
const root = @import("root.zig");
const ref = @import("testing/backtrack_ref.zig");
const pikevm = @import("engine/pikevm.zig");
const lazy_dfa = @import("engine/lazy_dfa.zig");

const testing = std.testing;
const Regex = root.Regex;
const Input = root.Input;

fn expectFind(pattern: []const u8, hay: []const u8, want: ?[2]u64) !void {
    var re = try Regex.compile(testing.allocator, pattern, .{});
    defer re.deinit(testing.allocator);
    var cache = try re.newCache(testing.allocator);
    defer cache.deinit();
    const got = re.find(&cache, .fromSlice(hay));
    if (want) |w| {
        const m = got orelse {
            std.debug.print("{s} on {s}: want {d}..{d}, got none\n", .{ pattern, hay, w[0], w[1] });
            return error.TestUnexpectedResult;
        };
        if (m.start != w[0] or m.end != w[1]) {
            std.debug.print("{s} on {s}: want {d}..{d}, got {d}..{d}\n", .{ pattern, hay, w[0], w[1], m.start, m.end });
            return error.TestUnexpectedResult;
        }
    } else if (got) |m| {
        std.debug.print("{s} on {s}: want none, got {d}..{d}\n", .{ pattern, hay, m.start, m.end });
        return error.TestUnexpectedResult;
    }
}

test "regex: find basics" {
    try expectFind("abc", "xxabcxx", .{ 2, 5 });
    try expectFind("a+", "baaab", .{ 1, 4 });
    try expectFind("a+?", "baaab", .{ 1, 2 });
    try expectFind("a|ab", "ab", .{ 0, 1 });
    try expectFind("ab|a", "ab", .{ 0, 2 });
    try expectFind("(?i)hello", "say HeLLo", .{ 4, 9 });
    try expectFind("^abc$", "abc", .{ 0, 3 });
    try expectFind("^abc$", "abcd", null);
    try expectFind("(?m)^b", "a\nb", .{ 2, 3 });
    try expectFind("\\bfoo\\b", "a foo b", .{ 2, 5 });
    try expectFind("\\bfoo\\b", "afoob", null);
    try expectFind("\\w+", "  héllo  ", .{ 2, 8 });
    try expectFind("(?-u)\\w+", "  héllo  ", .{ 2, 3 });
    try expectFind("\\p{Greek}+", "abc αβγ def", .{ 4, 10 });
    try expectFind("[^a]", "aaé", .{ 2, 4 });
    try expectFind("", "abc", .{ 0, 0 });
    try expectFind("x*", "abc", .{ 0, 0 });
    try expectFind("\\d{3}-\\d{4}", "call 555-1234 now", .{ 5, 13 });
    try expectFind("foo|bar|baz", "xxbazxx", .{ 2, 5 });
    try expectFind("(?s).", "\n", .{ 0, 1 });
    try expectFind(".", "\n", null);
    try expectFind("(?R)^b$", "a\r\nb", null);
    try expectFind("(?mR)^b$", "a\r\nb\r\n", .{ 3, 4 });
    try expectFind("\\Bb", "ab", .{ 1, 2 });
    try expectFind("\\b{start}\\w", " ab", .{ 1, 2 });
    try expectFind("\\w\\b{end}", "ab ", .{ 1, 2 });
}

test "regex: captures and names" {
    const gpa = testing.allocator;
    var re = try Regex.compile(gpa, "(?P<year>\\d{4})-(\\d{2})(-(?<day>\\d{2}))?", .{});
    defer re.deinit(gpa);
    var cache = try re.newCache(gpa);
    defer cache.deinit();
    var caps = try re.newCaptures(gpa);
    defer caps.deinit(gpa);
    try testing.expect(re.captures(&cache, .fromSlice("on 2026-10 ok"), &caps));
    try testing.expectEqual(@as(usize, 5), caps.len());
    try testing.expectEqual(@as(u64, 3), caps.get(0).?.start);
    try testing.expectEqual(@as(u64, 10), caps.get(0).?.end);
    try testing.expectEqual(@as(u64, 7), caps.get(1).?.end);
    try testing.expect(caps.get(3) == null);
    try testing.expectEqualStrings("year", re.captureNames()[1].?);
    try testing.expect(re.captureNames()[2] == null);
    try testing.expectEqualStrings("day", re.captureNames()[4].?);
}

test "regex: findIter empty-match rules" {
    const gpa = testing.allocator;
    const Case = struct { []const u8, []const u8, []const [2]u64 };
    const cases = [_]Case{
        .{ "a*", "baaab", &.{ .{ 0, 0 }, .{ 1, 4 }, .{ 5, 5 } } },
        .{ "", "é", &.{ .{ 0, 0 }, .{ 2, 2 } } },
        .{ "\\d+", "a1b22c333", &.{ .{ 1, 2 }, .{ 3, 5 }, .{ 6, 9 } } },
        .{ "a|", "aa", &.{ .{ 0, 1 }, .{ 1, 2 } } },
        .{ "a?", "ba", &.{ .{ 0, 0 }, .{ 1, 2 } } },
    };
    for (cases) |c| {
        var re = try Regex.compile(gpa, c[0], .{});
        defer re.deinit(gpa);
        var cache = try re.newCache(gpa);
        defer cache.deinit();
        var it = re.findIter(&cache, .fromSlice(c[1]));
        for (c[2]) |w| {
            const m = it.next() orelse return error.TestUnexpectedResult;
            try testing.expectEqual(w[0], m.start);
            try testing.expectEqual(w[1], m.end);
        }
        try testing.expect(it.next() == null);
    }
}

test "regex: options, errors and helpers" {
    const gpa = testing.allocator;
    var diag: root.Error = undefined;
    try testing.expectError(error.Syntax, Regex.compile(gpa, "a(?=b)", .{ .diag = &diag }));
    try testing.expectEqual(root.ErrorKind.unsupported_lookaround, diag.kind);
    try testing.expectError(error.Syntax, Regex.compile(gpa, "\\p{Klingon}", .{ .diag = &diag }));
    try testing.expectEqual(root.ErrorKind.unicode_property_unknown, diag.kind);
    try testing.expectEqual(@as(u32, 0), diag.span.start);
    {
        var re = try Regex.compile(gpa, "a.b(", .{ .literal = true });
        defer re.deinit(gpa);
        var cache = try re.newCache(gpa);
        defer cache.deinit();
        try testing.expect(re.isMatch(&cache, .fromSlice("xa.b(")));
        try testing.expect(!re.isMatch(&cache, .fromSlice("axb(")));
    }
    {
        var re = try Regex.compile(gpa, "cat", .{ .whole_word = true });
        defer re.deinit(gpa);
        var cache = try re.newCache(gpa);
        defer cache.deinit();
        try testing.expect(!re.isMatch(&cache, .fromSlice("concatenate")));
        try testing.expect(re.isMatch(&cache, .fromSlice("a cat!")));
    }
    try testing.expect(root.smartCaseInsensitive("foo\\w"));
    try testing.expect(!root.smartCaseInsensitive("Foo"));
    try testing.expect(root.smartCaseInsensitive("\\Dfoo\\p{Greek}"));
    try testing.expect(!root.smartCaseInsensitive("Σ"));
    var set = try root.RegexSet.compile(gpa, &.{ "foo", "ba[rz]", "\\d+" }, .{});
    defer set.deinit();
    var sc = try set.newCache(gpa);
    defer sc.deinit();
    var bits = try std.DynamicBitSetUnmanaged.initEmpty(gpa, 3);
    defer bits.deinit(gpa);
    set.matches(&sc, .fromSlice("xx baz 12"), &bits);
    try testing.expect(!bits.isSet(0) and bits.isSet(1) and bits.isSet(2));
}

// -- differential testing ---------------------------------------------------

/// Generates a random pattern over a small alphabet from `s`.
fn genPattern(rnd: std.Random, buf: []u8) []const u8 {
    const atoms = [_][]const u8{ "a", "b", "c", ".", "[ab]", "[^a]", "\\w", "\\W", "\\d", "\\s", "\\b", "\\B", "^", "$", "(?m:^)", "(?m:$)", "é", "[a-cé]", "(?i:A)", "\\b{start}", "\\b{end}", "(?-u:\\w)", "(?-u:\\b)", "x?" };
    var n: usize = 0;
    var depth: usize = 0;
    const len = rnd.intRangeAtMost(usize, 1, 8);
    for (0..len) |_| {
        const r = rnd.intRangeAtMost(u8, 0, 99);
        var piece: []const u8 = undefined;
        if (r < 10 and depth < 3) {
            piece = if (rnd.boolean()) "(" else "(?:";
            depth += 1;
        } else if (r < 20 and depth > 0) {
            piece = ")";
            depth -= 1;
        } else if (r < 25 and n > 0 and depth > 0) {
            piece = "|";
        } else {
            piece = atoms[rnd.intRangeLessThan(usize, 0, atoms.len)];
        }
        if (n + piece.len + 8 > buf.len) break;
        @memcpy(buf[n..][0..piece.len], piece);
        n += piece.len;
        if (!std.mem.eql(u8, piece, "(") and !std.mem.eql(u8, piece, "(?:") and !std.mem.eql(u8, piece, "|") and !std.mem.eql(u8, piece, "^") and rnd.intRangeAtMost(u8, 0, 3) == 0) {
            const ops = [_][]const u8{ "*", "+", "?", "{1,2}", "*?", "+?", "{0,2}?" };
            const op = ops[rnd.intRangeLessThan(usize, 0, ops.len)];
            @memcpy(buf[n..][0..op.len], op);
            n += op.len;
        }
    }
    while (depth > 0) : (depth -= 1) {
        buf[n] = ')';
        n += 1;
    }
    return buf[0..n];
}

fn genHay(rnd: std.Random, buf: []u8) []const u8 {
    const pieces = [_][]const u8{ "a", "b", "c", "A", " ", "\n", "é", "1", "\xff", "\r" };
    var n: usize = 0;
    const len = rnd.intRangeAtMost(usize, 0, 10);
    for (0..len) |_| {
        const p = pieces[rnd.intRangeLessThan(usize, 0, pieces.len)];
        if (n + p.len > buf.len) break;
        @memcpy(buf[n..][0..p.len], p);
        n += p.len;
    }
    return buf[0..n];
}

fn checkOne(gpa: std.mem.Allocator, pattern: []const u8, hay: []const u8, stats: *Stats) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var re = Regex.compile(gpa, pattern, .{}) catch |e| switch (e) {
        error.Syntax => return,
        else => return e,
    };
    defer re.deinit(gpa);
    var cache = try re.newCache(gpa);
    defer cache.deinit();

    // Reference.
    const a = (try root.syntax.parse.parse(arena, pattern, .{})).ok;
    const h = (try root.syntax.translate.translate(arena, a, .{ .unicode = true })).ok;
    const groups = re.groupCount();
    const ref_slots = try arena.alloc(?u64, groups * 2);
    // Search every span start to exercise look-around outside the span.
    var span_start: usize = 0;
    while (span_start <= @min(hay.len, 3)) : (span_start += 1) {
        const in = Input.fromSlice(hay).withSpan(.{ .start = span_start, .end = hay.len });
        const outcome = ref.search(h, in, ref_slots, 100_000);
        if (outcome == .budget) {
            stats.skipped += 1;
            continue;
        }
        stats.checked += 1;
        const got = re.find(&cache, in);
        const want: ?[2]u64 = if (outcome == .match) .{ ref_slots[0].?, ref_slots[1].? } else null;
        const ok = if (want) |w| (got != null and got.?.start == w[0] and got.?.end == w[1]) else got == null;
        if (!ok) {
            std.debug.print("MISMATCH pattern={f} hay={f} span_start={d}: want ", .{ std.zig.fmtString(pattern), std.zig.fmtString(hay), span_start });
            if (want) |w| std.debug.print("{d}..{d}", .{ w[0], w[1] }) else std.debug.print("none", .{});
            if (got) |m| std.debug.print(" got {d}..{d}\n", .{ m.start, m.end }) else std.debug.print(" got none\n", .{});
            return error.TestUnexpectedResult;
        }
        // Engine consistency: the PikeVM alone agrees.
        var pc = try pikevm.Cache.init(gpa, &re.engines.fwd);
        defer pc.deinit(gpa);
        const slots = try arena.alloc(u64, groups * 2);
        const hm = pikevm.search(&re.engines.fwd, &pc, &in, slots);
        try testing.expectEqual(got != null, hm != null);
        if (hm) |x| {
            try testing.expectEqual(got.?.end, x.end);
            try testing.expectEqual(got.?.start, slots[0]);
        }
        // isMatch agrees.
        try testing.expectEqual(got != null, re.isMatch(&cache, in));
        // Captures agree with the reference when no loop body is nullable.
        if (got != null and !ref.hasNullableLoop(h)) {
            var caps = try re.newCaptures(gpa);
            defer caps.deinit(gpa);
            try testing.expect(re.captures(&cache, in, &caps));
            for (0..groups) |g| {
                const rs = ref_slots[2 * g];
                const re_ = ref_slots[2 * g + 1];
                const cg = caps.get(g);
                if (rs == null or re_ == null) {
                    if (cg != null) {
                        std.debug.print("CAPTURE MISMATCH {s} on {f} group {d}: want none\n", .{ pattern, std.zig.fmtString(hay), g });
                        return error.TestUnexpectedResult;
                    }
                } else {
                    if (cg == null or cg.?.start != rs.? or cg.?.end != re_.?) {
                        std.debug.print("CAPTURE MISMATCH {s} on {f} group {d}: want {d}..{d}\n", .{ pattern, std.zig.fmtString(hay), g, rs.?, re_.? });
                        return error.TestUnexpectedResult;
                    }
                }
            }
        }
        // Chunked input agrees for every split position.
        for (0..hay.len + 1) |cut| {
            const parts = [_][]const u8{ hay[0..cut], hay[cut..] };
            var starts: [2]u64 = undefined;
            const sc = root.SliceChunks.init(&parts, &starts);
            const cin = Input.fromChunks(sc.source(), hay.len).withSpan(in.span);
            const cm = re.find(&cache, cin);
            try testing.expectEqual(got != null, cm != null);
            if (cm) |x| {
                try testing.expectEqual(got.?.start, x.start);
                try testing.expectEqual(got.?.end, x.end);
            }
        }
    }
}

const Stats = struct { checked: usize = 0, skipped: usize = 0 };

test "regex: differential test against the backtracking reference" {
    var prng: std.Random.DefaultPrng = .init(0xdecafbad);
    const rnd = prng.random();
    var stats: Stats = .{};
    var pbuf: [64]u8 = undefined;
    var hbuf: [32]u8 = undefined;
    for (0..3000) |_| {
        const p = genPattern(rnd, &pbuf);
        const h = genHay(rnd, &hbuf);
        try checkOne(testing.allocator, p, h, &stats);
    }
    try testing.expect(stats.checked > 5000);
}

test "regex: pathological patterns run in linear time" {
    const gpa = testing.allocator;
    const hay_a = try gpa.alloc(u8, 100_000);
    defer gpa.free(hay_a);
    @memset(hay_a, 'a');
    const hay_x = try gpa.alloc(u8, 100_000);
    defer gpa.free(hay_x);
    @memset(hay_x, 'x');
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "(a*)*b", hay_a },
        .{ "(a|a)*c", hay_a },
        .{ "(x+x+)+y", hay_x },
        .{ "(?:a|aa)*$b", hay_a },
    };
    for (cases) |c| {
        var re = try Regex.compile(gpa, c[0], .{});
        defer re.deinit(gpa);
        var cache = try re.newCache(gpa);
        defer cache.deinit();
        var sw = zg_core.time.Stopwatch.start(testing.io);
        _ = re.find(&cache, .fromSlice(c[1]));
        const ns = sw.readNs(testing.io);
        // Budget: 50 ms per 100 KB; Debug builds get 20x headroom.
        const limit: u64 = if (@import("builtin").mode == .Debug) 1000 * std.time.ns_per_ms else 50 * std.time.ns_per_ms;
        if (ns > limit) {
            std.debug.print("{s}: {d} ms\n", .{ c[0], ns / std.time.ns_per_ms });
            return error.TestUnexpectedResult;
        }
    }
}

test "fuzz: regex differential" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var seed_buf: [8]u8 = undefined;
            _ = s.slice(&seed_buf);
            var prng: std.Random.DefaultPrng = .init(std.mem.readInt(u64, &seed_buf, .little));
            const rnd = prng.random();
            var pbuf: [64]u8 = undefined;
            var hbuf: [32]u8 = undefined;
            var stats: Stats = .{};
            try checkOne(testing.allocator, genPattern(rnd, &pbuf), genHay(rnd, &hbuf), &stats);
        }
    }.one, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "differential") });
}
