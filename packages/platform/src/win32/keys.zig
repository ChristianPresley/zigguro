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

/// The repeat count of a key message (bits 0..15), at least 1 and capped
/// at 32 events.
pub fn repeatCount(lparam: isize) u8 {
    const l: usize = @bitCast(lparam);
    return @intCast(std.math.clamp(l & 0xffff, 1, 32));
}

/// `KEY_EVENT_RECORD.dwControlKeyState` bits.
pub const CtrlState = struct {
    /// RIGHT_ALT_PRESSED.
    pub const RIGHT_ALT: u16 = 0x0001;
    /// LEFT_ALT_PRESSED.
    pub const LEFT_ALT: u16 = 0x0002;
    /// RIGHT_CTRL_PRESSED.
    pub const RIGHT_CTRL: u16 = 0x0004;
    /// LEFT_CTRL_PRESSED.
    pub const LEFT_CTRL: u16 = 0x0008;
    /// SHIFT_PRESSED.
    pub const SHIFT: u16 = 0x0010;
    /// NUMLOCK_ON.
    pub const NUMLOCK: u16 = 0x0020;
    /// SCROLLLOCK_ON.
    pub const SCROLLLOCK: u16 = 0x0040;
    /// CAPSLOCK_ON.
    pub const CAPSLOCK: u16 = 0x0080;
    /// ENHANCED_KEY.
    pub const ENHANCED: u16 = 0x0100;
};

/// The console control-key state for E06's win32-input-mode, from the
/// same key-state reader as `modsFrom`; `extended` is lParam bit 24.
pub fn ctrlStateFrom(ctx: anytype, comptime down: fn (@TypeOf(ctx), u16) bool, comptime toggled: fn (@TypeOf(ctx), u16) bool, extended: bool) u16 {
    var s: u16 = 0;
    if (down(ctx, VK.RMENU)) s |= CtrlState.RIGHT_ALT;
    if (down(ctx, VK.LMENU)) s |= CtrlState.LEFT_ALT;
    if (down(ctx, VK.RCONTROL)) s |= CtrlState.RIGHT_CTRL;
    if (down(ctx, VK.LCONTROL)) s |= CtrlState.LEFT_CTRL;
    if (down(ctx, VK.SHIFT)) s |= CtrlState.SHIFT;
    if (toggled(ctx, VK.NUMLOCK)) s |= CtrlState.NUMLOCK;
    if (toggled(ctx, VK.SCROLL)) s |= CtrlState.SCROLLLOCK;
    if (toggled(ctx, VK.CAPITAL)) s |= CtrlState.CAPSLOCK;
    if (extended) s |= CtrlState.ENHANCED;
    return s;
}

/// A key message as the AltGr check sees it.
pub const KeyMsg = struct { scancode: u16, time: u32 };

/// Whether a Left Ctrl message is the one Windows synthesizes for AltGr:
/// non-extended 0x1D immediately followed by Right Alt (E0 38) with the
/// same message time.
pub fn isFakeAltGrCtrl(cur: KeyMsg, next: ?KeyMsg) bool {
    if (cur.scancode != 0x1d) return false;
    const n = next orelse return false;
    return n.scancode == 0x138 and n.time == cur.time;
}

/// Keys held down, so focus loss can release them. Fixed size: no
/// allocation per message.
pub const DownKeys = struct {
    /// A held key.
    pub const Held = struct { scancode: u16, vk: u16 };

    items: [32]Held = undefined,
    len: u8 = 0,

    /// Records a press (once per key).
    pub fn press(d: *DownKeys, h: Held) void {
        for (d.items[0..d.len]) |x| if (x.scancode == h.scancode) return;
        if (d.len == d.items.len) return;
        d.items[d.len] = h;
        d.len += 1;
    }

    /// Forgets a key.
    pub fn release(d: *DownKeys, scancode: u16) void {
        for (d.items[0..d.len], 0..) |x, i| if (x.scancode == scancode) {
            d.items[i] = d.items[d.len - 1];
            d.len -= 1;
            return;
        };
    }

    /// Takes every held key, leaving none.
    pub fn drain(d: *DownKeys) []const Held {
        const n = d.len;
        d.len = 0;
        return d.items[0..n];
    }
};

