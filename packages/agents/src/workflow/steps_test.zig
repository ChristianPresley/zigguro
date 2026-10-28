const std = @import("std");
const t = @import("test_env.zig");
const run = @import("../runs/run.zig");
const WorkflowEngine = @import("exec.zig");

const testing = std.testing;
const gpa = t.gpa;
const io = t.io;
const Env = t.Env;
const Fake = t.Fake;
const Job = t.Job;
const Reply = t.Reply;

fn failBad(_: *Fake, j: Job) Reply {
    if (std.mem.indexOf(u8, j.prompt, "bad") != null) return .{ .fail = "boom" };
    return .{ .text = j.prompt };
}

fn mapSrc(comptime ratio: []const u8) [:0]const u8 {
    return
    \\.{ .version = 1, .name = "m",
    \\  .args = .{ .{ .name = "items", .type = .json } },
    \\  .steps = .{
    \\    .{ .id = "each", .map = .{ .over = "$args.items", .as = "file", .max_fail_ratio =
    ++ ratio ++
        \\, .agent = .{ .prompt = "check {{$file}}" } } },
        \\  },
        \\}
    ;
}

test "map_failure_ratio" {
    const items = "{\"items\":[\"a\",\"bad1\",\"b\",\"bad2\",\"c\",\"d\",\"e\",\"bad3\",\"f\",\"g\"]}";
    {
        var e: Env = undefined;
        try e.init(failBad, .{});
        defer e.deinit();
        const id = try e.runToEnd(mapSrc("0.2"), items);
        try testing.expectEqual(run.RunStatus.failed, e.status(id));
        try testing.expectEqualStrings("step each: 3 of 10 items failed (more than 20%); first: boom", e.errText(id));
    }
    {
        var e: Env = undefined;
        try e.init(failBad, .{});
        defer e.deinit();
        const id = try e.runToEnd(mapSrc("0.5"), items);
        try testing.expectEqual(run.RunStatus.completed, e.status(id));
        const r = try e.result(id, "each");
        try testing.expectEqualStrings("check a", r.array.items[0].string);
        try testing.expect(r.array.items[1] == .null);
        try testing.expect(r.array.items[7] == .null);
    }
}

test "parallel_branches_keyed" {
    var e: Env = undefined;
    try e.init(t.fake_workers_echo, .{});
    defer e.deinit();
    const id = try e.runToEnd(
        \\.{ .version = 1, .name = "p",
        \\  .steps = .{
        \\    .{ .id = "both", .parallel = .{
        \\      .{ .id = "security", .agent = .{ .prompt = "sec" } },
        \\      .{ .id = "perf", .agent = .{ .prompt = "perf" } },
        \\    } },
        \\    .{ .id = "merge", .reduce = .{ .prompt = "{{$.security}} + {{$.both.perf}}" } },
        \\  },
        \\}
    , "{}");
    try testing.expectEqual(run.RunStatus.completed, e.status(id));
    try testing.expectEqualStrings("{\"perf\":\"perf\",\"security\":\"sec\"}", try e.resultJson(id, "both"));
    try testing.expectEqualStrings("\"sec + perf\"", try e.resultJson(id, "merge"));
    // Branch positions name their parallel step.
    var saw = false;
    for (0..3) |i| {
        if (std.mem.eql(u8, e.fake.started(i).pos, "both/security")) saw = true;
    }
    try testing.expect(saw);
}

fn bySeed(_: *Fake, j: Job) Reply {
    if (std.mem.startsWith(u8, j.prompt, "judge")) return .{ .text = "J" };
    return .{ .text = if (j.seed == 2) "B" else "A" };
}

fn split(_: *Fake, j: Job) Reply {
    return .{ .text = if (j.seed == 0) "A" else if (j.seed == 1) "B" else "C" };
}

test "vote_majority_and_judge" {
    {
        var e: Env = undefined;
        try e.init(bySeed, .{});
        defer e.deinit();
        const id = try e.runToEnd(
            \\.{ .version = 1, .name = "v", .steps = .{
            \\  .{ .id = "pick", .vote = .{ .n = 3, .agent = .{ .prompt = "pick one" } } },
            \\} }
        , "{}");
        try testing.expectEqual(run.RunStatus.completed, e.status(id));
        try testing.expectEqualStrings("\"A\"", try e.resultJson(id, "pick"));
        try testing.expect(e.fake.hasPos("pick.0") and e.fake.hasPos("pick.2"));
    }
    {
        var e: Env = undefined;
        try e.init(split, .{});
        defer e.deinit();
        const id = try e.runToEnd(
            \\.{ .version = 1, .name = "v", .steps = .{
            \\  .{ .id = "pick", .vote = .{ .n = 3, .agent = .{ .prompt = "pick one" } } },
            \\} }
        , "{}");
        try testing.expectEqual(run.RunStatus.failed, e.status(id));
        try testing.expectEqualStrings("step pick: no majority: the most common result got 1 of 3 votes", e.errText(id));
    }
    {
        var e: Env = undefined;
        try e.init(bySeed, .{});
        defer e.deinit();
        const id = try e.runToEnd(
            \\.{ .version = 1, .name = "v", .steps = .{
            \\  .{ .id = "pick", .vote = .{ .n = 3, .decide = .judge, .agent = .{ .prompt = "pick one" },
            \\     .judge = .{ .prompt = "judge {{$candidates}}" } } },
            \\} }
        , "{}");
        try testing.expectEqual(run.RunStatus.completed, e.status(id));
        try testing.expectEqualStrings("\"J\"", try e.resultJson(id, "pick"));
        try testing.expectEqualStrings("judge [\"A\",\"A\",\"B\"]", e.fake.started(3).prompt);
    }
}

