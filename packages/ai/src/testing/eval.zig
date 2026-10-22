//! The evaluation runner (E10.F10.S02.T02): runs agent scenarios against
//! fixture workspaces, grades what they leave behind and compares the
//! results with a baseline.
//!
//! A suite directory holds `scenarios/*.zon` (one `Scenario` each),
//! `fixtures/<name>/` (the starting workspaces) and `baseline.json`.
//! Each scenario copies its fixture into a fresh directory under the work
//! directory, so scenarios run concurrently.
//!
//! The model is one of:
//! - a script (`Scenario.script`): the model's turns, written out. Each
//!   turn can `expect` text in the request it answers, so a loop that drops
//!   tool results or history fails the scenario. This is how the suite
//!   runs offline.
//! - a cassette (`Scenario.cassette`): recorded provider HTTP, replayed
//!   through the real provider.
//! - live (`EvalOptions.live`): the real provider, recording missing
//!   exchanges into the scenario's cassette (`record_missing`).
//!
//! The agent runs headless through `runPrint` with stream-json output and
//! no memory files (the `--bare` context), plus the scenario's
//! permission mode, tool rules and hooks. The transcript gives the tools
//! used, turns, tokens, cost and permission denials.

const std = @import("std");
const proto = @import("zg_ai_proto");
const graders = @import("graders.zig");
const cassette_mod = @import("cassette.zig");
const reg_mod = @import("../models/registry.zig");
const scripted = @import("../provider/scripted.zig");
const Provider = @import("../provider/Provider.zig");
const request = @import("../provider/request.zig");
const tp = @import("../provider/transport.zig");
const hub_mod = @import("../provider/hub.zig");
const keyref = @import("../provider/keyref.zig");
const ratelimit = @import("../provider/ratelimit.zig");
const AgentManager = @import("../loop/Manager.zig");
const deps = @import("../loop/deps.zig");
const tool_registry = @import("../tools/registry.zig");
const toolset = @import("../tools/toolset.zig");
const read_tracker = @import("../tools/read_tracker.zig");
const process_host = @import("../tools/builtin/process_host.zig");
const run_tools = @import("../tools/builtin/run.zig");
const files = @import("../tools/builtin/files.zig");
const disk_files = @import("../tools/builtin/disk_files.zig");
const compactor = @import("../context/compactor.zig");
const args = @import("../headless/args.zig");
const print = @import("../headless/print.zig");
const store_mod = @import("../session/store.zig");
const index_mod = @import("../session/index.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Step = scripted.ScriptedProvider.Step;

pub const Grader = graders.Grader;

/// One tool call in a scripted turn.
pub const ToolUse = struct {
    name: []const u8,
    /// The input as JSON text.
    input: []const u8 = "{}",
};

/// One scripted model turn.
pub const Turn = struct {
    text: []const u8 = "",
    tools: []const ToolUse = &.{},
    /// Each must appear in the request this turn answers (its messages'
    /// text and tool results).
    expect: []const []const u8 = &.{},
    input_tokens: u32 = 1000,
    output_tokens: u32 = 50,
};

/// A `PreToolUse` hook rule.
pub const Hook = struct {
    tool: []const u8,
    /// Matches when the input JSON contains this; empty matches all.
    input_contains: []const u8 = "",
    decision: enum { deny, ask, allow } = .deny,
    reason: []const u8 = "blocked by a hook",
};

pub const Scenario = struct {
    name: []const u8,
    fixture: []const u8,
    prompt: []const u8,
    /// `cassette` and `cassette-small` (an 8k window) for scripts; a
    /// catalog model for cassettes.
    model: []const u8 = "cassette",
    permission_mode: []const u8 = "accept-edits",
    max_turns: u32 = 20,
    /// Relative to the suite directory.
    cassette: ?[]const u8 = null,
    graders: []const Grader,
    script: []const Turn = &.{},
    allowed_tools: []const []const u8 = &.{},
    disallowed_tools: []const []const u8 = &.{},
    hooks: []const Hook = &.{},
    /// A second prompt, run with `--continue` after the first.
    followup: ?[]const u8 = null,
    /// Compact once the estimated request grows by this many tokens over
    /// the first request of the run.
    compact_after_tokens: ?u64 = null,
};

/// Live runs: the real provider, recording missing exchanges.
pub const Live = struct {
    transport: tp.Transport,
    environ: *const std.process.Environ.Map,
    model: []const u8,
};

pub const EvalOptions = struct {
    /// Absolute; each scenario gets `<work_dir>/<name>`.
    work_dir: []const u8,
    /// Only scenarios whose name contains this.
    filter: ?[]const u8 = null,
    /// Scenarios run at once; the CPU count when null.
    jobs: ?u32 = null,
    live: ?Live = null,
    /// The zig that `command_succeeds` runs for `zig`.
    zig_exe: ?[]const u8 = null,
    /// The environment of commands (agent and graders); null inherits.
    environ: ?*const std.process.Environ.Map = null,
};

pub const GraderResult = struct {
    grader: []const u8,
    ok: bool,
    detail: []const u8,
};

pub const Result = struct {
    name: []const u8,
    passed: bool = false,
    /// Set when the scenario could not run or its script went wrong.
    error_text: ?[]const u8 = null,
    graders: []const GraderResult = &.{},
    exit_code: u8 = 0,
    turns: u32 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cost_usd: f64 = 0,
    wall_ms: u64 = 0,
};

pub const Report = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    results: []Result,

    pub fn deinit(r: *Report) void {
        r.arena.deinit();
    }

    pub fn passed(r: *const Report) usize {
        var n: usize = 0;
        for (r.results) |x| n += @intFromBool(x.passed);
        return n;
    }

    /// The human-readable table.
    pub fn writeTable(r: *const Report, w: *Io.Writer) Io.Writer.Error!void {
        var width: usize = 8;
        for (r.results) |x| width = @max(width, x.name.len);
        try w.writeAll("scenario");
        try w.splatByteAll(' ', width - 8);
        try w.writeAll("  result  turns  tokens in/out     cost  wall ms\n");
        for (r.results) |x| {
            try w.writeAll(x.name);
            try w.splatByteAll(' ', width - x.name.len);
            try w.print("  {s}  {d:>5}  {d:>7}/{d:<6}  ${d:>6.4}  {d:>7}\n", .{ if (x.passed) "pass" else "FAIL", x.turns, x.input_tokens, x.output_tokens, x.cost_usd, x.wall_ms });
            if (x.passed) continue;
            if (x.error_text) |e| try w.print("    error: {s}\n", .{e});
            for (x.graders) |g| if (!g.ok) try w.print("    {s}: {s}\n", .{ g.grader, g.detail });
        }
        try w.print("{d}/{d} scenarios passed\n", .{ r.passed(), r.results.len });
    }

    /// `report.json`.
    pub fn writeJson(r: *const Report, w: *Io.Writer) Io.Writer.Error!void {
        try std.json.Stringify.value(.{
            .version = 1,
            .passed = r.passed(),
            .total = r.results.len,
            .scenarios = r.results,
        }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, w);
        try w.writeByte('\n');
    }
};

