//! Page extraction for the source library (E13.F05.S01.T01): metadata
//! and the main content of an HTML page, as Markdown.
//!
//! Metadata: the title from `og:title` or `<title>`, the site from
//! `og:site_name` or the host, the publication date from
//! `article:published_time` or the first `<time datetime>`, and a
//! `<link rel="canonical">`.
//!
//! Main content, before E10's HTML-to-Markdown conversion: `nav`,
//! `header`, `footer`, `aside` and `form` go, and so do elements whose
//! class or id has a word starting with `nav`, `menu`, `footer`,
//! `sidebar`, `cookie`, `subscribe` or `share`. Then, unless the page
//! marks its content with `main` or `article` (the converter keeps those),
//! the densest block (`div`, `section`, `td`: text characters per tag)
//! holding at least 60% of the page's text is kept alone.
//!
//! Unlike readability-style extractors there is no scoring of commas,
//! link density or sibling merging, no image or byline extraction, and no
//! retrying with looser rules when little text is left: a page whose text
//! is spread thin keeps everything that survived the first pass.

const std = @import("std");
const zg_ai = @import("zg_ai");
const canon = @import("canon_url.zig");

const Allocator = std.mem.Allocator;
const html2md = zg_ai.tools.builtin.html2md;

pub const Extracted = struct {
    title: []const u8 = "",
    site: []const u8 = "",
    /// As written on the page (a date or date-time), if any.
    published: ?[]const u8 = null,
    canonical: ?[]const u8 = null,
    markdown: []const u8 = "",
};

const drop_tags = [_][]const u8{ "nav", "header", "footer", "aside", "form" };
const drop_words = [_][]const u8{ "nav", "menu", "footer", "sidebar", "cookie", "subscribe", "share" };
const block_tags = [_][]const u8{ "div", "section", "td" };
const void_tags = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" };
const raw_tags = [_][]const u8{ "script", "style", "noscript", "template", "textarea", "title" };

fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.ascii.eqlIgnoreCase(x, s)) return true;
    return false;
}

/// A start or end tag.
const Tag = struct {
    name: []const u8,
    end: bool,
    self_close: bool,
    /// The whole tag, `<` to `>`.
    start: usize,
    stop: usize,
    attrs: []const u8,

    fn attr(t: Tag, name: []const u8) ?[]const u8 {
        var i: usize = 0;
        const s = t.attrs;
        while (i < s.len) {
            while (i < s.len and (std.ascii.isWhitespace(s[i]) or s[i] == '/')) i += 1;
            const ns = i;
            while (i < s.len and !std.ascii.isWhitespace(s[i]) and s[i] != '=' and s[i] != '/') i += 1;
            const n = s[ns..i];
            while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
            var v: []const u8 = "";
            if (i < s.len and s[i] == '=') {
                i += 1;
                while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
                if (i < s.len and (s[i] == '"' or s[i] == '\'')) {
                    const q = s[i];
                    const e = std.mem.indexOfScalarPos(u8, s, i + 1, q) orelse s.len;
                    v = s[i + 1 .. e];
                    i = @min(s.len, e + 1);
                } else {
                    const vs = i;
                    while (i < s.len and !std.ascii.isWhitespace(s[i])) i += 1;
                    v = s[vs..i];
                }
            }
            if (n.len > 0 and std.ascii.eqlIgnoreCase(n, name)) return v;
            if (n.len == 0) i += 1;
        }
        return null;
    }
};

/// Walks tags and text runs; raw-text elements are passed over whole.
const Scanner = struct {
    src: []const u8,
    pos: usize = 0,
    raw: ?[2]usize = null,
    raw_tag: ?Tag = null,

    const Item = union(enum) { tag: Tag, text: [2]usize };

    fn next(sc: *Scanner) ?Item {
        const s = sc.src;
        while (sc.pos < s.len) {
            if (s[sc.pos] != '<') {
                const e = std.mem.indexOfScalarPos(u8, s, sc.pos, '<') orelse s.len;
                const r: [2]usize = .{ sc.pos, e };
                sc.pos = e;
                return .{ .text = r };
            }
            const lt = sc.pos;
            if (std.mem.startsWith(u8, s[lt..], "<!--")) {
                sc.pos = if (std.mem.indexOfPos(u8, s, lt + 4, "-->")) |e| e + 3 else s.len;
                continue;
            }
            if (lt + 1 < s.len and (s[lt + 1] == '!' or s[lt + 1] == '?')) {
                sc.pos = if (std.mem.indexOfScalarPos(u8, s, lt, '>')) |e| e + 1 else s.len;
                continue;
            }
            const end = lt + 1 < s.len and s[lt + 1] == '/';
            var i = lt + 1 + @intFromBool(end);
            if (i >= s.len or !std.ascii.isAlphabetic(s[i])) {
                // A lone '<' is text.
                const e = std.mem.indexOfScalarPos(u8, s, lt + 1, '<') orelse s.len;
                sc.pos = e;
                return .{ .text = .{ lt, e } };
            }
            const ns = i;
            while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-' or s[i] == ':')) i += 1;
            const name = s[ns..i];
            // The tag's end, past quoted attribute values.
            var k = i;
            var quote: u8 = 0;
            while (k < s.len) : (k += 1) {
                const c = s[k];
                if (quote != 0) {
                    if (c == quote) quote = 0;
                } else if (c == '"' or c == '\'') quote = c else if (c == '>') break;
            }
            const stop = @min(s.len, k + 1);
            const self_close = k > i and s[k - 1] == '/';
            const t: Tag = .{ .name = name, .end = end, .self_close = self_close, .start = lt, .stop = stop, .attrs = s[i..@min(k, s.len)] };
            sc.pos = stop;
            if (!end and inList(&raw_tags, name)) {
                // Skip to the matching end tag, reporting the content as one run.
                const close = findClose(s, stop, name);
                sc.raw = .{ stop, close.content_end };
                sc.raw_tag = .{ .name = name, .end = true, .self_close = false, .start = close.content_end, .stop = close.after, .attrs = "" };
                sc.pos = close.after;
            }
            return .{ .tag = t };
        }
        return null;
    }

    /// After a raw-text start tag: its content and end tag.
    fn takeRaw(sc: *Scanner) ?struct { content: [2]usize, end: Tag } {
        const r = sc.raw orelse return null;
        sc.raw = null;
        const t = sc.raw_tag.?;
        sc.raw_tag = null;
        return .{ .content = r, .end = t };
    }
};

