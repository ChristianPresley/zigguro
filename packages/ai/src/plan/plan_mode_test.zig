//! Tests for plan mode (E10.F09.S02.T01): the plan toolset, the command
//! allowlist, the pipeline double check and `exit_plan_mode` approval.

const std = @import("std");
const proto = @import("zg_ai_proto");
const golden = @import("zg_core").testkit.golden;
const plan_mode = @import("plan_mode.zig");
const Agent = @import("../loop/Agent.zig");
const AgentManager = @import("../loop/Manager.zig");
const ev = @import("../loop/events.zig");
const reg_mod = @import("../models/registry.zig");
const scripted = @import("../provider/scripted.zig");
const Provider = @import("../provider/Provider.zig");
const assembler = @import("../context/assembler.zig");
const compactor = @import("../context/compactor.zig");
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
    \\    },
    \\}
;

/// `read_file`, `edit_file` and `run_command`; each call is logged so a
/// test can see what actually ran.
const Tools = struct {
    specs: [3]proto.ToolSpec = undefined,
    mutex: std.Io.Mutex = .init,
    ran: std.ArrayList(u8) = .empty,

    fn source(p: *Tools) tool_registry.ToolSource {
        const schema = "{\"type\":\"object\"}";
        p.specs = .{
            .{ .name = "read_file", .description = "Reads.", .input_schema_json = schema, .read_only = true, .handler = .{ .ctx = p, .call = ok } },
            .{ .name = "edit_file", .description = "Edits.", .input_schema_json = schema, .read_only = false, .effects = .{ .writes_workspace = true }, .handler = .{ .ctx = p, .call = ok } },
            .{ .name = "run_command", .description = "Runs.", .input_schema_json = schema, .read_only = false, .effects = .{ .executes = true }, .handler = .{ .ctx = p, .call = ok } },
        };
        return .{ .name = "plain", .ctx = p, .list = list, .kind = .builtin };
    }

    fn list(ctx: *anyopaque, gpa: Allocator, out: *std.ArrayList(proto.ToolSpec)) anyerror!void {
        const p: *Tools = @ptrCast(@alignCast(ctx));
        try out.appendSlice(gpa, &p.specs);
    }

    fn ok(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const p: *Tools = @ptrCast(@alignCast(ctx));
        p.mutex.lockUncancelable(c.io);
        defer p.mutex.unlock(c.io);
        p.ran.print(testing.allocator, "{s} {s}\n", .{ c.name, c.input_json }) catch return error.OutOfMemory;
        return proto.ToolOutput.text(c.arena, "ok", false) catch error.OutOfMemory;
    }
};

/// Answers every plan with `answer`; remembers the plans it saw.
const FixedApprover = struct {
    answer: plan_mode.Answer,
    seen: u32 = 0,

    fn approver(f: *FixedApprover) plan_mode.Approver {
        return .{ .ctx = f, .ask = ask };
    }

    fn ask(ctx: *anyopaque, _: std.Io, _: Allocator, _: []const u8) std.Io.Cancelable!plan_mode.Answer {
        const f: *FixedApprover = @ptrCast(@alignCast(ctx));
        f.seen += 1;
        return f.answer;
    }
};

const Title = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,
    fn sink(t: *Title) plan_mode.TitleSink {
        return .{ .ctx = t, .set = set };
    }
    fn set(ctx: *anyopaque, title: []const u8) void {
        const t: *Title = @ptrCast(@alignCast(ctx));
        @memcpy(t.buf[0..title.len], title);
        t.len = title.len;
    }
};

