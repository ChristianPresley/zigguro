//! Compound launches against `fake_dap_adapter` scripts
//! (testdata/sessions/): `stopAll`, independent members, partial failure
//! and the compound's pre-launch task.

const std = @import("std");
const DebugManager = @import("DebugManager.zig");
const DebugSession = @import("DebugSession.zig");
const ConfigSet = @import("../config/ConfigSet.zig");
const LaunchConfig = @import("../config/LaunchConfig.zig");
const test_harness = @import("test_harness.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Harness = test_harness.Harness;

const named: []const [2][]const u8 = &.{
    .{ "a", "member.txt" },
    .{ "b", "member.txt" },
    .{ "bad", "launch_failed.txt" },
};

/// Configurations a, b, bad (fails to launch) and off (disabled).
fn configSet(h: *Harness, compound: ConfigSet.Compound) !ConfigSet {
    const a = h.arena.allocator();
    const cfgs = try a.alloc(LaunchConfig, 4);
    cfgs[0] = try h.configNamed("a", .launch);
    cfgs[1] = try h.configNamed("b", .launch);
    cfgs[2] = try h.configNamed("bad", .launch);
    cfgs[3] = try h.configNamed("off", .launch);
    cfgs[3].enabled = false;
    cfgs[3].disabled_reason = "no adapter";
    const comps = try a.alloc(ConfigSet.Compound, 1);
    comps[0] = compound;
    return .{ .arena = .init(gpa), .configs = cfgs, .compounds = comps };
}

fn find(r: DebugManager.CompoundStart, name: []const u8) *DebugSession {
    for (r.sessions) |s| if (std.mem.eql(u8, s.cfg.name, name)) return s;
    unreachable;
}

fn running(_: *Harness, s: *DebugSession) bool {
    return s.state() == .running;
}

fn hasError(r: DebugManager.CompoundStart, needle: []const u8) bool {
    for (r.errors) |e| if (std.mem.indexOf(u8, e, needle) != null) return true;
    return false;
}

test "compounds: stopAll semantics; partial failure" {
    var h: Harness = undefined;
    try h.init(&.{"member.txt"}, .{ .named = named });
    defer h.deinit();
    var set = try configSet(&h, .{ .name = "all", .configurations = &.{ "a", "bad", "missing", "off", "b" }, .stop_all = true });
    defer set.arena.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = try h.m.startCompound(&set.compounds[0], &set, arena.allocator());
    // In order; missing and disabled ones are reported, the rest start.
    try testing.expectEqual(@as(usize, 3), r.sessions.len);
    try testing.expectEqualStrings("a", r.sessions[0].cfg.name);
    try testing.expectEqualStrings("bad", r.sessions[1].cfg.name);
    try testing.expectEqualStrings("b", r.sessions[2].cfg.name);
    try testing.expectEqual(@as(usize, 2), r.errors.len);
    try testing.expect(hasError(r, "there is no configuration \"missing\""));
    try testing.expect(hasError(r, "\"off\" is disabled: no adapter"));
    const sa = find(r, "a");
    const sb = find(r, "b");
    const bad = find(r, "bad");
    try h.waitFor(sa, running);
    try h.waitFor(sb, running);
    // A member that fails to launch leaves the others running.
    try h.waitFor(bad, Harness.ended);
    try testing.expectEqual(.failed, bad.state());
    try testing.expectEqual(.running, sa.state());
    try testing.expectEqual(@as(usize, 3), r.run.?.members.items.len);
    // Stopping one stops all.
    sb.stop();
    try h.waitFor(sa, Harness.ended);
    try h.waitFor(sb, Harness.ended);
    try h.expectScriptPassed(sa);
    try h.expectScriptPassed(sb);
}

test "compounds: without stopAll members are independent" {
    var h: Harness = undefined;
    try h.init(&.{"member.txt"}, .{ .named = named });
    defer h.deinit();
    var set = try configSet(&h, .{ .name = "pair", .configurations = &.{ "a", "b" } });
    defer set.arena.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = try h.m.startCompound(&set.compounds[0], &set, arena.allocator());
    try testing.expectEqual(@as(usize, 0), r.errors.len);
    const sa = find(r, "a");
    const sb = find(r, "b");
    try h.waitFor(sa, running);
    try h.waitFor(sb, running);
    sa.stop();
    try h.waitFor(sa, Harness.ended);
    try testing.expectEqual(.running, sb.state());
    sb.stop();
    try h.waitFor(sb, Harness.ended);
    try h.expectScriptPassed(sa);
    try h.expectScriptPassed(sb);
}

const FailingTasks = struct {
    fn host() DebugManager.TaskHost {
        return .{ .ctx = null, .run = run };
    }

    fn run(_: ?*anyopaque, _: []const u8, _: std.mem.Allocator) DebugManager.TaskOutcome {
        return .{ .failed = "exit code 1" };
    }
};

test "compounds: a failed preLaunchTask starts nothing" {
    var h: Harness = undefined;
    try h.init(&.{"member.txt"}, .{ .named = named, .tasks = FailingTasks.host() });
    defer h.deinit();
    var set = try configSet(&h, .{ .name = "pair", .configurations = &.{ "a", "b" }, .pre_launch_task = "build" });
    defer set.arena.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = try h.m.startCompound(&set.compounds[0], &set, arena.allocator());
    try testing.expectEqual(@as(usize, 0), r.sessions.len);
    try testing.expectEqualStrings("preLaunchTask \"build\" failed: exit code 1", r.errors[0]);
    try testing.expectEqual(@as(usize, 0), h.m.sessions().len);
}
