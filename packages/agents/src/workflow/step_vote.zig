//! `vote` steps (E13.F08.S01.T03): `n` copies of one agent (each with its
//! own seed, the copy index, so reruns get the same seeds) run at once,
//! then a decision. `majority`: the result more than half the copies
//! gave (compared as canonical JSON, keys sorted). `unanimous`: every
//! copy gave the same result. `judge`: a judge agent sees every result as
//! `$candidates` and its result is the step's.

const std = @import("std");
const exec = @import("exec.zig");
const def = @import("def.zig");
const step_agent = @import("step_agent.zig");

const Io = std.Io;
const Value = std.json.Value;
const Exec = exec.Exec;
const Abort = exec.Abort;
const Outcome = exec.Outcome;

const Copy = struct {
    x: *Exec,
    prep: step_agent.Prepared,
    out: Abort!Outcome = .{ .ok = .null },

    fn go(c: *Copy) Io.Cancelable!void {
        c.out = step_agent.execute(c.x, &c.prep);
    }
};

pub fn run(x: *Exec, id: []const u8, v: *const def.VoteStep, scope: Value, pos: []const u8) Abort!Outcome {
    const a = x.allocator();
    x.tracker.setTotal(id, v.n + @as(u32, @intFromBool(v.decide == .judge)));
    const copies = try a.alloc(Copy, v.n);
    for (copies, 0..) |*c, k| {
        const cpos = try std.fmt.allocPrint(a, "{s}.{d}", .{ pos, k });
        switch (try step_agent.prepare(x, id, &v.agent, scope, cpos, null, k)) {
            .ready => |p| c.* = .{ .x = x, .prep = p },
            .failed => |m| return .{ .failed = m },
        }
    }
    var g: Io.Group = .init;
    defer g.cancel(x.eng.io);
    for (copies) |*c| g.concurrent(x.eng.io, Copy.go, .{c}) catch try c.go();
    try g.await(x.eng.io);

    var cands: std.json.Array = .init(a);
    var texts: std.ArrayList([]const u8) = .empty;
    var failed: usize = 0;
    for (copies) |*c| switch (try c.out) {
        .ok => |r| {
            try cands.append(r);
            try texts.append(a, try exec.canonical(a, r));
        },
        .failed => failed += 1,
    };
    switch (v.decide) {
        .unanimous => {
            if (failed > 0) return x.failf("{d} of {d} copies failed", .{ failed, v.n });
            for (texts.items[1..]) |t| if (!std.mem.eql(u8, t, texts.items[0])) return x.failf("the copies disagree", .{});
            return .{ .ok = cands.items[0] };
        },
        .majority => {
            var best: usize = 0;
            var best_n: usize = 0;
            for (texts.items, 0..) |t, i| {
                var n: usize = 0;
                for (texts.items) |u| {
                    if (std.mem.eql(u8, t, u)) n += 1;
                }
                if (n > best_n) {
                    best_n = n;
                    best = i;
                }
            }
            if (best_n * 2 <= v.n) return x.failf("no majority: the most common result got {d} of {d} votes", .{ best_n, v.n });
            return .{ .ok = cands.items[best] };
        },
        .judge => {
            if (cands.items.len == 0) return x.failf("every copy failed", .{});
            const js = try x.scopeWith(scope.object, &.{.{ .name = "candidates", .value = .{ .array = cands } }});
            const jpos = try std.fmt.allocPrint(a, "{s}:judge", .{pos});
            return step_agent.runOne(x, id, &v.judge.?, js, jpos, null, 0);
        },
    }
}
