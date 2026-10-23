//! E09.F05.S01.T01 provenance benchmark: recording one agent edit
//! (`Recorder.onEdit`, copying and enqueueing the event; budget 20 µs),
//! with the queue drained every 4096 events as the worker would; and
//! remapping the manifests of a 20-change stack rebased onto a new parent
//! (budget 10 ms); and evaluating `agent(claude)` over 10k changes with
//! the provenance index (budget 20 ms).

const std = @import("std");
const zg_core = @import("zg_core");
const scm = @import("zg_scm");
const gen_dag = @import("gen_dag.zig");
const bench = zg_core.bench;
const State = bench.State;

const recorder = scm.prov.recorder;
const bench_dir = ".zig-cache/scm-prov-bench";

pub fn register(b: *bench.Bench) !void {
    if (b.opts.filter) |f| if (std.mem.indexOf(u8, "prov.on_edit prov.remap_rebase_20 prov.revset_agent_10k", f) == null) return;
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(b.io, bench_dir) catch {};
    defer cwd.deleteTree(b.io, bench_dir) catch {};
    var root = try cwd.createDirPathOpen(b.io, bench_dir, .{});
    defer root.close(b.io);
    const store = try scm.Store.open(b.gpa, b.io, root, .{ .fsync = false });
    defer store.close();
    try b.run("prov.on_edit: record one agent edit (enqueue)", store, onEdit);
    try remapBench(b, store);
    try agentRevsetBench(b, store);
}

/// 10k commits; every third has lines by "claude", every fifth by
/// "helper" (each in one of 50 sessions), the rest by a human.
fn agentRevsetBench(b: *bench.Bench, store: *scm.Store) !void {
    const gpa = b.gpa;
    const io = b.io;
    const n = 10_000;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ids = try gen_dag.generate(gpa, store, n, 3);
    defer gpa.free(ids);
    var root = try std.Io.Dir.cwd().openDir(io, bench_dir, .{});
    defer root.close(io);
    var ix_dir = try root.createDirPathOpen(io, "index", .{ .open_options = .{ .iterate = true } });
    defer ix_dir.close(io);
    const ix = try scm.CommitIndex.open(gpa, io, ix_dir, store, .{ .fsync = false });
    defer ix.close();
    try ix.ensureIndexed(ids[ids.len - 1 ..]);

    var batch = store.batch();
    var ctx: scm.prov.remap.RemapContext = .{ .gpa = gpa, .store = store, .batch = &batch };
    const human = try scm.prov.remap.writeRecord(&ctx, .{ .actor = scm.prov.record.Actor.human("Bob", "bob@example.com"), .created_ms = 0 });
    var agents: [100]scm.ObjectId = undefined;
    for (&agents, 0..) |*r, i| {
        const session = try std.fmt.allocPrint(a, "session-{d}", .{i % 50});
        const actor = if (i < 50) scm.prov.record.Actor.agent("claude", "anthropic/claude-x", session) else scm.prov.record.Actor.agent("helper", "openai/gpt-y", session);
        r.* = try scm.prov.remap.writeRecord(&ctx, .{ .actor = actor, .created_ms = 0 });
    }
    const manifests = try a.alloc(scm.ObjectId, n);
    for (manifests, 0..) |*mid, i| {
        var bld: scm.prov.attribution.Builder = try .initInherited(gpa, 100);
        defer bld.deinit();
        const rec = if (i % 3 == 0) agents[i % 50] else if (i % 5 == 0) agents[50 + i % 50] else human;
        try bld.splice(@intCast(i % 90), 0, 5, rec, false);
        const fa = try scm.prov.manifest.encodeFile(a, "src/file.zig", scm.id.hashObject(.blob, "x"), try bld.toMap(a));
        mid.* = try scm.prov.manifest.write(&batch, gpa, .{ .files = &.{fa} });
    }
    try batch.commit();

    var pix: scm.prov.index.ProvenanceIndex = .init(gpa);
    defer pix.deinit();
    const t0 = std.Io.Timestamp.now(io, .awake).nanoseconds;
    for (ids, manifests) |c, mid| try pix.addManifest(store, c, mid);
    const t1 = std.Io.Timestamp.now(io, .awake).nanoseconds;
    std.debug.print("prov.index_build_10k: index 10k manifests: {d} ms\n", .{@divTrunc(t1 - t0, std.time.ns_per_ms)});

    var heads = [1]scm.ObjectId{ids[ids.len - 1]};
    var view: scm.View = .empty;
    view.heads = &heads;
    view.wc_commits = &.{.{ .workspace = "default", .commit = ids[ids.len - 1] }};
    const rv = ix.acquire();
    defer rv.release();
    const q = pix.query();
    const rctx: scm.revset.EvalContext = .{ .graph = rv, .view = &view, .store = store, .io = io, .prov = &q };
    try b.run("prov.revset_agent_10k: evaluate agent(claude) over 10k changes", &rctx, agentRevset);
}

