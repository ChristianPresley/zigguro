//! Table (E04.F04.S02.T03).

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const table_mod = @import("table.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const Ui = ui_mod.Ui;
const Table = table_mod.Table;
const Column = table_mod.Column;
const TableSource = table_mod.TableSource;
const Sort = table_mod.Sort;
const testing = std.testing;

/// `rows` rows; cell (r, c) reads "r<r>c<c>", or `long` in column 9.
const Grid = struct {
    rows: u64,
    long: []const u8 = "",
    bufs: [64][32]u8 = undefined,
    next: usize = 0,

    fn rowCount(p: *anyopaque) u64 {
        const g: *Grid = @ptrCast(@alignCast(p));
        return g.rows;
    }
    fn cellText(p: *anyopaque, row: u64, col: u32) []const u8 {
        const g: *Grid = @ptrCast(@alignCast(p));
        if (col == 9 and g.long.len > 0) return g.long;
        const b = &g.bufs[g.next];
        g.next = (g.next + 1) % g.bufs.len;
        return std.fmt.bufPrint(b, "r{d}c{d}", .{ row, col }) catch "";
    }
    const vt: TableSource.VTable = .{ .row_count = rowCount, .cell_text = cellText };

    fn source(g: *Grid) TableSource {
        return .{ .ptr = g, .vtable = &vt };
    }
};

const Page = struct {
    t: *Table,
    w: f32 = 400,
    pub fn build(p: *Page, ui: *Ui) void {
        ui.open(.{ .style = .{ .w = .{ .px = p.w }, .h = .{ .px = 200 }, .dir = .column } });
        defer ui.close();
        p.t.build(ui);
    }
};

/// `n` columns titled "c<i>" with id i, 100 px wide.
fn makeColumns(buf: []Column, names: [][8]u8) []Column {
    for (buf, 0..) |*c, i| {
        const title = std.fmt.bufPrint(&names[i], "c{d}", .{i}) catch unreachable;
        c.* = .{ .id = @intCast(i), .title = title, .width = 100 };
    }
    return buf;
}

fn setup(gpa: std.mem.Allocator, page: *Page) !*TestApp {
    const app = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(page) });
    _ = app.settle();
    // The first build used the window width; settle on the real one.
    page.t.markDirty();
    _ = app.settle();
    app.win.setFocus(page.t.node, true);
    _ = app.settle();
    return app;
}

test "table: only visible columns built" {
    const gpa = testing.allocator;
    var grid: Grid = .{ .rows = 1_000_000 };
    var cols_buf: [50]Column = undefined;
    var names: [50][8]u8 = undefined;
    var tb = Table.init(gpa, grid.source(), .{ .columns = makeColumns(&cols_buf, &names), .label = "Data" });
    defer tb.deinit();
    var page: Page = .{ .t = &tb };
    const t = try setup(gpa, &page);
    defer t.deinit();

    // 400 px shows 4 columns; one more is built on the right.
    try testing.expectEqual(@as(usize, 5), t.count(.{ .role = .columnheader }));
    try testing.expect(t.count(.{ .role = .gridcell }) <= 5 * 16);
    try testing.expect(t.find(.{ .role = .columnheader, .name = "c4" }) != null);
    try testing.expect(t.find(.{ .role = .columnheader, .name = "c5" }) == null);

    try t.scroll(.{ .role = .grid }, 2000, 0);
    try testing.expectEqual(@as(f32, 2000), tb.scroll_x);
    try testing.expect(t.find(.{ .role = .columnheader, .name = "c0" }) == null);
    try testing.expect(t.find(.{ .role = .columnheader, .name = "c20" }) != null);
    try testing.expect(t.find(.{ .role = .gridcell, .name = "r0c20" }) != null);
    try testing.expect(t.count(.{ .role = .columnheader }) <= 6);
    const r = try t.rectOf(.{ .role = .columnheader, .name = "c20" });
    const g = try t.rectOf(.{ .role = .grid });
    try testing.expectEqual(g.x, r.x);
    // Scrolling stops at the last column.
    try t.scroll(.{ .role = .grid }, 1e6, 0);
    try testing.expectEqual(@as(f32, 5000 - 400), tb.scroll_x);
    try testing.expect(t.find(.{ .role = .columnheader, .name = "c49" }) != null);

    const sem = try t.semanticsSnapshot(gpa);
    defer gpa.free(sem);
    try testing.expect(std.mem.indexOf(u8, sem, "grid \"Data\" rows=1000001 cols=50 focused") != null);
    try testing.expect(std.mem.indexOf(u8, sem, "columnheader \"c49\" row=1 col=50") != null);
}

