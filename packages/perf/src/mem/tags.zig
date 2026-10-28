//! Memory tags (E14.F04.S01.T01): every allocation is charged to the
//! subsystem that made it. The list is central on purpose: a package
//! cannot add a tag without editing this file (see docs/perf/memory.md
//! for which package uses which tag).
//!
//! Per tag the counters are live bytes, peak bytes, allocations and frees.
//! Each thread charges its own shard with plain stores (no locked
//! instructions); a shard flushes to the tag's global live count once it
//! holds `flush_bytes`, and the peak is updated there. Reads sum the
//! shards.

const std = @import("std");

pub const MemTag = enum(u8) { core, platform, gpu_host, text, gui, editor, syntax, terminal, lsp, workspace, notes, scm, ai, mcp, review, perf, config, other };

/// Room for tags (the snapshot arrays are this long).
pub const max_tags = 32;
/// Tags in use.
pub const tag_count = @typeInfo(MemTag).@"enum".fields.len;

comptime {
    std.debug.assert(tag_count <= max_tags);
}

/// The tag's name (`mem.tag.<name>` counters, reports).
pub fn name(t: MemTag) []const u8 {
    return @tagName(t);
}

/// One tag's counters at a point in time.
pub const TagStats = struct {
    live: i64 = 0,
    peak: u64 = 0,
    allocs: u64 = 0,
    frees: u64 = 0,
};

/// Bytes a thread's shard holds before it flushes them to the tag's
/// global live count (and peak).
pub const flush_bytes: i64 = 64 * 1024;

const Global = struct {
    live: std.atomic.Value(i64) align(std.atomic.cache_line) = .init(0),
    peak: std.atomic.Value(u64) = .init(0),
    /// Counts from threads that could not get a shard.
    allocs: std.atomic.Value(u64) = .init(0),
    frees: std.atomic.Value(u64) = .init(0),
};

/// One thread's counters. Only the owner writes them (plain loads and
/// stores, no locked instructions); readers sum all shards. Shards are
/// never freed: a thread that exits leaves its deltas, which keeps the
/// sums exact.
const Shard = struct {
    delta: [max_tags]std.atomic.Value(i64) = @splat(.init(0)),
    allocs: [max_tags]std.atomic.Value(u64) = @splat(.init(0)),
    frees: [max_tags]std.atomic.Value(u64) = @splat(.init(0)),
    next: ?*Shard = null,
};

var globals: [max_tags]Global = @splat(.{});
var shards: std.atomic.Value(?*Shard) = .init(null);
threadlocal var my_shard: ?*Shard = null;

fn shard() ?*Shard {
    if (my_shard) |sh| return sh;
    return newShard();
}

noinline fn newShard() ?*Shard {
    const sh = std.heap.page_allocator.create(Shard) catch return null;
    sh.* = .{};
    var head = shards.load(.monotonic);
    while (true) {
        sh.next = head;
        head = shards.cmpxchgWeak(head, sh, .release, .monotonic) orelse break;
    }
    my_shard = sh;
    return sh;
}

fn bump(v: *std.atomic.Value(u64)) void {
    v.store(v.load(.monotonic) + 1, .monotonic);
}

fn flush(i: usize, d: i64) void {
    const g = &globals[i];
    const live = g.live.fetchAdd(d, .monotonic) + d;
    if (d <= 0 or live <= 0) return;
    const l: u64 = @intCast(live);
    var peak = g.peak.load(.monotonic);
    while (l > peak) peak = g.peak.cmpxchgWeak(peak, l, .monotonic, .monotonic) orelse return;
}

/// An allocation (or growth) of `bytes` charged to `tag`; `count` adds
/// one to the allocation count.
pub fn chargeAlloc(tag: MemTag, bytes: usize, count: bool) void {
    const i = @intFromEnum(tag);
    const sh = shard() orelse {
        if (count) _ = globals[i].allocs.fetchAdd(1, .monotonic);
        return flush(i, @intCast(bytes));
    };
    if (count) bump(&sh.allocs[i]);
    const d = sh.delta[i].load(.monotonic) + @as(i64, @intCast(bytes));
    if (d >= flush_bytes) {
        flush(i, d);
        sh.delta[i].store(0, .monotonic);
    } else sh.delta[i].store(d, .monotonic);
}

/// A free (or shrink) of `bytes`; `count` adds one to the free count.
pub fn chargeFree(tag: MemTag, bytes: usize, count: bool) void {
    const i = @intFromEnum(tag);
    const sh = shard() orelse {
        if (count) _ = globals[i].frees.fetchAdd(1, .monotonic);
        return flush(i, -@as(i64, @intCast(bytes)));
    };
    if (count) bump(&sh.frees[i]);
    const d = sh.delta[i].load(.monotonic) - @as(i64, @intCast(bytes));
    if (d <= -flush_bytes) {
        flush(i, d);
        sh.delta[i].store(0, .monotonic);
    } else sh.delta[i].store(d, .monotonic);
}

/// `tag`'s counters now: exact when no thread is charging it; otherwise
/// each field is a recent value. The peak is tracked at flush points, so
/// it can miss up to `flush_bytes` per thread.
pub fn tagStats(tag: MemTag) TagStats {
    const i = @intFromEnum(tag);
    const g = &globals[i];
    var st: TagStats = .{ .live = g.live.load(.monotonic), .allocs = g.allocs.load(.monotonic), .frees = g.frees.load(.monotonic) };
    var it = shards.load(.acquire);
    while (it) |sh| : (it = sh.next) {
        st.live += sh.delta[i].load(.monotonic);
        st.allocs += sh.allocs[i].load(.monotonic);
        st.frees += sh.frees[i].load(.monotonic);
    }
    st.peak = @max(g.peak.load(.monotonic), @as(u64, @intCast(@max(0, st.live))));
    return st;
}

/// Every tag's counters (unused slots are zero), indexed by tag.
pub fn allTagStats(out: *[max_tags]TagStats) void {
    for (out, 0..) |*st, i| st.* = if (i < tag_count) tagStats(@enumFromInt(i)) else .{};
}

/// Live bytes of all tags.
pub fn totalLive() i64 {
    var t: i64 = 0;
    for (0..tag_count) |i| t += tagStats(@enumFromInt(i)).live;
    return t;
}

test "tags: names and room" {
    try std.testing.expectEqualStrings("gpu_host", name(.gpu_host));
    try std.testing.expect(tag_count <= max_tags);
    var all: [max_tags]TagStats = undefined;
    allTagStats(&all);
    try std.testing.expectEqual(@as(u64, 0), all[max_tags - 1].allocs);
}
