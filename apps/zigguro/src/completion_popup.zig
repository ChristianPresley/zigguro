//! The completion popup (E07.F03.S01.T03): the completion engine's list
//! under the caret line (above it when there is no room), its text
//! column aligned with the word being completed, at most `max_rows` rows
//! (a virtual list), each with a kind badge, the label with the matched
//! characters bold, the label detail dimmed after it and the description
//! on the right; deprecated items are struck through. The selected
//! item's documentation shows beside the list (below it when the editor
//! is narrow): its detail as a code block, then its Markdown.
//!
//! The popup never takes focus: the editor keeps the keys and `CodeIntel`
//! moves the selection, accepts and closes. A click on a row picks it
//! (`on_pick`).

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_codeintel = @import("zg_codeintel");

const Allocator = std.mem.Allocator;
const Window = zg_gui.Window;
const Ui = zg_gui.Ui;
const Rect = zg_gui.core.Rect;
const Size = zg_gui.core.Size;
const NodeId = zg_gui.core.NodeId;
const OverlayId = zg_gui.w.overlay.OverlayId;
const PaintCx = zg_gui.paint.PaintCx;
const EventCx = zg_gui.input.EventCx;
const InputEvent = zg_gui.input.InputEvent;
const MeasureCx = zg_gui.layout.measure.MeasureCx;
const Style = zg_gui.layout.Style;
const Theme = zg_gui.theme.Theme;
const TextStyle = zg_gui.paint.text.TextStyle;
const widget = zg_gui.core.widget;
const markdown = zg_gui.markdown;
const scroll = zg_gui.w.scroll;
const rank = zg_codeintel.features.completion_rank;
const HoverService = zg_codeintel.features.HoverService;
const Kind = rank.Kind;

pub const max_rows = 12;
pub const row_h: f32 = 22;
const docs_w: f32 = 320;
const list_w: f32 = 380;
/// Below this editor width the docs go under the list.
const narrow_w: f32 = 720;

/// What the popup shows (the engine's session, borrowed until the next
/// `update` or `hide`).
pub const Model = struct {
    items: []const rank.Item = &.{},
    ranked: []const rank.Ranked = &.{},
    ranker: ?*const rank.Ranker = null,
    selected: ?u32 = null,

    fn item(m: *const Model, i: usize) *const rank.Item {
        return &m.items[m.ranked[i].item];
    }
};

/// Told when a row is clicked.
pub const PickHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, pos: u32) void,
};

