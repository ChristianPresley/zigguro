//! Word-level text matching for document proposals (E13.F04.S01.T01):
//! minimal word hunks between two texts (what the review shows as tracked
//! changes), finding text again after the user edited around it (with
//! whitespace normalized, then by word similarity), and the similarity
//! score itself.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A replacement of `text[start..end]` by `new`.
pub const Hunk = struct {
    start: u32,
    end: u32,
    new: []const u8,
};

pub const Token = struct { start: u32, end: u32 };

/// Words, runs of whitespace and single punctuation characters.
pub fn tokenize(a: Allocator, text: []const u8) Allocator.Error![]Token {
    var out: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        const c = text[i];
        if (isSpace(c)) {
            while (i < text.len and isSpace(text[i])) i += 1;
        } else if (isWord(c)) {
            while (i < text.len and isWord(text[i])) i += 1;
        } else i += 1;
        try out.append(a, .{ .start = @intCast(start), .end = @intCast(i) });
    }
    return out.items;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isWord(c: u8) bool {
    return c >= 0x80 or std.ascii.isAlphanumeric(c) or c == '_' or c == '\'';
}

/// Above this many tokens on both sides of the changed middle, the hunk
/// is the whole middle (the table would be too big).
pub const max_lcs_tokens = 1500;

/// The word hunks turning `old` into `new`; offsets are into `old`, plus
/// `base` (where `old` sits in the document).
pub fn hunks(a: Allocator, old: []const u8, new: []const u8, base: u32) Allocator.Error![]Hunk {
    const ot = try tokenize(a, old);
    const nt = try tokenize(a, new);
    var pre: usize = 0;
    while (pre < ot.len and pre < nt.len and tokEql(old, ot[pre], new, nt[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < ot.len - pre and suf < nt.len - pre and tokEql(old, ot[ot.len - 1 - suf], new, nt[nt.len - 1 - suf])) suf += 1;
    const om = ot[pre .. ot.len - suf];
    const nm = nt[pre .. nt.len - suf];
    var out: std.ArrayList(Hunk) = .empty;
    if (om.len == 0 and nm.len == 0) return out.items;
    if (om.len > max_lcs_tokens or nm.len > max_lcs_tokens) {
        try out.append(a, .{ .start = base + spanStart(ot, pre, old.len), .end = base + spanEnd(ot, ot.len - suf, pre, old.len), .new = new[spanStart(nt, pre, new.len)..spanEnd(nt, nt.len - suf, pre, new.len)] });
        return out.items;
    }
    const mid: Mid = .{ .old = spanStart(ot, pre, old.len), .new = spanStart(nt, pre, new.len), .base = base };
    // LCS table over the middles, walked forwards into hunks.
    const w = nm.len + 1;
    const table = try a.alloc(u16, (om.len + 1) * w);
    @memset(table, 0);
    var i: usize = om.len;
    while (i > 0) {
        i -= 1;
        var j: usize = nm.len;
        while (j > 0) {
            j -= 1;
            table[i * w + j] = if (tokEql(old, om[i], new, nm[j]))
                table[(i + 1) * w + j + 1] + 1
            else
                @max(table[(i + 1) * w + j], table[i * w + j + 1]);
        }
    }
    i = 0;
    var j: usize = 0;
    var open: ?struct { oi: usize, nj: usize } = null;
    while (i < om.len or j < nm.len) {
        if (i < om.len and j < nm.len and tokEql(old, om[i], new, nm[j])) {
            if (open) |o| try out.append(a, mid.hunk(new, om, nm, o.oi, i, o.nj, j));
            open = null;
            i += 1;
            j += 1;
        } else {
            if (open == null) open = .{ .oi = i, .nj = j };
            if (j < nm.len and (i == om.len or table[i * w + j + 1] >= table[(i + 1) * w + j])) j += 1 else i += 1;
        }
    }
    if (open) |o| try out.append(a, mid.hunk(new, om, nm, o.oi, om.len, o.nj, nm.len));
    return out.items;
}

/// Where the changed middles start, for hunks at their edges.
const Mid = struct {
    old: u32,
    new: u32,
    base: u32,

    fn hunk(m: Mid, new: []const u8, om: []const Token, nm: []const Token, oi: usize, oe: usize, ni: usize, ne: usize) Hunk {
        const os = edge(om, oi, m.old);
        const oend = if (oe > oi) om[oe - 1].end else os;
        const ns = edge(nm, ni, m.new);
        const nend = if (ne > ni) nm[ne - 1].end else ns;
        return .{ .start = m.base + os, .end = m.base + oend, .new = new[ns..nend] };
    }

    fn edge(t: []const Token, i: usize, start: u32) u32 {
        return if (i < t.len) t[i].start else if (t.len > 0) t[t.len - 1].end else start;
    }
};

fn spanStart(t: []const Token, i: usize, len: usize) u32 {
    return if (i < t.len) t[i].start else @intCast(len);
}

fn spanEnd(t: []const Token, e: usize, i: usize, len: usize) u32 {
    return if (e > i) t[e - 1].end else spanStart(t, i, len);
}

fn tokEql(x: []const u8, a: Token, y: []const u8, b: Token) bool {
    return std.mem.eql(u8, x[a.start..a.end], y[b.start..b.end]);
}

/// Where `needle` occurs in `hay` with runs of whitespace treated as one
/// space (and leading/trailing whitespace ignored): the byte range in
/// `hay`, or null. `count` gets the number of occurrences.
pub fn findLoose(a: Allocator, hay: []const u8, needle: []const u8, count: *u32) Allocator.Error!?[2]u32 {
    count.* = 0;
    const n = try squash(a, std.mem.trim(u8, needle, " \t\r\n"), null);
    if (n.text.len == 0) return null;
    const h = try squash(a, hay, a);
    var first: ?[2]u32 = null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, h.text, from, n.text)) |p| : (from = p + 1) {
        count.* += 1;
        if (first == null) first = .{ h.map[p], h.map[p + n.text.len - 1] + 1 };
    }
    return first;
}

