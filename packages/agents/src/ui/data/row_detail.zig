//! Row detail (E13.F06.S01.T02): one row as names and values, for rows
//! too wide to read across. Nested JSON values are pretty-printed and
//! fold: collapsed they show their first line and size.

const std = @import("std");
const zg_gui = @import("zg_gui");
const grid_vm = @import("grid_vm.zig");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const controls = zg_gui.w.controls;

pub const RowDetail = struct {
    gpa: Allocator,
    row: ?u64 = null,
    /// Columns whose nested value is unfolded.
    open: std.AutoHashMapUnmanaged(u32, void) = .empty,

    pub fn deinit(d: *RowDetail) void {
        d.open.deinit(d.gpa);
    }

    pub fn show(d: *RowDetail, row: ?u64) void {
        if (!std.meta.eql(d.row, row)) d.open.clearRetainingCapacity();
        d.row = row;
    }

    pub fn toggle(d: *RowDetail, col: u32) void {
        if (d.open.remove(col)) return;
        d.open.put(d.gpa, col, {}) catch {};
    }
};

/// A cell's value: plain text, or pretty-printed nested JSON.
pub const Shown = struct {
    text: []const u8,
    /// For nested values: the size ("3 keys", "12 items").
    nested: ?[]const u8 = null,
};

/// How a cell shows in the detail.
pub fn shownValue(a: Allocator, text: []const u8) Shown {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len < 2 or !((t[0] == '{' and t[t.len - 1] == '}') or (t[0] == '[' and t[t.len - 1] == ']'))) return .{ .text = text };
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, t, .{}) catch return .{ .text = text };
    const pretty = std.json.Stringify.valueAlloc(a, v, .{ .whitespace = .indent_2 }) catch return .{ .text = text };
    const size = switch (v) {
        .object => |o| std.fmt.allocPrint(a, "{d} {s}", .{ o.count(), if (o.count() == 1) "key" else "keys" }),
        .array => |l| std.fmt.allocPrint(a, "{d} {s}", .{ l.items.len, if (l.items.len == 1) "item" else "items" }),
        else => return .{ .text = text },
    } catch return .{ .text = text };
    return .{ .text = pretty, .nested = size };
}

pub fn rowDetail(ui: *Ui, d: *RowDetail, vm: *grid_vm.GridVM) void {
    const th = ui.theme();
    const row = d.row orelse return;
    ui.open(.{ .role = .group, .label = "Row detail", .test_id = "data-row-detail", .style = .{ .dir = .column, .gap = th.dim(.space_sm), .padding = .all(th.dim(.space_sm)), .w = .{ .px = 320 }, .shrink = 0, .clip = true } });
    defer ui.close();
    var buf: [40]u8 = undefined;
    ui.text(std.fmt.allocPrint(ui.arena(), "Row {s}", .{vm.rowLabel(row, &buf)}) catch "Row", .{ .style = .{ .weight = 700 } });
    const a = ui.arena();
    for (0..vm.columnCount()) |ci| {
        const col: u32 = @intCast(ci);
        ui.id(@as(u64, col));
        ui.open(.{ .role = .group, .label = vm.columnName(col), .style = .{ .dir = .column } });
        defer ui.close();
        ui.text(vm.columnName(col), .{ .color = .fg_muted, .wrap = false });
        const e = vm.cell(row, col) catch continue;
        if (e.null_) {
            ui.text(grid_vm.null_mark, .{ .color = .fg_muted });
            continue;
        }
        const s = shownValue(a, e.text);
        const size = s.nested orelse {
            ui.text(s.text, .{});
            continue;
        };
        const open = d.open.contains(col);
        const first = std.mem.sliceTo(s.text, '\n');
        const label = std.fmt.allocPrint(a, "{s} {s}…  ({s})", .{ if (open) "▾" else "▸", first, size }) catch "";
        if (controls.button(ui, .{ .label = label, .variant = .ghost }).clicked) d.toggle(col);
        if (open) ui.text(s.text, .{ .wrap = false, .style = .{ .font = .mono } });
    }
}

test {
    std.testing.refAllDecls(@This());
}
