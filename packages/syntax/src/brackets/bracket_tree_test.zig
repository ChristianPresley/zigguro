//! Tests for the bracket-pair tree: matching, depth, unmatched brackets,
//! and incremental updates checked against a full rebuild.

const std = @import("std");
const bt_mod = @import("bracket_tree.zig");

const testing = std.testing;
const gpa = testing.allocator;
const BracketTree = bt_mod.BracketTree;
const BracketToken = bt_mod.BracketToken;
const BracketPairInfo = bt_mod.BracketPairInfo;
const TextEdit = bt_mod.TextEdit;
const Range = bt_mod.Range;

/// A toy lexer: `()`, `[]` and `{}` are pairs 0, 1 and 2; a `"` starts or
/// ends a string, where brackets are text.
fn lexToy(text: []const u8, out: *std.ArrayList(BracketToken)) !void {
    out.clearRetainingCapacity();
    var in_str = false;
    for (text, 0..) |c, i| {
        if (c == '"') in_str = !in_str;
        if (in_str) continue;
        const t: ?struct { u6, bool } = switch (c) {
            '(' => .{ 0, true },
            ')' => .{ 0, false },
            '[' => .{ 1, true },
            ']' => .{ 1, false },
            '{' => .{ 2, true },
            '}' => .{ 2, false },
            else => null,
        };
        if (t) |x| try out.append(gpa, .{ .offset = i, .len = 1, .pair = x[0], .open = x[1] });
    }
}

const Doc = struct {
    text: std.ArrayList(u8) = .empty,
    toks: std.ArrayList(BracketToken) = .empty,
    src: bt_mod.SliceSource = .{ .tokens = &.{}, .text_len = 0 },

    fn init(text: []const u8) !Doc {
        var d: Doc = .{};
        try d.text.appendSlice(gpa, text);
        try d.relex();
        return d;
    }

    fn deinit(d: *Doc) void {
        d.text.deinit(gpa);
        d.toks.deinit(gpa);
    }

    fn relex(d: *Doc) !void {
        try lexToy(d.text.items, &d.toks);
        d.src = .{ .tokens = d.toks.items, .text_len = d.text.items.len };
    }

    fn source(d: *Doc) bt_mod.BracketSource {
        return d.src.source();
    }
};

fn expectPairs(t: *const BracketTree, want: []const struct { u64, ?u64, u32 }) !void {
    var out: std.ArrayList(BracketPairInfo) = .empty;
    defer out.deinit(gpa);
    try t.pairsInRange(gpa, .{ .start = 0, .end = t.len() }, &out);
    try testing.expectEqual(want.len, out.items.len);
    for (want, out.items) |w, p| {
        try testing.expectEqual(w[0], p.open);
        try testing.expectEqual(w[1], p.close);
        try testing.expectEqual(w[2], p.depth);
    }
}

fn expectUnmatched(t: *const BracketTree, want: []const u64) !void {
    var out: std.ArrayList(u64) = .empty;
    defer out.deinit(gpa);
    try t.unmatched(gpa, .{ .start = 0, .end = t.len() }, &out);
    try testing.expectEqualSlices(u64, want, out.items);
}

test "bracket_tree: depth for rainbow" {
    var d: Doc = try .init("f(a[b{c}], {d})");
    defer d.deinit();
    var t: BracketTree = try .build(gpa, d.source());
    defer t.deinit();
    try t.check();
    try expectPairs(&t, &.{ .{ 1, 14, 0 }, .{ 3, 8, 1 }, .{ 5, 7, 2 }, .{ 11, 13, 1 } });
    const m = t.matching(8).?;
    try testing.expectEqual(@as(u64, 3), m.open);
    try testing.expectEqual(@as(u32, 1), m.depth);
    try testing.expect(t.matching(0) == null);
    try testing.expect(t.matching(2) == null);
    try testing.expectEqual(@as(u64, 5), t.enclosing(6).?.open);
    try testing.expectEqual(@as(u64, 3), t.enclosing(4).?.open);
    try testing.expectEqual(@as(u64, 1), t.enclosing(10).?.open);
    try testing.expectEqual(@as(u64, 1), t.enclosing(9).?.open);
    try testing.expect(t.enclosing(15) == null);
    // A range query returns the pairs it touches and those around it.
    var out: std.ArrayList(BracketPairInfo) = .empty;
    defer out.deinit(gpa);
    try t.pairsInRange(gpa, .{ .start = 12, .end = 12 }, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u64, 11), out.items[1].open);
}

