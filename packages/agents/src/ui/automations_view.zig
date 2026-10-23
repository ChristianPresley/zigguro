//! The Automations manager (E13.F02.S01.T03): every automation with its
//! state, schedule in words, next fire (local time), last status and
//! month-to-date cost; an approval banner for automations that came with
//! the repository; and, for the selected one, an editor (description,
//! cron with a live description and the next five fires, prompt,
//! permission profile), "Run now", and its history.
//!
//! Saving goes through `Ports.save`: the app turns it into an E12
//! changeset applied at once (the user's own edit is the approval), then
//! the view reloads the service.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const controls = zg_gui.w.controls;
const TextBuffer = zg_gui.w.text_field.TextBuffer;

const sched = zg_agents.sched;
const Automation = sched.Automation;

pub const Ports = struct {
    service: *sched.Service,
    /// Writes `.zigguro/automations/<name>.zon` (`base` null creates it).
    save: struct {
        ctx: *anyopaque,
        f: *const fn (ctx: *anyopaque, path: []const u8, base: ?[]const u8, text: []const u8) anyerror!void,
    },
    /// Approves a repository automation's current content (E16 pin).
    approve: ?struct {
        ctx: *anyopaque,
        f: *const fn (ctx: *anyopaque, name: []const u8, hash: sched.loader.Hash) anyerror!void,
    } = null,
    /// The profiles the picker offers.
    profiles: []const []const u8 = &.{ "unattended-readonly", "unattended-notes-write", "unattended-lane-write" },
};

