//! The note extractor (E08.F06.S01.T01): a pure function from note bytes
//! to `NoteMeta`. Pure and allocation-only, so indexer workers call it in
//! parallel.
//!
//! It runs its own line scanner instead of E04's Markdown AST: the AST
//! keeps inline ranges in its prefix-stripped `content` buffer, while the
//! index and the link-rewrite engine need ranges in the note's own bytes,
//! and a full parse would cost more than the 0.5 ms budget for 20 KB. The
//! scanner knows enough CommonMark/GFM block structure to keep tags and
//! links out of code: fenced and indented code, `$$` math, HTML and `%%`
//! comments, ATX and setext headings, list items, block quotes, thematic
//! breaks. Inline, it skips code spans, escapes, inline math and URLs.

const std = @import("std");
const zg_core = @import("zg_core");
const fm = @import("zg_frontmatter").frontmatter;
const note = @import("note.zig");
const tags = @import("tags.zig");
const vault = @import("vault.zig");

const Allocator = std.mem.Allocator;
const NoteMeta = note.NoteMeta;

/// Byte ranges of `bytes` that are code, math or comments (and the
/// frontmatter), in `gpa`: text there is never a mention or a tag.
pub fn excludedRanges(gpa: Allocator, bytes: []const u8) ![]const [2]u32 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var out: std.ArrayList([2]u32) = .empty;
    errdefer out.deinit(gpa);
    var x: Extractor = .{ .a = arena_state.allocator(), .src = bytes, .code = &out, .code_gpa = gpa };
    _ = try x.run("x.md");
    return out.toOwnedSlice(gpa);
}

/// Extracts the metadata of one note. Allocates everything in `gpa`
/// (normally an arena per note); nothing in the result points into
/// `bytes`. `path` gives the title fallback (the file stem).
pub fn extract(gpa: Allocator, bytes: []const u8, path: []const u8, cfg: *const vault.VaultConfig) !NoteMeta {
    _ = cfg;
    var x: Extractor = .{ .a = gpa, .src = bytes };
    return x.run(path);
}

/// The type a property's value implies, before the vault registry.
pub fn inferType(name: []const u8, node: fm.Node) note.PropertyType {
    if (eqlAny(name, &.{ "tags", "tag" })) return .tags;
    if (eqlAny(name, &.{ "aliases", "alias" })) return .aliases;
    if (eqlAny(name, &.{ "cssclasses", "cssclass" })) return .list;
    return switch (node.value) {
        .list => .list,
        .bool => .checkbox,
        .int, .float => .number,
        .date => .date,
        .datetime => .datetime,
        .string => .text,
        .null, .map, .raw => .unknown,
    };
}

fn eqlAny(s: []const u8, opts: []const []const u8) bool {
    for (opts) |o| if (std.ascii.eqlIgnoreCase(s, o)) return true;
    return false;
}

/// Deep-copies `n` into `a`.
pub fn cloneNode(a: Allocator, n: fm.Node) !fm.Node {
    var out = n;
    out.value = switch (n.value) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .raw => |s| .{ .raw = try a.dupe(u8, s) },
        .list => |items| blk: {
            const l = try a.alloc(fm.Node, items.len);
            for (items, l) |it, *d| d.* = try cloneNode(a, it);
            break :blk .{ .list = l };
        },
        .map => |pairs| blk: {
            const m = try a.alloc(fm.Pair, pairs.len);
            for (pairs, m) |p, *d| d.* = .{ .key = try a.dupe(u8, p.key), .key_src = p.key_src, .node = try cloneNode(a, p.node), .span = p.span };
            break :blk .{ .map = m };
        },
        else => n.value,
    };
    return out;
}

/// The text of a scalar node (`raw` and non-strings as their source).
pub fn scalarText(src: []const u8, n: fm.Node) ?[]const u8 {
    return switch (n.value) {
        .string => |s| s,
        .null, .list, .map => null,
        else => src[n.src[0]..n.src[1]],
    };
}

const Fence = struct { ch: u8, len: u32 };

