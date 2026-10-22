//! Benchmarks for zg_review; run with `zig build bench` at the repo root.
//! Inputs are generated (seeded), so runs are reproducible.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_review = @import("zg_review");
const bench = zg_core.bench;

const model = zg_review.model;
const ChangeSet = model.changeset.ChangeSet;
const Replace = model.changeset.Replace;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

const Hunks = struct {
    base: []const u8,
    lines: zg_core.LineIndex,
    cs: ChangeSet,
    gpa: std.mem.Allocator,
};

fn register(b: *bench.Bench) !void {
    try registerHunks(b);
    try registerSubmit(b);
    try registerApprovals(b);
    try registerReanchor(b);
}

const Reanchor = struct {
    store: zg_review.feedback.CommentStore,
    texts: [2][]const u8,
};

/// Re-anchor 200 threads after a revision that inserted 3 lines at the
/// top of a 2,000-line file, with no line mapping (hash search; the
/// budget is < 5 ms). Alternates between the two texts so every pass
/// moves every thread.
fn registerReanchor(b: *bench.Bench) !void {
    var v1: std.ArrayList(u8) = .empty;
    defer v1.deinit(b.gpa);
    for (0..2_000) |i| try v1.print(b.gpa, "    const x{d} = compute({d}, \"line\");\n", .{ i, i * 7 });
    var v2: std.ArrayList(u8) = .empty;
    defer v2.deinit(b.gpa);
    try v2.appendSlice(b.gpa, "// a\n// b\n// c\n");
    try v2.appendSlice(b.gpa, v1.items);
    var r: Reanchor = .{ .store = .init(b.gpa, .{}), .texts = .{ v2.items, v1.items } };
    defer r.store.deinit();
    const target: model.ChangesetId = @enumFromInt(1);
    for (0..200) |i| {
        const at: zg_review.feedback.CommentAnchor = try .at(b.gpa, "src/a.zig", .new, v1.items, .{ .start = @intCast(i * 10), .count = 2 });
        _ = try r.store.create(target, at, null, false, "why?", .{ .user = "bench" }, 0);
    }
    try b.run("review.comments.reanchor_200", &r, struct {
        fn f(x: *Reanchor, st: *bench.State) void {
            var i: u64 = 0;
            while (i < st.iterations()) : (i += 1) {
                const rep = x.store.reanchor(@enumFromInt(1), "src/a.zig", x.texts[i % 2], .{}) catch unreachable;
                bench.doNotOptimizeAway(rep);
            }
        }
    }.f);
}

/// Present, answer and collect one approval (the broker's share of the
/// "answer to resumed waiter < 1 ms" budget), pruned every 1,000.
fn registerApprovals(b: *bench.Bench) !void {
    var br: zg_review.approvals.ApprovalBroker = .init(b.gpa, b.io, .{});
    defer br.deinit();
    try b.run("review.approvals.round_trip", &br, struct {
        fn f(x: *zg_review.approvals.ApprovalBroker, st: *bench.State) void {
            var i: u64 = 0;
            while (i < st.iterations()) : (i += 1) {
                const id = x.present(.{
                    .kind = .command,
                    .actor = .{ .agent = .{ .session = "s1", .agent = "main" } },
                    .title = "Run command",
                    .detail_json = "{\"cwd\":\"/ws\"}",
                    .command = "cargo test --release",
                    .created_ms = 0,
                }) catch unreachable;
                x.answer(id, .allow_once, "bench") catch unreachable;
                bench.doNotOptimizeAway(x.await(id, x.io) catch unreachable);
                if (i % 1000 == 999) _ = x.prune(std.math.maxInt(i64));
            }
        }
    }.f);
}

const Submit = struct {
    q: *model.Queue,
    base: []const u8,
    edits: [3]ChangeSet,
};

/// Owner-thread submit of a 3-file batch (budget < 200 µs), base texts of
/// 2,000 lines each.
fn registerSubmit(b: *bench.Bench) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(b.gpa);
    for (0..2_000) |i| try text.print(b.gpa, "line {d} of the file, with some code-like text ();\n", .{i});
    var mem: model.MemBlobs = .init(b.gpa);
    defer mem.deinit();
    var s: Submit = .{ .q = try model.Queue.init(b.gpa, b.io, .{ .root = "/w", .blobs = mem.blobs() }), .base = text.items, .edits = undefined };
    defer s.q.deinit();
    for (&s.edits, 0..) |*e, i| {
        const at = 100 + 3_000 * i;
        e.* = try .fromEdits(b.gpa, text.items.len, &.{ .{ .range = .{ .start = at, .end = at + 4 }, .text = "LINE" }, .{ .range = .{ .start = at + 40_000, .end = at + 40_000 }, .text = "new line\n" } });
    }
    defer for (&s.edits) |*e| e.deinit();
    try b.run("review.submit.3_files", &s, struct {
        fn f(x: *Submit, st: *bench.State) void {
            const names = [_][]const u8{ "src/a.zig", "src/b.zig", "src/c.zig" };
            var i: u64 = 0;
            while (i < st.iterations()) : (i += 1) {
                const id = x.q.beginBatch(.{ .origin = .{ .user_bulk = .{ .command = "bench" } }, .label = "bench", .workspace = "/w", .created_ms = 0 }) catch unreachable;
                for (names, &x.edits) |n, *e| x.q.addEdit(id, n, x.base, null, e) catch unreachable;
                const cs = x.q.commitBatch(id, .{}) catch unreachable;
                x.q.remove(cs);
            }
        }
    }.f);
}

/// 1,000 one-line replaces scattered over a 10k-line file (the
/// `deriveHunks` budget: < 2 ms).
fn registerHunks(b: *bench.Bench) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(b.gpa);
    var rng: std.Random.DefaultPrng = .init(0x12e1);
    const r = rng.random();
    var starts: std.ArrayList(u64) = .empty;
    defer starts.deinit(b.gpa);
    for (0..10_000) |_| {
        try starts.append(b.gpa, text.items.len);
        const n = 20 + r.uintLessThan(usize, 80);
        for (0..n) |_| try text.append(b.gpa, "abcdefghijklmnopqrstuvwxyz (){};"[r.uintLessThan(usize, 32)]);
        try text.append(b.gpa, '\n');
    }
    var reps: std.ArrayList(Replace) = .empty;
    defer reps.deinit(b.gpa);
    var line: usize = 0;
    for (0..1_000) |_| {
        line += 1 + r.uintLessThan(usize, 18);
        if (line >= starts.items.len) break;
        const s = starts.items[line] + 2;
        try reps.append(b.gpa, .{ .range = .{ .start = s, .end = s + 3 }, .text = if (r.boolean()) "xyz" else "a\nb" });
    }
    var h: Hunks = .{ .base = text.items, .lines = try .build(b.gpa, text.items), .cs = try .fromEdits(b.gpa, text.items.len, reps.items), .gpa = b.gpa };
    defer h.lines.deinit(b.gpa);
    defer h.cs.deinit();
    try b.run("review.hunks.1k_replaces_10k_lines", &h, struct {
        fn f(x: *Hunks, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                const hs = model.deriveHunks(x.gpa, x.base, &x.lines, &x.cs, .{}) catch unreachable;
                bench.doNotOptimizeAway(hs.len);
                x.gpa.free(hs);
            }
        }
    }.f);
}
