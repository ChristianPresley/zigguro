//! Layout tests: itemization, line layout (fast and general paths), tabs,
//! letter spacing, bidi order, wrapping, metrics, the width cache and hit
//! testing.

const std = @import("std");
const testing = std.testing;
const fonts = @import("../fonts/root.zig");
const TestFont = @import("../fonts/fallback_test.zig").TestFont;
const ot = @import("../ot/root.zig");
const Feature = @import("../shape/buffer.zig").Feature;
const style = @import("style.zig");
const TextStyle = style.TextStyle;
const StyleRun = style.StyleRun;
const Line = style.Line;
const itemize = @import("itemize.zig");
const grapheme = @import("../unicode/grapheme.zig");
const TextLayout = @import("line.zig").TextLayout;

/// Fonts, registry, fallback and a layout engine.
const Fixture = struct {
    mono: TestFont,
    inter: TestFont,
    serif: TestFont,
    arabic: TestFont,
    han: TestFont,
    emoji: TestFont,
    reg: fonts.FontRegistry,
    fb: fonts.Fallback,
    tl: TextLayout,
    ids: struct { mono: fonts.InstanceId, inter: fonts.InstanceId, serif: fonts.InstanceId, arabic: fonts.InstanceId, han: fonts.InstanceId, emoji: fonts.InstanceId },
    /// JetBrains Mono, Arabic, Han, emoji.
    code: fonts.ChainId,
    /// Inter, Arabic, Han, emoji.
    ui: fonts.ChainId,
    serif_chain: fonts.ChainId,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fixture) !void {
        const gpa = testing.allocator;
        try f.mono.load(gpa, "JetBrainsMono[wght].ttf");
        errdefer f.mono.deinit(gpa);
        try f.inter.load(gpa, "Inter[opsz,wght].ttf");
        errdefer f.inter.deinit(gpa);
        try f.serif.load(gpa, "SourceSerif4-Regular.otf");
        errdefer f.serif.deinit(gpa);
        try f.arabic.load(gpa, "NotoSansArabic-Subset.ttf");
        errdefer f.arabic.deinit(gpa);
        try f.han.load(gpa, "SourceHanSansJP-Subset.otf");
        errdefer f.han.deinit(gpa);
        try f.emoji.load(gpa, "NotoColorEmoji-CBDT-Subset.ttf");
        errdefer f.emoji.deinit(gpa);
        f.reg = fonts.FontRegistry.init(gpa);
        f.ids = .{
            .mono = try f.reg.register(&f.mono.inst),
            .inter = try f.reg.register(&f.inter.inst),
            .serif = try f.reg.register(&f.serif.inst),
            .arabic = try f.reg.register(&f.arabic.inst),
            .han = try f.reg.register(&f.han.inst),
            .emoji = try f.reg.register(&f.emoji.inst),
        };
        f.fb = fonts.Fallback.init(gpa, &f.reg);
        f.code = try f.fb.chainOf(&.{ f.ids.mono, f.ids.arabic, f.ids.han, f.ids.emoji });
        f.ui = try f.fb.chainOf(&.{ f.ids.inter, f.ids.arabic, f.ids.han, f.ids.emoji });
        f.serif_chain = try f.fb.chainOf(&.{f.ids.serif});
        f.tl = try TextLayout.init(gpa, &f.reg, &f.fb);
        f.arena = .init(gpa);
    }

    fn deinit(f: *Fixture) void {
        const gpa = testing.allocator;
        f.arena.deinit();
        f.tl.deinit();
        f.fb.deinit();
        f.reg.deinit();
        f.emoji.deinit(gpa);
        f.han.deinit(gpa);
        f.arabic.deinit(gpa);
        f.serif.deinit(gpa);
        f.inter.deinit(gpa);
        f.mono.deinit(gpa);
    }

    fn a(f: *Fixture) std.mem.Allocator {
        return f.arena.allocator();
    }

    fn one(f: *Fixture, st: TextStyle) []const StyleRun {
        const runs = f.a().alloc(StyleRun, 1) catch unreachable;
        runs[0] = .{ .end = std.math.maxInt(u32), .style = st };
        return runs;
    }

    fn line(f: *Fixture, text: []const u8, st: TextStyle) !Line {
        return f.tl.layoutLine(f.a(), text, f.one(st), .{});
    }
};

