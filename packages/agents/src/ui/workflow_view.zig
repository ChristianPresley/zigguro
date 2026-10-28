//! The workflow progress view (E13.F08.S01.T02): a header with the run's
//! status, elapsed time, agents done of started, cost and budget bar, and
//! Pause/Stop/Resume/Save; the steps grouped in collapsible phases, each
//! with a done/failed/running/queued bar; Enter on a step lists its agents
//! (virtualized, `f` cycles the status filter); Space shows an agent's
//! prompt, last activity, result (pretty JSON) or error, attempts and
//! cost. A waiting gate shows its approval card inline, and plans that
//! branch get a mini-map laid out by zg_diagram.
//!
//! Keys while the list has focus are the `workflow.*` actions of
//! `zg_agents.workflow.vm.actions`: Up/Down move, Enter opens a step or
//! an agent's transcript, Space shows an agent or folds a phase, Escape
//! goes back, `f` filter, `x` stop agent, `r` restart agent, `e` expand
//! the prompt, `p` pause/continue, Ctrl+X stop (twice within 2 s),
//! Shift+R resume, Ctrl+S save as workflow, Ctrl+Enter / Ctrl+Backspace
//! answer the gate.
//!
//! The engine's progress is read once per frame; registry events and a
//! 4 Hz timer (while the run is active) wake the view.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const diagram_view = @import("diagram_view.zig");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Window = zg_gui.core.window.Window;
const controls = zg_gui.w.controls;
const scroll = zg_gui.w.scroll;
const TextBuffer = zg_gui.w.text_field.TextBuffer;
const widget = zg_gui.core.widget;
const ev_mod = zg_gui.input.event;

const runs = zg_agents.runs;
const wf = zg_agents.workflow;
const vm_mod = wf.vm;
const RunId = runs.RunId;
const WorkflowVM = wf.WorkflowVM;
const Action = vm_mod.Action;
const Worker = wf.progress.Worker;

pub const Hook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, id: RunId) void,
};

/// Saves run `id`'s definition as workflow `name` (project scope goes
/// through an E12 changeset); returns the changeset, or an error shown in
/// the view.
pub const SaveHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, id: RunId, name: []const u8) anyerror!?u64,
};

pub const Ports = struct {
    eng: *wf.WorkflowEngine,
    run: RunId,
    /// Enter on an agent: opens its transcript (the E10 pane).
    attach: ?Hook = null,
    /// Resume: starts the run again, reusing its finished agents.
    resume_: ?Hook = null,
    save: ?SaveHook = null,
    /// Called from any thread when the run changes; the app schedules a
    /// frame.
    wake: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void } = null,
};

pub const row_h: f32 = 40;
pub const agent_row_h: f32 = 28;

