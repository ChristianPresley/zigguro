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
    "text.cells_row_200",
    "text.fontdb_load_3k",
    "text.hit_test",
    "text.itemize_200col",
    "text.layout_200col",
    "text.measure_hit",
    "text.registry_get",
    "text.wrap_10kb",
};

const font_names = [_][]const u8{
    "JetBrainsMono[wght].ttf",        "FiraCode-Regular.ttf",        "Inter[opsz,wght].ttf",
    "SourceSerif4-Regular.otf",       "SourceHanSansJP-Subset.otf",  "NotoSansArabic-Subset.ttf",
    "NotoColorEmoji-CBDT-Subset.ttf", "test_glyphs-glyf_colr_1.ttf",
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

    // HVAR advance at wght=700 with cached region scalars.
    const vt = zg_text.ot.variation;
    var bold = try vt.FaceInstance.init(b.gpa, &jb, &.{.{ .tag = zg_text.ot.tag("wght"), .value = 700 }});
    defer bold.deinit(b.gpa);
    try b.run("text.var_advance", AdvanceCtx{ .inst = &bold, .gids = &ascii_gids }, varAdvance);

    // One JetBrains Mono ASCII glyph outlined at wght=700 (glyf + gvar).
    try b.run("text.gvar_apply", VarOutlineCtx{ .inst = &bold, .gids = &ascii_gids, .gpa = b.gpa }, gvarOutline);

    // One Source Serif 4 (CFF) ASCII glyph per iteration.
    const serif = try zg_text.ot.Face.init(fonts.data[3], 0);
    var serif_inst = try vt.FaceInstance.init(b.gpa, &serif, &.{});
    defer serif_inst.deinit(b.gpa);
    var serif_gids: [94]u16 = undefined;
    for (&serif_gids, 0..) |*g, i| g.* = serif.glyphIndex(@intCast(0x21 + i));
    try b.run("text.cff_outline", VarOutlineCtx{ .inst = &serif_inst, .gids = &serif_gids, .gpa = b.gpa }, gvarOutline);

    // Outline + coverage raster of one JetBrains Mono ASCII glyph at 14 px.
    var rast: [4]zg_text.raster.Rasterizer = @splat(.init(b.gpa));
    defer for (&rast) |*r| r.deinit();
    var jb_inst = try vt.FaceInstance.init(b.gpa, &jb, &.{});
    defer jb_inst.deinit(b.gpa);
    try b.run("text.raster_14px", RasterCtx{ .inst = &jb_inst, .gids = &ascii_gids, .r = &rast[0], .px = 14 }, rasterGlyph);

    // LCD (3× raster plus FIR filter) of the same glyphs.
    try b.run("text.raster_lcd_14px", RasterCtx{ .inst = &jb_inst, .gids = &ascii_gids, .r = &rast[1], .px = 14, .mode = .lcd_rgb }, rasterGlyph);

    // SDF at the 48 px base with a 4 px spread.
    try b.run("text.sdf_48px", RasterCtx{ .inst = &jb_inst, .gids = &ascii_gids, .r = &rast[2], .px = 48, .mode = .sdf }, rasterGlyph);

    // The same for Source Han Sans JP (CFF, CJK) at 64 px.
    const han = try zg_text.ot.Face.init(fonts.data[4], 0);
    var han_inst = try vt.FaceInstance.init(b.gpa, &han, &.{});
    defer han_inst.deinit(b.gpa);
    var han_gids: [12]u16 = undefined;
    for (&han_gids, han_cps) |*g, c| g.* = han.glyphIndex(c);
    try b.run("text.raster_64px_cjk", RasterCtx{ .inst = &han_inst, .gids = &han_gids, .r = &rast[3], .px = 64 }, rasterGlyph);

    // CBDT emoji at 32 px: cached strike (resample only), then with the
    // PNG decoded every time.
    const emoji = try zg_text.ot.Face.init(fonts.data[6], 0);
    var emoji_inst = try vt.FaceInstance.init(b.gpa, &emoji, &.{});
    defer emoji_inst.deinit(b.gpa);
    var emoji_gids: [5]u16 = undefined;
    for (&emoji_gids, [_]u21{ 0x1F600, 0x2764, 0x1F44D, 0x1F389, 0x1F525 }) |*g, c| g.* = emoji.glyphIndex(c);
    var emoji_r: [2]zg_text.raster.Rasterizer = @splat(.init(b.gpa));
    defer for (&emoji_r) |*r| r.deinit();
    try b.run("text.cbdt_32px_cached", StrikeCtx{ .inst = &emoji_inst, .gids = &emoji_gids, .r = &emoji_r[0], .decode = false }, strikeGlyph);
    try b.run("text.cbdt_32px_decode", StrikeCtx{ .inst = &emoji_inst, .gids = &emoji_gids, .r = &emoji_r[1], .decode = true }, strikeGlyph);

    // COLRv1 at 32 px: every paint format of the googlefonts test glyphs,
    // rendered through rasterizeGlyph (no cache in between).
    const colr_face = try zg_text.ot.Face.init(fonts.data[7], 0);
    var colr_inst = try vt.FaceInstance.init(b.gpa, &colr_face, &.{});
    defer colr_inst.deinit(b.gpa);
    const colr = zg_text.ot.colr.Colr.fromFace(&colr_face).?;
    var colr_gids: std.ArrayList(u16) = .empty;
    defer colr_gids.deinit(b.gpa);
    for (0..colr_face.num_glyphs) |g| if (colr.v1Paint(@intCast(g)) != null) try colr_gids.append(b.gpa, @intCast(g));
    var colr_r: zg_text.raster.Rasterizer = .init(b.gpa);
    defer colr_r.deinit();
    try b.run("text.colr_32px", ColrCtx{ .inst = &colr_inst, .gids = colr_gids.items, .r = &colr_r }, colrGlyph);

    // Atlas inserts of glyph-sized bitmaps (3–22 × 4–28 px), with page
    // eviction once the four default gray pages fill.
    var atlas = try zg_text.cache.Atlas.init(b.gpa, .{});
    defer atlas.deinit();
    const glyph_px = try b.gpa.alloc(u8, 22 * 28);
    defer b.gpa.free(glyph_px);
    @memset(glyph_px, 0x80);
    var sizes: [1024][2]u16 = undefined;
    var prng = std.Random.DefaultPrng.init(1);
    for (&sizes) |*sz| sz.* = .{ prng.random().intRangeAtMost(u16, 3, 22), prng.random().intRangeAtMost(u16, 4, 28) };
    var inserted: u64 = 0;
    try b.run("text.atlas_insert", AtlasCtx{ .atlas = &atlas, .px = glyph_px, .sizes = &sizes, .n = &inserted }, atlasInsert);

    // Prefix-sum integration of a 256×256 accumulator; bytes/s = pixels/s.
    try b.run("text.integrate_gpix", b.gpa, integrate);

    // Glyph cache hits: random lookups over 20k resident keys, and one
    // 200×60 screen of lookups over the ~100 distinct glyphs it shows.
    var rt: zg_core.runtime.Runtime = undefined;
    try rt.initBorrowed(b.gpa, b.io, 64);
    defer _ = rt.deinit();
    var cache_atlas = try zg_text.cache.Atlas.init(b.gpa, .{ .page_size = 64 });
    defer cache_atlas.deinit();
    var one: [4]u8 = @splat(255);
    const one_bm: zg_text.raster.Bitmap = .{ .width = 2, .height = 2, .stride = 2, .pixels = &one };
    const page_entry = try cache_atlas.insert(&one_bm, 1);
    var cache: zg_text.cache.GlyphCache = undefined;
    try cache.init(b.gpa, &rt, &cache_atlas, .{ .workers = 0 });
    defer cache.deinit();
    const resident = try b.gpa.alloc(zg_text.cache.GlyphKey, 20_000);
    defer b.gpa.free(resident);
    var cache_prng = std.Random.DefaultPrng.init(0xcac4e);
    for (resident, 0..) |*k, i| {
        k.* = .{ .instance = @intCast(i % 7), .glyph = @intCast(i / 7), .size_q = 56 + @as(u13, @intCast(i % 3)) * 4 };
        try cache.put(k.*, page_entry);
    }
    const order = try b.gpa.alloc(u32, 1 << 16);
    defer b.gpa.free(order);
    for (order) |*o| o.* = cache_prng.random().uintLessThan(u32, @intCast(resident.len));
    var frame: u32 = 2;
    try b.run("text.cache_hit", CacheCtx{ .cache = &cache, .keys = resident, .order = order, .frame = &frame }, cacheHit);
    var screen: [200 * 60]u32 = undefined;
    for (&screen) |*o| o.* = cache_prng.random().uintLessThan(u32, 100);
    try b.run("text.cache_screen", CacheCtx{ .cache = &cache, .keys = resident, .order = &screen, .frame = &frame }, cacheScreen);

    // Shaping with a warm shaper (plans built, buffers grown): 1000
    // characters of Latin prose in Inter (GPOS kerning, marks), one
    // 200-column code line in JetBrains Mono (calt ligatures), and 1000
    // characters of Arabic.
    const inter = try zg_text.ot.Face.init(fonts.data[2], 0);
    var inter_inst = try vt.FaceInstance.init(b.gpa, &inter, &.{});
    defer inter_inst.deinit(b.gpa);
    var shaper = zg_text.shape.Shaper.init(b.gpa);
    defer shaper.deinit();
    var prose: [1000]u8 = undefined;
    fill(&prose, &.{ "The quick brown fox jumps over the lazy dog. ", "AVATAR Wave To office caf\u{E9}, ", "na\u{EF}ve r\u{E9}sum\u{E9} 1234; " });
    const dflt = zg_text.ot.tag("dflt");
    const prose_plan = try shaper.plan(&inter_inst, .Latn, dflt, .ltr, &.{});
    try b.run("text.shape_latin_1k", ShapeCtx{ .shaper = &shaper, .plan = prose_plan, .text = &prose }, shapeText);
    var code: [200]u8 = undefined;
    fill(&code, &.{ "if (a != b && c => d) { x = y->z; } ", "// TODO: <!-- www --> 0xFF ", "for (i = 0; i <= n; i++) ||| " });
    const code_plan = try shaper.plan(&jb_inst, .Latn, dflt, .ltr, &.{});
    try b.run("text.shape_code_line_200", ShapeCtx{ .shaper = &shaper, .plan = code_plan, .text = &code }, shapeText);
    // 1000 characters of Arabic (joining forms, lam-alef, marks) in Noto
    // Sans Arabic; the text is about 1000 code points of two bytes each.
    const naskh = try zg_text.ot.Face.init(fonts.data[5], 0);
    var naskh_inst = try vt.FaceInstance.init(b.gpa, &naskh, &.{});
    defer naskh_inst.deinit(b.gpa);
    var arabic_text: [2000]u8 = undefined;
    fill(&arabic_text, &.{ "\u{628}\u{633}\u{645} \u{627}\u{644}\u{644}\u{647} \u{627}\u{644}\u{631}\u{62D}\u{645}\u{646} ", "\u{645}\u{64E}\u{631}\u{652}\u{62D}\u{64E}\u{628}\u{64B}\u{627} \u{644}\u{627} ", "\u{6A9}\u{62A}\u{627}\u{628} \u{6AF}\u{686}\u{6CC} " });
    const arabic_plan = try shaper.plan(&naskh_inst, .Arab, dflt, .rtl, &.{});
    try b.run("text.shape_arabic_1k", ShapeCtx{ .shaper = &shaper, .plan = arabic_plan, .text = &arabic_text }, shapeText);

    // Word-cache hits: one cached word per iteration (Inter without `calt`
    // and `kern`, whose lookups would make spaces participate).
    const no_ctx = [_]zg_text.shape.Feature{ .{ .tag = zg_text.ot.tag("calt"), .value = 0 }, .{ .tag = zg_text.ot.tag("kern"), .value = 0 } };
    var shape_cache = try zg_text.shape.ShapeCache.init(b.gpa, .{});
    defer shape_cache.deinit();
    const words = [_][]const u8{ "office ", "Wave ", "the ", "quick ", "brown ", "r\u{E9}sum\u{E9} ", "jumps ", "AVATAR " };
    var arena_buf: [64 << 10]u8 = undefined;
    var word_ctx: WordCtx = .{ .shaper = &shaper, .cache = &shape_cache, .inst = &inter_inst, .features = &no_ctx, .words = &words, .arena = &arena_buf };
    for (words) |w| word_ctx.one(w); // fill the cache
    try b.run("text.shape_word_cache_hit", &word_ctx, shapeWordHit);
}

