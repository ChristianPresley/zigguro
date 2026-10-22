//! Skills, commands and the `skill` tool (E10.F09.S04.T01), over the
//! fixtures in `testdata/skills` (the Claude Code docs examples among
//! them).

const std = @import("std");
const proto = @import("zg_ai_proto");
const AgentManager = @import("../loop/Manager.zig");
const reg_mod = @import("../models/registry.zig");
const scripted = @import("../provider/scripted.zig");
const Provider = @import("../provider/Provider.zig");
const tool_registry = @import("../tools/registry.zig");
const toolset = @import("../tools/toolset.zig");
const run_mod = @import("../tools/builtin/run.zig");
const fake_host = @import("../tools/builtin/fake_host.zig");
const deps = @import("../loop/deps.zig");
const defs = @import("../subagent/defs.zig");
const subagent = @import("../subagent/runner.zig");
const skills = @import("skills.zig");
const skill_tool = @import("skill_tool.zig");
const commands = @import("commands.zig");
const builtin_commands = @import("builtin_commands.zig");

const testing = std.testing;
const io = testing.io;
const Allocator = std.mem.Allocator;
const script = scripted.script;
const Step = scripted.ScriptedProvider.Step;

const root = @import("zg_options").package_root;

fn fixture(a: Allocator, rel: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ root, "testdata", "skills", rel });
}

fn loadFixtures(a: Allocator, compat: bool) !skills.SkillIndex {
    const roots = try skills.standardRoots(a, try fixture(a, "project"), try fixture(a, "user"), try fixture(a, "managed"), compat);
    return skills.SkillIndex.load(testing.allocator, io, roots);
}

fn names(a: Allocator, ix: *skills.SkillIndex) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (try ix.list(a)) |s| try out.print(a, "{s}{s}:{t}:{t}", .{ if (out.items.len > 0) " " else "", s.name, s.source, s.kind });
    return out.items;
}

test "discovery_precedence_and_compat" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ix = try loadFixtures(a, true);
    defer ix.deinit();
    // explain: user beats project; deploy: the .claude skill beats the
    // .zigguro command; review: managed beats project.
    try testing.expectEqualStrings("deploy:project:skills explain:user:skills pr-summary:project:skills review:managed:commands", try names(a, &ix));
    try testing.expectEqual(@as(usize, 1), ix.warnings.items.len);
    try testing.expect(std.mem.indexOf(u8, ix.warnings.items[0], "broken") != null);

    const explain = ix.find("explain").?;
    try testing.expectEqualStrings("When the user asks how code works.", explain.when_to_use.?);
    try testing.expectEqualStrings("[path]", explain.argument_hint.?);
    try testing.expectEqualStrings("path", explain.arguments[0]);
    const pr = ix.find("pr-summary").?;
    try testing.expectEqual(skills.Context.fork, pr.context);
    try testing.expectEqualStrings("run_command(gh *)", pr.allowed_tools[0]);
    try testing.expect(ix.find("deploy").?.disable_model_invocation);
    try testing.expectEqualStrings("<files>", ix.find("review").?.argument_hint.?);

    // Without compat, .claude is ignored: deploy is the .zigguro command
    // and the frontmatter-less command takes its name from the file.
    var plain = try loadFixtures(a, false);
    defer plain.deinit();
    try testing.expectEqualStrings("deploy:project:commands explain:user:skills review:managed:commands", try names(a, &plain));
    try testing.expectEqualStrings("Deploy (command copy)", plain.find("deploy").?.description);

    // Nested skills join once the agent works below their directory.
    const project = try fixture(a, "project");
    try plain.activateFor(project, "README.md", false);
    try testing.expect(plain.find("pkg-lint") == null);
    try plain.activateFor(project, "pkg/src/main.zig", false);
    try testing.expectEqualStrings("Lints the pkg package", plain.find("pkg-lint").?.description);
}

