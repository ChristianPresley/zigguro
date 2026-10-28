//! The startup benchmark's data (E14.F05.S01.T03). Each launch of the app
//! writes one `ChildRun` (`--startup-report-json`): its marks as absolute
//! `.awake` nanoseconds, which is the same clock in every process on the
//! machine. The harness (`zigguro-bench-startup`) notes its own spawn time
//! on that clock, feeds both to a `Collector`, and writes E00 bench JSON
//! (schema 1, package `startup`) that the budget gate binds to.

const std = @import("std");
const builtin = @import("builtin");
const timeline = @import("timeline.zig");

const Phase = timeline.Phase;
const Summary = timeline.Summary;

/// One mark of a child run.
pub const Mark = struct { name: []const u8, ns: u64 };

/// What one launch of the app reports.
pub const ChildRun = struct {
    schema: u32 = 1,
    launch: []const u8 = "cold_guess",
    present_estimated: bool = true,
    /// The display's refresh interval, 0 when unknown.
    refresh_ns: u64 = 0,
    /// Absolute `.awake` ns per mark.
    marks: []const Mark = &.{},

    pub fn at(r: ChildRun, p: Phase) ?u64 {
        for (r.marks) |m| if (std.mem.eql(u8, m.name, @tagName(p))) return m.ns;
        return null;
    }

    /// The first interactive frame: `interactive`, else the first frame.
    pub fn end(r: ChildRun) ?u64 {
        return r.at(.interactive) orelse r.at(.first_frame_presented) orelse r.at(.first_frame_submitted);
    }
};

/// Writes `s` as a `ChildRun`.
pub fn writeChildJson(s: Summary, refresh_ns: u64, w: *std.Io.Writer) !void {
    var marks: [timeline.phase_count]Mark = undefined;
    var n: usize = 0;
    for (s.phases, 0..) |v, i| if (v) |t| {
        marks[n] = .{ .name = @tagName(@as(Phase, @enumFromInt(i))), .ns = t };
        n += 1;
    };
    try std.json.Stringify.value(ChildRun{
        .launch = @tagName(s.launch_kind),
        .present_estimated = s.presentEstimated(),
        .refresh_ns = refresh_ns,
        .marks = marks[0..n],
    }, .{}, w);
    try w.writeAll("\n");
}

pub fn parseChild(arena: std.mem.Allocator, bytes: []const u8) !ChildRun {
    return std.json.parseFromSliceLeaky(ChildRun, arena, bytes, .{ .ignore_unknown_fields = true });
}

/// Percentiles of a metric's samples (nearest rank).
pub const Pcts = struct {
    count: usize,
    mean_ns: f64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,

    /// Sorts `samples` in place.
    pub fn of(samples: []u64) Pcts {
        std.debug.assert(samples.len > 0);
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        var sum: f64 = 0;
        for (samples) |v| sum += @floatFromInt(v);
        return .{
            .count = samples.len,
            .mean_ns = sum / @as(f64, @floatFromInt(samples.len)),
            .p50_ns = rank(samples, 50),
            .p95_ns = rank(samples, 95),
            .p99_ns = rank(samples, 99),
            .max_ns = samples[samples.len - 1],
        };
    }

    fn rank(sorted: []const u64, p: u64) u64 {
        const k = (p * sorted.len + 99) / 100;
        return sorted[@max(k, 1) - 1];
    }
};

/// How the cold runs were made cold.
pub const ColdKind = enum {
    /// No cold runs.
    none,
    /// Root on Linux: the page cache was dropped before each run.
    drop_caches,
    /// A fresh copy of the binary (and workspace) per run.
    pseudo_cold,
};

/// Run facts written next to the results.
pub const Meta = struct {
    platform: []const u8,
    cold_kind: ColdKind = .none,
    /// Linux scaling governor of cpu0, when readable.
    governor: ?[]const u8 = null,
    machine: []const u8 = "",
    workspace: ?[]const u8 = null,
    /// Launches whose injected key was handled later than two frames
    /// after the first presented frame.
    input_late: u32 = 0,
};

