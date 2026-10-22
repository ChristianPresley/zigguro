//! UAX #9 conformance (BidiTest.txt, BidiCharacterTest.txt) and behaviour
//! tests for the bidi algorithm.

const std = @import("std");
const testing = std.testing;
const bidi = @import("bidi.zig");
const p = @import("props.zig");
const seg = @import("segment_test.zig");
const BC = p.BidiClass;

/// Levels after L1 for the whole input as one line, and the visual order
/// of retained elements.
fn lineResult(gpa: std.mem.Allocator, classes: []const BC, levels: []const bidi.Level, base: bidi.Level, out_levels: []bidi.Level, order: *std.ArrayList(u32)) !void {
    bidi.lineLevels(classes, levels, base, out_levels);
    var runs: std.ArrayList(bidi.VisualRun) = .empty;
    defer runs.deinit(gpa);
    // Same run construction as Paragraph.reorderLine.
    const para: bidi.Paragraph = .{ .levels = @constCast(levels), .cp_offsets = &.{}, .classes = @constCast(classes), .base = base };
    if (classes.len > 0) try para.reorderLine(gpa, 0, @intCast(classes.len), &runs);
    for (runs.items) |r| {
        var k: u32 = 0;
        while (k < r.end_cp - r.start_cp) : (k += 1) {
            const i = if (r.level & 1 == 1) r.end_cp - 1 - k else r.start_cp + k;
            if (!para.isRemoved(i)) try order.append(gpa, i);
        }
    }
}

const x_level: u8 = 0xFF;

/// Per-case scratch memory for the conformance runs (an allocator per
/// case is much slower in Debug).
var scratch: [64 * 1024]u8 = undefined;

fn parseLevels(s: []const u8, out: []u8) !usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |t| : (n += 1) out[n] = if (std.mem.eql(u8, t, "x")) x_level else try std.fmt.parseInt(u8, t, 10);
    return n;
}

fn parseOrder(s: []const u8, out: []u32) !usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |t| : (n += 1) out[n] = try std.fmt.parseInt(u32, t, 10);
    return n;
}

fn check(gpa: std.mem.Allocator, classes: []const BC, cps: ?[]const u21, dir: bidi.Direction, want_base: ?u8, want_levels: []const u8, want_order: []const u32) !bool {
    var levels: [256]bidi.Level = undefined;
    const base = try bidi.resolveClasses(gpa, classes, cps, dir, levels[0..classes.len]);
    if (want_base) |b| if (b != base) return false;
    var line: [256]bidi.Level = undefined;
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    try lineResult(gpa, classes, levels[0..classes.len], base, line[0..classes.len], &order);
    for (classes, 0..) |c, i| {
        const removed = switch (c) {
            .RLE, .LRE, .RLO, .LRO, .PDF, .BN => true,
            else => false,
        };
        if (removed != (want_levels[i] == x_level)) return false;
        if (!removed and line[i] != want_levels[i]) return false;
    }
    return std.mem.eql(u32, order.items, want_order);
}

test "BidiTest.txt conformance" {
    const gpa = testing.allocator;
    const data = try seg.readUcd(gpa, "BidiTest.txt");
    defer gpa.free(data);
    var want_levels: [256]u8 = undefined;
    var nlevels: usize = 0;
    var want_order: [256]u32 = undefined;
    var norder: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var ln: usize = 0;
    var cases: usize = 0;
    var failed: usize = 0;
    while (lines.next()) |raw| {
        ln += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "@Levels:")) {
            nlevels = try parseLevels(line[8..], &want_levels);
            continue;
        }
        if (std.mem.startsWith(u8, line, "@Reorder:")) {
            norder = try parseOrder(line[9..], &want_order);
            continue;
        }
        if (line[0] == '@') continue;
        const semi = std.mem.indexOfScalar(u8, line, ';').?;
        var classes: [256]BC = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, line[0..semi], " \t");
        while (it.next()) |t| : (n += 1) classes[n] = std.meta.stringToEnum(BC, t).?;
        try testing.expectEqual(nlevels, n);
        const bits = try std.fmt.parseInt(u8, std.mem.trim(u8, line[semi + 1 ..], " \t"), 16);
        for ([_]struct { u8, bidi.Direction }{ .{ 1, .auto }, .{ 2, .ltr }, .{ 4, .rtl } }) |bd| {
            if (bits & bd[0] == 0) continue;
            cases += 1;
            var fba: std.heap.FixedBufferAllocator = .init(&scratch);
            if (!try check(fba.allocator(), classes[0..n], null, bd[1], null, want_levels[0..n], want_order[0..norder])) {
                failed += 1;
                if (failed <= 10) std.debug.print("BidiTest line {d} dir {t}: {s}\n", .{ ln, bd[1], line });
            }
        }
    }
    try testing.expect(cases > 400000);
    try testing.expectEqual(@as(usize, 0), failed);
}

