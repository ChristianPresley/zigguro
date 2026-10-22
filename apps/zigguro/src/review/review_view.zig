//! `ReviewView`: a changeset's (or an agent session's) changes, one file
//! at a time, hunk by hunk (E12.F03.S02.T02), over zg_review's
//! `ReviewSession`. Each hunk shows its removed and added lines with
//! Accept and Reject; the header has the file, the progress, file-level
//! actions and Undo.
//!
//! A plain line diff for now: E05's diff view (side by side, intraline
//! highlights, edit-before-accept) replaces the body when it exists. The
//! session lives on the glue's queue, so the view reads and acts under
//! the glue's mutex, like the queue panel.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_review = @import("zg_review");
const ReviewGlue = @import("../agent/review_glue.zig").ReviewGlue;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const ReviewSession = zg_review.session.ReviewSession;

/// See the module doc.
pub const ReviewView = struct {
    gpa: Allocator,
    io: Io,
    app: *zg_gui.App,
    glue: *ReviewGlue,
    session: *ReviewSession,
    /// The tab title.
    title_buf: [64]u8 = undefined,
    title: []const u8 = "Review",
    /// A button's action, run after the build.
    action: ?Action = null,
    on_change: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void } = null,
    posted: std.atomic.Value(bool) = .init(false),
    /// This build's rows (reset every build).
    arena: std.heap.ArenaAllocator,

    const Action = union(enum) {
        accept_hunk: u32,
        reject_hunk: u32,
        accept_file,
        reject_file,
        accept_all,
        undo,
        next_file,
        prev_file,
    };

    const Row = struct {
        kind: enum { hunk, del, add },
        hunk: u32,
        text: []const u8 = "",
    };

    /// Reviews `target` on the glue's queue.
    pub fn create(gpa: Allocator, io: Io, app: *zg_gui.App, glue: *ReviewGlue, target: zg_review.session.Target) !*ReviewView {
        const v = try gpa.create(ReviewView);
        errdefer gpa.destroy(v);
        glue.mutex.lockUncancelable(io);
        defer glue.mutex.unlock(io);
        const s = try ReviewSession.init(gpa, glue.q, &glue.applier, target);
        v.* = .{ .gpa = gpa, .io = io, .app = app, .glue = glue, .session = s, .arena = .init(gpa) };
        s.subscribe(.{ .ctx = v, .changed = changed });
        v.setTitle(target);
        return v;
    }

    pub fn destroy(v: *ReviewView) void {
        v.glue.mutex.lockUncancelable(v.io);
        v.session.deinit();
        v.glue.mutex.unlock(v.io);
        v.arena.deinit();
        v.gpa.destroy(v);
    }

    fn setTitle(v: *ReviewView, target: zg_review.session.Target) void {
        v.title = switch (target) {
            .changeset => |id| if (v.glue.q.get(id)) |cs| std.fmt.bufPrint(&v.title_buf, "Review: {s}", .{cs.prov.label}) catch "Review" else "Review",
            .session => "Review: session",
        };
    }

    /// Queue events reach the session on the agents' tasks (under the
    /// glue's mutex): repaint on the UI thread.
    fn changed(ctx: *anyopaque, _: *ReviewSession) void {
        const v: *ReviewView = @ptrCast(@alignCast(ctx));
        if (!v.posted.swap(true, .acq_rel)) v.app.post(.{ .ctx = v, .f = repaint }) catch v.posted.store(false, .release);
    }

    fn repaint(ctx: *anyopaque, _: *zg_gui.App) void {
        const v: *ReviewView = @ptrCast(@alignCast(ctx));
        v.posted.store(false, .release);
        if (v.on_change) |h| h.f(h.ctx);
    }

    pub fn build(v: *ReviewView, ui: *Ui) void {
        v.glue.mutex.lockUncancelable(v.io);
        defer v.glue.mutex.unlock(v.io);
        _ = v.arena.reset(.retain_capacity);
        const s = v.session;
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .role = .group, .label = "Review" });
        defer ui.close();
        v.header(ui);
        const rows = v.fileRows() catch |e| blk: {
            var buf: [96]u8 = undefined;
            ui.text(std.fmt.bufPrint(&buf, "Cannot show this file: {t}", .{e}) catch "Cannot show this file", .{ .color = .danger });
            break :blk &[_]Row{};
        };
        if (s.files().len == 0) {
            ui.open(.{ .style = .{ .grow = 1, .padding = .all(12) } });
            ui.text("Nothing to review.", .{ .color = .fg_muted });
            ui.close();
        } else if (rows.len == 0) {
            ui.open(.{ .style = .{ .grow = 1, .padding = .all(12) } });
            ui.text(if (s.fileChange(s.cursor.file)) |fc| switch (fc.state) {
                .applied => "This file is applied.",
                .rejected => "This file is rejected.",
                else => "No line changes in this file (accept or reject it as a whole).",
            } else "", .{ .color = .fg_muted });
            ui.close();
        } else {
            const Ctx = struct { v: *ReviewView, rows: []const Row };
            _ = zg_gui.w.virtualList(ui, .{ .count = rows.len, .row_h = 20, .test_id = "review-hunks" }, Ctx{ .v = v, .rows = rows }, struct {
                fn row(c: Ctx, u: *Ui, i: usize) void {
                    c.v.buildRow(u, c.rows[i]);
                }
            }.row);
        }
        if (v.action) |a| {
            v.action = null;
            v.run(a);
            ui.window().markAllDirty();
        }
    }

    fn header(v: *ReviewView, ui: *Ui) void {
        const s = v.session;
        ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .padding = .xy(8, 4), .gap = 4, .shrink = 0 } });
        const n = s.files().len;
        var buf: [256]u8 = undefined;
        const fc = s.fileChange(s.cursor.file);
        const pr = s.progress();
        ui.open(.{ .style = .{ .grow = 1, .basis = .{ .px = 0 } } });
        ui.text(std.fmt.bufPrint(&buf, "{s}  ·  file {d} of {d}  ·  {d} of {d} decided", .{
            if (fc) |f| f.path else "",
            if (n == 0) 0 else s.cursor.file + 1,
            n,
            pr.decided,
            pr.total,
        }) catch "", .{ .wrap = false });
        ui.close();
        v.button(ui, "Previous file", .prev_file);
        v.button(ui, "Next file", .next_file);
        v.button(ui, "Accept file", .accept_file);
        v.button(ui, "Reject file", .reject_file);
        v.button(ui, "Accept all", .accept_all);
        v.button(ui, "Undo", .undo);
        ui.close();
        if (s.last_error) |e| {
            ui.open(.{ .style = .{ .padding = .xy(8, 2), .shrink = 0 } });
            ui.text(e, .{ .color = .danger });
            ui.close();
        }
    }

    fn button(v: *ReviewView, ui: *Ui, label: []const u8, a: Action) void {
        if (zg_gui.w.button(ui, .{ .label = label, .variant = .ghost }).clicked) v.action = a;
    }

    /// The focused file's hunks as rows: a header, then its removed and
    /// added lines.
    fn fileRows(v: *ReviewView) ![]const Row {
        const s = v.session;
        const a = v.arena.allocator();
        const fc = s.fileChange(s.cursor.file) orelse return &.{};
        if (fc.hunks.len == 0) return &.{};
        const tx = try s.texts(a, s.cursor.file) orelse return &.{};
        const old = try splitLines(a, tx.base);
        const new = try splitLines(a, tx.new);
        var out: std.ArrayList(Row) = .empty;
        for (fc.hunks, 0..) |h, i| {
            const hi: u32 = @intCast(i);
            try out.append(a, .{ .kind = .hunk, .hunk = hi });
            for (old[@min(h.base_lines.start, old.len)..@min(h.base_lines.start + h.base_lines.count, old.len)]) |l| try out.append(a, .{ .kind = .del, .hunk = hi, .text = l });
            for (new[@min(h.new_lines.start, new.len)..@min(h.new_lines.start + h.new_lines.count, new.len)]) |l| try out.append(a, .{ .kind = .add, .hunk = hi, .text = l });
        }
        return out.items;
    }

    fn buildRow(v: *ReviewView, ui: *Ui, r: Row) void {
        const s = v.session;
        const focused = s.cursor.hunk == r.hunk;
        switch (r.kind) {
            .hunk => {
                const fc = s.fileChange(s.cursor.file).?;
                const h = fc.hunks[r.hunk];
                ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .gap = 4, .padding = .xy(8, 0), .grow = 1, .bg = .{ .token = if (focused) .selection_bg else .bg_sunken } } });
                defer ui.close();
                var buf: [96]u8 = undefined;
                ui.open(.{ .style = .{ .grow = 1, .basis = .{ .px = 0 } } });
                ui.text(std.fmt.bufPrint(&buf, "Hunk {d} of {d}  ·  −{d} +{d}{s}", .{
                    r.hunk + 1,
                    fc.hunks.len,
                    h.base_lines.count,
                    h.new_lines.count,
                    if (h.conflict != null) "  ·  ⚠ conflict" else "",
                }) catch "", .{ .color = if (h.conflict != null) .danger else .fg_muted, .wrap = false });
                ui.close();
                ui.id(r.hunk * 2);
                v.button(ui, "Accept", .{ .accept_hunk = r.hunk });
                ui.id(r.hunk * 2 + 1);
                v.button(ui, "Reject", .{ .reject_hunk = r.hunk });
            },
            .del, .add => {
                ui.open(.{ .style = .{ .dir = .row, .padding = .xy(8, 0), .grow = 1 } });
                defer ui.close();
                var buf: [512]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "{s} {s}", .{ if (r.kind == .del) "-" else "+", r.text }) catch r.text;
                ui.text(line, .{ .style = .{ .font = .mono }, .color = if (r.kind == .del) .danger else .success, .wrap = false });
            },
        }
    }

    /// Runs a button's action (locked).
    fn run(v: *ReviewView, a: Action) void {
        const s = v.session;
        const r: anyerror!?zg_review.session.Failure = switch (a) {
            .accept_hunk => |h| blk: {
                s.focus(.{ .file = s.cursor.file, .hunk = h });
                break :blk s.acceptHunk();
            },
            .reject_hunk => |h| blk: {
                s.focus(.{ .file = s.cursor.file, .hunk = h });
                break :blk s.rejectHunk();
            },
            .accept_file => s.acceptFile(),
            .reject_file => s.rejectFile(),
            .accept_all => s.acceptChangeset(),
            .undo => s.undo(),
            .next_file => blk: {
                s.nextFile();
                break :blk null;
            },
            .prev_file => blk: {
                s.prevFile();
                break :blk null;
            },
        };
        // Failures are in `last_error`; "nothing here" needs no message.
        _ = r catch |e| switch (e) {
            error.NothingHere, error.NothingToUndo => {},
            else => s.last_error = @errorName(e),
        };
    }
};

