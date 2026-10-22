//! `AgentHost`: what a workbench agent runs on, set up like `zg agent`
//! (apps/zg/src/cmd_agent.zig) but with the IDE's seams: file tools
//! through `EditorFiles` (open documents are read and edited in the
//! editor, other writes recorded by E12's `ReviewGlue`, which also takes
//! a checkpoint per user turn), approvals through `ToolApprovals` over the workbench's
//! approvals inbox (E12's `ApprovalBroker`, journaled in the review store), and command tools over child processes until E06's
//! terminals take them. The other subsystems' tools (LSP, tasks, SCM,
//! MCP, ...) come through zg_ai's adapters as each package exports them;
//! none does yet.
//!
//! Context as in `zg agent` (zg_ai's `ContextStack`): the memory files
//! (ZIGGURO.md, AGENTS.md, CLAUDE.md and rules from the home folder and
//! the workspace) and the environment block go into the system prompt,
//! and the conversation is compacted by the provider's compaction model
//! near the window and on `/compact`.
//!
//! MCP servers: once the workspace is trusted, `connectMcp` reads the
//! project's `.mcp.json` (Claude Code), `.vscode/mcp.json` (VS Code) and
//! `.zigguro/mcp.json`, in that order (a later entry of the same name
//! wins), connects them on a worker and registers their tools as
//! `mcp__<server>__<tool>`, as `zg agent --mcp-config` does.
//!
//! Providers and keys come from the environment (ANTHROPIC_API_KEY,
//! OPENAI_API_KEY, GEMINI_API_KEY); ZG_MODEL picks the model (else
//! "sonnet"). Sessions are not saved yet.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_ai = @import("zg_ai");
const zg_net = @import("zg_net");
const zg_gui = @import("zg_gui");
const zg_editor = @import("zg_editor");
const zg_security = @import("zg_security");
const zg_review = @import("zg_review");
const zg_mcp = @import("zg_mcp");
const zg_mcp_servers = @import("zg_mcp_servers");
const EditorFiles = @import("editor_files.zig").EditorFiles;
const ReviewGlue = @import("review_glue.zig").ReviewGlue;
const ToolApprovals = @import("approvals.zig").ToolApprovals;
const PlanCards = @import("plan_card.zig").PlanCards;
const ChildRelay = @import("panel.zig").ChildRelay;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Agent = zg_ai.loop.Agent;
const builtin_tools = zg_ai.tools.builtin;
const log = std.log.scoped(.agent);

