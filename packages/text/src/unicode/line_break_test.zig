//! UAX #14 conformance (LineBreakTest.txt) and behaviour tests for the
//! line-break iterator, including the code tailoring.

const std = @import("std");
const testing = std.testing;
const lb = @import("line_break.zig");
const seg = @import("segment_test.zig");

fn collect(bytes: []const u8, opts: lb.Options, out: []lb.Break) []lb.Break {
    var it = lb.Iterator.init(bytes, opts);
    var n: usize = 0;
    while (it.next()) |b| {
        out[n] = b;
        n += 1;
    }
    return out[0..n];
}

/// Offsets of allowed breaks plus mandatory ones, excluding the end.
fn offsets(bytes: []const u8, opts: lb.Options, buf: []usize) []usize {
    var bs: [512]lb.Break = undefined;
    const all = collect(bytes, opts, &bs);
    var n: usize = 0;
    for (all) |b| {
        if (b.offset == bytes.len) continue;
        buf[n] = b.offset;
        n += 1;
    }
    return buf[0..n];
}

test "LineBreakTest.txt conformance" {
    const data = try seg.readUcd(testing.allocator, "auxiliary/LineBreakTest.txt");
    defer testing.allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    var n: usize = 0;
    var cases: usize = 0;
    var failed: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const c = (try seg.parseCase(raw, n)) orelse continue;
        cases += 1;
        var buf: [256]usize = undefined;
        const got = offsets(c.bytes(), .{}, &buf);
        if (!std.mem.eql(usize, c.breaks[0..c.nbreaks], got)) {
            failed += 1;
            if (failed <= 10) std.debug.print("line {d}: want {any} got {any}\n  {s}\n", .{ n, c.breaks[0..c.nbreaks], got, raw });
        }
    }
    try testing.expect(cases > 19000);
    try testing.expectEqual(@as(usize, 0), failed);
}

fn expectOffsets(text: []const u8, opts: lb.Options, want: []const usize) !void {
    var buf: [128]usize = undefined;
    const got = offsets(text, opts, &buf);
    testing.expectEqualSlices(usize, want, got) catch |e| {
        std.debug.print("text: \"{s}\"\n", .{text});
        return e;
    };
}

test "mandatory breaks crlf" {
    var bs: [16]lb.Break = undefined;
    const got = collect("a\r\nb\rc\nd", .{}, &bs);
    const want = [_]lb.Break{
        .{ .offset = 3, .kind = .mandatory },
        .{ .offset = 5, .kind = .mandatory },
        .{ .offset = 7, .kind = .mandatory },
        .{ .offset = 8, .kind = .mandatory },
    };
    try testing.expectEqualSlices(lb.Break, &want, got);
    // U+2028 LINE SEPARATOR (BK) and U+0085 NEXT LINE (NL).
    try testing.expectEqualSlices(lb.Break, &.{
        .{ .offset = 4, .kind = .mandatory },
        .{ .offset = 7, .kind = .mandatory },
        .{ .offset = 8, .kind = .mandatory },
    }, collect("a\u{2028}b\u{85}c", .{}, &bs));
    try testing.expectEqual(@as(usize, 0), collect("", .{}, &bs).len);
}

test "emoji modifier no break" {
    // 👍🏽 (EB EM) is one unit; between two of them is an opportunity.
    try expectOffsets("👍🏽👍🏽", .{}, &.{8});
    // Unassigned Extended_Pictographic + EM (LB30b).
    try expectOffsets("\u{1FC00}\u{1F3FD}", .{}, &.{});
}

test "RI pairs" {
    // Three flags' worth of RIs: breaks only between pairs.
    try expectOffsets("🇺🇸🇫🇷🇩🇪", .{}, &.{ 8, 16 });
    try expectOffsets("🇺🇸🇫", .{}, &.{8});
}

test "lb25 numbers" {
    try expectOffsets("$(12.35)", .{}, &.{});
    try expectOffsets("12,345.67%", .{}, &.{});
    try expectOffsets("cost $(12.35) now", .{}, &.{ 5, 14 });
    try expectOffsets("-12.5e", .{}, &.{});
}

