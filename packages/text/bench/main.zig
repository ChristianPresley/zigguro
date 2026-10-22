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
    "text.atlas_insert",         "text.bidi_200col_ltr", "text.bidi_200col_rtl",     "text.cache_hit",
    "text.cache_screen",         "text.casefold_ascii",  "text.cells_row_200",       "text.cff_outline",
    "text.fontdb_load_3k",       "text.gamma",           "text.glyf_outline",        "text.gvar_apply",
    "text.hit_test",             "text.integrate_gpix",  "text.itemize_200col",      "text.layout_200col",
    "text.lcd",                  "text.linebreak_mixed", "text.measure_hit",         "text.nfc_quickcheck",
    "text.nfc_slow_mixed",       "text.raster_14px",     "text.raster_64px_cjk",     "text.raster_lcd_14px",
    "text.registry_get",         "text.sdf_48px",        "text.shape_code_line_200", "text.shape_latin_1k",
    "text.shape_word_cache_hit", "text.var_advance",     "text.width_row_200",       "text.wrap_10kb",
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