/// See the module doc.
pub const AgentHost = struct {
    gpa: Allocator,
    io: Io,
    /// The working folder (absolute).
    cwd: [:0]u8,
    models: zg_ai.ModelRegistry,
    client: *zg_net.http.Client,
    net: zg_ai.transport.ZgNet,
    limiter: zg_ai.ratelimit.RateLimiter,
    hub: *zg_ai.ProviderHub,
    tools: zg_ai.tools.ToolRegistry,
    processes: builtin_tools.process_host.ProcessHost,
    run_tools: builtin_tools.run.RunTools,
    tracker: zg_ai.tools.read_tracker.ReadTracker,
    files: EditorFiles,
    /// E12: agent writes recorded, a checkpoint per user turn, and the
    /// restore behind rewind.
    review: *ReviewGlue,
    file_tools: builtin_tools.files.FileTools,
    adapters: zg_ai.tools.adapters.all.Adapters,
    agent_tools: zg_ai.tools.AgentTools,
    approvals: ToolApprovals,
    mgr: *zg_ai.loop.AgentManager,
    /// Memory files, reminders, the context assembler and compaction.
    context: zg_ai.context.ContextStack,
    /// The workspace roots the context reads (just `cwd`).
    roots: [1][]const u8,
    /// The workbench's agent.
    agent: *Agent,
    /// Plan mode and its approval cards (in the agent panel).
    plans: PlanCards,
    plan_mode: zg_ai.plan.PlanMode,
    /// Subagents (`.zigguro/agents/*.md`, then the built-ins) through the
    /// `task` tool; their events reach the panel through `children`.
    defs_arena: std.heap.ArenaAllocator,
    subagents: zg_ai.subagent.SubagentRunner,
    task: zg_ai.subagent.task_tool.TaskTool,
    children: ChildRelay,
    /// The project's MCP servers (`connectMcp`).
    mcp: zg_mcp_servers.Servers,
    /// The connect running on a worker.
    mcp_task: ?Io.Future(void) = null,

    /// An agent on the working folder whose file tools use the documents
    /// of `docs` and whose approvals go to `approvals` (which outlives the
    /// host). UI thread.
    pub fn create(rt: *zg_core.Runtime, env: *const std.process.Environ.Map, app: *zg_gui.App, docs: *zg_editor.model.api.registry.DocumentRegistry, approvals: *zg_review.approvals.ApprovalBroker) !*AgentHost {
        const gpa = rt.gpa;
        const io = rt.io;
        const h = try gpa.create(AgentHost);
        errdefer gpa.destroy(h);
        h.gpa = gpa;
        h.io = io;
        h.cwd = try std.process.currentPathAlloc(io, gpa);
        errdefer gpa.free(h.cwd);

        h.models = .init(gpa, io, zg_ai.models.registry.builtin_catalog);
        errdefer h.models.deinit();
        h.client = try zg_net.http.Client.init(rt, .{ .environ_map = env });
        errdefer h.client.deinit();
        h.net = .{ .client = h.client };
        h.limiter = .init(gpa, .real);
        errdefer h.limiter.deinit();
        h.hub = try zg_ai.ProviderHub.init(gpa, .{
            .secrets = no_secrets,
            .environ = env,
            .transport = h.net.transport(),
            .limiter = &h.limiter,
            .registry = &h.models,
            .notifier = .{ .ctx = h, .warn = warn, .redact = redact },
        });
        errdefer h.hub.deinit();
        try h.hub.onSettingsChanged(io, &.{});

        h.tools = .init(gpa, io);
        errdefer h.tools.deinit();
        h.processes = .init(gpa, io);
        h.processes.environ = env;
        errdefer h.processes.deinit();
        h.run_tools = .init(gpa, io, h.processes.host(), .{ .visible = false });
        errdefer h.run_tools.deinit();
        try h.tools.addSource(h.run_tools.source());
        h.tracker = .init(gpa, io);
        errdefer h.tracker.deinit();
        h.files = .init(gpa, app, h.cwd, docs, 0);
        errdefer h.files.deinit();
        h.review = try ReviewGlue.create(gpa, io, h.cwd, .{ .persist = true, .approvals = approvals });
        errdefer h.review.destroy();
        h.files.outside = h.review.files();
        h.file_tools = .{ .files = h.files.files(), .tracker = &h.tracker };
        try h.tools.addSource(h.file_tools.source());
        h.adapters = .init(gpa, io);
        errdefer h.adapters.deinit();
        try h.adapters.registerAll(&h.tools, &.{}, .{}, .{});
        h.agent_tools = .init(gpa, io, &h.tools, .{});
        errdefer h.agent_tools.deinit();
        h.approvals = .init(gpa, approvals.approvalPort());
        errdefer h.approvals.deinit();

        h.mgr = try zg_ai.loop.AgentManager.init(gpa, io, .{
            .registry = &h.models,
            .providers = .fromHub(h.hub),
            .tools = h.agent_tools.tools(),
            .permission = h.approvals.permission(),
            .checkpoints = h.review.checkpoints(),
            // Each turn's writes become a changeset in the review queue.
            .turn_end = h.file_tools.turnEnd(),
            // Tool inputs are checked by E11's JSON Schema validator, as
            // in `zg agent`.
            .validator = zg_mcp.schema.toolValidator(zg_ai.schema.validate),
        });
        errdefer h.mgr.deinit();
        const model_name = env.get("ZG_MODEL") orelse "sonnet";
        h.roots = .{h.cwd};
        try h.context.init(gpa, io, .{
            .sources = .{
                .home_dir = env.get("HOME") orelse env.get("USERPROFILE"),
                .workspace_roots = &h.roots,
                .cwd = h.cwd,
            },
            .env = .{ .cwd = h.cwd, .now_ms = zg_ai.ratelimit.Clock.real.now(io), .workspace_roots = &h.roots, .shell = env.get("SHELL") },
            .compaction = compaction: {
                const main_model = h.models.resolve(model_name) orelse break :compaction null;
                const m = h.models.modelForRole(main_model, .compaction);
                const p = h.mgr.deps.providers.get(m) orelse break :compaction null;
                break :compaction .{ .provider = p, .model = m };
            },
        });
        errdefer h.context.deinit();
        for (h.context.memorySet().notes) |n| log.info("{s}", .{n});
        // Before the agent: it copies the manager's deps.
        h.context.install(&h.mgr.deps);
        h.agent = try h.mgr.create(.{ .model = model_name, .cwd = h.cwd });
        // Undo groups name the agent's session.
        h.files.edits.session = @truncate(h.agent.ref.session);
        // Plan mode: `exit_plan_mode` asks through the panel's plan card.
        h.plans = .init(gpa, io, app);
        errdefer h.plans.deinit();
        h.plan_mode = .init(gpa, h.agent, h.cwd, h.plans.approver(), .{ .tools = &h.agent_tools });
        errdefer h.plan_mode.deinit();
        try h.tools.addSource(h.plan_mode.source());

        h.defs_arena = .init(gpa);
        errdefer h.defs_arena.deinit();
        const da = h.defs_arena.allocator();
        var agent_defs: std.ArrayList(zg_ai.subagent.defs.AgentDef) = .empty;
        const agents_dir = try std.fs.path.join(da, &.{ h.cwd, ".zigguro", "agents" });
        try zg_ai.subagent.defs.loadDefs(io, da, &.{.{ .dir = agents_dir, .source = .project }}, &agent_defs, null);
        h.subagents = .init(gpa, io, h.mgr, &h.tools, agent_defs.items, .{});
        h.subagents.main_tools = &h.agent_tools;
        errdefer h.subagents.deinit();
        h.task = try .init(gpa, &h.subagents);
        errdefer h.task.deinit();
        try h.tools.addSource(h.task.source());
        h.mcp = .init(gpa);
        h.mcp_task = null;
        h.children = .{ .io = io };
        try h.mgr.subscribeAll(h.children.subscriber());
        return h;
    }

    /// Frees everything; the agent must be idle (`AgentPanel.destroy`
    /// stops it). UI thread.
    pub fn destroy(h: *AgentHost) void {
        const gpa = h.gpa;
        if (h.mcp_task) |*t| t.await(h.io);
        h.subagents.deinit();
        h.mgr.deinit();
        h.context.deinit();
        h.task.deinit();
        h.defs_arena.deinit();
        h.plan_mode.deinit();
        h.plans.deinit();
        h.approvals.deinit();
        h.agent_tools.deinit();
        h.files.deinit();
        h.review.destroy();
        h.tracker.deinit();
        h.run_tools.deinit();
        h.processes.deinit();
        h.tools.deinit();
        h.adapters.deinit();
        h.mcp.deinit();
        h.hub.deinit();
        h.limiter.deinit();
        h.client.deinit();
        h.models.deinit();
        gpa.free(h.cwd);
        gpa.destroy(h);
    }

    /// The MCP config files of the project, in load order.
    pub const mcp_configs = [_][]const u8{ ".mcp.json", ".vscode/mcp.json", ".zigguro/mcp.json" };

    /// Connects the project's MCP servers on a worker (once; only for a
    /// trusted workspace: the configs start programs). `rt` and `env`
    /// outlive the host.
    pub fn connectMcp(h: *AgentHost, rt: *zg_core.Runtime, env: *const std.process.Environ.Map) void {
        if (h.mcp_task != null) return;
        h.mcp_task = h.io.concurrent(loadMcp, .{ h, rt, env }) catch {
            loadMcp(h, rt, env);
            return;
        };
    }

    fn loadMcp(h: *AgentHost, rt: *zg_core.Runtime, env: *const std.process.Environ.Map) void {
        var arena: std.heap.ArenaAllocator = .init(h.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const paths = projectMcpConfigs(h.io, a, h.cwd) catch return;
        if (paths.len == 0) return;
        var warn_buf: Io.Writer.Allocating = .init(a);
        h.mcp.load(rt, h.client, paths, env, h.cwd, &warn_buf.writer) catch |e| {
            log.warn("MCP servers: {t}", .{e});
            return;
        };
        var lines = std.mem.splitScalar(u8, warn_buf.written(), '\n');
        while (lines.next()) |l| if (l.len > 0) log.warn("{s}", .{l});
        h.adapters.registerAll(&h.tools, &.{ .mcp = h.mcp.exporters.items }, .{ .lsp = false, .tasks = false, .workspace = false, .notes = false, .scm = false }, .{}) catch |e| {
            log.warn("MCP tools: {t}", .{e});
            return;
        };
        log.info("{d} MCP server(s) connected", .{h.mcp.exporters.items.len});
    }

    fn warn(_: *anyopaque, msg: []const u8) void {
        log.warn("{s}", .{msg});
    }

    fn redact(_: *anyopaque, _: []const u8) void {}
};

/// The MCP config files `root` has, in load order (`AgentHost.mcp_configs`).
pub fn projectMcpConfigs(io: Io, arena: Allocator, root: []const u8) Allocator.Error![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for (AgentHost.mcp_configs) |rel| {
        const path = try std.fs.path.join(arena, &.{ root, rel });
        Io.Dir.cwd().access(io, path, .{}) catch continue;
        try paths.append(arena, path);
    }
    return paths.items;
}

/// No secret store until E16's keychain lands: keys come from the environment.
const no_secrets: zg_ai.keyref.SecretStore = .{ .ctx = @constCast(@as(*const anyopaque, &{})), .vtable = &.{ .get = getNone, .put = putNone } };

fn getNone(_: *anyopaque, _: Io, _: []const u8) zg_ai.keyref.SecretError!?[]const u8 {
    return null;
}

fn putNone(_: *anyopaque, _: Io, _: []const u8, _: []const u8) zg_ai.keyref.SecretError!void {
    return error.Unavailable;
}

test "agent host: the project's MCP configs, in load order" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    try std.testing.expectEqual(@as(usize, 0), (try projectMcpConfigs(io, a, root)).len);
    try tmp.dir.createDirPath(io, ".zigguro");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zigguro/mcp.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".mcp.json", .data = "{}" });
    const got = try projectMcpConfigs(io, a, root);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expect(std.mem.endsWith(u8, got[0], ".mcp.json") and !std.mem.endsWith(u8, got[0], "/mcp.json"));
    try std.testing.expect(std.mem.endsWith(u8, got[1], ".zigguro/mcp.json") or std.mem.endsWith(u8, got[1], ".zigguro\\mcp.json"));
}
