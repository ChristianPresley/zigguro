//! Query execution (E13.F06.S02.T03): runs a T01 `Plan` over F06
//! datasets.
//!
//! The source's rows split into morsels of 64 k rows that workers take
//! in turn. A worker reads only the needed columns, and the pushed-down
//! filter's columns first: a row the filter drops never has its other
//! fields parsed. Rows then flow through the streaming stages (`where`,
//! `derive`, `select`, `join`) into the first blocking stage's per-worker
//! state:
//! * `group`: a hash table per worker, merged at the end;
//! * `sort`: the rows, sorted once merged;
//! * `topk` (`sort … | limit k`): a bounded top-k per worker;
//! * `limit`: the first rows of each morsel;
//! * `sample`: the rows whose order hashes lowest.
//! Whatever follows runs in memory on the merged rows. Every result is
//! deterministic: rows keep their source order (ties too), and groups
//! come out in the order of their first row.
//!
//! A memory guard (`max_mem`) stops a query whose kept rows, groups or
//! join table would grow past it (`error.QueryTooLarge`; there is no
//! spilling to disk). `cancel` is checked every 1024 rows.
//! Semantics are documented in docs/formats/data-query.md ("Execution").

const std = @import("std");
const plan_mod = @import("plan.zig");
const types = @import("types.zig");
const ev = @import("expr_eval.zig");
const agg = @import("agg.zig");
const sort = @import("sort.zig");
const join_mod = @import("join.zig");
const infer = @import("../infer.zig");
const csv = @import("../csv.zig");
const encoding = @import("../encoding.zig");
const dataset = @import("../dataset.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Plan = plan_mod.Plan;
const Stage = plan_mod.Stage;
const TypedExpr = plan_mod.TypedExpr;
const Dataset = dataset.Dataset;
const Row = sort.Row;

pub const Value = ev.Value;

pub const ColumnVec = struct {
    name: []const u8,
    ty: types.Type,
    values: []const Value,
};

/// Receives the result in batches (on the thread that called `execute`).
/// The columns live until `batch` returns.
pub const ResultSink = struct {
    ctx: *anyopaque,
    batch: *const fn (ctx: *anyopaque, cols: []const ColumnVec, n: u32) anyerror!void,
};

pub const ExecOpts = struct {
    max_rows_out: u64 = 1_000_000,
    max_mem: usize = 1 << 30,
    cancel: *const std.atomic.Value(bool),
    /// 0: one per CPU (at most 32).
    threads: u16 = 0,
    morsel_rows: u32 = 64 << 10,
    batch_rows: u32 = 4096,
};

pub const ExecStats = struct {
    rows_scanned: u64 = 0,
    /// Result rows before `max_rows_out`.
    total_rows: u64 = 0,
    rows_out: u64 = 0,
    truncated: bool = false,
    /// A sketch answered (count_distinct past 1 M values, quantiles past
    /// 1 M per group).
    approximate: bool = false,
    morsels: u32 = 0,
    threads: u16 = 0,
    mem_used: usize = 0,
};

/// Dataset name → open dataset (the source and joined datasets).
pub const Datasets = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, name: []const u8) ?*Dataset,
};

pub const Error = error{ QueryTooLarge, JoinTooLarge, Canceled, UnknownDataset };

const Blocking = enum { none, group, sort, topk, limit, sample };

fn blockingOf(s: Stage) ?Blocking {
    return switch (s) {
        .group => .group,
        .sort => .sort,
        .topk => .topk,
        .limit => .limit,
        .sample => .sample,
        .where, .derive, .select, .join => null,
    };
}

/// A dataset's rows as typed values.
const Source = struct {
    ds: *Dataset,
    types: []const infer.ColType,
    ictx: infer.InferCtx,
    rows: u64,

    fn init(ds: *Dataset) !Source {
        try ds.waitIndexed();
        const n: u64 = switch (ds.rowCount()) {
            inline else => |x| x,
        };
        return .{ .ds = ds, .types = ds.types, .ictx = ds.inferCtx(), .rows = n };
    }

    fn ty(s: *const Source, c: u32) infer.ColType {
        return if (c < s.types.len) s.types[c] else .string;
    }
};

