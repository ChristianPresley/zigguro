//! `ConfigPaths`: the one resolver for zigguro's per-user directories
//! (`<config>`, `<data>`, `<state>`, `<cache>`) and the machine-wide
//! `<managed>` policy directory. See `packages/config/docs/paths.md`.
//!
//! Pure: reads only the environment map it is given (never the global
//! environment) and allocates only in the caller's arena. It never creates
//! directories; writers create them on first write. The only I/O is the
//! optional portable-mode probe when `ResolveOptions.io` is set.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

/// Which per-user directory.
pub const Kind = enum { config, data, state, cache };

/// Resolved directories. Every string lives in the arena passed to `resolve`.
pub const ConfigPaths = struct {
    /// App config dir; already ends in "zigguro" (or "config" in portable mode).
    config: []const u8,
    data: []const u8,
    state: []const u8,
    cache: []const u8,
    /// Machine-wide policy dir for E15 locked settings and E16; null if not applicable.
    managed: ?[]const u8,
    home: []const u8,
    /// True when every directory lives under `<exe_dir>/zigguro-data`.
    portable: bool,
    /// Path separator of the target OS.
    sep: u8,
    user_settings: []const u8,
    user_keybindings: []const u8,
    extensions_dir: []const u8,

    /// The directory of kind `k`.
    pub fn dir(p: *const ConfigPaths, k: Kind) []const u8 {
        return switch (k) {
            .config => p.config,
            .data => p.data,
            .state => p.state,
            .cache => p.cache,
        };
    }

    /// `dir(k)` joined with `parts` using the target separator.
    pub fn join(p: *const ConfigPaths, arena: Allocator, k: Kind, parts: []const []const u8) error{OutOfMemory}![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, p.dir(k));
        for (parts) |part| {
            try out.append(arena, p.sep);
            try out.appendSlice(arena, part);
        }
        return out.items;
    }

    /// `<config>/settings.zon`.
    pub fn userSettings(p: *const ConfigPaths) []const u8 {
        return p.user_settings;
    }

    /// `<config>/keybindings.zon`.
    pub fn userKeybindings(p: *const ConfigPaths) []const u8 {
        return p.user_keybindings;
    }

    /// `<data>/extensions`.
    pub fn extensionsDir(p: *const ConfigPaths) []const u8 {
        return p.extensions_dir;
    }
};

/// Alias used by E10 drafts (`zg_config.Paths`).
pub const Paths = ConfigPaths;

/// Options for `resolve`.
pub const ResolveOptions = struct {
    /// The OS whose conventions apply (tests exercise every OS on any host).
    os: std.Target.Os.Tag = builtin.os.tag,
    /// Directory of the running executable, from `std.process.executableDirPathAlloc`.
    exe_dir: ?[]const u8 = null,
    /// When set together with `exe_dir`, probe `<exe_dir>/zigguro-data` for portable mode.
    io: ?std.Io = null,
};

/// Errors of `resolve`.
pub const Error = error{ NoHomeDirectory, OutOfMemory };

const app = "zigguro";
const portable_dir = "zigguro-data";

/// Resolves every directory for `opts.os` from `env`.
pub fn resolve(arena: Allocator, env: *const Environ.Map, opts: ResolveOptions) Error!ConfigPaths {
    const win = opts.os == .windows;
    const sep: u8 = if (win) '\\' else '/';
    const j = Joiner{ .a = arena, .sep = sep };

    // Copy everything taken from `env` so the result outlives the map.
    const home = try arena.dupe(u8, nonEmpty(env, if (win) "USERPROFILE" else "HOME") orelse return error.NoHomeDirectory);
    var p: ConfigPaths = undefined;
    p.home = home;
    p.sep = sep;
    p.portable = false;

    switch (opts.os) {
        .windows => {
            const roaming = absOrNull(env, "APPDATA", true) orelse try j.join(&.{ home, "AppData", "Roaming" });
            const local = absOrNull(env, "LOCALAPPDATA", true) orelse try j.join(&.{ home, "AppData", "Local" });
            p.config = try j.join(&.{ roaming, app });
            p.data = try j.join(&.{ local, app, "data" });
            p.state = try j.join(&.{ local, app, "state" });
            p.cache = try j.join(&.{ local, app, "cache" });
            p.managed = if (absOrNull(env, "ProgramData", true)) |pd| try j.join(&.{ pd, app }) else null;
        },
        .macos => {
            const support = try j.join(&.{ home, "Library", "Application Support", app });
            p.config = support;
            p.data = try j.join(&.{ support, "data" });
            p.state = try j.join(&.{ support, "state" });
            p.cache = try j.join(&.{ home, "Library", "Caches", app });
            p.managed = "/Library/Application Support/zigguro";
        },
        else => {
            p.config = try xdg(j, env, "XDG_CONFIG_HOME", home, &.{".config"});
            p.data = try xdg(j, env, "XDG_DATA_HOME", home, &.{ ".local", "share" });
            p.state = try xdg(j, env, "XDG_STATE_HOME", home, &.{ ".local", "state" });
            p.cache = try xdg(j, env, "XDG_CACHE_HOME", home, &.{".cache"});
            p.managed = "/etc/zigguro";
        },
    }

    if (portableRoot(j, opts)) |root| {
        const r = try root;
        p.config = try j.join(&.{ r, "config" });
        p.data = try j.join(&.{ r, "data" });
        p.state = try j.join(&.{ r, "state" });
        p.cache = try j.join(&.{ r, "cache" });
        p.portable = true;
    }

    // Explicit overrides win over OS defaults and portable mode.
    inline for (.{ .{ "ZIGGURO_CONFIG_DIR", "config" }, .{ "ZIGGURO_DATA_DIR", "data" }, .{ "ZIGGURO_STATE_DIR", "state" }, .{ "ZIGGURO_CACHE_DIR", "cache" } }) |o| {
        if (absOrNull(env, o[0], win)) |v| @field(p, o[1]) = try arena.dupe(u8, v);
    }

    p.user_settings = try j.join(&.{ p.config, "settings.zon" });
    p.user_keybindings = try j.join(&.{ p.config, "keybindings.zon" });
    p.extensions_dir = try j.join(&.{ p.data, "extensions" });
    return p;
}

