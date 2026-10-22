//! The inline edit prompt bar (E12.F06.S01.T02): the field where the user
//! types an instruction for the selection, the streaming status, the
//! Accept/Reject/Ask agent controls and the answer of a question. It
//! drives one `InlineEditSession` at a time; the editor hosts it above the
//! selection and shows the session's live edits as a pending change.
//!
//! Keys (rebindable through `Keys`):
//! - Enter edits (a follow-up once an edit is ready), Alt+Enter asks.
//! - Ctrl+Enter accepts the edit.
//! - Escape cancels while streaming, otherwise rejects and closes.
//! - Ctrl+Backspace rejects a ready edit (otherwise the field deletes a word).
//! - Ctrl+L hands the selection and instruction to the agent pane. With an
//!   edit pending it asks first; a second Ctrl+L discards the edit.
//! - Up/Down recall earlier instructions when the field is empty or still
//!   shows a recalled one unchanged (the shell rule, without a caret test).
//!
//! The last 50 instructions persist per workspace (`History.load/save`).
//! Every key also has a button labelled with its shortcut, and status
//! changes are announced.
//!
//! UI thread only. `Hooks.closed` runs inside `build`: the host must not
//! destroy the bar there (post it).

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_review = @import("zg_review");
const zg_platform = @import("zg_platform");
const zg_ai_proto = @import("zg_ai").proto;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const TextBuffer = zg_gui.w.TextBuffer;
const ev_mod = zg_gui.input.event;
const widget = zg_gui.core.widget;
const Key = zg_platform.keys.Key;
const Mods = zg_platform.keys.Mods;
const inline_edit = zg_review.assist.inline_edit;
const InlineEditSession = inline_edit.InlineEditSession;

/// Earlier instructions, oldest first, and the recall position.
pub const History = struct {
    gpa: Allocator,
    items: std.ArrayList([]u8) = .empty,
    cap: usize = 50,
    /// The entry shown while recalling.
    at: ?usize = null,
    /// What the field held before recall started.
    draft: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) History {
        return .{ .gpa = gpa };
    }

    pub fn deinit(h: *History) void {
        for (h.items.items) |x| h.gpa.free(x);
        h.items.deinit(h.gpa);
        h.draft.deinit(h.gpa);
    }

    /// Records a sent instruction (not blanks or a repeat of the newest)
    /// and ends recall.
    pub fn add(h: *History, text: []const u8) !void {
        h.at = null;
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len == 0) return;
        if (h.items.items.len > 0 and std.mem.eql(u8, h.items.items[h.items.items.len - 1], t)) return;
        const copy = try h.gpa.dupe(u8, t);
        errdefer h.gpa.free(copy);
        try h.items.append(h.gpa, copy);
        while (h.items.items.len > h.cap) h.gpa.free(h.items.orderedRemove(0));
    }

    /// Whether Up/Down recall now, given the field's text.
    pub fn recalls(h: *const History, current: []const u8) bool {
        if (current.len == 0) return true;
        const i = h.at orelse return false;
        return std.mem.eql(u8, h.items.items[i], current);
    }

    /// The entry before the shown one (the newest first), or null.
    pub fn prev(h: *History, current: []const u8) !?[]const u8 {
        if (h.items.items.len == 0) return null;
        const i = if (h.at) |i| (if (i == 0) return null else i - 1) else blk: {
            h.draft.clearRetainingCapacity();
            try h.draft.appendSlice(h.gpa, current);
            break :blk h.items.items.len - 1;
        };
        h.at = i;
        return h.items.items[i];
    }

    /// The entry after the shown one; past the newest, the draft.
    pub fn next(h: *History) ?[]const u8 {
        const i = h.at orelse return null;
        if (i + 1 < h.items.items.len) {
            h.at = i + 1;
            return h.items.items[i + 1];
        }
        h.at = null;
        return h.draft.items;
    }

    /// One entry per line, `\` and newlines escaped.
    pub fn encode(h: *const History, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (h.items.items) |x| {
            for (x) |c| switch (c) {
                '\\' => try out.appendSlice(gpa, "\\\\"),
                '\n' => try out.appendSlice(gpa, "\\n"),
                '\r' => try out.appendSlice(gpa, "\\r"),
                else => try out.append(gpa, c),
            };
            try out.append(gpa, '\n');
        }
        return out.toOwnedSlice(gpa);
    }

    /// Replaces the entries with those in `bytes` (from `encode`).
    pub fn decode(h: *History, bytes: []const u8) !void {
        for (h.items.items) |x| h.gpa.free(x);
        h.items.clearRetainingCapacity();
        h.at = null;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(h.gpa);
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            buf.clearRetainingCapacity();
            var i: usize = 0;
            while (i < line.len) : (i += 1) {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 1;
                    try buf.append(h.gpa, switch (line[i]) {
                        'n' => '\n',
                        'r' => '\r',
                        else => line[i],
                    });
                } else try buf.append(h.gpa, line[i]);
            }
            try h.add(buf.items);
        }
    }

    /// Loads `sub_path` under `dir`; a missing file leaves it empty.
    pub fn load(h: *History, io: Io, dir: Io.Dir, sub_path: []const u8) !void {
        const bytes = dir.readFileAlloc(io, sub_path, h.gpa, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer h.gpa.free(bytes);
        try h.decode(bytes);
    }

    /// Writes the entries to `sub_path` under `dir`, creating its folder.
    pub fn save(h: *const History, io: Io, dir: Io.Dir, sub_path: []const u8) !void {
        const bytes = try h.encode(h.gpa);
        defer h.gpa.free(bytes);
        if (std.fs.path.dirname(sub_path)) |d| try dir.createDirPath(io, d);
        try dir.writeFile(io, .{ .sub_path = sub_path, .data = bytes });
    }
};

