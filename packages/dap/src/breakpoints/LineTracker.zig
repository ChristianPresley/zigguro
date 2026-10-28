//! A `LineHost` that tracks lines through whole-line edits, for tests and
//! headless hosts (the app tracks them with E05 anchors).
//!
//! - `insertLines(path, before, n)`: lines from `before` on move down.
//! - `deleteLines(path, first, n)`: lines after the deleted ones move up;
//!   a tracked line inside them collapses onto `first` (the merged line),
//!   as VS Code keeps a breakpoint whose line was deleted.

const LineTracker = @This();
const std = @import("std");
const BreakpointManager = @import("BreakpointManager.zig");
const Allocator = std.mem.Allocator;

const Tracked = struct { path: []const u8, line: u32, live: bool = true };

gpa: Allocator,
open: std.StringArrayHashMapUnmanaged(bool) = .empty,
tracked: std.ArrayList(Tracked) = .empty,

pub fn init(gpa: Allocator) LineTracker {
    return .{ .gpa = gpa };
}

pub fn deinit(t: *LineTracker) void {
    for (t.open.keys()) |k| t.gpa.free(k);
    t.open.deinit(t.gpa);
    t.tracked.deinit(t.gpa);
}

pub fn host(t: *LineTracker) BreakpointManager.LineHost {
    return .{ .ctx = t, .track = track, .line = line, .untrack = untrack, .dirty = dirty };
}

/// Opens `path` (call the manager's `docOpened` after).
pub fn openDoc(t: *LineTracker, path: []const u8) Allocator.Error!void {
    if (t.open.contains(path)) return;
    try t.open.put(t.gpa, try t.gpa.dupe(u8, path), false);
}

/// Closes `path` (call the manager's `docClosed` before).
pub fn closeDoc(t: *LineTracker, path: []const u8) void {
    const kv = t.open.fetchSwapRemove(path) orelse return;
    t.gpa.free(kv.key);
}

pub fn setDirty(t: *LineTracker, path: []const u8, d: bool) void {
    if (t.open.getPtr(path)) |p| p.* = d;
}

pub fn insertLines(t: *LineTracker, path: []const u8, before: u32, n: u32) void {
    for (t.tracked.items) |*x| if (x.live and std.mem.eql(u8, x.path, path) and x.line >= before) {
        x.line += n;
    };
    t.setDirty(path, true);
}

pub fn deleteLines(t: *LineTracker, path: []const u8, first: u32, n: u32) void {
    for (t.tracked.items) |*x| if (x.live and std.mem.eql(u8, x.path, path)) {
        if (x.line >= first + n) x.line -= n else if (x.line >= first) x.line = first;
    };
    t.setDirty(path, true);
}

fn track(ctx: ?*anyopaque, path: []const u8, l: u32) ?u64 {
    const t: *LineTracker = @ptrCast(@alignCast(ctx.?));
    const key = t.open.getKey(path) orelse return null;
    t.tracked.append(t.gpa, .{ .path = key, .line = l }) catch return null;
    return t.tracked.items.len - 1;
}

fn line(ctx: ?*anyopaque, h: u64) ?u32 {
    const t: *LineTracker = @ptrCast(@alignCast(ctx.?));
    const x = t.tracked.items[@intCast(h)];
    if (!x.live or !t.open.contains(x.path)) return null;
    return x.line;
}

fn untrack(ctx: ?*anyopaque, h: u64) void {
    const t: *LineTracker = @ptrCast(@alignCast(ctx.?));
    t.tracked.items[@intCast(h)].live = false;
}

fn dirty(ctx: ?*anyopaque, path: []const u8) bool {
    const t: *LineTracker = @ptrCast(@alignCast(ctx.?));
    return t.open.get(path) orelse false;
}
