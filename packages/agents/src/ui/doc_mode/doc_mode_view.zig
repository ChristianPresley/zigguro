//! Document mode (E13.F04.S01.T02): the writing view of a Markdown file.
//! The outline on the left, the editor (the app's, through a slot) with
//! the agent's pending changes drawn as tracked changes, the selection
//! bar, and a status line with word counts and reading time.
//!
//! The view keeps the tracked changes in step with the person's edits and
//! the agent's streaming tool calls, and handles the review keys:
//! Ctrl+Enter accepts the change at the cursor, Esc rejects it, F8 and
//! Shift+F8 move between changes, Ctrl+Shift+Enter and Ctrl+Shift+Backspace
//! accept or reject everything in the current section, Ctrl+K opens the
//! selection bar. The editor's drawing and the dock layout (layout.zig)
//! belong to the app, which wires both through ports.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const outline_mod = @import("outline.zig");
const selection_bar = @import("selection_bar.zig");
const layout = @import("layout.zig");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const widget = zg_gui.core.widget;
const ev_mod = zg_gui.input.event;
const docs = zg_agents.docs;
const sections = docs.sections;
const shortcuts = docs.shortcuts;
const tracked_mod = docs.tracked;
const Hunk = docs.words.Hunk;

pub const OutlineView = outline_mod.OutlineView;
pub const SelectionBar = selection_bar.SelectionBar;

pub const commands = [_][]const u8{
    "docs.open",
    "docs.exit",
    "docs.acceptChange",
    "docs.rejectChange",
    "docs.acceptAllInSection",
    "docs.rejectAllInSection",
    "docs.nextChange",
    "docs.prevChange",
    "docs.selectionBar",
};

pub const Ports = struct {
    /// Puts the editor's cursor at a byte offset.
    navigate: struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, offset: u32) void },
    /// Applies an edit as the person's own (one undo step).
    edit: struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, m: sections.Move) void },
    /// Sends a prompt to the agent pane, scoped to `scope`.
    request: struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, prompt: []const u8, scope: sections.Range) void },
    /// Accepts or rejects a changeset's hunk (E12 review).
    decide: ?tracked_mod.DecidePort = null,
    /// Draws the editor in the centre.
    editor: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, ui: *Ui) void } = null,
    /// Speaks to screen readers.
    announce: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, text: []const u8) void } = null,
    /// The prompt library's overrides for shortcut templates.
    templates: ?shortcuts.TemplateLookup = null,
};

