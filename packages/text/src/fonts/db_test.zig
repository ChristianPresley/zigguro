//! Font database, cache, matching and registry tests over the test fonts
//! (never the system's) and synthetic databases.

const std = @import("std");
const testing = std.testing;
const options = @import("zg_options");
const db_mod = @import("db.zig");
const cache = @import("db_cache.zig");
const matcher = @import("matcher.zig");
const registry = @import("registry.zig");
const discovery = @import("discovery.zig");
const tag = @import("../ot/reader.zig").tag;

const FontDb = db_mod.FontDb;

fn fontsDir(gpa: std.mem.Allocator) ![]u8 {
    return std.fs.path.join(gpa, &.{ options.package_root, "testdata", "fonts" });
}

/// A database of every test font.
fn scanTestFonts(gpa: std.mem.Allocator, stats: *db_mod.ScanStats) !FontDb {
    const dir = try fontsDir(gpa);
    defer gpa.free(dir);
    var list: std.ArrayList(discovery.FileEntry) = .empty;
    defer discovery.freeFileEntries(gpa, &list);
    try discovery.listFontFiles(gpa, testing.io, &.{dir}, &list);
    return FontDb.empty.rescan(gpa, testing.io, list.items, stats);
}

fn faceNamed(d: *const FontDb, name: []const u8) ?*const db_mod.FaceInfo {
    const es = d.named(name);
    return if (es.len == 0) null else d.face(es[0].face);
}

test "scan test fonts metadata" {
    const gpa = testing.allocator;
    var stats: db_mod.ScanStats = .{};
    var d = try scanTestFonts(gpa, &stats);
    defer d.deinit(gpa);
    try testing.expectEqual(0, stats.failed);
    try testing.expectEqual(12, stats.added);

    const jbm = faceNamed(&d, "jetbrains mono").?;
    try testing.expect(jbm.monospace);
    try testing.expect(jbm.variable());
    try testing.expect(jbm.axes & db_mod.Axis.wght != 0);
    try testing.expectEqual(100, jbm.weight_min);
    try testing.expectEqual(800, jbm.weight_max);
    try testing.expectEqual(400, jbm.weight);
    try testing.expectEqual(db_mod.ColorKind.none, jbm.colorOf());

    const serif = faceNamed(&d, "Source Serif 4").?;
    try testing.expect(!serif.monospace);
    try testing.expectEqual(db_mod.Slant.normal, serif.slantOf());

    const inter = faceNamed(&d, "Inter").?;
    try testing.expect(inter.axes & db_mod.Axis.opsz != 0);
    try testing.expect(!inter.monospace);

    // Color kinds, by coverage of an emoji.
    var cbdt = false;
    var colr = false;
    var it = d.coveringFaces(0x1F600);
    while (it.next()) |f| switch (d.face(f).colorOf()) {
        .cbdt => cbdt = true,
        .colr => colr = true,
        else => {},
    };
    try testing.expect(cbdt and colr);

    // Coverage index agrees with the exact check.
    var han = d.coveringFaces(0x6F22); // 漢
    const h = han.next().?;
    try testing.expect(d.covers(h, 0x6F22));
    try testing.expect(std.mem.indexOf(u8, d.path(h), "SourceHanSansJP") != null);
    try testing.expect(han.next() == null);
    try testing.expect(!d.covers(d.named("jetbrains mono")[0].face, 0x6F22));
    try testing.expect(d.covers(d.named("jetbrains mono")[0].face, 'A'));

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const fams = try d.families(arena.allocator());
    try testing.expect(fams.len >= 10);
    for (fams[1..], 0..) |f, i| try testing.expect(std.ascii.lessThanIgnoreCase(fams[i], f));
}

fn tmpPath(gpa: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(base);
    return std.fs.path.join(gpa, &.{ base, name });
}

