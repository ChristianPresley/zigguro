//! Recently used workspaces, files and notes, ranked by frecency
//! (Firefox-style bucketed decay over the last 10 visits).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// What a recent entry refers to.
pub const RecentKind = enum(u8) { workspace, file, note };

/// Most entries kept per kind; the lowest-scoring is evicted.
pub const max_per_kind = 500;
/// Visits remembered per entry.
pub const max_visits = 10;

/// One remembered item.
pub const Entry = struct {
    /// Kind of item.
    kind: RecentKind,
    /// Its key (path or identity).
    key: []const u8,
    /// Visit times (Unix seconds), newest last.
    visits: []const i64,
    /// Frecency at the time of `ranked`.
    score: u32 = 0,
};

const Stored = struct { kind: RecentKind, key: []const u8, visits: []const i64 };

/// The recents table.
pub const Recents = struct {
    gpa: Allocator,
    items: std.ArrayList(Item) = .empty,

    const Item = struct { kind: RecentKind, key: []u8, visits: [max_visits]i64, n: u8 };

    /// An empty table.
    pub fn init(gpa: Allocator) Recents {
        return .{ .gpa = gpa };
    }

    /// Frees the table.
    pub fn deinit(r: *Recents) void {
        for (r.items.items) |it| r.gpa.free(it.key);
        r.items.deinit(r.gpa);
    }

    fn find(r: *const Recents, kind: RecentKind, key: []const u8) ?usize {
        for (r.items.items, 0..) |it, i| if (it.kind == kind and std.mem.eql(u8, it.key, key)) return i;
        return null;
    }

    /// Records a visit at `now_s`.
    pub fn touch(r: *Recents, kind: RecentKind, key: []const u8, now_s: i64) !void {
        if (r.find(kind, key)) |i| {
            const it = &r.items.items[i];
            if (it.n == max_visits) {
                std.mem.copyForwards(i64, it.visits[0 .. max_visits - 1], it.visits[1..]);
                it.n -= 1;
            }
            it.visits[it.n] = now_s;
            it.n += 1;
            return;
        }
        var same_kind: usize = 0;
        var worst: ?usize = null;
        var worst_score: u32 = std.math.maxInt(u32);
        for (r.items.items, 0..) |it, i| if (it.kind == kind) {
            same_kind += 1;
            const s = score(it.visits[0..it.n], now_s);
            if (s < worst_score) {
                worst_score = s;
                worst = i;
            }
        };
        if (same_kind >= max_per_kind) r.removeAt(worst.?);
        const owned = try r.gpa.dupe(u8, key);
        errdefer r.gpa.free(owned);
        var item: Item = .{ .kind = kind, .key = owned, .visits = undefined, .n = 1 };
        item.visits[0] = now_s;
        try r.items.append(r.gpa, item);
    }

    /// Forgets an entry.
    pub fn remove(r: *Recents, kind: RecentKind, key: []const u8) void {
        if (r.find(kind, key)) |i| r.removeAt(i);
    }

    fn removeAt(r: *Recents, i: usize) void {
        r.gpa.free(r.items.items[i].key);
        _ = r.items.orderedRemove(i);
    }

    /// Number of entries of `kind` (all kinds when null).
    pub fn count(r: *const Recents, kind: ?RecentKind) usize {
        var n: usize = 0;
        for (r.items.items) |it| if (kind == null or it.kind == kind.?) {
            n += 1;
        };
        return n;
    }

    /// Appends entries (all kinds, or one) to `out` in frecency order,
    /// highest first; ties go to the most recent visit. Entries borrow the
    /// table's memory until the next mutation.
    pub fn ranked(r: *const Recents, kind: ?RecentKind, now_s: i64, out: *std.ArrayList(Entry)) !void {
        const start = out.items.len;
        for (r.items.items) |*it| {
            if (kind != null and it.kind != kind.?) continue;
            try out.append(r.gpa, .{ .kind = it.kind, .key = it.key, .visits = it.visits[0..it.n], .score = score(it.visits[0..it.n], now_s) });
        }
        std.mem.sort(Entry, out.items[start..], {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                if (a.score != b.score) return a.score > b.score;
                return a.visits[a.visits.len - 1] > b.visits[b.visits.len - 1];
            }
        }.lt);
    }

    /// Loads a table saved by `save`.
    pub fn load(gpa: Allocator, bytes: []const u8) !Recents {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const z = try arena.allocator().dupeZ(u8, bytes);
        const stored = try std.zon.parse.fromSliceAlloc([]const Stored, arena.allocator(), z, null, .{ .ignore_unknown_fields = true });
        var r: Recents = .init(gpa);
        errdefer r.deinit();
        for (stored) |s| {
            if (s.visits.len == 0) continue;
            const v = s.visits[s.visits.len -| max_visits..];
            var item: Item = .{ .kind = s.kind, .key = try gpa.dupe(u8, s.key), .visits = undefined, .n = @intCast(v.len) };
            @memcpy(item.visits[0..v.len], v);
            r.items.append(gpa, item) catch |e| {
                gpa.free(item.key);
                return e;
            };
        }
        return r;
    }

    /// Writes the table as ZON.
    pub fn save(r: *const Recents, w: *std.Io.Writer) !void {
        try w.writeAll(".{\n");
        for (r.items.items) |it| {
            try w.print("    .{{ .kind = .{s}, .key = \"{f}\", .visits = .{{", .{ @tagName(it.kind), std.zig.fmtString(it.key) });
            for (it.visits[0..it.n], 0..) |v, i| try w.print("{s}{d}", .{ if (i == 0) " " else ", ", v });
            try w.writeAll(" } },\n");
        }
        try w.writeAll("}\n");
    }
};

