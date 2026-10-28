//! The note search dock panel (E08.F06.S03.T02): a query field parsed as
//! you type (an error underlines its span and dims the previous results),
//! ranked rows with title, path, tag pills, highlighted snippets and a
//! relevance bar, a live region with the count, the operator cheat sheet
//! (`?` or Ctrl+/), and saved searches.
//!
//! Keys while focus is inside: Up/Down move, Enter opens at the best
//! snippet, Ctrl+Enter opens to the side, Alt+Enter attaches the search
//! to the agent composer.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_notes = @import("zg_notes");
const zg_ai_proto = @import("zg_ai_proto");
const model_mod = @import("search_view_model.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Ui = zg_gui.Ui;
const controls = zg_gui.w.controls;
const scroll = zg_gui.w.scroll;
const TextBuffer = zg_gui.w.text_field.TextBuffer;
const widget = zg_gui.core.widget;
const ev_mod = zg_gui.input.event;
const OpKind = zg_notes.search.query.OpKind;

pub const NoteSearchViewModel = model_mod.NoteSearchViewModel;
pub const SavedSearches = model_mod.SavedSearches;

/// Takes the search as agent context (the composer's attach).
pub const AttachHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, ref: zg_ai_proto.ContextRef) void,
};

pub const Options = struct {
    attach: ?AttachHook = null,
    /// Shown under the field; `notes.saveSearch` adds to it.
    saved: ?*SavedSearches = null,
    /// Where `saved` is written (per-vault storage).
    storage: ?Io.Dir = null,
};

/// The commands the app registers with E15 (`key` is the default).
pub const Command = struct { id: []const u8, title: []const u8, key: ?[]const u8 = null };
pub const commands = [_]Command{
    .{ .id = "notes.search", .title = "Notes: Search Notes", .key = "ctrl+shift+n" },
    .{ .id = "notes.searchSelection", .title = "Notes: Search Notes for Selection" },
    .{ .id = "notes.saveSearch", .title = "Notes: Save Search" },
};

pub const row_h: f32 = 96;

pub const SearchView = struct {
    gpa: Allocator,
    m: *NoteSearchViewModel,
    o: Options,
    field: TextBuffer,
    show_help: bool = false,
    /// The count last announced (a change re-announces).
    announced: ?usize = null,
    seen_version: u32 = 0,
    err: ?[]const u8 = null,
    /// The query field's node at the last build (`focus`).
    field_node: zg_gui.core.NodeId = .none,

    pub fn init(gpa: Allocator, m: *NoteSearchViewModel, o: Options) !*SearchView {
        const v = try gpa.create(SearchView);
        errdefer gpa.destroy(v);
        v.* = .{ .gpa = gpa, .m = m, .o = o, .field = try .init(gpa, m.query.items) };
        return v;
    }

    pub fn deinit(v: *SearchView) void {
        v.field.deinit();
        v.gpa.destroy(v);
    }

    /// Replaces the query (`notes.search` with an argument, the tags
    /// pane, `notes.searchSelection`).
    pub fn setQuery(v: *SearchView, q: []const u8) !void {
        try v.field.setText(q);
        v.m.setQuery(q);
    }

    /// Saves the current query under `name` (default: the query).
    pub fn saveSearch(v: *SearchView, io: Io, name: ?[]const u8) !void {
        const s = v.o.saved orelse return;
        const q = v.m.query.items;
        if (q.len == 0) return;
        try s.put(name orelse q, q);
        if (v.o.storage) |d| try s.save(io, d);
    }

    pub fn attach(v: *SearchView) void {
        if (v.m.query.items.len == 0) return;
        if (v.o.attach) |h| h.f(h.ctx, v.m.attachToAgent());
    }

    pub fn build(v: *SearchView, ui: *Ui) void {
        noteSearchView(ui, v);
    }

    /// Moves keyboard focus to the query field (after a build in `w`).
    pub fn focus(v: *SearchView, w: *zg_gui.Window) void {
        if (!v.field_node.isNone() and w.store.valid(v.field_node)) w.setFocus(v.field_node, true);
    }

    fn onKey(v: *SearchView, k: ev_mod.KeyPress) bool {
        if (k.action == .release) return false;
        switch (k.key) {
            .arrow_down => v.m.moveSelection(1),
            .arrow_up => v.m.moveSelection(-1),
            .page_down => v.m.moveSelection(10),
            .page_up => v.m.moveSelection(-10),
            .enter, .numpad_enter => {
                if (k.mods.alt) v.attach() else v.m.openSelected(k.mods.ctrl);
            },
            .slash => {
                if (!k.mods.ctrl) return false;
                v.show_help = !v.show_help;
            },
            .escape => {
                if (!v.show_help) return false;
                v.show_help = false;
            },
            else => return false,
        }
        return true;
    }
};

