//! MarkdownView (E04.F06.S01.T02): a parsed `Doc` as native zigguro UI.
//!
//! Each top-level block is a keyed subtree (keyed by its source offset and
//! kind, which a streaming append never changes for a closed block), and
//! every text leaf is a `RichText` node. Flattened text and line layout
//! are cached per block in `MdViewState`; an append drops only the
//! entries of the blocks it replaced, so only those nodes re-measure.
//! Documents over 200 top-level blocks build only the blocks in view
//! (estimated heights, corrected after layout).
//!
//! The state is owned by the caller, like a text field's buffer: it holds
//! the document pointer, the caches, the selection and the callbacks, and
//! must outlive the nodes built from it.

const std = @import("std");
const ast = @import("ast.zig");
const doc_mod = @import("doc.zig");
const stream = @import("stream.zig");
const links = @import("links.zig");
const rich = @import("rich.zig");
const selection = @import("selection.zig");
const rich_text = @import("rich_text.zig");
const code_view = @import("code_view.zig");
const table_view = @import("table_view.zig");
const image_view = @import("image_view.zig");
const geom = @import("../core/geom.zig");
const ids = @import("../core/ids.zig");
const ui_mod = @import("../core/ui.zig");
const widget = @import("../core/widget.zig");
const event_mod = @import("../input/event.zig");
const style_mod = @import("../layout/style.zig");
const text_mod = @import("../paint/text.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const theme_mod = @import("../theme/theme.zig");
const tokens = @import("../theme/tokens.zig");
const controls = @import("../widgets/controls.zig");
const scroll = @import("../widgets/scroll.zig");
const HeightIndex = @import("../widgets/height_index.zig").HeightIndex;

const Allocator = std.mem.Allocator;
const Doc = doc_mod.Doc;
const Ui = ui_mod.Ui;
const NodeId = ids.NodeId;
const Token = tokens.Token;
const TextStyle = text_mod.TextStyle;
const none = ast.none;

pub const DocSelection = selection.DocSelection;
pub const Pos = selection.Pos;
pub const Highlighter = code_view.Highlighter;
pub const SyntaxClass = code_view.SyntaxClass;
pub const Span = code_view.Span;
pub const CodeAction = code_view.CodeAction;
pub const ImageLoader = image_view.ImageLoader;
pub const ImageHandle = image_view.ImageHandle;

/// Where a clicked link points.
pub const LinkTarget = union(enum) {
    url: []const u8,
    wiki: []const u8,
    anchor: []const u8,
    footnote: []const u8,
};

/// Called when a link is clicked (`ctrl`: Ctrl or Cmd was held).
pub const LinkCb = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, target: LinkTarget, ctrl: bool) void,
};

/// Called when a task checkbox is clicked, with the source offset of its
/// `[` and the state it shows now.
pub const TaskCb = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, src_offset: u32, checked: bool) void,
};

/// How `view` draws a document.
pub const MdViewProps = struct {
    /// A blinking caret after the last glyph while an answer streams in.
    streaming: bool = false,
    highlighter: ?Highlighter = null,
    /// Tighter spacing (chat bubbles).
    compact: bool = false,
    max_width: f32 = 820,
    on_link: ?LinkCb = null,
    on_task_toggle: ?TaskCb = null,
    image_loader: ?ImageLoader = null,
    selectable: bool = true,
    /// Build only the blocks in view (documents over 200 blocks). Off for
    /// small documents inside chat bubbles, whose transcript virtualizes.
    virtualize: bool = true,
    /// Action buttons in every code block header (Insert, Apply).
    code_actions: []const CodeAction = &.{},
    test_id: []const u8 = "",
};

/// A text leaf built this frame.
pub const LeafRef = struct {
    block: u32,
    node: NodeId,
    shape: rich.Shape,
    wrap: bool,
    @"align": paint_cx.TextAlign = .start,
};

/// A row of a virtualized view and its node.
pub const BuiltRow = struct { row: u32, node: NodeId };

