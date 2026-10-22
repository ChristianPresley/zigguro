//! Layout persistence (E04.F07.S03.T01): the dock layout, window geometry,
//! panel states and small UI state as a versioned ZON file, written
//! atomically off the UI thread and read back before the first frame.
//!
//! - `fromModel` copies a `DockModel` into a `LayoutFile` (UI thread);
//!   `save` serializes it and replaces `layout.zon` atomically (a worker);
//!   `load` reads it, migrating older versions, and `toModel` builds the
//!   model again. The schema is in packages/gui/docs/layout-schema.md.
//! - Panel kinds are stored by name (`Kinds`). A kind the app no longer
//!   knows becomes a `placeholder_kind` panel that keeps its name and state,
//!   so saving again writes it back unchanged.
//! - A file that does not parse is renamed `layout.zon.bad-<unix seconds>`
//!   and the caller uses its defaults; a file from a newer version is left
//!   alone. Files above `max_file_bytes` are refused, and panel states
//!   above `max_state_bytes` are dropped with a warning.
//! - `Persister` debounces saves: `markDirty` arms a window timer, and when
//!   it fires the layout is snapshotted and written on a worker. Saves run
//!   one at a time and an older snapshot never replaces a newer one.
//!   `saveNow` writes synchronously (window close, quit).
//!
//! One process owns the file: the workspace lock (E08) keeps a second
//! process away; without it the last writer wins.

