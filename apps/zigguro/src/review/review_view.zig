//! `ReviewView`: a changeset's (or an agent session's) changes, one file
//! at a time, hunk by hunk (E12.F03.S02.T02), over zg_review's
//! `ReviewSession`. Each hunk shows its removed and added lines with
//! Accept and Reject; the header has the file, the progress, file-level
//! actions and Undo.
//!
//! Review comments (zg_review.feedback, on the glue's `comments`): each
//! hunk has a Comment button; its threads follow its lines, with Reply
//! and Resolve, and resolved ones collapse to one line. Threads whose
//! lines are not in a hunk (outdated, or on unchanged lines) are listed
//! first. The composer sits under the header. Unresolved blocking
//! threads warn next to Accept all, which stays allowed.
//!
//! Request fix sends the open threads of the focused file's changeset to
//! the agent (zg_review's `Feedback` on the glue); when its session has
//! ended the view offers to send to the workbench's agent instead. Once
//! the agent revised the changeset (or a new one supersedes it), the
//! Interdiff toggle shows what changed between the two proposals.
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
const feedback = zg_review.feedback;
const TextBuffer = zg_gui.w.TextBuffer;
const diff = @import("zg_editor").model.diff;

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
    /// The comment being written, if any.
    composer: ?Composer = null,
    /// The composer's text; kept until `destroy` (a field built this
    /// frame may still point at it).
    field: ?TextBuffer = null,
    /// Comments are posted under this name.
    author: []const u8 = "you",
    /// Show the interdiff (previous proposal → current) instead of the
    /// diff against the base.
    interdiff: bool = false,
    /// What the last fix request did (static text).
    notice: []const u8 = "",
    /// A fix request waits for the user: the agent's session ended.
    ask_ended: bool = false,

    const Composer = union(enum) {
        /// A new thread on this hunk of the focused file.
        hunk: u32,
        reply: feedback.ThreadId,
    };

    const Action = union(enum) {
        accept_hunk: u32,
        reject_hunk: u32,
        accept_file,
        reject_file,
        accept_all,
        undo,
        next_file,
        prev_file,
        comment_hunk: u32,
        reply: feedback.ThreadId,
        toggle_resolved: feedback.ThreadId,
        post,
        cancel_comment,
        request_fix,
        toggle_interdiff,
        send_current,
        cancel_send,
    };

    const Row = struct {
        kind: enum { hunk, del, add, thread, comment, note },
        hunk: u32 = 0,
        text: []const u8 = "",
        thread: ?*const feedback.Thread = null,
        /// `comment`: its index in the thread.
        comment: u32 = 0,
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
        if (v.field) |*f| f.deinit();
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
        v.composerBar(ui);
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
        if (v.glue.feedback != null and v.openThreads() > 0) v.button(ui, "Request fix", .request_fix);
        if (v.interdiff or v.interdiffSource() != null) v.button(ui, if (v.interdiff) "Full diff" else "Interdiff", .toggle_interdiff);
        ui.close();
        if (v.ask_ended) {
            ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .gap = 6, .padding = .xy(8, 2), .shrink = 0 } });
            ui.text("The agent session that made this change has ended.", .{ .color = .warning, .wrap = false });
            v.button(ui, "Send to the current agent", .send_current);
            v.button(ui, "Cancel", .cancel_send);
            ui.close();
        } else if (v.notice.len > 0) {
            ui.open(.{ .style = .{ .padding = .xy(8, 2), .shrink = 0 } });
            ui.text(v.notice, .{ .color = .fg_muted });
            ui.close();
        }
        const blocking = v.unresolvedBlocking();
        if (blocking > 0) {
            ui.open(.{ .style = .{ .padding = .xy(8, 2), .shrink = 0 } });
            ui.text(std.fmt.bufPrint(&buf, "⚠ {d} blocking comment{s} unresolved", .{ blocking, if (blocking == 1) "" else "s" }) catch "", .{ .color = .warning });
            ui.close();
        }
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
        if (v.interdiff) return v.interdiffRows(fc);
        if (fc.hunks.len == 0) return &.{};
        const tx = try s.texts(a, s.cursor.file) orelse return &.{};
        const old = try splitLines(a, tx.base);
        const new = try splitLines(a, tx.new);
        var out: std.ArrayList(Row) = .empty;
        const threads = v.glue.comments.threadsOf(s.files()[s.cursor.file].cs);
        // Threads not on a hunk come first.
        for (threads) |t| if (std.mem.eql(u8, t.anchor.path, fc.path) and hunkOf(fc.hunks, t) == null) try threadRows(a, &out, t, 0);
        for (fc.hunks, 0..) |h, i| {
            const hi: u32 = @intCast(i);
            try out.append(a, .{ .kind = .hunk, .hunk = hi });
            for (old[@min(h.base_lines.start, old.len)..@min(h.base_lines.start + h.base_lines.count, old.len)]) |l| try out.append(a, .{ .kind = .del, .hunk = hi, .text = l });
            for (new[@min(h.new_lines.start, new.len)..@min(h.new_lines.start + h.new_lines.count, new.len)]) |l| try out.append(a, .{ .kind = .add, .hunk = hi, .text = l });
            for (threads) |t| if (std.mem.eql(u8, t.anchor.path, fc.path) and hunkOf(fc.hunks, t) == hi) try threadRows(a, &out, t, hi);
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
                ui.id(r.hunk * 3);
                v.button(ui, "Accept", .{ .accept_hunk = r.hunk });
                ui.id(r.hunk * 3 + 1);
                v.button(ui, "Reject", .{ .reject_hunk = r.hunk });
                ui.id(r.hunk * 3 + 2);
                v.button(ui, "Comment", .{ .comment_hunk = r.hunk });
            },
            .thread => {
                const t = r.thread.?;
                ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .gap = 4, .padding = .xy(24, 0), .grow = 1 } });
                defer ui.close();
                var buf: [512]u8 = undefined;
                ui.open(.{ .style = .{ .grow = 1, .basis = .{ .px = 0 } } });
                ui.text(threadLine(&buf, t), .{ .color = if (t.resolved) .fg_muted else if (t.blocking) .warning else .fg, .wrap = false });
                ui.close();
                ui.id(@intFromEnum(t.id));
                ui.open(.{ .style = .{ .dir = .row, .gap = 4 } });
                defer ui.close();
                if (!t.resolved) v.button(ui, "Reply", .{ .reply = t.id });
                v.button(ui, if (t.resolved) "Reopen" else "Resolve", .{ .toggle_resolved = t.id });
            },
            .note => {
                ui.open(.{ .style = .{ .dir = .row, .padding = .xy(8, 0), .grow = 1, .bg = .{ .token = .bg_sunken } } });
                defer ui.close();
                ui.text(r.text, .{ .color = .fg_muted, .wrap = false });
            },
            .comment => {
                const c = &r.thread.?.comments.items[r.comment];
                ui.open(.{ .style = .{ .dir = .row, .padding = .xy(40, 0), .grow = 1 } });
                defer ui.close();
                var buf: [512]u8 = undefined;
                ui.text(commentLine(&buf, c), .{ .color = .fg_muted, .wrap = false });
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
            .comment_hunk => |h| blk: {
                v.startComposer(.{ .hunk = h });
                break :blk null;
            },
            .reply => |t| blk: {
                v.startComposer(.{ .reply = t });
                break :blk null;
            },
            .toggle_resolved => |t| blk: {
                const th = v.glue.comments.get(t) orelse break :blk null;
                v.glue.comments.resolve(t, !th.resolved) catch |e| break :blk e;
                break :blk null;
            },
            .post => v.post(),
            .cancel_comment => blk: {
                v.composer = null;
                break :blk null;
            },
            .request_fix => v.requestFix(),
            .toggle_interdiff => blk: {
                v.interdiff = !v.interdiff;
                break :blk null;
            },
            .send_current, .cancel_send => blk: {
                v.ask_ended = false;
                const f = &(v.glue.feedback orelse break :blk null);
                f.finishEnded(if (a == .send_current) .new_session else .cancel, nowMs(v.io)) catch |e| break :blk e;
                v.notice = if (a == .send_current) "Sent to the current agent." else "";
                break :blk null;
            },
        };
        // Failures are in `last_error`; "nothing here" needs no message.
        _ = r catch |e| switch (e) {
            error.NothingHere, error.NothingToUndo => {},
            else => s.last_error = @errorName(e),
        };
    }

    fn startComposer(v: *ReviewView, c: Composer) void {
        v.composer = c;
        if (v.field) |*f| {
            f.setText("") catch {};
        } else v.field = TextBuffer.init(v.gpa, "") catch null;
    }

    fn composerBar(v: *ReviewView, ui: *Ui) void {
        const c = v.composer orelse return;
        const f = if (v.field) |*x| x else return;
        ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .gap = 6, .padding = .xy(8, 4), .shrink = 0, .bg = .{ .token = .bg_sunken } } });
        defer ui.close();
        var buf: [64]u8 = undefined;
        ui.text(switch (c) {
            .hunk => |h| std.fmt.bufPrint(&buf, "Comment on hunk {d}", .{h + 1}) catch "Comment",
            .reply => "Reply",
        }, .{ .wrap = false });
        ui.open(.{ .style = .{ .grow = 1, .basis = .{ .px = 0 } } });
        const r = zg_gui.w.textField(ui, .{ .buffer = f, .a11y_label = "Comment", .placeholder = "issue (blocking): …" });
        ui.close();
        if (r.submitted) v.action = .post;
        if (r.cancelled) v.action = .cancel_comment;
        if (zg_gui.w.button(ui, .{ .label = "Post", .variant = .primary }).clicked) v.action = .post;
        if (zg_gui.w.button(ui, .{ .label = "Cancel", .variant = .ghost }).clicked) v.action = .cancel_comment;
    }

    /// Posts the composer's text (locked).
    fn post(v: *ReviewView) anyerror!?zg_review.session.Failure {
        const c = v.composer orelse return null;
        const body = if (v.field) |*f| f.slice() else return null;
        if (std.mem.trim(u8, body, " \t\r\n").len == 0) return null;
        const g = v.glue;
        const now = nowMs(v.io);
        switch (c) {
            .reply => |t| _ = try g.comments.reply(t, body, .{ .user = v.author }, now),
            .hunk => |hi| {
                const s = v.session;
                const fc = s.fileChange(s.cursor.file) orelse return null;
                if (hi >= fc.hunks.len) return null;
                const h = fc.hunks[hi];
                const a = v.arena.allocator();
                const tx = try s.texts(a, s.cursor.file) orelse return null;
                // Added lines when there are some, else the removed ones.
                const side: feedback.Side = if (h.new_lines.count > 0) .new else .base;
                var at: feedback.CommentAnchor = try .at(a, fc.path, side, if (side == .new) tx.new else tx.base, if (side == .new) h.new_lines else h.base_lines);
                at.hunk_key = h.key;
                const p = feedback.parseLabelPrefix(body);
                _ = try g.comments.create(s.files()[s.cursor.file].cs, at, p.label, p.blocking orelse false, body, .{ .user = v.author }, now);
            },
        }
        v.composer = null;
        return null;
    }

    /// The focused file's changeset.
    fn focusedCs(v: *ReviewView) ?zg_review.model.ChangesetId {
        const fs = v.session.files();
        if (fs.len == 0) return null;
        return fs[v.session.cursor.file].cs;
    }

    /// Unresolved threads on the focused file's changeset.
    fn openThreads(v: *ReviewView) u32 {
        const cs = v.focusedCs() orelse return 0;
        return v.glue.comments.counts(cs).open;
    }

    /// Sends the focused changeset's open threads to its agent (locked).
    fn requestFix(v: *ReviewView) anyerror!?zg_review.session.Failure {
        const f = &(v.glue.feedback orelse return null);
        const cs = v.focusedCs() orelse return null;
        const a = v.arena.allocator();
        var ids: std.ArrayList(feedback.ThreadId) = .empty;
        for (v.glue.comments.threadsOf(cs)) |t| if (!t.resolved) try ids.append(a, t.id);
        v.notice = switch (try f.requestFix(cs, ids.items, "", nowMs(v.io))) {
            .steered => "Sent to the agent: it reads it after its current step.",
            .new_turn => "Sent to the agent as a new turn.",
            .ask_resume => blk: {
                v.ask_ended = true;
                break :blk "";
            },
        };
        return null;
    }

    /// The changesets whose proposals the focused file's interdiff
    /// compares: its own previous revision, or the one it supersedes.
    fn interdiffSource(v: *ReviewView) ?struct { older: zg_review.model.ChangesetId, newer: zg_review.model.ChangesetId } {
        const s = v.session;
        const fc = s.fileChange(s.cursor.file) orelse return null;
        const cs = v.focusedCs() orelse return null;
        if (fc.previous != null) return .{ .older = cs, .newer = cs };
        const c = v.glue.q.get(cs) orelse return null;
        const old = c.supersedes orelse return null;
        const o = v.glue.q.get(old) orelse return null;
        if (o.fileIndex(fc.path) == null) return null;
        return .{ .older = old, .newer = cs };
    }

    /// The interdiff of the focused file as rows: each change between the
    /// two proposals with its removed and added lines.
    fn interdiffRows(v: *ReviewView, fc: *const zg_review.model.FileChange) ![]const Row {
        const a = v.arena.allocator();
        const src = v.interdiffSource() orelse return &.{};
        const f = &(v.glue.feedback orelse return &.{});
        const d = try f.interdiff(src.older, src.newer, fc.path, a) orelse return &.{};
        var la = try diff.LineSource.fromBytes(v.gpa, d.left);
        defer la.deinit(v.gpa);
        var lb = try diff.LineSource.fromBytes(v.gpa, d.right);
        defer lb.deinit(v.gpa);
        var r = try diff.diffLines(v.gpa, &la, &lb, .{ .intraline = .none, .context_lines = 0 });
        defer r.deinit(v.gpa);
        const old = try splitLines(a, d.left);
        const new = try splitLines(a, d.right);
        var out: std.ArrayList(Row) = .empty;
        try out.append(a, .{ .kind = .note, .text = try std.fmt.allocPrint(a, "Interdiff: {s} → {s}", .{ d.left_label, d.right_label }) });
        var n: u32 = 0;
        for (r.hunks) |h| {
            n += 1;
            try out.append(a, .{ .kind = .note, .text = try std.fmt.allocPrint(a, "Change {d}  ·  −{d} +{d}", .{ n, h.old.count, h.new.count }) });
            const os: usize = @intCast(h.old.start);
            const oc: usize = @intCast(h.old.count);
            const ns: usize = @intCast(h.new.start);
            const nc: usize = @intCast(h.new.count);
            for (old[@min(os, old.len)..@min(os + oc, old.len)]) |l| try out.append(a, .{ .kind = .del, .text = l });
            for (new[@min(ns, new.len)..@min(ns + nc, new.len)]) |l| try out.append(a, .{ .kind = .add, .text = l });
        }
        if (n == 0) try out.append(a, .{ .kind = .note, .text = "No changes between the two proposals." });
        return out.items;
    }

    /// Unresolved blocking threads on the changesets under review.
    fn unresolvedBlocking(v: *ReviewView) u32 {
        var n: u32 = 0;
        var last: ?zg_review.model.ChangesetId = null;
        for (v.session.files()) |f| {
            if (last == f.cs) continue;
            last = f.cs;
            n += v.glue.comments.unresolvedBlocking(f.cs);
        }
        return n;
    }
};

