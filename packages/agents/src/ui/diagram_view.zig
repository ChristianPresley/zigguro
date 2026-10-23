//! Diagram views (E13.F07.S02.T03): Mermaid source drawn as a diagram
//! with pan and zoom, and the `mermaid` fence renderer for Markdown
//! views (notes, chat, documents, artifacts).
//!
//! Parsing and layout run on a worker; until they finish a placeholder
//! sized from the source holds the space. The first frame after the
//! worker posts back records the display list (cheap) and shows it
//! through a `VectorSurface`. Source that is not a flowchart, or does
//! not parse, is shown as code with a `line:col message` line, never
//! hidden. Fences are cached by the BLAKE3 of their source and theme,
//! so a rebuilt view reuses its diagram.
//!
//! Pan: drag, the wheel, or the arrow keys. Zoom: the toolbar, `+`/`-`
//! and `0` to reset.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const vector_view = @import("vector_view.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const App = zg_gui.App;
const Ui = zg_gui.Ui;
const geom = zg_gui.core.geom;
const event_mod = zg_gui.input.event;
const dr = zg_agents.diagram_render;
const vector = zg_agents.vector;
const DiagramTheme = dr.DiagramTheme;
const Measure = @import("zg_diagram").Measure;

/// Diagram colours from the app theme: nodes tinted with the accent,
/// clusters a 6% accent wash.
pub fn themeFromTokens(th: *const zg_gui.theme.Theme) DiagramTheme {
    const c = struct {
        fn of(x: geom.Color) vector.Color {
            return .{ .r = x.r, .g = x.g, .b = x.b, .a = x.a };
        }
    }.of;
    const accent = th.color(.accent);
    const base = th.color(.bg_base);
    return .{
        .node_fill = c(geom.Color.lerp(th.color(.bg_elevated), accent, 0.12)),
        .node_stroke = c(accent),
        .edge = c(th.color(.fg_muted)),
        .text = c(th.color(.fg)),
        .cluster_fill = c(accent.fade(0.06)),
        .cluster_stroke = c(th.color(.border_strong)),
        .background = c(base),
        .font = .{ .size = th.dim(.font_size) },
    };
}

/// Called with the view whose toolbar button was pressed.
pub const Action = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, st: *DiagramViewState) void,
};

