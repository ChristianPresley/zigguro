//! Memory reports (E14.F04.S01.T02): a human table for `--mem-report` and
//! the `perf.memory.report` command, and JSON for scenarios.

const std = @import("std");
const tags = @import("tags.zig");
const sampler = @import("sampler.zig");

const Snapshot = sampler.Snapshot;

/// Writes `bytes` as B, KiB, MiB or GiB with one decimal.
pub fn writeBytes(w: *std.Io.Writer, bytes: i64) !void {
    const neg = bytes < 0;
    const b: u64 = @abs(bytes);
    const sign: []const u8 = if (neg) "-" else "";
    if (b < 1024) return w.print("{s}{d} B", .{ sign, b });
    const units = [_][]const u8{ "KiB", "MiB", "GiB", "TiB" };
    var unit: usize = 0;
    var div: u64 = 1024;
    while (unit + 1 < units.len and b >= div * 1024) : (unit += 1) div *= 1024;
    // Tenths, rounded.
    const tenths = (b * 10 + div / 2) / div;
    try w.print("{s}{d}.{d} {s}", .{ sign, tenths / 10, tenths % 10, units[unit] });
}

fn bytesCell(w: *std.Io.Writer, bytes: i64, width: usize) !void {
    var buf: [32]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&buf);
    try writeBytes(&fw, bytes);
    const s = fw.buffered();
    try w.splatByteAll(' ', width -| s.len);
    try w.writeAll(s);
}

/// The human table: tag | live | peak | allocs, then process and GPU
/// totals and the untracked remainder (`private - sum of tags`).
pub fn writeReport(s: Snapshot, w: *std.Io.Writer) !void {
    try w.writeAll("tag             live        peak      allocs\n");
    for (s.tags[0..tags.tag_count], 0..) |t, i| {
        if (t.allocs == 0 and t.live == 0) continue;
        const name = tags.name(@enumFromInt(i));
        try w.writeAll(name);
        try w.splatByteAll(' ', 10 -| name.len);
        try bytesCell(w, t.live, 10);
        try bytesCell(w, @intCast(t.peak), 12);
        try w.print("{d:>12}\n", .{t.allocs});
    }
    try w.writeAll("tagged    ");
    try bytesCell(w, s.taggedLive(), 10);
    try w.writeAll("\n\n");
    if (s.process) |p| {
        try w.writeAll("process   private ");
        try writeBytes(w, @intCast(p.private_bytes));
        try w.writeAll(", rss ");
        try writeBytes(w, @intCast(p.rss_bytes));
        if (p.pss_bytes) |pss| {
            try w.writeAll(", pss ");
            try writeBytes(w, @intCast(pss));
        }
        try w.writeAll(", peak rss ");
        try writeBytes(w, @intCast(p.peak_rss_bytes));
        try w.writeAll("\n");
    } else try w.writeAll("process   unavailable\n");
    if (s.gpu) |g| {
        try w.writeAll("gpu       used ");
        try writeBytes(w, @intCast(g.device_local_used));
        if (g.device_local_budget != 0) {
            try w.writeAll(" of ");
            try writeBytes(w, @intCast(g.device_local_budget));
        }
        try w.writeAll(", tagged ");
        try writeBytes(w, @intCast(g.taggedTotal()));
        try w.writeAll("\n");
    } else try w.writeAll("gpu       unavailable\n");
    if (s.untracked()) |u| {
        try w.writeAll("untracked ");
        try writeBytes(w, u);
        try w.writeAll(" (private - tagged)\n");
    }
}