fn setup() !*Fixture {
    const f = try testing.allocator.create(Fixture);
    errdefer testing.allocator.destroy(f);
    try f.init();
    return f;
}

fn teardown(f: *Fixture) void {
    f.deinit();
    testing.allocator.destroy(f);
}

/// Every caret offset is a grapheme boundary, carets are in logical
/// order, and the graphemes tile [0, width] in x.
fn expectWellFormed(text: []const u8, l: Line) !void {
    try testing.expect(l.carets.len >= 1);
    for (l.carets, 0..) |c, i| {
        if (i > 0) try testing.expect(c.offset > l.carets[i - 1].offset);
        const rel = c.offset - l.start;
        if (rel != 0 and rel != text.len) try testing.expectEqual(rel, grapheme.nextBoundary(text, grapheme.prevBoundary(text, rel)));
    }
    try testing.expectEqual(l.end, l.carets[l.carets.len - 1].offset);
    var x: f32 = 0;
    for (l.graphemes) |g| {
        try testing.expectApproxEqAbs(x, g.x0, 0.01);
        try testing.expect(g.x1 >= g.x0);
        x = g.x1;
    }
    try testing.expectApproxEqAbs(l.width, x, 0.01);
}

// ---------------------------------------------------------------- itemize

test "itemize: ltr ascii single item fast path" {
    const f = try setup();
    defer teardown(f);
    var items: std.ArrayList(itemize.Item) = .empty;
    const info = try itemize.itemize(f.a(), "fn main() void {}", f.one(.{ .chain = f.code, .size_px = 14 }), .auto, &f.fb, &items);
    try testing.expect(!info.has_rtl and info.paragraph == null);
    try testing.expectEqual(@as(usize, 1), items.items.len);
    try testing.expectEqual(f.ids.mono, items.items[0].instance);
    try testing.expectEqual(@import("../unicode/root.zig").Script.Latn, items.items[0].script);
}

test "itemize: mixed arabic code items" {
    const f = try setup();
    defer teardown(f);
    var items: std.ArrayList(itemize.Item) = .empty;
    const text = "x = \"\u{645}\u{631}\u{62D}\u{628}\u{627}\";";
    const info = try itemize.itemize(f.a(), text, f.one(.{ .chain = f.code, .size_px = 14 }), .ltr, &f.fb, &items);
    try testing.expect(info.has_rtl);
    try testing.expect(items.items.len >= 3);
    var saw_rtl = false;
    for (items.items) |it| if (it.level & 1 == 1) {
        saw_rtl = true;
        try testing.expectEqual(f.ids.arabic, it.instance);
        try testing.expectEqual(@import("../unicode/root.zig").Script.Arab, it.script);
    };
    try testing.expect(saw_rtl);
    // Items tile the text in logical order.
    var at: u32 = 0;
    for (items.items) |it| {
        try testing.expectEqual(at, it.start);
        at = it.end;
    }
    try testing.expectEqual(@as(u32, text.len), at);
}

test "itemize: fallback split at clusters" {
    const f = try setup();
    defer teardown(f);
    var items: std.ArrayList(itemize.Item) = .empty;
    _ = try itemize.itemize(f.a(), "ab\u{65E5}\u{672C}cd", f.one(.{ .chain = f.ui, .size_px = 14 }), .auto, &f.fb, &items);
    try testing.expectEqual(@as(usize, 3), items.items.len);
    try testing.expectEqual(f.ids.inter, items.items[0].instance);
    try testing.expectEqual(f.ids.han, items.items[1].instance);
    try testing.expectEqual(@as(u32, 2), items.items[1].start);
    try testing.expectEqual(@as(u32, 8), items.items[1].end);
    try testing.expectEqual(f.ids.inter, items.items[2].instance);
}

