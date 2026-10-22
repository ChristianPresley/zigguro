//! Default crash and state directories, resolved before the runtime (and
//! E08's workspace paths) exist.

const std = @import("std");
const builtin = @import("builtin");

/// `ZIGGURO_STATE_DIR`, else `$XDG_STATE_HOME/zigguro`, else
/// `$HOME/.local/state/zigguro`; on Windows `%ZIGGURO_STATE_DIR%`, else
/// `%LOCALAPPDATA%\zigguro`. Null when nothing is set.
pub fn stateDir(environ: std.process.Environ, buf: []u8) ?[]const u8 {
    if (override(environ, buf)) |d| return d;
    if (builtin.os.tag == .windows) {
        const d = wide(environ, std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"), buf) orelse return null;
        // `d` is already at the start of `buf`; append in place.
        const tail = "\\zigguro";
        if (buf.len - d.len < tail.len) return null;
        @memcpy(buf[d.len..][0..tail.len], tail);
        return buf[0 .. d.len + tail.len];
    }
    if (nonEmpty(environ.getPosix("XDG_STATE_HOME"))) |d| return copy(buf, &.{ d, "/zigguro" });
    if (nonEmpty(environ.getPosix("HOME"))) |d| return copy(buf, &.{ d, "/.local/state/zigguro" });
    return null;
}

/// The folder next to the executable that makes an install portable: the
/// rule of zg_config's `ConfigPaths.portable` (E17.F02.S02.T01).
pub const portable_dir = "zigguro-data";

/// `stateDir`, except that a portable install keeps its state in
/// `<exe_dir>/zigguro-data/state`. `ZIGGURO_STATE_DIR` still wins.
pub fn stateDirAt(io: std.Io, environ: std.process.Environ, buf: []u8) ?[]const u8 {
    if (override(environ, buf)) |d| return d;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executableDirPath(io, &exe_buf) catch return stateDir(environ, buf);
    if (portableRoot(io, exe_buf[0..n], buf)) |root| {
        const tail = std.fs.path.sep_str ++ "state";
        if (buf.len - root.len < tail.len) return null;
        @memcpy(buf[root.len..][0..tail.len], tail);
        return buf[0 .. root.len + tail.len];
    } else |_| {}
    return stateDir(environ, buf);
}

/// `<exe_dir>/zigguro-data` at the start of `buf` when that directory
/// exists.
pub fn portableRoot(io: std.Io, exe_dir: []const u8, buf: []u8) error{NotPortable}![]const u8 {
    const root = copy(buf, &.{ exe_dir, std.fs.path.sep_str ++ portable_dir }) orelse return error.NotPortable;
    const st = std.Io.Dir.cwd().statFile(io, root, .{}) catch return error.NotPortable;
    if (st.kind != .directory) return error.NotPortable;
    return root;
}

/// `ZIGGURO_STATE_DIR` when set and not empty.
fn override(environ: std.process.Environ, buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return wide(environ, std.unicode.utf8ToUtf16LeStringLiteral("ZIGGURO_STATE_DIR"), buf);
    return copy(buf, &.{nonEmpty(environ.getPosix("ZIGGURO_STATE_DIR")) orelse return null});
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

test "paths: portable root only when zigguro-data is a directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(std.testing.io, ".", &dir_buf);
    const exe_dir = dir_buf[0..n];
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(error.NotPortable, portableRoot(std.testing.io, exe_dir, &buf));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = portable_dir, .data = "" });
    try std.testing.expectError(error.NotPortable, portableRoot(std.testing.io, exe_dir, &buf));
    try tmp.dir.deleteFile(std.testing.io, portable_dir);
    try tmp.dir.createDirPath(std.testing.io, portable_dir);
    const root = try portableRoot(std.testing.io, exe_dir, &buf);
    try std.testing.expect(std.mem.endsWith(u8, root, std.fs.path.sep_str ++ portable_dir));
    try std.testing.expect(std.mem.startsWith(u8, root, exe_dir));
}
