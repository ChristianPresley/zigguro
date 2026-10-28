//! EditorView: the per-view state of an open document (selections, scroll,
//! undo, the highlighter and decorations it shows) and the editing
//! operations the editor widget (`widget.zig`) runs on it.
//!
//! This is the first cut of E05.F05.S02.T02/T04: unwrapped rows (no display
//! map yet), laid out through the E04 `TextSystem` with tabs expanded to
//! `tab_size` columns, and the core editing commands. A system that shapes
//! (zg_text's `TextLayout`) gives each row's caret stops, so kerning,
//! ligatures, combining marks and fallback fonts place carets and hit
//! tests where the glyphs are drawn (`Options.shape_text`); otherwise
//! rows use per-codepoint advances. Every
//! edit goes through `Document.applyChangeSet` and the undo tree. Edits
//! from elsewhere (agents, reload) map the selections through the change.
//!
//! The selections are the model's `SelectionSet`, so the multi-cursor
//! commands of `model/edit/multi_cursor.zig` (add cursor above/below,
//! next/all occurrences, split into lines, box selection, cursor undo)
//! run on the view directly; box selection and vertical cursors measure
//! rows through the view's `displayMap` (unwrapped lines, pixel x).
//!
//! Smart typing (`Options.smart_typing`): typed characters, Enter and
//! Backspace run the model's `smart_edit` commands with the document's
//! language rules: auto-closed and surrounding pairs, typing over an
//! auto-inserted closer, electric re-indent, auto-indent (in the indent
//! unit guessed when the view opened) and pair-aware delete. Their changes
//! are captured from the document's change events and recorded as one undo
//! step each.
//!
//! Decorations (`decorations`): highlights, underlines and strikes paint
//! over the text; `inline_before`/`inline_after` texts (ghost text, a
//! pending change's one-line insert) are drawn in the row and shift the
//! text after them; `block_above`/`block_below` reserve `rows` line
//! heights above or below their line. Positions, hit tests and scrolling
//! go through `lineTop`/`lineAtY`, which count the blocks. A block's
//! content comes from `block_painter`, or from a widget the host places at
//! `blockRect` (the inline-edit prompt bar).
//!
//! Modal input (`mode`, e.g. a `VimState`): the widget offers keys to the
//! mode first (`modeKey`); keys it passes through get the normal
//! handling. The mode edits through a `modes.Host` built from the view
//! and records its own undo steps; the caret takes its shape.

const std = @import("std");
const zg_gui = @import("zg_gui");
const document = @import("../model/document.zig");
const pt = @import("../model/buffer/piece_tree.zig");
const cs_mod = @import("../model/edit/change_set.zig");
const sel_mod = @import("../model/edit/selection.zig");
const undo_mod = @import("../model/edit/undo.zig");
const syntax_mod = @import("../model/syntax.zig");
const deco_store = @import("../model/decorations/store.zig");
const multi = @import("../model/edit/multi_cursor.zig");
const gutter = @import("gutter.zig");
const smart = @import("../model/edit/smart_edit.zig");
const indent_mod = @import("../model/edit/indent.zig");
const modes = @import("../modes.zig");

const Allocator = std.mem.Allocator;
const Document = document.Document;
const PieceTree = pt.PieceTree;
const ChangeSet = cs_mod.ChangeSet;
const Range = cs_mod.Range;
const Replace = cs_mod.Replace;
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const UndoTree = undo_mod.UndoTree;
const CoalesceKey = undo_mod.CoalesceKey;
const TextSystem = zg_gui.paint.TextSystem;
const TextStyle = zg_gui.paint.text.TextStyle;
const CaretStop = zg_gui.paint.text.CaretStop;

/// The caret stops of the last shaped row (one entry: rows are measured
/// many times in a row while painting or hit testing).
const RowCarets = struct {
    hash: u64 = 0,
    len: usize = 0,
    style: TextStyle = .{},
    tab_w: f32 = 0,
    valid: bool = false,
    stops: std.ArrayList(CaretStop) = .empty,
};
const Vec2 = zg_gui.core.Vec2;
const Size = zg_gui.core.Size;
const Color = zg_gui.core.Color;

/// View settings (the `editor.*` settings E15 will feed in).
pub const Options = struct {
    tab_size: u8 = 4,
    /// Tab inserts spaces.
    insert_spaces: bool = true,
    line_numbers: bool = true,
    font_size: f32 = 13,
    read_only: bool = false,
    /// Typing, Enter and Backspace follow the language's pair and indent
    /// rules (see the module doc).
    smart_typing: bool = true,
    /// Shape rows when the text system can (see the module doc).
    shape_text: bool = true,
};

/// Maps a decoration's `StyleRef` to a colour (E15 theme tokens); null
/// uses the view's default for that kind.
pub const StyleResolver = struct {
    ctx: ?*anyopaque = null,
    color: *const fn (ctx: ?*anyopaque, style: deco_store.StyleRef) ?Color,
};

/// Told after the document changed under the view (not by the view's own
/// editing), so the owner can mark the window dirty.
pub const ChangeHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, v: *EditorView) void,
};

/// Offered each key press before the mode and the editor's own keys
/// (inline completions take Tab and Escape this way). Returning true
/// consumes the key.
pub const KeyHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, v: *EditorView, k: zg_gui.input.event.KeyPress) bool,
};

/// Told where the pointer rests and of Ctrl/Cmd+clicks and key presses,
/// for hover popups and go to definition (E07). Offsets are null where
/// no text is (past a line's end, below the last line).
pub const PointerHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, v: *EditorView, e: PointerEvent) bool,
};

/// Told of a plain left click on a gutter mark lane, on document line
/// `line` (0-based): lane 0 holds diagnostics and breakpoints, lane 1
/// the lightbulb. Returning true consumes the click; otherwise it selects
/// as a click on the line would.
pub const GutterHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, v: *EditorView, line: u64, lane: u8) bool,
};

/// What `PointerHook` hears. `origin` is the text origin in window
/// coordinates (`posOf` plus `origin` places an offset in the window).
pub const PointerEvent = struct {
    kind: Kind,
    offset: ?u64 = null,
    origin: Vec2 = .{},
    mods: @FieldType(zg_gui.input.event.KeyPress, "mods") = .{},
    /// The key pressed (`kind == .key`).
    key: ?zg_gui.input.event.KeyPress = null,
    /// The text typed (`kind == .text` and `.typed`).
    text: []const u8 = "",
    /// The block clicked (`kind == .block`), and the click's x from the
    /// block's left edge.
    block: ?BlockInfo = null,
    block_x: f32 = 0,

    pub const Kind = enum {
        /// The pointer moved over the text (not while dragging).
        move,
        /// The pointer left the editor.
        leave,
        /// A left click with Ctrl or Cmd held; returning true consumes it.
        click,
        /// A key press, before anything else sees it (returning true
        /// consumes it; Escape hides a hover this way).
        key,
        /// Text is about to be typed (returning true consumes it: a
        /// completion's commit character accepts it first).
        text,
        /// Text was typed (completion and signature help triggers).
        typed,
        /// A left click on a block row (code lens titles); returning
        /// true consumes it.
        block,
    };
};

/// Horizontal moves.
pub const Unit = enum { char, word };

/// A block row group, as `BlockPainter` and `blocks` see it.
pub const BlockInfo = struct {
    owner: deco_store.OwnerId,
    payload: u64,
    /// Above its line (else below).
    above: bool,
    line: u64,
    rows: u32,
};

/// Paints the content of block decorations (deleted lines, accept and
/// reject rows). `rect` is in the editor node's coordinates.
pub const BlockPainter = struct {
    ctx: ?*anyopaque = null,
    paint: *const fn (ctx: ?*anyopaque, pc: *zg_gui.paint.PaintCx, rect: zg_gui.core.Rect, b: BlockInfo) void,
};