test "bracket_tree: unmatched reported" {
    var d: Doc = try .init("a) (b] [c\n{ }");
    defer d.deinit();
    var t: BracketTree = try .build(gpa, d.source());
    defer t.deinit();
    try t.check();
    // `)` has no opener. In `(b]`, `]` closes nothing that is open, so it
    // is unmatched inside the parens; `(` and `[` are never closed.
    try expectUnmatched(&t, &.{ 1, 3, 5, 7 });
    try expectPairs(&t, &.{ .{ 3, null, 0 }, .{ 7, null, 1 }, .{ 10, 12, 2 } });
    // A closing bracket that matches an outer opener closes the inner
    // pairs early.
    var d2: Doc = try .init("{ ( }");
    defer d2.deinit();
    var t2: BracketTree = try .build(gpa, d2.source());
    defer t2.deinit();
    try expectPairs(&t2, &.{ .{ 0, 4, 0 }, .{ 2, null, 1 } });
    try expectUnmatched(&t2, &.{2});
}

test "bracket_tree: brackets in strings ignored" {
    var d: Doc = try .init("f(\")\", x)");
    defer d.deinit();
    var t: BracketTree = try .build(gpa, d.source());
    defer t.deinit();
    try expectPairs(&t, &.{.{ 1, 8, 0 }});
    try expectUnmatched(&t, &.{});
}

/// Applies `edits` (old offsets, disjoint, sorted) to the doc and returns
/// the new-offset range where tokens changed outside the edits.
fn applyText(d: *Doc, edits: []const struct { TextEdit, []const u8 }) !?Range {
    var old_toks: std.ArrayList(BracketToken) = .empty;
    defer old_toks.deinit(gpa);
    try old_toks.appendSlice(gpa, d.toks.items);
    var i = edits.len;
    while (i > 0) {
        i -= 1;
        const e = edits[i][0];
        try d.text.replaceRange(gpa, @intCast(e.start), @intCast(e.end - e.start), edits[i][1]);
    }
    try d.relex();
    // Map old tokens outside the edits to new offsets.
    var mapped: std.AutoHashMapUnmanaged(BracketToken, void) = .empty;
    defer mapped.deinit(gpa);
    var fresh: std.AutoHashMapUnmanaged(BracketToken, void) = .empty;
    defer fresh.deinit(gpa);
    var lo: u64 = std.math.maxInt(u64);
    var hi: u64 = 0;
    for (old_toks.items) |tk| {
        var delta: i64 = 0;
        var inside = false;
        for (edits) |ed| {
            const e = ed[0];
            if (tk.offset + tk.len <= e.start) break;
            if (tk.offset < e.end) {
                inside = true;
                break;
            }
            delta += @as(i64, @intCast(ed[1].len)) - @as(i64, @intCast(e.end - e.start));
        }
        if (inside) continue;
        var m = tk;
        m.offset = @intCast(@as(i64, @intCast(tk.offset)) + delta);
        try mapped.put(gpa, m, {});
    }
    // New tokens inside the edits' new text.
    var new_ranges: std.ArrayList(Range) = .empty;
    defer new_ranges.deinit(gpa);
    var delta: i64 = 0;
    for (edits) |ed| {
        const e = ed[0];
        const ns: u64 = @intCast(@as(i64, @intCast(e.start)) + delta);
        try new_ranges.append(gpa, .{ .start = ns, .end = ns + ed[1].len });
        delta += @as(i64, @intCast(ed[1].len)) - @as(i64, @intCast(e.end - e.start));
    }
    for (d.toks.items) |tk| {
        var inside = false;
        for (new_ranges.items) |r| if (tk.offset < r.end and tk.offset + tk.len > r.start) {
            inside = true;
        };
        if (inside) continue;
        try fresh.put(gpa, tk, {});
        if (!mapped.contains(tk)) {
            lo = @min(lo, tk.offset);
            hi = @max(hi, tk.offset + tk.len);
        }
    }
    var it = mapped.keyIterator();
    while (it.next()) |tk| if (!fresh.contains(tk.*)) {
        lo = @min(lo, tk.offset);
        hi = @max(hi, tk.offset + tk.len);
    };
    return if (lo < hi) .{ .start = lo, .end = hi } else null;
}

