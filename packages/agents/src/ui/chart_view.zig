//! Chart views (E13.F07.S01.T03): a chart spec compiled and drawn
//! through a `VectorSurface`, with a hover tooltip for the mark nearest
//! the pointer (within 8 px). A spec that does not compile shows its
//! error message instead, so a model can read and fix it.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const vector_view = @import("vector_view.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const App = zg_gui.App;
const Ui = zg_gui.Ui;
const geom = zg_gui.core.geom;
const chart = zg_agents.chart;
const event_mod = zg_gui.input.event;

pub const ChartView = struct {
    gpa: Allocator,
    surface: *vector_view.VectorSurface,
    /// Holds the spec, the compiled chart and the error message.
    arena: std.heap.ArenaAllocator,
    compiled: ?chart.CompiledChart = null,
    /// Why the last spec did not compile.
    err: ?[]const u8 = null,
    /// The pointer in chart units, while over the chart.
    hover: ?[2]f32 = null,

    pub fn init(gpa: Allocator, io: Io, app: *App, o: vector_view.VectorSurface.Options) !*ChartView {
        const v = try gpa.create(ChartView);
        errdefer gpa.destroy(v);
        v.* = .{ .gpa = gpa, .surface = try .init(gpa, io, app, o), .arena = .init(gpa) };
        return v;
    }

    /// Call when no job is pending (`App.joinWork` first).
    pub fn deinit(v: *ChartView) void {
        v.surface.deinit();
        v.arena.deinit();
        v.gpa.destroy(v);
    }

    /// Reads, compiles and draws `json`. A spec or data error is kept
    /// for the view to show and returned.
    pub fn setSpec(v: *ChartView, json: []const u8, o: chart.Options) !void {
        _ = v.arena.reset(.retain_capacity);
        v.compiled = null;
        v.err = null;
        v.hover = null;
        const a = v.arena.allocator();
        var diag: chart.Diagnostic = .{};
        const s = chart.parseSpec(a, json, &diag) catch |e| return v.fail(e, diag.message);
        var cd: chart.compile_mod.Diagnostic = .{};
        const c = chart.compile(a, v.gpa, &s, o, &cd) catch |e| return v.fail(e, cd.message);
        v.compiled = c;
        const cv = try v.surface.begin();
        try chart.render(&v.compiled.?, cv);
        try v.surface.commit();
    }

    fn fail(v: *ChartView, e: anyerror, message: []const u8) anyerror {
        v.err = v.arena.allocator().dupe(u8, if (message.len > 0) message else @errorName(e)) catch @errorName(e);
        v.surface.app.notifyEntity(v.surface.entity);
        return e;
    }

    fn onHover(ctx: *anyopaque, at: ?[2]f32) void {
        const v: *ChartView = @ptrCast(@alignCast(ctx));
        if (std.meta.eql(v.hover, at)) return;
        v.hover = at;
        v.surface.app.notifyEntity(v.surface.entity);
    }

    /// The tooltip under the pointer, if any.
    pub fn tooltip(v: *const ChartView, a: Allocator) Allocator.Error!?chart.Tooltip {
        const c = &(v.compiled orelse return null);
        const at = v.hover orelse return null;
        return chart.hitTest(c, a, at);
    }
};

pub const Props = struct {
    zoom: f32 = 1,
    test_id: ?[]const u8 = null,
    label: []const u8 = "Chart",
};