/// The snapshot as one JSON object (schema 1) for scenario results.
pub fn writeReportJson(s: Snapshot, w: *std.Io.Writer) !void {
    try w.print("{{\"schema\":1,\"t_ns\":{d},\"sample\":{d},\"process\":", .{ s.t_ns, s.sample });
    if (s.process) |p| {
        try w.print("{{\"private_bytes\":{d},\"rss_bytes\":{d},\"peak_rss_bytes\":{d}", .{ p.private_bytes, p.rss_bytes, p.peak_rss_bytes });
        inline for (.{ "pss_bytes", "anon_bytes", "file_bytes", "commit_bytes" }) |f| {
            if (@field(p, f)) |v| try w.print(",\"" ++ f ++ "\":{d}", .{v});
        }
        try w.writeAll("}");
    } else try w.writeAll("null");
    try w.writeAll(",\"gpu\":");
    if (s.gpu) |g| {
        try w.print("{{\"device_local_used\":{d},\"device_local_budget\":{d},\"host_visible_used\":{d},\"tagged\":{d}}}", .{ g.device_local_used, g.device_local_budget, g.host_visible_used, g.taggedTotal() });
    } else try w.writeAll("null");
    try w.writeAll(",\"tags\":{");
    var first = true;
    for (s.tags[0..tags.tag_count], 0..) |t, i| {
        if (t.allocs == 0 and t.live == 0) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("\"{s}\":{{\"live\":{d},\"peak\":{d},\"allocs\":{d},\"frees\":{d}}}", .{ tags.name(@enumFromInt(i)), t.live, t.peak, t.allocs, t.frees });
    }
    try w.print("}},\"tagged_live\":{d}", .{s.taggedLive()});
    if (s.untracked()) |u| try w.print(",\"untracked\":{d}", .{u});
    try w.writeAll("}");
}

fn goldenSnapshot() Snapshot {
    var s: Snapshot = .{ .t_ns = 5_000_000_000, .sample = 3 };
    s.process = .{ .private_bytes = 64 << 20, .rss_bytes = 96 << 20, .pss_bytes = 80 << 20, .peak_rss_bytes = 100 << 20 };
    s.gpu = .{ .device_local_used = 40 << 20, .device_local_budget = 6 << 30 };
    s.gpu.?.per_tag[0] = 4 << 20;
    s.gpu.?.per_tag[4] = 24 << 20;
    s.tags[@intFromEnum(tags.MemTag.editor)] = .{ .live = 12 << 20, .peak = 13 << 20, .allocs = 4200, .frees = 4000 };
    s.tags[@intFromEnum(tags.MemTag.text)] = .{ .live = 3 << 19, .peak = 2 << 20, .allocs = 90, .frees = 10 };
    s.tags[@intFromEnum(tags.MemTag.perf)] = .{ .live = 512, .peak = 4096, .allocs = 7, .frees = 6 };
    return s;
}

test "report: golden table" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeReport(goldenSnapshot(), &w);
    try std.testing.expectEqualStrings(
        \\tag             live        peak      allocs
        \\text         1.5 MiB     2.0 MiB          90
        \\editor      12.0 MiB    13.0 MiB        4200
        \\perf           512 B     4.0 KiB           7
        \\tagged      13.5 MiB
        \\
        \\process   private 64.0 MiB, rss 96.0 MiB, pss 80.0 MiB, peak rss 100.0 MiB
        \\gpu       used 40.0 MiB of 6.0 GiB, tagged 28.0 MiB
        \\untracked 50.5 MiB (private - tagged)
        \\
    , w.buffered());
}

test "report: json" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeReportJson(goldenSnapshot(), &w);
    const out = w.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 64 << 20), root.get("process").?.object.get("private_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 4200), root.get("tags").?.object.get("editor").?.object.get("allocs").?.integer);
    try std.testing.expectEqual(@as(i64, (64 << 20) - (13 << 20) - (1 << 19) - 512), root.get("untracked").?.integer);
    // Without process or GPU numbers.
    w = .fixed(&buf);
    try writeReportJson(.{}, &w);
    try std.testing.expectEqualStrings("{\"schema\":1,\"t_ns\":0,\"sample\":0,\"process\":null,\"gpu\":null,\"tags\":{},\"tagged_live\":0}", w.buffered());
}

test "report: bytes" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBytes(&w, -(3 << 29));
    try std.testing.expectEqualStrings("-1.5 GiB", w.buffered());
}