/// The hunk a thread sits on: its lines overlap the hunk's on its side.
fn hunkOf(hunks: []const zg_review.model.changeset.Hunk, t: *const feedback.Thread) ?u32 {
    if (t.outdated) return null;
    const l = t.anchor.lines;
    for (hunks, 0..) |h, i| {
        const r = if (t.anchor.side == .new) h.new_lines else h.base_lines;
        const hit = if (l.count == 0 or r.count == 0) l.start >= r.start and l.start <= r.end() else l.start < r.end() and r.start < l.end();
        if (hit) return @intCast(i);
    }
    return null;
}

/// A thread's header row and, unless resolved, a row per comment after
/// the first.
fn threadRows(a: Allocator, out: *std.ArrayList(ReviewView.Row), t: *const feedback.Thread, hunk: u32) !void {
    try out.append(a, .{ .kind = .thread, .hunk = hunk, .thread = t });
    if (t.resolved) return;
    for (1..t.comments.items.len) |i| try out.append(a, .{ .kind = .comment, .hunk = hunk, .thread = t, .comment = @intCast(i) });
}

/// "💬 issue · blocking · dana: first line  ·  2 replies"
fn threadLine(buf: []u8, t: *const feedback.Thread) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const c = t.first();
    w.writeAll("💬 ") catch {};
    if (t.label) |l| w.print("{t} · ", .{l}) catch {};
    if (t.blocking) w.writeAll("blocking · ") catch {};
    if (t.outdated) w.writeAll("outdated · ") catch {};
    if (t.maybe_addressed) w.writeAll("maybe addressed · ") catch {} else if (t.sent_ms != null and !t.resolved) w.writeAll("sent · ") catch {};
    authorName(&w, c.author);
    w.print(": {s}", .{firstLine(feedback.parseLabelPrefix(c.body).rest)}) catch {};
    const replies = t.comments.items.len - 1;
    if (t.resolved) {
        w.writeAll("  ·  Resolved") catch {};
    } else if (replies > 0) w.print("  ·  {d} repl{s}", .{ replies, if (replies == 1) "y" else "ies" }) catch {};
    return w.buffered();
}