/// Reads consecutive rows of a source.
const Cursor = struct {
    src: *const Source,
    rd: csv.CsvReader = undefined,
    fields: std.ArrayListUnmanaged(csv.Field) = .empty,
    row: u64,
    a: Allocator,

    fn init(src: *const Source, lo: u64, a: Allocator) Cursor {
        var c: Cursor = .{ .src = src, .row = lo, .a = a };
        if (src.ds.json == null) {
            const ix = src.ds.index();
            c.rd = .initAt(src.ds.bytes, src.ds.dialect, ix.offset(lo + src.ds.headerRows()));
        }
        return c;
    }

    /// Moves to the next row; false at the end.
    fn next(c: *Cursor) !bool {
        if (c.src.ds.json != null) return true;
        return (try c.rd.nextRecord(&c.fields, c.a)) != null;
    }

    fn done(c: *Cursor) void {
        c.row += 1;
    }

    fn cell(c: *Cursor, col: u32) !Value {
        if (c.src.ds.json) |t| {
            if (try t.isNull(c.row, col, c.a)) return .null_;
            return ev.parseCell(try t.cell(c.row, col, c.a), false, c.src.ty(col), c.src.ictx);
        }
        if (col >= c.fields.items.len) return .null_;
        const f = c.fields.items[col];
        var text = try c.rd.fieldText(f, c.a);
        if (c.src.ds.encoding == .latin1) text = try encoding.latin1ToUtf8(c.a, text);
        return ev.parseCell(text, c.rd.isNull(f), c.src.ty(col), c.src.ictx);
    }
};

const Prepared = struct {
    p: *const Plan,
    src: Source,
    stages: []const Stage,
    /// The first blocking stage (`stages.len` when none).
    first_block: usize,
    kind: Blocking,
    /// widths[i]: row width entering stage i (widths[stages.len]: out).
    widths: []usize,
    joins: []?*join_mod.JoinTable,
    filter_cols: []const u32,
    rest_cols: []const u32,
};

fn exprCols(e: *const TypedExpr, out: *std.ArrayListUnmanaged(u32), a: Allocator) !void {
    switch (e.node) {
        .lit => {},
        .col => |c| for (out.items) |x| {
            if (x == c) break;
        } else try out.append(a, c),
        .unary => |u| try exprCols(u.e, out, a),
        .binary => |b| {
            try exprCols(b.l, out, a);
            try exprCols(b.r, out, a);
        },
        .in_list => |x| {
            try exprCols(x.e, out, a);
            for (x.list) |i| try exprCols(i, out, a);
        },
        .between => |x| {
            try exprCols(x.e, out, a);
            try exprCols(x.lo, out, a);
            try exprCols(x.hi, out, a);
        },
        .is_null => |x| try exprCols(x.e, out, a),
        .call => |c| for (c.args) |x| try exprCols(x, out, a),
        .case => |c| {
            for (c.whens) |w| {
                try exprCols(w.cond, out, a);
                try exprCols(w.then, out, a);
            }
            if (c.else_) |x| try exprCols(x, out, a);
        },
    }
}

const Shared = struct {
    gpa: Allocator,
    io: Io,
    prep: *const Prepared,
    opts: ExecOpts,
    budget: agg.Budget,
    next: std.atomic.Value(u32) = .init(0),
    n_morsels: u32,
    failed: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    err: ?anyerror = null,

    fn fail(sh: *Shared, e: anyerror) void {
        sh.mutex.lockUncancelable(sh.io);
        defer sh.mutex.unlock(sh.io);
        if (sh.err == null) sh.err = e;
        sh.failed.store(true, .release);
    }

    fn canceled(sh: *const Shared) bool {
        return sh.opts.cancel.load(.acquire) or sh.failed.load(.acquire);
    }
};

const MorselOut = struct { index: u32, rows: []Row };

