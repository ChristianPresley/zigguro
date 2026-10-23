//! The task board's view-model (E13.F03.S01.T02): the columns, their
//! cards in order, WIP limits, the flat list for list and table modes,
//! and moves turned into the smallest set of file changes.
//!
//! Within a column, cards with a `rank` come first in rank order, then
//! the rest by priority and id. Moving a card to a position computes a
//! rank between its new neighbours (`rank.zig`), so a move normally
//! rewrites only the moved card's file; a move to where the card already
//! sorts changes only its status. Ranks are given to unranked cards
//! above the drop point when needed, and a column whose ranks grew too
//! long is rebalanced. Keyboard moves and drag-and-drop both go through
//! `move`, so they make identical file changes.

const std = @import("std");
const task_mod = @import("task.zig");
const view_mod = @import("view.zig");
const query_mod = @import("query.zig");
const rank = @import("rank.zig");
const ids = @import("ids.zig");
const runs = @import("../runs/root.zig");
const TaskStore = @import("store.zig");

const Allocator = std.mem.Allocator;
const Task = task_mod.Task;
const TaskId = task_mod.TaskId;
const Status = task_mod.Status;
const TasksView = view_mod.TasksView;
const Query = query_mod.Query;
const TaskPatch = TaskStore.TaskPatch;

pub const BoardMode = enum { board, list, table };

pub const status_count = view_mod.status_count;

/// Board columns, left to right (cancelled only when shown).
pub const column_order = [_]Status{ .backlog, .ready, .in_progress, .review, .blocked, .done, .cancelled };

pub const Column = struct {
    status: Status,
    /// Indexes into the view's tasks, in board order.
    cards: []const u32,
    /// Cards in the column before the filter.
    total: u32,
    wip: ?u32 = null,

    pub fn overWip(c: *const Column) bool {
        return if (c.wip) |w| c.total > w else false;
    }
};

/// A rank for another card, written alongside a move.
pub const Assign = struct { id: TaskId, rank: []const u8 };

pub const Move = struct {
    id: TaskId,
    /// For the moved card (empty when nothing changes).
    patch: TaskPatch = .{},
    /// Ranks for other cards in the target column, written first.
    others: []const Assign = &.{},
    /// The card goes to work (or review, or done) while a dependency is
    /// unfinished: ask first.
    needs_confirm: bool = false,

    pub fn isNoop(m: *const Move) bool {
        return m.others.len == 0 and std.meta.eql(m.patch, TaskPatch{});
    }
};

pub const MoveError = error{ TaskNotFound, OutOfMemory };

