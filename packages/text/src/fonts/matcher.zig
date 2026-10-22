//! Style matching (CSS Fonts 4 §5.2, step 4) and generic families.
//!
//! Within a family's faces, in order:
//! 1. width: the desired class if some face has it (a variable face
//!    when its wdth range holds it); otherwise, for normal or narrower,
//!    the nearest narrower width, then the nearest wider; for wider, the
//!    reverse.
//! 2. style: italic → italic, oblique, normal; oblique → oblique,
//!    italic, normal; normal → normal, oblique, italic. A face with an
//!    `ital` axis offers italic, one with `slnt` offers oblique.
//! 3. weight: desired in 400–500: desired..500 ascending, then below
//!    the desired descending, then above 500 ascending; below 400:
//!    descending then ascending; above 500: ascending then descending.
//!    A variable face offers every weight of its wght range.
//!
//! The result carries the axis settings for a variable face and the
//! synthesis needed: bold when 600+ was asked for and 400 or less was
//! found, oblique when a slanted style was asked for and none exists.

const std = @import("std");
const Allocator = std.mem.Allocator;
const db_mod = @import("db.zig");
const FontDb = db_mod.FontDb;
const FaceRef = db_mod.FaceRef;
const FaceInfo = db_mod.FaceInfo;
const Slant = db_mod.Slant;
const Axis = db_mod.Axis;
const AxisValue = @import("../ot/var/fvar.zig").AxisValue;
const tag = @import("../ot/reader.zig").tag;
const discovery = @import("discovery.zig");

pub const Query = struct {
    family: []const u8,
    weight: u16 = 400,
    /// Width class 1..9 (5 is normal).
    width: u8 = 5,
    slant: Slant = .normal,
};

/// Synthesized style the renderer applies.
pub const Synth = packed struct(u8) {
    bold: bool = false,
    oblique: bool = false,
    _: u6 = 0,

    pub fn eql(a: Synth, b: Synth) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }
};

/// The oblique angle used on a `slnt` axis (CSS's default 14deg;
/// `slnt` counts counter-clockwise, so negative).
pub const oblique_slnt: f32 = -14;

pub const Match = struct {
    face: FaceRef,
    /// The weight, width class and style found.
    weight: u16,
    width: u8,
    slant: Slant,
    synth: Synth = .{},
    coords: [4]AxisValue = undefined,
    coord_count: u8 = 0,

    /// Axis settings for the instance (empty for a static face).
    pub fn axisValues(m: *const Match) []const AxisValue {
        return m.coords[0..m.coord_count];
    }
};

/// Matches within the faces named `q.family` (no generic resolution).
pub fn matchFamily(d: *const FontDb, q: Query) ?Match {
    var buf: [512]FaceRef = undefined;
    var n: usize = 0;
    for (d.named(q.family)) |e| {
        if (n == buf.len) break;
        buf[n] = e.face;
        n += 1;
    }
    return matchFaces(d, buf[0..n], q);
}

fn styleAvailable(f: *const FaceInfo, s: Slant) bool {
    if (f.slantOf() == s) return true;
    if (f.slantOf() != .normal) return false;
    return switch (s) {
        .normal => false,
        .italic => f.axes & Axis.ital != 0,
        .oblique => f.axes & Axis.slnt != 0,
    };
}

