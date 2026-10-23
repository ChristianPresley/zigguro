//! Mission Control in a headless zg_gui window over a run registry and a
//! scripted agent runtime.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const mc_mod = @import("mission_control.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestApp = zg_gui.testing.TestApp;
const runs = zg_agents.runs;
const RunId = runs.RunId;
const Fake = runs.fake_agents.Fake;

const Recorder = struct {
    attached: ?RunId = null,
    outputs: ?RunId = null,

    fn attach(ctx: *anyopaque, id: RunId) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.attached = id;
    }

    fn output(ctx: *anyopaque, id: RunId) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.outputs = id;
    }
};

const Fx = struct {
    reg: *runs.RunRegistry,
    host: *runs.RunHost,
    fake: Fake = .{},
    mc: *mc_mod.MissionControl,
    t: *TestApp,
    rec: Recorder = .{},
    n: u128 = 0,

    fn init(f: *Fx) !void {
        f.* = .{ .reg = undefined, .host = undefined, .mc = undefined, .t = undefined };
        f.reg = try runs.RunRegistry.init(gpa, io, null, .{});
        f.host = try runs.RunHost.init(gpa, io, f.reg, f.fake.agentPort(), null, .builtin, .{});
        f.mc = try mc_mod.MissionControl.init(gpa, .{
            .reg = f.reg,
            .host = f.host,
            .attach = .{ .ctx = &f.rec, .f = Recorder.attach },
            .outputs = .{ .ctx = &f.rec, .f = Recorder.output },
        });
        f.t = try TestApp.init(gpa, .{ .root = .of(f.mc), .size = .{ .w = 720, .h = 1400 } });
        _ = f.t.settle();
    }

    fn deinit(f: *Fx) void {
        f.mc.detach();
        f.t.deinit();
        f.mc.deinit();
        f.host.deinit();
        f.reg.deinit();
        f.fake.deinit();
    }

    fn settle(f: *Fx) void {
        f.t.win.markAllDirty();
        _ = f.t.settle();
    }

    fn add(f: *Fx, title: []const u8, path: []const runs.RunStatus) !RunId {
        f.n += 1;
        const id = try f.reg.createWithId(.fromInt((@as(u128, 1_700_000_000_000) + f.n) << 80 | f.n), .{ .kind = .background, .title = title, .prompt = "p" });
        for (path) |s| try f.reg.update(id, .{ .status = s });
        return id;
    }

    fn focusList(f: *Fx) !void {
        const n = f.t.find(.{ .role = .list, .name = "Agent runs" }) orelse return error.NoList;
        f.t.win.setFocus(n, true);
        _ = f.t.settle();
    }

    fn waitStatus(f: *Fx, id: RunId, s: runs.RunStatus) !void {
        var i: u32 = 0;
        while (i < 2_000) : (i += 1) {
            {
                const v = f.reg.snapshot();
                defer f.reg.release(v);
                if (v.get(id).?.status == s) return;
            }
            io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        return error.Timeout;
    }
};

const working = [_]runs.RunStatus{ .starting, .working };

test "mission_control: 12 runs in every group, with screen-reader labels" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.add("queued one", &.{});
    _ = try f.add("queued two", &.{});
    const paused = try f.add("paused", &.{ .starting, .working, .paused });
    _ = paused;
    _ = try f.add("build", &working);
    _ = try f.add("lint", &working);
    const ask = try f.add("deploy", &working);
    try f.reg.update(ask, .{ .question = "Push to prod?" });
    try f.reg.update(ask, .{ .status = .needs_input });
    _ = try f.add("done one", &.{ .starting, .working, .completed });
    _ = try f.add("done two", &.{ .starting, .working, .completed });
    _ = try f.add("broken", &.{ .starting, .failed });
    _ = try f.add("halted", &.{ .starting, .stopped });
    const pin = try f.add("watch me", &working);
    try f.reg.update(pin, .{ .pinned = true });
    const costly = try f.add("costly", &working);
    try f.reg.update(costly, .{ .cost = .{ .micros = 1_250_000 } });
    f.settle();

    const sem = try f.t.semanticsSnapshot(gpa);
    defer gpa.free(sem);
    const groups = [_][]const u8{
        "group \"Pinned (1)\"",
        "group \"Needs input (1)\"",
        "group \"Working (3)\"",
        "group \"Queued and paused (3)\"",
        "group \"Done (4)\"",
    };
    var at: usize = 0;
    for (groups) |g| {
        const i = std.mem.indexOfPos(u8, sem, at, g) orelse {
            std.debug.print("missing {s} after {d} in\n{s}\n", .{ g, at, sem });
            return error.TestUnexpectedResult;
        };
        at = i;
    }
    try testing.expect(std.mem.indexOf(u8, sem, "list \"Agent runs\" rows=12") != null);
    // "title, status, age, cost".
    try testing.expect(std.mem.indexOf(u8, sem, "listitem \"costly, working, now, $1.25\"") != null);
    try testing.expect(std.mem.indexOf(u8, sem, "listitem \"deploy, needs input, now, $0.00\"") != null);
    try testing.expect(std.mem.indexOf(u8, sem, "status \"5 running, 1 need input, today $1.25\"") != null);
    try testing.expect(f.t.find(.{ .name_contains = "Push to prod?" }) != null);
    try testing.expectEqual(@as(usize, 12), f.t.count(.{ .role = .listitem }));

    // A filter narrows the list.
    try f.t.click(.{ .role = .textbox, .name = "Filter runs" });
    f.t.typeText("s:done");
    f.settle();
    try testing.expectEqual(@as(usize, 4), f.t.count(.{ .role = .listitem }));
}

