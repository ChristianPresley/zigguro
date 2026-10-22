//! `TextField` (E04.F05.S02.T01): the single- and multi-line text input
//! every field in the product uses. The caller owns the `TextBuffer`;
//! the node's state holds the selection, scroll offset and undo stack.
//!
//! Layout: single-line fields scroll horizontally, keeping the caret two
//! ems from the edges. Multi-line fields wrap at the content width and grow
//! from `min_rows` to `max_rows`, then scroll vertically.
//!
//! Not yet: bidi visual caret movement (waits on E03 `moveVisual`), caret
//! blink (the caret is steady, so idle frames stay at zero), IME preedit
//! input and PRIMARY selection (E04.F05.S02.T02 plugs into `ImeHooks`).

const std = @import("std");
const zg_text = @import("zg_text");
const geom = @import("../../core/geom.zig");
const hash = @import("../../core/hash.zig");
const widget = @import("../../core/widget.zig");
const response_mod = @import("../../core/response.zig");
const ui_mod = @import("../../core/ui.zig");
const paint_cx = @import("../../paint/paint_cx.zig");
const text_mod = @import("../../paint/text.zig");
const measure_mod = @import("../../layout/measure.zig");
const style_mod = @import("../../layout/style.zig");
const theme_mod = @import("../../theme/theme.zig");
const tokens = @import("../../theme/tokens.zig");
const event_mod = @import("../../input/event.zig");
const model = @import("model.zig");
const undo_mod = @import("undo.zig");
const commands = @import("commands.zig");

const grapheme = zg_text.unicode.grapheme;
const Size = geom.Size;
const Rect = geom.Rect;
const Vec2 = geom.Vec2;
const Response = response_mod.Response;
const Ui = ui_mod.Ui;
const PaintCx = paint_cx.PaintCx;
const MeasureCx = measure_mod.MeasureCx;
const EventCx = event_mod.EventCx;
const InputEvent = event_mod.InputEvent;
const TextSystem = text_mod.TextSystem;
const TextStyle = text_mod.TextStyle;
const TextBuffer = model.TextBuffer;
const Selection = model.Selection;
const Editor = commands.Editor;

/// What an IME hook did with an event.
pub const EventResult = enum { ignored, handled };

/// The seam E04.F05.S02.T02 installs IME, PRIMARY selection and prompt
/// behaviour through. Rects are window logical coordinates.
pub const ImeHooks = struct {
    /// Focus gained (true) or lost (false).
    onFocus: ?*const fn (*TextField.State, *EventCx, bool) void = null,
    /// The caret moved to `caret_rect`.
    onCaretMoved: ?*const fn (*TextField.State, *EventCx, caret_rect: Rect) void = null,
    /// Sees every event first; `handled` stops the field's own handling.
    onEvent: ?*const fn (*TextField.State, *EventCx, *const InputEvent) EventResult = null,
    /// The selection changed.
    onSelectionChanged: ?*const fn (*TextField.State, *EventCx) void = null,
};

/// Drawn per grapheme in password fields.
const bullet: u21 = 0x2022;

