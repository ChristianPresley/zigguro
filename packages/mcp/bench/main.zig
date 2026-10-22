//! zg_mcp benchmarks (`zig build bench`).
//!
//! Budgets (E11 epic): decoding `tools/list` with 500 tools is part of the
//! < 15 ms catalog budget; per-request codec work is part of the < 50 µs
//! zigguro-side overhead.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_mcp = @import("zg_mcp");
const bench = zg_core.bench;
const State = bench.State;
const codec = zg_mcp.protocol.codec;
const M = zg_mcp.protocol.messages;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

const tool_count = 500;

fn register(b: *bench.Bench) !void {
    const gpa = b.gpa;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"resultType\":\"complete\",\"ttlMs\":60000,\"cacheScope\":\"private\",\"tools\":[");
    for (0..tool_count) |i| {
        if (i != 0) try w.writeByte(',');
        try w.print(
            \\{{"name":"tool_{d}","title":"Tool {d}","description":"Does thing number {d} to the repository and reports what changed.","inputSchema":{{"type":"object","properties":{{"path":{{"type":"string","description":"File path"}},"line":{{"type":"integer","minimum":1}},"dryRun":{{"type":"boolean"}}}},"required":["path"]}},"annotations":{{"readOnlyHint":true}}}}
        , .{ i, i, i });
    }
    try w.writeAll("]}");
    const list = aw.written();

    try b.run("protocol: decode tools/list (500 tools)", list, decodeList);
    try b.run("protocol: decode tools/call result", {}, decodeCall);
    try b.run("protocol: encode tools/call request", {}, encodeCall);
    try registerSchema(b);
}

const schema = zg_mcp.schema;

/// A 200-subschema object schema (40 properties of 5 nodes each).
fn bigSchema(gpa: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    try w.writeAll("{\"type\":\"object\",\"properties\":{");
    for (0..40) |i| {
        if (i != 0) try w.writeByte(',');
        try w.print(
            \\"p{d}":{{"anyOf":[{{"type":"string","maxLength":64}},{{"type":"array","items":{{"type":"integer","minimum":0}}}},{{"type":"null"}}]}}
        , .{i});
    }
    try w.writeAll("},\"required\":[\"p0\"],\"additionalProperties\":false}");
    return aw.toOwnedSlice();
}

const tool_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File path"},"line":{"type":"integer","minimum":1},"dryRun":{"type":"boolean"}},"required":["path"]}
;
const tool_args =
    \\{"path":"src/main.zig","line":42,"dryRun":false}
;

const SchemaFixture = struct { big: std.json.Value, tool: *schema.Schema, args: std.json.Value };

fn registerSchema(b: *bench.Bench) !void {
    var arena: std.heap.ArenaAllocator = .init(b.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const big = try std.json.parseFromSliceLeaky(std.json.Value, a, try bigSchema(a), .{});
    const tool = try schema.compile(b.gpa, try std.json.parseFromSliceLeaky(std.json.Value, a, tool_schema, .{}), .{});
    defer tool.deinit();
    const fx: SchemaFixture = .{ .big = big, .tool = tool, .args = try std.json.parseFromSliceLeaky(std.json.Value, a, tool_args, .{}) };
    try b.run("schema: compile 200-node schema", fx, compileBig);
    try b.run("schema: validate tools/call arguments", fx, validateArgs);
}

fn compileBig(fx: SchemaFixture, s: *State) void {
    for (0..s.iterations()) |_| {
        const c = schema.compile(s.allocator(), fx.big, .{}) catch unreachable;
        bench.doNotOptimizeAway(c.nodes.len);
        c.deinit();
    }
}

fn validateArgs(fx: SchemaFixture, s: *State) void {
    for (0..s.iterations()) |_| {
        const ok = schema.validate(fx.tool, s.allocator(), fx.args, null) catch unreachable;
        bench.doNotOptimizeAway(ok);
    }
}

fn decodeList(list: []const u8, s: *State) void {
    var arena: std.heap.ArenaAllocator = .init(s.allocator());
    defer arena.deinit();
    s.setBytes(list.len);
    for (0..s.iterations()) |_| {
        _ = arena.reset(.retain_capacity);
        const r = codec.decodeResult(M.ListToolsResult, arena.allocator(), .{ .bytes = list }, .{}) catch unreachable;
        bench.doNotOptimizeAway(r.complete.tools.len);
    }
}

const call_result =
    \\{"resultType":"complete","content":[{"type":"text","text":"Current weather in New York:\nTemperature: 72°F\nConditions: Partly cloudy"}],"structuredContent":{"temperature":72,"conditions":"Partly cloudy"},"isError":false}
;

fn decodeCall(_: void, s: *State) void {
    var arena: std.heap.ArenaAllocator = .init(s.allocator());
    defer arena.deinit();
    s.setBytes(call_result.len);
    for (0..s.iterations()) |_| {
        _ = arena.reset(.retain_capacity);
        const r = codec.decodeResult(M.CallToolResult, arena.allocator(), .{ .bytes = call_result }, .{}) catch unreachable;
        bench.doNotOptimizeAway(r.complete.content.len);
    }
}

fn encodeCall(_: void, s: *State) void {
    var arena: std.heap.ArenaAllocator = .init(s.allocator());
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    for (0..s.iterations()) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        var args: std.json.ObjectMap = .empty;
        args.put(a, "location", .{ .string = "New York" }) catch unreachable;
        const p: M.CallToolParams = .{
            .name = "get_weather",
            .arguments = .{ .object = args },
            .meta = .{
                .protocol_version = "2026-07-28",
                .client_info = .{ .name = "zigguro", .version = "0.0.0" },
                .client_capabilities = zg_mcp.protocol.Capabilities.empty,
            },
        };
        var w: std.Io.Writer = .fixed(&buf);
        @import("zg_jsonrpc").message.writeRequest(&w, .{ .int = 1 }, "tools/call", codec.json(p)) catch unreachable;
        bench.doNotOptimizeAway(w.end);
    }
}