const Extractor = struct {
    a: Allocator,
    src: []const u8,
    tags: std.ArrayList(note.TagRef) = .empty,
    headings: std.ArrayList(note.Heading) = .empty,
    blocks: std.ArrayList(note.BlockId) = .empty,
    links: std.ArrayList(note.Link) = .empty,
    tasks: std.ArrayList(note.Task) = .empty,
    external: std.ArrayList([]const u8) = .empty,
    words: u32 = 0,
    /// A `%%` or `<!--` comment continues on the next line.
    comment: enum { none, percent, html } = .none,
    /// The line being scanned (link context).
    cur_line: [2]u32 = .{ 0, 0 },
    /// `excludedRanges`: where code, math and comments go.
    code: ?*std.ArrayList([2]u32) = null,
    code_gpa: Allocator = undefined,

    fn excluded(x: *Extractor, a: u32, b: u32) !void {
        const c = x.code orelse return;
        if (c.items.len > 0 and c.items[c.items.len - 1][1] >= a) {
            c.items[c.items.len - 1][1] = @max(c.items[c.items.len - 1][1], b);
            return;
        }
        try c.append(x.code_gpa, .{ a, b });
    }

    fn run(x: *Extractor, path: []const u8) !NoteMeta {
        var props: std.ArrayList(note.Property) = .empty;
        var aliases: std.ArrayList([]const u8) = .empty;
        var title: ?[]const u8 = null;
        var fm_range: ?[2]u32 = null;
        var fm_diags: u32 = 0;
        var body_start: u32 = if (std.mem.startsWith(u8, x.src, "\xEF\xBB\xBF")) 3 else 0;
        if (fm.findFrontmatter(x.src)) |loc| {
            fm_range = loc.block;
            try x.excluded(loc.block[0], loc.block[1]);
            body_start = loc.block[1];
            var arena_state: std.heap.ArenaAllocator = .init(x.a);
            defer arena_state.deinit();
            var diag: zg_core.report.Diagnostics = .init(arena_state.allocator());
            const root = try fm.parseRange(arena_state.allocator(), x.src, loc.body, &diag);
            fm_diags = @intCast(diag.messages.items.len + diag.dropped);
            if (root.value == .map) for (root.value.map) |p| {
                const node = try cloneNode(x.a, p.node);
                const ty = inferType(p.key, node);
                try props.append(x.a, .{ .name = try x.a.dupe(u8, p.key), .ty = ty, .node = node });
                switch (ty) {
                    .tags => try x.propertyTags(node),
                    .aliases => try x.propertyAliases(&aliases, node),
                    else => if (std.ascii.eqlIgnoreCase(p.key, "title") and node.value == .string and node.value.string.len > 0) {
                        title = node.value.string;
                    },
                }
            };
        }
        try x.scanBody(body_start);
        if (title == null) {
            for (x.headings.items) |h| if (h.level == 1) {
                title = h.text;
                break;
            };
        }
        return .{
            .title = title orelse try x.a.dupe(u8, stem(path)),
            .aliases = aliases.items,
            .tags = x.tags.items,
            .props = props.items,
            .headings = x.headings.items,
            .blocks = x.blocks.items,
            .links = x.links.items,
            .tasks = x.tasks.items,
            .external_links = x.external.items,
            .word_count = x.words,
            .fm_range = fm_range,
            .fm_diagnostics = fm_diags,
        };
    }

    fn propertyTags(x: *Extractor, node: fm.Node) !void {
        switch (node.value) {
            .list => |items| for (items) |it| if (scalarText(x.src, it)) |s| try x.addPropertyTag(s, it.src),
            .string => |s| {
                // `tags: a, b` and `tags: a b` (compatibility).
                var it = std.mem.tokenizeAny(u8, s, ", \t");
                while (it.next()) |t| try x.addPropertyTag(t, node.src);
            },
            else => if (scalarText(x.src, node)) |s| try x.addPropertyTag(s, node.src),
        }
    }

    fn addPropertyTag(x: *Extractor, raw: []const u8, src: [2]u32) !void {
        const t = tags.fromProperty(raw);
        if (t.len == 0) return;
        const display = try x.a.dupe(u8, t);
        try x.tags.append(x.a, .{ .key = try tags.foldKey(x.a, t), .display = display, .src = src, .in_frontmatter = true });
    }

    fn propertyAliases(x: *Extractor, out: *std.ArrayList([]const u8), node: fm.Node) !void {
        switch (node.value) {
            .list => |items| for (items) |it| if (scalarText(x.src, it)) |s| {
                if (s.len > 0) try out.append(x.a, s);
            },
            else => if (scalarText(x.src, node)) |s| if (s.len > 0) try out.append(x.a, s),
        }
    }

    // ---- block structure ----

    fn scanBody(x: *Extractor, from: u32) !void {
        var fence: ?Fence = null;
        var in_math = false;
        var in_indented_code = false;
        var prev_blank = true;
        var in_list = false;
        // The current block (paragraph, list item, quote) and the last
        // finished one, for `^id`.
        var block_start: ?u32 = null;
        var block_end: u32 = 0;
        var prev_block: ?[2]u32 = null;
        // The paragraph a setext underline would turn into a heading.
        var para: ?struct { start: u32, end: u32, line: u32, list: bool } = null;
        var line_no: u32 = countLines(x.src[0..from]);
        var i: u32 = from;
        while (i < x.src.len) : (line_no += 1) {
            const ls = i;
            const nl = std.mem.indexOfScalarPos(u8, x.src, i, '\n');
            var le: u32 = if (nl) |n| @intCast(n) else @intCast(x.src.len);
            i = if (nl) |n| @intCast(n + 1) else @intCast(x.src.len);
            if (le > ls and x.src[le - 1] == '\r') le -= 1;

            // Container prefixes: block quote markers.
            var cs = ls;
            var quoted = false;
            while (true) {
                var k = cs;
                while (k < le and k - cs < 3 and x.src[k] == ' ') k += 1;
                if (k < le and x.src[k] == '>') {
                    quoted = true;
                    cs = k + 1;
                    if (cs < le and x.src[cs] == ' ') cs += 1;
                } else break;
            }
            const line = x.src[cs..le];
            const indent = leadingIndent(line);
            const t = std.mem.trim(u8, line, " \t");
            const ts: u32 = cs + @as(u32, @intCast(std.mem.indexOfNone(u8, line, " \t") orelse line.len));

            x.cur_line = .{ ls, le };
            if (fence) |f| {
                try x.excluded(ls, le);
                if (isFenceClose(t, f)) fence = null;
                continue;
            }
            if (in_math) {
                try x.excluded(ls, le);
                if (std.mem.indexOf(u8, t, "$$") != null) in_math = false;
                continue;
            }
            if (x.comment != .none) {
                const close: []const u8 = if (x.comment == .percent) "%%" else "-->";
                if (std.mem.indexOf(u8, line, close)) |c| {
                    x.comment = .none;
                    const after: u32 = cs + @as(u32, @intCast(c + close.len));
                    try x.excluded(ls, after);
                    try x.scanInline(after, le, line_no);
                } else try x.excluded(ls, le);
                continue;
            }
            if (t.len == 0) {
                if (block_start) |b| prev_block = .{ b, block_end };
                block_start = null;
                para = null;
                prev_blank = true;
                continue;
            }
            if (in_indented_code) {
                if (indent >= 4) {
                    try x.excluded(ls, le);
                    continue;
                }
                in_indented_code = false;
            }
            defer prev_blank = false;
            if (indent < 4 or in_list) {
                if (openFence(t)) |f| {
                    try x.excluded(ls, le);
                    fence = f;
                    if (block_start) |b| prev_block = .{ b, block_end };
                    block_start = null;
                    para = null;
                    continue;
                }
            }
            if (indent >= 4 and prev_blank and !in_list and !quoted) {
                try x.excluded(ls, le);
                in_indented_code = true;
                continue;
            }
            if (std.mem.startsWith(u8, t, "$$")) {
                try x.excluded(ls, le);
                if (!(t.len >= 4 and std.mem.endsWith(u8, t, "$$"))) in_math = true;
                para = null;
                continue;
            }
            if (prev_blank and !quoted and indent == 0 and !isListMarker(t)) in_list = false;

            // ATX heading.
            if (indent < 4) if (atxLevel(t)) |level| {
                var text_s: u32 = ts + level;
                while (text_s < le and (x.src[text_s] == ' ' or x.src[text_s] == '\t')) text_s += 1;
                const text_e = atxTextEnd(x.src, text_s, le);
                try x.scanInline(text_s, text_e, line_no);
                try x.headings.append(x.a, .{ .level = level, .text = try stripInline(x.a, x.src[text_s..text_e]), .src = .{ ls, le }, .line = line_no });
                if (block_start) |b| prev_block = .{ b, block_end };
                prev_block = .{ ls, le };
                block_start = null;
                para = null;
                continue;
            };
            // Setext underline.
            if (para) |p| if (indent < 4 and !p.list) if (isSetext(t)) |level| {
                const text = std.mem.trim(u8, x.src[p.start..p.end], " \t\r\n");
                try x.headings.append(x.a, .{ .level = level, .text = try stripInline(x.a, try joinLines(x.a, text)), .src = .{ p.start, le }, .line = p.line });
                prev_block = .{ p.start, le };
                block_start = null;
                para = null;
                continue;
            };
            if (indent < 4 and isThematicBreak(t)) {
                if (block_start) |b| prev_block = .{ b, block_end };
                block_start = null;
                para = null;
                continue;
            }
            // A lone `^id` names the previous block (or the current one
            // when it directly continues it).
            if (blockIdOnly(t)) {
                const id = t[1..];
                const range: ?[2]u32 = if (!prev_blank and block_start != null) .{ block_start.?, block_end } else prev_block;
                if (range) |r| try x.blocks.append(x.a, .{ .id = try x.a.dupe(u8, id), .range = r, .marker = .{ ts, ts + @as(u32, @intCast(t.len)) }, .line = line_no });
                continue;
            }

            var text_s = ts;
            const item = listItem(t);
            if (item) |li| {
                in_list = true;
                if (block_start) |b| prev_block = .{ b, block_end };
                block_start = ls;
                text_s = ts + li.content;
                if (li.task) |st| {
                    try x.tasks.append(x.a, .{ .status = st, .text = .{ @min(ts + li.content + 4, le), le }, .line = line_no });
                    text_s = @min(ts + li.content + 4, le);
                }
                para = .{ .start = ls, .end = le, .line = line_no, .list = true };
            } else if (block_start == null or prev_blank) {
                if (block_start) |b| prev_block = .{ b, block_end };
                block_start = ls;
                para = .{ .start = ts, .end = le, .line = line_no, .list = false };
            } else if (para) |*p| {
                p.end = le;
            } else para = .{ .start = ts, .end = le, .line = line_no, .list = false };
            block_end = le;

            // A trailing ` ^id` names the current block.
            var scan_end = le;
            if (trailingBlockId(x.src[text_s..le])) |off| {
                const m_s = text_s + off;
                try x.blocks.append(x.a, .{ .id = try x.a.dupe(u8, x.src[m_s + 1 .. le]), .range = .{ block_start.?, le }, .marker = .{ m_s, le }, .line = line_no });
                scan_end = m_s;
            }
            try x.scanInline(text_s, scan_end, line_no);
        }
    }

    // ---- inlines ----

    fn scanInline(x: *Extractor, from: u32, to: u32, line_no: u32) !void {
        const s = x.src;
        x.words += countWords(s[from..to]);
        var i = from;
        while (i < to) {
            const c = s[i];
            switch (c) {
                '\\' => {
                    i += if (i + 1 < to and std.ascii.isPrint(s[i + 1])) 2 else 1;
                    continue;
                },
                '`' => {
                    const e = codeSpanEnd(s, i, to);
                    try x.excluded(i, e);
                    i = e;
                    continue;
                },
                '%' => if (i + 1 < to and s[i + 1] == '%') {
                    if (std.mem.indexOfPos(u8, s[0..to], i + 2, "%%")) |e| {
                        try x.excluded(i, @intCast(e + 2));
                        i = @intCast(e + 2);
                    } else {
                        try x.excluded(i, to);
                        x.comment = .percent;
                        return;
                    }
                    continue;
                },
                '<' => {
                    if (std.mem.startsWith(u8, s[i..to], "<!--")) {
                        if (std.mem.indexOfPos(u8, s[0..to], i + 4, "-->")) |e| {
                            try x.excluded(i, @intCast(e + 3));
                            i = @intCast(e + 3);
                        } else {
                            try x.excluded(i, to);
                            x.comment = .html;
                            return;
                        }
                        continue;
                    }
                    if (autolinkEnd(s, i, to)) |e| {
                        try x.external.append(x.a, try x.a.dupe(u8, s[i + 1 .. e - 1]));
                        i = e;
                        continue;
                    }
                },
                '$' => if (inlineMathEnd(s, i, to)) |e| {
                    try x.excluded(i, e);
                    i = e;
                    continue;
                },
                '!' => if (i + 1 < to and s[i + 1] == '[') {
                    if (i + 2 < to and s[i + 2] == '[') {
                        if (try x.wikilink(i + 1, to, true, line_no)) |e| {
                            i = e;
                            continue;
                        }
                    } else if (try x.mdLink(i + 1, to, true, line_no)) |e| {
                        i = e;
                        continue;
                    }
                },
                '[' => {
                    if (i + 1 < to and s[i + 1] == '[') {
                        if (try x.wikilink(i, to, false, line_no)) |e| {
                            i = e;
                            continue;
                        }
                    } else if (try x.mdLink(i, to, false, line_no)) |e| {
                        i = e;
                        continue;
                    }
                },
                '#' => if (tags.canStartAfter(tags.prevCodepoint(s, i))) {
                    if (tags.scanBody(s[0..to], i + 1)) |e| {
                        const display = try x.a.dupe(u8, s[i + 1 .. e]);
                        try x.tags.append(x.a, .{ .key = try tags.foldKey(x.a, display), .display = display, .src = .{ i, @intCast(e) } });
                        i = @intCast(e);
                        continue;
                    }
                },
                else => if (std.ascii.isAlphabetic(c) and (i == from or !std.ascii.isAlphanumeric(s[i - 1]))) {
                    if (bareUrlEnd(s, i, to)) |e| {
                        try x.external.append(x.a, try x.a.dupe(u8, s[i..e]));
                        i = e;
                        continue;
                    }
                },
            }
            i += 1;
        }
    }

    /// `[[target#sub|alias]]` at `i` (the first `[`). Returns the end.
    fn wikilink(x: *Extractor, i: u32, to: u32, embed: bool, line_no: u32) !?u32 {
        const s = x.src;
        const close = std.mem.indexOfPos(u8, s[0..to], i + 2, "]]") orelse return null;
        const inner_s = i + 2;
        const inner_e: u32 = @intCast(close);
        if (std.mem.indexOfPos(u8, s[0..inner_e], inner_s, "[[") != null) return null;
        if (inner_e == inner_s) return null;
        // `|` splits off the alias; `\|` (inside tables) too.
        var bar: ?u32 = null;
        var k = inner_s;
        while (k < inner_e) : (k += 1) if (s[k] == '|') {
            bar = k;
            break;
        };
        var target_e = bar orelse inner_e;
        if (bar != null and target_e > inner_s and s[target_e - 1] == '\\') target_e -= 1;
        const hash = std.mem.indexOfScalarPos(u8, s[0..target_e], inner_s, '#');
        const tt = trimRange(s, inner_s, if (hash) |h| @intCast(h) else target_e);
        var link: note.Link = .{
            .kind = if (embed) .embed else .wiki,
            .target = try x.a.dupe(u8, s[tt[0]..tt[1]]),
            .src = .{ if (embed) i - 1 else i, inner_e + 2 },
            .target_src = tt,
            .line = line_no,
            .context = x.cur_line,
        };
        if (hash) |h| link.subpath = try x.subpath(s[h + 1 .. target_e]);
        if (bar) |b| link.alias = try x.a.dupe(u8, std.mem.trim(u8, s[b + 1 .. inner_e], " "));
        try x.links.append(x.a, link);
        return inner_e + 2;
    }

    fn subpath(x: *Extractor, text: []const u8) !?note.Subpath {
        const t = std.mem.trim(u8, text, " ");
        if (t.len == 0) return null;
        if (t[0] == '^') return .{ .block = try x.a.dupe(u8, t[1..]) };
        var parts: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, t, '#');
        while (it.next()) |p| {
            const pt = std.mem.trim(u8, p, " ");
            if (pt.len > 0) try parts.append(x.a, try x.a.dupe(u8, pt));
        }
        if (parts.items.len == 0) return null;
        return .{ .heading = parts.items };
    }

    /// `[text](dest "title")` at `i`. Returns the end, or null when the
    /// bracket does not start an inline link.
    fn mdLink(x: *Extractor, i: u32, to: u32, image: bool, line_no: u32) !?u32 {
        const s = x.src;
        // The matching `]`.
        var depth: u32 = 0;
        var k = i;
        const close: u32 = while (k < to) : (k += 1) switch (s[k]) {
            '\\' => k += 1,
            '`' => k = codeSpanEnd(s, k, to) - 1,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) break k;
            },
            else => {},
        } else return null;
        if (close + 1 >= to or s[close + 1] != '(') return null;
        var d = close + 2;
        while (d < to and s[d] == ' ') d += 1;
        var dest_s = d;
        var dest_e: u32 = undefined;
        var angle = false;
        if (d < to and s[d] == '<') {
            angle = true;
            dest_s = d + 1;
            const e = std.mem.indexOfScalarPos(u8, s[0..to], dest_s, '>') orelse return null;
            dest_e = @intCast(e);
            d = dest_e + 1;
        } else {
            var parens: u32 = 0;
            while (d < to) : (d += 1) {
                const ch = s[d];
                if (ch == '\\') {
                    d += 1;
                    continue;
                }
                if (ch == ' ' or ch == '\t') break;
                if (ch == '(') parens += 1;
                if (ch == ')') {
                    if (parens == 0) break;
                    parens -= 1;
                }
            }
            dest_e = @min(d, to);
        }
        while (d < to and s[d] == ' ') d += 1;
        if (d < to and (s[d] == '"' or s[d] == '\'' or s[d] == '(')) {
            const q: u8 = if (s[d] == '(') ')' else s[d];
            const e = std.mem.indexOfScalarPos(u8, s[0..to], d + 1, q) orelse return null;
            d = @intCast(e + 1);
            while (d < to and s[d] == ' ') d += 1;
        }
        if (d >= to or s[d] != ')') return null;
        const end = d + 1;
        const start = if (image) i - 1 else i;
        const dest = s[dest_s..dest_e];
        if (dest.len == 0) return end;
        if (hasScheme(dest)) {
            try x.external.append(x.a, try x.a.dupe(u8, dest));
            return end;
        }
        const hash = std.mem.indexOfScalar(u8, dest, '#');
        const path_part = dest[0 .. hash orelse dest.len];
        const encoded = std.mem.indexOfScalar(u8, path_part, '%') != null;
        var link: note.Link = .{
            .kind = if (image) .markdown_embed else .markdown,
            .target = try percentDecode(x.a, path_part),
            .src = .{ start, end },
            .target_src = .{ dest_s, dest_s + @as(u32, @intCast(path_part.len)) },
            .line = line_no,
            .context = x.cur_line,
            .angle = angle,
            .encoded = encoded,
        };
        if (hash) |h| link.subpath = try x.subpath(try percentDecode(x.a, dest[h + 1 ..]));
        try x.links.append(x.a, link);
        return end;
    }
};

