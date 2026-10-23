//! Aggregates and hash group-by for query execution (E13.F06.S02.T03).
//!
//! Each worker fills its own `GroupTable`; the tables merge at the end,
//! and groups come out in the order of their first row. Aggregates are
//! exact up to a size limit: `count_distinct` keeps exact hashes up to
//! 1 M distinct values, then an F06 HyperLogLog; `median` and `p` keep
//! the values up to 1 M per group, then an F06 t-digest. Results past
//! those limits are flagged approximate.

const std = @import("std");
const plan = @import("plan.zig");
const types = @import("types.zig");
const ev = @import("expr_eval.zig");
const sketches = @import("../sketches.zig");

const Allocator = std.mem.Allocator;
const Value = ev.Value;
const AggSpec = plan.AggSpec;

pub const exact_distinct_max = 1_000_000;
pub const exact_quantile_max = 1_000_000;

/// The memory guard shared by a query's workers.
pub const Budget = struct {
    used: std.atomic.Value(usize) = .init(0),
    max: usize,

    pub fn charge(b: *Budget, n: usize) error{QueryTooLarge}!void {
        const now = b.used.fetchAdd(n, .monotonic) + n;
        if (now > b.max) return error.QueryTooLarge;
    }
};

/// A deep copy of `v` (its string) in `a`.
pub fn dupeValue(a: Allocator, v: Value) Allocator.Error!Value {
    return if (v == .string) .{ .string = try a.dupe(u8, v.string) } else v;
}

pub fn valueBytes(v: Value) usize {
    return @sizeOf(Value) + if (v == .string) v.string.len else 0;
}