const ShapeCtx = struct { shaper: *zg_text.shape.Shaper, plan: *const zg_text.shape.ShapePlan, text: []const u8 };

fn shapeText(ctx: ShapeCtx, s: *State) void {
    for (0..s.iterations()) |_| {
        ctx.shaper.shapeWithPlan(ctx.plan, ctx.text) catch unreachable;
        bench.doNotOptimizeAway(ctx.shaper.buf.pos.items.len);
    }
    s.setBytes(ctx.text.len);
}

const WordCtx = struct {
    shaper: *zg_text.shape.Shaper,
    cache: *zg_text.shape.ShapeCache,
    inst: *const zg_text.ot.variation.FaceInstance,
    features: []const zg_text.shape.Feature,
    words: []const []const u8,
    arena: []u8,

    fn one(ctx: *WordCtx, word: []const u8) void {
        var fba = std.heap.FixedBufferAllocator.init(ctx.arena);
        var run: zg_text.shape.GlyphRun = .{};
        zg_text.shape.shape_cache.shapeCached(ctx.shaper, ctx.cache, ctx.inst, 1, 1, word, .Latn, .ltr, zg_text.ot.tag("dflt"), ctx.features, &run, fba.allocator()) catch unreachable;
        bench.doNotOptimizeAway(run.gids.len);
    }
};

