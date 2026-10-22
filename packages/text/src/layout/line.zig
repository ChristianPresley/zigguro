//! `TextLayout`: lays out one line of styled text. Itemizes it, shapes each
//! item through the word cache, scales to pixels, applies tabs and letter
//! spacing, orders runs visually (UAX #9 L2) and derives caret stops and
//! grapheme extents for hit testing.
//!
//! ASCII text in one style skips shaping when the font's lookups cannot
//! touch ASCII glyphs (`ascii_trivial`): glyphs and advances come from a
//! per-(instance, feature set) table built by shaping each character
//! once, so both paths produce identical positions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ot = @import("../ot/root.zig");
const GlyphId = ot.GlyphId;
const Gdef = @import("../ot/gdef.zig").Gdef;
const unicode = @import("../unicode/root.zig");
const Script = unicode.Script;
const grapheme = unicode.grapheme;
const decode = @import("../unicode/decode.zig");
const fonts = @import("../fonts/root.zig");
const FontRegistry = fonts.FontRegistry;
const Fallback = fonts.Fallback;
const InstanceId = fonts.InstanceId;
const shape = @import("../shape/root.zig");
const shaper_mod = @import("../shape/shaper.zig");
const Shaper = shaper_mod.Shaper;
const GlyphRun = shaper_mod.GlyphRun;
const shape_cache = @import("../shape/shape_cache.zig");
const ShapeCache = shape_cache.ShapeCache;
const buffer = @import("../shape/buffer.zig");
const Feature = buffer.Feature;
const digest = @import("../shape/digest.zig");
const glyph_key = @import("../cache/glyph_key.zig");
const RenderMode = glyph_key.RenderMode;
const style_mod = @import("style.zig");
const TextStyle = style_mod.TextStyle;
const StyleRun = style_mod.StyleRun;
const LineOptions = style_mod.LineOptions;
const WrapOptions = style_mod.WrapOptions;
const PxMetrics = style_mod.PxMetrics;
const Line = style_mod.Line;
const VisualRun = style_mod.VisualRun;
const Caret = style_mod.Caret;
const VisGrapheme = style_mod.VisGrapheme;
const FeatureSetId = style_mod.FeatureSetId;
const itemize_mod = @import("itemize.zig");
const Item = itemize_mod.Item;
const WidthCache = @import("width_cache.zig").WidthCache;

const dflt = ot.tag("dflt");

/// Per (instance, feature set): whether ASCII shapes trivially, and the
/// glyph and advance (font units) of each printable ASCII character.
pub const AsciiInfo = struct {
    /// No lookup can touch ASCII glyphs.
    trivial: bool,
    /// The fast path applies to text without `hot` characters.
    usable: bool,
    /// Bit `c`: a lookup may start at the glyph of ASCII `c`.
    hot: u128,
    /// `fast[c]`: ASCII `c` may take the fast path (printable or tab, and
    /// not hot).
    fast: [256]bool,
    gid: [128]GlyphId,
    adv: [128]i32,
};

/// A shaped item ready for positioning.
const Shaped = struct {
    item: Item,
    run: GlyphRun,
    style: TextStyle,
};

