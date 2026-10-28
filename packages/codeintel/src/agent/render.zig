//! What the `lsp_*` tools show the model (E07.F05.S01.T03): compiler-style
//! text that is the same on every run and platform. Paths are relative to
//! the workspace with `/` separators and lines are 1-based. Locations are
//! grouped by file, in path then line order, each as `path:line:column`
//! with a short excerpt (`NN│ code`, target lines marked `>`; excerpts
//! that meet are merged). Output stops at a token
//! budget (estimated as bytes / 4) at a file boundary, with a summary of
//! what was left out. `structuredJson` is the same list for MCP structured
//! content.

const std = @import("std");
const zg_core = @import("zg_core");

const Allocator = std.mem.Allocator;

pub const RenderOpts = struct {
    token_budget: u32 = 4000,
    /// Lines shown before and after each target.
    context_lines: u8 = 2,
    /// Paths under it are shown relative to it.
    root: []const u8 = "",
};

/// A location to show. Lines are 0-based; columns are 0-based characters
/// (Unicode scalar values).
pub const Target = struct {
    /// Absolute path, or a URI for documents that are not files.
    path: []const u8,
    line: u32,
    column: u32,
    end_line: u32,
    end_column: u32,
    kind: []const u8 = "",
    name: []const u8 = "",
};

/// A file's text, for excerpts (null: none, then only locations show).
pub const TextLookup = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, path: []const u8) ?[]const u8,
};

/// What the targets are, for headers and summaries.
pub const Noun = struct { one: []const u8, many: []const u8 };

/// Longest excerpt line shown, in bytes.
const max_line_bytes = 200;

