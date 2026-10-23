//! The task editor (E13.F03.S01.T02): a form for the task's properties
//! (title, status, priority, assignee with the agent definitions, labels,
//! due date, dependencies with search over titles) above the Markdown
//! body. Saving writes only the changed properties through
//! `TaskStore.update(.user)`; the body opens in the editor (E05, with the
//! notes live preview) through `Ports.open_file`.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const board_view = @import("board_view.zig");
const card_mod = @import("card.zig");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const controls = zg_gui.w.controls;
const TextBuffer = zg_gui.w.text_field.TextBuffer;
const textField = zg_gui.w.text_field.textField;

const tasks = zg_agents.tasks;
const Task = tasks.Task;
const TaskId = tasks.TaskId;
const Status = tasks.Status;
const TaskBoard = board_view.TaskBoard;

const preview_bytes = 600;
const max_suggestions = 5;

pub const TaskEditor = struct {
    gpa: Allocator,
    b: *TaskBoard,
    id: TaskId,
    title: TextBuffer,
    assignee: TextBuffer,
    labels: TextBuffer,
    due: TextBuffer,
    depends: TextBuffer,
    status: Status,
    priority: u2,
    body: []u8 = &.{},
    body_line: u32 = 1,
    problem: ?[]const u8 = null,
    problem_buf: [160]u8 = undefined,

    pub fn init(gpa: Allocator, b: *TaskBoard, id: TaskId) !*TaskEditor {
        const v = b.view orelse return error.TaskNotFound;
        const t = v.get(id) orelse return error.TaskNotFound;
        const e = try gpa.create(TaskEditor);
        errdefer gpa.destroy(e);
        var labels: std.Io.Writer.Allocating = .init(gpa);
        defer labels.deinit();
        for (t.labels, 0..) |l, i| labels.writer.print("{s}{s}", .{ if (i > 0) ", " else "", l }) catch {};
        var depends: std.Io.Writer.Allocating = .init(gpa);
        defer depends.deinit();
        for (t.depends_on, 0..) |d, i| depends.writer.print("{s}{s}", .{ if (i > 0) ", " else "", tasks.ids.format(d).slice() }) catch {};
        var due_buf: [16]u8 = undefined;
        const due = if (t.due) |d| std.fmt.bufPrint(&due_buf, "{d}-{d:0>2}-{d:0>2}", .{ d.y, d.m, d.d }) catch "" else "";
        e.* = .{
            .gpa = gpa,
            .b = b,
            .id = id,
            .title = try .init(gpa, t.title),
            .assignee = try .init(gpa, t.assignee orelse ""),
            .labels = try .init(gpa, labels.written()),
            .due = try .init(gpa, due),
            .depends = try .init(gpa, depends.written()),
            .status = t.status,
            .priority = t.priority,
        };
        e.loadBody(t);
        return e;
    }

    pub fn deinit(e: *TaskEditor) void {
        e.title.deinit();
        e.assignee.deinit();
        e.labels.deinit();
        e.due.deinit();
        e.depends.deinit();
        e.gpa.free(e.body);
        e.gpa.destroy(e);
    }

    fn loadBody(e: *TaskEditor, t: *const Task) void {
        const st = e.b.p.store;
        const bytes = st.dir.readFileAlloc(st.io, t.path, e.gpa, .limited(1 << 20)) catch return;
        defer e.gpa.free(bytes);
        const body = tasks.task.bodyOf(bytes);
        e.body_line = @intCast(std.mem.count(u8, bytes[0 .. bytes.len - body.len], "\n") + 1);
        e.body = e.gpa.dupe(u8, std.mem.trimStart(u8, body, "\r\n")[0..@min(preview_bytes, std.mem.trimStart(u8, body, "\r\n").len)]) catch &.{};
    }

    fn say(e: *TaskEditor, comptime fmt: []const u8, args: anytype) void {
        e.problem = std.fmt.bufPrint(&e.problem_buf, fmt, args) catch "…";
    }

    /// The patch from the form: only what differs from the task.
    pub fn patch(e: *TaskEditor, a: Allocator) !tasks.TaskStore.TaskPatch {
        const v = e.b.view orelse return error.TaskNotFound;
        const t = v.get(e.id) orelse return error.TaskNotFound;
        var p: tasks.TaskStore.TaskPatch = .{};
        const title = std.mem.trim(u8, e.title.slice(), " \t");
        if (title.len == 0) return error.EmptyTitle;
        if (!std.mem.eql(u8, title, t.title)) p.title = title;
        if (e.status != t.status) p.status = e.status;
        if (e.priority != t.priority) p.priority = e.priority;
        const who = std.mem.trim(u8, e.assignee.slice(), " \t");
        const old_who = t.assignee orelse "";
        if (!std.mem.eql(u8, who, old_who)) p.assignee = if (who.len == 0) @as(?[]const u8, null) else who;
        var labels: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, e.labels.slice(), ", ");
        while (it.next()) |l| try labels.append(a, l);
        if (!sameStrings(labels.items, t.labels)) p.labels = labels.items;
        const due_s = std.mem.trim(u8, e.due.slice(), " \t");
        const due: ?tasks.task.Date = if (due_s.len == 0) null else (parseDate(due_s) orelse return error.BadDate);
        const same_due = if (due) |d| (if (t.due) |o| d.eql(o) else false) else t.due == null;
        if (!same_due) p.due = due;
        var deps: std.ArrayList(TaskId) = .empty;
        var dit = std.mem.tokenizeAny(u8, e.depends.slice(), ", ");
        while (dit.next()) |d| try deps.append(a, tasks.ids.parse(d) orelse return error.BadDependency);
        if (!std.mem.eql(TaskId, deps.items, t.depends_on)) p.depends_on = deps.items;
        return p;
    }

    pub fn save(e: *TaskEditor) void {
        var arena: std.heap.ArenaAllocator = .init(e.gpa);
        defer arena.deinit();
        const p = e.patch(arena.allocator()) catch |err| return e.say("Cannot save: {s}", .{switch (err) {
            error.EmptyTitle => "the title is empty",
            error.BadDate => "the due date must be YYYY-MM-DD",
            error.BadDependency => "dependencies are task ids such as T-0042",
            else => @errorName(err),
        }});
        e.problem = null;
        _ = e.b.p.store.update(e.id, p, .user) catch |err| return e.say("Cannot save: {t}", .{err});
        e.b.say("Saved {s}", .{tasks.ids.format(e.id).slice()});
    }

    /// Adds a dependency from a search pick.
    pub fn addDependency(e: *TaskEditor, id: TaskId) void {
        var buf: [512]u8 = undefined;
        const cur = std.mem.trimEnd(u8, e.depends.slice(), " ,");
        // Replace the search word being typed.
        const cut = if (std.mem.lastIndexOfAny(u8, cur, ", ")) |i| cur[0 .. i + 1] else "";
        const keep = std.mem.trimEnd(u8, cut, " ,");
        const s = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ keep, if (keep.len > 0) ", " else "", tasks.ids.format(id).slice() }) catch return;
        e.depends.setText(s) catch {};
    }
};

