//! The Call Stack view (E07.F07.S01.T01): a tree of sessions (child
//! sessions nested), their threads and each thread's frames, from the
//! inspection models (zg_dap's `StackModel`).
//!
//! - A stopped thread whose frames are not loaded yet opens by asking for
//!   its first page; a thread with more frames ends with a "Load more
//!   stack frames" row. A running thread has no children.
//! - Frames show the function, then `file:line` (or the module for a
//!   frame without a source) muted. Runs of two or more `subtle` or
//!   de-emphasized frames fold into an "N frames hidden" row that opens
//!   to show them; `label` frames are separators and cannot be selected.
//! - Selecting a frame (click, or Enter and double click to also focus
//!   the editor) goes through `Hooks.select_frame`, which selects it in
//!   the `StackModel`. The selected frame carries a marker.
//! - Node ids stay the same across updates for the same session, thread
//!   and frame position, so open rows stay open. Accessible names read
//!   "function, file line N".
//!
//! `update` rebuilds the nodes from a snapshot when the models changed
//! (not per frame). UI thread only.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_dap = @import("zg_dap");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const virtual = zg_gui.virtual;
const TreeView = virtual.TreeView;
const TreeSource = virtual.TreeSource;
const ChildCount = virtual.tree_view.ChildCount;
const RowInfo = virtual.tree_view.RowInfo;
const LoadDone = virtual.tree_view.LoadDone;
pub const FrameRow = zg_dap.inspect.StackModel.FrameRow;
const SessionState = zg_dap.session.DebugSession.SessionState;

pub const ThreadIn = struct {
    id: i64,
    name: []const u8,
    stopped: bool,
    /// Why it stopped ("breakpoint", "step", ...).
    reason: ?[]const u8 = null,
    frames: []const FrameRow = &.{},
    complete: bool = false,
};

pub const SessionIn = struct {
    id: u32,
    name: []const u8,
    state: SessionState,
    parent: ?u32 = null,
    threads: []const ThreadIn = &.{},
};

pub const Selected = struct { session: u32, thread: i64, frame: i64 };

/// What the view asks of its owner (the debug service).
pub const Hooks = struct {
    ctx: *anyopaque,
    /// `focus`: also move focus to the editor.
    select_frame: *const fn (ctx: *anyopaque, session: u32, thread: i64, frame: i64, focus: bool) void,
    /// The next page of `thread`'s frames (its first when it has none).
    load_more: *const fn (ctx: *anyopaque, session: u32, thread: i64) void,
};

const Kind = enum(u8) { session, thread, frame, group, more };

const Key = struct { kind: Kind, session: u32, thread: i64, index: u32 };

const Node = struct {
    kind: Kind,
    session: u32,
    thread: i64 = 0,
    frame: i64 = 0,
    /// The accessible name (and type-ahead key).
    label: []const u8,
    name: []const u8,
    detail: []const u8 = "",
    dim: bool = false,
    selected: bool = false,
    /// A separator frame: not selectable.
    separator: bool = false,
    /// Null: not known yet (loading on open).
    children: ?[]const u64,
};

