//! Markdown tables (E04.F06.S01.T02): each column as wide as its widest
//! cell (capped at 400 px, never under its longest word), cells aligned
//! from the GFM delimiter row, the header row emphasised, the whole table
//! scrolling sideways when wider than the view.

const std = @import("std");
const ast = @import("ast.zig");
const rich = @import("rich.zig");
const view_mod = @import("view.zig");
const paint_cx = @import("../paint/paint_cx.zig");

const none = ast.none;

/// Column widths above this wrap.
pub const max_col_w: f32 = 400;
/// Horizontal cell padding on each side.
pub const cell_pad: f32 = 8;

/// The width of each column of table `i` (content plus padding), into
/// `out`; returns the column count.
pub fn columnWidths(b: *view_mod.Builder, i: u32, out: []f32) usize {
    const d = b.s.doc;
    var cols: usize = 0;
    var mins: [64]f32 = [_]f32{0} ** 64;
    @memset(out, 0);
    var row = d.blocks.items[i].first_child;
    while (row != none) : (row = d.blocks.items[row].next) {
        const header = d.blocks.items[row].level == 1;
        var cell = d.blocks.items[row].first_child;
        var k: usize = 0;
        while (cell != none and k < out.len) : ({
            cell = d.blocks.items[cell].next;
            k += 1;
        }) {
            const e = b.s.entry(cell) orelse continue;
            const cw = rich.contentWidths(.{ .ts = b.ts, .base = cellStyle(b, header) }, &e.flat);
            out[k] = @max(out[k], cw.max);
            if (k < mins.len) mins[k] = @max(mins[k], cw.min);
        }
        cols = @max(cols, k);
    }
    for (out[0..cols], 0..) |*w, k| {
        const lo = if (k < mins.len) mins[k] else 0;
        w.* = @max(@min(w.*, max_col_w), lo) + 2 * cell_pad;
    }
    return cols;
}

fn cellStyle(b: *const view_mod.Builder, header: bool) @import("../paint/text.zig").TextStyle {
    var st = b.base;
    if (header) st.weight = 600;
    return st;
}

/// Builds table block `i`.
pub fn build(b: *view_mod.Builder, i: u32) void {
    const ui = b.ui;
    const d = b.s.doc;
    const th = ui.theme();
    var widths: [64]f32 = undefined;
    const cols = columnWidths(b, i, &widths);
    ui.open(.{ .style = .{ .dir = .column, .scroll_x = true, .align_items = .start }, .test_id = "md-table" });
    defer ui.close();
    ui.open(.{ .style = .{ .dir = .column, .border = .{ .token = .border }, .border_w = th.dim(.border_w), .radius = th.dim(.radius_md), .clip = true, .shrink = 0 }, .role = .group, .label = "Table" });
    defer ui.close();
    var row = d.blocks.items[i].first_child;
    var r: u64 = 0;
    while (row != none) : ({
        row = d.blocks.items[row].next;
        r += 1;
    }) {
        const header = d.blocks.items[row].level == 1;
        ui.id(r);
        ui.open(.{ .style = .{ .dir = .row, .bg = if (header) .{ .token = .bg_elevated } else .none, .shrink = 0 } });
        defer ui.close();
        var cell = d.blocks.items[row].first_child;
        var k: usize = 0;
        while (k < cols) : (k += 1) {
            ui.id(@as(u64, k));
            ui.open(.{ .style = .{ .w = .{ .px = widths[k] }, .shrink = 0, .dir = .column, .padding = .xy(cell_pad, 4), .border = if (header or r > 0) .{ .token = .border } else .none, .border_w = 0 } });
            if (cell != none) {
                const al: paint_cx.TextAlign = switch (d.blocks.items[cell].align_) {
                    .none, .left => .start,
                    .center => .center,
                    .right => .end,
                };
                b.leaf(cell, cellStyle(b, header), .fg, true, al);
                cell = d.blocks.items[cell].next;
            }
            ui.close();
        }
    }
}
