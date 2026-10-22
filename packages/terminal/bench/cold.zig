//! Cold scrollback benchmarks (E06.F03.S02.T01): encode and decode speed
//! in bytes of hot cells (8 per cell), raw and deflated, on the corpora,
//! with each corpus's size per cell logged.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_terminal = @import("zg_terminal");
const corpus_gen = @import("corpus_gen.zig");
const screen = zg_terminal.screen;
const cold = screen.cold;
const bench = zg_core.bench;

const log = std.log.scoped(.bench_cold);

const cols = 200;
/// Rows encoded per operation (about one hot page's worth at 200 columns).
const target_rows = 4000;

const Ctx = struct { first: screen.Pin, rows: u64, deflate: bool };

fn encode(ctx: *const Ctx, s: *bench.State) void {
    const gpa = s.allocator();
    s.setBytes(ctx.rows * cols * @sizeOf(screen.Cell));
    for (0..s.iterations()) |_| {
        var cp = cold.encode(gpa, ctx.first, ctx.rows, .{ .deflate = ctx.deflate }) catch unreachable;
        bench.doNotOptimizeAway(cp.blob.ptr);
        cp.deinit(gpa);
    }
}

const DecodeCtx = struct { page: *const cold.ColdPage, rows: u64 };

fn decode(ctx: *const DecodeCtx, s: *bench.State) void {
    const gpa = s.allocator();
    s.setBytes(ctx.rows * cols * @sizeOf(screen.Cell));
    for (0..s.iterations()) |_| {
        var pl = screen.PageList.init(gpa, cols, 1, .{ .max_bytes = 1 << 30 }) catch unreachable;
        ctx.page.decode(gpa, &pl) catch unreachable;
        bench.doNotOptimizeAway(pl.total);
        pl.deinit();
    }
}

/// The first `target_rows` or so hot rows, cut at a line end.
fn wholeLines(pl: *const screen.PageList) u64 {
    var p = pl.firstHot();
    var end: u64 = 0;
    var i: u64 = 0;
    while (i < target_rows) : (i += 1) {
        if (!p.row().wrap) end = i + 1;
        p = screen.PageList.next(p) orelse break;
    }
    return end;
}

/// Whether the filter keeps any benchmark of corpus `c` (setup is slow).
fn wanted(b: *const bench.Bench, c: corpus_gen.Corpus) !bool {
    const f = b.opts.filter orelse return true;
    var name: [96]u8 = undefined;
    for ([_][]const u8{ "encode", "decode" }) |op| for ([_][]const u8{ "", ".deflate" }) |suffix| {
        if (std.mem.indexOf(u8, try std.fmt.bufPrint(&name, "terminal.cold.{s}.{t}{s}", .{ op, c, suffix }), f) != null) return true;
    };
    return false;
}

/// Registers the cold page benchmarks.
pub fn register(b: *bench.Bench) !void {
    const gpa = b.gpa;
    const corpora = [_]corpus_gen.Corpus{ .ascii_lines, .unicode_mixed, .sgr_heavy };
    for (corpora) |c| {
        var name: [96]u8 = undefined;
        if (!try wanted(b, c)) continue;
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        try corpus_gen.generate(c, 2 << 20, 0xc01d, &data, gpa);
        var t = try zg_terminal.Terminal.init(gpa, .{ .cols = cols, .rows = 50, .max_scrollback_bytes = 1 << 30 });
        defer t.deinit();
        t.feed(data.items);
        const pl = &t.primary.pages;
        const rows = wholeLines(pl);
        if (rows == 0) continue;

        var raw = try cold.encode(gpa, pl.firstHot(), rows, .{ .deflate = false });
        defer raw.deinit(gpa);
        var packed_page = try cold.encode(gpa, pl.firstHot(), rows, .{ .deflate = true });
        defer packed_page.deinit(gpa);
        const cells: f64 = @floatFromInt(rows * cols);
        log.info("{t}: {d} rows, {d:.3} B/cell raw, {d:.3} B/cell deflated", .{
            c,
            rows,
            @as(f64, @floatFromInt(raw.bytesUsed())) / cells,
            @as(f64, @floatFromInt(packed_page.bytesUsed())) / cells,
        });

        const enc_raw: Ctx = .{ .first = pl.firstHot(), .rows = rows, .deflate = false };
        try b.run(try std.fmt.bufPrint(&name, "terminal.cold.encode.{t}", .{c}), &enc_raw, encode);
        const enc_flate: Ctx = .{ .first = pl.firstHot(), .rows = rows, .deflate = true };
        try b.run(try std.fmt.bufPrint(&name, "terminal.cold.encode.{t}.deflate", .{c}), &enc_flate, encode);
        const dec_raw: DecodeCtx = .{ .page = &raw, .rows = rows };
        try b.run(try std.fmt.bufPrint(&name, "terminal.cold.decode.{t}", .{c}), &dec_raw, decode);
        const dec_flate: DecodeCtx = .{ .page = &packed_page, .rows = rows };
        try b.run(try std.fmt.bufPrint(&name, "terminal.cold.decode.{t}.deflate", .{c}), &dec_flate, decode);
    }
}
