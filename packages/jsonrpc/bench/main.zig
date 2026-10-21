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