fn commentLine(buf: []u8, c: *const feedback.Comment) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    authorName(&w, c.author);
    w.print(": {s}", .{firstLine(c.body)}) catch {};
    return w.buffered();
}

fn authorName(w: *std.Io.Writer, a: feedback.Author) void {
    switch (a) {
        .user => |u| w.writeAll(u) catch {},
        .agent => |g| (if (g.agent == 0) w.writeAll("agent") else w.print("subagent {d}", .{g.agent})) catch {},
        .code_review => |r| w.print("code review {d}", .{r}) catch {},
    }
}

fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    return t[0 .. std.mem.indexOfAny(u8, t, "\r\n") orelse t.len];
}

fn nowMs(io: Io) i64 {
    const now = Io.Clock.real.now(io);
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms));
}

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
    const g = try ReviewGlue.create(gpa, testing.io, root, .{});
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

test "review view: comment threads on hunks, replies, resolve and the blocking warning" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\n.\n.\n.\n.\ntwo\n" });
    const g = try ReviewGlue.create(gpa, testing.io, root, .{});
    defer g.destroy();
    g.mode = .review;
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
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 1000, .h = 500 }, .root = .of(&view) });
    defer t.deinit();
    const v = try ReviewView.create(gpa, testing.io, &t.app, g, .{ .changeset = id });
    defer v.destroy();
    view.v = v;
    t.win.markAllDirty();
    _ = t.settle();

    // A blocking issue on the second hunk.
    {
        const r = t.win.store.absRect(t.findNth(.{ .role = .button, .name = "Comment" }, 1).?);
        const x = r.x + r.w / 2;
        const y = r.y + r.h / 2;
        t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = x, .y = y } } });
        t.win.dispatch(.{ .pointer_down = .{ .pos = .{ .x = x, .y = y } } });
        t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = x, .y = y } } });
        _ = t.settle();
    }
    try testing.expect(t.find(.{ .name = "Comment on hunk 2" }) != null);
    try v.field.?.setText("issue (blocking): keep it lower case");
    try t.click(.{ .role = .button, .name = "Post" });
    _ = t.settle();
    const threads = g.comments.threadsOf(id);
    try testing.expectEqual(@as(usize, 1), threads.len);
    try testing.expectEqual(@as(u32, 5), threads[0].anchor.lines.start);
    try testing.expectEqual(feedback.Label.issue, threads[0].label.?);
    try testing.expect(t.find(.{ .name = "💬 issue · blocking · you: keep it lower case" }) != null);
    try testing.expect(t.find(.{ .name = "⚠ 1 blocking comment unresolved" }) != null);

    // A reply shows under it; resolving collapses it and clears the warning.
    try t.click(.{ .role = .button, .name = "Reply" });
    _ = t.settle();
    try v.field.?.setText("Agreed.");
    try t.click(.{ .role = .button, .name = "Post" });
    _ = t.settle();
    try testing.expect(t.find(.{ .name = "you: Agreed." }) != null);
    try t.click(.{ .role = .button, .name = "Resolve" });
    _ = t.settle();
    try testing.expect(t.find(.{ .name = "you: Agreed." }) == null);
    try testing.expect(t.find(.{ .name_contains = "Resolved" }) != null);
    try testing.expect(t.find(.{ .name_contains = "blocking comment" }) == null);
    try testing.expect(g.comments.get(threads[0].id).?.resolved);
}

