//! The outgoing links pane (E08.F06.S01.T04): the active note's links,
//! resolved, ambiguous (with their candidates) or unresolved (with
//! "Create note").

const std = @import("std");
const zg_gui = @import("zg_gui");
const sidebar = @import("notes_sidebar.zig");

const Ui = zg_gui.Ui;
const controls = zg_gui.w.controls;

pub fn build(ui: *Ui, v: *sidebar.SidebarView) void {
    const m = v.m;
    if (m.active == null) return;
    sidebar.section(ui, "Outgoing links");
    defer ui.close();
    const th = ui.theme();
    if (m.outgoing.len == 0) ui.text("No links.", .{ .color = .fg_muted });
    for (m.outgoing, 0..) |l, i| {
        ui.id(@as(u64, i));
        const what = switch (l.kind) {
            .note, .attachment, .self => "",
            .ambiguous => " (ambiguous)",
            .unresolved => " (unresolved)",
        };
        const label = std.fmt.allocPrint(ui.arena(), "{s}{s}", .{ l.target, what }) catch l.target;
        ui.open(.{ .role = .listitem, .label = label, .style = .{ .dir = .column, .gap = th.dim(.space_xs) } });
        defer ui.close();
        ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center } });
        ui.open(.{ .hit = true, .style = .{ .grow = 1, .dir = .row, .gap = th.dim(.space_sm) } });
        ui.text(l.target, .{ .color = if (l.kind == .unresolved) .fg_muted else .fg_link, .wrap = false });
        if (l.path) |p| if (!std.mem.eql(u8, p, l.target)) ui.text(p, .{ .color = .fg_muted, .wrap = false });
        if (l.kind == .ambiguous) ui.text("ambiguous", .{ .color = .warning, .wrap = false });
        if (ui.response().clicked) if (l.path) |p| v.open(p, null);
        ui.close();
        if (l.create_path) |p| {
            const b = std.fmt.allocPrint(ui.arena(), "Create {s}", .{p}) catch "Create note";
            if (controls.button(ui, .{ .label = b }).clicked) {
                _ = m.createNote(p) catch |e| v.fail(e);
                v.open(p, null);
            }
        }
        ui.close();
        for (l.candidates, 0..) |c, k| {
            ui.id(@as(u64, k));
            ui.open(.{ .role = .link, .label = c, .hit = true, .style = .{ .padding = .xy(th.dim(.space_md), 0) } });
            ui.text(c, .{ .color = .fg_muted, .wrap = false });
            if (ui.response().clicked) v.open(c, null);
            ui.close();
        }
    }
}
