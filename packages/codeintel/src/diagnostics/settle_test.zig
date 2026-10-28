//! Settle detection: the rules on an injected clock (versions, progress,
//! quiet periods, silent servers, timeouts, crashes, build-on-save, the
//! check task), then the driver against the fake server (a push without
//! a version, a pull asked at once).

const std = @import("std");
const zg_editor = @import("zg_editor");
const zg_lsp = @import("zg_lsp");
const Store = @import("Store.zig");
const convert = @import("convert.zig");
const Driver = @import("Driver.zig");
const SettleDetector = @import("settle.zig");
const Harness = @import("../Manager_test.zig").Harness;

const testing = std.testing;
const gpa = testing.allocator;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
const pt = zg_editor.model.buffer.piece_tree;
const protocol = zg_lsp.protocol;
const Row = SettleDetector.Row;
const ServerState = SettleDetector.ServerState;

const ms = std.time.ns_per_ms;
const path = "/w/a.zig";

/// A detector on a fake clock: every sleep advances it and then runs the
/// test's `step`, which plays the servers.
const Fx = struct {
    rt: @import("zg_core").Runtime,
    st: Store,
    sd: SettleDetector,
    now_ns: i96 = 0,
    step: *const fn (f: *Fx) anyerror!void = noStep,
    /// The test's own state.
    n: u32 = 0,
    build_runs: u32 = 0,

    fn init(f: *Fx, opts: SettleDetector.Options) !void {
        f.rt.initTesting();
        f.st = try .init(gpa, f.rt.io, .posix);
        var o = opts;
        o.clock = .{ .ctx = f, .now = now, .sleep = sleep };
        f.sd = .init(gpa, f.rt.io, &f.st, o);
        f.now_ns = 1000 * ms;
        f.step = noStep;
        f.n = 0;
        f.build_runs = 0;
    }

    fn deinit(f: *Fx) void {
        f.sd.deinit();
        f.st.deinit();
        _ = f.rt.deinit();
    }

    fn noStep(_: *Fx) anyerror!void {}

    fn now(ctx: ?*anyopaque, _: Io) i96 {
        const f: *Fx = @ptrCast(@alignCast(ctx.?));
        return f.now_ns;
    }

    fn sleep(ctx: ?*anyopaque, _: Io, d: Io.Duration) Io.Cancelable!void {
        const f: *Fx = @ptrCast(@alignCast(ctx.?));
        f.now_ns += d.nanoseconds;
        f.step(f) catch @panic("step failed");
    }

    /// Milliseconds since the wait began (it begins at 1000 ms).
    fn at(f: *const Fx) i96 {
        return @divTrunc(f.now_ns, ms) - 1000;
    }

    fn key(f: *Fx) []const u8 {
        return f.st.keyOfPath(f.arena(), path) catch unreachable;
    }

    var arena_state: std.heap.ArenaAllocator = undefined;
    fn arena(_: *Fx) Allocator {
        return arena_state.allocator();
    }

    fn table(f: *Fx, row: Row, server: ServerState) !void {
        var r = row;
        r.key = f.key();
        var s = server;
        s.setName("zls");
        try f.sd.set(&.{r}, &.{s});
    }

    fn diags(f: *Fx, owner: Store.Owner, items: []const protocol.Diagnostic) !void {
        const set = try Store.Set.create(gpa, owner);
        errdefer set.destroy();
        try convert.fromLsp(set, items);
        try f.st.replace(f.key(), owner, set);
        f.st.commit();
    }

    fn wait(f: *Fx, req: SettleDetector.Request) !SettleDetector.Result {
        return f.sd.wait(f.rt.io, f.arena(), req);
    }
};

fn lspDiag(line: u32, sev: protocol.DiagnosticSeverity, msg: []const u8) protocol.Diagnostic {
    return .{
        .range = .{ .start = .{ .line = line, .character = 4 }, .end = .{ .line = line, .character = 5 } },
        .severity = sev,
        .message = .{ .string = msg },
        .source = "zls",
    };
}