pub const Acc = struct {
    n: u64 = 0,
    isum: i128 = 0,
    fsum: f64 = 0,
    saw_float: bool = false,
    best: Value = .null_,
    mean: f64 = 0,
    m2: f64 = 0,
    set: ?*std.AutoHashMapUnmanaged(u64, void) = null,
    hll: ?*sketches.HyperLogLog = null,
    vals: ?*std.ArrayListUnmanaged(f64) = null,
    digest: ?*sketches.Quantiles = null,

    /// Adds `v` (ignored when null, except by `count()`, which gets a
    /// non-null placeholder per row).
    pub fn add(acc: *Acc, spec: *const AggSpec, v: Value, a: Allocator, budget: *Budget) !void {
        if (v == .null_) return;
        acc.n += 1;
        switch (spec.func) {
            .count => {},
            .count_distinct => try acc.addHash(ev.hashValue(v, 0x5eed), a, budget),
            .sum, .avg => switch (v) {
                .int => |i| acc.isum += i,
                else => {
                    acc.fsum += ev.num(v) orelse 0;
                    acc.saw_float = true;
                },
            },
            .min, .max => {
                const o = if (acc.best == .null_) null else ev.order(v, acc.best);
                const better = if (o) |x| (if (spec.func == .min) x == .lt else x == .gt) else acc.best == .null_;
                if (better) {
                    if (acc.best == .string) _ = budget.used.fetchSub(acc.best.string.len, .monotonic);
                    acc.best = try dupeValue(a, v);
                    if (v == .string) try budget.charge(v.string.len);
                }
            },
            .stddev => {
                const x = ev.num(v) orelse return;
                const d = x - acc.mean;
                acc.mean += d / @as(f64, @floatFromInt(acc.n));
                acc.m2 += d * (x - acc.mean);
            },
            .median, .p => try acc.addQuantile(ev.num(v) orelse return, a, budget),
        }
    }

    fn addHash(acc: *Acc, h: u64, a: Allocator, budget: *Budget) !void {
        if (acc.hll) |hll| return hll.add(h);
        const set = acc.set orelse blk: {
            const s = try a.create(std.AutoHashMapUnmanaged(u64, void));
            s.* = .empty;
            acc.set = s;
            break :blk s;
        };
        const gop = try set.getOrPut(a, h);
        if (gop.found_existing) return;
        try budget.charge(16);
        if (set.count() > exact_distinct_max) try acc.toHll(a);
    }

    fn toHll(acc: *Acc, a: Allocator) !void {
        const hll = try a.create(sketches.HyperLogLog);
        hll.* = .{};
        if (acc.set) |s| {
            var it = s.keyIterator();
            while (it.next()) |k| hll.add(k.*);
        }
        acc.set = null;
        acc.hll = hll;
    }

    fn addQuantile(acc: *Acc, x: f64, a: Allocator, budget: *Budget) !void {
        if (acc.digest) |d| return d.add(x);
        const vals = acc.vals orelse blk: {
            const l = try a.create(std.ArrayListUnmanaged(f64));
            l.* = .empty;
            acc.vals = l;
            break :blk l;
        };
        try vals.append(a, x);
        try budget.charge(8);
        if (vals.items.len > exact_quantile_max) try acc.toDigest(a);
    }

    fn toDigest(acc: *Acc, a: Allocator) !void {
        const d = try a.create(sketches.Quantiles);
        d.* = .init(a);
        if (acc.vals) |l| for (l.items) |x| try d.add(x);
        acc.vals = null;
        acc.digest = d;
    }

    /// Folds `o` (another worker's state for the same group) into `acc`.
    pub fn merge(acc: *Acc, o: *Acc, spec: *const AggSpec, a: Allocator, budget: *Budget) !void {
        const n0 = acc.n;
        acc.n += o.n;
        switch (spec.func) {
            .count => {},
            .count_distinct => {
                if (o.hll != null and acc.hll == null) try acc.toHll(a);
                if (acc.hll) |h| {
                    if (o.hll) |oh| h.merge(oh) else if (o.set) |s| {
                        var it = s.keyIterator();
                        while (it.next()) |k| h.add(k.*);
                    }
                } else if (o.set) |s| {
                    var it = s.keyIterator();
                    while (it.next()) |k| try acc.addHash(k.*, a, budget);
                }
            },
            .sum, .avg => {
                acc.isum += o.isum;
                acc.fsum += o.fsum;
                acc.saw_float = acc.saw_float or o.saw_float;
            },
            .min, .max => if (o.best != .null_) {
                const better = if (acc.best == .null_) true else blk: {
                    const x = ev.order(o.best, acc.best) orelse break :blk false;
                    break :blk if (spec.func == .min) x == .lt else x == .gt;
                };
                if (better) acc.best = try dupeValue(a, o.best);
            },
            .stddev => if (o.n > 0) {
                // Chan et al.'s parallel update.
                const na: f64 = @floatFromInt(n0);
                const nb: f64 = @floatFromInt(o.n);
                const n = na + nb;
                const d = o.mean - acc.mean;
                acc.mean += d * nb / n;
                acc.m2 += o.m2 + d * d * na * nb / n;
            },
            .median, .p => {
                if (o.digest != null and acc.digest == null) try acc.toDigest(a);
                if (acc.digest) |d| {
                    if (o.digest) |od| try d.merge(od) else if (o.vals) |l| for (l.items) |x| try d.add(x);
                } else if (o.vals) |l| for (l.items) |x| try acc.addQuantile(x, a, budget);
            },
        }
    }

    /// The aggregate's value; sets `approx` when a sketch answered.
    pub fn final(acc: *Acc, spec: *const AggSpec, approx: *bool) !Value {
        switch (spec.func) {
            .count => return .{ .int = @intCast(acc.n) },
            .count_distinct => {
                if (acc.hll) |h| {
                    approx.* = true;
                    return .{ .int = @intCast(h.estimate()) };
                }
                return .{ .int = if (acc.set) |s| s.count() else 0 };
            },
            .sum => {
                if (acc.n == 0) return .null_;
                if (spec.ty == .float or acc.saw_float) return .{ .float = @as(f64, @floatFromInt(acc.isum)) + acc.fsum };
                if (acc.isum < std.math.minInt(i64) or acc.isum > std.math.maxInt(i64)) return .null_;
                return .{ .int = @intCast(acc.isum) };
            },
            .avg => {
                if (acc.n == 0) return .null_;
                return .{ .float = (@as(f64, @floatFromInt(acc.isum)) + acc.fsum) / @as(f64, @floatFromInt(acc.n)) };
            },
            .min, .max => return acc.best,
            .stddev => {
                if (acc.n < 2) return .null_;
                return .{ .float = @sqrt(acc.m2 / @as(f64, @floatFromInt(acc.n - 1))) };
            },
            .median, .p => {
                const q = if (spec.func == .median) 0.5 else spec.q;
                if (acc.digest) |d| {
                    approx.* = true;
                    try d.flush();
                    return if (d.quantile(q)) |x| .{ .float = x } else .null_;
                }
                const l = acc.vals orelse return .null_;
                if (l.items.len == 0) return .null_;
                return .{ .float = exactQuantile(l.items, q) };
            },
        }
    }
};