pub const CallStack = struct {
    gpa: Allocator,
    hooks: Hooks,
    tv: TreeView = undefined,
    /// The nodes' strings and child lists; replaced on `update`.
    arena: std.heap.ArenaAllocator,
    nodes: std.AutoHashMapUnmanaged(u64, Node) = .empty,
    roots: []const u64 = &.{},
    ids: std.AutoHashMapUnmanaged(Key, u64) = .empty,
    next_id: u64 = 1,
    /// Threads asked to load, told when their frames arrive.
    loading: std.AutoArrayHashMapUnmanaged(u64, void) = .empty,
    done: ?LoadDone = null,

    /// `cs` must not move afterwards.
    pub fn init(cs: *CallStack, gpa: Allocator, hooks: Hooks) Allocator.Error!void {
        cs.* = .{ .gpa = gpa, .hooks = hooks, .arena = .init(gpa) };
        cs.tv = try TreeView.init(gpa, cs.source(), .{
            .label = "Call Stack",
            .test_id = "debug-call-stack",
            .expand_on_click = false,
            .on_open = .{ .ctx = cs, .f = onOpen },
            .on_click = .{ .ctx = cs, .f = onClick },
        });
    }

    pub fn deinit(cs: *CallStack) void {
        cs.tv.deinit();
        cs.nodes.deinit(cs.gpa);
        cs.ids.deinit(cs.gpa);
        cs.loading.deinit(cs.gpa);
        cs.arena.deinit();
    }

    fn self(ptr: *anyopaque) *CallStack {
        return @ptrCast(@alignCast(ptr));
    }

    // -- building the nodes ---------------------------------------------------

    /// Rebuilds the tree from `sessions` (copied).
    pub fn update(cs: *CallStack, sessions: []const SessionIn, sel: ?Selected) Allocator.Error!void {
        cs.nodes.clearRetainingCapacity();
        _ = cs.arena.reset(.retain_capacity);
        var seen: std.AutoHashMapUnmanaged(Key, u64) = .empty;
        errdefer seen.deinit(cs.gpa);
        var b: Builder = .{ .cs = cs, .a = cs.arena.allocator(), .seen = &seen, .sel = sel };
        var roots: std.ArrayList(u64) = .empty;
        for (sessions) |s| {
            const top = if (s.parent) |p| for (sessions) |o| {
                if (o.id == p) break false;
            } else true else true;
            if (top) try roots.append(b.a, try b.session(sessions, &s));
        }
        cs.roots = roots.items;
        // Ids not seen this time are forgotten.
        cs.ids.deinit(cs.gpa);
        cs.ids = seen;
        try cs.tv.reload();
        // Threads whose frames arrived.
        var i: usize = 0;
        while (i < cs.loading.count()) {
            const id = cs.loading.keys()[i];
            const n = cs.nodes.get(id);
            if (n == null or n.?.children != null) {
                cs.loading.swapRemoveAt(i);
                if (n != null) if (cs.done) |d| d.call(id);
            } else i += 1;
        }
    }

    const Builder = struct {
        cs: *CallStack,
        a: Allocator,
        seen: *std.AutoHashMapUnmanaged(Key, u64),
        sel: ?Selected,

        fn id(b: *Builder, k: Key) Allocator.Error!u64 {
            const cs = b.cs;
            const v = cs.ids.get(k) orelse blk: {
                const n = cs.next_id;
                cs.next_id += 1;
                break :blk n;
            };
            try b.seen.put(cs.gpa, k, v);
            return v;
        }

        fn put(b: *Builder, k: Key, n: Node) Allocator.Error!u64 {
            const v = try b.id(k);
            try b.cs.nodes.put(b.cs.gpa, v, n);
            return v;
        }

        fn session(b: *Builder, all: []const SessionIn, s: *const SessionIn) Allocator.Error!u64 {
            var kids: std.ArrayList(u64) = .empty;
            for (all) |*c| if (c.parent == s.id) try kids.append(b.a, try b.session(all, c));
            for (s.threads) |*t| try kids.append(b.a, try b.thread(s, t));
            const st = stateText(s.state);
            return b.put(.{ .kind = .session, .session = s.id, .thread = 0, .index = 0 }, .{
                .kind = .session,
                .session = s.id,
                .label = try std.fmt.allocPrint(b.a, "{s}, {s}", .{ s.name, st }),
                .name = try b.a.dupe(u8, s.name),
                .detail = st,
                .dim = s.state == .terminated or s.state == .failed,
                .children = kids.items,
            });
        }

        fn thread(b: *Builder, s: *const SessionIn, t: *const ThreadIn) Allocator.Error!u64 {
            const detail = if (!t.stopped)
                "Running"
            else if (t.reason) |r|
                try std.fmt.allocPrint(b.a, "Paused on {s}", .{r})
            else
                "Paused";
            const key: Key = .{ .kind = .thread, .session = s.id, .thread = t.id, .index = 0 };
            var kids: ?[]const u64 = &.{};
            if (t.stopped) kids = if (t.frames.len == 0 and !t.complete) null else try b.frames(s, t);
            return b.put(key, .{
                .kind = .thread,
                .session = s.id,
                .thread = t.id,
                .label = try std.fmt.allocPrint(b.a, "Thread {s}, {s}", .{ t.name, detail }),
                .name = try b.a.dupe(u8, t.name),
                .detail = detail,
                .children = kids,
            });
        }

        fn frames(b: *Builder, s: *const SessionIn, t: *const ThreadIn) Allocator.Error![]const u64 {
            var kids: std.ArrayList(u64) = .empty;
            var i: usize = 0;
            while (i < t.frames.len) {
                var j = i;
                while (j < t.frames.len and isSubtle(&t.frames[j])) j += 1;
                if (j - i >= 2) {
                    var hidden: std.ArrayList(u64) = .empty;
                    for (i..j) |k| try hidden.append(b.a, try b.frame(s, t, k));
                    const heading = try std.fmt.allocPrint(b.a, "{d} frames hidden", .{j - i});
                    try kids.append(b.a, try b.put(.{ .kind = .group, .session = s.id, .thread = t.id, .index = @intCast(i) }, .{
                        .kind = .group,
                        .session = s.id,
                        .thread = t.id,
                        .label = heading,
                        .name = heading,
                        .dim = true,
                        .children = hidden.items,
                    }));
                    i = j;
                    continue;
                }
                try kids.append(b.a, try b.frame(s, t, i));
                i += 1;
            }
            if (!t.complete) try kids.append(b.a, try b.put(.{ .kind = .more, .session = s.id, .thread = t.id, .index = 0 }, .{
                .kind = .more,
                .session = s.id,
                .thread = t.id,
                .label = "Load more stack frames",
                .name = "Load more stack frames",
                .children = &.{},
            }));
            return kids.items;
        }

        fn frame(b: *Builder, s: *const SessionIn, t: *const ThreadIn, i: usize) Allocator.Error!u64 {
            const f = &t.frames[i];
            const where = try whereText(b.a, f);
            const sel = if (b.sel) |x| x.session == s.id and x.thread == t.id and x.frame == f.id else false;
            return b.put(.{ .kind = .frame, .session = s.id, .thread = t.id, .index = @intCast(i) }, .{
                .kind = .frame,
                .session = s.id,
                .thread = t.id,
                .frame = f.id,
                .label = try a11yName(b.a, f),
                .name = try b.a.dupe(u8, f.name),
                .detail = where,
                .dim = isSubtle(f) or f.hint == .label,
                .separator = f.hint == .label,
                .selected = sel,
                .children = &.{},
            });
        }
    };

    fn isSubtle(f: *const FrameRow) bool {
        if (f.hint == .subtle) return true;
        const src = f.source orelse return false;
        return src.deemphasize;
    }

    fn fileName(f: *const FrameRow) ?[]const u8 {
        const src = f.source orelse return null;
        if (src.path) |p| return std.fs.path.basename(p);
        return src.name;
    }

    /// "file:line", or the module for a frame without a source.
    fn whereText(a: Allocator, f: *const FrameRow) Allocator.Error![]const u8 {
        if (fileName(f)) |file| return std.fmt.allocPrint(a, "{s}:{d}", .{ file, f.line });
        return if (f.module) |m| a.dupe(u8, m) else "";
    }

    /// "function, file line N".
    fn a11yName(a: Allocator, f: *const FrameRow) Allocator.Error![]const u8 {
        if (fileName(f)) |file| return std.fmt.allocPrint(a, "{s}, {s} line {d}", .{ f.name, file, f.line });
        if (f.module) |m| return std.fmt.allocPrint(a, "{s}, module {s}", .{ f.name, m });
        return a.dupe(u8, f.name);
    }

    pub fn stateText(st: SessionState) []const u8 {
        return switch (st) {
            .initializing, .configuring, .launching => "Starting",
            .running => "Running",
            .stopped => "Paused",
            .terminating => "Stopping",
            .terminated => "Ended",
            .failed => "Failed",
        };
    }

    /// Opens `session`'s row and its `thread` (after a stop), revealing
    /// the selected frame. False while the thread or its frames are not
    /// there yet (ask again after the next `update`).
    pub fn reveal(cs: *CallStack, session: u32, thread: i64) bool {
        const sid = cs.ids.get(.{ .kind = .session, .session = session, .thread = 0, .index = 0 }) orelse return false;
        cs.openNode(sid);
        const tid = cs.ids.get(.{ .kind = .thread, .session = session, .thread = thread, .index = 0 }) orelse return false;
        const loaded = if (cs.nodes.get(tid)) |n| (if (n.children) |k| k.len > 0 else false) else false;
        if (!loaded) return false;
        cs.openNode(tid);
        var it = cs.nodes.iterator();
        while (it.next()) |kv| if (kv.value_ptr.selected) {
            if (cs.tv.flat.rowOf(kv.key_ptr.*)) |row| cs.tv.reveal(row);
            break;
        };
        return true;
    }

    fn openNode(cs: *CallStack, id: u64) void {
        const row = cs.tv.flat.rowOf(id) orelse return;
        if (!cs.tv.flat.isExpanded(id)) _ = cs.tv.expandRow(row) catch {};
    }

    /// The thread's frames as text (Copy Call Stack), in `a`.
    pub fn copyText(cs: *const CallStack, a: Allocator, session: u32, thread: i64) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        const tid = cs.ids.get(.{ .kind = .thread, .session = session, .thread = thread, .index = 0 }) orelse return out.toOwnedSlice(a);
        try cs.appendFrames(a, &out, tid);
        return out.toOwnedSlice(a);
    }

    fn appendFrames(cs: *const CallStack, a: Allocator, out: *std.ArrayList(u8), id: u64) Allocator.Error!void {
        const n = cs.nodes.get(id) orelse return;
        for (n.children orelse &.{}) |k| {
            const c = cs.nodes.get(k) orelse continue;
            switch (c.kind) {
                .frame => {
                    try out.appendSlice(a, c.name);
                    if (c.detail.len > 0) try out.print(a, " ({s})", .{c.detail});
                    try out.append(a, '\n');
                },
                .group => try cs.appendFrames(a, out, k),
                else => {},
            }
        }
    }

    /// The frame under the active row: its session, thread and id.
    pub fn activeFrame(cs: *const CallStack) ?Selected {
        const id = cs.tv.active orelse return null;
        const n = cs.nodes.get(id) orelse return null;
        if (n.kind != .frame) return null;
        return .{ .session = n.session, .thread = n.thread, .frame = n.frame };
    }

    /// The thread of the active row, if it is in one.
    pub fn activeThread(cs: *const CallStack) ?struct { session: u32, thread: i64 } {
        const id = cs.tv.active orelse return null;
        const n = cs.nodes.get(id) orelse return null;
        if (n.kind == .session) return null;
        return .{ .session = n.session, .thread = n.thread };
    }

    // -- the tree's data --------------------------------------------------------

    fn source(cs: *CallStack) TreeSource {
        return .{ .ptr = cs, .vtable = &vtable };
    }

    const vtable: TreeSource.VTable = .{
        .root_count = rootCount,
        .child_count = childCount,
        .child = child,
        .load = load,
        .label = label,
        .build_row = buildRow,
    };

    fn rootCount(ptr: *anyopaque) u32 {
        return @intCast(self(ptr).roots.len);
    }

    fn childCount(ptr: *anyopaque, id: u64) ChildCount {
        const n = self(ptr).nodes.get(id) orelse return .leaf;
        const kids = n.children orelse return .unknown_loading;
        return if (kids.len == 0) .leaf else .{ .known = @intCast(kids.len) };
    }

    fn child(ptr: *anyopaque, parent: ?u64, i: u32) u64 {
        const cs = self(ptr);
        const p = parent orelse return cs.roots[i];
        return cs.nodes.get(p).?.children.?[i];
    }

    fn load(ptr: *anyopaque, id: u64, done: LoadDone) void {
        const cs = self(ptr);
        const n = cs.nodes.get(id) orelse return;
        cs.done = done;
        cs.loading.put(cs.gpa, id, {}) catch return;
        cs.hooks.load_more(cs.hooks.ctx, n.session, n.thread);
    }

    fn label(ptr: *anyopaque, id: u64) []const u8 {
        const n = self(ptr).nodes.get(id) orelse return "";
        return n.label;
    }

    fn buildRow(ptr: *anyopaque, ui: *Ui, id: u64, _: RowInfo) void {
        const n = self(ptr).nodes.get(id) orelse return;
        ui.open(.{ .style = .{ .dir = .row, .gap = 6, .align_items = .center, .grow = 1, .shrink = 1 } });
        defer ui.close();
        switch (n.kind) {
            .more => ui.text(n.name, .{ .color = .fg_link, .wrap = false }),
            .group => ui.text(n.name, .{ .color = .fg_muted, .wrap = false }),
            else => {
                if (n.kind == .frame) ui.text(if (n.selected) "\u{27A4}" else " ", .{ .color = .warning, .wrap = false });
                ui.text(n.name, .{ .color = if (n.dim) .fg_muted else .fg, .wrap = false });
                if (n.detail.len > 0) ui.text(n.detail, .{ .color = .fg_muted, .wrap = false });
            },
        }
    }

    // -- actions ------------------------------------------------------------------

    fn activate(cs: *CallStack, id: u64, focus_editor: bool) void {
        const n = cs.nodes.get(id) orelse return;
        switch (n.kind) {
            .frame => if (!n.separator) cs.hooks.select_frame(cs.hooks.ctx, n.session, n.thread, n.frame, focus_editor),
            .more => cs.hooks.load_more(cs.hooks.ctx, n.session, n.thread),
            .session, .thread, .group => if (cs.tv.flat.rowOf(id)) |row| {
                if (cs.tv.flat.isExpanded(id)) {
                    _ = cs.tv.collapseRow(row);
                } else _ = cs.tv.expandRow(row) catch {};
            },
        }
    }

    fn onClick(ctx: *anyopaque, id: u64) void {
        self(ctx).activate(id, false);
    }

    fn onOpen(ctx: *anyopaque, id: u64) void {
        self(ctx).activate(id, true);
    }

    /// Focuses the tree.
    pub fn focus(cs: *CallStack, w: *Window) void {
        if (!cs.tv.node.isNone() and w.store.valid(cs.tv.node)) w.setFocus(cs.tv.node, true);
    }

    pub fn build(cs: *CallStack, ui: *Ui) void {
        cs.tv.win = ui.window();
        cs.tv.build(ui);
    }
};

