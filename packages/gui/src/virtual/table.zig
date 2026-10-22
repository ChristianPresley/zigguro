//! Table (E04.F04.S02.T03): a virtualised grid for debug variables and
//! watches (E07), settings tables, test results, the agent run dashboard
//! (E13) and CSV previews.
//!
//! The caller owns a `Table` (data source, columns, selection) and calls
//! `build` from its view. Rows come from `virtualList` at a fixed height,
//! and only the columns that cross the viewport (plus one each side) are
//! built, so 50 columns by a million rows cost what one screenful costs.
//! Leading columns marked `frozen` stay put while the rest scroll
//! sideways; the header row stays on top and follows the sideways scroll.
//!
//! Columns live in the caller's slice, which the table changes in place:
//! - Drag a header's right edge (6 px) to resize it, clamped to the
//!   column's range; double-click the edge to fit the visible rows.
//! - Drag a header to move the column (within the frozen or the
//!   scrolling group).
//! - Click a sortable header to cycle ascending, descending and unsorted;
//!   `on_sort` hears about it and the source sorts its rows.
//!
//! Keyboard (WAI-ARIA APG grid; focus stays on the table and the active
//! cell is drawn as focused):
//! - Arrows move between cells, Home/End to the row's ends, Ctrl+Home/End
//!   to the first and last cell, Page Up/Down by a page.
//! - In row selection, the selection follows the active row; Shift+arrows
//!   extend it, Ctrl+arrows move without selecting, Shift+Space adds the
//!   active row and Ctrl+A selects every row.
//! - Enter calls `on_activate`; Ctrl+C copies the selection as
//!   tab-separated text (`cell_text`).
//!
//! Not yet: type-ahead and keeping the selection across a re-sort.

const std = @import("std");
const geom = @import("../core/geom.zig");
const ids = @import("../core/ids.zig");
const ui_mod = @import("../core/ui.zig");
const widget = @import("../core/widget.zig");
const window_mod = @import("../core/window.zig");
const style_mod = @import("../layout/style.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const text_mod = @import("../paint/text.zig");
const event_mod = @import("../input/event.zig");
const theme_mod = @import("../theme/theme.zig");
const scroll = @import("../widgets/scroll.zig");

const Rect = geom.Rect;
const NodeId = ids.NodeId;
const Ui = ui_mod.Ui;
const Window = window_mod.Window;
const PaintCx = paint_cx.PaintCx;
const Allocator = std.mem.Allocator;

pub const Align = paint_cx.TextAlign;

/// One column; the table writes `width` and the slice order back.
pub const Column = struct {
    id: u32,
    title: []const u8,
    width: f32,
    min_w: f32 = 40,
    max_w: f32 = 2000,
    resizable: bool = true,
    sortable: bool = false,
    align_: Align = .start,
    /// Leading columns that do not scroll sideways.
    frozen: bool = false,
};

/// Where the rows come from. `col` is a column's `id`.
pub const TableSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        row_count: *const fn (ptr: *anyopaque) u64,
        /// A stable key per row, so the active row follows its data
        /// across `reload` (after a sort).
        row_key: ?*const fn (ptr: *anyopaque, row: u64) u64 = null,
        /// Builds a cell's content; without it the cell shows `cell_text`.
        build_cell: ?*const fn (ptr: *anyopaque, ui: *Ui, row: u64, col: u32) void = null,
        /// A cell's plain text: shown, copied, named for assistive
        /// technology and measured by auto-fit.
        cell_text: ?*const fn (ptr: *anyopaque, row: u64, col: u32) []const u8 = null,
    };

    pub fn rowCount(s: TableSource) u64 {
        return s.vtable.row_count(s.ptr);
    }

    pub fn text(s: TableSource, row: u64, col: u32) []const u8 {
        const f = s.vtable.cell_text orelse return "";
        return f(s.ptr, row, col);
    }
};

/// A sorted column.
pub const Sort = struct {
    col: u32,
    desc: bool = false,
};

/// Called when a header click changes the sort (null: unsorted).
pub const SortHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, t: *Table, sort: ?Sort) void,
};

/// Called with a cell (Enter or double click).
pub const CellHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, row: u64, col: u32) void,
};

/// Called when the selection changed.
pub const SelectionHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, t: *Table) void,
};

pub const SelectionMode = enum { row, cell, none };