test "itemize: emoji cluster item flagged" {
    const f = try setup();
    defer teardown(f);
    var items: std.ArrayList(itemize.Item) = .empty;
    _ = try itemize.itemize(f.a(), "hi \u{1F600}!", f.one(.{ .chain = f.ui, .size_px = 14 }), .auto, &f.fb, &items);
    var found = false;
    for (items.items) |it| if (it.emoji) {
        found = true;
        try testing.expectEqual(f.ids.emoji, it.instance);
        try testing.expectEqual(@as(u32, 3), it.start);
        try testing.expectEqual(@as(u32, 7), it.end);
    };
    try testing.expect(found);
}

test "itemize: style boundary clamp" {
    const f = try setup();
    defer teardown(f);
    var items: std.ArrayList(itemize.Item) = .empty;
    // The first style ends inside "e\u{301}": the cluster stays whole.
    const styles = [_]StyleRun{
        .{ .end = 2, .style = .{ .chain = f.ui, .size_px = 14 } },
        .{ .end = 100, .style = .{ .chain = f.ui, .size_px = 20 } },
    };
    _ = try itemize.itemize(f.a(), "ae\u{301}b", &styles, .auto, &f.fb, &items);
    try testing.expectEqual(@as(usize, 2), items.items.len);
    try testing.expectEqual(@as(u32, 4), items.items[0].end);
    try testing.expectEqual(@as(u16, 0), items.items[0].style_index);
    try testing.expectEqual(@as(u16, 1), items.items[1].style_index);
}

// ---------------------------------------------------------------- lines

test "line: fast path equals general path" {
    const f = try setup();
    defer teardown(f);
    // Ligatures off: JetBrains Mono's ASCII shaping is then trivial except
    // for `ccmp` at the backtick (it becomes a combining grave after a
    // letter), which sends such lines through the shaper.
    const fs = try f.tl.featureSet(&.{ .{ .tag = ot.tag("calt"), .value = 0 }, .{ .tag = ot.tag("liga"), .value = 0 } });
    const st: TextStyle = .{ .chain = f.code, .size_px = 13, .features = fs, .letter_spacing = 0.5 };
    const at = try f.tl.asciiTrivial(f.ids.mono, fs);
    try testing.expectEqual(@as(u128, 1) << '`', at.hot);
    var prng = std.Random.DefaultPrng.init(0x1a7);
    const r = prng.random();
    var buf: [48]u8 = undefined;
    for (0..10_000) |_| {
        _ = f.arena.reset(.retain_capacity);
        const n = r.intRangeAtMost(usize, 1, buf.len);
        for (buf[0..n]) |*c| c.* = if (r.intRangeLessThan(u8, 0, 16) == 0) '\t' else r.intRangeLessThan(u8, 0x20, 0x7F);
        const text = buf[0..n];
        f.tl.fast_path = true;
        const fast = try f.line(text, st);
        f.tl.fast_path = false;
        const slow = try f.line(text, st);
        try testing.expectEqualSlices(ot.GlyphId, slow.glyphs, fast.glyphs);
        try testing.expectEqualSlices(f32, slow.x, fast.x);
        try testing.expectEqualSlices(u32, slow.clusters, fast.clusters);
        try testing.expectEqual(slow.width, fast.width);
        try testing.expectEqual(slow.carets.len, fast.carets.len);
        for (slow.carets, fast.carets) |a, b| try testing.expectEqual(a, b);
    }
    f.tl.fast_path = true;
}

