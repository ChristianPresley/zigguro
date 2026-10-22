//! `ucdgen regex`: emits the Unicode tables zg_regex needs (E05.F03.S01.T02)
//! as one Zig source file, `regex_tables.zig`:
//!
//! - range tables for every General_Category value (including the groups
//!   L, LC, M, N, P, S, Z, C), every Script, every Script_Extensions value,
//!   and every binary property in PropList.txt, DerivedCoreProperties.txt
//!   and emoji-data.txt, plus Any, ASCII and Assigned;
//! - name tables keyed by the UAX44-LM3 loose form (case, spaces, `_` and
//!   `-` ignored) holding every alias from PropertyValueAliases.txt and the
//!   binary property aliases of PropertyAliases.txt (which is not vendored,
//!   so the short names are listed here);
//! - simple case-fold orbits from CaseFolding.txt (statuses C and S).
//!
//! It reads the raw UCD files with `parse.zig` and does not need the rest of
//! ucdgen's model, so zg_regex stays at layer 1 with no zg_text dependency.

const std = @import("std");
const parse = @import("parse.zig");
const lib = @import("lib.zig");

const Allocator = std.mem.Allocator;

/// Input files, relative to the version directory, in argument order.
pub const files = [_][]const u8{
    "extracted/DerivedGeneralCategory.txt",
    "Scripts.txt",
    "ScriptExtensions.txt",
    "PropList.txt",
    "DerivedCoreProperties.txt",
    "emoji/emoji-data.txt",
    "PropertyValueAliases.txt",
    "CaseFolding.txt",
};

/// File contents in `files` order.
pub const Inputs = [files.len][]const u8;

const n_cp = 0x110000;

/// General_Category groups (UAX #44 table 12).
const gc_groups = [_]struct { []const u8, []const []const u8 }{
    .{ "L", &.{ "Lu", "Ll", "Lt", "Lm", "Lo" } },
    .{ "LC", &.{ "Lu", "Ll", "Lt" } },
    .{ "M", &.{ "Mn", "Mc", "Me" } },
    .{ "N", &.{ "Nd", "Nl", "No" } },
    .{ "P", &.{ "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po" } },
    .{ "S", &.{ "Sm", "Sc", "Sk", "So" } },
    .{ "Z", &.{ "Zs", "Zl", "Zp" } },
    .{ "C", &.{ "Cc", "Cf", "Cs", "Co", "Cn" } },
};

/// Short aliases of binary properties (from PropertyAliases.txt).
const binary_aliases = [_]struct { []const u8, []const []const u8 }{
    .{ "ASCII_Hex_Digit", &.{"AHex"} },
    .{ "Alphabetic", &.{"Alpha"} },
    .{ "Bidi_Control", &.{"Bidi_C"} },
    .{ "Case_Ignorable", &.{"CI"} },
    .{ "Changes_When_Casefolded", &.{"CWCF"} },
    .{ "Changes_When_Casemapped", &.{"CWCM"} },
    .{ "Changes_When_Lowercased", &.{"CWL"} },
    .{ "Changes_When_Titlecased", &.{"CWT"} },
    .{ "Changes_When_Uppercased", &.{"CWU"} },
    .{ "Dash", &.{} },
    .{ "Default_Ignorable_Code_Point", &.{"DI"} },
    .{ "Deprecated", &.{"Dep"} },
    .{ "Diacritic", &.{"Dia"} },
    .{ "Emoji_Component", &.{"EComp"} },
    .{ "Emoji_Modifier", &.{"EMod"} },
    .{ "Emoji_Modifier_Base", &.{"EBase"} },
    .{ "Emoji_Presentation", &.{"EPres"} },
    .{ "Extended_Pictographic", &.{"ExtPict"} },
    .{ "Extender", &.{"Ext"} },
    .{ "Grapheme_Base", &.{"Gr_Base"} },
    .{ "Grapheme_Extend", &.{"Gr_Ext"} },
    .{ "Hex_Digit", &.{"Hex"} },
    .{ "IDS_Binary_Operator", &.{"IDSB"} },
    .{ "IDS_Trinary_Operator", &.{"IDST"} },
    .{ "IDS_Unary_Operator", &.{"IDSU"} },
    .{ "ID_Continue", &.{"IDC"} },
    .{ "ID_Start", &.{"IDS"} },
    .{ "Ideographic", &.{"Ideo"} },
    .{ "Join_Control", &.{"Join_C"} },
    .{ "Logical_Order_Exception", &.{"LOE"} },
    .{ "Lowercase", &.{"Lower"} },
    .{ "Math", &.{} },
    .{ "Noncharacter_Code_Point", &.{"NChar"} },
    .{ "Pattern_Syntax", &.{"Pat_Syn"} },
    .{ "Pattern_White_Space", &.{"Pat_WS"} },
    .{ "Prepended_Concatenation_Mark", &.{"PCM"} },
    .{ "Quotation_Mark", &.{"QMark"} },
    .{ "Radical", &.{} },
    .{ "Regional_Indicator", &.{"RI"} },
    .{ "Sentence_Terminal", &.{"STerm"} },
    .{ "Soft_Dotted", &.{"SD"} },
    .{ "Terminal_Punctuation", &.{"Term"} },
    .{ "Unified_Ideograph", &.{"UIdeo"} },
    .{ "Uppercase", &.{"Upper"} },
    .{ "Variation_Selector", &.{"VS"} },
    .{ "White_Space", &.{ "WSpace", "space" } },
    .{ "XID_Continue", &.{"XIDC"} },
    .{ "XID_Start", &.{"XIDS"} },
};

