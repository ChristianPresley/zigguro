//! Kitty keyboard protocol tests, one group per enhancement flag with the
//! spec's examples, plus the per-screen flag stacks.

const std = @import("std");
const testing = std.testing;
const ke = @import("key_encode.zig");
const kitty = @import("kitty.zig");
const Terminal = @import("../term/Terminal.zig");

fn expectKey(want: []const u8, flags: u5, k: ke.KeyInput) !void {
    const st: ke.EncoderState = .{ .kitty_flags = flags };
    var buf: [64]u8 = undefined;
    const got = ke.encodeKey(&st, k, &buf);
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("flags {d} key {t}: want \"{f}\", got \"{f}\"\n", .{ flags, k.key, std.zig.fmtString(want), std.zig.fmtString(got) });
        return error.TestUnexpectedResult;
    }
}

const d = kitty.disambiguate;
const ev = kitty.event_types;
const alt_keys = kitty.alternate_keys;
const all = kitty.all_keys;
const txt = kitty.associated_text;

test "kitty flag 1: disambiguate" {
    try expectKey("a", d, .{ .key = .key_a, .text = "a" });
    try expectKey("A", d, .{ .key = .key_a, .mods = .{ .shift = true }, .text = "A" });
    try expectKey("\x1b[97;6u", d, .{ .key = .key_a, .mods = .{ .ctrl = true, .shift = true } });
    try expectKey("\x1b[97;5u", d, .{ .key = .key_a, .mods = .{ .ctrl = true } });
    try expectKey("\x1b[97;3u", d, .{ .key = .key_a, .mods = .{ .alt = true }, .text = "a" });
    try expectKey("\x1b[27u", d, .{ .key = .escape });
    try expectKey("\r", d, .{ .key = .enter });
    try expectKey("\x1b[13;2u", d, .{ .key = .enter, .mods = .{ .shift = true } });
    try expectKey("\x7f", d, .{ .key = .backspace });
    try expectKey("\x1b[127;5u", d, .{ .key = .backspace, .mods = .{ .ctrl = true } });
    try expectKey("\x1b[9;2u", d, .{ .key = .tab, .mods = .{ .shift = true } });
    try expectKey("\x1b[A", d, .{ .key = .up });
    try expectKey("\x1b[1;5A", d, .{ .key = .up, .mods = .{ .ctrl = true } });
    try expectKey("\x1bOP", d, .{ .key = .f1 });
    try expectKey("\x1b[13~", d, .{ .key = .f3 });
    try expectKey("\x1b[13;2~", d, .{ .key = .f3, .mods = .{ .shift = true } });
    try expectKey("\x1b[57376u", d, .{ .key = .f13 });
    try expectKey("1", d, .{ .key = .kp_1, .text = "1" });
    try expectKey("\x1b[57400u", d, .{ .key = .kp_1 });
    try expectKey("\x1b[57400;5u", d, .{ .key = .kp_1, .mods = .{ .ctrl = true }, .text = "1" });
    try expectKey("", d, .{ .key = .key_a, .action = .release, .text = "a" });
    try expectKey("", d, .{ .key = .left_shift, .mods = .{ .shift = true } });
    // AltGr text stays text.
    try expectKey("@", d, .{ .key = .key_q, .mods = .{ .ctrl = true, .alt = true, .alt_gr = true }, .text = "@" });
}

test "kitty flag 2: event types, releases only with the flag" {
    try expectKey("\x1b[97;5:3u", d | ev, .{ .key = .key_a, .mods = .{ .ctrl = true }, .action = .release });
    try expectKey("\x1b[97;5:2u", d | ev, .{ .key = .key_a, .mods = .{ .ctrl = true }, .action = .repeat });
    try expectKey("\x1b[97;5u", d, .{ .key = .key_a, .mods = .{ .ctrl = true }, .action = .repeat });
    try expectKey("\x1b[1;1:3A", d | ev, .{ .key = .up, .action = .release });
    try expectKey("\x1b[5;1:2~", d | ev, .{ .key = .page_up, .action = .repeat });
    // Text keys and Enter/Tab/Backspace report no release without flag 8.
    try expectKey("", d | ev, .{ .key = .key_a, .action = .release, .text = "a" });
    try expectKey("", d | ev, .{ .key = .enter, .action = .release });
    try expectKey("\x1b[27;1:3u", d | ev, .{ .key = .escape, .action = .release });
}

test "kitty flag 4: alternate keys" {
    try expectKey("\x1b[97:65;6u", d | alt_keys, .{ .key = .key_a, .mods = .{ .ctrl = true, .shift = true }, .shifted_cp = 'A' });
    // A Cyrillic layout: the key is U+0444, its US-layout key is `a`.
    try expectKey("\x1b[1092::97;5u", d | alt_keys, .{ .key = .key_a, .mods = .{ .ctrl = true }, .codepoint = 0x444, .base_layout_cp = 'a' });
    // Only keys already sent as escapes are affected.
    try expectKey("A", d | alt_keys, .{ .key = .key_a, .mods = .{ .shift = true }, .text = "A", .shifted_cp = 'A' });
}

