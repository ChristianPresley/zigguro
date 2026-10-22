//! HTML to compact Markdown for `web_fetch` (E10.F06.S03.T03).
//!
//! A pragmatic subset of the WHATWG tokenizer: text, start and end tags
//! with double-quoted, single-quoted and unquoted attributes, comments,
//! doctypes and character references (numeric and the common named ones;
//! unknown ones stay as written). `script`, `style`, `noscript`,
//! `template` and `head` are skipped.
//!
//! There is no tree construction. Unlike the spec's tree builder, elements
//! map to Markdown as their tags arrive: a stray end tag is ignored, an
//! unclosed `p` or `li` simply ends at the next block, and misnested
//! inline tags are not repaired. Nesting is tracked to depth 512; deeper
//! structure is flattened. `nav`, `footer`, `aside` and `form` are dropped,
//! and when the page has a `main` (or else an `article`) only that subtree
//! is kept.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Keep only `main`/`article` when the page has one.
    main_only: bool = true,
    /// Output cap in bytes (cut at a line end).
    max_bytes: usize = 1 << 20,
};

pub const max_depth = 512;

/// Converts `html`; links and images are made absolute against `base_url`.
/// Never fails except for allocation.
pub fn htmlToMarkdown(arena: Allocator, html: []const u8, base_url: []const u8, opts: Options) Allocator.Error![]const u8 {
    var c: Converter = .{ .a = arena, .base = base_url, .opts = opts };
    if (opts.main_only) c.focus = findFocus(html);
    try c.run(html);
    return c.finish();
}

const Focus = enum { none, main, article };

/// `main` when the page has one, else `article`.
fn findFocus(html: []const u8) Focus {
    var t: Tokenizer = .{ .src = html };
    var article = false;
    while (t.next()) |tok| switch (tok) {
        .start => |s| {
            if (eql(s.name, "main")) return .main;
            if (eql(s.name, "article")) article = true;
        },
        else => {},
    };
    return if (article) .article else .none;
}

// ---------------------------------------------------------------- tokenizer

const Attr = struct { name: []const u8, value: []const u8 };

const Tag = struct {
    /// Lowercase when `lower` is used; the raw name otherwise.
    name: []const u8,
    attrs_src: []const u8,
    self_closing: bool,

    fn attr(t: Tag, name: []const u8) ?[]const u8 {
        var it: AttrIter = .{ .s = t.attrs_src };
        while (it.next()) |a| if (std.ascii.eqlIgnoreCase(a.name, name)) return a.value;
        return null;
    }
};

const Token = union(enum) {
    text: []const u8,
    start: Tag,
    end: []const u8,
};

const Tokenizer = struct {
    src: []const u8,
    i: usize = 0,
    /// Inside a raw-text element: skip to its end tag.
    raw: ?[]const u8 = null,

    fn next(t: *Tokenizer) ?Token {
        while (t.i < t.src.len) {
            if (t.raw) |name| {
                t.raw = null;
                t.skipRaw(name);
                continue;
            }
            const s = t.src;
            if (s[t.i] != '<') {
                const end = std.mem.indexOfScalarPos(u8, s, t.i, '<') orelse s.len;
                defer t.i = end;
                return .{ .text = s[t.i..end] };
            }
            const rest = s[t.i..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                const e = std.mem.indexOfPos(u8, s, t.i + 4, "-->");
                t.i = if (e) |x| x + 3 else s.len;
                continue;
            }
            if (rest.len >= 2 and (rest[1] == '!' or rest[1] == '?')) {
                const e = std.mem.indexOfScalarPos(u8, s, t.i, '>');
                t.i = if (e) |x| x + 1 else s.len;
                continue;
            }
            if (rest.len >= 2 and rest[1] == '/') {
                if (rest.len >= 3 and std.ascii.isAlphabetic(rest[2])) {
                    const name_end = nameEnd(s, t.i + 2);
                    const name = s[t.i + 2 .. name_end];
                    const e = std.mem.indexOfScalarPos(u8, s, name_end, '>');
                    t.i = if (e) |x| x + 1 else s.len;
                    return .{ .end = name };
                }
                // `</>` or `</ ...`: a bogus comment.
                const e = std.mem.indexOfScalarPos(u8, s, t.i, '>');
                t.i = if (e) |x| x + 1 else s.len;
                continue;
            }
            if (rest.len >= 2 and std.ascii.isAlphabetic(rest[1])) {
                const name_end = nameEnd(s, t.i + 1);
                const name = s[t.i + 1 .. name_end];
                const close = tagClose(s, name_end);
                const attrs = s[name_end..close.attrs_end];
                t.i = close.next;
                const tag: Tag = .{ .name = name, .attrs_src = attrs, .self_closing = close.self_closing };
                if (isRawText(name)) t.raw = name;
                return .{ .start = tag };
            }
            // A lone `<` is text.
            defer t.i += 1;
            return .{ .text = s[t.i .. t.i + 1] };
        }
        return null;
    }

    fn skipRaw(t: *Tokenizer, name: []const u8) void {
        const s = t.src;
        var j = t.i;
        while (std.mem.indexOfPos(u8, s, j, "</")) |p| {
            const n = s[p + 2 ..];
            if (n.len >= name.len and std.ascii.eqlIgnoreCase(n[0..name.len], name) and (n.len == name.len or !isNameChar(n[name.len]))) {
                const e = std.mem.indexOfScalarPos(u8, s, p, '>');
                t.i = if (e) |x| x + 1 else s.len;
                return;
            }
            j = p + 2;
        }
        t.i = s.len;
    }
};

