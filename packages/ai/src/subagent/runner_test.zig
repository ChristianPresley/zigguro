//! Tests for subagent definitions, the runner and the `task` tool
//! (E10.F09.S01.T01). The parent plays a script; children are answered by
//! a router that echoes their delegation prompt, so parallel children
//! need no ordering.

const std = @import("std");
const proto = @import("zg_ai_proto");
const golden = @import("zg_core").testkit.golden;
const defs = @import("defs.zig");
const runner = @import("runner.zig");
const task_tool = @import("task_tool.zig");
const Agent = @import("../loop/Agent.zig");
const AgentManager = @import("../loop/Manager.zig");
const ev = @import("../loop/events.zig");
const reg_mod = @import("../models/registry.zig");
const scripted = @import("../provider/scripted.zig");
const Provider = @import("../provider/Provider.zig");
const request = @import("../provider/request.zig");
const pevents = @import("../provider/events.zig");
const MessageAssembler = @import("../provider/assembler.zig").MessageAssembler;
const tool_registry = @import("../tools/registry.zig");
const toolset = @import("../tools/toolset.zig");

const testing = std.testing;
const io = testing.io;
const Allocator = std.mem.Allocator;
const script = scripted.script;
const Step = scripted.ScriptedProvider.Step;

const catalog: [:0]const u8 =
    \\.{
    \\    .retrieved = "test",
    \\    .models = .{
    \\        .{ .id = "m", .context_window = 200_000, .max_output = 32_000, .base = .claude,
    \\           .price = .{ .input_per_mtok_micros = 3_000_000, .output_per_mtok_micros = 15_000_000 } },
    \\        .{ .id = "mini", .context_window = 200_000, .max_output = 32_000, .base = .claude,
    \\           .price = .{ .input_per_mtok_micros = 1_000_000, .output_per_mtok_micros = 5_000_000 } },
    \\    },
    \\}
;

/// Requests whose first user message starts with `SUB:` are children's:
/// they get `Report: <prompt>` (or the behaviour the prompt names);
/// everything else goes to the parent's script.
const Router = struct {
    parent: *scripted.ScriptedProvider,
    mutex: std.Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    child_requests: std.ArrayList(request.Request) = .empty,
    running: u32 = 0,
    max_running: u32 = 0,

    fn provider(r: *Router) Provider {
        return .{ .ptr = r, .vtable = &.{ .stream = stream, .deinit = deinitFn }, .id = .scripted, .caps = .all };
    }

    fn deinitFn(_: *anyopaque) void {}

    fn firstUser(req: *const request.Request) []const u8 {
        for (req.messages) |m| if (m.role == .user) for (m.content) |b| if (b == .text) return b.text.text;
        return "";
    }

    fn stream(ptr: *anyopaque, x: std.Io, arena: Allocator, req: *const request.Request, sink: pevents.EventSink) Provider.StreamError!request.Response {
        const r: *Router = @ptrCast(@alignCast(ptr));
        const prompt = firstUser(req);
        if (!std.mem.startsWith(u8, prompt, "SUB:")) return r.parent.provider().stream(x, arena, req, sink);
        {
            try r.mutex.lock(x);
            defer r.mutex.unlock(x);
            r.child_requests.append(r.arena.allocator(), scripted.cloneRequest(r.arena.allocator(), req.*) catch return error.OutOfMemory) catch return error.OutOfMemory;
            r.running += 1;
            r.max_running = @max(r.max_running, r.running);
        }
        defer {
            r.mutex.lockUncancelable(x);
            r.running -= 1;
            r.mutex.unlock(x);
        }
        if (std.mem.startsWith(u8, prompt, "SUB:slow")) try x.sleep(.fromMilliseconds(30), .awake);
        if (std.mem.startsWith(u8, prompt, "SUB:block")) try x.sleep(.fromSeconds(60), .awake);
        const text = if (std.mem.startsWith(u8, prompt, "SUB:long"))
            "first line of a long answer\n" ++ ("x" ** 200)
        else
            std.fmt.allocPrint(arena, "Report: {s}", .{prompt[4..]}) catch return error.OutOfMemory;
        const evs = [_]pevents.StreamEvent{
            .{ .message_start = .{ .id = "msg_child", .model = req.model } },
            .{ .block_start = .{ .index = 0, .kind = .text } },
            .{ .text_delta = .{ .index = 0, .text = text } },
            .{ .block_stop = .{ .index = 0 } },
            .{ .usage = .{ .input = 10, .output = 5 } },
            .{ .stop = .end_turn },
        };
        var asm_: MessageAssembler = .init(arena);
        for (evs) |e| {
            asm_.feed(e) catch return error.Protocol;
            sink.send(e);
        }
        const msg = asm_.finish() catch return error.Protocol;
        return .{ .message = msg, .stop = .end_turn, .usage = asm_.usage };
    }
};

