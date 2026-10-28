//! Breakpoints in the editor (E07.F06.S03.T01): the `LineHost` that keeps
//! the breakpoint manager's lines attached to the text through edits, and
//! the gutter marks it draws.
//!
//! - Each tracked breakpoint holds a zero-width decoration at its line
//!   start (owner `dap.breakpoints.anchor`, `point_right`: a line
//!   inserted at the very start of the line pushes the breakpoint down
//!   with its code, as in VS Code). Deleting the line collapses the
//!   anchor onto the merged line, which keeps the breakpoint there;
//!   `flush` moves such an anchor back to its line start.
//! - Decoration stores are UI-thread only, while the manager asks for
//!   lines from any thread. So `track` and `untrack` are queued and
//!   applied by `flush` (once per frame, on the UI thread), which also
//!   caches every tracked line for `line`.
//! - `flush` redraws a document's marks when the manager changed or the
//!   document was edited: the breakpoint glyphs (owner
//!   `dap.breakpoints`, see zg_dap's decorate.zig) and the execution
//!   pointer (owner `dap.exec`: an arrow and a line highlight for the top
//!   frame, a lighter highlight for a selected frame below it).

const BreakpointGutter = @This();
const std = @import("std");
const zg_editor = @import("zg_editor");
const zg_dap = @import("zg_dap");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const BreakpointManager = zg_dap.breakpoints.BreakpointManager;
const decorate = zg_dap.breakpoints.decorate;
const Document = zg_editor.model.document.Document;
const deco = zg_editor.model.decorations.store;
const DecorationStore = deco.DecorationStore;
const Decoration = deco.Decoration;
const DecorationId = deco.DecorationId;
const StyleRef = deco.StyleRef;

pub const owner_anchor = "dap.breakpoints.anchor";

pub const Styles = struct {
    /// The breakpoint lane in the gutter (the editor's lane 0, with the
    /// diagnostics; lane 1 is the lightbulb's).
    lane: u8 = 0,
    /// Icon per `decorate.Glyph` (breakpoint, conditional, logpoint,
    /// hit_count, disabled).
    icons: [5]u32 = .{ 0x25CF, 0x229C, 0x25C6, 0x25CE, 0x25CB },
    /// Unverified while a session runs.
    hollow_icon: u32 = 0x25CB,
    enabled: StyleRef,
    disabled: StyleRef,
    unverified: StyleRef,
    warning: StyleRef,
    /// Nothing is drawn for anchors; any style.
    anchor: StyleRef,
    exec_arrow_icon: u32 = 0x27A4,
    exec_top: StyleRef,
    exec_selected: StyleRef,
    /// The arrow's colour (null: `exec_top`'s), as the line highlight is
    /// usually a faded one.
    exec_arrow: ?StyleRef = null,
};

const Doc = struct {
    path: []u8,
    doc: *const Document,
    store: *DecorationStore,
    anchor_owner: deco.OwnerId,
    mark_owner: deco.OwnerId,
    exec_owner: deco.OwnerId,
    /// The version the marks were drawn at.
    drawn_version: ?u64 = null,
    /// Unsaved changes, as of the last `flush`.
    dirty: bool = false,
};

const Track = struct {
    /// Owned.
    path: []u8,
    /// 1-based; the requested line until applied, then the cached one.
    line: u32,
    id: ?DecorationId = null,
    state: enum { pending, live, closed, dropped } = .pending,
};

gpa: Allocator,
io: Io,
styles: Styles,
bpm: ?*BreakpointManager = null,
/// Guards `tracks` (the manager calls in from any thread).
mutex: Io.Mutex = .init,
tracks: std.ArrayList(Track) = .empty,
/// Free `tracks` slots.
free: std.ArrayList(u32) = .empty,
/// Untracked while their document is attached: removed by `flush`.
removals: std.ArrayList(struct { store: *DecorationStore, id: DecorationId }) = .empty,
/// Changed on the UI thread under `mutex`; read by the host under it.
docs: std.ArrayList(Doc) = .empty,
/// The manager changed since the last `flush`.
model_dirty: std.atomic.Value(bool) = .init(true),
top: ?decorate.FramePos = null,
selected: ?decorate.FramePos = null,
exec_paths: [2][]u8 = .{ &.{}, &.{} },
exec_dirty: bool = false,
scratch: std.ArrayList(Decoration) = .empty,
/// Mark rebuilds (tests).
redraws: u32 = 0,

