//! The OS-independent coalescer: merges raw change records into one event
//! per path per burst. A burst closes `debounce_ms` after its last record,
//! or 200 ms after its first, whichever comes first.

const std = @import("std");
const api = @import("api.zig");
const FsEvent = api.FsEvent;
const Kind = api.FsEvent.Kind;

/// Longest a burst may stay open.
pub const max_latency_ns: u64 = 200 * std.time.ns_per_ms;

const Key = struct { root: api.RootId, path: []const u8 };

const KeyContext = struct {
    /// Hashes root and path.
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h = std.hash.Wyhash.init(@intFromEnum(k.root));
        h.update(k.path);
        return h.final();
    }
    /// Compares root and path.
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.root == b.root and std.mem.eql(u8, a.path, b.path);
    }
};

const Entry = struct {
    kind: Kind,
    old_path: ?[]const u8 = null,
    is_dir: ?bool = null,
    reason: api.RescanReason = .none,
};

/// Pending changes for the current burst. Paths are copied into the
/// coalescer's own memory.
pub const Coalescer = struct {
    gpa: std.mem.Allocator,
    debounce_ns: u64,
    map: std.HashMapUnmanaged(Key, Entry, KeyContext, 80) = .empty,
    first_ns: ?u64 = null,
    last_ns: u64 = 0,

    /// An empty coalescer.
    pub fn init(gpa: std.mem.Allocator, debounce_ms: u32) Coalescer {
        return .{ .gpa = gpa, .debounce_ns = @as(u64, debounce_ms) * std.time.ns_per_ms };
    }

    /// Frees all pending entries.
    pub fn deinit(c: *Coalescer) void {
        c.clear();
        c.map.deinit(c.gpa);
    }

    fn clear(c: *Coalescer) void {
        var it = c.map.iterator();
        while (it.next()) |e| c.freeEntry(e.key_ptr.*, e.value_ptr.*);
        c.map.clearRetainingCapacity();
        c.first_ns = null;
    }

    fn freeEntry(c: *Coalescer, k: Key, v: Entry) void {
        c.gpa.free(k.path);
        if (v.old_path) |o| c.gpa.free(o);
    }

    /// Whether anything is pending.
    pub fn isEmpty(c: *const Coalescer) bool {
        return c.map.count() == 0;
    }

    /// Records one change seen at `now_ns`.
    pub fn add(c: *Coalescer, ev: FsEvent, now_ns: u64) std.mem.Allocator.Error!void {
        if (c.first_ns == null) c.first_ns = now_ns;
        c.last_ns = now_ns;
        switch (ev.kind) {
            .rescan_required => return c.addRescan(ev),
            .renamed => return c.addRename(ev),
            else => {},
        }
        // A rescan of an ancestor already covers this path.
        if (c.coveredByRescan(ev.root, ev.path)) return;
        const key: Key = .{ .root = ev.root, .path = ev.path };
        if (c.map.getPtr(key)) |cur| {
            const merged = merge(cur.kind, ev.kind);
            if (merged) |k| {
                cur.kind = k;
                if (ev.is_dir) |d| cur.is_dir = d;
            } else {
                const kv = c.map.fetchRemove(key).?;
                c.freeEntry(kv.key, kv.value);
            }
            return;
        }
        try c.put(ev.root, ev.path, .{ .kind = ev.kind, .is_dir = ev.is_dir });
    }

    fn put(c: *Coalescer, root: api.RootId, path: []const u8, e: Entry) std.mem.Allocator.Error!void {
        const owned = try c.gpa.dupe(u8, path);
        errdefer c.gpa.free(owned);
        try c.map.put(c.gpa, .{ .root = root, .path = owned }, e);
    }

    fn addRename(c: *Coalescer, ev: FsEvent) std.mem.Allocator.Error!void {
        const old = ev.old_path.?;
        var was_created = false;
        if (c.map.fetchRemove(.{ .root = ev.root, .path = old })) |kv| {
            was_created = kv.value.kind == .created;
            c.freeEntry(kv.key, kv.value);
        }
        if (c.map.fetchRemove(.{ .root = ev.root, .path = ev.path })) |kv| c.freeEntry(kv.key, kv.value);
        if (was_created) return c.put(ev.root, ev.path, .{ .kind = .created, .is_dir = ev.is_dir });
        const old_owned = try c.gpa.dupe(u8, old);
        errdefer c.gpa.free(old_owned);
        try c.put(ev.root, ev.path, .{ .kind = .renamed, .old_path = old_owned, .is_dir = ev.is_dir });
    }

    fn addRescan(c: *Coalescer, ev: FsEvent) std.mem.Allocator.Error!void {
        // Drop everything under the rescanned directory.
        var doomed: std.ArrayList(Key) = .empty;
        defer doomed.deinit(c.gpa);
        var it = c.map.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.root == ev.root and isUnder(e.key_ptr.path, ev.path)) try doomed.append(c.gpa, e.key_ptr.*);
        }
        for (doomed.items) |k| {
            const kv = c.map.fetchRemove(k).?;
            c.freeEntry(kv.key, kv.value);
        }
        try c.put(ev.root, ev.path, .{ .kind = .rescan_required, .is_dir = true, .reason = ev.reason });
    }

    fn coveredByRescan(c: *const Coalescer, root: api.RootId, path: []const u8) bool {
        var p = path;
        while (true) {
            if (c.map.get(.{ .root = root, .path = p })) |e| if (e.kind == .rescan_required) return true;
            if (p.len == 0) return false;
            p = if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[0..i] else "";
        }
    }

    /// Whether the burst is complete at `now_ns`.
    pub fn ready(c: *const Coalescer, now_ns: u64) bool {
        const first = c.first_ns orelse return false;
        return now_ns -| c.last_ns >= c.debounce_ns or now_ns -| first >= max_latency_ns;
    }

    /// Nanoseconds until `ready` turns true, or null when nothing is pending.
    pub fn timeUntilReady(c: *const Coalescer, now_ns: u64) ?u64 {
        const first = c.first_ns orelse return null;
        const by_debounce = (c.last_ns + c.debounce_ns) -| now_ns;
        const by_cap = (first + max_latency_ns) -| now_ns;
        return @min(by_debounce, by_cap);
    }

    /// Moves the burst into `out` (grown with `list_gpa`), sorted by root
    /// then path, with paths copied into `arena`. Empties the coalescer.
    pub fn take(c: *Coalescer, arena: std.mem.Allocator, list_gpa: std.mem.Allocator, out: *std.ArrayList(FsEvent)) std.mem.Allocator.Error!void {
        const start = out.items.len;
        var it = c.map.iterator();
        while (it.next()) |e| {
            try out.append(list_gpa, .{
                .root = e.key_ptr.root,
                .kind = e.value_ptr.kind,
                .path = try arena.dupe(u8, e.key_ptr.path),
                .old_path = if (e.value_ptr.old_path) |o| try arena.dupe(u8, o) else null,
                .is_dir = e.value_ptr.is_dir,
                .reason = e.value_ptr.reason,
            });
        }
        std.mem.sort(FsEvent, out.items[start..], {}, lessThan);
        c.clear();
    }
};