pub const DocMode = struct {
    gpa: Allocator,
    ports: Ports,
    session: ?*docs.DocSession,
    outline: OutlineView,
    bar: SelectionBar,
    tracked: tracked_mod.TrackedChanges,
    /// The document as last seen (owned by the outline's arena).
    text: []const u8 = "",
    version: u64 = 0,
    cursor: u32 = 0,
    /// The last thing announced (tests and logs).
    said: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator, ports: Ports, session: ?*docs.DocSession) !*DocMode {
        const m = try gpa.create(DocMode);
        errdefer gpa.destroy(m);
        m.* = .{
            .gpa = gpa,
            .ports = ports,
            .session = session,
            .outline = undefined,
            .bar = try SelectionBar.init(gpa),
            .tracked = .init(gpa, ports.decide),
        };
        m.outline = .init(gpa, .{
            .navigate = .{ .ctx = ports.navigate.ctx, .f = ports.navigate.f },
            .edit = .{ .ctx = ports.edit.ctx, .f = ports.edit.f },
            .pending = .{ .ctx = m, .f = pendingThunk },
        });
        return m;
    }

    pub fn deinit(m: *DocMode) void {
        m.outline.deinit();
        m.bar.deinit();
        m.tracked.deinit();
        m.said.deinit(m.gpa);
        m.gpa.destroy(m);
    }

    fn pendingThunk(ctx: *anyopaque, r: sections.Range) bool {
        const m: *DocMode = @ptrCast(@alignCast(ctx));
        return m.tracked.pendingIn(r);
    }

    // ---- the editor's side ----

    /// The document's text, version and cursor (after load or any edit).
    pub fn update(m: *DocMode, text: []const u8, version: u64, cursor: u32) !void {
        try m.outline.update(text, version, cursor);
        m.text = m.outline.text;
        m.version = version;
        m.cursor = @min(cursor, @as(u32, @intCast(m.text.len)));
    }

    /// The person replaced `old_len` bytes at `start` with `new_text`;
    /// `text` is the document after it.
    pub fn onUserEdit(m: *DocMode, start: u32, old_len: u32, new_text: []const u8, text: []const u8, version: u64) !void {
        if (m.session) |s| {
            try s.applyEdit(start, old_len, new_text, version);
            s.noteTyping(start + @as(u32, @intCast(new_text.len)));
        }
        const dropped = m.tracked.onUserEdit(start, old_len, @intCast(new_text.len));
        if (dropped > 0) m.say("{d} pending change{s} dropped by your edit", .{ dropped, if (dropped == 1) "" else "s" });
        try m.update(text, version, start + @as(u32, @intCast(new_text.len)));
    }

    pub fn onSelection(m: *DocMode, range: ?sections.Range, dragging: bool, now_ms: i64) void {
        m.bar.onSelection(range, dragging, now_ms);
    }

    /// Advances timers (the selection bar's debounce); whether to redraw.
    pub fn tick(m: *DocMode, now_ms: i64) bool {
        return m.bar.tick(now_ms);
    }

    // ---- the agent's side ----

    /// Part of a `doc_propose_edit`/`doc_insert` call's input arrived.
    pub fn onToolProgress(m: *DocMode, call: u64, tool: []const u8, partial_json: []const u8) !void {
        if (!isDocTool(tool)) return;
        try m.tracked.streamDelta(call, tool, partial_json, m.text);
    }

    /// The call finished: with its changeset's hunks, or null on failure.
    pub fn onToolDone(m: *DocMode, call: u64, changeset: ?u64, hunks: []const Hunk) !void {
        try m.tracked.streamEnd(call, if (changeset) |cs| .{ .changeset = cs, .hunks = hunks } else null);
        if (changeset != null and hunks.len > 0) m.say("{d} change{s} proposed", .{ hunks.len, if (hunks.len == 1) "" else "s" });
    }

    pub fn isDocTool(tool: []const u8) bool {
        return std.mem.eql(u8, tool, "doc_propose_edit") or std.mem.eql(u8, tool, "doc_insert");
    }

    // ---- commands ----

    pub fn run(m: *DocMode, command: []const u8) !bool {
        const eql = std.mem.eql;
        if (eql(u8, command, "docs.acceptChange")) return m.decideAtCursor(.accept);
        if (eql(u8, command, "docs.rejectChange")) return m.decideAtCursor(.reject);
        if (eql(u8, command, "docs.acceptAllInSection")) return m.decideSection(.accept);
        if (eql(u8, command, "docs.rejectAllInSection")) return m.decideSection(.reject);
        if (eql(u8, command, "docs.nextChange")) return m.goChange(m.tracked.next(m.cursor));
        if (eql(u8, command, "docs.prevChange")) return m.goChange(m.tracked.prev(m.cursor));
        if (eql(u8, command, "docs.selectionBar")) {
            m.bar.openFromKeyboard();
            return true;
        }
        return false;
    }

    fn decideAtCursor(m: *DocMode, d: tracked_mod.Decision) !bool {
        const i = m.tracked.at(m.cursor) orelse return false;
        if (!try m.tracked.decide(i, d)) return false;
        m.say("Change {s}", .{if (d == .accept) "accepted" else "rejected"});
        return true;
    }

    fn decideSection(m: *DocMode, d: tracked_mod.Decision) !bool {
        const i = sections.sectionAt(m.outline.all, m.cursor) orelse return false;
        const n = try m.tracked.decideIn(m.outline.all[i].range, d);
        if (n == 0) return false;
        m.say("{d} change{s} {s} in {s}", .{ n, if (n == 1) "" else "s", if (d == .accept) "accepted" else "rejected", m.outline.all[i].title });
        return true;
    }

    fn goChange(m: *DocMode, i: ?usize) !bool {
        const k = i orelse return false;
        const c = m.tracked.items.items[k];
        m.cursor = c.start;
        m.ports.navigate.f(m.ports.navigate.ctx, c.start);
        var scratch: std.heap.ArenaAllocator = .init(m.gpa);
        defer scratch.deinit();
        const d = try m.tracked.describe(scratch.allocator(), k, m.text);
        m.say("{s}", .{d});
        return true;
    }

    /// The picked shortcut or question, as a prompt for the agent pane.
    pub fn request(m: *DocMode, pick: selection_bar.Pick) !void {
        var scratch: std.heap.ArenaAllocator = .init(m.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const range = m.scope();
        const sel = m.text[range.start..range.end];
        const title = if (sections.sectionAt(m.outline.all, range.start)) |i| m.outline.all[i].title else "";
        const p = switch (pick) {
            .shortcut => |s| try shortcuts.prompt(a, s, sel, title, &.{}, m.ports.templates),
            .ask => |q| try shortcuts.expand(a, "{{question}}\n\nAbout this passage from \"{{section_title}}\":\n\n{{selection}}", &.{
                .{ .name = "question", .value = q },
                .{ .name = "section_title", .value = title },
                .{ .name = "selection", .value = sel },
            }),
        };
        m.ports.request.f(m.ports.request.ctx, p, range);
        m.bar.dismiss();
    }

    /// The selection, or (with none) the section at the cursor.
    fn scope(m: *const DocMode) sections.Range {
        const n: u32 = @intCast(m.text.len);
        if (m.bar.selection) |s| if (s.end > s.start and s.end <= n) return s;
        if (sections.sectionAt(m.outline.all, m.cursor)) |i| return m.outline.all[i].range;
        return .{ .start = 0, .end = n };
    }

    fn say(m: *DocMode, comptime fmt: []const u8, args: anytype) void {
        m.said.clearRetainingCapacity();
        m.said.print(m.gpa, fmt, args) catch return;
        if (m.ports.announce) |p| p.f(p.ctx, m.said.items);
    }

    /// The status line: words, reading time, and the change at the cursor.
    pub fn status(m: *const DocMode, a: Allocator) ![]const u8 {
        const total = sections.countWords(m.text);
        const sec: ?u32 = if (sections.sectionAt(m.outline.all, m.cursor)) |i| m.outline.all[i].words else null;
        const base = try layout.statusText(a, total, sec);
        const i = m.tracked.at(m.cursor) orelse return base;
        return std.fmt.allocPrint(a, "{s} · {s}", .{ base, try m.tracked.describe(a, i, m.text) });
    }

    fn onKey(m: *DocMode, k: ev_mod.KeyPress) bool {
        if (k.action == .release) return false;
        const cmd: ?[]const u8 = switch (k.key) {
            .enter, .numpad_enter => if (k.mods.ctrl and k.mods.shift) "docs.acceptAllInSection" else if (k.mods.ctrl) "docs.acceptChange" else null,
            .backspace => if (k.mods.ctrl and k.mods.shift) "docs.rejectAllInSection" else null,
            .escape => if (m.bar.visible) {
                m.bar.dismiss();
                return true;
            } else if (m.tracked.at(m.cursor) != null) "docs.rejectChange" else null,
            .f8 => if (k.mods.shift) "docs.prevChange" else "docs.nextChange",
            .key_k => if (k.mods.ctrl and !k.mods.shift) "docs.selectionBar" else null,
            else => null,
        };
        return m.run(cmd orelse return false) catch false;
    }

    pub fn build(m: *DocMode, ui: *Ui) void {
        _ = ui.begin(DocModeBox, .{ .m = m });
        ui.open(.{ .role = .group, .label = "Outline", .test_id = "doc-outline-pane", .style = .{ .dir = .column, .w = .{ .px = 240 } } });
        m.outline.build(ui);
        ui.close();
        ui.open(.{ .style = .{ .dir = .column, .grow = 1 } });
        if (m.bar.build(ui)) |pick| m.request(pick) catch {};
        ui.open(.{ .style = .{ .grow = 1 } });
        if (m.ports.editor) |e| e.f(e.ctx, ui);
        ui.close();
        const st = m.status(ui.arena()) catch "";
        ui.open(.{ .role = .status, .label = st, .test_id = "doc-status" });
        ui.text(st, .{ .color = .fg_muted, .wrap = false });
        ui.close();
        ui.close();
        ui.end(DocModeBox);
    }
};

const DocModeBox = struct {
    pub const name = "doc_mode";
    pub const Props = struct { m: *DocMode };

    pub fn style(_: *const Props, _: *const zg_gui.theme.Theme) zg_gui.Style {
        return .{ .dir = .row, .grow = 1 };
    }

    pub fn event(ec: *ev_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const ev_mod.InputEvent) bool {
        if (ec.phase == .capture) return false;
        const k = switch (ev.*) {
            .key => |k| k,
            else => return false,
        };
        if (!props.m.onKey(k)) return false;
        ec.respond(.{ .changed = true });
        return true;
    }

    pub fn a11y(_: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .group, .name = "Document" };
    }
};