/// A key with modifiers. `ctrl` also matches Cmd.
pub const Chord = struct {
    key: Key,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    fn matches(c: Chord, k: ev_mod.KeyPress) bool {
        if (k.key != c.key and !(c.key == .enter and k.key == .numpad_enter)) return false;
        return c.ctrl == (k.mods.ctrl or k.mods.super) and c.alt == k.mods.alt and c.shift == k.mods.shift;
    }
};

/// The bar's bindings (commands `inlineEdit.*`).
pub const Keys = struct {
    ask: Chord = .{ .key = .enter, .alt = true },
    accept: Chord = .{ .key = .enter, .ctrl = true },
    escape: Chord = .{ .key = .escape },
    reject: Chord = .{ .key = .backspace, .ctrl = true },
    to_agent: Chord = .{ .key = .key_l, .ctrl = true },
    history_prev: Chord = .{ .key = .arrow_up },
    history_next: Chord = .{ .key = .arrow_down },
};

pub const Action = enum { submit, ask, accept, reject, escape, to_agent, history_prev, history_next, retry, apply_answer };

/// What the bar edits.
pub const Target = struct {
    path: []const u8,
    language: []const u8 = "",
    /// The file as the editor has it (borrowed for the bar's life).
    text: []const u8,
    region: [2]usize,
    diagnostics: []const []const u8 = &.{},
    rules: []const u8 = "",
    secrets: ?inline_edit.session.Secrets = null,
    ref: zg_ai_proto.AgentRef,
    workspace: []const u8,
};

pub const Hooks = struct {
    ctx: *anyopaque,
    /// Opens the agent pane with a draft holding the selection and the
    /// instruction (E10 composer).
    to_agent: *const fn (ctx: *anyopaque, selection: []const u8, instruction: []const u8) void,
    /// The bar is done: accepted, rejected, cancelled or handed off.
    closed: *const fn (ctx: *anyopaque) void,
    /// The session changed off a build (stream events): rebuild.
    changed: *const fn (ctx: *anyopaque) void,
};

/// A key the scope took, for the next build.
const KeySink = struct { action: ?Action = null };

/// The bar's region: takes its keys before the field does (capture), and
/// Up/Down the single-line field leaves to it (bubble).
const BarScope = struct {
    pub const name = "inline_edit_bar";
    pub const Props = struct {
        sink: *KeySink,
        keys: *const Keys,
        /// An edit is ready (Ctrl+Backspace rejects instead of deleting).
        ready: bool,
    };

    pub fn event(ec: *ev_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const ev_mod.InputEvent) bool {
        const k = switch (ev.*) {
            .key => |k| k,
            else => return false,
        };
        if (k.action == .release) return false;
        const ks = props.keys;
        const a: Action = if (ec.phase == .capture) blk: {
            if (ks.ask.matches(k)) break :blk .ask;
            if (ks.accept.matches(k)) break :blk .accept;
            if (ks.escape.matches(k)) break :blk .escape;
            if (ks.to_agent.matches(k)) break :blk .to_agent;
            if (props.ready and ks.reject.matches(k)) break :blk .reject;
            return false;
        } else blk: {
            if (ks.history_prev.matches(k)) break :blk .history_prev;
            if (ks.history_next.matches(k)) break :blk .history_next;
            return false;
        };
        props.sink.action = a;
        ec.respond(.{ .changed = true });
        return true;
    }

    pub fn a11y(_: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .group, .name = "Inline edit" };
    }
};