pub const CompletionPopup = struct {
    gpa: Allocator,
    win: ?*Window = null,
    overlay: OverlayId = .none,
    model: Model = .{},
    /// The editor's width (the popup takes at most 60% of it).
    editor_w: f32 = 1000,
    show_docs: bool = true,
    /// Code fences in the docs are tagged with this language.
    lang: []const u8 = "",
    /// Highlights code fences (the editor's highlighter, set by the
    /// workbench).
    highlighter: @FieldType(markdown.MdViewProps, "highlighter") = null,
    on_pick: ?PickHook = null,
    list: NodeId = .none,
    /// Matched positions of the rows built (index: row - `first`).
    matches: std.ArrayList([rank.max_pattern]u16) = .empty,
    match_lens: std.ArrayList(u8) = .empty,
    first: usize = 0,
    md: ?*Md = null,
    /// The item and state the docs were made for.
    docs_for: ?struct { item: *const rank.Item, resolved: bool } = null,
    docs_text: std.ArrayList(u8) = .empty,
    /// The selected row's accessible name ("label, kind, detail").
    announce: std.ArrayList(u8) = .empty,
    scroll_to: ?u32 = null,

    const Md = struct {
        doc: markdown.Doc,
        view: markdown.MdViewState,
    };

    pub fn init(gpa: Allocator) CompletionPopup {
        return .{ .gpa = gpa };
    }

    /// Not `deinit`: the overlay's view calls that when it closes.
    pub fn release(p: *CompletionPopup) void {
        p.hide();
        p.freeMd();
        p.matches.deinit(p.gpa);
        p.match_lens.deinit(p.gpa);
        p.docs_text.deinit(p.gpa);
        p.announce.deinit(p.gpa);
    }

    fn freeMd(p: *CompletionPopup) void {
        const m = p.md orelse return;
        m.view.deinit();
        m.doc.deinit();
        p.gpa.destroy(m);
        p.md = null;
        p.docs_for = null;
    }

    /// Opens the popup at `anchor` (the word being completed on the caret
    /// line, window coordinates) or moves it there, showing `m`.
    pub fn show(p: *CompletionPopup, m: Model, anchor: Rect) !void {
        const w = p.win orelse return;
        p.update(m);
        if (p.isOpen()) {
            if (w.overlays.indexOf(p.overlay)) |i| w.overlays.items.items[i].opts.anchor = .{ .rect = anchor };
            w.markAllDirty();
            return;
        }
        p.overlay = try w.openOverlay(.of(p), .{
            .layer = .popover,
            .anchor = .{ .rect = anchor },
            .placement = .{ .side = .below, .alignment = .start, .gap = 0 },
            .light_dismiss = true,
            .consume_outside_click = false,
            .take_focus = false,
            .restore_focus = false,
            .role = .list,
            .label = "Suggestions",
            .test_id = "completion",
            .on_close = .{ .ctx = p, .f = onClose },
        });
        w.markAllDirty();
    }

    /// New list or selection; the selected row is scrolled into view.
    pub fn update(p: *CompletionPopup, m: Model) void {
        const sel_changed = m.selected != p.model.selected;
        p.model = m;
        if (sel_changed) p.scroll_to = m.selected;
        p.refreshAnnounce();
        if (p.win) |w| w.markAllDirty();
    }

    pub fn hide(p: *CompletionPopup) void {
        p.model = .{};
        p.docs_for = null;
        const w = p.win orelse return;
        if (p.overlay == .none) return;
        const id = p.overlay;
        p.overlay = .none;
        w.closeOverlay(id);
    }

    pub fn isOpen(p: *const CompletionPopup) bool {
        const w = p.win orelse return false;
        return p.overlay != .none and w.isOverlayOpen(p.overlay);
    }

    /// Ctrl+Space while open.
    pub fn toggleDocs(p: *CompletionPopup) void {
        p.show_docs = !p.show_docs;
        if (p.win) |w| w.markAllDirty();
    }

    fn onClose(ctx: *anyopaque, id: OverlayId) void {
        const p: *CompletionPopup = @ptrCast(@alignCast(ctx));
        if (p.overlay == id) p.overlay = .none;
    }

    fn refreshAnnounce(p: *CompletionPopup) void {
        p.announce.clearRetainingCapacity();
        const sel = p.model.selected orelse return;
        if (sel >= p.model.ranked.len) return;
        const it = p.model.item(sel);
        p.announce.print(p.gpa, "{s}", .{it.label}) catch return;
        if (it.kind) |k| p.announce.print(p.gpa, ", {s}", .{kindName(k)}) catch {};
        if (it.detail) |d| p.announce.print(p.gpa, ", {s}", .{d}) catch {};
    }

    fn width(p: *const CompletionPopup) f32 {
        return @min(list_w, @max(160, p.editor_w * 0.6));
    }

    pub fn build(p: *CompletionPopup, ui: *Ui) void {
        const n = p.model.ranked.len;
        if (n == 0) return;
        const narrow = p.editor_w < narrow_w;
        ui.open(.{ .style = .{ .dir = if (narrow) .column else .row, .align_items = .start } });
        defer ui.close();
        const h = @as(f32, @floatFromInt(@min(n, max_rows))) * row_h;
        const opts: scroll.ListOptions = .{
            .count = n,
            .row_h = row_h,
            .style = .{ .w = .{ .px = p.width() }, .h = .{ .px = h }, .shrink = 0 },
            .test_id = "completion-list",
        };
        const vis = scroll.virtualList(ui, opts, p, row);
        p.list = vis.node;
        if (p.scroll_to) |i| {
            p.scroll_to = null;
            scroll.scrollToRow(ui.window(), vis.node, opts, i);
        }
        if (p.show_docs) p.buildDocs(ui, narrow);
    }

    fn row(p: *CompletionPopup, ui: *Ui, i: usize) void {
        const m = &p.model;
        const it = m.item(i);
        var hl: []const u16 = &.{};
        if (m.ranker) |r| {
            if (i < p.first or p.matches.items.len == 0 or i == 0) {
                p.first = i;
                p.matches.clearRetainingCapacity();
                p.match_lens.clearRetainingCapacity();
            }
            const k = i - p.first;
            if (k == p.matches.items.len) {
                p.matches.append(p.gpa, undefined) catch {};
                p.match_lens.append(p.gpa, 0) catch {};
            }
            if (k < p.matches.items.len) {
                p.match_lens.items[k] = r.matches(it, &p.matches.items[k]);
                hl = p.matches.items[k][0..p.match_lens.items[k]];
            }
        }
        const selected = m.selected != null and m.selected.? == i;
        _ = ui.leaf(Row, .{
            .p = p,
            .pos = @intCast(i),
            .label = it.label,
            .detail = it.label_detail orelse "",
            .desc = it.label_desc orelse (if (it.label_detail == null) it.detail orelse "" else ""),
            .kind = it.kind,
            .deprecated = it.deprecated,
            .matches = hl,
            .matched_text = it.filter_text,
            .selected = selected,
            .name = if (selected) p.announce.items else it.label,
        });
    }

    fn buildDocs(p: *CompletionPopup, ui: *Ui, narrow: bool) void {
        const sel = p.model.selected orelse return;
        if (sel >= p.model.ranked.len) return;
        const it = p.model.item(sel);
        if (it.detail == null and it.doc == null) return;
        if (p.docs_for == null or p.docs_for.?.item != it or p.docs_for.?.resolved != it.resolved) p.makeDocs(it) catch return;
        const m = p.md orelse return;
        const w: f32 = if (narrow) p.width() else docs_w;
        ui.open(.{ .style = .{ .dir = .column, .w = .{ .px = w }, .max_h = max_rows * row_h, .scroll_y = true, .padding = .all(6) }, .test_id = "completion-docs" });
        defer ui.close();
        markdown.view(ui, &m.view, .{ .compact = true, .virtualize = false, .max_width = w - 12, .highlighter = p.highlighter, .test_id = "completion-docs-text" });
    }

    fn makeDocs(p: *CompletionPopup, it: *const rank.Item) !void {
        p.freeMd();
        p.docs_text.clearRetainingCapacity();
        if (it.detail) |d| try p.docs_text.print(p.gpa, "```{s}\n{s}\n```\n\n", .{ p.lang, d });
        if (it.doc) |d| switch (d) {
            .markdown => |md| try HoverService.sanitize(p.gpa, md, &p.docs_text),
            .plain => |t| try HoverService.escapeInto(p.gpa, t, &p.docs_text),
        };
        const m = try p.gpa.create(Md);
        errdefer p.gpa.destroy(m);
        m.* = .{ .doc = markdown.stream.init(p.gpa, .{}), .view = undefined };
        m.view = .init(p.gpa, &m.doc);
        p.md = m;
        _ = m.view.append(p.docs_text.items) catch {};
        _ = m.view.finish() catch {};
        p.docs_for = .{ .item = it, .resolved = it.resolved };
    }

    fn picked(p: *CompletionPopup, pos: u32) void {
        if (p.on_pick) |h| h.f(h.ctx, pos);
    }
};

