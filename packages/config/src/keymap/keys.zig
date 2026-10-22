//! Physical keys (W3C `code` names keyed by USB HID usage, page 0x07),
//! modifiers, the key event the resolver consumes, and keyboard-layout
//! tables.
//!
//! E01 (`zg_platform`) owns the canonical `Key`/`Mods`/`KeyEvent` types and
//! the per-OS layout queries. Until E01 merges, this module carries the
//! subset the resolver needs, using the same identity (HID usage) so the
//! E04/E01 adapter converts without a table: `Key` values are ordered by HID
//! usage in E01.F01.S01.T01 and `KeyInput.usage` is that usage.

const std = @import("std");

/// A USB HID keyboard usage (page 0x07).
pub const Usage = u16;

/// W3C `code` names by HID usage.
pub const codes = [_]struct { Usage, []const u8 }{
    .{ 0x04, "KeyA" },          .{ 0x05, "KeyB" },           .{ 0x06, "KeyC" },           .{ 0x07, "KeyD" },
    .{ 0x08, "KeyE" },          .{ 0x09, "KeyF" },           .{ 0x0A, "KeyG" },           .{ 0x0B, "KeyH" },
    .{ 0x0C, "KeyI" },          .{ 0x0D, "KeyJ" },           .{ 0x0E, "KeyK" },           .{ 0x0F, "KeyL" },
    .{ 0x10, "KeyM" },          .{ 0x11, "KeyN" },           .{ 0x12, "KeyO" },           .{ 0x13, "KeyP" },
    .{ 0x14, "KeyQ" },          .{ 0x15, "KeyR" },           .{ 0x16, "KeyS" },           .{ 0x17, "KeyT" },
    .{ 0x18, "KeyU" },          .{ 0x19, "KeyV" },           .{ 0x1A, "KeyW" },           .{ 0x1B, "KeyX" },
    .{ 0x1C, "KeyY" },          .{ 0x1D, "KeyZ" },           .{ 0x1E, "Digit1" },         .{ 0x1F, "Digit2" },
    .{ 0x20, "Digit3" },        .{ 0x21, "Digit4" },         .{ 0x22, "Digit5" },         .{ 0x23, "Digit6" },
    .{ 0x24, "Digit7" },        .{ 0x25, "Digit8" },         .{ 0x26, "Digit9" },         .{ 0x27, "Digit0" },
    .{ 0x28, "Enter" },         .{ 0x29, "Escape" },         .{ 0x2A, "Backspace" },      .{ 0x2B, "Tab" },
    .{ 0x2C, "Space" },         .{ 0x2D, "Minus" },          .{ 0x2E, "Equal" },          .{ 0x2F, "BracketLeft" },
    .{ 0x30, "BracketRight" },  .{ 0x31, "Backslash" },      .{ 0x32, "IntlHash" },       .{ 0x33, "Semicolon" },
    .{ 0x34, "Quote" },         .{ 0x35, "Backquote" },      .{ 0x36, "Comma" },          .{ 0x37, "Period" },
    .{ 0x38, "Slash" },         .{ 0x39, "CapsLock" },       .{ 0x3A, "F1" },             .{ 0x3B, "F2" },
    .{ 0x3C, "F3" },            .{ 0x3D, "F4" },             .{ 0x3E, "F5" },             .{ 0x3F, "F6" },
    .{ 0x40, "F7" },            .{ 0x41, "F8" },             .{ 0x42, "F9" },             .{ 0x43, "F10" },
    .{ 0x44, "F11" },           .{ 0x45, "F12" },            .{ 0x46, "PrintScreen" },    .{ 0x47, "ScrollLock" },
    .{ 0x48, "Pause" },         .{ 0x49, "Insert" },         .{ 0x4A, "Home" },           .{ 0x4B, "PageUp" },
    .{ 0x4C, "Delete" },        .{ 0x4D, "End" },            .{ 0x4E, "PageDown" },       .{ 0x4F, "ArrowRight" },
    .{ 0x50, "ArrowLeft" },     .{ 0x51, "ArrowDown" },      .{ 0x52, "ArrowUp" },        .{ 0x53, "NumLock" },
    .{ 0x54, "NumpadDivide" },  .{ 0x55, "NumpadMultiply" }, .{ 0x56, "NumpadSubtract" }, .{ 0x57, "NumpadAdd" },
    .{ 0x58, "NumpadEnter" },   .{ 0x59, "Numpad1" },        .{ 0x5A, "Numpad2" },        .{ 0x5B, "Numpad3" },
    .{ 0x5C, "Numpad4" },       .{ 0x5D, "Numpad5" },        .{ 0x5E, "Numpad6" },        .{ 0x5F, "Numpad7" },
    .{ 0x60, "Numpad8" },       .{ 0x61, "Numpad9" },        .{ 0x62, "Numpad0" },        .{ 0x63, "NumpadDecimal" },
    .{ 0x64, "IntlBackslash" }, .{ 0x65, "ContextMenu" },    .{ 0x66, "Power" },          .{ 0x67, "NumpadEqual" },
    .{ 0x68, "F13" },           .{ 0x69, "F14" },            .{ 0x6A, "F15" },            .{ 0x6B, "F16" },
    .{ 0x6C, "F17" },           .{ 0x6D, "F18" },            .{ 0x6E, "F19" },            .{ 0x6F, "F20" },
    .{ 0x70, "F21" },           .{ 0x71, "F22" },            .{ 0x72, "F23" },            .{ 0x73, "F24" },
    .{ 0x87, "IntlRo" },        .{ 0x89, "IntlYen" },        .{ 0xE0, "ControlLeft" },    .{ 0xE1, "ShiftLeft" },
    .{ 0xE2, "AltLeft" },       .{ 0xE3, "MetaLeft" },       .{ 0xE4, "ControlRight" },   .{ 0xE5, "ShiftRight" },
    .{ 0xE6, "AltRight" },      .{ 0xE7, "MetaRight" },
};