/// A block's cached text and layout.
pub const Entry = struct {
    gen: u32,
    flat: rich.Flat = .{},
    lines: std.ArrayList(rich.Line) = .empty,
    /// Width, size and font of `lines`.
    lines_key: [3]u64 = .{ std.math.maxInt(u64), 0, 0 },

    fn deinit(e: *Entry, gpa: Allocator) void {
        e.flat.deinit(gpa);
        e.lines.deinit(gpa);
    }
};

/// Counters for tests and benchmarks.
pub const Stats = struct {
    flattened: u32 = 0,
    laid_out: u32 = 0,
    highlighted: u32 = 0,
};

/// A document's view state: caches, selection and callbacks.
pub const MdViewState = struct {
    gpa: Allocator,
    doc: *Doc,
    entries: std.AutoHashMapUnmanaged(u32, *Entry) = .empty,
    next_gen: u32 = 1,
    selection: ?DocSelection = null,
    /// Text leaves built by the last `view`, in document order.
    leaves: std.ArrayList(LeafRef) = .empty,
    dragging: bool = false,
    drag_moved: bool = false,
    /// The link under the pointer: (block, link index).
    hover: ?[2]u32 = null,
    props: MdViewProps = .{},
    /// Code blocks with wrapping turned on, by source offset.
    wrapped: std.AutoHashMapUnmanaged(u32, void) = .empty,
    front_matter_open: bool = false,
    code: code_view.Cache = .{},
    /// Bumped by `imagesChanged` so image nodes re-measure.
    image_gen: u32 = 0,
    heights: HeightIndex,
    /// Rows built by the last virtualized `view`.
    rows: std.ArrayList(BuiltRow) = .empty,
    stats: Stats = .{},

    /// A view of `doc` (borrowed; it must outlive the state).
    pub fn init(gpa: Allocator, doc: *Doc) MdViewState {
        return .{ .gpa = gpa, .doc = doc, .heights = .init(gpa) };
    }

    /// Frees the caches.
    pub fn deinit(s: *MdViewState) void {
        var it = s.entries.valueIterator();
        while (it.next()) |e| {
            e.*.deinit(s.gpa);
            s.gpa.destroy(e.*);
        }
        s.entries.deinit(s.gpa);
        s.leaves.deinit(s.gpa);
        s.wrapped.deinit(s.gpa);
        s.code.deinit(s.gpa);
        s.heights.deinit();
        s.rows.deinit(s.gpa);
    }

    /// Streams `chunk` into the document and drops the caches of the
    /// blocks it replaced.
    pub fn append(s: *MdViewState, chunk: []const u8) stream.Error!ast.Delta {
        const delta = try stream.append(s.doc, chunk);
        s.applyDelta(delta);
        return delta;
    }

    /// Ends the stream (closes every block).
    pub fn finish(s: *MdViewState) stream.Error!ast.Delta {
        const delta = try stream.finish(s.doc);
        s.applyDelta(delta);
        return delta;
    }

    /// Drops the caches of the top-level blocks from
    /// `delta.first_changed_block` on (after the caller changed the doc).
    pub fn applyDelta(s: *MdViewState, delta: ast.Delta) void {
        var c = s.doc.blocks.items[0].first_child;
        var k: u32 = 0;
        while (c != none and k < delta.first_changed_block) : (c = s.doc.blocks.items[c].next) k += 1;
        const from: u32 = if (c == none) @intCast(s.doc.blocks.items.len) else c;
        s.dropFrom(from);
        if (s.selection) |sel| {
            const o = sel.ordered();
            if (o[1].block >= from) s.selection = null;
        }
    }

    /// Drops every cache (the document was replaced).
    pub fn invalidateAll(s: *MdViewState) void {
        s.dropFrom(0);
        s.selection = null;
    }

    fn dropFrom(s: *MdViewState, from: u32) void {
        var it = s.entries.iterator();
        var gone: std.ArrayList(u32) = .empty;
        defer gone.deinit(s.gpa);
        while (it.next()) |kv| if (kv.key_ptr.* >= from) {
            gone.append(s.gpa, kv.key_ptr.*) catch {};
        };
        for (gone.items) |k| if (s.entries.fetchRemove(k)) |kv| {
            kv.value.deinit(s.gpa);
            s.gpa.destroy(kv.value);
        };
    }

    /// Images finished loading: image nodes measure again.
    pub fn imagesChanged(s: *MdViewState) void {
        s.image_gen +%= 1;
    }

    /// The cached text of leaf `block` (flattened on first use).
    pub fn entry(s: *MdViewState, block: u32) ?*Entry {
        if (s.entries.get(block)) |e| return e;
        const e = s.gpa.create(Entry) catch return null;
        e.* = .{ .gen = s.next_gen };
        s.next_gen +%= 1;
        rich.flatten(s.gpa, s.doc, block, &e.flat) catch {
            e.deinit(s.gpa);
            s.gpa.destroy(e);
            return null;
        };
        s.entries.put(s.gpa, block, e) catch {
            e.deinit(s.gpa);
            s.gpa.destroy(e);
            return null;
        };
        s.stats.flattened += 1;
        return e;
    }

    /// The lines of `e` laid out with `shape` at `max_w` (null: no wrap).
    pub fn linesOf(s: *MdViewState, e: *Entry, shape: rich.Shape, max_w: ?f32) []const rich.Line {
        const w: u64 = if (max_w) |m| @as(u32, @bitCast(m)) else std.math.maxInt(u64) - 1;
        const key: [3]u64 = .{ w, @as(u32, @bitCast(shape.base.size)), @as(u64, shape.base.weight) | (@as(u64, @intFromEnum(shape.base.font)) << 16) | (@as(u64, @intFromBool(shape.base.italic)) << 32) };
        if (std.mem.eql(u64, &key, &e.lines_key)) return e.lines.items;
        rich.layout(s.gpa, shape, &e.flat, max_w, &e.lines) catch {
            e.lines.clearRetainingCapacity();
            e.lines_key[0] = std.math.maxInt(u64);
            return &.{};
        };
        e.lines_key = key;
        s.stats.laid_out += 1;
        return e.lines.items;
    }

    fn textOf(ctx: *anyopaque, block: u32) []const u8 {
        const s: *MdViewState = @ptrCast(@alignCast(ctx));
        const e = s.entry(block) orelse return "";
        return e.flat.text.items;
    }

    /// The selected text (caller frees), or null without a selection.
    pub fn selectedText(s: *MdViewState, gpa: Allocator) ?[]u8 {
        const sel = s.selection orelse return null;
        if (sel.isEmpty()) return null;
        return selection.copyText(gpa, s.doc, sel, .{ .ctx = s, .f = textOf }) catch null;
    }

    /// Selects every text leaf.
    pub fn selectAll(s: *MdViewState) void {
        var first: u32 = none;
        var last: u32 = none;
        for (s.doc.blocks.items, 0..) |b, i| if (selection.isTextLeaf(b.kind)) {
            if (first == none) first = @intCast(i);
            last = @intCast(i);
        };
        if (first == none) return;
        const e = s.entry(last) orelse return;
        s.selection = .{ .anchor = .{ .block = first, .off = 0 }, .head = .{ .block = last, .off = @intCast(e.flat.text.items.len) } };
    }

    /// Copies the selection to the clipboard (through `ec`).
    pub fn copySelection(s: *MdViewState, ec: *event_mod.EventCx) void {
        const t = s.selectedText(s.gpa) orelse return;
        defer s.gpa.free(t);
        ec.setClipboard(t);
    }

    /// Repaints every text leaf (the selection or hover changed).
    pub fn repaintLeaves(s: *MdViewState, ec: *event_mod.EventCx) void {
        for (s.leaves.items) |l| ec.repaintNode(l.node);
    }

    /// The leaf and offset under window point `p`: the leaf containing
    /// it, else the last leaf above it (its end), else the first (0).
    pub fn posAt(s: *MdViewState, ec: *event_mod.EventCx, p: geom.Vec2) ?Pos {
        if (s.leaves.items.len == 0) return null;
        var above: ?usize = null;
        for (s.leaves.items, 0..) |l, i| {
            const r = ec.rectOf(l.node);
            if (r.contains(p)) return s.posIn(l, r, p);
            if (r.y <= p.y) above = i;
        }
        if (above) |i| {
            const l = s.leaves.items[i];
            const r = ec.rectOf(l.node);
            if (p.y < r.bottom()) return s.posIn(l, r, p);
            const e = s.entry(l.block) orelse return null;
            return .{ .block = l.block, .off = @intCast(e.flat.text.items.len) };
        }
        return .{ .block = s.leaves.items[0].block, .off = 0 };
    }

    fn posIn(s: *MdViewState, l: LeafRef, r: geom.Rect, p: geom.Vec2) ?Pos {
        const e = s.entry(l.block) orelse return null;
        const lines = s.linesOf(e, l.shape, if (l.wrap) r.w else null);
        const local: geom.Vec2 = .{ .x = p.x - r.x, .y = p.y - r.y };
        const lp = rich_text.unalign(l, e, lines, r.w, local);
        return .{ .block = l.block, .off = rich.hitTest(l.shape, &e.flat, lines, lp) };
    }

    fn leafIndex(s: *const MdViewState, block: u32) ?usize {
        for (s.leaves.items, 0..) |l, i| if (l.block == block) return i;
        return null;
    }

    /// The leaf ref of `block`, if built.
    pub fn leafOf(s: *const MdViewState, block: u32) ?LeafRef {
        const i = s.leafIndex(block) orelse return null;
        return s.leaves.items[i];
    }
};

