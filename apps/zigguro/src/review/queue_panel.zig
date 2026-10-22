//! `QueuePanel`: the workbench's review queue (E12.F03.S01.T01), a dock
//! panel over the agent's `ReviewGlue`. It lists what is pending and what
//! each agent turn changed, grouped by session (or agent, origin, top
//! directory, none), with a filter box (`state:all path:src/** text`).
//! The header switches whether agent edits land at once or are held for
//! review (`ReviewGlue.mode`). A click on a changeset shows its files. An applied changeset can be
//! undone, which reverts its files and puts its changes back for review;
//! an open one can be accepted or rejected.
//!
//! Above the queue, the approvals inbox (`approvals_view.zig`) lists
//! requests waiting for an answer.
//!
//! The rows come from `zg_review.queue_view.QueueModel`, which the
//! glue's queue updates on the agents' tasks under the glue's mutex; the
//! panel reads it, and acts, under the same mutex. Files open in an
//! editor are left alone (the editor holds their text): the action is
//! refused until they are closed.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_review = @import("zg_review");
const ReviewGlue = @import("../agent/review_glue.zig").ReviewGlue;
const ApprovalsInbox = @import("approvals_view.zig").ApprovalsInbox;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const qv = zg_review.queue_view;
const Action = ReviewGlue.Action;

