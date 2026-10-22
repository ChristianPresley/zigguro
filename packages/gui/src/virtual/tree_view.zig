//! TreeView (E04.F04.S02.T02): a virtualised tree for the explorer (E08),
//! outline (E05/E07), SCM changes (E09), test explorer and settings.
//!
//! The caller owns a `TreeView` (data source, visible rows, selection) and
//! calls `build` from its view. Only the rows in the viewport are built
//! (`virtualList`), so a tree with a million visible rows costs what its
//! visible rows cost. Expanding and collapsing splice rows (`FlatTree`).
//!
//! Keyboard (WAI-ARIA APG tree; focus stays on the tree and the active
//! row is drawn as focused):
//! - Up/Down move, Home/End jump, Page Up/Down move a page.
//! - Right opens a closed node, or moves to the first child of an open
//!   one; Left closes an open node, or moves to the parent.
//! - `*` opens every sibling of the active row.
//! - Enter calls `on_open`; typing jumps to the next row whose label
//!   starts with the typed text (type-ahead, reset after 500 ms).
//! - Selection follows the active row. With `multi`, Shift+arrows and
//!   Shift+click extend from the anchor, Ctrl+arrows move without
//!   selecting, Space and Ctrl+click toggle, Ctrl+A selects every row.
//!
//! Clicking a row selects it; clicking the chevron (or the row, with
//! `expand_on_click`) opens or closes it; a double click calls `on_open`.
//! Children the source does not know yet show a "Loading…" row until the
//! source's load finishes.
//!
//! Not yet: sticky headers and drag and drop.

const std = @import("std");
const geom = @import("../core/geom.zig");
const ids = @import("../core/ids.zig");
const ui_mod = @import("../core/ui.zig");
const widget = @import("../core/widget.zig");
const window_mod = @import("../core/window.zig");
const style_mod = @import("../layout/style.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const text_mod = @import("../paint/text.zig");
const event_mod = @import("../input/event.zig");
const theme_mod = @import("../theme/theme.zig");
const scroll = @import("../widgets/scroll.zig");
const flat_mod = @import("flat_tree.zig");

pub const FlatTree = flat_mod.FlatTree;
pub const TreeSource = flat_mod.TreeSource;
pub const ChildCount = flat_mod.ChildCount;
pub const LoadDone = flat_mod.LoadDone;
pub const RowInfo = flat_mod.RowInfo;
pub const Row = flat_mod.Row;

const Rect = geom.Rect;
const NodeId = ids.NodeId;
const Ui = ui_mod.Ui;
const Window = window_mod.Window;
const PaintCx = paint_cx.PaintCx;
const Allocator = std.mem.Allocator;

/// Called with a node.
pub const NodeHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, node: u64) void,
};

/// Called when the selection changed.
pub const SelectionHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, tv: *TreeView) void,
};

/// How a tree looks and behaves.
pub const TreeProps = struct {
    row_h: f32 = 22,
    /// Indent per level.
    indent: f32 = 8,
    /// Draw a vertical guide per level.
    guides: bool = true,
    multi: bool = false,
    /// A plain click on an expandable row also opens or closes it.
    expand_on_click: bool = true,
    /// The tree's accessible name.
    label: []const u8 = "",
    test_id: []const u8 = "",
    /// The tree's style (`dir = .column` is set).
    style: style_mod.Style = .{ .grow = 1 },
    /// Enter or double click on a row.
    on_open: ?NodeHook = null,
    on_selection: ?SelectionHook = null,
};

/// Type-ahead resets after this pause.
pub const typeahead_ms: u64 = 500;
/// Width of the chevron column.
pub const chevron_w: f32 = 16;

