//! `ApprovalsInbox` (E12.F05.S02.T02): the approvals section pinned at the
//! top of the review queue panel. It lists E12's `ApprovalBroker`
//! requests (agents' commands and tool calls, MCP tools) as
//! `ApprovalCard`s, pending first, with answered ones lingering for a
//! moment so the outcome is seen. It is collapsed when there are none.
//!
//! Keys while the section has focus (not while a card's field is open):
//! `y` allow once, `s` allow for the session, `Y` always allow (opens the
//! rule preview), `n` deny (opens the reason), `e` edit and allow, `j`/`k`
//! (or the arrows) next/previous request, `o` open the agent's session.
//!
//! New requests call `on_pending` (the workbench shows the panel). While
//! the window is unfocused they are coalesced for 1.5 s into one toast
//! ("Agent wants to run `npm test`" or "3 approvals needed") with an Open
//! action.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_review = @import("zg_review");
const card = @import("approval_card.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const ap = zg_review.approvals;
const widget = zg_gui.core.widget;
const ev_mod = zg_gui.input.event;

/// Answered cards stay this long.
pub const linger_ms: i64 = 30_000;
/// Requests within this long share one toast.
pub const coalesce_ms: u64 = 1500;
/// The toast's Open action.
pub const open_action = "review.approvals.open";

/// A key the section took, for the next build.
const KeySink = struct { key: ?u21 = null };

/// A focusable container that takes the inbox's single-letter keys.
const KeyScope = struct {
    pub const name = "approvals_keys";
    pub const focusable = true;
    pub const Props = struct { sink: *KeySink, label: []const u8 = "Approvals" };

    pub fn event(ec: *ev_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const ev_mod.InputEvent) bool {
        const k = switch (ev.*) {
            .key => |k| k,
            else => return false,
        };
        if (k.action == .release or k.mods.ctrl or k.mods.alt or k.mods.super) return false;
        const c: u21 = switch (k.key) {
            .arrow_down => 'j',
            .arrow_up => 'k',
            else => k.codepoint,
        };
        switch (c) {
            'y', 's', 'Y', 'n', 'e', 'j', 'k', 'o' => {},
            else => return false,
        }
        props.sink.key = c;
        // Rebuilds the view, which acts on the key.
        ec.respond(.{ .changed = true });
        return true;
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .group, .name = props.label };
    }
};

