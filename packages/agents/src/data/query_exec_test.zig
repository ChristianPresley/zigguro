//! Query execution (E13.F06.S02.T03): the parallel executor against a
//! naive one-row-at-a-time reference, and its guards.

const std = @import("std");
const query = @import("query/root.zig");
const dataset = @import("dataset.zig");
const infer = @import("infer.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const types = query.types;
const plan = query.plan;
const exec = query.exec;
const ev = query.expr_eval;
const agg = query.agg;
const sort = query.sort;
const Value = exec.Value;
const Dataset = dataset.Dataset;

// ---------------------------------------------------------------------
// Harness

const Tables = struct {
    names: []const []const u8,
    sets: []const *Dataset,

    fn get(ctx: *anyopaque, name: []const u8) ?*Dataset {
        const t: *const Tables = @ptrCast(@alignCast(ctx));
        for (t.names, t.sets) |n, d| if (std.mem.eql(u8, n, name)) return d;
        return null;
    }

    fn resolve(ctx: *anyopaque, name: []const u8) ?types.Schema {
        const ds = get(ctx, name) orelse return null;
        ds.waitIndexed() catch return null;
        const cols = schema_arena.allocator().alloc(types.SchemaCol, ds.columns.len) catch return null;
        for (cols, ds.columns, 0..) |*c, n, i| c.* = .{
            .name = n,
            .ty = types.Type.fromCol(if (i < ds.types.len) ds.types[i] else .string),
        };
        return .{ .columns = cols };
    }

    fn datasets(t: *const Tables) exec.Datasets {
        return .{ .ctx = @constCast(t), .get = get };
    }

    fn catalog(t: *const Tables) query.Catalog {
        return .{ .ctx = @constCast(t), .resolve = resolve };
    }
};

/// Schemas live until the test binary exits (the catalog has no
/// allocator of its own).
var schema_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

fn mustPlan(a: std.mem.Allocator, t: *const Tables, src: []const u8) !query.Plan {
    var diag: query.Diagnostic = .{};
    const tree = query.parse(a, src, &diag) catch |e| {
        std.debug.print("{s}: {f}\n", .{ src, diag });
        return e;
    };
    return plan.plan(a, &tree, t.catalog(), &diag) catch |e| {
        std.debug.print("{s}: {f}\n", .{ src, diag });
        return e;
    };
}

const Collect = struct {
    a: std.mem.Allocator,
    rows: std.ArrayListUnmanaged([]Value) = .empty,
    batches: u32 = 0,

    fn batch(ctx: *anyopaque, cols: []const exec.ColumnVec, n: u32) anyerror!void {
        const c: *Collect = @ptrCast(@alignCast(ctx));
        c.batches += 1;
        for (0..n) |r| {
            const row = try c.a.alloc(Value, cols.len);
            for (cols, row) |col, *v| v.* = try agg.dupeValue(c.a, col.values[r]);
            try c.rows.append(c.a, row);
        }
    }

    fn sink(c: *Collect) exec.ResultSink {
        return .{ .ctx = c, .batch = batch };
    }
};

const RunOpts = struct { threads: u16 = 0, morsel_rows: u32 = 64 << 10, max_mem: usize = 1 << 30, batch_rows: u32 = 4096 };

fn run(a: std.mem.Allocator, t: *const Tables, p: *const query.Plan, o: RunOpts) !struct { rows: [][]Value, stats: exec.ExecStats } {
    var c: Collect = .{ .a = a };
    const cancel: std.atomic.Value(bool) = .init(false);
    const stats = try exec.execute(io, gpa, p, t.datasets(), c.sink(), .{
        .cancel = &cancel,
        .threads = o.threads,
        .morsel_rows = o.morsel_rows,
        .max_mem = o.max_mem,
        .batch_rows = o.batch_rows,
    });
    return .{ .rows = c.rows.items, .stats = stats };
}

fn sameValue(x: Value, y: Value) bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return switch (x) {
        .null_ => true,
        .bool_ => |b| b == y.bool_,
        .int => |i| i == y.int,
        .float => |f| f == y.float or (std.math.isNan(f) and std.math.isNan(y.float)) or
            @abs(f - y.float) <= 1e-9 * @max(1.0, @max(@abs(f), @abs(y.float))),
        .string => |s| std.mem.eql(u8, s, y.string),
        .date => |d| d == y.date,
        .datetime => |d| d == y.datetime,
    };
}