pub const AutomationsView = struct {
    gpa: Allocator,
    p: Ports,
    arena: std.heap.ArenaAllocator,
    rows: []sched.tools.Row = &.{},
    costs: []u64 = &.{},
    selected: ?usize = null,
    /// The editor's fields, loaded from the selected automation.
    description: TextBuffer,
    cron_text: TextBuffer,
    prompt: TextBuffer,
    profile: usize = 0,
    /// The editor holds a new automation (named by `new_name`).
    creating: bool = false,
    new_name: TextBuffer,
    notice: ?[]const u8 = null,
    notice_buf: [200]u8 = undefined,
    history: []const sched.history.Record = &.{},

    pub fn init(gpa: Allocator, p: Ports) !*AutomationsView {
        const v = try gpa.create(AutomationsView);
        errdefer gpa.destroy(v);
        v.* = .{
            .gpa = gpa,
            .p = p,
            .arena = .init(gpa),
            .description = try .init(gpa, ""),
            .cron_text = try .init(gpa, ""),
            .prompt = try .init(gpa, ""),
            .new_name = try .init(gpa, ""),
        };
        v.refresh();
        return v;
    }

    pub fn deinit(v: *AutomationsView) void {
        v.arena.deinit();
        v.description.deinit();
        v.cron_text.deinit();
        v.prompt.deinit();
        v.new_name.deinit();
        v.gpa.destroy(v);
    }

    pub fn build(v: *AutomationsView, ui: *Ui) void {
        automationsView(ui, v);
    }

    fn say(v: *AutomationsView, comptime fmt: []const u8, args: anytype) void {
        v.notice = std.fmt.bufPrint(&v.notice_buf, fmt, args) catch "…";
    }

    /// Re-reads the rows (after a reload, a save or a fire).
    pub fn refresh(v: *AutomationsView) void {
        _ = v.arena.reset(.retain_capacity);
        const a = v.arena.allocator();
        const src = v.p.service.source();
        v.rows = sched.tools.listRows(&src, a) catch &.{};
        v.costs = a.alloc(u64, v.rows.len) catch &.{};
        for (v.rows, v.costs) |r, *c| c.* = v.p.service.runner.monthCostMicros(r.name);
        if (v.selected) |i| if (i >= v.rows.len) {
            v.selected = null;
        };
        v.history = &.{};
        if (v.selected) |i| {
            v.history = sched.history.readTail(a, v.p.service.io, v.p.service.hist, v.rows[i].name, 10) catch &.{};
        }
    }

    fn loadedAutomation(v: *AutomationsView, name: []const u8) ?*const sched.loader.Loaded {
        const l = &(v.p.service.loaded orelse return null);
        return l.find(name);
    }

    /// Selects row `i` and fills the editor from it.
    pub fn select(v: *AutomationsView, i: usize) void {
        if (i >= v.rows.len) return;
        v.selected = i;
        v.creating = false;
        v.notice = null;
        const l = v.loadedAutomation(v.rows[i].name);
        const a: ?Automation = if (l) |x| x.automation else null;
        v.description.setText(if (a) |x| x.description else "") catch {};
        v.cron_text.setText(if (a) |x| if (x.schedule()) |s| s.cron else "" else "") catch {};
        v.prompt.setText(if (a) |x| switch (x.action) {
            .agent => |g| g.prompt,
            .workflow => "",
        } else "") catch {};
        v.profile = 0;
        if (a) |x| for (v.p.profiles, 0..) |p, k| {
            if (std.mem.eql(u8, p, x.profile)) v.profile = k;
        };
        v.refresh();
    }

    /// Opens the editor on a new automation.
    pub fn startNew(v: *AutomationsView) void {
        v.selected = null;
        v.creating = true;
        v.notice = null;
        v.new_name.setText("") catch {};
        v.description.setText("") catch {};
        v.cron_text.setText("0 9 * * 1-5") catch {};
        v.prompt.setText("") catch {};
        v.profile = 0;
    }

    /// Saves the editor's fields.
    pub fn save(v: *AutomationsView) void {
        var arena: std.heap.ArenaAllocator = .init(v.gpa);
        defer arena.deinit();
        const ar = arena.allocator();
        var base: ?[]const u8 = null;
        var a: Automation = undefined;
        if (v.creating) {
            const name = std.mem.trim(u8, v.new_name.slice(), " ");
            a = .{ .name = ar.dupe(u8, name) catch return, .triggers = &.{}, .action = .{ .agent = .{ .prompt = "" } }, .budgets = .{ .max_cost_micro_usd = 500_000 } };
        } else {
            const i = v.selected orelse return;
            const l = v.loadedAutomation(v.rows[i].name) orelse return v.say("Fix the file's problems first", .{});
            a = l.automation orelse return v.say("Fix the file's problems first", .{});
            base = l.source;
        }
        a.description = ar.dupe(u8, v.description.slice()) catch return;
        const cron_s = std.mem.trim(u8, v.cron_text.slice(), " ");
        var triggers: std.ArrayList(sched.automation.Trigger) = .empty;
        for (a.triggers) |t| if (t != .schedule) triggers.append(ar, t) catch return;
        if (cron_s.len > 0) triggers.append(ar, .{ .schedule = .{ .cron = ar.dupe(u8, cron_s) catch return } }) catch return;
        a.triggers = triggers.items;
        switch (a.action) {
            .agent => |*g| g.prompt = ar.dupe(u8, v.prompt.slice()) catch return,
            .workflow => {},
        }
        a.profile = v.p.profiles[v.profile];
        if (sched.automation.validate(&a, a.name)) |msg| return v.say("Cannot save: {s}", .{msg});
        const text = sched.automation.toZon(ar, &a) catch return;
        const path = std.fmt.allocPrint(ar, "{s}/{s}.zon", .{ sched.loader.dir_path, a.name }) catch return;
        v.p.save.f(v.p.save.ctx, path, base, text) catch |e| return v.say("Cannot save: {t}", .{e});
        v.approveText(a.name, text);
        v.p.service.reload() catch {};
        v.creating = false;
        v.refresh();
        for (v.rows, 0..) |r, k| if (std.mem.eql(u8, r.name, a.name)) {
            v.selected = k;
        };
        v.say("Saved {s}", .{a.name});
    }

    /// Flips `enabled` for row `i`.
    pub fn toggle(v: *AutomationsView, i: usize) void {
        if (i >= v.rows.len) return;
        const l = v.loadedAutomation(v.rows[i].name) orelse return;
        var a = l.automation orelse return;
        a.enabled = !v.rows[i].enabled;
        const text = sched.automation.toZon(v.gpa, &a) catch return;
        defer v.gpa.free(text);
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ sched.loader.dir_path, l.file }) catch return;
        v.p.save.f(v.p.save.ctx, path, l.source, text) catch |e| return v.say("Cannot save: {t}", .{e});
        v.approveText(a.name, text);
        v.p.service.reload() catch {};
        v.refresh();
    }

    /// The user's own save approves what was saved.
    fn approveText(v: *AutomationsView, name: []const u8, text: []const u8) void {
        const ap = v.p.approve orelse return;
        var h: sched.loader.Hash = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &h, .{});
        ap.f(ap.ctx, name, h) catch |e| v.say("Saved, but not approved: {t}", .{e});
    }

    pub fn runNow(v: *AutomationsView, i: usize) void {
        if (i >= v.rows.len) return;
        const id = v.p.service.scheduler.fireNow(v.rows[i].name) catch |e| return v.say("Cannot run: {t}", .{e});
        v.say("Started {s} (fire {d})", .{ v.rows[i].name, id });
        v.refresh();
    }

    pub fn approve(v: *AutomationsView, i: usize) void {
        if (i >= v.rows.len) return;
        const ap = v.p.approve orelse return;
        const l = v.loadedAutomation(v.rows[i].name) orelse return;
        ap.f(ap.ctx, l.name, l.hash) catch |e| return v.say("Cannot approve: {t}", .{e});
        v.p.service.reload() catch {};
        v.refresh();
    }
};