const Squashed = struct { text: []const u8, map: []const u32 };

fn squash(a: Allocator, s: []const u8, want_map: ?Allocator) Allocator.Error!Squashed {
    var out: std.ArrayList(u8) = .empty;
    var map: std.ArrayList(u32) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (isSpace(s[i])) {
            const st = i;
            while (i < s.len and isSpace(s[i])) i += 1;
            try out.append(a, ' ');
            if (want_map) |m| try map.append(m, @intCast(st));
        } else {
            try out.append(a, s[i]);
            if (want_map) |m| try map.append(m, @intCast(i));
            i += 1;
        }
    }
    return .{ .text = out.items, .map = map.items };
}

/// Words only (no whitespace or punctuation), as ranges.
pub fn words(a: Allocator, text: []const u8) Allocator.Error![]Token {
    var out: std.ArrayList(Token) = .empty;
    for (try tokenize(a, text)) |t| if (isWord(text[t.start])) try out.append(a, t);
    return out.items;
}

/// Dice similarity of two word sequences: 2·LCS / (|x| + |y|).
pub fn similarity(a: Allocator, xt: []const u8, x: []const Token, yt: []const u8, y: []const Token) Allocator.Error!f32 {
    if (x.len + y.len == 0) return 1;
    const w = y.len + 1;
    const row = try a.alloc(u16, w);
    const prev = try a.alloc(u16, w);
    @memset(prev, 0);
    for (x) |xi| {
        row[0] = 0;
        for (y, 1..) |yj, j| row[j] = if (tokEql(xt, xi, yt, yj)) prev[j - 1] + 1 else @max(prev[j], row[j - 1]);
        @memcpy(prev, row);
    }
    return 2 * @as(f32, @floatFromInt(prev[y.len])) / @as(f32, @floatFromInt(x.len + y.len));
}

/// The span of `hay` most similar to `needle` by words, if it reaches
/// `min`: windows of the needle's length ±25% starting at words that
/// occur in the needle's first few words.
pub fn findSimilar(a: Allocator, hay: []const u8, needle: []const u8, min: f32) Allocator.Error!?[2]u32 {
    const nw = try words(a, needle);
    const hw = try words(a, hay);
    if (nw.len == 0 or hw.len == 0 or nw.len > 4000) return null;
    const slack = @max(1, nw.len / 4);
    var best: f32 = 0;
    var best_span: ?[2]u32 = null;
    var s: usize = 0;
    while (s < hw.len) : (s += 1) {
        const lead = @min(nw.len, 4);
        const starts = for (nw[0..lead]) |t| {
            if (tokEql(needle, t, hay, hw[s])) break true;
        } else false;
        if (!starts) continue;
        var len = if (nw.len > slack) nw.len - slack else 1;
        while (len <= nw.len + slack and s + len <= hw.len) : (len += 1) {
            const sim = try similarity(a, needle, nw, hay, hw[s .. s + len]);
            if (sim > best) {
                best = sim;
                best_span = .{ hw[s].start, hw[s + len - 1].end };
            }
        }
    }
    var span = best_span orelse return null;
    if (best < min) return null;
    // Words carry no punctuation: take the needle's leading and trailing
    // punctuation along when the text has it too.
    const lead = needle[0..nw[0].start];
    const trail = needle[nw[nw.len - 1].end..];
    const lt = std.mem.trimStart(u8, lead, " \t\r\n");
    const tt = std.mem.trimEnd(u8, trail, " \t\r\n");
    if (lt.len > 0 and span[0] >= lt.len and std.mem.eql(u8, hay[span[0] - lt.len .. span[0]], lt)) span[0] -= @intCast(lt.len);
    if (tt.len > 0 and std.mem.startsWith(u8, hay[span[1]..], tt)) span[1] += @intCast(tt.len);
    return span;
}