test "table: frozen column stays" {
    const gpa = testing.allocator;
    var grid: Grid = .{ .rows = 100 };
    var cols_buf: [20]Column = undefined;
    var names: [20][8]u8 = undefined;
    const cols = makeColumns(&cols_buf, &names);
    cols[0].frozen = true;
    var tb = Table.init(gpa, grid.source(), .{ .columns = cols });
    defer tb.deinit();
    var page: Page = .{ .t = &tb };
    const t = try setup(gpa, &page);
    defer t.deinit();

    const before = try t.rectOf(.{ .role = .columnheader, .name = "c0" });
    try t.scroll(.{ .role = .grid }, 750, 0);
    try testing.expectEqual(@as(f32, 750), tb.scroll_x);
    const after = try t.rectOf(.{ .role = .columnheader, .name = "c0" });
    try testing.expectEqual(before.x, after.x);
    try testing.expect(t.find(.{ .role = .gridcell, .name = "r0c0" }) != null);
    // c8 starts at 100 + 700 - 750: half hidden under the frozen column.
    try testing.expect(t.find(.{ .role = .columnheader, .name = "c1" }) == null);
    const c8 = try t.rectOf(.{ .role = .columnheader, .name = "c8" });
    try testing.expectEqual(before.x + 50, c8.x);
    // Moving left from c8 scrolls c7 back into view, right of the frozen one.
    tb.moveTo(0, 8, .keep);
    t.press(.arrow_left, .{});
    _ = t.settle();
    try testing.expectEqual(@as(f32, 600), tb.scroll_x);
    const c7 = try t.rectOf(.{ .role = .columnheader, .name = "c7" });
    try testing.expectEqual(before.x + 100, c7.x);
}

/// Presses at `from`, moves to each of `path` (a frame each), releases at
/// the last point.
fn dragPath(t: *TestApp, from: @import("../core/geom.zig").Vec2, path: []const @import("../core/geom.zig").Vec2, clicks: u8) void {
    t.win.dispatch(.{ .pointer_move = .{ .pos = from } });
    t.win.dispatch(.{ .pointer_down = .{ .pos = from, .clicks = clicks } });
    for (path) |p| {
        t.win.dispatch(.{ .pointer_move = .{ .pos = p } });
        _ = t.settle();
    }
    t.win.dispatch(.{ .pointer_up = .{ .pos = if (path.len > 0) path[path.len - 1] else from, .clicks = clicks } });
    _ = t.settle();
}

test "table: resize clamps and is live" {
    const gpa = testing.allocator;
    var grid: Grid = .{ .rows = 10 };
    var cols_buf: [3]Column = undefined;
    var names: [3][8]u8 = undefined;
    const cols = makeColumns(&cols_buf, &names);
    cols[0].max_w = 180;
    var tb = Table.init(gpa, grid.source(), .{ .columns = cols });
    defer tb.deinit();
    var page: Page = .{ .t = &tb };
    const t = try setup(gpa, &page);
    defer t.deinit();

    const h = try t.rectOf(.{ .role = .columnheader, .name = "c0" });
    const edge: @import("../core/geom.zig").Vec2 = .{ .x = h.right() - 2, .y = h.y + h.h / 2 };
    t.win.dispatch(.{ .pointer_move = .{ .pos = edge } });
    try testing.expectEqual(.col_resize, t.win.cursor);
    t.win.dispatch(.{ .pointer_down = .{ .pos = edge } });
    t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = edge.x + 30, .y = edge.y } } });
    _ = t.settle();
    // Live: the column and its cells are wider before the release.
    try testing.expectEqual(@as(f32, 130), cols[0].width);
    try testing.expectEqual(@as(f32, 130), (try t.rectOf(.{ .role = .gridcell, .name = "r0c0" })).w);
    try testing.expectEqual(h.x + 130, (try t.rectOf(.{ .role = .columnheader, .name = "c1" })).x);
    t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = edge.x + 300, .y = edge.y } } });
    _ = t.settle();
    try testing.expectEqual(@as(f32, 180), cols[0].width);
    t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = edge.x - 300, .y = edge.y } } });
    t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = edge.x - 300, .y = edge.y } } });
    _ = t.settle();
    try testing.expectEqual(@as(f32, 40), cols[0].width);
    // A resize is not a sort click.
    try testing.expectEqual(@as(?Sort, null), tb.sort);
}

