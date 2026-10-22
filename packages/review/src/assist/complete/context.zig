//! Completion context (E12.F07.S01.T02): what goes around the cursor in a
//! completion request.
//!
//! - The prefix runs back from the cursor by whole lines until its token
//!   budget is spent. When the enclosing scope (a function, from E05
//!   Structure through `Scopes`) starts within 1.5 times that budget, the
//!   prefix starts there and the file header gives way.
//! - The file's import block (the first 30 lines, up to the last import)
//!   is kept when it fits, under a path comment (`// path: src/x.zig`).
//! - The suffix runs forward by whole lines up to its budget, and stops
//!   five lines past the enclosing scope's end.
//! - Extra snippets come from `NeighbourIndex`: the best windows of other
//!   recent documents for the identifiers of the last 30 lines, plus the
//!   best window of this document outside the prefix and suffix.
//! - A completion is multi-line when explicitly asked for, or when the
//!   cursor ends a line that is blank or opens a block; otherwise it is
//!   one line, stopped at a newline.
//!
//! The text is an immutable snapshot, so a request can be built on any
//! thread.

const std = @import("std");
const neighbours = @import("neighbours.zig");

const Allocator = std.mem.Allocator;
pub const Snippet = neighbours.Snippet;
pub const NeighbourIndex = neighbours.NeighbourIndex;

pub const CompletionRequest = struct {
    path: []const u8,
    language: []const u8,
    prefix: []const u8,
    suffix: []const u8,
    extras: []const Snippet = &.{},
    multiline: bool,
    max_tokens: u32,
    stop: []const []const u8,
};

pub const ContextBudget = struct {
    total_tokens: u32 = 2048,
    prefix_share: f32 = 0.6,
    suffix_share: f32 = 0.15,
    extra_share: f32 = 0.25,

    fn part(b: ContextBudget, share: f32) u32 {
        return @intFromFloat(@as(f32, @floatFromInt(b.total_tokens)) * share);
    }
};

/// Counts tokens (E10's calibrated estimator, bound by the app).
pub const TokenEstimate = struct {
    ctx: ?*anyopaque = null,
    count: *const fn (ctx: ?*anyopaque, text: []const u8) u32,

    /// About four bytes per token.
    pub const bytes4: TokenEstimate = .{ .count = struct {
        fn f(_: ?*anyopaque, t: []const u8) u32 {
            return @intCast((t.len + 3) / 4);
        }
    }.f };

    fn of(e: TokenEstimate, t: []const u8) u32 {
        return e.count(e.ctx, t);
    }
};

/// The scope enclosing a byte, in bytes `[start, end)` (E05 Structure).
pub const Scopes = struct {
    ctx: *anyopaque,
    enclosing: *const fn (ctx: *anyopaque, offset: usize) ?[2]usize,
};

pub const Options = struct {
    path: []const u8,
    language: []const u8 = "",
    budget: ContextBudget = .{},
    est: TokenEstimate = .bytes4,
    scopes: ?Scopes = null,
    neighbours: ?*NeighbourIndex = null,
    /// This document's id in `neighbours`.
    doc: u64 = 0,
    /// The user asked for a completion (multi-line).
    explicit: bool = false,
    max_tokens_line: u32 = 32,
    max_tokens_block: u32 = 256,
};

/// Lines of the file header searched for imports.
pub const header_lines = 30;
/// Lines before the cursor whose identifiers query the neighbours.
pub const query_lines = 30;
/// Lines kept after the enclosing scope's end.
pub const after_scope_lines = 5;

