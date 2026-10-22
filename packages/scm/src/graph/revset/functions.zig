//! The revset function table, string patterns, and the provider
//! interfaces that the AI and review functions query (F05 provenance and
//! history search, the E12 review adapter). Functions whose provider is
//! missing fail with `error.Unavailable`.

const std = @import("std");
const id_mod = @import("../../store/id.zig");
const ObjectId = id_mod.ObjectId;
const Allocator = std.mem.Allocator;

pub const Builtin = struct {
    name: []const u8,
    min_args: u8,
    max_args: u8,
};

/// Every built-in function with its arity.
pub const builtins = [_]Builtin{
    .{ .name = "all", .min_args = 0, .max_args = 0 },
    .{ .name = "none", .min_args = 0, .max_args = 0 },
    .{ .name = "root", .min_args = 0, .max_args = 0 },
    .{ .name = "visible_heads", .min_args = 0, .max_args = 0 },
    .{ .name = "heads", .min_args = 1, .max_args = 1 },
    .{ .name = "roots", .min_args = 1, .max_args = 1 },
    .{ .name = "parents", .min_args = 1, .max_args = 1 },
    .{ .name = "children", .min_args = 1, .max_args = 1 },
    .{ .name = "ancestors", .min_args = 1, .max_args = 2 },
    .{ .name = "descendants", .min_args = 1, .max_args = 2 },
    .{ .name = "description", .min_args = 1, .max_args = 1 },
    .{ .name = "author", .min_args = 1, .max_args = 1 },
    .{ .name = "committer", .min_args = 1, .max_args = 1 },
    .{ .name = "mine", .min_args = 0, .max_args = 0 },
    .{ .name = "empty", .min_args = 0, .max_args = 0 },
    .{ .name = "conflicts", .min_args = 0, .max_args = 0 },
    .{ .name = "files", .min_args = 1, .max_args = 1 },
    .{ .name = "bookmarks", .min_args = 0, .max_args = 1 },
    .{ .name = "remote_bookmarks", .min_args = 0, .max_args = 2 },
    .{ .name = "untracked_remote_bookmarks", .min_args = 0, .max_args = 2 },
    .{ .name = "tags", .min_args = 0, .max_args = 1 },
    .{ .name = "trunk", .min_args = 0, .max_args = 0 },
    .{ .name = "present", .min_args = 1, .max_args = 1 },
    .{ .name = "latest", .min_args = 1, .max_args = 2 },
    .{ .name = "fork_point", .min_args = 1, .max_args = 1 },
    .{ .name = "divergent", .min_args = 0, .max_args = 0 },
    .{ .name = "agent", .min_args = 0, .max_args = 1 },
    .{ .name = "human", .min_args = 0, .max_args = 0 },
    .{ .name = "session", .min_args = 1, .max_args = 1 },
    .{ .name = "lane", .min_args = 0, .max_args = 1 },
    .{ .name = "reviewed", .min_args = 0, .max_args = 0 },
    .{ .name = "unreviewed", .min_args = 0, .max_args = 0 },
    .{ .name = "signed", .min_args = 0, .max_args = 0 },
    .{ .name = "why", .min_args = 2, .max_args = 2 },
    .{ .name = "evolog", .min_args = 1, .max_args = 1 },
    .{ .name = "touched_by_op", .min_args = 1, .max_args = 1 },
};

pub fn find(name: []const u8) ?Builtin {
    for (builtins) |b| if (std.mem.eql(u8, b.name, name)) return b;
    return null;
}

/// Function names, for suggestions.
pub const names = blk: {
    var out: [builtins.len][]const u8 = undefined;
    for (builtins, 0..) |b, i| out[i] = b.name;
    const final = out;
    break :blk final;
};

pub const PatternKind = enum { substring, exact, glob };

/// A compiled string pattern. `regex:` patterns need zg-regex (E05.F03)
/// and are refused for now.
pub const Pattern = struct {
    kind: PatternKind,
    text: []const u8,
    case_insensitive: bool = false,
    /// `files()` default: the path itself or anything under it.
    path_prefix: bool = false,

    /// From a pattern's kind ("" means substring) and text.
    pub fn parse(kind: []const u8, text: []const u8) error{ UnknownPatternKind, Unavailable }!Pattern {
        const table = [_]struct { []const u8, PatternKind, bool }{
            .{ "", .substring, false },
            .{ "substring", .substring, false },
            .{ "substring-i", .substring, true },
            .{ "exact", .exact, false },
            .{ "exact-i", .exact, true },
            .{ "glob", .glob, false },
            .{ "glob-i", .glob, true },
        };
        for (table) |e| if (std.mem.eql(u8, e[0], kind)) return .{ .kind = e[1], .text = text, .case_insensitive = e[2] };
        if (std.mem.eql(u8, kind, "regex") or std.mem.eql(u8, kind, "regex-i")) return error.Unavailable;
        return error.UnknownPatternKind;
    }

    pub fn matches(p: Pattern, s: []const u8) bool {
        if (p.path_prefix) {
            const t = std.mem.trimEnd(u8, p.text, "/");
            if (t.len == 0 or std.mem.eql(u8, t, ".")) return true;
            return std.mem.eql(u8, s, t) or (std.mem.startsWith(u8, s, t) and s.len > t.len and s[t.len] == '/');
        }
        return switch (p.kind) {
            .exact => if (p.case_insensitive) std.ascii.eqlIgnoreCase(p.text, s) else std.mem.eql(u8, p.text, s),
            .substring => if (p.case_insensitive) std.ascii.indexOfIgnoreCase(s, p.text) != null else std.mem.indexOf(u8, s, p.text) != null,
            .glob => globMatch(p.text, s, p.case_insensitive),
        };
    }
};

