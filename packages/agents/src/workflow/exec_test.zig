const std = @import("std");
const zg_ai = @import("zg_ai");
const t = @import("test_env.zig");
const run = @import("../runs/run.zig");
const WorkflowEngine = @import("exec.zig");
const step_agent = @import("step_agent.zig");
const step_loop = @import("step_loop.zig");

const testing = std.testing;
const gpa = t.gpa;
const io = t.io;
const Env = t.Env;
const Fake = t.Fake;
const Job = t.Job;
const Reply = t.Reply;

const map_src =
    \\.{ .version = 1, .name = "m",
    \\  .args = .{ .{ .name = "items", .type = .json } },
    \\  .steps = .{
    \\    .{ .id = "each", .map = .{ .over = "$args.items", .agent = .{ .prompt = "do {{$item}}" } } },
    \\  },
    \\}
;

fn itemsJson(a: std.mem.Allocator, n: usize) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.writeAll("{\"items\":[");
    for (0..n) |i| try w.writer.print("{s}{d}", .{ if (i > 0) "," else "", i });
    try w.writer.writeAll("]}");
    return w.written();
}

test "map_concurrency_bound" {
    var e: Env = undefined;
    try e.init(t.fake_workers_echo, .{ .delay_ms = 1 });
    defer e.deinit();
    const id = try e.runToEnd(map_src, try itemsJson(e.arena.allocator(), 200));
    try testing.expectEqual(run.RunStatus.completed, e.status(id));
    try testing.expectEqual(@as(usize, 200), e.fake.count(null));
    try testing.expect(e.fake.max_running <= 8);
    try testing.expect(e.fake.max_running >= 2);
    const r = try e.result(id, "each");
    try testing.expectEqual(@as(usize, 200), r.array.items.len);
    // Input order, whatever order they finished in.
    for (r.array.items, 0..) |v, i| {
        var buf: [16]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "do {d}", .{i}), v.string);
    }
    // Every child is a separate plan position.
    try testing.expect(e.fake.hasPos("each#0") and e.fake.hasPos("each#199"));
}

test "workflow run is a parent with cost rolled up" {
    const S = struct {
        fn script(_: *Fake, j: Job) Reply {
            _ = j;
            return .{ .cost_then_text = .{ .cost = .{ .micros = 10, .input_tokens = 5, .output_tokens = 1 }, .text = "ok" } };
        }
    };
    var e: Env = undefined;
    try e.init(S.script, .{});
    defer e.deinit();
    const id = try e.runToEnd(map_src, "{\"items\":[1,2,3]}");
    const rec = e.record(id);
    try testing.expectEqual(run.RunKind.workflow, rec.spec.kind);
    try testing.expectEqual(run.RunStatus.completed, rec.status);
    try testing.expectEqual(@as(u64, 30), rec.cost.micros);
    try testing.expectEqual(@as(u64, 15), rec.cost.input_tokens);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = (try e.eng.progress(id, arena.allocator())).?;
    try testing.expectEqual(@as(u32, 3), p.agents);
    try testing.expectEqual(@as(u32, 3), p.steps[0].done);
    try testing.expectEqual(@as(u64, 30), p.cost.micros);
}

fn costly(_: *Fake, _: Job) Reply {
    return .{ .cost_then_text = .{ .cost = .{ .micros = 60 }, .text = "ok" } };
}

test "budget_split_and_stop" {
    var e: Env = undefined;
    try e.init(costly, .{});
    defer e.deinit();
    const src =
        \\.{ .version = 1, .name = "b",
        \\  .args = .{ .{ .name = "items", .type = .json } },
        \\  .limits = .{ .max_parallel = 1, .max_cost_micros = 100 },
        \\  .steps = .{
        \\    .{ .id = "each", .map = .{ .over = "$args.items", .agent = .{ .prompt = "{{$item}}" } } },
        \\  },
        \\}
    ;
    const id = try e.runToEnd(src, "{\"items\":[1,2,3,4,5]}");
    try testing.expectEqual(run.RunStatus.failed, e.status(id));
    try testing.expect(std.mem.startsWith(u8, e.errText(id), "budget"));
    // The first child may spend everything, the second what was left.
    try testing.expectEqual(@as(?u64, 100), e.fake.started(0).budgets.max_cost_micros);
    try testing.expectEqual(@as(?u64, 40), e.fake.started(1).budgets.max_cost_micros);
    try testing.expectEqual(@as(usize, 2), e.fake.count(null));
}

