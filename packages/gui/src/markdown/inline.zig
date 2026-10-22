//! Markdown phase 2, inlines (E04.F06.S01.T03): CommonMark 0.31.2 code
//! spans, emphasis by delimiter runs, links and images with the bracket
//! stack, autolinks, raw HTML (kept as `html_literal`), entities, escapes
//! and line breaks; GFM strikethrough and extended autolinks; zigguro
//! `[[wikilinks|alias]]`, `![[embeds]]` and `$math$`.
//!
//! The algorithm follows the spec appendix ("process emphasis", "look
//! for link or image") with `openers_bottom` per delimiter kind, length
//! mod 3 and can-open, and memoized backtick runs, so pathological input
//! stays linear.

const std = @import("std");
const zg_text = @import("zg_text");
const ast = @import("ast.zig");
const doc_mod = @import("doc.zig");
const links = @import("links.zig");
const entities = @import("entities.zig");
const html = @import("html.zig");

const Allocator = std.mem.Allocator;
const Doc = doc_mod.Doc;
const Inline = ast.Inline;
const none = ast.none;
const Error = Allocator.Error;

/// The parser for `Doc.inline_parser`.
pub fn inlineParser() doc_mod.InlineParser {
    return .{ .parseLeaf = parseLeafErased };
}

fn parseLeafErased(_: ?*anyopaque, doc: *Doc, block: u32) Error!void {
    return parseInlines(doc, block);
}

/// Parses a leaf block's text into inlines (sets `Block.first_inline`).
pub fn parseInlines(doc: *Doc, block: u32) Error!void {
    const c = doc.blocks.items[block].content;
    var p: Parser = .{ .doc = doc, .gpa = doc.gpa, .base = c[0], .s = doc.content.items[c[0]..c[1]], .top = doc.topOf(block) };
    defer p.delims.deinit(p.gpa);
    defer p.brackets.deinit(p.gpa);
    p.root = try doc.addInline(.{ .kind = .emph });
    try p.parse();
    try p.mergeText(p.root);
    if (doc.opts.gfm) try p.extendedAutolinks(p.root);
    const first = doc.inlines.items[p.root].first_child;
    var it = first;
    while (it != none) : (it = doc.inlines.items[it].next) doc.inlines.items[it].parent = none;
    doc.blocks.items[block].first_inline = first;
}

const Delim = struct {
    cc: u8,
    num: u32,
    orig: u32,
    node: u32,
    prev: u32 = none,
    next: u32 = none,
    can_open: bool,
    can_close: bool,
};

const Bracket = struct {
    node: u32,
    prev_delim: u32,
    /// Index of `[` in the subject.
    index: usize,
    image: bool,
    active: bool = true,
    bracket_after: bool = false,
};

