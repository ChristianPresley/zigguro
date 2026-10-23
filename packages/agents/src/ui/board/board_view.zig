//! The task board (E13.F03.S01.T02): kanban columns of virtualised cards,
//! a grouped list and a table over the same filtered tasks, a query box,
//! drag-and-drop and keyboard moves, and the task editor.
//!
//! Keys while the board has focus: arrows move the cursor (Left/Right
//! between columns on the board); Alt+Left/Right move the card to the
//! next column, Alt+Up/Down reorder it; Enter opens the editor; N adds a
//! task to the focused column; A assigns; S starts an agent on the task;
//! `/` focuses the query box; Delete moves the task to the trash (Undo in
//! the notice). Each is also the palette command `tasks.*` (`commands`).
//!
//! Moves go through `BoardVM.move`, so dragging a card and moving it with
//! the keyboard write the same bytes. A move that sends a task to work
//! while a dependency is unfinished asks first.
//!
//! The store's listener only raises a flag and calls `Ports.wake`; the
//! next build takes the new view.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const card_mod = @import("card.zig");
const table_view = @import("table_view.zig");
const task_editor = @import("task_editor.zig");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Window = zg_gui.core.window.Window;
const NodeId = zg_gui.core.ids.NodeId;
const Rect = zg_gui.core.geom.Rect;
const Vec2 = zg_gui.core.geom.Vec2;
const controls = zg_gui.w.controls;
const scroll = zg_gui.w.scroll;
const TextBuffer = zg_gui.w.text_field.TextBuffer;
const widget = zg_gui.core.widget;
const ev_mod = zg_gui.input.event;

const tasks = zg_agents.tasks;
const runs = zg_agents.runs;
const TaskStore = tasks.TaskStore;
const TasksView = tasks.TasksView;
const Task = tasks.Task;
const TaskId = tasks.TaskId;
const Status = tasks.Status;
const BoardVM = tasks.BoardVM;
const BoardMode = tasks.BoardMode;

pub const Hook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, id: TaskId) void,
};

pub const Ports = struct {
    store: *TaskStore,
    /// Live claim chips.
    reg: ?*runs.RunRegistry = null,
    /// S: starts an agent on the task (F03.S02 dispatch).
    start_agent: ?Hook = null,
    /// A claim chip: shows the run in Mission Control.
    open_run: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, id: runs.RunId) void } = null,
    /// Opens a workspace file in the editor at a line (the body, "fix").
    open_file: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, path: []const u8, line: u32) void } = null,
    /// Agent definitions the assignee picker offers (`agent:<name>`).
    agents: []const []const u8 = &.{},
    /// Called from any thread when tasks change; the app schedules a frame.
    wake: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void } = null,
};

pub const card_h: f32 = 84;
pub const col_w: f32 = 260;
pub const list_row_h: f32 = 28;

/// Palette commands; `TaskBoard.runCommand` runs them.
pub const commands = [_][]const u8{
    "tasks.new",       "tasks.open",      "tasks.assign",    "tasks.startAgent",      "tasks.delete",
    "tasks.moveLeft",  "tasks.moveRight", "tasks.moveUp",    "tasks.moveDown",        "tasks.focusQuery",
    "tasks.showBoard", "tasks.showList",  "tasks.showTable", "tasks.toggleCancelled",
};

/// A card being dragged.
pub const Drag = struct { id: TaskId, pos: Vec2 };

/// Where a drop lands: a column and a position in it without the card.
pub const Target = struct { col: usize, index: usize, before_k: ?usize };