pub const DiagramViewState = struct {
    gpa: Allocator,
    app: *App,
    surface: *vector_view.VectorSurface,
    theme: DiagramTheme,
    /// Label sizes for layout on the worker; must be thread-safe.
    measure: Measure,
    estimate: dr.Estimate,
    src: []u8 = &.{},
    key: [32]u8 = @splat(0),
    status: Status = .empty,
    /// The `line:col message` (or unsupported-type) line.
    notice: []u8 = &.{},
    /// The diagram's size (an estimate until it is ready).
    size: [2]f32 = .{ 0, 0 },
    zoom: f32 = 1,
    pan: [2]f32 = .{ 0, 0 },
    /// Bumped by `setSource`; results of older jobs are dropped.
    gen: u32 = 0,
    /// Parses and layouts finished (tests).
    builds: u32 = 0,
    /// The parsed diagram and layout, for redraws and SVG export.
    result: ?*Result = null,
    on_open_artifact: ?Action = null,
    on_export_svg: ?Action = null,

    pub const Status = enum { empty, pending, ready, unsupported, failed };

    pub const Options = struct {
        surface: vector_view.VectorSurface.Options = .{},
        theme: DiagramTheme = .light,
        /// Null: a glyph-width estimate (see `dr.Estimate`).
        measure: ?Measure = null,
    };

    const Result = struct {
        arena: std.heap.ArenaAllocator,
        diagram: @import("zg_diagram").Diagram,
        layout: @import("zg_diagram").Layout,
    };

    pub fn init(gpa: Allocator, io: Io, app: *App, o: Options) !*DiagramViewState {
        const st = try gpa.create(DiagramViewState);
        errdefer gpa.destroy(st);
        st.* = .{ .gpa = gpa, .app = app, .surface = try .init(gpa, io, app, o.surface), .theme = o.theme, .measure = undefined, .estimate = .{ .size = o.theme.font.size } };
        st.measure = o.measure orelse st.estimate.measure();
        return st;
    }

    /// Call when no job is pending (`App.joinWork`, then drain the
    /// app's messages).
    pub fn deinit(st: *DiagramViewState) void {
        st.dropResult();
        st.gpa.free(st.src);
        st.gpa.free(st.notice);
        st.surface.deinit();
        st.gpa.destroy(st);
    }

    fn dropResult(st: *DiagramViewState) void {
        if (st.result) |r| {
            r.arena.deinit();
            st.gpa.destroy(r);
            st.result = null;
        }
    }

    /// The cache key of `src` drawn with `theme`.
    pub fn keyOf(src: []const u8, theme: DiagramTheme) [32]u8 {
        var h: std.crypto.hash.Blake3 = .init(.{});
        h.update(src);
        h.update(std.mem.asBytes(&theme.hash()));
        var out: [32]u8 = undefined;
        h.final(&out);
        return out;
    }

    /// Shows `src`: parses and lays it out on a worker (nothing happens
    /// when it is what is shown or pending already).
    pub fn setSource(st: *DiagramViewState, src: []const u8) !void {
        const key = keyOf(src, st.theme);
        if (st.status != .empty and std.mem.eql(u8, &key, &st.key)) return;
        const copy = try st.gpa.dupe(u8, src);
        st.gpa.free(st.src);
        st.src = copy;
        st.key = key;
        st.gen +%= 1;
        st.status = .pending;
        st.size = estimateSize(src);
        st.pan = .{ 0, 0 };
        const job = try st.gpa.create(Job);
        errdefer st.gpa.destroy(job);
        job.* = .{ .st = st, .gen = st.gen, .arena = .init(st.gpa), .src = undefined, .m = st.measure };
        job.src = try job.arena.allocator().dupe(u8, src);
        st.app.spawn(Job.run, .{job});
        st.app.notifyEntity(st.surface.entity);
    }

    /// Redraws with `theme` (no new layout).
    pub fn setTheme(st: *DiagramViewState, theme: DiagramTheme) !void {
        if (theme.hash() == st.theme.hash()) return;
        st.theme = theme;
        st.key = keyOf(st.src, theme);
        if (st.result != null) try st.redraw();
    }

    fn redraw(st: *DiagramViewState) !void {
        const r = st.result orelse return;
        const cv = try st.surface.begin();
        try dr.draw(cv, &r.diagram, &r.layout, st.theme, st.measure);
        try st.surface.commit();
        st.size = r.layout.size;
    }

    /// The diagram as an SVG document; false when it is not drawn.
    pub fn exportSvg(st: *const DiagramViewState, w: *std.Io.Writer) !bool {
        const r = st.result orelse return false;
        var arena: std.heap.ArenaAllocator = .init(st.gpa);
        defer arena.deinit();
        var cv: vector.VectorCanvas = .init(arena.allocator());
        try dr.draw(&cv, &r.diagram, &r.layout, st.theme, st.measure);
        const dl = try cv.finish();
        try dr.writeSvg(w, &dl, r.layout.size, st.theme);
        return true;
    }

    pub fn setZoom(st: *DiagramViewState, z: f32) void {
        st.zoom = std.math.clamp(z, 0.25, 4);
        st.app.notifyEntity(st.surface.entity);
    }

    pub fn panBy(st: *DiagramViewState, dx: f32, dy: f32) void {
        st.pan = .{ st.pan[0] + dx, st.pan[1] + dy };
        st.app.notifyEntity(st.surface.entity);
    }

    const Job = struct {
        st: *DiagramViewState,
        gen: u32,
        arena: std.heap.ArenaAllocator,
        src: []const u8,
        m: Measure,
        prepared: ?dr.Prepared = null,

        fn run(job: *Job) void {
            job.prepared = dr.prepare(job.arena.allocator(), job.src, job.m) catch null;
            job.st.app.post(.{ .ctx = job, .f = done }) catch {};
        }

        fn done(ctx: *anyopaque, _: *App) void {
            const job: *Job = @ptrCast(@alignCast(ctx));
            const st = job.st;
            defer st.gpa.destroy(job);
            if (job.gen != st.gen) {
                job.arena.deinit();
                return;
            }
            st.builds += 1;
            st.adopt(job) catch {
                st.status = .failed;
                st.setNotice("the diagram could not be drawn", .{});
            };
            st.app.notifyEntity(st.surface.entity);
        }
    };

    fn adopt(st: *DiagramViewState, job: *Job) !void {
        const p = job.prepared orelse {
            job.arena.deinit();
            st.status = .failed;
            st.setNotice("the diagram could not be laid out", .{});
            return;
        };
        switch (p) {
            .ok => |ok| {
                st.dropResult();
                const r = try st.gpa.create(Result);
                r.* = .{ .arena = job.arena, .diagram = ok.diagram, .layout = ok.layout };
                st.result = r;
                st.status = .ready;
                st.setNotice("", .{});
                try st.redraw();
            },
            .unsupported => {
                job.arena.deinit();
                st.status = .unsupported;
                st.setNotice("This diagram type is not supported yet; showing its source.", .{});
            },
            .errors => |errs| {
                st.status = .failed;
                const e = errs[0];
                st.setNotice("{d}:{d}: {s}", .{ e.line, e.col, e.message });
                job.arena.deinit();
            },
        }
    }

    fn setNotice(st: *DiagramViewState, comptime fmt: []const u8, args: anytype) void {
        st.gpa.free(st.notice);
        st.notice = std.fmt.allocPrint(st.gpa, fmt, args) catch &.{};
    }
};

