//! Intraline refinement: which words (or characters) changed inside the
//! lines of a replace block.
//!
//! Lines of a block (a delete run next to an insert run) are paired in
//! order when the counts match, otherwise by character-bigram similarity
//! (Dice coefficient >= 0.5, keeping order). Each pair is tokenized into
//! UAX #29 word segments (punctuation one code point at a time), the
//! tokens interned and diffed with histogram; `char` mode, and lines under
//! 20 graphemes, diff graphemes with Myers instead. When over 60% of a
//! line's tokens changed the whole line is marked (no confetti). Changed
//! ranges separated by at most one whitespace token are merged. Blocks over
//! `max_block_lines` lines are skipped.

const std = @import("std");
const zg_text = @import("zg_text");
const script = @import("script.zig");
const hunks_mod = @import("hunks.zig");
const line_ids = @import("line_ids.zig");
const myers_mod = @import("myers.zig");
const histogram_mod = @import("histogram.zig");

const Allocator = std.mem.Allocator;
const Edit = script.Edit;
const DiffRange = hunks_mod.DiffRange;
const LineSource = line_ids.LineSource;
const word = zg_text.unicode.word;
const grapheme = zg_text.unicode.grapheme;

/// Token granularity.
pub const Mode = enum { word, char };

/// Lines shorter than this many graphemes are diffed by character.
pub const char_threshold = 20;
/// Pairs scored for similarity at most this many lines per side.
const max_pairing = 64;
/// Blocks with more lines than this on either side get no highlights
/// (rewrites, unrelated files).
pub const max_block_lines = 256;

