//! The Universal Shaping Engine class of every code point, derived the way
//! HarfBuzz's `gen-use-table.py` does: Indic_Syllabic_Category and
//! Indic_Positional_Category with Microsoft's override files on top,
//! General_Category, Joining_Type and Default_Ignorable_Code_Point, mapped
//! through the USE spec's classification predicates, then given a position
//! suffix (Abv, Blw, Pst, Pre) from the positional category.
//!
//! Only code points listed in one of the Indic files, ArabicShaping.txt or
//! the Default_Ignorable list get a class; the rest, and every code point
//! of the scripts USE does not handle (Arabic, Lao, Samaritan, Syriac,
//! Thai), stay `O`.

const std = @import("std");
const parse = @import("parse.zig");
const e = @import("ucd_enums");
const U = e.UseCategory;

/// Microsoft's override files (`packages/text/ucd/ms-use/`), in argument
/// order.
pub const files = [_][]const u8{
    "IndicSyllabicCategory-Additional.txt",
    "IndicPositionalCategory-Additional.txt",
};

/// Contents of `files`, in order.
pub const Inputs = [files.len][]const u8;

/// Indic_Syllabic_Category, extended with Microsoft's values the UCD does
/// not have (symbol modifiers and hieroglyphs).
const Isc = union(enum) {
    ucd: e.IndicSyllabic,
    Symbol_Modifier,
    Hieroglyph,
    Hieroglyph_Joiner,
    Hieroglyph_Mark_Begin,
    Hieroglyph_Mark_End,
    Hieroglyph_Mirror,
    Hieroglyph_Modifier,
    Hieroglyph_Segment_Begin,
    Hieroglyph_Segment_End,

    fn is(x: Isc, v: e.IndicSyllabic) bool {
        return x == .ucd and x.ucd == v;
    }

    fn in(x: Isc, vs: []const e.IndicSyllabic) bool {
        if (x != .ucd) return false;
        return std.mem.indexOfScalar(e.IndicSyllabic, vs, x.ucd) != null;
    }

    fn parseValue(s: []const u8) ?Isc {
        // https://github.com/MicrosoftDocs/typography-issues/issues/336
        if (std.mem.eql(u8, s, "Consonant_Final_Modifier")) return .{ .ucd = .Syllable_Modifier };
        inline for (@typeInfo(Isc).@"union".fields[1..]) |f| {
            if (std.mem.eql(u8, s, f.name)) return @unionInit(Isc, f.name, {});
        }
        return .{ .ucd = e.IndicSyllabic.fromAlias(s) orelse return null };
    }
};

/// The classes before the position suffix.
const Class = enum { B, N, GB, CGJ, F, FM, M, CM, SUB, CS, H, HVM, HN, IS, G, HM, HR, J, SB, SE, ZWNJ, O, RK, R, Sk, SM, V, VM, WJ };

/// What a code point's class is computed from.
const Data = struct {
    cp: u21,
    isc: Isc,
    ipc: e.IndicPositional,
    di: bool,
    gc: e.GeneralCategory,
    jt: ?e.JoiningType,
};

fn isBase(d: Data) bool {
    return d.isc.in(&.{ .Number, .Consonant, .Consonant_Head_Letter, .Tone_Letter, .Vowel_Independent }) or
        // https://github.com/MicrosoftDocs/typography-issues/issues/484
        (d.jt != null and switch (d.jt.?) {
            .C, .D, .L, .R => true,
            else => false,
        } and !d.isc.is(.Joiner)) or
        (d.gc == .Lo and d.isc.in(&.{ .Avagraha, .Bindu, .Consonant_Final, .Consonant_Medial, .Consonant_Subjoined, .Vowel, .Vowel_Dependent }));
}

fn isBaseOther(d: Data) bool {
    if (d.isc.is(.Consonant_Placeholder)) return true;
    return switch (d.cp) {
        0x2015, 0x2022, 0x25FB, 0x25FC, 0x25FD, 0x25FE => true,
        else => false,
    };
}

fn isCgj(d: Data) bool {
    // Also variation selectors and ZWJ.
    return d.isc.is(.Joiner) or (d.di and (d.gc == .Mc or d.gc == .Me or d.gc == .Mn));
}

fn isSymMod(d: Data) bool {
    return d.isc == .Symbol_Modifier;
}

fn isSakot(d: Data) bool {
    return d.cp == 0x1A60;
}

fn isWordJoiner(d: Data) bool {
    const filler = switch (d.cp) {
        0x115F, 0x1160, 0x3164, 0xFFA0, 0x1BCA0...0x1BCA3 => true,
        else => false,
    };
    return (d.di and !filler and d.isc.is(.Other) and !isCgj(d)) or d.gc == .Cn;
}

