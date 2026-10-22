//! Physical keys. A `Key` names a key by its position, as the W3C UI Events
//! `code` value does, independent of the active layout. Values 0x0004-0x00e7
//! are the USB HID usage on the Keyboard/Keypad page (0x07); keys outside
//! that page (media, browser and launch keys from the Consumer page 0x0c, and
//! `Fn`) are numbered from 0x0100.

const std = @import("std");

/// A physical key. The integer value is the HID usage for page-0x07 keys.
/// The enum is non-exhaustive so a backend can carry an unnamed HID usage
/// through unchanged; such a value has `name()` "Unidentified".
pub const Key = enum(u16) {
    /// No key, or a key the backend could not map.
    unknown = 0,
    key_a = 0x0004,
    key_b = 0x0005,
    key_c = 0x0006,
    key_d = 0x0007,
    key_e = 0x0008,
    key_f = 0x0009,
    key_g = 0x000a,
    key_h = 0x000b,
    key_i = 0x000c,
    key_j = 0x000d,
    key_k = 0x000e,
    key_l = 0x000f,
    key_m = 0x0010,
    key_n = 0x0011,
    key_o = 0x0012,
    key_p = 0x0013,
    key_q = 0x0014,
    key_r = 0x0015,
    key_s = 0x0016,
    key_t = 0x0017,
    key_u = 0x0018,
    key_v = 0x0019,
    key_w = 0x001a,
    key_x = 0x001b,
    key_y = 0x001c,
    key_z = 0x001d,
    digit_1 = 0x001e,
    digit_2 = 0x001f,
    digit_3 = 0x0020,
    digit_4 = 0x0021,
    digit_5 = 0x0022,
    digit_6 = 0x0023,
    digit_7 = 0x0024,
    digit_8 = 0x0025,
    digit_9 = 0x0026,
    digit_0 = 0x0027,
    enter = 0x0028,
    escape = 0x0029,
    backspace = 0x002a,
    tab = 0x002b,
    space = 0x002c,
    minus = 0x002d,
    equal = 0x002e,
    bracket_left = 0x002f,
    bracket_right = 0x0030,
    backslash = 0x0031,
    semicolon = 0x0033,
    quote = 0x0034,
    backquote = 0x0035,
    comma = 0x0036,
    period = 0x0037,
    slash = 0x0038,
    caps_lock = 0x0039,
    f1 = 0x003a,
    f2 = 0x003b,
    f3 = 0x003c,
    f4 = 0x003d,
    f5 = 0x003e,
    f6 = 0x003f,
    f7 = 0x0040,
    f8 = 0x0041,
    f9 = 0x0042,
    f10 = 0x0043,
    f11 = 0x0044,
    f12 = 0x0045,
    print_screen = 0x0046,
    scroll_lock = 0x0047,
    pause = 0x0048,
    insert = 0x0049,
    home = 0x004a,
    page_up = 0x004b,
    delete = 0x004c,
    end = 0x004d,
    page_down = 0x004e,
    arrow_right = 0x004f,
    arrow_left = 0x0050,
    arrow_down = 0x0051,
    arrow_up = 0x0052,
    num_lock = 0x0053,
    numpad_divide = 0x0054,
    numpad_multiply = 0x0055,
    numpad_subtract = 0x0056,
    numpad_add = 0x0057,
    numpad_enter = 0x0058,
    numpad1 = 0x0059,
    numpad2 = 0x005a,
    numpad3 = 0x005b,
    numpad4 = 0x005c,
    numpad5 = 0x005d,
    numpad6 = 0x005e,
    numpad7 = 0x005f,
    numpad8 = 0x0060,
    numpad9 = 0x0061,
    numpad0 = 0x0062,
    numpad_decimal = 0x0063,
    intl_backslash = 0x0064,
    context_menu = 0x0065,
    power = 0x0066,
    numpad_equal = 0x0067,
    f13 = 0x0068,
    f14 = 0x0069,
    f15 = 0x006a,
    f16 = 0x006b,
    f17 = 0x006c,
    f18 = 0x006d,
    f19 = 0x006e,
    f20 = 0x006f,
    f21 = 0x0070,
    f22 = 0x0071,
    f23 = 0x0072,
    f24 = 0x0073,
    open = 0x0074,
    help = 0x0075,
    select_key = 0x0077,
    again = 0x0079,
    undo = 0x007a,
    cut = 0x007b,
    copy = 0x007c,
    paste = 0x007d,
    find = 0x007e,
    audio_volume_mute = 0x007f,
    audio_volume_up = 0x0080,
    audio_volume_down = 0x0081,
    numpad_comma = 0x0085,
    intl_ro = 0x0087,
    kana_mode = 0x0088,
    intl_yen = 0x0089,
    convert = 0x008a,
    non_convert = 0x008b,
    lang1 = 0x0090,
    lang2 = 0x0091,
    lang3 = 0x0092,
    lang4 = 0x0093,
    lang5 = 0x0094,
    numpad_paren_left = 0x00b6,
    numpad_paren_right = 0x00b7,
    numpad_backspace = 0x00bb,
    numpad_memory_store = 0x00d0,
    numpad_memory_recall = 0x00d1,
    numpad_memory_clear = 0x00d2,
    numpad_memory_add = 0x00d3,
    numpad_memory_subtract = 0x00d4,
    numpad_clear = 0x00d8,
    numpad_clear_entry = 0x00d9,
    control_left = 0x00e0,
    shift_left = 0x00e1,
    alt_left = 0x00e2,
    meta_left = 0x00e3,
    control_right = 0x00e4,
    shift_right = 0x00e5,
    alt_right = 0x00e6,
    meta_right = 0x00e7,
    fn_key = 0x0100,
    fn_lock = 0x0101,
    media_play_pause = 0x0102,
    media_stop = 0x0103,
    media_track_next = 0x0104,
    media_track_previous = 0x0105,
    media_select = 0x0106,
    eject = 0x0107,
    sleep = 0x0108,
    wake_up = 0x0109,
    browser_back = 0x010a,
    browser_forward = 0x010b,
    browser_refresh = 0x010c,
    browser_stop = 0x010d,
    browser_search = 0x010e,
    browser_favorites = 0x010f,
    browser_home = 0x0110,
    launch_mail = 0x0111,
    launch_app1 = 0x0112,
    launch_app2 = 0x0113,
    _,

    /// The key for HID usage `usage` on page 0x07, or `.unknown` when that
    /// usage has no W3C `code` name.
    pub fn fromHidUsage(usage: u16) Key {
        if (usage >= hid_table.len) return .unknown;
        return hid_table[usage];
    }

    /// The W3C `code` name, such as "KeyA" or "ArrowLeft"; "Unidentified"
    /// for `.unknown` and unnamed values.
    pub fn name(k: Key) []const u8 {
        for (names) |e| if (e.key == k) return e.name;
        return "Unidentified";
    }

    /// The key whose W3C `code` name is `n` (case-sensitive), or null.
    pub fn fromName(n: []const u8) ?Key {
        return name_map.get(n);
    }
};