/// A question's answer, parsed as Markdown while it streams (on the heap:
/// the view state points at the document).
const Answer = struct {
    doc: zg_gui.markdown.Doc,
    view: zg_gui.markdown.MdViewState,
    fed: usize = 0,
    done: bool = false,

    fn create(gpa: Allocator) !*Answer {
        const r = try gpa.create(Answer);
        r.* = .{ .doc = zg_gui.markdown.stream.init(gpa, .{}), .view = undefined };
        r.view = .init(gpa, &r.doc);
        return r;
    }

    fn destroy(r: *Answer, gpa: Allocator) void {
        r.view.deinit();
        r.doc.deinit();
        gpa.destroy(r);
    }
};

pub const InlineEditBar = struct {
    gpa: Allocator,
    q: *zg_review.model.Queue,
    applier: *zg_review.apply.Applier,
    port: inline_edit.ModelPort,
    target: Target,
    history: *History,
    hooks: Hooks,
    keys: Keys = .{},
    /// The model chip, e.g. "claude-sonnet-5-5".
    model_label: []const u8 = "",
    field: TextBuffer,
    session: ?*InlineEditSession = null,
    /// The instruction the session runs (the session borrows it).
    sent: std.ArrayList(u8) = .empty,
    sent_question: bool = false,
    answer: ?*Answer = null,
    sink: KeySink = .{},
    action: ?Action = null,
    /// Ctrl+L with an edit pending: the next one discards it.
    confirm_handoff: bool = false,
    /// Why the last start failed (e.g. a secret selection).
    note: []const u8 = "",
    /// The last state announced.
    announced: ?inline_edit.session.State = null,
    closed: bool = false,

    pub fn create(gpa: Allocator, q: *zg_review.model.Queue, applier: *zg_review.apply.Applier, port: inline_edit.ModelPort, target: Target, history: *History, hooks: Hooks) !*InlineEditBar {
        const b = try gpa.create(InlineEditBar);
        errdefer gpa.destroy(b);
        b.* = .{ .gpa = gpa, .q = q, .applier = applier, .port = port, .target = target, .history = history, .hooks = hooks, .field = try TextBuffer.init(gpa, "") };
        return b;
    }

    /// Cancels a running stream; a ready edit stays in the queue.
    pub fn destroy(b: *InlineEditBar) void {
        b.dropSession();
        b.sent.deinit(b.gpa);
        b.field.deinit();
        b.gpa.destroy(b);
    }

    /// The editor changed bytes `[from, to)` to `new_len` bytes.
    pub fn documentEdited(b: *InlineEditBar, from: usize, to: usize, new_len: usize) !void {
        if (b.session) |s| try s.documentEdited(from, to, new_len);
    }

    /// The session's state, or null before the first instruction.
    pub fn state(b: *const InlineEditBar) ?inline_edit.session.State {
        return if (b.session) |s| s.state else null;
    }

    pub fn build(b: *InlineEditBar, ui: *Ui) void {
        if (b.sink.action) |a| {
            b.sink.action = null;
            b.action = a;
        }
        const st = b.state();
        _ = ui.begin(BarScope, .{ .sink = &b.sink, .keys = &b.keys, .ready = st == .ready });
        defer ui.end(BarScope);
        ui.open(.{ .style = .{ .dir = .column, .gap = 4, .padding = .xy(8, 6), .bg = .{ .token = .bg_elevated } }, .test_id = "inline-edit-bar" });
        defer ui.close();

        ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .gap = 6 } });
        ui.open(.{ .style = .{ .grow = 1, .basis = .{ .px = 0 } } });
        const r = zg_gui.w.textField(ui, .{
            .buffer = &b.field,
            .a11y_label = "Inline edit instruction",
            .placeholder = if (st == .ready) "Follow-up instruction (Enter)" else "Edit the selection (Enter) or ask about it (Alt+Enter)",
        });
        ui.close();
        if (r.submitted) b.action = .submit;
        if (b.model_label.len > 0) ui.text(b.model_label, .{ .color = .fg_muted, .wrap = false });
        ui.close();

        b.status(ui);
        b.feedAnswer();
        if (b.answer) |ans| zg_gui.markdown.view(ui, &ans.view, .{ .streaming = !ans.done, .compact = true, .virtualize = false, .max_width = std.math.inf(f32) });
        b.buttons(ui);
        b.announce(ui);

        if (b.action) |a| {
            b.action = null;
            b.run(a) catch |e| {
                b.note = @errorName(e);
            };
            ui.window().markAllDirty();
        }
    }

    fn status(b: *InlineEditBar, ui: *Ui) void {
        var buf: [160]u8 = undefined;
        if (b.note.len > 0) ui.text(std.fmt.bufPrint(&buf, "⚠ {s}", .{b.note}) catch "⚠", .{ .color = .danger });
        const s = b.session orelse return;
        const line: []const u8, const color: zg_gui.theme.Token = switch (s.state) {
            .streaming => .{ std.fmt.bufPrint(&buf, "Generating… {d} characters", .{s.output().len}) catch "Generating…", .fg_muted },
            .ready => .{ if (s.changeset == null) "No changes." else "Ready: Ctrl+Enter accepts, Escape rejects.", .fg_muted },
            .answered => .{ "Answered.", .fg_muted },
            .accepted => .{ "Accepted.", .success },
            .rejected => .{ "Rejected.", .fg_muted },
            .cancelled => .{ if (s.reason.len > 0) s.reason else "Cancelled.", .fg_muted },
            .failed => .{ std.fmt.bufPrint(&buf, "⚠ {s}", .{failText(s.reason)}) catch "⚠ Failed", .danger },
        };
        ui.text(line, .{ .color = color });
        if (s.state == .ready) switch (s.parser.warning) {
            .none => {},
            .unterminated => ui.text("⚠ The answer was cut off; the edit may be incomplete.", .{ .color = .warning }),
            .no_open_tag => ui.text("⚠ The answer had no rewrite tag; it was taken as is.", .{ .color = .warning }),
        };
        if (b.confirm_handoff) ui.text("Hand off to the agent and discard this edit? Press Ctrl+L again.", .{ .color = .warning });
    }

    fn buttons(b: *InlineEditBar, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .row, .gap = 4 } });
        defer ui.close();
        const st = b.state();
        if (st == .streaming) {
            if (zg_gui.w.button(ui, .{ .label = "Cancel (Esc)", .variant = .ghost }).clicked) b.action = .escape;
        }
        if (st == .ready) {
            if (zg_gui.w.button(ui, .{ .label = "Accept (Ctrl+Enter)", .variant = .primary }).clicked) b.action = .accept;
            if (zg_gui.w.button(ui, .{ .label = "Reject (Esc)", .variant = .ghost }).clicked) b.action = .reject;
        }
        if (st == .answered) {
            if (zg_gui.w.button(ui, .{ .label = "Apply as edit", .variant = .primary }).clicked) b.action = .apply_answer;
        }
        if (st == .failed) {
            if (zg_gui.w.button(ui, .{ .label = "Retry", .variant = .primary }).clicked) b.action = .retry;
        }
        if (zg_gui.w.button(ui, .{ .label = "Ask agent (Ctrl+L)", .variant = .ghost }).clicked) b.action = .to_agent;
    }

    /// Announces start, done and failure once each.
    fn announce(b: *InlineEditBar, ui: *Ui) void {
        const st = b.state() orelse return;
        if (b.announced == st) return;
        b.announced = st;
        const tree = ui.window().a11y orelse return;
        switch (st) {
            .streaming => tree.announce("Generating edit", false),
            .ready => tree.announce("Edit ready", false),
            .answered => tree.announce("Answer ready", false),
            .failed => tree.announce("Inline edit failed", true),
            else => {},
        }
    }

    fn feedAnswer(b: *InlineEditBar) void {
        const s = b.session orelse return;
        if (!s.o.question) return;
        const ans = b.answer orelse blk: {
            b.answer = Answer.create(b.gpa) catch return;
            break :blk b.answer.?;
        };
        const out = s.output();
        if (out.len > ans.fed) {
            _ = ans.view.append(out[ans.fed..]) catch {};
            ans.fed = out.len;
        }
        if (s.state != .streaming and !ans.done) {
            ans.done = true;
            _ = ans.view.finish() catch {};
        }
    }

    pub fn run(b: *InlineEditBar, a: Action) !void {
        if (a != .to_agent) b.confirm_handoff = false;
        const st = b.state();
        switch (a) {
            .submit => {
                const text = std.mem.trim(u8, b.field.slice(), " \t\r\n");
                if (text.len == 0) return;
                try b.history.add(text);
                if (b.session) |s| if (!s.o.question and s.state == .ready) {
                    try s.followUp(text);
                    return b.field.setText("");
                };
                try b.begin(text, false);
                try b.field.setText("");
            },
            .ask => {
                const text = std.mem.trim(u8, b.field.slice(), " \t\r\n");
                if (text.len == 0) return;
                try b.history.add(text);
                try b.begin(text, true);
                try b.field.setText("");
            },
            .accept => if (st == .ready) {
                const r = try b.session.?.accept();
                if (r != .ok) {
                    b.note = "The file changed under the edit; review it in the queue.";
                    return;
                }
                b.close();
            },
            .reject => if (st == .ready) {
                try b.session.?.reject();
                b.close();
            },
            .escape => switch (st orelse .cancelled) {
                .streaming => try b.session.?.cancel("Cancelled."),
                .ready => {
                    try b.session.?.reject();
                    b.close();
                },
                else => {
                    if (b.session) |s| if (s.state == .answered) try s.cancel("");
                    b.close();
                },
            },
            .to_agent => {
                if (st == .ready and b.session.?.changeset != null and !b.confirm_handoff) {
                    b.confirm_handoff = true;
                    return;
                }
                const field = std.mem.trim(u8, b.field.slice(), " \t\r\n");
                const instruction = if (field.len > 0) field else b.sent.items;
                const sel = b.target.text[b.target.region[0]..b.target.region[1]];
                b.hooks.to_agent(b.hooks.ctx, sel, instruction);
                if (b.session) |s| switch (s.state) {
                    .ready => try s.reject(),
                    .streaming, .answered => try s.cancel("Handed off to the agent."),
                    else => {},
                };
                b.close();
            },
            .history_prev => {
                if (!b.history.recalls(b.field.slice())) return;
                if (try b.history.prev(b.field.slice())) |t| try b.field.setText(t);
            },
            .history_next => {
                if (!b.history.recalls(b.field.slice())) return;
                if (b.history.next()) |t| try b.field.setText(t);
            },
            .retry => if (st == .failed) {
                const text = try b.gpa.dupe(u8, b.sent.items);
                defer b.gpa.free(text);
                try b.begin(text, b.sent_question);
            },
            .apply_answer => if (st == .answered) {
                const s = b.session.?;
                const text = try std.fmt.allocPrint(b.gpa, "{s}\n\nYour answer:\n{s}\n\nDo it.", .{ b.sent.items, s.output() });
                defer b.gpa.free(text);
                try b.begin(text, false);
            },
        }
    }

    /// Starts a new session for `instruction`, replacing the current one.
    fn begin(b: *InlineEditBar, instruction: []const u8, question: bool) !void {
        b.dropSession();
        b.note = "";
        b.sent.clearRetainingCapacity();
        try b.sent.appendSlice(b.gpa, instruction);
        b.sent_question = question;
        const t = b.target;
        const s = InlineEditSession.start(b.gpa, b.q, b.applier, b.port, .{
            .path = t.path,
            .language = t.language,
            .text = t.text,
            .region = t.region,
            .instruction = b.sent.items,
            .question = question,
            .diagnostics = t.diagnostics,
            .rules = t.rules,
            .secrets = t.secrets,
            .ref = t.ref,
            .workspace = t.workspace,
        }) catch |e| {
            b.note = switch (e) {
                error.SecretSelection => "The selection looks like a secret; it was not sent.",
                else => @errorName(e),
            };
            return;
        };
        s.listener = .{ .ctx = b, .changed = onChanged };
        b.session = s;
    }

    fn dropSession(b: *InlineEditBar) void {
        if (b.answer) |a| a.destroy(b.gpa);
        b.answer = null;
        if (b.session) |s| s.deinit();
        b.session = null;
        b.announced = null;
    }

    fn close(b: *InlineEditBar) void {
        if (b.closed) return;
        b.closed = true;
        b.hooks.closed(b.hooks.ctx);
    }

    fn onChanged(ctx: *anyopaque, _: *InlineEditSession) void {
        const b: *InlineEditBar = @ptrCast(@alignCast(ctx));
        b.hooks.changed(b.hooks.ctx);
    }
};