test "table: autofit width" {
    const gpa = testing.allocator;
    var grid: Grid = .{ .rows = 10, .long = "a fairly long cell value" };
    var cols_buf: [10]Column = undefined;
    var names: [10][8]u8 = undefined;
    const cols = makeColumns(&cols_buf, &names);
    for (cols) |*c| c.width = 40;
    cols[0].width = 300;
    var tb = Table.init(gpa, grid.source(), .{ .columns = cols });
    defer tb.deinit();
    var page: Page = .{ .t = &tb, .w = 800 };
    const t = try setup(gpa, &page);
    defer t.deinit();

    const h = try t.rectOf(.{ .role = .columnheader, .name = "c9" });
    dragPath(t, .{ .x = h.right() - 1, .y = h.y + 4 }, &.{}, 2);
    const ts = t.win.engine.mc.text;
    const want = @ceil(ts.width(.{ .size = t.win.app.theme.dim(.font_size) }, grid.long) + 2 * table_mod.cell_pad + 1);
    try testing.expectEqual(want, cols[9].width);
    try testing.expect(cols[9].width > 100);
    // A wide column shrinks to its text.
    const h0 = try t.rectOf(.{ .role = .columnheader, .name = "c0" });
    dragPath(t, .{ .x = h0.right() - 1, .y = h0.y + 4 }, &.{}, 2);
    const want0 = @ceil(ts.width(.{ .size = t.win.app.theme.dim(.font_size) }, "r0c0") + 2 * table_mod.cell_pad + 1);
    try testing.expectEqual(@max(40, want0), cols[0].width);
}

test "table: reorder permutes columns" {
    const gpa = testing.allocator;
    var grid: Grid = .{ .rows = 10 };
    var cols_buf: [3]Column = undefined;
    var names: [3][8]u8 = undefined;
    const cols = makeColumns(&cols_buf, &names);
    cols[2].sortable = true;
    var tb = Table.init(gpa, grid.source(), .{ .columns = cols });
    defer tb.deinit();
    var page: Page = .{ .t = &tb };
    const t = try setup(gpa, &page);
    defer t.deinit();

    tb.moveTo(0, 2, .replace); // active on c2
    const h2 = try t.rectOf(.{ .role = .columnheader, .name = "c2" });
    const h0 = try t.rectOf(.{ .role = .columnheader, .name = "c0" });
    const y = h2.y + h2.h / 2;
    t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = h2.x + 20, .y = y } } });
    t.win.dispatch(.{ .pointer_down = .{ .pos = .{ .x = h2.x + 20, .y = y } } });
    t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = h0.x + 10, .y = y } } });
    _ = t.settle();
    try testing.expectEqual(@as(?usize, 0), tb.drop);
    t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = h0.x + 10, .y = y } } });
    _ = t.settle();
    try testing.expectEqual(@as(u32, 2), cols[0].id);
    try testing.expectEqual(@as(u32, 0), cols[1].id);
    try testing.expectEqual(@as(u32, 1), cols[2].id);
    try testing.expectEqual(@as(usize, 0), tb.active_col);
    // The drag did not sort, and the header moved.
    try testing.expectEqual(@as(?Sort, null), tb.sort);
    try testing.expectEqual(h0.x, (try t.rectOf(.{ .role = .columnheader, .name = "c2" })).x);
    // Back to the end.
    tb.moveColumn(0, 3);
    try testing.expectEqual(@as(u32, 0), cols[0].id);
    try testing.expectEqual(@as(u32, 2), cols[2].id);
}

