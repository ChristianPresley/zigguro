//! Text measurement and glyph placement for widgets.
//!
//! `TextSystem` is the seam to E03. A system may shape: then `width` and
//! the glyphs `PaintCx.textLine` draws come from E03's `TextLayout`
//! (kerning, ligatures, font fallback, bidi), as in `FontText`. Otherwise,
//! or for a style with `shape = false` (cell grids), text is laid out from
//! per-codepoint advances. Line breaking stays greedy at spaces and
//! measures lines by their advances, so wrapping matches between measure
//! and paint. `MonoText` is the deterministic implementation used by tests
//! and the headless driver (it does not shape).

const std = @import("std");
const geom = @import("../core/geom.zig");
const canvas = @import("canvas.zig");

const Size = geom.Size;
const Vec2 = geom.Vec2;
const GlyphQuad = canvas.GlyphQuad;

/// A font family slot; the app maps slots to faces.
pub const FontId = enum(u16) { ui = 0, mono = 1, _ };

/// How a run of text is drawn.
pub const TextStyle = struct {
    font: FontId = .ui,
    size: f32 = 13,
    weight: u16 = 400,
    italic: bool = false,
    /// Shape when the system can; false keeps one glyph per codepoint at
    /// its advance (cell grids).
    shape: bool = true,
};

/// A shaped glyph: an id for `TextSystem.shapedGlyph`, placed relative to
/// the line's pen (y down).
pub const ShapedGlyph = struct { id: u32, x: f32, y: f32 = 0 };

/// A shaped line.
pub const Shaped = struct { glyphs: []const ShapedGlyph, width: f32 };

/// Vertical metrics of a font at a size.
pub const LineMetrics = struct {
    ascent: f32,
    descent: f32,
    line_h: f32,
};

/// The text backend used by layout and paint.
pub const TextSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// The operations.
    pub const VTable = struct {
        metrics: *const fn (*anyopaque, TextStyle) LineMetrics,
        advance: *const fn (*anyopaque, TextStyle, cp: u21) f32,
        /// The quad for `cp` with its pen at `pen` (on the baseline), or
        /// null for blank glyphs such as spaces.
        glyph: *const fn (*anyopaque, TextStyle, cp: u21, pen: Vec2) ?GlyphQuad,
        /// Optional shaping of one line (no newlines); the result is valid
        /// until the next call. Null when shaping fails.
        shape: ?*const fn (*anyopaque, TextStyle, s: []const u8) ?Shaped = null,
        /// The quad for a shaped glyph with its origin at `pen`.
        shaped_glyph: ?*const fn (*anyopaque, TextStyle, id: u32, pen: Vec2) ?GlyphQuad = null,
        /// The shaped width of one line (cached by the system).
        shaped_width: ?*const fn (*anyopaque, TextStyle, s: []const u8) f32 = null,
    };

    /// Whether `st` is shaped by this system.
    pub fn shapes(t: TextSystem, st: TextStyle) bool {
        return st.shape and t.vtable.shape != null;
    }

    /// `s` (one line) shaped, or null when `st` is not shaped.
    pub fn shape(t: TextSystem, st: TextStyle, s: []const u8) ?Shaped {
        if (!t.shapes(st)) return null;
        return t.vtable.shape.?(t.ptr, st, s);
    }

    /// See `VTable.shaped_glyph`.
    pub fn shapedGlyph(t: TextSystem, st: TextStyle, id: u32, pen: Vec2) ?GlyphQuad {
        const f = t.vtable.shaped_glyph orelse return null;
        return f(t.ptr, st, id, pen);
    }

    /// See `VTable.metrics`.
    pub fn metrics(t: TextSystem, st: TextStyle) LineMetrics {
        return t.vtable.metrics(t.ptr, st);
    }
    /// See `VTable.advance`.
    pub fn advance(t: TextSystem, st: TextStyle, cp: u21) f32 {
        return t.vtable.advance(t.ptr, st, cp);
    }
    /// See `VTable.glyph`.
    pub fn glyph(t: TextSystem, st: TextStyle, cp: u21, pen: Vec2) ?GlyphQuad {
        return t.vtable.glyph(t.ptr, st, cp, pen);
    }

    /// The width of `s` on one line.
    pub fn width(t: TextSystem, st: TextStyle, s: []const u8) f32 {
        if (st.shape) if (t.vtable.shaped_width) |f| return f(t.ptr, st, s);
        var w: f32 = 0;
        var it = Codepoints{ .s = s };
        while (it.next()) |cp| w += t.advance(st, cp);
        return w;
    }

    /// The size of `s` wrapped at `max_w` (unwrapped when null).
    pub fn measure(t: TextSystem, st: TextStyle, s: []const u8, max_w: ?f32) Size {
        const m = t.metrics(st);
        var lines: u32 = 0;
        var widest: f32 = 0;
        var it = LineIter{ .ts = t, .st = st, .s = s, .max_w = max_w };
        while (it.next()) |ln| {
            lines += 1;
            widest = @max(widest, ln.w);
        }
        if (lines == 0) lines = 1;
        return .{ .w = widest, .h = m.line_h * @as(f32, @floatFromInt(lines)) };
    }
};

/// One laid-out line: a byte range of the source and its width.
pub const Line = struct { start: usize, end: usize, w: f32 };