/// One row of the name table.
pub const NameEntry = struct {
    /// The key.
    key: Key,
    /// Its W3C UI Events `code` value.
    name: []const u8,
};

/// Every named key in HID usage order, written out by hand from the W3C
/// `code` list and the HID Usage Tables.
pub const names = [_]NameEntry{
    .{ .key = .key_a, .name = "KeyA" },
    .{ .key = .key_b, .name = "KeyB" },
    .{ .key = .key_c, .name = "KeyC" },
    .{ .key = .key_d, .name = "KeyD" },
    .{ .key = .key_e, .name = "KeyE" },
    .{ .key = .key_f, .name = "KeyF" },
    .{ .key = .key_g, .name = "KeyG" },
    .{ .key = .key_h, .name = "KeyH" },
    .{ .key = .key_i, .name = "KeyI" },
    .{ .key = .key_j, .name = "KeyJ" },
    .{ .key = .key_k, .name = "KeyK" },
    .{ .key = .key_l, .name = "KeyL" },
    .{ .key = .key_m, .name = "KeyM" },
    .{ .key = .key_n, .name = "KeyN" },
    .{ .key = .key_o, .name = "KeyO" },
    .{ .key = .key_p, .name = "KeyP" },
    .{ .key = .key_q, .name = "KeyQ" },
    .{ .key = .key_r, .name = "KeyR" },
    .{ .key = .key_s, .name = "KeyS" },
    .{ .key = .key_t, .name = "KeyT" },
    .{ .key = .key_u, .name = "KeyU" },
    .{ .key = .key_v, .name = "KeyV" },
    .{ .key = .key_w, .name = "KeyW" },
    .{ .key = .key_x, .name = "KeyX" },
    .{ .key = .key_y, .name = "KeyY" },
    .{ .key = .key_z, .name = "KeyZ" },
    .{ .key = .digit_1, .name = "Digit1" },
    .{ .key = .digit_2, .name = "Digit2" },
    .{ .key = .digit_3, .name = "Digit3" },
    .{ .key = .digit_4, .name = "Digit4" },
    .{ .key = .digit_5, .name = "Digit5" },
    .{ .key = .digit_6, .name = "Digit6" },
    .{ .key = .digit_7, .name = "Digit7" },
    .{ .key = .digit_8, .name = "Digit8" },
    .{ .key = .digit_9, .name = "Digit9" },
    .{ .key = .digit_0, .name = "Digit0" },
    .{ .key = .enter, .name = "Enter" },
    .{ .key = .escape, .name = "Escape" },
    .{ .key = .backspace, .name = "Backspace" },
    .{ .key = .tab, .name = "Tab" },
    .{ .key = .space, .name = "Space" },
    .{ .key = .minus, .name = "Minus" },
    .{ .key = .equal, .name = "Equal" },
    .{ .key = .bracket_left, .name = "BracketLeft" },
    .{ .key = .bracket_right, .name = "BracketRight" },
    .{ .key = .backslash, .name = "Backslash" },
    .{ .key = .semicolon, .name = "Semicolon" },
    .{ .key = .quote, .name = "Quote" },
    .{ .key = .backquote, .name = "Backquote" },
    .{ .key = .comma, .name = "Comma" },
    .{ .key = .period, .name = "Period" },
    .{ .key = .slash, .name = "Slash" },
    .{ .key = .caps_lock, .name = "CapsLock" },
    .{ .key = .f1, .name = "F1" },
    .{ .key = .f2, .name = "F2" },
    .{ .key = .f3, .name = "F3" },
    .{ .key = .f4, .name = "F4" },
    .{ .key = .f5, .name = "F5" },
    .{ .key = .f6, .name = "F6" },
    .{ .key = .f7, .name = "F7" },
    .{ .key = .f8, .name = "F8" },
    .{ .key = .f9, .name = "F9" },
    .{ .key = .f10, .name = "F10" },
    .{ .key = .f11, .name = "F11" },
    .{ .key = .f12, .name = "F12" },
    .{ .key = .print_screen, .name = "PrintScreen" },
    .{ .key = .scroll_lock, .name = "ScrollLock" },
    .{ .key = .pause, .name = "Pause" },
    .{ .key = .insert, .name = "Insert" },
    .{ .key = .home, .name = "Home" },
    .{ .key = .page_up, .name = "PageUp" },
    .{ .key = .delete, .name = "Delete" },
    .{ .key = .end, .name = "End" },
    .{ .key = .page_down, .name = "PageDown" },
    .{ .key = .arrow_right, .name = "ArrowRight" },
    .{ .key = .arrow_left, .name = "ArrowLeft" },
    .{ .key = .arrow_down, .name = "ArrowDown" },
    .{ .key = .arrow_up, .name = "ArrowUp" },
    .{ .key = .num_lock, .name = "NumLock" },
    .{ .key = .numpad_divide, .name = "NumpadDivide" },
    .{ .key = .numpad_multiply, .name = "NumpadMultiply" },
    .{ .key = .numpad_subtract, .name = "NumpadSubtract" },
    .{ .key = .numpad_add, .name = "NumpadAdd" },
    .{ .key = .numpad_enter, .name = "NumpadEnter" },
    .{ .key = .numpad1, .name = "Numpad1" },
    .{ .key = .numpad2, .name = "Numpad2" },
    .{ .key = .numpad3, .name = "Numpad3" },
    .{ .key = .numpad4, .name = "Numpad4" },
    .{ .key = .numpad5, .name = "Numpad5" },
    .{ .key = .numpad6, .name = "Numpad6" },
    .{ .key = .numpad7, .name = "Numpad7" },
    .{ .key = .numpad8, .name = "Numpad8" },
    .{ .key = .numpad9, .name = "Numpad9" },
    .{ .key = .numpad0, .name = "Numpad0" },
    .{ .key = .numpad_decimal, .name = "NumpadDecimal" },
    .{ .key = .intl_backslash, .name = "IntlBackslash" },
    .{ .key = .context_menu, .name = "ContextMenu" },
    .{ .key = .power, .name = "Power" },
    .{ .key = .numpad_equal, .name = "NumpadEqual" },
    .{ .key = .f13, .name = "F13" },
    .{ .key = .f14, .name = "F14" },
    .{ .key = .f15, .name = "F15" },
    .{ .key = .f16, .name = "F16" },
    .{ .key = .f17, .name = "F17" },
    .{ .key = .f18, .name = "F18" },
    .{ .key = .f19, .name = "F19" },
    .{ .key = .f20, .name = "F20" },
    .{ .key = .f21, .name = "F21" },
    .{ .key = .f22, .name = "F22" },
    .{ .key = .f23, .name = "F23" },
    .{ .key = .f24, .name = "F24" },
    .{ .key = .open, .name = "Open" },
    .{ .key = .help, .name = "Help" },
    .{ .key = .select_key, .name = "Select" },
    .{ .key = .again, .name = "Again" },
    .{ .key = .undo, .name = "Undo" },
    .{ .key = .cut, .name = "Cut" },
    .{ .key = .copy, .name = "Copy" },
    .{ .key = .paste, .name = "Paste" },
    .{ .key = .find, .name = "Find" },
    .{ .key = .audio_volume_mute, .name = "AudioVolumeMute" },
    .{ .key = .audio_volume_up, .name = "AudioVolumeUp" },
    .{ .key = .audio_volume_down, .name = "AudioVolumeDown" },
    .{ .key = .numpad_comma, .name = "NumpadComma" },
    .{ .key = .intl_ro, .name = "IntlRo" },
    .{ .key = .kana_mode, .name = "KanaMode" },
    .{ .key = .intl_yen, .name = "IntlYen" },
    .{ .key = .convert, .name = "Convert" },
    .{ .key = .non_convert, .name = "NonConvert" },
    .{ .key = .lang1, .name = "Lang1" },
    .{ .key = .lang2, .name = "Lang2" },
    .{ .key = .lang3, .name = "Lang3" },
    .{ .key = .lang4, .name = "Lang4" },
    .{ .key = .lang5, .name = "Lang5" },
    .{ .key = .numpad_paren_left, .name = "NumpadParenLeft" },
    .{ .key = .numpad_paren_right, .name = "NumpadParenRight" },
    .{ .key = .numpad_backspace, .name = "NumpadBackspace" },
    .{ .key = .numpad_memory_store, .name = "NumpadMemoryStore" },
    .{ .key = .numpad_memory_recall, .name = "NumpadMemoryRecall" },
    .{ .key = .numpad_memory_clear, .name = "NumpadMemoryClear" },
    .{ .key = .numpad_memory_add, .name = "NumpadMemoryAdd" },
    .{ .key = .numpad_memory_subtract, .name = "NumpadMemorySubtract" },
    .{ .key = .numpad_clear, .name = "NumpadClear" },
    .{ .key = .numpad_clear_entry, .name = "NumpadClearEntry" },
    .{ .key = .control_left, .name = "ControlLeft" },
    .{ .key = .shift_left, .name = "ShiftLeft" },
    .{ .key = .alt_left, .name = "AltLeft" },
    .{ .key = .meta_left, .name = "MetaLeft" },
    .{ .key = .control_right, .name = "ControlRight" },
    .{ .key = .shift_right, .name = "ShiftRight" },
    .{ .key = .alt_right, .name = "AltRight" },
    .{ .key = .meta_right, .name = "MetaRight" },
    .{ .key = .fn_key, .name = "Fn" },
    .{ .key = .fn_lock, .name = "FnLock" },
    .{ .key = .media_play_pause, .name = "MediaPlayPause" },
    .{ .key = .media_stop, .name = "MediaStop" },
    .{ .key = .media_track_next, .name = "MediaTrackNext" },
    .{ .key = .media_track_previous, .name = "MediaTrackPrevious" },
    .{ .key = .media_select, .name = "MediaSelect" },
    .{ .key = .eject, .name = "Eject" },
    .{ .key = .sleep, .name = "Sleep" },
    .{ .key = .wake_up, .name = "WakeUp" },
    .{ .key = .browser_back, .name = "BrowserBack" },
    .{ .key = .browser_forward, .name = "BrowserForward" },
    .{ .key = .browser_refresh, .name = "BrowserRefresh" },
    .{ .key = .browser_stop, .name = "BrowserStop" },
    .{ .key = .browser_search, .name = "BrowserSearch" },
    .{ .key = .browser_favorites, .name = "BrowserFavorites" },
    .{ .key = .browser_home, .name = "BrowserHome" },
    .{ .key = .launch_mail, .name = "LaunchMail" },
    .{ .key = .launch_app1, .name = "LaunchApp1" },
    .{ .key = .launch_app2, .name = "LaunchApp2" },
};