fn isNameChar(c: u8) bool {
    return !(std.ascii.isWhitespace(c) or c == '/' or c == '>');
}

fn nameEnd(s: []const u8, from: usize) usize {
    var j = from;
    while (j < s.len and isNameChar(s[j])) j += 1;
    return j;
}

/// Finds the `>` ending a start tag, skipping quoted attribute values.
fn tagClose(s: []const u8, from: usize) struct { attrs_end: usize, next: usize, self_closing: bool } {
    var j = from;
    var quote: u8 = 0;
    while (j < s.len) : (j += 1) {
        const c = s[j];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            // Only a quote after `=` starts a value.
            var k = j;
            while (k > from and std.ascii.isWhitespace(s[k - 1])) k -= 1;
            if (k > from and s[k - 1] == '=') quote = c;
        } else if (c == '>') {
            const sc = j > from and s[j - 1] == '/';
            return .{ .attrs_end = if (sc) j - 1 else j, .next = j + 1, .self_closing = sc };
        }
    }
    return .{ .attrs_end = s.len, .next = s.len, .self_closing = false };
}

const AttrIter = struct {
    s: []const u8,
    i: usize = 0,

    fn next(it: *AttrIter) ?Attr {
        const s = it.s;
        while (it.i < s.len and (std.ascii.isWhitespace(s[it.i]) or s[it.i] == '/')) it.i += 1;
        if (it.i >= s.len) return null;
        const ns = it.i;
        while (it.i < s.len and !std.ascii.isWhitespace(s[it.i]) and s[it.i] != '=' and s[it.i] != '/') it.i += 1;
        const name = s[ns..it.i];
        while (it.i < s.len and std.ascii.isWhitespace(s[it.i])) it.i += 1;
        if (it.i >= s.len or s[it.i] != '=') return .{ .name = name, .value = "" };
        it.i += 1;
        while (it.i < s.len and std.ascii.isWhitespace(s[it.i])) it.i += 1;
        if (it.i >= s.len) return .{ .name = name, .value = "" };
        const q = s[it.i];
        if (q == '"' or q == '\'') {
            const vs = it.i + 1;
            const ve = std.mem.indexOfScalarPos(u8, s, vs, q) orelse s.len;
            it.i = @min(ve + 1, s.len);
            return .{ .name = name, .value = s[vs..ve] };
        }
        const vs = it.i;
        while (it.i < s.len and !std.ascii.isWhitespace(s[it.i])) it.i += 1;
        return .{ .name = name, .value = s[vs..it.i] };
    }
};