/// A read-only and a writing tool besides `task`.
const Plain = struct {
    specs: [2]proto.ToolSpec = undefined,

    fn source(p: *Plain) tool_registry.ToolSource {
        const schema = "{\"type\":\"object\"}";
        p.specs = .{
            .{ .name = "read_file", .description = "Reads.", .input_schema_json = schema, .read_only = true, .handler = .{ .ctx = p, .call = ok } },
            .{ .name = "edit_file", .description = "Edits.", .input_schema_json = schema, .read_only = false, .effects = .{ .writes_workspace = true }, .handler = .{ .ctx = p, .call = ok } },
        };
        return .{ .name = "plain", .ctx = p, .list = list, .kind = .builtin };
    }

    fn list(ctx: *anyopaque, gpa: Allocator, out: *std.ArrayList(proto.ToolSpec)) anyerror!void {
        const p: *Plain = @ptrCast(@alignCast(ctx));
        try out.appendSlice(gpa, &p.specs);
    }

    fn ok(_: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        return proto.ToolOutput.text(c.arena, "ok", false) catch error.OutOfMemory;
    }
};

const Harness = struct {
    registry: reg_mod.ModelRegistry,
    sp: *scripted.ScriptedProvider,
    router: Router,
    provider: Provider,
    tools: tool_registry.ToolRegistry,
    plain: Plain = .{},
    main_tools: toolset.AgentTools,
    mgr: *AgentManager,
    arena: std.heap.ArenaAllocator,
    definitions: std.ArrayList(defs.AgentDef) = .empty,
    runner: runner.SubagentRunner,
    task: task_tool.TaskTool,
    parent: *Agent,

    fn init(h: *Harness, turns: []const []const Step, cfg: runner.Config, extra: []const defs.AgentDef) !void {
        h.registry = .init(testing.allocator, io, catalog);
        h.sp = try .init(testing.allocator, turns, .all);
        h.router = .{ .parent = h.sp, .arena = .init(testing.allocator) };
        h.provider = h.router.provider();
        h.arena = .init(testing.allocator);
        h.definitions = .empty;
        try h.definitions.appendSlice(h.arena.allocator(), extra);
        try defs.loadDefs(io, h.arena.allocator(), &.{}, &h.definitions, null);
        h.tools = .init(testing.allocator, io);
        try h.tools.addSource(h.plain.source());
        h.main_tools = .init(testing.allocator, io, &h.tools, .{});
        h.main_tools.warn_invalidations = false;
        h.mgr = try AgentManager.init(testing.allocator, io, .{ .registry = &h.registry, .providers = .fixed(&h.provider), .tools = h.main_tools.tools() });
        h.runner = .init(testing.allocator, io, h.mgr, &h.tools, h.definitions.items, cfg);
        h.runner.main_tools = &h.main_tools;
        h.task = try .init(testing.allocator, &h.runner);
        try h.tools.addSource(h.task.source());
        h.parent = try h.mgr.create(.{ .model = "m" });
    }

    fn deinit(h: *Harness) void {
        h.runner.deinit();
        h.mgr.deinit();
        h.task.deinit();
        h.main_tools.deinit();
        h.tools.deinit();
        h.sp.destroy();
        h.router.arena.deinit();
        h.registry.deinit();
        h.arena.deinit();
    }

    fn run(h: *Harness, text: []const u8) !void {
        _ = try h.parent.submit(.{ .text = text });
        h.parent.waitIdle();
    }

    /// The tool results of the parent's last tool turn, in call order.
    fn results(h: *Harness) []const proto.ContentBlock {
        const msgs = h.parent.messages();
        var i = msgs.len;
        while (i > 0) {
            i -= 1;
            if (msgs[i].role == .user and msgs[i].content.len > 0 and msgs[i].content[0] == .tool_result) return msgs[i].content;
        }
        return &.{};
    }

    fn def(h: *Harness, name: []const u8) *const defs.AgentDef {
        return defs.find(h.definitions.items, name).?;
    }
};