pub const WorkflowView = struct {
    gpa: Allocator,
    p: Ports,
    vm: WorkflowVM,
    save_field: TextBuffer,
    saving: bool = false,
    stop_guard: zg_agents.mission.StopGuard = .{},
    notice: ?[]const u8 = null,
    notice_buf: [200]u8 = undefined,
    listener: ?u32 = null,
    timer: Window.TimerId = .none,
    win: ?*Window = null,
    vid: u16 = 0,
    minimap: ?*diagram_view.DiagramViewState = null,
    minimap_hash: u64 = 0,
    /// Frames that read the engine's progress (tests).
    frames: u32 = 0,

    pub fn init(gpa: Allocator, p: Ports) !*WorkflowView {
        const v = try gpa.create(WorkflowView);
        errdefer gpa.destroy(v);
        v.* = .{ .gpa = gpa, .p = p, .vm = .init(gpa), .save_field = try .init(gpa, "") };
        v.listener = try p.eng.reg.subscribe(.{ .ctx = v, .on_event = onRunEvent });
        return v;
    }

    /// Cancels the timer; call before `deinit` while the window lives.
    pub fn detach(v: *WorkflowView) void {
        if (v.win) |w| if (v.timer != .none) w.cancelTimer(v.timer);
        v.timer = .none;
        v.win = null;
    }

    /// Frees the view; its window is gone or `detach` was called, and no
    /// mini-map layout is pending (`App.joinWork`).
    pub fn deinit(v: *WorkflowView) void {
        if (v.listener) |l| v.p.eng.reg.unsubscribe(l);
        if (v.minimap) |m| m.deinit();
        v.vm.deinit();
        v.save_field.deinit();
        v.gpa.destroy(v);
    }

    fn onRunEvent(ctx: *anyopaque, _: runs.RunEvent) void {
        const v: *WorkflowView = @ptrCast(@alignCast(ctx));
        if (v.p.wake) |w| w.f(w.ctx);
    }

    pub fn build(v: *WorkflowView, ui: *Ui) void {
        workflowView(ui, v);
    }

    fn say(v: *WorkflowView, comptime fmt: []const u8, args: anytype) void {
        v.notice = std.fmt.bufPrint(&v.notice_buf, fmt, args) catch "…";
    }

    /// Reads the engine's progress into the view model; false when the
    /// engine no longer has the run.
    pub fn sync(v: *WorkflowView, arena: Allocator) bool {
        v.frames += 1;
        const p = (v.p.eng.progress(v.p.run, arena) catch return false) orelse return false;
        _ = v.vm.apply(&p) catch v.say("Out of memory", .{});
        return true;
    }

    fn active(v: *const WorkflowView) bool {
        return !v.vm.status.isTerminal();
    }

    /// Runs `a`, as the palette command `workflow.*` does.
    pub fn runAction(v: *WorkflowView, a: Action) void {
        const eng = v.p.eng;
        const id = v.p.run;
        if (a != .stop) v.stop_guard.reset();
        v.notice = null;
        switch (a) {
            .pause => if (v.vm.status == .paused) eng.unpause(id) else if (v.active()) eng.pause(id),
            .stop => {
                if (!v.active()) return;
                switch (v.stop_guard.press(id.toInt(), eng.nowMs())) {
                    .armed => v.say("Press Ctrl+X again to stop the workflow", .{}),
                    .confirmed => eng.stop(id),
                }
            },
            .@"resume" => {
                if (v.active()) return v.say("The workflow is still running", .{});
                const h = v.p.resume_ orelse return v.say("Resume is not available here", .{});
                h.f(h.ctx, id);
            },
            .drill => v.vm.drill() catch {},
            .back => _ = v.vm.back(),
            .filter => if (v.vm.open_step != null) v.vm.cycleFilter() catch {},
            .show_agent => if (v.vm.open_step != null) v.vm.showDetail() else v.vm.togglePhase() catch {},
            .toggle_phase => v.vm.togglePhase() catch {},
            .stop_agent, .restart_agent => {
                const w = v.targetAgent() orelse return;
                if (w.state != .running) return v.say("The agent is not running", .{});
                const r = if (a == .stop_agent) eng.stopAgent(id, w.child) else eng.restartAgent(id, w.child);
                r catch |err| v.say("Cannot {s} the agent: {t}", .{ if (a == .stop_agent) "stop" else "restart", err });
            },
            .open_transcript => {
                const w = v.targetAgent() orelse return;
                if (v.p.attach) |h| h.f(h.ctx, w.child);
            },
            .approve, .reject => {
                const g = v.vm.gate orelse return;
                eng.answerGate(id, g.step, a == .approve, if (a == .reject) "rejected in the workflow view" else null) catch |err| v.say("Cannot answer the gate: {t}", .{err});
            },
            .save_as => {
                if (v.p.save == null) return v.say("Saving is not available here", .{});
                v.saving = !v.saving;
                if (v.saving) v.save_field.setText(v.vm.name) catch {};
            },
            .toggle_prompt => v.vm.prompt_expanded = !v.vm.prompt_expanded,
        }
    }

    /// The agent in detail, else the agent-list cursor.
    fn targetAgent(v: *const WorkflowView) ?*const Worker {
        if (v.vm.detail) |d| return v.vm.worker(d);
        return v.vm.cursorAgent();
    }

    pub fn save(v: *WorkflowView, name: []const u8) void {
        const h = v.p.save orelse return;
        const n = std.mem.trim(u8, name, " ");
        if (!wf.def.validName(n)) return v.say("Use a name like my-workflow ([a-z][a-z0-9-]*)", .{});
        const cs = h.f(h.ctx, v.p.run, n) catch |err| return v.say("Cannot save: {t}", .{err});
        v.saving = false;
        if (cs) |c| v.say("Proposed .zigguro/workflows/{s}.zon for review (changeset {d})", .{ n, c }) else v.say("Saved workflow {s}", .{n});
    }

    fn onKey(v: *WorkflowView, k: ev_mod.KeyPress) bool {
        if (k.action == .release) return false;
        const m = k.mods;
        const a: Action = switch (k.key) {
            .arrow_down, .arrow_up, .page_down, .page_up => {
                const d: i32 = switch (k.key) {
                    .arrow_down => 1,
                    .arrow_up => -1,
                    .page_down => 10,
                    else => -10,
                };
                v.vm.move(d);
                return true;
            },
            .enter, .numpad_enter => if (m.ctrl) .approve else if (v.vm.open_step != null) .open_transcript else .drill,
            .backspace => if (m.ctrl) .reject else return false,
            .space => .show_agent,
            .escape => if (v.vm.open_step != null or v.vm.detail != null) .back else return false,
            .key_f => .filter,
            .key_x => if (m.ctrl) .stop else .stop_agent,
            .key_r => if (m.shift) .@"resume" else .restart_agent,
            .key_p => .pause,
            .key_e => .toggle_prompt,
            .key_s => if (m.ctrl) .save_as else return false,
            else => return false,
        };
        v.runAction(a);
        return true;
    }

    fn onTimer(ctx: *anyopaque, w: *Window) void {
        const v: *WorkflowView = @ptrCast(@alignCast(ctx));
        v.timer = .none;
        w.markViewDirty(v.vid);
    }

    /// Four frames a second while the run is active (elapsed time and
    /// counters the registry does not announce).
    fn scheduleTick(v: *WorkflowView, ui: *Ui) void {
        const w = ui.window();
        v.win = w;
        v.vid = ui.currentView();
        if (v.timer != .none or !v.active()) return;
        v.timer = w.setTimer(w.app.now_ms + 250, .{ .ctx = v, .f = onTimer }) catch .none;
    }

    /// Feeds the mini-map a new source when the plan's states changed.
    fn updateMiniMap(v: *WorkflowView, ui: *Ui) void {
        if (!v.vm.branches()) return;
        const th = ui.theme();
        if (v.minimap == null) {
            v.minimap = diagram_view.DiagramViewState.init(v.gpa, v.p.eng.io, ui.window().app, .{ .theme = diagram_view.themeFromTokens(th) }) catch return;
        }
        var bufs: [6][8]u8 = undefined;
        const colors: vm_mod.MiniMapColors = .{
            .pending = hex(&bufs[0], th.color(.fg_muted)),
            .running = hex(&bufs[1], th.color(.accent)),
            .waiting = hex(&bufs[2], th.color(.warning)),
            .done = hex(&bufs[3], th.color(.success)),
            .failed = hex(&bufs[4], th.color(.danger)),
            .skipped = hex(&bufs[5], th.color(.border_strong)),
        };
        var w: std.Io.Writer.Allocating = .init(ui.arena());
        vm_mod.miniMap(&v.vm, &w.writer, colors) catch return;
        const h = std.hash.Wyhash.hash(0, w.written());
        if (h == v.minimap_hash) return;
        v.minimap_hash = h;
        v.minimap.?.setSource(w.written()) catch {};
    }
};

