//! Cold scrollback in the page list: compaction past `hot_rows`, stable
//! row indices, decoding when the viewport scrolls back, the byte cap,
//! pins, resize and ED 3.

const std = @import("std");
const testing = std.testing;
const Terminal = @import("../term/Terminal.zig");
const PageList = @import("PageList.zig");
const Screen = @import("Screen.zig");

fn feedLines(t: *Terminal, from: usize, to: usize) void {
    var buf: [64]u8 = undefined;
    for (from..to) |i| t.feed(std.fmt.bufPrint(&buf, "line {d} \x1b[1mbold\x1b[0m\r\n", .{i}) catch unreachable);
}

/// The text of absolute row `r`, decoding cold scrollback as needed (the
/// viewport moves there).
fn rowAt(pl: *PageList, r: u64, out: *std.ArrayList(u8)) !void {
    const cur: i64 = @intCast(if (pl.viewport) |v| pl.rowIndex(v.pin) else pl.scrollbackRows());
    try pl.scrollViewport(cur - @as(i64, @intCast(r)));
    out.clearRetainingCapacity();
    try Screen.pinText(pl.viewportRow(0), out, testing.allocator);
}

test "old scrollback compacts into cold pages with stable row indices" {
    inline for (.{ false, true }) |deflate| try compactsAndDecodes(deflate);
}

fn compactsAndDecodes(deflate: bool) !void {
    var t = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50, .deflate_scrollback = deflate });
    defer t.deinit();
    feedLines(&t, 0, 3000);
    const pl = &t.primary.pages;
    try pl.verify();
    try testing.expect(pl.coldRows() > 2000);
    // At most `hot_rows` plus two pages stay hot.
    try testing.expect(pl.scrollbackRows() - pl.coldRows() < 50 + 2 * @as(u64, pl.head.page.layout.rows_cap));
    // Every line plus the cursor's row.
    try testing.expectEqual(@as(u64, 3000 + 1), pl.totalRows());
    try testing.expectEqual(@as(u64, 0), pl.evicted);
    // Cold rows are not addressable as pins.
    try testing.expect(pl.screenRow(0) == null);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try rowAt(pl, 0, &text);
    try testing.expectEqualStrings("line 0 bold", text.items);
    try pl.verify();
    try rowAt(pl, 1234, &text);
    try testing.expectEqualStrings("line 1234 bold", text.items);
    // The last scrollback row (the active area starts below it).
    try rowAt(pl, 2995, &text);
    try testing.expectEqualStrings("line 2995 bold", text.items);
    try pl.verify();
    // Styles survive the round trip.
    try rowAt(pl, 7, &text);
    const p = pl.viewportRow(0);
    try testing.expect(p.node.page.styleOf(p.cells()[7]).flags.bold);
}

test "the viewport keeps its rows hot; leaving it lets them compact again" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50 });
    defer t.deinit();
    feedLines(&t, 0, 2000);
    const pl = &t.primary.pages;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try rowAt(pl, 10, &text);
    const cold_while_viewing = pl.coldRows();
    try testing.expect(cold_while_viewing < 10 + 1);
    // Output while scrolled back keeps the viewport where it is.
    feedLines(&t, 2000, 2500);
    try pl.verify();
    try testing.expectEqual(@as(u64, 10), pl.rowIndex(pl.viewport.?.pin));
    try Screen.pinText(pl.viewportRow(0), &text, testing.allocator);
    // Back to the bottom: the next output compacts the old rows again.
    try pl.scrollViewport(-1_000_000);
    feedLines(&t, 2500, 2501);
    try testing.expect(pl.scrollbackRows() - pl.coldRows() < 50 + 2 * @as(u64, pl.head.page.layout.rows_cap));
    try pl.verify();
}

test "cold scrollback is far smaller than hot pages" {
    var hot = try Terminal.init(testing.allocator, .{ .cols = 80, .rows = 24, .hot_scrollback_rows = 0 });
    defer hot.deinit();
    var cold = try Terminal.init(testing.allocator, .{ .cols = 80, .rows = 24, .hot_scrollback_rows = 1000 });
    defer cold.deinit();
    var buf: [32]u8 = undefined;
    for (0..50_000) |i| {
        const line = std.fmt.bufPrint(&buf, "{d}\r\n", .{i}) catch unreachable;
        hot.feed(line);
        cold.feed(line);
    }
    const hb = hot.primary.pages.bytesUsed();
    const cb = cold.primary.pages.bytesUsed();
    try testing.expect(cb * 4 < hb);
    try testing.expectEqual(hot.primary.pages.totalRows(), cold.primary.pages.totalRows());
}

