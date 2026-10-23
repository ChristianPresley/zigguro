//! `zg agents host` and `zg runs` (E13.F01.S01.T03).
//!
//! `zg agents host [--workspace DIR] [--idle-exit SECONDS]` owns the
//! workspace's runs while no GUI does: it takes `.zigguro/runs/host.lock`
//! (exit 3 when another host holds it), loads the run registry, serves the
//! host protocol on a local socket, and exits after `--idle-exit` seconds
//! (default 600) with no active runs and no clients, or on
//! `host.shutdown`.
//!
//! `zg runs list|show|outputs|attach|start|stop|pause|resume|reply|pin|
//! rename|remove [--json]` talk to the host; without one, `list`, `show`
//! and `outputs` read the registry directly and the others fail with
//! exit 1. Every Mission Control row action has a subcommand here
//! (`zg_agents.mission.actions.table`).

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_ai = @import("zg_ai");
const zg_net = @import("zg_net");
const zg_agents = @import("zg_agents");
const review_hooks = @import("review_hooks.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const runs = zg_agents.runs;
const protocol = runs.protocol;
const ipc = runs.ipc;
const notify = zg_agents.notify;

pub const host_usage =
    \\Usage: zg agents host [--workspace DIR] [--idle-exit SECONDS]
    \\
    \\Runs the workspace's background agents without the GUI. One host per
    \\workspace: a second one exits with code 3. Exits after SECONDS
    \\(default 600) with no active runs and no clients.
    \\
;

pub const runs_usage =
    \\Usage: zg runs list [--json]
    \\       zg runs show ID [--json]
    \\       zg runs outputs ID [--json]
    \\       zg runs attach ID          (follows the run until it ends)
    \\       zg runs start [--title T] [--kind background|task] PROMPT
    \\       zg runs stop ID [--now]
    \\       zg runs pause ID
    \\       zg runs resume ID
    \\       zg runs reply ID TEXT
    \\       zg runs pin ID [--off]
    \\       zg runs rename ID TITLE
    \\       zg runs remove ID [--delete-files]
    \\
    \\Options: --workspace DIR (default: the current directory)
    \\
    \\Talks to the workspace's agent host (the GUI or `zg agents host`);
    \\list and show also work without one.
    \\
;

const Streams = struct {
    out_w: Io.File.Writer,
    err_w: Io.File.Writer,
    obuf: [16 * 1024]u8 = undefined,
    ebuf: [2048]u8 = undefined,

    fn init(s: *Streams, io: Io) void {
        s.out_w = .init(.stdout(), io, &s.obuf);
        s.err_w = .init(.stderr(), io, &s.ebuf);
    }
    fn flush(s: *Streams) void {
        s.out_w.interface.flush() catch {};
        s.err_w.interface.flush() catch {};
    }
};

/// `<workspace>/.zigguro/runs`, created when missing.
fn openRuns(io: Io, gpa: Allocator, workspace: []const u8) !struct { dir: Io.Dir, abs: []u8 } {
    const abs = try std.fs.path.join(gpa, &.{ workspace, ".zigguro", "runs" });
    errdefer gpa.free(abs);
    const dir = try Io.Dir.cwd().createDirPathOpen(io, abs, .{});
    const real = dir.realPathFileAlloc(io, ".", gpa) catch return .{ .dir = dir, .abs = abs };
    defer gpa.free(real);
    gpa.free(abs);
    return .{ .dir = dir, .abs = try gpa.dupe(u8, real) };
}

fn flagValue(argv: []const [:0]const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= argv.len) return null;
    i.* += 1;
    return argv[i.*];
}

// ---- zg agents host ----

