//! The Mission Control panel (E13.F01.S02.T01): a totals bar, the dispatch
//! box, the filter box, and every run as a grouped virtual list with live
//! status, age, cost and outputs; Space opens the peek/reply panel.
//!
//! Keys while the list has focus: Up/Down move (Shift extends the
//! selection), Right/Left expand or collapse a workflow, and the row
//! actions of `zg_agents.mission.actions` (Enter attach, Space peek,
//! Ctrl+X stop (twice within 2 s), P pause/resume, R resume, O outputs,
//! Ctrl+T pin, Delete remove, Ctrl+R rename). Stop and Delete apply to
//! every selected row.
//!
//! Updates arrive from the registry's listener on any thread: it only
//! raises a flag and calls `Ports.wake`; the next build applies the new
//! view. Ages tick once a second through one window timer, and only the
//! built (visible) rows redraw.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Window = zg_gui.core.window.Window;
const controls = zg_gui.w.controls;
const scroll = zg_gui.w.scroll;
const TextBuffer = zg_gui.w.text_field.TextBuffer;
const widget = zg_gui.core.widget;
const ev_mod = zg_gui.input.event;

const runs = zg_agents.runs;
const mission = zg_agents.mission;
const RunId = runs.RunId;
const RunRegistry = runs.RunRegistry;
const RunHost = runs.RunHost;
const MissionVM = mission.MissionVM;
const Action = mission.Action;

pub const Hook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, id: RunId) void,
};

pub const Ports = struct {
    reg: *RunRegistry,
    /// Starts and controls runs; without it the panel is read-only.
    host: ?*RunHost = null,
    review: mission.ReviewCounts = .none,
    /// Enter: opens the run's conversation.
    attach: ?Hook = null,
    /// O: shows the run's outputs.
    outputs: ?Hook = null,
    /// Ctrl+G in an empty dispatch box: edit the prompt in a full editor.
    prompt_editor: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void } = null,
    /// Called from any thread when runs change; the app schedules a frame.
    wake: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void } = null,
};

pub const row_h: f32 = 44;
pub const header_h: f32 = 24;

