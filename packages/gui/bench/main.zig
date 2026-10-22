//! Benchmarks for zg_gui; run with `zig build bench` at the repo root.
//! Every scene is headless (`TestApp`: monospace text, recording canvas),
//! so the numbers measure the runtime itself, not a renderer.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_gui = @import("zg_gui");
const bench = zg_core.bench;

const Ui = zg_gui.Ui;
const TestApp = zg_gui.testing.TestApp;
const geom = zg_gui.core.geom;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

/// Budgeted bench names that have no body yet.
pub const pending = [_][]const u8{
    "gui.frame.idle_with_animation",
    "gui.text.shape_cache_hit",
};

/// A keyed column of `n` rows, each a row box with two text leaves.
const ListView = struct {
    n: u32,
    /// Changes every row's label on each build (a full rebuild).
    churn: bool = false,
    round: u32 = 0,

    pub fn build(self: *ListView, ui: *Ui) void {
        self.round +%= 1;
        ui.open(.{ .test_id = "list", .style = .{ .dir = .column } });
        defer ui.close();
        var i: u32 = 0;
        while (i < self.n) : (i += 1) {
            ui.id(i);
            ui.open(.{ .style = .{ .dir = .row, .gap = 4 } });
            defer ui.close();
            if (self.churn) ui.textf("row {d}.{d}", .{ i, self.round }, .{}) else ui.textf("row {d}", .{i}, .{});
            ui.text("detail", .{ .color = .fg_muted });
        }
    }
};

/// A wrapping flex row of `n` fixed-size hit-testable boxes.
const GridView = struct {
    n: u32,

    pub fn build(self: *GridView, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .row, .wrap = true, .gap = 2 } });
        defer ui.close();
        var i: u32 = 0;
        while (i < self.n) : (i += 1) {
            ui.open(.{ .hit = true, .style = .{ .w = .{ .px = 10 }, .h = .{ .px = 10 } } });
            ui.close();
        }
    }
};

fn scene(gpa: std.mem.Allocator, v: zg_gui.AnyView, size: geom.Size) !*TestApp {
    const t = try TestApp.init(gpa, .{ .root = v, .size = size });
    _ = t.settle();
    return t;
}

/// Rebuilds an unchanged 1k-row list: reconcile only, no layout or paint.
fn reconcileUnchanged(t: *TestApp, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        t.win.markAllDirty();
        bench.doNotOptimizeAway(t.frame().nodes_emitted);
    }
}

/// Rebuilds a 5k-row list whose every label changed: reconcile, layout,
/// paint and present.
fn rebuildChanged(t: *TestApp, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        t.win.markAllDirty();
        bench.doNotOptimizeAway(t.frame().nodes_painted);
    }
}

/// Lays out 10k wrapped boxes after each width change.
fn layoutFlex(t: *TestApp, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const w: f32 = if (t.win.size.w == 1200) 1180 else 1200;
        t.win.resize(.{ .w = w, .h = 900 }, 1);
        bench.doNotOptimizeAway(t.frame().layout.visited);
    }
}

/// Hit-tests scattered points against 10k rectangles.
fn hitTest(t: *TestApp, s: *bench.State) void {
    var rng: std.Random.DefaultPrng = .init(0x0404);
    const r = rng.random();
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const p: geom.Vec2 = .{ .x = r.float(f32) * 1200, .y = r.float(f32) * 900 };
        bench.doNotOptimizeAway(t.win.hitTest(p));
    }
}

/// A scroll area holding 2 000 laid-out rows.
const ScrollPage = struct {
    area: zg_gui.core.ids.NodeId = .none,

    pub fn build(self: *ScrollPage, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .w = .{ .px = 800 }, .h = .{ .px = 600 } } });
        defer ui.close();
        self.area = zg_gui.w.scrollArea(ui, .{});
        defer ui.close();
        var i: u32 = 0;
        while (i < 1000) : (i += 1) {
            ui.id(i);
            ui.open(.{ .style = .{ .h = .{ .px = 20 }, .shrink = 0 } });
            ui.textf("line {d}", .{i}, .{});
            ui.close();
        }
    }
};

/// A million-row virtual list.
const BigList = struct {
    node: zg_gui.core.ids.NodeId = .none,

    pub fn build(self: *BigList, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .w = .{ .px = 800 }, .h = .{ .px = 600 } } });
        defer ui.close();
        self.node = zg_gui.w.virtualList(ui, .{ .count = 1_000_000, .row_h = 20 }, self, row).node;
    }

    fn row(_: *BigList, ui: *Ui, i: usize) void {
        ui.textf("row {d}", .{i}, .{});
    }
};

const ScrollCtx = struct { t: *TestApp, node: zg_gui.core.ids.NodeId, step: f32 };

/// One frame per one-step scroll, bouncing between the ends.
fn scrollFrame(c: *ScrollCtx, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        if (!c.t.win.scrollBy(c.node, .{ .y = c.step })) c.step = -c.step;
        bench.doNotOptimizeAway(c.t.frame().nodes_replayed);
    }
}

/// `set` then `find` on a 10M-row height index.
fn heightIndex(h: *zg_gui.w.HeightIndex, s: *bench.State) void {
    var rng: std.Random.DefaultPrng = .init(0x1010);
    const r = rng.random();
    const total = h.total();
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        h.set(r.uintLessThan(usize, h.len()), 18 + r.float(f32) * 4);
        bench.doNotOptimizeAway(h.find(r.float(f32) * total));
    }
}

fn register(b: *bench.Bench) !void {
    for (pending) |name| if (b.opts.filter == null or std.mem.indexOf(u8, name, b.opts.filter.?) != null)
        std.debug.print("{s:<40} skipped (not implemented yet)\n", .{name});

    {
        var v: ListView = .{ .n = 1000 };
        const t = try scene(b.gpa, .of(&v), .{ .w = 800, .h = 600 });
        defer t.deinit();
        try b.run("gui.reconcile.unchanged_1k", t, reconcileUnchanged);
    }
    {
        var v: ListView = .{ .n = 5000, .churn = true };
        const t = try scene(b.gpa, .of(&v), .{ .w = 800, .h = 600 });
        defer t.deinit();
        try b.run("gui.reconcile.rebuild_5k", t, rebuildChanged);
    }
    {
        var v: GridView = .{ .n = 10_000 };
        const t = try scene(b.gpa, .of(&v), .{ .w = 1200, .h = 900 });
        defer t.deinit();
        try b.run("gui.layout.flex_10k", t, layoutFlex);
        try b.run("gui.input.hit_test_10k", t, hitTest);
    }
    {
        var v: ScrollPage = .{};
        const t = try scene(b.gpa, .of(&v), .{ .w = 800, .h = 600 });
        defer t.deinit();
        var c: ScrollCtx = .{ .t = t, .node = v.area, .step = 7 };
        try b.run("gui.scroll_frame", &c, scrollFrame);
    }
    {
        var v: BigList = .{};
        const t = try scene(b.gpa, .of(&v), .{ .w = 800, .h = 600 });
        defer t.deinit();
        var c: ScrollCtx = .{ .t = t, .node = v.node, .step = 20 };
        try b.run("gui.virtual.scroll_frame_1m", &c, scrollFrame);
    }
    {
        var h: zg_gui.w.HeightIndex = .init(b.gpa);
        defer h.deinit();
        try h.resize(10_000_000, 20);
        try b.run("gui.virtual.height_index_10m", &h, heightIndex);
    }
}