/// Samples per metric over all runs.
pub const Collector = struct {
    gpa: std.mem.Allocator,
    metrics: std.StringArrayHashMapUnmanaged(std.ArrayList(u64)) = .empty,
    names: std.heap.ArenaAllocator,
    refresh_ns: u64 = 0,
    input_late: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Collector {
        return .{ .gpa = gpa, .names = .init(gpa) };
    }

    pub fn deinit(c: *Collector) void {
        for (c.metrics.values()) |*v| v.deinit(c.gpa);
        c.metrics.deinit(c.gpa);
        c.names.deinit();
    }

    fn add(c: *Collector, name: []const u8, ns: u64) !void {
        const gop = try c.metrics.getOrPut(c.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try c.names.allocator().dupe(u8, name);
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(c.gpa, ns);
    }

    /// Adds one launch spawned at `spawn_ns` (`.awake`). Cold runs go to
    /// the `_cold` metrics. Results:
    /// - `startup.first_interactive_frame`: spawn to the first
    ///   interactive frame;
    /// - `startup.os_to_main`: spawn to `main_entered`;
    /// - `startup.phase.<owner>`: the time each owner's marks took (the
    ///   `startup.phase.<owner>` budgets), as in the startup report.
    pub fn addRun(c: *Collector, r: ChildRun, spawn_ns: u64, cold: bool) !void {
        const end = r.end() orelse return error.NoFrame;
        const suffix = if (cold) "_cold" else "";
        var buf: [96]u8 = undefined;
        try c.add(try std.fmt.bufPrint(&buf, "startup.first_interactive_frame{s}", .{suffix}), end -| spawn_ns);
        if (r.at(.main_entered)) |m| try c.add(try std.fmt.bufPrint(&buf, "startup.os_to_main{s}", .{suffix}), m -| spawn_ns);
        if (r.refresh_ns != 0) c.refresh_ns = r.refresh_ns;
        if (r.at(.first_input_handled)) |inp| if (r.at(.first_frame_presented)) |p| {
            const frame = if (r.refresh_ns != 0) r.refresh_ns else 16_666_667;
            if (inp > p + 2 * frame) c.input_late += 1;
        };
        // Owner time: each mark's delta from the previous mark, in time
        // order, the first mark and first_input_handled left out.
        var order: [timeline.phase_count]Phase = undefined;
        var n: usize = 0;
        for (0..timeline.phase_count) |i| {
            const p: Phase = @enumFromInt(i);
            if (r.at(p) == null or p == .first_input_handled or p == .process_created) continue;
            order[n] = p;
            n += 1;
        }
        std.mem.sort(Phase, order[0..n], r, struct {
            fn lt(run: ChildRun, a: Phase, b: Phase) bool {
                return run.at(a).? < run.at(b).?;
            }
        }.lt);
        var owners: [16]struct { name: []const u8, ns: u64 } = undefined;
        var no: usize = 0;
        for (order[0..n], 0..) |p, i| {
            if (i == 0) continue;
            const d = r.at(p).? -| r.at(order[i - 1]).?;
            const own = p.owner();
            const slot = for (owners[0..no]) |*x| {
                if (std.mem.eql(u8, x.name, own)) break x;
            } else blk: {
                owners[no] = .{ .name = own, .ns = 0 };
                no += 1;
                break :blk &owners[no - 1];
            };
            slot.ns += d;
        }
        for (owners[0..no]) |x| {
            if (std.mem.eql(u8, x.name, "os")) continue;
            try c.add(try std.fmt.bufPrint(&buf, "startup.phase.{s}{s}", .{ x.name, suffix }), x.ns);
        }
    }

    /// Writes E00 bench JSON (schema 1, package `startup`): per metric
    /// `ns_per_op` (mean), `p50_ns`, `p95_ns`, `p99_ns`, `max_ns` and
    /// every run in `samples_ns`.
    pub fn writeJson(c: *Collector, w: *std.Io.Writer, meta: Meta) !void {
        var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
        try s.beginObject();
        try s.objectField("schema");
        try s.write(@as(u32, 1));
        try s.objectField("package");
        try s.write("startup");
        try s.objectField("zig");
        try s.write(builtin.zig_version_string);
        try s.objectField("target");
        try s.write(@tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag));
        try s.objectField("optimize");
        try s.write(@tagName(builtin.mode));
        try s.objectField("cpu");
        try s.write(builtin.cpu.model.name);
        try s.objectField("quick");
        try s.write(false);
        try s.objectField("platform");
        try s.write(meta.platform);
        try s.objectField("launch_kind");
        try s.write(if (meta.cold_kind == .none) "warm" else @tagName(meta.cold_kind));
        try s.objectField("cold_kind");
        try s.write(@tagName(meta.cold_kind));
        try s.objectField("machine");
        try s.write(meta.machine);
        try s.objectField("governor");
        try s.write(meta.governor);
        try s.objectField("refresh_ns");
        try s.write(c.refresh_ns);
        try s.objectField("workspace");
        try s.write(meta.workspace);
        try s.objectField("input_late");
        try s.write(c.input_late);
        try s.objectField("results");
        try s.beginArray();
        for (c.metrics.keys(), c.metrics.values()) |name, *v| {
            const sorted = try c.gpa.dupe(u64, v.items);
            defer c.gpa.free(sorted);
            const p = Pcts.of(sorted);
            try s.beginObject();
            try s.objectField("name");
            try s.write(name);
            try s.objectField("iters");
            try s.write(p.count);
            try s.objectField("ns_per_op");
            try s.write(p.mean_ns);
            try s.objectField("p50_ns");
            try s.write(p.p50_ns);
            try s.objectField("p95_ns");
            try s.write(p.p95_ns);
            try s.objectField("p99_ns");
            try s.write(p.p99_ns);
            try s.objectField("max_ns");
            try s.write(p.max_ns);
            try s.objectField("allocs_per_op");
            try s.write(@as(f64, 0));
            try s.objectField("bytes_alloc_per_op");
            try s.write(@as(f64, 0));
            try s.objectField("samples_ns");
            try s.write(v.items);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
        try w.writeAll("\n");
    }

    /// A short table for the terminal.
    pub fn writeSummary(c: *Collector, w: *std.Io.Writer) !void {
        try w.print("{s:<40} {s:>5} {s:>9} {s:>9} {s:>9}\n", .{ "metric (ms)", "runs", "p50", "p95", "max" });
        for (c.metrics.keys(), c.metrics.values()) |name, *v| {
            const sorted = try c.gpa.dupe(u64, v.items);
            defer c.gpa.free(sorted);
            const p = Pcts.of(sorted);
            try w.print("{s:<40} {d:>5} {d:>9.2} {d:>9.2} {d:>9.2}\n", .{ name, p.count, ms(p.p50_ns), ms(p.p95_ns), ms(p.max_ns) });
        }
    }
};

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// The Linux CPU frequency governor of cpu0 (null elsewhere or when
/// unreadable).
pub fn readGovernor(arena: std.mem.Allocator, io: std.Io) ?[]const u8 {
    if (builtin.os.tag != .linux) return null;
    const text = std.Io.Dir.cwd().readFileAlloc(io, "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", arena, .limited(256)) catch return null;
    return std.mem.trim(u8, text, " \n\r\t");
}

fn synthetic(arena: std.mem.Allocator, spawn: u64, main_off: u64, total: u64) !ChildRun {
    const ms_ = std.time.ns_per_ms;
    var s: Summary = .{};
    const set = struct {
        fn f(x: *Summary, p: Phase, t: u64) void {
            x.phases[@intFromEnum(p)] = t;
        }
    }.f;
    const m = spawn + main_off;
    set(&s, .main_entered, m);
    set(&s, .runtime_ready, m + 1 * ms_);
    set(&s, .config_loaded, m + 3 * ms_);
    set(&s, .platform_ready, m + 9 * ms_);
    set(&s, .window_created, m + 20 * ms_);
    set(&s, .workbench_built, m + 30 * ms_);
    set(&s, .first_frame_submitted, m + 35 * ms_);
    set(&s, .first_frame_presented, m + 40 * ms_);
    set(&s, .interactive, spawn + total);
    set(&s, .first_input_handled, m + 45 * ms_);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeChildJson(s, 16 * ms_, &aw.writer);
    return parseChild(arena, aw.written());
}

test "startup bench: percentile and schema" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ms_ = std.time.ns_per_ms;

    var samples = [_]u64{ 5, 1, 4, 2, 3, 10, 9, 8, 7, 6 };
    const p = Pcts.of(&samples);
    try std.testing.expectEqual(@as(u64, 5), p.p50_ns);
    try std.testing.expectEqual(@as(u64, 10), p.p95_ns);
    try std.testing.expectEqual(@as(u64, 10), p.max_ns);
    var one = [_]u64{7};
    try std.testing.expectEqual(@as(u64, 7), Pcts.of(&one).p99_ns);

    var c: Collector = .init(gpa);
    defer c.deinit();
    for (0..4) |i| try c.addRun(try synthetic(a, 1000 * ms_ * (i + 1), 2 * ms_, (50 + i) * ms_), 1000 * ms_ * (i + 1), false);
    try c.addRun(try synthetic(a, 9000 * ms_, 5 * ms_, 90 * ms_), 9000 * ms_, true);
    // A run without any frame is an error.
    try std.testing.expectError(error.NoFrame, c.addRun(.{}, 0, false));

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try c.writeJson(&aw.writer, .{ .platform = "headless", .cold_kind = .pseudo_cold, .governor = "performance" });
    // The output binds like any E00 bench file.
    const bind = @import("../budget/bench_bind.zig");
    const f = try bind.parseBenchFile(a, aw.written());
    try std.testing.expectEqualStrings("startup", f.package);
    var found: u32 = 0;
    for (f.results) |r| {
        if (std.mem.eql(u8, r.name, "startup.first_interactive_frame")) {
            found += 1;
            try std.testing.expectEqual(@as(f64, 51 * ms_), r.p50_ns);
            try std.testing.expectEqual(@as(f64, 53 * ms_), r.p95_ns.?);
            try std.testing.expectEqual(@as(usize, 4), r.samples_ns.?.len);
        } else if (std.mem.eql(u8, r.name, "startup.os_to_main")) {
            found += 1;
            try std.testing.expectEqual(@as(f64, 2 * ms_), r.p50_ns);
        } else if (std.mem.eql(u8, r.name, "startup.phase.e00")) {
            found += 1;
            try std.testing.expectEqual(@as(f64, 1 * ms_), r.p50_ns);
        } else if (std.mem.eql(u8, r.name, "startup.first_interactive_frame_cold")) {
            found += 1;
            try std.testing.expectEqual(@as(f64, 90 * ms_), r.p50_ns);
        }
    }
    try std.testing.expectEqual(@as(u32, 4), found);
    // The injected key came 5 ms after the first presented frame: on time.
    try std.testing.expectEqual(@as(u32, 0), c.input_late);
    try std.testing.expectEqual(@as(u64, 16 * ms_), c.refresh_ns);
}