/// Writes the UAX44-LM3 loose form of `s` (lowercase; spaces, `_` and `-`
/// dropped; a leading "is" is kept here and stripped by the lookup) into
/// `buf` and returns it.
pub fn looseKey(s: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (c == ' ' or c == '_' or c == '-' or c == '\t') continue;
        if (n == buf.len) break;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

const Value = struct {
    names: std.ArrayList([]const u8) = .empty,
    member: std.DynamicBitSetUnmanaged = .{},
};

const Property = struct {
    values: std.ArrayList(Value) = .empty,

    fn find(p: *const Property, name: []const u8) ?usize {
        for (p.values.items, 0..) |v, i| for (v.names.items) |n| if (std.mem.eql(u8, n, name)) return i;
        return null;
    }

    fn add(p: *Property, arena: Allocator, names: []const []const u8) !usize {
        var v: Value = .{};
        try v.names.appendSlice(arena, names);
        v.member = try .initEmpty(arena, n_cp);
        try p.values.append(arena, v);
        return p.values.items.len - 1;
    }
};

/// The tables built from the inputs.
pub const Tables = struct {
    gc: Property = .{},
    sc: Property = .{},
    scx: Property = .{},
    binary: Property = .{},
    /// Case-fold orbits, each sorted, ordered by first member.
    orbits: std.ArrayList([]u21) = .empty,
    /// `\w` in Unicode mode (UTS #18 Annex C): Alphabetic, M, Nd, Pc and
    /// Join_Control.
    perl_word: std.DynamicBitSetUnmanaged = .{},
};

/// Errors from `build`.
pub const Error = error{ UnknownValue, OutOfMemory } || parse.Error;

fn setRange(bs: *std.DynamicBitSetUnmanaged, lo: u21, hi: u21) void {
    bs.setRangeValue(.{ .start = lo, .end = @as(usize, hi) + 1 }, true);
}

/// Builds all tables from `in` into `arena`.
pub fn build(arena: Allocator, in: *const Inputs) Error!Tables {
    var t: Tables = .{};
    const pva = in[6];

    // Value aliases for gc and sc.
    var it = parse.Iterator.init(pva);
    while (try nextPva(&it)) |l| {
        const prop = l.prop;
        const target: ?*Property = if (std.mem.eql(u8, prop, "gc")) &t.gc else if (std.mem.eql(u8, prop, "sc")) &t.sc else null;
        if (target) |p| {
            _ = try p.add(arena, l.names[0..l.n]);
            if (p == &t.sc) _ = try t.scx.add(arena, l.names[0..l.n]);
        }
    }

    // General_Category: every code point defaults to Cn.
    {
        const cn = t.gc.find("Cn") orelse return error.UnknownValue;
        setRange(&t.gc.values.items[cn].member, 0, 0x10FFFF);
        var gi = parse.Iterator.init(in[0]);
        while (try gi.next()) |l| {
            if (l.missing) continue;
            const v = t.gc.find(l.field(0)) orelse return error.UnknownValue;
            t.gc.values.items[cn].member.setRangeValue(.{ .start = l.lo, .end = @as(usize, l.hi) + 1 }, false);
            setRange(&t.gc.values.items[v].member, l.lo, l.hi);
        }
        for (gc_groups) |g| {
            const gv = t.gc.find(g[0]) orelse return error.UnknownValue;
            for (g[1]) |m| {
                const mv = t.gc.find(m) orelse return error.UnknownValue;
                t.gc.values.items[gv].member.setUnion(t.gc.values.items[mv].member);
            }
        }
    }

    // Script: default Zzzz (Unknown).
    var sc_of = try arena.alloc(u16, n_cp);
    {
        const zzzz = t.sc.find("Zzzz") orelse return error.UnknownValue;
        @memset(sc_of, @intCast(zzzz));
        var si = parse.Iterator.init(in[1]);
        while (try si.next()) |l| {
            if (l.missing) continue;
            const v = t.sc.find(l.field(0)) orelse return error.UnknownValue;
            @memset(sc_of[l.lo .. @as(usize, l.hi) + 1], @intCast(v));
        }
        for (sc_of, 0..) |v, cp| t.sc.values.items[v].member.set(cp);
    }

    // Script_Extensions: listed ranges replace the default {Script}.
    {
        var listed = try std.DynamicBitSetUnmanaged.initEmpty(arena, n_cp);
        var xi = parse.Iterator.init(in[2]);
        while (try xi.next()) |l| {
            if (l.missing) continue;
            setRange(&listed, l.lo, l.hi);
            var names = std.mem.tokenizeScalar(u8, l.field(0), ' ');
            while (names.next()) |n| {
                const v = t.scx.find(n) orelse return error.UnknownValue;
                setRange(&t.scx.values.items[v].member, l.lo, l.hi);
            }
        }
        for (sc_of, 0..) |v, cp| if (!listed.isSet(cp)) t.scx.values.items[v].member.set(cp);
    }

    // Binary properties: specials first, then every one-field data line.
    {
        const any = try t.binary.add(arena, &.{"Any"});
        setRange(&t.binary.values.items[any].member, 0, 0x10FFFF);
        const ascii = try t.binary.add(arena, &.{"ASCII"});
        setRange(&t.binary.values.items[ascii].member, 0, 0x7F);
        const assigned = try t.binary.add(arena, &.{"Assigned"});
        setRange(&t.binary.values.items[assigned].member, 0, 0x10FFFF);
        const cn = t.gc.find("Cn").?;
        var inv = t.gc.values.items[cn].member;
        var it_cn = inv.iterator(.{});
        while (it_cn.next()) |cp| t.binary.values.items[assigned].member.unset(cp);
        for ([_]usize{ 3, 4, 5 }) |fi| {
            var bi = parse.Iterator.init(in[fi]);
            while (try bi.next()) |l| {
                if (l.missing or l.n != 1) continue;
                const name = l.field(0);
                const v = t.binary.find(name) orelse blk: {
                    var names: std.ArrayList([]const u8) = .empty;
                    try names.append(arena, name);
                    for (binary_aliases) |a| if (std.mem.eql(u8, a[0], name)) try names.appendSlice(arena, a[1]);
                    break :blk try t.binary.add(arena, names.items);
                };
                setRange(&t.binary.values.items[v].member, l.lo, l.hi);
            }
        }
    }

    // `\w` (UTS #18 Annex C), precomputed so translation never unions tables.
    {
        t.perl_word = try .initEmpty(arena, n_cp);
        for ([_][]const u8{ "M", "Nd", "Pc" }) |v| t.perl_word.setUnion(t.gc.values.items[t.gc.find(v) orelse return error.UnknownValue].member);
        for ([_][]const u8{ "Alphabetic", "Join_Control" }) |v| t.perl_word.setUnion(t.binary.values.items[t.binary.find(v) orelse return error.UnknownValue].member);
    }

    // Simple case folding orbits: group code points by fold target.
    {
        var fold = std.AutoArrayHashMapUnmanaged(u21, std.ArrayList(u21)).empty;
        var fi = parse.Iterator.init(in[7]);
        while (try fi.next()) |l| {
            if (l.missing) continue;
            const status = l.field(0);
            if (!(std.mem.eql(u8, status, "C") or std.mem.eql(u8, status, "S"))) continue;
            const target = try parse.parseCp(l.field(1));
            const gop = try fold.getOrPut(arena, target);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
                try gop.value_ptr.append(arena, target);
            }
            try gop.value_ptr.append(arena, l.lo);
        }
        for (fold.values()) |*members| {
            std.mem.sort(u21, members.items, {}, std.sort.asc(u21));
            try t.orbits.append(arena, members.items);
        }
        std.mem.sort([]u21, t.orbits.items, {}, struct {
            fn lt(_: void, a: []u21, b: []u21) bool {
                return a[0] < b[0];
            }
        }.lt);
    }
    return t;
}