const Ranges = struct {
    d: *const FontDb,
    faces: []const FaceRef,
    kind: enum { width, weight },

    fn range(r: Ranges, f: FaceRef) [2]u16 {
        const fi = r.d.face(f);
        return switch (r.kind) {
            .width => .{ fi.width_min, fi.width_max },
            .weight => .{ fi.weight_min, fi.weight_max },
        };
    }

    fn contains(r: Ranges, v: u16) bool {
        for (r.faces) |f| {
            const x = r.range(f);
            if (x[0] <= v and v <= x[1]) return true;
        }
        return false;
    }

    /// The smallest available value in [lo, hi].
    fn ascending(r: Ranges, lo: u16, hi: u16) ?u16 {
        var best: ?u16 = null;
        for (r.faces) |f| {
            const x = r.range(f);
            if (x[1] < lo) continue;
            const v = @max(x[0], lo);
            if (v > hi) continue;
            if (best == null or v < best.?) best = v;
        }
        return best;
    }

    /// The largest available value in [lo, hi].
    fn descending(r: Ranges, lo: u16, hi: u16) ?u16 {
        var best: ?u16 = null;
        for (r.faces) |f| {
            const x = r.range(f);
            if (x[0] > hi) continue;
            const v = @min(x[1], hi);
            if (v < lo) continue;
            if (best == null or v > best.?) best = v;
        }
        return best;
    }
};

fn pickWidth(r: Ranges, want: u8) ?u16 {
    if (r.contains(want)) return want;
    if (want <= 5) return r.descending(1, want -| 1) orelse r.ascending(want + 1, 9);
    return r.ascending(want + 1, 9) orelse r.descending(1, want - 1);
}

fn pickWeight(r: Ranges, want: u16) ?u16 {
    if (r.contains(want)) return want;
    if (want >= 400 and want <= 500)
        return r.ascending(want + 1, 500) orelse r.descending(1, want - 1) orelse r.ascending(501, 1000);
    if (want < 400) return r.descending(1, want -| 1) orelse r.ascending(want + 1, 1000);
    return r.ascending(want + 1, 1000) orelse r.descending(1, want - 1);
}

/// Keeps the faces of `faces` for which `keep` holds; returns the count.
fn filter(faces: []FaceRef, ctx: anytype, comptime keep: fn (@TypeOf(ctx), FaceRef) bool) usize {
    var n: usize = 0;
    for (faces) |f| if (keep(ctx, f)) {
        faces[n] = f;
        n += 1;
    };
    return n;
}

/// The best face of `candidates` for `q` (CSS Fonts 4 §5.2 step 4).
pub fn matchFaces(d: *const FontDb, candidates: []const FaceRef, q: Query) ?Match {
    if (candidates.len == 0) return null;
    var buf: [512]FaceRef = undefined;
    const n0 = @min(candidates.len, buf.len);
    @memcpy(buf[0..n0], candidates[0..n0]);
    var set = buf[0..n0];

    const want_w = @max(1, @min(q.width, 9));
    const w = pickWidth(.{ .d = d, .faces = set, .kind = .width }, want_w).?;
    const WCtx = struct { d: *const FontDb, w: u16 };
    set = set[0..filter(set, WCtx{ .d = d, .w = w }, struct {
        fn k(c: WCtx, f: FaceRef) bool {
            const fi = c.d.face(f);
            return fi.width_min <= c.w and c.w <= fi.width_max;
        }
    }.k)];

    const order: [3]Slant = switch (q.slant) {
        .italic => .{ .italic, .oblique, .normal },
        .oblique => .{ .oblique, .italic, .normal },
        .normal => .{ .normal, .oblique, .italic },
    };
    const SCtx = struct { d: *const FontDb, s: Slant };
    const s = for (order) |cand| {
        const any = for (set) |f| {
            if (styleAvailable(d.face(f), cand)) break true;
        } else false;
        if (any) break cand;
    } else unreachable;
    set = set[0..filter(set, SCtx{ .d = d, .s = s }, struct {
        fn k(c: SCtx, f: FaceRef) bool {
            return styleAvailable(c.d.face(f), c.s);
        }
    }.k)];

    const wt = pickWeight(.{ .d = d, .faces = set, .kind = .weight }, @max(1, @min(q.weight, 1000))).?;
    // Among faces offering the weight, a static face at exactly that
    // weight and style beats a variable one; otherwise the first.
    var best: ?FaceRef = null;
    for (set) |f| {
        const fi = d.face(f);
        if (fi.weight_min > wt or wt > fi.weight_max) continue;
        const exact = !fi.variable() and fi.slantOf() == s;
        if (best == null or (exact and d.face(best.?).variable())) best = f;
        if (exact) break;
    }
    const f = best.?;
    const fi = d.face(f);
    var m: Match = .{ .face = f, .weight = wt, .width = @intCast(w), .slant = s };
    if (fi.axes & Axis.wght != 0) m.coords[addCoord(&m)] = .{ .tag = tag("wght"), .value = @floatFromInt(wt) };
    if (fi.axes & Axis.wdth != 0) m.coords[addCoord(&m)] = .{ .tag = tag("wdth"), .value = db_mod.width_percent[w - 1] };
    if (fi.slantOf() == .normal and s == .italic and fi.axes & Axis.ital != 0)
        m.coords[addCoord(&m)] = .{ .tag = tag("ital"), .value = 1 };
    if (fi.slantOf() == .normal and s == .oblique and fi.axes & Axis.slnt != 0)
        m.coords[addCoord(&m)] = .{ .tag = tag("slnt"), .value = oblique_slnt };
    m.synth.bold = q.weight >= 600 and wt <= 400;
    m.synth.oblique = q.slant != .normal and s == .normal;
    return m;
}

