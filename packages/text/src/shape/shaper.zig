//! The shaping driver: UTF-8 in, positioned glyphs out. One `Shaper` per
//! thread owns a reusable buffer and a small plan cache; a warm shaper does
//! not allocate except for the caller's output arena.
//!
//! Order of work follows HarfBuzz's `hb_ot_shape_internal` so results match
//! it glyph for glyph: Unicode properties and grapheme clusters, RTL
//! mirroring, normalization, masks, GSUB, advances, GPOS (or the `kern`
//! table), mark zeroing, attachment resolution, hiding default ignorables
//! and finally reversal of RTL runs into visual order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ot = @import("../ot/root.zig");
const Tag = ot.Tag;
const GlyphId = ot.GlyphId;
const FaceInstance = @import("../ot/var/instance.zig").FaceInstance;
const unicode = @import("../unicode/root.zig");
const Script = unicode.Script;
const GlyphProps = @import("../ot/gdef.zig").GlyphProps;
const buffer = @import("buffer.zig");
const Buffer = buffer.Buffer;
const GlyphInfo = buffer.GlyphInfo;
const GlyphPos = buffer.GlyphPos;
const Direction = buffer.Direction;
const Feature = buffer.Feature;
const plan_mod = @import("plan.zig");
const ShapePlan = plan_mod.ShapePlan;
const ComplexShaper = plan_mod.ComplexShaper;
const skippy = @import("skippy.zig");
const apply_gsub = @import("apply_gsub.zig");
const apply_gpos = @import("apply_gpos.zig");
const normalize = @import("normalize.zig");

/// Shaper output in font units, visual order, structure of arrays.
pub const GlyphRun = struct {
    gids: []GlyphId = &.{},
    /// Byte offset (in the shaped text) of each glyph's cluster.
    clusters: []u32 = &.{},
    x_adv: []i32 = &.{},
    x_off: []i32 = &.{},
    y_off: []i32 = &.{},
    /// Breaking the line before this glyph needs reshaping.
    unsafe_to_break: []bool = &.{},

    /// Number of glyphs.
    pub fn len(r: GlyphRun) usize {
        return r.gids.len;
    }

    /// Arrays for `n` glyphs from `arena`.
    pub fn alloc(arena: Allocator, n: usize) Allocator.Error!GlyphRun {
        return .{
            .gids = try arena.alloc(GlyphId, n),
            .clusters = try arena.alloc(u32, n),
            .x_adv = try arena.alloc(i32, n),
            .x_off = try arena.alloc(i32, n),
            .y_off = try arena.alloc(i32, n),
            .unsafe_to_break = try arena.alloc(bool, n),
        };
    }
};

const plan_cache_size = 16;

const PlanKey = struct {
    inst: *const FaceInstance,
    script: Script,
    lang: Tag,
    dir: Direction,
    features: u64,

    fn eql(a: PlanKey, b: PlanKey) bool {
        return a.inst == b.inst and a.script == b.script and a.lang == b.lang and a.dir == b.dir and a.features == b.features;
    }
};

fn featureHash(features: []const Feature) u64 {
    var h = std.hash.Wyhash.init(0x5a17);
    for (features) |f| h.update(std.mem.asBytes(&f));
    return h.final();
}