fn hangOnOne(_: *Fake, j: Job) Reply {
    if (std.mem.eql(u8, j.prompt, "do 1")) return .hang;
    return .{ .text = j.prompt };
}

test "stall_restart_then_null" {
    var e: Env = undefined;
    try e.init(hangOnOne, .{});
    defer e.deinit();
    const src =
        \\.{ .version = 1, .name = "s",
        \\  .args = .{ .{ .name = "items", .type = .json } },
        \\  .steps = .{
        \\    .{ .id = "each", .map = .{ .over = "$args.items", .max_fail_ratio = 0.5,
        \\       .agent = .{ .prompt = "do {{$item}}", .stall_ms = 40, .max_retries = 2 } } },
        \\  },
        \\}
    ;
    const id = try e.runToEnd(src, "{\"items\":[0,1]}");
    try testing.expectEqual(run.RunStatus.completed, e.status(id));
    try testing.expectEqualStrings("[\"do 0\",null]", try e.resultJson(id, "each"));
    // One try and two restarts for the stalled item, each stopped.
    try testing.expectEqual(@as(usize, 4), e.fake.count(null));
    try testing.expectEqual(@as(usize, 3), e.fake.stops.items.len);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = (try e.eng.progress(id, arena.allocator())).?;
    try testing.expectEqual(@as(u32, 2), p.steps[0].retries);
    try testing.expectEqual(@as(u32, 1), p.steps[0].failed);
}

/// Requires an object with key "a".
const NeedsA = struct {
    var dummy: u8 = 0;
    fn validator() zg_ai.schema.validate.Validator {
        return .{ .ctx = &dummy, .compile = compile, .validate = check };
    }
    fn compile(_: *anyopaque, _: std.mem.Allocator, _: []const u8) zg_ai.schema.validate.CompileError!*const anyopaque {
        return &dummy;
    }
    fn check(_: *anyopaque, _: *const anyopaque, _: std.mem.Allocator, v: std.json.Value, errs: *zg_ai.schema.validate.ErrorList) bool {
        if (v == .object and v.object.contains("a")) return true;
        errs.add(.{ .pointer = "/a", .keyword = "required", .message = "missing property" });
        return false;
    }
};

fn neverA(_: *Fake, j: Job) Reply {
    _ = j;
    return .{ .text = "```json\n{\"b\": 1}\n```" };
}

fn aOnSecondTry(_: *Fake, j: Job) Reply {
    if (j.attempt == 0) return .{ .text = "Here you go: {\"b\": 1}" };
    return .{ .text = "{\"a\": 2}" };
}

const schema_src =
    \\.{ .version = 1, .name = "o",
    \\  .steps = .{
    \\    .{ .id = "pick", .agent = .{ .prompt = "pick", .schema = "{\"type\":\"object\",\"required\":[\"a\"]}", .max_retries = 4 } },
    \\  },
    \\}
;

test "structured_output_retries_then_fails" {
    {
        var e: Env = undefined;
        try e.init(neverA, .{ .validator = NeedsA.validator() });
        defer e.deinit();
        const id = try e.runToEnd(schema_src, "{}");
        try testing.expectEqual(run.RunStatus.failed, e.status(id));
        try testing.expectEqual(@as(usize, 5), e.fake.count(null));
        const msg = e.errText(id);
        try testing.expect(std.mem.indexOf(u8, msg, "gave up after 5 attempts") != null);
        try testing.expect(std.mem.indexOf(u8, msg, "/a: missing property") != null);
        // Retries carry the errors.
        try testing.expect(std.mem.indexOf(u8, e.fake.started(1).prompt, step_agent.retry_instruction) != null);
        try testing.expect(std.mem.indexOf(u8, e.fake.started(0).prompt, step_agent.schema_instruction) != null);
    }
    {
        var e: Env = undefined;
        try e.init(aOnSecondTry, .{ .validator = NeedsA.validator() });
        defer e.deinit();
        const id = try e.runToEnd(schema_src, "{}");
        try testing.expectEqual(run.RunStatus.completed, e.status(id));
        try testing.expectEqualStrings("{\"a\":2}", try e.resultJson(id, "pick"));
    }
}

