//! `zg automation` (E13.F02.S01.T03): the workspace's automations from
//! the command line.
//!
//! `list`, `show`, `history` and `validate` read `.zigguro/automations`
//! and the history directly. `enable` and `disable` rewrite the file (the
//! user's own edit) and ask a running agent host to reload. `run` asks the
//! agent host to fire the automation now (exit 1 without one). `validate`
//! exits 1 when any file has a problem, printing `file:line:col: message`
//! lines, so it can run in CI.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_agents = @import("zg_agents");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const sched = zg_agents.sched;
const runs = zg_agents.runs;
const protocol = runs.protocol;
const ipc = runs.ipc;

pub const usage_text =
    \\Usage: zg automation list [--json]
    \\       zg automation show NAME [--json]
    \\       zg automation enable NAME
    \\       zg automation disable NAME
    \\       zg automation run NAME
    \\       zg automation history NAME [--limit N] [--json]
    \\       zg automation validate [--json]
    \\
    \\Options: --workspace DIR (default: the current directory)
    \\
    \\Automations live in .zigguro/automations/<name>.zon (see
    \\docs/formats/automation.md). `run` needs the workspace's agent host
    \\(the GUI or `zg agents host`).
    \\
;

pub const Cmd = enum { list, show, enable, disable, run, history, validate };

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

pub fn run(rt: *zg_core.Runtime, argv: []const [:0]const u8) !u8 {
    var s: Streams = undefined;
    s.init(rt.io);
    defer s.flush();
    return runIn(rt, argv, &s.out_w.interface, &s.err_w.interface);
}

fn usage(err: *Io.Writer) !u8 {
    try err.writeAll(usage_text);
    return 2;
}