const Sorted = struct {
    calls: u32 = 0,
    last: ?Sort = null,
    fn f(ctx: *anyopaque, _: *Table, s: ?Sort) void {
        const o: *Sorted = @ptrCast(@alignCast(ctx));
        o.calls += 1;
        o.last = s;
    }
};

test "table: sort cycle callback" {
    const gpa = testing.allocator;
    var grid: Grid = .{ .rows = 10 };
    var cols_buf: [3]Column = undefined;
    var names: [3][8]u8 = undefined;
    const cols = makeColumns(&cols_buf, &names);
    cols[1].sortable = true;
    var sorted: Sorted = .{};
    var tb = Table.init(gpa, grid.source(), .{ .columns = cols, .on_sort = .{ .ctx = &sorted, .f = Sorted.f } });
    defer tb.deinit();
    var page: Page = .{ .t = &tb };
    const t = try setup(gpa, &page);
    defer t.deinit();

    try t.click(.{ .role = .columnheader, .name = "c0" }); // not sortable
    try testing.expectEqual(@as(u32, 0), sorted.calls);
    try t.click(.{ .role = .columnheader, .name = "c1" });
    try testing.expectEqual(Sort{ .col = 1 }, sorted.last.?);
    const sem = try t.semanticsSnapshot(gpa);
    defer gpa.free(sem);
    try testing.expect(std.mem.indexOf(u8, sem, "columnheader \"c1\" row=1 col=2 sort=ascending") != null);
    try t.click(.{ .role = .columnheader, .name = "c1" });
    try testing.expectEqual(Sort{ .col = 1, .desc = true }, sorted.last.?);
    try t.click(.{ .role = .columnheader, .name = "c1" });
    try testing.expectEqual(@as(?Sort, null), sorted.last);
    try testing.expectEqual(@as(u32, 3), sorted.calls);
}

const Activated = struct {
    row: ?u64 = null,
    col: u32 = 0,
    fn f(ctx: *anyopaque, row: u64, col: u32) void {
        const o: *Activated = @ptrCast(@alignCast(ctx));
        o.row = row;
        o.col = col;
    }
};