pub fn runHost(rt: *zg_core.Runtime, min: std.process.Init.Minimal, argv: []const [:0]const u8) !u8 {
    const gpa = rt.gpa;
    const io = rt.io;
    var s: Streams = undefined;
    s.init(io);
    defer s.flush();
    const out = &s.out_w.interface;
    const err = &s.err_w.interface;

    var workspace: []const u8 = ".";
    var idle_s: i64 = 600;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try out.writeAll(host_usage);
            return 0;
        } else if (std.mem.eql(u8, a, "--workspace")) {
            workspace = flagValue(argv, &i) orelse return usage(err, host_usage);
        } else if (std.mem.eql(u8, a, "--idle-exit")) {
            idle_s = std.fmt.parseInt(i64, flagValue(argv, &i) orelse return usage(err, host_usage), 10) catch return usage(err, host_usage);
        } else return usage(err, host_usage);
    }

    var rd = try openRuns(io, gpa, workspace);
    defer {
        rd.dir.close(io);
        gpa.free(rd.abs);
    }
    const lock = (try ipc.HostLock.acquire(io, rd.dir)) orelse {
        try err.print("zg agents host: a host is already running for {s} (pid {d})\n", .{ workspace, ipc.HostLock.holderPid(io, rd.dir) orelse 0 });
        return 3;
    };
    defer lock.release(io);

    var env = try min.environ.createMap(gpa);
    defer env.deinit();

    const reg = try runs.RunRegistry.init(gpa, io, rd.dir, .{});
    defer reg.deinit();
    // Run notifications go to stderr (no window: everything is "away").
    var note_buf: [1024]u8 = undefined;
    var note_w: Io.File.Writer = .init(.stderr(), io, &note_buf);
    const router = try notify.NotificationRouter.init(gpa, rt, try notify.headlessBackend(gpa, io, &note_w.interface, null), null, .{}, .{});
    defer router.deinit();
    const notifier = try notify.RunNotifier.init(reg, router);
    defer notifier.deinit();
    const report = try reg.load(.{ .host_alive = false });
    if (report.interrupted != 0) try err.print("zg agents host: {d} run(s) were interrupted\n", .{report.interrupted});

    // The agent runtime: providers from the environment, command and file
    // tools (file edits held for review, as `zg agent --review defer`).
    var models = zg_ai.ModelRegistry.init(gpa, io, zg_ai.models.registry.builtin_catalog);
    defer models.deinit();
    const client = try zg_net.http.Client.init(rt, .{ .environ_map = &env });
    defer client.deinit();
    var net: zg_ai.transport.ZgNet = .{ .client = client };
    var limiter: zg_ai.ratelimit.RateLimiter = .init(gpa, .real);
    defer limiter.deinit();
    const hub = try zg_ai.ProviderHub.init(gpa, .{
        .secrets = no_secrets,
        .environ = &env,
        .transport = net.transport(),
        .limiter = &limiter,
        .registry = &models,
        .notifier = .{ .ctx = err, .warn = warn, .redact = redact },
    });
    defer hub.deinit();
    try hub.onSettingsChanged(io, &.{});
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, workspace, gpa);
    defer gpa.free(cwd);
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
    var review: review_hooks.Review = try .init(gpa, io, cwd, .@"defer", "default");
    defer review.deinit();
    var file_tools: zg_ai.tools.builtin.files.FileTools = .{ .files = review.glue.files(), .tracker = &read_tracker };
    try tool_registry.addSource(file_tools.source());
    var agent_tools: zg_ai.tools.AgentTools = .init(gpa, io, &tool_registry, .{});
    defer agent_tools.deinit();
    const mgr = try zg_ai.loop.AgentManager.init(gpa, io, .{
        .registry = &models,
        .providers = .fromHub(hub),
        .tools = agent_tools.tools(),
        .checkpoints = review.glue.checkpoints(),
        .turn_end = file_tools.turnEnd(),
    });
    defer mgr.deinit();
    var e10: runs.E10Agents = .init(gpa, io, mgr, .{ .default_model = env.get("ZG_MODEL") orelse "sonnet" });

    const host = try runs.RunHost.init(gpa, io, reg, e10.agentPort(), null, .builtin, .{ .workspace_root = cwd });
    defer host.deinit();
    // Automations: the host fires them while it holds the scheduler lease
    // (the GUI may hold it instead). Files are re-read every 10 s.
    var ws_dir = try Io.Dir.cwd().openDir(io, workspace, .{});
    defer ws_dir.close(io);
    const automations = try zg_agents.sched.Service.init(gpa, io, ws_dir, reg, .fromHost(host), zg_agents.sched.utcZone(), .{
        .workspace_key = cwd,
        .warn = .{ .ctx = router, .warn = warnAutomation },
        .on_problem = reportProblem,
        .on_problem_ctx = err,
    });
    defer automations.deinit();
    try automations.start();
    const server = try ipc.HostServer.listen(rt, host, reg, rd.dir, rd.abs, .{ .runtime_dir = env.get("XDG_RUNTIME_DIR"), .automations = automations.port() });
    defer server.deinit();
    try out.print("zg agents host: serving {s} on {s}\n", .{ workspace, server.sock_path });
    s.flush();

    var idle: runs.handoff.IdleTimer = .{ .idle_ms = idle_s * std.time.ms_per_s };
    var ticks: u32 = 0;
    while (!server.shutdown_requested.load(.acquire)) {
        io.sleep(.fromMilliseconds(250), .awake) catch break;
        ticks +%= 1;
        if (ticks % 40 == 0) automations.reload() catch {};
        const active = blk: {
            const v = reg.snapshot();
            defer reg.release(v);
            var n: usize = 0;
            for (v.runs) |r| {
                if (!r.status.isTerminal() and r.status != .paused) n += 1;
            }
            break :blk n;
        };
        if (idle.tick(reg.nowMs(), active != 0 or server.clients() != 0)) break;
    }
    reg.flush();
    return 0;
}

