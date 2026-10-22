//! Functional-key tables for the legacy xterm (PC-style) and kitty
//! encodings, built at comptime from the specs:
//! - xterm ctlseqs, "PC-Style Function Keys":
//!   https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-PC-Style-Function-Keys
//! - kitty keyboard protocol, "Functional key definitions":
//!   https://sw.kovidgoyal.net/kitty/keyboard-protocol/#functional-key-definitions

const Key = @import("keys.zig").Key;

/// How a functional key is written: `CSI number ~`, `CSI 1 ; m <letter>`
/// (or `CSI <letter>` / `SS3 <letter>` without modifiers), or kitty's
/// `CSI code u`.
pub const Form = union(enum) {
    tilde: u16,
    letter: u8,
    /// Kitty only: a `CSI code u` key (Private Use Area code or C0 value).
    u: u21,
};

/// One functional key.
pub const Entry = struct {
    /// Legacy xterm form; null when xterm has no encoding.
    legacy: ?Form,
    /// Kitty form.
    kitty: Form,
    /// Legacy letter forms switch to SS3 under DECCKM (cursor keys, Home,
    /// End) or always use SS3 without modifiers (F1-F4).
    ss3: enum { never, decckm, always } = .never,
};

/// The functional key entry for `k`, or null for text keys.
pub fn functional(k: Key) ?Entry {
    return table[@intFromEnum(k)];
}

const table: [256]?Entry = blk: {
    var t: [256]?Entry = @splat(null);
    const set = struct {
        fn f(tt: *[256]?Entry, k: Key, e: Entry) void {
            tt[@intFromEnum(k)] = e;
        }
    }.f;
    set(&t, .up, .{ .legacy = .{ .letter = 'A' }, .kitty = .{ .letter = 'A' }, .ss3 = .decckm });
    set(&t, .down, .{ .legacy = .{ .letter = 'B' }, .kitty = .{ .letter = 'B' }, .ss3 = .decckm });
    set(&t, .right, .{ .legacy = .{ .letter = 'C' }, .kitty = .{ .letter = 'C' }, .ss3 = .decckm });
    set(&t, .left, .{ .legacy = .{ .letter = 'D' }, .kitty = .{ .letter = 'D' }, .ss3 = .decckm });
    set(&t, .home, .{ .legacy = .{ .letter = 'H' }, .kitty = .{ .letter = 'H' }, .ss3 = .decckm });
    set(&t, .end, .{ .legacy = .{ .letter = 'F' }, .kitty = .{ .letter = 'F' }, .ss3 = .decckm });
    set(&t, .insert, .{ .legacy = .{ .tilde = 2 }, .kitty = .{ .tilde = 2 } });
    set(&t, .delete, .{ .legacy = .{ .tilde = 3 }, .kitty = .{ .tilde = 3 } });
    set(&t, .page_up, .{ .legacy = .{ .tilde = 5 }, .kitty = .{ .tilde = 5 } });
    set(&t, .page_down, .{ .legacy = .{ .tilde = 6 }, .kitty = .{ .tilde = 6 } });
    set(&t, .f1, .{ .legacy = .{ .letter = 'P' }, .kitty = .{ .letter = 'P' }, .ss3 = .always });
    set(&t, .f2, .{ .legacy = .{ .letter = 'Q' }, .kitty = .{ .letter = 'Q' }, .ss3 = .always });
    // kitty: F3 is `CSI 13 ~` because `CSI R` is the cursor position report.
    set(&t, .f3, .{ .legacy = .{ .letter = 'R' }, .kitty = .{ .tilde = 13 }, .ss3 = .always });
    set(&t, .f4, .{ .legacy = .{ .letter = 'S' }, .kitty = .{ .letter = 'S' }, .ss3 = .always });
    const tildes = [_]struct { Key, u16 }{
        .{ .f5, 15 }, .{ .f6, 17 }, .{ .f7, 18 }, .{ .f8, 19 }, .{ .f9, 20 }, .{ .f10, 21 }, .{ .f11, 23 }, .{ .f12, 24 },
    };
    for (tildes) |e| set(&t, e[0], .{ .legacy = .{ .tilde = e[1] }, .kitty = .{ .tilde = e[1] } });
    // F13-F24: kitty PUA 57376..; legacy xterm sends Shift+F1..F12 (handled
    // by the legacy encoder, so no legacy form here).
    for (0..12) |i| set(&t, @enumFromInt(@intFromEnum(Key.f13) + i), .{ .legacy = null, .kitty = .{ .u = 57376 + @as(u21, @intCast(i)) } });
    set(&t, .caps_lock, .{ .legacy = null, .kitty = .{ .u = 57358 } });
    set(&t, .scroll_lock, .{ .legacy = null, .kitty = .{ .u = 57359 } });
    set(&t, .num_lock, .{ .legacy = null, .kitty = .{ .u = 57360 } });
    set(&t, .print_screen, .{ .legacy = null, .kitty = .{ .u = 57361 } });
    set(&t, .pause, .{ .legacy = null, .kitty = .{ .u = 57362 } });
    set(&t, .context_menu, .{ .legacy = null, .kitty = .{ .u = 57363 } });
    // Keypad: kitty PUA codes; legacy handled by the keypad table below.
    const kp = [_]struct { Key, u21 }{
        .{ .kp_0, 57399 },        .{ .kp_1, 57400 },        .{ .kp_2, 57401 },       .{ .kp_3, 57402 },
        .{ .kp_4, 57403 },        .{ .kp_5, 57404 },        .{ .kp_6, 57405 },       .{ .kp_7, 57406 },
        .{ .kp_8, 57407 },        .{ .kp_9, 57408 },        .{ .kp_decimal, 57409 }, .{ .kp_divide, 57410 },
        .{ .kp_multiply, 57411 }, .{ .kp_subtract, 57412 }, .{ .kp_add, 57413 },     .{ .kp_enter, 57414 },
        .{ .kp_equal, 57415 },
    };
    for (kp) |e| set(&t, e[0], .{ .legacy = null, .kitty = .{ .u = e[1] } });
    const mods = [_]struct { Key, u21 }{
        .{ .left_shift, 57441 },  .{ .left_ctrl, 57442 },  .{ .left_alt, 57443 },  .{ .left_super, 57444 },
        .{ .right_shift, 57447 }, .{ .right_ctrl, 57448 }, .{ .right_alt, 57449 }, .{ .right_super, 57450 },
    };
    for (mods) |e| set(&t, e[0], .{ .legacy = null, .kitty = .{ .u = e[1] } });
    break :blk t;
};

