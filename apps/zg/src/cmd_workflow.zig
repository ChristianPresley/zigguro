//! `zg workflow` (E13.F08.S01.T02): workflows from the command line.
//!
//! `list` shows the project's workflows (`.zigguro/workflows/*.zon`) and
//! the bundled templates, `show NAME` prints one, `validate FILE` checks
//! one. `run NAME` runs a workflow in this process (it takes the
//! workspace's agent host lock, so it fails with exit 3 while
//! `zg agents host` runs), printing one line per step change, or
//! `zg.stream/1`-style NDJSON events with `--json`. Gates and commands
//! ask on the terminal unless `--approve` answers yes for you.
//! `status RUN` reads a run from the registry, `resume RUN` runs it again
//! reusing the agents that finished (the run folder keeps the definition
//! and arguments), `stop RUN` asks a running `zg workflow run` to stop,
//! and `save RUN --as NAME` keeps a run's definition as a project
//! workflow.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_agents = @import("zg_agents");
const zg_workspace = @import("zg_workspace");
const AgentRuntime = @import("agent_runtime.zig").AgentRuntime;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const runs = zg_agents.runs;
const wf = zg_agents.workflow;
const PromptLibrary = zg_agents.library.PromptLibrary;
const RunId = runs.RunId;

pub const usage_text =
    \\Usage: zg workflow list [--json]
    \\       zg workflow show NAME
    \\       zg workflow validate FILE
    \\       zg workflow run NAME [--args JSON] [--approve] [--json]
    \\       zg workflow status RUN [--json]
    \\       zg workflow resume RUN [--approve] [--json]
    \\       zg workflow stop RUN
    \\       zg workflow save RUN --as NAME
    \\
    \\Options: --workspace DIR   (default: the current directory)
    \\
    \\Workflows live in .zigguro/workflows/NAME.zon (docs/formats/workflow.md);
    \\the bundled templates are audit-files, migrate-files, review-changes and
    \\fix-until-green. `run` and `resume` follow the run until it ends; gates
    \\and commands ask on the terminal unless --approve is given.
    \\
;

pub const Cmd = enum { list, show, validate, run, status, @"resume", stop, save };

/// What `run`/`resume` use instead of the real agent runtime (tests).
pub const Opts = struct {
    agents: ?runs.port.AgentPort = null,
    environ: ?*std.process.Environ.Map = null,
    /// Answers to gate and command questions; null: no one to ask.
    stdin: ?*Io.Reader = null,
    poll_ms: u32 = 100,
};

pub fn run(rt: *zg_core.Runtime, min: std.process.Init.Minimal, argv: []const [:0]const u8) !u8 {
    var obuf: [16 * 1024]u8 = undefined;
    var ebuf: [2048]u8 = undefined;
    var ibuf: [1024]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), rt.io, &obuf);
    var err_w: Io.File.Writer = .init(.stderr(), rt.io, &ebuf);
    var in_r: Io.File.Reader = .init(.stdin(), rt.io, &ibuf);
    defer out_w.interface.flush() catch {};
    defer err_w.interface.flush() catch {};
    var env = try min.environ.createMap(rt.gpa);
    defer env.deinit();
    const tty = Io.File.stdin().isTty(rt.io) catch false;
    return runIn(rt, argv, &out_w.interface, &err_w.interface, .{ .environ = &env, .stdin = if (tty) &in_r.interface else null });
}

fn usage(err: *Io.Writer) !u8 {
    try err.writeAll(usage_text);
    return 2;
}

const Args = struct {
    cmd: Cmd,
    pos: ?[]const u8 = null,
    workspace: []const u8 = ".",
    json: bool = false,
    approve: bool = false,
    args_json: ?[]const u8 = null,
    as: ?[]const u8 = null,
};

pub fn runIn(rt: *zg_core.Runtime, argv: []const [:0]const u8, out: *Io.Writer, err: *Io.Writer, o: Opts) !u8 {
    if (argv.len == 0 or std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h")) {
        const asked = argv.len > 0;
        try (if (asked) out else err).writeAll(usage_text);
        return if (asked) 0 else 2;
    }
    var p: Args = .{ .cmd = std.meta.stringToEnum(Cmd, argv[0]) orelse return usage(err) };
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--json")) {
            p.json = true;
        } else if (std.mem.eql(u8, a, "--approve")) {
            p.approve = true;
        } else if (std.mem.eql(u8, a, "--wait")) {
            // `run` always follows the run.
        } else if (std.mem.eql(u8, a, "--workspace") or std.mem.eql(u8, a, "--args") or std.mem.eql(u8, a, "--as")) {
            i += 1;
            if (i >= argv.len) return usage(err);
            switch (a[2]) {
                'w' => p.workspace = argv[i],
                'a' => if (a[3] == 'r') {
                    p.args_json = argv[i];
                } else {
                    p.as = argv[i];
                },
                else => unreachable,
            }
        } else if (a.len > 0 and a[0] == '-') {
            return usage(err);
        } else if (p.pos == null) {
            p.pos = a;
        } else return usage(err);
    }
    if (p.cmd != .list and p.pos == null) return usage(err);

    var arena_state: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena_state.deinit();
    var c: Ctx = .{ .rt = rt, .a = arena_state.allocator(), .p = p, .out = out, .err = err, .o = o };
    c.ws = Io.Dir.cwd().openDir(rt.io, p.workspace, .{}) catch {
        try err.print("zg workflow: cannot open workspace {s}\n", .{p.workspace});
        return 1;
    };
    defer c.ws.close(rt.io);
    c.lib = try c.openLibrary();
    defer c.lib.deinit();
    return switch (p.cmd) {
        .list => c.list(),
        .show => c.show(),
        .validate => c.validateFile(),
        .run => c.runNamed(),
        .status => c.status(),
        .@"resume" => c.resumeRun(),
        .stop => c.stopRun(),
        .save => c.save(),
    };
}

