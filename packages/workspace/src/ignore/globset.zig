//! VS Code-style include/exclude globs, as typed in search fields, settings
//! (`files.exclude`, `search.exclude`) and agent tools.
//!
//! Dialect: `*`, `?`, `**`, `[...]`, `[!...]` and `{a,b}` alternation
//! (nested, at most 256 expansions per pattern), in a comma-separated list
//! (commas inside braces do not separate). Matching is git wildmatch in
//! pathname mode on `/`-separated root-relative paths. A pattern without `/`
//! matches at any depth (an implicit `**/`); a leading `./` anchors it to the
//! root. A pattern that matches a directory matches everything inside it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wildmatch = @import("wildmatch.zig");

/// Upper bound on the brace expansions of one pattern.
pub const max_expansions = 256;

/// A compiled list of globs.
pub const GlobSet = struct {
    arena: std.heap.ArenaAllocator,
    globs: []const Glob,
    case_insensitive: bool,

    const Glob = struct {
        full: wildmatch.Pattern,
        /// Per-segment patterns for prefix pruning; null marks a `**` segment.
        segments: []const ?wildmatch.Pattern,
        /// For `x/**`: the pattern `x`, whose matches contain only matches.
        everything_under: ?wildmatch.Pattern,
    };

    /// Compile options.
    pub const Options = struct {
        /// ASCII case-insensitive matching.
        case_insensitive: bool = false,
    };

    /// Compiles a comma-separated list of globs. Fails on unbalanced braces,
    /// too many expansions or a pattern ending in a lone backslash.
    pub fn compile(gpa: Allocator, patterns: []const u8, opts: Options) error{ OutOfMemory, InvalidPattern, TooManyExpansions }!GlobSet {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var globs: std.ArrayList(Glob) = .empty;
        var list: std.ArrayList([]const u8) = .empty;
        try splitTopLevel(a, patterns, &list);
        for (list.items) |item| {
            var expanded: std.ArrayList([]const u8) = .empty;
            try expandBraces(a, item, &expanded);
            for (expanded.items) |e| try globs.append(a, try compileOne(a, e));
        }
        return .{ .arena = arena, .globs = globs.items, .case_insensitive = opts.case_insensitive };
    }

    /// Frees the set.
    pub fn deinit(gs: *GlobSet) void {
        gs.arena.deinit();
        gs.* = undefined;
    }

    /// Whether the set has no patterns.
    pub fn isEmpty(gs: *const GlobSet) bool {
        return gs.globs.len == 0;
    }

    /// Whether `rel_path` (or one of its ancestor directories) matches.
    pub fn matches(gs: *const GlobSet, rel_path: []const u8) bool {
        const flags: wildmatch.Flags = .{ .casefold = gs.case_insensitive };
        for (gs.globs) |*g| {
            if (wildmatch.match(&g.full, rel_path, flags)) return true;
            var i: usize = 0;
            while (std.mem.indexOfScalarPos(u8, rel_path, i, '/')) |slash| : (i = slash + 1) {
                if (wildmatch.match(&g.full, rel_path[0..slash], flags)) return true;
            }
        }
        return false;
    }

    /// Prefix pruning for a traversal: `all` when everything under `rel_dir`
    /// matches, `no` when nothing under it can match, `maybe` otherwise.
    pub fn matchesDirPrefix(gs: *const GlobSet, rel_dir: []const u8) DirMatch {
        if (gs.matches(rel_dir)) return .all;
        const flags: wildmatch.Flags = .{ .casefold = gs.case_insensitive };
        for (gs.globs) |*g| {
            const under = g.everything_under orelse continue;
            if (wildmatch.match(&under, rel_dir, flags)) return .all;
        }
        for (gs.globs) |*g| {
            if (couldMatchUnder(g.segments, rel_dir, flags)) return .maybe;
        }
        return .no;
    }

    /// Result of `matchesDirPrefix`.
    pub const DirMatch = enum { no, maybe, all };
};

fn couldMatchUnder(segments: []const ?wildmatch.Pattern, rel_dir: []const u8, flags: wildmatch.Flags) bool {
    var it = std.mem.splitScalar(u8, rel_dir, '/');
    var i: usize = 0;
    while (it.next()) |seg| : (i += 1) {
        if (i >= segments.len) return false;
        const p = segments[i] orelse return true;
        if (!wildmatch.match(&p, seg, flags)) return false;
    }
    // Every directory segment matched a pattern segment; deeper paths may too.
    return i < segments.len;
}

