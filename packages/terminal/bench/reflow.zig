//! Resize benchmarks (E06.F03.S02.T02): one resize per operation,
//! alternating between 80 and 200 columns, of 10k hot rows of 200 cells,
//! and of 1M cold lines (which only recount their rows).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_terminal = @import("zg_terminal");
const bench = zg_core.bench;

const Ctx = struct { t: *zg_terminal.Terminal };

fn resize(ctx: *const Ctx, s: *bench.State) void {
    for (0..s.iterations()) |_| {
        const to: u16 = if (ctx.t.cols() == 200) 80 else 200;
        ctx.t.resize(to, 50) catch unreachable;
        bench.doNotOptimizeAway(ctx.t.primary.pages.totalRows());
    }
}

fn wanted(b: *const bench.Bench, name: []const u8) bool {
    const f = b.opts.filter orelse return true;
    return std.mem.indexOf(u8, name, f) != null;
}

/// Registers the resize benchmarks.
pub fn register(b: *bench.Bench) !void {
    const gpa = b.gpa;
    var line: [256]u8 = undefined;
    if (wanted(b, "terminal.reflow.hot_10k")) {
        // Everything stays hot: 10k full 200-cell rows.
        var t = try zg_terminal.Terminal.init(gpa, .{ .cols = 200, .rows = 50, .hot_scrollback_rows = 0, .max_scrollback_bytes = 1 << 30 });
        defer t.deinit();
        for (0..10_000) |i| {
            @memset(line[0..200], 'a' + @as(u8, @intCast(i % 26)));
            t.feed(line[0..200]);
            t.feed("\r\n");
        }
        const ctx: Ctx = .{ .t = &t };
        try b.run("terminal.reflow.hot_10k", &ctx, resize);
    }
    if (wanted(b, "terminal.reflow.cold_1m")) {
        var t = try zg_terminal.Terminal.init(gpa, .{ .cols = 200, .rows = 50, .hot_scrollback_rows = 1000, .max_scrollback_bytes = 1 << 30 });
        defer t.deinit();
        for (0..1_000_000) |i| t.feed(std.fmt.bufPrint(&line, "{d} some output on a line of its own\r\n", .{i}) catch unreachable);
        const ctx: Ctx = .{ .t = &t };
        try b.run("terminal.reflow.cold_1m", &ctx, resize);
    }
}
