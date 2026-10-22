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
//! Keys (with the view focused, the composer closed): `j`/`k` (or the
//! arrows) next and previous hunk, `J`/`K` next and previous file, `n`
//! next undecided, `c` next conflict, `a`/`x` accept or reject the hunk,
//! `A`/`X` the file, `m` comment on the hunk, `e` edit it, `r` reply to
//! and `R` resolve (or reopen) its first thread, `f` request fix, `u`
//! undo.
//!
//! Edit-before-accept: Edit (`e`) opens the hunk's proposed lines in a
//! multi-line field under the header; Accept edit (or Ctrl+Enter) accepts
//! the hunk with that text in place of its base lines (decision
//! `edited`, undoable like any accept). Only the hunk's lines are in the
//! field, so the edit cannot reach outside it.
//!
//! Layout: side by side (removed lines on the left, added on the right,
//! paired in order) or inline, toggled in the header. Changed words in a
//! hunk's paired lines are highlighted (E05's intraline diff over the
//! hunk's texts; E12's hunks stay authoritative). Decided hunks show ✓,
//! ✗ or ✎ and dimmed lines; accepted hunks and hunks over
//! `collapse_lines` lines are collapsed behind "Show N lines". The hunk
//! header and the view's key scope carry the focused hunk's description
//! ("Hunk 3 of 12, 4 lines added, 2 removed, pending") for screen readers.
//!
//! Conflicted hunks say why (the user edited the lines, the disk or
//! another change did, or the base is gone) and show the text there now
//! against the agent's, with Take agent (accept), Take mine (reject),
//! Edit merge (edit-before-accept seeded with the agent's lines) and
//! Re-ask agent (both sides sent through `Feedback.requestFix`).
//!
//! Still open (E05's DiffView): editing in place in the diff, the base
//! pane of a 3-way conflict (the text the agent started from), binary
//! previews. The session lives on the glue's queue, so the
//! view reads and acts under the glue's mutex, like the queue panel.

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
const ev_mod = zg_gui.input.event;
const widget = zg_gui.core.widget;

/// The keys `KeyScope` takes (see the module doc).
const view_keys = "jkJKncaxAXmrRfue";

/// Hunks with more lines than this start collapsed.
pub const collapse_lines = 400;

/// A key the view took, for the next build.
const KeySink = struct { key: ?u21 = null };

