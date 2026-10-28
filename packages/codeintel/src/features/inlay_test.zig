//! Inlay hints against the scripted fake server (inlay.script), and the
//! coverage set and display modes.

const std = @import("std");
const zg_editor = @import("zg_editor");
const Harness = @import("../Manager_test.zig").Harness;
const InlayService = @import("inlay.zig");

const testing = std.testing;
const gpa = testing.allocator;
const DocHandle = zg_editor.model.api.registry.DocHandle;

fn running(h: *Harness) bool {
    for (h.mgr.serverList()) |s| if (s.status == .running and s.sync != null and s.docs.items.len > 0 and s.sync.?.isTracked(s.docs.items[s.docs.items.len - 1])) return true;
    return false;
}

/// 40 lines of 19 bytes.
fn text() []const u8 {
    return "const a = f(1, 2);\n" ** 40;
}

const Fx = struct {
    h: Harness,
    d: DocHandle,
    s: InlayService,
    now: u64 = 0,

    fn init(f: *Fx) !void {
        return f.initWith("inlay.script");
    }

    fn initWith(f: *Fx, script: []const u8) !void {
        try f.h.init(script, &.{});
        f.d = try f.h.open("main.zig", text());
        try f.s.init(&f.h.mgr, .noop, .{});
        f.now = 0;
        for (0..2000) |_| {
            f.h.mgr.tick();
            if (running(&f.h)) return;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }

    fn deinit(f: *Fx) void {
        f.h.mgr.closeDoc(f.d);
        f.h.docs.release(f.d);
        f.h.mgr.deinit();
        f.s.deinit();
        f.h.docs.deinit();
        f.h.reg.deinit();
        gpa.free(f.h.script);
        f.h.tmp.cleanup();
        _ = f.h.rt.deinit();
    }

    /// Ticks (the clock moving 50 ms a step) until `pred`.
    fn until(f: *Fx, comptime pred: fn (*Fx) bool) !void {
        for (0..2000) |_| {
            f.h.mgr.tick();
            _ = f.s.tick(f.now);
            if (pred(f)) return;
            f.now += 50;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }

    /// A few rounds of ticks.
    fn settle(f: *Fx) !void {
        for (0..10) |_| {
            f.h.mgr.tick();
            _ = f.s.tick(f.now);
            f.now += 50;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
    }
};

fn firstAnswer(f: *Fx) bool {
    return f.s.sent >= 1 and f.s.inflight == null and f.s.hints(f.d).len == 2;
}

fn secondAnswer(f: *Fx) bool {
    return f.s.sent >= 2 and f.s.inflight == null;
}

fn resolved(f: *Fx) bool {
    const hs = f.s.hints(f.d);
    return hs.len >= 2 and hs[1].tooltip != null;
}

fn refreshed(f: *Fx) bool {
    return f.s.hints(f.d).len == 3;
}

test "inlay: viewport coverage cache avoids re-request while scrolling; label parts with location navigate; resolve on hover; refresh re-requests visible only" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();

    // Lines 0..10 shown: 0..20 asked, after the debounce.
    try f.s.onViewport(f.d, .{ .first = 0, .end = 10 }, f.now);
    try testing.expectEqual(@as(?u64, f.now + 100), f.s.nextDue());
    try f.until(firstAnswer);
    const hs = f.s.hints(f.d);
    try testing.expectEqual(@as(u64, 19 + 5), hs[0].offset);
    try testing.expectEqualStrings(": i32", hs[0].label);
    try testing.expect(hs[0].pad_left);
    try testing.expectEqual(@as(u64, 2 * 19 + 10), hs[1].offset);
    try testing.expectEqualStrings("x:", hs[1].label);
    try testing.expectEqual(@as(usize, 2), hs[1].parts.len);
    try testing.expect(f.s.hintAt(f.d, 24) != null);
    try testing.expect(f.s.hintAt(f.d, 25) == null);

    // The second part goes to its location; the first nowhere.
    try testing.expect(f.s.partLocation(f.d, hs[1].id, 0) == null);
    const loc = f.s.partLocation(f.d, hs[1].id, 1).?;
    try testing.expectEqual(@as(u32, 3), loc.range.start.character);
    try testing.expect(std.mem.endsWith(u8, loc.uri, "/main.zig"));

    // Scrolling inside what is covered asks nothing.
    for (0..5) |i| try f.s.onViewport(f.d, .{ .first = 2 + i, .end = 12 + i }, f.now);
    try testing.expectEqual(@as(?u64, null), f.s.nextDue());
    try f.settle();
    try testing.expectEqual(@as(u32, 1), f.s.sent);

    // Far away: the uncovered lines are asked.
    try f.s.onViewport(f.d, .{ .first = 30, .end = 40 }, f.now);
    try f.until(secondAnswer);
    try testing.expectEqual(@as(u32, 2), f.s.sent);
    try testing.expectEqual(@as(usize, 2), f.s.hints(f.d).len);

    // Hovering the parameter hint resolves it.
    const id = f.s.hints(f.d)[1].id;
    try testing.expect(f.s.hints(f.d)[1].tooltip == null);
    try f.s.resolve(f.d, id);
    try f.until(resolved);
    try testing.expectEqualStrings("parameter x", f.s.hints(f.d)[1].tooltip.?);
    // Asked once.
    try f.s.resolve(f.d, id);

    // The server's refresh: the visible lines (20..40) are asked again;
    // the hints above stay.
    try f.until(refreshed);
    try testing.expectEqual(@as(u32, 3), f.s.sent);
    const after = f.s.hints(f.d);
    try testing.expectEqual(@as(u64, 24), after[0].offset);
    try testing.expectEqual(@as(u64, 35 * 19 + 2), after[2].offset);
    try testing.expect(after[2].pad_right);
}

test "inlay: hints follow edits; an edited anchor drops its hint" {
    var f: Fx = undefined;
    try f.initWith("inlay_edit.script");
    defer f.deinit();
    try f.s.onViewport(f.d, .{ .first = 0, .end = 10 }, f.now);
    try f.until(firstAnswer);
    const doc = f.h.docs.get(f.d).?;
    const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
    // Insert at the start (both move), then delete around the second.
    var cs = try ChangeSet.fromEdits(gpa, doc.len(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "//\n" }});
    defer cs.deinit();
    try doc.applyChangeSet(&cs, .{ .user = 0 });
    f.h.mgr.flush();
    var hs = f.s.hints(f.d);
    try testing.expectEqual(@as(usize, 2), hs.len);
    try testing.expectEqual(@as(u64, 27), hs[0].offset);
    try testing.expectEqual(@as(u64, 51), hs[1].offset);
    var cs2 = try ChangeSet.fromEdits(gpa, doc.len(), &.{.{ .range = .{ .start = 49, .end = 53 }, .text = "" }});
    defer cs2.deinit();
    try doc.applyChangeSet(&cs2, .{ .user = 0 });
    f.h.mgr.flush();
    hs = f.s.hints(f.d);
    try testing.expectEqual(@as(usize, 1), hs.len);
    // Nothing is covered at the new version: the visible lines are asked
    // again (and answer none).
    try testing.expect(f.s.nextDue() != null);
    try f.until(secondAnswer);
    try testing.expectEqual(@as(usize, 0), f.s.hints(f.d).len);
}

test "inlay: mode toggle onUnlessPressed" {
    var s: InlayService = undefined;
    s.opts = .{ .mode = .on_unless_pressed };
    s.pressed = false;
    s.generation = 0;
    try testing.expect(s.shown());
    s.setPressed(true);
    try testing.expect(!s.shown());
    try testing.expectEqual(@as(u64, 1), s.generation);
    s.setPressed(false);
    try testing.expect(s.shown());
    s.setMode(.off_unless_pressed);
    try testing.expect(!s.shown());
    s.setPressed(true);
    try testing.expect(s.shown());
    s.setMode(.off);
    try testing.expect(!s.shown());
    s.setMode(.on);
    try testing.expect(s.shown());
}

test "inlay: covered lines merge" {
    var set: std.ArrayList(InlayService.LineRange) = .empty;
    defer set.deinit(gpa);
    try InlayService.addCovered(gpa, &set, .{ .first = 20, .end = 30 });
    try InlayService.addCovered(gpa, &set, .{ .first = 0, .end = 10 });
    try testing.expectEqual(@as(usize, 2), set.items.len);
    try testing.expectEqual(@as(u64, 0), set.items[0].first);
    try InlayService.addCovered(gpa, &set, .{ .first = 10, .end = 20 });
    try testing.expectEqual(@as(usize, 1), set.items.len);
    try testing.expectEqual(@as(u64, 30), set.items[0].end);
}
