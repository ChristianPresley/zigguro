//! Terminal rows on an exact cell grid. Each cell holds one grapheme
//! cluster; glyphs sit at `col × cell_w` and are never stretched. A glyph
//! wider than its cells (a fallback font's) is scaled down to fit; one
//! narrower is centred. Box drawing, blocks, braille, Powerline and
//! sextants are drawn procedurally (`box_drawing.zig`) under the reserved
//! instance id 1. With `ligatures`, runs of ASCII cells in one style that
//! contain a character some lookup may start at are shaped, and a shaped
//! cluster is kept only when its advance matches the cells it covers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fonts = @import("../fonts/root.zig");
const registry = fonts.registry;
const ot = @import("../ot/root.zig");
const GlyphId = ot.GlyphId;
const glyph_key = @import("../cache/glyph_key.zig");
const GlyphKey = glyph_key.GlyphKey;
const RenderMode = glyph_key.RenderMode;
const Bitmap = @import("../raster/rasterizer.zig").Bitmap;
const Accumulator = @import("../raster/coverage.zig").Accumulator;
const decode = @import("../unicode/decode.zig");
const shape_cache = @import("../shape/shape_cache.zig");
const GlyphRun = @import("../shape/shaper.zig").GlyphRun;
const style_mod = @import("style.zig");
const TextStyle = style_mod.TextStyle;
const TextLayout = @import("line.zig").TextLayout;
pub const box_drawing = @import("box_drawing.zig");

/// The cell grid of a terminal font, in whole pixels where it matters.
pub const CellGrid = struct {
    /// The font size the grid was measured at.
    size_px: f32,
    cell_w: f32,
    cell_h: f32,
    /// Baseline below the cell top.
    baseline: f32,
    /// Underline top below the cell top, and its thickness.
    underline_y: f32,
    underline_h: f32,
    /// Strikeout top below the cell top, and its thickness.
    strike_y: f32,
    strike_h: f32,
};

/// How a cell's text is drawn. Bold and italic faces are matched by
/// E03.F07; until then they draw with the chain's instances.
pub const CellStyle = struct {
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    chain: fonts.ChainId,

    fn eql(a: CellStyle, b: CellStyle) bool {
        return a.bold == b.bold and a.italic == b.italic and a.faint == b.faint and a.chain == b.chain;
    }
};

/// One terminal cell: a grapheme cluster (empty is blank) and its width;
/// the cell after a wide character has width 0.
pub const Cell = struct {
    text: []const u8,
    width: u2 = 1,
    style: CellStyle,
};

/// Row layout options.
pub const CellOptions = struct {
    /// Shape ASCII runs so programming ligatures can form.
    ligatures: bool = false,
    bold_is_bright: bool = false,
};

/// A glyph placed on the grid. `x` is the pen position from the row's
/// left edge and `y` the baseline from its top (y down); a procedural
/// glyph's bitmap is the whole cell, so its `x`, `y` are the cell's top
/// left corner.
pub const CellGlyph = struct {
    col: u16,
    key: GlyphKey,
    x: f32,
    y: f32,
    /// The glyph was scaled down by this to fit (`key.size_q` already
    /// holds the scaled size).
    scale: f32 = 1,
    procedural: bool,
};

/// The grid for `style`'s primary instance: the advance of "M" when it is
/// monospaced, else the widest printable ASCII advance, rounded up; height
/// and baseline from the pixel-snapped metrics.
pub fn cellMetrics(tl: *const TextLayout, style: TextStyle) CellGrid {
    const r = tl.reg.get(tl.fb.primary(style.chain));
    const face = r.inst.face;
    const s = style.size_px / r.upem;
    var adv: f32 = 0;
    if (r.monospace) {
        adv = r.inst.advance(face.glyphIndex('M'));
    } else for (0x20..0x7F) |c| {
        adv = @max(adv, r.inst.advance(face.glyphIndex(@intCast(c))));
    }
    const m = tl.fontMetrics(style);
    return .{
        .size_px = style.size_px,
        .cell_w = @max(1, @ceil(adv * s)),
        .cell_h = @max(1, m.line_height),
        .baseline = m.ascent,
        .underline_y = m.ascent + m.underline_y,
        .underline_h = m.underline_h,
        .strike_y = m.ascent + m.strike_y,
        .strike_h = m.strike_h,
    };
}

/// True for code points drawn procedurally.
pub const isProcedural = box_drawing.isProcedural;

/// The key of procedural `cp` on `grid`: instance 1, the glyph's id in
/// the low 9 bits of `glyph` and the cell width (at most 127 px) above
/// them, the cell height as the size.
pub fn proceduralKey(cp: u21, grid: CellGrid) GlyphKey {
    const w: u16 = @intFromFloat(@min(grid.cell_w, 127));
    return .{
        .instance = registry.procedural_instance,
        .glyph = box_drawing.id(cp) | w << 9,
        .size_q = glyph_key.quantizeSize(grid.cell_h),
    };
}