const hid_table = blk: {
    var t = [_]Key{.unknown} ** 0xe8;
    for (names) |e| {
        const v = @intFromEnum(e.key);
        if (v < t.len) t[v] = e.key;
    }
    break :blk t;
};

const name_map = blk: {
    var kvs: [names.len]struct { []const u8, Key } = undefined;
    for (names, 0..) |e, i| kvs[i] = .{ e.name, e.key };
    break :blk std.StaticStringMap(Key).initComptime(kvs);
};

/// Modifier state at the time of an event.
pub const Mods = packed struct(u16) {
    /// Either Shift key is held.
    shift: bool = false,
    /// Either Control key is held.
    ctrl: bool = false,
    /// Either Alt key is held (Option on macOS).
    alt: bool = false,
    /// Either Super / Windows / Command key is held.
    super: bool = false,
    /// AltGr (ISO level 3 shift) is held.
    alt_gr: bool = false,
    /// Caps Lock is on.
    caps_lock: bool = false,
    /// Num Lock is on.
    num_lock: bool = false,
    _pad: u9 = 0,
};

/// What happened to a key.
pub const KeyAction = enum(u8) {
    /// The key went down.
    press,
    /// The key went up.
    release,
    /// Auto-repeat while held; backends synthesise it where the OS does not.
    repeat,
};

