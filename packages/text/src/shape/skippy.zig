//! The lookup application context shared by GSUB and GPOS, and `Skippy`,
//! the iterator that walks the buffer honouring LookupFlag (ignore base /
//! ligature / mark glyphs, mark filtering sets, mark attachment classes),
//! feature masks and default-ignorable joiners, HarfBuzz-style.

const std = @import("std");
const ot = @import("../ot/root.zig");
const GlyphId = ot.GlyphId;
const lc = @import("../ot/layout_common.zig");
const LookupFlag = lc.LookupFlag;
const LayoutTable = lc.LayoutTable;
const U16Array = lc.U16Array;
const gdef_mod = @import("../ot/gdef.zig");
const Gdef = gdef_mod.Gdef;
const GlyphProps = gdef_mod.GlyphProps;
const buffer = @import("buffer.zig");
const Buffer = buffer.Buffer;
const GlyphInfo = buffer.GlyphInfo;
const UFlags = buffer.UFlags;
const VarCoords = @import("../ot/var/ivs.zig").VarCoords;
const digest = @import("digest.zig");

/// Which table a context applies.
pub const TableKind = enum { gsub, gpos };

/// The longest input/backtrack/lookahead sequence a rule may match.
pub const max_context_length = 64;

/// Nested (recursive) lookups allowed below the top-level lookup.
pub const max_nesting = 6;

/// Bounds the work one shaping call can do on hostile tables: every
/// subtable application attempt costs one unit.
pub const OpBudget = struct {
    remaining: i64,
    exhausted: bool = false,

    /// 64 units per glyph, at least 16 384.
    pub fn init(buf_len: usize) OpBudget {
        return .{ .remaining = @max(16_384, @as(i64, @intCast(buf_len)) * 64) };
    }

    /// Takes one unit; false when the budget is spent.
    pub inline fn take(b: *OpBudget) bool {
        if (b.remaining <= 0) {
            b.exhausted = true;
            return false;
        }
        b.remaining -= 1;
        return true;
    }
};

/// State for applying one lookup (and the lookups it recurses into).
pub const Ctx = struct {
    buf: *Buffer,
    table: LayoutTable,
    kind: TableKind,
    gdef: *const Gdef,
    budget: *OpBudget,
    /// Normalized variation coordinates (GPOS VariationIndex deltas).
    coords: VarCoords = &.{},
    /// Region scalars of GDEF's ItemVariationStore at `coords` (empty:
    /// computed per delta).
    var_scalars: []const f32 = &.{},
    /// A top-level MultipleSubst pass writes its output to `buf.out`.
    multi_out: bool = false,
    lookup_index: u16 = 0,
    lookup_mask: u32 = 1,
    lookup_props: u32 = 0,
    auto_zwj: bool = true,
    auto_zwnj: bool = true,
    random: bool = false,
    per_syllable: bool = false,
    nesting_left: u8 = max_nesting,
    /// GPOS: glyph advance direction of the run.
    rtl: bool = false,
    /// First-glyph set of the lookup being applied (empty: no filter).
    lookup_digest: []const u64 = &.{},
    /// The table's lookup accelerators by index (empty: parse each time).
    accels: []const digest.LookupAccel = &.{},

    /// HarfBuzz's `check_glyph_property`: false when `props` (a lookup's
    /// flag and filtering set) ignores `g`.
    pub fn checkGlyphProperty(c: *const Ctx, g: GlyphInfo, props: u32) bool {
        const gp: u32 = g.glyph_props;
        if (gp & props & LookupFlag.ignore_flags != 0) return false;
        if (gp & GlyphProps.mark != 0) {
            if (props & LookupFlag.use_mark_filtering_set != 0) return c.gdef.inMarkSet(@intCast(props >> 16), g.gid);
            if (props & LookupFlag.mark_attachment_type != 0) return (props & LookupFlag.mark_attachment_type) == (gp & LookupFlag.mark_attachment_type);
        }
        return true;
    }

    /// True when the current lookup may apply to the glyph at `i` at all.
    pub inline fn applicable(c: *const Ctx, i: usize) bool {
        const g = c.buf.infos.items[i];
        return g.mask & c.lookup_mask != 0 and c.checkGlyphProperty(g, c.lookup_props);
    }

    /// GSUB: recompute the class of the glyph at `i` after it became `gid`
    /// (HarfBuzz's `_set_glyph_class`).
    pub fn setGlyphClass(c: *const Ctx, g: *GlyphInfo, gid: GlyphId, class_guess: u16, ligature: bool, component: bool) void {
        var props = g.glyph_props | GlyphProps.substituted;
        if (ligature) {
            props |= GlyphProps.ligated;
            props &= ~GlyphProps.multiplied;
        }
        if (component) props |= GlyphProps.multiplied;
        digest.add(c.buf.glyph_set.items, gid);
        if (c.gdef.has_glyph_classes) {
            props = (props & GlyphProps.preserve) | c.gdef.glyphProps(gid);
        } else if (class_guess != 0) {
            props = (props & GlyphProps.preserve) | class_guess;
        }
        g.glyph_props = props;
    }
};