fn findClose(s: []const u8, from: usize, name: []const u8) struct { content_end: usize, after: usize } {
    var k = from;
    while (std.mem.indexOfPos(u8, s, k, "</")) |p| {
        const n = p + 2;
        if (n + name.len <= s.len and std.ascii.eqlIgnoreCase(s[n .. n + name.len], name)) {
            const gt = std.mem.indexOfScalarPos(u8, s, n, '>') orelse s.len;
            return .{ .content_end = p, .after = @min(s.len, gt + 1) };
        }
        k = n;
    }
    return .{ .content_end = s.len, .after = s.len };
}

fn hasDropWord(v: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, v, " \t\n-_");
    while (it.next()) |w| for (drop_words) |d| {
        if (std.ascii.startsWithIgnoreCase(w, d)) return true;
    };
    return false;
}

fn dropped(t: Tag) bool {
    if (inList(&drop_tags, t.name)) return true;
    if (t.attr("class")) |c| if (hasDropWord(c)) return true;
    if (t.attr("id")) |c| if (hasDropWord(c)) return true;
    if (t.attr("role")) |r| if (std.ascii.eqlIgnoreCase(r, "navigation") or std.ascii.eqlIgnoreCase(r, "banner") or std.ascii.eqlIgnoreCase(r, "contentinfo")) return true;
    return false;
}

/// Decodes the few character references metadata uses.
pub fn decodeEntities(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return std.mem.trim(u8, s, " \t\r\n");
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') if (std.mem.indexOfScalarPos(u8, s, i, ';')) |semi| if (semi - i <= 10) {
            const ent = s[i + 1 .. semi];
            const named = [_][2][]const u8{ .{ "amp", "&" }, .{ "lt", "<" }, .{ "gt", ">" }, .{ "quot", "\"" }, .{ "apos", "'" }, .{ "nbsp", " " }, .{ "#39", "'" } };
            var done = false;
            for (named) |n| if (std.mem.eql(u8, ent, n[0])) {
                try out.appendSlice(a, n[1]);
                done = true;
            };
            if (!done and ent.len > 1 and ent[0] == '#') {
                const cp = if (ent[1] == 'x' or ent[1] == 'X') std.fmt.parseInt(u21, ent[2..], 16) catch null else std.fmt.parseInt(u21, ent[1..], 10) catch null;
                if (cp) |c| {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(c, &buf) catch 0;
                    if (n > 0) {
                        try out.appendSlice(a, buf[0..n]);
                        done = true;
                    }
                }
            }
            if (done) {
                i = semi + 1;
                continue;
            }
        };
        try out.append(a, s[i]);
        i += 1;
    }
    return std.mem.trim(u8, out.items, " \t\r\n");
}

/// Collapses whitespace runs (titles spread over lines).
fn oneLine(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    while (it.next()) |w| {
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, w);
    }
    return out.items;
}

const Elem = struct {
    name: []const u8,
    open: usize,
    close: usize = 0,
    text_at_open: usize,
    tags_at_open: usize,
    text: usize = 0,
    tags: usize = 0,
    block: bool,
};

