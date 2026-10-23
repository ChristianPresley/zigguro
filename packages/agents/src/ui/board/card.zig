//! A task card (E13.F03.S01.T02): id, priority, assignee, a two-line
//! title, labels, due date, the "blocked by" chip and the live claim chip.
//! Cards have a fixed height per mode so columns virtualise in O(1). The
//! card box takes presses: a click moves the cursor, a double click opens
//! the editor and a drag past a few pixels moves the card.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const board_view = @import("board_view.zig");

const Ui = zg_gui.Ui;
const Vec2 = zg_gui.core.geom.Vec2;
const controls = zg_gui.w.controls;
const widget = zg_gui.core.widget;
const ev_mod = zg_gui.input.event;

const tasks = zg_agents.tasks;
const runs = zg_agents.runs;
const Task = tasks.Task;
const TaskId = tasks.TaskId;
const TaskBoard = board_view.TaskBoard;

/// Pixels a press moves before it becomes a drag.
pub const drag_threshold: f32 = 5;
pub const max_labels = 3;
const title_max = 90;

pub const Mode = enum { board, list };

/// What a screen reader hears for a card.
pub fn label(b: *const TaskBoard, t: *const Task, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const idf = tasks.ids.format(t.id);
    w.print("{s} {s}, {s}, P{d}", .{ if (t.id == 0) "" else idf.slice(), t.title, board_view.statusName(t.status), t.priority }) catch {};
    if (t.assignee) |a| w.print(", assigned to {s}", .{a}) catch {};
    if (t.due) |d| w.print(", due {d}-{d:0>2}-{d:0>2}", .{ d.y, d.m, d.d }) catch {};
    if (b.view) |v| if (v.isBlocked(t)) w.print(", blocked", .{}) catch {};
    if (t.claimed_by != null) w.print(", claimed", .{}) catch {};
    if (t.problem) |p| w.print(", problem: {s}", .{p}) catch {};
    return w.buffered();
}

/// The card at position `k` of column `col`.
pub fn card(ui: *Ui, b: *TaskBoard, col: usize, k: usize, mode: Mode, insert_mark: bool) void {
    const c = b.vm.columns()[col];
    if (k >= c.cards.len) return;
    const ti = c.cards[k];
    const t = b.vm.task(ti);
    const sel = b.cursor != null and b.cursor.? == t.id and t.id != 0;
    const lbl_buf = ui.arena().alloc(u8, 256) catch return;
    const lbl = label(b, t, lbl_buf);
    ui.id(@as(u64, ti) + 1);
    _ = ui.begin(CardBox, .{ .b = b, .id = t.id, .label = lbl, .selected = sel, .insert_mark = insert_mark, .mode = mode, .dragging = b.drag != null and b.drag.?.id == t.id });
    b.frame.cards.append(b.gpa, .{ .col = col, .k = k, .node = ui.current() }) catch {};
    switch (mode) {
        .board => boardCard(ui, b, t),
        .list => listCard(ui, b, t),
    }
    ui.end(CardBox);
}

fn boardCard(ui: *Ui, b: *TaskBoard, t: *const Task) void {
    ui.open(.{ .style = .{ .dir = .row, .gap = 4, .align_items = .center } });
    if (t.id != 0) ui.text(tasks.ids.format(t.id).slice(), .{ .color = .fg_muted, .wrap = false });
    controls.badge(ui, priorityText(t.priority));
    ui.open(.{ .style = .{ .grow = 1 } });
    ui.close();
    if (t.assignee) |a| assignee(ui, a);
    ui.close();
    ui.text(clip(ui, t.title), .{ .style = .{ .weight = 600 } });
    ui.open(.{ .style = .{ .dir = .row, .gap = 4, .align_items = .center } });
    chips(ui, b, t);
    ui.close();
}

fn listCard(ui: *Ui, b: *TaskBoard, t: *const Task) void {
    ui.open(.{ .style = .{ .dir = .row, .gap = 6, .align_items = .center, .grow = 1 } });
    defer ui.close();
    if (t.id != 0) ui.text(tasks.ids.format(t.id).slice(), .{ .color = .fg_muted, .wrap = false });
    controls.badge(ui, priorityText(t.priority));
    ui.text(clip(ui, t.title), .{ .wrap = false });
    ui.open(.{ .style = .{ .grow = 1 } });
    ui.close();
    chips(ui, b, t);
    if (t.assignee) |a| assignee(ui, a);
}

fn assignee(ui: *Ui, a: []const u8) void {
    if (std.mem.startsWith(u8, a, "agent:")) {
        ui.textf("\u{25C6} {s}", .{a[6..]}, .{ .color = .accent, .wrap = false });
    } else ui.textf("@{s}", .{a}, .{ .color = .fg_muted, .wrap = false });
}