/// Highlights for every replace block of `edits`, in byte offsets of each
/// side's text, sorted by side then offset.
pub fn intralineEdits(gpa: Allocator, edits: []const Edit, a: *const LineSource, b: *const LineSource, mode: Mode) Allocator.Error![]DiffRange {
    var out: std.ArrayList(DiffRange) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < edits.len) : (i += 1) {
        if (edits[i].kind == .equal) continue;
        // A block: one delete run and/or one insert run, adjacent.
        var del: ?Edit = null;
        var ins: ?Edit = null;
        while (i < edits.len and edits[i].kind != .equal) : (i += 1) {
            if (edits[i].kind == .delete) del = edits[i] else ins = edits[i];
        }
        if (del != null and ins != null) try block(gpa, &out, a, del.?.a_start, del.?.len, b, ins.?.b_start, ins.?.len, mode);
    }
    std.sort.pdq(DiffRange, out.items, {}, struct {
        fn lt(_: void, x: DiffRange, y: DiffRange) bool {
            if (x.side != y.side) return x.side == .old;
            return x.range.start < y.range.start;
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

fn block(gpa: Allocator, out: *std.ArrayList(DiffRange), a: *const LineSource, a0: usize, na: usize, b: *const LineSource, b0: usize, nb: usize, mode: Mode) Allocator.Error!void {
    if (na > max_block_lines or nb > max_block_lines) return;
    if (na == nb or na > max_pairing or nb > max_pairing) {
        for (0..@min(na, nb)) |k| try pairRanges(gpa, out, a, a0 + k, b, b0 + k, mode);
        return;
    }
    // Greedy in-order pairing by similarity.
    var next_b: usize = 0;
    for (0..na) |i| {
        var best: ?usize = null;
        var best_score: f32 = 0.5;
        for (next_b..nb) |j| {
            const sc = dice(a.line(a0 + i), b.line(b0 + j));
            if (sc >= best_score) {
                if (best == null or sc > best_score) {
                    best = j;
                    best_score = sc;
                }
            }
        }
        if (best) |j| {
            try pairRanges(gpa, out, a, a0 + i, b, b0 + j, mode);
            next_b = j + 1;
        }
    }
}

/// Dice coefficient of the byte bigram multisets (bounded to 256 bigrams
/// per line).
pub fn dice(x: []const u8, y: []const u8) f32 {
    if (x.len < 2 or y.len < 2) return if (std.mem.eql(u8, x, y)) 1 else 0;
    var bx: [256]u16 = undefined;
    var by: [256]u16 = undefined;
    const nx = bigrams(x, &bx);
    const ny = bigrams(y, &by);
    std.sort.pdq(u16, bx[0..nx], {}, std.sort.asc(u16));
    std.sort.pdq(u16, by[0..ny], {}, std.sort.asc(u16));
    var i: usize = 0;
    var j: usize = 0;
    var common: usize = 0;
    while (i < nx and j < ny) {
        if (bx[i] == by[j]) {
            common += 1;
            i += 1;
            j += 1;
        } else if (bx[i] < by[j]) i += 1 else j += 1;
    }
    return @as(f32, @floatFromInt(2 * common)) / @as(f32, @floatFromInt(nx + ny));
}

fn bigrams(s: []const u8, out: *[256]u16) usize {
    const n = @min(s.len - 1, out.len);
    for (0..n) |k| out[k] = @as(u16, s[k]) << 8 | s[k + 1];
    return n;
}

const Tok = struct { start: u32, len: u32, ws: bool };

fn tokenize(gpa: Allocator, s: []const u8, mode: Mode, out: *std.ArrayList(Tok)) Allocator.Error!void {
    out.clearRetainingCapacity();
    if (mode == .char) {
        var it = grapheme.Iterator.init(s);
        while (it.next()) |g| try out.append(gpa, .{ .start = @intCast(g.start), .len = @intCast(g.len), .ws = isSpace(s[g.start..][0..g.len]) });
        return;
    }
    var it = word.WordIterator.init(s);
    while (it.next()) |w| {
        if (w.kind == .punct or w.kind == .other) {
            // One token per grapheme, so `foo.bar` vs `foo->bar` stays local.
            var g = grapheme.Iterator.init(s[w.start..][0..w.len]);
            while (g.next()) |c| try out.append(gpa, .{ .start = @intCast(w.start + c.start), .len = @intCast(c.len), .ws = false });
        } else {
            try out.append(gpa, .{ .start = @intCast(w.start), .len = @intCast(w.len), .ws = w.kind == .space });
        }
    }
}

fn isSpace(s: []const u8) bool {
    for (s) |c| if (c != ' ' and c != '\t') return false;
    return s.len > 0;
}

fn pairRanges(gpa: Allocator, out: *std.ArrayList(DiffRange), a: *const LineSource, ai: usize, b: *const LineSource, bi: usize, mode_in: Mode) Allocator.Error!void {
    const la = a.line(ai);
    const lb = b.line(bi);
    const mode: Mode = if (mode_in == .word and grapheme.count(la) < char_threshold and grapheme.count(lb) < char_threshold) .char else mode_in;
    var ta: std.ArrayList(Tok) = .empty;
    defer ta.deinit(gpa);
    var tb: std.ArrayList(Tok) = .empty;
    defer tb.deinit(gpa);
    try tokenize(gpa, la, mode, &ta);
    try tokenize(gpa, lb, mode, &tb);
    // Intern the tokens.
    var map: std.StringHashMapUnmanaged(u32) = .empty;
    defer map.deinit(gpa);
    const ids_a = try gpa.alloc(u32, ta.items.len);
    defer gpa.free(ids_a);
    const ids_b = try gpa.alloc(u32, tb.items.len);
    defer gpa.free(ids_b);
    inline for (.{ .{ la, ta.items, ids_a }, .{ lb, tb.items, ids_b } }) |side| {
        for (side[1], side[2]) |t, *id| {
            const g = try map.getOrPut(gpa, side[0][t.start..][0..t.len]);
            if (!g.found_existing) g.value_ptr.* = map.count() - 1;
            id.* = g.value_ptr.*;
        }
    }
    var m = try script.Marks.init(gpa, ids_a, ids_b, null);
    defer m.deinit(gpa);
    if (mode == .char)
        try myers_mod.markRegion(gpa, &m, 0, ids_a.len, 0, ids_b.len, false)
    else
        try histogram_mod.markRegion(gpa, &m, 0, ids_a.len, 0, ids_b.len);
    try emit(gpa, out, .old, a.offsetOf(ai), la.len, ta.items, m.ca);
    try emit(gpa, out, .new, b.offsetOf(bi), lb.len, tb.items, m.cb);
}

fn emit(gpa: Allocator, out: *std.ArrayList(DiffRange), side: DiffRange.Side, base: u64, line_len: usize, toks: []const Tok, changed: []const bool) Allocator.Error!void {
    // The confetti ratio counts non-whitespace tokens only.
    var n_changed: usize = 0;
    var n_words: usize = 0;
    for (changed, toks) |c, t| if (!t.ws) {
        n_words += 1;
        n_changed += @intFromBool(c);
    };
    var any = n_changed > 0;
    for (changed) |c| any = any or c;
    if (!any) return;
    if (n_words > 0 and n_changed * 10 > n_words * 6) {
        try out.append(gpa, .{ .side = side, .range = .{ .start = base, .end = base + line_len }, .kind = .changed });
        return;
    }
    var k: usize = 0;
    while (k < toks.len) {
        if (!changed[k]) {
            k += 1;
            continue;
        }
        const s = k;
        var e = k + 1;
        while (true) {
            while (e < toks.len and changed[e]) e += 1;
            // Bridge a single unchanged whitespace token.
            if (e + 1 < toks.len and toks[e].ws and changed[e + 1]) {
                e += 2;
                continue;
            }
            break;
        }
        const r0 = toks[s].start;
        const r1 = toks[e - 1].start + toks[e - 1].len;
        try out.append(gpa, .{ .side = side, .range = .{ .start = base + r0, .end = base + r1 }, .kind = .changed });
        k = e;
    }
}
