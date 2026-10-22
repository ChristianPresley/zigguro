//! Default crash and state directories, resolved before the runtime (and
//! E08's workspace paths) exist.

const std = @import("std");
const builtin = @import("builtin");

/// `ZIGGURO_STATE_DIR`, else `$XDG_STATE_HOME/zigguro`, else
/// `$HOME/.local/state/zigguro`; on Windows `%ZIGGURO_STATE_DIR%`, else
/// `%LOCALAPPDATA%\zigguro`. Null when nothing is set.
pub fn stateDir(environ: std.process.Environ, buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        if (wide(environ, std.unicode.utf8ToUtf16LeStringLiteral("ZIGGURO_STATE_DIR"), buf)) |d| return d;
        const d = wide(environ, std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"), buf) orelse return null;
        // `d` is already at the start of `buf`; append in place.
        const tail = "\\zigguro";
        if (buf.len - d.len < tail.len) return null;
        @memcpy(buf[d.len..][0..tail.len], tail);
        return buf[0 .. d.len + tail.len];
    }
    if (nonEmpty(environ.getPosix("ZIGGURO_STATE_DIR"))) |d| return copy(buf, &.{d});
    if (nonEmpty(environ.getPosix("XDG_STATE_HOME"))) |d| return copy(buf, &.{ d, "/zigguro" });
    if (nonEmpty(environ.getPosix("HOME"))) |d| return copy(buf, &.{ d, "/.local/state/zigguro" });
    return null;
}

/// `<state>/crashes` (a backslash on Windows).
pub fn crashDir(state_dir: []const u8, buf: []u8) ?[]const u8 {
    return copy(buf, &.{ state_dir, std.fs.path.sep_str ++ "crashes" });
}

/// A non-empty Windows variable as WTF-8 at the start of `buf`.
fn wide(environ: std.process.Environ, key: [*:0]const u16, buf: []u8) ?[]const u8 {
    const v = environ.getWindows(key) orelse return null;
    if (v.len == 0 or std.unicode.calcWtf8Len(v) > buf.len) return null;
    return buf[0..std.unicode.wtf16LeToWtf8(buf, v)];
}

fn nonEmpty(v: ?[:0]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

fn copy(buf: []u8, parts: []const []const u8) ?[]const u8 {
    var n: usize = 0;
    for (parts) |p| {
        if (buf.len - n < p.len) return null;
        @memcpy(buf[n..][0..p.len], p);
        n += p.len;
    }
    return buf[0..n];
}

test "paths: crash dir" {
    var buf: [64]u8 = undefined;
    const want = if (builtin.os.tag == .windows) "/s\\crashes" else "/s/crashes";
    try std.testing.expectEqualStrings(want, crashDir("/s", &buf).?);
    try std.testing.expect(crashDir("/s" ** 40, &buf) == null);
}
