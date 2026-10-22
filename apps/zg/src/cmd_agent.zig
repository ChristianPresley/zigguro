//! `zg agent` (E10.F10.S01.T01): the headless agent. Parses the flags,
//! builds the providers (zg_net, or a cassette), the model registry, the
//! session store and the signal handlers, then hands over to zg_ai's
//! print mode or REPL. Never imports zg_gui or zg_vulkan.
//!
//! Environment:
//!   ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY  provider keys
//!   ZG_MODEL             the default model (else "sonnet")
//!   ZG_CASSETTE          record or replay provider HTTP in this file
//!   ZG_CASSETTE_MODE     replay (default), record or record_missing
//!   ZG_CASSETTE_SPEED    1 replays with the recorded timing
//!   ZIGGURO_STATE_DIR    where sessions are kept (see zg_crash.paths)
//!
//! `--mcp-config <file>` connects MCP servers (`mcp_servers.zig`).
//! `--review` decides what happens to the agent's edits (`review_hooks.zig`).

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_ai = @import("zg_ai");
const zg_net = @import("zg_net");
const zg_crash = @import("zg_crash");
const zg_config = @import("zg_config");
const zg_mcp = @import("zg_mcp");
const mcp_servers = @import("mcp_servers.zig");
const review_hooks = @import("review_hooks.zig");

const headless = zg_ai.headless;
const Cassette = zg_ai.testing.cassette.Cassette;
const Io = std.Io;

