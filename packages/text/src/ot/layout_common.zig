//! OpenType layout common table formats shared by GSUB and GPOS
//! (spec chapter 2): Coverage, ClassDef, ScriptList/LangSys, FeatureList,
//! LookupList (with Extension subtables) and FeatureVariations.
//!
//! Every view borrows the font bytes. Constructors check the bounds of the
//! arrays they expose, so lookups through a valid view never read past the
//! table; offsets elsewhere are checked when followed.

const std = @import("std");
const reader = @import("reader.zig");
const GlyphId = reader.GlyphId;
const Tag = reader.Tag;
const tag = reader.tag;
const readAt = reader.readAt;
const Error = reader.Error;
const VarCoords = @import("var/ivs.zig").VarCoords;

inline fn be16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

/// `data[off..]` for a non-null 16/32-bit offset; null offsets give null.
pub fn follow(data: []const u8, off: u32) Error!?[]const u8 {
    if (off == 0) return null;
    return try reader.sub(data, off);
}

/// A Coverage table (format 1: sorted glyph array; format 2: ranges).
pub const Coverage = struct {
    data: []const u8 = &.{},
    format: u16 = 0,
    count: u16 = 0,

    /// An empty coverage (covers nothing).
    pub const empty: Coverage = .{};

    /// The coverage at `data[off..]`; checks the format and array bounds.
    pub fn init(data: []const u8, off: usize) Error!Coverage {
        const d = try reader.sub(data, off);
        const format = try readAt(u16, d, 0);
        const count = try readAt(u16, d, 2);
        const size: usize = switch (format) {
            1 => 2,
            2 => 6,
            else => return error.Malformed,
        };
        _ = try reader.subLen(d, 4, @as(usize, count) * size);
        return .{ .data = d, .format = format, .count = count };
    }

    /// The coverage index of `gid`, or null when not covered.
    pub fn index(c: Coverage, gid: GlyphId) ?u16 {
        var lo: usize = 0;
        var hi: usize = c.count;
        switch (c.format) {
            1 => while (lo < hi) {
                const mid = (lo + hi) / 2;
                const g = be16(c.data, 4 + mid * 2);
                if (gid < g) hi = mid else if (gid > g) lo = mid + 1 else return @intCast(mid);
            },
            2 => while (lo < hi) {
                const mid = (lo + hi) / 2;
                const rec = 4 + mid * 6;
                const start = be16(c.data, rec);
                const end = be16(c.data, rec + 2);
                if (gid < start) hi = mid else if (gid > end) lo = mid + 1 else {
                    return @truncate(@as(u32, be16(c.data, rec + 4)) + (gid - start));
                }
            },
            else => {},
        }
        return null;
    }

    /// Calls `cb(ctx, gid)` for every covered glyph, in coverage order.
    pub fn forEach(c: Coverage, ctx: anytype, comptime cb: fn (@TypeOf(ctx), GlyphId) void) void {
        switch (c.format) {
            1 => for (0..c.count) |i| cb(ctx, be16(c.data, 4 + i * 2)),
            2 => for (0..c.count) |i| {
                const start = be16(c.data, 4 + i * 6);
                const end = be16(c.data, 4 + i * 6 + 2);
                var g: u32 = start;
                while (g <= end) : (g += 1) cb(ctx, @intCast(g));
            },
            else => {},
        }
    }
};