fn isRawText(name: []const u8) bool {
    return inSet(name, &.{ "script", "style", "noscript", "template", "textarea", "title", "svg", "math", "iframe" });
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// ---------------------------------------------------------------- entities

const named = [_]struct { []const u8, []const u8 }{
    .{ "amp", "&" },  .{ "lt", "<" },     .{ "gt", ">" },  .{ "quot", "\"" },
    .{ "apos", "'" }, .{ "nbsp", " " },
    .{ "copy", "©" },
    .{ "reg", "®" },
    .{ "trade", "™" },
    .{ "mdash", "—" },
    .{ "ndash", "–" },
    .{ "hellip", "…" },
    .{ "laquo", "«" },
    .{ "raquo", "»" },
    .{ "lsquo", "‘" },
    .{ "rsquo", "’" },
    .{ "ldquo", "“" },
    .{ "rdquo", "”" },
    .{ "bull", "•" },
    .{ "middot", "·" },
    .{ "times", "×" },
    .{ "divide", "÷" },
    .{ "deg", "°" },
    .{ "plusmn", "±" },
    .{ "para", "¶" },
    .{ "sect", "§" },
    .{ "euro", "€" },
    .{ "pound", "£" },
    .{ "yen", "¥" },
    .{ "cent", "¢" },
    .{ "larr", "←" },
    .{ "rarr", "→" },
    .{ "uarr", "↑" },
    .{ "darr", "↓" },
    .{ "harr", "↔" },
    .{ "le", "≤" },
    .{ "ge", "≥" },
    .{ "ne", "≠" },
    .{ "minus", "−" },
    .{ "infin", "∞" },
    .{ "shy", "" },   .{ "zwj", "" },     .{ "zwnj", "" }, .{ "ensp", " " },
    .{ "emsp", " " }, .{ "thinsp", " " },
    .{ "check", "✓" },
    .{ "eacute", "é" },
    .{ "egrave", "è" },
    .{ "aacute", "á" },
    .{ "agrave", "à" },
    .{ "ouml", "ö" },
    .{ "uuml", "ü" },
    .{ "auml", "ä" },
    .{ "szlig", "ß" },
    .{ "ntilde", "ñ" },
    .{ "ccedil", "ç" },
    .{ "iuml", "ï" },
};

fn lookupNamed(ref: []const u8) ?[]const u8 {
    for (named) |e| if (std.mem.eql(u8, e[0], ref)) return e[1];
    return null;
}

/// Appends `text` with character references decoded.
fn decodeInto(a: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const amp = std.mem.indexOfScalarPos(u8, text, i, '&') orelse {
            try out.appendSlice(a, text[i..]);
            return;
        };
        try out.appendSlice(a, text[i..amp]);
        i = amp + 1;
        const semi = std.mem.indexOfScalarPos(u8, text, i, ';');
        if (semi) |sc| if (sc - i <= 10) {
            const ref = text[i..sc];
            if (ref.len > 1 and ref[0] == '#') {
                const hex = ref[1] == 'x' or ref[1] == 'X';
                const digits = if (hex) ref[2..] else ref[1..];
                if (std.fmt.parseInt(u21, digits, if (hex) 16 else 10)) |cp| {
                    var buf: [4]u8 = undefined;
                    const cp2: u21 = if (cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) 0xFFFD else cp;
                    const n = std.unicode.utf8Encode(cp2, &buf) catch 0;
                    try out.appendSlice(a, buf[0..n]);
                    i = sc + 1;
                    continue;
                } else |_| {}
            } else if (lookupNamed(ref)) |v| {
                try out.appendSlice(a, v);
                i = sc + 1;
                continue;
            }
        };
        try out.append(a, '&');
    }
}

// ---------------------------------------------------------------- converter

const List = struct { ordered: bool, n: u32 = 0 };

const Table = struct {
    rows: std.ArrayList([]const []const u8) = .empty,
    row: std.ArrayList([]const u8) = .empty,
    cell: std.ArrayList(u8) = .empty,
    in_cell: bool = false,
};