/// Lays out text. One per render thread.
pub const TextLayout = struct {
    gpa: Allocator,
    reg: *const FontRegistry,
    fb: *const Fallback,
    shaper: Shaper,
    cache: ShapeCache,
    widths: WidthCache,
    /// Interned feature lists; index 0 is the empty list.
    feature_sets: std.ArrayList([]const Feature) = .empty,
    ascii: std.AutoHashMapUnmanaged(u64, *AsciiInfo) = .empty,
    /// Lay out plain ASCII without shaping when that gives the same result
    /// (tests and benches turn it off to compare).
    fast_path: bool = true,
    /// Scratch for `measure` and table building; reset per use.
    scratch: std.heap.ArenaAllocator,

    /// A layout engine over the instances of `reg` and chains of `fb`.
    pub fn init(gpa: Allocator, reg: *const FontRegistry, fb: *const Fallback) Allocator.Error!TextLayout {
        var cache = try ShapeCache.init(gpa, .{});
        errdefer cache.deinit();
        var widths = try WidthCache.init(gpa);
        errdefer widths.deinit();
        var tl: TextLayout = .{
            .gpa = gpa,
            .reg = reg,
            .fb = fb,
            .shaper = Shaper.init(gpa),
            .cache = cache,
            .widths = widths,
            .scratch = .init(gpa),
        };
        try tl.feature_sets.append(gpa, &.{});
        return tl;
    }

    /// Frees caches and tables.
    pub fn deinit(tl: *TextLayout) void {
        for (tl.feature_sets.items[1..]) |f| tl.gpa.free(f);
        tl.feature_sets.deinit(tl.gpa);
        var it = tl.ascii.valueIterator();
        while (it.next()) |v| tl.gpa.destroy(v.*);
        tl.ascii.deinit(tl.gpa);
        tl.scratch.deinit();
        tl.widths.deinit();
        tl.cache.deinit();
        tl.shaper.deinit();
        tl.* = undefined;
    }

    /// The id of a feature list (interned; the same list gets the same id).
    pub fn featureSet(tl: *TextLayout, features: []const Feature) Allocator.Error!FeatureSetId {
        for (tl.feature_sets.items, 0..) |f, i| if (sameFeatures(f, features)) return @intCast(i);
        if (tl.feature_sets.items.len > std.math.maxInt(FeatureSetId)) return error.OutOfMemory;
        const copy = try tl.gpa.dupe(Feature, features);
        errdefer tl.gpa.free(copy);
        try tl.feature_sets.append(tl.gpa, copy);
        return @intCast(tl.feature_sets.items.len - 1);
    }

    /// Lays out `text` as one line. `styles` must not be empty.
    pub fn layoutLine(tl: *TextLayout, arena: Allocator, text: []const u8, styles: []const StyleRun, o: LineOptions) !Line {
        const lv = try itemize_mod.resolveLevels(arena, text, o.base_dir);
        const levels = if (lv.paragraph) |*para| try itemize_mod.lineByteLevels(arena, para, 0, @intCast(text.len)) else null;
        return tl.buildLine(arena, text, 0, styles, levels, lv.base, o.tab_width_px);
    }

    /// The width of `text` in one style, from the width cache when present.
    pub fn measure(tl: *TextLayout, text: []const u8, style: TextStyle) f32 {
        const k = WidthCache.key(text, style.hash());
        if (tl.widths.get(k, @intCast(text.len))) |w| return w;
        defer _ = tl.scratch.reset(.retain_capacity);
        const line = tl.layoutLine(tl.scratch.allocator(), text, &.{.{ .end = @intCast(text.len), .style = style }}, .{}) catch return 0;
        tl.widths.put(k, @intCast(text.len), line.width);
        return line.width;
    }

    /// Wraps a paragraph to `max_w` px (see `wrap.zig`).
    pub fn wrap(tl: *TextLayout, arena: Allocator, text: []const u8, styles: []const StyleRun, max_w: f32, o: WrapOptions) ![]const Line {
        return @import("wrap.zig").wrap(tl, arena, text, styles, max_w, o);
    }

    /// Pixel metrics of the style's primary instance.
    pub fn fontMetrics(tl: *const TextLayout, style: TextStyle) PxMetrics {
        const r = tl.reg.get(tl.fb.primary(style.chain));
        const m = r.inst.metrics();
        const s = style.size_px / r.upem;
        const ascent = @ceil(m.ascender * s);
        const descent = @ceil(-m.descender * s);
        return .{
            .ascent = ascent,
            .descent = descent,
            .line_height = ascent + descent + @round(@max(m.line_gap, 0) * s),
            .x_height = m.x_height * s,
            .cap_height = m.cap_height * s,
            .underline_y = @round(-m.underline_pos * s),
            .underline_h = @max(1, @round(m.underline_thickness * s)),
            .strike_y = @round(-m.strikeout_pos * s),
            .strike_h = @max(1, @round(m.strikeout_thickness * s)),
        };
    }

    /// True when ASCII text in this instance and feature set lays out
    /// without shaping; `hot` characters (those some lookup may start at)
    /// send a line through the shaper.
    pub fn asciiTrivial(tl: *TextLayout, id: InstanceId, fs: FeatureSetId) !struct { trivial: bool, hot: u128 } {
        const info = try tl.asciiInfo(id, fs);
        return .{ .trivial = info.trivial, .hot = if (info.usable) info.hot else ~@as(u128, 0) };
    }

    /// The ASCII table of an instance and feature set, built on first use.
    pub fn asciiInfo(tl: *TextLayout, id: InstanceId, fs: FeatureSetId) !*const AsciiInfo {
        const key = @as(u64, id) << 16 | fs;
        if (tl.ascii.get(key)) |v| return v;
        const info = try tl.gpa.create(AsciiInfo);
        errdefer tl.gpa.destroy(info);
        const inst = tl.reg.get(id).inst;
        const features = tl.feature_sets.items[fs];
        info.usable = true;
        info.hot = 0;
        for ([_]Script{ .Latn, .Zyyy }) |script| {
            const p = try tl.shaper.plan(inst, script, dflt, .ltr, features);
            if (planAsciiHot(p)) |h| info.hot |= h else info.usable = false;
        }
        @memset(&info.gid, 0);
        @memset(&info.adv, 0);
        defer _ = tl.scratch.reset(.retain_capacity);
        for (0x20..0x7F) |c| {
            var run: GlyphRun = .{};
            const ch = [1]u8{@intCast(c)};
            try tl.shaper.shape(inst, &ch, .Latn, .ltr, dflt, features, &run, tl.scratch.allocator());
            if (run.len() != 1) {
                info.usable = false;
                continue;
            }
            info.gid[c] = run.gids[0];
            info.adv[c] = run.x_adv[0];
        }
        info.gid['\t'] = info.gid[' '];
        // A tab shapes as .notdef, which no lookup should see; keep it
        // out of the fast path if one could.
        if (info.hot & (@as(u128, 1) << ' ') != 0) info.hot |= @as(u128, 1) << '\t';
        info.trivial = info.usable and info.hot == 0;
        @memset(&info.fast, false);
        for (0..128) |c| info.fast[c] = info.usable and (c == '\t' or (c >= 0x20 and c < 0x7F)) and info.hot >> @intCast(c) & 1 == 0;
        try tl.ascii.put(tl.gpa, key, info);
        return info;
    }

    /// Builds the line for `text` (a slice of the caller's text starting at
    /// byte `offset`) with per-byte `levels` (null: all at `base`).
    pub fn buildLine(tl: *TextLayout, arena: Allocator, text: []const u8, offset: u32, styles: []const StyleRun, levels: ?[]const u8, base: u8, tab_width_px: f32) !Line {
        std.debug.assert(styles.len > 0);
        if (try tl.fastLine(arena, text, offset, styles, levels, tab_width_px)) |l| return l;
        var shaped: std.ArrayList(Shaped) = .empty;
        {
            var items: std.ArrayList(Item) = .empty;
            try itemize_mod.itemizeLevels(arena, text, styles, levels, base, tl.fb, &items);
            try shaped.ensureTotalCapacity(arena, items.items.len);
            for (items.items) |it| {
                const st = styles[it.style_index].style;
                var run: GlyphRun = .{};
                const dir: buffer.Direction = if (it.level & 1 == 1) .rtl else .ltr;
                if (it.instance == fonts.registry.last_resort_instance) {
                    run = try tl.lastResortRun(arena, text[it.start..it.end], st, dir);
                } else {
                    const r = tl.reg.get(it.instance);
                    try shape_cache.shapeCached(&tl.shaper, &tl.cache, r.inst, it.instance, st.features, text[it.start..it.end], it.script, dir, dflt, tl.feature_sets.items[st.features], &run, arena);
                }
                shaped.appendAssumeCapacity(.{ .item = it, .run = run, .style = st });
            }
        }
        return tl.position(arena, text, offset, styles, shaped.items, base, tab_width_px);
    }

    /// Glyphs of text nothing maps: one last-resort glyph per grapheme,
    /// 1 em wide in the style's primary instance (whose units the run
    /// uses), in visual order for `dir`.
    fn lastResortRun(tl: *TextLayout, arena: Allocator, text: []const u8, st: TextStyle, dir: buffer.Direction) !GlyphRun {
        const upem: i32 = @intFromFloat(tl.reg.get(tl.fb.primary(st.chain)).upem);
        var n: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (n += 1) i = grapheme.nextBoundary(text, i);
        var run = try GlyphRun.alloc(arena, n);
        i = 0;
        var k: usize = 0;
        while (i < text.len) : (k += 1) {
            const at = if (dir == .rtl) n - 1 - k else k;
            run.gids[at] = tl.reg.lastResortGlyph(decode.at(text, i).cp);
            run.clusters[at] = @intCast(i);
            run.x_adv[at] = upem;
            run.x_off[at] = 0;
            run.y_off[at] = 0;
            run.unsafe_to_break[at] = false;
            i = grapheme.nextBoundary(text, i);
        }
        return run;
    }

    /// The registry entry whose metrics a run of `instance` in `st`
    /// uses (the primary for last-resort runs).
    fn metricsEntry(tl: *const TextLayout, instance: InstanceId, st: TextStyle) *const fonts.registry.Registered {
        return tl.reg.get(if (instance == fonts.registry.last_resort_instance) tl.fb.primary(st.chain) else instance);
    }

    /// The line for ASCII text in one style whose glyphs need no shaping,
    /// or null when the text does not qualify. Same results as `position`
    /// over the shaped text: one glyph, cluster and grapheme per byte.
    fn fastLine(tl: *TextLayout, arena: Allocator, text: []const u8, offset: u32, styles: []const StyleRun, levels: ?[]const u8, tab_width_px: f32) !?Line {
        if (!tl.fast_path or levels != null or text.len == 0) return null;
        const st = styles[0].style;
        for (styles[1..]) |s| if (!s.style.sameShape(st)) return null;
        const id = tl.fb.primary(st.chain);
        const reg = tl.reg.get(id);
        if (!reg.coversAscii()) return null;
        const info = try tl.asciiInfo(id, st.features);
        for (text) |c| if (!info.fast[c]) return null;

        const n = text.len;
        const glyphs = try arena.alloc(GlyphId, n);
        const xs = try arena.alloc(f32, n);
        const ys = try arena.alloc(f32, n);
        const clusters = try arena.alloc(u32, n);
        const graphemes = try arena.alloc(VisGrapheme, n);
        const carets = try arena.alloc(Caret, n + 1);
        const scale = st.size_px / reg.upem;
        const ls = st.letter_spacing;
        var tab: f32 = tab_width_px;
        if (tab <= 0) tab = @max(reg.inst.advance(info.gid[' ']) * scale * 8, 1);
        var pen: f32 = 0;
        for (text, 0..) |c, i| {
            const at: u32 = offset + @as(u32, @intCast(i));
            const adv = if (c == '\t')
                (@floor(pen / tab + 1e-3) + 1) * tab - pen
            else
                @as(f32, @floatFromInt(info.adv[c])) * scale;
            glyphs[i] = info.gid[c];
            xs[i] = pen;
            ys[i] = 0;
            clusters[i] = at;
            carets[i] = .{ .offset = at, .x = pen, .x_up = pen, .rtl = false };
            const x0 = pen;
            pen += adv;
            pen += ls;
            graphemes[i] = .{ .x0 = x0, .x1 = pen, .start = at, .end = at + 1, .rtl = false };
        }
        const end = offset + @as(u32, @intCast(n));
        carets[n] = .{ .offset = end, .x = pen, .x_up = pen, .rtl = false };
        const runs = try arena.alloc(VisualRun, 1);
        runs[0] = .{ .instance = id, .level = 0, .glyph_start = 0, .glyph_end = @intCast(n), .x = 0, .size_px = st.size_px, .mode = modeOf(reg, st.size_px) };
        const m = reg.inst.metrics();
        return .{
            .start = offset,
            .end = end,
            .runs = runs,
            .glyphs = glyphs,
            .x = xs,
            .y_off = ys,
            .clusters = clusters,
            .carets = carets,
            .graphemes = graphemes,
            .width = pen,
            .ascent = @ceil(m.ascender * scale),
            .descent = @ceil(-m.descender * scale),
            .line_gap = @round(@max(m.line_gap, 0) * scale),
        };
    }

    /// Positions shaped items in visual order and derives runs, graphemes
    /// and carets.
    fn position(tl: *TextLayout, arena: Allocator, text: []const u8, offset: u32, styles: []const StyleRun, shaped: []const Shaped, base: u8, tab_width_px: f32) !Line {
        var n_glyphs: usize = 0;
        for (shaped) |s| n_glyphs += s.run.len();
        const glyphs = try arena.alloc(GlyphId, n_glyphs);
        const xs = try arena.alloc(f32, n_glyphs);
        const ys = try arena.alloc(f32, n_glyphs);
        const clusters = try arena.alloc(u32, n_glyphs);
        const runs = try arena.alloc(VisualRun, shaped.len);
        var graphemes: std.ArrayList(VisGrapheme) = try .initCapacity(arena, text.len + 1);

        // UAX #9 L2 over items (already split at level changes).
        const order = try arena.alloc(u32, shaped.len);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        reorderItems(shaped, order);

        var line: Line = .{ .start = offset, .end = offset + @as(u32, @intCast(text.len)), .paragraph_rtl = base & 1 == 1 };
        var pen: f32 = 0;
        var g_out: usize = 0;
        for (order, 0..) |oi, ri| {
            const s = shaped[oi];
            const it = s.item;
            const last_resort = it.instance == fonts.registry.last_resort_instance;
            const reg = tl.metricsEntry(it.instance, s.style);
            const scale = s.style.size_px / reg.upem;
            const rtl = it.level & 1 == 1;
            runs[ri] = .{
                .instance = it.instance,
                .level = it.level,
                .glyph_start = @intCast(g_out),
                .glyph_end = @intCast(g_out + s.run.len()),
                .x = pen,
                .size_px = s.style.size_px,
                .mode = if (last_resort) .gray else modeOf(reg, s.style.size_px),
            };
            const m = reg.inst.metrics();
            line.ascent = @max(line.ascent, @ceil(m.ascender * scale));
            line.descent = @max(line.descent, @ceil(-m.descender * scale));
            line.line_gap = @max(line.line_gap, @round(@max(m.line_gap, 0) * scale));

            const run = s.run;
            const n = run.len();
            if (n == 0) {
                try appendGraphemes(arena, &graphemes, text, it.start, it.end, &.{ pen, pen }, rtl);
                continue;
            }
            var i: usize = 0;
            while (i < n) {
                var j = i + 1;
                while (j < n and run.clusters[j] == run.clusters[i]) j += 1;
                var cs = run.clusters[i] + it.start;
                const ce = if (rtl)
                    (if (i > 0) run.clusters[i - 1] + it.start else it.end)
                else
                    (if (j < n) run.clusters[j] + it.start else it.end);
                // The logically first cluster takes any bytes before it.
                if ((!rtl and i == 0) or (rtl and j == n)) cs = it.start;
                const gx0 = pen;
                for (i..j) |k| {
                    var gid = run.gids[k];
                    var adv = @as(f32, @floatFromInt(run.x_adv[k])) * scale;
                    if (!last_resort and j - i == 1 and ce - cs == 1 and text[cs] == '\t') {
                        gid = reg.inst.face.glyphIndex(' ');
                        const space = reg.inst.advance(gid) * scale;
                        const tab = if (tab_width_px > 0) tab_width_px else @max(space * 8, 1);
                        adv = (@floor(pen / tab + 1e-3) + 1) * tab - pen;
                    }
                    glyphs[g_out] = gid;
                    xs[g_out] = pen + @as(f32, @floatFromInt(run.x_off[k])) * scale;
                    ys[g_out] = @as(f32, @floatFromInt(run.y_off[k])) * scale;
                    clusters[g_out] = cs + offset;
                    g_out += 1;
                    pen += adv;
                }
                pen += s.style.letter_spacing;
                // Grapheme edges inside the cluster: GDEF ligature carets for
                // a single ligature glyph, else uniform subdivision.
                var bounds: [33]u32 = undefined;
                const k = graphemeBounds(text, cs, ce, &bounds);
                var edges: [33]f32 = undefined;
                edges[0] = gx0;
                edges[k] = pen;
                var have = false;
                if (k > 1 and j - i == 1 and !last_resort) {
                    var carets: [32]i16 = undefined;
                    const gdef = if (reg.inst.face.knownTable(.gdef)) |t| Gdef.init(t) catch Gdef{} else Gdef{};
                    const nc = gdef.ligatureCarets(run.gids[i], carets[0 .. k - 1]);
                    if (nc >= k - 1) {
                        std.mem.sort(i16, carets[0 .. k - 1], {}, std.sort.asc(i16));
                        for (1..k) |v| edges[v] = std.math.clamp(gx0 + @as(f32, @floatFromInt(carets[v - 1])) * scale, gx0, pen);
                        have = true;
                    }
                }
                if (!have) for (1..k) |v| {
                    edges[v] = gx0 + (pen - gx0) * @as(f32, @floatFromInt(v)) / @as(f32, @floatFromInt(k));
                };
                for (0..k) |v| {
                    const g = if (rtl) k - 1 - v else v;
                    try graphemes.append(arena, .{ .x0 = edges[v], .x1 = edges[v + 1], .start = bounds[g] + offset, .end = bounds[g + 1] + offset, .rtl = rtl });
                }
                i = j;
            }
        }
        line.width = pen;
        if (shaped.len == 0) {
            const m = tl.fontMetrics(styles[0].style);
            line.ascent = m.ascent;
            line.descent = m.descent;
            line.line_gap = m.line_height - m.ascent - m.descent;
        }
        line.runs = runs;
        line.glyphs = glyphs;
        line.x = xs;
        line.y_off = ys;
        line.clusters = clusters;
        line.graphemes = graphemes.items;
        line.carets = try buildCarets(arena, graphemes.items, line.end, base & 1 == 1, offset);
        return line;
    }
};