/// A provider error name as the user reads it.
fn failText(reason: []const u8) []const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "RateLimited", "Rate limited by the provider. Retry in a moment." },
        .{ "Overloaded", "The model is overloaded. Retry in a moment." },
        .{ "Auth", "The provider refused the API key." },
        .{ "Network", "Network error." },
        .{ "Timeout", "The model timed out." },
        .{ "ContextOverflow", "The selection and context are too long for the model." },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], reason)) return m[1];
    return if (reason.len > 0) reason else "Failed.";
}

const testing = std.testing;

test "inline edit history: dedupe, cap, recall rules and persistence" {
    const gpa = testing.allocator;
    var h: History = .init(gpa);
    defer h.deinit();
    h.cap = 3;
    try h.add("  one ");
    try h.add("one");
    try h.add("");
    try h.add("two\nlines");
    try h.add("three \\ slash");
    try h.add("four");
    try testing.expectEqual(@as(usize, 3), h.items.items.len);
    try testing.expectEqualStrings("two\nlines", h.items.items[0]);

    // Recall starts only from an empty field, and keeps the draft.
    try testing.expect(!h.recalls("typing"));
    try testing.expect(h.recalls(""));
    try testing.expectEqualStrings("four", (try h.prev("")).?);
    try testing.expect(h.recalls("four"));
    try testing.expect(!h.recalls("four, edited"));
    try testing.expectEqualStrings("three \\ slash", (try h.prev("four")).?);
    try testing.expectEqualStrings("two\nlines", (try h.prev("x")).?);
    try testing.expect((try h.prev("x")) == null);
    try testing.expectEqualStrings("three \\ slash", h.next().?);
    try testing.expectEqualStrings("four", h.next().?);
    try testing.expectEqualStrings("", h.next().?);
    try testing.expect(h.next() == null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try h.save(testing.io, tmp.dir, ".zigguro/inline-edit-history");
    var back: History = .init(gpa);
    defer back.deinit();
    try back.load(testing.io, tmp.dir, ".zigguro/inline-edit-history");
    try testing.expectEqual(@as(usize, 3), back.items.items.len);
    for (h.items.items, back.items.items) |a, b| try testing.expectEqualStrings(a, b);
    var none: History = .init(gpa);
    defer none.deinit();
    try none.load(testing.io, tmp.dir, "missing");
    try testing.expectEqual(@as(usize, 0), none.items.items.len);
}

/// A synchronous model: the test streams chunks by hand.
const FakePort = struct {
    next: u64 = 1,
    sink: ?inline_edit.session.Sink = null,
    users: std.ArrayList([]u8) = .empty,
    cancelled: u32 = 0,

    fn port(f: *FakePort) inline_edit.ModelPort {
        return .{ .ctx = f, .start = start, .cancel = cancel };
    }

    fn deinit(f: *FakePort) void {
        for (f.users.items) |u| testing.allocator.free(u);
        f.users.deinit(testing.allocator);
    }

    fn start(ctx: *anyopaque, req: *const inline_edit.session.Request, sink: inline_edit.session.Sink) anyerror!u64 {
        const f: *FakePort = @ptrCast(@alignCast(ctx));
        try f.users.append(testing.allocator, try testing.allocator.dupe(u8, req.user));
        f.sink = sink;
        f.next += 1;
        return f.next - 1;
    }

    fn cancel(ctx: *anyopaque, _: u64) void {
        const f: *FakePort = @ptrCast(@alignCast(ctx));
        f.cancelled += 1;
    }

    fn stream(f: *FakePort, chunks: []const []const u8, end: ?anyerror, ends: bool) void {
        const s = f.sink.?;
        for (chunks) |c| s.chunk(s.ctx, f.next - 1, c);
        if (ends) s.end(s.ctx, f.next - 1, end);
    }

    fn lastUser(f: *const FakePort) []const u8 {
        return f.users.items[f.users.items.len - 1];
    }
};

const file = "function f() {\n  let x = 1;\n  return x;\n}\n";

const Fx = struct {
    blobs: zg_review.model.MemBlobs,
    disk: zg_review.apply.MemFiles,
    hist: zg_review.model.History,
    q: *zg_review.model.Queue,
    ap: zg_review.apply.Applier,
    fake: FakePort = .{},
    history: History,
    t: *zg_gui.testing.TestApp,
    bar: *InlineEditBar = undefined,
    closed: u32 = 0,
    changed: u32 = 0,
    handoff: std.ArrayList(u8) = .empty,

    pub fn build(fx: *Fx, ui: *Ui) void {
        if (fx.closed == 0) fx.bar.build(ui);
    }

    fn init(fx: *Fx) !void {
        const gpa = testing.allocator;
        fx.* = .{ .blobs = .init(gpa), .disk = .init(gpa), .hist = .init(gpa, null), .q = undefined, .ap = undefined, .history = .init(gpa), .t = undefined };
        fx.q = try zg_review.model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = fx.blobs.blobs() });
        fx.ap = .init(gpa, testing.io, fx.q, fx.disk.files(), &fx.hist);
        try fx.disk.put("a.ts", file, false);
        fx.bar = try InlineEditBar.create(gpa, fx.q, &fx.ap, fx.fake.port(), .{
            .path = "a.ts",
            .language = "typescript",
            .text = file,
            .region = .{ 15, 28 },
            .ref = .{ .session = 1 },
            .workspace = "/w",
        }, &fx.history, .{ .ctx = fx, .to_agent = toAgent, .closed = closedFn, .changed = changedFn });
        fx.bar.model_label = "test-model";
        fx.t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 600, .h = 300 }, .root = .of(fx) });
        _ = fx.t.settle();
        try fx.t.click(.{ .name = "Inline edit instruction" });
    }

    fn deinit(fx: *Fx) void {
        fx.t.deinit();
        fx.bar.destroy();
        fx.handoff.deinit(testing.allocator);
        fx.history.deinit();
        fx.fake.deinit();
        fx.q.deinit();
        fx.hist.deinit();
        fx.disk.deinit();
        fx.blobs.deinit();
    }

    fn toAgent(ctx: *anyopaque, sel: []const u8, instruction: []const u8) void {
        const fx: *Fx = @ptrCast(@alignCast(ctx));
        fx.handoff.print(testing.allocator, "{s}|{s}", .{ sel, instruction }) catch unreachable;
    }

    fn closedFn(ctx: *anyopaque) void {
        const fx: *Fx = @ptrCast(@alignCast(ctx));
        fx.closed += 1;
    }

    fn changedFn(ctx: *anyopaque) void {
        const fx: *Fx = @ptrCast(@alignCast(ctx));
        fx.changed += 1;
    }

    /// Rebuilds after the fake streamed.
    fn redraw(fx: *Fx) void {
        fx.t.win.markAllDirty();
        _ = fx.t.settle();
    }

    fn has(fx: *Fx, name: []const u8) bool {
        return fx.t.find(.{ .name_contains = name }) != null;
    }
};

