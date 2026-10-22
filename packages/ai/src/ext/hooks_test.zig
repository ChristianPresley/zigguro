//! Tests for the hook engine (E10.F09.S03.T01). Hooks are POSIX shell
//! commands and `testdata/hooks/*.sh`, so these tests skip on Windows.

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("zg_ai_proto");
const hooks = @import("hooks.zig");
const Agent = @import("../loop/Agent.zig");
const AgentManager = @import("../loop/Manager.zig");
const reg_mod = @import("../models/registry.zig");
const scripted = @import("../provider/scripted.zig");
const Provider = @import("../provider/Provider.zig");
const tool_registry = @import("../tools/registry.zig");
const toolset = @import("../tools/toolset.zig");
const validate = @import("../schema/validate.zig");

const testing = std.testing;
const io = testing.io;
const Allocator = std.mem.Allocator;
const script = scripted.script;
const Step = scripted.ScriptedProvider.Step;

const root = @import("zg_options").package_root;

fn skipOnWindows() !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
}

fn hookScript(a: Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "sh '{s}/testdata/hooks/{s}'", .{ root, name });
}

/// An engine with the test environment and `sources`.
fn engine(sources: []const hooks.Source, opts: hooks.Options) !hooks.HookEngine {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var o = opts;
    o.environ = &env;
    var e: hooks.HookEngine = try .init(testing.allocator, io, o);
    errdefer e.deinit();
    try e.add(sources);
    return e;
}

fn one(event: hooks.HookEvent, matcher: []const u8, h: []const hooks.Handler) [1]hooks.Source {
    return .{.{ .layer = .user, .event = event, .configs = &.{.{ .matcher = matcher, .hooks = h }} }};
}

const rm_input: hooks.Input = .{ .tool_name = "run_command", .tool_input_json = "{\"command\":\"rm -rf build\"}" };

test "exit0_json_permission_deny" {
    try skipOnWindows();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try engine(&one(.PreToolUse, "*", &.{.{ .command = try hookScript(a, "deny_json.sh") }}), .{});
    defer e.deinit();
    const o = try e.run(io, a, .PreToolUse, rm_input);
    try testing.expectEqual(hooks.hook_io_mod.Permission.deny, o.permission.?);
    try testing.expectEqualStrings("policy says no", o.permission_reason.?);
    try testing.expect(o.block == null);
}

test "exit2_blocks_pretooluse_with_stderr (the Claude Code rm example, Bash alias)" {
    try skipOnWindows();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try engine(&one(.PreToolUse, "Bash", &.{.{ .command = try hookScript(a, "block_rm.sh") }}), .{});
    defer e.deinit();
    const o = try e.run(io, a, .PreToolUse, rm_input);
    try testing.expectEqualStrings("Blocked: rm is not allowed here; move files to trash/ instead.", o.block.?);
    const ok = try e.run(io, a, .PreToolUse, .{ .tool_name = "run_command", .tool_input_json = "{\"command\":\"ls\"}" });
    try testing.expect(ok.block == null);
    // Other tools do not match `Bash`.
    const other = try e.run(io, a, .PreToolUse, .{ .tool_name = "write_file", .tool_input_json = "{\"command\":\"rm x\"}" });
    try testing.expect(other.block == null);
}

test "exit2_posttooluse_nonblocking" {
    try skipOnWindows();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try engine(&one(.PostToolUse, "*", &.{.{ .command = "echo 'lint failed: unused variable' >&2; exit 2" }}), .{});
    defer e.deinit();
    const o = try e.run(io, a, .PostToolUse, .{ .tool_name = "edit_file", .tool_input_json = "{}", .tool_response_json = "{}" });
    try testing.expect(o.block == null);
    try testing.expectEqualStrings("lint failed: unused variable", o.additional_context.?);
}