const testing = std.testing;

const TestHooks = struct {
    selected: ?Selected = null,
    focused: bool = false,
    more: u32 = 0,

    fn select(ctx: *anyopaque, session: u32, thread: i64, frame: i64, focus: bool) void {
        const h: *TestHooks = @ptrCast(@alignCast(ctx));
        h.selected = .{ .session = session, .thread = thread, .frame = frame };
        h.focused = focus;
    }

    fn loadMore(ctx: *anyopaque, _: u32, _: i64) void {
        const h: *TestHooks = @ptrCast(@alignCast(ctx));
        h.more += 1;
    }

    fn hooks(h: *TestHooks) Hooks {
        return .{ .ctx = h, .select_frame = select, .load_more = loadMore };
    }
};

fn frameAt(id: i64, name: []const u8, path: ?[]const u8, line: u32, hint: zg_dap.inspect.StackModel.Hint) FrameRow {
    return .{
        .id = id,
        .name = name,
        .source = if (path) |p| .{ .path = p } else null,
        .line = line,
        .column = 1,
        .hint = hint,
        .can_restart = false,
        .ip_ref = null,
        .module = if (path == null) "libc.so.6" else null,
    };
}

fn rowLabels(cs: *CallStack, a: Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (cs.tv.flat.rows.items) |r| try out.print(a, "{d}:{s}|", .{ r.depth, if (r.flags.placeholder) "\u{2026}" else CallStack.label(cs, r.node) });
    return out.items;
}