fn expectSameRows(src: []const u8, want: []const []const Value, got: []const []const Value) !void {
    const fail = blk: {
        if (want.len != got.len) break :blk true;
        for (want, got) |w, g| {
            if (w.len != g.len) break :blk true;
            for (w, g) |x, y| if (!sameValue(x, y)) break :blk true;
        }
        return;
    };
    if (fail) {
        std.debug.print("query: {s}\nwant {d} rows, got {d}\n", .{ src, want.len, got.len });
        const n = @min(@max(want.len, got.len), 12);
        for (0..n) |i| {
            std.debug.print("  {d}: want ", .{i});
            if (i < want.len) printRow(want[i]) else std.debug.print("-", .{});
            std.debug.print("\n     got  ", .{});
            if (i < got.len) printRow(got[i]) else std.debug.print("-", .{});
            std.debug.print("\n", .{});
        }
        return error.TestUnexpectedResult;
    }
}

fn printRow(r: []const Value) void {
    for (r) |v| switch (v) {
        .null_ => std.debug.print("null ", .{}),
        .bool_ => |b| std.debug.print("{} ", .{b}),
        .int => |i| std.debug.print("{d} ", .{i}),
        .float => |f| std.debug.print("{d} ", .{f}),
        .string => |s| std.debug.print("\"{s}\" ", .{s}),
        .date => |d| std.debug.print("d{d} ", .{d}),
        .datetime => |d| std.debug.print("t{d} ", .{d}),
    };
}

// ---------------------------------------------------------------------
// The reference: every stage in order over materialized rows, with the
// same order rules as the executor (see exec.zig) but no morsels,
// hashing, sketches or merging.

const RRow = struct { vals: []Value, ord: u128 };