fn hex(buf: *[8]u8, c: zg_gui.core.geom.Color) []const u8 {
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch "#888888";
}

/// The focusable container: the view's keys.
const KeyBox = struct {
    pub const name = "workflow_view";
    pub const focusable = true;
    pub const Props = struct { v: *WorkflowView, rows: usize };

    pub fn style(_: *const Props, _: *const zg_gui.theme.Theme) zg_gui.Style {
        return .{ .dir = .column, .grow = 1, .gap = 2 };
    }

    pub fn event(ec: *ev_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const ev_mod.InputEvent) bool {
        if (ec.phase == .capture) return false;
        const k = switch (ev.*) {
            .key => |k| k,
            else => return false,
        };
        if (!props.v.onKey(k)) return false;
        ec.respond(.{ .changed = true });
        return true;
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .list, .name = "Workflow steps", .row_count = @intCast(props.rows) };
    }
};

/// The view.
pub fn workflowView(ui: *Ui, v: *WorkflowView) void {
    const th = ui.theme();
    ui.open(.{ .style = .{ .dir = .column, .gap = th.dim(.space_sm), .padding = .all(th.dim(.space_sm)), .grow = 1 }, .test_id = "workflow-view" });
    defer ui.close();
    if (!v.sync(ui.arena())) {
        ui.text("This workflow run is no longer loaded.", .{ .color = .fg_muted });
        return;
    }
    v.updateMiniMap(ui);
    header(ui, v);
    if (v.notice) |n| {
        ui.open(.{ .role = .status, .label = n, .test_id = "workflow-notice" });
        ui.text(n, .{ .color = .warning });
        ui.close();
    }
    if (v.saving) saveBox(ui, v);
    if (v.vm.gate) |g| gateCard(ui, v, g);
    if (v.vm.error_) |e| ui.text(e, .{ .color = .danger });

    // Fixed ids: the notice, gate and save rows above come and go, and
    // the key box must keep its focus.
    ui.id(0x776f726b);
    ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .grow = 1 } });
    ui.id(1);
    _ = ui.begin(KeyBox, .{ .v = v, .rows = if (v.vm.open_step != null) v.vm.agents.items.len else v.vm.items.items.len });
    if (v.vm.open_step) |s| agentList(ui, v, s) else stepList(ui, v);
    ui.end(KeyBox);
    if (v.minimap) |m| if (v.vm.branches()) {
        ui.open(.{ .style = .{ .dir = .column, .w = .{ .px = 240 } }, .test_id = "workflow-minimap" });
        diagram_view.diagramView(ui, m, .{ .max_w = 240, .max_h = 360, .label = "Workflow map" });
        ui.close();
    };
    ui.close();
    if (v.vm.detail) |d| if (v.vm.worker(d)) |w| agentDetail(ui, v, w);
    v.scheduleTick(ui);
}

