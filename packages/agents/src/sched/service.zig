//! A workspace's automations, assembled (E13.F02.S01.T03): the files in
//! `.zigguro/automations`, the runner, and the scheduler with its state in
//! `.zigguro/state` and history in `.zigguro/runs/automations`. The GUI
//! and `zg agents host` each own one; the scheduler lease decides which
//! one fires. `reload` re-reads the files (on a workspace file event, a
//! timer, or `zg automation enable|disable`).

const std = @import("std");
const runs = @import("../runs/root.zig");
const zone_mod = @import("zone.zig");
const loader = @import("loader.zig");
const Scheduler = @import("scheduler.zig");
const AutomationRunner = @import("runner.zig");
const tools = @import("tools.zig");
const TriggerEngine = @import("triggers.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const state_path = ".zigguro/state";
pub const history_path = ".zigguro/runs/automations";

pub const Options = struct {
    trust: ?loader.TrustPort = null,
    warn: ?AutomationRunner.WarnPort = null,
    workflows: ?AutomationRunner.WorkflowPort = null,
    /// For SCM triggers with a revset, and task triggers (claims).
    revsets: ?TriggerEngine.RevsetPort = null,
    claims: ?TriggerEngine.ClaimPort = null,
    /// Mixed into jitter; the workspace's absolute path is a good key.
    workspace_key: []const u8 = "",
    /// Reports files that failed to load (once per file content).
    on_problem: ?*const fn (ctx: ?*anyopaque, file: []const u8, line: u32, column: u32, message: []const u8) void = null,
    on_problem_ctx: ?*anyopaque = null,
};

const Service = @This();

gpa: Allocator,
io: Io,
autos: Io.Dir,
state: Io.Dir,
hist: Io.Dir,
runner: AutomationRunner,
scheduler: *Scheduler,
/// Feed it file, SCM and task events.
triggers: *TriggerEngine,
o: Options,
key: []u8,
mutex: Io.Mutex = .init,
loaded: ?loader.LoadResult = null,

/// Opens (creating) the directories under `workspace` and loads the
/// automations. Call `start` to begin firing.
pub fn init(gpa: Allocator, io: Io, workspace: Io.Dir, reg: *runs.RunRegistry, starter: AutomationRunner.StartPort, z: zone_mod.ZoneResolver, o: Options) !*Service {
    const s = try gpa.create(Service);
    errdefer gpa.destroy(s);
    const autos = try workspace.createDirPathOpen(io, loader.dir_path, .{ .open_options = .{ .iterate = true } });
    errdefer autos.close(io);
    const st = try workspace.createDirPathOpen(io, state_path, .{});
    errdefer st.close(io);
    const hist = try workspace.createDirPathOpen(io, history_path, .{});
    errdefer hist.close(io);
    const key = try gpa.dupe(u8, o.workspace_key);
    errdefer gpa.free(key);
    s.* = .{ .gpa = gpa, .io = io, .autos = autos, .state = st, .hist = hist, .runner = undefined, .scheduler = undefined, .triggers = undefined, .o = o, .key = key };
    s.runner = .init(gpa, io, reg, starter, z, .{ .warn = o.warn, .workflows = o.workflows });
    s.scheduler = try Scheduler.init(gpa, io, z, st, hist, s.runner.iface(), .{ .workspace_key = key });
    errdefer s.scheduler.deinit();
    s.triggers = try TriggerEngine.init(gpa, io, .fromScheduler(s.scheduler), .{ .registry = reg, .revsets = o.revsets, .claims = o.claims });
    errdefer s.triggers.deinit();
    try s.reload();
    return s;
}

pub fn deinit(s: *Service) void {
    s.triggers.deinit();
    s.scheduler.deinit();
    if (s.loaded) |*l| l.deinit();
    s.autos.close(s.io);
    s.state.close(s.io);
    s.hist.close(s.io);
    s.gpa.free(s.key);
    s.gpa.destroy(s);
}

pub fn start(s: *Service) !void {
    try s.scheduler.start();
    try s.triggers.start();
}

/// Re-reads the automation files and hands them to the scheduler.
pub fn reload(s: *Service) !void {
    var res = try loader.loadAll(s.io, s.gpa, s.autos, s.o.trust);
    errdefer res.deinit();
    if (s.o.on_problem) |f| for (res.items) |it| if (it.problem) |p| {
        if (s.loaded) |*old| if (old.find(it.name)) |prev| if (std.mem.eql(u8, &prev.hash, &it.hash)) continue;
        f(s.o.on_problem_ctx, it.file, p.line, p.column, p.message);
    };
    const list = try res.automations();
    try s.scheduler.setAutomations(list);
    try s.triggers.setAutomations(list);
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    if (s.loaded) |*old| old.deinit();
    s.loaded = res;
}

/// A read-only tool source over this workspace (the manager UI's rows).
pub fn source(s: *Service) tools.Source {
    return .{
        .gpa = s.gpa,
        .io = s.io,
        .dir = s.autos,
        .history_dir = s.hist,
        .scheduler = s.scheduler,
        .trust = s.o.trust,
        .zone = s.runner.zone,
        .workspace_key = s.key,
    };
}

/// For the agent host's IPC server.
pub fn port(s: *Service) runs.ipc.AutomationsPort {
    return .{ .ctx = s, .run = runFn, .reload = reloadFn };
}

fn runFn(ctx: *anyopaque, name: []const u8) anyerror!u64 {
    const s: *Service = @ptrCast(@alignCast(ctx));
    return s.scheduler.fireNow(name);
}

fn reloadFn(ctx: *anyopaque) anyerror!void {
    const s: *Service = @ptrCast(@alignCast(ctx));
    return s.reload();
}

test "service loads, fires and reloads" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const reg = try runs.RunRegistry.init(testing.allocator, io, null, .{});
    defer reg.deinit();
    const Starter = struct {
        fn start(ctx: *anyopaque, spec: runs.RunSpec) anyerror!runs.RunId {
            const r: *runs.RunRegistry = @ptrCast(@alignCast(ctx));
            return r.create(spec);
        }
        fn stop(_: *anyopaque, _: runs.RunId) void {}
    };
    const s = try Service.init(testing.allocator, io, tmp.dir, reg, .{ .ctx = reg, .start = Starter.start, .stop = Starter.stop }, zone_mod.utcZone(), .{});
    defer s.deinit();
    try testing.expectError(error.UnknownAutomation, s.port().run(s, "x"));
    try tmp.dir.writeFile(io, .{ .sub_path = ".zigguro/automations/x.zon", .data = ".{ .name = \"x\", .triggers = .{.{ .schedule = .{ .cron = \"0 0 1 1 *\" } }}, .action = .{ .agent = .{ .prompt = \"hello\" } }, .budgets = .{ .max_cost_micro_usd = 1 } }" });
    try s.port().reload(s);
    try testing.expectEqual(@as(u64, 1), try s.port().run(s, "x"));
    const v = reg.snapshot();
    defer reg.release(v);
    try testing.expectEqual(@as(usize, 1), v.runs.len);
    try testing.expectEqualStrings("hello", v.runs[0].spec.prompt);
    try testing.expectEqualStrings("x", v.runs[0].spec.origin.automation.name);
}
