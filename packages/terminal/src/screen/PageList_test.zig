//! PageList tests: growth across pages, eviction, pins, viewport, erase
//! scrollback and resize.

const std = @import("std");
const testing = std.testing;
const PageList = @import("PageList.zig");
const Page = @import("Page.zig");

test "grow beyond page capacity links pages; totalRows correct" {
    var pl: PageList = try .init(testing.allocator, 80, 24, .{});
    defer pl.deinit();
    const cap = Page.layoutFor(80, Page.bytesFor(80)).rows_cap;
    for (0..cap * 3) |_| _ = try pl.grow();
    try testing.expectEqual(@as(u64, 24 + cap * 3), pl.totalRows());
    try testing.expect(pl.nodes >= 4);
    try pl.verify();
    // Active rows are the last 24.
    const last = pl.activeRow(23);
    try testing.expect(last.node == pl.tail);
    try testing.expectEqual(pl.tail.page.rowCount() - 1, last.y);
    try testing.expectEqual(pl.totalRows() - 1, pl.rowIndex(last));
}

test "eviction at max_bytes marks pins garbage" {
    var pl: PageList = try .init(testing.allocator, 80, 24, .{ .max_bytes = 3 * Page.default_bytes });
    defer pl.deinit();
    const t = try pl.track(pl.activeRow(0));
    const cap = Page.layoutFor(80, Page.bytesFor(80)).rows_cap;
    for (0..cap * 10) |_| _ = try pl.grow();
    try testing.expect(pl.bytesUsed() <= 3 * Page.default_bytes);
    try testing.expect(t.garbage);
    try testing.expect(pl.evicted > 0);
    try testing.expectEqual(pl.totalRows() + pl.evicted, 24 + cap * 10);
    try pl.verify();
}

test "viewport anchored while scrolled back as output arrives" {
    var pl: PageList = try .init(testing.allocator, 10, 5, .{});
    defer pl.deinit();
    for (0..100) |i| {
        const p = try pl.grow();
        p.cells()[0].content = @intCast('0' + i % 10);
    }
    try pl.scrollViewport(10);
    const top_before = pl.viewportRow(0);
    const ch = top_before.cells()[0].content;
    for (0..20) |_| _ = try pl.grow();
    try testing.expectEqual(ch, pl.viewportRow(0).cells()[0].content);
    try pl.scrollViewport(-1000);
    try testing.expect(pl.viewport == null);
}

test "erase scrollback keeps the active area" {
    var pl: PageList = try .init(testing.allocator, 10, 3, .{});
    defer pl.deinit();
    for (0..500) |i| {
        const p = try pl.grow();
        p.cells()[0].content = @intCast('a' + i % 26);
    }
    const before = pl.activeRow(2).cells()[0].content;
    const t = try pl.track(pl.activeRow(1));
    const old = try pl.track(pl.screenRow(0).?);
    try pl.eraseScrollback();
    try testing.expectEqual(@as(u64, 3), pl.totalRows());
    try testing.expectEqual(before, pl.activeRow(2).cells()[0].content);
    try testing.expect(!t.garbage and t.pin.y == pl.activeRow(1).y and t.pin.node == pl.activeRow(1).node);
    try testing.expect(old.garbage);
    try pl.verify();
}

test "resize truncates and pads rows, pins follow" {
    var pl: PageList = try .init(testing.allocator, 20, 4, .{});
    defer pl.deinit();
    for (0..4) |y| {
        const cs = pl.activeRow(@intCast(y)).cells();
        for (cs, 0..) |*c, x| c.content = @intCast('a' + (x + y) % 26);
    }
    const t = try pl.track(pl.activeRow(2));
    try pl.resize(5, 6);
    try testing.expectEqual(@as(u16, 5), pl.cols);
    try testing.expectEqual(@as(u64, 6), pl.totalRows());
    try testing.expectEqual(@as(u21, 'c'), t.pin.cells()[0].codepoint());
    try pl.resize(30, 2);
    try testing.expectEqual(@as(u21, 'c'), t.pin.cells()[0].codepoint());
    try pl.verify();
}
