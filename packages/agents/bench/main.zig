//! Benchmarks for zg_agents; run with `zig build bench` at the repo root.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_agents = @import("zg_agents");
const bench = zg_core.bench;

const runs = zg_agents.runs;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    try registerRuns(b);
    try registerMission(b);
    try registerNotify(b);
    try registerSched(b);
    try registerTasks(b);
    try registerDocs(b);
    try registerData(b);
}

/// `docs/anchor_resolve_1mb`: re-resolving a sticky anchor in a 1 MB
/// Markdown document after an edit before it (budget 1 ms);
/// `docs/outline_1mb`: its section outline (no budget; for reference);
/// `docs/diff_50k_words`: the word diff between two versions of a
/// 50,000-word document with scattered edits (budget 50 ms).
fn registerDocs(b: *bench.Bench) !void {
    const docs = zg_agents.docs;
    const gpa = std.heap.smp_allocator;
    var text: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (text.items.len < 1 << 20) : (i += 1) {
        try text.print(gpa, "## Section {d}\n\nSome prose about item {d}, with enough words to look like a paragraph of a long document.\n\n", .{ i, i });
    }
    const Ctx = struct { text: []u8, anchors: docs.anchors.Anchors, id: docs.anchors.AnchorId };
    var ctx: Ctx = .{ .text = text.items, .anchors = .{}, .id = 0 };
    ctx.id = try ctx.anchors.create(gpa, text.items, @intCast(text.items.len - 4096), .right);
    try b.run("docs/anchor_resolve_1mb", &ctx, struct {
        fn f(c: *Ctx, s: *bench.State) void {
            var n: u64 = 0;
            while (n < s.iterations()) : (n += 1) {
                // An edit far before the anchor, then resolve it.
                c.anchors.applyEdit(100, 0, 0);
                bench.doNotOptimizeAway(c.anchors.resolve(c.id, c.text));
            }
        }
    }.f);
    try b.run("docs/outline_1mb", &ctx, struct {
        fn f(c: *Ctx, s: *bench.State) void {
            var n: u64 = 0;
            while (n < s.iterations()) : (n += 1) {
                var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
                defer arena.deinit();
                bench.doNotOptimizeAway(docs.sections.outline(arena.allocator(), c.text) catch unreachable);
            }
        }
    }.f);

    var old: std.ArrayList(u8) = .empty;
    var new: std.ArrayList(u8) = .empty;
    var w: usize = 0;
    var p: usize = 0;
    while (w < 50_000) : (p += 1) {
        try old.print(gpa, "Paragraph {d} says the quick brown fox jumps over the lazy dog again and again.\n\n", .{p});
        if (p % 25 == 0) try new.print(gpa, "Paragraph {d} says the quick red fox jumps over the lazy dog again and again.\n\n", .{p}) else try new.print(gpa, "Paragraph {d} says the quick brown fox jumps over the lazy dog again and again.\n\n", .{p});
        if (p % 40 == 0) try new.print(gpa, "An added paragraph {d}.\n\n", .{p});
        w += 16;
    }
    const Pair = struct { old: []const u8, new: []const u8 };
    var pair: Pair = .{ .old = old.items, .new = new.items };
    try b.run("docs/diff_50k_words", &pair, struct {
        fn f(c: *Pair, s: *bench.State) void {
            var n: u64 = 0;
            while (n < s.iterations()) : (n += 1) {
                var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
                defer arena.deinit();
                bench.doNotOptimizeAway(docs.versions.diffWords(arena.allocator(), c.old, c.new) catch unreachable);
            }
        }
    }.f);
}

