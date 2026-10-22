//! Builds the full per-code-point property arrays and auxiliary maps from
//! the UCD text files. This is the "naive reference": plain arrays indexed
//! by code point, which `emit.zig` compresses and `zg_text` tests compare
//! against.

const std = @import("std");
const parse = @import("parse.zig");
const e = @import("ucd_enums");
const Props = e.Props;
const Aux = e.Aux;

/// Number of code points.
pub const code_points = 0x110000;

/// Every input file, relative to the version directory, in a fixed order.
pub const files = [_][]const u8{
    "UnicodeData.txt",
    "DerivedCoreProperties.txt",
    "PropList.txt",
    "PropertyValueAliases.txt",
    "EastAsianWidth.txt",
    "LineBreak.txt",
    "BidiBrackets.txt",
    "BidiMirroring.txt",
    "Scripts.txt",
    "ScriptExtensions.txt",
    "CaseFolding.txt",
    "SpecialCasing.txt",
    "CompositionExclusions.txt",
    "DerivedNormalizationProps.txt",
    "ArabicShaping.txt",
    "IndicSyllabicCategory.txt",
    "IndicPositionalCategory.txt",
    "extracted/DerivedBidiClass.txt",
    "extracted/DerivedGeneralCategory.txt",
    "auxiliary/GraphemeBreakProperty.txt",
    "auxiliary/WordBreakProperty.txt",
    "emoji/emoji-data.txt",
    "emoji/emoji-variation-sequences.txt",
};

/// Index of `name` in `files` (comptime).
pub fn fileIndex(comptime name: []const u8) usize {
    inline for (files, 0..) |f, i| if (comptime std.mem.eql(u8, f, name)) return i;
    @compileError("unknown UCD file " ++ name);
}

/// File contents in `files` order.
pub const Inputs = [files.len][]const u8;

/// A code point mapped to a sequence.
pub const Seq = struct { cp: u21, cps: []const u21 };

/// A code point range with its Script_Extensions.
pub const ScxRange = struct { lo: u21, hi: u21, scripts: []const e.Script };

/// Case mapping kinds.
pub const CaseKind = enum(u2) { lower = 0, upper = 1, title = 2 };

/// A full (multi-code-point) case mapping.
pub const CaseFull = struct { cp: u21, kind: CaseKind, cps: []const u21 };

/// A canonical primary composite: `a` + `b` -> `c`.
pub const Composite = struct { a: u21, b: u21, c: u21 };

/// Where an unknown property value was found.
pub const Diag = struct {
    file: []const u8 = "",
    line: usize = 0,
    value: []const u8 = "",
    enum_name: []const u8 = "",
};

/// Build errors.
pub const Error = error{ UnknownPropertyValue, BadFirstLast, OutOfMemory } || parse.Error;

/// Everything the generator emits, as plain uncompressed data.
pub const Ucd = struct {
    arena: std.heap.ArenaAllocator,
    props: []Props,
    aux: []Aux,
    scx: []ScxRange,
    mirror: [][2]u21,
    brackets: [][2]u21,
    /// Full canonical decompositions (NFD), sorted by code point.
    decomp_canon: []Seq,
    /// Full compatibility decompositions (NFKD) where they differ from the
    /// canonical one, sorted by code point.
    decomp_compat: []Seq,
    compose: []Composite,
    /// C+S foldings.
    fold_simple: [][2]u21,
    /// C+F foldings (also the C entries, so every fold is here).
    fold_full: []Seq,
    /// Simple mappings: cp, upper, lower, title (only cps where one differs).
    case_simple: [][4]u21,
    /// Unconditional SpecialCasing entries.
    case_full: []CaseFull,

    /// Frees everything.
    pub fn deinit(u: *Ucd) void {
        u.arena.deinit();
    }
};

fn lookup(comptime E: type, value: []const u8, diag: *Diag, file: []const u8, line: usize) Error!E {
    if (E.fromAlias(value)) |v| return v;
    diag.* = .{ .file = file, .line = line, .value = value, .enum_name = @typeName(E) };
    return error.UnknownPropertyValue;
}