fn sameFix(_: *Fake, j: Job) Reply {
    if (std.mem.startsWith(u8, j.prompt, "judge")) return .{ .text = "{\"pass\": false, \"why\": \"3 tests fail\"}" };
    return .{ .text = "patched" };
}

fn passOnThird(_: *Fake, j: Job) Reply {
    if (std.mem.startsWith(u8, j.prompt, "judge")) {
        if (std.mem.endsWith(u8, j.pos, "@2:judge")) return .{ .text = "{\"pass\": true}" };
        return .{ .text = if (std.mem.endsWith(u8, j.pos, "@0:judge")) "{\"pass\": false, \"why\": \"a\"}" else "{\"pass\": false, \"why\": \"b\"}" };
    }
    return .{ .text = "patch" };
}

const loop_src =
    \\.{ .version = 1, .name = "l", .steps = .{
    \\  .{ .id = "fix", .loop_until = .{ .max_rounds = 5,
    \\     .agent = .{ .prompt = "fix; last check: {{$check}}" },
    \\     .check = .{ .judge = .{ .prompt = "judge {{$.fix}}", .schema = "{\"type\":\"object\"}" } } } },
    \\} }
;

test "loop_until_no_progress_stop" {
    {
        var e: Env = undefined;
        try e.init(sameFix, .{});
        defer e.deinit();
        const id = try e.runToEnd(loop_src, "{}");
        try testing.expectEqual(run.RunStatus.failed, e.status(id));
        try testing.expect(std.mem.startsWith(u8, e.errText(id), "step fix: no progress: the check failed the same way 2 rounds in a row"));
        // Two rounds of agent + judge.
        try testing.expectEqual(@as(usize, 4), e.fake.count(null));
        // The second round sees the first check.
        try testing.expect(std.mem.indexOf(u8, e.fake.started(2).prompt, "\"pass\":false") != null);
    }
    {
        var e: Env = undefined;
        try e.init(passOnThird, .{});
        defer e.deinit();
        const id = try e.runToEnd(loop_src, "{}");
        try testing.expectEqual(run.RunStatus.completed, e.status(id));
        try testing.expectEqualStrings("\"patch\"", try e.resultJson(id, "fix"));
        try testing.expectEqual(@as(usize, 6), e.fake.count(null));
    }
}

const gate_src =
    \\.{ .version = 1, .name = "g", .steps = .{
    \\  .{ .id = "plan", .agent = .{ .prompt = "plan it" } },
    \\  .{ .id = "ok", .gate = .{ .title = "Apply the plan?", .show = "$.plan" } },
    \\  .{ .id = "apply", .agent = .{ .prompt = "apply {{$.plan}}" } },
    \\} }
;

test "gate_needs_input_then_continue" {
    var e: Env = undefined;
    try e.init(t.fake_workers_echo, .{});
    defer e.deinit();
    const id = try e.eng.start(try e.def(gate_src), .null, .{});
    try e.waitStatus(id, .needs_input);
    try testing.expectEqualStrings("Apply the plan?\n\nplan it", e.record(id).question.?);
    try testing.expectError(error.NoGate, e.eng.answerGate(id, "other", true, null));
    try e.eng.answerGate(id, "ok", true, "go");
    try testing.expectEqual(run.RunStatus.completed, try e.eng.wait(id));
    try testing.expectEqualStrings("{\"approved\":true,\"note\":\"go\"}", try e.resultJson(id, "ok"));
    try testing.expectEqual(@as(usize, 2), e.fake.count(null));
}

test "gate rejection stops the run" {
    var e: Env = undefined;
    try e.init(t.fake_workers_echo, .{});
    defer e.deinit();
    const id = try e.eng.start(try e.def(gate_src), .null, .{});
    try e.waitStatus(id, .needs_input);
    try e.eng.answerGate(id, "ok", false, null);
    try testing.expectEqual(run.RunStatus.stopped, try e.eng.wait(id));
    try testing.expectEqualStrings("step ok: rejected at gate", e.errText(id));
    try testing.expectEqual(@as(usize, 1), e.fake.count(null));
}

fn laneWriter(_: *Fake, j: Job) Reply {
    if (j.isolation != .lane) return .{ .text = "?" };
    const lanes = [_][]const u8{ "run/A", "run/B", "run/C" };
    const i = std.fmt.parseInt(usize, j.prompt[j.prompt.len - 1 ..], 10) catch 0;
    return .{ .lane_then_text = .{ .lane = lanes[i], .text = "wrote" } };
}