/// A short word for a completion kind (badges and announcements).
pub fn kindName(k: Kind) []const u8 {
    return switch (k) {
        .Text => "text",
        .Method => "method",
        .Function => "function",
        .Constructor => "constructor",
        .Field => "field",
        .Variable => "variable",
        .Class => "class",
        .Interface => "interface",
        .Module => "module",
        .Property => "property",
        .Unit => "unit",
        .Value => "value",
        .Enum => "enum",
        .Keyword => "keyword",
        .Snippet => "snippet",
        .Color => "color",
        .File => "file",
        .Reference => "reference",
        .Folder => "folder",
        .EnumMember => "enum member",
        .Constant => "constant",
        .Struct => "struct",
        .Event => "event",
        .Operator => "operator",
        .TypeParameter => "type parameter",
        _ => "item",
    };
}

/// The badge letter and colour token of a kind.
fn badge(k: ?Kind) struct { []const u8, zg_gui.theme.Token } {
    const kk = k orelse return .{ "·", .fg_muted };
    return switch (kk) {
        .Method, .Function, .Constructor => .{ "f", .accent },
        .Field, .Variable, .Property, .Reference => .{ "v", .info },
        .Class, .Interface, .Struct, .Enum, .TypeParameter, .Module => .{ "T", .warning },
        .Constant, .EnumMember, .Value, .Unit, .Color => .{ "c", .info },
        .Keyword, .Operator => .{ "k", .fg_muted },
        .Snippet => .{ "s", .success },
        .File, .Folder => .{ "/", .fg_muted },
        else => .{ "a", .fg_muted },
    };
}

