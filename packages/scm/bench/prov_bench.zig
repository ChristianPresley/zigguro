//! E09.F05.S01.T01 provenance benchmark: recording one agent edit
//! (`Recorder.onEdit`, copying and enqueueing the event; budget 20 µs),
//! with the queue drained every 4096 events as the worker would; and
//! remapping the manifests of a 20-change stack rebased onto a new parent
//! (budget 10 ms).

const std = @import("std");
const zg_core = @import("zg_core");
const scm = @import("zg_scm");
const bench = zg_core.bench;
const State = bench.State;

const recorder = scm.prov.recorder;
const bench_dir = ".zig-cache/scm-prov-bench";

pub fn register(b: *bench.Bench) !void {
    if (b.opts.filter) |f| if (std.mem.indexOf(u8, "prov.on_edit prov.remap_rebase_20", f) == null) return;
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(b.io, bench_dir) catch {};
    defer cwd.deleteTree(b.io, bench_dir) catch {};
    var root = try cwd.createDirPathOpen(b.io, bench_dir, .{});
    defer root.close(b.io);
    const store = try scm.Store.open(b.gpa, b.io, root, .{ .fsync = false });
    defer store.close();
    try b.run("prov.on_edit: record one agent edit (enqueue)", store, onEdit);
    try remapBench(b, store);
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