const Converter = struct {
    a: Allocator,
    base: []const u8,
    opts: Options,
    focus: Focus = .none,
    out: std.ArrayList(u8) = .empty,
    /// Depth inside the focus element (0 = outside).
    focus_depth: u32 = 0,
    seen_focus: bool = false,
    /// Inside a dropped subtree: its tag and nesting.
    drop: ?[]const u8 = null,
    drop_depth: u32 = 0,
    lists: [max_depth]List = undefined,
    nlists: u32 = 0,
    quote: u32 = 0,
    pre: u32 = 0,
    code: u32 = 0,
    bold: u32 = 0,
    italic: u32 = 0,
    /// Pending whitespace between words.
    space: bool = false,
    /// Open links: where the text started and the target.
    links: [max_depth]struct { start: usize, href: ?[]const u8 } = undefined,
    nlinks: u32 = 0,
    table: ?Table = null,
    table_depth: u32 = 0,
    text_buf: std.ArrayList(u8) = .empty,

    fn run(c: *Converter, html: []const u8) Allocator.Error!void {
        var t: Tokenizer = .{ .src = html };
        while (t.next()) |tok| {
            if (c.out.items.len > c.opts.max_bytes) return;
            switch (tok) {
                .text => |s| if (c.active()) try c.text(s),
                .start => |tag| try c.startTag(tag),
                .end => |name| try c.endTag(name),
            }
        }
    }

    fn active(c: *const Converter) bool {
        if (c.drop != null) return false;
        return c.focus == .none or c.focus_depth > 0;
    }

    fn isFocus(c: *const Converter, name: []const u8) bool {
        return switch (c.focus) {
            .none => false,
            .main => eql(name, "main"),
            .article => eql(name, "article"),
        };
    }

    /// Where text goes: the open table cell, or the output.
    fn sink(c: *Converter) *std.ArrayList(u8) {
        if (c.table) |*t| if (t.in_cell) return &t.cell;
        return &c.out;
    }

    fn startTag(c: *Converter, tag: Tag) Allocator.Error!void {
        const n = tag.name;
        if (c.drop) |d| {
            if (eql(n, d) and !tag.self_closing) c.drop_depth += 1;
            return;
        }
        if (c.isFocus(n) and !c.seen_focus) {
            c.seen_focus = true;
            c.focus_depth = 1;
            return;
        } else if (c.focus_depth > 0 and c.isFocus(n)) c.focus_depth += 1;
        if (!c.active()) return;
        const k = kindOf(n) orelse {
            if (isDropped(n) and !tag.self_closing) {
                c.drop = n;
                c.drop_depth = 1;
            }
            return;
        };
        if (isDropped(n) and !tag.self_closing) {
            c.drop = n;
            c.drop_depth = 1;
            return;
        }
        if (c.table != null and c.table_depth > 1 and k != .table) {
            // Inside a nested table: text only.
            if (k == .br or k == .td or k == .th or k == .tr) c.space = true;
            return;
        }
        if (headingLevel(k)) |level| {
            try c.block(2);
            for (0..level) |_| try c.raw("#");
            try c.raw(" ");
        } else if (k == .p or k == .div or k == .section or k == .header or k == .figure or k == .dl or k == .details or k == .summary or k == .address) {
            try c.block(if (k == .p) 2 else 1);
        } else if (k == .dt or k == .dd or k == .figcaption or k == .tr and c.table == null) {
            try c.block(1);
        } else if (k == .br) {
            if (c.pre > 0) try c.sink().append(c.a, '\n') else try c.newline();
        } else if (k == .hr) {
            try c.block(2);
            try c.raw("---");
            try c.block(2);
        } else if (k == .ul or k == .ol) {
            if (c.nlists < max_depth) {
                c.lists[c.nlists] = .{ .ordered = k == .ol };
                c.nlists += 1;
            }
            try c.block(if (c.nlists == 1) 2 else 1);
        } else if (k == .li) {
            try c.block(1);
            const depth = @min(c.nlists, 32);
            if (depth > 1) for (0..depth - 1) |_| try c.raw("  ");
            if (depth > 0 and c.lists[c.nlists - 1].ordered) {
                c.lists[c.nlists - 1].n += 1;
                var buf: [16]u8 = undefined;
                try c.raw(std.fmt.bufPrint(&buf, "{d}. ", .{c.lists[c.nlists - 1].n}) catch "1. ");
            } else try c.raw("- ");
        } else if (k == .blockquote) {
            try c.block(2);
            c.quote += 1;
            try c.linePrefix();
        } else if (k == .pre) {
            try c.block(2);
            c.pre += 1;
            if (c.pre == 1) {
                try c.raw("```");
                if (languageOf(tag)) |l| try c.raw(l);
                try c.sink().append(c.a, '\n');
                try c.linePrefix();
            }
        } else if (k == .code or k == .kbd or k == .samp) {
            c.code += 1;
            if (c.pre == 0 and c.code == 1) try c.inlineMark("`");
            // `<pre><code class="language-x">`: the fence takes the language.
            if (c.pre > 0) if (languageOf(tag)) |l| {
                const w = c.sink();
                const ls = lastLine(w.items);
                const prev = lastLine(w.items[0..w.items.len - ls.len -| 1]);
                if (std.mem.trim(u8, ls, "> ").len == 0 and std.mem.eql(u8, std.mem.trimStart(u8, prev, "> "), "```")) {
                    try w.insertSlice(c.a, w.items.len - ls.len - 1, l);
                }
            };
        } else if (k == .strong or k == .b) {
            c.bold += 1;
            if (c.pre == 0 and c.bold == 1) try c.inlineMark("**");
        } else if (k == .em or k == .i) {
            c.italic += 1;
            if (c.pre == 0 and c.italic == 1) try c.inlineMark("*");
        } else if (k == .a) {
            if (c.pre > 0) return;
            if (c.nlinks < max_depth) {
                const href = tag.attr("href");
                const keep = if (href) |h| !(h.len == 0 or h[0] == '#' or std.ascii.startsWithIgnoreCase(h, "javascript:")) else false;
                try c.inlineMark("");
                c.links[c.nlinks] = .{ .start = c.sink().items.len, .href = if (keep) try c.resolve(href.?) else null };
                c.nlinks += 1;
            }
        } else if (k == .img) {
            const alt = tag.attr("alt") orelse return;
            const src = tag.attr("src") orelse return;
            if (std.mem.trim(u8, alt, " \t\r\n").len == 0) return;
            try c.inlineMark("");
            const w = c.sink();
            try w.append(c.a, '[');
            c.text_buf.clearRetainingCapacity();
            try decodeInto(c.a, &c.text_buf, alt);
            try appendCollapsed(c.a, w, c.text_buf.items);
            try w.print(c.a, "]({s})", .{try c.resolve(src)});
        } else if (k == .table) {
            if (c.table == null) {
                try c.block(2);
                c.table = .{};
            }
            c.table_depth += 1;
        } else if (c.table != null and c.table_depth == 1) {
            const t = &c.table.?;
            if (k == .tr) {
                try c.endRow();
            } else if (k == .td or k == .th) {
                try c.endCell();
                t.in_cell = true;
                c.space = false;
            }
        }
    }

    fn endTag(c: *Converter, name: []const u8) Allocator.Error!void {
        if (c.drop) |d| {
            if (eql(name, d)) {
                c.drop_depth -= 1;
                if (c.drop_depth == 0) c.drop = null;
            }
            return;
        }
        if (c.focus_depth > 0 and c.isFocus(name)) {
            c.focus_depth -= 1;
            return;
        }
        if (!c.active()) return;
        const k = kindOf(name) orelse return;
        if (k == .table) {
            if (c.table_depth > 0) c.table_depth -= 1;
            if (c.table_depth == 0 and c.table != null) try c.flushTable();
            return;
        }
        if (c.table != null and c.table_depth > 1) return;
        if (headingLevel(k) != null) {
            try c.block(2);
        } else if (k == .p) {
            try c.block(2);
        } else if (k == .div or k == .section or k == .header or k == .figure or k == .dt or k == .dd or k == .li or k == .figcaption or k == .details or k == .summary) {
            try c.block(1);
        } else if (k == .ul or k == .ol) {
            if (c.nlists > 0) c.nlists -= 1;
            try c.block(if (c.nlists == 0) 2 else 1);
        } else if (k == .blockquote) {
            try c.block(2);
            if (c.quote > 0) c.quote -= 1;
        } else if (k == .pre) {
            if (c.pre == 0) return;
            c.pre -= 1;
            if (c.pre == 0) {
                const w = c.sink();
                if (w.items.len > 0 and w.items[w.items.len - 1] != '\n') try w.append(c.a, '\n');
                try c.linePrefix();
                try c.raw("```");
                try c.block(2);
            }
        } else if (k == .code or k == .kbd or k == .samp) {
            if (c.code == 0) return;
            c.code -= 1;
            if (c.pre == 0 and c.code == 0) try c.closeMark("`");
        } else if (k == .strong or k == .b) {
            if (c.bold == 0) return;
            c.bold -= 1;
            if (c.pre == 0 and c.bold == 0) try c.closeMark("**");
        } else if (k == .em or k == .i) {
            if (c.italic == 0) return;
            c.italic -= 1;
            if (c.pre == 0 and c.italic == 0) try c.closeMark("*");
        } else if (k == .a) {
            if (c.pre > 0 or c.nlinks == 0) return;
            c.nlinks -= 1;
            const l = c.links[c.nlinks];
            const href = l.href orelse return;
            const w = c.sink();
            if (l.start > w.items.len) return;
            // An empty link text uses the URL.
            if (std.mem.trim(u8, w.items[l.start..], " \n>").len == 0) {
                w.shrinkRetainingCapacity(l.start);
                try w.print(c.a, "<{s}>", .{href});
            } else {
                while (w.items.len > 0 and w.items[w.items.len - 1] == ' ') {
                    w.items.len -= 1;
                    c.space = true;
                }
                try w.insert(c.a, l.start, '[');
                try w.print(c.a, "]({s})", .{href});
            }
        } else if (c.table != null) {
            if (k == .td or k == .th) try c.endCell() else if (k == .tr) try c.endRow();
        }
    }

    fn text(c: *Converter, s: []const u8) Allocator.Error!void {
        const t = if (std.mem.indexOfScalar(u8, s, '&') == null) s else blk: {
            c.text_buf.clearRetainingCapacity();
            try decodeInto(c.a, &c.text_buf, s);
            break :blk c.text_buf.items;
        };
        const w = c.sink();
        if (c.pre > 0) {
            // Keep it as is, with the blockquote prefix after each newline.
            var lines = std.mem.splitScalar(u8, t, '\n');
            var first = true;
            while (lines.next()) |line| {
                if (!first) {
                    try w.append(c.a, '\n');
                    if (c.quote > 0) try c.linePrefix();
                }
                first = false;
                try w.appendSlice(c.a, line);
            }
            return;
        }
        var i: usize = 0;
        while (i < t.len) {
            if (std.ascii.isWhitespace(t[i])) {
                c.space = true;
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < t.len and !std.ascii.isWhitespace(t[j])) j += 1;
            if (c.space) {
                c.space = false;
                if (w.items.len > 0) {
                    const last = w.items[w.items.len - 1];
                    if (last != ' ' and last != '\n' and last != '[' and last != '(') try w.append(c.a, ' ');
                }
            }
            try w.appendSlice(c.a, t[i..j]);
            i = j;
        }
    }

    /// Opens an inline mark, keeping a pending space before it.
    fn inlineMark(c: *Converter, mark: []const u8) Allocator.Error!void {
        const w = c.sink();
        if (c.space) {
            c.space = false;
            if (w.items.len > 0) {
                const last = w.items[w.items.len - 1];
                if (last != ' ' and last != '\n') try w.append(c.a, ' ');
            }
        }
        try w.appendSlice(c.a, mark);
    }

    /// Closes an inline mark; an empty one is removed.
    fn closeMark(c: *Converter, mark: []const u8) Allocator.Error!void {
        const w = c.sink();
        if (std.mem.endsWith(u8, w.items, mark)) {
            w.items.len -= mark.len;
            return;
        }
        while (w.items.len > 0 and w.items[w.items.len - 1] == ' ') {
            w.items.len -= 1;
            c.space = true;
        }
        try w.appendSlice(c.a, mark);
    }

    fn raw(c: *Converter, s: []const u8) Allocator.Error!void {
        c.space = false;
        try c.sink().appendSlice(c.a, s);
    }

    /// Ends the line, keeping the blockquote prefix.
    fn newline(c: *Converter) Allocator.Error!void {
        const w = c.sink();
        if (c.table) |t| if (t.in_cell) {
            c.space = true;
            return;
        };
        while (w.items.len > 0 and w.items[w.items.len - 1] == ' ') w.items.len -= 1;
        try w.append(c.a, '\n');
        try c.linePrefix();
        c.space = false;
    }

    /// Makes the output end with `n` line breaks (one blank line for 2).
    fn block(c: *Converter, n: u8) Allocator.Error!void {
        c.space = false;
        if (c.table) |t| if (t.in_cell) {
            c.space = true;
            return;
        };
        const w = &c.out;
        // Drop a trailing bare prefix and spaces.
        // A paragraph right after a list marker stays on the marker's line.
        if (onlyMarker(std.mem.trimEnd(u8, lastLine(w.items), " "))) return;
        trimLineEnd(w, c.quote);
        if (w.items.len == 0) return c.linePrefix();
        var have: u8 = 0;
        var j = w.items.len;
        while (j > 0 and w.items[j - 1] == '\n' and have < n) : (j -= 1) have += 1;
        while (have < n) : (have += 1) {
            if (have > 0 and c.quote > 0) try c.linePrefix();
            trimSpaces(w);
            try w.append(c.a, '\n');
        }
        try c.linePrefix();
    }

    fn linePrefix(c: *Converter) Allocator.Error!void {
        const w = c.sink();
        for (0..@min(c.quote, 32)) |_| try w.appendSlice(c.a, "> ");
    }

    fn endCell(c: *Converter) Allocator.Error!void {
        const t = &c.table.?;
        if (!t.in_cell) return;
        t.in_cell = false;
        const cell = std.mem.trim(u8, t.cell.items, " \n");
        const clean = try c.a.alloc(u8, cell.len);
        for (cell, clean) |ch, *o| o.* = if (ch == '\n' or ch == '|') ' ' else ch;
        try t.row.append(c.a, clean);
        t.cell = .empty;
        c.space = false;
    }

    fn endRow(c: *Converter) Allocator.Error!void {
        try c.endCell();
        const t = &c.table.?;
        if (t.row.items.len == 0) return;
        try t.rows.append(c.a, t.row.items);
        t.row = .empty;
    }

    /// A GFM table when every row has the same number of cells, else one
    /// line per row with cells separated by ` | `.
    fn flushTable(c: *Converter) Allocator.Error!void {
        try c.endRow();
        const t = c.table.?;
        c.table = null;
        const rows = t.rows.items;
        if (rows.len == 0) return;
        var cols: usize = 0;
        var same = true;
        for (rows) |r| {
            if (cols != 0 and r.len != cols) same = false;
            cols = @max(cols, r.len);
        }
        try c.block(2);
        for (rows, 0..) |r, i| {
            if (same) try c.raw("| ");
            for (r, 0..) |cell, k| {
                if (k > 0) try c.raw(" | ");
                try c.raw(cell);
            }
            if (same) try c.raw(" |");
            try c.newline();
            if (same and i == 0) {
                for (0..cols) |_| try c.raw("| --- ");
                try c.raw("|");
                try c.newline();
            }
        }
        try c.block(2);
    }

    /// `base_url` + `href`, made absolute.
    fn resolve(c: *Converter, href_raw: []const u8) Allocator.Error![]const u8 {
        c.text_buf.clearRetainingCapacity();
        try decodeInto(c.a, &c.text_buf, std.mem.trim(u8, href_raw, " \t\r\n"));
        const href = try c.a.dupe(u8, c.text_buf.items);
        return resolveUrl(c.a, c.base, href);
    }

    fn finish(c: *Converter) Allocator.Error![]const u8 {
        if (c.pre > 0) {
            c.pre = 0;
            try c.out.appendSlice(c.a, "\n```");
        }
        // Collapse runs of blank lines (prefix-only lines count as blank).
        var out: std.ArrayList(u8) = .empty;
        var blank: u32 = 0;
        // The blank lines were inside a blockquote.
        var quoted_blank = false;
        var lines = std.mem.splitScalar(u8, c.out.items, '\n');
        var in_fence = false;
        while (lines.next()) |line0| {
            const line = std.mem.trimEnd(u8, line0, " ");
            const bare = std.mem.trim(u8, line, "> ");
            if (std.mem.startsWith(u8, bare, "```")) in_fence = !in_fence;
            if (bare.len == 0 and !in_fence) {
                blank += 1;
                if (line.len > 0) quoted_blank = true;
                continue;
            }
            if (out.items.len > 0) {
                if (blank == 0) {
                    try out.append(c.a, '\n');
                } else if (quoted_blank and line.len > 0 and line[0] == '>' and lastLine(out.items).len > 0 and lastLine(out.items)[0] == '>') {
                    try out.appendSlice(c.a, "\n>\n");
                } else try out.appendSlice(c.a, "\n\n");
            }
            blank = 0;
            quoted_blank = false;
            try out.appendSlice(c.a, line);
            if (out.items.len > c.opts.max_bytes) break;
        }
        if (out.items.len > c.opts.max_bytes) {
            const cut = std.mem.lastIndexOfScalar(u8, out.items[0..c.opts.max_bytes], '\n') orelse c.opts.max_bytes;
            out.items.len = cut;
        }
        return out.items;
    }
};

