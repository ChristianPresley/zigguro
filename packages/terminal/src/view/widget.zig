//! The terminal widget (E06.F05.S01.T02, first cut): paints a
//! `TerminalView`'s viewport as a cell grid and routes input to it.
//!
//! Paint per viewport row: background runs (default-background runs are
//! left to the clear), glyph runs of one colour and face, then underline
//! (single, double, curly, dotted, dashed), strike and overline. The
//! cursor follows DECSCUSR (block, underline, bar; hollow while unfocused)
//! and DECTCEM, and shows only while following output. A thumb on the
//! right shows the position while scrolled back.
//!
//! Default colours follow the zg_gui theme unless the application set
//! its own (OSC 10/11). Layout fits the grid to the widget and resizes the
//! terminal (`TerminalView.fit`).
//!
//! Open (E06.F05): per-row damage and layer caching, E03 cell layout with
//! ligatures and procedural box drawing, minimum contrast, IME preedit,
//! selection, hyperlink hover and blink.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_terminal = @import("zg_terminal");
const view_mod = @import("terminal_view.zig");
const pal = @import("palette.zig");
const route = @import("input_route.zig");

const TerminalView = view_mod.TerminalView;
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
const Cell = zg_terminal.screen.Cell;
const TStyle = zg_terminal.screen.Style;

