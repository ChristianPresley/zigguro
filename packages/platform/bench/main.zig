//! zg_platform benchmarks (`zig build bench`): event ring push/pop and
//! cross-thread wake round trips (E01.F01 budgets: ring < 30 ns per push+pop,
//! wake < 100 µs p99).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_platform = @import("zg_platform");
const bench = zg_core.bench;
const State = bench.State;
const Event = zg_platform.Event;
const Wake = zg_platform.queue.Wake;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

const Ring = zg_platform.queue.EventRing(4096);

fn register(b: *bench.Bench) !void {
    const ring = try b.gpa.create(Ring);
    defer b.gpa.destroy(ring);
    ring.* = .{ .io = b.io };
    try b.run("ring: push + pop one event", ring, ringPushPop);
    try b.run("ring: push 256 then popMany", ring, ringBatch);
    try b.run("wake: cross-thread round trip", b.io, wakeRoundTrip);
}

const move: Event = .{ .pointer_move = .{ .win = @enumFromInt(1), .pos_px = .{ 1, 2 }, .mods = .{}, .time_ns = 0 } };

fn ringPushPop(ring: *Ring, s: *State) void {
    var out: [1]Event = undefined;
    for (0..s.iterations()) |_| {
        _ = ring.push(move);
        bench.doNotOptimizeAway(ring.popMany(&out));
    }
}

fn ringBatch(ring: *Ring, s: *State) void {
    var out: [256]Event = undefined;
    for (0..s.iterations()) |_| {
        for (0..out.len) |_| _ = ring.push(move);
        bench.doNotOptimizeAway(ring.popMany(&out));
    }
}

fn wakeRoundTrip(io: std.Io, s: *State) void {
    var ping = Wake.init(io) catch unreachable;
    defer ping.deinit();
    var pong = Wake.init(io) catch unreachable;
    defer pong.deinit();
    const n = s.iterations();
    const Echo = struct {
        fn run(a: *Wake, z: *Wake, count: u64) void {
            for (0..count) |_| {
                _ = a.wait(null);
                a.consume();
                z.signal();
            }
        }
    };
    const t = std.Thread.spawn(.{}, Echo.run, .{ &ping, &pong, n }) catch unreachable;
    for (0..n) |_| {
        ping.signal();
        _ = pong.wait(null);
        pong.consume();
    }
    t.join();
}