/// Pointer tracking and the tooltip, laid over the chart.
const Overlay = struct {
    pub const name = "chart_overlay";
    pub const State = struct {};

    pub const Hover = struct { ctx: *anyopaque, f: *const fn (*anyopaque, ?[2]f32) void };

    /// A tooltip line as ranges of `chars`.
    pub const Line = struct { label_start: u32, label_len: u32, value_start: u32, value_len: u32 };

    pub const Props = struct {
        w: f32,
        h: f32,
        zoom: f32,
        hover: Hover,
        /// The tooltip's anchor in chart units (when `lines` is not empty).
        tip: [2]f32 = .{ 0, 0 },
        lines: []const Line = &.{},
        chars: []const u8 = "",
        /// Changes when the tooltip does.
        hash: u64 = 0,
    };

    const pad: f32 = 6;
    const gap: f32 = 8;

    pub fn style(p: *const Overlay.Props, _: *const zg_gui.theme.Theme) zg_gui.layout.style.Style {
        return .{ .position = .absolute, .inset = .{ .l = 0, .t = 0 }, .w = .{ .px = p.w }, .h = .{ .px = p.h }, .z = 1 };
    }

    pub fn measure(_: *zg_gui.layout.measure.MeasureCx, p: *const Overlay.Props, _: *State, _: ?f32) geom.Size {
        return .{ .w = p.w, .h = p.h };
    }

    pub fn paint(pc: *zg_gui.paint.PaintCx, p: *const Overlay.Props, _: *State) void {
        if (p.lines.len == 0) return;
        const box = pc.bounds();
        const st: zg_gui.paint.text.TextStyle = .{ .size = 12 };
        const bold: zg_gui.paint.text.TextStyle = .{ .size = 12, .weight = 700 };
        const lh = pc.text_sys.metrics(st).line_h;
        var label_w: f32 = 0;
        var value_w: f32 = 0;
        for (p.lines) |l| {
            label_w = @max(label_w, pc.text_sys.width(st, p.chars[l.label_start..][0..l.label_len]));
            value_w = @max(value_w, pc.text_sys.width(bold, p.chars[l.value_start..][0..l.value_len]));
        }
        const w = pad * 2 + label_w + gap + value_w;
        const h = pad * 2 + lh * @as(f32, @floatFromInt(p.lines.len));
        // Right of and above the anchor; flipped to stay inside the view.
        var x = box.x + p.tip[0] * p.zoom + gap;
        var y = box.y + p.tip[1] * p.zoom - h - gap;
        if (x + w > box.right()) x = box.x + p.tip[0] * p.zoom - gap - w;
        if (y < box.y) y = box.y + p.tip[1] * p.zoom + gap;
        x = @max(box.x, x);
        const r: geom.Rect = .{ .x = x, .y = y, .w = w, .h = h };
        pc.fill(r, .bg_overlay, 4);
        pc.border(r, 1, pc.color(.border), 4);
        for (p.lines, 0..) |l, i| {
            const ly = y + pad + lh * @as(f32, @floatFromInt(i));
            pc.textBox(p.chars[l.label_start..][0..l.label_len], st, pc.color(.fg_muted), .{ .x = x + pad, .y = ly, .w = label_w, .h = lh }, false, .start);
            pc.textBox(p.chars[l.value_start..][0..l.value_len], bold, pc.color(.fg), .{ .x = x + pad + label_w + gap, .y = ly, .w = value_w, .h = lh }, false, .start);
        }
    }

    pub fn event(ec: *event_mod.EventCx, p: *const Overlay.Props, _: *State, ev: *const event_mod.InputEvent) bool {
        switch (ev.*) {
            .pointer_move => |m| {
                const l = ec.local(m.pos);
                p.hover.f(p.hover.ctx, .{ l.x / p.zoom, l.y / p.zoom });
                return false;
            },
            .pointer_leave => p.hover.f(p.hover.ctx, null),
            else => {},
        }
        return false;
    }
};

/// Draws the chart (or its error) with the hover tooltip.
pub fn chartView(ui: *Ui, v: *ChartView, p: Props) void {
    ui.cx().observe(v.surface.entity);
    if (v.err) |msg| {
        ui.open(.{ .role = .status, .label = p.label, .test_id = p.test_id orelse "" });
        ui.text(msg, .{});
        ui.close();
        return;
    }
    const c = v.compiled orelse return;
    const w = c.width * p.zoom;
    const h = c.height * p.zoom;
    ui.open(.{ .label = p.label, .style = .{ .w = .{ .px = w }, .h = .{ .px = h } } });
    vector_view.vectorView(ui, v.surface, .{ .w = w, .h = h, .zoom = p.zoom, .test_id = p.test_id, .label = c.title orelse p.label });
    var props: Overlay.Props = .{ .w = w, .h = h, .zoom = p.zoom, .hover = .{ .ctx = v, .f = ChartView.onHover } };
    const a = ui.arena();
    if (v.tooltip(a) catch null) |tip| setTip(a, &props, tip) catch {};
    _ = ui.leaf(Overlay, props);
    ui.close();
}

/// Flattens a tooltip into the overlay's props.
fn setTip(a: Allocator, props: *Overlay.Props, tip: chart.Tooltip) Allocator.Error!void {
    var chars: std.ArrayListUnmanaged(u8) = .empty;
    const lines = try a.alloc(Overlay.Line, tip.lines.len);
    for (lines, tip.lines) |*l, t| {
        l.* = .{ .label_start = @intCast(chars.items.len), .label_len = @intCast(t.label.len), .value_start = @intCast(chars.items.len + t.label.len), .value_len = @intCast(t.value.len) };
        try chars.appendSlice(a, t.label);
        try chars.appendSlice(a, t.value);
    }
    props.tip = .{ tip.x, tip.y };
    props.lines = lines;
    props.chars = chars.items;
    props.hash = std.hash.Wyhash.hash(tip.row, chars.items);
}