/// Loads every scenario under `<dir>/scenarios`, sorted by file name.
pub fn loadScenarios(io: Io, arena: Allocator, dir: []const u8) ![]Scenario {
    const sdir = try std.fs.path.join(arena, &.{ dir, "scenarios" });
    var d = try Io.Dir.cwd().openDir(io, sdir, .{ .iterate = true });
    defer d.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".zon")) try names.append(arena, try arena.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    const out = try arena.alloc(Scenario, names.items.len);
    for (names.items, out) |n, *s| {
        const src = try d.readFileAllocOptions(io, n, arena, .limited(1 << 20), .of(u8), 0);
        s.* = parseScenario(arena, src) catch |e| {
            std.log.err("eval: {s}/{s} is not a valid scenario", .{ sdir, n });
            return e;
        };
    }
    return out;
}

/// Parses one scenario file.
pub fn parseScenario(arena: Allocator, src: [:0]const u8) !Scenario {
    return std.zon.parse.fromSliceAlloc(Scenario, arena, src, null, .{ .free_on_error = false });
}

/// Runs the suite in `dir`.
pub fn runSuite(io: Io, gpa: Allocator, dir: []const u8, opts: EvalOptions) !Report {
    var report: Report = .{ .gpa = gpa, .arena = .init(gpa), .results = &.{} };
    errdefer report.deinit();
    const a = report.arena.allocator();
    const all = try loadScenarios(io, a, dir);
    var picked: std.ArrayList(Scenario) = .empty;
    for (all) |s| if (opts.filter == null or std.mem.indexOf(u8, s.name, opts.filter.?) != null) try picked.append(a, s);
    report.results = try a.alloc(Result, picked.items.len);
    try runScenarios(io, gpa, dir, picked.items, report.results, a, opts);
    return report;
}

