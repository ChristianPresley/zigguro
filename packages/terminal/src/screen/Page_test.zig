//! Page tests: layout, style/grapheme/link tables, cloning and the
//! `page_ops` fuzz target.

const std = @import("std");
const testing = std.testing;
const zg_core = @import("zg_core");
const Page = @import("Page.zig");
const Cell = Page.Cell;

test "layoutFor cols 1..4096 fits page and rows_cap ≥ 1" {
    var cols: u32 = 1;
    while (cols <= 4096) : (cols += if (cols < 300) 1 else 37) {
        const c: u16 = @intCast(cols);
        const l = Page.layoutFor(c, Page.bytesFor(c));
        try testing.expect(l.rows_cap >= 1);
        try testing.expect(l.total <= Page.bytesFor(c));
        try testing.expect(l.cells_off % 8 == 0 and l.styles_off % 4 == 0 and l.graph_map_off % 4 == 0);
    }
    const l = Page.layoutFor(200, Page.default_bytes);
    try testing.expect(l.rows_cap >= 120); // cells are ≥ 75% of the page
}

fn newPage(pool: *Page.PagePool, cols: u16) !Page {
    return Page.init(try pool.alloc(Page.bytesFor(cols)), cols);
}

test "styles through the page refcount per cell" {
    var pool: Page.PagePool = .init(testing.allocator);
    defer pool.deinit();
    var p = try newPage(&pool, 80);
    defer pool.free(p.buf);
    for (0..1) |_| _ = p.addRow();
    const r = p.row(0);
    const cs = p.cells(r);
    const id = try p.internStyle(.{ .fg = .palette(2) }, 3);
    for (cs[0..3]) |*c| c.* = .{ .content = 'a', .style = id };
    r.styled = true;
    try p.verify(testing.allocator);
    p.clearCells(r, cs[0..2], .blank);
    try p.verify(testing.allocator);
    try testing.expectEqual(@as(u32, 1), p.styleRefs(id));
}

test "GraphemeMap add/remove/reuse across size classes" {
    var pool: Page.PagePool = .init(testing.allocator);
    defer pool.deinit();
    var p = try newPage(&pool, 40);
    defer pool.free(p.buf);
    for (0..1) |_| _ = p.addRow();
    const r = p.row(0);
    r.has_grapheme = true;
    const c = &p.cells(r)[3];
    c.* = .{ .content = 0x1F9D1 };
    for (0..10) |i| try p.appendGrapheme(c, @intCast(0x200D + i));
    try testing.expectEqual(@as(usize, 10), p.grapheme(c).?.len);
    try testing.expectEqual(@as(u21, 0x200D + 9), p.grapheme(c).?[9]);
    try p.verify(testing.allocator);
    const used = p.header().garena.used;
    p.clearCell(c, .blank);
    try testing.expectEqual(@as(u32, 0), p.header().gmap.count);
    // Reuse: the same sequence fits in freed blocks without bumping.
    c.* = .{ .content = 'e' };
    for (0..10) |i| try p.appendGrapheme(c, @intCast(0x300 + i));
    try testing.expectEqual(used, p.header().garena.used);
    for (0..20) |_| try p.appendGrapheme(c, 0x301);
    try testing.expectEqual(@as(usize, 16), p.grapheme(c).?.len);
    try p.verify(testing.allocator);
}

test "HyperlinkMap dedup URIs and refcount" {
    var pool: Page.PagePool = .init(testing.allocator);
    defer pool.deinit();
    var p = try newPage(&pool, 40);
    defer pool.free(p.buf);
    for (0..1) |_| _ = p.addRow();
    const r = p.row(0);
    r.has_hyperlink = true;
    const cs = p.cells(r);
    for (cs[0..5]) |*c| {
        const id = try p.internLink(.{ .uri = "https://ziglang.org" });
        c.content = 'x';
        p.attachLink(c, id);
    }
    const other = try p.internLink(.{ .uri = "https://ziglang.org", .id = "a" });
    p.attachLink(&cs[5], other);
    try testing.expectEqual(p.linkId(&cs[0]).?, p.linkId(&cs[4]).?);
    try testing.expect(p.linkId(&cs[0]).? != p.linkId(&cs[5]).?);
    try testing.expectEqualStrings("https://ziglang.org", p.hyperlinkOf(&cs[2]).?.uri);
    try p.verify(testing.allocator);
    p.clearCells(r, cs[0..6], .blank);
    try testing.expectEqual(@as(u16, 0), p.header().links.live);
    try testing.expectEqual(@as(u32, 0), p.header().links.arena_used);
    try p.verify(testing.allocator);
}