/// Runs `zg agent <argv>`; returns the process exit code.
pub fn run(rt: *zg_core.Runtime, min: std.process.Init.Minimal, argv: []const [:0]const u8) !u8 {
    const gpa = rt.gpa;
    const io = rt.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var err_buf: [4096]u8 = undefined;
    var err_w: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err = &err_w.interface;
    var out_buf: [64 * 1024]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    const review_flag = review_hooks.parseFlag(arena, argv) catch |e| switch (e) {
        error.Usage => {
            try err.print("zg agent: --review is defer, interactive, apply or policy\nRun 'zg agent --help' for usage.\n", .{});
            try err.flush();
            return headless.ExitCode.usage.code();
        },
        else => return e,
    };
    var diag: []const u8 = "invalid arguments";
    var opts = headless.args.parseArgsDiag(arena, review_flag.rest, &diag) catch |e| switch (e) {
        error.Usage => {
            try err.print("zg agent: {s}\nRun 'zg agent --help' for usage.\n", .{diag});
            try err.flush();
            return headless.ExitCode.usage.code();
        },
        else => return e,
    };
    if (opts.help) {
        try out.writeAll(headless.args.usage_text);
        try out.writeAll(review_hooks.help);
        return 0;
    }

    var env = try min.environ.createMap(gpa);
    defer env.deinit();

    var registry = zg_ai.ModelRegistry.init(gpa, io, zg_ai.models.registry.builtin_catalog);
    defer registry.deinit();

    // HTTP, optionally through a cassette.
    const client = try zg_net.http.Client.init(rt, .{ .environ_map = &env });
    defer client.deinit();
    var net: zg_ai.transport.ZgNet = .{ .client = client };
    var transport = net.transport();
    var cassette: ?*Cassette = null;
    defer if (cassette) |c| {
        c.finish() catch |e| err.print("zg agent: could not write the cassette: {s}\n", .{@errorName(e)}) catch {};
        c.deinit();
    };
    if (env.get("ZG_CASSETTE")) |path| {
        const mode_name = env.get("ZG_CASSETTE_MODE") orelse "replay";
        const mode = std.meta.stringToEnum(zg_ai.testing.cassette.Mode, mode_name) orelse {
            try err.print("zg agent: ZG_CASSETTE_MODE must be replay, record or record_missing\n", .{});
            try err.flush();
            return headless.ExitCode.usage.code();
        };
        const speed: u8 = if (env.get("ZG_CASSETTE_SPEED")) |s| (std.fmt.parseInt(u8, s, 10) catch 0) else 0;
        cassette = try Cassette.open(io, gpa, path, mode, .{ .speed = speed, .print_misses = true });
        transport = cassette.?.transport(if (mode == .replay) null else net.transport());
        // Replays need no real key, but the provider must exist.
        if (mode == .replay and env.get("ANTHROPIC_API_KEY") == null) try env.put("ANTHROPIC_API_KEY", "cassette");
    }

    var limiter: zg_ai.ratelimit.RateLimiter = .init(gpa, .real);
    defer limiter.deinit();
    var notes: Notes = .{ .err = err };
    const hub = try zg_ai.ProviderHub.init(gpa, .{
        .secrets = no_secrets,
        .environ = &env,
        .transport = transport,
        .limiter = &limiter,
        .registry = &registry,
        .notifier = .{ .ctx = &notes, .warn = Notes.warn, .redact = Notes.redact },
    });
    defer hub.deinit();
    try hub.onSettingsChanged(io, &.{});

    const cwd = try std.process.currentPathAlloc(io, arena);
    var state_buf_hooks: [std.fs.max_path_bytes]u8 = undefined;

    // Tools: the file tools on disk through E12's review glue (each turn's
    // edits held for review or recorded), the command tools over child
    // processes and the web tools (the IDE uses E05 documents and E06
    // terminals).
    var tool_registry: zg_ai.tools.ToolRegistry = .init(gpa, io);
    defer tool_registry.deinit();
    var processes: zg_ai.tools.builtin.process_host.ProcessHost = .init(gpa, io);
    processes.environ = &env;
    defer processes.deinit();
    var run_tools: zg_ai.tools.builtin.run.RunTools = .init(gpa, io, processes.host(), .{ .visible = false });
    defer run_tools.deinit();
    try tool_registry.addSource(run_tools.source());
    var read_tracker: zg_ai.tools.read_tracker.ReadTracker = .init(gpa, io);
    defer read_tracker.deinit();
    var review: review_hooks.Review = try .init(gpa, io, cwd, review_flag.mode, @tagName(opts.permission_mode));
    defer review.deinit();
    var file_tools: zg_ai.tools.builtin.files.FileTools = .{ .files = review.glue.files(), .tracker = &read_tracker };
    try tool_registry.addSource(file_tools.source());
    // Web tools: fetch over the same transport (so cassettes record it) and
    // the provider's own search for models that have one.
    var web_fetch: zg_ai.tools.builtin.web_fetch.WebFetch = .init(gpa, io, transport, .{});
    defer web_fetch.deinit();
    try tool_registry.addSource(web_fetch.source());
    var web_search: zg_ai.tools.builtin.web_search.WebSearch = .init(io, transport, .provider_native);
    try tool_registry.addSource(web_search.source());
    // MCP servers from --mcp-config, as `mcp__<server>__<tool>`.
    var mcp: mcp_servers.Servers = .init(gpa);
    defer mcp.deinit();
    try mcp.load(rt, client, opts.mcp_configs, &env, cwd, err);
    var adapters: zg_ai.tools.adapters.all.Adapters = .init(gpa, io);
    defer adapters.deinit();
    try adapters.registerAll(&tool_registry, &.{ .mcp = mcp.exporters.items }, .{}, .{});
    var agent_tools: zg_ai.tools.AgentTools = .init(gpa, io, &tool_registry, .{
        .deny = try bareRules(arena, opts.disallowed_tools),
        .mode = opts.permission_mode,
    });
    defer agent_tools.deinit();

    // Tool inputs and `--json-schema` are checked by E11's JSON Schema
    // validator, the one MCP `tools/call` arguments go through.
    const validator = zg_mcp.schema.toolValidator(zg_ai.schema.validate);
    const mgr = try zg_ai.loop.AgentManager.init(gpa, io, .{
        .registry = &registry,
        .providers = .fromHub(hub),
        .tools = agent_tools.tools(),
        .validator = validator,
        .checkpoints = review.glue.checkpoints(),
        .turn_end = file_tools.turnEnd(),
    });
    defer mgr.deinit();

    // Subagents: `.zigguro/agents/*.md` in the workspace, then the
    // built-ins, through the `task` tool.
    var agent_defs: std.ArrayList(zg_ai.subagent.defs.AgentDef) = .empty;
    const agents_dir = try std.fs.path.join(arena, &.{ cwd, ".zigguro", "agents" });
    try zg_ai.subagent.defs.loadDefs(io, arena, &.{.{ .dir = agents_dir, .source = .project }}, &agent_defs, null);
    var subagents: zg_ai.subagent.SubagentRunner = .init(gpa, io, mgr, &tool_registry, agent_defs.items, .{});
    defer subagents.deinit();
    subagents.main_tools = &agent_tools;
    var task: zg_ai.subagent.task_tool.TaskTool = try .init(gpa, &subagents);
    defer task.deinit();
    try tool_registry.addSource(task.source());

    // The todo list, and questions to the user: asked on the terminal in
    // the REPL; one-shot runs have nobody to ask, so ask_user is left out.
    var todos: zg_ai.plan.todos.TodoStore = .init(gpa, io);
    defer todos.deinit();
    todos.mgr = mgr;
    try tool_registry.addSource(todos.source());
    var in_buf: [64 * 1024]u8 = undefined;
    var in_r: Io.File.Reader = .initStreaming(.stdin(), io, &in_buf);
    const in = &in_r.interface;
    const stdin_piped = !(Io.File.stdin().isTty(io) catch true);
    const one_shot = opts.prompt != null or opts.streamInput() or stdin_piped;
    var cli_asker: zg_ai.plan.ask_user.CliAsker = .{ .in = in, .out = err };
    var ask_user: zg_ai.plan.ask_user.AskUserTool = .{
        .asker = if (one_shot) null else cli_asker.asker(),
        .mgr = mgr,
        .labeler = zg_ai.plan.ask_user.subagentLabeler(&subagents),
    };
    try tool_registry.addSource(ask_user.source());
    // Plan mode: `exit_plan_mode` asks on the terminal in the REPL (and
    // `/plan` enters it); one-shot runs answer with the plan instead. The
    // runner attaches its agent.
    var cli_approver: zg_ai.plan.plan_mode.CliApprover = .{ .in = in, .out = err };
    var plan_mode: zg_ai.plan.PlanMode = .init(gpa, undefined, cwd, cli_approver.approver(), .{ .tools = &agent_tools });
    defer plan_mode.deinit();
    if (!one_shot) try tool_registry.addSource(plan_mode.source());

    // Skills and commands: managed, user and workspace `skills` and
    // `commands` (`.claude` too), run as `/name args` or by the model
    // through `skill`; shell injections run as child processes behind
    // the command-line rules, without prompting.
    const cfg_paths: ?zg_config.paths.ConfigPaths = zg_config.paths.resolve(arena, &env, .{}) catch null;
    var skill_index: zg_ai.ext.SkillIndex = try .load(gpa, io, try zg_ai.ext.skills.standardRoots(
        arena,
        cwd,
        if (cfg_paths) |p| p.config else null,
        if (cfg_paths) |p| p.managed else null,
        true,
    ));
    defer skill_index.deinit();
    for (skill_index.warnings.items) |w| err.print("zg agent: skipping skill {s}\n", .{w}) catch {};
    var skill_tool: zg_ai.ext.SkillTool = .init(gpa, &skill_index);
    defer skill_tool.deinit();
    skill_tool.subagents = &subagents;
    try tool_registry.addSource(skill_tool.source());

    // Context: the memory files (ZIGGURO.md, AGENTS.md and CLAUDE.md,
    // rules) in the system prompt, and compaction by the provider's
    // cheapest model, automatic near the window and on `/compact`.
    const default_model = env.get("ZG_MODEL") orelse "sonnet";
    var context: zg_ai.context.ContextStack = undefined;
    try context.init(gpa, io, .{
        .sources = if (opts.bare) null else .{
            .managed_dir = if (cfg_paths) |p| p.managed else null,
            .user_dir = if (cfg_paths) |p| p.config else null,
            .home_dir = env.get("HOME") orelse env.get("USERPROFILE"),
            .workspace_roots = &.{cwd},
            .cwd = cwd,
        },
        .env = .{ .cwd = cwd, .now_ms = zg_ai.ratelimit.Clock.real.now(io), .workspace_roots = &.{cwd}, .shell = env.get("SHELL") },
        .compaction = compaction: {
            const main_model = registry.resolve(opts.model orelse default_model) orelse break :compaction null;
            const m = registry.modelForRole(main_model, .compaction);
            const p = mgr.deps.providers.get(m) orelse break :compaction null;
            break :compaction .{ .provider = p, .model = m };
        },
    });
    defer context.deinit();
    for (context.memorySet().notes) |n| err.print("zg agent: {s}\n", .{n}) catch {};
    context.install(&mgr.deps);

    // Hooks (Claude Code format): managed and user `hooks.json`, then the
    // workspace's `.zigguro/hooks.json` and `hooks.local.json`, and in
    // compat `.claude/settings.json` and `settings.local.json`. Running
    // `zg agent` in a directory trusts it, as `claude -p` does.
    var hook_engine: zg_ai.ext.HookEngine = try .init(gpa, io, .{
        .project_dir = cwd,
        .environ = &env,
        .compat = true,
        .workspace_trusted = true,
        .spill_dir = try std.fs.path.join(arena, &.{ stateDir(min, &env, &state_buf_hooks) orelse cwd, "tool-output" }),
        .permission_mode = switch (opts.permission_mode) {
            .default => "default",
            .accept_edits => "acceptEdits",
            .plan => "plan",
            .bypass_permissions => "bypassPermissions",
            .dont_ask => "dontAsk",
        },
        .audit = .{ .ctx = err, .record = hookRecord, .notice = hookNotice },
    });
    defer hook_engine.deinit();
    try loadHooks(io, arena, &hook_engine, &env, cwd, err);
    mgr.deps.hooks = hook_engine.hooks();

    // Sessions live under the state directory.
    var state_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state = stateDir(min, &env, &state_buf);
    var store: ?zg_ai.session.store.SessionStore = null;
    defer if (store) |*s| s.deinit();
    // The index keeps the directory handle.
    var sessions_dir: ?Io.Dir = null;
    defer if (sessions_dir) |d| d.close(io);
    var index: ?zg_ai.session.index.SessionIndex = null;
    defer if (index) |*ix| ix.deinit();
    if (state) |dir| if (!opts.no_session_persistence) {
        store = try .init(gpa, dir, cwd);
        if (Io.Dir.cwd().createDirPath(io, store.?.dir)) |_| {
            sessions_dir = try Io.Dir.cwd().openDir(io, store.?.dir, .{ .iterate = true });
            index = zg_ai.session.index.SessionIndex.load(gpa, io, sessions_dir.?) catch null;
        } else |e| try err.print("zg agent: sessions will not be saved ({s})\n", .{@errorName(e)});
    };

    var sig: headless.signals.Signals = .{};
    headless.signals.install(&sig);

    opts.env = .{
        .stdin_piped = stdin_piped,
        .spill_dir = state orelse cwd,
        .store = if (store) |*s| s else null,
        .index = if (index) |*ix| ix else null,
        .signals = &sig,
        .err = err,
        .cwd = cwd,
        .default_model = default_model,
        .todos = &todos,
        .plan_mode = if (one_shot) null else &plan_mode,
        .skills = .{ .index = &skill_index, .tool = &skill_tool, .host = processes.host() },
        .context = &context,
        .agents = agent_defs.items,
        .hooks = &hook_engine,
        .validator = validator,
        .mcp_servers = mcp.statuses.items,
    };

    const code = if (one_shot)
        try headless.runPrint(io, gpa, mgr, opts, out, in)
    else
        try headless.runRepl(io, gpa, mgr, opts, out, in);
    out.flush() catch {};
    const err_tty = Io.File.stderr().isTty(io) catch false;
    review.finish(io, &env, err, if (!stdin_piped and err_tty) in else null, .{ .color = err_tty and env.get("NO_COLOR") == null }) catch |e|
        err.print("zg agent: review: {t}\n", .{e}) catch {};
    err.flush() catch {};
    return code.code();
}