test "the byte cap evicts cold pages first" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50, .max_scrollback_bytes = 1 << 20 });
    defer t.deinit();
    feedLines(&t, 0, 200_000);
    const pl = &t.primary.pages;
    try pl.verify();
    try testing.expect(pl.bytesUsed() <= 1 << 20);
    try testing.expect(pl.evicted > 0);
    try testing.expectEqual(@as(u64, 200_000 + 1), pl.totalRows() + pl.evicted);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try rowAt(pl, 0, &text);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "line {d} bold", .{pl.evicted}), text.items);
}

test "pins into compacted rows are garbage while cold and return when decoded" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50 });
    defer t.deinit();
    const pl = &t.primary.pages;
    var start = pl.activeRow(0);
    start.x = 5;
    const pin = try pl.track(start);
    defer pl.untrack(pin);
    feedLines(&t, 0, 2000);
    try testing.expect(pin.garbage);
    try testing.expect(pin.cold != null);
    // Scrolling back to it decodes the page and restores the pin.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try rowAt(pl, 0, &text);
    try testing.expect(!pin.garbage);
    try testing.expectEqual(@as(?PageList.ColdPos, null), pin.cold);
    try testing.expectEqual(@as(u64, 0), pl.rowIndex(pin.pin));
    try testing.expectEqual(@as(u16, 5), pin.pin.x);
    try pl.verify();
}

test "a cold pin keeps its place in a wrapped line across a resize" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50 });
    defer t.deinit();
    const pl = &t.primary.pages;
    var buf: [64]u8 = undefined;
    t.feed("line zero\r\n");
    // Line 1 is 30 cells; pin its 26th cell ('Z').
    t.feed("abcdefghijklmnopqrstuvwxyZ0123\r\n");
    var p = pl.screenRow(1).?;
    p.x = 25;
    const pin = try pl.track(p);
    defer pl.untrack(pin);
    for (0..1000) |i| t.feed(std.fmt.bufPrint(&buf, "{d}\r\n", .{i}) catch unreachable);
    try testing.expect(pin.cold != null);
    try t.resize(20, 5);
    try testing.expect(pin.cold != null);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try rowAt(pl, 0, &text);
    try testing.expect(!pin.garbage);
    // At 20 columns line 1 takes rows 1 and 2; cell 25 is row 2, column 5.
    try testing.expectEqual(@as(u64, 2), pl.rowIndex(pin.pin));
    try testing.expectEqual(@as(u16, 5), pin.pin.x);
    try testing.expectEqual(@as(u21, 'Z'), pin.pin.cells()[5].codepoint());
}

test "evicting a cold page drops its pins' positions" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50, .max_scrollback_bytes = 1 << 20 });
    defer t.deinit();
    const pl = &t.primary.pages;
    const pin = try pl.track(pl.activeRow(0));
    defer pl.untrack(pin);
    feedLines(&t, 0, 200_000);
    try testing.expect(pl.evicted > 0);
    try testing.expect(pin.garbage);
    try testing.expectEqual(@as(?PageList.ColdPos, null), pin.cold);
}

test "resize recounts cold rows; decoding re-wraps them at the new width" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50 });
    defer t.deinit();
    var buf: [64]u8 = undefined;
    // 30-cell lines: one row at 40 columns, two at 20.
    for (0..1000) |i| t.feed(std.fmt.bufPrint(&buf, "{d:0>30}\r\n", .{i}) catch unreachable);
    const pl = &t.primary.pages;
    const cold_at_40 = pl.coldRows();
    try testing.expect(cold_at_40 > 500);
    try t.resize(20, 5);
    try pl.verify();
    try testing.expectEqual(cold_at_40 * 2, pl.coldRows());
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try rowAt(pl, 0, &text);
    try testing.expectEqualStrings("00000000000000000000", text.items);
    try rowAt(pl, 1, &text);
    try testing.expectEqualStrings("0000000000", text.items);
    try rowAt(pl, 3, &text);
    try testing.expectEqualStrings("0000000001", text.items);
    try pl.verify();
}

test "ED 3 drops cold scrollback" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50 });
    defer t.deinit();
    feedLines(&t, 0, 2000);
    t.feed("\x1b[3J");
    const pl = &t.primary.pages;
    try pl.verify();
    try testing.expectEqual(@as(u64, 0), pl.coldRows());
    try testing.expectEqual(@as(u64, 0), pl.scrollbackRows());
}

