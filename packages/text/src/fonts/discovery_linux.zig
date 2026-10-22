//! Linux font discovery without libfontconfig: the directories and
//! aliases declared in fontconfig's XML configuration, read with our own
//! parser (fontconfig_xml.zig), plus the XDG default directories.
//!
//! Configuration files, in order: `FONTCONFIG_FILE` (else `fonts.conf`
//! in `FONTCONFIG_PATH`, else `/etc/fonts`), then
//! `$XDG_CONFIG_HOME/fontconfig/fonts.conf` and `~/.fonts.conf` when the
//! system configuration did not already include them. Includes nest up
//! to 16 deep and each file is read once (cycles end there).
//! Unreadable or malformed files are skipped with a log line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const discovery = @import("discovery.zig");
const fc = @import("fontconfig_xml.zig");

const log = std.log.scoped(.zg_text);

pub const Discovery = discovery.Discovery;

pub const Options = struct {
    /// Prefixed to every absolute path before the file system is
    /// touched (tests point it at a fixture tree). Paths in the result
    /// carry it too.
    sysroot: []const u8 = "",
};

pub const max_include_depth = 16;
pub const max_config_bytes = 1 << 20;

pub fn discoverLinux(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) !Discovery {
    return discoverWith(gpa, io, env, .{});
}

pub fn discoverWith(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, o: Options) !Discovery {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    var l: Loader = .{ .arena = arena_state.allocator(), .io = io, .o = o, .env = .init(env) };
    try l.run();
    const dirs = try l.existingDirs();
    return .{ .dirs = dirs, .aliases = l.aliases.items, .arena = arena_state.state };
}

const Env = struct {
    home: []const u8,
    config_home: ?[]const u8,
    data_home: ?[]const u8,
    data_dirs: []const u8,
    fc_file: ?[]const u8,
    fc_path: ?[]const u8,

    fn init(m: *const std.process.Environ.Map) Env {
        return .{
            .home = nonEmpty(m.get("HOME")) orelse "",
            .config_home = nonEmpty(m.get("XDG_CONFIG_HOME")),
            .data_home = nonEmpty(m.get("XDG_DATA_HOME")),
            .data_dirs = nonEmpty(m.get("XDG_DATA_DIRS")) orelse "/usr/local/share:/usr/share",
            .fc_file = nonEmpty(m.get("FONTCONFIG_FILE")),
            .fc_path = nonEmpty(m.get("FONTCONFIG_PATH")),
        };
    }
};

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