/// One thread's state; also runs the in-memory stages after the merge.
const Worker = struct {
    sh: *Shared,
    /// Rows, groups and sketches that outlive a morsel.
    keep: std.heap.ArenaAllocator,
    /// Reset per morsel.
    scratch: std.heap.ArenaAllocator,
    eval: ev.Eval = undefined,
    groups: ?agg.GroupTable = null,
    collected: std.ArrayListUnmanaged(Row) = .empty,
    topk: ?sort.TopK = null,
    sample: ?sort.Sample = null,
    cur: std.ArrayListUnmanaged(Row) = .empty,
    morsels: std.ArrayListUnmanaged(MorselOut) = .empty,
    rows_scanned: u64 = 0,
    approx: bool = false,

    fn init(w: *Worker, sh: *Shared) void {
        w.* = .{ .sh = sh, .keep = .init(sh.gpa), .scratch = .init(sh.gpa) };
        w.eval = .init(sh.gpa, w.scratch.allocator());
        const prep = sh.prep;
        if (prep.first_block < prep.stages.len) switch (prep.stages[prep.first_block]) {
            .group => |g| w.groups = .init(w.keep.allocator(), g.keys.len, g.aggs, &sh.budget),
            .topk => |t| w.topk = .{ .arena = w.keep.allocator(), .keys = t.keys, .k = t.k, .budget = &sh.budget },
            .sample => |n| w.sample = .{ .arena = w.keep.allocator(), .n = n, .budget = &sh.budget },
            else => {},
        };
    }

    fn deinit(w: *Worker) void {
        w.eval.deinit();
        w.scratch.deinit();
        w.keep.deinit();
    }

    fn main(w: *Worker) void {
        w.run() catch |e| w.sh.fail(e);
    }

    fn run(w: *Worker) !void {
        const sh = w.sh;
        const n = sh.prep.src.rows;
        const per: u64 = sh.opts.morsel_rows;
        while (true) {
            if (sh.opts.cancel.load(.acquire)) return error.Canceled;
            if (sh.failed.load(.acquire)) return;
            const m = sh.next.fetchAdd(1, .monotonic);
            if (m >= sh.n_morsels) return;
            _ = w.scratch.reset(.retain_capacity);
            const lo = @as(u64, m) * per;
            try w.scanMorsel(m, lo, @min(lo + per, n));
        }
    }

    fn scanMorsel(w: *Worker, m: u32, lo: u64, hi: u64) !void {
        const prep = w.sh.prep;
        const a = w.scratch.allocator();
        var cur: Cursor = .init(&prep.src, lo, a);
        const base = try a.alloc(Value, prep.widths[0]);
        while (cur.row < hi) : (cur.done()) {
            if ((cur.row - lo) % 1024 == 0 and w.sh.canceled()) {
                if (w.sh.opts.cancel.load(.acquire)) return error.Canceled;
                return;
            }
            if (!try cur.next()) break;
            w.rows_scanned += 1;
            @memset(base, .null_);
            for (prep.filter_cols) |c| base[c] = try cur.cell(c);
            if (prep.p.filter) |f| if (!ev.truthy(try w.eval.eval(f, base))) continue;
            for (prep.rest_cols) |c| base[c] = try cur.cell(c);
            try w.process(0, base, @as(u128, cur.row) << 64);
        }
        if (w.cur.items.len > 0 or prep.kind == .none or prep.kind == .limit) {
            try w.morsels.append(w.keep.allocator(), .{ .index = m, .rows = w.cur.items });
            w.cur = .empty;
        }
    }

    const MatchCtx = struct { w: *Worker, k: usize, cur: []const Value, ord: u128 };

    fn onMatch(c: *const MatchCtx, right: []const Value, sub: u32) anyerror!void {
        if (sub >= 1 << 16) return error.JoinTooLarge;
        const combined = try c.w.scratch.allocator().alloc(Value, c.cur.len + right.len);
        @memcpy(combined[0..c.cur.len], c.cur);
        @memcpy(combined[c.cur.len..], right);
        try c.w.process(c.k + 1, combined, c.ord + subOrd(c.w.sh.prep, c.k, sub));
    }

    /// Runs streaming stages `k..first_block` on one row, then hands it
    /// to the blocking stage.
    fn process(w: *Worker, k0: usize, vals: []Value, ord: u128) anyerror!void {
        const prep = w.sh.prep;
        const a = w.scratch.allocator();
        var cur = vals;
        var k = k0;
        while (k < prep.first_block) : (k += 1) switch (prep.stages[k]) {
            .where => |e| if (!ev.truthy(try w.eval.eval(e, cur))) return,
            .derive => |ds| {
                const wn = prep.widths[k + 1];
                if (wn > cur.len) {
                    const grown = try a.alloc(Value, wn);
                    @memcpy(grown[0..cur.len], cur);
                    @memset(grown[cur.len..], .null_);
                    cur = grown;
                }
                for (ds) |d| cur[d.target] = ev.coerce(try w.eval.eval(d.expr, cur), d.expr.ty);
            },
            .select => |ss| {
                const out = try a.alloc(Value, ss.len);
                for (ss, out) |d, *o| o.* = ev.coerce(try w.eval.eval(d.expr, cur), d.expr.ty);
                cur = out;
            },
            .join => |j| {
                const ctx: MatchCtx = .{ .w = w, .k = k, .cur = cur, .ord = ord };
                const n = try prep.joins[k].?.probe(cur[j.left_col], &ctx, onMatch);
                if (n == 0 and j.left) {
                    const combined = try a.alloc(Value, prep.widths[k + 1]);
                    @memcpy(combined[0..cur.len], cur);
                    @memset(combined[cur.len..], .null_);
                    try w.process(k + 1, combined, ord);
                }
                return;
            },
            else => unreachable,
        };
        try w.consume(cur, ord);
    }

    fn consume(w: *Worker, vals: []const Value, ord: u128) !void {
        const prep = w.sh.prep;
        switch (prep.kind) {
            .none, .limit => {
                if (prep.kind == .limit and w.cur.items.len >= prep.stages[prep.first_block].limit) return;
                try w.cur.append(w.keep.allocator(), .{ .vals = try sort.dupeRow(w.keep.allocator(), vals, &w.sh.budget), .ord = ord });
            },
            .group => try addToGroups(&w.groups.?, &w.eval, prep.stages[prep.first_block].group, vals, ord, w.scratch.allocator()),
            .sort => try w.collected.append(w.keep.allocator(), .{ .vals = try sort.dupeRow(w.keep.allocator(), vals, &w.sh.budget), .ord = ord }),
            .topk => try w.topk.?.add(vals, ord),
            .sample => try w.sample.?.add(vals, ord),
        }
    }
};

