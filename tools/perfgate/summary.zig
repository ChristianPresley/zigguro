//! The Markdown summary perfgate writes for a PR comment and the job
//! summary (E14.F06.S02.T01): a header with the overall verdict, a table
//! of what needs attention (regressions and budget failures), then
//! improvements, then every row inside `<details>`. The output is capped
//! at 1 MiB (GitHub's comment limit is 64 KiB characters, the job summary
//! limit 1 MiB); past the cap the details table is cut with a note.

const std = @import("std");
const compare = @import("compare.zig");

pub const Env = struct {
    machine: []const u8 = "",
    scale: f64 = 1,
    base_ref: []const u8 = "",
    head_ref: []const u8 = "",
    zig: []const u8 = "",
};

pub const max_bytes: usize = 1 << 20;

const header_row = "| bench | budget | base | head | Δ% | p | verdict |\n|---|---|---:|---:|---:|---:|---|\n";

/// Writes the summary of `rows` into `arena` memory, at most `cap` bytes.
pub fn render(arena: std.mem.Allocator, rows: []const compare.Row, env: Env, cap: usize) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    const blocking = compare.blockingCount(rows);
    var counts = std.EnumArray(compare.Verdict, usize).initFill(0);
    for (rows) |r| counts.getPtr(r.verdict).* += 1;

    if (blocking > 0)
        try w.print("## ❌ perfgate: {d} blocking\n\n", .{blocking})
    else if (counts.get(.regressed) + counts.get(.budget_fail) + counts.get(.budget_warn) > 0)
        try w.writeAll("## ⚠️ perfgate: pass with warnings\n\n")
    else
        try w.writeAll("## ✅ perfgate: pass\n\n");
    try w.print("{d} benches: {d} regressed, {d} improved, {d} noisy, {d} missing, {d} budget failures, {d} budget warnings.\n\n", .{
        rows.len,             counts.get(.regressed),   counts.get(.improved),    counts.get(.noisy),
        counts.get(.missing), counts.get(.budget_fail), counts.get(.budget_warn),
    });
    try w.print("Machine `{s}`, calibration scale {d:.2}", .{ env.machine, env.scale });
    if (env.zig.len > 0) try w.print(", Zig {s}", .{env.zig});
    if (env.base_ref.len > 0) try w.print(", base `{s}`", .{env.base_ref});
    if (env.head_ref.len > 0) try w.print(", head `{s}`", .{env.head_ref});
    try w.writeAll(".\n\n");

    const attention = [_]compare.Verdict{ .regressed, .budget_fail, .budget_warn };
    if (counts.get(.regressed) + counts.get(.budget_fail) + counts.get(.budget_warn) > 0) {
        try w.writeAll("### Needs attention\n\n" ++ header_row);
        for (rows) |r| for (attention) |v| if (r.verdict == v) try writeRow(w, r);
        try w.writeAll("\n");
        for (rows) |r| for (attention) |v| if (r.verdict == v and r.note.len > 0)
            try w.print("- `{s}/{s}`: {s}\n", .{ r.suite, r.name, r.note });
        try w.writeAll("\n");
    }
    if (counts.get(.improved) > 0) {
        try w.writeAll("### Improvements\n\n" ++ header_row);
        for (rows) |r| if (r.verdict == .improved) try writeRow(w, r);
        try w.writeAll("\n");
    }

    const tail = "\n</details>\n";
    const cut_note = "\n_Truncated: the summary reached its size limit; see the JSON artifact for every row._\n";
    try w.writeAll("<details><summary>All benches</summary>\n\n" ++ header_row);
    var row_buf: std.Io.Writer.Allocating = .init(arena);
    for (rows) |r| {
        row_buf.clearRetainingCapacity();
        try writeRow(&row_buf.writer, r);
        if (aw.written().len + row_buf.written().len + tail.len + cut_note.len > cap) {
            try w.writeAll(cut_note);
            break;
        }
        try w.writeAll(row_buf.written());
    }
    try w.writeAll(tail);
    return aw.written();
}

