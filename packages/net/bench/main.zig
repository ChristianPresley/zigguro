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

    // Masked binary frames with 4 KiB payloads, as a server receives them.
    const frames = try gpa.alloc(u8, stream_len);
    defer gpa.free(frames);
    var off: usize = 0;
    while (off + 14 + 4096 <= frames.len) {
        var h: [14]u8 = undefined;
        const enc = zg_net.ws_frame.encodeHeader(&h, .{ .fin = true, .opcode = .binary, .masked = true, .len = 4096, .mask = .{ 1, 2, 3, 4 } });
        @memcpy(frames[off..][0..enc.len], enc);
        off += enc.len;
        for (frames[off..][0..4096], 0..) |*c, i| c.* = @truncate(i);
        off += 4096;
    }
    try b.run("ws: decode and unmask 8 MiB of 4 KiB frames", frames[0..off], wsDecode);
}

fn wsDecode(frames: []const u8, s: *State) void {
    s.setBytes(frames.len);
    const buf = s.allocator().alloc(u8, frames.len) catch unreachable;
    for (0..s.iterations()) |_| {
        @memcpy(buf, frames);
        var off: usize = 0;
        var total: u64 = 0;
        while (off < buf.len) {
            const d = zg_net.ws_frame.decodeHeader(buf[off..]) catch unreachable;
            off += d.size;
            const len: usize = @intCast(d.header.len);
            zg_net.ws_frame.applyMask(d.header.mask, 0, buf[off..][0..len]);
            total += len;
            off += len;
        }
        bench.doNotOptimizeAway(total);
    }
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