const builtin_names = [_][]const u8{ "files.glob", "scm.changed_files", "lanes.collect", "artifact.write_table" };

fn allowCommands(_: ?*anyopaque, profile: []const u8) bool {
    return runs.port.ProfilePort.builtin.resolve(undefined, profile) != null;
}

const Ctx = struct {
    rt: *zg_core.Runtime,
    a: Allocator,
    p: Args,
    out: *Io.Writer,
    err: *Io.Writer,
    o: Opts,
    ws: Io.Dir = undefined,
    lib: *PromptLibrary = undefined,
    prompts_dir: ?Io.Dir = null,

    fn openLibrary(c: *Ctx) !*PromptLibrary {
        c.prompts_dir = c.ws.openDir(c.rt.io, ".zigguro/prompts", .{ .iterate = true }) catch null;
        return PromptLibrary.open(c.rt.gpa, c.rt.io, .{ .project = c.prompts_dir }, null);
    }

    fn env(c: *Ctx, schema_files: ?wf.validate.SchemaFiles) wf.ValidateEnv {
        return .{ .library = c.lib, .builtins = &builtin_names, .commands_allowed = allowCommands, .schema_files = schema_files };
    }

    fn fail(c: *Ctx, comptime fmt: []const u8, args: anytype) !u8 {
        try c.err.print("zg workflow {t}: " ++ fmt ++ "\n", .{c.p.cmd} ++ args);
        return 1;
    }

    // ---- definitions ----

    const Found = struct { src: [:0]const u8, project: bool };

    /// Project workflow `name`, else the template.
    fn source(c: *Ctx, name: []const u8) !?Found {
        const path = try std.fmt.allocPrint(c.a, ".zigguro/workflows/{s}.zon", .{name});
        if (c.ws.readFileAllocOptions(c.rt.io, path, c.a, .limited(1 << 20), .of(u8), 0)) |src| {
            return .{ .src = src, .project = true };
        } else |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        }
        const t = wf.templates.find(name) orelse return null;
        return .{ .src = t.source, .project = false };
    }

    fn schemaFiles(c: *Ctx) wf.validate.SchemaFiles {
        return .{ .ctx = c, .read = readSchema };
    }

    fn readSchema(ctx: *anyopaque, arena: Allocator, name: []const u8) ?[]const u8 {
        const c: *Ctx = @ptrCast(@alignCast(ctx));
        const path = std.fmt.allocPrint(arena, ".zigguro/workflows/{s}", .{name}) catch return null;
        return c.ws.readFileAlloc(c.rt.io, path, arena, .limited(1 << 20)) catch null;
    }

    /// Parses and validates; prints the problems.
    fn load(c: *Ctx, file: []const u8, src: [:0]const u8) !?wf.parse.Parsed {
        var diags: wf.Diagnostics = .init(c.rt.gpa);
        defer diags.deinit();
        return wf.parseDef(c.rt.gpa, src, c.env(c.schemaFiles()), &diags) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => {
                try diags.format(file, c.err);
                return null;
            },
        };
    }

    fn list(c: *Ctx) !u8 {
        const Row = struct { name: []const u8, description: []const u8, source: []const u8 };
        var rows: std.ArrayList(Row) = .empty;
        if (c.ws.openDir(c.rt.io, ".zigguro/workflows", .{ .iterate = true })) |d| {
            var dir = d;
            defer dir.close(c.rt.io);
            var it = dir.iterate();
            while (try it.next(c.rt.io)) |en| {
                if (en.kind != .file or !std.mem.endsWith(u8, en.name, ".zon")) continue;
                const name = try c.a.dupe(u8, en.name[0 .. en.name.len - 4]);
                const src = dir.readFileAllocOptions(c.rt.io, en.name, c.a, .limited(1 << 20), .of(u8), 0) catch continue;
                var diags: wf.Diagnostics = .init(c.a);
                var parsed = wf.parse.parseOnly(c.rt.gpa, src, &diags) catch {
                    try rows.append(c.a, .{ .name = name, .description = "(does not parse)", .source = "project" });
                    continue;
                };
                defer parsed.deinit();
                try rows.append(c.a, .{ .name = name, .description = try c.a.dupe(u8, parsed.def.description), .source = "project" });
            }
        } else |_| {}
        for (wf.templates.all) |t| {
            for (rows.items) |r| {
                if (std.mem.eql(u8, r.name, t.name)) break;
            } else {
                var diags: wf.Diagnostics = .init(c.a);
                var parsed = try wf.parse.parseOnly(c.rt.gpa, t.source, &diags);
                defer parsed.deinit();
                try rows.append(c.a, .{ .name = t.name, .description = try c.a.dupe(u8, parsed.def.description), .source = "template" });
            }
        }
        std.mem.sort(Row, rows.items, {}, struct {
            fn lt(_: void, l: Row, r: Row) bool {
                return std.mem.order(u8, l.name, r.name) == .lt;
            }
        }.lt);
        if (c.p.json) {
            try std.json.Stringify.value(rows.items, .{}, c.out);
            try c.out.writeByte('\n');
            return 0;
        }
        for (rows.items) |r| try c.out.print("{s: <20}  {s: <8}  {s}\n", .{ r.name, r.source, r.description });
        return 0;
    }

    fn show(c: *Ctx) !u8 {
        const f = try c.source(c.p.pos.?) orelse return c.fail("no workflow {s}", .{c.p.pos.?});
        try c.out.writeAll(f.src);
        if (!std.mem.endsWith(u8, f.src, "\n")) try c.out.writeByte('\n');
        return 0;
    }

    fn validateFile(c: *Ctx) !u8 {
        const file = c.p.pos.?;
        const src = Io.Dir.cwd().readFileAllocOptions(c.rt.io, file, c.a, .limited(1 << 20), .of(u8), 0) catch |e| return c.fail("cannot read {s}: {t}", .{ file, e });
        var parsed = try c.load(file, src) orelse return 1;
        defer parsed.deinit();
        try c.out.print("{s}: ok ({s})\n", .{ file, parsed.def.name });
        return 0;
    }

    // ---- running ----

    fn runNamed(c: *Ctx) !u8 {
        const name = c.p.pos.?;
        const f = try c.source(name) orelse return c.fail("no workflow {s}", .{name});
        var parsed = try c.load(name, f.src) orelse return 1;
        defer parsed.deinit();
        const args: std.json.Value = if (c.p.args_json) |j|
            std.json.parseFromSliceLeaky(std.json.Value, c.a, j, .{}) catch return c.fail("--args is not valid JSON", .{})
        else
            .{ .object = .empty };
        if (args != .object) return c.fail("--args must be a JSON object", .{});
        return c.execute(&parsed.def, args, f.src, null);
    }

    fn resumeRun(c: *Ctx) !u8 {
        const old = RunId.parse(c.p.pos.?) catch return c.fail("invalid run id {s}", .{c.p.pos.?});
        const src_path = try std.fmt.allocPrint(c.a, ".zigguro/runs/{s}/workflow.zon", .{&old.text()});
        const args_path = try std.fmt.allocPrint(c.a, ".zigguro/runs/{s}/args.json", .{&old.text()});
        const src = c.ws.readFileAllocOptions(c.rt.io, src_path, c.a, .limited(1 << 20), .of(u8), 0) catch return c.fail("run {f} has no saved workflow", .{old});
        const args_text = c.ws.readFileAlloc(c.rt.io, args_path, c.a, .limited(1 << 24)) catch "{}";
        const args = std.json.parseFromSliceLeaky(std.json.Value, c.a, args_text, .{}) catch return c.fail("run {f} has unreadable arguments", .{old});
        var parsed = try c.load(src_path, src) orelse return 1;
        defer parsed.deinit();
        return c.execute(&parsed.def, args, src, old);
    }

    fn execute(c: *Ctx, d: *const wf.WorkflowDef, args: std.json.Value, src: []const u8, prev: ?RunId) !u8 {
        const gpa = c.rt.gpa;
        const io = c.rt.io;
        var runs_dir = try c.ws.createDirPathOpen(io, ".zigguro/runs", .{});
        defer runs_dir.close(io);
        const lock = (try runs.ipc.HostLock.acquire(io, runs_dir)) orelse {
            try c.err.print("zg workflow: an agent host is running for this workspace (pid {d}); stop it or run the workflow from it\n", .{runs.ipc.HostLock.holderPid(io, runs_dir) orelse 0});
            return 3;
        };
        defer lock.release(io);
        const reg = try runs.RunRegistry.init(gpa, io, runs_dir, .{});
        defer reg.deinit();
        _ = try reg.load(.{ .host_alive = false });

        var rt_agents: ?*AgentRuntime = null;
        defer if (rt_agents) |r| r.destroy();
        const agents = c.o.agents orelse blk: {
            const envm = c.o.environ orelse return c.fail("no environment", .{});
            rt_agents = try AgentRuntime.create(c.rt, envm, c.p.workspace, c.err, "zg workflow");
            break :blk rt_agents.?.agentPort();
        };
        const cwd = try c.ws.realPathFileAlloc(io, ".", c.a);

        var hw: wf.HostWorkers = .init(gpa, io, reg);
        defer hw.deinit();
        const host = try runs.RunHost.init(gpa, io, reg, agents, null, .builtin, .{ .workspace_root = cwd, .observer = hw.observer() });
        defer host.deinit();
        var globber: Globber = .{ .ws = c.ws, .io = io };
        var builtins = try wf.BuiltinRegistry.standard(gpa, .{ .glob = .{ .ctx = &globber, .glob = Globber.glob } });
        defer builtins.deinit();
        var commands: Commands = .{ .c = c, .cwd = cwd };
        const eng = try wf.WorkflowEngine.init(gpa, io, reg, .{
            .workers = hw.port(),
            .commands = .{ .ctx = &commands, .exec = Commands.exec },
            .library = c.lib,
            .builtins = &builtins,
            .runs_dir = runs_dir,
            .validator = null,
        });
        defer eng.deinit();
        try hw.attach(host, eng);

        const opts: wf.WorkflowEngine.StartOpts = .{ .origin = .cli, .source = src, .schema_files = c.schemaFiles() };
        const id = (if (prev) |old| eng.resumeFrom(old, d, args, opts) else eng.start(d, args, opts)) catch |e| switch (e) {
            error.MissingArgument => return c.fail("a required argument is missing (--args '{{\"name\": …}}')", .{}),
            error.FileNotFound => return c.fail("run {f} has no journal", .{prev.?}),
            else => return e,
        };
        const started_ms = reg.nowMs();
        if (c.p.json) {
            try c.event(.{ .type = "workflow.started", .run = &id.text(), .name = d.name, .protocol = "zg.stream/1" });
        } else try c.out.print("{s}: run {f}\n", .{ d.name, id });
        try c.out.flush();
        const final = try c.follow(eng, id, runs_dir);
        const p = (try eng.progress(id, c.a)).?;
        const summary = blk: {
            const v = reg.snapshot();
            defer reg.release(v);
            const rec = v.get(id) orelse break :blk "";
            break :blk try c.a.dupe(u8, if (final == .completed) rec.summary else rec.error_ orelse "");
        };
        if (c.p.json) {
            try c.event(.{
                .type = "result",
                .subtype = switch (final) {
                    .completed => "success",
                    .stopped => "error_interrupted",
                    else => if (std.mem.startsWith(u8, summary, "budget")) "error_budget" else "error_during_execution",
                },
                .is_error = final != .completed,
                .result = summary,
                .workflow_run = &id.text(),
                .status = @tagName(final),
                .agents = p.agents,
                .total_cost_usd = @as(f64, @floatFromInt(p.cost.micros)) / 1e6,
                .duration_ms = reg.nowMs() - started_ms,
            });
        } else try c.out.print("{s}: {s}{s}{s}\n", .{ d.name, @tagName(final), if (summary.len > 0) ": " else "", summary });
        reg.flush();
        return if (final == .completed) 0 else 1;
    }

    fn event(c: *Ctx, v: anytype) !void {
        try std.json.Stringify.value(v, .{ .emit_null_optional_fields = false }, c.out);
        try c.out.writeByte('\n');
    }

    /// Prints step changes until the run ends; answers gates; honours
    /// `zg workflow stop`.
    fn follow(c: *Ctx, eng: *wf.WorkflowEngine, id: RunId, runs_dir: Io.Dir) !runs.RunStatus {
        const io = c.rt.io;
        var last: std.ArrayList(wf.progress.StepProgress) = .empty;
        var asked: ?[]const u8 = null;
        const stop_path = try std.fmt.allocPrint(c.a, "{s}/stop", .{&id.text()});
        while (true) {
            var frame: std.heap.ArenaAllocator = .init(c.rt.gpa);
            defer frame.deinit();
            const p = (try eng.progress(id, frame.allocator())).?;
            for (p.steps, 0..) |s, i| {
                if (i < last.items.len and same(last.items[i], s)) continue;
                try c.stepLine(s);
            }
            last.clearRetainingCapacity();
            for (p.steps) |s| try last.append(c.a, s);
            try c.out.flush();
            if (p.gate) |g| {
                if (asked == null or !std.mem.eql(u8, asked.?, g.step)) {
                    asked = try c.a.dupe(u8, g.step);
                    const ok = try c.askGate(g);
                    eng.answerGate(id, g.step, ok, if (ok) null else "rejected on the command line") catch {};
                }
            }
            if (p.status.isTerminal()) return p.status;
            if (runs_dir.access(io, stop_path, .{})) |_| {
                eng.stop(id);
                runs_dir.deleteFile(io, stop_path) catch {};
            } else |_| {}
            io.sleep(.fromMilliseconds(c.o.poll_ms), .awake) catch {};
        }
    }

    fn same(a: wf.progress.StepProgress, b: wf.progress.StepProgress) bool {
        return a.state == b.state and a.done == b.done and a.failed == b.failed and a.running == b.running and a.total == b.total and a.retries == b.retries and a.round == b.round;
    }

    fn stepLine(c: *Ctx, s: wf.progress.StepProgress) !void {
        if (s.state == .pending) return;
        if (c.p.json) return c.event(.{
            .type = "workflow.step",
            .step = s.id,
            .phase = s.phase,
            .state = @tagName(s.state),
            .total = s.total,
            .done = s.done,
            .failed = s.failed,
            .running = s.running,
            .retries = s.retries,
            .@"error" = s.error_,
        });
        try c.out.print("  {s}: {s}", .{ s.id, @tagName(s.state) });
        if (s.total > 1 or s.kind == .map) try c.out.print(" {d}/{d}", .{ s.done, s.total });
        if (s.running > 0) try c.out.print(", {d} running", .{s.running});
        if (s.failed > 0) try c.out.print(", {d} failed", .{s.failed});
        if (s.retries > 0) try c.out.print(", {d} retries", .{s.retries});
        if (s.round > 0 and s.kind == .loop_until) try c.out.print(", round {d}", .{s.round});
        if (s.error_) |e| try c.out.print(": {s}", .{e});
        try c.out.writeByte('\n');
    }

    fn askGate(c: *Ctx, g: wf.progress.Gate) !bool {
        if (c.p.json) try c.event(.{ .type = "workflow.gate", .step = g.step, .title = g.title, .show = g.show }) else {
            try c.out.print("? {s}\n", .{g.title});
            if (g.show.len > 0) try c.out.print("{s}\n", .{g.show[0..@min(g.show.len, 4000)]});
        }
        try c.out.flush();
        return c.confirm("Approve?");
    }

    /// --approve says yes; otherwise asks on the terminal (no terminal:
    /// no).
    fn confirm(c: *Ctx, question: []const u8) !bool {
        if (c.p.approve) return true;
        const in = c.o.stdin orelse {
            try c.err.print("zg workflow: {s} no (no terminal to ask; use --approve)\n", .{question});
            return false;
        };
        try c.err.print("{s} [y/N] ", .{question});
        try c.err.flush();
        const line = in.takeDelimiterExclusive('\n') catch return false;
        in.toss(@min(1, in.bufferedLen()));
        const t = std.mem.trim(u8, line, " \t\r");
        return std.ascii.eqlIgnoreCase(t, "y") or std.ascii.eqlIgnoreCase(t, "yes");
    }

    // ---- registry ----

    fn status(c: *Ctx) !u8 {
        const gpa = c.rt.gpa;
        const io = c.rt.io;
        const id = RunId.parse(c.p.pos.?) catch return c.fail("invalid run id {s}", .{c.p.pos.?});
        var runs_dir = c.ws.openDir(io, ".zigguro/runs", .{ .iterate = true }) catch return c.fail("no runs in this workspace", .{});
        defer runs_dir.close(io);
        const reg = try runs.RunRegistry.init(gpa, io, runs_dir, .{});
        defer reg.deinit();
        _ = try reg.load(.{ .host_alive = true });
        {
            // Ended runs load as index rows without their parent; read the
            // journals of the workers started after this run.
            const v0 = reg.snapshot();
            defer reg.release(v0);
            if (v0.get(id) == null) return c.fail("no run {f}", .{id});
            for (v0.runs) |r| {
                if (r.spec.kind != .workflow_worker or r.id.order(id) != .gt) continue;
                reg.loadDetail(r.id) catch {};
            }
        }
        const v = reg.snapshot();
        defer reg.release(v);
        const rec = v.get(id) orelse return c.fail("no run {f}", .{id});
        const Child = struct { id: []const u8, title: []const u8, step: []const u8, status: []const u8, cost_micros: u64 };
        var kids: std.ArrayList(Child) = .empty;
        var i = v.runs.len;
        while (i > 0) {
            i -= 1;
            const r = v.runs[i];
            if (r.spec.parent == null or !r.spec.parent.?.eql(id)) continue;
            const step = switch (r.spec.origin) {
                .workflow => |w| w.step,
                else => "",
            };
            try kids.append(c.a, .{ .id = try c.a.dupe(u8, &r.id.text()), .title = r.spec.title, .step = step, .status = @tagName(r.status), .cost_micros = r.cost.micros });
        }
        if (c.p.json) {
            try c.event(.{ .run = &id.text(), .title = rec.spec.title, .status = @tagName(rec.status), .cost_micros = rec.cost.micros, .question = rec.question, .@"error" = rec.error_, .summary = rec.summary, .agents = kids.items });
            return 0;
        }
        try c.out.print("{s}  {s}  ${d}.{d:0>4}\n", .{ rec.spec.title, @tagName(rec.status), rec.cost.micros / 1_000_000, (rec.cost.micros % 1_000_000) / 100 });
        if (rec.question) |q| try c.out.print("waiting: {s}\n", .{q});
        if (rec.error_) |e| try c.out.print("error: {s}\n", .{e});
        for (kids.items) |k| try c.out.print("  {s: <14}  {s: <11}  {s}\n", .{ k.step, k.status, k.title });
        return 0;
    }

    fn stopRun(c: *Ctx) !u8 {
        const id = RunId.parse(c.p.pos.?) catch return c.fail("invalid run id {s}", .{c.p.pos.?});
        const dir_path = try std.fmt.allocPrint(c.a, ".zigguro/runs/{s}", .{&id.text()});
        var d = c.ws.openDir(c.rt.io, dir_path, .{}) catch return c.fail("no workflow run {f}", .{id});
        defer d.close(c.rt.io);
        try d.writeFile(c.rt.io, .{ .sub_path = "stop", .data = "" });
        try c.out.print("asked run {f} to stop\n", .{id});
        return 0;
    }

    fn save(c: *Ctx) !u8 {
        const id = RunId.parse(c.p.pos.?) catch return c.fail("invalid run id {s}", .{c.p.pos.?});
        const name = c.p.as orelse return usage(c.err);
        if (!wf.def.validName(name)) return c.fail("invalid name {s}: use [a-z][a-z0-9-]*", .{name});
        const src_path = try std.fmt.allocPrint(c.a, ".zigguro/runs/{s}/workflow.zon", .{&id.text()});
        const src = c.ws.readFileAllocOptions(c.rt.io, src_path, c.a, .limited(1 << 20), .of(u8), 0) catch return c.fail("run {f} has no saved workflow", .{id});
        const renamed = try renameDef(c.a, src, name) orelse return c.fail("cannot find the .name field in the run's workflow", .{});
        var parsed = try c.load(name, renamed) orelse return 1;
        parsed.deinit();
        const dest = try std.fmt.allocPrint(c.a, ".zigguro/workflows/{s}.zon", .{name});
        if (c.ws.access(c.rt.io, dest, .{})) |_| return c.fail("{s} already exists", .{dest}) else |_| {}
        try c.ws.createDirPath(c.rt.io, ".zigguro/workflows");
        try c.ws.writeFile(c.rt.io, .{ .sub_path = dest, .data = renamed });
        try c.out.print("saved {s}\n", .{dest});
        return 0;
    }
};

