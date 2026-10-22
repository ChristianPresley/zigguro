//! Styled text for Markdown leaves (E04.F06.S01.T02): a leaf block's
//! inline tree flattened into one string with style runs, its line
//! breaking across runs, hit testing and caret positions.
//!
//! Soft breaks become spaces and hard breaks newlines, so the flattened
//! text is also what Copy puts on the clipboard. Lines are measured by
//! per-codepoint advances in each run's style (as `text.LineIter` does
//! for one style), so measuring, painting and hit testing agree.

const std = @import("std");
const ast = @import("ast.zig");
const doc_mod = @import("doc.zig");
const geom = @import("../core/geom.zig");
const text_mod = @import("../paint/text.zig");

const Allocator = std.mem.Allocator;
const Doc = doc_mod.Doc;
const TextStyle = text_mod.TextStyle;
const TextSystem = text_mod.TextSystem;
const Vec2 = geom.Vec2;
const none = ast.none;

/// How a run is drawn.
pub const Flags = packed struct(u16) {
    italic: bool = false,
    bold: bool = false,
    code: bool = false,
    strike: bool = false,
    link: bool = false,
    math: bool = false,
    /// Image alt text and raw HTML: drawn muted.
    muted: bool = false,
    /// A link with an unsafe destination: drawn as a warning, never opened.
    unsafe: bool = false,
    _pad: u8 = 0,
};

/// A styled byte range of `Flat.text`.
pub const Run = struct {
    start: u32,
    end: u32,
    flags: Flags = .{},
    /// Index into `Flat.links`, or `none`.
    link: u32 = none,
};

/// What a link points at.
pub const LinkKind = enum(u8) { url, wiki, anchor, footnote };

/// A link's target; `dest` is a range of `Flat.strings`.
pub const Link = struct {
    kind: LinkKind,
    dest: [2]u32,
    unsafe: bool = false,
};

/// A leaf's flattened text.
pub const Flat = struct {
    text: std.ArrayList(u8) = .empty,
    /// Contiguous, covering `text`.
    runs: std.ArrayList(Run) = .empty,
    links: std.ArrayList(Link) = .empty,
    strings: std.ArrayList(u8) = .empty,

    /// Frees the lists.
    pub fn deinit(f: *Flat, gpa: Allocator) void {
        f.text.deinit(gpa);
        f.runs.deinit(gpa);
        f.links.deinit(gpa);
        f.strings.deinit(gpa);
    }

    /// Empties the lists, keeping their memory.
    pub fn clear(f: *Flat) void {
        f.text.clearRetainingCapacity();
        f.runs.clearRetainingCapacity();
        f.links.clearRetainingCapacity();
        f.strings.clearRetainingCapacity();
    }

    /// The destination of link `i`.
    pub fn linkDest(f: *const Flat, i: u32) []const u8 {
        const l = f.links.items[i];
        return f.strings.items[l.dest[0]..l.dest[1]];
    }

    /// The run containing byte `off` (the last run at the end).
    pub fn runAt(f: *const Flat, off: u32) ?u32 {
        const runs = f.runs.items;
        if (runs.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = runs.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (runs[mid].end <= off) lo = mid + 1 else hi = mid;
        }
        return @intCast(@min(lo, runs.len - 1));
    }

    /// Appends `s` in `flags`, merging with the previous run when equal.
    pub fn emit(f: *Flat, gpa: Allocator, s: []const u8, flags: Flags, link: u32) Allocator.Error!void {
        if (s.len == 0) return;
        const start: u32 = @intCast(f.text.items.len);
        try f.text.appendSlice(gpa, s);
        const end: u32 = @intCast(f.text.items.len);
        if (f.runs.items.len > 0) {
            const last = &f.runs.items[f.runs.items.len - 1];
            if (@as(u16, @bitCast(last.flags)) == @as(u16, @bitCast(flags)) and last.link == link) {
                last.end = end;
                return;
            }
        }
        try f.runs.append(gpa, .{ .start = start, .end = end, .flags = flags, .link = link });
    }

    fn addLink(f: *Flat, gpa: Allocator, kind: LinkKind, dest: []const u8, unsafe: bool) Allocator.Error!u32 {
        const s: u32 = @intCast(f.strings.items.len);
        try f.strings.appendSlice(gpa, dest);
        try f.links.append(gpa, .{ .kind = kind, .dest = .{ s, @intCast(f.strings.items.len) }, .unsafe = unsafe });
        return @intCast(f.links.items.len - 1);
    }
};