fn stem(path: []const u8) []const u8 {
    const base = std.fs.path.basenamePosix(path);
    const b2 = if (std.mem.lastIndexOfScalar(u8, base, '\\')) |k| base[k + 1 ..] else base;
    if (std.mem.lastIndexOfScalar(u8, b2, '.')) |dot| if (dot > 0) return b2[0..dot];
    return b2;
}

fn countLines(s: []const u8) u32 {
    return @intCast(std.mem.count(u8, s, "\n"));
}

fn leadingIndent(line: []const u8) u32 {
    var n: u32 = 0;
    for (line) |c| switch (c) {
        ' ' => n += 1,
        '\t' => n += 4 - n % 4,
        else => break,
    };
    return n;
}

fn openFence(t: []const u8) ?Fence {
    if (t.len < 3 or (t[0] != '`' and t[0] != '~')) return null;
    var n: u32 = 0;
    while (n < t.len and t[n] == t[0]) n += 1;
    if (n < 3) return null;
    if (t[0] == '`' and std.mem.indexOfScalar(u8, t[n..], '`') != null) return null;
    return .{ .ch = t[0], .len = n };
}

fn isFenceClose(t: []const u8, f: Fence) bool {
    var n: u32 = 0;
    while (n < t.len and t[n] == f.ch) n += 1;
    return n >= f.len and std.mem.trim(u8, t[n..], " \t").len == 0;
}

