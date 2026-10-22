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

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_ai = @import("zg_ai");
const zg_net = @import("zg_net");
const zg_crash = @import("zg_crash");

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

    var diag: []const u8 = "invalid arguments";
    var opts = headless.args.parseArgsDiag(arena, argv, &diag) catch |e| switch (e) {
        error.Usage => {
            try err.print("zg agent: {s}\nRun 'zg agent --help' for usage.\n", .{diag});
            try err.flush();
            return headless.ExitCode.usage.code();
        },
        else => return e,
    };
    if (opts.help) {
        try out.writeAll(headless.args.usage_text);
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

    // Tools: the file tools straight on disk, the command tools over
    // child processes and the web tools (the IDE uses E05 documents and E06
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
    var disk: zg_ai.tools.builtin.disk_files.DiskFiles = .{ .root = cwd };
    var file_tools: zg_ai.tools.builtin.files.FileTools = .{ .files = disk.asFiles(), .tracker = &read_tracker };
    try tool_registry.addSource(file_tools.source());
    // Web tools: fetch over the same transport (so cassettes record it) and
    // the provider's own search for models that have one.
    var web_fetch: zg_ai.tools.builtin.web_fetch.WebFetch = .init(gpa, io, transport, .{});
    defer web_fetch.deinit();
    try tool_registry.addSource(web_fetch.source());
    var web_search: zg_ai.tools.builtin.web_search.WebSearch = .init(io, transport, .provider_native);
    try tool_registry.addSource(web_search.source());
    var agent_tools: zg_ai.tools.AgentTools = .init(gpa, io, &tool_registry, .{
        .deny = try bareRules(arena, opts.disallowed_tools),
        .mode = opts.permission_mode,
    });
    defer agent_tools.deinit();

    const mgr = try zg_ai.loop.AgentManager.init(gpa, io, .{ .registry = &registry, .providers = .fromHub(hub), .tools = agent_tools.tools() });
    defer mgr.deinit();

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
        .stdin_piped = !(Io.File.stdin().isTty(io) catch true),
        .spill_dir = state orelse cwd,
        .store = if (store) |*s| s else null,
        .index = if (index) |*ix| ix else null,
        .signals = &sig,
        .err = err,
        .cwd = cwd,
        .default_model = env.get("ZG_MODEL") orelse "sonnet",
    };

    var in_buf: [64 * 1024]u8 = undefined;
    var in_r: Io.File.Reader = .initStreaming(.stdin(), io, &in_buf);
    const in = &in_r.interface;
    const code = if (opts.prompt != null or opts.streamInput() or opts.env.stdin_piped)
        try headless.runPrint(io, gpa, mgr, opts, out, in)
    else
        try headless.runRepl(io, gpa, mgr, opts, out, in);
    out.flush() catch {};
    err.flush() catch {};
    return code.code();
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
