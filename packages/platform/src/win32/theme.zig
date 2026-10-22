//! The Windows appearance: light/dark apps theme and accent colour from
//! the registry, high contrast and client-area animations from
//! `SystemParametersInfoW`. The backend reads it at start and again on
//! each `WM_SETTINGCHANGE`, and stages `Event.appearance_changed` when it
//! differs. The pure parts build and test on every OS.

const std = @import("std");
const builtin = @import("builtin");
const Appearance = @import("../api/event.zig").Appearance;

const is_windows = builtin.os.tag == .windows;

/// `SPI_GETHIGHCONTRAST`.
pub const SPI_GETHIGHCONTRAST: u32 = 0x0042;
/// `SPI_GETCLIENTAREAANIMATION`.
pub const SPI_GETCLIENTAREAANIMATION: u32 = 0x1042;
/// `HCF_HIGHCONTRASTON`.
pub const HCF_HIGHCONTRASTON: u32 = 0x1;

/// `HIGHCONTRASTW`.
pub const HIGHCONTRASTW = extern struct {
    cbSize: u32 = @sizeOf(HIGHCONTRASTW),
    dwFlags: u32 = 0,
    lpszDefaultScheme: ?[*:0]u16 = null,
};

/// DWM's `AccentColor` (0xAABBGGRR) as sRGB.
pub fn accentRgb(abgr: u32) [3]u8 {
    return .{ @truncate(abgr), @truncate(abgr >> 8), @truncate(abgr >> 16) };
}

/// The raw values `read` gathers, so the mapping can be tested anywhere.
pub const Raw = struct {
    /// `AppsUseLightTheme`, if the value exists.
    apps_use_light: ?u32 = null,
    /// DWM `AccentColor`, if the value exists.
    accent_abgr: ?u32 = null,
    /// High contrast is on.
    high_contrast: bool = false,
    /// Client-area animations are enabled.
    animations: bool = true,
};

/// The appearance `raw` describes.
pub fn fromRaw(raw: Raw) Appearance {
    return .{
        .scheme = if (raw.apps_use_light) |v| (if (v == 0) .dark else .light) else .no_preference,
        .accent = if (raw.accent_abgr) |a| accentRgb(a) else .{ 0, 0, 0 },
        .has_accent = raw.accent_abgr != null,
        .contrast = if (raw.high_contrast) .high else .normal,
        .reduced_motion = !raw.animations,
    };
}

/// Reads the current appearance (Windows only).
pub fn read() Appearance {
    if (!is_windows) return .{};
    const advapi32 = @import("bindings/advapi32.zig");
    const user32 = @import("bindings/user32.zig");
    const L = @import("wide.zig").L;
    var raw: Raw = .{};
    var v: u32 = 0;
    var size: u32 = @sizeOf(u32);
    if (advapi32.RegGetValueW(advapi32.HKEY_CURRENT_USER, L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"), L("AppsUseLightTheme"), advapi32.RRF_RT_REG_DWORD, null, &v, &size) == 0) raw.apps_use_light = v;
    size = @sizeOf(u32);
    if (advapi32.RegGetValueW(advapi32.HKEY_CURRENT_USER, L("Software\\Microsoft\\Windows\\DWM"), L("AccentColor"), advapi32.RRF_RT_REG_DWORD, null, &v, &size) == 0) raw.accent_abgr = v;
    var hc: HIGHCONTRASTW = .{};
    if (user32.SystemParametersInfoW(SPI_GETHIGHCONTRAST, @sizeOf(HIGHCONTRASTW), &hc, 0) != 0) raw.high_contrast = hc.dwFlags & HCF_HIGHCONTRASTON != 0;
    var anim: i32 = 1;
    if (user32.SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &anim, 0) != 0) raw.animations = anim != 0;
    return fromRaw(raw);
}

/// Whether two appearances differ in anything an app would show.
pub fn differs(a: Appearance, b: Appearance) bool {
    return a.scheme != b.scheme or a.has_accent != b.has_accent or !std.mem.eql(u8, &a.accent, &b.accent) or
        a.contrast != b.contrast or a.reduced_motion != b.reduced_motion;
}

const testing = std.testing;

test "AccentColor ABGR → rgb" {
    try testing.expectEqual([3]u8{ 0x00, 0x78, 0xd4 }, accentRgb(0xffd47800));
    try testing.expectEqual([3]u8{ 0x11, 0x22, 0x33 }, accentRgb(0x00332211));
}

test "appearance from raw values" {
    const dark = fromRaw(.{ .apps_use_light = 0, .accent_abgr = 0xffd47800, .high_contrast = true, .animations = false });
    try testing.expectEqual(.dark, dark.scheme);
    try testing.expect(dark.has_accent);
    try testing.expectEqual([3]u8{ 0x00, 0x78, 0xd4 }, dark.accent);
    try testing.expectEqual(.high, dark.contrast);
    try testing.expect(dark.reduced_motion);
    const unknown = fromRaw(.{});
    try testing.expectEqual(.no_preference, unknown.scheme);
    try testing.expect(!unknown.has_accent and !unknown.reduced_motion);
    try testing.expect(differs(dark, unknown));
    try testing.expect(!differs(unknown, fromRaw(.{})));
    try testing.expectEqual(.light, fromRaw(.{ .apps_use_light = 1 }).scheme);
}

test "HIGHCONTRASTW size" {
    try testing.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 16 else 12), @sizeOf(HIGHCONTRASTW));
}