test "line: ligature line golden" {
    const f = try setup();
    defer teardown(f);
    const st: TextStyle = .{ .chain = f.code, .size_px = 14 };
    const text = "a -> b != c => d";
    const l = try f.line(text, st);
    try expectWellFormed(text, l);
    // JetBrains Mono keeps one glyph per character (ligatures are
    // contextual alternates), every glyph on the 0.6 em grid.
    try testing.expectEqual(text.len, l.glyphs.len);
    const adv = l.width / @as(f32, @floatFromInt(text.len));
    for (l.x, 0..) |x, i| try testing.expectApproxEqAbs(adv * @as(f32, @floatFromInt(i)), x, 0.01);
    // calt replaced "->", "!=" and "=>".
    const plain = try f.tl.layoutLine(f.a(), text, f.one(.{ .chain = f.code, .size_px = 14, .features = try f.tl.featureSet(&.{.{ .tag = ot.tag("calt"), .value = 0 }}) }), .{});
    var differ: usize = 0;
    for (l.glyphs, plain.glyphs) |x, y| differ += @intFromBool(x != y);
    try testing.expect(differ >= 6);
    try testing.expectEqual(text.len + 1, l.carets.len);
}

test "line: uniform ligature subdivision" {
    const f = try setup();
    defer teardown(f);
    const l = try f.line("office", .{ .chain = f.serif_chain, .size_px = 20 });
    try testing.expect(l.glyphs.len < 6);
    try expectWellFormed("office", l);
    try testing.expectEqual(@as(usize, 7), l.carets.len);
    // Inside the "ffi" ligature the carets split its advance in three.
    var lig: usize = 0;
    while (lig < l.glyphs.len and l.clusters[lig] != 1) lig += 1;
    const x0 = l.x[lig];
    const x1 = if (lig + 1 < l.x.len) l.x[lig + 1] else l.width;
    if (lig + 1 < l.clusters.len and l.clusters[lig + 1] == 4) {
        const third = (x1 - x0) / 3;
        try testing.expectApproxEqAbs(x0 + third, l.carets[2].x, 0.01);
        try testing.expectApproxEqAbs(x0 + 2 * third, l.carets[3].x, 0.01);
    }
}

test "line: tab stops" {
    const f = try setup();
    defer teardown(f);
    const st: TextStyle = .{ .chain = f.ui, .size_px = 16 };
    const l = try f.tl.layoutLine(f.a(), "a\tb\tc", f.one(st), .{ .tab_width_px = 40 });
    try testing.expectEqual(@as(usize, 5), l.glyphs.len);
    try testing.expectApproxEqAbs(@as(f32, 40), l.x[2], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 80), l.x[4], 0.01);
    // The tab draws the space glyph.
    try testing.expectEqual(f.inter.face.glyphIndex(' '), l.glyphs[1]);
    // Default stops: eight spaces.
    const d = try f.line("\tx", .{ .chain = f.code, .size_px = 10 });
    try testing.expectApproxEqAbs(d.x[1], 8 * f.mono.inst.advance(f.mono.face.glyphIndex(' ')) * 10 / 1000, 0.01);
}

test "line: letter spacing not inside ligatures" {
    const f = try setup();
    defer teardown(f);
    const text = "office -> x";
    const base = try f.line(text, .{ .chain = f.serif_chain, .size_px = 20 });
    const spaced = try f.line(text, .{ .chain = f.serif_chain, .size_px = 20, .letter_spacing = 3 });
    var clusters: f32 = 0;
    for (base.clusters, 0..) |c, i| {
        if (i == 0 or c != base.clusters[i - 1]) clusters += 1;
    }
    try testing.expect(clusters < @as(f32, @floatFromInt(text.len)));
    try testing.expectApproxEqAbs(base.width + 3 * clusters, spaced.width, 0.01);
}