fn warn(ctx: *anyopaque, msg: []const u8) void {
    const err: *Io.Writer = @ptrCast(@alignCast(ctx));
    err.print("zg agents host: {s}\n", .{msg}) catch {};
}

fn redact(_: *anyopaque, _: []const u8) void {}

fn warnAutomation(ctx: *anyopaque, name: []const u8, message: []const u8) void {
    const router: *notify.NotificationRouter = @ptrCast(@alignCast(ctx));
    var key_buf: [80]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "automation:{s}", .{name}) catch return;
    router.post(.{ .key = key, .severity = .warning, .title = name, .body = message });
}

fn reportProblem(ctx: ?*anyopaque, file: []const u8, line: u32, column: u32, message: []const u8) void {
    const err: *Io.Writer = @ptrCast(@alignCast(ctx.?));
    err.print("zg agents host: .zigguro/automations/{s}:{d}:{d}: {s}\n", .{ file, line, column, message }) catch {};
}

const no_secrets: zg_ai.keyref.SecretStore = .{ .ctx = @constCast(@as(*const anyopaque, &{})), .vtable = &.{ .get = getNone, .put = putNone } };

fn getNone(_: *anyopaque, _: Io, _: []const u8) zg_ai.keyref.SecretError!?[]const u8 {
    return null;
}

fn putNone(_: *anyopaque, _: Io, _: []const u8, _: []const u8) zg_ai.keyref.SecretError!void {
    return error.Unavailable;
}

fn usage(err: *Io.Writer, text: []const u8) !u8 {
    try err.writeAll(text);
    return 2;
}

// ---- zg runs ----

pub fn runRuns(rt: *zg_core.Runtime, argv: []const [:0]const u8) !u8 {
    var s: Streams = undefined;
    s.init(rt.io);
    defer s.flush();
    return runRunsIn(rt, argv, &s.out_w.interface, &s.err_w.interface);
}

pub const Cmd = enum { list, show, outputs, attach, start, stop, pause, @"resume", reply, pin, rename, remove };