test "cloneInto produces an identical, independently mutable page" {
    var pool: Page.PagePool = .init(testing.allocator);
    defer pool.deinit();
    var p = try newPage(&pool, 100);
    defer pool.free(p.buf);
    for (0..2) |_| _ = p.addRow();
    const r = p.row(1);
    r.styled = true;
    r.has_grapheme = true;
    const c = &p.cells(r)[7];
    c.* = .{ .content = 'e', .style = try p.internStyle(.{ .flags = .{ .bold = true } }, 1) };
    try p.appendGrapheme(c, 0x301);
    var q = try newPage(&pool, 100);
    defer pool.free(q.buf);
    p.cloneInto(&q);
    try q.verify(testing.allocator);
    const qc = &q.cells(q.row(1))[7];
    try testing.expectEqual(@as(u21, 0x301), q.grapheme(qc).?[0]);
    try testing.expect(q.styleOf(qc.*).flags.bold);
    q.clearCell(qc, .blank);
    try q.verify(testing.allocator);
    try testing.expectEqual(@as(u21, 0x301), p.grapheme(c).?[0]);
    try p.verify(testing.allocator);
}

test "moveCell and copyCellFrom carry graphemes, styles and links" {
    var pool: Page.PagePool = .init(testing.allocator);
    defer pool.deinit();
    var p = try newPage(&pool, 30);
    defer pool.free(p.buf);
    var q = try newPage(&pool, 30);
    defer pool.free(q.buf);
    for (0..1) |_| _ = p.addRow();
    for (0..1) |_| _ = q.addRow();
    const r = p.row(0);
    r.* = .{ .cells_off = r.cells_off, .styled = true, .has_grapheme = true, .has_hyperlink = true };
    q.row(0).* = .{ .cells_off = q.row(0).cells_off, .styled = true, .has_grapheme = true, .has_hyperlink = true };
    const cs = p.cells(r);
    cs[0] = .{ .content = 'a', .style = try p.internStyle(.{ .fg = .rgb(1, 2, 3) }, 1) };
    try p.appendGrapheme(&cs[0], 0x301);
    p.attachLink(&cs[0], try p.internLink(.{ .uri = "file:///x" }));
    p.moveCell(&cs[9], &cs[0]);
    try p.verify(testing.allocator);
    try testing.expectEqual(@as(u21, 0x301), p.grapheme(&cs[9]).?[0]);
    const qc = &q.cells(q.row(0))[2];
    q.copyCellFrom(qc, &p, &cs[9]);
    try q.verify(testing.allocator);
    try testing.expectEqualStrings("file:///x", q.hyperlinkOf(qc).?.uri);
    try testing.expectEqual(@as(u8, 1), q.styleOf(qc.*).fg.r);
}

fn fuzzPageOps(_: void, s: *std.testing.Smith) anyerror!void {
    var pool: Page.PagePool = .init(testing.allocator);
    defer pool.deinit();
    var p = try newPage(&pool, 16);
    defer pool.free(p.buf);
    for (0..4) |_| _ = p.addRow();
    for (0..4) |y| {
        const r = p.row(@intCast(y));
        r.styled = true;
        r.has_grapheme = true;
        r.has_hyperlink = true;
    }
    const uris = [_][]const u8{ "a", "bb", "https://c" };
    var n: usize = 0;
    while (!s.eos() and n < 400) : (n += 1) {
        const y: u16 = s.valueRangeAtMost(u16, 0, 3);
        const x: usize = s.valueRangeAtMost(u16, 0, 15);
        const c = &p.cells(p.row(y))[x];
        switch (s.valueRangeAtMost(u8, 0, 4)) {
            0 => {
                p.clearCell(c, .blank);
                const id = p.internStyle(.{ .fg = .palette(s.valueRangeAtMost(u8, 0, 40)) }, 1) catch continue;
                c.* = .{ .content = 'x', .style = id };
            },
            1 => {
                if (c.isEmpty()) c.content = 'e';
                p.appendGrapheme(c, 0x300 + @as(u21, s.valueRangeAtMost(u8, 0, 50))) catch {};
            },
            2 => {
                p.clearLink(c);
                const id = p.internLink(.{ .uri = uris[s.valueRangeAtMost(u8, 0, 2)] }) catch continue;
                p.attachLink(c, id);
            },
            3 => p.clearCell(c, .blank),
            else => {
                const x2: usize = s.valueRangeAtMost(u16, 0, 15);
                const d = &p.cells(p.row(y))[x2];
                if (d != c) {
                    p.clearCell(d, .blank);
                    p.moveCell(d, c);
                }
            },
        }
        try p.verify(testing.allocator);
    }
}

test "fuzz: page_ops" {
    try std.testing.fuzz({}, fuzzPageOps, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "page_ops") });
}