fn shapeWordHit(ctx: *WordCtx, s: *State) void {
    var k: usize = 0;
    for (0..s.iterations()) |_| {
        ctx.one(ctx.words[k]);
        k = (k + 1) % ctx.words.len;
    }
}

const han_cps = [12]u21{ '語', '漢', '字', '日', '本', 'あ', 'い', 'う', 'え', 'お', 'か', 'き' };

const RasterCtx = struct {
    inst: *const zg_text.ot.variation.FaceInstance,
    gids: []const u16,
    /// One rasterizer per bench, warmed by its first call.
    r: *zg_text.raster.Rasterizer,
    px: f32,
    mode: zg_text.raster.RasterParams.Mode = .gray,
};

fn rasterGlyph(ctx: RasterCtx, s: *State) void {
    // Warm once per bench, outside the timed calls: the buffers grow to
    // the largest glyph and stay.
    const r = ctx.r;
    if (r.out.capacity == 0) {
        for (ctx.gids) |gid| _ = r.rasterizeGlyph(ctx.inst, gid, .{ .px_per_em = ctx.px, .mode = ctx.mode }) catch unreachable;
    }
    var k: usize = 0;
    for (0..s.iterations()) |_| {
        const bm = r.rasterizeGlyph(ctx.inst, ctx.gids[k], .{ .px_per_em = ctx.px, .mode = ctx.mode }) catch unreachable;
        bench.doNotOptimizeAway(bm.pixels.len);
        k += 1;
        if (k == ctx.gids.len) k = 0;
    }
}

