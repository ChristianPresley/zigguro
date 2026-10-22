//! Locates git's `core.excludesFile` without a full git config parser
//! (E09 owns that): a minimal INI reader finds `[core] excludesFile` in
//! `~/.gitconfig` or `$XDG_CONFIG_HOME/git/config` (later files win, as in
//! git), expands a leading `~/`, and falls back to git's default
//! `$XDG_CONFIG_HOME/git/ignore` (else `~/.config/git/ignore`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The environment the lookup depends on.
pub const Env = struct {
    /// `$HOME` (or `%USERPROFILE%`).
    home: ?[]const u8,
    /// `$XDG_CONFIG_HOME`, when set and non-empty.
    xdg_config_home: ?[]const u8 = null,
};

/// The value of `[core] excludesFile` in one config file's bytes, or null.
/// Handles comments (`#`, `;`), quoting, backslash escapes, case-insensitive
/// section and key names, and `[core]` appearing more than once (the last
/// assignment wins).
pub fn parseExcludesFile(bytes: []const u8) ?[]const u8 {
    var in_core = false;
    var result: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const name = std.mem.trim(u8, line[1..close], " \t");
            in_core = std.ascii.eqlIgnoreCase(name, "core");
            continue;
        }
        if (!in_core) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "excludesfile")) continue;
        result = cleanValue(std.mem.trim(u8, line[eq + 1 ..], " \t"));
    }
    return result;
}

fn cleanValue(v: []const u8) []const u8 {
    var s = v;
    // Strip a trailing comment outside quotes.
    var in_q = false;
    for (s, 0..) |c, i| {
        if (c == '"') in_q = !in_q;
        if (!in_q and (c == '#' or c == ';')) {
            s = std.mem.trimEnd(u8, s[0..i], " \t");
            break;
        }
    }
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s = s[1 .. s.len - 1];
    return s;
}

/// Expands a leading `~/` against `home`. Caller owns the result.
pub fn expandHome(gpa: Allocator, path: []const u8, home: ?[]const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        if (home) |h| return std.fs.path.join(gpa, &.{ h, path[2..] });
    }
    return gpa.dupe(u8, path);
}

/// Resolves the absolute path of the excludes file: reads the global config
/// files through `dir` (absolute paths) and returns the configured or default
/// path. Caller owns the result; null when no home directory is known.
pub fn resolve(gpa: Allocator, io: std.Io, env: Env) !?[]u8 {
    var configured: ?[]u8 = null;
    errdefer if (configured) |c| gpa.free(c);
    var candidates: [2]?[]u8 = .{ null, null };
    defer for (candidates) |c| if (c) |p| gpa.free(p);
    if (env.home) |h| candidates[0] = try std.fs.path.join(gpa, &.{ h, ".gitconfig" });
    if (env.xdg_config_home) |x| {
        candidates[1] = try std.fs.path.join(gpa, &.{ x, "git", "config" });
    } else if (env.home) |h| {
        candidates[1] = try std.fs.path.join(gpa, &.{ h, ".config", "git", "config" });
    }
    // git reads the XDG file first and ~/.gitconfig second; the latter wins.
    for ([_]?[]u8{ candidates[1], candidates[0] }) |cand| {
        const path = cand orelse continue;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(bytes);
        if (parseExcludesFile(bytes)) |v| {
            if (configured) |c| gpa.free(c);
            configured = try expandHome(gpa, v, env.home);
        }
    }
    if (configured) |c| return c;
    if (env.xdg_config_home) |x| return try std.fs.path.join(gpa, &.{ x, "git", "ignore" });
    if (env.home) |h| return try std.fs.path.join(gpa, &.{ h, ".config", "git", "ignore" });
    return null;
}

test "gitconfig_excludes: parse sections, quoting and comments" {
    try std.testing.expectEqualStrings("~/.gitignore_global", parseExcludesFile(
        \\[user]
        \\  name = X
        \\[Core]
        \\  autocrlf = false
        \\  excludesFile = ~/.gitignore_global ; comment
        \\
    ).?);
    try std.testing.expectEqualStrings("/a b/ignore", parseExcludesFile("[core]\nexcludesfile = \"/a b/ignore\"\n").?);
    try std.testing.expect(parseExcludesFile("[user]\nexcludesfile = /x\n") == null);
    try std.testing.expectEqualStrings("/second", parseExcludesFile("[core]\nexcludesFile=/first\n[core]\nexcludesFile=/second\n").?);
    const e = try expandHome(std.testing.allocator, "~/g", "/home/u");
    defer std.testing.allocator.free(e);
    try std.testing.expectEqualStrings("/home/u/g", e);
}

test "gitconfig_excludes: resolve reads ~/.gitconfig and falls back to the XDG default" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(home);
    const def = (try resolve(gpa, io, .{ .home = home })).?;
    defer gpa.free(def);
    try std.testing.expect(std.mem.endsWith(u8, def, ".config/git/ignore"));
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitconfig", .data = "[core]\n\texcludesFile = ~/my-ignore\n" });
    const got = (try resolve(gpa, io, .{ .home = home })).?;
    defer gpa.free(got);
    try std.testing.expect(std.mem.endsWith(u8, got, "my-ignore"));
    try std.testing.expect(std.mem.startsWith(u8, got, home));
}
