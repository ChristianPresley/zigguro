//! Token-budgeted context for the F06 prompts (E09.F06.S01.T01): change
//! statistics, unified diffs that fit a budget, and the helpers for
//! sizing text.
//!
//! When a diff is over budget, generated and lock files go first (each
//! becomes one `@@ path: +N -M (omitted, generated)` line), then hunks
//! are kept by rank, size x (1 + touches a public declaration), until the
//! budget is spent; the rest become `@@ path: +N -M (omitted)` lines.
//! Files stay in path order and kept hunks in file order.

const std = @import("std");
const mat = @import("../merge/materialize.zig");
const proposal_files = @import("proposal_files.zig");
const FileChange = proposal_files.FileChange;
const Allocator = std.mem.Allocator;

/// Tokens for `text`, estimated as bytes / 3.5 (no tokenizer here).
pub fn estimateTokens(text: []const u8) u32 {
    return @intCast(@min(std.math.maxInt(u32), (text.len * 2 + 6) / 7));
}

/// The longest prefix of `text` within `tokens`, cut at a line (or
/// UTF-8) boundary when one is near.
pub fn truncate(text: []const u8, tokens: u32) []const u8 {
    const max = @as(usize, tokens) * 7 / 2;
    if (text.len <= max) return text;
    var end = max;
    if (std.mem.lastIndexOfScalar(u8, text[0..max], '\n')) |nl| {
        if (nl + 1 >= max / 2) end = nl + 1;
    }
    while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) end -= 1;
    return text[0..end];
}

pub const ContextBudget = struct {
    total: u32,
    diff: u32,
    intent: u32,
    conventions: u32,

    /// A fifth for intent, a tenth for conventions, the rest for the
    /// diff (which also gets whatever the others leave).
    pub fn split(total: u32) ContextBudget {
        const intent = total / 5;
        const conventions = total / 10;
        return .{ .total = total, .diff = total - intent - conventions, .intent = intent, .conventions = conventions };
    }
};

pub const Stats = struct {
    files: u32 = 0,
    insertions: u32 = 0,
    deletions: u32 = 0,
};

pub const Hunk = struct {
    /// Starts with the `@@ -a,b +c,d @@` line.
    text: []const u8,
    added: u32,
    removed: u32,
};

pub const FileDiff = struct {
    path: []const u8,
    hunks: []const Hunk,
    added: u32,
    removed: u32,
    generated: bool,
};

const max_diff_lines = 20_000;

fn replaceAll(arena: Allocator, n: usize, m: usize) ![]mat.DiffOp {
    const ops = try arena.alloc(mat.DiffOp, n + m);
    for (0..n) |i| ops[i] = .{ .kind = .delete, .index = i };
    for (0..m) |i| ops[n + i] = .{ .kind = .insert, .index = i };
    return ops;
}

/// Diffs `f` by lines into hunks with `context` lines around changes.
pub fn diffFile(arena: Allocator, f: FileChange, context: usize, generated: bool) !FileDiff {
    const a = try mat.splitLines(arena, f.base orelse "");
    const b = try mat.splitLines(arena, f.new orelse "");
    // The line diff keeps an O(D^2) trace: very large files are shown as
    // replaced outright.
    const ops = if (a.len + b.len > max_diff_lines) try replaceAll(arena, a.len, b.len) else try mat.diffLines(arena, a, b);
    var hunks: std.ArrayList(Hunk) = .empty;
    var added: u32 = 0;
    var removed: u32 = 0;
    // Position of each op in a and b.
    const pa = try arena.alloc(usize, ops.len + 1);
    const pb = try arena.alloc(usize, ops.len + 1);
    var ia: usize = 0;
    var ib: usize = 0;
    for (ops, 0..) |op, k| {
        pa[k] = ia;
        pb[k] = ib;
        switch (op.kind) {
            .equal => {
                ia += 1;
                ib += 1;
            },
            .delete => ia += 1,
            .insert => ib += 1,
        }
    }
    pa[ops.len] = ia;
    pb[ops.len] = ib;

    var k: usize = 0;
    while (k < ops.len) {
        if (ops[k].kind == .equal) {
            k += 1;
            continue;
        }
        // A hunk: from `context` equal ops before the change to
        // `context` after the last change that is within 2 * context.
        const start = k -| context;
        var end = k;
        var last_change = k;
        while (end < ops.len) : (end += 1) {
            if (ops[end].kind != .equal) {
                last_change = end;
            } else if (end - last_change > 2 * context) break;
        }
        end = @min(ops.len, last_change + 1 + context);
        var body: std.ArrayList(u8) = .empty;
        var h_add: u32 = 0;
        var h_del: u32 = 0;
        for (ops[start..end]) |op| {
            const line = switch (op.kind) {
                .equal, .delete => a[op.index],
                .insert => b[op.index],
            };
            try body.append(arena, switch (op.kind) {
                .equal => ' ',
                .delete => '-',
                .insert => '+',
            });
            try body.appendSlice(arena, line);
            if (line.len == 0 or line[line.len - 1] != '\n') try body.appendSlice(arena, "\n\\ No newline at end of file\n");
            switch (op.kind) {
                .delete => h_del += 1,
                .insert => h_add += 1,
                .equal => {},
            }
        }
        const a_len = pa[end] - pa[start];
        const b_len = pb[end] - pb[start];
        const text = try std.fmt.allocPrint(arena, "@@ -{d},{d} +{d},{d} @@\n{s}", .{
            if (a_len == 0) pa[start] else pa[start] + 1, a_len,
            if (b_len == 0) pb[start] else pb[start] + 1, b_len,
            body.items,
        });
        try hunks.append(arena, .{ .text = text, .added = h_add, .removed = h_del });
        added += h_add;
        removed += h_del;
        k = end;
    }
    return .{ .path = f.path, .hunks = hunks.items, .added = added, .removed = removed, .generated = generated };
}