/// Applies a single-valued property file: `@missing` lines first (in
/// order, later ones override sub-ranges), then data lines.
fn applyEnum(comptime E: type, text: []const u8, file: []const u8, diag: *Diag, out: anytype, comptime setter: fn (@TypeOf(out), u21, u21, E) void, comptime prop_field: ?[]const u8, field_index: usize) Error!void {
    inline for (.{ true, false }) |missing_pass| {
        var it = parse.Iterator.init(text);
        while (try it.next()) |l| {
            if (l.missing != missing_pass) continue;
            var idx = field_index;
            if (prop_field) |pf| {
                if (!std.mem.eql(u8, l.field(0), pf)) continue;
                idx = 1;
            }
            const v = try lookup(E, l.field(idx), diag, file, l.number);
            setter(out, l.lo, l.hi, v);
        }
    }
}

/// Applies a binary property: every data line whose first field is `name`.
fn applyBool(text: []const u8, name: []const u8, out: anytype, comptime setter: fn (@TypeOf(out), u21, u21) void) parse.Error!void {
    var it = parse.Iterator.init(text);
    while (try it.next()) |l| {
        if (l.missing) continue;
        if (std.mem.eql(u8, l.field(0), name)) setter(out, l.lo, l.hi);
    }
}

/// Builds every table from `in`. On `error.UnknownPropertyValue`, `diag`
/// names the file, line, value and enum.
pub fn build(gpa: std.mem.Allocator, in: *const Inputs, diag: *Diag) Error!Ucd {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const props = try a.alloc(Props, code_points);
    @memset(props, .{});
    const aux = try a.alloc(Aux, code_points);
    @memset(aux, .{});
    const P = []Props;
    const X = []Aux;

    // General_Category (with Cn for unassigned) and Bidi_Class (with block defaults).
    try applyEnum(e.GeneralCategory, in[fileIndex("extracted/DerivedGeneralCategory.txt")], "extracted/DerivedGeneralCategory.txt", diag, props, struct {
        fn f(p: P, lo: u21, hi: u21, v: e.GeneralCategory) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.gc = v;
        }
    }.f, null, 0);
    try applyEnum(e.BidiClass, in[fileIndex("extracted/DerivedBidiClass.txt")], "extracted/DerivedBidiClass.txt", diag, props, struct {
        fn f(p: P, lo: u21, hi: u21, v: e.BidiClass) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.bidi = v;
        }
    }.f, null, 0);
    try applyEnum(e.GraphemeBreak, in[fileIndex("auxiliary/GraphemeBreakProperty.txt")], "auxiliary/GraphemeBreakProperty.txt", diag, props, struct {
        fn f(p: P, lo: u21, hi: u21, v: e.GraphemeBreak) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.gcb = v;
        }
    }.f, null, 0);
    try applyEnum(e.WordBreak, in[fileIndex("auxiliary/WordBreakProperty.txt")], "auxiliary/WordBreakProperty.txt", diag, props, struct {
        fn f(p: P, lo: u21, hi: u21, v: e.WordBreak) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.wb = v;
        }
    }.f, null, 0);
    try applyEnum(e.LineBreak, in[fileIndex("LineBreak.txt")], "LineBreak.txt", diag, props, struct {
        fn f(p: P, lo: u21, hi: u21, v: e.LineBreak) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.lb = v;
        }
    }.f, null, 0);
    try applyEnum(e.EastAsianWidth, in[fileIndex("EastAsianWidth.txt")], "EastAsianWidth.txt", diag, props, struct {
        fn f(p: P, lo: u21, hi: u21, v: e.EastAsianWidth) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.eaw = v;
        }
    }.f, null, 0);
    try applyEnum(e.Script, in[fileIndex("Scripts.txt")], "Scripts.txt", diag, props, struct {
        fn f(p: P, lo: u21, hi: u21, v: e.Script) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.script = v;
        }
    }.f, null, 0);
    try applyEnum(e.IndicConjunctBreak, in[fileIndex("DerivedCoreProperties.txt")], "DerivedCoreProperties.txt", diag, props, struct {
        fn f(p: P, lo: u21, hi: u21, v: e.IndicConjunctBreak) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.incb = v;
        }
    }.f, "InCB", 1);
    try applyEnum(e.QuickCheck, in[fileIndex("DerivedNormalizationProps.txt")], "DerivedNormalizationProps.txt", diag, props, struct {
        fn f(p: P, lo: u21, hi: u21, v: e.QuickCheck) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.nfc_qc = v;
        }
    }.f, "NFC_QC", 1);
    const dnp = in[fileIndex("DerivedNormalizationProps.txt")];
    try applyEnum(e.QuickCheck, dnp, "DerivedNormalizationProps.txt", diag, aux, struct {
        fn f(p: X, lo: u21, hi: u21, v: e.QuickCheck) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.nfd_qc = v;
        }
    }.f, "NFD_QC", 1);
    try applyEnum(e.QuickCheck, dnp, "DerivedNormalizationProps.txt", diag, aux, struct {
        fn f(p: X, lo: u21, hi: u21, v: e.QuickCheck) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.nfkd_qc = v;
        }
    }.f, "NFKD_QC", 1);
    try applyEnum(e.QuickCheck, dnp, "DerivedNormalizationProps.txt", diag, aux, struct {
        fn f(p: X, lo: u21, hi: u21, v: e.QuickCheck) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.nfkc_qc = v;
        }
    }.f, "NFKC_QC", 1);
    try applyEnum(e.IndicSyllabic, in[fileIndex("IndicSyllabicCategory.txt")], "IndicSyllabicCategory.txt", diag, aux, struct {
        fn f(p: X, lo: u21, hi: u21, v: e.IndicSyllabic) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.isc = v;
        }
    }.f, null, 0);
    try applyEnum(e.IndicPositional, in[fileIndex("IndicPositionalCategory.txt")], "IndicPositionalCategory.txt", diag, aux, struct {
        fn f(p: X, lo: u21, hi: u21, v: e.IndicPositional) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.ipc = v;
        }
    }.f, null, 0);

    // Binary properties.
    const dcp = in[fileIndex("DerivedCoreProperties.txt")];
    try applyBool(dcp, "Cased", aux, struct {
        fn f(p: X, lo: u21, hi: u21) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.cased = true;
        }
    }.f);
    try applyBool(dcp, "Case_Ignorable", aux, struct {
        fn f(p: X, lo: u21, hi: u21) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.case_ignorable = true;
        }
    }.f);
    try applyBool(dcp, "Default_Ignorable_Code_Point", aux, struct {
        fn f(p: X, lo: u21, hi: u21) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.default_ignorable = true;
        }
    }.f);
    try applyBool(in[fileIndex("PropList.txt")], "White_Space", aux, struct {
        fn f(p: X, lo: u21, hi: u21) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.white_space = true;
        }
    }.f);
    try applyBool(dnp, "Full_Composition_Exclusion", aux, struct {
        fn f(p: X, lo: u21, hi: u21) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.full_comp_ex = true;
        }
    }.f);
    const emoji = in[fileIndex("emoji/emoji-data.txt")];
    inline for (.{ .{ "Extended_Pictographic", "ext_pict" }, .{ "Emoji", "emoji" }, .{ "Emoji_Presentation", "emoji_pres" }, .{ "Emoji_Modifier", "emoji_mod" }, .{ "Emoji_Modifier_Base", "emoji_mod_base" } }) |pair| {
        try applyBool(emoji, pair[0], props, struct {
            fn f(p: P, lo: u21, hi: u21) void {
                for (p[lo .. @as(usize, hi) + 1]) |*x| @field(x, pair[1]) = true;
            }
        }.f);
    }
    {
        // The code point field is "XXXX FE0E"; parse the base only.
        var lines = std.mem.splitScalar(u8, in[fileIndex("emoji/emoji-variation-sequences.txt")], '\n');
        while (lines.next()) |raw| {
            const s = std.mem.trim(u8, raw, " \t\r");
            if (s.len == 0 or s[0] == '#') continue;
            const sp = std.mem.indexOfAny(u8, s, " ;") orelse continue;
            aux[try parse.parseCp(s[0..sp])].vs_base = true;
        }
    }

    // UnicodeData: ccc, mirrored, decompositions, simple case mappings.
    var raw_decomp: std.AutoHashMapUnmanaged(u21, struct { compat: bool, cps: []const u21 }) = .empty;
    var case_simple: std.ArrayList([4]u21) = .empty;
    {
        var it = parse.UnicodeDataIterator.init(in[fileIndex("UnicodeData.txt")]);
        while (try it.next()) |r| {
            const ccc = std.fmt.parseInt(u8, r.fields[2], 10) catch return error.BadCodePoint;
            const mirrored = std.mem.eql(u8, r.fields[8], "Y");
            for (props[r.lo .. @as(usize, r.hi) + 1]) |*x| {
                x.ccc = ccc;
                x.bidi_mirrored = mirrored;
            }
            if (r.lo != r.hi) continue;
            const cp = r.lo;
            var d = r.fields[4];
            if (d.len > 0) {
                const compat = d[0] == '<';
                if (compat) d = d[(std.mem.indexOfScalar(u8, d, '>') orelse return error.BadCodePoint) + 1 ..];
                var buf: [32]u21 = undefined;
                const cps = try a.dupe(u21, try parse.parseCps(d, &buf));
                try raw_decomp.put(a, cp, .{ .compat = compat, .cps = cps });
                aux[cp].has_decomp = true;
            }
            const up = if (r.fields[11].len > 0) try parse.parseCp(r.fields[11]) else cp;
            const lo = if (r.fields[12].len > 0) try parse.parseCp(r.fields[12]) else cp;
            const ti = if (r.fields[13].len > 0) try parse.parseCp(r.fields[13]) else up;
            if (up != cp or lo != cp or ti != cp) {
                try case_simple.append(a, .{ cp, up, lo, ti });
                aux[cp].has_case_map = true;
            }
        }
    }

    // Joining_Type: explicit entries, else T for Mn/Me/Cf, else U.
    for (props) |*x| x.jt = switch (x.gc) {
        .Mn, .Me, .Cf => .T,
        else => .U,
    };
    {
        var it = parse.Iterator.init(in[fileIndex("ArabicShaping.txt")]);
        while (try it.next()) |l| {
            if (l.missing) continue;
            const v = try lookup(e.JoiningType, l.field(1), diag, "ArabicShaping.txt", l.number);
            for (props[l.lo .. @as(usize, l.hi) + 1]) |*x| x.jt = v;
        }
    }

    // Brackets and mirroring.
    var brackets: std.ArrayList([2]u21) = .empty;
    {
        var it = parse.Iterator.init(in[fileIndex("BidiBrackets.txt")]);
        while (try it.next()) |l| {
            if (l.missing) continue;
            const v = try lookup(e.BracketType, l.field(1), diag, "BidiBrackets.txt", l.number);
            props[l.lo].bpt = v;
            try brackets.append(a, .{ l.lo, try parse.parseCp(l.field(0)) });
        }
    }
    var mirror: std.ArrayList([2]u21) = .empty;
    {
        var it = parse.Iterator.init(in[fileIndex("BidiMirroring.txt")]);
        while (try it.next()) |l| {
            if (l.missing) continue;
            try mirror.append(a, .{ l.lo, try parse.parseCp(l.field(0)) });
        }
    }

    // Script_Extensions.
    var scx: std.ArrayList(ScxRange) = .empty;
    {
        var it = parse.Iterator.init(in[fileIndex("ScriptExtensions.txt")]);
        while (try it.next()) |l| {
            if (l.missing) continue;
            var list: std.ArrayList(e.Script) = .empty;
            var toks = std.mem.tokenizeScalar(u8, l.field(0), ' ');
            while (toks.next()) |t| try list.append(a, try lookup(e.Script, t, diag, "ScriptExtensions.txt", l.number));
            try scx.append(a, .{ .lo = l.lo, .hi = l.hi, .scripts = list.items });
        }
    }

    // Case folding.
    var fold_simple: std.ArrayList([2]u21) = .empty;
    var fold_full: std.ArrayList(Seq) = .empty;
    {
        var it = parse.Iterator.init(in[fileIndex("CaseFolding.txt")]);
        while (try it.next()) |l| {
            if (l.missing) continue;
            const status = l.field(0);
            var buf: [8]u21 = undefined;
            const cps = try parse.parseCps(l.field(1), &buf);
            if (std.mem.eql(u8, status, "C") or std.mem.eql(u8, status, "S")) try fold_simple.append(a, .{ l.lo, cps[0] });
            if (std.mem.eql(u8, status, "C") or std.mem.eql(u8, status, "F")) try fold_full.append(a, .{ .cp = l.lo, .cps = try a.dupe(u21, cps) });
            if (!std.mem.eql(u8, status, "T")) aux[l.lo].has_fold = true;
        }
    }

    // Unconditional full case mappings (fields: lower; title; upper; [condition]).
    var case_full: std.ArrayList(CaseFull) = .empty;
    {
        var it = parse.Iterator.init(in[fileIndex("SpecialCasing.txt")]);
        while (try it.next()) |l| {
            if (l.missing or l.n > 3) continue;
            inline for (.{ .{ 0, CaseKind.lower }, .{ 1, CaseKind.title }, .{ 2, CaseKind.upper } }) |k| {
                var buf: [8]u21 = undefined;
                const cps = try parse.parseCps(l.field(k[0]), &buf);
                try case_full.append(a, .{ .cp = l.lo, .kind = k[1], .cps = try a.dupe(u21, cps) });
            }
            aux[l.lo].has_case_map = true;
        }
        std.mem.sort(CaseFull, case_full.items, {}, struct {
            fn lt(_: void, x: CaseFull, y: CaseFull) bool {
                return if (x.cp != y.cp) x.cp < y.cp else @intFromEnum(x.kind) < @intFromEnum(y.kind);
            }
        }.lt);
    }

    // Decompositions: full canonical and full compatibility expansions.
    var canon: std.ArrayList(Seq) = .empty;
    var compat: std.ArrayList(Seq) = .empty;
    var compose: std.ArrayList(Composite) = .empty;
    {
        var keys: std.ArrayList(u21) = .empty;
        var kit = raw_decomp.keyIterator();
        while (kit.next()) |k| try keys.append(a, k.*);
        std.mem.sort(u21, keys.items, {}, std.sort.asc(u21));
        for (keys.items) |cp| {
            const raw = raw_decomp.get(cp).?;
            var c_out: std.ArrayList(u21) = .empty;
            var k_out: std.ArrayList(u21) = .empty;
            try expand(a, &raw_decomp, cp, false, &c_out);
            try expand(a, &raw_decomp, cp, true, &k_out);
            if (!raw.compat) try canon.append(a, .{ .cp = cp, .cps = c_out.items });
            if (raw.compat or !std.mem.eql(u21, c_out.items, k_out.items)) try compat.append(a, .{ .cp = cp, .cps = k_out.items });
            if (!raw.compat and raw.cps.len == 2 and !aux[cp].full_comp_ex)
                try compose.append(a, .{ .a = raw.cps[0], .b = raw.cps[1], .c = cp });
        }
        std.mem.sort(Composite, compose.items, {}, struct {
            fn lt(_: void, x: Composite, y: Composite) bool {
                return if (x.a != y.a) x.a < y.a else x.b < y.b;
            }
        }.lt);
    }

    // Everything the runtime binary-searches is sorted by code point.
    const pairLt = struct {
        fn lt(_: void, x: [2]u21, y: [2]u21) bool {
            return x[0] < y[0];
        }
    }.lt;
    std.mem.sort([2]u21, mirror.items, {}, pairLt);
    std.mem.sort([2]u21, brackets.items, {}, pairLt);
    std.mem.sort([2]u21, fold_simple.items, {}, pairLt);
    std.mem.sort(Seq, fold_full.items, {}, struct {
        fn lt(_: void, x: Seq, y: Seq) bool {
            return x.cp < y.cp;
        }
    }.lt);
    std.mem.sort(ScxRange, scx.items, {}, struct {
        fn lt(_: void, x: ScxRange, y: ScxRange) bool {
            return x.lo < y.lo;
        }
    }.lt);

    return .{
        .arena = arena,
        .props = props,
        .aux = aux,
        .scx = scx.items,
        .mirror = mirror.items,
        .brackets = brackets.items,
        .decomp_canon = canon.items,
        .decomp_compat = compat.items,
        .compose = compose.items,
        .fold_simple = fold_simple.items,
        .fold_full = fold_full.items,
        .case_simple = case_simple.items,
        .case_full = case_full.items,
    };
}