/// One per thread: a reusable buffer and a small plan cache.
pub const Shaper = struct {
    gpa: Allocator,
    buf: Buffer,
    keys: [plan_cache_size]?PlanKey = @splat(null),
    plans: [plan_cache_size]ShapePlan = undefined,
    next_slot: usize = 0,

    /// An empty shaper.
    pub fn init(gpa: Allocator) Shaper {
        return .{ .gpa = gpa, .buf = Buffer.init(gpa) };
    }

    /// Frees the buffer and cached plans.
    pub fn deinit(s: *Shaper) void {
        for (s.keys, &s.plans) |k, *p| if (k != null) p.deinit();
        s.buf.deinit();
        s.* = undefined;
    }

    /// Drops cached plans for `inst` (call before freeing it).
    pub fn forget(s: *Shaper, inst: *const FaceInstance) void {
        for (&s.keys, &s.plans) |*k, *p| if (k.*) |key| if (key.inst == inst) {
            p.deinit();
            k.* = null;
        };
    }

    /// The plan for these settings, built on first use.
    pub fn plan(s: *Shaper, inst: *const FaceInstance, script: Script, lang: Tag, dir: Direction, features: []const Feature) Allocator.Error!*const ShapePlan {
        const key: PlanKey = .{ .inst = inst, .script = script, .lang = lang, .dir = dir, .features = featureHash(features) };
        for (s.keys, 0..) |k, i| if (k) |v| if (v.eql(key)) return &s.plans[i];
        const slot = s.next_slot;
        s.next_slot = (slot + 1) % plan_cache_size;
        const p = try ShapePlan.build(s.gpa, inst, script, lang, dir, null, features);
        if (s.keys[slot] != null) s.plans[slot].deinit();
        s.plans[slot] = p;
        s.keys[slot] = key;
        return &s.plans[slot];
    }

    /// Shapes `text` (one script, one direction) into `out`, allocated from
    /// `arena`. Clusters are byte offsets into `text`; RTL output is in
    /// visual order, so its clusters decrease.
    pub fn shape(s: *Shaper, inst: *const FaceInstance, text: []const u8, script: Script, dir: Direction, lang: Tag, features: []const Feature, out: *GlyphRun, arena: Allocator) Allocator.Error!void {
        const p = try s.plan(inst, script, lang, dir, features);
        try s.shapeWithPlan(p, text);
        out.* = try s.collect(arena);
    }

    /// Shapes `text` into the shaper's buffer with an existing plan.
    pub fn shapeWithPlan(s: *Shaper, p: *const ShapePlan, text: []const u8) Allocator.Error!void {
        const b = &s.buf;
        b.reset();
        b.dir = p.dir;
        b.script = p.script;
        b.lang = p.lang;
        try b.addUtf8(text, 0);
        try run(p, b);
    }

    /// Copies the buffer into a `GlyphRun` from `arena`.
    pub fn collect(s: *const Shaper, arena: Allocator) Allocator.Error!GlyphRun {
        const b = &s.buf;
        var r = try GlyphRun.alloc(arena, b.len());
        for (b.infos.items, b.pos.items, 0..) |g, p, i| {
            r.gids[i] = g.gid;
            r.clusters[i] = g.cluster;
            r.x_adv[i] = p.x_adv;
            r.x_off[i] = p.x_off;
            r.y_off[i] = p.y_off;
            r.unsafe_to_break[i] = g.unsafe_to_break;
        }
        return r;
    }
};

