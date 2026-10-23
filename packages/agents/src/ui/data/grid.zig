//! Data mode's editor surface (E13.F06.S01.T02): a dataset in an E04
//! Table, with the row count, the sort and filter bar, the column
//! profile, row detail and "Chart this".
//!
//! The table shows a row-number gutter (approximate numbers start with
//! `~` while the file is indexed), keeps the gutter frozen (and the first
//! column with `data.pinFirstColumn`), right-aligns numbers, dims nulls
//! and gives long cells a tooltip. Column widths come from the 95th
//! percentile of a sample of their cells. A header click sorts through
//! the query engine. Keyboard navigation is the E04 grid's; every action
//! is a `data.*` command (`runCommand`), so the palette and key bindings
//! reach them all.
//!
//! The app opens `.csv`, `.tsv`, `.json`, `.ndjson` and `.jsonl` files
//! here as an alternative editor (`isDataPath`), and by default when they
//! are larger than 50 MB (`opensAsData`); "Open as text" goes back to the
//! text editor.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const grid_vm = @import("grid_vm.zig");
const chart_this = @import("chart_this.zig");
const query_bar = @import("query_bar.zig");
const profile_panel = @import("profile_panel.zig");
const row_detail = @import("row_detail.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Ui = zg_gui.Ui;
const App = zg_gui.App;
const virtual = zg_gui.virtual;
const controls = zg_gui.w.controls;
const GridVM = grid_vm.GridVM;
const Dataset = zg_agents.data.Dataset;

pub const data_extensions = [_][]const u8{ ".csv", ".tsv", ".json", ".ndjson", ".jsonl" };
/// Files larger than this open in data mode by default.
pub const default_data_mode_bytes: u64 = 50 << 20;

/// Whether data mode can open `path`.
pub fn isDataPath(path: []const u8) bool {
    for (data_extensions) |e| if (std.ascii.endsWithIgnoreCase(path, e)) return true;
    return false;
}

/// Whether `path` (of `size` bytes) opens in data mode by default.
pub fn opensAsData(path: []const u8, size: u64) bool {
    return isDataPath(path) and size > default_data_mode_bytes;
}

/// Palette commands; `DataGrid.runCommand` runs them.
pub const commands = [_][]const u8{
    "data.sortAscending",  "data.sortDescending", "data.clearSort",      "data.filterEquals",
    "data.filterContains", "data.filterRange",    "data.filterEmpty",    "data.filterNotEmpty",
    "data.clearFilters",   "data.advancedQuery",  "data.simpleQuery",    "data.toggleProfile",
    "data.rowDetail",      "data.selectColumn",   "data.chartThis",      "data.copyTsv",
    "data.copyMarkdown",   "data.pinFirstColumn", "data.autofitColumns", "data.openAsText",
};

pub const Ports = struct {
    /// Called from any thread when the grid has something new; the app
    /// schedules a frame.
    wake: ?grid_vm.Hook = null,
    /// Puts text on the clipboard.
    set_clipboard: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, text: []const u8) void } = null,
    /// Creates a chart artifact from a spec (and shows it).
    create_chart: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, spec_json: []const u8) void } = null,
    /// Reopens the file in the text editor.
    open_as_text: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void } = null,
};

/// The gutter's column id.
const gutter_id: u32 = std.math.maxInt(u32);
pub const row_h: f32 = 24;

