//! The artifact pane (E13.F07.S01.T01): one artifact beside the
//! conversation, drawn by kind, with a version stepper and Save, Copy,
//! Open externally and Export.
//!
//! Body by kind:
//! * markdown: E04's MarkdownView;
//! * table: E04's Table over an F06 Dataset opened on the content;
//! * image: E04's ImageView when the app gives an ImageCache (SVG and
//!   images without a cache show their size);
//! * chart and diagram: the app's renderer view when one is plugged in
//!   (T03, F07.S02), else their source;
//! * code, html_source, text: read-only code blocks with highlighting.
//! Content is read (and parsed) on a worker; the pane shows a placeholder
//! until it arrives, so opening never waits on the disk. Nothing in an
//! artifact runs: HTML opens in the browser only after a confirmation.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const App = zg_gui.App;
const controls = zg_gui.w.controls;
const md = zg_gui.markdown;
const virtual = zg_gui.virtual;
const ImageCache = zg_gui.image.cache.ImageCache;

const artifacts = zg_agents.artifacts;
const ArtifactId = artifacts.ArtifactId;
const ArtifactStore = artifacts.ArtifactStore;
const Artifact = artifacts.Artifact;
const Content = artifacts.Content;
const save = artifacts.save;
const Dataset = zg_agents.data.Dataset;

/// `agents.artifacts.auto_open`.
pub const AutoOpen = enum { interactive, always, never };

/// Draws a chart or diagram (T03's chart view, F07.S02's diagram view).
pub const Renderer = struct {
    ctx: *anyopaque,
    build: *const fn (ctx: *anyopaque, ui: *Ui, content: []const u8) void,
};

pub const Ports = struct {
    store: *ArtifactStore,
    /// Decodes images; without one, images show their size.
    images: ?*ImageCache = null,
    /// Creates the save changeset (zg_review in the app).
    save: ?save.SavePort = null,
    save_dirs: save.SaveDirs = .{},
    /// Puts text on the clipboard.
    copy: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, text: []const u8) void } = null,
    /// Opens content outside zigguro (a temp file and E01's open-URL).
    open_external: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, ext: []const u8, bytes: []const u8) anyerror!void } = null,
    /// Exports a chart or diagram as SVG or PNG.
    export_: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, kind: artifacts.ArtifactKind, content: []const u8, format: []const u8) anyerror!void } = null,
    chart: ?Renderer = null,
    diagram: ?Renderer = null,
    highlighter: ?md.code_view.Highlighter = null,
    auto_open: AutoOpen = .interactive,
};

pub const Phase = enum { empty, loading, ready, failed };

/// One loaded version, built on a worker.
const Loaded = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    content: Content,
    /// Markdown (or a fenced code block) for text kinds.
    doc: ?md.Doc = null,
    md_state: ?md.MdViewState = null,
    ds: ?*Dataset = null,
    table: ?virtual.Table = null,
    columns: []virtual.Column = &.{},
    image: ?zg_gui.image.cache.Handle = null,
    images: ?*ImageCache = null,
    /// Shown above the body (e.g. why a chart shows its source).
    note: ?[]const u8 = null,
    cell_arena: std.heap.ArenaAllocator,

    fn destroy(l: *Loaded) void {
        if (l.table) |*t| t.deinit();
        if (l.ds) |d| d.close();
        if (l.md_state) |*s| s.deinit();
        if (l.doc) |*d| d.deinit();
        if (l.image) |h| if (l.images) |c| c.release(h);
        l.cell_arena.deinit();
        l.arena.deinit();
        l.gpa.destroy(l);
    }

    fn rowCount(ptr: *anyopaque) u64 {
        const l: *Loaded = @ptrCast(@alignCast(ptr));
        return switch (l.ds.?.rowCount()) {
            inline else => |n| n,
        };
    }

    fn cellText(ptr: *anyopaque, row: u64, col: u32) []const u8 {
        const l: *Loaded = @ptrCast(@alignCast(ptr));
        // Cells live until the next frame's first cell.
        return l.ds.?.cell(row, col, l.cell_arena.allocator()) catch "";
    }

    const table_vtable: virtual.TableSource.VTable = .{ .row_count = rowCount, .cell_text = cellText };
};

const Job = struct {
    pane: *ArtifactPane,
    gen: u32,
    id: ArtifactId,
    version: ?u32,
    loaded: ?*Loaded = null,
    err: ?anyerror = null,
};