test "command without frontmatter" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ix: skills.SkillIndex = .init(testing.allocator, io);
    defer ix.deinit();
    try ix.addRoot(.{ .dir = try fixture(a, "project/.zigguro/commands"), .source = .project, .kind = .commands });
    const review = ix.find("review").?;
    try testing.expectEqualStrings("Review the frontend changes in $ARGUMENTS for accessibility.", review.description);
    const ex = try skills.expand(io, a, review, "src/App.tsx", .{});
    try testing.expectEqualStrings("# Review\n\nReview the frontend changes in src/App.tsx for accessibility.", ex.text);
}

test "lazy_body_read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "skills/greet");
    try tmp.dir.writeFile(io, .{ .sub_path = "skills/greet/SKILL.md", .data = "---\ndescription: Greets\n---\nHello v1.\n" });
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/skills", .{&tmp.sub_path});
    var ix = try skills.SkillIndex.load(testing.allocator, io, &.{.{ .dir = dir, .source = .project }});
    defer ix.deinit();
    // The body is read on invoke, not at load.
    try tmp.dir.writeFile(io, .{ .sub_path = "skills/greet/SKILL.md", .data = "---\ndescription: Greets\n---\nHello v2.\n" });
    const ex = try skills.expand(io, a, ix.find("greet").?, "", .{});
    try testing.expectEqualStrings("Hello v2.", ex.text);
}

const Policy = struct {
    deny: ?[]const u8 = null,
    fn check(ctx: *anyopaque, _: std.Io, req: run_mod.CommandRequest) std.Io.Cancelable!deps.Decision {
        const p: *Policy = @ptrCast(@alignCast(ctx));
        if (p.deny) |d| if (std.mem.eql(u8, d, req.command)) return .{ .deny = "not on the allowlist" };
        return .allow;
    }
    fn policy(p: *Policy) run_mod.CommandPolicy {
        return .{ .ctx = p, .check = check };
    }
};

const gh_scripts = [_]fake_host.Script{
    .{ .command = "gh pr diff", .steps = &.{ .{ .line = "+fn main() {}" }, .{ .exit = 0 } } },
    .{ .command = "gh pr view --comments", .steps = &.{ .{ .line = "LGTM" }, .{ .exit = 0 } } },
    .{ .command = "gh pr diff --name-only", .steps = &.{ .{ .line = "src/main.zig" }, .{ .line = "build.zig" }, .{ .exit = 0 } } },
};

test "claude code examples expand in compat mode" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ix = try loadFixtures(a, true);
    defer ix.deinit();
    var host: fake_host.FakeHost = .init(testing.allocator, &gh_scripts);
    defer host.deinit();
    var sh: skills.HostShell = .{ .host = host.host() };
    const ctx: skills.ExpandCtx = .{ .vars = .{ .session_id = "S9", .project_dir = "/work", .compat = true }, .shell = sh.shell() };

    const deploy = try skills.expand(io, a, ix.find("deploy").?, "staging", ctx);
    try testing.expect(std.mem.startsWith(u8, deploy.text, "Deploy staging to production:\n\n1. Run the test suite"));

    const pr = try skills.expand(io, a, ix.find("pr-summary").?, "", ctx);
    try testing.expectEqual(@as(u32, 3), pr.injections);
    try testing.expectEqualStrings(
        \\## Pull request context
        \\- PR diff: +fn main() {}
        \\- PR comments: LGTM
        \\- Changed files: src/main.zig
        \\build.zig
        \\
        \\## Your task
        \\Summarize this pull request for session S9.
    , pr.text);
    try testing.expectEqualStrings("/work", host.started.items[0].cwd.?);
    try testing.expect(!host.sessions.items[0].visible);
}