const Harness = struct {
    registry: reg_mod.ModelRegistry,
    sp: *scripted.ScriptedProvider,
    provider: Provider,
    reg: tool_registry.ToolRegistry,
    tools: Tools = .{},
    agent_tools: toolset.AgentTools,
    mgr: *AgentManager,
    agent: *Agent,
    approver: FixedApprover,
    state: assembler.State = .{ .env = .{ .cwd = ".", .now_ms = 0 } },
    loop_compaction: compactor.LoopCompaction = .{ .compactor = undefined },
    title: Title = .{},
    tmp: testing.TmpDir,
    ws_buf: [128]u8 = undefined,
    pm: plan_mode.PlanMode,

    fn init(h: *Harness, turns: []const []const Step, answer: plan_mode.Answer) !void {
        h.* = .{ .registry = undefined, .sp = undefined, .provider = undefined, .reg = undefined, .agent_tools = undefined, .mgr = undefined, .agent = undefined, .approver = .{ .answer = answer }, .tmp = testing.tmpDir(.{}), .pm = undefined };
        h.registry = .init(testing.allocator, io, catalog);
        h.sp = try .init(testing.allocator, turns, .all);
        h.provider = h.sp.provider();
        h.reg = .init(testing.allocator, io);
        try h.reg.addSource(h.tools.source());
        h.agent_tools = .init(testing.allocator, io, &h.reg, .{});
        h.agent_tools.warn_invalidations = false;
        h.mgr = try AgentManager.init(testing.allocator, io, .{ .registry = &h.registry, .providers = .fixed(&h.provider), .tools = h.agent_tools.tools() });
        h.agent = try h.mgr.create(.{ .model = "m" });
        const ws = try std.fmt.bufPrint(&h.ws_buf, ".zig-cache/tmp/{s}", .{&h.tmp.sub_path});
        h.pm = .init(testing.allocator, h.agent, ws, h.approver.approver(), .{
            .tools = &h.agent_tools,
            .state = &h.state,
            .compaction = &h.loop_compaction,
            .title = h.title.sink(),
        });
        try h.reg.addSource(h.pm.source());
        h.pm.enter();
    }

    fn deinit(h: *Harness) void {
        h.mgr.deinit();
        h.pm.deinit();
        h.agent_tools.deinit();
        h.reg.deinit();
        h.sp.destroy();
        h.registry.deinit();
        h.tools.ran.deinit(testing.allocator);
        h.tmp.cleanup();
    }

    fn run(h: *Harness, text: []const u8) !void {
        _ = try h.agent.submit(.{ .text = text });
        h.agent.waitIdle();
    }

    fn results(h: *Harness) []const proto.ContentBlock {
        const msgs = h.agent.messages();
        var i = msgs.len;
        while (i > 0) {
            i -= 1;
            if (msgs[i].role == .user and msgs[i].content.len > 0 and msgs[i].content[0] == .tool_result) return msgs[i].content;
        }
        return &.{};
    }

    fn names(h: *Harness, arena: Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (h.agent.deps.tools.list()) |s| {
            if (out.items.len > 0) try out.append(arena, ',');
            try out.appendSlice(arena, s.name);
        }
        return out.items;
    }
};

fn resultText(b: proto.ContentBlock) []const u8 {
    return b.tool_result.parts[0].text;
}

const plan_text = "# Rename parse to decode\n\n1. Rename in src/parse.zig.\n2. Update callers.\n3. Run zig build test.\n";

fn exitCall(comptime plan: []const u8) []const Step {
    return script.tools(&.{.{ "p1", "exit_plan_mode", "{\"plan\":" ++ std.fmt.comptimePrint("{f}", .{std.json.fmt(plan, .{})}) ++ "}" }});
}

test "plan_toolset_read_only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var h: Harness = undefined;
    try h.init(&.{}, .{ .decision = .{ .keep_planning = null } });
    defer h.deinit();
    try testing.expectEqualStrings("read_file,run_command,exit_plan_mode", try h.names(arena.allocator()));
    try testing.expect(h.agent.plan_mode.load(.acquire));
    try testing.expectEqual(assembler.Mode.plan, h.state.mode);
    h.pm.leave(.accept_edits);
    try testing.expectEqualStrings("read_file,edit_file,run_command,exit_plan_mode", try h.names(arena.allocator()));
    try testing.expect(!h.agent.plan_mode.load(.acquire));
    try testing.expectEqual(assembler.Mode.accept_edits, h.state.mode);
}