/// The request for a completion at byte `cursor` of `text` (in `arena`).
pub fn buildRequest(arena: Allocator, text: []const u8, cursor: usize, o: Options) !CompletionRequest {
    std.debug.assert(cursor <= text.len);
    const est = o.est;
    const pb = o.budget.part(o.budget.prefix_share);
    const sb = o.budget.part(o.budget.suffix_share);
    const xb = o.budget.part(o.budget.extra_share);
    const scope: ?[2]usize = if (o.scopes) |s| s.enclosing(s.ctx, cursor) else null;

    // The header block keeps up to half the prefix budget when it lies
    // above the cursor's line.
    const cur_line = lineStart(text, cursor);
    const header_end = headerEnd(text, o.language);
    var header_t: u32 = 0;
    if (header_end > 0 and header_end <= cur_line) {
        const t = est.of(text[0..header_end]);
        if (t <= pb / 2) header_t = t;
    }

    // Prefix: whole lines back from the cursor's line, in what the header
    // leaves; reaching the header joins it.
    var start = cur_line;
    var used = est.of(text[start..cursor]);
    while (start > 0) {
        const prev = lineStart(text, start - 1);
        if (header_t > 0 and prev < header_end) {
            start = 0;
            used += header_t;
            header_t = 0;
            break;
        }
        const t = est.of(text[prev..start]);
        if (used + t + header_t > pb) break;
        start = prev;
        used += t;
    }
    // The enclosing scope, when it starts within 1.5 times the budget;
    // the header stays only if it still fits.
    if (scope) |sc| if (sc[0] < start) {
        const s = lineStart(text, sc[0]);
        const t = est.of(text[s..cursor]);
        if (@as(f32, @floatFromInt(t)) <= 1.5 * @as(f32, @floatFromInt(pb))) {
            start = s;
            used = t;
            if (header_end > s or t + header_t > pb) header_t = 0;
        }
    };

    var prefix: std.ArrayList(u8) = .empty;
    try prefix.print(arena, "{s} path: {s}\n", .{ commentFor(o.language), o.path });
    if (header_t > 0) try prefix.appendSlice(arena, text[0..header_end]);
    try prefix.appendSlice(arena, text[start..cursor]);

    // Suffix: whole lines forward, to five lines past the scope's end.
    var limit = text.len;
    if (scope) |sc| if (sc[1] >= cursor) {
        var e = sc[1];
        if (e > 0 and e < text.len and text[e - 1] != '\n') e = lineEnd(text, e);
        for (0..after_scope_lines) |_| e = lineEnd(text, e);
        limit = @min(limit, e);
    };
    var end = @min(lineEnd(text, cursor), limit);
    var sused = est.of(text[cursor..end]);
    while (end < limit) {
        const next = @min(lineEnd(text, end), limit);
        const t = est.of(text[end..next]);
        if (sused + t > sb) break;
        end = next;
        sused += t;
    }

    // Neighbour snippets, within the extra budget.
    var extras: std.ArrayList(Snippet) = .empty;
    if (o.neighbours) |nb| {
        const q_from = linesBack(text, cursor, query_lines);
        const query = try neighbours.identifiers(arena, text[q_from..cursor]);
        var buf: [4]Snippet = undefined;
        var got = try nb.top(query, o.doc, buf[0..3]);
        if (try nb.bestIn(o.doc, query, .{ start, end })) |s| {
            buf[got] = s;
            got += 1;
        }
        var xused: u32 = 0;
        for (buf[0..got]) |s| {
            const t = est.of(s.text);
            if (xused + t > xb) continue;
            xused += t;
            try extras.append(arena, .{ .path = try arena.dupe(u8, s.path), .text = try arena.dupe(u8, s.text), .score = s.score });
        }
    }

    const multiline = o.explicit or isBlockPosition(text[lineStart(text, cursor)..cursor], text[cursor..lineEnd(text, cursor)], o.language);
    return .{
        .path = o.path,
        .language = o.language,
        .prefix = prefix.items,
        .suffix = text[cursor..end],
        .extras = extras.items,
        .multiline = multiline,
        .max_tokens = if (multiline) o.max_tokens_block else o.max_tokens_line,
        .stop = if (multiline) &.{} else &.{"\n"},
    };
}