/// `YYYY-MM-DD`.
fn parseDate(s: []const u8) ?tasks.task.Date {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
    const y = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u4, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u5, s[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    return .{ .y = y, .m = m, .d = d };
}

fn sameStrings(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

pub fn taskEditor(ui: *Ui, e: *TaskEditor) void {
    const th = ui.theme();
    const label = std.fmt.allocPrint(ui.arena(), "Edit {s}", .{tasks.ids.format(e.id).slice()}) catch "Edit task";
    ui.open(.{ .role = .group, .label = label, .test_id = "task-editor", .style = .{ .dir = .column, .gap = 4, .w = .{ .px = 380 }, .shrink = 0, .scroll_y = true, .padding = .all(th.dim(.space_sm)), .bg = .{ .token = .bg_elevated } } });
    defer ui.close();
    ui.text(label, .{ .style = .{ .weight = 700 } });
    _ = textField(ui, .{ .buffer = &e.title, .a11y_label = "Title" });
    // Status and priority as segmented choices.
    ui.open(.{ .role = .group, .label = "Status", .style = .{ .dir = .row, .gap = 2, .wrap = true } });
    for (tasks.board.column_order) |s| {
        ui.id(@as(u64, @intFromEnum(s)) + 1);
        if (controls.button(ui, .{ .label = board_view.statusName(s), .variant = if (e.status == s) .primary else .ghost }).clicked) e.status = s;
    }
    ui.close();
    ui.open(.{ .role = .group, .label = "Priority", .style = .{ .dir = .row, .gap = 2 } });
    for (0..4) |i| {
        const p: u2 = @intCast(i);
        ui.id(@as(u64, i) + 1);
        if (controls.button(ui, .{ .label = card_mod.priorityText(p), .variant = if (e.priority == p) .primary else .ghost }).clicked) e.priority = p;
    }
    ui.close();
    _ = textField(ui, .{ .buffer = &e.assignee, .a11y_label = "Assignee", .placeholder = "A name, or agent:<definition>" });
    if (e.b.p.agents.len > 0) {
        ui.open(.{ .role = .group, .label = "Agents", .style = .{ .dir = .row, .gap = 2, .wrap = true } });
        for (e.b.p.agents, 0..) |a, i| {
            ui.id(@as(u64, i) + 1);
            const who = std.fmt.allocPrint(ui.arena(), "agent:{s}", .{a}) catch continue;
            if (controls.button(ui, .{ .label = who, .variant = .ghost }).clicked) e.assignee.setText(who) catch {};
        }
        ui.close();
    }
    _ = textField(ui, .{ .buffer = &e.labels, .a11y_label = "Labels", .placeholder = "docs, bug" });
    _ = textField(ui, .{ .buffer = &e.due, .a11y_label = "Due", .placeholder = "YYYY-MM-DD" });
    _ = textField(ui, .{ .buffer = &e.depends, .a11y_label = "Depends on", .placeholder = "T-0042, or type to search titles" });
    dependencySuggestions(ui, e);
    if (e.problem) |p| {
        ui.open(.{ .role = .status, .label = p, .test_id = "task-editor-problem" });
        ui.text(p, .{ .color = .danger });
        ui.close();
    }
    ui.open(.{ .style = .{ .dir = .row, .gap = 4 } });
    if (controls.button(ui, .{ .label = "Save", .variant = .primary }).clicked) e.save();
    if (controls.button(ui, .{ .label = "Edit body", .disabled = e.b.p.open_file == null }).clicked) openBody(e);
    if (controls.button(ui, .{ .label = "Close" }).clicked) {
        e.b.closeEditor();
        return;
    }
    ui.close();
    if (e.body.len > 0) ui.text(e.body, .{ .color = .fg_muted });
}

fn openBody(e: *TaskEditor) void {
    const h = e.b.p.open_file orelse return;
    const v = e.b.view orelse return;
    const t = v.get(e.id) orelse return;
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ e.b.p.store.o.dir_rel, t.path }) catch return;
    h.f(h.ctx, path, e.body_line);
}