/// How a rule names the glyphs it matches.
pub const Matcher = union(enum) {
    /// Any glyph (used for GPOS searches).
    none,
    /// Values are glyph ids.
    glyph,
    /// Values are classes of this class definition.
    class: lc.ClassDef,
    /// Values are Coverage offsets from this table start.
    coverage: []const u8,

    /// True when `gid` matches `value`.
    pub fn matches(m: Matcher, gid: GlyphId, value: u16) bool {
        return switch (m) {
            .none => true,
            .glyph => gid == value,
            .class => |cd| cd.class(gid) == value,
            .coverage => |base| blk: {
                const cov = lc.Coverage.init(base, value) catch break :blk false;
                break :blk cov.index(gid) != null;
            },
        };
    }
};

/// Result of testing one glyph.
pub const MatchResult = enum { match, not_match, skip };

/// Walks the buffer forward or backward from `idx`, skipping glyphs the
/// lookup ignores and matching the rest against a value list.
pub const Skippy = struct {
    c: *Ctx,
    idx: usize = 0,
    /// One past the last glyph `next` may reach.
    end: usize,
    num_items: usize = 0,
    props: u32,
    mask: u32,
    ignore_zwnj: bool,
    ignore_zwj: bool,
    ignore_hidden: bool,
    per_syllable: bool,
    syllable: u8 = 0,
    matcher: Matcher = .none,
    values: U16Array = .{},
    /// Next value to match (forward from 0, or backward from the end).
    value_i: usize = 0,
    backward_values: bool = false,

    /// An iterator for the current lookup. `context_match` is set when
    /// matching backtrack/lookahead (masks and joiners are ignored).
    pub fn init(c: *Ctx, context_match: bool) Skippy {
        return .{
            .c = c,
            .end = c.buf.infos.items.len,
            .props = c.lookup_props,
            .mask = if (context_match) std.math.maxInt(u32) else c.lookup_mask,
            .ignore_zwnj = c.kind == .gpos or (context_match and c.auto_zwnj),
            .ignore_zwj = context_match or c.auto_zwj,
            .ignore_hidden = c.kind == .gpos,
            .per_syllable = c.kind == .gsub and c.per_syllable,
        };
    }

    /// Positions the iterator at `start` with `num_items` glyphs to find.
    pub fn reset(s: *Skippy, start: usize, num_items: usize) void {
        s.idx = start;
        s.num_items = num_items;
        s.end = s.c.buf.infos.items.len;
        s.value_i = 0;
        s.syllable = if (start < s.end and s.per_syllable) s.c.buf.infos.items[start].syllable else 0;
    }

    /// Sets the values to match and how.
    pub fn setMatch(s: *Skippy, m: Matcher, values: U16Array) void {
        s.matcher = m;
        s.values = values;
        s.value_i = 0;
    }

    /// `may_skip`: yes, no, or maybe (default-ignorables).
    pub fn maySkip(s: *const Skippy, g: GlyphInfo) enum { yes, no, maybe } {
        if (g.uflags & UFlags.deleted != 0 or !s.c.checkGlyphProperty(g, s.props)) return .yes;
        if (g.isDefaultIgnorable() and (s.ignore_zwnj or !g.isZwnj()) and (s.ignore_zwj or !g.isZwj()) and (s.ignore_hidden or !g.isHidden())) return .maybe;
        return .no;
    }

    /// Tests one glyph against the next value.
    pub fn match(s: *const Skippy, g: GlyphInfo) MatchResult {
        const skip = s.maySkip(g);
        if (skip == .yes) return .skip;
        const may: enum { no, yes, maybe } = blk: {
            if (g.mask & s.mask == 0) break :blk .no;
            if (s.per_syllable and s.syllable != 0 and s.syllable != g.syllable) break :blk .no;
            if (s.matcher == .none or s.value_i >= s.values.len) break :blk .maybe;
            break :blk if (s.matcher.matches(g.gid, s.values.get(s.value_i))) .yes else .no;
        };
        if (may == .yes or (may == .maybe and skip == .no)) return .match;
        if (skip == .no) return .not_match;
        return .skip;
    }

    /// The next glyph the lookup does not ignore outright, when it is a
    /// plain candidate (not a default-ignorable, mask and syllable match);
    /// null otherwise. The fast paths use it to peek at the second glyph.
    pub fn peekNext(s: *const Skippy) ?usize {
        const infos = s.c.buf.infos.items;
        var j = s.idx + 1;
        while (j < s.end) : (j += 1) {
            const g = infos[j];
            switch (s.maySkip(g)) {
                .yes => continue,
                .maybe => return null,
                .no => {
                    if (g.mask & s.mask == 0) return null;
                    if (s.per_syllable and s.syllable != 0 and s.syllable != g.syllable) return null;
                    return j;
                },
            }
        }
        return null;
    }

    /// Moves to the next matching glyph. On failure `unsafe_to` is set to
    /// one past the glyph that broke the match (or the end).
    pub fn next(s: *Skippy, unsafe_to: ?*usize) bool {
        const infos = s.c.buf.infos.items;
        while (s.idx + s.num_items < s.end) {
            s.idx += 1;
            switch (s.match(infos[s.idx])) {
                .match => {
                    s.num_items -= 1;
                    s.value_i += 1;
                    return true;
                },
                .not_match => {
                    if (unsafe_to) |u| u.* = s.idx + 1;
                    return false;
                },
                .skip => {},
            }
        }
        if (unsafe_to) |u| u.* = s.end;
        return false;
    }

    /// Moves to the previous matching glyph.
    pub fn prev(s: *Skippy, unsafe_from: ?*usize) bool {
        const infos = s.c.buf.infos.items;
        while (s.idx > s.num_items -| 1 and s.idx > 0) {
            s.idx -= 1;
            switch (s.match(infos[s.idx])) {
                .match => {
                    s.num_items -|= 1;
                    s.value_i += 1;
                    return true;
                },
                .not_match => {
                    if (unsafe_from) |u| u.* = s.idx;
                    return false;
                },
                .skip => {},
            }
        }
        if (unsafe_from) |u| u.* = 0;
        return false;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testInfo(gid: GlyphId, props: u16) GlyphInfo {
    return .{ .gid = gid, .cluster = gid, .cp = 'a', .mask = 1, .glyph_props = props };
}

test "skippy: lookup flag skipping table" {
    var b: lc.TestBytes = .{ .gpa = testing.allocator };
    defer b.deinit();
    // GDEF 1.2: no class def (props are set by hand), attach classes @14,
    // mark sets @26: set 0 = {21}.
    b.u16s(&.{ 1, 2, 0, 0, 0, 14, 26 });
    b.u16s(&.{ 1, 20, 3, 1, 2, 1 }); // attach: 20→1, 21→2, 22→1
    b.u16s(&.{ 1, 1 });
    b.u32_(8);
    b.u16s(&.{ 1, 1, 21 });
    const gdef = try Gdef.init(b.buf.items);
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    // base, mark(20, class 1), ligature, mark(21, class 2), mark(22, class 1), base
    const glyphs = [_]GlyphInfo{
        testInfo(1, GlyphProps.base),
        testInfo(20, GlyphProps.mark | 0x100),
        testInfo(5, GlyphProps.ligature),
        testInfo(21, GlyphProps.mark | 0x200),
        testInfo(22, GlyphProps.mark | 0x100),
        testInfo(2, GlyphProps.base),
    };
    try buf.infos.appendSlice(testing.allocator, &glyphs);
    var budget = OpBudget.init(buf.len());
    var c: Ctx = .{ .buf = &buf, .table = undefined, .kind = .gsub, .gdef = &gdef, .budget = &budget };
    const Case = struct { props: u32, want: []const usize };
    const cases = [_]Case{
        .{ .props = 0, .want = &.{ 1, 2, 3, 4, 5 } },
        .{ .props = LookupFlag.ignore_marks, .want = &.{ 2, 5 } },
        .{ .props = LookupFlag.ignore_ligatures, .want = &.{ 1, 3, 4, 5 } },
        .{ .props = LookupFlag.ignore_base_glyphs, .want = &.{ 1, 2, 3, 4 } },
        .{ .props = 0x100, .want = &.{ 1, 2, 4, 5 } }, // attachment class 1 only
        .{ .props = LookupFlag.use_mark_filtering_set, .want = &.{ 2, 3, 5 } }, // set 0
        // IgnoreMarks wins over both filters.
        .{ .props = LookupFlag.ignore_marks | LookupFlag.use_mark_filtering_set, .want = &.{ 2, 5 } },
    };
    for (cases) |cs| {
        c.lookup_props = cs.props;
        var it = Skippy.init(&c, false);
        it.reset(0, 0);
        var got: std.ArrayList(usize) = .empty;
        defer got.deinit(testing.allocator);
        // One item at a time so next() can reach the last glyph.
        while (true) {
            it.num_items = 1;
            if (!it.next(null)) break;
            try got.append(testing.allocator, it.idx);
        }
        try testing.expectEqualSlices(usize, cs.want, got.items);
    }
}

test "skippy: mark filtering set" {
    var b: lc.TestBytes = .{ .gpa = testing.allocator };
    defer b.deinit();
    b.u16s(&.{ 1, 2, 0, 0, 0, 0, 14 });
    b.u16s(&.{ 1, 2 });
    b.u32_(12);
    b.u32_(18);
    b.u16s(&.{ 1, 1, 30 });
    b.u16s(&.{ 1, 1, 31 });
    const gdef = try Gdef.init(b.buf.items);
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    var budget = OpBudget.init(1);
    const c: Ctx = .{ .buf = &buf, .table = undefined, .kind = .gsub, .gdef = &gdef, .budget = &budget };
    const set1: u32 = @as(u32, LookupFlag.use_mark_filtering_set) | (1 << 16);
    try testing.expect(c.checkGlyphProperty(testInfo(31, GlyphProps.mark), set1));
    try testing.expect(!c.checkGlyphProperty(testInfo(30, GlyphProps.mark), set1));
    // Non-marks are never filtered by a mark set.
    try testing.expect(c.checkGlyphProperty(testInfo(30, GlyphProps.base), set1));
}