const hook_files = [_]struct { []const u8, zg_ai.ext.hooks.Layer }{
    .{ ".zigguro/hooks.json", .project },
    .{ ".zigguro/hooks.local.json", .local },
    .{ ".claude/settings.json", .project },
    .{ ".claude/settings.local.json", .local },
};

/// Reads every hook file that exists; a broken one is reported and skipped.
fn loadHooks(io: Io, arena: std.mem.Allocator, e: *zg_ai.ext.HookEngine, env: *const std.process.Environ.Map, cwd: []const u8, err: *Io.Writer) !void {
    var files: std.ArrayList(struct { []const u8, zg_ai.ext.hooks.Layer }) = .empty;
    if (zg_config.paths.resolve(arena, env, .{})) |p| {
        if (p.managed) |m| try files.append(arena, .{ try std.fs.path.join(arena, &.{ m, "hooks.json" }), .managed });
        try files.append(arena, .{ try p.join(arena, .config, &.{"hooks.json"}), .user });
    } else |_| {}
    for (hook_files) |f| try files.append(arena, .{ try std.fs.path.join(arena, &.{ cwd, f[0] }), f[1] });
    for (files.items) |f| {
        const text = Io.Dir.cwd().readFileAlloc(io, f[0], arena, .limited(1 << 20)) catch continue;
        const parsed = zg_ai.ext.hooks.parseSettings(arena, text, f[1]) catch |e2| {
            err.print("zg agent: ignoring hooks in {s}: {s}\n", .{ f[0], @errorName(e2) }) catch {};
            continue;
        };
        for (parsed.unknown) |u| err.print("zg agent: {s}: unknown hook event {s}\n", .{ f[0], u }) catch {};
        if (parsed.disable_all) e.opts.disable_non_managed = true;
        e.add(parsed.sources) catch |e2| err.print("zg agent: ignoring hooks in {s}: {s}\n", .{ f[0], @errorName(e2) }) catch {};
    }
}