fn expand(a: std.mem.Allocator, raw: anytype, cp: u21, compat: bool, out: *std.ArrayList(u21)) !void {
    if (raw.get(cp)) |d| if (compat or !d.compat) {
        for (d.cps) |c| try expand(a, raw, c, compat, out);
        return;
    };
    try out.append(a, cp);
}

/// Checks `ucd_enums` against PropertyValueAliases.txt: every value listed
/// for a property must exist in its enum.
pub fn checkAliases(pva: []const u8, diag: *Diag) Error!void {
    var lines = std.mem.splitScalar(u8, pva, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        var s = raw;
        if (std.mem.indexOfScalar(u8, s, '#')) |h| s = s[0..h];
        s = std.mem.trim(u8, s, " \t\r");
        if (s.len == 0) continue;
        var f = std.mem.splitScalar(u8, s, ';');
        const prop = std.mem.trim(u8, f.first(), " ");
        const value = std.mem.trim(u8, f.next() orelse continue, " ");
        inline for (enum_props) |ep| {
            if (std.mem.eql(u8, prop, ep[0])) {
                if (ep[1].fromAlias(value) == null and !(ep.len > 2 and isGroup(value))) {
                    diag.* = .{ .file = "PropertyValueAliases.txt", .line = n, .value = value, .enum_name = @typeName(ep[1]) };
                    return error.UnknownPropertyValue;
                }
            }
        }
    }
}

