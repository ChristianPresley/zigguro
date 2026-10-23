const std = @import("std");
const run = @import("../runs/run.zig");
const RunRegistry = @import("../runs/registry.zig");
const vm_mod = @import("vm.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const RunId = run.RunId;
const MissionVM = vm_mod.MissionVM;
const Group = vm_mod.Group;

const Clock = struct {
    now: i64 = 1_700_000_000_000,
    fn read(ctx: ?*anyopaque) i64 {
        const c: *Clock = @ptrCast(@alignCast(ctx.?));
        return c.now;
    }
};

const Fx = struct {
    clock: Clock = .{},
    reg: *RunRegistry,
    vm: MissionVM,
    n: u128 = 0,

    fn init(f: *Fx) !void {
        f.* = .{ .reg = undefined, .vm = .init(gpa) };
        f.reg = try RunRegistry.init(gpa, io, null, .{ .clock = Clock.read, .clock_ctx = &f.clock });
    }

    fn deinit(f: *Fx) void {
        f.vm.deinit();
        f.reg.deinit();
    }

    fn add(f: *Fx, s: run.RunSpec) !RunId {
        f.n += 1;
        f.clock.now += 1;
        return f.reg.createWithId(.fromInt((@as(u128, @intCast(f.clock.now)) << 80) | f.n), s);
    }

    fn to(f: *Fx, id: RunId, path: []const run.RunStatus) !void {
        for (path) |s| try f.reg.update(id, .{ .status = s });
    }

    fn apply(f: *Fx) !void {
        try f.applyReview(.none);
    }

    fn applyReview(f: *Fx, rc: vm_mod.ReviewCounts) !void {
        const v = f.reg.snapshot();
        defer f.reg.release(v);
        try f.vm.apply(v, rc, f.clock.now);
    }

    /// "group:title" per row, headers as "[group n]".
    fn layout(f: *Fx, buf: []u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        for (f.vm.rows()) |it| switch (it) {
            .header => |h| try w.print("[{s} {d}] ", .{ @tagName(h.group), h.count }),
            .row => |r| try w.print("{s}{s} ", .{ if (r.depth > 0) "  " else "", r.title }),
        };
        return w.buffered();
    }
};

fn bg(title: []const u8) run.RunSpec {
    return .{ .kind = .background, .title = title, .prompt = "p" };
}

const working = [_]run.RunStatus{ .starting, .working };
const done = [_]run.RunStatus{ .starting, .working, .completed };

test "vm_groups_and_order" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const q = try f.add(bg("q"));
    const w1 = try f.add(bg("w1"));
    const w2 = try f.add(bg("w2"));
    const ask = try f.add(bg("ask"));
    const old = try f.add(bg("old"));
    const pin = try f.add(bg("pin"));
    const rev = try f.add(bg("rev"));
    const fail = try f.add(bg("fail"));
    const paused = try f.add(bg("paused"));
    _ = q;
    try f.to(w1, &working);
    try f.to(w2, &working);
    try f.to(ask, &working);
    try f.reg.update(ask, .{ .question = "Allow rm?" });
    try f.to(ask, &.{.needs_input});
    try f.to(old, &done);
    try f.reg.update(pin, .{ .pinned = true });
    try f.to(rev, &.{ .starting, .working });
    try f.reg.update(rev, .{ .output = .{ .changeset = 7 } });
    try f.to(rev, &.{.completed});
    try f.to(fail, &.{ .starting, .failed });
    try f.to(paused, &.{ .starting, .working, .paused });
    // The first view: nothing is unread; most recent activity first.
    try f.apply();
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "[pinned 1] pin [needs_input 1] ask [working 2] w2 w1 [queued_paused 2] paused q [done 3] fail rev old ",
        try f.layout(&buf),
    );
    try testing.expectEqualStrings("Allow rm?", f.vm.get(ask).?.line);
    try testing.expectEqual(@as(u32, 3), f.vm.totals.running);
    try testing.expectEqual(@as(u32, 1), f.vm.totals.needs_input);

    // A changeset pending review moves the run to ready_for_review.
    const Rc = struct {
        fn pending(_: ?*anyopaque, cs: u64) bool {
            return cs == 7;
        }
    };
    try f.applyReview(.{ .version = 1, .pending = Rc.pending });
    try testing.expectEqual(Group.ready_for_review, f.vm.get(rev).?.group);
    try testing.expectEqual(@as(u16, 1), f.vm.get(rev).?.pending_review);
    try testing.expectEqualStrings(
        "[pinned 1] pin [needs_input 1] ask [ready_for_review 1] rev [working 2] w2 w1 [queued_paused 2] paused q [done 2] fail old ",
        try f.layout(&buf),
    );

    // Activity on w1 makes it unread and puts it first in its group.
    f.clock.now += 1_000;
    try f.reg.update(w1, .{ .summary = "editing" });
    try f.applyReview(.{ .version = 1, .pending = Rc.pending });
    try testing.expect(f.vm.get(w1).?.unread);
    try testing.expectEqual(f.clock.now, f.vm.get(w1).?.activity_ms);
    try testing.expectEqualStrings(
        "[pinned 1] pin [needs_input 1] ask [ready_for_review 1] rev [working 2] w1 w2 [queued_paused 2] paused q [done 2] fail old ",
        try f.layout(&buf),
    );
    f.vm.markSeen(w1);
    try f.vm.refresh();
    try testing.expect(!f.vm.get(w1).?.unread);
    // Still the most recent.
    try testing.expectEqual(w1, f.vm.rows()[7].row.run);
    try testing.expectEqual(@as(i64, 2_000), f.vm.get(w1).?.ageMs(f.clock.now + 2_000));
}

