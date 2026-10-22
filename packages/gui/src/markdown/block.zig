//! Markdown phase 1, block structure (E04.F06.S01.T01), following the
//! CommonMark 0.31.2 appendix "A parsing strategy" line by line: match
//! the open containers, look for new block starts, add lazy paragraph
//! continuations, close what did not match.
//!
//! Extensions: GFM tables and task list items (`Options.gfm`), callouts
//! (`> [!note] Title`), front matter (`---` ... `---` at the start) and
//! `$$` math blocks.
//!
//! `run` parses `Doc.src` from a line start with the document open and
//! the top-level blocks before it closed; stream.zig uses it for both
//! batch and incremental parsing.

const std = @import("std");
const ast = @import("ast.zig");
const doc_mod = @import("doc.zig");
const links = @import("links.zig");
const html = @import("html.zig");

const Allocator = std.mem.Allocator;
const Doc = doc_mod.Doc;
const Block = ast.Block;
const Kind = ast.BlockKind;
const none = ast.none;

const Error = Allocator.Error;

/// What `run` found out about stability.
pub const RunResult = struct {
    /// Top-level blocks before the one the last (partial) line could
    /// still change.
    stable: u32,
};

/// Parses `doc.src[from..]`. With `final`, every block is closed at the
/// end; otherwise the last top-level block stays open.
pub fn run(doc: *Doc, from: u32, final: bool) Error!RunResult {
    var p: Parser = .{ .doc = doc, .gpa = doc.gpa };
    defer p.cur.deinit(doc.gpa);
    defer p.table_aligns.deinit(doc.gpa);
    p.tip = 0;
    doc.blocks.items[0].closed = false;
    const src = doc.src.items;
    var pos: usize = from;
    if (from == 0 and doc.opts.front_matter) {
        if (frontMatterEnd(src)) |fm| {
            try p.frontMatter(fm);
            pos = fm.next;
        } else if (!final and std.mem.startsWith(u8, src, "---")) {
            // A closing fence may still come.
            p.hold_all = true;
        }
    }
    var stable: u32 = 0;
    while (pos < src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, pos, '\n');
        const end = nl orelse src.len;
        if (nl == null and !final) stable = p.closedTopCount();
        var line = src[pos..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try p.incorporate(line, @intCast(pos));
        pos = if (nl) |n| n + 1 else src.len;
    }
    if (src.len == 0 or src[src.len - 1] == '\n' or final) stable = p.closedTopCount();
    if (final) {
        while (p.tip != none) try p.finalize(p.tip, p.line_no);
        doc.blocks.items[0].closed = true;
        stable = p.topCount();
    }
    if (p.hold_all) stable = 0;
    return .{ .stable = stable };
}

const FrontMatter = struct { content: [2]usize, next: usize };

/// `---` on the first line and a closing `---` or `...` line.
fn frontMatterEnd(src: []const u8) ?FrontMatter {
    const first_end = std.mem.indexOfScalar(u8, src, '\n') orelse return null;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, src[0..first_end], " \t\r"), "---")) return null;
    var pos = first_end + 1;
    while (pos < src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, pos, '\n');
        const end = nl orelse src.len;
        const l = std.mem.trimEnd(u8, src[pos..end], " \t\r");
        if (std.mem.eql(u8, l, "---") or std.mem.eql(u8, l, "...")) {
            if (nl == null) return null;
            return .{ .content = .{ first_end + 1, pos }, .next = end + 1 };
        }
        pos = end + 1;
    }
    return null;
}

