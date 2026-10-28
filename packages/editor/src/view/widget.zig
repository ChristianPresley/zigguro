//! The editor widget: paints an `EditorView` and turns input into its
//! editing operations (E05.F05.S02.T02/T04, first cut).
//!
//! Paint order per visible row: current-line background, decoration
//! highlights, selections, syntax-coloured text (lexical tokens with LSP
//! semantic ones merged in) with inline decoration texts spliced in,
//! underlines, carets; block decorations (their `block_painter`); then
//! the line-number gutter over the horizontally scrolled text. Only the
//! visible rows are read, highlighted (`DocumentSyntax.ensure`) and drawn.
//!
//! Keys the widget does not handle (Ctrl+S, Ctrl+P, ...) bubble to the
//! window's key handler (the E15 keymap).
//!
//! IME: while focused, the widget reports the primary caret and its line
//! to the platform IME after every input it handles (the window resends
//! only changes), so the candidate window follows the caret; commits
//! arrive as text. Inline preedit is not drawn yet.
//!
//! Multi-cursor (VS Code keys): Alt+click adds a caret, Alt+Shift+drag
//! selects a column (box), Ctrl+Alt+Up/Down add a cursor above/below,
//! Ctrl+D adds the next occurrence, Ctrl+Shift+L selects all of them,
//! Alt+Shift+I splits ranges into lines, Ctrl+U undoes the last cursor
//! change and Escape collapses to the primary.
//!
//! PRIMARY selection (X11 and Wayland): when a pointer drag or a key
//! leaves a new non-empty primary selection, its text becomes PRIMARY; a
//! middle click places the caret and pastes PRIMARY there.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_syntax = @import("zg_syntax");
const view_mod = @import("editor_view.zig");
const colors = @import("syntax_colors.zig");
const deco_store = @import("../model/decorations/store.zig");
const cs_mod = @import("../model/edit/change_set.zig");
const gutter = @import("gutter.zig");
const modes = @import("../modes.zig");

const EditorView = view_mod.EditorView;
const Ui = zg_gui.Ui;
const PaintCx = zg_gui.paint.PaintCx;
const EventCx = zg_gui.input.EventCx;
const InputEvent = zg_gui.input.InputEvent;
const MeasureCx = zg_gui.layout.measure.MeasureCx;
const Style = zg_gui.layout.Style;
const Theme = zg_gui.theme.Theme;
const Rect = zg_gui.core.Rect;
const Vec2 = zg_gui.core.Vec2;
const Size = zg_gui.core.Size;
const Color = zg_gui.core.Color;
const A11y = zg_gui.core.widget.A11y;

/// Pixels between the gutter and the text.
const text_pad: f32 = 6;
/// Width of a caret.
const caret_w: f32 = 2;
/// Width of the SCM bar, and the room it takes at the gutter's left.
const scm_bar_w: f32 = 3;
const scm_lane_w: f32 = 6;

