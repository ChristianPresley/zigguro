//! `ToolExporter` against a real `zg_mcp.Server` over `InProcPair`, with a
//! copy of zg_ai's foreign-tool contract (zg_mcp cannot import zg_ai).

const std = @import("std");
const zg_core = @import("zg_core");
const protocol = @import("../protocol/root.zig");
const Server = @import("../server/Server.zig");
const Client = @import("Client.zig");
const InProcPair = @import("../transport/in_process.zig");
const agent_tools = @import("agent_tools.zig");

const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const M = protocol.messages;

/// The shape of `zg_ai.tools.adapters.foreign`.
pub const Foreign = struct {
    pub const Kind = enum { lsp, debug, tasks, workspace, notes, scm, mcp };
    pub const Annotations = struct {
        title: ?[]const u8 = null,
        read_only_hint: ?bool = null,
        destructive_hint: ?bool = null,
        idempotent_hint: ?bool = null,
        open_world_hint: ?bool = null,
    };
    pub const ForeignTool = struct {
        name: []const u8,
        description: []const u8,
        input_schema_json: []const u8,
        read_only: bool = false,
        mutates: bool = false,
        annotations: Annotations = .{},
    };
    pub const Result = struct { json: []const u8, changeset: ?u64 = null };
    pub const ChangedCb = struct { ctx: *anyopaque, changed: *const fn (ctx: *anyopaque) void };
    pub const Exporter = struct {
        name: []const u8,
        kind: Kind,
        trusted: bool = false,
        ctx: *anyopaque,
        list: *const fn (ctx: *anyopaque, arena: Allocator) anyerror![]const ForeignTool,
        call: *const fn (ctx: *anyopaque, io: std.Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!Result,
        subscribe_changed: ?*const fn (ctx: *anyopaque, cb: ChangedCb) void = null,
    };
};

const X = agent_tools.ToolExporter(Foreign);

fn echo(_: ?*anyopaque, cc: *Server.CallCtx, args: Value) anyerror!M.CallToolResult {
    const text = if (args == .object) (if (args.object.get("text")) |t| t.string else "") else "";
    const blocks = try cc.arena.alloc(protocol.ContentBlock, 1);
    blocks[0] = .textBlock(try std.fmt.allocPrint(cc.arena, "echo: {s}", .{text}));
    return .{ .content = blocks };
}

const Fixture = struct {
    rt: zg_core.Runtime,
    arena: std.heap.ArenaAllocator,
    s: *Server,
    pair: InProcPair,
    conn: *Server.Conn,
    c: *Client,
    x: X,

    fn init(f: *Fixture, revisions: []const protocol.Revision) !void {
        f.rt.initTesting();
        f.arena = .init(gpa);
        const a = f.arena.allocator();
        f.s = try Server.init(gpa, io, .{ .info = .{ .name = "fixture", .version = "1" } });
        try f.s.addDynamicTool(.{
            .def = .{
                .name = "echo",
                .description = "Echoes text.",
                .input_schema = try protocol.codec.parseValue(a, "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}"),
                .annotations = .{ .read_only_hint = true, .open_world_hint = false },
            },
            .handler = .{ .ctx = null, .call = echo },
        });
        f.pair = .init(gpa, io);
        f.conn = try f.s.serveInProcess(&f.pair);
        f.x.init(gpa, io, "fx", .{ .catalog = .{ .debounce = .fromMilliseconds(20) } });
        f.c = try Client.connect(&f.rt, gpa, .{ .in_process = &f.pair }, .{
            .client_info = .{ .name = "t", .version = "1" },
            .revisions = revisions,
            .on_notification = f.x.notificationHandler(),
        });
        f.x.attach(f.c);
    }

    fn deinit(f: *Fixture) void {
        f.x.deinit();
        f.c.close();
        f.conn.close();
        f.pair.deinit();
        f.s.deinit();
        f.arena.deinit();
        _ = f.rt.deinit();
    }
};

test "agent tools: list and call through the exporter" {
    var f: Fixture = undefined;
    try f.init(&protocol.revision.supported_newest_first);
    defer f.deinit();
    const e = f.x.exporter();
    try testing.expectEqualStrings("fx", e.name);
    try testing.expectEqual(Foreign.Kind.mcp, e.kind);
    try testing.expect(!e.trusted);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = try e.list(e.ctx, a);
    try testing.expectEqual(1, tools.len);
    try testing.expectEqualStrings("echo", tools[0].name);
    try testing.expectEqualStrings("Echoes text.", tools[0].description);
    try testing.expect(tools[0].annotations.read_only_hint.?);
    try testing.expect(!tools[0].mutates);
    const schema = try std.json.parseFromSliceLeaky(Value, a, tools[0].input_schema_json, .{});
    try testing.expectEqualStrings("object", schema.object.get("type").?.string);

    const r = try e.call(e.ctx, io, a, "echo", "{\"text\":\"hi\"}");
    try testing.expect(r.changeset == null);
    const v = try std.json.parseFromSliceLeaky(Value, a, r.json, .{});
    try testing.expectEqualStrings("echo: hi", v.object.get("content").?.array.items[0].object.get("text").?.string);

    // An unknown tool is an isError result for the model.
    const bad = try e.call(e.ctx, io, a, "nope", "{}");
    const bv = try std.json.parseFromSliceLeaky(Value, a, bad.json, .{});
    try testing.expect(bv.object.get("isError").?.bool);
}

const Counter = struct {
    n: std.atomic.Value(u32) = .init(0),

    fn changed(ctx: *anyopaque) void {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        _ = c.n.fetchAdd(1, .monotonic);
    }
};

test "agent tools: list_changed refreshes and tells the registry" {
    var f: Fixture = undefined;
    // Legacy: the server pushes list_changed on the session.
    try f.init(&.{.v2025_06_18});
    defer f.deinit();
    const e = f.x.exporter();
    var counter: Counter = .{};
    e.subscribe_changed.?(e.ctx, .{ .ctx = &counter, .changed = Counter.changed });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(1, (try e.list(e.ctx, a)).len);
    // The first listing published the catalog.
    try testing.expectEqual(1, counter.n.load(.monotonic));

    try f.s.addDynamicTool(.{
        .def = .{ .name = "second", .input_schema = try protocol.codec.parseValue(f.arena.allocator(), "{\"type\":\"object\"}") },
        .handler = .{ .ctx = null, .call = echo },
    });
    var waited: u32 = 0;
    while (counter.n.load(.monotonic) < 2 and waited < 300) : (waited += 1) try io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectEqual(2, counter.n.load(.monotonic));
    try testing.expectEqual(2, (try e.list(e.ctx, a)).len);
}