/// A ClassDef table (format 1: class array from a start glyph; format 2:
/// class ranges). Glyphs not listed are class 0.
pub const ClassDef = struct {
    data: []const u8 = &.{},
    format: u16 = 0,
    start: u16 = 0,
    count: u16 = 0,

    /// Every glyph in class 0.
    pub const empty: ClassDef = .{};

    /// The class definition at `data[off..]`; null offsets give `empty`.
    pub fn init(data: []const u8, off: usize) Error!ClassDef {
        if (off == 0) return .empty;
        const d = try reader.sub(data, off);
        const format = try readAt(u16, d, 0);
        switch (format) {
            1 => {
                const start = try readAt(u16, d, 2);
                const count = try readAt(u16, d, 4);
                _ = try reader.subLen(d, 6, @as(usize, count) * 2);
                return .{ .data = d, .format = 1, .start = start, .count = count };
            },
            2 => {
                const count = try readAt(u16, d, 2);
                _ = try reader.subLen(d, 4, @as(usize, count) * 6);
                return .{ .data = d, .format = 2, .count = count };
            },
            else => return error.Malformed,
        }
    }

    /// The class of `gid` (0 when absent).
    pub fn class(c: ClassDef, gid: GlyphId) u16 {
        switch (c.format) {
            1 => {
                if (gid < c.start) return 0;
                const i = gid - c.start;
                if (i >= c.count) return 0;
                return be16(c.data, 6 + @as(usize, i) * 2);
            },
            2 => {
                var lo: usize = 0;
                var hi: usize = c.count;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    const rec = 4 + mid * 6;
                    if (gid < be16(c.data, rec)) hi = mid else if (gid > be16(c.data, rec + 2)) lo = mid + 1 else return be16(c.data, rec + 4);
                }
                return 0;
            },
            else => return 0,
        }
    }
};

/// LookupFlag bits.
pub const LookupFlag = struct {
    pub const right_to_left: u16 = 0x0001;
    pub const ignore_base_glyphs: u16 = 0x0002;
    pub const ignore_ligatures: u16 = 0x0004;
    pub const ignore_marks: u16 = 0x0008;
    pub const ignore_flags: u16 = 0x000E;
    pub const use_mark_filtering_set: u16 = 0x0010;
    pub const mark_attachment_type: u16 = 0xFF00;
};

/// A lookup: its type, flags and subtables. Extension subtables are
/// resolved by `subtable`.
pub const Lookup = struct {
    data: []const u8,
    kind: u16,
    flag: u16,
    subtable_count: u16,
    mark_filtering_set: ?u16,

    /// One subtable: its (extension-resolved) type and bytes.
    pub const Subtable = struct { kind: u16, data: []const u8 };

    /// Subtable `i`, following an Extension (`ext_kind`: 7 for GSUB, 9 for
    /// GPOS) to its real type; an extension of an extension is Malformed.
    pub fn subtable(l: Lookup, i: u16, ext_kind: u16) Error!Subtable {
        if (i >= l.subtable_count) return error.Malformed;
        const off = be16(l.data, 6 + @as(usize, i) * 2);
        const d = try reader.sub(l.data, off);
        if (l.kind != ext_kind) return .{ .kind = l.kind, .data = d };
        if (try readAt(u16, d, 0) != 1) return error.Malformed;
        const kind = try readAt(u16, d, 2);
        if (kind == ext_kind) return error.Malformed;
        return .{ .kind = kind, .data = try reader.sub(d, try readAt(u32, d, 4)) };
    }

    /// The lookup props HarfBuzz-style: the flag in the low 16 bits and the
    /// mark filtering set above them.
    pub fn props(l: Lookup) u32 {
        var p: u32 = l.flag;
        if (l.mark_filtering_set) |s| p |= @as(u32, s) << 16;
        return p;
    }
};

/// A Script table: its default LangSys and language records.
pub const ScriptTable = struct {
    data: []const u8,
    /// The tag that selected it.
    tag: Tag,

    /// The LangSys for `lang`, else the default LangSys, else null.
    pub fn langSys(s: ScriptTable, lang: Tag) ?LangSys {
        return s.langSysExact(lang) orelse s.defaultLangSys();
    }

    /// The LangSys record tagged `lang`, or null.
    pub fn langSysExact(s: ScriptTable, lang: Tag) ?LangSys {
        const n = readAt(u16, s.data, 2) catch return null;
        _ = reader.subLen(s.data, 4, @as(usize, n) * 6) catch return null;
        for (0..n) |i| {
            const rec = 4 + i * 6;
            if (std.mem.readInt(u32, s.data[rec..][0..4], .big) == lang) {
                return LangSys.init(s.data, be16(s.data, rec + 4)) catch null;
            }
        }
        return null;
    }

    /// The default LangSys, or null.
    pub fn defaultLangSys(s: ScriptTable) ?LangSys {
        const off = readAt(u16, s.data, 0) catch return null;
        if (off == 0) return null;
        return LangSys.init(s.data, off) catch null;
    }
};

