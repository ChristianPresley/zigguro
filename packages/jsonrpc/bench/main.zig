//! zg_jsonrpc benchmarks (`zig build bench`).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_jsonrpc = @import("zg_jsonrpc");
const bench = zg_core.bench;
const State = bench.State;
const framing = zg_jsonrpc.framing;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

const body_len = 64 << 10;

const Frames = struct {
    cl: []u8,
    nd: []u8,
};

fn register(b: *bench.Bench) !void {
    const gpa = b.gpa;
    const header = std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n", .{body_len});
    var frames: Frames = .{
        .cl = try gpa.alloc(u8, header.len + body_len),
        .nd = try gpa.alloc(u8, body_len + 1),
    };
    defer {
        gpa.free(frames.cl);
        gpa.free(frames.nd);
    }
    @memcpy(frames.cl[0..header.len], header);
    @memset(frames.cl[header.len..], 'a');
    @memset(frames.nd[0..body_len], 'a');
    frames.nd[body_len] = '\n';

    try b.run("framing: content-length 64 KiB frame read", &frames, clRead);
    try b.run("framing: ndjson 64 KiB line read", &frames, ndRead);
    try b.run("message: classify 64 KiB didOpen", &frames, classify);
    try b.run("endpoint: request/response round trip (PipePair)", {}, roundTrip);
}

fn classify(f: *const Frames, s: *State) void {
    _ = f;
    const gpa = std.heap.page_allocator;
    const text = gpa.alloc(u8, body_len) catch unreachable;
    defer gpa.free(text);
    @memset(text, 'x');
    const body = std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///a.zig\",\"text\":\"{s}\"}}}}}}", .{text}) catch unreachable;
    defer gpa.free(body);
    var arena: std.heap.ArenaAllocator = .init(s.allocator());
    defer arena.deinit();
    s.setBytes(body.len);
    for (0..s.iterations()) |_| {
        _ = arena.reset(.retain_capacity);
        bench.doNotOptimizeAway(zg_jsonrpc.message.parse(arena.allocator(), body));
    }
}

fn echo(_: ?*anyopaque, _: *zg_jsonrpc.Endpoint, req: zg_jsonrpc.message.Request, _: std.mem.Allocator) zg_jsonrpc.Endpoint.HandlerResult {
    return .{ .result = req.params orelse .{ .bytes = "null" } };
}

fn roundTrip(_: void, s: *State) void {
    const io = s.ioHandle();
    const gpa = std.heap.smp_allocator;
    var rt: zg_core.Runtime = undefined;
    rt.initBorrowed(gpa, io, 1024) catch unreachable;
    defer _ = rt.deinit();
    const pipe = zg_jsonrpc.testing.PipePair.init(gpa, io, 1 << 16) catch unreachable;
    defer pipe.deinit();
    const cfg: zg_jsonrpc.Endpoint.Config = .{ .framing = .content_length, .dialect = .lsp };
    const client = zg_jsonrpc.Endpoint.init(&rt, cfg, pipe.a_reader, pipe.a_writer) catch unreachable;
    const server = zg_jsonrpc.Endpoint.init(&rt, cfg, pipe.b_reader, pipe.b_writer) catch unreachable;
    server.onRequest("echo", .{ .ctx = null, .func = echo }) catch unreachable;
    server.start() catch unreachable;
    client.start() catch unreachable;
    for (0..s.iterations()) |_| {
        const r = client.request("echo", .{ .x = 1 }, .{}) catch unreachable;
        r.deinit();
    }
    pipe.closeA();
    pipe.closeB();
    client.deinit();
    server.deinit();
}

fn clRead(f: *const Frames, s: *State) void {
    s.setBytes(body_len);
    for (0..s.iterations()) |_| {
        var r: std.Io.Reader = .fixed(f.cl);
        var cl: framing.ContentLengthReader = .init(&r, .{});
        bench.doNotOptimizeAway((cl.next(s.allocator()) catch unreachable).len);
    }
}

fn ndRead(f: *const Frames, s: *State) void {
    s.setBytes(body_len);
    for (0..s.iterations()) |_| {
        var r: std.Io.Reader = .fixed(f.nd);
        var nd: framing.NdjsonReader = .init(&r, .{});
        bench.doNotOptimizeAway((nd.next(s.allocator()) catch unreachable).len);
    }
}