/// `tasks/index_10k`: a cold open of a board of 10,000 task files
/// (budget 250 ms); `tasks/query_10k`: a filtered, sorted query over it
/// (budget 10 ms). The files live in a scratch directory under the
/// working directory.
fn registerTasks(b: *bench.Bench) !void {
    const tasks = zg_agents.tasks;
    const gpa = std.heap.smp_allocator;
    const io = b.io;
    const cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/bench-tasks";
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/.zigguro/tasks");
    var ws = try cwd.openDir(io, root, .{});
    defer ws.close(io);
    defer cwd.deleteTree(io, root) catch {};
    const statuses = [_][]const u8{ "backlog", "ready", "in_progress", "review", "done" };
    var name: [64]u8 = undefined;
    var body: [512]u8 = undefined;
    for (1..10_001) |i| {
        const n = try std.fmt.bufPrint(&name, ".zigguro/tasks/T-{d:0>4}-task-number-{d}.md", .{ i, i });
        const dep: usize = if (i > 10) i - 10 else 0;
        const data = try std.fmt.bufPrint(&body,
            \\---
            \\id: T-{d:0>4}
            \\title: Task number {d} about {s}
            \\status: {s}
            \\priority: P{d}
            \\assignee: {s}
            \\labels: [area-{d}, {s}]
            \\depends_on: [T-{d:0>4}]
            \\due: 2026-{d:0>2}-{d:0>2}
            \\created: 2026-01-01T00:00:00Z
            \\---
            \\# Task number {d}
            \\
            \\Some body text that the index does not need to read.
            \\
        , .{ i, i, if (i % 3 == 0) "parsing" else "layout", statuses[i % statuses.len], i % 4, if (i % 2 == 0) "agent:coder" else "alice", i % 20, if (i % 5 == 0) "bug" else "feature", dep, 1 + i % 12, 1 + i % 28, i });
        try ws.writeFile(io, .{ .sub_path = n, .data = data });
    }
    const Ctx = struct { ws: std.Io.Dir, io: std.Io };
    const ctx: Ctx = .{ .ws = ws, .io = io };
    try b.run("tasks/index_10k", &ctx, struct {
        fn f(c: *const Ctx, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                const st = tasks.TaskStore.open(std.heap.smp_allocator, c.io, c.ws, .{}) catch unreachable;
                bench.doNotOptimizeAway(st.view().tasks.len);
                st.release(st.view());
                st.close();
            }
        }
    }.f);
    const store = try tasks.TaskStore.open(gpa, io, ws, .{});
    defer store.close();
    const v = store.view();
    defer store.release(v);
    const Q = struct { v: *const tasks.TasksView };
    try b.run("tasks/query_10k", &Q{ .v = v }, struct {
        fn f(c: *const Q, s: *bench.State) void {
            var i: u64 = 0;
            var out: std.ArrayList(u32) = .empty;
            defer out.deinit(std.heap.smp_allocator);
            while (i < s.iterations()) : (i += 1) {
                var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
                defer arena.deinit();
                const q = tasks.parseQuery(arena.allocator(), "status:ready,review -blocked:true assignee:agent:* parsing sort:due") catch unreachable;
                out.clearRetainingCapacity();
                tasks.query.evalQueryAt(c.v, &q, .{ .y = 2026, .m = 10, .d = 23 }, &out, std.heap.smp_allocator) catch unreachable;
                bench.doNotOptimizeAway(out.items.len);
            }
        }
    }.f);
}

/// `cron/next`: the next fire time of a weekday-office-hours expression
/// in a fixed zone (budget 2 us).
fn registerSched(b: *bench.Bench) !void {
    const sched = zg_agents.sched;
    const Ctx = struct { c: sched.CronExpr, z: sched.FixedZone };
    const ctx: Ctx = .{ .c = try sched.CronExpr.parse("*/15 9-17 * * mon-fri"), .z = .{ .offset_s = 5 * 3600 + 1800 } };
    try b.run("cron/next", &ctx, struct {
        fn f(c: *const Ctx, s: *bench.State) void {
            const zr = c.z.resolver();
            var t: i64 = 1_790_000_000;
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                // Step by an odd number of minutes to land everywhere.
                t = (c.c.next(zr, t + 7 * 3600 + 13 * 60) orelse unreachable);
                bench.doNotOptimizeAway(t);
            }
        }
    }.f);
    try registerTriggers(b);
}

/// `triggers/fire`: a file event matched against 50 automations' globs,
/// then the poll after its debounce window that hands the fire to the
/// port: the trigger-to-run-start latency the engine adds (budget 50 ms).
fn registerTriggers(b: *bench.Bench) !void {
    const sched = zg_agents.sched;
    const gpa = std.heap.smp_allocator;
    const Env = struct {
        ms: i64 = 0,
        fires: u64 = 0,
        fn now(ctx: ?*anyopaque) i64 {
            const e: *@This() = @ptrCast(@alignCast(ctx.?));
            return e.ms;
        }
        fn fire(ctx: *anyopaque, _: []const u8, _: []const u8, _: sched.Scheduler.EventFire) anyerror!?u64 {
            const e: *@This() = @ptrCast(@alignCast(ctx));
            e.fires += 1;
            return e.fires;
        }
        fn skip(_: *anyopaque, _: []const u8, _: sched.Scheduler.Skip) void {}
    };
    var env: Env = .{};
    const t = try sched.TriggerEngine.init(gpa, b.io, .{ .ctx = &env, .fire = Env.fire, .skip = Env.skip }, .{ .clock = .{ .ctx = &env, .nowRealMs = Env.now } });
    defer t.deinit();
    var list: [50]sched.Automation = undefined;
    var names: [50][8]u8 = undefined;
    for (&list, 0..) |*a, i| a.* = .{
        .name = std.fmt.bufPrint(&names[i], "a{d}", .{i}) catch unreachable,
        .triggers = &.{.{ .files = .{ .globs = &.{ "src/**/*.{zig,zon}", "!src/gen/**" }, .debounce_ms = 100 } }},
        .action = .{ .agent = .{ .prompt = "x" } },
    };
    try t.setAutomations(&list);
    const Ctx = struct { t: *sched.TriggerEngine, env: *Env };
    const ctx: Ctx = .{ .t = t, .env = &env };
    try b.run("triggers/fire", &ctx, struct {
        fn f(c: *const Ctx, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                c.t.onFileEvents(&.{.{ .path = "src/pkg/deep/file.zig", .kind = .modified }});
                c.env.ms += 100;
                bench.doNotOptimizeAway(c.t.poll());
            }
        }
    }.f);
}