/// A LangSys: the required feature and the feature indices.
pub const LangSys = struct {
    data: []const u8,
    required: ?u16,
    count: u16,

    fn init(data: []const u8, off: usize) Error!LangSys {
        const d = try reader.sub(data, off);
        const req = try readAt(u16, d, 2);
        const n = try readAt(u16, d, 4);
        _ = try reader.subLen(d, 6, @as(usize, n) * 2);
        return .{ .data = d, .required = if (req == 0xFFFF) null else req, .count = n };
    }

    /// Feature index `i` of this LangSys.
    pub fn featureIndex(l: LangSys, i: usize) u16 {
        return be16(l.data, 6 + i * 2);
    }
};

/// A Feature table's lookup indices.
pub const FeatureTable = struct {
    data: []const u8 = &.{},
    count: u16 = 0,

    fn init(data: []const u8) Error!FeatureTable {
        const n = try readAt(u16, data, 2);
        _ = try reader.subLen(data, 4, @as(usize, n) * 2);
        return .{ .data = data, .count = n };
    }

    /// Lookup index `i`.
    pub fn lookupIndex(f: FeatureTable, i: usize) u16 {
        return be16(f.data, 4 + i * 2);
    }
};

/// The common header of GSUB and GPOS.
pub const LayoutTable = struct {
    data: []const u8,
    scripts: []const u8,
    script_count: u16,
    features: []const u8,
    feature_count: u16,
    lookups: []const u8,
    lookup_count: u16,
    feature_vars: ?[]const u8,

    /// Parses the header and checks the three record arrays.
    pub fn init(bytes: []const u8) Error!LayoutTable {
        const major = try readAt(u16, bytes, 0);
        const minor = try readAt(u16, bytes, 2);
        if (major != 1) return error.Malformed;
        const sl = try readAt(u16, bytes, 4);
        const fl = try readAt(u16, bytes, 6);
        const ll = try readAt(u16, bytes, 8);
        var t: LayoutTable = .{
            .data = bytes,
            .scripts = &.{},
            .script_count = 0,
            .features = &.{},
            .feature_count = 0,
            .lookups = &.{},
            .lookup_count = 0,
            .feature_vars = null,
        };
        if (sl != 0) {
            t.scripts = try reader.sub(bytes, sl);
            t.script_count = try readAt(u16, t.scripts, 0);
            _ = try reader.subLen(t.scripts, 2, @as(usize, t.script_count) * 6);
        }
        if (fl != 0) {
            t.features = try reader.sub(bytes, fl);
            t.feature_count = try readAt(u16, t.features, 0);
            _ = try reader.subLen(t.features, 2, @as(usize, t.feature_count) * 6);
        }
        if (ll != 0) {
            t.lookups = try reader.sub(bytes, ll);
            t.lookup_count = try readAt(u16, t.lookups, 0);
            _ = try reader.subLen(t.lookups, 2, @as(usize, t.lookup_count) * 2);
        }
        if (minor >= 1) {
            const fv = try readAt(u32, bytes, 10);
            if (fv != 0) t.feature_vars = reader.sub(bytes, fv) catch null;
        }
        return t;
    }

    /// The first script found among `tags`, then `DFLT`, `dflt` and `latn`
    /// (HarfBuzz's order); null when none exists.
    pub fn findScript(t: LayoutTable, tags: []const Tag) ?ScriptTable {
        for (tags) |want| if (t.script(want)) |s| return s;
        for ([_]Tag{ tag("DFLT"), tag("dflt"), tag("latn") }) |want| if (t.script(want)) |s| return s;
        return null;
    }

    /// The script table for `want`, or null.
    pub fn script(t: LayoutTable, want: Tag) ?ScriptTable {
        for (0..t.script_count) |i| {
            const rec = 2 + i * 6;
            if (std.mem.readInt(u32, t.scripts[rec..][0..4], .big) != want) continue;
            const d = reader.sub(t.scripts, be16(t.scripts, rec + 4)) catch return null;
            _ = readAt(u16, d, 2) catch return null;
            return .{ .data = d, .tag = want };
        }
        return null;
    }

    /// The tag of feature `i`.
    pub fn featureTag(t: LayoutTable, i: u16) ?Tag {
        if (i >= t.feature_count) return null;
        return std.mem.readInt(u32, t.features[2 + @as(usize, i) * 6 ..][0..4], .big);
    }

    /// Feature `i`'s lookups, with FeatureVariations record `variations`
    /// (from `featureVariationsIndex`) substituting it when it lists one.
    pub fn feature(t: LayoutTable, i: u16, variations: ?u32) ?FeatureTable {
        if (i >= t.feature_count) return null;
        if (variations) |v| if (t.substitutedFeature(v, i)) |f| return f;
        const off = be16(t.features, 2 + @as(usize, i) * 6 + 4);
        const d = reader.sub(t.features, off) catch return null;
        return FeatureTable.init(d) catch null;
    }

    /// Lookup `i`, validated.
    pub fn lookup(t: LayoutTable, i: u16) Error!Lookup {
        if (i >= t.lookup_count) return error.Malformed;
        const d = try reader.sub(t.lookups, be16(t.lookups, 2 + @as(usize, i) * 2));
        const kind = try readAt(u16, d, 0);
        const flag = try readAt(u16, d, 2);
        const n = try readAt(u16, d, 4);
        _ = try reader.subLen(d, 6, @as(usize, n) * 2);
        const mfs: ?u16 = if (flag & LookupFlag.use_mark_filtering_set != 0) try readAt(u16, d, 6 + @as(usize, n) * 2) else null;
        return .{ .data = d, .kind = kind, .flag = flag, .subtable_count = n, .mark_filtering_set = mfs };
    }

    /// The index of the first FeatureVariations record whose condition set
    /// matches `coords`, or null.
    pub fn featureVariationsIndex(t: LayoutTable, coords: VarCoords) ?u32 {
        const fv = t.feature_vars orelse return null;
        if ((readAt(u16, fv, 0) catch return null) != 1) return null;
        const n = readAt(u32, fv, 4) catch return null;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const rec: usize = 8 + @as(usize, i) * 8;
            const cs_off = readAt(u32, fv, rec) catch return null;
            if (conditionSetMatches(fv, cs_off, coords)) return i;
        }
        return null;
    }

    fn substitutedFeature(t: LayoutTable, v: u32, feature_index: u16) ?FeatureTable {
        const fv = t.feature_vars orelse return null;
        const rec: usize = 8 + @as(usize, v) * 8;
        const sub_off = readAt(u32, fv, rec + 4) catch return null;
        if (sub_off == 0) return null;
        const s = reader.sub(fv, sub_off) catch return null;
        const n = readAt(u16, s, 4) catch return null;
        _ = reader.subLen(s, 6, @as(usize, n) * 6) catch return null;
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const r = 6 + mid * 6;
            const fi = be16(s, r);
            if (feature_index < fi) hi = mid else if (feature_index > fi) lo = mid + 1 else {
                const off = std.mem.readInt(u32, s[r + 2 ..][0..4], .big);
                const d = reader.sub(s, off) catch return null;
                return FeatureTable.init(d) catch null;
            }
        }
        return null;
    }
};

