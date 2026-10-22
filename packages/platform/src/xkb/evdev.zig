//! Linux evdev key codes (`KEY_*` from input-event-codes.h) to `Key`. For
//! XKB keymaps from the `evdev` keycodes, the XKB keycode is evdev + 8.

const std = @import("std");
const Key = @import("../api/keys.zig").Key;

/// The physical key for evdev code `evdev`, or `.unknown`.
pub fn evdevToKey(evdev: u16) Key {
    return if (evdev < table.len) table[evdev] else switch (evdev) {
        0x1d0 => .fn_key, // KEY_FN
        else => .unknown,
    };
}

const table = blk: {
    var t = [_]Key{.unknown} ** 256;
    const pairs = [_]struct { u16, Key }{
        .{ 1, .escape },               .{ 2, .digit_1 },             .{ 3, .digit_2 },             .{ 4, .digit_3 },
        .{ 5, .digit_4 },              .{ 6, .digit_5 },             .{ 7, .digit_6 },             .{ 8, .digit_7 },
        .{ 9, .digit_8 },              .{ 10, .digit_9 },            .{ 11, .digit_0 },            .{ 12, .minus },
        .{ 13, .equal },               .{ 14, .backspace },          .{ 15, .tab },                .{ 16, .key_q },
        .{ 17, .key_w },               .{ 18, .key_e },              .{ 19, .key_r },              .{ 20, .key_t },
        .{ 21, .key_y },               .{ 22, .key_u },              .{ 23, .key_i },              .{ 24, .key_o },
        .{ 25, .key_p },               .{ 26, .bracket_left },       .{ 27, .bracket_right },      .{ 28, .enter },
        .{ 29, .control_left },        .{ 30, .key_a },              .{ 31, .key_s },              .{ 32, .key_d },
        .{ 33, .key_f },               .{ 34, .key_g },              .{ 35, .key_h },              .{ 36, .key_j },
        .{ 37, .key_k },               .{ 38, .key_l },              .{ 39, .semicolon },          .{ 40, .quote },
        .{ 41, .backquote },           .{ 42, .shift_left },         .{ 43, .backslash },          .{ 44, .key_z },
        .{ 45, .key_x },               .{ 46, .key_c },              .{ 47, .key_v },              .{ 48, .key_b },
        .{ 49, .key_n },               .{ 50, .key_m },              .{ 51, .comma },              .{ 52, .period },
        .{ 53, .slash },               .{ 54, .shift_right },        .{ 55, .numpad_multiply },    .{ 56, .alt_left },
        .{ 57, .space },               .{ 58, .caps_lock },          .{ 59, .f1 },                 .{ 60, .f2 },
        .{ 61, .f3 },                  .{ 62, .f4 },                 .{ 63, .f5 },                 .{ 64, .f6 },
        .{ 65, .f7 },                  .{ 66, .f8 },                 .{ 67, .f9 },                 .{ 68, .f10 },
        .{ 69, .num_lock },            .{ 70, .scroll_lock },        .{ 71, .numpad7 },            .{ 72, .numpad8 },
        .{ 73, .numpad9 },             .{ 74, .numpad_subtract },    .{ 75, .numpad4 },            .{ 76, .numpad5 },
        .{ 77, .numpad6 },             .{ 78, .numpad_add },         .{ 79, .numpad1 },            .{ 80, .numpad2 },
        .{ 81, .numpad3 },             .{ 82, .numpad0 },            .{ 83, .numpad_decimal },     .{ 85, .lang5 },
        .{ 86, .intl_backslash },      .{ 87, .f11 },                .{ 88, .f12 },                .{ 89, .intl_ro },
        .{ 90, .lang3 },               .{ 91, .lang4 },              .{ 92, .convert },            .{ 93, .kana_mode },
        .{ 94, .non_convert },         .{ 95, .numpad_comma },       .{ 96, .numpad_enter },       .{ 97, .control_right },
        .{ 98, .numpad_divide },       .{ 99, .print_screen },       .{ 100, .alt_right },         .{ 102, .home },
        .{ 103, .arrow_up },           .{ 104, .page_up },           .{ 105, .arrow_left },        .{ 106, .arrow_right },
        .{ 107, .end },                .{ 108, .arrow_down },        .{ 109, .page_down },         .{ 110, .insert },
        .{ 111, .delete },             .{ 113, .audio_volume_mute }, .{ 114, .audio_volume_down }, .{ 115, .audio_volume_up },
        .{ 116, .power },              .{ 117, .numpad_equal },      .{ 119, .pause },             .{ 121, .numpad_comma },
        .{ 122, .lang1 },              .{ 123, .lang2 },             .{ 124, .intl_yen },          .{ 125, .meta_left },
        .{ 126, .meta_right },         .{ 127, .context_menu },      .{ 128, .browser_stop },      .{ 129, .again },
        .{ 131, .undo },               .{ 133, .copy },              .{ 134, .open },              .{ 135, .paste },
        .{ 136, .find },               .{ 137, .cut },               .{ 138, .help },              .{ 139, .context_menu },
        .{ 140, .launch_app2 },        .{ 142, .sleep },             .{ 143, .wake_up },           .{ 155, .launch_mail },
        .{ 156, .browser_favorites },  .{ 157, .launch_app1 },       .{ 158, .browser_back },      .{ 159, .browser_forward },
        .{ 161, .eject },              .{ 163, .media_track_next },  .{ 164, .media_play_pause },  .{ 165, .media_track_previous },
        .{ 166, .media_stop },         .{ 172, .browser_home },      .{ 173, .browser_refresh },   .{ 179, .numpad_paren_left },
        .{ 180, .numpad_paren_right }, .{ 183, .f13 },               .{ 184, .f14 },               .{ 185, .f15 },
        .{ 186, .f16 },                .{ 187, .f17 },               .{ 188, .f18 },               .{ 189, .f19 },
        .{ 190, .f20 },                .{ 191, .f21 },               .{ 192, .f22 },               .{ 193, .f23 },
        .{ 194, .f24 },                .{ 217, .browser_search },    .{ 226, .media_select },
    };
    for (pairs) |p| t[p[0]] = p[1];
    break :blk t;
};

const testing = std.testing;

test "evdevToKey maps the main block, keypad and media keys" {
    try testing.expectEqual(Key.escape, evdevToKey(1));
    try testing.expectEqual(Key.key_a, evdevToKey(30));
    try testing.expectEqual(Key.numpad7, evdevToKey(71));
    try testing.expectEqual(Key.meta_left, evdevToKey(125));
    try testing.expectEqual(Key.media_play_pause, evdevToKey(164));
    try testing.expectEqual(Key.fn_key, evdevToKey(0x1d0));
    try testing.expectEqual(Key.unknown, evdevToKey(0));
    try testing.expectEqual(Key.unknown, evdevToKey(0x2ff));
}