/// The container node of a document: focusable (one tab stop), it takes
/// Copy, Select All and Escape for the selection.
pub const MdRoot = struct {
    /// Shown in snapshots.
    pub const name = "markdown";
    /// Takes focus so Ctrl+C reaches it.
    pub const focusable = true;

    /// The state and width.
    pub const Props = struct {
        view: *MdViewState,
        max_width: f32 = 820,
        compact: bool = false,
        /// Fill the parent's height (virtualized: the view scrolls).
        fill: bool = false,
    };

    /// A column of blocks.
    pub fn style(props: *const Props, th: *const theme_mod.Theme) style_mod.Style {
        const gap = if (props.compact) th.dim(.space_sm) else th.dim(.space_md);
        // As tall as its blocks: the caller scrolls (unless it fills).
        var st: style_mod.Style = .{ .dir = .column, .gap = gap, .max_w = props.max_width, .align_items = .stretch, .shrink = 0 };
        if (props.fill) {
            st.shrink = 1;
            st.grow = 1;
            st.basis = .{ .px = 0 };
            st.min_h = 0;
        }
        return st;
    }

    /// Copy, Select All, Escape.
    pub fn event(ec: *event_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const event_mod.InputEvent) bool {
        const s = props.view;
        switch (ev.*) {
            .key => |k| {
                if (k.action == .release) return false;
                const ctrl = k.mods.ctrl or k.mods.super;
                switch (k.key) {
                    .key_c, .insert => if (ctrl) {
                        s.copySelection(ec);
                        return true;
                    },
                    .key_a => if (ctrl and s.props.selectable) {
                        s.selectAll();
                        s.repaintLeaves(ec);
                        return true;
                    },
                    .escape => if (s.selection != null) {
                        s.selection = null;
                        s.repaintLeaves(ec);
                        return true;
                    },
                    else => {},
                }
                return false;
            },
            else => return false,
        }
    }

    /// A document region.
    pub fn a11y(_: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .group, .name = "Markdown" };
    }
};