test "kitty flag 8: all keys as escapes" {
    try expectKey("\x1b[97u", all, .{ .key = .key_a, .text = "a" });
    try expectKey("\x1b[97;2u", all, .{ .key = .key_a, .mods = .{ .shift = true }, .text = "A" });
    try expectKey("\x1b[13u", all, .{ .key = .enter });
    try expectKey("\x1b[9u", all, .{ .key = .tab });
    try expectKey("\x1b[127u", all, .{ .key = .backspace });
    try expectKey("\x1b[57441;2u", all, .{ .key = .left_shift });
    try expectKey("\x1b[57442;5u", all, .{ .key = .left_ctrl });
    try expectKey("\x1b[97;65u", all, .{ .key = .key_a, .mods = .{ .caps_lock = true }, .text = "A" });
    try expectKey("\x1b[57399u", all, .{ .key = .kp_0, .text = "0" });
    try expectKey("\x1b[57441;1:3u", all | ev, .{ .key = .left_shift, .action = .release, .mods = .{ .shift = true } });
    try expectKey("\x1b[13;1:3u", all | ev, .{ .key = .enter, .action = .release });
    try expectKey("\x1b[97;1:3u", all | ev, .{ .key = .key_a, .action = .release, .text = "a" });
    // Lock modifiers are not reported without flag 8.
    try expectKey("\x1b[97;5u", d, .{ .key = .key_a, .mods = .{ .ctrl = true, .caps_lock = true, .num_lock = true } });
}

test "kitty flag 16: associated text" {
    try expectKey("\x1b[97;;97u", all | txt, .{ .key = .key_a, .text = "a" });
    try expectKey("\x1b[97;2;65u", all | txt, .{ .key = .key_a, .mods = .{ .shift = true }, .text = "A" });
    try expectKey("\x1b[97:65;2;65u", all | txt | alt_keys, .{ .key = .key_a, .mods = .{ .shift = true }, .text = "A", .shifted_cp = 'A' });
    // Control characters are never associated text; releases carry none.
    try expectKey("\x1b[13u", all | txt, .{ .key = .enter, .text = "\r" });
    try expectKey("\x1b[97;1:3u", all | txt | ev, .{ .key = .key_a, .action = .release, .text = "a" });
    // Without flag 8 the flag does nothing.
    try expectKey("a", d | txt, .{ .key = .key_a, .text = "a" });
}

fn reply(t: *Terminal, q: []const u8) ![]const u8 {
    t.clearReplies();
    t.feed(q);
    return t.replies.items;
}

test "kitty stacks: per screen, CSI ? u, pop past the bottom, overflow, RIS" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 10, .rows = 4 });
    defer t.deinit();
    t.feed("\x1b[>1u");
    try testing.expectEqualStrings("\x1b[?1u", try reply(&t, "\x1b[?u"));
    t.feed("\x1b[?1049h");
    try testing.expectEqualStrings("\x1b[?0u", try reply(&t, "\x1b[?u"));
    t.feed("\x1b[>11u");
    try testing.expectEqual(@as(u5, 11), t.encoderState().kitty_flags);
    t.feed("\x1b[?1049l");
    try testing.expectEqualStrings("\x1b[?1u", try reply(&t, "\x1b[?u"));
    t.feed("\x1b[>2u\x1b[>3u\x1b[<10u");
    try testing.expectEqualStrings("\x1b[?0u", try reply(&t, "\x1b[?u"));
    for (0..20) |i| t.feed(if (i % 2 == 0) "\x1b[>1u" else "\x1b[>2u");
    try testing.expectEqual(@as(usize, 16), t.primary.kitty_kb.len);
    try testing.expectEqualStrings("\x1b[?2u", try reply(&t, "\x1b[?u"));
    t.feed("\x1b[?1049h\x1b[>4u\x1bc");
    try testing.expectEqual(@as(usize, 0), t.primary.kitty_kb.len);
    try testing.expectEqual(@as(usize, 0), t.alternate.kitty_kb.len);
}

test "XTMODKEYS sets and resets modifyOtherKeys" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 10, .rows = 4 });
    defer t.deinit();
    t.feed("\x1b[>4;2m");
    try testing.expectEqual(@as(u2, 2), t.encoderState().modify_other_keys);
    t.feed("\x1b[>4m");
    try testing.expectEqual(@as(u2, 0), t.encoderState().modify_other_keys);
    t.feed("\x1b[>4;1m\x1bc");
    try testing.expectEqual(@as(u2, 0), t.encoderState().modify_other_keys);
}

test "encoderState mirrors the modes" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 10, .rows = 4 });
    defer t.deinit();
    t.feed("\x1b[?1h\x1b=\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[?1004h\x1b[?67h\x1b[20h");
    const st = t.encoderState();
    try testing.expect(st.decckm and st.deckpam and st.bracketed_paste and st.focus_events and st.backarrow_bs and st.linefeed);
    try testing.expectEqual(.button, st.mouse);
    try testing.expectEqual(.sgr, st.mouse_enc);
}
