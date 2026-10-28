//! A snippet editing session (E07.F03.S01.T05): the expansion inserted
//! at every cursor, its tab stops followed through edits, Tab and
//! Shift+Tab between them.
//!
//! Activating a stop selects every range of its index at every cursor,
//! mirrors included, so typing edits them all at once as one undo step
//! (the editor's multi-cursor typing). Mirrors with a transform are not
//! selected: they are rewritten through the transform when the stop is
//! left. Ranges follow edits with the active stop growing at both edges
//! and the others keeping clear of it; a stop whose text was typed over
//! as part of an enclosing placeholder is skipped.
//!
//! The session ends at `$0`, on Escape (`end`), when an edit lands
//! outside every stop, on undo or redo, or when the caret leaves every
//! stop (`cursorMoved`). `Stack` nests sessions: a snippet expanded
//! inside an active one runs first, then the outer one carries on.

const Session = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_editor = @import("zg_editor");
const Snippet = @import("Snippet.zig");

const EditorView = zg_editor.view.EditorView;
const document = zg_editor.model.document;
const Range = zg_editor.model.buffer.piece_tree.Range;
const Replace = zg_editor.model.edit.change_set.Replace;
const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
const Selection = zg_editor.model.edit.selection.Selection;

/// The stop being edited.
pub const ActiveStop = struct {
    index: u32,
    /// One per cursor (mirrors left out).
    ranges: []const Range,
    choice: ?[]const []const u8,
};

const Stop = struct {
    index: u32,
    cursor: u32,
    range: Range,
    choice: ?[]const []const u8,
    mirror: bool,
    transform: ?*const Snippet.Transform,
    /// `StopRange.seq`: tells apart touching and nested stops.
    seq: u32,
    /// Typed over as part of an enclosing placeholder.
    dead: bool = false,
};

gpa: Allocator,
view: *EditorView,
listener: ?document.ListenerId = null,
stops: std.ArrayList(Stop) = .empty,
/// Distinct indices in visiting order.
order: std.ArrayList(u32) = .empty,
/// Position in `order` of the active stop.
pos: usize = 0,
done: bool = false,
/// The session's own edits are not checked against the stops.
own_edit: bool = false,
scratch: std.ArrayList(Range) = .empty,

/// Inserts `exp` over every range of `at` (one per cursor) as one undo
/// step and activates the first stop. The session may be `done` at once
/// (a snippet with only `$0`). `exp` is only read during the call;
/// transforms it points at must outlive the session.
pub fn begin(gpa: Allocator, view: *EditorView, at: []const Range, exp: *const Snippet.Expansion) !*Session {
    return beginWith(gpa, view, at, exp, &.{});
}

/// `begin` with `extra` edits (clear of every insertion point) made in
/// the same undo step: a completion's additional text edits.
pub fn beginWith(gpa: Allocator, view: *EditorView, at: []const Range, exp: *const Snippet.Expansion, extra: []const Replace) !*Session {
    const s = try gpa.create(Session);
    errdefer gpa.destroy(s);
    s.* = .{ .gpa = gpa, .view = view };
    errdefer s.deinitFields();

    // Insertion points in order (their cursor index), then every edit in
    // order; each lands shifted by the ones before.
    const sorted = try gpa.dupe(Range, at);
    defer gpa.free(sorted);
    std.mem.sort(Range, sorted, {}, struct {
        fn lt(_: void, a: Range, b: Range) bool {
            return a.start < b.start;
        }
    }.lt);
    const Ins = struct { edit: Replace, cursor: ?u32 };
    const all = try gpa.alloc(Ins, sorted.len + extra.len);
    defer gpa.free(all);
    for (sorted, 0..) |r, ci| all[ci] = .{ .edit = .{ .range = r, .text = exp.text.items }, .cursor = @intCast(ci) };
    for (extra, sorted.len..) |e, i| all[i] = .{ .edit = e, .cursor = null };
    std.mem.sort(Ins, all, {}, struct {
        fn lt(_: void, a: Ins, b: Ins) bool {
            return a.edit.range.start < b.edit.range.start;
        }
    }.lt);
    const edits = try gpa.alloc(Replace, all.len);
    defer gpa.free(edits);
    for (all, edits) |x, *e| e.* = x.edit;
    s.own_edit = true;
    try view.applyEdits(edits);
    s.own_edit = false;
    var delta: i128 = 0;
    for (all) |x| {
        const r = x.edit.range;
        const base: u64 = @intCast(@as(i128, r.start) + delta);
        delta += @as(i128, x.edit.text.len) - @as(i128, r.end - r.start);
        const ci = x.cursor orelse continue;
        for (exp.stops.items) |st| try s.stops.append(gpa, .{
            .index = st.index,
            .cursor = ci,
            .range = .{ .start = base + st.start, .end = base + st.end },
            .choice = st.choice,
            .mirror = st.mirror_of != null,
            .transform = st.transform,
            .seq = st.seq,
        });
    }
    for (exp.stops.items) |st| {
        if (s.order.items.len == 0 or s.order.items[s.order.items.len - 1] != st.index) {
            if (std.mem.indexOfScalar(u32, s.order.items, st.index) == null) try s.order.append(gpa, st.index);
        }
    }
    s.listener = try view.doc.subscribe(.{ .ctx = s, .onChange = onChange });
    try s.activate(0);
    return s;
}