test "review view: request fix, the agent's revision and the interdiff" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\n.\n.\n.\n.\ntwo\n" });
    const g = try ReviewGlue.create(gpa, testing.io, root, .{});
    defer g.destroy();
    g.mode = .review;

    const Agent = struct {
        sent: std.ArrayList(u8) = .empty,
        status: feedback.AgentStatus = .idle,
        fn port(x: *@This()) feedback.AgentPort {
            return .{ .ctx = x, .status = st, .submit = sub, .resumeSession = res, .newSession = ns };
        }
        fn st(ctx: *anyopaque, _: u128) feedback.AgentStatus {
            return @as(*@This(), @ptrCast(@alignCast(ctx))).status;
        }
        fn sub(ctx: *anyopaque, _: u128, m: *const feedback.FeedbackMessage, _: feedback.SubmitMode) anyerror!void {
            const x: *@This() = @ptrCast(@alignCast(ctx));
            x.sent.clearRetainingCapacity();
            try x.sent.appendSlice(gpa, m.text);
        }
        fn res(_: *anyopaque, _: u128) anyerror!void {
            return error.Unsupported;
        }
        fn ns(ctx: *anyopaque, m: *const feedback.FeedbackMessage) anyerror!u128 {
            try sub(ctx, 0x51, m, .new_turn);
            return 0x51;
        }
    };
    var agent: Agent = .{};
    defer agent.sent.deinit(gpa);
    try g.bindAgent(agent.port());

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const fs = g.files();
    const s1: @import("zg_ai").proto.AgentRef = .{ .session = 0x51 };
    const abs = (try fs.resolve(testing.io, ar, "a.txt")).abs;
    const o1: @import("zg_ai").tools.builtin.files.Origin = .{ .agent = s1, .turn = 1, .tool = "edit_file", .tool_call_id = "t" };
    _ = try fs.propose(testing.io, ar, abs, .{ .whole_file = .{ .text = "ONE\n.\n.\n.\n.\nTWO\n", .base_version = null } }, o1);
    const id: zg_review.model.ChangesetId = @enumFromInt((try fs.endTurn(testing.io, s1, 1)).?);

    const Root = struct {
        v: ?*ReviewView = null,
        pub fn build(r: *@This(), ui: *Ui) void {
            if (r.v) |x| x.build(ui);
        }
    };
    var view: Root = .{};
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 1200, .h = 600 }, .root = .of(&view) });
    defer t.deinit();
    const v = try ReviewView.create(gpa, testing.io, &t.app, g, .{ .changeset = id });
    defer v.destroy();
    view.v = v;
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expect(t.find(.{ .role = .button, .name = "Request fix" }) == null);

    // Comment, then request a fix: the idle agent gets a new turn.
    try t.click(.{ .role = .button, .name = "Comment" });
    try v.field.?.setText("issue: keep it lower case");
    try t.click(.{ .role = .button, .name = "Post" });
    try t.click(.{ .role = .button, .name = "Request fix" });
    try testing.expect(t.find(.{ .name = "Sent to the agent as a new turn." }) != null);
    try testing.expect(std.mem.indexOf(u8, agent.sent.items, "1. [issue] a.txt:1") != null);
    try testing.expect(t.find(.{ .name_contains = "sent · you: keep it lower case" }) != null);

    // The agent revises its pending change: revision 2, and the interdiff
    // shows only what the revision changed.
    const o2: @import("zg_ai").tools.builtin.files.Origin = .{ .agent = s1, .turn = 2, .tool = "edit_file", .tool_call_id = "t2" };
    _ = try fs.propose(testing.io, ar, abs, .{ .str_replace = .{ .old = "ONE", .new = "one" } }, o2);
    _ = try fs.endTurn(testing.io, s1, 2);
    try testing.expectEqual(@as(u16, 2), g.q.get(id).?.revision);
    t.win.markAllDirty();
    _ = t.settle();
    try t.click(.{ .role = .button, .name = "Interdiff" });
    try testing.expect(t.find(.{ .name = "Interdiff: revision 1 → revision 2" }) != null);
    try testing.expect(t.find(.{ .name = "- ONE" }) != null);
    try testing.expect(t.find(.{ .name = "+ one" }) != null);
    try testing.expect(t.find(.{ .name = "- TWO" }) == null);
    try t.click(.{ .role = .button, .name = "Full diff" });
    try testing.expect(t.find(.{ .name = "+ TWO" }) != null);

    // An ended session: the view offers the current agent.
    agent.status = .ended;
    try t.click(.{ .role = .button, .name = "Request fix" });
    try testing.expect(t.find(.{ .name_contains = "has ended" }) != null);
    try t.click(.{ .role = .button, .name = "Send to the current agent" });
    try testing.expect(t.find(.{ .name = "Sent to the current agent." }) != null);
}
