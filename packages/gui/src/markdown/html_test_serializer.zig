//! Test-only HTML output of a `Doc`, in the format of the CommonMark and
//! GFM spec examples, so the parser can be checked against them. Raw
//! HTML passes through here (the spec expects that); the GUI view never
//! renders it.

const std = @import("std");
const ast = @import("ast.zig");
const doc_mod = @import("doc.zig");

const Allocator = std.mem.Allocator;
const Doc = doc_mod.Doc;
const none = ast.none;

pub fn render(gpa: Allocator, d: *const Doc) ![]u8 {
    var r: Renderer = .{ .gpa = gpa, .d = d };
    errdefer r.out.deinit(gpa);
    try r.blockChildren(0);
    return r.out.toOwnedSlice(gpa);
}

const Renderer = struct {
    gpa: Allocator,
    d: *const Doc,
    out: std.ArrayList(u8) = .empty,
    /// Inside image alt text: tags are dropped.
    plain: u32 = 0,

    fn w(r: *Renderer, s: []const u8) !void {
        try r.out.appendSlice(r.gpa, s);
    }

    fn cr(r: *Renderer) !void {
        if (r.out.items.len > 0 and r.out.items[r.out.items.len - 1] != '\n') try r.out.append(r.gpa, '\n');
    }

    fn esc(r: *Renderer, s: []const u8) !void {
        for (s) |c| switch (c) {
            '&' => try r.w("&amp;"),
            '<' => try r.w("&lt;"),
            '>' => try r.w("&gt;"),
            '"' => try r.w("&quot;"),
            0 => try r.w("\u{FFFD}"),
            else => try r.out.append(r.gpa, c),
        };
    }

    /// Percent-encodes a URL like commonmark.js (`mdurl.encode`), then
    /// escapes it for an attribute.
    fn url(r: *Renderer, s: []const u8) !void {
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '%' and i + 2 < s.len and std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2])) {
                try r.out.append(r.gpa, '%');
                continue;
            }
            if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, ";/?:@&=+$,-_.!~*'()#", c) != null) {
                if (c == '&') try r.w("&amp;") else if (c == '\'') try r.w("'") else try r.out.append(r.gpa, c);
            } else {
                var buf: [3]u8 = undefined;
                _ = std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch unreachable;
                try r.w(&buf);
            }
        }
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
        switch (b.kind) {
            .document => try r.blockChildren(i),
            .paragraph => {
                if (r.tightParagraph(i)) {
                    try r.inlines(b.first_inline);
                } else {
                    try r.cr();
                    try r.w("<p>");
                    try r.inlines(b.first_inline);
                    try r.w("</p>");
                    try r.cr();
                }
            },
            .heading => {
                try r.cr();
                try r.out.print(r.gpa, "<h{d}>", .{b.level});
                try r.inlines(b.first_inline);
                try r.out.print(r.gpa, "</h{d}>", .{b.level});
                try r.cr();
            },
            .thematic_break => {
                try r.cr();
                try r.w("<hr />");
                try r.cr();
            },
            .code_fenced, .code_indented => {
                try r.cr();
                try r.w("<pre><code");
                if (b.kind == .code_fenced) {
                    const info = r.d.contentOf(b.info);
                    if (info.len > 0) {
                        const word_end = std.mem.indexOfAny(u8, info, " \t\n") orelse info.len;
                        try r.w(" class=\"language-");
                        try r.esc(info[0..word_end]);
                        try r.w("\"");
                    }
                }
                try r.w(">");
                try r.esc(r.d.contentOf(b.content));
                try r.w("</code></pre>");
                try r.cr();
            },
            .math_block, .front_matter => {
                try r.cr();
                try r.w("<pre><code class=\"language-math\">");
                try r.esc(r.d.contentOf(b.content));
                try r.w("</code></pre>");
                try r.cr();
            },
            .html_literal => {
                try r.cr();
                try r.w(r.d.contentOf(b.content));
                try r.cr();
            },
            .block_quote, .callout => {
                try r.cr();
                try r.w("<blockquote>");
                try r.cr();
                try r.blockChildren(i);
                try r.cr();
                try r.w("</blockquote>");
                try r.cr();
            },
            .list => {
                try r.cr();
                if (b.list.ordered) {
                    if (b.list.start != 1) try r.out.print(r.gpa, "<ol start=\"{d}\">", .{b.list.start}) else try r.w("<ol>");
                } else try r.w("<ul>");
                try r.cr();
                try r.blockChildren(i);
                try r.cr();
                try r.w(if (b.list.ordered) "</ol>" else "</ul>");
                try r.cr();
            },
            .list_item => {
                try r.w("<li>");
                switch (b.task) {
                    .none => {},
                    .unchecked => try r.w("<input disabled=\"\" type=\"checkbox\"> "),
                    .checked => try r.w("<input checked=\"\" disabled=\"\" type=\"checkbox\"> "),
                }
                try r.blockChildren(i);
                try r.w("</li>");
                try r.cr();
            },
            .table => {
                try r.cr();
                try r.w("<table>\n<thead>\n");
                var row = b.first_child;
                var body = false;
                while (row != none) : (row = r.d.blocks.items[row].next) {
                    const header = r.d.blocks.items[row].level == 1;
                    if (!header and !body) {
                        try r.w("<tbody>\n");
                        body = true;
                    }
                    try r.w("<tr>\n");
                    var cell = r.d.blocks.items[row].first_child;
                    while (cell != none) : (cell = r.d.blocks.items[cell].next) {
                        const cb = r.d.blocks.items[cell];
                        const tag = if (header) "th" else "td";
                        try r.out.print(r.gpa, "<{s}", .{tag});
                        switch (cb.align_) {
                            .none => {},
                            .left => try r.w(" align=\"left\""),
                            .center => try r.w(" align=\"center\""),
                            .right => try r.w(" align=\"right\""),
                        }
                        try r.w(">");
                        try r.inlines(cb.first_inline);
                        try r.out.print(r.gpa, "</{s}>\n", .{tag});
                    }
                    try r.w("</tr>\n");
                    if (header) try r.w("</thead>\n");
                }
                if (body) try r.w("</tbody>\n");
                try r.w("</table>");
                try r.cr();
            },
            else => {},
        }
    }

    fn inlines(r: *Renderer, first: u32) anyerror!void {
        var c = first;
        while (c != none) : (c = r.d.inlines.items[c].next) try r.inl(c);
    }

    fn inl(r: *Renderer, i: u32) anyerror!void {
        const n = &r.d.inlines.items[i];
        switch (n.kind) {
            .text => try r.esc(r.d.inlineText(n)),
            .softbreak => try r.w("\n"),
            .hardbreak => try r.w(if (r.plain > 0) "\n" else "<br />\n"),
            .code => {
                if (r.plain == 0) try r.w("<code>");
                try r.esc(r.d.inlineText(n));
                if (r.plain == 0) try r.w("</code>");
            },
            .emph, .strong, .strike => {
                const tag = switch (n.kind) {
                    .emph => "em",
                    .strong => "strong",
                    else => "del",
                };
                if (r.plain == 0) try r.out.print(r.gpa, "<{s}>", .{tag});
                try r.inlines(n.first_child);
                if (r.plain == 0) try r.out.print(r.gpa, "</{s}>", .{tag});
            },
            .link => {
                if (r.plain == 0) {
                    try r.w("<a href=\"");
                    try r.url(r.d.destOf(n));
                    try r.w("\"");
                    const t = r.d.titleOf(n);
                    if (t.len > 0) {
                        try r.w(" title=\"");
                        try r.esc(t);
                        try r.w("\"");
                    }
                    try r.w(">");
                }
                try r.inlines(n.first_child);
                if (r.plain == 0) try r.w("</a>");
            },
            .image => {
                if (r.plain == 0) {
                    try r.w("<img src=\"");
                    try r.url(r.d.destOf(n));
                    try r.w("\" alt=\"");
                }
                r.plain += 1;
                try r.inlines(n.first_child);
                r.plain -= 1;
                if (r.plain == 0) {
                    try r.w("\"");
                    const t = r.d.titleOf(n);
                    if (t.len > 0) {
                        try r.w(" title=\"");
                        try r.esc(t);
                        try r.w("\"");
                    }
                    try r.w(" />");
                }
            },
            .autolink => {
                if (r.plain == 0) {
                    try r.w("<a href=\"");
                    try r.url(r.d.destOf(n));
                    try r.w("\">");
                }
                try r.esc(r.d.contentOf(n.text));
                if (r.plain == 0) try r.w("</a>");
            },
            .html_literal => try r.w(r.d.inlineText(n)),
            .wikilink, .embed => {
                try r.w("<a class=\"wikilink\" href=\"");
                try r.esc(r.d.inlineText(n));
                try r.w("\">");
                if (n.first_child != none) try r.inlines(n.first_child) else try r.esc(r.d.inlineText(n));
                try r.w("</a>");
            },
            .math => {
                try r.w("<span class=\"math\">");
                try r.esc(r.d.inlineText(n));
                try r.w("</span>");
            },
            .footnote_ref => {},
        }
    }
};