/// `src` with its top-level `.name = "…"` replaced.
pub fn renameDef(a: Allocator, src: []const u8, name: []const u8) !?[:0]const u8 {
    const key = std.mem.indexOf(u8, src, ".name") orelse return null;
    const q1 = std.mem.indexOfScalarPos(u8, src, key, '"') orelse return null;
    const q2 = std.mem.indexOfScalarPos(u8, src, q1 + 1, '"') orelse return null;
    return try std.mem.concatWithSentinel(a, u8, &.{ src[0 .. q1 + 1], name, src[q2..] }, 0);
}

/// `files.glob` over the workspace (VS Code glob dialect), skipping VCS,
/// build and dependency folders.
const Globber = struct {
    ws: Io.Dir,
    io: Io,

    const skip = [_][]const u8{ ".git", ".jj", ".zigguro", ".zig-cache", "zig-out", "node_modules" };

    fn glob(ctx: *anyopaque, arena: Allocator, pattern: []const u8) anyerror![]const []const u8 {
        const g: *Globber = @ptrCast(@alignCast(ctx));
        var set = try zg_workspace.ignore.GlobSet.compile(arena, pattern, .{});
        var out: std.ArrayList([]const u8) = .empty;
        var dir = try g.ws.openDir(g.io, ".", .{ .iterate = true });
        defer dir.close(g.io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(g.io)) |en| {
            if (en.kind == .directory) {
                for (skip) |s| if (std.mem.eql(u8, en.basename, s)) {
                    walker.leave(g.io);
                    break;
                };
                continue;
            }
            if (en.kind != .file) continue;
            const rel = try arena.dupe(u8, en.path);
            if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, rel, '\\', '/');
            if (set.matches(rel)) try out.append(arena, rel);
            if (out.items.len > wf.def.max_map_items_cap) break;
        }
        std.mem.sort([]const u8, out.items, {}, struct {
            fn lt(_: void, l: []const u8, r: []const u8) bool {
                return std.mem.order(u8, l, r) == .lt;
            }
        }.lt);
        return out.items;
    }
};

