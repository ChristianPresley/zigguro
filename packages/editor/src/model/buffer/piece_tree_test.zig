//! Piece tree tests: a differential model against `ArrayList(u8)` plus
//! `zg_core.LineIndex`, persistence, iterators and the fuzz target.

const std = @import("std");
const zg_core = @import("zg_core");
const pt = @import("piece_tree.zig");
const buffers = @import("buffers.zig");
const NodePool = @import("node_pool.zig").NodePool;

const PieceTree = pt.PieceTree;
const gpa = std.testing.allocator;

const Env = struct {
    pool: NodePool,
    bt: *buffers.BufferTable,

    fn init(original: []const u8) !Env {
        return .{ .pool = .init(gpa), .bt = try buffers.BufferTable.create(gpa, try gpa.dupe(u8, original), true) };
    }

    fn deinit(e: *Env) void {
        e.pool.deinit();
        e.bt.release();
    }
};

fn expectText(t: PieceTree, want: []const u8) !void {
    const got = try t.copyRange(gpa, .{ .start = 0, .end = t.len() });
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
}

/// Compares every query against the naive model.
fn expectQueries(t: PieceTree, text: []const u8) !void {
    try std.testing.expectEqual(@as(u64, text.len), t.len());
    var li = try zg_core.LineIndex.build(gpa, text);
    defer li.deinit(gpa);
    try std.testing.expectEqual(@as(u64, li.lineCount()), t.lineCount());
    for (0..li.lineCount()) |line| {
        try std.testing.expectEqual(li.lineStart(@intCast(line)), t.lineStart(line));
    }
    var off: usize = 0;
    while (off <= text.len) : (off += 1) {
        const line = li.lineOf(off);
        const ls: usize = @intCast(li.lineStart(line));
        try std.testing.expectEqual(@as(u64, line), t.lineOf(off));
        const p = t.offsetToPoint(off);
        try std.testing.expectEqual(@as(u64, line), p.line);
        try std.testing.expectEqual(@as(u32, @intCast(off - ls)), p.col);
        const u = t.offsetToUtf16(off);
        const want_col = zg_core.utf8.byteToColumn(text[ls..], off - ls, .utf16);
        try std.testing.expectEqual(want_col, u.col);
        if (off < text.len) try std.testing.expectEqual(text[off], t.byteAt(off));
    }
    // utf16ToOffset against columnToByte on each line's content.
    for (0..li.lineCount()) |line| {
        const r = t.lineRange(line);
        const content = text[@intCast(r.start)..@intCast(r.end)];
        var col: u32 = 0;
        while (col <= content.len + 2) : (col += 1) {
            const want = r.start + zg_core.utf8.columnToByte(content, col, .utf16);
            try std.testing.expectEqual(want, t.utf16ToOffset(.{ .line = line, .col = col }));
        }
        try std.testing.expectEqual(r.start + @min(3, content.len), t.pointToOffset(.{ .line = line, .col = 3 }));
    }
}

const alphabet = [_]u8{ 'a', 'b', '\n', '\r', 0xC3, 0xA9, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80, 0xFF };

/// A source of random choices (std.Random or a fuzz Smith).
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