fn atxLevel(t: []const u8) ?u8 {
    var n: u8 = 0;
    while (n < t.len and n < 7 and t[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < t.len and t[n] != ' ' and t[n] != '\t') return null;
    return n;
}

/// The end of an ATX heading's text: before an optional closing `#` run.
fn atxTextEnd(s: []const u8, from: u32, to: u32) u32 {
    var e = to;
    while (e > from and (s[e - 1] == ' ' or s[e - 1] == '\t')) e -= 1;
    var h = e;
    while (h > from and s[h - 1] == '#') h -= 1;
    if (h < e and (h == from or s[h - 1] == ' ' or s[h - 1] == '\t')) {
        e = h;
        while (e > from and (s[e - 1] == ' ' or s[e - 1] == '\t')) e -= 1;
    }
    return e;
}

fn isSetext(t: []const u8) ?u8 {
    const c = t[0];
    if (c != '=' and c != '-') return null;
    var n: usize = 0;
    while (n < t.len and t[n] == c) n += 1;
    if (std.mem.trim(u8, t[n..], " \t").len != 0) return null;
    return if (c == '=') 1 else 2;
}

fn isThematicBreak(t: []const u8) bool {
    const c = t[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var n: usize = 0;
    for (t) |ch| {
        if (ch == c) n += 1 else if (ch != ' ' and ch != '\t') return false;
    }
    return n >= 3;
}

fn isListMarker(t: []const u8) bool {
    return listItem(t) != null;
}

const ListItem = struct {
    /// Offset of the item's content from the marker.
    content: u32,
    task: ?u8,
};

fn listItem(t: []const u8) ?ListItem {
    var n: usize = 0;
    if (t[0] == '-' or t[0] == '*' or t[0] == '+') {
        n = 1;
    } else {
        while (n < t.len and n < 9 and std.ascii.isDigit(t[n])) n += 1;
        if (n == 0 or n >= t.len or (t[n] != '.' and t[n] != ')')) return null;
        n += 1;
    }
    if (n < t.len and t[n] != ' ' and t[n] != '\t') return null;
    var c = n;
    while (c < t.len and (t[c] == ' ' or t[c] == '\t')) c += 1;
    var item: ListItem = .{ .content = @intCast(c), .task = null };
    if (c + 2 < t.len and t[c] == '[' and t[c + 2] == ']' and (c + 3 == t.len or t[c + 3] == ' ')) {
        if (t[c + 1] < 0x80) item.task = t[c + 1];
    } else if (c + 3 == t.len and t[c] == '[' and t[c + 2] == ']') {
        if (t[c + 1] < 0x80) item.task = t[c + 1];
    }
    return item;
}

fn isBlockIdChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-';
}

fn blockIdOnly(t: []const u8) bool {
    if (t.len < 2 or t[0] != '^') return false;
    for (t[1..]) |c| if (!isBlockIdChar(c)) return false;
    return true;
}

/// The offset of a trailing ` ^id` in `text` (at the `^`).
fn trailingBlockId(text: []const u8) ?u32 {
    const t = std.mem.trimEnd(u8, text, " \t");
    var k = t.len;
    while (k > 0 and isBlockIdChar(t[k - 1])) k -= 1;
    if (k == t.len or k < 2 or t[k - 1] != '^' or (t[k - 2] != ' ' and t[k - 2] != '\t')) return null;
    if (t.len != text.len) return null; // trailing spaces after the id
    return @intCast(k - 1);
}

/// Past a code span starting with the backtick run at `i`; just past the
/// run when it has no closer on the line (literal backticks).
fn codeSpanEnd(s: []const u8, i: u32, to: u32) u32 {
    var n: u32 = 0;
    while (i + n < to and s[i + n] == '`') n += 1;
    var k = i + n;
    while (k < to) {
        if (s[k] != '`') {
            k += 1;
            continue;
        }
        var m: u32 = 0;
        while (k + m < to and s[k + m] == '`') m += 1;
        if (m == n) return k + m;
        k += m;
    }
    return i + n;
}

/// `$x$` (no space inside the dollars, no digit after the closer).
fn inlineMathEnd(s: []const u8, i: u32, to: u32) ?u32 {
    if (i + 2 >= to or s[i + 1] == ' ' or s[i + 1] == '$') return null;
    var k = i + 1;
    while (k < to) : (k += 1) {
        if (s[k] == '\\') {
            k += 1;
            continue;
        }
        if (s[k] == '$') {
            if (s[k - 1] == ' ') return null;
            if (k + 1 < to and std.ascii.isDigit(s[k + 1])) return null;
            return k + 1;
        }
    }
    return null;
}

fn hasScheme(dest: []const u8) bool {
    if (dest.len < 2 or !std.ascii.isAlphabetic(dest[0])) return false;
    for (dest[1..], 1..) |c, k| {
        if (c == ':') return k >= 2; // `C:` drive letters are paths
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '.' or c == '-')) return false;
    }
    return false;
}

