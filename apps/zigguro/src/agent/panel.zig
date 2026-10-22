//! `AgentPanel`: one zg_ai agent in the workbench (E10 ↔ E04), the IDE's
//! side of `zg agent`. It shows the transcript (the user's prompts, the
//! streamed replies, tool calls with their outcome, and the permission,
//! hook and validation decisions about them), the agent's status and a
//! prompt field: Enter sends, Shift+Enter breaks the line, Stop cancels
//! the turn. With plan mode wired (`plans`, `plan_mode`), a "Plan mode"
//! switch in the header enters and leaves it, and a proposed plan shows
//! as a card above the prompt (plan_card.zig).
//!
//! Subagents: with a `ChildRelay` attached (the host subscribes it to
//! every agent of the manager), a child's replies, tool calls and failures
//! nest under the `task` call that spawned it (`AgentRef.tool_call`),
//! grandchildren under theirs. A task with children has a disclosure
//! button; finished tasks collapse.
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
    inbox: std.ArrayList(Entry) = .empty,
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
    /// Where subagent events come from, while attached.
    relay: ?*ChildRelay = null,
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
        /// A `task` call: its subagent's transcript.
        children: std.ArrayList(Item) = .empty,
        /// The last child is assistant text still streaming.
        child_streaming: bool = false,
        /// Children shown; null follows the state (open while running).
        expanded: ?bool = null,

        fn deinit(it: *Item, gpa: Allocator) void {
            it.text.deinit(gpa);
            gpa.free(it.id);
            for (it.children.items) |*c| c.deinit(gpa);
            it.children.deinit(gpa);
        }

        /// Whether its children show.
        pub fn open(it: *const Item) bool {
            return it.expanded orelse (it.state == .queued or it.state == .running);
        }
    };

    /// An inbox entry: a change to the main transcript, or (`call` set) to
    /// the subagent under that `task` call.
    const Entry = struct {
        op: Op,
        call: ?[]u8 = null,

        fn deinit(e: Entry, gpa: Allocator) void {
            e.op.deinit(gpa);
            if (e.call) |c| gpa.free(c);
        }
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
        if (p.relay) |r| r.attach(null);
        p.stopAll(.everything);
        // Tools may wait on the UI thread until the turn stops.
        while (p.stopping != null and !p.cancelDone()) {
            _ = p.app.drainMessages();
            p.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        if (p.stopping) |*f| f.await(p.io);
        // A drain posted before the unsubscribe still holds `p`.
        while (p.posted.load(.acquire)) _ = p.app.drainMessages();
        for (p.inbox.items) |e| e.deinit(p.gpa);
        p.inbox.deinit(p.gpa);
        for (p.items.items) |*it| it.deinit(p.gpa);
        p.items.deinit(p.gpa);
        p.input.deinit();
        p.gpa.destroy(p);
    }

    /// Shows the subagents of this panel's agent from `r`. UI thread.
    pub fn attachChildren(p: *AgentPanel, r: *ChildRelay) void {
        p.relay = r;
        r.attach(p);
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
        try p.addTo(&p.items, kind, text);
    }

    fn addTo(p: *AgentPanel, list: *std.ArrayList(Item), kind: Kind, text: []const u8) !void {
        var it: Item = .{ .kind = kind };
        try it.text.appendSlice(p.gpa, text);
        errdefer it.text.deinit(p.gpa);
        try list.append(p.gpa, it);
    }

    fn changed(p: *AgentPanel) void {
        p.follow = true;
        if (p.on_change) |h| h.f(h.ctx);
    }

    // ── Agent side ──────────────────────────────────────────────────────

    fn onEvents(ctx: *anyopaque, batch: []const ev.Envelope) void {
        const p: *AgentPanel = @ptrCast(@alignCast(ctx));
        p.queue(batch, null);
    }

    /// A subagent's events, from the relay: kept when the child belongs to
    /// this panel's session.
    fn onChildEvents(p: *AgentPanel, ref: zg_ai.proto.AgentRef, batch: []const ev.Envelope) void {
        const call = ref.tool_call orelse return;
        if (ref.agent == 0 or ref.session != p.agent.ref.session) return;
        p.queue(batch, call);
    }

    fn queue(p: *AgentPanel, batch: []const ev.Envelope, call: ?[]const u8) void {
        {
            p.mutex.lockUncancelable(p.io);
            defer p.mutex.unlock(p.io);
            for (batch) |e| {
                const op = (if (call == null) p.opOf(e.ev) else p.childOpOf(e.ev)) catch continue orelse continue;
                const entry: Entry = .{ .op = op, .call = if (call) |c| p.gpa.dupe(u8, c) catch {
                    op.deinit(p.gpa);
                    continue;
                } else null };
                p.inbox.append(p.gpa, entry) catch entry.deinit(p.gpa);
            }
        }
        if (!p.posted.swap(true, .acq_rel)) p.app.post(.{ .ctx = p, .f = drain }) catch p.posted.store(false, .release);
    }

    /// A subagent's transcript change: its text, tool calls, decisions
    /// and failures, not its status or plan events.
    fn childOpOf(p: *AgentPanel, e: ev.AgentEvent) Allocator.Error!?Op {
        return switch (e) {
            .status, .plan_approved => null,
            else => p.opOf(e),
        };
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
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(p.gpa);
        {
            p.mutex.lockUncancelable(p.io);
            defer p.mutex.unlock(p.io);
            std.mem.swap(std.ArrayList(Entry), &entries, &p.inbox);
            p.posted.store(false, .release);
        }
        for (entries.items) |e| {
            if (e.call) |c| {
                // A child of a call not shown (yet) is dropped.
                if (findTool(p.items.items, c)) |task| p.apply(&task.children, &task.child_streaming, e.op) catch {};
            } else p.apply(&p.items, &p.streaming, e.op) catch {};
            e.deinit(p.gpa);
        }
        if (entries.items.len > 0) p.changed();
    }

    /// Applies `op` to `list` (the main transcript or a subagent's).
    fn apply(p: *AgentPanel, list: *std.ArrayList(Item), streaming: *bool, op: Op) !void {
        switch (op) {
            .delta => |s| {
                if (!streaming.*) {
                    try p.addTo(list, .assistant, "");
                    streaming.* = true;
                }
                try list.items[list.items.len - 1].text.appendSlice(p.gpa, s);
            },
            .committed => streaming.* = false,
            .tool_queued => |t| {
                streaming.* = false;
                try p.addTo(list, .tool, t.text);
                const it = &list.items[list.items.len - 1];
                it.id = try p.gpa.dupe(u8, t.id);
            },
            .tool_started => |id| if (findTool(list.items, id)) |it| {
                it.state = .running;
            },
            .tool_finished => |t| if (findTool(list.items, t.id)) |it| {
                it.state = t.state;
            },
            .note => |s| {
                streaming.* = false;
                try p.addTo(list, .note, s);
            },
            .failure => |s| {
                streaming.* = false;
                try p.addTo(list, .failure, s);
            },
            .status => |s| p.status = s,
        }
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

    fn item(p: *AgentPanel, ui: *Ui, it: *Item) void {
        switch (it.kind) {
            .user => {
                ui.open(.{ .style = .{ .padding = .xy(8, 6), .bg = .{ .token = .bg_base } } });
                ui.text(it.text.items, .{});
                ui.close();
            },
            .assistant => ui.text(it.text.items, .{}),
            .tool => {
                if (it.children.items.len > 0) return p.taskItem(ui, it);
                ui.open(.{ .style = .{ .dir = .row, .gap = 6 } });
                ui.text(stateGlyph(it.state), .{ .color = stateColor(it.state), .wrap = false });
                ui.text(it.text.items, .{ .style = .{ .font = .mono }, .color = .fg_muted });
                ui.close();
            },
            .note => ui.text(it.text.items, .{ .color = .warning }),
            .failure => ui.text(it.text.items, .{ .color = .danger }),
        }
    }

    /// A `task` call with its subagent's transcript: the call line with a
    /// disclosure button, then the children indented.
    fn taskItem(p: *AgentPanel, ui: *Ui, it: *Item) void {
        ui.open(.{ .style = .{ .dir = .column, .gap = 6 } });
        defer ui.close();
        ui.open(.{ .style = .{ .dir = .row, .gap = 6 } });
        const open = it.open();
        var buf: [32]u8 = undefined;
        const n = it.children.items.len;
        const label = std.fmt.bufPrint(&buf, "{s} {d} step{s}", .{ if (open) "\u{25be}" else "\u{25b8}", n, if (n == 1) "" else "s" }) catch "";
        if (zg_gui.w.button(ui, .{ .label = label, .variant = .ghost }).clicked) {
            it.expanded = !open;
            ui.win.markAllDirty();
        }
        ui.text(stateGlyph(it.state), .{ .color = stateColor(it.state), .wrap = false });
        ui.text(it.text.items, .{ .style = .{ .font = .mono }, .color = .fg_muted });
        ui.close();
        if (!open) return;
        ui.open(.{ .style = .{ .dir = .column, .gap = 6, .padding = .{ .l = 18 } }, .test_id = "subagent" });
        defer ui.close();
        for (it.children.items, 0..) |*c, i| {
            ui.id(@as(u32, @intCast(i)));
            p.item(ui, c);
        }
    }

    fn scrollToEnd(ctx: *anyopaque, w: *zg_gui.Window) void {
        const p: *AgentPanel = @ptrCast(@alignCast(ctx));
        if (!p.area.isNone()) _ = w.scrollTo(p.area, .{ .y = std.math.floatMax(f32) });
    }
};

/// The tool call `id` in `items` or any subagent under them (latest first).
fn findTool(items: []AgentPanel.Item, id: []const u8) ?*AgentPanel.Item {
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const it = &items[i];
        if (it.kind != .tool) continue;
        if (std.mem.eql(u8, it.id, id)) return it;
        if (findTool(it.children.items, id)) |c| return c;
    }
    return null;
}