fn header(ui: *Ui, v: *WorkflowView) void {
    const th = ui.theme();
    const vm = &v.vm;
    const t = vm.totals;
    var el_buf: [16]u8 = undefined;
    const elapsed = elapsedOf(v, &el_buf);
    const label = std.fmt.allocPrint(ui.arena(), "{s}, {s}, {s}, {d} of {d} agents done, {f}", .{ vm.name, statusName(vm.status), elapsed, t.done, t.agents, usd(t.cost_micros) }) catch vm.name;
    ui.open(.{ .role = .group, .label = label, .test_id = "workflow-header", .style = .{ .dir = .column, .gap = 4 } });
    defer ui.close();
    ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center } });
    ui.text(vm.name, .{ .wrap = false, .style = .{ .weight = 700 } });
    ui.text(statusName(vm.status), .{ .color = statusColor(vm.status), .wrap = false });
    ui.text(elapsed, .{ .color = .fg_muted, .wrap = false });
    ui.textf("{d}/{d} agents", .{ t.done, t.agents }, .{ .color = .fg_muted, .wrap = false });
    if (t.running > 0) ui.textf("{d} running", .{t.running}, .{ .color = .accent, .wrap = false });
    if (t.failed > 0) ui.textf("{d} failed", .{t.failed}, .{ .color = .danger, .wrap = false });
    ui.textf("{f}", .{usd(t.cost_micros)}, .{ .color = .fg_muted, .wrap = false });
    ui.textf("{d} tokens", .{t.tokens}, .{ .color = .fg_muted, .wrap = false });
    controls.spacer(ui);
    const active = v.active();
    if (controls.button(ui, .{ .label = if (vm.status == .paused) "Continue" else "Pause", .disabled = !active }).clicked) v.runAction(.pause);
    if (controls.button(ui, .{ .label = "Stop", .disabled = !active }).clicked) {
        v.runAction(.stop);
        v.runAction(.stop);
    }
    if (v.p.resume_ != null and controls.button(ui, .{ .label = "Resume", .disabled = active }).clicked) v.runAction(.@"resume");
    if (v.p.save != null and controls.button(ui, .{ .label = "Save as workflow…", .disabled = active }).clicked) v.runAction(.save_as);
    ui.close();
    if (t.budgetUsed()) |u| {
        ui.open(.{ .role = .status, .label = "Budget used", .test_id = "workflow-budget", .style = .{ .dir = .row, .gap = 6, .align_items = .center } });
        ui.textf("budget {f} of {f}", .{ usd(t.cost_micros), usd(t.budget_micros.?) }, .{ .color = .fg_muted, .wrap = false });
        ui.open(.{ .style = .{ .grow = 1 } });
        controls.progress(ui, u);
        ui.close();
        ui.close();
    }
}