test "ui: call stack paging and subtle grouping" {
    var h: TestHooks = .{};
    var cs: CallStack = undefined;
    try cs.init(testing.allocator, h.hooks());
    defer cs.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A stopped thread with no frames yet: opening it asks for them.
    var threads = [_]ThreadIn{
        .{ .id = 1, .name = "main", .stopped = true, .reason = "breakpoint" },
        .{ .id = 2, .name = "worker", .stopped = false },
    };
    const sessions = [_]SessionIn{.{ .id = 7, .name = "app", .state = .stopped, .threads = &threads }};
    try cs.update(&sessions, null);
    try testing.expectEqualStrings("0:app, Paused|", try rowLabels(&cs, a));
    // The frames are not there yet: the thread stays closed.
    try testing.expect(!cs.reveal(7, 1));
    try testing.expectEqual(@as(u32, 0), h.more);
    // Opening it asks for them.
    _ = try cs.tv.expandRow(1);
    try testing.expectEqual(@as(u32, 1), h.more);
    try testing.expectEqualStrings("0:app, Paused|1:Thread main, Paused on breakpoint|2:\u{2026}|1:Thread worker, Running|", try rowLabels(&cs, a));

    // The first page: two subtle frames fold, a single one does not;
    // the thread is not complete, so "Load more" ends it.
    const page = [_]FrameRow{
        frameAt(10, "handler", "/w/src/main.zig", 12, .normal),
        frameAt(11, "std.start.callMain", "/zig/lib/std/start.zig", 600, .subtle),
        frameAt(12, "std.start.main", "/zig/lib/std/start.zig", 610, .subtle),
        frameAt(13, "__libc_start_main", null, 0, .normal),
        frameAt(14, "_start", "/zig/lib/std/start.zig", 20, .subtle),
    };
    threads[0].frames = &page;
    try cs.update(&sessions, .{ .session = 7, .thread = 1, .frame = 10 });
    try testing.expectEqualStrings(
        "0:app, Paused|1:Thread main, Paused on breakpoint|" ++
            "2:handler, main.zig line 12|2:2 frames hidden|2:__libc_start_main, module libc.so.6|" ++
            "2:_start, start.zig line 20|2:Load more stack frames|1:Thread worker, Running|",
        try rowLabels(&cs, a),
    );
    // The group opens to its frames.
    CallStack.onClick(&cs, cs.tv.flat.rows.items[3].node);
    const first_hidden = cs.tv.flat.rows.items[4];
    try testing.expectEqual(@as(u16, 3), first_hidden.depth);
    try testing.expectEqualStrings("std.start.callMain, start.zig line 600", CallStack.label(&cs, first_hidden.node));
    // "Load more" asks for the next page.
    const more_row = cs.tv.flat.rows.items[cs.tv.flat.len() - 2].node;
    CallStack.onClick(&cs, more_row);
    try testing.expectEqual(@as(u32, 2), h.more);
    // Complete: no "Load more"; open rows stay open across updates.
    threads[0].complete = true;
    try cs.update(&sessions, null);
    const labels = try rowLabels(&cs, a);
    try testing.expect(std.mem.indexOf(u8, labels, "Load more") == null);
    try testing.expect(std.mem.indexOf(u8, labels, "3:std.start.main") != null);
    // Copy Call Stack lists every frame, hidden ones included.
    const text = try cs.copyText(a, 7, 1);
    try testing.expectEqualStrings(
        "handler (main.zig:12)\nstd.start.callMain (start.zig:600)\nstd.start.main (start.zig:610)\n__libc_start_main (libc.so.6)\n_start (start.zig:20)\n",
        text,
    );
}

