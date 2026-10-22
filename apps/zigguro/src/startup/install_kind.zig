//! How this copy of zigguro is installed (E17.F02.S02.T01), and what a
//! portable copy promises: a binary next to a `zigguro-data` folder keeps
//! config, data, state, cache and crash reports inside it, never writes a
//! registration (the app only calls zg_install from setup) and only
//! notifies about updates (`zg_update.layout.InstallKind.managed`).
//!
//! `zigguro --self-check` prints the resolved kind and paths and exits;
//! the portable end-to-end test asserts every path is under
//! `zigguro-data`.

const std = @import("std");
const builtin = @import("builtin");
const zg_config = @import("zg_config");
const zg_crash = @import("zg_crash");
const zg_release = @import("zg_release");
const zg_update = @import("zg_update");
const Io = std.Io;

pub const Info = struct {
    layout: zg_update.layout.Layout,
    paths: ?zg_config.paths.ConfigPaths,
    /// Where crash reports and update state go.
    state: ?[]const u8,
};

/// Resolves the install kind and every directory. Strings go to `arena`.
pub fn resolve(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, environ: std.process.Environ) !Info {
    const exe_dir = try std.process.executableDirPathAlloc(io, arena);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const state = if (zg_crash.paths.stateDirAt(io, environ, &buf)) |s| try arena.dupe(u8, s) else null;
    return .{
        .layout = zg_update.layout.detectInstall(io, exe_dir, builtin.os.tag, zg_release.current.distro),
        .paths = zg_config.paths.resolve(arena, env, .{ .exe_dir = exe_dir, .io = io }) catch null,
        .state = state,
    };
}

/// `--self-check`: the version, install kind and resolved paths.
pub fn write(info: Info, w: *Io.Writer) !void {
    try w.print("zigguro {s}\ninstall: {t} {s}\nupdates: {s}\n", .{
        zg_release.current.version_string,
        info.layout.kind,
        info.layout.root,
        if (info.layout.kind.managed()) "download and apply" else "notify only",
    });
    if (info.paths) |p| {
        try w.print("portable: {}\nconfig: {s}\ndata: {s}\nstate: {s}\ncache: {s}\n", .{ p.portable, p.config, p.data, p.state, p.cache });
    } else try w.writeAll("paths: unresolved (no home directory)\n");
    try w.print("crash state: {s}\n", .{info.state orelse "none"});
}

/// A portable copy's own temp folder, `zigguro-data/tmp`, when it
/// exists (the VS Code convention): set as TMP and TEMP (TMPDIR off
/// Windows) in `env`, which child processes inherit.
pub fn usePortableTmp(io: Io, info: Info, env: *std.process.Environ.Map) !void {
    if (info.layout.kind != .portable) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&buf, "{s}{c}{s}{c}tmp", .{ info.layout.root, std.fs.path.sep, zg_update.layout.portable_dir, std.fs.path.sep }) catch return;
    const st = Io.Dir.cwd().statFile(io, tmp, .{}) catch return;
    if (st.kind != .directory) return;
    if (builtin.os.tag == .windows) {
        try env.put("TMP", tmp);
        try env.put("TEMP", tmp);
    } else try env.put("TMPDIR", tmp);
}

test "install_kind: self-check output" {
    var out: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    try write(.{
        .layout = .{ .root = "/opt/zg", .kind = .portable },
        .paths = null,
        .state = "/opt/zg/zigguro-data/state",
    }, &w);
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "install: portable /opt/zg\nupdates: notify only\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "crash state: /opt/zg/zigguro-data/state\n"));
}

test "install_kind: portable tmp goes into the env map" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPathFile(io, ".", &buf)];
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const info: Info = .{ .layout = .{ .root = root, .kind = .portable }, .paths = null, .state = null };
    try usePortableTmp(io, info, &env);
    try std.testing.expectEqual(@as(usize, 0), env.count());
    try tmp.dir.createDirPath(io, zg_update.layout.portable_dir ++ std.fs.path.sep_str ++ "tmp");
    try usePortableTmp(io, info, &env);
    const key = if (builtin.os.tag == .windows) "TEMP" else "TMPDIR";
    try std.testing.expect(std.mem.endsWith(u8, env.get(key).?, std.fs.path.sep_str ++ "tmp"));
    var other = info;
    other.layout.kind = .unmanaged;
    var env2: std.process.Environ.Map = .init(std.testing.allocator);
    defer env2.deinit();
    try usePortableTmp(io, other, &env2);
    try std.testing.expectEqual(@as(usize, 0), env2.count());
}