/// A `BlockPainter` for the blocks of one decoration owner.
pub const OwnerPainter = struct { owner: deco_store.OwnerId, painter: BlockPainter };

/// Text drawn inside a row at `offset` (`after`: the caret at `offset`
/// stays before it).
pub const Inlay = struct {
    offset: u64,
    text: []const u8,
    style: deco_store.StyleRef,
    after: bool,
    /// Its width, set by `rowInlays`.
    w: f32 = 0,
};

/// Most inlays laid out per row.
pub const max_row_inlays = 16;

/// The changes a model command made, from the document's change events:
/// composed forward and inverse ChangeSets.
const Capture = struct {
    fwd: ?ChangeSet = null,
    inv: ?ChangeSet = null,
    failed: bool = false,

    fn add(c: *Capture, gpa: Allocator, ev: *const document.ChangeEvent) void {
        c.addOrFail(gpa, ev) catch {
            c.failed = true;
        };
    }

    fn addOrFail(c: *Capture, gpa: Allocator, ev: *const document.ChangeEvent) !void {
        var f = try ev.changes.clone(gpa);
        errdefer f.deinit();
        var i = try ev.changes.invert(ev.before, gpa);
        errdefer i.deinit();
        if (c.fwd) |*pf| {
            const nf = try pf.compose(&f, gpa);
            var nf_owned = nf;
            errdefer nf_owned.deinit();
            // Undo the newest change first.
            const ni = try i.compose(&c.inv.?, gpa);
            pf.deinit();
            c.inv.?.deinit();
            f.deinit();
            i.deinit();
            c.fwd = nf;
            c.inv = ni;
        } else {
            c.fwd = f;
            c.inv = i;
        }
    }

    fn deinit(c: *Capture) void {
        if (c.fwd) |*f| f.deinit();
        if (c.inv) |*i| i.deinit();
    }
};

