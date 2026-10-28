//! Replay semantics, one test per rule in docs/formats/workflow.md.

const std = @import("std");
const JournalStore = @import("journal.zig");
const Replayer = @import("replay.zig").Replayer;
const run = @import("../runs/run.zig");

const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;

fn key(name: []const u8) JournalStore.ReplayKey {
    return JournalStore.replayKey(name, null, name, &.{}, null, null, null);
}

const Rec = struct { name: []const u8, outcome: ?JournalStore.Outcome = .{ .ok = .{ .string = "r" } } };

/// A previous generation that started `recs` in order.
fn previous(recs: []const Rec) !*JournalStore {
    const j = try JournalStore.memory(gpa, io);
    for (recs, 0..) |r, i| {
        try j.recordStart(@intCast(i), key(r.name), run.RunId.zero);
        if (r.outcome) |o| try j.recordResult(@intCast(i), o);
    }
    return j;
}

/// Which of `names` (in start order) are reused.
fn reuse(prev: *JournalStore, names: []const []const u8) ![]bool {
    var r: Replayer = .init(prev);
    const out = try gpa.alloc(bool, names.len);
    for (names, 0..) |n, i| out[i] = r.lookup(@intCast(i), key(n)) != null;
    return out;
}

fn expectReuse(prev_recs: []const Rec, now: []const []const u8, want: []const bool) !void {
    const prev = try previous(prev_recs);
    defer prev.deinit();
    const got = try reuse(prev, now);
    defer gpa.free(got);
    try testing.expectEqualSlices(bool, want, got);
}

test "replay_reuses_until_first_change" {
    // map a, b, c then reduce; the reduce prompt was edited.
    try expectReuse(&.{ .{ .name = "a" }, .{ .name = "b" }, .{ .name = "c" }, .{ .name = "reduce" } }, &.{ "a", "b", "c", "reduce2" }, &.{ true, true, true, false });
}

test "edit_map_item_reruns_it_and_later_started" {
    try expectReuse(&.{ .{ .name = "a" }, .{ .name = "b" }, .{ .name = "c" }, .{ .name = "reduce" } }, &.{ "a", "b2", "c", "reduce" }, &.{ true, false, false, false });
}

test "failed_agent_reruns_and_later_started" {
    try expectReuse(&.{ .{ .name = "a" }, .{ .name = "b", .outcome = .{ .failed = "x" } }, .{ .name = "c" } }, &.{ "a", "b", "c" }, &.{ true, false, false });
    // A stopped agent and one still running when the workflow stopped
    // start over as well.
    try expectReuse(&.{ .{ .name = "a", .outcome = .stopped }, .{ .name = "b" } }, &.{ "a", "b" }, &.{ false, false });
    try expectReuse(&.{ .{ .name = "a" }, .{ .name = "b", .outcome = null } }, &.{ "a", "b" }, &.{ true, false });
}

test "reordered_starts_rerun_from_divergence" {
    try expectReuse(&.{ .{ .name = "a" }, .{ .name = "b" }, .{ .name = "c" }, .{ .name = "d" } }, &.{ "a", "c", "b", "d" }, &.{ true, false, false, false });
}

test "more_agents_than_before" {
    try expectReuse(&.{ .{ .name = "a" }, .{ .name = "b" } }, &.{ "a", "b", "c" }, &.{ true, true, false });
}

test "library_body_change_changes_key" {
    const k1 = JournalStore.replayKey("plan", null, "@research/lead", &.{}, null, null, 111);
    const k2 = JournalStore.replayKey("plan", null, "@research/lead", &.{}, null, null, 222);
    try testing.expect(!std.mem.eql(u8, &k1, &k2));
    const prev = try JournalStore.memory(gpa, io);
    defer prev.deinit();
    try prev.recordStart(0, k1, run.RunId.zero);
    try prev.recordResult(0, .{ .ok = .null });
    var r: Replayer = .init(prev);
    try testing.expect(r.lookup(0, k2) == null);
}

test "fresh_run_reuses_nothing" {
    var r: Replayer = .init(null);
    try testing.expect(r.lookup(0, key("a")) == null);
}

test "resume_200_cached_fast" {
    const prev = try JournalStore.memory(gpa, io);
    defer prev.deinit();
    var keys: [200]JournalStore.ReplayKey = undefined;
    for (&keys, 0..) |*k, i| {
        k.* = JournalStore.replayKey("map", @intCast(i), "same prompt", &.{"read_file"}, "m", null, null);
        try prev.recordStart(@intCast(i), k.*, run.RunId.zero);
        try prev.recordResult(@intCast(i), .{ .ok = .{ .integer = @intCast(i) } });
    }
    const t0 = std.Io.Clock.awake.now(io);
    var r: Replayer = .init(prev);
    for (keys, 0..) |k, i| {
        const kk = JournalStore.replayKey("map", @intCast(i), "same prompt", &.{"read_file"}, "m", null, null);
        try testing.expect(std.mem.eql(u8, &k, &kk));
        try testing.expectEqual(@as(i64, @intCast(i)), r.lookup(@intCast(i), kk).?.integer);
    }
    const ns = t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    try testing.expectEqual(@as(u32, 200), r.reused);
    try testing.expect(ns < 50 * std.time.ns_per_ms);
}