test "cache roundtrip" {
    const gpa = testing.allocator;
    var stats: db_mod.ScanStats = .{};
    var d = try scanTestFonts(gpa, &stats);
    defer d.deinit(gpa);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try tmpPath(gpa, &tmp, "cache/zigguro/fontdb-v1.bin");
    defer gpa.free(p);
    try d.save(gpa, testing.io, p);
    var l = try FontDb.load(gpa, testing.io, p);
    defer l.deinit(gpa);
    try testing.expectEqualSlices(u8, d.buf, l.buf);
    try testing.expect(l.generation != d.generation);
    try testing.expectEqual(d.faces().len, l.faces().len);
    try testing.expectEqualStrings(d.path(0), l.path(0));
    // No temporary file is left behind.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "cache/zigguro/fontdb-v1.bin.tmp", .{}));
    // A missing cache is an empty database.
    var none = try FontDb.load(gpa, testing.io, "/nonexistent/fontdb-v1.bin");
    defer none.deinit(gpa);
    try testing.expectEqual(0, none.faces().len);
}

test "cache rejects corrupt/old version" {
    const gpa = testing.allocator;
    var b: db_mod.Builder = .init(gpa);
    defer b.deinit();
    const file = try b.addFile("/f.ttf", 1, 2);
    try b.addFace(file, .{ .family = "A", .coverage = &.{.{ 0x20, 0x7E }} });
    var d = try b.finish();
    defer d.deinit(gpa);

    const Case = struct { off: usize, val: u8, err: cache.Error };
    const cases = [_]Case{
        .{ .off = 0, .val = 'X', .err = error.BadMagic },
        .{ .off = 8, .val = 0, .err = error.BadVersion }, // version 1 → 0
        .{ .off = 16, .val = 3, .err = error.BadVersion }, // section count
        .{ .off = 32 + 3 * 16 + 8, .val = 0xFF, .err = error.Corrupt }, // face count
    };
    for (cases) |c| {
        const copy = try gpa.alignedAlloc(u8, .@"8", d.buf.len);
        @memcpy(copy, d.buf);
        copy[c.off] = c.val;
        try testing.expectError(c.err, FontDb.fromBytes(gpa, copy));
    }
    // A face pointing at a missing string.
    const copy = try gpa.alignedAlloc(u8, .@"8", d.buf.len);
    @memcpy(copy, d.buf);
    const faces_off = std.mem.readInt(u64, copy[32 + 3 * 16 ..][0..8], .little);
    std.mem.writeInt(u32, copy[faces_off + @offsetOf(db_mod.FaceInfo, "family") ..][0..4], 9999, .native);
    try testing.expectError(error.Corrupt, FontDb.fromBytes(gpa, copy));
    // Truncated.
    const short = try gpa.alignedAlloc(u8, .@"8", 40);
    @memcpy(short, d.buf[0..40]);
    try testing.expectError(error.BadMagic, FontDb.fromBytes(gpa, short));
}

test "incremental rescan detects change" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try fontsDir(gpa);
    defer gpa.free(dir);
    for ([_][]const u8{ "FiraCode-Regular.ttf", "SourceSerif4-Regular.otf", "JetBrainsMono[wght].ttf" }) |n| {
        const src = try std.fs.path.join(gpa, &.{ dir, n });
        defer gpa.free(src);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, src, gpa, .unlimited);
        defer gpa.free(bytes);
        try tmp.dir.writeFile(io, .{ .sub_path = n, .data = bytes });
    }
    const base = try tmpPath(gpa, &tmp, "");
    defer gpa.free(base);

    var list: std.ArrayList(discovery.FileEntry) = .empty;
    defer discovery.freeFileEntries(gpa, &list);
    try discovery.listFontFiles(gpa, io, &.{base}, &list);
    var s1: db_mod.ScanStats = .{};
    var d1 = try FontDb.empty.rescan(gpa, io, list.items, &s1);
    defer d1.deinit(gpa);
    try testing.expectEqual(3, s1.added);

    // Grow one file (size changes), delete another.
    const fira = try std.Io.Dir.cwd().readFileAlloc(io, list.items[0].path, gpa, .unlimited);
    defer gpa.free(fira);
    const grown = try std.mem.concat(gpa, u8, &.{ fira, "\x00\x00\x00\x00" });
    defer gpa.free(grown);
    try tmp.dir.writeFile(io, .{ .sub_path = std.fs.path.basename(list.items[0].path), .data = grown });
    try tmp.dir.deleteFile(io, "SourceSerif4-Regular.otf");
    discovery.freeFileEntries(gpa, &list);
    list = .empty;
    try discovery.listFontFiles(gpa, io, &.{base}, &list);
    var s2: db_mod.ScanStats = .{};
    var d2 = try d1.rescan(gpa, io, list.items, &s2);
    defer d2.deinit(gpa);
    try testing.expectEqual(0, s2.added);
    try testing.expectEqual(1, s2.changed);
    try testing.expectEqual(1, s2.unchanged);
    try testing.expectEqual(1, s2.removed);
    try testing.expectEqual(2, d2.files().len);
    try testing.expect(d2.named("source serif 4").len == 0);
    // Unchanged records are copied, names and coverage included.
    const j = d2.named("JetBrains Mono");
    try testing.expectEqual(1, j.len);
    try testing.expectEqual(800, d2.face(j[0].face).weight_max);
    try testing.expect(d2.covers(j[0].face, 'g'));
}

