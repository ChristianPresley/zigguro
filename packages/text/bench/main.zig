//! zg_text benchmarks (`zig build bench`). Every bench name used by the E03
//! budgets is listed in `pending` until its task replaces the placeholder
//! with a real body; pending names are reported as skipped so E14's gate can
//! tell missing from failing.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_text = @import("zg_text");
const bench = zg_core.bench;
const State = bench.State;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

/// Budgeted bench names that have no body yet.
pub const pending = [_][]const u8{
    "text.atlas_insert",    "text.cache_hit",
    "text.cache_screen",    "text.cells_row_200",
    "text.cff_outline",     "text.fontdb_load_3k",
    "text.gamma",           "text.gvar_apply",
    "text.hit_test",        "text.integrate_gpix",
    "text.itemize_200col",  "text.layout_200col",
    "text.lcd",             "text.measure_hit",
    "text.raster_14px",     "text.raster_64px_cjk",
    "text.raster_lcd_14px", "text.registry_get",
    "text.sdf_48px",        "text.shape_code_line_200",
    "text.shape_latin_1k",  "text.shape_word_cache_hit",
    "text.var_advance",     "text.wrap_10kb",
};

const font_names = [_][]const u8{
    "JetBrainsMono[wght].ttf",  "FiraCode-Regular.ttf",       "Inter[opsz,wght].ttf",
    "SourceSerif4-Regular.otf", "SourceHanSansJP-Subset.otf", "NotoSansArabic-Subset.ttf",
};

const Fonts = struct { data: [font_names.len][]u8 };

fn loadFonts(gpa: std.mem.Allocator, io: std.Io) !Fonts {
    var dir = try std.Io.Dir.openDirAbsolute(io, zg_text.dev.package_root, .{});
    defer dir.close(io);
    var out: Fonts = undefined;
    for (font_names, 0..) |n, i| {
        var buf: [128]u8 = undefined;
        out.data[i] = try dir.readFileAlloc(io, try std.fmt.bufPrint(&buf, "testdata/fonts/{s}", .{n}), gpa, .limited(32 << 20));
    }
    return out;
}

