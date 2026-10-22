//! CFF tests: INDEX and DICT encodings, crafted charstrings for hints,
//! flex, seac, subroutines, limits and arithmetic, and fontTools goldens
//! for CFF1, CID-keyed CFF and CFF2 (default and blended). Every glyph of
//! the three CFF test fonts was also diffed once against
//! `gen_outline_golden.py --all` (0 diffs, CFF2 also at wght=900).

const std = @import("std");
const testing = std.testing;
const cff = @import("cff.zig");
const Cff = cff.Cff;
const Face = @import("face.zig").Face;
const instance = @import("var/instance.zig");
const Path = @import("../outline/path.zig").Path;
const fonts = @import("../testing/fonts.zig");
const glyf_test = @import("glyf_test.zig");

test "index parsing with every offset size and empty" {
    for (1..5) |os| {
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        buf[0] = 0;
        buf[1] = 2; // count 2
        buf[2] = @intCast(os);
        n = 3;
        for ([_]u32{ 1, 3, 6 }) |off| {
            var k = os;
            while (k > 0) : (k -= 1) {
                buf[n] = @truncate(off >> @intCast((k - 1) * 8));
                n += 1;
            }
        }
        @memcpy(buf[n..][0..5], "abcde");
        n += 5;
        const ix, const end = try cff.Index.parse(buf[0..n], 0, .cff1);
        try testing.expectEqual(n, end);
        try testing.expectEqualStrings("ab", try ix.get(0));
        try testing.expectEqualStrings("cde", try ix.get(1));
        try testing.expectError(error.Malformed, ix.get(2));
        try testing.expectError(error.Malformed, cff.Index.parse(buf[0 .. n - 1], 0, .cff1));
    }
    const empty1, const e1 = try cff.Index.parse(&.{ 0, 0 }, 0, .cff1);
    try testing.expectEqual(@as(u32, 0), empty1.count);
    try testing.expectEqual(@as(usize, 2), e1);
    const empty2, const e2 = try cff.Index.parse(&.{ 0, 0, 0, 0 }, 0, .cff2);
    try testing.expectEqual(@as(u32, 0), empty2.count);
    try testing.expectEqual(@as(usize, 4), e2);
    // Non-monotonic offsets are caught on access.
    const bad, _ = try cff.Index.parse(&.{ 0, 2, 1, 1, 4, 3, 'a', 'b', 'c' }, 0, .cff1);
    try testing.expectError(error.Malformed, bad.get(0));
}

test "dict operands: every encoding and reals" {
    const bytes = [_]u8{
        139, // 0
        247, 0, // 108
        251, 0, // -108
        28, 0x80, 0x00, // -32768
        29, 0x00, 0x01, 0x00, 0x00, // 65536
        30, 0xe2, 0xa2, 0x5f, // -2.25
        30, 0x1c, 0x3f, // 1E-3
        17, // CharStrings
        12, 7, // FontMatrix (no operands)
    };
    var it = cff.DictIter.init(&bytes);
    const e = (try it.next()).?;
    try testing.expectEqual(@as(u16, 17), e.op);
    try testing.expectEqualSlices(f64, &.{ 0, 108, -108, -32768, 65536, -2.25, 1e-3 }, e.args);
    const e2 = (try it.next()).?;
    try testing.expectEqual(@as(u16, cff.Op.font_matrix), e2.op);
    try testing.expect(try it.next() == null);
    var bad = cff.DictIter.init(&.{ 30, 0xd0 });
    try testing.expectError(error.Malformed, bad.next());
}

test "subr bias boundaries" {
    try testing.expectEqual(@as(i32, 107), cff.subrBias(1239));
    try testing.expectEqual(@as(i32, 1131), cff.subrBias(1240));
    try testing.expectEqual(@as(i32, 1131), cff.subrBias(33899));
    try testing.expectEqual(@as(i32, 32768), cff.subrBias(33900));
}

/// Charstring bytes: numbers become `28 hi lo`, ops are passed through.
inline fn cs(comptime items: anytype) []const u8 {
    comptime {
        var out: []const u8 = &.{};
        for (items) |x| {
            out = out ++ switch (@TypeOf(x)) {
                comptime_int => blk: {
                    const v: i16 = x;
                    const u: u16 = @bitCast(v);
                    break :blk &[_]u8{ 28, u >> 8, u & 0xFF };
                },
                Op => &[_]u8{@intFromEnum(x)},
                Esc => &[_]u8{ 12, @intFromEnum(x) },
                Raw => x.bytes,
                else => @compileError("bad item"),
            };
        }
        const final = out[0..out.len].*;
        return &final;
    }
}