/// `zg runs` with the output streams given.
pub fn runRunsIn(rt: *zg_core.Runtime, argv: []const [:0]const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    const gpa = rt.gpa;
    const io = rt.io;
    if (argv.len == 0 or std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h")) {
        try out.writeAll(runs_usage);
        return if (argv.len == 0) 2 else 0;
    }
    const cmd = std.meta.stringToEnum(Cmd, argv[0]) orelse return usage(err, runs_usage);
    var json = false;
    var now = false;
    var off = false;
    var delete_files = false;
    var workspace: []const u8 = ".";
    var title: ?[]const u8 = null;
    var kind: runs.RunKind = .background;
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(gpa);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, a, "--now")) {
            now = true;
        } else if (std.mem.eql(u8, a, "--off")) {
            off = true;
        } else if (std.mem.eql(u8, a, "--delete-files")) {
            delete_files = true;
        } else if (std.mem.eql(u8, a, "--workspace")) {
            workspace = flagValue(argv, &i) orelse return usage(err, runs_usage);
        } else if (std.mem.eql(u8, a, "--title")) {
            title = flagValue(argv, &i) orelse return usage(err, runs_usage);
        } else if (std.mem.eql(u8, a, "--kind")) {
            kind = std.meta.stringToEnum(runs.RunKind, flagValue(argv, &i) orelse return usage(err, runs_usage)) orelse return usage(err, runs_usage);
        } else try pos.append(gpa, a);
    }
    const need: usize = switch (cmd) {
        .list => 0,
        .show, .outputs, .attach, .stop, .pause, .@"resume", .start, .pin, .remove => 1,
        .reply, .rename => 2,
    };
    if (pos.items.len != need) return usage(err, runs_usage);

    var rd = try openRuns(io, gpa, workspace);
    defer {
        rd.dir.close(io);
        gpa.free(rd.abs);
    }
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const client = ipc.HostClient.connect(rt, rd.dir) catch |e| {
        try err.print("zg runs: cannot reach the agent host: {t}\n", .{e});
        return 1;
    };
    defer if (client) |c| c.deinit();

    const id: ?runs.RunId = if (cmd != .list and cmd != .start) runs.RunId.parse(pos.items[0]) catch {
        try err.print("zg runs: not a run id: {s}\n", .{pos.items[0]});
        return 2;
    } else null;

    const c = client orelse switch (cmd) {
        .list, .show, .outputs => return offline(gpa, io, rd.dir, cmd, id, json, out, err),
        else => {
            try err.print("zg runs: no agent host is running for {s} (start one with `zg agents host`)\n", .{workspace});
            return 1;
        },
    };
    switch (cmd) {
        .list => {
            const rows = try c.call(protocol.methods.list, .{}, []protocol.RunSummary, arena);
            try printList(rows, json, out);
        },
        .show => {
            const rec = c.call(protocol.methods.show, protocol.IdParams{ .id = id.? }, std.json.Value, arena) catch return remoteFailed(err, cmd);
            try std.json.Stringify.value(rec, .{ .whitespace = if (json) .minified else .indent_2 }, out);
            try out.writeByte('\n');
        },
        .start => {
            const spec: runs.RunSpec = .{ .kind = kind, .title = title orelse firstLine(pos.items[0]), .prompt = pos.items[0], .origin = .cli };
            const r = c.call(protocol.methods.start, protocol.StartParams{ .spec = spec }, protocol.IdParams, arena) catch return remoteFailed(err, cmd);
            if (json) try out.print("{{\"id\":\"{f}\"}}\n", .{r.id}) else try out.print("{f}\n", .{r.id});
        },
        .stop => _ = c.call(protocol.methods.stop, protocol.StopParams{ .id = id.?, .how = if (now) .now else .graceful }, protocol.Ok, arena) catch return remoteFailed(err, cmd),
        .pause => _ = c.call(protocol.methods.pause, protocol.IdParams{ .id = id.? }, protocol.Ok, arena) catch return remoteFailed(err, cmd),
        .@"resume" => _ = c.call(protocol.methods.resume_, protocol.IdParams{ .id = id.? }, protocol.Ok, arena) catch return remoteFailed(err, cmd),
        .reply => _ = c.call(protocol.methods.reply, protocol.ReplyParams{ .id = id.?, .text = pos.items[1] }, protocol.Ok, arena) catch return remoteFailed(err, cmd),
        .pin => _ = c.call(protocol.methods.pin, protocol.PinParams{ .id = id.?, .on = !off }, protocol.Ok, arena) catch return remoteFailed(err, cmd),
        .rename => _ = c.call(protocol.methods.rename, protocol.RenameParams{ .id = id.?, .title = pos.items[1] }, protocol.Ok, arena) catch return remoteFailed(err, cmd),
        .remove => _ = c.call(protocol.methods.remove, protocol.RemoveParams{ .id = id.?, .delete_files = delete_files }, protocol.Ok, arena) catch return remoteFailed(err, cmd),
        .outputs => {
            const rec = c.call(protocol.methods.show, protocol.IdParams{ .id = id.? }, runs.RunRecord, arena) catch return remoteFailed(err, cmd);
            try printOutputs(rec.outputs, json, out);
        },
        .attach => return attach(gpa, io, c, id.?, json, out, err),
    }
    return 0;
}

