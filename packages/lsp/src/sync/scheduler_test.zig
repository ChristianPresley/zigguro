const std = @import("std");
const zg_core = @import("zg_core");
const sched = @import("scheduler.zig");
const Client = @import("../client/Client.zig");
const protocol = @import("../gen/protocol.zig");
const Harness = @import("../client/client_test.zig").Harness;
const testing = std.testing;
const Io = std.Io;

const RequestScheduler = sched.RequestScheduler;
const ms = Io.Duration.fromMilliseconds;

/// Records runs; keeps the last token.
const Runs = struct {
    n: usize = 0,
    version: u64 = 0,
    token: ?sched.CancelToken = null,

    fn runFn(r: *Runs) sched.RunFn {
        return .{ .ctx = r, .func = run };
    }

    fn run(ctx: ?*anyopaque, version: u64, token: sched.CancelToken) void {
        const r: *Runs = @ptrCast(@alignCast(ctx.?));
        r.n += 1;
        r.version = version;
        r.token = token;
    }
};

const Fixture = struct {
    rt: zg_core.Runtime,
    clock: sched.ManualClock = .{},
    s: RequestScheduler,

    fn init(f: *Fixture) void {
        f.rt.initTesting();
        f.clock = .{};
        f.s = .init(&f.rt, f.clock.clock());
    }

    fn deinit(f: *Fixture) void {
        f.s.deinit();
        _ = f.rt.deinit();
    }

    /// Moves the clock and polls.
    fn after(f: *Fixture, d: Io.Duration) void {
        f.clock.advance(d);
        f.s.poll();
    }
};

const doc: sched.DocId = 7;

test "scheduler: debounce per key" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var a: Runs = .{};
    var b: Runs = .{};
    const ka: sched.SchedKey = .{ .doc = doc, .feature = .inlay_hint };
    const kb: sched.SchedKey = .{ .doc = doc, .feature = .code_lens };
    try f.s.schedule(ka, f.s.debounceFor(.inlay_hint), a.runFn());
    try f.s.schedule(kb, f.s.debounceFor(.code_lens), b.runFn());
    f.after(ms(60));
    try f.s.schedule(ka, f.s.debounceFor(.inlay_hint), a.runFn()); // reset
    f.after(ms(60));
    try testing.expectEqual(@as(usize, 0), a.n);
    f.after(ms(50));
    try testing.expectEqual(@as(usize, 1), a.n);
    try testing.expectEqual(@as(usize, 0), b.n);
    f.after(ms(100));
    try testing.expectEqual(@as(usize, 1), b.n);
    try testing.expectEqual(@as(usize, 1), a.n);

    f.s.setDebounce(.inlay_hint, ms(10));
    try testing.expectEqual(@as(i96, ms(10).nanoseconds), f.s.debounceFor(.inlay_hint).nanoseconds);
    try testing.expectEqual(@as(i96, 0), f.s.debounceFor(.completion).nanoseconds);
}

test "scheduler: onDocChanged restarts auto keys with new version" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var tokens: Runs = .{};
    var hover: Runs = .{};
    try f.s.schedule(.{ .doc = doc, .feature = .semantic_tokens_full }, ms(150), tokens.runFn());
    f.after(ms(150));
    try testing.expectEqual(@as(usize, 1), tokens.n);
    try f.s.schedule(.{ .doc = doc, .feature = .hover }, ms(0), hover.runFn());
    f.after(ms(5));
    try testing.expectEqual(@as(usize, 1), hover.n);
    const t1 = tokens.token.?;
    const h1 = hover.token.?;
    try testing.expect(!t1.isCanceled());

    f.s.onDocChanged(doc, 2);
    try testing.expect(t1.isCanceled());
    try testing.expect(h1.isCanceled());
    try testing.expectEqual(@as(u64, 2), f.s.version(doc));
    f.after(ms(150));
    try testing.expectEqual(@as(usize, 2), tokens.n);
    try testing.expectEqual(@as(u64, 2), tokens.version);
    // Interactive keys are canceled, not re-run.
    try testing.expectEqual(@as(usize, 1), hover.n);
    // Another document is untouched.
    f.s.onDocChanged(doc + 1, 9);
    try testing.expect(!tokens.token.?.isCanceled());
}

test "scheduler: ContentModified retries exactly once" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var r: Runs = .{};
    const k: sched.SchedKey = .{ .doc = doc, .feature = .inlay_hint };
    try f.s.schedule(k, ms(0), r.runFn());
    f.after(ms(5));
    try testing.expectEqual(@as(usize, 1), r.n);
    try testing.expect(f.s.onContentModified(k));
    f.after(ms(500));
    try testing.expectEqual(@as(usize, 1), r.n); // waits for the change
    f.s.onDocChanged(doc, 3);
    f.after(ms(5));
    try testing.expectEqual(@as(usize, 2), r.n);
    try testing.expect(!f.s.onContentModified(k));
    // Not for every feature.
    var c: Runs = .{};
    const kc: sched.SchedKey = .{ .doc = doc, .feature = .completion };
    try f.s.schedule(kc, ms(0), c.runFn());
    f.after(ms(5));
    try testing.expect(!f.s.onContentModified(kc));
}