test "decoded pages keep their encoding and compact again without encoding" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50 });
    defer t.deinit();
    feedLines(&t, 0, 2000);
    const pl = &t.primary.pages;
    const cold_before = pl.cold_nodes.items.len;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    // Decode the two newest cold pages.
    const second = pl.coldRows() - pl.cold_nodes.items[cold_before - 1].rows - 1;
    try rowAt(pl, second, &text);
    try testing.expectEqual(@as(usize, 2), pl.thawed.items.len);
    try testing.expect(pl.thawed_bytes > 0);
    try pl.verify();
    // Leaving them lets the next output take them back, reusing the blobs.
    const blob = pl.thawed.items[0].page.blob.ptr;
    try pl.scrollViewport(-1_000_000);
    feedLines(&t, 2000, 2001);
    try pl.verify();
    try testing.expectEqual(@as(usize, 0), pl.thawed.items.len);
    try testing.expectEqual(@as(usize, 0), pl.thawed_bytes);
    try testing.expectEqual(cold_before, pl.cold_nodes.items.len);
    try testing.expectEqual(blob, pl.cold_nodes.items[cold_before - 1].page.blob.ptr);
    try rowAt(pl, second, &text);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "line {d} bold", .{second}), text.items);
}

test "the decode cache keeps at most thaw_cache pages and empties on resize" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50 });
    defer t.deinit();
    feedLines(&t, 0, 20_000);
    const pl = &t.primary.pages;
    try testing.expect(pl.cold_nodes.items.len > PageList.thaw_cache + 2);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try rowAt(pl, 0, &text);
    try testing.expectEqualStrings("line 0 bold", text.items);
    try testing.expectEqual(@as(usize, PageList.thaw_cache), pl.thawed.items.len);
    try pl.verify();
    try t.resize(30, 5);
    try testing.expectEqual(@as(usize, 0), pl.thawed.items.len);
    try pl.verify();
}

test "background compaction swaps rows out and keeps pins" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50, .background_compaction = true });
    defer t.deinit();
    const pl = &t.primary.pages;
    var start = pl.activeRow(0);
    start.x = 3;
    const pin = try pl.track(start);
    defer pl.untrack(pin);
    feedLines(&t, 0, 2000);
    // Nothing compacts until the owner runs the job.
    try testing.expectEqual(@as(u64, 0), pl.coldRows());
    try testing.expect(t.compactionDue());
    while (t.compactionDue()) {
        const job = (try t.beginCompaction()).?;
        // Only one job at a time.
        try testing.expectEqual(@as(?*PageList.CompactJob, null), try t.beginCompaction());
        job.run();
        try t.finishCompaction(job);
    }
    try pl.verify();
    try testing.expect(pl.coldRows() > 1000);
    try testing.expect(pin.garbage and pin.cold != null);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try rowAt(pl, 0, &text);
    try testing.expectEqualStrings("line 0 bold", text.items);
    try testing.expect(!pin.garbage);
    try testing.expectEqual(@as(u16, 3), pin.pin.x);
}

test "a background compaction overtaken by a resize or ED 3 is dropped" {
    inline for (.{ "resize", "ed3" }) |what| {
        var t = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50, .background_compaction = true });
        defer t.deinit();
        const pl = &t.primary.pages;
        feedLines(&t, 0, 3000);
        const job = (try t.beginCompaction()).?;
        job.run();
        if (comptime std.mem.eql(u8, what, "resize")) try t.resize(30, 5) else t.feed("\x1b[3J");
        try t.finishCompaction(job);
        try pl.verify();
        try testing.expectEqual(@as(u64, 0), pl.coldRows());
        try testing.expect(!pl.job_out);
    }
}

test "a background compaction is dropped when the viewport moved into its rows" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50, .background_compaction = true });
    defer t.deinit();
    const pl = &t.primary.pages;
    feedLines(&t, 0, 3000);
    const job = (try t.beginCompaction()).?;
    job.run();
    try pl.scrollViewport(1_000_000);
    try t.finishCompaction(job);
    try pl.verify();
    try testing.expectEqual(@as(u64, 0), pl.coldRows());
}

test "cancelling a background compaction frees it" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50, .background_compaction = true, .deflate_scrollback = true });
    defer t.deinit();
    feedLines(&t, 0, 3000);
    const job = (try t.beginCompaction()).?;
    job.run();
    try testing.expect(job.result != null);
    t.cancelCompaction(job);
    try testing.expect(!t.primary.pages.job_out);
}
