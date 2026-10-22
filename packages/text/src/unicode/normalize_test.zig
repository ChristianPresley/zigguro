//! UAX #15 conformance (NormalizationTest.txt) and tests for the
//! streaming decomposer and canonical caseless folding.

const std = @import("std");
const testing = std.testing;
const norm = @import("normalize.zig");
const fold = @import("casefold.zig");
const seg = @import("segment_test.zig");

fn parseField(field: []const u8, buf: []u8) ![]const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, field, ' ');
    while (it.next()) |t| n += try std.unicode.utf8Encode(try std.fmt.parseInt(u21, t, 16), buf[n..]);
    return buf[0..n];
}

fn expectForm(gpa: std.mem.Allocator, src: []const u8, form: norm.Form, want: []const u8, line: usize) !void {
    const got = try norm.normalize(gpa, src, form);
    defer gpa.free(got);
    testing.expectEqualSlices(u8, want, got) catch |e| {
        std.debug.print("line {d} form {t}: {x} -> {x}, want {x}\n", .{ line, form, src, got, want });
        return e;
    };
}

/// Streaming decomposition equals NFD/NFKD.
fn expectStream(src: []const u8, compat: bool, want: []const u8) !void {
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    var d = norm.Decomposer.init(src, compat);
    while (d.next()) |it| {
        try testing.expect(it.src_start < it.src_end and it.src_end <= src.len);
        n += try std.unicode.utf8Encode(it.cp, buf[n..]);
    }
    try testing.expectEqualSlices(u8, want, buf[0..n]);
}

test "NormalizationTest.txt conformance" {
    const gpa = testing.allocator;
    const data = try seg.readUcd(gpa, "NormalizationTest.txt");
    defer gpa.free(data);
    var listed: std.DynamicBitSetUnmanaged = try .initEmpty(gpa, 0x110000);
    defer listed.deinit(gpa);
    var part: u8 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var ln: usize = 0;
    var cases: usize = 0;
    while (lines.next()) |raw| {
        ln += 1;
        if (raw.len == 0 or raw[0] == '#') continue;
        if (raw[0] == '@') {
            part = raw[5] - '0';
            continue;
        }
        var bufs: [5][256]u8 = undefined;
        var c: [5][]const u8 = undefined;
        var f = std.mem.splitScalar(u8, raw, ';');
        for (0..5) |k| c[k] = try parseField(f.next().?, &bufs[k]);
        if (part == 1) {
            const first = raw[0..std.mem.indexOfScalar(u8, raw, ';').?];
            listed.set(try std.fmt.parseInt(u21, first, 16));
        }
        cases += 1;
        for (0..5) |k| {
            try expectForm(gpa, c[k], .nfc, if (k < 3) c[1] else c[3], ln);
            try expectForm(gpa, c[k], .nfd, if (k < 3) c[2] else c[4], ln);
            try expectForm(gpa, c[k], .nfkc, c[3], ln);
            try expectForm(gpa, c[k], .nfkd, c[4], ln);
        }
        try expectStream(c[0], false, c[2]);
        try expectStream(c[0], true, c[4]);
    }
    try testing.expect(cases > 19000);
    // Part 1: every code point not listed is invariant under every form.
    var cp: u21 = 0;
    while (cp < 0x110000) : (cp += 1) {
        if (cp >= 0xD800 and cp <= 0xDFFF) continue;
        if (listed.isSet(cp)) continue;
        var b: [4]u8 = undefined;
        const s = b[0..try std.unicode.utf8Encode(cp, &b)];
        inline for (.{ norm.Form.nfc, .nfd, .nfkc, .nfkd }) |form| {
            if (norm.isNormalizedQuick(s, form) == .no) {
                std.debug.print("U+{X} not invariant under {t}\n", .{ cp, form });
                return error.TestUnexpectedResult;
            }
        }
        // Spot-check the full algorithm too (every 97th code point).
        if (cp % 97 == 0) inline for (.{ norm.Form.nfc, .nfd, .nfkc, .nfkd }) |form| try expectForm(gpa, s, form, s, cp);
    }
}

test "hangul compose/decompose" {
    const gpa = testing.allocator;
    // 한 = U+D55C = ᄒ U+1112 + ᅡ U+1161 + ᆫ U+11AB; 가 = U+AC00 (LV).
    try expectForm(gpa, "\u{D55C}\u{AC00}", .nfd, "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1161}", 0);
    try expectForm(gpa, "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1161}", .nfc, "\u{D55C}\u{AC00}", 0);
    // LV + T composes to LVT; a lone T stays.
    try expectForm(gpa, "\u{AC00}\u{11A8}", .nfc, "\u{AC01}", 0);
    try expectForm(gpa, "\u{11A8}", .nfc, "\u{11A8}", 0);
}

test "quick check yes for ascii and nfc samples" {
    for ([_]norm.Form{ .nfc, .nfd, .nfkc, .nfkd }) |form| {
        try testing.expectEqual(norm.QuickCheckResult.yes, norm.isNormalizedQuick("plain ASCII text that is long enough for the vector path", form));
    }
    try testing.expectEqual(norm.QuickCheckResult.yes, norm.isNormalizedQuick("caf\u{E9} \u{65E5}\u{672C}", .nfc));
    try testing.expectEqual(norm.QuickCheckResult.no, norm.isNormalizedQuick("caf\u{E9}", .nfd));
    try testing.expectEqual(norm.QuickCheckResult.maybe, norm.isNormalizedQuick("cafe\u{301}", .nfc));
    try testing.expectEqual(norm.QuickCheckResult.no, norm.isNormalizedQuick("\u{FB01}", .nfkc));
    // Out-of-order marks are never normalized.
    try testing.expectEqual(norm.QuickCheckResult.no, norm.isNormalizedQuick("a\u{301}\u{316}", .nfd));
}