/// One row of the list.
const Row = struct {
    pub const name = "completion_item";

    pub const Props = struct {
        p: *CompletionPopup,
        pos: u32,
        label: []const u8,
        detail: []const u8 = "",
        desc: []const u8 = "",
        kind: ?Kind = null,
        deprecated: bool = false,
        /// Byte positions of matched characters in `matched_text`.
        matches: []const u16 = &.{},
        matched_text: []const u8 = "",
        selected: bool = false,
        name: []const u8 = "",
    };

    pub fn style(_: *const Props, _: *const Theme) Style {
        return .{ .grow = 1, .align_self = .stretch };
    }

    pub fn measure(_: *MeasureCx, _: *const Props, _: *widget.NoState, _: ?f32) Size {
        return .{ .w = 0, .h = 0 };
    }

    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        const th = pc.theme;
        const st: TextStyle = .{ .size = th.dim(.font_size) };
        const small: TextStyle = .{ .size = th.dim(.font_size_sm) };
        const m = pc.text_sys.metrics(st);
        const baseline = r.y + (r.h - m.line_h) / 2 + (m.line_h - (m.ascent + m.descent)) / 2 + m.ascent;
        if (props.selected) pc.fill(r, .selection_bg, pc.dim(.radius_sm));
        var x = r.x + 4;
        // The kind badge.
        const letter, const tok = badge(props.kind);
        const bw: f32 = 14;
        const box: Rect = .{ .x = x, .y = r.y + (r.h - bw) / 2, .w = bw, .h = bw };
        pc.border(box, 1, pc.color(tok), 3);
        pc.textLine(letter, small, pc.color(tok), .{ .x = box.x + (bw - pc.text_sys.width(small, letter)) / 2, .y = box.bottom() - 3 });
        x += bw + 6;
        const fg = pc.color(if (props.deprecated) .fg_muted else .fg);
        const hl_color = pc.color(.quick_input_highlight);
        const bold: TextStyle = .{ .size = st.size, .weight = 700 };
        const label_x = x;
        // Matched characters bold (when the filter text is the label).
        const same = std.mem.eql(u8, props.matched_text, props.label);
        var i: usize = 0;
        var mi: usize = 0;
        while (i < props.label.len) {
            const is_m = same and mi < props.matches.len and props.matches[mi] == i;
            var j = i + 1;
            if (is_m) {
                mi += 1;
                while (j < props.label.len and mi < props.matches.len and props.matches[mi] == j) : (j += 1) mi += 1;
            } else {
                while (j < props.label.len and !(same and mi < props.matches.len and props.matches[mi] == j)) j += 1;
            }
            const seg = props.label[i..j];
            const s = if (is_m) bold else st;
            pc.textLine(seg, s, if (is_m) hl_color else fg, .{ .x = x, .y = baseline });
            x += pc.text_sys.width(s, seg);
            i = j;
        }
        if (props.deprecated) pc.fill(.{ .x = label_x, .y = baseline - m.ascent / 3, .w = x - label_x, .h = 1 }, .fg_muted, 0);
        const muted = pc.color(.fg_muted);
        if (props.detail.len > 0) {
            pc.textLine(props.detail, st, muted, .{ .x = x, .y = baseline });
            x += pc.text_sys.width(st, props.detail);
        }
        if (props.desc.len > 0) {
            const dw = pc.text_sys.width(small, props.desc);
            const dx = @max(x + 12, r.right() - 6 - dw);
            if (dx + 8 < r.right()) pc.textLine(props.desc, small, muted, .{ .x = dx, .y = baseline });
        }
    }

    pub fn event(_: *EventCx, props: *const Props, _: *widget.NoState, ev: *const InputEvent) bool {
        switch (ev.*) {
            .pointer_up => |pu| if (pu.button == .left) {
                props.p.picked(props.pos);
                return true;
            },
            .pointer_down => return true,
            else => {},
        }
        return false;
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .listitem, .name = props.name, .selected = props.selected };
    }
};

fn testItem(label: []const u8, kind: ?Kind) rank.Item {
    return .{ .label = label, .kind = kind, .sort_text = label, .sort_key = rank.sortKey(label), .filter_text = label, .edit = .{ .insert_text = label } };
}