/// The row of a server sent version 2 at the start, last reporting on 1.
fn sent2() Row {
    return .{ .key = "", .server = 0, .sent = 2, .sent_ns = 1000 * ms, .reported = 1, .report_ns = 900 * ms };
}

const one = &.{path};

fn setup(f: *Fx) !void {
    Fx.arena_state = .init(gpa);
    try f.init(.{});
}

fn teardown(f: *Fx) void {
    f.deinit();
    Fx.arena_state.deinit();
}

test "settle: push with version" {
    var f: Fx = undefined;
    try setup(&f);
    defer teardown(&f);
    try f.table(sent2(), .{ .id = 0 });
    f.step = struct {
        fn s(x: *Fx) !void {
            // The push for version 2 at 100 ms.
            if (x.at() >= 100 and x.n == 0) {
                x.n = 1;
                try x.diags(.{ .server = 0 }, &.{lspDiag(3, .Error, "expected type 'u32', found '[]const u8'")});
                var r = sent2();
                r.reported = 2;
                r.report_ns = x.now_ns;
                try x.table(r, .{ .id = 0 });
            }
        }
    }.s;
    const r = try f.wait(.{ .paths = one });
    try testing.expect(r.settled and !r.heuristic and r.reason == null);
    // Quiet for 300 ms after the push.
    try testing.expect(r.waited_ns >= 400 * ms and r.waited_ns < 430 * ms);
    try testing.expectEqual(@as(usize, 1), r.errors);
    try testing.expectEqualStrings(
        \\1 error, 0 warnings:
        \\a.zig:4:5: error: expected type 'u32', found '[]const u8' [zls]
    , try f.sd.renderResult(f.arena(), r, one, "/w"));
}

test "settle: quiet period resets on new publish" {
    var f: Fx = undefined;
    try setup(&f);
    defer teardown(&f);
    try f.table(sent2(), .{ .id = 0 });
    f.step = struct {
        fn s(x: *Fx) !void {
            // Pushes for version 2 at 100 ms and again at 300 ms.
            const due: [2]i96 = .{ 100, 300 };
            if (x.n < 2 and x.at() >= due[x.n]) {
                x.n += 1;
                var r = sent2();
                r.reported = 2;
                r.report_ns = x.now_ns;
                try x.table(r, .{ .id = 0 });
            }
        }
    }.s;
    const r = try f.wait(.{ .paths = one });
    try testing.expect(r.settled and !r.heuristic);
    try testing.expect(r.waited_ns >= 600 * ms and r.waited_ns < 630 * ms);
}

test "settle: waits for progress end" {
    var f: Fx = undefined;
    try setup(&f);
    defer teardown(&f);
    var row = sent2();
    row.reported = 2;
    try f.table(row, .{ .id = 0, .progress = 1 });
    f.step = struct {
        fn s(x: *Fx) !void {
            // Indexing ends at 2 s.
            if (x.at() >= 2000 and x.n == 0) {
                x.n = 1;
                var r = sent2();
                r.reported = 2;
                try x.table(r, .{ .id = 0 });
            }
        }
    }.s;
    const r = try f.wait(.{ .paths = one });
    try testing.expect(r.settled);
    try testing.expect(r.waited_ns >= 2000 * ms and r.waited_ns < 2030 * ms);
}

test "settle: heuristic for silent servers" {
    var f: Fx = undefined;
    try setup(&f);
    defer teardown(&f);
    // The server reported on version 1 and says nothing about version 2.
    try f.diags(.{ .server = 0 }, &.{lspDiag(1, .Warning, "unused local constant")});
    try f.table(sent2(), .{ .id = 0 });
    const r = try f.wait(.{ .paths = one });
    try testing.expect(r.settled and r.heuristic and r.reason == null);
    // quiet × 3 after the send.
    try testing.expect(r.waited_ns >= 900 * ms and r.waited_ns < 930 * ms);
    try testing.expectEqual(@as(usize, 1), r.warnings);
    try testing.expect(std.mem.endsWith(u8, try f.sd.renderResult(f.arena(), r, one, "/w"), "(A server sent nothing new for this version; its last report is shown.)"));
}

