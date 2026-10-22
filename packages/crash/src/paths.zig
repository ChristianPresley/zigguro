//! Default crash and state directories, resolved before the runtime (and
//! E08's workspace paths) exist.

const std = @import("std");
const builtin = @import("builtin");

/// `ZIGGURO_STATE_DIR`, else `$XDG_STATE_HOME/zigguro`, else
/// `$HOME/.local/state/zigguro` (POSIX only; null on Windows until
/// E17.F05.S01.T03, or when nothing is set).
pub fn stateDir(environ: std.process.Environ, buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    if (nonEmpty(environ.getPosix("ZIGGURO_STATE_DIR"))) |d| return copy(buf, &.{d});
    if (nonEmpty(environ.getPosix("XDG_STATE_HOME"))) |d| return copy(buf, &.{ d, "/zigguro" });
    if (nonEmpty(environ.getPosix("HOME"))) |d| return copy(buf, &.{ d, "/.local/state/zigguro" });
    return null;
}

/// `<state>/crashes`.
pub fn crashDir(state_dir: []const u8, buf: []u8) ?[]const u8 {
    return copy(buf, &.{ state_dir, "/crashes" });
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
    try std.testing.expectEqualStrings("/s/crashes", crashDir("/s", &buf).?);
    try std.testing.expect(crashDir("/s" ** 40, &buf) == null);
}