/// See the module doc.
pub const QueuePanel = struct {
    gpa: Allocator,
    io: Io,
    app: *zg_gui.App,
    glue: *ReviewGlue,
    filter: zg_gui.w.TextBuffer,
    /// The filter text did not parse (shown under the box).
    filter_error: ?[]const u8 = null,
    /// Row to expand or collapse after this build.
    toggle_row: ?usize = null,
    /// A button's action, run after this build's rows.
    action: ?struct { cs: zg_review.model.ChangesetId, act: Action } = null,
    /// The last action's outcome, under the filter box.
    status: []const u8 = "",
    status_bad: bool = false,
    status_buf: [192]u8 = undefined,
    /// Opens a changeset in the hunk-by-hunk review view.
    open_review: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, cs: zg_review.model.ChangesetId) void } = null,
    /// A Review button's changeset, opened after the build.
    open_req: ?zg_review.model.ChangesetId = null,
    /// Whether a workspace-relative path is open in an editor.
    is_open: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, rel: []const u8) bool } = null,
    /// The approvals section pinned at the top.
    inbox: ?*ApprovalsInbox = null,
    /// The workbench repaints.
    on_change: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void } = null,
    /// A repaint is queued on the UI thread.
    posted: std.atomic.Value(bool) = .init(false),

    pub fn create(gpa: Allocator, io: Io, app: *zg_gui.App, glue: *ReviewGlue) !*QueuePanel {
        const p = try gpa.create(QueuePanel);
        errdefer gpa.destroy(p);
        p.* = .{ .gpa = gpa, .io = io, .app = app, .glue = glue, .filter = try .init(gpa, "") };
        glue.on_change = .{ .ctx = p, .f = changed };
        return p;
    }

    /// The agent is stopped (nothing calls `changed` any more).
    pub fn destroy(p: *QueuePanel) void {
        p.glue.on_change = null;
        p.filter.deinit();
        p.gpa.destroy(p);
    }

    /// Any thread: the queue changed.
    fn changed(ctx: *anyopaque) void {
        const p: *QueuePanel = @ptrCast(@alignCast(ctx));
        if (!p.posted.swap(true, .acq_rel)) p.app.post(.{ .ctx = p, .f = repaint }) catch p.posted.store(false, .release);
    }

    fn repaint(ctx: *anyopaque, _: *zg_gui.App) void {
        const p: *QueuePanel = @ptrCast(@alignCast(ctx));
        p.posted.store(false, .release);
        if (p.on_change) |h| h.f(h.ctx);
    }

    /// The tab badge: waiting approvals, else open changesets, if any.
    pub fn badge(p: *QueuePanel, buf: []u8) []const u8 {
        if (p.inbox) |i| {
            const a = i.pendingCount();
            if (a > 0) return std.fmt.bufPrint(buf, "\u{2691}{d}", .{a}) catch "";
        }
        p.glue.mutex.lockUncancelable(p.io);
        const n = p.glue.model.counts().pending_changesets;
        p.glue.mutex.unlock(p.io);
        if (n == 0) return "";
        return std.fmt.bufPrint(buf, "{d}", .{n}) catch "";
    }

    pub fn build(p: *QueuePanel, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } } });
        defer ui.close();
        // Outside the glue's lock: answers go to the broker.
        if (p.inbox) |i| i.build(ui);
        p.glue.mutex.lockUncancelable(p.io);
        p.buildLocked(ui);
        p.glue.mutex.unlock(p.io);
        // Outside the lock: the review view takes it too.
        if (p.open_req) |id| {
            p.open_req = null;
            if (p.open_review) |o| o.f(o.ctx, id);
        }
    }

    fn buildLocked(p: *QueuePanel, ui: *Ui) void {
        const m = p.glue.model;
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .role = .group, .label = "Review queue" });
        defer ui.close();
        p.header(ui, m);
        const rows = m.rows();
        if (rows.len == 0) {
            ui.open(.{ .style = .{ .grow = 1, .padding = .all(12) } });
            ui.text(if (p.filter.slice().len > 0) "Nothing matches the filter." else "No changes yet. Each agent turn's edits appear here when the turn ends.", .{ .color = .fg_muted });
            ui.close();
            return;
        }
        const now = nowMs(p.io);
        const Ctx = struct { p: *QueuePanel, rows: []const qv.Row, now: i64 };
        _ = zg_gui.w.virtualList(ui, .{ .count = rows.len, .row_h = 24, .test_id = "review-queue" }, Ctx{ .p = p, .rows = rows, .now = now }, struct {
            fn row(c: Ctx, u: *Ui, i: usize) void {
                c.p.buildRow(u, c.rows[i], i, c.now);
            }
        }.row);
        if (p.toggle_row) |i| {
            p.toggle_row = null;
            m.toggle(i) catch {};
            ui.window().markAllDirty();
        }
        if (p.action) |a| {
            p.action = null;
            p.run(a.cs, a.act);
            ui.window().markAllDirty();
        }
    }

    /// Runs a row's action (locked) and says how it went.
    fn run(p: *QueuePanel, cs: zg_review.model.ChangesetId, act: Action) void {
        const c = p.glue.q.get(cs) orelse return;
        const label = c.prov.label;
        if (p.is_open) |o| for (c.files) |f| if (o.f(o.ctx, f.path)) {
            p.say(true, "Close {s} first: it is open in an editor", .{f.path});
            return;
        };
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const r = p.glue.actLocked(arena_state.allocator(), cs, act) catch |e| {
            p.say(true, "{s}: {t}", .{ label, e });
            return;
        };
        switch (r) {
            .ok => switch (act) {
                .undo => p.say(false, "Undid {s}: its changes wait for review", .{label}),
                .accept => p.say(false, "Applied {s}", .{label}),
                .reject => p.say(false, "Rejected {s}", .{label}),
            },
            .refused => |x| if (x.path.len > 0)
                p.say(true, "Not done: {s} {s}", .{ x.path, x.reason })
            else
                p.say(true, "Not done: {s}", .{x.reason}),
            .failed => |x| p.say(true, "Writing {s} failed: {t}", .{ x.path, x.err }),
        }
    }

    fn say(p: *QueuePanel, bad: bool, comptime fmt: []const u8, args: anytype) void {
        p.status = std.fmt.bufPrint(&p.status_buf, fmt, args) catch p.status_buf[0..p.status_buf.len];
        p.status_bad = bad;
    }

    fn header(p: *QueuePanel, ui: *Ui, m: *qv.QueueModel) void {
        ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .padding = .xy(8, 4), .shrink = 0 } });
        const c = m.counts();
        var buf: [96]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print("{d} pending · {d} hunks", .{ c.pending_changesets, c.pending_hunks }) catch {};
        if (c.conflicts > 0) w.print(" · ⚠ {d}", .{c.conflicts}) catch {};
        ui.open(.{ .style = .{ .grow = 1, .basis = .{ .px = 0 } } });
        ui.text(w.buffered(), .{ .color = if (c.conflicts > 0) .danger else .fg_muted });
        ui.close();
        var gb: [32]u8 = undefined;
        if (zg_gui.w.button(ui, .{ .label = std.fmt.bufPrint(&gb, "Group: {t}", .{m.o.group_by}) catch "Group", .variant = .ghost }).clicked) {
            const next: qv.GroupBy = switch (m.o.group_by) {
                .session => .agent,
                .agent => .origin,
                .origin => .path,
                .path => .none,
                .none => .session,
            };
            m.setGroupBy(next);
            ui.window().markAllDirty();
        }
        ui.close();

        ui.open(.{ .style = .{ .dir = .row, .padding = .xy(8, 0), .shrink = 0 } });
        const label = switch (p.glue.mode) {
            .auto_apply => "Agent edits: applied",
            .review => "Agent edits: held",
            .policy => "Agent edits: by policy",
        };
        if (zg_gui.w.button(ui, .{ .label = label, .variant = .ghost }).clicked) {
            p.glue.mode = switch (p.glue.mode) {
                .auto_apply => .review,
                .review => .policy,
                .policy => .auto_apply,
            };
            p.say(false, "{s}", .{switch (p.glue.mode) {
                .auto_apply => "Agent edits now land at once (each turn can be undone here)",
                .review => "Agent edits now wait here for review",
                .policy => "Agent edits now follow the review rules in .zigguro/settings.zon; the rest wait here",
            }});
            ui.window().markAllDirty();
        }
        ui.close();

        ui.open(.{ .style = .{ .dir = .column, .padding = .xy(8, 2), .shrink = 0 } });
        defer ui.close();
        const r = zg_gui.w.textField(ui, .{ .buffer = &p.filter, .placeholder = "Filter: text, state:all, path:src/**, agent:name, conflicts:yes", .a11y_label = "Filter the review queue" });
        if (r.changed) p.applyFilter(m);
        if (p.filter_error) |e| ui.text(e, .{ .color = .danger, .wrap = false });
        if (p.status.len > 0) ui.text(p.status, .{ .color = if (p.status_bad) .danger else .fg_muted });
    }

    fn applyFilter(p: *QueuePanel, m: *qv.QueueModel) void {
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        p.filter_error = null;
        const f = qv.parseFilter(arena_state.allocator(), p.filter.slice()) catch |e| {
            p.filter_error = switch (e) {
                error.UnknownKey => "Unknown filter key: use state, origin, agent, path or conflicts",
                error.BadValue => "Bad filter value",
                error.OutOfMemory => "Out of memory",
            };
            return;
        };
        m.setFilter(f) catch {
            p.filter_error = "Invalid path pattern";
        };
    }

    fn actionButton(p: *QueuePanel, ui: *Ui, cs: zg_review.model.ChangesetId, act: Action, label: []const u8) void {
        ui.id(@intFromEnum(act));
        if (zg_gui.w.button(ui, .{ .label = label, .variant = .ghost }).clicked) p.action = .{ .cs = cs, .act = act };
    }

    fn buildRow(p: *QueuePanel, ui: *Ui, r: qv.Row, i: usize, now: i64) void {
        ui.open(.{ .style = .{ .w = .{ .px = 8 + 16 * @as(f32, @floatFromInt(r.depth)) }, .shrink = 0 } });
        ui.close();
        var lb: [192]u8 = undefined;
        const label = switch (r.kind) {
            .group => std.fmt.bufPrint(&lb, "{s} {s} ({d})", .{ if (r.expanded) "▾" else "▸", r.label, r.count }),
            .changeset => std.fmt.bufPrint(&lb, "{s} {s}", .{ if (r.expanded) "▾" else "▸", r.label }),
            .file => std.fmt.bufPrint(&lb, "{s}", .{r.label}),
        } catch r.label;
        if (r.kind == .file) {
            ui.text(label, .{ .wrap = false });
        } else if (zg_gui.w.button(ui, .{ .label = label, .variant = .ghost }).clicked) p.toggle_row = i;
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        if (r.kind == .group) return;
        var sb: [96]u8 = undefined;
        var w: std.Io.Writer = .fixed(&sb);
        if (r.kind == .changeset) w.print("{d} file{s}  ", .{ r.files, if (r.files == 1) "" else "s" }) catch {};
        w.print("+{d} −{d}", .{ r.added, r.removed }) catch {};
        if (r.conflicts > 0) w.print("  ⚠ {d}", .{r.conflicts}) catch {};
        if (r.kind == .changeset) {
            var ab: [16]u8 = undefined;
            w.print("  {s}", .{age(&ab, now - r.created_ms)}) catch {};
        }
        ui.text(w.buffered(), .{ .color = if (r.conflicts > 0) .danger else .fg_muted, .wrap = false });
        if (r.kind == .changeset) if (r.cs) |id| if (p.glue.q.get(id)) |c| switch (c.state) {
            .applied => p.actionButton(ui, id, .undo, "Undo"),
            .pending, .partially_applied => {
                if (p.open_review != null) {
                    ui.id(100);
                    if (zg_gui.w.button(ui, .{ .label = "Review", .variant = .ghost }).clicked) p.open_req = id;
                }
                p.actionButton(ui, id, .accept, "Accept");
                p.actionButton(ui, id, .reject, "Reject");
            },
            else => {},
        };
        ui.open(.{ .style = .{ .w = .{ .px = 8 }, .shrink = 0 } });
        ui.close();
    }
};

