//! Core-protocol keyboard translation for X11: the keycode → keysym table
//! from GetKeyboardMapping, the four-group rule of the core protocol for
//! Shift and Caps Lock, and modifier state bits. The full XKB keymap path
//! is E01.F05.S02.T02; this is what windows get until then.

const std = @import("std");
const keys = @import("../api/keys.zig");
const keysyms = @import("../xkb/keysyms.zig");
const evdevToKey = @import("../xkb/evdev.zig").evdevToKey;

/// Core modifier state bits (the `state` field of input events).
pub const State = struct {
    /// Shift.
    pub const shift: u16 = 1 << 0;
    /// Lock (Caps Lock).
    pub const lock: u16 = 1 << 1;
    /// Control.
    pub const control: u16 = 1 << 2;
    /// Mod1 (Alt).
    pub const mod1: u16 = 1 << 3;
    /// Mod2 (Num Lock).
    pub const mod2: u16 = 1 << 4;
    /// Mod4 (Super).
    pub const mod4: u16 = 1 << 6;
    /// Mod5 (ISO Level3 Shift, AltGr).
    pub const mod5: u16 = 1 << 7;
};

/// `Mods` from a core state mask.
pub fn modsFromState(state: u16) keys.Mods {
    return .{
        .shift = state & State.shift != 0,
        .ctrl = state & State.control != 0,
        .alt = state & State.mod1 != 0,
        .super = state & State.mod4 != 0,
        .alt_gr = state & State.mod5 != 0,
        .caps_lock = state & State.lock != 0,
        .num_lock = state & State.mod2 != 0,
    };
}

/// The keycode → keysym table.
pub const Keymap = struct {
    min_keycode: u8 = 8,
    per_keycode: u8 = 0,
    /// `per_keycode` keysyms for each keycode from `min_keycode`.
    syms: []u32 = &.{},

    /// Builds the table from a GetKeyboardMapping reply's keysym bytes.
    pub fn init(gpa: std.mem.Allocator, min_keycode: u8, per_keycode: u8, bytes: []const u8) !Keymap {
        const syms = try gpa.alloc(u32, bytes.len / 4);
        for (syms, 0..) |*s, i| s.* = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
        return .{ .min_keycode = min_keycode, .per_keycode = per_keycode, .syms = syms };
    }

    /// Frees the table.
    pub fn deinit(m: *Keymap, gpa: std.mem.Allocator) void {
        gpa.free(m.syms);
        m.* = .{};
    }

    /// The keysym for `keycode` under `state`, following the core
    /// protocol's rules for group 1: Shift selects the second keysym,
    /// Lock upper-cases letters. 0 when unmapped.
    pub fn keysym(m: *const Keymap, keycode: u8, state: u16) u32 {
        if (m.per_keycode == 0 or keycode < m.min_keycode) return 0;
        const at = @as(usize, keycode - m.min_keycode) * m.per_keycode;
        if (at + m.per_keycode > m.syms.len) return 0;
        const row = m.syms[at..][0..m.per_keycode];
        const lower = row[0];
        const upper = if (m.per_keycode > 1 and row[1] != 0) row[1] else upperOf(lower);
        const shifted = state & State.shift != 0;
        const caps = state & State.lock != 0 and isLetter(lower);
        return if (shifted != caps) upper else lower;
    }

    /// The physical key and the event fields for `keycode` under `state`.
    pub fn resolve(m: *const Keymap, keycode: u8, state: u16) struct { key: keys.Key, keysym: u32, codepoint: u21 } {
        const ks = m.keysym(keycode, state);
        const ctrl = state & State.control != 0;
        const cp = keysyms.keysymToCodepoint(ks) orelse 0;
        return .{
            .key = if (keycode >= 8) evdevToKey(keycode - 8) else .unknown,
            .keysym = ks,
            // Control chords produce no text.
            .codepoint = if (ctrl or cp < 0x20 or cp == 0x7f) 0 else cp,
        };
    }
};

fn isLetter(ks: u32) bool {
    return (ks >= 'a' and ks <= 'z') or (ks >= 'A' and ks <= 'Z');
}

fn upperOf(ks: u32) u32 {
    return if (ks >= 'a' and ks <= 'z') ks - 32 else ks;
}

test "keysym follows Shift and Lock" {
    // keycode 38 = 'a' / 'A', keycode 10 = '1' / '!'.
    var syms = [_]u32{0} ** (40 * 2);
    syms[(38 - 8) * 2] = 'a';
    syms[(38 - 8) * 2 + 1] = 'A';
    syms[(10 - 8) * 2] = '1';
    syms[(10 - 8) * 2 + 1] = '!';
    const m: Keymap = .{ .min_keycode = 8, .per_keycode = 2, .syms = &syms };
    try std.testing.expectEqual(@as(u32, 'a'), m.keysym(38, 0));
    try std.testing.expectEqual(@as(u32, 'A'), m.keysym(38, State.shift));
    try std.testing.expectEqual(@as(u32, 'A'), m.keysym(38, State.lock));
    try std.testing.expectEqual(@as(u32, 'a'), m.keysym(38, State.lock | State.shift));
    try std.testing.expectEqual(@as(u32, '1'), m.keysym(10, State.lock));
    try std.testing.expectEqual(@as(u32, '!'), m.keysym(10, State.shift));
    try std.testing.expectEqual(@as(u32, 0), m.keysym(5, 0));
    try std.testing.expectEqual(@as(u32, 0), m.keysym(200, 0));
    const r = m.resolve(38, State.shift);
    try std.testing.expectEqual(keys.Key.key_a, r.key);
    try std.testing.expectEqual(@as(u21, 'A'), r.codepoint);
    try std.testing.expectEqual(@as(u21, 0), m.resolve(38, State.control).codepoint);
}

test "modsFromState" {
    const m = modsFromState(State.shift | State.control | State.mod4);
    try std.testing.expect(m.shift and m.ctrl and m.super and !m.alt);
}