/// Titles matching the word being typed in "Depends on".
fn dependencySuggestions(ui: *Ui, e: *TaskEditor) void {
    const text = e.depends.slice();
    const start = if (std.mem.lastIndexOfAny(u8, text, ", ")) |i| i + 1 else 0;
    const word = std.mem.trim(u8, text[start..], " ");
    if (word.len < 2 or tasks.ids.parse(word) != null) return;
    const v = e.b.view orelse return;
    var n: usize = 0;
    ui.open(.{ .role = .list, .label = "Matching tasks", .style = .{ .dir = .column } });
    defer ui.close();
    for (v.tasks) |*t| {
        if (n == max_suggestions) break;
        if (t.id == 0 or t.id == e.id or !fuzzy(word, t.title)) continue;
        ui.id(@as(u64, t.id));
        const lbl = std.fmt.allocPrint(ui.arena(), "{s} {s}", .{ tasks.ids.format(t.id).slice(), t.title }) catch continue;
        if (controls.button(ui, .{ .label = lbl, .variant = .ghost }).clicked) e.addDependency(t.id);
        n += 1;
    }
}

/// Every character of `q` appears in `s` in order, ignoring case.
pub fn fuzzy(q: []const u8, s: []const u8) bool {
    var i: usize = 0;
    for (s) |c| {
        if (i < q.len and std.ascii.toLower(c) == std.ascii.toLower(q[i])) i += 1;
    }
    return i == q.len;
}