const by_name = std.StaticStringMap(Usage).initComptime(blk: {
    var kvs: [codes.len]struct { []const u8, Usage } = undefined;
    for (codes, 0..) |c, i| kvs[i] = .{ c[1], c[0] };
    break :blk kvs;
});

/// The usage of W3C code `name` (exact case), or null.
pub fn fromName(code_name: []const u8) ?Usage {
    return by_name.get(code_name);
}

/// The W3C code name of `u`, or null.
pub fn name(u: Usage) ?[]const u8 {
    for (codes) |c| if (c[0] == u) return c[1];
    return null;
}

/// Usage of AltRight (AltGr on many layouts).
pub const alt_right: Usage = 0xE6;
/// Usage of Escape.
pub const escape: Usage = 0x29;

/// The modifier a modifier key produces, or null for other keys.
pub fn modifierOf(u: Usage) ?Modifier {
    return switch (u) {
        0xE0, 0xE4 => .ctrl,
        0xE1, 0xE5 => .shift,
        0xE2, 0xE6 => .alt,
        0xE3, 0xE7 => .super,
        else => null,
    };
}

/// One modifier.
pub const Modifier = enum(u2) { ctrl, shift, alt, super };

/// The modifiers a binding can name.
pub const Mods = packed struct(u4) {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,

    /// Whether no modifier is set.
    pub fn isEmpty(m: Mods) bool {
        return @as(u4, @bitCast(m)) == 0;
    }

    /// `m` with modifier `x` set.
    pub fn with(m: Mods, x: Modifier) Mods {
        var out = m;
        switch (x) {
            .ctrl => out.ctrl = true,
            .shift => out.shift = true,
            .alt => out.alt = true,
            .super => out.super = true,
        }
        return out;
    }

    /// Whether modifier `x` is set.
    pub fn has(m: Mods, x: Modifier) bool {
        return switch (x) {
            .ctrl => m.ctrl,
            .shift => m.shift,
            .alt => m.alt,
            .super => m.super,
        };
    }
};

/// Modifier state of an event, including lock and AltGr state (mirrors E01 `Mods`).
pub const EventMods = packed struct(u8) {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    /// AltGr is held (E01 already splits it from Ctrl+Alt on Windows).
    alt_gr: bool = false,
    _pad: u1 = 0,

    /// The bindable part.
    pub fn bindable(m: EventMods) Mods {
        return .{ .ctrl = m.ctrl, .shift = m.shift, .alt = m.alt, .super = m.super };
    }
};

/// A key event as the resolver sees it (mirrors E01 `KeyEvent`).
pub const KeyInput = struct {
    usage: Usage,
    mods: EventMods = .{},
    action: enum { press, repeat, release } = .press,
    /// The character the event produced, if any (after Shift/AltGr).
    codepoint: ?u21 = null,
    /// Monotonic event time, for chord timeouts and double taps.
    t_ns: u64 = 0,
};