/// A text input.
pub const TextField = struct {
    /// Shown in snapshots.
    pub const name = "text_field";
    /// Fields take keyboard focus.
    pub const focusable = true;

    /// Text field props.
    pub const Props = struct {
        /// The text; owned by the caller and kept alive while shown.
        buffer: *TextBuffer,
        multiline: bool = false,
        min_rows: u16 = 1,
        max_rows: u16 = 1,
        placeholder: []const u8 = "",
        /// Draws bullets and blocks Copy/Cut.
        password: bool = false,
        read_only: bool = false,
        disabled: bool = false,
        /// The most bytes the text may hold.
        max_len: ?u32 = null,
        /// Draws the border in the danger colour.
        invalid: bool = false,
        /// Multi-line: Enter submits and Shift+Enter inserts a newline.
        /// When false, Enter inserts a newline and Ctrl+Enter submits.
        submit_on_enter: bool = true,
        font: text_mod.FontId = .ui,
        a11y_label: []const u8 = "",
        hooks: ?*const ImeHooks = null,
    };

    /// Pointer-drag granularity.
    pub const Drag = enum(u8) { none, char, word, line };

    /// Per-node editing state.
    pub const State = struct {
        sel: Selection = .{},
        preedit: ?model.Preedit = null,
        /// Content scroll offset (x for single-line, y for multi-line).
        scroll: Vec2 = .{},
        undo: undo_mod.UndoStack = .{},
        drag: Drag = .none,
        /// The word or line a double/triple-click drag started on.
        drag_origin: [2]u32 = .{ 0, 0 },
        /// Visible rows at the last layout (multi-line).
        rows: u16 = 1,
        /// Visual line breaks of the current text.
        lines: LineCache = .{},

        /// Selects the whole text.
        pub fn selectAll(s: *State, buf: *TextBuffer) void {
            s.sel = .{ .anchor = 0, .head = buf.len() };
        }

        /// Replaces the text, puts the caret at the end and clears undo.
        pub fn setText(s: *State, buf: *TextBuffer, t: []const u8) !void {
            try buf.setText(t);
            s.sel = .caret(buf.len());
            s.undo.deinit();
            s.scroll = .{};
        }
    };

    /// Frees the undo history and line cache.
    pub fn deinitState(s: *State) void {
        s.undo.deinit();
        s.lines.deinit();
    }

    fn padding(th: *const theme_mod.Theme) geom.Insets {
        return .xy(th.dim(.space_md), th.dim(.space_xs) + th.dim(.border_w));
    }

    /// Padding and the control height.
    pub fn style(props: *const Props, th: *const theme_mod.Theme) style_mod.Style {
        return .{ .padding = padding(th), .min_h = if (props.multiline) 0 else th.dim(.control_h), .min_w = 40, .shrink = 1 };
    }

    /// Text changes re-lay a multi-line field out (its row count may change).
    pub fn layoutHash(props: *const Props) u64 {
        const v: u64 = if (props.multiline) props.buffer.version else 0;
        return hash.of(props.*) ^ (v *% 0x9e37_79b9_7f4a_7c15);
    }

    /// Any text change repaints.
    pub fn paintHash(props: *const Props) u64 {
        return hash.of(props.*) ^ (@as(u64, props.buffer.version) *% 0x9e37_79b9_7f4a_7c15);
    }

    /// Twenty digits wide by default; multi-line fills `max_w` and is as
    /// tall as its wrapped text, clamped to `min_rows..max_rows`.
    pub fn measure(mc: *MeasureCx, props: *const Props, state: *State, max_w: ?f32) Size {
        const st = textStyle(props, mc.theme);
        const lh = mc.text.metrics(st).line_h;
        const w = max_w orelse mc.text.advance(st, '0') * 20;
        if (!props.multiline) return .{ .w = w, .h = lh };
        const g: Geo = .init(mc.text, st, props, w, &state.lines, props.buffer.slice());
        state.rows = clampRows(props, g.rowCount());
        return .{ .w = w, .h = lh * @as(f32, @floatFromInt(state.rows)) };
    }

    /// Background, selection, text or placeholder, caret, border.
    pub fn paint(pc: *PaintCx, props: *const Props, state: *State) void {
        const r = pc.bounds();
        const rad = pc.dim(.radius_md);
        const focused = pc.state.focused;
        pc.fill(r, if (props.disabled) .bg_sunken else .control_bg, rad);

        const content = r.inset(pc.style.padding);
        const st = textStyle(props, pc.theme);

        // With a preedit, lay out the text with the preedit in place of
        // the selection (in a throwaway line cache).
        var owned: ?[]u8 = null;
        defer if (owned) |o| pc.gpa.free(o);
        var temp: LineCache = .{};
        defer temp.deinit();
        var cache = &state.lines;
        var t: []const u8 = props.buffer.slice();
        state.sel.clamp(@intCast(t.len));
        var sel = state.sel;
        var underline: ?[2]u32 = null;
        if (state.preedit) |pe| if (pe.text.len > 0) {
            const sr = sel.range();
            if (std.mem.concat(pc.gpa, u8, &.{ t[0..sr[0]], pe.text, t[sr[1]..] })) |c| {
                owned = c;
                t = c;
                cache = &temp;
                const caret_at: u32 = sr[0] + @as(u32, @intCast(@max(0, @min(pe.cursor[1], @as(i32, @intCast(pe.text.len))))));
                sel = .caret(caret_at);
                underline = .{ sr[0], sr[0] + @as(u32, @intCast(pe.text.len)) };
            } else |_| {}
        };
        var g: Geo = .init(pc.text_sys, st, props, content.w, cache, t);
        const lh = g.m.line_h;
        if (owned != null and state.preedit.?.cursor[0] < 0) g.hide_caret = true;

        // Clamp the scroll offset to the content (a relayout may have
        // grown the field since the last event).
        const y0 = if (props.multiline) content.y else content.y + (content.h - lh) / 2;
        if (props.multiline) {
            const total = lh * @as(f32, @floatFromInt(g.rowCount()));
            state.scroll.y = std.math.clamp(state.scroll.y, 0, @max(0, total - content.h));
            state.scroll.x = 0;
        } else {
            const total = g.width(t, 0, @intCast(t.len)) + caretWidth(pc.theme);
            state.scroll.x = std.math.clamp(state.scroll.x, 0, @max(0, total - content.w));
            state.scroll.y = 0;
        }
        const origin: Vec2 = .{ .x = content.x - state.scroll.x, .y = y0 - state.scroll.y };

        pc.pushClip(.{ .x = content.x - 2, .y = r.y, .w = content.w + 4, .h = r.h }, 0);
        if (t.len == 0) {
            pc.textLine(props.placeholder, st, pc.color(.fg_muted), .{ .x = origin.x, .y = origin.y + baseline(g.m) });
        } else {
            const fg = pc.color(if (props.disabled) .fg_disabled else .fg);
            const sr = sel.range();
            const sel_color = pc.color(.selection_bg).fade(if (focused) 1 else 0.6);
            const first: usize = @intFromFloat(@max(0, @floor(state.scroll.y / lh)));
            for (g.lines[@min(first, g.lines.len)..], first..) |ln, row| {
                const y = origin.y + lh * @as(f32, @floatFromInt(row));
                if (y > content.bottom()) break;
                if (sr[0] != sr[1] and sr[0] <= ln.end and sr[1] >= ln.start) {
                    const a = @max(sr[0], @as(u32, @intCast(ln.start)));
                    const b = @min(sr[1], @as(u32, @intCast(ln.end)));
                    const x0 = g.width(t, @intCast(ln.start), a);
                    var x1 = g.width(t, @intCast(ln.start), b);
                    // A selected line break shows as a space-wide block.
                    if (sr[1] > ln.end) x1 += pc.text_sys.advance(st, ' ');
                    pc.rect(.{ .x = origin.x + x0, .y = y, .w = x1 - x0, .h = lh }, sel_color, .{});
                }
                drawLine(pc, &g, t[ln.start..ln.end], fg, .{ .x = origin.x, .y = y + baseline(g.m) });
                if (underline) |u| if (u[0] <= ln.end and u[1] >= ln.start) {
                    const a = @max(u[0], @as(u32, @intCast(ln.start)));
                    const b = @min(u[1], @as(u32, @intCast(ln.end)));
                    const x0 = g.width(t, @intCast(ln.start), a);
                    const x1 = g.width(t, @intCast(ln.start), b);
                    pc.rect(.{ .x = origin.x + x0, .y = y + lh - 2, .w = x1 - x0, .h = 1 }, fg, .{});
                };
            }
        }
        if (focused and !props.read_only and !props.disabled and !g.hide_caret) {
            const c = g.caret(t, sel.head);
            pc.rect(.{ .x = @round(origin.x + c.x), .y = origin.y + c.y, .w = caretWidth(pc.theme), .h = lh }, pc.color(.fg), .{});
        }
        pc.popClip();

        const border: tokens.Token = if (props.invalid) .danger else if (focused) .accent else if (pc.state.hovered) .border_strong else .control_border;
        pc.border(r, pc.dim(.border_w), pc.color(border), rad);
        pc.focusRing(r, rad);
    }

    /// A text box (masked value for passwords is E04.F09's job).
    pub fn a11y(props: *const Props, _: *State) widget.A11y {
        return .{
            .role = .textbox,
            .name = if (props.a11y_label.len > 0) props.a11y_label else props.placeholder,
            .disabled = props.disabled,
            .text = if (props.password) "" else props.buffer.slice(),
        };
    }

    /// Pointer selection, typing, navigation, clipboard and undo.
    pub fn event(ec: *EventCx, props: *const Props, state: *State, ev: *const InputEvent) bool {
        if (props.disabled or ec.phase == .capture) return false;
        if (props.hooks) |h| if (h.onEvent) |f| {
            if (f(state, ec, ev) == .handled) return true;
        };
        const ed: Editor = .{
            .buf = props.buffer,
            .sel = &state.sel,
            .undo = &state.undo,
            .opts = .{ .multiline = props.multiline, .read_only = props.read_only, .max_len = props.max_len },
            .now_ms = ec.nowMs(),
        };
        state.sel.clamp(props.buffer.len());
        switch (ev.*) {
            .focus_gained, .focus_lost => {
                const gained = ev.* == .focus_gained;
                state.undo.breakGroup();
                if (!gained) state.drag = .none;
                if (props.hooks) |h| if (h.onFocus) |f| f(state, ec, gained);
                ec.repaint();
                return false;
            },
            .pointer_down => |p| {
                if (p.button != .left) return false;
                const at = hitAt(ec, props, state, p.pos);
                switch (p.clicks) {
                    0, 1 => {
                        ed.moveTo(at, p.mods.shift);
                        state.drag = .char;
                    },
                    2 => {
                        state.drag_origin = ed.wordRange(at);
                        ed.selectRange(state.drag_origin);
                        state.drag = .word;
                    },
                    else => {
                        state.drag_origin = ed.lineRange(at);
                        ed.selectRange(state.drag_origin);
                        state.drag = .line;
                    },
                }
                state.sel.goal_x = null;
                state.undo.breakGroup();
                after(ec, props, state, false);
                return true;
            },
            .pointer_move => |p| {
                if (state.drag == .none) return false;
                const at = hitAt(ec, props, state, p.pos);
                switch (state.drag) {
                    .none => {},
                    .char => ed.moveTo(at, true),
                    .word, .line => {
                        const unit = if (state.drag == .word) ed.wordRange(at) else ed.lineRange(at);
                        const o = state.drag_origin;
                        state.sel = if (unit[0] < o[0]) .{ .anchor = o[1], .head = unit[0] } else .{ .anchor = o[0], .head = @max(unit[1], o[1]) };
                    },
                }
                after(ec, props, state, false);
                return true;
            },
            .pointer_up => |p| {
                if (p.button != .left or state.drag == .none) return false;
                state.drag = .none;
                return true;
            },
            .scroll => |sc| {
                if (!props.multiline) return false;
                const before = state.scroll.y;
                const k: f32 = if (sc.precise) 1 else 48;
                const g = geoFor(ec, props, state);
                const total = g.m.line_h * @as(f32, @floatFromInt(g.rowCount()));
                state.scroll.y = std.math.clamp(state.scroll.y + sc.dy * k, 0, @max(0, total - contentRect(ec).h));
                if (state.scroll.y == before) return false;
                ec.repaint();
                return true;
            },
            .text => |s| {
                if (props.read_only) return true;
                const changed = ed.insert(s) catch false;
                after(ec, props, state, changed);
                return true;
            },
            .key => |k| {
                if (k.action == .release) return false;
                return onKey(ec, props, state, ed, k);
            },
            // Enter/Space are handled as keys; never treat them as clicks.
            .activate => return true,
            .pointer_leave => return false,
        }
    }

    fn onKey(ec: *EventCx, props: *const Props, state: *State, ed: Editor, k: event_mod.KeyPress) bool {
        const ctrl = k.mods.ctrl or k.mods.super;
        const shift = k.mods.shift;
        var changed = false;
        switch (k.key) {
            .arrow_left => ed.move(if (ctrl) .word_left else .char_left, shift),
            .arrow_right => ed.move(if (ctrl) .word_right else .char_right, shift),
            .arrow_up, .arrow_down => {
                // Single-line fields leave Up/Down to lists around them.
                if (!props.multiline) return false;
                vertical(ec, props, state, ed, if (k.key == .arrow_up) -1 else 1, shift);
            },
            .page_up, .page_down => {
                if (!props.multiline) return false;
                const n: i32 = @max(1, state.rows - 1);
                vertical(ec, props, state, ed, if (k.key == .page_up) -n else n, shift);
            },
            .home, .end => {
                if (ctrl or !props.multiline) {
                    ed.move(if (k.key == .home) .doc_start else .doc_end, shift);
                } else {
                    const g = geoFor(ec, props, state);
                    const ln = g.lineOf(state.sel.head).line;
                    ed.moveTo(@intCast(if (k.key == .home) ln.start else ln.end), shift);
                    state.sel.goal_x = null;
                    state.undo.breakGroup();
                }
            },
            .backspace => changed = ed.backspace(ctrl) catch false,
            .delete => changed = ed.deleteForward(ctrl) catch false,
            .enter, .numpad_enter => {
                const newline = props.multiline and !props.read_only and (if (props.submit_on_enter) shift else !ctrl);
                if (newline) {
                    changed = ed.insert("\n") catch false;
                } else {
                    ec.respond(.{ .submitted = true });
                    return true;
                }
            },
            .key_a => if (ctrl) ed.selectAll() else return true,
            .key_c, .insert => if (ctrl) {
                if (!props.password and !state.sel.isEmpty()) ec.setClipboard(ed.selected());
                return true;
            } else return k.key == .key_c,
            .key_x => if (ctrl) {
                if (props.password or props.read_only or state.sel.isEmpty()) return true;
                ec.setClipboard(ed.selected());
                changed = ed.deleteSelection() catch false;
            } else return true,
            .key_v => if (ctrl) {
                changed = ed.commitText(ec.clipboard()) catch false;
            } else return true,
            .key_z => if (ctrl) {
                changed = (if (shift) ed.redoStep() else ed.undoStep()) catch false;
            } else return true,
            .key_y => if (ctrl) {
                changed = ed.redoStep() catch false;
            } else return true,
            else => {
                // Printable keys arrive again as `text`; claim them so key
                // bindings without modifiers do not fire while typing.
                return k.codepoint != 0 and !ctrl and !k.mods.alt;
            },
        }
        after(ec, props, state, changed);
        return true;
    }

    fn vertical(ec: *EventCx, props: *const Props, state: *State, ed: Editor, dir: i32, extend: bool) void {
        const g = geoFor(ec, props, state);
        const t = ed.text();
        const at = g.lineOf(state.sel.head);
        const goal = state.sel.goal_x orelse g.caret(t, state.sel.head).x;
        const rows: i32 = @intCast(g.rowCount());
        const want = @as(i32, @intCast(at.row)) + dir;
        const off: u32 = if (want < 0) 0 else if (want >= rows) @intCast(t.len) else g.hitLine(t, g.lineAt(@intCast(want)), goal);
        ed.moveTo(off, extend);
        state.sel.goal_x = goal;
        state.undo.breakGroup();
    }

    /// After a caret move or edit: report, re-lay out when the row count
    /// changed, scroll the caret into view and repaint.
    fn after(ec: *EventCx, props: *const Props, state: *State, changed: bool) void {
        const g = geoFor(ec, props, state);
        const t = props.buffer.slice();
        if (changed) {
            ec.respond(.{ .changed = true });
            if (props.multiline and clampRows(props, g.rowCount()) != state.rows) ec.relayout();
        }
        const c = g.caret(t, state.sel.head);
        const box = contentRect(ec);
        if (props.multiline) {
            const lh = g.m.line_h;
            if (c.y < state.scroll.y) state.scroll.y = c.y;
            if (c.y + lh > state.scroll.y + box.h) state.scroll.y = c.y + lh - box.h;
        } else {
            const margin = @min(2 * g.st.size, box.w / 3);
            if (c.x - state.scroll.x < margin) state.scroll.x = @max(0, c.x - margin);
            if (c.x - state.scroll.x > box.w - margin) state.scroll.x = c.x - box.w + margin;
        }
        ec.repaint();
        if (props.hooks) |h| {
            if (h.onCaretMoved) |f| {
                const y0 = if (props.multiline) box.y else box.y + (box.h - g.m.line_h) / 2;
                f(state, ec, .{ .x = box.x + c.x - state.scroll.x, .y = y0 + c.y - state.scroll.y, .w = caretWidth(ec.theme()), .h = g.m.line_h });
            }
            if (h.onSelectionChanged) |f| f(state, ec);
        }
    }

    fn contentRect(ec: *EventCx) Rect {
        return ec.rect().inset(padding(ec.theme()));
    }

    fn geoFor(ec: *EventCx, props: *const Props, state: *State) Geo {
        return .init(ec.textSystem(), textStyle(props, ec.theme()), props, contentRect(ec).w, &state.lines, props.buffer.slice());
    }

    /// The text offset under window point `p`.
    fn hitAt(ec: *EventCx, props: *const Props, state: *State, p: Vec2) u32 {
        const g = geoFor(ec, props, state);
        const box = contentRect(ec);
        const y0 = if (props.multiline) box.y else box.y + (box.h - g.m.line_h) / 2;
        return g.hit(props.buffer.slice(), .{ .x = p.x - box.x + state.scroll.x, .y = p.y - y0 + state.scroll.y });
    }
};