/// Whether `path` is a lock or build-output file, or matches one of the
/// `linguist-generated` patterns (from `generatedPatterns`).
pub fn isGenerated(path: []const u8, patterns: []const []const u8) bool {
    const base = std.fs.path.basenamePosix(path);
    const lock_names = [_][]const u8{ "Cargo.lock", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "go.sum", "poetry.lock", "Gemfile.lock", "composer.lock", "flake.lock" };
    for (lock_names) |n| if (std.mem.eql(u8, base, n)) return true;
    if (std.mem.endsWith(u8, base, ".lock")) return true;
    if (std.mem.startsWith(u8, path, "zig-cache/") or std.mem.startsWith(u8, path, ".zig-cache/") or std.mem.indexOf(u8, path, "/zig-cache/") != null or std.mem.indexOf(u8, path, "/.zig-cache/") != null) return true;
    for (patterns) |p| if (globMatch(p, path)) return true;
    return false;
}

/// The patterns `.gitattributes` text marks `linguist-generated` (or
/// `linguist-generated=true`).
pub fn generatedPatterns(arena: Allocator, gitattributes: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, gitattributes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const pat = it.next() orelse continue;
        while (it.next()) |attr| {
            if (std.mem.eql(u8, attr, "linguist-generated") or std.mem.eql(u8, attr, "linguist-generated=true")) {
                try out.append(arena, pat);
                break;
            }
        }
    }
    return out.items;
}

/// gitattributes-style matching: a pattern without `/` matches the base
/// name; `*` matches within a path segment and `**` across them.
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    var p = pattern;
    if (p.len > 0 and p[0] == '/') p = p[1..];
    const subject = if (std.mem.indexOfScalar(u8, p, '/') == null) std.fs.path.basenamePosix(path) else path;
    return matchAt(p, subject);
}

fn matchAt(p: []const u8, s: []const u8) bool {
    if (p.len == 0) return s.len == 0;
    if (std.mem.startsWith(u8, p, "**")) {
        var rest = p[2..];
        if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (matchAt(rest, s[i..])) return true;
        }
        return false;
    }
    if (p[0] == '*') {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (matchAt(p[1..], s[i..])) return true;
            if (i < s.len and s[i] == '/') return false;
        }
        return false;
    }
    if (s.len == 0) return false;
    if (p[0] != '?' and p[0] != s[0]) return false;
    if (p[0] == '?' and s[0] == '/') return false;
    return matchAt(p[1..], s[1..]);
}

pub const BudgetedDiff = struct {
    text: []const u8,
    stats: Stats,
    /// Hunks replaced by summary lines (generated files count once).
    omitted: u32,
    tokens: u32,
};

