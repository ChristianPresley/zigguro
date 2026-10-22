//! Rule files: `.zigguro/rules/**/*.md` plus the compat locations
//! `.claude/rules/**/*.md` and `.cursor/rules/**/*.mdc` (E10.F07.S01.T02).
//! A rule's frontmatter decides when it applies; `classify` maps both the
//! Claude Code (`paths:`) and Cursor (`globs` / `alwaysApply` /
//! `description`) forms onto one `Activation`. Globs use the local
//! matcher below.

const std = @import("std");
const builtin = @import("builtin");
const fm = @import("frontmatter.zig");

const Allocator = std.mem.Allocator;

/// When a rule enters the context.
pub const Activation = union(enum) {
    /// Loaded at session start (no paths, or Cursor `alwaysApply: true`).
    always,
    /// Loaded once the agent touches a file matching one of the globs.
    scoped: []const []const u8,
    /// Listed by description in the rules index; the agent reads it on request.
    requested: []const u8,
    /// Cursor "Manual" rules: only when the user mentions them.
    manual,
};

/// A classified rule.
pub const Rule = struct {
    activation: Activation,
    /// The Markdown body without frontmatter.
    body: []const u8,
    /// Set when the frontmatter was malformed (the rule is then unscoped).
    problem: ?[]const u8 = null,
};

const Meta = struct {
    paths: []const []const u8 = &.{},
    globs: []const []const u8 = &.{},
    always_apply: ?bool = null,
    description: ?[]const u8 = null,
};

/// Classifies a rule file's text. `mdc` selects Cursor semantics: with
/// neither globs nor `alwaysApply`, a description makes it agent-requested
/// and no description makes it manual. Malformed frontmatter yields an
/// `always` rule with `problem` set (Claude Code treats such files as having
/// no `paths`).
pub fn classify(arena: Allocator, text: []const u8, mdc: bool) Allocator.Error!Rule {
    var diag: fm.Diag = .{};
    const doc = fm.parse(arena, text, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .activation = .always, .body = text, .problem = try std.fmt.allocPrint(arena, "malformed frontmatter at {d}:{d}: {s}", .{ diag.line, diag.col, diag.message }) },
    };
    const meta_node = doc.meta orelse return .{ .activation = if (mdc) .manual else .always, .body = doc.body };
    const meta = fm.decode(Meta, arena, meta_node, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .activation = .always, .body = doc.body, .problem = try std.fmt.allocPrint(arena, "invalid frontmatter field {s}", .{diag.message}) },
    };
    var globs: std.ArrayList([]const u8) = .empty;
    try globs.appendSlice(arena, meta.paths);
    try globs.appendSlice(arena, meta.globs);
    if (meta.always_apply orelse false) return .{ .activation = .always, .body = doc.body };
    if (globs.items.len > 0) return .{ .activation = .{ .scoped = globs.items }, .body = doc.body };
    if (mdc) {
        if (meta.description) |d| if (d.len > 0) return .{ .activation = .{ .requested = d }, .body = doc.body };
        return .{ .activation = .manual, .body = doc.body };
    }
    return .{ .activation = .always, .body = doc.body };
}

/// Whether `path` (relative, `/` or `\` separated) matches any glob.
pub fn matchesAny(globs: []const []const u8, path: []const u8) bool {
    for (globs) |g| if (match(g, path)) return true;
    return false;
}

/// Glob match on a workspace-relative path. Supports `*` (within a
/// segment), `**` (any number of segments), `?`, `[abc]`/`[a-z]`/`[!x]`
/// and `{a,b}`. A pattern without `/` matches the file name in any
/// directory. `\` in `path` is read as `/`; matching is case-insensitive on
/// Windows. A leading `./` or `/` in the pattern anchors at the root.
pub fn match(pattern_in: []const u8, path_in: []const u8) bool {
    var pbuf: [1024]u8 = undefined;
    var sbuf: [1024]u8 = undefined;
    if (pattern_in.len > pbuf.len or path_in.len > sbuf.len) return false;
    const pattern = normalize(&pbuf, pattern_in);
    const path = normalize(&sbuf, path_in);
    var p = pattern;
    if (std.mem.startsWith(u8, p, "./")) p = p[2..] else if (p.len > 0 and p[0] == '/') p = p[1..];
    const s = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    if (std.mem.indexOfScalar(u8, p, '/') == null and p.len == pattern.len) {
        const base = if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s[i + 1 ..] else s;
        return matchAt(p, base);
    }
    return matchAt(p, s);
}

fn normalize(buf: []u8, s: []const u8) []const u8 {
    for (s, 0..) |c, i| {
        const d: u8 = if (c == '\\') '/' else c;
        buf[i] = if (builtin.os.tag == .windows) std.ascii.toLower(d) else d;
    }
    return buf[0..s.len];
}