/// Commands run in the workspace after a yes on the terminal (or
/// --approve).
const Commands = struct {
    c: *Ctx,
    cwd: []const u8,
    mutex: Io.Mutex = .init,

    fn exec(ctx: *anyopaque, arena: Allocator, req: wf.WorkflowEngine.CommandRequest) anyerror!wf.WorkflowEngine.CommandResult {
        const self: *Commands = @ptrCast(@alignCast(ctx));
        const c = self.c;
        const io = c.rt.io;
        const line = try std.mem.join(arena, " ", req.argv);
        {
            // One question at a time.
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const q = try std.fmt.allocPrint(arena, "Run `{s}` ({s})?", .{ line, req.step });
            if (!try c.confirm(q)) return error.Denied;
        }
        const argv: []const []const u8 = if (req.shell)
            if (builtin.os.tag == .windows) &.{ "cmd.exe", "/d", "/s", "/c", req.argv[0] } else &.{ "/bin/sh", "-c", req.argv[0] }
        else
            req.argv;
        const cwd = if (req.cwd) |d| try std.fs.path.resolve(arena, &.{ self.cwd, d }) else self.cwd;
        const r = try std.process.run(arena, io, .{ .argv = argv, .cwd = .{ .path = cwd }, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) });
        const code: i32 = switch (r.term) {
            .exited => |x| x,
            else => -1,
        };
        const both = try std.mem.concat(arena, u8, &.{ r.stdout, r.stderr });
        return .{ .exit_code = code, .output = both[both.len -| 64 * 1024..] };
    }
};

