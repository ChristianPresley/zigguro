//! Terminal cell tests: metrics, procedural glyph joins and goldens, wide
//! and fallback glyph fitting, ligature acceptance and style runs.

const std = @import("std");
const testing = std.testing;
const fonts = @import("../fonts/root.zig");
const TestFont = @import("../fonts/fallback_test.zig").TestFont;
const testdata = @import("../testing/fonts.zig");
const glyph_key = @import("../cache/glyph_key.zig");
const Accumulator = @import("../raster/coverage.zig").Accumulator;
const TextLayout = @import("line.zig").TextLayout;
const cells = @import("cells.zig");
const box = @import("box_drawing.zig");
const Cell = cells.Cell;
const CellGlyph = cells.CellGlyph;
const CellGrid = cells.CellGrid;

const Fixture = struct {
    mono: TestFont,
    serif: TestFont,
    han: TestFont,
    reg: fonts.FontRegistry,
    fb: fonts.Fallback,
    tl: TextLayout,
    code: fonts.ChainId,
    serif_chain: fonts.ChainId,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fixture) !void {
        const gpa = testing.allocator;
        try f.mono.load(gpa, "JetBrainsMono[wght].ttf");
        errdefer f.mono.deinit(gpa);
        try f.serif.load(gpa, "SourceSerif4-Regular.otf");
        errdefer f.serif.deinit(gpa);
        try f.han.load(gpa, "SourceHanSansJP-Subset.otf");
        errdefer f.han.deinit(gpa);
        f.reg = fonts.FontRegistry.init(gpa);
        const mono = try f.reg.register(&f.mono.inst);
        const serif = try f.reg.register(&f.serif.inst);
        const han = try f.reg.register(&f.han.inst);
        f.fb = fonts.Fallback.init(gpa, &f.reg);
        f.code = try f.fb.chainOf(&.{ mono, han });
        f.serif_chain = try f.fb.chainOf(&.{ serif, han });
        f.tl = try TextLayout.init(gpa, &f.reg, &f.fb);
        f.arena = .init(gpa);
    }

    fn deinit(f: *Fixture) void {
        const gpa = testing.allocator;
        f.arena.deinit();
        f.tl.deinit();
        f.fb.deinit();
        f.reg.deinit();
        f.han.deinit(gpa);
        f.serif.deinit(gpa);
        f.mono.deinit(gpa);
    }

    fn grid(f: *Fixture, chain: fonts.ChainId, px: f32) CellGrid {
        return cells.cellMetrics(&f.tl, .{ .chain = chain, .size_px = px });
    }

    /// Cells for ASCII/UTF-8 `text`, one grapheme per cell, all width 1.
    fn row(f: *Fixture, text: []const u8, chain: fonts.ChainId) ![]Cell {
        var out: std.ArrayList(Cell) = .empty;
        var i: usize = 0;
        while (i < text.len) {
            const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            try out.append(f.arena.allocator(), .{ .text = text[i .. i + n], .style = .{ .chain = chain } });
            i += n;
        }
        return out.items;
    }

    fn layout(f: *Fixture, r: []const Cell, g: CellGrid, o: cells.CellOptions) ![]CellGlyph {
        var out: std.ArrayList(CellGlyph) = .empty;
        try cells.layoutCells(&f.tl, f.arena.allocator(), r, g, o, &out);
        return out.items;
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

test "cells: cell metrics jetbrains mono 13px" {
    const f = try setup();
    defer teardown(f);
    const g = f.grid(f.code, 13);
    // 600 / 1000 em × 13 px = 7.8 px, rounded up.
    try testing.expectEqual(@as(f32, 8), g.cell_w);
    try testing.expectEqual(@round(g.cell_h), g.cell_h);
    try testing.expectEqual(@round(g.baseline), g.baseline);
    try testing.expect(g.baseline > 0 and g.baseline < g.cell_h);
    try testing.expect(g.underline_h >= 1 and g.underline_y > g.baseline and g.underline_y < g.cell_h);
    try testing.expect(g.strike_y < g.baseline);
    // A proportional font takes its widest ASCII advance.
    const s = f.grid(f.serif_chain, 13);
    const w_adv = f.serif.inst.advance(f.serif.face.glyphIndex('W')) * 13 / 1000;
    try testing.expect(s.cell_w >= @ceil(w_adv));
}

/// Renders `cp` into a fresh w×h canvas.
const Render = struct {
    acc: Accumulator = .{},
    pixels: []u8 = &.{},

    fn draw(r: *Render, cp: u21, w: u32, h: u32) !box.Canvas {
        const gpa = testing.allocator;
        gpa.free(r.pixels);
        r.pixels = try gpa.alloc(u8, w * h);
        var c: box.Canvas = .{ .w = w, .h = h, .pixels = r.pixels };
        try testing.expect(try box.draw(cp, &c, &r.acc, gpa));
        return c;
    }

    fn deinit(r: *Render) void {
        r.acc.deinit(testing.allocator);
        testing.allocator.free(r.pixels);
    }
};

/// Covered positions along one edge (top row, bottom row, left column or
/// right column) as a bitset over the edge's length.
fn edge(c: box.Canvas, which: u2) u256 {
    var bits: u256 = 0;
    const n = if (which == 0 or which == 2) c.w else c.h;
    for (0..n) |k| {
        const v = switch (which) {
            0 => c.pixels[k], // top
            1 => c.pixels[k * c.w + c.w - 1], // right
            2 => c.pixels[(c.h - 1) * c.w + k], // bottom
            3 => c.pixels[k * c.w], // left
        };
        if (v > 127) bits |= @as(u256, 1) << @intCast(k);
    }
    return bits;
}

fn band(len: u32, start: i32, t: i32) u256 {
    _ = len;
    var bits: u256 = 0;
    var k = start;
    while (k < start + t) : (k += 1) bits |= @as(u256, 1) << @intCast(k);
    return bits;
}

test "cells: procedural box joins" {
    var r: Render = .{};
    defer r.deinit();
    for ([_][2]u32{ .{ 8, 16 }, .{ 9, 19 }, .{ 13, 27 } }) |size| {
        const w = size[0];
        const h = size[1];
        const light: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(h)) / 16))));
        var cp: u21 = 0x2500;
        while (cp <= 0x257F) : (cp += 1) {
            const code = boxCode(cp) orelse continue;
            const c = try r.draw(cp, w, h);
            // Up, right, down, left: edge k crosses the arm across the
            // cell's width (up, down) or height (left, right).
            for (0..4) |k| {
                const across = if (k % 2 == 0) w else h;
                const want: u256 = switch (code[k]) {
                    '0' => 0,
                    '1' => band(across, @divFloor(@as(i32, @intCast(across)) - light, 2), light),
                    '2' => band(across, @divFloor(@as(i32, @intCast(across)) - 2 * light, 2), 2 * light),
                    '3' => blk: {
                        const s0 = @divFloor(@as(i32, @intCast(across)) - 3 * light, 2);
                        break :blk band(across, s0, light) | band(across, s0 + 2 * light, light);
                    },
                    else => unreachable,
                };
                if (edge(c, @intCast(k)) != want) {
                    std.debug.print("U+{X} {d}x{d} edge {d}: got {b} want {b}\n", .{ cp, w, h, k, edge(c, @intCast(k)), want });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

fn boxCode(cp: u21) ?*const [4]u8 {
    const t = box_table_for_tests[cp - 0x2500];
    return if (t[0] == '-') null else t;
}

const box_table_for_tests = @import("box_drawing.zig").box_table_for_tests;

test "cells: block eighths exact rows" {
    var r: Render = .{};
    defer r.deinit();
    for ([_][2]u32{ .{ 8, 16 }, .{ 9, 19 }, .{ 13, 27 } }) |size| {
        const w = size[0];
        const h = size[1];
        for (1..9) |k| {
            const c = try r.draw(@intCast(0x2580 + k), w, h);
            var rows: u32 = 0;
            for (0..h) |y| {
                const full = std.mem.allEqual(u8, c.pixels[y * w ..][0..w], 255);
                const empty = std.mem.allEqual(u8, c.pixels[y * w ..][0..w], 0);
                try testing.expect(full or empty);
                if (full) rows += 1;
            }
            try testing.expectEqual(@as(u32, @intCast((h * k + 4) / 8)), rows);
            // Filled rows are at the bottom.
            try testing.expectEqual(@as(u8, 255), c.pixels[(h - 1) * w]);
        }
        // Shades are uniform.
        const shade = try r.draw(0x2592, w, h);
        try testing.expect(std.mem.allEqual(u8, shade.pixels, 128));
    }
}

test "cells: braille dots" {
    var r: Render = .{};
    defer r.deinit();
    const all = try r.draw(0x28FF, 8, 16);
    var lit: usize = 0;
    for (all.pixels) |p| lit += @intFromBool(p == 255);
    // Eight 2×2 dots at 8×16 (sub-cell 4×4).
    try testing.expectEqual(@as(usize, 8 * 4), lit);
    const one = try r.draw(0x2801, 8, 16);
    for (one.pixels, 0..) |p, k| if (p != 0) {
        try testing.expect(k % 8 < 4 and k / 8 < 4);
    };
    const eight = try r.draw(0x2880, 8, 16);
    for (eight.pixels, 0..) |p, k| if (p != 0) {
        try testing.expect(k % 8 >= 4 and k / 8 >= 12);
    };
}

test "cells: sextants and powerline" {
    var r: Render = .{};
    defer r.deinit();
    // Sextant-1 is the top-left sixth.
    const s1 = try r.draw(0x1FB00, 8, 15);
    try testing.expectEqual(@as(u8, 255), s1.pixels[0]);
    try testing.expectEqual(@as(u8, 0), s1.pixels[4]);
    try testing.expectEqual(@as(u8, 0), s1.pixels[5 * 8]);
    // The last one (sextant-23456) leaves only the top-left sixth empty.
    const last = try r.draw(0x1FB3B, 8, 15);
    try testing.expectEqual(@as(u8, 0), last.pixels[0]);
    try testing.expectEqual(@as(u8, 255), last.pixels[4]);
    // The right-pointing triangle fills the left edge and the right
    // middle.
    const tri = try r.draw(0xE0B0, 8, 16);
    try testing.expectEqual(@as(u8, 255), tri.pixels[8 * 8]);
    try testing.expect(tri.pixels[7 * 8 + 7] > 0 or tri.pixels[8 * 8 + 7] > 0);
    try testing.expectEqual(@as(u8, 0), tri.pixels[7]);
}

/// All procedural glyphs at one cell size tiled 32 to a row, as a PGM.
fn sheet(gpa: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    var r: Render = .{};
    defer r.deinit();
    const count = 480;
    const cols = 32;
    const rows = (count + cols - 1) / cols;
    const sw = cols * w;
    const sh = rows * h;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "P5\n# producer: zg_text src/layout/cells_test.zig sheet(), {d}x{d} cells, 32 per row in procedural id order\n{d} {d}\n255\n", .{ w, h, sw, sh });
    const hdr = out.items.len;
    try out.appendNTimes(gpa, 0, sw * sh);
    for (0..count) |i| {
        const cp = box.codepoint(@intCast(i)).?;
        const c = try r.draw(cp, w, h);
        const ox = (i % cols) * w;
        const oy = (i / cols) * h;
        for (0..h) |y| @memcpy(out.items[hdr + (oy + y) * sw + ox ..][0..w], c.pixels[y * w ..][0..w]);
    }
    return out.toOwnedSlice(gpa);
}

test "cells: procedural goldens" {
    const gpa = testing.allocator;
    for ([_][2]u32{ .{ 8, 16 }, .{ 9, 19 }, .{ 13, 27 } }) |size| {
        const got = try sheet(gpa, size[0], size[1]);
        defer gpa.free(got);
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "golden/cells/procedural_{d}x{d}.pgm", .{ size[0], size[1] });
        const want = testdata.readTestdata(gpa, name) catch |e| switch (e) {
            error.FileNotFound => {
                try writeGolden(name, got);
                std.debug.print("wrote missing golden {s}; rerun\n", .{name});
                return error.SkipZigTest;
            },
            else => return e,
        };
        defer gpa.free(want);
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("{s} differs; delete it to regenerate after a deliberate change\n", .{name});
            return error.TestExpectedEqual;
        }
    }
}

