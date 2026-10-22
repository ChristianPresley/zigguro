//! Fuzz targets for GSUB and GPOS application on hostile tables.
//!
//! Input: u16 GDEF length, the GDEF bytes, a u8 glyph count, that many
//! u16 glyph ids, then the GSUB or GPOS table. Every lookup is applied in
//! index order over the glyphs. Invariants: no crash or hang (the op
//! budget bounds the work) and clusters stay non-decreasing.

const std = @import("std");
const testing = std.testing;
const ot = @import("../ot/root.zig");
const lc = @import("../ot/layout_common.zig");
const Gdef = @import("../ot/gdef.zig").Gdef;
const buffer = @import("buffer.zig");
const Buffer = buffer.Buffer;
const skippy = @import("skippy.zig");
const apply_gsub = @import("apply_gsub.zig");
const apply_gpos = @import("apply_gpos.zig");

const max_lookups = 96;

const Parsed = struct { gdef: Gdef, glyphs: []const u8, table: []const u8 };

fn split(input: []const u8) ?Parsed {
    if (input.len < 3) return null;
    const gdef_len = std.mem.readInt(u16, input[0..2], .big);
    if (2 + @as(usize, gdef_len) + 1 > input.len) return null;
    const gdef_bytes = input[2..][0..gdef_len];
    const n = input[2 + gdef_len];
    const glyph_start = 3 + @as(usize, gdef_len);
    if (glyph_start + @as(usize, n) * 2 > input.len) return null;
    return .{
        .gdef = Gdef.init(gdef_bytes) catch .{},
        .glyphs = input[glyph_start..][0 .. @as(usize, n) * 2],
        .table = input[glyph_start + @as(usize, n) * 2 ..],
    };
}

fn fill(b: *Buffer, p: Parsed) !void {
    var i: usize = 0;
    while (i < p.glyphs.len) : (i += 2) {
        const gid = std.mem.readInt(u16, p.glyphs[i..][0..2], .big);
        try b.infos.append(b.gpa, .{
            .gid = gid,
            .cluster = @intCast(i / 2),
            .cp = 'a',
            .mask = 1,
            .glyph_props = if (p.gdef.has_glyph_classes) p.gdef.glyphProps(gid) else 0,
        });
    }
    try b.pos.appendNTimes(b.gpa, .{ .x_adv = 500 }, b.len());
}

fn expectMonotonic(b: *const Buffer) !void {
    const infos = b.infos.items;
    if (infos.len < 2) return; // GSUB may delete every glyph
    for (1..infos.len) |i| try testing.expect(infos[i - 1].cluster <= infos[i].cluster);
}

fn fuzzGsub(input: []const u8) !void {
    const p = split(input) orelse return;
    const table = lc.LayoutTable.init(p.table) catch return;
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try fill(&b, p);
    var budget = skippy.OpBudget.init(b.len());
    var c: skippy.Ctx = .{ .buf = &b, .table = table, .kind = .gsub, .gdef = &p.gdef, .budget = &budget };
    var li: u16 = 0;
    while (li < @min(table.lookup_count, max_lookups)) : (li += 1) {
        try apply_gsub.applyLookup(&c, li);
        if (budget.exhausted) break;
    }
    try expectMonotonic(&b);
    for (b.infos.items) |g| try testing.expect(g.cluster < 256);
}

fn fuzzGpos(input: []const u8) !void {
    const p = split(input) orelse return;
    const table = lc.LayoutTable.init(p.table) catch return;
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try fill(&b, p);
    const n = b.len();
    for ([_]buffer.Direction{ .ltr, .rtl }) |dir| {
        for (b.pos.items) |*q| q.* = .{ .x_adv = 500 };
        b.has_attachments = false;
        var budget = skippy.OpBudget.init(n);
        var c: skippy.Ctx = .{ .buf = &b, .table = table, .kind = .gpos, .gdef = &p.gdef, .budget = &budget, .rtl = dir == .rtl };
        var li: u16 = 0;
        while (li < @min(table.lookup_count, max_lookups)) : (li += 1) {
            try apply_gpos.applyLookup(&c, li);
            if (budget.exhausted) break;
        }
        apply_gpos.resolveAttachments(&b, dir);
        try testing.expectEqual(n, b.len());
        for (b.pos.items) |q| try testing.expectEqual(@as(i16, 0), q.attach_chain);
    }
}

test "fuzz: shape-gsub" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [32768]u8 = undefined;
            try fuzzGsub(buf[0..s.slice(&buf)]);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "shape-gsub") });
}

test "fuzz: shape-gpos" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [32768]u8 = undefined;
            try fuzzGpos(buf[0..s.slice(&buf)]);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "shape-gpos") });
}

test "fuzz seeds apply cleanly" {
    // The corpus seeds are real fonts' tables: GSUB changes something.
    const corpus = @import("zg_corpus");
    for (@field(corpus, "shape-gsub")) |seed| try fuzzGsub(seed);
    for (@field(corpus, "shape-gpos")) |seed| try fuzzGpos(seed);
}
