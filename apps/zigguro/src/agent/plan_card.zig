//! `PlanCards`: the agent panel's plan approval (E10.F09 `exit_plan_mode`
//! ↔ E04, the F11 plan card). It is the `plan_mode.Approver` of the
//! workbench agent: when the agent presents a plan, a card shows it in
//! the panel above the prompt field with these choices:
//!
//! - Approve (leave plan mode in the default mode),
//! - Approve, auto-accept edits,
//! - Approve and clear context (the history is replaced by the plan),
//! - Keep planning, with optional feedback for the model.
//!
//! "Edit plan" turns the plan into a text field; an approval then sends
//! the edited plan, which `PlanMode` saves to `.zigguro/plans/<session>.md`.
//!
//! `ask` runs on the agent's task: it posts the card to the UI thread and
//! waits on an `Io.Event` that a choice sets. A cancelled turn withdraws
//! the card. One card at a time (only the main agent may plan).

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_gui = @import("zg_gui");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const plan_mode = zg_ai.plan.plan_mode;
const TextBuffer = zg_gui.w.TextBuffer;

/// One plan waiting for a choice.
const Card = struct {
    owner: *PlanCards,
    plan: []u8,
    done: Io.Event = .unset,
    /// Set by the UI thread with `edited`/`feedback` (gpa-owned).
    answer: ?plan_mode.PlanDecision = null,
    edited: ?[]u8 = null,
    feedback: ?[]u8 = null,
    /// UI thread: the card is on screen, the plan is being edited.
    shown: bool = false,
    editing: bool = false,
    edit: ?TextBuffer = null,
    note: ?TextBuffer = null,

    /// Frees the card on the UI thread (its fields may be on screen until
    /// the next build, which the repaint brings first).
    fn retire(ctx: *anyopaque, _: *zg_gui.App) void {
        const c: *Card = @ptrCast(@alignCast(ctx));
        const pc = c.owner;
        c.destroy(pc.gpa);
        if (pc.on_change) |h| h.f(h.ctx);
    }

    fn destroy(c: *Card, gpa: Allocator) void {
        gpa.free(c.plan);
        if (c.edited) |s| gpa.free(s);
        if (c.feedback) |s| gpa.free(s);
        if (c.edit) |*b| b.deinit();
        if (c.note) |*b| b.deinit();
        gpa.destroy(c);
    }
};

