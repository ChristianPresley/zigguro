//! The properties editor (E08.F06.S01.T04): a typed widget per property of
//! the active note: checkboxes, list chips (tags, aliases, lists), and
//! text fields for text, numbers, dates and datetimes (`YYYY-MM-DD`,
//! checked on submit; a month grid is later polish). A value that does
//! not fit the registry type shows a warning and stays editable as text.
//! Every commit goes through `applyPropEdits`, which rewrites only the
//! edited value's bytes.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_notes = @import("zg_notes");
const sidebar = @import("notes_sidebar.zig");
const model_mod = @import("sidebar_model.zig");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const controls = zg_gui.w.controls;
const Value = zg_notes.frontmatter.Value;
const Node = zg_notes.frontmatter.Node;
const PropertyType = zg_notes.note.PropertyType;

pub fn build(ui: *Ui, v: *sidebar.SidebarView) void {
    const m = v.m;
    if (m.active == null) return;
    sidebar.section(ui, "Properties");
    defer ui.close();
    propertiesEditor(ui, v);
}

pub fn propertiesEditor(ui: *Ui, v: *sidebar.SidebarView) void {
    const th = ui.theme();
    if (v.m.props.len == 0) ui.text("No properties.", .{ .color = .fg_muted });
    for (v.m.props) |p| {
        ui.id(p.name);
        ui.open(.{ .role = .group, .label = p.name, .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center } });
        defer ui.close();
        ui.open(.{ .style = .{ .w = .{ .px = 96 }, .shrink = 0 } });
        ui.text(p.name, .{ .color = .fg_muted, .wrap = false });
        ui.close();
        if (p.conflict) {
            const why = std.fmt.allocPrint(ui.arena(), "Value does not match the {t} type", .{p.ty}) catch "Value does not match its type";
            ui.open(.{ .role = .img, .label = why, .test_id = "prop-conflict" });
            ui.text("\u{26a0}", .{ .color = .warning, .wrap = false });
            ui.close();
        }
        valueEditor(ui, v, p) catch |e| v.fail(e);
    }
}

fn valueEditor(ui: *Ui, v: *sidebar.SidebarView, p: model_mod.PropRow) !void {
    if (!p.conflict) switch (p.ty) {
        .checkbox => if (p.value == .bool) {
            var on = p.value.bool;
            if (controls.checkbox(ui, p.name, &on).clicked) _ = try v.m.setProperty(p.name, .{ .bool = on });
            return;
        },
        .list, .tags, .aliases => if (p.value == .list or p.value == .null) return chips(ui, v, p),
        else => {},
    };
    const b = try v.buffer(p.name, displayText(p));
    const r = zg_gui.w.text_field.textField(ui, .{ .buffer = b, .a11y_label = p.name, .invalid = p.conflict, .placeholder = placeholder(p.ty) });
    if (r.submitted or (r.focus_lost and !std.mem.eql(u8, b.slice(), displayText(p)))) {
        const new = std.mem.trim(u8, b.slice(), " ");
        if (std.mem.eql(u8, new, displayText(p))) return;
        const val = parseValue(p.ty, new) orelse {
            v.err = "the value does not fit the property's type";
            return;
        };
        v.err = null;
        _ = try v.m.setProperty(p.name, val);
    }
}

fn placeholder(ty: PropertyType) []const u8 {
    return switch (ty) {
        .date => "YYYY-MM-DD",
        .datetime => "YYYY-MM-DDTHH:MM",
        .number => "0",
        else => "",
    };
}

/// The value as the field shows it: a scalar's text without quotes.
fn displayText(p: model_mod.PropRow) []const u8 {
    return switch (p.value) {
        .string => |s| s,
        .null => "",
        else => p.raw,
    };
}

/// Text typed for a property of type `ty` as a frontmatter value; null
/// when it does not fit (an invalid date or number).
pub fn parseValue(ty: PropertyType, s: []const u8) ?Value {
    if (s.len == 0) return .null;
    switch (ty) {
        .number => {
            if (std.fmt.parseInt(i64, s, 10)) |n| return .{ .int = n } else |_| {}
            if (std.fmt.parseFloat(f64, s)) |f| return .{ .float = f } else |_| {}
            return null;
        },
        .date => return if (zg_notes.frontmatter.parseDate(s)) |d| .{ .date = d } else null,
        .datetime => return if (zg_notes.frontmatter.parseDateTime(s)) |d| .{ .datetime = d } else null,
        .checkbox => {
            if (std.ascii.eqlIgnoreCase(s, "true")) return .{ .bool = true };
            if (std.ascii.eqlIgnoreCase(s, "false")) return .{ .bool = false };
            return null;
        },
        else => return .{ .string = s },
    }
}

fn chips(ui: *Ui, v: *sidebar.SidebarView, p: model_mod.PropRow) !void {
    const th = ui.theme();
    const items: []const Node = if (p.value == .list) p.value.list else &.{};
    ui.open(.{ .style = .{ .dir = .row, .wrap = true, .gap = th.dim(.space_xs), .grow = 1, .align_items = .center } });
    defer ui.close();
    for (items, 0..) |n, i| {
        const s = switch (n.value) {
            .string => |x| x,
            else => continue,
        };
        ui.id(@as(u64, i));
        ui.open(.{ .role = .listitem, .label = s, .style = .{ .dir = .row, .gap = 2, .align_items = .center } });
        defer ui.close();
        ui.text(s, .{ .wrap = false });
        const rm = std.fmt.allocPrint(ui.arena(), "Remove {s}", .{s}) catch "Remove";
        if (controls.button(ui, .{ .label = rm }).clicked) {
            _ = try v.m.setProperty(p.name, try withoutItem(ui.arena(), items, i));
            return;
        }
    }
    const key = std.fmt.allocPrint(ui.arena(), "{s}+", .{p.name}) catch p.name;
    const b = try v.buffer(key, "");
    const label = std.fmt.allocPrint(ui.arena(), "Add to {s}", .{p.name}) catch "Add";
    const r = zg_gui.w.text_field.textField(ui, .{ .buffer = b, .a11y_label = label, .placeholder = "Add\u{2026}" });
    if (r.submitted) {
        const s = std.mem.trim(u8, b.slice(), " #");
        if (s.len == 0) return;
        const all = try ui.arena().alloc(Node, items.len + 1);
        @memcpy(all[0..items.len], items);
        all[items.len] = .{ .value = .{ .string = try ui.arena().dupe(u8, s) }, .src = .{ 0, 0 }, .style = .plain };
        try b.setText("");
        _ = try v.m.setProperty(p.name, .{ .list = all });
    }
}

fn withoutItem(a: Allocator, items: []const Node, i: usize) !Value {
    const out = try a.alloc(Node, items.len - 1);
    @memcpy(out[0..i], items[0..i]);
    @memcpy(out[i..], items[i + 1 ..]);
    return .{ .list = out };
}