/// A synthetic family of static faces at `weights` (one per weight,
/// with `widths` and `slants` when given).
fn family(gpa: std.mem.Allocator, specs: []const db_mod.FaceDesc) !FontDb {
    var b: db_mod.Builder = .init(gpa);
    defer b.deinit();
    for (specs, 0..) |sp, i| {
        var buf: [32]u8 = undefined;
        const file = try b.addFile(try std.fmt.bufPrint(&buf, "/f{d}.ttf", .{i}), 1, 0);
        var fd = sp;
        fd.coverage = &.{.{ 0x20, 0x7E }};
        try b.addFace(file, fd);
    }
    return b.finish();
}

fn weights(gpa: std.mem.Allocator, ws: []const u16) !FontDb {
    var specs: [16]db_mod.FaceDesc = undefined;
    for (ws, 0..) |w, i| specs[i] = .{ .family = "W", .weight = w, .coverage = &.{} };
    return family(gpa, specs[0..ws.len]);
}

test "css weight matching table" {
    const gpa = testing.allocator;
    const Case = struct { have: []const u16, want: u16, got: u16 };
    const cases = [_]Case{
        .{ .have = &.{ 300, 500 }, .want = 400, .got = 500 }, // 400 → 500 before 300
        .{ .have = &.{ 300, 600 }, .want = 400, .got = 300 }, // nothing up to 500: below first
        .{ .have = &.{600}, .want = 400, .got = 600 },
        .{ .have = &.{ 500, 700 }, .want = 600, .got = 700 }, // 600 → 700
        .{ .have = &.{ 400, 500 }, .want = 600, .got = 500 },
        .{ .have = &.{ 300, 450, 500 }, .want = 420, .got = 450 },
        .{ .have = &.{ 200, 400 }, .want = 300, .got = 200 }, // below 400: descending
        .{ .have = &.{ 400, 500 }, .want = 300, .got = 400 },
        .{ .have = &.{ 700, 900 }, .want = 800, .got = 900 }, // above 500: ascending
        .{ .have = &.{ 100, 400 }, .want = 800, .got = 400 },
        .{ .have = &.{ 100, 400, 700 }, .want = 700, .got = 700 },
    };
    for (cases) |c| {
        var d = try weights(gpa, c.have);
        defer d.deinit(gpa);
        const m = d.match(.{ .family = "w", .weight = c.want }).?;
        try testing.expectEqual(c.got, m.weight);
        try testing.expectEqual(c.got, d.face(m.face).weight);
    }
}