/// See the module doc.
pub const PlanCards = struct {
    gpa: Allocator,
    io: Io,
    app: *zg_gui.App,
    mutex: Io.Mutex = .init,
    /// The card being asked about (guarded by `mutex`).
    card: ?*Card = null,
    /// Called when the card appears or goes (the workbench repaints).
    on_change: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void } = null,

    pub fn init(gpa: Allocator, io: Io, app: *zg_gui.App) PlanCards {
        return .{ .gpa = gpa, .io = io, .app = app };
    }

    /// Frees a card left behind; nothing may be asking (the agent is
    /// stopped).
    pub fn deinit(pc: *PlanCards) void {
        if (pc.card) |c| c.destroy(pc.gpa);
        pc.card = null;
    }

    /// The approver for `PlanMode`.
    pub fn approver(pc: *PlanCards) plan_mode.Approver {
        return .{ .ctx = pc, .ask = ask };
    }

    /// Whether a plan is waiting for a choice (UI thread).
    pub fn waiting(pc: *PlanCards) bool {
        pc.mutex.lockUncancelable(pc.io);
        defer pc.mutex.unlock(pc.io);
        return pc.card != null;
    }

    fn ask(ctx: *anyopaque, io: Io, arena: Allocator, plan: []const u8) Io.Cancelable!plan_mode.Answer {
        const pc: *PlanCards = @ptrCast(@alignCast(ctx));
        const keep: plan_mode.Answer = .{ .decision = .{ .keep_planning = null } };
        const c = pc.gpa.create(Card) catch return keep;
        c.* = .{ .owner = pc, .plan = pc.gpa.dupe(u8, plan) catch {
            pc.gpa.destroy(c);
            return keep;
        } };
        {
            pc.mutex.lockUncancelable(pc.io);
            defer pc.mutex.unlock(pc.io);
            if (pc.card != null) {
                c.destroy(pc.gpa);
                return .{ .decision = .{ .keep_planning = "Another plan is already waiting for the user." } };
            }
            pc.card = c;
        }
        pc.app.post(.{ .ctx = pc, .f = changedOnUi }) catch {};
        c.done.wait(io) catch |e| {
            // Withdrawn: the UI thread frees the card.
            pc.mutex.lockUncancelable(pc.io);
            if (pc.card == c) pc.card = null;
            pc.mutex.unlock(pc.io);
            pc.app.post(.{ .ctx = c, .f = Card.retire }) catch {};
            return e;
        };
        pc.mutex.lockUncancelable(pc.io);
        defer pc.mutex.unlock(pc.io);
        var out: plan_mode.Answer = .{ .decision = c.answer.? };
        // Copy what the card owns: it is freed on the UI thread.
        switch (out.decision) {
            .keep_planning => |fb| if (fb != null) {
                out.decision = .{ .keep_planning = arena.dupe(u8, c.feedback.?) catch null };
            },
            else => {},
        }
        if (c.edited) |s| out.edited_plan = arena.dupe(u8, s) catch null;
        if (pc.card == c) pc.card = null;
        pc.app.post(.{ .ctx = c, .f = Card.retire }) catch {};
        return out;
    }

    fn changedOnUi(ctx: *anyopaque, _: *zg_gui.App) void {
        const pc: *PlanCards = @ptrCast(@alignCast(ctx));
        if (pc.on_change) |h| h.f(h.ctx);
    }

    /// Records the choice and wakes `ask`. UI thread.
    fn choose(pc: *PlanCards, c: *Card, d: plan_mode.PlanDecision) void {
        pc.mutex.lockUncancelable(pc.io);
        defer pc.mutex.unlock(pc.io);
        if (c.answer != null or pc.card != c) return;
        var decision = d;
        if (c.editing) if (c.edit) |*b| {
            const s = b.slice();
            if (!std.mem.eql(u8, s, c.plan)) c.edited = pc.gpa.dupe(u8, s) catch null;
        };
        if (d == .keep_planning) if (c.note) |*b| {
            const s = std.mem.trim(u8, b.slice(), " \t\r\n");
            if (s.len > 0) c.feedback = pc.gpa.dupe(u8, s) catch null;
            decision = .{ .keep_planning = if (c.feedback) |f| f else null };
        };
        c.answer = decision;
        c.done.set(pc.io);
    }

    /// The card, when a plan is waiting. UI thread.
    pub fn build(pc: *PlanCards, ui: *Ui) void {
        const c = blk: {
            pc.mutex.lockUncancelable(pc.io);
            defer pc.mutex.unlock(pc.io);
            const c = pc.card orelse return;
            if (c.answer != null) return;
            break :blk c;
        };
        if (!c.shown) {
            c.shown = true;
            c.note = TextBuffer.init(pc.gpa, "") catch null;
        }
        const th = ui.theme();
        ui.open(.{ .style = .{ .dir = .column, .gap = th.dim(.space_md), .padding = .all(10), .shrink = 0, .bg = .{ .token = .bg_base }, .border = .{ .token = .accent }, .border_w = 1 }, .role = .group, .label = "Proposed plan", .test_id = "plan-card" });
        defer ui.close();
        ui.text("PROPOSED PLAN", .{ .color = .accent, .wrap = false });
        if (c.editing) {
            if (c.edit) |*b| _ = zg_gui.w.textField(ui, .{ .buffer = b, .multiline = true, .max_rows = 14, .a11y_label = "Plan" });
        } else {
            _ = zg_gui.w.scrollArea(ui, .{ .style = .{ .dir = .column, .max_h = 260 }, .test_id = "plan-text" });
            ui.text(c.plan, .{});
            ui.close();
        }
        if (!c.editing and zg_gui.w.button(ui, .{ .label = "Edit plan", .variant = .ghost }).clicked) {
            c.editing = true;
            if (c.edit == null) c.edit = TextBuffer.init(pc.gpa, c.plan) catch null;
            ui.window().markViewDirty(ui.currentView());
        }

        ui.open(.{ .style = .{ .dir = .row, .wrap = true, .gap = 6 } });
        if (zg_gui.w.button(ui, .{ .label = "Approve", .variant = .primary }).clicked) pc.choose(c, .{ .approve = .default });
        if (zg_gui.w.button(ui, .{ .label = "Approve, auto-accept edits" }).clicked) pc.choose(c, .{ .approve = .accept_edits });
        if (zg_gui.w.button(ui, .{ .label = "Approve and clear context" }).clicked) pc.choose(c, .{ .approve_clear_context = .default });
        ui.close();
        ui.open(.{ .style = .{ .dir = .row, .gap = 6, .align_items = .center } });
        if (c.note) |*b| {
            ui.open(.{ .style = .{ .grow = 1, .basis = .{ .px = 0 } } });
            _ = zg_gui.w.textField(ui, .{ .buffer = b, .placeholder = "What should change?", .a11y_label = "Plan feedback" });
            ui.close();
        }
        if (zg_gui.w.button(ui, .{ .label = "Keep planning" }).clicked) pc.choose(c, .{ .keep_planning = null });
        ui.close();
    }
};