pub const TaskBoard = struct {
    gpa: Allocator,
    p: Ports,
    vm: BoardVM,
    mode: BoardMode = .board,
    view: ?*const TasksView = null,
    runs_view: ?*const runs.RunsView = null,
    query_field: TextBuffer,
    query_arena: std.heap.ArenaAllocator,
    query: ?tasks.Query = null,
    query_error: ?[]const u8 = null,
    cursor: ?TaskId = null,
    cursor_col: usize = 0,
    editor: ?*task_editor.TaskEditor = null,
    notice: ?[]const u8 = null,
    notice_buf: [200]u8 = undefined,
    /// The last task deleted (the notice's Undo).
    undo: ?TaskId = null,
    /// A move waiting for "Move anyway".
    confirm: ?struct { id: TaskId, to: Status, index: usize } = null,
    new_field: TextBuffer,
    creating: ?Status = null,
    assign_field: TextBuffer,
    assigning: ?TaskId = null,
    drag: ?Drag = null,
    table: table_view.TableState,
    /// Nodes of the last build, for drops.
    frame: struct {
        cols: [tasks.board.column_order.len]NodeId = @splat(.none),
        cards: std.ArrayList(struct { col: usize, k: usize, node: NodeId }) = .empty,
    } = .{},
    changed: std.atomic.Value(bool) = .init(true),
    listener: ?u32 = null,
    win: ?*Window = null,
    query_node: NodeId = .none,
    board_node: NodeId = .none,
    /// A card was pressed: keys go to the board on the next build.
    want_focus: bool = false,

    pub fn init(gpa: Allocator, p: Ports) !*TaskBoard {
        const b = try gpa.create(TaskBoard);
        errdefer gpa.destroy(b);
        b.* = .{
            .gpa = gpa,
            .p = p,
            .vm = .init(gpa),
            .query_field = try .init(gpa, ""),
            .query_arena = .init(gpa),
            .new_field = try .init(gpa, ""),
            .assign_field = try .init(gpa, ""),
            .table = undefined,
        };
        b.table.init(b);
        b.listener = try p.store.subscribe(.{ .ctx = b, .f = onTaskEvent });
        return b;
    }

    pub fn deinit(b: *TaskBoard) void {
        if (b.listener) |l| b.p.store.unsubscribe(l);
        if (b.editor) |e| e.deinit();
        if (b.view) |v| b.p.store.release(v);
        if (b.runs_view) |v| b.p.reg.?.release(v);
        b.table.deinit();
        b.vm.deinit();
        b.query_field.deinit();
        b.query_arena.deinit();
        b.new_field.deinit();
        b.assign_field.deinit();
        b.frame.cards.deinit(b.gpa);
        b.gpa.destroy(b);
    }

    fn onTaskEvent(ctx: *anyopaque, _: tasks.TaskEvent, _: *const TasksView) void {
        const b: *TaskBoard = @ptrCast(@alignCast(ctx));
        if (b.changed.swap(true, .acq_rel)) return;
        if (b.p.wake) |w| w.f(w.ctx);
    }

    /// A run changed (the app forwards registry events here).
    pub fn runsChanged(b: *TaskBoard) void {
        onTaskEvent(b, undefined, undefined);
    }

    pub fn build(b: *TaskBoard, ui: *Ui) void {
        taskBoard(ui, b);
    }

    /// Takes the store's (and registry's) current views.
    pub fn sync(b: *TaskBoard) void {
        if (b.changed.swap(false, .acq_rel) or b.view == null) {
            const nv = b.p.store.view();
            if (b.view) |old| b.p.store.release(old);
            b.view = nv;
            if (b.p.reg) |reg| {
                const rv = reg.snapshot();
                if (b.runs_view) |old| reg.release(old);
                b.runs_view = rv;
            }
        }
        b.vm.apply(b.view.?, b.runs_view, if (b.query) |*q| q else null, b.p.store.today()) catch b.say("Out of memory", .{});
        if (b.cursor) |c| if (b.vm.locate(c) == null) {
            b.cursor = null;
        };
        if (b.cursor == null) b.cursor = b.firstIn(b.cursor_col);
        if (b.cursor) |c| if (b.vm.locate(c)) |l| {
            b.cursor_col = l.col;
        };
        b.cursor_col = @min(b.cursor_col, b.vm.columns().len -| 1);
        if (b.mode == .table) b.table.reload();
    }

    fn firstIn(b: *const TaskBoard, col: usize) ?TaskId {
        const cols = b.vm.columns();
        if (col < cols.len and cols[col].cards.len > 0) return b.vm.task(cols[col].cards[0]).id;
        for (cols) |c| if (c.cards.len > 0) return b.vm.task(c.cards[0]).id;
        return null;
    }

    pub fn say(b: *TaskBoard, comptime fmt: []const u8, args: anytype) void {
        b.notice = std.fmt.bufPrint(&b.notice_buf, fmt, args) catch "…";
        b.announce(b.notice.?);
    }

    fn announce(b: *TaskBoard, text: []const u8) void {
        const w = b.win orelse return;
        if (w.a11y) |tree| tree.announce(text, false);
    }

    /// Parses the query box (an invalid query keeps the last good one).
    pub fn setQuery(b: *TaskBoard, text: []const u8) void {
        _ = b.query_arena.reset(.retain_capacity);
        b.query_error = null;
        if (std.mem.trim(u8, text, " \t").len == 0) {
            b.query = null;
        } else {
            b.query = tasks.parseQuery(b.query_arena.allocator(), text) catch {
                b.query = null;
                b.query_error = "Invalid query: see docs/formats/tasks.md";
                return;
            };
        }
        b.vm.invalidate();
    }

    pub fn setMode(b: *TaskBoard, m: BoardMode) void {
        b.mode = m;
        if (m == .table) b.table.reload();
    }

    // ---- cursor ----

    fn cursorPos(b: *const TaskBoard) ?struct { col: usize, index: usize } {
        const c = b.cursor orelse return null;
        const l = b.vm.locate(c) orelse return null;
        return .{ .col = l.col, .index = l.index };
    }

    /// The cursor's place in list order (columns one after another).
    fn flatIndex(b: *const TaskBoard) ?usize {
        const pos = b.cursorPos() orelse return null;
        var n: usize = 0;
        for (b.vm.columns()[0..pos.col]) |c| n += c.cards.len;
        return n + pos.index;
    }

    fn atFlat(b: *const TaskBoard, i: usize) ?TaskId {
        var n = i;
        for (b.vm.columns()) |c| {
            if (n < c.cards.len) return b.vm.task(c.cards[n]).id;
            n -= c.cards.len;
        }
        return null;
    }

    pub fn moveCursor(b: *TaskBoard, dcol: i32, drow: i32) void {
        const cols = b.vm.columns();
        if (cols.len == 0) return;
        if (b.mode != .board) {
            const cur = b.flatIndex() orelse 0;
            const n = b.vm.flat.items.len;
            if (n == 0) return;
            const next: usize = @intCast(std.math.clamp(@as(i64, @intCast(cur)) + drow, 0, @as(i64, @intCast(n - 1))));
            if (b.atFlat(next)) |id| b.cursor = id;
            return;
        }
        const pos = b.cursorPos() orelse {
            b.cursor = b.firstIn(b.cursor_col);
            return;
        };
        if (dcol != 0) {
            const c: usize = @intCast(std.math.clamp(@as(i64, @intCast(pos.col)) + dcol, 0, @as(i64, @intCast(cols.len - 1))));
            b.cursor_col = c;
            if (cols[c].cards.len > 0) b.cursor = b.vm.task(cols[c].cards[@min(pos.index, cols[c].cards.len - 1)]).id;
            return;
        }
        const cards = cols[pos.col].cards;
        const k: usize = @intCast(std.math.clamp(@as(i64, @intCast(pos.index)) + drow, 0, @as(i64, @intCast(cards.len - 1))));
        b.cursor = b.vm.task(cards[k]).id;
    }

    // ---- moves ----

    /// Moves card `id` to position `index` of column `to` (as a drop or a
    /// key does); asks first when the move needs it.
    pub fn requestMove(b: *TaskBoard, id: TaskId, to: Status, index: usize, confirmed: bool) void {
        const m = b.vm.move(id, to, index) catch |e| return b.say("Cannot move: {t}", .{e});
        if (m.isNoop()) return;
        if (m.needs_confirm and !confirmed) {
            b.confirm = .{ .id = id, .to = to, .index = index };
            return b.say("{s} waits for unfinished tasks. Move it to {s} anyway?", .{ tasks.ids.format(id).slice(), statusName(to) });
        }
        b.confirm = null;
        tasks.board.commit(b.p.store, &m) catch |e| return b.say("Cannot move: {t}", .{e});
        b.cursor = id;
        b.notice = null;
        var buf: [96]u8 = undefined;
        b.announce(std.fmt.bufPrint(&buf, "Moved {s} to {s}", .{ tasks.ids.format(id).slice(), statusName(to) }) catch "");
    }

    /// Alt+Left/Right: the next column, where the card sorts.
    pub fn moveAcross(b: *TaskBoard, dir: i32) void {
        const id = b.cursor orelse return;
        const pos = b.cursorPos() orelse return;
        const cols = b.vm.columns();
        const c = @as(i64, @intCast(pos.col)) + dir;
        if (c < 0 or c >= cols.len) return;
        const to = cols[@intCast(c)].status;
        const at = b.vm.naturalIndex(id, to) catch return;
        b.requestMove(id, to, at, false);
    }

    /// Alt+Up/Down: one place up or down in the column.
    pub fn reorder(b: *TaskBoard, dir: i32) void {
        const id = b.cursor orelse return;
        const pos = b.cursorPos() orelse return;
        const col = b.vm.columns()[pos.col];
        const k = @as(i64, @intCast(pos.index)) + dir;
        if (k < 0 or k >= col.cards.len) return;
        b.requestMove(id, col.status, @intCast(k), false);
    }

    /// The drop target under `pos`, from the last frame's rectangles.
    pub fn dropTarget(b: *const TaskBoard, pos: Vec2, ctx: anytype, comptime rectOf: fn (@TypeOf(ctx), NodeId) Rect) ?Target {
        const drag = b.drag orelse return null;
        const cols = b.vm.columns();
        var col: ?usize = null;
        var best: f32 = std.math.inf(f32);
        for (cols, 0..) |_, ci| {
            const n = b.frame.cols[ci];
            if (n.isNone()) continue;
            const r = rectOf(ctx, n);
            if (pos.x >= r.x and pos.x < r.x + r.w) {
                col = ci;
                break;
            }
            const d = @min(@abs(pos.x - r.x), @abs(pos.x - (r.x + r.w)));
            if (d < best) {
                best = d;
                col = ci;
            }
        }
        const ci = col orelse return null;
        const from = b.vm.locate(drag.id);
        const same = from != null and from.?.col == ci;
        // The first built card below the pointer.
        var before: ?usize = null;
        var last: ?usize = null;
        for (b.frame.cards.items) |fc| {
            if (fc.col != ci) continue;
            const r = rectOf(ctx, fc.node);
            if (last == null or fc.k > last.?) last = fc.k;
            if (pos.y < r.y + r.h / 2 and (before == null or fc.k < before.?)) before = fc.k;
        }
        const k_full: usize = before orelse if (last) |l| l + 1 else 0;
        var index = k_full;
        if (same and from.?.index < k_full) index -= 1;
        return .{ .col = ci, .index = index, .before_k = before };
    }

    fn drop(b: *TaskBoard, t: Target) void {
        const drag = b.drag orelse return;
        b.drag = null;
        const cols = b.vm.columns();
        if (t.col >= cols.len) return;
        b.requestMove(drag.id, cols[t.col].status, t.index, false);
    }

    // ---- actions ----

    pub fn openEditor(b: *TaskBoard, id: TaskId) void {
        if (b.editor) |e| e.deinit();
        b.editor = task_editor.TaskEditor.init(b.gpa, b, id) catch null;
    }

    pub fn closeEditor(b: *TaskBoard) void {
        if (b.editor) |e| e.deinit();
        b.editor = null;
    }

    pub fn startCreate(b: *TaskBoard) void {
        const cols = b.vm.columns();
        b.creating = if (b.cursor_col < cols.len) cols[b.cursor_col].status else .backlog;
        b.new_field.setText("") catch {};
    }

    pub fn create(b: *TaskBoard, title: []const u8) void {
        const s = b.creating orelse .backlog;
        const t = std.mem.trim(u8, title, " \t");
        if (t.len == 0) return;
        const r = b.p.store.create(.{ .title = t, .status = s }, .user) catch |e| return b.say("Cannot create: {t}", .{e});
        b.creating = null;
        b.cursor = r.id;
        b.say("Created {s}", .{tasks.ids.format(r.id).slice()});
    }

    pub fn startAssign(b: *TaskBoard) void {
        const id = b.cursor orelse return;
        b.assigning = id;
        const v = b.view orelse return;
        b.assign_field.setText(if (v.get(id)) |t| t.assignee orelse "" else "") catch {};
    }

    pub fn assign(b: *TaskBoard, who: []const u8) void {
        const id = b.assigning orelse return;
        b.assigning = null;
        const w = std.mem.trim(u8, who, " \t");
        _ = b.p.store.update(id, .{ .assignee = if (w.len == 0) @as(?[]const u8, null) else w }, .user) catch |e| return b.say("Cannot assign: {t}", .{e});
    }

    pub fn startAgent(b: *TaskBoard) void {
        const id = b.cursor orelse return;
        const h = b.p.start_agent orelse return b.say("No agent host", .{});
        h.f(h.ctx, id);
    }

    pub fn deleteCursor(b: *TaskBoard) void {
        const id = b.cursor orelse return;
        _ = b.p.store.delete(id, .user) catch |e| return b.say("Cannot delete: {t}", .{e});
        b.undo = id;
        b.cursor = null;
        b.say("Moved {s} to the trash", .{tasks.ids.format(id).slice()});
    }

    pub fn undoDelete(b: *TaskBoard) void {
        const id = b.undo orelse return;
        b.undo = null;
        b.p.store.restore(id) catch |e| return b.say("Cannot restore: {t}", .{e});
        b.cursor = id;
        b.say("Restored {s}", .{tasks.ids.format(id).slice()});
    }

    pub fn focusQuery(b: *TaskBoard) void {
        const w = b.win orelse return;
        if (!b.query_node.isNone()) w.setFocus(b.query_node, true);
    }

    /// Runs a palette command (`commands`); false when unknown.
    pub fn runCommand(b: *TaskBoard, name: []const u8) bool {
        const eq = std.mem.eql;
        if (eq(u8, name, "tasks.new")) b.startCreate() else if (eq(u8, name, "tasks.open")) {
            if (b.cursor) |c| b.openEditor(c);
        } else if (eq(u8, name, "tasks.assign")) b.startAssign() else if (eq(u8, name, "tasks.startAgent")) b.startAgent() else if (eq(u8, name, "tasks.delete")) b.deleteCursor() else if (eq(u8, name, "tasks.moveLeft")) b.moveAcross(-1) else if (eq(u8, name, "tasks.moveRight")) b.moveAcross(1) else if (eq(u8, name, "tasks.moveUp")) b.reorder(-1) else if (eq(u8, name, "tasks.moveDown")) b.reorder(1) else if (eq(u8, name, "tasks.focusQuery")) b.focusQuery() else if (eq(u8, name, "tasks.showBoard")) b.setMode(.board) else if (eq(u8, name, "tasks.showList")) b.setMode(.list) else if (eq(u8, name, "tasks.showTable")) b.setMode(.table) else if (eq(u8, name, "tasks.toggleCancelled")) b.vm.setShowCancelled(!b.vm.show_cancelled) else return false;
        b.sync();
        return true;
    }

    fn onKey(b: *TaskBoard, k: ev_mod.KeyPress) bool {
        if (k.action == .release) return false;
        const m = k.mods;
        if (m.alt) {
            switch (k.key) {
                .arrow_left => b.moveAcross(-1),
                .arrow_right => b.moveAcross(1),
                .arrow_up => b.reorder(-1),
                .arrow_down => b.reorder(1),
                else => return false,
            }
            b.sync();
            return true;
        }
        if (m.ctrl) return false;
        switch (k.key) {
            .arrow_down => b.moveCursor(0, 1),
            .arrow_up => b.moveCursor(0, -1),
            .arrow_left => b.moveCursor(-1, 0),
            .arrow_right => b.moveCursor(1, 0),
            .page_down => b.moveCursor(0, 10),
            .page_up => b.moveCursor(0, -10),
            .enter, .numpad_enter => if (b.cursor) |c| b.openEditor(c),
            .key_n => b.startCreate(),
            .key_a => b.startAssign(),
            .key_s => b.startAgent(),
            .slash => b.focusQuery(),
            .delete => b.deleteCursor(),
            .escape => {
                if (b.confirm == null and b.creating == null and b.assigning == null and b.drag == null) return false;
                b.confirm = null;
                b.creating = null;
                b.assigning = null;
                b.drag = null;
            },
            else => return false,
        }
        b.sync();
        if (b.cursor) |c| if (b.view.?.get(c)) |t| {
            b.announce(card_mod.label(b, t, b.notice_buf[100..]));
        };
        return true;
    }
};