fn elapsedOf(v: *WorkflowView, buf: []u8) []const u8 {
    const reg = v.p.eng.reg;
    const s = reg.snapshot();
    defer reg.release(s);
    const rec = s.get(v.p.run) orelse return "";
    const started = rec.started_ms orelse rec.created_ms;
    const end = rec.ended_ms orelse reg.nowMs();
    return fmtDuration(buf, end - started);
}

fn saveBox(ui: *Ui, v: *WorkflowView) void {
    ui.open(.{ .style = .{ .dir = .row, .gap = 4 }, .test_id = "workflow-save" });
    defer ui.close();
    ui.open(.{ .style = .{ .grow = 1 } });
    const r = zg_gui.w.text_field.textField(ui, .{ .buffer = &v.save_field, .a11y_label = "Workflow name", .placeholder = "my-workflow" });
    ui.close();
    if (r.submitted) v.save(v.save_field.slice()) else if (r.cancelled) {
        v.saving = false;
    }
    if (controls.button(ui, .{ .label = "Save", .variant = .primary }).clicked) v.save(v.save_field.slice());
}

fn gateCard(ui: *Ui, v: *WorkflowView, g: wf.progress.Gate) void {
    const th = ui.theme();
    ui.open(.{ .role = .group, .label = g.title, .test_id = "workflow-gate", .style = .{ .dir = .column, .gap = 6, .padding = .all(th.dim(.space_sm)), .bg = .{ .token = .bg_elevated }, .radius = th.dim(.radius_md), .border = .{ .token = .warning }, .border_w = 1 } });
    defer ui.close();
    ui.text(g.title, .{ .style = .{ .weight = 700 } });
    if (g.show.len > 0) ui.text(g.show[0..@min(g.show.len, 4000)], .{ .color = .fg_muted });
    ui.open(.{ .style = .{ .dir = .row, .gap = 6 } });
    if (controls.button(ui, .{ .label = "Approve", .variant = .primary }).clicked) v.runAction(.approve);
    if (controls.button(ui, .{ .label = "Reject" }).clicked) v.runAction(.reject);
    ui.close();
}

fn stepList(ui: *Ui, v: *WorkflowView) void {
    if (v.vm.items.items.len == 0) {
        ui.text("No steps.", .{ .color = .fg_muted });
        return;
    }
    _ = scroll.virtualList(ui, .{ .count = v.vm.items.items.len, .row_h = row_h, .test_id = "workflow-steps" }, v, itemRow);
}