/// `zg automation` with the output streams given.
pub fn runIn(rt: *zg_core.Runtime, argv: []const [:0]const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    const gpa = rt.gpa;
    const io = rt.io;
    if (argv.len == 0 or std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h")) {
        try out.writeAll(usage_text);
        return if (argv.len == 0) 2 else 0;
    }
    const cmd = std.meta.stringToEnum(Cmd, argv[0]) orelse return usage(err);
    var json = false;
    var limit: u32 = 20;
    var workspace: []const u8 = ".";
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(gpa);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, a, "--workspace")) {
            i += 1;
            if (i >= argv.len) return usage(err);
            workspace = argv[i];
        } else if (std.mem.eql(u8, a, "--limit")) {
            i += 1;
            if (i >= argv.len) return usage(err);
            limit = std.fmt.parseInt(u32, argv[i], 10) catch return usage(err);
        } else try pos.append(gpa, a);
    }
    const need: usize = switch (cmd) {
        .list, .validate => 0,
        else => 1,
    };
    if (pos.items.len != need) return usage(err);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ws = Io.Dir.cwd().openDir(io, workspace, .{}) catch |e| {
        try err.print("zg automation: cannot open {s}: {t}\n", .{ workspace, e });
        return 1;
    };
    defer ws.close(io);
    const autos = ws.createDirPathOpen(io, sched.loader.dir_path, .{ .open_options = .{ .iterate = true } }) catch |e| {
        try err.print("zg automation: cannot open {s}: {t}\n", .{ sched.loader.dir_path, e });
        return 1;
    };
    defer autos.close(io);
    const hist: ?Io.Dir = ws.openDir(io, sched.Service.history_path, .{}) catch null;
    defer if (hist) |h| h.close(io);
    const zone = sched.utcZone();
    const key = ws.realPathFileAlloc(io, ".", arena) catch "";
    var src: sched.tools.Source = .{
        .gpa = gpa,
        .io = io,
        .dir = autos,
        .history_dir = hist,
        .zone = zone,
        .workspace_key = key,
    };

    switch (cmd) {
        .list => {
            const rows = try sched.tools.listRows(&src, arena);
            if (json) return writeJson(out, .{ .automations = rows });
            if (rows.len == 0) try out.writeAll("No automations. Add one in .zigguro/automations/.\n");
            for (rows) |r| {
                const state: []const u8 = if (r.problem != null) "invalid" else if (r.needs_approval) "needs approval" else if (r.enabled) "enabled" else "disabled";
                const next = if (r.next_fires.len > 0) r.next_fires[0] else "-";
                try out.print("{s}  [{s}]  next {s}  last {s}\n    {s}\n", .{ r.name, state, next, r.last_status orelse "-", r.problem orelse r.triggers });
            }
        },
        .validate => {
            var res = try sched.loader.loadAll(io, gpa, autos, null);
            defer res.deinit();
            var bad: usize = 0;
            const Diag = struct { file: []const u8, line: u32, column: u32, message: []const u8 };
            var diags: std.ArrayList(Diag) = .empty;
            for (res.items) |it| if (it.problem) |p| {
                bad += 1;
                try diags.append(arena, .{ .file = try std.fmt.allocPrint(arena, "{s}/{s}", .{ sched.loader.dir_path, it.file }), .line = p.line, .column = p.column, .message = p.message });
            };
            if (json) {
                _ = try writeJson(out, .{ .files = res.items.len, .problems = diags.items });
            } else {
                for (diags.items) |d| try out.print("{s}:{d}:{d}: {s}\n", .{ d.file, d.line, d.column, d.message });
                try out.print("{d} automation file(s), {d} with problems\n", .{ res.items.len, bad });
            }
            return if (bad == 0) 0 else 1;
        },
        .show => {
            const name = pos.items[0];
            const file = try std.fmt.allocPrint(arena, "{s}.zon", .{name});
            const l = try sched.loader.loadOne(io, arena, autos, file, null);
            const a = l.automation orelse {
                if (l.source.len == 0) {
                    try err.print("zg automation: no automation named \"{s}\"\n", .{name});
                } else try err.print("{s}/{s}:{d}:{d}: {s}\n", .{ sched.loader.dir_path, file, l.problem.?.line, l.problem.?.column, l.problem.?.message });
                return 1;
            };
            var times: [5]i64 = undefined;
            const n = sched.Scheduler.upcoming(&a, zone, key, nowMs(io), &times);
            const next = try sched.tools.localTimes(&src, arena, times[0..n]);
            const triggers = try sched.tools.summarizeTriggers(arena, &a);
            if (json) return writeJson(out, .{ .automation = a, .triggers = triggers, .next_fires = next });
            try out.print("{s}{s}{s}\n", .{ a.name, if (a.description.len > 0) ": " else "", a.description });
            try out.print("  enabled   {}\n  triggers  {s}\n  profile   {s}\n  isolation {t}\n  overlap   {t}\n  catch-up  {t}\n", .{ a.enabled, triggers, a.profile, a.isolation, a.overlap, a.catch_up });
            if (a.budgets.max_cost_micro_usd) |m| try out.print("  budget    ${d}.{d:0>2} per run\n", .{ m / 1_000_000, m % 1_000_000 / 10_000 });
            switch (a.action) {
                .agent => |g| try out.print("  prompt    {s}\n", .{g.prompt}),
                .workflow => |w| try out.print("  workflow  {s}\n", .{w.workflow}),
            }
            for (next, 0..) |t, k| try out.print("  {s} {s}\n", .{ if (k == 0) "next     " else "         ", t });
        },
        .enable, .disable => {
            const name = pos.items[0];
            const file = try std.fmt.allocPrint(arena, "{s}.zon", .{name});
            const l = try sched.loader.loadOne(io, arena, autos, file, null);
            var a = l.automation orelse {
                try err.print("zg automation: {s}: {s}\n", .{ file, if (l.problem) |p| p.message else "not found" });
                return 1;
            };
            a.enabled = cmd == .enable;
            const text = try sched.automation.toZon(arena, &a);
            var af = try autos.createFileAtomic(io, file, .{ .replace = true });
            defer af.deinit(io);
            try af.file.writeStreamingAll(io, text);
            try af.replace(io);
            try out.print("{s} {s}\n", .{ if (a.enabled) "Enabled" else "Disabled", name });
            // Tell a running host now (it would notice within seconds).
            if (try hostClient(rt, ws)) |c| {
                defer c.deinit();
                _ = c.call(protocol.methods.automation_reload, .{}, protocol.Ok, arena) catch {};
            }
        },
        .run => {
            const c = try hostClient(rt, ws) orelse {
                try err.print("zg automation: no agent host is running for {s} (start one with `zg agents host`)\n", .{workspace});
                return 1;
            };
            defer c.deinit();
            const r = c.call(protocol.methods.automation_run, protocol.AutomationRunParams{ .name = pos.items[0] }, protocol.AutomationRunResult, arena) catch |e| {
                try err.print("zg automation: run failed: {t}\n", .{e});
                return 1;
            };
            if (json) return writeJson(out, r);
            try out.print("Fired {s} (fire {d})\n", .{ pos.items[0], r.fire_id });
        },
        .history => {
            const h = hist orelse {
                if (json) return writeJson(out, .{ .name = pos.items[0], .records = &[_]sched.history.Record{} });
                try out.writeAll("No history yet.\n");
                return 0;
            };
            const recs = try sched.history.readTail(arena, io, h, pos.items[0], limit);
            if (json) return writeJson(out, .{ .name = pos.items[0], .records = recs });
            if (recs.len == 0) try out.writeAll("No history yet.\n");
            for (recs) |r| {
                const due = try sched.tools.localTimes(&src, arena, &.{r.due});
                if (r.skip) |sk| {
                    try out.print("{s}  {t}  skipped: {t}\n", .{ due[0], r.reason, sk });
                } else if (r.run) |id| {
                    try out.print("{s}  {t}  run {f}\n", .{ due[0], r.reason, id });
                } else try out.print("{s}  {t}\n", .{ due[0], r.reason });
            }
        },
    }
    return 0;
}

fn writeJson(out: *Io.Writer, v: anytype) !u8 {
    try std.json.Stringify.value(v, .{ .emit_null_optional_fields = false }, out);
    try out.writeByte('\n');
    return 0;
}

