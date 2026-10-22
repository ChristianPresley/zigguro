//! Synthetic history for the graph benchmarks: `n` change objects forming
//! a DAG shaped like a busy monorepo (mostly single parents, some merges
//! of recent work, an occasional long-lived branch merged back), with
//! rising committer times and some clock skew.

const std = @import("std");
const scm = @import("zg_scm");

/// Writes the DAG into `s` in batches; returns the IDs in topological
/// order (caller frees).
pub fn generate(gpa: std.mem.Allocator, s: *scm.Store, n: usize, seed: u64) ![]scm.ObjectId {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const ids = try gpa.alloc(scm.ObjectId, n);
    errdefer gpa.free(ids);
    const empty_tree = try scm.encode.idOf(gpa, scm.Tree, .{ .entries = &.{} });
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var time: i64 = 1_600_000_000_000;
    var batch = s.batch();
    defer batch.abort();
    var parents: [3]scm.ObjectId = undefined;
    var desc: [24]u8 = undefined;
    for (ids, 0..) |*id, i| {
        var np: usize = 0;
        if (i > 0) {
            parents[0] = ids[i - 1 - @min(i - 1, rng.uintLessThan(usize, 3))];
            np = 1;
            const roll = rng.uintLessThan(u16, 1000);
            if (i > 2 and roll < 120) {
                const back: usize = if (roll < 5) 2 + rng.uintLessThan(usize, 5000) else 2 + rng.uintLessThan(usize, 60);
                const cand = ids[i - 1 - @min(i - 1, back)];
                if (!cand.eql(parents[0])) {
                    parents[1] = cand;
                    np = 2;
                }
            }
        }
        time += rng.intRangeAtMost(i64, -2_000, 120_000);
        var cid: scm.ChangeId = undefined;
        rng.bytes(&cid.bytes);
        const sig: scm.Signature = .{ .name = "bench", .email = "bench@example.com", .time_ms = time, .tz_offset_min = 0 };
        const c: scm.Change = .{
            .parents = parents[0..np],
            .tree_terms = &.{empty_tree},
            .change_id = cid,
            .predecessors = &.{},
            .author = sig,
            .committer = sig,
            .description = std.fmt.bufPrint(&desc, "commit {d}", .{i}) catch unreachable,
            .provenance = null,
            .extra = &.{},
            .sig = null,
        };
        aw.clearRetainingCapacity();
        try scm.encode.encode(scm.Change, c, &aw.writer);
        id.* = try batch.put(.change, aw.written());
        if (i % 100_000 == 99_999) {
            try batch.commit();
            batch = s.batch();
        }
    }
    try batch.commit();
    return ids;
}