const Joiner = struct {
    a: Allocator,
    sep: u8,

    fn join(j: Joiner, parts: []const []const u8) error{OutOfMemory}![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (parts, 0..) |part, i| {
            const trimmed = if (i == 0) std.mem.trimEnd(u8, part, "/\\") else part;
            if (i != 0) try out.append(j.a, j.sep);
            try out.appendSlice(j.a, if (i == 0 and trimmed.len == 0) part[0..@min(part.len, 1)] else trimmed);
        }
        return out.items;
    }
};

fn portableRoot(j: Joiner, opts: ResolveOptions) ?error{OutOfMemory}![]const u8 {
    const exe_dir = opts.exe_dir orelse return null;
    const io = opts.io orelse return null;
    const root = j.join(&.{ exe_dir, portable_dir }) catch |e| return e;
    var d = std.Io.Dir.cwd().openDir(io, root, .{}) catch return null;
    d.close(io);
    return root;
}

fn nonEmpty(env: *const Environ.Map, name: []const u8) ?[]const u8 {
    const v = env.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

/// The variable if set, non-empty and absolute for the target OS.
fn absOrNull(env: *const Environ.Map, name: []const u8, win: bool) ?[]const u8 {
    const v = nonEmpty(env, name) orelse return null;
    return if (isAbsolute(v, win)) v else null;
}

/// Absolute path check for the *target* OS, independent of the host.
pub fn isAbsolute(path: []const u8, win: bool) bool {
    if (!win) return path.len > 0 and path[0] == '/';
    if (path.len >= 2 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/')) return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
}

var warned_relative_xdg: std.atomic.Value(bool) = .init(false);

fn xdg(j: Joiner, env: *const Environ.Map, name: []const u8, home: []const u8, default_rel: []const []const u8) error{OutOfMemory}![]const u8 {
    if (nonEmpty(env, name)) |v| {
        if (isAbsolute(v, false)) return j.join(&.{ v, app });
        // The XDG spec says relative values are invalid and must be ignored.
        if (!warned_relative_xdg.swap(true, .monotonic) and !builtin.is_test)
            std.log.scoped(.config).warn("ignoring relative {s}='{s}'", .{ name, v });
    }
    var parts: [4][]const u8 = undefined;
    parts[0] = home;
    for (default_rel, 1..) |r, i| parts[i] = r;
    parts[default_rel.len + 1] = app;
    return j.join(parts[0 .. default_rel.len + 2]);
}

fn testEnv(pairs: []const [2][]const u8) !Environ.Map {
    var m: Environ.Map = .init(std.testing.allocator);
    errdefer m.deinit();
    for (pairs) |kv| try m.put(kv[0], kv[1]);
    return m;
}

fn testResolve(pairs: []const [2][]const u8, opts: ResolveOptions) !struct { std.heap.ArenaAllocator, ConfigPaths } {
    var env = try testEnv(pairs);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    errdefer arena.deinit();
    const p = try resolve(arena.allocator(), &env, opts);
    return .{ arena, p };
}

test "paths: linux defaults" {
    var a, const p = try testResolve(&.{.{ "HOME", "/home/u" }}, .{ .os = .linux });
    defer a.deinit();
    try std.testing.expectEqualStrings("/home/u/.config/zigguro", p.config);
    try std.testing.expectEqualStrings("/home/u/.local/share/zigguro", p.data);
    try std.testing.expectEqualStrings("/home/u/.local/state/zigguro", p.state);
    try std.testing.expectEqualStrings("/home/u/.cache/zigguro", p.cache);
    try std.testing.expectEqualStrings("/etc/zigguro", p.managed.?);
    try std.testing.expectEqualStrings("/home/u/.config/zigguro/settings.zon", p.userSettings());
    try std.testing.expectEqualStrings("/home/u/.config/zigguro/keybindings.zon", p.userKeybindings());
    try std.testing.expectEqualStrings("/home/u/.local/share/zigguro/extensions", p.extensionsDir());
    try std.testing.expect(!p.portable);
}

test "paths: linux XDG absolute" {
    var a, const p = try testResolve(&.{ .{ "HOME", "/home/u" }, .{ "XDG_CONFIG_HOME", "/cfg/" }, .{ "XDG_CACHE_HOME", "/tmp/c" } }, .{ .os = .linux });
    defer a.deinit();
    try std.testing.expectEqualStrings("/cfg/zigguro", p.config);
    try std.testing.expectEqualStrings("/tmp/c/zigguro", p.cache);
}

test "paths: linux XDG relative ignored" {
    var a, const p = try testResolve(&.{ .{ "HOME", "/home/u" }, .{ "XDG_DATA_HOME", "rel/data" } }, .{ .os = .linux });
    defer a.deinit();
    try std.testing.expectEqualStrings("/home/u/.local/share/zigguro", p.data);
}

test "paths: linux XDG empty = unset" {
    var a, const p = try testResolve(&.{ .{ "HOME", "/home/u" }, .{ "XDG_STATE_HOME", "" } }, .{ .os = .linux });
    defer a.deinit();
    try std.testing.expectEqualStrings("/home/u/.local/state/zigguro", p.state);
}

test "paths: windows APPDATA/LOCALAPPDATA" {
    var a, const p = try testResolve(&.{
        .{ "USERPROFILE", "C:\\Users\\u" },
        .{ "APPDATA", "C:\\Users\\u\\AppData\\Roaming" },
        .{ "LOCALAPPDATA", "D:\\Local" },
        .{ "ProgramData", "C:\\ProgramData" },
    }, .{ .os = .windows });
    defer a.deinit();
    try std.testing.expectEqualStrings("C:\\Users\\u\\AppData\\Roaming\\zigguro", p.config);
    try std.testing.expectEqualStrings("D:\\Local\\zigguro\\data", p.data);
    try std.testing.expectEqualStrings("D:\\Local\\zigguro\\state", p.state);
    try std.testing.expectEqualStrings("D:\\Local\\zigguro\\cache", p.cache);
    try std.testing.expectEqualStrings("C:\\ProgramData\\zigguro", p.managed.?);
    try std.testing.expectEqualStrings("C:\\Users\\u\\AppData\\Roaming\\zigguro\\settings.zon", p.userSettings());
}

test "paths: windows fallback USERPROFILE" {
    var a, const p = try testResolve(&.{.{ "USERPROFILE", "C:\\Users\\u" }}, .{ .os = .windows });
    defer a.deinit();
    try std.testing.expectEqualStrings("C:\\Users\\u\\AppData\\Roaming\\zigguro", p.config);
    try std.testing.expectEqualStrings("C:\\Users\\u\\AppData\\Local\\zigguro\\cache", p.cache);
    try std.testing.expect(p.managed == null);
}

test "paths: env overrides win" {
    var a, const p = try testResolve(&.{
        .{ "HOME", "/home/u" },
        .{ "ZIGGURO_CONFIG_DIR", "/override/cfg" },
        .{ "ZIGGURO_CACHE_DIR", "relative/ignored" },
    }, .{ .os = .linux });
    defer a.deinit();
    try std.testing.expectEqualStrings("/override/cfg", p.config);
    try std.testing.expectEqualStrings("/override/cfg/settings.zon", p.userSettings());
    try std.testing.expectEqualStrings("/home/u/.cache/zigguro", p.cache);
}

test "paths: portable mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, portable_dir);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    var a, const p = try testResolve(&.{.{ "HOME", "/home/u" }}, .{ .os = .linux, .exe_dir = buf[0..n], .io = std.testing.io });
    defer a.deinit();
    try std.testing.expect(p.portable);
    try std.testing.expect(std.mem.endsWith(u8, p.config, "/zigguro-data/config"));
    try std.testing.expect(std.mem.endsWith(u8, p.cache, "/zigguro-data/cache"));
    // No zigguro-data next to the exe: not portable.
    var b, const q = try testResolve(&.{.{ "HOME", "/home/u" }}, .{ .os = .linux, .exe_dir = "/nonexistent-dir", .io = std.testing.io });
    defer b.deinit();
    try std.testing.expect(!q.portable);
}

test "paths: no HOME → error.NoHomeDirectory" {
    try std.testing.expectError(error.NoHomeDirectory, testResolve(&.{}, .{ .os = .linux }));
    try std.testing.expectError(error.NoHomeDirectory, testResolve(&.{.{ "HOME", "" }}, .{ .os = .linux }));
}

test "paths: join" {
    var a, const p = try testResolve(&.{.{ "HOME", "/h" }}, .{ .os = .linux });
    defer a.deinit();
    try std.testing.expectEqualStrings("/h/.cache/zigguro/fonts/db.bin", try p.join(a.allocator(), .cache, &.{ "fonts", "db.bin" }));
}
