//! Shape plans: script and language selection, feature collection, mask
//! allocation and the lookup stages of GSUB and GPOS. The map builder
//! follows HarfBuzz's `hb_ot_map_builder_t` so that lookup order, mask
//! sharing and feature disabling match its output.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ot = @import("../ot/root.zig");
const Tag = ot.Tag;
const tag = ot.tag;
const GlyphId = ot.GlyphId;
const lc = @import("../ot/layout_common.zig");
const LayoutTable = lc.LayoutTable;
const Gdef = @import("../ot/gdef.zig").Gdef;
const FaceInstance = @import("../ot/var/instance.zig").FaceInstance;
const Script = @import("../unicode/root.zig").Script;
const buffer = @import("buffer.zig");
const Buffer = buffer.Buffer;
const Direction = buffer.Direction;
const Feature = buffer.Feature;
const kern_fallback = @import("kern_fallback.zig");
const digest = @import("digest.zig");

/// Largest feature value a mask can hold (8 bits).
pub const max_value = 255;
const max_bits = 8;
/// Bit 0 is the global bit; features take bits from 1 up.
const global_mask: u32 = 1;
const first_bit = 1;

/// Feature flags (HarfBuzz's `hb_ot_map_feature_flags_t`).
pub const FeatureFlags = packed struct(u8) {
    global: bool = false,
    has_fallback: bool = false,
    manual_zwnj: bool = false,
    manual_zwj: bool = false,
    random: bool = false,
    per_syllable: bool = false,
    _pad: u2 = 0,

    pub const none: FeatureFlags = .{};
    pub const global_on: FeatureFlags = .{ .global = true };
    pub const manual_joiners: FeatureFlags = .{ .global = true, .manual_zwj = true, .manual_zwnj = true };
};

/// A pause between stages: complex shapers reorder or retag here.
pub const PauseFn = *const fn (plan: *const ShapePlan, buf: *Buffer) void;

/// One lookup of a stage with the mask and joiner rules it runs under.
pub const LookupMap = struct {
    index: u16,
    mask: u32,
    auto_zwj: bool = true,
    auto_zwnj: bool = true,
    random: bool = false,
    per_syllable: bool = false,
    /// Glyphs the lookup can start at (`digest.zig`); empty: unknown.
    digest: []const u64 = &.{},
};

/// A run of lookups followed by an optional pause.
pub const Stage = struct {
    lookups: []const LookupMap,
    pause: ?PauseFn = null,
};

/// A feature's mask bits in the plan.
pub const FeatureMap = struct {
    tag: Tag,
    mask: u32,
    shift: u5,
    /// Its value-1 mask.
    one: u32,
};

/// When mark advances are zeroed relative to GPOS.
pub const ZeroMarks = enum { none, gdef_early, gdef_late };

/// A complex shaper front end (default, Arabic, USE, Indic).
pub const ComplexShaper = struct {
    name: []const u8,
    /// Adds the shaper's features and pauses after `rvrn`/direction ones.
    collectFeatures: ?*const fn (b: *PlanBuilder) Allocator.Error!void = null,
    /// Called once the plan is compiled (masks known).
    dataInit: ?*const fn (plan: *ShapePlan) void = null,
    /// Sets per-glyph feature masks before GSUB.
    setupMasks: ?*const fn (plan: *const ShapePlan, buf: *Buffer) void = null,
    /// Reorders marks within a ccc run [start, end) after normalization.
    reorderMarks: ?@import("normalize.zig").ReorderFn = null,
    zero_marks: ZeroMarks = .gdef_late,
    fallback_position: bool = true,
};

const FeatureInfo = struct {
    tag: Tag,
    seq: u32,
    max_value: u32,
    flags: FeatureFlags,
    default_value: u32,
    stage: [2]u16,
};

const StageInfo = struct { index: u16, pause: ?PauseFn };

