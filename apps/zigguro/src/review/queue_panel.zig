//! `QueuePanel`: the workbench's review queue (E12.F03.S01.T01), a dock
//! panel over the agent's `ReviewGlue`. It lists what is pending and what
//! each agent turn changed, grouped by session (or agent, origin, top
//! directory, none), with a filter box (`state:all path:src/** text`).
//! A click on a changeset shows its files.
//!
//! The rows come from `zg_review.queue_view.QueueModel`, which the
//! glue's queue updates on the agents' tasks under the glue's mutex; the
//! panel reads it under the same mutex. Accept and reject arrive with
//! the review mode that keeps proposals pending.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_review = @import("zg_review");
const ReviewGlue = @import("../agent/review_glue.zig").ReviewGlue;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const qv = zg_review.queue_view;

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

    /// The tab badge: open changesets, if any.
    pub fn badge(p: *QueuePanel, buf: []u8) []const u8 {
        p.glue.mutex.lockUncancelable(p.io);
        const n = p.glue.model.counts().pending_changesets;
        p.glue.mutex.unlock(p.io);
        if (n == 0) return "";
        return std.fmt.bufPrint(buf, "{d}", .{n}) catch "";
    }

    pub fn build(p: *QueuePanel, ui: *Ui) void {
        p.glue.mutex.lockUncancelable(p.io);
        defer p.glue.mutex.unlock(p.io);
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

        ui.open(.{ .style = .{ .dir = .column, .padding = .xy(8, 2), .shrink = 0 } });
        defer ui.close();
        const r = zg_gui.w.textField(ui, .{ .buffer = &p.filter, .placeholder = "Filter: text, state:all, path:src/**, agent:name, conflicts:yes", .a11y_label = "Filter the review queue" });
        if (r.changed) p.applyFilter(m);
        if (p.filter_error) |e| ui.text(e, .{ .color = .danger, .wrap = false });
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
    const g = try ReviewGlue.create(gpa, testing.io, root);
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