pub const ArtifactPane = struct {
    gpa: Allocator,
    app: *App,
    p: Ports,
    entity: zg_gui.core.EntityId,
    current: ?ArtifactId = null,
    /// The version shown; null follows the latest.
    version: ?u32 = null,
    meta_arena: std.heap.ArenaAllocator,
    meta: ?Artifact = null,
    phase: Phase = .empty,
    err: ?anyerror = null,
    loaded: ?*Loaded = null,
    gen: u32 = 0,
    inflight: u32 = 0,
    seen_revision: u64 = 0,
    confirm_external: bool = false,
    notice: ?[]const u8 = null,
    notice_buf: [240]u8 = undefined,
    /// Opens requested by `artifactCreated`.
    opened_by_policy: u32 = 0,

    pub fn init(gpa: Allocator, app: *App, p: Ports) !*ArtifactPane {
        const v = try gpa.create(ArtifactPane);
        errdefer gpa.destroy(v);
        const e = try app.new(u8, 0);
        v.* = .{ .gpa = gpa, .app = app, .p = p, .entity = e.id, .meta_arena = .init(gpa) };
        return v;
    }

    /// Waits for loads in flight, then frees everything.
    pub fn deinit(v: *ArtifactPane) void {
        v.gen +%= 1;
        while (v.inflight > 0) {
            if (v.app.drainMessages() == 0) std.Thread.yield() catch {};
        }
        if (v.loaded) |l| l.destroy();
        v.meta_arena.deinit();
        v.app.release(v.entity);
        v.gpa.destroy(v);
    }

    pub fn build(v: *ArtifactPane, ui: *Ui) void {
        artifactPane(ui, v);
    }

    fn say(v: *ArtifactPane, comptime fmt: []const u8, args: anytype) void {
        v.notice = std.fmt.bufPrint(&v.notice_buf, fmt, args) catch "…";
    }

    /// Shows artifact `id` at `version` (the latest, following updates,
    /// when null).
    pub fn open(v: *ArtifactPane, id: ArtifactId, version: ?u32) void {
        v.current = id;
        v.version = version;
        v.confirm_external = false;
        v.notice = null;
        v.reload();
    }

    /// A new artifact was created; opens it per `auto_open` (background
    /// runs only list it among their outputs).
    pub fn artifactCreated(v: *ArtifactPane, id: ArtifactId, interactive: bool) void {
        const show = switch (v.p.auto_open) {
            .always => true,
            .interactive => interactive,
            .never => false,
        };
        if (!show) return;
        v.opened_by_policy += 1;
        v.open(id, null);
    }

    pub fn close(v: *ArtifactPane) void {
        v.current = null;
        v.gen +%= 1;
        v.phase = .empty;
        v.meta = null;
        if (v.loaded) |l| l.destroy();
        v.loaded = null;
        v.app.notifyEntity(v.entity);
    }

    /// Re-reads the metadata and starts loading the shown version.
    fn reload(v: *ArtifactPane) void {
        const id = v.current orelse return;
        v.seen_revision = v.p.store.revision.load(.acquire);
        _ = v.meta_arena.reset(.retain_capacity);
        v.meta = v.p.store.get(id, v.meta_arena.allocator()) catch null;
        v.gen +%= 1;
        if (v.meta == null) {
            v.phase = .failed;
            v.err = error.UnknownArtifact;
            return;
        }
        v.phase = .loading;
        v.err = null;
        const job = v.gpa.create(Job) catch {
            v.phase = .failed;
            v.err = error.OutOfMemory;
            return;
        };
        job.* = .{ .pane = v, .gen = v.gen, .id = id, .version = v.version };
        v.inflight += 1;
        v.app.spawn(work, .{job});
        v.app.notifyEntity(v.entity);
    }

    /// The version shown (1-based) and how many there are.
    pub fn shownVersion(v: *const ArtifactPane) struct { n: u32, of: u32 } {
        const m = v.meta orelse return .{ .n = 0, .of = 0 };
        return .{ .n = v.version orelse m.latest().n, .of = @intCast(m.versions.len) };
    }

    pub fn step(v: *ArtifactPane, delta: i32) void {
        const s = v.shownVersion();
        if (s.of == 0) return;
        const n: i64 = @as(i64, s.n) + delta;
        if (n < 1 or n > s.of) return;
        // Stepping back to the last version follows updates again.
        v.version = if (n == s.of) null else @intCast(n);
        v.notice = null;
        v.reload();
    }

    fn poll(v: *ArtifactPane) void {
        if (v.current == null) return;
        const r = v.p.store.revision.load(.acquire);
        if (r == v.seen_revision) return;
        const before = v.shownVersion();
        v.seen_revision = r;
        _ = v.meta_arena.reset(.retain_capacity);
        v.meta = v.p.store.get(v.current.?, v.meta_arena.allocator()) catch null;
        // Following the latest and a new version arrived: show it.
        if (v.version == null and v.shownVersion().n != before.n) v.reload();
    }

    pub fn saveShown(v: *ArtifactPane) void {
        const port = v.p.save orelse return;
        const m = v.meta orelse return;
        const s = v.shownVersion();
        const ver = m.version(s.n) orelse return;
        var buf: [512]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const path = save.proposePath(fba.allocator(), v.p.save_dirs, &m, ver) catch return v.say("Cannot save: name too long", .{});
        const cs = v.p.store.saveToWorkspace(v.current.?, s.n, path, port, .{}) catch |e| return v.say("Cannot save: {t}", .{e});
        v.say("Saved to {s} (changeset {d}; undo from the review queue)", .{ path, cs });
    }

    pub fn copyShown(v: *ArtifactPane) void {
        const c = v.p.copy orelse return;
        const l = v.loaded orelse return;
        c.f(c.ctx, l.content.bytes);
        v.say("Copied", .{});
    }

    /// HTML needs a confirmation first (it runs outside zigguro).
    pub fn openExternally(v: *ArtifactPane, confirmed: bool) void {
        const o = v.p.open_external orelse return;
        const l = v.loaded orelse return;
        const m = v.meta orelse return;
        if (m.kind == .html_source and !confirmed) {
            v.confirm_external = true;
            return;
        }
        v.confirm_external = false;
        o.f(o.ctx, l.content.ext, l.content.bytes) catch |e| return v.say("Cannot open: {t}", .{e});
        v.say("Opened outside zigguro", .{});
    }

    pub fn exportShown(v: *ArtifactPane, format: []const u8) void {
        const x = v.p.export_ orelse return;
        const l = v.loaded orelse return;
        const m = v.meta orelse return;
        x.f(x.ctx, m.kind, l.content.bytes, format) catch |e| return v.say("Cannot export: {t}", .{e});
        v.say("Exported as {s}", .{format});
    }
};

