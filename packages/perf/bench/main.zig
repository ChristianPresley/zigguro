//! Benchmarks for zg_perf; run with `zig build bench` at the repo root.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_perf = @import("zg_perf");
const bench = zg_core.bench;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    try b.run("perf.budget_evaluate", {}, struct {
        fn f(_: void, s: *bench.State) void {
            const budget = zg_perf.budget.get("input.key_to_photon");
            var x: f64 = 0;
            for (0..s.iterations()) |i| {
                x += @floatFromInt(@intFromEnum(zg_perf.budget.evaluate(budget, @floatFromInt(i & 0xffffff), 1.0).verdict));
            }
            bench.doNotOptimizeAway(x);
        }
    }.f);
    try b.run("perf.shadow_push_pop", {}, struct {
        fn f(_: void, s: *bench.State) void {
            var st: zg_perf.runtime.ShadowStack = .{};
            const site = zg_core.trace.siteFor(@src(), "bench");
            for (0..s.iterations()) |_| {
                st.push(site);
                st.pop();
            }
            bench.doNotOptimizeAway(&st);
        }
    }.f);
    // With -Dtracing=zones: a zone with and without the shadow-stack hook
    // (the difference is the hook's cost, budget < 5 ns).
    try b.run("perf.zone_no_hook", {}, struct {
        fn f(_: void, s: *bench.State) void {
            for (0..s.iterations()) |_| zg_core.trace.zone(@src(), "bench").end();
            drainTrace();
        }
    }.f);
    try b.run("perf.zone_hook_overhead", {}, struct {
        fn f(_: void, s: *bench.State) void {
            _ = zg_perf.runtime.shadow_stack.enableForCurrentThread();
            defer zg_core.trace.zone_hook = null;
            for (0..s.iterations()) |_| zg_core.trace.zone(@src(), "bench").end();
            drainTrace();
        }
    }.f);
    // Tracked allocation (E14.F04.S01.T01): the overhead is the
    // difference between these two (budget < 5 ns).
    try b.run("perf.smp_alloc_free", {}, struct {
        fn f(_: void, s: *bench.State) void {
            allocFree(std.heap.smp_allocator, s);
        }
    }.f);
    try b.run("perf.tracked_alloc_overhead", {}, struct {
        fn f(_: void, s: *bench.State) void {
            var st: zg_perf.mem.TrackedAllocator = undefined;
            allocFree(zg_perf.mem.trackedWith(&st, .perf, std.heap.smp_allocator), s);
        }
    }.f);
    // One memory sample: /proc reads, tag sums, GPU query (budget
    // < 200 us, E14.F04.S01.T02).
    try b.run("perf.mem_sample", {}, struct {
        fn f(_: void, s: *bench.State) void {
            var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            var scratch: [32 * 1024]u8 = undefined;
            for (0..s.iterations()) |_| {
                const snap = zg_perf.mem.sampler.takeSnapshot(threaded.io(), &scratch);
                bench.doNotOptimizeAway(snap.t_ns);
            }
        }
    }.f);
    // A first startup mark: clock read, CAS, trace instant (budget
    // < 50 ns, E14.F05.S01.T01).
    try b.run("perf.startup_mark", {}, struct {
        fn f(_: void, s: *bench.State) void {
            var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            var t: zg_perf.startup.StartupTimeline = .{ .io = threaded.io() };
            const i = @intFromEnum(zg_perf.startup.Phase.workbench_built);
            for (0..s.iterations()) |_| {
                t.marks[i].store(0, .monotonic);
                t.mark(.workbench_built);
            }
            bench.doNotOptimizeAway(t.marks[i].load(.monotonic));
        }
    }.f);
    try b.run("perf.activity_level", {}, struct {
        fn f(_: void, s: *bench.State) void {
            var sig: zg_perf.ActivitySignal = .{};
            sig.publish(.interactive, 1000);
            var x: usize = 0;
            for (0..s.iterations()) |_| x += @intFromEnum(sig.publishedLevel());
            bench.doNotOptimizeAway(x);
        }
    }.f);
    try b.run("perf.histogram_record", {}, struct {
        fn f(_: void, s: *bench.State) void {
            var h: zg_perf.frame.LatencyHistogram = .{};
            var x: u64 = 0x9e3779b97f4a7c15;
            for (0..s.iterations()) |_| {
                x = x *% 6364136223846793005 +% 1442695040888963407;
                h.record(x >> 36);
            }
            bench.doNotOptimizeAway(&h);
        }
    }.f);
    try b.run("perf.timeline_frame", {}, struct {
        fn f(_: void, s: *bench.State) void {
            var t = zg_perf.frame.FrameTimeline.init(std.heap.page_allocator, 1024) catch unreachable;
            defer t.deinit();
            for (0..s.iterations()) |i| {
                const seq: u64 = i + 1;
                const t0: u64 = seq * 8_333_333;
                t.onFrameStats(.{ .seq = seq, .t_input_ns = t0, .input_kind = .key, .t_frame_start_ns = t0 + 100_000, .build_ns = 300_000, .t_submit_ns = t0 + 1_000_000, .present_id = seq });
                t.onPresented(seq, t0 + 4_000_000, 0);
            }
            bench.doNotOptimizeAway(&t.key_to_photon);
        }
    }.f);
    try b.run("perf.async_span_pair", {}, struct {
        fn f(_: void, s: *bench.State) void {
            for (0..s.iterations()) |_| {
                const span = zg_perf.trace.async_span.Span.begin(.lsp_request);
                span.end();
            }
            drainTrace();
        }
    }.f);
    try b.run("perf.budget_by_id", {}, struct {
        fn f(_: void, s: *bench.State) void {
            for (0..s.iterations()) |_| bench.doNotOptimizeAway(zg_perf.budget.byId("agents.notification_route"));
        }
    }.f);
    // One op exports 1 M zone events (2 M slice events) to Perfetto.
    const corpus = try zg_perf.@"export".perfetto.syntheticZones(std.heap.page_allocator, 1_000_000);
    defer std.heap.page_allocator.free(corpus);
    try b.run("perf.perfetto_export_1m", corpus, struct {
        fn f(evs: []const zg_core.trace.Event, s: *bench.State) void {
            var buf: [64 * 1024]u8 = undefined;
            for (0..s.iterations()) |_| {
                var sink: std.Io.Writer.Discarding = .init(&buf);
                var w = zg_perf.@"export".perfetto.Writer.init(std.heap.page_allocator, &sink.writer, .{});
                defer w.deinit();
                w.writeEvents(evs) catch unreachable;
                w.finish() catch unreachable;
                bench.doNotOptimizeAway(sink.fullCount());
            }
        }
    }.f);
}

/// Keeps the trace rings from filling (dropped events are cheaper and
/// would flatter the zone benches).
fn drainTrace() void {
    if (!zg_core.trace.enabled) return;
    var events: std.ArrayList(zg_core.trace.Event) = .empty;
    defer events.deinit(std.heap.page_allocator);
    zg_core.trace.collect(std.heap.page_allocator, &events) catch {};
}

fn allocFree(a: std.mem.Allocator, s: *bench.State) void {
    for (0..s.iterations()) |i| {
        const buf = a.alloc(u8, 32 + (i & 31)) catch return;
        bench.doNotOptimizeAway(buf.ptr);
        a.free(buf);
    }
}