test "plain_stdout_context_on_prompt_submit" {
    try skipOnWindows();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try engine(&one(.UserPromptSubmit, "", &.{.{ .command = "cat >/dev/null; echo 'Current sprint: 42'" }}), .{});
    defer e.deinit();
    const o = try e.run(io, a, .UserPromptSubmit, .{ .prompt = "hi" });
    try testing.expectEqualStrings("Current sprint: 42", o.additional_context.?);
    // Plain stdout is not context on other events.
    var e2 = try engine(&one(.PostToolUse, "*", &.{.{ .command = "echo ignored" }}), .{});
    defer e2.deinit();
    try testing.expect((try e2.run(io, a, .PostToolUse, .{ .tool_name = "x" })).additional_context == null);
}

test "input json and environment" {
    try skipOnWindows();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const out = try std.fs.path.join(a, &.{ dir, "seen.txt" });
    const cmd = try std.fmt.allocPrint(a, "{s} '{s}'", .{ try hookScript(a, "echo_input.sh"), out });
    var e = try engine(&one(.SessionStart, "startup", &.{.{ .command = cmd }}), .{ .project_dir = dir, .compat = true, .session_id = "S1", .permission_mode = "plan" });
    defer e.deinit();
    _ = try e.run(io, a, .SessionStart, .{ .source = "resume" });
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "seen.txt", .{}));
    _ = try e.run(io, a, .SessionStart, .{ .source = "startup" });
    const seen = try tmp.dir.readFileAlloc(io, "seen.txt", a, .limited(1 << 16));
    const want = try std.fmt.allocPrint(a, "{{\"session_id\":\"S1\",\"cwd\":\"{s}\",\"permission_mode\":\"plan\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}}{s}\n{s}\n", .{ dir, dir, dir });
    try testing.expectEqualStrings(want, seen);
}

test "timeout_kills_process" {
    try skipOnWindows();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try engine(&one(.PreToolUse, "*", &.{.{ .command = "sleep 30", .timeout_s = 1, .on_failure = .block }}), .{});
    defer e.deinit();
    const t0 = std.Io.Timestamp.now(io, .awake);
    const o = try e.run(io, a, .PreToolUse, rm_input);
    const ms = t0.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    try testing.expect(ms < 10_000);
    try testing.expectEqualStrings("hook sleep 30 timed out", o.block.?);
}

test "parallel_merge_precedence" {
    try skipOnWindows();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decide = "cat >/dev/null; printf '{\"hookSpecificOutput\":{\"permissionDecision\":\"%s\",\"permissionDecisionReason\":\"%s\"}}' ";
    var e = try engine(&one(.PreToolUse, "*", &.{
        .{ .command = decide ++ "allow allowed" },
        .{ .command = decide ++ "deny denied; sleep 0.2" },
        .{ .command = decide ++ "ask asked" },
        .{ .command = "cat >/dev/null; printf '{\"hookSpecificOutput\":{\"updatedInput\":{\"command\":\"ls\"}}}'" },
        .{ .command = "cat >/dev/null; printf '{\"hookSpecificOutput\":{\"updatedInput\":{\"command\":\"pwd\"}}}'" },
        // An identical command runs once.
        .{ .command = decide ++ "allow allowed" },
    }), .{});
    defer e.deinit();
    const t0 = std.Io.Timestamp.now(io, .awake);
    const o = try e.run(io, a, .PreToolUse, rm_input);
    const ms = t0.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    try testing.expectEqual(hooks.hook_io_mod.Permission.deny, o.permission.?);
    try testing.expectEqualStrings("denied", o.permission_reason.?);
    try testing.expectEqualStrings("{\"command\":\"ls\"}", o.updated_input_json.?);
    try testing.expectEqual(@as(usize, 1), o.notices.len);
    try testing.expect(std.mem.indexOf(u8, o.notices[0], "2 hooks changed the tool input") != null);
    // In parallel: well under five sequential 200 ms runs.
    try testing.expect(ms < 900);
}