/// The focusable board container: the keys.
const BoardBox = struct {
    pub const name = "task_board";
    pub const focusable = true;
    pub const Props = struct { b: *TaskBoard, count: usize };

    pub fn style(_: *const Props, _: *const zg_gui.theme.Theme) zg_gui.Style {
        return .{ .dir = .column, .grow = 1 };
    }

    pub fn event(ec: *ev_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const ev_mod.InputEvent) bool {
        if (ec.phase == .capture) return false;
        const k = switch (ev.*) {
            .key => |k| k,
            else => return false,
        };
        if (!props.b.onKey(k)) return false;
        ec.respond(.{ .changed = true });
        return true;
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .group, .name = "Task board", .row_count = props.count };
    }
};

/// The board panel.
pub fn taskBoard(ui: *Ui, b: *TaskBoard) void {
    b.win = ui.window();
    b.sync();
    const th = ui.theme();
    ui.open(.{ .style = .{ .dir = .column, .gap = th.dim(.space_sm), .padding = .all(th.dim(.space_sm)), .grow = 1 }, .test_id = "task-board" });
    defer ui.close();
    toolbar(ui, b);
    if (b.notice) |n| noticeBar(ui, b, n);
    if (b.creating) |s| {
        const r = zg_gui.w.text_field.textField(ui, .{ .buffer = &b.new_field, .a11y_label = "New task title", .placeholder = std.fmt.allocPrint(ui.arena(), "New task in {s}…", .{statusName(s)}) catch "" });
        if (r.submitted) b.create(b.new_field.slice()) else if (r.cancelled) {
            b.creating = null;
        }
    }
    if (b.assigning) |_| assignBox(ui, b);
    // The drop indicator uses the previous frame's rectangles.
    const tgt: ?Target = if (b.drag) |d| b.dropTarget(d.pos, ui.window(), rectFromStore) else null;
    b.frame.cards.clearRetainingCapacity();
    b.frame.cols = @splat(.none);
    // The board, and the editor beside it.
    ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .grow = 1 } });
    defer ui.close();
    _ = ui.begin(BoardBox, .{ .b = b, .count = b.vm.flat.items.len });
    b.board_node = ui.current();
    if (b.want_focus) {
        b.want_focus = false;
        ui.window().setFocus(b.board_node, false);
    }
    if (b.vm.flat.items.len == 0 and b.view.?.tasks.len == 0) {
        ui.text("No tasks yet. Press N to add one, or ask an agent to plan the work.", .{ .color = .fg_muted });
    } else switch (b.mode) {
        .board => boardMode(ui, b, tgt),
        .list => listMode(ui, b),
        .table => table_view.build(ui, b),
    }
    ui.end(BoardBox);
    if (b.editor) |e| task_editor.taskEditor(ui, e);
}

