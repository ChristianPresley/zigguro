//! Automation history (E13.F02.S01.T02): every fire and skip appended to
//! `.zigguro/runs/automations/<name>.jsonl` as
//! `{"t":..,"due":..,"fire":..,"reason":"..","run":"<RunId>"|null,"skip":".."|null}`
//! for the manager UI and `zg automation history`.

const std = @import("std");
const runs = @import("../runs/root.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const FireReason = enum { scheduled, catch_up, once, manual, triggered };

pub const Skip = enum { overlap, rate_limited, disabled, asleep_discarded, budget_exhausted, lease_lost, chain_limit, already_claimed, failed };

pub const Record = struct {
    /// When it happened (unix ms).
    t: i64,
    /// The nominal due time (unix ms).
    due: i64,
    fire: u64 = 0,
    reason: FireReason,
    run: ?runs.RunId = null,
    skip: ?Skip = null,
};

pub fn fileName(buf: []u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.jsonl", .{name});
}

/// Appends one line; the directory is created when missing.
pub fn append(io: Io, dir: Io.Dir, name: []const u8, rec: Record) !void {
    var name_buf: [80]u8 = undefined;
    const path = try fileName(&name_buf, name);
    var line_buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&line_buf);
    try std.json.Stringify.value(rec, .{}, &w);
    try w.writeByte('\n');
    const f = try dir.createFile(io, path, .{ .truncate = false });
    defer f.close(io);
    const end = try f.length(io);
    try f.writePositionalAll(io, w.buffered(), end);
}

/// The last `max` records, oldest first, in `arena`. Missing file: none.
/// Malformed lines are skipped.
pub fn readTail(arena: Allocator, io: Io, dir: Io.Dir, name: []const u8, max: usize) ![]Record {
    var name_buf: [80]u8 = undefined;
    const path = try fileName(&name_buf, name);
    const bytes = dir.readFileAlloc(io, path, arena, .limited(64 << 20)) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    var out: std.ArrayList(Record) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const r = std.json.parseFromSliceLeaky(Record, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        try out.append(arena, r);
    }
    const items = out.items;
    return items[items.len -| max..];
}

test "history append and read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try readTail(arena.allocator(), io, tmp.dir, "x", 10)).len);
    try append(io, tmp.dir, "x", .{ .t = 10, .due = 5, .fire = 1, .reason = .scheduled, .run = .fromInt(42) });
    try append(io, tmp.dir, "x", .{ .t = 20, .due = 15, .reason = .scheduled, .skip = .overlap });
    try append(io, tmp.dir, "x", .{ .t = 30, .due = 25, .fire = 2, .reason = .catch_up });
    const all = try readTail(arena.allocator(), io, tmp.dir, "x", 10);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expect(all[0].run.?.eql(.fromInt(42)));
    try std.testing.expectEqual(Skip.overlap, all[1].skip.?);
    const last = try readTail(arena.allocator(), io, tmp.dir, "x", 1);
    try std.testing.expectEqual(FireReason.catch_up, last[0].reason);
}