/// Runs `scenarios` concurrently into `results` (same length), with
/// result text in `arena`.
pub fn runScenarios(io: Io, gpa: Allocator, dir: []const u8, scenarios: []const Scenario, results: []Result, arena: Allocator, opts: EvalOptions) !void {
    std.debug.assert(scenarios.len == results.len);
    // One arena per scenario, merged into `arena` by copying at the end.
    const arenas = try gpa.alloc(std.heap.ArenaAllocator, scenarios.len);
    defer gpa.free(arenas);
    for (arenas) |*x| x.* = .init(gpa);
    defer for (arenas) |*x| x.deinit();

    var pool: Pool = .{ .io = io, .gpa = gpa, .dir = dir, .scenarios = scenarios, .results = results, .arenas = arenas, .opts = opts };
    const jobs: usize = @max(1, opts.jobs orelse @as(u32, @intCast(std.Thread.getCpuCount() catch 1)));
    var group: Io.Group = .init;
    for (0..@min(jobs, scenarios.len)) |_| group.async(io, Pool.work, .{&pool});
    try group.await(io);
    for (results) |*r| r.* = try cloneResult(arena, r.*);
}

const Pool = struct {
    io: Io,
    gpa: Allocator,
    dir: []const u8,
    scenarios: []const Scenario,
    results: []Result,
    arenas: []std.heap.ArenaAllocator,
    opts: EvalOptions,
    next: std.atomic.Value(usize) = .init(0),

    fn work(p: *Pool) void {
        while (true) {
            const i = p.next.fetchAdd(1, .monotonic);
            if (i >= p.scenarios.len) return;
            const s = &p.scenarios[i];
            const a = p.arenas[i].allocator();
            const t0 = Io.Timestamp.now(p.io, .awake);
            p.results[i] = runOne(p.io, p.gpa, a, p.dir, s, p.opts) catch |e| .{
                .name = s.name,
                .error_text = std.fmt.allocPrint(a, "the scenario could not run: {s}", .{@errorName(e)}) catch "out of memory",
            };
            p.results[i].wall_ms = @intCast(@max(0, t0.durationTo(Io.Timestamp.now(p.io, .awake)).toMilliseconds()));
        }
    }
};

/// The models scripts run as.
pub const script_catalog: [:0]const u8 =
    \\.{
    \\    .retrieved = "eval",
    \\    .models = .{
    \\        .{ .id = "cassette", .context_window = 200_000, .max_output = 32_000, .base = .claude,
    \\           .price = .{ .input_per_mtok_micros = 3_000_000, .output_per_mtok_micros = 15_000_000 } },
    \\        .{ .id = "cassette-small", .context_window = 8_000, .max_output = 4_000, .base = .claude,
    \\           .price = .{ .input_per_mtok_micros = 3_000_000, .output_per_mtok_micros = 15_000_000 } },
    \\    },
    \\}