/// Forwards the subagent events of an `AgentManager` (`subscribeAll`, which
/// has no unsubscribe, so the relay lives as long as the manager) to the
/// attached panel.
pub const ChildRelay = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    panel: ?*AgentPanel = null,

    pub fn subscriber(r: *ChildRelay) zg_ai.loop.AgentManager.AllSubscriber {
        return .{ .ctx = r, .on_events = onEvents };
    }

    /// Sets the panel (null detaches); once it returns, the old panel gets
    /// no more events.
    pub fn attach(r: *ChildRelay, p: ?*AgentPanel) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.panel = p;
    }

    fn onEvents(ctx: *anyopaque, ref: zg_ai.proto.AgentRef, batch: []const ev.Envelope) void {
        const r: *ChildRelay = @ptrCast(@alignCast(ctx));
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (r.panel) |p| p.onChildEvents(ref, batch);
    }
};

fn stateGlyph(s: AgentPanel.ToolState) []const u8 {
    return switch (s) {
        .queued => "\u{25cb}",
        .running => "\u{25cf}",
        .ok => "\u{2713}",
        .failed => "\u{2717}",
        .skipped => "\u{2013}",
    };
}

fn stateColor(s: AgentPanel.ToolState) zg_gui.theme.Token {
    return switch (s) {
        .ok => .success,
        .failed => .danger,
        else => .fg_muted,
    };
}

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