test "readonly_commands_allowed_others_absent" {
    var h: Harness = undefined;
    try h.init(&.{
        script.tools(&.{
            .{ "c1", "run_command", "{\"command\":\"git status\"}" },
            .{ "c2", "edit_file", "{\"path\":\"a\"}" },
        }),
        script.tools(&.{.{ "c3", "run_command", "{\"command\":\"rm -rf src\"}" }}),
        script.tools(&.{.{ "c4", "run_command", "{\"command\":\"ls\",\"background\":true}" }}),
        script.text("Plan: later."),
    }, .{ .decision = .{ .keep_planning = null } });
    defer h.deinit();
    try h.run("Plan it.");
    const reqs = h.sp.requests();
    try testing.expectEqual(@as(usize, 4), reqs.len);
    const first = lastResults(reqs[1]);
    try testing.expectEqualStrings("ok", resultText(first[0]));
    try testing.expectEqualStrings("Unknown tool: edit_file", resultText(first[1]));
    try testing.expect(std.mem.startsWith(u8, resultText(lastResults(reqs[2])[0]), "Plan mode is read-only: run_command was not run"));
    try testing.expect(std.mem.startsWith(u8, resultText(lastResults(reqs[3])[0]), "Plan mode is read-only: run_command was not run"));
    try testing.expectEqualStrings("run_command {\"command\":\"git status\"}\n", h.tools.ran.items);
}

fn lastResults(req: @import("../provider/request.zig").Request) []const proto.ContentBlock {
    return req.messages[req.messages.len - 1].content;
}

test "pipeline refuses a declared mutating tool in plan mode" {
    // The toolset still declares edit_file (as if the filter were bypassed);
    // the invoke pipeline refuses it anyway.
    var h: Harness = undefined;
    try h.init(&.{
        script.tools(&.{.{ "e1", "edit_file", "{\"path\":\"a\"}" }}),
        script.text("Plan: later."),
    }, .{ .decision = .{ .keep_planning = null } });
    defer h.deinit();
    h.agent_tools.setMode(.default);
    try h.run("Plan it.");
    const rs = h.results();
    try testing.expect(std.mem.startsWith(u8, resultText(rs[0]), "Plan mode is read-only: edit_file was not run"));
    try testing.expectEqual(@as(usize, 0), h.tools.ran.items.len);
}

test "exit_plan_approve_switches_mode_and_writes_file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var h: Harness = undefined;
    try h.init(&.{
        exitCall(plan_text),
        script.tools(&.{.{ "e1", "edit_file", "{\"path\":\"src/parse.zig\"}" }}),
        script.text("Done."),
    }, .{ .decision = .{ .approve = .accept_edits } });
    defer h.deinit();
    var seen: Events = .{};
    defer seen.out.deinit(testing.allocator);
    _ = try h.agent.subscribe(seen.sub());
    try h.run("Rename parse.");

    try testing.expectEqual(@as(u32, 1), h.approver.seen);
    try testing.expectEqualStrings("edit_file {\"path\":\"src/parse.zig\"}\n", h.tools.ran.items);
    const req = h.sp.requests()[1];
    const tr = req.messages[req.messages.len - 1].content[0].tool_result;
    try testing.expectEqualStrings("Plan approved; mode is now accept-edits. Proceed.", tr.parts[0].text);
    try testing.expectEqual(toolset.PermissionMode.accept_edits, h.pm.mode);
    try testing.expectEqualStrings(plan_text, h.state.plan.?);
    try testing.expectEqualStrings("Rename parse to decode", h.title.buf[0..h.title.len]);

    const path = try plan_mode.planPath(arena.allocator(), h.pm.ws_root, h.agent.ref.session);
    const saved = try std.Io.Dir.cwd().readFileAlloc(io, path, arena.allocator(), .limited(1 << 16));
    try testing.expectEqualStrings(plan_text, saved);
    try testing.expect(std.mem.endsWith(u8, std.fs.path.dirname(path).?, ".zigguro" ++ std.fs.path.sep_str ++ "plans"));
    try testing.expectEqualStrings("plan_proposed plan_approved:accept-edits ", seen.out.items);
}

test "keep_planning_feedback_roundtrip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var h: Harness = undefined;
    try h.init(&.{ exitCall(plan_text), script.text("Plan: revised.") }, .{ .decision = .{ .keep_planning = "Keep the old name as an alias." } });
    defer h.deinit();
    try h.run("Rename parse.");
    const tr = resultText(h.results()[0]);
    try testing.expect(std.mem.indexOf(u8, tr, "Keep the old name as an alias.") != null);
    try testing.expectEqual(toolset.PermissionMode.plan, h.pm.mode);
    try testing.expect(h.agent.plan_mode.load(.acquire));
    try testing.expect(h.state.plan == null);
    const path = try plan_mode.planPath(arena.allocator(), h.pm.ws_root, h.agent.ref.session);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, path, .{}));
}

