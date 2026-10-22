//! Gitignore-style path patterns for permission rules (E16.F02.S01.T01).
//!
//! - `*` and `?` match within one segment; `**` matches any number of
//!   segments (including none).
//! - A trailing `/` makes the pattern match directories only.
//! - A bare pattern with no `/` (`.env*`) matches at any depth below the
//!   workspace root, as in gitignore; `./x`, `/x`, `~/x` and `//x` are
//!   anchored.
//! - A pattern also matches everything below a directory it matches, so
//!   `read_file(.git)` covers `.git/config`.
//! - `!` negation is rejected (carve-outs in permission rules are confusing
//!   and unsafe).
//!
//! Paths are absolute. On Windows `C:\Users\x` and `//c/Users/x` are the same
//! path and comparison is ASCII case-insensitive. Matching allocates nothing:
//! paths are walked segment by segment.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maximum path depth matched; deeper paths are compared by their first
/// `max_segments` segments plus a "too deep" flag that fails closed for deny.
pub const max_segments = 256;

/// Errors from `compile`.
pub const Error = error{ BadPattern, OutOfMemory };

/// A compiled path pattern.
pub const PathPattern = struct {
    /// Normalised anchor directory segments (e.g. workspace root).
    anchor: []const []const u8,
    /// Pattern segments; `**` is stored as the literal "**".
    segs: []const []const u8,
    dir_only: bool,
    case_insensitive: bool,
    /// The pattern as written, for messages.
    text: []const u8,

    /// True when `abs_path` (or a directory above it) matches.
    pub fn matches(p: *const PathPattern, abs_path: []const u8, is_dir: bool) bool {
        var buf: [max_segments][]const u8 = undefined;
        const path = splitPath(abs_path, &buf, p.case_insensitive) orelse return false;
        if (path.len < p.anchor.len) return false;
        for (p.anchor, path[0..p.anchor.len]) |a, s| if (!segEql(a, s, p.case_insensitive)) return false;
        const rest = path[p.anchor.len..];
        // Try the path itself, then each ancestor directory below the anchor.
        var n = rest.len;
        while (n > 0) : (n -= 1) {
            const candidate_is_dir = n < rest.len or is_dir;
            if (p.dir_only and !candidate_is_dir) continue;
            if (matchSegs(p.segs, rest[0..n], p.case_insensitive)) return true;
        }
        return false;
    }
};

/// Splits an absolute path into segments. Accepts `/a/b`, `C:\a\b`,
/// `C:/a/b` and `//c/a/b` (the rule form of a drive). Returns null when the
/// path is too deep. `.` segments are dropped; `..` pops (callers pass
/// already-resolved paths; this is defence in depth).
pub fn splitPath(path: []const u8, buf: *[max_segments][]const u8, windows: bool) ?[]const []const u8 {
    var n: usize = 0;
    var rest = path;
    if (windows and rest.len >= 2 and rest[1] == ':' and std.ascii.isAlphabetic(rest[0])) {
        buf[0] = rest[0..1];
        n = 1;
        rest = rest[2..];
    }
    var it = std.mem.tokenizeAny(u8, rest, if (windows) "/\\" else "/");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (n > 0) n -= 1;
            continue;
        }
        if (n == max_segments) return null;
        buf[n] = seg;
        n += 1;
    }
    return buf[0..n];
}