test "inline edit bar: Enter edits, the stream shows, Ctrl+Enter accepts and closes" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try testing.expect(fx.t.find(.{ .role = .group, .name = "Inline edit" }) != null);
    try testing.expect(fx.has("test-model"));

    fx.t.typeText("make it const");
    fx.t.press(.enter, .{});
    _ = fx.t.settle();
    try testing.expectEqual(inline_edit.session.State.streaming, fx.bar.state().?);
    try testing.expect(std.mem.indexOf(u8, fx.fake.lastUser(), "Instruction: make it const") != null);
    try testing.expectEqualStrings("", fx.bar.field.slice());
    try testing.expectEqualStrings("make it const", fx.history.items.items[0]);

    fx.fake.stream(&.{"<rewrite>\n  const"}, null, false);
    try testing.expect(fx.changed > 0);
    fx.redraw();
    try testing.expect(fx.has("Generating"));
    try testing.expect(fx.has("Cancel (Esc)"));

    fx.fake.stream(&.{" x = 1;\n</rewrite>"}, null, true);
    fx.redraw();
    try testing.expect(fx.has("Ready: Ctrl+Enter accepts"));
    try testing.expect(fx.has("Accept (Ctrl+Enter)"));

    fx.t.press(.enter, .{ .ctrl = true });
    _ = fx.t.settle();
    try testing.expectEqual(@as(u32, 1), fx.closed);
    try testing.expectEqualStrings("function f() {\n  const x = 1;\n  return x;\n}\n", fx.disk.get("a.ts").?);
}