/// A placeholder size from the source: a row per few statements.
fn estimateSize(src: []const u8) [2]f32 {
    var lines: f32 = 0;
    var it = std.mem.tokenizeScalar(u8, src, '\n');
    while (it.next()) |_| lines += 1;
    return .{ 480, std.math.clamp(lines * 28, 80, 480) };
}

pub const Props = struct {
    /// The viewport's largest size; bigger diagrams pan inside it.
    max_w: f32 = 820,
    max_h: f32 = 480,
    test_id: ?[]const u8 = null,
    label: []const u8 = "Diagram",
};

/// Pointer, wheel and key handling over the viewport.
const PanLayer = struct {
    pub const name = "diagram_pan";
    pub const focusable = true;

    pub const State = struct {
        drag_from: ?geom.Vec2 = null,
    };

    pub const Props = struct {
        st: *DiagramViewState,
        w: f32,
        h: f32,
    };

    const step: f32 = 40;

    pub fn style(p: *const PanLayer.Props, _: *const zg_gui.theme.Theme) zg_gui.layout.style.Style {
        return .{ .position = .absolute, .inset = .{ .l = 0, .t = 0 }, .w = .{ .px = p.w }, .h = .{ .px = p.h }, .z = 1 };
    }

    pub fn measure(_: *zg_gui.layout.measure.MeasureCx, p: *const PanLayer.Props, _: *State, _: ?f32) geom.Size {
        return .{ .w = p.w, .h = p.h };
    }

    pub fn event(ec: *event_mod.EventCx, p: *const PanLayer.Props, s: *State, ev: *const event_mod.InputEvent) bool {
        const st = p.st;
        switch (ev.*) {
            .pointer_down => |m| {
                ec.focus();
                ec.capture();
                s.drag_from = m.pos;
                return true;
            },
            .pointer_move => |m| if (s.drag_from) |from| {
                st.panBy(from.x - m.pos.x, from.y - m.pos.y);
                s.drag_from = m.pos;
                return true;
            },
            .pointer_up => if (s.drag_from != null) {
                s.drag_from = null;
                ec.releaseCapture();
                return true;
            },
            .scroll => |sc| {
                const k: f32 = if (sc.precise) 1 else step;
                st.panBy(-sc.dx * k, -sc.dy * k);
                return true;
            },
            .key => |k| {
                if (k.action == .release) return false;
                switch (k.key) {
                    .arrow_left => st.panBy(-step, 0),
                    .arrow_right => st.panBy(step, 0),
                    .arrow_up => st.panBy(0, -step),
                    .arrow_down => st.panBy(0, step),
                    .equal, .numpad_add => st.setZoom(st.zoom * 1.25),
                    .minus, .numpad_subtract => st.setZoom(st.zoom / 1.25),
                    .digit_0 => {
                        st.setZoom(1);
                        st.pan = .{ 0, 0 };
                    },
                    else => return false,
                }
                return true;
            },
            else => {},
        }
        return false;
    }

    pub fn a11y(_: *const PanLayer.Props, _: *State) zg_gui.core.widget.A11y {
        return .{ .role = .img, .name = "Diagram viewport" };
    }
};