/// Whether a completion at this position should span lines: `before` and
/// `after` are the cursor's line on each side of it.
pub fn isBlockPosition(before: []const u8, after: []const u8, language: []const u8) bool {
    // Mid-line (anything but closers after the cursor): one line.
    for (after) |c| switch (c) {
        ' ', '\t', '\r', '\n', ')', ']', '}', ';', ',', '"', '\'', '`' => {},
        else => return false,
    };
    const b = std.mem.trimEnd(u8, before, " \t\r");
    if (b.len == 0) return true;
    if (std.mem.endsWith(u8, b, "{") or std.mem.endsWith(u8, b, "=>") or std.mem.endsWith(u8, b, "(") or std.mem.endsWith(u8, b, "[")) return true;
    if (std.mem.endsWith(u8, b, ":") and isPythonLike(language)) return true;
    return false;
}

fn isPythonLike(language: []const u8) bool {
    return eqlAny(language, &.{ "python", "py" });
}

/// The comment marker for the path line.
fn commentFor(language: []const u8) []const u8 {
    if (eqlAny(language, &.{ "python", "py", "shell", "sh", "bash", "ruby", "yaml", "toml", "perl", "r" })) return "#";
    if (eqlAny(language, &.{ "lua", "sql", "haskell" })) return "--";
    return "//";
}

const Imports = struct { lang: []const []const u8, starts: []const []const u8 = &.{}, contains: []const []const u8 = &.{} };

const imports = [_]Imports{
    .{ .lang = &.{"zig"}, .contains = &.{"@import("} },
    .{ .lang = &.{ "python", "py" }, .starts = &.{ "import ", "from " } },
    .{ .lang = &.{ "typescript", "ts", "javascript", "js", "tsx", "jsx" }, .starts = &.{ "import ", "export * from" }, .contains = &.{"require("} },
    .{ .lang = &.{ "rust", "rs" }, .starts = &.{ "use ", "extern crate ", "mod " } },
    .{ .lang = &.{"go"}, .starts = &.{ "package ", "import ", "\"" } },
    .{ .lang = &.{ "c", "cpp", "c++", "objc" }, .starts = &.{"#include"} },
    .{ .lang = &.{ "java", "kotlin", "scala" }, .starts = &.{ "package ", "import " } },
    .{ .lang = &.{"csharp"}, .starts = &.{ "using ", "namespace " } },
};

/// The end of the header block: just past the last import line among the
/// first `header_lines` lines (0 when there is none).
fn headerEnd(text: []const u8, language: []const u8) usize {
    const im = for (&imports) |*im| {
        if (eqlAny(language, im.lang)) break im;
    } else return 0;
    var end: usize = 0;
    var pos: usize = 0;
    var line: usize = 0;
    while (pos < text.len and line < header_lines) : (line += 1) {
        const e = lineEnd(text, pos);
        const l = std.mem.trimStart(u8, text[pos..e], " \t");
        const hit = for (im.starts) |p| {
            if (std.mem.startsWith(u8, l, p)) break true;
        } else for (im.contains) |p| {
            if (std.mem.indexOf(u8, l, p) != null) break true;
        } else false;
        if (hit) end = e;
        pos = e;
    }
    return end;
}

fn eqlAny(s: []const u8, set: []const []const u8) bool {
    for (set) |x| if (std.ascii.eqlIgnoreCase(s, x)) return true;
    return false;
}

/// The start of the line holding byte `i`.
fn lineStart(text: []const u8, i: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, text[0..i], '\n')) |n| n + 1 else 0;
}

/// Just past the newline ending the line at `i` (or the text's end).
fn lineEnd(text: []const u8, i: usize) usize {
    return if (std.mem.indexOfScalarPos(u8, text, i, '\n')) |n| n + 1 else text.len;
}

/// The start of the line `n` lines above the one holding `i`.
fn linesBack(text: []const u8, i: usize, n: usize) usize {
    var s = lineStart(text, i);
    for (0..n) |_| {
        if (s == 0) break;
        s = lineStart(text, s - 1);
    }
    return s;
}