test "table: APG grid keyboard script" {
    const gpa = testing.allocator;
    var grid: Grid = .{ .rows = 1000 };
    var cols_buf: [8]Column = undefined;
    var names: [8][8]u8 = undefined;
    var act: Activated = .{};
    var tb = Table.init(gpa, grid.source(), .{ .columns = makeColumns(&cols_buf, &names), .on_activate = .{ .ctx = &act, .f = Activated.f } });
    defer tb.deinit();
    var page: Page = .{ .t = &tb };
    const t = try setup(gpa, &page);
    defer t.deinit();

    t.press(.arrow_down, .{});
    t.press(.arrow_right, .{});
    t.press(.arrow_right, .{});
    try testing.expectEqual(@as(u64, 1), tb.active_row);
    try testing.expectEqual(@as(usize, 2), tb.active_col);
    try testing.expectEqualSlices(table_mod.Range, &.{.{ .lo = 1, .hi = 1 }}, tb.selection());
    t.press(.end, .{});
    try testing.expectEqual(@as(usize, 7), tb.active_col);
    _ = t.settle();
    // The last column scrolled into view.
    try testing.expect(t.find(.{ .role = .gridcell, .name = "r1c7" }) != null);
    t.press(.home, .{});
    try testing.expectEqual(@as(usize, 0), tb.active_col);
    try testing.expectEqual(@as(f32, 0), tb.scroll_x);
    t.press(.arrow_left, .{}); // stays at the edge
    try testing.expectEqual(@as(usize, 0), tb.active_col);
    t.press(.page_down, .{});
    try testing.expect(tb.active_row > 1);
    t.press(.end, .{ .ctrl = true });
    try testing.expectEqual(@as(u64, 999), tb.active_row);
    try testing.expectEqual(@as(usize, 7), tb.active_col);
    _ = t.settle();
    try testing.expect(t.find(.{ .role = .gridcell, .name = "r999c7" }) != null);
    t.press(.home, .{ .ctrl = true });
    try testing.expectEqual(@as(u64, 0), tb.active_row);
    try testing.expectEqual(@as(usize, 0), tb.active_col);

    // Shift extends, Ctrl moves without selecting, Shift+Space adds.
    t.press(.arrow_down, .{ .shift = true });
    t.press(.arrow_down, .{ .shift = true });
    try testing.expectEqualSlices(table_mod.Range, &.{.{ .lo = 0, .hi = 2 }}, tb.selection());
    t.press(.arrow_down, .{ .ctrl = true });
    t.press(.arrow_down, .{ .ctrl = true });
    try testing.expectEqual(@as(u64, 4), tb.active_row);
    try testing.expect(!tb.isSelected(4));
    t.press(.space, .{ .shift = true });
    try testing.expect(tb.isSelected(4));
    try testing.expect(!tb.isSelected(3));
    t.press(.key_a, .{ .ctrl = true });
    try testing.expectEqualSlices(table_mod.Range, &.{.{ .lo = 0, .hi = 999 }}, tb.selection());
    t.press(.escape, .{});
    try testing.expectEqual(@as(usize, 0), tb.selection().len);

    t.press(.arrow_right, .{});
    t.press(.enter, .{});
    try testing.expectEqual(@as(?u64, 4), act.row);
    try testing.expectEqual(@as(u32, 1), act.col);

    t.press(.space, .{ .shift = true });
    _ = t.settle();
    const sem = try t.semanticsSnapshot(gpa);
    defer gpa.free(sem);
    try testing.expect(std.mem.indexOf(u8, sem, "row selected row=6") != null);
    try testing.expect(std.mem.indexOf(u8, sem, "gridcell \"r4c1\" row=6 col=2") != null);

    // A click selects the row; a double click activates the cell.
    try t.click(.{ .role = .gridcell, .name = "r2c3" });
    try testing.expectEqual(@as(u64, 2), tb.active_row);
    try testing.expectEqual(@as(usize, 3), tb.active_col);
    try testing.expectEqualSlices(table_mod.Range, &.{.{ .lo = 2, .hi = 2 }}, tb.selection());
    try t.doubleClick(.{ .role = .gridcell, .name = "r3c0" });
    try testing.expectEqual(@as(?u64, 3), act.row);
    try testing.expectEqual(@as(u32, 0), act.col);
}

test "table: copy selection as TSV" {
    const gpa = testing.allocator;
    var grid: Grid = .{ .rows = 20 };
    var cols_buf: [3]Column = undefined;
    var names: [3][8]u8 = undefined;
    var tb = Table.init(gpa, grid.source(), .{ .columns = makeColumns(&cols_buf, &names) });
    defer tb.deinit();
    var page: Page = .{ .t = &tb };
    const t = try setup(gpa, &page);
    defer t.deinit();

    t.press(.arrow_down, .{});
    t.press(.arrow_down, .{ .shift = true });
    t.press(.arrow_down, .{ .ctrl = true });
    t.press(.arrow_down, .{ .ctrl = true });
    t.press(.space, .{ .shift = true });
    t.press(.key_c, .{ .ctrl = true });
    try testing.expectEqualStrings("r1c0\tr1c1\tr1c2\nr2c0\tr2c1\tr2c2\nr4c0\tr4c1\tr4c2", t.app.clipboard.get());

    // Cell selection copies the active cell.
    tb.props.selection = .cell;
    t.press(.arrow_right, .{});
    t.press(.key_c, .{ .ctrl = true });
    try testing.expectEqualStrings("r4c1", t.app.clipboard.get());
}
