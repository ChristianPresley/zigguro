//! The section outline of a Markdown document (E13.F04.S01.T01): ATX and
//! setext headings outside fenced code and front matter, each section
//! running from its heading to the next heading of the same or a higher
//! level. Sections have a positional id (`2.1`: the first child of the
//! second top section) and a GitHub-style slug (`-1`, `-2` for repeats);
//! tools accept either.
//!
//! The outline is a line scan (about 7 ms for a 1 MB document of 10,000
//! sections, `docs/outline_1mb`), rebuilt
//! when the document's version changes.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Range = struct {
    start: u32,
    end: u32,

    pub fn contains(r: Range, at: u32) bool {
        return at >= r.start and at < r.end;
    }

    pub fn len(r: Range) u32 {
        return r.end - r.start;
    }
};

pub const Section = struct {
    /// 1-based positions from the top, e.g. {2, 1}.
    path: []const u16,
    /// `2.1`.
    id: []const u8,
    slug: []const u8,
    level: u3,
    title: []const u8,
    /// From the heading to the next heading of the same or a higher level.
    range: Range,
    /// The end of the heading line(s).
    heading_end: u32,
    /// Words in `range` (children included).
    words: u32,
    parent: ?u32,
    /// Indices into the outline.
    children: []const u32,

    /// Where the section's own text ends: its first child, or its end.
    pub fn ownEnd(s: *const Section, all: []const Section) u32 {
        return if (s.children.len > 0) all[s.children[0]].range.start else s.range.end;
    }
};

/// The outline of `text`, in document order; everything in `a`.
pub fn outline(a: Allocator, text: []const u8) Allocator.Error![]Section {
    var heads: std.ArrayList(Head) = .empty;
    try scan(a, text, &heads);
    const out = try a.alloc(Section, heads.items.len);
    var slugs: std.StringHashMapUnmanaged(u32) = .empty;
    // Positional ids: a stack of (level, index into out).
    var stack: std.ArrayList(u32) = .empty;
    var root_count: u16 = 0;
    var child_counts = try a.alloc(u16, heads.items.len);
    @memset(child_counts, 0);
    var children = try a.alloc(std.ArrayList(u32), heads.items.len);
    for (children) |*c| c.* = .empty;
    for (heads.items, 0..) |h, i| {
        while (stack.items.len > 0 and heads.items[stack.items[stack.items.len - 1]].level >= h.level) _ = stack.pop();
        const parent: ?u32 = if (stack.items.len > 0) stack.items[stack.items.len - 1] else null;
        var path: std.ArrayList(u16) = .empty;
        if (parent) |p| {
            try path.appendSlice(a, out[p].path);
            child_counts[p] += 1;
            try path.append(a, child_counts[p]);
            try children[p].append(a, @intCast(i));
        } else {
            root_count += 1;
            try path.append(a, root_count);
        }
        var end: u32 = @intCast(text.len);
        for (heads.items[i + 1 ..]) |n| if (n.level <= h.level) {
            end = n.start;
            break;
        };
        const base = try slugify(a, h.title);
        const seen = try slugs.getOrPut(a, base);
        const slug = if (seen.found_existing) blk: {
            seen.value_ptr.* += 1;
            break :blk try std.fmt.allocPrint(a, "{s}-{d}", .{ base, seen.value_ptr.* });
        } else blk: {
            seen.value_ptr.* = 0;
            break :blk base;
        };
        out[i] = .{
            .path = path.items,
            .id = try idText(a, path.items),
            .slug = slug,
            .level = h.level,
            .title = h.title,
            .range = .{ .start = h.start, .end = end },
            .heading_end = h.end,
            .words = countWords(text[h.start..end]),
            .parent = parent,
            .children = &.{},
        };
        try stack.append(a, @intCast(i));
    }
    for (out, children) |*s, c| s.children = c.items;
    return out;
}

