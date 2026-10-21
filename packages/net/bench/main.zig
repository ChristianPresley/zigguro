//! zg_net benchmarks (`zig build bench`).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_net = @import("zg_net");
const bench = zg_core.bench;
const State = bench.State;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

const stream_len = 8 << 20;

fn register(b: *bench.Bench) !void {
    const gpa = b.gpa;
    // `data:` lines of 120 bytes, one event per 4 lines.
    const text = try gpa.alloc(u8, stream_len);
    defer gpa.free(text);
    var n: usize = 0;
    var k: usize = 0;
    while (n + 128 < text.len) : (k += 1) {
        const line = "data: " ++ "x" ** 113 ++ "\n";
        @memcpy(text[n..][0..line.len], line);
        n += line.len;
        if (k % 4 == 3) {
            text[n] = '\n';
            n += 1;
        }
    }
    @memset(text[n..], '\n');
    try b.run("sse: parse 8 MiB of data lines", text, sseParse);
}

const Sink = struct {
    events: usize = 0,
    pub fn onEvent(self: *Sink, ev: zg_net.sse.Event) !void {
        self.events += 1;
        bench.doNotOptimizeAway(ev.data.len);
    }
};

fn sseParse(text: []const u8, s: *State) void {
    s.setBytes(text.len);
    var p: zg_net.sse.Parser = .init(s.allocator(), .{});
    defer p.deinit();
    var sink: Sink = .{};
    for (0..s.iterations()) |_| {
        // 64 KiB chunks, as a socket would deliver them.
        var i: usize = 0;
        while (i < text.len) : (i += 64 << 10) p.feed(text[i..@min(text.len, i + (64 << 10))], &sink) catch unreachable;
        p.finish();
    }
    bench.doNotOptimizeAway(sink.events);
}