pub const MissionControl = struct {
    gpa: Allocator,
    p: Ports,
    vm: MissionVM,
    filter_field: TextBuffer,
    dispatch_field: TextBuffer,
    reply_field: TextBuffer,
    rename_field: TextBuffer,
    /// The focused row's run.
    cursor: ?RunId = null,
    /// Shift-selected runs (besides the cursor).
    marked: std.AutoArrayHashMapUnmanaged(u128, void) = .empty,
    peek: ?RunId = null,
    renaming: ?RunId = null,
    stop_guard: mission.StopGuard = .{},
    /// "Press Ctrl+X again to stop", errors.
    notice: ?[]const u8 = null,
    notice_buf: [160]u8 = undefined,
    changed: std.atomic.Value(bool) = .init(true),
    listener: ?u32 = null,
    timer: Window.TimerId = .none,
    win: ?*Window = null,
    vid: u16 = 0,

    pub fn init(gpa: Allocator, p: Ports) !*MissionControl {
        const mc = try gpa.create(MissionControl);
        errdefer gpa.destroy(mc);
        mc.* = .{
            .gpa = gpa,
            .p = p,
            .vm = .init(gpa),
            .filter_field = try .init(gpa, ""),
            .dispatch_field = try .init(gpa, ""),
            .reply_field = try .init(gpa, ""),
            .rename_field = try .init(gpa, ""),
        };
        mc.listener = try p.reg.subscribe(.{ .ctx = mc, .on_event = onRunEvent });
        return mc;
    }

    /// Cancels the age timer; call before `deinit` while the window
    /// lives (closing the panel).
    pub fn detach(mc: *MissionControl) void {
        if (mc.win) |w| if (mc.timer != .none) w.cancelTimer(mc.timer);
        mc.timer = .none;
        mc.win = null;
    }

    /// Frees the panel; its window is gone or `detach` was called.
    pub fn deinit(mc: *MissionControl) void {
        if (mc.listener) |l| mc.p.reg.unsubscribe(l);
        mc.vm.deinit();
        mc.filter_field.deinit();
        mc.dispatch_field.deinit();
        mc.reply_field.deinit();
        mc.rename_field.deinit();
        mc.marked.deinit(mc.gpa);
        mc.gpa.destroy(mc);
    }

    fn onRunEvent(ctx: *anyopaque, _: runs.RunEvent) void {
        const mc: *MissionControl = @ptrCast(@alignCast(ctx));
        if (mc.changed.swap(true, .acq_rel)) return;
        if (mc.p.wake) |w| w.f(w.ctx);
    }

    pub fn build(mc: *MissionControl, ui: *Ui) void {
        missionControl(ui, mc);
    }

    /// Applies the registry's current view (when it changed).
    pub fn sync(mc: *MissionControl) void {
        const v = mc.p.reg.snapshot();
        defer mc.p.reg.release(v);
        mc.changed.store(false, .release);
        mc.vm.apply(v, mc.p.review, mc.p.reg.nowMs()) catch mc.say("Out of memory", .{});
        if (mc.cursor) |c| if (mc.vm.get(c) == null) {
            mc.cursor = null;
        };
        if (mc.cursor == null) mc.cursor = mc.firstRow();
    }

    fn firstRow(mc: *const MissionControl) ?RunId {
        for (mc.vm.rows()) |it| if (it == .row) return it.row.run;
        return null;
    }

    fn say(mc: *MissionControl, comptime fmt: []const u8, args: anytype) void {
        mc.notice = std.fmt.bufPrint(&mc.notice_buf, fmt, args) catch "…";
    }

    /// The runs an action applies to: the selection, else the cursor.
    fn targets(mc: *const MissionControl, bulk: bool, out: []RunId) []RunId {
        var n: usize = 0;
        if (bulk and mc.marked.count() > 0) {
            for (mc.marked.keys()) |k| {
                if (n == out.len) break;
                out[n] = .fromInt(k);
                n += 1;
            }
            return out[0..n];
        }
        const c = mc.cursor orelse return out[0..0];
        out[0] = c;
        return out[0..1];
    }

    /// Runs `a` on the cursor (or the selection), as the palette command
    /// `agents.mc.*` does.
    pub fn runAction(mc: *MissionControl, a: Action) void {
        const now = mc.p.reg.nowMs();
        const e = mission.actions.entry(a);
        var buf: [256]RunId = undefined;
        const ids = mc.targets(e.bulk, &buf);
        if (ids.len == 0) return;
        const first = ids[0];
        if (a != .stop) mc.stop_guard.reset();
        mc.notice = null;
        switch (a) {
            .attach => {
                mc.vm.markSeen(first);
                if (mc.p.attach) |h| h.f(h.ctx, first);
            },
            .peek => {
                mc.peek = if (mc.peek != null and mc.peek.?.eql(first)) null else first;
                mc.vm.markSeen(first);
            },
            .outputs => if (mc.p.outputs) |h| h.f(h.ctx, first),
            .stop => {
                var key: u128 = 0;
                for (ids) |id| key ^= id.toInt();
                switch (mc.stop_guard.press(key, now)) {
                    .armed => mc.say("Press Ctrl+X again to stop {d} run{s}", .{ ids.len, if (ids.len == 1) "" else "s" }),
                    .confirmed => {
                        const host = mc.p.host orelse return mc.say("No agent host", .{});
                        for (ids) |id| host.stop(id, .graceful);
                        mc.marked.clearRetainingCapacity();
                    },
                }
            },
            .pause => {
                const host = mc.p.host orelse return mc.say("No agent host", .{});
                const row = mc.vm.get(first) orelse return;
                if (row.status == .paused) host.resumeRun(first) catch |err| mc.say("Cannot resume: {t}", .{err}) else host.pause(first);
            },
            .resume_ => {
                const host = mc.p.host orelse return mc.say("No agent host", .{});
                host.resumeRun(first) catch |err| mc.say("Cannot resume: {t}", .{err});
            },
            .pin => {
                const row = mc.vm.get(first) orelse return;
                mc.p.reg.update(first, .{ .pinned = !row.pinned }) catch |err| mc.say("Cannot pin: {t}", .{err});
            },
            .remove => {
                var skipped: usize = 0;
                for (ids) |id| mc.p.reg.remove(id, false) catch {
                    skipped += 1;
                };
                mc.marked.clearRetainingCapacity();
                if (skipped > 0) mc.say("{d} active run{s} not removed (stop first)", .{ skipped, if (skipped == 1) "" else "s" });
            },
            .rename => {
                const row = mc.vm.get(first) orelse return;
                mc.renaming = first;
                mc.rename_field.setText(row.title) catch {};
            },
        }
    }

    /// Moves the cursor by `delta` rows (headers skipped); `extend` adds
    /// the rows passed to the selection.
    pub fn move(mc: *MissionControl, delta: i32, extend: bool) void {
        const items = mc.vm.rows();
        if (items.len == 0) return;
        var i: isize = @intCast(mc.cursorIndex() orelse 0);
        const step: isize = if (delta < 0) -1 else 1;
        var left: u32 = @abs(delta);
        if (extend) if (mc.cursor) |c| mc.marked.put(mc.gpa, c.toInt(), {}) catch {};
        while (left > 0) {
            var j = i + step;
            while (j >= 0 and j < items.len and items[@intCast(j)] == .header) j += step;
            if (j < 0 or j >= items.len) break;
            i = j;
            left -= 1;
            if (extend) mc.marked.put(mc.gpa, items[@intCast(i)].row.run.toInt(), {}) catch {};
        }
        if (!extend) mc.marked.clearRetainingCapacity();
        if (items[@intCast(i)] == .row) mc.cursor = items[@intCast(i)].row.run;
    }

    fn cursorIndex(mc: *const MissionControl) ?usize {
        const c = mc.cursor orelse return null;
        for (mc.vm.rows(), 0..) |it, i| if (it == .row and it.row.run.eql(c)) return i;
        return null;
    }

    /// Starts a run from the dispatch box's text.
    pub fn dispatch(mc: *MissionControl, text: []const u8) void {
        const d = mission.parseDispatch(text);
        if (d.isEmpty()) return;
        const host = mc.p.host orelse return mc.say("No agent host", .{});
        var buf: [4096]u8 = undefined;
        const spec = mission.dispatch.toSpec(d, &buf) catch return mc.say("Prompt too long", .{});
        const id = host.start(spec) catch |err| return mc.say("Cannot start: {t}", .{err});
        mc.cursor = id;
        mc.dispatch_field.setText("") catch {};
    }

    /// Sends the peek panel's reply. `!cmd` asks the run to run a shell
    /// command (as a message; nothing executes it directly).
    pub fn sendReply(mc: *MissionControl, text: []const u8) void {
        const id = mc.peek orelse return;
        const host = mc.p.host orelse return mc.say("No agent host", .{});
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len == 0) return;
        var buf: [4096]u8 = undefined;
        const msg = if (t[0] == '!')
            std.fmt.bufPrint(&buf, "Please run this shell command in the terminal and show me the output:\n\n```sh\n{s}\n```", .{std.mem.trim(u8, t[1..], " ")}) catch return mc.say("Reply too long", .{})
        else
            t;
        host.reply(id, msg) catch |err| return mc.say("Cannot reply: {t}", .{err});
        mc.reply_field.setText("") catch {};
    }

    fn onKey(mc: *MissionControl, k: ev_mod.KeyPress) bool {
        if (k.action == .release) return false;
        const m = k.mods;
        switch (k.key) {
            .arrow_down => mc.move(1, m.shift),
            .arrow_up => mc.move(-1, m.shift),
            .page_down => mc.move(10, m.shift),
            .page_up => mc.move(-10, m.shift),
            .arrow_right, .arrow_left => {
                const c = mc.cursor orelse return false;
                mc.vm.setExpanded(c, k.key == .arrow_right);
            },
            .enter, .numpad_enter => mc.runAction(.attach),
            .space => mc.runAction(.peek),
            .delete => mc.runAction(.remove),
            .escape => {
                if (mc.peek == null and mc.marked.count() == 0) return false;
                mc.peek = null;
                mc.marked.clearRetainingCapacity();
            },
            .key_x => if (m.ctrl) mc.runAction(.stop) else return false,
            .key_t => if (m.ctrl) mc.runAction(.pin) else return false,
            .key_r => mc.runAction(if (m.ctrl) .rename else .resume_),
            .key_p => if (!m.ctrl) mc.runAction(.pause) else return false,
            .key_o => if (!m.ctrl) mc.runAction(.outputs) else return false,
            else => return false,
        }
        mc.vm.refresh() catch {};
        return true;
    }

    fn onTimer(ctx: *anyopaque, w: *Window) void {
        const mc: *MissionControl = @ptrCast(@alignCast(ctx));
        mc.timer = .none;
        w.markViewDirty(mc.vid);
    }

    /// One frame a second while rows show ages or working glyphs.
    fn scheduleTick(mc: *MissionControl, ui: *Ui) void {
        const w = ui.window();
        mc.win = w;
        mc.vid = ui.currentView();
        if (mc.timer != .none or mc.vm.rowCount() == 0) return;
        mc.timer = w.setTimer(w.app.now_ms + 1_000, .{ .ctx = mc, .f = onTimer }) catch .none;
    }
};

