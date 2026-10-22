//! Vowel constraints (HarfBuzz's `_hb_preprocess_text_vowel_constraints`,
//! from Microsoft's IndicShapingInvalidCluster.txt): an independent vowel
//! followed by a sign that makes it look like another vowel (DEVANAGARI
//! A + AA looks like AA) is a spelling the USE and Indic specs discourage,
//! so a dotted circle goes before the sign, as for a broken cluster. Runs
//! on the characters before normalization, for the buffer's script. The
//! table is Microsoft's data (MIT, see `ucd/ms-use/LICENSE`) grouped by
//! script.

const std = @import("std");
const Allocator = std.mem.Allocator;
const plan_mod = @import("../plan.zig");
const ShapePlan = plan_mod.ShapePlan;
const buffer = @import("../buffer.zig");
const Buffer = buffer.Buffer;
const GlyphInfo = buffer.GlyphInfo;
const Script = @import("../../unicode/root.zig").Script;

const Constraints = struct { script: Script, seqs: []const []const u21 };

/// The prohibited sequences by the script of their first character. No
/// sequence is a prefix of another.
const constraints = [_]Constraints{
    .{ .script = .Deva, .seqs = &.{
        &.{ 0x0905, 0x093A },
        &.{ 0x0905, 0x093B },
        &.{ 0x0905, 0x093E },
        &.{ 0x0905, 0x0945 },
        &.{ 0x0905, 0x0946 },
        &.{ 0x0905, 0x0949 },
        &.{ 0x0905, 0x094A },
        &.{ 0x0905, 0x094B },
        &.{ 0x0905, 0x094C },
        &.{ 0x0905, 0x094F },
        &.{ 0x0905, 0x0956 },
        &.{ 0x0905, 0x0957 },
        &.{ 0x0906, 0x093A },
        &.{ 0x0906, 0x0945 },
        &.{ 0x0906, 0x0946 },
        &.{ 0x0906, 0x0947 },
        &.{ 0x0906, 0x0948 },
        &.{ 0x0909, 0x0941 },
        &.{ 0x090F, 0x0945 },
        &.{ 0x090F, 0x0946 },
        &.{ 0x090F, 0x0947 },
        &.{ 0x0930, 0x094D, 0x0907 },
    } },
    .{ .script = .Beng, .seqs = &.{
        &.{ 0x0985, 0x09BE },
        &.{ 0x098B, 0x09C3 },
        &.{ 0x098C, 0x09E2 },
    } },
    .{ .script = .Guru, .seqs = &.{
        &.{ 0x0A05, 0x0A3E },
        &.{ 0x0A05, 0x0A48 },
        &.{ 0x0A05, 0x0A4C },
        &.{ 0x0A72, 0x0A3F },
        &.{ 0x0A72, 0x0A40 },
        &.{ 0x0A72, 0x0A47 },
        &.{ 0x0A73, 0x0A41 },
        &.{ 0x0A73, 0x0A42 },
        &.{ 0x0A73, 0x0A4B },
    } },
    .{ .script = .Gujr, .seqs = &.{
        &.{ 0x0A85, 0x0ABE },
        &.{ 0x0A85, 0x0AC5 },
        &.{ 0x0A85, 0x0AC7 },
        &.{ 0x0A85, 0x0AC8 },
        &.{ 0x0A85, 0x0AC9 },
        &.{ 0x0A85, 0x0ACB },
        &.{ 0x0A85, 0x0ACC },
        &.{ 0x0AC5, 0x0ABE },
    } },
    .{ .script = .Orya, .seqs = &.{
        &.{ 0x0B05, 0x0B3E },
        &.{ 0x0B0F, 0x0B57 },
        &.{ 0x0B13, 0x0B57 },
    } },
    .{ .script = .Taml, .seqs = &.{
        &.{ 0x0B85, 0x0BC2 },
    } },
    .{ .script = .Telu, .seqs = &.{
        &.{ 0x0C12, 0x0C4C },
        &.{ 0x0C12, 0x0C55 },
        &.{ 0x0C3F, 0x0C55 },
        &.{ 0x0C46, 0x0C55 },
        &.{ 0x0C4A, 0x0C55 },
    } },
    .{ .script = .Knda, .seqs = &.{
        &.{ 0x0C89, 0x0CBE },
        &.{ 0x0C8B, 0x0CBE },
        &.{ 0x0C92, 0x0CCC },
    } },
    .{ .script = .Mlym, .seqs = &.{
        &.{ 0x0D07, 0x0D57 },
        &.{ 0x0D09, 0x0D57 },
        &.{ 0x0D0E, 0x0D46 },
        &.{ 0x0D12, 0x0D3E },
        &.{ 0x0D12, 0x0D57 },
    } },
    .{ .script = .Sinh, .seqs = &.{
        &.{ 0x0D85, 0x0DCF },
        &.{ 0x0D85, 0x0DD0 },
        &.{ 0x0D85, 0x0DD1 },
        &.{ 0x0D8B, 0x0DDF },
        &.{ 0x0D8D, 0x0DD8 },
        &.{ 0x0D8F, 0x0DDF },
        &.{ 0x0D91, 0x0DCA },
        &.{ 0x0D91, 0x0DD9 },
        &.{ 0x0D91, 0x0DDA },
        &.{ 0x0D91, 0x0DDC },
        &.{ 0x0D91, 0x0DDD },
        &.{ 0x0D91, 0x0DDE },
        &.{ 0x0D94, 0x0DDF },
    } },
    .{ .script = .Brah, .seqs = &.{
        &.{ 0x11005, 0x11038 },
        &.{ 0x1100B, 0x1103E },
        &.{ 0x1100F, 0x11042 },
    } },
    .{ .script = .Takr, .seqs = &.{
        &.{ 0x11680, 0x116AD },
        &.{ 0x11680, 0x116B4 },
        &.{ 0x11680, 0x116B5 },
        &.{ 0x11686, 0x116B2 },
    } },
    .{ .script = .Khoj, .seqs = &.{
        &.{ 0x11200, 0x1122C },
        &.{ 0x11200, 0x11231 },
        &.{ 0x11200, 0x11233 },
        &.{ 0x11206, 0x1122C },
        &.{ 0x1122C, 0x11230 },
        &.{ 0x1122C, 0x11231 },
        &.{ 0x11240, 0x1122E },
    } },
    .{ .script = .Sind, .seqs = &.{
        &.{ 0x112B0, 0x112E0 },
        &.{ 0x112B0, 0x112E5 },
        &.{ 0x112B0, 0x112E6 },
        &.{ 0x112B0, 0x112E7 },
        &.{ 0x112B0, 0x112E8 },
    } },
    .{ .script = .Tirh, .seqs = &.{
        &.{ 0x11481, 0x114B0 },
        &.{ 0x1148B, 0x114BA },
        &.{ 0x1148D, 0x114BA },
        &.{ 0x114AA, 0x114B5 },
        &.{ 0x114AA, 0x114B6 },
    } },
    .{ .script = .Modi, .seqs = &.{
        &.{ 0x11600, 0x11639 },
        &.{ 0x11600, 0x1163A },
        &.{ 0x11601, 0x11639 },
        &.{ 0x11601, 0x1163A },
    } },
};