/// Catches the view's keys before the field sees them.
const Keys = struct {
    pub const name = "note_search_keys";
    pub const Props = struct { v: *SearchView };

    pub fn style(_: *const Props, _: *const zg_gui.theme.Theme) zg_gui.Style {
        return .{ .dir = .column, .grow = 1 };
    }

    pub fn event(ec: *ev_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const ev_mod.InputEvent) bool {
        if (ec.phase != .capture) return false;
        const k = switch (ev.*) {
            .key => |k| k,
            else => return false,
        };
        if (!props.v.onKey(k)) return false;
        ec.respond(.{ .changed = true });
        return true;
    }

    pub fn a11y(_: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .group, .name = "Search notes" };
    }
};

/// The panel.
pub fn noteSearchView(ui: *Ui, v: *SearchView) void {
    const m = v.m;
    m.sync() catch |e| {
        v.err = @errorName(e);
    };
    if (m.version != v.seen_version) {
        v.seen_version = m.version;
        v.announced = null;
    }
    const th = ui.theme();
    _ = ui.begin(Keys, .{ .v = v });
    defer ui.end(Keys);
    ui.open(.{ .style = .{ .dir = .column, .gap = th.dim(.space_sm), .padding = .all(th.dim(.space_sm)), .grow = 1 }, .test_id = "note-search" });
    defer ui.close();

    ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_xs), .align_items = .center } });
    ui.open(.{ .style = .{ .grow = 1 } });
    const r = zg_gui.w.text_field.textField(ui, .{ .buffer = &v.field, .a11y_label = "Search notes", .placeholder = "Search notes (? for operators)", .invalid = m.err != null });
    v.field_node = ui.lastNode();
    ui.close();
    if (r.changed) m.setQuery(v.field.slice());
    if (controls.button(ui, .{ .label = "?" }).clicked) v.show_help = !v.show_help;
    if (v.o.saved != null and controls.button(ui, .{ .label = "Save search" }).clicked) {
        v.saveSearch(m.o.io, null) catch |e| {
            v.err = @errorName(e);
        };
    }
    ui.close();

    if (v.err) |e| ui.textf("Error: {s}", .{e}, .{ .color = .danger });
    if (m.parseError()) |pe| errorLine(ui, m.query.items, pe);
    if (v.show_help) operatorHelp(ui);
    savedList(ui, v);
    liveRegion(ui, v);
    if (m.failure()) |f| ui.textf("Search failed: {s}", .{f}, .{ .color = .danger });

    const rows = m.rows();
    if (rows.len == 0) {
        if (m.query.items.len > 0 and !m.running and m.err == null) ui.text("No matching notes.", .{ .color = .fg_muted });
        return;
    }
    const vis = scroll.virtualList(ui, .{ .count = rows.len, .row_h = row_h, .test_id = "note-search-results" }, v, resultRow);
    _ = vis;
}

/// "37 notes", announced when it changes.
fn liveRegion(ui: *Ui, v: *SearchView) void {
    const m = v.m;
    const n = m.rows().len;
    const label = if (m.running and m.stale())
        "Searching\u{2026}"
    else
        std.fmt.allocPrint(ui.arena(), "{d} note{s}", .{ n, if (n == 1) "" else "s" }) catch "";
    ui.open(.{ .role = .status, .label = label, .test_id = "note-search-count" });
    ui.text(label, .{ .color = .fg_muted, .wrap = false });
    ui.close();
    if (m.query.items.len == 0 or m.running) return;
    if (v.announced == n) return;
    v.announced = n;
    if (ui.window().a11y) |t| t.announce(label, false);
}

