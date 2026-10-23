//! Drawing a laid-out flowchart (E13.F07.S02.T03) on the vector canvas:
//! cluster boxes and titles, edges with their ends, edge labels on the
//! canvas colour, then nodes on top. Colours come from the theme,
//! overridden by `classDef`/`class`/`:::`/`style` (nodes, subgraphs)
//! and `linkStyle` (edges). Labels are wrapped with the same `Measure`
//! the layout used, so the text fits the boxes it was sized for.

const std = @import("std");
const zg_diagram = @import("zg_diagram");
const vector = @import("../vector/root.zig");
const theme_mod = @import("theme.zig");
const shapes = @import("shapes.zig");

const Allocator = std.mem.Allocator;
const Canvas = vector.VectorCanvas;
const Color = vector.Color;
const Path = vector.Path;
const StrokeStyle = vector.StrokeStyle;
const Diagram = zg_diagram.Diagram;
const Layout = zg_diagram.Layout;
const Measure = zg_diagram.Measure;
const Style = zg_diagram.Style;
const DiagramTheme = theme_mod.DiagramTheme;

pub const Opts = struct {
    /// Labels wrap at this width (the layout's `max_label_w`).
    max_label_w: f32 = (zg_diagram.LayoutOpts{}).max_label_w,
};

pub const node_stroke_w: f32 = 1;
pub const edge_w: f32 = 1.5;
pub const thick_w: f32 = 3.5;
pub const dotted_dash = [_]f32{ 3, 3 };
/// Arrowheads: a filled triangle this long and wide at the end tangent.
pub const arrow_len: f32 = 8;
pub const arrow_w: f32 = 6;
pub const circle_r: f32 = 4;
pub const cross_len: f32 = 6;

/// The diagram as a display list (everything in `arena`).
pub fn toDisplayList(arena: Allocator, d: *const Diagram, l: *const Layout, theme: DiagramTheme, m: Measure) !vector.DisplayList {
    var cv: Canvas = .init(arena);
    try render(&cv, d, l, theme, m, .{});
    return cv.finish();
}

/// Draws `l` into `cv`.
pub fn render(cv: *Canvas, d: *const Diagram, l: *const Layout, theme: DiagramTheme, m: Measure, o: Opts) !void {
    const a = cv.arena;
    const lh = lineHeight(m);

    // Outer subgraphs first so nested ones draw over them.
    const order = try a.alloc(u32, l.clusters.len);
    for (order, 0..) |*x, i| x.* = @intCast(i);
    const depth = try a.alloc(u32, l.clusters.len);
    @memset(depth, 0);
    for (d.subgraphs) |s| for (s.children) |c| {
        depth[c] += 1;
    };
    // Children may be listed before parents: propagate until stable.
    var changed = true;
    while (changed) {
        changed = false;
        for (d.subgraphs, 0..) |s, i| for (s.children) |c| {
            if (depth[c] < depth[i] + 1) {
                depth[c] = depth[i] + 1;
                changed = true;
            }
        };
    }
    std.sort.pdq(u32, order, depth, struct {
        fn lt(dp: []const u32, x: u32, y: u32) bool {
            return if (dp[x] != dp[y]) dp[x] < dp[y] else x < y;
        }
    }.lt);
    for (order) |ci| {
        const cb = l.clusters[ci];
        const s = d.subgraphs[ci];
        const st = classStyle(d, s.classes).merge(s.style);
        const p = try cv.path();
        try p.rect(a, cb.x, cb.y, cb.w, cb.h);
        try cv.fill(p, colorOr(st.fill, theme.cluster_fill));
        try cv.stroke(p, strokeOf(st, node_stroke_w), colorOr(st.stroke, theme.cluster_stroke));
        if (s.title.len > 0 and cb.title_h > 0) {
            try label(cv, m, s.title, .{ cb.x + cb.w / 2, cb.y + cb.title_h / 2 }, lh, o, colorOr(st.color, theme.text), theme.font);
        }
    }

    // Edges, then their labels over any edge they cross.
    var default_link: Style = .{};
    for (d.link_styles) |ls| if (ls.index == null) {
        default_link = default_link.merge(ls.style);
    };
    for (l.edges) |ep| {
        const e = d.edges[ep.edge];
        if (e.style == .invisible) continue;
        var st = default_link;
        for (d.link_styles) |ls| if (ls.index == ep.edge) {
            st = st.merge(ls.style);
        };
        try edge(cv, e, ep.points, st, theme);
    }
    for (l.edges) |ep| {
        const e = d.edges[ep.edge];
        if (e.style == .invisible) continue;
        const box = ep.label orelse continue;
        const text = e.label orelse continue;
        try cv.fillRect(.xywh(box.x - box.w / 2, box.y - box.h / 2, box.w, box.h), theme.background);
        try label(cv, m, text, .{ box.x, box.y }, lh, o, theme.text, theme.font);
    }

    // Nodes on top.
    for (l.nodes) |box| {
        const n = d.nodes[box.node];
        const st = classStyle(d, n.classes).merge(n.style);
        const p = try cv.path();
        try shapes.outline(a, p, n.shape, box);
        try cv.fill(p, colorOr(st.fill, theme.node_fill));
        const sstyle = strokeOf(st, node_stroke_w);
        const scol = colorOr(st.stroke, theme.node_stroke);
        try cv.stroke(p, sstyle, scol);
        const inner = try cv.path();
        try shapes.innerLines(a, inner, n.shape, box);
        try cv.stroke(inner, sstyle, scol);
        // A cylinder's text sits below its lid.
        const dy: f32 = if (n.shape == .cylinder) shapes.cylinder_ry else 0;
        try label(cv, m, n.label, .{ box.x, box.y + dy }, lh, o, colorOr(st.color, theme.text), theme.font);
    }
}