/// The focusable list container: the row keys.
const ListBox = struct {
    pub const name = "mission_list";
    pub const focusable = true;
    pub const Props = struct { mc: *MissionControl, rows: usize };

    pub fn style(_: *const Props, _: *const zg_gui.theme.Theme) zg_gui.Style {
        return .{ .dir = .column, .grow = 1 };
    }

    pub fn event(ec: *ev_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const ev_mod.InputEvent) bool {
        if (ec.phase == .capture) return false;
        const k = switch (ev.*) {
            .key => |k| k,
            else => return false,
        };
        if (!props.mc.onKey(k)) return false;
        ec.respond(.{ .changed = true });
        return true;
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .list, .name = "Agent runs", .row_count = @intCast(props.rows) };
    }
};

/// The panel.
pub fn missionControl(ui: *Ui, mc: *MissionControl) void {
    if (mc.changed.load(.acquire)) mc.sync();
    mc.vm.refresh() catch {};
    const th = ui.theme();
    ui.open(.{ .style = .{ .dir = .column, .gap = th.dim(.space_sm), .padding = .all(th.dim(.space_sm)), .grow = 1 }, .test_id = "mission-control" });
    defer ui.close();
    totalsBar(ui, mc);
    dispatchBox(ui, mc);
    filterBox(ui, mc);
    if (mc.notice) |n| {
        ui.open(.{ .role = .status, .label = n, .test_id = "mission-notice" });
        ui.text(n, .{ .color = .warning });
        ui.close();
    }
    if (mc.renaming) |id| renameBox(ui, mc, id);

    const items = mc.vm.rows();
    _ = ui.begin(ListBox, .{ .mc = mc, .rows = mc.vm.rowCount() });
    if (items.len == 0) {
        ui.text(if (mc.vm.filter.isEmpty()) "No agent runs yet. Dispatch one above." else "No runs match the filter.", .{ .color = .fg_muted });
    } else {
        _ = scroll.virtualList(ui, .{ .count = items.len, .row_h = row_h, .test_id = "mission-rows" }, mc, itemRow);
    }
    ui.end(ListBox);
    if (mc.peek) |id| peekPanel(ui, mc, id);
    mc.scheduleTick(ui);
}

