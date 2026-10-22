//! Per-cluster font choice along a fallback chain.
//!
//! A chain is an ordered list of registered instances. `resolve` picks the
//! first instance that maps every visible code point of a grapheme
//! cluster, trying color instances first for emoji presentation.
//!
//! With a font database attached (`attachDb`), chains can be built from
//! family names (`chain`), and a cluster no chain instance maps goes on
//! to, in order: the emoji fonts (for emoji presentation), the OS
//! per-script defaults (Han by UI locale), the faces of the database's
//! coverage index (same monospace property and nearest weight first, at
//! most 64 tried), and finally `last_resort_instance`. Results for
//! single code points are cached per (chain, presentation, code point)
//! until the database snapshot changes. Without a database, an unmapped
//! cluster falls back to the chain's first instance (`.notdef`), as for
//! fixed UIs built with `chainOf`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const registry = @import("registry.zig");
const FontRegistry = registry.FontRegistry;
const InstanceId = registry.InstanceId;
const unicode = @import("../unicode/root.zig");
const decode = @import("../unicode/decode.zig");
const buffer = @import("../shape/buffer.zig");
const db_mod = @import("db.zig");
const FontDb = db_mod.FontDb;
const matcher = @import("matcher.zig");
const Script = unicode.Script;

pub const last_resort_instance = registry.last_resort_instance;

/// Han glyph conventions, chosen from the UI locale.
pub const HanVariant = enum { sc, tc, ja, ko };

/// The Han variant for a BCP 47 locale: zh-TW/zh-HK/zh-MO and
/// zh-Hant → traditional, ja → Japanese, ko → Korean, else simplified.
pub fn hanVariantOf(locale: []const u8) HanVariant {
    var it = std.mem.tokenizeAny(u8, locale, "-_.");
    const lang = it.next() orelse return .sc;
    if (std.ascii.eqlIgnoreCase(lang, "ja")) return .ja;
    if (std.ascii.eqlIgnoreCase(lang, "ko")) return .ko;
    if (!std.ascii.eqlIgnoreCase(lang, "zh")) return .sc;
    while (it.next()) |sub| {
        for ([_][]const u8{ "TW", "HK", "MO", "Hant" }) |t| if (std.ascii.eqlIgnoreCase(sub, t)) return .tc;
    }
    return .sc;
}

/// Families to try for one script (and Han variant, for `.Hani`).
pub const ScriptFallback = struct {
    script: Script,
    han: ?HanVariant = null,
    families: []const []const u8,
};

/// An OS's default families.
pub const OsDefaults = struct {
    ui: []const []const u8 = &.{},
    mono: []const []const u8 = &.{},
    serif: []const []const u8 = &.{},
    emoji: []const []const u8 = &.{},
    per_script: []const ScriptFallback = &.{},
};

/// Linux defaults, used after the fontconfig aliases.
pub const linux_defaults: OsDefaults = .{
    .ui = &.{ "Noto Sans", "DejaVu Sans" },
    .mono = &.{ "DejaVu Sans Mono", "Noto Sans Mono" },
    .serif = &.{ "Noto Serif", "DejaVu Serif" },
    .emoji = &.{"Noto Color Emoji"},
    .per_script = &.{
        .{ .script = .Hani, .han = .sc, .families = &.{ "Noto Sans CJK SC", "Source Han Sans SC", "WenQuanYi Zen Hei" } },
        .{ .script = .Hani, .han = .tc, .families = &.{ "Noto Sans CJK TC", "Source Han Sans TC" } },
        .{ .script = .Hani, .han = .ja, .families = &.{ "Noto Sans CJK JP", "Source Han Sans JP", "IPAGothic" } },
        .{ .script = .Hani, .han = .ko, .families = &.{ "Noto Sans CJK KR", "Source Han Sans KR", "NanumGothic" } },
        .{ .script = .Arab, .families = &.{ "Noto Sans Arabic", "Noto Naskh Arabic" } },
        .{ .script = .Hebr, .families = &.{"Noto Sans Hebrew"} },
        .{ .script = .Deva, .families = &.{"Noto Sans Devanagari"} },
        .{ .script = .Thai, .families = &.{"Noto Sans Thai"} },
        .{ .script = .Ethi, .families = &.{"Noto Sans Ethiopic"} },
        .{ .script = .Zyyy, .families = &.{ "Noto Sans Symbols", "Noto Sans Symbols 2", "DejaVu Sans" } },
    },
};

/// Where resolutions came from (diagnostics and tests).
pub const Stats = struct {
    cache_hits: u64 = 0,
    chain: u64 = 0,
    emoji: u64 = 0,
    script: u64 = 0,
    search: u64 = 0,
    last_resort: u64 = 0,
};

/// Candidates `resolve` tries from the coverage index.
pub const max_search = 64;