const Parser = struct {
    doc: *Doc,
    gpa: Allocator,
    /// `s` starts at this offset of `Doc.content`.
    base: u32,
    s: []const u8,
    top: u32,
    pos: usize = 0,
    root: u32 = none,
    delims: std.ArrayList(Delim) = .empty,
    /// The top delimiter (`none`: empty).
    last_delim: u32 = none,
    brackets: std.ArrayList(Bracket) = .empty,
    /// Backtick runs seen while scanning for code span closers: the
    /// latest start of a run of each length, once the whole subject was
    /// scanned.
    ticks_scanned: bool = false,
    ticks_last: [64]usize = [_]usize{0} ** 64,
    ticks_long: std.AutoHashMapUnmanaged(usize, usize) = .empty,

    fn in(p: *Parser, i: u32) *Inline {
        return &p.doc.inlines.items[i];
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.s.len) p.s[p.pos] else null;
    }

    fn range(p: *Parser, a: usize, e: usize) [2]u32 {
        return .{ p.base + @as(u32, @intCast(a)), p.base + @as(u32, @intCast(e)) };
    }

    // -- tree -----------------------------------------------------------

    fn append(p: *Parser, parent: u32, child: u32) void {
        const par = p.in(parent);
        const ch = p.in(child);
        ch.parent = parent;
        ch.next = none;
        ch.prev = par.last_child;
        if (par.last_child == none) par.first_child = child else p.in(par.last_child).next = child;
        par.last_child = child;
    }

    fn unlink(p: *Parser, i: u32) void {
        const n = p.in(i);
        if (n.prev != none) p.in(n.prev).next = n.next else if (n.parent != none) p.in(n.parent).first_child = n.next;
        if (n.next != none) p.in(n.next).prev = n.prev else if (n.parent != none) p.in(n.parent).last_child = n.prev;
        n.parent = none;
        n.next = none;
        n.prev = none;
    }

    fn insertAfter(p: *Parser, after: u32, i: u32) void {
        const a = p.in(after);
        const n = p.in(i);
        n.parent = a.parent;
        n.prev = after;
        n.next = a.next;
        if (a.next != none) p.in(a.next).prev = i else if (a.parent != none) p.in(a.parent).last_child = i;
        p.in(after).next = i;
    }

    fn insertBefore(p: *Parser, before: u32, i: u32) void {
        const bnode = p.in(before);
        const n = p.in(i);
        n.parent = bnode.parent;
        n.next = before;
        n.prev = bnode.prev;
        if (bnode.prev != none) p.in(bnode.prev).next = i else if (bnode.parent != none) p.in(bnode.parent).first_child = i;
        p.in(before).prev = i;
    }

    fn textNode(p: *Parser, a: usize, e: usize) Error!u32 {
        const i = try p.doc.addInline(.{ .kind = .text, .text = p.range(a, e) });
        p.append(p.root, i);
        return i;
    }

    fn pooledText(p: *Parser, s: []const u8) Error!u32 {
        const r = try p.doc.pool(s);
        const i = try p.doc.addInline(.{ .kind = .text, .text = r, .pooled = true });
        p.append(p.root, i);
        return i;
    }

    fn textOf(p: *Parser, i: u32) []const u8 {
        return p.doc.inlineText(p.in(i));
    }

    // -- main loop ------------------------------------------------------

    fn parse(p: *Parser) Error!void {
        defer p.ticks_long.deinit(p.gpa);
        while (p.pos < p.s.len) try p.parseInline();
        try p.processEmphasis(none);
    }

    fn special(p: *Parser, c: u8) bool {
        return switch (c) {
            '\n', '\\', '`', '*', '_', '[', ']', '!', '<', '&' => true,
            '~' => p.doc.opts.gfm,
            '$' => p.doc.opts.math,
            else => false,
        };
    }

    fn parseInline(p: *Parser) Error!void {
        const c = p.s[p.pos];
        const handled = switch (c) {
            '\n' => try p.newline(),
            '\\' => try p.backslash(),
            '`' => try p.backticks(),
            '*', '_' => try p.handleDelim(c),
            '~' => if (p.doc.opts.gfm) try p.handleDelim(c) else false,
            '[' => try p.openBracket(),
            '!' => try p.bang(),
            ']' => try p.closeBracket(),
            '<' => try p.autolink() or try p.rawHtml(),
            '&' => try p.entity(),
            '$' => if (p.doc.opts.math) try p.math() else false,
            else => try p.string(),
        };
        if (!handled) {
            _ = try p.textNode(p.pos, p.pos + 1);
            p.pos += 1;
        }
    }

    fn string(p: *Parser) Error!bool {
        const start = p.pos;
        while (p.pos < p.s.len and !p.special(p.s[p.pos])) p.pos += 1;
        if (p.pos == start) return false;
        _ = try p.textNode(start, p.pos);
        return true;
    }

    fn newline(p: *Parser) Error!bool {
        p.pos += 1;
        const last = p.in(p.root).last_child;
        var hard = false;
        if (last != none and p.in(last).kind == .text) {
            const t = p.textOf(last);
            if (t.len > 0 and t[t.len - 1] == ' ') {
                var n: usize = 0;
                while (n < t.len and t[t.len - 1 - n] == ' ') n += 1;
                hard = n >= 2;
                p.in(last).text[1] -= @intCast(n);
            }
        }
        const i = try p.doc.addInline(.{ .kind = if (hard) .hardbreak else .softbreak });
        p.append(p.root, i);
        while (p.pos < p.s.len and (p.s[p.pos] == ' ' or p.s[p.pos] == '\t')) p.pos += 1;
        return true;
    }

    fn backslash(p: *Parser) Error!bool {
        p.pos += 1;
        if (p.peek() == '\n') {
            p.pos += 1;
            const i = try p.doc.addInline(.{ .kind = .hardbreak });
            p.append(p.root, i);
            while (p.pos < p.s.len and (p.s[p.pos] == ' ' or p.s[p.pos] == '\t')) p.pos += 1;
        } else if (p.peek() != null and links.isAsciiPunct(p.s[p.pos])) {
            _ = try p.textNode(p.pos, p.pos + 1);
            p.pos += 1;
        } else {
            _ = try p.textNode(p.pos - 1, p.pos);
        }
        return true;
    }

    fn runAt(p: *Parser, i: usize) usize {
        var e = i;
        while (e < p.s.len and p.s[e] == '`') e += 1;
        return e - i;
    }

    fn backticks(p: *Parser) Error!bool {
        const start = p.pos;
        const n = p.runAt(start);
        const after = start + n;
        // A closer of this length is known not to exist.
        if (p.ticks_scanned) {
            const last = if (n < p.ticks_last.len) p.ticks_last[n] else p.ticks_long.get(n) orelse 0;
            if (last <= start) {
                p.pos = after;
                _ = try p.textNode(start, after);
                return true;
            }
        }
        var i = after;
        while (i < p.s.len) {
            if (p.s[i] != '`') {
                i += 1;
                continue;
            }
            const m = p.runAt(i);
            if (m < p.ticks_last.len) p.ticks_last[m] = i else try p.ticks_long.put(p.gpa, m, i);
            if (m == n) {
                try p.codeSpan(after, i);
                p.pos = i + m;
                return true;
            }
            i += m;
        }
        p.ticks_scanned = true;
        p.pos = after;
        _ = try p.textNode(start, after);
        return true;
    }

    fn codeSpan(p: *Parser, a: usize, e: usize) Error!void {
        var t = p.s[a..e];
        const has_nl = std.mem.indexOfScalar(u8, t, '\n') != null;
        var r: [2]u32 = p.range(a, e);
        var pooled = false;
        if (has_nl) {
            const start: u32 = @intCast(p.doc.text_pool.items.len);
            for (t) |c| try p.doc.text_pool.append(p.gpa, if (c == '\n') ' ' else c);
            r = .{ start, @intCast(p.doc.text_pool.items.len) };
            pooled = true;
            t = p.doc.text_pool.items[r[0]..r[1]];
        }
        if (t.len >= 2 and t[0] == ' ' and t[t.len - 1] == ' ' and std.mem.indexOfNone(u8, t, " ") != null) {
            r[0] += 1;
            r[1] -= 1;
        }
        const i = try p.doc.addInline(.{ .kind = .code, .text = r, .pooled = pooled });
        p.append(p.root, i);
    }

    fn entity(p: *Parser) Error!bool {
        var buf: [4]u8 = undefined;
        const m = entities.match(p.s[p.pos..], &buf) orelse return false;
        _ = try p.pooledText(m.utf8);
        p.pos += m.len;
        return true;
    }

    // -- autolinks and raw HTML -----------------------------------------

    fn autolink(p: *Parser) Error!bool {
        const s = p.s;
        const start = p.pos;
        var i = start + 1;
        // URI: scheme ':' non-space, non-<> characters.
        const scheme_start = i;
        if (i < s.len and std.ascii.isAlphabetic(s[i])) {
            i += 1;
            while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '+' or s[i] == '.' or s[i] == '-')) i += 1;
            const slen = i - scheme_start;
            if (slen >= 2 and slen <= 32 and i < s.len and s[i] == ':') {
                i += 1;
                while (i < s.len and s[i] > 0x20 and s[i] != '<' and s[i] != '>' and s[i] != 0x7f) i += 1;
                if (i < s.len and s[i] == '>') {
                    try p.autolinkNode(start + 1, i, null);
                    p.pos = i + 1;
                    return true;
                }
            }
        }
        // Email.
        i = start + 1;
        const local_start = i;
        while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or std.mem.indexOfScalar(u8, ".!#$%&'*+/=?^_`{|}~-", s[i]) != null)) i += 1;
        if (i == local_start or i >= s.len or s[i] != '@') return false;
        i += 1;
        var labels: u32 = 0;
        while (true) {
            const ls = i;
            while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-')) i += 1;
            const lab = s[ls..i];
            if (lab.len == 0 or lab.len > 63 or lab[0] == '-' or lab[lab.len - 1] == '-') return false;
            labels += 1;
            if (i < s.len and s[i] == '.') {
                i += 1;
                continue;
            }
            break;
        }
        if (i >= s.len or s[i] != '>') return false;
        try p.autolinkNode(start + 1, i, "mailto:");
        p.pos = i + 1;
        return true;
    }

    fn autolinkNode(p: *Parser, a: usize, e: usize, prefix: ?[]const u8) Error!void {
        const d = p.doc;
        const ds: u32 = @intCast(d.text_pool.items.len);
        if (prefix) |pre| try d.text_pool.appendSlice(p.gpa, pre);
        try d.text_pool.appendSlice(p.gpa, p.s[a..e]);
        const dest = d.text_pool.items[ds..];
        const i = try d.addInline(.{ .kind = .autolink, .text = p.range(a, e), .dest = .{ ds, @intCast(d.text_pool.items.len) }, .dest_pooled = true, .title = .{ ds, ds }, .unsafe = links.isUnsafeDestination(dest) });
        p.append(p.root, i);
    }

    fn rawHtml(p: *Parser) Error!bool {
        const e = html.scanInline(p.s, p.pos) orelse return false;
        const i = try p.doc.addInline(.{ .kind = .html_literal, .text = p.range(p.pos, e) });
        p.append(p.root, i);
        p.pos = e;
        return true;
    }

    // -- math -----------------------------------------------------------

    fn math(p: *Parser) Error!bool {
        const s = p.s;
        const start = p.pos;
        if (start + 1 >= s.len or s[start + 1] == ' ' or s[start + 1] == '$' or s[start + 1] == '\n') return false;
        var i = start + 1;
        while (i < s.len) : (i += 1) {
            if (s[i] == '\\' and i + 1 < s.len) {
                i += 1;
                continue;
            }
            if (s[i] == '$') {
                if (s[i - 1] == ' ' or s[i - 1] == '\n') continue;
                if (i + 1 < s.len and std.ascii.isDigit(s[i + 1])) continue;
                const n = try p.doc.addInline(.{ .kind = .math, .text = p.range(start + 1, i) });
                p.append(p.root, n);
                p.pos = i + 1;
                return true;
            }
        }
        return false;
    }

    // -- emphasis -------------------------------------------------------

    fn isUnicodeWs(cp: u21) bool {
        if (cp == '\t' or cp == '\n' or cp == 0x0C or cp == '\r' or cp == ' ') return true;
        if (cp < 128) return false;
        return zg_text.unicode.props(cp).gc == .Zs;
    }

    fn isUnicodePunct(cp: u21) bool {
        if (cp < 128) return links.isAsciiPunct(@intCast(cp));
        return switch (zg_text.unicode.props(cp).gc) {
            .Pc, .Pd, .Pe, .Pf, .Pi, .Po, .Ps, .Sc, .Sk, .Sm, .So => true,
            else => false,
        };
    }

    fn cpBefore(p: *Parser, i: usize) u21 {
        if (i == 0) return '\n';
        var k = i - 1;
        while (k > 0 and p.s[k] & 0xC0 == 0x80 and i - k < 4) k -= 1;
        return std.unicode.utf8Decode(p.s[k..i]) catch 0xFFFD;
    }

    fn cpAt(p: *Parser, i: usize) u21 {
        if (i >= p.s.len) return '\n';
        const n = std.unicode.utf8ByteSequenceLength(p.s[i]) catch return 0xFFFD;
        if (i + n > p.s.len) return 0xFFFD;
        return std.unicode.utf8Decode(p.s[i .. i + n]) catch 0xFFFD;
    }

    fn handleDelim(p: *Parser, cc: u8) Error!bool {
        const start = p.pos;
        var n: usize = 0;
        while (start + n < p.s.len and p.s[start + n] == cc) n += 1;
        const before = p.cpBefore(start);
        const after = p.cpAt(start + n);
        const after_ws = isUnicodeWs(after);
        const after_p = isUnicodePunct(after);
        const before_ws = isUnicodeWs(before);
        const before_p = isUnicodePunct(before);
        const left = !after_ws and (!after_p or before_ws or before_p);
        const right = !before_ws and (!before_p or after_ws or after_p);
        var can_open = left;
        var can_close = right;
        if (cc == '_') {
            can_open = left and (!right or before_p);
            can_close = right and (!left or after_p);
        }
        p.pos = start + n;
        const node = try p.textNode(start, start + n);
        // Strikethrough uses runs of one or two tildes.
        if (cc == '~' and n > 2) return true;
        if (can_open or can_close) {
            const di: u32 = @intCast(p.delims.items.len);
            try p.delims.append(p.gpa, .{ .cc = cc, .num = @intCast(n), .orig = @intCast(n), .node = node, .prev = p.last_delim, .can_open = can_open, .can_close = can_close });
            if (p.last_delim != none) p.delims.items[p.last_delim].next = di;
            p.last_delim = di;
        }
        return true;
    }

    fn removeDelim(p: *Parser, di: u32) void {
        const d = p.delims.items[di];
        if (d.prev != none) p.delims.items[d.prev].next = d.next;
        if (d.next == none) p.last_delim = d.prev else p.delims.items[d.next].prev = d.prev;
    }

    fn bottomIndex(cc: u8, can_open: bool, orig: u32) usize {
        const base: usize = switch (cc) {
            '_' => 0,
            '*' => 6,
            else => 12,
        };
        return base + @as(usize, if (can_open) 3 else 0) + orig % 3;
    }

    fn processEmphasis(p: *Parser, bottom: u32) Error!void {
        var openers_bottom = [_]u32{bottom} ** 18;
        // The first delimiter above `bottom`.
        var closer = p.last_delim;
        while (closer != none and p.delims.items[closer].prev != bottom) closer = p.delims.items[closer].prev;
        while (closer != none) {
            const c = p.delims.items[closer];
            if (!c.can_close) {
                closer = c.next;
                continue;
            }
            const bi = bottomIndex(c.cc, c.can_open, c.orig);
            var opener = c.prev;
            var found = false;
            while (opener != none and opener != bottom and opener != openers_bottom[bi]) {
                const o = p.delims.items[opener];
                if (o.cc == c.cc and o.can_open) {
                    if (c.cc == '~') {
                        if (o.num == c.num) {
                            found = true;
                            break;
                        }
                    } else {
                        const odd = (c.can_open or o.can_close) and c.orig % 3 != 0 and (o.orig + c.orig) % 3 == 0;
                        if (!odd) {
                            found = true;
                            break;
                        }
                    }
                }
                opener = o.prev;
            }
            const old_closer = closer;
            if (found) {
                const o = &p.delims.items[opener];
                const cl = &p.delims.items[closer];
                const use: u32 = if (c.cc == '~') c.num else if (cl.num >= 2 and o.num >= 2) 2 else 1;
                o.num -= use;
                cl.num -= use;
                p.in(o.node).text[1] -= use;
                p.in(cl.node).text[1] -= use;
                const kind: ast.InlineKind = if (c.cc == '~') .strike else if (use == 1) .emph else .strong;
                const em = try p.doc.addInline(.{ .kind = kind });
                const o_node = p.delims.items[opener].node;
                const c_node = p.delims.items[closer].node;
                var tmp = p.in(o_node).next;
                while (tmp != none and tmp != c_node) {
                    const nx = p.in(tmp).next;
                    p.unlink(tmp);
                    p.append(em, tmp);
                    tmp = nx;
                }
                p.insertAfter(o_node, em);
                // Delimiters between opener and closer go.
                p.delims.items[opener].next = closer;
                p.delims.items[closer].prev = opener;
                if (p.delims.items[opener].num == 0) {
                    p.unlink(o_node);
                    p.removeDelim(opener);
                }
                if (p.delims.items[closer].num == 0) {
                    p.unlink(c_node);
                    const nx = p.delims.items[closer].next;
                    p.removeDelim(closer);
                    closer = nx;
                }
            } else {
                closer = c.next;
                openers_bottom[bi] = c.prev;
                if (!c.can_open) p.removeDelim(old_closer);
            }
        }
        while (p.last_delim != none and p.last_delim != bottom) p.removeDelim(p.last_delim);
    }

    // -- links ----------------------------------------------------------

    fn addBracket(p: *Parser, node: u32, index: usize, image: bool) Error!void {
        if (p.brackets.items.len > 0) p.brackets.items[p.brackets.items.len - 1].bracket_after = true;
        try p.brackets.append(p.gpa, .{ .node = node, .prev_delim = p.last_delim, .index = index, .image = image });
    }

    fn openBracket(p: *Parser) Error!bool {
        if (p.doc.opts.wikilinks and try p.wikilink(false)) return true;
        const start = p.pos;
        p.pos += 1;
        const node = try p.textNode(start, start + 1);
        try p.addBracket(node, start, false);
        return true;
    }

    fn bang(p: *Parser) Error!bool {
        const start = p.pos;
        if (start + 1 < p.s.len and p.s[start + 1] == '[') {
            if (p.doc.opts.wikilinks and try p.wikilink(true)) return true;
            p.pos += 2;
            const node = try p.textNode(start, start + 2);
            try p.addBracket(node, start + 1, true);
            return true;
        }
        p.pos += 1;
        _ = try p.textNode(start, start + 1);
        return true;
    }

    /// `[[target|alias]]` (or `![[target]]` with `embed`) at `pos`.
    fn wikilink(p: *Parser, embed: bool) Error!bool {
        const s = p.s;
        const open = p.pos + @intFromBool(embed);
        if (open + 1 >= s.len or s[open + 1] != '[') return false;
        const inner_start = open + 2;
        var i = inner_start;
        while (i + 1 < s.len) : (i += 1) {
            const c = s[i];
            if (c == '\n' or c == '[') return false;
            if (c == ']') {
                if (s[i + 1] != ']') return false;
                break;
            }
        } else return false;
        if (i == inner_start) return false;
        const inner = s[inner_start..i];
        const bar = std.mem.indexOfScalar(u8, inner, '|');
        const target_end = inner_start + (bar orelse inner.len);
        const n = try p.doc.addInline(.{ .kind = if (embed) .embed else .wikilink, .text = p.range(inner_start, target_end) });
        p.append(p.root, n);
        if (bar) |b| {
            const t = try p.doc.addInline(.{ .kind = .text, .text = p.range(inner_start + b + 1, i) });
            p.append(n, t);
        }
        p.pos = i + 2;
        return true;
    }

    /// A link label at `i` for the inline parser: its length including
    /// the brackets (2 for `[]`), or 0.
    fn labelLen(s: []const u8, i: usize) usize {
        if (i >= s.len or s[i] != '[') return 0;
        var k = i + 1;
        while (k < s.len) {
            const c = s[k];
            if (c == '\\' and k + 1 < s.len) {
                k += 2;
                continue;
            }
            if (c == '[') return 0;
            if (c == ']') return if (k - i - 1 > 999) 0 else k - i + 1;
            k += 1;
        }
        return 0;
    }

    fn closeBracket(p: *Parser) Error!bool {
        p.pos += 1;
        const startpos = p.pos;
        if (p.brackets.items.len == 0) {
            _ = try p.textNode(startpos - 1, startpos);
            return true;
        }
        const opener = p.brackets.items[p.brackets.items.len - 1];
        if (!opener.active) {
            _ = try p.textNode(startpos - 1, startpos);
            _ = p.brackets.pop();
            return true;
        }
        var matched = false;
        var dest: [2]u32 = .{ 0, 0 };
        var title: [2]u32 = .{ 0, 0 };
        var dest_pooled = true;
        const s = p.s;
        // Inline link: `(dest "title")`.
        if (p.peek() == '(') {
            var i = links.skipSpacesNl(s, p.pos + 1);
            var ok = true;
            var dr: [2]usize = .{ i, i };
            if (i < s.len and s[i] == ')') {
                // Empty destination.
            } else if (links.scanDestination(s, i)) |d| {
                dr = .{ d.start, d.end };
                i = d.next;
            } else ok = false;
            var tr: ?[2]usize = null;
            if (ok) {
                const j = links.skipSpacesNl(s, i);
                if (j != i and j < s.len) if (links.scanTitle(s, j)) |t| {
                    tr = .{ t.start, t.end };
                    i = t.next;
                };
                i = links.skipSpacesNl(s, i);
                if (i < s.len and s[i] == ')') {
                    matched = true;
                    p.pos = i + 1;
                    dest = try p.unescaped(s[dr[0]..dr[1]]);
                    title = if (tr) |t| try p.unescaped(s[t[0]..t[1]]) else .{ dest[1], dest[1] };
                }
            }
        }
        if (!matched) {
            // Reference link: full, collapsed or shortcut.
            const before = p.pos;
            const n = labelLen(s, p.pos);
            var label: ?[]const u8 = null;
            if (n > 2) {
                label = s[before + 1 .. before + n - 1];
            } else if (!opener.bracket_after) {
                label = s[opener.index + 1 .. startpos - 1];
            }
            if (n == 0) p.pos = before else p.pos = before + n;
            if (label) |l| {
                var norm: std.ArrayList(u8) = .empty;
                defer norm.deinit(p.gpa);
                try links.normalizeLabel(&norm, p.gpa, l);
                if (norm.items.len > 0) {
                    if (p.doc.lookupRef(norm.items)) |r| {
                        matched = true;
                        dest = try p.doc.pool(p.doc.refText(r.dest));
                        title = try p.doc.pool(p.doc.refText(r.title));
                    } else try p.doc.noteUnresolved(norm.items, p.top);
                }
            }
            if (!matched) p.pos = before;
        }
        if (!matched) {
            _ = p.brackets.pop();
            p.pos = startpos;
            _ = try p.textNode(startpos - 1, startpos);
            return true;
        }
        const node = try p.doc.addInline(.{
            .kind = if (opener.image) .image else .link,
            .dest = dest,
            .title = title,
            .dest_pooled = dest_pooled,
        });
        dest_pooled = true;
        p.in(node).unsafe = links.isUnsafeDestination(p.doc.pooled(dest));
        var tmp = p.in(opener.node).next;
        while (tmp != none) {
            const nx = p.in(tmp).next;
            p.unlink(tmp);
            p.append(node, tmp);
            tmp = nx;
        }
        p.append(p.root, node);
        try p.processEmphasis(opener.prev_delim);
        _ = p.brackets.pop();
        p.unlink(opener.node);
        // No links in links.
        if (!opener.image) for (p.brackets.items) |*b| {
            if (!b.image) b.active = false;
        };
        return true;
    }

    fn unescaped(p: *Parser, raw: []const u8) Error![2]u32 {
        const start: u32 = @intCast(p.doc.text_pool.items.len);
        try links.unescape(&p.doc.text_pool, p.gpa, raw);
        return .{ start, @intCast(p.doc.text_pool.items.len) };
    }

    // -- post-processing ------------------------------------------------

    /// Joins adjacent text nodes whose ranges touch in `Doc.content`.
    fn mergeText(p: *Parser, parent: u32) Error!void {
        var c = p.in(parent).first_child;
        while (c != none) {
            const n = p.in(c);
            if (n.kind == .text and !n.pooled) {
                while (n.next != none) {
                    const nx = p.in(n.next);
                    if (nx.kind != .text or nx.pooled or nx.text[0] != n.text[1]) break;
                    n.text[1] = nx.text[1];
                    p.unlink(n.next);
                }
            } else if (n.first_child != none) try p.mergeText(c);
            c = p.in(c).next;
        }
    }

    /// GFM extended autolinks (`www.`, `http(s)://`, emails) in text that
    /// is not already inside a link.
    fn extendedAutolinks(p: *Parser, parent: u32) Error!void {
        var c = p.in(parent).first_child;
        while (c != none) {
            const n = p.in(c);
            switch (n.kind) {
                .link, .image, .autolink, .wikilink, .embed => {},
                .text => if (!n.pooled) {
                    c = try p.linkifyText(c);
                },
                else => if (n.first_child != none) try p.extendedAutolinks(c),
            }
            c = p.in(c).next;
        }
    }

    /// Splits text node `i` around the first extended autolink in it and
    /// returns the last node of the split (the caller continues after it;
    /// later links in the tail are found by recursion).
    fn linkifyText(p: *Parser, i: u32) Error!u32 {
        const r = p.in(i).text;
        const t = p.doc.content.items[r[0]..r[1]];
        var k: usize = 0;
        while (k < t.len) : (k += 1) {
            const m = autolinkAt(t, k) orelse continue;
            // text[0..m.start] | link | rest
            const link_r: [2]u32 = .{ r[0] + @as(u32, @intCast(m.start)), r[0] + @as(u32, @intCast(m.end)) };
            const ds: u32 = @intCast(p.doc.text_pool.items.len);
            try p.doc.text_pool.appendSlice(p.gpa, m.prefix);
            try p.doc.text_pool.appendSlice(p.gpa, t[m.start..m.end]);
            const link = try p.doc.addInline(.{ .kind = .autolink, .text = link_r, .dest = .{ ds, @intCast(p.doc.text_pool.items.len) }, .dest_pooled = true, .title = .{ ds, ds } });
            var after: u32 = link;
            if (m.start == 0) {
                p.insertBefore(i, link);
                p.unlink(i);
            } else {
                p.in(i).text[1] = link_r[0];
                p.insertAfter(i, link);
            }
            if (m.end < t.len) {
                const tail = try p.doc.addInline(.{ .kind = .text, .text = .{ link_r[1], r[1] } });
                p.insertAfter(link, tail);
                after = try p.linkifyText(tail);
            }
            return after;
        }
        return i;
    }
};

