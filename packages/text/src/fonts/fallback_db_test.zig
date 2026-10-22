//! Database-backed fallback over a database of the test fonts only
//! (deterministic, never the system's), the last-resort glyph, and
//! layout of text nothing maps.

const std = @import("std");
const testing = std.testing;
const options = @import("zg_options");
const db_mod = @import("db.zig");
const discovery = @import("discovery.zig");
const registry = @import("registry.zig");
const fallback = @import("fallback.zig");
const matcher = @import("matcher.zig");
const last_resort = @import("last_resort.zig");
const decode = @import("../unicode/decode.zig");
const layout = @import("../layout/root.zig");
const testdata = @import("../testing/fonts.zig");

const InstanceId = registry.InstanceId;

const Fixture = struct {
    list: std.ArrayList(discovery.FileEntry) = .empty,
    db: db_mod.FontDb,
    reg: registry.FontRegistry,
    fb: fallback.Fallback,

    fn init(f: *Fixture, defaults: fallback.OsDefaults, generics: matcher.Generics) !void {
        const gpa = testing.allocator;
        const dir = try std.fs.path.join(gpa, &.{ options.package_root, "testdata", "fonts" });
        defer gpa.free(dir);
        f.list = .empty;
        try discovery.listFontFiles(gpa, testing.io, &.{dir}, &f.list);
        var stats: db_mod.ScanStats = .{};
        f.db = try db_mod.FontDb.empty.rescan(gpa, testing.io, f.list.items, &stats);
        f.reg = .init(gpa);
        f.fb = .init(gpa, &f.reg);
        try f.fb.attachDb(&f.reg, testing.io, &f.db, generics, defaults);
    }

    fn deinit(f: *Fixture) void {
        f.fb.deinit();
        f.reg.deinit();
        f.db.deinit(testing.allocator);
        discovery.freeFileEntries(testing.allocator, &f.list);
    }

    /// The file name of the face behind instance `id`.
    fn fileOf(f: *Fixture, id: InstanceId) []const u8 {
        for (f.reg.keyed.items) |o| if (o.id == id) return std.fs.path.basename(o.path);
        return "?";
    }

    /// True when instance `id` maps every code point of `s`.
    fn maps(f: *Fixture, id: InstanceId, s: []const u8) bool {
        const face = f.reg.get(id).inst.face;
        var i: usize = 0;
        while (i < s.len) {
            const u = decode.at(s, i);
            i += u.len;
            if (u.cp == 0xFE0F or u.cp == 0x200D) continue;
            if (face.glyphIndex(u.cp) == 0) return false;
        }
        return true;
    }
};

const emoji_generics: matcher.Generics = blk: {
    var g: matcher.Generics = .{};
    g.lists.set(.emoji, &.{"Noto Color Emoji"});
    break :blk g;
};

test "latin primary covers" {
    var f: Fixture = undefined;
    try f.init(.{}, .{});
    defer f.deinit();
    const c = try f.fb.chain(&.{ "Not Installed", "JetBrains Mono" }, .{});
    try testing.expectEqual(c, try f.fb.chain(&.{"JetBrains Mono"}, .{}));
    const p = f.fb.primary(c);
    try testing.expectEqualStrings("JetBrainsMono[wght].ttf", f.fileOf(p));
    try testing.expectEqual(p, f.fb.resolve(c, "a", .default));
    try testing.expectEqual(p, f.fb.resolve(c, "e\u{301}", .default));
    try testing.expectEqual(@as(u64, 0), f.fb.stats().search);
    // A bold chain is another chain with a variable instance at 700.
    const b = try f.fb.chain(&.{"JetBrains Mono"}, .{ .weight = 700 });
    try testing.expect(b != c and f.fb.primary(b) != p);
    try testing.expect(!f.reg.get(f.fb.primary(b)).synth.bold);
    try testing.expectError(error.NoFonts, blk: {
        var empty: db_mod.FontDb = .empty;
        f.fb.setDb(&empty);
        defer f.fb.setDb(&f.db);
        break :blk f.fb.chain(&.{"Nope"}, .{});
    });
}