fn forScript(s: Script) ?[]const []const u21 {
    for (constraints) |c| if (c.script == s) return c.seqs;
    return null;
}

/// The length of the prohibited sequence at `infos[i..]`, or 0.
fn matchAt(seqs: []const []const u21, infos: []const GlyphInfo, i: usize) usize {
    outer: for (seqs) |s| {
        if (i + s.len > infos.len) continue;
        for (s, infos[i .. i + s.len]) |cp, g| if (g.cp != cp) continue :outer;
        return s.len;
    }
    return 0;
}

/// Inserts a dotted circle before the last character of each prohibited
/// sequence. The circle copies that character's properties and cluster,
/// as HarfBuzz's does.
pub fn preprocess(p: *const ShapePlan, b: *Buffer) Allocator.Error!void {
    const seqs = forScript(p.script) orelse return;
    const infos = b.infos.items;
    const found = for (0..infos.len -| 1) |i| {
        if (matchAt(seqs, infos, i) != 0) break true;
    } else false;
    if (!found) return;
    b.out.clearRetainingCapacity();
    var i: usize = 0;
    while (i + 1 < infos.len) {
        const n = matchAt(seqs, infos, i);
        if (n == 0) {
            try b.out.append(b.gpa, infos[i]);
            i += 1;
            continue;
        }
        try b.out.appendSlice(b.gpa, infos[i .. i + n - 1]);
        var circle = infos[i + n - 1];
        circle.cp = 0x25CC;
        try b.out.append(b.gpa, circle);
        try b.out.append(b.gpa, infos[i + n - 1]);
        i += n;
    }
    try b.out.appendSlice(b.gpa, infos[i..]);
    b.swapOut();
}

test "vowel constraint table is prefix-free" {
    for (constraints) |c| for (c.seqs, 0..) |a, i| for (c.seqs, 0..) |x, j| {
        if (i == j or x.len > a.len) continue;
        try std.testing.expect(!std.mem.eql(u21, a[0..x.len], x));
    };
}