/// The order offset of match `sub` at join stage `k`: each join before
/// the next reorder gets 16 bits below the row's.
fn subOrd(prep: *const Prepared, k: usize, sub: u32) u128 {
    var depth: u7 = 0;
    var i = k;
    while (i > 0) {
        i -= 1;
        switch (prep.stages[i]) {
            .join => depth += 1,
            .group, .sort, .topk, .limit, .sample => break,
            else => {},
        }
    }
    const shift: u7 = 48 -| (16 * @as(u7, @min(depth, 3)));
    return @as(u128, sub) << shift;
}

fn addToGroups(t: *agg.GroupTable, e: *ev.Eval, g: anytype, vals: []const Value, ord: u128, scratch: Allocator) !void {
    const keys = try scratch.alloc(Value, g.keys.len);
    for (g.keys, keys) |c, *k| k.* = vals[c];
    const args = try scratch.alloc(Value, g.aggs.len);
    for (g.aggs, args) |spec, *x| x.* = if (spec.arg) |arg| try e.eval(arg, vals) else .{ .bool_ = true };
    try t.add(keys, args, ord);
}

/// Runs `p` over `datasets`, sending the result to `sink`.
pub fn execute(io: Io, gpa: Allocator, p: *const Plan, datasets: Datasets, sink: ResultSink, opts: ExecOpts) !ExecStats {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ds = datasets.get(datasets.ctx, p.source.name) orelse return error.UnknownDataset;

    var prep: Prepared = .{
        .p = p,
        .src = try Source.init(ds),
        .stages = p.stages,
        .first_block = p.stages.len,
        .kind = .none,
        .widths = try a.alloc(usize, p.stages.len + 1),
        .joins = try a.alloc(?*join_mod.JoinTable, p.stages.len),
        .filter_cols = &.{},
        .rest_cols = &.{},
    };
    for (p.stages, 0..) |s, i| if (blockingOf(s)) |b| {
        prep.first_block = i;
        prep.kind = b;
        break;
    };
    var w: usize = p.source.schema.columns.len;
    for (p.stages, 0..) |s, i| {
        prep.widths[i] = w;
        prep.joins[i] = null;
        switch (s) {
            .derive => |ds_| for (ds_) |d| {
                w = @max(w, d.target + 1);
            },
            .select => |ss| w = ss.len,
            .group => |g| w = g.keys.len + g.aggs.len,
            .join => |j| w += j.right.schema.columns.len,
            else => {},
        }
    }
    prep.widths[p.stages.len] = w;

    var filter_cols: std.ArrayListUnmanaged(u32) = .empty;
    if (p.filter) |f| try exprCols(f, &filter_cols, a);
    var rest: std.ArrayListUnmanaged(u32) = .empty;
    for (p.needed_columns) |c| if (std.mem.indexOfScalar(u32, filter_cols.items, c) == null) try rest.append(a, c);
    prep.filter_cols = filter_cols.items;
    prep.rest_cols = rest.items;

    var sh: Shared = .{ .gpa = gpa, .io = io, .prep = &prep, .opts = opts, .budget = .{ .max = opts.max_mem }, .n_morsels = 0 };

    // Joined datasets go in hash tables first.
    var join_arenas: std.ArrayListUnmanaged(*std.heap.ArenaAllocator) = .empty;
    defer for (join_arenas.items) |ja| {
        ja.deinit();
        gpa.destroy(ja);
    };
    for (p.stages, 0..) |s, i| if (s == .join) {
        const ja = try gpa.create(std.heap.ArenaAllocator);
        ja.* = .init(gpa);
        try join_arenas.append(a, ja);
        prep.joins[i] = try buildJoin(ja.allocator(), &sh, datasets, s.join);
    };

    const per: u64 = opts.morsel_rows;
    sh.n_morsels = @intCast((prep.src.rows + per - 1) / per);
    const cpus: usize = std.Thread.getCpuCount() catch 1;
    const want: usize = if (opts.threads > 0) opts.threads else @min(cpus, 32);
    const n_threads: usize = @max(1, @min(want, sh.n_morsels));

    const workers = try a.alloc(Worker, n_threads);
    for (workers) |*wk| wk.init(&sh);
    defer for (workers) |*wk| wk.deinit();
    if (n_threads == 1) {
        workers[0].main();
    } else {
        var group: Io.Group = .init;
        for (workers) |*wk| group.async(io, Worker.main, .{wk});
        try group.await(io);
    }
    if (opts.cancel.load(.acquire)) return error.Canceled;
    if (sh.err) |e| return e;

    var stats: ExecStats = .{ .morsels = sh.n_morsels, .threads = @intCast(n_threads) };
    for (workers) |*wk| stats.rows_scanned += wk.rows_scanned;

    // Merge the workers' states into one row list.
    const main = &workers[0];
    var rows: []Row = &.{};
    var start = prep.first_block;
    switch (prep.kind) {
        .none, .limit => {
            var outs: std.ArrayListUnmanaged(MorselOut) = .empty;
            for (workers) |*wk| try outs.appendSlice(a, wk.morsels.items);
            std.sort.pdq(MorselOut, outs.items, {}, struct {
                fn lt(_: void, x: MorselOut, y: MorselOut) bool {
                    return x.index < y.index;
                }
            }.lt);
            var all: std.ArrayListUnmanaged(Row) = .empty;
            for (outs.items) |o| try all.appendSlice(a, o.rows);
            rows = all.items;
            if (prep.kind == .limit) {
                rows = rows[0..@min(rows.len, prep.stages[start].limit)];
                start += 1;
            }
        },
        .group => {
            for (workers[1..]) |*wk| try main.groups.?.merge(&wk.groups.?);
            const outs = try main.groups.?.finish(main.keep.allocator(), &stats.approximate);
            rows = try a.alloc(Row, outs.len);
            for (outs, rows) |o, *r| r.* = .{ .vals = o.values, .ord = o.first };
            start += 1;
        },
        .sort => {
            var all: std.ArrayListUnmanaged(Row) = .empty;
            for (workers) |*wk| try all.appendSlice(a, wk.collected.items);
            rows = all.items;
            sort.sortRows(rows, prep.stages[start].sort);
            start += 1;
        },
        .topk => {
            for (workers[1..]) |*wk| try main.topk.?.merge(&wk.topk.?);
            rows = main.topk.?.finish();
            start += 1;
        },
        .sample => {
            for (workers[1..]) |*wk| try main.sample.?.merge(&wk.sample.?);
            rows = try main.sample.?.finish(a);
            start += 1;
        },
    }
    if (prep.kind != .none) reorder(rows);

    // The rest runs in memory.
    main.eval.arena = main.keep.allocator();
    rows = try runRest(main, &prep, rows, start, &stats.approximate);

    stats.total_rows = rows.len;
    stats.rows_out = @min(rows.len, opts.max_rows_out);
    stats.truncated = stats.rows_out < rows.len;
    stats.mem_used = sh.budget.used.load(.monotonic);
    try emit(gpa, p, rows[0..@intCast(stats.rows_out)], sink, opts.batch_rows);
    return stats;
}

