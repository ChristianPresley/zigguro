//! Accessors for the generated Unicode tables (`ucd_tables`, built by
//! tools/ucdgen from the vendored UCD). Everything here is immutable data
//! and may be read from any thread.

const std = @import("std");
const builtin = @import("builtin");
const t = @import("ucd_tables");
const e = @import("ucd_enums");

comptime {
    // The blob is little-endian; every tier-1 target is too.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

pub const Props = e.Props;
pub const Aux = e.Aux;
pub const GeneralCategory = e.GeneralCategory;
pub const GraphemeBreak = e.GraphemeBreak;
pub const IndicConjunctBreak = e.IndicConjunctBreak;
pub const WordBreak = e.WordBreak;
pub const LineBreak = e.LineBreak;
pub const BidiClass = e.BidiClass;
pub const BracketType = e.BracketType;
pub const EastAsianWidth = e.EastAsianWidth;
pub const Script = e.Script;
pub const JoiningType = e.JoiningType;
pub const QuickCheck = e.QuickCheck;
pub const IndicSyllabic = e.IndicSyllabic;
pub const IndicPositional = e.IndicPositional;

/// The Unicode version of the tables.
pub const unicode_version = t.unicode_version;

inline fn sec(comptime T: type, comptime s: t.Section) []const T {
    const p: [*]const T = @ptrCast(@alignCast(&t.blob[s.off]));
    return p[0..s.len];
}

/// The properties of `cp` (any value; > U+10FFFF reads as unassigned).
/// At most three dependent loads; ASCII reads a direct table.
pub inline fn props(cp: u21) Props {
    if (cp < 128) return @bitCast(sec(u64, t.props_ascii)[cp]);
    if (cp > 0x10FFFF) return .{};
    const s1 = sec(u16, t.props_stage1);
    const s2 = sec(u16, t.props_stage2);
    const mask = (1 << t.props_shift) - 1;
    const block: u32 = s1[cp >> t.props_shift];
    return @bitCast(sec(u64, t.props_records)[s2[(block << t.props_shift) | (cp & mask)]]);
}

/// True when every code point of BMP block `block` (`cp >> 6`, < 1024)
/// has ccc 0 and NFC_QC=Y, so the NFC quick check can skip it.
pub inline fn nfcSafeBlock(block: u32) bool {
    return (sec(u64, t.nfc_safe_bmp)[block >> 6] >> @intCast(block & 63)) & 1 != 0;
}

/// The less frequently used properties of `cp`.
pub inline fn aux(cp: u21) Aux {
    if (cp > 0x10FFFF) return .{};
    const s1 = sec(u16, t.aux_stage1);
    const s2 = sec(u16, t.aux_stage2);
    const mask = (1 << t.aux_shift) - 1;
    const block: u32 = s1[cp >> t.aux_shift];
    return @bitCast(sec(u32, t.aux_records)[s2[(block << t.aux_shift) | (cp & mask)]]);
}

const script_count = @typeInfo(Script).@"enum".fields.len;
const all_scripts: [script_count]Script = blk: {
    var a: [script_count]Script = undefined;
    for (&a, 0..) |*s, i| s.* = @enumFromInt(i);
    break :blk a;
};

/// Index of the entry whose key (first u32 of each `stride`-word entry)
/// equals `key`, by binary search.
fn find(data: []const u32, comptime stride: usize, key: u32) ?usize {
    var lo: usize = 0;
    var hi: usize = data.len / stride;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const k = data[mid * stride];
        if (k == key) return mid;
        if (k < key) lo = mid + 1 else hi = mid;
    }
    return null;
}

fn pool(word: u32) []const u21 {
    const p = sec(u21, t.seq_pool);
    return p[word >> 8 ..][0 .. word & 0xFF];
}

/// Script_Extensions of `cp`; when it has none, a one-element slice holding
/// its Script value.
pub fn scriptExtensions(cp: u21) []const Script {
    const r = sec(u32, t.scx_ranges);
    var lo: usize = 0;
    var hi: usize = r.len / 3;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (r[mid * 3 + 1] < cp) lo = mid + 1 else hi = mid;
    }
    if (lo < r.len / 3 and r[lo * 3] <= cp) {
        const w = r[lo * 3 + 2];
        const scripts: []const Script = @ptrCast(sec(u8, t.scx_pool));
        return scripts[w >> 8 ..][0 .. w & 0xFF];
    }
    const s = @intFromEnum(props(cp).script);
    return all_scripts[s .. s + 1];
}

/// The Bidi_Mirroring_Glyph of `cp`, if any.
pub fn mirror(cp: u21) ?u21 {
    const d = sec(u32, t.mirror);
    const i = find(d, 2, cp) orelse return null;
    return @intCast(d[i * 2 + 1]);
}

/// The Bidi_Paired_Bracket of `cp`, if any.
pub fn pairedBracket(cp: u21) ?u21 {
    const d = sec(u32, t.brackets);
    const i = find(d, 2, cp) orelse return null;
    return @intCast(d[i * 2 + 1]);
}

