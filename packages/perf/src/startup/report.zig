//! The startup report and history (E14.F05.S01.T01): `zigguro
//! --startup-report` prints phases, durations and the ledger budgets;
//! `persist` keeps the last 20 summaries in `startup.json`.

const std = @import("std");
const timeline = @import("timeline.zig");
const budget = @import("../budget.zig");

const Phase = timeline.Phase;
const Summary = timeline.Summary;

/// Summaries kept in startup.json.
pub const history_len = 20;
pub const file_name = "startup.json";
/// A run this soon after the previous one counts as warm.
pub const warm_window_ms: i64 = 10 * std.time.ms_per_min;

fn writeMs(w: *std.Io.Writer, ns: u64) !void {
    const tenths = (ns + 50_000) / 100_000;
    try w.print("{d}.{d}", .{ tenths / 10, tenths % 10 });
}

fn cell(w: *std.Io.Writer, ns: u64, width: usize) !void {
    var buf: [24]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&buf);
    try writeMs(&fw, ns);
    try w.splatByteAll(' ', width -| fw.buffered().len);
    try w.writeAll(fw.buffered());
}

/// The startup.phase.<owner> budget's limit in ns.
fn ownerBudgetNs(owner: []const u8) ?u64 {
    var buf: [32]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "startup.phase.{s}", .{owner}) catch return null;
    const b = budget.byId(id) orelse return null;
    return @intFromFloat(b.limit);
}

/// The human report: each mark relative to the origin and to the
/// previous mark, time per owner against its `startup.phase.<owner>`
/// budget, and the total against `startup.first_interactive_frame`.
pub fn writeReport(s: Summary, w: *std.Io.Writer) !void {
    try w.print("startup ({t} launch)\n", .{s.launch_kind});
    const o = s.origin() orelse {
        try w.writeAll("no marks\n");
        return;
    };
    // Marks in time order.
    var order: [timeline.phase_count]Phase = undefined;
    var n: usize = 0;
    for (0..timeline.phase_count) |i| {
        if (s.phases[i] == null) continue;
        order[n] = @enumFromInt(i);
        n += 1;
    }
    std.mem.sort(Phase, order[0..n], s, struct {
        fn lt(sm: Summary, a: Phase, b: Phase) bool {
            return sm.at(a).? < sm.at(b).?;
        }
    }.lt);
    var owner_ns: [16]struct { owner: []const u8, ns: u64 } = undefined;
    var owners: usize = 0;
    try w.writeAll("phase                     at ms     +ms  owner\n");
    var prev: ?u64 = null;
    for (order[0..n]) |p| {
        const t = s.at(p).?;
        const name = @tagName(p);
        try w.writeAll(name);
        try w.splatByteAll(' ', 22 -| name.len);
        if (t < o) {
            try w.writeAll("  -");
            try cell(w, o - t, 6);
        } else try cell(w, t - o, 9);
        const delta = if (prev) |pv| t -| pv else 0;
        try cell(w, delta, 8);
        try w.print("  {s}\n", .{p.owner()});
        if (prev != null and p != .first_input_handled) {
            const own = p.owner();
            const slot = for (owner_ns[0..owners]) |*x| {
                if (std.mem.eql(u8, x.owner, own)) break x;
            } else blk: {
                owner_ns[owners] = .{ .owner = own, .ns = 0 };
                owners += 1;
                break :blk &owner_ns[owners - 1];
            };
            slot.ns += delta;
        }
        prev = t;
    }
    if (s.at(.process_created)) |c| if (s.at(.main_entered)) |m| {
        try w.writeAll("\nOS to main ");
        try writeMs(w, m -| c);
        try w.writeAll(" ms (process start resolution ");
        try writeMs(w, s.process_start_resolution_ns);
        try w.writeAll(" ms)\n");
    };
    try w.writeAll("\nowner      ms  budget\n");
    for (owner_ns[0..owners]) |x| {
        if (std.mem.eql(u8, x.owner, "os")) continue;
        try w.writeAll(x.owner);
        try w.splatByteAll(' ', 6 -| x.owner.len);
        try cell(w, x.ns, 6);
        if (ownerBudgetNs(x.owner)) |b| {
            try cell(w, b, 8);
            if (x.ns > b) try w.writeAll("  over");
        } else try w.writeAll("       -");
        try w.writeAll("\n");
    }
    if (s.totalNs()) |t| {
        const b: u64 = @intFromFloat(budget.get("startup.first_interactive_frame").limit);
        try w.writeAll("\ntotal ");
        try writeMs(w, t);
        try w.writeAll(" ms of ");
        try writeMs(w, b);
        try w.print(" ms budget ({s} to {s}){s}{s}\n", .{
            if (s.origin() == s.at(.main_entered)) "main" else "process start",
            if (s.at(.interactive) != null) "interactive" else "first frame",
            if (s.presentEstimated()) ", presentation estimated" else "",
            if (t > b) ", over" else "",
        });
    }
}

/// One persisted run.
pub const Run = struct {
    unix_ms: i64,
    launch: []const u8,
    total_ns: ?u64 = null,
    present_estimated: bool = true,
    /// Mark times relative to the origin, by phase name.
    phases: []const PhaseNs = &.{},

    pub const PhaseNs = struct { name: []const u8, ns: i64 };
};

pub const File = struct {
    schema: u32 = 1,
    runs: []const Run = &.{},
};

