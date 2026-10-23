//! Vector views (E13.F07.S01.T02): a display list on screen through the
//! tile cache. Tiles are rasterized on workers and shown as app image
//! textures. Until a tile is ready, the tiles of the previous scale are
//! drawn stretched over it, so a zoom or DPI change never shows a blank
//! frame. Text is drawn as glyph quads from E03's atlas.
//!
//! `VectorSurface` owns the display list (record into `begin`, then
//! `commit`) and the tiles; `vectorView` draws it at one logical pixel
//! per unit times `zoom`.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const App = zg_gui.App;
const Ui = zg_gui.Ui;
const geom = zg_gui.core.geom;
const vector = zg_agents.vector;
const tiles = vector.tiles;
const TextureId = zg_gui.paint.canvas.TextureId;

pub const VectorSurface = struct {
    gpa: Allocator,
    io: Io,
    app: *App,
    cache: tiles.TileCache,
    threads: usize,
    entity: zg_gui.core.EntityId,
    /// The committed list and its arena.
    dl: ?vector.DisplayList = null,
    arena: ?*std.heap.ArenaAllocator = null,
    /// What `begin` records into.
    recording: ?*std.heap.ArenaAllocator = null,
    canvas: vector.VectorCanvas = undefined,
    /// Arenas of replaced lists that a job may still read.
    retired: std.ArrayListUnmanaged(*std.heap.ArenaAllocator) = .empty,
    pending: bool = false,
    /// The scale last drawn with every tile ready (the fallback).
    last_scale_q: ?u32 = null,
    /// Tile rasterizations done (tests).
    jobs_done: u32 = 0,

    pub const Options = struct {
        budget: usize = tiles.TileCache.default_budget,
        threads: usize = 4,
    };

    pub fn init(gpa: Allocator, io: Io, app: *App, o: Options) !*VectorSurface {
        const s = try gpa.create(VectorSurface);
        errdefer gpa.destroy(s);
        const e = try app.new(u8, 0);
        s.* = .{ .gpa = gpa, .io = io, .app = app, .cache = .init(gpa, o.budget), .threads = o.threads, .entity = e.id };
        s.cache.on_evict = .{ .ctx = s, .f = onEvict };
        return s;
    }

    /// Call when no job is pending (`App.joinWork` first).
    pub fn deinit(s: *VectorSurface) void {
        s.cache.deinit();
        if (s.arena) |a| freeArena(s.gpa, a);
        if (s.recording) |a| freeArena(s.gpa, a);
        for (s.retired.items) |a| freeArena(s.gpa, a);
        s.retired.deinit(s.gpa);
        s.app.release(s.entity);
        s.gpa.destroy(s);
    }

    fn freeArena(gpa: Allocator, a: *std.heap.ArenaAllocator) void {
        a.deinit();
        gpa.destroy(a);
    }

    fn onEvict(ctx: *anyopaque, t: *tiles.Tile) void {
        const s: *VectorSurface = @ptrCast(@alignCast(ctx));
        if (t.user != 0) s.app.images.remove(s.gpa, @enumFromInt(@as(u32, @intCast(t.user))));
        t.user = 0;
    }

    /// A canvas to record the next list into.
    pub fn begin(s: *VectorSurface) !*vector.VectorCanvas {
        if (s.recording) |a| freeArena(s.gpa, a);
        const a = try s.gpa.create(std.heap.ArenaAllocator);
        a.* = .init(s.gpa);
        s.recording = a;
        s.canvas = .init(a.allocator());
        return &s.canvas;
    }

    /// Shows what was recorded since `begin`.
    pub fn commit(s: *VectorSurface) !void {
        const a = s.recording orelse return;
        const dl = try s.canvas.finish();
        if (s.arena) |old| {
            if (s.pending) try s.retired.append(s.gpa, old) else freeArena(s.gpa, old);
        }
        s.arena = a;
        s.recording = null;
        s.dl = dl;
        s.app.notifyEntity(s.entity);
    }

    const Job = struct {
        s: *VectorSurface,
        dl: *const vector.DisplayList,
        keys: []tiles.Key,
    };

    fn run(job: *Job) void {
        const s = job.s;
        tiles.rasterizeTiles(s.io, &s.cache, job.dl, job.keys, s.threads) catch {};
        s.app.post(.{ .ctx = job, .f = done }) catch {};
    }

    fn done(ctx: *anyopaque, app: *App) void {
        const job: *Job = @ptrCast(@alignCast(ctx));
        const s = job.s;
        s.gpa.free(job.keys);
        s.gpa.destroy(job);
        s.pending = false;
        s.jobs_done += 1;
        for (s.retired.items) |a| freeArena(s.gpa, a);
        s.retired.clearRetainingCapacity();
        app.notifyEntity(s.entity);
    }

    fn schedule(s: *VectorSurface, keys: []const tiles.Key) void {
        if (s.pending or keys.len == 0) return;
        const job = s.gpa.create(Job) catch return;
        job.* = .{ .s = s, .dl = &s.dl.?, .keys = s.gpa.dupe(tiles.Key, keys) catch {
            s.gpa.destroy(job);
            return;
        } };
        s.pending = true;
        s.app.spawn(run, .{job});
    }

    /// The texture of a ready tile (uploaded on first use).
    fn texture(s: *VectorSurface, t: *tiles.Tile) ?TextureId {
        if (t.user == 0) {
            const id = s.app.images.add(s.gpa, tiles.tile_size, tiles.tile_size, t.pixels) catch return null;
            t.user = @intFromEnum(id);
        }
        return @enumFromInt(@as(u32, @intCast(t.user)));
    }
};