fn writeGolden(rel: []const u8, data: []const u8) !void {
    const io = testing.io;
    var root = try std.Io.Dir.openDirAbsolute(io, @import("zg_options").package_root, .{});
    defer root.close(io);
    var td = try root.openDir(io, "testdata", .{});
    defer td.close(io);
    try td.createDirPath(io, "golden/cells");
    try td.writeFile(io, .{ .sub_path = rel, .data = data });
}

test "cells: wide cjk scaled to fit" {
    const f = try setup();
    defer teardown(f);
    const g = f.grid(f.code, 13);
    // In two cells the 13 px ideograph fits and is centred.
    const wide = [_]Cell{ .{ .text = "\u{65E5}", .width = 2, .style = .{ .chain = f.code } }, .{ .text = "", .width = 0, .style = .{ .chain = f.code } } };
    const gw = try f.layout(&wide, g, .{});
    try testing.expectEqual(@as(usize, 1), gw.len);
    try testing.expectEqual(@as(f32, 1), gw[0].scale);
    try testing.expectEqual(@as(f32, 2), gw[0].x);
    try testing.expectEqual(f.han.face.glyphIndex(0x65E5), gw[0].key.glyph);
    // In one cell it is scaled down to the cell width.
    const narrow = [_]Cell{.{ .text = "\u{65E5}", .width = 1, .style = .{ .chain = f.code } }};
    const gn = try f.layout(&narrow, g, .{});
    try testing.expectApproxEqAbs(@as(f32, 8.0 / 13.0), gn[0].scale, 1e-4);
    try testing.expectEqual(glyph_key.quantizeSize(8), gn[0].key.size_q);
    try testing.expectEqual(@as(f32, 0), gn[0].x);
    // Never wider than its cells.
    try testing.expect(gn[0].scale * 13 <= g.cell_w + 0.01);
}