/// The view.
pub fn automationsView(ui: *Ui, v: *AutomationsView) void {
    const th = ui.theme();
    ui.open(.{ .style = .{ .dir = .column, .gap = th.dim(.space_sm), .padding = .all(th.dim(.space_sm)), .grow = 1 }, .test_id = "automations" });
    defer ui.close();
    ui.open(.{ .style = .{ .dir = .row, .gap = 4, .align_items = .center } });
    ui.text("Automations", .{ .style = .{ .weight = 700 } });
    ui.open(.{ .style = .{ .grow = 1 } });
    ui.close();
    if (controls.button(ui, .{ .label = "New automation" }).clicked) v.startNew();
    ui.close();
    if (v.notice) |n| {
        ui.open(.{ .role = .status, .label = n, .test_id = "automations-notice" });
        ui.text(n, .{ .color = .warning });
        ui.close();
    }
    if (v.rows.len == 0 and !v.creating) ui.text("No automations yet. Create one to run an agent on a schedule.", .{ .color = .fg_muted });
    ui.open(.{ .role = .list, .label = "Automations", .style = .{ .dir = .column, .gap = 2 } });
    for (v.rows, 0..) |r, i| row(ui, v, r, i);
    ui.close();
    if (v.creating or v.selected != null) editor(ui, v);
}

fn row(ui: *Ui, v: *AutomationsView, r: sched.tools.Row, i: usize) void {
    const th = ui.theme();
    const state: []const u8 = if (r.problem != null) "invalid" else if (r.needs_approval) "needs approval" else if (r.enabled) "enabled" else "disabled";
    const next = if (r.next_fires.len > 0) r.next_fires[0] else "-";
    const label = std.fmt.allocPrint(ui.arena(), "{s}, {s}, next {s}", .{ r.name, state, next }) catch r.name;
    const sel = v.selected != null and v.selected.? == i;
    ui.id(@as(u64, i));
    ui.open(.{ .role = .listitem, .label = label, .hit = true, .test_id = if (sel) "automation-selected" else "", .style = .{
        .dir = .column,
        .padding = .xy(4, 2),
        .bg = if (sel) .{ .token = .selection_bg } else .none,
    } });
    defer ui.close();
    if (ui.response().clicked) v.select(i);
    ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center } });
    ui.text(r.name, .{ .wrap = false, .style = .{ .weight = 700 } });
    ui.text(state, .{ .color = if (r.problem != null) .danger else if (r.enabled) .success else .fg_muted, .wrap = false });
    ui.open(.{ .style = .{ .grow = 1 } });
    ui.close();
    ui.textf("next {s}", .{next}, .{ .color = .fg_muted, .wrap = false });
    if (r.last_status) |s| ui.textf("last {s}", .{s}, .{ .color = if (std.mem.eql(u8, s, "fired")) .fg_muted else .warning, .wrap = false });
    const cost = if (i < v.costs.len) v.costs[i] else 0;
    ui.textf("${d}.{d:0>2} this month", .{ cost / 1_000_000, cost % 1_000_000 / 10_000 }, .{ .color = .fg_muted, .wrap = false });
    if (r.problem == null and !r.needs_approval) {
        if (controls.button(ui, .{ .label = if (r.enabled) "Disable" else "Enable", .variant = .ghost }).clicked) v.toggle(i);
        if (controls.button(ui, .{ .label = "Run now", .variant = .ghost, .disabled = !r.enabled }).clicked) v.runNow(i);
    }
    ui.close();
    ui.text(r.problem orelse r.triggers, .{ .color = if (r.problem != null) .danger else .fg_muted, .wrap = false });
    if (r.needs_approval) {
        ui.open(.{ .role = .group, .label = "Approval", .style = .{ .dir = .row, .gap = 4, .align_items = .center } });
        ui.text("New automation from the repository: review and enable.", .{ .color = .warning });
        if (controls.button(ui, .{ .label = "Review & enable", .variant = .primary, .disabled = v.p.approve == null }).clicked) v.approve(i);
        ui.close();
    }
}