test "ui: frame selection updates StackModel" {
    var h: TestHooks = .{};
    var cs: CallStack = undefined;
    try cs.init(testing.allocator, h.hooks());
    defer cs.deinit();
    const page = [_]FrameRow{
        frameAt(10, "inner", "/w/a.zig", 3, .normal),
        frameAt(11, "[async boundary]", null, 0, .label),
        frameAt(12, "outer", "/w/a.zig", 9, .normal),
    };
    const threads = [_]ThreadIn{.{ .id = 1, .name = "main", .stopped = true, .frames = &page, .complete = true }};
    // A child session nests under its parent.
    const sessions = [_]SessionIn{
        .{ .id = 1, .name = "parent", .state = .running },
        .{ .id = 2, .name = "child", .state = .stopped, .parent = 1, .threads = &threads },
    };
    try cs.update(&sessions, .{ .session = 2, .thread = 1, .frame = 10 });
    try testing.expectEqual(@as(usize, 1), cs.roots.len);
    _ = cs.reveal(1, 0);
    try testing.expect(cs.reveal(2, 1));
    try testing.expectEqual(@as(usize, 6), cs.tv.flat.len());
    // A click selects (the service then calls StackModel.select); Enter
    // also focuses the editor.
    CallStack.onClick(&cs, cs.tv.flat.rows.items[5].node);
    try testing.expectEqual(@as(i64, 12), h.selected.?.frame);
    try testing.expectEqual(@as(u32, 2), h.selected.?.session);
    try testing.expect(!h.focused);
    CallStack.onOpen(&cs, cs.tv.flat.rows.items[3].node);
    try testing.expectEqual(@as(i64, 10), h.selected.?.frame);
    try testing.expect(h.focused);
    // A separator is not selectable.
    h.selected = null;
    CallStack.onClick(&cs, cs.tv.flat.rows.items[4].node);
    try testing.expect(h.selected == null);
}