test "settle: timeout returns partial with reason" {
    var f: Fx = undefined;
    try setup(&f);
    defer teardown(&f);
    try f.diags(.{ .server = 0 }, &.{lspDiag(1, .Error, "old")});
    try f.table(sent2(), .{ .id = 0, .progress = 2 });
    var r = try f.wait(.{ .paths = one, .timeout = .fromSeconds(2) });
    try testing.expect(!r.settled and r.reason.? == .timeout_indexing);
    try testing.expect(r.waited_ns >= 2000 * ms and r.waited_ns < 2030 * ms);
    try testing.expectEqual(@as(usize, 1), r.errors);
    try testing.expectEqualStrings(
        \\1 error, 0 warnings:
        \\a.zig:2:5: error: old [zls]
        \\Timed out after 2.0 s while the language server was still busy (indexing); this may be out of date.
    , try f.sd.renderResult(f.arena(), r, one, "/w"));
    // Not busy, still editing: no publish.
    var dirty = sent2();
    dirty.dirty = true;
    try f.table(dirty, .{ .id = 0 });
    r = try f.wait(.{ .paths = one, .timeout = .fromSeconds(1) });
    try testing.expect(r.reason.? == .timeout_no_publish);
}

test "settle: server crashed returns what it had" {
    var f: Fx = undefined;
    try setup(&f);
    defer teardown(&f);
    try f.table(sent2(), .{ .id = 0 });
    f.step = struct {
        fn s(x: *Fx) !void {
            if (x.at() >= 50) try x.sd.set(&.{}, &.{.{ .id = 0, .status = .crashed, .name_buf = "zls".* ++ @as([29]u8, @splat(0)), .name_len = 3 }});
        }
    }.s;
    const r = try f.wait(.{ .paths = one });
    try testing.expect(!r.settled and r.reason.? == .server_crashed);
    try testing.expectEqualStrings("zls", r.crashed.?);
    try testing.expect(r.waited_ns < 100 * ms);
}

test "settle: zls build-on-save extension" {
    var f: Fx = undefined;
    try setup(&f);
    defer teardown(&f);
    var row = sent2();
    row.reported = 2;
    row.report_ns = 1000 * ms;
    // A server that builds on save: 1.5 s quiet...
    try f.table(row, .{ .id = 0, .builds = true });
    var r = try f.wait(.{ .paths = one });
    try testing.expect(r.settled);
    try testing.expect(r.waited_ns >= 1500 * ms and r.waited_ns < 1530 * ms);
    // ...unless its build ends first (at 600 ms; the build's publish
    // came with it).
    f.now_ns = 1000 * ms;
    try f.table(row, .{ .id = 0, .builds = true });
    f.n = 0;
    f.step = struct {
        fn s(x: *Fx) !void {
            if (x.at() >= 600 and x.n == 0) {
                x.n = 1;
                var rr = sent2();
                rr.reported = 2;
                rr.report_ns = x.now_ns;
                try x.table(rr, .{ .id = 0, .builds = true, .build_end_ns = x.now_ns });
            }
        }
    }.s;
    r = try f.wait(.{ .paths = one });
    try testing.expect(r.settled);
    try testing.expect(r.waited_ns >= 900 * ms and r.waited_ns < 930 * ms);
}

test "settle: pull asked at once; slack for an edit not sent yet" {
    var f: Fx = undefined;
    try setup(&f);
    defer teardown(&f);
    // Last sent long ago: the edit may still be on its way.
    var row = sent2();
    row.sent_ns = 0;
    row.reported = 2;
    row.report_ns = 0;
    try f.table(row, .{ .id = 0 });
    f.step = struct {
        fn s(x: *Fx) !void {
            if (x.n > 0) return;
            x.n = 1;
            var pulls: std.ArrayList([]u8) = .empty;
            defer {
                for (pulls.items) |k| gpa.free(k);
                pulls.deinit(gpa);
            }
            try x.sd.takePulls(&pulls);
            try testing.expectEqual(@as(usize, 1), pulls.items.len);
            try testing.expectEqualStrings(x.key(), pulls.items[0]);
        }
    }.s;
    const r = try f.wait(.{ .paths = one });
    try testing.expect(r.settled and f.n == 1);
    try testing.expect(r.waited_ns >= 250 * ms and r.waited_ns < 280 * ms);
}