/// Flattens the inlines of leaf block `blk` into `out` (cleared first).
/// Blocks without inlines (code) contribute their text in one run.
pub fn flatten(gpa: Allocator, d: *const Doc, blk: u32, out: *Flat) Allocator.Error!void {
    out.clear();
    const b = d.blocks.items[blk];
    if (!b.kind.hasInlines()) {
        const flags: Flags = switch (b.kind) {
            .code_fenced, .code_indented, .math_block, .front_matter => .{ .code = true },
            .html_literal => .{ .muted = true },
            else => .{},
        };
        var t = d.contentOf(b.content);
        if (t.len > 0 and t[t.len - 1] == '\n') t = t[0 .. t.len - 1];
        return out.emit(gpa, t, flags, none);
    }
    const Frame = struct { next: u32, flags: Flags, link: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    var flags: Flags = .{};
    var link: u32 = none;
    var cur = b.first_inline;
    while (true) {
        if (cur == none) {
            const fr = stack.pop() orelse break;
            flags = fr.flags;
            link = fr.link;
            cur = fr.next;
            continue;
        }
        const n = &d.inlines.items[cur];
        var inner = flags;
        var inner_link = link;
        var container = false;
        switch (n.kind) {
            .text => try out.emit(gpa, d.inlineText(n), flags, link),
            .softbreak => try out.emit(gpa, " ", flags, link),
            .hardbreak => try out.emit(gpa, "\n", flags, link),
            .code => try out.emit(gpa, d.inlineText(n), withCode(flags), link),
            .math => try out.emit(gpa, d.inlineText(n), withMath(flags), link),
            .html_literal => try out.emit(gpa, d.inlineText(n), withMuted(flags), link),
            .footnote_ref => {},
            .emph => {
                inner.italic = true;
                container = true;
            },
            .strong => {
                inner.bold = true;
                container = true;
            },
            .strike => {
                inner.strike = true;
                container = true;
            },
            .image => {
                inner.muted = true;
                container = true;
            },
            .link => {
                const dest = d.destOf(n);
                const kind: LinkKind = if (dest.len > 0 and dest[0] == '#') .anchor else .url;
                inner_link = try out.addLink(gpa, kind, dest, n.unsafe);
                if (n.unsafe) inner.unsafe = true else inner.link = true;
                container = true;
            },
            .autolink => {
                const l = try out.addLink(gpa, .url, d.destOf(n), n.unsafe);
                var f = flags;
                if (n.unsafe) f.unsafe = true else f.link = true;
                try out.emit(gpa, d.contentOf(n.text), f, l);
            },
            .wikilink, .embed => {
                const target = d.inlineText(n);
                inner_link = try out.addLink(gpa, .wiki, target, false);
                inner.link = true;
                if (n.kind == .embed) inner.muted = true;
                if (n.first_child == none) {
                    try out.emit(gpa, target, inner, inner_link);
                } else container = true;
            },
        }
        if (container and n.first_child != none) {
            try stack.append(gpa, .{ .next = n.next, .flags = flags, .link = link });
            flags = inner;
            link = inner_link;
            cur = n.first_child;
        } else cur = n.next;
    }
}

fn withCode(f: Flags) Flags {
    var g = f;
    g.code = true;
    return g;
}

fn withMath(f: Flags) Flags {
    var g = f;
    g.math = true;
    return g;
}

fn withMuted(f: Flags) Flags {
    var g = f;
    g.muted = true;
    return g;
}

/// One laid-out line of a `Flat`: a byte range and its width.
pub const Line = struct { start: u32, end: u32, w: f32 };

/// The text system and base style a leaf is laid out with.
pub const Shape = struct {
    ts: TextSystem,
    base: TextStyle,

    /// The style of a run.
    pub fn styleOf(s: Shape, flags: Flags) TextStyle {
        var st = s.base;
        if (flags.code or flags.math) {
            st.font = .mono;
            st.size = s.base.size * 0.92;
        }
        if (flags.bold) st.weight = if (st.weight >= 600) 800 else 600;
        if (flags.italic) st.italic = true;
        return st;
    }

    /// The height of every line.
    pub fn lineHeight(s: Shape) f32 {
        return s.ts.metrics(s.base).line_h;
    }

    /// The baseline below a line's top.
    pub fn baseline(s: Shape) f32 {
        const m = s.ts.metrics(s.base);
        return (m.line_h - (m.ascent + m.descent)) / 2 + m.ascent;
    }

    /// The width of `f.text[a..b]` (one line).
    pub fn width(s: Shape, f: *const Flat, a: u32, b: u32) f32 {
        var w: f32 = 0;
        var c: Cursor = .init(f, a);
        while (c.i < b) w += c.step(s);
        return w;
    }
};

/// Walks a `Flat` by codepoint, tracking the run.
const Cursor = struct {
    f: *const Flat,
    i: u32,
    run: u32,

    fn init(f: *const Flat, at: u32) Cursor {
        return .{ .f = f, .i = at, .run = f.runAt(at) orelse 0 };
    }

    fn cp(c: *const Cursor, len: *u32) u21 {
        const s = c.f.text.items;
        const n: u32 = std.unicode.utf8ByteSequenceLength(s[c.i]) catch 1;
        if (c.i + n > s.len) {
            len.* = @intCast(s.len - c.i);
            return 0xfffd;
        }
        len.* = n;
        return std.unicode.utf8Decode(s[c.i .. c.i + n]) catch 0xfffd;
    }

    /// The advance of the codepoint at `i`; moves past it.
    fn step(c: *Cursor, s: Shape) f32 {
        var n: u32 = 1;
        const code = c.cp(&n);
        const runs = c.f.runs.items;
        while (c.run + 1 < runs.len and runs[c.run].end <= c.i) c.run += 1;
        const adv = if (code == '\n') 0 else s.ts.advance(s.styleOf(if (runs.len > 0) runs[c.run].flags else .{}), code);
        c.i += n;
        return adv;
    }
};

/// Greedy line breaking of `f` at spaces and newlines (a word wider than
/// the line breaks between codepoints); `max_w` null: no wrapping.
pub fn layout(gpa: Allocator, s: Shape, f: *const Flat, max_w: ?f32, out: *std.ArrayList(Line)) Allocator.Error!void {
    out.clearRetainingCapacity();
    const t = f.text.items;
    const len: u32 = @intCast(t.len);
    var start: u32 = 0;
    while (true) {
        var c: Cursor = .init(f, start);
        var w: f32 = 0;
        var brk: ?u32 = null;
        var w_at_brk: f32 = 0;
        var ended = true;
        while (c.i < len) {
            const at = c.i;
            if (t[at] == '\n') {
                try out.append(gpa, .{ .start = start, .end = at, .w = w });
                start = at + 1;
                ended = false;
                break;
            }
            var probe = c;
            const adv = probe.step(s);
            if (max_w) |mw| if (w + adv > mw + 0.001 and at > start and t[at] != ' ') {
                if (brk) |b| {
                    try out.append(gpa, .{ .start = start, .end = b, .w = w_at_brk });
                    start = b + 1;
                } else {
                    try out.append(gpa, .{ .start = start, .end = at, .w = w });
                    start = at;
                }
                ended = false;
                break;
            };
            if (t[at] == ' ') {
                brk = at;
                w_at_brk = w;
            }
            c = probe;
            w += adv;
        }
        if (ended) {
            try out.append(gpa, .{ .start = start, .end = len, .w = w });
            return;
        }
    }
}

/// The widest line of `f` unwrapped (max-content) and its widest word
/// (min-content).
pub fn contentWidths(s: Shape, f: *const Flat) struct { max: f32, min: f32 } {
    const t = f.text.items;
    var c: Cursor = .init(f, 0);
    var line: f32 = 0;
    var word: f32 = 0;
    var max: f32 = 0;
    var min: f32 = 0;
    while (c.i < t.len) {
        const ch = t[c.i];
        const adv = c.step(s);
        if (ch == '\n') {
            max = @max(max, line);
            min = @max(min, word);
            line = 0;
            word = 0;
            continue;
        }
        line += adv;
        if (ch == ' ') {
            min = @max(min, word);
            word = 0;
        } else word += adv;
    }
    return .{ .max = @max(max, line), .min = @max(min, word) };
}

/// The byte offset nearest `p` (local coordinates).
pub fn hitTest(s: Shape, f: *const Flat, lines: []const Line, p: Vec2) u32 {
    if (lines.len == 0) return 0;
    const lh = s.lineHeight();
    const row: usize = if (p.y <= 0) 0 else @min(lines.len - 1, @as(usize, @intFromFloat(p.y / lh)));
    if (p.y < 0) return lines[0].start;
    if (p.y >= lh * @as(f32, @floatFromInt(lines.len))) return lines[lines.len - 1].end;
    const ln = lines[row];
    var c: Cursor = .init(f, ln.start);
    var x: f32 = 0;
    while (c.i < ln.end) {
        const at = c.i;
        const adv = c.step(s);
        if (p.x < x + adv / 2) return at;
        x += adv;
    }
    return ln.end;
}

/// The line holding `off` and the x of `off` on it.
pub fn caretAt(s: Shape, f: *const Flat, lines: []const Line, off: u32) struct { row: usize, x: f32 } {
    for (lines, 0..) |ln, i| {
        const last = i + 1 == lines.len;
        if (off <= ln.end or last) {
            const o = @max(ln.start, @min(off, ln.end));
            return .{ .row = i, .x = s.width(f, ln.start, o) };
        }
        // `off` sits in the break between this line and the next.
        if (off < lines[i + 1].start) return .{ .row = i, .x = ln.w };
    }
    return .{ .row = 0, .x = 0 };
}

/// The word around `off` (letters, digits, `_`); a single byte otherwise.
pub fn wordAt(t: []const u8, off: u32) [2]u32 {
    const isWord = struct {
        fn f(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
        }
    }.f;
    if (t.len == 0) return .{ 0, 0 };
    const o = @min(off, @as(u32, @intCast(t.len - 1)));
    if (!isWord(t[o])) return .{ o, o + 1 };
    var a = o;
    while (a > 0 and isWord(t[a - 1])) a -= 1;
    var b = o;
    while (b < t.len and isWord(t[b])) b += 1;
    return .{ a, b };
}

test "flatten styles, breaks and links" {
    const stream = @import("stream.zig");
    const gpa = std.testing.allocator;
    var d = try stream.parse(gpa, "a *b* **c** `d` ~~e~~\nf  \ng [h](/x) <javascript:y>\n", .{});
    defer d.deinit();
    var f: Flat = .{};
    defer f.deinit(gpa);
    try flatten(gpa, &d, d.blocks.items[0].first_child, &f);
    try std.testing.expectEqualStrings("a b c d e f\ng h javascript:y", f.text.items);
    const R = struct { s: []const u8, fl: Flags };
    const want = [_]R{
        .{ .s = "a ", .fl = .{} },
        .{ .s = "b", .fl = .{ .italic = true } },
        .{ .s = " ", .fl = .{} },
        .{ .s = "c", .fl = .{ .bold = true } },
        .{ .s = " ", .fl = .{} },
        .{ .s = "d", .fl = .{ .code = true } },
        .{ .s = " ", .fl = .{} },
        .{ .s = "e", .fl = .{ .strike = true } },
        .{ .s = " f\ng ", .fl = .{} },
        .{ .s = "h", .fl = .{ .link = true } },
        .{ .s = " ", .fl = .{} },
        .{ .s = "javascript:y", .fl = .{ .unsafe = true } },
    };
    try std.testing.expectEqual(want.len, f.runs.items.len);
    for (want, f.runs.items) |w, r| {
        try std.testing.expectEqualStrings(w.s, f.text.items[r.start..r.end]);
        try std.testing.expectEqual(@as(u16, @bitCast(w.fl)), @as(u16, @bitCast(r.flags)));
    }
    try std.testing.expectEqualStrings("/x", f.linkDest(f.runs.items[9].link));
    try std.testing.expect(f.links.items[f.runs.items[11].link].unsafe);
}

test "layout wraps across runs and hit tests" {
    const gpa = std.testing.allocator;
    var mono: text_mod.MonoText = .{};
    const s: Shape = .{ .ts = mono.system(), .base = .{ .size = 10 } };
    var f: Flat = .{};
    defer f.deinit(gpa);
    try f.emit(gpa, "aaa ", .{}, none);
    try f.emit(gpa, "bbb", .{ .bold = true }, none);
    try f.emit(gpa, " ccc\nd", .{}, none);
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(gpa);
    try layout(gpa, s, &f, 45, &lines);
    // 6 px per char: "aaa bbb" is 42 px; "ccc" wraps; "\n" breaks.
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("aaa bbb", f.text.items[lines.items[0].start..lines.items[0].end]);
    try std.testing.expectEqualStrings("ccc", f.text.items[lines.items[1].start..lines.items[1].end]);
    try std.testing.expectEqualStrings("d", f.text.items[lines.items[2].start..lines.items[2].end]);
    const lh = s.lineHeight();
    try std.testing.expectEqual(@as(u32, 5), hitTest(s, &f, lines.items, .{ .x = 32, .y = 1 }));
    try std.testing.expectEqual(@as(u32, 9), hitTest(s, &f, lines.items, .{ .x = 7, .y = lh + 1 }));
    try std.testing.expectEqual(@as(u32, 13), hitTest(s, &f, lines.items, .{ .x = 100, .y = 10 * lh }));
    const c = caretAt(s, &f, lines.items, 9);
    try std.testing.expectEqual(@as(usize, 1), c.row);
    try std.testing.expectEqual(@as(f32, 6), c.x);
    const cw = contentWidths(s, &f);
    try std.testing.expectEqual(@as(f32, 66), cw.max);
    try std.testing.expectEqual(@as(f32, 18), cw.min);
    try std.testing.expectEqual([2]u32{ 4, 7 }, wordAt(f.text.items, 5));
}
