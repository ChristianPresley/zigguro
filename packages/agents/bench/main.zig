//! Benchmarks for zg_agents; run with `zig build bench` at the repo root.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_agents = @import("zg_agents");
const bench = zg_core.bench;

const runs = zg_agents.runs;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    try registerRuns(b);
}

/// `runs/update_500`: one cost update (copy-on-write record + view
/// publish) with 500 runs; `runs/snapshot`: retain and release the view.
fn registerRuns(b: *bench.Bench) !void {
    const Ctx = struct { reg: *runs.RunRegistry, ids: []runs.RunId };
    const gpa = std.heap.smp_allocator;
    const io = b.io;
    const reg = try runs.RunRegistry.init(gpa, io, null, .{});
    const ids = try gpa.alloc(runs.RunId, 500);
    for (ids, 0..) |*id, i| {
        id.* = try reg.createWithId(.fromInt(@as(u128, i + 1) << 80), .{ .kind = .background, .title = "bench run", .prompt = "p" });
    }
    const ctx: Ctx = .{ .reg = reg, .ids = ids };
    try b.run("runs/update_500", ctx, struct {
        fn f(c: Ctx, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                c.reg.update(c.ids[i % c.ids.len], .{ .cost = .{ .micros = i } }) catch unreachable;
            }
        }
    }.f);
    try b.run("runs/snapshot", ctx, struct {
        fn f(c: Ctx, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                const v = c.reg.snapshot();
                bench.doNotOptimizeAway(v.runs.len);
                c.reg.release(v);
            }
        }
    }.f);
    reg.deinit();
    gpa.free(ids);
}