/// Collects features and pauses; `ShapePlan.build` compiles them.
pub const PlanBuilder = struct {
    gpa: Allocator,
    script: Script,
    dir: Direction,
    /// The chosen GSUB script tag (null when none matched).
    chosen_script: [2]?Tag = .{ null, null },
    infos: std.ArrayList(FeatureInfo) = .empty,
    stages: [2]std.ArrayList(StageInfo) = .{ .empty, .empty },
    current_stage: [2]u16 = .{ 0, 0 },

    /// Adds `t` with `flags`; `value` is its maximum (and default when global).
    pub fn addFeature(b: *PlanBuilder, t: Tag, flags: FeatureFlags, value: u32) Allocator.Error!void {
        if (t == 0) return;
        try b.infos.append(b.gpa, .{
            .tag = t,
            .seq = @intCast(b.infos.items.len),
            .max_value = value,
            .flags = flags,
            .default_value = if (flags.global) value else 0,
            .stage = b.current_stage,
        });
    }

    /// Adds `t` as a global feature.
    pub fn enableFeature(b: *PlanBuilder, t: Tag, flags: FeatureFlags, value: u32) Allocator.Error!void {
        var f = flags;
        f.global = true;
        try b.addFeature(t, f, value);
    }

    /// Ends the current stage of table `table` (0 GSUB, 1 GPOS).
    pub fn addPause(b: *PlanBuilder, table: u1, pause: ?PauseFn) Allocator.Error!void {
        try b.stages[table].append(b.gpa, .{ .index = b.current_stage[table], .pause = pause });
        b.current_stage[table] += 1;
    }

    /// Ends the current GSUB stage.
    pub fn addGsubPause(b: *PlanBuilder, pause: ?PauseFn) Allocator.Error!void {
        try b.addPause(0, pause);
    }

    fn deinit(b: *PlanBuilder) void {
        b.infos.deinit(b.gpa);
        b.stages[0].deinit(b.gpa);
        b.stages[1].deinit(b.gpa);
    }
};

const common_features = [_]struct { *const [4]u8, FeatureFlags }{
    .{ "abvm", .global_on },
    .{ "blwm", .global_on },
    .{ "ccmp", .global_on },
    .{ "locl", .global_on },
    .{ "mark", .manual_joiners },
    .{ "mkmk", .manual_joiners },
    .{ "rlig", .global_on },
};

const horizontal_features = [_]struct { *const [4]u8, FeatureFlags }{
    .{ "calt", .global_on },
    .{ "clig", .global_on },
    .{ "curs", .global_on },
    .{ "dist", .global_on },
    .{ "kern", .{ .global = true, .has_fallback = true } },
    .{ "liga", .global_on },
    .{ "rclt", .global_on },
};

/// The OpenType script tags for `s`, most preferred first: the newest
/// Indic generation (`dev3`, `dev2`), then the old tag.
pub fn otScriptTags(s: Script) [3]?Tag {
    const new: ?[]const u8 = switch (s) {
        .Beng => "bng",
        .Deva => "dev",
        .Gujr => "gjr",
        .Guru => "gur",
        .Knda => "knd",
        .Mlym => "mlm",
        .Orya => "ory",
        .Taml => "tml",
        .Telu => "tel",
        .Mymr => "mym",
        else => null,
    };
    const old: ?Tag = switch (s) {
        .Zyyy, .Zinh, .Zzzz => null,
        .Hira, .Kana, .Hrkt => tag("kana"),
        .Laoo => tag("lao "),
        .Yiii => tag("yi  "),
        .Nkoo => tag("nko "),
        .Vaii => tag("vai "),
        else => lower(@tagName(s)),
    };
    var out: [3]?Tag = .{ null, null, null };
    var n: usize = 0;
    if (new) |p| {
        const base = std.mem.readInt(u32, &[4]u8{ p[0], p[1], p[2], 0 }, .big);
        if (s != .Mymr) {
            out[n] = base | '3';
            n += 1;
        }
        out[n] = base | '2';
        n += 1;
    }
    out[n] = old;
    return out;
}

fn lower(name: []const u8) Tag {
    var b: [4]u8 = .{ ' ', ' ', ' ', ' ' };
    for (name[0..@min(4, name.len)], 0..) |ch, i| b[i] = std.ascii.toLower(ch);
    return std.mem.readInt(u32, &b, .big);
}