/// Whether `k` is a modifier key (kitty reports these only with flag 8).
pub fn isModifier(k: Key) bool {
    return switch (k) {
        .left_shift, .left_ctrl, .left_alt, .left_super, .right_shift, .right_ctrl, .right_alt, .right_super, .caps_lock, .num_lock, .scroll_lock => true,
        else => false,
    };
}

/// Legacy keypad keys: the DECKPAM (application keypad) SS3 final and the
/// text sent in numeric mode.
pub const Keypad = struct { ss3: u8, text: u8 };

/// The keypad entry for `k`, or null when `k` is not on the keypad.
pub fn keypad(k: Key) ?Keypad {
    return switch (k) {
        .kp_0 => .{ .ss3 = 'p', .text = '0' },
        .kp_1 => .{ .ss3 = 'q', .text = '1' },
        .kp_2 => .{ .ss3 = 'r', .text = '2' },
        .kp_3 => .{ .ss3 = 's', .text = '3' },
        .kp_4 => .{ .ss3 = 't', .text = '4' },
        .kp_5 => .{ .ss3 = 'u', .text = '5' },
        .kp_6 => .{ .ss3 = 'v', .text = '6' },
        .kp_7 => .{ .ss3 = 'w', .text = '7' },
        .kp_8 => .{ .ss3 = 'x', .text = '8' },
        .kp_9 => .{ .ss3 = 'y', .text = '9' },
        .kp_decimal => .{ .ss3 = 'n', .text = '.' },
        .kp_divide => .{ .ss3 = 'o', .text = '/' },
        .kp_multiply => .{ .ss3 = 'j', .text = '*' },
        .kp_subtract => .{ .ss3 = 'm', .text = '-' },
        .kp_add => .{ .ss3 = 'k', .text = '+' },
        .kp_enter => .{ .ss3 = 'M', .text = '\r' },
        .kp_equal => .{ .ss3 = 'X', .text = '=' },
        else => null,
    };
}

/// The unshifted US-layout code point of a text key, or 0. Used when the
/// event carries no layout code point.
pub fn usCodepoint(k: Key) u21 {
    const v = @intFromEnum(k);
    if (v >= @intFromEnum(Key.key_a) and v <= @intFromEnum(Key.key_z)) return 'a' + @as(u21, v - @intFromEnum(Key.key_a));
    if (v >= @intFromEnum(Key.digit_1) and v <= @intFromEnum(Key.digit_9)) return '1' + @as(u21, v - @intFromEnum(Key.digit_1));
    return switch (k) {
        .digit_0 => '0',
        .space => ' ',
        .minus => '-',
        .equal => '=',
        .bracket_left => '[',
        .bracket_right => ']',
        .backslash => '\\',
        .semicolon => ';',
        .quote => '\'',
        .grave => '`',
        .comma => ',',
        .period => '.',
        .slash => '/',
        else => 0,
    };
}