test "approve_clear_context_compacts" {
    var h: Harness = undefined;
    try h.init(&.{ exitCall(plan_text), script.text("Starting.") }, .{ .decision = .{ .approve_clear_context = .default } });
    defer h.deinit();
    try h.run("Rename parse.");
    // The request after approval carries only the plan.
    const req = h.sp.requests()[1];
    try testing.expectEqual(@as(usize, 1), req.messages.len);
    const first = req.messages[0].content[0].text.text;
    try testing.expect(std.mem.startsWith(u8, first, "Implement this approved plan"));
    try testing.expect(std.mem.indexOf(u8, first, "Update callers.") != null);
    try testing.expectEqual(toolset.PermissionMode.default, h.pm.mode);
}

test "plan_survives_compaction" {
    var h: Harness = undefined;
    try h.init(&.{}, .{ .decision = .{ .keep_planning = null } });
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = try h.pm.approve(io, arena.allocator(), plan_text, .accept_edits);
    const c: compactor.Compactor = .{ .provider = undefined, .model = undefined };
    const text = try c.reinjection(arena.allocator(), h.loop_compaction.reinject);
    try testing.expect(std.mem.startsWith(u8, text, "# Current plan\n\n# Rename parse to decode"));
}

test "edited plan wins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var h: Harness = undefined;
    try h.init(&.{ exitCall(plan_text), script.text("Ok.") }, .{ .decision = .{ .approve = .default }, .edited_plan = "# Edited\n\nOnly step 1.\n" });
    defer h.deinit();
    try h.run("Rename parse.");
    try testing.expect(std.mem.indexOf(u8, resultText(h.results()[0]), "Only step 1.") != null);
    const path = try plan_mode.planPath(arena.allocator(), h.pm.ws_root, h.agent.ref.session);
    try testing.expectEqualStrings("# Edited\n\nOnly step 1.\n", try std.Io.Dir.cwd().readFileAlloc(io, path, arena.allocator(), .limited(1 << 16)));
}

test "cli_prompt_rendering" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var in: std.Io.Reader = .fixed("x\nn\nKeep the old name.\n");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var cli: plan_mode.CliApprover = .{ .in = &in, .out = &out.writer };
    const ap = cli.approver();
    const ans = try ap.ask(ap.ctx, io, arena.allocator(), plan_text);
    try testing.expectEqualStrings("Keep the old name.", ans.decision.keep_planning.?);
    try golden.expectGoldenOpts(io, @src(), "cli_prompt", out.written(), .{ .root = @import("zg_options").package_root, .dir = "testdata/plan" });

    for ([_]struct { []const u8, plan_mode.PlanDecision }{
        .{ "a\n", .{ .approve = .accept_edits } },
        .{ "y\n", .{ .approve = .default } },
        .{ "", .{ .keep_planning = null } },
    }) |case| {
        var r: std.Io.Reader = .fixed(case[0]);
        var sink: std.Io.Writer.Discarding = .init(&.{});
        var c: plan_mode.CliApprover = .{ .in = &r, .out = &sink.writer };
        const a2 = c.approver();
        try testing.expectEqualDeep(case[1], (try a2.ask(a2.ctx, io, arena.allocator(), plan_text)).decision);
    }
}

test "planTitle" {
    try testing.expectEqualStrings("Fix it", plan_mode.planTitle("\n## Fix it\nbody").?);
    try testing.expectEqualStrings("Later heading", plan_mode.planTitle("First line\n# Later heading").?);
    try testing.expectEqualStrings("Only text", plan_mode.planTitle("\nOnly text\nmore").?);
    try testing.expect(plan_mode.planTitle(" \n\n") == null);
}

/// Records plan events as `name[:mode] `.
const Events = struct {
    mutex: std.Io.Mutex = .init,
    out: std.ArrayList(u8) = .empty,

    fn sub(e: *Events) @import("../loop/bus.zig").Subscriber {
        return .{ .ctx = e, .on_events = on, .mode = .inline_ };
    }

    fn on(ctx: *anyopaque, batch: []const ev.Envelope) void {
        const e: *Events = @ptrCast(@alignCast(ctx));
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        for (batch) |x| switch (x.ev) {
            .plan_proposed => e.out.appendSlice(testing.allocator, "plan_proposed ") catch {},
            .plan_approved => |p| e.out.print(testing.allocator, "plan_approved:{s} ", .{p.mode}) catch {},
            else => {},
        };
    }
};