;

/// Runs one scenario; text in `a`.
pub fn runOne(io: Io, gpa: Allocator, a: Allocator, dir: []const u8, s: *const Scenario, opts: EvalOptions) !Result {
    var result: Result = .{ .name = s.name };

    // The workspace.
    const fixture = try std.fs.path.join(a, &.{ dir, "fixtures", s.fixture });
    const workspace = try std.fs.path.join(a, &.{ opts.work_dir, s.name });
    try copyTree(io, a, fixture, workspace);
    const state_dir = try std.fs.path.join(a, &.{ opts.work_dir, try std.fmt.allocPrint(a, "{s}.state", .{s.name}) });
    Io.Dir.cwd().deleteTree(io, state_dir) catch {};
    try Io.Dir.cwd().createDirPath(io, state_dir);

    // The model.
    const mode: enum { script, cassette, live } = if (opts.live != null) .live else if (s.cassette != null) .cassette else .script;
    var registry = reg_mod.ModelRegistry.init(gpa, io, if (mode == .script) script_catalog else reg_mod.builtin_catalog);
    defer registry.deinit();
    const model = if (opts.live) |l| l.model else s.model;

    var sp: ?*scripted.ScriptedProvider = null;
    var script_provider: Provider = undefined;
    defer if (sp != null) script_provider.deinit();
    var cassette: ?*cassette_mod.Cassette = null;
    defer if (cassette) |c| c.deinit();
    var limiter: ratelimit.RateLimiter = .init(gpa, .real);
    defer limiter.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var hub: ?*hub_mod.ProviderHub = null;
    defer if (hub) |h| h.deinit();
    var providers: deps.Providers = undefined;
    var compaction_provider: Provider = undefined;
    switch (mode) {
        .script => {
            sp = try .init(gpa, try scriptSteps(a, s.script), .all);
            script_provider = sp.?.provider();
            providers = .fixed(&script_provider);
            compaction_provider = script_provider;
        },
        .cassette, .live => {
            const rel = s.cassette orelse try std.fmt.allocPrint(a, "cassettes/{s}.jsonl", .{s.name});
            const path = try std.fs.path.join(a, &.{ dir, rel });
            cassette = try .open(io, gpa, path, if (mode == .live) .record_missing else .replay, .{});
            if (opts.live) |l| {
                var it = l.environ.iterator();
                while (it.next()) |e| try env.put(e.key_ptr.*, e.value_ptr.*);
            } else {
                // Replays need no real key, but the providers must exist.
                for ([_][]const u8{ "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY" }) |k| try env.put(k, "cassette");
            }
            hub = try .init(gpa, .{
                .secrets = no_secrets,
                .environ = &env,
                .transport = cassette.?.transport(if (opts.live) |l| l.transport else null),
                .limiter = &limiter,
                .registry = &registry,
            });
            try hub.?.onSettingsChanged(io, &.{});
            providers = .fromHub(hub.?);
            const info = registry.resolve(model) orelse return error.UnknownModel;
            compaction_provider = providers.get(info) orelse return error.NoProvider;
        },
    }

    // The tools, rooted in the workspace.
    var reg: tool_registry.ToolRegistry = .init(gpa, io);
    defer reg.deinit();
    var processes: process_host.ProcessHost = .init(gpa, io);
    processes.cwd = workspace;
    processes.environ = opts.environ;
    defer processes.deinit();
    var commands: run_tools.RunTools = .init(gpa, io, processes.host(), .{ .visible = false });
    defer commands.deinit();
    try reg.addSource(commands.source());
    var tracker: read_tracker.ReadTracker = .init(gpa, io);
    defer tracker.deinit();
    var disk: disk_files.DiskFiles = .{ .root = workspace };
    var file_tools: files.FileTools = .{ .files = disk.asFiles(), .tracker = &tracker };
    try reg.addSource(file_tools.source());

    // The headless options, parsed like `zg agent` flags.
    var argv: std.ArrayList([:0]const u8) = .empty;
    try argv.appendSlice(a, &.{ "-p", try a.dupeZ(u8, s.prompt), "--output-format", "stream-json", "--model", try a.dupeZ(u8, model) });
    try argv.appendSlice(a, &.{ "--permission-mode", try a.dupeZ(u8, s.permission_mode), "--max-turns", try std.fmt.allocPrintSentinel(a, "{d}", .{s.max_turns}, 0) });
    for (s.allowed_tools) |t| try argv.appendSlice(a, &.{ "--allowed-tools", try a.dupeZ(u8, t) });
    for (s.disallowed_tools) |t| try argv.appendSlice(a, &.{ "--disallowed-tools", try a.dupeZ(u8, t) });
    if (s.followup == null) try argv.append(a, "--no-session-persistence");
    var hopts = args.parseArgs(a, argv.items) catch return error.InvalidScenario;

    var agent_tools: toolset.AgentTools = .init(gpa, io, &reg, .{ .deny = try bareRules(a, s.disallowed_tools), .mode = hopts.permission_mode });
    defer agent_tools.deinit();
    const mgr = try AgentManager.init(gpa, io, .{ .registry = &registry, .providers = providers, .tools = agent_tools.tools() });
    defer mgr.deinit();
    var hooks: HookSet = .{ .rules = s.hooks };
    if (s.hooks.len > 0) mgr.deps.hooks = .{ .ctx = &hooks, .pre_tool_use = HookSet.pre };
    var compact: ?compactor.Compactor = null;
    var loop_compaction: compactor.LoopCompaction = undefined;
    var growth: Growth = undefined;
    if (s.compact_after_tokens) |n| {
        const info = registry.resolve(model) orelse return error.UnknownModel;
        compact = .{ .provider = compaction_provider, .model = info };
        loop_compaction = .{ .compactor = &compact.? };
        growth = .{ .inner = loop_compaction.compaction(), .tokens = n };
        mgr.deps.compaction = growth.compaction();
    }

    // Sessions, for follow-ups.
    var store: ?store_mod.SessionStore = null;
    defer if (store) |*x| x.deinit();
    var sessions_dir: ?Io.Dir = null;
    defer if (sessions_dir) |d| d.close(io);
    var index: ?index_mod.SessionIndex = null;
    defer if (index) |*ix| ix.deinit();
    if (s.followup != null) {
        store = try .init(gpa, state_dir, workspace);
        try Io.Dir.cwd().createDirPath(io, store.?.dir);
        sessions_dir = try Io.Dir.cwd().openDir(io, store.?.dir, .{ .iterate = true });
        index = try .load(gpa, io, sessions_dir.?);
    }

    var err: Io.Writer.Allocating = .init(a);
    hopts.env = .{
        .spill_dir = state_dir,
        .err = &err.writer,
        .cwd = workspace,
        .default_model = model,
        .store = if (store) |*x| x else null,
        .index = if (index) |*ix| ix else null,
    };

    var out: Io.Writer.Allocating = .init(a);
    var facts: graders.Facts = .{ .workspace = workspace, .fixture = fixture, .zig_exe = opts.zig_exe, .environ = opts.environ };
    var tools_used: std.ArrayList([]const u8) = .empty;
    var problems: std.ArrayList(u8) = .empty;

    var runs: [2]?[]const u8 = .{ s.prompt, s.followup };
    for (&runs, 0..) |*p, ri| {
        const prompt = p.* orelse continue;
        if (ri == 1) {
            hopts.prompt = prompt;
            hopts.continue_session = true;
        }
        out.clearRetainingCapacity();
        var in: Io.Reader = .fixed("");
        const code = try print.runPrint(io, gpa, mgr, hopts, &out.writer, &in);
        result.exit_code = @max(result.exit_code, code.code());
        try readTranscript(a, out.written(), &facts, &tools_used, &result);
    }
    if (cassette) |c| if (mode == .live) try c.finish();
    facts.tools_used = tools_used.items;

    // Script expectations.
    if (sp) |x| {
        const reqs = x.requests();
        for (s.script, 0..) |t, i| {
            if (t.expect.len == 0) continue;
            if (i >= reqs.len) {
                try problems.print(a, "turn {d} was never requested; ", .{i + 1});
                continue;
            }
            for (t.expect) |needle| if (!requestContains(&reqs[i], needle))
                try problems.print(a, "turn {d}: the request lacks \"{s}\"; ", .{ i + 1, needle });
        }
        if (x.remaining() > 0) try problems.print(a, "{d} scripted turns were not used; ", .{x.remaining()});
    }
    if (err.written().len > 0 and result.exit_code != 0) try problems.print(a, "stderr: {s}", .{std.mem.trim(u8, err.written(), " \n")});

    const verdicts = try a.alloc(GraderResult, s.graders.len);
    var ok = problems.items.len == 0;
    for (s.graders, verdicts) |g, *v| {
        const r = try graders.grade(io, a, g, &facts);
        v.* = .{ .grader = try graders.label(a, g), .ok = r.ok, .detail = r.detail };
        ok = ok and r.ok;
    }
    result.graders = verdicts;
    result.passed = ok;
    if (problems.items.len > 0) result.error_text = std.mem.trimEnd(u8, problems.items, "; ");
    return result;
}

