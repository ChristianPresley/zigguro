//! Drawing a compiled chart (E13.F07.S01.T03) on the vector canvas:
//! gridlines as device hairlines, axes, marks clipped near the plot,
//! the legend and the title. Text goes in as text runs, so it stays
//! crisp on screen and real text in SVG.

const std = @import("std");
const vector = @import("../vector/root.zig");
const compile = @import("compile.zig");
const scale = @import("scale.zig");

const CompiledChart = compile.CompiledChart;
const Canvas = vector.VectorCanvas;
const Color = vector.Color;

fn color(rgb: scale.Rgb, opacity: f32) Color {
    return Color.rgb(rgb).withAlpha(@intFromFloat(@round(std.math.clamp(opacity, 0, 1) * 255)));
}

pub fn render(c: *const CompiledChart, cv: *Canvas) !void {
    const st = c.style;
    const p = c.plot;
    const hair = 1 / @max(st.device_scale, 0.5);

    if (c.title) |t| try cv.text(.{ .x = c.width / 2, .y = st.padding + st.title_size, .text = t, .size = st.title_size, .color = Color.rgb(st.title), .anchor = .middle, .bold = true });

    // Gridlines under everything.
    if (c.y) |ax| if (ax.grid) for (ax.ticks) |tk| {
        try cv.line(p.x, snap(tk.pos, hair), p.right(), snap(tk.pos, hair), .{ .width = hair }, Color.rgb(st.grid));
    };
    if (c.x) |ax| if (ax.grid) for (ax.ticks) |tk| {
        try cv.line(snap(tk.pos, hair), p.y, snap(tk.pos, hair), p.bottom(), .{ .width = hair }, Color.rgb(st.grid));
    };

    // Marks, clipped a little outside the plot (points on the edge stay whole).
    try cv.pushClip(.xywh(p.x - 8, p.y - 8, p.w + 16, p.h + 16));
    for (c.items) |it| try item(cv, it, p.w);
    try cv.popClip();

    // Axes.
    const axis_col = Color.rgb(st.axis);
    const text_col = Color.rgb(st.text);
    if (c.x) |ax| {
        const y = snap(p.bottom(), hair);
        try cv.line(p.x, y, p.right(), y, .{ .width = hair }, axis_col);
        for (ax.ticks) |tk| {
            try cv.line(snap(tk.pos, hair), y, snap(tk.pos, hair), y + st.tick_size, .{ .width = hair }, axis_col);
            if (ax.labels and tk.show) try cv.text(.{ .x = tk.pos, .y = y + st.tick_size + st.label_gap, .text = tk.label, .size = st.font_size, .color = text_col, .anchor = .middle, .baseline = .top });
        }
        if (ax.title) |t| if (t.len > 0) try cv.text(.{ .x = p.x + p.w / 2, .y = c.height - st.padding, .text = t, .size = st.axis_title_size, .color = Color.rgb(st.title), .anchor = .middle, .baseline = .bottom, .bold = true });
    }
    if (c.y) |ax| {
        const x = snap(p.x, hair);
        try cv.line(x, p.y, x, p.bottom(), .{ .width = hair }, axis_col);
        for (ax.ticks) |tk| {
            try cv.line(x - st.tick_size, snap(tk.pos, hair), x, snap(tk.pos, hair), .{ .width = hair }, axis_col);
            if (ax.labels and tk.show) try cv.text(.{ .x = x - st.tick_size - st.label_gap, .y = tk.pos, .text = tk.label, .size = st.font_size, .color = text_col, .anchor = .end, .baseline = .middle });
        }
        if (ax.title) |t| if (t.len > 0) try cv.text(.{ .x = st.padding + st.axis_title_size / 2, .y = p.y + p.h / 2, .text = t, .size = st.axis_title_size, .color = Color.rgb(st.title), .anchor = .middle, .baseline = .middle, .rotate = .ccw90, .bold = true });
    }

    if (c.legend) |lg| try legend(cv, c, lg);
    if (c.sampled) try cv.text(.{ .x = p.right() - 4, .y = p.y + 4, .text = "sampled", .size = st.font_size - 1, .color = axis_col, .anchor = .end, .baseline = .top });
}

/// A hairline position on the device pixel grid (so it is one sharp
/// pixel, not two half ones).
fn snap(v: f32, hair: f32) f32 {
    const px = v / hair;
    return (@floor(px) + 0.5) * hair;
}