fn conditionSetMatches(fv: []const u8, cs_off: u32, coords: VarCoords) bool {
    if (cs_off == 0) return true;
    const cs = reader.sub(fv, cs_off) catch return false;
    const n = readAt(u16, cs, 0) catch return false;
    for (0..n) |i| {
        const c_off = readAt(u32, cs, 2 + i * 4) catch return false;
        const c = reader.sub(cs, c_off) catch return false;
        const format = readAt(u16, c, 0) catch return false;
        if (format != 1) return false; // unknown condition formats never match
        const axis = readAt(u16, c, 2) catch return false;
        const lo = readAt(i16, c, 4) catch return false;
        const hi = readAt(i16, c, 6) catch return false;
        const v: i16 = if (axis < coords.len) coords[axis] else 0;
        if (v < lo or v > hi) return false;
    }
    return true;
}

/// The SequenceLookupRecord list of a context rule: (sequence index,
/// lookup index) pairs.
pub const LookupRecords = struct {
    data: []const u8 = &.{},
    count: u16 = 0,

    /// `count` records at `data[off..]`, bounds-checked.
    pub fn init(data: []const u8, off: usize, count: u16) Error!LookupRecords {
        return .{ .data = try reader.subLen(data, off, @as(usize, count) * 4), .count = count };
    }

    /// Record `i`: the sequence index and the lookup index.
    pub fn get(r: LookupRecords, i: usize) struct { seq: u16, lookup: u16 } {
        return .{ .seq = be16(r.data, i * 4), .lookup = be16(r.data, i * 4 + 2) };
    }
};