fn deinitFields(s: *Session) void {
    if (s.listener) |l| s.view.doc.unsubscribe(l);
    s.listener = null;
    s.stops.deinit(s.gpa);
    s.order.deinit(s.gpa);
    s.scratch.deinit(s.gpa);
}

pub fn destroy(s: *Session) void {
    s.deinitFields();
    s.gpa.destroy(s);
}

/// Selects stop `order[pos]` (the first live one from there in `dir`),
/// or ends at `$0`.
fn activate(s: *Session, from: usize) anyerror!void {
    var p = from;
    while (p < s.order.items.len and !s.live(s.order.items[p])) p += 1;
    if (p >= s.order.items.len) return s.finish();
    s.pos = p;
    const index = s.order.items[p];
    var sels: std.ArrayList(Selection) = .empty;
    defer sels.deinit(s.gpa);
    var primary: usize = 0;
    for (s.stops.items) |st| if (st.index == index and st.transform == null and !st.dead) {
        if (st.cursor == 0 and !st.mirror) primary = sels.items.len;
        try sels.append(s.gpa, .{ .anchor = st.range.start, .head = st.range.end });
    };
    if (sels.items.len == 0) return s.finish();
    try s.view.setSelections(sels.items, primary);
    if (index == 0) s.finishAt();
}

fn live(s: *const Session, index: u32) bool {
    for (s.stops.items) |st| if (st.index == index and !st.dead and st.transform == null) return true;
    return false;
}

/// At `$0` (selected): the session is over.
fn finishAt(s: *Session) void {
    s.done = true;
    if (s.listener) |l| s.view.doc.unsubscribe(l);
    s.listener = null;
}

/// Puts the carets at `$0` and ends.
fn finish(s: *Session) anyerror!void {
    if (s.done) return;
    for (s.order.items, 0..) |ix, p| if (ix == 0) {
        s.pos = p;
        return s.activate(p);
    };
    s.finishAt();
}

/// Tab: leaves the active stop for the next; false when the session
/// ended (at `$0`).
pub fn next(s: *Session) !bool {
    if (s.done) return false;
    try s.leave();
    try s.activate(s.pos + 1);
    return !s.done;
}

/// Shift+Tab: the previous stop; false at the first.
pub fn prev(s: *Session) !bool {
    if (s.done) return false;
    var p = s.pos;
    while (p > 0) {
        p -= 1;
        if (s.order.items[p] != 0 and s.live(s.order.items[p])) {
            try s.leave();
            try s.activate(p);
            return true;
        }
    }
    return false;
}

/// Escape (or anything that ends it): transformed mirrors are written,
/// the selections stay.
pub fn end(s: *Session) void {
    if (s.done) return;
    s.leave() catch {};
    s.finishAt();
}