/// A tree's state.
pub const TreeView = struct {
    gpa: Allocator,
    source: TreeSource,
    props: TreeProps,
    flat: FlatTree,
    /// The active (keyboard-focused) row's node.
    active: ?u64 = null,
    active_row: usize = 0,
    selected: std.AutoArrayHashMapUnmanaged(u64, void) = .empty,
    anchor: ?u64 = null,
    win: ?*Window = null,
    view: u16 = 0,
    node: NodeId = .none,
    list: NodeId = .none,
    focused: bool = false,
    typed: [64]u8 = undefined,
    typed_len: u8 = 0,
    typed_at: u64 = 0,

    /// A tree of `source`'s roots, all closed.
    pub fn init(gpa: Allocator, source: TreeSource, props: TreeProps) Allocator.Error!TreeView {
        var tv: TreeView = .{ .gpa = gpa, .source = source, .props = props, .flat = .init(gpa) };
        try tv.flat.rebuild(source, null);
        if (tv.flat.len() > 0) tv.active = tv.flat.rows.items[0].node;
        return tv;
    }

    pub fn deinit(tv: *TreeView) void {
        tv.flat.deinit();
        tv.selected.deinit(tv.gpa);
    }

    fn loadDone(tv: *TreeView) LoadDone {
        return .{ .ctx = tv, .f = onLoaded };
    }

    fn onLoaded(ctx: *anyopaque, node: u64) void {
        const tv: *TreeView = @ptrCast(@alignCast(ctx));
        tv.flat.refresh(tv.source, node, tv.loadDone()) catch {};
        tv.markDirty();
    }

    /// Re-reads the whole tree (after the source changed), keeping open
    /// nodes, the active node and the selection where they still exist.
    pub fn reload(tv: *TreeView) Allocator.Error!void {
        try tv.flat.rebuild(tv.source, tv.loadDone());
        if (tv.flat.len() == 0) {
            tv.active = null;
        } else if (tv.active == null or tv.flat.rowOf(tv.active.?) == null) {
            tv.active = tv.flat.rows.items[@min(tv.active_row, tv.flat.len() - 1)].node;
        }
        tv.markDirty();
    }

    fn markDirty(tv: *TreeView) void {
        const w = tv.win orelse return;
        if (tv.view != 0) w.markViewDirty(tv.view);
    }

    // -- queries --------------------------------------------------------------

    /// The active row, if any.
    pub fn activeRow(tv: *TreeView) ?usize {
        const node = tv.active orelse return null;
        const rows = tv.flat.rows.items;
        if (tv.active_row < rows.len and rows[tv.active_row].node == node and !rows[tv.active_row].flags.placeholder) return tv.active_row;
        tv.active_row = tv.flat.rowOf(node) orelse return null;
        return tv.active_row;
    }

    pub fn isSelected(tv: *const TreeView, node: u64) bool {
        return tv.selected.contains(node);
    }

    /// The selected nodes, in selection order.
    pub fn selection(tv: *const TreeView) []const u64 {
        return tv.selected.keys();
    }

    // -- commands -------------------------------------------------------------

    /// Opens row `i`.
    pub fn expandRow(tv: *TreeView, i: usize) Allocator.Error!bool {
        const opened = try tv.flat.expand(tv.source, i, tv.loadDone());
        if (opened) tv.markDirty();
        return opened;
    }

    /// Closes row `i`; an active row inside it moves to `i`.
    pub fn collapseRow(tv: *TreeView, i: usize) bool {
        const a = tv.activeRow();
        const end = tv.flat.subtreeEnd(i);
        if (!tv.flat.collapse(i)) return false;
        if (a) |r| if (r > i and r < end) tv.setActive(i);
        tv.markDirty();
        return true;
    }

    fn toggleRow(tv: *TreeView, i: usize) Allocator.Error!void {
        if (tv.flat.rows.items[i].flags.expanded) {
            _ = tv.collapseRow(i);
        } else _ = try tv.expandRow(i);
    }

    fn setActive(tv: *TreeView, i: usize) void {
        tv.active = tv.flat.rows.items[i].node;
        tv.active_row = i;
    }

    /// How a move changes the selection.
    const Sel = enum { replace, extend, keep, toggle };

    /// Makes row `i` active and updates the selection.
    pub fn moveTo(tv: *TreeView, i: usize, how: Sel) void {
        if (i >= tv.flat.len()) return;
        const node = tv.flat.rows.items[i].node;
        tv.setActive(i);
        const mode: Sel = if (tv.props.multi) how else switch (how) {
            .keep => .keep,
            else => .replace,
        };
        switch (mode) {
            .keep => {},
            .replace => {
                tv.selected.clearRetainingCapacity();
                tv.selected.put(tv.gpa, node, {}) catch {};
                tv.anchor = node;
                tv.selectionChanged();
            },
            .toggle => {
                if (!tv.selected.orderedRemove(node)) tv.selected.put(tv.gpa, node, {}) catch {};
                tv.anchor = node;
                tv.selectionChanged();
            },
            .extend => {
                const from = if (tv.anchor) |a| tv.flat.rowOf(a) orelse i else i;
                tv.selected.clearRetainingCapacity();
                const lo = @min(from, i);
                const hi = @max(from, i);
                for (tv.flat.rows.items[lo .. hi + 1]) |r| if (!r.flags.placeholder) tv.selected.put(tv.gpa, r.node, {}) catch {};
                tv.selectionChanged();
            },
        }
        tv.reveal(i);
        tv.markDirty();
    }

    fn selectionChanged(tv: *TreeView) void {
        if (tv.props.on_selection) |h| h.f(h.ctx, tv);
    }

    fn listOptions(tv: *const TreeView) scroll.ListOptions {
        return .{ .count = tv.flat.len(), .row_h = tv.props.row_h };
    }

    /// Scrolls row `i` into view.
    pub fn reveal(tv: *TreeView, i: usize) void {
        const w = tv.win orelse return;
        if (tv.list.isNone() or !w.store.valid(tv.list)) return;
        scroll.scrollToRow(w, tv.list, tv.listOptions(), i);
    }

    /// The next row from `i` in direction `dir`, skipping placeholders.
    fn step(tv: *const TreeView, i: usize, dir: i2) ?usize {
        const rows = tv.flat.rows.items;
        var j = i;
        while (true) {
            if (dir > 0) {
                if (j + 1 >= rows.len) return null;
                j += 1;
            } else {
                if (j == 0) return null;
                j -= 1;
            }
            if (!rows[j].flags.placeholder) return j;
        }
    }

    fn pageRows(tv: *const TreeView) usize {
        const w = tv.win orelse return 10;
        if (tv.list.isNone() or !w.store.valid(tv.list)) return 10;
        const h = w.store.relRect(tv.list).h;
        return @max(1, @as(usize, @intFromFloat(@floor(h / tv.props.row_h))) -| 1);
    }

    /// Handles a key on the tree; true when used.
    pub fn onKey(tv: *TreeView, k: event_mod.KeyPress) Allocator.Error!bool {
        if (k.action == .release or k.mods.alt) return false;
        const n = tv.flat.len();
        if (n == 0) return false;
        const cur = tv.activeRow() orelse 0;
        const how: Sel = if (k.mods.shift) .extend else if (k.mods.ctrl) .keep else .replace;
        switch (k.key) {
            .arrow_down => tv.moveTo(tv.step(cur, 1) orelse cur, how),
            .arrow_up => tv.moveTo(tv.step(cur, -1) orelse cur, how),
            .home => tv.moveTo(0, how),
            .end => tv.moveTo(tv.step(n, -1) orelse n - 1, how),
            .page_down => tv.moveTo(@min(n - 1, cur + tv.pageRows()), how),
            .page_up => tv.moveTo(cur -| tv.pageRows(), how),
            .arrow_right => {
                if (k.mods.shift or k.mods.ctrl) return false;
                const r = tv.flat.rows.items[cur];
                if (!r.flags.expandable) return true;
                if (!r.flags.expanded) {
                    _ = try tv.expandRow(cur);
                } else if (cur + 1 < n and !tv.flat.rows.items[cur + 1].flags.placeholder and tv.flat.rows.items[cur + 1].depth > r.depth) {
                    tv.moveTo(cur + 1, .replace);
                }
            },
            .arrow_left => {
                if (k.mods.shift or k.mods.ctrl) return false;
                if (tv.flat.rows.items[cur].flags.expanded) {
                    _ = tv.collapseRow(cur);
                } else if (tv.flat.parentRow(cur)) |p| tv.moveTo(p, .replace);
            },
            .numpad_multiply => _ = try tv.expandAllSiblings(cur),
            .enter, .numpad_enter => {
                const h = tv.props.on_open orelse return false;
                h.f(h.ctx, tv.flat.rows.items[cur].node);
            },
            .space => {
                if (tv.typed_len > 0) return false; // part of a type-ahead
                tv.moveTo(cur, if (k.mods.ctrl or tv.props.multi) .toggle else .replace);
            },
            .key_a => {
                if (!k.mods.ctrl or !tv.props.multi) return false;
                tv.selected.clearRetainingCapacity();
                for (tv.flat.rows.items) |r| if (!r.flags.placeholder) try tv.selected.put(tv.gpa, r.node, {});
                tv.selectionChanged();
                tv.markDirty();
            },
            .escape => {
                if (tv.selected.count() == 0) return false;
                tv.selected.clearRetainingCapacity();
                tv.selectionChanged();
                tv.markDirty();
            },
            else => return false,
        }
        return true;
    }

    fn expandAllSiblings(tv: *TreeView, i: usize) Allocator.Error!bool {
        const opened = try tv.flat.expandSiblings(tv.source, i, tv.loadDone());
        if (opened > 0) tv.markDirty();
        return true;
    }

    /// Handles typed text (type-ahead and `*`); true when used.
    pub fn onText(tv: *TreeView, s: []const u8, now_ms: u64) Allocator.Error!bool {
        if (s.len == 0 or tv.flat.len() == 0) return false;
        if (now_ms -| tv.typed_at > typeahead_ms) tv.typed_len = 0;
        if (tv.typed_len == 0 and std.mem.eql(u8, s, "*")) return tv.expandAllSiblings(tv.activeRow() orelse 0);
        if (tv.typed_len == 0 and std.mem.eql(u8, s, " ")) return false;
        tv.typed_at = now_ms;
        const room = tv.typed.len - tv.typed_len;
        const take = @min(room, s.len);
        @memcpy(tv.typed[tv.typed_len..][0..take], s[0..take]);
        tv.typed_len += @intCast(take);
        const q = tv.typed[0..tv.typed_len];
        // One repeated character cycles through the rows starting with it.
        const repeat = q.len > 1 and std.mem.allEqual(u8, q, q[0]);
        const needle = if (repeat) q[0..1] else q;
        const cur = tv.activeRow() orelse 0;
        const n = tv.flat.len();
        const start: usize = if (q.len == 1 or repeat) cur + 1 else cur;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const i = (start + k) % n;
            const r = tv.flat.rows.items[i];
            if (r.flags.placeholder) continue;
            if (std.ascii.startsWithIgnoreCase(tv.source.label(r.node), needle)) {
                tv.moveTo(i, .replace);
                return true;
            }
        }
        return true;
    }

    /// A press on row `i` at `x` (row-local) with `p`'s modifiers.
    fn onRowPointer(tv: *TreeView, i: usize, x: f32, p: event_mod.Pointer) Allocator.Error!void {
        if (i >= tv.flat.len()) return;
        const r = tv.flat.rows.items[i];
        if (r.flags.placeholder) return;
        const chev_x = @as(f32, @floatFromInt(r.depth)) * tv.props.indent;
        const on_chevron = x >= chev_x and x < chev_x + chevron_w;
        if (p.button != .left) {
            if (!tv.isSelected(r.node)) tv.moveTo(i, .replace);
            return;
        }
        if (p.clicks >= 2) {
            if (tv.props.on_open) |h| h.f(h.ctx, r.node);
            return;
        }
        if (r.flags.expandable and on_chevron) {
            tv.setActive(i);
            try tv.toggleRow(i);
            return;
        }
        const how: Sel = if (p.mods.shift) .extend else if (p.mods.ctrl) .toggle else .replace;
        tv.moveTo(i, how);
        if (how == .replace and tv.props.expand_on_click and r.flags.expandable) try tv.toggleRow(i);
    }

    // -- building -------------------------------------------------------------

    /// Builds the tree into the current view.
    pub fn build(tv: *TreeView, ui: *Ui) void {
        tv.win = ui.window();
        tv.view = ui.currentView();
        _ = ui.begin(TreeBox, .{ .tv = tv, .label = tv.props.label });
        defer ui.end(TreeBox);
        tv.node = ui.current();
        var opts = tv.listOptions();
        opts.style = .{ .grow = 1 };
        opts.test_id = tv.props.test_id;
        const vis = scroll.virtualList(ui, opts, tv, row);
        tv.list = vis.node;
    }

    fn row(tv: *TreeView, ui: *Ui, i: usize) void {
        const r = tv.flat.rows.items[i];
        const custom = if (r.flags.placeholder) null else tv.source.vtable.build_row;
        const active = !r.flags.placeholder and tv.active != null and tv.active.? == r.node;
        const selected = !r.flags.placeholder and tv.isSelected(r.node);
        _ = ui.begin(TreeRow, .{
            .tv = tv,
            .index = @intCast(i),
            .depth = r.depth,
            .expanded = r.flags.expanded,
            .expandable = r.flags.expandable,
            .placeholder = r.flags.placeholder,
            .label = if (r.flags.placeholder) "Loading\u{2026}" else tv.source.label(r.node),
            .draw_label = custom == null,
            .active = active,
            .selected = selected,
            .focused = tv.focused,
            .guides = tv.props.guides,
            .indent = tv.props.indent,
        });
        defer ui.end(TreeRow);
        if (custom) |f| f(tv.source.ptr, ui, r.node, .{ .index = i, .depth = r.depth, .expanded = r.flags.expanded, .selected = selected, .active = active });
    }
};

