//! Diagram building and SVG export (E13.F07.S02.T03): Mermaid source to
//! a display list (parse, lay out, draw), or a reason it can't be drawn
//! (another diagram type, or parse errors with line and column), and
//! the same list written as a standalone SVG document. The view and the
//! export share `build`, so on-screen and exported geometry match.

const std = @import("std");
const zg_diagram = @import("zg_diagram");
const vector = @import("../vector/root.zig");
const render_mod = @import("render.zig");
const theme_mod = @import("theme.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Measure = zg_diagram.Measure;
const DiagramTheme = theme_mod.DiagramTheme;

pub const Built = union(enum) {
    ok: struct {
        diagram: zg_diagram.Diagram,
        layout: zg_diagram.Layout,
        list: vector.DisplayList,
    },
    /// A Mermaid diagram type other than flowchart (or no known type).
    unsupported,
    /// Parse errors, first one first.
    errors: []const zg_diagram.Diagnostic,
};

/// A parsed and laid-out diagram, or why there is none.
pub const Prepared = union(enum) {
    ok: struct { diagram: zg_diagram.Diagram, layout: zg_diagram.Layout },
    unsupported,
    errors: []const zg_diagram.Diagnostic,
};

/// Parses and lays out `src` (the slow part; runs on a worker in the
/// view, with a thread-safe `m`).
pub fn prepare(arena: Allocator, src: []const u8, m: Measure) !Prepared {
    if (zg_diagram.detectType(src) != .flowchart) return .unsupported;
    var diags: std.ArrayList(zg_diagram.Diagnostic) = .empty;
    const parsed = try zg_diagram.parse(arena, src, &diags);
    var errs: std.ArrayList(zg_diagram.Diagnostic) = .empty;
    for (diags.items) |dg| if (dg.severity == .err) try errs.append(arena, dg);
    const d = parsed orelse {
        if (errs.items.len == 0) return .unsupported;
        return .{ .errors = errs.items };
    };
    if (errs.items.len > 0) return .{ .errors = errs.items };
    var l = try zg_diagram.layout(arena, &d, m, .{});
    // A front-matter title gets a band of its own above the diagram.
    if (titleBand(&d, m)) |band| l = try shifted(arena, &l, band);
    return .{ .ok = .{ .diagram = d, .layout = l } };
}

fn titleBand(d: *const zg_diagram.Diagram, m: Measure) ?f32 {
    const t = d.title orelse return null;
    if (t.len == 0) return null;
    return render_mod.lineHeight(m) * 1.4 + 8;
}

/// Draws a prepared diagram (and its title) into `cv`.
pub fn draw(cv: *vector.VectorCanvas, d: *const zg_diagram.Diagram, l: *const zg_diagram.Layout, theme: DiagramTheme, m: Measure) !void {
    if (titleBand(d, m)) |band| {
        try cv.text(.{ .x = l.size[0] / 2, .y = band / 2 + 4, .text = d.title.?, .size = theme.font.size * 1.15, .color = theme.text, .anchor = .middle, .baseline = .middle, .bold = true, .family = theme.font.family });
    }
    try render_mod.render(cv, d, l, theme, m, .{});
}

/// Parses, lays out and draws `src` (all memory from `arena`).
pub fn build(arena: Allocator, src: []const u8, theme: DiagramTheme, m: Measure) !Built {
    const p = try prepare(arena, src, m);
    const ok = switch (p) {
        .ok => |v| v,
        .unsupported => return .unsupported,
        .errors => |e| return .{ .errors = e },
    };
    var cv: vector.VectorCanvas = .init(arena);
    try draw(&cv, &ok.diagram, &ok.layout, theme, m);
    return .{ .ok = .{ .diagram = ok.diagram, .layout = ok.layout, .list = try cv.finish() } };
}

/// `l` moved down by `dy`, its size grown to match.
fn shifted(arena: Allocator, l: *const zg_diagram.Layout, dy: f32) !zg_diagram.Layout {
    const nodes = try arena.dupe(zg_diagram.NodeBox, l.nodes);
    for (nodes) |*n| n.y += dy;
    const clusters = try arena.dupe(zg_diagram.ClusterBox, l.clusters);
    for (clusters) |*c| c.y += dy;
    const edges = try arena.dupe(zg_diagram.EdgePath, l.edges);
    for (edges) |*e| {
        const pts = try arena.dupe([2]f32, e.points);
        for (pts) |*p| p[1] += dy;
        e.points = pts;
        if (e.label) |*lb| lb.y += dy;
    }
    return .{ .nodes = nodes, .edges = edges, .clusters = clusters, .size = .{ l.size[0], l.size[1] + dy } };
}

/// Writes `src` as an SVG document; false (nothing written) when it is
/// not a flowchart or does not parse.
pub fn writeDiagramSvg(w: *Writer, src: []const u8, theme: DiagramTheme, m: Measure) !bool {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const b = try build(arena.allocator(), src, theme, m);
    const ok = switch (b) {
        .ok => |v| v,
        else => return false,
    };
    try writeSvg(w, &ok.list, ok.layout.size, theme);
    return true;
}

/// A built diagram's list as SVG, sized to the layout.
pub fn writeSvg(w: *Writer, dl: *const vector.DisplayList, size: [2]f32, theme: DiagramTheme) Writer.Error!void {
    try vector.writeSvg(w, dl, .{
        .view = .xywh(0, 0, size[0], size[1]),
        .font_family = theme.font.family orelse "sans-serif",
        .background = theme.background,
    });
}