/// A 16-bit array at `data[off..]` with its count, bounds-checked.
pub const U16Array = struct {
    data: []const u8 = &.{},
    len: u16 = 0,

    /// `len` big-endian u16s at `data[off..]`.
    pub fn init(data: []const u8, off: usize, len: u16) Error!U16Array {
        return .{ .data = try reader.subLen(data, off, @as(usize, len) * 2), .len = len };
    }

    /// Element `i`.
    pub inline fn get(a: U16Array, i: usize) u16 {
        return be16(a.data, i * 2);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Big-endian byte builder for crafted tables in tests.
pub const TestBytes = struct {
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    /// Appends a u16.
    pub fn u16_(b: *TestBytes, v: u16) void {
        b.buf.appendSlice(b.gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, v))) catch @panic("OOM");
    }
    /// Appends an i16.
    pub fn i16_(b: *TestBytes, v: i16) void {
        b.u16_(@bitCast(v));
    }
    /// Appends a u32.
    pub fn u32_(b: *TestBytes, v: u32) void {
        b.buf.appendSlice(b.gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, v))) catch @panic("OOM");
    }
    /// Appends u16s.
    pub fn u16s(b: *TestBytes, vs: []const u16) void {
        for (vs) |v| b.u16_(v);
    }
    /// Current length.
    pub fn len(b: *const TestBytes) usize {
        return b.buf.items.len;
    }
    /// Overwrites a u16 at `off`.
    pub fn patch16(b: *TestBytes, off: usize, v: u16) void {
        std.mem.writeInt(u16, b.buf.items[off..][0..2], v, .big);
    }
    /// Frees the bytes.
    pub fn deinit(b: *TestBytes) void {
        b.buf.deinit(b.gpa);
    }
};

test "layout: coverage format1/2" {
    var b: TestBytes = .{ .gpa = testing.allocator };
    defer b.deinit();
    b.u16s(&.{ 1, 4, 3, 7, 9, 200 });
    const c1 = try Coverage.init(b.buf.items, 0);
    try testing.expectEqual(@as(?u16, 0), c1.index(3));
    try testing.expectEqual(@as(?u16, 2), c1.index(9));
    try testing.expectEqual(@as(?u16, 3), c1.index(200));
    try testing.expectEqual(@as(?u16, null), c1.index(8));
    const f2 = b.len();
    b.u16s(&.{ 2, 2, 10, 12, 0, 20, 20, 3 });
    const c2 = try Coverage.init(b.buf.items, f2);
    try testing.expectEqual(@as(?u16, 1), c2.index(11));
    try testing.expectEqual(@as(?u16, 3), c2.index(20));
    try testing.expectEqual(@as(?u16, null), c2.index(13));
    try testing.expectEqual(@as(?u16, null), c2.index(9));
    // Truncated arrays are rejected up front.
    try testing.expectError(error.Malformed, Coverage.init(b.buf.items[0..8], 0));
    try testing.expectError(error.Malformed, Coverage.init(&.{ 0, 3, 0, 0 }, 0));
}

