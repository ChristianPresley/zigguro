//! Display width in terminal cells: per code point (wcwidth, Kuhn
//! semantics over the generated tables) and per grapheme cluster (mode
//! 2027 rules: emoji presentation selectors, ZWJ sequences, flags). No
//! allocation.

const std = @import("std");
const p = @import("props.zig");
const decode = @import("decode.zig");
const grapheme = @import("grapheme.zig");

/// Width options.
pub const WidthOptions = struct {
    /// East_Asian_Width=A characters take two cells (CJK legacy terminals).
    ambiguous_wide: bool = false,
};

/// Cells for `cp`: -1 for C0/C1 controls and DEL, 0 for NUL, combining and
/// format characters, Hangul medial/final Jamo and default-ignorables, 2
/// for East_Asian_Width W/F (including emoji presentation and unassigned
/// ideographic ranges), ambiguous per `o`, otherwise 1.
pub fn wcwidth(cp: u21, o: WidthOptions) i8 {
    if (cp >= 0x20 and cp < 0x7F) return 1;
    if (cp == 0) return 0;
    if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return -1;
    if (cp == 0xAD) return 1; // SOFT HYPHEN
    const x = p.props(cp);
    switch (x.gc) {
        .Mn, .Me, .Cf => return 0,
        else => {},
    }
    if ((cp >= 0x1160 and cp <= 0x11FF) or (cp >= 0xD7B0 and cp <= 0xD7FF)) return 0;
    if (cp == 0x200B or p.aux(cp).default_ignorable) return 0;
    return switch (x.eaw) {
        .W, .F => 2,
        .A => if (o.ambiguous_wide) 2 else 1,
        else => 1,
    };
}

/// Cells for one grapheme cluster (0..2): the width of its first
/// non-zero-width code point, 2 with VS16 after an emoji variation base,
/// 1 with VS15, 2 for a regional-indicator pair or an emoji ZWJ sequence;
/// clamped to 2.
pub fn graphemeWidth(cluster: []const u8, o: WidthOptions) u2 {
    if (cluster.len == 0) return 0;
    if (cluster.len == 1) {
        const c = cluster[0];
        return if (c >= 0x20 and c < 0x7F) 1 else 0;
    }
    var w: i8 = 0;
    var first: ?u21 = null;
    var ri: u8 = 0;
    var vs15 = false;
    var vs16 = false;
    var zwj = false;
    var i: usize = 0;
    while (i < cluster.len) {
        const u = decode.at(cluster, i);
        i += u.len;
        const cp: u21 = if (u.valid) u.cp else 0xFFFD;
        if (first == null) first = cp;
        switch (cp) {
            0xFE0E => vs15 = true,
            0xFE0F => vs16 = true,
            0x200D => zwj = true,
            0x1F1E6...0x1F1FF => ri += 1,
            else => {},
        }
        if (w <= 0) w = wcwidth(cp, o);
    }
    const base = first.?;
    if (p.isEmojiVariationBase(base)) {
        if (vs16) return 2;
        if (vs15) return 1;
    }
    if (ri >= 2) return 2;
    if (zwj and p.props(base).ext_pict) return 2;
    return @intCast(std.math.clamp(w, 0, 2));
}

/// Width mode for `stringWidth`.
pub const Mode = enum { codepoint, grapheme };

/// Total cells of `bytes`: the sum of non-negative `wcwidth` values, or of
/// `graphemeWidth` over grapheme clusters.
pub fn stringWidth(bytes: []const u8, o: WidthOptions, mode: Mode) usize {
    var total: usize = 0;
    switch (mode) {
        .codepoint => {
            var i: usize = 0;
            while (i < bytes.len) {
                const c = bytes[i];
                if (c >= 0x20 and c < 0x7F) {
                    total += 1;
                    i += 1;
                    continue;
                }
                const u = decode.at(bytes, i);
                i += u.len;
                total += @intCast(@max(0, wcwidth(if (u.valid) u.cp else 0xFFFD, o)));
            }
        },
        .grapheme => {
            var it = grapheme.Iterator.init(bytes);
            while (it.next()) |span| total += graphemeWidth(bytes[span.start..][0..span.len], o);
        },
    }
    return total;
}

test {
    _ = @import("width_test.zig");
}