pub const Props = struct {
    /// The view's size in logical pixels (default: the list's bounds).
    w: ?f32 = null,
    h: ?f32 = null,
    zoom: f32 = 1,
    test_id: ?[]const u8 = null,
    label: []const u8 = "",
};

/// The widget: tile quads and text, laid out by `vectorView`.
const VectorWidget = struct {
    pub const name = "vector";
    pub const State = struct {};

    pub const Quad = struct { tex: TextureId, dst: geom.Rect };

    /// A text item with its string as a range of `chars` (props keep no
    /// nested slices).
    pub const Run = struct {
        x: f32,
        y: f32,
        size: f32,
        color: vector.Color,
        anchor: vector.display_list.Anchor,
        baseline: vector.display_list.Baseline,
        bold: bool,
        start: u32,
        len: u32,
    };

    pub const Props = struct {
        w: f32,
        h: f32,
        quads: []const Quad,
        texts: []const Run,
        /// The runs' bytes.
        chars: []const u8,
        zoom: f32,
        /// Changes when what is drawn does.
        hash: u64,
    };

    pub fn style(p: *const VectorWidget.Props, _: *const zg_gui.theme.Theme) zg_gui.layout.style.Style {
        return .{ .w = .{ .px = p.w }, .h = .{ .px = p.h }, .clip = true };
    }

    pub fn measure(_: *zg_gui.layout.measure.MeasureCx, p: *const VectorWidget.Props, _: *State, _: ?f32) geom.Size {
        return .{ .w = p.w, .h = p.h };
    }

    pub fn paint(pc: *zg_gui.paint.PaintCx, p: *const VectorWidget.Props, _: *State) void {
        const box = pc.bounds();
        pc.pushClip(box, 0);
        defer pc.popClip();
        for (p.quads) |q| pc.image(q.tex, q.dst, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .r = 255, .g = 255, .b = 255 }, 0);
        for (p.texts) |t| {
            const str = p.chars[t.start..][0..t.len];
            const st: zg_gui.paint.text.TextStyle = .{ .size = t.size * p.zoom, .weight = if (t.bold) 700 else 400 };
            const w = pc.text_sys.width(st, str);
            const m = pc.text_sys.metrics(st);
            var x = t.x * p.zoom;
            switch (t.anchor) {
                .start => {},
                .middle => x -= w / 2,
                .end => x -= w,
            }
            var y = t.y * p.zoom;
            switch (t.baseline) {
                .alphabetic => {},
                .middle => y += (m.ascent - m.descent) / 2,
                .top => y += m.ascent,
                .bottom => y -= m.descent,
            }
            const c = t.color;
            // Rotated text is drawn level (vertical glyph runs wait for
            // E03 rotation support).
            pc.textLine(str, st, .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }, .{ .x = x, .y = y });
        }
    }
};

