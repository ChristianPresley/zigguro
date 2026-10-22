//! Keysym names, values and Unicode, over the tables generated from the
//! vendored xorgproto headers (`keysym_data.zig`), plus the simple case
//! mapping that the Lock modifier applies.

const std = @import("std");
const data = @import("keysym_data.zig");

/// The keysym for "no symbol".
pub const no_symbol: u32 = 0;

/// The preferred name of `ks`, or null when it has none (Unicode keysyms
/// without a name are spelled `U+XXXX` by callers).
pub fn keysymName(ks: u32) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = data.by_value.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const v = data.by_value[mid].value;
        if (v == ks) return data.by_value[mid].name;
        if (v < ks) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// The keysym named `name`: a table name, `U+XXXX` / `UXXXX` (a Unicode
/// keysym), or `0x` followed by a hex value. Null when unknown.
pub fn keysymFromName(name: []const u8) ?u32 {
    if (lookupName(name)) |v| return v;
    if (name.len >= 2 and name[0] == 'U' and std.ascii.isHex(name[name.len - 1])) {
        const hex = if (name[1] == '+') name[2..] else name[1..];
        const cp = std.fmt.parseInt(u21, hex, 16) catch return null;
        if (cp > 0x10ffff) return null;
        return unicodeKeysym(cp);
    }
    if (std.mem.startsWith(u8, name, "0x")) return std.fmt.parseInt(u32, name[2..], 16) catch null;
    return null;
}