/// `read_file` (read-only, so no approval) for the subagent test.
const ReadTool = struct {
    specs: [1]proto.ToolSpec = undefined,

    fn source(t: *ReadTool) zg_ai.tools.ToolSource {
        t.specs = .{.{ .name = "read_file", .description = "Reads.", .input_schema_json = "{\"type\":\"object\"}", .read_only = true, .handler = .{ .ctx = t, .call = call } }};
        return .{ .name = "read", .ctx = t, .list = list, .kind = .builtin };
    }

    fn list(ctx: *anyopaque, gpa: Allocator, out: *std.ArrayList(proto.ToolSpec)) anyerror!void {
        const t: *ReadTool = @ptrCast(@alignCast(ctx));
        try out.appendSlice(gpa, &t.specs);
    }

    fn call(_: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        return proto.ToolOutput.text(c.arena, "fn parse() void {}", false) catch error.OutOfMemory;
    }
};

/// The parent delegates, the child reads a file and answers, the parent
/// wraps up (one provider, played in order: the parent waits on the
/// child). Borrowed by the provider, so they live for the whole test.
const subagent_turns = [_][]const scripted.ScriptedProvider.Step{
    scripted.script.tools(&.{.{ "x1", "task", "{\"agent\":\"general\",\"prompt\":\"find the callers of parse\",\"description\":\"Find callers\"}" }}),
    scripted.script.tools(&.{.{ "c1", "read_file", "{\"path\":\"src/parse.zig\"}" }}),
    scripted.script.text("Found 3 callers."),
    scripted.script.text("Done."),
};

