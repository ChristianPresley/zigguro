//! `loop_until` steps (E13.F08.S01.T03), the evaluator-optimizer pattern:
//! each round runs the agent, then the check. The agent and the check
//! see the loop's last result as `$.<id>`, and the agent sees the last
//! check as `$check` (`{"pass", "output"}`). A command check passes on
//! exit 0, a path check on a truthy value, a judge check when the judge's
//! result has `"pass": true`.
//!
//! The run stops with "no progress" after `stop_when_no_progress` rounds
//! in a row fail the same way: the failure signature is a hash of the
//! check's output with whitespace collapsed and digit runs folded (so
//! timings and counters do not count as progress).

const std = @import("std");
const exec = @import("exec.zig");
const def = @import("def.zig");
const path_mod = @import("path.zig");
const interp = @import("interpolate.zig");
const step_agent = @import("step_agent.zig");
const step_command = @import("step_command.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Exec = exec.Exec;
const Abort = exec.Abort;
const Outcome = exec.Outcome;

pub fn run(x: *Exec, id: []const u8, l: *const def.LoopStep, scope: Value, pos: []const u8) Abort!Outcome {
    const a = x.allocator();
    x.tracker.setTotal(id, l.max_rounds);
    var last: Value = .null;
    var check: Value = .null;
    var last_sig: ?u64 = null;
    var same: u32 = 0;
    var round: u8 = 0;
    while (round < l.max_rounds) : (round += 1) {
        x.tracker.setRound(id, round + 1);
        const rs = try x.scopeWith(scope.object, &.{ .{ .name = id, .value = last }, .{ .name = "check", .value = check } });
        const rpos = try std.fmt.allocPrint(a, "{s}@{d}", .{ pos, round });
        switch (try step_agent.runOne(x, id, &l.agent, rs, rpos, null, 0)) {
            .ok => |v| last = v,
            .failed => |m| return x.failf("round {d}: {s}", .{ round + 1, m }),
        }
        const cs = try x.scopeWith(scope.object, &.{ .{ .name = id, .value = last }, .{ .name = "check", .value = check } });
        const c = switch (try runCheck(x, id, &l.check, cs, rpos)) {
            .ok => |c| c,
            .failed => |m| return x.failf("round {d} check: {s}", .{ round + 1, m }),
        };
        if (c.pass) return .{ .ok = last };
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "pass", .{ .bool = false });
        try o.put(a, "output", c.output);
        check = .{ .object = o };
        const sig = signature(try interp.render(a, c.output));
        if (last_sig != null and last_sig.? == sig) same += 1 else same = 1;
        last_sig = sig;
        if (same >= l.stop_when_no_progress) {
            const text = try interp.render(a, c.output);
            return x.failf("no progress: the check failed the same way {d} rounds in a row: {s}", .{ same, text[0..@min(text.len, 200)] });
        }
    }
    return x.failf("the check did not pass after {d} rounds", .{l.max_rounds});
}

const CheckResult = struct { pass: bool, output: Value };
const CheckOutcome = union(enum) { ok: CheckResult, failed: []const u8 };

fn runCheck(x: *Exec, id: []const u8, c: *const def.Check, scope: Value, rpos: []const u8) Abort!CheckOutcome {
    const a = x.allocator();
    if (c.command) |argv| {
        const r = try step_command.runArgv(x, id, argv, null, scope);
        return switch (r) {
            .ok => |res| .{ .ok = .{ .pass = res.exit_code == 0, .output = .{ .string = res.output } } },
            .failed => |m| .{ .failed = m },
        };
    }
    if (c.path) |p| {
        const cp = path_mod.Path.compile(a, p) catch return .{ .failed = "invalid check path" };
        const v = try cp.value(scope, a);
        return .{ .ok = .{ .pass = path_mod.truthy(v), .output = v } };
    }
    const jpos = try std.fmt.allocPrint(a, "{s}:judge", .{rpos});
    return switch (try step_agent.runOne(x, id, &c.judge.?, scope, jpos, null, 0)) {
        .ok => |v| .{ .ok = .{ .pass = judgePass(v), .output = v } },
        .failed => |m| .{ .failed = m },
    };
}

fn judgePass(v: Value) bool {
    return switch (v) {
        .object => |o| if (o.get("pass")) |p| p == .bool and p.bool else false,
        else => false,
    };
}

/// Hash of `s` with whitespace runs collapsed and digit runs folded.
pub fn signature(s: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    var space = false;
    var digit = false;
    for (std.mem.trim(u8, s, " \t\r\n")) |c| {
        if (std.ascii.isWhitespace(c)) {
            space = true;
            continue;
        }
        if (std.ascii.isDigit(c)) {
            if (!digit) h.update("0");
            digit = true;
            space = false;
            continue;
        }
        if (space) h.update(" ");
        space = false;
        digit = false;
        h.update(&.{c});
    }
    return h.final();
}