pub fn init(gpa: Allocator, io: Io, styles: Styles) BreakpointGutter {
    return .{ .gpa = gpa, .io = io, .styles = styles };
}

pub fn deinit(g: *BreakpointGutter) void {
    for (g.tracks.items) |t| g.gpa.free(t.path);
    g.tracks.deinit(g.gpa);
    g.free.deinit(g.gpa);
    g.removals.deinit(g.gpa);
    for (g.docs.items) |d| g.gpa.free(d.path);
    g.docs.deinit(g.gpa);
    for (g.exec_paths) |p| g.gpa.free(p);
    g.scratch.deinit(g.gpa);
}

/// The host for `BreakpointManager.Options.host`.
pub fn host(g: *BreakpointGutter) BreakpointManager.LineHost {
    return .{ .ctx = g, .track = track, .line = line, .untrack = untrack, .dirty = dirty };
}

/// Draws `m`'s breakpoints; `g` must not move.
pub fn bind(g: *BreakpointGutter, m: *BreakpointManager) Allocator.Error!void {
    g.bpm = m;
    try m.subscribe(.{ .ctx = g, .func = onModel });
}

fn onModel(ctx: ?*anyopaque, _: BreakpointManager.Change) void {
    const g: *BreakpointGutter = @ptrCast(@alignCast(ctx.?));
    g.model_dirty.store(true, .release);
}

fn lock(g: *BreakpointGutter) void {
    g.mutex.lockUncancelable(g.io);
}

fn unlock(g: *BreakpointGutter) void {
    g.mutex.unlock(g.io);
}

fn findDoc(g: *BreakpointGutter, path: []const u8) ?*Doc {
    for (g.docs.items) |*d| if (std.mem.eql(u8, d.path, path)) return d;
    return null;
}

// ---------------------------------------------------------------------
// Documents (UI thread).

/// `path` opened in `doc`, decorated through `store` (subscribed to the
/// document before any edit). Call the manager's `docOpened` after.
pub fn attach(g: *BreakpointGutter, path: []const u8, doc: *const Document, store: *DecorationStore) Allocator.Error!void {
    const anchor = store.ownerByName(owner_anchor) orelse try store.registerOwner(owner_anchor, 0);
    const marks = store.ownerByName(decorate.owner_breakpoints) orelse try store.registerOwner(decorate.owner_breakpoints, 20);
    const exec = store.ownerByName(decorate.owner_exec) orelse try store.registerOwner(decorate.owner_exec, 21);
    const p = try g.gpa.dupe(u8, path);
    errdefer g.gpa.free(p);
    g.lock();
    defer g.unlock();
    try g.docs.append(g.gpa, .{ .path = p, .doc = doc, .store = store, .anchor_owner = anchor, .mark_owner = marks, .exec_owner = exec, .dirty = doc.isDirty() });
    g.model_dirty.store(true, .release);
}

/// Whether `path` is attached (UI thread).
pub fn attached(g: *BreakpointGutter, path: []const u8) bool {
    return g.findDoc(path) != null;
}

/// `path` closes. Call the manager's `docClosed` before (it reads the
/// lines one last time).
pub fn detach(g: *BreakpointGutter, path: []const u8) void {
    g.flush();
    for (g.docs.items, 0..) |d, i| if (std.mem.eql(u8, d.path, path)) {
        d.store.clearOwner(d.anchor_owner);
        d.store.clearOwner(d.mark_owner);
        d.store.clearOwner(d.exec_owner);
        g.lock();
        for (g.tracks.items) |*t| if (t.state == .live and std.mem.eql(u8, t.path, path)) {
            t.state = .closed;
            t.id = null;
        };
        // Removals for this store are moot now.
        var k: usize = 0;
        while (k < g.removals.items.len) {
            if (g.removals.items[k].store == d.store) _ = g.removals.swapRemove(k) else k += 1;
        }
        g.gpa.free(d.path);
        _ = g.docs.swapRemove(i);
        g.unlock();
        return;
    };
}