/// Runs the whole pipeline over a filled buffer.
pub fn run(p: *const ShapePlan, b: *Buffer) Allocator.Error!void {
    const face = p.inst.face;
    for (b.infos.items) |*g| g.mask = p.global_mask;
    buffer.setUnicodeProps(b);
    buffer.formClusters(b);

    // Shape against the script's native direction: a Latin run laid out
    // RTL is shaped LTR with its graphemes reversed (HarfBuzz's
    // `hb_ensure_native_direction`).
    var dir = p.dir;
    if (nativeDirection(p.script, b)) |native| if (native != dir) {
        reverseGraphemes(b);
        dir = native;
    };

    // RTL mirroring: use the mirrored character when the font has it, else
    // let `rtlm` do it.
    if (p.dir == .rtl) {
        for (b.infos.items) |*g| {
            if (unicode.mirror(g.cp)) |m| {
                if (face.glyphIndex(m) != 0) {
                    g.cp = m;
                    continue;
                }
            }
            g.mask |= p.rtlm_mask;
        }
    }

    try normalize.normalize(face, b, p.complex.reorderMarks);
    setupMasks(p, b);

    // GSUB.
    const infos_props = b.infos.items;
    for (infos_props) |*g| {
        g.glyph_props = if (p.gdef.has_glyph_classes) p.gdef.glyphProps(g.gid) else synthesized(g.*);
        g.lig_props = 0;
    }
    var budget = skippy.OpBudget.init(b.len());
    try b.computeGlyphSet(face.num_glyphs);
    if (p.gsub) |table| {
        var c: skippy.Ctx = .{ .buf = b, .table = table, .kind = .gsub, .gdef = &p.gdef, .budget = &budget, .coords = p.coords, .var_scalars = p.var_scalars, .accels = p.accels[0] };
        for (p.gsub_stages) |stage| {
            try apply_gsub.applyLookups(&c, stage.lookups);
            if (stage.pause) |f| f(p, b);
        }
    } else for (p.gsub_stages) |stage| if (stage.pause) |f| f(p, b);

    // Advances.
    try b.pos.resize(b.gpa, b.len());
    for (b.infos.items, b.pos.items) |g, *pos| {
        pos.* = .{ .x_adv = @intFromFloat(@round(p.inst.advance(g.gid))) };
    }
    fallbackSpaces(p, b);

    // GPOS or the kern table.
    const adjust = p.adjust_mark_positioning_when_zeroing and dir == .ltr;
    if (p.zero_marks and p.complex.zero_marks == .gdef_early) zeroMarks(b, adjust);
    var gpos_budget = skippy.OpBudget.init(b.len());
    try b.computeGlyphSet(face.num_glyphs);
    if (p.apply_gpos) if (p.gpos) |table| {
        var c: skippy.Ctx = .{ .buf = b, .table = table, .kind = .gpos, .gdef = &p.gdef, .budget = &gpos_budget, .coords = p.coords, .var_scalars = p.var_scalars, .rtl = dir == .rtl, .accels = p.accels[1] };
        for (p.gpos_stages) |stage| {
            try apply_gpos.applyLookups(&c, stage.lookups);
            if (stage.pause) |f| f(p, b);
        }
    };
    if (p.apply_kern) if (p.kern) |*k| k.apply(b, &p.gdef, p.kern_mask);
    if (p.zero_marks and p.complex.zero_marks == .gdef_late) zeroMarks(b, adjust);
    if (b.has_default_ignorables) {
        for (b.infos.items, b.pos.items) |g, *pos| if (g.isDefaultIgnorable()) {
            pos.* = .{ .attach_chain = pos.attach_chain, .attach_type = pos.attach_type };
        };
    }
    apply_gpos.resolveAttachments(b, dir);

    hideDefaultIgnorables(p, b);
    if (dir == .rtl) b.reverseRange(0, b.len());
}

/// The horizontal direction `script` is written in; null for scripts
/// written both ways. Digits-only runs of RTL scripts count as LTR.
fn nativeDirection(script: Script, b: *const Buffer) ?Direction {
    switch (script) {
        .Arab, .Hebr, .Syrc, .Thaa, .Cprt, .Khar, .Phnx, .Nkoo, .Lydi, .Avst, .Armi, .Phli, .Prti, .Sarb, .Orkh, .Samr, .Mand, .Merc, .Mero, .Mani, .Mend, .Nbat, .Narb, .Palm, .Phlp, .Hatr, .Adlm, .Rohg, .Sogo, .Sogd, .Elym, .Chrs, .Yezi, .Ougr, .Gara => {
            var number = false;
            for (b.infos.items) |g| switch (g.gc) {
                .Nd => number = true,
                .Lu, .Ll, .Lt, .Lm, .Lo => return .rtl,
                else => {},
            };
            return if (number) .ltr else .rtl;
        },
        .Hung, .Ital, .Runr, .Tfng => return null,
        else => return .ltr,
    }
}

/// Reverses the order of grapheme clusters, keeping each one's glyphs in
/// logical order.
fn reverseGraphemes(b: *Buffer) void {
    const infos = b.infos.items;
    std.mem.reverse(GlyphInfo, infos);
    var start: usize = 0;
    var i: usize = 0;
    // After the full reversal a grapheme's continuations come first; a
    // group ends at its base (the first glyph without the flag).
    while (i < infos.len) : (i += 1) {
        if (infos[i].uflags & buffer.UFlags.continuation != 0) continue;
        std.mem.reverse(GlyphInfo, infos[start .. i + 1]);
        start = i + 1;
    }
    if (start < infos.len) std.mem.reverse(GlyphInfo, infos[start..]);
}