test "cells: ligature accepted only when advance matches" {
    const f = try setup();
    defer teardown(f);
    const g = f.grid(f.code, 13);
    const r = try f.row("a -> b != c", f.code);
    const plain = try f.layout(r, g, .{});
    const lig = try f.layout(r, g, .{ .ligatures = true });
    try testing.expectEqual(plain.len, lig.len);
    var differ: usize = 0;
    for (plain, lig) |p, l| {
        try testing.expectEqual(p.col, l.col);
        try testing.expectEqual(p.x, l.x);
        differ += @intFromBool(p.key.glyph != l.key.glyph);
    }
    try testing.expect(differ >= 4);
    // Source Serif's "ffi" ligature spans three cells but is narrower
    // than them: the cells keep their own glyphs.
    const sg = f.grid(f.serif_chain, 13);
    const sr = try f.row("office", f.serif_chain);
    const sl = try f.layout(sr, sg, .{ .ligatures = true });
    try testing.expectEqual(@as(usize, 6), sl.len);
    for (sl, "office") |gl, ch| try testing.expectEqual(f.serif.face.glyphIndex(ch), gl.key.glyph);
}

test "cells: style run grouping" {
    const f = try setup();
    defer teardown(f);
    const g = f.grid(f.code, 13);
    // A style change between '-' and '>' splits the run: no ligature.
    const r = [_]Cell{
        .{ .text = "-", .style = .{ .chain = f.code } },
        .{ .text = ">", .style = .{ .chain = f.code, .bold = true } },
    };
    const gl = try f.layout(&r, g, .{ .ligatures = true });
    try testing.expectEqual(@as(usize, 2), gl.len);
    try testing.expectEqual(f.mono.face.glyphIndex('-'), gl[0].key.glyph);
    try testing.expectEqual(f.mono.face.glyphIndex('>'), gl[1].key.glyph);
    // Blank cells, procedural cells and grid positions.
    const mixed = [_]Cell{
        .{ .text = "x", .style = .{ .chain = f.code } },
        .{ .text = "", .style = .{ .chain = f.code } },
        .{ .text = "\u{2500}", .style = .{ .chain = f.code } },
        .{ .text = "y", .style = .{ .chain = f.code } },
    };
    const gm = try f.layout(&mixed, g, .{});
    try testing.expectEqual(@as(usize, 3), gm.len);
    try testing.expect(gm[1].procedural);
    try testing.expectEqual(@as(u16, 2), gm[1].col);
    try testing.expectEqual(@as(f32, 16), gm[1].x);
    const p = cells.proceduralOf(gm[1].key).?;
    try testing.expectEqual(@as(u21, 0x2500), p.cp);
    try testing.expectEqual(@as(u32, 8), p.w);
    try testing.expectEqual(@as(u32, @intFromFloat(g.cell_h)), p.h);
    try testing.expectEqual(@as(f32, 24), gm[2].x);
}

test "cells: renderProcedural matches the grid" {
    const f = try setup();
    defer teardown(f);
    const g = f.grid(f.code, 13);
    var bm: @import("../raster/rasterizer.zig").Bitmap = .{};
    try cells.renderProcedural(0x253C, g, &bm, testing.allocator);
    defer testing.allocator.free(bm.pixels);
    try testing.expectEqual(@as(u16, 8), bm.width);
    try testing.expectEqual(@as(u16, @intFromFloat(g.cell_h)), bm.height);
    try testing.expectError(error.NotProcedural, cells.renderProcedural('a', g, &bm, testing.allocator));
}
