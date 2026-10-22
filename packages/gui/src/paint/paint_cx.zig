//! `PaintCx`: what a widget's `paint` function draws with. Coordinates are
//! local to the node (0,0 is its top-left corner); the paint pass places
//! the recorded ops at the node's absolute position.

const std = @import("std");
const geom = @import("../core/geom.zig");
const canvas = @import("canvas.zig");
const text = @import("text.zig");
const theme_mod = @import("../theme/theme.zig");
const tokens = @import("../theme/tokens.zig");
const style_mod = @import("../layout/style.zig");

const default_style: style_mod.Style = .{};

const Rect = geom.Rect;
const Color = geom.Color;
const Radii = geom.Radii;
const Vec2 = geom.Vec2;
const Token = tokens.Token;

/// The node's live interaction state.
pub const Interaction = packed struct(u8) {
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    /// Focus came from the keyboard: draw the focus ring (WCAG 2.4.7).
    focus_visible: bool = false,
    disabled: bool = false,
    _pad: u3 = 0,
};

/// Horizontal text alignment within a box.
pub const TextAlign = enum(u8) { start, center, end };

/// Passed to `W.paint(pc, props, state)`.
pub const PaintCx = struct {
    gpa: std.mem.Allocator,
    ops: *canvas.OpList,
    theme: *const theme_mod.Theme,
    text_sys: text.TextSystem,
    /// The node's size.
    size: geom.Size,
    /// The node's style (container decoration).
    style: *const style_mod.Style = &default_style,
    state: Interaction = .{},
    /// Set when an append failed; the paint pass repaints next frame.
    oom: bool = false,

    /// The node's bounds in local coordinates.
    pub fn bounds(pc: *const PaintCx) Rect {
        return .{ .w = pc.size.w, .h = pc.size.h };
    }

    /// The colour of a style fill (transparent for `.none`).
    pub fn fillColor(pc: *const PaintCx, f: style_mod.Fill) geom.Color {
        return switch (f) {
            .none => geom.Color.transparent,
            .token => |t| pc.theme.color(t),
            .color => |c| c,
        };
    }

    /// The colour of a theme token.
    pub fn color(pc: *const PaintCx, t: Token) Color {
        return pc.theme.color(t);
    }

    /// The value of a dimension token.
    pub fn dim(pc: *const PaintCx, d: tokens.Dim) f32 {
        return pc.theme.dim(d);
    }

    fn push(pc: *PaintCx, op: canvas.Op) void {
        pc.ops.ops.append(pc.gpa, op) catch {
            pc.oom = true;
        };
    }

    /// A filled rounded rectangle.
    pub fn rect(pc: *PaintCx, r: Rect, c: Color, radii: Radii) void {
        if (c.a == 0 or r.isEmpty()) return;
        pc.push(.{ .rect = .{ .r = r, .fill = c, .radii = radii } });
    }

    /// A filled rounded rectangle in a token colour.
    pub fn fill(pc: *PaintCx, r: Rect, t: Token, radius: f32) void {
        pc.rect(r, pc.color(t), .all(radius));
    }

    /// A uniform outline drawn inside `r`.
    pub fn border(pc: *PaintCx, r: Rect, width: f32, c: Color, radius: f32) void {
        if (c.a == 0 or width <= 0 or r.isEmpty()) return;
        pc.push(.{ .border = .{ .r = r, .widths = .all(width), .color = c, .radii = .all(radius) } });
    }

    /// A drop shadow.
    pub fn shadow(pc: *PaintCx, r: Rect, radius: f32, sigma: f32, spread: f32, c: Color) void {
        if (c.a == 0) return;
        pc.push(.{ .shadow = .{ .r = r, .radii = .all(radius), .sigma = sigma, .spread = spread, .color = c } });
    }

    /// A linear gradient.
    pub fn gradient(pc: *PaintCx, r: Rect, p0: Vec2, p1: Vec2, c0: Color, c1: Color, radius: f32) void {
        pc.push(.{ .gradient = .{ .r = r, .p0 = p0, .p1 = p1, .c0 = c0, .c1 = c1, .radii = .all(radius) } });
    }

    /// A textured rectangle.
    pub fn image(pc: *PaintCx, tex: canvas.TextureId, dst: Rect, uv: Rect, tint: Color, radius: f32) void {
        pc.push(.{ .image = .{ .tex = tex, .dst = dst, .uv = uv, .tint = tint, .radii = .all(radius) } });
    }

    /// Clips the following ops to `r` until `popClip` (pairs must match
    /// within one paint call).
    pub fn pushClip(pc: *PaintCx, r: Rect, radius: f32) void {
        pc.push(.{ .push_clip = .{ .r = r, .radii = .all(radius) } });
    }

    /// Ends the innermost `pushClip`.
    pub fn popClip(pc: *PaintCx) void {
        pc.push(.pop_clip);
    }

    /// The focus ring around `r` when focus is keyboard-visible.
    pub fn focusRing(pc: *PaintCx, r: Rect, radius: f32) void {
        if (!pc.state.focus_visible) return;
        const off = pc.dim(.focus_ring_offset);
        const w = pc.dim(.focus_ring_w);
        pc.border(r.outset(off + w), w, pc.color(.focus_ring), radius + off + w);
    }

    /// One line of text with its baseline at `baseline`.
    pub fn textLine(pc: *PaintCx, s: []const u8, st: text.TextStyle, c: Color, pen: Vec2) void {
        if (s.len == 0 or c.a == 0) return;
        const start: u32 = @intCast(pc.ops.quads.items.len);
        var x = pen.x;
        var it = text.Codepoints{ .s = s };
        while (it.next()) |cp| {
            if (pc.text_sys.glyph(st, cp, .{ .x = x, .y = pen.y })) |q| {
                pc.ops.quads.append(pc.gpa, q) catch {
                    pc.oom = true;
                    return;
                };
            }
            x += pc.text_sys.advance(st, cp);
        }
        const n: u32 = @as(u32, @intCast(pc.ops.quads.items.len)) - start;
        if (n > 0) pc.push(.{ .glyphs = .{ .start = start, .len = n, .color = c, .aa = .grayscale } });
    }

    /// Text in `box`, wrapped at its width when `wrap` is set, vertically
    /// starting at the top, aligned horizontally by `al`. Lines past the
    /// bottom are not drawn.
    pub fn textBox(pc: *PaintCx, s: []const u8, st: text.TextStyle, c: Color, box: Rect, wrap: bool, al: TextAlign) void {
        const m = pc.text_sys.metrics(st);
        var y = box.y + (m.line_h - (m.ascent + m.descent)) / 2 + m.ascent;
        var it = text.LineIter{ .ts = pc.text_sys, .st = st, .s = s, .max_w = if (wrap) box.w else null };
        while (it.next()) |ln| {
            if (y - m.ascent > box.bottom()) break;
            const x = switch (al) {
                .start => box.x,
                .center => box.x + (box.w - ln.w) / 2,
                .end => box.x + box.w - ln.w,
            };
            pc.textLine(s[ln.start..ln.end], st, c, .{ .x = x, .y = y });
            y += m.line_h;
        }
    }
};