fn toolbar(ui: *Ui, b: *TaskBoard) void {
    ui.open(.{ .style = .{ .dir = .row, .gap = 4, .align_items = .center } });
    defer ui.close();
    ui.text("Tasks", .{ .wrap = false, .style = .{ .weight = 700 } });
    ui.open(.{ .style = .{ .grow = 1 } });
    const r = zg_gui.w.text_field.textField(ui, .{ .buffer = &b.query_field, .a11y_label = "Filter tasks", .placeholder = "Filter: status:ready label:docs assignee:agent:* due:overdue sort:priority" });
    b.query_node = ui.lastNode();
    ui.close();
    if (r.changed) b.setQuery(b.query_field.slice());
    inline for (.{ .{ BoardMode.board, "Board" }, .{ BoardMode.list, "List" }, .{ BoardMode.table, "Table" } }) |m| {
        if (controls.button(ui, .{ .label = m[1], .variant = if (b.mode == m[0]) .primary else .ghost }).clicked) b.setMode(m[0]);
    }
    if (controls.button(ui, .{ .label = if (b.vm.show_cancelled) "Hide cancelled" else "Show cancelled", .variant = .ghost }).clicked) b.vm.setShowCancelled(!b.vm.show_cancelled);
    if (controls.button(ui, .{ .label = "New task" }).clicked) b.startCreate();
    if (b.query_error) |e| {
        ui.open(.{ .role = .status, .label = e, .test_id = "task-query-error" });
        ui.text(e, .{ .color = .danger, .wrap = false });
        ui.close();
    }
}