fn modeOf(reg: *const fonts.registry.Registered, size_px: f32) RenderMode {
    return if (reg.color) .color else if (size_px >= glyph_key.sdf_threshold_px) .sdf else .gray;
}

fn sameFeatures(a: []const Feature, b: []const Feature) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.tag != y.tag or x.value != y.value or x.start != y.start or x.end != y.end) return false;
    return true;
}

/// The ASCII characters at which a lookup the plan applies may start
/// matching ASCII-only text; null when the plan cannot be analysed that
/// way (ranged features, a legacy `kern` table, huge glyph sets).
fn planAsciiHot(p: *const shape.ShapePlan) ?u128 {
    if (p.ranged.len != 0) return null;
    if (p.apply_kern and p.kern != null) return null;
    const face = p.inst.face;
    var set_buf: [1024]u64 = @splat(0);
    var hot_buf: [1024]u64 = @splat(0);
    const words = digest.words(face.num_glyphs);
    if (words > set_buf.len) return null;
    const set = set_buf[0..@max(words, 1)];
    const hot = hot_buf[0..set.len];
    for (0x20..0x7F) |c| digest.add(set, face.glyphIndex(@intCast(c)));
    const tables = [2]?ot.layout_common.LayoutTable{ p.gsub, p.gpos };
    const stage_sets = [2][]const shape.plan.Stage{ p.gsub_stages, p.gpos_stages };
    for (tables, stage_sets, 0..) |maybe, stages, ti| {
        const t = maybe orelse continue;
        if (ti == 1 and !p.apply_gpos) continue;
        for (stages) |s| for (s.lookups) |l| {
            if (l.mask & p.global_mask == 0 and p.complex.setupMasks == null) continue;
            if (!digest.intersects(set, l.digest)) continue;
            shape.set_closure.hotGlyphs(t, l.index, set, if (ti == 0) 7 else 9, hot);
        };
    }
    var bits: u128 = 0;
    for (0x20..0x7F) |c| if (digest.has(hot, face.glyphIndex(@intCast(c)))) {
        bits |= @as(u128, 1) << @intCast(c);
    };
    return bits;
}