const Reference = struct {
    a: std.mem.Allocator,
    t: *const Tables,
    e: ev.Eval,

    fn readAll(r: *Reference, ds: *Dataset) ![]RRow {
        try ds.waitIndexed();
        const n: u64 = switch (ds.rowCount()) {
            inline else => |x| x,
        };
        const ictx = ds.inferCtx();
        const rows = try r.a.alloc(RRow, @intCast(n));
        for (rows, 0..) |*row, i| {
            const vals = try r.a.alloc(Value, ds.columns.len);
            for (vals, 0..) |*v, c| {
                const ty: infer.ColType = if (c < ds.types.len) ds.types[c] else .string;
                const is_null = try ds.isNull(i, @intCast(c), r.a);
                v.* = ev.parseCell(try ds.cell(i, @intCast(c), r.a), is_null, ty, ictx);
            }
            row.* = .{ .vals = vals, .ord = @as(u128, i) << 64 };
        }
        return rows;
    }

    fn runPlan(r: *Reference, p: *const query.Plan) ![][]Value {
        var rows = try r.readAll(Tables.get(@constCast(r.t), p.source.name).?);
        if (p.filter) |f| {
            var kept: std.ArrayListUnmanaged(RRow) = .empty;
            for (rows) |row| if (ev.truthy(try r.e.eval(f, row.vals))) try kept.append(r.a, row);
            rows = kept.items;
        }
        var joins_since: u7 = 0;
        for (p.stages) |s| switch (s) {
            .where => |e| {
                var kept: std.ArrayListUnmanaged(RRow) = .empty;
                for (rows) |row| if (ev.truthy(try r.e.eval(e, row.vals))) try kept.append(r.a, row);
                rows = kept.items;
            },
            .derive => |ds| for (rows) |*row| {
                var w = row.vals.len;
                for (ds) |d| w = @max(w, d.target + 1);
                const grown = try r.a.alloc(Value, w);
                @memset(grown, .null_);
                @memcpy(grown[0..row.vals.len], row.vals);
                for (ds) |d| grown[d.target] = ev.coerce(try r.e.eval(d.expr, grown), d.expr.ty);
                row.vals = grown;
            },
            .select => |ss| for (rows) |*row| {
                const out = try r.a.alloc(Value, ss.len);
                for (ss, out) |d, *o| o.* = ev.coerce(try r.e.eval(d.expr, row.vals), d.expr.ty);
                row.vals = out;
            },
            .join => |j| {
                const right = try r.readAll(Tables.get(@constCast(r.t), j.right.name).?);
                const shift: u7 = 48 -| (16 * @as(u7, @min(joins_since, 3)));
                joins_since += 1;
                var out: std.ArrayListUnmanaged(RRow) = .empty;
                for (rows) |row| {
                    var sub: u128 = 0;
                    const key = row.vals[j.left_col];
                    if (key != .null_) for (right) |rr| {
                        const rk = rr.vals[j.right_col];
                        if (rk == .null_ or ev.order(key, rk) != .eq) continue;
                        try out.append(r.a, .{ .vals = try std.mem.concat(r.a, Value, &.{ row.vals, rr.vals }), .ord = row.ord + (sub << shift) });
                        sub += 1;
                    };
                    if (sub == 0 and j.left) {
                        const v = try r.a.alloc(Value, row.vals.len + j.right.schema.columns.len);
                        @memset(v, .null_);
                        @memcpy(v[0..row.vals.len], row.vals);
                        try out.append(r.a, .{ .vals = v, .ord = row.ord });
                    }
                }
                rows = out.items;
            },
            .group => |g| {
                rows = try r.group(rows, g.keys, g.aggs);
                renumber(rows);
                joins_since = 0;
            },
            .sort => |keys| {
                stableSort(rows, keys);
                renumber(rows);
                joins_since = 0;
            },
            .topk => |t| {
                stableSort(rows, t.keys);
                rows = rows[0..@min(rows.len, t.k)];
                renumber(rows);
                joins_since = 0;
            },
            .limit => |n| {
                rows = rows[0..@min(rows.len, n)];
                renumber(rows);
                joins_since = 0;
            },
            .sample => |n| {
                const Ranked = struct { rank: u64, row: RRow };
                const ranked = try r.a.alloc(Ranked, rows.len);
                for (rows, ranked) |row, *x| x.* = .{ .rank = sort.sampleRank(row.ord), .row = row };
                std.sort.insertion(Ranked, ranked, {}, struct {
                    fn lt(_: void, x: Ranked, y: Ranked) bool {
                        return x.rank < y.rank or (x.rank == y.rank and x.row.ord < y.row.ord);
                    }
                }.lt);
                const kept = ranked[0..@min(ranked.len, n)];
                std.sort.insertion(Ranked, kept, {}, struct {
                    fn lt(_: void, x: Ranked, y: Ranked) bool {
                        return x.row.ord < y.row.ord;
                    }
                }.lt);
                rows = try r.a.alloc(RRow, kept.len);
                for (kept, rows) |x, *o| o.* = x.row;
                renumber(rows);
                joins_since = 0;
            },
        };
        const out = try r.a.alloc([]Value, rows.len);
        const w = p.out_schema.columns.len;
        for (rows, out) |row, *o| {
            o.* = try r.a.alloc(Value, w);
            for (o.*, 0..) |*v, i| v.* = if (i < row.vals.len) row.vals[i] else .null_;
        }
        return out;
    }

    fn renumber(rows: []RRow) void {
        for (rows, 0..) |*row, i| row.ord = @as(u128, i) << 64;
    }

    fn stableSort(rows: []RRow, keys: []const plan.PlanKey) void {
        std.sort.insertion(RRow, rows, keys, struct {
            fn lt(ks: []const plan.PlanKey, x: RRow, y: RRow) bool {
                for (ks) |k| switch (sort.cmpKey(x.vals[k.col], y.vals[k.col], k.desc)) {
                    .lt => return true,
                    .gt => return false,
                    .eq => {},
                };
                return false;
            }
        }.lt);
    }

    fn group(r: *Reference, rows: []RRow, keys: []const u32, aggs: []const plan.AggSpec) ![]RRow {
        const G = struct { keys: []Value, members: std.ArrayListUnmanaged([]Value) = .empty };
        var groups: std.ArrayListUnmanaged(G) = .empty;
        for (rows) |row| {
            const ks = try r.a.alloc(Value, keys.len);
            for (keys, ks) |c, *k| k.* = row.vals[c];
            const g = for (groups.items) |*g| {
                const same = for (g.keys, ks) |x, y| {
                    if (!(ev.sameKey(x, y))) break false;
                } else true;
                if (same) break g;
            } else blk: {
                try groups.append(r.a, .{ .keys = ks });
                break :blk &groups.items[groups.items.len - 1];
            };
            try g.members.append(r.a, row.vals);
        }
        const out = try r.a.alloc(RRow, groups.items.len);
        for (groups.items, out) |g, *o| {
            const vals = try r.a.alloc(Value, keys.len + aggs.len);
            @memcpy(vals[0..keys.len], g.keys);
            for (aggs, vals[keys.len..]) |*spec, *v| v.* = ev.coerce(try r.aggregate(spec, g.members.items), spec.ty);
            o.* = .{ .vals = vals, .ord = 0 };
        }
        return out;
    }

    fn aggregate(r: *Reference, spec: *const plan.AggSpec, members: []const []Value) !Value {
        var xs: std.ArrayListUnmanaged(Value) = .empty;
        for (members) |m| {
            const v: Value = if (spec.arg) |e| try r.e.eval(e, m) else .{ .bool_ = true };
            if (v != .null_) try xs.append(r.a, v);
        }
        const vs = xs.items;
        switch (spec.func) {
            .count => return .{ .int = @intCast(vs.len) },
            .count_distinct => {
                var n: i64 = 0;
                for (vs, 0..) |v, i| {
                    const seen = for (vs[0..i]) |w| {
                        if (ev.sameKey(v, w)) break true;
                    } else false;
                    if (!seen) n += 1;
                }
                return .{ .int = n };
            },
            .sum, .avg => {
                if (vs.len == 0) return .null_;
                var isum: i128 = 0;
                var fsum: f64 = 0;
                var saw_float = false;
                for (vs) |v| switch (v) {
                    .int => |i| isum += i,
                    else => {
                        fsum += ev.num(v).?;
                        saw_float = true;
                    },
                };
                const total = @as(f64, @floatFromInt(isum)) + fsum;
                if (spec.func == .avg) return .{ .float = total / @as(f64, @floatFromInt(vs.len)) };
                if (spec.ty == .float or saw_float) return .{ .float = total };
                return .{ .int = @intCast(isum) };
            },
            .min, .max => {
                var best: Value = .null_;
                for (vs) |v| {
                    if (best == .null_) {
                        best = v;
                        continue;
                    }
                    const o = ev.order(v, best) orelse continue;
                    if ((spec.func == .min and o == .lt) or (spec.func == .max and o == .gt)) best = v;
                }
                return best;
            },
            .stddev => {
                if (vs.len < 2) return .null_;
                var mean: f64 = 0;
                for (vs) |v| mean += ev.num(v).?;
                mean /= @floatFromInt(vs.len);
                var ss: f64 = 0;
                for (vs) |v| ss += (ev.num(v).? - mean) * (ev.num(v).? - mean);
                return .{ .float = @sqrt(ss / @as(f64, @floatFromInt(vs.len - 1))) };
            },
            .median, .p => {
                if (vs.len == 0) return .null_;
                const fs = try r.a.alloc(f64, vs.len);
                for (vs, fs) |v, *f| f.* = ev.num(v).?;
                std.sort.insertion(f64, fs, {}, std.sort.asc(f64));
                const q = if (spec.func == .median) 0.5 else spec.q;
                const pos = q * @as(f64, @floatFromInt(fs.len - 1));
                const lo: usize = @intFromFloat(@floor(pos));
                const hi = @min(lo + 1, fs.len - 1);
                return .{ .float = fs[lo] + (fs[hi] - fs[lo]) * (pos - @floor(pos)) };
            },
        }
    }
};