fn matches(c: Class, d: Data) bool {
    return switch (c) {
        .B => isBase(d),
        .N => d.isc.is(.Brahmi_Joining_Number),
        .GB => isBaseOther(d),
        .CGJ => isCgj(d),
        .F => (d.isc.is(.Consonant_Final) and d.gc != .Lo) or d.isc.is(.Consonant_Succeeding_Repha),
        .FM => d.isc.is(.Syllable_Modifier),
        // Consonant_Initial_Postfixed is new in Unicode 11, not in the spec.
        .M => (d.isc.is(.Consonant_Medial) and d.gc != .Lo) or d.isc.is(.Consonant_Initial_Postfixed),
        .CM => d.isc.in(&.{ .Nukta, .Gemination_Mark, .Consonant_Killer }),
        .SUB => d.isc.is(.Consonant_Subjoined) and d.gc != .Lo,
        .CS => d.isc.is(.Consonant_With_Stacker),
        .H => d.isc.is(.Virama) and d.cp != 0x0DCA,
        .HVM => d.cp == 0x0DCA,
        .HN => d.isc.is(.Number_Joiner),
        .IS => d.isc.is(.Invisible_Stacker) and !isSakot(d),
        .G => d.isc == .Hieroglyph,
        .HM => d.isc == .Hieroglyph_Modifier,
        .HR => d.isc == .Hieroglyph_Mirror,
        .J => d.isc == .Hieroglyph_Joiner,
        .SB => d.isc == .Hieroglyph_Mark_Begin or d.isc == .Hieroglyph_Segment_Begin,
        .SE => d.isc == .Hieroglyph_Mark_End or d.isc == .Hieroglyph_Segment_End,
        .ZWNJ => d.isc.is(.Non_Joiner),
        // Also BASE_IND and SYM.
        .O => (d.gc == .Po or d.isc.in(&.{ .Consonant_Dead, .Joiner, .Modifying_Letter, .Other })) and
            !isBase(d) and !isBaseOther(d) and !isCgj(d) and !isSymMod(d) and !isWordJoiner(d),
        .RK => d.isc.is(.Reordering_Killer),
        .R => d.isc.in(&.{ .Consonant_Preceding_Repha, .Consonant_Prefixed }),
        .Sk => isSakot(d),
        .SM => isSymMod(d),
        .V => d.isc.is(.Pure_Killer) or (d.gc != .Lo and d.isc.in(&.{ .Vowel, .Vowel_Dependent })),
        .VM => d.isc.in(&.{ .Tone_Mark, .Cantillation_Mark, .Register_Shifter, .Visarga }) or (d.gc != .Lo and d.isc.is(.Bindu)),
        .WJ => isWordJoiner(d),
    };
}

const P = e.IndicPositional;
const Pos = enum { Abv, Blw, Pst, Pre };

/// The positional categories that pick each suffix, per class (null: no
/// suffix).
fn positions(c: Class) ?[4][]const P {
    return switch (c) {
        .F => .{ &.{.Top}, &.{.Bottom}, &.{.Right}, &.{} },
        .M => .{ &.{.Top}, &.{ .Bottom, .Bottom_And_Left, .Bottom_And_Right }, &.{.Right}, &.{ .Left, .Top_And_Bottom_And_Left } },
        .CM => .{ &.{.Top}, &.{ .Bottom, .Overstruck }, &.{}, &.{} },
        .V => .{ &.{ .Top, .Top_And_Bottom, .Top_And_Bottom_And_Right, .Top_And_Right }, &.{ .Bottom, .Overstruck, .Bottom_And_Right }, &.{.Right}, &.{ .Left, .Top_And_Left, .Top_And_Left_And_Right, .Left_And_Right } },
        .VM => .{ &.{.Top}, &.{ .Bottom, .Overstruck }, &.{.Right}, &.{.Left} },
        .SM => .{ &.{.Top}, &.{.Bottom}, &.{}, &.{} },
        .FM => .{ &.{.Top}, &.{.Bottom}, &.{.NA}, &.{} },
        else => null,
    };
}

fn suffixed(c: Class, p: Pos) ?U {
    const name = switch (c) {
        .F => "F",
        .M => "M",
        .CM => "CM",
        .V => "V",
        .VM => "VM",
        .SM => "SM",
        .FM => "FM",
        else => return null,
    };
    var buf: [8]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}{t}", .{ name, p }) catch return null;
    return std.meta.stringToEnum(U, full);
}