test "scheduler: interactive preempts background; starvation cap" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var hover: Runs = .{};
    var lens: Runs = .{};
    try f.s.schedule(.{ .doc = doc, .feature = .hover }, ms(0), hover.runFn());
    f.after(ms(5));
    try f.s.schedule(.{ .doc = doc, .feature = .code_lens }, ms(0), lens.runFn());
    f.after(ms(5));
    f.after(ms(100));
    try testing.expectEqual(@as(usize, 0), lens.n);
    hover.token.?.done();
    f.after(ms(5));
    try testing.expectEqual(@as(usize, 1), lens.n);

    // A hover that never finishes holds background work 500 ms at most.
    try f.s.schedule(.{ .doc = doc, .feature = .hover }, ms(0), hover.runFn());
    f.after(ms(5));
    try f.s.schedule(.{ .doc = doc, .feature = .code_lens }, ms(0), lens.runFn());
    var waited: u32 = 0;
    while (lens.n == 1 and waited < 200) : (waited += 1) f.after(ms(5));
    try testing.expectEqual(@as(usize, 2), lens.n);
    try testing.expect(waited >= 100 and waited <= 102);
}

test "scheduler: cancelDoc clears timers and in-flight" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var a: Runs = .{};
    var b: Runs = .{};
    const ka: sched.SchedKey = .{ .doc = doc, .feature = .folding_range };
    try f.s.schedule(ka, ms(0), a.runFn());
    f.after(ms(5));
    try f.s.schedule(.{ .doc = doc, .feature = .document_symbol }, ms(300), b.runFn());
    const t = a.token.?;
    f.s.cancelDoc(doc);
    try testing.expect(t.isCanceled());
    f.after(ms(400));
    try testing.expectEqual(@as(usize, 0), b.n);
    // Entries are reused; old tokens stay canceled.
    try f.s.schedule(ka, ms(0), a.runFn());
    f.after(ms(5));
    try testing.expectEqual(@as(usize, 2), a.n);
    try testing.expect(t.isCanceled());
    try testing.expect(!a.token.?.isCanceled());
}

test "scheduler: keystroke path does not allocate" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var counting = zg_core.alloc.CountingAllocator.init(testing.allocator);
    f.s.gpa = counting.allocator();
    var r: Runs = .{};
    const k: sched.SchedKey = .{ .doc = doc, .feature = .semantic_tokens_full };
    try f.s.schedule(k, ms(150), r.runFn());
    counting.resetCounters();
    for (0..1000) |i| {
        f.s.onDocChanged(doc, i);
        try f.s.schedule(k, ms(150), r.runFn());
    }
    try testing.expectEqual(@as(u64, 0), counting.allocs.load(.monotonic));
    f.s.cancelDoc(doc);
}

/// Sends one hover per run and keeps the results.
const HoverRuns = struct {
    client: *Client,
    character: u32 = 0,
    mutex: Io.Mutex = .init,
    io: Io,
    results: [2]?Client.Result(.@"textDocument/hover") = .{ null, null },
    done: Io.Event = .unset,

    fn runFn(h: *HoverRuns) sched.RunFn {
        return .{ .ctx = h, .func = run };
    }

    const Slot = struct { h: *HoverRuns, i: usize, token: sched.CancelToken };
    var slots: [2]Slot = undefined;

    fn run(ctx: ?*anyopaque, _: u64, token: sched.CancelToken) void {
        const h: *HoverRuns = @ptrCast(@alignCast(ctx.?));
        h.character += 1;
        const i = h.character - 1;
        slots[i] = .{ .h = h, .i = i, .token = token };
        const handle = h.client.request(.@"textDocument/hover", .{
            .textDocument = .{ .uri = "file:///w/main.zig" },
            .position = .{ .line = 0, .character = h.character },
        }, .{}, .{ .ctx = &slots[i], .func = onResult }) catch unreachable;
        token.bind(h.client, handle);
    }

    fn onResult(ctx: ?*anyopaque, r: Client.Result(.@"textDocument/hover")) void {
        const slot: *Slot = @ptrCast(@alignCast(ctx.?));
        slot.token.done();
        const h = slot.h;
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        h.results[slot.i] = r;
        if (h.results[0] != null and h.results[1] != null) h.done.set(h.io);
    }
};

test "scheduler: supersede cancels in-flight and sends $/cancelRequest" {
    var h: Harness = undefined;
    try h.init("scheduler_supersede.script", .{ .root_uri = "file:///w" });
    defer h.deinit();
    errdefer h.dumpStderr();
    try h.client.start();
    try h.client.waitInitialized(.fromSeconds(10));

    var clock: sched.ManualClock = .{};
    var s: RequestScheduler = .init(&h.rt, clock.clock());
    defer s.deinit();
    var hr: HoverRuns = .{ .client = h.client, .io = h.rt.io };
    const k: sched.SchedKey = .{ .doc = doc, .feature = .hover };
    try s.schedule(k, ms(0), hr.runFn());
    clock.advance(ms(5));
    s.poll();
    try s.schedule(k, ms(0), hr.runFn());
    clock.advance(ms(5));
    s.poll();

    try hr.done.waitTimeout(h.rt.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    defer for (hr.results) |r| r.?.deinit();
    try testing.expect(hr.results[0].? == .canceled);
    try testing.expect(hr.results[1].?.ok.value == null);

    h.client.shutdown();
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try h.exitStatus());
}

test "scheduler: real wheel fires on its worker" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var s: RequestScheduler = .init(&rt, .real(&rt.io));
    defer s.deinit();
    try s.start();
    const Ev = struct {
        event: Io.Event = .unset,
        io: Io,
        fn run(ctx: ?*anyopaque, _: u64, _: sched.CancelToken) void {
            const e: *@This() = @ptrCast(@alignCast(ctx.?));
            e.event.set(e.io);
        }
    };
    var ev: Ev = .{ .io = rt.io };
    try s.schedule(.{ .doc = doc, .feature = .document_highlight }, ms(20), .{ .ctx = &ev, .func = Ev.run });
    try ev.event.waitTimeout(rt.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
}