/// Indic syllabic and positional categories.
pub const IndicCategories = struct { syllabic: IndicSyllabic, positional: IndicPositional };

/// Indic_Syllabic_Category and Indic_Positional_Category of `cp`.
pub fn indicCategories(cp: u21) IndicCategories {
    const x = aux(cp);
    return .{ .syllabic = x.isc, .positional = x.ipc };
}

/// True if `cp` starts a sequence in emoji-variation-sequences.txt.
pub fn isEmojiVariationBase(cp: u21) bool {
    return aux(cp).vs_base;
}

/// A decomposition mapping.
pub const Decomposition = struct { compat: bool, cps: []const u21 };

/// The full decomposition of `cp` (recursively expanded): the compatibility
/// one when any step is a compatibility mapping (`compat = true`), else the
/// canonical one. Hangul syllables are decomposed algorithmically by
/// `normalize` and return null here.
pub fn decomposition(cp: u21) ?Decomposition {
    if (!aux(cp).has_decomp) return null;
    if (decomposeCompat(cp)) |d| return .{ .compat = true, .cps = d };
    return .{ .compat = false, .cps = decomposeCanonical(cp).? };
}

/// The full canonical decomposition (NFD mapping) of `cp`, if any.
pub fn decomposeCanonical(cp: u21) ?[]const u21 {
    if (!aux(cp).has_decomp) return null;
    const d = sec(u32, t.decomp_canon);
    const i = find(d, 2, cp) orelse return null;
    return pool(d[i * 2 + 1]);
}

/// The full compatibility decomposition (NFKD mapping) of `cp` when it
/// differs from the canonical one.
pub fn decomposeCompat(cp: u21) ?[]const u21 {
    if (!aux(cp).has_decomp) return null;
    const d = sec(u32, t.decomp_compat);
    const i = find(d, 2, cp) orelse return null;
    return pool(d[i * 2 + 1]);
}

/// The primary composite of `a` + `b` (exclusions removed; Hangul is
/// composed algorithmically by `normalize`).
pub fn compose(a: u21, b: u21) ?u21 {
    const keys = sec(u64, t.compose_keys);
    const key = @as(u64, a) << 21 | b;
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (keys[mid] == key) return @intCast(sec(u32, t.compose_values)[mid]);
        if (keys[mid] < key) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// A short code point sequence held by value (full case mappings and
/// foldings are at most 3 code points).
pub const Mapping = struct {
    buf: [3]u21 = undefined,
    len: u8 = 0,

    /// The code points.
    pub fn slice(m: *const Mapping) []const u21 {
        return m.buf[0..m.len];
    }

    fn of(cps: []const u21) Mapping {
        var m: Mapping = .{ .len = @intCast(cps.len) };
        @memcpy(m.buf[0..cps.len], cps);
        return m;
    }

    fn one(cp: u21) Mapping {
        return .{ .buf = .{ cp, 0, 0 }, .len = 1 };
    }
};

/// Full case folding (status C + F); `cp` itself when it does not fold.
pub fn caseFoldFull(cp: u21) Mapping {
    if (aux(cp).has_fold) {
        const d = sec(u32, t.fold_full);
        if (find(d, 2, cp)) |i| return .of(pool(d[i * 2 + 1]));
    }
    return .one(cp);
}

/// Simple case folding (status C + S).
pub fn caseFoldSimple(cp: u21) u21 {
    if (!aux(cp).has_fold) return cp;
    const d = sec(u32, t.fold_simple);
    const i = find(d, 2, cp) orelse return cp;
    return @intCast(d[i * 2 + 1]);
}

/// Case mapping kinds.
pub const CaseKind = enum(u2) { lower = 0, upper = 1, title = 2 };

/// Simple case mapping from UnicodeData (identity when empty; an empty
/// titlecase mapping means the uppercase one).
pub fn caseMapSimple(cp: u21, k: CaseKind) u21 {
    if (!aux(cp).has_case_map) return cp;
    const d = sec(u32, t.case_simple);
    const i = find(d, 4, cp) orelse return cp;
    return @intCast(d[
        i * 4 + @as(usize, switch (k) {
            .upper => 1,
            .lower => 2,
            .title => 3,
        })
    ]);
}

/// Full case mapping: the unconditional SpecialCasing entry if any, else
/// the simple mapping. Conditional mappings (Final_Sigma,
/// language-specific) are applied by `casefold`.
pub fn caseMapFull(cp: u21, k: CaseKind) Mapping {
    if (!aux(cp).has_case_map) return .one(cp);
    const d = sec(u32, t.case_full);
    if (find(d, 2, @as(u32, cp) << 2 | @intFromEnum(k))) |i| return .of(pool(d[i * 2 + 1]));
    return .one(caseMapSimple(cp, k));
}

/// DerivedCoreProperties Cased.
pub fn isCased(cp: u21) bool {
    return aux(cp).cased;
}

/// DerivedCoreProperties Case_Ignorable.
pub fn isCaseIgnorable(cp: u21) bool {
    return aux(cp).case_ignorable;
}

test {
    _ = @import("props_test.zig");
}