fn nowMs(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

/// The workspace's agent host, or null when none runs.
fn hostClient(rt: *zg_core.Runtime, ws: Io.Dir) !?*ipc.HostClient {
    const dir = ws.openDir(rt.io, ".zigguro/runs", .{}) catch return null;
    defer dir.close(rt.io);
    return ipc.HostClient.connect(rt, dir) catch null;
}

test "zg automation list, show, enable and validate" {
    const testing = std.testing;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const ws = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(ws);
    try tmp.dir.createDirPath(io, ".zigguro/automations");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zigguro/automations/tidy.zon", .data = ".{ .name = \"tidy\", .description = \"Tidy up\", .triggers = .{.{ .schedule = .{ .cron = \"*/5 * * * *\" } }}, .action = .{ .agent = .{ .prompt = \"Tidy\" } }, .budgets = .{ .max_cost_micro_usd = 250000 } }" });
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var errw: Io.Writer.Allocating = .init(testing.allocator);
    defer errw.deinit();

    try testing.expectEqual(@as(u8, 0), try runIn(&rt, &.{ "list", "--workspace", ws }, &out.writer, &errw.writer));
    try testing.expect(std.mem.indexOf(u8, out.written(), "tidy  [enabled]") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "every 5 minutes") != null);
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), try runIn(&rt, &.{ "show", "tidy", "--workspace", ws }, &out.writer, &errw.writer));
    try testing.expect(std.mem.indexOf(u8, out.written(), "budget    $0.25 per run") != null);
    out.clearRetainingCapacity();
    // --json is one JSON document.
    try testing.expectEqual(@as(u8, 0), try runIn(&rt, &.{ "list", "--json", "--workspace", ws }, &out.writer, &errw.writer));
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    parsed.deinit();
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), try runIn(&rt, &.{ "disable", "tidy", "--workspace", ws }, &out.writer, &errw.writer));
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), try runIn(&rt, &.{ "list", "--workspace", ws }, &out.writer, &errw.writer));
    try testing.expect(std.mem.indexOf(u8, out.written(), "tidy  [disabled]") != null);
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), try runIn(&rt, &.{ "validate", "--workspace", ws }, &out.writer, &errw.writer));
    try tmp.dir.writeFile(io, .{ .sub_path = ".zigguro/automations/bad.zon", .data = ".{ .name = \"bad\" }" });
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 1), try runIn(&rt, &.{ "validate", "--workspace", ws }, &out.writer, &errw.writer));
    try testing.expect(std.mem.indexOf(u8, out.written(), ".zigguro/automations/bad.zon:1:") != null);
    // No host: run fails cleanly.
    try testing.expectEqual(@as(u8, 1), try runIn(&rt, &.{ "run", "tidy", "--workspace", ws }, &out.writer, &errw.writer));
    try testing.expectEqual(@as(u8, 2), try runIn(&rt, &.{"show"}, &out.writer, &errw.writer));
}

test "cli_json_schema" {
    const testing = std.testing;
    const zg_ai = @import("zg_ai");
    const zg_mcp = @import("zg_mcp");
    const fixtures = @import("zg_cli_fixtures");
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(ws);
    try tmp.dir.createDirPath(io, ".zigguro/automations");
    try tmp.dir.createDirPath(io, ".zigguro/runs/automations");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zigguro/automations/tidy.zon", .data = ".{ .name = \"tidy\", .triggers = .{.{ .schedule = .{ .cron = \"@hourly\" } }}, .action = .{ .agent = .{ .prompt = \"Tidy\" } }, .budgets = .{ .max_cost_micro_usd = 1 } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".zigguro/automations/broken.zon", .data = ".{" });
    const hist = try tmp.dir.openDir(io, ".zigguro/runs/automations", .{});
    defer hist.close(io);
    try sched.history.append(io, hist, "tidy", .{ .t = 1, .due = 1, .reason = .scheduled, .skip = .overlap });
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var errw: Io.Writer.Allocating = .init(testing.allocator);
    defer errw.deinit();
    try testing.expectEqual(@as(u8, 0), try runIn(&rt, &.{ "list", "--json", "--workspace", ws }, &out.writer, &errw.writer));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const schema = try Io.Dir.cwd().readFileAlloc(io, fixtures.automation_schema, arena.allocator(), .limited(1 << 20));
    const c = try zg_ai.schema.validate.Compiled.init(zg_mcp.schema.toolValidator(zg_ai.schema.validate), arena.allocator(), schema);
    const r = try c.check(arena.allocator(), out.written());
    if (!r.ok) {
        for (r.errors.slice()) |e| std.debug.print("{s} {s}: {s}\n", .{ e.pointer, e.keyword, e.message });
        std.debug.print("{s}\n", .{out.written()});
        return error.TestUnexpectedResult;
    }
    // The schema rejects what it should.
    try testing.expect(!(try c.check(arena.allocator(), "{\"automations\":[{\"name\":\"x\"}]}")).ok);
}