test "mission_control: dispatch, peek, reply and the double-press stop" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.t.click(.{ .role = .textbox, .name = "Dispatch a run" });
    f.t.typeText("@coder summarise the logs");
    f.t.press(.enter, .{});
    f.settle();
    const id = f.mc.cursor orelse return error.NoCursor;
    try f.waitStatus(id, .working);
    {
        const v = f.reg.snapshot();
        defer f.reg.release(v);
        const r = v.get(id).?;
        try testing.expectEqualStrings("summarise the logs", r.spec.prompt);
        try testing.expectEqualStrings("coder", r.spec.agent_def.?);
    }
    f.settle();
    try testing.expectEqualStrings("", f.mc.dispatch_field.slice());
    try f.focusList();

    // Space peeks; a reply goes to the run.
    f.t.press(.space, .{});
    f.settle();
    try testing.expect(f.t.find(.{ .test_id = "mission-peek" }) != null);
    try f.t.click(.{ .role = .textbox, .name = "Reply to run" });
    f.t.typeText("! zig build");
    f.t.press(.enter, .{});
    f.settle();
    const agent = f.fake.agents.items[0];
    const last = agent.submits.items[agent.submits.items.len - 1];
    try testing.expect(std.mem.indexOf(u8, last, "```sh\nzig build\n```") != null);

    // Enter attaches; O shows outputs.
    try f.focusList();
    f.t.press(.enter, .{});
    try testing.expect(f.rec.attached.?.eql(id));
    f.t.press(.key_o, .{});
    try testing.expect(f.rec.outputs.?.eql(id));

    // Ctrl+X once only warns; twice stops.
    f.t.press(.key_x, .{ .ctrl = true });
    f.settle();
    try testing.expect(f.t.find(.{ .name_contains = "Press Ctrl+X again" }) != null);
    try testing.expectEqual(runs.RunStatus.working, f.mc.vm.get(id).?.status);
    f.t.press(.key_x, .{ .ctrl = true });
    try f.waitStatus(id, .stopped);
    f.settle();

    // Ctrl+T pins, Ctrl+R renames, Delete removes the stopped run.
    f.t.press(.key_t, .{ .ctrl = true });
    f.settle();
    try testing.expect(f.mc.vm.get(id).?.pinned);
    f.t.press(.key_r, .{ .ctrl = true });
    f.settle();
    try f.t.click(.{ .role = .textbox, .name = "Rename run" });
    f.t.press(.key_a, .{ .ctrl = true });
    f.t.typeText("log summary");
    f.t.press(.enter, .{});
    f.settle();
    try testing.expectEqualStrings("log summary", f.mc.vm.get(id).?.title);
    try f.focusList();
    f.t.press(.delete, .{});
    f.settle();
    try testing.expect(f.mc.vm.get(id) == null);
    try testing.expect(f.t.find(.{ .name_contains = "No agent runs yet" }) != null);
}

test "mission_control: ages tick once a second" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.add("build", &working);
    f.settle();
    try testing.expect(f.mc.timer != .none);
    const before = f.mc.vm.stats.flattened;
    f.t.advance(1_000);
    // The timer redraws the view without rebuilding the rows.
    try testing.expect(f.mc.timer != .none);
    try testing.expectEqual(before, f.mc.vm.stats.flattened);
}

test "fmtAge" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("now", mc_mod.fmtAge(&buf, 1_200));
    try testing.expectEqualStrings("42s", mc_mod.fmtAge(&buf, 42_000));
    try testing.expectEqualStrings("5m", mc_mod.fmtAge(&buf, 5 * 60_000 + 10));
    try testing.expectEqualStrings("3h", mc_mod.fmtAge(&buf, 3 * 3_600_000));
    try testing.expectEqualStrings("2d", mc_mod.fmtAge(&buf, 2 * 86_400_000));
}