test "ui: keyboard navigation and a11y names" {
    var h: TestHooks = .{};
    var cs: CallStack = undefined;
    try cs.init(testing.allocator, h.hooks());
    defer cs.deinit();
    const page = [_]FrameRow{
        frameAt(10, "inner", "/w/a.zig", 3, .normal),
        frameAt(12, "outer", "/w/a.zig", 9, .normal),
    };
    const threads = [_]ThreadIn{.{ .id = 1, .name = "main", .stopped = true, .frames = &page, .complete = true }};
    const sessions = [_]SessionIn{.{ .id = 1, .name = "app", .state = .stopped, .threads = &threads }};
    try cs.update(&sessions, null);
    try testing.expectEqualStrings("Call Stack", cs.tv.props.label);
    // Right opens, Down moves, Enter selects the frame.
    const K = zg_gui.input.event.KeyPress;
    _ = try cs.tv.onKey(K{ .key = .arrow_right });
    _ = try cs.tv.onKey(K{ .key = .arrow_down });
    _ = try cs.tv.onKey(K{ .key = .arrow_right });
    _ = try cs.tv.onKey(K{ .key = .arrow_down });
    _ = try cs.tv.onKey(K{ .key = .arrow_down });
    try testing.expectEqualStrings("outer, a.zig line 9", CallStack.label(&cs, cs.tv.active.?));
    _ = try cs.tv.onKey(K{ .key = .enter });
    try testing.expectEqual(@as(i64, 12), h.selected.?.frame);
    try testing.expect(cs.activeFrame().?.frame == 12);
}