fn isGroup(v: []const u8) bool {
    for ([_][]const u8{ "C", "L", "LC", "M", "N", "P", "S", "Z" }) |g| if (std.mem.eql(u8, v, g)) return true;
    return false;
}

/// PropertyValueAliases property names and their enums; a third element
/// marks General_Category, whose group values are not stored.
pub const enum_props = .{
    .{ "gc", e.GeneralCategory, true },
    .{ "GCB", e.GraphemeBreak },
    .{ "InCB", e.IndicConjunctBreak },
    .{ "WB", e.WordBreak },
    .{ "lb", e.LineBreak },
    .{ "bc", e.BidiClass },
    .{ "bpt", e.BracketType },
    .{ "ea", e.EastAsianWidth },
    .{ "sc", e.Script },
    .{ "jt", e.JoiningType },
    .{ "NFC_QC", e.QuickCheck },
    .{ "InSC", e.IndicSyllabic },
    .{ "InPC", e.IndicPositional },
};

test "unknown alias names the enum" {
    var diag: Diag = .{};
    try std.testing.expectError(error.UnknownPropertyValue, checkAliases("lb ; ZZ ; Zebra_Break\n", &diag));
    try std.testing.expectEqualStrings("ZZ", diag.value);
    try std.testing.expect(std.mem.endsWith(u8, diag.enum_name, "LineBreak"));
    try checkAliases("lb ; AL ; Alphabetic\ngc ; LC ; Cased_Letter\n", &diag);
}

test "missing override order" {
    var props: [0x10]Props = @splat(.{});
    var diag: Diag = .{};
    const text =
        \\# @missing: 0000..000F; L
        \\# @missing: 0005..0007; R
        \\0006; AN
    ;
    try applyEnum(e.BidiClass, text, "t", &diag, @as([]Props, &props), struct {
        fn f(p: []Props, lo: u21, hi: u21, v: e.BidiClass) void {
            for (p[lo .. @as(usize, hi) + 1]) |*x| x.bidi = v;
        }
    }.f, null, 0);
    try std.testing.expectEqual(e.BidiClass.L, props[4].bidi);
    try std.testing.expectEqual(e.BidiClass.R, props[5].bidi);
    try std.testing.expectEqual(e.BidiClass.AN, props[6].bidi);
    try std.testing.expectEqual(e.BidiClass.R, props[7].bidi);
}
