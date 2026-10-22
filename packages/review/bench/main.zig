//! Benchmarks for zg_review; run with `zig build bench` at the repo root.
//! Inputs are generated (seeded), so runs are reproducible.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_review = @import("zg_review");
const bench = zg_core.bench;

const model = zg_review.model;
const ChangeSet = model.changeset.ChangeSet;
const Replace = model.changeset.Replace;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

const Hunks = struct {
    base: []const u8,
    lines: zg_core.LineIndex,
    cs: ChangeSet,
    gpa: std.mem.Allocator,
};

/// 1,000 one-line replaces scattered over a 10k-line file (the
/// `deriveHunks` budget: < 2 ms).
fn register(b: *bench.Bench) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(b.gpa);
    var rng: std.Random.DefaultPrng = .init(0x12e1);
    const r = rng.random();
    var starts: std.ArrayList(u64) = .empty;
    defer starts.deinit(b.gpa);
    for (0..10_000) |_| {
        try starts.append(b.gpa, text.items.len);
        const n = 20 + r.uintLessThan(usize, 80);
        for (0..n) |_| try text.append(b.gpa, "abcdefghijklmnopqrstuvwxyz (){};"[r.uintLessThan(usize, 32)]);
        try text.append(b.gpa, '\n');
    }
    var reps: std.ArrayList(Replace) = .empty;
    defer reps.deinit(b.gpa);
    var line: usize = 0;
    for (0..1_000) |_| {
        line += 1 + r.uintLessThan(usize, 18);
        if (line >= starts.items.len) break;
        const s = starts.items[line] + 2;
        try reps.append(b.gpa, .{ .range = .{ .start = s, .end = s + 3 }, .text = if (r.boolean()) "xyz" else "a\nb" });
    }
    var h: Hunks = .{ .base = text.items, .lines = try .build(b.gpa, text.items), .cs = try .fromEdits(b.gpa, text.items.len, reps.items), .gpa = b.gpa };
    defer h.lines.deinit(b.gpa);
    defer h.cs.deinit();
    try b.run("review.hunks.1k_replaces_10k_lines", &h, struct {
        fn f(x: *Hunks, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                const hs = model.deriveHunks(x.gpa, x.base, &x.lines, &x.cs, .{}) catch unreachable;
                bench.doNotOptimizeAway(hs.len);
                x.gpa.free(hs);
            }
        }
    }.f);
}
