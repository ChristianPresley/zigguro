//! Benchmarks for the E12 budget table rows that need no GUI (#913):
//! agent view reads, closed-file rebases, checkpoints, accept-all,
//! changeset memory and the store (journal append, cold load; in
//! `.zig-cache/bench-review` under the current directory).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_review = @import("zg_review");
const bench = zg_core.bench;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const model = zg_review.model;
const apply = zg_review.apply;
const ChangeSet = model.changeset.ChangeSet;
const Replace = model.changeset.Replace;

pub fn register(b: *bench.Bench) !void {
    try registerAgentView(b);
    try registerRebaseClosed(b);
    try registerCheckpoint(b);
    try registerAcceptAll(b);
    try registerMem(b);
    try registerStore(b);
}

/// Whether a bench named `name` runs (`--filter`): skips costly setup.
fn wanted(b: *const bench.Bench, name: []const u8) bool {
    const f = b.opts.filter orelse return true;
    return std.mem.indexOf(u8, name, f) != null;
}

fn agentProv(session: u128) model.Provenance {
    return .{ .origin = .{ .agent = .{ .ref = .{ .session = session }, .turn = 1, .model = "bench" } }, .label = "bench", .workspace = "/w", .created_ms = 0 };
}

/// `lines` lines of code-like text.
fn codeText(gpa: Allocator, lines: usize, seed: u64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rng: std.Random.DefaultPrng = .init(seed);
    const r = rng.random();
    for (0..lines) |i| try out.print(gpa, "    const v{d} = call(arg{d}, {d}); // {d}\n", .{ i, r.uintLessThan(u32, 1000), i * 3, r.int(u16) });
    return out.toOwnedSlice(gpa);
}

/// `n` one-word replaces spread over `text`.
fn spreadEdits(gpa: Allocator, text: []const u8, n: usize) !ChangeSet {
    var reps: std.ArrayList(Replace) = .empty;
    defer reps.deinit(gpa);
    const step = text.len / (n + 1);
    for (1..n + 1) |i| {
        const at = std.mem.indexOfScalarPos(u8, text, step * i, '\n') orelse break;
        try reps.append(gpa, .{ .range = .{ .start = at + 5, .end = at + 10 }, .text = "CONST" });
    }
    return ChangeSet.fromEdits(gpa, text.len, reps.items);
}

// ------------------------------------------------------------ agent view

const AgentView = struct {
    disk: apply.MemFiles,
    blobs: model.MemBlobs,
    q: *model.Queue,
    fs: zg_review.overlay.OverlayFs,
    arena: std.heap.ArenaAllocator,
};

/// A 1 MB file with one session's 50 pending replaces, read through that
/// session's view (budget `review.agentview_1mb` < 1 ms).
fn registerAgentView(b: *bench.Bench) !void {
    if (!wanted(b, "review.agentview_1mb")) return;
    const text = try codeText(b.gpa, 22_000, 0xa9e1);
    defer b.gpa.free(text);
    var v: AgentView = .{ .disk = .init(b.gpa), .blobs = .init(b.gpa), .q = undefined, .fs = undefined, .arena = .init(b.gpa) };
    defer v.disk.deinit();
    defer v.blobs.deinit();
    defer v.arena.deinit();
    v.q = try model.Queue.init(b.gpa, b.io, .{ .root = "/w", .blobs = v.blobs.blobs() });
    defer v.q.deinit();
    try v.disk.put("big.zig", text, false);
    var e = try spreadEdits(b.gpa, text, 50);
    defer e.deinit();
    const batch = try v.q.beginBatch(agentProv(1));
    try v.q.addEdit(batch, "big.zig", text, null, &e);
    _ = try v.q.commitBatch(batch, .{});
    v.fs = .{ .q = v.q, .files = v.disk.files() };
    try b.run("review.agentview_1mb", &v, struct {
        fn f(x: *AgentView, st: *bench.State) void {
            var i: u64 = 0;
            while (i < st.iterations()) : (i += 1) {
                const r = x.fs.read(x.arena.allocator(), .{ .agent = .{ .session = 1 } }, "big.zig") catch unreachable;
                bench.doNotOptimizeAway(r.?.text.len);
                _ = x.arena.reset(.retain_capacity);
            }
            st.setBytes(1 << 20);
        }
    }.f);
}

// ------------------------------------------------------- closed rebase

const Merge = struct { base: []const u8, ours: []const u8, theirs: []const u8, gpa: Allocator };

