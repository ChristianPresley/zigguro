//! `gate` steps (E13.F08.S01.T03): human approval. The workflow run goes
//! to `needs_input` with the gate's title and the rendered `show` value as
//! its question (Mission Control shows the approval card) and waits for
//! `WorkflowEngine.answerGate`. Approving continues with
//! `{"approved": true, "note": …}` as the step's result; rejecting stops
//! the run with "rejected at gate". Answers are journaled like agents, so
//! a resumed run does not ask again unless what the gate shows changed.

const std = @import("std");
const exec = @import("exec.zig");
const def = @import("def.zig");
const path_mod = @import("path.zig");
const interp = @import("interpolate.zig");
const JournalStore = @import("journal.zig");

const Value = std.json.Value;
const Exec = exec.Exec;
const Abort = exec.Abort;
const Outcome = exec.Outcome;

pub const rejected = "rejected at gate";

pub fn run(x: *Exec, id: []const u8, g: *const def.GateStep, scope: Value, pos: []const u8) Abort!Outcome {
    const e = x.eng;
    const a = x.allocator();
    var show: []const u8 = "";
    if (g.show) |p| {
        const cp = path_mod.Path.compile(a, p) catch return x.failf("invalid path {s}", .{p});
        show = try interp.render(a, try cp.value(scope, a));
    }
    const key = JournalStore.replayKey(pos, null, try std.mem.concat(a, u8, &.{ g.title, "\n", show }), &.{}, null, null, null);
    if (try x.lookup(pos, key)) |v| return decide(x, v);

    {
        x.mutex.lockUncancelable(e.io);
        defer x.mutex.unlock(e.io);
        x.gate = id;
        x.gate_answer = null;
    }
    const question = if (show.len > 0) try std.mem.concat(a, u8, &.{ g.title, "\n\n", show[0..@min(show.len, 4000)] }) else g.title;
    e.reg.update(x.id, .{ .question = question }) catch {};
    e.reg.update(x.id, .{ .status = .needs_input }) catch {};
    x.tracker.setGate(.{ .step = id, .title = g.title, .show = show });
    x.tracker.setState(id, .waiting);
    x.tracker.setStatus(.needs_input, null);
    const answer = blk: {
        x.mutex.lockUncancelable(e.io);
        defer x.mutex.unlock(e.io);
        defer x.gate = null;
        while (x.gate_answer == null and !x.stopped()) try x.cond.wait(e.io, &x.mutex);
        break :blk x.gate_answer;
    };
    x.tracker.setGate(null);
    e.reg.update(x.id, .{ .question = null }) catch {};
    e.reg.update(x.id, .{ .status = .working }) catch {};
    x.tracker.setStatus(.working, null);
    const ans = answer orelse return error.Stopped;

    var o: std.json.ObjectMap = .empty;
    try o.put(a, "approved", .{ .bool = ans.approve });
    try o.put(a, "note", if (ans.note) |n| .{ .string = n } else .null);
    const v: Value = .{ .object = o };
    const seq = x.nextSeq();
    x.journal.recordStart(seq, pos, key, x.id) catch |err| return exec.mapErr(err);
    x.journal.recordResult(seq, .{ .ok = v }) catch |err| return exec.mapErr(err);
    return decide(x, v);
}

fn decide(x: *Exec, v: Value) Abort!Outcome {
    const ok = v == .object and if (v.object.get("approved")) |b| b == .bool and b.bool else false;
    if (ok) return .{ .ok = v };
    x.requestStop(null);
    return .{ .failed = rejected };
}