/// How a table looks and behaves.
pub const TableProps = struct {
    columns: []Column,
    row_h: f32 = 24,
    header_h: f32 = 26,
    selection: SelectionMode = .row,
    sort: ?Sort = null,
    on_sort: ?SortHook = null,
    on_activate: ?CellHook = null,
    on_selection: ?SelectionHook = null,
    reorder_columns: bool = true,
    striped: bool = false,
    /// The table's accessible name.
    label: []const u8 = "",
    test_id: []const u8 = "",
    /// The table's style (`dir = .column` is set).
    style: style_mod.Style = .{ .grow = 1 },
};

/// Horizontal padding inside a cell.
pub const cell_pad: f32 = 6;
/// Width of the resize zone at a header's right edge.
pub const resize_zone: f32 = 6;
/// A header press becomes a column drag past this distance.
pub const drag_threshold: f32 = 4;
/// Auto-fit measures at most this many rows.
pub const autofit_rows: u64 = 1000;
/// Room for the sort arrow in a header.
const sort_w: f32 = 14;

/// Selected rows `lo..hi` (inclusive).
pub const Range = struct { lo: u64, hi: u64 };

const Drag = union(enum) {
    none,
    /// Resizing column `col` (slice index) from width `w0` at pointer `x0`.
    resize: struct { col: usize, x0: f32, w0: f32 },
    /// A press on header `col`; `moved` once past the threshold.
    press: struct { col: usize, x0: f32, moved: bool = false },
};

