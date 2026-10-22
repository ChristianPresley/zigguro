//! Win32 keyboard translation (the first part of E01.F02.S02.T01): the
//! set-1 scancode in a key message's lParam to a physical `Key`, virtual
//! keys to X11 keysyms for keys without text, and modifier state. Set-1
//! scancodes equal evdev codes for non-extended keys, so the evdev table
//! does the bulk; extended (E0) keys are listed here. Pure functions:
//! they build and test on every OS.

const std = @import("std");
const keys = @import("../api/keys.zig");
const evdevToKey = @import("../xkb/evdev.zig").evdevToKey;
const VK = @import("msgs.zig").VK;

/// The scancode (bits 16..23) and extended flag (bit 24) of a key
/// message's lParam, as `MapVirtualKey` reports them: E0 keys set bit 8.
pub fn scancodeOf(lparam: isize) u16 {
    const l: usize = @bitCast(lparam);
    const sc: u16 = @intCast((l >> 16) & 0xff);
    return if ((l >> 24) & 1 != 0) sc | 0x100 else sc;
}

/// Whether the key was already down (auto-repeat), bit 30 of lParam.
pub fn isRepeat(lparam: isize) bool {
    const l: usize = @bitCast(lparam);
    return (l >> 30) & 1 != 0;
}

/// The evdev code of an E0-prefixed scancode.
fn extendedEvdev(sc: u8) ?u16 {
    return switch (sc) {
        0x1c => 96, // KP Enter
        0x1d => 97, // Right Ctrl
        0x35 => 98, // KP /
        0x37 => 99, // Print Screen
        0x38 => 100, // Right Alt
        0x45 => 69, // Num Lock (reported extended)
        0x47 => 102, // Home
        0x48 => 103, // Up
        0x49 => 104, // Page Up
        0x4b => 105, // Left
        0x4d => 106, // Right
        0x4f => 107, // End
        0x50 => 108, // Down
        0x51 => 109, // Page Down
        0x52 => 110, // Insert
        0x53 => 111, // Delete
        0x5b => 125, // Left Windows
        0x5c => 126, // Right Windows
        0x5d => 127, // Menu
        else => null,
    };
}

/// The physical key for `scancode` (from `scancodeOf`) and `vk`.
pub fn keyOf(scancode: u16, vk: u16) keys.Key {
    // Pause arrives as a non-extended 0x45, the same scancode as Num Lock.
    if (vk == VK.PAUSE) return evdevToKey(119);
    const sc: u8 = @truncate(scancode);
    if (scancode & 0x100 != 0) return if (extendedEvdev(sc)) |e| evdevToKey(e) else .unknown;
    return evdevToKey(sc);
}

/// The keysym for a key that produced `codepoint` (0 for none), else from
/// its virtual key.
pub fn keysymOf(vk: u16, codepoint: u21) u32 {
    if (codepoint != 0) return if (codepoint < 0x100) codepoint else 0x0100_0000 + @as(u32, codepoint);
    return switch (vk) {
        VK.BACK => 0xff08,
        VK.TAB => 0xff09,
        VK.RETURN => 0xff0d,
        VK.PAUSE => 0xff13,
        VK.ESCAPE => 0xff1b,
        VK.HOME => 0xff50,
        VK.LEFT => 0xff51,
        VK.UP => 0xff52,
        VK.RIGHT => 0xff53,
        VK.DOWN => 0xff54,
        VK.PRIOR => 0xff55,
        VK.NEXT => 0xff56,
        VK.END => 0xff57,
        VK.INSERT => 0xff63,
        VK.DELETE => 0xffff,
        VK.SHIFT => 0xffe1,
        VK.CONTROL => 0xffe3,
        VK.MENU => 0xffe9,
        VK.CAPITAL => 0xffe5,
        VK.LWIN, VK.RWIN => 0xffeb,
        VK.NUMLOCK => 0xff7f,
        VK.F1...VK.F24 => 0xffbe + @as(u32, vk - VK.F1),
        else => 0,
    };
}

/// `Mods` from a key-state reader: `down(vk)` says whether the key is
/// held, `toggled(vk)` whether a lock key is on.
pub fn modsFrom(ctx: anytype, comptime down: fn (@TypeOf(ctx), u16) bool, comptime toggled: fn (@TypeOf(ctx), u16) bool) keys.Mods {
    return .{
        .shift = down(ctx, VK.SHIFT),
        .ctrl = down(ctx, VK.CONTROL),
        .alt = down(ctx, VK.MENU),
        .super = down(ctx, VK.LWIN) or down(ctx, VK.RWIN),
        .alt_gr = down(ctx, VK.RMENU) and down(ctx, VK.CONTROL),
        .caps_lock = toggled(ctx, VK.CAPITAL),
        .num_lock = toggled(ctx, VK.NUMLOCK),
    };
}

test "scancodeOf and isRepeat read lParam" {
    // 'A' down: scancode 0x1E, repeat count 1.
    try std.testing.expectEqual(@as(u16, 0x1e), scancodeOf(0x001E0001));
    // Up arrow: E0 48 with the extended bit.
    try std.testing.expectEqual(@as(u16, 0x148), scancodeOf(0x01480001));
    try std.testing.expect(isRepeat(0x401E0001));
    try std.testing.expect(!isRepeat(0x001E0001));
    try std.testing.expectEqual(@as(u16, 0x11d), scancodeOf(@bitCast(@as(usize, 0xC11D0001))));
}

test "keyOf maps base and extended scancodes" {
    try std.testing.expectEqual(keys.Key.key_a, keyOf(0x1e, 'A'));
    try std.testing.expectEqual(evdevToKey(103), keyOf(0x148, VK.UP));
    try std.testing.expectEqual(evdevToKey(97), keyOf(0x11d, VK.CONTROL));
    try std.testing.expectEqual(evdevToKey(69), keyOf(0x145, VK.NUMLOCK));
    try std.testing.expectEqual(evdevToKey(119), keyOf(0x45, VK.PAUSE));
    try std.testing.expectEqual(keys.Key.unknown, keyOf(0x1ff, 0));
}

test "keysymOf" {
    try std.testing.expectEqual(@as(u32, 'a'), keysymOf('A', 'a'));
    try std.testing.expectEqual(@as(u32, 0x0100_20ac), keysymOf(0, 0x20ac));
    try std.testing.expectEqual(@as(u32, 0xff0d), keysymOf(VK.RETURN, 0));
    try std.testing.expectEqual(@as(u32, 0xffbe + 11), keysymOf(VK.F1 + 11, 0));
    try std.testing.expectEqual(@as(u32, 0), keysymOf(0xff, 0));
}

test "modsFrom" {
    const State = struct {
        held: []const u16,
        fn down(s: @This(), vk: u16) bool {
            return std.mem.indexOfScalar(u16, s.held, vk) != null;
        }
        fn toggled(_: @This(), vk: u16) bool {
            return vk == VK.CAPITAL;
        }
    };
    const m = modsFrom(State{ .held = &.{ VK.SHIFT, VK.CONTROL, VK.RMENU } }, State.down, State.toggled);
    try std.testing.expect(m.shift and m.ctrl and m.alt_gr and m.caps_lock and !m.num_lock and !m.super);
}