test "line: bidi visual order golden" {
    const f = try setup();
    defer teardown(f);
    const text = "ab \u{645}\u{631}\u{62D}\u{628}\u{627} cd";
    const l = try f.tl.layoutLine(f.a(), text, f.one(.{ .chain = f.ui, .size_px = 16 }), .{ .base_dir = .ltr });
    try expectWellFormed(text, l);
    // Levels left to right: Latin, Arabic (one run), Latin; the space
    // after the Arabic is in its script run but at level 0.
    var rtl_run: ?usize = null;
    for (l.runs, 0..) |r, i| if (r.level == 1) {
        try testing.expect(rtl_run == null);
        rtl_run = i;
    };
    const ri = rtl_run.?;
    try testing.expect(ri > 0 and ri + 1 < l.runs.len);
    try testing.expectEqual(@as(u8, 0), l.runs[0].level);
    try testing.expectEqual(@as(u8, 0), l.runs[l.runs.len - 1].level);
    const r = l.runs[ri];
    try testing.expectEqual(f.ids.arabic, r.instance);
    // The Arabic run is reversed: its clusters decrease left to right.
    for (r.glyph_start + 1..r.glyph_end) |i| try testing.expect(l.clusters[i - 1] >= l.clusters[i]);
    try testing.expectEqual(@as(u32, 3), l.clusters[r.glyph_end - 1]);
    try testing.expect(l.runs[0].x < r.x and r.x < l.runs[ri + 1].x);
    // In an RTL paragraph the Latin runs swap sides.
    const rl = try f.tl.layoutLine(f.a(), text, f.one(.{ .chain = f.ui, .size_px = 16 }), .{ .base_dir = .rtl });
    try expectWellFormed(text, rl);
    try testing.expect(rl.paragraph_rtl);
    try testing.expectEqual(@as(u32, 3 + 10 + 1), rl.clusters[rl.runs[0].glyph_start]);
    try testing.expectEqual(@as(u32, 0), rl.clusters[rl.runs[rl.runs.len - 1].glyph_start]);
}

test "line: metrics pixel snapping" {
    const f = try setup();
    defer teardown(f);
    for ([_]f32{ 9, 11.5, 13, 17.25 }) |size| {
        const st: TextStyle = .{ .chain = f.ui, .size_px = size };
        const m = f.tl.fontMetrics(st);
        try testing.expectEqual(@round(m.ascent), m.ascent);
        try testing.expectEqual(@round(m.descent), m.descent);
        try testing.expectEqual(@round(m.line_height), m.line_height);
        try testing.expect(m.ascent > 0 and m.descent > 0 and m.underline_h >= 1);
        const l = try f.line("Ag\u{65E5}", st);
        try testing.expectEqual(@round(l.ascent), l.ascent);
        try testing.expectEqual(@round(l.descent), l.descent);
        try testing.expect(l.ascent >= m.ascent);
    }
    // An empty line still has the style's metrics.
    const e = try f.line("", .{ .chain = f.ui, .size_px = 12 });
    try testing.expect(e.ascent > 0 and e.width == 0 and e.carets.len == 1);
}

test "line: width cache hit" {
    const f = try setup();
    defer teardown(f);
    const st: TextStyle = .{ .chain = f.ui, .size_px = 12 };
    const w = f.tl.measure("Save changes", st);
    const hits = f.tl.widths.hits;
    try testing.expectEqual(w, f.tl.measure("Save changes", st));
    try testing.expectEqual(hits + 1, f.tl.widths.hits);
    try testing.expect(w > 0);
    try testing.expect(f.tl.measure("Save changes", .{ .chain = f.ui, .size_px = 24 }) > w * 1.9);
}

// ---------------------------------------------------------------- wrap

fn expectLinesTile(text: []const u8, lines: []const Line) !void {
    var at: u32 = 0;
    for (lines) |l| {
        try testing.expectEqual(at, l.start);
        at = l.end;
    }
    try testing.expectEqual(@as(u32, @intCast(text.len)), at);
}