/// A table's state.
pub const Table = struct {
    gpa: Allocator,
    source: TableSource,
    props: TableProps,
    sort: ?Sort,
    active_row: u64 = 0,
    /// The active column's slice index.
    active_col: usize = 0,
    active_key: ?u64 = null,
    anchor: u64 = 0,
    /// Selected rows (row selection), disjoint.
    ranges: std.ArrayList(Range) = .empty,
    /// Sideways scroll of the non-frozen columns.
    scroll_x: f32 = 0,
    /// Left edges of the non-frozen columns, plus the right edge of the
    /// last one.
    xs: std.ArrayList(f32) = .empty,
    frozen_n: usize = 0,
    frozen_w: f32 = 0,
    /// Width of the scrolling part, from the last layout.
    pane_w: f32 = 0,
    drag: Drag = .none,
    /// Insertion index while dragging a column.
    drop: ?usize = null,
    win: ?*Window = null,
    view: u16 = 0,
    node: NodeId = .none,
    list: NodeId = .none,
    focused: bool = false,
    /// The rows built last time.
    first: u64 = 0,
    end: u64 = 0,

    pub fn init(gpa: Allocator, source: TableSource, props: TableProps) Table {
        return .{ .gpa = gpa, .source = source, .props = props, .sort = props.sort };
    }

    pub fn deinit(t: *Table) void {
        t.ranges.deinit(t.gpa);
        t.xs.deinit(t.gpa);
    }

    pub fn columns(t: *const Table) []Column {
        return t.props.columns;
    }

    pub fn markDirty(t: *Table) void {
        const w = t.win orelse return;
        if (t.view != 0) w.markViewDirty(t.view);
    }

    /// Re-reads the rows (after the source changed or sorted). The active
    /// row follows its key when the source has `row_key`; the selection
    /// is cleared.
    pub fn reload(t: *Table) void {
        const n = t.source.rowCount();
        if (t.source.vtable.row_key) |f| if (t.active_key) |k| {
            var i: u64 = 0;
            while (i < n) : (i += 1) if (f(t.source.ptr, i) == k) {
                t.active_row = i;
                break;
            };
        };
        if (t.active_row >= n) t.active_row = n -| 1;
        t.ranges.clearRetainingCapacity();
        t.markDirty();
    }

    // -- column geometry --------------------------------------------------------

    fn layoutColumns(t: *Table) void {
        const cols = t.props.columns;
        t.frozen_n = 0;
        t.frozen_w = 0;
        while (t.frozen_n < cols.len and cols[t.frozen_n].frozen) : (t.frozen_n += 1) t.frozen_w += cols[t.frozen_n].width;
        t.xs.clearRetainingCapacity();
        t.xs.ensureTotalCapacity(t.gpa, cols.len - t.frozen_n + 1) catch return;
        var x: f32 = 0;
        t.xs.appendAssumeCapacity(0);
        for (cols[t.frozen_n..]) |c| {
            x += c.width;
            t.xs.appendAssumeCapacity(x);
        }
    }

    fn scrollWidth(t: *const Table) f32 {
        const xs = t.xs.items;
        return if (xs.len == 0) 0 else xs[xs.len - 1];
    }

    fn clampScroll(t: *Table) void {
        t.scroll_x = std.math.clamp(t.scroll_x, 0, @max(0, t.scrollWidth() - t.pane_w));
    }

    /// Scrolls the columns sideways by `dx`; true when they moved.
    pub fn scrollXBy(t: *Table, dx: f32) bool {
        const before = t.scroll_x;
        t.scroll_x += dx;
        t.clampScroll();
        if (t.scroll_x == before) return false;
        t.markDirty();
        return true;
    }

    /// How many of `xs` are below `v` (or at most `v` with `inclusive`).
    fn countBelow(xs: []const f32, v: f32, inclusive: bool) usize {
        var lo: usize = 0;
        var hi: usize = xs.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (xs[mid] < v or (inclusive and xs[mid] == v)) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// The non-frozen columns (indices from the first one) to build.
    fn visibleCols(t: *const Table) struct { a: usize, b: usize } {
        const xs = t.xs.items;
        if (xs.len < 2) return .{ .a = 0, .b = 0 };
        const n = xs.len - 1;
        const a = countBelow(xs[1..], t.scroll_x, true);
        const b = countBelow(xs[0..n], t.scroll_x + t.pane_w, false);
        return .{ .a = a -| 1, .b = @min(n, b + 1) };
    }

    /// A column's left edge relative to the table.
    fn colX(t: *const Table, i: usize) f32 {
        const cols = t.props.columns;
        if (i < t.frozen_n) {
            var x: f32 = 0;
            for (cols[0..i]) |c| x += c.width;
            return x;
        }
        return t.frozen_w + t.xs.items[i - t.frozen_n] - t.scroll_x;
    }

    // -- selection --------------------------------------------------------------

    pub fn isSelected(t: *const Table, row: u64) bool {
        for (t.ranges.items) |r| if (row >= r.lo and row <= r.hi) return true;
        return false;
    }

    /// The selected row ranges, unordered.
    pub fn selection(t: *const Table) []const Range {
        return t.ranges.items;
    }

    fn selectionChanged(t: *Table) void {
        if (t.props.on_selection) |h| h.f(h.ctx, t);
    }

    fn setRange(t: *Table, lo: u64, hi: u64) void {
        t.ranges.clearRetainingCapacity();
        t.ranges.append(t.gpa, .{ .lo = lo, .hi = hi }) catch {};
    }

    /// Adds `row` to the selection, or takes it out.
    fn toggleRow(t: *Table, row: u64) void {
        for (t.ranges.items, 0..) |r, i| if (row >= r.lo and row <= r.hi) {
            if (r.lo == r.hi) {
                _ = t.ranges.orderedRemove(i);
            } else if (row == r.lo) {
                t.ranges.items[i].lo += 1;
            } else if (row == r.hi) {
                t.ranges.items[i].hi -= 1;
            } else {
                t.ranges.items[i].hi = row - 1;
                t.ranges.append(t.gpa, .{ .lo = row + 1, .hi = r.hi }) catch {};
            }
            return;
        };
        t.ranges.append(t.gpa, .{ .lo = row, .hi = row }) catch {};
    }

    /// Selects every row.
    pub fn selectAll(t: *Table) void {
        const n = t.source.rowCount();
        if (n == 0 or t.props.selection != .row) return;
        t.setRange(0, n - 1);
        t.selectionChanged();
        t.markDirty();
    }

    /// How a move changes the selection.
    const Sel = enum { replace, extend, keep, toggle };

    /// Makes cell (`row`, column index `col`) active and updates the
    /// selection.
    pub fn moveTo(t: *Table, row: u64, col: usize, how: Sel) void {
        const n = t.source.rowCount();
        if (n == 0 or t.props.columns.len == 0) return;
        t.active_row = @min(row, n - 1);
        t.active_col = @min(col, t.props.columns.len - 1);
        if (t.source.vtable.row_key) |f| t.active_key = f(t.source.ptr, t.active_row);
        const r = t.active_row;
        if (t.props.selection == .row) switch (how) {
            .keep => {},
            .replace => {
                t.setRange(r, r);
                t.anchor = r;
                t.selectionChanged();
            },
            .toggle => {
                t.toggleRow(r);
                t.anchor = r;
                t.selectionChanged();
            },
            .extend => {
                t.setRange(@min(t.anchor, r), @max(t.anchor, r));
                t.selectionChanged();
            },
        };
        t.reveal(t.active_row, t.active_col);
        t.markDirty();
    }

    fn listOptions(t: *const Table) scroll.ListOptions {
        return .{ .count = @intCast(t.source.rowCount()), .row_h = t.props.row_h };
    }

    /// Scrolls cell (`row`, column index `col`) into view.
    pub fn reveal(t: *Table, row: u64, col: usize) void {
        t.layoutColumns();
        if (col >= t.frozen_n and col < t.props.columns.len) {
            const k = col - t.frozen_n;
            const x0 = t.xs.items[k];
            const x1 = t.xs.items[k + 1];
            if (x0 < t.scroll_x) {
                t.scroll_x = x0;
            } else if (x1 > t.scroll_x + t.pane_w) t.scroll_x = x1 - t.pane_w;
            t.clampScroll();
        }
        const w = t.win orelse return;
        if (t.list.isNone() or !w.store.valid(t.list)) return;
        scroll.scrollToRow(w, t.list, t.listOptions(), @intCast(row));
    }

    fn pageRows(t: *const Table) u64 {
        const w = t.win orelse return 10;
        if (t.list.isNone() or !w.store.valid(t.list)) return 10;
        const h = w.store.relRect(t.list).h;
        return @max(1, @as(u64, @intFromFloat(@floor(h / t.props.row_h))) -| 1);
    }

    /// Handles a key on the table; true when used.
    pub fn onKey(t: *Table, k: event_mod.KeyPress) bool {
        if (k.action == .release or k.mods.alt) return false;
        const n = t.source.rowCount();
        const nc = t.props.columns.len;
        if (n == 0 or nc == 0) return false;
        const r = @min(t.active_row, n - 1);
        const c = @min(t.active_col, nc - 1);
        const how: Sel = if (k.mods.shift) .extend else if (k.mods.ctrl) .keep else .replace;
        // Ctrl+Home/End jump rather than move without selecting.
        const jump: Sel = if (k.mods.shift) .extend else .replace;
        switch (k.key) {
            .arrow_down => t.moveTo(@min(n - 1, r + 1), c, how),
            .arrow_up => t.moveTo(r -| 1, c, how),
            .arrow_right => t.moveTo(r, @min(nc - 1, c + 1), .keep),
            .arrow_left => t.moveTo(r, c -| 1, .keep),
            .home => if (k.mods.ctrl) t.moveTo(0, 0, jump) else t.moveTo(r, 0, .keep),
            .end => if (k.mods.ctrl) t.moveTo(n - 1, nc - 1, jump) else t.moveTo(r, nc - 1, .keep),
            .page_down => t.moveTo(@min(n - 1, r + t.pageRows()), c, how),
            .page_up => t.moveTo(r -| t.pageRows(), c, how),
            .space => {
                if (!k.mods.shift or t.props.selection != .row) return false;
                if (!t.isSelected(r)) t.toggleRow(r);
                t.anchor = r;
                t.selectionChanged();
                t.markDirty();
            },
            .key_a => {
                if (!k.mods.ctrl or t.props.selection != .row) return false;
                t.selectAll();
            },
            .enter, .numpad_enter => {
                const h = t.props.on_activate orelse return false;
                h.f(h.ctx, r, t.props.columns[c].id);
            },
            .escape => {
                if (t.ranges.items.len == 0) return false;
                t.ranges.clearRetainingCapacity();
                t.selectionChanged();
                t.markDirty();
            },
            else => return false,
        }
        return true;
    }

    /// The selection as tab-separated text: the selected rows (row
    /// selection) or the active cell, in column order. Caller frees.
    pub fn copyText(t: *const Table, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const n = t.source.rowCount();
        if (n == 0 or t.props.columns.len == 0) return out.toOwnedSlice(gpa);
        switch (t.props.selection) {
            .none => {},
            .cell => try appendClean(gpa, &out, t.source.text(t.active_row, t.props.columns[@min(t.active_col, t.props.columns.len - 1)].id)),
            .row => {
                const rs = try gpa.dupe(Range, t.ranges.items);
                defer gpa.free(rs);
                std.mem.sort(Range, rs, {}, struct {
                    fn lt(_: void, a: Range, b: Range) bool {
                        return a.lo < b.lo;
                    }
                }.lt);
                for (rs) |rg| {
                    var row = rg.lo;
                    while (row <= @min(rg.hi, n - 1)) : (row += 1) {
                        if (out.items.len > 0) try out.append(gpa, '\n');
                        for (t.props.columns, 0..) |c, i| {
                            if (i > 0) try out.append(gpa, '\t');
                            try appendClean(gpa, &out, t.source.text(row, c.id));
                        }
                    }
                }
            },
        }
        return out.toOwnedSlice(gpa);
    }

    /// Appends `s` with tabs and line breaks turned into spaces.
    fn appendClean(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
        const start = out.items.len;
        try out.appendSlice(gpa, s);
        for (out.items[start..]) |*ch| if (ch.* == '\t' or ch.* == '\n' or ch.* == '\r') {
            ch.* = ' ';
        };
    }

    /// A press on cell (`row`, column index `col`).
    fn onCellPointer(t: *Table, row: u64, col: usize, p: event_mod.Pointer) void {
        if (p.button != .left) {
            if (!t.isSelected(row)) t.moveTo(row, col, .replace);
            return;
        }
        if (p.clicks >= 2) {
            if (t.props.on_activate) |h| h.f(h.ctx, row, t.props.columns[col].id);
            return;
        }
        t.moveTo(row, col, if (p.mods.shift) .extend else if (p.mods.ctrl) .toggle else .replace);
    }

    // -- columns ------------------------------------------------------------------

    /// Sets column `i`'s width, clamped to its range.
    pub fn setWidth(t: *Table, i: usize, w: f32) void {
        const c = &t.props.columns[i];
        c.width = std.math.clamp(w, c.min_w, c.max_w);
        t.layoutColumns();
        t.clampScroll();
        t.markDirty();
    }

    /// Fits column `i` to its header and the built rows (at most
    /// `autofit_rows`), measured with `ts` at `size`.
    pub fn autofit(t: *Table, i: usize, ts: text_mod.TextSystem, size: f32) void {
        const c = t.props.columns[i];
        var w = ts.width(.{ .size = size, .weight = 600 }, c.title) + if (c.sortable) sort_w else 0;
        if (t.source.vtable.cell_text) |f| {
            const end = @min(t.end, t.first + autofit_rows, t.source.rowCount());
            var r = t.first;
            while (r < end) : (r += 1) w = @max(w, ts.width(.{ .size = size }, f(t.source.ptr, r, c.id)));
        }
        t.setWidth(i, @ceil(w + 2 * cell_pad + 1));
    }

    /// Moves column `from` to insertion index `to` (0..len), within its
    /// group (frozen or scrolling).
    pub fn moveColumn(t: *Table, from: usize, to_: usize) void {
        const cols = t.props.columns;
        if (from >= cols.len) return;
        const frozen = from < t.frozen_n;
        var to = if (frozen) @min(to_, t.frozen_n) else std.math.clamp(to_, t.frozen_n, cols.len);
        if (to > from) to -= 1;
        if (to == from) return;
        const active_id = if (t.active_col < cols.len) cols[t.active_col].id else null;
        const c = cols[from];
        if (to > from) {
            std.mem.copyForwards(Column, cols[from..to], cols[from + 1 .. to + 1]);
        } else std.mem.copyBackwards(Column, cols[to + 1 .. from + 1], cols[to..from]);
        cols[to] = c;
        if (active_id) |id| for (cols, 0..) |col, i| if (col.id == id) {
            t.active_col = i;
        };
        t.layoutColumns();
        t.markDirty();
    }

    /// Cycles column `i`'s sort: ascending, descending, unsorted.
    pub fn cycleSort(t: *Table, i: usize) void {
        const c = t.props.columns[i];
        if (!c.sortable) return;
        t.sort = if (t.sort) |s|
            (if (s.col != c.id) Sort{ .col = c.id } else if (!s.desc) Sort{ .col = c.id, .desc = true } else null)
        else
            .{ .col = c.id };
        if (t.props.on_sort) |h| h.f(h.ctx, t, t.sort);
        t.markDirty();
    }

    fn sortOf(t: *const Table, id: u32) widget.SortState {
        const s = t.sort orelse return .none;
        if (s.col != id) return .none;
        return if (s.desc) .descending else .ascending;
    }

    /// The insertion index for a column dropped at table-relative `x`.
    fn dropIndex(t: *const Table, x: f32) usize {
        const cols = t.props.columns;
        var i: usize = 0;
        while (i < cols.len) : (i += 1) {
            if (x < t.colX(i) + cols[i].width / 2) return i;
        }
        return cols.len;
    }

    fn onHeaderDown(t: *Table, ec: *event_mod.EventCx, i: usize, p: event_mod.Pointer) void {
        if (p.button != .left) return;
        const local = ec.local(p.pos);
        const c = t.props.columns[i];
        const on_edge = c.resizable and local.x >= c.width - resize_zone;
        if (on_edge and p.clicks >= 2) {
            t.drag = .none;
            t.autofit(i, ec.textSystem(), ec.theme().dim(.font_size));
            return;
        }
        t.drag = if (on_edge)
            .{ .resize = .{ .col = i, .x0 = p.pos.x, .w0 = c.width } }
        else
            .{ .press = .{ .col = i, .x0 = p.pos.x } };
    }

    fn onHeaderMove(t: *Table, ec: *event_mod.EventCx, i: usize, p: event_mod.Pointer) void {
        switch (t.drag) {
            .none => {
                const c = t.props.columns[i];
                const on_edge = c.resizable and ec.local(p.pos).x >= c.width - resize_zone;
                ec.setCursor(if (on_edge) .col_resize else .default);
            },
            .resize => |d| {
                ec.setCursor(.col_resize);
                t.setWidth(d.col, d.w0 + p.pos.x - d.x0);
            },
            .press => |*d| {
                if (!t.props.reorder_columns) return;
                if (!d.moved and @abs(p.pos.x - d.x0) < drag_threshold) return;
                d.moved = true;
                ec.setCursor(.grabbing);
                const tr = ec.rectOf(t.node);
                const drop = t.dropIndex(p.pos.x - tr.x);
                if (t.drop == null or t.drop.? != drop) {
                    t.drop = drop;
                    t.markDirty();
                }
            },
        }
    }

    fn onHeaderUp(t: *Table, ec: *event_mod.EventCx) void {
        const d = t.drag;
        t.drag = .none;
        switch (d) {
            .none, .resize => {},
            .press => |pr| {
                if (pr.moved) {
                    if (t.drop) |to| t.moveColumn(pr.col, to);
                    t.drop = null;
                    ec.setCursor(.default);
                    t.markDirty();
                } else t.cycleSort(pr.col);
            },
        }
    }

    // -- building -----------------------------------------------------------------

    /// Builds the table into the current view.
    pub fn build(t: *Table, ui: *Ui) void {
        const win = ui.window();
        t.win = win;
        t.view = ui.currentView();
        t.layoutColumns();
        const width = if (!t.node.isNone() and win.store.valid(t.node)) win.store.relRect(t.node).w else win.size.w;
        t.pane_w = @max(0, width - t.frozen_w);
        t.clampScroll();
        const n = t.source.rowCount();
        _ = ui.begin(TableBox, .{ .t = t, .label = t.props.label, .rows = n + 1, .cols = @intCast(t.props.columns.len) });
        defer ui.end(TableBox);
        t.node = ui.current();

        ui.id(@as([]const u8, "header"));
        _ = ui.begin(TableRow, .{ .t = t, .header = true, .h = t.props.header_h, .shadow = t.scroll_x > 0 and t.frozen_n > 0 });
        t.line(ui, null);
        ui.end(TableRow);

        var opts = t.listOptions();
        opts.style = .{ .grow = 1 };
        opts.test_id = t.props.test_id;
        const vis = scroll.virtualList(ui, opts, t, buildRow);
        t.list = vis.node;
        t.first = vis.first;
        t.end = vis.end;
    }

    fn buildRow(t: *Table, ui: *Ui, i: usize) void {
        const r: u64 = i;
        _ = ui.begin(TableRow, .{
            .t = t,
            .index = r,
            .selected = t.props.selection == .row and t.isSelected(r),
            .striped = t.props.striped and r % 2 == 1,
            .shadow = t.scroll_x > 0 and t.frozen_n > 0,
        });
        defer ui.end(TableRow);
        t.line(ui, r);
    }

    /// The cells of a row (or the header): frozen ones, then the visible
    /// scrolling ones placed in a clipped pane.
    fn line(t: *Table, ui: *Ui, r: ?u64) void {
        const cols = t.props.columns;
        for (cols[0..t.frozen_n], 0..) |c, i| t.cell(ui, r, i, c, 0, false);
        ui.id(@as([]const u8, "pane"));
        ui.open(.{ .style = .{ .grow = 1, .align_self = .stretch, .clip = true } });
        defer ui.close();
        const vc = t.visibleCols();
        var k = vc.a;
        while (k < vc.b) : (k += 1) {
            const i = t.frozen_n + k;
            t.cell(ui, r, i, cols[i], t.xs.items[k] - t.scroll_x, true);
        }
    }

    fn cell(t: *Table, ui: *Ui, r: ?u64, i: usize, c: Column, x: f32, abs: bool) void {
        ui.id(@as(u64, c.id));
        const col: u32 = @intCast(i);
        const rr = r orelse {
            const after = t.drop != null and t.drop.? == t.props.columns.len and i + 1 == t.props.columns.len;
            _ = ui.leaf(TableHeaderCell, .{
                .t = t,
                .col = col,
                .title = c.title,
                .x = x,
                .w = c.width,
                .abs = abs,
                .align_ = c.align_,
                .sort = t.sortOf(c.id),
                .drop_before = t.drop != null and t.drop.? == i,
                .drop_after = after,
            });
            return;
        };
        const custom = t.source.vtable.build_cell;
        const active = rr == t.active_row and i == t.active_col;
        _ = ui.begin(TableCell, .{
            .t = t,
            .row = rr,
            .col = col,
            .x = x,
            .w = c.width,
            .abs = abs,
            .text = t.source.text(rr, c.id),
            .draw_text = custom == null,
            .align_ = c.align_,
            .active = active,
            .focused = t.focused,
            .selected = active and t.props.selection == .cell,
        });
        defer ui.end(TableCell);
        if (custom) |f| f(t.source.ptr, ui, rr, c.id);
    }
};

/// The table's focusable container.
pub const TableBox = struct {
    pub const name = "grid";
    pub const focusable = true;

    pub const Props = struct {
        t: *Table,
        label: []const u8 = "",
        rows: u64 = 0,
        cols: u32 = 0,
    };

    pub fn style(props: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        var st = props.t.props.style;
        st.dir = .column;
        return st;
    }

    pub fn event(ec: *event_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const event_mod.InputEvent) bool {
        const t = props.t;
        if (ec.phase == .capture) return false;
        switch (ev.*) {
            .key => |k| {
                if (k.key == .key_c and k.mods.ctrl and !k.mods.alt and k.action != .release) {
                    const s = t.copyText(ec.allocator()) catch return true;
                    defer ec.allocator().free(s);
                    if (s.len > 0) ec.setClipboard(s);
                    return true;
                }
                return t.onKey(k);
            },
            .scroll => |sc| {
                if (sc.dx == 0) return false;
                const k: f32 = if (sc.precise) 1 else Window.wheel_step;
                _ = t.scrollXBy(sc.dx * k);
                return sc.dy == 0;
            },
            .focus_gained, .focus_lost => {
                t.focused = ev.* == .focus_gained;
                t.markDirty();
                return false;
            },
            else => return false,
        }
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .grid, .name = props.label, .row_count = props.rows, .col_count = props.cols };
    }
};