const Parser = struct {
    doc: *Doc,
    gpa: Allocator,
    line: []const u8 = "",
    line_src: u32 = 0,
    line_no: u32 = 0,
    offset: usize = 0,
    column: usize = 0,
    next_nonspace: usize = 0,
    next_nonspace_column: usize = 0,
    indent: usize = 0,
    indented: bool = false,
    blank: bool = false,
    partially_consumed_tab: bool = false,
    all_closed: bool = true,
    last_matched: u32 = 0,
    old_tip: u32 = 0,
    tip: u32 = 0,
    /// The open leaf's text so far.
    cur: std.ArrayList(u8) = .empty,
    cur_block: u32 = none,
    /// Set by a start that already took the whole line.
    skip_line: bool = false,
    hold_all: bool = false,
    /// Column alignments of the open table.
    table_aligns: std.ArrayList(ast.Align) = .empty,

    fn b(p: *Parser, i: u32) *Block {
        return &p.doc.blocks.items[i];
    }

    fn topCount(p: *Parser) u32 {
        var n: u32 = 0;
        var c = p.b(0).first_child;
        while (c != none) : (c = p.b(c).next) n += 1;
        return n;
    }

    /// Top-level blocks before the last one (which may still be open).
    fn closedTopCount(p: *Parser) u32 {
        const n = p.topCount();
        return if (n == 0) 0 else n - 1;
    }

    fn peek(p: *Parser, i: usize) ?u8 {
        return if (i < p.line.len) p.line[i] else null;
    }

    fn findNextNonspace(p: *Parser) void {
        var i = p.offset;
        var cols = p.column;
        while (i < p.line.len) {
            const c = p.line[i];
            if (c == ' ') {
                i += 1;
                cols += 1;
            } else if (c == '\t') {
                i += 1;
                cols += 4 - (cols % 4);
            } else break;
        }
        p.blank = i >= p.line.len;
        p.next_nonspace = i;
        p.next_nonspace_column = cols;
        p.indent = cols - p.column;
        p.indented = p.indent >= 4;
    }

    fn advanceNextNonspace(p: *Parser) void {
        p.offset = p.next_nonspace;
        p.column = p.next_nonspace_column;
        p.partially_consumed_tab = false;
    }

    fn advanceOffset(p: *Parser, count_in: usize, columns: bool) void {
        var count = count_in;
        while (count > 0 and p.offset < p.line.len) {
            const c = p.line[p.offset];
            if (c == '\t') {
                const to_tab = 4 - (p.column % 4);
                if (columns) {
                    p.partially_consumed_tab = to_tab > count;
                    const adv = @min(count, to_tab);
                    p.column += adv;
                    if (!p.partially_consumed_tab) p.offset += 1;
                    count -= adv;
                } else {
                    p.partially_consumed_tab = false;
                    p.column += to_tab;
                    p.offset += 1;
                    count -= 1;
                }
            } else {
                p.partially_consumed_tab = false;
                p.offset += 1;
                p.column += 1;
                count -= 1;
            }
        }
    }

    fn rest(p: *Parser) []const u8 {
        return p.line[p.next_nonspace..];
    }

    // -- the tree -------------------------------------------------------

    fn canContain(parent: Kind, child: Kind) bool {
        return switch (parent) {
            .document, .block_quote, .list_item, .callout, .footnote_def => child != .list_item,
            .list => child == .list_item,
            else => false,
        };
    }

    fn acceptsLines(k: Kind) bool {
        return switch (k) {
            .paragraph, .code_fenced, .code_indented, .html_literal, .math_block, .front_matter => true,
            else => false,
        };
    }

    fn depth(p: *Parser, i: u32) u32 {
        var d: u32 = 0;
        var c = i;
        while (c != none) : (c = p.b(c).parent) d += 1;
        return d;
    }

    fn addChild(p: *Parser, kind: Kind, offset: usize) Error!u32 {
        while (!canContain(p.b(p.tip).kind, kind)) try p.finalize(p.tip, p.line_no -| 1);
        return p.addBlock(kind, p.tip, offset);
    }

    fn addBlock(p: *Parser, kind: Kind, parent: u32, offset: usize) Error!u32 {
        const d = p.doc;
        const i: u32 = @intCast(d.blocks.items.len);
        try d.blocks.append(d.gpa, .{
            .kind = kind,
            .parent = parent,
            .src = .{ p.line_src + @as(u32, @intCast(offset)), p.line_src + @as(u32, @intCast(p.line.len)) },
            .line = .{ p.line_no, p.line_no },
            .line_src = .{ p.line_src, p.line_src },
            .content_mark = @intCast(d.content.items.len),
        });
        const par = p.b(parent);
        if (par.last_child == none) par.first_child = i else p.b(par.last_child).next = i;
        par.last_child = i;
        if (acceptsLines(kind) or kind == .heading) {
            p.cur.clearRetainingCapacity();
            p.cur_block = i;
        }
        p.tip = i;
        return i;
    }

    fn unlink(p: *Parser, i: u32) void {
        const parent = p.b(i).parent;
        const par = p.b(parent);
        var prev: u32 = none;
        var c = par.first_child;
        while (c != none and c != i) : (c = p.b(c).next) prev = c;
        if (c == none) return;
        if (prev == none) par.first_child = p.b(i).next else p.b(prev).next = p.b(i).next;
        if (par.last_child == i) par.last_child = prev;
        p.b(i).next = none;
    }

    fn addLine(p: *Parser) Error!void {
        if (p.partially_consumed_tab) {
            p.offset += 1;
            const chars = 4 - (p.column % 4);
            try p.cur.appendNTimes(p.gpa, ' ', chars);
        }
        try p.cur.appendSlice(p.gpa, p.line[@min(p.offset, p.line.len)..]);
        try p.cur.append(p.gpa, '\n');
        const t = p.b(p.tip);
        t.line_src[1] = p.line_src;
    }

    fn closeUnmatchedBlocks(p: *Parser) Error!void {
        if (p.all_closed) return;
        while (p.old_tip != p.last_matched) {
            const parent = p.b(p.old_tip).parent;
            try p.finalize(p.old_tip, p.line_no -| 1);
            p.old_tip = parent;
        }
        p.all_closed = true;
    }

    /// Moves the open leaf's text into `Doc.content`.
    fn flushContent(p: *Parser, i: u32, text: []const u8) Error!void {
        const d = p.doc;
        const start: u32 = @intCast(d.content.items.len);
        try d.content.appendSlice(d.gpa, text);
        p.b(i).content = .{ start, @intCast(d.content.items.len) };
    }

    fn finalize(p: *Parser, i: u32, line_no: u32) Error!void {
        const blk = p.b(i);
        const above = blk.parent;
        blk.closed = true;
        blk.line[1] = @max(line_no, blk.line[0]);
        if (i == p.cur_block) {
            p.cur_block = none;
            try p.finalizeLeaf(i);
        }
        switch (p.b(i).kind) {
            .list => p.finalizeList(i),
            .list_item => {
                const it = p.b(i);
                it.line[1] = if (it.last_child != none) p.b(it.last_child).line[1] else it.line[0];
                if (p.doc.opts.gfm) p.taskItem(i);
            },
            .block_quote => if (p.doc.opts.callouts) p.callout(i),
            .table => {
                const t = p.b(i);
                if (t.last_child != none) t.line[1] = p.b(t.last_child).line[1];
            },
            else => {},
        }
        p.tip = above;
    }

    fn finalizeLeaf(p: *Parser, i: u32) Error!void {
        const text = p.cur.items;
        switch (p.b(i).kind) {
            .paragraph => {
                const remaining = try p.extractRefs(i, text);
                if (std.mem.trim(u8, remaining, " \t\n").len == 0) {
                    p.unlink(i);
                    return;
                }
                try p.flushContent(i, trimParagraph(remaining));
            },
            .heading => try p.flushContent(i, std.mem.trim(u8, text, " \t\n")),
            .code_indented => {
                // Trailing blank lines are not part of the block.
                var end = text.len;
                var lines_dropped: u32 = 0;
                while (end > 0) {
                    const ls = if (std.mem.lastIndexOfScalar(u8, text[0 .. end - 1], '\n')) |n| n + 1 else 0;
                    if (std.mem.trim(u8, text[ls .. end - 1], " \t").len != 0) break;
                    end = ls;
                    lines_dropped += 1;
                }
                const blk = p.b(i);
                blk.line[1] -|= lines_dropped;
                try p.flushContent(i, text[0..end]);
            },
            .html_literal => try p.flushContent(i, std.mem.trimEnd(u8, text, "\n")),
            else => try p.flushContent(i, text),
        }
    }

    fn trimParagraph(t: []const u8) []const u8 {
        // Leading whitespace was skipped per line; the final spaces and the
        // last line end go.
        return std.mem.trimEnd(u8, t, " \t\n");
    }

    /// Takes link reference definitions off the start of a paragraph's
    /// text and returns what is left.
    fn extractRefs(p: *Parser, i: u32, text_in: []const u8) Error![]const u8 {
        var text = text_in;
        const d = p.doc;
        var norm: std.ArrayList(u8) = .empty;
        defer norm.deinit(p.gpa);
        var dest: std.ArrayList(u8) = .empty;
        defer dest.deinit(p.gpa);
        var title: std.ArrayList(u8) = .empty;
        defer title.deinit(p.gpa);
        while (text.len > 0 and text[0] == '[') {
            const m = links.scanReference(text) orelse break;
            norm.clearRetainingCapacity();
            dest.clearRetainingCapacity();
            title.clearRetainingCapacity();
            try links.normalizeLabel(&norm, p.gpa, text[m.label[0]..m.label[1]]);
            try links.unescape(&dest, p.gpa, text[m.dest[0]..m.dest[1]]);
            if (m.title) |t| try links.unescape(&title, p.gpa, text[t[0]..t[1]]);
            try d.addRef(norm.items, dest.items, title.items, d.topOf(i));
            text = text[m.len..];
        }
        return text;
    }

    fn finalizeList(p: *Parser, i: u32) void {
        var item = p.b(i).first_child;
        outer: while (item != none) : (item = p.b(item).next) {
            if (p.b(item).next != none and p.endsWithBlank(item)) {
                p.b(i).list.tight = false;
                break;
            }
            var sub = p.b(item).first_child;
            while (sub != none) : (sub = p.b(sub).next) {
                if (p.b(sub).next != none and p.endsWithBlank(sub)) {
                    p.b(i).list.tight = false;
                    break :outer;
                }
            }
        }
        const l = p.b(i);
        if (l.last_child != none) l.line[1] = p.b(l.last_child).line[1];
    }

    fn endsWithBlank(p: *Parser, i: u32) bool {
        const nx = p.b(i).next;
        return nx != none and p.b(i).line[1] + 1 != p.b(nx).line[0];
    }

    fn taskItem(p: *Parser, i: u32) void {
        const first = p.b(i).first_child;
        if (first == none or p.b(first).kind != .paragraph) return;
        const para = p.b(first);
        const t = p.doc.contentOf(para.content);
        if (t.len < 3 or t[0] != '[' or t[2] != ']') return;
        const state: ast.Task = switch (t[1]) {
            ' ' => .unchecked,
            'x', 'X' => .checked,
            else => return,
        };
        if (t.len > 3 and !links.isWs(t[3])) return;
        var skip: u32 = 3;
        while (skip < t.len and links.isSpaceOrTab(t[skip])) skip += 1;
        p.b(i).task = state;
        para.content[0] += skip;
    }

    /// `> [!kind] Title` turns a block quote into a callout.
    fn callout(p: *Parser, i: u32) void {
        const first = p.b(i).first_child;
        if (first == none or p.b(first).kind != .paragraph) return;
        const para = p.b(first);
        const t = p.doc.contentOf(para.content);
        if (!std.mem.startsWith(u8, t, "[!")) return;
        var k: usize = 2;
        while (k < t.len and (std.ascii.isAlphanumeric(t[k]) or t[k] == '-' or t[k] == '_')) k += 1;
        if (k == 2 or k >= t.len or t[k] != ']') return;
        const line_end = std.mem.indexOfScalarPos(u8, t, k, '\n') orelse t.len;
        const base = para.content[0];
        const blk = p.b(i);
        blk.kind = .callout;
        blk.info = .{ base + 2, base + @as(u32, @intCast(k)) };
        const title = std.mem.trim(u8, t[k + 1 .. line_end], " \t");
        const ts: u32 = base + @as(u32, @intCast(@intFromPtr(title.ptr) - @intFromPtr(t.ptr)));
        blk.title = .{ ts, ts + @as(u32, @intCast(title.len)) };
        if (line_end >= t.len) {
            p.unlink(first);
        } else {
            para.content[0] = base + @as(u32, @intCast(line_end + 1));
        }
    }

    fn frontMatter(p: *Parser, fm: FrontMatter) Error!void {
        const d = p.doc;
        p.line = d.src.items[0..0];
        const i = try p.addBlock(.front_matter, 0, 0);
        const blk = p.b(i);
        blk.closed = true;
        blk.src = .{ 0, @intCast(fm.next) };
        p.cur_block = none;
        try p.flushContent(i, d.src.items[fm.content[0]..fm.content[1]]);
        p.tip = 0;
        p.line_no += @intCast(std.mem.count(u8, d.src.items[0..fm.next], "\n"));
    }

    // -- continuation ---------------------------------------------------

    const Cont = enum { matched, failed, done };

    fn continues(p: *Parser, i: u32) Error!Cont {
        const blk = p.b(i);
        switch (blk.kind) {
            .document, .list => return .matched,
            .block_quote => {
                if (!p.indented and p.peek(p.next_nonspace) == '>') {
                    p.advanceNextNonspace();
                    p.advanceOffset(1, false);
                    if (p.peek(p.offset)) |c| if (links.isSpaceOrTab(c)) p.advanceOffset(1, true);
                    return .matched;
                }
                return .failed;
            },
            .list_item => {
                if (p.blank) {
                    if (blk.first_child == none) return .failed;
                    p.advanceNextNonspace();
                } else if (p.indent >= blk.list.marker_offset + blk.list.padding) {
                    p.advanceOffset(blk.list.marker_offset + blk.list.padding, true);
                } else return .failed;
                return .matched;
            },
            .heading, .thematic_break => return .failed,
            .code_fenced => {
                const r = p.rest();
                if (p.indent <= 3 and r.len > 0 and r[0] == blk.fence_char) {
                    var n: usize = 0;
                    while (n < r.len and r[n] == blk.fence_char) n += 1;
                    if (n >= blk.level and std.mem.trim(u8, r[n..], " \t").len == 0) {
                        try p.finalize(i, p.line_no);
                        return .done;
                    }
                }
                var k: usize = blk.fence_offset;
                while (k > 0) : (k -= 1) {
                    const c = p.peek(p.offset) orelse break;
                    if (!links.isSpaceOrTab(c)) break;
                    p.advanceOffset(1, true);
                }
                return .matched;
            },
            .math_block => {
                if (blk.fence_char == 0) return .failed;
                const r = std.mem.trim(u8, p.rest(), " \t");
                if (p.indent <= 3 and std.mem.eql(u8, r, "$$")) {
                    try p.finalize(i, p.line_no);
                    return .done;
                }
                return .matched;
            },
            .front_matter => return .failed,
            .code_indented => {
                if (p.indent >= 4) {
                    p.advanceOffset(4, true);
                } else if (p.blank) {
                    p.advanceNextNonspace();
                } else return .failed;
                return .matched;
            },
            .html_literal => return if (p.blank and (blk.html_type == 6 or blk.html_type == 7)) .failed else .matched,
            .paragraph, .table => return if (p.blank) .failed else .matched,
            else => return .failed,
        }
    }

    // -- block starts ---------------------------------------------------

    const Start = enum { none, container, leaf };

    fn maybeSpecial(c: u8) bool {
        return switch (c) {
            '#', '`', '~', '*', '+', '_', '=', '<', '>', '-', '|', ':', '$' => true,
            '0'...'9' => true,
            else => false,
        };
    }

    fn tryStarts(p: *Parser, container: u32) Error!Start {
        const kind = p.b(container).kind;
        if (try p.startBlockQuote(container)) return .container;
        if (try p.startAtxHeading()) return .leaf;
        if (try p.startFence()) return .leaf;
        if (p.doc.opts.math and try p.startMath()) return .leaf;
        if (try p.startHtml(container)) return .leaf;
        if (kind == .paragraph and p.doc.opts.gfm and try p.startTable(container)) return .leaf;
        if (kind == .paragraph and try p.startSetext(container)) return .leaf;
        if (try p.startThematicBreak()) return .leaf;
        if (try p.startListItem(container)) return .container;
        if (try p.startIndentedCode()) return .leaf;
        return .none;
    }

    fn nestingOk(p: *Parser, container: u32) bool {
        return p.depth(container) < p.doc.opts.max_nesting;
    }

    fn startBlockQuote(p: *Parser, container: u32) Error!bool {
        if (p.indented or p.peek(p.next_nonspace) != '>' or !p.nestingOk(container)) return false;
        p.advanceNextNonspace();
        p.advanceOffset(1, false);
        if (p.peek(p.offset)) |c| if (links.isSpaceOrTab(c)) p.advanceOffset(1, true);
        try p.closeUnmatchedBlocks();
        _ = try p.addChild(.block_quote, p.next_nonspace);
        return true;
    }

    fn startAtxHeading(p: *Parser) Error!bool {
        if (p.indented) return false;
        const r = p.rest();
        var n: usize = 0;
        while (n < r.len and r[n] == '#') n += 1;
        if (n == 0 or n > 6) return false;
        if (n < r.len and !links.isSpaceOrTab(r[n])) return false;
        p.advanceNextNonspace();
        p.advanceOffset(n, false);
        try p.closeUnmatchedBlocks();
        const i = try p.addChild(.heading, p.next_nonspace);
        p.b(i).level = @intCast(n);
        // Content: drop an optional closing sequence.
        var c = std.mem.trim(u8, p.line[p.offset..], " \t");
        if (std.mem.trimEnd(u8, c, "#").len == 0) {
            c = "";
        } else {
            const stripped = std.mem.trimEnd(u8, c, "#");
            if (stripped.len < c.len and links.isSpaceOrTab(stripped[stripped.len - 1])) c = std.mem.trimEnd(u8, stripped, " \t");
        }
        try p.cur.appendSlice(p.gpa, c);
        p.advanceOffset(p.line.len - p.offset, false);
        p.skip_line = true;
        return true;
    }

    fn startFence(p: *Parser) Error!bool {
        if (p.indented) return false;
        const r = p.rest();
        if (r.len < 3 or (r[0] != '`' and r[0] != '~')) return false;
        const ch = r[0];
        var n: usize = 0;
        while (n < r.len and r[n] == ch) n += 1;
        if (n < 3) return false;
        const info_raw = std.mem.trim(u8, r[n..], " \t");
        if (ch == '`' and std.mem.indexOfScalar(u8, info_raw, '`') != null) return false;
        try p.closeUnmatchedBlocks();
        const i = try p.addChild(.code_fenced, p.next_nonspace);
        const blk = p.b(i);
        blk.fence_char = ch;
        blk.level = @intCast(@min(n, 255));
        blk.fence_offset = @intCast(p.indent);
        // The info string goes into the content pool right away.
        const d = p.doc;
        const start: u32 = @intCast(d.content.items.len);
        try links.unescape(&d.content, d.gpa, info_raw);
        p.b(i).info = .{ start, @intCast(d.content.items.len) };
        p.advanceNextNonspace();
        p.advanceOffset(n, false);
        p.skip_line = true;
        return true;
    }

    fn startMath(p: *Parser) Error!bool {
        if (p.indented) return false;
        const r = std.mem.trimEnd(u8, p.rest(), " \t");
        if (!std.mem.startsWith(u8, r, "$$")) return false;
        const inner = r[2..];
        const single = inner.len >= 2 and std.mem.endsWith(u8, inner, "$$");
        if (!single and std.mem.trim(u8, inner, " \t").len != 0) return false;
        try p.closeUnmatchedBlocks();
        const i = try p.addChild(.math_block, p.next_nonspace);
        if (single) {
            try p.cur.appendSlice(p.gpa, std.mem.trim(u8, inner[0 .. inner.len - 2], " \t"));
            try p.cur.append(p.gpa, '\n');
        } else p.b(i).fence_char = '$';
        p.advanceOffset(p.line.len - p.offset, false);
        p.skip_line = true;
        return true;
    }

    fn startHtml(p: *Parser, container: u32) Error!bool {
        if (p.indented or p.peek(p.next_nonspace) != '<') return false;
        const t = html.blockStart(p.rest());
        if (t == 0) return false;
        if (t == 7) {
            const lazy = !p.all_closed and !p.blank and p.b(p.tip).kind == .paragraph;
            if (p.b(container).kind == .paragraph or lazy) return false;
        }
        try p.closeUnmatchedBlocks();
        // The indentation is part of the block.
        const i = try p.addChild(.html_literal, p.offset);
        p.b(i).html_type = t;
        return true;
    }

    fn startSetext(p: *Parser, container: u32) Error!bool {
        if (p.indented) return false;
        const r = std.mem.trimEnd(u8, p.rest(), " \t");
        if (r.len == 0 or (r[0] != '=' and r[0] != '-')) return false;
        for (r) |c| if (c != r[0]) return false;
        try p.closeUnmatchedBlocks();
        // Definitions at the start are not part of the heading.
        const remaining = try p.extractRefs(container, p.cur.items);
        if (std.mem.trim(u8, remaining, " \t\n").len == 0) {
            const keep = try p.gpa.dupe(u8, remaining);
            defer p.gpa.free(keep);
            p.cur.clearRetainingCapacity();
            try p.cur.appendSlice(p.gpa, keep);
            return false;
        }
        const keep = try p.gpa.dupe(u8, remaining);
        defer p.gpa.free(keep);
        p.cur.clearRetainingCapacity();
        try p.cur.appendSlice(p.gpa, keep);
        const blk = p.b(container);
        blk.kind = .heading;
        blk.level = if (r[0] == '=') 1 else 2;
        p.advanceOffset(p.line.len - p.offset, false);
        p.skip_line = true;
        return true;
    }

    fn startThematicBreak(p: *Parser) Error!bool {
        if (p.indented) return false;
        const r = p.rest();
        if (r.len == 0) return false;
        const ch = r[0];
        if (ch != '*' and ch != '-' and ch != '_') return false;
        var n: usize = 0;
        for (r) |c| {
            if (c == ch) n += 1 else if (!links.isSpaceOrTab(c)) return false;
        }
        if (n < 3) return false;
        try p.closeUnmatchedBlocks();
        _ = try p.addChild(.thematic_break, p.next_nonspace);
        p.advanceOffset(p.line.len - p.offset, false);
        p.skip_line = true;
        return true;
    }

    fn startListItem(p: *Parser, container: u32) Error!bool {
        const ckind = p.b(container).kind;
        if (p.indented and ckind != .list) return false;
        if (p.indent >= 4) return false;
        if (!p.nestingOk(container)) return false;
        const r = p.rest();
        if (r.len == 0) return false;
        var data: ast.ListData = .{ .marker_offset = @intCast(p.indent) };
        var mlen: usize = 0;
        if (r[0] == '*' or r[0] == '+' or r[0] == '-') {
            data.marker = r[0];
            mlen = 1;
        } else {
            var n: usize = 0;
            while (n < r.len and n < 10 and std.ascii.isDigit(r[n])) n += 1;
            if (n == 0 or n > 9 or n >= r.len or (r[n] != '.' and r[n] != ')')) return false;
            const start = std.fmt.parseInt(u32, r[0..n], 10) catch return false;
            if (ckind == .paragraph and start != 1) return false;
            data.ordered = true;
            data.start = start;
            data.marker = r[n];
            mlen = n + 1;
        }
        if (mlen < r.len and !links.isSpaceOrTab(r[mlen])) return false;
        if (ckind == .paragraph and std.mem.trim(u8, r[mlen..], " \t").len == 0) return false;
        p.advanceNextNonspace();
        p.advanceOffset(mlen, true);
        const spaces_col = p.column;
        const spaces_off = p.offset;
        while (true) {
            p.advanceOffset(1, true);
            const c = p.peek(p.offset);
            if (!(p.column - spaces_col < 5 and c != null and links.isSpaceOrTab(c.?))) break;
        }
        const blank_item = p.peek(p.offset) == null;
        const after = p.column - spaces_col;
        if (after >= 5 or after < 1 or blank_item) {
            data.padding = @intCast(mlen + 1);
            p.column = spaces_col;
            p.offset = spaces_off;
            if (p.peek(p.offset)) |c| if (links.isSpaceOrTab(c)) p.advanceOffset(1, true);
        } else data.padding = @intCast(mlen + after);

        try p.closeUnmatchedBlocks();
        const tip = p.b(p.tip);
        if (tip.kind != .list or !listsMatch(tip.list, data)) {
            const l = try p.addChild(.list, p.next_nonspace);
            p.b(l).list = data;
        }
        const it = try p.addChild(.list_item, p.next_nonspace);
        p.b(it).list = data;
        return true;
    }

    fn listsMatch(a: ast.ListData, d: ast.ListData) bool {
        return a.ordered == d.ordered and a.marker == d.marker;
    }

    fn startIndentedCode(p: *Parser) Error!bool {
        if (!p.indented or p.b(p.tip).kind == .paragraph or p.blank) return false;
        p.advanceOffset(4, true);
        try p.closeUnmatchedBlocks();
        _ = try p.addChild(.code_indented, p.offset);
        return true;
    }

    // -- GFM tables -----------------------------------------------------

    /// A delimiter row under a paragraph whose last line has as many cells
    /// turns that line into a table header.
    fn startTable(p: *Parser, container: u32) Error!bool {
        if (p.indented or container != p.tip) return false;
        const r = std.mem.trim(u8, p.rest(), " \t");
        var aligns: std.ArrayList(ast.Align) = .empty;
        defer aligns.deinit(p.gpa);
        if (!try parseDelimiterRow(p.gpa, r, &aligns)) return false;
        // The header: the paragraph's last line.
        const text = std.mem.trimEnd(u8, p.cur.items, "\n");
        const ls = if (std.mem.lastIndexOfScalar(u8, text, '\n')) |n| n + 1 else 0;
        const header = text[ls..];
        if (std.mem.indexOfScalar(u8, header, '|') == null and std.mem.indexOfScalar(u8, r, '|') == null) return false;
        var cells: std.ArrayList([2]usize) = .empty;
        defer cells.deinit(p.gpa);
        try splitRow(p.gpa, header, &cells);
        if (cells.items.len != aligns.items.len) return false;

        try p.closeUnmatchedBlocks();
        const header_copy = try p.gpa.dupe(u8, header);
        defer p.gpa.free(header_copy);
        const para = container;
        const header_src = p.b(para).line_src[1];
        // Split the paragraph: earlier lines stay a paragraph.
        if (ls == 0) {
            // The whole paragraph is the header: it becomes the table.
            p.cur.clearRetainingCapacity();
            p.cur_block = none;
            p.unlink(para);
            p.tip = p.b(para).parent;
        } else {
            p.cur.shrinkRetainingCapacity(ls);
            try p.finalize(para, p.line_no -| 2);
        }
        const t = try p.addChild(.table, p.next_nonspace);
        const tb = p.b(t);
        tb.level = @intCast(@min(aligns.items.len, 255));
        tb.line[0] = p.line_no -| 1;
        tb.line_src[0] = header_src;
        tb.src[0] = header_src;
        try p.addRow(t, header_copy, aligns.items, true);
        p.table_aligns.clearRetainingCapacity();
        try p.table_aligns.appendSlice(p.gpa, aligns.items);
        p.advanceOffset(p.line.len - p.offset, false);
        p.skip_line = true;
        return true;
    }

    fn addRow(p: *Parser, table: u32, line: []const u8, aligns: []const ast.Align, header: bool) Error!void {
        var cells: std.ArrayList([2]usize) = .empty;
        defer cells.deinit(p.gpa);
        try splitRow(p.gpa, line, &cells);
        const row = try p.addBlock(.table_row, table, 0);
        p.b(row).closed = true;
        p.b(row).level = @intFromBool(header);
        const d = p.doc;
        for (aligns, 0..) |a, k| {
            const cell = try p.addBlock(.table_cell, row, 0);
            const start: u32 = @intCast(d.content.items.len);
            if (k < cells.items.len) {
                const c = line[cells.items[k][0]..cells.items[k][1]];
                // `\|` is a pipe, even inside code spans.
                var j: usize = 0;
                while (j < c.len) : (j += 1) {
                    if (c[j] == '\\' and j + 1 < c.len and c[j + 1] == '|') {
                        try d.content.append(d.gpa, '|');
                        j += 1;
                    } else try d.content.append(d.gpa, c[j]);
                }
            }
            const cb = p.b(cell);
            cb.content = .{ start, @intCast(d.content.items.len) };
            cb.align_ = a;
            cb.closed = true;
        }
        p.tip = table;
        p.cur_block = none;
    }

    fn parseDelimiterRow(gpa: Allocator, r: []const u8, out: *std.ArrayList(ast.Align)) Error!bool {
        var cells: std.ArrayList([2]usize) = .empty;
        defer cells.deinit(gpa);
        try splitRow(gpa, r, &cells);
        if (cells.items.len == 0) return false;
        for (cells.items) |c| {
            const t = std.mem.trim(u8, r[c[0]..c[1]], " \t");
            if (t.len == 0) return false;
            const left = t[0] == ':';
            const right = t[t.len - 1] == ':';
            const dashes = t[@intFromBool(left) .. t.len - @intFromBool(right and t.len > 1)];
            if (dashes.len == 0) return false;
            for (dashes) |ch| if (ch != '-') return false;
            try out.append(gpa, if (left and right) .center else if (left) .left else if (right) .right else .none);
        }
        return true;
    }

    /// Cell ranges of a table row (outer pipes optional, `\|` escaped).
    fn splitRow(gpa: Allocator, line_in: []const u8, out: *std.ArrayList([2]usize)) Error!void {
        const lead = line_in.len - std.mem.trimStart(u8, line_in, " \t").len;
        const line = std.mem.trimEnd(u8, line_in, " \t");
        var i: usize = lead;
        if (i < line.len and line[i] == '|') i += 1;
        var start = i;
        var j = i;
        while (j < line.len) {
            if (line[j] == '\\' and j + 1 < line.len) {
                j += 2;
                continue;
            }
            if (line[j] == '|') {
                try out.append(gpa, trimRange(line, start, j));
                start = j + 1;
            }
            j += 1;
        }
        if (start < line.len) try out.append(gpa, trimRange(line, start, line.len));
    }

    fn trimRange(s: []const u8, a: usize, e: usize) [2]usize {
        var x = a;
        var y = e;
        while (x < y and links.isSpaceOrTab(s[x])) x += 1;
        while (y > x and links.isSpaceOrTab(s[y - 1])) y -= 1;
        return .{ x, y };
    }

    // -- one line -------------------------------------------------------

    fn incorporate(p: *Parser, line: []const u8, line_src: u32) Error!void {
        var all_matched = true;
        var container: u32 = 0;
        p.old_tip = p.tip;
        p.offset = 0;
        p.column = 0;
        p.blank = false;
        p.partially_consumed_tab = false;
        p.line_no += 1;
        p.line = line;
        p.line_src = line_src;
        p.skip_line = false;

        while (true) {
            const last = p.b(container).last_child;
            if (last == none or p.b(last).closed) break;
            container = last;
            p.findNextNonspace();
            switch (try p.continues(container)) {
                .matched => {},
                .failed => {
                    all_matched = false;
                    container = p.b(container).parent;
                },
                .done => return,
            }
            if (!all_matched) break;
        }
        p.all_closed = container == p.old_tip;
        p.last_matched = container;

        const ck = p.b(container).kind;
        var matched_leaf = ck != .paragraph and acceptsLines(ck);
        while (!matched_leaf) {
            p.findNextNonspace();
            if (!p.indented and (p.next_nonspace >= line.len or !maybeSpecial(line[p.next_nonspace]))) {
                p.advanceNextNonspace();
                break;
            }
            switch (try p.tryStarts(container)) {
                .container => container = p.tip,
                .leaf => {
                    container = p.tip;
                    matched_leaf = true;
                },
                .none => {
                    p.advanceNextNonspace();
                    break;
                },
            }
        }

        if (!p.all_closed and !p.blank and p.b(p.tip).kind == .paragraph) {
            // Lazy continuation.
            try p.addLine();
        } else {
            try p.closeUnmatchedBlocks();
            const ck2 = p.b(container).kind;
            if (p.blank and p.b(container).last_child != none) p.b(p.b(container).last_child).last_line_blank = true;
            if (p.skip_line) {
                // The start took the line.
            } else if (ck2 == .table) {
                if (!p.blank) {
                    p.b(container).line[1] = p.line_no;
                    try p.addRow(container, line[p.offset..], p.table_aligns.items, false);
                    p.b(p.b(container).last_child).line = .{ p.line_no, p.line_no };
                }
            } else if (acceptsLines(ck2)) {
                try p.addLine();
                if (ck2 == .html_literal) {
                    const ht = p.b(container).html_type;
                    if (ht >= 1 and ht <= 5 and html.blockEnds(ht, line[@min(p.offset, line.len)..])) try p.finalize(container, p.line_no);
                }
            } else if (p.offset < line.len and !p.blank) {
                _ = try p.addChild(.paragraph, p.offset);
                p.advanceNextNonspace();
                try p.addLine();
            }
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}