const FakeBuild = struct {
    fn run(ctx: *anyopaque, _: Io, _: Allocator, timeout: Io.Duration) anyerror!SettleDetector.BuildSummary {
        const f: *Fx = @ptrCast(@alignCast(ctx));
        f.build_runs += 1;
        try testing.expect(timeout.nanoseconds > 0);
        try f.diags(.{ .task = 1 }, &.{lspDiag(9, .Error, "expected ';' after statement")});
        f.now_ns += 1200 * ms;
        return .{ .label = "zig build check", .ok = false, .exit_code = 1, .duration_ns = 1200 * ms };
    }
};

test "settle: no server -> build check fallback" {
    var f: Fx = undefined;
    try setup(&f);
    defer teardown(&f);
    // Without a check task: said so, at once.
    var r = try f.wait(.{ .paths = one });
    try testing.expect(r.reason.? == .no_server and r.build == null and r.waited_ns == 0);
    try testing.expect(std.mem.endsWith(u8, try f.sd.renderResult(f.arena(), r, one, "/w"), "No language server checks a.zig, and there is no check task to run."));

    f.sd.build = .{ .ctx = &f, .run = FakeBuild.run };
    r = try f.wait(.{ .paths = one });
    try testing.expectEqual(@as(u32, 1), f.build_runs);
    try testing.expect(r.reason.? == .no_server and !r.build.?.ok);
    try testing.expectEqualStrings(
        \\1 error, 0 warnings:
        \\a.zig:10:5: error: expected ';' after statement [zls]
        \\Ran zig build check: failed (exit 1) in 1.2 s.
    , try f.sd.renderResult(f.arena(), r, one, "/w"));
    // `never` skips it; `always` runs it with a server too.
    _ = try f.wait(.{ .paths = one, .build_check = .never });
    try testing.expectEqual(@as(u32, 1), f.build_runs);
    var row = sent2();
    row.reported = 2;
    try f.table(row, .{ .id = 0 });
    r = try f.wait(.{ .paths = one, .build_check = .always });
    try testing.expect(r.settled and r.reason == null and r.build != null);
    try testing.expectEqual(@as(u32, 2), f.build_runs);

    // A run in progress: the request takes its result instead of running
    // again.
    try f.sd.set(&.{}, &.{});
    f.sd.build_running = true;
    f.n = 0;
    f.step = struct {
        fn s(x: *Fx) !void {
            if (x.at() >= 40 and x.n == 0) {
                x.n = 1;
                const label = try gpa.dupe(u8, "zig build");
                defer gpa.free(label);
                x.sd.finishBuild(.{ .label = label, .ok = true });
            }
        }
    }.s;
    f.now_ns = 1000 * ms;
    r = try f.wait(.{ .paths = one });
    try testing.expectEqual(@as(u32, 2), f.build_runs);
    try testing.expect(r.build.?.ok);
    try testing.expectEqualStrings("zig build", r.build.?.label);
}

test "settle: a server still starting is waited for" {
    var f: Fx = undefined;
    try setup(&f);
    defer teardown(&f);
    try f.sd.set(&.{}, &.{.{ .id = 0, .status = .starting }});
    f.step = struct {
        fn s(x: *Fx) !void {
            if (x.at() >= 500 and x.n == 0) {
                x.n = 1;
                try x.table(.{ .key = "", .server = 0, .sent = 1, .sent_ns = x.now_ns, .reported = 1, .report_ns = x.now_ns }, .{ .id = 0 });
            }
        }
    }.s;
    const r = try f.wait(.{ .paths = one });
    try testing.expect(r.settled and r.reason == null);
    try testing.expect(r.waited_ns >= 800 * ms and r.waited_ns < 830 * ms);
}

