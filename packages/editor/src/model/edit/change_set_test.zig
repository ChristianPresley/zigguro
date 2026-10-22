//! ChangeSet law tests (compose, invert, TP1), mapping tables, LSP change
//! sequences and the fuzz target.

const std = @import("std");
const zg_core = @import("zg_core");
const cs_mod = @import("change_set.zig");
const pt = @import("../buffer/piece_tree.zig");
const buffers = @import("../buffer/buffers.zig");
const NodePool = @import("../buffer/node_pool.zig").NodePool;

const ChangeSet = cs_mod.ChangeSet;
const Replace = cs_mod.Replace;
const gpa = std.testing.allocator;

const alphabet = [_]u8{ 'a', 'b', 'c', '\n', '\r', 0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80 };

fn Source(comptime T: type) type {
    return struct {
        inner: T,
        fn pick(s: *@This(), n: usize) usize {
            if (n <= 1) return 0;
            if (T == std.Random) return s.inner.uintLessThan(usize, n);
            return s.inner.index(n);
        }
    };
}

fn randomText(src: anytype, buf: []u8) []u8 {
    const n = src.pick(buf.len + 1);
    for (buf[0..n]) |*c| c.* = alphabet[src.pick(alphabet.len)];
    return buf[0..n];
}

/// A random valid ChangeSet over a text of `len` bytes.
fn randomChangeSet(src: anytype, len: u64) !ChangeSet {
    var edits: [6]Replace = undefined;
    var texts: [6][6]u8 = undefined;
    var n: usize = 0;
    var pos: u64 = 0;
    while (n < edits.len and pos <= len and src.pick(4) != 0) : (n += 1) {
        const a = pos + src.pick(@intCast(@min(len - pos, 20) + 1));
        const b = a + src.pick(@intCast(@min(len - a, 6) + 1));
        edits[n] = .{ .range = .{ .start = a, .end = b }, .text = randomText(src, &texts[n]) };
        pos = b + src.pick(3);
    }
    // Shuffle to exercise sorting.
    if (n > 1) std.mem.swap(Replace, &edits[0], &edits[n - 1]);
    return ChangeSet.fromEdits(gpa, len, edits[0..n]);
}

fn applyStr(cs: *const ChangeSet, s: []const u8) ![]u8 {
    return cs.applyToSlice(gpa, s);
}

fn checkLaws(src: anytype) !void {
    var tbuf: [80]u8 = undefined;
    const base = randomText(src, &tbuf);
    var a = try randomChangeSet(src, base.len);
    defer a.deinit();
    var b0 = try randomChangeSet(src, base.len);
    defer b0.deinit();
    const after_a = try applyStr(&a, base);
    defer gpa.free(after_a);

    // invert: apply(invert(a), apply(a, s)) == s
    {
        var pool: NodePool = .init(gpa);
        defer pool.deinit();
        const bt = try buffers.BufferTable.create(gpa, try gpa.dupe(u8, base), true);
        defer bt.release();
        var t = try pt.PieceTree.fromOriginal(&pool, bt);
        defer t.deinit(&pool);
        var inv = try a.invert(t, gpa);
        defer inv.deinit();
        const back = try applyStr(&inv, after_a);
        defer gpa.free(back);
        try std.testing.expectEqualStrings(base, back);
        // apply through the piece tree too
        var t2 = try a.apply(t, &pool);
        defer t2.deinit(&pool);
        const got = try t2.copyRange(gpa, .{ .start = 0, .end = t2.len() });
        defer gpa.free(got);
        try std.testing.expectEqualStrings(after_a, got);
    }

    // compose: apply(compose(a, b)) == apply(b, apply(a))
    {
        var b = try randomChangeSet(src, after_a.len);
        defer b.deinit();
        var ab = try a.compose(&b, gpa);
        defer ab.deinit();
        const want = try applyStr(&b, after_a);
        defer gpa.free(want);
        const got = try applyStr(&ab, base);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(want, got);
        try std.testing.expectEqual(b.newLen(), ab.newLen());
    }

    // TP1: apply(b', apply(a)) == apply(a', apply(b))
    {
        const b = &b0;
        for ([_]bool{ true, false }) |a_wins| {
            var a1 = try a.transform(b, a_wins, gpa);
            defer a1.deinit();
            var b1 = try b.transform(&a, !a_wins, gpa);
            defer b1.deinit();
            const after_b = try applyStr(b, base);
            defer gpa.free(after_b);
            const x = try applyStr(&b1, after_a);
            defer gpa.free(x);
            const y = try applyStr(&a1, after_b);
            defer gpa.free(y);
            try std.testing.expectEqualStrings(x, y);
        }
    }

    // mapPos is monotone and lands inside the new text.
    var prev: u64 = 0;
    for (0..base.len + 1) |p| {
        const m = a.mapPos(p, .left);
        const r = a.mapPos(p, .right);
        try std.testing.expect(m <= r and r <= a.newLen() and m >= prev);
        prev = m;
    }
}