test "agent panel: a subagent's transcript nests under its task call" {
    const gpa = testing.allocator;
    const io = testing.io;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    rt.bindUiThread(.noop);
    defer _ = rt.deinit();

    var models: zg_ai.ModelRegistry = .init(gpa, io, test_catalog);
    defer models.deinit();
    const sp = try scripted.ScriptedProvider.init(gpa, &subagent_turns, .all);
    var provider = sp.provider();
    defer provider.deinit();
    var reg: zg_ai.tools.ToolRegistry = .init(gpa, io);
    defer reg.deinit();
    var read: ReadTool = .{};
    try reg.addSource(read.source());
    var agent_tools: zg_ai.tools.AgentTools = .init(gpa, io, &reg, .{});
    defer agent_tools.deinit();
    const mgr = try zg_ai.loop.AgentManager.init(gpa, io, .{ .registry = &models, .providers = .fixed(&provider), .tools = agent_tools.tools() });
    defer mgr.deinit();
    var defs_arena: std.heap.ArenaAllocator = .init(gpa);
    defer defs_arena.deinit();
    var defs: std.ArrayList(zg_ai.subagent.defs.AgentDef) = .empty;
    try zg_ai.subagent.defs.loadDefs(io, defs_arena.allocator(), &.{}, &defs, null);
    var runner: zg_ai.subagent.SubagentRunner = .init(gpa, io, mgr, &reg, defs.items, .{});
    defer runner.deinit();
    runner.main_tools = &agent_tools;
    var task: zg_ai.subagent.task_tool.TaskTool = try .init(gpa, &runner);
    defer task.deinit();
    try reg.addSource(task.source());
    var relay: ChildRelay = .{ .io = io };
    try mgr.subscribeAll(relay.subscriber());
    const agent = try mgr.create(.{ .model = "m" });

    const Root = struct {
        p: ?*AgentPanel = null,
        pub fn build(r: *@This(), ui: *Ui) void {
            if (r.p) |x| x.build(ui);
        }
    };
    var root: Root = .{};
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 400, .h = 700 }, .root = .of(&root) });
    defer t.deinit();
    t.app.attachRuntime(&rt);
    const p = try AgentPanel.create(gpa, io, &t.app, agent);
    defer p.destroy();
    p.attachChildren(&relay);
    root.p = p;
    t.win.markAllDirty();
    _ = t.settle();

    try p.submit("who calls parse?");
    var spins: u32 = 0;
    while (find(p, .assistant, "Done.") == null or busy(p.status)) : (spins += 1) {
        try testing.expect(spins < 5000);
        _ = t.settle();
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    _ = t.settle();

    // The child's call and answer sit under the task call, not beside it.
    const call = find(p, .tool, "task ").?;
    try testing.expectEqualStrings("x1", call.id);
    try testing.expectEqual(AgentPanel.ToolState.ok, call.state);
    try testing.expectEqual(@as(usize, 2), call.children.items.len);
    try testing.expectEqual(AgentPanel.Kind.tool, call.children.items[0].kind);
    try testing.expectEqualStrings("c1", call.children.items[0].id);
    try testing.expectEqual(AgentPanel.ToolState.ok, call.children.items[0].state);
    try testing.expect(std.mem.startsWith(u8, call.children.items[0].text.items, "read_file "));
    try testing.expectEqualStrings("Found 3 callers.", call.children.items[1].text.items);
    try testing.expect(find(p, .assistant, "Found 3 callers.") == null);
    try testing.expect(find(p, .tool, "read_file") == null);

    // Finished, the task is collapsed; the disclosure button opens it.
    try testing.expect(!call.open());
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expectEqual(@as(usize, 0), t.count(.{ .test_id = "subagent" }));
    try t.click(.{ .role = .button, .name = "\u{25b8} 2 steps" });
    _ = t.settle();
    try testing.expect(call.open());
    try testing.expectEqual(@as(usize, 1), t.count(.{ .test_id = "subagent" }));
}