/// The section `ref` names: a positional id (`2.1`), a slug, or `#slug`.
pub fn find(sections: []const Section, ref: []const u8) ?u32 {
    const r = std.mem.trim(u8, ref, " ");
    const key = if (std.mem.startsWith(u8, r, "#")) r[1..] else r;
    for (sections, 0..) |s, i| if (std.mem.eql(u8, s.id, key)) return @intCast(i);
    for (sections, 0..) |s, i| if (std.mem.eql(u8, s.slug, key)) return @intCast(i);
    for (sections, 0..) |s, i| if (std.ascii.eqlIgnoreCase(s.title, key)) return @intCast(i);
    return null;
}

/// The innermost section containing byte `at`.
pub fn sectionAt(sections: []const Section, pos: u32) ?u32 {
    var best: ?u32 = null;
    for (sections, 0..) |s, i| if (s.range.contains(pos)) {
        best = @intCast(i);
    };
    return best;
}

fn idText(a: Allocator, path: []const u16) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (path, 0..) |p, i| try out.print(a, "{s}{d}", .{ if (i == 0) "" else ".", p });
    return out.items;
}

/// GitHub's heading anchors: lower case, spaces to `-`, punctuation other
/// than `-` and `_` dropped (non-ASCII kept).
pub fn slugify(a: Allocator, title: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (title) |c| {
        if (c >= 0x80 or std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            try out.append(a, std.ascii.toLower(c));
        } else if (c == ' ') try out.append(a, '-');
    }
    return out.items;
}

pub fn countWords(text: []const u8) u32 {
    var n: u32 = 0;
    var in_word = false;
    for (text) |c| {
        const ws = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (!ws and !in_word) n += 1;
        in_word = !ws;
    }
    return n;
}

const Head = struct { start: u32, end: u32, level: u3, title: []const u8 };

fn scan(a: Allocator, text: []const u8, heads: *std.ArrayList(Head)) Allocator.Error!void {
    var pos: usize = frontMatterEnd(text);
    var fence: ?struct { ch: u8, n: usize } = null;
    // The paragraph a setext underline would turn into a heading.
    var para_start: ?usize = null;
    while (pos < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n');
        const line_end = nl orelse text.len;
        const next = if (nl) |k| k + 1 else text.len;
        const line = std.mem.trimEnd(u8, text[pos..line_end], "\r");
        defer pos = next;
        const indent = leadingColumns(line);
        const body = std.mem.trimStart(u8, line, " \t");
        if (fence) |f| {
            const run = runOf(body, f.ch);
            if (indent <= 3 and run >= f.n and std.mem.trim(u8, body[run..], " \t").len == 0) fence = null;
            continue;
        }
        if (indent <= 3 and (runOf(body, '`') >= 3 or runOf(body, '~') >= 3)) {
            const ch = body[0];
            const n = runOf(body, ch);
            // A backtick fence's info string has no backticks.
            if (ch == '~' or std.mem.indexOfScalar(u8, body[n..], '`') == null) {
                fence = .{ .ch = ch, .n = n };
                para_start = null;
                continue;
            }
        }
        if (std.mem.trim(u8, line, " \t").len == 0) {
            para_start = null;
            continue;
        }
        if (indent <= 3) {
            if (atx(body)) |h| {
                try heads.append(a, .{ .start = @intCast(pos), .end = @intCast(line_end), .level = h.level, .title = h.title });
                para_start = null;
                continue;
            }
            if (para_start) |ps| if (setextLevel(body)) |lvl| {
                const title = try joinLines(a, text[ps..pos]);
                try heads.append(a, .{ .start = @intCast(ps), .end = @intCast(line_end), .level = lvl, .title = title });
                para_start = null;
                continue;
            };
        }
        if (para_start == null) {
            // Indented code, quotes and list items never start a setext heading.
            const plain = indent <= 3 and body.len > 0 and body[0] != '>' and !isListItem(body) and !isBreak(body);
            if (plain) para_start = pos;
        }
    }
}