test "wrap: at opportunities only" {
    const f = try setup();
    defer teardown(f);
    const text = "The quick brown fox jumps over the lazy dog and keeps running";
    const st: TextStyle = .{ .chain = f.ui, .size_px = 16 };
    const lines = try f.tl.wrap(f.a(), text, f.one(st), 150, .{});
    try testing.expect(lines.len > 2);
    try expectLinesTile(text, lines);
    for (lines, 0..) |l, i| {
        // Every break follows a space, and the visible text fits.
        if (i + 1 < lines.len) try testing.expectEqual(@as(u8, ' '), text[l.end - 1]);
        var vis = l.end;
        while (vis > l.start and text[vis - 1] == ' ') vis -= 1;
        try testing.expect(l.caretX(vis, .upstream) <= 150.01);
    }
    // A mandatory break ends a line even when more would fit.
    const two = try f.tl.wrap(f.a(), "one\ntwo", f.one(st), 1000, .{});
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqual(@as(u32, 4), two[0].end);
    try testing.expectEqual(@as(usize, 4), two[0].carets.len);
}

test "wrap: emergency break" {
    const f = try setup();
    defer teardown(f);
    const text = "Supercalifragilisticexpialidocious";
    const lines = try f.tl.wrap(f.a(), text, f.one(.{ .chain = f.ui, .size_px = 16 }), 60, .{});
    try testing.expect(lines.len > 2);
    try expectLinesTile(text, lines);
    for (lines) |l| {
        try testing.expect(l.width <= 60.01);
        try testing.expect(l.end > l.start);
    }
    // Narrower than one grapheme: one grapheme per line.
    const tiny = try f.tl.wrap(f.a(), "ab", f.one(.{ .chain = f.ui, .size_px = 16 }), 1, .{});
    try testing.expectEqual(@as(usize, 2), tiny.len);
}

test "wrap: hanging indent" {
    const f = try setup();
    defer teardown(f);
    const text = "if (condition_one and condition_two and condition_three) return;";
    const st: TextStyle = .{ .chain = f.code, .size_px = 10 };
    const lines = try f.tl.wrap(f.a(), text, f.one(st), 200, .{ .hanging_indent_px = 24, .code_wrap = true });
    try testing.expect(lines.len >= 2);
    try testing.expectEqual(@as(f32, 0), lines[0].indent);
    for (lines[1..]) |l| {
        try testing.expectEqual(@as(f32, 24), l.indent);
        var vis = l.end;
        while (vis > l.start and text[vis - 1] == ' ') vis -= 1;
        try testing.expect(l.caretX(vis, .upstream) <= 200 - 24 + 0.01);
    }
}

test "wrap: ellipsis" {
    const f = try setup();
    defer teardown(f);
    const text = "A long label that will not fit on two short lines at all";
    const st: TextStyle = .{ .chain = f.ui, .size_px = 14 };
    const lines = try f.tl.wrap(f.a(), text, f.one(st), 100, .{ .max_lines = 2, .ellipsis = true });
    try testing.expectEqual(@as(usize, 2), lines.len);
    const last = lines[1];
    try testing.expect(last.width <= 100.01);
    try testing.expect(last.end < text.len);
    // The last glyph is the ellipsis.
    try testing.expectEqual(f.inter.face.glyphIndex(0x2026), last.glyphs[last.glyphs.len - 1]);
    try testing.expectEqual(last.end, last.carets[last.carets.len - 1].offset);
    // Without the ellipsis the text just stops.
    const cut = try f.tl.wrap(f.a(), text, f.one(st), 100, .{ .max_lines = 2 });
    try testing.expectEqual(@as(usize, 2), cut.len);
}

test "wrap: lines are reshaped on their own" {
    const f = try setup();
    defer teardown(f);
    // "AV" kerns in Inter: at a break between them the kerning must go.
    const text = "WAVE AVATAR VAVAVAVAVAVAVAVAVAVAVA";
    const st: TextStyle = .{ .chain = f.ui, .size_px = 20 };
    const lines = try f.tl.wrap(f.a(), text, f.one(st), 90, .{});
    try expectLinesTile(text, lines);
    for (lines) |l| {
        var e = l.end;
        while (e > l.start and text[e - 1] == ' ') e -= 1;
        const own = try f.tl.layoutLine(f.a(), text[l.start..l.end], f.one(st), .{});
        try testing.expectEqualSlices(ot.GlyphId, own.glyphs, l.glyphs);
        try testing.expectEqualSlices(f32, own.x, l.x);
    }
}