pub const BoardVM = struct {
    gpa: Allocator,
    view: ?*const TasksView = null,
    runs: ?*const runs.RunsView = null,
    cols: [status_count]std.ArrayList(u32) = @splat(.empty),
    totals: [status_count]u32 = @splat(0),
    columns_buf: [status_count]Column = undefined,
    ncols: usize = 0,
    /// Every shown card in query order (list and table modes).
    flat: std.ArrayList(u32) = .empty,
    /// Per status, from settings `agents.tasks.wip.<status>`.
    wip: [status_count]?u32 = @splat(null),
    show_cancelled: bool = false,
    /// Inputs of the last `apply`, to skip unchanged ones.
    applied: struct { version: u64 = std.math.maxInt(u64), query: ?*const Query = null, gen: u64 = 0, today: ?task_mod.Date = null } = .{},
    gen: u64 = 1,
    move_arena: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator) BoardVM {
        return .{ .gpa = gpa, .move_arena = .init(gpa) };
    }

    pub fn deinit(vm: *BoardVM) void {
        for (&vm.cols) |*c| c.deinit(vm.gpa);
        vm.flat.deinit(vm.gpa);
        vm.move_arena.deinit();
    }

    /// Settings changed (WIP limits, cancelled shown): rebuild on the next
    /// `apply`.
    pub fn invalidate(vm: *BoardVM) void {
        vm.gen += 1;
    }

    pub fn setShowCancelled(vm: *BoardVM, on: bool) void {
        if (vm.show_cancelled == on) return;
        vm.show_cancelled = on;
        vm.invalidate();
    }

    pub fn setWip(vm: *BoardVM, s: Status, limit: ?u32) void {
        vm.wip[@intFromEnum(s)] = limit;
        vm.invalidate();
    }

    /// Rebuilds the columns from `view` filtered by `query`; does nothing
    /// when neither changed. `view` (and `rv`) must stay alive until the
    /// next `apply`. `today` serves `due:` terms.
    pub fn apply(vm: *BoardVM, view: *const TasksView, rv: ?*const runs.RunsView, query: ?*const Query, today: ?task_mod.Date) !void {
        vm.runs = rv;
        const same_day = if (vm.applied.today) |a| (if (today) |b| a.eql(b) else false) else today == null;
        if (vm.view == view and vm.applied.version == view.version and vm.applied.query == query and vm.applied.gen == vm.gen and same_day) return;
        vm.view = view;
        vm.applied = .{ .version = view.version, .query = query, .gen = vm.gen, .today = today };
        for (&vm.cols) |*c| c.clearRetainingCapacity();
        vm.totals = @splat(0);
        vm.flat.clearRetainingCapacity();
        if (query) |q| {
            try query_mod.evalQueryAt(view, q, today, &vm.flat, vm.gpa);
        } else {
            try vm.flat.ensureTotalCapacity(vm.gpa, view.tasks.len);
            for (0..view.tasks.len) |i| vm.flat.appendAssumeCapacity(@intCast(i));
        }
        if (!vm.show_cancelled) {
            var w: usize = 0;
            for (vm.flat.items) |i| if (view.tasks[i].status != .cancelled) {
                vm.flat.items[w] = i;
                w += 1;
            };
            vm.flat.shrinkRetainingCapacity(w);
        }
        for (view.tasks) |t| vm.totals[@intFromEnum(t.status)] += 1;
        for (vm.flat.items) |i| try vm.cols[@intFromEnum(view.tasks[i].status)].append(vm.gpa, i);
        for (&vm.cols) |*c| std.mem.sort(u32, c.items, view, lessCard);
        vm.ncols = 0;
        for (column_order) |s| {
            if (s == .cancelled and !vm.show_cancelled) continue;
            const k = @intFromEnum(s);
            vm.columns_buf[vm.ncols] = .{ .status = s, .cards = vm.cols[k].items, .total = vm.totals[k], .wip = vm.wip[k] };
            vm.ncols += 1;
        }
    }

    pub fn columns(vm: *const BoardVM) []const Column {
        return vm.columns_buf[0..vm.ncols];
    }

    pub fn columnIndex(vm: *const BoardVM, s: Status) ?usize {
        for (vm.columns(), 0..) |c, i| if (c.status == s) return i;
        return null;
    }

    pub fn task(vm: *const BoardVM, i: u32) *const Task {
        return &vm.view.?.tasks[i];
    }

    /// The card's column and position.
    pub fn locate(vm: *const BoardVM, id: TaskId) ?struct { col: usize, index: usize } {
        for (vm.columns(), 0..) |c, ci| for (c.cards, 0..) |i, k| {
            if (vm.view.?.tasks[i].id == id) return .{ .col = ci, .index = k };
        };
        return null;
    }

    /// The run holding the task's claim, when it is in the runs view.
    pub fn claimRun(vm: *const BoardVM, t: *const Task) ?*const runs.RunRecord {
        const c = t.claimed_by orelse return null;
        const rv = vm.runs orelse return null;
        const id = runs.RunId.parse(c) catch return null;
        return rv.get(id);
    }

    /// Where the card would sort in column `to` with its current rank:
    /// the index a keyboard move across columns drops it at.
    pub fn naturalIndex(vm: *const BoardVM, id: TaskId, to: Status) MoveError!usize {
        const v = vm.view orelse return error.TaskNotFound;
        const ti: u32 = @intCast(v.indexOf(id) orelse return error.TaskNotFound);
        var n: usize = 0;
        for (vm.cols[@intFromEnum(to)].items) |i| {
            if (v.tasks[i].id == id) continue;
            if (lessCard(v, i, ti)) n += 1;
        }
        return n;
    }

    /// The changes that put card `id` at position `index` of column `to`
    /// (positions count the column without the card; clamped). Valid
    /// until the next `move`.
    pub fn move(vm: *BoardVM, id: TaskId, to: Status, index: usize) MoveError!Move {
        _ = vm.move_arena.reset(.retain_capacity);
        const a = vm.move_arena.allocator();
        const v = vm.view orelse return error.TaskNotFound;
        const t = v.get(id) orelse return error.TaskNotFound;
        var m: Move = .{ .id = id };
        if (t.status != to) {
            m.patch.status = to;
            m.needs_confirm = (to == .in_progress or to == .review or to == .done) and v.isBlocked(t);
        }
        // The target column without the card.
        var list: std.ArrayList(u32) = .empty;
        for (vm.cols[@intFromEnum(to)].items) |i| if (v.tasks[i].id != id) try list.append(a, i);
        const at = @min(index, list.items.len);
        if (at == try vm.naturalIndex(id, to)) return m;
        const cards = list.items;
        // Rank the unranked cards above the drop point, after the last
        // ranked one.
        var others: std.ArrayList(Assign) = .empty;
        var lo: ?[]const u8 = null;
        var k: usize = 0;
        while (k < at) : (k += 1) {
            const c = &v.tasks[cards[k]];
            if (c.rank != null and rank.isValid(c.rank.?)) {
                lo = c.rank.?;
                continue;
            }
            var buf: [64]u8 = undefined;
            const r = rank.between(&buf, lo, null) catch break;
            const owned = try a.dupe(u8, r);
            try others.append(a, .{ .id = c.id, .rank = owned });
            lo = owned;
        }
        const hi: ?[]const u8 = if (at < cards.len) blk: {
            const c = &v.tasks[cards[at]];
            break :blk if (c.rank != null and rank.isValid(c.rank.?) and k == at) c.rank.? else null;
        } else null;
        var buf: [64]u8 = undefined;
        const ok = k == at;
        const r: ?[]const u8 = if (ok) rank.between(&buf, lo, hi) catch null else null;
        if (r != null and r.?.len <= rank.max_len) {
            m.patch.rank = @as(?[]const u8, try a.dupe(u8, r.?));
            m.others = others.items;
            return m;
        }
        // Rebalance: every card of the column gets a fresh, short rank.
        others.clearRetainingCapacity();
        const order = try a.alloc(TaskId, cards.len + 1);
        for (cards[0..at], 0..) |i, j| order[j] = v.tasks[i].id;
        order[at] = id;
        for (cards[at..], at + 1..) |i, j| order[j] = v.tasks[i].id;
        const Ctx = struct { a: Allocator, order: []const TaskId, others: *std.ArrayList(Assign), mine: *?[]const u8, me: TaskId, err: bool = false };
        var mine: ?[]const u8 = null;
        var ctx: Ctx = .{ .a = a, .order = order, .others = &others, .mine = &mine, .me = id };
        rank.spread(order.len, &ctx, struct {
            fn f(c: *Ctx, i: usize, rk: []const u8) void {
                const owned = c.a.dupe(u8, rk) catch {
                    c.err = true;
                    return;
                };
                if (c.order[i] == c.me) c.mine.* = owned else c.others.append(c.a, .{ .id = c.order[i], .rank = owned }) catch {
                    c.err = true;
                };
            }
        }.f);
        if (ctx.err) return error.OutOfMemory;
        m.patch.rank = @as(?[]const u8, mine.?);
        m.others = others.items;
        return m;
    }
};

/// Writes a move as the user: the other cards' ranks first, then the
/// card.
pub fn commit(store: *TaskStore, m: *const Move) !void {
    for (m.others) |o| _ = try store.update(o.id, .{ .rank = @as(?[]const u8, o.rank) }, .user);
    if (!std.meta.eql(m.patch, TaskPatch{})) _ = try store.update(m.id, m.patch, .user);
}

/// Board order within a column.
pub fn lessCard(v: *const TasksView, a: u32, b: u32) bool {
    const ta = &v.tasks[a];
    const tb = &v.tasks[b];
    const ra = if (ta.rank) |r| (if (rank.isValid(r)) r else null) else null;
    const rb = if (tb.rank) |r| (if (rank.isValid(r)) r else null) else null;
    if (ra != null and rb != null) {
        const o = rank.order(ra.?, rb.?);
        if (o != .eq) return o == .lt;
    } else if (ra != null or rb != null) return ra != null;
    if (ta.priority != tb.priority) return ta.priority < tb.priority;
    const ka: u64 = if (ta.id == 0) std.math.maxInt(u64) else ta.id;
    const kb: u64 = if (tb.id == 0) std.math.maxInt(u64) else tb.id;
    if (ka != kb) return ka < kb;
    return a < b;
}