const std = @import("std");
const model = @import("model.zig");
const app_mod = @import("../core/app.zig");
const window_mod = @import("../core/window.zig");
const ui_state = @import("../core/ui_state.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const DockModel = model.DockModel;
const PanelKindId = model.PanelKindId;
const log = std.log.scoped(.layout);

/// The version `save` writes.
pub const schema_version: u32 = 1;
/// The file's name in the layout directory.
pub const file_name = "layout.zon";
/// Larger files are not read or written.
pub const max_file_bytes = 4 << 20;
/// Larger panel states are dropped.
pub const max_state_bytes = 64 << 10;
/// The kind of a panel whose kind the app does not know.
pub const placeholder_kind: PanelKindId = std.math.maxInt(u32);

/// A small UI state entry (MRU lists, collapsed sections, ...).
pub const KV = ui_state.KV;

/// A tree node.
pub const NodeRec = union(enum) { group: u32, split: u32 };

/// A panel: its kind by name and its opaque, panel-defined state.
pub const PanelRecord = struct { ref: u32, kind: []const u8, state: []const u8 = "" };

/// A tab group.
pub const GroupRec = struct { id: u32, tabs: []const u32 = &.{}, active: u32 = 0, pinned: u32 = 0, preview: ?u32 = null };

/// A split.
pub const SplitRec = struct { id: u32, axis: model.Axis, children: []const NodeRec, ratios: []const f32 };

/// An area (in `model.Area` order).
pub const AreaRec = struct { root: ?NodeRec = null, visible: bool = true, size: f32 = 240 };

/// A floating window (logical pixels).
pub const FloatRec = struct { id: u32, rect: [4]f32, monitor: []const u8 = "", scale: f32 = 1, root: ?NodeRec = null };

/// An OS window's geometry (physical pixels; the position may be unknown).
pub const WindowLayout = struct { id: []const u8, rect: [4]i32 = .{ 0, 0, 0, 0 }, monitor: []const u8 = "", scale: f32 = 1, maximized: bool = false };

/// The file. New fields get defaults, so older files still parse; a field
/// is never removed without a migration.
pub const LayoutFile = struct {
    version: u32 = schema_version,
    windows: []const WindowLayout = &.{},
    panels: []const PanelRecord = &.{},
    groups: []const GroupRec = &.{},
    splits: []const SplitRec = &.{},
    areas: [5]AreaRec = @splat(.{}),
    floating: []const FloatRec = &.{},
    maximized: ?u32 = null,
    focused: ?u32 = null,
    next_id: u32 = 1,
    ui_state: []const KV = &.{},
};

/// Panel kinds by name.
pub const Kinds = struct {
    ctx: ?*anyopaque = null,
    /// The name of an app kind (null: not saved, and its tabs are left
    /// out of their groups).
    name: *const fn (ctx: ?*anyopaque, kind: PanelKindId) ?[]const u8,
    /// The kind of a name (null: unknown, kept as a placeholder).
    id: *const fn (ctx: ?*anyopaque, name: []const u8) ?PanelKindId,
};

// -- model <-> file ---------------------------------------------------------

fn nodeRec(n: model.Node) NodeRec {
    return switch (n) {
        .group => |g| .{ .group = @intFromEnum(g) },
        .split => |s| .{ .split = @intFromEnum(s) },
    };
}

fn nodeOf(n: NodeRec) model.Node {
    return switch (n) {
        .group => |g| .{ .group = @enumFromInt(g) },
        .split => |s| .{ .split = @enumFromInt(s) },
    };
}

/// A placeholder's state: the kind name, a 0 byte, the original state.
fn placeholderState(a: Allocator, kind: []const u8, state: []const u8) Allocator.Error![]u8 {
    const out = try a.alloc(u8, kind.len + 1 + state.len);
    @memcpy(out[0..kind.len], kind);
    out[kind.len] = 0;
    @memcpy(out[kind.len + 1 ..], state);
    return out;
}

/// The layout of `m` (allocated in `arena`), with `windows` and `ui`.
pub fn fromModel(arena: Allocator, m: *const DockModel, kinds: Kinds, windows: []const WindowLayout, ui: []const KV) Allocator.Error!LayoutFile {
    var panels: std.ArrayList(PanelRecord) = .empty;
    for (m.panels.keys(), m.panels.values()) |ref, p| {
        var kind: []const u8 = undefined;
        var state: []const u8 = p.state orelse "";
        if (p.kind == placeholder_kind) {
            const z = std.mem.indexOfScalar(u8, state, 0) orelse continue;
            kind = state[0..z];
            state = state[z + 1 ..];
        } else kind = kinds.name(kinds.ctx, p.kind) orelse continue;
        if (state.len > max_state_bytes) {
            log.warn("panel {d} ({s}): state of {d} bytes not saved", .{ @intFromEnum(ref), kind, state.len });
            state = "";
        }
        try panels.append(arena, .{ .ref = @intFromEnum(ref), .kind = kind, .state = state });
    }
    // Tabs of panels not saved are left out of their groups.
    var saved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (panels.items) |p| try saved.put(arena, p.ref, {});
    const groups = try arena.alloc(GroupRec, m.groups.count());
    for (m.groups.keys(), m.groups.values(), groups) |id, g, *o| {
        var tabs: std.ArrayList(u32) = .empty;
        var active: u32 = 0;
        var pinned: u32 = 0;
        for (g.tabs.items, 0..) |t, i| {
            const ref = @intFromEnum(t);
            if (!saved.contains(ref)) continue;
            if (i == g.active) active = @intCast(tabs.items.len);
            if (i < g.pinned) pinned += 1;
            try tabs.append(arena, ref);
        }
        const preview: ?u32 = if (g.preview) |p| if (saved.contains(@intFromEnum(p))) @intFromEnum(p) else null else null;
        o.* = .{ .id = @intFromEnum(id), .tabs = tabs.items, .active = active, .pinned = pinned, .preview = preview };
    }
    const splits = try arena.alloc(SplitRec, m.splits.count());
    for (m.splits.keys(), m.splits.values(), splits) |id, s, *o| {
        const kids = try arena.alloc(NodeRec, s.children.items.len);
        for (s.children.items, kids) |c, *x| x.* = nodeRec(c);
        o.* = .{ .id = @intFromEnum(id), .axis = s.axis, .children = kids, .ratios = try arena.dupe(f32, s.ratios.items) };
    }
    var areas: [5]AreaRec = undefined;
    for (m.areas, &areas) |a, *o| o.* = .{ .root = if (a.root) |r| nodeRec(r) else null, .visible = a.visible, .size = a.size };
    const floating = try arena.alloc(FloatRec, m.floating.items.len);
    for (m.floating.items, floating) |f, *o| o.* = .{
        .id = @intFromEnum(f.id),
        .rect = .{ f.rect.x, f.rect.y, f.rect.w, f.rect.h },
        .monitor = try arena.dupe(u8, f.monitor.get()),
        .scale = f.scale,
        .root = if (f.root) |r| nodeRec(r) else null,
    };
    return .{
        .windows = try arena.dupe(WindowLayout, windows),
        .panels = panels.items,
        .groups = groups,
        .splits = splits,
        .areas = areas,
        .floating = floating,
        .maximized = if (m.maximized) |g| @intFromEnum(g) else null,
        .focused = if (m.focused) |g| @intFromEnum(g) else null,
        .next_id = m.next_id,
        .ui_state = try arena.dupe(KV, ui),
    };
}

/// The model `f` describes. Unknown kinds become placeholders; a layout
/// that breaks the model's invariants is `error.Invalid`.
pub fn toModel(gpa: Allocator, f: *const LayoutFile, kinds: Kinds) (Allocator.Error || error{Invalid})!DockModel {
    var m: DockModel = .{ .gpa = gpa };
    errdefer m.deinit();
    m.history = false;
    var max_id: u32 = 0;
    for (f.panels) |p| {
        if (p.ref == 0) return error.Invalid;
        max_id = @max(max_id, p.ref);
        const kind = kinds.id(kinds.ctx, p.kind);
        const state: ?[]u8 = if (kind != null)
            (if (p.state.len > 0) try gpa.dupe(u8, p.state) else null)
        else
            try placeholderState(gpa, p.kind, p.state);
        errdefer if (state) |s| gpa.free(s);
        const gop = try m.panels.getOrPut(gpa, @enumFromInt(p.ref));
        if (gop.found_existing) return error.Invalid;
        gop.value_ptr.* = .{ .kind = kind orelse placeholder_kind, .state = state };
    }

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const groups = try a.alloc(model.Snapshot.GroupSnap, f.groups.len);
    for (f.groups, groups) |g, *o| {
        const tabs = try a.alloc(model.PanelRef, g.tabs.len);
        for (g.tabs, tabs) |t, *x| x.* = @enumFromInt(t);
        o.* = .{ .id = @enumFromInt(g.id), .tabs = tabs, .active = g.active, .pinned = g.pinned, .preview = if (g.preview) |p| @enumFromInt(p) else null };
        max_id = @max(max_id, g.id);
    }
    const splits = try a.alloc(model.Snapshot.SplitSnap, f.splits.len);
    for (f.splits, splits) |s, *o| {
        if (s.children.len != s.ratios.len) return error.Invalid;
        const kids = try a.alloc(model.Node, s.children.len);
        for (s.children, kids) |c, *x| x.* = nodeOf(c);
        o.* = .{ .id = @enumFromInt(s.id), .axis = s.axis, .children = kids, .ratios = s.ratios };
        max_id = @max(max_id, s.id);
    }
    var areas: [5]model.AreaState = undefined;
    for (f.areas, &areas) |r, *o| o.* = .{ .root = if (r.root) |n| nodeOf(n) else null, .visible = r.visible, .size = if (std.math.isFinite(r.size)) @max(0, r.size) else 240 };
    const floating = try a.alloc(model.Floating, f.floating.len);
    for (f.floating, floating) |r, *o| {
        o.* = .{ .id = @enumFromInt(r.id), .rect = .{ .x = r.rect[0], .y = r.rect[1], .w = r.rect[2], .h = r.rect[3] }, .scale = r.scale, .root = if (r.root) |n| nodeOf(n) else null };
        o.monitor.set(r.monitor);
        max_id = @max(max_id, r.id);
    }
    // Every node must exist, and only once.
    try checkTrees(a, f);
    var snap: model.Snapshot = .{ .arena = arena, .groups = groups, .splits = splits, .areas = areas, .floating = floating, .maximized = if (f.maximized) |g| @enumFromInt(g) else null };
    defer snap.deinit();
    m.focused = if (f.focused) |g| @enumFromInt(g) else null;
    try m.restore(&snap);
    if (m.areas[@intFromEnum(model.Area.center)].root == null) return error.Invalid;
    m.next_id = @max(f.next_id, max_id + 1);
    m.validate() catch return error.Invalid;
    m.history = true;
    return m;
}

/// Each node referenced once, and each reference resolves.
fn checkTrees(a: Allocator, f: *const LayoutFile) (Allocator.Error || error{Invalid})!void {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    const Walk = struct {
        fn node(fl: *const LayoutFile, s: *std.AutoHashMapUnmanaged(u64, void), al: Allocator, n: NodeRec, depth: u32) (Allocator.Error || error{Invalid})!void {
            if (depth > 64) return error.Invalid;
            const key: u64 = switch (n) {
                .group => |g| @as(u64, g),
                .split => |sp| (1 << 32) | @as(u64, sp),
            };
            if ((try s.getOrPut(al, key)).found_existing) return error.Invalid;
            switch (n) {
                .group => |g| for (fl.groups) |x| {
                    if (x.id == g) break;
                } else return error.Invalid,
                .split => |sp| for (fl.splits) |x| {
                    if (x.id == sp) {
                        for (x.children) |c| try node(fl, s, al, c, depth + 1);
                        break;
                    }
                } else return error.Invalid,
            }
        }
    };
    for (f.areas) |r| if (r.root) |n| try Walk.node(f, &seen, a, n, 0);
    for (f.floating) |r| if (r.root) |n| try Walk.node(f, &seen, a, n, 0);
}

// -- files --------------------------------------------------------------------

/// `f` as ZON text.
pub fn serialize(gpa: Allocator, f: *const LayoutFile) Allocator.Error![]u8 {
    var w: Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    std.zon.stringify.serialize(f.*, .{}, &w.writer) catch return error.OutOfMemory;
    w.writer.writeByte('\n') catch return error.OutOfMemory;
    return w.toOwnedSlice();
}

pub const SaveError = error{ FileTooBig, Injected } || Allocator.Error || Io.Dir.CreateFileAtomicError || Io.File.Writer.Error || Io.File.Atomic.ReplaceError;

/// Test hook: the write fails after this many bytes.
pub const Fault = struct { fail_after: ?usize = null };

/// Writes `f` to `dir`/`layout.zon` atomically.
pub fn save(gpa: Allocator, io: Io, dir: Io.Dir, f: *const LayoutFile) SaveError!void {
    const text = try serialize(gpa, f);
    defer gpa.free(text);
    return saveText(io, dir, text, .{});
}

/// Writes `text` to `dir`/`layout.zon` atomically: the old file stays
/// until the new one is complete.
pub fn saveText(io: Io, dir: Io.Dir, text: []const u8, fault: Fault) SaveError!void {
    if (text.len > max_file_bytes) return error.FileTooBig;
    var af = try dir.createFileAtomic(io, file_name, .{ .replace = true });
    defer af.deinit(io);
    var buf: [8192]u8 = undefined;
    var w = af.file.writer(io, &buf);
    if (fault.fail_after) |n| {
        w.interface.writeAll(text[0..@min(n, text.len)]) catch return error.Injected;
        w.interface.flush() catch {};
        return error.Injected;
    }
    w.interface.writeAll(text) catch return w.err orelse error.Injected;
    w.interface.flush() catch return w.err orelse error.Injected;
    try af.replace(io);
}

/// A parsed file and the memory it lives in.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    file: LayoutFile,

    pub fn deinit(l: *Loaded) void {
        l.arena.deinit();
    }
};

