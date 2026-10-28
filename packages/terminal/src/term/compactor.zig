//! Background scrollback compaction for a terminal fed on one thread
//! (E06.F03.S02.T01): the feeding thread copies the due rows, a worker
//! encodes (and deflates) them, and the feeding thread swaps them into a
//! cold page afterwards. Only the copy and the swap run on the feeding
//! thread; a resize, reflow or ED 3 in between makes the swap drop the
//! stale result.
//!
//! The terminal must be created with `background_compaction`. After each
//! feed, the owner calls `poll`; when it returns true, it runs `work` on
//! another thread and, once `work` returns, makes the feeding thread
//! `poll` again.

const std = @import("std");
const Terminal = @import("Terminal.zig");
const PageList = @import("../screen/PageList.zig");

const Compactor = @This();

/// The job out, if any. Owned by the feeding thread until `poll` returns
/// true, then by the worker until `done`.
job: ?*PageList.CompactJob = null,
/// The worker finished the job.
done: std.atomic.Value(bool) = .init(false),

/// Feeding thread: finishes a job the worker completed and starts the next
/// one when compaction is due. True when a fresh job waits for `work`.
pub fn poll(c: *Compactor, t: *Terminal) bool {
    if (c.job) |job| {
        if (!c.done.load(.acquire)) return false;
        c.job = null;
        c.done.store(false, .release);
        // Out of memory only keeps the rows hot until the next try.
        t.finishCompaction(job) catch {};
    }
    if (!t.compactionDue()) return false;
    c.job = (t.beginCompaction() catch null) orelse return false;
    return true;
}

/// Worker: encodes the job `poll` started.
pub fn work(c: *Compactor) void {
    c.job.?.run();
    c.done.store(true, .release);
}

/// Whether a job is out (the worker may still be running it).
pub fn busy(c: *const Compactor) bool {
    return c.job != null;
}

/// Feeding thread, after the worker stopped: frees a job still out.
pub fn deinit(c: *Compactor, t: *Terminal) void {
    if (c.job) |job| t.cancelCompaction(job);
    c.* = .{};
}

test "background compaction matches inline compaction" {
    const gpa = std.testing.allocator;
    var a = try Terminal.init(gpa, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50 });
    defer a.deinit();
    var b = try Terminal.init(gpa, .{ .cols = 40, .rows = 5, .hot_scrollback_rows = 50, .background_compaction = true });
    defer b.deinit();
    var c: Compactor = .{};
    defer c.deinit(&b);
    var buf: [64]u8 = undefined;
    for (0..3000) |i| {
        const line = std.fmt.bufPrint(&buf, "line {d} \x1b[1mbold\x1b[0m\r\n", .{i}) catch unreachable;
        a.feed(line);
        b.feed(line);
        // The worker runs inline here.
        if (c.poll(&b)) c.work();
    }
    while (c.poll(&b)) c.work();
    try b.primary.pages.verify();
    try std.testing.expect(b.primary.pages.coldRows() > 2000);
    try std.testing.expectEqual(a.primary.pages.totalRows(), b.primary.pages.totalRows());
    try std.testing.expectEqual(a.primary.pages.coldRows(), b.primary.pages.coldRows());
}