fn itemRow(v: *WorkflowView, ui: *Ui, i: usize) void {
    const vm = &v.vm;
    if (i >= vm.items.items.len) return;
    const cur = vm.cursor == i;
    switch (vm.items.items[i]) {
        .phase => |pi| {
            const ph = vm.phases[pi];
            ui.id(@as(u64, pi) + 1);
            var done: u32 = 0;
            for (ph.steps) |s| done += @intFromBool(vm.steps[s].p.state == .done or vm.steps[s].p.state == .skipped);
            const label = std.fmt.allocPrint(ui.arena(), "{s} {s} ({d}/{d} steps)", .{ if (ph.collapsed) "\u{25B8}" else "\u{25BE}", ph.title orelse "", done, ph.steps.len }) catch "";
            ui.open(.{ .role = .group, .label = label, .hit = true, .test_id = if (cur) "workflow-cursor" else "", .style = .{ .padding = .xy(4, 8), .grow = 1, .bg = if (cur) .{ .token = .selection_bg } else .none } });
            if (ui.response().clicked) {
                vm.cursor = i;
                vm.togglePhase() catch {};
            }
            ui.text(label, .{ .color = .fg_muted, .wrap = false, .style = .{ .weight = 700 } });
            ui.close();
        },
        .step => |si| stepRow(v, ui, i, si, cur),
    }
}

fn stepRow(v: *WorkflowView, ui: *Ui, i: usize, si: u32, cur: bool) void {
    const th = ui.theme();
    const r = v.vm.steps[si];
    const s = r.p;
    const name = s.label orelse s.id;
    const label = std.fmt.allocPrint(ui.arena(), "{s}, {s}, {s}, {d} done, {d} failed, {d} running, {d} queued", .{ name, @tagName(s.kind), @tagName(s.state), s.done, s.failed, s.running, r.queued }) catch name;
    ui.id(@as(u64, si) + 1000);
    ui.open(.{ .role = .listitem, .label = label, .hit = true, .test_id = if (cur) "workflow-cursor" else "", .style = .{
        .dir = .column,
        .gap = 2,
        .grow = 1,
        .padding = .{ .l = 8 + @as(f32, if (s.parent != null) 16 else 0), .r = 4, .t = 2, .b = 2 },
        .bg = if (cur) .{ .token = .selection_bg } else .none,
    } });
    defer ui.close();
    const resp = ui.response();
    if (resp.clicked) v.vm.cursor = i;
    if (resp.double_clicked) {
        v.vm.cursor = i;
        v.runAction(.drill);
    }
    ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center } });
    ui.text(kindGlyph(s.kind), .{ .color = stateColor(s.state), .wrap = false });
    ui.text(name, .{ .wrap = false });
    if (s.label != null) ui.text(s.id, .{ .color = .fg_muted, .wrap = false });
    controls.spacer(ui);
    if (s.total > 0) ui.textf("{d}/{d}", .{ s.done, s.total }, .{ .color = .fg_muted, .wrap = false });
    if (s.round > 0 and s.kind == .loop_until) ui.textf("round {d}", .{s.round}, .{ .color = .fg_muted, .wrap = false });
    if (s.retries > 0) ui.textf("{d} retries", .{s.retries}, .{ .color = .warning, .wrap = false });
    if (s.reused > 0) ui.textf("{d} reused", .{s.reused}, .{ .color = .fg_muted, .wrap = false });
    ui.text(@tagName(s.state), .{ .color = stateColor(s.state), .wrap = false });
    ui.close();
    if (s.error_) |e| ui.text(e, .{ .color = .danger, .wrap = false }) else segmentBar(ui, s.done, s.failed, s.running, r.queued);
}

/// Done, failed, running and queued as proportional segments.
fn segmentBar(ui: *Ui, done: u32, failed: u32, running: u32, queued: u32) void {
    const th = ui.theme();
    ui.open(.{ .style = .{ .dir = .row, .h = .{ .px = 4 }, .grow = 0, .radius = 2, .bg = .{ .token = .bg_sunken } } });
    defer ui.close();
    const parts = [_]struct { n: u32, tok: zg_gui.theme.Token }{
        .{ .n = done, .tok = .success },
        .{ .n = failed, .tok = .danger },
        .{ .n = running, .tok = .accent },
        .{ .n = queued, .tok = .border_strong },
    };
    _ = th;
    for (parts, 0..) |p, k| {
        if (p.n == 0) continue;
        ui.id(@as(u64, k));
        ui.open(.{ .style = .{ .grow = @floatFromInt(p.n), .basis = .{ .px = 0 }, .h = .{ .px = 4 }, .bg = .{ .token = p.tok } } });
        ui.close();
    }
}