// ---- tests ----

const testing = std.testing;

const Out = struct {
    out: Io.Writer.Allocating,
    err: Io.Writer.Allocating,

    fn init() Out {
        return .{ .out = .init(testing.allocator), .err = .init(testing.allocator) };
    }
    fn deinit(o: *Out) void {
        o.out.deinit();
        o.err.deinit();
    }
    fn clear(o: *Out) void {
        o.out.clearRetainingCapacity();
        o.err.clearRetainingCapacity();
    }
};

test "zg workflow lists, shows and validates" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(ws);
    try tmp.dir.createDirPath(testing.io, ".zigguro/workflows");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".zigguro/workflows/hello.zon", .data = ".{ .version = 1, .name = \"hello\", .description = \"Say hello\", .steps = .{ .{ .id = \"hi\", .agent = .{ .prompt = \"hello\" } } } }\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bad.zon", .data = ".{ .version = 1, .name = \"bad\", .steps = .{ .{ .id = \"x\", .agent = .{ .prompt = \"{{$.later}}\" } } } }\n" });
    var o: Out = .init();
    defer o.deinit();

    try testing.expectEqual(@as(u8, 0), try runIn(&rt, &.{ "list", "--workspace", ws }, &o.out.writer, &o.err.writer, .{}));
    try testing.expect(std.mem.indexOf(u8, o.out.written(), "hello                 project   Say hello") != null);
    try testing.expect(std.mem.indexOf(u8, o.out.written(), "fix-until-green") != null);
    o.clear();
    try testing.expectEqual(@as(u8, 0), try runIn(&rt, &.{ "show", "audit-files", "--workspace", ws }, &o.out.writer, &o.err.writer, .{}));
    try testing.expect(std.mem.indexOf(u8, o.out.written(), "@workflow/audit-file") != null);
    o.clear();
    // Every template validates.
    for (wf.templates.all) |t| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}.zon", .{t.name});
        defer testing.allocator.free(path);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = t.source });
        const full = try std.fs.path.joinZ(testing.allocator, &.{ ws, path });
        defer testing.allocator.free(full);
        try testing.expectEqual(@as(u8, 0), try runIn(&rt, &.{ "validate", full, "--workspace", ws }, &o.out.writer, &o.err.writer, .{}));
    }
    o.clear();
    const bad = try std.fs.path.joinZ(testing.allocator, &.{ ws, "bad.zon" });
    defer testing.allocator.free(bad);
    try testing.expectEqual(@as(u8, 1), try runIn(&rt, &.{ "validate", bad, "--workspace", ws }, &o.out.writer, &o.err.writer, .{}));
    try testing.expect(std.mem.indexOf(u8, o.err.written(), "unknown step \"later\"") != null);
}

