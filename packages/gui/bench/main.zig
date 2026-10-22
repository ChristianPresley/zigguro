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

/// A 10k-character multi-line field (about 125 wrapped rows, 12 shown).
const Prompt = struct {
    buf: *zg_gui.w.TextBuffer,

    pub fn build(self: *Prompt, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .padding = .all(8) } });
        defer ui.close();
        _ = zg_gui.w.textField(ui, .{ .buffer = self.buf, .multiline = true, .min_rows = 3, .max_rows = 12, .placeholder = "Prompt" });
    }
};

/// One frame per keystroke in the middle of the text: a typed character,
/// then a Backspace, so the text length stays put.
fn keystroke(t: *TestApp, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        if (i % 2 == 0) {
            t.win.dispatch(.{ .text = "a" });
        } else {
            t.win.dispatch(.{ .key = .{ .key = .backspace } });
        }
        bench.doNotOptimizeAway(t.frame().nodes_painted);
    }
}

/// Opens a 50-item menu and runs the frame that shows it, then closes it
/// again (two frames per iteration; the open frame is the budgeted part).
/// A workbench-sized layout: 4 groups of 6 tabs.
const DockCase = struct {
    m: zg_gui.dock.DockModel,
    groups: [4]zg_gui.dock.model.GroupId,
    panels: [24]zg_gui.dock.model.PanelRef,
};

/// Moves a tab into another tab's group, with undo history (one op per
/// iteration).
fn dockOp(c: *DockCase, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const p = c.panels[i % c.panels.len];
        // Next to another panel, wherever that one is now.
        const q = c.panels[(i * 7 + 3) % c.panels.len];
        const g = c.m.groupOf(q) orelse continue;
        c.m.move(p, .{ .group = .{ .g = g } }) catch return;
        bench.doNotOptimizeAway(c.m.groups.count());
    }
}

fn menuOpen(t: *TestApp, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const h = zg_gui.w.openMenu(t.win, &menu_items, .{ .pointer = .{ .x = 10, .y = 10 } }, .{}) catch return;
        bench.doNotOptimizeAway(t.frame().nodes_painted);
        h.close(t.win);
        bench.doNotOptimizeAway(t.frame().nodes_painted);
    }
}

const menu_items = blk: {
    var items: [50]zg_gui.w.MenuItem = undefined;
    for (&items) |*it| it.* = .{ .action = .{ .label = "&Menu item", .action = "bench.item", .shortcut = "Ctrl+K" } };
    break :blk items;
};

/// 100k file-like paths behind an async provider; `query` scores them with
/// the default matcher and pushes batches of 1000 (inline here: the bench
/// has no runtime, so this measures the whole query plus the merges).
const QpBench = struct {
    gpa: std.mem.Allocator,
    labels: [][]const u8,

    fn query(ptr: ?*anyopaque, q: []const u8, sink: *zg_gui.w.quick_pick_provider.ResultSink, cancel: *const std.atomic.Value(bool)) void {
        const self: *QpBench = @ptrCast(@alignCast(ptr.?));
        var hl: std.ArrayList([2]u32) = .empty;
        defer hl.deinit(self.gpa);
        var batch: [1000]zg_gui.w.QpItem = undefined;
        var hls: [1000][4][2]u32 = undefined;
        var n: usize = 0;
        for (self.labels, 0..) |l, i| {
            if (cancel.load(.acquire)) return;
            hl.clearRetainingCapacity();
            const sc = zg_gui.w.quick_pick_matcher.scoreOf(q, l, &hl, self.gpa) orelse continue;
            const k = @min(hl.items.len, 4);
            @memcpy(hls[n][0..k], hl.items[0..k]);
            batch[n] = .{ .id = i, .label = l, .score = sc, .highlights = hls[n][0..k] };
            n += 1;
            if (n == batch.len) {
                sink.push(&batch);
                n = 0;
            }
        }
        sink.push(batch[0..n]);
    }

    fn accept(_: ?*anyopaque, _: []const zg_gui.w.QpItem, _: ?[]const u8, _: bool) void {}

    const vtable: zg_gui.w.quick_pick_provider.Provider.VTable = .{ .query = query, .accept = accept };
};

/// Opens a QuickPick over 100k items, streams every match in and closes it.
fn quickPick(c: *QpCase, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const h = zg_gui.w.openQuickPick(c.t.win, .{ .providers = &.{.{ .ptr = c.qp, .vtable = &QpBench.vtable }}, .initial = "f12" }) catch return;
        bench.doNotOptimizeAway(c.t.settle());
        h.close(c.t.win);
        bench.doNotOptimizeAway(c.t.frame().nodes_painted);
    }
}

const QpCase = struct { t: *TestApp, qp: *QpBench };

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
        const text = try b.gpa.alloc(u8, 10_000);
        defer b.gpa.free(text);
        for (text, 0..) |*c, i| c.* = if (i % 9 == 8) ' ' else 'a' + @as(u8, @intCast(i % 26));
        var buf: zg_gui.w.TextBuffer = try .init(b.gpa, text);
        defer buf.deinit();
        var v: Prompt = .{ .buf = &buf };
        const t = try scene(b.gpa, .of(&v), .{ .w = 800, .h = 600 });
        defer t.deinit();
        const r = t.win.store.absRect(t.find(.{ .name = "Prompt" }).?);
        t.win.dispatch(.{ .pointer_down = .{ .pos = .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 } } });
        t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 } } });
        _ = t.settle();
        try b.run("gui.text_field.keystroke_10k", t, keystroke);
    }
    {
        var v: ListView = .{ .n = 100 };
        const t = try scene(b.gpa, .of(&v), .{ .w = 1280, .h = 800 });
        defer t.deinit();
        try b.run("gui.menu.open_50", t, menuOpen);
    }
    {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const labels = try arena.allocator().alloc([]const u8, 100_000);
        for (labels, 0..) |*l, i| l.* = try std.fmt.allocPrint(arena.allocator(), "src/pkg{d}/module{d}/file{d}.zig", .{ i % 97, i % 1013, i });
        var qp: QpBench = .{ .gpa = b.gpa, .labels = labels };
        var page: ListView = .{ .n = 10 };
        const t = try scene(b.gpa, .of(&page), .{ .w = 1200, .h = 900 });
        defer t.deinit();
        var c: QpCase = .{ .t = t, .qp = &qp };
        try b.run("gui.quickpick_100k", &c, quickPick);
    }
    {
        var c: DockCase = .{ .m = try .init(b.gpa), .groups = undefined, .panels = undefined };
        defer c.m.deinit();
        const center = c.m.firstGroup(c.m.areas[@intFromEnum(zg_gui.dock.model.Area.center)].root).?;
        c.groups[0] = center;
        for (&c.panels, 0..) |*p, i| {
            p.* = try c.m.addPanel(1, null);
            if (i < 4 and i > 0) {
                c.groups[i] = (try c.m.split(c.groups[i - 1], if (i % 2 == 0) .bottom else .right, p.*)).?;
            } else try c.m.openIn(p.*, c.groups[i % 4], null, .{});
        }
        try b.run("gui.dock.op", &c, dockOp);
    }
    {
        var h: zg_gui.w.HeightIndex = .init(b.gpa);
        defer h.deinit();
        try h.resize(10_000_000, 20);
        try b.run("gui.virtual.height_index_10m", &h, heightIndex);
    }
}