/// The database side of a `Fallback` (heap-allocated so `resolve` can
/// cache through a const pointer).
const Source = struct {
    reg: *FontRegistry,
    io: std.Io,
    db: *const FontDb,
    defaults: OsDefaults,
    generics: matcher.Generics,
    han: HanVariant = .sc,
    cache: std.AutoHashMapUnmanaged(u64, InstanceId) = .empty,
    /// A direct-mapped front of `cache` (key 0 marks an empty slot; real
    /// keys never are 0 since code point 0 is not cached).
    front: [256]struct { key: u64, id: InstanceId } = @splat(.{ .key = 0, .id = 0 }),
    stats: Stats = .{},

    fn clear(src: *Source) void {
        src.cache.clearRetainingCapacity();
        src.front = @splat(.{ .key = 0, .id = 0 });
    }

    fn slot(key: u64) usize {
        return @intCast((key *% 0x9E3779B97F4A7C15) >> 56);
    }
};

/// The style a chain asked for (default for `chainOf` chains).
pub const ChainStyle = struct {
    weight: u16 = 400,
    width: u8 = 5,
    slant: db_mod.Slant = .normal,
};

/// An interned fallback chain.
pub const ChainId = enum(u16) { _ };

/// The presentation a cluster asks for.
pub const Presentation = enum { text, emoji, default };

/// UTS #51 emoji presentation of a grapheme cluster: VS16, a keycap,
/// a modifier, ZWJ or tag sequence, a flag, or a base with
/// Emoji_Presentation; VS15 forces text.
pub fn emojiPresentation(cluster: []const u8) bool {
    var i: usize = 0;
    var first = true;
    var base_pres = false;
    var base_pict = false;
    var regional: u8 = 0;
    while (i < cluster.len) {
        const u = decode.at(cluster, i);
        i += u.len;
        const cp = u.cp;
        switch (cp) {
            0xFE0E => return false,
            0xFE0F, 0x20E3 => return true,
            0x1F3FB...0x1F3FF, 0xE0020...0xE007F => if (!first) return true,
            0x200D => if (base_pict) return true,
            0x1F1E6...0x1F1FF => regional += 1,
            else => {},
        }
        if (first) {
            const p = unicode.props(cp);
            base_pres = p.emoji_pres;
            base_pict = p.ext_pict;
            first = false;
        }
    }
    return base_pres or regional >= 2;
}