// ---- loading ----

fn work(job: *Job) void {
    const v = job.pane;
    job.loaded = load(v, job.id, job.version) catch |e| blk: {
        job.err = e;
        break :blk null;
    };
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        v.app.post(.{ .ctx = job, .f = deliver }) catch {
            if (tries < 10_000) {
                std.Thread.yield() catch {};
                continue;
            }
            // The UI is gone; nobody is waiting.
            if (job.loaded) |l| l.destroy();
            v.gpa.destroy(job);
            return;
        };
        return;
    }
}

fn load(v: *ArtifactPane, id: ArtifactId, version: ?u32) !*Loaded {
    const gpa = v.gpa;
    const l = try gpa.create(Loaded);
    l.* = .{ .gpa = gpa, .arena = .init(gpa), .content = undefined, .cell_arena = .init(gpa) };
    errdefer {
        l.arena.deinit();
        l.cell_arena.deinit();
        gpa.destroy(l);
    }
    const a = l.arena.allocator();
    const meta = (try v.p.store.get(id, a)) orelse return error.UnknownArtifact;
    l.content = try v.p.store.read(id, version, a);
    const c = l.content;
    switch (meta.kind) {
        .markdown => l.doc = try md.parse(gpa, c.bytes, .{}),
        .table => {
            const fmt: zg_agents.data.dataset.Format = if (std.mem.eql(u8, c.ext, "tsv")) .tsv else if (std.mem.eql(u8, c.ext, "json")) .json_array else if (std.mem.eql(u8, c.ext, "ndjson")) .ndjson else .csv;
            const ds = try Dataset.openBytes(gpa, v.p.store.io, c.bytes, fmt);
            errdefer ds.close();
            try ds.waitIndexed();
            l.ds = ds;
        },
        .image => {},
        .chart, .diagram => {
            const r = if (meta.kind == .chart) v.p.chart else v.p.diagram;
            if (r == null) {
                l.note = if (meta.kind == .chart) "Chart preview needs the chart renderer; showing the spec." else "Diagram preview needs the diagram renderer; showing the source.";
                l.doc = try md.parse(gpa, try fenced(a, if (meta.kind == .chart) "json" else "mermaid", c.bytes), .{});
            }
        },
        .code, .html_source, .text => {
            const lang: []const u8 = switch (meta.kind) {
                .html_source => "html",
                .code => meta.source_lang orelse "",
                else => "",
            };
            l.doc = try md.parse(gpa, try fenced(a, lang, c.bytes), .{});
        },
    }
    return l;
}

