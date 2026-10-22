//! Agent turn-loop tests, driven by `ScriptedProvider`.

const std = @import("std");
const proto = @import("zg_ai_proto");
const golden = @import("zg_core").testkit.golden;
const Agent = @import("Agent.zig");
const ev = @import("events.zig");
const busm = @import("bus.zig");
const deps = @import("deps.zig");
const scripted = @import("../provider/scripted.zig");
const pevents = @import("../provider/events.zig");
const reg = @import("../models/registry.zig");

const testing = std.testing;
const io = testing.io;
const Step = scripted.ScriptedProvider.Step;
const script = scripted.script;
const root = @import("zg_options").package_root;

const catalog: [:0]const u8 =
    \\.{
    \\    .retrieved = "test",
    \\    .models = .{
    \\        .{ .id = "m", .context_window = 200_000, .max_output = 32_000, .base = .claude,
    \\           .price = .{ .input_per_mtok_micros = 2_000_000, .output_per_mtok_micros = 10_000_000 } },
    \\    },
    \\}
;

/// Event lines (JSON, renumbered) minus events produced on tool tasks,
/// whose order relative to each other is not deterministic.
const Recorder = struct {
    mutex: std.Io.Mutex = .init,
    out: std.ArrayList(u8) = .empty,
    kept: u64 = 0,
    finished: u32 = 0,

    fn deinit(r: *Recorder) void {
        r.out.deinit(testing.allocator);
    }

    fn sub(r: *Recorder) busm.Subscriber {
        return .{ .ctx = r, .on_events = on, .mode = .inline_ };
    }

    fn on(ctx: *anyopaque, batch: []const ev.Envelope) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        for (batch) |e| {
            switch (e.ev) {
                .tool_started, .tool_progress => continue,
                .turn_finished => r.finished += 1,
                else => {},
            }
            r.kept += 1;
            var w: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &r.out);
            ev.writeJson(&w.writer, .{ .seq = r.kept, .ev = e.ev }) catch {};
            w.writer.writeByte('\n') catch {};
            r.out = w.toArrayList();
        }
    }
};

/// Fake `read`, `edit` and `run_tests` tools. `run_tests` fails on its
/// first call and passes afterwards.
const FakeTools = struct {
    sleep_ms: u32 = 0,
    /// Random 0-2 ms sleeps per call (determinism test).
    jitter: ?*std.Random.DefaultPrng = null,
    jitter_mutex: std.Io.Mutex = .init,
    calls: std.atomic.Value(u32) = .init(0),
    test_runs: std.atomic.Value(u32) = .init(0),
    specs: [3]proto.ToolSpec = undefined,
    static: deps.StaticTools = undefined,

    fn init(t: *FakeTools) void {
        const schema = "{\"type\":\"object\"}";
        t.specs = .{
            .{ .name = "read", .description = "Reads a file.", .input_schema_json = schema, .read_only = true, .handler = .{ .ctx = t, .call = read } },
            .{ .name = "edit", .description = "Edits a file.", .input_schema_json = schema, .read_only = false, .effects = .{ .writes_workspace = true }, .handler = .{ .ctx = t, .call = edit } },
            .{ .name = "run_tests", .description = "Runs the tests.", .input_schema_json = schema, .read_only = false, .effects = .{ .executes = true }, .handler = .{ .ctx = t, .call = runTests } },
        };
        t.static = .{ .specs = &t.specs };
    }

    fn pause(t: *FakeTools, c: *proto.ToolCall) proto.ToolError!void {
        _ = t.calls.fetchAdd(1, .monotonic);
        if (c.progress) |p| p.emit(p.ctx, "working");
        var ms = t.sleep_ms;
        if (t.jitter) |j| {
            t.jitter_mutex.lockUncancelable(c.io);
            defer t.jitter_mutex.unlock(c.io);
            ms += j.random().uintAtMost(u32, 2);
        }
        if (ms > 0) c.io.sleep(.fromMilliseconds(ms), .awake) catch return error.Canceled;
    }

    fn path(c: *proto.ToolCall) []const u8 {
        if (c.input == .object) if (c.input.object.get("path")) |v| if (v == .string) return v.string;
        return "?";
    }

    fn reply(c: *proto.ToolCall, comptime fmt: []const u8, args: anytype, is_error: bool) proto.ToolError!proto.ToolOutput {
        const text = std.fmt.allocPrint(c.arena, fmt, args) catch return error.OutOfMemory;
        return proto.ToolOutput.text(c.arena, text, is_error) catch error.OutOfMemory;
    }

    fn read(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const t: *FakeTools = @ptrCast(@alignCast(ctx));
        try t.pause(c);
        return reply(c, "contents of {s}", .{path(c)}, false);
    }

    fn edit(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const t: *FakeTools = @ptrCast(@alignCast(ctx));
        try t.pause(c);
        return reply(c, "edited {s}", .{path(c)}, false);
    }

    fn runTests(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const t: *FakeTools = @ptrCast(@alignCast(ctx));
        try t.pause(c);
        if (t.test_runs.fetchAdd(1, .monotonic) == 0) return reply(c, "1 failed: expected 2, found 3", .{}, true);
        return reply(c, "all tests passed", .{}, false);
    }
};

