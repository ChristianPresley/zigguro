//! zg_core benchmarks (`zig build bench`); also the example for other packages.

const std = @import("std");
const zg_core = @import("zg_core");
const bench = zg_core.bench;
const State = bench.State;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

const Data = struct {
    ascii: []u8,
    mixed: []u8,
    text: []u8,
};

fn register(b: *bench.Bench) !void {
    const gpa = b.gpa;
    var data: Data = .{
        .ascii = try gpa.alloc(u8, 1 << 20),
        .mixed = try gpa.alloc(u8, 1 << 20),
        .text = try gpa.alloc(u8, 16 << 20),
    };
    defer {
        gpa.free(data.ascii);
        gpa.free(data.mixed);
        gpa.free(data.text);
    }
    for (data.ascii, 0..) |*c, i| c.* = @intCast(32 + i % 90);
    const pieces = [_][]const u8{ "abc ", "\u{4e2d}\u{6587}", "\u{1F600}", "\u{e9}t\u{e9} " };
    var n: usize = 0;
    var k: usize = 0;
    while (n + 8 < data.mixed.len) : (k += 1) {
        const p = pieces[k % pieces.len];
        @memcpy(data.mixed[n..][0..p.len], p);
        n += p.len;
    }
    @memset(data.mixed[n..], 'x');
    for (data.text, 0..) |*c, i| c.* = if (i % 41 == 40) '\n' else 'a';

    try b.run("mailbox post+drain (1 producer)", {}, mailboxSingle);
    try b.run("mailbox post+drain (4 producers)", {}, mailboxMulti);
    try b.run(if (zg_core.trace.enabled) "trace zone (enabled)" else "trace zone (compiled out)", {}, traceZone);
    try b.run("utf8.validate 1 MiB ascii", &data, utf8Ascii);
    try b.run("utf8.validate 1 MiB mixed", &data, utf8Mixed);
    try b.run("LineIndex.build 16 MiB", &data, lineIndex);
    try b.run("ArenaAllocator alloc 64 B", {}, arenaAlloc);
    try b.run("DebugAllocator alloc+free 64 B", {}, debugAlloc);
    try b.run("log filtered out", {}, logFiltered);
}

fn mailboxSingle(_: void, s: *State) void {
    const io = s.ioHandle();
    var mb = zg_core.runtime.Mailbox.init(std.heap.page_allocator, 1024) catch unreachable;
    defer mb.deinit(std.heap.page_allocator);
    var out: [1]zg_core.runtime.UiMsg = undefined;
    for (0..s.iterations()) |i| {
        mb.post(io, .{ .kind = 1, .a = i }, false) catch unreachable;
        bench.doNotOptimizeAway(mb.drain(io, &out));
    }
}

fn mailboxMulti(_: void, s: *State) void {
    const io = s.ioHandle();
    var mb = zg_core.runtime.Mailbox.init(std.heap.page_allocator, 4096) catch unreachable;
    defer mb.deinit(std.heap.page_allocator);
    const per = s.iterations() / 4 + 1;
    const P = struct {
        fn run(m: *zg_core.runtime.Mailbox, i: std.Io, count: u64) void {
            var j: u64 = 0;
            while (j < count) {
                m.post(i, .{ .kind = 1, .a = j }, false) catch {
                    std.atomic.spinLoopHint();
                    continue;
                };
                j += 1;
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = std.Thread.spawn(.{}, P.run, .{ &mb, io, per }) catch unreachable;
    var got: u64 = 0;
    var out: [256]zg_core.runtime.UiMsg = undefined;
    while (got < per * 4) got += mb.drain(io, &out);
    for (threads) |t| t.join();
}

fn traceZone(_: void, s: *State) void {
    for (0..s.iterations()) |_| {
        const z = zg_core.trace.zone(@src(), "bench");
        z.end();
    }
    // Keep the per-thread ring from filling up across samples.
    var evs: std.ArrayList(zg_core.trace.Event) = .empty;
    defer evs.deinit(std.heap.page_allocator);
    zg_core.trace.collect(std.heap.page_allocator, &evs) catch {};
}

fn utf8Ascii(d: *Data, s: *State) void {
    s.setBytes(d.ascii.len);
    for (0..s.iterations()) |_| bench.doNotOptimizeAway(zg_core.utf8.validate(d.ascii));
}

fn utf8Mixed(d: *Data, s: *State) void {
    s.setBytes(d.mixed.len);
    for (0..s.iterations()) |_| bench.doNotOptimizeAway(zg_core.utf8.validate(d.mixed));
}

fn lineIndex(d: *Data, s: *State) void {
    s.setBytes(d.text.len);
    for (0..s.iterations()) |_| {
        var li = zg_core.LineIndex.build(std.heap.page_allocator, d.text) catch unreachable;
        bench.doNotOptimizeAway(li.lineCount());
        li.deinit(std.heap.page_allocator);
    }
}

fn arenaAlloc(_: void, s: *State) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..s.iterations()) |_| bench.doNotOptimizeAway(a.alloc(u8, 64) catch unreachable);
}

fn debugAlloc(_: void, s: *State) void {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const a = dbg.allocator();
    for (0..s.iterations()) |_| {
        const p = a.alloc(u8, 64) catch unreachable;
        bench.doNotOptimizeAway(p);
        a.free(p);
    }
}

fn logFiltered(_: void, s: *State) void {
    const log = std.log.scoped(.bench);
    for (0..s.iterations()) |i| log.debug("never formatted {d}", .{i});
}