const AutoMatch = struct { start: usize, end: usize, prefix: []const u8 };

fn validDomainEnd(t: []const u8, start: usize) ?usize {
    // Segments of alphanumerics, `_` and `-` separated by periods; the
    // last two may not contain `_`; at least one period.
    var i = start;
    var periods: u32 = 0;
    var seg_underscore = [2]bool{ false, false };
    var seg_len: usize = 0;
    while (i < t.len) {
        const c = t[i];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c >= 0x80) {
            seg_len += 1;
        } else if (c == '_') {
            seg_len += 1;
            seg_underscore[1] = true;
        } else if (c == '.') {
            if (i + 1 >= t.len or !(std.ascii.isAlphanumeric(t[i + 1]) or t[i + 1] == '-' or t[i + 1] == '_' or t[i + 1] >= 0x80)) break;
            periods += 1;
            seg_underscore[0] = seg_underscore[1];
            seg_underscore[1] = false;
            seg_len = 0;
        } else break;
        i += 1;
    }
    if (i == start or periods == 0 or seg_underscore[0] or seg_underscore[1]) return null;
    return i;
}

/// Trims trailing punctuation, unbalanced `)` and an entity-like `&x;`.
fn trimLinkEnd(t: []const u8, start: usize, end_in: usize) usize {
    var end = end_in;
    while (end > start) {
        const c = t[end - 1];
        if (std.mem.indexOfScalar(u8, "?!.,:*_~'\"", c) != null) {
            end -= 1;
        } else if (c == ')') {
            var open: usize = 0;
            var close: usize = 0;
            for (t[start..end]) |ch| {
                if (ch == '(') open += 1 else if (ch == ')') close += 1;
            }
            if (close > open) end -= 1 else break;
        } else if (c == ';') {
            var k = end - 1;
            while (k > start and std.ascii.isAlphanumeric(t[k - 1])) k -= 1;
            if (k > start and t[k - 1] == '&' and k < end - 1) end = k - 1 else break;
        } else break;
    }
    return end;
}