/// Everything shaping needs to know about one (face, script, language,
/// direction, user features) combination, built once and cached.
pub const ShapePlan = struct {
    arena: std.heap.ArenaAllocator,
    inst: *const FaceInstance,
    script: Script,
    lang: Tag,
    dir: Direction,
    complex: *const ComplexShaper,
    gdef: Gdef,
    gsub: ?LayoutTable,
    gpos: ?LayoutTable,
    /// Legacy `kern` table, used when GPOS has no `kern` feature.
    kern: ?kern_fallback.Kern,
    /// Stages in order; lookups index the table of their kind.
    gsub_stages: []const Stage,
    gpos_stages: []const Stage,
    /// Features sorted by tag.
    features: []const FeatureMap,
    /// Non-global user features (their masks are set per cluster range).
    ranged: []const Feature,
    global_mask: u32,
    chosen_script: [2]?Tag,
    apply_gpos: bool,
    apply_kern: bool,
    kern_mask: u32,
    rtlm_mask: u32,
    frac_mask: u32,
    numr_mask: u32,
    dnom_mask: u32,
    has_frac: bool,
    zero_marks: bool,
    /// Without GPOS, zeroing a mark keeps it where it was drawn.
    adjust_mark_positioning_when_zeroing: bool,
    /// False when no enabled lookup can see a U+0020 glyph, so text can be
    /// shaped word by word.
    space_participates: bool,
    space_glyph: GlyphId,
    /// Per-lookup accelerators of GSUB and GPOS, by lookup index.
    accels: [2][]const digest.LookupAccel = .{ &.{}, &.{} },
    /// Complex-shaper data (Arabic: per-form masks).
    shaper_masks: [8]u32 = @splat(0),

    /// Builds the plan. `user` features are copied.
    pub fn build(gpa: Allocator, inst: *const FaceInstance, script: Script, lang: Tag, dir: Direction, complex: *const ComplexShaper, user: []const Feature) Allocator.Error!ShapePlan {
        const face = inst.face;
        var plan: ShapePlan = .{
            .arena = .init(gpa),
            .inst = inst,
            .script = script,
            .lang = lang,
            .dir = dir,
            .complex = complex,
            .gdef = if (face.knownTable(.gdef)) |t| Gdef.init(t) catch .{} else .{},
            .gsub = if (face.knownTable(.gsub)) |t| LayoutTable.init(t) catch null else null,
            .gpos = if (face.knownTable(.gpos)) |t| LayoutTable.init(t) catch null else null,
            .kern = if (face.knownTable(.kern)) |t| kern_fallback.Kern.init(t) else null,
            .gsub_stages = &.{},
            .gpos_stages = &.{},
            .features = &.{},
            .ranged = &.{},
            .global_mask = global_mask,
            .chosen_script = .{ null, null },
            .apply_gpos = false,
            .apply_kern = false,
            .kern_mask = 0,
            .rtlm_mask = 0,
            .frac_mask = 0,
            .numr_mask = 0,
            .dnom_mask = 0,
            .has_frac = false,
            .zero_marks = false,
            .adjust_mark_positioning_when_zeroing = false,
            .space_participates = true,
            .space_glyph = face.glyphIndex(' '),
        };
        errdefer plan.arena.deinit();
        const a = plan.arena.allocator();

        var b: PlanBuilder = .{ .gpa = gpa, .script = script, .dir = dir };
        defer b.deinit();

        // Script and LangSys per table.
        const tags = otScriptTags(script);
        var tag_buf: [3]Tag = undefined;
        var nt: usize = 0;
        for (tags) |t| if (t) |v| {
            tag_buf[nt] = v;
            nt += 1;
        };
        var langsys: [2]?lc.LangSys = .{ null, null };
        const tables = [2]?LayoutTable{ plan.gsub, plan.gpos };
        for (tables, 0..) |maybe, ti| {
            const t = maybe orelse continue;
            const s = t.findScript(tag_buf[0..nt]) orelse continue;
            plan.chosen_script[ti] = s.tag;
            langsys[ti] = selectLangSys(s, lang);
        }
        b.chosen_script = plan.chosen_script;

        // Feature collection (hb_ot_shape_collect_features).
        try b.enableFeature(tag("rvrn"), .none, 1);
        try b.addGsubPause(null);
        switch (dir) {
            .ltr => {
                try b.enableFeature(tag("ltra"), .none, 1);
                try b.enableFeature(tag("ltrm"), .none, 1);
            },
            .rtl => {
                try b.enableFeature(tag("rtla"), .none, 1);
                try b.addFeature(tag("rtlm"), .none, 1);
            },
        }
        try b.addFeature(tag("frac"), .none, 1);
        try b.addFeature(tag("numr"), .none, 1);
        try b.addFeature(tag("dnom"), .none, 1);
        try b.enableFeature(tag("rand"), .{ .random = true }, max_value);
        try b.enableFeature(tag("trak"), .{ .has_fallback = true }, 1);
        if (complex.collectFeatures) |f| try f(&b);
        inline for (common_features) |cf| try b.addFeature(tag(cf[0]), cf[1], 1);
        inline for (horizontal_features) |hf| try b.addFeature(tag(hf[0]), hf[1], 1);
        var ranged: std.ArrayList(Feature) = .empty;
        for (user) |f| {
            try b.addFeature(f.tag, if (f.isGlobal()) .global_on else .none, f.value);
            if (!f.isGlobal()) try ranged.append(a, f);
        }
        plan.ranged = ranged.items;

        try plan.compile(&b, langsys);

        plan.rtlm_mask = plan.mask1(tag("rtlm"));
        plan.frac_mask = plan.mask1(tag("frac"));
        plan.numr_mask = plan.mask1(tag("numr"));
        plan.dnom_mask = plan.mask1(tag("dnom"));
        plan.has_frac = plan.frac_mask != 0 or (plan.numr_mask != 0 and plan.dnom_mask != 0);
        plan.kern_mask = plan.maskOf(tag("kern")).mask;

        const has_gpos_kern = plan.gposHasFeature(langsys[1], tag("kern"));
        plan.apply_gpos = plan.gpos != null;
        plan.apply_kern = (!has_gpos_kern or !plan.apply_gpos) and plan.kern != null;
        plan.zero_marks = complex.zero_marks != .none and !(plan.apply_kern and plan.kern.?.has_state_machine);
        plan.adjust_mark_positioning_when_zeroing = !plan.apply_gpos and !(plan.apply_kern and plan.kern.?.has_cross_stream);
        if (complex.dataInit) |f| f(&plan);
        plan.space_participates = plan.computeSpaceParticipates();
        return plan;
    }

    /// Frees the plan.
    pub fn deinit(p: *ShapePlan) void {
        p.arena.deinit();
        p.* = undefined;
    }

    /// The mask bits of feature `t` (zero mask when absent).
    pub fn maskOf(p: *const ShapePlan, t: Tag) FeatureMap {
        var lo: usize = 0;
        var hi: usize = p.features.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const f = p.features[mid];
            if (f.tag == t) return f;
            if (f.tag < t) lo = mid + 1 else hi = mid;
        }
        return .{ .tag = t, .mask = 0, .shift = 0, .one = 0 };
    }

    /// The value-1 mask of feature `t`.
    pub fn mask1(p: *const ShapePlan, t: Tag) u32 {
        return p.maskOf(t).one;
    }

    fn gposHasFeature(p: *const ShapePlan, ls: ?lc.LangSys, t: Tag) bool {
        const g = p.gpos orelse return false;
        const l = ls orelse return false;
        for (0..l.count) |i| if (g.featureTag(l.featureIndex(i)) == t) return true;
        return false;
    }

    fn compile(p: *ShapePlan, b: *PlanBuilder, langsys: [2]?lc.LangSys) Allocator.Error!void {
        const a = p.arena.allocator();
        try b.addPause(0, null);
        try b.addPause(1, null);

        // Sort by tag (stable) and merge duplicates.
        const infos = b.infos.items;
        std.mem.sort(FeatureInfo, infos, {}, struct {
            fn lt(_: void, x: FeatureInfo, y: FeatureInfo) bool {
                return if (x.tag != y.tag) x.tag < y.tag else x.seq < y.seq;
            }
        }.lt);
        var n: usize = 0;
        for (infos) |info| {
            if (n > 0 and infos[n - 1].tag == info.tag) {
                const j = &infos[n - 1];
                if (info.flags.global) {
                    j.flags.global = true;
                    j.max_value = info.max_value;
                    j.default_value = info.default_value;
                } else {
                    j.flags.global = false;
                    j.max_value = @max(j.max_value, info.max_value);
                }
                j.flags.has_fallback = j.flags.has_fallback or info.flags.has_fallback;
                j.stage[0] = @min(j.stage[0], info.stage[0]);
                j.stage[1] = @min(j.stage[1], info.stage[1]);
                continue;
            }
            infos[n] = info;
            n += 1;
        }

        const vars: [2]?u32 = .{
            if (p.gsub) |t| t.featureVariationsIndex(p.inst.coordsSlice()) else null,
            if (p.gpos) |t| t.featureVariationsIndex(p.inst.coordsSlice()) else null,
        };
        const tables = [2]?LayoutTable{ p.gsub, p.gpos };

        const Mapped = struct { info: FeatureInfo, index: [2]?u16, mask: u32 };
        var mapped: std.ArrayList(Mapped) = .empty;
        var features: std.ArrayList(FeatureMap) = .empty;
        var required_stage: [2]u16 = .{ 0, 0 };
        var next_bit: u32 = first_bit;
        for (infos[0..n]) |info| {
            const uses_global = info.flags.global and info.max_value == 1;
            const bits: u32 = if (uses_global) 0 else std.math.log2_int_ceil(u32, @as(u32, @min(max_value, info.max_value)) + 1);
            if (info.max_value == 0 or next_bit + bits > 32) continue;
            var index: [2]?u16 = .{ null, null };
            var found = false;
            for (0..2) |ti| {
                const ls = langsys[ti] orelse continue;
                const t = tables[ti].?;
                if (ls.required) |r| if (t.featureTag(r) == info.tag) {
                    required_stage[ti] = info.stage[ti];
                };
                for (0..ls.count) |k| {
                    const fi = ls.featureIndex(k);
                    if (t.featureTag(fi) == info.tag) {
                        index[ti] = fi;
                        found = true;
                        break;
                    }
                }
            }
            if (!found and !info.flags.has_fallback) continue;
            var fm: FeatureMap = undefined;
            if (uses_global) {
                fm = .{ .tag = info.tag, .mask = global_mask, .shift = 0, .one = global_mask };
            } else {
                const shift: u5 = @intCast(next_bit);
                const mask: u32 = @intCast((@as(u64, 1) << @intCast(next_bit + bits)) - (@as(u64, 1) << shift));
                next_bit += bits;
                p.global_mask |= (info.default_value << shift) & mask;
                fm = .{ .tag = info.tag, .mask = mask, .shift = shift, .one = (@as(u32, 1) << shift) & mask };
            }
            try features.append(a, fm);
            try mapped.append(a, .{ .info = info, .index = index, .mask = fm.mask });
        }
        p.features = features.items;

        var out: [2][]Stage = undefined;
        for (0..2) |ti| {
            var lookups: std.ArrayList(LookupMap) = .empty;
            var ends: std.ArrayList(usize) = .empty;
            var pauses: std.ArrayList(?PauseFn) = .empty;
            var stage_index: usize = 0;
            var last: usize = 0;
            for (0..b.current_stage[ti]) |stage| {
                if (tables[ti]) |table| {
                    if (langsys[ti]) |ls| if (ls.required) |r| if (required_stage[ti] == stage) {
                        try addLookups(a, &lookups, table, r, vars[ti], .{ .index = 0, .mask = global_mask });
                    };
                    for (mapped.items) |m| {
                        if (m.info.stage[ti] != stage) continue;
                        const fi = m.index[ti] orelse continue;
                        try addLookups(a, &lookups, table, fi, vars[ti], .{
                            .index = 0,
                            .mask = m.mask,
                            .auto_zwnj = !m.info.flags.manual_zwnj,
                            .auto_zwj = !m.info.flags.manual_zwj,
                            .random = m.info.flags.random,
                            .per_syllable = m.info.flags.per_syllable,
                        });
                    }
                }
                // Sort this stage's lookups and merge duplicates.
                const seg = lookups.items[last..];
                if (seg.len > 1) {
                    std.mem.sort(LookupMap, seg, {}, struct {
                        fn lt(_: void, x: LookupMap, y: LookupMap) bool {
                            return x.index < y.index;
                        }
                    }.lt);
                    var j: usize = 0;
                    for (seg[1..]) |l| {
                        if (l.index != seg[j].index) {
                            j += 1;
                            seg[j] = l;
                        } else {
                            seg[j].mask |= l.mask;
                            seg[j].auto_zwnj = seg[j].auto_zwnj and l.auto_zwnj;
                            seg[j].auto_zwj = seg[j].auto_zwj and l.auto_zwj;
                        }
                    }
                    lookups.shrinkRetainingCapacity(last + j + 1);
                }
                last = lookups.items.len;
                if (stage_index < b.stages[ti].items.len and b.stages[ti].items[stage_index].index == stage) {
                    try ends.append(a, last);
                    try pauses.append(a, b.stages[ti].items[stage_index].pause);
                    stage_index += 1;
                }
            }
            const stages = try a.alloc(Stage, ends.items.len);
            var start: usize = 0;
            for (stages, ends.items, pauses.items) |*st, end, pause| {
                st.* = .{ .lookups = lookups.items[start..end], .pause = pause };
                start = end;
            }
            out[ti] = stages;
        }
        p.gsub_stages = out[0];
        p.gpos_stages = out[1];

        // Accelerators for every lookup (nested ones included).
        const n_glyphs = p.inst.face.num_glyphs;
        for (out, tables, 0..) |stages, maybe, ti| {
            const t = maybe orelse continue;
            const accels = try digest.buildAccels(a, t, ti == 1, n_glyphs);
            p.accels[ti] = accels;
            for (stages) |st| for (@constCast(st.lookups)) |*lm| {
                lm.digest = accels[lm.index].digest;
            };
        }
    }

    fn computeSpaceParticipates(p: *const ShapePlan) bool {
        const space = p.space_glyph;
        if (space == 0) return false;
        if (p.apply_kern) if (p.kern) |k| if (k.involves(space)) return true;
        const sp = @import("space.zig");
        const tables = [2]?LayoutTable{ p.gsub, p.gpos };
        const stage_sets = [2][]const Stage{ p.gsub_stages, p.gpos_stages };
        for (tables, stage_sets, 0..) |maybe, stages, ti| {
            const t = maybe orelse continue;
            if (ti == 1 and !p.apply_gpos) continue;
            for (stages) |s| for (s.lookups) |l| {
                // A lookup outside the global mask runs only where masks are
                // set per glyph (fractions, ranged features), which the word
                // cache checks per run; complex shapers set masks anywhere.
                if (l.mask & p.global_mask == 0 and p.complex.setupMasks == null) continue;
                if (sp.lookupInvolves(t, l.index, space, if (ti == 0) 7 else 9)) return true;
            };
        }
        return false;
    }
};