fn register(b: *bench.Bench) !void {
    for (pending) |name| if (b.opts.filter == null or std.mem.indexOf(u8, name, b.opts.filter.?) != null)
        std.debug.print("{s:<40} skipped (not implemented yet)\n", .{name});

    const fonts = try loadFonts(b.gpa, b.io);
    defer for (fonts.data) |d| b.gpa.free(d);

    try b.run("text.face_open", &fonts, faceOpen);

    // 4096 code points: 3/4 BMP (Latin, CJK), 1/4 astral; mapped or not.
    const jb = try zg_text.ot.Face.init(fonts.data[0], 0);
    var cps: [4096]u21 = undefined;
    var rng: std.Random.DefaultPrng = .init(42);
    for (&cps) |*c| c.* = switch (rng.random().uintLessThan(u8, 4)) {
        0 => rng.random().intRangeAtMost(u21, 0x20, 0x7E),
        1 => rng.random().intRangeAtMost(u21, 0x100, 0x2FFF),
        2 => rng.random().intRangeAtMost(u21, 0x4E00, 0x9FFF),
        else => rng.random().intRangeAtMost(u21, 0x10000, 0x1FFFF),
    };
    var pc: zg_text.ot.cmap.BmpPageCache = .init(b.gpa);
    defer pc.deinit();
    var cached = jb;
    cached.attachPageCache(&pc);
    for (cps) |c| _ = cached.glyphIndex(c); // warm the pages
    try b.run("text.cmap_lookup", CmapCtx{ .face = &cached, .cps = &cps }, cmapLookup);

    // Unicode property lookups over the same mixed code points.
    try b.run("text.props_lookup", &cps, propsLookup);

    // Segmentation over 1 MiB of ASCII source code and of mixed text.
    const ascii = try b.gpa.alloc(u8, 1 << 20);
    defer b.gpa.free(ascii);
    fill(ascii, &.{ "fn main() void {\n", "    const x = foo(bar, 42);\n", "    // comment here\n", "}\n" });
    const mixed = try b.gpa.alloc(u8, 1 << 20);
    defer b.gpa.free(mixed);
    fill(mixed, &.{ "Hello wörld, ", "日本語のテキスト ", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} ", "مرحبا بالعالم ", "क्षत्रिय ", "can't 3.14\n" });
    try b.run("text.grapheme_ascii", @as([]const u8, ascii), graphemeCount);
    try b.run("text.grapheme_mixed", @as([]const u8, mixed), graphemeCount);
    try b.run("text.word_mixed", @as([]const u8, mixed), wordCount);
    try b.run("text.linebreak_mixed", @as([]const u8, mixed), lineBreakCount);

    // Case folding over 1 MiB of ASCII source.
    try b.run("text.casefold_ascii", FoldCtx{ .text = ascii, .gpa = b.gpa }, foldAscii);
    // NFC: quick check over already-NFC mixed text, and the full algorithm
    // over text that needs composition.
    try b.run("text.nfc_quickcheck", @as([]const u8, mixed), nfcQuick);
    const decomposed = try zg_text.unicode.normalize.normalize(b.gpa, mixed[0 .. 64 * 1024], .nfd);
    defer b.gpa.free(decomposed);
    try b.run("text.nfc_slow_mixed", FoldCtx{ .text = decomposed, .gpa = b.gpa }, nfcSlow);

    // Cell width of a 200-column mixed row, per grapheme.
    var row: [400]u8 = undefined;
    fill(&row, &.{ "ls -la ", "\u{4E2D}\u{6587} ", "\u{1F44D}\u{1F3FD} ", "caf\u{E9} ", "\u{1F1FA}\u{1F1F8} " });
    try b.run("text.width_row_200", @as([]const u8, &row), widthRow);

    // Bidi on one 200-column line: the LTR early-out and a full RTL line.
    var ltr_line: [200]u8 = undefined;
    fill(&ltr_line, &.{ "const total = items.len * 2; ", "// sum the widths\n" });
    try b.run("text.bidi_200col_ltr", @as([]const u8, &ltr_line), bidiLtr);
    var rtl_line: [400]u8 = undefined;
    fill(&rtl_line, &.{ "\u{05E9}\u{05DC}\u{05D5}\u{05DD} ", "(\u{05D0} 12) ", "abc ", "\u{0627}\u{0644}\u{0639}\u{0627}\u{0644}\u{0645} " });
    try b.run("text.bidi_200col_rtl", @as([]const u8, &rtl_line), bidiRtl);

    // One JetBrains Mono ASCII glyph per iteration, with warm buffers.
    var ascii_gids: [94]u16 = undefined;
    for (&ascii_gids, 0..) |*g, i| g.* = jb.glyphIndex(@intCast(0x21 + i));
    try b.run("text.glyf_outline", OutlineCtx{ .face = &jb, .gids = &ascii_gids, .gpa = b.gpa }, glyfOutline);
}

const OutlineCtx = struct { face: *const zg_text.ot.Face, gids: []const u16, gpa: std.mem.Allocator };

fn glyfOutline(ctx: OutlineCtx, s: *State) void {
    const g = ctx.face.glyf().?;
    var scratch: zg_text.ot.glyf.Scratch = .{};
    defer scratch.deinit(ctx.gpa);
    var path: zg_text.outline.Path = .{};
    defer path.deinit(ctx.gpa);
    for (ctx.gids) |gid| _ = g.outline(ctx.gpa, gid, &scratch, null, &path) catch unreachable;
    var k: usize = 0;
    for (0..s.iterations()) |_| {
        path.reset();
        _ = g.outline(ctx.gpa, ctx.gids[k], &scratch, null, &path) catch unreachable;
        bench.doNotOptimizeAway(path.points.items.len);
        k += 1;
        if (k == ctx.gids.len) k = 0;
    }
}

fn fill(buf: []u8, pieces: []const []const u8) void {
    var n: usize = 0;
    var k: usize = 0;
    while (n < buf.len) : (k += 1) {
        const p = pieces[k % pieces.len];
        if (n + p.len > buf.len) {
            @memset(buf[n..], ' ');
            break;
        }
        @memcpy(buf[n..][0..p.len], p);
        n += p.len;
    }
}

fn graphemeCount(text: []const u8, s: *State) void {
    s.setBytes(text.len);
    for (0..s.iterations()) |_| bench.doNotOptimizeAway(zg_text.unicode.grapheme.count(text));
}

fn wordCount(text: []const u8, s: *State) void {
    s.setBytes(text.len);
    for (0..s.iterations()) |_| {
        var it = zg_text.unicode.word.WordIterator.init(text);
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        bench.doNotOptimizeAway(n);
    }
}

fn lineBreakCount(text: []const u8, s: *State) void {
    s.setBytes(text.len);
    for (0..s.iterations()) |_| {
        var it = zg_text.unicode.line_break.Iterator.init(text, .{});
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        bench.doNotOptimizeAway(n);
    }
}

const FoldCtx = struct { text: []const u8, gpa: std.mem.Allocator };

fn foldAscii(ctx: FoldCtx, s: *State) void {
    s.setBytes(ctx.text.len);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.gpa);
    out.ensureTotalCapacity(ctx.gpa, ctx.text.len) catch unreachable;
    for (0..s.iterations()) |_| {
        out.clearRetainingCapacity();
        zg_text.unicode.casefold.foldAppend(&out, ctx.gpa, ctx.text, .full) catch unreachable;
        bench.doNotOptimizeAway(out.items.len);
    }
}