fn resultText(b: proto.ContentBlock) []const u8 {
    return b.tool_result.parts[0].text;
}

fn toolNames(a: *Agent, arena: Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (a.deps.tools.list()) |s| {
        if (out.items.len > 0) try out.append(arena, ',');
        try out.appendSlice(arena, s.name);
    }
    return out.items;
}

const three = script.tools(&.{
    .{ "t1", "task", "{\"agent\":\"explore\",\"prompt\":\"SUB:where is main\",\"thoroughness\":\"quick\"}" },
    .{ "t2", "task", "{\"agent\":\"explore\",\"prompt\":\"SUB:who calls parse\"}" },
    .{ "t3", "task", "{\"agent\":\"explore\",\"prompt\":\"SUB:what tests exist\"}" },
});

/// Structural parent events, without the ones whose order depends on
/// which child finishes first.
const Log = struct {
    mutex: std.Io.Mutex = .init,
    out: std.ArrayList(u8) = .empty,
    n: u64 = 0,

    fn sub(l: *Log) @import("../loop/bus.zig").Subscriber {
        return .{ .ctx = l, .on_events = on, .mode = .inline_ };
    }

    fn on(ctx: *anyopaque, batch: []const ev.Envelope) void {
        const l: *Log = @ptrCast(@alignCast(ctx));
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        for (batch) |e| switch (e.ev) {
            .tool_started, .tool_finished, .tool_progress, .stream, .usage, .status, .request_sent => {},
            else => {
                l.n += 1;
                var w: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &l.out);
                ev.writeJson(&w.writer, .{ .seq = l.n, .ev = e.ev }) catch {};
                w.writer.writeByte('\n') catch {};
                l.out = w.toArrayList();
            },
        };
    }
};

test "parallel_three_explore" {
    var h: Harness = undefined;
    try h.init(&.{ three, script.text("All three answered.") }, .{}, &.{});
    defer h.deinit();
    var log: Log = .{};
    defer log.out.deinit(testing.allocator);
    _ = try h.parent.subscribe(log.sub());
    try h.run("Explore the repo.");

    const rs = h.results();
    try testing.expectEqual(@as(usize, 3), rs.len);
    try testing.expectEqualStrings("Report: where is main\n\n[agent explore · 0 tool calls · 15 tokens · $0.00 · files read: 0]", resultText(rs[0]));
    try testing.expect(std.mem.startsWith(u8, resultText(rs[1]), "Report: who calls parse\n"));
    try testing.expect(std.mem.startsWith(u8, resultText(rs[2]), "Report: what tests exist\n"));
    try testing.expectEqual(@as(usize, 3), h.router.child_requests.items.len);
    // Children run the cheap model and are gone afterwards.
    for (h.router.child_requests.items) |r| try testing.expectEqualStrings("mini", r.model);
    try testing.expectEqual(@as(usize, 1), h.mgr.count());
    // Thoroughness reaches the child's system prompt.
    var quick = false;
    for (h.router.child_requests.items) |r| for (r.system) |s| {
        quick = quick or std.mem.indexOf(u8, s.text, "Thoroughness: quick.") != null;
    };
    try testing.expect(quick);

    // The second request carries all three reports.
    const last = h.sp.requests()[1];
    var hits: usize = 0;
    for (last.messages[last.messages.len - 1].content) |b| if (b == .tool_result) {
        hits += 1;
    };
    try testing.expectEqual(@as(usize, 3), hits);
    try golden.expectGoldenOpts(io, @src(), "parallel_three_explore.events", log.out.items, .{ .root = @import("zg_options").package_root, .dir = "testdata/subagent" });
}

