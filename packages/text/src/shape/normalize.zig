//! Font-aware normalization before GSUB (HarfBuzz's "composed diacritics"
//! mode): decompose what the font lacks, sort marks by combining class,
//! then recompose what the font has. Every glyph leaves with its nominal
//! glyph id.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ot = @import("../ot/root.zig");
const Face = ot.Face;
const GlyphId = ot.GlyphId;
const ucd = @import("../unicode/props.zig");
const buffer = @import("buffer.zig");
const Buffer = buffer.Buffer;
const GlyphInfo = buffer.GlyphInfo;
const SpaceFallback = buffer.SpaceFallback;

/// Longest mark run that is sorted (HarfBuzz's limit).
pub const max_combining_marks = 32;

/// Reorders a sorted mark run [start, end) further (Arabic modifier marks).
pub const ReorderFn = *const fn (buf: *Buffer, start: usize, end: usize) void;

const s_base = 0xAC00;
const l_base = 0x1100;
const v_base = 0x1161;
const t_base = 0x11A7;
const l_count = 19;
const v_count = 21;
const t_count = 28;
const n_count = v_count * t_count;
const s_count = l_count * n_count;

const Pair = struct { a: u21, b: u21 };

/// The one-step canonical decomposition of `ab` (`b == 0` for singletons).
pub fn decompose(ab: u21) ?Pair {
    if (ab >= s_base and ab < s_base + s_count) {
        const s = ab - s_base;
        const t = s % t_count;
        if (t != 0) return .{ .a = ab - t, .b = t_base + t };
        return .{ .a = l_base + s / n_count, .b = v_base + (s % n_count) / t_count };
    }
    const full = ucd.decomposeCanonical(ab) orelse return null;
    switch (full.len) {
        0 => return null,
        1 => return .{ .a = full[0], .b = 0 },
        2 => return .{ .a = full[0], .b = full[1] },
        else => {
            // Rebuild the first step: compose all but the last code point.
            var a = full[0];
            for (full[1 .. full.len - 1]) |c| a = ucd.compose(a, c) orelse return null;
            return .{ .a = a, .b = full[full.len - 1] };
        },
    }
}

/// The primary composite of `a` + `b`, Hangul included.
pub fn compose(a: u21, b: u21) ?u21 {
    if (a >= l_base and a < l_base + l_count and b >= v_base and b < v_base + v_count)
        return s_base + ((a - l_base) * v_count + (b - v_base)) * t_count;
    if (a >= s_base and a < s_base + s_count and (a - s_base) % t_count == 0 and b > t_base and b < t_base + t_count)
        return a + (b - t_base);
    return ucd.compose(a, b);
}

const Ctx = struct {
    face: *const Face,
    b: *Buffer,
    idx: usize = 0,

    fn glyph(c: *const Ctx, cp: u21) GlyphId {
        return c.face.glyphIndex(cp);
    }

    fn cur(c: *const Ctx) GlyphInfo {
        return c.b.infos.items[c.idx];
    }

    /// Copies the current glyph to the output with `gid`.
    fn nextChar(c: *Ctx, gid: GlyphId) Allocator.Error!void {
        var g = c.cur();
        g.gid = gid;
        try c.b.out.append(c.b.gpa, g);
        c.idx += 1;
    }

    /// Outputs `cp` (with the current glyph's cluster and mask) without
    /// consuming input.
    fn outputChar(c: *Ctx, cp: u21, gid: GlyphId) Allocator.Error!void {
        var g = c.cur();
        g.cp = cp;
        g.gid = gid;
        buffer.setProps(c.b, &g);
        try c.b.out.append(c.b.gpa, g);
    }

    fn decomposeRec(c: *Ctx, shortest: bool, ab: u21) Allocator.Error!usize {
        const d = decompose(ab) orelse return 0;
        var b_glyph: GlyphId = 0;
        if (d.b != 0) {
            b_glyph = c.glyph(d.b);
            if (b_glyph == 0) return 0;
        }
        const a_glyph = c.glyph(d.a);
        const has_a = a_glyph != 0;
        if (shortest and has_a) {
            try c.outputChar(d.a, a_glyph);
            if (d.b != 0) {
                try c.outputChar(d.b, b_glyph);
                return 2;
            }
            return 1;
        }
        const ret = try c.decomposeRec(shortest, d.a);
        if (ret != 0) {
            if (d.b != 0) {
                try c.outputChar(d.b, b_glyph);
                return ret + 1;
            }
            return ret;
        }
        if (has_a) {
            try c.outputChar(d.a, a_glyph);
            if (d.b != 0) {
                try c.outputChar(d.b, b_glyph);
                return 2;
            }
            return 1;
        }
        return 0;
    }

    fn decomposeCurrent(c: *Ctx, shortest: bool) Allocator.Error!void {
        const u = c.cur().cp;
        const g = c.glyph(u);
        if (shortest and g != 0) return c.nextChar(g);
        if (try c.decomposeRec(shortest, u) != 0) {
            c.idx += 1;
            return;
        }
        if (!shortest and g != 0) return c.nextChar(g);
        if (c.cur().gc == .Zs) {
            const kind = SpaceFallback.of(u);
            const space = c.glyph(' ');
            if (kind != .none and space != 0) {
                c.b.infos.items[c.idx].space = kind;
                return c.nextChar(space);
            }
        }
        if (u == 0x2011) {
            const other = c.glyph(0x2010);
            if (other != 0) return c.nextChar(other);
        }
        return c.nextChar(0);
    }

    fn variationSelectorCluster(c: *Ctx, end: usize) Allocator.Error!void {
        const infos = c.b.infos.items;
        while (c.idx + 1 < end) {
            if (buffer.isVariationSelector(infos[c.idx + 1].cp)) {
                const base = infos[c.idx].cp;
                const vg = c.face.glyphVariant(base, infos[c.idx + 1].cp) orelse 0;
                if (vg != 0) {
                    // Replace base + selector with the variant glyph.
                    var g = infos[c.idx];
                    g.gid = vg;
                    g.cluster = @min(g.cluster, infos[c.idx + 1].cluster);
                    try c.b.out.append(c.b.gpa, g);
                    c.idx += 2;
                } else {
                    // Keep the selector; it is hidden later.
                    try c.nextChar(c.glyph(base));
                    c.b.infos.items[c.idx].uflags |= buffer.UFlags.variation_selector;
                    try c.nextChar(c.glyph(c.cur().cp));
                }
                while (c.idx < end and buffer.isVariationSelector(infos[c.idx].cp)) try c.nextChar(c.glyph(c.cur().cp));
            } else try c.nextChar(c.glyph(infos[c.idx].cp));
        }
        if (c.idx < end) try c.nextChar(c.glyph(c.cur().cp));
    }

    fn multiCharCluster(c: *Ctx, end: usize, shortest: bool) Allocator.Error!void {
        for (c.b.infos.items[c.idx..end]) |g| if (buffer.isVariationSelector(g.cp)) return c.variationSelectorCluster(end);
        while (c.idx < end) try c.decomposeCurrent(shortest);
    }
};