/// After a reordering stage, a row's order is its position.
fn reorder(rows: []Row) void {
    for (rows, 0..) |*r, i| r.ord = @as(u128, i) << 64;
}

fn buildJoin(ja: Allocator, sh: *Shared, datasets: Datasets, j: anytype) !*join_mod.JoinTable {
    const rds = datasets.get(datasets.ctx, j.right.name) orelse return error.UnknownDataset;
    const src: Source = try .init(rds);
    const t = try ja.create(join_mod.JoinTable);
    const width = j.right.schema.columns.len;
    t.* = .init(ja, j.right_col, width);
    var scratch: std.heap.ArenaAllocator = .init(sh.gpa);
    defer scratch.deinit();
    var cur: Cursor = .init(&src, 0, scratch.allocator());
    while (cur.row < src.rows) : (cur.done()) {
        if (cur.row % 1024 == 0) {
            if (sh.opts.cancel.load(.acquire)) return error.Canceled;
            _ = scratch.reset(.retain_capacity);
            cur.a = scratch.allocator();
        }
        if (!try cur.next()) break;
        const row = try ja.alloc(Value, width);
        var bytes: usize = 0;
        for (row, 0..) |*v, c| {
            v.* = try agg.dupeValue(ja, try cur.cell(@intCast(c)));
            bytes += agg.valueBytes(v.*);
        }
        try sh.budget.charge(bytes);
        try t.add(row);
    }
    return t;
}