const Harness = struct {
    registry: reg.ModelRegistry,
    provider: @import("../provider/Provider.zig"),
    sp: *scripted.ScriptedProvider,
    tools: FakeTools = .{},
    rec: Recorder = .{},
    agent: *Agent = undefined,

    fn init(h: *Harness, turns: []const []const Step, cfg: Agent.Config, hooks: ?deps.Hooks) !void {
        h.* = .{ .registry = .init(testing.allocator, io, catalog), .sp = try .init(testing.allocator, turns, .all), .provider = undefined };
        h.provider = h.sp.provider();
        h.tools.init();
        h.agent = try Agent.create(testing.allocator, io, .{ .session = 1 }, cfg, h.agentDeps(hooks));
        _ = try h.agent.subscribe(h.rec.sub());
    }

    fn agentDeps(h: *Harness, hooks: ?deps.Hooks) Agent.Deps {
        return .{ .registry = &h.registry, .providers = .fixed(&h.provider), .tools = h.tools.static.tools(), .hooks = hooks };
    }

    fn deinit(h: *Harness) void {
        h.agent.destroy();
        h.provider.deinit();
        h.registry.deinit();
        h.rec.deinit();
    }

    fn roles(h: *Harness, buf: []u8) []const u8 {
        const msgs = h.agent.messages();
        for (msgs, 0..) |m, i| buf[i] = if (m.role == .user) 'u' else 'a';
        return buf[0..msgs.len];
    }

    fn waitStatus(h: *Harness, s: ev.Status) !void {
        var n: u32 = 0;
        while (h.agent.snapshot().status != s) : (n += 1) {
            if (n > 5000) return error.Timeout;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};

/// The transcript keeps the protocol invariant: every tool_use is answered
/// by a tool_result in the next message.
fn expectValidHistory(msgs: []const proto.Message) !void {
    for (msgs, 0..) |m, i| {
        if (m.role != .assistant) continue;
        for (m.content) |b| if (b == .tool_use and !b.tool_use.server) {
            try testing.expect(i + 1 < msgs.len);
            var found = false;
            for (msgs[i + 1].content) |r| if (r == .tool_result and std.mem.eql(u8, r.tool_result.tool_use_id, b.tool_use.id)) {
                found = true;
            };
            try testing.expect(found);
        };
    }
}

const scenario_turns = [_][]const Step{
    script.tools(&.{ .{ "t1", "read", "{\"path\":\"a.zig\"}" }, .{ "t2", "read", "{\"path\":\"b.zig\"}" } }),
    script.tools(&.{.{ "t3", "edit", "{\"path\":\"a.zig\"}" }}),
    script.tools(&.{.{ "t4", "run_tests", "{}" }}),
    script.tools(&.{.{ "t5", "edit", "{\"path\":\"a.zig\"}" }}),
    script.tools(&.{.{ "t6", "run_tests", "{}" }}),
    script.text("Fixed: the test passes now."),
};

/// Runs the read, edit, test, fix scenario; returns the event log.
fn runScenario(gpa: std.mem.Allocator, turns: []const []const Step, jitter: ?*std.Random.DefaultPrng) ![]u8 {
    var h: Harness = undefined;
    try h.init(turns, .{ .model = "m" }, null);
    defer h.deinit();
    h.tools.jitter = jitter;
    _ = try h.agent.submit(.{ .text = "fix the failing test in a.zig" });
    h.agent.waitIdle();
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("uauauauauaua", h.roles(&buf));
    try expectValidHistory(h.agent.messages());
    try testing.expectEqual(@as(u32, 6), h.tools.calls.load(.monotonic));
    const msgs = h.agent.messages();
    try testing.expectEqualStrings("contents of a.zig", msgs[2].content[0].tool_result.parts[0].text);
    try testing.expectEqualStrings("contents of b.zig", msgs[2].content[1].tool_result.parts[0].text);
    try testing.expect(msgs[6].content[0].tool_result.is_error);
    try testing.expect(!msgs[10].content[0].tool_result.is_error);
    const snap = h.agent.snapshot();
    try testing.expectEqual(@as(u32, 6), snap.turns);
    try testing.expectEqual(ev.FinishReason.end_turn, snap.last_finish.?);
    try testing.expect(snap.cost_micros > 0);
    return gpa.dupe(u8, h.rec.out.items);
}

test "scenario_read_edit_test_fix" {
    const log = try runScenario(testing.allocator, &scenario_turns, null);
    defer testing.allocator.free(log);
    try golden.expectGoldenOpts(io, @src(), "scenario_read_edit_test_fix.events", log, .{ .root = root, .dir = "testdata/loop" });
}

test "scenario_deterministic_under_jitter" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const expected = try runScenario(a, &scenario_turns, null);
    for (0..100) |_| {
        // A 0-2 ms delay before each scripted turn's events, and in tools.
        const turns = try a.alloc([]const Step, scenario_turns.len);
        for (scenario_turns, turns) |src, *dst| {
            const steps = try a.alloc(Step, src.len + 1);
            steps[0] = .{ .delay_ms = prng.random().uintAtMost(u32, 2) };
            @memcpy(steps[1..], src);
            dst.* = steps;
        }
        try testing.expectEqualStrings(expected, try runScenario(a, turns, &prng));
    }
}

test "queued_inputs_run_in_order" {
    const turns = [_][]const Step{
        &.{ .{ .delay_ms = 20 }, script.text("one")[0], script.text("one")[1], script.text("one")[2], script.text("one")[3], script.text("one")[4], script.text("one")[5] },
        script.text("two"),
    };
    var h: Harness = undefined;
    try h.init(&turns, .{ .model = "m" }, null);
    defer h.deinit();
    _ = try h.agent.submit(.{ .text = "first" });
    _ = try h.agent.submit(.{ .text = "second" });
    h.agent.waitIdle();
    const msgs = h.agent.messages();
    try testing.expectEqual(@as(usize, 4), msgs.len);
    try testing.expectEqualStrings("first", msgs[0].content[0].text.text);
    try testing.expectEqualStrings("one", msgs[1].content[0].text.text);
    try testing.expectEqualStrings("second", msgs[2].content[0].text.text);
    try testing.expectEqualStrings("two", msgs[3].content[0].text.text);
}

test "steer_lands_after_tool_results" {
    const turns = [_][]const Step{
        script.tools(&.{.{ "t1", "read", "{\"path\":\"a\"}" }}),
        script.text("ok"),
    };
    var h: Harness = undefined;
    try h.init(&turns, .{ .model = "m" }, null);
    defer h.deinit();
    h.tools.sleep_ms = 100;
    _ = try h.agent.submit(.{ .text = "go" });
    try h.waitStatus(.running_tools);
    _ = try h.agent.submit(.{ .text = "also check b", .mode = .steer });
    h.agent.waitIdle();
    const msgs = h.agent.messages();
    try testing.expectEqual(@as(usize, 4), msgs.len);
    try testing.expectEqual(@as(usize, 2), msgs[2].content.len);
    try testing.expect(msgs[2].content[0] == .tool_result);
    try testing.expectEqualStrings("also check b", msgs[2].content[1].text.text);
    // The second request saw the steering text.
    try testing.expectEqual(@as(usize, 3), h.sp.requests()[1].messages.len);
}

test "interrupt_cancels_then_runs" {
    const turns = [_][]const Step{
        &.{ script.text("x")[0], script.text("x")[1], .{ .event = .{ .text_delta = .{ .index = 0, .text = "partial" } } }, .{ .delay_ms = 10_000 } },
        script.text("fresh"),
    };
    var h: Harness = undefined;
    try h.init(&turns, .{ .model = "m" }, null);
    defer h.deinit();
    _ = try h.agent.submit(.{ .text = "long" });
    try h.waitStatus(.streaming);
    _ = try h.agent.submit(.{ .text = "never mind", .mode = .interrupt });
    h.agent.waitIdle();
    const msgs = h.agent.messages();
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("uaua", h.roles(&buf));
    try testing.expect(msgs[1].meta.interrupted);
    try testing.expectEqualStrings("partial", msgs[1].content[0].text.text);
    try testing.expectEqualStrings("fresh", msgs[3].content[0].text.text);
}

test "stop_hook_continues_at_most_three_times" {
    const Hook = struct {
        calls: u32 = 0,
        fn stop(ctx: *anyopaque, _: std.Io, _: std.mem.Allocator, _: *const proto.Message) anyerror!deps.StopDecision {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.calls += 1;
            return .{ .block = "keep going" };
        }
    };
    var hook: Hook = .{};
    const turns = [_][]const Step{ script.text("1"), script.text("2"), script.text("3"), script.text("4") };
    var h: Harness = undefined;
    try h.init(&turns, .{ .model = "m" }, .{ .ctx = &hook, .stop = Hook.stop });
    defer h.deinit();
    _ = try h.agent.submit(.{ .text = "go" });
    h.agent.waitIdle();
    try testing.expectEqual(@as(u32, 3), hook.calls);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("uauauaua", h.roles(&buf));
    try testing.expect(h.agent.messages()[2].meta.synthetic);
    try testing.expectEqual(@as(usize, 0), h.sp.remaining());
}

test "prompt_hook_blocks_and_adds_context" {
    const Hook = struct {
        fn prompt(_: *anyopaque, _: std.Io, _: std.mem.Allocator, text: []const u8) anyerror!deps.PromptDecision {
            if (std.mem.eql(u8, text, "secret")) return .{ .block = "blocked by policy" };
            return .{ .add_context = "ctx" };
        }
    };
    var dummy: u8 = 0;
    const turns = [_][]const Step{script.text("ok")};
    var h: Harness = undefined;
    try h.init(&turns, .{ .model = "m" }, .{ .ctx = &dummy, .prompt_submit = Hook.prompt });
    defer h.deinit();
    _ = try h.agent.submit(.{ .text = "secret" });
    h.agent.waitIdle();
    try testing.expectEqual(ev.FinishReason.blocked, h.agent.snapshot().last_finish.?);
    try testing.expectEqual(@as(usize, 0), h.agent.messages().len);
    _ = try h.agent.submit(.{ .text = "hi" });
    h.agent.waitIdle();
    try testing.expectEqualStrings("hi\n\nctx", h.agent.messages()[0].content[0].text.text);
}

test "non_retryable_error_keeps_agent_usable" {
    const turns = [_][]const Step{ &.{.{ .fail = error.InvalidRequest }}, script.text("recovered") };
    var h: Harness = undefined;
    try h.init(&turns, .{ .model = "m" }, null);
    defer h.deinit();
    _ = try h.agent.submit(.{ .text = "a" });
    h.agent.waitIdle();
    try testing.expectEqual(ev.FinishReason.failed, h.agent.snapshot().last_finish.?);
    try testing.expect(std.mem.indexOf(u8, h.rec.out.items, "\"error_\"") != null);
    _ = try h.agent.submit(.{ .text = "b" });
    h.agent.waitIdle();
    try testing.expectEqual(ev.FinishReason.end_turn, h.agent.snapshot().last_finish.?);
    const msgs = h.agent.messages();
    try testing.expectEqualStrings("recovered", msgs[msgs.len - 1].content[0].text.text);
}

test "pause_turn_resends" {
    const paused = [_]Step{
        .{ .event = .{ .message_start = .{ .id = "p", .model = "m" } } },
        .{ .event = .{ .block_start = .{ .index = 0, .kind = .text } } },
        .{ .event = .{ .text_delta = .{ .index = 0, .text = "searching" } } },
        .{ .event = .{ .block_stop = .{ .index = 0 } } },
        .{ .event = .{ .stop = .pause_turn } },
    };
    const turns = [_][]const Step{ &paused, script.text("found it") };
    var h: Harness = undefined;
    try h.init(&turns, .{ .model = "m" }, null);
    defer h.deinit();
    _ = try h.agent.submit(.{ .text = "q" });
    h.agent.waitIdle();
    try testing.expectEqual(@as(usize, 2), h.sp.requests().len);
    try testing.expectEqual(@as(usize, 2), h.sp.requests()[1].messages.len);
    try testing.expectEqual(ev.FinishReason.end_turn, h.agent.snapshot().last_finish.?);
}

test "submit_from_multiple_threads" {
    const threads_n = 8;
    const per = 100;
    const turns = [_][]const Step{script.text("r")} ** (threads_n * per);
    var h: Harness = undefined;
    try h.init(&turns, .{ .model = "m" }, null);
    defer h.deinit();
    const Submitter = struct {
        fn run(a: *Agent, t: usize) void {
            var buf: [16]u8 = undefined;
            for (0..per) |i| {
                const text = std.fmt.bufPrint(&buf, "{d}:{d}", .{ t, i }) catch unreachable;
                // The queue holds 64; back off while it is full.
                while (true) {
                    _ = a.submit(.{ .text = text }) catch |e| switch (e) {
                        error.Busy => {
                            io.sleep(.fromMilliseconds(1), .awake) catch {};
                            continue;
                        },
                        else => unreachable,
                    };
                    break;
                }
            }
        }
    };
    var threads: [threads_n]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Submitter.run, .{ h.agent, i });
    for (threads) |t| t.join();
    h.agent.waitIdle();
    const msgs = h.agent.messages();
    try testing.expectEqual(@as(usize, 2 * threads_n * per), msgs.len);
    try testing.expectEqual(@as(u32, threads_n * per), h.rec.finished);
    // FIFO per thread.
    var next = [_]usize{0} ** threads_n;
    for (msgs) |m| if (m.role == .user) {
        var it = std.mem.splitScalar(u8, m.content[0].text.text, ':');
        const t = try std.fmt.parseInt(usize, it.next().?, 10);
        const i = try std.fmt.parseInt(usize, it.next().?, 10);
        try testing.expectEqual(next[t], i);
        next[t] += 1;
    };
}