/// Draws the diagram (or its placeholder, or its source and notice).
pub fn diagramView(ui: *Ui, st: *DiagramViewState, p: Props) void {
    ui.cx().observe(st.surface.entity);
    const th = ui.theme();
    ui.open(.{ .role = .group, .label = p.label, .test_id = p.test_id orelse "", .style = .{ .dir = .column, .gap = 4, .align_items = .stretch } });
    defer ui.close();

    switch (st.status) {
        .empty, .pending => {
            ui.open(.{ .role = .status, .label = "Laying out diagram", .style = .{ .w = .{ .px = @min(st.size[0], p.max_w) }, .h = .{ .px = @min(st.size[1], p.max_h) }, .bg = .{ .token = .bg_sunken }, .radius = th.dim(.radius_md) } });
            ui.close();
            return;
        },
        .unsupported, .failed => {
            ui.open(.{ .role = .status, .label = "Diagram error", .style = .{ .dir = .column, .gap = 4, .padding = .all(8), .bg = .{ .token = .bg_sunken }, .radius = th.dim(.radius_md) } });
            ui.text(st.notice, .{ .color = if (st.status == .failed) .danger else .fg_muted });
            ui.text(st.src, .{ .style = .{ .font = .mono }, .wrap = false });
            ui.close();
            return;
        },
        .ready => {},
    }

    // Toolbar.
    ui.open(.{ .style = .{ .dir = .row, .gap = 4, .align_items = .center } });
    if (zg_gui.w.controls.button(ui, .{ .label = "−", .variant = .ghost }).clicked) st.setZoom(st.zoom / 1.25);
    ui.textf("{d}%", .{@round(st.zoom * 100)}, .{ .color = .fg_muted, .wrap = false });
    if (zg_gui.w.controls.button(ui, .{ .label = "+", .variant = .ghost }).clicked) st.setZoom(st.zoom * 1.25);
    if (zg_gui.w.controls.button(ui, .{ .label = "Reset", .variant = .ghost }).clicked) {
        st.setZoom(1);
        st.pan = .{ 0, 0 };
    }
    if (st.on_open_artifact) |a| if (zg_gui.w.controls.button(ui, .{ .label = "Open as artifact", .variant = .ghost }).clicked) a.f(a.ctx, st);
    if (st.on_export_svg) |a| if (zg_gui.w.controls.button(ui, .{ .label = "Export SVG", .variant = .ghost }).clicked) a.f(a.ctx, st);
    ui.close();

    // The viewport, the diagram offset by the pan inside it.
    const full = [2]f32{ st.size[0] * st.zoom, st.size[1] * st.zoom };
    const vw = @min(full[0], p.max_w);
    const vh = @min(full[1], p.max_h);
    st.pan = .{ std.math.clamp(st.pan[0], 0, full[0] - vw), std.math.clamp(st.pan[1], 0, full[1] - vh) };
    ui.open(.{ .style = .{ .w = .{ .px = vw }, .h = .{ .px = vh }, .clip = true } });
    ui.open(.{ .style = .{ .position = .absolute, .inset = .{ .l = -st.pan[0], .t = -st.pan[1] }, .w = .{ .px = full[0] }, .h = .{ .px = full[1] } } });
    vector_view.vectorView(ui, st.surface, .{ .w = full[0], .h = full[1], .zoom = st.zoom, .label = p.label });
    ui.close();
    _ = ui.leaf(PanLayer, .{ .st = st, .w = vw, .h = vh });
    ui.close();
}