pub const DataGrid = struct {
    gpa: Allocator,
    io: Io,
    app: *App,
    p: Ports,
    vm: *GridVM,
    table: virtual.Table,
    columns: std.ArrayListUnmanaged(virtual.Column) = .empty,
    /// Column titles (with the selection mark) live here.
    col_arena: std.heap.ArenaAllocator,
    /// The columns' identity when they were built (view text).
    built_for: ?u64 = null,
    pin_first: bool = false,
    /// Columns picked for "Chart this" (and copies), by view column.
    picked: std.ArrayListUnmanaged(u32) = .empty,
    bar: query_bar.QueryBar,
    profile: *profile_panel.ProfilePanel,
    show_profile: bool = false,
    detail: row_detail.RowDetail,
    notice: ?[]const u8 = null,
    notice_buf: [200]u8 = undefined,
    gutter_bufs: [256][24]u8 = undefined,
    gutter_next: usize = 0,

    pub fn init(gpa: Allocator, io: Io, app: *App, ds: *Dataset, name: []const u8, p: Ports) !*DataGrid {
        const g = try gpa.create(DataGrid);
        errdefer gpa.destroy(g);
        const vm = try GridVM.init(gpa, io, ds, name);
        errdefer vm.deinit();
        vm.wake = p.wake;
        const prof = try profile_panel.ProfilePanel.init(gpa, io, app, ds);
        prof.wake = p.wake;
        g.* = .{
            .gpa = gpa,
            .io = io,
            .app = app,
            .p = p,
            .vm = vm,
            .table = undefined,
            .col_arena = .init(gpa),
            .bar = try .init(gpa),
            .profile = prof,
            .detail = .{ .gpa = gpa },
        };
        g.table = .init(gpa, .{ .ptr = g, .vtable = &table_vtable }, .{
            .columns = &.{},
            .row_h = row_h,
            .label = "Data",
            .test_id = "data-grid",
            .on_sort = .{ .ctx = g, .f = onSort },
            .on_activate = .{ .ctx = g, .f = onActivate },
        });
        g.rebuildColumns();
        return g;
    }

    /// Call when no worker job is pending (`App.joinWork` first).
    pub fn deinit(g: *DataGrid) void {
        g.profile.deinit();
        g.vm.deinit();
        g.table.deinit();
        g.columns.deinit(g.gpa);
        g.picked.deinit(g.gpa);
        g.col_arena.deinit();
        g.bar.deinit();
        g.detail.deinit();
        g.gpa.destroy(g);
    }

    // -- columns -------------------------------------------------------------

    fn viewKey(g: *const DataGrid) u64 {
        const t = g.vm.view_text orelse return 0;
        return std.hash.Wyhash.hash(g.vm.columnCount(), t);
    }

    /// Columns for the view: the gutter, then one per view column, sized
    /// from a sample.
    fn rebuildColumns(g: *DataGrid) void {
        g.built_for = g.viewKey();
        _ = g.col_arena.reset(.retain_capacity);
        g.columns.clearRetainingCapacity();
        g.picked.clearRetainingCapacity();
        const n = g.vm.columnCount();
        g.columns.ensureTotalCapacity(g.gpa, n + 1) catch return;
        g.columns.appendAssumeCapacity(.{ .id = gutter_id, .title = "#", .width = g.gutterWidth(), .frozen = true, .resizable = false, .align_ = .end });
        for (0..n) |i| {
            const c: u32 = @intCast(i);
            const number = grid_vm.kindOf(g.vm.columnType(c)) == .number;
            g.columns.appendAssumeCapacity(.{
                .id = c,
                .title = g.vm.columnName(c),
                .width = g.sampleWidth(c),
                .sortable = true,
                .align_ = if (number) .end else .start,
                .frozen = i == 0 and g.pin_first,
            });
        }
        g.table.props.columns = g.columns.items;
        g.table.sort = if (g.vm.sort) |s| .{ .col = s.col, .desc = s.desc } else null;
        g.table.reload();
    }

    fn gutterWidth(g: *DataGrid) f32 {
        var buf: [32]u8 = undefined;
        const digits = g.vm.rowLabel(g.vm.rowCount(), &buf).len + 1;
        return @max(40, @as(f32, @floatFromInt(digits)) * char_w + 2 * virtual.table.cell_pad);
    }

    /// The 95th percentile of the widths of up to 200 cells (and the
    /// title), capped.
    fn sampleWidth(g: *DataGrid, col: u32) f32 {
        var ws: [201]f32 = undefined;
        const rows = @min(g.vm.rowCount(), 200);
        var n: usize = 0;
        ws[n] = textWidth(g.vm.columnName(col)) + 16;
        n += 1;
        var r: u64 = 0;
        while (r < rows) : (r += 1) {
            ws[n] = textWidth(g.vm.cellText(r, col));
            n += 1;
        }
        std.mem.sort(f32, ws[0..n], {}, std.sort.asc(f32));
        const p95 = ws[@min(n - 1, (n * 95) / 100)];
        return std.math.clamp(p95 + 2 * virtual.table.cell_pad, 56, 320);
    }

    // -- the table source ------------------------------------------------------

    fn rowCount(ptr: *anyopaque) u64 {
        const g: *DataGrid = @ptrCast(@alignCast(ptr));
        return g.vm.rowCount();
    }

    fn cellText(ptr: *anyopaque, row: u64, col: u32) []const u8 {
        const g: *DataGrid = @ptrCast(@alignCast(ptr));
        if (col == gutter_id) {
            const b = &g.gutter_bufs[g.gutter_next];
            g.gutter_next = (g.gutter_next + 1) % g.gutter_bufs.len;
            return g.vm.rowLabel(row, b);
        }
        return g.vm.cellText(row, col);
    }

    fn buildCell(ptr: *anyopaque, ui: *Ui, row: u64, col: u32) void {
        const g: *DataGrid = @ptrCast(@alignCast(ptr));
        if (col == gutter_id) {
            var buf: [24]u8 = undefined;
            ui.text(ui.arena().dupe(u8, g.vm.rowLabel(row, &buf)) catch "", .{ .color = .fg_muted, .wrap = false, .@"align" = .end });
            return;
        }
        const e = g.vm.cell(row, col) catch return;
        if (e.null_) return ui.text(grid_vm.null_mark, .{ .color = .fg_disabled, .wrap = false });
        const number = grid_vm.kindOf(g.vm.columnType(col)) == .number;
        ui.text(e.text, .{ .wrap = false, .@"align" = if (number) .end else .start });
        // Long text: the whole value on hover.
        const w = g.widthOf(col);
        if (textWidth(e.text) + 2 * virtual.table.cell_pad > w) zg_gui.w.tooltip(ui, e.text, .{});
    }

    fn widthOf(g: *const DataGrid, col: u32) f32 {
        for (g.columns.items) |c| if (c.id == col) return c.width;
        return 0;
    }

    const table_vtable: virtual.TableSource.VTable = .{ .row_count = rowCount, .cell_text = cellText, .build_cell = buildCell };

    fn onSort(ctx: *anyopaque, _: *virtual.Table, s: ?virtual.table.Sort) void {
        const g: *DataGrid = @ptrCast(@alignCast(ctx));
        if (s) |x| if (x.col == gutter_id) return;
        g.bar.mode = .simple;
        g.vm.setSort(if (s) |x| .{ .col = x.col, .desc = x.desc } else null) catch |e| g.say("Could not sort: {s}", .{@errorName(e)});
    }

    fn onActivate(ctx: *anyopaque, row: u64, _: u32) void {
        const g: *DataGrid = @ptrCast(@alignCast(ctx));
        g.detail.show(row);
    }

    // -- state -------------------------------------------------------------------

    /// The active cell's view column (null on the gutter).
    pub fn activeColumn(g: *const DataGrid) ?u32 {
        const cols = g.table.columns();
        if (g.table.active_col >= cols.len) return null;
        const id = cols[g.table.active_col].id;
        return if (id == gutter_id) null else id;
    }

    /// The active column as a source column (filters and profiles work on
    /// the file's columns).
    fn sourceColumn(g: *const DataGrid) ?u32 {
        const c = g.activeColumn() orelse return null;
        const name = g.vm.columnName(c);
        for (g.vm.ds.columns, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
        return null;
    }

    fn say(g: *DataGrid, comptime fmt: []const u8, args: anytype) void {
        g.notice = std.fmt.bufPrint(&g.notice_buf, fmt, args) catch "…";
    }

    /// The rows a copy takes: the selection, else the active row.
    fn copyRanges(g: *DataGrid, a: Allocator) ![]const [2]u64 {
        const sel = g.table.selection();
        if (sel.len == 0) {
            const out = try a.alloc([2]u64, 1);
            out[0] = .{ g.table.active_row, g.table.active_row };
            return out;
        }
        const out = try a.alloc([2]u64, sel.len);
        for (out, sel) |*o, r| o.* = .{ r.lo, r.hi };
        return out;
    }

    /// The columns a copy or chart takes: the picked ones in grid order,
    /// else (for copies) every column, or (for charts) the active one.
    fn chosenColumns(g: *DataGrid, a: Allocator, all: bool) ![]const u32 {
        var out: std.ArrayListUnmanaged(u32) = .empty;
        for (g.columns.items) |c| {
            if (c.id == gutter_id) continue;
            if (std.mem.indexOfScalar(u32, g.picked.items, c.id) != null) try out.append(a, c.id);
        }
        if (out.items.len > 0) return out.items;
        if (all) {
            for (g.columns.items) |c| if (c.id != gutter_id) try out.append(a, c.id);
        } else if (g.activeColumn()) |c| try out.append(a, c);
        return out.items;
    }

    /// Runs a palette command; false when `id` is not one of `commands`.
    pub fn runCommand(g: *DataGrid, id: []const u8) bool {
        g.command(id) catch |e| g.say("{s} failed: {s}", .{ id, @errorName(e) });
        for (commands) |c| if (std.mem.eql(u8, c, id)) return true;
        return false;
    }

    fn command(g: *DataGrid, id: []const u8) !void {
        const eq = std.mem.eql;
        var arena: std.heap.ArenaAllocator = .init(g.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        g.notice = null;
        if (eq(u8, id, "data.sortAscending") or eq(u8, id, "data.sortDescending")) {
            const c = g.sourceColumn() orelse return g.say("Select a column of the file to sort by.", .{});
            g.bar.mode = .simple;
            try g.vm.setSort(.{ .col = c, .desc = eq(u8, id, "data.sortDescending") });
        } else if (eq(u8, id, "data.clearSort")) {
            try g.vm.setSort(null);
        } else if (std.mem.startsWith(u8, id, "data.filter")) {
            const c = g.sourceColumn() orelse return g.say("Select a column of the file to filter.", .{});
            const op: grid_vm.Chip.Op = if (eq(u8, id, "data.filterEquals")) .equals else if (eq(u8, id, "data.filterContains")) .contains else if (eq(u8, id, "data.filterRange")) .range else if (eq(u8, id, "data.filterEmpty")) .is_null else .not_null;
            g.bar.mode = .simple;
            try g.bar.startChip(g.vm, c, op);
        } else if (eq(u8, id, "data.clearFilters")) {
            try g.vm.clearFilters();
        } else if (eq(u8, id, "data.advancedQuery")) {
            try g.bar.advanced(g.vm);
        } else if (eq(u8, id, "data.simpleQuery")) {
            try g.bar.simple(g.vm);
        } else if (eq(u8, id, "data.toggleProfile")) {
            g.show_profile = !g.show_profile;
            try g.profile.show(if (g.show_profile) g.sourceColumn() else null);
        } else if (eq(u8, id, "data.rowDetail")) {
            g.detail.show(if (g.detail.row == g.table.active_row) null else g.table.active_row);
        } else if (eq(u8, id, "data.selectColumn")) {
            const c = g.activeColumn() orelse return;
            if (std.mem.indexOfScalar(u32, g.picked.items, c)) |i| _ = g.picked.swapRemove(i) else try g.picked.append(g.gpa, c);
        } else if (eq(u8, id, "data.chartThis")) {
            const cols = try g.chosenColumns(a, false);
            const spec = chart_this.spec(g.vm, a, cols) catch |e| switch (e) {
                error.Unchartable => return g.say("{s}", .{chart_this.hint}),
                else => return e,
            };
            const p = g.p.create_chart orelse return g.say("Charts are not available here.", .{});
            p.f(p.ctx, spec);
            g.say("Chart created.", .{});
        } else if (eq(u8, id, "data.copyTsv") or eq(u8, id, "data.copyMarkdown")) {
            const md = eq(u8, id, "data.copyMarkdown");
            const ranges = try g.copyRanges(a);
            const text = grid_vm.copyRows(g.vm, a, ranges, try g.chosenColumns(a, true), if (md) .markdown else .tsv) catch |e| switch (e) {
                error.TooManyRows => return g.say("Markdown copies at most {d} rows; copy as TSV instead.", .{grid_vm.max_markdown_rows}),
                else => return e,
            };
            const p = g.p.set_clipboard orelse return;
            p.f(p.ctx, text);
            var rows: u64 = 0;
            for (ranges) |r| rows += r[1] - r[0] + 1;
            g.say("Copied {d} {s} as {s}.", .{ rows, if (rows == 1) "row" else "rows", if (md) "Markdown" else "TSV" });
        } else if (eq(u8, id, "data.pinFirstColumn")) {
            g.pin_first = !g.pin_first;
            g.rebuildColumns();
        } else if (eq(u8, id, "data.autofitColumns")) {
            for (g.columns.items) |*c| if (c.id != gutter_id) {
                c.width = g.sampleWidth(c.id);
            };
            g.table.markDirty();
        } else if (eq(u8, id, "data.openAsText")) {
            if (g.p.open_as_text) |p| p.f(p.ctx);
        }
    }

    /// Picks up background changes; called at the start of each build.
    fn refresh(g: *DataGrid) void {
        const reload = g.vm.poll();
        if (g.viewKey() != g.built_for) {
            g.rebuildColumns();
            // A new view's rows: the detail and profile follow the grid.
            g.detail.show(null);
        } else if (reload) {
            g.columns.items[0].width = g.gutterWidth();
            g.table.reload();
        }
        if (g.show_profile) g.profile.show(g.sourceColumn()) catch {};
    }

    pub fn build(g: *DataGrid, ui: *Ui) void {
        g.refresh();
        const th = ui.theme();
        const a = ui.arena();
        ui.open(.{ .role = .group, .label = "Data", .test_id = "data-mode", .style = .{ .dir = .column, .gap = th.dim(.space_sm), .padding = .all(th.dim(.space_sm)), .grow = 1 } });
        defer ui.close();
        g.toolbar(ui);
        query_bar.queryBar(ui, &g.bar, g.vm);
        if (g.notice) |n| {
            ui.open(.{ .role = .status, .label = n, .test_id = "data-notice" });
            ui.text(n, .{ .color = .fg_muted });
            ui.close();
        }
        if (g.picked.items.len > 0) {
            var w: Io.Writer.Allocating = .init(a);
            w.writer.writeAll("Columns picked: ") catch {};
            for (g.picked.items, 0..) |c, i| w.writer.print("{s}{s}", .{ if (i > 0) ", " else "", g.vm.columnName(c) }) catch {};
            ui.text(w.written(), .{ .color = .fg_muted, .wrap = false });
        }
        ui.open(.{ .style = .{ .dir = .row, .grow = 1, .gap = th.dim(.space_sm) } });
        defer ui.close();
        ui.open(.{ .style = .{ .dir = .column, .grow = 1 } });
        g.table.build(ui);
        ui.close();
        if (g.show_profile) switch (profile_panel.profilePanel(ui, g.profile, g.vm)) {
            .none => {},
            .filter_equals => |v| if (g.profile.col) |c| {
                g.bar.mode = .simple;
                g.vm.addChip(.{ .col = c, .op = .equals, .a = v }) catch {};
            },
        };
        row_detail.rowDetail(ui, &g.detail, g.vm);
    }

    fn toolbar(g: *DataGrid, ui: *Ui) void {
        const th = ui.theme();
        ui.open(.{ .role = .toolbar, .label = "Data", .style = .{ .dir = .row, .gap = th.dim(.space_xs), .align_items = .center, .wrap = true } });
        defer ui.close();
        var buf: [96]u8 = undefined;
        const label = g.vm.rowCountLabel(&buf);
        ui.open(.{ .role = .status, .label = label, .test_id = "data-row-count" });
        ui.text(ui.arena().dupe(u8, label) catch "", .{ .wrap = false });
        ui.close();
        const Btn = struct { label: []const u8, cmd: []const u8 };
        const btns = [_]Btn{
            .{ .label = "Sort ↑", .cmd = "data.sortAscending" },
            .{ .label = "Sort ↓", .cmd = "data.sortDescending" },
            .{ .label = "Equals…", .cmd = "data.filterEquals" },
            .{ .label = "Contains…", .cmd = "data.filterContains" },
            .{ .label = "Range…", .cmd = "data.filterRange" },
            .{ .label = "Clear", .cmd = "data.clearFilters" },
            .{ .label = if (g.bar.mode == .simple) "Query…" else "Simple", .cmd = if (g.bar.mode == .simple) "data.advancedQuery" else "data.simpleQuery" },
            .{ .label = "Profile", .cmd = "data.toggleProfile" },
            .{ .label = "Row", .cmd = "data.rowDetail" },
            .{ .label = "Pick column", .cmd = "data.selectColumn" },
            .{ .label = "Chart this", .cmd = "data.chartThis" },
            .{ .label = "Copy", .cmd = "data.copyTsv" },
            .{ .label = "Copy Markdown", .cmd = "data.copyMarkdown" },
            .{ .label = "Open as text", .cmd = "data.openAsText" },
        };
        for (btns) |b| {
            ui.id(b.cmd);
            if (controls.button(ui, .{ .label = b.label, .variant = .ghost }).clicked) _ = g.runCommand(b.cmd);
        }
    }
};

/// An average UI character's width (sizing columns without measuring).
const char_w: f32 = 7.2;

fn textWidth(s: []const u8) f32 {
    var n: usize = 0;
    for (s) |c| n += @intFromBool(c & 0xC0 != 0x80);
    return @as(f32, @floatFromInt(n)) * char_w;
}

pub fn dataGrid(ui: *Ui, g: *DataGrid) void {
    g.build(ui);
}

test {
    std.testing.refAllDecls(@This());
}
