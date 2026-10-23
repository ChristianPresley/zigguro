//! The tags pane (E08.F06.S01.T04): the vault's tag tree with counts, a
//! filter and a name/count sort. Opening a tag runs a `tag:` search.

const std = @import("std");
const zg_gui = @import("zg_gui");
const sidebar = @import("notes_sidebar.zig");

const Ui = zg_gui.Ui;
const controls = zg_gui.w.controls;

pub fn build(ui: *Ui, v: *sidebar.SidebarView) void {
    sidebar.section(ui, "Tags");
    defer ui.close();
    const th = ui.theme();
    ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center } });
    if (zg_gui.w.text_field.textField(ui, .{ .buffer = &v.tag_filter, .placeholder = "Filter tags", .a11y_label = "Filter tags" }).changed)
        v.m.setTagFilter(v.tag_filter.slice()) catch |e| v.fail(e);
    const by_count = v.m.tag_sort == .count;
    if (controls.button(ui, .{ .label = if (by_count) "Sort by name" else "Sort by count" }).clicked)
        v.m.setTagSort(if (by_count) .name else .count) catch |e| v.fail(e);
    ui.close();
    if (v.m.tag_roots.len == 0) {
        ui.text(if (v.tag_filter.slice().len > 0) "No matching tags." else "No tags.", .{ .color = .fg_muted });
        return;
    }
    const rows: f32 = @floatFromInt(@min(v.tags.flat.len(), 12));
    ui.open(.{ .style = .{ .dir = .column, .h = .{ .px = @max(rows, 1) * v.tags.props.row_h + 4 } } });
    v.tags.build(ui);
    ui.close();
}

/// Enter or double click on a tag row.
pub fn onOpen(ctx: *anyopaque, node: u64) void {
    const v: *sidebar.SidebarView = @ptrCast(@alignCast(ctx));
    const t = v.m.tagOf(node) orelse return;
    const h = v.o.search orelse return;
    var buf: [256]u8 = undefined;
    const q = std.fmt.bufPrint(&buf, "tag:#{s}", .{t.full}) catch return;
    h.f(h.ctx, q);
}
