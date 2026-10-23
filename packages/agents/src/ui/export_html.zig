//! Standalone HTML export (E13.F04.S01.T03): a Markdown document as one
//! self-contained, safe HTML5 file. It renders the same block tree the
//! in-app preview draws (zg_gui.markdown, CommonMark + GFM): headings,
//! lists and task lists, tables, quotes and callouts, code (highlighted
//! through a port), math as code, images embedded as data URIs, and
//! `mermaid` fences as inline SVG through a diagram port.
//!
//! Safety: all text is escaped; raw HTML is dropped unless the caller
//! allows it, and then goes through docs.html_sanitize like SVG images
//! and diagrams do; links keep only relative, http(s) and mailto
//! targets; local images load only from below `base_dir`; remote images
//! become links, so opening the file makes no request the reader did not
//! click.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const md = zg_gui.markdown;
const ast = md.ast;
const Doc = md.Doc;
const none = ast.none;
const sanitize = zg_agents.docs.html_sanitize;

/// Writes `code` as HTML (escaped, with `hl-*` class spans); false to
/// fall back to plain escaped text. Supplied by the editor's highlighter.
pub const HighlightFn = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, lang: []const u8, code: []const u8, w: *Writer) anyerror!bool,
};

/// Renders a diagram's source to SVG; false when it does not parse.
pub const DiagramSvgFn = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, src: []const u8, w: *Writer) anyerror!bool,
};

pub const Theme = enum { auto, light, dark };

pub const ExportOpts = struct {
    allow_raw_html: bool = false,
    embed_images_max_bytes: u32 = 2 << 20,
    theme: Theme = .auto,
    highlight: ?HighlightFn = null,
    diagram_svg: ?DiagramSvgFn = null,
    /// Where relative image paths resolve; null links them instead.
    base_dir: ?Io.Dir = null,
    /// The page title; the first heading when null.
    title: ?[]const u8 = null,
};

/// Parses `src` and exports it.
pub fn exportMarkdown(io: Io, arena: Allocator, src: []const u8, w: *Writer, opts: ExportOpts) !void {
    var doc = try md.parse(arena, src, .{});
    defer doc.deinit();
    try exportHtml(io, arena, &doc, w, opts);
}

pub fn exportHtml(io: Io, arena: Allocator, doc: *const Doc, out: *Writer, opts: ExportOpts) !void {
    // Rendered whole first: line breaks depend on what was written last.
    var page: Writer.Allocating = try .initCapacity(arena, doc.src.items.len * 2 + css_base.len + 4096);
    const w = &page.writer;
    var r: Renderer = .{ .io = io, .a = arena, .d = doc, .w = w, .o = opts };
    try w.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    // Nothing loads or runs unless the reader follows a link.
    try w.writeAll("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'\">\n");
    try w.writeAll("<title>");
    if (opts.title) |t| try r.esc(t) else try r.plainTitle();
    try w.writeAll("</title>\n<style>\n");
    try w.writeAll(css_base);
    switch (opts.theme) {
        .auto => try w.print("@media (prefers-color-scheme: dark) {{\n{s}}}\n", .{css_dark}),
        .light => {},
        .dark => try w.writeAll(css_dark),
    }
    try w.writeAll("</style>\n</head>\n<body>\n<main>\n");
    try r.blockChildren(0);
    try r.cr();
    try w.writeAll("</main>\n</body>\n</html>\n");
    try out.writeAll(page.written());
}