// ---------------------------------------------------------------------
// Random data and queries

const words = [_][]const u8{ "alpha", "beta", "gamma", "delta", "Alpha", "beta two", "eps", "zeta" };
const groups_ = [_][]const u8{ "a", "b", "c", "d", "e" };

/// `facts`: g (string, 5 values), n (int, some null), x (float), d
/// (date), s (string, some null).
fn genFacts(a: std.mem.Allocator, rand: std.Random, rows: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "g,n,x,d,s\n");
    for (0..rows) |_| {
        const g = groups_[rand.uintLessThan(usize, groups_.len)];
        try out.print(a, "{s},", .{g});
        if (rand.uintLessThan(u8, 8) != 0) try out.print(a, "{d}", .{rand.intRangeAtMost(i64, -50, 200)});
        try out.print(a, ",{d}.{d:0>2},", .{ rand.intRangeAtMost(i64, -20, 100), rand.uintLessThan(u8, 100) });
        try out.print(a, "2025-{d:0>2}-{d:0>2},", .{ rand.intRangeAtMost(u8, 1, 12), rand.intRangeAtMost(u8, 1, 28) });
        if (rand.uintLessThan(u8, 6) != 0) try out.appendSlice(a, words[rand.uintLessThan(usize, words.len)]);
        try out.append(a, '\n');
    }
    return out.items;
}