fn noticeBar(ui: *Ui, b: *TaskBoard, n: []const u8) void {
    ui.open(.{ .role = .status, .label = n, .test_id = "task-notice", .style = .{ .dir = .row, .gap = 4, .align_items = .center } });
    defer ui.close();
    ui.text(n, .{ .color = .warning });
    if (b.confirm) |c| {
        if (controls.button(ui, .{ .label = "Move anyway", .variant = .primary }).clicked) b.requestMove(c.id, c.to, c.index, true);
        if (controls.button(ui, .{ .label = "Cancel" }).clicked) {
            b.confirm = null;
            b.notice = null;
        }
    } else if (b.undo != null) {
        if (controls.button(ui, .{ .label = "Undo" }).clicked) b.undoDelete();
    }
}

fn assignBox(ui: *Ui, b: *TaskBoard) void {
    ui.open(.{ .role = .group, .label = "Assign", .style = .{ .dir = .row, .gap = 4, .align_items = .center } });
    defer ui.close();
    ui.open(.{ .style = .{ .grow = 1 } });
    const r = zg_gui.w.text_field.textField(ui, .{ .buffer = &b.assign_field, .a11y_label = "Assignee", .placeholder = "A name, or agent:<definition> (empty: unassigned)" });
    ui.close();
    if (r.submitted) return b.assign(b.assign_field.slice());
    if (r.cancelled) {
        b.assigning = null;
        return;
    }
    // Agent definitions as one-click picks.
    for (b.p.agents, 0..) |a, i| {
        ui.id(@as(u64, i));
        const who = std.fmt.allocPrint(ui.arena(), "agent:{s}", .{a}) catch continue;
        if (controls.button(ui, .{ .label = who, .variant = .ghost }).clicked) return b.assign(who);
    }
}