fn autolinkEnd(s: []const u8, i: u32, to: u32) ?u32 {
    const e = std.mem.indexOfScalarPos(u8, s[0..to], i + 1, '>') orelse return null;
    const inner = s[i + 1 .. e];
    if (std.mem.indexOfAny(u8, inner, " <") != null) return null;
    if (!hasScheme(inner) and std.mem.indexOfScalar(u8, inner, '@') == null) return null;
    return @intCast(e + 1);
}

fn bareUrlEnd(s: []const u8, i: u32, to: u32) ?u32 {
    const rest = s[i..to];
    const schemes = [_][]const u8{ "https://", "http://", "ftp://", "mailto:", "file://", "obsidian://", "www." };
    const ok = for (schemes) |sc| {
        if (rest.len > sc.len and std.ascii.startsWithIgnoreCase(rest, sc)) break true;
    } else false;
    if (!ok) return null;
    var e = i;
    while (e < to and s[e] != ' ' and s[e] != '\t' and s[e] != '<') e += 1;
    while (e > i and std.mem.indexOfScalar(u8, ".,;:!?*_~'\")]", s[e - 1]) != null) e -= 1;
    return e;
}

fn trimRange(s: []const u8, a: u32, b: u32) [2]u32 {
    var x = a;
    var y = b;
    while (x < y and s[x] == ' ') x += 1;
    while (y > x and s[y - 1] == ' ') y -= 1;
    return .{ x, y };
}