test "parse_answer_tolerates_fences_and_prose" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(step_agent.parseAnswer(a, " {\"x\":1} ").? == .object);
    try testing.expect(step_agent.parseAnswer(a, "```json\n[1,2]\n```").? == .array);
    try testing.expect(step_agent.parseAnswer(a, "Sure. {\"x\": {\"y\": 2}} Done.").? == .object);
    try testing.expect(step_agent.parseAnswer(a, "no json here") == null);
}

test "agent cap is enforced at runtime" {
    var e: Env = undefined;
    try e.init(t.fake_workers_echo, .{});
    defer e.deinit();
    const src =
        \\.{ .version = 1, .name = "cap",
        \\  .args = .{ .{ .name = "items", .type = .json } },
        \\  .limits = .{ .max_agents = 3, .max_parallel = 1 },
        \\  .steps = .{
        \\    .{ .id = "each", .map = .{ .over = "$args.items", .agent = .{ .prompt = "{{$item}}" } } },
        \\  },
        \\}
    ;
    const id = try e.runToEnd(src, "{\"items\":[1,2,3,4,5]}");
    try testing.expectEqual(run.RunStatus.failed, e.status(id));
    try testing.expectEqualStrings("the workflow tried to start more than 3 agents", e.errText(id));
    try testing.expectEqual(@as(usize, 3), e.fake.count(null));
}

test "map item cap is enforced at runtime" {
    var e: Env = undefined;
    try e.init(t.fake_workers_echo, .{});
    defer e.deinit();
    const src =
        \\.{ .version = 1, .name = "cap",
        \\  .args = .{ .{ .name = "items", .type = .json } },
        \\  .limits = .{ .max_map_items = 2 },
        \\  .steps = .{
        \\    .{ .id = "each", .map = .{ .over = "$args.items", .agent = .{ .prompt = "{{$item}}" } } },
        \\  },
        \\}
    ;
    const id = try e.runToEnd(src, "{\"items\":[1,2,3]}");
    try testing.expectEqual(run.RunStatus.failed, e.status(id));
    try testing.expectEqualStrings("step each: $args.items has 3 items, more than max_map_items (2)", e.errText(id));
    try testing.expectEqual(@as(usize, 0), e.fake.count(null));
}

fn hangAll(_: *Fake, _: Job) Reply {
    return .hang;
}

