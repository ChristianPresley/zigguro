//! Input routing helpers (E06.F04.S01.T01, E06.F04.S02.T01): zg_gui key and
//! pointer events as the zg_terminal encoders' inputs, and which keys stay
//! with the IDE instead of reaching the application.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_platform = @import("zg_platform");
const zg_terminal = @import("zg_terminal");

const input = zg_terminal.input;
const KeyPress = zg_gui.input.event.KeyPress;
const Button = zg_gui.input.event.Button;
const PKey = zg_platform.keys.Key;

/// The encoders' modifiers for zg_platform's.
pub fn mods(m: zg_platform.keys.Mods) input.Mods {
    return .{
        .shift = m.shift,
        .ctrl = m.ctrl,
        .alt = m.alt,
        .super = m.super,
        .alt_gr = m.alt_gr,
        .caps_lock = m.caps_lock,
        .num_lock = m.num_lock,
    };
}

/// Whether `cp` is text a key types (not a control character).
fn printable(cp: u21) bool {
    return cp >= 0x20 and cp != 0x7f and !(cp >= 0x80 and cp < 0xa0);
}

/// `kp` as an encoder input. Both key enums are USB HID usages. The
/// layout's text goes in `text` (written to `buf`); the unshifted code point
/// is left to the encoders' US-layout fallback.
pub fn keyInput(kp: KeyPress, buf: *[4]u8) input.KeyInput {
    const m = mods(kp.mods);
    var k: input.KeyInput = .{
        .key = @enumFromInt(@intFromEnum(kp.key)),
        .mods = m,
        .action = switch (kp.action) {
            .press => .press,
            .repeat => .repeat,
            .release => .release,
        },
    };
    if (printable(kp.codepoint)) {
        const n = std.unicode.utf8Encode(kp.codepoint, buf) catch 0;
        // Ctrl+key sends its control byte, never the layout's text.
        if (!(m.ctrl and !m.alt_gr)) k.text = buf[0..n];
        if (m.shift) k.shifted_cp = kp.codepoint;
    }
    return k;
}

/// Keys the IDE keeps by default, like VS Code's `commandsToSkipShell`:
/// Ctrl+Shift+letter or digit (palette, copy, paste, new terminal), Ctrl+`
/// (toggle the panel) and F1 (commands). Everything else reaches the
/// application.
pub fn defaultBubble(kp: KeyPress) bool {
    const m = kp.mods;
    if (m.alt_gr) return false;
    if (kp.key == .f1 and !m.ctrl and !m.alt and !m.shift) return true;
    if (m.ctrl and !m.alt and kp.key == .backquote) return true;
    if (m.ctrl and m.shift and !m.alt) {
        const v = @intFromEnum(kp.key);
        return v >= @intFromEnum(PKey.key_a) and v <= @intFromEnum(PKey.digit_0);
    }
    return false;
}

/// The xterm button code of a pointer button (buttons 8 and 9 are back
/// and forward).
pub fn mouseButton(b: Button) u8 {
    return switch (b) {
        .left => 0,
        .middle => 1,
        .right => 2,
        .back => 128,
        .forward => 129,
    };
}

/// The `buttons_down` bit of a pointer button (none for back/forward).
pub fn buttonBit(b: Button) u8 {
    return switch (b) {
        .left => 1,
        .middle => 2,
        .right => 4,
        else => 0,
    };
}

const testing = std.testing;

test "route: key input carries text, never with Ctrl" {
    var buf: [4]u8 = undefined;
    var k = keyInput(.{ .key = .key_a, .codepoint = 'a' }, &buf);
    try testing.expectEqualStrings("a", k.text);
    try testing.expectEqual(input.Key.key_a, k.key);
    k = keyInput(.{ .key = .key_a, .codepoint = 'A', .mods = .{ .shift = true } }, &buf);
    try testing.expectEqualStrings("A", k.text);
    try testing.expectEqual(@as(u21, 'A'), k.shifted_cp);
    k = keyInput(.{ .key = .key_c, .codepoint = 'c', .mods = .{ .ctrl = true } }, &buf);
    try testing.expectEqualStrings("", k.text);
    // AltGr text stays text.
    k = keyInput(.{ .key = .key_q, .codepoint = '@', .mods = .{ .ctrl = true, .alt = true, .alt_gr = true } }, &buf);
    try testing.expectEqualStrings("@", k.text);
    k = keyInput(.{ .key = .arrow_up, .action = .release }, &buf);
    try testing.expectEqual(input.Key.up, k.key);
    try testing.expectEqual(input.Action.release, k.action);
}

test "route: the IDE keeps Ctrl+Shift letters, Ctrl+` and F1" {
    try testing.expect(defaultBubble(.{ .key = .key_p, .mods = .{ .ctrl = true, .shift = true } }));
    try testing.expect(defaultBubble(.{ .key = .backquote, .mods = .{ .ctrl = true } }));
    try testing.expect(defaultBubble(.{ .key = .f1 }));
    try testing.expect(!defaultBubble(.{ .key = .key_c, .mods = .{ .ctrl = true } }));
    try testing.expect(!defaultBubble(.{ .key = .arrow_up, .mods = .{ .ctrl = true, .shift = true } }));
    try testing.expect(!defaultBubble(.{ .key = .f1, .mods = .{ .shift = true } }));
}
