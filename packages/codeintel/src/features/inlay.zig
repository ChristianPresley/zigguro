//! Inlay hints (E07.F03.S02.T03): `textDocument/inlayHint` for the lines
//! an editor shows plus one screen above and below, asked `debounce_ms`
//! after the view settles. Lines already answered for the document's
//! current version are covered and not asked again while scrolling; an
//! edit maps the cached hints through the change (hints whose anchor was
//! edited away are dropped) and asks the visible lines again.
//!
//! Hints are resolved (`inlayHint/resolve`) when hovered, for their
//! tooltip and label part details; `workspace/inlayHint/refresh` forgets
//! what the server's documents covered and asks the visible ones again.
//! `editor.inlayHints.enabled` decides whether hints show (`shown`):
//! always, never, or while Ctrl+Alt is held (or released).

const InlayService = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const requester = @import("request.zig");
const oneshot = @import("oneshot.zig");
const position = @import("position.zig");

const Allocator = std.mem.Allocator;
const protocol = zg_lsp.protocol;
const Client = zg_lsp.client.Client;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const Document = zg_editor.model.document.Document;
const ByteRange = position.ByteRange;
const Req = requester.Requester(.@"textDocument/inlayHint", .inlay_hint);
const Resolve = oneshot.Oneshot(.@"inlayHint/resolve", InlayId);

/// Identifies a hint across edits and answers.
pub const InlayId = u64;

/// Lines `[first, end)`.
pub const LineRange = struct { first: u64, end: u64 };

pub const Mode = enum { on, off, on_unless_pressed, off_unless_pressed };

/// A place a label part points at (Ctrl+click goes there).
pub const Location = struct {
    uri: []const u8,
    range: protocol.Range,
    enc: position.Encoding,
};

pub const Part = struct {
    text: []const u8,
    location: ?Location = null,
    /// The part's command, as JSON (`protocol.Command`).
    command: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
};

pub const Hint = struct {
    id: InlayId,
    /// The anchor, in the document's current version.
    offset: u64,
    /// The whole label (parts joined).
    label: []const u8,
    parts: []const Part,
    kind: ?protocol.InlayHintKind = null,
    pad_left: bool = false,
    pad_right: bool = false,
    tooltip: ?[]const u8 = null,
    /// The hint as the server sent it, for `inlayHint/resolve`; null once
    /// resolved (or when the server cannot resolve).
    raw: ?[]const u8 = null,
    client: *Client,
};

pub const Options = struct {
    debounce_ms: u64 = 100,
    mode: Mode = .on,
};

const Entry = struct {
    /// Owns the hints' strings.
    arena: std.heap.ArenaAllocator,
    hints: std.ArrayList(Hint) = .empty,
    /// The version `hints` and `covered` are for.
    version: u64,
    /// Lines answered at `version`, sorted and disjoint.
    covered: std.ArrayList(LineRange) = .empty,
    /// What the editor shows (null: not shown).
    visible: ?LineRange = null,
    due_ms: ?u64 = null,

    fn deinit(e: *Entry, gpa: Allocator) void {
        e.hints.deinit(gpa);
        e.covered.deinit(gpa);
        e.arena.deinit();
    }
};

gpa: Allocator,
mgr: *Manager,
req: Req,
resolve_req: Resolve,
opts: Options,
entries: std.AutoHashMapUnmanaged(DocHandle, Entry) = .empty,
/// The request in flight: its document, lines and version.
inflight: ?struct { h: DocHandle, lines: LineRange, version: u64, cleared: bool = false } = null,
pressed: bool = false,
next_id: InlayId = 1,
/// Bumped when any document's hints (or `shown`) change.
generation: u64 = 0,
/// Requests sent (tests, the bench).
sent: u32 = 0,

/// `s` must not move once initialized (refresh listener).
pub fn init(s: *InlayService, mgr: *Manager, waker: zg_core.runtime.Waker, opts: Options) Allocator.Error!void {
    s.* = .{ .gpa = mgr.gpa, .mgr = mgr, .req = .init(mgr, waker), .resolve_req = .init(mgr.gpa, mgr.rt.io, waker), .opts = opts };
    try mgr.onRefresh(.{ .ctx = s, .func = onRefreshHook });
}