/// `dims`: key (string; "a" twice, "e" missing, "f" unmatched), w (int).
const dims_csv =
    \\key,w
    \\a,1
    \\b,2
    \\a,3
    \\c,
    \\d,5
    \\f,6
    \\
;

/// Stages that keep facts' columns (g n x d s, maybe with y appended).
const keep_stages = [_][]const u8{
    "where n > 20",
    "where x < 40.5 and n is not null",
    "where g in [\"a\", \"c\"] or contains(s, \"eta\")",
    "where n between 0 and 100",
    "where not (g == \"b\")",
    "where d >= 2025-06-01",
    "where regex_match(s, \"^[ab]\")",
    "where coalesce(n, 0) % 3 == 1",
    "sort -n, s",
    "sort d, -x",
    "sort s",
    "limit 37",
    "sample 25",
    "sort -x | limit 15",
};

/// Stages that end a pipeline (may change the columns).
const end_stages = [_][]const u8{
    "",
    "group g { c = count(), t = sum(n), m = avg(x), lo = min(s), hi = max(d), k = count(n) }",
    "group g { cd = count_distinct(n), md = median(x), q = p(x, 0.9), sd = stddev(x), ts = sum(x) }",
    "derive y = n * 2 + 1, z = x / (n % 4) | group g { t = sum(y), z = max(z) }",
    "derive b = n > 50 | group g, b { c = count() } | sort g, b",
    "derive m = month(d) | group m { c = count(), s = sum(n) } | sort -c, m | limit 5",
    "select g, len = length(s), up = upper(s), yr = year(d), diff = date_diff(2025-01-01, d)",
    "select g, r = round(x), c = case when n > 100 then \"big\" when n > 0 then \"small\" else \"other\" end",
    "join dims on g == key | select g, n, w",
    "join dims on g == key left | group g { c = count(), w = sum(w) }",
    "join dims on g == key | join dims on g == key left | select g, n",
    "group s { c = count() } | sort -c, s",
    "sample 10 | select g, n",
};

test "exec_vs_reference" {
    var prng: std.Random.DefaultPrng = .init(0xE13F0602);
    const rand = prng.random();
    var total: usize = 0;
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const sizes = [_]usize{ 3, 40, 300, 2000 };
        const rows = sizes[round];
        const facts = try Dataset.openBytes(gpa, io, try genFacts(a, rand, rows), .csv);
        defer facts.close();
        const dims = try Dataset.openBytes(gpa, io, dims_csv, .csv);
        defer dims.close();
        try facts.waitIndexed();
        // A table that came out typed differently would turn these
        // queries into type errors rather than tests.
        try testing.expectEqualStrings("s", facts.columns[4]);
        try testing.expectEqual(infer.ColType.date, facts.types[3]);
        const t: Tables = .{ .names = &.{ "facts", "dims" }, .sets = &.{ facts, dims } };

        var q: usize = 0;
        while (q < 60) : (q += 1) {
            var src: std.ArrayList(u8) = .empty;
            try src.appendSlice(a, "from facts");
            const n_keep = rand.uintLessThan(usize, 3);
            for (0..n_keep) |_| try src.print(a, " | {s}", .{keep_stages[rand.uintLessThan(usize, keep_stages.len)]});
            const end = end_stages[rand.uintLessThan(usize, end_stages.len)];
            if (end.len > 0) try src.print(a, " | {s}", .{end});

            const p = try mustPlan(a, &t, src.items);
            var ref: Reference = .{ .a = a, .t = &t, .e = .init(gpa, a) };
            defer ref.e.deinit();
            const want = try ref.runPlan(&p);
            total += want.len;
            for ([_]RunOpts{
                .{ .threads = 1 },
                .{ .threads = 4, .morsel_rows = 7, .batch_rows = 3 },
                .{ .threads = 3, .morsel_rows = 64 },
            }) |o| {
                const got = try run(a, &t, &p, o);
                try expectSameRows(src.items, want, got.rows);
                try testing.expect(!got.stats.truncated);
            }
        }
    }
    // The random queries return rows (not all filtered away).
    try testing.expect(total > 5000);
}

