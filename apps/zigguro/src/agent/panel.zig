//! `AgentPanel`: one zg_ai agent in the workbench (E10 ↔ E04), the IDE's
//! side of `zg agent`. It shows the transcript (the user's prompts, the
//! streamed replies, tool calls with their outcome, and the permission,
//! hook and validation decisions about them), the agent's status and a
//! prompt field: Enter sends, Shift+Enter breaks the line, Stop cancels
//! the turn. With plan mode wired (`plans`, `plan_mode`), a "Plan mode"
//! switch in the header enters and leaves it, and a proposed plan shows
//! as a card above the prompt (plan_card.zig).
//!
//! The agent publishes on its own tasks: a queued bus subscriber copies
//! each batch into an inbox under a mutex and posts one drain to the UI
//! thread at a time, which applies it to the transcript (UI-thread
//! state). Cancelling runs off the UI thread, since a tool may be waiting
//! on the UI thread (an editor read or edit) when the turn stops.

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_gui = @import("zg_gui");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Agent = zg_ai.loop.Agent;
const ev = zg_ai.loop.events;
const bus = zg_ai.loop.bus;
const PlanCards = @import("plan_card.zig").PlanCards;

/// See the module doc.
pub const AgentPanel = struct {
    gpa: Allocator,
    io: Io,
    app: *zg_gui.App,
    agent: *Agent,
    sub: bus.SubscriptionId,
    /// Guards `inbox`.
    mutex: Io.Mutex = .init,
    inbox: std.ArrayList(Op) = .empty,
    /// A drain is queued on the UI thread.
    posted: std.atomic.Value(bool) = .init(false),
    /// The transcript, oldest first (UI thread).
    items: std.ArrayList(Item) = .empty,
    /// The last item is the reply being streamed.
    streaming: bool = false,
    status: ev.Status = .idle,
    input: zg_gui.w.TextBuffer,
    /// A cancel running off the UI thread.
    stopping: ?Io.Future(void) = null,
    /// `stopping` has finished.
    cancel_flag: std.atomic.Value(bool) = .init(false),
    area: zg_gui.core.NodeId = .none,
    /// The prompt field (focused when the pane opens).
    input_node: zg_gui.core.NodeId = .none,
    /// Scroll to the end after the next frame (new content).
    follow: bool = false,
    /// Plan approvals and the plan mode switch (optional).
    plans: ?*PlanCards = null,
    plan_mode: ?*zg_ai.plan.PlanMode = null,
    /// Called after the transcript changed (the workbench repaints).
    on_change: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void } = null,

    pub const Kind = enum { user, assistant, tool, note, failure };
    pub const ToolState = enum { queued, running, ok, failed, skipped };

    /// One transcript entry.
    pub const Item = struct {
        kind: Kind,
        text: std.ArrayList(u8) = .empty,
        /// Tool calls: the call id and how it went.
        id: []u8 = &.{},
        state: ToolState = .queued,
    };

    /// A transcript change, copied out of an agent event.
    const Op = union(enum) {
        delta: []u8,
        committed,
        tool_queued: struct { id: []u8, text: []u8 },
        tool_started: []u8,
        tool_finished: struct { id: []u8, state: ToolState },
        note: []u8,
        failure: []u8,
        status: ev.Status,

        fn deinit(op: Op, gpa: Allocator) void {
            switch (op) {
                .delta, .tool_started, .note, .failure => |s| gpa.free(s),
                .tool_queued => |t| {
                    gpa.free(t.id);
                    gpa.free(t.text);
                },
                .tool_finished => |t| gpa.free(t.id),
                .committed, .status => {},
            }
        }
    };

    /// A panel on `agent` (which outlives it).
    pub fn create(gpa: Allocator, io: Io, app: *zg_gui.App, agent: *Agent) !*AgentPanel {
        const p = try gpa.create(AgentPanel);
        errdefer gpa.destroy(p);
        p.* = .{ .gpa = gpa, .io = io, .app = app, .agent = agent, .sub = undefined, .input = try .init(gpa, "") };
        errdefer p.input.deinit();
        p.sub = try agent.subscribe(.{ .ctx = p, .on_events = onEvents, .mode = .queued });
        return p;
    }

    /// Stops the agent's work and frees the panel. UI thread.
    pub fn destroy(p: *AgentPanel) void {
        p.agent.unsubscribe(p.sub);
        p.stopAll(.everything);
        // Tools may wait on the UI thread until the turn stops.
        while (p.stopping != null and !p.cancelDone()) {
            _ = p.app.drainMessages();
            p.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        if (p.stopping) |*f| f.await(p.io);
        // A drain posted before the unsubscribe still holds `p`.
        while (p.posted.load(.acquire)) _ = p.app.drainMessages();
        for (p.inbox.items) |op| op.deinit(p.gpa);
        p.inbox.deinit(p.gpa);
        for (p.items.items) |*it| {
            it.text.deinit(p.gpa);
            p.gpa.free(it.id);
        }
        p.items.deinit(p.gpa);
        p.input.deinit();
        p.gpa.destroy(p);
    }

    /// Sends `text` to the agent (queued behind a running turn).
    pub fn submit(p: *AgentPanel, text: []const u8) !void {
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len == 0) return;
        try p.addItem(.user, t);
        p.streaming = false;
        _ = try p.agent.submit(.{ .text = t, .source = .ui });
        p.changed();
    }

    /// Cancels the running turn (queued prompts then run).
    pub fn stop(p: *AgentPanel) void {
        p.stopAll(.turn);
    }

    fn stopAll(p: *AgentPanel, what: Agent.CancelWhat) void {
        if (p.stopping != null) {
            if (!p.cancelDone()) return;
            p.stopping.?.await(p.io);
            p.stopping = null;
        }
        p.cancel_flag.store(false, .release);
        p.stopping = p.io.concurrent(cancelTask, .{ p, what }) catch {
            // No other task can run the cancel: tools cannot be waiting
            // on this thread either.
            p.agent.cancel(what);
            return;
        };
    }

    fn cancelDone(p: *AgentPanel) bool {
        return p.cancel_flag.load(.acquire);
    }

    fn cancelTask(p: *AgentPanel, what: Agent.CancelWhat) void {
        p.agent.cancel(what);
        p.cancel_flag.store(true, .release);
    }

    fn addItem(p: *AgentPanel, kind: Kind, text: []const u8) !void {
        var it: Item = .{ .kind = kind };
        try it.text.appendSlice(p.gpa, text);
        errdefer it.text.deinit(p.gpa);
        try p.items.append(p.gpa, it);
    }

    fn changed(p: *AgentPanel) void {
        p.follow = true;
        if (p.on_change) |h| h.f(h.ctx);
    }

    // ── Agent side ──────────────────────────────────────────────────────

    fn onEvents(ctx: *anyopaque, batch: []const ev.Envelope) void {
        const p: *AgentPanel = @ptrCast(@alignCast(ctx));
        {
            p.mutex.lockUncancelable(p.io);
            defer p.mutex.unlock(p.io);
            for (batch) |e| {
                const op = p.opOf(e.ev) catch continue orelse continue;
                p.inbox.append(p.gpa, op) catch op.deinit(p.gpa);
            }
        }
        if (!p.posted.swap(true, .acq_rel)) p.app.post(.{ .ctx = p, .f = drain }) catch p.posted.store(false, .release);
    }

    /// The transcript change `e` makes, if any (strings copied).
    fn opOf(p: *AgentPanel, e: ev.AgentEvent) Allocator.Error!?Op {
        const a = p.gpa;
        return switch (e) {
            .stream => |s| switch (s) {
                .text_delta => |d| .{ .delta = try a.dupe(u8, d.text) },
                else => null,
            },
            .message_committed => |m| if (m.role == .assistant) .committed else null,
            .tool_queued => |t| blk: {
                const id = try a.dupe(u8, t.id);
                errdefer a.free(id);
                break :blk .{ .tool_queued = .{ .id = id, .text = try toolLine(a, t.name, t.input_json) } };
            },
            .tool_started => |id| .{ .tool_started = try a.dupe(u8, id) },
            .tool_finished => |t| .{ .tool_finished = .{
                .id = try a.dupe(u8, t.id),
                .state = if (t.skipped) .skipped else if (t.is_error) .failed else .ok,
            } },
            .tool_decision => |d| if (decisionLine(a, d)) |s| .{ .note = try s } else null,
            .warning => |w| .{ .note = try a.dupe(u8, w) },
            .error_ => |er| .{ .failure = try std.fmt.allocPrint(a, "{s}: {s}", .{ er.kind, er.message }) },
            .turn_finished => |t| switch (t.reason) {
                .end_turn => null,
                .canceled => .{ .note = try a.dupe(u8, "Stopped.") },
                else => .{ .note = try std.fmt.allocPrint(a, "The turn ended: {t}.", .{t.reason}) },
            },
            .status => |s| .{ .status = s },
            .plan_approved => |pa| .{ .note = try std.fmt.allocPrint(a, "Plan approved ({s}); saved to {s}.", .{ pa.mode, pa.path }) },
            else => null,
        };
    }

    fn drain(ctx: *anyopaque, _: *zg_gui.App) void {
        const p: *AgentPanel = @ptrCast(@alignCast(ctx));
        var ops: std.ArrayList(Op) = .empty;
        defer ops.deinit(p.gpa);
        {
            p.mutex.lockUncancelable(p.io);
            defer p.mutex.unlock(p.io);
            std.mem.swap(std.ArrayList(Op), &ops, &p.inbox);
            p.posted.store(false, .release);
        }
        for (ops.items) |op| {
            p.apply(op) catch {};
            op.deinit(p.gpa);
        }
        if (ops.items.len > 0) p.changed();
    }

    fn apply(p: *AgentPanel, op: Op) !void {
        switch (op) {
            .delta => |s| {
                if (!p.streaming) {
                    try p.addItem(.assistant, "");
                    p.streaming = true;
                }
                try p.items.items[p.items.items.len - 1].text.appendSlice(p.gpa, s);
            },
            .committed => p.streaming = false,
            .tool_queued => |t| {
                p.streaming = false;
                try p.addItem(.tool, t.text);
                const it = &p.items.items[p.items.items.len - 1];
                it.id = try p.gpa.dupe(u8, t.id);
            },
            .tool_started => |id| if (p.toolItem(id)) |it| {
                it.state = .running;
            },
            .tool_finished => |t| if (p.toolItem(t.id)) |it| {
                it.state = t.state;
            },
            .note => |s| {
                p.streaming = false;
                try p.addItem(.note, s);
            },
            .failure => |s| {
                p.streaming = false;
                try p.addItem(.failure, s);
            },
            .status => |s| p.status = s,
        }
    }

    fn toolItem(p: *AgentPanel, id: []const u8) ?*Item {
        var i = p.items.items.len;
        while (i > 0) {
            i -= 1;
            const it = &p.items.items[i];
            if (it.kind == .tool and std.mem.eql(u8, it.id, id)) return it;
        }
        return null;
    }

    // ── View ────────────────────────────────────────────────────────────

    pub fn build(p: *AgentPanel, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .w = .{ .px = 380 }, .h = .{ .pct = 100 }, .shrink = 0, .bg = .{ .token = .bg_elevated } } });
        defer ui.close();

        ui.open(.{ .style = .{ .dir = .row, .gap = 12, .padding = .xy(10, 3), .shrink = 0 } });
        ui.text("AGENT", .{ .color = .fg_muted, .wrap = false });
        ui.text(statusText(p.status), .{ .color = if (p.status == .failed) .danger else .fg_muted, .wrap = false });
        if (p.plan_mode) |pm| {
            ui.open(.{ .style = .{ .grow = 1 } });
            ui.close();
            var on = pm.mode == .plan;
            if (zg_gui.w.toggle(ui, "Plan mode", &on).changed and !busy(p.status)) {
                if (on) pm.enter() else pm.leave(.default);
            }
        }
        ui.close();

        p.area = zg_gui.w.scrollArea(ui, .{ .style = .{ .grow = 1, .basis = .{ .px = 0 }, .dir = .column, .gap = 8, .padding = .all(10) }, .test_id = "agent-transcript" });
        if (p.items.items.len == 0) ui.text("Ask the agent to do something in this workspace.", .{ .color = .fg_muted });
        for (p.items.items, 0..) |*it, i| {
            ui.id(@as(u32, @intCast(i)));
            p.item(ui, it);
        }
        ui.close();
        if (p.follow) {
            p.follow = false;
            ui.win.afterNextFrame(.{ .ctx = p, .f = scrollToEnd });
        }

        if (p.plans) |pc| pc.build(ui);

        ui.open(.{ .style = .{ .dir = .column, .gap = 6, .padding = .all(10), .shrink = 0 } });
        defer ui.close();
        const r = zg_gui.w.textField(ui, .{ .buffer = &p.input, .multiline = true, .max_rows = 6, .placeholder = "Message the agent (Enter sends)", .a11y_label = "Agent prompt" });
        p.input_node = ui.lastNode();
        if (r.submitted) {
            const text = p.gpa.dupe(u8, p.input.slice()) catch return;
            defer p.gpa.free(text);
            p.input.setText("") catch {};
            p.submit(text) catch |e| p.addItem(.failure, @errorName(e)) catch {};
        }
        if (busy(p.status)) {
            if (zg_gui.w.button(ui, .{ .label = "Stop" }).clicked) p.stop();
        }
    }

    fn item(_: *AgentPanel, ui: *Ui, it: *const Item) void {
        switch (it.kind) {
            .user => {
                ui.open(.{ .style = .{ .padding = .xy(8, 6), .bg = .{ .token = .bg_base } } });
                ui.text(it.text.items, .{});
                ui.close();
            },
            .assistant => ui.text(it.text.items, .{}),
            .tool => {
                ui.open(.{ .style = .{ .dir = .row, .gap = 6 } });
                ui.text(switch (it.state) {
                    .queued => "\u{25cb}",
                    .running => "\u{25cf}",
                    .ok => "\u{2713}",
                    .failed => "\u{2717}",
                    .skipped => "\u{2013}",
                }, .{ .color = switch (it.state) {
                    .ok => .success,
                    .failed => .danger,
                    else => .fg_muted,
                }, .wrap = false });
                ui.text(it.text.items, .{ .style = .{ .font = .mono }, .color = .fg_muted });
                ui.close();
            },
            .note => ui.text(it.text.items, .{ .color = .warning }),
            .failure => ui.text(it.text.items, .{ .color = .danger }),
        }
    }

    fn scrollToEnd(ctx: *anyopaque, w: *zg_gui.Window) void {
        const p: *AgentPanel = @ptrCast(@alignCast(ctx));
        if (!p.area.isNone()) _ = w.scrollTo(p.area, .{ .y = std.math.floatMax(f32) });
    }
};