/// A focusable container that takes the view's single-letter keys.
const KeyScope = struct {
    pub const name = "review_keys";
    pub const focusable = true;
    pub const Props = struct { sink: *KeySink, label: []const u8 = "Review" };

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
        if (c > 0x7f or std.mem.indexOfScalar(u8, view_keys, @intCast(c)) == null) return false;
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
    keys: KeySink = .{},
    layout: Layout = .side_by_side,
    /// Accepted hunks start collapsed.
    collapse_accepted: bool = true,
    /// Hunks (by `Hunk.key`) whose collapsed state the user flipped.
    flipped: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub const Layout = enum { side_by_side, inline_ };

    const Composer = union(enum) {
        /// A new thread on this hunk of the focused file.
        hunk: u32,
        reply: feedback.ThreadId,
        /// Editing this hunk's proposed lines before accepting them.
        edit: u32,
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
        edit_hunk: u32,
        reply: feedback.ThreadId,
        toggle_resolved: feedback.ThreadId,
        post,
        cancel_comment,
        request_fix,
        /// Sends a conflicted hunk's two sides to the agent to redo.
        reask: u32,
        toggle_interdiff,
        toggle_layout,
        toggle_lines: u32,
        send_current,
        cancel_send,
    };

    const Row = struct {
        kind: enum { hunk, del, add, pair, thread, comment, note },
        hunk: u32 = 0,
        /// `del`, `add`: the line; `pair`: the removed line (null: none).
        text: []const u8 = "",
        spans: []const Span = &.{},
        /// `pair`: whether there is a removed line, and the added one.
        old: bool = false,
        new: ?[]const u8 = null,
        new_spans: []const Span = &.{},
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
        v.flipped.deinit(v.gpa);
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
        if (v.keys.key) |k| {
            v.keys.key = null;
            // The composer is open: keys are its text.
            if (v.composer == null) if (v.keyAction(k)) |a| v.run(a);
        }
        _ = ui.begin(KeyScope, .{ .sink = &v.keys, .label = v.scopeLabel() });
        defer ui.end(KeyScope);
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
        v.button(ui, if (v.layout == .side_by_side) "Inline" else "Side by side", .toggle_layout);
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
            if (h.conflict) |c| if (!v.collapsed(h)) try out.append(a, .{
                .kind = .note,
                .hunk = hi,
                .text = try std.fmt.allocPrint(a, "⚠ {s}. {s} your text now, {s} the agent's.", .{
                    conflictReason(c.kind),
                    if (v.layout == .side_by_side) "Left:" else "−",
                    if (v.layout == .side_by_side) "right:" else "+",
                }),
            });
            if (!v.collapsed(h)) {
                const ol = old[@min(h.base_lines.start, old.len)..@min(h.base_lines.start + h.base_lines.count, old.len)];
                const nl = new[@min(h.new_lines.start, new.len)..@min(h.new_lines.start + h.new_lines.count, new.len)];
                try v.lineRows(&out, hi, ol, nl);
            }
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
                ui.open(.{
                    .style = .{ .dir = .row, .align_items = .center, .gap = 4, .padding = .xy(8, 0), .grow = 1, .bg = .{ .token = if (focused) .selection_bg else .bg_sunken } },
                    .role = .group,
                    .label = hunkLabel(v.arena.allocator(), fc, r.hunk) catch "",
                });
                defer ui.close();
                var buf: [128]u8 = undefined;
                ui.open(.{ .style = .{ .grow = 1, .basis = .{ .px = 0 } } });
                ui.text(std.fmt.bufPrint(&buf, "{s}Hunk {d} of {d}  ·  −{d} +{d}{s}", .{
                    switch (h.decision) {
                        .undecided => "",
                        .accepted => "✓ ",
                        .rejected => "✗ ",
                        .edited => "✎ ",
                    },
                    r.hunk + 1,
                    fc.hunks.len,
                    h.base_lines.count,
                    h.new_lines.count,
                    if (h.conflict != null) "  ·  ⚠ conflict" else "",
                }) catch "", .{ .color = if (h.conflict != null) .danger else .fg_muted, .wrap = false });
                ui.close();
                ui.id(r.hunk * 6 + 3);
                if (v.collapsed(h)) {
                    v.button(ui, showLabel(&buf, h.base_lines.count + h.new_lines.count), .{ .toggle_lines = r.hunk });
                } else if (h.decision == .accepted or h.base_lines.count + h.new_lines.count > collapse_lines) {
                    v.button(ui, "Hide lines", .{ .toggle_lines = r.hunk });
                }
                const conflicted = h.conflict != null;
                ui.id(r.hunk * 6);
                v.button(ui, if (conflicted) "Take agent" else "Accept", .{ .accept_hunk = r.hunk });
                ui.id(r.hunk * 6 + 1);
                v.button(ui, if (conflicted) "Take mine" else "Reject", .{ .reject_hunk = r.hunk });
                ui.id(r.hunk * 6 + 4);
                if (conflicted or h.new_lines.count > 0) v.button(ui, if (conflicted) "Edit merge" else "Edit", .{ .edit_hunk = r.hunk });
                ui.id(r.hunk * 6 + 5);
                if (conflicted and v.glue.feedback != null) v.button(ui, "Re-ask agent", .{ .reask = r.hunk });
                ui.id(r.hunk * 6 + 2);
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
                v.lineText(ui, r.kind == .add, r.hunk, r.text, r.spans);
            },
            .pair => {
                ui.open(.{ .style = .{ .dir = .row, .grow = 1 } });
                defer ui.close();
                ui.open(.{ .style = .{ .dir = .row, .padding = .xy(8, 0), .grow = 1, .basis = .{ .px = 0 }, .clip = true } });
                if (r.old) v.lineText(ui, false, r.hunk, r.text, r.spans);
                ui.close();
                ui.open(.{ .style = .{ .dir = .row, .padding = .xy(8, 0), .grow = 1, .basis = .{ .px = 0 }, .clip = true } });
                if (r.new) |n| v.lineText(ui, true, r.hunk, n, r.new_spans);
                ui.close();
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
            .edit_hunk => |h| blk: {
                const text = (s.proposedText(v.arena.allocator(), s.cursor.file, h) catch |e| break :blk e) orelse break :blk null;
                s.focus(.{ .file = s.cursor.file, .hunk = h });
                v.startComposer(.{ .edit = h });
                // The field holds the lines without the last line end.
                if (v.field) |*f| f.setText(if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text) catch |e| break :blk e;
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
            .reask => |h| v.reask(h),
            .toggle_interdiff => blk: {
                v.interdiff = !v.interdiff;
                break :blk null;
            },
            .toggle_layout => blk: {
                v.layout = if (v.layout == .side_by_side) .inline_ else .side_by_side;
                break :blk null;
            },
            .toggle_lines => |h| blk: {
                const fc = s.fileChange(s.cursor.file) orelse break :blk null;
                if (h >= fc.hunks.len) break :blk null;
                const key = fc.hunks[h].key;
                if (v.flipped.remove(key)) break :blk null;
                v.flipped.put(v.gpa, key, {}) catch |e| break :blk e;
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

    /// What key `k` does at the cursor (locked); navigation happens here.
    fn keyAction(v: *ReviewView, k: u21) ?Action {
        const s = v.session;
        const h = s.cursor.hunk;
        switch (k) {
            'j' => s.next(),
            'k' => s.prev(),
            'J' => s.nextFile(),
            'K' => s.prevFile(),
            'n' => _ = s.nextUndecided(),
            'c' => _ = s.nextConflict(),
            'a' => return if (h) |x| .{ .accept_hunk = x } else null,
            'x' => return if (h) |x| .{ .reject_hunk = x } else null,
            'A' => return .accept_file,
            'X' => return .reject_file,
            'm' => return if (h) |x| .{ .comment_hunk = x } else null,
            'e' => return if (h) |x| .{ .edit_hunk = x } else null,
            'r' => return if (v.cursorThread(true)) |t| .{ .reply = t } else null,
            'R' => return if (v.cursorThread(false)) |t| .{ .toggle_resolved = t } else null,
            'f' => return if (v.glue.feedback != null and v.openThreads() > 0) .request_fix else null,
            'u' => return .undo,
            else => {},
        }
        return null;
    }

    /// The first thread on the hunk under the cursor, unresolved ones
    /// first (only those when `open_only`).
    fn cursorThread(v: *ReviewView, open_only: bool) ?feedback.ThreadId {
        const s = v.session;
        const fc = s.fileChange(s.cursor.file) orelse return null;
        const at = s.cursor.hunk orelse return null;
        var resolved: ?feedback.ThreadId = null;
        for (v.glue.comments.threadsOf(s.files()[s.cursor.file].cs)) |t| {
            if (!std.mem.eql(u8, t.anchor.path, fc.path) or hunkOf(fc.hunks, t) != at) continue;
            if (!t.resolved) return t.id;
            if (resolved == null) resolved = t.id;
        }
        return if (open_only) null else resolved;
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
            .edit => |h| std.fmt.bufPrint(&buf, "Edit hunk {d}", .{h + 1}) catch "Edit",
        }, .{ .wrap = false });
        ui.open(.{ .style = .{ .grow = 1, .basis = .{ .px = 0 } } });
        const r = if (c == .edit)
            zg_gui.w.textField(ui, .{ .buffer = f, .a11y_label = "Proposed lines", .multiline = true, .submit_on_enter = false, .min_rows = 3, .max_rows = 12 })
        else
            zg_gui.w.textField(ui, .{ .buffer = f, .a11y_label = "Comment", .placeholder = "issue (blocking): …" });
        ui.close();
        if (r.submitted) v.action = .post;
        if (r.cancelled) v.action = .cancel_comment;
        if (zg_gui.w.button(ui, .{ .label = if (c == .edit) "Accept edit" else "Post", .variant = .primary }).clicked) v.action = .post;
        if (zg_gui.w.button(ui, .{ .label = "Cancel", .variant = .ghost }).clicked) v.action = .cancel_comment;
    }

    /// Posts the composer's text (locked).
    fn post(v: *ReviewView) anyerror!?zg_review.session.Failure {
        const c = v.composer orelse return null;
        const body = if (v.field) |*f| f.slice() else return null;
        // An empty edit accepts the hunk as a deletion of its base lines.
        if (c != .edit and std.mem.trim(u8, body, " \t\r\n").len == 0) return null;
        const g = v.glue;
        const now = nowMs(v.io);
        switch (c) {
            .edit => |hi| {
                const s = v.session;
                const old = try s.proposedText(v.arena.allocator(), s.cursor.file, hi) orelse return null;
                // Lines keep their line ends when the proposal had one.
                const text = if (std.mem.endsWith(u8, old, "\n")) try std.mem.concat(v.arena.allocator(), u8, &.{ body, "\n" }) else body;
                s.focus(.{ .file = s.cursor.file, .hunk = hi });
                const fail = try s.acceptHunkEdited(text);
                v.composer = null;
                return fail;
            },
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
        return v.send(f, cs, ids.items, "");
    }

    /// Asks the agent to redo conflicted hunk `hi` of the focused file on
    /// top of the current text, with both sides in the message.
    fn reask(v: *ReviewView, hi: u32) anyerror!?zg_review.session.Failure {
        const f = &(v.glue.feedback orelse return null);
        const cs = v.focusedCs() orelse return null;
        const s = v.session;
        const fc = s.fileChange(s.cursor.file) orelse return null;
        if (hi >= fc.hunks.len) return null;
        const h = fc.hunks[hi];
        const c = h.conflict orelse return null;
        const a = v.arena.allocator();
        const theirs = try s.proposedText(a, s.cursor.file, hi) orelse "";
        const msg = try std.fmt.allocPrint(a, "Your change to {s} (hunk {d}) conflicts: {s}.\n\nThe text there now:\n```\n{s}```\n\nYou proposed:\n```\n{s}```\n\nRedo this change on top of the current text.", .{
            fc.path, hi + 1, conflictReason(c.kind), c.theirs_text, theirs,
        });
        return v.send(f, cs, &.{}, msg);
    }

    fn send(v: *ReviewView, f: *feedback.Feedback, cs: zg_review.model.ChangesetId, ids: []const feedback.ThreadId, extra: []const u8) anyerror!?zg_review.session.Failure {
        v.notice = switch (try f.requestFix(cs, ids, extra, nowMs(v.io))) {
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
            try v.lineRows(&out, 0, old[@min(os, old.len)..@min(os + oc, old.len)], new[@min(ns, new.len)..@min(ns + nc, new.len)]);
        }
        if (n == 0) try out.append(a, .{ .kind = .note, .text = "No changes between the two proposals." });
        return out.items;
    }

    /// Whether a hunk's lines are hidden: accepted ones (when
    /// `collapse_accepted`) and large ones are, unless flipped.
    fn collapsed(v: *const ReviewView, h: zg_review.model.changeset.Hunk) bool {
        const by_default = (v.collapse_accepted and h.decision == .accepted) or h.base_lines.count + h.new_lines.count > collapse_lines;
        return by_default != v.flipped.contains(h.key);
    }

    /// A hunk's removed lines `ol` and added lines `nl` as rows, in the
    /// layout, with intraline highlights.
    fn lineRows(v: *ReviewView, out: *std.ArrayList(Row), hunk: u32, ol: []const []const u8, nl: []const []const u8) !void {
        const a = v.arena.allocator();
        const hl = try intralineSpans(a, v.gpa, ol, nl);
        switch (v.layout) {
            .inline_ => {
                for (ol, hl.old) |l, sp| try out.append(a, .{ .kind = .del, .hunk = hunk, .text = l, .spans = sp });
                for (nl, hl.new) |l, sp| try out.append(a, .{ .kind = .add, .hunk = hunk, .text = l, .spans = sp });
            },
            .side_by_side => for (0..@max(ol.len, nl.len)) |k| try out.append(a, .{
                .kind = .pair,
                .hunk = hunk,
                .old = k < ol.len,
                .text = if (k < ol.len) ol[k] else "",
                .spans = if (k < ol.len) hl.old[k] else &.{},
                .new = if (k < nl.len) nl[k] else null,
                .new_spans = if (k < nl.len) hl.new[k] else &.{},
            }),
        }
    }

    /// One removed (`added` false) or added line: "- text" in the mono
    /// font, its changed spans on the status colour; decided hunks' lines
    /// are dimmed.
    fn lineText(v: *ReviewView, ui: *Ui, added: bool, hunk: u32, text: []const u8, spans: []const Span) void {
        const s = v.session;
        const decided = if (v.interdiff) false else if (s.fileChange(s.cursor.file)) |fc| hunk < fc.hunks.len and fc.hunks[hunk].decision != .undecided else false;
        const color: zg_gui.theme.Token = if (decided) .fg_muted else if (added) .success else .danger;
        const mono: zg_gui.paint.text.TextStyle = .{ .font = .mono };
        const prefix = if (added) "+ " else "- ";
        const line = std.mem.concat(v.arena.allocator(), u8, &.{ prefix, text }) catch text;
        if (spans.len == 0 or decided) {
            ui.text(line, .{ .style = mono, .color = color, .wrap = false });
            return;
        }
        ui.open(.{ .style = .{ .dir = .row }, .role = .group, .label = line });
        defer ui.close();
        ui.text(prefix, .{ .style = mono, .color = color, .wrap = false });
        var at: usize = 0;
        for (spans) |sp| {
            if (sp.start > at) ui.text(text[at..sp.start], .{ .style = mono, .color = color, .wrap = false });
            ui.open(.{ .style = .{ .bg = .{ .token = color } } });
            ui.text(text[sp.start..sp.end], .{ .style = mono, .color = .fg_on_accent, .wrap = false });
            ui.close();
            at = sp.end;
        }
        if (at < text.len) ui.text(text[at..], .{ .style = mono, .color = color, .wrap = false });
    }

    /// The key scope's name: the view plus the focused hunk.
    fn scopeLabel(v: *ReviewView) []const u8 {
        const s = v.session;
        const fc = s.fileChange(s.cursor.file) orelse return "Review";
        const h = s.cursor.hunk orelse return "Review";
        const l = hunkLabel(v.arena.allocator(), fc, h) catch return "Review";
        return std.fmt.allocPrint(v.arena.allocator(), "Review, {s}", .{l}) catch "Review";
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

/// Changed bytes `[start, end)` within one line.
const Span = struct { start: u32, end: u32 };

const Highlights = struct { old: []const []const Span, new: []const []const Span };

/// The changed spans of each removed line `ol` and added line `nl`,
/// from E05's intraline diff of the two texts (in `a`; `gpa` for the
/// diff's scratch). Blocks E05 skips, and lines changed as a whole, get
/// none.
fn intralineSpans(a: Allocator, gpa: Allocator, ol: []const []const u8, nl: []const []const u8) !Highlights {
    const old = try a.alloc([]const Span, ol.len);
    @memset(old, &.{});
    const new = try a.alloc([]const Span, nl.len);
    @memset(new, &.{});
    const out: Highlights = .{ .old = old, .new = new };
    const max = diff.intraline.max_block_lines;
    if (ol.len == 0 or nl.len == 0 or ol.len > max or nl.len > max) return out;
    const ot = try joinLines(a, ol);
    const nt = try joinLines(a, nl);
    var la = try diff.LineSource.fromBytes(gpa, ot);
    defer la.deinit(gpa);
    var lb = try diff.LineSource.fromBytes(gpa, nt);
    defer lb.deinit(gpa);
    var r = try diff.diffLines(gpa, &la, &lb, .{ .context_lines = 0 });
    defer r.deinit(gpa);
    const lists_old = try a.alloc(std.ArrayList(Span), ol.len);
    @memset(lists_old, .empty);
    const lists_new = try a.alloc(std.ArrayList(Span), nl.len);
    @memset(lists_new, .empty);
    for (r.ranges) |x| {
        if (x.kind != .changed) continue;
        const lines, const lists = if (x.side == .old) .{ ol, lists_old } else .{ nl, lists_new };
        var off: u64 = 0;
        for (lines, lists) |l, *list| {
            const lo = @max(x.range.start, off);
            const hi = @min(x.range.end, off + l.len);
            if (lo < hi) try list.append(a, .{ .start = @intCast(lo - off), .end = @intCast(hi - off) });
            off += l.len + 1;
        }
    }
    inline for (.{ .{ ol, lists_old, old }, .{ nl, lists_new, new } }) |side| {
        for (side[0], side[1], side[2]) |l, list, *dst| {
            const whole = list.items.len == 1 and list.items[0].start == 0 and list.items[0].end >= l.len;
            if (!whole) dst.* = list.items;
        }
    }
    return out;
}

fn joinLines(a: Allocator, lines: []const []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    for (lines) |l| {
        try w.writer.writeAll(l);
        try w.writer.writeByte('\n');
    }
    return w.written();
}

/// Why a hunk conflicts, as a sentence fragment.
fn conflictReason(k: zg_review.model.changeset.ConflictKind) []const u8 {
    return switch (k) {
        .user_edit => "You edited these lines after the agent proposed its change",
        .external_change => "These lines changed on disk after the agent proposed its change",
        .sibling_changeset => "Another accepted change touched these lines",
        .base_missing => "The text the agent changed is gone",
    };
}

/// "Hunk 3 of 12, 4 lines added, 2 removed, pending"
fn hunkLabel(a: Allocator, fc: *const zg_review.model.FileChange, hunk: u32) ![]const u8 {
    if (hunk >= fc.hunks.len) return "";
    const h = fc.hunks[hunk];
    return std.fmt.allocPrint(a, "Hunk {d} of {d}, {d} line{s} added, {d} removed, {s}", .{
        hunk + 1,
        fc.hunks.len,
        h.new_lines.count,
        if (h.new_lines.count == 1) "" else "s",
        h.base_lines.count,
        if (h.conflict != null) "conflict" else switch (h.decision) {
            .undecided => "pending",
            .accepted => "accepted",
            .rejected => "rejected",
            .edited => "edited",
        },
    });
}

/// "Show 1,234 lines"
fn showLabel(buf: []u8, n: u32) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("Show ") catch {};
    var digits: [16]u8 = undefined;
    const d = std.fmt.bufPrint(&digits, "{d}", .{n}) catch "";
    for (d, 0..) |c, i| {
        if (i > 0 and (d.len - i) % 3 == 0) w.writeByte(',') catch {};
        w.writeByte(c) catch {};
    }
    w.writeAll(if (n == 1) " line" else " lines") catch {};
    return w.buffered();
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

test "review view: keys move, decide, comment, reply and resolve" {
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
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 900, .h = 500 }, .root = .of(&view) });
    defer t.deinit();
    const v = try ReviewView.create(gpa, testing.io, &t.app, g, .{ .changeset = id });
    defer v.destroy();
    view.v = v;
    t.win.markAllDirty();
    _ = t.settle();
    const press = struct {
        fn f(app: *zg_gui.testing.TestApp, k: @FieldType(ev_mod.KeyPress, "key"), cp: u21, shift: bool) void {
            app.win.dispatch(.{ .key = .{ .key = k, .codepoint = cp, .mods = .{ .shift = shift } } });
            app.win.dispatch(.{ .key = .{ .key = k, .codepoint = cp, .mods = .{ .shift = shift }, .action = .release } });
            _ = app.settle();
        }
    }.f;
    t.win.setFocus(t.find(.{ .role = .group, .name = "Review" }).?, false);

    // `j` moves to hunk 2, `x` rejects it; `u` undoes that.
    press(t, .key_j, 'j', false);
    try testing.expectEqual(@as(?u32, 1), v.session.cursor.hunk);
    press(t, .key_x, 'x', false);
    try testing.expect(t.find(.{ .name_contains = "1 of 2 decided" }) != null);
    press(t, .key_u, 'u', false);
    try testing.expect(t.find(.{ .name_contains = "0 of 2 decided" }) != null);

    // `m` opens the composer on the hunk under the cursor.
    press(t, .key_k, 'k', false);
    press(t, .key_m, 'm', false);
    try testing.expect(v.composer != null and v.composer.? == .hunk and v.composer.?.hunk == 0);
    try v.field.?.setText("nit: shout less");
    v.glue.mutex.lockUncancelable(testing.io);
    _ = try v.post();
    v.glue.mutex.unlock(testing.io);
    t.win.markAllDirty();
    _ = t.settle();
    t.win.setFocus(t.find(.{ .role = .group, .name = "Review" }).?, false);
    const th = g.comments.threadsOf(id)[0].id;

    // `r` replies to that thread, `R` resolves it, and `R` again reopens it.
    press(t, .key_r, 'r', false);
    try testing.expect(v.composer.? == .reply and v.composer.?.reply == th);
    v.composer = null;
    press(t, .key_r, 'R', true);
    try testing.expect(g.comments.get(th).?.resolved);
    press(t, .key_r, 'R', true);
    try testing.expect(!g.comments.get(th).?.resolved);

    // While the composer is open, keys are its text.
    press(t, .key_m, 'm', false);
    press(t, .key_a, 'a', false);
    try testing.expect(t.find(.{ .name_contains = "0 of 2 decided" }) != null);
    v.composer = null;

    // `a` accepts the hunk under the cursor; `A` the rest of the file.
    press(t, .key_a, 'a', false);
    try testing.expect(t.find(.{ .name_contains = "1 of 2 decided" }) != null);
    press(t, .key_a, 'A', true);
    try testing.expectEqual(zg_review.model.State.applied, g.q.get(id).?.state);
}

test "review view: intraline spans, hunk labels and the show label" {
    const testing = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const hl = try intralineSpans(a, testing.allocator, &.{"const answer = compute(41, base);"}, &.{"const answer = compute(42, base);"});
    try testing.expectEqual(@as(usize, 1), hl.old[0].len);
    const sp = hl.old[0][0];
    try testing.expectEqualStrings("41", "const answer = compute(41, base);"[sp.start..sp.end]);
    try testing.expectEqualStrings("42", "const answer = compute(42, base);"[hl.new[0][0].start..hl.new[0][0].end]);
    // A line changed as a whole, and a pure insertion, get none.
    const whole = try intralineSpans(a, testing.allocator, &.{"one"}, &.{"ONE"});
    try testing.expectEqual(@as(usize, 0), whole.old[0].len);
    const ins = try intralineSpans(a, testing.allocator, &.{}, &.{"x"});
    try testing.expectEqual(@as(usize, 0), ins.new[0].len);

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Show 1,234 lines", showLabel(&buf, 1234));
    try testing.expectEqualStrings("Show 401 lines", showLabel(&buf, 401));
    try testing.expectEqualStrings("Show 1 line", showLabel(&buf, 1));

    var hunks = [_]zg_review.model.changeset.Hunk{
        .{ .id = 0, .base_lines = .{ .start = 0, .count = 2 }, .new_lines = .{ .start = 0, .count = 4 }, .replace_span = .{ 0, 1 } },
        .{ .id = 1, .base_lines = .{ .start = 5, .count = 1 }, .new_lines = .{ .start = 7, .count = 1 }, .replace_span = .{ 1, 2 }, .decision = .accepted },
    };
    const fc: zg_review.model.FileChange = .{ .path = "a", .op = .modify, .content = undefined, .hunks = &hunks };
    try testing.expectEqualStrings("Hunk 1 of 2, 4 lines added, 2 removed, pending", try hunkLabel(a, &fc, 0));
    try testing.expectEqualStrings("Hunk 2 of 2, 1 line added, 1 removed, accepted", try hunkLabel(a, &fc, 1));
}

test "review view: side by side and inline layouts, highlights, collapsed hunks" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    // a.txt: one word changes in a long line, and 401 lines are added
    // after the gap.
    var big: std.Io.Writer.Allocating = .init(ar);
    try big.writer.writeAll("const answer = compute(41, base);\n.\n.\n.\n.\nend\n");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = big.written() });
    var next: std.Io.Writer.Allocating = .init(ar);
    try next.writer.writeAll("const answer = compute(42, base);\n.\n.\n.\n.\nend\n");
    for (0..401) |i| try next.writer.print("line {d}\n", .{i});
    const g = try ReviewGlue.create(gpa, testing.io, root, .{});
    defer g.destroy();
    g.mode = .review;
    const fs = g.files();
    const s1: @import("zg_ai").proto.AgentRef = .{ .session = 0x51 };
    const origin: @import("zg_ai").tools.builtin.files.Origin = .{ .agent = s1, .turn = 1, .tool = "edit_file", .tool_call_id = "t" };
    const abs = (try fs.resolve(testing.io, ar, "a.txt")).abs;
    _ = try fs.propose(testing.io, ar, abs, .{ .whole_file = .{ .text = next.written(), .base_version = null } }, origin);
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

    // Side by side by default: the changed line is one row whose halves
    // carry their whole text; "41" and "42" are their own highlighted runs.
    try testing.expectEqual(ReviewView.Layout.side_by_side, v.layout);
    try testing.expect(t.find(.{ .role = .group, .name = "- const answer = compute(41, base);" }) != null);
    try testing.expect(t.find(.{ .role = .group, .name = "+ const answer = compute(42, base);" }) != null);
    try testing.expect(t.find(.{ .name = "41" }) != null);
    try testing.expect(t.find(.{ .name = "42" }) != null);
    try testing.expect(t.find(.{ .role = .group, .name = "Hunk 1 of 2, 1 line added, 1 removed, pending" }) != null);

    // The 401-line hunk is collapsed; Show expands it, Hide lines folds it.
    try testing.expect(t.find(.{ .name = "+ line 0" }) == null);
    try t.click(.{ .role = .button, .name = "Show 401 lines" });
    _ = t.settle();
    try testing.expect(t.find(.{ .name = "+ line 0" }) != null);
    try t.click(.{ .role = .button, .name = "Hide lines" });
    _ = t.settle();
    try testing.expect(t.find(.{ .name = "+ line 0" }) == null);

    // Inline: the removed line, then the added one, as rows of their own.
    try t.click(.{ .role = .button, .name = "Inline" });
    _ = t.settle();
    try testing.expectEqual(ReviewView.Layout.inline_, v.layout);
    try testing.expect(t.find(.{ .role = .button, .name = "Side by side" }) != null);
    try testing.expect(t.find(.{ .role = .group, .name = "- const answer = compute(41, base);" }) != null);
    try testing.expect(t.find(.{ .name = "41" }) != null);
}