/// Draws `s`'s committed list; schedules missing tiles on a worker.
pub fn vectorView(ui: *Ui, s: *VectorSurface, p: Props) void {
    ui.cx().observe(s.entity);
    const a = ui.arena();
    const dl = s.dl orelse {
        _ = ui.leaf(VectorWidget, .{ .w = p.w orelse 0, .h = p.h orelse 0, .quads = &.{}, .texts = &.{}, .chars = "", .zoom = p.zoom, .hash = 0 });
        return;
    };
    const lw = p.w orelse @max(0, dl.bounds.x1) * p.zoom;
    const lh = p.h orelse @max(0, dl.bounds.y1) * p.zoom;
    const device = ui.window().scale * p.zoom;
    const scale_q = tiles.quantizeScale(device);
    const scale = @as(f32, @floatFromInt(scale_q)) / 1000;
    const keep_since = s.cache.now(s.io);

    var quads: std.ArrayListUnmanaged(VectorWidget.Quad) = .empty;
    var under: std.ArrayListUnmanaged(VectorWidget.Quad) = .empty;
    var missing: std.ArrayListUnmanaged(tiles.Key) = .empty;
    var h: std.hash.Wyhash = .init(dl.hash);
    const r = tiles.tilesFor(.{ .x0 = 0, .y0 = 0, .x1 = lw / p.zoom * scale, .y1 = lh / p.zoom * scale });
    var fallback_drawn = false;
    var ty = r.y0;
    while (ty < r.y1) : (ty += 1) {
        var tx = r.x0;
        while (tx < r.x1) : (tx += 1) {
            const key: tiles.Key = .{ .hash = dl.hash, .scale_q = scale_q, .tx = tx, .ty = ty };
            if (s.cache.get(s.io, key)) |t| {
                if (s.texture(t)) |tex| {
                    quads.append(a, .{ .tex = tex, .dst = tileRect(tx, ty, scale, p.zoom) }) catch {};
                    h.update(std.mem.asBytes(&key));
                }
            } else {
                missing.append(a, key) catch {};
                if (!fallback_drawn) {
                    fallback_drawn = true;
                    // Every tile of the last complete scale, stretched,
                    // under the ready ones.
                    if (s.last_scale_q) |old_q| if (old_q != scale_q) fallback(s, a, &under, &h, dl, old_q, lw, lh, p.zoom);
                }
            }
        }
    }
    if (missing.items.len == 0) s.last_scale_q = scale_q else s.schedule(missing.items);
    // The stretched fallback goes under the ready tiles.
    under.appendSlice(a, quads.items) catch {};
    var texts: std.ArrayListUnmanaged(VectorWidget.Run) = .empty;
    var chars: std.ArrayListUnmanaged(u8) = .empty;
    for (dl.items) |it| if (it == .text) {
        const t = it.text;
        const start: u32 = @intCast(chars.items.len);
        chars.appendSlice(a, t.text) catch continue;
        texts.append(a, .{ .x = t.x, .y = t.y, .size = t.size, .color = t.color, .anchor = t.anchor, .baseline = t.baseline, .bold = t.bold, .start = start, .len = @intCast(t.text.len) }) catch {};
    };
    ui.open(.{ .role = .img, .label = p.label, .test_id = p.test_id orelse "", .style = .{ .w = .{ .px = lw }, .h = .{ .px = lh } } });
    _ = ui.leaf(VectorWidget, .{ .w = lw, .h = lh, .quads = under.items, .texts = texts.items, .chars = chars.items, .zoom = p.zoom, .hash = h.final() });
    ui.close();
    s.cache.trim(s.io, keep_since);
}

fn tileRect(tx: i32, ty: i32, scale: f32, zoom: f32) geom.Rect {
    const ts: f32 = tiles.tile_size;
    // Device pixels → logical pixels of the view.
    const k = zoom / scale;
    return .{ .x = @as(f32, @floatFromInt(tx)) * ts * k, .y = @as(f32, @floatFromInt(ty)) * ts * k, .w = ts * k, .h = ts * k };
}

fn fallback(s: *VectorSurface, a: Allocator, quads: *std.ArrayListUnmanaged(VectorWidget.Quad), h: *std.hash.Wyhash, dl: vector.DisplayList, old_q: u32, lw: f32, lh: f32, zoom: f32) void {
    const old: f32 = @as(f32, @floatFromInt(old_q)) / 1000;
    const r = tiles.tilesFor(.{ .x0 = 0, .y0 = 0, .x1 = lw / zoom * old, .y1 = lh / zoom * old });
    var ty = r.y0;
    while (ty < r.y1) : (ty += 1) {
        var tx = r.x0;
        while (tx < r.x1) : (tx += 1) {
            const key: tiles.Key = .{ .hash = dl.hash, .scale_q = old_q, .tx = tx, .ty = ty };
            const t = s.cache.get(s.io, key) orelse continue;
            const tex = s.texture(t) orelse continue;
            quads.append(a, .{ .tex = tex, .dst = tileRect(tx, ty, old, zoom) }) catch {};
            h.update(std.mem.asBytes(&key));
        }
    }
}