fn selectLangSys(s: lc.ScriptTable, lang: Tag) ?lc.LangSys {
    const dflt = tag("dflt");
    if (lang != dflt) if (s.langSysExact(lang)) |l| return l;
    if (s.langSysExact(dflt)) |l| return l;
    return s.defaultLangSys();
}

fn addLookups(a: Allocator, out: *std.ArrayList(LookupMap), t: LayoutTable, feature_index: u16, variations: ?u32, proto: LookupMap) Allocator.Error!void {
    const f = t.feature(feature_index, variations) orelse return;
    for (0..f.count) |i| {
        const li = f.lookupIndex(i);
        if (li >= t.lookup_count) continue;
        var l = proto;
        l.index = li;
        try out.append(a, l);
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "plan: script tags" {
    try testing.expectEqual([3]?Tag{ tag("dev3"), tag("dev2"), tag("deva") }, otScriptTags(.Deva));
    try testing.expectEqual([3]?Tag{ tag("mym2"), tag("mymr"), null }, otScriptTags(.Mymr));
    try testing.expectEqual([3]?Tag{ tag("arab"), null, null }, otScriptTags(.Arab));
    try testing.expectEqual([3]?Tag{ tag("latn"), null, null }, otScriptTags(.Latn));
    try testing.expectEqual([3]?Tag{ tag("kana"), null, null }, otScriptTags(.Hira));
    try testing.expectEqual([3]?Tag{ tag("lao "), null, null }, otScriptTags(.Laoo));
    try testing.expectEqual([3]?Tag{ null, null, null }, otScriptTags(.Zyyy));
}