/// A row (or the header row): background, selection and the frozen
/// columns' edge.
pub const TableRow = struct {
    pub const name = "row";

    pub const Props = struct {
        t: *Table,
        index: u64 = 0,
        header: bool = false,
        /// Header height (data rows fill the list's row).
        h: f32 = 0,
        selected: bool = false,
        striped: bool = false,
        /// Columns are scrolled under the frozen ones.
        shadow: bool = false,
    };

    pub fn style(props: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        if (props.header) return .{ .h = .{ .px = props.h }, .shrink = 0, .dir = .row, .clip = true };
        return .{ .grow = 1, .align_self = .stretch, .dir = .row };
    }

    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        if (props.header) {
            pc.fill(r, .bg_elevated, 0);
            pc.fill(.{ .x = r.x, .y = r.bottom() - 1, .w = r.w, .h = 1 }, .border, 0);
        } else if (props.selected) {
            pc.fill(r, .selection_bg, 0);
        } else if (pc.state.hovered) {
            pc.fill(r, .hover_bg, 0);
        } else if (props.striped) pc.fill(r, .bg_sunken, 0);
        if (props.shadow) pc.fill(.{ .x = r.x + props.t.frozen_w, .y = r.y, .w = 1, .h = r.h }, .shadow, 0);
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{
            .role = .row,
            .row_index = if (props.header) 1 else props.index + 2,
            .selected = if (props.header or props.t.props.selection != .row) null else props.selected,
        };
    }
};

