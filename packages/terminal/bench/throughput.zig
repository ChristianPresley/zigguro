//! Throughput benchmarks: parser-only over each corpus with `NullHandler`,
//! whole and in 64 KiB chunks as the session pump feeds it.
//! Parse+apply benches join once the `Terminal` executor (E06.F02.S02) lands.

const std = @import("std");
const zg_core = @import("zg_core");
const vt = @import("zg_terminal").vt;
const corpus_gen = @import("corpus_gen.zig");
const bench = zg_core.bench;

/// Corpus size per benchmark (the spec's 64 MiB in full runs; 8 MiB keeps the
/// adaptive harness's sample count reasonable).
pub const corpus_bytes = 8 << 20;

const Ctx = struct { data: []const u8, chunk: usize };

fn parseOnly(ctx: *const Ctx, s: *bench.State) void {
    s.setBytes(ctx.data.len);
    var p: vt.Parser = .init(s.allocator(), .{});
    defer p.deinit();
    var h: vt.NullHandler = .{};
    for (0..s.iterations()) |_| {
        var i: usize = 0;
        while (i < ctx.data.len) {
            const n = @min(ctx.chunk, ctx.data.len - i);
            p.feed(ctx.data[i..][0..n], &h);
            i += n;
        }
    }
    bench.doNotOptimizeAway(h.count);
}

fn scanOnly(data: []const u8, s: *bench.State) void {
    s.setBytes(data.len);
    var total: usize = 0;
    for (0..s.iterations()) |_| {
        var d = data;
        std.mem.doNotOptimizeAway(&d);
        total += vt.fast_path.scanPrintable(d);
    }
    bench.doNotOptimizeAway(total);
}

/// Registers the throughput benchmarks.
pub fn register(b: *bench.Bench) !void {
    const gpa = b.gpa;
    var printable: [1 << 20]u8 = undefined;
    @memset(&printable, 'a');
    try b.run("terminal.scan_printable 1 MiB", @as([]const u8, &printable), scanOnly);
    for (std.enums.values(corpus_gen.Corpus)) |c| {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        try corpus_gen.generate(c, corpus_bytes, 0x7e57, &data, gpa);
        const whole: Ctx = .{ .data = data.items, .chunk = data.items.len };
        var name: [96]u8 = undefined;
        try b.run(try std.fmt.bufPrint(&name, "terminal.throughput.parser.{t}", .{c}), &whole, parseOnly);
        const chunked: Ctx = .{ .data = data.items, .chunk = 64 << 10 };
        try b.run(try std.fmt.bufPrint(&name, "terminal.throughput.parser.{t}.64k", .{c}), &chunked, parseOnly);
    }
}