test "matcher_regex_and_aliases" {
    try skipOnWindows();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try engine(&.{
        .{ .layer = .user, .event = .PreToolUse, .configs = &.{
            .{ .matcher = "Edit|Write", .hooks = &.{.{ .command = "cat >/dev/null; echo edit >&2; exit 2" }} },
            .{ .matcher = "mcp__.*__delete.*", .hooks = &.{.{ .command = "cat >/dev/null; echo mcp >&2; exit 2" }} },
        } },
    }, .{});
    defer e.deinit();
    try testing.expectEqualStrings("edit", (try e.run(io, a, .PreToolUse, .{ .tool_name = "edit_file" })).block.?);
    try testing.expectEqualStrings("edit", (try e.run(io, a, .PreToolUse, .{ .tool_name = "write_file" })).block.?);
    try testing.expectEqualStrings("mcp", (try e.run(io, a, .PreToolUse, .{ .tool_name = "mcp__github__delete_branch" })).block.?);
    try testing.expect((try e.run(io, a, .PreToolUse, .{ .tool_name = "read_file" })).block == null);
}

test "untrusted_workspace_skips_project_hooks" {
    try skipOnWindows();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block: []const hooks.HookConfig = &.{.{ .hooks = &.{.{ .command = "cat >/dev/null; echo project >&2; exit 2" }} }};
    const managed: []const hooks.HookConfig = &.{.{ .hooks = &.{.{ .command = "cat >/dev/null; echo managed >&2; exit 2" }} }};
    const sources = [_]hooks.Source{
        .{ .layer = .project, .event = .UserPromptSubmit, .configs = block },
        .{ .layer = .managed, .event = .Stop, .configs = managed },
    };
    var untrusted = try engine(&sources, .{});
    defer untrusted.deinit();
    try testing.expect((try untrusted.run(io, a, .UserPromptSubmit, .{ .prompt = "x" })).block == null);

    var trusted = try engine(&sources, .{ .workspace_trusted = true });
    defer trusted.deinit();
    try testing.expectEqualStrings("project", (try trusted.run(io, a, .UserPromptSubmit, .{ .prompt = "x" })).block.?);

    // disableAllHooks keeps managed hooks.
    var disabled = try engine(&sources, .{ .workspace_trusted = true, .disable_non_managed = true });
    defer disabled.deinit();
    try testing.expect((try disabled.run(io, a, .UserPromptSubmit, .{ .prompt = "x" })).block == null);
    try testing.expectEqualStrings("managed", (try disabled.run(io, a, .Stop, .{})).block.?);
}

test "project commands need approval once" {
    try skipOnWindows();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Approver = struct {
        asked: u32 = 0,
        answer: bool = false,
        fn approve(ctx: *anyopaque, _: std.Io, _: hooks.HookEvent, _: []const u8) std.Io.Cancelable!bool {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.asked += 1;
            return s.answer;
        }
    };
    var ap: Approver = .{};
    const sources = [_]hooks.Source{.{ .layer = .project, .event = .UserPromptSubmit, .configs = &.{.{ .hooks = &.{.{ .command = "cat >/dev/null; echo hi" }} }} }};
    var e = try engine(&sources, .{ .workspace_trusted = true, .approver = .{ .ctx = &ap, .approve = Approver.approve } });
    defer e.deinit();
    const refused = try e.run(io, a, .UserPromptSubmit, .{ .prompt = "x" });
    try testing.expect(refused.additional_context == null);
    try testing.expect(std.mem.indexOf(u8, refused.notices[0], "was not approved") != null);
    ap.answer = true;
    try testing.expectEqualStrings("hi", (try e.run(io, a, .UserPromptSubmit, .{ .prompt = "x" })).additional_context.?);
    try testing.expectEqualStrings("hi", (try e.run(io, a, .UserPromptSubmit, .{ .prompt = "x" })).additional_context.?);
    try testing.expectEqual(@as(u32, 2), ap.asked);
}

test "settings in Claude Code format" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try hooks.parseSettings(arena.allocator(),
        \\{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"./check.sh","timeout":30}]}],
        \\ "Stop":[{"hooks":[{"type":"command","command":"./stop.sh"}]}],"Unknown":[]},"disableAllHooks":false}
    , .project);
    try testing.expectEqual(@as(usize, 2), s.sources.len);
    try testing.expectEqual(hooks.HookEvent.PreToolUse, s.sources[0].event);
    try testing.expectEqualStrings("Bash", s.sources[0].configs[0].matcher);
    try testing.expectEqual(@as(u32, 30), s.sources[0].configs[0].hooks[0].timeout_s);
    try testing.expectEqualStrings("*", s.sources[1].configs[0].matcher);
    try testing.expect(!s.disable_all);
    try testing.expectEqualStrings("Unknown", s.unknown[0]);
}

