//! Sorting, top-k and sampling for query execution (E13.F06.S02.T03).
//! Rows carry their order (`ord`) so every result is deterministic:
//! ties keep their original order, nulls sort last in either direction,
//! and `sample n` keeps the n rows whose order hashes lowest.

const std = @import("std");
const plan = @import("plan.zig");
const ev = @import("expr_eval.zig");
const agg = @import("agg.zig");

const Allocator = std.mem.Allocator;
const Value = ev.Value;
const PlanKey = plan.PlanKey;

pub const Row = struct {
    vals: []Value,
    /// Position in the stage's input: the source row (or, after a stage
    /// that reorders, the position) << 64, plus join match offsets.
    ord: u128,
};

/// A deep copy of `vals` in `a`, charged to `budget`.
pub fn dupeRow(a: Allocator, vals: []const Value, budget: *agg.Budget) ![]Value {
    const out = try a.alloc(Value, vals.len);
    var bytes: usize = @sizeOf(Row);
    for (vals, out) |v, *o| {
        o.* = try agg.dupeValue(a, v);
        bytes += agg.valueBytes(v);
    }
    try budget.charge(bytes);
    return out;
}

/// Orders by one key: nulls last, `desc` reverses the rest.
pub fn cmpKey(a: Value, b: Value, desc: bool) std.math.Order {
    if (a == .null_ or b == .null_) {
        if (a == .null_ and b == .null_) return .eq;
        return if (a == .null_) .gt else .lt;
    }
    const o = ev.order(a, b) orelse return .eq;
    return if (desc) o.invert() else o;
}

pub fn lessThan(keys: []const PlanKey, a: Row, b: Row) bool {
    for (keys) |k| switch (cmpKey(a.vals[k.col], b.vals[k.col], k.desc)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    };
    return a.ord < b.ord;
}

pub fn sortRows(rows: []Row, keys: []const PlanKey) void {
    std.sort.pdq(Row, rows, keys, lessThan);
}

pub fn sortByOrd(rows: []Row) void {
    std.sort.pdq(Row, rows, {}, struct {
        fn lt(_: void, a: Row, b: Row) bool {
            return a.ord < b.ord;
        }
    }.lt);
}

/// The first `k` rows by `keys` among those added (bounded memory: the
/// buffer is cut back to `k` whenever it reaches `2k`).
pub const TopK = struct {
    arena: Allocator,
    keys: []const PlanKey,
    k: u64,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    /// The k-th best so far once the buffer was cut.
    worst: ?Row = null,
    budget: *agg.Budget,

    pub fn add(t: *TopK, vals: []const Value, ord: u128) !void {
        if (t.k == 0) return;
        const probe: Row = .{ .vals = @constCast(vals), .ord = ord };
        if (t.worst) |w| if (!lessThan(t.keys, probe, w)) return;
        try t.rows.append(t.arena, .{ .vals = try dupeRow(t.arena, vals, t.budget), .ord = ord });
        if (t.rows.items.len >= 2 * t.k) t.cut();
    }

    fn cut(t: *TopK) void {
        sortRows(t.rows.items, t.keys);
        if (t.rows.items.len > t.k) t.rows.shrinkRetainingCapacity(@intCast(t.k));
        if (t.rows.items.len == t.k) t.worst = t.rows.items[t.rows.items.len - 1];
    }

    pub fn merge(t: *TopK, o: *TopK) !void {
        for (o.rows.items) |r| try t.add(r.vals, r.ord);
    }

    /// The top k, sorted.
    pub fn finish(t: *TopK) []Row {
        t.cut();
        return t.rows.items;
    }
};

pub const sample_seed: u64 = 0x5A4D_504C_4553_4545;

pub fn sampleRank(ord: u128) u64 {
    return std.hash.Wyhash.hash(sample_seed, std.mem.asBytes(&ord));
}

/// `n` rows chosen by hashing their order: deterministic, the same in
/// parallel and serial runs, and spread over the whole input.
pub const Sample = struct {
    arena: Allocator,
    n: u64,
    rows: std.ArrayListUnmanaged(Ranked) = .empty,
    worst: ?u64 = null,
    budget: *agg.Budget,

    const Ranked = struct { rank: u64, row: Row };

    fn lt(_: void, a: Ranked, b: Ranked) bool {
        return a.rank < b.rank or (a.rank == b.rank and a.row.ord < b.row.ord);
    }

    pub fn add(s: *Sample, vals: []const Value, ord: u128) !void {
        if (s.n == 0) return;
        const rank = sampleRank(ord);
        if (s.worst) |w| if (rank > w) return;
        try s.rows.append(s.arena, .{ .rank = rank, .row = .{ .vals = try dupeRow(s.arena, vals, s.budget), .ord = ord } });
        if (s.rows.items.len >= 2 * s.n) s.cut();
    }

    fn cut(s: *Sample) void {
        std.sort.pdq(Ranked, s.rows.items, {}, lt);
        if (s.rows.items.len > s.n) s.rows.shrinkRetainingCapacity(@intCast(s.n));
        if (s.rows.items.len == s.n) s.worst = s.rows.items[s.rows.items.len - 1].rank;
    }

    pub fn merge(s: *Sample, o: *Sample) !void {
        for (o.rows.items) |r| try s.add(r.row.vals, r.row.ord);
    }

    /// The sample in input order.
    pub fn finish(s: *Sample, a: Allocator) ![]Row {
        s.cut();
        const out = try a.alloc(Row, s.rows.items.len);
        for (s.rows.items, out) |r, *o| o.* = r.row;
        sortByOrd(out);
        return out;
    }
};