fn boardMode(ui: *Ui, b: *TaskBoard, tgt: ?Target) void {
    const th = ui.theme();
    ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .grow = 1, .scroll_x = true } });
    defer ui.close();
    for (b.vm.columns(), 0..) |c, ci| {
        ui.id(@as(u64, @intFromEnum(c.status)) + 1);
        const label = std.fmt.allocPrint(ui.arena(), "{s}, {d} task{s}", .{ statusName(c.status), c.cards.len, if (c.cards.len == 1) "" else "s" }) catch "";
        const drop_end = tgt != null and tgt.?.col == ci and tgt.?.before_k == null;
        ui.open(.{ .role = .list, .label = label, .test_id = statusName(c.status), .style = .{
            .dir = .column,
            .w = .{ .px = col_w },
            .shrink = 0,
            .gap = 4,
            .padding = .all(4),
            .bg = .{ .token = .bg_sunken },
            .border = if (drop_end) .{ .token = .accent } else .none,
            .border_w = if (drop_end) 2 else 0,
        } });
        b.frame.cols[ci] = ui.current();
        ui.open(.{ .style = .{ .dir = .row, .gap = 4, .align_items = .center } });
        ui.text(statusName(c.status), .{ .wrap = false, .style = .{ .weight = 700 } });
        if (c.wip) |w| {
            ui.textf("{d}/{d}", .{ c.total, w }, .{ .color = if (c.overWip()) .danger else .fg_muted, .wrap = false });
        } else ui.textf("{d}", .{c.cards.len}, .{ .color = .fg_muted, .wrap = false });
        ui.close();
        if (c.cards.len > 0) {
            const Ctx = struct { b: *TaskBoard, col: usize, tgt: ?Target };
            _ = scroll.virtualList(ui, .{ .count = c.cards.len, .row_h = card_h, .test_id = "" }, Ctx{ .b = b, .col = ci, .tgt = tgt }, struct {
                fn row(x: Ctx, u: *Ui, k: usize) void {
                    const ins = x.tgt != null and x.tgt.?.col == x.col and x.tgt.?.before_k != null and x.tgt.?.before_k.? == k;
                    card_mod.card(u, x.b, x.col, k, .board, ins);
                }
            }.row);
        }
        ui.close();
    }
}