test "depth_limit_withholds_task" {
    var h: Harness = undefined;
    try h.init(&.{}, .{ .max_depth = 2 }, &.{});
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Depth 1 may still delegate; depth 2 may not.
    const c1 = try h.runner.spawn(h.parent, h.def("general"), "SUB:one", .{});
    try testing.expectEqual(@as(u8, 1), c1.cfg.depth);
    try testing.expect(std.mem.indexOf(u8, try toolNames(c1, a), "task") != null);
    const c2 = try h.runner.spawn(c1, h.def("general"), "SUB:two", .{});
    try testing.expectEqual(@as(u8, 2), c2.cfg.depth);
    try testing.expectEqualStrings("read_file,edit_file", try toolNames(c2, a));
    _ = try h.runner.awaitReport(io, a, c2);
    _ = try h.runner.awaitReport(io, a, c1);
    // Explore is read-only by its tool list.
    const e = try h.runner.spawn(h.parent, h.def("explore"), "SUB:three", .{});
    try testing.expectEqualStrings("read_file", try toolNames(e, a));
    _ = try h.runner.awaitReport(io, a, e);
}

test "concurrency_semaphore" {
    var h: Harness = undefined;
    try h.init(&.{
        script.tools(&.{
            .{ "t1", "task", "{\"agent\":\"explore\",\"prompt\":\"SUB:slow 1\"}" },
            .{ "t2", "task", "{\"agent\":\"explore\",\"prompt\":\"SUB:slow 2\"}" },
            .{ "t3", "task", "{\"agent\":\"explore\",\"prompt\":\"SUB:slow 3\"}" },
            .{ "t4", "task", "{\"agent\":\"explore\",\"prompt\":\"SUB:slow 4\"}" },
            .{ "t5", "task", "{\"agent\":\"explore\",\"prompt\":\"SUB:slow 5\"}" },
        }),
        script.text("done"),
    }, .{ .max_concurrent = 2 }, &.{});
    defer h.deinit();
    try h.run("Go.");
    try testing.expectEqual(@as(usize, 5), h.router.child_requests.items.len);
    try testing.expectEqual(@as(u32, 2), h.router.max_running);
    for (h.results()) |b| try testing.expect(!b.tool_result.is_error);
}

test "child_has_no_parent_history" {
    var h: Harness = undefined;
    try h.init(&.{
        script.text("Noted the secret."),
        script.tools(&.{.{ "t1", "task", "{\"agent\":\"explore\",\"prompt\":\"SUB:find it\"}" }}),
        script.text("ok"),
    }, .{}, &.{});
    defer h.deinit();
    try h.run("The password is SECRET-PARENT.");
    try h.run("Now delegate.");
    const r = h.router.child_requests.items[0];
    try testing.expectEqual(@as(usize, 1), r.messages.len);
    try testing.expectEqualStrings("SUB:find it", r.messages[0].content[0].text.text);
    var sys: std.ArrayList(u8) = .empty;
    defer sys.deinit(testing.allocator);
    for (r.system) |s| try sys.appendSlice(testing.allocator, s.text);
    try testing.expect(std.mem.indexOf(u8, sys.items, "You are an explore agent") != null);
    try testing.expect(std.mem.indexOf(u8, sys.items, "SECRET-PARENT") == null);
    // The child is linked to the parent's call.
    try testing.expectEqual(@as(usize, 1), h.router.child_requests.items.len);
}

test "inherit_model_and_plan_mode" {
    const custom = [_]defs.AgentDef{
        .{ .name = "editor", .description = "Edits.", .prompt = "You edit.", .model = "mini", .permission_mode = .accept_edits, .source = .project },
    };
    var h: Harness = undefined;
    try h.init(&.{}, .{}, &custom);
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try h.runner.spawn(h.parent, h.def("general"), "SUB:g", .{});
    try testing.expectEqualStrings("m", g.cfg.model);
    try testing.expectEqual(.default, h.runner.modeOf(g.ref));
    const ed = try h.runner.spawn(h.parent, h.def("editor"), "SUB:e", .{});
    try testing.expectEqualStrings("mini", ed.cfg.model);
    try testing.expectEqual(.accept_edits, h.runner.modeOf(ed.ref));
    _ = try h.runner.awaitReport(io, a, g);
    _ = try h.runner.awaitReport(io, a, ed);

    // A plan-mode parent forces plan mode, which hides writing tools.
    h.main_tools.setMode(.plan);
    const p = try h.runner.spawn(h.parent, h.def("editor"), "SUB:p", .{});
    try testing.expectEqual(.plan, h.runner.modeOf(p.ref));
    try testing.expectEqualStrings("read_file,task", try toolNames(p, a));
    _ = try h.runner.awaitReport(io, a, p);

    try testing.expectError(error.UnknownModel, runner.resolveModel(&h.registry, "nope", "m"));
}