const PvaLine = struct { prop: []const u8, names: [8][]const u8, n: usize };

fn nextPva(it: *parse.Iterator) parse.Error!?PvaLine {
    // PropertyValueAliases.txt lines do not start with a code point, so walk
    // the raw lines here rather than through `Iterator.next`.
    while (it.lines.next()) |raw| {
        it.number += 1;
        var s = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.indexOfScalar(u8, s, '#')) |h| s = s[0..h];
        s = std.mem.trim(u8, s, " \t");
        if (s.len == 0) continue;
        var fields = std.mem.splitScalar(u8, s, ';');
        var line: PvaLine = .{ .prop = std.mem.trim(u8, fields.first(), " \t"), .names = undefined, .n = 0 };
        while (fields.next()) |f| {
            const v = std.mem.trim(u8, f, " \t");
            if (v.len == 0 or line.n == line.names.len) continue;
            // Skip duplicates (`sc ; Zyyy ; Common` style lines repeat none,
            // but `n/a` placeholders appear in some properties).
            line.names[line.n] = v;
            line.n += 1;
        }
        return line;
    }
    return null;
}

fn writeRanges(w: *std.Io.Writer, bs: std.DynamicBitSetUnmanaged) !usize {
    var count: usize = 0;
    try w.writeAll("&.{");
    var cp: usize = 0;
    while (cp < n_cp) {
        if (!bs.isSet(cp)) {
            cp += 1;
            continue;
        }
        const lo = cp;
        while (cp < n_cp and bs.isSet(cp)) cp += 1;
        try w.print(".{{0x{X},0x{X}}},", .{ lo, cp - 1 });
        count += 1;
    }
    try w.writeAll("}");
    return count;
}