/// See the module doc.
pub const ApprovalsInbox = struct {
    gpa: Allocator,
    io: Io,
    app: *zg_gui.App,
    broker: *ap.ApprovalBroker,
    /// Card states by request id (UI thread).
    cards: std.AutoHashMapUnmanaged(u64, *card.CardState) = .empty,
    /// The keyboard selection, by request id.
    selected: ?ap.ApprovalId = null,
    keys: KeySink = .{},
    /// The workbench repaints.
    on_change: ?Hook = null,
    /// A new request is waiting (UI thread): show the inbox.
    on_pending: ?Hook = null,
    /// `o` on a card: show that agent session.
    open_session: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, session: []const u8) void } = null,
    /// Where toasts' coalescing timer runs.
    win: ?*Window = null,
    toast_timer: Window.TimerId = .none,
    /// Requests already announced in a toast or seen focused.
    announced: u64 = 0,
    /// Set by the listener on any thread.
    posted: std.atomic.Value(bool) = .init(false),
    fresh: std.atomic.Value(bool) = .init(false),

    pub const Hook = struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void };

    pub fn create(gpa: Allocator, io: Io, app: *zg_gui.App, broker: *ap.ApprovalBroker) !*ApprovalsInbox {
        const inb = try gpa.create(ApprovalsInbox);
        errdefer gpa.destroy(inb);
        inb.* = .{ .gpa = gpa, .io = io, .app = app, .broker = broker };
        try broker.addListener(.{ .ctx = inb, .changed = changed });
        return inb;
    }

    pub fn destroy(inb: *ApprovalsInbox) void {
        inb.broker.removeListener(inb);
        if (inb.win) |w| if (inb.toast_timer != .none) w.cancelTimer(inb.toast_timer);
        var it = inb.cards.valueIterator();
        while (it.next()) |c| {
            c.*.deinit();
            inb.gpa.destroy(c.*);
        }
        inb.cards.deinit(inb.gpa);
        inb.gpa.destroy(inb);
    }

    /// Any thread: a request was added or changed.
    fn changed(ctx: *anyopaque, _: ap.ApprovalId, state: ap.ApprovalState) void {
        const inb: *ApprovalsInbox = @ptrCast(@alignCast(ctx));
        if (state == .pending) inb.fresh.store(true, .release);
        if (!inb.posted.swap(true, .acq_rel)) inb.app.post(.{ .ctx = inb, .f = onUi }) catch inb.posted.store(false, .release);
    }

    fn onUi(ctx: *anyopaque, _: *zg_gui.App) void {
        const inb: *ApprovalsInbox = @ptrCast(@alignCast(ctx));
        inb.posted.store(false, .release);
        if (inb.fresh.swap(false, .acq_rel)) inb.newPending();
        if (inb.on_change) |h| h.f(h.ctx);
    }

    /// UI thread: shows the inbox; while unfocused, arms the toast.
    fn newPending(inb: *ApprovalsInbox) void {
        if (inb.on_pending) |h| h.f(h.ctx);
        const w = inb.win orelse return;
        if (w.chrome.focused) {
            inb.announced = inb.newestPending();
            return;
        }
        if (inb.toast_timer == .none) inb.toast_timer = w.setTimer(w.app.now_ms + coalesce_ms, .{ .ctx = inb, .f = fireToast }) catch .none;
    }

    fn newestPending(inb: *ApprovalsInbox) u64 {
        var arena_state: std.heap.ArenaAllocator = .init(inb.gpa);
        defer arena_state.deinit();
        var top: u64 = inb.announced;
        for (inb.broker.list(arena_state.allocator(), .{ .answered = false }) catch &.{}) |it| top = @max(top, @intFromEnum(it.id));
        return top;
    }

    fn fireToast(ctx: *anyopaque, w: *Window) void {
        const inb: *ApprovalsInbox = @ptrCast(@alignCast(ctx));
        inb.toast_timer = .none;
        var arena_state: std.heap.ArenaAllocator = .init(inb.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const items = inb.broker.list(a, .{ .answered = false }) catch return;
        var fresh: usize = 0;
        var first: ?ap.InboxItem = null;
        for (items) |it| if (@intFromEnum(it.id) > inb.announced) {
            fresh += 1;
            if (first == null) first = it;
        };
        inb.announced = inb.newestPending();
        const it = first orelse return;
        const title = toastTitle(a, fresh, items.len, &it) catch return;
        _ = zg_gui.w.toast(w.app, .{
            .severity = .warning,
            .title = title,
            .source = "Approvals",
            .sticky = true,
            .actions = &.{.{ .label = "Open", .action = open_action, .primary = true }},
        });
    }

    /// The tab badge part: pending requests.
    pub fn pendingCount(inb: *ApprovalsInbox) usize {
        return inb.broker.pendingCount(.{});
    }

    fn stateOf(inb: *ApprovalsInbox, id: ap.ApprovalId) ?*card.CardState {
        const gop = inb.cards.getOrPut(inb.gpa, @intFromEnum(id)) catch return null;
        if (!gop.found_existing) {
            const s = inb.gpa.create(card.CardState) catch {
                inb.cards.removeByPtr(gop.key_ptr);
                return null;
            };
            s.* = .init(inb.gpa);
            gop.value_ptr.* = s;
        }
        return gop.value_ptr.*;
    }

    /// Drops the states of cards no longer shown.
    fn sweep(inb: *ApprovalsInbox, shown: []const ap.InboxItem) void {
        var it = inb.cards.iterator();
        var dead: [32]u64 = undefined;
        var n: usize = 0;
        while (it.next()) |e| {
            const live = for (shown) |s| {
                if (@intFromEnum(s.id) == e.key_ptr.*) break true;
            } else false;
            if (!live and n < dead.len) {
                dead[n] = e.key_ptr.*;
                n += 1;
            }
        }
        for (dead[0..n]) |k| if (inb.cards.fetchRemove(k)) |kv| {
            kv.value.deinit();
            inb.gpa.destroy(kv.value);
        };
    }

    /// The cards shown: pending ones, and answered ones for `linger_ms`.
    fn shownItems(inb: *ApprovalsInbox, arena: Allocator, now_ms: i64) []ap.InboxItem {
        const all = inb.broker.list(arena, .{}) catch return &.{};
        var n: usize = 0;
        for (all) |it| {
            if (it.state != .pending and now_ms - (it.answered_ms orelse it.req.created_ms) > linger_ms) continue;
            all[n] = it;
            n += 1;
        }
        return all[0..n];
    }

    pub fn build(inb: *ApprovalsInbox, ui: *Ui) void {
        const now = nowMs(inb.io);
        const items = inb.shownItems(ui.arena(), now);
        inb.sweep(items);
        if (items.len == 0) {
            inb.selected = null;
            return;
        }
        var pending: usize = 0;
        for (items) |it| pending += @intFromBool(it.state == .pending);
        // The selection stays on a request until it is answered, then
        // moves to the first one still waiting.
        const sel_i = if (inb.selected) |s| indexOf(items, s) else null;
        if (sel_i == null or (items[sel_i.?].state != .pending and items[0].state == .pending)) inb.selected = items[0].id;
        if (inb.keys.key) |k| {
            inb.keys.key = null;
            inb.onKey(k, items);
            ui.window().markAllDirty();
        }

        var lb: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&lb, "Approvals ({d} waiting)", .{pending}) catch "Approvals";
        ui.with(.{ .shrink = 0 });
        _ = ui.begin(KeyScope, .{ .sink = &inb.keys, .label = label });
        defer ui.end(KeyScope);
        ui.open(.{ .style = .{ .dir = .column, .gap = 6, .padding = .xy(8, 4) }, .role = .list, .label = label, .test_id = "approvals-inbox" });
        defer ui.close();
        ui.text(label, .{ .color = if (pending > 0) .warning else .fg_muted, .wrap = false });
        for (items) |*it| {
            const st = inb.stateOf(it.id) orelse continue;
            ui.id(@intFromEnum(it.id));
            ui.open(.{ .style = .{ .dir = .column }, .role = .listitem });
            card.build(ui, inb.broker, it, st, .{
                .view = "inbox",
                .selected = inb.selected != null and inb.selected.? == it.id,
                .now_ms = now,
            });
            ui.close();
        }
    }

    /// A key the section took (see the module doc).
    fn onKey(inb: *ApprovalsInbox, k: u21, items: []const ap.InboxItem) void {
        // A card's field is open: its keys are text.
        var it = inb.cards.valueIterator();
        while (it.next()) |s| if (s.*.mode != .view) return;
        const sel = inb.selected orelse return;
        const i = indexOf(items, sel) orelse return;
        switch (k) {
            'j' => if (i + 1 < items.len) {
                inb.selected = items[i + 1].id;
            },
            'k' => if (i > 0) {
                inb.selected = items[i - 1].id;
            },
            'o' => if (inb.open_session) |o| if (items[i].session()) |s| o.f(o.ctx, s),
            else => {
                if (items[i].state != .pending) return;
                const st = inb.stateOf(sel) orelse return;
                const act: card.Act = switch (k) {
                    'y' => .allow_once,
                    's' => .allow_session,
                    'Y' => .always,
                    'n' => .deny,
                    'e' => .edit,
                    else => return,
                };
                card.run(inb.broker, &items[i], st, act, "inbox");
            },
        }
    }
};