test "completion popup: below the line, aligned with the word; above without room; rows, selection, docs, clicks" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const Page = struct {
        pub fn build(_: *@This(), ui: *Ui) void {
            ui.id("page");
            ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 } }, .focusable = true });
            ui.close();
        }
    };
    var page: Page = .{};
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .root = .of(&page), .size = .{ .w = 900, .h = 500 } });
    defer t.deinit();

    var items: [30]rank.Item = undefined;
    var names: [30][8]u8 = undefined;
    for (&items, 0..) |*it, i| it.* = testItem(std.fmt.bufPrint(&names[i], "item{d:0>2}", .{i}) catch unreachable, if (i % 2 == 0) .Function else .Variable);
    items[1].detail = "const item01: u32";
    items[1].doc = .{ .markdown = "The *first* one." };
    items[2].deprecated = true;
    var r = try rank.Ranker.init(gpa);
    defer r.deinit();
    try r.refilter(&items, "it", null);

    var p: CompletionPopup = .init(gpa);
    defer p.release();
    p.win = t.win;
    p.lang = "zig";
    const Pick = struct {
        got: ?u32 = null,
        fn f(ctx: *anyopaque, pos: u32) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.got = pos;
        }
    };
    var pick: Pick = .{};
    p.on_pick = .{ .ctx = &pick, .f = Pick.f };
    // The docs' code goes through the editor's highlighter.
    const Hl = struct {
        lang: [8]u8 = undefined,
        lang_len: usize = 0,
        n: u32 = 0,
        fn f(ctx: *anyopaque, _: std.mem.Allocator, lang: []const u8, _: []const u8, _: *std.ArrayList(markdown.code_view.Span)) std.mem.Allocator.Error!void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.n += 1;
            s.lang_len = @min(lang.len, s.lang.len);
            @memcpy(s.lang[0..s.lang_len], lang[0..s.lang_len]);
        }
    };
    var hl: Hl = .{};
    p.highlighter = .{ .ptr = &hl, .highlight = Hl.f };
    const model: Model = .{ .items = &items, .ranked = r.ranked.items, .ranker = &r, .selected = 0 };
    try p.show(model, .{ .x = 100, .y = 100, .w = 20, .h = 16 });
    // It paints in the first frame after the results.
    const fs = t.frame();
    try testing.expect(fs.presented and fs.nodes_painted > 0);
    try testing.expect(p.isOpen());
    const box = try t.rectOf(.{ .test_id = "completion-list" });
    try testing.expect(box.y >= 116);
    try testing.expect(@abs(box.x - 100) < 16);
    // At most 12 rows tall; the window keeps focus in the page.
    try testing.expect(box.h <= max_rows * row_h + 1);

    // The selected row's docs: detail as code, then the Markdown.
    p.update(.{ .items = &items, .ranked = r.ranked.items, .ranker = &r, .selected = 1 });
    _ = t.settle();
    const docs = try t.rectOf(.{ .test_id = "completion-docs" });
    try testing.expect(docs.x >= box.x + box.w - 1);
    try testing.expectEqualStrings("item01, variable, const item01: u32", p.announce.items);
    try testing.expect(hl.n > 0);
    try testing.expectEqualStrings("zig", hl.lang[0..hl.lang_len]);
    p.toggleDocs();
    _ = t.settle();
    try testing.expectError(error.NotFound, t.rectOf(.{ .test_id = "completion-docs" }));

    // A selection far down scrolls the list.
    p.update(.{ .items = &items, .ranked = r.ranked.items, .ranker = &r, .selected = 25 });
    _ = t.settle();
    try testing.expect(t.win.scrollOffset(p.list).y > 0);

    // A click on a row picks it.
    p.update(.{ .items = &items, .ranked = r.ranked.items, .ranker = &r, .selected = 0 });
    _ = t.settle();
    try testing.expect(t.win.scrollOffset(p.list).y == 0);
    const at: zg_gui.core.Vec2 = .{ .x = box.x + 30, .y = box.y + row_h * 2 + row_h / 2 };
    t.win.dispatch(.{ .pointer_move = .{ .pos = at } });
    t.win.dispatch(.{ .pointer_down = .{ .pos = at } });
    t.win.dispatch(.{ .pointer_up = .{ .pos = at } });
    _ = t.settle();
    try testing.expectEqual(@as(?u32, 2), pick.got);

    // Near the bottom of the window: above the line.
    try p.show(model, .{ .x = 100, .y = 480, .w = 20, .h = 16 });
    _ = t.settle();
    const up = try t.rectOf(.{ .test_id = "completion-list" });
    try testing.expect(up.y + up.h <= 480 + 1);
    p.hide();
    _ = t.settle();
    try testing.expect(!p.isOpen());
}