/// The stop being edited, until the next call.
pub fn active(s: *Session) ?ActiveStop {
    if (s.done) return null;
    const index = s.order.items[s.pos];
    s.scratch.clearRetainingCapacity();
    var choice: ?[]const []const u8 = null;
    for (s.stops.items) |st| if (st.index == index and !st.mirror and st.transform == null) {
        s.scratch.append(s.gpa, st.range) catch return null;
        if (st.choice) |c| choice = c;
    };
    return .{ .index = index, .ranges = s.scratch.items, .choice = choice };
}

/// Replaces the active stop's text with `text` everywhere (a choice).
pub fn choose(s: *Session, text: []const u8) !void {
    if (s.done) return;
    const index = s.order.items[s.pos];
    var edits: std.ArrayList(Replace) = .empty;
    defer edits.deinit(s.gpa);
    for (s.stops.items) |st| if (st.index == index and st.transform == null and !st.dead) {
        try edits.append(s.gpa, .{ .range = st.range, .text = text });
    };
    s.own_edit = true;
    defer s.own_edit = false;
    try s.view.applyEdits(edits.items);
    try s.activate(s.pos);
}

/// Writes the active stop's text through each transformed mirror.
fn leave(s: *Session) !void {
    const index = s.order.items[s.pos];
    var edits: std.ArrayList(Replace) = .empty;
    defer edits.deinit(s.gpa);
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    for (s.stops.items) |st| if (st.index == index and st.transform != null and !st.dead) {
        const src = s.primaryText(index, st.cursor) orelse continue;
        var out: std.ArrayList(u8) = .empty;
        try Snippet.applyTransform(arena.allocator(), st.transform.?, src, &out);
        if (std.mem.eql(u8, out.items, s.view.text(st.range))) continue;
        try edits.append(s.gpa, .{ .range = st.range, .text = out.items });
    };
    if (edits.items.len == 0) return;
    s.own_edit = true;
    defer s.own_edit = false;
    try s.view.applyEdits(edits.items);
}

fn primaryText(s: *Session, index: u32, cursor: u32) ?[]const u8 {
    for (s.stops.items) |st| if (st.index == index and st.cursor == cursor and !st.mirror and st.transform == null) return s.view.text(st.range);
    return null;
}

/// The caret moved: the session ends when the primary caret is outside
/// every stop.
pub fn cursorMoved(s: *Session) void {
    if (s.done) return;
    const h = s.view.primarySel().head;
    for (s.stops.items) |st| if (!st.dead and h >= st.range.start and h <= st.range.end) return;
    s.end();
}

fn onChange(ctx: *anyopaque, ev: *const document.ChangeEvent) void {
    const s: *Session = @ptrCast(@alignCast(ctx));
    if (s.done) return;
    if (ev.origin == .undo or ev.origin == .redo) return s.finishAt();
    const cs = ev.changes;
    if (!s.own_edit) {
        // Edits outside every stop end the session.
        for (cs.replaces) |rep| {
            var inside = false;
            for (s.stops.items) |st| if (!st.dead and rep.range.start >= st.range.start and rep.range.end <= st.range.end) {
                inside = true;
                break;
            };
            if (!inside) return s.finishAt();
        }
    }
    const index = s.order.items[s.pos];
    // The session's own edits replace whole stops: everything grows.
    if (s.own_edit) {
        for (s.stops.items) |*st| {
            const r = st.range;
            const a = cs.mapPos(r.start, .left);
            st.range = .{ .start = a, .end = @max(a, cs.mapPos(r.end, .right)) };
        }
        return;
    }
    // The active stop at each cursor, in old coordinates.
    var act_buf: [64]?Stop = @splat(null);
    for (s.stops.items) |st| if (st.index == index and !st.mirror and st.transform == null and st.cursor < act_buf.len) {
        act_buf[st.cursor] = st;
    };
    for (s.stops.items) |*st| {
        const r = st.range;
        const is_active = st.index == index and st.transform == null;
        if (is_active) {
            st.range = .{ .start = cs.mapPos(r.start, .left), .end = cs.mapPos(r.end, .right) };
            continue;
        }
        for (cs.replaces) |rep| {
            if (rep.range.end > rep.range.start and rep.range.start <= r.start and r.end <= rep.range.end) {
                st.dead = true;
                break;
            }
        }
        const bias = biasFor(st.*, if (st.cursor < act_buf.len) act_buf[st.cursor] else null);
        const a = cs.mapPos(r.start, bias[0]);
        st.range = .{ .start = a, .end = @max(a, cs.mapPos(r.end, bias[1])) };
    }
}

