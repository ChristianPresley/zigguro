//! Document mode's comments pane (E13.F04.S02.T01): the document's
//! threads in text order, then detached ones. Clicking a thread goes to
//! its text; the selected thread takes a reply, can be sent to the agent,
//! resolved or reopened, and a detached one can be attached to the
//! current selection. A new comment goes on the selection.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const controls = zg_gui.w.controls;
const text_field = zg_gui.w.text_field;
const TextBuffer = text_field.TextBuffer;
const docs = zg_agents.docs;
const comments = docs.comments;
const Range = docs.sections.Range;
const CommentStore = comments.CommentStore;
const ThreadId = comments.ThreadId;

pub const Ports = struct {
    /// Puts the editor's cursor at a byte offset.
    navigate: struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, offset: u32) void },
    /// The document's current text.
    doc: struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) []const u8 },
    /// The editor's selection, if any.
    selection: struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) ?Range },
    /// The person's name on their comments.
    user: []const u8 = "",
};

pub const CommentsView = struct {
    gpa: Allocator,
    store: *CommentStore,
    ports: Ports,
    selected: ?ThreadId = null,
    show_resolved: bool = false,
    reply: TextBuffer,
    draft: TextBuffer,
    /// The last error, shown until the next action.
    notice: ?[]const u8 = null,

    pub fn init(gpa: Allocator, store: *CommentStore, ports: Ports) !CommentsView {
        var reply = try TextBuffer.init(gpa, "");
        errdefer reply.deinit();
        return .{ .gpa = gpa, .store = store, .ports = ports, .reply = reply, .draft = try TextBuffer.init(gpa, "") };
    }

    pub fn deinit(v: *CommentsView) void {
        v.reply.deinit();
        v.draft.deinit();
    }

    fn user(v: *const CommentsView) comments.Author {
        return .{ .user = v.ports.user };
    }

    fn fail(v: *CommentsView, err: anyerror) void {
        v.notice = switch (err) {
            error.OutOfMemory => "Out of memory",
            else => "Could not save the comment",
        };
    }

    pub fn select(v: *CommentsView, t: ThreadId) void {
        v.selected = t;
        v.reply.setText("") catch {};
        if (v.store.get(t)) |th| if (th.anchor) |r| v.ports.navigate.f(v.ports.navigate.ctx, r.start);
    }

    /// A new thread on the selection.
    pub fn comment(v: *CommentsView, ask: bool) void {
        v.notice = null;
        const sel = v.ports.selection.f(v.ports.selection.ctx) orelse {
            v.notice = "Select the text to comment on first";
            return;
        };
        const raw = std.mem.trim(u8, v.draft.slice(), " \t\n");
        if (raw.len == 0 and !ask) return;
        var buf: [4096]u8 = undefined;
        const text = if (ask and !comments.mentionsAgent(raw)) std.fmt.bufPrint(&buf, "@agent {s}", .{raw}) catch raw else raw;
        const id = v.store.add(v.ports.doc.f(v.ports.doc.ctx), sel, text, v.user()) catch |e| return v.fail(e);
        v.draft.setText("") catch {};
        v.selected = id;
    }

    pub fn sendReply(v: *CommentsView, ask: bool) void {
        v.notice = null;
        const t = v.selected orelse return;
        const raw = std.mem.trim(u8, v.reply.slice(), " \t\n");
        if (raw.len == 0) {
            if (ask) v.store.askAgent(t) catch |e| v.fail(e);
            return;
        }
        var buf: [4096]u8 = undefined;
        const text = if (ask and !comments.mentionsAgent(raw)) std.fmt.bufPrint(&buf, "@agent {s}", .{raw}) catch raw else raw;
        _ = v.store.reply(t, text, v.user()) catch |e| return v.fail(e);
        v.reply.setText("") catch {};
    }

    pub fn toggleResolved(v: *CommentsView) void {
        const t = v.selected orelse return;
        const th = v.store.get(t) orelse return;
        if (th.resolved) {
            _ = v.store.reply(t, "Reopened.", v.user()) catch |e| v.fail(e);
        } else v.store.resolve(t) catch |e| v.fail(e);
    }

    pub fn reattach(v: *CommentsView) void {
        const t = v.selected orelse return;
        const sel = v.ports.selection.f(v.ports.selection.ctx) orelse {
            v.notice = "Select the text to attach the comment to";
            return;
        };
        v.store.setAnchor(t, v.ports.doc.f(v.ports.doc.ctx), sel) catch |e| v.fail(e);
    }

    pub fn build(v: *CommentsView, ui: *Ui) void {
        v.store.sort();
        ui.open(.{ .role = .group, .label = "Comments", .test_id = "doc-comments", .style = .{ .dir = .column, .gap = 6, .padding = .all(6), .grow = 1 } });
        defer ui.close();
        var open_count: usize = 0;
        for (v.store.threads()) |t| open_count += @intFromBool(!t.resolved);
        ui.open(.{ .style = .{ .dir = .row, .gap = 6, .align_items = .center } });
        ui.textf("{d} open", .{open_count}, .{ .wrap = false, .style = .{ .weight = 700 } });
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        if (controls.button(ui, .{ .label = if (v.show_resolved) "Hide resolved" else "Show resolved", .variant = .ghost }).clicked) v.show_resolved = !v.show_resolved;
        ui.close();
        if (v.notice) |n| {
            ui.open(.{ .role = .status, .label = n });
            ui.text(n, .{ .color = .warning });
            ui.close();
        }
        // A new comment on the selection.
        ui.open(.{ .style = .{ .dir = .row, .gap = 4 } });
        ui.open(.{ .style = .{ .grow = 1 } });
        const r = text_field.textField(ui, .{ .buffer = &v.draft, .a11y_label = "New comment", .placeholder = "Comment on the selection… (@agent to ask)" });
        ui.close();
        if (r.submitted or controls.button(ui, .{ .label = "Comment" }).clicked) v.comment(false);
        if (controls.button(ui, .{ .label = "Ask agent", .variant = .ghost }).clicked) v.comment(true);
        ui.close();

        var detached_heading = false;
        for (v.store.threads()) |*t| {
            if (t.resolved and !v.show_resolved) continue;
            if (t.anchor == null and !detached_heading) {
                detached_heading = true;
                ui.text("Detached (their text is gone)", .{ .color = .fg_muted, .wrap = false });
            }
            v.thread(ui, t);
        }
    }

    fn thread(v: *CommentsView, ui: *Ui, t: *const comments.Thread) void {
        const sel = v.selected != null and v.selected.? == t.id;
        const label = std.fmt.allocPrint(ui.arena(), "Comment on \"{s}\", {d} comment{s}{s}{s}", .{
            t.quote[0..@min(t.quote.len, 60)],
            t.comments.items.len,
            if (t.comments.items.len == 1) "" else "s",
            if (t.resolved) ", resolved" else "",
            if (t.anchor == null) ", detached" else "",
        }) catch "";
        ui.id(@as(u64, t.id) + 1);
        ui.open(.{ .role = .listitem, .label = label, .hit = true, .style = .{
            .dir = .column,
            .gap = 2,
            .padding = .all(6),
            .bg = if (sel) .{ .token = .selection_bg } else .{ .token = .bg_elevated },
        } });
        if (ui.response().clicked) v.select(t.id);
        ui.text(t.quote[0..@min(t.quote.len, 120)], .{ .color = .fg_muted, .style = .{ .italic = true } });
        for (t.comments.items) |c| {
            const who = switch (c.author) {
                .user => |u| if (u.len > 0) u else "You",
                .agent => "Agent",
            };
            ui.textf("{s}: {s}", .{ who, c.text }, .{});
        }
        if (sel) {
            ui.open(.{ .style = .{ .dir = .row, .gap = 4 } });
            ui.open(.{ .style = .{ .grow = 1 } });
            const r = text_field.textField(ui, .{ .buffer = &v.reply, .a11y_label = "Reply", .placeholder = "Reply…" });
            ui.close();
            if (r.submitted or controls.button(ui, .{ .label = "Reply" }).clicked) v.sendReply(false);
            if (controls.button(ui, .{ .label = "Ask agent", .variant = .ghost }).clicked) v.sendReply(true);
            if (controls.button(ui, .{ .label = if (t.resolved) "Reopen" else "Resolve", .variant = .ghost }).clicked) v.toggleResolved();
            if (t.anchor == null and controls.button(ui, .{ .label = "Attach to selection", .variant = .ghost }).clicked) v.reattach();
            ui.close();
        }
        ui.close();
    }
};