// -- with the agent loop -------------------------------------------------

const catalog: [:0]const u8 =
    \\.{
    \\    .retrieved = "test",
    \\    .models = .{
    \\        .{ .id = "m", .context_window = 200_000, .max_output = 32_000, .base = .claude,
    \\           .price = .{ .input_per_mtok_micros = 3_000_000, .output_per_mtok_micros = 15_000_000 } },
    \\    },
    \\}
;

/// `run_command` with a schema; records the commands it ran.
const Commands = struct {
    spec: [1]proto.ToolSpec = undefined,
    ran: std.ArrayList(u8) = .empty,

    fn source(c: *Commands) tool_registry.ToolSource {
        c.spec = .{.{ .name = "run_command", .description = "Runs.", .input_schema_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}", .read_only = true, .handler = .{ .ctx = c, .call = call } }};
        return .{ .name = "cmd", .ctx = c, .list = list, .kind = .builtin };
    }
    fn list(ctx: *anyopaque, gpa: Allocator, out: *std.ArrayList(proto.ToolSpec)) anyerror!void {
        const c: *Commands = @ptrCast(@alignCast(ctx));
        try out.appendSlice(gpa, &c.spec);
    }
    fn call(ctx: *anyopaque, tc: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const c: *Commands = @ptrCast(@alignCast(ctx));
        c.ran.appendSlice(testing.allocator, tc.input_json) catch return error.OutOfMemory;
        c.ran.append(testing.allocator, '\n') catch return error.OutOfMemory;
        return proto.ToolOutput.text(tc.arena, "done", false) catch error.OutOfMemory;
    }
};

/// Checks only that `"type":"string"` properties hold strings.
const StringValidator = struct {
    var ctx: u8 = 0;

    fn validator() validate.Validator {
        return .{ .ctx = &ctx, .compile = compile, .validate = check };
    }

    fn compile(_: *anyopaque, arena: Allocator, schema_json: []const u8) validate.CompileError!*const anyopaque {
        const v = try arena.create(std.json.Value);
        v.* = std.json.parseFromSliceLeaky(std.json.Value, arena, schema_json, .{}) catch return error.InvalidSchema;
        return v;
    }

    fn check(_: *anyopaque, compiled: *const anyopaque, _: Allocator, value: std.json.Value, errs: *validate.ErrorList) bool {
        const s: *const std.json.Value = @ptrCast(@alignCast(compiled));
        if (value != .object) return false;
        var it = s.object.get("properties").?.object.iterator();
        while (it.next()) |e| {
            const got = value.object.get(e.key_ptr.*) orelse continue;
            if (std.mem.eql(u8, e.value_ptr.object.get("type").?.string, "string") and got != .string) {
                errs.add(.{ .pointer = "/command", .keyword = "type", .message = "expected a string" });
                return false;
            }
        }
        return true;
    }
};

const Loop = struct {
    registry: reg_mod.ModelRegistry,
    sp: *scripted.ScriptedProvider,
    provider: Provider,
    reg: tool_registry.ToolRegistry,
    cmds: Commands = .{},
    agent_tools: toolset.AgentTools,
    mgr: *AgentManager,
    agent: *Agent,

    fn init(l: *Loop, turns: []const []const Step, e: *hooks.HookEngine) !void {
        l.registry = .init(testing.allocator, io, catalog);
        l.sp = try .init(testing.allocator, turns, .all);
        l.provider = l.sp.provider();
        l.reg = .init(testing.allocator, io);
        l.cmds = .{};
        try l.reg.addSource(l.cmds.source());
        l.agent_tools = .init(testing.allocator, io, &l.reg, .{});
        l.agent_tools.warn_invalidations = false;
        l.mgr = try AgentManager.init(testing.allocator, io, .{ .registry = &l.registry, .providers = .fixed(&l.provider), .tools = l.agent_tools.tools(), .validator = StringValidator.validator() });
        l.mgr.deps.hooks = e.hooks();
        l.agent = try l.mgr.create(.{ .model = "m" });
    }

    fn deinit(l: *Loop) void {
        l.mgr.deinit();
        l.agent_tools.deinit();
        l.reg.deinit();
        l.sp.destroy();
        l.registry.deinit();
        l.cmds.ran.deinit(testing.allocator);
    }

    fn run(l: *Loop, text: []const u8) !void {
        _ = try l.agent.submit(.{ .text = text });
        l.agent.waitIdle();
    }

    fn resultIn(l: *Loop, i: usize) []const u8 {
        const req = l.sp.requests()[i];
        return req.messages[req.messages.len - 1].content[0].tool_result.parts[0].text;
    }
};

test "updated_input_revalidated" {
    try skipOnWindows();
    const rewrite = "cat >/dev/null; printf '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":%s}}' ";
    var bad = try engine(&one(.PreToolUse, "Bash", &.{.{ .command = rewrite ++ "'{\"command\":5}'" }}), .{});
    defer bad.deinit();
    var l: Loop = undefined;
    try l.init(&.{ script.tools(&.{.{ "c1", "run_command", "{\"command\":\"ls\"}" }}), script.text("ok") }, &bad);
    defer l.deinit();
    try l.run("List.");
    try testing.expectEqual(@as(usize, 0), l.cmds.ran.items.len);
    try testing.expect(std.mem.indexOf(u8, l.resultIn(1), "command") != null);

    var good = try engine(&one(.PreToolUse, "Bash", &.{.{ .command = rewrite ++ "'{\"command\":\"ls -la\"}'" }}), .{});
    defer good.deinit();
    var l2: Loop = undefined;
    try l2.init(&.{ script.tools(&.{.{ "c1", "run_command", "{\"command\":\"ls\"}" }}), script.text("ok") }, &good);
    defer l2.deinit();
    try l2.run("List.");
    try testing.expectEqualStrings("{\"command\":\"ls -la\"}\n", l2.cmds.ran.items);
}

