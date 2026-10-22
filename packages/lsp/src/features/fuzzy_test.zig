//! Tests for `fuzzy.zig`.

const std = @import("std");
const testing = std.testing;
const fuzzy = @import("fuzzy.zig");
const Fuzzy = fuzzy.Fuzzy;

var scratch: fuzzy.Scratch = .{};

fn scoreOf(pattern: []const u8, candidate: []const u8) ?i32 {
    const f: Fuzzy = .init(pattern);
    return f.score(candidate, &scratch, null);
}

test "fuzzy: table" {
    // Word-start hump beats an in-word match.
    try testing.expect(scoreOf("fb", "fooBar").? > scoreOf("fb", "fob").?);
    try testing.expect(scoreOf("pa", "parseArgs").? > scoreOf("pa", "compare").?);
    try testing.expect(scoreOf("ga", "get_args").? > scoreOf("ga", "garbage").? - 100);
    try testing.expect(scoreOf("ga", "get_args").? > scoreOf("ga", "getxargs").?);
    // Exact case bonus.
    try testing.expect(scoreOf("Foo", "Foo").? > scoreOf("Foo", "foo").?);
    // Prefix beats a late match.
    try testing.expect(scoreOf("ab", "abc").? > scoreOf("ab", "xxxxab").?);
    // No match.
    try testing.expectEqual(@as(?i32, null), scoreOf("xyz", "fooBar"));
    try testing.expectEqual(@as(?i32, null), scoreOf("abc", "ab"));
    // Empty pattern.
    try testing.expectEqual(@as(?i32, 0), scoreOf("", "anything"));
}

test "fuzzy: match positions" {
    const f: Fuzzy = .init("fb");
    var out: [fuzzy.max_pattern]u16 = undefined;
    _ = f.score("fooBar", &scratch, &out).?;
    try testing.expectEqualSlices(u16, &.{ 0, 3 }, out[0..2]);

    const g: Fuzzy = .init("pargs");
    _ = g.score("parse_args", &scratch, &out).?;
    // `p`, then all of `args` from its word start.
    try testing.expectEqualSlices(u16, &.{ 0, 6, 7, 8, 9 }, out[0..5]);
}

test "fuzzy: monotonic refilter" {
    const words = [_][]const u8{ "fooBar", "foo_bar", "barFoo", "f", "FOOBAR", "frob", "xfooBarx" };
    const patterns = [_][]const u8{ "f", "fo", "fob", "fobr", "fobrx", "b", "ba", "bar" };
    for (words) |w| {
        var failed = false;
        for (patterns) |p| {
            if (p.len == 1) failed = false;
            const s = scoreOf(p, w);
            if (failed) try testing.expectEqual(@as(?i32, null), s);
            if (s == null) failed = true;
        }
    }
}

test "fuzzy: long candidates (>255) fallback positions" {
    const long = "x" ** 300 ++ "fooBar";
    const f: Fuzzy = .init("fb");
    var out: [fuzzy.max_pattern]u16 = undefined;
    try testing.expect(f.score(long, &scratch, &out) != null);
    try testing.expectEqualSlices(u16, &.{ 300, 303 }, out[0..2]);
}

test "fuzzy: isWordStart" {
    try testing.expect(fuzzy.isWordStart('_', 'a'));
    try testing.expect(fuzzy.isWordStart('o', 'B'));
    try testing.expect(fuzzy.isWordStart('a', '1'));
    try testing.expect(!fuzzy.isWordStart('a', 'b'));
    try testing.expect(!fuzzy.isWordStart('A', 'B'));
}

test "fuzz: lsp fuzzy" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var pat: [80]u8 = undefined;
            var cand: [300]u8 = undefined;
            const np = s.slice(&pat);
            const nc = s.slice(&cand);
            const f: Fuzzy = .init(pat[0..np]);
            var out: [fuzzy.max_pattern]u16 = undefined;
            var sc: fuzzy.Scratch = .{};
            if (f.score(cand[0..nc], &sc, &out) != null) {
                // Positions are strictly increasing and in range.
                for (0..f.len) |i| {
                    try testing.expect(out[i] < nc);
                    if (i > 0) try testing.expect(out[i] > out[i - 1]);
                }
            }
        }
    }.one, .{});
}