const Op = enum(u8) { hstem = 1, vstem = 3, vmoveto = 4, rlineto = 5, hlineto = 6, vlineto = 7, rrcurveto = 8, callsubr = 10, ret = 11, endchar = 14, hintmask = 19, rmoveto = 21, hmoveto = 22, callgsubr = 29 };
const Esc = enum(u8) { add = 10, sub = 11, mul = 24, dup = 27, exch = 28, index = 29, roll = 30, hflex = 34, flex = 35, hflex1 = 36, flex1 = 37 };
const Raw = struct { bytes: []const u8 };

/// A CFF1 font (ISOAdobe charset, so gid = SID) with `glyphs`, local
/// `subrs` and global `gsubrs`.
fn buildCff(gpa: std.mem.Allocator, glyphs: []const []const u8, subrs: []const []const u8, gsubrs: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 1, 0, 4, 4 });
    try index(gpa, &out, &.{"T"});
    // Top DICT with fixed-width offsets, patched below.
    const top = [_]u8{ 29, 0, 0, 0, 0, 17, 29, 0, 0, 0, 0, 29, 0, 0, 0, 0, 18 };
    try index(gpa, &out, &.{&top});
    const top_at = out.items.len - top.len;
    try index(gpa, &out, &.{}); // strings
    try index(gpa, &out, gsubrs);
    const cs_off = out.items.len;
    try index(gpa, &out, glyphs);
    const priv_off = out.items.len;
    const priv = [_]u8{ 29, 0, 0, 0, 7, 19 }; // Subrs at +7 (after this 6-byte DICT and a pad byte)
    try out.appendSlice(gpa, &priv);
    try out.append(gpa, 0);
    try index(gpa, &out, subrs);
    std.mem.writeInt(u32, out.items[top_at + 1 ..][0..4], @intCast(cs_off), .big);
    std.mem.writeInt(u32, out.items[top_at + 7 ..][0..4], priv.len, .big);
    std.mem.writeInt(u32, out.items[top_at + 12 ..][0..4], @intCast(priv_off), .big);
    return out.toOwnedSlice(gpa);
}

fn index(gpa: std.mem.Allocator, out: *std.ArrayList(u8), items: []const []const u8) !void {
    try out.appendSlice(gpa, &.{ @intCast(items.len >> 8), @intCast(items.len & 0xFF) });
    if (items.len == 0) return;
    try out.append(gpa, 4);
    var off: u32 = 1;
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, off, .big);
    try out.appendSlice(gpa, &b);
    for (items) |it| {
        off += @intCast(it.len);
        std.mem.writeInt(u32, &b, off, .big);
        try out.appendSlice(gpa, &b);
    }
    for (items) |it| try out.appendSlice(gpa, it);
}

fn render(table: []const u8, gid: u16) ![]u8 {
    const gpa = testing.allocator;
    const c = try Cff.init(table, .cff1);
    var p: Path = .{};
    defer p.deinit(gpa);
    try c.outline(gid, null, &p, gpa);
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try p.format(&w.writer);
    return w.toOwnedSlice();
}