test "review view: edit a hunk's proposed lines, then accept the edit" {
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
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 900, .h = 500 }, .root = .of(&view) });
    defer t.deinit();
    const v = try ReviewView.create(gpa, testing.io, &t.app, g, .{ .changeset = id });
    defer v.destroy();
    view.v = v;
    t.win.markAllDirty();
    _ = t.settle();

    // `j` then `e` edits the second hunk: its proposed line is in the
    // field.
    const press = struct {
        fn f(app: *zg_gui.testing.TestApp, k: @FieldType(ev_mod.KeyPress, "key"), cp: u21) void {
            app.win.dispatch(.{ .key = .{ .key = k, .codepoint = cp } });
            app.win.dispatch(.{ .key = .{ .key = k, .codepoint = cp, .action = .release } });
            _ = app.settle();
        }
    }.f;
    t.win.setFocus(t.find(.{ .role = .group, .name = "Review" }).?, false);
    press(t, .key_j, 'j');
    press(t, .key_e, 'e');
    try testing.expect(v.composer != null and v.composer.? == .edit and v.composer.?.edit == 1);
    try testing.expectEqualStrings("TWO", v.field.?.slice());
    try testing.expect(t.find(.{ .name_contains = "Edit hunk 2" }) != null);

    // The reviewer rewrites it as two lines and accepts the edit.
    try v.field.?.setText("Two\nand three");
    try t.click(.{ .role = .button, .name = "Accept edit" });
    _ = t.settle();
    try testing.expect(v.composer == null);
    const got = try tmp.dir.readFileAlloc(testing.io, "a.txt", ar, .limited(64));
    try testing.expectEqualStrings("one\n.\n.\n.\n.\nTwo\nand three\n", got);
    try testing.expect(t.find(.{ .name_contains = "1 of 2 decided" }) != null);

    // Undo puts the file back.
    try t.click(.{ .role = .button, .name = "Undo" });
    _ = t.settle();
    try testing.expectEqualStrings("one\n.\n.\n.\n.\ntwo\n", try tmp.dir.readFileAlloc(testing.io, "a.txt", ar, .limited(64)));
}