fn listMode(ui: *Ui, b: *TaskBoard) void {
    // Headers and cards, column by column.
    var count: usize = 0;
    for (b.vm.columns()) |c| count += 1 + c.cards.len;
    _ = scroll.virtualList(ui, .{ .count = count, .row_h = list_row_h, .test_id = "task-list" }, b, struct {
        fn row(bb: *TaskBoard, u: *Ui, i: usize) void {
            var n = i;
            for (bb.vm.columns(), 0..) |c, ci| {
                if (n == 0) {
                    u.id(@as(u64, @intFromEnum(c.status)) + 1);
                    const label = std.fmt.allocPrint(u.arena(), "{s} ({d})", .{ statusName(c.status), c.cards.len }) catch "";
                    u.open(.{ .role = .group, .label = label, .style = .{ .padding = .xy(4, 2), .grow = 1 } });
                    u.text(label, .{ .color = .fg_muted, .wrap = false, .style = .{ .weight = 700 } });
                    u.close();
                    return;
                }
                n -= 1;
                if (n < c.cards.len) return card_mod.card(u, bb, ci, n, .list, false);
                n -= c.cards.len;
            }
        }
    }.row);
}

fn rectFromStore(w: *Window, n: NodeId) Rect {
    if (!w.store.valid(n)) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    return w.store.absRect(n);
}

fn rectFromEvent(ec: *ev_mod.EventCx, n: NodeId) Rect {
    return ec.rectOf(n);
}

pub fn dropFromEvent(b: *TaskBoard, ec: *ev_mod.EventCx, pos: Vec2) void {
    const t = b.dropTarget(pos, ec, rectFromEvent) orelse {
        b.drag = null;
        return;
    };
    b.drop(t);
}

pub fn statusName(s: Status) []const u8 {
    return switch (s) {
        .backlog => "Backlog",
        .ready => "Ready",
        .in_progress => "In progress",
        .review => "Review",
        .blocked => "Blocked",
        .done => "Done",
        .cancelled => "Cancelled",
    };
}