fn busy(s: ev.Status) bool {
    return switch (s) {
        .idle, .done, .failed, .canceled, .waiting_user => false,
        else => true,
    };
}

fn statusText(s: ev.Status) []const u8 {
    return switch (s) {
        .idle, .done => "Ready",
        .thinking => "Thinking…",
        .streaming => "Writing…",
        .running_tools => "Running tools…",
        .awaiting_approval => "Waiting for your approval",
        .waiting_user => "Waiting for you",
        .retrying => "Retrying…",
        .compacting => "Compacting the conversation…",
        .failed => "Failed",
        .canceled => "Stopped",
    };
}

/// "name  input" with the input cut to one short line.
fn toolLine(a: Allocator, name: []const u8, input_json: []const u8) Allocator.Error![]u8 {
    const max = 160;
    const cut = input_json[0..@min(input_json.len, max)];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.print(a, "{s} ", .{name});
    for (cut) |c| try out.append(a, if (c == '\n' or c == '\r' or c == '\t') ' ' else c);
    if (input_json.len > max) try out.appendSlice(a, "…");
    return out.toOwnedSlice(a);
}

/// A note for a decision the user should see: anything but a plain
/// allow, and a hook's allow (it skipped the prompt).
fn decisionLine(a: Allocator, d: zg_ai.loop.deps.ToolDecision) ?Allocator.Error![]u8 {
    if (d.outcome == .allow and d.stage != .pre_hook) return null;
    const who = switch (d.stage) {
        .validation => "Validation",
        .pre_hook, .post_hook => "A hook",
        .permission => "You",
        .bound => "The output limit",
    };
    const what = switch (d.outcome) {
        .allow => "allowed",
        .deny => "denied",
        .ask => "asked about",
        .edit => "edited",
        .replace => "replaced the result of",
        .context => "added context to",
        .truncate => "cut the output of",
    };
    if (d.reason.len > 0) return std.fmt.allocPrint(a, "{s} {s} {s}: {s}", .{ who, what, d.tool, d.reason });
    return std.fmt.allocPrint(a, "{s} {s} {s}.", .{ who, what, d.tool });
}