fn indexOf(items: []const ap.InboxItem, id: ap.ApprovalId) ?usize {
    for (items, 0..) |it, i| if (it.id == id) return i;
    return null;
}

/// "Agent s1/main wants to run `npm test`", or "3 approvals needed".
pub fn toastTitle(a: Allocator, fresh: usize, pending: usize, first: *const ap.InboxItem) ![]const u8 {
    if (fresh == 1 and pending == 1) {
        const r = &first.req;
        if (r.command) |c| return std.fmt.allocPrint(a, "{f} wants to run `{s}`", .{ r.actor, c });
        return std.fmt.allocPrint(a, "{f}: {s}", .{ r.actor, r.title });
    }
    return std.fmt.allocPrint(a, "{d} approvals needed", .{pending});
}

fn nowMs(io: Io) i64 {
    const now = Io.Clock.real.now(io);
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms));
}

fn testRequest(session: []const u8, command: ?[]const u8, created_ms: i64) @import("zg_security").contracts.ApprovalRequest {
    return .{
        .kind = if (command != null) .command else .mcp_tool,
        .actor = .{ .agent = .{ .session = session, .agent = "main" } },
        .title = if (command != null) "Run command" else "Call MCP tool github.create_issue",
        .detail_json = if (command != null) "{\"cwd\":\"/ws\",\"terminal\":2}" else "{\"title\":\"x\"}",
        .command = command,
        .risk = if (command != null) &.{"Runs a program on this machine."} else &.{},
        .rule_suggestion = if (command != null) "run_command(cargo test *)" else null,
        .editable = true,
        .created_ms = created_ms,
    };
}