test "inline edit bar: follow-up, Escape cancels a stream then rejects, Retry after a failure" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    fx.t.typeText("make it const");
    fx.t.press(.enter, .{});
    _ = fx.t.settle();
    fx.fake.stream(&.{"<rewrite>\n  const x = 1;\n</rewrite>"}, null, true);
    fx.redraw();

    // A follow-up while an edit is ready rewrites it.
    fx.t.typeText("and name it y");
    fx.t.press(.enter, .{});
    _ = fx.t.settle();
    try testing.expectEqual(@as(usize, 2), fx.fake.users.items.len);
    try testing.expect(std.mem.indexOf(u8, fx.fake.lastUser(), "Instruction: and name it y") != null);

    // Escape while streaming cancels; the bar stays open.
    fx.t.press(.escape, .{});
    _ = fx.t.settle();
    try testing.expectEqual(inline_edit.session.State.cancelled, fx.bar.state().?);
    try testing.expectEqual(@as(u32, 1), fx.fake.cancelled);
    try testing.expectEqual(@as(u32, 0), fx.closed);

    // A provider failure offers Retry, which asks again.
    fx.t.typeText("try again");
    fx.t.press(.enter, .{});
    _ = fx.t.settle();
    fx.fake.stream(&.{}, error.RateLimited, true);
    fx.redraw();
    try testing.expect(fx.has("Rate limited"));
    try fx.t.click(.{ .name = "Retry" });
    _ = fx.t.settle();
    try testing.expectEqual(inline_edit.session.State.streaming, fx.bar.state().?);
    try testing.expect(std.mem.indexOf(u8, fx.fake.lastUser(), "Instruction: try again") != null);

    // Ready, then Escape rejects and closes.
    fx.fake.stream(&.{"<rewrite>\n  let y = 1;\n</rewrite>"}, null, true);
    fx.redraw();
    const cs = fx.bar.session.?.changeset.?;
    fx.t.press(.escape, .{});
    _ = fx.t.settle();
    try testing.expectEqual(@as(u32, 1), fx.closed);
    try testing.expectEqual(zg_review.model.State.rejected, fx.q.get(cs).?.state);
    try testing.expectEqualStrings(file, fx.disk.get("a.ts").?);
}