/// Follows a run: prints its status, question and summary as they change
/// until it ends. Answer a question with `zg runs reply`.
fn attach(gpa: Allocator, io: Io, c: *ipc.HostClient, id: runs.RunId, json: bool, out: *Io.Writer, err: *Io.Writer) !u8 {
    var last_rev: u64 = 0;
    var last_status: ?runs.RunStatus = null;
    var last_summary: std.ArrayList(u8) = .empty;
    defer last_summary.deinit(gpa);
    var last_question: std.ArrayList(u8) = .empty;
    defer last_question.deinit(gpa);
    while (true) {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const rec = c.call(protocol.methods.show, protocol.IdParams{ .id = id }, runs.RunRecord, arena_state.allocator()) catch return remoteFailed(err, .attach);
        if (rec.revision != last_rev) {
            last_rev = rec.revision;
            if (json) {
                try std.json.Stringify.value(protocol.RunSummary.of(&rec), .{}, out);
                try out.writeByte('\n');
            } else {
                if (last_status != rec.status) try out.print("[{t}]\n", .{rec.status});
                if (!std.mem.eql(u8, last_summary.items, rec.summary) and rec.summary.len > 0) try out.print("{s}\n", .{rec.summary});
                const q = rec.question orelse "";
                if (!std.mem.eql(u8, last_question.items, q) and q.len > 0) try out.print("asks: {s}\n  (answer with `zg runs reply {f} TEXT`)\n", .{ q, id });
                last_question.clearRetainingCapacity();
                try last_question.appendSlice(gpa, q);
            }
            last_status = rec.status;
            last_summary.clearRetainingCapacity();
            try last_summary.appendSlice(gpa, rec.summary);
            try out.flush();
        }
        if (rec.status.isTerminal()) return if (rec.status == .completed) 0 else 1;
        io.sleep(.fromMilliseconds(250), .awake) catch return 1;
    }
}

fn printOutputs(outputs: []const runs.Output, json: bool, out: *Io.Writer) !void {
    if (json) {
        try std.json.Stringify.value(outputs, .{}, out);
        return out.writeByte('\n');
    }
    if (outputs.len == 0) return out.writeAll("no outputs\n");
    for (outputs) |o| switch (o) {
        .changeset => |cs| try out.print("changeset  {d}\n", .{cs}),
        .artifact => |s| try out.print("artifact   {s}\n", .{s}),
        .file => |s| try out.print("file       {s}\n", .{s}),
        .task => |s| try out.print("task       {s}\n", .{s}),
        .note => |s| try out.print("note       {s}\n", .{s}),
        .pr => |pr| try out.print("pr         #{d} {s}\n", .{ pr.number, pr.url }),
    };
}

fn remoteFailed(err: *Io.Writer, cmd: Cmd) !u8 {
    try err.print("zg runs {t}: the host refused (unknown run or wrong state)\n", .{cmd});
    return 1;
}

fn firstLine(s: []const u8) []const u8 {
    const line = s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
    return line[0..@min(line.len, 80)];
}

