//! The kitty keyboard protocol encoder
//! (https://sw.kovidgoyal.net/kitty/keyboard-protocol/):
//! `CSI code[:shifted[:base]] ; mods[:event] ; text u`, the legacy-compatible
//! `CSI 1 ; mods <letter>` and `CSI n ; mods ~` forms, and the five
//! progressive-enhancement flags.

const std = @import("std");
const key_encode = @import("key_encode.zig");
const tables = @import("keytables.zig");
const EncoderState = key_encode.EncoderState;
const KeyInput = key_encode.KeyInput;
const Key = key_encode.Key;

/// Flag bits.
pub const disambiguate: u5 = 1;
pub const event_types: u5 = 2;
pub const alternate_keys: u5 = 4;
pub const all_keys: u5 = 8;
pub const associated_text: u5 = 16;

/// The modifier bits (shift 1, alt 2, ctrl 4, super 8, caps lock 64, num
/// lock 128). Lock bits are reported only with `all_keys`. For a modifier
/// key itself, its own bit is set on press and repeat and clear on release.
fn modBits(k: KeyInput, flags: u5) u8 {
    var m = k.mods;
    switch (k.key) {
        .left_shift, .right_shift => m.shift = k.action != .release,
        .left_ctrl, .right_ctrl => m.ctrl = k.action != .release,
        .left_alt, .right_alt => m.alt = k.action != .release,
        .left_super, .right_super => m.super = k.action != .release,
        else => {},
    }
    var v: u8 = 0;
    if (m.shift) v |= 1;
    if (m.alt and !m.alt_gr) v |= 2;
    if (m.ctrl and !m.alt_gr) v |= 4;
    if (m.super) v |= 8;
    if (flags & all_keys != 0) {
        if (m.caps_lock) v |= 64;
        if (m.num_lock) v |= 128;
    }
    return v;
}

/// Encodes `k` under `st.kitty_flags`.
pub fn encode(st: *const EncoderState, k: KeyInput, w: *std.Io.Writer) !void {
    const flags = st.kitty_flags;
    const all = flags & all_keys != 0;
    const disamb = flags & disambiguate != 0 or all;
    const events = flags & event_types != 0;
    if (k.action == .release and !events) return;
    // Without event reporting a repeat is just another press.
    const action: key_encode.Action = if (k.action == .repeat and !events) .press else k.action;
    const bits = modBits(k, flags);
    const text_mods = bits & (2 | 4 | 8) != 0; // alt, ctrl or super

    if (tables.isModifier(k.key)) {
        if (!all) return;
        return writeU(w, tables.functional(k.key).?.kitty.u, null, bits, action, "", flags);
    }
    switch (k.key) {
        .enter, .tab, .backspace, .escape => {
            const code: u21 = switch (k.key) {
                .enter => 13,
                .tab => 9,
                .backspace => 127,
                else => 27,
            };
            // Esc is always disambiguated; Enter, Tab and Backspace keep
            // their legacy bytes without modifiers, and report releases only
            // with all_keys.
            const escape = all or (disamb and (k.key == .escape or bits != 0));
            if (!escape) {
                if (action == .release) return;
                return key_encode.legacy(st, k, w);
            }
            return writeU(w, code, null, bits, action, "", flags);
        },
        else => {},
    }
    if (tables.functional(k.key)) |e| {
        switch (e.kitty) {
            .u => |code| {
                // Keypad and other PUA keys are disambiguated, except keypad
                // keys that produce text (and keypad Enter) without Ctrl,
                // Alt or Super, which only all_keys turns into codes.
                const kp_text = tables.keypad(k.key) != null and !text_mods and (k.key == .kp_enter or k.text.len > 0);
                if (!disamb or (!all and kp_text)) {
                    if (action == .release) return;
                    return key_encode.legacy(st, k, w);
                }
                return writeU(w, code, null, bits, action, "", flags);
            },
            .tilde => |n| {
                if (bits == 0 and action == .press) return w.print("\x1b[{d}~", .{n});
                try w.print("\x1b[{d};", .{n});
                try writeMods(w, bits, action);
                return w.writeByte('~');
            },
            .letter => |c| {
                if (bits == 0 and action == .press) {
                    // Legacy-compatible: SS3 for F1-F4 and under DECCKM.
                    const ss3 = switch (e.ss3) {
                        .never => false,
                        .decckm => st.decckm,
                        .always => true,
                    };
                    return w.print("\x1b{c}{c}", .{ @as(u8, if (ss3) 'O' else '['), c });
                }
                try w.writeAll("\x1b[1;");
                try writeMods(w, bits, action);
                return w.writeByte(c);
            },
        }
    }
    // Text keys.
    const cp = lower(if (k.codepoint != 0) k.codepoint else tables.usCodepoint(k.key));
    if (!all and !(disamb and text_mods)) {
        if (action == .release) return;
        return key_encode.legacy(st, k, w);
    }
    if (cp == 0) {
        // No key code: the text alone, as key 0 (all_keys with text only).
        if (!all or k.text.len == 0) return;
        return writeU(w, 0, k, bits, action, k.text, flags);
    }
    const text = if (all and flags & associated_text != 0 and action != .release) k.text else "";
    return writeU(w, cp, k, bits, action, text, flags);
}

fn lower(cp: u21) u21 {
    return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
}

fn writeMods(w: *std.Io.Writer, bits: u8, action: key_encode.Action) !void {
    try w.print("{d}", .{@as(u16, bits) + 1});
    switch (action) {
        .press => {},
        .repeat => try w.writeAll(":2"),
        .release => try w.writeAll(":3"),
    }
}

/// `CSI code[:shifted[:base]] [; mods[:event] [; text]] u`.
fn writeU(w: *std.Io.Writer, code: u21, k: ?KeyInput, bits: u8, action: key_encode.Action, text: []const u8, flags: u5) !void {
    try w.print("\x1b[{d}", .{code});
    if (k) |key| if (flags & alternate_keys != 0) {
        const shifted: u21 = if (key.mods.shift and key.shifted_cp != 0 and key.shifted_cp != code) key.shifted_cp else 0;
        const base: u21 = if (key.base_layout_cp != 0 and key.base_layout_cp != code) key.base_layout_cp else 0;
        if (shifted != 0) try w.print(":{d}", .{shifted});
        if (base != 0) try w.print("{s}:{d}", .{ if (shifted == 0) ":" else "", base });
    };
    const has_text = textCodepoints(text) > 0;
    if (bits != 0 or action != .press) {
        try w.writeByte(';');
        try writeMods(w, bits, action);
    } else if (has_text) try w.writeByte(';');
    if (has_text) {
        try w.writeByte(';');
        var first = true;
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (it.nextCodepoint()) |c| {
            if (c < 0x20 or c == 0x7f or (c >= 0x80 and c < 0xa0)) continue;
            if (!first) try w.writeByte(':');
            try w.print("{d}", .{c});
            first = false;
        }
    }
    try w.writeByte('u');
}

/// How many non-control code points `text` holds (invalid UTF-8 counts as none).
fn textCodepoints(text: []const u8) usize {
    const view = std.unicode.Utf8View.init(text) catch return 0;
    var n: usize = 0;
    var it = view.iterator();
    while (it.nextCodepoint()) |c| {
        if (c < 0x20 or c == 0x7f or (c >= 0x80 and c < 0xa0)) continue;
        n += 1;
    }
    return n;
}

test {
    _ = @import("kitty_test.zig");
}