test "BidiCharacterTest.txt conformance" {
    const gpa = testing.allocator;
    const data = try seg.readUcd(gpa, "BidiCharacterTest.txt");
    defer gpa.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    var ln: usize = 0;
    var cases: usize = 0;
    var failed: usize = 0;
    while (lines.next()) |raw| {
        ln += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, ';');
        const f0 = f.next().?;
        const f1 = f.next().?;
        const f2 = f.next().?;
        const f3 = f.next().?;
        const f4 = f.next().?;
        var cps: [256]u21 = undefined;
        var classes: [256]BC = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, f0, " ");
        while (it.next()) |t| : (n += 1) {
            cps[n] = try std.fmt.parseInt(u21, t, 16);
            classes[n] = p.props(cps[n]).bidi;
        }
        const dir: bidi.Direction = switch (f1[0]) {
            '0' => .ltr,
            '1' => .rtl,
            else => .auto,
        };
        var want_levels: [256]u8 = undefined;
        _ = try parseLevels(f3, &want_levels);
        var want_order: [256]u32 = undefined;
        const norder = try parseOrder(f4, &want_order);
        cases += 1;
        var fba: std.heap.FixedBufferAllocator = .init(&scratch);
        if (!try check(fba.allocator(), classes[0..n], cps[0..n], dir, try std.fmt.parseInt(u8, f2, 10), want_levels[0..n], want_order[0..norder])) {
            failed += 1;
            if (failed <= 10) std.debug.print("BidiCharacterTest line {d}: {s}\n", .{ ln, line });
        }
    }
    try testing.expect(cases > 90000);
    try testing.expectEqual(@as(usize, 0), failed);
}

/// Visual order of code point indices for the whole paragraph as one line.
fn visual(gpa: std.mem.Allocator, para: *const bidi.Paragraph, out: *std.ArrayList(u32)) !void {
    var runs: std.ArrayList(bidi.VisualRun) = .empty;
    defer runs.deinit(gpa);
    try para.reorderLine(gpa, 0, @intCast(para.levels.len), &runs);
    for (runs.items) |r| {
        var k: u32 = 0;
        while (k < r.end_cp - r.start_cp) : (k += 1) {
            try out.append(gpa, if (r.level & 1 == 1) r.end_cp - 1 - k else r.start_cp + k);
        }
    }
}

test "hasRtl fast path" {
    try testing.expect(!bidi.hasRtl("plain ASCII text, long enough to use the vector skip path"));
    try testing.expect(!bidi.hasRtl("naïve café — 日本語 ✓"));
    try testing.expect(bidi.hasRtl("abc \u{05D0}"));
    try testing.expect(bidi.hasRtl("x = \u{0661}\u{0662}")); // Arabic-Indic digits (AN)
    try testing.expect(bidi.hasRtl("a\u{2067}b\u{2069}")); // RLI ... PDI
    try testing.expect(bidi.hasRtl("0123456789abcdef\u{202A}")); // LRE after a vector block
    const gpa = testing.allocator;
    var para = try bidi.resolve(gpa, "let x = 42; // done", .auto);
    defer para.deinit(gpa);
    try testing.expectEqual(@as(bidi.Level, 0), para.base);
    for (para.levels) |l| try testing.expectEqual(@as(bidi.Level, 0), l);
}

test "mixed code/hebrew sample" {
    const gpa = testing.allocator;
    // A comment in Hebrew inside LTR code: the code stays in order, the
    // Hebrew words reverse, and the trailing number joins the RTL run
    // (W7 keeps EN after R; N1 makes the space between them R).
    const text = "x = 1; // \u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{05E2}\u{05D5}\u{05DC}\u{05DD} 2";
    var para = try bidi.resolve(gpa, text, .ltr);
    defer para.deinit(gpa);
    try testing.expectEqual(@as(usize, 21), para.levels.len);
    try testing.expectEqual(@as(u32, 10), para.cp_offsets[10]);
    try testing.expectEqual(@as(u32, 12), para.cp_offsets[11]);
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    try visual(gpa, &para, &order);
    const want = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10 };
    try testing.expectEqualSlices(u32, &want, order.items);
    try testing.expectEqual(@as(bidi.Level, 1), para.levels[10]);
    try testing.expectEqual(@as(bidi.Level, 2), para.levels[20]);
    try testing.expectEqual(@as(bidi.Level, 0), para.levels[9]);
}