/// Turns a script into provider steps.
pub fn scriptSteps(a: Allocator, script: []const Turn) Allocator.Error![]const []const Step {
    const turns = try a.alloc([]const Step, script.len);
    for (script, turns, 0..) |t, *out, ti| {
        var steps: std.ArrayList(Step) = .empty;
        try steps.append(a, .{ .event = .{ .message_start = .{ .id = try std.fmt.allocPrint(a, "msg_eval_{d}", .{ti + 1}), .model = "cassette" } } });
        var index: u32 = 0;
        if (t.text.len > 0) {
            try steps.appendSlice(a, &.{
                .{ .event = .{ .block_start = .{ .index = index, .kind = .text } } },
                .{ .event = .{ .text_delta = .{ .index = index, .text = t.text } } },
                .{ .event = .{ .block_stop = .{ .index = index } } },
            });
            index += 1;
        }
        for (t.tools, 0..) |call, ci| {
            const id = try std.fmt.allocPrint(a, "toolu_{d}_{d}", .{ ti + 1, ci + 1 });
            try steps.appendSlice(a, &.{
                .{ .event = .{ .block_start = .{ .index = index, .kind = .tool_use, .tool_id = id, .tool_name = call.name } } },
                .{ .event = .{ .tool_input_delta = .{ .index = index, .partial_json = call.input } } },
                .{ .event = .{ .block_stop = .{ .index = index } } },
            });
            index += 1;
        }
        try steps.appendSlice(a, &.{
            .{ .event = .{ .usage = .{ .input = t.input_tokens, .output = t.output_tokens } } },
            .{ .event = .{ .stop = if (t.tools.len > 0) .tool_use else .end_turn } },
        });
        out.* = steps.items;
    }
    return turns;
}

