//! The grid's sort and filter bar (E13.F06.S01.T02). Simple mode shows
//! the sort and one chip per filter (equals, contains, range, is null,
//! not null), each removable, plus an editor for a new chip on a column.
//! Advanced mode takes the query language (S02.T01) and runs it on
//! Enter; parse and plan errors show under it.

const std = @import("std");
const zg_gui = @import("zg_gui");
const grid_vm = @import("grid_vm.zig");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const controls = zg_gui.w.controls;
const text_field = zg_gui.w.text_field;
const TextBuffer = text_field.TextBuffer;
const GridVM = grid_vm.GridVM;
const Chip = grid_vm.Chip;

pub const Mode = enum { simple, advanced };

pub const QueryBar = struct {
    gpa: Allocator,
    mode: Mode = .simple,
    query: TextBuffer,
    /// A chip being written: its column and operator.
    editing: ?struct { col: u32, op: Chip.Op } = null,
    a: TextBuffer,
    b: TextBuffer,

    pub fn init(gpa: Allocator) !QueryBar {
        return .{ .gpa = gpa, .query = try .init(gpa, ""), .a = try .init(gpa, ""), .b = try .init(gpa, "") };
    }

    pub fn deinit(q: *QueryBar) void {
        q.query.deinit();
        q.a.deinit();
        q.b.deinit();
    }

    /// Switches to advanced mode with the simple mode's query as text.
    pub fn advanced(q: *QueryBar, vm: *GridVM) !void {
        q.mode = .advanced;
        var arena: std.heap.ArenaAllocator = .init(q.gpa);
        defer arena.deinit();
        const text = vm.view_text orelse (try vm.simpleQuery(arena.allocator())) orelse "";
        try setText(&q.query, text);
    }

    /// Back to simple mode: the chips and the sort apply again.
    pub fn simple(q: *QueryBar, vm: *GridVM) !void {
        q.mode = .simple;
        var arena: std.heap.ArenaAllocator = .init(q.gpa);
        defer arena.deinit();
        try vm.setView(try vm.simpleQuery(arena.allocator()));
    }

    /// Opens the editor for a new chip on `col`; ops that take no value
    /// apply at once.
    pub fn startChip(q: *QueryBar, vm: *GridVM, col: u32, op: Chip.Op) !void {
        if (op == .is_null or op == .not_null) return vm.addChip(.{ .col = col, .op = op });
        q.editing = .{ .col = col, .op = op };
        try setText(&q.a, "");
        try setText(&q.b, "");
    }

    pub fn applyChip(q: *QueryBar, vm: *GridVM) !void {
        const e = q.editing orelse return;
        q.editing = null;
        try vm.addChip(.{ .col = e.col, .op = e.op, .a = q.a.slice(), .b = q.b.slice() });
    }
};

fn setText(b: *TextBuffer, s: []const u8) !void {
    try b.replace(.{ 0, b.len() }, s);
}

pub fn opName(op: Chip.Op) []const u8 {
    return switch (op) {
        .equals => "=",
        .contains => "contains",
        .range => "in",
        .is_null => "is empty",
        .not_null => "is not empty",
    };
}

pub fn chipLabel(a: Allocator, vm: *const GridVM, c: Chip) []const u8 {
    const name = vm.ds.columns[c.col];
    return switch (c.op) {
        .is_null, .not_null => std.fmt.allocPrint(a, "{s} {s}  ×", .{ name, opName(c.op) }),
        .range => std.fmt.allocPrint(a, "{s} in {s}…{s}  ×", .{ name, c.a, c.b }),
        else => std.fmt.allocPrint(a, "{s} {s} {s}  ×", .{ name, opName(c.op), c.a }),
    } catch "";
}

pub fn queryBar(ui: *Ui, q: *QueryBar, vm: *GridVM) void {
    const th = ui.theme();
    const a = ui.arena();
    ui.open(.{ .role = .group, .label = "Sort and filter", .test_id = "data-query-bar", .style = .{ .dir = .column, .gap = th.dim(.space_xs) } });
    defer ui.close();
    switch (q.mode) {
        .advanced => {
            const r = text_field.textField(ui, .{ .buffer = &q.query, .multiline = true, .max_rows = 6, .font = .mono, .a11y_label = "Query", .placeholder = "where amount > 100 | sort -amount   (Enter runs)", .invalid = vm.query_error != null });
            if (r.submitted) {
                const t = std.mem.trim(u8, q.query.slice(), " \t\r\n");
                vm.setView(if (t.len == 0) null else t) catch {};
            }
        },
        .simple => {
            ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_xs), .wrap = true, .align_items = .center } });
            defer ui.close();
            if (vm.sort) |s| {
                const label = std.fmt.allocPrint(a, "Sorted by {s} {s}  ×", .{ vm.ds.columns[s.col], if (s.desc) "↓" else "↑" }) catch "";
                ui.id(@as([]const u8, "sort"));
                if (controls.button(ui, .{ .label = label, .variant = .ghost }).clicked) vm.setSort(null) catch {};
            }
            var remove: ?usize = null;
            for (vm.chips.items, 0..) |c, i| {
                ui.id(@as(u64, i));
                if (controls.button(ui, .{ .label = chipLabel(a, vm, c), .variant = .ghost }).clicked) remove = i;
            }
            if (remove) |i| vm.removeChip(i) catch {};
            if (vm.sort == null and vm.chips.items.len == 0 and q.editing == null)
                ui.text("Click a header to sort; filter a column from the toolbar.", .{ .color = .fg_muted, .wrap = false });
            if (q.editing) |e| {
                ui.text(std.fmt.allocPrint(a, "{s} {s}", .{ vm.ds.columns[e.col], opName(e.op) }) catch "", .{ .wrap = false });
                const ra = text_field.textField(ui, .{ .buffer = &q.a, .a11y_label = if (e.op == .range) "From" else "Value", .placeholder = if (e.op == .range) "from" else "value" });
                var submit = ra.submitted;
                if (e.op == .range) {
                    const rb = text_field.textField(ui, .{ .buffer = &q.b, .a11y_label = "To", .placeholder = "to" });
                    submit = submit or rb.submitted;
                }
                if (controls.button(ui, .{ .label = "Apply", .variant = .primary }).clicked) submit = true;
                if (submit) q.applyChip(vm) catch {};
                if (controls.button(ui, .{ .label = "Cancel" }).clicked or ra.cancelled) q.editing = null;
            }
        },
    }
    if (vm.query_error) |e| {
        ui.open(.{ .role = .status, .label = e, .test_id = "data-query-error" });
        ui.text(e, .{ .color = .danger });
        ui.close();
    }
}

test {
    std.testing.refAllDecls(@This());
}