fn totalsBar(ui: *Ui, mc: *MissionControl) void {
    const t = mc.vm.totals;
    const label = std.fmt.allocPrint(ui.arena(), "{d} running, {d} need input, today {f}", .{ t.running, t.needs_input, usd(t.today_cost_micro) }) catch "";
    ui.open(.{ .role = .status, .label = label, .test_id = "mission-totals" });
    ui.text(label, .{ .color = .fg_muted, .wrap = false });
    ui.close();
}

fn dispatchBox(ui: *Ui, mc: *MissionControl) void {
    ui.open(.{ .style = .{ .dir = .row, .gap = 4 } });
    defer ui.close();
    ui.open(.{ .style = .{ .grow = 1 } });
    const r = zg_gui.w.text_field.textField(ui, .{ .buffer = &mc.dispatch_field, .a11y_label = "Dispatch a run", .placeholder = "Ask an agent… (@agent, /skill, ! cmd, +lane)" });
    ui.close();
    if (r.submitted) mc.dispatch(mc.dispatch_field.slice());
    if (controls.button(ui, .{ .label = "Run", .disabled = mc.p.host == null }).clicked) mc.dispatch(mc.dispatch_field.slice());
}

fn filterBox(ui: *Ui, mc: *MissionControl) void {
    const r = zg_gui.w.text_field.textField(ui, .{ .buffer = &mc.filter_field, .a11y_label = "Filter runs", .placeholder = "Filter: s:working k:scheduled cost>0.5 #tag a:name" });
    if (r.changed) mc.vm.setFilterText(mc.filter_field.slice()) catch {};
}