test "vm_incremental_only_changed_rows" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var ids: [20]RunId = undefined;
    for (&ids, 0..) |*id, i| {
        var name: [8]u8 = undefined;
        id.* = try f.add(bg(try std.fmt.bufPrint(&name, "r{d}", .{i})));
        try f.to(id.*, &working);
    }
    try f.apply();
    try testing.expectEqual(@as(u64, 20), f.vm.stats.rebuilt);
    const sorted = f.vm.stats.sorted_groups;
    // Nothing changed: no work at all.
    try f.apply();
    try testing.expectEqual(@as(u64, 20), f.vm.stats.rebuilt);
    try testing.expectEqual(sorted, f.vm.stats.sorted_groups);
    // Two runs change: two rows rebuilt, one group re-sorted.
    try f.reg.update(ids[3], .{ .summary = "a" });
    try f.reg.update(ids[9], .{ .cost = .{ .micros = 50 } });
    f.clock.now += 10;
    try f.apply();
    try testing.expectEqual(@as(u64, 22), f.vm.stats.rebuilt);
    try testing.expectEqual(sorted + 1, f.vm.stats.sorted_groups);
    // One finishes: it moves to done, the only group re-sorted (taking a
    // row out keeps the rest in order).
    try f.to(ids[5], &.{.completed});
    try f.apply();
    try testing.expectEqual(@as(u64, 23), f.vm.stats.rebuilt);
    try testing.expectEqual(sorted + 2, f.vm.stats.sorted_groups);
    try testing.expectEqual(Group.done, f.vm.get(ids[5]).?.group);
    // Removed from the registry: gone from the rows.
    try f.reg.remove(ids[5], false);
    try f.apply();
    try testing.expect(f.vm.get(ids[5]) == null);
    try testing.expectEqual(@as(usize, 19), f.vm.rowCount());
    try testing.expectEqual(@as(u64, 23), f.vm.stats.rebuilt);
}

