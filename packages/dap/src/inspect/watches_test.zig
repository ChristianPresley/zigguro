//! Watches against `fake_dap_adapter` (testdata/sessions/
//! watch_timeouts.txt): one batch per stop with per-watch timeouts; and
//! persistence of the watch list and the REPL history.

const std = @import("std");
const Inspector = @import("Inspector.zig");
const Watches = @import("Watches.zig");
const ReplHistory = @import("ReplHistory.zig");
const inspect_test = @import("inspect_test.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Fixture = inspect_test.Fixture;

fn addThree(i: *Inspector) void {
    i.watches.add("w1");
    i.watches.add("w2");
    i.watches.add("w3");
    // Not stopped yet: nothing is sent.
    std.debug.assert(i.ch.inflight() == 0);
}

test "watch: concurrent evaluation with timeouts" {
    var f: Fixture = undefined;
    try f.initWith("watch_timeouts.txt", .{ .watch_timeout = .fromMilliseconds(300) }, addThree);
    defer f.deinit();
    const r = f.insp.watches.results();
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqual(Watches.State.ok, r[0].state);
    try testing.expectEqualStrings("1", r[0].result.?.value);
    try testing.expectEqual(Watches.State.error_, r[1].state);
    try testing.expectEqualStrings("no such name", r[1].result.?.value);
    // Answered after 900 ms: too late.
    try testing.expectEqual(Watches.State.timed_out, r[2].state);
    // Running: not stopped.
    f.insp.watches.markNotStopped();
    try testing.expectEqual(Watches.State.not_stopped, f.insp.watches.results()[0].state);
    try f.finish();
}

test "watch: one batch for 20 expressions" {
    var i: Inspector = undefined;
    // A port that accepts everything and answers nothing.
    const Port = struct {
        var sent: u32 = 0;
        var cbs: [32]@import("../conn/DapConnection.zig").RawRespCb = undefined;
        fn send(_: ?*anyopaque, _: []const u8, _: []const u8, cb: @import("../conn/DapConnection.zig").RawRespCb) bool {
            cbs[sent] = cb;
            sent += 1;
            return true;
        }
        fn caps(_: ?*anyopaque) @import("../gen/protocol.zig").Capabilities {
            return .{};
        }
    };
    try i.init(gpa, testing.io, null, .{ .ctx = null, .send = Port.send, .caps = Port.caps }, .{});
    defer i.deinit();
    for (0..20) |k| {
        var buf: [8]u8 = undefined;
        i.watches.add(try std.fmt.bufPrint(&buf, "w{d}", .{k}));
    }
    try i.applyStop(.{ .gen = 2, .thread = 1, .stack = "{\"stackFrames\":[{\"id\":1,\"name\":\"main\",\"source\":{\"path\":\"/a.zig\"}}],\"totalFrames\":1}", .scopes = "{\"scopes\":[]}" });
    // All 20 at once, before any answer.
    try testing.expectEqual(@as(u32, 20), Port.sent);
    try testing.expectEqual(@as(usize, 20), i.watches.pendingCount());
    for (Port.cbs[0..Port.sent]) |cb| cb.func(cb.ctx, .closed);
    _ = i.pump();
    try testing.expectEqual(@as(usize, 0), i.watches.pendingCount());
}

test "watch: persistence roundtrip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var i: Inspector = undefined;
    try i.init(gpa, testing.io, null, .none, .{});
    defer i.deinit();
    i.watches.persist_to = .{ .dir = tmp.dir };
    i.watches.add("a + 1");
    i.watches.add("s.\"quoted\"");
    i.watches.edit(0, "a + 2");
    i.watches.add("gone");
    i.watches.remove(2);
    const text = try tmp.dir.readFileAlloc(testing.io, Watches.sub_path, gpa, .limited(1 << 16));
    defer gpa.free(text);
    var j: Inspector = undefined;
    try j.init(gpa, testing.io, null, .none, .{});
    defer j.deinit();
    try j.watches.load(text);
    const r = j.watches.results();
    try testing.expectEqual(@as(usize, 2), r.len);
    try testing.expectEqualStrings("a + 2", r[0].expr);
    try testing.expectEqualStrings("s.\"quoted\"", r[1].expr);
    try testing.expectEqual(Watches.State.not_stopped, r[0].state);
}

test "repl: history navigation and persistence" {
    var h: ReplHistory = .init(gpa);
    defer h.deinit();
    h.max = 3;
    h.push("p x");
    h.push("p x"); // collapsed
    h.push("`bt"); // lldb-dap command escape kept as is
    h.push("frame 1");
    h.push("p y"); // the oldest goes
    try testing.expectEqual(@as(usize, 3), h.lines.items.len);
    try testing.expectEqualStrings("p y", h.prev().?);
    try testing.expectEqualStrings("frame 1", h.prev().?);
    try testing.expectEqualStrings("`bt", h.prev().?);
    try testing.expectEqualStrings("`bt", h.prev().?); // stays at the oldest
    try testing.expectEqualStrings("frame 1", h.next().?);
    try testing.expectEqualStrings("p y", h.next().?);
    try testing.expect(h.next() == null); // back at the input line
    // Per adapter type in one file.
    const t1 = try h.encodeInto(gpa, null, "lldb-dap");
    defer gpa.free(t1);
    var other: ReplHistory = .init(gpa);
    defer other.deinit();
    other.push("print(x)");
    const t2 = try other.encodeInto(gpa, t1, "debugpy");
    defer gpa.free(t2);
    var back: ReplHistory = .init(gpa);
    defer back.deinit();
    try back.load(t2, "lldb-dap");
    try testing.expectEqual(@as(usize, 3), back.lines.items.len);
    try testing.expectEqualStrings("`bt", back.lines.items[0]);
    var back2: ReplHistory = .init(gpa);
    defer back2.deinit();
    try back2.load(t2, "debugpy");
    try testing.expectEqualStrings("print(x)", back2.lines.items[0]);
}