test "exec_known_answers" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const doc =
        \\id,name,v,day
        \\1,Oslo,10,2025-03-01
        \\2,lima,,2025-01-15
        \\3,Quito,0,2024-12-31
        \\4,,7,
        \\
    ;
    const ds = try Dataset.openBytes(gpa, io, doc, .csv);
    defer ds.close();
    const t: Tables = .{ .names = &.{"t"}, .sets = &.{ds} };
    const cases = [_]struct { []const u8, []const u8 }{
        // Division by zero, nulls in arithmetic.
        .{ "from t | select q = 100 / v", "10|null|null|14.285714285714286" },
        // Nulls sort last in either direction; ties keep input order.
        .{ "from t | sort -v | select id", "1|4|3|2" },
        .{ "from t | sort v | select id", "3|4|1|2" },
        // date_diff(a, b) is b - a in days.
        .{ "from t | select dd = date_diff(2025-01-01, day)", "59|14|-1|null" },
        .{ "from t | where regex_match(name, \"^[A-Z]\") | select id", "1|3" },
        .{ "from t | where v > 5 or v is null | select id", "1|2|4" },
        .{ "from t | select y = year(day), m = trunc(day, \"month\")", "2025,2025-03-01|2025,2025-01-01|2024,2024-12-01|null,null" },
        .{ "from t | group { c = count(), n = count(v), s = sum(v), a = avg(v) }", "4,3,17,5.666666666666667" },
        .{ "from t | select l = lower(name), c = coalesce(name, \"?\")", "oslo,Oslo|lima,lima|quito,Quito|null,?" },
        .{ "from t | limit 2 | select id", "1|2" },
        .{ "from t | where id in [2, 4, null] | select id", "2|4" },
    };
    for (cases) |c| {
        const p = try mustPlan(a, &t, c[0]);
        for ([_]RunOpts{ .{ .threads = 1 }, .{ .threads = 2, .morsel_rows = 1 } }) |o| {
            const got = try run(a, &t, &p, o);
            var text: std.ArrayList(u8) = .empty;
            for (got.rows, 0..) |row, i| {
                if (i > 0) try text.append(a, '|');
                for (row, 0..) |v, j| {
                    if (j > 0) try text.append(a, ',');
                    try formatValue(a, &text, v);
                }
            }
            testing.expectEqualStrings(c[1], text.items) catch |e| {
                std.debug.print("query: {s}\n", .{c[0]});
                return e;
            };
        }
    }
}

fn formatValue(a: std.mem.Allocator, out: *std.ArrayList(u8), v: Value) !void {
    switch (v) {
        .null_ => try out.appendSlice(a, "null"),
        .bool_ => |b| try out.print(a, "{}", .{b}),
        .int => |i| try out.print(a, "{d}", .{i}),
        .float => |f| try out.print(a, "{d}", .{f}),
        .string => |s| try out.appendSlice(a, s),
        .date => |d| {
            const c = infer.civilFromDays(d);
            try out.print(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(c.y)), c.m, c.d });
        },
        .datetime => |d| try out.print(a, "t{d}", .{d}),
    }
}

/// A CSV of `rows` rows: k (0..groups), v (int), f (float).
fn genWide(a: std.mem.Allocator, rows: usize, groups: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, rows * 20);
    try out.appendSlice(a, "k,v,f\n");
    var h: u64 = 1;
    for (0..rows) |i| {
        h = h *% 6364136223846793005 +% 1442695040888963407;
        try out.print(a, "k{d},{d},{d}.{d}\n", .{ (h >> 33) % groups, (h >> 20) % 1000, i % 977, (h >> 40) % 10 });
    }
    return out.items;
}