const NameEntry = struct { key: []const u8, index: usize };

fn writeProperty(arena: Allocator, w: *std.Io.Writer, comptime ident: []const u8, p: *const Property) !usize {
    var total: usize = 0;
    try w.print("/// Range tables of `{s}` values, indexed by the `{s}_names` entries.\npub const {s} = [_][]const Range{{\n", .{ ident, ident, ident });
    for (p.values.items) |v| {
        try w.writeAll("    ");
        total += try writeRanges(w, v.member);
        try w.print(", // {s}\n", .{v.names.items[0]});
    }
    try w.writeAll("};\n\n");

    var names: std.ArrayList(NameEntry) = .empty;
    for (p.values.items, 0..) |v, i| for (v.names.items) |n| {
        var buf: [128]u8 = undefined;
        const key = try arena.dupe(u8, looseKey(n, &buf));
        try names.append(arena, .{ .key = key, .index = i });
    };
    // Stable sort, so a key used by two values (rare) keeps the first.
    std.mem.sort(NameEntry, names.items, {}, struct {
        fn lt(_: void, a: NameEntry, b: NameEntry) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lt);
    try w.print("/// Loose-matched names of `{s}` values, sorted by key.\npub const {s}_names = [_]Name{{\n", .{ ident, ident });
    var prev: []const u8 = "";
    for (names.items) |e| {
        if (std.mem.eql(u8, e.key, prev)) continue;
        prev = e.key;
        try w.print("    .{{ .key = \"{s}\", .index = {d} }},\n", .{ e.key, e.index });
    }
    try w.writeAll("};\n\n");
    return total;
}

/// Writes `regex_tables.zig`.
pub fn writeZig(arena: Allocator, w: *std.Io.Writer, version: []const u8, t: *const Tables) !void {
    try w.print(
        \\//! Unicode {s} tables for zg_regex, generated by `ucdgen regex`. Do not edit.
        \\
        \\/// A closed code point range `[lo, hi]`.
        \\pub const Range = [2]u21;
        \\/// A loose-matching key and the index of its value table.
        \\pub const Name = struct {{ key: []const u8, index: u16 }};
        \\/// One case-fold orbit: `len` code points starting at `orbit_cps[start]`.
        \\pub const Orbit = struct {{ start: u16, len: u8 }};
        \\
        \\/// The UCD version.
        \\pub const ucd_version = "{s}";
        \\
        \\
    , .{ version, version });
    var ranges: usize = 0;
    ranges += try writeProperty(arena, w, "general_category", &t.gc);
    ranges += try writeProperty(arena, w, "script", &t.sc);
    ranges += try writeProperty(arena, w, "script_extensions", &t.scx);
    ranges += try writeProperty(arena, w, "binary", &t.binary);
    try w.writeAll("/// `\\w` in Unicode mode: Alphabetic, M, Nd, Pc and Join_Control.\npub const perl_word: []const Range = ");
    ranges += try writeRanges(w, t.perl_word);
    try w.writeAll(";\n\n");

    try w.writeAll("/// Code points of every orbit, orbit after orbit, each sorted.\npub const orbit_cps = [_]u21{\n");
    var n: usize = 0;
    for (t.orbits.items) |o| {
        try w.writeAll("   ");
        for (o) |cp| try w.print(" 0x{X},", .{cp});
        try w.writeByte('\n');
        n += o.len;
    }
    try w.writeAll("};\n\n/// For each code point in an orbit (sorted by code point), its orbit.\npub const fold_index = [_]struct { cp: u21, orbit: Orbit }{\n");
    var entries: std.ArrayList(struct { cp: u21, start: usize, len: usize }) = .empty;
    var start: usize = 0;
    for (t.orbits.items) |o| {
        for (o) |cp| try entries.append(arena, .{ .cp = cp, .start = start, .len = o.len });
        start += o.len;
    }
    std.mem.sort(@TypeOf(entries.items[0]), entries.items, {}, struct {
        fn lt(_: void, a: @TypeOf(entries.items[0]), b: @TypeOf(entries.items[0])) bool {
            return a.cp < b.cp;
        }
    }.lt);
    for (entries.items) |e| try w.print("    .{{ .cp = 0x{X}, .orbit = .{{ .start = {d}, .len = {d} }} }},\n", .{ e.cp, e.start, e.len });
    try w.print("}};\n\n/// Total number of ranges in all tables (for size reports).\npub const total_ranges = {d};\n", .{ranges});
}

/// `ucdgen regex --version <v> --manifest <manifest.zon> <files...> <out-dir>`.
pub fn main(arena: Allocator, io: std.Io, args: []const []const u8, verify: anytype) !u8 {
    if (args.len != 4 + files.len + 1 or !std.mem.eql(u8, args[0], "--version") or !std.mem.eql(u8, args[2], "--manifest")) {
        std.debug.print("usage: ucdgen regex --version <v> --manifest <manifest.zon> <{d} UCD files> <out-dir>\n", .{files.len});
        return 2;
    }
    const cwd = std.Io.Dir.cwd();
    var inputs: Inputs = undefined;
    for (files, 0..) |rel, i| {
        const path = args[4 + i];
        if (!lib.pathEndsWith(path, rel)) {
            std.debug.print("ucdgen regex: argument {d} should be {s}, got {s}\n", .{ i + 1, rel, path });
            return 2;
        }
        inputs[i] = try cwd.readFileAlloc(io, path, arena, .limited(64 << 20));
    }
    if (!try verify(arena, io, args[3], &files, &inputs)) return 1;
    const t = build(arena, &inputs) catch |err| {
        std.debug.print("ucdgen regex: {t}\n", .{err});
        return 1;
    };
    var out = try cwd.createDirPathOpen(io, args[args.len - 1], .{});
    defer out.close(io);
    var src: std.Io.Writer.Allocating = .init(arena);
    try writeZig(arena, &src.writer, args[1], &t);
    try out.writeFile(io, .{ .sub_path = "regex_tables.zig", .data = src.written() });
    return 0;
}

test "looseKey: UAX44-LM3" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("uppercaseletter", looseKey("Uppercase_Letter", &buf));
    try std.testing.expectEqualStrings("whitespace", looseKey("White Space", &buf));
    try std.testing.expectEqualStrings("lu", looseKey("L-u", &buf));
}