/// What `load` found.
pub const LoadResult = union(enum) {
    ok: Loaded,
    /// Read from an older version.
    migrated: Loaded,
    /// No file: use the defaults.
    missing,
    /// It did not parse: renamed to `renamed_to`; use the defaults.
    corrupt: struct { buf: [48]u8 = undefined, len: u8 = 0 },
    /// Written by a newer version: left alone; use the defaults.
    too_new: u32,

    pub fn renamedTo(r: *const LoadResult) []const u8 {
        return switch (r.*) {
            .corrupt => |*c| c.buf[0..c.len],
            else => "",
        };
    }

    pub fn deinit(r: *LoadResult) void {
        switch (r.*) {
            .ok, .migrated => |*l| l.deinit(),
            else => {},
        }
    }
};

/// Rewrites a version's text as the next version's.
pub const Migration = *const fn (gpa: Allocator, old: []const u8) anyerror![]u8;
/// Index = from-version (v0 → v1 first).
pub const migrations = [_]Migration{migrateV0};

/// The `.version` field near the start of `text`; 0 when absent.
pub fn scanVersion(text: []const u8) u32 {
    const head = text[0..@min(text.len, 256)];
    const at = std.mem.indexOf(u8, head, ".version") orelse return 0;
    var i = at + ".version".len;
    while (i < head.len and (head[i] == ' ' or head[i] == '=' or head[i] == '\t')) i += 1;
    var v: u32 = 0;
    while (i < head.len and std.ascii.isDigit(head[i])) : (i += 1) v = v *| 10 +| (head[i] - '0');
    return v;
}