test "lane_per_worker_and_collect" {
    var e: Env = undefined;
    try e.init(laneWriter, .{});
    defer e.deinit();
    const id = try e.runToEnd(
        \\.{ .version = 1, .name = "w",
        \\  .args = .{ .{ .name = "items", .type = .json } },
        \\  .steps = .{
        \\    .{ .id = "write", .map = .{ .over = "$args.items", .agent = .{ .prompt = "edit {{$item}}", .isolation = .lane } } },
        \\    .{ .id = "lanes", .builtin = .{ .name = "lanes.collect" } },
        \\  },
        \\}
    , "{\"items\":[0,1,2]}");
    try testing.expectEqual(run.RunStatus.completed, e.status(id));
    const r = try e.result(id, "lanes");
    try testing.expectEqual(@as(usize, 3), r.array.items.len);
    var seen: [3]bool = @splat(false);
    for (r.array.items) |l| {
        const name = l.object.get("lane").?.string;
        seen[name[4] - 'A'] = true;
        try testing.expectEqualStrings("write", l.object.get("step").?.string);
    }
    try testing.expect(seen[0] and seen[1] and seen[2]);
}

const Cmd = struct {
    approve: bool,
    calls: u32 = 0,
    last_profile: []const u8 = "",
    last_argv1: []const u8 = "",

    fn port(c: *Cmd) WorkflowEngine.CommandPort {
        return .{ .ctx = c, .exec = execFn };
    }

    fn execFn(ctx: *anyopaque, arena: std.mem.Allocator, req: WorkflowEngine.CommandRequest) anyerror!WorkflowEngine.CommandResult {
        const c: *Cmd = @ptrCast(@alignCast(ctx));
        c.calls += 1;
        c.last_profile = try arena.dupe(u8, req.profile);
        c.last_argv1 = try arena.dupe(u8, req.argv[1]);
        if (!c.approve) return error.Denied;
        return .{ .exit_code = 0, .output = "ok\n" };
    }
};

const cmd_src =
    \\.{ .version = 1, .name = "c", .profile = "ci",
    \\  .args = .{ .{ .name = "target" } },
    \\  .steps = .{ .{ .id = "build", .command = .{ .argv = .{ "zig", "build", "{{$args.target}}" } } } },
    \\}
;

test "command_step_requires_approval" {
    {
        var cmd: Cmd = .{ .approve = false };
        var e: Env = undefined;
        try e.init(t.fake_workers_echo, .{ .commands = cmd.port() });
        defer e.deinit();
        const id = try e.runToEnd(cmd_src, "{\"target\":\"test\"}");
        try testing.expectEqual(run.RunStatus.failed, e.status(id));
        try testing.expectEqualStrings("step build: command denied", e.errText(id));
        try testing.expectEqualStrings("ci", cmd.last_profile);
    }
    {
        var cmd: Cmd = .{ .approve = true };
        var e: Env = undefined;
        try e.init(t.fake_workers_echo, .{ .commands = cmd.port() });
        defer e.deinit();
        const id = try e.runToEnd(cmd_src, "{\"target\":\"test\"}");
        try testing.expectEqual(run.RunStatus.completed, e.status(id));
        try testing.expectEqualStrings("{\"exit_code\":0,\"output\":\"ok\\n\"}", try e.resultJson(id, "build"));
    }
    {
        // No profile: refused before anything runs.
        var cmd: Cmd = .{ .approve = true };
        var e: Env = undefined;
        try e.init(t.fake_workers_echo, .{ .commands = cmd.port() });
        defer e.deinit();
        const id = try e.runToEnd(
            \\.{ .version = 1, .name = "c", .steps = .{ .{ .id = "build", .command = .{ .argv = .{ "zig", "build" } } } } }
        , "{}");
        try testing.expectEqual(run.RunStatus.failed, e.status(id));
        try testing.expectEqual(@as(u32, 0), cmd.calls);
    }
}

test "when skips a step and args get defaults" {
    var e: Env = undefined;
    try e.init(t.fake_workers_echo, .{});
    defer e.deinit();
    const id = try e.runToEnd(
        \\.{ .version = 1, .name = "w",
        \\  .args = .{ .{ .name = "deep", .type = .bool, .default = "false" }, .{ .name = "topic", .default = "zig" } },
        \\  .steps = .{
        \\    .{ .id = "extra", .when = "$args.deep", .agent = .{ .prompt = "more" } },
        \\    .{ .id = "main", .agent = .{ .prompt = "about {{$args.topic}}" } },
        \\  },
        \\}
    , "{}");
    try testing.expectEqual(run.RunStatus.completed, e.status(id));
    try testing.expectEqual(@as(usize, 1), e.fake.count(null));
    try testing.expectEqualStrings("\"about zig\"", try e.resultJson(id, "main"));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = (try e.eng.progress(id, arena.allocator())).?;
    try testing.expectEqual(@import("progress.zig").StepState.skipped, p.steps[0].state);
    try testing.expectEqualStrings("about zig", e.record(id).summary);
}
