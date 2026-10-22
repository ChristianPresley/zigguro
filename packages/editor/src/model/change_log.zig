//! The per-document change log: the ChangeSet that produced each recent
//! version, used to map positions and ranges computed against an older
//! version (diagnostics, agent edits, anchors) onto the current one.
//! Bounded by version count and bytes; evicted versions map to null and
//! callers recompute.

const std = @import("std");
const cs_mod = @import("edit/change_set.zig");

const Allocator = std.mem.Allocator;
const ChangeSet = cs_mod.ChangeSet;

/// Version `version` was produced from `version - 1` by `changes`.
pub const Entry = struct { version: u64, changes: ChangeSet };

/// A bounded log of recent ChangeSets.
pub const ChangeLog = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    capacity_versions: u32 = 4096,
    max_bytes: usize = 8 << 20,
    /// The oldest version positions can be mapped from.
    oldest: u64 = 0,

    /// An empty log starting at `version`.
    pub fn init(gpa: Allocator, version: u64) ChangeLog {
        return .{ .gpa = gpa, .oldest = version };
    }

    /// Frees every entry.
    pub fn deinit(cl: *ChangeLog) void {
        for (cl.entries.items) |*e| e.changes.deinit();
        cl.entries.deinit(cl.gpa);
    }

    /// Records the ChangeSet (owned by the log from now on) that produced
    /// `version`, evicting the oldest entries over the limits.
    pub fn push(cl: *ChangeLog, version: u64, changes: ChangeSet) Allocator.Error!void {
        var c = changes;
        errdefer c.deinit();
        std.debug.assert(cl.entries.items.len == 0 or cl.entries.items[cl.entries.items.len - 1].version + 1 == version);
        try cl.entries.append(cl.gpa, .{ .version = version, .changes = c });
        cl.bytes += c.memoryBytes();
        if (cl.entries.items.len > cl.capacity_versions or cl.bytes > cl.max_bytes) cl.evict();
    }

    /// A version bump with no text change (summary refresh) still needs
    /// an entry so version arithmetic stays contiguous.
    pub fn pushIdentity(cl: *ChangeLog, version: u64, len: u64) Allocator.Error!void {
        return cl.push(version, ChangeSet.identity(cl.gpa, len));
    }

    fn evict(cl: *ChangeLog) void {
        // Drop an eighth (at least enough to meet the limits) at once so
        // eviction is amortised O(1).
        var drop: usize = @max(cl.entries.items.len / 8, 1);
        while (true) {
            var bytes = cl.bytes;
            for (cl.entries.items[0..drop]) |*e| bytes -= e.changes.memoryBytes();
            if ((cl.entries.items.len - drop <= cl.capacity_versions and bytes <= cl.max_bytes) or drop == cl.entries.items.len) break;
            drop = @min(drop * 2, cl.entries.items.len);
        }
        for (cl.entries.items[0..drop]) |*e| {
            cl.bytes -= e.changes.memoryBytes();
            e.changes.deinit();
        }
        cl.oldest = cl.entries.items[drop - 1].version;
        const rest = cl.entries.items.len - drop;
        std.mem.copyForwards(Entry, cl.entries.items[0..rest], cl.entries.items[drop..]);
        cl.entries.shrinkRetainingCapacity(rest);
    }

    /// Entries that turn `from` into the newest version, or null when
    /// `from` was evicted (or is newer than the log).
    pub fn since(cl: *const ChangeLog, from: u64) ?[]const Entry {
        if (from < cl.oldest) return null;
        const newest = cl.oldest + cl.entries.items.len;
        if (from > newest) return null;
        return cl.entries.items[@intCast(from - cl.oldest)..];
    }

    /// Maps `pos` from version `from` to the newest version; `deleted`
    /// when it fell strictly inside replaced text on the way.
    pub fn mapPos(cl: *const ChangeLog, from: u64, pos: u64, bias: cs_mod.Bias) ?struct { pos: u64, deleted: bool } {
        const es = cl.since(from) orelse return null;
        var p = pos;
        var deleted = false;
        for (es) |*e| {
            const m = e.changes.mapPosDetail(p, bias);
            p = m.pos;
            deleted = deleted or m.deleted;
        }
        return .{ .pos = p, .deleted = deleted };
    }

    /// One ChangeSet from version `from` to `to` (both within the log).
    pub fn compose(cl: *const ChangeLog, from: u64, to: u64, gpa: Allocator) Allocator.Error!?ChangeSet {
        const es = cl.since(from) orelse return null;
        if (to < from or to - from > es.len) return null;
        if (to == from) {
            const len = if (es.len > 0) es[0].changes.base_len else return null;
            return ChangeSet.identity(gpa, len);
        }
        var acc = try es[0].changes.clone(gpa);
        errdefer acc.deinit();
        for (es[1..@intCast(to - from)]) |*e| {
            const next = try acc.compose(&e.changes, gpa);
            acc.deinit();
            acc = next;
        }
        return acc;
    }
};

test "change_log: eviction returns null" {
    const gpa = std.testing.allocator;
    var cl: ChangeLog = .init(gpa, 0);
    defer cl.deinit();
    cl.capacity_versions = 8;
    var len: u64 = 0;
    for (1..20) |v| {
        const cs = try ChangeSet.fromEdits(gpa, len, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "ab" }});
        len += 2;
        try cl.push(v, cs);
    }
    try std.testing.expect(cl.entries.items.len <= 8);
    try std.testing.expect(cl.mapPos(0, 0, .left) == null);
    const m = cl.mapPos(18, 0, .right).?;
    try std.testing.expectEqual(@as(u64, 2), m.pos);
    var c = (try cl.compose(15, 19, gpa)).?;
    defer c.deinit();
    try std.testing.expectEqual(@as(u64, 8), c.insertedBytes());
}