/// Reads `dir`/`layout.zon` (see `LoadResult`).
pub fn load(gpa: Allocator, io: Io, dir: Io.Dir) LoadResult {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const a = arena.allocator();
    const raw = dir.readFileAlloc(io, file_name, a, .limited(max_file_bytes + 1)) catch |e| {
        arena.deinit();
        return switch (e) {
            error.FileNotFound => .missing,
            else => corrupt(io, dir),
        };
    };
    var text: []const u8 = raw;
    const from = scanVersion(text);
    if (from > schema_version) {
        arena.deinit();
        return .{ .too_new = from };
    }
    var v = from;
    while (v < schema_version) : (v += 1) {
        text = migrations[v](a, text) catch {
            arena.deinit();
            return corrupt(io, dir);
        };
    }
    const src = a.dupeZ(u8, text) catch {
        arena.deinit();
        return corrupt(io, dir);
    };
    const file = std.zon.parse.fromSliceAlloc(LayoutFile, a, src, null, .{ .ignore_unknown_fields = true }) catch {
        arena.deinit();
        return corrupt(io, dir);
    };
    const l: Loaded = .{ .arena = arena, .file = file };
    return if (from < schema_version) .{ .migrated = l } else .{ .ok = l };
}

fn corrupt(io: Io, dir: Io.Dir) LoadResult {
    var r: LoadResult = .{ .corrupt = .{} };
    const secs = @divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s);
    const name = std.fmt.bufPrint(&r.corrupt.buf, file_name ++ ".bad-{d}", .{secs}) catch return r;
    r.corrupt.len = @intCast(name.len);
    dir.rename(file_name, dir, name, io) catch |e| log.warn("could not set the bad layout aside: {t}", .{e});
    log.warn("the saved layout did not parse; it was renamed {s} and the default layout is used", .{name});
    return r;
}