test "group_merge_parallel_equals_serial" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ds = try Dataset.openBytes(gpa, io, try genWide(a, 200_000, 997), .csv);
    defer ds.close();
    const t: Tables = .{ .names = &.{"w"}, .sets = &.{ds} };
    const src = "from w | group k { c = count(), s = sum(v), m = avg(f), lo = min(v), hi = max(f), d = count_distinct(v), md = median(f), sd = stddev(f) }";
    const p = try mustPlan(a, &t, src);
    const serial = try run(a, &t, &p, .{ .threads = 1, .morsel_rows = 1 << 30 });
    const parallel = try run(a, &t, &p, .{ .threads = 8, .morsel_rows = 1000 });
    try testing.expectEqual(@as(usize, 997), serial.rows.len);
    try testing.expect(parallel.stats.morsels >= 200);
    try testing.expect(!parallel.stats.approximate);
    try expectSameRows(src, serial.rows, parallel.rows);
}

test "topk_equals_full_sort_prefix" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ds = try Dataset.openBytes(gpa, io, try genWide(a, 50_000, 50), .csv);
    defer ds.close();
    const t: Tables = .{ .names = &.{"w"}, .sets = &.{ds} };
    const full = try mustPlan(a, &t, "from w | sort -v, k");
    const top = try mustPlan(a, &t, "from w | sort -v, k | limit 25");
    try testing.expect(top.stages[0] == .topk);
    const all = try run(a, &t, &full, .{ .threads = 4, .morsel_rows = 4096 });
    for ([_]RunOpts{ .{ .threads = 1 }, .{ .threads = 6, .morsel_rows = 999 } }) |o| {
        const got = try run(a, &t, &top, o);
        try expectSameRows("topk", all.rows[0..25], got.rows);
    }
}

test "join_left_inner" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const orders = try Dataset.openBytes(gpa, io,
        \\id,cust
        \\1,a
        \\2,b
        \\3,z
        \\4,
        \\5,a
        \\
    , .csv);
    defer orders.close();
    const custs = try Dataset.openBytes(gpa, io,
        \\cid,name
        \\a,Ann
        \\b,Bo
        \\a,Ann again
        \\,nobody
        \\
    , .csv);
    defer custs.close();
    const t: Tables = .{ .names = &.{ "orders", "custs" }, .sets = &.{ orders, custs } };
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "from orders | join custs on cust == cid | select id, name", "1,Ann|1,Ann again|2,Bo|5,Ann|5,Ann again" },
        .{ "from orders | join custs on cust == cid left | select id, name", "1,Ann|1,Ann again|2,Bo|3,null|4,null|5,Ann|5,Ann again" },
        .{ "from orders | join custs on cust == cid left | group cust { c = count(name) }", "a,4|b,1|z,0|null,0" },
    };
    for (cases) |c| {
        const p = try mustPlan(a, &t, c[0]);
        for ([_]RunOpts{ .{ .threads = 1 }, .{ .threads = 3, .morsel_rows = 2 } }) |o| {
            const got = try run(a, &t, &p, o);
            var text: std.ArrayList(u8) = .empty;
            for (got.rows, 0..) |row, i| {
                if (i > 0) try text.append(a, '|');
                for (row, 0..) |v, j| {
                    if (j > 0) try text.append(a, ',');
                    try formatValue(a, &text, v);
                }
            }
            testing.expectEqualStrings(c[1], text.items) catch |e| {
                std.debug.print("query: {s}\n", .{c[0]});
                return e;
            };
        }
    }
}

test "mem_guard_triggers" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ds = try Dataset.openBytes(gpa, io, try genWide(a, 20_000, 20_000), .csv);
    defer ds.close();
    const t: Tables = .{ .names = &.{"w"}, .sets = &.{ds} };
    for ([_][]const u8{
        "from w | sort v",
        "from w | group k, v { c = count() }",
        "from w | group k { m = median(f) }",
    }) |src| {
        const p = try mustPlan(a, &t, src);
        try testing.expectError(error.QueryTooLarge, run(a, &t, &p, .{ .threads = 2, .morsel_rows = 1000, .max_mem = 64 << 10 }));
        // The same query fits a normal budget.
        _ = try run(a, &t, &p, .{ .threads = 2, .morsel_rows = 1000 });
    }
    // A join table is charged too.
    const t2: Tables = .{ .names = &.{ "w", "w2" }, .sets = &.{ ds, ds } };
    const jp = try mustPlan(a, &t2, "from w | join w2 on k == k | limit 1");
    try testing.expectError(error.QueryTooLarge, run(a, &t2, &jp, .{ .max_mem = 64 << 10 }));
}

