//! Local completion telemetry (E12.F07.S01.T04): how many ghosts were
//! shown and accepted, and how long they took. Counts only, never code or
//! paths, and never sent anywhere. E14 reads `snapshot`; the user sees the
//! acceptance rate and median latency in the status bar's tooltip. Each
//! day's counts are kept in `.zigguro/review/stats.zon`.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const buckets = 16;

pub const Telemetry = struct {
    shown: u64 = 0,
    accepted_full: u64 = 0,
    accepted_partial: u64 = 0,
    chars_accepted: u64 = 0,
    /// Bucket `i` counts latencies in [2^i, 2^(i+1)) ms; bucket 0 also
    /// takes 0 ms and the last everything longer.
    latency_ms_hist: [buckets]u32 = @splat(0),

    pub fn snapshot(t: *const Telemetry) Telemetry {
        return t.*;
    }

    pub fn bucketOf(latency_ms: u64) usize {
        if (latency_ms < 2) return 0;
        return @min(buckets - 1, std.math.log2_int(u64, latency_ms));
    }

    /// A ghost was shown, `latency_ms` after its trigger.
    pub fn recordShown(t: *Telemetry, latency_ms: u64) void {
        t.shown += 1;
        t.latency_ms_hist[bucketOf(latency_ms)] +|= 1;
    }

    pub fn recordAccept(t: *Telemetry, full: bool, chars: usize) void {
        if (full) t.accepted_full += 1 else t.accepted_partial += 1;
        t.chars_accepted += chars;
    }

    /// Accepted (fully or partly) per shown, 0 to 1.
    pub fn acceptanceRate(t: *const Telemetry) f64 {
        if (t.shown == 0) return 0;
        const acc: f64 = @floatFromInt(t.accepted_full + t.accepted_partial);
        return @min(1.0, acc / @as(f64, @floatFromInt(t.shown)));
    }

    /// The median latency's bucket lower bound in ms (null when empty).
    pub fn p50Ms(t: *const Telemetry) ?u64 {
        var total: u64 = 0;
        for (t.latency_ms_hist) |n| total += n;
        if (total == 0) return null;
        var seen: u64 = 0;
        for (t.latency_ms_hist, 0..) |n, i| {
            seen += n;
            if (seen * 2 >= total) return if (i == 0) 0 else @as(u64, 1) << @intCast(i);
        }
        unreachable;
    }

    pub fn add(t: *Telemetry, o: Telemetry) void {
        t.shown += o.shown;
        t.accepted_full += o.accepted_full;
        t.accepted_partial += o.accepted_partial;
        t.chars_accepted += o.chars_accepted;
        for (&t.latency_ms_hist, o.latency_ms_hist) |*a, b| a.* +|= b;
    }
};

/// One day in the stats file.
pub const Day = struct {
    /// `YYYY-MM-DD`.
    day: []const u8,
    counts: Telemetry,
};

pub const StatsFile = struct {
    days: []const Day = &.{},
};

/// Days kept in the file.
pub const max_days = 90;

pub const stats_path = ".zigguro/review/stats.zon";

/// `YYYY-MM-DD` (UTC) for a Unix time in seconds.
pub fn dayString(buf: *[10]u8, unix_s: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(unix_s, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 }) catch unreachable;
}

/// Adds `counts` to `day` in the stats file under `root` (created when
/// missing), keeping the last `max_days` days.
pub fn persist(gpa: Allocator, io: Io, root: Io.Dir, day: []const u8, counts: Telemetry) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var days: std.ArrayList(Day) = .empty;
    if (root.readFileAlloc(io, stats_path, a, .limited(1 << 20))) |bytes| {
        const src = try a.dupeZ(u8, bytes);
        // A damaged file starts over rather than blocking the counts.
        if (std.zon.parse.fromSliceAlloc(StatsFile, a, src, null, .{ .ignore_unknown_fields = true })) |f| {
            try days.appendSlice(a, f.days);
        } else |_| {}
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }
    for (days.items) |*d| {
        if (std.mem.eql(u8, d.day, day)) {
            d.counts.add(counts);
            break;
        }
    } else try days.append(a, .{ .day = day, .counts = counts });
    const keep = days.items[days.items.len -| max_days..];

    var out: Io.Writer.Allocating = .init(a);
    std.zon.stringify.serialize(StatsFile{ .days = keep }, .{}, &out.writer) catch return error.OutOfMemory;
    try out.writer.writeByte('\n');
    try root.createDirPath(io, std.fs.path.dirname(stats_path).?);
    try root.writeFile(io, .{ .sub_path = stats_path, .data = out.written() });
}