fn chips(ui: *Ui, b: *TaskBoard, t: *const Task) void {
    for (t.labels[0..@min(t.labels.len, max_labels)], 0..) |l, i| {
        ui.id(@as(u64, i) + 1);
        controls.badge(ui, l);
    }
    if (t.labels.len > max_labels) ui.textf("+{d}", .{t.labels.len - max_labels}, .{ .color = .fg_muted, .wrap = false });
    if (t.due) |d| {
        const today = b.p.store.today();
        const overdue = tasks.query.cmpDate(d, today) == .lt and !t.status.finished();
        ui.textf("{d}-{d:0>2}-{d:0>2}", .{ d.y, d.m, d.d }, .{ .color = if (overdue) .danger else .fg_muted, .wrap = false });
    }
    if (b.view) |v| if (v.isBlocked(t)) {
        var list: std.ArrayList(TaskId) = .empty;
        v.blockedBy(t.id, &list, ui.arena()) catch {};
        if (list.items.len > 0) ui.textf("blocked by {s}{s}", .{ tasks.ids.format(list.items[0]).slice(), if (list.items.len > 1) " …" else "" }, .{ .color = .warning, .wrap = false });
    };
    if (t.claimed_by) |c| {
        const run = b.vm.claimRun(t);
        const chip = if (run) |r| std.fmt.allocPrint(ui.arena(), "\u{25CF} {s}", .{@tagName(r.status)}) catch "claimed" else "claimed";
        ui.id(@as([]const u8, "claim"));
        if (controls.button(ui, .{ .label = chip, .variant = .ghost }).clicked) if (b.p.open_run) |h| {
            if (runs.RunId.parse(c)) |id| h.f(h.ctx, id) else |_| {}
        };
    }
    if (t.problem) |_| {
        ui.id(@as([]const u8, "fix"));
        if (controls.button(ui, .{ .label = "Fix", .variant = .ghost }).clicked) if (b.p.open_file) |h| {
            const path = std.fmt.allocPrint(ui.arena(), "{s}/{s}", .{ b.p.store.o.dir_rel, t.path }) catch return;
            h.f(h.ctx, path, 1);
        };
    }
}

fn clip(ui: *Ui, s: []const u8) []const u8 {
    if (s.len <= title_max) return s;
    var end: usize = title_max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(ui.arena(), "{s}\u{2026}", .{s[0..end]}) catch s[0..end];
}

pub fn priorityText(p: u2) []const u8 {
    return switch (p) {
        0 => "P0",
        1 => "P1",
        2 => "P2",
        3 => "P3",
    };
}

/// The card's box: selection, the drop mark and pointer handling.
const CardBox = struct {
    pub const name = "task_card";
    pub const Props = struct {
        b: *TaskBoard,
        id: TaskId,
        label: []const u8,
        selected: bool,
        insert_mark: bool,
        mode: Mode,
        dragging: bool,
    };
    pub const State = struct { press: ?Vec2 = null };

    pub fn style(props: *const Props, _: *const zg_gui.theme.Theme) zg_gui.Style {
        return .{
            .dir = if (props.mode == .board) .column else .row,
            .grow = 1,
            .gap = 2,
            .padding = .xy(6, 4),
            .radius = if (props.mode == .board) 4 else 0,
            .bg = if (props.selected) .{ .token = .selection_bg } else if (props.mode == .board) .{ .token = .bg_elevated } else .none,
            .border = if (props.insert_mark) .{ .token = .accent } else if (props.dragging) .{ .token = .focus_ring } else .none,
            .border_w = if (props.insert_mark or props.dragging) 2 else 0,
        };
    }

    pub fn event(ec: *ev_mod.EventCx, props: *const Props, st: *State, ev: *const ev_mod.InputEvent) bool {
        if (ec.phase == .capture) return false;
        const b = props.b;
        switch (ev.*) {
            .pointer_down => |p| {
                if (p.button != .left or props.id == 0) return false;
                b.cursor = props.id;
                b.want_focus = true;
                if (p.clicks >= 2) {
                    b.openEditor(props.id);
                } else {
                    st.press = p.pos;
                    ec.capture();
                }
                ec.respond(.{ .changed = true });
                return true;
            },
            .pointer_move => |p| {
                const start = st.press orelse return false;
                if (b.drag == null) {
                    if (@abs(p.pos.x - start.x) + @abs(p.pos.y - start.y) < drag_threshold) return true;
                    b.drag = .{ .id = props.id, .pos = p.pos };
                } else b.drag.?.pos = p.pos;
                ec.respond(.{ .changed = true });
                return true;
            },
            .pointer_up => |p| {
                if (st.press == null) return false;
                st.press = null;
                ec.releaseCapture();
                if (b.drag != null) {
                    b.drag.?.pos = p.pos;
                    board_view.dropFromEvent(b, ec, p.pos);
                    b.sync();
                }
                ec.respond(.{ .changed = true });
                return true;
            },
            else => return false,
        }
    }

    pub fn a11y(props: *const Props, _: *State) widget.A11y {
        return .{ .role = .listitem, .name = props.label, .selected = props.selected };
    }
};