/// Call after `Manager.deinit`.
pub fn deinit(s: *InlayService) void {
    s.req.deinit();
    s.resolve_req.deinit();
    var it = s.entries.valueIterator();
    while (it.next()) |e| e.deinit(s.gpa);
    s.entries.deinit(s.gpa);
}

pub fn setMode(s: *InlayService, mode: Mode) void {
    if (s.opts.mode == mode) return;
    const was = s.shown();
    s.opts.mode = mode;
    if (s.shown() != was) s.generation += 1;
}

/// Ctrl+Alt went down or up.
pub fn setPressed(s: *InlayService, on: bool) void {
    if (s.pressed == on) return;
    const was = s.shown();
    s.pressed = on;
    if (s.shown() != was) s.generation += 1;
}

/// Whether hints are drawn now.
pub fn shown(s: *const InlayService) bool {
    return switch (s.opts.mode) {
        .on => true,
        .off => false,
        .on_unless_pressed => !s.pressed,
        .off_unless_pressed => s.pressed,
    };
}

/// Lines `[first, end)` of `h` are on screen. Cheap when they are
/// already covered (scrolling calls it every frame).
pub fn onViewport(s: *InlayService, h: DocHandle, visible: LineRange, now_ms: u64) Allocator.Error!void {
    const doc = s.mgr.docs.get(h) orelse return;
    const gop = try s.entries.getOrPut(s.gpa, h);
    if (!gop.found_existing) gop.value_ptr.* = .{ .arena = .init(s.gpa), .version = doc.version };
    const e = gop.value_ptr;
    s.sync(e, doc);
    e.visible = visible;
    if (s.opts.mode == .off or covers(e.covered.items, visible)) {
        e.due_ms = null;
        return;
    }
    if (s.inflight) |f| if (std.meta.eql(f.h, h) and f.version == doc.version and contains(f.lines, visible)) return;
    // Scrolling keeps pushing the request back until the view rests.
    e.due_ms = now_ms + s.opts.debounce_ms;
}

/// `h` is no longer shown (its hints stay cached).
pub fn hide(s: *InlayService, h: DocHandle) void {
    const e = s.entries.getPtr(h) orelse return;
    e.visible = null;
    e.due_ms = null;
}

/// Forgets `h` (it closed).
pub fn forget(s: *InlayService, h: DocHandle) void {
    if (s.entries.fetchRemove(h)) |kv| {
        var e = kv.value;
        e.deinit(s.gpa);
        s.generation += 1;
    }
    if (s.inflight) |f| if (std.meta.eql(f.h, h)) {
        s.req.cancel();
        s.inflight = null;
    };
}

/// `workspace/inlayHint/refresh` from `server`: its documents' hints are
/// stale; the visible ones are asked again at once.
pub fn onRefresh(s: *InlayService, server: *Manager.Server) void {
    const c = server.client orelse return;
    var it = s.entries.valueIterator();
    while (it.next()) |e| {
        const from_it = for (e.hints.items) |x| {
            if (x.client == c) break true;
        } else e.hints.items.len == 0;
        if (!from_it) continue;
        e.covered.clearRetainingCapacity();
        // Not visible: asked when it is shown again.
        if (e.visible != null) e.due_ms = 0;
    }
    if (s.inflight != null) {
        s.req.cancel();
        s.inflight = null;
    }
}

fn onRefreshHook(ctx: *anyopaque, server: *Manager.Server, f: Manager.RefreshFeature) void {
    const s: *InlayService = @ptrCast(@alignCast(ctx));
    if (f == .inlay_hint) s.onRefresh(server);
}

pub fn nextDue(s: *const InlayService) ?u64 {
    if (s.inflight != null) return null;
    var best: ?u64 = null;
    var it = s.entries.valueIterator();
    while (it.next()) |e| if (e.due_ms) |d| {
        best = if (best) |b| @min(b, d) else d;
    };
    return best;
}

