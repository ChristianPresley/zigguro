//! A stdio MCP server for the `zg agent --mcp-config` end-to-end test,
//! built on the zg_mcp server SDK: NDJSON on stdin and stdout, one tool
//! `add {a, b}` that answers with the sum.

const std = @import("std");
const zg_mcp = @import("zg_mcp");

const Io = std.Io;
const Value = std.json.Value;
const M = zg_mcp.protocol.messages;

const Out = struct {
    io: Io,
    mutex: Io.Mutex = .init,

    fn send(ctx: ?*anyopaque, body: []const u8) void {
        const o: *Out = @ptrCast(@alignCast(ctx.?));
        o.mutex.lockUncancelable(o.io);
        defer o.mutex.unlock(o.io);
        Io.File.stdout().writeStreamingAll(o.io, body) catch {};
        Io.File.stdout().writeStreamingAll(o.io, "\n") catch {};
    }
};

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
    var out: Out = .{ .io = io };
    const conn = try s.connect(.{ .ctx = &out, .send = Out.send }, null);
    defer conn.close();
    var buf: [1 << 16]u8 = undefined;
    var r = Io.File.stdin().readerStreaming(io, &buf);
    while (r.interface.takeDelimiter('\n') catch null) |line| {
        if (line.len == 0) continue;
        conn.receive(line);
    }
}