test "change_set: fromEdits rejects overlap" {
    try std.testing.expectError(error.Overlap, ChangeSet.fromEdits(gpa, 10, &.{
        .{ .range = .{ .start = 2, .end = 5 }, .text = "x" },
        .{ .range = .{ .start = 4, .end = 6 }, .text = "" },
    }));
    try std.testing.expectError(error.OutOfBounds, ChangeSet.fromEdits(gpa, 10, &.{.{ .range = .{ .start = 8, .end = 11 }, .text = "" }}));
    var cs = try ChangeSet.fromEdits(gpa, 10, &.{
        .{ .range = .{ .start = 5, .end = 6 }, .text = "B" },
        .{ .range = .{ .start = 2, .end = 5 }, .text = "A" },
        .{ .range = .{ .start = 8, .end = 8 }, .text = "" },
    });
    defer cs.deinit();
    try std.testing.expectEqual(@as(usize, 1), cs.replaces.len);
    try std.testing.expectEqualStrings("AB", cs.replaces[0].text);
    try std.testing.expectEqual(@as(u64, 8), cs.newLen());
    try std.testing.expectEqual(@as(u64, 2), cs.insertedBytes());
    try std.testing.expectEqual(@as(u64, 4), cs.deletedBytes());
}

test "change_set: invert restores" {
    var prng: std.Random.DefaultPrng = .init(31);
    var src: Source(std.Random) = .{ .inner = prng.random() };
    for (0..500) |_| try checkLaws(&src);
}

test "change_set: compose law" {
    var cs1 = try ChangeSet.fromEdits(gpa, 5, &.{.{ .range = .{ .start = 1, .end = 3 }, .text = "XYZ" }});
    defer cs1.deinit();
    var cs2 = try ChangeSet.fromEdits(gpa, 6, &.{.{ .range = .{ .start = 2, .end = 5 }, .text = "q" }});
    defer cs2.deinit();
    var c = try cs1.compose(&cs2, gpa);
    defer c.deinit();
    const out = try c.applyToSlice(gpa, "abcde");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("aXqe", out);
}

test "change_set: transform TP1 convergence" {
    // Both insert at 2; a wins puts a's text first.
    var a = try ChangeSet.fromEdits(gpa, 4, &.{.{ .range = .{ .start = 2, .end = 2 }, .text = "A" }});
    defer a.deinit();
    var b = try ChangeSet.fromEdits(gpa, 4, &.{.{ .range = .{ .start = 2, .end = 2 }, .text = "B" }});
    defer b.deinit();
    var a1 = try a.transform(&b, true, gpa);
    defer a1.deinit();
    const after_b = try b.applyToSlice(gpa, "wxyz");
    defer gpa.free(after_b);
    const out = try a1.applyToSlice(gpa, after_b);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("wxAByz", out);
    // a modifies text b deleted: conflicted, collapses to an insertion.
    var c = try ChangeSet.fromEdits(gpa, 4, &.{.{ .range = .{ .start = 1, .end = 3 }, .text = "Q" }});
    defer c.deinit();
    var d = try ChangeSet.fromEdits(gpa, 4, &.{.{ .range = .{ .start = 0, .end = 4 }, .text = "" }});
    defer d.deinit();
    var c1 = try c.transform(&d, false, gpa);
    defer c1.deinit();
    try std.testing.expect(c1.conflicted);
    try std.testing.expectEqual(@as(u64, 0), c1.base_len);
    try std.testing.expectEqualStrings("Q", c1.replaces[0].text);
}

test "change_set: mapPos bias table" {
    // "0123456789": insert "AB" at 3, replace [5,7) with "x", delete [8,9).
    var cs = try ChangeSet.fromEdits(gpa, 10, &.{
        .{ .range = .{ .start = 3, .end = 3 }, .text = "AB" },
        .{ .range = .{ .start = 5, .end = 7 }, .text = "x" },
        .{ .range = .{ .start = 8, .end = 9 }, .text = "" },
    });
    defer cs.deinit();
    // new text: "012AB34x79"
    const T = struct { pos: u64, left: u64, right: u64 };
    const table = [_]T{
        .{ .pos = 0, .left = 0, .right = 0 },
        .{ .pos = 3, .left = 3, .right = 5 }, // insert at pos
        .{ .pos = 4, .left = 6, .right = 6 },
        .{ .pos = 5, .left = 7, .right = 7 }, // replace touching start
        .{ .pos = 6, .left = 7, .right = 8 }, // inside replaced range
        .{ .pos = 7, .left = 8, .right = 8 }, // replace touching end
        .{ .pos = 8, .left = 9, .right = 9 }, // delete start
        .{ .pos = 9, .left = 9, .right = 9 }, // delete end
        .{ .pos = 10, .left = 10, .right = 10 },
    };
    for (table) |row| {
        try std.testing.expectEqual(row.left, cs.mapPos(row.pos, .left));
        try std.testing.expectEqual(row.right, cs.mapPos(row.pos, .right));
    }
    try std.testing.expect(cs.mapPosDetail(6, .left).deleted);
    try std.testing.expect(!cs.mapPosDetail(5, .left).deleted);
    try std.testing.expectEqual(cs_mod.Range{ .start = 3, .end = 6 }, cs.mapRange(.{ .start = 3, .end = 4 }, .expand).?);
    try std.testing.expectEqual(cs_mod.Range{ .start = 5, .end = 6 }, cs.mapRange(.{ .start = 3, .end = 4 }, .shrink).?);
    try std.testing.expectEqual(@as(?cs_mod.Range, null), cs.mapRange(.{ .start = 4, .end = 5 }, .delete_if_touched));
    try std.testing.expectEqual(cs_mod.Range{ .start = 0, .end = 2 }, cs.mapRange(.{ .start = 0, .end = 2 }, .delete_if_touched).?);
}

