//! The board's table mode (E13.F03.S01.T02): the filtered tasks in the
//! E04 Table, one row per task, with sortable columns. Enter or a double
//! click opens the task editor, where every field is edited.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const board_view = @import("board_view.zig");
const card_mod = @import("card.zig");

const Ui = zg_gui.Ui;
const table = zg_gui.virtual.table;
const tasks = zg_agents.tasks;
const Task = tasks.Task;
const TaskBoard = board_view.TaskBoard;

const Col = enum(u32) { id, title, status, priority, assignee, labels, due, created, claim };

pub const TableState = struct {
    b: *TaskBoard,
    cols: [9]table.Column,
    t: table.Table,
    /// Indexes into the view's tasks, in table order.
    rows: std.ArrayList(u32) = .empty,
    sort: ?table.Sort = null,
    arena: std.heap.ArenaAllocator,

    pub fn init(s: *TableState, b: *TaskBoard) void {
        s.* = .{
            .b = b,
            .cols = .{
                .{ .id = @intFromEnum(Col.id), .title = "ID", .width = 72, .sortable = true, .frozen = true },
                .{ .id = @intFromEnum(Col.title), .title = "Title", .width = 280, .sortable = true },
                .{ .id = @intFromEnum(Col.status), .title = "Status", .width = 100, .sortable = true },
                .{ .id = @intFromEnum(Col.priority), .title = "Priority", .width = 64, .sortable = true },
                .{ .id = @intFromEnum(Col.assignee), .title = "Assignee", .width = 120, .sortable = true },
                .{ .id = @intFromEnum(Col.labels), .title = "Labels", .width = 140 },
                .{ .id = @intFromEnum(Col.due), .title = "Due", .width = 96, .sortable = true },
                .{ .id = @intFromEnum(Col.created), .title = "Created", .width = 160, .sortable = true },
                .{ .id = @intFromEnum(Col.claim), .title = "Claim", .width = 100 },
            },
            .t = undefined,
            .arena = .init(b.gpa),
        };
        s.t = .init(b.gpa, .{ .ptr = s, .vtable = &vtable }, .{
            .columns = &s.cols,
            .on_sort = .{ .ctx = s, .f = onSort },
            .on_activate = .{ .ctx = s, .f = onActivate },
            .on_selection = .{ .ctx = s, .f = onSelection },
            .label = "Tasks",
            .test_id = "task-table",
        });
    }

    pub fn deinit(s: *TableState) void {
        s.t.deinit();
        s.rows.deinit(s.b.gpa);
        s.arena.deinit();
    }

    /// Takes the board's filtered tasks and re-sorts them.
    pub fn reload(s: *TableState) void {
        _ = s.arena.reset(.retain_capacity);
        s.rows.clearRetainingCapacity();
        s.rows.appendSlice(s.b.gpa, s.b.vm.flat.items) catch return;
        if (s.sort) |so| if (s.b.view) |v| {
            const Ctx = struct { v: *const tasks.TasksView, so: table.Sort };
            std.mem.sort(u32, s.rows.items, Ctx{ .v = v, .so = so }, struct {
                fn less(c: Ctx, a: u32, b: u32) bool {
                    const o = order(@enumFromInt(c.so.col), &c.v.tasks[a], &c.v.tasks[b]);
                    if (o == .eq) return a < b;
                    return if (c.so.desc) o == .gt else o == .lt;
                }
            }.less);
        };
        s.t.reload();
    }

    fn task(s: *const TableState, row: u64) ?*const Task {
        if (row >= s.rows.items.len) return null;
        return s.b.vm.task(s.rows.items[@intCast(row)]);
    }

    const vtable: table.TableSource.VTable = .{
        .row_count = rowCount,
        .row_key = rowKey,
        .cell_text = cellText,
    };

    fn rowCount(p: *anyopaque) u64 {
        const s: *TableState = @ptrCast(@alignCast(p));
        return s.rows.items.len;
    }

    fn rowKey(p: *anyopaque, row: u64) u64 {
        const s: *TableState = @ptrCast(@alignCast(p));
        const t = s.task(row) orelse return 0;
        return if (t.id != 0) t.id else (@as(u64, 1) << 40) + row;
    }

    fn cellText(p: *anyopaque, row: u64, col: u32) []const u8 {
        const s: *TableState = @ptrCast(@alignCast(p));
        const t = s.task(row) orelse return "";
        const a = s.arena.allocator();
        return switch (@as(Col, @enumFromInt(col))) {
            .id => if (t.id == 0) "-" else a.dupe(u8, tasks.ids.format(t.id).slice()) catch "",
            .title => t.title,
            .status => board_view.statusName(t.status),
            .priority => card_mod.priorityText(t.priority),
            .assignee => t.assignee orelse "",
            .labels => std.mem.join(a, ", ", t.labels) catch "",
            .due => if (t.due) |d| std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2}", .{ d.y, d.m, d.d }) catch "" else "",
            .created => t.created orelse "",
            .claim => if (s.b.vm.claimRun(t)) |r| @tagName(r.status) else if (t.claimed_by != null) "claimed" else "",
        };
    }

    fn onSort(ctx: *anyopaque, _: *table.Table, so: ?table.Sort) void {
        const s: *TableState = @ptrCast(@alignCast(ctx));
        s.sort = so;
        s.reload();
    }

    fn onActivate(ctx: *anyopaque, row: u64, _: u32) void {
        const s: *TableState = @ptrCast(@alignCast(ctx));
        const t = s.task(row) orelse return;
        if (t.id != 0) s.b.openEditor(t.id);
    }

    fn onSelection(ctx: *anyopaque, t: *table.Table) void {
        const s: *TableState = @ptrCast(@alignCast(ctx));
        const tk = s.task(t.active_row) orelse return;
        if (tk.id != 0) s.b.cursor = tk.id;
    }
};

fn order(c: Col, a: *const Task, b: *const Task) std.math.Order {
    return switch (c) {
        .id => std.math.order(a.id, b.id),
        .title => std.ascii.orderIgnoreCase(a.title, b.title),
        .status => std.math.order(@intFromEnum(a.status), @intFromEnum(b.status)),
        .priority => std.math.order(a.priority, b.priority),
        .assignee => std.mem.order(u8, a.assignee orelse "", b.assignee orelse ""),
        .due => if (a.due == null or b.due == null)
            std.math.order(@intFromBool(a.due == null), @intFromBool(b.due == null))
        else
            tasks.query.cmpDate(a.due.?, b.due.?),
        .created => std.mem.order(u8, a.created orelse "", b.created orelse ""),
        .labels, .claim => .eq,
    };
}

pub fn build(ui: *Ui, b: *TaskBoard) void {
    b.table.t.build(ui);
}