/// Splits `[cs, ce)` at grapheme boundaries into `out` (k + 1 offsets);
/// returns k. More than 32 graphemes in one cluster count as one.
fn graphemeBounds(text: []const u8, cs: u32, ce: u32, out: *[33]u32) usize {
    out[0] = cs;
    if (ce - cs <= 1) {
        out[1] = ce;
        return 1;
    }
    var k: usize = 0;
    var b = cs;
    while (b < ce and k < 32) {
        const nb: u32 = @intCast(@min(grapheme.nextBoundary(text[0..ce], b), ce));
        k += 1;
        out[k] = if (nb <= b) ce else nb;
        b = out[k];
    }
    out[k] = ce;
    return k;
}

fn appendGraphemes(arena: Allocator, list: *std.ArrayList(VisGrapheme), text: []const u8, s: u32, e: u32, edges: *const [2]f32, rtl: bool) !void {
    var b = s;
    while (b < e) {
        const nb: u32 = @intCast(@min(grapheme.nextBoundary(text[0..e], b), e));
        try list.append(arena, .{ .x0 = edges[0], .x1 = edges[1], .start = b, .end = if (nb <= b) e else nb, .rtl = rtl });
        b = if (nb <= b) e else nb;
    }
}

/// UAX #9 L2 on items: from the highest level down to the lowest odd
/// level, reverse each maximal sequence at that level or higher.
fn reorderItems(shaped: []const Shaped, order: []u32) void {
    var hi: u8 = 0;
    var lo_odd: u8 = 255;
    for (shaped) |s| {
        hi = @max(hi, s.item.level);
        if (s.item.level & 1 == 1) lo_odd = @min(lo_odd, s.item.level);
    }
    if (lo_odd == 255) return;
    var k = hi;
    while (k >= lo_odd) : (k -= 1) {
        var i: usize = 0;
        while (i < order.len) {
            if (shaped[order[i]].item.level < k) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < order.len and shaped[order[j]].item.level >= k) j += 1;
            std.mem.reverse(u32, order[i..j]);
            i = j;
        }
        if (k == 0) break;
    }
}

