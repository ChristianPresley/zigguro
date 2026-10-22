//! Paragraph wrapping: lays the paragraph out once to get grapheme widths,
//! picks breaks greedily among UAX #14 opportunities (trailing spaces do
//! not count against the width; a grapheme break when no opportunity
//! fits), then lays out each line on its own so shaping across a break
//! (`unsafe_to_break`) is redone and bidi reordering is per line (L1–L2)
//! with the paragraph's embedding levels.

const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("../unicode/root.zig");
const line_break = unicode.line_break;
const style_mod = @import("style.zig");
const StyleRun = style_mod.StyleRun;
const WrapOptions = style_mod.WrapOptions;
const Line = style_mod.Line;
const VisGrapheme = style_mod.VisGrapheme;
const itemize_mod = @import("itemize.zig");
const TextLayout = @import("line.zig").TextLayout;

const ellipsis = "\u{2026}";
const eps = 0.01;

/// Logical grapheme widths of a measured paragraph.
const Widths = struct {
    /// Grapheme start offsets, ascending, then `text.len`.
    starts: []u32,
    /// prefix[i]: width of the graphemes before grapheme i.
    prefix: []f32,

    fn index(w: *const Widths, offset: u32) usize {
        return std.sort.lowerBound(u32, w.starts, offset, order);
    }

    fn width(w: *const Widths, s: u32, e: u32) f32 {
        return w.prefix[w.index(e)] - w.prefix[w.index(s)];
    }
};