/// See the module doc.
pub const EditorView = struct {
    gpa: Allocator,
    doc: *Document,
    listener: document.ListenerId,
    /// Sorted by start and non-overlapping; the primary is the one
    /// scrolled into view.
    sels: SelectionSet,
    undo: UndoTree,
    /// Highlighting, fed this document's changes by the view (one view
    /// per `DocumentSyntax`). Not owned.
    syntax: ?*syntax_mod.DocumentSyntax = null,
    /// Decorations to draw (fed by its own listener). Not owned.
    decorations: ?*const deco_store.DecorationStore = null,
    styles: ?StyleResolver = null,
    /// Names of highlight ids beyond the fixed set (LSP semantic token
    /// types, from E07's legend), so they colour like their ancestors.
    /// Not owned.
    hl_names: ?*const @import("zg_syntax").HighlightNames = null,
    /// Closers auto-inserted by smart typing (cleared when the caret
    /// jumps).
    auto_pairs: smart.AutoPairs,
    /// The document's indentation unit, guessed when the view opened.
    indent_unit: ?indent_mod.IndentUnit = null,
    /// Collects the changes of a running model command (`runSmart`).
    capture: ?*Capture = null,
    /// Offered every key press before `mode` (release events are not).
    key_hook: ?KeyHook = null,
    /// Told of pointer moves, Ctrl+clicks and key presses (hover).
    pointer_hook: ?PointerHook = null,
    /// Offered pointer moves, leaves and key presses before
    /// `pointer_hook` (the debugger's hover, E07): a move it returns true
    /// for reaches `pointer_hook` as a leave, so the language hover gives
    /// way; a key it returns true for goes no further.
    priority_hook: ?PointerHook = null,
    /// Told of clicks on the gutter's mark lanes (breakpoints, E07).
    gutter_hook: ?GutterHook = null,
    /// A modal input handler (Vim) offered every key first. Not owned.
    mode: ?modes.ModeHandler = null,
    /// Where the mode sends `:w`, `:q`, `C-x C-s` and other file and
    /// workbench commands (null: they report an error). Not owned.
    mode_actions: ?modes.mode.Actions = null,
    /// The SCM bar's hunks (a dirty diff); none: no bar. Not owned.
    scm: ?gutter.ScmGutterSource = null,
    on_change: ?ChangeHook = null,
    /// Called when the primary caret moved or the number of selections
    /// changed (a status bar's position).
    on_caret: ?ChangeHook = null,
    /// The caret `on_caret` last reported.
    seen_head: u64 = 0,
    seen_sels: usize = 1,
    opts: Options,
    /// Content scroll offset in pixels.
    scroll: Vec2 = .{},
    /// Bumped on every visible change; part of the widget's paint hash.
    generation: u64 = 0,
    /// The text system and the text area size from the last paint or
    /// event; geometry before the first paint uses a 8x16 fallback.
    text_sys: ?TextSystem = null,
    viewport: Size = .{ .w = 0, .h = 0 },
    /// Width of the line-number gutter at the last paint.
    gutter_w: f32 = 0,
    /// Wall time for undo grouping (ms), set by the widget.
    now_ms: u64 = 0,
    scratch: std.ArrayList(u8) = .empty,
    in_edit: bool = false,
    /// The document changed outside this view's undo history (an agent
    /// or LSP edit) since it was last seen clean, so the undo tree's saved
    /// marker no longer says whether the text matches the disk.
    foreign: bool = false,
    /// Paints block decorations' content (none: blocks stay empty).
    block_painter: ?BlockPainter = null,
    /// Painters for one owner's blocks (code lens rows), tried before
    /// `block_painter`; see `setOwnerPainter`.
    owner_painters: [4]?OwnerPainter = @splat(null),
    /// The window and node the editor widget was last built as
    /// (`focusEditor`).
    ui_window: ?*zg_gui.Window = null,
    ui_node: zg_gui.core.NodeId = .none,
    /// Block decorations by line (`ensureBlocks`), and the running sum of
    /// their heights: `block_cum[i]` is the height of `blocks[0..i]`.
    blocks: std.ArrayList(BlockInfo) = .empty,
    /// See `RowCarets` (behind a pointer: measuring takes a const view).
    row_carets: *RowCarets = undefined,
    block_cum: std.ArrayList(f32) = .empty,
    blocks_key: [5]u64 = .{ 0, 0, 0, 0, 0 },

    /// A view on `doc` with a caret at the start.
    pub fn init(gpa: Allocator, doc: *Document, opts: Options) !*EditorView {
        const v = try gpa.create(EditorView);
        errdefer gpa.destroy(v);
        const rc = try gpa.create(RowCarets);
        errdefer gpa.destroy(rc);
        rc.* = .{};
        v.* = .{ .gpa = gpa, .doc = doc, .listener = undefined, .sels = try .init(gpa, .caret(0)), .undo = .init(gpa, .{}), .opts = opts, .auto_pairs = .{ .gpa = gpa }, .row_carets = rc };
        errdefer v.undo.deinit();
        errdefer v.sels.deinit();
        v.listener = try doc.subscribe(.{ .ctx = v, .onChange = onDocChange });
        var snap = doc.snapshot();
        defer snap.release();
        v.indent_unit = indent_mod.guess(&snap);
        return v;
    }

    /// Unsubscribes and frees the view (not the document).
    pub fn deinit(v: *EditorView) void {
        v.doc.unsubscribe(v.listener);
        v.sels.deinit();
        v.undo.deinit();
        v.auto_pairs.deinit();
        v.scratch.deinit(v.gpa);
        v.blocks.deinit(v.gpa);
        v.block_cum.deinit(v.gpa);
        v.row_carets.stops.deinit(v.gpa);
        v.gpa.destroy(v.row_carets);
        v.gpa.destroy(v);
    }

    fn tree(v: *const EditorView) *const PieceTree {
        return &v.doc.tree;
    }

    /// Number of lines (at least 1).
    pub fn lineCount(v: *const EditorView) u64 {
        return v.tree().lineCount();
    }

    /// Byte range of `line` without its terminator.
    pub fn lineRange(v: *const EditorView, line: u64) Range {
        const r = v.tree().lineRange(line);
        return .{ .start = r.start, .end = r.end };
    }

    /// The line holding offset `off`.
    pub fn lineOf(v: *const EditorView, off: u64) u64 {
        return v.tree().lineOf(off);
    }

    /// The text of `range`, valid until the next call.
    pub fn text(v: *EditorView, range: Range) []const u8 {
        v.scratch.clearRetainingCapacity();
        v.scratch.ensureTotalCapacity(v.gpa, @intCast(range.len())) catch return "";
        var it = v.tree().slice(range);
        while (it.next()) |chunk| v.scratch.appendSliceAssumeCapacity(chunk);
        return v.scratch.items;
    }

    /// The whole document (caller frees).
    pub fn allText(v: *const EditorView, gpa: Allocator) ![]u8 {
        return v.tree().copyRange(gpa, .{ .start = 0, .end = v.doc.len() });
    }

    /// The primary selection.
    pub fn primarySel(v: *const EditorView) Selection {
        return v.sels.primary();
    }

    /// The selections, sorted.
    pub fn selections(v: *const EditorView) []const Selection {
        return v.sels.slice();
    }

    /// The primary selection, to change in place (call `normalize`
    /// after).
    pub fn primaryPtr(v: *EditorView) *Selection {
        return &v.sels.items.items[v.sels.primaryIndex()];
    }

    fn touch(v: *EditorView) void {
        v.generation +%= 1;
        const head = v.primarySel().head;
        const n = v.sels.items.items.len;
        if (head == v.seen_head and n == v.seen_sels) return;
        v.seen_head = head;
        v.seen_sels = n;
        if (v.on_caret) |h| h.f(h.ctx, v);
    }

    fn onDocChange(ctx: *anyopaque, ev: *const document.ChangeEvent) void {
        const v: *EditorView = @ptrCast(@alignCast(ctx));
        if (v.syntax) |ds| ds.onChange(ev, &v.doc.tree, null) catch {};
        if (v.capture) |c| c.add(v.gpa, ev);
        if (v.in_edit) return;
        if (ev.origin != .reload) v.foreign = true;
        for (v.sels.items.items) |*s| s.* = s.map(ev.changes);
        v.normalize();
        v.touch();
        if (v.on_change) |h| h.f(h.ctx, v);
    }

    // -- geometry ----------------------------------------------------------

    /// The editor's text style.
    pub fn textStyle(v: *const EditorView) TextStyle {
        return .{ .font = .mono, .size = v.opts.font_size, .shape = v.opts.shape_text };
    }

    /// The caret stops of row text `s` when the text system shapes it,
    /// else null (per-codepoint advances).
    fn rowCarets(v: *const EditorView, s: []const u8) ?[]const CaretStop {
        const ts = v.text_sys orelse return null;
        const st = v.textStyle();
        if (!ts.shapes(st) or ts.vtable.carets == null) return null;
        const tab_w = v.spaceW() * @as(f32, @floatFromInt(v.opts.tab_size));
        const c = v.row_carets;
        const h = std.hash.Wyhash.hash(0, s);
        if (c.valid and c.hash == h and c.len == s.len and c.tab_w == tab_w and std.meta.eql(c.style, st)) return c.stops.items;
        c.valid = false;
        const got = ts.carets(st, s, tab_w) orelse return null;
        c.stops.clearRetainingCapacity();
        c.stops.appendSlice(v.gpa, got) catch return null;
        c.* = .{ .hash = h, .len = s.len, .style = st, .tab_w = tab_w, .valid = true, .stops = c.stops };
        return c.stops.items;
    }

    /// Row height in pixels.
    pub fn lineHeight(v: *const EditorView) f32 {
        const ts = v.text_sys orelse return 16;
        return ts.metrics(v.textStyle()).line_h;
    }

    fn advance(v: *const EditorView, cp: u21) f32 {
        const ts = v.text_sys orelse return 8;
        return ts.advance(v.textStyle(), cp);
    }

    fn spaceW(v: *const EditorView) f32 {
        return v.advance(' ');
    }

    /// The x of byte `col` in line text `s` (tabs to the next stop).
    pub fn xInLine(v: *const EditorView, s: []const u8, col: usize) f32 {
        if (v.rowCarets(s)) |stops| {
            // The stop at `col`, or the grapheme it is inside.
            var lo: usize = 0;
            var hi: usize = stops.len;
            while (hi - lo > 1) {
                const mid = (lo + hi) / 2;
                if (stops[mid].offset <= col) lo = mid else hi = mid;
            }
            return if (stops.len > 0) stops[lo].x else 0;
        }
        const sw = v.spaceW();
        const tab_w = sw * @as(f32, @floatFromInt(v.opts.tab_size));
        var x: f32 = 0;
        var i: usize = 0;
        while (i < @min(col, s.len)) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            if (s[i] == '\t') {
                x = (@floor(x / tab_w + 0.001) + 1) * tab_w;
            } else {
                const cp = std.unicode.utf8Decode(s[i..@min(s.len, i + n)]) catch 0xfffd;
                x += v.advance(cp);
            }
            i += n;
        }
        return x;
    }

    /// The byte column in line text `s` nearest to `x`.
    pub fn colAt(v: *const EditorView, s: []const u8, x: f32) usize {
        if (v.rowCarets(s)) |stops| {
            // The nearest stop (right-to-left runs are not monotonic in x).
            var best: usize = s.len;
            var best_d = std.math.inf(f32);
            for (stops) |c| {
                const d = @abs(c.x - x);
                if (d < best_d) {
                    best_d = d;
                    best = c.offset;
                }
            }
            return best;
        }
        const sw = v.spaceW();
        const tab_w = sw * @as(f32, @floatFromInt(v.opts.tab_size));
        var cx: f32 = 0;
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const w = if (s[i] == '\t')
                (@floor(cx / tab_w + 0.001) + 1) * tab_w - cx
            else
                v.advance(std.unicode.utf8Decode(s[i..@min(s.len, i + n)]) catch 0xfffd);
            if (x < cx + w / 2) return i;
            cx += w;
            i += n;
        }
        return s.len;
    }

    /// The offset nearest to `p`, in text-area coordinates (scroll applied
    /// by the caller is not: `p` is relative to the text origin).
    pub fn offsetAt(v: *EditorView, p: Vec2) u64 {
        if (p.y < 0) return 0;
        const line = v.lineAtY(p.y);
        if (p.y >= v.lineTop(line) + v.lineHeight() and line + 1 >= v.lineCount()) return v.doc.len();
        const r = v.lineRange(line);
        var inl: [max_row_inlays]Inlay = undefined;
        const ins = v.rowInlays(r, &inl);
        const s = v.text(r);
        return r.start + v.colAtInlays(s, r.start, ins, p.x);
    }

    /// The text-origin position of offset `off` (top of its row).
    pub fn posOf(v: *EditorView, off: u64) Vec2 {
        const line = v.lineOf(off);
        const r = v.lineRange(line);
        var inl: [max_row_inlays]Inlay = undefined;
        const ins = v.rowInlays(r, &inl);
        const s = v.text(r);
        return .{ .x = v.xInLine(s, @intCast(off - r.start)) + inlayShift(ins, off), .y = v.lineTop(line) };
    }

    /// Lines `[first, last]` intersecting the viewport.
    pub fn visibleLines(v: *EditorView) [2]u64 {
        const first = v.lineAtY(@max(0, v.scroll.y));
        const last = @min(v.lineCount() - 1, v.lineAtY(v.scroll.y + @max(v.viewport.h, 1)) + 1);
        return .{ @min(first, last), last };
    }

    /// Clamps the scroll offset to the content.
    pub fn clampScroll(v: *EditorView) void {
        // One screen of overscroll past the last line, like most editors.
        const max_y = @max(0, v.lineTop(v.lineCount() - 1));
        v.scroll.y = std.math.clamp(v.scroll.y, 0, max_y);
        v.scroll.x = @max(0, v.scroll.x);
    }

    /// Scrolls by `d` pixels.
    pub fn scrollBy(v: *EditorView, d: Vec2) void {
        v.scroll.x += d.x;
        v.scroll.y += d.y;
        v.clampScroll();
        v.touch();
    }

    /// Scrolls so `line` is the first visible row.
    pub fn scrollToLine(v: *EditorView, line: u64) void {
        v.scroll.y = v.lineTop(@min(line, v.lineCount() - 1));
        v.clampScroll();
        v.touch();
    }

    /// Scrolls the primary caret into view.
    pub fn revealPrimary(v: *EditorView) void {
        if (v.viewport.h <= 0) return;
        const lh = v.lineHeight();
        const p = v.posOf(v.primarySel().head);
        if (p.y < v.scroll.y) v.scroll.y = p.y;
        if (p.y + lh > v.scroll.y + v.viewport.h) v.scroll.y = p.y + lh - v.viewport.h;
        const margin = @min(4 * v.spaceW(), v.viewport.w / 3);
        if (p.x - v.scroll.x < margin) v.scroll.x = @max(0, p.x - margin);
        if (p.x - v.scroll.x > v.viewport.w - margin) v.scroll.x = p.x - v.viewport.w + margin;
        v.clampScroll();
        v.touch();
    }

    /// Scrolls so the lines of `range`, with the blocks above its first
    /// line (a prompt bar), are in view; the top wins when they don't fit.
    pub fn revealRange(v: *EditorView, range: Range) void {
        if (v.viewport.h <= 0) return;
        const first = v.lineOf(range.start);
        const last = v.lineOf(range.end);
        const top = v.blocksTop(first);
        const bottom = v.lineTop(last) + v.lineHeight();
        if (bottom > v.scroll.y + v.viewport.h) v.scroll.y = bottom - v.viewport.h;
        if (top < v.scroll.y) v.scroll.y = top;
        v.clampScroll();
        v.touch();
    }

    // -- blocks and inlays ---------------------------------------------------

    /// Rebuilds `blocks` when the decorations, the document or the line
    /// height changed.
    fn ensureBlocks(v: *EditorView) void {
        const ds = v.decorations orelse {
            v.blocks.clearRetainingCapacity();
            v.block_cum.clearRetainingCapacity();
            return;
        };
        const lh = v.lineHeight();
        const key: [5]u64 = .{ @intFromPtr(ds), ds.inline_generation, v.doc.version, v.lineCount(), @as(u32, @bitCast(lh)) };
        if (std.mem.eql(u64, &key, &v.blocks_key)) return;
        v.blocks_key = key;
        v.blocks.clearRetainingCapacity();
        v.block_cum.clearRetainingCapacity();
        var refs: std.ArrayList(deco_store.DecoRef) = .empty;
        defer refs.deinit(v.gpa);
        var mask: deco_store.KindMask = .initEmpty();
        mask.insert(.block_above);
        mask.insert(.block_below);
        ds.query(.{ .start = 0, .end = v.doc.len() }, mask, v.gpa, &refs) catch {
            v.blocks_key[0] = 0;
            return;
        };
        for (refs.items) |r| {
            const above = r.deco.kind == .block_above;
            const spec = switch (r.deco.kind) {
                .block_above, .block_below => |b| b,
                else => continue,
            };
            if (spec.rows == 0) continue;
            const line = v.lineOf(if (above) r.range.start else r.range.end);
            v.blocks.append(v.gpa, .{ .owner = r.deco.owner, .payload = spec.payload, .above = above, .line = line, .rows = spec.rows }) catch break;
        }
        // By line; above blocks before the line's text, below ones after.
        std.sort.insertion(BlockInfo, v.blocks.items, {}, struct {
            fn lt(_: void, a: BlockInfo, b: BlockInfo) bool {
                return blockKey(a) < blockKey(b);
            }
        }.lt);
        v.block_cum.ensureTotalCapacity(v.gpa, v.blocks.items.len + 1) catch {
            v.blocks.clearRetainingCapacity();
            return;
        };
        var sum: f32 = 0;
        v.block_cum.appendAssumeCapacity(0);
        for (v.blocks.items) |b| {
            sum += @as(f32, @floatFromInt(b.rows)) * lh;
            v.block_cum.appendAssumeCapacity(sum);
        }
    }

    fn blockKey(b: BlockInfo) u64 {
        return b.line * 2 + @intFromBool(!b.above);
    }

    /// How many blocks sort before key `k`.
    fn blocksBefore(v: *const EditorView, k: u64) usize {
        var lo: usize = 0;
        var hi: usize = v.blocks.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (blockKey(v.blocks.items[mid]) < k) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// The y of `line`'s text row from the text origin (blocks above it
    /// included).
    pub fn lineTop(v: *EditorView, line: u64) f32 {
        v.ensureBlocks();
        const base = @as(f32, @floatFromInt(line)) * v.lineHeight();
        if (v.blocks.items.len == 0) return base;
        return base + v.block_cum.items[v.blocksBefore(line * 2 + 1)];
    }

    /// The y where `line`'s blocks above start (its text row's top when it
    /// has none).
    pub fn blocksTop(v: *EditorView, line: u64) f32 {
        v.ensureBlocks();
        const base = @as(f32, @floatFromInt(line)) * v.lineHeight();
        if (v.blocks.items.len == 0) return base;
        return base + v.block_cum.items[v.blocksBefore(line * 2)];
    }

    /// The line whose text row is at or above `y` (a block's area maps to
    /// the line before it).
    pub fn lineAtY(v: *EditorView, y: f32) u64 {
        const n = v.lineCount();
        v.ensureBlocks();
        if (v.blocks.items.len == 0) {
            const f = @floor(@max(0, y) / v.lineHeight());
            return @min(n - 1, @as(u64, @intFromFloat(@min(f, @as(f32, @floatFromInt(n))))));
        }
        var lo: u64 = 0;
        var hi: u64 = n;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (v.lineTop(mid) <= y) lo = mid else hi = mid;
        }
        return lo;
    }

    /// Paints `owner`'s blocks with `p` (null: no longer). False when
    /// every slot is taken.
    pub fn setOwnerPainter(v: *EditorView, owner: deco_store.OwnerId, p: ?BlockPainter) bool {
        for (&v.owner_painters) |*slot| if (slot.*) |op| if (op.owner == owner) {
            slot.* = if (p) |x| .{ .owner = owner, .painter = x } else null;
            return true;
        };
        const x = p orelse return true;
        for (&v.owner_painters) |*slot| if (slot.* == null) {
            slot.* = .{ .owner = owner, .painter = x };
            return true;
        };
        return false;
    }

    /// The painter for a block of `owner`.
    pub fn painterFor(v: *const EditorView, owner: deco_store.OwnerId) ?BlockPainter {
        for (v.owner_painters) |slot| if (slot) |op| if (op.owner == owner) return op.painter;
        return v.block_painter;
    }

    /// The block decorations, sorted by line (valid until the next
    /// geometry call).
    pub fn blockList(v: *EditorView) []const BlockInfo {
        v.ensureBlocks();
        return v.blocks.items;
    }

    /// Where block `i` of `blockList` is, in editor node coordinates.
    pub fn blockRectAt(v: *EditorView, i: usize) zg_gui.core.Rect {
        v.ensureBlocks();
        const b = v.blocks.items[i];
        const lh = v.lineHeight();
        var y = @as(f32, @floatFromInt(b.line)) * lh + v.block_cum.items[i];
        if (!b.above) y += lh;
        return .{ .x = v.gutter_w, .y = y - v.scroll.y, .w = v.viewport.w, .h = @as(f32, @floatFromInt(b.rows)) * lh };
    }

    /// The slot of `owner`'s block with `payload`, in editor node
    /// coordinates, for a widget the host places over the editor; null when
    /// there is no such block.
    pub fn blockRect(v: *EditorView, owner: deco_store.OwnerId, payload: u64) ?zg_gui.core.Rect {
        v.ensureBlocks();
        for (v.blocks.items, 0..) |b, i| if (b.owner == owner and b.payload == payload) return v.blockRectAt(i);
        return null;
    }

    /// The inline texts in line range `lr`, sorted by offset, with their
    /// widths.
    pub fn rowInlays(v: *EditorView, lr: Range, out: *[max_row_inlays]Inlay) []Inlay {
        const ds = v.decorations orelse return out[0..0];
        if (ds.inline_generation == 0) return out[0..0];
        var refs: std.ArrayList(deco_store.DecoRef) = .empty;
        defer refs.deinit(v.gpa);
        var mask: deco_store.KindMask = .initEmpty();
        mask.insert(.inline_before);
        mask.insert(.inline_after);
        ds.query(lr, mask, v.gpa, &refs) catch return out[0..0];
        var n: usize = 0;
        for (refs.items) |r| {
            if (n == out.len) break;
            const it, const after = switch (r.deco.kind) {
                .inline_before => |t| .{ t, false },
                .inline_after => |t| .{ t, true },
                else => continue,
            };
            const at = if (after) r.range.end else r.range.start;
            if (at < lr.start or at > lr.end) continue;
            out[n] = .{ .offset = at, .text = it.text, .style = it.style, .after = after, .w = v.textWidth(it.text) };
            n += 1;
        }
        return out[0..n];
    }

    /// Width of `s` without tabs.
    fn textWidth(v: *const EditorView, s: []const u8) f32 {
        if (v.text_sys) |ts| if (ts.shapes(v.textStyle())) return ts.width(v.textStyle(), s);
        var w: f32 = 0;
        var it = (std.unicode.Utf8View.init(s) catch return 0).iterator();
        while (it.nextCodepoint()) |cp| w += v.advance(cp);
        return w;
    }

    /// How far inlays push the text at document offset `off` right.
    pub fn inlayShift(ins: []const Inlay, off: u64) f32 {
        var w: f32 = 0;
        for (ins) |i| {
            if (i.offset < off or (i.offset == off and !i.after)) w += i.w;
        }
        return w;
    }

    /// The byte column in line text `s` (starting at document offset
    /// `start`) nearest to `x`, with `ins` in the row.
    fn colAtInlays(v: *const EditorView, s: []const u8, start: u64, ins: []const Inlay, x: f32) usize {
        if (ins.len == 0) return v.colAt(s, x);
        // Walk the columns: the shift only grows, so the first column past
        // `x` with its shift is the answer.
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const x0 = v.xInLine(s, i) + inlayShift(ins, start + i);
            const x1 = v.xInLine(s, i + n) + inlayShift(ins, start + i + n) - (if (inlayAt(ins, start + i + n)) |w| w else 0);
            if (x < (x0 + x1) / 2) return i;
            i += n;
        }
        return s.len;
    }

    /// The width of inlays drawn before the text at `off` (an
    /// `inline_before` there), which a click just left of `off` skips.
    fn inlayAt(ins: []const Inlay, off: u64) ?f32 {
        var w: f32 = 0;
        var any = false;
        for (ins) |i| if (i.offset == off and !i.after) {
            w += i.w;
            any = true;
        };
        return if (any) w else null;
    }

    /// Moves keyboard focus to the editor widget (after a prompt bar or
    /// popover over it closes).
    pub fn focusEditor(v: *EditorView) void {
        const w = v.ui_window orelse return;
        if (v.ui_node.isNone() or !w.store.valid(v.ui_node)) return;
        w.setFocus(v.ui_node, false);
    }

    // -- selections --------------------------------------------------------

    /// Sorts the selections and merges overlapping ones (touching carets
    /// merge, and so do a caret and a range it touches; touching ranges do
    /// not).
    pub fn normalize(v: *EditorView) void {
        if (v.sels.count() == 0) {
            v.sels.set(&.{.caret(0)}, 0) catch {};
            return;
        }
        const len = v.doc.len();
        for (v.sels.items.items) |*s| {
            s.anchor = @min(s.anchor, len);
            s.head = @min(s.head, len);
        }
        v.sels.normalize(.for_edit);
    }

    /// Replaces the selections with one caret or range.
    pub fn setSelection(v: *EditorView, s: Selection) void {
        v.sels.set(&.{s}, 0) catch {};
        v.normalize();
        v.undo.breakGroup();
        v.touch();
    }

    /// Adds a caret (Alt+click).
    pub fn addCaret(v: *EditorView, off: u64) void {
        v.sels.pushHistory() catch {};
        v.sels.add(.caret(off)) catch return;
        v.normalize();
        v.undo.breakGroup();
        v.touch();
    }

    /// Selects everything.
    pub fn selectAll(v: *EditorView) void {
        v.setSelection(.{ .anchor = 0, .head = v.doc.len() });
    }

    fn byteAt(v: *const EditorView, off: u64) u8 {
        return v.tree().byteAt(off);
    }

    fn isWordByte(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
    }

    /// The offset one code point before `off`.
    fn prevChar(v: *const EditorView, off: u64) u64 {
        if (off == 0) return 0;
        var p = off - 1;
        while (p > 0 and v.byteAt(p) & 0xc0 == 0x80) p -= 1;
        // A CRLF is one step.
        if (p > 0 and v.byteAt(p) == '\n' and v.byteAt(p - 1) == '\r') p -= 1;
        return p;
    }

    /// The offset one code point after `off`.
    fn nextChar(v: *const EditorView, off: u64) u64 {
        const len = v.doc.len();
        if (off >= len) return len;
        if (v.byteAt(off) == '\r' and off + 1 < len and v.byteAt(off + 1) == '\n') return off + 2;
        var p = off + 1;
        while (p < len and v.byteAt(p) & 0xc0 == 0x80) p += 1;
        return p;
    }

    /// The start of the word at or before `off` (skipping spaces first).
    fn prevWord(v: *const EditorView, off: u64) u64 {
        var p = off;
        while (p > 0 and std.ascii.isWhitespace(v.byteAt(p - 1)) and v.byteAt(p - 1) != '\n') p -= 1;
        if (p == 0) return 0;
        if (p == off and v.byteAt(p - 1) == '\n') return v.prevChar(p);
        const word = isWordByte(v.byteAt(p - 1));
        while (p > 0) {
            const c = v.byteAt(p - 1);
            if (std.ascii.isWhitespace(c) or isWordByte(c) != word) break;
            p -= 1;
        }
        return p;
    }

    /// The end of the word at or after `off` (skipping spaces first).
    fn nextWord(v: *const EditorView, off: u64) u64 {
        const len = v.doc.len();
        var p = off;
        while (p < len and std.ascii.isWhitespace(v.byteAt(p)) and v.byteAt(p) != '\n') p += 1;
        if (p >= len) return len;
        if (p == off and (v.byteAt(p) == '\n' or v.byteAt(p) == '\r')) return v.nextChar(p);
        const word = isWordByte(v.byteAt(p));
        while (p < len) {
            const c = v.byteAt(p);
            if (std.ascii.isWhitespace(c) or isWordByte(c) != word) break;
            p += 1;
        }
        return p;
    }

    /// The word (or run of punctuation, or of spaces) around `off`.
    pub fn wordRange(v: *const EditorView, off: u64) Range {
        const len = v.doc.len();
        if (len == 0) return .{ .start = 0, .end = 0 };
        const at = if (off < len and v.byteAt(off) != '\n') off else if (off > 0) off - 1 else 0;
        const c = v.byteAt(at);
        if (c == '\n') return .{ .start = off, .end = off };
        const Class = enum { word, space, punct };
        const class = struct {
            fn of(b: u8) Class {
                return if (isWordByte(b)) .word else if (b == ' ' or b == '\t') .space else .punct;
            }
        }.of;
        const k = class(c);
        var s = at;
        while (s > 0 and v.byteAt(s - 1) != '\n' and class(v.byteAt(s - 1)) == k) s -= 1;
        var e = at + 1;
        while (e < len and v.byteAt(e) != '\n' and v.byteAt(e) != '\r' and class(v.byteAt(e)) == k) e += 1;
        return .{ .start = s, .end = e };
    }

    /// The line around `off`, with its terminator.
    pub fn lineRangeWithEol(v: *const EditorView, off: u64) Range {
        const line = v.lineOf(off);
        const r = v.tree().lineRange(line);
        return .{ .start = r.start, .end = r.end + r.eol_len };
    }

    /// Moves every selection by one character or word; `extend` keeps the
    /// anchor. Without `extend`, a range collapses to its edge first.
    pub fn moveH(v: *EditorView, forward: bool, unit: Unit, extend: bool) void {
        for (v.sels.items.items) |*s| {
            if (!extend and !s.isCaret() and unit == .char) {
                s.* = .{ .anchor = if (forward) s.end() else s.start(), .head = if (forward) s.end() else s.start(), .id = s.id };
                continue;
            }
            const to = switch (unit) {
                .char => if (forward) v.nextChar(s.head) else v.prevChar(s.head),
                .word => if (forward) v.nextWord(s.head) else v.prevWord(s.head),
            };
            s.head = to;
            if (!extend) s.anchor = to;
            s.goal_x = null;
        }
        v.afterMove();
    }

    /// Moves every selection `lines` rows (negative is up), keeping the
    /// sticky x.
    pub fn moveV(v: *EditorView, lines: i64, extend: bool) void {
        const n = v.lineCount();
        for (v.sels.items.items) |*s| {
            const line = v.lineOf(s.head);
            const gx = s.goal_x orelse v.posOf(s.head).x;
            const target_i = @as(i64, @intCast(line)) + lines;
            const to: u64 = if (target_i < 0)
                0
            else if (target_i >= @as(i64, @intCast(n)))
                v.doc.len()
            else blk: {
                const r = v.lineRange(@intCast(target_i));
                break :blk r.start + v.colAt(v.text(r), gx);
            };
            s.head = to;
            if (!extend) s.anchor = to;
            s.goal_x = if (target_i < 0 or target_i >= @as(i64, @intCast(n))) null else gx;
        }
        v.afterMove();
    }

    /// Home: to the first non-blank, or to column 0 when already there.
    pub fn home(v: *EditorView, extend: bool) void {
        for (v.sels.items.items) |*s| {
            const r = v.lineRange(v.lineOf(s.head));
            var first = r.start;
            while (first < r.end and (v.byteAt(first) == ' ' or v.byteAt(first) == '\t')) first += 1;
            const to = if (s.head == first) r.start else first;
            s.head = to;
            if (!extend) s.anchor = to;
            s.goal_x = null;
        }
        v.afterMove();
    }

    /// End of line.
    pub fn end(v: *EditorView, extend: bool) void {
        for (v.sels.items.items) |*s| {
            const to = v.lineRange(v.lineOf(s.head)).end;
            s.head = to;
            if (!extend) s.anchor = to;
            s.goal_x = null;
        }
        v.afterMove();
    }

    /// Start or end of the document.
    pub fn docEdge(v: *EditorView, at_end: bool, extend: bool) void {
        const to: u64 = if (at_end) v.doc.len() else 0;
        const anchor = if (extend) v.primarySel().anchor else to;
        v.setSelection(.{ .anchor = anchor, .head = to });
        v.revealPrimary();
    }

    fn afterMove(v: *EditorView) void {
        v.auto_pairs.clear();
        v.normalize();
        v.undo.breakGroup();
        v.revealPrimary();
        v.touch();
    }

    // -- multi-cursor ------------------------------------------------------

    /// Rows and x for the model's box selection and vertical cursors: one
    /// row per line, x in pixels from the text origin.
    pub fn displayMap(v: *EditorView) multi.DisplayMapQuery {
        return .{ .ptr = v, .rowCountFn = dmRows, .hitTestFn = dmHit, .rowOfFn = dmRowOf };
    }

    fn dmRows(ptr: *anyopaque) u64 {
        const v: *EditorView = @ptrCast(@alignCast(ptr));
        return v.lineCount();
    }

    fn dmHit(ptr: *anyopaque, row: u64, x: f32) multi.Hit {
        const v: *EditorView = @ptrCast(@alignCast(ptr));
        const r = v.lineRange(@min(row, v.lineCount() - 1));
        const t = v.text(r);
        const col = v.colAt(t, x);
        const past = x - v.xInLine(t, t.len);
        const virtual: u32 = if (col == t.len and past > 0) @intFromFloat(@round(past / v.spaceW())) else 0;
        return .{ .offset = r.start + col, .virtual = virtual };
    }

    fn dmRowOf(ptr: *anyopaque, pos: u64) multi.RowPos {
        const v: *EditorView = @ptrCast(@alignCast(ptr));
        const p = v.posOf(pos);
        return .{ .row = v.lineOf(pos), .x = p.x };
    }

    /// The display position (row, x) of text-area point `p`.
    pub fn displayPosAt(v: *EditorView, p: Vec2) multi.DisplayPos {
        return .{ .row = v.lineAtY(@max(0, p.y)), .col_px = @max(0, p.x) };
    }

    /// Column (box) selection between two display positions.
    pub fn boxSelect(v: *EditorView, anchor: multi.DisplayPos, head: multi.DisplayPos) void {
        multi.boxToSelections(.{ .anchor = anchor, .head = head }, v.displayMap(), &v.sels) catch return;
        v.afterMove();
    }

    /// The commands of `multi_cursor.zig` the editor binds.
    pub const CursorCommand = enum { add_above, add_below, add_next_occurrence, skip_occurrence, select_all_occurrences, split_into_lines, collapse, undo_cursor };

    /// Runs `c`; false when it changed nothing.
    pub fn cursorCommand(v: *EditorView, c: CursorCommand) !bool {
        const changed = switch (c) {
            .add_above, .add_below => blk: {
                var snap = v.doc.snapshot();
                defer snap.release();
                break :blk try multi.addCursorVertical(&snap, &v.sels, if (c == .add_above) .up else .down, .{ .tab_size = v.opts.tab_size });
            },
            .add_next_occurrence => try multi.addNextOccurrence(v.doc, &v.sels, .{}),
            .skip_occurrence => try multi.skipOccurrence(v.doc, &v.sels, .{}),
            .select_all_occurrences => try multi.selectAllOccurrences(v.doc, &v.sels, .{}) > 0,
            .split_into_lines => blk: {
                var snap = v.doc.snapshot();
                defer snap.release();
                const n = v.sels.count();
                try multi.splitIntoLines(&snap, &v.sels);
                break :blk v.sels.count() != n;
            },
            .collapse => blk: {
                if (v.sels.count() <= 1) break :blk false;
                try multi.collapse(&v.sels);
                break :blk true;
            },
            .undo_cursor => try v.sels.undoCursorOp(),
        };
        if (changed) v.afterMove();
        return changed;
    }

    // -- editing -----------------------------------------------------------

    fn timestamp(v: *const EditorView) std.Io.Timestamp {
        return .{ .nanoseconds = @as(i96, v.now_ms) * std.time.ns_per_ms };
    }

    /// Applies one edit per selection (in selection order) and leaves a
    /// caret after each edit's text.
    fn applyPerSelection(v: *EditorView, edits: []const Replace, key: ?CoalesceKey) !void {
        std.debug.assert(edits.len == v.sels.count());
        if (v.opts.read_only) return;
        var nonempty = false;
        for (edits) |e| if (e.range.start != e.range.end or e.text.len > 0) {
            nonempty = true;
        };
        if (!nonempty) return;
        var cs = try ChangeSet.fromEdits(v.gpa, v.doc.len(), edits);
        var cs_owned = true;
        defer if (cs_owned) cs.deinit();
        var inverse = try cs.invert(v.doc.tree, v.gpa);
        var inv_owned = true;
        defer if (inv_owned) inverse.deinit();
        const before = try sel_mod.dupe(v.gpa, v.sels.slice());
        defer v.gpa.free(before);

        v.in_edit = true;
        defer v.in_edit = false;
        try v.doc.applyChangeSet(&cs, .{ .user = 0 });
        for (v.sels.items.items, edits) |*s, e| {
            const at = cs.mapPos(e.range.start, .left) + e.text.len;
            s.* = .{ .anchor = at, .head = at, .id = s.id };
        }
        v.sels.clearHistory();
        v.sels.word_search = false;
        v.normalize();
        cs_owned = false;
        inv_owned = false;
        try v.undo.record(cs, inverse, before, v.sels.slice(), .{ .origin = .{ .user = 0 }, .timestamp = v.timestamp(), .coalesce_key = key });
        v.revealPrimary();
        v.touch();
    }

    /// Applies `edits` (non-overlapping, any order) as one undo step of
    /// its own; selections follow the text. For inserts that are not
    /// typing: snippets, completions, snippet choices.
    pub fn applyEdits(v: *EditorView, edits: []const Replace) !void {
        if (v.opts.read_only) return error.ReadOnly;
        var cs = try ChangeSet.fromEdits(v.gpa, v.doc.len(), edits);
        var cs_owned = true;
        defer if (cs_owned) cs.deinit();
        if (cs.isIdentity()) return;
        var inverse = try cs.invert(v.doc.tree, v.gpa);
        var inv_owned = true;
        defer if (inv_owned) inverse.deinit();
        const before = try sel_mod.dupe(v.gpa, v.sels.slice());
        defer v.gpa.free(before);

        v.in_edit = true;
        defer v.in_edit = false;
        try v.doc.applyChangeSet(&cs, .{ .user = 0 });
        for (v.sels.items.items) |*s| {
            s.anchor = cs.mapPos(s.anchor, .right);
            s.head = cs.mapPos(s.head, .right);
        }
        v.sels.clearHistory();
        v.normalize();
        v.undo.breakGroup();
        cs_owned = false;
        inv_owned = false;
        try v.undo.record(cs, inverse, before, v.sels.slice(), .{ .origin = .{ .user = 0 }, .timestamp = v.timestamp(), .coalesce_key = null });
        v.undo.breakGroup();
        v.revealPrimary();
        v.touch();
    }

    /// Replaces the selections; `sels[primary]` becomes the primary.
    pub fn setSelections(v: *EditorView, sels: []const Selection, primary: usize) !void {
        try v.sels.set(sels, primary);
        v.afterMove();
    }

    /// Typed text: one character goes through smart typing (pairs,
    /// electric indent); anything longer (an IME commit) is inserted as
    /// is.
    pub fn typeText(v: *EditorView, t: []const u8) !void {
        if (v.opts.smart_typing and t.len > 0 and t.len == (std.unicode.utf8ByteSequenceLength(t[0]) catch 0) and t[0] != '\n') {
            const cp = std.unicode.utf8Decode(t) catch return v.insertText(t);
            const space = cp == ' ' or cp == '\t';
            return v.runSmart(.{ .type_char = cp }, if (space) .typing_space else .typing_word);
        }
        return v.insertText(t);
    }

    /// Types `t` over every selection.
    pub fn insertText(v: *EditorView, t: []const u8) !void {
        const edits = try v.gpa.alloc(Replace, v.sels.count());
        defer v.gpa.free(edits);
        for (v.sels.slice(), edits) |s, *e| e.* = .{ .range = s.range(), .text = t };
        const space = t.len > 0 and std.mem.indexOfNone(u8, t, " \t") == null;
        const key: ?CoalesceKey = if (std.mem.indexOfScalar(u8, t, '\n') != null) null else if (space) .typing_space else .typing_word;
        try v.applyPerSelection(edits, key);
    }

    /// Inserts a line break that keeps the current line's indentation
    /// (smart typing: indents after openers and splits a bracket pair).
    pub fn newline(v: *EditorView) !void {
        if (v.opts.smart_typing) {
            v.undo.breakGroup();
            return v.runSmart(.newline, null);
        }
        var arena: std.heap.ArenaAllocator = .init(v.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const edits = try a.alloc(Replace, v.sels.count());
        for (v.sels.slice(), edits) |s, *e| {
            const r = v.lineRange(v.lineOf(s.start()));
            var i = r.start;
            while (i < s.start() and (v.byteAt(i) == ' ' or v.byteAt(i) == '\t')) i += 1;
            const indent = try a.dupe(u8, v.text(.{ .start = r.start, .end = i }));
            e.* = .{ .range = s.range(), .text = try std.mem.concat(a, u8, &.{ "\n", indent }) };
        }
        v.undo.breakGroup();
        try v.applyPerSelection(edits, null);
    }

    /// Tab: indent to the next tab stop (or insert a tab character).
    pub fn tab(v: *EditorView) !void {
        var arena: std.heap.ArenaAllocator = .init(v.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const edits = try a.alloc(Replace, v.sels.count());
        for (v.sels.slice(), edits) |s, *e| {
            if (!v.opts.insert_spaces) {
                e.* = .{ .range = s.range(), .text = "\t" };
                continue;
            }
            const r = v.lineRange(v.lineOf(s.start()));
            const col_x = v.xInLine(v.text(r), @intCast(s.start() - r.start));
            const cols: usize = @intFromFloat(@round(col_x / v.spaceW()));
            const n = v.opts.tab_size - @as(u8, @intCast(cols % v.opts.tab_size));
            const sp = try a.alloc(u8, n);
            @memset(sp, ' ');
            e.* = .{ .range = s.range(), .text = sp };
        }
        try v.applyPerSelection(edits, .typing_space);
    }

    /// Deletes the selections, or one character or word before each caret
    /// (smart typing: an auto-inserted pair goes as one, leading spaces
    /// back to the previous tab stop).
    pub fn backspace(v: *EditorView, unit: Unit) !void {
        if (v.opts.smart_typing and unit == .char) return v.runSmart(.delete_left, .delete_left);
        const edits = try v.gpa.alloc(Replace, v.sels.count());
        defer v.gpa.free(edits);
        for (v.sels.slice(), edits) |s, *e| {
            const r: Range = if (!s.isCaret()) s.range() else .{ .start = switch (unit) {
                .char => v.prevChar(s.head),
                .word => v.prevWord(s.head),
            }, .end = s.head };
            e.* = .{ .range = r, .text = "" };
        }
        try v.applyPerSelection(edits, .delete_left);
    }

    /// Deletes the selections, or one character or word after each caret.
    pub fn deleteForward(v: *EditorView, unit: Unit) !void {
        const edits = try v.gpa.alloc(Replace, v.sels.count());
        defer v.gpa.free(edits);
        for (v.sels.slice(), edits) |s, *e| {
            const r: Range = if (!s.isCaret()) s.range() else .{ .start = s.head, .end = switch (unit) {
                .char => v.nextChar(s.head),
                .word => v.nextWord(s.head),
            } };
            e.* = .{ .range = r, .text = "" };
        }
        try v.applyPerSelection(edits, .delete_right);
    }

    /// The smart typing context: the language and its tokens when the
    /// view has syntax.
    fn smartCtx(v: *EditorView, tokens: *syntax_mod.SyntaxTokens) smart.EditCtx {
        var c: smart.EditCtx = .{ .tab_size = v.opts.tab_size, .insert_spaces = v.opts.insert_spaces, .unit = v.indent_unit, .auto_pairs = &v.auto_pairs };
        if (v.syntax) |ds| {
            tokens.* = .{ .ds = ds, .tree = &v.doc.tree };
            c.lang = ds.lang;
            c.tokens = tokens.query();
        }
        return c;
    }

    const SmartOp = union(enum) { type_char: u21, newline, delete_left };

    /// Offers `k` to the mode; true when it took it (the view then shows
    /// what it did). Read-only views have no mode.
    pub fn modeKey(v: *EditorView, k: modes.Key) !bool {
        const m = v.mode orelse return false;
        if (v.opts.read_only) return false;
        var tokens: syntax_mod.SyntaxTokens = undefined;
        var host: modes.Host = .{
            .doc = v.doc,
            .sels = &v.sels,
            .undo = &v.undo,
            .edit = v.smartCtx(&tokens),
            .move = .{ .display = v.displayMap(), .page_rows = @intFromFloat(@max(1, @floor(v.viewport.h / v.lineHeight()) - 1)), .lang = if (v.syntax) |ds| ds.lang else null, .tab_size = v.opts.tab_size },
            .brackets = if (v.syntax) |ds| &ds.brackets else null,
            .actions = v.mode_actions,
        };
        // The mode moves the selections and records undo itself.
        const r = blk: {
            v.in_edit = true;
            defer v.in_edit = false;
            break :blk try m.handleKey(k, &host);
        };
        if (r == .passthrough) return false;
        v.syncSaved();
        v.revealPrimary();
        v.touch();
        // The mode line may have changed without a caret move.
        if (v.on_caret) |h| h.f(h.ctx, v);
        return true;
    }

    /// How the caret is drawn: the mode's shape, else a bar.
    pub fn caretShape(v: *const EditorView) modes.mode.CaretShape {
        const m = v.mode orelse return .bar;
        return m.caretShape();
    }

    /// The mode's status ("-- INSERT --"), or "" without one.
    pub fn modeStatus(v: *const EditorView) []const u8 {
        const m = v.mode orelse return "";
        return m.statusText();
    }

    /// Runs a `smart_edit` command and records what it changed as one
    /// undo step.
    fn runSmart(v: *EditorView, op: SmartOp, key: ?CoalesceKey) !void {
        if (v.opts.read_only) return;
        var tokens: syntax_mod.SyntaxTokens = undefined;
        const ctx = v.smartCtx(&tokens);
        const before = try sel_mod.dupe(v.gpa, v.sels.slice());
        defer v.gpa.free(before);
        var cap: Capture = .{};
        defer cap.deinit();
        {
            v.capture = &cap;
            v.in_edit = true;
            defer {
                v.capture = null;
                v.in_edit = false;
            }
            _ = switch (op) {
                .type_char => |cp| try smart.typeChar(v.doc, &v.sels, cp, ctx),
                .newline => try smart.newline(v.doc, &v.sels, ctx),
                .delete_left => try smart.deleteLeft(v.doc, &v.sels, ctx, true),
            };
        }
        if (cap.failed) return error.OutOfMemory;
        v.sels.clearHistory();
        v.sels.word_search = false;
        v.normalize();
        if (cap.fwd) |f| {
            cap.fwd = null;
            const inv = cap.inv.?;
            cap.inv = null;
            try v.undo.record(f, inv, before, v.sels.slice(), .{ .origin = .{ .user = 0 }, .timestamp = v.timestamp(), .coalesce_key = key });
        }
        v.revealPrimary();
        v.touch();
    }

    /// The text Copy takes (caller frees): the selections joined by
    /// newlines, or the caret lines when nothing is selected.
    pub fn copyText(v: *EditorView, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var all_carets = true;
        for (v.sels.slice()) |s| if (!s.isCaret()) {
            all_carets = false;
        };
        var last_line: ?u64 = null;
        for (v.sels.slice(), 0..) |s, i| {
            if (all_carets) {
                const line = v.lineOf(s.head);
                if (last_line == line) continue;
                last_line = line;
                const r = v.lineRangeWithEol(s.head);
                try out.appendSlice(gpa, v.text(r));
                if (r.end == v.doc.len() and (r.start == r.end or v.byteAt(r.end - 1) != '\n')) try out.append(gpa, '\n');
            } else {
                if (i > 0) try out.append(gpa, '\n');
                try out.appendSlice(gpa, v.text(s.range()));
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// Cut: copies (see `copyText`) and deletes; caret-only cuts take
    /// whole lines.
    pub fn cut(v: *EditorView, gpa: Allocator) ![]u8 {
        const t = try v.copyText(gpa);
        errdefer gpa.free(t);
        var all_carets = true;
        for (v.sels.slice()) |s| if (!s.isCaret()) {
            all_carets = false;
        };
        if (all_carets) {
            for (v.sels.items.items) |*s| {
                const r = v.lineRangeWithEol(s.head);
                s.* = .{ .anchor = r.start, .head = r.end, .id = s.id };
            }
            v.normalize();
        }
        v.undo.breakGroup();
        try v.backspace(.char);
        return t;
    }

    /// Paste: one line per selection when the counts match, else the
    /// whole text at every selection.
    pub fn paste(v: *EditorView, t: []const u8) !void {
        if (t.len == 0) return;
        const n = v.sels.count();
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(v.gpa);
        if (n > 1) {
            var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, t, "\n"), '\n');
            while (it.next()) |l| try lines.append(v.gpa, l);
        }
        const edits = try v.gpa.alloc(Replace, n);
        defer v.gpa.free(edits);
        for (v.sels.slice(), edits, 0..) |s, *e, i| {
            e.* = .{ .range = s.range(), .text = if (lines.items.len == n) lines.items[i] else t };
        }
        v.undo.breakGroup();
        try v.applyPerSelection(edits, null);
        v.undo.breakGroup();
    }

    fn applyStep(v: *EditorView, step: undo_mod.Step, origin: document.EditOrigin) !void {
        v.in_edit = true;
        defer v.in_edit = false;
        try v.doc.applyChangeSet(step.changes, origin);
        if (step.selections.len > 0) try v.sels.set(step.selections, step.selections.len - 1);
        v.sels.clearHistory();
        v.normalize();
        v.revealPrimary();
        v.touch();
    }

    /// Undoes the last group; false when there is nothing to undo.
    pub fn undoStep(v: *EditorView) !bool {
        if (!v.doc.isDirty()) v.foreign = false;
        const step = v.undo.undo() orelse return false;
        try v.applyStep(step, .undo);
        v.syncSaved();
        return true;
    }

    /// Redoes the next group; false when there is nothing to redo.
    pub fn redoStep(v: *EditorView) !bool {
        if (!v.doc.isDirty()) v.foreign = false;
        const step = v.undo.redo() orelse return false;
        try v.applyStep(step, .redo);
        v.syncSaved();
        return true;
    }

    /// Undoing or redoing back to the saved state makes the document
    /// clean again (when only this view's history changed it).
    fn syncSaved(v: *EditorView) void {
        if (v.undo.isAtSaved() and !v.foreign) v.doc.saved_version = v.doc.version;
    }
};