test "fromHidUsage roundtrip all 0x04..0xE7" {
    var named: usize = 0;
    var usage: u16 = 0x04;
    while (usage <= 0xe7) : (usage += 1) {
        const k = Key.fromHidUsage(usage);
        if (k == .unknown) continue;
        named += 1;
        try std.testing.expectEqual(usage, @intFromEnum(k));
    }
    // 0x04-0xe7 holds 228 usages; the ones without a W3C name are reserved
    // or legacy (keyboard error codes, locking keys, Sun-specific keys).
    try std.testing.expect(named >= 150);
    try std.testing.expectEqual(Key.key_a, Key.fromHidUsage(0x04));
    try std.testing.expectEqual(Key.digit_0, Key.fromHidUsage(0x27));
    try std.testing.expectEqual(Key.enter, Key.fromHidUsage(0x28));
    try std.testing.expectEqual(Key.escape, Key.fromHidUsage(0x29));
    try std.testing.expectEqual(Key.meta_right, Key.fromHidUsage(0xe7));
    try std.testing.expectEqual(Key.unknown, Key.fromHidUsage(0x01));
    try std.testing.expectEqual(Key.unknown, Key.fromHidUsage(0x0100));
}

test "name/fromName roundtrip" {
    for (names, 0..) |e, i| {
        try std.testing.expectEqualStrings(e.name, e.key.name());
        try std.testing.expectEqual(e.key, Key.fromName(e.name).?);
        // Table is strictly ordered by value, so every key appears once.
        if (i > 0) try std.testing.expect(@intFromEnum(names[i - 1].key) < @intFromEnum(e.key));
    }
    try std.testing.expectEqual(@typeInfo(Key).@"enum".fields.len - 1, names.len);
    try std.testing.expectEqualStrings("Unidentified", Key.unknown.name());
    try std.testing.expectEqualStrings("Unidentified", @as(Key, @enumFromInt(0x0076)).name());
    try std.testing.expectEqual(@as(?Key, null), Key.fromName("keya"));
}

test "Mods and Key have fixed layouts" {
    try std.testing.expectEqual(2, @sizeOf(Mods));
    try std.testing.expectEqual(2, @sizeOf(Key));
}