test "zg workflow runs, reports status, resumes and saves" {
    const Fake = runs.fake_agents.Fake;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(ws);
    try tmp.dir.createDirPath(testing.io, ".zigguro/workflows");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".zigguro/workflows/two.zon", .data =
        \\.{ .version = 1, .name = "two",
        \\  .args = .{ .{ .name = "topic" } },
        \\  .steps = .{
        \\    .{ .id = "draft", .agent = .{ .prompt = "write about {{$args.topic}}" } },
        \\    .{ .id = "ok", .gate = .{ .title = "Publish it?", .show = "$.draft" } },
        \\    .{ .id = "final", .reduce = .{ .prompt = "polish {{$.draft}}" } },
        \\  },
        \\}
        \\
    });
    var agents: Fake = .{ .auto_complete = true };
    defer agents.deinit();
    var o: Out = .init();
    defer o.deinit();

    // Missing argument.
    try testing.expectEqual(@as(u8, 1), try runIn(&rt, &.{ "run", "two", "--workspace", ws }, &o.out.writer, &o.err.writer, .{ .agents = agents.agentPort(), .poll_ms = 5 }));
    o.clear();
    // The gate is answered on "stdin".
    var in: Io.Reader = .fixed("y\n");
    try testing.expectEqual(@as(u8, 0), try runIn(&rt, &.{ "run", "two", "--args", "{\"topic\":\"zig\"}", "--json", "--workspace", ws }, &o.out.writer, &o.err.writer, .{ .agents = agents.agentPort(), .stdin = &in, .poll_ms = 5 }));
    const text = o.out.written();
    try testing.expect(std.mem.startsWith(u8, text, "{\"type\":\"workflow.started\""));
    try testing.expect(std.mem.indexOf(u8, text, "{\"type\":\"workflow.gate\",\"step\":\"ok\",\"title\":\"Publish it?\",\"show\":\"done\\nnow\"}") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"type\":\"workflow.step\",\"step\":\"final\",\"state\":\"done\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false") != null);
    try testing.expectEqual(@as(usize, 2), agents.count());
    const run_at = std.mem.indexOf(u8, text, "\"run\":\"").? + 7;
    var id_buf: [26:0]u8 = @splat(0);
    @memcpy(id_buf[0..26], text[run_at..][0..26]);
    o.clear();

    try testing.expectEqual(@as(u8, 0), try runIn(&rt, &.{ "status", &id_buf, "--workspace", ws }, &o.out.writer, &o.err.writer, .{}));
    try testing.expect(std.mem.indexOf(u8, o.out.written(), "two  completed") != null);
    try testing.expect(std.mem.indexOf(u8, o.out.written(), "draft") != null);
    o.clear();

    // Resume reuses both agents and the gate answer.
    try testing.expectEqual(@as(u8, 0), try runIn(&rt, &.{ "resume", &id_buf, "--workspace", ws }, &o.out.writer, &o.err.writer, .{ .agents = agents.agentPort(), .poll_ms = 5 }));
    try testing.expectEqual(@as(usize, 2), agents.count());
    try testing.expect(std.mem.indexOf(u8, o.out.written(), "two: completed") != null);
    o.clear();

    // A rejected gate (no terminal, no --approve) stops the run.
    try testing.expectEqual(@as(u8, 1), try runIn(&rt, &.{ "run", "two", "--args", "{\"topic\":\"c\"}", "--workspace", ws }, &o.out.writer, &o.err.writer, .{ .agents = agents.agentPort(), .poll_ms = 5 }));
    try testing.expect(std.mem.indexOf(u8, o.out.written(), "two: stopped: step ok: rejected at gate") != null);
    o.clear();

    try testing.expectEqual(@as(u8, 0), try runIn(&rt, &.{ "save", &id_buf, "--as", "two-copy", "--workspace", ws }, &o.out.writer, &o.err.writer, .{}));
    const saved = try tmp.dir.readFileAlloc(testing.io, ".zigguro/workflows/two-copy.zon", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, ".name = \"two-copy\"") != null);
    try testing.expectEqual(@as(u8, 1), try runIn(&rt, &.{ "save", &id_buf, "--as", "two-copy", "--workspace", ws }, &o.out.writer, &o.err.writer, .{}));
}

test "zg workflow refuses to run while a host owns the workspace" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(ws);
    var runs_dir = try tmp.dir.createDirPathOpen(testing.io, ".zigguro/runs", .{});
    defer runs_dir.close(testing.io);
    const lock = (try runs.ipc.HostLock.acquire(testing.io, runs_dir)).?;
    defer lock.release(testing.io);
    var agents: runs.fake_agents.Fake = .{ .auto_complete = true };
    defer agents.deinit();
    var o: Out = .init();
    defer o.deinit();
    try testing.expectEqual(@as(u8, 3), try runIn(&rt, &.{ "run", "fix-until-green", "--workspace", ws }, &o.out.writer, &o.err.writer, .{ .agents = agents.agentPort() }));
}

test "renameDef replaces the top-level name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = (try renameDef(arena.allocator(), ".{ .version = 1, .name = \"old\", .steps = .{} }", "new")).?;
    try testing.expectEqualStrings(".{ .version = 1, .name = \"new\", .steps = .{} }", r);
}