fn agentList(ui: *Ui, v: *WorkflowView, si: u32) void {
    const th = ui.theme();
    const s = v.vm.steps[si].p;
    ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center }, .test_id = "workflow-agents-header" });
    ui.textf("{s}: {d} agents", .{ s.label orelse s.id, v.vm.agents.items.len }, .{ .style = .{ .weight = 700 }, .wrap = false });
    ui.textf("filter: {s} (f)", .{v.vm.filter.name()}, .{ .color = .fg_muted, .wrap = false });
    controls.spacer(ui);
    if (controls.button(ui, .{ .label = "Back" }).clicked) _ = v.vm.back();
    ui.close();
    if (v.vm.agents.items.len == 0) {
        ui.text("No agents match the filter.", .{ .color = .fg_muted });
        return;
    }
    _ = scroll.virtualList(ui, .{ .count = v.vm.agents.items.len, .row_h = agent_row_h, .test_id = "workflow-agents" }, v, agentRow);
}

fn agentRow(v: *WorkflowView, ui: *Ui, i: usize) void {
    const vm = &v.vm;
    if (i >= vm.agents.items.len) return;
    const w = &vm.workers[vm.agents.items[i]];
    const cur = vm.agent_cursor == i;
    const label = std.fmt.allocPrint(ui.arena(), "{s}, {s}, attempt {d}, {f}", .{ w.pos, @tagName(w.state), w.attempt + 1, usd(w.cost.micros) }) catch w.pos;
    ui.id(@as(u64, @truncate(w.child.toInt())));
    ui.open(.{ .role = .listitem, .label = label, .hit = true, .test_id = if (cur) "workflow-agent-cursor" else "", .style = .{ .dir = .row, .gap = 8, .grow = 1, .align_items = .center, .padding = .xy(6, 2), .bg = if (cur) .{ .token = .selection_bg } else .none } });
    defer ui.close();
    const resp = ui.response();
    if (resp.clicked) {
        vm.agent_cursor = i;
        vm.showDetail();
    }
    if (resp.double_clicked) {
        vm.agent_cursor = i;
        v.runAction(.open_transcript);
    }
    ui.text(workerGlyph(w.state), .{ .color = workerColor(w.state), .wrap = false });
    ui.text(w.pos, .{ .wrap = false });
    if (w.attempt > 0) ui.textf("attempt {d}", .{w.attempt + 1}, .{ .color = .warning, .wrap = false });
    const line = firstLine(w.text);
    if (line.len > 0) ui.text(line, .{ .color = if (w.state == .failed) .danger else .fg_muted, .wrap = false });
    controls.spacer(ui);
    ui.textf("{f}", .{usd(w.cost.micros)}, .{ .color = .fg_muted, .wrap = false });
}