// ------------------------------------------------------------- driver

fn edit(h: *Harness, d: DocHandle, a: usize, b: usize, text: []const u8) !void {
    const doc = h.docs.get(d).?;
    var cs = try ChangeSet.fromEdits(gpa, doc.len(), &.{pt.Edit{ .range = .{ .start = a, .end = b }, .text = text }});
    defer cs.deinit();
    try doc.applyChangeSet(&cs, .{ .user = 0 });
}

/// The driver on the fake server, waited on from another thread.
const Live = struct {
    h: Harness,
    st: Store,
    d: Driver,
    doc: DocHandle,
    arena: std.heap.ArenaAllocator,
    result: ?SettleDetector.Result = null,
    done: std.atomic.Value(bool) = .init(false),

    fn init(l: *Live, script: []const u8, opts: Driver.Options) !void {
        try l.h.init(script, &.{});
        l.st = try .init(gpa, l.h.rt.io, .native);
        try l.d.init(&l.h.mgr, &l.st, opts);
        l.doc = try l.h.open("main.zig", "const a = 1;\n");
        l.arena = .init(gpa);
        l.result = null;
        l.done = .init(false);
    }

    fn deinit(l: *Live) void {
        l.h.mgr.closeDoc(l.doc);
        l.h.docs.release(l.doc);
        l.h.mgr.deinit();
        l.d.deinit();
        l.h.mgr = undefined;
        l.st.deinit();
        l.h.docs.deinit();
        l.h.reg.deinit();
        gpa.free(l.h.script);
        l.h.tmp.cleanup();
        l.arena.deinit();
        _ = l.h.rt.deinit();
    }

    fn pump(l: *Live, comptime done: fn (*Live) bool) !void {
        for (0..2000) |_| {
            l.h.mgr.tick();
            _ = l.d.tick();
            if (done(l)) return;
            try l.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }

    fn reported(l: *Live) bool {
        return l.d.tracks.count() == 1 and l.d.tracks.values()[0].reported != null;
    }

    fn finished(l: *Live) bool {
        return l.done.load(.acquire);
    }

    fn run(l: *Live, io: Io) void {
        const p = std.fs.path.join(l.arena.allocator(), &.{ l.h.ws, "main.zig" }) catch return;
        l.result = l.d.settle.wait(io, l.arena.allocator(), .{ .paths = &.{p}, .timeout = .fromSeconds(5) }) catch null;
        l.done.store(true, .release);
    }

    fn waitAfterEdit(l: *Live) !SettleDetector.Result {
        try edit(&l.h, l.doc, 0, 5, "+");
        var fut = try l.h.rt.io.concurrent(run, .{ l, l.h.rt.io });
        defer fut.cancel(l.h.rt.io);
        try l.pump(finished);
        return l.result orelse error.TestUnexpectedResult;
    }
};

test "settle: push without version uses sent version" {
    var l: Live = undefined;
    try l.init("settle_push.script", .{});
    defer l.deinit();
    try l.pump(Live.reported);
    const r = try l.waitAfterEdit();
    // The versionless push after the edit is about version 2: settled,
    // not by the silent-server rule.
    try testing.expect(r.settled and !r.heuristic and r.reason == null);
    try testing.expectEqual(@as(usize, 1), r.errors);
    try testing.expectEqualStrings("expected expression", r.diags[0].message);
    try testing.expect(r.waited_ns < 900 * ms);
}

test "settle: pull triggered" {
    var l: Live = undefined;
    // Ten seconds of debounce: only the wait's own ask is fast.
    try l.init("settle_pull.script", .{ .pull = .{ .debounce = .fromSeconds(10) } });
    defer l.deinit();
    try l.pump(Live.reported);
    const r = try l.waitAfterEdit();
    try testing.expect(r.settled and !r.heuristic);
    try testing.expectEqual(@as(usize, 1), r.errors);
    try testing.expectEqualStrings("after the edit", r.diags[0].message);
    try testing.expect(r.waited_ns < 2 * std.time.ns_per_s);
}