test "normalize idempotent" {
    const gpa = testing.allocator;
    const pool = [_][]const u8{ "a", "A", "\u{E9}", "e\u{301}", "\u{1E9B}\u{323}", "\u{D55C}", "\u{1100}\u{1161}", "\u{FB01}", "\u{212B}", "\u{301}", "\u{316}", "\u{345}", " ", "\u{3300}", "\u{FDFA}", "\u{0F73}", "\u{1D15E}" };
    var rng = std.Random.DefaultPrng.init(15);
    const r = rng.random();
    for (0..300) |_| {
        var buf: [128]u8 = undefined;
        var n: usize = 0;
        for (0..r.uintLessThan(usize, 10)) |_| {
            const s = pool[r.uintLessThan(usize, pool.len)];
            @memcpy(buf[n..][0..s.len], s);
            n += s.len;
        }
        const x = buf[0..n];
        for ([_]norm.Form{ .nfc, .nfd, .nfkc, .nfkd }) |form| {
            const once = try norm.normalize(gpa, x, form);
            defer gpa.free(once);
            const twice = try norm.normalize(gpa, once, form);
            defer gpa.free(twice);
            try testing.expectEqualSlices(u8, once, twice);
            try testing.expect(norm.isNormalizedQuick(once, form) != .no);
        }
    }
}

fn canonFold(s: []const u8, out: []u21) []u21 {
    var f = fold.Folder.init(s, true);
    var n: usize = 0;
    while (f.next()) |x| : (n += 1) out[n] = x.cp;
    return out[0..n];
}

test "canonical caseless Å (U+212B) vs å" {
    var a: [16]u21 = undefined;
    var b: [16]u21 = undefined;
    var c: [16]u21 = undefined;
    try testing.expectEqualSlices(u21, canonFold("\u{212B}", &a), canonFold("\u{E5}", &b));
    try testing.expectEqualSlices(u21, canonFold("A\u{30A}", &c), canonFold("\u{E5}", &b));
    try testing.expectEqualSlices(u21, &.{ 'a', 0x30A }, canonFold("\u{C5}", &a));
    // U+0345 (ccc 240) folds to ι (a starter): D145's second NFD keeps it
    // after the reordered marks.
    try testing.expectEqualSlices(u21, canonFold("\u{1FB3}", &a), canonFold("\u{3B1}\u{345}", &b));
}

test "canonical Folder offsets" {
    var f = fold.Folder.init("e\u{301}", true);
    try testing.expectEqual(fold.Folded{ .cp = 'e', .src_start = 0, .src_end = 1 }, f.next().?);
    try testing.expectEqual(fold.Folded{ .cp = 0x301, .src_start = 1, .src_end = 3 }, f.next().?);
    try testing.expectEqual(@as(?fold.Folded, null), f.next());
    var g = fold.Folder.init("\u{C9}x", true);
    try testing.expectEqual(fold.Folded{ .cp = 'e', .src_start = 0, .src_end = 2 }, g.next().?);
    try testing.expectEqual(fold.Folded{ .cp = 0x301, .src_start = 0, .src_end = 2 }, g.next().?);
    try testing.expectEqual(fold.Folded{ .cp = 'x', .src_start = 2, .src_end = 3 }, g.next().?);
    // Reordering keeps each mark's own source range: a + U+0301 (230) +
    // U+0316 (220) puts U+0316 first.
    var h = fold.Folder.init("a\u{301}\u{316}", true);
    _ = h.next();
    try testing.expectEqual(fold.Folded{ .cp = 0x316, .src_start = 3, .src_end = 5 }, h.next().?);
    try testing.expectEqual(fold.Folded{ .cp = 0x301, .src_start = 1, .src_end = 3 }, h.next().?);
}

test "long non-starter run" {
    const gpa = testing.allocator;
    // 'a' then 100 marks alternating ccc 230 and 220.
    var buf: [1 + 100 * 2]u8 = undefined;
    buf[0] = 'a';
    var n: usize = 1;
    for (0..100) |k| {
        const cp: u21 = if (k % 2 == 0) 0x301 else 0x316;
        n += try std.unicode.utf8Encode(cp, buf[n..]);
    }
    const nfd = try norm.normalize(gpa, buf[0..n], .nfd);
    defer gpa.free(nfd);
    // All 50 U+0316 (220) come before all 50 U+0301 (230).
    var expect: [1 + 100 * 2]u8 = undefined;
    expect[0] = 'a';
    var m: usize = 1;
    for (0..100) |k| m += try std.unicode.utf8Encode(if (k < 50) 0x316 else 0x301, expect[m..]);
    try testing.expectEqualSlices(u8, expect[0..m], nfd);
    // The streaming decomposer degrades past its 64-entry buffer: still
    // every code point once, each flushed chunk in ccc order.
    var d = norm.Decomposer.init(buf[0..n], false);
    var count: usize = 0;
    while (d.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 101), count);
}