/// Builds `s.doc` as UI.
pub fn view(ui: *Ui, s: *MdViewState, p: MdViewProps) void {
    s.props = p;
    s.leaves.clearRetainingCapacity();
    const d = s.doc;
    if (d.blocks.items.len == 0) return;
    var count: usize = 0;
    var c = d.blocks.items[0].first_child;
    while (c != none) : (c = d.blocks.items[c].next) count += 1;
    const virtual = p.virtualize and count > 200;

    if (p.test_id.len > 0) ui.id(p.test_id);
    _ = ui.begin(MdRoot, .{ .view = s, .max_width = p.max_width, .compact = p.compact, .fill = virtual });
    defer ui.end(MdRoot);

    var b: Builder = .{ .ui = ui, .s = s, .p = p, .caret_block = if (p.streaming) caretBlock(d) else none };
    b.base = .{ .size = ui.theme().dim(.font_size) };
    b.ts = ui.window().text_sys;

    if (!virtual) {
        c = d.blocks.items[0].first_child;
        while (c != none) : (c = d.blocks.items[c].next) b.top(c);
        if (p.streaming and b.caret_block == none) b.caretLine();
        return;
    }

    // Virtualized: one row per top-level block.
    const tops = ui.arena().alloc(u32, count) catch return;
    c = d.blocks.items[0].first_child;
    for (tops) |*t| {
        t.* = c;
        c = d.blocks.items[c].next;
    }
    b.tops = tops;
    updateHeights(s, ui, tops, &b);
    s.rows.clearRetainingCapacity();
    _ = scroll.virtualList(ui, .{ .count = count, .heights = &s.heights, .style = .{ .grow = 1, .basis = .{ .px = 0 } }, .test_id = "markdown-rows" }, &b, Builder.row);
}