/// The style from `classDef default` and the named classes, in order.
fn classStyle(d: *const Diagram, classes: []const []const u8) Style {
    var st: Style = .{};
    for (d.class_defs) |cd| if (std.mem.eql(u8, cd.name, "default")) {
        st = st.merge(cd.style);
    };
    for (classes) |name| for (d.class_defs) |cd| if (std.mem.eql(u8, cd.name, name)) {
        st = st.merge(cd.style);
    };
    return st;
}

fn colorOr(v: ?u32, dflt: Color) Color {
    return if (v) |c| theme_mod.fromArgb(c) else dflt;
}

fn strokeOf(st: Style, width: f32) StrokeStyle {
    return .{ .width = st.stroke_width orelse width, .dash = st.stroke_dasharray orelse &.{}, .join = .round };
}

fn edge(cv: *Canvas, e: zg_diagram.Edge, points: []const [2]f32, st: Style, theme: DiagramTheme) !void {
    if (points.len < 4) return;
    const a = cv.arena;
    const col = colorOr(st.stroke, theme.edge);
    const base_w: f32 = if (e.style == .thick) thick_w else edge_w;
    const dash: []const f32 = st.stroke_dasharray orelse if (e.style == .dotted) &dotted_dash else &.{};
    const style: StrokeStyle = .{ .width = st.stroke_width orelse base_w, .dash = dash, .join = .round, .cap = .butt };

    const pts = try a.dupe([2]f32, points);
    const n = pts.len;
    // Tangents at both ends, pointing out of the curve.
    const head_dir = endDir(pts[n - 1], pts[n - 2], pts[0]);
    const tail_dir = endDir(pts[0], pts[1], pts[n - 1]);
    const head_tip = pts[n - 1];
    const tail_tip = pts[0];
    // Pull the line back so it does not poke through the end mark.
    shorten(pts[n - 2 ..], head_dir, endInset(e.head));
    shorten(pts[0..2], tail_dir, endInset(e.tail));

    const p = try cv.path();
    try p.moveTo(a, pts[0][0], pts[0][1]);
    var i: usize = 1;
    while (i + 2 < n) : (i += 3) try p.cubicTo(a, pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1], pts[i + 2][0], pts[i + 2][1]);
    try cv.stroke(p, style, col);
    try endMark(cv, e.head, head_tip, head_dir, col, style.width);
    try endMark(cv, e.tail, tail_tip, tail_dir, col, style.width);
}

