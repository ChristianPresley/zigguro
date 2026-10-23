//! The board view-model: columns, WIP, moves and ranks.

const std = @import("std");
const task_mod = @import("task.zig");
const view_mod = @import("view.zig");
const board = @import("board.zig");
const rank = @import("rank.zig");
const query = @import("query.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Task = task_mod.Task;
const Status = task_mod.Status;
const TasksView = view_mod.TasksView;
const BoardVM = board.BoardVM;

fn t(comptime id: u32, comptime s: Status, comptime p: u2, comptime r: ?[]const u8) Task {
    return .{ .id = id, .path = std.fmt.comptimePrint("T-{d:0>4}.md", .{id}), .title = std.fmt.comptimePrint("Task {d}", .{id}), .status = s, .priority = p, .rank = r };
}

fn colIds(vm: *const BoardVM, s: Status, out: []u32) []u32 {
    const c = vm.columns()[vm.columnIndex(s).?];
    for (c.cards, 0..) |i, k| out[k] = vm.task(i).id;
    return out[0..c.cards.len];
}

test "vm_columns_counts_wip" {
    const tasks = [_]Task{
        t(1, .ready, 2, null),       t(2, .ready, 0, null),       t(3, .ready, 2, "k"),        t(4, .ready, 1, "F"),
        t(5, .in_progress, 2, null), t(6, .in_progress, 2, null), t(7, .in_progress, 2, null), t(8, .done, 2, null),
        t(9, .cancelled, 2, null),   t(10, .ready, 3, "bad!"),
    };
    const v = try TasksView.build(gpa, &tasks, 1);
    defer v.destroy();
    var vm: BoardVM = .init(gpa);
    defer vm.deinit();
    vm.setWip(.in_progress, 2);
    try vm.apply(v, null, null, null);
    // Six columns; cancelled hidden.
    try testing.expectEqual(@as(usize, 6), vm.columns().len);
    try testing.expectEqual(Status.backlog, vm.columns()[0].status);
    var buf: [16]u32 = undefined;
    // Ranked first (F < k), then priority, then id; a bad rank is no rank.
    try testing.expectEqualSlices(u32, &.{ 4, 3, 2, 1, 10 }, colIds(&vm, .ready, &buf));
    const ip = vm.columns()[vm.columnIndex(.in_progress).?];
    try testing.expectEqual(@as(u32, 3), ip.total);
    try testing.expect(ip.overWip());
    try testing.expect(!vm.columns()[vm.columnIndex(.ready).?].overWip());
    vm.setShowCancelled(true);
    try vm.apply(v, null, null, null);
    try testing.expectEqual(@as(usize, 7), vm.columns().len);
    // A filter keeps the totals (for WIP) but not the cards.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const q = try query.parseQuery(arena.allocator(), "priority:P2");
    try vm.apply(v, null, &q, null);
    try testing.expectEqualSlices(u32, &.{ 3, 1 }, colIds(&vm, .ready, &buf));
    try testing.expectEqual(@as(u32, 5), vm.columns()[vm.columnIndex(.ready).?].total);
    try testing.expectEqual(@as(usize, 7), vm.flat.items.len);
}

test "move_produces_minimal_patch" {
    const tasks = [_]Task{ t(1, .ready, 2, "F"), t(2, .ready, 2, "V"), t(3, .ready, 2, "k"), t(4, .backlog, 1, null), t(5, .ready, 2, null), t(6, .ready, 2, null) };
    const v = try TasksView.build(gpa, &tasks, 1);
    defer v.destroy();
    var vm: BoardVM = .init(gpa);
    defer vm.deinit();
    try vm.apply(v, null, null, null);
    // Between two ranked cards: only the moved card's rank.
    {
        const m = try vm.move(3, .ready, 1);
        try testing.expectEqual(@as(usize, 0), m.others.len);
        try testing.expectEqualStrings("N", m.patch.rank.?.?);
        try testing.expect(m.patch.status == null);
    }
    // To where it already sorts: nothing.
    try testing.expect((try vm.move(2, .ready, 1)).isNoop());
    // Across columns at its natural place: the status only (what Alt+Right does).
    {
        const n = try vm.naturalIndex(4, .ready);
        try testing.expectEqual(@as(usize, 3), n);
        const m = try vm.move(4, .ready, n);
        try testing.expectEqual(Status.ready, m.patch.status.?);
        try testing.expect(m.patch.rank == null and m.others.len == 0);
    }
    // To the top: a rank before the first.
    try testing.expectEqualStrings("7", (try vm.move(4, .ready, 0)).patch.rank.?.?);
    // Below an unranked card: that card gets a rank too.
    {
        const m = try vm.move(1, .ready, 3);
        try testing.expectEqual(@as(usize, 1), m.others.len);
        try testing.expectEqual(@as(u32, 5), m.others[0].id);
        try testing.expectEqual(std.math.Order.lt, rank.order("k", m.others[0].rank));
        try testing.expectEqual(std.math.Order.lt, rank.order(m.others[0].rank, m.patch.rank.?.?));
    }
    try testing.expectError(error.TaskNotFound, vm.move(99, .ready, 0));
}

test "blocked_move_requires_confirm" {
    const tasks = [_]Task{
        .{ .id = 1, .path = "a.md", .title = "a", .status = .ready, .depends_on = &.{2} },
        .{ .id = 2, .path = "b.md", .title = "b", .status = .in_progress },
        .{ .id = 3, .path = "c.md", .title = "c", .status = .ready, .depends_on = &.{4} },
        .{ .id = 4, .path = "d.md", .title = "d", .status = .done },
    };
    const v = try TasksView.build(gpa, &tasks, 1);
    defer v.destroy();
    var vm: BoardVM = .init(gpa);
    defer vm.deinit();
    try vm.apply(v, null, null, null);
    try testing.expect((try vm.move(1, .in_progress, 0)).needs_confirm);
    try testing.expect((try vm.move(1, .done, 0)).needs_confirm);
    try testing.expect(!(try vm.move(1, .backlog, 0)).needs_confirm);
    try testing.expect(!(try vm.move(1, .blocked, 0)).needs_confirm);
    try testing.expect(!(try vm.move(3, .in_progress, 0)).needs_confirm);
}

test "rank_midpoint_properties: 10k random moves keep the order and ranks short" {
    const n = 40;
    var store: [n]Task = undefined;
    var ranks: [n][64]u8 = undefined;
    var rank_len: [n]usize = @splat(0);
    var names: [n][16]u8 = undefined;
    for (&store, 0..) |*x, i| x.* = .{ .id = @intCast(i + 1), .path = std.fmt.bufPrint(&names[i], "T-{d}.md", .{i + 1}) catch unreachable, .title = "t", .status = if (i % 2 == 0) .ready else .backlog, .priority = @intCast(i % 4) };
    var vm: BoardVM = .init(gpa);
    defer vm.deinit();
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rnd = prng.random();
    var version: u64 = 1;
    var v = try TasksView.build(gpa, &store, version);
    defer v.destroy();
    try vm.apply(v, null, null, null);
    var expect: std.ArrayList(u32) = .empty;
    defer expect.deinit(gpa);
    var longest: usize = 0;
    for (0..10_000) |step| {
        const id: u32 = rnd.intRangeAtMost(u32, 1, n);
        // Mostly reorder within one column, sometimes cross over; favour
        // the ends and the same slot to grow ranks fast.
        const to: Status = if (rnd.uintLessThan(u8, 10) == 0) (if (store[id - 1].status == .ready) .backlog else .ready) else store[id - 1].status;
        // The expected column after the move.
        expect.clearRetainingCapacity();
        for (vm.columns()[vm.columnIndex(to).?].cards) |i| if (vm.task(i).id != id) try expect.append(gpa, vm.task(i).id);
        const index: usize = switch (rnd.uintLessThan(u8, 4)) {
            0 => 0,
            1 => expect.items.len,
            2 => @min(expect.items.len, 1),
            else => rnd.uintLessThan(usize, expect.items.len + 1),
        };
        try expect.insert(gpa, index, id);
        const m = try vm.move(id, to, index);
        // Apply to the in-memory board.
        for (m.others) |o| {
            @memcpy(ranks[o.id - 1][0..o.rank.len], o.rank);
            rank_len[o.id - 1] = o.rank.len;
            store[o.id - 1].rank = ranks[o.id - 1][0..o.rank.len];
        }
        if (m.patch.status) |s| store[id - 1].status = s;
        if (m.patch.rank) |r| {
            const rr = r.?;
            @memcpy(ranks[id - 1][0..rr.len], rr);
            rank_len[id - 1] = rr.len;
            store[id - 1].rank = ranks[id - 1][0..rr.len];
        }
        version += 1;
        const nv = try TasksView.build(gpa, &store, version);
        v.destroy();
        v = nv;
        try vm.apply(v, null, null, null);
        var buf: [n]u32 = undefined;
        const got = colIds(&vm, to, &buf);
        testing.expectEqualSlices(u32, expect.items, got) catch |e| {
            std.debug.print("step {d}: move {d} to {t} at {d}\n", .{ step, id, to, index });
            return e;
        };
        for (rank_len) |l| longest = @max(longest, l);
    }
    try testing.expect(longest <= rank.max_len);
}