test "cancel_while_streaming_is_fast_and_history_valid" {
    const turns = [_][]const Step{&.{
        script.text("x")[0],
        script.text("x")[1],
        .{ .event = .{ .text_delta = .{ .index = 0, .text = "half" } } },
        .{ .event = .{ .block_stop = .{ .index = 0 } } },
        .{ .event = .{ .block_start = .{ .index = 1, .kind = .tool_use, .tool_id = "t9", .tool_name = "read" } } },
        .{ .event = .{ .tool_input_delta = .{ .index = 1, .partial_json = "{}" } } },
        .{ .event = .{ .block_stop = .{ .index = 1 } } },
        .{ .delay_ms = 10_000 },
    }};
    var h: Harness = undefined;
    try h.init(&turns, .{ .model = "m" }, null);
    defer h.deinit();
    _ = try h.agent.submit(.{ .text = "go" });
    try h.waitStatus(.streaming);
    try io.sleep(.fromMilliseconds(5), .awake);
    const t0 = std.Io.Timestamp.now(io, .awake);
    h.agent.cancel(.turn);
    try testing.expect(t0.untilNow(io, .awake).toMilliseconds() < 50);
    h.agent.waitIdle();
    try testing.expectEqual(ev.FinishReason.canceled, h.agent.snapshot().last_finish.?);
    const msgs = h.agent.messages();
    try testing.expect(msgs[1].meta.interrupted);
    try expectValidHistory(msgs);
    try testing.expect(msgs[2].content[0].tool_result.is_error);
}