const testing = std.testing;
const zg_core = @import("zg_core");
const AgentPanel = @import("panel.zig").AgentPanel;
const scripted = zg_ai.scripted;

const test_catalog: [:0]const u8 =
    \\.{
    \\    .retrieved = "test",
    \\    .models = .{
    \\        .{ .id = "m", .context_window = 200_000, .max_output = 32_000, .base = .claude,
    \\           .price = .{ .input_per_mtok_micros = 1_000_000, .output_per_mtok_micros = 5_000_000 } },
    \\    },
    \\}
;

const plan_text = "# Rename parse\n1. Rename `parse` to `parseExpr`.\n2. Run the tests.";

/// Borrowed by the provider, so they live for the whole test.
const turns = [_][]const scripted.ScriptedProvider.Step{
    scripted.script.tools(&.{.{ "x1", "exit_plan_mode", "{\"plan\":\"# Rename parse\\n1. Rename `parse` to `parseExpr`.\\n2. Run the tests.\"}" }}),
    scripted.script.text("On it."),
};

/// An agent in plan mode whose first turn presents `plan_text`, a panel
/// with plan cards, and a window showing it.
const Fx = struct {
    rt: zg_core.Runtime,
    models: zg_ai.ModelRegistry,
    sp: *scripted.ScriptedProvider,
    provider: zg_ai.Provider,
    reg: zg_ai.tools.ToolRegistry,
    agent_tools: zg_ai.tools.AgentTools,
    mgr: *zg_ai.loop.AgentManager,
    plans: PlanCards,
    pm: plan_mode.PlanMode,
    tmp: testing.TmpDir,
    ws_buf: [128]u8 = undefined,
    root: Root = .{},
    t: *zg_gui.testing.TestApp,
    p: *AgentPanel,

    const Root = struct {
        p: ?*AgentPanel = null,
        pub fn build(r: *Root, ui: *Ui) void {
            if (r.p) |x| x.build(ui);
        }
    };

    fn init(f: *Fx) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        f.rt.initTesting();
        f.rt.bindUiThread(.noop);
        f.models = .init(gpa, io, test_catalog);
        f.sp = try scripted.ScriptedProvider.init(gpa, &turns, .all);
        f.provider = f.sp.provider();
        f.reg = .init(gpa, io);
        f.agent_tools = .init(gpa, io, &f.reg, .{});
        f.agent_tools.warn_invalidations = false;
        f.mgr = try zg_ai.loop.AgentManager.init(gpa, io, .{ .registry = &f.models, .providers = .fixed(&f.provider), .tools = f.agent_tools.tools() });
        const agent = try f.mgr.create(.{ .model = "m" });
        f.tmp = testing.tmpDir(.{});
        const ws = try std.fmt.bufPrint(&f.ws_buf, ".zig-cache/tmp/{s}", .{&f.tmp.sub_path});
        f.t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 420, .h = 700 }, .root = .of(&f.root) });
        f.t.app.attachRuntime(&f.rt);
        f.plans = .init(gpa, io, &f.t.app);
        f.pm = .init(gpa, agent, ws, f.plans.approver(), .{ .tools = &f.agent_tools });
        try f.reg.addSource(f.pm.source());
        f.p = try AgentPanel.create(gpa, io, &f.t.app, agent);
        f.p.plans = &f.plans;
        f.p.plan_mode = &f.pm;
        f.root.p = f.p;
        f.t.win.markAllDirty();
        _ = f.t.settle();
    }

    fn deinit(f: *Fx) void {
        f.p.destroy();
        f.t.deinit();
        f.mgr.deinit();
        f.pm.deinit();
        f.plans.deinit();
        f.agent_tools.deinit();
        f.reg.deinit();
        f.sp.destroy();
        f.models.deinit();
        f.tmp.cleanup();
        _ = f.rt.deinit();
    }

    /// Frames until `cond` holds (agent tasks run concurrently).
    fn until(f: *Fx, cond: *const fn (f: *Fx) bool) !void {
        var spins: u32 = 0;
        while (!cond(f)) : (spins += 1) {
            try testing.expect(spins < 5000);
            f.t.win.markAllDirty();
            _ = f.t.settle();
            testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        f.t.win.markAllDirty();
        _ = f.t.settle();
    }

    fn cardShown(f: *Fx) bool {
        return f.t.find(.{ .test_id = "plan-card" }) != null;
    }

    fn idle(f: *Fx) bool {
        return !f.plans.waiting() and f.p.status != .thinking and f.p.status != .streaming and f.p.status != .running_tools and
            f.p.status != .awaiting_approval and f.sp.requests().len >= 2 and f.t.find(.{ .test_id = "plan-card" }) == null;
    }

    fn lastResult(f: *Fx) []const u8 {
        const req = f.sp.requests()[1];
        return req.messages[req.messages.len - 1].content[0].tool_result.parts[0].text;
    }
};