test "fenced injections, plain fences and limits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const big = "x" ** 40;
    var host: fake_host.FakeHost = .init(testing.allocator, &.{
        .{ .command = "git status --short\ngit log -1", .steps = &.{ .{ .line = "M a.zig" }, .{ .exit = 0 } } },
        .{ .command = "cat big", .steps = &.{ .{ .line = big }, .{ .exit = 0 } } },
    });
    defer host.deinit();
    var sh: skills.HostShell = .{ .host = host.host() };
    // Inside an ordinary fence `!` is just text, as is `!` glued to a word.
    const text = "Status:\n```!\ngit status --short\ngit log -1\n```\nExample:\n```\n!`date`\n```\nwow!`x` and !`cat big`";
    const ex = try skills.inject(io, a, text, .{ .shell = sh.shell(), .max_injection_bytes = 16 });
    try testing.expectEqualStrings("Status:\nM a.zig\nExample:\n```\n!`date`\n```\nwow!`x` and " ++ "x" ** 16 ++ "\n[output truncated]", ex.text);
    try testing.expectEqual(@as(u32, 2), ex.injections);
    try testing.expectEqual(@as(usize, 2), host.started.items.len);
}

test "disabled shell execution" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ex = try skills.inject(io, arena.allocator(), "Diff: !`gh pr diff`", .{ .disable_shell = true });
    try testing.expectEqualStrings("Diff: " ++ skills.disabled_text, ex.text);
}

test "shell_injection_permission_denied_aborts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ix = try loadFixtures(a, true);
    defer ix.deinit();
    var host: fake_host.FakeHost = .init(testing.allocator, &gh_scripts);
    defer host.deinit();
    var policy: Policy = .{ .deny = "gh pr view --comments" };
    var sh: skills.HostShell = .{ .host = host.host(), .policy = policy.policy() };
    var why: []const u8 = "";
    try testing.expectError(error.ShellDenied, skills.expand(io, a, ix.find("pr-summary").?, "", .{ .shell = sh.shell(), .diag = &why }));
    try testing.expectEqualStrings("`gh pr view --comments` was not run: not on the allowlist", why);
    // The denied command never started.
    try testing.expectEqual(@as(usize, 1), host.started.items.len);
}

test "shell_injection_failure_aborts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host: fake_host.FakeHost = .init(testing.allocator, &.{
        .{ .command = "false", .steps = &.{ .{ .line = "boom" }, .{ .exit = 1 } } },
    });
    defer host.deinit();
    var sh: skills.HostShell = .{ .host = host.host() };
    var why: []const u8 = "";
    try testing.expectError(error.ShellFailed, skills.inject(io, a, "A !`false` B", .{ .shell = sh.shell(), .diag = &why }));
    try testing.expectEqualStrings("`false` failed: exit code 1: boom", why);
    try testing.expectError(error.ShellFailed, skills.inject(io, a, "A !`missing` B", .{ .shell = sh.shell(), .diag = &why }));
    try testing.expectEqualStrings("`missing` failed: SpawnFailed", why);
    try testing.expectError(error.ShellFailed, skills.inject(io, a, "A !`ls` B", .{ .diag = &why }));
    try testing.expectError(error.ShellFailed, skills.inject(io, a, "```!\nls\n", .{ .shell = sh.shell(), .diag = &why }));
}

test "model_listing_truncation_and_order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ix = try loadFixtures(a, true);
    defer ix.deinit();
    try ix.activateFor(try fixture(a, "project"), "pkg/x.zig", false);

    // deploy is user-only; pkg-lint waits for a matching file.
    var listing = try ix.modelListing(a, skills.max_listing_chars, &.{});
    try testing.expectEqual(@as(usize, 3), listing.len);
    try testing.expectEqualStrings("explain", listing[0].name);
    try testing.expectEqualStrings("Explains code with diagrams and analogies. (When the user asks how code works.)", listing[0].description);
    try testing.expectEqualStrings("pr-summary", listing[1].name);
    try testing.expectEqualStrings("review", listing[2].name);

    listing = try ix.modelListing(a, 20, &.{"pkg/src/a.zig"});
    try testing.expectEqual(@as(usize, 4), listing.len);
    try testing.expectEqualStrings("pkg-lint", listing[1].name);
    try testing.expectEqualStrings("Explains code wit…", listing[0].description);
    try testing.expect(listing[0].description.len <= 20);
}