/// The unified diff of `files` within `budget` tokens.
pub fn budgetDiff(arena: Allocator, files: []const FileChange, generated: []const []const u8, budget: u32) !BudgetedDiff {
    var diffs = try arena.alloc(FileDiff, files.len);
    var stats: Stats = .{ .files = @intCast(files.len) };
    for (files, 0..) |f, i| {
        diffs[i] = try diffFile(arena, f, 3, isGenerated(f.path, generated));
        stats.insertions += diffs[i].added;
        stats.deletions += diffs[i].removed;
    }

    // Everything, when it fits.
    const Ref = struct { file: u32, hunk: u32, rank: u64, tokens: u32 };
    var refs: std.ArrayList(Ref) = .empty;
    var full: u64 = 0;
    for (diffs, 0..) |d, fi| {
        full += estimateTokens(try header(arena, d.path)) + 1;
        for (d.hunks, 0..) |h, hi| {
            const tok = estimateTokens(h.text);
            full += tok;
            if (d.generated) continue;
            const api: u64 = @intFromBool(touchesPublicApi(h.text));
            try refs.append(arena, .{ .file = @intCast(fi), .hunk = @intCast(hi), .rank = @as(u64, h.added + h.removed) * (1 + api), .tokens = tok });
        }
    }
    const keep = try arena.alloc([]bool, diffs.len);
    for (keep, diffs) |*k, d| {
        k.* = try arena.alloc(bool, d.hunks.len);
        @memset(k.*, !d.generated or full <= budget);
    }
    if (full > budget) {
        // Headers and the summary line of every file are always there.
        var used: u64 = 0;
        for (diffs) |d| used += estimateTokens(try header(arena, d.path)) + 16;
        for (keep) |k| @memset(k, false);
        std.mem.sort(Ref, refs.items, {}, struct {
            fn gt(_: void, x: Ref, y: Ref) bool {
                return x.rank > y.rank or (x.rank == y.rank and (x.file < y.file or (x.file == y.file and x.hunk < y.hunk)));
            }
        }.gt);
        for (refs.items) |r| {
            if (used + r.tokens > budget) continue;
            used += r.tokens;
            keep[r.file][r.hunk] = true;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    var omitted: u32 = 0;
    for (diffs, keep) |d, k| {
        try out.appendSlice(arena, try header(arena, d.path));
        var dropped_add: u32 = 0;
        var dropped_del: u32 = 0;
        var dropped: u32 = 0;
        for (d.hunks, k) |h, kept| {
            if (kept) {
                try out.appendSlice(arena, h.text);
            } else {
                dropped += 1;
                dropped_add += h.added;
                dropped_del += h.removed;
            }
        }
        if (dropped > 0) {
            try out.print(arena, "@@ {s}: +{d} -{d} (omitted{s})\n", .{ d.path, dropped_add, dropped_del, if (d.generated) ", generated" else "" });
            omitted += if (d.generated) 1 else dropped;
        }
    }
    return .{ .text = out.items, .stats = stats, .omitted = omitted, .tokens = estimateTokens(out.items) };
}

fn header(arena: Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "--- a/{s}\n+++ b/{s}\n", .{ path, path });
}

/// Whether a hunk's changed lines declare something public.
fn touchesPublicApi(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or (line[0] != '+' and line[0] != '-')) continue;
        const body = std.mem.trimStart(u8, line[1..], " \t");
        const markers = [_][]const u8{ "pub ", "export ", "public ", "func ", "def " };
        for (markers) |m| if (std.mem.startsWith(u8, body, m)) return true;
    }
    return false;
}

// ---------------------------------------------------------------- tests

const t = std.testing;

test "context: unified hunks" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    var old: std.ArrayList(u8) = .empty;
    var new: std.ArrayList(u8) = .empty;
    for (0..20) |i| {
        try old.print(a.allocator(), "line {d}\n", .{i});
        if (i == 2) try new.appendSlice(a.allocator(), "changed 2\n") else if (i != 15) try new.print(a.allocator(), "line {d}\n", .{i});
    }
    const d = try diffFile(a.allocator(), .{ .path = "f", .base = old.items, .new = new.items }, 3, false);
    try t.expectEqual(@as(usize, 2), d.hunks.len);
    try t.expectEqualStrings("@@ -1,6 +1,6 @@\n line 0\n line 1\n-line 2\n+changed 2\n line 3\n line 4\n line 5\n", d.hunks[0].text);
    try t.expectEqualStrings("@@ -13,7 +13,6 @@\n line 12\n line 13\n line 14\n-line 15\n line 16\n line 17\n line 18\n", d.hunks[1].text);
    try t.expectEqual(@as(u32, 1), d.added);
    try t.expectEqual(@as(u32, 2), d.removed);
    // A new file without a final newline.
    const n = try diffFile(a.allocator(), .{ .path = "g", .new = "x" }, 3, false);
    try t.expectEqualStrings("@@ -0,0 +1,1 @@\n+x\n\\ No newline at end of file\n", n.hunks[0].text);
}

test "context: generated patterns and globs" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const pats = try generatedPatterns(a.allocator(), "# gen\n*.pb.go linguist-generated\ndocs/** -diff\nvendor/** linguist-generated=true\n");
    try t.expectEqual(@as(usize, 2), pats.len);
    try t.expect(isGenerated("api/x.pb.go", pats));
    try t.expect(isGenerated("vendor/a/b.c", pats));
    try t.expect(isGenerated("web/package-lock.json", pats));
    try t.expect(isGenerated("Cargo.lock", pats));
    try t.expect(isGenerated(".zig-cache/o/x", pats));
    try t.expect(!isGenerated("src/main.zig", pats));
    try t.expect(!isGenerated("docs/x.md", pats));
    try t.expect(globMatch("src/*.zig", "src/a.zig"));
    try t.expect(!globMatch("src/*.zig", "src/x/a.zig"));
    try t.expect(globMatch("src/**/*.zig", "src/x/y/a.zig"));
}

test "context: truncate and estimate" {
    try t.expectEqual(@as(u32, 2), estimateTokens("1234567"));
    const s = "first line\nsecond line\nthird line\n";
    try t.expectEqualStrings("first line\nsecond line\n", truncate(s, 7));
    try t.expectEqualStrings(s, truncate(s, 100));
}