/// `path` was saved: refreshes the cached lines, then re-sends its
/// breakpoints (UI thread).
pub fn saved(g: *BreakpointGutter, path: []const u8) void {
    g.flush();
    if (g.bpm) |m| m.documentSaved(path);
}

/// `path` was edited (UI thread).
pub fn edited(g: *BreakpointGutter, path: []const u8) void {
    g.flush();
    if (g.bpm) |m| m.documentEdited(path);
}

/// The execution pointer: the top frame and the selected frame (null
/// when the session is not stopped).
pub fn setExec(g: *BreakpointGutter, top: ?decorate.FramePos, selected: ?decorate.FramePos) Allocator.Error!void {
    const old = g.exec_paths;
    const t: []u8 = if (top) |x| try g.gpa.dupe(u8, x.path) else &.{};
    errdefer g.gpa.free(t);
    const s: []u8 = if (selected) |x| try g.gpa.dupe(u8, x.path) else &.{};
    g.exec_paths = .{ t, s };
    g.top = if (top) |x| .{ .path = t, .line = x.line } else null;
    g.selected = if (selected) |x| .{ .path = s, .line = x.line } else null;
    for (old) |p| g.gpa.free(p);
    g.exec_dirty = true;
}

/// Applies queued tracking, refreshes the cached lines and redraws what
/// changed. Once per frame, on the UI thread.
pub fn flush(g: *BreakpointGutter) void {
    g.lock();
    for (g.removals.items) |r| r.store.remove(r.id);
    g.removals.clearRetainingCapacity();
    for (g.tracks.items) |*t| switch (t.state) {
        .pending => {
            const d = g.findDoc(t.path) orelse {
                t.state = .closed;
                continue;
            };
            const tree = &d.doc.tree;
            const l = @min(@as(u64, t.line -| 1), tree.lineCount() -| 1);
            const at = tree.lineStart(l);
            t.id = d.store.add(.{ .range = .{ .start = at, .end = at }, .owner = d.anchor_owner, .stick = .point_right, .kind = .{ .text_style = g.styles.anchor } }) catch null;
            t.state = if (t.id != null) .live else .closed;
        },
        .live => {
            const d = g.findDoc(t.path) orelse continue;
            const r = d.store.get(t.id.?) orelse continue;
            const l = d.doc.tree.lineOf(r.range.start);
            t.line = @intCast(l + 1);
            // After a merge the anchor sits inside the line: move it back
            // to the line start, so it behaves like any other.
            const at = d.doc.tree.lineStart(l);
            if (r.range.start != at) {
                d.store.remove(t.id.?);
                t.id = d.store.add(.{ .range = .{ .start = at, .end = at }, .owner = d.anchor_owner, .stick = .point_right, .kind = .{ .text_style = g.styles.anchor } }) catch null;
                if (t.id == null) t.state = .closed;
            }
        },
        else => {},
    };
    for (g.docs.items) |*d| d.dirty = d.doc.isDirty();
    g.unlock();
    const model = g.model_dirty.swap(false, .acq_rel);
    for (g.docs.items) |*d| {
        if (model or d.drawn_version != d.doc.version) g.drawMarks(d) catch {};
        if (g.exec_dirty or d.drawn_version != d.doc.version) g.drawExec(d) catch {};
        d.drawn_version = d.doc.version;
    }
    g.exec_dirty = false;
}