test "width/style fallbacks" {
    const gpa = testing.allocator;
    {
        var d = try family(gpa, &.{ .{ .family = "F", .width = 3, .coverage = &.{} }, .{ .family = "F", .width = 7, .coverage = &.{} } });
        defer d.deinit(gpa);
        try testing.expectEqual(3, d.match(.{ .family = "F", .width = 5 }).?.width); // normal: narrower first
        try testing.expectEqual(7, d.match(.{ .family = "F", .width = 6 }).?.width); // wider: wider first
        try testing.expectEqual(3, d.match(.{ .family = "F", .width = 2 }).?.width);
        try testing.expectEqual(7, d.match(.{ .family = "F", .width = 9 }).?.width);
    }
    const S = db_mod.Slant;
    const Case = struct { have: [2]S, want: S, got: S };
    const cases = [_]Case{
        .{ .have = .{ .normal, .oblique }, .want = .italic, .got = .oblique },
        .{ .have = .{ .normal, .italic }, .want = .oblique, .got = .italic },
        .{ .have = .{ .italic, .oblique }, .want = .normal, .got = .oblique },
        .{ .have = .{ .italic, .normal }, .want = .normal, .got = .normal },
    };
    for (cases) |c| {
        var d = try family(gpa, &.{ .{ .family = "F", .slant = c.have[0], .coverage = &.{} }, .{ .family = "F", .slant = c.have[1], .coverage = &.{} } });
        defer d.deinit(gpa);
        const m = d.match(.{ .family = "F", .slant = c.want }).?;
        try testing.expectEqual(c.got, m.slant);
        try testing.expectEqual(c.got, d.face(m.face).slantOf());
    }
    // Width wins over style, style over weight.
    var d = try family(gpa, &.{
        .{ .family = "F", .width = 5, .weight = 700, .slant = .normal, .coverage = &.{} },
        .{ .family = "F", .width = 5, .weight = 400, .slant = .italic, .coverage = &.{} },
        .{ .family = "F", .width = 3, .weight = 400, .slant = .normal, .coverage = &.{} },
    });
    defer d.deinit(gpa);
    const m = d.match(.{ .family = "F", .weight = 400 }).?;
    try testing.expectEqual(5, m.width);
    try testing.expectEqual(db_mod.Slant.normal, m.slant);
    try testing.expectEqual(700, m.weight);
}

test "synthetic bold" {
    const gpa = testing.allocator;
    var d = try weights(gpa, &.{ 300, 400 });
    defer d.deinit(gpa);
    const m = d.match(.{ .family = "W", .weight = 700, .slant = .italic }).?;
    try testing.expectEqual(400, m.weight);
    try testing.expect(m.synth.bold and m.synth.oblique);
    try testing.expect(!d.match(.{ .family = "W", .weight = 500 }).?.synth.bold);
    var e = try weights(gpa, &.{ 400, 600 });
    defer e.deinit(gpa);
    try testing.expect(!e.match(.{ .family = "W", .weight = 700 }).?.synth.bold);
}

test "variable font creates instance at weight 450" {
    const gpa = testing.allocator;
    var stats: db_mod.ScanStats = .{};
    var d = try scanTestFonts(gpa, &stats);
    defer d.deinit(gpa);
    const m = d.match(.{ .family = "JetBrains Mono", .weight = 450 }).?;
    try testing.expectEqual(450, m.weight);
    try testing.expect(!m.synth.bold);
    try testing.expectEqual(1, m.axisValues().len);
    try testing.expectEqual(tag("wght"), m.axisValues()[0].tag);
    try testing.expectEqual(450, m.axisValues()[0].value);

    var reg: registry.FontRegistry = .init(gpa);
    defer reg.deinit();
    const id = try reg.instance(testing.io, &d, m.face, m.axisValues(), m.synth);
    const r = reg.get(id);
    try testing.expect(r.monospace);
    try testing.expect(r.inst.axis_count == 1 and r.inst.coords[0] > 0);
    // The default instance is a different id with zero coordinates.
    const id0 = try reg.instance(testing.io, &d, m.face, &.{}, .{});
    try testing.expect(id0 != id);
    try testing.expectEqual(0, reg.get(id0).inst.coords[0]);
    // A synthesized bold of the same face is another id that says so.
    const idb = try reg.instance(testing.io, &d, m.face, m.axisValues(), .{ .bold = true });
    try testing.expect(idb != id and reg.get(idb).synth.bold);
}