test "spaces and hyphens" {
    try expectOffsets("hello world", .{}, &.{6});
    try expectOffsets("well-known fact", .{}, &.{ 5, 11 });
    try expectOffsets("a  b", .{}, &.{3});
    // OP SP* × (LB14): no break inside "( x".
    try expectOffsets("( x", .{}, &.{});
    // Non-breaking space (GL).
    try expectOffsets("a\u{a0}b c", .{}, &.{5});
}

test "CJ resolution" {
    // U+3041 HIRAGANA LETTER SMALL A is CJ: NS (no break before) by
    // default, ID (break before) when loose.
    try expectOffsets("\u{3042}\u{3041}", .{}, &.{});
    try expectOffsets("\u{3042}\u{3041}", .{ .loose_cj = true }, &.{3});
}

test "code tailoring url" {
    const url = "see https://example.com/a?b=1&c=2#frag ok";
    var buf: [64]usize = undefined;
    const plain = offsets(url, .{}, &buf);
    try testing.expect(std.mem.indexOfScalar(usize, plain, std.mem.indexOfScalar(u8, url, '?').?) == null);
    var tb: [64]usize = undefined;
    const tail = offsets(url, .{ .code_tailoring = true }, &tb);
    for ("?=&#") |ch| {
        const at = std.mem.indexOfScalarPos(u8, url, 20, ch).?;
        try testing.expect(std.mem.indexOfScalar(usize, tail, at) != null);
    }
    // Outside a URL-like run, '=' is not a new opportunity.
    try expectOffsets("a=b", .{ .code_tailoring = true }, &.{});
    try expectOffsets("www.x.org?q", .{ .code_tailoring = true }, &.{ 9, 10 });
}

test "code tailoring operators" {
    // Default rules break inside "->" and "!=".
    try expectOffsets("a->b", .{}, &.{2});
    try expectOffsets("x!=y", .{}, &.{2});
    try expectOffsets("a->b", .{ .code_tailoring = true }, &.{});
    try expectOffsets("x!=y", .{ .code_tailoring = true }, &.{});
    try expectOffsets("a::b <= c", .{ .code_tailoring = true }, &.{ 5, 8 });
    // Tailoring is off by default.
    try testing.expect(!(lb.Options{}).code_tailoring);
}

fn lastForward(bytes: []const u8, limit: usize, opts: lb.Options) ?lb.Break {
    var it = lb.Iterator.init(bytes, opts);
    var last: ?lb.Break = null;
    while (it.next()) |b| {
        if (b.offset > limit) break;
        last = b;
    }
    return last;
}

test "lastOpportunityBefore equals forward scan" {
    const words = [_][]const u8{ "the", "quick", "brown", "fox—jumps", "over", "(lazy)", "dogs,", "12.5%", "日本語", "テキスト", "naïve", "co-op", "\u{0915}\u{094D}\u{0937}", "👍🏽", "“quoted”", "\n" };
    var buf: [8192]u8 = undefined;
    var len: usize = 0;
    var rng = std.Random.DefaultPrng.init(14);
    const r = rng.random();
    while (len < buf.len - 64) {
        const w = words[r.uintLessThan(usize, words.len)];
        @memcpy(buf[len..][0..w.len], w);
        len += w.len;
        buf[len] = ' ';
        len += 1;
    }
    const text = buf[0..len];
    var limit: usize = 0;
    while (limit <= text.len) : (limit += 7) {
        try testing.expectEqual(lastForward(text, limit, .{}), lb.lastOpportunityBefore(text, limit, .{}));
    }
}

fn checkConsistency(input: []const u8) !void {
    var it = lb.Iterator.init(input, .{});
    var prev: usize = 0;
    var count: usize = 0;
    while (it.next()) |b| {
        try testing.expect(b.offset > prev);
        try testing.expect(b.offset <= input.len);
        prev = b.offset;
        count += 1;
    }
    if (input.len > 0) try testing.expectEqual(input.len, prev);
    var t = lb.Iterator.init(input, .{ .code_tailoring = true, .loose_cj = true });
    prev = 0;
    while (t.next()) |b| {
        try testing.expect(b.offset > prev);
        prev = b.offset;
    }
    if (input.len > 0) _ = lb.lastOpportunityBefore(input, input.len / 2, .{});
}

test "fuzz: unicode-linebreak" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [300]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            try checkConsistency(input);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "unicode-linebreak") });
}