/// Whether the newest run in `history` is recent enough to call this
/// launch warm.
pub fn launchKind(history: []const Run, now_unix_ms: i64) @FieldType(Summary, "launch_kind") {
    if (history.len == 0) return .cold_guess;
    const last = history[history.len - 1].unix_ms;
    return if (now_unix_ms - last >= 0 and now_unix_ms - last < warm_window_ms) .warm else .cold_guess;
}

/// Reads startup.json from `dir` (empty history when missing or bad).
pub fn readHistory(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) []const Run {
    const text = dir.readFileAlloc(io, file_name, arena, .limited(1 << 20)) catch return &.{};
    const f = std.json.parseFromSliceLeaky(File, arena, text, .{ .ignore_unknown_fields = true }) catch return &.{};
    return f.runs;
}

/// Appends `s` to startup.json in `dir`, keeping the last 20 runs, and
/// writes it atomically. Blocking: run it on a worker.
pub fn persist(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, s: Summary, now_unix_ms: i64) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old = readHistory(arena, io, dir);
    const keep = old[old.len -| (history_len - 1)..];
    var runs = try arena.alloc(Run, keep.len + 1);
    @memcpy(runs[0..keep.len], keep);
    var phases: std.ArrayList(Run.PhaseNs) = .empty;
    const o = s.origin() orelse 0;
    for (s.phases, 0..) |v, i| if (v) |t| {
        try phases.append(arena, .{ .name = @tagName(@as(Phase, @enumFromInt(i))), .ns = @as(i64, @intCast(t)) - @as(i64, @intCast(o)) });
    };
    runs[keep.len] = .{ .unix_ms = now_unix_ms, .launch = @tagName(s.launch_kind), .total_ns = s.totalNs(), .present_estimated = s.presentEstimated(), .phases = phases.items };
    const out = try std.json.Stringify.valueAlloc(arena, File{ .runs = runs }, .{ .whitespace = .indent_1 });
    var af = try dir.createFileAtomic(io, file_name, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, out);
    try af.replace(io);
}

fn sample() Summary {
    var s: Summary = .{ .process_start_resolution_ns = 10 * std.time.ns_per_ms };
    const ms = std.time.ns_per_ms;
    const base: u64 = 1000 * ms;
    const set = struct {
        fn f(x: *Summary, p: Phase, t: u64) void {
            x.phases[@intFromEnum(p)] = t;
        }
    }.f;
    set(&s, .process_created, base - 8 * ms);
    set(&s, .main_entered, base);
    set(&s, .runtime_ready, base + 1_200_000);
    set(&s, .config_loaded, base + 3 * ms);
    set(&s, .platform_ready, base + 9 * ms);
    set(&s, .gpu_ready, base + 52 * ms);
    set(&s, .fonts_ready, base + 60 * ms);
    set(&s, .window_created, base + 64 * ms);
    set(&s, .workbench_built, base + 70 * ms);
    set(&s, .first_frame_submitted, base + 78 * ms);
    set(&s, .interactive, base + 80 * ms);
    return s;
}

test "startup: report golden" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeReport(sample(), &w);
    try std.testing.expectEqualStrings(
        \\startup (cold_guess launch)
        \\phase                     at ms     +ms  owner
        \\process_created         -   8.0     0.0  os
        \\main_entered                0.0     8.0  os
        \\runtime_ready               1.2     1.2  e00
        \\config_loaded               3.0     1.8  e15
        \\platform_ready              9.0     6.0  e01
        \\gpu_ready                  52.0    43.0  e02
        \\fonts_ready                60.0     8.0  e03
        \\window_created             64.0     4.0  e01
        \\workbench_built            70.0     6.0  e04
        \\first_frame_submitted      78.0     8.0  e04
        \\interactive                80.0     2.0  e04
        \\
        \\OS to main 8.0 ms (process start resolution 10.0 ms)
        \\
        \\owner      ms  budget
        \\e00      1.2     2.0
        \\e15      1.8     5.0
        \\e01     10.0    15.0
        \\e02     43.0    40.0  over
        \\e03      8.0    12.0
        \\e04     16.0    10.0  over
        \\
        \\total 80.0 ms of 150.0 ms budget (main to interactive), presentation estimated
        \\
    , w.buffered());
}

test "startup: persist keeps last 20" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (0..25) |i| try persist(gpa, io, tmp.dir, sample(), @intCast(1_000_000 + i));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const h = readHistory(arena.allocator(), io, tmp.dir);
    try std.testing.expectEqual(@as(usize, history_len), h.len);
    try std.testing.expectEqual(@as(i64, 1_000_024), h[h.len - 1].unix_ms);
    try std.testing.expectEqual(@as(i64, 1_000_005), h[0].unix_ms);
    try std.testing.expectEqual(@as(?u64, 80 * std.time.ns_per_ms), h[0].total_ns);
    try std.testing.expectEqualStrings("process_created", h[0].phases[0].name);
    try std.testing.expectEqual(@as(i64, -8 * std.time.ns_per_ms), h[0].phases[0].ns);
    try std.testing.expectEqual(.warm, launchKind(h, 1_000_100));
    try std.testing.expectEqual(.cold_guess, launchKind(h, 1_000_024 + warm_window_ms));
    try std.testing.expectEqual(.cold_guess, launchKind(&.{}, 0));
}

test {
    _ = @import("process_start.zig");
}