pub const pattern_kinds = [_][]const u8{ "prefix", "substring", "substring-i", "exact", "exact-i", "glob", "glob-i", "regex", "regex-i" };

/// Glob matching: `*` matches within one path component, `**` across
/// components, `?` one character, `[abc]`/`[a-z]`/`[!x]` a class.
pub fn globMatch(pat: []const u8, s: []const u8, ci: bool) bool {
    var p: usize = 0;
    var i: usize = 0;
    // Backtracking points for the last `*` and `**`.
    var star_p: ?usize = null;
    var star_i: usize = 0;
    var dstar_p: ?usize = null;
    var dstar_i: usize = 0;
    while (true) {
        if (p < pat.len) {
            const c = pat[p];
            if (c == '*') {
                if (p + 1 < pat.len and pat[p + 1] == '*') {
                    var q = p + 2;
                    if (q < pat.len and pat[q] == '/') q += 1;
                    dstar_p = q;
                    dstar_i = i;
                    star_p = null;
                    p = q;
                    continue;
                }
                star_p = p + 1;
                star_i = i;
                p += 1;
                continue;
            }
            if (i < s.len) {
                if (c == '?' and s[i] != '/') {
                    p += 1;
                    i += 1;
                    continue;
                }
                if (c == '[') {
                    if (classMatch(pat, p, s[i], ci)) |end| {
                        p = end;
                        i += 1;
                        continue;
                    }
                } else if (c != '?' and charEql(c, s[i], ci)) {
                    p += 1;
                    i += 1;
                    continue;
                }
            }
        } else if (i == s.len) return true;
        // Mismatch: retry the last `*` one character further (not past a
        // '/'), else the last `**`.
        if (star_p) |sp| {
            if (star_i < s.len and s[star_i] != '/') {
                star_i += 1;
                i = star_i;
                p = sp;
                continue;
            }
        }
        if (dstar_p) |dp| {
            if (dstar_i < s.len) {
                dstar_i += 1;
                i = dstar_i;
                p = dp;
                star_p = null;
                continue;
            }
        }
        return false;
    }
}

fn charEql(a: u8, b: u8, ci: bool) bool {
    return if (ci) std.ascii.toLower(a) == std.ascii.toLower(b) else a == b;
}

/// Matches `[...]` at `pat[p]`; returns the index after `]`, or null.
fn classMatch(pat: []const u8, p: usize, c: u8, ci: bool) ?usize {
    var k = p + 1;
    var negate = false;
    if (k < pat.len and (pat[k] == '!' or pat[k] == '^')) {
        negate = true;
        k += 1;
    }
    var hit = false;
    var first = true;
    while (k < pat.len and (pat[k] != ']' or first)) : (first = false) {
        if (k + 2 < pat.len and pat[k + 1] == '-' and pat[k + 2] != ']') {
            const lo = pat[k];
            const hi = pat[k + 2];
            const x = if (ci) std.ascii.toLower(c) else c;
            if ((x >= lo and x <= hi) or (ci and std.ascii.toUpper(c) >= lo and std.ascii.toUpper(c) <= hi)) hit = true;
            k += 3;
        } else {
            if (charEql(pat[k], c, ci)) hit = true;
            k += 1;
        }
    }
    if (k >= pat.len) return null;
    if (c == '/') return null;
    return if (hit != negate) k + 1 else null;
}

/// F05 provenance: which changes carry AI-attributed lines.
pub const ProvenanceQuery = struct {
    ctx: *anyopaque,
    /// Whether `commit` adds lines attributed to an agent whose
    /// `agent_name` or `model_id` matches `p` (any agent when null).
    hasAgentLines: *const fn (ctx: *anyopaque, commit: ObjectId, p: ?Pattern) anyerror!bool,
    /// Whether `commit` was made in agent session `session`.
    inSession: *const fn (ctx: *anyopaque, commit: ObjectId, session: []const u8) anyerror!bool,
};

/// The E12 review adapter.
pub const ReviewQuery = struct {
    ctx: *anyopaque,
    isReviewed: *const fn (ctx: *anyopaque, commit: ObjectId) anyerror!bool,
};

/// F05 history search (blame).
pub const HistorySearch = struct {
    ctx: *anyopaque,
    /// The commits blame reports for `line` (1-based) of `path` at the
    /// working-copy commit. Allocated in `arena`.
    blame: *const fn (ctx: *anyopaque, arena: Allocator, path: []const u8, line: u32) anyerror![]const ObjectId,
};