fn cellStyle(abs: bool, x: f32, w: f32) style_mod.Style {
    var st: style_mod.Style = .{
        .w = .{ .px = w },
        .shrink = 0,
        .align_self = .stretch,
        .dir = .row,
        .align_items = .center,
        .padding = .{ .l = cell_pad, .r = cell_pad },
        .clip = true,
    };
    if (abs) {
        st.position = .absolute;
        st.inset = .{ .l = x, .t = 0, .b = 0 };
    }
    return st;
}

fn textRect(r: Rect) Rect {
    return .{ .x = r.x + cell_pad, .y = r.y, .w = @max(0, r.w - 2 * cell_pad), .h = r.h };
}

/// A data cell: its text (or the source's content), the active cell's
/// ring and the cell selection.
pub const TableCell = struct {
    pub const name = "gridcell";

    pub const Props = struct {
        t: *Table,
        row: u64,
        /// The column's slice index.
        col: u32,
        x: f32 = 0,
        w: f32,
        abs: bool = false,
        text: []const u8 = "",
        draw_text: bool = true,
        align_: Align = .start,
        active: bool = false,
        focused: bool = false,
        selected: bool = false,
    };

    pub fn style(props: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        return cellStyle(props.abs, props.x, props.w);
    }

    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        if (props.selected) pc.fill(r, .selection_bg, 0);
        if (props.active and props.focused) pc.border(r, 1, pc.color(.focus_ring), 0);
        if (props.draw_text) pc.textBox(props.text, .{ .size = pc.theme.dim(.font_size) }, pc.color(.fg), textRect(r), false, props.align_);
    }

    pub fn event(ec: *event_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const event_mod.InputEvent) bool {
        switch (ev.*) {
            .pointer_down => |p| {
                if (ec.phase == .capture) return false;
                props.t.onCellPointer(props.row, props.col, p);
                return true;
            },
            else => return false,
        }
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{
            .role = .gridcell,
            .name = props.text,
            .row_index = props.row + 2,
            .col_index = props.col + 1,
            .selected = if (props.t.props.selection == .cell) props.selected else null,
        };
    }
};

