//! `AgentHost`: what a workbench agent runs on, set up like `zg agent`
//! (apps/zg/src/cmd_agent.zig) but with the IDE's seams: file tools
//! through `EditorFiles` (open documents are read and edited in the
//! editor), approvals through `ToolApprovals` over the workbench's dialog
//! `ApprovalPort`, and command tools over child processes until E06's
//! terminals take them. The other subsystems' tools (LSP, tasks, SCM,
//! MCP, ...) come through zg_ai's adapters as each package exports them;
//! none does yet.
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
const EditorFiles = @import("editor_files.zig").EditorFiles;
const ToolApprovals = @import("approvals.zig").ToolApprovals;

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
    file_tools: builtin_tools.files.FileTools,
    adapters: zg_ai.tools.adapters.all.Adapters,
    agent_tools: zg_ai.tools.AgentTools,
    approvals: ToolApprovals,
    mgr: *zg_ai.loop.AgentManager,
    /// The workbench's agent.
    agent: *Agent,

    /// An agent on the working folder whose file tools use the documents
    /// of `docs` and whose approvals go through `port`. UI thread.
    pub fn create(rt: *zg_core.Runtime, env: *const std.process.Environ.Map, app: *zg_gui.App, docs: *zg_editor.model.api.registry.DocumentRegistry, port: zg_security.contracts.ApprovalPort) !*AgentHost {
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
        h.file_tools = .{ .files = h.files.files(), .tracker = &h.tracker };
        try h.tools.addSource(h.file_tools.source());
        h.adapters = .init(gpa, io);
        errdefer h.adapters.deinit();
        try h.adapters.registerAll(&h.tools, &.{}, .{}, .{});
        h.agent_tools = .init(gpa, io, &h.tools, .{});
        errdefer h.agent_tools.deinit();
        h.approvals = .init(gpa, port);
        errdefer h.approvals.deinit();

        h.mgr = try zg_ai.loop.AgentManager.init(gpa, io, .{
            .registry = &h.models,
            .providers = .fromHub(h.hub),
            .tools = h.agent_tools.tools(),
            .permission = h.approvals.permission(),
        });
        errdefer h.mgr.deinit();
        h.agent = try h.mgr.create(.{ .model = env.get("ZG_MODEL") orelse "sonnet", .cwd = h.cwd });
        // Undo groups name the agent's session.
        h.files.edits.session = @truncate(h.agent.ref.session);
        return h;
    }

    /// Frees everything; the agent must be idle (`AgentPanel.destroy`
    /// stops it). UI thread.
    pub fn destroy(h: *AgentHost) void {
        const gpa = h.gpa;
        h.mgr.deinit();
        h.approvals.deinit();
        h.agent_tools.deinit();
        h.files.deinit();
        h.tracker.deinit();
        h.run_tools.deinit();
        h.processes.deinit();
        h.tools.deinit();
        h.adapters.deinit();
        h.hub.deinit();
        h.limiter.deinit();
        h.client.deinit();
        h.models.deinit();
        gpa.free(h.cwd);
        gpa.destroy(h);
    }

    fn warn(_: *anyopaque, msg: []const u8) void {
        log.warn("{s}", .{msg});
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