/// The elements the converter maps.
const Kind = enum { p, div, section, header, figure, dl, details, summary, address, dt, dd, figcaption, tr, br, hr, ul, ol, li, blockquote, pre, code, kbd, samp, strong, b, em, i, a, img, table, td, th, h1, h2, h3, h4, h5, h6 };

/// A tag name (up to 16 bytes) lowercased into one integer, so lookups
/// are integer compares.
fn nameKey(name: []const u8) ?u128 {
    if (name.len == 0 or name.len > 16) return null;
    var buf: [16]u8 = @splat(0);
    for (name, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return std.mem.readInt(u128, &buf, .little);
}

fn comptimeKey(comptime name: []const u8) u128 {
    var buf: [16]u8 = @splat(0);
    @memcpy(buf[0..name.len], name);
    return std.mem.readInt(u128, &buf, .little);
}

fn kindOf(name: []const u8) ?Kind {
    const key = nameKey(name) orelse return null;
    inline for (@typeInfo(Kind).@"enum".fields) |f| {
        if (key == comptime comptimeKey(f.name)) return @enumFromInt(f.value);
    }
    return null;
}

fn inSet(name: []const u8, comptime set: []const []const u8) bool {
    const key = nameKey(name) orelse return false;
    inline for (set) |x| if (key == comptime comptimeKey(x)) return true;
    return false;
}

fn headingLevel(k: Kind) ?u8 {
    return switch (k) {
        .h1 => 1,
        .h2 => 2,
        .h3 => 3,
        .h4 => 4,
        .h5 => 5,
        .h6 => 6,
        else => null,
    };
}

fn isDropped(name: []const u8) bool {
    return inSet(name, &.{ "nav", "footer", "aside", "form", "head", "button", "select", "dialog" });
}

fn languageOf(tag: Tag) ?[]const u8 {
    const class = tag.attr("class") orelse return null;
    var it = std.mem.tokenizeAny(u8, class, " \t");
    while (it.next()) |cls| {
        for ([_][]const u8{ "language-", "lang-" }) |p| if (std.mem.startsWith(u8, cls, p) and cls.len > p.len) return cls[p.len..];
    }
    return null;
}

fn lastLine(s: []const u8) []const u8 {
    return s[if (std.mem.lastIndexOfScalar(u8, s, '\n')) |p| p + 1 else 0..];
}

/// `- ` or `12. ` after indentation and blockquote prefixes.
fn onlyMarker(line: []const u8) bool {
    var l = std.mem.trimStart(u8, line, "> ");
    if (std.mem.eql(u8, l, "-")) return true;
    if (l.len < 2 or l[l.len - 1] != '.') return false;
    l = l[0 .. l.len - 1];
    for (l) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

fn trimSpaces(w: *std.ArrayList(u8)) void {
    while (w.items.len > 0 and w.items[w.items.len - 1] == ' ') w.items.len -= 1;
}

/// Removes trailing spaces and a trailing bare blockquote prefix.
fn trimLineEnd(w: *std.ArrayList(u8), quote: u32) void {
    _ = quote;
    while (true) {
        trimSpaces(w);
        if (w.items.len > 0 and w.items[w.items.len - 1] == '>') {
            const ls = if (std.mem.lastIndexOfScalar(u8, w.items, '\n')) |p| p + 1 else 0;
            if (std.mem.trim(u8, w.items[ls..], "> ").len == 0) {
                w.items.len = ls;
                continue;
            }
        }
        return;
    }
}

fn appendCollapsed(a: Allocator, w: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    var space = false;
    for (std.mem.trim(u8, s, " \t\r\n")) |ch| {
        if (std.ascii.isWhitespace(ch)) {
            space = true;
            continue;
        }
        if (space) try w.append(a, ' ');
        space = false;
        try w.append(a, ch);
    }
}

/// Resolves `href` against `base` (RFC 3986, without dot-segment removal
/// for relative paths beyond `./` and `../`).
pub fn resolveUrl(a: Allocator, base: []const u8, href: []const u8) Allocator.Error![]const u8 {
    if (href.len == 0) return base;
    if (std.mem.indexOf(u8, href, "://") != null or std.ascii.startsWithIgnoreCase(href, "mailto:") or std.ascii.startsWithIgnoreCase(href, "data:")) return href;
    const scheme_end = std.mem.indexOf(u8, base, "://") orelse return href;
    const scheme = base[0..scheme_end];
    const after = base[scheme_end + 3 ..];
    const host_end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
    const origin = base[0 .. scheme_end + 3 + host_end];
    if (std.mem.startsWith(u8, href, "//")) return std.fmt.allocPrint(a, "{s}:{s}", .{ scheme, href });
    if (href[0] == '/') return std.fmt.allocPrint(a, "{s}{s}", .{ origin, href });
    const path_full = after[host_end..];
    const path_end = std.mem.indexOfAny(u8, path_full, "?#") orelse path_full.len;
    const path = path_full[0..path_end];
    if (href[0] == '?') return std.fmt.allocPrint(a, "{s}{s}{s}", .{ origin, path, href });
    if (href[0] == '#') return std.fmt.allocPrint(a, "{s}{s}{s}", .{ origin, path_full[0..@min(path_full.len, std.mem.indexOfScalar(u8, path_full, '#') orelse path_full.len)], href });
    const dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |p| path[0 .. p + 1] else "/";
    // Join and remove dot segments.
    var segs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, dir, '/');
    while (it.next()) |s| if (s.len > 0) try segs.append(a, s);
    const q = std.mem.indexOfAny(u8, href, "?#") orelse href.len;
    var rit = std.mem.splitScalar(u8, href[0..q], '/');
    var trailing = false;
    while (rit.next()) |s| {
        trailing = false;
        if (std.mem.eql(u8, s, ".")) {
            trailing = true;
        } else if (std.mem.eql(u8, s, "..")) {
            if (segs.items.len > 0) _ = segs.pop();
            trailing = true;
        } else if (s.len > 0) {
            try segs.append(a, s);
        } else trailing = true;
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, origin);
    for (segs.items) |s| try out.print(a, "/{s}", .{s});
    if (trailing or segs.items.len == 0) try out.append(a, '/');
    try out.appendSlice(a, href[q..]);
    return out.items;
}