/// The level-1 characters of a keyboard layout per physical key, built from
/// E01 layout data (Win32 `ToUnicodeEx` without modifiers, XKB level 1).
pub const LayoutInfo = struct {
    name: []const u8,
    /// Unshifted, lowercase base character per usage.
    base: [0xE8]?u21,
    latin: bool,

    /// A layout from `(usage, char)` pairs; unlisted keys have no character.
    pub fn fromPairs(layout_name: []const u8, pairs: []const struct { Usage, u21 }) LayoutInfo {
        var l: LayoutInfo = .{ .name = layout_name, .base = @splat(null), .latin = true };
        for (pairs) |p| if (p[0] < l.base.len) {
            l.base[p[0]] = lower(p[1]);
        };
        // A layout is Latin when its letter keys produce ASCII letters.
        var ascii_letters: u32 = 0;
        for (0x04..0x1E) |u| if (l.base[u]) |c| {
            if (c < 0x80 and std.ascii.isAlphabetic(@intCast(c))) ascii_letters += 1;
        };
        l.latin = ascii_letters >= 20;
        return l;
    }

    /// The unshifted level-1 character for `u`, lowercase.
    pub fn baseChar(l: *const LayoutInfo, u: Usage) ?u21 {
        return if (u < l.base.len) l.base[u] else null;
    }

    /// The physical key producing `c` unshifted, if any.
    pub fn keyForChar(l: *const LayoutInfo, c: u21) ?Usage {
        const lc = lower(c);
        for (l.base, 0..) |b, u| if (b != null and b.? == lc) return @intCast(u);
        return null;
    }

    /// Whether letters on this layout are Latin.
    pub fn isLatin(l: *const LayoutInfo) bool {
        return l.latin;
    }
};

/// Lowercase for ASCII and the Latin-1/Cyrillic ranges used by layouts.
pub fn lower(c: u21) u21 {
    if (c < 0x80) return std.ascii.toLower(@intCast(c));
    if (c >= 0xC0 and c <= 0xDE and c != 0xD7) return c + 0x20;
    if (c >= 0x410 and c <= 0x42F) return c + 0x20;
    if (c == 0x401) return 0x451;
    return c;
}

/// The US QWERTY base character of `u` (the fallback for non-Latin layouts).
pub fn usChar(u: Usage) ?u21 {
    return us_layout.baseChar(u);
}

const us_pairs = blk: {
    var p: [47]struct { Usage, u21 } = undefined;
    var n = 0;
    for (0..26) |i| {
        p[n] = .{ 0x04 + i, 'a' + i };
        n += 1;
    }
    for (0..9) |i| {
        p[n] = .{ 0x1E + i, '1' + i };
        n += 1;
    }
    p[n] = .{ 0x27, '0' };
    n += 1;
    for ([_]struct { Usage, u21 }{ .{ 0x2D, '-' }, .{ 0x2E, '=' }, .{ 0x2F, '[' }, .{ 0x30, ']' }, .{ 0x31, '\\' }, .{ 0x33, ';' }, .{ 0x34, '\'' }, .{ 0x35, '`' }, .{ 0x36, ',' }, .{ 0x37, '.' }, .{ 0x38, '/' } }) |x| {
        p[n] = x;
        n += 1;
    }
    break :blk p;
};

/// The US QWERTY layout.
pub const us_layout: LayoutInfo = LayoutInfo.fromPairs("us", &us_pairs);