test "cancel_while_running_tools" {
    const turns = [_][]const Step{script.tools(&.{ .{ "t1", "read", "{\"path\":\"a\"}" }, .{ "t2", "read", "{\"path\":\"b\"}" } })};
    var h: Harness = undefined;
    try h.init(&turns, .{ .model = "m" }, null);
    defer h.deinit();
    h.tools.sleep_ms = 10_000;
    _ = try h.agent.submit(.{ .text = "go" });
    try h.waitStatus(.running_tools);
    try io.sleep(.fromMilliseconds(5), .awake);
    const t0 = std.Io.Timestamp.now(io, .awake);
    h.agent.cancel(.turn);
    try testing.expect(t0.untilNow(io, .awake).toMilliseconds() < 50);
    const msgs = h.agent.messages();
    try testing.expectEqual(@as(usize, 3), msgs.len);
    try expectValidHistory(msgs);
    for (msgs[2].content) |b| try testing.expect(b.tool_result.is_error);
    try testing.expectEqual(ev.FinishReason.canceled, h.agent.snapshot().last_finish.?);
}

test "turn_budget_stops_before_next_request" {
    const turns = [_][]const Step{
        script.tools(&.{.{ "t1", "read", "{\"path\":\"a\"}" }}),
        script.text("unreached"),
    };
    var h: Harness = undefined;
    try h.init(&turns, .{ .model = "m", .budgets = .{ .max_turns = 1 } }, null);
    defer h.deinit();
    _ = try h.agent.submit(.{ .text = "go" });
    h.agent.waitIdle();
    try testing.expectEqual(ev.FinishReason.budget, h.agent.snapshot().last_finish.?);
    try testing.expectEqual(@as(usize, 1), h.sp.requests().len);
    try testing.expect(std.mem.indexOf(u8, h.rec.out.items, "\"level\":\"stop\"") != null);
    try expectValidHistory(h.agent.messages());
}