/// Whether a `WM_SYSKEYDOWN` goes to `DefWindowProcW` for the system:
/// Alt alone and Alt+Space (the window menu), and Alt+F4. F10 is
/// swallowed: we have no menu bar for it to activate.
pub fn systemKey(vk: u16, alt: bool) bool {
    if (vk == VK.F10) return false;
    return vk == VK.MENU or vk == VK.LMENU or vk == VK.RMENU or (alt and (vk == VK.SPACE or vk == VK.F1 + 3));
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

test "ctrl_state bits from synthetic GetKeyState snapshots" {
    const Snap = struct {
        down: []const u16,
        on: []const u16,
        fn isDown(x: @This(), vk: u16) bool {
            return std.mem.indexOfScalar(u16, x.down, vk) != null;
        }
        fn isOn(x: @This(), vk: u16) bool {
            return std.mem.indexOfScalar(u16, x.on, vk) != null;
        }
    };
    // AltGr = LEFT_CTRL | RIGHT_ALT.
    const altgr: Snap = .{ .down = &.{ VK.CONTROL, VK.LCONTROL, VK.MENU, VK.RMENU }, .on = &.{} };
    try std.testing.expectEqual(CtrlState.LEFT_CTRL | CtrlState.RIGHT_ALT, ctrlStateFrom(altgr, Snap.isDown, Snap.isOn, false));
    try std.testing.expect(modsFrom(altgr, Snap.isDown, Snap.isOn).alt_gr);
    // Numpad Enter is enhanced; locks are reported when toggled.
    const locks: Snap = .{ .down = &.{ VK.SHIFT, VK.RCONTROL }, .on = &.{ VK.NUMLOCK, VK.CAPITAL, VK.SCROLL } };
    try std.testing.expectEqual(CtrlState.SHIFT | CtrlState.RIGHT_CTRL | CtrlState.NUMLOCK | CtrlState.CAPSLOCK | CtrlState.SCROLLLOCK | CtrlState.ENHANCED, ctrlStateFrom(locks, Snap.isDown, Snap.isOn, true));
}

test "AltGr fake-ctrl suppression" {
    try std.testing.expect(isFakeAltGrCtrl(.{ .scancode = 0x1d, .time = 500 }, .{ .scancode = 0x138, .time = 500 }));
    // A real Left Ctrl: later Right Alt, or nothing queued.
    try std.testing.expect(!isFakeAltGrCtrl(.{ .scancode = 0x1d, .time = 500 }, .{ .scancode = 0x138, .time = 530 }));
    try std.testing.expect(!isFakeAltGrCtrl(.{ .scancode = 0x1d, .time = 500 }, null));
    try std.testing.expect(!isFakeAltGrCtrl(.{ .scancode = 0x11d, .time = 500 }, .{ .scancode = 0x138, .time = 500 }));
}

test "repeat counts, held keys and system keys" {
    try std.testing.expectEqual(@as(u8, 1), repeatCount(0x001E0000));
    try std.testing.expectEqual(@as(u8, 3), repeatCount(0x401E0003));
    try std.testing.expectEqual(@as(u8, 32), repeatCount(0x401E00FF));
    var d: DownKeys = .{};
    d.press(.{ .scancode = 0x1e, .vk = 'A' });
    d.press(.{ .scancode = 0x1e, .vk = 'A' });
    d.press(.{ .scancode = 0x2a, .vk = VK.SHIFT });
    d.release(0x1e);
    const held = d.drain();
    try std.testing.expectEqual(@as(usize, 1), held.len);
    try std.testing.expectEqual(@as(u16, 0x2a), held[0].scancode);
    try std.testing.expectEqual(@as(usize, 0), d.drain().len);
    try std.testing.expect(systemKey(VK.MENU, true));
    try std.testing.expect(systemKey(VK.SPACE, true));
    try std.testing.expect(systemKey(VK.F1 + 3, true));
    try std.testing.expect(!systemKey(VK.F10, false));
    try std.testing.expect(!systemKey('X', true));
}