/// The text leaf the streaming caret follows: the last leaf of the last
/// block (none when that block is not text).
fn caretBlock(d: *const Doc) u32 {
    var c: u32 = 0;
    while (d.blocks.items[c].last_child != none) c = d.blocks.items[c].last_child;
    if (c == 0) return none;
    return if (selection.isTextLeaf(d.blocks.items[c].kind)) c else none;
}

const heading_scale = [_]f32{ 1.75, 1.45, 1.25, 1.1, 1.0, 0.9 };

/// Builds blocks; shared state of one `view` call.
pub const Builder = struct {
    ui: *Ui,
    s: *MdViewState,
    p: MdViewProps,
    base: TextStyle = .{},
    ts: text_mod.TextSystem = undefined,
    caret_block: u32,
    /// Top-level blocks (virtualized views).
    tops: []const u32 = &.{},

    pub fn gap(b: *const Builder) f32 {
        return if (b.p.compact) b.ui.theme().dim(.space_sm) else b.ui.theme().dim(.space_md);
    }

    /// One top-level block under its stable key.
    fn top(b: *Builder, i: u32) void {
        const blk = b.s.doc.blocks.items[i];
        b.ui.id((@as(u64, blk.src[0]) << 8) | @intFromEnum(blk.kind));
        b.block(i);
    }

    fn row(b: *Builder, ui: *Ui, i: usize) void {
        const c = b.tops[i];
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .align_self = .start, .padding = .{ .b = b.gap() } } });
        b.s.rows.append(b.s.gpa, .{ .row = @intCast(i), .node = ui.current() }) catch {};
        b.block(c);
        ui.close();
    }

    fn block(b: *Builder, i: u32) void {
        const blk = b.s.doc.blocks.items[i];
        switch (blk.kind) {
            .paragraph => if (image_view.soleImage(b.s.doc, i)) |img| {
                image_view.build(b, i, img);
            } else b.leaf(i, b.base, .fg, true, .start),
            .heading => {
                var st = b.base;
                const lvl = @max(1, @min(6, blk.level));
                st.size = @round(b.base.size * heading_scale[lvl - 1]);
                st.weight = if (lvl <= 2) 700 else 600;
                b.ui.with(.{ .margin = .{ .t = if (b.p.compact) 2 else 6 } });
                b.leaf(i, st, .fg, true, .start);
            },
            .thematic_break => controls.separator(b.ui, false),
            .code_fenced, .code_indented, .math_block => code_view.build(b, i),
            .html_literal => {
                var st = b.base;
                st.font = .mono;
                b.leaf(i, st, .fg_muted, true, .start);
            },
            .block_quote, .callout => b.quote(i),
            .list => b.list(i),
            .table => table_view.build(b, i),
            .front_matter => b.frontMatter(i),
            else => {},
        }
    }

    /// A text leaf for block `i`.
    pub fn leaf(b: *Builder, i: u32, st: TextStyle, color: Token, wrap: bool, al: paint_cx.TextAlign) void {
        const e = b.s.entry(i) orelse return;
        const shape: rich.Shape = .{ .ts = b.ts, .base = st };
        _ = b.ui.leaf(rich_text.RichText, .{
            .view = b.s,
            .block = i,
            .gen = e.gen,
            .shape_base = st,
            .color = color,
            .wrap = wrap,
            .@"align" = al,
            .caret = i == b.caret_block,
            .code = !b.s.doc.blocks.items[i].kind.hasInlines() and b.s.doc.blocks.items[i].kind != .html_literal,
        });
        const node = b.ui.lastNode();
        if (!node.isNone()) b.s.leaves.append(b.s.gpa, .{ .block = i, .node = node, .shape = shape, .wrap = wrap, .@"align" = al }) catch {};
    }

    /// The streaming caret when the document ends in a non-text block (or
    /// is empty): on a line of its own.
    fn caretLine(b: *Builder) void {
        _ = b.ui.leaf(rich_text.Caret, .{ .size = b.base.size });
    }

    fn children(b: *Builder, i: u32) void {
        var c = b.s.doc.blocks.items[i].first_child;
        while (c != none) : (c = b.s.doc.blocks.items[c].next) {
            const blk = b.s.doc.blocks.items[c];
            b.ui.id((@as(u64, blk.src[0]) << 8) | @intFromEnum(blk.kind));
            b.block(c);
        }
    }

    /// A block quote (left rule) or callout (coloured rule, icon, title).
    fn quote(b: *Builder, i: u32) void {
        const d = b.s.doc;
        const blk = d.blocks.items[i];
        const kind = if (blk.kind == .callout) calloutKind(d.contentOf(blk.info)) else null;
        const color: Token = if (kind) |k| k.color else .border_strong;
        b.ui.open(.{ .style = .{ .dir = .row, .gap = 10, .bg = if (kind != null) .{ .token = .bg_elevated } else .none, .radius = if (kind != null) b.ui.theme().dim(.radius_md) else 0, .padding = if (kind != null) .{ .r = 10, .t = 6, .b = 6 } else .{} }, .role = if (kind != null) .group else .none, .label = if (kind) |k| k.label else "" });
        defer b.ui.close();
        b.ui.open(.{ .style = .{ .w = .{ .px = 3 }, .shrink = 0, .bg = .{ .token = color }, .radius = 1.5 } });
        b.ui.close();
        b.ui.open(.{ .style = .{ .dir = .column, .grow = 1, .shrink = 1, .gap = b.gap() } });
        defer b.ui.close();
        if (kind) |k| {
            b.ui.open(.{ .style = .{ .dir = .row, .gap = 6, .align_items = .center } });
            b.ui.text(k.icon, .{ .color = k.color, .wrap = false });
            const title = d.contentOf(blk.title);
            b.ui.text(if (title.len > 0) title else k.label, .{ .color = k.color, .wrap = true, .style = .{ .weight = 600 } });
            b.ui.close();
        }
        b.children(i);
    }

    /// A list: markers (bullets by depth, ordered numbers right-aligned)
    /// and task boxes beside each item's blocks.
    fn list(b: *Builder, i: u32) void {
        const d = b.s.doc;
        const ld = d.blocks.items[i].list;
        const depth = listDepth(d, i);
        b.ui.open(.{ .style = .{ .dir = .column, .gap = if (ld.tight) 2 else b.gap() }, .role = .list });
        defer b.ui.close();
        // Ordered markers are as wide as the widest number.
        var n_items: u32 = 0;
        var c = d.blocks.items[i].first_child;
        while (c != none) : (c = d.blocks.items[c].next) n_items += 1;
        var buf: [16]u8 = undefined;
        const widest = if (ld.ordered) std.fmt.bufPrint(&buf, "{d}{c}", .{ ld.start + n_items -| 1, ld.marker }) catch "" else "•";
        const marker_w = b.ts.width(b.base, widest) + 2;
        var n: u32 = ld.start;
        c = d.blocks.items[i].first_child;
        while (c != none) : ({
            c = d.blocks.items[c].next;
            n += 1;
        }) {
            const item = d.blocks.items[c];
            b.ui.id((@as(u64, item.src[0]) << 8) | @intFromEnum(item.kind));
            b.ui.open(.{ .style = .{ .dir = .row, .gap = 6, .align_items = .start }, .role = .listitem });
            defer b.ui.close();
            b.ui.open(.{ .style = .{ .w = .{ .px = marker_w }, .shrink = 0, .dir = .row, .justify = if (ld.ordered) .end else .center } });
            if (ld.ordered) {
                b.ui.textf("{d}{c}", .{ n, ld.marker }, .{ .color = .fg_muted, .wrap = false });
            } else b.ui.text(bullets[depth % bullets.len], .{ .color = .fg_muted, .wrap = false });
            b.ui.close();
            if (item.task != .none) {
                _ = b.ui.leaf(TaskBox, .{ .view = b.s, .item = c, .checked = item.task == .checked, .read_only = b.p.on_task_toggle == null, .size = b.base.size });
            }
            b.ui.open(.{ .style = .{ .dir = .column, .grow = 1, .shrink = 1, .gap = if (ld.tight) 2 else b.gap() } });
            b.children(c);
            b.ui.close();
        }
    }

    /// Front matter: a collapsible key-value grid (collapsed by default).
    fn frontMatter(b: *Builder, i: u32) void {
        const d = b.s.doc;
        const text = d.contentOf(d.blocks.items[i].content);
        b.ui.open(.{ .style = .{ .dir = .column, .gap = 4, .padding = .xy(8, 6), .bg = .{ .token = .bg_sunken }, .radius = b.ui.theme().dim(.radius_md) } });
        defer b.ui.close();
        if (controls.button(b.ui, .{ .label = if (b.s.front_matter_open) "▾ Properties" else "▸ Properties", .variant = .ghost }).clicked) {
            b.s.front_matter_open = !b.s.front_matter_open;
            b.ui.cx().notify();
        }
        if (!b.s.front_matter_open) return;
        var it = std.mem.splitScalar(u8, text, '\n');
        var k: u32 = 0;
        while (it.next()) |line| : (k += 1) {
            if (std.mem.trim(u8, line, " \t").len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':');
            b.ui.id(k);
            b.ui.open(.{ .style = .{ .dir = .row, .gap = 12 } });
            b.ui.with(.{ .w = .{ .px = 140 } });
            b.ui.text(if (colon) |c| std.mem.trim(u8, line[0..c], " \t") else line, .{ .color = .fg_muted, .wrap = false });
            b.ui.text(if (colon) |c| std.mem.trim(u8, line[c + 1 ..], " \t") else "", .{ .style = .{ .font = .mono } });
            b.ui.close();
        }
    }
};