fn drawMarks(g: *BreakpointGutter, d: *Doc) Allocator.Error!void {
    const m = g.bpm orelse return;
    var arena: std.heap.ArenaAllocator = .init(g.gpa);
    defer arena.deinit();
    const marks = try decorate.marks(m, arena.allocator(), d.path);
    g.scratch.clearRetainingCapacity();
    const tree = &d.doc.tree;
    const st = g.styles;
    for (marks) |mk| {
        const l = @min(@as(u64, mk.line -| 1), tree.lineCount() -| 1);
        const at = tree.lineStart(l);
        const icon = if (mk.hollow) st.hollow_icon else st.icons[@intFromEnum(mk.glyph)];
        const style = if (mk.glyph == .disabled) st.disabled else if (mk.warning) st.warning else if (mk.hollow) st.unverified else st.enabled;
        try g.scratch.append(g.gpa, .{
            .range = .{ .start = at, .end = at },
            .owner = d.mark_owner,
            .stick = .point_right,
            .kind = .{ .gutter = .{ .lane = st.lane, .icon = icon, .style = style } },
            .hover = @intFromEnum(mk.id),
        });
    }
    g.redraws += 1;
    try d.store.setOwnerDecorations(d.mark_owner, d.store.version, g.scratch.items);
}

fn drawExec(g: *BreakpointGutter, d: *Doc) Allocator.Error!void {
    var buf: [2]decorate.ExecMark = undefined;
    const ex = decorate.execMarks(d.path, g.top, g.selected, &buf);
    g.scratch.clearRetainingCapacity();
    const tree = &d.doc.tree;
    for (ex) |e| {
        const l = @min(@as(u64, e.line -| 1), tree.lineCount() -| 1);
        const at = tree.lineStart(l);
        const end = if (l + 1 < tree.lineCount()) tree.lineStart(l + 1) else d.doc.len();
        const style = if (e.style == .top) g.styles.exec_top else g.styles.exec_selected;
        try g.scratch.append(g.gpa, .{ .range = .{ .start = at, .end = end }, .owner = d.exec_owner, .kind = .{ .highlight = style } });
        if (e.style == .top) try g.scratch.append(g.gpa, .{
            .range = .{ .start = at, .end = at },
            .owner = d.exec_owner,
            .stick = .point_right,
            .kind = .{ .gutter = .{ .lane = g.styles.lane, .icon = g.styles.exec_arrow_icon, .style = g.styles.exec_arrow orelse style } },
        });
    }
    try d.store.setOwnerDecorations(d.exec_owner, d.store.version, g.scratch.items);
}

// ---------------------------------------------------------------------
// The host (any thread).

fn track(ctx: ?*anyopaque, path: []const u8, l: u32) ?u64 {
    const g: *BreakpointGutter = @ptrCast(@alignCast(ctx.?));
    g.lock();
    defer g.unlock();
    // Only open documents are tracked; `docs` changes on the UI thread,
    // which also attaches before the manager's `docOpened`.
    if (g.findDoc(path) == null) return null;
    const p = g.gpa.dupe(u8, path) catch return null;
    const t: Track = .{ .path = p, .line = l };
    if (g.free.pop()) |i| {
        g.tracks.items[i] = t;
        return i;
    }
    g.tracks.append(g.gpa, t) catch {
        g.gpa.free(p);
        return null;
    };
    return g.tracks.items.len - 1;
}

fn line(ctx: ?*anyopaque, h: u64) ?u32 {
    const g: *BreakpointGutter = @ptrCast(@alignCast(ctx.?));
    g.lock();
    defer g.unlock();
    const t = g.tracks.items[@intCast(h)];
    return switch (t.state) {
        .pending, .live => t.line,
        .closed, .dropped => null,
    };
}

fn untrack(ctx: ?*anyopaque, h: u64) void {
    const g: *BreakpointGutter = @ptrCast(@alignCast(ctx.?));
    g.lock();
    defer g.unlock();
    const t = &g.tracks.items[@intCast(h)];
    if (t.state == .live) if (g.findDoc(t.path)) |d| {
        g.removals.append(g.gpa, .{ .store = d.store, .id = t.id.? }) catch {};
    };
    g.gpa.free(t.path);
    t.* = .{ .path = &.{}, .line = 0, .state = .dropped };
    g.free.append(g.gpa, @intCast(h)) catch {};
}

fn dirty(ctx: ?*anyopaque, path: []const u8) bool {
    const g: *BreakpointGutter = @ptrCast(@alignCast(ctx.?));
    g.lock();
    defer g.unlock();
    const d = g.findDoc(path) orelse return false;
    return d.dirty;
}