/// `body` as one fenced code block (the fence longer than any backtick
/// run inside).
fn fenced(a: Allocator, lang: []const u8, body: []const u8) ![]const u8 {
    var longest: usize = 0;
    var run: usize = 0;
    for (body) |ch| {
        run = if (ch == '`') run + 1 else 0;
        longest = @max(longest, run);
    }
    const n = @max(3, longest + 1);
    const fence = try a.alloc(u8, n);
    @memset(fence, '`');
    const nl: []const u8 = if (body.len > 0 and body[body.len - 1] != '\n') "\n" else "";
    return std.fmt.allocPrint(a, "{s}{s}\n{s}{s}{s}\n", .{ fence, lang, body, nl, fence });
}

/// UI thread: installs a finished load (unless it was overtaken).
fn deliver(ctx: *anyopaque, app: *App) void {
    const job: *Job = @ptrCast(@alignCast(ctx));
    const v = job.pane;
    defer v.gpa.destroy(job);
    v.inflight -= 1;
    if (job.gen != v.gen) {
        if (job.loaded) |l| l.destroy();
        return;
    }
    if (job.loaded) |l| {
        install(v, l) catch |e| {
            l.destroy();
            v.phase = .failed;
            v.err = e;
            app.notifyEntity(v.entity);
            return;
        };
        if (v.loaded) |old| old.destroy();
        v.loaded = l;
        v.phase = .ready;
    } else {
        v.phase = .failed;
        v.err = job.err;
    }
    app.notifyEntity(v.entity);
}

fn install(v: *ArtifactPane, l: *Loaded) !void {
    if (l.doc) |*d| l.md_state = .init(v.gpa, d);
    if (l.ds) |ds| {
        l.columns = try l.arena.allocator().alloc(virtual.Column, ds.columns.len);
        for (l.columns, ds.columns, 0..) |*col, name, i| col.* = .{ .id = @intCast(i), .title = name, .width = 120 };
        l.table = .init(v.gpa, .{ .ptr = l, .vtable = &Loaded.table_vtable }, .{ .columns = l.columns, .label = "Table", .test_id = "artifact-table" });
    }
    if (l.content.kind == .image) if (v.p.images) |cache| {
        if (!std.mem.eql(u8, l.content.ext, "svg")) {
            l.image = try cache.request(.{ .bytes = try v.gpa.dupe(u8, l.content.bytes) }, 800);
            l.images = cache;
        }
    };
}

// ---- view ----

pub fn artifactPane(ui: *Ui, v: *ArtifactPane) void {
    v.poll();
    ui.cx().observe(v.entity);
    const th = ui.theme();
    ui.open(.{ .role = .group, .label = "Artifact", .test_id = "artifact-pane", .style = .{ .dir = .column, .gap = th.dim(.space_sm), .padding = .all(th.dim(.space_sm)), .grow = 1 } });
    defer ui.close();
    const m = v.meta orelse {
        ui.text(if (v.phase == .failed) "This artifact is gone." else "No artifact open.", .{ .color = .fg_muted });
        return;
    };
    header(ui, v, &m);
    if (v.notice) |n| {
        ui.open(.{ .role = .status, .label = n, .test_id = "artifact-notice" });
        ui.text(n, .{ .color = .fg_muted });
        ui.close();
    }
    if (v.confirm_external) {
        ui.open(.{ .role = .dialog, .label = "Open HTML outside zigguro", .test_id = "artifact-confirm", .style = .{ .dir = .column, .gap = 4, .padding = .all(th.dim(.space_sm)), .bg = .{ .token = .bg_elevated } } });
        ui.text("This opens the HTML in your browser, outside zigguro, where its scripts can run.", .{ .color = .warning });
        ui.open(.{ .style = .{ .dir = .row, .gap = 4 } });
        if (controls.button(ui, .{ .label = "Open in browser", .variant = .primary }).clicked) v.openExternally(true);
        if (controls.button(ui, .{ .label = "Cancel" }).clicked) v.confirm_external = false;
        ui.close();
        ui.close();
    }
    switch (v.phase) {
        .empty => {},
        .loading => {
            ui.open(.{ .role = .status, .label = "Loading", .test_id = "artifact-loading" });
            ui.text("Loading…", .{ .color = .fg_muted });
            ui.close();
        },
        .failed => ui.textf("Cannot show this version: {t}", .{v.err orelse error.Unknown}, .{ .color = .danger }),
        .ready => bodyView(ui, v, &m, v.loaded.?),
    }
}