fn lessThan(_: void, a: FsEvent, b: FsEvent) bool {
    if (a.root != b.root) return @intFromEnum(a.root) < @intFromEnum(b.root);
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// Whether `path` is `dir` or inside it ("" is the root).
pub fn isUnder(path: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return true;
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path.len == dir.len or path[dir.len] == '/';
}

/// The merge table: `old` then `new` for the same path in one burst; null
/// means the changes cancel out.
pub fn merge(old: Kind, new: Kind) ?Kind {
    return switch (old) {
        .created => switch (new) {
            .removed => null,
            else => .created,
        },
        .removed => switch (new) {
            .created => .modified,
            else => .removed,
        },
        .modified, .attrib, .renamed => switch (new) {
            .removed => .removed,
            .attrib => if (old == .attrib) .attrib else old,
            .created => .modified,
            else => if (old == .renamed) .renamed else .modified,
        },
        .rescan_required => .rescan_required,
    };
}

const testing = std.testing;
const r0: api.RootId = @enumFromInt(0);

fn mk(kind: Kind, path: []const u8) FsEvent {
    return .{ .root = r0, .kind = kind, .path = path };
}

fn run(events: []const FsEvent) !std.ArrayList(FsEvent) {
    var c: Coalescer = .init(testing.allocator, 30);
    defer c.deinit();
    for (events, 0..) |e, i| try c.add(e, i);
    var out: std.ArrayList(FsEvent) = .empty;
    try c.take(arena_state.allocator(), arena_state.allocator(), &out);
    return out;
}

var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

test "merge table" {
    defer _ = arena_state.reset(.free_all);
    const Case = struct { in: []const FsEvent, want: []const struct { Kind, []const u8 } };
    const cases = [_]Case{
        .{ .in = &.{ mk(.created, "a"), mk(.modified, "a") }, .want = &.{.{ .created, "a" }} },
        .{ .in = &.{ mk(.created, "a"), mk(.removed, "a") }, .want = &.{} },
        .{ .in = &.{ mk(.removed, "a"), mk(.created, "a") }, .want = &.{.{ .modified, "a" }} },
        .{ .in = &.{ mk(.modified, "a"), mk(.removed, "a") }, .want = &.{.{ .removed, "a" }} },
        .{ .in = &.{ mk(.attrib, "a"), mk(.modified, "a") }, .want = &.{.{ .modified, "a" }} },
        .{ .in = &.{ mk(.modified, "a"), mk(.attrib, "a") }, .want = &.{.{ .modified, "a" }} },
        .{ .in = &.{ mk(.modified, "b"), mk(.created, "a") }, .want = &.{ .{ .created, "a" }, .{ .modified, "b" } } },
        .{ .in = &.{ mk(.modified, "d/x"), mk(.rescan_required, "d"), mk(.created, "d/y"), mk(.created, "e") }, .want = &.{ .{ .rescan_required, "d" }, .{ .created, "e" } } },
        .{ .in = &.{ mk(.created, "a"), .{ .root = r0, .kind = .renamed, .path = "b", .old_path = "a" } }, .want = &.{.{ .created, "b" }} },
        .{ .in = &.{ mk(.modified, "a"), .{ .root = r0, .kind = .renamed, .path = "b", .old_path = "a" } }, .want = &.{.{ .renamed, "b" }} },
        .{ .in = &.{ mk(.modified, "dd"), mk(.rescan_required, "d") }, .want = &.{ .{ .rescan_required, "d" }, .{ .modified, "dd" } } },
    };
    for (cases) |c| {
        var out = try run(c.in);
        try testing.expectEqual(c.want.len, out.items.len);
        for (c.want, out.items) |w, g| {
            try testing.expectEqual(w[0], g.kind);
            try testing.expectEqualStrings(w[1], g.path);
        }
        out.clearRetainingCapacity();
    }
}

test "readiness: debounce after the last record, capped at 200 ms" {
    var c: Coalescer = .init(testing.allocator, 30);
    defer c.deinit();
    try testing.expect(!c.ready(0));
    try testing.expectEqual(null, c.timeUntilReady(0));
    const ms = std.time.ns_per_ms;
    try c.add(mk(.modified, "a"), 0);
    try testing.expect(!c.ready(29 * ms));
    try testing.expect(c.ready(30 * ms));
    var t: u64 = 0;
    while (t < 190 * ms) : (t += 20 * ms) try c.add(mk(.modified, "a"), t);
    try testing.expect(!c.ready(199 * ms));
    try testing.expect(c.ready(200 * ms));
    try testing.expectEqual(@as(?u64, 0), c.timeUntilReady(200 * ms));
}