/// Chooses an instance per grapheme cluster.
pub const Fallback = struct {
    gpa: Allocator,
    reg: *const FontRegistry,
    chains: std.ArrayList([]const InstanceId) = .empty,
    styles: std.ArrayList(ChainStyle) = .empty,
    src: ?*Source = null,

    /// A resolver over the instances of `reg`.
    pub fn init(gpa: Allocator, reg: *const FontRegistry) Fallback {
        return .{ .gpa = gpa, .reg = reg };
    }

    /// Frees the chains and the database state.
    pub fn deinit(f: *Fallback) void {
        for (f.chains.items) |c| f.gpa.free(c);
        f.chains.deinit(f.gpa);
        f.styles.deinit(f.gpa);
        if (f.src) |src| {
            src.cache.deinit(f.gpa);
            f.gpa.destroy(src);
        }
        f.* = undefined;
    }

    /// The chain of `list` in order (interned; at least one).
    pub fn chainOf(f: *Fallback, list: []const InstanceId) Allocator.Error!ChainId {
        return f.intern(list, .{});
    }

    fn intern(f: *Fallback, list: []const InstanceId, style: ChainStyle) Allocator.Error!ChainId {
        std.debug.assert(list.len > 0);
        for (f.chains.items, f.styles.items, 0..) |c, st, i| {
            if (std.mem.eql(InstanceId, c, list) and std.meta.eql(st, style)) return @enumFromInt(i);
        }
        if (f.chains.items.len > std.math.maxInt(u16)) return error.OutOfMemory;
        const copy = try f.gpa.dupe(InstanceId, list);
        errdefer f.gpa.free(copy);
        try f.styles.ensureUnusedCapacity(f.gpa, 1);
        try f.chains.append(f.gpa, copy);
        f.styles.appendAssumeCapacity(style);
        return @enumFromInt(f.chains.items.len - 1);
    }

    /// Resolves through `db` from now on: `reg` (the registry this
    /// resolver was made with) opens database faces, `generics` names
    /// the families of generic names and emoji, `defaults` the OS
    /// per-script families.
    pub fn attachDb(f: *Fallback, reg: *FontRegistry, io: std.Io, db: *const FontDb, generics: matcher.Generics, defaults: OsDefaults) Allocator.Error!void {
        std.debug.assert(reg == f.reg);
        if (f.src == null) f.src = try f.gpa.create(Source);
        f.src.?.* = .{ .reg = reg, .io = io, .db = db, .defaults = defaults, .generics = generics };
    }

    /// Switches to a new database snapshot; cached resolutions are
    /// dropped when it differs (ids already handed out stay valid).
    pub fn setDb(f: *Fallback, db: *const FontDb) void {
        const src = f.src.?;
        if (src.db.generation != db.generation) src.clear();
        src.db = db;
    }

    /// Sets the UI locale (BCP 47), which picks the Han fonts.
    pub fn setLocale(f: *Fallback, locale: []const u8) void {
        const src = f.src.?;
        const v = hanVariantOf(locale);
        if (v != src.han) src.clear();
        src.han = v;
    }

    /// Where resolutions came from so far.
    pub fn stats(f: *const Fallback) Stats {
        return if (f.src) |src| src.stats else .{};
    }

    /// The chain of the installed `families` (generic names resolved)
    /// matched with `style`, interned. Families that are not installed
    /// are skipped; with none installed, the first face of the database
    /// stands in. Needs `attachDb`.
    pub fn chain(f: *Fallback, families: []const []const u8, style: ChainStyle) !ChainId {
        const src = f.src.?;
        var ids: std.ArrayList(InstanceId) = .empty;
        defer ids.deinit(f.gpa);
        for (families) |fam| {
            const m = matcher.match(src.db, &src.generics, .{ .family = fam, .weight = style.weight, .width = style.width, .slant = style.slant }) orelse continue;
            const id = src.reg.instance(src.io, src.db, m.face, m.axisValues(), m.synth) catch continue;
            if (std.mem.indexOfScalar(InstanceId, ids.items, id) == null) try ids.append(f.gpa, id);
        }
        if (ids.items.len == 0) {
            if (src.db.faces().len == 0) return error.NoFonts;
            const q: matcher.Query = .{ .family = src.db.str(src.db.faces()[0].typographic_family), .weight = style.weight, .width = style.width, .slant = style.slant };
            const m = matcher.matchFamily(src.db, q).?;
            try ids.append(f.gpa, try src.reg.instance(src.io, src.db, m.face, m.axisValues(), m.synth));
        }
        return f.intern(ids.items, style);
    }

    /// The instances of chain `id`.
    pub fn instances(f: *const Fallback, id: ChainId) []const InstanceId {
        return f.chains.items[@intFromEnum(id)];
    }

    /// The chain's first (primary) instance.
    pub fn primary(f: *const Fallback, id: ChainId) InstanceId {
        return f.instances(id)[0];
    }

    /// The instance to draw `cluster` with: one that maps it, or (with a
    /// database) `last_resort_instance`.
    pub fn resolve(f: *const Fallback, chain_id: ChainId, cluster: []const u8, presentation: Presentation) InstanceId {
        const list = f.instances(chain_id);
        if (cluster.len == 1 and cluster[0] < 0x80 and presentation != .emoji) {
            const bit = @as(u128, 1) << @intCast(cluster[0]);
            for (list) |id| if (f.reg.get(id).ascii & bit != 0) return id;
            if (f.src == null or cluster[0] < 0x20 or cluster[0] == 0x7F) return list[0];
        }
        const src = f.src orelse return f.resolveChain(list, cluster, emojiOf(cluster, presentation)) orelse list[0];
        // With a database, single code points are cached per (chain,
        // presentation, code point) whichever step resolves them.
        const first = decode.at(cluster, 0);
        const single = first.len == cluster.len and first.cp != 0;
        const key = @as(u64, @intFromEnum(chain_id)) << 40 | @as(u64, @intFromEnum(presentation)) << 22 | first.cp;
        if (single) {
            const fr = &src.front[Source.slot(key)];
            if (fr.key == key) {
                src.stats.cache_hits += 1;
                return fr.id;
            }
            if (src.cache.get(key)) |id| {
                src.stats.cache_hits += 1;
                fr.* = .{ .key = key, .id = id };
                return id;
            }
        }
        const emoji = emojiOf(cluster, presentation);
        const id = f.resolveChain(list, cluster, emoji) orelse f.resolveDb(src, chain_id, cluster, first.cp, emoji);
        if (single) {
            src.cache.put(f.gpa, key, id) catch {};
            src.front[Source.slot(key)] = .{ .key = key, .id = id };
        }
        return id;
    }

    fn emojiOf(cluster: []const u8, presentation: Presentation) bool {
        return switch (presentation) {
            .emoji => true,
            .text => false,
            .default => emojiPresentation(cluster),
        };
    }

    /// The first chain instance that maps `cluster` (color ones first
    /// for emoji).
    fn resolveChain(f: *const Fallback, list: []const InstanceId, cluster: []const u8, emoji: bool) ?InstanceId {
        if (emoji) for (list) |id| {
            if (f.reg.get(id).color and f.covers(id, cluster)) return id;
        };
        for (list) |id| if (f.covers(id, cluster)) return id;
        return null;
    }

    fn resolveDb(f: *const Fallback, src: *Source, chain_id: ChainId, cluster: []const u8, base: u21, emoji: bool) InstanceId {
        const db = src.db;
        const style = f.styles.items[@intFromEnum(chain_id)];
        const q: matcher.Query = .{ .family = "", .weight = style.weight, .width = style.width, .slant = style.slant };
        if (emoji) {
            for ([_][]const []const u8{ src.generics.lists.get(.emoji), src.defaults.emoji }) |fams| for (fams) |fam| {
                if (f.tryFamily(src, fam, q, cluster)) |id| {
                    src.stats.emoji += 1;
                    return id;
                }
            };
        }
        // OS per-script defaults; Han by locale (kana → Japanese,
        // Hangul → Korean, Bopomofo → traditional).
        const script = unicode.props(base).script;
        const han: ?HanVariant = switch (script) {
            .Hani => src.han,
            .Hira, .Kana => .ja,
            .Hang => .ko,
            .Bopo => .tc,
            else => null,
        };
        for (src.defaults.per_script) |sf| {
            const ok = if (han) |v| sf.script == .Hani and sf.han == v else sf.script == script;
            if (!ok) continue;
            for (sf.families) |fam| if (f.tryFamily(src, fam, q, cluster)) |id| {
                src.stats.script += 1;
                return id;
            };
        }
        // The coverage index: color matching the presentation, the same
        // monospace property as the primary, then nearest weight.
        const mono = f.reg.get(f.instances(chain_id)[0]).monospace;
        var it = db.coveringFaces(base);
        var best: ?db_mod.FaceRef = null;
        var best_score: u32 = std.math.maxInt(u32);
        var tried: usize = 0;
        while (it.next()) |face| {
            if (tried == max_search) break;
            tried += 1;
            const fi = db.face(face);
            if (!dbCovers(db, face, cluster)) continue;
            const w = std.math.clamp(style.weight, fi.weight_min, fi.weight_max);
            // Color faces only when nothing else maps a text cluster.
            const score = @as(u32, @intFromBool((fi.colorOf() != .none) != emoji)) << 17 |
                @as(u32, @intFromBool(fi.monospace != mono)) << 16 | @abs(@as(i32, w) - @as(i32, style.weight));
            if (score < best_score) {
                best = face;
                best_score = score;
            }
        }
        if (best) |face| {
            var fq = q;
            fq.family = db.str(db.face(face).typographic_family);
            if (matcher.matchFaces(db, &.{face}, fq)) |m| {
                if (src.reg.instance(src.io, db, face, m.axisValues(), m.synth)) |id| {
                    src.stats.search += 1;
                    return id;
                } else |_| {}
            }
        }
        src.stats.last_resort += 1;
        return last_resort_instance;
    }

    /// The instance of `fam` matched with `q` when it maps `cluster`.
    fn tryFamily(f: *const Fallback, src: *Source, fam: []const u8, q: matcher.Query, cluster: []const u8) ?InstanceId {
        _ = f;
        var fq = q;
        fq.family = fam;
        const m = matcher.matchFamily(src.db, fq) orelse return null;
        if (!dbCovers(src.db, m.face, cluster)) return null;
        return src.reg.instance(src.io, src.db, m.face, m.axisValues(), m.synth) catch null;
    }

    /// True when instance `id` maps every code point of `cluster` that is
    /// drawn (default-ignorables and variation selectors are not).
    pub fn covers(f: *const Fallback, id: InstanceId, cluster: []const u8) bool {
        const face = f.reg.get(id).inst.face;
        var i: usize = 0;
        while (i < cluster.len) {
            const u = decode.at(cluster, i);
            i += u.len;
            if (buffer.isDefaultIgnorable(u.cp) or buffer.isVariationSelector(u.cp)) continue;
            if (u.cp < 0x20 or u.cp == 0x7F) continue;
            if (face.glyphIndex(u.cp) == 0) return false;
        }
        return true;
    }
};

/// True when database face `face` maps every drawn code point of
/// `cluster` (as `Fallback.covers`).
fn dbCovers(db: *const FontDb, face: db_mod.FaceRef, cluster: []const u8) bool {
    var i: usize = 0;
    while (i < cluster.len) {
        const u = decode.at(cluster, i);
        i += u.len;
        if (buffer.isDefaultIgnorable(u.cp) or buffer.isVariationSelector(u.cp)) continue;
        if (u.cp < 0x20 or u.cp == 0x7F) continue;
        if (!db.covers(face, u.cp)) return false;
    }
    return true;
}