fn item(cv: *Canvas, it: compile.Item, plot_w: f32) !void {
    const col = color(it.color, it.opacity);
    switch (it.geom) {
        .rect => |b| if (b.w > 0 and b.h > 0) try cv.fillRect(.xywh(b.x, b.y, b.w, b.h), col),
        .line => |l| {
            if (@as(f32, @floatFromInt(l.points.len)) > 2 * plot_w) return denseLine(cv, l.points, l.width, col);
            const path = try cv.path();
            var pen = false;
            for (l.points) |pt| {
                if (std.math.isNan(pt[1])) {
                    pen = false;
                    continue;
                }
                if (pen) try path.lineTo(cv.arena, pt[0], pt[1]) else try path.moveTo(cv.arena, pt[0], pt[1]);
                pen = true;
            }
            try cv.stroke(path, .{ .width = l.width, .join = .round, .cap = .round }, col);
        },
        .area => |ar| {
            if (ar.top.len < 2) return;
            const path = try cv.path();
            try path.moveTo(cv.arena, ar.top[0][0], ar.top[0][1]);
            for (ar.top[1..]) |pt| try path.lineTo(cv.arena, pt[0], pt[1]);
            var i = ar.base.len;
            while (i > 0) {
                i -= 1;
                try path.lineTo(cv.arena, ar.base[i][0], ar.base[i][1]);
            }
            try path.close(cv.arena);
            try cv.fill(path, col);
        },
        .point => |pt| {
            const path = try cv.path();
            const r = @sqrt(pt.size / std.math.pi);
            const s = @sqrt(pt.size);
            switch (pt.shape) {
                .circle => try path.circle(cv.arena, pt.x, pt.y, r),
                .square => try path.rect(cv.arena, pt.x - s / 2, pt.y - s / 2, s, s),
                .diamond => try poly(cv, path, &.{ .{ pt.x, pt.y - s * 0.7 }, .{ pt.x + s * 0.7, pt.y }, .{ pt.x, pt.y + s * 0.7 }, .{ pt.x - s * 0.7, pt.y } }),
                .triangle_up => try poly(cv, path, &.{ .{ pt.x, pt.y - s * 0.66 }, .{ pt.x + s * 0.66, pt.y + s * 0.5 }, .{ pt.x - s * 0.66, pt.y + s * 0.5 } }),
                .triangle_down => try poly(cv, path, &.{ .{ pt.x - s * 0.66, pt.y - s * 0.5 }, .{ pt.x + s * 0.66, pt.y - s * 0.5 }, .{ pt.x, pt.y + s * 0.66 } }),
                .cross => {
                    const a = s * 0.6;
                    const b = s * 0.2;
                    try poly(cv, path, &.{ .{ pt.x - b, pt.y - a }, .{ pt.x + b, pt.y - a }, .{ pt.x + b, pt.y - b }, .{ pt.x + a, pt.y - b }, .{ pt.x + a, pt.y + b }, .{ pt.x + b, pt.y + b }, .{ pt.x + b, pt.y + a }, .{ pt.x - b, pt.y + a }, .{ pt.x - b, pt.y + b }, .{ pt.x - a, pt.y + b }, .{ pt.x - a, pt.y - b }, .{ pt.x - b, pt.y - b } });
                },
            }
            if (pt.filled) try cv.fill(path, col) else try cv.stroke(path, .{ .width = 1.5 }, col);
        },
        .rule => |ru| try cv.line(ru.x0, ru.y0, ru.x1, ru.y1, .{ .width = ru.width }, col),
        .text => |t| try cv.text(.{ .x = t.x, .y = t.y, .text = t.text, .size = t.size, .color = col, .anchor = .middle, .baseline = .middle }),
    }
}

fn poly(cv: *Canvas, path: *vector.Path, pts: []const [2]f32) !void {
    try path.moveTo(cv.arena, pts[0][0], pts[0][1]);
    for (pts[1..]) |q| try path.lineTo(cv.arena, q[0], q[1]);
    try path.close(cv.arena);
}