/// The editor widget.
pub const Editor = struct {
    /// Shown in snapshots.
    pub const name = "editor";
    /// Editors take keyboard focus.
    pub const focusable = true;

    /// Editor props.
    pub const Props = struct {
        view: *EditorView,
        a11y_label: []const u8 = "Editor",
    };

    /// Pointer-drag granularity.
    pub const Drag = enum(u8) { none, char, word, line, box };

    /// Per-node input state.
    pub const State = struct {
        drag: Drag = .none,
        drag_origin: [2]u64 = .{ 0, 0 },
        /// Box drags: where the drag started (row, x).
        box_anchor: @import("../model/edit/multi_cursor.zig").DisplayPos = .{ .row = 0, .col_px = 0 },
        /// The selection last made PRIMARY (empty: none).
        primary_pub: [2]u64 = .{ 0, 0 },
        decos: std.ArrayList(deco_store.DecoRef) = .empty,
        gpa: ?std.mem.Allocator = null,
        /// A row's tokens, lexical merged with semantic (allocated by
        /// the DocumentSyntax's allocator, `toks_gpa`).
        toks: std.ArrayList(zg_syntax.Token) = .empty,
        toks_gpa: ?std.mem.Allocator = null,
    };

    /// Frees the scratch lists.
    pub fn deinitState(s: *State) void {
        if (s.gpa) |g| s.decos.deinit(g);
        if (s.toks_gpa) |g| s.toks.deinit(g);
    }

    /// Row `line`'s tokens: the lexical ones with the semantic overlay's
    /// merged in (`DocumentSyntax.mergedTokens`); lexical alone if the
    /// merge fails.
    fn rowTokens(state: *State, v: *const EditorView, line: u64) []const zg_syntax.Token {
        const ds = v.syntax orelse return &.{};
        if (state.toks_gpa) |g| if (g.ptr != ds.gpa.ptr or g.vtable != ds.gpa.vtable) {
            state.toks.deinit(g);
            state.toks = .empty;
        };
        state.toks_gpa = ds.gpa;
        ds.mergedTokens(&v.doc.tree, line, &state.toks) catch return ds.hl.tokens(line);
        return state.toks.items;
    }

    /// Fills the space it is given.
    pub fn style(_: *const Props, _: *const Theme) Style {
        return .{ .grow = 1, .shrink = 1, .basis = .{ .px = 0 }, .min_w = 40, .min_h = 40, .align_self = .stretch };
    }

    /// The view pointer alone: edits never change the layout.
    pub fn layoutHash(props: *const Props) u64 {
        return @intFromPtr(props.view);
    }

    /// Any visible change repaints.
    pub fn paintHash(props: *const Props) u64 {
        const scm: u64 = if (props.view.scm) |s| s.version() else 0;
        const blocks: u64 = if (props.view.decorations) |d| d.inline_generation else 0;
        const decos: u64 = if (props.view.decorations) |d| d.generation else 0;
        return @intFromPtr(props.view) ^ (props.view.generation *% 0x9e37_79b9_7f4a_7c15) ^ (scm *% 0xc2b2_ae3d_27d4_eb4f) ^ (blocks *% 0x1656_67b1_9e37_79f9) ^ (decos *% 0x27d4_eb2f_1656_67c5);
    }

    /// Takes whatever room the parent offers (80x24 cells otherwise).
    pub fn measure(mc: *MeasureCx, props: *const Props, _: *State, max_w: ?f32) Size {
        const st = props.view.textStyle();
        const lh = mc.text.metrics(st).line_h;
        return .{ .w = max_w orelse mc.text.advance(st, '0') * 80, .h = lh * 24 };
    }

    /// The gutter width for the view's line count.
    fn gutterWidth(v: *const EditorView) f32 {
        const lane: f32 = if (v.scm != null) scm_lane_w else 0;
        if (!v.opts.line_numbers) return text_pad + lane;
        var digits: f32 = 1;
        var n = v.lineCount();
        while (n >= 10) : (n /= 10) digits += 1;
        const ts = v.text_sys orelse return 8 * (@max(digits, 3) + 2) + text_pad + lane;
        return ts.advance(v.textStyle(), '0') * (@max(digits, 3) + 2) + text_pad + lane;
    }

    /// Where the text origin (line 0, column 0) is, in node coordinates.
    fn origin(v: *const EditorView) Vec2 {
        return .{ .x = v.gutter_w - v.scroll.x, .y = -v.scroll.y };
    }

    fn sync(v: *EditorView, ts: zg_gui.paint.TextSystem, size: Size) void {
        v.text_sys = ts;
        v.gutter_w = gutterWidth(v);
        v.viewport = .{ .w = @max(0, size.w - v.gutter_w), .h = size.h };
    }

    fn decoColor(v: *const EditorView, s: deco_store.StyleRef, fallback: Color) Color {
        if (v.styles) |r| if (r.color(r.ctx, s)) |c| return c;
        return fallback;
    }

    /// See the module doc.
    pub fn paint(pc: *PaintCx, props: *const Props, state: *State) void {
        const v = props.view;
        sync(v, pc.text_sys, pc.size);
        v.clampScroll();
        const r = pc.bounds();
        const th = pc.theme;
        const bg = pc.color(.bg_base);
        pc.rect(r, bg, .{});
        const st = v.textStyle();
        const m = pc.text_sys.metrics(st);
        const lh = m.line_h;
        const base = (lh - (m.ascent + m.descent)) / 2 + m.ascent;
        const o = origin(v);
        const vis = v.visibleLines();
        const palette = colors.forBackground(bg);
        const fg = pc.color(.fg);
        const focused = pc.state.focused;
        _ = th;

        if (v.syntax) |ds| ds.ensure(&v.doc.tree, vis[0], vis[1]) catch {};
        state.gpa = pc.gpa;
        state.decos.clearRetainingCapacity();
        if (v.decorations) |ds| {
            const span: cs_mod.Range = .{ .start = v.lineRange(vis[0]).start, .end = v.lineRange(vis[1]).end };
            var mask: deco_store.KindMask = .initEmpty();
            mask.insert(.highlight);
            mask.insert(.underline);
            mask.insert(.strike);
            mask.insert(.text_style);
            mask.insert(.gutter);
            ds.query(span, mask, pc.gpa, &state.decos) catch {};
        }

        const text_clip: Rect = .{ .x = v.gutter_w, .y = 0, .w = @max(0, r.w - v.gutter_w), .h = r.h };
        pc.pushClip(text_clip, 0);
        const prim = v.primarySel();
        const prim_line = v.lineOf(prim.head);
        const shape = v.caretShape();
        const sel_color = pc.color(.selection_bg).fade(if (focused) 1 else 0.6);
        const hl_default = pc.color(.warning).fade(0.35);
        const ul_default = pc.color(.danger);
        var line = vis[0];
        while (line <= vis[1]) : (line += 1) {
            const lr = v.lineRange(line);
            var inl: [view_mod.max_row_inlays]view_mod.Inlay = undefined;
            const ins = v.rowInlays(lr, &inl);
            // `text` reuses the view's scratch; copy the row for this loop.
            const row_text = pc.gpa.dupe(u8, v.text(lr)) catch break;
            defer pc.gpa.free(row_text);
            const y = o.y + v.lineTop(line);
            const rx = RowX{ .v = v, .s = row_text, .ins = ins, .start = lr.start };

            // Current line (only with a single caret, like most editors).
            if (line == prim_line and prim.isCaret() and v.selections().len == 1 and focused) {
                pc.rect(.{ .x = v.gutter_w, .y = y, .w = r.w - v.gutter_w, .h = lh }, pc.color(.hover_bg), .{});
            }
            // Decoration highlights.
            for (state.decos.items) |d| {
                const hl_style = switch (d.deco.kind) {
                    .highlight => |s| s,
                    else => continue,
                };
                if (rowSpan(lr, d.range)) |sp| {
                    const x0 = rx.at(sp[0]);
                    const x1 = rx.at(sp[1]);
                    pc.rect(.{ .x = o.x + x0, .y = y, .w = @max(x1 - x0, 1), .h = lh }, decoColor(v, hl_style, hl_default), .{});
                }
            }
            // Selections.
            for (v.selections()) |s| {
                if (s.isCaret()) continue;
                const sr = s.range();
                if (sr.end < lr.start or sr.start > lr.end) continue;
                if (sr.end == lr.start and line > 0) continue;
                const a = @max(sr.start, lr.start) - lr.start;
                const b = @min(sr.end, lr.end) - lr.start;
                const x0 = rx.at(@intCast(a));
                var x1 = rx.at(@intCast(b));
                // A selected line break shows as a space-wide block.
                if (sr.end > lr.end) x1 += pc.text_sys.advance(st, ' ');
                pc.rect(.{ .x = o.x + x0, .y = y, .w = x1 - x0, .h = lh }, sel_color, .{});
            }
            // Text, in syntax-coloured runs.
            drawRow(pc, v, row_text, rowTokens(state, v, line), palette, fg, .{ .x = o.x, .y = y + base }, ins, lr.start);
            drawInlays(pc, v, rx, fg, .{ .x = o.x, .y = y + base });
            // Faded text, underlines and strikes.
            for (state.decos.items) |d| {
                const sp = rowSpan(lr, d.range) orelse continue;
                const x0 = o.x + rx.at(sp[0]);
                const w = @max(rx.at(sp[1]) - rx.at(sp[0]), 2);
                switch (d.deco.kind) {
                    // A wash of the background over the text.
                    .text_style => |ts| pc.rect(.{ .x = x0, .y = y, .w = w, .h = lh }, decoColor(v, ts, bg.fade(0.45)), .{}),
                    .underline => |u| underline(pc, u.kind, decoColor(v, u.style, ul_default), x0, w, y + lh - 3),
                    .strike => pc.rect(.{ .x = x0, .y = y + lh / 2, .w = w, .h = 1 }, fg, .{}),
                    else => {},
                }
            }
            // Carets.
            if (focused) for (v.selections()) |s| {
                if (s.head < lr.start or s.head > lr.end) continue;
                const col: usize = @intCast(s.head - lr.start);
                const x = rx.at(col);
                // Block shapes cover the character under the caret.
                const cw = if (col < row_text.len) @max(v.xInLine(row_text, col + (std.unicode.utf8ByteSequenceLength(row_text[col]) catch 1)) - v.xInLine(row_text, col), 1) else pc.text_sys.advance(st, ' ');
                const cr: Rect = switch (shape) {
                    .bar => .{ .x = @round(o.x + x), .y = y, .w = caret_w, .h = lh },
                    .block => .{ .x = @round(o.x + x), .y = y, .w = cw, .h = lh },
                    .underline => .{ .x = @round(o.x + x), .y = y + lh - 2, .w = cw, .h = 2 },
                    .half_block => .{ .x = @round(o.x + x), .y = y + lh / 2, .w = cw, .h = lh / 2 },
                };
                pc.rect(cr, if (shape == .block) fg.fade(0.6) else fg, .{});
            };
        }
        // Blocks: an empty band unless a painter fills it.
        for (v.blockList(), 0..) |b, i| {
            const br = v.blockRectAt(i);
            if (br.y + br.h <= 0 or br.y >= r.h) continue;
            if (v.block_painter) |bp| bp.paint(bp.ctx, pc, br, b) else pc.rect(br, bg, .{});
        }
        pc.popClip();

        // Gutter.
        if (v.opts.line_numbers) {
            pc.rect(.{ .x = 0, .y = 0, .w = v.gutter_w - text_pad / 2, .h = r.h }, bg, .{});
            var buf: [24]u8 = undefined;
            line = vis[0];
            while (line <= vis[1]) : (line += 1) {
                const label = std.fmt.bufPrint(&buf, "{d}", .{line + 1}) catch continue;
                var w: f32 = 0;
                for (label) |ch| w += pc.text_sys.advance(st, ch);
                const y = o.y + v.lineTop(line);
                const c = pc.color(if (line == prim_line) .fg else .fg_muted);
                pc.textLine(label, st, c, .{ .x = v.gutter_w - text_pad - pc.text_sys.advance(st, '0') - w, .y = y + base });
            }
        }
        if (v.scm) |*src| paintScm(pc, v, src, vis, o.y, lh);
        paintGutterMarks(pc, v, state.decos.items, o.y, lh);
        if (v.decorations) |ds| paintOverview(pc, v, ds, state, r);
        pc.focusRing(r, 0);
    }

    /// Width of the overview ruler at the editor's right edge.
    const overview_w: f32 = 4;

    /// An underline of `kind` from `x` over `w` pixels, its top at `y`.
    fn underline(pc: *PaintCx, kind: @FieldType(deco_store.UnderlineStyle, "kind"), c: Color, x: f32, w: f32, y: f32) void {
        switch (kind) {
            .straight => pc.rect(.{ .x = x, .y = y + 1, .w = w, .h = 1 }, c, .{}),
            .double => {
                pc.rect(.{ .x = x, .y = y, .w = w, .h = 1 }, c, .{});
                pc.rect(.{ .x = x, .y = y + 2, .w = w, .h = 1 }, c, .{});
            },
            .dotted => {
                var dx: f32 = 0;
                while (dx < w) : (dx += 3) pc.rect(.{ .x = x + dx, .y = y + 1, .w = @min(1.5, w - dx), .h = 1.5 }, c, .{});
            },
            // A zigzag: 2-pixel steps up and down.
            .squiggle => {
                var dx: f32 = 0;
                var up = false;
                while (dx < w) : (dx += 2) {
                    pc.rect(.{ .x = x + dx, .y = if (up) y else y + 1.5, .w = @min(2, w - dx), .h = 1.5 }, c, .{});
                    up = !up;
                }
            },
        }
    }

    /// Gutter marks (diagnostic severities, breakpoints): a dot per line
    /// at the gutter's left, the highest `z` mark winning.
    fn paintGutterMarks(pc: *PaintCx, v: *EditorView, decos: []const deco_store.DecoRef, oy: f32, lh: f32) void {
        const lane: f32 = if (v.scm != null) scm_lane_w else 0;
        const d = @min(lh * 0.4, 8);
        var last_line: ?u64 = null;
        var last_z: i16 = std.math.minInt(i16);
        for (decos) |dr| {
            const g = switch (dr.deco.kind) {
                .gutter => |g| g,
                else => continue,
            };
            const line = v.lineOf(dr.range.start);
            if (last_line == line and dr.deco.z <= last_z) continue;
            last_line = line;
            last_z = dr.deco.z;
            const y = oy + v.lineTop(line) + (lh - d) / 2;
            pc.rect(.{ .x = lane + 2, .y = y, .w = d, .h = d }, decoColor(v, g.style, pc.color(.danger)), .all(d / 2));
        }
    }

    /// The overview ruler: a mark per decoration at its line's place in
    /// the whole document, over the editor's right edge.
    fn paintOverview(pc: *PaintCx, v: *EditorView, ds: *const deco_store.DecorationStore, state: *State, r: Rect) void {
        var mask: deco_store.KindMask = .initEmpty();
        mask.insert(.overview);
        state.decos.clearRetainingCapacity();
        ds.query(.{ .start = 0, .end = v.doc.len() }, mask, pc.gpa, &state.decos) catch return;
        if (state.decos.items.len == 0) return;
        const n: f32 = @floatFromInt(@max(v.lineCount(), 1));
        for (state.decos.items) |dr| {
            const ov = switch (dr.deco.kind) {
                .overview => |ov| ov,
                else => continue,
            };
            const line: f32 = @floatFromInt(v.lineOf(dr.range.start));
            const y = @floor(line / n * (r.h - 2));
            pc.rect(.{ .x = r.w - overview_w, .y = y, .w = overview_w, .h = 2 }, decoColor(v, ov.style, pc.color(.danger)), .{});
        }
    }

    /// The SCM bar: added lines solid, modified lines striped, deletions
    /// a triangle on the boundary where the lines were.
    fn paintScm(pc: *PaintCx, v: *EditorView, src: *const gutter.ScmGutterSource, vis: [2]u64, oy: f32, lh: f32) void {
        if (vis[1] < vis[0]) return;
        if (!v.opts.line_numbers) pc.rect(.{ .x = 0, .y = 0, .w = v.gutter_w - text_pad / 2, .h = pc.bounds().h }, pc.color(.bg_base), .{});
        var rows: [256]gutter.ScmRow = undefined;
        const added = pc.color(.success);
        const modified = pc.color(.info);
        const deleted = pc.color(.danger);
        const x: f32 = 1;
        var first = vis[0];
        while (first <= vis[1]) {
            const n: usize = @intCast(@min(rows.len, vis[1] - first + 1));
            gutter.scmRows(src.hunks(), first, v.lineCount(), rows[0..n]);
            for (rows[0..n], 0..) |row, i| {
                const y = oy + v.lineTop(first + i);
                switch (row.bar) {
                    .none => {},
                    .added => pc.rect(.{ .x = x, .y = y, .w = scm_bar_w, .h = lh }, added, .{}),
                    .modified => {
                        // Stripes: 2 px on, 1 px off.
                        var sy = y;
                        while (sy < y + lh) : (sy += 3) pc.rect(.{ .x = x, .y = sy, .w = scm_bar_w, .h = @min(2, y + lh - sy) }, modified, .{});
                    },
                }
                if (row.deleted_above) deletionMark(pc, x, y, deleted);
                if (row.deleted_below) deletionMark(pc, x, y + lh, deleted);
            }
            first += n;
        }
    }

    /// A small right-pointing triangle centred on boundary `y`, drawn as
    /// shrinking rows.
    fn deletionMark(pc: *PaintCx, x: f32, y: f32, c: Color) void {
        var i: f32 = 0;
        while (i < 4) : (i += 1) {
            const w = 2 + i;
            pc.rect(.{ .x = x, .y = y - 4 + i, .w = w, .h = 1 }, c, .{});
            pc.rect(.{ .x = x, .y = y + 3 - i, .w = w, .h = 1 }, c, .{});
        }
    }

    /// The part of `d` on row `lr`, as byte columns, or null.
    fn rowSpan(lr: cs_mod.Range, d: cs_mod.Range) ?[2]usize {
        if (d.end < lr.start or d.start > lr.end) return null;
        if (d.start == d.end and (d.start < lr.start or d.start > lr.end)) return null;
        const a = @max(d.start, lr.start) - lr.start;
        const b = @min(d.end, lr.end) - lr.start;
        return .{ @intCast(a), @intCast(b) };
    }

    /// Draws a row's text in runs of one colour, expanding tabs; GFM
    /// `~~strikethrough~~` gets a line through it.
    fn drawRow(pc: *PaintCx, v: *const EditorView, s: []const u8, toks: []const zg_syntax.Token, palette: *const colors.Palette, fg: Color, pen: Vec2, ins: []const view_mod.Inlay, row_start: u64) void {
        const st = v.textStyle();
        const rx = RowX{ .v = v, .s = s, .ins = ins, .start = row_start };
        var ti: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            // The run: up to the next token start, inlay or tab.
            while (ti + 1 < toks.len and toks[ti + 1].start <= i) ti += 1;
            const in_tok = ti < toks.len and toks[ti].start <= i;
            const color = if (in_tok) colors.colorOfNamed(palette, v.hl_names, toks[ti].hl, fg) else fg;
            var j = i;
            const next_tok: usize = @min(if (ti + 1 < toks.len) toks[ti + 1].start else s.len, nextInlay(ins, row_start, i, s.len));
            if (s[i] == '\t') {
                i += 1;
                continue;
            }
            while (j < s.len and j < @max(next_tok, i + 1) and s[j] != '\t') j += 1;
            const x0 = pen.x + rx.at(i);
            pc.textLine(s[i..j], st, color, .{ .x = x0, .y = pen.y });
            if (in_tok and toks[ti].hl == .markup_strikethrough) {
                const x1 = x0 + v.xInLine(s, j) - v.xInLine(s, i);
                // Through the middle of the lowercase letters.
                const m = pc.text_sys.metrics(st);
                pc.rect(.{ .x = x0, .y = @floor(pen.y - m.ascent * 0.3), .w = x1 - x0, .h = 1 }, color, .{});
            }
            i = j;
        }
    }

    /// The first inlay column after `i` in a row starting at `row_start`
    /// (`len` when none).
    fn nextInlay(ins: []const view_mod.Inlay, row_start: u64, i: usize, len: usize) usize {
        var best = len;
        for (ins) |x| {
            const c: usize = @intCast(x.offset - row_start);
            if (c > i and c < best) best = c;
        }
        return best;
    }

    /// Draws a row's inline decoration texts where they sit: at their
    /// offset, after-inlays first, then before-inlays, each after the
    /// earlier ones at the same offset.
    fn drawInlays(pc: *PaintCx, v: *const EditorView, rx: RowX, fg: Color, pen: Vec2) void {
        const st = v.textStyle();
        for (rx.ins, 0..) |x, k| {
            var dx = rx.at(@intCast(x.offset - rx.start)) - EditorView.inlayShift(rx.ins, x.offset);
            for (rx.ins) |o| if (o.offset < x.offset) {
                dx += o.w;
            };
            for (rx.ins[0..k]) |o| if (o.offset == x.offset and o.after == x.after) {
                dx += o.w;
            };
            if (!x.after) for (rx.ins) |o| if (o.offset == x.offset and o.after) {
                dx += o.w;
            };
            pc.textLine(x.text, st, decoColor(v, x.style, fg.fade(0.55)), .{ .x = pen.x + dx, .y = pen.y });
        }
    }

    /// X positions in one row with its inlays.
    const RowX = struct {
        v: *const EditorView,
        s: []const u8,
        ins: []const view_mod.Inlay,
        start: u64,

        /// The x of byte column `col` from the text origin.
        fn at(rx: RowX, col: usize) f32 {
            return rx.v.xInLine(rx.s, col) + EditorView.inlayShift(rx.ins, rx.start + col);
        }
    };

    /// A multi-line text box for assistive technology.
    pub fn a11y(props: *const Props, _: *State) A11y {
        return .{ .role = .textbox, .name = props.a11y_label };
    }

    fn hitAt(ec: *EventCx, v: *EditorView, p: Vec2) u64 {
        return v.offsetAt(textPoint(ec, v, p));
    }

    /// The offset of the character under `p` (window coordinates), or
    /// null past the end of its line or below the text.
    fn textAt(ec: *EventCx, v: *EditorView, p: Vec2) ?u64 {
        if (ec.local(p).x < v.gutter_w) return null;
        const t = textPoint(ec, v, p);
        if (t.x < 0 or t.y < 0) return null;
        const line = v.lineAtY(t.y);
        if (t.y >= v.lineTop(line) + v.lineHeight()) return null;
        const r = v.lineRange(line);
        if (t.x >= v.posOf(r.end).x) return null;
        const off = v.offsetAt(t);
        // `offsetAt` rounds to the nearest boundary: take the character
        // the point is on.
        return if (off > r.start and v.posOf(off).x > t.x) off - 1 else off;
    }

    /// The text origin in window coordinates.
    fn windowOrigin(ec: *EventCx, v: *EditorView) Vec2 {
        const r = ec.rect();
        const o = origin(v);
        return .{ .x = r.x + o.x, .y = r.y + o.y };
    }

    /// `p` relative to the text origin.
    fn textPoint(ec: *EventCx, v: *EditorView, p: Vec2) Vec2 {
        const l = ec.local(p);
        const o = origin(v);
        return .{ .x = l.x - o.x, .y = l.y - o.y };
    }

    /// See the module doc and `EditorView`.
    pub fn event(ec: *EventCx, props: *const Props, state: *State, ev: *const InputEvent) bool {
        if (ec.phase == .capture) return false;
        const v = props.view;
        v.now_ms = ec.nowMs();
        const r = ec.rect();
        sync(v, ec.textSystem(), .{ .w = r.w, .h = r.h });
        const handled = handle(ec, v, state, ev) catch true;
        switch (ev.*) {
            .focus_lost => ec.setIme(null),
            .focus_gained, .text => reportIme(ec, v),
            .key => |k| if (k.action != .release) {
                reportIme(ec, v);
                publishPrimary(ec, v, state);
            },
            .pointer_down => if (handled) reportIme(ec, v),
            .pointer_up => if (handled) {
                reportIme(ec, v);
                publishPrimary(ec, v, state);
            },
            else => {},
        }
        return handled;
    }

    /// Makes a new non-empty primary selection the PRIMARY text. Not
    /// during a drag: large selections are copied once, on release.
    fn publishPrimary(ec: *EventCx, v: *EditorView, state: *State) void {
        const s = v.primarySel();
        const r = s.range();
        if (r.start == r.end) {
            state.primary_pub = .{ 0, 0 };
            return;
        }
        if (state.primary_pub[0] == r.start and state.primary_pub[1] == r.end) return;
        state.primary_pub = .{ r.start, r.end };
        ec.setPrimary(v.text(r));
    }

    /// Tells the IME where the primary caret is (window coordinates) and
    /// the text of its line.
    fn reportIme(ec: *EventCx, v: *EditorView) void {
        if (v.opts.read_only) return ec.setIme(null);
        const r = ec.rect();
        const o = origin(v);
        const head = v.primarySel().head;
        const p = v.posOf(head);
        const caret: Rect = .{ .x = r.x + o.x + p.x, .y = r.y + o.y + p.y, .w = caret_w, .h = v.lineHeight() };
        // At most the IME's limit around the caret, not a whole long line.
        const lr = v.lineRange(v.lineOf(head));
        const half = zg_gui.w.text_field.ime.max_surrounding / 2;
        const lo = @max(lr.start, head -| half);
        const line = v.text(.{ .start = lo, .end = @min(lr.end, head + half) });
        const col: u32 = @intCast(@min(head - lo, line.len));
        const w = zg_gui.w.text_field.ime.window(line, col);
        ec.setIme(.{ .caret = caret, .surrounding = .{ .text = line[w[0]..w[1]], .cursor_byte = col - w[0], .anchor_byte = col - w[0] } });
    }

    fn handle(ec: *EventCx, v: *EditorView, state: *State, ev: *const InputEvent) !bool {
        switch (ev.*) {
            .focus_gained, .focus_lost => {
                v.undo.breakGroup();
                if (ev.* == .focus_lost) state.drag = .none;
                ec.repaint();
                return false;
            },
            .pointer_down => |p| {
                if (p.button == .middle) {
                    const t = ec.primary() orelse return false;
                    ec.focus();
                    if (v.opts.read_only or t.len == 0) return true;
                    v.setSelection(.caret(hitAt(ec, v, p.pos)));
                    v.undo.breakGroup();
                    try v.paste(t);
                    ec.respond(.{ .changed = true });
                    ec.repaint();
                    return true;
                }
                if (p.button != .left) return false;
                if (p.clicks <= 1 and (p.mods.ctrl or p.mods.super) and !p.mods.alt and !p.mods.shift) {
                    if (v.pointer_hook) |h| if (h.f(h.ctx, v, .{ .kind = .click, .offset = textAt(ec, v, p.pos), .origin = windowOrigin(ec, v), .mods = p.mods })) {
                        ec.focus();
                        return true;
                    };
                }
                ec.focus();
                const at = hitAt(ec, v, p.pos);
                switch (p.clicks) {
                    0, 1 => {
                        if (p.mods.alt and p.mods.shift) {
                            state.box_anchor = v.displayPosAt(textPoint(ec, v, p.pos));
                            v.boxSelect(state.box_anchor, state.box_anchor);
                            state.drag = .box;
                            ec.capture();
                            ec.repaint();
                            return true;
                        }
                        if (p.mods.alt) {
                            v.addCaret(at);
                        } else if (p.mods.shift) {
                            const prim = v.primarySel();
                            v.setSelection(.{ .anchor = prim.anchor, .head = at });
                        } else v.setSelection(.caret(at));
                        state.drag = .char;
                    },
                    2 => {
                        const w = v.wordRange(at);
                        state.drag_origin = .{ w.start, w.end };
                        v.setSelection(.{ .anchor = w.start, .head = w.end });
                        state.drag = .word;
                    },
                    else => {
                        const l = v.lineRangeWithEol(at);
                        state.drag_origin = .{ l.start, l.end };
                        v.setSelection(.{ .anchor = l.start, .head = l.end });
                        state.drag = .line;
                    },
                }
                ec.capture();
                ec.repaint();
                return true;
            },
            .pointer_move => |p| {
                ec.setCursor(.text);
                if (state.drag == .none) {
                    if (v.pointer_hook) |h| _ = h.f(h.ctx, v, .{ .kind = .move, .offset = textAt(ec, v, p.pos), .origin = windowOrigin(ec, v), .mods = p.mods });
                    return false;
                }
                if (state.drag == .box) {
                    v.boxSelect(state.box_anchor, v.displayPosAt(textPoint(ec, v, p.pos)));
                    ec.repaint();
                    return true;
                }
                const at = hitAt(ec, v, p.pos);
                const s = v.primaryPtr();
                switch (state.drag) {
                    .none, .box => {},
                    .char => s.head = at,
                    .word, .line => {
                        const unit = if (state.drag == .word) v.wordRange(at) else v.lineRangeWithEol(at);
                        const o = state.drag_origin;
                        s.* = if (unit.start < o[0]) .{ .anchor = o[1], .head = unit.start } else .{ .anchor = o[0], .head = @max(unit.end, o[1]) };
                    },
                }
                v.normalize();
                v.revealPrimary();
                ec.repaint();
                return true;
            },
            .pointer_leave => {
                if (v.pointer_hook) |h| _ = h.f(h.ctx, v, .{ .kind = .leave });
                return false;
            },
            .pointer_up => {
                if (state.drag == .none) return false;
                state.drag = .none;
                ec.releaseCapture();
                return true;
            },
            .scroll => |sc| {
                const step = if (sc.precise) 1 else 3 * v.lineHeight();
                v.scrollBy(.{ .x = -sc.dx * step, .y = -sc.dy * step });
                ec.repaint();
                return true;
            },
            .text => |t| {
                if (v.opts.read_only) return false;
                if (v.mode != null) {
                    // Each character goes to the mode (Vim commands and
                    // insert-mode typing).
                    var took = false;
                    var it = (std.unicode.Utf8View.init(t) catch return false).iterator();
                    while (it.nextCodepoint()) |cp| {
                        if (try v.modeKey(.char(cp))) {
                            took = true;
                            continue;
                        }
                        var b: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &b) catch continue;
                        try v.typeText(b[0..n]);
                        took = true;
                    }
                    if (took) {
                        ec.respond(.{ .changed = true });
                        ec.repaint();
                    }
                    return true;
                }
                try v.typeText(t);
                ec.respond(.{ .changed = true });
                ec.repaint();
                return true;
            },
            .key => |k| {
                if (k.action == .release) return false;
                if (v.pointer_hook) |h| if (h.f(h.ctx, v, .{ .kind = .key, .key = k, .mods = k.mods })) return true;
                if (v.key_hook) |h| if (h.f(h.ctx, v, k)) {
                    ec.respond(.{ .changed = true });
                    ec.repaint();
                    return true;
                };
                if (modeKeyOf(k)) |mk| if (try v.modeKey(mk)) {
                    ec.respond(.{ .changed = true });
                    ec.repaint();
                    return true;
                };
                const done = try key(ec, v, k);
                if (done) ec.repaint();
                return done;
            },
            else => return false,
        }
    }

    /// The mode's view of a key press: named keys, and letters or `[`
    /// with Ctrl or Alt. Plain characters arrive as text instead.
    fn modeKeyOf(k: zg_gui.input.event.KeyPress) ?modes.Key {
        const ctrl = k.mods.ctrl;
        const named: ?modes.key.Special = switch (k.key) {
            .escape => .esc,
            .enter, .numpad_enter => .enter,
            .tab => .tab,
            .backspace => .backspace,
            .delete => .delete,
            .arrow_left => .left,
            .arrow_right => .right,
            .arrow_up => .up,
            .arrow_down => .down,
            .home => .home,
            .end => .end,
            .page_up => .page_up,
            .page_down => .page_down,
            .insert => .insert,
            else => null,
        };
        if (named) |n| return .{ .code = @intFromEnum(n), .ctrl = ctrl, .alt = k.mods.alt, .shift = k.mods.shift };
        if (!ctrl and !k.mods.alt) return null;
        if (k.mods.super) return null;
        const tag = @tagName(k.key);
        const cp: u21 = if (tag.len == 5 and std.mem.startsWith(u8, tag, "key_"))
            tag[4]
        else if (k.key == .bracket_left)
            '['
        else
            return null;
        return .{ .code = cp, .ctrl = ctrl, .alt = k.mods.alt, .shift = k.mods.shift };
    }

    fn key(ec: *EventCx, v: *EditorView, k: zg_gui.input.event.KeyPress) !bool {
        const ctrl = k.mods.ctrl or k.mods.super;
        const shift = k.mods.shift;
        const unit: view_mod.Unit = if (ctrl or k.mods.alt) .word else .char;
        const page: i64 = @intFromFloat(@max(1, @floor(v.viewport.h / v.lineHeight()) - 1));
        const ro = v.opts.read_only;
        switch (k.key) {
            .arrow_left => v.moveH(false, unit, shift),
            .arrow_right => v.moveH(true, unit, shift),
            .arrow_up => if (ctrl and k.mods.alt) {
                _ = try v.cursorCommand(.add_above);
            } else if (ctrl) v.scrollBy(.{ .x = 0, .y = -v.lineHeight() }) else v.moveV(-1, shift),
            .arrow_down => if (ctrl and k.mods.alt) {
                _ = try v.cursorCommand(.add_below);
            } else if (ctrl) v.scrollBy(.{ .x = 0, .y = v.lineHeight() }) else v.moveV(1, shift),
            .page_up => v.moveV(-page, shift),
            .page_down => v.moveV(page, shift),
            .home => if (ctrl) v.docEdge(false, shift) else v.home(shift),
            .end => if (ctrl) v.docEdge(true, shift) else v.end(shift),
            .backspace => if (!ro) try v.backspace(unit) else return false,
            .delete => if (shift and !ctrl) {
                if (ro) return false;
                const t = try v.cut(v.gpa);
                defer v.gpa.free(t);
                ec.setClipboard(t);
            } else if (!ro) try v.deleteForward(unit) else return false,
            .enter, .numpad_enter => if (!ro and !ctrl and !k.mods.alt) try v.newline() else return false,
            .tab => if (!ro and !ctrl) try v.tab() else return false,
            .escape => {
                if (v.selections().len > 1) {
                    _ = try v.cursorCommand(.collapse);
                } else {
                    if (v.primarySel().isCaret()) return false;
                    v.setSelection(.caret(v.primarySel().head));
                }
            },
            .key_d => if (ctrl and !shift and !k.mods.alt) {
                _ = try v.cursorCommand(.add_next_occurrence);
            } else return false,
            .key_l => if (ctrl and shift) {
                _ = try v.cursorCommand(.select_all_occurrences);
            } else return false,
            .key_i => if (k.mods.alt and shift and !ctrl) {
                _ = try v.cursorCommand(.split_into_lines);
            } else return false,
            .key_u => if (ctrl and !shift) {
                _ = try v.cursorCommand(.undo_cursor);
            } else return false,
            .key_a => if (ctrl) v.selectAll() else return false,
            .key_c, .insert => if (ctrl) {
                const t = try v.copyText(v.gpa);
                defer v.gpa.free(t);
                ec.setClipboard(t);
            } else return false,
            .key_x => if (ctrl and !ro) {
                const t = try v.cut(v.gpa);
                defer v.gpa.free(t);
                ec.setClipboard(t);
            } else return false,
            .key_v => if (ctrl and !ro) try v.paste(ec.clipboard()) else return false,
            .key_z => if (ctrl and !ro) {
                _ = try (if (shift) v.redoStep() else v.undoStep());
            } else return false,
            .key_y => if (ctrl and !ro) {
                _ = try v.redoStep();
            } else return false,
            else => {
                // Printable keys arrive again as `text`; claim them so key
                // bindings without modifiers do not fire while typing.
                return k.codepoint != 0 and !ctrl and !k.mods.alt and !ro;
            },
        }
        return true;
    }
};