/// Why a code point could not be classified.
pub const Diag = struct { cp: u21 = 0, reason: []const u8 = "" };

/// Classification errors.
pub const Error = error{ UnknownPropertyValue, UseCategory, OutOfMemory } || parse.Error;

/// The class of one code point.
fn classify(d: Data, diag: *Diag) Error!U {
    var found: ?Class = null;
    inline for (@typeInfo(Class).@"enum".fields) |f| {
        const c: Class = @enumFromInt(f.value);
        if (matches(c, d)) {
            if (found != null) {
                diag.* = .{ .cp = d.cp, .reason = "more than one USE class matches" };
                return error.UseCategory;
            }
            found = c;
        }
    }
    const c = found orelse {
        diag.* = .{ .cp = d.cp, .reason = "no USE class matches" };
        return error.UseCategory;
    };
    const table = positions(c) orelse return std.meta.stringToEnum(U, @tagName(c)).?;
    var pos: ?Pos = null;
    for (table, 0..) |list, i| if (std.mem.indexOfScalar(P, list, d.ipc) != null) {
        pos = @enumFromInt(i);
    };
    return suffixed(c, pos orelse {
        diag.* = .{ .cp = d.cp, .reason = "no USE position for the positional category" };
        return error.UseCategory;
    }).?;
}

fn disabled(s: e.Script) bool {
    return switch (s) {
        .Arab, .Laoo, .Samr, .Syrc, .Thai => true,
        else => false,
    };
}

/// Sets `aux[cp].use` for every code point. `isc_file`, `ipc_file`,
/// `arabic_shaping` and `dcp` are the UCD files; `props` and `aux` must
/// already hold their values (General_Category, Script, the Indic
/// categories and Default_Ignorable_Code_Point).
pub fn apply(a: std.mem.Allocator, ucd: struct { isc: []const u8, ipc: []const u8, arabic_shaping: []const u8, dcp: []const u8 }, ms: *const Inputs, props: []const e.Props, aux: []e.Aux, diag: *Diag) Error!void {
    const n = props.len;
    const listed = try a.alloc(bool, n);
    @memset(listed, false);
    const isc = try a.alloc(Isc, n);
    const ipc = try a.alloc(P, n);
    const jt = try a.alloc(?e.JoiningType, n);
    @memset(jt, null);
    for (aux, isc, ipc) |x, *s, *p| {
        s.* = .{ .ucd = x.isc };
        p.* = x.ipc;
    }
    inline for (.{ ucd.isc, ucd.ipc }) |text| try markListed(text, listed, null);
    try markListed(ucd.dcp, listed, "Default_Ignorable_Code_Point");
    {
        var it = parse.Iterator.init(ucd.arabic_shaping);
        while (try it.next()) |l| {
            if (l.missing) continue;
            const v = e.JoiningType.fromAlias(l.field(1)) orelse return unknown(l.lo, diag);
            for (l.lo..@as(usize, l.hi) + 1) |cp| {
                listed[cp] = true;
                jt[cp] = v;
            }
        }
    }
    // Microsoft's overrides, after the UCD values.
    {
        var it = parse.Iterator.init(try spaced(a, ms[0]));
        while (try it.next()) |l| {
            if (l.missing) continue;
            const v = Isc.parseValue(l.field(0)) orelse return unknown(l.lo, diag);
            for (l.lo..@as(usize, l.hi) + 1) |cp| {
                listed[cp] = true;
                isc[cp] = v;
            }
        }
    }
    {
        var it = parse.Iterator.init(try spaced(a, ms[1]));
        while (try it.next()) |l| {
            if (l.missing) continue;
            const v = P.fromAlias(l.field(0)) orelse return unknown(l.lo, diag);
            for (l.lo..@as(usize, l.hi) + 1) |cp| {
                listed[cp] = true;
                ipc[cp] = v;
            }
        }
    }

    for (0..n) |i| {
        if (!listed[i] or disabled(props[i].script)) continue;
        const cp: u21 = @intCast(i);
        var d: Data = .{ .cp = cp, .isc = isc[i], .ipc = ipc[i], .di = aux[i].default_ignorable, .gc = props[i].gc, .jt = jt[i] };
        // HarfBuzz's fixes for values the files lack or get wrong.
        switch (cp) {
            0x1CE2...0x1CE8 => d.isc = .{ .ucd = .Cantillation_Mark },
            0x0F18...0x0F19, 0x0F3E...0x0F3F => d.isc = .{ .ucd = .Vowel_Dependent },
            // Should only follow some of the nasalization marks.
            0x1CED => d.isc = .{ .ucd = .Tone_Mark },
            0x11302, 0x11303, 0x114C1 => d.ipc = .Top,
            else => {},
        }
        aux[i].use = try classify(d, diag);
    }
}

