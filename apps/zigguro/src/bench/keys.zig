//! The keys `bench-latency` types and how each one is spelled for the
//! injectors: the platform key, the evdev code (equal to the PC set-1
//! scancode for these keys, used by uinput and `SendInput`), the keysym
//! and the text it produces.

const std = @import("std");
const zg_platform = @import("zg_platform");

const Key = zg_platform.keys.Key;

/// Backspace in the key sequence.
pub const backspace: u8 = 0x08;

/// One key.
pub const BenchKey = struct {
    key: Key,
    evdev: u16,
    keysym: u32,
    /// The UTF-8 text the key types (empty for Backspace).
    text: []const u8,
};

const letters = "abcdefghijklmnopqrstuvwxyz";
/// evdev codes of a..z.
const letter_codes = [26]u16{ 30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44 };

/// The key for `ch` (a..z, space or `backspace`).
pub fn keyFor(ch: u8) BenchKey {
    return switch (ch) {
        'a'...'z' => .{
            .key = @enumFromInt(@intFromEnum(Key.key_a) + (ch - 'a')),
            .evdev = letter_codes[ch - 'a'],
            .keysym = ch,
            .text = letters[ch - 'a' ..][0..1],
        },
        ' ' => .{ .key = .space, .evdev = 57, .keysym = ' ', .text = " " },
        else => .{ .key = .backspace, .evdev = 14, .keysym = 0xff08, .text = "" },
    };
}

/// Keys per cycle of the sequence: 64 typed, then 8 Backspaces.
pub const cycle = 72;

/// The `i`th key of the sequence: letters a..z with a space every 8th
/// key, and 8 Backspaces after every 64 keys so the line stays short.
pub fn sequence(i: u32) u8 {
    const k = i % cycle;
    if (k >= 64) return backspace;
    if (k % 8 == 7) return ' ';
    return letters[i % 26];
}

test "bench keys: sequence and table" {
    try std.testing.expectEqual(@as(u8, 'a'), sequence(0));
    try std.testing.expectEqual(@as(u8, ' '), sequence(7));
    try std.testing.expectEqual(backspace, sequence(64));
    try std.testing.expectEqual(backspace, sequence(71));
    try std.testing.expect(sequence(72) != backspace);
    const q = keyFor('q');
    try std.testing.expectEqual(Key.key_q, q.key);
    try std.testing.expectEqual(@as(u16, 16), q.evdev);
    try std.testing.expectEqualStrings("q", q.text);
    try std.testing.expectEqual(Key.backspace, keyFor(backspace).key);
    try std.testing.expectEqual(Key.space, keyFor(' ').key);
    // Net effect of a cycle: 56 letters + 8 spaces - 8 = 56 characters.
    var net: i32 = 0;
    for (0..cycle) |i| net += if (sequence(@intCast(i)) == backspace) -1 else 1;
    try std.testing.expectEqual(@as(i32, 56), net);
}