test "wrap: rtl lines reorder independently" {
    const f = try setup();
    defer teardown(f);
    const text = "\u{645}\u{631}\u{62D}\u{628}\u{627} abc \u{645}\u{631}\u{62D}\u{628}\u{627} def";
    const lines = try f.tl.wrap(f.a(), text, f.one(.{ .chain = f.ui, .size_px = 16 }), 60, .{ .base_dir = .auto });
    try testing.expect(lines.len >= 2);
    try expectLinesTile(text, lines);
    for (lines) |l| {
        try testing.expect(l.paragraph_rtl);
        try expectWellFormed(text[l.start..l.end], l);
    }
}

// ---------------------------------------------------------------- hit test

test "hit test: affinity at bidi boundary" {
    const f = try setup();
    defer teardown(f);
    // "abc " then Arabic: offset 4 has two positions.
    const text = "abc \u{645}\u{631}\u{62D}";
    const l = try f.tl.layoutLine(f.a(), text, f.one(.{ .chain = f.ui, .size_px = 16 }), .{ .base_dir = .ltr });
    const up = l.caretX(4, .upstream);
    const down = l.caretX(4, .downstream);
    // Upstream: after the space; downstream: the right edge of the Arabic.
    try testing.expectApproxEqAbs(l.runs[1].x, up, 0.01);
    try testing.expectApproxEqAbs(l.width, down, 0.01);
    const h = l.hitTest(l.width - 0.1);
    try testing.expectEqual(@as(u32, 4), h.offset);
    try testing.expectEqual(style.Affinity.downstream, h.affinity);
    try testing.expect(h.inside);
    try testing.expect(!l.hitTest(l.width + 5).inside);
    try testing.expectEqual(@as(u32, text.len), l.hitTest(up + 0.1).offset);
}

test "hit test: selection rects rtl split" {
    const f = try setup();
    defer teardown(f);
    const text = "ab \u{645}\u{631}\u{62D}\u{628} cd";
    const l = try f.tl.layoutLine(f.a(), text, f.one(.{ .chain = f.ui, .size_px = 16 }), .{ .base_dir = .ltr });
    var rects: std.ArrayList([2]f32) = .empty;
    defer rects.deinit(testing.allocator);
    // "b" plus the first two Arabic letters: two visual pieces.
    try l.selectionRects(1, 7, &rects, testing.allocator);
    try testing.expectEqual(@as(usize, 2), rects.items.len);
    try testing.expect(rects.items[0][1] < rects.items[1][0]);
    try testing.expectApproxEqAbs(l.caretX(1, .downstream), rects.items[0][0], 0.01);
    // The Arabic piece ends at the run's right edge.
    try testing.expectApproxEqAbs(l.caretX(3, .downstream), rects.items[1][1], 0.01);
    // A whole-line selection is one rect.
    rects.clearRetainingCapacity();
    try l.selectionRects(0, @intCast(text.len), &rects, testing.allocator);
    try testing.expectEqual(@as(usize, 1), rects.items.len);
    try testing.expectApproxEqAbs(l.width, rects.items[0][1], 0.01);
}