test "review view: a conflicted hunk shows both sides, re-asks the agent, takes mine" {
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
    // The second hunk conflicts: the user changed "two" meanwhile.
    {
        const h = &g.q.getMut(id).?.files[0].hunks[1];
        h.conflict = .{ .kind = .user_edit, .ours_lines = h.base_lines, .theirs_text = "two\n" };
    }

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
    try testing.expect(t.find(.{ .name_contains = "You edited these lines after the agent proposed its change. Left: your text now" }) != null);
    try testing.expect(t.find(.{ .role = .button, .name = "Take agent" }) != null);
    try testing.expect(t.find(.{ .role = .button, .name = "Edit merge" }) != null);
    try testing.expect(t.find(.{ .name_contains = "Hunk 2 of 2, 1 line added, 1 removed, conflict" }) != null);

    // Re-ask sends both sides to the agent.
    try t.click(.{ .role = .button, .name = "Re-ask agent" });
    _ = t.settle();
    try testing.expect(std.mem.indexOf(u8, agent.sent.items, "The text there now:\n```\ntwo\n```") != null);
    try testing.expect(std.mem.indexOf(u8, agent.sent.items, "You proposed:\n```\nTWO\n```") != null);
    try testing.expect(t.find(.{ .name = "Sent to the agent as a new turn." }) != null);

    // Take mine keeps the file and decides the hunk.
    try t.click(.{ .role = .button, .name = "Take mine" });
    _ = t.settle();
    try testing.expectEqualStrings("one\n.\n.\n.\n.\ntwo\n", try tmp.dir.readFileAlloc(testing.io, "a.txt", ar, .limited(64)));
    try testing.expect(t.find(.{ .name_contains = "1 of 2 decided" }) != null);
}
