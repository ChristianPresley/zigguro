//! Workspace path globs for file triggers (E13.F02.S02.T01), gitignore
//! style, relative to the workspace root with `/` separators:
//!
//! - `*` matches within a segment (dotfiles too), `?` one character,
//!   `[abc]`, `[a-z]` and `[!x]` (or `[^x]`) a class, `\x` a literal.
//! - `**` as a whole segment matches any number of segments.
//! - `{a,b}` alternation (expanded at compile time, nesting allowed).
//! - A pattern without a `/` (other than a trailing one) matches at any
//!   depth; with one it is anchored to the root. A leading `/` anchors.
//!   A trailing `/` matches only directories (so their contents).
//! - A pattern also matches everything under a directory it matches.
//! - In a list, a leading `!` negates and the last matching pattern wins.
//!
//! Pure; no regex.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{ InvalidGlob, OutOfMemory };

/// Segments of patterns and paths are bounded.
const max_segments = 64;
/// `{}` expansions per pattern.
const max_alternatives = 64;

pub const Glob = struct {
    /// One pattern per `{}` alternative; anchored, without the leading
    /// `/`, `!` or trailing `/`.
    alts: []const []const u8,
    negated: bool,
    dir_only: bool,
    /// Literal leading directories shared by every alternative (for fast
    /// rejection), with a trailing `/`; "" when there are none.
    prefix: []const u8,

    pub fn compile(gpa: Allocator, pattern: []const u8) Error!Glob {
        var p = std.mem.trim(u8, pattern, " \t");
        var negated = false;
        if (p.len > 0 and p[0] == '!') {
            negated = true;
            p = p[1..];
        }
        var dir_only = false;
        while (p.len > 0 and p[p.len - 1] == '/') {
            dir_only = true;
            p = p[0 .. p.len - 1];
        }
        if (p.len == 0) return error.InvalidGlob;
        var anchored = std.mem.indexOfScalar(u8, p, '/') != null;
        if (p[0] == '/') p = p[1..];
        if (p.len == 0) return error.InvalidGlob;
        if (std.mem.startsWith(u8, p, "**/")) anchored = true;

        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |s| gpa.free(s);
            list.deinit(gpa);
        }
        try expand(gpa, p, &list, 0);
        for (list.items) |*s| {
            try validate(s.*);
            if (!anchored) {
                const with = try std.mem.concat(gpa, u8, &.{ "**/", s.* });
                gpa.free(s.*);
                s.* = with;
            }
        }
        const alts = try list.toOwnedSlice(gpa);
        errdefer {
            for (alts) |s| gpa.free(s);
            gpa.free(alts);
        }
        const prefix = try gpa.dupe(u8, commonPrefix(alts));
        return .{ .alts = alts, .negated = negated, .dir_only = dir_only, .prefix = prefix };
    }

    pub fn deinit(g: *Glob, gpa: Allocator) void {
        for (g.alts) |s| gpa.free(s);
        gpa.free(g.alts);
        gpa.free(g.prefix);
        g.* = undefined;
    }

    /// Whether `rel_path` (a file, `/`-separated) or a directory above it
    /// matches, ignoring negation.
    pub fn match(g: *const Glob, rel_path: []const u8) bool {
        if (!std.mem.startsWith(u8, rel_path, g.prefix)) return false;
        var sbuf: [max_segments][]const u8 = undefined;
        const s = split(rel_path, &sbuf) orelse return false;
        var pbuf: [max_segments][]const u8 = undefined;
        for (g.alts) |alt| {
            const p = split(alt, &pbuf) orelse continue;
            // The path itself (a file: not for directory-only patterns),
            // then each directory above it.
            var k: usize = if (g.dir_only) s.len - 1 else s.len;
            while (k > 0) : (k -= 1) {
                if (matchSegs(p, s[0..k])) return true;
            }
        }
        return false;
    }
};

/// Patterns with negation, last match wins.
pub const GlobList = struct {
    globs: []Glob,

    pub fn compile(gpa: Allocator, patterns: []const []const u8) Error!GlobList {
        const globs = try gpa.alloc(Glob, patterns.len);
        var n: usize = 0;
        errdefer {
            for (globs[0..n]) |*g| g.deinit(gpa);
            gpa.free(globs);
        }
        for (patterns) |p| {
            globs[n] = try Glob.compile(gpa, p);
            n += 1;
        }
        return .{ .globs = globs };
    }

    pub fn deinit(l: *GlobList, gpa: Allocator) void {
        for (l.globs) |*g| g.deinit(gpa);
        gpa.free(l.globs);
        l.* = undefined;
    }

    pub fn match(l: *const GlobList, rel_path: []const u8) bool {
        var res = false;
        for (l.globs) |*g| {
            if (res == !g.negated) continue;
            if (g.match(rel_path)) res = !g.negated;
        }
        return res;
    }
};

fn split(s: []const u8, buf: *[max_segments][]const u8) ?[][]const u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (n == buf.len) return null;
        buf[n] = seg;
        n += 1;
    }
    if (n == 0) return null;
    return buf[0..n];
}

