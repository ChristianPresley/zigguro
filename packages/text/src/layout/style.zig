//! Layout inputs and outputs: text styles, style runs, options, metrics
//! and the `Line` produced by `TextLayout` (see the E03.F08 design).

const std = @import("std");
const fonts = @import("../fonts/root.zig");
const ot = @import("../ot/root.zig");
const GlyphId = ot.GlyphId;
const bidi = @import("../unicode/bidi.zig");
const RenderMode = @import("../cache/glyph_key.zig").RenderMode;

/// The direction of a paragraph.
pub const Direction = bidi.Direction;

/// Interned OpenType feature list (`TextLayout.featureSet`); 0 is the
/// default set (no user features).
pub const FeatureSetId = u16;

/// Requested slant; matching and synthesis come with E03.F07.
pub const Slant = enum { normal, italic, oblique };

/// How a span of text is drawn.
pub const TextStyle = struct {
    chain: fonts.ChainId,
    size_px: f32,
    weight: u16 = 400,
    slant: Slant = .normal,
    features: FeatureSetId = 0,
    /// Extra advance after every cluster, in px.
    letter_spacing: f32 = 0,
    /// Only used for COLR glyphs that paint with the text colour.
    color_rgba: u32 = 0,

    /// True when both styles lay text out identically (colour aside).
    pub fn sameShape(a: TextStyle, b: TextStyle) bool {
        return a.chain == b.chain and a.size_px == b.size_px and a.weight == b.weight and
            a.slant == b.slant and a.features == b.features and a.letter_spacing == b.letter_spacing;
    }

    /// A hash of the fields that change layout.
    pub fn hash(s: TextStyle) u64 {
        var h = std.hash.Wyhash.init(0x7e57);
        h.update(std.mem.asBytes(&@intFromEnum(s.chain)));
        h.update(std.mem.asBytes(&s.size_px));
        h.update(std.mem.asBytes(&s.weight));
        h.update(std.mem.asBytes(&@intFromEnum(s.slant)));
        h.update(std.mem.asBytes(&s.features));
        h.update(std.mem.asBytes(&s.letter_spacing));
        return h.final();
    }
};

/// A style over bytes `[previous end, end)`. The last run extends to the
/// end of the text; offsets inside a grapheme move to its end.
pub const StyleRun = struct { end: u32, style: TextStyle };

/// Index of the style run covering byte `offset`.
pub fn styleIndexAt(styles: []const StyleRun, offset: u32) u16 {
    var i: usize = 0;
    while (i + 1 < styles.len and styles[i].end <= offset) i += 1;
    return @intCast(i);
}

/// Options for one line.
pub const LineOptions = struct {
    base_dir: Direction = .auto,
    /// Tab stop interval in px; 0 means eight spaces of the tab's style.
    tab_width_px: f32 = 0,
    code_wrap: bool = false,
};

/// Options for `TextLayout.wrap`.
pub const WrapOptions = struct {
    /// UAX #14 code tailoring (breaks in URLs, not inside operators).
    code_wrap: bool = false,
    /// Indent of continuation lines, in px (the lines are narrower by it).
    hanging_indent_px: f32 = 0,
    /// 0 means no limit.
    max_lines: u32 = 0,
    /// When `max_lines` cuts text off, end the last line with "…".
    ellipsis: bool = false,
    base_dir: Direction = .auto,
    tab_width_px: f32 = 0,
};

/// Font-wide metrics in px; `ascent`, `descent` and `line_height` are
/// whole pixels so baselines land on the pixel grid. `underline_y` and
/// `strike_y` are offsets below the baseline (negative is above).
pub const PxMetrics = struct {
    ascent: f32,
    descent: f32,
    line_height: f32,
    x_height: f32,
    cap_height: f32,
    underline_y: f32,
    underline_h: f32,
    strike_y: f32,
    strike_h: f32,
};

/// Which side of an offset a caret belongs to at a direction boundary:
/// the character before it (upstream) or after it (downstream).
pub const Affinity = enum { upstream, downstream };

/// A caret: an offset and which side of a direction boundary it is on.
pub const CaretPos = struct { offset: u32, affinity: Affinity = .downstream };

/// Result of `Line.hitTest`.
pub const Hit = struct {
    offset: u32,
    affinity: Affinity,
    /// The x was within `[0, width)`.
    inside: bool,
};

/// Glyphs of one font, size and level, in visual order.
pub const VisualRun = struct {
    instance: fonts.InstanceId,
    level: u8,
    glyph_start: u32,
    glyph_end: u32,
    /// Pen x of the run's first glyph.
    x: f32,
    size_px: f32,
    mode: RenderMode,
};

/// A caret stop: a grapheme boundary of the line, in logical order.
pub const Caret = struct {
    offset: u32,
    /// Downstream x: the leading edge of the grapheme starting here (the
    /// trailing edge of the last grapheme at the end of the line).
    x: f32,
    /// Upstream x: the trailing edge of the grapheme ending here (equals
    /// `x` at the start of the line and away from direction boundaries).
    x_up: f32,
    /// The grapheme starting here is right-to-left.
    rtl: bool,
};

/// A grapheme's visual extent; `Line.graphemes` is sorted by x.
pub const VisGrapheme = struct {
    x0: f32,
    x1: f32,
    start: u32,
    end: u32,
    rtl: bool,
};

/// One laid-out line. Arrays come from the caller's arena; glyph arrays
/// are in visual order. Offsets are byte offsets into the caller's text.
pub const Line = struct {
    /// The byte range of the text the line shows.
    start: u32 = 0,
    end: u32 = 0,
    runs: []const VisualRun = &.{},
    glyphs: []const GlyphId = &.{},
    /// Glyph origin x (pen position plus GPOS x offset).
    x: []const f32 = &.{},
    /// Glyph y offset, up positive (as in the font).
    y_off: []const f32 = &.{},
    /// Byte offset of each glyph's cluster.
    clusters: []const u32 = &.{},
    carets: []const Caret = &.{},
    graphemes: []const VisGrapheme = &.{},
    width: f32 = 0,
    ascent: f32 = 0,
    descent: f32 = 0,
    line_gap: f32 = 0,
    /// Where the caller should place the line's x = 0 (wrap's hanging
    /// indent); hit testing and carets are relative to it.
    indent: f32 = 0,
    paragraph_rtl: bool = false,

    const hit = @import("hit_test.zig");
    pub const hitTest = hit.hitTest;
    pub const caretX = hit.caretX;
    pub const selectionRects = hit.selectionRects;
    pub const moveVisual = hit.moveVisual;
};