/// The tree's focusable container.
pub const TreeBox = struct {
    pub const name = "tree";
    pub const focusable = true;

    pub const Props = struct {
        tv: *TreeView,
        label: []const u8 = "",
    };

    pub fn style(props: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        var st = props.tv.props.style;
        st.dir = .column;
        return st;
    }

    pub fn event(ec: *event_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const event_mod.InputEvent) bool {
        const tv = props.tv;
        if (ec.phase == .capture) return false;
        switch (ev.*) {
            .key => |k| return tv.onKey(k) catch false,
            .text => |s| return tv.onText(s, ec.nowMs()) catch false,
            .focus_gained, .focus_lost => {
                tv.focused = ev.* == .focus_gained;
                tv.markDirty();
                return false;
            },
            else => return false,
        }
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .tree, .name = props.label };
    }
};

/// One row: indent, guides, chevron and the label (or the source's
/// content).
pub const TreeRow = struct {
    pub const name = "treeitem";

    pub const Props = struct {
        tv: *TreeView,
        index: u32,
        depth: u16,
        expanded: bool = false,
        expandable: bool = false,
        placeholder: bool = false,
        label: []const u8,
        draw_label: bool = true,
        active: bool = false,
        selected: bool = false,
        focused: bool = false,
        guides: bool = true,
        indent: f32 = 8,
    };

    fn textStyle(th: *const theme_mod.Theme, italic: bool) text_mod.TextStyle {
        return .{ .size = th.dim(.font_size), .italic = italic };
    }

    pub fn style(props: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        const left = @as(f32, @floatFromInt(props.depth)) * props.indent + chevron_w;
        return .{ .grow = 1, .align_self = .stretch, .dir = .row, .align_items = .center, .padding = .{ .l = left } };
    }

    pub fn paint(pc: *PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        if (props.selected) {
            pc.fill(r, .selection_bg, 0);
        } else if (pc.state.hovered) pc.fill(r, .hover_bg, 0);
        if (props.active and props.focused) pc.border(r, 1, pc.color(.focus_ring), 0);
        if (props.guides) {
            var d: u16 = 0;
            while (d < props.depth) : (d += 1) {
                const x = r.x + @as(f32, @floatFromInt(d)) * props.indent + chevron_w / 2;
                pc.fill(.{ .x = @floor(x), .y = r.y, .w = 1, .h = r.h }, .border, 0);
            }
        }
        const st = textStyle(pc.theme, props.placeholder);
        const x0 = r.x + @as(f32, @floatFromInt(props.depth)) * props.indent;
        if (props.expandable) {
            const glyph = if (props.expanded) "\u{25be}" else "\u{25b8}";
            pc.textBox(glyph, st, pc.color(.fg_muted), .{ .x = x0, .y = r.y, .w = chevron_w, .h = r.h }, false, .center);
        }
        if (props.draw_label) {
            const tr: Rect = .{ .x = x0 + chevron_w, .y = r.y, .w = @max(0, r.right() - x0 - chevron_w), .h = r.h };
            const fg = if (props.placeholder) pc.color(.fg_muted) else pc.color(.fg);
            pc.textBox(props.label, st, fg, tr, false, .start);
        }
    }

    pub fn event(ec: *event_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const event_mod.InputEvent) bool {
        switch (ev.*) {
            .pointer_down => |p| {
                if (ec.phase == .capture) return false;
                const local = ec.local(p.pos);
                props.tv.onRowPointer(props.index, local.x, p) catch {};
                return true;
            },
            else => return false,
        }
    }

    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{
            .role = .treeitem,
            .name = props.label,
            .expanded = if (props.expandable) props.expanded else null,
            .selected = props.selected,
            .level = props.depth + 1,
        };
    }
};
