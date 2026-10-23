//! The data grid in a headless window: a 20-column dataset's first
//! screen, then the palette commands (sort, filter, copy, Chart this, row
//! detail, profile) with the clipboard and chart ports captured.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const grid = @import("grid.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestApp = zg_gui.testing.TestApp;
const Dataset = zg_agents.data.Dataset;

const Host = struct {
    g: ?*grid.DataGrid = null,

    pub fn build(h: *Host, ui: *zg_gui.Ui) void {
        if (h.g) |g| grid.dataGrid(ui, g);
    }
};

/// What the ports received.
const Captured = struct {
    clipboard: std.ArrayListUnmanaged(u8) = .empty,
    chart: std.ArrayListUnmanaged(u8) = .empty,
    as_text: u32 = 0,

    fn setClipboard(ctx: *anyopaque, text: []const u8) void {
        const c: *Captured = @ptrCast(@alignCast(ctx));
        c.clipboard.clearRetainingCapacity();
        c.clipboard.appendSlice(gpa, text) catch {};
    }

    fn createChart(ctx: *anyopaque, spec: []const u8) void {
        const c: *Captured = @ptrCast(@alignCast(ctx));
        c.chart.clearRetainingCapacity();
        c.chart.appendSlice(gpa, spec) catch {};
    }

    fn openAsText(ctx: *anyopaque) void {
        const c: *Captured = @ptrCast(@alignCast(ctx));
        c.as_text += 1;
    }

    fn deinit(c: *Captured) void {
        c.clipboard.deinit(gpa);
        c.chart.deinit(gpa);
    }
};

/// 40 rows of 20 columns: id, name, amount, day, then c4..c19.
fn wideCsv() ![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    try w.writer.writeAll("id,name,amount,day");
    for (4..20) |c| try w.writer.print(",c{d}", .{c});
    try w.writer.writeByte('\n');
    for (0..40) |i| {
        try w.writer.print("{d},{s},{d}.5,2025-01-{d:0>2}", .{ i, if (i % 7 == 3) "" else if (i % 2 == 0) "alpha" else "beta", (i * 37) % 100, 1 + i % 28 });
        for (4..20) |c| try w.writer.print(",v{d}_{d}", .{ c, i });
        try w.writer.writeByte('\n');
    }
    return w.toOwnedSlice();
}

const Fx = struct {
    host: Host = .{},
    cap: Captured = .{},
    bytes: []u8 = &.{},
    ds: *Dataset = undefined,
    t: *TestApp = undefined,
    g: *grid.DataGrid = undefined,

    fn init(f: *Fx) !void {
        f.* = .{};
        f.bytes = try wideCsv();
        f.ds = try Dataset.openBytes(gpa, io, f.bytes, .csv);
        try f.ds.waitIndexed();
        f.t = try TestApp.init(gpa, .{ .root = .of(&f.host), .size = .{ .w = 1600, .h = 900 } });
        f.g = try grid.DataGrid.init(gpa, io, &f.t.app, f.ds, "data", .{
            .set_clipboard = .{ .ctx = &f.cap, .f = Captured.setClipboard },
            .create_chart = .{ .ctx = &f.cap, .f = Captured.createChart },
            .open_as_text = .{ .ctx = &f.cap, .f = Captured.openAsText },
        });
        f.host.g = f.g;
        f.settle();
    }

    fn deinit(f: *Fx) void {
        f.t.app.joinWork();
        _ = f.t.app.drainMessages();
        f.host.g = null;
        f.g.deinit();
        f.t.deinit();
        f.ds.close();
        gpa.free(f.bytes);
        f.cap.deinit();
    }

    fn settle(f: *Fx) void {
        f.t.win.markAllDirty();
        _ = f.t.settle();
    }

    /// Waits for the grid's query (and the profile) to finish.
    fn waitIdle(f: *Fx) !void {
        var tries: u32 = 0;
        while (f.g.vm.querying() or f.g.profile.computing()) : (tries += 1) {
            if (tries > 20_000) return error.Timeout;
            io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        f.settle();
    }

    fn sem(f: *Fx) ![]u8 {
        return f.t.semanticsSnapshot(gpa);
    }

    /// Makes view column `col` active (index + 1 for the gutter).
    fn activate(f: *Fx, row: u64, col: u32) void {
        f.g.table.moveTo(row, col + 1, .replace);
    }

    fn run(f: *Fx, id: []const u8) !void {
        try testing.expect(f.g.runCommand(id));
        try f.waitIdle();
    }
};

fn expectHas(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("missing {s} in\n{s}\n", .{ needle, hay });
        return error.TestUnexpectedResult;
    }
}