/// The hints of `h` in its current version, by offset.
pub fn hints(s: *InlayService, h: DocHandle) []const Hint {
    const e = s.entries.getPtr(h) orelse return &.{};
    const doc = s.mgr.docs.get(h) orelse return &.{};
    s.sync(e, doc);
    return e.hints.items;
}

/// The hint anchored at `offset` of `h`, if any.
pub fn hintAt(s: *InlayService, h: DocHandle, offset: u64) ?*const Hint {
    for (s.hints(h)) |*x| if (x.offset == offset) return x;
    return null;
}

/// Where Ctrl+click on part `part` of hint `id` goes, if anywhere.
pub fn partLocation(s: *InlayService, h: DocHandle, id: InlayId, part: usize) ?Location {
    for (s.hints(h)) |x| if (x.id == id) {
        if (part >= x.parts.len) return null;
        return x.parts[part].location;
    };
    return null;
}

/// The command of part `part` of hint `id` (JSON), if any.
pub fn partCommand(s: *InlayService, h: DocHandle, id: InlayId, part: usize) ?[]const u8 {
    for (s.hints(h)) |x| if (x.id == id) {
        if (part >= x.parts.len) return null;
        return x.parts[part].command;
    };
    return null;
}

/// Asks the server for the details of hint `id` of `h` (hovered); the
/// answer fills its tooltip and parts in `tick`.
pub fn resolve(s: *InlayService, h: DocHandle, id: InlayId) !void {
    const e = s.entries.getPtr(h) orelse return;
    for (e.hints.items) |*x| if (x.id == id) {
        const raw = x.raw orelse return;
        if (!canResolve(x.client)) {
            x.raw = null;
            return;
        }
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const hint = try std.json.parseFromSliceLeaky(protocol.InlayHint, arena.allocator(), raw, .{ .ignore_unknown_fields = true });
        try s.resolve_req.send(x.client, hint, .{}, id);
        // Asked once.
        x.raw = null;
        return;
    };
}

fn canResolve(c: *Client) bool {
    const caps = c.caps() orelse return false;
    const p = caps.raw.inlayHintProvider orelse return false;
    return switch (p) {
        .boolean => false,
        .inlay_hint_options => |o| o.resolveProvider orelse false,
        .inlay_hint_registration_options => |o| o.resolveProvider orelse false,
    };
}

/// Takes answers and sends a due request; true when hints changed.
pub fn tick(s: *InlayService, now_ms: u64) bool {
    const g = s.generation;
    if (s.inflight) |f| {
        for (s.req.take()) |a| s.onAnswer(a);
        if (s.req.done()) {
            if (s.entries.getPtr(f.h)) |e| {
                const doc = s.mgr.docs.get(f.h);
                if (doc != null and doc.?.version == f.version and e.version == f.version) addCovered(s.gpa, &e.covered, f.lines) catch {};
            }
            s.inflight = null;
        }
    }
    for (s.resolve_req.take()) |a| s.onResolved(a);
    if (s.inflight == null and s.opts.mode != .off) s.sendDue(now_ms);
    return s.generation != g;
}

fn sendDue(s: *InlayService, now_ms: u64) void {
    var it = s.entries.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr;
        const due = e.due_ms orelse continue;
        if (now_ms < due) continue;
        e.due_ms = null;
        const vis = e.visible orelse continue;
        const h = kv.key_ptr.*;
        const doc = s.mgr.docs.get(h) orelse continue;
        s.sync(e, doc);
        const lines = want(vis, doc.tree.lineCount());
        const start = doc.tree.lineStart(lines.first);
        const end = if (lines.end >= doc.tree.lineCount()) doc.len() else doc.tree.lineStart(lines.end);
        const n = s.req.askRange(h, .{ .start = start, .end = end }, .{}) catch 0;
        if (n == 0) continue;
        s.sent += 1;
        s.inflight = .{ .h = h, .lines = lines, .version = doc.version };
        return;
    }
}