const css_base =
    \\:root { --fg: #1f2328; --bg: #ffffff; --muted: #59636e; --border: #d1d9e0; --code-bg: #f6f8fa; --accent: #0969da; --note: #0969da; --warn: #9a6700; --danger: #d1242f; }
    \\body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif; }
    \\main { max-width: 72ch; margin: 0 auto; padding: 2rem 1rem; }
    \\h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.5em 0 0.5em; }
    \\a { color: var(--accent); }
    \\code, pre { font-family: ui-monospace, "Cascadia Code", Menlo, monospace; font-size: 0.9em; }
    \\code { background: var(--code-bg); padding: 0.1em 0.3em; border-radius: 4px; }
    \\pre { background: var(--code-bg); padding: 0.8em 1em; overflow-x: auto; border-radius: 6px; }
    \\pre code { background: none; padding: 0; }
    \\blockquote { margin: 1em 0; padding: 0 1em; border-left: 4px solid var(--border); color: var(--muted); }
    \\.callout { border-left-color: var(--note); }
    \\.callout-warning, .callout-caution { border-left-color: var(--warn); }
    \\.callout-danger, .callout-important { border-left-color: var(--danger); }
    \\.callout-title { font-weight: 600; color: var(--fg); }
    \\table { border-collapse: collapse; margin: 1em 0; }
    \\th, td { border: 1px solid var(--border); padding: 0.3em 0.7em; }
    \\img, svg { max-width: 100%; height: auto; }
    \\figure.diagram { margin: 1em 0; text-align: center; }
    \\li.task { list-style: none; }
    \\hr { border: 0; border-top: 1px solid var(--border); }
    \\.hl-keyword { color: #cf222e; } .hl-string { color: #0a3069; } .hl-comment { color: #59636e; font-style: italic; }
    \\.hl-number, .hl-constant { color: #0550ae; } .hl-type { color: #953800; } .hl-function { color: #8250df; }
    \\
;

const css_dark =
    \\:root { --fg: #f0f6fc; --bg: #0d1117; --muted: #9198a1; --border: #3d444d; --code-bg: #151b23; --accent: #4493f8; --note: #4493f8; --warn: #d29922; --danger: #f85149; }
    \\.hl-keyword { color: #ff7b72; } .hl-string { color: #a5d6ff; } .hl-comment { color: #9198a1; }
    \\.hl-number, .hl-constant { color: #79c0ff; } .hl-type { color: #ffa657; } .hl-function { color: #d2a8ff; }
    \\
;

const Renderer = struct {
    io: Io,
    a: Allocator,
    d: *const Doc,
    w: *Writer,
    o: ExportOpts,
    /// Inside image alt text: tags are dropped.
    plain: u32 = 0,
    /// Collecting a heading's text for its anchor: nothing is escaped.
    raw: bool = false,

    fn cr(r: *Renderer) !void {
        const buf = r.w.buffered();
        if (buf.len > 0 and buf[buf.len - 1] != '\n') try r.w.writeByte('\n');
    }

    fn esc(r: *Renderer, s: []const u8) !void {
        if (r.raw) return r.w.writeAll(s);
        try escapeTo(r.w, s);
    }

    /// The first heading's text, as the title.
    fn plainTitle(r: *Renderer) !void {
        for (r.d.blocks.items) |b| if (b.kind == .heading) {
            r.plain += 1;
            defer r.plain -= 1;
            return r.inlines(b.first_inline);
        };
        try r.w.writeAll("Document");
    }

    fn blockChildren(r: *Renderer, i: u32) anyerror!void {
        var c = r.d.blocks.items[i].first_child;
        while (c != none) : (c = r.d.blocks.items[c].next) try r.block(c);
    }

    fn tightParagraph(r: *Renderer, i: u32) bool {
        const parent = r.d.blocks.items[i].parent;
        if (parent == none or r.d.blocks.items[parent].kind != .list_item) return false;
        const list = r.d.blocks.items[parent].parent;
        return list != none and r.d.blocks.items[list].list.tight;
    }

    fn block(r: *Renderer, i: u32) anyerror!void {
        const b = r.d.blocks.items[i];
        const w = r.w;
        switch (b.kind) {
            .document => try r.blockChildren(i),
            .paragraph => {
                if (r.tightParagraph(i)) {
                    try r.inlines(b.first_inline);
                } else {
                    try r.cr();
                    try w.writeAll("<p>");
                    try r.inlines(b.first_inline);
                    try w.writeAll("</p>\n");
                }
            },
            .heading => {
                try r.cr();
                try w.print("<h{d} id=\"", .{b.level});
                try r.slug(b.first_inline);
                try w.writeAll("\">");
                try r.inlines(b.first_inline);
                try w.print("</h{d}>\n", .{b.level});
            },
            .thematic_break => {
                try r.cr();
                try w.writeAll("<hr>\n");
            },
            .code_fenced, .code_indented => try r.code(b),
            .math_block => {
                try r.cr();
                try w.writeAll("<pre class=\"math\"><code>");
                try r.esc(r.d.contentOf(b.content));
                try w.writeAll("</code></pre>\n");
            },
            .front_matter, .link_ref_def => {},
            .html_literal => {
                if (!r.o.allow_raw_html) return;
                try r.cr();
                try r.rawHtml(r.d.contentOf(b.content));
                try r.cr();
            },
            .block_quote => {
                try r.cr();
                try w.writeAll("<blockquote>\n");
                try r.blockChildren(i);
                try r.cr();
                try w.writeAll("</blockquote>\n");
            },
            .callout => {
                const kind = r.d.contentOf(b.info);
                const title = r.d.contentOf(b.title);
                try r.cr();
                try w.writeAll("<blockquote class=\"callout callout-");
                try r.classWord(kind);
                try w.writeAll("\">\n<p class=\"callout-title\">");
                if (title.len > 0) try r.esc(title) else try r.titleCase(kind);
                try w.writeAll("</p>\n");
                try r.blockChildren(i);
                try r.cr();
                try w.writeAll("</blockquote>\n");
            },
            .list => {
                try r.cr();
                if (b.list.ordered) {
                    if (b.list.start != 1) try w.print("<ol start=\"{d}\">\n", .{b.list.start}) else try w.writeAll("<ol>\n");
                } else try w.writeAll("<ul>\n");
                try r.blockChildren(i);
                try r.cr();
                try w.writeAll(if (b.list.ordered) "</ol>\n" else "</ul>\n");
            },
            .list_item => {
                switch (b.task) {
                    .none => try w.writeAll("<li>"),
                    .unchecked => try w.writeAll("<li class=\"task\"><input type=\"checkbox\" disabled> "),
                    .checked => try w.writeAll("<li class=\"task\"><input type=\"checkbox\" checked disabled> "),
                }
                try r.blockChildren(i);
                try w.writeAll("</li>\n");
            },
            .table => try r.table(i),
            .footnote_def => {
                try r.cr();
                try w.writeAll("<div class=\"footnote\">\n");
                try r.blockChildren(i);
                try r.cr();
                try w.writeAll("</div>\n");
            },
            .table_row, .table_cell => {},
        }
    }

    fn table(r: *Renderer, i: u32) !void {
        const w = r.w;
        try r.cr();
        try w.writeAll("<table>\n<thead>\n");
        var row = r.d.blocks.items[i].first_child;
        var body = false;
        while (row != none) : (row = r.d.blocks.items[row].next) {
            const header = r.d.blocks.items[row].level == 1;
            if (!header and !body) {
                try w.writeAll("<tbody>\n");
                body = true;
            }
            try w.writeAll("<tr>\n");
            var cell = r.d.blocks.items[row].first_child;
            while (cell != none) : (cell = r.d.blocks.items[cell].next) {
                const cb = r.d.blocks.items[cell];
                const tag = if (header) "th" else "td";
                try w.print("<{s}", .{tag});
                switch (cb.align_) {
                    .none => {},
                    .left => try w.writeAll(" style=\"text-align: left\""),
                    .center => try w.writeAll(" style=\"text-align: center\""),
                    .right => try w.writeAll(" style=\"text-align: right\""),
                }
                try w.writeAll(">");
                try r.inlines(cb.first_inline);
                try w.print("</{s}>\n", .{tag});
            }
            try w.writeAll("</tr>\n");
            if (header) try w.writeAll("</thead>\n");
        }
        if (body) try w.writeAll("</tbody>\n");
        try w.writeAll("</table>\n");
    }

    fn code(r: *Renderer, b: ast.Block) !void {
        const w = r.w;
        const text = r.d.contentOf(b.content);
        const info = if (b.kind == .code_fenced) r.d.contentOf(b.info) else "";
        const lang = info[0 .. std.mem.indexOfAny(u8, info, " \t\n") orelse info.len];
        try r.cr();
        if (std.ascii.eqlIgnoreCase(lang, "mermaid")) {
            if (r.o.diagram_svg) |dg| {
                var buf: Writer.Allocating = .init(r.a);
                const ok = dg.f(dg.ctx, text, &buf.writer) catch false;
                if (ok) if (sanitize.sanitize(r.a, buf.written())) |svg| {
                    try w.writeAll("<figure class=\"diagram\">\n");
                    try w.writeAll(svg);
                    try r.cr();
                    try w.writeAll("</figure>\n");
                    return;
                } else |_| {};
                try w.writeAll("<!-- diagram could not be rendered -->\n");
            }
        }
        try w.writeAll("<pre><code");
        if (lang.len > 0) {
            try w.writeAll(" class=\"language-");
            try r.classWord(lang);
            try w.writeAll("\"");
        }
        try w.writeAll(">");
        if (lang.len > 0) if (r.o.highlight) |h| {
            var buf: Writer.Allocating = .init(r.a);
            if (h.f(h.ctx, lang, text, &buf.writer) catch false) {
                try w.writeAll(buf.written());
                try w.writeAll("</code></pre>\n");
                return;
            }
        };
        try r.esc(text);
        try w.writeAll("</code></pre>\n");
    }

    /// Letters, digits and dashes only (for class names).
    fn classWord(r: *Renderer, s: []const u8) !void {
        for (s) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '+') try r.w.writeByte(std.ascii.toLower(c)) else try r.w.writeByte('-');
        }
    }

    fn titleCase(r: *Renderer, s: []const u8) !void {
        if (s.len == 0) return r.w.writeAll("Note");
        try r.w.writeByte(std.ascii.toUpper(s[0]));
        try r.esc(s[1..]);
    }

    /// The heading's anchor: its plain text, slugged like the outline.
    fn slug(r: *Renderer, first: u32) !void {
        var buf: Writer.Allocating = .init(r.a);
        const saved = r.w;
        r.w = &buf.writer;
        r.plain += 1;
        r.raw = true;
        r.inlines(first) catch {};
        r.raw = false;
        r.plain -= 1;
        r.w = saved;
        const s = try zg_agents.docs.sections.slugify(r.a, buf.written());
        try r.esc(s);
    }

    fn rawHtml(r: *Renderer, html: []const u8) !void {
        const clean = sanitize.sanitize(r.a, html) catch |err| switch (err) {
            error.Malformed => return r.esc(html),
            else => |e| return e,
        };
        try r.w.writeAll(clean);
    }

    fn inlines(r: *Renderer, first: u32) anyerror!void {
        var c = first;
        while (c != none) : (c = r.d.inlines.items[c].next) try r.inl(c);
    }

    fn inl(r: *Renderer, i: u32) anyerror!void {
        const n = &r.d.inlines.items[i];
        const w = r.w;
        const tags = r.plain == 0;
        switch (n.kind) {
            .text => try r.esc(r.d.inlineText(n)),
            .softbreak => try w.writeByte('\n'),
            .hardbreak => try w.writeAll(if (tags) "<br>\n" else "\n"),
            .code, .math => {
                if (tags) try w.writeAll(if (n.kind == .math) "<code class=\"math\">" else "<code>");
                try r.esc(r.d.inlineText(n));
                if (tags) try w.writeAll("</code>");
            },
            .emph, .strong, .strike => {
                const tag = switch (n.kind) {
                    .emph => "em",
                    .strong => "strong",
                    else => "del",
                };
                if (tags) try w.print("<{s}>", .{tag});
                try r.inlines(n.first_child);
                if (tags) try w.print("</{s}>", .{tag});
            },
            .link, .autolink => {
                const dest = r.d.destOf(n);
                const ok = tags and !n.unsafe and sanitize.safeLink(dest);
                if (ok) {
                    try w.writeAll("<a href=\"");
                    try r.esc(dest);
                    try w.writeAll("\"");
                    const t = r.d.titleOf(n);
                    if (t.len > 0) {
                        try w.writeAll(" title=\"");
                        try r.esc(t);
                        try w.writeAll("\"");
                    }
                    try w.writeAll(">");
                }
                if (n.kind == .autolink) try r.esc(r.d.contentOf(n.text)) else try r.inlines(n.first_child);
                if (ok) try w.writeAll("</a>");
            },
            .image => try r.image(n, r.d.destOf(n)),
            .wikilink, .embed => {
                const target = r.d.inlineText(n);
                if (n.kind == .embed and isImagePath(target)) return r.image(n, target);
                if (!tags) return if (n.first_child != none) r.inlines(n.first_child) else r.esc(target);
                try w.writeAll("<a class=\"wikilink\" href=\"");
                try r.wikiHref(target);
                try w.writeAll("\">");
                if (n.first_child != none) try r.inlines(n.first_child) else try r.esc(target);
                try w.writeAll("</a>");
            },
            .html_literal => if (r.o.allow_raw_html and tags) try r.rawHtml(r.d.inlineText(n)),
            .footnote_ref => {
                if (tags) try w.writeAll("<sup class=\"footnote-ref\">");
                try r.esc(r.d.inlineText(n));
                if (tags) try w.writeAll("</sup>");
            },
        }
    }

    /// `Page#Heading` → `Page.md#heading`, percent-encoding spaces.
    fn wikiHref(r: *Renderer, target: []const u8) !void {
        const hash = std.mem.indexOfScalar(u8, target, '#');
        const page = std.mem.trim(u8, target[0 .. hash orelse target.len], " ");
        try r.urlPart(page);
        if (page.len > 0 and std.fs.path.extension(page).len == 0) try r.w.writeAll(".md");
        if (hash) |h| {
            try r.w.writeByte('#');
            try r.esc(try zg_agents.docs.sections.slugify(r.a, target[h + 1 ..]));
        }
    }

    fn urlPart(r: *Renderer, s: []const u8) !void {
        for (s) |c| switch (c) {
            ' ' => try r.w.writeAll("%20"),
            '"' => try r.w.writeAll("%22"),
            '<' => try r.w.writeAll("%3C"),
            '>' => try r.w.writeAll("%3E"),
            '&' => try r.w.writeAll("&amp;"),
            ':' => try r.w.writeAll("%3A"),
            else => try r.w.writeByte(c),
        };
    }

    fn image(r: *Renderer, n: *const ast.Inline, dest: []const u8) !void {
        const w = r.w;
        if (r.plain > 0) {
            // Alt text of an image inside alt text.
            return if (n.first_child != none) r.inlines(n.first_child) else {};
        }
        var alt: Writer.Allocating = .init(r.a);
        {
            const saved = r.w;
            r.w = &alt.writer;
            r.plain += 1;
            defer {
                r.plain -= 1;
                r.w = saved;
            }
            if (n.first_child != none) try r.inlines(n.first_child) else if (n.kind == .embed) try r.esc(dest);
        }
        if (try r.embed(dest)) |data| {
            try w.writeAll("<img src=\"");
            try w.writeAll(data);
            try w.writeAll("\" alt=\"");
            try w.writeAll(alt.written());
            try w.writeAll("\"");
            const t = if (n.kind == .image) r.d.titleOf(n) else "";
            if (t.len > 0) {
                try w.writeAll(" title=\"");
                try r.esc(t);
                try w.writeAll("\"");
            }
            try w.writeAll(">");
            return;
        }
        // Linked (too large, remote, unreadable or not an image).
        const label = if (alt.written().len > 0) alt.written() else "image";
        if (!n.unsafe and sanitize.safeLink(dest)) {
            try w.writeAll("<a class=\"image-link\" href=\"");
            try r.esc(dest);
            try w.writeAll("\">");
            try w.writeAll(label);
            try w.writeAll("</a>");
        } else try w.writeAll(label);
    }

    /// A data URI for a local image under `base_dir`, or null.
    fn embed(r: *Renderer, dest: []const u8) !?[]const u8 {
        if (sanitize.safeImageData(dest)) {
            // Already embedded: keep it when it is plain base64.
            const comma = std.mem.indexOfScalar(u8, dest, ',') orelse return null;
            for (dest[comma + 1 ..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=')) return null;
            return dest;
        }
        const dir = r.o.base_dir orelse return null;
        const path = localPath(r.a, dest) orelse return null;
        const bytes = dir.readFileAlloc(r.io, path, r.a, .limited(r.o.embed_images_max_bytes + 1)) catch return null;
        if (bytes.len > r.o.embed_images_max_bytes) return null;
        const mime = sniff(bytes) orelse return null;
        const body = if (std.mem.eql(u8, mime, "image/svg+xml")) sanitize.sanitize(r.a, bytes) catch return null else bytes;
        const enc = std.base64.standard.Encoder;
        const prefix = try std.fmt.allocPrint(r.a, "data:{s};base64,", .{mime});
        const out = try r.a.alloc(u8, prefix.len + enc.calcSize(body.len));
        @memcpy(out[0..prefix.len], prefix);
        _ = enc.encode(out[prefix.len..], body);
        return out;
    }
};

/// A relative path without `..`, schemes or a leading slash, with
/// percent-escapes decoded; null otherwise.
pub fn localPath(a: Allocator, dest: []const u8) ?[]const u8 {
    var buf: [16]u8 = undefined;
    const scheme = sanitize.schemeOf(dest, &buf) orelse return null;
    if (scheme.len > 0 or dest.len == 0) return null;
    const end = std.mem.indexOfAny(u8, dest, "?#") orelse dest.len;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    const s = dest[0..end];
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len and std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2])) {
            out.append(a, std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return null) catch return null;
            i += 2;
        } else out.append(a, if (s[i] == '\\') '/' else s[i]) catch return null;
    }
    const p = out.items;
    if (p.len == 0 or p[0] == '/' or std.mem.indexOfScalar(u8, p, 0) != null) return null;
    if (p.len >= 2 and p[1] == ':') return null;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |part| if (std.mem.eql(u8, part, "..")) return null;
    return p;
}

/// The image type, by magic bytes.
pub fn sniff(b: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, b, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (std.mem.startsWith(u8, b, "\xff\xd8\xff")) return "image/jpeg";
    if (std.mem.startsWith(u8, b, "GIF87a") or std.mem.startsWith(u8, b, "GIF89a")) return "image/gif";
    if (b.len >= 12 and std.mem.eql(u8, b[0..4], "RIFF") and std.mem.eql(u8, b[8..12], "WEBP")) return "image/webp";
    const head = std.mem.trimStart(u8, b[0..@min(b.len, 1024)], "\xef\xbb\xbf \t\r\n");
    if ((std.mem.startsWith(u8, head, "<?xml") or std.mem.startsWith(u8, head, "<svg") or std.mem.startsWith(u8, head, "<!--")) and std.mem.indexOf(u8, head, "<svg") != null) return "image/svg+xml";
    return null;
}

fn isImagePath(p: []const u8) bool {
    const ext = std.fs.path.extension(p);
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

pub fn escapeTo(w: *Writer, s: []const u8) Writer.Error!void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const rep: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            0 => "\u{FFFD}",
            else => continue,
        };
        try w.writeAll(s[start..i]);
        try w.writeAll(rep);
        start = i + 1;
    }
    try w.writeAll(s[start..]);
}