/// `notify/decide`: the policy and coalescing decision `post` makes
/// under its lock (budget 10 us).
fn registerNotify(b: *bench.Bench) !void {
    const notify = zg_agents.notify;
    var rt: zg_core.Runtime = undefined;
    try rt.initBorrowed(std.heap.smp_allocator, b.io, 64);
    defer _ = rt.deinit();
    const r = try notify.NotificationRouter.init(std.heap.smp_allocator, &rt, null, null, .{}, .{ .inline_delivery = true });
    defer r.deinit();
    try b.run("notify/decide", r, struct {
        fn f(router: *notify.NotificationRouter, s: *bench.State) void {
            var i: u64 = 0;
            var key: [24]u8 = undefined;
            while (i < s.iterations()) : (i += 1) {
                const n: notify.Notification = .{
                    .key = std.fmt.bufPrint(&key, "run:{d}", .{i % 512}) catch unreachable,
                    .group = if (i % 4 == 0) "wf:bench" else null,
                    .severity = .success,
                    .title = "Done",
                };
                bench.doNotOptimizeAway(router.decide(&n) catch unreachable);
            }
        }
    }.f);
}

/// `mission/open_500`: Mission Control's first frame over 500 runs (budget
/// 16 ms); `mission/stream_50`: 50 working runs each report a summary and
/// the view-model catches up (one frame; budget 1 ms).
fn registerMission(b: *bench.Bench) !void {
    const mission = zg_agents.mission;
    const Ctx = struct { reg: *runs.RunRegistry, ids: []runs.RunId, vm: *mission.MissionVM };
    const gpa = std.heap.smp_allocator;
    const io = b.io;
    const reg = try runs.RunRegistry.init(gpa, io, null, .{});
    const ids = try gpa.alloc(runs.RunId, 500);
    for (ids, 0..) |*id, i| {
        id.* = try reg.createWithId(.fromInt(@as(u128, i + 1) << 80), .{ .kind = .background, .title = "bench run", .prompt = "summarise the logs" });
        // 50 working, 30 waiting, the rest done.
        if (i < 80) {
            try reg.update(id.*, .{ .status = .starting });
            try reg.update(id.*, .{ .status = .working });
            if (i >= 50) {
                try reg.update(id.*, .{ .question = "Allow the command?" });
                try reg.update(id.*, .{ .status = .needs_input });
            }
        } else if (i % 7 != 0) {
            try reg.update(id.*, .{ .status = .starting });
            try reg.update(id.*, .{ .status = .working });
            try reg.update(id.*, .{ .summary = "Done: 3 files changed" });
            try reg.update(id.*, .{ .status = .completed });
        }
    }
    var vm: mission.MissionVM = .init(gpa);
    const ctx: Ctx = .{ .reg = reg, .ids = ids, .vm = &vm };
    try b.run("mission/open_500", ctx, struct {
        fn f(c: Ctx, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                var m: mission.MissionVM = .init(std.heap.smp_allocator);
                const v = c.reg.snapshot();
                m.apply(v, .none, 1_000) catch unreachable;
                bench.doNotOptimizeAway(m.rows().len);
                c.reg.release(v);
                m.deinit();
            }
        }
    }.f);
    {
        const v = reg.snapshot();
        try vm.apply(v, .none, 1_000);
        reg.release(v);
    }
    try b.run("mission/stream_50", ctx, struct {
        fn f(c: Ctx, s: *bench.State) void {
            var i: u64 = 0;
            var buf: [32]u8 = undefined;
            while (i < s.iterations()) : (i += 1) {
                const text = std.fmt.bufPrint(&buf, "step {d}", .{i}) catch unreachable;
                for (c.ids[0..50]) |id| c.reg.update(id, .{ .summary = text }) catch unreachable;
                const v = c.reg.snapshot();
                c.vm.apply(v, .none, @intCast(2_000 + i)) catch unreachable;
                bench.doNotOptimizeAway(c.vm.rows().len);
                c.reg.release(v);
            }
        }
    }.f);
    vm.deinit();
    reg.deinit();
    gpa.free(ids);
}

