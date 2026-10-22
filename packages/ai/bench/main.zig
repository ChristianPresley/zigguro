//! Benchmarks for zg_ai; run with `zig build bench` at the repo root.

const std = @import("std");
const zg_core = @import("zg_core");
const ai = @import("zg_ai");
const bench = zg_core.bench;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    var reg = ai.ModelRegistry.init(b.gpa, b.io, ai.models.registry.builtin_catalog);
    defer reg.deinit();
    _ = try reg.snapshot();
    // Budget: < 200 ns (E10.F04.S01.T01).
    try b.run("ai.registry_resolve: resolve an alias through the snapshot", &reg, struct {
        fn f(r: *ai.ModelRegistry, s: *bench.State) void {
            for (0..s.iterations()) |i| {
                const name: []const u8 = if (i & 1 == 0) "sonnet" else "claude-opus-5-5";
                bench.doNotOptimizeAway(r.resolve(name));
            }
        }
    }.f);
    const price = reg.resolve("haiku").?.price.?;
    try b.run("ai.cost_of: price one request with tiers", price, struct {
        fn f(p: ai.models.pricing.Price, s: *bench.State) void {
            for (0..s.iterations()) |i| {
                var u: ai.proto.Usage = .{ .input = 1000 + i, .cache_read = 120_000, .output = 800 };
                bench.doNotOptimizeAway(&u);
                bench.doNotOptimizeAway(ai.models.pricing.costOf(p, u));
            }
        }
    }.f);
    var ledger = ai.CostLedger.init(b.gpa, b.io);
    defer ledger.deinit();
    const model = reg.resolve("sonnet").?;
    // Budget: < 1 µs hold time (E10.F04.S01.T02).
    try b.run("ai.ledger_record: record one request (uncontended)", .{ &ledger, model }, struct {
        fn f(ctx: struct { *ai.CostLedger, *const ai.models.registry.ModelInfo }, s: *bench.State) void {
            for (0..s.iterations()) |i| _ = ctx[0].record(.{ .session = i % 4 }, ctx[1], .{ .input = 100, .output = 10 }, false) catch unreachable;
        }
    }.f);
    var schemas: ai.tools.invoke.Schemas = .init(b.gpa, b.io, ai.schema.validate.permissive());
    defer schemas.deinit();
    var dummy: u8 = 0;
    const spec: ai.proto.ToolSpec = .{ .name = "noop", .description = "", .input_schema_json = "{\"type\":\"object\"}", .read_only = true, .handler = .{ .ctx = &dummy, .call = struct {
        fn f(_: *anyopaque, c: *ai.proto.ToolCall) ai.proto.ToolError!ai.proto.ToolOutput {
            return ai.proto.ToolOutput.text(c.arena, "ok", false);
        }
    }.f } };
    const pipeline: ai.tools.invoke.Pipeline = .{ .schemas = &schemas };
    // Budget: < 1 ms with no hooks and an allow decision (E10.F06.S01.T02).
    try b.run("ai.invoke_overhead: one call through the invoke pipeline", .{ &pipeline, &spec, b.gpa, b.io }, struct {
        fn f(ctx: struct { *const ai.tools.invoke.Pipeline, *const ai.proto.ToolSpec, std.mem.Allocator, std.Io }, s: *bench.State) void {
            var arena: std.heap.ArenaAllocator = .init(ctx[2]);
            defer arena.deinit();
            for (0..s.iterations()) |_| {
                _ = arena.reset(.retain_capacity);
                bench.doNotOptimizeAway(ai.tools.invoke.invoke(ctx[0], ctx[3], arena.allocator(), .{ .id = "toolu_1", .spec = ctx[1], .input_json = "{\"path\":\"src/main.zig\",\"limit\":20}" }));
            }
        }
    }.f);
}