fn writeRow(w: *std.Io.Writer, r: compare.Row) !void {
    try w.print("| `{s}/{s}` | {s} | ", .{ r.suite, r.name, r.budget_id orelse "" });
    try ns(w, r.base_median_ns);
    try w.writeAll(" | ");
    try ns(w, r.head_median_ns);
    try w.writeAll(" | ");
    if (r.delta_pct) |d| try w.print("{s}{d:.1}", .{ if (d > 0) "+" else "", d }) else try w.writeAll("–");
    try w.writeAll(" | ");
    if (r.p_value) |p| (if (p < 0.001) try w.writeAll("<0.001") else try w.print("{d:.3}", .{p})) else try w.writeAll("–");
    try w.print(" | {s}{s} |\n", .{ verdictLabel(r.verdict), if (r.blocking) " (blocking)" else "" });
}

fn ns(w: *std.Io.Writer, v: ?f64) !void {
    const x = v orelse return w.writeAll("–");
    if (x >= 1e9) return w.print("{d:.2} s", .{x / 1e9});
    if (x >= 1e6) return w.print("{d:.2} ms", .{x / 1e6});
    if (x >= 1e3) return w.print("{d:.2} µs", .{x / 1e3});
    return w.print("{d:.1} ns", .{x});
}

pub fn verdictLabel(v: compare.Verdict) []const u8 {
    return switch (v) {
        .pass => "pass",
        .regressed => "🔴 regressed",
        .improved => "🟢 improved",
        .noisy => "noisy",
        .missing => "missing",
        .budget_fail => "🔴 over budget",
        .budget_warn => "🟡 over budget (scaled)",
    };
}

test "summary: golden markdown" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const rows = [_]compare.Row{
        .{ .suite = "zg_t", .name = "fast", .budget_id = "t.fast", .base_median_ns = 500, .head_median_ns = 575, .delta_pct = 15, .p_value = 0.0006, .verdict = .regressed, .gate = .block, .blocking = true },
        .{ .suite = "zg_t", .name = "slow", .base_median_ns = 2.5e6, .head_median_ns = 2e6, .delta_pct = -20, .p_value = 0.004, .verdict = .improved },
    };
    const md = try render(arena.allocator(), &rows, .{ .machine = "ci_linux_x64" }, max_bytes);
    const expected =
        \\## ❌ perfgate: 1 blocking
        \\
        \\2 benches: 1 regressed, 1 improved, 0 noisy, 0 missing, 0 budget failures, 0 budget warnings.
        \\
        \\Machine `ci_linux_x64`, calibration scale 1.00.
        \\
        \\### Needs attention
        \\
        \\| bench | budget | base | head | Δ% | p | verdict |
        \\|---|---|---:|---:|---:|---:|---|
        \\| `zg_t/fast` | t.fast | 500.0 ns | 575.0 ns | +15.0 | <0.001 | 🔴 regressed (blocking) |
        \\
        \\
        \\### Improvements
        \\
        \\| bench | budget | base | head | Δ% | p | verdict |
        \\|---|---|---:|---:|---:|---:|---|
        \\| `zg_t/slow` |  | 2.50 ms | 2.00 ms | -20.0 | 0.004 | 🟢 improved |
        \\
        \\<details><summary>All benches</summary>
        \\
        \\| bench | budget | base | head | Δ% | p | verdict |
        \\|---|---|---:|---:|---:|---:|---|
        \\| `zg_t/fast` | t.fast | 500.0 ns | 575.0 ns | +15.0 | <0.001 | 🔴 regressed (blocking) |
        \\| `zg_t/slow` |  | 2.50 ms | 2.00 ms | -20.0 | 0.004 | 🟢 improved |
        \\
        \\</details>
        \\
    ;
    try std.testing.expectEqualStrings(expected, md);
}

test "summary: size cap truncates details" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try a.alloc(compare.Row, 5000);
    for (rows, 0..) |*r, i| r.* = .{ .suite = "zg_t", .name = try std.fmt.allocPrint(a, "bench_{d}", .{i}), .base_median_ns = 100, .head_median_ns = 100, .delta_pct = 0, .p_value = 0.5 };
    const md = try render(a, rows, .{ .machine = "m" }, 64 * 1024);
    try std.testing.expect(md.len <= 64 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, md, "Truncated") != null);
    try std.testing.expect(std.mem.endsWith(u8, md, "</details>\n"));
}