const bullets = [_][]const u8{ "•", "◦", "▪" };

fn listDepth(d: *const Doc, i: u32) usize {
    var n: usize = 0;
    var p = d.blocks.items[i].parent;
    while (p != none) : (p = d.blocks.items[p].parent) {
        if (d.blocks.items[p].kind == .list) n += 1;
    }
    return n;
}

/// How a callout kind is drawn.
pub const CalloutStyle = struct { label: []const u8, icon: []const u8, color: Token };

/// The style of a callout's `[!kind]` (unknown kinds look like notes).
pub fn calloutKind(kind: []const u8) CalloutStyle {
    const table = [_]struct { []const u8, CalloutStyle }{
        .{ "note", .{ .label = "Note", .icon = "ℹ", .color = .info } },
        .{ "info", .{ .label = "Info", .icon = "ℹ", .color = .info } },
        .{ "tip", .{ .label = "Tip", .icon = "✦", .color = .success } },
        .{ "important", .{ .label = "Important", .icon = "!", .color = .accent } },
        .{ "warning", .{ .label = "Warning", .icon = "⚠", .color = .warning } },
        .{ "caution", .{ .label = "Caution", .icon = "⚠", .color = .danger } },
        .{ "danger", .{ .label = "Danger", .icon = "⚠", .color = .danger } },
        .{ "todo", .{ .label = "To do", .icon = "☐", .color = .accent } },
    };
    for (table) |t| if (std.ascii.eqlIgnoreCase(kind, t[0])) return t[1];
    return table[0][1];
}