/// Greedy line breaking at spaces and newlines; a word wider than the
/// line is broken between codepoints. Lines are measured by their
/// advances, also when drawn shaped (kerning only narrows the drawn run),
/// so measuring and painting break at the same places.
pub const LineIter = struct {
    ts: TextSystem,
    st: TextStyle,
    s: []const u8,
    max_w: ?f32,
    pos: usize = 0,
    done: bool = false,

    /// The next line, or null after the last.
    pub fn next(it: *LineIter) ?Line {
        if (it.done) return null;
        const s = it.s;
        const start = it.pos;
        var w: f32 = 0;
        var i = start;
        var last_break: ?usize = null; // index of a space we may break at
        var w_at_break: f32 = 0;
        while (i < s.len) {
            if (s[i] == '\n') {
                it.pos = i + 1;
                return .{ .start = start, .end = i, .w = w };
            }
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const cp = if (i + n <= s.len) (std.unicode.utf8Decode(s[i .. i + n]) catch 0xfffd) else 0xfffd;
            const adv = it.ts.advance(it.st, cp);
            if (it.max_w) |mw| {
                if (w + adv > mw + 0.001 and i > start and cp != ' ') {
                    if (last_break) |b| {
                        it.pos = b + 1;
                        return .{ .start = start, .end = b, .w = w_at_break };
                    }
                    it.pos = i;
                    return .{ .start = start, .end = i, .w = w };
                }
            }
            if (cp == ' ') {
                last_break = i;
                w_at_break = w;
            }
            w += adv;
            i += n;
        }
        it.done = true;
        return .{ .start = start, .end = s.len, .w = w };
    }
};

/// UTF-8 decoding that maps malformed bytes to U+FFFD.
pub const Codepoints = struct {
    s: []const u8,
    i: usize = 0,

    /// The next codepoint, or null at the end.
    pub fn next(it: *Codepoints) ?u21 {
        if (it.i >= it.s.len) return null;
        const n = std.unicode.utf8ByteSequenceLength(it.s[it.i]) catch {
            it.i += 1;
            return 0xfffd;
        };
        if (it.i + n > it.s.len) {
            it.i = it.s.len;
            return 0xfffd;
        }
        const cp = std.unicode.utf8Decode(it.s[it.i .. it.i + n]) catch 0xfffd;
        it.i += n;
        return cp;
    }
};

/// A deterministic text system: every codepoint advances `0.6 × size`
/// (East Asian wide ranges `1.2 × size`), ascent `0.8 × size`, descent
/// `0.2 × size`, line height `round(1.3 × size)`. Glyph quads are boxes
/// on page 0. Used by tests and the headless driver.
pub const MonoText = struct {
    /// The interface.
    pub fn system(m: *MonoText) TextSystem {
        return .{ .ptr = m, .vtable = &vtable };
    }

    const vtable: TextSystem.VTable = .{ .metrics = metrics, .advance = advance, .glyph = glyph };

    fn metrics(_: *anyopaque, st: TextStyle) LineMetrics {
        return .{ .ascent = 0.8 * st.size, .descent = 0.2 * st.size, .line_h = @round(1.3 * st.size) };
    }

    fn advance(_: *anyopaque, st: TextStyle, cp: u21) f32 {
        if (cp == '\n') return 0;
        return if (isWide(cp)) 1.2 * st.size else 0.6 * st.size;
    }

    fn glyph(p: *anyopaque, st: TextStyle, cp: u21, pen: Vec2) ?GlyphQuad {
        if (cp == ' ' or cp == '\n' or cp == '\t') return null;
        const adv = advance(p, st, cp);
        const asc = 0.7 * st.size;
        return .{
            .dst = .{ pen.x + 0.05 * st.size, pen.y - asc, adv - 0.1 * st.size, asc },
            .uv = .{ 0, 0, 0, 0 },
            .page = 0,
            .format = .r8,
        };
    }

    fn isWide(cp: u21) bool {
        return (cp >= 0x1100 and cp <= 0x115f) or (cp >= 0x2e80 and cp <= 0xa4cf) or
            (cp >= 0xac00 and cp <= 0xd7a3) or (cp >= 0xf900 and cp <= 0xfaff) or
            (cp >= 0xff00 and cp <= 0xff60) or (cp >= 0x1f300 and cp <= 0x1faff) or (cp >= 0x20000 and cp <= 0x3fffd);
    }
};

test "mono measure and wrap" {
    var m: MonoText = .{};
    const ts = m.system();
    const st: TextStyle = .{ .size = 10 };
    try std.testing.expectEqual(@as(f32, 18), ts.width(st, "abc"));
    const one = ts.measure(st, "hello world", null);
    try std.testing.expectEqual(@as(f32, 66), one.w);
    try std.testing.expectEqual(@as(f32, 13), one.h);
    const two = ts.measure(st, "hello world", 40);
    try std.testing.expectEqual(@as(f32, 30), two.w);
    try std.testing.expectEqual(@as(f32, 26), two.h);
    // A long word breaks between codepoints.
    const brk = ts.measure(st, "abcdefghij", 20);
    try std.testing.expectEqual(@as(f32, 4 * 13), brk.h);
    // Explicit newlines.
    try std.testing.expectEqual(@as(f32, 26), ts.measure(st, "a\nb", null).h);
}

test "malformed utf8 is replaced" {
    var it = Codepoints{ .s = "a\xffb" };
    try std.testing.expectEqual(@as(?u21, 'a'), it.next());
    try std.testing.expectEqual(@as(?u21, 0xfffd), it.next());
    try std.testing.expectEqual(@as(?u21, 'b'), it.next());
    try std.testing.expectEqual(@as(?u21, null), it.next());
}