fn nfcQuick(text: []const u8, s: *State) void {
    s.setBytes(text.len);
    for (0..s.iterations()) |_| bench.doNotOptimizeAway(zg_text.unicode.normalize.isNormalizedQuick(text, .nfc));
}

fn nfcSlow(ctx: FoldCtx, s: *State) void {
    s.setBytes(ctx.text.len);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.gpa);
    for (0..s.iterations()) |_| {
        out.clearRetainingCapacity();
        zg_text.unicode.normalize.normalizeAppend(&out, ctx.gpa, ctx.text, .nfc) catch unreachable;
        bench.doNotOptimizeAway(out.items.len);
    }
}

fn widthRow(row: []const u8, s: *State) void {
    for (0..s.iterations()) |_| bench.doNotOptimizeAway(zg_text.unicode.width.stringWidth(row, .{}, .grapheme));
}

fn bidiLtr(line: []const u8, s: *State) void {
    for (0..s.iterations()) |_| bench.doNotOptimizeAway(zg_text.unicode.bidi.hasRtl(line));
}

fn bidiRtl(line: []const u8, s: *State) void {
    // A frame-style arena: one fixed buffer reset per line.
    var mem: [32 * 1024]u8 = undefined;
    for (0..s.iterations()) |_| {
        var fba: std.heap.FixedBufferAllocator = .init(&mem);
        const a = fba.allocator();
        var para = zg_text.unicode.bidi.resolve(a, line, .rtl) catch unreachable;
        var runs: std.ArrayList(zg_text.unicode.bidi.VisualRun) = .empty;
        para.reorderLine(a, 0, @intCast(para.levels.len), &runs) catch unreachable;
        bench.doNotOptimizeAway(runs.items.len);
    }
}

fn propsLookup(cps: *const [4096]u21, s: *State) void {
    var acc: u64 = 0;
    for (0..s.iterations()) |i| acc +%= @as(u64, @bitCast(zg_text.unicode.props(cps[i & 4095])));
    bench.doNotOptimizeAway(acc);
}

fn faceOpen(fonts: *const Fonts, s: *State) void {
    for (0..s.iterations()) |i| {
        const f = zg_text.ot.Face.init(fonts.data[i % fonts.data.len], 0) catch unreachable;
        bench.doNotOptimizeAway(f.num_glyphs);
    }
}

const CmapCtx = struct { face: *const zg_text.ot.Face, cps: *const [4096]u21 };

fn cmapLookup(ctx: CmapCtx, s: *State) void {
    var acc: u32 = 0;
    for (0..s.iterations()) |i| acc +%= ctx.face.glyphIndex(ctx.cps[i & 4095]);
    bench.doNotOptimizeAway(acc);
}