/// Normalizes `b` against `face`'s cmap. `reorder` runs on each sorted
/// mark run.
pub fn normalize(face: *const Face, b: *Buffer, reorder: ?ReorderFn) Allocator.Error!void {
    if (b.len() == 0) return;
    b.out.clearRetainingCapacity();
    try b.out.ensureTotalCapacity(b.gpa, b.len());
    var c: Ctx = .{ .face = face, .b = b };
    const count = b.len();
    var all_simple = true;

    // Round 1: decompose.
    while (c.idx < count) {
        var end = c.idx + 1;
        while (end < count and !b.infos.items[end].isUnicodeMark()) end += 1;
        if (end < count) end -= 1; // leave one base for the marks
        while (c.idx < end) try c.decomposeCurrent(true);
        if (c.idx == count) break;
        all_simple = false;
        end = c.idx + 1;
        while (end < count and b.infos.items[end].isUnicodeMark()) end += 1;
        try c.multiCharCluster(end, false);
    }
    b.swapOut();
    if (all_simple) return;

    // Round 2: sort mark runs by modified combining class.
    {
        const infos = b.infos.items;
        var i: usize = 0;
        while (i < infos.len) : (i += 1) {
            if (infos[i].ccc == 0) continue;
            var end = i + 1;
            while (end < infos.len and infos[end].ccc != 0) end += 1;
            if (end - i <= max_combining_marks) {
                sortMarks(b, i, end);
                if (reorder) |f| f(b, i, end);
            }
            i = end;
        }
    }

    // Round 3: recompose what the font has.
    b.out.clearRetainingCapacity();
    try b.out.ensureTotalCapacity(b.gpa, b.len());
    const infos = b.infos.items;
    const out = &b.out;
    var starter: usize = 0;
    out.appendAssumeCapacity(infos[0]);
    for (infos[1..]) |g| {
        if (g.isUnicodeMark()) {
            const last = out.items[out.items.len - 1];
            if (starter == out.items.len - 1 or last.ccc < g.ccc) {
                if (compose(out.items[starter].cp, g.cp)) |composed| {
                    const gid = face.glyphIndex(composed);
                    if (gid != 0) {
                        const s = &out.items[starter];
                        // Merge clusters of the starter through the mark.
                        var cl = @min(s.cluster, g.cluster);
                        for (out.items[starter..]) |o| cl = @min(cl, o.cluster);
                        for (out.items[starter..]) |*o| o.cluster = cl;
                        s.cp = composed;
                        s.gid = gid;
                        buffer.setProps(b, s);
                        continue;
                    }
                }
            } else if (starter < out.items.len - 1 and last.ccc > g.ccc) {
                starter = out.items.len;
            }
        }
        out.appendAssumeCapacity(g);
        if (g.ccc == 0) starter = out.items.len - 1;
    }
    b.swapOut();
}

fn sortMarks(b: *Buffer, start: usize, end: usize) void {
    const infos = b.infos.items;
    var i = start + 1;
    while (i < end) : (i += 1) {
        var j = i;
        while (j > start and infos[j - 1].ccc > infos[i].ccc) j -= 1;
        if (i == j) continue;
        b.mergeClusters(j, i + 1);
        const t = infos[i];
        std.mem.copyBackwards(GlyphInfo, infos[j + 1 .. i + 1], infos[j..i]);
        infos[j] = t;
    }
}

test "normalize: one-step decompositions" {
    try std.testing.expectEqual(Pair{ .a = 0xE2, .b = 0x303 }, decompose(0x1EAB).?); // ẫ = â + ̃
    try std.testing.expectEqual(Pair{ .a = 'e', .b = 0x301 }, decompose(0xE9).?);
    try std.testing.expectEqual(Pair{ .a = 0x1100, .b = 0x1161 }, decompose(0xAC00).?);
    try std.testing.expectEqual(Pair{ .a = 0xAC00, .b = 0x11A8 }, decompose(0xAC01).?);
    try std.testing.expectEqual(Pair{ .a = 0x3A9, .b = 0 }, decompose(0x2126).?); // Ω (ohm) singleton
    try std.testing.expectEqual(@as(?Pair, null), decompose('a'));
    try std.testing.expectEqual(@as(?u21, 0xAC01), compose(0xAC00, 0x11A8));
    try std.testing.expectEqual(@as(?u21, 0xE9), compose('e', 0x301));
}