fn renameBox(ui: *Ui, mc: *MissionControl, id: RunId) void {
    const r = zg_gui.w.text_field.textField(ui, .{ .buffer = &mc.rename_field, .a11y_label = "Rename run" });
    if (r.submitted) {
        const t = std.mem.trim(u8, mc.rename_field.slice(), " ");
        if (t.len > 0) mc.p.reg.update(id, .{ .title = t }) catch |err| mc.say("Cannot rename: {t}", .{err});
        mc.renaming = null;
    } else if (r.cancelled) mc.renaming = null;
}

fn itemRow(mc: *MissionControl, ui: *Ui, i: usize) void {
    const items = mc.vm.rows();
    if (i >= items.len) return;
    switch (items[i]) {
        .header => |h| {
            ui.id(@as(u64, @intFromEnum(h.group)) + 1);
            const label = std.fmt.allocPrint(ui.arena(), "{s} ({d})", .{ groupName(h.group), h.count }) catch "";
            ui.open(.{ .role = .group, .label = label, .style = .{ .padding = .xy(4, 2), .grow = 1 } });
            ui.text(label, .{ .color = .fg_muted, .wrap = false, .style = .{ .weight = 700 } });
            ui.close();
        },
        .row => |r| runRow(mc, ui, r),
    }
}

fn runRow(mc: *MissionControl, ui: *Ui, r: *const mission.Row) void {
    const th = ui.theme();
    const now = mc.p.reg.nowMs();
    const cur = mc.cursor != null and mc.cursor.?.eql(r.run);
    const marked = mc.marked.contains(r.run.toInt());
    var age_buf: [16]u8 = undefined;
    const age = fmtAge(&age_buf, r.ageMs(now));
    // Screen readers hear "title, status, age, cost".
    const label = std.fmt.allocPrint(ui.arena(), "{s}, {s}, {s}, {f}", .{ r.title, statusName(r.status), age, usd(r.cost_micro) }) catch r.title;
    ui.id(@as(u64, @truncate(r.run.toInt())));
    ui.open(.{ .role = .listitem, .label = label, .hit = true, .test_id = if (cur) "mission-cursor" else "", .style = .{
        .dir = .column,
        .grow = 1,
        .padding = .{ .l = 4 + @as(f32, @floatFromInt(r.depth)) * 16, .r = 4, .t = 2, .b = 2 },
        .bg = if (cur or marked) .{ .token = .selection_bg } else .none,
    } });
    defer ui.close();
    const resp = ui.response();
    if (resp.clicked) {
        mc.cursor = r.run;
        mc.marked.clearRetainingCapacity();
    }
    if (resp.double_clicked) {
        mc.cursor = r.run;
        mc.runAction(.attach);
    }
    ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center } });
    ui.text(statusGlyph(r.status, now), .{ .color = statusColor(r.status), .wrap = false });
    if (r.unread) ui.text("\u{25CF}", .{ .color = .accent, .wrap = false });
    ui.text(r.title, .{ .wrap = false, .style = .{ .weight = if (r.unread) 700 else 400 } });
    if (r.progress) |p| ui.textf("{d}/{d}", .{ p.done, p.total }, .{ .color = .fg_muted, .wrap = false });
    ui.open(.{ .style = .{ .grow = 1 } });
    ui.close();
    if (r.pending_review > 0) ui.textf("{d} to review", .{r.pending_review}, .{ .color = .accent, .wrap = false });
    if (r.outputs > 0) ui.textf("{d} out", .{r.outputs}, .{ .color = .fg_muted, .wrap = false });
    ui.textf("{f}", .{usd(r.cost_micro)}, .{ .color = .fg_muted, .wrap = false });
    ui.text(age, .{ .color = .fg_muted, .wrap = false });
    ui.close();
    if (r.line.len > 0) ui.text(r.line, .{ .color = if (r.status == .needs_input) .fg else .fg_muted, .wrap = false });
}

