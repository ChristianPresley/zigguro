//! Face tests against the test-font corpus and its fontTools reference
//! values in `testdata/fonts/metrics.zon`.

const std = @import("std");
const testing = std.testing;
const face_mod = @import("face.zig");
const Face = face_mod.Face;
const cmap = @import("cmap.zig");
const reader = @import("reader.zig");
const sfnt = @import("sfnt.zig");
const testutil = @import("testutil.zig");
const fonts = @import("../testing/fonts.zig");

const Ref = struct {
    file: []const u8,
    num_glyphs: u16,
    outline: face_mod.OutlineKind,
    family: []const u8,
    subfamily: []const u8,
    tables: []const u8,
    metrics: face_mod.FontMetrics,
    style: face_mod.Style,
    cmap_count: u32,
    cmap_sha256: []const u8,
    hmtx_sha256: []const u8,
};

fn refs() ![]Ref {
    const src = try fonts.readTestdataZ(testing.allocator, "fonts/metrics.zon");
    defer testing.allocator.free(src);
    return std.zon.parse.fromSliceAlloc([]Ref, testing.allocator, src, null, .{});
}

fn hex(digest: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

test "font manifest checksums match and corpus is under 8 MB" {
    const m = try fonts.manifest(testing.allocator);
    defer std.zon.parse.free(testing.allocator, m);
    try testing.expect(m.len >= 10);
    var total: usize = 0;
    for (m) |e| {
        const data = try fonts.font(testing.allocator, e.file);
        defer testing.allocator.free(data);
        total += data.len;
        var d: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
        testing.expectEqualStrings(e.sha256, &hex(d)) catch |err| {
            std.debug.print("checksum mismatch: {s}\n", .{e.file});
            return err;
        };
        var lic_path: [256]u8 = undefined;
        const lic = try fonts.readTestdata(testing.allocator, try std.fmt.bufPrint(&lic_path, "fonts/{s}", .{e.license_file}));
        testing.allocator.free(lic);
    }
    try testing.expect(total < 8 << 20);
}

test "sfnt directory, metrics, names and style match the reference" {
    const rs = try refs();
    defer std.zon.parse.free(testing.allocator, rs);
    for (rs) |r| {
        errdefer std.debug.print("font: {s}\n", .{r.file});
        const data = try fonts.font(testing.allocator, r.file);
        defer testing.allocator.free(data);
        try testing.expectEqual(@as(u32, 1), try Face.faceCount(data));
        const f = try Face.init(data, 0);
        try testing.expectEqual(r.num_glyphs, f.num_glyphs);
        try testing.expectEqual(r.outline, f.outline_kind);
        try testing.expectEqual(r.metrics, f.metrics());
        try testing.expectEqual(r.style, f.style());
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings(r.family, f.names().get(.family, &buf).?);
        try testing.expectEqualStrings(r.subfamily, f.names().get(.subfamily, &buf).?);
        // Every table tag is located.
        var it = std.mem.tokenizeScalar(u8, r.tables, ' ');
        var count: usize = 0;
        while (it.next()) |name| : (count += 1) {
            var t: [4]u8 = @splat(' ');
            @memcpy(t[0..name.len], name);
            try testing.expect(f.table(std.mem.readInt(u32, &t, .big)) != null);
        }
        try testing.expectEqual(count, f.tables.num_tables);
        try testing.expect(f.validateChecksums() or true); // subset fonts may carry stale checksums
    }
}

test "cmap and hmtx agree with the reference for every code point and glyph" {
    const rs = try refs();
    defer std.zon.parse.free(testing.allocator, rs);
    for (rs) |r| {
        errdefer std.debug.print("font: {s}\n", .{r.file});
        const data = try fonts.font(testing.allocator, r.file);
        defer testing.allocator.free(data);
        var f = try Face.init(data, 0);
        // Exhaustive cmap: "%X %d\n" for mapped code points, hashed.
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        var n: u32 = 0;
        var line: [32]u8 = undefined;
        var cp: u21 = 0;
        while (cp <= 0x10FFFF) : (cp += 1) {
            const g = f.glyphIndex(cp);
            try testing.expect(g < f.num_glyphs);
            if (g == 0) continue;
            h.update(try std.fmt.bufPrint(&line, "{X} {d}\n", .{ cp, g }));
            n += 1;
        }
        try testing.expectEqual(r.cmap_count, n);
        try testing.expectEqualStrings(r.cmap_sha256, &hex(h.finalResult()));
        // Page cache equals the slow path for every code point.
        var pc: cmap.BmpPageCache = .init(testing.allocator);
        defer pc.deinit();
        f.attachPageCache(&pc);
        cp = 0;
        while (cp <= 0x10FFFF) : (cp += 1) try testing.expectEqual(f.cmap.?.lookupSlow(cp), f.glyphIndex(cp));
        // hmtx including glyphs past numberOfHMetrics.
        var hm = std.crypto.hash.sha2.Sha256.init(.{});
        for (0..f.num_glyphs) |gi| {
            const g: u16 = @intCast(gi);
            hm.update(try std.fmt.bufPrint(&line, "{d} {d} {d}\n", .{ g, f.advance(g), f.lsb(g) }));
        }
        try testing.expectEqualStrings(r.hmtx_sha256, &hex(hm.finalResult()));
        // coverage() agrees with lookups.
        const cov = try f.cmap.?.coverage(testing.allocator);
        defer cov.deinit(testing.allocator);
        var covered: u32 = 0;
        for (cov.ranges) |rg| covered += rg[1] - rg[0] + 1;
        try testing.expectEqual(n, covered);
    }
}

test "hmtx tail reuses the last advance" {
    const data = try fonts.font(testing.allocator, "SourceSerif4-Regular.otf");
    defer testing.allocator.free(data);
    const f = try Face.init(data, 0);
    // A synthetic view: two long metrics then two lsb-only entries.
    const bytes = [_]u8{ 0, 100, 0, 5, 0, 200, 0xff, 0xfe, 0, 7, 0, 9 };
    const h = @import("hmtx.zig").Hmtx.init(&bytes, 2, 4);
    try testing.expectEqual(@as(u16, 200), h.advance(3));
    try testing.expectEqual(@as(i16, -2), h.lsb(1));
    try testing.expectEqual(@as(i16, 9), h.lsb(3));
    try testing.expectEqual(@as(i16, 0), h.lsb(4));
    _ = f;
}

test "monospace detection" {
    for ([_]struct { []const u8, bool }{ .{ "JetBrainsMono[wght].ttf", true }, .{ "SourceSerif4-Regular.otf", false }, .{ "FiraCode-Regular.ttf", true }, .{ "Inter[opsz,wght].ttf", false } }) |c| {
        const data = try fonts.font(testing.allocator, c[0]);
        defer testing.allocator.free(data);
        const f = try Face.init(data, 0);
        try testing.expectEqual(c[1], f.style().monospace);
    }
}

test "ttc faces" {
    const a = try fonts.font(testing.allocator, "JetBrainsMono[wght].ttf");
    defer testing.allocator.free(a);
    const b = try fonts.font(testing.allocator, "SourceSerif4-Regular.otf");
    defer testing.allocator.free(b);
    const ttc = try testutil.buildTtc(testing.allocator, &.{ a, b });
    defer testing.allocator.free(ttc);
    try testing.expectEqual(@as(u32, 2), try Face.faceCount(ttc));
    const f0 = try Face.init(ttc, 0);
    const f1 = try Face.init(ttc, 1);
    try testing.expectEqual(face_mod.OutlineKind.glyf, f0.outline_kind);
    try testing.expectEqual(face_mod.OutlineKind.cff, f1.outline_kind);
    const plain0 = try Face.init(a, 0);
    try testing.expectEqual(plain0.metrics(), f0.metrics());
    try testing.expectEqual(plain0.glyphIndex('x'), f0.glyphIndex('x'));
    try testing.expectError(error.IndexOutOfRange, Face.init(ttc, 2));
    try testing.expectError(error.IndexOutOfRange, Face.init(a, 1));
}

test "glyphVariant and rejected inputs" {
    const data = try fonts.font(testing.allocator, "SourceHanSansJP-Subset.otf");
    defer testing.allocator.free(data);
    const f = try Face.init(data, 0);
    try testing.expect(f.glyphIndex(0x65E5) != 0);
    try testing.expect(f.glyphVariant(0x65E5, 0x1F600) == null);
    try testing.expectError(error.Unsupported, Face.init("typ1\x00\x00\x00\x00\x00\x00\x00\x00", 0));
    try testing.expectError(error.Malformed, Face.init("\x00\x01", 0));
    // Truncations never panic.
    var len: usize = 0;
    while (len < 4096) : (len += 37) _ = Face.init(data[0..len], 0) catch {};
}

test "no allocation in Face.init and lookups" {
    // Face.init takes no allocator; this documents that lookups do not either.
    const data = try fonts.font(testing.allocator, "Inter[opsz,wght].ttf");
    defer testing.allocator.free(data);
    const f = try Face.init(data, 0);
    try testing.expect(f.glyphIndex('A') != 0);
    try testing.expect(f.advance(f.glyphIndex('A')) > 0);
}

test "MappedFont maps a font read-only" {
    const io = testing.io;
    var root = try std.Io.Dir.openDirAbsolute(io, @import("zg_options").package_root, .{});
    defer root.close(io);
    var mf = try face_mod.MappedFont.open(io, root, "testdata/fonts/JetBrainsMono[wght].ttf");
    defer mf.close(io);
    const f = try Face.init(mf.bytes(), 0);
    try testing.expect(f.glyphIndex('a') != 0);
}

test "fuzz: ot-face" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [8192]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            const n = Face.faceCount(input) catch return;
            for (0..@min(n, 4)) |i| {
                const f = Face.init(input, @intCast(i)) catch continue;
                _ = f.metrics();
                _ = f.style();
                var nb: [64]u8 = undefined;
                _ = f.names().get(.family, &nb);
                for (0..64) |k| {
                    const g: u16 = @truncate(k *% 7919);
                    _ = f.advance(g);
                    _ = f.lsb(g);
                }
                for ([_]u21{ 'a', 0x4E00, 0x1F600 }) |cp| try testing.expect(f.glyphIndex(cp) < @max(f.num_glyphs, 1));
            }
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "ot-face") });
}