test "builtin_commands_registered_in_palette" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ix = try loadFixtures(a, true);
    defer ix.deinit();
    const Fake = struct {
        ids: std.ArrayList([]const u8) = .empty,
        a: Allocator,
        fn add(ctx: *anyopaque, e: commands.PaletteEntry) anyerror!void {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            try f.ids.append(f.a, e.id);
        }
    };
    var fake: Fake = .{ .a = a };
    try commands.registerWithPalette(a, .{ .ctx = &fake, .add = Fake.add }, &ix, &builtin_commands.all);
    try testing.expectEqual(builtin_commands.all.len + 4, fake.ids.items.len);
    try testing.expectEqualStrings("ai.clear", fake.ids.items[0]);
    try testing.expectEqualStrings("ai.help", fake.ids.items[builtin_commands.all.len - 1]);
    try testing.expectEqualStrings("ai.skill.deploy", fake.ids.items[builtin_commands.all.len]);

    // Built-ins win; /help lists both.
    const reg: commands.CommandRegistry = .{ .index = &ix };
    try testing.expect(reg.resolve("plan") == .builtin);
    try testing.expectEqualStrings("explain", reg.resolve("explain").skill.name);
    try testing.expect(reg.resolve("nope") == .unknown);
    const help = try reg.help(a);
    try testing.expect(std.mem.indexOf(u8, help, "  /model [id]  Show or switch the model\n") != null);
    try testing.expect(std.mem.indexOf(u8, help, "  /explain [path]  Explains code with diagrams and analogies.\n") != null);
}

// -- the skill tool ----------------------------------------------------

const catalog: [:0]const u8 =
    \\.{
    \\    .retrieved = "test",
    \\    .models = .{
    \\        .{ .id = "m", .context_window = 200_000, .max_output = 32_000, .base = .claude,
    \\           .price = .{ .input_per_mtok_micros = 3_000_000, .output_per_mtok_micros = 15_000_000 } },
    \\    },
    \\}
;

const Grants = struct {
    got: std.ArrayList(u8) = .empty,
    fn grant(ctx: *anyopaque, _: std.Io, _: proto.AgentRef, skill: []const u8, rules: []const []const u8) void {
        const g: *Grants = @ptrCast(@alignCast(ctx));
        g.got.print(testing.allocator, "{s}:", .{skill}) catch {};
        for (rules) |r| g.got.print(testing.allocator, "{s};", .{r}) catch {};
    }
};

const Harness = struct {
    registry: reg_mod.ModelRegistry,
    sp: *scripted.ScriptedProvider,
    provider: Provider,
    reg: tool_registry.ToolRegistry,
    agent_tools: toolset.AgentTools,
    mgr: *AgentManager,
    arena: std.heap.ArenaAllocator,
    agent_defs: std.ArrayList(defs.AgentDef) = .empty,
    runner: subagent.SubagentRunner,
    ix: skills.SkillIndex,
    host: fake_host.FakeHost,
    sh: skills.HostShell,
    tool: skill_tool.SkillTool,
    grants: Grants = .{},

    fn init(h: *Harness, turns: []const []const Step) !void {
        h.arena = .init(testing.allocator);
        const a = h.arena.allocator();
        h.registry = .init(testing.allocator, io, catalog);
        h.sp = try .init(testing.allocator, turns, .all);
        h.provider = h.sp.provider();
        h.reg = .init(testing.allocator, io);
        h.agent_tools = .init(testing.allocator, io, &h.reg, .{});
        h.agent_tools.warn_invalidations = false;
        h.mgr = try AgentManager.init(testing.allocator, io, .{ .registry = &h.registry, .providers = .fixed(&h.provider), .tools = h.agent_tools.tools() });
        h.agent_defs = .empty;
        try defs.loadDefs(io, a, &.{}, &h.agent_defs, null);
        h.runner = .init(testing.allocator, io, h.mgr, &h.reg, h.agent_defs.items, .{});
        h.runner.main_tools = &h.agent_tools;
        h.ix = try loadFixtures(a, true);
        h.host = .init(testing.allocator, &gh_scripts);
        h.sh = .{ .host = h.host.host() };
        h.grants = .{};
        h.tool = .init(testing.allocator, &h.ix);
        h.tool.expand = .{ .vars = .{ .project_dir = "/work", .compat = true }, .shell = h.sh.shell() };
        h.tool.subagents = &h.runner;
        h.tool.grants = .{ .ctx = &h.grants, .grant = Grants.grant };
        try h.reg.addSource(h.tool.source());
    }

    fn deinit(h: *Harness) void {
        h.runner.deinit();
        h.mgr.deinit();
        h.tool.deinit();
        h.agent_tools.deinit();
        h.reg.deinit();
        h.host.deinit();
        h.ix.deinit();
        h.grants.got.deinit(testing.allocator);
        h.sp.destroy();
        h.registry.deinit();
        h.arena.deinit();
    }

    fn call(h: *Harness, a: Allocator, input: []const u8) !proto.ToolOutput {
        const spec = h.tool.specs()[0];
        var c: proto.ToolCall = .{ .id = "s1", .name = "skill", .input_json = input, .input = try std.json.parseFromSliceLeaky(std.json.Value, a, input, .{}), .arena = a, .io = io, .agent = .{ .session = 7, .agent = 0 } };
        return spec.handler.call(spec.handler.ctx, &c);
    }
};