test "stop ends the run and its children" {
    var e: Env = undefined;
    try e.init(hangAll, .{});
    defer e.deinit();
    const d = try e.def(map_src);
    const id = try e.eng.start(d, try e.json("{\"items\":[1,2,3]}"), .{});
    for (0..2000) |_| {
        if (e.fake.count(null) == 3) break;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    e.eng.stop(id);
    try testing.expectEqual(run.RunStatus.stopped, try e.eng.wait(id));
    try testing.expectEqual(run.RunStatus.stopped, e.status(id));
    try testing.expectEqual(@as(usize, 3), e.fake.stops.items.len);
}

test "restartAgent starts a child again" {
    var e: Env = undefined;
    try e.init(hangAll, .{});
    defer e.deinit();
    const src =
        \\.{ .version = 1, .name = "r", .steps = .{ .{ .id = "one", .agent = .{ .prompt = "x" } } } }
    ;
    const id = try e.eng.start(try e.def(src), .null, .{});
    for (0..2000) |_| {
        if (e.fake.count(null) == 1) break;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try e.eng.restartAgent(id, e.fake.started(0).child);
    for (0..2000) |_| {
        if (e.fake.count(null) == 2) break;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expectEqual(@as(u8, 1), e.fake.started(1).attempt);
    e.eng.stop(id);
    _ = try e.eng.wait(id);
}

const replay_src =
    \\.{ .version = 1, .name = "rp",
    \\  .args = .{ .{ .name = "items", .type = .json } },
    \\  .steps = .{
    \\    .{ .id = "each", .map = .{ .over = "$args.items", .agent = .{ .prompt = "do {{$item}}" } } },
    \\    .{ .id = "sum", .reduce = .{ .prompt = "SUMMARY of {{$.each}}" } },
    \\  },
    \\}
;

test "deterministic_resume_reuses_unchanged_agents" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var e: Env = undefined;
    try e.init(t.fake_workers_echo, .{ .runs_dir = tmp.dir });
    defer e.deinit();
    const first = try e.runToEnd(replay_src, "{\"items\":[1,2,3]}");
    try testing.expectEqual(run.RunStatus.completed, e.status(first));
    try testing.expectEqual(@as(usize, 4), e.fake.count(null));
    // Same definition: nothing starts again.
    const d = try e.def(replay_src);
    const again = try e.eng.resumeFrom(first, d, try e.json("{\"items\":[1,2,3]}"), .{});
    try testing.expectEqual(run.RunStatus.completed, try e.eng.wait(again));
    try testing.expectEqual(@as(usize, 4), e.fake.count(null));
    try testing.expectEqualStrings(try e.resultJson(first, "sum"), try e.resultJson(again, "sum"));
    // Edited last prompt: only that agent runs.
    const edited = try e.def(
        \\.{ .version = 1, .name = "rp",
        \\  .args = .{ .{ .name = "items", .type = .json } },
        \\  .steps = .{
        \\    .{ .id = "each", .map = .{ .over = "$args.items", .agent = .{ .prompt = "do {{$item}}" } } },
        \\    .{ .id = "sum", .reduce = .{ .prompt = "Summary of {{$.each}}" } },
        \\  },
        \\}
    );
    const third = try e.eng.resumeFrom(again, edited, try e.json("{\"items\":[1,2,3]}"), .{});
    try testing.expectEqual(run.RunStatus.completed, try e.eng.wait(third));
    try testing.expectEqual(@as(usize, 5), e.fake.count(null));
    try testing.expectEqualStrings("sum", e.fake.started(4).step);
    // A changed second item re-runs it and everything after it.
    const fourth = try e.eng.resumeFrom(third, edited, try e.json("{\"items\":[1,9,3]}"), .{});
    try testing.expectEqual(run.RunStatus.completed, try e.eng.wait(fourth));
    try testing.expectEqual(@as(usize, 8), e.fake.count(null));
    var rerun: [3][]const u8 = undefined;
    for (&rerun, 5..) |*r, i| r.* = e.fake.started(i).pos;
    std.mem.sort([]const u8, &rerun, {}, struct {
        fn lt(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.order(u8, l, r) == .lt;
        }
    }.lt);
    try testing.expectEqualStrings("each#1", rerun[0]);
    try testing.expectEqualStrings("each#2", rerun[1]);
    try testing.expectEqualStrings("sum", rerun[2]);
}

test "no_progress_signature_folds_digits_and_spaces" {
    try testing.expectEqual(step_loop.signature("3 tests failed in 0.41s\n"), step_loop.signature("  3 tests   failed in 0.52s"));
    try testing.expect(step_loop.signature("test a failed") != step_loop.signature("test b failed"));
}

test "canonical_json_sorts_keys" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const x = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"b\":1,\"a\":[{\"d\":1,\"c\":2}]}", .{});
    try testing.expectEqualStrings("{\"a\":[{\"c\":2,\"d\":1}],\"b\":1}", try WorkflowEngine.canonical(a, x));
}

test "host_workers run each agent as a child run of the workflow" {
    const RunRegistry = @import("../runs/registry.zig");
    const RunHost = @import("../runs/host.zig");
    const FakeAgents = @import("../runs/fake_agents.zig").Fake;
    const HostWorkers = @import("host_workers.zig").HostWorkers;
    const parse = @import("parse.zig");

    const reg = try RunRegistry.init(gpa, io, null, .{});
    defer reg.deinit();
    var agents: FakeAgents = .{ .auto_complete = true };
    defer agents.deinit();
    var hw: HostWorkers = .init(gpa, io, reg);
    defer hw.deinit();
    const host = try RunHost.init(gpa, io, reg, agents.agentPort(), null, .builtin, .{ .observer = hw.observer() });
    defer host.deinit();
    const eng = try WorkflowEngine.init(gpa, io, reg, .{ .workers = hw.port(), .stall_poll_ms = 10 });
    defer eng.deinit();
    try hw.attach(host, eng);

    var diags: parse.Diagnostics = .init(gpa);
    defer diags.deinit();
    var p = try parse.parseOnly(gpa,
        \\.{ .version = 1, .name = "h", .steps = .{
        \\  .{ .id = "both", .parallel = .{
        \\    .{ .id = "a", .agent = .{ .prompt = "first", .label = "First" } },
        \\    .{ .id = "b", .agent = .{ .prompt = "second" } },
        \\  } },
        \\} }
    , &diags);
    defer p.deinit();
    const id = try eng.start(&p.def, .null, .{});
    try testing.expectEqual(run.RunStatus.completed, try eng.wait(id));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = (try eng.result(id, "a", arena.allocator())).?;
    try testing.expectEqualStrings("done\nnow", r.string);

    const v = reg.snapshot();
    defer reg.release(v);
    var kids: usize = 0;
    for (v.runs) |rec| {
        if (rec.spec.kind != .workflow_worker) continue;
        kids += 1;
        try testing.expect(rec.spec.parent.?.eql(id));
        try testing.expectEqual(run.RunStatus.completed, rec.status);
        try testing.expect(rec.spec.origin.workflow.run.eql(id));
        const step = rec.spec.origin.workflow.step;
        try testing.expect(std.mem.eql(u8, step, "a") or std.mem.eql(u8, step, "b"));
        if (std.mem.eql(u8, rec.spec.prompt, "first")) try testing.expectEqualStrings("First", rec.spec.title);
    }
    try testing.expectEqual(@as(usize, 2), kids);
}

