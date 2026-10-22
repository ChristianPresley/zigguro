//! `PaneApprovals`: the approval cards of one agent session, shown in its
//! agent panel above the prompt (E12 ↔ E10). The requests are the same
//! ones the review queue's approvals inbox lists (E12's `ApprovalBroker`),
//! filtered to the panel's session; answering here answers there too,
//! recorded as answered by "agent-pane". Only pending requests show: the
//! transcript already shows how the tool call went.

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_gui = @import("zg_gui");
const zg_review = @import("zg_review");
const card = @import("../review/approval_card.zig");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const ap = zg_review.approvals;

/// `answered_by` for answers given here.
pub const view_name = "agent-pane";

/// See the module doc.
pub const PaneApprovals = struct {
    gpa: Allocator,
    app: *zg_gui.App,
    broker: *ap.ApprovalBroker,
    /// The agent session's id, as requests carry it.
    session: []u8,
    /// Card states by request id (UI thread).
    cards: std.AutoHashMapUnmanaged(u64, *card.CardState) = .empty,
    /// Where the cards were built last, to rebuild on a change.
    win: ?*Window = null,
    view: u16 = 0,
    /// Set by the listener on any thread.
    posted: std.atomic.Value(bool) = .init(false),

    /// The cards of agent session `session` (a `proto.AgentRef.session`).
    pub fn create(gpa: Allocator, app: *zg_gui.App, broker: *ap.ApprovalBroker, session: zg_ai.proto.SessionId) !*PaneApprovals {
        const pa = try gpa.create(PaneApprovals);
        errdefer gpa.destroy(pa);
        const sid = zg_ai.proto.agent_ref.format(session);
        pa.* = .{ .gpa = gpa, .app = app, .broker = broker, .session = try gpa.dupe(u8, &sid) };
        errdefer gpa.free(pa.session);
        try broker.addListener(.{ .ctx = pa, .changed = changed });
        return pa;
    }

    pub fn destroy(pa: *PaneApprovals) void {
        pa.broker.removeListener(pa);
        var it = pa.cards.valueIterator();
        while (it.next()) |c| {
            c.*.deinit();
            pa.gpa.destroy(c.*);
        }
        pa.cards.deinit(pa.gpa);
        pa.gpa.free(pa.session);
        pa.gpa.destroy(pa);
    }

    /// Any thread: a request was added or changed.
    fn changed(ctx: *anyopaque, _: ap.ApprovalId, _: ap.ApprovalState) void {
        const pa: *PaneApprovals = @ptrCast(@alignCast(ctx));
        if (!pa.posted.swap(true, .acq_rel)) pa.app.post(.{ .ctx = pa, .f = onUi }) catch pa.posted.store(false, .release);
    }

    fn onUi(ctx: *anyopaque, _: *zg_gui.App) void {
        const pa: *PaneApprovals = @ptrCast(@alignCast(ctx));
        pa.posted.store(false, .release);
        const w = pa.win orelse return;
        if (pa.view != 0) w.markViewDirty(pa.view);
    }

    /// Requests of this session waiting for an answer.
    pub fn pendingCount(pa: *PaneApprovals) usize {
        return pa.broker.pendingCount(.{ .session = pa.session });
    }

    fn stateOf(pa: *PaneApprovals, id: ap.ApprovalId) ?*card.CardState {
        const gop = pa.cards.getOrPut(pa.gpa, @intFromEnum(id)) catch return null;
        if (!gop.found_existing) {
            const s = pa.gpa.create(card.CardState) catch {
                pa.cards.removeByPtr(gop.key_ptr);
                return null;
            };
            s.* = .init(pa.gpa);
            gop.value_ptr.* = s;
        }
        return gop.value_ptr.*;
    }

    /// Drops the states of cards no longer shown.
    fn sweep(pa: *PaneApprovals, shown: []const ap.InboxItem) void {
        var dead: [32]u64 = undefined;
        var n: usize = 0;
        var it = pa.cards.iterator();
        while (it.next()) |e| {
            const live = for (shown) |s| {
                if (@intFromEnum(s.id) == e.key_ptr.*) break true;
            } else false;
            if (!live and n < dead.len) {
                dead[n] = e.key_ptr.*;
                n += 1;
            }
        }
        for (dead[0..n]) |k| if (pa.cards.fetchRemove(k)) |kv| {
            kv.value.deinit();
            pa.gpa.destroy(kv.value);
        };
    }

    /// Builds the session's pending cards (nothing when none wait).
    pub fn build(pa: *PaneApprovals, ui: *Ui) void {
        pa.win = ui.window();
        pa.view = ui.currentView();
        const items = pa.broker.list(ui.arena(), .{ .session = pa.session, .answered = false }) catch &.{};
        pa.sweep(items);
        if (items.len == 0) return;
        var lb: [48]u8 = undefined;
        const label = std.fmt.bufPrint(&lb, "Approvals for this agent ({d})", .{items.len}) catch "Approvals for this agent";
        ui.open(.{ .style = .{ .dir = .column, .gap = 6, .padding = .xy(10, 4), .shrink = 0 }, .role = .list, .label = label, .test_id = "agent-approvals" });
        defer ui.close();
        for (items) |*it| {
            const st = pa.stateOf(it.id) orelse continue;
            ui.id(@as(u64, @intFromEnum(it.id)));
            card.build(ui, pa.broker, it, st, .{ .view = view_name });
        }
    }
};

fn testRequest(session: []const u8, command: []const u8) @import("zg_security").contracts.ApprovalRequest {
    return .{
        .kind = .command,
        .actor = .{ .agent = .{ .session = session, .agent = "main" } },
        .title = "Run command",
        .detail_json = "{}",
        .command = command,
        .editable = true,
        .created_ms = 1,
    };
}

test "pane approvals: only this session's pending requests, answered as agent-pane" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var broker: ap.ApprovalBroker = .init(gpa, io, .{});
    defer broker.deinit();

    const Root = struct {
        pa: ?*PaneApprovals = null,
        pub fn build(r: *@This(), ui: *Ui) void {
            ui.open(.{ .style = .{ .dir = .column, .grow = 1 } });
            if (r.pa) |x| x.build(ui);
            ui.close();
        }
    };
    var view: Root = .{};
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 480, .h = 700 }, .root = .of(&view) });
    defer t.deinit();
    const pa = try PaneApprovals.create(gpa, &t.app, &broker, 42);
    defer pa.destroy();
    view.pa = pa;
    _ = t.settle();
    try testing.expect(t.find(.{ .test_id = "agent-approvals" }) == null);

    const other = try broker.present(testRequest("someone-else", "rm -rf build"));
    const mine = try broker.present(testRequest(pa.session, "cargo test"));
    _ = t.settle();
    try testing.expectEqual(@as(usize, 1), pa.pendingCount());
    try testing.expect(t.find(.{ .name = "Approvals for this agent (1)" }) != null);
    try testing.expect(t.find(.{ .name = "cargo test" }) != null);
    try testing.expect(t.find(.{ .name = "rm -rf build" }) == null);

    try t.click(.{ .role = .button, .name = "Allow once" });
    _ = t.settle();
    try testing.expectEqual(ap.ApprovalState.allowed_once, broker.get(mine).?.state);
    try testing.expectEqualStrings(view_name, broker.get(mine).?.answered_by.?);
    try testing.expectEqual(ap.ApprovalState.pending, broker.get(other).?.state);
    // Answered: the cards go away.
    try testing.expect(t.find(.{ .test_id = "agent-approvals" }) == null);
    try testing.expectEqual(@as(u32, 0), pa.cards.count());
}
