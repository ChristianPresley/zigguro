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
    // A 1 MiB docs-like page.
    var page: std.ArrayList(u8) = .empty;
    defer page.deinit(b.gpa);
    try page.appendSlice(b.gpa, "<html><head><title>t</title><script>var x = 1 < 2;</script></head><body><nav><a href=\"/\">Home</a></nav><main>");
    const section =
        \\<h2 id="s{d}">Section {d}</h2><p>Some <em>prose</em> with a <a href="../ref/{d}.html">link</a> &amp; an entity, and <code>inline()</code> code.</p>
        \\<ul><li>first item</li><li>second <b>item</b><ul><li>nested</li></ul></li></ul>
        \\<pre><code class="language-zig">const x = foo({d});
        \\</code></pre><table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>
        \\
    ;
    var i: usize = 0;
    while (page.items.len < 1 << 20) : (i += 1) try page.print(b.gpa, section, .{ i, i, i, i });
    try page.appendSlice(b.gpa, "</main><footer>&copy; 2026</footer></body></html>");
    // Budget: >= 50 MB/s (E10.F06.S03.T03).
    try b.run("ai.html2md: convert a 1 MiB page", .{ page.items, b.gpa }, struct {
        fn f(ctx: struct { []const u8, std.mem.Allocator }, s: *bench.State) void {
            s.setBytes(ctx[0].len);
            var arena: std.heap.ArenaAllocator = .init(ctx[1]);
            defer arena.deinit();
            for (0..s.iterations()) |_| {
                _ = arena.reset(.retain_capacity);
                bench.doNotOptimizeAway(ai.tools.builtin.html2md.htmlToMarkdown(arena.allocator(), ctx[0], "https://example.com/docs/page.html", .{ .max_bytes = 4 << 20 }) catch unreachable);
            }
        }
    }.f);

    // Budget: < 5 ms per subagent, spawn to report (E10.F09.S01.T01).
    var sub: SubagentBench = undefined;
    try sub.init(b.gpa, b.io, &reg);
    defer sub.deinit();
    try b.run("ai.subagent_spawn: spawn a child, one model call, report", &sub, struct {
        fn f(x: *SubagentBench, s: *bench.State) void {
            var arena: std.heap.ArenaAllocator = .init(x.gpa);
            defer arena.deinit();
            for (0..s.iterations()) |_| {
                _ = arena.reset(.retain_capacity);
                const child = x.runner.spawn(x.parent, ai.subagent.defs.find(x.defs.items, "general").?, "Report.", .{}) catch unreachable;
                bench.doNotOptimizeAway(x.runner.awaitReport(x.io, arena.allocator(), child) catch unreachable);
            }
        }
    }.f);
}

/// A parent agent and a runner whose children get an instant answer.
const SubagentBench = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    provider: ai.Provider,
    tools: ai.tools.ToolRegistry,
    main_tools: ai.tools.AgentTools,
    mgr: *ai.loop.AgentManager,
    arena: std.heap.ArenaAllocator,
    defs: std.ArrayList(ai.subagent.defs.AgentDef),
    runner: ai.subagent.SubagentRunner,
    parent: *ai.loop.Agent,

    fn init(x: *SubagentBench, gpa: std.mem.Allocator, io: std.Io, reg: *ai.ModelRegistry) !void {
        x.* = .{ .gpa = gpa, .io = io, .provider = .{ .ptr = x, .vtable = &.{ .stream = answer, .deinit = noop }, .id = .scripted, .caps = .all }, .tools = .init(gpa, io), .main_tools = undefined, .mgr = undefined, .arena = .init(gpa), .defs = .empty, .runner = undefined, .parent = undefined };
        x.main_tools = .init(gpa, io, &x.tools, .{});
        x.mgr = try ai.loop.AgentManager.init(gpa, io, .{ .registry = reg, .providers = .fixed(&x.provider), .tools = x.main_tools.tools() });
        try ai.subagent.defs.loadDefs(io, x.arena.allocator(), &.{}, &x.defs, null);
        x.runner = .init(gpa, io, x.mgr, &x.tools, x.defs.items, .{});
        x.parent = try x.mgr.create(.{ .model = "sonnet" });
    }

    fn deinit(x: *SubagentBench) void {
        x.runner.deinit();
        x.mgr.deinit();
        x.main_tools.deinit();
        x.tools.deinit();
        x.arena.deinit();
    }

    fn noop(_: *anyopaque) void {}

    fn answer(_: *anyopaque, _: std.Io, arena: std.mem.Allocator, _: *const ai.request.Request, sink: ai.events.EventSink) ai.Provider.StreamError!ai.request.Response {
        const evs = [_]ai.events.StreamEvent{
            .{ .message_start = .{ .id = "msg", .model = "sonnet" } },
            .{ .block_start = .{ .index = 0, .kind = .text } },
            .{ .text_delta = .{ .index = 0, .text = "Done." } },
            .{ .block_stop = .{ .index = 0 } },
            .{ .usage = .{ .input = 10, .output = 2 } },
            .{ .stop = .end_turn },
        };
        var asm_: ai.MessageAssembler = .init(arena);
        for (evs) |e| {
            asm_.feed(e) catch return error.Protocol;
            sink.send(e);
        }
        return .{ .message = asm_.finish() catch return error.Protocol, .stop = .end_turn, .usage = asm_.usage };
    }
};