/// A task list checkbox: read-only unless the view has `on_task_toggle`.
pub const TaskBox = struct {
    /// Shown in snapshots.
    pub const name = "md_task";

    /// The item and its state.
    pub const Props = struct {
        view: *MdViewState,
        item: u32,
        checked: bool,
        read_only: bool,
        size: f32,
    };

    /// A square one line tall.
    pub fn style(props: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        const side = @round(props.size * 1.3);
        return .{ .w = .{ .px = side }, .h = .{ .px = side }, .shrink = 0, .padding = .all(@round(props.size * 0.15)) };
    }

    /// The box, filled with a check when done.
    pub fn paint(pc: *paint_cx.PaintCx, props: *const Props, _: *widget.NoState) void {
        const r = pc.bounds().inset(pc.style.padding);
        const rad = pc.dim(.radius_sm);
        if (props.checked) {
            pc.fill(r, .control_checked, rad);
            const st: TextStyle = .{ .size = r.h * 0.9 };
            pc.textBox("✓", st, pc.color(.fg_on_accent), r, false, .center);
        } else {
            pc.fill(r, .control_bg, rad);
            pc.border(r, pc.dim(.border_w), pc.color(.control_border), rad);
        }
        pc.focusRing(r, rad);
    }

    /// Click toggles through the callback.
    pub fn event(ec: *event_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const event_mod.InputEvent) bool {
        switch (ev.*) {
            .pointer_up => |pu| {
                if (pu.button != .left or props.read_only) return false;
                if (!ec.rect().contains(pu.pos)) return false;
                const cb = props.view.props.on_task_toggle orelse return false;
                cb.f(cb.ctx, taskOffset(props.view.doc, props.item), !props.checked);
                return true;
            },
            .pointer_move => {
                ec.setCursor(if (props.read_only) .default else .pointer);
                return false;
            },
            else => return false,
        }
    }

    /// A checkbox.
    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .checkbox, .name = "Task", .checked = props.checked, .disabled = props.read_only };
    }
};