/// The query with the error span in the danger colour, and the message.
fn errorLine(ui: *Ui, q: []const u8, pe: model_mod.ParseError) void {
    const a = @min(pe.span[0], q.len);
    const b = @min(@max(pe.span[1], pe.span[0]), q.len);
    const label = std.fmt.allocPrint(ui.arena(), "Query error: {s}", .{pe.msg}) catch "Query error";
    ui.open(.{ .role = .status, .label = label, .test_id = "note-search-error", .style = .{ .dir = .column, .gap = 2 } });
    defer ui.close();
    ui.open(.{ .style = .{ .dir = .row, .wrap = true } });
    if (a > 0) ui.text(q[0..a], .{ .wrap = false });
    // An empty span (end of input) still shows a mark.
    ui.open(.{ .test_id = "note-search-error-span", .style = .{ .border_w = 1, .border = .{ .token = .danger } } });
    ui.text(if (b > a) q[a..b] else " ", .{ .color = .danger, .wrap = false });
    ui.close();
    if (b < q.len) ui.text(q[b..], .{ .wrap = false });
    ui.close();
    ui.text(pe.msg, .{ .color = .danger });
}

/// One operator-help entry.
pub const HelpEntry = struct { syntax: []const u8, example: []const u8, what: []const u8 };

/// The `op:` operators' help, one per `OpKind` (an exhaustive switch, so
/// a new operator does not compile without its entry).
pub fn opHelp(k: OpKind) HelpEntry {
    return switch (k) {
        .file => .{ .syntax = "file:", .example = "file:meeting", .what = "Matches the file name" },
        .path => .{ .syntax = "path:", .example = "path:projects/2024", .what = "Matches the path" },
        .content => .{ .syntax = "content:", .example = "content:\"happy cat\"", .what = "Matches the note text only" },
        .tag => .{ .syntax = "tag:", .example = "tag:#work", .what = "Notes with the tag (and its children)" },
        .line => .{ .syntax = "line:", .example = "line:(mix flour)", .what = "Every term on the same line" },
        .block => .{ .syntax = "block:", .example = "block:(dog cat)", .what = "Every term in the same block" },
        .section => .{ .syntax = "section:", .example = "section:(dog cat)", .what = "Every term under the same heading" },
        .task => .{ .syntax = "task:", .example = "task:call", .what = "Matches tasks" },
        .task_todo => .{ .syntax = "task-todo:", .example = "task-todo:call", .what = "Matches open tasks" },
        .task_done => .{ .syntax = "task-done:", .example = "task-done:call", .what = "Matches completed tasks" },
        .match_case => .{ .syntax = "match-case:", .example = "match-case:HappyCat", .what = "Case-sensitive match" },
        .ignore_case => .{ .syntax = "ignore-case:", .example = "ignore-case:ikea", .what = "Case-insensitive match" },
    };
}

/// The syntax that is not an `op:`.
pub const syntax_help = [_]HelpEntry{
    .{ .syntax = "a b", .example = "meeting work", .what = "Both terms (AND)" },
    .{ .syntax = "OR", .example = "meeting OR work", .what = "Either term" },
    .{ .syntax = "-", .example = "meeting -work", .what = "Excludes a term" },
    .{ .syntax = "\"...\"", .example = "\"star wars\"", .what = "An exact phrase" },
    .{ .syntax = "( )", .example = "(a OR b) c", .what = "Groups terms" },
    .{ .syntax = "/regex/", .example = "/\\d{4}-\\d{2}/", .what = "A regular expression" },
    .{ .syntax = "[prop]", .example = "[aliases]", .what = "Notes with the property" },
    .{ .syntax = "[prop:value]", .example = "[status:done]", .what = "A property value (also :null, :<5, :>2024-01-01)" },
};

fn operatorHelp(ui: *Ui) void {
    const th = ui.theme();
    ui.open(.{ .role = .list, .label = "Search operators", .test_id = "note-search-help", .style = .{ .dir = .column, .gap = 2, .padding = .all(th.dim(.space_sm)), .bg = .{ .token = .bg_elevated } } });
    defer ui.close();
    inline for (std.meta.fields(OpKind)) |f| helpRow(ui, opHelp(@enumFromInt(f.value)));
    for (syntax_help) |h| helpRow(ui, h);
}

