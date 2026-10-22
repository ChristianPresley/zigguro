//! Interim Unicode width and grapheme-break tables for the print path.
//!
//! These are hand-written approximations of E03's generated tables (EAW
//! W/F ranges, the common zero-width ranges and a reduced UAX #29 rule set:
//! GB6-GB9a, GB9c for Devanagari, GB11 and GB12/13). They exist only until
//! zg_text lands `unicode.width` (E03.F05.S04.T05, #353) and the streaming
//! grapheme iterator (E03.F05.S02.T02, #345); the signatures mirror those
//! interfaces so the swap is mechanical. Do not extend them beyond that.

const std = @import("std");

/// Width options (mirrors `zg_text.unicode.width.WidthOptions`).
pub const WidthOptions = struct {
    /// Treat East Asian Ambiguous characters as wide.
    ambiguous_wide: bool = false,
};

const Range = struct { u21, u21 };

fn inRanges(cp: u21, comptime rs: []const Range) bool {
    // Binary search over sorted, non-overlapping ranges.
    var lo: usize = 0;
    var hi: usize = rs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < rs[mid][0]) {
            hi = mid;
        } else if (cp > rs[mid][1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

const zero_width = [_]Range{
    .{ 0x0300, 0x036F }, .{ 0x0483, 0x0489 },   .{ 0x0591, 0x05BD },   .{ 0x05BF, 0x05BF },
    .{ 0x05C1, 0x05C2 }, .{ 0x05C4, 0x05C5 },   .{ 0x05C7, 0x05C7 },   .{ 0x0610, 0x061A },
    .{ 0x064B, 0x065F }, .{ 0x0670, 0x0670 },   .{ 0x06D6, 0x06DC },   .{ 0x06DF, 0x06E4 },
    .{ 0x06E7, 0x06E8 }, .{ 0x06EA, 0x06ED },   .{ 0x0900, 0x0902 },   .{ 0x093A, 0x093A },
    .{ 0x093C, 0x093C }, .{ 0x0941, 0x0948 },   .{ 0x094D, 0x094D },   .{ 0x0951, 0x0957 },
    .{ 0x0962, 0x0963 }, .{ 0x0E31, 0x0E31 },   .{ 0x0E34, 0x0E3A },   .{ 0x0E47, 0x0E4E },
    .{ 0x1160, 0x11FF }, .{ 0x1AB0, 0x1AFF },   .{ 0x1DC0, 0x1DFF },   .{ 0x200B, 0x200F },
    .{ 0x2028, 0x202E }, .{ 0x2060, 0x2064 },   .{ 0x20D0, 0x20FF },   .{ 0x302A, 0x302D },
    .{ 0x3099, 0x309A }, .{ 0xD7B0, 0xD7FF },   .{ 0xFE00, 0xFE0F },   .{ 0xFE20, 0xFE2F },
    .{ 0xFEFF, 0xFEFF }, .{ 0x1F3FB, 0x1F3FF }, .{ 0xE0000, 0xE0FFF },
};

const wide = [_]Range{
    .{ 0x1100, 0x115F },   .{ 0x231A, 0x231B },   .{ 0x2329, 0x232A },   .{ 0x23E9, 0x23EC },
    .{ 0x23F0, 0x23F0 },   .{ 0x23F3, 0x23F3 },   .{ 0x25FD, 0x25FE },   .{ 0x2614, 0x2615 },
    .{ 0x2648, 0x2653 },   .{ 0x267F, 0x267F },   .{ 0x2693, 0x2693 },   .{ 0x26A1, 0x26A1 },
    .{ 0x26AA, 0x26AB },   .{ 0x26BD, 0x26BE },   .{ 0x26C4, 0x26C5 },   .{ 0x26CE, 0x26CE },
    .{ 0x26D4, 0x26D4 },   .{ 0x26EA, 0x26EA },   .{ 0x26F2, 0x26F3 },   .{ 0x26F5, 0x26F5 },
    .{ 0x26FA, 0x26FA },   .{ 0x26FD, 0x26FD },   .{ 0x2705, 0x2705 },   .{ 0x270A, 0x270B },
    .{ 0x2728, 0x2728 },   .{ 0x274C, 0x274C },   .{ 0x274E, 0x274E },   .{ 0x2753, 0x2755 },
    .{ 0x2757, 0x2757 },   .{ 0x2795, 0x2797 },   .{ 0x27B0, 0x27B0 },   .{ 0x27BF, 0x27BF },
    .{ 0x2B1B, 0x2B1C },   .{ 0x2B50, 0x2B50 },   .{ 0x2B55, 0x2B55 },   .{ 0x2E80, 0x3029 },
    .{ 0x302E, 0x303E },   .{ 0x3041, 0x3098 },   .{ 0x309B, 0x33FF },   .{ 0x3400, 0x4DBF },
    .{ 0x4E00, 0x9FFF },   .{ 0xA000, 0xA4CF },   .{ 0xA960, 0xA97F },   .{ 0xAC00, 0xD7A3 },
    .{ 0xF900, 0xFAFF },   .{ 0xFE10, 0xFE19 },   .{ 0xFE30, 0xFE6F },   .{ 0xFF00, 0xFF60 },
    .{ 0xFFE0, 0xFFE6 },   .{ 0x16FE0, 0x16FE4 }, .{ 0x17000, 0x18AFF }, .{ 0x1B000, 0x1B2FF },
    .{ 0x1F004, 0x1F004 }, .{ 0x1F0CF, 0x1F0CF }, .{ 0x1F18E, 0x1F18E }, .{ 0x1F191, 0x1F19A },
    .{ 0x1F200, 0x1F202 }, .{ 0x1F210, 0x1F23B }, .{ 0x1F240, 0x1F248 }, .{ 0x1F250, 0x1F251 },
    .{ 0x1F260, 0x1F265 }, .{ 0x1F300, 0x1F320 }, .{ 0x1F32D, 0x1F335 }, .{ 0x1F337, 0x1F37C },
    .{ 0x1F37E, 0x1F393 }, .{ 0x1F3A0, 0x1F3CA }, .{ 0x1F3CF, 0x1F3D3 }, .{ 0x1F3E0, 0x1F3F0 },
    .{ 0x1F3F4, 0x1F3F4 }, .{ 0x1F3F8, 0x1F3FA }, .{ 0x1F400, 0x1F43E }, .{ 0x1F440, 0x1F440 },
    .{ 0x1F442, 0x1F4FC }, .{ 0x1F4FF, 0x1F53D }, .{ 0x1F54B, 0x1F54E }, .{ 0x1F550, 0x1F567 },
    .{ 0x1F57A, 0x1F57A }, .{ 0x1F595, 0x1F596 }, .{ 0x1F5A4, 0x1F5A4 }, .{ 0x1F5FB, 0x1F64F },
    .{ 0x1F680, 0x1F6C5 }, .{ 0x1F6CC, 0x1F6CC }, .{ 0x1F6D0, 0x1F6D2 }, .{ 0x1F6D5, 0x1F6D7 },
    .{ 0x1F6DC, 0x1F6DF }, .{ 0x1F6EB, 0x1F6EC }, .{ 0x1F6F4, 0x1F6FC }, .{ 0x1F7E0, 0x1F7EB },
    .{ 0x1F7F0, 0x1F7F0 }, .{ 0x1F90C, 0x1F93A }, .{ 0x1F93C, 0x1F945 }, .{ 0x1F947, 0x1F9FF },
    .{ 0x1FA70, 0x1FAFF }, .{ 0x20000, 0x2FFFD }, .{ 0x30000, 0x3FFFD },
};

const ambiguous = [_]Range{
    .{ 0x00A1, 0x00A1 }, .{ 0x00A7, 0x00A8 }, .{ 0x00B0, 0x00B4 }, .{ 0x00B6, 0x00BA },
    .{ 0x00BC, 0x00BF }, .{ 0x00D7, 0x00D7 }, .{ 0x00F7, 0x00F7 }, .{ 0x0391, 0x03A9 },
    .{ 0x03B1, 0x03C9 }, .{ 0x0401, 0x0451 }, .{ 0x2010, 0x2027 }, .{ 0x2030, 0x203E },
    .{ 0x2190, 0x21FF }, .{ 0x2200, 0x22FF }, .{ 0x2460, 0x24FF }, .{ 0x2500, 0x257F },
    .{ 0x2580, 0x25FC }, .{ 0x2600, 0x2613 }, .{ 0xE000, 0xF8FF },
};

const ext_pict = [_]Range{
    .{ 0x00A9, 0x00A9 },   .{ 0x00AE, 0x00AE },   .{ 0x203C, 0x203C },   .{ 0x2049, 0x2049 },
    .{ 0x2122, 0x2122 },   .{ 0x2139, 0x2139 },   .{ 0x2194, 0x2199 },   .{ 0x21A9, 0x21AA },
    .{ 0x231A, 0x231B },   .{ 0x2328, 0x2328 },   .{ 0x23CF, 0x23CF },   .{ 0x23E9, 0x23F3 },
    .{ 0x23F8, 0x23FA },   .{ 0x24C2, 0x24C2 },   .{ 0x25AA, 0x25AB },   .{ 0x25B6, 0x25B6 },
    .{ 0x25C0, 0x25C0 },   .{ 0x25FB, 0x25FE },   .{ 0x2600, 0x27BF },   .{ 0x2934, 0x2935 },
    .{ 0x2B05, 0x2B07 },   .{ 0x2B1B, 0x2B1C },   .{ 0x2B50, 0x2B50 },   .{ 0x2B55, 0x2B55 },
    .{ 0x3030, 0x3030 },   .{ 0x303D, 0x303D },   .{ 0x3297, 0x3297 },   .{ 0x3299, 0x3299 },
    .{ 0x1F000, 0x1F1E5 }, .{ 0x1F200, 0x1F3FA }, .{ 0x1F400, 0x1FAFF }, .{ 0x1FC00, 0x1FFFD },
};

const spacing_mark = [_]Range{
    .{ 0x0903, 0x0903 }, .{ 0x093B, 0x093B }, .{ 0x093E, 0x0940 }, .{ 0x0949, 0x094C },
    .{ 0x094E, 0x094F }, .{ 0x0E33, 0x0E33 },
};

/// Per-code-point cell width: -1 for controls, 0, 1 or 2.
pub fn wcwidth(cp: u21, o: WidthOptions) i8 {
    if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return -1;
    if (cp < 0x300) return if (o.ambiguous_wide and inRanges(cp, &ambiguous)) 2 else 1;
    if (inRanges(cp, &zero_width)) return 0;
    if (inRanges(cp, &wide)) return 2;
    if (o.ambiguous_wide and inRanges(cp, &ambiguous)) return 2;
    return 1;
}

fn isRegional(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

/// Cell width of a whole grapheme cluster (mode 2027 semantics).
pub fn graphemeWidth(cluster: []const u21, o: WidthOptions) u2 {
    if (cluster.len == 0) return 0;
    const base_w = wcwidth(cluster[0], o);
    if (isRegional(cluster[0])) return if (cluster.len >= 2 and isRegional(cluster[1])) 2 else 1;
    for (cluster[1..]) |cp| {
        if (cp == 0xFE0F) return 2; // VS16: emoji presentation
        if (cp == 0xFE0E) return @intCast(@min(1, @max(0, base_w))); // VS15: text presentation
    }
    return @intCast(@max(0, base_w));
}

const Hangul = enum { none, l, v, t, lv, lvt };

fn hangul(cp: u21) Hangul {
    if ((cp >= 0x1100 and cp <= 0x115F) or (cp >= 0xA960 and cp <= 0xA97C)) return .l;
    if ((cp >= 0x1160 and cp <= 0x11A7) or (cp >= 0xD7B0 and cp <= 0xD7C6)) return .v;
    if ((cp >= 0x11A8 and cp <= 0x11FF) or (cp >= 0xD7CB and cp <= 0xD7FB)) return .t;
    if (cp >= 0xAC00 and cp <= 0xD7A3) return if ((cp - 0xAC00) % 28 == 0) .lv else .lvt;
    return .none;
}

fn isExtend(cp: u21) bool {
    return cp != 0x200D and cp >= 0x300 and (inRanges(cp, &zero_width) or (cp >= 0x1F3FB and cp <= 0x1F3FF));
}

fn isDevaConsonant(cp: u21) bool {
    return (cp >= 0x0915 and cp <= 0x0939) or (cp >= 0x0958 and cp <= 0x095F);
}

/// Streaming grapheme-break state (mirrors E03's `BreakState`).
pub const BreakState = struct {
    /// Count of consecutive regional indicators, mod 2.
    ri_odd: bool = false,
    /// Inside `ExtPict Extend*`, optionally followed by ZWJ.
    emoji: enum { none, pict, zwj } = .none,
    /// GB9c: consonant (Extend|Linker)* seen; `linked` once a virama occurred.
    incb: enum { none, consonant, linked } = .none,
};

/// Whether there is a grapheme boundary between `prev` and `next`, updating
/// `st` (which must describe the text up to and including `prev`).
pub fn isBreak(st: *BreakState, prev: u21, next: u21) bool {
    const brk = decide(st, prev, next);
    // Update state for `next`.
    if (isRegional(next)) {
        st.ri_odd = if (isRegional(prev) and !brk) false else true;
    } else st.ri_odd = false;
    if (inRanges(next, &ext_pict)) {
        st.emoji = .pict;
    } else if (st.emoji != .none and !brk and next == 0x200D) {
        st.emoji = .zwj;
    } else if (st.emoji == .pict and !brk and isExtend(next)) {
        st.emoji = .pict;
    } else st.emoji = .none;
    if (isDevaConsonant(next)) {
        st.incb = .consonant;
    } else if (st.incb != .none and !brk and next == 0x094D) {
        st.incb = .linked;
    } else if (st.incb != .none and !brk and (isExtend(next) or next == 0x200D)) {
        // keep
    } else st.incb = .none;
    return brk;
}

fn decide(st: *const BreakState, prev: u21, next: u21) bool {
    const hp = hangul(prev);
    const hn = hangul(next);
    if (hp == .l and (hn == .l or hn == .v or hn == .lv or hn == .lvt)) return false; // GB6
    if ((hp == .lv or hp == .v) and (hn == .v or hn == .t)) return false; // GB7
    if ((hp == .lvt or hp == .t) and hn == .t) return false; // GB8
    if (isExtend(next) or next == 0x200D) return false; // GB9
    if (inRanges(next, &spacing_mark)) return false; // GB9a
    if (st.incb == .linked and isDevaConsonant(next)) return false; // GB9c
    if (prev == 0x200D and st.emoji == .zwj and inRanges(next, &ext_pict)) return false; // GB11
    if (isRegional(prev) and isRegional(next) and st.ri_odd) return false; // GB12/13
    return true;
}

fn clusters(cps: []const u21, out: []usize) []usize {
    var st: BreakState = .{};
    _ = isBreak(&st, 0, cps[0]);
    var n: usize = 0;
    var len: usize = 1;
    for (cps[1..], 0..) |cp, i| {
        if (isBreak(&st, cps[i], cp)) {
            out[n] = len;
            n += 1;
            len = 1;
        } else len += 1;
    }
    out[n] = len;
    return out[0 .. n + 1];
}

test "cluster boundaries for common sequences" {
    var buf: [16]usize = undefined;
    const farmer = [_]u21{ 0x1F9D1, 0x200D, 0x1F33E };
    try std.testing.expectEqualSlices(usize, &.{3}, clusters(&farmer, &buf));
    const flags = [_]u21{ 0x1F1FA, 0x1F1F8, 0x1F1EB, 0x1F1F7 };
    try std.testing.expectEqualSlices(usize, &.{ 2, 2 }, clusters(&flags, &buf));
    const thumbs = [_]u21{ 0x1F44D, 0x1F3FD, 'a' };
    try std.testing.expectEqualSlices(usize, &.{ 2, 1 }, clusters(&thumbs, &buf));
    const jamo = [_]u21{ 0x1112, 0x1161, 0x11AB };
    try std.testing.expectEqualSlices(usize, &.{3}, clusters(&jamo, &buf));
    const ksi = [_]u21{ 0x0915, 0x094D, 0x0937, 0x093F };
    try std.testing.expectEqualSlices(usize, &.{4}, clusters(&ksi, &buf));
    const ab = [_]u21{ 'a', 'b', 0x301 };
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, clusters(&ab, &buf));
}

test "widths" {
    try std.testing.expectEqual(@as(i8, 2), wcwidth(0x65E5, .{}));
    try std.testing.expectEqual(@as(i8, 0), wcwidth(0x301, .{}));
    try std.testing.expectEqual(@as(i8, 1), wcwidth(0x2764, .{}));
    try std.testing.expectEqual(@as(u2, 2), graphemeWidth(&.{ 0x2764, 0xFE0F }, .{}));
    try std.testing.expectEqual(@as(u2, 1), graphemeWidth(&.{ 0x2764, 0xFE0E }, .{}));
    try std.testing.expectEqual(@as(u2, 2), graphemeWidth(&.{ 0x1F1EF, 0x1F1F5 }, .{}));
    try std.testing.expectEqual(@as(i8, 2), wcwidth(0x00B0, .{ .ambiguous_wide = true }));
}
