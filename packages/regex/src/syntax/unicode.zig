//! Unicode property lookup for `\p{..}` over the generated tables, with
//! UAX44-LM3 loose matching: case, spaces, `_` and `-` are ignored, and a
//! leading "is" is optional (`\p{isGreek}`).
//!
//! Resolution follows Rust `regex`: a one-part name is tried as a
//! General_Category value, then a Script, then a binary property; a two-part
//! name selects `gc`/`General_Category`, `sc`/`Script` or
//! `scx`/`Script_Extensions` and looks the value up there. A binary property
//! also accepts `=yes`/`=no` (and `y`, `t`, `true`, `n`, `f`, `false`).

const std = @import("std");
const tables = @import("regex_tables");

/// A resolved property: its ranges and whether the value was `=no`.
pub const Resolved = struct { ranges: []const [2]u21, negated: bool = false };

fn loose(s: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (c == ' ' or c == '_' or c == '-' or c == '\t') continue;
        if (n == buf.len) return buf[0..0];
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

fn find(names: []const tables.Name, key: []const u8) ?u16 {
    var lo: usize = 0;
    var hi: usize = names.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, names[mid].key, key)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return names[mid].index,
        }
    }
    return null;
}

fn findLoose(names: []const tables.Name, key: []const u8) ?u16 {
    if (find(names, key)) |i| return i;
    if (key.len > 2 and std.mem.startsWith(u8, key, "is")) return find(names, key[2..]);
    return null;
}

/// The ranges of property `name` (with `value` for two-part forms), or null
/// when unknown.
pub fn propertyRanges(name: []const u8, value: ?[]const u8) ?Resolved {
    var nb: [96]u8 = undefined;
    const key = loose(name, &nb);
    if (key.len == 0) return null;
    if (value) |v| {
        var vb: [96]u8 = undefined;
        const vkey = loose(v, &vb);
        if (vkey.len == 0) return null;
        if (eqlAny(key, &.{ "gc", "generalcategory" })) {
            return .{ .ranges = tables.general_category[findLoose(&tables.general_category_names, vkey) orelse return null] };
        }
        if (eqlAny(key, &.{ "sc", "script" })) {
            return .{ .ranges = tables.script[findLoose(&tables.script_names, vkey) orelse return null] };
        }
        if (eqlAny(key, &.{ "scx", "scriptextensions" })) {
            return .{ .ranges = tables.script_extensions[findLoose(&tables.script_extensions_names, vkey) orelse return null] };
        }
        const b = findLoose(&tables.binary_names, key) orelse return null;
        if (eqlAny(vkey, &.{ "yes", "y", "t", "true" })) return .{ .ranges = tables.binary[b] };
        if (eqlAny(vkey, &.{ "no", "n", "f", "false" })) return .{ .ranges = tables.binary[b], .negated = true };
        return null;
    }
    if (findLoose(&tables.general_category_names, key)) |i| return .{ .ranges = tables.general_category[i] };
    if (findLoose(&tables.script_names, key)) |i| return .{ .ranges = tables.script[i] };
    if (findLoose(&tables.binary_names, key)) |i| return .{ .ranges = tables.binary[i] };
    return null;
}

fn eqlAny(s: []const u8, opts: []const []const u8) bool {
    for (opts) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

/// `\d` in Unicode mode: General_Category=Nd.
pub fn perlDigit() []const [2]u21 {
    return propertyRanges("Nd", null).?.ranges;
}

/// `\s` in Unicode mode: White_Space.
pub fn perlSpace() []const [2]u21 {
    return propertyRanges("White_Space", null).?.ranges;
}

/// `\w` in Unicode mode: Alphabetic, M, Nd, Pc and Join_Control.
pub fn perlWord() []const [2]u21 {
    return tables.perl_word;
}

fn contains(ranges: []const [2]u21, cp: u21) bool {
    for (ranges) |r| if (cp >= r[0] and cp <= r[1]) return true;
    return false;
}

test "unicode: every property value resolves; loose matching aliases" {
    const cases = [_]struct { []const u8, ?[]const u8, u21 }{
        .{ "greek", null, 0x3B1 },
        .{ "Greek", null, 0x3B1 },
        .{ "isGreek", null, 0x3B1 },
        .{ "Script", "Grek", 0x3B1 },
        .{ "sc", "greek", 0x3B1 },
        .{ "gc", "uppercase_letter", 'A' },
        .{ "General Category", "Lu", 'A' },
        .{ "L", null, 'x' },
        .{ "LC", null, 'x' },
        .{ "Letter", null, 0x65E5 },
        .{ "Nd", null, '7' },
        .{ "digit", null, '7' },
        .{ "Alphabetic", null, 'q' },
        .{ "alpha", null, 'q' },
        .{ "White_Space", null, ' ' },
        .{ "wspace", null, 0x3000 },
        .{ "Emoji", null, 0x1F600 },
        .{ "ExtPict", null, 0x1F600 },
        .{ "Any", null, 0x10FFFF },
        .{ "ASCII", null, 0x7F },
        .{ "Assigned", null, 'a' },
        .{ "scx", "Arab", 0x60C },
        .{ "Script_Extensions", "Syriac", 0x60C },
        .{ "XID_Start", null, 'a' },
        .{ "Alphabetic", "yes", 'a' },
    };
    for (cases) |c| {
        const r = propertyRanges(c[0], c[1]) orelse {
            std.debug.print("unresolved: {s} {?s}\n", .{ c[0], c[1] });
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(contains(r.ranges, c[2]));
    }
    try std.testing.expect(propertyRanges("Alphabetic", "no").?.negated);
    try std.testing.expect(propertyRanges("NotAProperty", null) == null);
    try std.testing.expect(propertyRanges("sc", "Nope") == null);
    try std.testing.expect(!contains(propertyRanges("Assigned", null).?.ranges, 0x378));
    // Every listed name resolves.
    for (tables.general_category_names) |n| try std.testing.expect(propertyRanges("gc", n.key) != null);
    for (tables.script_names) |n| try std.testing.expect(propertyRanges("sc", n.key) != null);
    for (tables.binary_names) |n| try std.testing.expect(propertyRanges(n.key, null) != null);
    try std.testing.expect(contains(perlWord(), 0x200D));
    try std.testing.expect(contains(perlWord(), '_'));
    try std.testing.expect(contains(perlDigit(), 0x0663));
    try std.testing.expect(contains(perlSpace(), 0x85));
}