/// A column header: title, sort arrow, resize edge and drop marker.
pub const TableHeaderCell = struct {
    pub const name = "columnheader";

    pub const Props = struct {
        t: *Table,
        /// The column's slice index.
        col: u32,
        title: []const u8,
        x: f32 = 0,
        w: f32,
        abs: bool = false,
        align_: Align = .start,
        sort: widget.SortState = .none,
        drop_before: bool = false,
        drop_after: bool = false,
    };

    pub fn style(props: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        return cellStyle(props.abs, props.x, props.w);
    }

    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        if (pc.state.hovered) pc.fill(r, .hover_bg, 0);
        pc.fill(.{ .x = r.right() - 1, .y = r.y + 4, .w = 1, .h = @max(0, r.h - 8) }, .border, 0);
        const st: text_mod.TextStyle = .{ .size = pc.theme.dim(.font_size), .weight = 600 };
        var tr = textRect(r);
        if (props.sort != .none) {
            tr.w = @max(0, tr.w - sort_w);
            const glyph = if (props.sort == .ascending) "\u{25b4}" else "\u{25be}";
            pc.textBox(glyph, st, pc.color(.fg_muted), .{ .x = tr.right(), .y = r.y, .w = sort_w, .h = r.h }, false, .center);
        }
        pc.textBox(props.title, st, pc.color(.fg), tr, false, props.align_);
        if (props.drop_before) pc.fill(.{ .x = r.x, .y = r.y, .w = 2, .h = r.h }, .accent, 0);
        if (props.drop_after) pc.fill(.{ .x = r.right() - 2, .y = r.y, .w = 2, .h = r.h }, .accent, 0);
    }

    pub fn event(ec: *event_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const event_mod.InputEvent) bool {
        if (ec.phase == .capture) return false;
        const t = props.t;
        if (props.col >= t.props.columns.len) return false;
        switch (ev.*) {
            .pointer_down => |p| t.onHeaderDown(ec, props.col, p),
            .pointer_move => |p| t.onHeaderMove(ec, props.col, p),
            .pointer_up => t.onHeaderUp(ec),
            else => return false,
        }
        return true;
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .columnheader, .name = props.title, .row_index = 1, .col_index = props.col + 1, .sort = props.sort };
    }
};