/// The terminal widget.
pub const Term = struct {
    /// Shown in snapshots.
    pub const name = "terminal";
    /// Terminals take keyboard focus.
    pub const focusable = true;

    /// Terminal props.
    pub const Props = struct {
        view: *TerminalView,
        a11y_label: []const u8 = "Terminal",
    };

    /// Per-node state: a glyph-run scratch buffer.
    pub const State = struct {
        run: std.ArrayList(u8) = .empty,
        gpa: ?std.mem.Allocator = null,
    };

    /// Frees the scratch buffer.
    pub fn deinitState(s: *State) void {
        if (s.gpa) |g| s.run.deinit(g);
    }

    /// Fills the space it is given.
    pub fn style(_: *const Props, _: *const Theme) Style {
        return .{ .grow = 1, .shrink = 1, .basis = .{ .px = 0 }, .min_w = 40, .min_h = 24, .align_self = .stretch };
    }

    /// Output never changes the layout.
    pub fn layoutHash(props: *const Props) u64 {
        return @intFromPtr(props.view);
    }

    /// Any output or view change repaints.
    pub fn paintHash(props: *const Props) u64 {
        return @intFromPtr(props.view) ^ (props.view.generation *% 0x9e37_79b9_7f4a_7c15);
    }

    /// The terminal's current grid, or what the parent offers.
    pub fn measure(mc: *MeasureCx, props: *const Props, _: *State, max_w: ?f32) Size {
        const v = props.view;
        v.syncMetrics(mc.text);
        const pad = 2 * v.opts.padding;
        const cols: f32 = @floatFromInt(v.term.cols());
        const rows: f32 = @floatFromInt(v.term.rows());
        return .{ .w = max_w orelse cols * v.cell_w + pad, .h = rows * v.cell_h + pad };
    }

    fn defaults(pc: *PaintCx, t: *const zg_terminal.Terminal) pal.Defaults {
        const p = &t.palette;
        const d = &t.default_palette;
        return .{
            .fg = if (std.mem.eql(u8, &p.fg, &d.fg)) pc.color(.fg) else pal.fromRgb(p.fg),
            .bg = if (std.mem.eql(u8, &p.bg, &d.bg)) pc.color(.bg_base) else pal.fromRgb(p.bg),
        };
    }

    /// See the module doc.
    pub fn paint(pc: *PaintCx, props: *const Props, state: *State) void {
        const v = props.view;
        state.gpa = pc.gpa;
        v.syncMetrics(pc.text_sys);
        _ = v.fit(pc.size.w, pc.size.h);
        const t = v.term;
        const r = pc.bounds();
        const reverse = t.modes.get(.reverse_video);
        const d = defaults(pc, t);
        const clear = if (reverse) d.fg else d.bg;
        pc.rect(r, clear, .{});

        const pad = v.opts.padding;
        const cw = v.cell_w;
        const ch = v.cell_h;
        const m = pc.text_sys.metrics(v.textStyle(false, false));
        const base = (ch - (m.ascent + m.descent)) / 2 + m.ascent;
        const ropts: pal.Options = .{ .bold_is_bright = v.opts.bold_is_bright, .reverse_video = reverse };
        const screen = t.screen();
        const rows = t.rows();
        const cols = t.cols();

        pc.pushClip(r, 0);
        for (0..rows) |yi| {
            const y: u16 = @intCast(yi);
            const pin = screen.pages.viewportRow(y);
            const page = &pin.node.page;
            const cells = pin.cells();
            const n = @min(cells.len, cols);
            const top = pad + @as(f32, @floatFromInt(y)) * ch;

            // Backgrounds, merged into runs.
            var x: usize = 0;
            while (x < n) {
                const c0 = pal.resolve(&t.palette, d, page.styleOf(cells[x]), cells[x], ropts);
                var e = x + 1;
                while (e < n) : (e += 1) {
                    const c = pal.resolve(&t.palette, d, page.styleOf(cells[e]), cells[e], ropts);
                    if (c.bg_default != c0.bg_default or @as(u32, @bitCast(c.bg)) != @as(u32, @bitCast(c0.bg))) break;
                }
                if (!c0.bg_default) pc.rect(.{ .x = pad + @as(f32, @floatFromInt(x)) * cw, .y = top, .w = @as(f32, @floatFromInt(e - x)) * cw, .h = ch }, c0.bg, .{});
                x = e;
            }

            // Glyphs, in runs of one colour and face; wide cells alone.
            x = 0;
            while (x < n) {
                const c = cells[x];
                if (c.isEmpty() or c.wide == .spacer_tail or c.wide == .spacer_head) {
                    x += 1;
                    continue;
                }
                const st = page.styleOf(c);
                const res = pal.resolve(&t.palette, d, st, c, ropts);
                state.run.clearRetainingCapacity();
                var e = x;
                while (e < n) {
                    const ce = cells[e];
                    if (ce.isEmpty() or ce.wide != .narrow and e != x) break;
                    const se = page.styleOf(ce);
                    if (se.flags.bold != st.flags.bold or se.flags.italic != st.flags.italic) break;
                    const re = pal.resolve(&t.palette, d, se, ce, ropts);
                    if (@as(u32, @bitCast(re.fg)) != @as(u32, @bitCast(res.fg))) break;
                    appendCell(state, pc.gpa, page, &ce) catch break;
                    e += 1;
                    if (ce.wide == .wide) break;
                }
                if (e == x) e = x + 1;
                if (!st.flags.invisible and state.run.items.len > 0) {
                    pc.textLine(state.run.items, v.textStyle(st.flags.bold, st.flags.italic), res.fg, .{ .x = pad + @as(f32, @floatFromInt(x)) * cw, .y = top + base });
                }
                x = e;
            }

            // Decorations.
            for (cells[0..n], 0..) |c, xi| {
                if (c.style == 0) continue;
                const st = page.styleOf(c);
                if (st.underline == .none and !st.flags.strike and !st.flags.overline) continue;
                const res = pal.resolve(&t.palette, d, st, c, ropts);
                const cx = pad + @as(f32, @floatFromInt(xi)) * cw;
                const w = if (c.wide == .wide) 2 * cw else cw;
                const th = @max(1, @round(ch / 16));
                const ul_y = top + base + @max(1, @round(m.descent / 2));
                const ulc = pal.underlineColor(&t.palette, st, res.fg);
                switch (st.underline) {
                    .none => {},
                    .single => pc.rect(.{ .x = cx, .y = ul_y, .w = w, .h = th }, ulc, .{}),
                    .double => {
                        pc.rect(.{ .x = cx, .y = ul_y - th, .w = w, .h = th }, ulc, .{});
                        pc.rect(.{ .x = cx, .y = ul_y + th, .w = w, .h = th }, ulc, .{});
                    },
                    .curly => curly(pc, cx, ul_y, w, th, ulc),
                    .dotted => dashes(pc, cx, ul_y, w, th, th, ulc),
                    .dashed => dashes(pc, cx, ul_y, w, th, @max(3, cw / 3), ulc),
                }
                if (st.flags.strike) pc.rect(.{ .x = cx, .y = top + base - m.ascent / 3, .w = w, .h = th }, res.fg, .{});
                if (st.flags.overline) pc.rect(.{ .x = cx, .y = top, .w = w, .h = th }, res.fg, .{});
            }
        }

        // The cursor, while following output.
        if (t.modes.get(.cursor_visible) and !v.scrolledBack()) {
            const cur = screen.cursor;
            const pin = screen.pages.viewportRow(cur.y);
            const cells = pin.cells();
            const c: Cell = if (cur.x < cells.len) cells[cur.x] else .blank;
            const wide = c.wide == .wide;
            const cr: Rect = .{ .x = pad + @as(f32, @floatFromInt(cur.x)) * cw, .y = pad + @as(f32, @floatFromInt(cur.y)) * ch, .w = if (wide) 2 * cw else cw, .h = ch };
            const ccol = if (t.palette.cursor) |cc| pal.fromRgb(cc) else d.fg;
            const focused = pc.state.focused or v.focused;
            const shape: enum { block, underline, bar } = switch (t.cursor_shape) {
                .blinking_block, .steady_block => .block,
                .blinking_underline, .steady_underline => .underline,
                .blinking_bar, .steady_bar => .bar,
            };
            if (!focused) {
                hollow(pc, cr, ccol);
            } else switch (shape) {
                .block => {
                    pc.rect(cr, ccol, .{});
                    // The glyph again, in the background colour.
                    if (!c.isEmpty()) {
                        state.run.clearRetainingCapacity();
                        appendCell(state, pc.gpa, &pin.node.page, &c) catch {};
                        const st = pin.node.page.styleOf(c);
                        const res = pal.resolve(&t.palette, d, st, c, ropts);
                        pc.textLine(state.run.items, v.textStyle(st.flags.bold, st.flags.italic), res.bg, .{ .x = cr.x, .y = cr.y + base });
                    }
                },
                .underline => pc.rect(.{ .x = cr.x, .y = cr.y + ch - 2, .w = cr.w, .h = 2 }, ccol, .{}),
                .bar => pc.rect(.{ .x = cr.x, .y = cr.y, .w = 2, .h = ch }, ccol, .{}),
            }
        }

        // The scrollback position.
        if (v.scrolledBack()) {
            const sp = v.scrollPosition();
            const total: f32 = @floatFromInt(@max(sp.total, 1));
            const h = @max(16, r.h * @as(f32, @floatFromInt(rows)) / total);
            const y = (r.h - h) * @as(f32, @floatFromInt(sp.top)) / @max(1, total - @as(f32, @floatFromInt(rows)));
            pc.rect(.{ .x = r.w - 6, .y = y, .w = 4, .h = h }, pc.color(.fg_muted).fade(0.6), .all(2));
        }
        pc.popClip();
    }

    fn appendCell(state: *State, gpa: std.mem.Allocator, page: *const zg_terminal.screen.Page, c: *const Cell) !void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c.codepoint(), &buf) catch return;
        try state.run.appendSlice(gpa, buf[0..n]);
        if (page.grapheme(c)) |extra| for (extra) |cp| {
            const k = std.unicode.utf8Encode(cp, &buf) catch continue;
            try state.run.appendSlice(gpa, buf[0..k]);
        };
    }

    fn hollow(pc: *PaintCx, r: Rect, c: Color) void {
        pc.rect(.{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, c, .{});
        pc.rect(.{ .x = r.x, .y = r.y + r.h - 1, .w = r.w, .h = 1 }, c, .{});
        pc.rect(.{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, c, .{});
        pc.rect(.{ .x = r.x + r.w - 1, .y = r.y, .w = 1, .h = r.h }, c, .{});
    }

    fn dashes(pc: *PaintCx, x: f32, y: f32, w: f32, th: f32, len: f32, c: Color) void {
        var p: f32 = 0;
        while (p < w) : (p += 2 * len) pc.rect(.{ .x = x + p, .y = y, .w = @min(len, w - p), .h = th }, c, .{});
    }

    fn curly(pc: *PaintCx, x: f32, y: f32, w: f32, th: f32, c: Color) void {
        // A two-level zig-zag, one step per pixel column pair.
        var p: f32 = 0;
        while (p < w) : (p += 2) {
            const phase = @mod(p, 8);
            const dy: f32 = if (phase < 4) phase / 2 - 1 else 3 - phase / 2;
            pc.rect(.{ .x = x + p, .y = y + dy * th, .w = @min(2, w - p), .h = th }, c, .{});
        }
    }

    /// A text box for assistive technology.
    pub fn a11y(props: *const Props, _: *State) A11y {
        return .{ .role = .textbox, .name = props.a11y_label };
    }

    /// The cell under window point `p` (clamped to the grid) and the pixel
    /// offset in the text area.
    fn cellAt(ec: *EventCx, v: *TerminalView, p: Vec2) struct { cell: [2]u16, px: [2]u32 } {
        const l = ec.local(p);
        const x = @max(0, l.x - v.opts.padding);
        const y = @max(0, l.y - v.opts.padding);
        const cx: u16 = @intFromFloat(@min(@floor(x / v.cell_w), @as(f32, @floatFromInt(v.term.cols() - 1))));
        const cy: u16 = @intFromFloat(@min(@floor(y / v.cell_h), @as(f32, @floatFromInt(v.term.rows() - 1))));
        return .{ .cell = .{ cx, cy }, .px = .{ @intFromFloat(x), @intFromFloat(y) } };
    }

    /// See `TerminalView` for the routing rules.
    pub fn event(ec: *EventCx, props: *const Props, _: *State, ev: *const InputEvent) bool {
        if (ec.phase == .capture) return false;
        const v = props.view;
        const before = v.generation;
        const handled = handle(ec, v, ev);
        if (v.generation != before) ec.repaint();
        return handled;
    }

    fn handle(ec: *EventCx, v: *TerminalView, ev: *const InputEvent) bool {
        switch (ev.*) {
            .focus_gained => v.setFocused(true),
            .focus_lost => v.setFocused(false),
            .key => |k| return v.key(k, if (k.action == .release) "" else ec.clipboard()),
            .text => |s| {
                v.text(s);
                return true;
            },
            .pointer_down => |p| {
                ec.focus();
                if (!v.reportsMouse(p)) return true;
                const at = cellAt(ec, v, p.pos);
                v.buttons |= route.buttonBit(p.button);
                v.last_motion = at.cell;
                _ = v.reportMouse(.{ .kind = .press, .button = route.mouseButton(p.button), .cell = at.cell, .px = at.px, .mods = route.mods(p.mods), .buttons_down = v.buttons });
                ec.capture();
                return true;
            },
            .pointer_up => |p| {
                if (v.buttons == 0) return false;
                v.buttons &= ~route.buttonBit(p.button);
                if (v.buttons == 0) ec.releaseCapture();
                if (!v.reportsMouse(p)) return true;
                const at = cellAt(ec, v, p.pos);
                _ = v.reportMouse(.{ .kind = .release, .button = route.mouseButton(p.button), .cell = at.cell, .px = at.px, .mods = route.mods(p.mods), .buttons_down = v.buttons });
                return true;
            },
            .pointer_move => |p| {
                ec.setCursor(.text);
                if (!v.reportsMouse(p)) return false;
                const at = cellAt(ec, v, p.pos);
                const held: u8 = if (v.buttons & 1 != 0) 0 else if (v.buttons & 2 != 0) 1 else if (v.buttons & 4 != 0) 2 else 3;
                _ = v.reportMouse(.{ .kind = .motion, .button = held, .cell = at.cell, .px = at.px, .mods = route.mods(p.mods), .buttons_down = v.buttons });
                return true;
            },
            .scroll => |sc| {
                var notches: i32 = 0;
                if (sc.precise) {
                    v.scroll_rem += sc.dy / v.cell_h;
                    notches = @intFromFloat(@trunc(v.scroll_rem));
                    v.scroll_rem -= @floatFromInt(notches);
                } else notches = @intFromFloat(@round(sc.dy));
                const at = cellAt(ec, v, sc.pos);
                const report = v.reportsMouse(.{ .pos = sc.pos });
                v.wheel(notches, at.cell, at.px, .{}, report);
                return true;
            },
            else => return false,
        }
        return false;
    }
};

/// Adds a terminal for `view` to the tree (in a `terminalFocus` key
/// context), records its node in `view.node` (for focusing) and points the
/// view at the window for paste confirmations.
pub fn terminal(ui: *Ui, props: Term.Props) zg_gui.Response {
    props.view.win = ui.win;
    ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "terminalFocus" });
    defer ui.close();
    const r = ui.leaf(Term, props);
    props.view.node = ui.lastNode();
    return r;
}