/// `runs/update_500`: one cost update (copy-on-write record + view
/// publish) with 500 runs; `runs/snapshot`: retain and release the view.
fn registerRuns(b: *bench.Bench) !void {
    const Ctx = struct { reg: *runs.RunRegistry, ids: []runs.RunId };
    const gpa = std.heap.smp_allocator;
    const io = b.io;
    const reg = try runs.RunRegistry.init(gpa, io, null, .{});
    const ids = try gpa.alloc(runs.RunId, 500);
    for (ids, 0..) |*id, i| {
        id.* = try reg.createWithId(.fromInt(@as(u128, i + 1) << 80), .{ .kind = .background, .title = "bench run", .prompt = "p" });
    }
    const ctx: Ctx = .{ .reg = reg, .ids = ids };
    try b.run("runs/update_500", ctx, struct {
        fn f(c: Ctx, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                c.reg.update(c.ids[i % c.ids.len], .{ .cost = .{ .micros = i } }) catch unreachable;
            }
        }
    }.f);
    try b.run("runs/snapshot", ctx, struct {
        fn f(c: Ctx, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                const v = c.reg.snapshot();
                bench.doNotOptimizeAway(v.runs.len);
                c.reg.release(v);
            }
        }
    }.f);
    reg.deinit();
    gpa.free(ids);
}

/// `data/csv_index_256mb`: the full parallel row index of a 256 MiB CSV
/// with quoted multi-line fields (budget: 1 GB/s a core, so 256 ms on
/// one core); `data/first_screen_256mb`: opening it from disk until the
/// first screen's cells read (budget 200 ms; the full index runs in the
/// background and is canceled at close). The 1 GB budget scales from
/// these; the file lives in a scratch directory under the working
/// directory.
fn registerData(b: *bench.Bench) !void {
    const data = zg_agents.data;
    const gpa = std.heap.smp_allocator;
    const io = b.io;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var i: usize = 0;
    while (text.items.len < 256 << 20) : (i += 1) {
        if (i % 9 == 0) {
            try text.print(gpa, "{d},\"note {d}\nwith, a comma and \"\"quotes\"\"\",{d}.{d},2026-10-23\n", .{ i, i, i % 1000, i % 97 });
        } else try text.print(gpa, "{d},plain row {d},{d}.{d},2026-10-23\n", .{ i, i, i % 1000, i % 97 });
    }
    const Ctx = struct { bytes: []const u8, io: std.Io };
    var ctx: Ctx = .{ .bytes = text.items, .io = io };
    try b.run("data/csv_index_256mb", &ctx, struct {
        fn f(c: *Ctx, s: *bench.State) void {
            var n: u64 = 0;
            while (n < s.iterations()) : (n += 1) {
                var ix: data.RowIndex = .init(std.heap.smp_allocator);
                defer ix.deinit();
                var progress: std.atomic.Value(u64) = .init(0);
                const cancel: std.atomic.Value(bool) = .init(false);
                data.row_index.buildIndex(c.io, c.bytes, .{}, &ix, &progress, &cancel) catch unreachable;
                bench.doNotOptimizeAway(ix.count());
            }
        }
    }.f);

    const cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/bench-data";
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);
    defer cwd.deleteTree(io, root) catch {};
    var dir = try cwd.openDir(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "big.csv", .data = text.items });
    const Open = struct { dir: std.Io.Dir, io: std.Io };
    var open: Open = .{ .dir = dir, .io = io };
    try b.run("data/first_screen_256mb", &open, struct {
        fn f(c: *Open, s: *bench.State) void {
            var n: u64 = 0;
            while (n < s.iterations()) : (n += 1) {
                const ds = data.Dataset.open(std.heap.smp_allocator, c.io, c.dir, "big.csv", null) catch unreachable;
                defer ds.close();
                var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
                defer arena.deinit();
                var r: u64 = 0;
                while (r < 60) : (r += 1) {
                    var col: u32 = 0;
                    while (col < 4) : (col += 1) bench.doNotOptimizeAway(ds.cell(r, col, arena.allocator()) catch unreachable);
                }
            }
        }
    }.f);
}