fn expectSame(a: *const BracketTree, b: *const BracketTree) !void {
    try testing.expectEqual(b.len(), a.len());
    var pa: std.ArrayList(BracketPairInfo) = .empty;
    defer pa.deinit(gpa);
    var pb: std.ArrayList(BracketPairInfo) = .empty;
    defer pb.deinit(gpa);
    try a.pairsInRange(gpa, .{ .start = 0, .end = a.len() + 1 }, &pa);
    try b.pairsInRange(gpa, .{ .start = 0, .end = b.len() + 1 }, &pb);
    try testing.expectEqualSlices(BracketPairInfo, pb.items, pa.items);
    var ua: std.ArrayList(u64) = .empty;
    defer ua.deinit(gpa);
    var ub: std.ArrayList(u64) = .empty;
    defer ub.deinit(gpa);
    try a.unmatched(gpa, .{ .start = 0, .end = a.len() + 1 }, &ua);
    try b.unmatched(gpa, .{ .start = 0, .end = b.len() + 1 }, &ub);
    try testing.expectEqualSlices(u64, ub.items, ua.items);
}

fn randomText(rnd: std.Random, buf: []u8) []u8 {
    const alphabet = "()[]{}()[]{}xx  \n\"";
    const n = rnd.uintAtMost(usize, buf.len);
    for (buf[0..n]) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
    return buf[0..n];
}

fn fuzzOne(seed: u64, steps: usize) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rnd = prng.random();
    var buf: [400]u8 = undefined;
    var d: Doc = try .init(randomText(rnd, &buf));
    defer d.deinit();
    var t: BracketTree = try .build(gpa, d.source());
    defer t.deinit();
    for (0..steps) |_| {
        // One to three disjoint edits.
        var edits: [3]struct { TextEdit, []const u8 } = undefined;
        var ins_bufs: [3][24]u8 = undefined;
        var ne: usize = 0;
        var at: u64 = 0;
        const n = rnd.uintAtMost(usize, 2) + 1;
        for (0..n) |k| {
            const len = d.text.items.len;
            if (at > len) break;
            const start = at + rnd.uintAtMost(u64, @min(len - at, 60));
            const end = start + rnd.uintAtMost(u64, @min(len - start, 8));
            const ins = randomText(rnd, ins_bufs[k][0..rnd.uintAtMost(usize, 24)]);
            edits[ne] = .{ .{ .start = start, .end = end, .new_len = ins.len }, ins };
            ne += 1;
            at = end + 1;
        }
        const retok = try applyText(&d, edits[0..ne]);
        var tes: [3]TextEdit = undefined;
        for (edits[0..ne], 0..) |e, k| tes[k] = e[0];
        const rs: []const Range = if (retok) |r| &.{r} else &.{};
        try t.applyEdits(tes[0..ne], rs, d.source());
        try t.check();
        var fresh: BracketTree = try .build(gpa, d.source());
        defer fresh.deinit();
        try expectSame(&t, &fresh);
        // No leaks: live nodes are reachable from the root.
        try testing.expect(t.nodeCount() <= 4 * d.text.items.len + 4);
    }
}

test "bracket_tree: incremental equals rebuild" {
    for (0..40) |seed| try fuzzOne(seed, 50);
}

test "bracket_tree: incremental reuses nodes" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..2000) |i| try text.print(gpa, "fn f{d}() {{ if (x[{d}]) {{ y(); }} }}\n", .{ i, i });
    var d: Doc = try .init(text.items);
    defer d.deinit();
    var t: BracketTree = try .build(gpa, d.source());
    defer t.deinit();
    const before = t.stats.new_nodes;
    const mid = d.text.items.len / 2;
    const at = std.mem.indexOfPos(u8, d.text.items, mid, "y()").?;
    _ = try applyText(&d, &.{.{ .{ .start = at, .end = at, .new_len = 1 }, "z" }});
    try t.applyEdits(&.{.{ .start = at, .end = at, .new_len = 1 }}, &.{}, d.source());
    try t.check();
    // A handful of new nodes per level, not a rebuild.
    try testing.expect(t.stats.new_nodes - before < 200);
    var fresh: BracketTree = try .build(gpa, d.source());
    defer fresh.deinit();
    try expectSame(&t, &fresh);
    // Opening a string runs to the end: the rest is retokenized.
    const q = std.mem.indexOfPos(u8, d.text.items, mid, "{").?;
    const r = try applyText(&d, &.{.{ .{ .start = q, .end = q, .new_len = 1 }, "\"" }});
    try t.applyEdits(&.{.{ .start = q, .end = q, .new_len = 1 }}, if (r) |x| &.{x} else &.{}, d.source());
    var fresh2: BracketTree = try .build(gpa, d.source());
    defer fresh2.deinit();
    try expectSame(&t, &fresh2);
}

test "bracket_tree: fuzz incremental equals rebuild" {
    try testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) anyerror!void {
            try fuzzOne(smith.value(u64), 20);
        }
    }.f, .{});
}