/// Dynamic programming over (pattern, path) segment positions, so many
/// `**` stay linear in the table size.
fn matchSegs(p: []const []const u8, s: []const []const u8) bool {
    // ok[j]: pattern p[i..] matches path s[j..], filled from the end.
    var ok: [max_segments + 1]bool = @splat(false);
    var next: [max_segments + 1]bool = undefined;
    ok[s.len] = true;
    var i = p.len;
    while (i > 0) {
        i -= 1;
        const star = std.mem.eql(u8, p[i], "**");
        var j = s.len + 1;
        while (j > 0) {
            j -= 1;
            next[j] = if (star)
                ok[j] or (j < s.len and next[j + 1])
            else
                j < s.len and ok[j + 1] and matchSeg(p[i], s[j]);
        }
        @memcpy(ok[0 .. s.len + 1], next[0 .. s.len + 1]);
    }
    return ok[0];
}

/// Wildcards within one segment, with backtracking on the last `*`.
fn matchSeg(p: []const u8, s: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_p: ?usize = null;
    var star_s: usize = 0;
    while (si < s.len) {
        if (pi < p.len) switch (p[pi]) {
            '*' => {
                star_p = pi;
                star_s = si;
                pi += 1;
                continue;
            },
            '?' => {
                pi += 1;
                si += 1;
                continue;
            },
            '[' => if (matchClass(p, pi, s[si])) |r| {
                if (r.ok) {
                    pi = r.end;
                    si += 1;
                    continue;
                }
            } else if (s[si] == '[') {
                pi += 1;
                si += 1;
                continue;
            },
            '\\' => if (pi + 1 < p.len and p[pi + 1] == s[si]) {
                pi += 2;
                si += 1;
                continue;
            },
            else => |c| if (c == s[si]) {
                pi += 1;
                si += 1;
                continue;
            },
        };
        const sp = star_p orelse return false;
        pi = sp + 1;
        star_s += 1;
        si = star_s;
    }
    while (pi < p.len and p[pi] == '*') pi += 1;
    return pi == p.len;
}

/// `[...]` at `p[start]`: whether `c` is in it and where it ends; null
/// when the class is unterminated (then `[` is literal).
fn matchClass(p: []const u8, start: usize, c: u8) ?struct { ok: bool, end: usize } {
    var i = start + 1;
    var neg = false;
    if (i < p.len and (p[i] == '!' or p[i] == '^')) {
        neg = true;
        i += 1;
    }
    var ok = false;
    var first = true;
    while (i < p.len) {
        if (p[i] == ']' and !first) return .{ .ok = ok != neg, .end = i + 1 };
        first = false;
        var lo = p[i];
        if (lo == '\\' and i + 1 < p.len) {
            i += 1;
            lo = p[i];
        }
        if (i + 2 < p.len and p[i + 1] == '-' and p[i + 2] != ']') {
            const hi = p[i + 2];
            if (c >= lo and c <= hi) ok = true;
            i += 3;
        } else {
            if (c == lo) ok = true;
            i += 1;
        }
    }
    return null;
}

fn validate(p: []const u8) Error!void {
    var buf: [max_segments][]const u8 = undefined;
    const segs = split(p, &buf) orelse return error.InvalidGlob;
    for (segs) |s| {
        // `**` only as a whole segment.
        if (s.len > 2 and std.mem.indexOf(u8, s, "**") != null) return error.InvalidGlob;
    }
}

/// Expands the first `{...}` group of `p` recursively into `out`.
fn expand(gpa: Allocator, p: []const u8, out: *std.ArrayList([]const u8), depth: u8) Error!void {
    if (depth > 8) return error.InvalidGlob;
    const open = findUnescaped(p, '{', 0) orelse {
        if (findUnescaped(p, '}', 0) != null) return error.InvalidGlob;
        if (out.items.len >= max_alternatives) return error.InvalidGlob;
        try out.append(gpa, try gpa.dupe(u8, p));
        return;
    };
    // The matching `}` and the top-level commas.
    var level: u32 = 0;
    var i = open;
    var commas: [max_alternatives]usize = undefined;
    var nc: usize = 0;
    const close = while (i < p.len) : (i += 1) {
        switch (p[i]) {
            '\\' => i += 1,
            '{' => level += 1,
            '}' => {
                level -= 1;
                if (level == 0) break i;
            },
            ',' => if (level == 1) {
                if (nc == commas.len) return error.InvalidGlob;
                commas[nc] = i;
                nc += 1;
            },
            else => {},
        }
    } else return error.InvalidGlob;
    var from = open + 1;
    var k: usize = 0;
    while (k <= nc) : (k += 1) {
        const to = if (k < nc) commas[k] else close;
        const alt = try std.mem.concat(gpa, u8, &.{ p[0..open], p[from..to], p[close + 1 ..] });
        defer gpa.free(alt);
        try expand(gpa, alt, out, depth + 1);
        from = to + 1;
    }
}

fn findUnescaped(p: []const u8, c: u8, from: usize) ?usize {
    var i = from;
    while (i < p.len) : (i += 1) {
        if (p[i] == '\\') {
            i += 1;
            continue;
        }
        if (p[i] == c) return i;
    }
    return null;
}

/// The literal directories every alternative starts with.
fn commonPrefix(alts: []const []const u8) []const u8 {
    if (alts.len == 0) return "";
    var end: usize = 0;
    var i: usize = 0;
    const a = alts[0];
    while (i < a.len) : (i += 1) {
        const c = a[i];
        if (std.mem.indexOfScalar(u8, "*?[\\{", c) != null) break;
        for (alts[1..]) |b| if (i >= b.len or b[i] != c) return a[0..end];
        if (c == '/') end = i + 1;
    }
    return a[0..end];
}