test "hit test: moveVisual across runs" {
    const f = try setup();
    defer teardown(f);
    const text = "ab \u{645}\u{631} cd";
    const l = try f.tl.layoutLine(f.a(), text, f.one(.{ .chain = f.ui, .size_px = 16 }), .{ .base_dir = .ltr });
    // Walking right from the start visits every visual stop once, x
    // strictly increasing, including both stops of offset 3.
    var pos: style.CaretPos = .{ .offset = 0 };
    var xs: std.ArrayList(f32) = .empty;
    defer xs.deinit(testing.allocator);
    var offsets: std.ArrayList(u32) = .empty;
    defer offsets.deinit(testing.allocator);
    while (l.moveVisual(pos, .right)) |n| {
        const x = l.caretX(n.offset, n.affinity);
        if (xs.items.len > 0) try testing.expect(x > xs.items[xs.items.len - 1]);
        try xs.append(testing.allocator, x);
        try offsets.append(testing.allocator, n.offset);
        pos = n;
        if (xs.items.len > 32) return error.TestUnexpectedResult;
    }
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 5, 3, 8, 9, 10 }, offsets.items);
    try testing.expectApproxEqAbs(l.width, xs.items[xs.items.len - 1], 0.01);
    // Left from the end comes back to the start the same way.
    pos = .{ .offset = @intCast(text.len) };
    var steps: usize = 0;
    while (l.moveVisual(pos, .left)) |n| : (steps += 1) {
        pos = n;
        if (steps > 32) return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(u32, 0), pos.offset);
    try testing.expectEqual(@as(usize, 8), steps);
}

test "hit test: roundtrip all carets" {
    const f = try setup();
    defer teardown(f);
    const pieces = [_][]const u8{ "a", "b", " ", "e\u{301}", "\u{645}", "\u{631}", "\u{62D}\u{64E}", "1", "2", "\u{1F600}", "(", ")", "\u{65E5}", "-", ">" };
    var prng = std.Random.DefaultPrng.init(0xc4a7);
    const r = prng.random();
    var buf: [128]u8 = undefined;
    for (0..10_000) |iter| {
        _ = f.arena.reset(.retain_capacity);
        var n: usize = 0;
        for (0..r.intRangeAtMost(usize, 0, 12)) |_| {
            const p = pieces[r.uintLessThan(usize, pieces.len)];
            @memcpy(buf[n..][0..p.len], p);
            n += p.len;
        }
        const text = buf[0..n];
        const dir: style.Direction = switch (iter % 3) {
            0 => .ltr,
            1 => .rtl,
            else => .auto,
        };
        const l = try f.tl.layoutLine(f.a(), text, f.one(.{ .chain = f.code, .size_px = 13 }), .{ .base_dir = dir });
        try expectWellFormed(text, l);
        for (l.carets) |c| {
            for ([_]style.Affinity{ .downstream, .upstream }) |aff| {
                const x = l.caretX(c.offset, aff);
                const h = l.hitTest(x);
                // The hit lands on a stop drawn at the same x; away from
                // direction boundaries that is the same offset.
                try testing.expectApproxEqAbs(x, l.caretX(h.offset, h.affinity), 0.01);
                if (c.x == c.x_up and sameXOnly(l, c.offset)) try testing.expectEqual(c.offset, h.offset);
            }
        }
    }
}

/// True when no other caret stop is drawn at the x of `offset`'s.
fn sameXOnly(l: Line, offset: u32) bool {
    const x = l.caretX(offset, .downstream);
    for (l.carets) |c| {
        if (c.offset == offset) continue;
        if (@abs(c.x - x) < 0.02 or @abs(c.x_up - x) < 0.02) return false;
    }
    return true;
}

test "line: no allocation outside the arena once warm" {
    const f = try setup();
    defer teardown(f);
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var tl = try TextLayout.init(fa.allocator(), &f.reg, &f.fb);
    defer tl.deinit();
    const code: TextStyle = .{ .chain = f.code, .size_px = 14 };
    const ui: TextStyle = .{ .chain = f.ui, .size_px = 14 };
    const texts = [_][]const u8{ "fn main() !void { return a -> b; }", "x = \"\u{645}\u{631}\u{62D}\u{628}\u{627}\"; // \u{65E5}\u{672C} \u{1F600}", "plain ascii text" };
    for (0..2) |round| {
        if (round == 1) {
            fa.fail_index = fa.alloc_index;
            fa.resize_fail_index = fa.resize_index;
        }
        for (texts) |t| {
            _ = try tl.layoutLine(f.a(), t, f.one(code), .{});
            _ = try tl.wrap(f.a(), t, f.one(ui), 80, .{});
            _ = tl.measure(t, ui);
        }
    }
}