/// `text`'s lines without their line ends (in `a`).
fn splitLines(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try out.append(a, std.mem.trimEnd(u8, l, "\r"));
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0 and std.mem.endsWith(u8, text, "\n")) _ = out.pop();
    return out.items;
}

test "review view: split lines" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const l = try splitLines(arena.allocator(), "a\r\nb\n\nc");
    try std.testing.expectEqual(@as(usize, 4), l.len);
    try std.testing.expectEqualStrings("a", l[0]);
    try std.testing.expectEqualStrings("", l[2]);
    try std.testing.expectEqual(@as(usize, 2), (try splitLines(arena.allocator(), "x\ny\n")).len);
}

test "review view: accept, reject and undo hunks of a held turn" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\n.\n.\n.\n.\ntwo\n" });
    const g = try ReviewGlue.create(gpa, testing.io, root);
    defer g.destroy();
    g.mode = .review;

    // One held turn with two hunks in a.txt.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const fs = g.files();
    const s1: @import("zg_ai").proto.AgentRef = .{ .session = 0x51 };
    const origin: @import("zg_ai").tools.builtin.files.Origin = .{ .agent = s1, .turn = 1, .tool = "edit_file", .tool_call_id = "t" };
    const abs = (try fs.resolve(testing.io, ar, "a.txt")).abs;
    _ = try fs.propose(testing.io, ar, abs, .{ .whole_file = .{ .text = "ONE\n.\n.\n.\n.\nTWO\n", .base_version = null } }, origin);
    const id: zg_review.model.ChangesetId = @enumFromInt((try fs.endTurn(testing.io, s1, 1)).?);

    const Root = struct {
        v: ?*ReviewView = null,
        pub fn build(r: *@This(), ui: *Ui) void {
            if (r.v) |x| x.build(ui);
        }
    };
    var view: Root = .{};
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 900, .h = 500 }, .root = .of(&view) });
    defer t.deinit();
    const v = try ReviewView.create(gpa, testing.io, &t.app, g, .{ .changeset = id });
    defer v.destroy();
    view.v = v;
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expectEqualStrings("Review: Turn 1", v.title);
    try testing.expect(t.find(.{ .name_contains = "Hunk 1 of 2" }) != null);
    try testing.expect(t.find(.{ .name = "- one" }) != null);
    try testing.expect(t.find(.{ .name = "+ ONE" }) != null);
    try testing.expect(t.find(.{ .name_contains = "0 of 2 decided" }) != null);

    // Accept the first hunk: it lands; the second is now hunk 1 of 1.
    try t.click(.{ .role = .button, .name = "Accept" });
    _ = t.settle();
    const read = struct {
        fn f(d: Io.Dir, a: Allocator) ![]u8 {
            return d.readFileAlloc(testing.io, "a.txt", a, .limited(64));
        }
    }.f;
    try testing.expectEqualStrings("ONE\n.\n.\n.\n.\ntwo\n", try read(tmp.dir, ar));
    try testing.expect(t.find(.{ .name_contains = "Hunk 1 of 1" }) != null);
    try testing.expect(t.find(.{ .name_contains = "1 of 2 decided" }) != null);

    // Reject the second; undo it, then undo the accept.
    try t.click(.{ .role = .button, .name = "Reject" });
    _ = t.settle();
    // Every hunk decided, one landed: applied.
    try testing.expectEqual(zg_review.model.State.applied, g.q.get(id).?.state);
    try t.click(.{ .role = .button, .name = "Undo" });
    _ = t.settle();
    try testing.expectEqual(zg_review.model.State.partially_applied, g.q.get(id).?.state);
    try t.click(.{ .role = .button, .name = "Undo" });
    _ = t.settle();
    try testing.expectEqualStrings("one\n.\n.\n.\n.\ntwo\n", try read(tmp.dir, ar));
    try testing.expect(t.find(.{ .name_contains = "Hunk 1 of 2" }) != null);

    // Accept all.
    try t.click(.{ .role = .button, .name = "Accept all" });
    _ = t.settle();
    try testing.expectEqualStrings("ONE\n.\n.\n.\n.\nTWO\n", try read(tmp.dir, ar));
    try testing.expectEqual(zg_review.model.State.applied, g.q.get(id).?.state);
}