/// The `mermaid` fence renderer: one view per distinct fence, cached by
/// source and theme (least recently used views go beyond `capacity`).
pub const DiagramFence = struct {
    gpa: Allocator,
    io: Io,
    app: *App,
    theme: DiagramTheme = .light,
    measure: ?Measure = null,
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    tick: u64 = 0,
    capacity: usize = 32,
    hits: u32 = 0,
    misses: u32 = 0,
    on_open_artifact: ?Action = null,
    on_export_svg: ?Action = null,

    const Slot = struct { key: [32]u8, st: *DiagramViewState, used: u64 };

    pub fn init(gpa: Allocator, io: Io, app: *App) DiagramFence {
        return .{ .gpa = gpa, .io = io, .app = app };
    }

    /// Call when no job is pending (`App.joinWork`, then drain).
    pub fn deinit(f: *DiagramFence) void {
        for (f.slots.items) |s| s.st.deinit();
        f.slots.deinit(f.gpa);
    }

    /// Fences draw with `theme` from now on.
    pub fn setTheme(f: *DiagramFence, theme: DiagramTheme) void {
        f.theme = theme;
    }

    /// The view for `src`, made (and started) on a miss.
    pub fn view(f: *DiagramFence, src: []const u8) !*DiagramViewState {
        f.tick += 1;
        const key = DiagramViewState.keyOf(src, f.theme);
        for (f.slots.items) |*s| if (std.mem.eql(u8, &s.key, &key)) {
            s.used = f.tick;
            f.hits += 1;
            return s.st;
        };
        f.misses += 1;
        if (f.slots.items.len >= f.capacity) f.evict();
        const st = try DiagramViewState.init(f.gpa, f.io, f.app, .{ .theme = f.theme, .measure = f.measure });
        errdefer st.deinit();
        st.on_open_artifact = f.on_open_artifact;
        st.on_export_svg = f.on_export_svg;
        try st.setSource(src);
        try f.slots.append(f.gpa, .{ .key = key, .st = st, .used = f.tick });
        return st;
    }

    /// Drops the least recently used view with no job in flight.
    fn evict(f: *DiagramFence) void {
        var best: ?usize = null;
        for (f.slots.items, 0..) |s, i| {
            if (s.st.status == .pending) continue;
            if (best == null or s.used < f.slots.items[best.?].used) best = i;
        }
        const i = best orelse return;
        f.slots.items[i].st.deinit();
        _ = f.slots.swapRemove(i);
    }

    fn build(ctx: *anyopaque, ui: *Ui, b: zg_gui.markdown.BlockInfo) bool {
        const f: *DiagramFence = @ptrCast(@alignCast(ctx));
        // Streaming fences stay code until they close.
        if (!b.closed) return false;
        const st = f.view(b.code) catch return false;
        ui.id(@as(u64, b.key));
        diagramView(ui, st, .{ .max_w = b.max_width, .test_id = "md-diagram" });
        return true;
    }

    fn estimate(ctx: *anyopaque, b: zg_gui.markdown.BlockInfo) ?f32 {
        const f: *DiagramFence = @ptrCast(@alignCast(ctx));
        const key = DiagramViewState.keyOf(b.code, f.theme);
        for (f.slots.items) |s| if (std.mem.eql(u8, &s.key, &key)) return @min(s.st.size[1] * s.st.zoom, (Props{}).max_h) + 32;
        return @min(estimateSize(b.code)[1], (Props{}).max_h);
    }

    /// Maps `mermaid` fences in `reg` to this renderer.
    pub fn register(f: *DiagramFence, reg: *zg_gui.MarkdownBlockRenderers) !void {
        try reg.register("mermaid", .{ .ctx = f, .build = build, .estimate = estimate });
    }
};

/// Registers `f` as the `mermaid` fence renderer (see
/// `DiagramFence.register`).
pub fn registerFenceRenderer(reg: *zg_gui.MarkdownBlockRenderers, f: *DiagramFence) !void {
    return f.register(reg);
}