fn expectGlyph(table: []const u8, gid: u16, want: []const u8) !void {
    const got = try render(table, gid);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

const empty_glyph = cs(.{Op.endchar});

test "charstring lines, width and hint masks" {
    const gpa = testing.allocator;
    // Width 500 (odd rmoveto args), a square drawn with alternating lines.
    const square = cs(.{ 500, 10, 20, Op.rmoveto, 50, 50, -50, Op.hlineto, Op.endchar });
    // 8 hstem pairs + 1 implicit vstem pair = 9 stems: hintmask takes 2
    // bytes (0xFF and 0x0B, which would read as "return" if miscounted).
    const hinted = cs(.{ 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, Op.hstem, 0, 1, Op.hintmask, Raw{ .bytes = &.{ 0xFF, 0x0B } }, 5, Op.hmoveto, 7, 3, Op.rlineto, Op.endchar });
    // hmoveto with 2 args: the first is the width.
    const hmove = cs(.{ 400, 9, Op.hmoveto, 1, Op.vlineto, Op.endchar });
    const table = try buildCff(gpa, &.{ empty_glyph, square, hinted, hmove }, &.{}, &.{});
    defer gpa.free(table);
    try expectGlyph(table, 1, "M 10 20 L 60 20 L 60 70 L 10 70 Z");
    try expectGlyph(table, 2, "M 5 0 L 12 3 Z");
    try expectGlyph(table, 3, "M 9 0 L 9 1 Z");
    try expectGlyph(table, 0, "");
}

test "charstring flex variants" {
    const gpa = testing.allocator;
    const flex = cs(.{ 0, 0, Op.rmoveto, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 50, Esc.flex, Op.endchar });
    const hflex = cs(.{ 0, 0, Op.rmoveto, 10, 20, 5, 30, 40, 50, 60, Esc.hflex, Op.endchar });
    const hflex1 = cs(.{ 0, 0, Op.rmoveto, 1, 2, 3, 4, 5, 6, 7, 8, 9, Esc.hflex1, Op.endchar });
    // flex1: |dx| > |dy|, so d6 is the last dx and dy returns to the start.
    const flex1 = cs(.{ 0, 0, Op.rmoveto, 10, 1, 10, 1, 10, 1, 10, 1, 10, 1, 7, Esc.flex1, Op.endchar });
    const table = try buildCff(gpa, &.{ flex, hflex, hflex1, flex1 }, &.{}, &.{});
    defer gpa.free(table);
    try expectGlyph(table, 0, "M 0 0 C 1 2 4 6 9 12 C 16 20 25 30 36 42 Z");
    try expectGlyph(table, 1, "M 0 0 C 10 0 30 5 60 5 C 100 5 150 0 210 0 Z");
    try expectGlyph(table, 2, "M 0 0 C 1 2 4 6 9 6 C 15 6 22 14 31 0 Z");
    try expectGlyph(table, 3, "M 0 0 C 10 1 20 2 30 3 C 40 4 50 5 57 0 Z");
}

test "seac endchar accent" {
    const gpa = testing.allocator;
    // gid = SID with the ISOAdobe charset: 'A' is SID 34 (code 65),
    // 'acute' SID 125 (code 194).
    var glyphs: [130][]const u8 = @splat(empty_glyph);
    glyphs[34] = cs(.{ 0, 0, Op.rmoveto, 100, Op.hlineto, Op.endchar });
    glyphs[125] = cs(.{ 0, 0, Op.rmoveto, 10, Op.vlineto, Op.endchar });
    glyphs[1] = cs(.{ 300, 100, 200, 65, 194, Op.endchar }); // width + seac
    glyphs[2] = cs(.{ 0, 0, 65, 1, Op.endchar }); // code 1 is unencoded
    const table = try buildCff(gpa, &glyphs, &.{}, &.{});
    defer gpa.free(table);
    try expectGlyph(table, 1, "M 0 0 L 100 0 Z M 100 200 L 100 210 Z");
    try testing.expectError(error.Malformed, render(table, 2));
}

test "subroutines, recursion and stack limits" {
    const gpa = testing.allocator;
    const subrs = [_][]const u8{
        cs(.{ 5, Op.hlineto, Op.ret }), // 0: -107
        cs(.{ -106, Op.callsubr }), // 1: calls itself
    };
    const gsubrs = [_][]const u8{cs(.{ 6, Op.vlineto, Op.ret })};
    const calls = cs(.{ 0, 0, Op.rmoveto, -107, Op.callsubr, -107, Op.callgsubr, Op.endchar });
    const recursive = cs(.{ -106, Op.callsubr, Op.endchar });
    const overflow = cs(.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, Op.rlineto, Op.endchar });
    const missing = cs(.{ 50, Op.callsubr, Op.endchar });
    const table = try buildCff(gpa, &.{ calls, recursive, overflow, missing }, &subrs, &gsubrs);
    defer gpa.free(table);
    try expectGlyph(table, 0, "M 0 0 L 5 0 L 5 6 Z");
    try testing.expectError(error.LimitExceeded, render(table, 1));
    try testing.expectError(error.LimitExceeded, render(table, 2));
    try testing.expectError(error.Malformed, render(table, 3));
}

test "charstring arithmetic and storage" {
    const gpa = testing.allocator;
    // 3 4 add 2 sub dup -> 5 5 ; 1 2 exch -> 2 1 ; roll/index/mul.
    const a = cs(.{ 3, 4, Esc.add, 2, Esc.sub, Esc.dup, Op.rmoveto, 1, 2, Esc.exch, Op.rlineto, 4, 5, 6, 3, 1, Esc.roll, 0, Esc.index, Esc.mul, Op.rlineto, Op.endchar });
    const table = try buildCff(gpa, &.{a}, &.{}, &.{});
    defer gpa.free(table);
    // roll 4 5 6 by 1 -> 6 4 5 ; 0 index -> 6 4 5 5 ; mul -> 6 4 25: one
    // line (6, 4) (the odd trailing value is ignored).
    try expectGlyph(table, 0, "M 5 5 L 7 6 L 13 10 Z");
}