fn agentDetail(ui: *Ui, v: *WorkflowView, w: *const Worker) void {
    const th = ui.theme();
    ui.open(.{ .role = .group, .label = "Agent detail", .test_id = "workflow-agent-detail", .style = .{ .dir = .column, .gap = 4, .padding = .all(th.dim(.space_sm)), .bg = .{ .token = .bg_elevated }, .radius = th.dim(.radius_md) } });
    defer ui.close();
    ui.open(.{ .style = .{ .dir = .row, .gap = 8, .align_items = .center } });
    ui.text(w.pos, .{ .style = .{ .weight = 700 }, .wrap = false });
    ui.text(@tagName(w.state), .{ .color = workerColor(w.state), .wrap = false });
    ui.textf("attempt {d} of {d}", .{ w.attempt + 1, v.vm.attemptsAt(w) }, .{ .color = .fg_muted, .wrap = false });
    ui.textf("{f}, {d} tokens", .{ usd(w.cost.micros), w.cost.input_tokens + w.cost.output_tokens }, .{ .color = .fg_muted, .wrap = false });
    controls.spacer(ui);
    const running = w.state == .running;
    if (controls.button(ui, .{ .label = "Stop agent", .disabled = !running }).clicked) v.runAction(.stop_agent);
    if (controls.button(ui, .{ .label = "Restart", .disabled = !running }).clicked) v.runAction(.restart_agent);
    if (v.p.attach != null and controls.button(ui, .{ .label = "Transcript" }).clicked) v.runAction(.open_transcript);
    ui.close();

    // Prompt: three lines unless expanded.
    const prompt = if (v.vm.prompt_expanded) w.prompt else firstLines(w.prompt, 3);
    ui.open(.{ .role = .group, .label = "Prompt", .test_id = "workflow-agent-prompt", .style = .{ .dir = .column, .gap = 2 } });
    ui.text(prompt, .{ .color = .fg_muted });
    if (prompt.len < w.prompt.len or v.vm.prompt_expanded) {
        if (controls.button(ui, .{ .label = if (v.vm.prompt_expanded) "Show less" else "Show the whole prompt" }).clicked) v.runAction(.toggle_prompt);
    }
    ui.close();

    // Last activity from the child run.
    {
        const reg = v.p.eng.reg;
        const s = reg.snapshot();
        defer reg.release(s);
        if (s.get(w.child)) |rec| if (rec.summary.len > 0) ui.text(ui.arena().dupe(u8, rec.summary) catch "", .{ .color = .fg_muted });
    }

    switch (w.state) {
        .running => ui.text("Working…", .{ .color = .accent }),
        .failed, .stopped => ui.text(w.text, .{ .color = .danger }),
        .done => {
            ui.open(.{ .role = .group, .label = "Result", .test_id = "workflow-agent-result" });
            ui.text(prettyResult(ui.arena(), w.text), .{});
            ui.close();
        },
    }
}

/// The answer as indented JSON when it is JSON, else as written.
pub fn prettyResult(a: Allocator, text: []const u8) []const u8 {
    const v = wf.step_agent.parseAnswer(a, text) orelse return text;
    if (v != .object and v != .array) return text;
    return std.json.Stringify.valueAlloc(a, v, .{ .whitespace = .indent_2 }) catch text;
}

fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    return t[0..@min(end, 160)];
}

fn firstLines(s: []const u8, n: usize) []const u8 {
    var at: usize = 0;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        at = (std.mem.indexOfScalarPos(u8, s, at, '\n') orelse return s) + 1;
    }
    return s[0 .. at - 1];
}

fn kindGlyph(k: wf.StepKind) []const u8 {
    return switch (k) {
        .agent => "\u{25C6}",
        .reduce => "\u{25BC}",
        .map => "\u{2261}",
        .parallel => "\u{2225}",
        .vote => "\u{2696}",
        .loop_until => "\u{21BB}",
        .gate => "\u{2691}",
        .builtin => "\u{0192}",
        .command => "$",
    };
}

fn stateColor(s: wf.progress.StepState) zg_gui.theme.Token {
    return switch (s) {
        .pending, .skipped => .fg_muted,
        .running => .accent,
        .waiting => .warning,
        .done => .success,
        .failed => .danger,
    };
}

fn workerGlyph(s: wf.progress.WorkerState) []const u8 {
    return switch (s) {
        .running => "\u{25D0}",
        .done => "\u{2713}",
        .failed => "\u{2717}",
        .stopped => "\u{25A0}",
    };
}

fn workerColor(s: wf.progress.WorkerState) zg_gui.theme.Token {
    return switch (s) {
        .running => .accent,
        .done => .success,
        .failed => .danger,
        .stopped => .fg_muted,
    };
}

const statusName = @import("mission_control.zig").statusName;

fn statusColor(s: runs.RunStatus) zg_gui.theme.Token {
    return switch (s) {
        .needs_input, .interrupted => .warning,
        .failed => .danger,
        .completed => .success,
        .starting, .working => .accent,
        else => .fg_muted,
    };
}

/// "4s", "2m 05s", "1h 03m".
pub fn fmtDuration(buf: []u8, ms: i64) []const u8 {
    const s: u64 = @intCast(@max(0, @divFloor(ms, 1000)));
    return (if (s < 60)
        std.fmt.bufPrint(buf, "{d}s", .{s})
    else if (s < 3600)
        std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ s / 60, s % 60 })
    else
        std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ s / 3600, (s % 3600) / 60 })) catch "";
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