fn textStyle(props: *const TextField.Props, th: *const theme_mod.Theme) TextStyle {
    return .{ .font = props.font, .size = th.dim(.font_size) };
}

fn clampRows(props: *const TextField.Props, n: u32) u16 {
    const lo = @max(props.min_rows, 1);
    const hi = @max(props.max_rows, lo);
    return @intCast(std.math.clamp(n, lo, hi));
}

fn caretWidth(th: *const theme_mod.Theme) f32 {
    _ = th;
    return 2;
}

fn baseline(m: text_mod.LineMetrics) f32 {
    return (m.line_h - (m.ascent + m.descent)) / 2 + m.ascent;
}

fn drawLine(pc: *PaintCx, g: *const Geo, s: []const u8, c: geom.Color, pen: Vec2) void {
    if (!g.password) return pc.textLine(s, g.st, c, pen);
    // One bullet per grapheme, drawn in chunks from a stack buffer.
    var buf: [64 * 3]u8 = undefined;
    var n: usize = 0;
    var x = pen.x;
    const adv = g.ts.advance(g.st, bullet);
    var i: usize = 0;
    while (i < s.len) {
        i = grapheme.nextBoundary(s, i);
        n += std.unicode.utf8Encode(bullet, buf[n..]) catch 0;
        if (n + 3 > buf.len or i >= s.len) {
            pc.textLine(buf[0..n], g.st, c, .{ .x = x, .y = pen.y });
            x += adv * @as(f32, @floatFromInt(n / 3));
            n = 0;
        }
    }
}