/// Sum of per-visit weights by age: 100 (<= 4 days), 70 (<= 14), 50 (<= 31),
/// 30 (<= 90), else 10.
pub fn score(visits: []const i64, now_s: i64) u32 {
    var total: u32 = 0;
    for (visits) |v| {
        const days = @divFloor(@max(now_s - v, 0), std.time.s_per_day);
        total += if (days <= 4) 100 else if (days <= 14) 70 else if (days <= 31) 50 else if (days <= 90) 30 else 10;
    }
    return total;
}

test "recents: frecency ordering table test with fixed clock" {
    const day = std.time.s_per_day;
    const now: i64 = 1000 * day;
    var r: Recents = .init(std.testing.allocator);
    defer r.deinit();
    // a: one visit today (100). b: three visits 20 days ago (150).
    // c: 10 visits 100 days ago (100), older last visit than a.
    try r.touch(.file, "a", now);
    for (0..3) |_| try r.touch(.file, "b", now - 20 * day);
    for (0..12) |_| try r.touch(.file, "c", now - 100 * day);
    try r.touch(.workspace, "ws", now);
    var out: std.ArrayList(Entry) = .empty;
    defer out.deinit(std.testing.allocator);
    try r.ranked(.file, now, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("b", out.items[0].key);
    try std.testing.expectEqualStrings("a", out.items[1].key);
    try std.testing.expectEqualStrings("c", out.items[2].key);
    try std.testing.expectEqual(@as(usize, 10), out.items[2].visits.len);
    // Round trip through ZON.
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try r.save(&buf.writer);
    var back = try Recents.load(std.testing.allocator, buf.written());
    defer back.deinit();
    try std.testing.expectEqual(@as(usize, 4), back.count(null));
    r.remove(.file, "b");
    try std.testing.expectEqual(@as(usize, 2), r.count(.file));
}

test "recents: eviction at 500 entries" {
    const day = std.time.s_per_day;
    const now: i64 = 1000 * day;
    var r: Recents = .init(std.testing.allocator);
    defer r.deinit();
    try r.touch(.note, "old", now - 400 * day);
    var buf: [16]u8 = undefined;
    for (0..max_per_kind) |i| try r.touch(.note, try std.fmt.bufPrint(&buf, "n{d}", .{i}), now);
    try std.testing.expectEqual(@as(usize, max_per_kind), r.count(.note));
    try std.testing.expect(r.find(.note, "old") == null);
    try r.touch(.file, "f", now);
    try std.testing.expectEqual(@as(usize, max_per_kind + 1), r.count(null));
}