test "layout: classdef format1/2 default 0" {
    var b: TestBytes = .{ .gpa = testing.allocator };
    defer b.deinit();
    b.u16s(&.{ 0, 1, 5, 3, 1, 2, 3 });
    const c1 = try ClassDef.init(b.buf.items, 2);
    try testing.expectEqual(@as(u16, 0), c1.class(4));
    try testing.expectEqual(@as(u16, 1), c1.class(5));
    try testing.expectEqual(@as(u16, 3), c1.class(7));
    try testing.expectEqual(@as(u16, 0), c1.class(8));
    // A null offset is the empty class def.
    try testing.expectEqual(@as(u16, 0), (try ClassDef.init(b.buf.items, 0)).class(100));
    const f2 = b.len();
    b.u16s(&.{ 2, 2, 10, 19, 4, 30, 30, 9 });
    const c2 = try ClassDef.init(b.buf.items, f2);
    try testing.expectEqual(@as(u16, 4), c2.class(15));
    try testing.expectEqual(@as(u16, 9), c2.class(30));
    try testing.expectEqual(@as(u16, 0), c2.class(25));
}

test "layout: feature variations select by coords" {
    // GSUB 1.1 with two features and a FeatureVariations table whose one
    // record (axis 0 in [0.5, 1.0]) swaps feature 1's lookups for [7].
    var b: TestBytes = .{ .gpa = testing.allocator };
    defer b.deinit();
    b.u16s(&.{ 1, 1, 0, 14, 0 }); // header: no scripts, features @14, no lookups
    b.u32_(0); // featureVariations, patched below
    // FeatureList @14: 2 records.
    b.u16_(2);
    b.u32_(tag("liga"));
    b.u16_(14);
    b.u32_(tag("rvrn"));
    b.u16_(20);
    b.u16s(&.{ 0, 1, 3 }); // liga: lookup 3 (@14+14)
    b.u16s(&.{ 0, 1, 4 }); // rvrn: lookup 4 (@14+20)
    const fv = b.len();
    std.mem.writeInt(u32, b.buf.items[10..14], @intCast(fv), .big);
    b.u16s(&.{ 1, 0 });
    b.u32_(1); // one record
    b.u32_(16); // condition set @fv+16
    b.u32_(30); // substitution @fv+30
    b.u16_(1); // condition set: 1 condition
    b.u32_(6);
    b.u16s(&.{ 1, 0 }); // format 1, axis 0
    b.i16_(8192);
    b.i16_(16384);
    b.u16s(&.{ 1, 0 }); // substitution version 1.0
    b.u16_(1);
    b.u16_(1); // feature index 1
    b.u32_(12); // alternate feature @+12
    b.u16s(&.{ 0, 1, 7 });
    const t = try LayoutTable.init(b.buf.items);
    try testing.expectEqual(@as(?u32, null), t.featureVariationsIndex(&.{}));
    try testing.expectEqual(@as(?u32, null), t.featureVariationsIndex(&.{4000}));
    const v = t.featureVariationsIndex(&.{10000});
    try testing.expectEqual(@as(?u32, 0), v);
    try testing.expectEqual(@as(u16, 4), t.feature(1, null).?.lookupIndex(0));
    try testing.expectEqual(@as(u16, 7), t.feature(1, v).?.lookupIndex(0));
    try testing.expectEqual(@as(u16, 3), t.feature(0, v).?.lookupIndex(0));
    try testing.expectEqual(tag("rvrn"), t.featureTag(1).?);
}