/// The unit direction from `inner` to `tip` (from `far` when they
/// coincide).
fn endDir(tip: [2]f32, inner: [2]f32, far: [2]f32) [2]f32 {
    var dx = tip[0] - inner[0];
    var dy = tip[1] - inner[1];
    if (dx * dx + dy * dy < 1e-6) {
        dx = tip[0] - far[0];
        dy = tip[1] - far[1];
    }
    const len = @sqrt(dx * dx + dy * dy);
    return if (len < 1e-6) .{ 0, 1 } else .{ dx / len, dy / len };
}

fn endInset(kind: zg_diagram.EdgeEnd) f32 {
    return switch (kind) {
        .arrow => arrow_len - 1,
        .circle => 2 * circle_r,
        .cross, .none => 0,
    };
}

/// Moves an end of a curve and its control point back by `by` against
/// `dir`.
fn shorten(end2: [][2]f32, dir: [2]f32, by: f32) void {
    for (end2) |*pt| {
        pt[0] -= dir[0] * by;
        pt[1] -= dir[1] * by;
    }
}

fn endMark(cv: *Canvas, kind: zg_diagram.EdgeEnd, tip: [2]f32, dir: [2]f32, col: Color, w: f32) !void {
    const a = cv.arena;
    const nx = -dir[1];
    const ny = dir[0];
    switch (kind) {
        .none => {},
        .arrow => {
            const bx = tip[0] - dir[0] * arrow_len;
            const by = tip[1] - dir[1] * arrow_len;
            const hw = arrow_w / 2;
            const p = try cv.path();
            try p.moveTo(a, tip[0], tip[1]);
            try p.lineTo(a, bx + nx * hw, by + ny * hw);
            try p.lineTo(a, bx - nx * hw, by - ny * hw);
            try p.close(a);
            try cv.fill(p, col);
        },
        .circle => try cv.circle(tip[0] - dir[0] * circle_r, tip[1] - dir[1] * circle_r, circle_r, col),
        .cross => {
            const cx = tip[0] - dir[0] * cross_len / 2;
            const cy = tip[1] - dir[1] * cross_len / 2;
            const h = cross_len / 2 / std.math.sqrt2;
            // Two strokes at ±45° to the edge.
            const ux = (dir[0] + nx) * h;
            const uy = (dir[1] + ny) * h;
            const vx = (dir[0] - nx) * h;
            const vy = (dir[1] - ny) * h;
            const p = try cv.path();
            try p.moveTo(a, cx - ux, cy - uy);
            try p.lineTo(a, cx + ux, cy + uy);
            try p.moveTo(a, cx - vx, cy - vy);
            try p.lineTo(a, cx + vx, cy + vy);
            try cv.stroke(p, .{ .width = @max(w, 1.5) }, col);
        },
    }
}

/// The height of one line of label text.
pub fn lineHeight(m: Measure) f32 {
    return m.text(m.ctx, "Mg", std.math.floatMax(f32))[1];
}

/// `text`'s lines centred on `c`.
fn label(cv: *Canvas, m: Measure, text: []const u8, c: [2]f32, lh: f32, o: Opts, col: Color, font: DiagramTheme.Font) !void {
    var n: usize = 0;
    var it: LineIter = .{ .text = text, .max_w = o.max_label_w, .m = m };
    while (it.next()) |_| n += 1;
    it = .{ .text = text, .max_w = o.max_label_w, .m = m };
    var y = c[1] - lh * @as(f32, @floatFromInt(n)) / 2 + lh / 2;
    while (it.next()) |line| : (y += lh) {
        if (line.len == 0) continue;
        try cv.text(.{ .x = c[0], .y = y, .text = line, .size = font.size, .color = col, .anchor = .middle, .baseline = .middle, .family = font.family });
    }
}