const testing = std.testing;
const zg_core = @import("zg_core");
const zg_security = @import("zg_security");
const ToolApprovals = @import("approvals.zig").ToolApprovals;
const proto = zg_ai.proto;
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

/// `run`: counts its calls.
const RunTool = struct {
    calls: std.atomic.Value(u32) = .init(0),

    fn spec(t: *RunTool) proto.ToolSpec {
        return .{
            .name = "run",
            .description = "Runs a command.",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}",
            .read_only = false,
            .handler = .{ .ctx = t, .call = call },
            .effects = .{ .executes = true },
            .permission = .execute,
        };
    }

    fn call(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const t: *RunTool = @ptrCast(@alignCast(ctx));
        _ = t.calls.fetchAdd(1, .acq_rel);
        return proto.ToolOutput.text(c.arena, "ran", false) catch error.OutOfMemory;
    }
};

fn find(p: *const AgentPanel, kind: AgentPanel.Kind, needle: []const u8) ?*const AgentPanel.Item {
    for (p.items.items) |*it| if (it.kind == kind and std.mem.indexOf(u8, it.text.items, needle) != null) return it;
    return null;
}

test "agent panel: a prompt, a denied tool call and the reply" {
    const gpa = testing.allocator;
    const io = testing.io;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    rt.bindUiThread(.noop);
    defer _ = rt.deinit();

    var models: zg_ai.ModelRegistry = .init(gpa, io, test_catalog);
    defer models.deinit();
    const sp = try scripted.ScriptedProvider.init(gpa, &.{
        scripted.script.tools(&.{.{ "t1", "run", "{\"command\":\"rm -rf build\"}" }}),
        scripted.script.text("Understood, I left it."),
    }, .all);
    var provider = sp.provider();
    defer provider.deinit();
    var tool: RunTool = .{};
    var specs = [_]proto.ToolSpec{tool.spec()};
    var tools: zg_ai.loop.deps.StaticTools = .{ .specs = &specs };
    var fp: zg_security.testing.FakeApprovalPort = .{ .gpa = gpa };
    defer fp.deinit();
    try fp.answers.append(gpa, .{ .deny = "not on main" });
    var approvals: ToolApprovals = .init(gpa, fp.port());
    defer approvals.deinit();
    const mgr = try zg_ai.loop.AgentManager.init(gpa, io, .{ .registry = &models, .providers = .fixed(&provider), .tools = tools.tools(), .permission = approvals.permission() });
    defer mgr.deinit();
    const agent = try mgr.create(.{ .model = "m" });

    // The panel needs the app, and the window its view.
    const Root = struct {
        p: ?*AgentPanel = null,
        pub fn build(r: *@This(), ui: *Ui) void {
            if (r.p) |x| x.build(ui);
        }
    };
    var root: Root = .{};
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 400, .h = 600 }, .root = .of(&root) });
    defer t.deinit();
    t.app.attachRuntime(&rt);
    const p = try AgentPanel.create(gpa, io, &t.app, agent);
    defer p.destroy();
    root.p = p;
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expect(!p.input_node.isNone());

    // Typed into the prompt; Enter sends it.
    t.win.setFocus(p.input_node, false);
    t.typeText("clean the build");
    t.press(.enter, .{});
    try testing.expectEqualStrings("", p.input.slice());
    var spins: u32 = 0;
    while (find(p, .assistant, "Understood") == null or busy(p.status)) : (spins += 1) {
        try testing.expect(spins < 5000);
        _ = t.settle();
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }

    try testing.expectEqual(AgentPanel.Kind.user, p.items.items[0].kind);
    try testing.expectEqualStrings("clean the build", p.items.items[0].text.items);
    const call = find(p, .tool, "rm -rf build").?;
    try testing.expectEqualStrings("t1", call.id);
    try testing.expect(call.state != .ok);
    // The permission decision, with the reason the user gave.
    _ = find(p, .note, "You denied run: not on main").?;
    try testing.expectEqual(@as(u32, 0), tool.calls.load(.acquire));
    try testing.expectEqualStrings("rm -rf build", fp.presented.items[0].command.?);
    // The transcript is on screen.
    try testing.expect(t.count(.{ .test_id = "agent-transcript" }) == 1);
}