/// The three-way merge behind a closed file's rebase: 10k lines, the
/// user changed 20 of them, the agent 30 others (budget
/// `review.rebase_closed_10k` < 10 ms).
fn registerRebaseClosed(b: *bench.Bench) !void {
    if (!wanted(b, "review.rebase_closed_10k")) return;
    const base = try codeText(b.gpa, 10_000, 0x3e1);
    defer b.gpa.free(base);
    var eo = try spreadEdits(b.gpa, base, 20);
    defer eo.deinit();
    const ours = try eo.applyToSlice(b.gpa, base);
    defer b.gpa.free(ours);
    var reps: std.ArrayList(Replace) = .empty;
    defer reps.deinit(b.gpa);
    for (0..30) |i| {
        const at = std.mem.indexOfScalarPos(u8, base, base.len / 31 * i + 997, '\n') orelse break;
        try reps.append(b.gpa, .{ .range = .{ .start = at + 1, .end = at + 1 }, .text = "    // agent\n" });
    }
    var et: ChangeSet = try .fromEdits(b.gpa, base.len, reps.items);
    defer et.deinit();
    const theirs = try et.applyToSlice(b.gpa, base);
    defer b.gpa.free(theirs);
    var m: Merge = .{ .base = base, .ours = ours, .theirs = theirs, .gpa = b.gpa };
    try b.run("review.rebase_closed_10k", &m, struct {
        fn f(x: *Merge, st: *bench.State) void {
            var i: u64 = 0;
            while (i < st.iterations()) : (i += 1) {
                var r = model.merge3.merge(x.gpa, x.base, x.ours, x.theirs, .{}) catch unreachable;
                bench.doNotOptimizeAway(r.text.len);
                r.deinit(x.gpa);
            }
        }
    }.f);
}

// ---------------------------------------------------------- checkpoint

const Cp = struct {
    disk: apply.MemFiles,
    blobs: model.MemBlobs,
    history: model.History,
    q: *model.Queue,
    cps: zg_review.checkpoint.Checkpoints,
};

/// A turn's checkpoint with 100 pending changesets in the queue (budget
/// `review.checkpoint_create` < 1 ms).
fn registerCheckpoint(b: *bench.Bench) !void {
    if (!wanted(b, "review.checkpoint_create")) return;
    var c: Cp = .{ .disk = .init(b.gpa), .blobs = .init(b.gpa), .history = .init(b.gpa, null), .q = undefined, .cps = undefined };
    defer c.disk.deinit();
    defer c.blobs.deinit();
    defer c.history.deinit();
    c.q = try model.Queue.init(b.gpa, b.io, .{ .root = "/w", .blobs = c.blobs.blobs() });
    defer c.q.deinit();
    c.cps = .init(b.gpa, b.io, c.q, &c.history, c.disk.files(), null);
    defer c.cps.deinit();
    for (0..100) |i| {
        var name: [16]u8 = undefined;
        const batch = try c.q.beginBatch(agentProv(1 + i % 4));
        try c.q.addCreate(batch, try std.fmt.bufPrint(&name, "f{d}.txt", .{i}), "x\n");
        _ = try c.q.commitBatch(batch, .{});
    }
    try b.run("review.checkpoint_create", &c, struct {
        fn f(x: *Cp, st: *bench.State) void {
            var i: u64 = 0;
            while (i < st.iterations()) : (i += 1) bench.doNotOptimizeAway(x.cps.create(.{ .session = 1 }, @intCast(i), "turn"));
        }
    }.f);
}

// ---------------------------------------------------------- accept all

const Accept = struct {
    disk: apply.MemFiles,
    blobs: model.MemBlobs,
    history: model.History,
    q: *model.Queue,
    ap: apply.Applier,
    id: model.ChangesetId,
    arena: std.heap.ArenaAllocator,
};