fn agentRevset(c: *const scm.revset.EvalContext, s: *State) void {
    for (0..s.iterations()) |_| {
        var diag: scm.revset.ParseError = .{};
        var it = scm.revset.evaluate(s.allocator(), c, "agent(claude)", &diag) catch unreachable;
        defer it.deinit();
        var k: usize = 0;
        while (it.next() catch unreachable) |_| k += 1;
        bench.doNotOptimizeAway(k);
    }
}

fn meta(description: []const u8) scm.OpMeta {
    return .{ .start_ms = 0, .end_ms = 0, .description = description, .user = "bench", .host = "host", .workspace = "default", .actor = .human, .tags = &.{} };
}

fn commit(m: *scm.mutable_repo.MutableRepo, gpa: std.mem.Allocator, parent: ?scm.ObjectId, tag: usize, text: []const u8) !scm.ObjectId {
    var tm = scm.tree_merge.TreeMerger.init(gpa, m.batch.store, m.batch);
    defer tm.deinit();
    const tree = try scm.tree_merge.testTree(&tm, &.{.{ "src/file.zig", text }});
    const sig: scm.Signature = .{ .name = "b", .email = "b@example.com", .time_ms = 0, .tz_offset_min = 0 };
    var cid: scm.ChangeId = undefined;
    std.mem.writeInt(u128, &cid.bytes, tag, .little);
    return m.writeChange(.{
        .parents = if (parent) |p| try m.arena.dupe(scm.ObjectId, &.{p}) else &.{},
        .tree_terms = try m.arena.dupe(scm.ObjectId, &.{tree}),
        .change_id = cid,
        .predecessors = &.{},
        .author = sig,
        .committer = sig,
        .description = "",
        .provenance = null,
        .extra = &.{},
        .sig = null,
    });
}

const Stack = struct { store: *scm.Store, old: []scm.Change, new: []scm.Change };