test "build: tiny inputs" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var gc_pva: std.ArrayList(u8) = .empty;
    try gc_pva.appendSlice(arena, "sc ; Zzzz ; Unknown\nsc ; Latn ; Latin\nsc ; Grek ; Greek\n");
    for ([_][]const u8{ "Cc", "Cf", "Cn", "Co", "Cs", "Ll", "Lm", "Lo", "Lt", "Lu", "Mc", "Me", "Mn", "Nd", "Nl", "No", "Pc", "Pd", "Pe", "Pf", "Pi", "Po", "Ps", "Sc", "Sk", "Sm", "So", "Zl", "Zp", "Zs", "C", "L", "LC", "M", "N", "P", "S", "Z" }) |v|
        try gc_pva.print(arena, "gc ; {s} ; {s}\n", .{ v, v });
    const in: Inputs = .{
        "0041..005A ; Lu\n0061..007A ; Ll\n",
        "0041..007A ; Latn\n0391..03A9 ; Grek\n",
        "0342 ; Grek Latn\n",
        "0020 ; White_Space\n200D ; Join_Control\n",
        "0041..005A ; Uppercase\n0041..005A ; Alphabetic\n0300 ; InCB; Extend\n",
        "1F600 ; Emoji\n",
        gc_pva.items,
        "0041; C; 0061; # A\n212A; C; 006B; # KELVIN\n004B; C; 006B; # K\n1E9E; F; 0073 0073; # sharp s\n",
    };
    var t = try build(arena, &in);
    try std.testing.expect(t.gc.values.items[t.gc.find("L").?].member.isSet('a'));
    try std.testing.expect(t.gc.values.items[t.gc.find("Cn").?].member.isSet(0x10FFFF));
    try std.testing.expect(!t.gc.values.items[t.gc.find("Cn").?].member.isSet('A'));
    try std.testing.expect(t.scx.values.items[t.scx.find("Latn").?].member.isSet(0x342));
    try std.testing.expect(!t.sc.values.items[t.sc.find("Latn").?].member.isSet(0x342));
    try std.testing.expect(t.binary.find("InCB") == null);
    try std.testing.expect(t.perl_word.isSet(0x200D) and t.perl_word.isSet('A') and !t.perl_word.isSet(' '));
    // Orbits: {a, A}, {k, K, KELVIN}.
    try std.testing.expectEqual(@as(usize, 2), t.orbits.items.len);
    try std.testing.expectEqualSlices(u21, &.{ 'K', 'k', 0x212A }, t.orbits.items[1]);
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeZig(arena, &out.writer, "test", &t);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ".{ .key = \"greek\", .index = 2 }") != null);
}