const Golden = struct {
    font: []const u8,
    coords: []const i16,
    glyphs: []const struct { gid: u16, name: []const u8, path: []const u8 },
};

test "cff outlines match fontTools goldens" {
    const gpa = testing.allocator;
    const files = [_][]const u8{ "SourceSerif4-Regular.zon", "SourceHanSansJP-Subset.zon", "SourceSerif4Variable-default.zon", "SourceSerif4Variable-wght900.zon" };
    var scratch: instance.OutlineScratch = .{};
    defer scratch.deinit(gpa);
    var p: Path = .{};
    defer p.deinit(gpa);
    for (files) |file| {
        var pb: [128]u8 = undefined;
        const src = try fonts.readTestdataZ(gpa, try std.fmt.bufPrint(&pb, "golden/cff/{s}", .{file}));
        defer gpa.free(src);
        const gold = try std.zon.parse.fromSliceAlloc(Golden, gpa, src, null, .{});
        defer std.zon.parse.free(gpa, gold);
        const data = try fonts.font(gpa, gold.font);
        defer gpa.free(data);
        const face = try Face.init(data, 0);
        var fi = try instance.FaceInstance.initNormalized(gpa, &face, gold.coords);
        defer fi.deinit(gpa);
        for (gold.glyphs) |e| {
            p.reset();
            try fi.outline(gpa, e.gid, &scratch, &p);
            var w: std.Io.Writer.Allocating = .init(gpa);
            defer w.deinit();
            try p.format(&w.writer);
            glyf_test.expectPathsClose(e.path, w.written()) catch |err| {
                std.debug.print("{s} {s}:\n want {s}\n got  {s}\n", .{ file, e.name, e.path, w.written() });
                return err;
            };
        }
    }
}

test "all glyphs of the CFF fonts decode; cid fdselect; blend at default" {
    const gpa = testing.allocator;
    var p: Path = .{};
    defer p.deinit(gpa);
    for ([_][]const u8{ "SourceSerif4-Regular.otf", "SourceHanSansJP-Subset.otf", "SourceSerif4Variable-Roman.otf" }) |name| {
        const data = try fonts.font(gpa, name);
        defer gpa.free(data);
        const face = try Face.init(data, 0);
        const c = face.cff().?;
        try testing.expectEqual(@as(u32, face.num_glyphs), c.glyphCount());
        const zeros = try gpa.alloc(f32, if (c.store) |s| s.region_count else 0);
        defer gpa.free(zeros);
        @memset(zeros, 0);
        var q: Path = .{};
        defer q.deinit(gpa);
        for (0..face.num_glyphs) |gid| {
            p.reset();
            try c.outline(@intCast(gid), null, &p, gpa);
            if (c.version == .cff2) {
                // Blending with all-zero scalars is the default instance.
                q.reset();
                try c.outline(@intCast(gid), .{ .scalars = zeros }, &q, gpa);
                try testing.expectEqualSlices([2]f32, p.points.items, q.points.items);
            }
        }
        if (c.fd_select != null and c.version == .cff1) {
            // The CID font maps glyphs to more than one Font DICT.
            var seen: [4]bool = @splat(false);
            for (0..face.num_glyphs) |gid| seen[@min(3, try c.fdIndex(@intCast(gid)))] = true;
            try testing.expect(seen[0] and seen[1]);
        }
    }
}

test "fuzz: ot-cff" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [600]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            try fuzzOne(input);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "ot-cff") });
}

/// Input: one version byte (even = CFF1) then the table, or, with version
/// byte 0xFF, a raw charstring run inside a fixed CFF1 shell.
fn fuzzOne(input: []const u8) !void {
    if (input.len < 2) return;
    const gpa = testing.allocator;
    var p: Path = .{};
    defer p.deinit(gpa);
    if (input[0] == 0xFF) {
        const table = try buildCff(gpa, &.{ input[1..], empty_glyph }, &.{ input[1..], empty_glyph }, &.{input[1..]});
        defer gpa.free(table);
        const c = Cff.init(table, .cff1) catch return;
        for (0..2) |g| {
            p.reset();
            c.outline(@intCast(g), null, &p, gpa) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => {},
            };
        }
        return;
    }
    const version: cff.Version = if (input[0] % 2 == 0) .cff1 else .cff2;
    const c = Cff.init(input[1..], version) catch return;
    const scalars = [_]f32{ 0.5, 1, 0.25, 0 } ** 4;
    for (0..@min(c.glyphCount(), 8)) |g| {
        for ([_]?cff.BlendCtx{ null, .{ .scalars = &scalars } }) |b| {
            p.reset();
            c.outline(@intCast(g), b, &p, gpa) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => {},
            };
        }
    }
}
