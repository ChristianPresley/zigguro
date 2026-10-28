//! `map` steps (E13.F08.S01.T03): one body (agent, command or builtin) per
//! item of `over`, at most `max_parallel` at once. Agent bodies are all
//! prepared (prompt rendered, replay looked up) in item order before any
//! starts, so resume reuses exactly the items before the first change.
//! The result is an array in input order with `null` for failed items;
//! the step fails when more than `max_fail_ratio` of the items failed.

const std = @import("std");
const exec = @import("exec.zig");
const def = @import("def.zig");
const path_mod = @import("path.zig");
const step_agent = @import("step_agent.zig");
const step_command = @import("step_command.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const Exec = exec.Exec;
const Abort = exec.Abort;
const Outcome = exec.Outcome;

const Item = struct {
    scope: Value,
    prep: ?step_agent.Prepared = null,
    out: Outcome = .{ .ok = .null },
};

const Pool = struct {
    x: *Exec,
    id: []const u8,
    m: *const def.MapStep,
    items: []Item,
    next: std.atomic.Value(usize) = .init(0),
    abort: ?Abort = null,
    mutex: Io.Mutex = .init,

    fn work(p: *Pool) Io.Cancelable!void {
        while (true) {
            if (p.aborted()) return;
            const i = p.next.fetchAdd(1, .monotonic);
            if (i >= p.items.len) return;
            const it = &p.items[i];
            it.out = p.one(it) catch |e| {
                p.mutex.lockUncancelable(p.x.eng.io);
                defer p.mutex.unlock(p.x.eng.io);
                if (p.abort == null) p.abort = e;
                return;
            };
        }
    }

    fn aborted(p: *Pool) bool {
        p.mutex.lockUncancelable(p.x.eng.io);
        defer p.mutex.unlock(p.x.eng.io);
        return p.abort != null;
    }

    fn one(p: *Pool, it: *Item) Abort!Outcome {
        const x = p.x;
        if (it.prep) |*pr| return step_agent.execute(x, pr);
        const out = if (p.m.command) |*c|
            try step_command.run(x, p.id, c, it.scope)
        else
            try step_command.callBuiltin(x, p.id, &p.m.builtin.?, it.scope);
        x.tracker.agent(p.id, if (out == .ok) .item_ok else .item_failed);
        return out;
    }
};

pub fn run(x: *Exec, id: []const u8, m: *const def.MapStep, scope: Value, pos: []const u8) Abort!Outcome {
    const a = x.allocator();
    const over = path_mod.Path.compile(a, m.over) catch return x.failf("invalid path {s}", .{m.over});
    const list: []const Value = switch (try over.value(scope, a)) {
        .array => |arr| arr.items,
        .null => &.{},
        else => return x.failf("{s} is not a list", .{m.over}),
    };
    const limits = x.def.limits;
    if (list.len > limits.max_map_items) return x.failf("{s} has {d} items, more than max_map_items ({d})", .{ m.over, list.len, limits.max_map_items });
    x.tracker.setTotal(id, @intCast(list.len));
    if (list.len == 0) return .{ .ok = .{ .array = .init(a) } };

    const items = try a.alloc(Item, list.len);
    for (list, items, 0..) |v, *it, i| {
        it.* = .{ .scope = try x.scopeWith(scope.object, &.{
            .{ .name = m.as, .value = v },
            .{ .name = path_mod.item_key, .value = v },
            .{ .name = path_mod.index_key, .value = .{ .integer = @intCast(i) } },
        }) };
        if (m.agent) |*ag| {
            const ipos = try std.fmt.allocPrint(a, "{s}#{d}", .{ pos, i });
            switch (try step_agent.prepare(x, id, ag, it.scope, ipos, @intCast(i), 0)) {
                .ready => |p| it.prep = p,
                .failed => |msg| {
                    // A prompt that cannot be rendered fails the item.
                    it.out = .{ .failed = msg };
                    it.prep = null;
                    it.scope = .null;
                },
            }
        }
    }

    var pool: Pool = .{ .x = x, .id = id, .m = m, .items = items };
    // Items whose prompt failed are skipped by the workers.
    if (m.agent != null) {
        var kept: usize = 0;
        for (items) |*it| if (it.prep != null) {
            kept += 1;
        };
        if (kept < items.len) {
            const live = try a.alloc(Item, kept);
            var j: usize = 0;
            for (items) |it| if (it.prep != null) {
                live[j] = it;
                j += 1;
            };
            pool.items = live;
        }
    }
    const par: usize = @min(m.max_parallel orelse limits.max_parallel, limits.max_parallel, pool.items.len);
    var g: Io.Group = .init;
    defer g.cancel(x.eng.io);
    for (0..par) |_| g.concurrent(x.eng.io, Pool.work, .{&pool}) catch try pool.work();
    try g.await(x.eng.io);
    if (pool.abort) |e| return e;

    // Results back in input order.
    if (pool.items.ptr != items.ptr) {
        var j: usize = 0;
        for (items) |*it| if (it.prep != null) {
            it.out = pool.items[j].out;
            j += 1;
        };
    }
    var arr: std.json.Array = .init(a);
    try arr.ensureTotalCapacity(items.len);
    var failed: usize = 0;
    var first_err: ?[]const u8 = null;
    for (items) |it| switch (it.out) {
        .ok => |v| arr.appendAssumeCapacity(v),
        .failed => |msg| {
            failed += 1;
            if (first_err == null) first_err = msg;
            arr.appendAssumeCapacity(.null);
        },
    };
    const ratio = @as(f64, @floatFromInt(failed)) / @as(f64, @floatFromInt(items.len));
    if (ratio > m.max_fail_ratio) return x.failf("{d} of {d} items failed (more than {d}%); first: {s}", .{
        failed, items.len, @as(u32, @intFromFloat(@round(m.max_fail_ratio * 100))), first_err.?,
    });
    return .{ .ok = .{ .array = arr } };
}
