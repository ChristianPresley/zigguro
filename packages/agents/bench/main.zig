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
    try registerVector(b);
    try registerChart(b);
    try registerGrid(b);
    try registerDiagram(b);
    try registerLibrary(b);
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

/// `data/profile_1m_col` and `data/query_10m` (see below);
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

    // `data/profile_1m_col`: column statistics of a 1 M-row numeric
    // column (budget 200 ms).
    var small: std.ArrayList(u8) = .empty;
    defer small.deinit(gpa);
    try small.appendSlice(gpa, "id,score,city\n");
    for (0..1_000_000) |r| try small.print(gpa, "{d},{d}.{d},city{d}\n", .{ r, r % 9973, r % 10, r % 300 });
    const profiled = try data.Dataset.openBytes(gpa, io, small.items, .csv);
    defer profiled.close();
    try profiled.waitIndexed();
    const Prof = struct { ds: *data.Dataset, io: std.Io };
    var prof: Prof = .{ .ds = profiled, .io = io };
    try b.run("data/profile_1m_col", &prof, struct {
        fn f(c: *Prof, s: *bench.State) void {
            var n: u64 = 0;
            while (n < s.iterations()) : (n += 1) {
                var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
                defer arena.deinit();
                const cancel: std.atomic.Value(bool) = .init(false);
                bench.doNotOptimizeAway(data.stats.computeStats(c.io, c.ds, 1, arena.allocator(), &cancel) catch unreachable);
            }
        }
    }.f);

    // `data/query_10m`: filter + group over 10 M rows (budget 1.5 s on
    // 8 cores).
    var tenm: std.ArrayList(u8) = .empty;
    defer tenm.deinit(gpa);
    try tenm.ensureTotalCapacity(gpa, 10_000_000 * 20);
    try tenm.appendSlice(gpa, "k,v,f\n");
    var h: u64 = 1;
    for (0..10_000_000) |r| {
        h = h *% 6364136223846793005 +% 1442695040888963407;
        try tenm.print(gpa, "k{d},{d},{d}.{d}\n", .{ (h >> 33) % 1000, (h >> 20) % 1000, r % 977, (h >> 40) % 10 });
    }
    const qds = try data.Dataset.openBytes(gpa, io, tenm.items, .csv);
    defer qds.close();
    try qds.waitIndexed();
    const Query = struct {
        ds: *data.Dataset,
        io: std.Io,
        plan: data.query.Plan,

        fn get(self: *anyopaque, _: []const u8) ?*data.Dataset {
            const qq: *@This() = @ptrCast(@alignCast(self));
            return qq.ds;
        }

        fn batch(_: *anyopaque, cols: []const data.query.exec.ColumnVec, n: u32) anyerror!void {
            bench.doNotOptimizeAway(cols.len + n);
        }
    };
    var plan_arena: std.heap.ArenaAllocator = .init(gpa);
    defer plan_arena.deinit();
    const schema_cols = [_]data.query.types.SchemaCol{
        .{ .name = "k", .ty = .string },
        .{ .name = "v", .ty = .int },
        .{ .name = "f", .ty = .float },
    };
    const Cat = struct {
        fn resolve(_: *anyopaque, _: []const u8) ?data.query.types.Schema {
            return .{ .columns = &schema_cols };
        }
    };
    var diag: data.query.Diagnostic = .{};
    const tree = try data.query.parse(plan_arena.allocator(), "from w | where v > 100 and f < 900 | group k { c = count(), s = sum(f), m = avg(v) }", &diag);
    var cat_ctx: u8 = 0;
    var q: Query = .{ .ds = qds, .io = io, .plan = try data.query.plan.plan(plan_arena.allocator(), &tree, .{ .ctx = &cat_ctx, .resolve = Cat.resolve }, &diag) };
    try b.run("data/query_10m", &q, struct {
        fn f(c: *Query, s: *bench.State) void {
            var n: u64 = 0;
            while (n < s.iterations()) : (n += 1) {
                const cancel: std.atomic.Value(bool) = .init(false);
                const st = data.query.execute(c.io, std.heap.smp_allocator, &c.plan, .{ .ctx = c, .get = Query.get }, .{ .ctx = c, .batch = Query.batch }, .{ .cancel = &cancel }) catch unreachable;
                bench.doNotOptimizeAway(st.rows_out);
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

/// `vector/canvas_chart_view`: every tile of a 1,200×800 chart (gridlines,
/// 200 bars, three 500-point series, 60 markers) rasterized on workers
/// replacing a previous list's tiles (budget 4 ms).
fn registerVector(b: *bench.Bench) !void {
    const vector = zg_agents.vector;
    const gpa = std.heap.smp_allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: vector.VectorCanvas = .init(arena.allocator());
    try c.fillRect(.xywh(0, 0, 1200, 800), .rgb(0xFFFFFF));
    for (0..11) |i| {
        const y: f32 = 40 + @as(f32, @floatFromInt(i)) * 70;
        try c.line(60, y, 1180, y, .{ .width = 1, .dash = &.{ 3, 3 } }, .rgb(0xDDDDDD));
    }
    var h: u32 = 7;
    for (0..200) |i| {
        h = h *% 1103515245 +% 12345;
        const v: f32 = @floatFromInt(40 + (h >> 16) % 300);
        try c.fillRect(.xywh(62 + @as(f32, @floatFromInt(i)) * 5.6, 740 - v, 4, v), vector.Color.rgb(0x4C78A8).withAlpha(160));
    }
    for (0..3) |series| {
        const p = try c.path();
        for (0..500) |i| {
            const x = 60 + @as(f32, @floatFromInt(i)) * 2.24;
            const y = 300 + @as(f32, @floatFromInt(series)) * 120 + 80 * @sin(@as(f32, @floatFromInt(i)) / (20 + @as(f32, @floatFromInt(series)) * 7));
            if (i == 0) try p.moveTo(c.arena, x, y) else try p.lineTo(c.arena, x, y);
        }
        try c.stroke(p, .{ .width = 2, .join = .round }, .rgb(0xE45756 + @as(u24, @intCast(series)) * 0x101010));
    }
    for (0..60) |i| try c.circle(80 + @as(f32, @floatFromInt(i)) * 18, 200 + 40 * @cos(@as(f32, @floatFromInt(i))), 4, .rgb(0x54A24B));
    try c.line(60, 20, 60, 740, .{ .width = 1.5 }, .rgb(0x333333));
    try c.line(60, 740, 1180, 740, .{ .width = 1.5 }, .rgb(0x333333));
    const dl = try c.finish();
    var keys: std.ArrayListUnmanaged(vector.tiles.Key) = .empty;
    defer keys.deinit(gpa);
    const r = vector.tiles.tilesFor(.{ .x0 = 0, .y0 = 0, .x1 = 1200, .y1 = 800 });
    var ty = r.y0;
    while (ty < r.y1) : (ty += 1) {
        var tx = r.x0;
        while (tx < r.x1) : (tx += 1) try keys.append(gpa, .{ .hash = dl.hash, .scale_q = 1000, .tx = tx, .ty = ty });
    }
    // The view's cache lives on; each run replaces every tile (a
    // content change), reusing the evicted tiles' buffers.
    var cache: vector.TileCache = .init(gpa, vector.TileCache.default_budget);
    defer cache.deinit();
    const Ctx = struct { dl: *const vector.DisplayList, keys: []const vector.tiles.Key, io: std.Io, cache: *vector.TileCache };
    var ctx: Ctx = .{ .dl = &dl, .keys = keys.items, .io = b.io, .cache = &cache };
    try b.run("vector/canvas_chart_view", &ctx, struct {
        fn f(x: *Ctx, s: *bench.State) void {
            var n: u64 = 0;
            while (n < s.iterations()) : (n += 1) {
                x.cache.clear(x.io);
                vector.tiles.rasterizeTiles(x.io, x.cache, x.dl, x.keys, 8) catch unreachable;
                bench.doNotOptimizeAway(x.cache.count(x.io));
            }
        }
    }.f);
}

/// `chart/line_1m_frame`: a frame of a 1,000,000-point line chart: the
/// compiled (M4-decimated) chart drawn into a display list and every
/// tile of its 1,200×600 view rasterized on workers (budget 4 ms);
/// `chart/line_1m_compile`: compiling it from the table when the spec
/// or data changes (scales, ticks, decimation; for reference).
fn registerChart(b: *bench.Bench) !void {
    const chart = zg_agents.chart;
    const vector = zg_agents.vector;
    const gpa = std.heap.smp_allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var t: chart.Table = .{ .rows = 1_000_000 };
    const xs = try a.alloc(chart.transform.Lit, t.rows);
    const ys = try a.alloc(chart.transform.Lit, t.rows);
    var h: u32 = 11;
    for (xs, ys, 0..) |*x, *y, i| {
        h = h *% 1103515245 +% 12345;
        x.* = .{ .int = @intCast(i) };
        y.* = .{ .float = @sin(@as(f64, @floatFromInt(i)) / 5000) * 100 + @as(f64, @floatFromInt(h >> 20)) / 64 };
    }
    try t.put(a, "x", .int, xs);
    try t.put(a, "y", .float, ys);
    var diag: chart.Diagnostic = .{};
    const s = try chart.parseSpec(a,
        \\{"title":"1M points","width":1200,"height":600,"data":{"artifact":"A-big"},"mark":"line",
        \\ "encoding":{"x":{"field":"x","type":"quantitative"},"y":{"field":"y","type":"quantitative"}}}
    , &diag);
    const Ctx = struct {
        t: chart.Table,
        s: chart.ChartSpec,
        io: std.Io,
        c: chart.CompiledChart = undefined,
        cache: *vector.TileCache,
        keys: []const vector.tiles.Key = &.{},

        fn load(ctx: *anyopaque, _: std.mem.Allocator, _: *const chart.spec.Data) anyerror!chart.Table {
            const x: *@This() = @ptrCast(@alignCast(ctx));
            return x.t;
        }

        fn compile(x: *@This(), fa: std.mem.Allocator) chart.CompiledChart {
            var cd: chart.compile_mod.Diagnostic = .{};
            return chart.compile(fa, std.heap.smp_allocator, &x.s, .{ .source = .{ .ctx = x, .load = load } }, &cd) catch unreachable;
        }
    };
    var cache: vector.TileCache = .init(gpa, vector.TileCache.default_budget);
    defer cache.deinit();
    var ctx: Ctx = .{ .t = t, .s = s, .io = b.io, .cache = &cache };
    ctx.c = ctx.compile(a);
    var keys: std.ArrayListUnmanaged(vector.tiles.Key) = .empty;
    defer keys.deinit(gpa);
    const r = vector.tiles.tilesFor(.{ .x0 = 0, .y0 = 0, .x1 = ctx.c.width, .y1 = ctx.c.height });
    var ty = r.y0;
    while (ty < r.y1) : (ty += 1) {
        var tx = r.x0;
        while (tx < r.x1) : (tx += 1) try keys.append(gpa, .{ .hash = 0, .scale_q = 1000, .tx = tx, .ty = ty });
    }
    ctx.keys = keys.items;
    try b.run("chart/line_1m_frame", &ctx, struct {
        fn f(x: *Ctx, st: *bench.State) void {
            var n: u64 = 0;
            while (n < st.iterations()) : (n += 1) {
                var frame: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
                defer frame.deinit();
                var cv: vector.VectorCanvas = .init(frame.allocator());
                chart.render(&x.c, &cv) catch unreachable;
                const dl = cv.finish() catch unreachable;
                const ks = frame.allocator().dupe(vector.tiles.Key, x.keys) catch unreachable;
                for (ks) |*k| k.hash = dl.hash;
                x.cache.clear(x.io);
                vector.tiles.rasterizeTiles(x.io, x.cache, &dl, ks, 4) catch unreachable;
                bench.doNotOptimizeAway(x.cache.count(x.io));
            }
        }
    }.f);
    try b.run("chart/line_1m_compile", &ctx, struct {
        fn f(x: *Ctx, st: *bench.State) void {
            var n: u64 = 0;
            while (n < st.iterations()) : (n += 1) {
                var frame: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
                defer frame.deinit();
                bench.doNotOptimizeAway(x.compile(frame.allocator()).items.len);
            }
        }
    }.f);
}

/// `data/grid_scroll_10m`: a frame of the data grid after a page-sized
/// jump through a 10 M-row CSV, building every visible cell in a
/// headless window (budget 8.3 ms).
fn registerGrid(b: *bench.Bench) !void {
    const zg_gui = @import("zg_gui");
    const ui = @import("zg_agents_ui");
    const data = zg_agents.data;
    const gpa = std.heap.smp_allocator;
    const io = b.io;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.ensureTotalCapacity(gpa, 10_000_000 * 48);
    try text.appendSlice(gpa, "id,name,amount,day,city,flag\n");
    for (0..10_000_000) |r| try text.print(gpa, "{d},name {d},{d}.{d},2026-{d:0>2}-{d:0>2},city{d},{s}\n", .{ r, r % 977, r % 9973, r % 10, 1 + r % 12, 1 + r % 28, r % 300, if (r % 3 == 0) "true" else "false" });
    const ds = try data.Dataset.openBytes(gpa, io, text.items, .csv);
    defer ds.close();
    try ds.waitIndexed();

    const Host = struct {
        g: ?*ui.data.DataGrid = null,
        pub fn build(h: *@This(), u: *zg_gui.Ui) void {
            if (h.g) |g| ui.data.dataGrid(u, g);
        }
    };
    var host: Host = .{};
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .root = .of(&host), .size = .{ .w = 1600, .h = 900 } });
    defer t.deinit();
    const g = try ui.data.DataGrid.init(gpa, io, &t.app, ds, "data", .{});
    defer {
        host.g = null;
        g.deinit();
    }
    host.g = g;
    _ = t.settle();
    const Ctx = struct { t: *zg_gui.testing.TestApp, g: *ui.data.DataGrid, rows: u64, at: u64 = 0 };
    var ctx: Ctx = .{ .t = t, .g = g, .rows = ds.index().count() };
    try b.run("data/grid_scroll_10m", &ctx, struct {
        fn f(c: *Ctx, s: *bench.State) void {
            var n: u64 = 0;
            while (n < s.iterations()) : (n += 1) {
                // A page down, plus a far jump every 16 frames.
                c.at = if (n % 16 == 15) (c.at *% 2654435761 +% 7919) % c.rows else (c.at + 37) % c.rows;
                c.g.table.moveTo(c.at, 1, .replace);
                c.t.win.markAllDirty();
                bench.doNotOptimizeAway(c.t.frame());
            }
        }
    }.f);
}

/// `diagram/flowchart_parse_300`: parsing a 300-node, 600-edge flowchart
/// (budget 1 ms).
fn registerDiagram(b: *bench.Bench) !void {
    const zg_diagram = @import("zg_diagram");
    const gpa = std.heap.smp_allocator;
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try w.writer.writeAll("flowchart TB\n");
    for (0..300) |i| try w.writer.print("  n{d}[\"Step {d}\"] --> n{d}\n  n{d} -.->|retry| n{d}\n", .{ i, i, (i + 1) % 300, i, (i * 7 + 3) % 300 });
    const Ctx = struct { src: []const u8 };
    var ctx: Ctx = .{ .src = w.written() };
    try b.run("diagram/flowchart_parse_300", &ctx, struct {
        fn f(c: *Ctx, s: *bench.State) void {
            var n: u64 = 0;
            while (n < s.iterations()) : (n += 1) {
                var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
                defer arena.deinit();
                var diags: std.ArrayList(zg_diagram.Diagnostic) = .empty;
                const d = zg_diagram.parse(arena.allocator(), c.src, &diags) catch unreachable;
                bench.doNotOptimizeAway(d.?.edges.len);
            }
        }
    }.f);

    // `diagram/layout_300`: laying out a 300-node flowchart shaped like a
    // real one (a main flow with skips, retry loops, labelled branches and
    // three subgraphs; ~480 edges) (budget 15 ms).
    var big: std.Io.Writer.Allocating = .init(gpa);
    defer big.deinit();
    try big.writer.writeAll("flowchart TB\n");
    var prng: std.Random.DefaultPrng = .init(300);
    const rnd = prng.random();
    const nn = 300;
    var at: usize = 0;
    for (0..3) |sg| {
        at += rnd.intRangeAtMost(usize, 0, nn / 6);
        const len = rnd.intRangeAtMost(usize, 3, nn / 8 + 3);
        try big.writer.print("  subgraph s{d} [Stage {d}]\n", .{ sg, sg });
        for (at..@min(nn, at + len)) |i| try big.writer.print("    n{d}[Step {d}]\n", .{ i, i });
        try big.writer.writeAll("  end\n");
        at += len;
    }
    for (0..nn) |i| {
        if (i + 1 < nn) try big.writer.print("  n{d} --> n{d}\n", .{ i, i + 1 });
        if (rnd.boolean() and i + 2 < nn) {
            const j = @min(nn - 1, i + rnd.intRangeAtMost(usize, 2, 6));
            if (rnd.intRangeLessThan(u8, 0, 4) == 0) try big.writer.print("  n{d} -->|branch {d}| n{d}\n", .{ i, i, j }) else try big.writer.print("  n{d} --> n{d}\n", .{ i, j });
        }
        if (rnd.intRangeLessThan(u8, 0, 12) == 0 and i > 2) try big.writer.print("  n{d} -.->|retry| n{d}\n", .{ i, i - rnd.intRangeAtMost(usize, 1, 3) });
    }
    var parse_arena: std.heap.ArenaAllocator = .init(gpa);
    defer parse_arena.deinit();
    var diags: std.ArrayList(zg_diagram.Diagnostic) = .empty;
    const diagram = (try zg_diagram.parse(parse_arena.allocator(), big.written(), &diags)).?;
    const Lay = struct {
        d: zg_diagram.Diagram,
        fn text(_: *anyopaque, t: []const u8, max_w: f32) [2]f32 {
            return .{ @min(max_w, @as(f32, @floatFromInt(t.len)) * 7), 16 };
        }
    };
    var lay: Lay = .{ .d = diagram };
    try b.run("diagram/layout_300", &lay, struct {
        fn f(c: *Lay, s: *bench.State) void {
            var n: u64 = 0;
            while (n < s.iterations()) : (n += 1) {
                var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
                defer arena.deinit();
                const l = zg_diagram.layout(arena.allocator(), &c.d, .{ .ctx = c, .text = Lay.text }, .{}) catch unreachable;
                bench.doNotOptimizeAway(l.size);
            }
        }
    }.f);
}

/// `library/search_5k`: a fuzzy query over 5,000 prompt entries (budget
/// 10 ms); `library/index_5k` opens the library (headers only).
fn registerLibrary(b: *bench.Bench) !void {
    const PromptLibrary = zg_agents.library.PromptLibrary;
    const gpa = std.heap.smp_allocator;
    const io = b.io;
    const cwd = std.Io.Dir.cwd();
    const root = ".zig-cache/bench-library";
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);
    defer cwd.deleteTree(io, root) catch {};
    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    const topics = [_][]const u8{ "research", "writing", "review", "release", "planning", "data", "support", "legal" };
    var name: [96]u8 = undefined;
    var body: [512]u8 = undefined;
    for (0..5000) |i| {
        const topic = topics[i % topics.len];
        if (i < topics.len) try dir.createDirPath(io, topic);
        const n = try std.fmt.bufPrint(&name, "{s}/prompt-{d}.md", .{ topic, i });
        const data = try std.fmt.bufPrint(&body, "---\ntitle: {s} prompt number {d}\ndescription: Helps with {s} tasks of kind {d}\ntags: [{s}, kind-{d}]\n---\nDo the {s} thing for {{{{subject}}}}.\n", .{ topic, i, topic, i % 17, topic, i % 17, topic });
        try dir.writeFile(io, .{ .sub_path = n, .data = data });
    }
    const Ctx = struct { dir: std.Io.Dir, io: std.Io };
    const ctx: Ctx = .{ .dir = dir, .io = io };
    try b.run("library/index_5k", &ctx, struct {
        fn f(c: *const Ctx, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                const l = PromptLibrary.open(std.heap.smp_allocator, c.io, .{ .project = c.dir }, null) catch unreachable;
                bench.doNotOptimizeAway(l.count());
                l.deinit();
            }
        }
    }.f);
    const lib = try PromptLibrary.open(gpa, io, .{ .project = dir }, null);
    defer lib.deinit();
    try b.run("library/search_5k", lib, struct {
        fn f(l: *PromptLibrary, s: *bench.State) void {
            var hits: std.ArrayList(PromptLibrary.Hit) = .empty;
            defer hits.deinit(std.heap.smp_allocator);
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                l.search("planning 12", 50, &hits, std.heap.smp_allocator) catch unreachable;
                bench.doNotOptimizeAway(hits.items.len);
            }
        }
    }.f);
}