test "registry ids stable and lock-free get" {
    const gpa = testing.allocator;
    var stats: db_mod.ScanStats = .{};
    var d = try scanTestFonts(gpa, &stats);
    defer d.deinit(gpa);
    var reg: registry.FontRegistry = .init(gpa);
    defer reg.deinit();
    const f = d.named("Fira Code")[0].face;
    const a = try reg.instance(testing.io, &d, f, &.{}, .{});
    try testing.expectEqual(registry.first_id, a);
    try testing.expectEqual(a, try reg.instance(testing.io, &d, f, &.{}, .{}));
    // Another snapshot of the same files: same id.
    var s3: db_mod.ScanStats = .{};
    var d3 = try scanTestFonts(gpa, &s3);
    defer d3.deinit(gpa);
    try testing.expectEqual(a, try reg.instance(testing.io, &d3, d3.named("Fira Code")[0].face, &.{}, .{}));

    // Readers on another thread while ids are added across segments.
    const inst = reg.get(a).inst;
    const Reader = struct {
        fn run(r: *const registry.FontRegistry, stop: *std.atomic.Value(bool), seen: *u32) void {
            while (!stop.load(.acquire)) {
                const n = r.count();
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const id: registry.InstanceId = @intCast(registry.first_id + i);
                    std.debug.assert(r.has(id));
                    std.debug.assert(r.get(id).upem > 0);
                }
                seen.* = n;
            }
        }
    };
    var stop: std.atomic.Value(bool) = .init(false);
    var seen: u32 = 0;
    const t = try std.Thread.spawn(.{}, Reader.run, .{ &reg, &stop, &seen });
    var insts: [300]@import("../ot/var/instance.zig").FaceInstance = undefined;
    for (&insts) |*fi| fi.* = .{ .face = inst.face };
    for (&insts, 0..) |*fi, i| try testing.expectEqual(registry.first_id + 1 + i, try reg.register(fi));
    stop.store(true, .release);
    t.join();
    try testing.expectEqual(301, reg.count());
    for (&insts, 0..) |*fi, i| try testing.expectEqual(fi, reg.get(@intCast(registry.first_id + 1 + i)).inst);
    try testing.expectEqual(registry.first_id + 5, try reg.register(&insts[4]));
}

test "localized family names match" {
    const gpa = testing.allocator;
    var d = try family(gpa, &.{.{ .family = "Source Han Sans", .aliases = &.{ "源ノ角ゴシック", "Source Han Sans JP" }, .full_name = "Source Han Sans Regular", .coverage = &.{} }});
    defer d.deinit(gpa);
    for ([_][]const u8{ "源ノ角ゴシック", "source han sans jp", "SOURCE HAN SANS", "Source Han Sans Regular" }) |n|
        try testing.expect(d.match(.{ .family = n }) != null);
    try testing.expect(d.match(.{ .family = "Source Han" }) == null);
}

test "generic families" {
    const gpa = testing.allocator;
    var stats: db_mod.ScanStats = .{};
    var d = try scanTestFonts(gpa, &stats);
    defer d.deinit(gpa);
    var g: matcher.Generics = .{};
    g.lists.set(.monospace, &.{ "Not Installed", "Fira Code" });
    const m = matcher.match(&d, &g, .{ .family = "ui-monospace" }).?;
    try testing.expectEqualStrings("Fira Code", d.str(d.face(m.face).typographic_family));
    // With no list: the first monospaced or color face's family.
    const empty: matcher.Generics = .{};
    try testing.expect(d.face(matcher.match(&d, &empty, .{ .family = "monospace" }).?.face).monospace);
    try testing.expect(d.face(matcher.match(&d, &empty, .{ .family = "emoji" }).?.face).colorOf() != .none);
    try testing.expect(matcher.match(&d, &empty, .{ .family = "Nope" }) == null);
    try testing.expectEqual(matcher.Generic.sans_serif, matcher.genericOf("UI-Sans-Serif").?);
}

test "default cache path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expect(try db_mod.defaultCachePath(a, &env, .linux) == null);
    try env.put("HOME", "/home/u");
    try testing.expectEqualStrings("/home/u/.cache/zigguro/fontdb-v1.bin", (try db_mod.defaultCachePath(a, &env, .linux)).?);
    try env.put("XDG_CACHE_HOME", "/c");
    try testing.expectEqualStrings("/c/zigguro/fontdb-v1.bin", (try db_mod.defaultCachePath(a, &env, .linux)).?);
    try testing.expect(try db_mod.defaultCachePath(a, &env, .windows) == null);
    try env.put("LOCALAPPDATA", "C:\\Users\\u\\AppData\\Local");
    try testing.expectEqualStrings("C:\\Users\\u\\AppData\\Local\\zigguro\\cache\\fontdb-v1.bin", (try db_mod.defaultCachePath(a, &env, .windows)).?);
}