fn frontMatterEnd(text: []const u8) usize {
    if (!std.mem.startsWith(u8, text, "---\n") and !std.mem.startsWith(u8, text, "---\r\n")) return 0;
    var pos: usize = std.mem.indexOfScalar(u8, text, '\n').? + 1;
    while (pos < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n');
        const line = std.mem.trimEnd(u8, text[pos .. nl orelse text.len], "\r ");
        const next = if (nl) |k| k + 1 else text.len;
        if (std.mem.eql(u8, line, "---") or std.mem.eql(u8, line, "...")) return next;
        pos = next;
    }
    return 0;
}

fn atx(body: []const u8) ?struct { level: u3, title: []const u8 } {
    const n = runOf(body, '#');
    if (n == 0 or n > 6) return null;
    if (n < body.len and body[n] != ' ' and body[n] != '\t') return null;
    var title = std.mem.trim(u8, body[n..], " \t");
    // An optional closing sequence of `#`s, preceded by a space.
    const close = std.mem.trimEnd(u8, title, "#");
    if (close.len == 0) {
        title = "";
    } else if (close.len < title.len and (close[close.len - 1] == ' ' or close[close.len - 1] == '\t')) {
        title = std.mem.trimEnd(u8, close, " \t");
    }
    return .{ .level = @intCast(n), .title = title };
}

fn setextLevel(body: []const u8) ?u3 {
    const t = std.mem.trimEnd(u8, body, " \t");
    if (t.len == 0) return null;
    const ch = t[0];
    if (ch != '=' and ch != '-') return null;
    if (runOf(t, ch) != t.len) return null;
    return if (ch == '=') 1 else 2;
}

fn isBreak(body: []const u8) bool {
    const t = std.mem.trimEnd(u8, body, " \t");
    if (t.len < 3) return false;
    const ch = t[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    var n: usize = 0;
    for (t) |c| {
        if (c == ch) n += 1 else if (c != ' ' and c != '\t') return false;
    }
    return n >= 3;
}

fn isListItem(body: []const u8) bool {
    if (body.len >= 2 and (body[0] == '-' or body[0] == '*' or body[0] == '+') and (body[1] == ' ' or body[1] == '\t')) return true;
    var i: usize = 0;
    while (i < body.len and i < 9 and std.ascii.isDigit(body[i])) i += 1;
    return i > 0 and i + 1 < body.len and (body[i] == '.' or body[i] == ')') and body[i + 1] == ' ';
}

fn leadingColumns(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        if (c == ' ') n += 1 else if (c == '\t') n += 4 - n % 4 else break;
    }
    return n;
}

fn runOf(s: []const u8, ch: u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] == ch) n += 1;
    return n;
}

fn joinLines(a: Allocator, para: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, para, "\r\n");
    while (it.next()) |l| {
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, std.mem.trim(u8, l, " \t"));
    }
    return out.items;
}

/// One edit (a single undo step) that moves section `from` with its
/// subsections to just before section `before` (null: the end).
pub const Move = struct { start: u32, old_len: u32, new_text: []const u8 };

/// The edit moving section `from` before `before`, or null when it would
/// not move (into itself, or where it already is).
pub fn moveSection(a: Allocator, text: []const u8, all: []const Section, from: u32, before: ?u32) Allocator.Error!?Move {
    const r = all[from].range;
    const to: u32 = if (before) |b| all[b].range.start else @intCast(text.len);
    if (to >= r.start and to <= r.end) return null;
    var moved = text[r.start..r.end];
    // The last section may lack a final newline.
    if (moved.len > 0 and moved[moved.len - 1] != '\n') moved = try std.mem.concat(a, u8, &.{ moved, "\n" });
    if (to < r.start) {
        const new = try std.mem.concat(a, u8, &.{ moved, text[to..r.start] });
        return .{ .start = to, .old_len = r.end - to, .new_text = new };
    }
    const tail = text[r.end..to];
    const sep: []const u8 = if (tail.len > 0 and tail[tail.len - 1] != '\n') "\n" else "";
    return .{ .start = r.start, .old_len = to - r.start, .new_text = try std.mem.concat(a, u8, &.{ tail, sep, moved }) };
}