fn segEql(a: []const u8, b: []const u8, ci: bool) bool {
    return if (ci) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn chrEql(a: u8, b: u8, ci: bool) bool {
    return if (ci) std.ascii.toLower(a) == std.ascii.toLower(b) else a == b;
}

/// Matches one segment against a `*`/`?` glob (iterative, linear in
/// practice: the classic single-backtrack-point algorithm).
pub fn matchSegment(pat: []const u8, s: []const u8, ci: bool) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (i < s.len) {
        if (p < pat.len and (pat[p] == '?' or (pat[p] != '*' and chrEql(pat[p], s[i], ci)))) {
            p += 1;
            i += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star = p;
            mark = i;
            p += 1;
        } else if (star) |sp| {
            p = sp + 1;
            mark += 1;
            i = mark;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

/// Matches pattern segments (with `**`) against path segments; same
/// algorithm one level up, with `**` as the star.
fn matchSegs(pat: []const []const u8, path: []const []const u8, ci: bool) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (i < path.len) {
        if (p < pat.len and !isDoubleStar(pat[p]) and matchSegment(pat[p], path[i], ci)) {
            p += 1;
            i += 1;
        } else if (p < pat.len and isDoubleStar(pat[p])) {
            star = p;
            mark = i;
            p += 1;
        } else if (star) |sp| {
            p = sp + 1;
            mark += 1;
            i = mark;
        } else return false;
    }
    while (p < pat.len and isDoubleStar(pat[p])) p += 1;
    return p == pat.len;
}

fn isDoubleStar(s: []const u8) bool {
    return std.mem.eql(u8, s, "**");
}

/// Where relative patterns are anchored.
pub const Anchors = struct {
    workspace_root: []const u8,
    /// The directory of the settings file the rule came from.
    settings_root: []const u8,
    home: []const u8,
    windows: bool,
};

/// Compiles `text`: `//abs`, `~/home-relative`, `/settings-relative`,
/// `./workspace-relative` or bare `workspace-relative`. Memory comes from
/// `arena`.
pub fn compile(arena: Allocator, text: []const u8, anchors: Anchors) Error!PathPattern {
    if (text.len == 0 or text[0] == '!') return error.BadPattern;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.BadPattern;
    var body: []const u8 = undefined;
    var anchor_path: []const u8 = undefined;
    var bare = false;
    if (std.mem.startsWith(u8, text, "//")) {
        anchor_path = "/";
        body = text[2..];
    } else if (std.mem.startsWith(u8, text, "~/")) {
        anchor_path = anchors.home;
        body = text[2..];
    } else if (text[0] == '/') {
        anchor_path = anchors.settings_root;
        body = text[1..];
    } else if (std.mem.startsWith(u8, text, "./")) {
        anchor_path = anchors.workspace_root;
        body = text[2..];
    } else {
        anchor_path = anchors.workspace_root;
        body = text;
        bare = true;
    }
    const dir_only = body.len > 0 and body[body.len - 1] == '/';
    if (dir_only) body = body[0 .. body.len - 1];
    if (body.len == 0) {
        // `//` or `~/`: the anchor itself and everything below it.
        body = "**";
    }
    var segs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, body, if (anchors.windows) "/\\" else "/");
    var slash_inside = std.mem.indexOfScalar(u8, body, '/') != null;
    if (anchors.windows) slash_inside = slash_inside or std.mem.indexOfScalar(u8, body, '\\') != null;
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return error.BadPattern;
        if (std.mem.indexOf(u8, seg, "**") != null and !isDoubleStar(seg)) return error.BadPattern;
        try segs.append(arena, try arena.dupe(u8, seg));
    }
    if (segs.items.len == 0) return error.BadPattern;
    // gitignore: a bare single-segment pattern matches at any depth.
    if (bare and !slash_inside and !isDoubleStar(segs.items[0])) try segs.insert(arena, 0, "**");

    var abuf: [max_segments][]const u8 = undefined;
    const anchor_segs = splitPath(anchor_path, &abuf, anchors.windows) orelse return error.BadPattern;
    const anchor = try arena.alloc([]const u8, anchor_segs.len);
    for (anchor_segs, anchor) |s, *d| d.* = try arena.dupe(u8, s);
    return .{
        .anchor = anchor,
        .segs = try segs.toOwnedSlice(arena),
        .dir_only = dir_only,
        .case_insensitive = anchors.windows,
        .text = try arena.dupe(u8, text),
    };
}

const posix_anchors: Anchors = .{ .workspace_root = "/w", .settings_root = "/w/.zigguro", .home = "/home/u", .windows = false };