test "workflow_children_nest_and_progress" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const wf = try f.add(.{ .kind = .workflow, .title = "release", .prompt = "p" });
    try f.to(wf, &working);
    var workers: [3]RunId = undefined;
    for (&workers, 0..) |*w, i| {
        var name: [8]u8 = undefined;
        w.* = try f.add(.{ .kind = .workflow_worker, .title = try std.fmt.bufPrint(&name, "step{d}", .{i}), .prompt = "p", .parent = wf, .origin = .{ .workflow = .{ .run = wf, .step = "build" } } });
        try f.to(w.*, &working);
    }
    const solo = try f.add(bg("solo"));
    try f.to(solo, &working);
    try f.apply();
    var buf: [512]u8 = undefined;
    // Collapsed by default.
    try testing.expectEqualStrings("[working 2] solo release ", try f.layout(&buf));
    try testing.expectEqual(vm_mod.Progress{ .done = 0, .total = 3 }, f.vm.get(wf).?.progress.?);
    try f.to(workers[1], &.{.completed});
    try f.apply();
    try testing.expectEqual(vm_mod.Progress{ .done = 1, .total = 3 }, f.vm.get(wf).?.progress.?);
    f.vm.setExpanded(wf, true);
    try f.vm.refresh();
    try testing.expectEqualStrings("[working 2] solo release   step0   step1   step2 ", try f.layout(&buf));
    try testing.expectEqual(@as(u8, 1), f.vm.get(workers[0]).?.depth);
    var out: [4]RunId = undefined;
    try testing.expectEqual(@as(usize, 3), f.vm.children(wf, &out).len);
    // A filter matching only a worker shows its workflow too.
    f.vm.setExpanded(wf, false);
    try f.vm.setFilterText("step2");
    try testing.expectEqualStrings("[working 1] release   step2 ", try f.layout(&buf));
    try f.vm.setFilterText("a:build");
    try testing.expectEqualStrings("[working 1] release   step0   step1   step2 ", try f.layout(&buf));
    try f.vm.setFilterText("");
    // The workflow finishes and is removed: its workers go top-level.
    for (workers) |w| if (!w.eql(workers[1])) try f.to(w, &.{.completed});
    try f.to(wf, &.{.completed});
    try f.reg.remove(wf, false);
    try f.apply();
    try testing.expectEqual(@as(u8, 0), f.vm.get(workers[0]).?.depth);
    try testing.expectEqual(@as(usize, 4), f.vm.rowCount());
}

test "filters apply to rows" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const a = try f.add(.{ .kind = .scheduled, .title = "Nightly triage", .prompt = "label issues", .tags = &.{"ops"}, .origin = .{ .automation = .{ .name = "triage" } } });
    const b = try f.add(bg("Fix build"));
    try f.to(a, &working);
    try f.reg.update(a, .{ .cost = .{ .micros = 900_000 } });
    try f.to(b, &done);
    try f.reg.update(b, .{ .summary = "patched build.zig" });
    try f.apply();
    var buf: [256]u8 = undefined;
    const Case = struct { q: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .q = "s:working", .want = "[working 1] Nightly triage " },
        .{ .q = "s:done", .want = "[done 1] Fix build " },
        .{ .q = "k:scheduled", .want = "[working 1] Nightly triage " },
        .{ .q = "o:build.zig", .want = "[done 1] Fix build " },
        .{ .q = "cost>0.5", .want = "[working 1] Nightly triage " },
        .{ .q = "cost<0.5", .want = "[done 1] Fix build " },
        .{ .q = "#OPS", .want = "[working 1] Nightly triage " },
        .{ .q = "a:triage", .want = "[working 1] Nightly triage " },
        .{ .q = "label", .want = "[working 1] Nightly triage " },
        .{ .q = "nothing-matches", .want = "" },
        .{ .q = "", .want = "[working 1] Nightly triage [done 1] Fix build " },
    };
    for (cases) |c| {
        errdefer std.debug.print("filter: {s}\n", .{c.q});
        try f.vm.setFilterText(c.q);
        try testing.expectEqualStrings(c.want, try f.layout(&buf));
    }
}