/// Accept-all of one changeset over 200 closed 200-line files, then its
/// undo so the next pass starts the same (budget `review.accept_all_200`
/// < 300 ms for the accept alone; this bounds it from above).
fn registerAcceptAll(b: *bench.Bench) !void {
    if (!wanted(b, "review.accept_all_200")) return;
    var a: Accept = .{ .disk = .init(b.gpa), .blobs = .init(b.gpa), .history = .init(b.gpa, null), .q = undefined, .ap = undefined, .id = undefined, .arena = .init(b.gpa) };
    defer a.disk.deinit();
    defer a.blobs.deinit();
    defer a.history.deinit();
    defer a.arena.deinit();
    a.q = try model.Queue.init(b.gpa, b.io, .{ .root = "/w", .blobs = a.blobs.blobs() });
    defer a.q.deinit();
    a.ap = .init(b.gpa, b.io, a.q, a.disk.files(), &a.history);
    const batch = try a.q.beginBatch(agentProv(1));
    for (0..200) |i| {
        const text = try codeText(b.gpa, 200, i);
        defer b.gpa.free(text);
        var name: [24]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "src/f{d}.zig", .{i});
        try a.disk.put(path, text, false);
        var e = try spreadEdits(b.gpa, text, 3);
        defer e.deinit();
        try a.q.addEdit(batch, path, text, null, &e);
    }
    a.id = try a.q.commitBatch(batch, .{});
    try b.run("review.accept_all_200", &a, struct {
        fn f(x: *Accept, st: *bench.State) void {
            var i: u64 = 0;
            while (i < st.iterations()) : (i += 1) {
                const r = x.ap.acceptAll(x.id) catch unreachable;
                const u = x.ap.undoApply(x.arena.allocator(), r.ok.apply.?) catch unreachable;
                bench.doNotOptimizeAway(u);
                _ = x.arena.reset(.retain_capacity);
            }
        }
    }.f);
}

// -------------------------------------------------------------- memory

const Mem = struct { texts: [3][]const u8, edits: [3]ChangeSet };