fn key(t: *zg_gui.testing.TestApp, k: @FieldType(ev_mod.KeyPress, "key"), cp: u21, shift: bool) void {
    t.win.dispatch(.{ .key = .{ .key = k, .codepoint = cp, .mods = .{ .shift = shift } } });
    t.win.dispatch(.{ .key = .{ .key = k, .codepoint = cp, .mods = .{ .shift = shift }, .action = .release } });
    _ = t.settle();
}

test "approvals inbox: cards, buttons, keys, edit and always-allow" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var broker: ap.ApprovalBroker = .init(gpa, io, .{});
    defer broker.deinit();

    const Root = struct {
        inb: ?*ApprovalsInbox = null,
        pub fn build(r: *@This(), ui: *Ui) void {
            ui.open(.{ .style = .{ .dir = .column, .grow = 1 } });
            if (r.inb) |x| x.build(ui);
            ui.close();
        }
    };
    var view: Root = .{};
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 480, .h = 700 }, .root = .of(&view) });
    defer t.deinit();
    const inb = try ApprovalsInbox.create(gpa, io, &t.app, &broker);
    defer inb.destroy();
    var pendings: u32 = 0;
    inb.on_pending = .{ .ctx = &pendings, .f = struct {
        fn f(ctx: *anyopaque) void {
            const n: *u32 = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    }.f };
    inb.on_change = .{ .ctx = t.win, .f = struct {
        fn f(ctx: *anyopaque) void {
            const w: *Window = @ptrCast(@alignCast(ctx));
            w.markAllDirty();
        }
    }.f };
    inb.win = t.win;
    view.inb = inb;
    _ = t.settle();
    // Empty: collapsed.
    try testing.expect(t.find(.{ .test_id = "approvals-inbox" }) == null);

    // A command request shows its line, cwd, terminal and risk.
    const a = try broker.present(testRequest("s1", "cargo test --release", 1));
    _ = t.settle();
    try testing.expectEqual(@as(u32, 1), pendings);
    try testing.expect(t.find(.{ .name = "Approvals (1 waiting)" }) != null);
    try testing.expect(t.find(.{ .name = "cargo test --release" }) != null);
    try testing.expect(t.find(.{ .name = "in /ws · terminal 2" }) != null);
    try testing.expect(t.find(.{ .name_contains = "Runs a program" }) != null);
    try testing.expect(t.find(.{ .name = "Approval needed: Run command cargo test --release" }) != null);

    // Allow once by click; the card shows the outcome.
    try t.click(.{ .role = .button, .name = "Allow once" });
    _ = t.settle();
    try testing.expectEqual(ap.ApprovalState.allowed_once, broker.get(a).?.state);
    try testing.expectEqualStrings("inbox", broker.get(a).?.answered_by.?);
    try testing.expect(t.find(.{ .name = "Allowed once by you" }) != null);

    // Keys: `y` on the selected (first pending) card.
    const b = try broker.present(testRequest("s1", "make", 2));
    const c = try broker.present(testRequest("s2", "npm test", 3));
    _ = t.settle();
    t.win.setFocus(t.find(.{ .role = .group, .name = "Approvals (2 waiting)" }).?, false);
    key(t, .key_j, 'j', false); // to c
    key(t, .key_k, 'k', false); // back to b
    key(t, .key_y, 'y', false);
    try testing.expectEqual(ap.ApprovalState.allowed_once, broker.get(b).?.state);
    try testing.expectEqual(ap.ApprovalState.pending, broker.get(c).?.state);

    // Edit and allow: `e` opens the field, typing does not answer.
    t.win.setFocus(t.find(.{ .role = .group, .name = "Approvals (1 waiting)" }).?, false);
    key(t, .key_e, 'e', false);
    const field = t.find(.{ .name = "Edited input" }).?;
    t.win.setFocus(field, false);
    key(t, .key_y, 'y', false);
    try testing.expectEqual(ap.ApprovalState.pending, broker.get(c).?.state);
    inb.stateOf(c).?.field.?.setText("npm test -- --watch=false") catch unreachable;
    try t.click(.{ .role = .button, .name = "Run edited" });
    try testing.expectEqual(ap.ApprovalState.edited_allowed, broker.get(c).?.state);
    try testing.expectEqualStrings("npm test -- --watch=false", broker.get(c).?.answer.?.edit);

    // Always allow: the preview holds E16's rule and warns about an
    // early wildcard; an empty rule is refused.
    const d = try broker.present(testRequest("s1", "cargo test", 4));
    _ = t.settle();
    try t.click(.{ .role = .button, .name = "Always allow…" });
    try testing.expectEqualStrings("run_command(cargo test *)", inb.stateOf(d).?.field.?.slice());
    try testing.expect(t.find(.{ .name_contains = "A wildcard before the end" }) == null);
    inb.stateOf(d).?.field.?.setText("run_command(* test)") catch unreachable;
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = "A wildcard before the end" }) != null);
    inb.stateOf(d).?.field.?.setText("") catch unreachable;
    try t.click(.{ .role = .button, .name = "Save rule and allow" });
    try testing.expect(t.find(.{ .name = "The rule is empty" }) != null);
    inb.stateOf(d).?.field.?.setText("run_command(cargo test *)") catch unreachable;
    try t.click(.{ .role = .button, .name = "Save rule and allow" });
    try testing.expectEqualStrings("run_command(cargo test *)", broker.get(d).?.answer.?.allow_always);

    // A tool call's JSON input must stay JSON when edited.
    const e = try broker.present(testRequest("s1", null, 5));
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = "\"title\": \"x\"" }) != null);
    try t.click(.{ .role = .button, .name = "Edit and allow…" });
    inb.stateOf(e).?.field.?.setText("{not json") catch unreachable;
    try t.click(.{ .role = .button, .name = "Run edited" });
    try testing.expect(t.find(.{ .name = "The input must be valid JSON" }) != null);
    try testing.expectEqual(ap.ApprovalState.pending, broker.get(e).?.state);
    // Denied with a reason.
    try t.click(.{ .role = .button, .name = "Cancel" });
    try t.click(.{ .role = .button, .name = "Deny" });
    inb.stateOf(e).?.field.?.setText("not that repo") catch unreachable;
    try t.click(.{ .role = .button, .name = "Deny" });
    try testing.expectEqualStrings("not that repo", broker.get(e).?.answer.?.deny);

    // A cancelled request leaves the inbox.
    const f = try broker.present(testRequest("s3", "sleep 9", 6));
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = "sleep 9" }) != null);
    broker.cancel(f);
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = "sleep 9" }) == null);
}