/// The `q` quantile of `xs` (sorted in place), interpolating linearly
/// between the closest ranks.
pub fn exactQuantile(xs: []f64, q: f64) f64 {
    std.sort.pdq(f64, xs, {}, std.sort.asc(f64));
    const pos = q * @as(f64, @floatFromInt(xs.len - 1));
    const lo: usize = @intFromFloat(@floor(pos));
    const hi = @min(lo + 1, xs.len - 1);
    const frac = pos - @floor(pos);
    return xs[lo] + (xs[hi] - xs[lo]) * frac;
}

pub const Group = struct {
    keys: []Value,
    accs: []Acc,
    /// The order of the group's first row.
    first: u128,
    hash: u64,
    next: u32 = none,
};

const none = std.math.maxInt(u32);

pub const GroupTable = struct {
    arena: Allocator,
    specs: []const AggSpec,
    nkeys: usize,
    heads: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    groups: std.ArrayListUnmanaged(Group) = .empty,
    budget: *Budget,

    pub fn init(arena: Allocator, nkeys: usize, specs: []const AggSpec, budget: *Budget) GroupTable {
        return .{ .arena = arena, .nkeys = nkeys, .specs = specs, .budget = budget };
    }

    pub fn hashKeys(keys: []const Value) u64 {
        var h: u64 = 0x9E37_79B9_7F4A_7C15;
        for (keys) |k| h = std.hash.Wyhash.hash(h, std.mem.asBytes(&ev.hashValue(k, 0)));
        return h;
    }

    fn same(a: []const Value, b: []const Value) bool {
        for (a, b) |x, y| if (!ev.sameKey(x, y)) return false;
        return true;
    }

    /// The group of `keys` (values that only need to live for the call),
    /// created when new; `ord` keeps the earliest row.
    pub fn get(t: *GroupTable, keys: []const Value, hash: u64, ord: u128) !*Group {
        const gop = try t.heads.getOrPut(t.arena, hash);
        if (gop.found_existing) {
            var i = gop.value_ptr.*;
            while (i != none) : (i = t.groups.items[i].next) {
                const g = &t.groups.items[i];
                if (same(g.keys, keys)) {
                    if (ord < g.first) g.first = ord;
                    return g;
                }
            }
        }
        const ks = try t.arena.alloc(Value, keys.len);
        var bytes: usize = @sizeOf(Group) + t.specs.len * @sizeOf(Acc);
        for (keys, ks) |k, *o| {
            o.* = try dupeValue(t.arena, k);
            bytes += valueBytes(k);
        }
        try t.budget.charge(bytes);
        const accs = try t.arena.alloc(Acc, t.specs.len);
        for (accs) |*x| x.* = .{};
        const idx: u32 = @intCast(t.groups.items.len);
        try t.groups.append(t.arena, .{ .keys = ks, .accs = accs, .first = ord, .hash = hash, .next = if (gop.found_existing) gop.value_ptr.* else none });
        gop.value_ptr.* = idx;
        return &t.groups.items[idx];
    }

    /// Adds one row: `keys` are its key values, `args[i]` the value of
    /// aggregate i's argument (a non-null placeholder for `count()`).
    pub fn add(t: *GroupTable, keys: []const Value, args: []const Value, ord: u128) !void {
        const g = try t.get(keys, hashKeys(keys), ord);
        for (g.accs, t.specs, args) |*acc, *spec, v| try acc.add(spec, v, t.arena, t.budget);
    }

    /// Folds another worker's table into this one.
    pub fn merge(t: *GroupTable, o: *GroupTable) !void {
        for (o.groups.items) |*og| {
            const g = try t.get(og.keys, og.hash, og.first);
            for (g.accs, og.accs, t.specs) |*acc, *oa, *spec| try acc.merge(oa, spec, t.arena, t.budget);
        }
    }

    pub const Out = struct { values: []Value, first: u128 };

    /// One row per group (keys, then aggregates), in first-row order.
    pub fn finish(t: *GroupTable, out_arena: Allocator, approx: *bool) ![]Out {
        const rows = try out_arena.alloc(Out, t.groups.items.len);
        for (t.groups.items, rows) |*g, *r| {
            const vals = try out_arena.alloc(Value, t.nkeys + t.specs.len);
            @memcpy(vals[0..t.nkeys], g.keys);
            for (g.accs, t.specs, vals[t.nkeys..]) |*acc, *spec, *o| o.* = ev.coerce(try acc.final(spec, approx), spec.ty);
            r.* = .{ .values = vals, .first = g.first };
        }
        std.sort.pdq(Out, rows, {}, struct {
            fn lt(_: void, a: Out, b: Out) bool {
                return a.first < b.first;
            }
        }.lt);
        return rows;
    }
};