/// The visual lines of a field's text, rebuilt when the text, wrap width
/// or font changes, so caret, hit-test and paint queries cost O(rows
/// shown) instead of a pass over the whole text.
const LineCache = struct {
    gpa: ?std.mem.Allocator = null,
    lines: std.ArrayList(text_mod.Line) = .empty,
    key: [4]u64 = .{ std.math.maxInt(u64), 0, 0, 0 },

    fn deinit(c: *LineCache) void {
        if (c.gpa) |gpa| c.lines.deinit(gpa);
        c.* = .{};
    }

    /// The lines of `t`; empty when out of memory (nothing is drawn).
    fn get(c: *LineCache, gpa: std.mem.Allocator, g: *const Geo, t: []const u8, version: u64) []const text_mod.Line {
        const key: [4]u64 = .{ version, @as(u32, @bitCast(g.wrap orelse -1)), @as(u32, @bitCast(g.st.size)) | (@as(u64, @intFromEnum(g.st.font)) << 32), t.len };
        if (std.mem.eql(u64, &key, &c.key)) return c.lines.items;
        c.gpa = gpa;
        c.lines.clearRetainingCapacity();
        var it: text_mod.LineIter = .{ .ts = g.ts, .st = g.st, .s = t, .max_w = g.wrap };
        while (it.next()) |ln| c.lines.append(gpa, ln) catch {
            c.lines.clearRetainingCapacity();
            c.key[0] = std.math.maxInt(u64);
            return &.{};
        };
        c.key = key;
        return c.lines.items;
    }
};

