//! The generated tables against ucdgen's uncompressed reference builder,
//! run in the test binary over the vendored UCD files, plus spot checks.

const std = @import("std");
const testing = std.testing;
const u = @import("props.zig");
const ref = @import("ucdgen_ref");
const options = @import("zg_options");

/// Reads the vendored inputs; free each with `gpa`.
fn readInputs(gpa: std.mem.Allocator) !ref.Inputs {
    const io = testing.io;
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    var dir = try root.openDir(io, "ucd/" ++ u.unicode_version, .{});
    defer dir.close(io);
    var inputs: ref.Inputs = undefined;
    var loaded: usize = 0;
    errdefer for (inputs[0..loaded]) |x| gpa.free(x);
    for (ref.files, 0..) |f, i| {
        inputs[i] = try dir.readFileAlloc(io, f, gpa, .limited(64 << 20));
        loaded += 1;
    }
    return inputs;
}

/// Builds the reference tables from `ucd/<version>/`.
pub fn loadReference(gpa: std.mem.Allocator) !ref.Ucd {
    const inputs = try readInputs(gpa);
    defer for (inputs) |x| gpa.free(x);
    var diag: ref.Diag = .{};
    return ref.build(gpa, &inputs, &diag);
}

test "generated blob equals the build's and is deterministic" {
    const gpa = testing.allocator;
    const inputs = try readInputs(gpa);
    defer for (inputs) |x| gpa.free(x);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diag: ref.Diag = .{};
    const a = try ref.generate(arena.allocator(), gpa, &inputs, &diag);
    const b = try ref.generate(arena.allocator(), gpa, &inputs, &diag);
    try testing.expectEqualSlices(u8, a, b);
    try testing.expectEqualSlices(u8, a, &@import("ucd_tables").blob);
    try testing.expect(a.len < 600 * 1024);
}

test "manifest mismatch fails the generator" {
    const gpa = testing.allocator;
    var inputs = try readInputs(gpa);
    defer for (inputs) |x| gpa.free(x);
    const io = testing.io;
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    const src = try root.readFileAllocOptions(io, "ucd/" ++ u.unicode_version ++ "/manifest.zon", gpa, .limited(1 << 20), .of(u8), 0);
    defer gpa.free(src);
    const manifest = try std.zon.parse.fromSliceAlloc([]const ref.ManifestEntry, gpa, src, null, .{});
    defer std.zon.parse.free(gpa, manifest);
    var vd: ref.VerifyDiag = .{};
    try ref.verifyInputs(manifest, &inputs, &vd);
    // A tampered copy of one file.
    const tampered = try gpa.dupe(u8, inputs[0]);
    defer gpa.free(tampered);
    tampered[100] ^= 1;
    const orig = inputs[0];
    inputs[0] = tampered;
    defer inputs[0] = orig;
    try testing.expectError(error.ChecksumMismatch, ref.verifyInputs(manifest, &inputs, &vd));
    try testing.expectEqualStrings("UnicodeData.txt", vd.file);
}