/// Random edits applied to the tree and the model; every version is kept
/// and re-verified at the end (persistence).
fn runModel(src: anytype, ops: usize, full_queries: bool) !void {
    var initial_buf: [600]u8 = undefined;
    const initial = randomText(src, &initial_buf);
    var env = try Env.init(initial);
    defer env.deinit();
    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(gpa);
    try model.appendSlice(gpa, initial);
    var t = try PieceTree.fromOriginal(&env.pool, env.bt);
    var versions: std.ArrayList(struct { tree: PieceTree, text: []u8 }) = .empty;
    defer {
        for (versions.items) |*v| {
            v.tree.deinit(&env.pool);
            gpa.free(v.text);
        }
        versions.deinit(gpa);
    }
    var text_buf: [40]u8 = undefined;
    for (0..ops) |_| {
        try versions.append(gpa, .{ .tree = t, .text = try gpa.dupe(u8, model.items) });
        const kind = src.pick(4);
        var next: PieceTree = undefined;
        switch (kind) {
            0 => {
                const at = src.pick(model.items.len + 1);
                const text = randomText(src, &text_buf);
                next = try t.insert(&env.pool, at, text);
                try model.insertSlice(gpa, at, text);
            },
            1 => {
                const a = src.pick(model.items.len + 1);
                const b = a + src.pick(model.items.len - a + 1);
                next = try t.delete(&env.pool, .{ .start = a, .end = b });
                try model.replaceRange(gpa, a, b - a, "");
            },
            2 => {
                // Typing: consecutive inserts at one point.
                var at = src.pick(model.items.len + 1);
                next = t.clone();
                for (0..src.pick(6) + 1) |_| {
                    const ch = [1]u8{alphabet[src.pick(alphabet.len)]};
                    const n2 = try next.insert(&env.pool, at, &ch);
                    next.deinit(&env.pool);
                    next = n2;
                    try model.insert(gpa, at, ch[0]);
                    at += 1;
                }
            },
            else => {
                // Multi-edit replace.
                var edits: [8]pt.Edit = undefined;
                var texts: [8][8]u8 = undefined;
                var ne: usize = 0;
                var pos: usize = 0;
                while (ne < edits.len and pos <= model.items.len) : (ne += 1) {
                    const a = pos + src.pick(@min(model.items.len - pos, 50) + 1);
                    const b = a + src.pick(@min(model.items.len - a, 10) + 1);
                    const tl = randomText(src, &texts[ne]);
                    edits[ne] = .{ .range = .{ .start = a, .end = b }, .text = tl };
                    pos = b + 1;
                    if (src.pick(3) == 0) break;
                }
                next = try t.replace(&env.pool, edits[0..ne]);
                var i = ne;
                while (i > 0) {
                    i -= 1;
                    const e = edits[i];
                    try model.replaceRange(gpa, @intCast(e.range.start), @intCast(e.range.len()), e.text);
                }
            },
        }
        t = next;
        try t.check();
        expectText(t, model.items) catch |e| {
            std.debug.print("op kind {d} failed\n", .{kind});
            return e;
        };
    }
    if (full_queries) expectQueries(t, model.items) catch |e| {
        std.debug.print("queries failed\n", .{});
        return e;
    } else {
        try std.testing.expectEqual(@as(u64, model.items.len), t.len());
    }
    // Every old version is unchanged.
    for (versions.items, 0..) |v, vi| expectText(v.tree, v.text) catch |e| {
        std.debug.print("old version {d} of {d} changed\n", .{ vi, versions.items.len });
        return e;
    };
    t.deinit(&env.pool);
}

test "piece_tree: empty/insert/delete basics" {
    var env = try Env.init("");
    defer env.deinit();
    var t0 = try PieceTree.fromOriginal(&env.pool, env.bt);
    defer t0.deinit(&env.pool);
    try std.testing.expectEqual(@as(u64, 0), t0.len());
    try std.testing.expectEqual(@as(u64, 1), t0.lineCount());
    var t1 = try t0.insert(&env.pool, 0, "hello\nworld");
    defer t1.deinit(&env.pool);
    var t2 = try t1.insert(&env.pool, 5, ",");
    defer t2.deinit(&env.pool);
    var t3 = try t2.delete(&env.pool, .{ .start = 0, .end = 2 });
    defer t3.deinit(&env.pool);
    try expectText(t1, "hello\nworld");
    try expectText(t2, "hello,\nworld");
    try expectText(t3, "llo,\nworld");
    try std.testing.expectEqual(@as(u64, 2), t3.lineCount());
    try std.testing.expectEqual(pt.Point{ .line = 1, .col = 2 }, t3.offsetToPoint(7));
    try std.testing.expectEqual(@as(u64, 7), t3.pointToOffset(.{ .line = 1, .col = 2 }));
    try expectQueries(t3, "llo,\nworld");
}

test "piece_tree: crlf straddling pieces counts one line" {
    var env = try Env.init("ab\ncd");
    defer env.deinit();
    var t0 = try PieceTree.fromOriginal(&env.pool, env.bt);
    defer t0.deinit(&env.pool);
    var t1 = try t0.insert(&env.pool, 2, "\r");
    defer t1.deinit(&env.pool);
    try expectText(t1, "ab\r\ncd");
    try std.testing.expectEqual(@as(u64, 2), t1.lineCount());
    try std.testing.expectEqual(@as(u64, 4), t1.lineStart(1));
    try std.testing.expectEqual(@as(u64, 0), t1.lineOf(3));
    try expectQueries(t1, "ab\r\ncd");
}

test "piece_tree: utf8 sequence split across pieces counts once in utf16" {
    var env = try Env.init("x\xF0\x9F\x98y");
    defer env.deinit();
    var t0 = try PieceTree.fromOriginal(&env.pool, env.bt);
    defer t0.deinit(&env.pool);
    var t1 = try t0.insert(&env.pool, 4, "\x80");
    defer t1.deinit(&env.pool);
    try std.testing.expectEqual(@as(u32, 3), t1.offsetToUtf16(5).col);
    try std.testing.expectEqual(@as(u32, 1), t1.offsetToUtf16(3).col);
    try expectQueries(t1, "x😀y");
}

