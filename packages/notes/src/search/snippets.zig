//! Search result snippets (E08.F06.S03.T01): up to three windows of about
//! ±60 bytes around the densest clusters of query-term hits in a note's
//! body, with the hits as highlight ranges. Windows snap to UTF-8
//! boundaries and stay within one line where the line allows.

const std = @import("std");
const tokenize = @import("tokenize.zig");
const retriever = @import("retriever.zig");

const Allocator = std.mem.Allocator;
const Snippet = retriever.Snippet;

pub const radius = 60;

/// A snippet of the line holding `pos`.
pub fn lineSnippet(t: []const u8, pos: u32, line: u32) Snippet {
    const p = @min(pos, t.len);
    const s = if (std.mem.lastIndexOfScalar(u8, t[0..p], '\n')) |i| i + 1 else 0;
    const e = std.mem.indexOfScalarPos(u8, t, p, '\n') orelse t.len;
    return .{ .range = .{ @intCast(s), @intCast(@min(e, s + 2 * radius)) }, .line = line };
}

/// Fills `out` with snippets of `t` (body from `body_start`) around hits
/// of `terms` (folded words; a word of 3+ bytes also matches words it
/// prefixes). Returns how many.
pub fn extract(a: Allocator, tok: *tokenize.Tokenizer, t: []const u8, body_start: u32, terms: *const std.StringHashMapUnmanaged(void), out: *[3]Snippet) !u8 {
    tok.buf.clearRetainingCapacity();
    tok.toks.clearRetainingCapacity();
    try tok.append(a, t[body_start..], body_start);
    var hits: std.ArrayList([2]u32) = .empty;
    for (0..tok.len()) |i| {
        const k = tok.get(i);
        if (isHit(terms, k.text)) try hits.append(a, .{ k.start, k.end });
    }
    if (hits.items.len == 0) return 0;
    const used = try a.alloc(bool, hits.items.len);
    @memset(used, false);
    var n: u8 = 0;
    while (n < 3) {
        // The unused hit with the most unused hits within ±radius.
        var best: ?usize = null;
        var best_count: usize = 0;
        for (hits.items, 0..) |h, i| {
            if (used[i]) continue;
            var count: usize = 0;
            for (hits.items, 0..) |o, j| {
                if (!used[j] and o[0] + radius >= h[0] and o[0] <= h[0] + radius) count += 1;
            }
            if (count > best_count) {
                best = i;
                best_count = count;
            }
        }
        const bi = best orelse break;
        const center = hits.items[bi][0];
        var s: usize = if (center > body_start + radius) center - radius else body_start;
        var e: usize = @min(t.len, @as(usize, center) + radius);
        // Stay on the hit's line when it is long enough.
        if (std.mem.lastIndexOfScalar(u8, t[s..center], '\n')) |nl| s += nl + 1;
        if (std.mem.indexOfScalarPos(u8, t, center, '\n')) |nl| e = @min(e, nl);
        s = snapBack(t, s);
        e = snapBack(t, e);
        var sn: Snippet = .{ .range = .{ @intCast(s), @intCast(e) }, .line = @intCast(std.mem.count(u8, t[0..s], "\n")) };
        for (hits.items, 0..) |h, j| {
            if (h[0] < s or h[1] > e) continue;
            used[j] = true;
            if (sn.n_highlights < retriever.max_highlights) {
                sn.highlights[sn.n_highlights] = h;
                sn.n_highlights += 1;
            }
        }
        used[bi] = true;
        out[n] = sn;
        n += 1;
    }
    // In note order.
    std.mem.sort(Snippet, out[0..n], {}, struct {
        fn lt(_: void, x: Snippet, y: Snippet) bool {
            return x.range[0] < y.range[0];
        }
    }.lt);
    return n;
}

fn isHit(terms: *const std.StringHashMapUnmanaged(void), word: []const u8) bool {
    if (terms.contains(word)) return true;
    var it = terms.keyIterator();
    while (it.next()) |k| if (k.len >= 3 and std.mem.startsWith(u8, word, k.*)) return true;
    return false;
}

fn snapBack(t: []const u8, i: usize) usize {
    var j = @min(i, t.len);
    while (j > 0 and j < t.len and (t[j] & 0xC0) == 0x80) j -= 1;
    return j;
}

test "snippets: densest windows with highlights, in note order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tok: tokenize.Tokenizer = .{};
    const filler = "lorem ipsum dolor sit amet " ** 8;
    const t = "---\nk: zig\n---\nintro zig\n" ++ filler ++ "\nzig zig zigzag here\n" ++ filler ++ "\nend zig";
    var terms: std.StringHashMapUnmanaged(void) = .empty;
    try terms.put(a, "zig", {});
    var out: [3]Snippet = undefined;
    const n = try extract(a, &tok, t, 15, &terms, &out);
    try std.testing.expectEqual(@as(u8, 3), n);
    try std.testing.expect(out[0].range[0] < out[1].range[0]);
    // The dense line has three highlights (zigzag counts as a prefix hit).
    const dense = for (out[0..n]) |s| {
        if (s.n_highlights == 3) break s;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("zig zig zigzag here", t[dense.range[0]..dense.range[1]]);
    // Frontmatter is not snippet text.
    for (out[0..n]) |s| try std.testing.expect(s.range[0] >= 15);
}
