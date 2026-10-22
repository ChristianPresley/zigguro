//! The text leaf of a Markdown view (E04.F06.S01.T02): a block's styled
//! runs wrapped across lines, with inline code backgrounds, strikethrough,
//! link colour and hover underline, syntax colours in code blocks, the
//! selection, and the streaming caret. Pointer input selects (drag, word
//! on double-click, block on triple-click) and opens links.

const std = @import("std");
const ast = @import("ast.zig");
const rich = @import("rich.zig");
const links = @import("links.zig");
const view_mod = @import("view.zig");
const code_view = @import("code_view.zig");
const geom = @import("../core/geom.zig");
const hash = @import("../core/hash.zig");
const widget = @import("../core/widget.zig");
const event_mod = @import("../input/event.zig");
const measure_mod = @import("../layout/measure.zig");
const style_mod = @import("../layout/style.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const text_mod = @import("../paint/text.zig");
const theme_mod = @import("../theme/theme.zig");
const tokens = @import("../theme/tokens.zig");

const MdViewState = view_mod.MdViewState;
const Entry = view_mod.Entry;
const LeafRef = view_mod.LeafRef;
const PaintCx = paint_cx.PaintCx;
const TextStyle = text_mod.TextStyle;
const Token = tokens.Token;
const Vec2 = geom.Vec2;
const Rect = geom.Rect;
const none = ast.none;

/// The x offset of a line under `al` in a box `w` wide.
fn lineX(al: paint_cx.TextAlign, w: f32, line_w: f32) f32 {
    return switch (al) {
        .start => 0,
        .center => @max(0, (w - line_w) / 2),
        .end => @max(0, w - line_w),
    };
}

/// `p` (local) with the line alignment taken out, for hit testing.
pub fn unalign(l: LeafRef, e: *const Entry, lines: []const rich.Line, w: f32, p: Vec2) Vec2 {
    _ = e;
    if (l.@"align" == .start or lines.len == 0) return p;
    const lh = l.shape.lineHeight();
    const row: usize = if (p.y <= 0) 0 else @min(lines.len - 1, @as(usize, @intFromFloat(p.y / lh)));
    return .{ .x = p.x - lineX(l.@"align", w, lines[row].w), .y = p.y };
}

/// A Markdown text leaf.
pub const RichText = struct {
    /// Shown in snapshots.
    pub const name = "md_text";
    /// Receives pointer input (selection and links).
    pub const hit_testable = true;

    /// The block and how to draw it.
    pub const Props = struct {
        view: *MdViewState,
        block: u32,
        /// The cache entry's generation (changes when the block does).
        gen: u32,
        shape_base: TextStyle,
        color: Token = .fg,
        wrap: bool = true,
        @"align": paint_cx.TextAlign = .start,
        /// Draw the streaming caret after the last glyph.
        caret: bool = false,
        /// A code block: syntax colours from the view's highlight cache.
        code: bool = false,
    };

    /// Hover state.
    pub const State = struct {
        hover_link: u32 = none,
    };

    fn shapeOf(props: *const Props, ts: text_mod.TextSystem) rich.Shape {
        return .{ .ts = ts, .base = props.shape_base };
    }

    fn ref(props: *const Props, ts: text_mod.TextSystem) LeafRef {
        return .{ .block = props.block, .node = .none, .shape = shapeOf(props, ts), .wrap = props.wrap, .@"align" = props.@"align" };
    }

    /// Shrinks to fit; never wider than its text.
    pub fn style(_: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        return .{ .shrink = 1 };
    }

    /// The wrapped text's size.
    pub fn measure(mc: *measure_mod.MeasureCx, props: *const Props, _: *State, max_w: ?f32) geom.Size {
        const s = props.view;
        const shape = shapeOf(props, mc.text);
        const lh = shape.lineHeight();
        const e = s.entry(props.block) orelse return .{ .w = 0, .h = lh };
        const lines = s.linesOf(e, shape, if (props.wrap) max_w else null);
        var w: f32 = 0;
        for (lines) |ln| w = @max(w, ln.w);
        if (props.caret) w += lh * 0.5;
        if (props.wrap) if (max_w) |m| {
            w = @min(w, m);
        };
        const n: f32 = @floatFromInt(@max(lines.len, 1));
        return .{ .w = w, .h = lh * n };
    }

    /// Selection, runs, decorations, caret.
    pub fn paint(pc: *PaintCx, props: *const Props, state: *State) void {
        const s = props.view;
        const shape = shapeOf(props, pc.text_sys);
        const e = s.entry(props.block) orelse return;
        const lines = s.linesOf(e, shape, if (props.wrap) pc.size.w else null);
        const f = &e.flat;
        const t = f.text.items;
        const lh = shape.lineHeight();
        const base_y = shape.baseline();
        const w = pc.size.w;

        // Selection.
        if (s.selection) |sel| if (sel.rangeIn(props.block, @intCast(t.len))) |r| {
            for (lines, 0..) |ln, i| {
                const a = @max(r[0], ln.start);
                const b = @min(r[1], ln.end);
                const y: f32 = lh * @as(f32, @floatFromInt(i));
                const x0 = lineX(props.@"align", w, ln.w);
                // A selected line break shows as a small extra width.
                const brk: f32 = if (r[1] > ln.end and r[0] <= ln.end and i + 1 < lines.len) shape.base.size * 0.3 else 0;
                if (a >= b and brk == 0) continue;
                const xa = if (a < b) shape.width(f, ln.start, a) else ln.w;
                const xb = if (a < b) shape.width(f, ln.start, b) else ln.w;
                pc.rect(.{ .x = x0 + xa, .y = y, .w = xb - xa + brk, .h = lh }, pc.color(.selection_bg), .{});
            }
        };

        const spans: []const code_view.Span = if (props.code) s.code.spansOf(props.block) else &.{};
        for (lines, 0..) |ln, i| {
            const top: f32 = lh * @as(f32, @floatFromInt(i));
            var x = lineX(props.@"align", w, ln.w);
            var at = ln.start;
            var si: usize = 0;
            while (at < ln.end) {
                const ri = f.runAt(at) orelse break;
                const run = f.runs.items[ri];
                var end = @min(ln.end, run.end);
                var color: Token = props.color;
                // Syntax colours split code runs further.
                if (spans.len > 0) {
                    while (si < spans.len and spans[si].end <= at) si += 1;
                    if (si < spans.len) {
                        if (spans[si].start > at) end = @min(end, spans[si].start) else {
                            end = @min(end, spans[si].end);
                            color = code_view.classToken(spans[si].class);
                        }
                    }
                }
                if (end <= at) break;
                const st = shape.styleOf(run.flags);
                const seg = t[at..end];
                const seg_w = shape.width(f, at, end);
                if (run.flags.link) color = .fg_link;
                if (run.flags.unsafe) color = .warning;
                if (run.flags.muted) color = .fg_muted;
                if (run.flags.code and !props.code) {
                    pc.rect(.{ .x = x - 2, .y = top + 1, .w = seg_w + 4, .h = lh - 2 }, pc.color(.bg_sunken), .all(3));
                }
                const c = pc.color(color);
                pc.textLine(seg, st, c, .{ .x = x, .y = top + base_y });
                const m = pc.text_sys.metrics(st);
                if (run.flags.strike) {
                    pc.rect(.{ .x = x, .y = top + base_y - m.ascent * 0.32, .w = seg_w, .h = @max(1, st.size / 14) }, c, .{});
                }
                const hovered = run.link != none and run.link == state.hover_link and s.hover != null and s.hover.?[0] == props.block;
                if (hovered or run.flags.unsafe) {
                    pc.rect(.{ .x = x, .y = top + base_y + m.descent * 0.4, .w = seg_w, .h = @max(1, st.size / 14) }, c.fade(if (run.flags.unsafe) 0.6 else 1), .{});
                }
                x += seg_w;
                at = end;
            }
        }

        if (props.caret and lines.len > 0) {
            const last = lines[lines.len - 1];
            const y = lh * @as(f32, @floatFromInt(lines.len - 1));
            const x = lineX(props.@"align", w, last.w) + last.w + 1;
            pc.rect(.{ .x = x, .y = y + lh * 0.15, .w = @round(lh * 0.45), .h = lh * 0.7 }, pc.color(.fg).fade(0.8), .all(1));
        }
    }

    fn linkAt(props: *const Props, ec: *event_mod.EventCx, pos: Vec2) u32 {
        const s = props.view;
        const e = s.entry(props.block) orelse return none;
        if (e.flat.links.items.len == 0) return none;
        const r = ec.rect();
        const l = ref(props, ec.textSystem());
        const lines = s.linesOf(e, l.shape, if (props.wrap) r.w else null);
        const local = unalign(l, e, lines, r.w, ec.local(pos));
        if (lines.len == 0 or local.y < 0 or local.y >= l.shape.lineHeight() * @as(f32, @floatFromInt(lines.len))) return none;
        const off = rich.hitTest(l.shape, &e.flat, lines, local);
        // The hit is the boundary nearest the pointer: check the glyph
        // under it, not the one after.
        const row: usize = @min(lines.len - 1, @as(usize, @intFromFloat(local.y / l.shape.lineHeight())));
        if (local.x > lines[row].w) return none;
        const probe = if (off > lines[row].start and l.shape.width(&e.flat, lines[row].start, off) > local.x) off - 1 else off;
        const ri = e.flat.runAt(@min(probe, @as(u32, @intCast(e.flat.text.items.len)) -| 1)) orelse return none;
        return e.flat.runs.items[ri].link;
    }

    /// Selection and links.
    pub fn event(ec: *event_mod.EventCx, props: *const Props, state: *State, ev: *const event_mod.InputEvent) bool {
        const s = props.view;
        switch (ev.*) {
            .pointer_down => |pd| {
                if (pd.button != .left or !s.props.selectable) return false;
                const pos = s.posAt(ec, pd.pos) orelse return false;
                const e = s.entry(props.block) orelse return false;
                var sel: view_mod.DocSelection = .{ .anchor = pos, .head = pos };
                if (pd.clicks == 2 and pos.block == props.block) {
                    const wd = rich.wordAt(e.flat.text.items, pos.off);
                    sel = .{ .anchor = .{ .block = props.block, .off = wd[0] }, .head = .{ .block = props.block, .off = wd[1] } };
                } else if (pd.clicks >= 3) {
                    sel = .{ .anchor = .{ .block = props.block, .off = 0 }, .head = .{ .block = props.block, .off = @intCast(e.flat.text.items.len) } };
                }
                s.selection = sel;
                s.dragging = pd.clicks < 2;
                s.drag_moved = false;
                s.repaintLeaves(ec);
                return true;
            },
            .pointer_move => |pm| {
                if (s.dragging) {
                    const pos = s.posAt(ec, pm.pos) orelse return true;
                    if (s.selection) |*sel| if (!sel.head.eql(pos)) {
                        sel.head = pos;
                        s.drag_moved = true;
                        s.repaintLeaves(ec);
                    };
                    ec.setCursor(.text);
                    return true;
                }
                const l = linkAt(props, ec, pm.pos);
                const usable = l != none and !(s.entry(props.block).?.flat.links.items[l].unsafe);
                ec.setCursor(if (usable) .pointer else if (s.props.selectable) .text else .default);
                if (l != state.hover_link) {
                    state.hover_link = l;
                    s.hover = if (l != none) .{ props.block, l } else null;
                    ec.repaint();
                }
                return false;
            },
            .pointer_leave => {
                if (state.hover_link != none) {
                    state.hover_link = none;
                    s.hover = null;
                    ec.repaint();
                }
                return false;
            },
            .pointer_up => |pu| {
                if (pu.button != .left) return false;
                const was_drag = s.dragging and s.drag_moved;
                s.dragging = false;
                if (s.selection) |sel| {
                    if (sel.isEmpty()) {
                        s.selection = null;
                        s.repaintLeaves(ec);
                    } else if (s.selectedText(s.gpa)) |txt| {
                        defer s.gpa.free(txt);
                        ec.setPrimary(txt);
                    }
                }
                if (was_drag) return true;
                const l = linkAt(props, ec, pu.pos);
                if (l == none) return true;
                const e = s.entry(props.block) orelse return true;
                const link = e.flat.links.items[l];
                // Unsafe destinations are shown, never opened.
                if (link.unsafe) return true;
                const cb = s.props.on_link orelse return true;
                const dest = e.flat.linkDest(l);
                const target: view_mod.LinkTarget = switch (link.kind) {
                    .url => .{ .url = dest },
                    .wiki => .{ .wiki = dest },
                    .anchor => .{ .anchor = dest[1..] },
                    .footnote => .{ .footnote = dest },
                };
                cb.f(cb.ctx, target, pu.mods.ctrl or pu.mods.super);
                return true;
            },
            else => return false,
        }
    }

    /// Static text named by its content.
    pub fn a11y(props: *const Props, _: *State) widget.A11y {
        const e = props.view.entries.get(props.block) orelse return .{ .role = .text };
        return .{ .role = .text, .name = e.flat.text.items };
    }

    /// Layout depends on the block's text and style, not the caret.
    pub fn layoutHash(props: *const Props) u64 {
        var p = props.*;
        p.caret = false;
        p.color = .fg;
        return hash.of(p);
    }

    /// Paint also follows the caret, colour and image generation.
    pub fn paintHash(props: *const Props) u64 {
        return hash.of(props.*);
    }
};

/// The streaming caret on a line of its own.
pub const Caret = struct {
    /// Shown in snapshots.
    pub const name = "md_caret";

    /// The text size it matches.
    pub const Props = struct { size: f32 };

    /// One line tall.
    pub fn measure(mc: *measure_mod.MeasureCx, props: *const Props, _: *widget.NoState, _: ?f32) geom.Size {
        const lh = mc.text.metrics(.{ .size = props.size }).line_h;
        return .{ .w = @round(lh * 0.45) + 1, .h = lh };
    }

    /// A block caret.
    pub fn paint(pc: *PaintCx, _: *const Props, _: *widget.NoState) void {
        const r = pc.bounds();
        pc.rect(.{ .x = 1, .y = r.h * 0.15, .w = r.w - 1, .h = r.h * 0.7 }, pc.color(.fg).fade(0.8), .all(1));
    }
};

test {
    std.testing.refAllDecls(@This());
}