/// Layout fixtures for tests (level-1 characters that differ from US).
pub const fixtures = struct {
    fn derive(comptime layout_name: []const u8, comptime changes: []const struct { Usage, u21 }) LayoutInfo {
        var pairs: [us_pairs.len + changes.len]struct { Usage, u21 } = undefined;
        for (us_pairs, 0..) |p, i| pairs[i] = p;
        for (changes, us_pairs.len..) |p, i| pairs[i] = p;
        return LayoutInfo.fromPairs(layout_name, &pairs);
    }

    /// German QWERTZ.
    pub const de = derive("de", &.{ .{ 0x1C, 'z' }, .{ 0x1D, 'y' }, .{ 0x2D, 0xDF }, .{ 0x2E, 0xB4 }, .{ 0x2F, 0xFC }, .{ 0x30, '+' }, .{ 0x31, '#' }, .{ 0x33, 0xF6 }, .{ 0x34, 0xE4 }, .{ 0x35, '^' }, .{ 0x38, '-' } });
    /// French AZERTY: the digit row is unshifted symbols.
    pub const fr_azerty = derive("fr", &.{
        .{ 0x14, 'a' },  .{ 0x04, 'q' },  .{ 0x1A, 'z' }, .{ 0x1D, 'w' },  .{ 0x33, 'm' }, .{ 0x10, ',' }, .{ 0x36, ';' },  .{ 0x37, ':' }, .{ 0x38, '!' },
        .{ 0x1E, '&' },  .{ 0x1F, 0xE9 }, .{ 0x20, '"' }, .{ 0x21, '\'' }, .{ 0x22, '(' }, .{ 0x23, '-' }, .{ 0x24, 0xE8 }, .{ 0x25, '_' }, .{ 0x26, 0xE7 },
        .{ 0x27, 0xE0 },
    });
    /// Russian ЙЦУКЕН.
    pub const ru = derive("ru", &.{
        .{ 0x14, 0x439 }, .{ 0x1A, 0x446 }, .{ 0x08, 0x443 }, .{ 0x15, 0x43A }, .{ 0x17, 0x435 }, .{ 0x1C, 0x43D }, .{ 0x18, 0x433 }, .{ 0x0C, 0x448 }, .{ 0x12, 0x449 }, .{ 0x13, 0x437 },
        .{ 0x04, 0x444 }, .{ 0x16, 0x44B }, .{ 0x07, 0x432 }, .{ 0x09, 0x430 }, .{ 0x0A, 0x43F }, .{ 0x0B, 0x440 }, .{ 0x0D, 0x43E }, .{ 0x0E, 0x43B }, .{ 0x0F, 0x434 }, .{ 0x1D, 0x44F },
        .{ 0x1B, 0x447 }, .{ 0x06, 0x441 }, .{ 0x19, 0x43C }, .{ 0x05, 0x438 }, .{ 0x11, 0x442 }, .{ 0x10, 0x44C },
    });
    /// US Dvorak.
    pub const dvorak = derive("dvorak", &.{
        .{ 0x14, '\'' }, .{ 0x1A, ',' }, .{ 0x08, '.' }, .{ 0x15, 'p' }, .{ 0x17, 'y' }, .{ 0x1C, 'f' }, .{ 0x18, 'g' }, .{ 0x0C, 'c' }, .{ 0x12, 'r' }, .{ 0x13, 'l' },
        .{ 0x04, 'a' },  .{ 0x16, 'o' }, .{ 0x07, 'e' }, .{ 0x09, 'u' }, .{ 0x0A, 'i' }, .{ 0x0B, 'd' }, .{ 0x0D, 'h' }, .{ 0x0E, 't' }, .{ 0x0F, 'n' }, .{ 0x33, 's' },
        .{ 0x1D, ';' },  .{ 0x1B, 'q' }, .{ 0x06, 'j' }, .{ 0x19, 'k' }, .{ 0x05, 'x' }, .{ 0x11, 'b' }, .{ 0x10, 'm' }, .{ 0x36, 'w' }, .{ 0x37, 'v' }, .{ 0x38, 'z' },
        .{ 0x2D, '[' },  .{ 0x2E, ']' }, .{ 0x2F, '/' }, .{ 0x30, '=' }, .{ 0x34, '-' },
    });
};

test "keys: names round trip" {
    for (codes) |c| {
        try std.testing.expectEqual(c[0], fromName(c[1]).?);
        try std.testing.expectEqualStrings(c[1], name(c[0]).?);
    }
    try std.testing.expect(fromName("keya") == null);
}

test "keys: layouts" {
    try std.testing.expect(us_layout.isLatin());
    try std.testing.expectEqual(@as(?u21, 'y'), fixtures.de.baseChar(0x1D));
    try std.testing.expectEqual(@as(?Usage, 0x1C), fixtures.de.keyForChar('Z'));
    try std.testing.expect(!fixtures.ru.isLatin());
    try std.testing.expect(fixtures.fr_azerty.isLatin());
    try std.testing.expect(fixtures.dvorak.isLatin());
    try std.testing.expectEqual(@as(?u21, 'c'), usChar(0x06));
}