/// What a procedural key draws: the code point and the cell size in px.
pub fn proceduralOf(key: GlyphKey) ?struct { cp: u21, w: u32, h: u32 } {
    if (key.instance != registry.procedural_instance) return null;
    const cp = box_drawing.codepoint(key.glyph & 0x1FF) orelse return null;
    return .{ .cp = cp, .w = key.glyph >> 9, .h = @intFromFloat(@round(key.pxPerEm())) };
}

/// Draws procedural `cp` into `out` as gray8 coverage of exactly the
/// cell's size (rounded to whole pixels), pen origin at the cell's top
/// left. `out.pixels` is allocated from `gpa` and owned by the caller.
pub fn renderProcedural(cp: u21, grid: CellGrid, out: *Bitmap, gpa: Allocator) !void {
    const w: u32 = @intFromFloat(@max(1, @round(grid.cell_w)));
    const h: u32 = @intFromFloat(@max(1, @round(grid.cell_h)));
    const pixels = try gpa.alloc(u8, w * h);
    errdefer gpa.free(pixels);
    var acc: Accumulator = .{};
    defer acc.deinit(gpa);
    var canvas: box_drawing.Canvas = .{ .w = w, .h = h, .pixels = pixels };
    if (!try box_drawing.draw(cp, &canvas, &acc, gpa)) return error.NotProcedural;
    out.* = .{ .width = @intCast(w), .height = @intCast(h), .stride = w, .left = 0, .top = 0, .format = .gray8, .pixels = pixels };
}

fn modeOf(reg: *const registry.Registered, size_px: f32) RenderMode {
    return if (reg.color) .color else if (size_px >= glyph_key.sdf_threshold_px) .sdf else .gray;
}

fn singleCodepoint(text: []const u8) ?u21 {
    const u = decode.at(text, 0);
    return if (u.len == text.len) u.cp else null;
}

/// Appends the glyphs of one row to `out`.
pub fn layoutCells(tl: *TextLayout, arena: Allocator, row: []const Cell, grid: CellGrid, o: CellOptions, out: *std.ArrayList(CellGlyph)) !void {
    var i: usize = 0;
    while (i < row.len) {
        const cell = row[i];
        if (cell.text.len == 0 or cell.width == 0 or (cell.text.len == 1 and cell.text[0] == ' ')) {
            i += 1;
            continue;
        }
        if (singleCodepoint(cell.text)) |cp| if (isProcedural(cp)) {
            try out.append(arena, .{ .col = @intCast(i), .key = proceduralKey(cp, grid), .x = @as(f32, @floatFromInt(i)) * grid.cell_w, .y = 0, .procedural = true });
            i += 1;
            continue;
        };
        if (o.ligatures and isAsciiCell(cell)) {
            var j = i + 1;
            while (j < row.len and isAsciiCell(row[j]) and row[j].style.eql(cell.style)) j += 1;
            if (j - i >= 2 and try shapeRun(tl, arena, row[i..j], i, grid, out)) {
                i = j;
                continue;
            }
        }
        try placeCell(tl, arena, cell, i, grid, out);
        i += 1;
    }
}

fn isAsciiCell(c: Cell) bool {
    return c.width == 1 and c.text.len == 1 and c.text[0] > 0x20 and c.text[0] < 0x7F;
}