/// Whether `needle` appears in the text or tool results of `req`.
pub fn requestContains(req: *const request.Request, needle: []const u8) bool {
    for (req.messages) |m| for (m.content) |b| switch (b) {
        .text => |t| if (std.mem.indexOf(u8, t.text, needle) != null) return true,
        .tool_result => |r| for (r.parts) |c| switch (c) {
            .text => |t| if (std.mem.indexOf(u8, t, needle) != null) return true,
            else => {},
        },
        else => {},
    };
    return false;
}

/// Collects the facts of one stream-json transcript.
fn readTranscript(a: Allocator, text: []const u8, facts: *graders.Facts, tools_used: *std.ArrayList([]const u8), result: *Result) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        if (v != .object) continue;
        const kind = str(v, "type") orelse continue;
        if (std.mem.eql(u8, kind, "assistant")) {
            const msg = v.object.get("message") orelse continue;
            const content = if (msg == .object) msg.object.get("content") orelse continue else continue;
            if (content != .array) continue;
            for (content.array.items) |b| {
                const bt = str(b, "type") orelse continue;
                if (!std.mem.eql(u8, bt, "tool_use")) continue;
                const name = str(b, "name") orelse continue;
                for (tools_used.items) |t| {
                    if (std.mem.eql(u8, t, name)) break;
                } else try tools_used.append(a, name);
            }
        } else if (std.mem.eql(u8, kind, "result")) {
            facts.turns += @intCast(int(v, "num_turns"));
            facts.cost_usd += float(v, "total_cost_usd");
            if (v.object.get("permission_denials")) |d| if (d == .array) {
                facts.denials += @intCast(d.array.items.len);
            };
            facts.final_text = str(v, "result") orelse "";
            if (v.object.get("usage")) |u| {
                result.input_tokens += @intCast(int(u, "input"));
                result.output_tokens += @intCast(int(u, "output"));
            }
        }
    }
    result.turns = facts.turns;
    result.cost_usd = facts.cost_usd;
}