fn editor(ui: *Ui, v: *AutomationsView) void {
    const th = ui.theme();
    ui.open(.{ .role = .group, .label = "Edit automation", .test_id = "automation-editor", .style = .{ .dir = .column, .gap = 4, .padding = .all(th.dim(.space_sm)), .bg = .{ .token = .bg_elevated } } });
    defer ui.close();
    if (v.creating) {
        _ = zg_gui.w.text_field.textField(ui, .{ .buffer = &v.new_name, .a11y_label = "Name", .placeholder = "name (a-z, 0-9, -)" });
    }
    _ = zg_gui.w.text_field.textField(ui, .{ .buffer = &v.description, .a11y_label = "Description", .placeholder = "What it does" });
    _ = zg_gui.w.text_field.textField(ui, .{ .buffer = &v.cron_text, .a11y_label = "Schedule (cron)", .placeholder = "minute hour day month weekday" });
    // The schedule in words and its next fires, live.
    const cron_s = std.mem.trim(u8, v.cron_text.slice(), " ");
    if (cron_s.len > 0) {
        if (sched.CronExpr.parse(cron_s)) |c| {
            var w: std.Io.Writer.Allocating = .init(ui.arena());
            sched.describe(&c, &w.writer) catch {};
            ui.open(.{ .role = .status, .label = w.written(), .test_id = "automation-describe" });
            ui.text(w.written(), .{ .color = .fg_muted });
            ui.close();
            const svc = v.p.service;
            const tmp: Automation = .{ .name = if (v.creating) v.new_name.slice() else if (v.selected) |i| v.rows[i].name else "", .triggers = &.{.{ .schedule = .{ .cron = cron_s } }}, .action = .{ .agent = .{ .prompt = "" } } };
            var times: [5]i64 = undefined;
            const src = svc.source();
            const n = sched.Scheduler.upcoming(&tmp, svc.runner.zone, svc.key, svc.scheduler.nowMs(), &times);
            const local = sched.tools.localTimes(&src, ui.arena(), times[0..n]) catch &.{};
            const joined = std.mem.join(ui.arena(), ", ", local) catch "";
            ui.textf("Next: {s}", .{joined}, .{ .color = .fg_muted });
        } else |e| ui.textf("Invalid schedule: {t}", .{e}, .{ .color = .danger });
    }
    _ = zg_gui.w.text_field.textField(ui, .{ .buffer = &v.prompt, .a11y_label = "Prompt", .placeholder = "What the agent should do ({{date}}, {{last_run_summary}} …)" });
    ui.open(.{ .role = .group, .label = "Profile", .style = .{ .dir = .row, .gap = 4, .align_items = .center } });
    ui.text("Profile:", .{ .color = .fg_muted });
    for (v.p.profiles, 0..) |p, k| {
        ui.id(@as(u64, k));
        if (controls.button(ui, .{ .label = p, .variant = if (k == v.profile) .primary else .ghost }).clicked) v.profile = k;
    }
    ui.close();
    ui.open(.{ .style = .{ .dir = .row, .gap = 4 } });
    if (controls.button(ui, .{ .label = "Save", .variant = .primary }).clicked) v.save();
    if (controls.button(ui, .{ .label = "Close" }).clicked) {
        v.creating = false;
        v.selected = null;
    }
    ui.close();
    if (v.history.len > 0) {
        ui.text("History", .{ .style = .{ .weight = 700 } });
        const src = v.p.service.source();
        var k: usize = v.history.len;
        while (k > 0) {
            k -= 1;
            const r = v.history[k];
            ui.id(@as(u64, k) + 1000);
            const due = sched.tools.localTimes(&src, ui.arena(), &.{r.due}) catch &.{};
            const when = if (due.len > 0) due[0] else "";
            if (r.skip) |s| {
                ui.textf("{s}  {t}  skipped: {t}", .{ when, r.reason, s }, .{ .color = .fg_muted, .wrap = false });
            } else if (r.run) |id| {
                ui.textf("{s}  {t}  run {f}", .{ when, r.reason, id }, .{ .color = .fg_link, .wrap = false });
            } else ui.textf("{s}  {t}", .{ when, r.reason }, .{ .color = .fg_muted, .wrap = false });
        }
    }
}