test "deep nesting overflow (130 embeddings)" {
    const gpa = testing.allocator;
    var buf: [130 * 3 + 1]u8 = undefined;
    var n: usize = 0;
    for (0..130) |_| {
        @memcpy(buf[n..][0..3], "\u{202B}"); // RLE
        n += 3;
    }
    buf[n] = 'a';
    n += 1;
    var para = try bidi.resolve(gpa, buf[0..n], .ltr);
    defer para.deinit(gpa);
    // RLE raises odd levels by 2 from 1: 1, 3, ..., 125; further ones
    // overflow. 'a' (L) at odd level 125 resolves to 126.
    try testing.expectEqual(@as(bidi.Level, 126), para.levels[130]);
    for (para.levels) |l| try testing.expect(l <= 126);
    // Isolates past the limit overflow too and stay balanced.
    var b2: std.ArrayList(u8) = .empty;
    defer b2.deinit(gpa);
    for (0..130) |_| try b2.appendSlice(gpa, "\u{2067}"); // RLI
    try b2.append(gpa, 'x');
    for (0..130) |_| try b2.appendSlice(gpa, "\u{2069}"); // PDI
    try b2.append(gpa, 'y');
    var p2 = try bidi.resolve(gpa, b2.items, .ltr);
    defer p2.deinit(gpa);
    try testing.expectEqual(@as(bidi.Level, 0), p2.levels[p2.levels.len - 1]);
    for (p2.levels) |l| try testing.expect(l <= 126);
}

test "brackets N0 sample from UAX" {
    const gpa = testing.allocator;
    // UAX #9 N0 example: AB(CD[&ef]!)gh in an RTL paragraph; the brackets
    // take the embedding direction because they enclose R.
    const text = "\u{05D0}\u{05D1}(\u{05D2}\u{05D3}[&ef]!)gh";
    var para = try bidi.resolve(gpa, text, .rtl);
    defer para.deinit(gpa);
    const want = [_]bidi.Level{ 1, 1, 1, 1, 1, 1, 1, 2, 2, 1, 1, 1, 2, 2 };
    try testing.expectEqualSlices(bidi.Level, &want, para.levels);
    // Same text LTR: the parentheses enclose R and L with R context
    // before, so they become R (N0 c1).
    var p2 = try bidi.resolve(gpa, text, .ltr);
    defer p2.deinit(gpa);
    try testing.expectEqualSlices(bidi.Level, &.{ 1, 1, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, p2.levels);
}

test "mirror L4" {
    try testing.expectEqual(@as(?u21, ')'), bidi.mirrorGlyphNeeded('(', 1));
    try testing.expectEqual(@as(?u21, null), bidi.mirrorGlyphNeeded('(', 2));
    try testing.expectEqual(@as(?u21, '\u{00BB}'), bidi.mirrorGlyphNeeded('\u{00AB}', 3));
    try testing.expectEqual(@as(?u21, null), bidi.mirrorGlyphNeeded('a', 1));
}

test "reorderLine on part of a paragraph" {
    const gpa = testing.allocator;
    var para = try bidi.resolve(gpa, "ab \u{05D0}\u{05D1} cd", .ltr);
    defer para.deinit(gpa);
    var runs: std.ArrayList(bidi.VisualRun) = .empty;
    defer runs.deinit(gpa);
    // Line "ab אב " : trailing space resets to level 0 (L1).
    try para.reorderLine(gpa, 0, 6, &runs);
    try testing.expectEqualSlices(bidi.VisualRun, &.{
        .{ .start_cp = 0, .end_cp = 3, .level = 0 },
        .{ .start_cp = 3, .end_cp = 5, .level = 1 },
        .{ .start_cp = 5, .end_cp = 6, .level = 0 },
    }, runs.items);
}

fn checkInvariants(gpa: std.mem.Allocator, input: []const u8) !void {
    for ([_]bidi.Direction{ .ltr, .rtl, .auto }) |d| {
        var para = try bidi.resolve(gpa, input, d);
        defer para.deinit(gpa);
        for (para.levels) |l| try testing.expect(l <= 126);
        var order: std.ArrayList(u32) = .empty;
        defer order.deinit(gpa);
        try visual(gpa, &para, &order);
        try testing.expectEqual(para.levels.len, order.items.len);
        var seen = try gpa.alloc(bool, order.items.len);
        defer gpa.free(seen);
        @memset(seen, false);
        for (order.items) |i| {
            try testing.expect(!seen[i]);
            seen[i] = true;
        }
    }
}

test "fuzz: unicode-bidi" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            try checkInvariants(testing.allocator, buf[0..s.slice(&buf)]);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "unicode-bidi") });
}