/// Compacts once the request estimate grows by `tokens` over the first
/// one seen.
const Growth = struct {
    inner: deps.Compaction,
    tokens: u64,
    first: ?u64 = null,
    done: bool = false,

    fn compaction(g: *Growth) deps.Compaction {
        return .{ .ctx = g, .should_compact = should, .compact = run };
    }

    fn should(ctx: *anyopaque, est: u64, _: u32) bool {
        const g: *Growth = @ptrCast(@alignCast(ctx));
        const first = g.first orelse blk: {
            g.first = est;
            break :blk est;
        };
        return !g.done and est >= first + g.tokens;
    }

    fn run(ctx: *anyopaque, io: Io, arena: Allocator, base: *const request.Request, history: []const proto.Message, overflow: bool) anyerror!deps.CompactedHistory {
        const g: *Growth = @ptrCast(@alignCast(ctx));
        g.done = true;
        return g.inner.compact(g.inner.ctx, io, arena, base, history, overflow);
    }
};

const HookSet = struct {
    rules: []const Hook,

    fn pre(ctx: *anyopaque, _: Io, _: Allocator, _: proto.AgentRef, spec: *const proto.ToolSpec, input_json: []const u8) anyerror!deps.PreToolDecision {
        const h: *HookSet = @ptrCast(@alignCast(ctx));
        for (h.rules) |r| {
            if (!std.mem.eql(u8, r.tool, spec.name)) continue;
            if (std.mem.indexOf(u8, input_json, r.input_contains) == null) continue;
            return .{ .decision = switch (r.decision) {
                .deny => .deny,
                .ask => .ask,
                .allow => .allow,
            }, .reason = r.reason };
        }
        return .{};
    }
};

/// Copies the directory tree `from` to `to`, replacing `to`.
pub fn copyTree(io: Io, a: Allocator, from: []const u8, to: []const u8) !void {
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, to) catch {};
    try cwd.createDirPath(io, to);
    var src = try cwd.openDir(io, from, .{ .iterate = true });
    defer src.close(io);
    var dst = try cwd.openDir(io, to, .{});
    defer dst.close(io);
    var w = try src.walk(a);
    defer w.deinit();
    while (try w.next(io)) |e| switch (e.kind) {
        .directory => try dst.createDirPath(io, e.path),
        .file => try src.copyFile(e.path, dst, e.path, io, .{ .make_path = true }),
        else => {},
    };
}

// Baselines.

pub const BaselineEntry = struct {
    name: []const u8,
    passed: bool,
    turns: u32,
    cost_usd: f64,
};

