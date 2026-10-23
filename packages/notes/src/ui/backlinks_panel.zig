//! The backlinks pane (E08.F06.S01.T04): linked mentions grouped by source
//! note with the linking line, and unlinked mentions computed when the
//! section is opened, each with a "Link" action.

const std = @import("std");
const zg_gui = @import("zg_gui");
const sidebar = @import("notes_sidebar.zig");

const Ui = zg_gui.Ui;
const controls = zg_gui.w.controls;

pub fn build(ui: *Ui, v: *sidebar.SidebarView) void {
    const m = v.m;
    if (m.active == null) return;
    sidebar.section(ui, "Backlinks");
    defer ui.close();
    const th = ui.theme();
    var total: usize = 0;
    for (m.backlinks) |g| total += @max(g.rows.len, 1);
    ui.textf("{d} linked mention{s}", .{ total, if (total == 1) "" else "s" }, .{ .color = .fg_muted });
    for (m.backlinks) |g| {
        ui.id(g.path);
        ui.open(.{ .style = .{ .dir = .column, .gap = th.dim(.space_xs) } });
        defer ui.close();
        ui.id(@as([]const u8, "title"));
        ui.open(.{ .role = .link, .label = g.title, .hit = true, .style = .{ .dir = .row, .gap = th.dim(.space_sm) } });
        ui.text(g.title, .{ .style = .{ .weight = 600 }, .wrap = false });
        ui.text(g.path, .{ .color = .fg_muted, .wrap = false });
        if (ui.response().clicked) v.open(g.path, null);
        ui.close();
        for (g.rows, 0..) |r, i| {
            ui.id(@as(u64, i));
            const label = std.fmt.allocPrint(ui.arena(), "Linked from {s}: {s}", .{ g.title, std.mem.trim(u8, r.text, " \t") }) catch g.title;
            ui.open(.{ .role = .listitem, .label = label, .hit = true, .style = .{ .padding = .xy(th.dim(.space_md), 0) } });
            sidebar.highlighted(ui, r.text, r.highlight);
            if (ui.response().clicked) v.open(g.path, r.range);
            ui.close();
        }
    }

    // Unlinked mentions: computed on demand (a vault search).
    ui.id(@as([]const u8, "unlinked"));
    ui.open(.{ .role = .group, .label = "Unlinked mentions", .style = .{ .dir = .column, .gap = th.dim(.space_xs) } });
    defer ui.close();
    if (controls.button(ui, .{ .label = if (v.show_unlinked) "Hide unlinked mentions" else "Show unlinked mentions" }).clicked) {
        v.show_unlinked = !v.show_unlinked;
        if (v.show_unlinked) m.requestUnlinked() catch |e| v.fail(e);
    }
    if (!v.show_unlinked) return;
    switch (m.unlinkedState()) {
        .idle => if (controls.button(ui, .{ .label = "Search again" }).clicked) m.requestUnlinked() catch |e| v.fail(e),
        .running => ui.text("Searching the vault\u{2026}", .{ .color = .fg_muted }),
        .failed => |msg| ui.textf("Search failed: {s}", .{msg}, .{ .color = .danger }),
        .done => |rows| {
            ui.textf("{d} unlinked mention{s}", .{ rows.len, if (rows.len == 1) "" else "s" }, .{ .color = .fg_muted });
            if (rows.len > 1 and controls.button(ui, .{ .label = "Link all" }).clicked) {
                _ = m.linkAll() catch |e| v.fail(e);
                return;
            }
            for (rows, 0..) |r, i| {
                ui.id(@as(u64, i));
                const label = std.fmt.allocPrint(ui.arena(), "Mentioned in {s}: {s}", .{ r.source_title, std.mem.trim(u8, r.text, " \t") }) catch r.source_title;
                ui.open(.{ .role = .listitem, .label = label, .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center } });
                defer ui.close();
                ui.open(.{ .hit = true, .style = .{ .grow = 1, .dir = .column } });
                ui.text(r.source_title, .{ .style = .{ .weight = 600 }, .wrap = false });
                sidebar.highlighted(ui, r.text, r.highlight);
                if (ui.response().clicked) v.open(r.source_path, r.mention.range);
                ui.close();
                if (controls.button(ui, .{ .label = "Link" }).clicked) {
                    _ = m.linkMention(r) catch |e| v.fail(e);
                    return;
                }
            }
        },
    }
}