/// How a stop's edges follow an edit, given the active stop: an
/// enclosing stop grows, a nested one keeps inside, one before stays
/// left and one after moves right.
fn biasFor(st: Stop, active_stop: ?Stop) [2]zg_editor.model.edit.change_set.Bias {
    const a = (active_stop orelse return .{ .left, .right }).range;
    const sa = active_stop.?.seq;
    const r = st.range;
    if (r.start <= a.start and a.end <= r.end and st.seq > sa) return .{ .left, .right };
    if (a.start <= r.start and r.end <= a.end and sa > st.seq) return .{ .right, .left };
    if (r.end <= a.start and (r.start < a.start or st.seq < sa)) return .{ .left, .left };
    if (r.start >= a.end and (r.end > a.end or st.seq > sa)) return .{ .right, .right };
    return .{ .left, .right };
}

/// Nested sessions: the innermost is edited; when it ends, the one it
/// was started in carries on.
pub const Stack = struct {
    gpa: Allocator,
    items: std.ArrayList(*Session) = .empty,

    pub fn init(gpa: Allocator) Stack {
        return .{ .gpa = gpa };
    }

    pub fn deinit(st: *Stack) void {
        for (st.items.items) |x| x.destroy();
        st.items.deinit(st.gpa);
    }

    /// The innermost running session.
    pub fn top(st: *Stack) ?*Session {
        st.prune();
        return if (st.items.items.len > 0) st.items.items[st.items.items.len - 1] else null;
    }

    /// Drops finished sessions from the top.
    fn prune(st: *Stack) void {
        while (st.items.items.len > 0 and st.items.items[st.items.items.len - 1].done) st.items.pop().?.destroy();
    }

    /// Expands `exp` at `at` (inside the running session, if any).
    pub fn begin(st: *Stack, view: *EditorView, at: []const Range, exp: *const Snippet.Expansion) !void {
        return st.beginWith(view, at, exp, &.{});
    }

    /// `begin` with `extra` edits in the same undo step (`beginWith`).
    pub fn beginWith(st: *Stack, view: *EditorView, at: []const Range, exp: *const Snippet.Expansion, extra: []const Replace) !void {
        // A snippet in another editor ends the sessions of this one.
        if (st.items.items.len > 0 and st.items.items[0].view != view) st.endAll();
        const s = try Session.beginWith(st.gpa, view, at, exp, extra);
        if (s.done) return s.destroy();
        st.items.append(st.gpa, s) catch |e| {
            s.destroy();
            return e;
        };
    }

    /// Tab: true when a session took it.
    pub fn next(st: *Stack) !bool {
        const s = st.top() orelse return false;
        _ = try s.next();
        st.prune();
        // The inner snippet is finished: the outer goes on from its stop.
        return true;
    }

    /// Shift+Tab: true when a session took it.
    pub fn prev(st: *Stack) !bool {
        const s = st.top() orelse return false;
        return s.prev();
    }

    /// Escape: ends the innermost; true when there was one.
    pub fn escape(st: *Stack) bool {
        const s = st.top() orelse return false;
        s.end();
        st.prune();
        return true;
    }

    pub fn endAll(st: *Stack) void {
        for (st.items.items) |x| {
            x.end();
            x.destroy();
        }
        st.items.clearRetainingCapacity();
    }

    pub fn active(st: *Stack) ?ActiveStop {
        const s = st.top() orelse return null;
        return s.active();
    }

    /// The caret moved (sessions it left end).
    pub fn cursorMoved(st: *Stack) void {
        for (st.items.items) |x| x.cursorMoved();
        st.prune();
    }
};