test "skill_tool_respects_disable_model_invocation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();

    const desc = h.tool.specs()[0].description;
    try testing.expect(std.mem.indexOf(u8, desc, "- explain: Explains code") != null);
    try testing.expect(std.mem.indexOf(u8, desc, "deploy") == null);

    const denied = try h.call(a, "{\"name\":\"deploy\",\"args\":\"prod\"}");
    try testing.expect(denied.is_error);
    try testing.expectEqualStrings("The deploy skill can only be run by the user (/deploy).", denied.parts[0].text);

    const unknown = try h.call(a, "{\"name\":\"nope\"}");
    try testing.expect(unknown.is_error);

    const ok = try h.call(a, "{\"name\":\"explain\",\"args\":\"src/main.zig\"}");
    try testing.expect(!ok.is_error);
    const dir = try fixture(a, "user/skills/explain");
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "Base directory for this skill: {s}\n\nExplain src/main.zig. Start with an analogy.", .{dir}), ok.parts[0].text);
}

test "skill tool lists supporting files" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    var ix: skills.SkillIndex = .init(testing.allocator, io);
    defer ix.deinit();
    try ix.addRoot(.{ .dir = try fixture(a, "project/.claude/skills"), .source = .project });
    const files = try ix.find("deploy").?.supportingFiles(io, a);
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("scripts" ++ std.fs.path.sep_str ++ "verify.sh", files[0]);
}

test "fork_context_runs_subagent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var h: Harness = undefined;
    try h.init(&.{
        script.tools(&.{.{ "s1", "skill", "{\"name\":\"pr-summary\"}" }}),
        script.text("The PR adds main."),
        script.text("Summarized."),
    });
    defer h.deinit();
    const parent = try h.mgr.create(.{ .model = "m" });
    _ = try parent.submit(.{ .text = "Summarize the PR." });
    parent.waitIdle();

    const reqs = h.sp.requests();
    try testing.expectEqual(@as(usize, 3), reqs.len);
    // The child got the expanded skill, injections run.
    const child_msgs = reqs[1].messages;
    const prompt = child_msgs[child_msgs.len - 1].content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, prompt, "- PR comments: LGTM") != null);
    // The parent got the child's report.
    const last = reqs[2].messages[reqs[2].messages.len - 1].content[0].tool_result;
    try testing.expect(std.mem.startsWith(u8, last.parts[0].text, "The PR adds main.\n\n[agent explore"));
    try testing.expectEqualStrings("pr-summary:run_command(gh *);", h.grants.got.items);
}