fn countWords(s: []const u8) u32 {
    var n: u32 = 0;
    var in_word = false;
    for (s) |c| {
        const ws = c == ' ' or c == '\t' or c == '\r' or c == '\n';
        if (!ws and !in_word) n += 1;
        in_word = !ws;
    }
    return n;
}

/// Decodes `%XX` escapes; returns a copy.
pub fn percentDecode(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(a, s.len);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                out.appendAssumeCapacity(b);
                i += 2;
                continue;
            } else |_| {}
        }
        out.appendAssumeCapacity(s[i]);
    }
    return out.items;
}

fn joinLines(a: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    var first = true;
    while (it.next()) |l| {
        if (!first) try out.append(a, ' ');
        first = false;
        try out.appendSlice(a, std.mem.trim(u8, l, " \t\r"));
    }
    return out.items;
}

/// Heading text without inline markup: `[[a|b]]` → `b`, `[[a]]` → `a`,
/// `[t](u)` → `t`, emphasis/strike/highlight/code markers dropped.
pub fn stripInline(a: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, "[*_~=`\\") == null) return a.dupe(u8, s);
    var out: std.ArrayList(u8) = try .initCapacity(a, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len) {
            out.appendAssumeCapacity(s[i + 1]);
            i += 2;
            continue;
        }
        if (c == '[' and i + 1 < s.len and s[i + 1] == '[') {
            if (std.mem.indexOfPos(u8, s, i + 2, "]]")) |e| {
                const inner = s[i + 2 .. e];
                const shown = if (std.mem.indexOfScalar(u8, inner, '|')) |b| inner[b + 1 ..] else inner;
                out.appendSliceAssumeCapacity(shown);
                i = e + 2;
                continue;
            }
        }
        if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, ']')) |e| if (e + 1 < s.len and s[e + 1] == '(') {
                if (std.mem.indexOfScalarPos(u8, s, e + 2, ')')) |p| {
                    out.appendSliceAssumeCapacity(s[i + 1 .. e]);
                    i = p + 1;
                    continue;
                }
            };
        }
        if (c == '*' or c == '`' or (c == '~' and i + 1 < s.len and s[i + 1] == '~') or (c == '=' and i + 1 < s.len and s[i + 1] == '=')) {
            i += if (c == '*' or c == '`') 1 else 2;
            continue;
        }
        if (c == '_') {
            const before_word = i > 0 and std.ascii.isAlphanumeric(s[i - 1]);
            const after_word = i + 1 < s.len and std.ascii.isAlphanumeric(s[i + 1]);
            if (!(before_word and after_word)) {
                i += 1;
                continue;
            }
        }
        out.appendAssumeCapacity(c);
        i += 1;
    }
    return out.items;
}