/// The lines asked for `visible`: one screen above and below.
fn want(visible: LineRange, lines: u64) LineRange {
    const screen = @max(visible.end -| visible.first, 1);
    return .{ .first = visible.first -| screen, .end = @min(visible.end + screen, @max(lines, 1)) };
}

fn contains(outer: LineRange, inner: LineRange) bool {
    return inner.first >= outer.first and inner.end <= outer.end;
}

fn covers(set: []const LineRange, r: LineRange) bool {
    for (set) |c| if (contains(c, r)) return true;
    return false;
}

/// Adds `r` to the sorted disjoint `set`, merging what it touches.
pub fn addCovered(gpa: Allocator, set: *std.ArrayList(LineRange), r: LineRange) Allocator.Error!void {
    var merged = r;
    var i: usize = 0;
    while (i < set.items.len) {
        const c = set.items[i];
        if (c.end < merged.first or c.first > merged.end) {
            i += 1;
            continue;
        }
        merged = .{ .first = @min(c.first, merged.first), .end = @max(c.end, merged.end) };
        _ = set.orderedRemove(i);
    }
    var at: usize = 0;
    while (at < set.items.len and set.items[at].first < merged.first) at += 1;
    try set.insert(gpa, at, merged);
}

/// Brings `e` to the document's version: hints move with the edits (an
/// edited-away anchor drops its hint) and nothing is covered any more.
fn sync(s: *InlayService, e: *Entry, doc: *const Document) void {
    if (e.version == doc.version) return;
    var keep: usize = 0;
    for (e.hints.items) |x| {
        const r = position.mapResultRange(doc, e.version, .{ .start = x.offset, .end = x.offset }, .drop) orelse continue;
        var y = x;
        y.offset = r.start;
        e.hints.items[keep] = y;
        keep += 1;
    }
    e.hints.shrinkRetainingCapacity(keep);
    e.version = doc.version;
    e.covered.clearRetainingCapacity();
    if (e.visible != null and e.due_ms == null) e.due_ms = 0;
    s.generation += 1;
}

fn onAnswer(s: *InlayService, a: *const Req.Answer) void {
    if (s.inflight == null) return;
    const fl = &s.inflight.?;
    const doc = s.mgr.docs.get(a.h) orelse return;
    const e = s.entries.getPtr(a.h) orelse return;
    // Offsets are only meaningful in the text they were computed for.
    if (a.version != doc.version) {
        if (e.visible != null) e.due_ms = 0;
        return;
    }
    s.sync(e, doc);
    const v = switch (a.result) {
        .ok => |o| o.value orelse &.{},
        else => return,
    };
    const start = doc.tree.lineStart(fl.lines.first);
    const end = if (fl.lines.end >= doc.tree.lineCount()) doc.len() + 1 else doc.tree.lineStart(fl.lines.end);
    s.merge(e, doc, a.client, v, .{ .start = start, .end = end }, !fl.cleared) catch return;
    fl.cleared = true;
    s.generation += 1;
}

/// Replaces the hints in bytes `range` (when `clear`; the first answer of
/// a round) and adds `got`. The entry's strings move to a fresh arena so
/// replaced hints do not pile up.
fn merge(s: *InlayService, e: *Entry, doc: *const Document, c: *Client, got: []const protocol.InlayHint, range: ByteRange, clear: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList(Hint) = .empty;
    errdefer list.deinit(s.gpa);
    for (e.hints.items) |x| {
        if (clear and x.offset >= range.start and x.offset < range.end) continue;
        try list.append(s.gpa, try copyHint(a, x));
    }
    var m: position.Mapper = .{ .gpa = s.gpa, .tree = &doc.tree, .enc = position.encodingOf(c.encoding()) };
    defer m.deinit();
    const resolvable = canResolve(c);
    for (got) |x| {
        const off = m.byteOf(x.position) catch continue;
        if (off > doc.len()) continue;
        try list.append(s.gpa, try s.fromProtocol(a, c, x, off, resolvable));
    }
    std.sort.block(Hint, list.items, {}, struct {
        fn lt(_: void, p: Hint, q: Hint) bool {
            return p.offset < q.offset;
        }
    }.lt);
    e.hints.deinit(s.gpa);
    e.arena.deinit();
    e.hints = list;
    e.arena = arena;
}