/// Version 0: no `.version` and no `.next_id` (ids are taken from the
/// largest one in use).
const V0 = struct {
    windows: []const WindowLayout = &.{},
    panels: []const PanelRecord = &.{},
    groups: []const GroupRec = &.{},
    splits: []const SplitRec = &.{},
    areas: [5]AreaRec = @splat(.{}),
    floating: []const FloatRec = &.{},
    maximized: ?u32 = null,
    focused: ?u32 = null,
    ui_state: []const KV = &.{},
};

fn migrateV0(gpa: Allocator, old: []const u8) anyerror![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const v0 = try std.zon.parse.fromSliceAlloc(V0, a, try a.dupeZ(u8, old), null, .{ .ignore_unknown_fields = true });
    var max_id: u32 = 0;
    for (v0.panels) |p| max_id = @max(max_id, p.ref);
    for (v0.groups) |g| max_id = @max(max_id, g.id);
    for (v0.splits) |s| max_id = @max(max_id, s.id);
    for (v0.floating) |f| max_id = @max(max_id, f.id);
    const v1: LayoutFile = .{
        .version = 1,
        .windows = v0.windows,
        .panels = v0.panels,
        .groups = v0.groups,
        .splits = v0.splits,
        .areas = v0.areas,
        .floating = v0.floating,
        .maximized = v0.maximized,
        .focused = v0.focused,
        .next_id = max_id + 1,
        .ui_state = v0.ui_state,
    };
    return serialize(gpa, &v1);
}