test "props and aux exhaustive vs reference" {
    var r = try loadReference(testing.allocator);
    defer r.deinit();
    for (0..ref.code_points) |i| {
        const cp: u21 = @intCast(i);
        const got = u.props(cp);
        if (@as(u64, @bitCast(got)) != @as(u64, @bitCast(r.props[i]))) {
            std.debug.print("U+{X:0>4}: got {any}\nwant {any}\n", .{ cp, got, r.props[i] });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(@as(u32, @bitCast(r.aux[i])), @as(u32, @bitCast(u.aux(cp))));
    }
    try testing.expectEqual(u.Props{}, u.props(std.math.maxInt(u21)));
}

test "maps exhaustive vs reference" {
    var r = try loadReference(testing.allocator);
    defer r.deinit();
    for (r.mirror) |m| try testing.expectEqual(@as(?u21, m[1]), u.mirror(m[0]));
    for (r.brackets) |m| try testing.expectEqual(@as(?u21, m[1]), u.pairedBracket(m[0]));
    for (r.decomp_canon) |d| try testing.expectEqualSlices(u21, d.cps, u.decomposeCanonical(d.cp).?);
    for (r.decomp_compat) |d| try testing.expectEqualSlices(u21, d.cps, u.decomposeCompat(d.cp).?);
    for (r.compose) |c| try testing.expectEqual(@as(?u21, c.c), u.compose(c.a, c.b));
    for (r.fold_simple) |f| try testing.expectEqual(f[1], u.caseFoldSimple(f[0]));
    for (r.fold_full) |f| try testing.expectEqualSlices(u21, f.cps, u.caseFoldFull(f.cp).slice());
    for (r.case_simple) |c| {
        try testing.expectEqual(c[1], u.caseMapSimple(c[0], .upper));
        try testing.expectEqual(c[2], u.caseMapSimple(c[0], .lower));
        try testing.expectEqual(c[3], u.caseMapSimple(c[0], .title));
    }
    for (r.case_full) |c| try testing.expectEqualSlices(u21, c.cps, u.caseMapFull(c.cp, @enumFromInt(@intFromEnum(c.kind))).slice());
    // Script_Extensions for every code point.
    var si: usize = 0;
    for (0..ref.code_points) |i| {
        const cp: u21 = @intCast(i);
        while (si < r.scx.len and r.scx[si].hi < cp) si += 1;
        const got = u.scriptExtensions(cp);
        if (si < r.scx.len and r.scx[si].lo <= cp) {
            try testing.expectEqualSlices(u.Script, r.scx[si].scripts, got);
        } else {
            try testing.expectEqual(@as(usize, 1), got.len);
            try testing.expectEqual(r.props[i].script, got[0]);
        }
    }
}

test "decomposition samples" {
    try testing.expectEqualSlices(u21, &.{ 0x41, 0x30A }, u.decomposeCanonical(0xC5).?);
    // U+1E9B: canonical keeps long s, compatibility folds it to s.
    try testing.expectEqualSlices(u21, &.{ 0x17F, 0x307 }, u.decomposeCanonical(0x1E9B).?);
    try testing.expectEqualSlices(u21, &.{ 0x73, 0x307 }, u.decomposeCompat(0x1E9B).?);
    const fi = u.decomposition(0xFB01).?;
    try testing.expect(fi.compat);
    try testing.expectEqualSlices(u21, &.{ 0x66, 0x69 }, fi.cps);
    try testing.expect(u.decomposition('a') == null);
    try testing.expect(u.decomposition(0xAC00) == null); // Hangul is algorithmic
}

test "compose excludes exclusions" {
    try testing.expectEqual(@as(?u21, 0xC5), u.compose(0x41, 0x30A));
    // U+0958 (DEVANAGARI QA) is a composition exclusion.
    try testing.expect(u.compose(0x915, 0x93C) == null);
    try testing.expect(u.compose('a', 'b') == null);
}

test "case folding and mapping" {
    try testing.expectEqualSlices(u21, &.{ 's', 's' }, u.caseFoldFull(0xDF).slice());
    try testing.expectEqual(@as(u21, 0xDF), u.caseFoldSimple(0xDF));
    try testing.expectEqual(@as(u21, 'a'), u.caseFoldSimple('A'));
    try testing.expectEqual(@as(u21, 0x3C3), u.caseFoldSimple(0x3A3));
    try testing.expectEqualSlices(u21, &.{ 'S', 'S' }, u.caseMapFull(0xDF, .upper).slice());
    try testing.expectEqualSlices(u21, &.{ 'i', 0x307 }, u.caseMapFull(0x130, .lower).slice());
    try testing.expectEqualSlices(u21, &.{0x1C5}, u.caseMapFull(0x1C5, .title).slice());
    try testing.expectEqual(@as(u21, 0x1C4), u.caseMapSimple(0x1C5, .upper));
    try testing.expectEqual(@as(u21, 'A'), u.caseMapSimple('a', .title));
    try testing.expect(u.isCased('a') and !u.isCased('1'));
    try testing.expect(u.isCaseIgnorable('\''));
}

test "properties samples" {
    try testing.expectEqual(u.GeneralCategory.Lu, u.props('A').gc);
    try testing.expectEqual(u.LineBreak.ID, u.props(0x4E00).lb);
    try testing.expectEqual(u.EastAsianWidth.W, u.props(0x4E00).eaw);
    try testing.expectEqual(u.BidiClass.AL, u.props(0x627).bidi);
    try testing.expectEqual(u.BidiClass.R, u.props(0x5FF).bidi); // @missing block default
    try testing.expectEqual(u.JoiningType.D, u.props(0x628).jt);
    try testing.expectEqual(u.JoiningType.T, u.props(0x301).jt);
    try testing.expectEqual(u.GraphemeBreak.RI, u.props(0x1F1FA).gcb);
    try testing.expect(u.props(0x1F600).ext_pict and u.props(0x1F600).emoji_pres);
    try testing.expectEqual(u.IndicConjunctBreak.Linker, u.props(0x94D).incb);
    try testing.expectEqual(@as(u8, 230), u.props(0x301).ccc);
    try testing.expectEqual(u.BracketType.o, u.props('(').bpt);
    try testing.expectEqual(@as(?u21, ')'), u.pairedBracket('('));
    try testing.expectEqual(@as(?u21, '>'), u.mirror('<'));
    try testing.expect(u.isEmojiVariationBase(0x2764));
    try testing.expectEqual(u.IndicSyllabic.Virama, u.indicCategories(0x94D).syllabic);
    try testing.expectEqual(u.Script.Zzzz, u.props(0x10FFFF).script);
}

test "script extensions sample" {
    const s = u.scriptExtensions(0x964);
    try testing.expect(std.mem.indexOfScalar(u.Script, s, .Deva) != null);
    try testing.expect(std.mem.indexOfScalar(u.Script, s, .Beng) != null);
    try testing.expectEqualSlices(u.Script, &.{.Latn}, u.scriptExtensions('a'));
}