test "inline edit bar: Alt+Enter asks, the answer streams as Markdown, Apply as edit" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    fx.t.typeText("why let?");
    fx.t.press(.enter, .{ .alt = true });
    _ = fx.t.settle();
    try testing.expect(fx.bar.session.?.o.question);
    fx.fake.stream(&.{ "Because x is **never** ", "reassigned." }, null, true);
    fx.redraw();
    try testing.expect(fx.t.find(.{ .kind = "md_text", .name_contains = "never" }) != null);
    try fx.t.click(.{ .name = "Apply as edit" });
    _ = fx.t.settle();
    try testing.expect(!fx.bar.session.?.o.question);
    const user = fx.fake.lastUser();
    try testing.expect(std.mem.indexOf(u8, user, "why let?") != null);
    try testing.expect(std.mem.indexOf(u8, user, "reassigned.") != null);
    try testing.expect(std.mem.indexOf(u8, user, "Do it.") != null);
}

test "inline edit bar: Ctrl+L asks before discarding a pending edit, then hands off" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    fx.t.typeText("make it const");
    fx.t.press(.enter, .{});
    _ = fx.t.settle();
    fx.fake.stream(&.{"<rewrite>\n  const x = 1;\n</rewrite>"}, null, true);
    fx.redraw();
    const cs = fx.bar.session.?.changeset.?;

    fx.t.press(.key_l, .{ .ctrl = true });
    _ = fx.t.settle();
    try testing.expect(fx.has("Press Ctrl+L again"));
    try testing.expectEqual(@as(u32, 0), fx.closed);
    fx.t.press(.key_l, .{ .ctrl = true });
    _ = fx.t.settle();
    try testing.expectEqual(@as(u32, 1), fx.closed);
    try testing.expectEqualStrings("  let x = 1;\n|make it const", fx.handoff.items);
    try testing.expectEqual(zg_review.model.State.rejected, fx.q.get(cs).?.state);
}

test "inline edit bar: Up and Down recall instructions only from an empty field" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.history.add("first");
    try fx.history.add("second");
    fx.t.press(.arrow_up, .{});
    _ = fx.t.settle();
    try testing.expectEqualStrings("second", fx.bar.field.slice());
    fx.t.press(.arrow_up, .{});
    _ = fx.t.settle();
    try testing.expectEqualStrings("first", fx.bar.field.slice());
    fx.t.press(.arrow_down, .{});
    fx.t.press(.arrow_down, .{});
    _ = fx.t.settle();
    try testing.expectEqualStrings("", fx.bar.field.slice());
    fx.t.typeText("draft");
    fx.t.press(.arrow_up, .{});
    _ = fx.t.settle();
    try testing.expectEqualStrings("draft", fx.bar.field.slice());
}