const StrikeCtx = struct { inst: *const zg_text.ot.variation.FaceInstance, gids: []const u16, r: *zg_text.raster.Rasterizer, decode: bool };

fn strikeGlyph(ctx: StrikeCtx, s: *State) void {
    var k: usize = 0;
    for (0..s.iterations()) |_| {
        if (ctx.decode) ctx.r.strikes.budget_bytes = 0; // every lookup decodes
        const bm = ctx.r.rasterizeGlyph(ctx.inst, ctx.gids[k], .{ .px_per_em = 32, .color = true }) catch unreachable;
        bench.doNotOptimizeAway(bm.pixels.len);
        k += 1;
        if (k == ctx.gids.len) k = 0;
    }
}

const ColrCtx = struct { inst: *const zg_text.ot.variation.FaceInstance, gids: []const u16, r: *zg_text.raster.Rasterizer };

fn colrGlyph(ctx: ColrCtx, s: *State) void {
    var k: usize = 0;
    for (0..s.iterations()) |_| {
        const bm = ctx.r.rasterizeGlyph(ctx.inst, ctx.gids[k], .{ .px_per_em = 32, .color = true }) catch unreachable;
        bench.doNotOptimizeAway(bm.pixels.len);
        k += 1;
        if (k == ctx.gids.len) k = 0;
    }
}