const Loader = struct {
    arena: Allocator,
    io: Io,
    o: Options,
    env: Env,
    /// Logical (unprefixed) paths, in declaration order.
    dirs: std.ArrayList([]const u8) = .empty,
    aliases: std.ArrayList(discovery.Alias) = .empty,
    visited: std.StringHashMapUnmanaged(void) = .empty,

    /// `$XDG_CONFIG_HOME`, else `~/.config`; null without either.
    fn configHome(l: *Loader) Allocator.Error!?[]const u8 {
        if (l.env.config_home) |c| return c;
        if (l.env.home.len == 0) return null;
        return try std.fs.path.join(l.arena, &.{ l.env.home, ".config" });
    }

    /// `$XDG_DATA_HOME`, else `~/.local/share`; null without either.
    fn dataHome(l: *Loader) Allocator.Error!?[]const u8 {
        if (l.env.data_home) |d| return d;
        if (l.env.home.len == 0) return null;
        return try std.fs.path.join(l.arena, &.{ l.env.home, ".local/share" });
    }

    fn configDir(l: *Loader) []const u8 {
        if (l.env.fc_path) |p| {
            var it = std.mem.splitScalar(u8, p, ':');
            if (it.next()) |first| if (first.len > 0) return first;
        }
        return "/etc/fonts";
    }

    /// `p` on the file system.
    fn phys(l: *Loader, p: []const u8) ![]const u8 {
        if (l.o.sysroot.len == 0 or !std.fs.path.isAbsolute(p)) return p;
        return std.mem.concat(l.arena, u8, &.{ l.o.sysroot, p });
    }

    fn run(l: *Loader) !void {
        const cdir = l.configDir();
        const main = if (l.env.fc_file) |f|
            try std.fs.path.resolvePosix(l.arena, &.{ cdir, f })
        else
            try std.fs.path.join(l.arena, &.{ cdir, "fonts.conf" });
        try l.include(main, true, 0);
        if (try l.configHome()) |c| try l.include(try std.fs.path.join(l.arena, &.{ c, "fontconfig/fonts.conf" }), true, 0);
        if (l.env.home.len > 0) try l.include(try std.fs.path.join(l.arena, &.{ l.env.home, ".fonts.conf" }), true, 0);

        // Always searched, even with no configuration.
        if (try l.dataHome()) |d| try l.dirs.append(l.arena, try std.fs.path.join(l.arena, &.{ d, "fonts" }));
        var it = std.mem.splitScalar(u8, l.env.data_dirs, ':');
        while (it.next()) |d| if (d.len > 0) try l.dirs.append(l.arena, try std.fs.path.join(l.arena, &.{ d, "fonts" }));
        if (l.env.home.len > 0) try l.dirs.append(l.arena, try std.fs.path.join(l.arena, &.{ l.env.home, ".fonts" }));
        try l.dirs.append(l.arena, "/usr/share/fonts");
        try l.dirs.append(l.arena, "/usr/local/share/fonts");
    }

    /// Reads the file or `.conf` directory at logical path `path`.
    fn include(l: *Loader, path: []const u8, ignore_missing: bool, depth: usize) Allocator.Error!void {
        if (depth > max_include_depth) {
            log.info("fontconfig: include depth limit at {s}", .{path});
            return;
        }
        const norm = try std.fs.path.resolvePosix(l.arena, &.{path});
        const gop = try l.visited.getOrPut(l.arena, norm);
        if (gop.found_existing) return;
        const p = try l.phys(norm);
        const st = Io.Dir.cwd().statFile(l.io, p, .{}) catch {
            if (!ignore_missing) log.info("fontconfig: cannot read {s}", .{norm});
            return;
        };
        if (st.kind == .directory) return l.includeDir(norm, p, depth);
        const src = Io.Dir.cwd().readFileAlloc(l.io, p, l.arena, .limited(max_config_bytes)) catch |e| {
            log.info("fontconfig: cannot read {s}: {t}", .{ norm, e });
            return;
        };
        const items = fc.parse(l.arena, src) catch |e| switch (e) {
            error.Malformed => {
                log.info("fontconfig: {s} is malformed; skipped", .{norm});
                return;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        const file_dir = std.fs.path.dirnamePosix(norm) orelse "/";
        for (items) |item| switch (item) {
            .dir => |d| try l.dirs.append(l.arena, try l.resolve(d.path, d.prefix, file_dir, .data)),
            .include => |inc| try l.include(try l.resolve(inc.path, inc.prefix, file_dir, .config), inc.ignore_missing, depth + 1),
            .alias => |a| try l.aliases.append(l.arena, a),
        };
    }

    /// Files of a `conf.d`-style directory: names starting with a digit
    /// and ending in `.conf`, in byte order.
    fn includeDir(l: *Loader, norm: []const u8, p: []const u8, depth: usize) Allocator.Error!void {
        var dir = Io.Dir.cwd().openDir(l.io, p, .{ .iterate = true }) catch return;
        defer dir.close(l.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (it.next(l.io) catch null) |e| {
            if (e.name.len == 0 or !std.ascii.isDigit(e.name[0]) or !std.mem.endsWith(u8, e.name, ".conf")) continue;
            try names.append(l.arena, try l.arena.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, names.items, {}, lessThan);
        for (names.items) |n| try l.include(try std.fs.path.join(l.arena, &.{ norm, n }), true, depth + 1);
    }

    const Base = enum { data, config };

    /// The logical absolute path of a `<dir>`/`<include>` entry.
    fn resolve(l: *Loader, path: []const u8, prefix: fc.Prefix, file_dir: []const u8, base: Base) Allocator.Error![]const u8 {
        if (path[0] == '~') {
            if (l.env.home.len == 0) return path;
            return std.fs.path.resolvePosix(l.arena, &.{ l.env.home, std.mem.trimStart(u8, path[1..], "/") });
        }
        if (std.fs.path.isAbsolute(path)) return std.fs.path.resolvePosix(l.arena, &.{path});
        const root = switch (prefix) {
            .xdg => (if (base == .data) try l.dataHome() else try l.configHome()) orelse return path,
            .relative => file_dir,
            .default, .cwd => "/",
            // Unprefixed relative includes resolve against the config
            // directory; unprefixed relative dirs against cwd ("/" here).
            .none => if (base == .config) l.configDir() else "/",
        };
        return std.fs.path.resolvePosix(l.arena, &.{ root, path });
    }

    /// The declared directories that exist, normalised and deduplicated,
    /// with the sysroot applied.
    fn existingDirs(l: *Loader) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (l.dirs.items) |d| {
            const norm = try std.fs.path.resolvePosix(l.arena, &.{d});
            if ((try seen.getOrPut(l.arena, norm)).found_existing) continue;
            const p = try l.phys(norm);
            const st = Io.Dir.cwd().statFile(l.io, p, .{}) catch continue;
            if (st.kind != .directory) continue;
            try out.append(l.arena, p);
        }
        return out.items;
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