fn expectMatch(pattern: []const u8, path: []const u8, is_dir: bool, want: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try compile(arena.allocator(), pattern, posix_anchors);
    if (p.matches(path, is_dir) != want) {
        std.debug.print("pattern {s} path {s} want {}\n", .{ pattern, path, want });
        return error.TestUnexpectedResult;
    }
}

test "glob: gitignore semantics" {
    // Anchors.
    try expectMatch("//etc/**", "/etc/passwd", false, true);
    try expectMatch("//etc/**", "/w/etc/passwd", false, false);
    try expectMatch("~/.ssh/**", "/home/u/.ssh/id_ed25519", false, true);
    try expectMatch("/local.zon", "/w/.zigguro/local.zon", false, true);
    try expectMatch("/local.zon", "/w/.zigguro/sub/local.zon", false, false);
    try expectMatch("./.env", "/w/sub/.env", false, false);
    try expectMatch("./src/*.zig", "/w/src/main.zig", false, true);
    try expectMatch("src/*.zig", "/w/src/a/main.zig", false, false);
    try expectMatch("src/**/*.zig", "/w/src/a/b/main.zig", false, true);
    try expectMatch("src/**/*.zig", "/w/src/main.zig", false, true);
    // Single-segment patterns match at any depth.
    try expectMatch(".env*", "/w/.env", false, true);
    try expectMatch(".env*", "/w/apps/api/.env.local", false, true);
    try expectMatch(".env*", "/elsewhere/.env", false, false);
    // Directory-only and descendants.
    try expectMatch("build/", "/w/build", true, true);
    try expectMatch("build/", "/w/build", false, false);
    try expectMatch("build/", "/w/build/out.o", false, true);
    try expectMatch(".git", "/w/.git/config", false, true);
    try expectMatch("./.git/hooks/**", "/w/.git/hooks/pre-commit", false, true);
    try expectMatch("./.git/hooks/**", "/w/.git/config", false, false);
    // `?` and `..` defence.
    try expectMatch("a?.txt", "/w/ab.txt", false, true);
    try expectMatch("./secret/**", "/w/src/../secret/x", false, true);
    // Home and root shorthands cover everything below.
    try expectMatch("~/", "/home/u/x/y", false, true);
}

test "glob: rejected patterns" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.BadPattern, compile(a, "!keep", posix_anchors));
    try std.testing.expectError(error.BadPattern, compile(a, "", posix_anchors));
    try std.testing.expectError(error.BadPattern, compile(a, "a/../b", posix_anchors));
    try std.testing.expectError(error.BadPattern, compile(a, "a**b", posix_anchors));
}

test "glob: windows drive normalisation and case-insensitivity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const anchors: Anchors = .{ .workspace_root = "C:\\Work\\Repo", .settings_root = "C:\\Work\\Repo\\.zigguro", .home = "C:\\Users\\U", .windows = true };
    const p = try compile(arena.allocator(), "//c/Windows/**", anchors);
    try std.testing.expect(p.matches("C:\\WINDOWS\\System32\\x.dll", false));
    try std.testing.expect(p.matches("c:/windows/x", false));
    try std.testing.expect(!p.matches("D:\\Windows\\x", false));
    const e = try compile(arena.allocator(), ".ENV*", anchors);
    try std.testing.expect(e.matches("c:\\work\\repo\\sub\\.env.local", false));
    const h = try compile(arena.allocator(), "~/.ssh/**", anchors);
    try std.testing.expect(h.matches("C:\\Users\\u\\.ssh\\id_rsa", false));
}

test "glob: segment matcher" {
    try std.testing.expect(matchSegment("*.zig", "main.zig", false));
    try std.testing.expect(matchSegment("a*b*c", "aXXbYYc", false));
    try std.testing.expect(!matchSegment("a*b*c", "aXXbYY", false));
    try std.testing.expect(matchSegment("*", "", false));
    try std.testing.expect(!matchSegment("?", "", false));
}