fn copyHint(a: Allocator, x: Hint) !Hint {
    var y = x;
    y.label = try a.dupe(u8, x.label);
    const parts = try a.alloc(Part, x.parts.len);
    for (x.parts, parts) |p, *q| q.* = .{
        .text = try a.dupe(u8, p.text),
        .location = if (p.location) |l| .{ .uri = try a.dupe(u8, l.uri), .range = l.range, .enc = l.enc } else null,
        .command = if (p.command) |t| try a.dupe(u8, t) else null,
        .tooltip = if (p.tooltip) |t| try a.dupe(u8, t) else null,
    };
    y.parts = parts;
    y.tooltip = if (x.tooltip) |t| try a.dupe(u8, t) else null;
    y.raw = if (x.raw) |t| try a.dupe(u8, t) else null;
    return y;
}

fn tooltipText(t: anytype) []const u8 {
    return switch (t) {
        .string => |x| x,
        .markup_content => |m| m.value,
    };
}

fn fromProtocol(s: *InlayService, a: Allocator, c: *Client, x: protocol.InlayHint, off: u64, resolvable: bool) !Hint {
    var label: std.ArrayList(u8) = .empty;
    const parts: []Part = switch (x.label) {
        .string => |t| blk: {
            try label.appendSlice(a, t);
            const ps = try a.alloc(Part, 1);
            ps[0] = .{ .text = try a.dupe(u8, t) };
            break :blk ps;
        },
        .inlay_hint_label_part_array => |arr| blk: {
            const ps = try a.alloc(Part, arr.len);
            for (arr, ps) |p, *q| {
                try label.appendSlice(a, p.value);
                q.* = try partOf(a, c, p);
            }
            break :blk ps;
        },
    };
    const id = s.next_id;
    s.next_id += 1;
    return .{
        .id = id,
        .offset = off,
        .label = label.items,
        .parts = parts,
        .kind = x.kind,
        .pad_left = x.paddingLeft orelse false,
        .pad_right = x.paddingRight orelse false,
        .tooltip = if (x.tooltip) |t| try a.dupe(u8, tooltipText(t)) else null,
        .raw = if (resolvable) try std.json.Stringify.valueAlloc(a, x, .{}) else null,
        .client = c,
    };
}

fn partOf(a: Allocator, c: *Client, p: protocol.InlayHintLabelPart) !Part {
    return .{
        .text = try a.dupe(u8, p.value),
        .location = if (p.location) |l| .{ .uri = try a.dupe(u8, l.uri), .range = l.range, .enc = position.encodingOf(c.encoding()) } else null,
        .command = if (p.command) |cmd| try std.json.Stringify.valueAlloc(a, cmd, .{}) else null,
        .tooltip = if (p.tooltip) |t| try a.dupe(u8, tooltipText(t)) else null,
    };
}

fn onResolved(s: *InlayService, a: *const Resolve.Answer) void {
    const got = switch (a.result) {
        .ok => |o| o.value,
        else => return,
    };
    var it = s.entries.valueIterator();
    while (it.next()) |e| for (e.hints.items) |*x| if (x.id == a.tag) {
        const ar = e.arena.allocator();
        if (got.tooltip) |t| x.tooltip = ar.dupe(u8, tooltipText(t)) catch x.tooltip;
        switch (got.label) {
            .inlay_hint_label_part_array => |arr| if (arr.len == x.parts.len) {
                const ps = ar.alloc(Part, arr.len) catch return;
                for (arr, ps) |p, *q| q.* = partOf(ar, a.client, p) catch return;
                x.parts = ps;
            },
            .string => {},
        }
        s.generation += 1;
        return;
    };
}
