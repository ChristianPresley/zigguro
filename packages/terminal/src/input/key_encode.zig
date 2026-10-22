//! Key encoding: `encodeKey` turns a key event into the bytes the
//! application expects, following the modes it set. Legacy xterm encoding
//! lives here; the kitty keyboard protocol is in `kitty.zig`.
//!
//! Legacy follows xterm's PC-style function keys and modifyOtherKeys
//! (https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-PC-Style-Function-Keys,
//! https://invisible-island.net/xterm/modified-keys.html).

const std = @import("std");
const keys = @import("keys.zig");
const tables = @import("keytables.zig");
const kitty = @import("kitty.zig");
const mouse = @import("mouse.zig");

pub const Key = keys.Key;
pub const Mods = keys.Mods;

/// Press, repeat or release.
pub const Action = enum { press, repeat, release };

/// One key event, as the view builds it from the platform event.
pub const KeyInput = struct {
    key: Key,
    mods: Mods = .{},
    action: Action = .press,
    /// Text the layout produced for this event (shift applied); may be empty.
    text: []const u8 = "",
    /// The key's unshifted code point in the current layout (0: use the US
    /// layout for text keys).
    codepoint: u21 = 0,
    /// The code point with Shift applied, for kitty alternate keys.
    shifted_cp: u21 = 0,
    /// The key's code point in the US layout, for kitty alternate keys.
    base_layout_cp: u21 = 0,
    /// Native Win32 key data, for win32-input-mode (E06.F04.S01.T02).
    win: ?struct { vk: u16, scan: u16, ctrl_state: u32, utf16: u16 } = null,
};

/// The modes the encoders read, snapshotted from the terminal.
pub const EncoderState = struct {
    /// DECCKM: cursor keys send SS3.
    decckm: bool = false,
    /// DECKPAM: application keypad.
    deckpam: bool = false,
    /// The active screen's kitty keyboard flags.
    kitty_flags: u5 = 0,
    win32_input: bool = false,
    /// Alt sends an ESC prefix (modes 1036/1039); else it sets the 8th bit.
    meta_sends_esc: bool = true,
    /// DECBKM: Backspace sends BS instead of DEL.
    backarrow_bs: bool = false,
    /// LNM: Enter sends CR LF.
    linefeed: bool = false,
    /// xterm modifyOtherKeys level (`CSI > 4 ; n m`).
    modify_other_keys: u2 = 0,
    mouse: mouse.MouseMode = .none,
    mouse_enc: mouse.MouseEncoding = .default,
    bracketed_paste: bool = false,
    focus_events: bool = false,
    alt_scroll: bool = false,
    alt_screen: bool = false,
};

/// xterm's modifier parameter: 1 + shift 1 | alt 2 | ctrl 4 | meta 8.
pub fn modParam(m: Mods) u8 {
    var v: u8 = 0;
    if (m.shift) v |= 1;
    if (m.alt and !m.alt_gr) v |= 2;
    if (m.ctrl and !m.alt_gr) v |= 4;
    if (m.super) v |= 8;
    return v + 1;
}

/// Encodes `k` into `out`; an empty result means nothing is sent (a legacy
/// release, or a key with no encoding).
pub fn encodeKey(st: *const EncoderState, k: KeyInput, out: *[64]u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    if (st.kitty_flags != 0) {
        kitty.encode(st, k, &w) catch return "";
    } else {
        legacy(st, k, &w) catch return "";
    }
    return w.buffered();
}