fn lookupName(name: []const u8) ?u32 {
    var lo: usize = 0;
    var hi: usize = data.by_name.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, data.by_name[mid].name, name)) {
            .eq => return data.by_name[mid].value,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

/// The keysym for code point `cp`: Latin-1 keysyms equal their code
/// point; everything else is 0x01000000 + cp.
pub fn unicodeKeysym(cp: u21) u32 {
    if ((cp >= 0x20 and cp <= 0x7e) or (cp >= 0xa0 and cp <= 0xff)) return cp;
    return 0x01000000 + @as(u32, cp);
}

/// The character `ks` types, or null for function keys and the like.
pub fn keysymToCodepoint(ks: u32) ?u21 {
    if ((ks >= 0x20 and ks <= 0x7e) or (ks >= 0xa0 and ks <= 0xff)) return @intCast(ks);
    if (ks >= 0x01000100 and ks <= 0x0110ffff) return @intCast(ks - 0x01000000);
    // Keypad and control keysyms that produce characters.
    switch (ks) {
        0xff80 => return ' ', // KP_Space
        0xff08...0xff0b, 0xff0d, 0xff1b, 0xff89, 0xff8d => return @intCast(ks & 0x7f), // BackSpace..Clear, Return, Escape, KP_Tab, KP_Enter
        0xffff => return 0x7f, // Delete
        0xffaa...0xffb9, 0xffbd => return @intCast(ks & 0x7f), // KP_Multiply..KP_9, KP_Equal
        else => {},
    }
    var lo: usize = 0;
    var hi: usize = data.to_unicode.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const k = data.to_unicode[mid].keysym;
        if (k == ks) return data.to_unicode[mid].cp;
        if (k < ks) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// Uppercases `ks` for the Lock modifier: Latin-1, Greek and Cyrillic, as
/// legacy keysyms and as Unicode keysyms. Other keysyms are unchanged.
pub fn toUpper(ks: u32) u32 {
    switch (ks) {
        'a'...'z' => return ks - 0x20,
        0xe0...0xf6, 0xf8...0xfe => return ks - 0x20, // Latin-1
        0xff => return 0x13be, // ydiaeresis -> Ydiaeresis
        0x6a1...0x6af => return ks + 0x10, // Cyrillic (Serbian, Ukrainian...)
        0x6c0...0x6df => return ks + 0x20, // Cyrillic
        0x7b1...0x7bb => return if (ks == 0x7b6 or ks == 0x7ba) ks else ks - 0x10, // Greek accented
        0x7e1...0x7f9 => return if (ks == 0x7f3) ks else ks - 0x20, // Greek, final sigma stays
        0x01000000...0x0110ffff => {
            const cp: u32 = ks - 0x01000000;
            const up: u32 = switch (cp) {
                0x3b1...0x3c1, 0x3c3...0x3c9 => cp - 0x20, // Greek
                0x430...0x44f => cp - 0x20, // Cyrillic
                0x450...0x45f => cp - 0x50,
                0x100...0x137, 0x14a...0x177 => cp & ~@as(u32, 1), // Latin Extended-A pairs
                0x139...0x148, 0x179...0x17e => if (cp & 1 == 0) cp - 1 else cp,
                else => cp,
            };
            return unicodeKeysym(@intCast(up));
        },
        else => return ks,
    }
}

/// Lowercases `ks`: the inverse of `toUpper`.
pub fn toLower(ks: u32) u32 {
    switch (ks) {
        'A'...'Z' => return ks + 0x20,
        0xc0...0xd6, 0xd8...0xde => return ks + 0x20, // Latin-1
        0x13be => return 0xff, // Ydiaeresis
        0x6b1...0x6bf => return ks - 0x10, // Cyrillic (Serbian, Ukrainian...)
        0x6e0...0x6ff => return ks - 0x20, // Cyrillic
        0x7a1...0x7ab => return if (ks == 0x7a6 or ks == 0x7aa) ks else ks + 0x10, // Greek accented
        0x7c1...0x7d9 => return ks + 0x20, // Greek
        0x01000000...0x0110ffff => {
            const cp: u32 = ks - 0x01000000;
            const low: u32 = switch (cp) {
                0x391...0x3a1, 0x3a3...0x3a9 => cp + 0x20,
                0x410...0x42f => cp + 0x20,
                0x400...0x40f => cp + 0x50,
                0x100...0x137, 0x14a...0x177 => cp | 1,
                0x139...0x148, 0x179...0x17e => if (cp & 1 == 1) cp + 1 else cp,
                0x178 => 0xff,
                else => cp,
            };
            return unicodeKeysym(@intCast(low));
        },
        else => return ks,
    }
}

/// Whether `ks` is a lowercase letter (it has a distinct uppercase).
pub fn isLower(ks: u32) bool {
    return toUpper(ks) != ks;
}

/// Whether `ks` is an uppercase letter (it has a distinct lowercase).
pub fn isUpper(ks: u32) bool {
    return toLower(ks) != ks;
}

/// Whether `ks` is a keypad keysym (`KP_Space` to `KP_Equal`).
pub fn isKeypad(ks: u32) bool {
    return ks >= 0xff80 and ks <= 0xffbd;
}

const testing = std.testing;

test "keysymToCodepoint covers the 0x01000000 rule and Latin-1" {
    try testing.expectEqual('a', keysymToCodepoint(0x61).?);
    try testing.expectEqual(0xe9, keysymToCodepoint(0xe9).?);
    try testing.expectEqual(0x20ac, keysymToCodepoint(0x10020ac).?);
    try testing.expectEqual(0x20ac, keysymToCodepoint(keysymFromName("EuroSign").?).?);
    try testing.expectEqual(0x444, keysymToCodepoint(keysymFromName("Cyrillic_ef").?).?);
    try testing.expectEqual('7', keysymToCodepoint(keysymFromName("KP_7").?).?);
    try testing.expectEqual('\r', keysymToCodepoint(keysymFromName("Return").?).?);
    try testing.expectEqual(null, keysymToCodepoint(keysymFromName("F1").?));
    try testing.expectEqual(null, keysymToCodepoint(keysymFromName("Shift_L").?));
}

test "names: lookups, Unicode spellings and XF86 keysyms" {
    try testing.expectEqual(0x21, keysymFromName("exclam").?);
    try testing.expectEqualStrings("exclam", keysymName(0x21).?);
    try testing.expectEqual(0x1008ff12, keysymFromName("XF86AudioMute").?);
    try testing.expectEqual(0x100017f, keysymFromName("U017F").?);
    try testing.expectEqual(0xe9, keysymFromName("U+00E9").?);
    try testing.expectEqual(0x1234, keysymFromName("0x1234").?);
    try testing.expectEqual(null, keysymFromName("NoSuchKeysym"));
}

test "name<->value roundtrip for 1000 random entries" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const r = prng.random();
    for (0..1000) |_| {
        const e = data.by_value[r.uintLessThan(usize, data.by_value.len)];
        try testing.expectEqual(e.value, keysymFromName(e.name).?);
        try testing.expectEqualStrings(e.name, keysymName(e.value).?);
    }
    // Every name resolves to its value.
    for (data.by_name) |e| try testing.expectEqual(e.value, keysymFromName(e.name).?);
}

test "toUpper for Lock" {
    try testing.expectEqual('A', toUpper('a'));
    try testing.expectEqual(0xc9, toUpper(0xe9));
    try testing.expectEqual(0xf7, toUpper(0xf7));
    try testing.expectEqual(keysymFromName("Cyrillic_EF").?, toUpper(keysymFromName("Cyrillic_ef").?));
    try testing.expectEqual(keysymFromName("Greek_OMEGA").?, toUpper(keysymFromName("Greek_omega").?));
    try testing.expectEqual(keysymFromName("Ukrainian_I").?, toUpper(keysymFromName("Ukrainian_i").?));
    try testing.expectEqual(0x13be, toUpper(0xff));
    try testing.expectEqual(0x100017e - 1, toUpper(0x100017e));
    try testing.expectEqual(0x1000100, toUpper(0x1000101));
    try testing.expectEqual('1', toUpper('1'));
}

test "toLower inverts toUpper over the case ranges" {
    var ks: u32 = 0;
    while (ks < 0x800) : (ks += 1) {
        const up = toUpper(ks);
        if (up != ks) try testing.expectEqual(ks, toLower(up));
    }
    var cp: u32 = 0x100;
    while (cp < 0x460) : (cp += 1) {
        const k = 0x01000000 + cp;
        const up = toUpper(k);
        if (up != k) try testing.expectEqual(k, toLower(up));
    }
    try testing.expect(isLower('q') and isUpper('Q') and !isLower('1') and !isUpper('1'));
    try testing.expect(isKeypad(keysymFromName("KP_Home").?) and !isKeypad('7'));
}