test "report_truncation_and_trailer" {
    var h: Harness = undefined;
    try h.init(&.{}, .{ .max_report_tokens = 10 }, &.{});
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try h.runner.spawn(h.parent, h.def("general"), "SUB:long", .{});
    const r = try h.runner.awaitReport(io, arena.allocator(), c);
    try testing.expect(r.truncated);
    try testing.expectEqualStrings("first line of a long answer\n[report truncated]\n\n[agent general · 0 tool calls · 15 tokens · $0.00 · files read: 0]", r.text);
    try testing.expectEqual(@as(u64, 15), r.tokens);
    try testing.expectEqual(ev.FinishReason.end_turn, r.finish.?);
}

const FakeLanes = struct {
    created: std.ArrayList([]const u8) = .empty,
    finished: u32 = 0,
    arena: std.heap.ArenaAllocator,

    fn lanes(f: *FakeLanes) runner.Lanes {
        return .{ .ctx = f, .create = create, .finish = finish };
    }

    fn create(ctx: *anyopaque, _: std.Io, arena: Allocator, name: []const u8, _: proto.AgentRef) anyerror!runner.Lane {
        const f: *FakeLanes = @ptrCast(@alignCast(ctx));
        try f.created.append(f.arena.allocator(), try f.arena.allocator().dupe(u8, name));
        return .{ .path = try std.fmt.allocPrint(arena, "/repo/.zg/lanes/{s}", .{name}), .handle = name };
    }

    fn finish(ctx: *anyopaque, _: std.Io, _: []const u8) anyerror!bool {
        const f: *FakeLanes = @ptrCast(@alignCast(ctx));
        f.finished += 1;
        return true;
    }
};

test "workspace_isolation_uses_e09" {
    const custom = [_]defs.AgentDef{
        .{ .name = "worker", .description = "Works alone.", .prompt = "You work.", .isolation = .workspace, .source = .project },
    };
    var h: Harness = undefined;
    try h.init(&.{}, .{}, &custom);
    defer h.deinit();
    var lanes: FakeLanes = .{ .arena = .init(testing.allocator) };
    defer lanes.arena.deinit();
    h.runner.lanes = lanes.lanes();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const c = try h.runner.spawn(h.parent, h.def("worker"), "SUB:w", .{});
    const sid = proto.agent_ref.format(h.parent.ref.session);
    const name = try std.fmt.allocPrint(arena.allocator(), "agent-{s}-1", .{&sid});
    try testing.expectEqualStrings(name, lanes.created.items[0]);
    try testing.expect(std.mem.endsWith(u8, c.cfg.cwd, name));
    const r = try h.runner.awaitReport(io, arena.allocator(), c);
    try testing.expectEqualStrings(name, r.workspace_handle.?);
    try testing.expect(std.mem.endsWith(u8, r.text, try std.fmt.allocPrint(arena.allocator(), " · workspace {s}]", .{name})));
    try testing.expectEqual(@as(u32, 1), lanes.finished);
    // Shared definitions get no lane.
    const g = try h.runner.spawn(h.parent, h.def("general"), "SUB:g", .{});
    _ = try h.runner.awaitReport(io, arena.allocator(), g);
    try testing.expectEqual(@as(usize, 1), lanes.created.items.len);
}