fn peekPanel(ui: *Ui, mc: *MissionControl, id: RunId) void {
    const r = mc.vm.get(id) orelse {
        mc.peek = null;
        return;
    };
    const th = ui.theme();
    ui.open(.{ .role = .group, .label = "Peek", .test_id = "mission-peek", .style = .{ .dir = .column, .gap = 4, .padding = .all(th.dim(.space_sm)), .bg = .{ .token = .bg_elevated } } });
    defer ui.close();
    ui.text(r.title, .{ .style = .{ .weight = 700 } });
    ui.textf("{s} \u{00B7} {f} \u{00B7} {d} output{s}", .{ statusName(r.status), usd(r.cost_micro), r.outputs, if (r.outputs == 1) "" else "s" }, .{ .color = .fg_muted });
    if (r.line.len > 0) ui.text(r.line, .{});
    const v = mc.p.reg.snapshot();
    defer mc.p.reg.release(v);
    if (v.get(id)) |rec| for (rec.outputs, 0..) |o, i| {
        ui.id(@as(u64, i));
        switch (o) {
            .changeset => |cs| ui.textf("changeset {d}", .{cs}, .{ .color = .fg_link }),
            .artifact, .file, .task, .note => |s| ui.text(s, .{ .color = .fg_link }),
            .pr => |pr| ui.textf("PR #{d}", .{pr.number}, .{ .color = .fg_link }),
        }
    };
    if (r.status.isTerminal()) return;
    const rr = zg_gui.w.text_field.textField(ui, .{ .buffer = &mc.reply_field, .a11y_label = "Reply to run", .placeholder = if (r.status == .needs_input) "Answer… (! cmd asks it to run a command)" else "Message the run…" });
    if (rr.submitted) mc.sendReply(mc.reply_field.slice());
}

pub fn groupName(g: mission.Group) []const u8 {
    return switch (g) {
        .pinned => "Pinned",
        .needs_input => "Needs input",
        .ready_for_review => "Ready for review",
        .working => "Working",
        .queued_paused => "Queued and paused",
        .done => "Done",
    };
}

pub fn statusName(s: runs.RunStatus) []const u8 {
    return switch (s) {
        .queued => "queued",
        .starting => "starting",
        .working => "working",
        .needs_input => "needs input",
        .paused => "paused",
        .completed => "completed",
        .failed => "failed",
        .stopped => "stopped",
        .interrupted => "interrupted",
    };
}

/// Working runs spin at 1 Hz (the panel's one-second tick).
fn statusGlyph(s: runs.RunStatus, now_ms: i64) []const u8 {
    const spin = [_][]const u8{ "\u{25D0}", "\u{25D3}", "\u{25D1}", "\u{25D2}" };
    return switch (s) {
        .starting, .working => spin[@intCast(@mod(@divFloor(now_ms, 1000), 4))],
        .needs_input => "?",
        .queued => "\u{25CB}",
        .paused => "\u{2016}",
        .completed => "\u{2713}",
        .failed => "\u{2717}",
        .stopped => "\u{25A0}",
        .interrupted => "!",
    };
}

fn statusColor(s: runs.RunStatus) zg_gui.theme.Token {
    return switch (s) {
        .needs_input, .interrupted => .warning,
        .failed => .danger,
        .completed => .success,
        .starting, .working => .accent,
        else => .fg_muted,
    };
}

/// "now", "42s", "5m", "3h", "2d".
pub fn fmtAge(buf: []u8, ms: i64) []const u8 {
    const s = @divFloor(ms, 1000);
    return (if (s < 5)
        std.fmt.bufPrint(buf, "now", .{})
    else if (s < 60)
        std.fmt.bufPrint(buf, "{d}s", .{s})
    else if (s < 3600)
        std.fmt.bufPrint(buf, "{d}m", .{@divFloor(s, 60)})
    else if (s < 86_400)
        std.fmt.bufPrint(buf, "{d}h", .{@divFloor(s, 3600)})
    else
        std.fmt.bufPrint(buf, "{d}d", .{@divFloor(s, 86_400)})) catch "";
}

const Usd = struct {
    micros: u64,
    pub fn format(u: Usd, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("${d}.{d:0>2}", .{ u.micros / 1_000_000, (u.micros % 1_000_000) / 10_000 });
    }
};

fn usd(micros: u64) Usd {
    return .{ .micros = micros };
}
