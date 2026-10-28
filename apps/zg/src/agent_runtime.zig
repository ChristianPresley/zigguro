//! The agent runtime the headless commands share (`zg agents host`,
//! `zg workflow run`): model providers from the environment, command and
//! file tools (file edits held for review, as `zg agent --review defer`),
//! the E10 agent manager and its `RunHost` adapter. Fields point at each
//! other, so it lives on the heap.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_ai = @import("zg_ai");
const zg_net = @import("zg_net");
const zg_agents = @import("zg_agents");
const review_hooks = @import("review_hooks.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const runs = zg_agents.runs;

pub const AgentRuntime = struct {
    gpa: Allocator,
    env: *std.process.Environ.Map,
    /// The workspace's real path.
    cwd: [:0]u8,
    models: zg_ai.ModelRegistry,
    client: *zg_net.http.Client,
    net: zg_ai.transport.ZgNet,
    limiter: zg_ai.ratelimit.RateLimiter,
    hub: *zg_ai.ProviderHub,
    tool_registry: zg_ai.tools.ToolRegistry,
    processes: zg_ai.tools.builtin.process_host.ProcessHost,
    run_tools: zg_ai.tools.builtin.run.RunTools,
    read_tracker: zg_ai.tools.read_tracker.ReadTracker,
    review: review_hooks.Review,
    file_tools: zg_ai.tools.builtin.files.FileTools,
    agent_tools: zg_ai.tools.AgentTools,
    mgr: *zg_ai.loop.AgentManager,
    e10: runs.E10Agents,
    warn_ctx: WarnCtx,

    /// `warn` receives provider warnings (`zg agents host: …` lines).
    pub fn create(rt: *zg_core.Runtime, env: *std.process.Environ.Map, workspace: []const u8, warn_out: *Io.Writer, prefix: []const u8) !*AgentRuntime {
        const gpa = rt.gpa;
        const io = rt.io;
        const r = try gpa.create(AgentRuntime);
        errdefer gpa.destroy(r);
        r.gpa = gpa;
        r.env = env;
        r.warn_ctx = .{ .out = warn_out, .prefix = prefix };
        r.models = zg_ai.ModelRegistry.init(gpa, io, zg_ai.models.registry.builtin_catalog);
        errdefer r.models.deinit();
        r.client = try zg_net.http.Client.init(rt, .{ .environ_map = env });
        errdefer r.client.deinit();
        r.net = .{ .client = r.client };
        r.limiter = .init(gpa, .real);
        errdefer r.limiter.deinit();
        r.hub = try zg_ai.ProviderHub.init(gpa, .{
            .secrets = no_secrets,
            .environ = env,
            .transport = r.net.transport(),
            .limiter = &r.limiter,
            .registry = &r.models,
            .notifier = .{ .ctx = &r.warn_ctx, .warn = warn, .redact = redact },
        });
        errdefer r.hub.deinit();
        try r.hub.onSettingsChanged(io, &.{});
        r.cwd = try Io.Dir.cwd().realPathFileAlloc(io, workspace, gpa);
        errdefer gpa.free(r.cwd);
        r.tool_registry = .init(gpa, io);
        errdefer r.tool_registry.deinit();
        r.processes = .init(gpa, io);
        r.processes.environ = env;
        errdefer r.processes.deinit();
        r.run_tools = .init(gpa, io, r.processes.host(), .{ .visible = false });
        errdefer r.run_tools.deinit();
        try r.tool_registry.addSource(r.run_tools.source());
        r.read_tracker = .init(gpa, io);
        errdefer r.read_tracker.deinit();
        r.review = try .init(gpa, io, r.cwd, .@"defer", "default");
        errdefer r.review.deinit();
        r.file_tools = .{ .files = r.review.glue.files(), .tracker = &r.read_tracker };
        try r.tool_registry.addSource(r.file_tools.source());
        r.agent_tools = .init(gpa, io, &r.tool_registry, .{});
        errdefer r.agent_tools.deinit();
        r.mgr = try zg_ai.loop.AgentManager.init(gpa, io, .{
            .registry = &r.models,
            .providers = .fromHub(r.hub),
            .tools = r.agent_tools.tools(),
            .checkpoints = r.review.glue.checkpoints(),
            .turn_end = r.file_tools.turnEnd(),
        });
        r.e10 = .init(gpa, io, r.mgr, .{ .default_model = env.get("ZG_MODEL") orelse "sonnet" });
        return r;
    }

    pub fn destroy(r: *AgentRuntime) void {
        r.mgr.deinit();
        r.agent_tools.deinit();
        r.review.deinit();
        r.read_tracker.deinit();
        r.run_tools.deinit();
        r.processes.deinit();
        r.tool_registry.deinit();
        r.gpa.free(r.cwd);
        r.hub.deinit();
        r.limiter.deinit();
        r.client.deinit();
        r.models.deinit();
        r.gpa.destroy(r);
    }

    pub fn agentPort(r: *AgentRuntime) runs.port.AgentPort {
        return r.e10.agentPort();
    }
};

const WarnCtx = struct { out: *Io.Writer, prefix: []const u8 };

fn warn(ctx: *anyopaque, msg: []const u8) void {
    const w: *WarnCtx = @ptrCast(@alignCast(ctx));
    w.out.print("{s}: {s}\n", .{ w.prefix, msg }) catch {};
}

fn redact(_: *anyopaque, _: []const u8) void {}

pub const no_secrets: zg_ai.keyref.SecretStore = .{ .ctx = @constCast(@as(*const anyopaque, &{})), .vtable = &.{ .get = getNone, .put = putNone } };

fn getNone(_: *anyopaque, _: Io, _: []const u8) zg_ai.keyref.SecretError!?[]const u8 {
    return null;
}

fn putNone(_: *anyopaque, _: Io, _: []const u8, _: []const u8) zg_ai.keyref.SecretError!void {
    return error.Unavailable;
}