fn compileOne(a: Allocator, raw: []const u8) !GlobSet.Glob {
    var p = std.mem.trim(u8, raw, " \t");
    var anchored = false;
    if (std.mem.startsWith(u8, p, "./")) {
        anchored = true;
        p = p[2..];
    } else if (p.len > 0 and p[0] == '/') {
        anchored = true;
        p = p[1..];
    }
    while (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    const text = if (!anchored and std.mem.indexOfScalar(u8, p, '/') == null)
        try std.mem.concat(a, u8, &.{ "**/", p })
    else
        p;
    var segs: std.ArrayList(?wildmatch.Pattern) = .empty;
    var it = std.mem.splitScalar(u8, text, '/');
    while (it.next()) |s| {
        if (std.mem.eql(u8, s, "**")) {
            try segs.append(a, null);
        } else {
            try segs.append(a, try wildmatch.compile(a, s, .{ .pathname = true }));
        }
    }
    const under: ?wildmatch.Pattern = if (std.mem.endsWith(u8, text, "/**") and text.len > 3)
        try wildmatch.compile(a, text[0 .. text.len - 3], .{ .pathname = true })
    else
        null;
    return .{ .full = try wildmatch.compile(a, text, .{ .pathname = true }), .segments = segs.items, .everything_under = under };
}

/// Splits `s` at commas that are not inside braces or brackets.
fn splitTopLevel(a: Allocator, s: []const u8, out: *std.ArrayList([]const u8)) !void {
    var depth: usize = 0;
    var in_class = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '\\' => i += 1,
            '[' => in_class = true,
            ']' => in_class = false,
            '{' => if (!in_class) {
                depth += 1;
            },
            '}' => if (!in_class and depth > 0) {
                depth -= 1;
            },
            ',' => if (depth == 0 and !in_class) {
                try appendNonEmpty(a, out, s[start..i]);
                start = i + 1;
            },
            else => {},
        }
    }
    if (depth != 0) return error.InvalidPattern;
    try appendNonEmpty(a, out, s[start..]);
}

fn appendNonEmpty(a: Allocator, out: *std.ArrayList([]const u8), s: []const u8) !void {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len > 0) try out.append(a, t);
}

/// Expands `{a,b}` alternations (nested) into `out`.
pub fn expandBraces(a: Allocator, pattern: []const u8, out: *std.ArrayList([]const u8)) error{ OutOfMemory, InvalidPattern, TooManyExpansions }!void {
    // Find the first top-level brace group.
    var i: usize = 0;
    var open: ?usize = null;
    var depth: usize = 0;
    var in_class = false;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (in_class) {
            if (c == ']') in_class = false;
            continue;
        }
        switch (c) {
            '[' => in_class = true,
            '{' => {
                if (depth == 0) open = i;
                depth += 1;
            },
            '}' => {
                if (depth == 0) return error.InvalidPattern;
                depth -= 1;
                if (depth == 0) break;
            },
            else => {},
        }
    }
    const o = open orelse {
        if (out.items.len >= max_expansions) return error.TooManyExpansions;
        try out.append(a, pattern);
        return;
    };
    if (depth != 0 or i >= pattern.len) return error.InvalidPattern;
    const close = i;
    const prefix = pattern[0..o];
    const suffix = pattern[close + 1 ..];
    // Split the group body at its top-level commas.
    var alts: std.ArrayList([]const u8) = .empty;
    var d: usize = 0;
    var start = o + 1;
    var j = o + 1;
    while (j < close) : (j += 1) {
        switch (pattern[j]) {
            '\\' => j += 1,
            '{' => d += 1,
            '}' => d -= 1,
            ',' => if (d == 0) {
                try alts.append(a, pattern[start..j]);
                start = j + 1;
            },
            else => {},
        }
    }
    try alts.append(a, pattern[start..close]);
    for (alts.items) |alt| {
        const joined = try std.mem.concat(a, u8, &.{ prefix, alt, suffix });
        try expandBraces(a, joined, out);
    }
}