/// The legacy (xterm) encoding of `k`.
pub fn legacy(st: *const EncoderState, k: KeyInput, w: *std.Io.Writer) !void {
    if (k.action == .release) return;
    const m = k.mods;
    const alt = m.alt and !m.alt_gr;
    const ctrl = m.ctrl and !m.alt_gr;
    const mp = modParam(m);

    if (tables.functional(k.key)) |e| {
        if (e.legacy) |f| return writeFunctional(w, f, e.ss3, mp, st.decckm);
        // F13-F24: xterm sends Shift+F1..F12.
        const v = @intFromEnum(k.key);
        if (v >= @intFromEnum(Key.f13) and v <= @intFromEnum(Key.f24)) {
            const base: Key = @enumFromInt(@intFromEnum(Key.f1) + (v - @intFromEnum(Key.f13)));
            const be = tables.functional(base).?;
            return writeFunctional(w, be.legacy.?, be.ss3, ((mp - 1) | 1) + 1, st.decckm);
        }
    }
    if (tables.keypad(k.key)) |kp| {
        if (st.deckpam) return w.print("\x1bO{c}", .{kp.ss3});
        if (k.key == .kp_enter) return enter(st, w, alt, mp);
        if (alt) try w.writeByte(0x1b);
        return w.writeByte(kp.text);
    }
    switch (k.key) {
        .enter => return enter(st, w, alt, mp),
        .tab => {
            if (st.modify_other_keys == 2 and (ctrl or alt)) return w.print("\x1b[27;{d};9~", .{mp});
            if (m.shift and !ctrl and !alt) return w.writeAll("\x1b[Z");
            if (alt) try w.writeByte(0x1b);
            return w.writeByte('\t');
        },
        .backspace => {
            if (st.modify_other_keys == 2 and (ctrl or alt)) return w.print("\x1b[27;{d};127~", .{mp});
            // DECBKM picks BS or DEL; Ctrl sends the other one.
            const bs = st.backarrow_bs != ctrl;
            if (alt) try w.writeByte(0x1b);
            return w.writeByte(if (bs) 0x08 else 0x7f);
        },
        .escape => {
            if (st.modify_other_keys == 2 and (ctrl or alt or m.shift)) return w.print("\x1b[27;{d};27~", .{mp});
            if (alt) try w.writeByte(0x1b);
            return w.writeByte(0x1b);
        },
        else => {},
    }
    if (tables.isModifier(k.key)) return;

    // Text keys.
    const cp = if (k.codepoint != 0) k.codepoint else tables.usCodepoint(k.key);
    const shifted = shiftedOf(k, cp);
    if (ctrl) {
        const c = ctrlByte(cp);
        if (st.modify_other_keys == 2 or (st.modify_other_keys == 1 and (c == null or m.shift))) {
            if (shifted != 0) return w.print("\x1b[27;{d};{d}~", .{ mp, shifted });
        }
        if (c) |b| {
            if (alt) try w.writeByte(0x1b);
            return w.writeByte(b);
        }
    }
    if (alt and st.modify_other_keys == 2 and shifted != 0) return w.print("\x1b[27;{d};{d}~", .{ mp, shifted });
    var buf: [4]u8 = undefined;
    const text: []const u8 = if (k.text.len > 0) k.text else if (shifted != 0) buf[0 .. std.unicode.utf8Encode(shifted, &buf) catch return] else return;
    if (alt) {
        if (st.meta_sends_esc) {
            try w.writeByte(0x1b);
        } else if (text.len == 1 and text[0] < 0x80) {
            // eightBitInput: the 8th bit set, sent as UTF-8.
            var b8: [2]u8 = undefined;
            const n = std.unicode.utf8Encode(@as(u21, text[0]) | 0x80, &b8) catch unreachable;
            return w.writeAll(b8[0..n]);
        }
    }
    try w.writeAll(text);
}

fn enter(st: *const EncoderState, w: *std.Io.Writer, alt: bool, mp: u8) !void {
    if (st.modify_other_keys == 2 and mp > 1) return w.print("\x1b[27;{d};13~", .{mp});
    if (alt) try w.writeByte(0x1b);
    try w.writeAll(if (st.linefeed) "\r\n" else "\r");
}

fn writeFunctional(w: *std.Io.Writer, f: tables.Form, ss3: @FieldType(tables.Entry, "ss3"), mp: u8, decckm: bool) !void {
    switch (f) {
        .tilde => |n| if (mp > 1) try w.print("\x1b[{d};{d}~", .{ n, mp }) else try w.print("\x1b[{d}~", .{n}),
        .letter => |c| {
            if (mp > 1) return w.print("\x1b[1;{d}{c}", .{ mp, c });
            const use_ss3 = switch (ss3) {
                .never => false,
                .decckm => decckm,
                .always => true,
            };
            try w.print("\x1b{c}{c}", .{ @as(u8, if (use_ss3) 'O' else '['), c });
        },
        .u => {},
    }
}

/// The code point with Shift applied: the layout's when given, else the
/// US-layout shift of ASCII.
fn shiftedOf(k: KeyInput, cp: u21) u21 {
    if (!k.mods.shift) return cp;
    if (k.shifted_cp != 0) return k.shifted_cp;
    if (cp >= 'a' and cp <= 'z') return cp - 32;
    const pairs = "1!2@3#4$5%6^7&8*9(0)-_=+[{]}\\|;:'\",<.>/?`~";
    var i: usize = 0;
    while (i < pairs.len) : (i += 2) if (pairs[i] == cp) return pairs[i + 1];
    return cp;
}

/// The C0 byte Ctrl+`cp` sends, or null when Ctrl has no control mapping.
pub fn ctrlByte(cp: u21) ?u8 {
    return switch (cp) {
        'a'...'z' => @intCast(cp - 'a' + 1),
        'A'...'Z' => @intCast(cp - 'A' + 1),
        '@', ' ', '2' => 0x00,
        '[', '3' => 0x1b,
        '\\', '4' => 0x1c,
        ']', '5' => 0x1d,
        '^', '6' => 0x1e,
        '_', '7', '/' => 0x1f,
        '8', '?' => 0x7f,
        else => null,
    };
}

test {
    _ = @import("key_encode_test.zig");
}