fn byStart(_: void, a: VisGrapheme, b: VisGrapheme) bool {
    return a.start < b.start;
}

/// Caret stops in logical order from the visual graphemes.
fn buildCarets(arena: Allocator, vis: []const VisGrapheme, end: u32, rtl_para: bool, start: u32) ![]Caret {
    // Left-to-right lines are already in logical order.
    var sorted = true;
    for (1..@max(vis.len, 1)) |i| if (vis[i].start < vis[i - 1].start) {
        sorted = false;
        break;
    };
    const logical = if (sorted) vis else blk: {
        const copy = try arena.dupe(VisGrapheme, vis);
        std.mem.sort(VisGrapheme, copy, {}, byStart);
        break :blk copy;
    };
    const carets = try arena.alloc(Caret, logical.len + 1);
    for (logical, 0..) |g, i| {
        const lead = if (g.rtl) g.x1 else g.x0;
        const up = if (i == 0) lead else trailing(logical[i - 1]);
        carets[i] = .{ .offset = g.start, .x = lead, .x_up = up, .rtl = g.rtl };
    }
    if (logical.len == 0) {
        carets[0] = .{ .offset = start, .x = 0, .x_up = 0, .rtl = rtl_para };
    } else {
        const last = logical[logical.len - 1];
        const t = trailing(last);
        carets[logical.len] = .{ .offset = end, .x = t, .x_up = t, .rtl = last.rtl };
    }
    return carets;
}

fn trailing(g: VisGrapheme) f32 {
    return if (g.rtl) g.x0 else g.x1;
}