fn legend(cv: *Canvas, c: *const CompiledChart, lg: compile.Legend) !void {
    const st = c.style;
    const b = lg.box;
    try cv.text(.{ .x = b.x, .y = b.y + st.font_size, .text = lg.title, .size = st.font_size, .color = Color.rgb(st.title), .bold = true });
    const top = b.y + st.font_size + 6;
    if (lg.gradient) |g| {
        const steps = 16;
        const w = b.w / steps;
        for (0..steps) |i| {
            const t = @as(f64, @floatFromInt(i)) / (steps - 1);
            try cv.fillRect(.xywh(b.x + @as(f32, @floatFromInt(i)) * w, top, w + 0.5, 12), Color.rgb(scale.lerp(g.ramp[0], g.ramp[1], t)));
        }
        try cv.text(.{ .x = b.x, .y = top + 14, .text = g.lo, .size = st.font_size, .color = Color.rgb(st.text), .baseline = .top });
        try cv.text(.{ .x = b.right(), .y = top + 14, .text = g.hi, .size = st.font_size, .color = Color.rgb(st.text), .anchor = .end, .baseline = .top });
        return;
    }
    for (lg.entries, 0..) |e, i| {
        const col_i: f32 = @floatFromInt(i / lg.rows_per_column);
        const row_i: f32 = @floatFromInt(i % lg.rows_per_column);
        const x = b.x + col_i * lg.column_w;
        const cy = top + row_i * st.legend_row + st.legend_row / 2;
        const sw = st.swatch;
        const path = try cv.path();
        if (e.shape == .circle) try path.circle(cv.arena, x + sw / 2, cy, sw / 2) else try path.rect(cv.arena, x, cy - sw / 2, sw, sw);
        try cv.fill(path, Color.rgb(e.color));
        try cv.text(.{ .x = x + sw + 6, .y = cy, .text = e.label, .size = st.font_size, .color = Color.rgb(st.text), .baseline = .middle });
    }
}

test {
    std.testing.refAllDecls(@This());
}

/// A decimated line (several points per pixel column) drawn as the band
/// each column's points span, widened like the stroke would be (by half
/// its width, also across neighbouring columns): the pixels its stroke
/// covers, as one polygon of short edges instead of thousands of tall
/// stroke segments. NaN ys break the band.
pub fn denseLine(cv: *Canvas, points: []const [2]f32, width: f32, col: Color) !void {
    const a = cv.arena;
    const hw = width / 2;
    const path = try cv.path();
    var cols: std.ArrayListUnmanaged(Column) = .empty;
    for (points) |pt| {
        if (std.math.isNan(pt[1])) {
            try band(a, path, cols.items, hw);
            cols.clearRetainingCapacity();
            continue;
        }
        const x = @floor(pt[0]);
        if (cols.items.len > 0 and cols.items[cols.items.len - 1].x == x) {
            const c = &cols.items[cols.items.len - 1];
            c.lo = @min(c.lo, pt[1]);
            c.hi = @max(c.hi, pt[1]);
        } else try cols.append(a, .{ .x = x, .lo = pt[1], .hi = pt[1] });
    }
    try band(a, path, cols.items, hw);
    try cv.fill(path, col);
}

const Column = struct { x: f32, lo: f32, hi: f32 };

/// One closed band over `cols`: along the tops, back along the bottoms.
fn band(a: std.mem.Allocator, path: *vector.Path, cols: []const Column, hw: f32) !void {
    if (cols.len == 0) return;
    const reach: usize = @intFromFloat(@ceil(hw));
    const tops = try a.alloc([2]f32, cols.len);
    const bots = try a.alloc([2]f32, cols.len);
    for (cols, 0..) |c, i| {
        var lo = c.lo;
        var hi = c.hi;
        // Columns within the pen's reach widen this one.
        for (cols[i -| reach..@min(cols.len, i + reach + 1)]) |n| if (@abs(n.x - c.x) <= hw) {
            lo = @min(lo, n.lo);
            hi = @max(hi, n.hi);
        };
        tops[i] = .{ c.x + 0.5, lo - hw };
        bots[i] = .{ c.x + 0.5, hi + hw };
    }
    // The ends reach out like round caps.
    try path.moveTo(a, tops[0][0] - hw, tops[0][1]);
    for (tops) |t| try path.lineTo(a, t[0], t[1]);
    try path.lineTo(a, tops[tops.len - 1][0] + hw, tops[tops.len - 1][1]);
    try path.lineTo(a, bots[bots.len - 1][0] + hw, bots[bots.len - 1][1]);
    var i = bots.len;
    while (i > 0) {
        i -= 1;
        try path.lineTo(a, bots[i][0], bots[i][1]);
    }
    try path.lineTo(a, bots[0][0] - hw, bots[0][1]);
    try path.close(a);
}