/// Metadata and main-content Markdown of `html` fetched from `url`.
pub fn extract(a: Allocator, html: []const u8, url: []const u8) !Extracted {
    var ex: Extracted = .{};
    var og_title: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var og_site: ?[]const u8 = null;
    var has_focus = false;

    // One pass: metadata, dropped ranges, element text counts.
    var drops: std.ArrayList([2]usize) = .empty;
    var stack: std.ArrayList(Elem) = .empty;
    var elems: std.ArrayList(Elem) = .empty;
    var drop_depth: usize = 0;
    var drop_start: usize = 0;
    var drop_name: []const u8 = "";
    var text_total: usize = 0;
    var tags_total: usize = 0;
    var sc: Scanner = .{ .src = html };
    while (sc.next()) |item| switch (item) {
        .text => |r| {
            if (drop_depth > 0) continue;
            for (html[r[0]..r[1]]) |c| {
                if (!std.ascii.isWhitespace(c)) text_total += 1;
            }
        },
        .tag => |t| {
            if (sc.takeRaw()) |raw| {
                if (!t.end and std.ascii.eqlIgnoreCase(t.name, "title") and title == null) title = try oneLine(a, try decodeEntities(a, html[raw.content[0]..raw.content[1]]));
                continue;
            }
            if (!t.end) {
                if (std.ascii.eqlIgnoreCase(t.name, "meta")) {
                    const prop = t.attr("property") orelse t.attr("name") orelse "";
                    const content = t.attr("content") orelse "";
                    if (std.ascii.eqlIgnoreCase(prop, "og:title")) og_title = try decodeEntities(a, content);
                    if (std.ascii.eqlIgnoreCase(prop, "og:site_name")) og_site = try decodeEntities(a, content);
                    if (std.ascii.eqlIgnoreCase(prop, "article:published_time") and ex.published == null) ex.published = try a.dupe(u8, std.mem.trim(u8, content, " "));
                } else if (std.ascii.eqlIgnoreCase(t.name, "link")) {
                    const rel = t.attr("rel") orelse "";
                    if (std.ascii.eqlIgnoreCase(rel, "canonical")) if (t.attr("href")) |h| {
                        ex.canonical = try canon.resolve(a, url, try decodeEntities(a, h));
                    };
                } else if (std.ascii.eqlIgnoreCase(t.name, "time") and ex.published == null) {
                    if (t.attr("datetime")) |d| ex.published = try a.dupe(u8, std.mem.trim(u8, d, " "));
                }
                if (std.ascii.eqlIgnoreCase(t.name, "main") or std.ascii.eqlIgnoreCase(t.name, "article")) has_focus = true;
            }
            if (inList(&void_tags, t.name) or (t.self_close and !t.end)) {
                if (drop_depth == 0) tags_total += 1;
                continue;
            }
            if (drop_depth > 0) {
                if (std.ascii.eqlIgnoreCase(t.name, drop_name)) {
                    if (t.end) drop_depth -= 1 else drop_depth += 1;
                    if (drop_depth == 0) try drops.append(a, .{ drop_start, t.stop });
                }
                continue;
            }
            if (!t.end) {
                if (dropped(t)) {
                    drop_depth = 1;
                    drop_start = t.start;
                    drop_name = t.name;
                    continue;
                }
                tags_total += 1;
                try stack.append(a, .{ .name = t.name, .open = t.start, .text_at_open = text_total, .tags_at_open = tags_total, .block = inList(&block_tags, t.name) });
            } else {
                // Close the nearest open element of that name.
                var k = stack.items.len;
                while (k > 0) {
                    k -= 1;
                    if (std.ascii.eqlIgnoreCase(stack.items[k].name, t.name)) break;
                } else continue;
                while (stack.items.len > k) {
                    var e = stack.pop().?;
                    e.close = t.stop;
                    e.text = text_total - e.text_at_open;
                    e.tags = tags_total - e.tags_at_open;
                    if (e.block) try elems.append(a, e);
                }
            }
        },
    };
    if (drop_depth > 0) try drops.append(a, .{ drop_start, html.len });

    ex.title = og_title orelse title orelse "";
    ex.site = og_site orelse try canon.site(a, url);

    // The densest block holding most of the text.
    var lo: usize = 0;
    var hi: usize = html.len;
    if (!has_focus and text_total > 0) {
        var best: ?Elem = null;
        var best_density: f64 = 0;
        for (elems.items) |e| {
            if (e.text * 10 < text_total * 6) continue;
            const d = @as(f64, @floatFromInt(e.text)) / @as(f64, @floatFromInt(e.tags + 1));
            if (best == null or d > best_density) {
                best = e;
                best_density = d;
            }
        }
        if (best) |b| {
            lo = b.open;
            hi = b.close;
        }
    }
    // The page with the dropped parts cut out.
    var kept: std.ArrayList(u8) = .empty;
    var at = lo;
    for (drops.items) |d| {
        if (d[1] <= at or d[0] >= hi) continue;
        if (d[0] > at) try kept.appendSlice(a, html[at..d[0]]);
        at = @max(at, d[1]);
    }
    if (at < hi) try kept.appendSlice(a, html[at..hi]);
    ex.markdown = std.mem.trim(u8, try html2md.htmlToMarkdown(a, kept.items, url, .{}), " \n");
    return ex;
}