test "approvals inbox: requests coalesce into one toast while unfocused" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var broker: ap.ApprovalBroker = .init(gpa, io, .{});
    defer broker.deinit();
    const Root = struct {
        pub fn build(_: *@This(), ui: *Ui) void {
            ui.text("x", .{});
        }
    };
    var view: Root = .{};
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 480, .h = 400 }, .root = .of(&view) });
    defer t.deinit();
    const inb = try ApprovalsInbox.create(gpa, io, &t.app, &broker);
    defer inb.destroy();
    inb.win = t.win;
    t.win.chrome.focused = false;

    _ = try broker.present(testRequest("s1", "npm test", 1));
    _ = t.settle();
    t.advance(500);
    _ = try broker.present(testRequest("s1", "npm run lint", 2));
    _ = try broker.present(testRequest("s2", "make", 3));
    _ = t.settle();
    try testing.expectEqual(@as(usize, 0), t.app.notifications.entries.items.len);
    t.advance(coalesce_ms);
    try testing.expectEqual(@as(usize, 1), t.app.notifications.entries.items.len);
    try testing.expectEqualStrings("3 approvals needed", t.app.notifications.entries.items[0].toast.title);
    try testing.expectEqualStrings(open_action, t.app.notifications.entries.items[0].toast.actions[0].action);

    // One more, alone: named.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    for (try broker.list(arena_state.allocator(), .{})) |it| broker.cancel(it.id);
    _ = try broker.present(testRequest("s1", "cargo build", 4));
    _ = t.settle();
    t.advance(coalesce_ms);
    try testing.expectEqual(@as(usize, 2), t.app.notifications.entries.items.len);
    try testing.expectEqualStrings("agent:s1/main wants to run `cargo build`", t.app.notifications.entries.items[1].toast.title);
}