/// Applies LSP changes in sequence to a naive line model with columns in
/// UTF-16 units.
fn applyLsp(text: []const u8, changes: []const cs_mod.LspChange) ![]u8 {
    var cur: std.ArrayList(u8) = .empty;
    errdefer cur.deinit(gpa);
    try cur.appendSlice(gpa, text);
    for (changes) |ch| {
        var li = try zg_core.LineIndex.build(gpa, cur.items);
        defer li.deinit(gpa);
        const s = offsetOf(cur.items, &li, ch.start);
        const e = offsetOf(cur.items, &li, ch.end);
        try cur.replaceRange(gpa, s, e - s, ch.text);
    }
    return cur.toOwnedSlice(gpa);
}

fn offsetOf(text: []const u8, li: *const zg_core.LineIndex, p: cs_mod.PointUtf16) usize {
    const ls: usize = @intCast(li.lineStart(@intCast(p.line)));
    const le: usize = if (p.line + 1 < li.lineCount()) @intCast(li.lineStart(@intCast(p.line + 1))) else text.len;
    return ls + zg_core.utf8.columnToByte(text[ls..le], p.col, .utf16);
}

test "change_set: toLspChanges sequential application equals apply" {
    var prng: std.Random.DefaultPrng = .init(32);
    const r = prng.random();
    const pieces = [_][]const u8{ "a", "é", "😀", "\n", "\r\n", "xyz", "€" };
    for (0..300) |_| {
        var base: std.ArrayList(u8) = .empty;
        defer base.deinit(gpa);
        for (0..r.uintLessThan(usize, 30)) |_| try base.appendSlice(gpa, pieces[r.uintLessThan(usize, pieces.len)]);
        // Edits at code point boundaries (LSP clients send those).
        var bounds: std.ArrayList(u64) = .empty;
        defer bounds.deinit(gpa);
        var i: usize = 0;
        while (i <= base.items.len) : (i += 1) {
            if (i == base.items.len or (base.items[i] & 0xC0) != 0x80) {
                // never split a CRLF
                if (i > 0 and i < base.items.len and base.items[i - 1] == '\r' and base.items[i] == '\n') continue;
                try bounds.append(gpa, i);
            }
        }
        var edits: [4]Replace = undefined;
        var n: usize = 0;
        var k: usize = 0;
        while (n < 4 and k < bounds.items.len) : (n += 1) {
            const a = k + r.uintLessThan(usize, @min(bounds.items.len - k, 5));
            const b = a + r.uintLessThan(usize, @min(bounds.items.len - a, 3));
            edits[n] = .{ .range = .{ .start = bounds.items[a], .end = bounds.items[b] }, .text = pieces[r.uintLessThan(usize, pieces.len)] };
            k = b + 1;
        }
        var cs = ChangeSet.fromEdits(gpa, base.items.len, edits[0..n]) catch continue;
        defer cs.deinit();
        var pool: NodePool = .init(gpa);
        defer pool.deinit();
        const bt = try buffers.BufferTable.create(gpa, try gpa.dupe(u8, base.items), true);
        defer bt.release();
        var t = try pt.PieceTree.fromOriginal(&pool, bt);
        defer t.deinit(&pool);
        var changes: std.ArrayList(cs_mod.LspChange) = .empty;
        defer changes.deinit(gpa);
        try cs.toLspChanges(t, .utf16, &changes, gpa);
        const got = try applyLsp(base.items, changes.items);
        defer gpa.free(got);
        const want = try cs.applyToSlice(gpa, base.items);
        defer gpa.free(want);
        try std.testing.expectEqualStrings(want, got);
    }
}

test "fuzz: changeset laws" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var src: Source(*std.testing.Smith) = .{ .inner = s };
            try checkLaws(&src);
        }
    }.one, .{});
}
