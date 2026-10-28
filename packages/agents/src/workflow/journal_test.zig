const std = @import("std");
const JournalStore = @import("journal.zig");
const run = @import("../runs/run.zig");

const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;

fn child(n: u8) run.RunId {
    var id: run.RunId = .zero;
    id.bytes[15] = n;
    return id;
}

test "journal_roundtrip_and_tail_repair" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const k1 = JournalStore.replayKey("plan", null, "Plan it", &.{}, null, null, null);
    const k2 = JournalStore.replayKey("research", 0, "Q1", &.{"web_search"}, "m", "{}", 7);
    {
        const j = try JournalStore.create(gpa, io, tmp.dir);
        defer j.deinit();
        try j.recordStart(0, "plan", k1, child(1));
        var obj: std.json.ObjectMap = .empty;
        defer obj.deinit(gpa);
        try obj.put(gpa, "subquestions", .{ .integer = 3 });
        try j.recordResult(0, .{ .ok = .{ .object = obj } });
        try j.recordStart(1, "research#0", k2, child(2));
        try j.recordResult(1, .{ .failed = "boom" });
        try j.recordStart(2, "plan@1", k1, child(3));
    }
    // A writer died mid-line.
    {
        const f = try tmp.dir.openFile(io, JournalStore.file_name, .{ .mode = .read_write });
        defer f.close(io);
        const n = try f.length(io);
        try f.writePositionalAll(io, "{\"v\":1,\"seq\":2,\"t\":\"resu", n);
    }
    const j = try JournalStore.open(gpa, io, tmp.dir);
    defer j.deinit();
    try testing.expectEqual(@as(u32, 1), j.repaired);
    try testing.expectEqual(@as(u32, 3), j.len());
    const e0 = j.get(0).?;
    try testing.expect(std.mem.eql(u8, &e0.key, &k1));
    try testing.expect(e0.child.eql(child(1)));
    try testing.expectEqual(@as(i64, 3), e0.outcome.?.ok.object.get("subquestions").?.integer);
    try testing.expectEqualStrings("boom", j.get(1).?.outcome.?.failed);
    try testing.expect(j.get(2).?.outcome == null);
    try testing.expectEqualStrings("research#0", j.get(1).?.pos);
    try testing.expectEqual(@as(u32, 1), j.atPos("research#0").?.seq);
    // The file was cut back to whole lines and appends continue cleanly.
    try j.recordResult(2, .stopped);
    const again = try JournalStore.load(gpa, io, tmp.dir);
    defer again.deinit();
    try testing.expectEqual(@as(u32, 0), again.repaired);
    try testing.expect(again.get(2).?.outcome.? == .stopped);
}

test "replay_key_covers_every_input" {
    const base = JournalStore.replayKey("s", 1, "p", &.{ "a", "b" }, "m", "{}", 1);
    const variants = [_]JournalStore.ReplayKey{
        JournalStore.replayKey("t", 1, "p", &.{ "a", "b" }, "m", "{}", 1),
        JournalStore.replayKey("s", 2, "p", &.{ "a", "b" }, "m", "{}", 1),
        JournalStore.replayKey("s", null, "p", &.{ "a", "b" }, "m", "{}", 1),
        JournalStore.replayKey("s", 1, "q", &.{ "a", "b" }, "m", "{}", 1),
        JournalStore.replayKey("s", 1, "p", &.{"ab"}, "m", "{}", 1),
        JournalStore.replayKey("s", 1, "p", &.{ "a", "b" }, null, "{}", 1),
        JournalStore.replayKey("s", 1, "p", &.{ "a", "b" }, "m", null, 1),
        JournalStore.replayKey("s", 1, "p", &.{ "a", "b" }, "m", "{}", 2),
        JournalStore.replayKey("s", 1, "p", &.{ "a", "b" }, "m", "{}", null),
    };
    for (variants) |v| try testing.expect(!std.mem.eql(u8, &base, &v));
    try testing.expect(std.mem.eql(u8, &base, &JournalStore.replayKey("s", 1, "p", &.{ "a", "b" }, "m", "{}", 1)));
}

test "journal_append_fast" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const j = try JournalStore.create(gpa, io, tmp.dir);
    defer j.deinit();
    const k = JournalStore.replayKey("s", 0, "p", &.{}, null, null, null);
    const t0 = std.Io.Clock.awake.now(io);
    for (0..1000) |i| try j.recordStart(@intCast(i), "map#1", k, child(1));
    const ns = t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    // Budget 20 us per append; Debug gets slack.
    try testing.expect(@divTrunc(ns, 1000) < 200 * std.time.ns_per_us);
}