fn helpRow(ui: *Ui, h: HelpEntry) void {
    const th = ui.theme();
    ui.id(h.syntax);
    ui.open(.{ .role = .listitem, .label = h.syntax, .style = .{ .dir = .row, .gap = th.dim(.space_sm) } });
    defer ui.close();
    ui.open(.{ .style = .{ .w = .{ .px = 96 }, .shrink = 0 } });
    ui.text(h.syntax, .{ .wrap = false, .style = .{ .weight = 700 } });
    ui.close();
    ui.open(.{ .style = .{ .w = .{ .px = 150 }, .shrink = 0 } });
    ui.text(h.example, .{ .color = .fg_link, .wrap = false });
    ui.close();
    ui.text(h.what, .{ .color = .fg_muted });
}

fn savedList(ui: *Ui, v: *SearchView) void {
    const s = v.o.saved orelse return;
    if (s.items.items.len == 0) return;
    const th = ui.theme();
    ui.open(.{ .role = .group, .label = "Saved searches", .style = .{ .dir = .row, .wrap = true, .gap = th.dim(.space_xs) } });
    defer ui.close();
    for (s.items.items, 0..) |it, i| {
        ui.id(@as(u64, i));
        if (controls.button(ui, .{ .label = it.name }).clicked) {
            v.setQuery(it.query) catch |e| {
                v.err = @errorName(e);
            };
        }
    }
}

fn resultRow(v: *SearchView, ui: *Ui, i: usize) void {
    const m = v.m;
    const row = m.rows()[i];
    const th = ui.theme();
    const dim = m.stale();
    const sel = i == m.selected;
    ui.id(@as(u64, @bitCast(row.note)));
    const label = std.fmt.allocPrint(ui.arena(), "{s} ({s})", .{ row.title, row.path }) catch row.title;
    ui.open(.{ .role = .listitem, .label = label, .hit = true, .test_id = if (sel) "note-search-selected" else "", .style = .{
        .dir = .column,
        .gap = 2,
        .grow = 1,
        .padding = .all(th.dim(.space_xs)),
        .bg = if (sel) .{ .token = .selection_bg } else .none,
    } });
    defer ui.close();
    const resp = ui.response();
    if (resp.clicked) m.select(i);
    if (resp.double_clicked) {
        m.select(i);
        m.openSelected(false);
    }
    const fg: zg_gui.theme.Token = if (dim) .fg_muted else .fg;
    // The relevance bar, normalised to the top score.
    ui.open(.{ .style = .{ .h = .{ .px = 4 }, .w = .{ .pct = row.relevance * 100 }, .shrink = 0, .bg = .{ .token = if (dim) .border else .accent } } });
    ui.close();
    ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center } });
    ui.text(row.title, .{ .color = fg, .wrap = false, .style = .{ .weight = 700 } });
    ui.text(row.path, .{ .color = .fg_muted, .wrap = false });
    for (row.tags) |t| {
        ui.id(t);
        ui.open(.{ .role = .none, .style = .{ .padding = .xy(4, 0), .bg = .{ .token = .badge_bg } } });
        ui.textf("#{s}", .{t}, .{ .color = .badge_fg, .wrap = false });
        ui.close();
    }
    ui.close();
    for (row.snippets, 0..) |s, j| {
        ui.id(@as(u64, j));
        snippetLine(ui, s, dim);
    }
}

fn snippetLine(ui: *Ui, s: model_mod.SnippetLine, dim: bool) void {
    const label = std.fmt.allocPrint(ui.arena(), "Line {d}: {s}", .{ s.line + 1, s.text }) catch s.text;
    ui.open(.{ .role = .none, .label = label, .style = .{ .dir = .row, .wrap = false } });
    defer ui.close();
    const base: zg_gui.theme.Token = .fg_muted;
    const hit: zg_gui.theme.Token = if (dim) .fg_muted else .fg_link;
    var at: usize = 0;
    for (s.highlights) |h| {
        if (h[0] < at or h[1] > s.text.len) continue;
        if (h[0] > at) ui.text(s.text[at..h[0]], .{ .color = base, .wrap = false });
        if (h[1] > h[0]) ui.text(s.text[h[0]..h[1]], .{ .color = hit, .wrap = false, .style = .{ .weight = 700 } });
        at = h[1];
    }
    if (at < s.text.len) ui.text(s.text[at..], .{ .color = base, .wrap = false });
}