test "max_rows_out_truncates" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ds = try Dataset.openBytes(gpa, io, try genWide(a, 1000, 10), .csv);
    defer ds.close();
    const t: Tables = .{ .names = &.{"w"}, .sets = &.{ds} };
    const p = try mustPlan(a, &t, "from w | select v");
    var c: Collect = .{ .a = a };
    const cancel: std.atomic.Value(bool) = .init(false);
    const stats = try exec.execute(io, gpa, &p, t.datasets(), c.sink(), .{ .cancel = &cancel, .max_rows_out = 100, .batch_rows = 30 });
    try testing.expect(stats.truncated);
    try testing.expectEqual(@as(u64, 1000), stats.total_rows);
    try testing.expectEqual(@as(usize, 100), c.rows.items.len);
    try testing.expectEqual(@as(u32, 4), c.batches);
    try testing.expectEqual(@as(u64, 1000), stats.rows_scanned);
}

test "cancel_within_50ms" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ds = try Dataset.openBytes(gpa, io, try genWide(a, 3_000_000, 1000), .csv);
    defer ds.close();
    try ds.waitIndexed();
    const t: Tables = .{ .names = &.{"w"}, .sets = &.{ds} };
    const p = try mustPlan(a, &t, "from w | where regex_match(k, \"7$\") | group k { m = median(f), d = count_distinct(v) }");

    const Run = struct {
        t: *const Tables,
        p: *const query.Plan,
        cancel: std.atomic.Value(bool) = .init(false),
        result: ?anyerror = null,
        done_at: std.atomic.Value(i64) = .init(0),

        fn go(r: *@This()) void {
            var c: Collect = .{ .a = std.heap.page_allocator };
            _ = exec.execute(io, gpa, r.p, r.t.datasets(), c.sink(), .{ .cancel = &r.cancel, .threads = 2, .morsel_rows = 1 << 20 }) catch |e| {
                r.result = e;
            };
            r.done_at.store(nowNs(), .release);
        }
    };
    var r: Run = .{ .t = &t, .p = &p };
    const th = try std.Thread.spawn(.{}, Run.go, .{&r});
    try io.sleep(.fromMilliseconds(30), .awake);
    const canceled_at = nowNs();
    r.cancel.store(true, .release);
    th.join();
    try testing.expectEqual(@as(?anyerror, error.Canceled), r.result);
    const took_ms = @divTrunc(r.done_at.load(.acquire) - canceled_at, std.time.ns_per_ms);
    try testing.expect(took_ms < 50);
}

fn nowNs() i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

test "fuzz_exec_never_crashes" {
    // Random queries over the same table: planning may reject them, but
    // execution of a plan never fails other than by its guards.
    const dims = try Dataset.openBytes(gpa, io, dims_csv, .csv);
    defer dims.close();
    try testing.fuzz(dims, struct {
        fn one(ds: *Dataset, s: *testing.Smith) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            var buf: [96]u8 = undefined;
            const tail = buf[0..s.slice(&buf)];
            const src = try std.fmt.allocPrint(a, "from dims | {s}", .{tail});
            const t: Tables = .{ .names = &.{"dims"}, .sets = &.{ds} };
            var diag: query.Diagnostic = .{};
            const tree = query.parse(a, src, &diag) catch return;
            const p = plan.plan(a, &tree, t.catalog(), &diag) catch return;
            _ = run(a, &t, &p, .{ .threads = 2, .morsel_rows = 2 }) catch |e| switch (e) {
                error.QueryTooLarge, error.JoinTooLarge => {},
                else => return e,
            };
        }
    }.one, .{ .corpus = &.{
        "where w > 1 | sort -w",
        "group key { c = count(), m = median(w) }",
        "derive z = w / 0 | sample 3",
        "join dims on key == key left | limit 4",
    } });
}