const Cat = struct {
    written: ?[]u8 = null,

    const src: [:0]const u8 =
        \\.{ .version = 1, .name = "echo", .description = "Says it back",
        \\  .args = .{ .{ .name = "what" } },
        \\  .steps = .{ .{ .id = "say", .agent = .{ .prompt = "say {{$args.what}}" } } } }
    ;

    fn catalog(c: *Cat) @import("tools.zig").Catalog {
        return .{ .ctx = c, .list = list, .load = load, .write = write };
    }
    fn list(_: *anyopaque, a: std.mem.Allocator) anyerror![]const @import("tools.zig").Summary {
        return a.dupe(@import("tools.zig").Summary, &.{.{ .name = "echo", .description = "Says it back" }});
    }
    fn load(_: *anyopaque, _: std.mem.Allocator, name: []const u8) anyerror!?@import("tools.zig").Source {
        if (!std.mem.eql(u8, name, "echo")) return null;
        return .{ .text = src };
    }
    fn write(ctx: *anyopaque, _: []const u8, bytes: []const u8) anyerror!?u64 {
        const c: *Cat = @ptrCast(@alignCast(ctx));
        c.written = try gpa.dupe(u8, bytes);
        return 42;
    }
};

test "workflow tools list, run, report status and create" {
    const tools = @import("tools.zig");
    var e: Env = undefined;
    try e.init(t.fake_workers_echo, .{});
    defer e.deinit();
    var cat: Cat = .{};
    defer if (cat.written) |w| gpa.free(w);
    var te: tools.ToolExporter = .{ .eng = e.eng, .catalog = cat.catalog() };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try tools.runTool(&te, a, "workflow_list", "");
    try testing.expectEqualStrings("[{\"name\":\"echo\",\"description\":\"Says it back\"}]", l.text);

    const missing = try tools.runTool(&te, a, "workflow_run", "{\"name\":\"nope\"}");
    try testing.expect(missing.is_error);

    const r = try tools.runTool(&te, a, "workflow_run", "{\"name\":\"echo\",\"args\":{\"what\":\"hi\"}}");
    try testing.expect(!r.is_error);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, r.text, .{});
    const id = try run.RunId.parse(parsed.object.get("run").?.string);
    _ = try e.eng.wait(id);
    const s = try tools.runTool(&te, a, "workflow_status", try std.fmt.allocPrint(a, "{{\"run\":\"{s}\"}}", .{&id.text()}));
    try testing.expect(std.mem.indexOf(u8, s.text, "\"status\":\"completed\"") != null);
    try testing.expect(std.mem.indexOf(u8, s.text, "\"id\":\"say\",\"phase\":null,\"state\":\"done\",\"done\":1") != null);

    const bad = try tools.runTool(&te, a, "workflow_create", "{\"name\":\"x\",\"zon\":\".{ .version = 1, .name = \\\"x\\\", .steps = .{} }\"}");
    try testing.expect(bad.is_error);
    try testing.expect(std.mem.indexOf(u8, bad.text, "at least one step") != null);
    const good = try tools.runTool(&te, a, "workflow_create", "{\"name\":\"x\",\"zon\":\".{ .version = 1, .name = \\\"x\\\", .steps = .{ .{ .id = \\\"a\\\", .agent = .{ .prompt = \\\"p\\\" } } } }\"}");
    try testing.expect(!good.is_error);
    try testing.expectEqual(@as(?u64, 42), good.changeset);
    try testing.expect(cat.written != null);
}