fn synthesized(g: GlyphInfo) u16 {
    return if (g.gc != .Mn or g.isDefaultIgnorable()) GlyphProps.base else GlyphProps.mark;
}

fn setupMasks(p: *const ShapePlan, b: *Buffer) void {
    const infos = b.infos.items;
    if (p.has_frac and b.has_non_ascii) {
        var pre = p.frac_mask | p.numr_mask;
        var post = p.frac_mask | p.dnom_mask;
        if (p.dir == .rtl) std.mem.swap(u32, &pre, &post);
        var i: usize = 0;
        while (i < infos.len) : (i += 1) {
            if (infos[i].cp != 0x2044) continue;
            var start = i;
            var end = i + 1;
            while (start > 0 and infos[start - 1].gc == .Nd) start -= 1;
            while (end < infos.len and infos[end].gc == .Nd) end += 1;
            if (start == i or end == i + 1) continue;
            b.unsafeToBreak(start, end);
            for (infos[start..i]) |*g| g.mask |= pre;
            infos[i].mask |= p.frac_mask;
            for (infos[i + 1 .. end]) |*g| g.mask |= post;
            i = end - 1;
        }
    }
    if (p.complex.setupMasks) |f| f(p, b);
    for (p.ranged) |f| {
        const m = p.maskOf(f.tag);
        if (m.mask == 0) continue;
        const value = (@as(u32, f.value) << m.shift) & m.mask;
        for (infos) |*g| if (g.cluster >= f.start and g.cluster < f.end) {
            g.mask = (g.mask & ~m.mask) | value;
        };
    }
}

fn fallbackSpaces(p: *const ShapePlan, b: *Buffer) void {
    const face = p.inst.face;
    const upem: i32 = face.units_per_em;
    for (b.infos.items, b.pos.items) |g, *pos| switch (g.space) {
        .none, .space => {},
        .em_1, .em_2, .em_3, .em_4, .em_5, .em_6, .em_16 => {
            const n: i32 = @intFromEnum(g.space);
            pos.x_adv = @divTrunc(upem + @divTrunc(n, 2), n);
        },
        .em_4_18 => pos.x_adv = @divTrunc(upem * 4, 18),
        .figure => {
            var d: u21 = '0';
            while (d <= '9') : (d += 1) {
                const gid = face.glyphIndex(d);
                if (gid != 0) {
                    pos.x_adv = @intFromFloat(@round(p.inst.advance(gid)));
                    break;
                }
            }
        },
        .punctuation => {
            var gid = face.glyphIndex('.');
            if (gid == 0) gid = face.glyphIndex(',');
            if (gid != 0) pos.x_adv = @intFromFloat(@round(p.inst.advance(gid)));
        },
        .narrow => pos.x_adv = @divTrunc(pos.x_adv, 2),
    };
}

fn zeroMarks(b: *Buffer, adjust: bool) void {
    for (b.infos.items, b.pos.items) |g, *pos| if (g.isMark()) {
        if (adjust) {
            pos.x_off -= pos.x_adv;
            pos.y_off -= pos.y_adv;
        }
        pos.x_adv = 0;
        pos.y_adv = 0;
    };
}

/// Default ignorables that GSUB left alone become the space glyph (zero
/// advance already), or are deleted when the font has no space.
fn hideDefaultIgnorables(p: *const ShapePlan, b: *Buffer) void {
    if (!b.has_default_ignorables) return;
    if (p.space_glyph != 0) {
        for (b.infos.items) |*g| if (g.isDefaultIgnorable()) {
            g.gid = p.space_glyph;
        };
        return;
    }
    var i: usize = 0;
    while (i < b.len()) {
        if (b.infos.items[i].isDefaultIgnorable()) {
            b.deleteAt(i);
            _ = b.pos.orderedRemove(i);
        } else i += 1;
    }
}