/// "now", "42s", "5m", "3h" or "2d".
pub fn age(buf: []u8, ms: i64) []const u8 {
    const s = @divFloor(@max(ms, 0), std.time.ms_per_s);
    if (s < 5) return "now";
    const v: i64, const unit: []const u8 = if (s < 60) .{ s, "s" } else if (s < 3600) .{ @divFloor(s, 60), "m" } else if (s < 86400) .{ @divFloor(s, 3600), "h" } else .{ @divFloor(s, 86400), "d" };
    return std.fmt.bufPrint(buf, "{d}{s}", .{ v, unit }) catch "";
}

fn nowMs(io: Io) i64 {
    const now = Io.Clock.real.now(io);
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms));
}

test "queue panel: ages" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("now", age(&buf, 1200));
    try std.testing.expectEqualStrings("42s", age(&buf, 42_000));
    try std.testing.expectEqualStrings("5m", age(&buf, 5 * 60_000 + 10));
    try std.testing.expectEqualStrings("3h", age(&buf, 3 * 3_600_000));
    try std.testing.expectEqualStrings("2d", age(&buf, 2 * 86_400_000));
    try std.testing.expectEqualStrings("now", age(&buf, -5));
}

test "queue panel: a turn's changeset shows, expands and filters" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\ntwo\n" });
    const g = try ReviewGlue.create(gpa, testing.io, root, .{});
    defer g.destroy();

    const Root = struct {
        p: ?*QueuePanel = null,
        pub fn build(r: *@This(), ui: *Ui) void {
            if (r.p) |x| x.build(ui);
        }
    };
    var view: Root = .{};
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 360, .h = 400 }, .root = .of(&view) });
    defer t.deinit();
    const p = try QueuePanel.create(gpa, testing.io, &t.app, g);
    defer p.destroy();
    var repaints: u32 = 0;
    p.on_change = .{ .ctx = &repaints, .f = struct {
        fn f(ctx: *anyopaque) void {
            const n: *u32 = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    }.f };
    view.p = p;
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = "No changes yet" }) != null);

    // One agent turn edits a.txt; its end submits the changeset.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const fs = g.files();
    const s1: @import("zg_ai").proto.AgentRef = .{ .session = 0x51 };
    const abs = (try fs.resolve(testing.io, arena_state.allocator(), "a.txt")).abs;
    _ = try fs.propose(testing.io, arena_state.allocator(), abs, .{ .str_replace = .{ .old = "one", .new = "ONE" } }, .{ .agent = s1, .turn = 1, .tool = "edit_file", .tool_call_id = "t" });
    _ = (try fs.endTurn(testing.io, s1, 1)).?;
    _ = t.settle();
    try testing.expectEqual(@as(u32, 1), repaints);
    t.win.markAllDirty(); // what the workbench's `on_change` does
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = "Recently auto-applied" }) != null);
    try testing.expect(t.find(.{ .name_contains = "a.txt" }) == null);

    // A click shows the changeset's files.
    try t.click(.{ .role = .button, .name_contains = "Turn 1" });
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = "a.txt" }) != null);

    // Undo puts the turn back for review; the file is open, then closed.
    var open_file = true;
    p.is_open = .{ .ctx = &open_file, .f = struct {
        fn f(ctx: *anyopaque, rel: []const u8) bool {
            const o: *bool = @ptrCast(@alignCast(ctx));
            return o.* and std.mem.eql(u8, rel, "a.txt");
        }
    }.f };
    try t.click(.{ .role = .button, .name = "Undo" });
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = "Close a.txt first" }) != null);
    open_file = false;
    try t.click(.{ .role = .button, .name = "Undo" });
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = "Undid Turn 1" }) != null);
    try testing.expectEqualStrings("one\ntwo\n", try tmp.dir.readFileAlloc(testing.io, "a.txt", arena_state.allocator(), .limited(64)));
    // Review opens the changeset (outside the glue's lock).
    var opened: ?zg_review.model.ChangesetId = null;
    p.open_review = .{ .ctx = &opened, .f = struct {
        fn f(ctx: *anyopaque, cs: zg_review.model.ChangesetId) void {
            const o: *?zg_review.model.ChangesetId = @ptrCast(@alignCast(ctx));
            o.* = cs;
        }
    }.f };
    t.win.markAllDirty();
    _ = t.settle();
    try t.click(.{ .role = .button, .name = "Review" });
    _ = t.settle();
    try testing.expect(opened != null);
    try t.click(.{ .role = .button, .name = "Accept" });
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = "Applied Turn 1" }) != null);
    try testing.expectEqualStrings("ONE\ntwo\n", try tmp.dir.readFileAlloc(testing.io, "a.txt", arena_state.allocator(), .limited(64)));

    // The mode switch.
    try t.click(.{ .role = .button, .name = "Agent edits: applied" });
    _ = t.settle();
    try testing.expectEqual(ReviewGlue.Mode.review, g.mode);
    try testing.expect(t.find(.{ .name = "Agent edits: held" }) != null);
    try t.click(.{ .role = .button, .name = "Agent edits: held" });
    _ = t.settle();
    try testing.expectEqual(ReviewGlue.Mode.policy, g.mode);
    try t.click(.{ .role = .button, .name = "Agent edits: by policy" });
    _ = t.settle();
    try testing.expectEqual(ReviewGlue.Mode.auto_apply, g.mode);

    // A filter that matches nothing, then a bad one.
    p.filter.setText("nothing-matches") catch unreachable;
    p.applyFilter(g.model);
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = "Nothing matches" }) != null);
    p.filter.setText("colour:red") catch unreachable;
    p.applyFilter(g.model);
    try testing.expect(p.filter_error != null);
}