fn addCoord(m: *Match) usize {
    m.coord_count += 1;
    return m.coord_count - 1;
}

/// CSS generic families.
pub const Generic = enum { monospace, sans_serif, serif, emoji, system_ui };

/// The generic family `name` names (`ui-monospace`, `ui-sans-serif` and
/// `ui-serif` included), or null.
pub fn genericOf(name: []const u8) ?Generic {
    const table = [_]struct { []const u8, Generic }{
        .{ "monospace", .monospace },   .{ "ui-monospace", .monospace },
        .{ "sans-serif", .sans_serif }, .{ "ui-sans-serif", .sans_serif },
        .{ "serif", .serif },           .{ "ui-serif", .serif },
        .{ "emoji", .emoji },           .{ "system-ui", .system_ui },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(name, e[0])) return e[1];
    return null;
}

/// The families to try for each generic family, best first.
pub const Generics = struct {
    lists: std.EnumArray(Generic, []const []const u8) = .initFill(&.{}),

    /// From fontconfig aliases (Linux). `system-ui` falls through to the
    /// `sans-serif` list.
    pub fn fromDiscovery(arena: Allocator, d: *const discovery.Discovery) Allocator.Error!Generics {
        var g: Generics = .{};
        g.lists.set(.monospace, try d.preferences(arena, "monospace"));
        g.lists.set(.sans_serif, try d.preferences(arena, "sans-serif"));
        g.lists.set(.serif, try d.preferences(arena, "serif"));
        g.lists.set(.emoji, try d.preferences(arena, "emoji"));
        const ui = try d.preferences(arena, "system-ui");
        g.lists.set(.system_ui, try std.mem.concat(arena, []const u8, &.{ ui, g.lists.get(.sans_serif) }));
        return g;
    }
};

/// Matches `q.family`, resolving a generic family through `generics`
/// (each listed family in order). When no listed family is installed,
/// a generic still resolves: monospace to the first monospaced face's
/// family, emoji to the first color face's, the others to the first
/// face's.
pub fn match(d: *const FontDb, generics: *const Generics, q: Query) ?Match {
    if (matchFamily(d, q)) |m| return m;
    const g = genericOf(q.family) orelse return null;
    for (generics.lists.get(g)) |fam| {
        var sub = q;
        sub.family = fam;
        if (matchFamily(d, sub)) |m| return m;
    }
    for (d.faces()) |*fi| {
        const ok = switch (g) {
            .monospace => fi.monospace,
            .emoji => fi.colorOf() != .none,
            else => fi.colorOf() == .none,
        };
        if (!ok) continue;
        var sub = q;
        sub.family = d.str(fi.typographic_family);
        return matchFamily(d, sub);
    }
    return null;
}
