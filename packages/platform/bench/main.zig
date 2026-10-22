//! zg_platform benchmarks (`zig build bench`): event ring push/pop and
//! cross-thread wake round trips (E01.F01 budgets: ring < 30 ns per push+pop,
//! wake < 100 µs p99), PTY spawn (E01.F06: < 5 ms on Linux), watch setup (>= 50k dirs/s)
//! and XKB keymap parsing (E01.F04: < 2 ms for us.xkb in ReleaseFast).

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
    if (@import("builtin").os.tag == .linux) {
        try b.run("pty: spawn /bin/true and wait", b, ptySpawnTrue);
        try watchSetup(b);
    }
    try xkbParse(b);
}

/// Parses the `us` fixture (about 60 KB, like Mutter's). Skipped when not
/// run from the repository root.
fn xkbParse(b: *bench.Bench) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(b.io, "packages/platform/src/xkb/testdata/us.xkb", b.gpa, .limited(1 << 20)) catch return;
    defer b.gpa.free(text);
    try b.run("xkb: parse us.xkb", text, xkbParseOnce);
}

fn xkbParseOnce(text: []const u8, s: *State) void {
    s.setBytes(text.len);
    for (0..s.iterations()) |_| {
        var km = zg_platform.xkb.Keymap.parse(s.allocator(), text) catch unreachable;
        km.deinit(s.allocator());
    }
}

const watch_dirs = 50_000;

/// Watch setup over a generated tree of 50k directories (100 x 500); the
/// reported bytes/s figure is directories per second.
fn watchSetup(b: *bench.Bench) !void {
    const io = b.io;
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const base = try std.fmt.allocPrint(b.gpa, "/tmp/zg-watch-bench-{x}", .{rnd});
    defer b.gpa.free(base);
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteTree(io, base) catch {};
    var buf: [256]u8 = undefined;
    for (0..100) |i| for (0..watch_dirs / 100) |j| {
        try cwd.createDirPath(io, try std.fmt.bufPrint(&buf, "{s}/d{d}/e{d}", .{ base, i, j }));
    };
    try b.run("fswatch: watch a 50k-directory tree", base, watchTree);
}

fn watchTree(base: []const u8, s: *State) void {
    s.setBytes(watch_dirs);
    for (0..s.iterations()) |_| {
        var w = zg_platform.fswatch.Watcher.init(s.allocator(), s.ioHandle(), .{}) catch unreachable;
        _ = w.addRoot(base, &.none) catch unreachable;
        w.deinit();
    }
}

fn ptySpawnTrue(b: *bench.Bench, s: *State) void {
    var env: std.process.Environ.Map = .init(b.gpa);
    defer env.deinit();
    for (0..s.iterations()) |_| {
        var p = zg_platform.process.Pty.spawn(b.gpa, b.io, .{ .argv = &.{"/bin/true"}, .env = &env }) catch unreachable;
        _ = p.wait() catch unreachable;
        p.close();
    }
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
