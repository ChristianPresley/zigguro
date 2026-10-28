//! Linked editing against the scripted fake server (linked_editing.script).

const std = @import("std");
const zg_editor = @import("zg_editor");
const Harness = @import("../Manager_test.zig").Harness;
const LinkedEditingService = @import("linked_editing.zig");

const testing = std.testing;
const gpa = testing.allocator;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
const Replace = zg_editor.model.edit.change_set.Replace;

fn running(h: *Harness) bool {
    for (h.mgr.serverList()) |s| if (s.status == .running and s.sync != null and s.docs.items.len > 0 and s.sync.?.isTracked(s.docs.items[s.docs.items.len - 1])) return true;
    return false;
}

const Fx = struct {
    h: Harness,
    d: DocHandle,
    s: LinkedEditingService,
    now: u64 = 0,
    asked: u32 = 0,

    fn init(f: *Fx) !void {
        try f.h.init("linked_editing.script", &.{});
        f.d = try f.h.open("page.zig", "<div>hi</div>\n");
        f.s = .init(&f.h.mgr, .noop, .{ .enabled = true });
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

    /// Ticks until the request for the caret is answered.
    fn answered(f: *Fx) !void {
        const n = f.s.req.sent;
        for (0..2000) |_| {
            f.h.mgr.tick();
            _ = f.s.tick(f.now);
            if (f.s.req.sent > n and f.s.asked == null) return;
            f.now += 50;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }

    /// One undo step of `edits` (the editor's multi-cursor typing).
    fn edit(f: *Fx, edits: []const Replace) !void {
        const doc = f.h.docs.get(f.d).?;
        var cs = try ChangeSet.fromEdits(gpa, doc.len(), edits);
        defer cs.deinit();
        try doc.applyChangeSet(&cs, .{ .user = 0 });
        f.h.mgr.flush();
    }
};

test "linked: mirrors open/close tag edits in one undo step; wordPattern violation ends mirroring; leaves session on cursor exit; null result is a no-op" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();

    // Off: nothing is asked.
    f.s.setEnabled(false);
    f.s.onCursor(f.d, 2, f.now);
    try testing.expectEqual(@as(?u64, null), f.s.nextDue());
    f.s.setEnabled(true);

    f.s.onCursor(f.d, 2, f.now);
    try testing.expectEqual(@as(?u64, f.now + 100), f.s.nextDue());
    try f.answered();
    var rs = f.s.active(f.d).?;
    try testing.expectEqual(@as(usize, 2), rs.len);
    try testing.expectEqual(@as(u64, 1), rs[0].start);
    try testing.expectEqual(@as(u64, 9), rs[1].start);
    try testing.expectEqual(@as(usize, 0), f.s.primary());

    // Typing at the end of both names (one step) grows both ranges.
    try f.edit(&.{ .{ .range = .{ .start = 4, .end = 4 }, .text = "x" }, .{ .range = .{ .start = 12, .end = 12 }, .text = "x" } });
    rs = f.s.active(f.d).?;
    try testing.expectEqual(@as(u64, 5), rs[0].end);
    try testing.expectEqual(@as(u64, 14), rs[1].end);
    // The caret in the closing tag makes it the primary.
    f.s.onCursor(f.d, 12, f.now);
    try testing.expectEqual(@as(usize, 1), f.s.primary());
    try testing.expectEqual(@as(?u64, null), f.s.nextDue());

    // A space is not part of a tag name: mirroring stops.
    const g = f.s.generation;
    try f.edit(&.{ .{ .range = .{ .start = 5, .end = 5 }, .text = " " }, .{ .range = .{ .start = 14, .end = 14 }, .text = " " } });
    try testing.expect(f.s.active(f.d) == null);
    try testing.expect(f.s.generation > g);

    // A new session, then the caret leaves it.
    f.s.onCursor(f.d, 2, f.now);
    try f.answered();
    rs = f.s.active(f.d).?;
    try testing.expectEqual(@as(u64, 11), rs[1].start);
    f.s.onCursor(f.d, 0, f.now);
    try testing.expect(f.s.active(f.d) == null);

    // Outside any tag the server answers null: no session.
    try f.answered();
    try testing.expect(f.s.active(f.d) == null);
}