// -- debounced saving ---------------------------------------------------------

/// See the module doc. Must not move once used.
pub const Persister = struct {
    gpa: Allocator,
    io: Io,
    app: *app_mod.App,
    /// Where `layout.zon` goes (borrowed).
    dir: Io.Dir,
    source: Source,
    debounce_ms: u64 = 1000,
    /// The window whose timer runs the debounce.
    win: ?*window_mod.Window = null,
    timer: window_mod.Window.TimerId = .none,
    /// Serializes writes; guards `written`.
    mutex: Io.Mutex = .init,
    /// The newest snapshot written.
    written: u64 = 0,
    /// Snapshots taken.
    taken: u64 = 0,
    /// Saves on workers not finished.
    in_flight: std.atomic.Value(u32) = .init(0),
    /// Saves completed (tests).
    saves: std.atomic.Value(u32) = .init(0),

    /// Fills a `LayoutFile` (UI thread, allocated in `arena`).
    pub const Source = struct {
        ctx: *anyopaque,
        snapshot: *const fn (ctx: *anyopaque, arena: Allocator) anyerror!LayoutFile,
    };

    /// Waits for saves on workers.
    pub fn deinit(p: *Persister) void {
        if (p.win) |w| if (p.timer != .none) w.cancelTimer(p.timer);
        p.timer = .none;
        while (p.in_flight.load(.acquire) > 0) {
            _ = p.app.drainMessages();
            p.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }

    /// The layout changed: saves within `debounce_ms` (changes meanwhile
    /// go in the same save).
    pub fn markDirty(p: *Persister) void {
        if (p.timer != .none) return;
        const w = p.win orelse return;
        p.timer = w.setTimer(p.app.now_ms + p.debounce_ms, .{ .ctx = p, .f = onTimer }) catch .none;
    }

    fn onTimer(ctx: *anyopaque, _: *window_mod.Window) void {
        const p: *Persister = @ptrCast(@alignCast(ctx));
        p.timer = .none;
        p.saveAsync() catch |e| log.warn("layout not saved: {t}", .{e});
    }

    const Job = struct {
        p: *Persister,
        arena: std.heap.ArenaAllocator,
        file: LayoutFile = undefined,
        seq: u64,

        fn run(j: *Job) void {
            const p = j.p;
            defer {
                j.arena.deinit();
                p.gpa.destroy(j);
                _ = p.in_flight.fetchSub(1, .release);
            }
            p.write(j.seq, &j.file);
        }
    };

    /// Snapshots now and writes on a worker.
    pub fn saveAsync(p: *Persister) !void {
        const j = try p.gpa.create(Job);
        j.* = .{ .p = p, .arena = .init(p.gpa), .seq = 0 };
        errdefer {
            j.arena.deinit();
            p.gpa.destroy(j);
        }
        j.file = try p.source.snapshot(p.source.ctx, j.arena.allocator());
        p.taken += 1;
        j.seq = p.taken;
        _ = p.in_flight.fetchAdd(1, .acquire);
        p.app.spawn(Job.run, .{j});
    }

    /// Snapshots and writes now (window close, quit).
    pub fn saveNow(p: *Persister) !void {
        if (p.win) |w| if (p.timer != .none) w.cancelTimer(p.timer);
        p.timer = .none;
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        const file = try p.source.snapshot(p.source.ctx, arena.allocator());
        p.taken += 1;
        p.write(p.taken, &file);
    }

    fn write(p: *Persister, seq: u64, file: *const LayoutFile) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        if (seq <= p.written) return;
        save(p.gpa, p.io, p.dir, file) catch |e| {
            log.warn("layout not saved: {t}", .{e});
            return;
        };
        p.written = seq;
        _ = p.saves.fetchAdd(1, .release);
    }
};