/// Runs stages `start..` over materialized rows.
fn runRest(w: *Worker, prep: *const Prepared, rows_in: []Row, start: usize, approx: *bool) ![]Row {
    const a = w.keep.allocator();
    const sh = w.sh;
    var rows = rows_in;
    var k = start;
    while (k < prep.stages.len) : (k += 1) {
        if (sh.opts.cancel.load(.acquire)) return error.Canceled;
        switch (prep.stages[k]) {
            .where => |e| {
                var n: usize = 0;
                for (rows) |r| {
                    if (ev.truthy(try w.eval.eval(e, r.vals))) {
                        rows[n] = r;
                        n += 1;
                    }
                }
                rows = rows[0..n];
            },
            .derive => |ds| for (rows) |*r| {
                const wn = prep.widths[k + 1];
                if (wn > r.vals.len) {
                    const grown = try a.alloc(Value, wn);
                    @memcpy(grown[0..r.vals.len], r.vals);
                    @memset(grown[r.vals.len..], .null_);
                    r.vals = grown;
                }
                for (ds) |d| r.vals[d.target] = ev.coerce(try w.eval.eval(d.expr, r.vals), d.expr.ty);
            },
            .select => |ss| for (rows) |*r| {
                const out = try a.alloc(Value, ss.len);
                for (ss, out) |d, *o| o.* = ev.coerce(try w.eval.eval(d.expr, r.vals), d.expr.ty);
                r.vals = out;
            },
            .join => |j| {
                var out: std.ArrayListUnmanaged(Row) = .empty;
                const Ctx = struct {
                    out: *std.ArrayListUnmanaged(Row),
                    a: Allocator,
                    left: []const Value,
                    ord: u128,
                    prep: *const Prepared,
                    k: usize,
                    fn add(c: *const @This(), right: []const Value, sub: u32) anyerror!void {
                        if (sub >= 1 << 16) return error.JoinTooLarge;
                        const v = try c.a.alloc(Value, c.left.len + right.len);
                        @memcpy(v[0..c.left.len], c.left);
                        @memcpy(v[c.left.len..], right);
                        try c.out.append(c.a, .{ .vals = v, .ord = c.ord + subOrd(c.prep, c.k, sub) });
                    }
                };
                for (rows) |r| {
                    const ctx: Ctx = .{ .out = &out, .a = a, .left = r.vals, .ord = r.ord, .prep = prep, .k = k };
                    const n = try prep.joins[k].?.probe(r.vals[j.left_col], &ctx, Ctx.add);
                    if (n == 0 and j.left) {
                        const v = try a.alloc(Value, prep.widths[k + 1]);
                        @memcpy(v[0..r.vals.len], r.vals);
                        @memset(v[r.vals.len..], .null_);
                        try out.append(a, .{ .vals = v, .ord = r.ord });
                    }
                }
                rows = out.items;
            },
            .group => |g| {
                var t: agg.GroupTable = .init(a, g.keys.len, g.aggs, &sh.budget);
                var scratch: std.heap.ArenaAllocator = .init(sh.gpa);
                defer scratch.deinit();
                for (rows, 0..) |r, i| {
                    if (i % 1024 == 0) _ = scratch.reset(.retain_capacity);
                    try addToGroups(&t, &w.eval, g, r.vals, r.ord, scratch.allocator());
                }
                const outs = try t.finish(a, approx);
                rows = try a.alloc(Row, outs.len);
                for (outs, rows) |o, *r| r.* = .{ .vals = o.values, .ord = o.first };
                reorder(rows);
            },
            .sort => |keys| {
                sort.sortRows(rows, keys);
                reorder(rows);
            },
            .topk => |t| {
                sort.sortRows(rows, t.keys);
                rows = rows[0..@min(rows.len, t.k)];
                reorder(rows);
            },
            .limit => |n| {
                rows = rows[0..@min(rows.len, n)];
                reorder(rows);
            },
            .sample => |n| {
                var s: sort.Sample = .{ .arena = a, .n = n, .budget = &sh.budget };
                for (rows) |r| try s.add(r.vals, r.ord);
                rows = try s.finish(a);
                reorder(rows);
            },
        }
    }
    return rows;
}

fn emit(gpa: Allocator, p: *const Plan, rows: []const Row, sink: ResultSink, batch_rows: u32) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const cols = p.out_schema.columns;
    const vecs = try arena.allocator().alloc(ColumnVec, cols.len);
    const bufs = try arena.allocator().alloc([]Value, cols.len);
    const per: usize = @max(1, batch_rows);
    for (bufs) |*b| b.* = try arena.allocator().alloc(Value, per);
    var i: usize = 0;
    while (i < rows.len) {
        const n = @min(per, rows.len - i);
        for (cols, vecs, bufs, 0..) |c, *v, b, ci| {
            for (rows[i .. i + n], b[0..n]) |r, *o| o.* = if (ci < r.vals.len) r.vals[ci] else .null_;
            v.* = .{ .name = c.name, .ty = c.ty, .values = b[0..n] };
        }
        try sink.batch(sink.ctx, vecs, @intCast(n));
        i += n;
    }
}