/// The source offset of a task item's `[`.
pub fn taskOffset(d: *const Doc, item: u32) u32 {
    const b = d.blocks.items[item];
    const src = d.src.items;
    var i: usize = b.src[0];
    while (i < src.len and src[i] != '[' and src[i] != '\n') i += 1;
    return @intCast(i);
}

/// Sizes the virtual list: estimates for new rows, then the laid-out
/// height of each row built last time.
fn updateHeights(s: *MdViewState, ui: *Ui, tops: []const u32, b: *const Builder) void {
    const win = ui.window();
    if (s.heights.len() > tops.len) s.heights.resize(tops.len, 0) catch return;
    if (s.heights.len() < tops.len) {
        const old = s.heights.len();
        s.heights.resize(tops.len, 0) catch return;
        for (old..tops.len) |i| s.heights.set(i, estimate(s, tops[i], b));
    }
    for (s.rows.items) |r| {
        if (r.row >= tops.len or !win.store.valid(r.node)) continue;
        const h = win.store.relRect(r.node).h;
        if (h > 0 and @abs(h - s.heights.get(r.row)) > 0.5) s.heights.set(r.row, h);
    }
}

/// An estimated height before a block is laid out: its text's lines at
/// the view width.
fn estimate(s: *MdViewState, i: u32, b: *const Builder) f32 {
    const d = s.doc;
    const blk = d.blocks.items[i];
    const lh = b.ts.metrics(b.base).line_h;
    const chars: f32 = @floatFromInt(blk.src[1] -| blk.src[0]);
    const per_line = @max(1, b.p.max_width / (b.base.size * 0.55));
    const lines = switch (blk.kind) {
        .code_fenced, .code_indented => @as(f32, @floatFromInt(blk.line[1] -| blk.line[0] + 1)) + 1.5,
        .thematic_break => 0.5,
        else => @ceil(chars / per_line),
    };
    return @max(1, lines) * lh + b.gap();
}

test {
    std.testing.refAllDecls(@This());
}