/// `path` as shown: relative to `root` when under it, `/` separators.
pub fn shownPath(arena: Allocator, root: []const u8, path: []const u8) Allocator.Error![]const u8 {
    var p = path;
    const r = std.mem.trimEnd(u8, root, "/\\");
    if (r.len > 0 and p.len > r.len + 1 and std.mem.startsWith(u8, p, r) and (p[r.len] == '/' or p[r.len] == '\\')) p = p[r.len + 1 ..];
    if (std.mem.indexOfScalar(u8, p, '\\') == null) return p;
    const out = try arena.dupe(u8, p);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn lessTarget(_: void, a: Shown, b: Shown) bool {
    switch (std.mem.order(u8, a.shown, b.shown)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.t.line != b.t.line) return a.t.line < b.t.line;
    return a.t.column < b.t.column;
}

const Shown = struct { t: Target, shown: []const u8 };

/// The targets, grouped by file with excerpts, under a header such as
/// "3 references in 2 files:". `total` counts targets left out before
/// these (a `limit`); 0 means `ts.len`.
pub fn renderTargets(arena: Allocator, ts: []const Target, o: RenderOpts, text: ?TextLookup, noun: Noun, total_in: usize) Allocator.Error![]const u8 {
    var list = try arena.alloc(Shown, ts.len);
    for (ts, list) |t, *s| s.* = .{ .t = t, .shown = try shownPath(arena, o.root, t.path) };
    std.mem.sort(Shown, list, {}, lessTarget);
    // Duplicates (several servers, or a declaration listed twice) once.
    var n: usize = 0;
    for (list) |s| {
        if (n > 0 and std.mem.eql(u8, list[n - 1].shown, s.shown) and list[n - 1].t.line == s.t.line and list[n - 1].t.column == s.t.column) continue;
        list[n] = s;
        n += 1;
    }
    // Duplicates do not count; those past a limit do.
    const total = if (total_in > ts.len) total_in - (ts.len - n) else n;
    list = list[0..n];

    var files: usize = 0;
    for (list, 0..) |s, i| {
        if (i == 0 or !std.mem.eql(u8, list[i - 1].shown, s.shown)) files += 1;
    }
    var out: std.ArrayList(u8) = .empty;
    if (list.len == 0) {
        try out.print(arena, "No {s}.", .{noun.many});
        return out.items;
    }
    try out.print(arena, "{d} {s} in {d} file{s}:", .{ total, if (total == 1) noun.one else noun.many, files, plural(files) });
    const budget_bytes = @as(usize, o.token_budget) * 4;
    var shown_targets: usize = 0;
    var shown_files: usize = 0;
    var complete_files: usize = 0;
    var i: usize = 0;
    while (i < list.len) {
        var j = i + 1;
        while (j < list.len and std.mem.eql(u8, list[j].shown, list[i].shown)) j += 1;
        var group: std.ArrayList(u8) = .empty;
        const fit = try renderGroup(arena, &group, list[i..j], o, text, if (shown_files == 0) budget_bytes -| out.items.len else std.math.maxInt(usize));
        if (shown_files > 0 and out.items.len + group.items.len > budget_bytes) break;
        try out.appendSlice(arena, group.items);
        shown_targets += fit;
        shown_files += 1;
        if (fit < j - i) break;
        complete_files += 1;
        i = j;
    }
    const left = total - shown_targets;
    if (left > 0) {
        try out.print(arena, "\n… {d} more {s}", .{ left, if (left == 1) noun.one else noun.many });
        // Past `limit`, which files they are in is not known.
        if (total > list.len) {
            try out.appendSlice(arena, " (raise limit to see them)");
        } else {
            const left_files = files - complete_files;
            try out.print(arena, " in {d} file{s}", .{ left_files, plural(left_files) });
        }
    }
    return out.items;
}

/// One file's targets with excerpts; returns how many fit in `room`
/// bytes (at least one).
fn renderGroup(arena: Allocator, out: *std.ArrayList(u8), g: []const Shown, o: RenderOpts, text: ?TextLookup, room: usize) Allocator.Error!usize {
    const src: ?[]const u8 = if (text) |t| t.get(t.ctx, g[0].t.path) else null;
    const file = src orelse {
        for (g, 0..) |s, k| {
            if (k > 0 and out.items.len > room) return k;
            try out.print(arena, "\n{s}:{d}:{d}", .{ s.shown, s.t.line + 1, s.t.column + 1 });
            if (s.t.name.len > 0) try out.print(arena, ": {s}", .{s.t.name});
        }
        return g.len;
    };
    const lines = try lineStarts(arena, file, g[g.len - 1].t.line +| o.context_lines +| 1);
    const width = digits(@min(lines.len, g[g.len - 1].t.line + o.context_lines + 1));
    var shown_to: ?u32 = null;
    for (g, 0..) |s, k| {
        if (k > 0 and out.items.len > room) return k;
        const first: u32 = s.t.line -| o.context_lines;
        const last: u32 = @intCast(@min(@as(usize, s.t.line) + o.context_lines, lines.len -| 1));
        var from = first;
        // An excerpt starts with its target's place; one that runs into
        // the last continues it.
        if (shown_to != null and first <= shown_to.? + 1) {
            from = shown_to.? + 1;
        } else {
            try out.print(arena, "\n{s}:{d}:{d}", .{ s.shown, s.t.line + 1, s.t.column + 1 });
            if (s.t.name.len > 0) try out.print(arena, ": {s}", .{s.t.name});
        }
        var l = from;
        while (l <= last and l < lines.len) : (l += 1) {
            const mark: u8 = if (isTarget(g, l)) '>' else ' ';
            const code = lineText(file, lines, l);
            try out.print(arena, "\n{c} {d:>[2]}│", .{ mark, l + 1, width });
            if (code.len > 0) try out.print(arena, " {s}", .{clip(code)});
            if (code.len > max_line_bytes) try out.appendSlice(arena, " …");
            shown_to = l;
        }
        if (s.t.line >= lines.len) try out.print(arena, "\n> {d:>[1]}│ (past the end of the file)", .{ s.t.line + 1, width });
    }
    return g.len;
}

fn isTarget(g: []const Shown, l: u32) bool {
    for (g) |s| if (s.t.line == l) return true;
    return false;
}

/// The first `max_line_bytes` of `code`, cut at a character boundary.
fn clip(code: []const u8) []const u8 {
    if (code.len <= max_line_bytes) return code;
    var e: usize = max_line_bytes;
    while (e > 0 and code[e] & 0xC0 == 0x80) e -= 1;
    return code[0..e];
}

/// The starts of the first `max` lines of `text` (fewer when it ends).
fn lineStarts(arena: Allocator, text: []const u8, max: usize) Allocator.Error![]const usize {
    var out: std.ArrayList(usize) = .empty;
    try out.append(arena, 0);
    var i: usize = 0;
    while (out.items.len < max) {
        i = (std.mem.indexOfScalarPos(u8, text, i, '\n') orelse break) + 1;
        if (i == text.len) break;
        try out.append(arena, i);
    }
    return out.items;
}

fn lineText(text: []const u8, starts: []const usize, l: usize) []const u8 {
    const a = starts[l];
    const b = std.mem.indexOfScalarPos(u8, text, a, '\n') orelse text.len;
    return std.mem.trimEnd(u8, text[a..b], "\r");
}

/// A server column (in `enc` units) on `line_text` as characters.
pub fn charColumn(line_text: []const u8, col: u32, enc: zg_core.utf8.Encoding) u32 {
    if (enc == .utf32) return col;
    const b = zg_core.utf8.columnToByte(line_text, col, enc);
    return @intCast(zg_core.utf8.byteToColumn(line_text, b, .utf32));
}

/// The start of every line of `text`.
pub fn lineIndex(arena: Allocator, text: []const u8) Allocator.Error![]const usize {
    return lineStarts(arena, text, std.math.maxInt(usize));
}

/// Line `l` (0-based) through `lineIndex`'s `starts` (empty past the end).
pub fn lineAt(text: []const u8, starts: []const usize, l: usize) []const u8 {
    if (l >= starts.len) return "";
    return lineText(text, starts, l);
}

/// The text of 0-based `line` of `text` (empty past the end).
pub fn lineOf(text: []const u8, line: u32) []const u8 {
    var start: usize = 0;
    var l: u32 = 0;
    while (l < line) : (l += 1) {
        start = (std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return "") + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return std.mem.trimEnd(u8, text[start..end], "\r");
}

fn digits(n: usize) usize {
    var d: usize = 1;
    var x = n;
    while (x >= 10) : (x /= 10) d += 1;
    return d;
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// `[{path, line, column, end_line, end_column, kind, name}]`, 1-based,
/// in the text's order.
pub fn structuredJson(arena: Allocator, ts: []const Target, o: RenderOpts) Allocator.Error![]const u8 {
    const J = struct { path: []const u8, line: u32, column: u32, end_line: u32, end_column: u32, kind: []const u8, name: []const u8 };
    const list = try arena.alloc(Shown, ts.len);
    for (ts, list) |t, *s| s.* = .{ .t = t, .shown = try shownPath(arena, o.root, t.path) };
    std.mem.sort(Shown, list, {}, lessTarget);
    const out = try arena.alloc(J, list.len);
    for (list, out) |s, *j| j.* = .{ .path = s.shown, .line = s.t.line + 1, .column = s.t.column + 1, .end_line = s.t.end_line + 1, .end_column = s.t.end_column + 1, .kind = s.t.kind, .name = s.t.name };
    return std.json.Stringify.valueAlloc(arena, out, .{});
}

// ------------------------------------------------------------ diagnostics

pub const AgentDiag = struct {
    path: []const u8,
    /// 0-based line and character.
    line: u32,
    column: u32,
    severity: []const u8,
    message: []const u8,
    source: []const u8 = "",
    code: []const u8 = "",
};

/// `src/a.zig:12:5: error: expected type 'u32', found '[]const u8' [zls]`,
/// one per line (first message line only), sorted by path and position,
/// within the budget; the rest summarized.
pub fn renderDiagnostics(arena: Allocator, ds: []const AgentDiag, o: RenderOpts) Allocator.Error![]const u8 {
    const S = struct { d: AgentDiag, shown: []const u8 };
    const list = try arena.alloc(S, ds.len);
    for (ds, list) |d, *s| s.* = .{ .d = d, .shown = try shownPath(arena, o.root, d.path) };
    std.mem.sort(S, list, {}, struct {
        fn lt(_: void, a: S, b: S) bool {
            switch (std.mem.order(u8, a.shown, b.shown)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
            if (a.d.line != b.d.line) return a.d.line < b.d.line;
            return a.d.column < b.d.column;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    const budget = @as(usize, o.token_budget) * 4;
    for (list, 0..) |s, i| {
        if (i > 0 and out.items.len > budget) {
            try out.print(arena, "\n… {d} more", .{list.len - i});
            break;
        }
        if (i > 0) try out.append(arena, '\n');
        try writeDiagnostic(arena, &out, s.shown, s.d);
    }
    return out.items;
}

pub fn writeDiagnostic(arena: Allocator, out: *std.ArrayList(u8), shown: []const u8, d: AgentDiag) Allocator.Error!void {
    try out.print(arena, "{s}:{d}:{d}: {s}: ", .{ shown, d.line + 1, d.column + 1, d.severity });
    try out.appendSlice(arena, d.message[0 .. std.mem.indexOfScalar(u8, d.message, '\n') orelse d.message.len]);
    if (d.code.len > 0 or d.source.len > 0) try out.print(arena, " [{s}{s}{s}]", .{ d.source, if (d.code.len > 0 and d.source.len > 0) " " else "", d.code });
}

// ------------------------------------------------------------------ hover

/// Hover Markdown as plain text: code fences kept as they are; emphasis,
/// escapes, heading marks and rules dropped; links as `text (url)`; runs
/// of blank lines collapsed.
pub fn markdownToText(arena: Allocator, md: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_fence = false;
    // A blank line is owed before the next text.
    var blank = false;
    var lines = std.mem.splitScalar(u8, md, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const t = std.mem.trimStart(u8, line, " ");
        const fence = std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~");
        if (in_fence or fence) {
            if (fence) in_fence = !in_fence;
            try sep(arena, &out, &blank);
            try out.appendSlice(arena, line);
            continue;
        }
        if (isRule(t)) continue;
        if (t.len == 0) {
            blank = true;
            continue;
        }
        try sep(arena, &out, &blank);
        var body = t;
        while (body.len > 0 and body[0] == '#') body = body[1..];
        body = if (body.len < t.len) std.mem.trimStart(u8, body, " ") else line;
        try inline_(arena, &out, body);
    }
    return out.items;
}

/// Starts a line: after a blank line when one is owed.
fn sep(arena: Allocator, out: *std.ArrayList(u8), blank: *bool) Allocator.Error!void {
    if (out.items.len > 0) try out.appendSlice(arena, if (blank.*) "\n\n" else "\n");
    blank.* = false;
}

fn isRule(t: []const u8) bool {
    if (t.len < 3) return false;
    const c = t[0];
    if (c != '-' and c != '*' and c != '_') return false;
    for (t) |x| if (x != c and x != ' ') return false;
    return true;
}

/// One line's inline Markdown; backtick code spans are kept verbatim.
fn inline_(arena: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '`') {
            const end = std.mem.indexOfScalarPos(u8, s, i + 1, '`') orelse s.len - 1;
            try out.appendSlice(arena, s[i .. end + 1]);
            i = end + 1;
            continue;
        }
        if (c == '\\' and i + 1 < s.len and std.ascii.isPunctuation(s[i + 1])) {
            try out.append(arena, s[i + 1]);
            i += 2;
            continue;
        }
        if (c == '*' or c == '_') {
            // `**bold**` and `__bold__` marks.
            if (i + 1 < s.len and s[i + 1] == c) {
                i += 2;
                continue;
            }
            const in_word = i > 0 and i + 1 < s.len and std.ascii.isAlphanumeric(s[i - 1]) and std.ascii.isAlphanumeric(s[i + 1]);
            if (in_word) {
                // snake_case, a*b
                try out.append(arena, c);
            } else if (c == '*' and i + 1 < s.len and s[i + 1] == ' ' and std.mem.trim(u8, s[0..i], " ").len == 0) {
                // A list bullet.
                try out.append(arena, '-');
            }
            i += 1;
            continue;
        }
        if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, s, i, ']')) |close| {
                if (close + 1 < s.len and s[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, s, close, ')')) |paren| {
                        const label = s[i + 1 .. close];
                        const url = s[close + 2 .. paren];
                        try inline_(arena, out, label);
                        if (url.len > 0 and !std.mem.eql(u8, url, label)) try out.print(arena, " ({s})", .{url});
                        i = paren + 1;
                        continue;
                    }
                }
            }
        }
        try out.append(arena, c);
        i += 1;
    }
}