/// Text geometry for one field: visual lines, caret positions and hit
/// testing, in content coordinates (before scrolling).
const Geo = struct {
    ts: TextSystem,
    st: TextStyle,
    m: text_mod.LineMetrics,
    password: bool,
    /// The wrap width (multi-line), or null.
    wrap: ?f32,
    lines: []const text_mod.Line = &.{},
    hide_caret: bool = false,

    fn init(ts: TextSystem, st: TextStyle, props: *const TextField.Props, content_w: f32, cache: *LineCache, t: []const u8) Geo {
        const wrap = props.multiline and !props.password;
        var g: Geo = .{ .ts = ts, .st = st, .m = ts.metrics(st), .password = props.password, .wrap = if (wrap) @max(content_w, 1) else null };
        g.lines = cache.get(props.buffer.gpa, &g, t, props.buffer.version);
        return g;
    }

    /// The width of `t[a..b]` as drawn.
    fn width(g: *const Geo, t: []const u8, a: u32, b: u32) f32 {
        if (b <= a) return 0;
        if (!g.password) return g.ts.width(g.st, t[a..b]);
        return @as(f32, @floatFromInt(grapheme.count(t[a..b]))) * g.ts.advance(g.st, bullet);
    }

    fn rowCount(g: *const Geo) u32 {
        return @max(@as(u32, @intCast(g.lines.len)), 1);
    }

    const LineAt = struct { line: text_mod.Line, row: u32 };

    /// The visual line holding offset `off` (the later line when `off`
    /// ends one line and starts the next).
    fn lineOf(g: *const Geo, off: u32) LineAt {
        if (g.lines.len == 0) return .{ .line = .{ .start = 0, .end = 0, .w = 0 }, .row = 0 };
        // The last line starting at or before `off`.
        var lo: usize = 0;
        var hi: usize = g.lines.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (g.lines[mid].start <= off) lo = mid else hi = mid;
        }
        return .{ .line = g.lines[lo], .row = @intCast(lo) };
    }

    /// Visual line `row` (the last line when past the end).
    fn lineAt(g: *const Geo, row: u32) text_mod.Line {
        if (g.lines.len == 0) return .{ .start = 0, .end = 0, .w = 0 };
        return g.lines[@min(row, g.lines.len - 1)];
    }

    /// The caret's top-left corner for offset `off`.
    fn caret(g: *const Geo, t: []const u8, off: u32) Vec2 {
        const at = g.lineOf(off);
        const end: u32 = @intCast(at.line.end);
        return .{ .x = g.width(t, @intCast(at.line.start), @min(off, end)), .y = g.m.line_h * @as(f32, @floatFromInt(at.row)) };
    }

    /// The grapheme boundary in `ln` nearest to `x`.
    fn hitLine(g: *const Geo, t: []const u8, ln: text_mod.Line, x: f32) u32 {
        var i: usize = ln.start;
        var pen: f32 = 0;
        while (i < ln.end) {
            const next = @min(grapheme.nextBoundary(t, i), ln.end);
            const w = g.width(t, @intCast(i), @intCast(next));
            if (x < pen + w / 2) return @intCast(i);
            pen += w;
            i = next;
        }
        return @intCast(ln.end);
    }

    /// The offset nearest to content point `p`.
    fn hit(g: *const Geo, t: []const u8, p: Vec2) u32 {
        if (p.y < 0 and g.wrap != null) return 0;
        const row: u32 = if (p.y <= 0) 0 else @intFromFloat(@floor(p.y / g.m.line_h));
        const rows = g.rowCount();
        if (row >= rows and g.wrap != null) return @intCast(t.len);
        return g.hitLine(t, g.lineAt(@min(row, rows - 1)), p.x);
    }
};

/// A text field over `props.buffer`. Returns `.changed` after an edit and
/// `.submitted` on Enter (see `Props.submit_on_enter`); the node's
/// `State` (selection, undo) is `ui.lastState(TextField)`.
pub fn textField(ui: *Ui, props: TextField.Props) Response {
    return ui.leaf(TextField, props);
}

test {
    std.testing.refAllDecls(@This());
}
