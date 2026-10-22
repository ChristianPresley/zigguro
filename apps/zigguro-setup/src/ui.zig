//! Setup's dialogs. Windows only; elsewhere they print to stderr.

const std = @import("std");
const builtin = @import("builtin");

const MB_OK: u32 = 0x0;
const MB_RETRYCANCEL: u32 = 0x5;
const MB_ICONERROR: u32 = 0x10;
const MB_ICONWARNING: u32 = 0x30;
const MB_ICONINFORMATION: u32 = 0x40;
const IDRETRY: i32 = 4;

extern "user32" fn MessageBoxW(hwnd: ?*anyopaque, text: [*:0]const u16, caption: [*:0]const u16, kind: u32) callconv(.winapi) i32;

pub const Kind = enum { info, warning, failure };

fn show(text: []const u8, flags: u32) i32 {
    if (builtin.os.tag != .windows) {
        std.debug.print("{s}\n", .{text});
        return 0;
    }
    var buf: [2048]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text[0..@min(text.len, 1000)]) catch 0;
    buf[n] = 0;
    return MessageBoxW(null, buf[0..n :0], std.unicode.utf8ToUtf16LeStringLiteral("zigguro setup"), flags);
}

/// A message with an OK button.
pub fn message(kind: Kind, text: []const u8) void {
    _ = show(text, MB_OK | switch (kind) {
        .info => MB_ICONINFORMATION,
        .warning => MB_ICONWARNING,
        .failure => MB_ICONERROR,
    });
}

/// Retry/Cancel; true for Retry.
pub fn retry(text: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    return show(text, MB_RETRYCANCEL | MB_ICONWARNING) == IDRETRY;
}
