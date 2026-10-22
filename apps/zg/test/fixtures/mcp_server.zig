//! A stdio MCP server for the `zg agent --mcp-config` end-to-end test,
//! built on the zg_mcp server SDK and its stdio transport: one tool
//! `add {a, b}` that answers with the sum.

const std = @import("std");
const zg_mcp = @import("zg_mcp");

const Io = std.Io;
const Value = std.json.Value;
const M = zg_mcp.protocol.messages;

fn add(_: ?*anyopaque, cc: *zg_mcp.server.Server.CallCtx, args: Value) anyerror!M.CallToolResult {
    const a = args.object.get("a").?.integer;
    const b = args.object.get("b").?.integer;
    const blocks = try cc.arena.alloc(zg_mcp.protocol.ContentBlock, 1);
    blocks[0] = .textBlock(try std.fmt.allocPrint(cc.arena, "{d}", .{a + b}));
    return .{ .content = blocks };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const s = try zg_mcp.server.Server.init(gpa, io, .{ .info = .{ .name = "fixture", .version = "1" } });
    defer s.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try s.addDynamicTool(.{
        .def = .{
            .name = "add",
            .description = "Adds two integers.",
            .input_schema = try zg_mcp.protocol.codec.parseValue(arena.allocator(),
                \\{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},"required":["a","b"]}
            ),
            .annotations = .{ .read_only_hint = true },
        },
        .handler = .{ .ctx = null, .call = add },
    });
    try zg_mcp.server.transport.serveStdio(s, .{ .stdin = Io.File.stdin(), .stdout = Io.File.stdout() });
}
