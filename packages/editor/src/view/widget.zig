//! The editor widget: paints an `EditorView` and turns input into its
//! editing operations (E05.F05.S02.T02/T04, first cut).
//!
//! Paint order per visible row: current-line background, decoration
//! highlights, selections, syntax-coloured text, underlines, carets; then
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
    };

    /// Frees the decoration scratch list.
    pub fn deinitState(s: *State) void {
        if (s.gpa) |g| s.decos.deinit(g);
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
        return @intFromPtr(props.view) ^ (props.view.generation *% 0x9e37_79b9_7f4a_7c15);
    }

    /// Takes whatever room the parent offers (80x24 cells otherwise).
    pub fn measure(mc: *MeasureCx, props: *const Props, _: *State, max_w: ?f32) Size {
        const st = props.view.textStyle();
        const lh = mc.text.metrics(st).line_h;
        return .{ .w = max_w orelse mc.text.advance(st, '0') * 80, .h = lh * 24 };
    }

    /// The gutter width for the view's line count.
    fn gutterWidth(v: *const EditorView) f32 {
        if (!v.opts.line_numbers) return text_pad;
        var digits: f32 = 1;
        var n = v.lineCount();
        while (n >= 10) : (n /= 10) digits += 1;
        const ts = v.text_sys orelse return 8 * (@max(digits, 3) + 2) + text_pad;
        return ts.advance(v.textStyle(), '0') * (@max(digits, 3) + 2) + text_pad;
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
            ds.query(span, mask, pc.gpa, &state.decos) catch {};
        }

        const text_clip: Rect = .{ .x = v.gutter_w, .y = 0, .w = @max(0, r.w - v.gutter_w), .h = r.h };
        pc.pushClip(text_clip, 0);
        const prim = v.primarySel();
        const prim_line = v.lineOf(prim.head);
        const sel_color = pc.color(.selection_bg).fade(if (focused) 1 else 0.6);
        const hl_default = pc.color(.warning).fade(0.35);
        const ul_default = pc.color(.danger);
        var line = vis[0];
        while (line <= vis[1]) : (line += 1) {
            const lr = v.lineRange(line);
            // `text` reuses the view's scratch; copy the row for this loop.
            const row_text = pc.gpa.dupe(u8, v.text(lr)) catch break;
            defer pc.gpa.free(row_text);
            const y = o.y + @as(f32, @floatFromInt(line)) * lh;

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
                    const x0 = v.xInLine(row_text, sp[0]);
                    const x1 = v.xInLine(row_text, sp[1]);
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
                const x0 = v.xInLine(row_text, @intCast(a));
                var x1 = v.xInLine(row_text, @intCast(b));
                // A selected line break shows as a space-wide block.
                if (sr.end > lr.end) x1 += pc.text_sys.advance(st, ' ');
                pc.rect(.{ .x = o.x + x0, .y = y, .w = x1 - x0, .h = lh }, sel_color, .{});
            }
            // Text, in syntax-coloured runs.
            drawRow(pc, v, row_text, line, palette, fg, .{ .x = o.x, .y = y + base });
            // Underlines and strikes.
            for (state.decos.items) |d| {
                const c: Color, const yy: f32 = switch (d.deco.kind) {
                    .underline => |u| .{ decoColor(v, u.style, ul_default), y + lh - 2 },
                    .strike => .{ fg, y + lh / 2 },
                    else => continue,
                };
                if (rowSpan(lr, d.range)) |sp| {
                    const x0 = v.xInLine(row_text, sp[0]);
                    const x1 = v.xInLine(row_text, sp[1]);
                    pc.rect(.{ .x = o.x + x0, .y = yy, .w = @max(x1 - x0, 2), .h = 1 }, c, .{});
                }
            }
            // Carets.
            if (focused) for (v.selections()) |s| {
                if (s.head < lr.start or s.head > lr.end) continue;
                const x = v.xInLine(row_text, @intCast(s.head - lr.start));
                pc.rect(.{ .x = @round(o.x + x), .y = y, .w = caret_w, .h = lh }, fg, .{});
            };
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
                const y = o.y + @as(f32, @floatFromInt(line)) * lh;
                const c = pc.color(if (line == prim_line) .fg else .fg_muted);
                pc.textLine(label, st, c, .{ .x = v.gutter_w - text_pad - pc.text_sys.advance(st, '0') - w, .y = y + base });
            }
        }
        pc.focusRing(r, 0);
    }

    /// The part of `d` on row `lr`, as byte columns, or null.
    fn rowSpan(lr: cs_mod.Range, d: cs_mod.Range) ?[2]usize {
        if (d.end < lr.start or d.start > lr.end) return null;
        if (d.start == d.end and (d.start < lr.start or d.start > lr.end)) return null;
        const a = @max(d.start, lr.start) - lr.start;
        const b = @min(d.end, lr.end) - lr.start;
        return .{ @intCast(a), @intCast(b) };
    }

    /// Draws a row's text in runs of one colour, expanding tabs.
    fn drawRow(pc: *PaintCx, v: *const EditorView, s: []const u8, line: u64, palette: *const colors.Palette, fg: Color, pen: Vec2) void {
        const st = v.textStyle();
        const toks: []const zg_syntax.Token = if (v.syntax) |ds| ds.hl.tokens(line) else &.{};
        var ti: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            // The run: up to the next token start or tab.
            while (ti + 1 < toks.len and toks[ti + 1].start <= i) ti += 1;
            const color = if (ti < toks.len and toks[ti].start <= i) colors.colorOf(palette, toks[ti].hl, fg) else fg;
            var j = i;
            const next_tok: usize = if (ti + 1 < toks.len) toks[ti + 1].start else s.len;
            if (s[i] == '\t') {
                i += 1;
                continue;
            }
            while (j < s.len and j < @max(next_tok, i + 1) and s[j] != '\t') j += 1;
            pc.textLine(s[i..j], st, color, .{ .x = pen.x + v.xInLine(s, i), .y = pen.y });
            i = j;
        }
    }

    /// A multi-line text box for assistive technology.
    pub fn a11y(props: *const Props, _: *State) A11y {
        return .{ .role = .textbox, .name = props.a11y_label };
    }

    fn hitAt(ec: *EventCx, v: *EditorView, p: Vec2) u64 {
        return v.offsetAt(textPoint(ec, v, p));
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
                if (state.drag == .none) return false;
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
                try v.insertText(t);
                ec.respond(.{ .changed = true });
                ec.repaint();
                return true;
            },
            .key => |k| {
                if (k.action == .release) return false;
                const done = try key(ec, v, k);
                if (done) ec.repaint();
                return done;
            },
            else => return false,
        }
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
            .enter, .numpad_enter => if (!ro and !ctrl) try v.newline() else return false,
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
    return ui.leaf(Editor, props);
}