test "piece_tree: large original builds a balanced tree" {
    const big = try gpa.alloc(u8, 3 << 20);
    defer gpa.free(big);
    for (big, 0..) |*c, i| c.* = if (i % 61 == 60) '\n' else 'a' + @as(u8, @intCast(i % 26));
    var env = try Env.init(big);
    defer env.deinit();
    var t = try PieceTree.fromOriginal(&env.pool, env.bt);
    defer t.deinit(&env.pool);
    try t.check();
    try std.testing.expectEqual(@as(u64, big.len / 61 + 1), t.lineCount());
    try std.testing.expectEqual(@as(u64, 61 * 1000), t.lineStart(1000));
    try std.testing.expectEqual(pt.Point{ .line = 1000, .col = 5 }, t.offsetToPoint(61 * 1000 + 5));
}

test "piece_tree: old versions unchanged after edits" {
    var prng: std.Random.DefaultPrng = .init(21);
    var src: Source(std.Random) = .{ .inner = prng.random() };
    for (0..30) |_| try runModel(&src, 60, true);
}

test "piece_tree: replace with many sorted edits equals sequential application" {
    const n = 10_000;
    const base = try gpa.alloc(u8, n * 4);
    defer gpa.free(base);
    for (base, 0..) |*c, i| c.* = if (i % 40 == 39) '\n' else 'x';
    var env = try Env.init(base);
    defer env.deinit();
    var t = try PieceTree.fromOriginal(&env.pool, env.bt);
    defer t.deinit(&env.pool);
    const edits = try gpa.alloc(pt.Edit, n);
    defer gpa.free(edits);
    for (edits, 0..) |*e, i| e.* = .{ .range = .{ .start = i * 4 + 1, .end = i * 4 + 2 }, .text = "YZ" };
    var r = try t.replace(&env.pool, edits);
    defer r.deinit(&env.pool);
    try r.check();
    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(gpa);
    for (0..n) |i| {
        try model.append(gpa, base[i * 4]);
        try model.appendSlice(gpa, "YZ");
        try model.appendSlice(gpa, base[i * 4 + 2 .. i * 4 + 4]);
    }
    try expectText(r, model.items);
    try std.testing.expectError(error.Overlap, t.replace(&env.pool, &.{
        .{ .range = .{ .start = 0, .end = 5 }, .text = "" },
        .{ .range = .{ .start = 3, .end = 6 }, .text = "" },
    }));
}

test "piece_tree: chunk iterators forward/backward reproduce text" {
    var prng: std.Random.DefaultPrng = .init(22);
    const r = prng.random();
    const big = try gpa.alloc(u8, 100_000);
    defer gpa.free(big);
    r.bytes(big);
    var env = try Env.init(big);
    defer env.deinit();
    var t = try PieceTree.fromOriginal(&env.pool, env.bt);
    defer t.deinit(&env.pool);
    for (0..50) |_| {
        const at = r.uintLessThan(u64, t.len() + 1);
        const t2 = try t.insert(&env.pool, at, "inserted text");
        t.deinit(&env.pool);
        t = t2;
    }
    const all = try t.copyRange(gpa, .{ .start = 0, .end = t.len() });
    defer gpa.free(all);
    for (0..100) |_| {
        const a = r.uintLessThan(u64, t.len() + 1);
        const b = a + r.uintLessThan(u64, t.len() - a + 1);
        var it = t.slice(.{ .start = a, .end = b });
        var pos = a;
        while (it.next()) |ch| {
            try std.testing.expectEqualSlices(u8, all[@intCast(pos)..][0..ch.len], ch);
            pos += ch.len;
        }
        try std.testing.expectEqual(b, pos);
        var rit = t.chunksRev(b);
        var end = b;
        while (rit.next()) |ch| {
            try std.testing.expectEqualSlices(u8, all[@intCast(end - ch.len)..@intCast(end)], ch);
            end -= ch.len;
        }
        try std.testing.expectEqual(@as(u64, 0), end);
    }
}

test "piece_tree: queries and iterators do not allocate" {
    var env = try Env.init("line one\r\nline two\nthree é😀");
    defer env.deinit();
    var t = try PieceTree.fromOriginal(&env.pool, env.bt);
    defer t.deinit(&env.pool);
    const t2 = try t.insert(&env.pool, 4, "XYZ");
    t.deinit(&env.pool);
    t = t2;
    // Queries take no allocator; this checks they stay that way and work
    // with the pool's allocator failing.
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    const saved = env.pool.gpa;
    env.pool.gpa = failing.allocator();
    defer env.pool.gpa = saved;
    _ = t.offsetToPoint(20);
    _ = t.offsetToUtf16(30);
    _ = t.utf16ToOffset(.{ .line = 2, .col = 7 });
    var it = t.chunks(0);
    while (it.next()) |_| {}
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "fuzz: piece_tree vs naive" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var src: Source(*std.testing.Smith) = .{ .inner = s };
            try runModel(&src, 30, true);
        }
    }.one, .{});
}