test "plan card: the plan shows; approve with auto-accept saves it and leaves plan mode" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    // The header switch enters plan mode.
    try f.t.click(.{ .role = .switch_, .name = "Plan mode" });
    try testing.expectEqual(plan_mode.PermissionMode.plan, f.pm.mode);
    try f.p.submit("Rename parse.");
    try f.until(Fx.cardShown);
    try testing.expect(f.t.find(.{ .role = .text, .name = plan_text }) != null);
    try f.t.click(.{ .role = .button, .name = "Approve, auto-accept edits" });
    try f.until(Fx.idle);

    try testing.expectEqual(plan_mode.PermissionMode.accept_edits, f.pm.mode);
    try testing.expect(std.mem.startsWith(u8, f.lastResult(), "Plan approved; mode is now accept-edits."));
    // The plan file, and the note in the transcript.
    var found = false;
    for (f.p.items.items) |it| if (it.kind == .note and std.mem.indexOf(u8, it.text.items, "Plan approved (accept-edits); saved to") != null) {
        found = true;
    };
    try testing.expect(found);
    var plans_dir = try f.tmp.dir.openDir(testing.io, ".zigguro/plans", .{ .iterate = true });
    defer plans_dir.close(testing.io);
    var it = plans_dir.iterate();
    const e = (try it.next(testing.io)).?;
    var buf: [256]u8 = undefined;
    const saved = try plans_dir.readFile(testing.io, e.name, &buf);
    try testing.expectEqualStrings(plan_text, saved);
}

test "plan card: an edited plan and keep-planning feedback reach the agent" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.pm.enter();
    try f.p.submit("Rename parse.");
    try f.until(Fx.cardShown);
    // Feedback, then Keep planning: the agent stays in plan mode.
    try f.t.click(.{ .role = .textbox, .name = "Plan feedback" });
    f.t.typeText("smaller steps");
    try f.t.click(.{ .role = .button, .name = "Keep planning" });
    try f.until(Fx.idle);
    try testing.expectEqual(plan_mode.PermissionMode.plan, f.pm.mode);
    try testing.expectEqualStrings("The user wants to keep planning. Their feedback:\nsmaller steps", f.lastResult());
}

test "plan card: an edited plan is the one approved" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.pm.enter();
    try f.p.submit("Rename parse.");
    try f.until(Fx.cardShown);
    try f.t.click(.{ .role = .button, .name = "Edit plan" });
    try f.t.click(.{ .role = .textbox, .name = "Plan" });
    f.t.press(.end, .{ .ctrl = true });
    f.t.typeText("\n3. Update the docs.");
    try f.t.click(.{ .role = .button, .name = "Approve" });
    try f.until(Fx.idle);
    try testing.expectEqual(plan_mode.PermissionMode.default, f.pm.mode);
    try testing.expect(std.mem.endsWith(u8, f.lastResult(), "3. Update the docs."));
}