test "text line records one glyph run" {
    const gpa = std.testing.allocator;
    var ops: canvas.OpList = .{};
    defer ops.deinit(gpa);
    var mono: text.MonoText = .{};
    var pc: PaintCx = .{ .gpa = gpa, .ops = &ops, .theme = &theme_mod.zigguro_dark, .text_sys = mono.system(), .size = .{ .w = 100, .h = 20 } };
    pc.textLine("a b", .{ .size = 10 }, Color.hex(0xffffff), .{ .x = 0, .y = 10 });
    try std.testing.expectEqual(@as(usize, 1), ops.ops.items.len);
    try std.testing.expectEqual(@as(u32, 2), ops.ops.items[0].glyphs.len); // the space has no quad
    try std.testing.expectEqual(@as(f32, 12.5), ops.quads.items[1].dst[0]);
}

test "transparent fills are skipped" {
    const gpa = std.testing.allocator;
    var ops: canvas.OpList = .{};
    defer ops.deinit(gpa);
    var mono: text.MonoText = .{};
    var pc: PaintCx = .{ .gpa = gpa, .ops = &ops, .theme = &theme_mod.zigguro_dark, .text_sys = mono.system(), .size = .{ .w = 10, .h = 10 } };
    pc.rect(pc.bounds(), Color.transparent, .{});
    try std.testing.expectEqual(@as(usize, 0), ops.ops.items.len);
}