fn order(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

fn byStart(_: void, a: VisGrapheme, b: VisGrapheme) bool {
    return a.start < b.start;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isNewline(c: u8) bool {
    return c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

/// `e` moved back over trailing spaces and line terminators.
fn trimEnd(text: []const u8, s: u32, e: u32) u32 {
    var b = e;
    while (b > s and (isSpace(text[b - 1]) or isNewline(text[b - 1]))) b -= 1;
    return b;
}

/// `e` moved back over line terminators (U+2028/2029 and NEL included).
fn trimNewline(text: []const u8, s: u32, e: u32) u32 {
    var b = e;
    while (b > s) {
        if (isNewline(text[b - 1])) {
            b -= 1;
        } else if (b - s >= 3 and std.mem.eql(u8, text[b - 3 .. b - 1], "\u{2028}"[0..2]) and (text[b - 1] == 0xA8 or text[b - 1] == 0xA9)) {
            b -= 3;
        } else if (b - s >= 2 and text[b - 2] == 0xC2 and text[b - 1] == 0x85) {
            b -= 2;
        } else break;
    }
    return b;
}

/// The style runs of `[s, e)`, shifted to start at 0.
fn sliceStyles(arena: Allocator, styles: []const StyleRun, s: u32, e: u32) ![]StyleRun {
    var out: std.ArrayList(StyleRun) = .empty;
    for (styles, 0..) |r, i| {
        if (r.end <= s and i + 1 < styles.len) continue;
        const end = if (i + 1 == styles.len) e else @min(@max(r.end, s), e);
        try out.append(arena, .{ .end = end - s, .style = r.style });
        if (end >= e) break;
    }
    if (out.items.len == 0) try out.append(arena, .{ .end = e - s, .style = styles[styles.len - 1].style });
    return out.items;
}

/// Wraps `text` (one paragraph) to lines at most `max_w` px wide.
pub fn wrap(tl: *TextLayout, arena: Allocator, text: []const u8, styles: []const StyleRun, max_w: f32, o: WrapOptions) ![]const Line {
    std.debug.assert(styles.len > 0);
    const lv = try itemize_mod.resolveLevels(arena, text, o.base_dir);
    const para = if (lv.paragraph) |*p| p else null;
    const all_levels = if (para) |p| try itemize_mod.lineByteLevels(arena, p, 0, @intCast(text.len)) else null;
    const measured = try tl.buildLine(arena, text, 0, styles, all_levels, lv.base, o.tab_width_px);

    // Logical grapheme widths.
    var sorted = true;
    for (1..@max(measured.graphemes.len, 1)) |i| if (measured.graphemes[i].start < measured.graphemes[i - 1].start) {
        sorted = false;
        break;
    };
    const gs = if (sorted) measured.graphemes else blk: {
        const copy = try arena.dupe(VisGrapheme, measured.graphemes);
        std.mem.sort(VisGrapheme, copy, {}, byStart);
        break :blk copy;
    };
    var w: Widths = .{ .starts = try arena.alloc(u32, gs.len + 1), .prefix = try arena.alloc(f32, gs.len + 1) };
    var acc: f32 = 0;
    for (gs, 0..) |g, i| {
        w.starts[i] = g.start;
        w.prefix[i] = acc;
        acc += g.x1 - g.x0;
    }
    w.starts[gs.len] = @intCast(text.len);
    w.prefix[gs.len] = acc;

    var breaks: std.ArrayList(line_break.Break) = .empty;
    var it = line_break.Iterator.init(text, .{ .code_tailoring = o.code_wrap });
    while (it.next()) |b| try breaks.append(arena, b);

    var lines: std.ArrayList(Line) = .empty;
    var start: u32 = 0;
    var bi: usize = 0;
    while (true) {
        const first = lines.items.len == 0;
        const limit = if (first) max_w else max_w - o.hanging_indent_px;
        while (bi < breaks.items.len and breaks.items[bi].offset <= start) bi += 1;
        var best: ?u32 = null;
        var k = bi;
        while (k < breaks.items.len) : (k += 1) {
            const b = breaks.items[k];
            const e: u32 = @intCast(b.offset);
            if (w.width(start, trimEnd(text, start, e)) > limit + eps) break;
            best = e;
            if (b.kind == .mandatory) break;
        }
        const end = best orelse emergency(&w, text, start, limit);
        const last = o.max_lines != 0 and lines.items.len + 1 == o.max_lines and end < text.len;
        if (last and o.ellipsis) {
            try lines.append(arena, try ellipsisLine(tl, arena, text, styles, &w, start, end, limit, lv.base, o));
        } else {
            const e = trimNewline(text, start, end);
            const levels = if (para) |p| try itemize_mod.lineByteLevels(arena, p, start, e) else null;
            var line = try tl.buildLine(arena, text[start..e], start, try sliceStyles(arena, styles, start, e), levels, lv.base, o.tab_width_px);
            line.end = end;
            try lines.append(arena, line);
        }
        if (!first) lines.items[lines.items.len - 1].indent = o.hanging_indent_px;
        start = end;
        if (last or start >= text.len) break;
    }
    return lines.items;
}

/// The farthest grapheme boundary after `start` that fits (at least one
/// grapheme).
fn emergency(w: *const Widths, text: []const u8, start: u32, limit: f32) u32 {
    const first_i = w.index(start);
    var i = first_i + 1;
    while (i < w.starts.len and w.prefix[i] - w.prefix[first_i] <= limit + eps) i += 1;
    const end = w.starts[@max(i - 1, first_i + 1)];
    return @max(end, @min(start + 1, @as(u32, @intCast(text.len))));
}

/// The last line when `max_lines` cuts text: as many graphemes of
/// `[start, end)` as fit with "…" after them.
fn ellipsisLine(tl: *TextLayout, arena: Allocator, text: []const u8, styles: []const StyleRun, w: *const Widths, start: u32, end: u32, limit: f32, base: u8, o: WrapOptions) !Line {
    const st = styles[style_mod.styleIndexAt(styles, if (end > start) end - 1 else start)].style;
    const ell_w = tl.measure(ellipsis, st);
    var i = w.index(end);
    const first_i = w.index(start);
    while (i > first_i and w.width(start, trimEnd(text, start, w.starts[i])) + ell_w > limit + eps) i -= 1;
    const cut = trimEnd(text, start, w.starts[i]);
    const joined = try std.mem.concat(arena, u8, &.{ text[start..cut], ellipsis });
    var runs: std.ArrayList(StyleRun) = .empty;
    if (cut > start) try runs.appendSlice(arena, try sliceStyles(arena, styles, start, cut));
    try runs.append(arena, .{ .end = @intCast(joined.len), .style = st });
    const dir: style_mod.Direction = if (base & 1 == 1) .rtl else .ltr;
    var line = try tl.layoutLine(arena, joined, runs.items, .{ .base_dir = dir, .tab_width_px = o.tab_width_px });
    // Offsets of the joined text map back to the caller's; the ellipsis
    // maps to the cut.
    const shift = struct {
        fn f(v: u32, s: u32, c: u32) u32 {
            return @min(v + s, c);
        }
    }.f;
    const abs_cut = cut;
    // Carets stop at the cut: its stop sits before the ellipsis.
    var nc: usize = 0;
    while (nc < line.carets.len and line.carets[nc].offset <= cut - start) nc += 1;
    line.carets = line.carets[0..nc];
    for (@constCast(line.clusters)) |*c| c.* = shift(c.*, start, abs_cut);
    for (@constCast(line.carets)) |*c| c.offset = shift(c.offset, start, abs_cut);
    for (@constCast(line.graphemes)) |*g| {
        g.start = shift(g.start, start, abs_cut);
        g.end = shift(g.end, start, abs_cut);
    }
    line.start = start;
    line.end = abs_cut;
    return line;
}