fn autolinkAt(t: []const u8, k: usize) ?AutoMatch {
    const boundary = k == 0 or std.mem.indexOfScalar(u8, " \t\n*_~(", t[k - 1]) != null;
    if (boundary and t.len - k >= 4 and std.mem.startsWith(u8, t[k..], "www.")) {
        const de = validDomainEnd(t, k) orelse return null;
        var e = de;
        while (e < t.len and !links.isWs(t[e]) and t[e] != '<') e += 1;
        e = trimLinkEnd(t, k, e);
        if (e <= k + 4) return null;
        return .{ .start = k, .end = e, .prefix = "http://" };
    }
    if (boundary) {
        const schemes = [_][]const u8{ "http://", "https://", "ftp://" };
        for (schemes) |sc| if (t.len - k > sc.len and std.ascii.startsWithIgnoreCase(t[k..], sc)) {
            const de = validDomainEnd(t, k + sc.len) orelse return null;
            var e = de;
            while (e < t.len and !links.isWs(t[e]) and t[e] != '<') e += 1;
            e = trimLinkEnd(t, k, e);
            return .{ .start = k, .end = e, .prefix = "" };
        };
    }
    if (t[k] == '@') {
        // Email: scan back over the local part, forward over the domain.
        var s = k;
        while (s > 0 and (std.ascii.isAlphanumeric(t[s - 1]) or std.mem.indexOfScalar(u8, "._+-", t[s - 1]) != null)) s -= 1;
        if (s == k) return null;
        if (s > 0 and (t[s - 1] == '/' or std.ascii.isAlphanumeric(t[s - 1]))) return null;
        var e = k + 1;
        var periods: u32 = 0;
        while (e < t.len and (std.ascii.isAlphanumeric(t[e]) or t[e] == '.' or t[e] == '-' or t[e] == '_')) : (e += 1) {
            if (t[e] == '.' and e + 1 < t.len and std.ascii.isAlphanumeric(t[e + 1])) periods += 1;
        }
        while (e > k + 1 and t[e - 1] == '.') e -= 1;
        if (periods == 0 or e == k + 1) return null;
        const last = t[e - 1];
        if (last == '-' or last == '_') return null;
        return .{ .start = s, .end = e, .prefix = "mailto:" };
    }
    return null;
}

test {
    std.testing.refAllDecls(@This());
}