/// Adds an editor for `view` to the tree.
pub fn editor(ui: *Ui, props: Editor.Props) zg_gui.Response {
    const r = ui.leaf(Editor, props);
    // For `EditorView.focusEditor`.
    props.view.ui_window = ui.window();
    props.view.ui_node = ui.lastNode();
    return r;
}

test "editor: rows draw semantic tokens over lexical ones" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const model_syntax = @import("../model/syntax.zig");
    const Document = @import("../model/document.zig").Document;
    var reg = try zg_syntax.defaultRegistry(gpa);
    defer reg.deinit(gpa);
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "const a = 1;\n");
    defer doc.deinit();
    var ds = try model_syntax.DocumentSyntax.init(gpa, reg.get(.zig).?, &reg, &doc.tree, doc.version);
    defer ds.deinit();
    const v = try EditorView.init(gpa, doc, .{});
    defer v.deinit();
    v.syntax = &ds;
    var state: Editor.State = .{};
    defer Editor.deinitState(&state);

    // Lexical only: no overlay yet.
    try ds.ensure(&doc.tree, 0, 0);
    try testing.expectEqualSlices(zg_syntax.Token, ds.hl.tokens(0), Editor.rowTokens(&state, v, 0));

    // An LSP result marks `a` with a type outside the fixed names.
    var names: zg_syntax.HighlightNames = .init(gpa);
    defer names.deinit();
    var legend = try (zg_syntax.SemanticLegend{ .types = &.{"keyword"}, .modifiers = &.{"custom"} }).compile(gpa, &names);
    defer legend.deinit();
    const o = try ds.semanticOverlay(&doc.tree);
    try testing.expect(try o.applyFull(doc.version, null, &.{ 0, 6, 1, 0, 1 }, &legend, model_syntax.lineSource(&doc.tree)));
    const toks = Editor.rowTokens(&state, v, 0);
    var at_a: zg_syntax.HighlightId = .none;
    for (toks) |t| if (t.start <= 6) {
        at_a = t.hl;
    };
    try testing.expectEqualStrings("keyword.custom", names.name(at_a));
    // Its colour is its ancestor's once the view knows the names.
    v.hl_names = &names;
    const pal = &colors.dark;
    const fg: Color = .hex(0xffffff);
    try testing.expectEqual(colors.colorOf(pal, .keyword, fg), colors.colorOfNamed(pal, v.hl_names, at_a, fg));
}