test "stop_hook_block_reason" {
    try skipOnWindows();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Blocks the first stop only (a marker file remembers it).
    const cmd = try std.fmt.allocPrint(arena.allocator(), "cat >/dev/null; if [ -e '{s}/m' ]; then exit 0; fi; touch '{s}/m'; echo 'Run the tests before stopping.' >&2; exit 2", .{ dir, dir });
    var e = try engine(&one(.Stop, "", &.{.{ .command = cmd }}), .{});
    defer e.deinit();
    var l: Loop = undefined;
    try l.init(&.{ script.text("Done."), script.text("Tests pass.") }, &e);
    defer l.deinit();
    try l.run("Fix it.");
    const reqs = l.sp.requests();
    try testing.expectEqual(@as(usize, 2), reqs.len);
    const last = reqs[1].messages[reqs[1].messages.len - 1];
    try testing.expect(std.mem.indexOf(u8, last.content[0].text.text, "Run the tests before stopping.") != null);
}

test "audit records each run" {
    try skipOnWindows();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Rec = struct {
        out: std.ArrayList(u8) = .empty,
        fn record(ctx: *anyopaque, _: std.Io, r: hooks.HookRun) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.out.print(testing.allocator, "{t} {s} exit={?d} {s}\n", .{ r.event, r.handler, r.exit, r.decision }) catch {};
        }
    };
    var rec: Rec = .{};
    defer rec.out.deinit(testing.allocator);
    var e = try engine(&one(.PreToolUse, "*", &.{.{ .command = "cat >/dev/null; exit 2" }}), .{ .audit = .{ .ctx = &rec, .record = Rec.record } });
    defer e.deinit();
    _ = try e.run(io, arena.allocator(), .PreToolUse, rm_input);
    try testing.expectEqualStrings("PreToolUse cat >/dev/null; exit 2 exit=2 block\n", rec.out.items);
}