pub const Regression = struct {
    name: []const u8,
    reason: []const u8,
};

/// Turns or cost may grow this much before it counts as a regression.
pub const growth_limit = 1.25;

/// `baseline.json` for `report`.
pub fn writeBaseline(report: *const Report, w: *Io.Writer) Io.Writer.Error!void {
    const entries = report.arena.child_allocator.alloc(BaselineEntry, report.results.len) catch return error.WriteFailed;
    defer report.arena.child_allocator.free(entries);
    for (report.results, entries) |r, *e| e.* = .{ .name = r.name, .passed = r.passed, .turns = r.turns, .cost_usd = r.cost_usd };
    try std.json.Stringify.value(.{ .scenarios = entries }, .{ .whitespace = .indent_2 }, w);
    try w.writeByte('\n');
}

/// Scenarios that passed in `baseline_json` and now fail, or whose turns
/// or cost grew more than 25%. Scenarios new since the baseline count
/// only when they fail.
pub fn regressions(a: Allocator, baseline_json: []const u8, report: *const Report) ![]Regression {
    const base = try std.json.parseFromSliceLeaky(struct { scenarios: []const BaselineEntry }, a, baseline_json, .{ .ignore_unknown_fields = true });
    var out: std.ArrayList(Regression) = .empty;
    for (report.results) |r| {
        const b = for (base.scenarios) |b| {
            if (std.mem.eql(u8, b.name, r.name)) break b;
        } else {
            if (!r.passed) try out.append(a, .{ .name = r.name, .reason = "new scenario fails" });
            continue;
        };
        if (b.passed and !r.passed) {
            try out.append(a, .{ .name = r.name, .reason = "passed in the baseline, fails now" });
        } else if (b.turns > 0 and @as(f64, @floatFromInt(r.turns)) > @as(f64, @floatFromInt(b.turns)) * growth_limit) {
            try out.append(a, .{ .name = r.name, .reason = try std.fmt.allocPrint(a, "turns grew from {d} to {d}", .{ b.turns, r.turns }) });
        } else if (b.cost_usd > 0 and r.cost_usd > b.cost_usd * growth_limit) {
            try out.append(a, .{ .name = r.name, .reason = try std.fmt.allocPrint(a, "cost grew from ${d:.4} to ${d:.4}", .{ b.cost_usd, r.cost_usd }) });
        }
    }
    return out.items;
}

fn cloneResult(a: Allocator, r: Result) Allocator.Error!Result {
    var c = r;
    c.name = try a.dupe(u8, r.name);
    if (r.error_text) |e| c.error_text = try a.dupe(u8, e);
    const gs = try a.alloc(GraderResult, r.graders.len);
    for (r.graders, gs) |g, *x| x.* = .{ .grader = try a.dupe(u8, g.grader), .ok = g.ok, .detail = try a.dupe(u8, g.detail) };
    c.graders = gs;
    return c;
}

/// `--disallowed-tools` rules without a pattern remove the tool.
fn bareRules(a: Allocator, rules: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (rules) |r| if (std.mem.indexOfScalar(u8, r, '(') == null) try out.append(a, r);
    return out.items;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn int(v: std.json.Value, key: []const u8) i64 {
    if (v != .object) return 0;
    const x = v.object.get(key) orelse return 0;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

fn float(v: std.json.Value, key: []const u8) f64 {
    if (v != .object) return 0;
    const x = v.object.get(key) orelse return 0;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
}

/// Keys come from the environment (live) or are placeholders (replay).
const no_secrets: keyref.SecretStore = .{ .ctx = @constCast(@as(*const anyopaque, &{})), .vtable = &.{ .get = getNone, .put = putNone } };

fn getNone(_: *anyopaque, _: Io, _: []const u8) keyref.SecretError!?[]const u8 {
    return null;
}

fn putNone(_: *anyopaque, _: Io, _: []const u8, _: []const u8) keyref.SecretError!void {
    return error.Unavailable;
}