test "a 20-column dataset's first screen" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try testing.expectEqual(21, f.g.table.columns().len);
    const s = try f.sem();
    defer gpa.free(s);
    try expectHas(s, "\"40 rows\"");
    try expectHas(s, "\"Data\"");
    try expectHas(s, "Click a header to sort");
    // Numbers align right, the gutter is frozen, widths come from a sample.
    const cols = f.g.table.columns();
    try testing.expect(cols[0].frozen);
    try testing.expectEqual(.end, cols[3].align_);
    try testing.expectEqual(.start, cols[2].align_);
    for (cols[1..]) |c| try testing.expect(c.width >= 56 and c.width <= 320);
    try testing.expectEqualStrings("alpha", f.g.vm.cellText(0, 1));
    try testing.expectEqualStrings("37.5", f.g.vm.cellText(1, 2));
    try testing.expect(f.g.vm.isNull(3, 1));
    try testing.expect(!f.g.runCommand("data.nope"));
}

test "sort and filter from the palette" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.activate(0, 2);
    try f.run("data.sortDescending");
    try testing.expectEqualStrings("99.5", f.g.vm.cellText(0, 2));
    {
        const s = try f.sem();
        defer gpa.free(s);
        try expectHas(s, "Sorted by amount ↓");
    }
    try f.run("data.clearSort");
    try testing.expectEqualStrings("0.5", f.g.vm.cellText(0, 2));

    // Equals on name opens the chip editor; applying it filters.
    f.activate(0, 1);
    try f.run("data.filterEquals");
    try testing.expect(f.g.bar.editing != null);
    try f.g.bar.a.replace(.{ 0, 0 }, "beta");
    try f.g.bar.applyChip(f.g.vm);
    try f.waitIdle();
    for (0..f.g.vm.rowCount()) |r| try testing.expectEqualStrings("beta", f.g.vm.cellText(r, 1));
    {
        const s = try f.sem();
        defer gpa.free(s);
        try expectHas(s, "name = beta");
    }
    // Empty values need no editor.
    try f.run("data.clearFilters");
    f.activate(0, 1);
    try f.run("data.filterEmpty");
    try testing.expectEqual(@as(u64, 6), f.g.vm.rowCount());

    // Advanced mode starts from the simple query; a bad one says why.
    try f.run("data.advancedQuery");
    try testing.expectEqualStrings("from data | where name is null", f.g.bar.query.slice());
    try f.g.vm.setView("from data | where nope > 1");
    f.settle();
    try testing.expect(f.t.find(.{ .test_id = "data-query-error" }) != null);
    try f.run("data.simpleQuery");
    try testing.expectEqual(null, f.g.vm.query_error);
    try testing.expectEqual(@as(u64, 6), f.g.vm.rowCount());
}

test "copy, chart this, row detail, profile and open as text" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();

    // Two rows of the picked columns as TSV, then as Markdown.
    f.activate(1, 0);
    try f.run("data.selectColumn");
    f.activate(1, 2);
    try f.run("data.selectColumn");
    f.g.table.moveTo(2, 3, .extend);
    try f.run("data.copyTsv");
    try testing.expectEqualStrings("id\tamount\n1\t37.5\n2\t74.5\n", f.cap.clipboard.items);
    try f.run("data.copyMarkdown");
    try expectHas(f.cap.clipboard.items, "| id | amount |");
    {
        const s = try f.sem();
        defer gpa.free(s);
        try expectHas(s, "Copied 2 rows as Markdown.");
        try expectHas(s, "Columns picked: id, amount");
    }

    // Two numbers chart as a scatter of the file.
    try f.run("data.chartThis");
    try expectHas(f.cap.chart.items, "\"mark\":\"point\"");
    // A category and a number: bars of the sum.
    f.g.picked.clearRetainingCapacity();
    f.activate(0, 1);
    try f.run("data.selectColumn");
    f.activate(0, 2);
    try f.run("data.selectColumn");
    try f.run("data.chartThis");
    try expectHas(f.cap.chart.items, "\"mark\":\"bar\"");
    f.g.picked.clearRetainingCapacity();
    // Text that is not a category cannot chart.
    f.activate(0, 5);
    try f.run("data.chartThis");
    try testing.expectEqualStrings(@import("chart_this.zig").hint, f.g.notice.?);

    // The active row's detail, and closing it again.
    f.activate(4, 0);
    try f.run("data.rowDetail");
    try testing.expectEqual(@as(?u64, 4), f.g.detail.row);
    {
        const s = try f.sem();
        defer gpa.free(s);
        try expectHas(s, "\"Row detail\"");
        try expectHas(s, "v19_4");
    }
    try f.run("data.rowDetail");
    try testing.expectEqual(null, f.g.detail.row);

    // The profile of the amount column.
    f.activate(0, 2);
    try f.run("data.toggleProfile");
    try f.waitIdle();
    try testing.expect(f.g.profile.stats() != null);
    try testing.expectEqual(@as(u64, 40), f.g.profile.stats().?.count);
    {
        const s = try f.sem();
        defer gpa.free(s);
        try expectHas(s, "\"Column profile\"");
        try expectHas(s, "Histogram");
    }
    try f.run("data.toggleProfile");
    try testing.expect(!f.g.show_profile);

    try f.run("data.pinFirstColumn");
    try testing.expect(f.g.table.columns()[1].frozen);
    try f.run("data.openAsText");
    try testing.expectEqual(1, f.cap.as_text);
}