/// Places one cell's cluster: the cmap glyph for a single code point,
/// shaped glyphs otherwise; scaled down when wider than its cells and
/// centred when narrower.
fn placeCell(tl: *TextLayout, arena: Allocator, cell: Cell, col: usize, grid: CellGrid, out: *std.ArrayList(CellGlyph)) !void {
    const id = tl.fb.resolve(cell.style.chain, cell.text, .default);
    const reg = tl.reg.get(id);
    const s = grid.size_px / reg.upem;
    var run: GlyphRun = .{};
    var one_gid: [1]GlyphId = undefined;
    var one_adv: [1]i32 = undefined;
    var zero: [1]i32 = .{0};
    if (cell.text.len == 1 and cell.text[0] < 0x80 and reg.coversAscii()) {
        // Printable ASCII: the per-instance table, no cmap lookup.
        const info = try tl.asciiInfo(id, 0);
        one_gid[0] = info.gid[cell.text[0]];
        one_adv[0] = info.adv[cell.text[0]];
        run = .{ .gids = &one_gid, .x_adv = &one_adv, .x_off = &zero, .y_off = &zero };
    } else if (singleCodepoint(cell.text)) |cp| {
        one_gid[0] = reg.inst.face.glyphIndex(cp);
        one_adv[0] = @intFromFloat(@round(reg.inst.advance(one_gid[0])));
        run = .{ .gids = &one_gid, .x_adv = &one_adv, .x_off = &zero, .y_off = &zero };
    } else {
        try shape_cache.shapeCached(&tl.shaper, &tl.cache, reg.inst, id, 0, cell.text, scriptOf(cell.text), .ltr, ot.tag("dflt"), &.{}, &run, arena);
    }
    var adv_units: i32 = 0;
    for (run.x_adv) |a| adv_units += a;
    const adv = @as(f32, @floatFromInt(adv_units)) * s;
    const target = @as(f32, @floatFromInt(cell.width)) * grid.cell_w;
    var scale: f32 = 1;
    var x0 = @as(f32, @floatFromInt(col)) * grid.cell_w;
    var y = grid.baseline;
    if (adv > target + 1) {
        scale = target / adv;
        // Keep the em box centred on the same line as unscaled glyphs.
        const m = reg.inst.metrics();
        const centre = (m.ascender + m.descender) / 2 * s;
        y -= centre * (1 - scale);
    } else if (adv < target) {
        x0 += @round((target - adv) / 2);
    }
    const size_q = glyph_key.quantizeSize(grid.size_px * scale);
    const mode = modeOf(reg, grid.size_px * scale);
    var pen: f32 = 0;
    for (run.gids, 0..) |gid, k| {
        try out.append(arena, .{
            .col = @intCast(col),
            .key = .{ .instance = id, .glyph = gid, .size_q = size_q, .mode = mode },
            .x = x0 + (pen + @as(f32, @floatFromInt(run.x_off[k])) * s) * scale,
            .y = y - @as(f32, @floatFromInt(run.y_off[k])) * s * scale,
            .scale = scale,
            .procedural = false,
        });
        pen += @as(f32, @floatFromInt(run.x_adv[k])) * s;
    }
}

fn scriptOf(text: []const u8) @import("../unicode/root.zig").Script {
    var it = @import("../unicode/script.zig").ScriptRunIterator.init(text);
    return if (it.next()) |r| r.script else .Zyyy;
}

/// Shapes a run of ASCII cells when it holds a ligature-start character.
/// Returns false (placing nothing) when the run needs no shaping. Shaped
/// clusters whose advance is not their cell count × cell width (within
/// 1 px) fall back to one glyph per cell.
fn shapeRun(tl: *TextLayout, arena: Allocator, cells: []const Cell, first_col: usize, grid: CellGrid, out: *std.ArrayList(CellGlyph)) !bool {
    const chain = cells[0].style.chain;
    const id = tl.fb.primary(chain);
    const reg = tl.reg.get(id);
    if (!reg.coversAscii()) return false;
    const hot = (try tl.asciiTrivial(id, 0)).hot;
    var any = false;
    const text = try arena.alloc(u8, cells.len);
    for (cells, text) |c, *b| {
        b.* = c.text[0];
        if (hot >> @intCast(b.*) & 1 != 0) any = true;
    }
    if (!any) return false;
    var run: GlyphRun = .{};
    try shape_cache.shapeCached(&tl.shaper, &tl.cache, reg.inst, id, 0, text, .Latn, .ltr, ot.tag("dflt"), &.{}, &run, arena);
    const s = grid.size_px / reg.upem;
    const size_q = glyph_key.quantizeSize(grid.size_px);
    const mode = modeOf(reg, grid.size_px);
    const n = run.len();
    var g: usize = 0;
    while (g < n) {
        var e = g + 1;
        while (e < n and run.clusters[e] == run.clusters[g]) e += 1;
        const cs = run.clusters[g];
        const ce: u32 = if (e < n) run.clusters[e] else @intCast(text.len);
        const k = ce - cs;
        var adv_units: i32 = 0;
        for (run.x_adv[g..e]) |a| adv_units += a;
        const adv = @as(f32, @floatFromInt(adv_units)) * s;
        const col = first_col + cs;
        if (@abs(adv - @as(f32, @floatFromInt(k)) * grid.cell_w) <= 1) {
            var pen = @as(f32, @floatFromInt(col)) * grid.cell_w;
            for (g..e) |q| {
                try out.append(arena, .{
                    .col = @intCast(col),
                    .key = .{ .instance = id, .glyph = run.gids[q], .size_q = size_q, .mode = mode },
                    .x = pen + @as(f32, @floatFromInt(run.x_off[q])) * s,
                    .y = grid.baseline - @as(f32, @floatFromInt(run.y_off[q])) * s,
                    .procedural = false,
                });
                pen += @as(f32, @floatFromInt(run.x_adv[q])) * s;
            }
        } else {
            for (cs..ce) |c| try placeCell(tl, arena, cells[c], first_col + c, grid, out);
        }
        g = e;
    }
    return true;
}