fn hookRecord(_: *anyopaque, _: Io, r: zg_ai.ext.hooks.HookRun) void {
    std.log.scoped(.zg_agent).debug("hook {t} {s}: exit {?d}, {d} ms, {s}", .{ r.event, r.handler, r.exit, r.duration_ms, r.decision });
}

fn hookNotice(ctx: *anyopaque, _: Io, text: []const u8) void {
    const err: *Io.Writer = @ptrCast(@alignCast(ctx));
    err.print("zg agent: {s}\n", .{text}) catch {};
    err.flush() catch {};
}

/// `--disallowed-tools` rules without a pattern remove the tool from
/// requests; patterned rules are checked per call.
fn bareRules(arena: std.mem.Allocator, rules: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (rules) |r| if (std.mem.indexOfScalar(u8, r, '(') == null) try out.append(arena, r);
    return out.items;
}

fn stateDir(min: std.process.Init.Minimal, env: *const std.process.Environ.Map, buf: []u8) ?[]const u8 {
    if (zg_crash.paths.stateDir(min.environ, buf)) |d| return d;
    if (builtin.os.tag == .windows) if (env.get("LOCALAPPDATA")) |base| {
        return std.fmt.bufPrint(buf, "{s}\\zigguro", .{base}) catch null;
    };
    return null;
}

/// Provider warnings go to stderr; keys are never printed.
const Notes = struct {
    err: *Io.Writer,

    fn warn(ctx: *anyopaque, msg: []const u8) void {
        const n: *Notes = @ptrCast(@alignCast(ctx));
        n.err.print("zg agent: {s}\n", .{msg}) catch {};
    }

    fn redact(_: *anyopaque, _: []const u8) void {}
};

/// No secret store until E16's keychain lands: keys come from the environment.
const no_secrets: zg_ai.keyref.SecretStore = .{ .ctx = @constCast(@as(*const anyopaque, &{})), .vtable = &.{ .get = getNone, .put = putNone } };

fn getNone(_: *anyopaque, _: Io, _: []const u8) zg_ai.keyref.SecretError!?[]const u8 {
    return null;
}

fn putNone(_: *anyopaque, _: Io, _: []const u8, _: []const u8) zg_ai.keyref.SecretError!void {
    return error.Unavailable;
}