const AgentManager = @import("Manager.zig");

/// Counts events per agent number.
const AllCounter = struct {
    mutex: std.Io.Mutex = .init,
    per_agent: [4]u32 = .{ 0, 0, 0, 0 },

    fn on(ctx: *anyopaque, ref: proto.AgentRef, batch: []const ev.Envelope) void {
        const c: *AllCounter = @ptrCast(@alignCast(ctx));
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        c.per_agent[ref.agent] += @intCast(batch.len);
    }
};

test "manager_create_list_get_dispose" {
    const turns = [_][]const Step{ script.text("main"), script.text("sub") };
    var h: Harness = undefined;
    try h.init(&turns, .{ .model = "m" }, null);
    defer h.deinit();
    const m = try AgentManager.init(testing.allocator, io, h.agentDeps(null));
    defer m.deinit();
    var counter: AllCounter = .{};
    try m.subscribeAll(.{ .ctx = &counter, .on_events = AllCounter.on, .mode = .inline_ });

    const main = try m.create(.{ .model = "m" });
    try testing.expectEqual(@as(u32, 0), main.ref.agent);
    const sub = try m.create(.{ .model = "m", .parent = main.ref, .spawned_by = "toolu_9" });
    try testing.expectEqual(main.ref.session, sub.ref.session);
    try testing.expectEqual(@as(u32, 1), sub.ref.agent);
    try testing.expectEqualStrings("toolu_9", sub.ref.tool_call.?);
    try testing.expectEqual(sub, m.get(sub.ref).?);
    try testing.expectError(error.UnknownParent, m.create(.{ .model = "m", .parent = .{ .session = 42 } }));

    _ = try main.submit(.{ .text = "hi" });
    main.waitIdle();
    _ = try sub.submit(.{ .text = "sub task" });
    sub.waitIdle();
    try testing.expect(counter.per_agent[0] > 0 and counter.per_agent[1] > 0);

    var out: std.ArrayList(AgentManager.AgentSummary) = .empty;
    defer out.deinit(testing.allocator);
    try m.list(testing.allocator, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u32, 1), out.items[0].turns);
    try testing.expectEqual(main.ref.agent, out.items[1].parent.?.agent);

    // Disposing the parent disposes the child first.
    m.dispose(main);
    try testing.expectEqual(@as(usize, 0), m.count());
}