test "cjk falls to per-script default" {
    var f: Fixture = undefined;
    try f.init(.{ .per_script = &.{
        .{ .script = .Hani, .han = .sc, .families = &.{"Not Installed SC"} },
        .{ .script = .Hani, .han = .ja, .families = &.{ "Not Installed JP", "Source Han Sans JP" } },
    } }, .{});
    defer f.deinit();
    const c = try f.fb.chain(&.{"Fira Code"}, .{});
    f.fb.setLocale("ja-JP");
    const id = f.fb.resolve(c, "\u{6F22}", .default);
    try testing.expectEqualStrings("SourceHanSansJP-Subset.otf", f.fileOf(id));
    try testing.expectEqual(@as(u64, 1), f.fb.stats().script);
    // Kana go to the Japanese list whatever the locale.
    f.fb.setLocale("zh-CN");
    try testing.expectEqual(id, f.fb.resolve(c, "\u{3042}", .default));
    try testing.expectEqual(@as(u64, 2), f.fb.stats().script);
    // With a simplified-Chinese locale nothing listed is installed: the
    // coverage index still finds the face.
    try testing.expectEqual(id, f.fb.resolve(c, "\u{6F22}", .default));
    try testing.expectEqual(@as(u64, 1), f.fb.stats().search);
    try testing.expectEqual(fallback.HanVariant.tc, fallback.hanVariantOf("zh-Hant-HK"));
    try testing.expectEqual(fallback.HanVariant.tc, fallback.hanVariantOf("zh_TW.UTF-8"));
    try testing.expectEqual(fallback.HanVariant.ko, fallback.hanVariantOf("ko"));
    try testing.expectEqual(fallback.HanVariant.sc, fallback.hanVariantOf("en-US"));
}

test "emoji presentation rules" {
    const ep = fallback.emojiPresentation;
    try testing.expect(!ep("\u{2764}"));
    try testing.expect(ep("\u{2764}\u{FE0F}"));
    try testing.expect(ep("\u{1F600}"));
    try testing.expect(ep("\u{1F1EF}\u{1F1F5}"));
    try testing.expect(ep("1\u{FE0F}\u{20E3}"));
    try testing.expect(!ep("\u{1F600}\u{FE0E}"));

    var f: Fixture = undefined;
    try f.init(.{}, emoji_generics);
    defer f.deinit();
    const c = try f.fb.chain(&.{"Inter"}, .{});
    const e = f.fb.resolve(c, "\u{1F600}", .default);
    try testing.expect(f.reg.get(e).color and f.maps(e, "\u{1F600}"));
    try testing.expectEqual(@as(u64, 1), f.fb.stats().emoji);
}

test "coverage index search" {
    var f: Fixture = undefined;
    try f.init(.{}, .{});
    defer f.deinit();
    const c = try f.fb.chain(&.{"JetBrains Mono"}, .{});
    const ar = f.fb.resolve(c, "\u{628}", .default);
    try testing.expectEqualStrings("NotoSansArabic-Subset.ttf", f.fileOf(ar));
    const dv = f.fb.resolve(c, "\u{915}\u{94D}", .default);
    try testing.expectEqualStrings("NotoSansDevanagari-Subset.ttf", f.fileOf(dv));
    try testing.expectEqual(@as(u64, 2), f.fb.stats().search);
}

test "cache hit and generation invalidation" {
    var f: Fixture = undefined;
    try f.init(.{}, .{});
    defer f.deinit();
    const c = try f.fb.chain(&.{"JetBrains Mono"}, .{});
    const a = f.fb.resolve(c, "\u{628}", .default);
    try testing.expectEqual(a, f.fb.resolve(c, "\u{628}", .default));
    try testing.expectEqual(@as(u64, 1), f.fb.stats().cache_hits);
    // Text and emoji presentation are cached apart.
    _ = f.fb.resolve(c, "\u{628}", .emoji);
    try testing.expectEqual(@as(u64, 1), f.fb.stats().cache_hits);

    // A new snapshot of the same files: resolved again, same id.
    var stats: db_mod.ScanStats = .{};
    var d2 = try f.db.rescan(testing.allocator, testing.io, f.list.items, &stats);
    defer d2.deinit(testing.allocator);
    f.fb.setDb(&d2);
    defer f.fb.setDb(&f.db);
    try testing.expectEqual(a, f.fb.resolve(c, "\u{628}", .default));
    try testing.expectEqual(@as(u64, 1), f.fb.stats().cache_hits);
    try testing.expectEqual(@as(u64, 3), f.fb.stats().search);
}

test "never an instance without coverage" {
    var f: Fixture = undefined;
    try f.init(.{}, emoji_generics);
    defer f.deinit();
    const c = try f.fb.chain(&.{ "Inter", "monospace" }, .{});
    const mixed = [_][]const u8{ "A", "\u{e9}", "\u{65E5}", "\u{628}", "\u{915}", "\u{1F600}", "\u{2764}\u{FE0F}", "\u{10FFFD}", "\u{50000}", "\u{1D11E}", "\u{2603}" };
    var lr: usize = 0;
    for (mixed) |s| {
        const id = f.fb.resolve(c, s, .default);
        if (id == registry.last_resort_instance) {
            lr += 1;
            continue;
        }
        try testing.expect(f.maps(id, s));
    }
    try testing.expect(lr >= 2); // U+10FFFD, U+50000 at least
    try testing.expectEqual(@as(u64, lr), f.fb.stats().last_resort);
}