/// `text` with no-break spaces (U+00A0, which one line of Microsoft's
/// files uses as padding) turned into two ASCII spaces.
fn spaced(a: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    return std.mem.replaceOwned(u8, a, text, "\u{A0}", "  ");
}

fn markListed(text: []const u8, listed: []bool, prop: ?[]const u8) parse.Error!void {
    var it = parse.Iterator.init(text);
    while (try it.next()) |l| {
        if (l.missing) continue;
        if (prop) |p| if (!std.mem.eql(u8, l.field(0), p)) continue;
        @memset(listed[l.lo .. @as(usize, l.hi) + 1], true);
    }
}

fn unknown(cp: u21, diag: *Diag) Error {
    diag.* = .{ .cp = cp, .reason = "unknown property value" };
    return error.UnknownPropertyValue;
}

test "classes of sample code points" {
    const Case = struct { Data, U };
    const cases = [_]Case{
        .{ .{ .cp = 0xA98F, .isc = .{ .ucd = .Consonant }, .ipc = .NA, .di = false, .gc = .Lo, .jt = null }, .B },
        .{ .{ .cp = 0xA9BC, .isc = .{ .ucd = .Vowel_Dependent }, .ipc = .Top, .di = false, .gc = .Mn, .jt = null }, .VAbv },
        .{ .{ .cp = 0xA9BA, .isc = .{ .ucd = .Vowel_Dependent }, .ipc = .Left, .di = false, .gc = .Mc, .jt = null }, .VPre },
        .{ .{ .cp = 0x17D2, .isc = .{ .ucd = .Invisible_Stacker }, .ipc = .NA, .di = false, .gc = .Mn, .jt = null }, .IS },
        .{ .{ .cp = 0x1A60, .isc = .{ .ucd = .Invisible_Stacker }, .ipc = .NA, .di = false, .gc = .Mn, .jt = null }, .Sk },
        .{ .{ .cp = 0x0DCA, .isc = .{ .ucd = .Virama }, .ipc = .Top, .di = false, .gc = .Mn, .jt = null }, .HVM },
        .{ .{ .cp = 0x200C, .isc = .{ .ucd = .Non_Joiner }, .ipc = .NA, .di = true, .gc = .Cf, .jt = null }, .ZWNJ },
        .{ .{ .cp = 0x200D, .isc = .{ .ucd = .Joiner }, .ipc = .NA, .di = true, .gc = .Cf, .jt = null }, .CGJ },
        .{ .{ .cp = 0x1C36, .isc = .{ .ucd = .Syllable_Modifier }, .ipc = .Top, .di = false, .gc = .Mn, .jt = null }, .FMAbv },
        .{ .{ .cp = 0x13430, .isc = .Hieroglyph_Joiner, .ipc = .NA, .di = false, .gc = .Cf, .jt = null }, .J },
    };
    for (cases) |c| {
        var diag: Diag = .{};
        try std.testing.expectEqual(c[1], try classify(c[0], &diag));
    }
}

test "overlapping classes are an error" {
    var diag: Diag = .{};
    // Lo with Bindu is a base; Cn makes it a word joiner too.
    const d: Data = .{ .cp = 0x10FFFD, .isc = .{ .ucd = .Consonant }, .ipc = .NA, .di = false, .gc = .Cn, .jt = null };
    try std.testing.expectError(error.UseCategory, classify(d, &diag));
    try std.testing.expectEqual(@as(u21, 0x10FFFD), diag.cp);
}

test "no-break space padding" {
    const out = try spaced(std.testing.allocator, "AA35 \u{A0}; Top\n");
    defer std.testing.allocator.free(out);
    var it = parse.Iterator.init(out);
    const l = (try it.next()).?;
    try std.testing.expectEqual(@as(u21, 0xAA35), l.lo);
    try std.testing.expectEqualStrings("Top", l.field(0));
}

test "Microsoft value names" {
    try std.testing.expectEqual(Isc{ .ucd = .Syllable_Modifier }, Isc.parseValue("Consonant_Final_Modifier").?);
    try std.testing.expectEqual(Isc.Hieroglyph_Segment_End, Isc.parseValue("Hieroglyph_Segment_End").?);
    try std.testing.expectEqual(Isc{ .ucd = .Nukta }, Isc.parseValue("Nukta").?);
    try std.testing.expectEqual(@as(?Isc, null), Isc.parseValue("Nope"));
}