/// 20 stacked changes, each adding 10 agent lines to a 300-line file;
/// the same stack again on a parent with 5 more lines at the top.
fn remapBench(b: *bench.Bench, store: *scm.Store) !void {
    const gpa = b.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root = try std.Io.Dir.cwd().openDir(b.io, bench_dir, .{});
    defer root.close(b.io);
    const r0 = try scm.Repo.init(gpa, b.io, root, store, .{}, meta("init"));
    defer r0.close();
    const tx = try r0.startTransaction(meta("setup"));
    const m = tx.mutRepo();
    var base: std.ArrayList(u8) = .empty;
    for (0..300) |i| try base.print(a, "    base_line({d});\n", .{i});
    var top: std.ArrayList(u8) = .empty;
    for (0..5) |i| try top.print(a, "    new_top({d});\n", .{i});
    try top.appendSlice(a, base.items);
    var old_ids: [21]scm.ObjectId = undefined;
    var new_ids: [21]scm.ObjectId = undefined;
    old_ids[0] = try commit(m, gpa, null, 1, base.items);
    new_ids[0] = try commit(m, gpa, null, 2, top.items);
    var old_text: std.ArrayList(u8) = .empty;
    try old_text.appendSlice(a, base.items);
    var new_text: std.ArrayList(u8) = .empty;
    try new_text.appendSlice(a, top.items);
    const old_texts = try a.alloc([]const u8, 21);
    for (1..21) |k| {
        var add: std.ArrayList(u8) = .empty;
        for (0..10) |i| try add.print(a, "    agent_{d}_{d}();\n", .{ k, i });
        try old_text.appendSlice(a, add.items);
        try new_text.appendSlice(a, add.items);
        old_ids[k] = try commit(m, gpa, old_ids[k - 1], 100 + k, try a.dupe(u8, old_text.items));
        new_ids[k] = try commit(m, gpa, new_ids[k - 1], 200 + k, try a.dupe(u8, new_text.items));
        old_texts[k] = try a.dupe(u8, old_text.items);
    }
    const r1 = try tx.commit();
    defer r1.close();

    // Manifests of the old stack: each change's own 10 lines.
    var batch = store.batch();
    var ctx: scm.prov.remap.RemapContext = .{ .gpa = gpa, .store = store, .batch = &batch };
    const rec = try scm.prov.remap.writeRecord(&ctx, .{ .actor = scm.prov.record.Actor.agent("claude", "m", "s"), .created_ms = 0 });
    const old = try a.alloc(scm.Change, 20);
    const new = try a.alloc(scm.Change, 20);
    for (1..21) |k| {
        var bld: scm.prov.attribution.Builder = try .initInherited(gpa, @intCast(300 + 10 * (k - 1)));
        defer bld.deinit();
        try bld.push(.{ .len = 10, .prov = rec });
        const fa = try scm.prov.manifest.encodeFile(a, "src/file.zig", scm.id.hashObject(.blob, old_texts[k]), try bld.toMap(a));
        old[k - 1] = try scm.operation.read(scm.Change, store, a, old_ids[k]);
        old[k - 1].provenance = try scm.prov.manifest.write(&batch, gpa, .{ .files = &.{fa} });
        new[k - 1] = try scm.operation.read(scm.Change, store, a, new_ids[k]);
    }
    try batch.commit();
    try b.run("prov.remap_rebase_20: remap a rebased 20-change stack", Stack{ .store = store, .old = old, .new = new }, remapStack);
}

fn remapStack(st: Stack, s: *State) void {
    for (0..s.iterations()) |_| {
        var arena: std.heap.ArenaAllocator = .init(s.allocator());
        defer arena.deinit();
        var batch = st.store.batch();
        var ctx: scm.prov.remap.RemapContext = .{ .gpa = s.allocator(), .store = st.store, .batch = &batch };
        for (st.old, st.new) |o, n| {
            var nn = n;
            scm.prov.remap.remapForRewrite(&ctx, arena.allocator(), o, &nn, .rebase, .unknown) catch unreachable;
            std.debug.assert(nn.provenance != null);
        }
        batch.commit() catch unreachable;
    }
}

fn onEdit(store: *scm.Store, s: *State) void {
    const r = recorder.Recorder.init(s.allocator(), s.ioHandle(), store, .{}) catch unreachable;
    defer r.deinit();
    const actor = scm.prov.record.Actor.agent("claude", "anthropic/claude-x", "session-1");
    for (0..s.iterations()) |i| {
        r.onEdit(.{
            .path = "src/parser/expression.zig",
            .workspace = "default",
            .ranges = &.{.{ .old_start_line = @intCast(i % 500), .old_len = 1, .new_len = 2 }},
            .actor = actor,
            .prompt = "Make the parser accept trailing commas in argument lists.",
            .at_ms = 1,
        });
        if (i % 4096 == 4095) r.drain() catch unreachable;
    }
}