const AtlasCtx = struct { atlas: *zg_text.cache.Atlas, px: []u8, sizes: []const [2]u16, n: *u64 };

fn atlasInsert(ctx: AtlasCtx, s: *State) void {
    // Frames advance across runs: the atlas keeps its pages between them.
    for (0..s.iterations()) |_| {
        const i = ctx.n.*;
        ctx.n.* += 1;
        const sz = ctx.sizes[i % ctx.sizes.len];
        const frame: u32 = @intCast(1 + i / 256);
        const bmp: zg_text.raster.Bitmap = .{ .width = sz[0], .height = sz[1], .stride = sz[0], .pixels = ctx.px[0 .. @as(usize, sz[0]) * sz[1]] };
        const e = ctx.atlas.insert(&bmp, frame) catch unreachable;
        bench.doNotOptimizeAway(e.x);
    }
}

const CacheCtx = struct { cache: *zg_text.cache.GlyphCache, keys: []const zg_text.cache.GlyphKey, order: []const u32, frame: *u32 };

fn cacheHit(ctx: CacheCtx, s: *State) void {
    // A new frame every 4096 lookups, so LRU stamping is exercised too.
    for (0..s.iterations()) |i| {
        if (i & 4095 == 0) {
            ctx.frame.* += 1;
            ctx.cache.beginFrame(ctx.frame.*);
        }
        const k = ctx.keys[ctx.order[i & (ctx.order.len - 1)]];
        bench.doNotOptimizeAway(ctx.cache.lookup(k));
    }
}

fn cacheScreen(ctx: CacheCtx, s: *State) void {
    // One iteration is one frame: every cell of a 200×60 screen.
    for (0..s.iterations()) |_| {
        ctx.frame.* += 1;
        ctx.cache.beginFrame(ctx.frame.*);
        for (ctx.order) |o| bench.doNotOptimizeAway(ctx.cache.lookup(ctx.keys[o]));
    }
}

fn integrate(gpa: std.mem.Allocator, s: *State) void {
    const n = 256;
    var acc: zg_text.raster.coverage.Accumulator = .{};
    defer acc.deinit(gpa);
    acc.reset(gpa, n, n) catch unreachable;
    // A ring per row keeps every row's deltas balanced.
    for (0..n) |y| {
        const row = acc.buf[y * acc.stride ..];
        row[3] = 0.6;
        row[4] = 0.4;
        row[200] = -0.6;
        row[201] = -0.4;
    }
    const out = gpa.alloc(u8, n * n) catch unreachable;
    defer gpa.free(out);
    for (0..s.iterations()) |_| {
        acc.integrate(out, n);
        bench.doNotOptimizeAway(out[n * n - 1]);
    }
    s.setBytes(n * n);
}

const VarOutlineCtx = struct { inst: *const zg_text.ot.variation.FaceInstance, gids: []const u16, gpa: std.mem.Allocator };

fn gvarOutline(ctx: VarOutlineCtx, s: *State) void {
    var scratch: zg_text.ot.variation.OutlineScratch = .{};
    defer scratch.deinit(ctx.gpa);
    var path: zg_text.outline.Path = .{};
    defer path.deinit(ctx.gpa);
    for (ctx.gids) |gid| ctx.inst.outline(ctx.gpa, gid, &scratch, &path) catch unreachable;
    var k: usize = 0;
    for (0..s.iterations()) |_| {
        path.reset();
        ctx.inst.outline(ctx.gpa, ctx.gids[k], &scratch, &path) catch unreachable;
        bench.doNotOptimizeAway(path.points.items.len);
        k += 1;
        if (k == ctx.gids.len) k = 0;
    }
}

const AdvanceCtx = struct { inst: *const zg_text.ot.variation.FaceInstance, gids: []const u16 };

fn varAdvance(ctx: AdvanceCtx, s: *State) void {
    var k: usize = 0;
    for (0..s.iterations()) |_| {
        bench.doNotOptimizeAway(ctx.inst.advance(ctx.gids[k]));
        k += 1;
        if (k == ctx.gids.len) k = 0;
    }
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