/// `list`/`show` straight from the registry files (no host running).
fn offline(gpa: Allocator, io: Io, dir: Io.Dir, cmd: Cmd, id: ?runs.RunId, json: bool, out: *Io.Writer, err: *Io.Writer) !u8 {
    const reg = try runs.RunRegistry.init(gpa, io, dir, .{});
    defer reg.deinit();
    // Read-only intent: do not mark anything interrupted here.
    _ = try reg.load(.{ .host_alive = true });
    if (id) |x| reg.loadDetail(x) catch {};
    const v = reg.snapshot();
    defer reg.release(v);
    switch (cmd) {
        .list => {
            const rows = try gpa.alloc(protocol.RunSummary, v.runs.len);
            defer gpa.free(rows);
            for (v.runs, rows) |r, *row| row.* = .of(r);
            try printList(rows, json, out);
        },
        else => {
            const r = v.get(id.?) orelse {
                try err.print("zg runs {t}: no run {f}\n", .{ cmd, id.? });
                return 1;
            };
            if (cmd == .outputs) {
                try printOutputs(r.outputs, json, out);
                return 0;
            }
            try std.json.Stringify.value(r.*, .{ .whitespace = if (json) .minified else .indent_2 }, out);
            try out.writeByte('\n');
        },
    }
    return 0;
}

fn printList(rows: []const protocol.RunSummary, json: bool, out: *Io.Writer) !void {
    if (json) {
        try std.json.Stringify.value(rows, .{}, out);
        try out.writeByte('\n');
        return;
    }
    if (rows.len == 0) return out.writeAll("no runs\n");
    for (rows) |r| {
        try out.print("{f}  {s: <11}  {s: <15}  ${d}.{d:0>4}  {s}", .{
            r.id, @tagName(r.status), @tagName(r.kind), r.cost_micros / 1_000_000, (r.cost_micros % 1_000_000) / 100, r.title,
        });
        if (r.question) |q| try out.print("  [asks: {s}]", .{q});
        try out.writeByte('\n');
    }
}

test "zg runs lists and shows runs offline" {
    const testing = std.testing;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(ws);
    var id_buf: [26:0]u8 = @splat(0);
    {
        var rd = try openRuns(testing.io, testing.allocator, ws);
        defer {
            rd.dir.close(testing.io);
            testing.allocator.free(rd.abs);
        }
        const reg = try runs.RunRegistry.init(testing.allocator, testing.io, rd.dir, .{});
        defer reg.deinit();
        const id = try reg.create(.{ .kind = .task, .title = "Write the changelog", .prompt = "p", .origin = .cli });
        @memcpy(id_buf[0..26], &id.text());
    }
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var errw: Io.Writer.Allocating = .init(testing.allocator);
    defer errw.deinit();
    try testing.expectEqual(@as(u8, 0), try runRunsIn(&rt, &.{ "list", "--workspace", ws }, &out.writer, &errw.writer));
    try testing.expect(std.mem.indexOf(u8, out.written(), "Write the changelog") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "queued") != null);
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), try runRunsIn(&rt, &.{ "show", &id_buf, "--json", "--workspace", ws }, &out.writer, &errw.writer));
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"prompt\":\"p\"") != null);
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), try runRunsIn(&rt, &.{ "outputs", &id_buf, "--workspace", ws }, &out.writer, &errw.writer));
    try testing.expectEqualStrings("no outputs\n", out.written());
    // Commands that need a host fail clearly.
    try testing.expectEqual(@as(u8, 1), try runRunsIn(&rt, &.{ "stop", &id_buf, "--workspace", ws }, &out.writer, &errw.writer));
    try testing.expect(std.mem.indexOf(u8, errw.written(), "no agent host") != null);
}

test "every Mission Control action has a zg runs subcommand" {
    for (zg_agents.mission.actions.table) |a| {
        if (std.meta.stringToEnum(Cmd, a.cli) == null) {
            std.debug.print("no `zg runs {s}` for {s}\n", .{ a.cli, a.command });
            return error.TestUnexpectedResult;
        }
    }
}