fn kindLabel(k: artifacts.ArtifactKind) []const u8 {
    return switch (k) {
        .markdown => "Document",
        .table => "Table",
        .chart => "Chart",
        .diagram => "Diagram",
        .image => "Image",
        .html_source => "HTML",
        .code => "Code",
        .text => "Text",
    };
}

fn header(ui: *Ui, v: *ArtifactPane, m: *const Artifact) void {
    ui.open(.{ .style = .{ .dir = .row, .gap = 4, .align_items = .center } });
    defer ui.close();
    controls.badge(ui, kindLabel(m.kind));
    ui.text(m.title, .{ .wrap = false, .style = .{ .weight = 700 } });
    ui.open(.{ .style = .{ .grow = 1 } });
    ui.close();
    const s = v.shownVersion();
    const label = std.fmt.allocPrint(ui.arena(), "Version {d} of {d}", .{ s.n, s.of }) catch "Version";
    ui.open(.{ .role = .group, .label = label, .test_id = "artifact-versions", .style = .{ .dir = .row, .gap = 2, .align_items = .center } });
    if (controls.button(ui, .{ .label = "‹", .variant = .ghost, .disabled = s.n <= 1 }).clicked) v.step(-1);
    ui.textf("v{d}/{d}", .{ s.n, s.of }, .{ .wrap = false, .color = .fg_muted });
    if (controls.button(ui, .{ .label = "›", .variant = .ghost, .disabled = s.n >= s.of }).clicked) v.step(1);
    ui.close();
    const ready = v.phase == .ready;
    if (v.p.save != null) {
        if (controls.button(ui, .{ .label = "Save", .disabled = !ready }).clicked) v.saveShown();
    }
    if (v.p.copy != null and m.kind.isText()) {
        if (controls.button(ui, .{ .label = "Copy", .disabled = !ready }).clicked) v.copyShown();
    }
    if (v.p.open_external != null) {
        if (controls.button(ui, .{ .label = "Open externally", .disabled = !ready }).clicked) v.openExternally(false);
    }
    if (v.p.export_ != null and (m.kind == .chart or m.kind == .diagram)) {
        if (controls.button(ui, .{ .label = "Export SVG", .disabled = !ready }).clicked) v.exportShown("svg");
        if (controls.button(ui, .{ .label = "Export PNG", .disabled = !ready }).clicked) v.exportShown("png");
    }
}

fn bodyView(ui: *Ui, v: *ArtifactPane, m: *const Artifact, l: *Loaded) void {
    if (l.note) |n| ui.text(n, .{ .color = .fg_muted });
    if (v.version != null) if (m.version(v.version.?)) |ver| if (ver.note) |n| ui.textf("v{d}: {s}", .{ ver.n, n }, .{ .color = .fg_muted });
    switch (m.kind) {
        .table => {
            _ = l.cell_arena.reset(.retain_capacity);
            if (l.table) |*t| t.build(ui);
            return;
        },
        .image => {
            if (l.image) |h| {
                _ = zg_gui.image.view.imageView(ui, .{ .cache = l.images.?, .handle = h, .zoomable = true, .alt = m.title });
                return;
            }
            const ver = m.version(l.content.version);
            const w = if (ver) |x| x.width else 0;
            const h = if (ver) |x| x.height else 0;
            ui.open(.{ .role = .img, .label = m.title, .test_id = "artifact-image" });
            ui.textf("{s} image, {d}×{d}", .{ l.content.ext, w, h }, .{ .color = .fg_muted });
            ui.close();
            return;
        },
        .chart, .diagram => {
            const r = if (m.kind == .chart) v.p.chart else v.p.diagram;
            if (r) |x| {
                ui.open(.{ .style = .{ .dir = .column, .grow = 1 }, .test_id = "artifact-render" });
                x.build(x.ctx, ui, l.content.bytes);
                ui.close();
                return;
            }
        },
        else => {},
    }
    if (l.md_state) |*s| {
        _ = zg_gui.w.scroll.scrollArea(ui, .{ .test_id = "artifact-body" });
        md.view(ui, s, .{ .highlighter = v.p.highlighter, .test_id = "artifact-md" });
        ui.close();
    }
}