/// Greedy word wrap: a label's lines at `max_w`, breaking at newlines
/// and spaces (a word wider than `max_w` gets a line of its own).
pub const LineIter = struct {
    text: []const u8,
    max_w: f32,
    m: Measure,
    pos: usize = 0,
    done: bool = false,

    pub fn next(it: *LineIter) ?[]const u8 {
        return nextLine(it.text, &it.pos, &it.done, it.max_w, &it.m, struct {
            fn w(ctx: *anyopaque, s: []const u8) f32 {
                const mm: *const Measure = @ptrCast(@alignCast(ctx));
                return mm.text(mm.ctx, s, std.math.floatMax(f32))[0];
            }
        }.w);
    }
};

/// The next line of `text` from `pos.*` (shared by `LineIter` and the
/// estimate measure). `width` measures one unwrapped line.
pub fn nextLine(text: []const u8, pos: *usize, done: *bool, max_w: f32, ctx: *anyopaque, width: *const fn (*anyopaque, []const u8) f32) ?[]const u8 {
    if (done.*) return null;
    const start = pos.*;
    const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    var end = start;
    var scan = start;
    while (scan < nl) {
        // The next word's end.
        var we = scan;
        while (we < nl and text[we] == ' ') we += 1;
        while (we < nl and text[we] != ' ') we += 1;
        if (end > start and width(ctx, text[start..we]) > max_w) break;
        end = we;
        scan = we;
    }
    if (end == start and start < nl) end = nl;
    const line = std.mem.trim(u8, text[start..end], " ");
    if (end >= nl) {
        if (nl >= text.len) done.* = true;
        pos.* = nl + 1;
    } else {
        var p = end;
        while (p < nl and text[p] == ' ') p += 1;
        pos.* = p;
    }
    return line;
}

/// A measure without a text system: glyphs `0.6 × size` wide, lines
/// `1.25 × size` tall (headless SVG export and tests).
pub const Estimate = struct {
    size: f32 = 14,

    pub fn measure(e: *Estimate) Measure {
        return .{ .ctx = e, .text = text };
    }

    fn width(ctx: *anyopaque, s: []const u8) f32 {
        const e: *Estimate = @ptrCast(@alignCast(ctx));
        const n = std.unicode.utf8CountCodepoints(s) catch s.len;
        return @as(f32, @floatFromInt(n)) * e.size * 0.6;
    }

    fn text(ctx: *anyopaque, s: []const u8, max_w: f32) [2]f32 {
        const e: *Estimate = @ptrCast(@alignCast(ctx));
        var pos: usize = 0;
        var done = false;
        var w: f32 = 0;
        var n: f32 = 0;
        while (nextLine(s, &pos, &done, max_w, ctx, width)) |line| {
            w = @max(w, width(ctx, line));
            n += 1;
        }
        return .{ w, @max(1, n) * e.size * 1.25 };
    }
};

test "lines wrap at words and newlines" {
    var e: Estimate = .{ .size = 10 };
    const m = e.measure();
    var it: LineIter = .{ .text = "one two three\nfour", .max_w = 50, .m = m };
    try std.testing.expectEqualStrings("one two", it.next().?);
    try std.testing.expectEqualStrings("three", it.next().?);
    try std.testing.expectEqualStrings("four", it.next().?);
    try std.testing.expectEqual(null, it.next());
    it = .{ .text = "averyveryverylongword x", .max_w = 30, .m = m };
    try std.testing.expectEqualStrings("averyveryverylongword", it.next().?);
    try std.testing.expectEqualStrings("x", it.next().?);
    try std.testing.expectEqual(null, it.next());
    try std.testing.expectEqual([2]f32{ 42, 25 }, m.text(m.ctx, "one two three", 50));
    try std.testing.expectEqual([2]f32{ 0, 12.5 }, m.text(m.ctx, "", 50));
}