/// Counts the bytes live at any time (current and peak).
const Live = struct {
    inner: Allocator,
    now: usize = 0,
    peak: usize = 0,

    fn allocator(l: *Live) Allocator {
        return .{ .ptr = l, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn note(l: *Live, add: usize, sub: usize) void {
        l.now = l.now + add - sub;
        l.peak = @max(l.peak, l.now);
    }
    fn alloc(ctx: *anyopaque, n: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const p = l.inner.rawAlloc(n, a, ra) orelse return null;
        l.note(n, 0);
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (!l.inner.rawResize(m, a, n, ra)) return false;
        l.note(n, m.len);
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const p = l.inner.rawRemap(m, a, n, ra) orelse return null;
        l.note(n, m.len);
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.inner.rawFree(m, a, ra);
        l.note(0, m.len);
    }
};

/// Builds the 1,000 changesets in `gpa`.
fn fill(gpa: Allocator, io: Io, x: *Mem, blobs: *model.MemBlobs) !*model.Queue {
    const q = try model.Queue.init(gpa, io, .{ .root = "/w", .blobs = blobs.blobs() });
    errdefer q.deinit();
    const names = [_][]const u8{ "src/a.zig", "src/b.zig", "src/c.zig" };
    for (0..1000) |k| {
        // One session each: a session's later edits would fold.
        const batch = try q.beginBatch(agentProv(1 + k));
        for (names, x.texts, &x.edits) |n, t, *e| try q.addEdit(batch, n, t, null, e);
        _ = try q.commitBatch(batch, .{});
    }
    return q;
}

/// The queue's memory for 1,000 pending 3-file changesets, from 1,000
/// sessions (budget `review.mem_1000` < 32 MiB, printed as live bytes);
/// the timing is building them.
fn registerMem(b: *bench.Bench) !void {
    if (!wanted(b, "review.mem_1000")) return;
    var m: Mem = undefined;
    for (&m.texts, &m.edits, 0..) |*t, *e, i| {
        t.* = try codeText(b.gpa, 300, 77 + i);
        e.* = try spreadEdits(b.gpa, t.*, 4);
    }
    defer for (m.texts, &m.edits) |t, *e| {
        b.gpa.free(t);
        e.deinit();
    };
    // What stays in memory (the budget), printed beside the timing.
    {
        var live: Live = .{ .inner = b.gpa };
        var blobs: model.MemBlobs = .init(live.allocator());
        const q = try fill(live.allocator(), b.io, &m, &blobs);
        std.debug.print("review.mem_1000: {d} KiB live after building, {d} KiB at peak (budget 32 MiB)\n", .{ live.now >> 10, live.peak >> 10 });
        q.deinit();
        blobs.deinit();
    }
    try b.run("review.mem_1000", &m, struct {
        fn f(x: *Mem, st: *bench.State) void {
            var i: u64 = 0;
            while (i < st.iterations()) : (i += 1) {
                var blobs: model.MemBlobs = .init(st.allocator());
                defer blobs.deinit();
                const q = fill(st.allocator(), st.ioHandle(), x, &blobs) catch unreachable;
                q.deinit();
            }
        }
    }.f);
}

// --------------------------------------------------------------- store

const bench_dir = ".zig-cache/bench-review";

const Append = struct { store: *zg_review.store.ChangesetStore, record: []const u8, n: u64 = 0 };

const Load = struct { gpa: Allocator, io: Io, dir: Io.Dir };

/// The journal's caller cost per changeset record (budget
/// `review.journal_append` < 20 µs), and a cold load of 10k changesets
/// (budget `review.store_cold_load` < 50 ms). In a directory under the
/// current one, removed afterwards.
fn registerStore(b: *bench.Bench) !void {
    if (!wanted(b, "review.journal_append") and !wanted(b, "review.store_cold_load")) return;
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(b.io, bench_dir) catch {};
    defer cwd.deleteTree(b.io, bench_dir) catch {};
    try cwd.createDirPath(b.io, bench_dir ++ "/append");
    try cwd.createDirPath(b.io, bench_dir ++ "/load");
    var root = try cwd.openDir(b.io, bench_dir, .{});
    defer root.close(b.io);

    // A typical record: a 3-file changeset of the agent's.
    const text = try codeText(b.gpa, 300, 5);
    defer b.gpa.free(text);
    var e = try spreadEdits(b.gpa, text, 4);
    defer e.deinit();
    var blobs: model.MemBlobs = .init(b.gpa);
    defer blobs.deinit();
    const q = try model.Queue.init(b.gpa, b.io, .{ .root = "/w", .blobs = blobs.blobs() });
    defer q.deinit();
    const batch = try q.beginBatch(agentProv(1));
    for ([_][]const u8{ "src/a.zig", "src/b.zig", "src/c.zig" }) |n| try q.addEdit(batch, n, text, null, &e);
    const id = try q.commitBatch(batch, .{});
    var aw: std.Io.Writer.Allocating = .init(b.gpa);
    defer aw.deinit();
    try zg_review.store.records.writeChangeset(&aw.writer, q.get(id).?, blobs.blobs(), b.gpa);

    {
        var a: Append = .{ .store = try zg_review.store.ChangesetStore.open(b.gpa, b.io, root, "append", .{ .process_tag = 1 }), .record = aw.written() };
        defer a.store.close();
        try b.run("review.journal_append", &a, struct {
            fn f(x: *Append, st: *bench.State) void {
                var i: u64 = 0;
                while (i < st.iterations()) : (i += 1) {
                    x.store.append(.changeset, x.record) catch unreachable;
                    x.n += 1;
                    // Keep the pending buffer bounded, as flushes would.
                    if (x.n % 4096 == 0) {
                        x.store.mutex.lockUncancelable(x.store.io);
                        x.store.pending.clearRetainingCapacity();
                        x.store.mutex.unlock(x.store.io);
                    }
                }
            }
        }.f);
    }

    // 10k changesets, written once with distinct ids.
    {
        const st = try zg_review.store.ChangesetStore.open(b.gpa, b.io, root, "load", .{ .process_tag = 2 });
        defer st.close();
        const cs = q.getMut(id).?;
        for (1..10_001) |n| {
            cs.id = @enumFromInt(n);
            aw.clearRetainingCapacity();
            try zg_review.store.records.writeChangeset(&aw.writer, cs, blobs.blobs(), b.gpa);
            try st.append(.changeset, aw.written());
        }
        cs.id = id;
        try st.flush();
        std.debug.print("review.store_cold_load: 10,000 changeset records of {d} bytes\n", .{aw.written().len});
    }
    var l: Load = .{ .gpa = b.gpa, .io = b.io, .dir = root };
    try b.run("review.store_cold_load", &l, struct {
        fn f(x: *Load, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                const st = zg_review.store.ChangesetStore.open(x.gpa, x.io, x.dir, "load", .{ .process_tag = 3 }) catch unreachable;
                defer st.close();
                const lq = model.Queue.init(x.gpa, x.io, .{ .root = "/w", .blobs = st.blobs() }) catch unreachable;
                defer lq.deinit();
                var sink = st.queueSink(lq, null, null);
                const rep = st.load(sink.sink()) catch unreachable;
                std.debug.assert(lq.changesets.count() == 10_000);
                bench.doNotOptimizeAway(rep.records);
            }
        }
    }.f);
}