test "dispose_awaits_group_no_leak" {
    const turns = [_][]const Step{ &.{.{ .delay_ms = 10_000 }}, &.{.{ .delay_ms = 10_000 }} };
    var h: Harness = undefined;
    try h.init(&turns, .{ .model = "m" }, null);
    defer h.deinit();
    const m = try AgentManager.init(testing.allocator, io, h.agentDeps(null));
    defer m.deinit();
    const main = try m.create(.{ .model = "m" });
    const sub = try m.create(.{ .model = "m", .parent = main.ref });
    _ = try main.submit(.{ .text = "busy" });
    _ = try sub.submit(.{ .text = "busy too" });
    _ = try main.submit(.{ .text = "queued" });
    var n: u32 = 0;
    while (sub.snapshot().status != .thinking or main.snapshot().status != .thinking) : (n += 1) {
        if (n > 5000) return error.Timeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    const t0 = std.Io.Timestamp.now(io, .awake);
    m.dispose(main);
    try testing.expect(t0.untilNow(io, .awake).toMilliseconds() < 50);
    try testing.expectEqual(@as(usize, 0), m.count());
}

test "cancel_everything_cascades_subagents" {
    const turns = [_][]const Step{ &.{.{ .delay_ms = 10_000 }}, &.{.{ .delay_ms = 10_000 }} };
    var h: Harness = undefined;
    try h.init(&turns, .{ .model = "m" }, null);
    defer h.deinit();
    const m = try AgentManager.init(testing.allocator, io, h.agentDeps(null));
    defer m.deinit();
    const main = try m.create(.{ .model = "m" });
    const sub = try m.create(.{ .model = "m", .parent = main.ref });
    _ = try main.submit(.{ .text = "a" });
    _ = try sub.submit(.{ .text = "b" });
    var n: u32 = 0;
    while (sub.snapshot().status != .thinking or main.snapshot().status != .thinking) : (n += 1) {
        if (n > 5000) return error.Timeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    main.cancel(.everything);
    try testing.expectEqual(ev.FinishReason.canceled, sub.snapshot().last_finish.?);
    try testing.expectEqual(ev.FinishReason.canceled, main.snapshot().last_finish.?);
}