fn matchAt(p: []const u8, s: []const u8) bool {
    // Braces expand first: try each alternative with the rest of the pattern.
    if (std.mem.indexOfScalar(u8, p, '{')) |open| {
        if (closeBrace(p, open)) |close| {
            var buf: [1024]u8 = undefined;
            var start = open + 1;
            var depth: usize = 0;
            var k = open + 1;
            while (k <= close) : (k += 1) {
                const c = p[k];
                if (c == '{') depth += 1;
                if (c == '}' and depth > 0) {
                    depth -= 1;
                    continue;
                }
                if ((c == ',' and depth == 0) or k == close) {
                    const alt = p[start..k];
                    const total = open + alt.len + (p.len - close - 1);
                    if (total <= buf.len) {
                        @memcpy(buf[0..open], p[0..open]);
                        @memcpy(buf[open..][0..alt.len], alt);
                        @memcpy(buf[open + alt.len ..][0 .. p.len - close - 1], p[close + 1 ..]);
                        if (matchAt(buf[0..total], s)) return true;
                    }
                    start = k + 1;
                }
            }
            return false;
        }
    }
    return matchSimple(p, s);
}

fn closeBrace(p: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    for (p[open..], open..) |c, i| {
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn matchSimple(p: []const u8, s: []const u8) bool {
    if (p.len == 0) return s.len == 0;
    if (std.mem.startsWith(u8, p, "**")) {
        var rest = p[2..];
        if (rest.len > 0 and rest[0] == '/') rest = rest[1..] else if (rest.len == 0) return true;
        // `**/` matches zero or more whole segments.
        var k: usize = 0;
        while (true) {
            if (matchSimple(rest, s[k..])) return true;
            const nk = std.mem.indexOfScalarPos(u8, s, k, '/') orelse return false;
            k = nk + 1;
        }
    }
    switch (p[0]) {
        '*' => {
            var k: usize = 0;
            while (true) : (k += 1) {
                if (matchSimple(p[1..], s[k..])) return true;
                if (k >= s.len or s[k] == '/') return false;
            }
        },
        '?' => return s.len > 0 and s[0] != '/' and matchSimple(p[1..], s[1..]),
        '[' => {
            if (s.len == 0 or s[0] == '/') return false;
            const end = std.mem.indexOfScalarPos(u8, p, 1, ']') orelse return s[0] == '[' and matchSimple(p[1..], s[1..]);
            var set = p[1..end];
            const negate = set.len > 0 and (set[0] == '!' or set[0] == '^');
            if (negate) set = set[1..];
            var hit = false;
            var k: usize = 0;
            while (k < set.len) : (k += 1) {
                if (k + 2 < set.len and set[k + 1] == '-') {
                    if (s[0] >= set[k] and s[0] <= set[k + 2]) hit = true;
                    k += 2;
                } else if (set[k] == s[0]) hit = true;
            }
            return hit != negate and matchSimple(p[end + 1 ..], s[1..]);
        },
        else => return s.len > 0 and s[0] == p[0] and matchSimple(p[1..], s[1..]),
    }
}

test "glob matching" {
    const t = std.testing;
    try t.expect(match("**/*_test.zig", "src/a/b_test.zig"));
    try t.expect(match("**/*_test.zig", "b_test.zig"));
    try t.expect(!match("**/*_test.zig", "src/b.zig"));
    try t.expect(match("src/**/*.ts", "src/x.ts"));
    try t.expect(match("src/**/*.ts", "src/a/b/x.ts"));
    try t.expect(!match("src/**/*.ts", "lib/x.ts"));
    try t.expect(match("src/*.{ts,tsx}", "src/a.tsx"));
    try t.expect(!match("src/*.{ts,tsx}", "src/a/b.tsx"));
    try t.expect(match("*.md", "docs/deep/x.md"));
    try t.expect(match("file?.[a-c]", "file1.b"));
    try t.expect(!match("file?.[!a-c]", "file1.b"));
    try t.expect(match("src/**", "src/a/b"));
    try t.expect(match("src/**/*.zig", "src\\a\\b.zig"));
    try t.expect(match("./src/*.zig", "src/a.zig"));
    try t.expect(match("{src,lib}/**/*.{c,h}", "lib/x/y.h"));
}

test "classify rules" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t = std.testing;
    try t.expect((try classify(a, "plain rule\n", false)).activation == .always);
    const scoped = try classify(a, "---\npaths:\n  - \"**/*_test.zig\"\n---\nbody\n", false);
    try t.expectEqualStrings("**/*_test.zig", scoped.activation.scoped[0]);
    try t.expectEqualStrings("body\n", scoped.body);
    // Cursor: always / auto-attached / agent-requested / manual.
    try t.expect((try classify(a, "---\ndescription: x\nglobs:\nalwaysApply: true\n---\nb\n", true)).activation == .always);
    try t.expectEqual(@as(usize, 2), (try classify(a, "---\ndescription:\nglobs: src/**/*.ts,src/**/*.tsx\nalwaysApply: false\n---\nb\n", true)).activation.scoped.len);
    try t.expectEqualStrings("Use for DB work", (try classify(a, "---\ndescription: Use for DB work\nglobs:\nalwaysApply: false\n---\nb\n", true)).activation.requested);
    try t.expect((try classify(a, "---\ndescription:\nglobs:\nalwaysApply: false\n---\nb\n", true)).activation == .manual);
    const bad = try classify(a, "---\npaths: [unclosed\n---\nbody\n", false);
    try t.expect(bad.activation == .always and bad.problem != null);
}