test "cancel_parent_cascades" {
    var h: Harness = undefined;
    try h.init(&.{script.tools(&.{
        .{ "t1", "task", "{\"agent\":\"general\",\"prompt\":\"SUB:block a\"}" },
        .{ "t2", "task", "{\"agent\":\"general\",\"prompt\":\"SUB:block b\"}" },
    })}, .{}, &.{});
    defer h.deinit();
    _ = try h.parent.submit(.{ .text = "Go." });
    // Wait for both children to be streaming.
    while (true) {
        h.router.mutex.lockUncancelable(io);
        const n = h.router.running;
        h.router.mutex.unlock(io);
        if (n == 2) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    const t0 = std.Io.Timestamp.now(io, .awake);
    h.parent.cancel(.everything);
    h.parent.waitIdle();
    try testing.expect(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 5_000);
    try testing.expectEqual(@as(usize, 1), h.mgr.count());
    try testing.expectEqual(ev.FinishReason.canceled, h.parent.snapshot().last_finish.?);
}

test "task tool errors" {
    var h: Harness = undefined;
    try h.init(&.{
        script.tools(&.{.{ "t1", "task", "{\"agent\":\"nobody\",\"prompt\":\"SUB:x\"}" }}),
        script.text("ok"),
    }, .{}, &.{});
    defer h.deinit();
    try h.run("Go.");
    const r = h.results()[0];
    try testing.expect(r.tool_result.is_error);
    try testing.expectEqualStrings("Unknown agent nobody. Available: explore, plan, general.", resultText(r));
    try testing.expect(std.mem.indexOf(u8, h.task.description, "- explore: Fast read-only search") != null);
}

test "defs_precedence_and_compat_aliases" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "user");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/explore.md", .data =
        \\---
        \\name: explore
        \\description: Project explore.
        \\tools: Read, Grep, Bash
        \\disallowedTools: [WebFetch]
        \\model: haiku
        \\maxTurns: 7
        \\isolation: workspace
        \\effort: low
        \\---
        \\Project explore prompt.
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "user/explore.md", .data = "---\nname: explore\ndescription: User explore.\n---\nUser prompt.\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "user/reviewer.md", .data = "---\nname: reviewer\ndescription: Reviews.\npermission-mode: plan\ntools:\n  - Read\n  - Glob\n---\nReview carefully.\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "user/broken.md", .data = "---\nname: bad:name\ndescription: x\n---\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "user/nodesc.md", .data = "---\nname: nodesc\n---\nbody\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "user/notes.txt", .data = "ignored" });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const project = try std.fs.path.join(a, &.{ root, "project" });
    const user = try std.fs.path.join(a, &.{ root, "user" });

    var out: std.ArrayList(defs.AgentDef) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    try defs.loadDefs(io, a, &.{ .{ .dir = project, .source = .project }, .{ .dir = user, .source = .user }, .{ .dir = "/no/such/dir", .source = .user } }, &out, &warnings);

    var names: std.ArrayList(u8) = .empty;
    for (out.items) |d| try names.print(a, "{s}:{s} ", .{ d.name, @tagName(d.source) });
    try testing.expectEqualStrings("explore:project reviewer:user plan:builtin general:builtin ", names.items);
    try testing.expectEqual(@as(usize, 2), warnings.items.len);
    try testing.expect(std.mem.endsWith(u8, warnings.items[0], "broken.md: name must be 1-64 characters without ':'"));
    try testing.expect(std.mem.endsWith(u8, warnings.items[1], "nodesc.md: description"));

    const e = out.items[0];
    try testing.expectEqualStrings("Project explore.", e.description);
    try testing.expectEqual(@as(usize, 3), e.tools.?.len);
    try testing.expectEqualStrings("read_file", e.tools.?[0]);
    try testing.expectEqualStrings("grep", e.tools.?[1]);
    try testing.expectEqualStrings("run_command", e.tools.?[2]);
    try testing.expectEqualStrings("web_fetch", e.disallowed_tools[0]);
    try testing.expectEqualStrings("haiku", e.model.?);
    try testing.expectEqual(@as(u32, 7), e.max_turns.?);
    try testing.expectEqual(defs.Isolation.workspace, e.isolation);
    try testing.expectEqual(request.Effort.low, e.effort.?);
    // The body is read when needed.
    try testing.expectEqualStrings("", e.prompt);
    try testing.expectEqualStrings("Project explore prompt.", try e.body(io, a));

    const rv = out.items[1];
    try testing.expectEqual(.plan, rv.permission_mode.?);
    try testing.expectEqualStrings("glob", rv.tools.?[1]);
    // Built-ins carry their prompt.
    try testing.expect(std.mem.startsWith(u8, out.items[2].prompt, "You are a planning research agent."));
}