test "last resort glyph table" {
    var t: last_resort.LastResortTable = .{};
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 0x0378), t.glyph(testing.allocator, 0x0378));
    const a = t.glyph(testing.allocator, 0x10FFFD);
    const b = t.glyph(testing.allocator, 0xE0001);
    try testing.expectEqual(a, t.glyph(testing.allocator, 0x10FFFD));
    try testing.expect(a >= last_resort.LastResortTable.first_interned and a != b);
    try testing.expectEqual(@as(u21, 0x10FFFD), t.codepoint(a));
    try testing.expectEqual(@as(u21, 0xE0001), t.codepoint(b));
    try testing.expectEqual(@as(u21, 0x0378), t.codepoint(0x0378));
    try testing.expectEqual(@as(u21, 0xFFFD), t.codepoint(last_resort.LastResortTable.overflow));
}

/// Last-resort boxes for `cps` at `sizes` side by side, as a PGM.
fn sheet(gpa: std.mem.Allocator, cps: []const u21, sizes: []const u16) ![]u8 {
    var total_w: usize = 0;
    var max_h: usize = 0;
    for (sizes) |s| {
        total_w += @as(usize, s) * cps.len;
        max_h = @max(max_h, s);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "P5\n# producer: zg_text src/fonts/fallback_db_test.zig sheet(), last-resort boxes\n{d} {d}\n255\n", .{ total_w, max_h });
    const hdr = out.items.len;
    try out.appendNTimes(gpa, 0, total_w * max_h);
    var ox: usize = 0;
    for (sizes) |s| for (cps) |cp| {
        var bm: @import("../raster/rasterizer.zig").Bitmap = undefined;
        try last_resort.lastResortBitmap(cp, s, s, &bm, gpa);
        defer gpa.free(bm.pixels);
        for (0..bm.height) |y| @memcpy(out.items[hdr + y * total_w + ox ..][0..bm.width], bm.pixels[y * bm.stride ..][0..bm.width]);
        ox += s;
    };
    return out.toOwnedSlice(gpa);
}

test "last resort bitmap golden" {
    const gpa = testing.allocator;
    const got = try sheet(gpa, &.{ 0xE0001, 0x10FFFD, 0x0378 }, &.{ 12, 16, 24, 48 });
    defer gpa.free(got);
    const name = "golden/last_resort/boxes.pgm";
    const want = testdata.readTestdata(gpa, name) catch |e| switch (e) {
        error.FileNotFound => {
            const io = testing.io;
            var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
            defer root.close(io);
            try root.createDirPath(io, "testdata/golden/last_resort");
            var td = try root.openDir(io, "testdata", .{});
            defer td.close(io);
            try td.writeFile(io, .{ .sub_path = name, .data = got });
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
    // The text placement: 1 em wide, 0.8 em above the baseline.
    var bm: @import("../raster/rasterizer.zig").Bitmap = undefined;
    try last_resort.glyphBitmap(0x10FFFD, 20, &bm, gpa);
    defer gpa.free(bm.pixels);
    try testing.expectEqual(@as(u16, 20), bm.width);
    try testing.expectEqual(@as(i16, -16), bm.top);
}

test "layout of text nothing maps" {
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    try f.init(.{}, .{});
    defer f.deinit();
    const c = try f.fb.chain(&.{"JetBrains Mono"}, .{});
    var tl = try layout.TextLayout.init(gpa, &f.reg, &f.fb);
    defer tl.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // (Default-ignorables such as U+E0001 count as mapped by any face.)
    const text = "a\u{10FFFD}\u{50000}b";
    const style: layout.TextStyle = .{ .chain = c, .size_px = 20 };
    const line = try tl.layoutLine(arena.allocator(), text, &.{.{ .end = text.len, .style = style }}, .{});
    try testing.expectEqual(@as(usize, 3), line.runs.len);
    const r = line.runs[1];
    try testing.expectEqual(registry.last_resort_instance, r.instance);
    try testing.expectEqual(@as(u32, 2), r.glyph_end - r.glyph_start);
    try testing.expectEqual(@as(u21, 0x10FFFD), f.reg.lastResortCodepoint(line.glyphs[r.glyph_start]));
    try testing.expectEqual(@as(u21, 0x50000), f.reg.lastResortCodepoint(line.glyphs[r.glyph_start + 1]));
    // Each box is 1 em.
    try testing.expectApproxEqAbs(@as(f32, 20), line.x[r.glyph_start + 1] - line.x[r.glyph_start], 1e-3);
    try testing.expectEqual(@as(usize, 4), line.graphemes.len);
    try testing.expectEqual(@as(usize, 5), line.carets.len);

    // A terminal cell scales the box into its cell.
    const grid = layout.cellMetrics(&tl, style);
    var out: std.ArrayList(layout.CellGlyph) = .empty;
    const row = [_]layout.Cell{.{ .text = "\u{10FFFD}", .style = .{ .chain = c } }};
    try layout.layoutCells(&tl, arena.allocator(), &row, grid, .{}, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(registry.last_resort_instance, out.items[0].key.instance);
    try testing.expect(out.items[0].scale < 1);
}
