//! The data grid's view model (E13.F06.S01.T02): what the grid shows of
//! a `Dataset`, without any UI.
//!
//! With no query the grid shows the file's rows. Cell text is decoded
//! only for cells asked for, and cached (two generations of 32 k cells:
//! a lookup in the older one promotes the cell). While the file is still
//! being indexed, rows past the first screen are found by `seekApprox`:
//! a jump lands near the right place at once and the row numbers there
//! are approximate (`~`). When indexing finishes the cache is dropped
//! and every row is exact.
//!
//! A query (simple mode's sort and filter chips, or the query language
//! typed in advanced mode) runs on a worker. Its result rows stream into
//! the model as the executor hands them over; a new query cancels the
//! running one. Everything the UI reads is read on the UI thread, and
//! `wake` is called (from any thread) when there is something new;
//! `poll` then says whether the grid must reload.

const std = @import("std");
const zg_agents = @import("zg_agents");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const data = zg_agents.data;
const Dataset = data.Dataset;
const query = data.query;
const infer = data.infer;
const csv = data.csv;
const row_index = data.row_index;
const Value = query.exec.Value;
const QType = query.types.Type;

/// Rows a query keeps (the grid shows the first ones).
pub const max_result_rows: u64 = 1_000_000;
/// The cell cache holds at most twice this many cells.
pub const cache_generation: usize = 32 << 10;
/// Approximate rows read forward from one `seekApprox` landing.
const approx_window: u64 = 8192;

pub const Hook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque) void,
};

/// What a column holds, for alignment and "Chart this".
pub const Kind = enum { number, temporal, category };

pub fn kindOf(t: QType) Kind {
    return switch (t) {
        .int, .float => .number,
        .date, .datetime => .temporal,
        .null_, .bool_, .string => .category,
    };
}

/// A simple-mode filter on one column.
pub const Chip = struct {
    col: u32,
    op: Op,
    /// The value (equals, contains), or the range's low end.
    a: []const u8 = "",
    /// The range's high end.
    b: []const u8 = "",

    pub const Op = enum { equals, contains, range, is_null, not_null };
};

pub const Sort = struct { col: u32, desc: bool = false };

/// The rows of a query's result.
const Result = struct {
    arena: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    names: []const []const u8,
    types: []const QType,
    /// Row-major values, `names.len` per row.
    values: std.ArrayListUnmanaged(Value) = .empty,
    rows: u64 = 0,
    done: bool = false,
    stats: query.exec.ExecStats = .{},
    err: ?[]const u8 = null,
};

const Job = struct {
    vm: *GridVM,
    arena: std.heap.ArenaAllocator,
    plan: query.Plan,
    result: *Result,
    cancel: std.atomic.Value(bool) = .init(false),
    future: ?Io.Future(void) = null,
};

/// The two-generation cell cache.
const Cache = struct {
    cur: Gen,
    old: Gen,

    const Gen = struct {
        arena: std.heap.ArenaAllocator,
        map: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    };
    pub const Entry = struct { text: []const u8, null_: bool = false };

    fn init(gpa: Allocator) Cache {
        return .{ .cur = .{ .arena = .init(gpa) }, .old = .{ .arena = .init(gpa) } };
    }

    fn deinit(c: *Cache, gpa: Allocator) void {
        c.cur.map.deinit(gpa);
        c.old.map.deinit(gpa);
        c.cur.arena.deinit();
        c.old.arena.deinit();
    }

    fn clear(c: *Cache) void {
        c.cur.map.clearRetainingCapacity();
        c.old.map.clearRetainingCapacity();
        _ = c.cur.arena.reset(.retain_capacity);
        _ = c.old.arena.reset(.retain_capacity);
    }

    fn get(c: *Cache, gpa: Allocator, key: u64) ?Entry {
        if (c.cur.map.get(key)) |e| return e;
        const e = c.old.map.get(key) orelse return null;
        return c.put(gpa, key, e.text, e.null_) catch e;
    }

    /// Stores a copy of `text`; turns the generation over when full.
    fn put(c: *Cache, gpa: Allocator, key: u64, text: []const u8, null_: bool) !Entry {
        if (c.cur.map.count() >= cache_generation) {
            std.mem.swap(Gen, &c.cur, &c.old);
            c.cur.map.clearRetainingCapacity();
            _ = c.cur.arena.reset(.retain_capacity);
        }
        const e: Entry = .{ .text = try c.cur.arena.allocator().dupe(u8, text), .null_ = null_ };
        try c.cur.map.put(gpa, key, e);
        return e;
    }

    fn count(c: *const Cache) usize {
        return c.cur.map.count() + c.old.map.count();
    }
};

pub const GridVM = struct {
    gpa: Allocator,
    io: Io,
    ds: *Dataset,
    /// The dataset's name in queries ("" and this both work).
    name: []const u8,
    /// The file's workspace path (for "Chart this"), when it has one.
    path: ?[]const u8 = null,
    cache: Cache,
    /// Scratch for decoding one cell.
    scratch: std.heap.ArenaAllocator,
    /// Column types of the source.
    src_types: []QType,

    // -- the view --------------------------------------------------------
    /// The query in view (owned), or null for the file's rows.
    view_text: ?[]u8 = null,
    sort: ?Sort = null,
    chips: std.ArrayListUnmanaged(Chip) = .empty,
    chip_arena: std.heap.ArenaAllocator,
    /// Why the last query did not run (parse or plan error).
    query_error: ?[]u8 = null,
    job: ?*Job = null,
    /// Rows of the result seen by the last `poll`.
    seen_rows: u64 = 0,
    seen_done: bool = false,

    // -- the source while indexing --------------------------------------
    was_indexed: bool,
    /// Estimated data rows while indexing.
    est_rows: u64 = 0,
    /// Approximate rows: where each landing starts.
    approx: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    approx_anchor: ?struct { row: u64, offset: u64 } = null,

    wake: ?Hook = null,
    changed: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: Allocator, io: Io, ds: *Dataset, name: []const u8) !*GridVM {
        const vm = try gpa.create(GridVM);
        errdefer gpa.destroy(vm);
        const types = try gpa.alloc(QType, ds.columns.len);
        for (types, 0..) |*t, i| t.* = .fromCol(if (i < ds.types.len) ds.types[i] else .string);
        vm.* = .{
            .gpa = gpa,
            .io = io,
            .ds = ds,
            .name = name,
            .cache = .init(gpa),
            .scratch = .init(gpa),
            .chip_arena = .init(gpa),
            .src_types = types,
            .was_indexed = indexed(ds),
        };
        vm.estimate();
        return vm;
    }

    pub fn deinit(vm: *GridVM) void {
        vm.stopJob();
        vm.cache.deinit(vm.gpa);
        vm.scratch.deinit();
        vm.chip_arena.deinit();
        vm.chips.deinit(vm.gpa);
        vm.approx.deinit(vm.gpa);
        if (vm.view_text) |t| vm.gpa.free(t);
        if (vm.query_error) |e| vm.gpa.free(e);
        vm.gpa.free(vm.src_types);
        vm.gpa.destroy(vm);
    }

    fn indexed(ds: *const Dataset) bool {
        return ds.json != null or ds.indexed.load(.acquire);
    }

    fn estimate(vm: *GridVM) void {
        if (indexed(vm.ds)) return;
        const end = row_index.seekApprox(vm.ds.bytes, vm.ds.dialect, 1.0);
        vm.est_rows = end.approx_row -| vm.ds.headerRows();
    }

    fn notify(vm: *GridVM) void {
        vm.changed.store(true, .release);
        if (vm.wake) |w| w.f(w.ctx);
    }

    /// Picks up what changed in the background (indexing finished, result
    /// rows arrived); true when the grid must reload.
    pub fn poll(vm: *GridVM) bool {
        var reload = vm.changed.swap(false, .acq_rel);
        if (!vm.was_indexed and indexed(vm.ds)) {
            vm.was_indexed = true;
            vm.approx.clearRetainingCapacity();
            vm.approx_anchor = null;
            if (vm.job == null) vm.cache.clear();
            reload = true;
        }
        if (vm.job) |j| {
            j.result.mutex.lockUncancelable(vm.io);
            const rows = j.result.rows;
            const done = j.result.done;
            j.result.mutex.unlock(vm.io);
            if (rows != vm.seen_rows or done != vm.seen_done) reload = true;
            vm.seen_rows = rows;
            vm.seen_done = done;
        }
        return reload;
    }

    // -- shape ---------------------------------------------------------------

    pub fn columnCount(vm: *const GridVM) usize {
        if (vm.job) |j| return j.result.names.len;
        return vm.ds.columns.len;
    }

    pub fn columnName(vm: *const GridVM, col: u32) []const u8 {
        if (vm.job) |j| return j.result.names[col];
        return vm.ds.columns[col];
    }

    pub fn columnType(vm: *const GridVM, col: u32) QType {
        if (vm.job) |j| return j.result.types[col];
        return vm.src_types[col];
    }

    /// Rows the grid has: exact, or an estimate while indexing.
    pub fn rowCount(vm: *GridVM) u64 {
        if (vm.job) |j| {
            j.result.mutex.lockUncancelable(vm.io);
            defer j.result.mutex.unlock(vm.io);
            return j.result.rows;
        }
        return switch (vm.ds.rowCount()) {
            .exact => |n| n,
            .at_least => |n| @max(n, vm.est_rows),
        };
    }

    /// Data rows of the first screen's index (exact while indexing).
    fn exactRows(vm: *const GridVM) u64 {
        if (indexed(vm.ds)) return std.math.maxInt(u64);
        return vm.ds.index().count() -| vm.ds.headerRows();
    }

    /// Whether row `row`'s number is an estimate.
    pub fn isApprox(vm: *const GridVM, row: u64) bool {
        return vm.job == null and row >= vm.exactRows();
    }

    /// "1,234,567 rows", "≥ 2,000,000 rows (indexing 43%)", or the
    /// query's "12 of ≥ 3,400 rows…" while it runs.
    pub fn rowCountLabel(vm: *GridVM, buf: []u8) []const u8 {
        var w: Io.Writer = .fixed(buf);
        vm.writeCountLabel(&w) catch return buf[0..w.end];
        return w.buffered();
    }

    fn writeCountLabel(vm: *GridVM, w: *Io.Writer) !void {
        if (vm.job) |j| {
            j.result.mutex.lockUncancelable(vm.io);
            defer j.result.mutex.unlock(vm.io);
            const r = j.result;
            if (r.err) |e| return w.print("Query failed: {s}", .{e});
            try writeGrouped(w, r.rows);
            try w.writeAll(if (r.rows == 1) " row" else " rows");
            if (!r.done) return w.writeAll(" so far (querying…)");
            if (r.stats.total_rows > r.rows) {
                try w.writeAll(" of ");
                try writeGrouped(w, r.stats.total_rows);
            }
            return;
        }
        switch (vm.ds.rowCount()) {
            .exact => |n| {
                try writeGrouped(w, n);
                try w.writeAll(if (n == 1) " row" else " rows");
            },
            .at_least => |n| {
                const est = @max(vm.est_rows, 1);
                const pct = @min(99, n * 100 / est);
                try w.writeAll("≥ ");
                try writeGrouped(w, n);
                try w.print(" rows (indexing {d}%)", .{pct});
            },
        }
    }

    // -- cells -------------------------------------------------------------

    fn key(row: u64, col: u32) u64 {
        return (row << 16) | col;
    }

    /// A cell as the grid shows it: numbers with thousands separators,
    /// ISO dates, "∅" for null (`isNull` says which), "" past the end.
    pub fn cellText(vm: *GridVM, row: u64, col: u32) []const u8 {
        return (vm.cell(row, col) catch return "").text;
    }

    pub fn isNull(vm: *GridVM, row: u64, col: u32) bool {
        return (vm.cell(row, col) catch return false).null_;
    }

    pub fn cell(vm: *GridVM, row: u64, col: u32) !Cache.Entry {
        const k = key(row, col);
        if (vm.cache.get(vm.gpa, k)) |e| return e;
        defer _ = vm.scratch.reset(.retain_capacity);
        const a = vm.scratch.allocator();
        if (vm.job) |j| {
            j.result.mutex.lockUncancelable(vm.io);
            defer j.result.mutex.unlock(vm.io);
            const r = j.result;
            if (row >= r.rows) return .{ .text = "" };
            const v = r.values.items[@intCast(row * r.names.len + col)];
            if (v == .null_) return vm.cache.put(vm.gpa, k, null_mark, true);
            return vm.cache.put(vm.gpa, k, try formatValue(a, v), false);
        }
        const raw = try vm.sourceCell(a, row, col);
        const ty = vm.src_types[col];
        if (infer.isNullText(raw) and ty != .string) return vm.cache.put(vm.gpa, k, null_mark, true);
        if (raw.len == 0) return vm.cache.put(vm.gpa, k, null_mark, true);
        const v = infer.parse(raw, colTypeOf(ty), vm.ds.inferCtx()) orelse return vm.cache.put(vm.gpa, k, raw, false);
        return vm.cache.put(vm.gpa, k, try formatValue(a, fromInfer(v)), false);
    }

    /// The raw text of a source cell; approximate rows read from their
    /// `seekApprox` landing.
    fn sourceCell(vm: *GridVM, a: Allocator, row: u64, col: u32) ![]const u8 {
        if (!vm.isApprox(row)) return vm.ds.cell(row, col, a);
        const off = try vm.approxOffset(a, row) orelse return "";
        return vm.ds.cellAt(off, col, a);
    }

    /// Where approximate row `row` starts: read forward from the last
    /// landing when the row is just after it, else a new landing.
    fn approxOffset(vm: *GridVM, a: Allocator, row: u64) !?u64 {
        if (vm.approx.get(row)) |o| return o;
        const exact = vm.exactRows();
        const near_head = row - exact < approx_window;
        if (near_head and (vm.approx_anchor == null or vm.approx_anchor.?.row != exact)) {
            // The first rows past the first screen follow its last record.
            const ix = vm.ds.index();
            if (ix.count() == 0) return null;
            var rd: csv.CsvReader = .initAt(vm.ds.bytes, vm.ds.dialect, ix.offset(ix.count() - 1));
            var fields: std.ArrayList(csv.Field) = .empty;
            _ = try rd.nextRecord(&fields, a);
            vm.approx.clearRetainingCapacity();
            vm.approx_anchor = .{ .row = exact, .offset = rd.pos };
            try vm.approx.put(vm.gpa, exact, rd.pos);
        }
        const an_opt = vm.approx_anchor;
        if (an_opt == null or row < an_opt.?.row or row - an_opt.?.row >= approx_window) {
            const est = @max(vm.rowCount(), 1);
            const s = row_index.seekApprox(vm.ds.bytes, vm.ds.dialect, @as(f64, @floatFromInt(row)) / @as(f64, @floatFromInt(est)));
            vm.approx.clearRetainingCapacity();
            vm.approx_anchor = .{ .row = row, .offset = s.offset };
            try vm.approx.put(vm.gpa, row, s.offset);
            return s.offset;
        }
        const an = an_opt.?;
        var r = row;
        while (r > an.row and !vm.approx.contains(r)) r -= 1;
        var rd: csv.CsvReader = .initAt(vm.ds.bytes, vm.ds.dialect, vm.approx.get(r) orelse an.offset);
        var fields: std.ArrayList(csv.Field) = .empty;
        while (r < row) : (r += 1) {
            _ = (try rd.nextRecord(&fields, a)) orelse return null;
            try vm.approx.put(vm.gpa, r + 1, rd.pos);
        }
        return vm.approx.get(row);
    }

    /// The row number for the gutter: "1,234" or "~1,234,567".
    pub fn rowLabel(vm: *const GridVM, row: u64, buf: []u8) []const u8 {
        var w: Io.Writer = .fixed(buf);
        if (vm.isApprox(row)) w.writeAll("~") catch {};
        writeGrouped(&w, row + 1) catch {};
        return w.buffered();
    }

    pub fn cachedCells(vm: *const GridVM) usize {
        return vm.cache.count();
    }

    // -- the view ------------------------------------------------------------

    /// Shows `text`'s result (null: the file's rows). Cancels the running
    /// query. A parse or plan error is kept in `query_error` (and the
    /// view keeps the previous rows).
    pub fn setView(vm: *GridVM, text: ?[]const u8) !void {
        if (vm.query_error) |e| vm.gpa.free(e);
        vm.query_error = null;
        const src = text orelse {
            vm.stopJob();
            if (vm.view_text) |t| vm.gpa.free(t);
            vm.view_text = null;
            vm.cache.clear();
            vm.notify();
            return;
        };
        const job = try vm.gpa.create(Job);
        job.* = .{ .vm = vm, .arena = .init(vm.gpa), .plan = undefined, .result = undefined };
        var keep = false;
        defer if (!keep) {
            job.arena.deinit();
            vm.gpa.destroy(job);
        };
        const a = job.arena.allocator();
        const owned = try a.dupe(u8, src);
        var diag: query.Diagnostic = .{};
        const tree = query.parse(a, owned, &diag) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return vm.fail(diag),
        };
        job.plan = query.plan.plan(a, &tree, .{ .ctx = vm, .resolve = resolve }, &diag) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return vm.fail(diag),
        };
        const cols = job.plan.out_schema.columns;
        const result = try a.create(Result);
        result.* = .{ .arena = .init(vm.gpa), .names = undefined, .types = undefined };
        const names = try a.alloc([]const u8, cols.len);
        const types = try a.alloc(QType, cols.len);
        for (cols, names, types) |c, *n, *t| {
            n.* = c.name;
            t.* = c.ty;
        }
        result.names = names;
        result.types = types;
        job.result = result;

        vm.stopJob();
        if (vm.view_text) |t| vm.gpa.free(t);
        vm.view_text = try vm.gpa.dupe(u8, src);
        vm.cache.clear();
        vm.seen_rows = 0;
        vm.seen_done = false;
        vm.job = job;
        keep = true;
        job.future = vm.io.concurrent(runJob, .{job}) catch blk: {
            runJob(job);
            break :blk null;
        };
        vm.notify();
    }

    fn fail(vm: *GridVM, diag: query.Diagnostic) !void {
        vm.query_error = try std.fmt.allocPrint(vm.gpa, "{s}", .{diag.message});
        vm.notify();
    }

    fn stopJob(vm: *GridVM) void {
        const j = vm.job orelse return;
        j.cancel.store(true, .release);
        if (j.future) |*f| f.await(vm.io);
        j.result.arena.deinit();
        j.result.values.deinit(vm.gpa);
        j.arena.deinit();
        vm.gpa.destroy(j);
        vm.job = null;
    }

    /// Whether a query is running.
    pub fn querying(vm: *GridVM) bool {
        const j = vm.job orelse return false;
        j.result.mutex.lockUncancelable(vm.io);
        defer j.result.mutex.unlock(vm.io);
        return !j.result.done;
    }

    fn resolve(ctx: *anyopaque, name: []const u8) ?query.types.Schema {
        const vm: *GridVM = @ptrCast(@alignCast(ctx));
        if (!vm.isOwnName(name)) return null;
        const cols = vm.chip_arena.allocator().alloc(query.types.SchemaCol, vm.ds.columns.len) catch return null;
        for (cols, vm.ds.columns, vm.src_types) |*c, n, t| c.* = .{ .name = n, .ty = t };
        return .{ .columns = cols };
    }

    fn isOwnName(vm: *const GridVM, name: []const u8) bool {
        return name.len == 0 or std.mem.eql(u8, name, vm.name);
    }

    fn getDataset(ctx: *anyopaque, name: []const u8) ?*Dataset {
        const vm: *GridVM = @ptrCast(@alignCast(ctx));
        return if (vm.isOwnName(name)) vm.ds else null;
    }

    fn runJob(job: *Job) void {
        const vm = job.vm;
        const r = job.result;
        // Queries read the whole file: wait for its index.
        while (!indexed(vm.ds)) {
            if (job.cancel.load(.acquire)) return;
            if (vm.ds.index_error) |_| break;
            vm.io.sleep(.fromMilliseconds(2), .awake) catch {};
        }
        const Sink = struct {
            fn batch(ctx: *anyopaque, cols: []const query.exec.ColumnVec, n: u32) anyerror!void {
                const j: *Job = @ptrCast(@alignCast(ctx));
                const res = j.result;
                res.mutex.lockUncancelable(j.vm.io);
                defer res.mutex.unlock(j.vm.io);
                const a = res.arena.allocator();
                try res.values.ensureUnusedCapacity(j.vm.gpa, @as(usize, n) * cols.len);
                for (0..n) |i| for (cols) |c| {
                    var v = c.values[i];
                    if (v == .string) v = .{ .string = try a.dupe(u8, v.string) };
                    res.values.appendAssumeCapacity(v);
                };
                res.rows += n;
                j.vm.notify();
            }
        };
        const st = query.execute(vm.io, vm.gpa, &job.plan, .{ .ctx = vm, .get = getDataset }, .{ .ctx = job, .batch = Sink.batch }, .{
            .cancel = &job.cancel,
            .max_rows_out = max_result_rows,
        });
        r.mutex.lockUncancelable(vm.io);
        if (st) |s| r.stats = s else |e| if (e != error.Canceled) {
            r.err = switch (e) {
                error.QueryTooLarge => "the query needs too much memory; add a filter or a limit, or group the rows",
                error.JoinTooLarge => "the joined dataset is too large",
                else => @errorName(e),
            };
        }
        r.done = true;
        r.mutex.unlock(vm.io);
        if (!job.cancel.load(.acquire)) vm.notify();
    }

    // -- simple mode ----------------------------------------------------------

    pub fn setSort(vm: *GridVM, s: ?Sort) !void {
        vm.sort = s;
        try vm.applySimple();
    }

    pub fn addChip(vm: *GridVM, c: Chip) !void {
        const a = vm.chip_arena.allocator();
        try vm.chips.append(vm.gpa, .{ .col = c.col, .op = c.op, .a = try a.dupe(u8, c.a), .b = try a.dupe(u8, c.b) });
        try vm.applySimple();
    }

    pub fn removeChip(vm: *GridVM, i: usize) !void {
        _ = vm.chips.orderedRemove(i);
        try vm.applySimple();
    }

    pub fn clearFilters(vm: *GridVM) !void {
        vm.chips.clearRetainingCapacity();
        vm.sort = null;
        try vm.applySimple();
    }

    /// The simple mode's query (null: no sort and no filters).
    pub fn simpleQuery(vm: *const GridVM, a: Allocator) !?[]const u8 {
        if (vm.chips.items.len == 0 and vm.sort == null) return null;
        var w: Io.Writer.Allocating = .init(a);
        try w.writer.writeAll("from ");
        try query.parser.writeName(&w.writer, vm.name);
        for (vm.chips.items, 0..) |c, i| {
            try w.writer.writeAll(if (i == 0) " | where " else " and ");
            try vm.writeChip(&w.writer, c);
        }
        if (vm.sort) |s| {
            try w.writer.writeAll(" | sort ");
            if (s.desc) try w.writer.writeByte('-');
            try query.parser.writeName(&w.writer, vm.ds.columns[s.col]);
        }
        return w.written();
    }

    fn writeChip(vm: *const GridVM, w: *Io.Writer, c: Chip) !void {
        const name = vm.ds.columns[c.col];
        const ty = vm.src_types[c.col];
        switch (c.op) {
            .equals => {
                try query.parser.writeName(w, name);
                try w.writeAll(" == ");
                try writeLiteral(w, c.a, ty);
            },
            .contains => {
                try w.writeAll("contains(lower(");
                try query.parser.writeName(w, name);
                try w.writeAll("), ");
                var buf: [256]u8 = undefined;
                const lower = std.ascii.lowerString(buf[0..@min(buf.len, c.a.len)], c.a[0..@min(buf.len, c.a.len)]);
                try query.parser.writeString(w, lower);
                try w.writeAll(")");
            },
            .range => {
                const has_a = std.mem.trim(u8, c.a, " ").len > 0;
                const has_b = std.mem.trim(u8, c.b, " ").len > 0;
                try query.parser.writeName(w, name);
                if (has_a and has_b) {
                    try w.writeAll(" between ");
                    try writeLiteral(w, c.a, ty);
                    try w.writeAll(" and ");
                    try writeLiteral(w, c.b, ty);
                } else if (has_a) {
                    try w.writeAll(" >= ");
                    try writeLiteral(w, c.a, ty);
                } else {
                    try w.writeAll(" <= ");
                    try writeLiteral(w, c.b, ty);
                }
            },
            .is_null => {
                try query.parser.writeName(w, name);
                try w.writeAll(" is null");
            },
            .not_null => {
                try query.parser.writeName(w, name);
                try w.writeAll(" is not null");
            },
        }
    }

    fn applySimple(vm: *GridVM) !void {
        var arena: std.heap.ArenaAllocator = .init(vm.gpa);
        defer arena.deinit();
        try vm.setView(try vm.simpleQuery(arena.allocator()));
    }
};

pub const CopyFormat = enum { tsv, markdown };

/// Markdown copies at most this many rows.
pub const max_markdown_rows: u64 = 1000;

/// Rows `rows` (inclusive ranges, in order) of columns `cols` as TSV
/// (tabs and line breaks in cells become spaces) or a Markdown table
/// (numbers right-aligned, `|` escaped), with a header row.
pub fn copyRows(vm: *GridVM, a: Allocator, rows: []const [2]u64, cols: []const u32, format: CopyFormat) ![]const u8 {
    var n: u64 = 0;
    for (rows) |r| n += r[1] - r[0] + 1;
    if (format == .markdown and n > max_markdown_rows) return error.TooManyRows;
    var w: Io.Writer.Allocating = .init(a);
    const out = &w.writer;
    for (cols, 0..) |c, i| {
        if (format == .markdown) try out.writeAll(if (i == 0) "| " else " | ") else if (i > 0) try out.writeByte('\t');
        try writeCell(out, vm.columnName(c), format);
    }
    if (format == .markdown) {
        try out.writeAll(" |\n|");
        for (cols) |c| try out.writeAll(if (kindOf(vm.columnType(c)) == .number) " ---: |" else " --- |");
    }
    try out.writeByte('\n');
    for (rows) |r| {
        var row = r[0];
        while (row <= r[1]) : (row += 1) {
            for (cols, 0..) |c, i| {
                if (format == .markdown) try out.writeAll(if (i == 0) "| " else " | ") else if (i > 0) try out.writeByte('\t');
                const e = try vm.cell(row, c);
                try writeCell(out, if (e.null_) "" else e.text, format);
            }
            if (format == .markdown) try out.writeAll(" |");
            try out.writeByte('\n');
        }
    }
    return w.written();
}

fn writeCell(w: *Io.Writer, s: []const u8, format: CopyFormat) !void {
    for (s) |ch| switch (ch) {
        '\t', '\n', '\r' => try w.writeByte(' '),
        '|' => try w.writeAll(if (format == .markdown) "\\|" else "|"),
        else => try w.writeByte(ch),
    };
}

pub const null_mark = "∅";

fn colTypeOf(t: QType) infer.ColType {
    return switch (t) {
        .null_ => .null_,
        .bool_ => .bool_,
        .int => .int,
        .float => .float,
        .string => .string,
        .date => .date,
        .datetime => .datetime,
    };
}

pub fn fromInfer(v: infer.Value) Value {
    return switch (v) {
        .bool_ => |b| .{ .bool_ = b },
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .date => |d| .{ .date = d },
        .datetime => |t| .{ .datetime = t },
        .string => |s| .{ .string = s },
    };
}

/// A literal of the column's type when the text reads as one, else a
/// string.
fn writeLiteral(w: *Io.Writer, text: []const u8, ty: QType) !void {
    const s = std.mem.trim(u8, text, " \t");
    switch (ty) {
        .int, .float => if (infer.parseFloat(s) != null or infer.parseInt(s) != null) return w.writeAll(s),
        .date => if (infer.parseIsoDate(s)) |d| return query.parser.writeDate(w, d),
        .datetime => if (infer.parseDatetime(s)) |t| return query.parser.writeDatetime(w, t),
        .bool_ => if (infer.parseBool(s)) |b| return w.writeAll(if (b) "true" else "false"),
        else => {},
    }
    try query.parser.writeString(w, s);
}

/// A value as the grid shows it.
pub fn formatValue(a: Allocator, v: Value) ![]const u8 {
    var w: Io.Writer.Allocating = .init(a);
    writeValue(&w.writer, v) catch return error.OutOfMemory;
    return w.written();
}

pub fn writeValue(w: *Io.Writer, v: Value) !void {
    switch (v) {
        .null_ => try w.writeAll(null_mark),
        .bool_ => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| {
            if (i < 0) try w.writeByte('-');
            try writeGrouped(w, @abs(i));
        },
        .float => |f| {
            if (!std.math.isFinite(f)) return w.print("{d}", .{f});
            var buf: [64]u8 = undefined;
            var s: []const u8 = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return w.print("{d}", .{f});
            if (s.len > 0 and s[0] == '-') {
                try w.writeByte('-');
                s = s[1..];
            }
            const dot = std.mem.indexOfAny(u8, s, ".e") orelse s.len;
            const whole = std.fmt.parseInt(u64, s[0..dot], 10) catch return w.writeAll(s);
            try writeGrouped(w, whole);
            try w.writeAll(s[dot..]);
        },
        .string => |s| try w.writeAll(s),
        .date => |d| try query.parser.writeDate(w, d),
        .datetime => |t| try query.parser.writeDatetime(w, t),
    }
}

/// `n` with thousands separators.
pub fn writeGrouped(w: *Io.Writer, n: u64) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
    for (s, 0..) |ch, i| {
        if (i > 0 and (s.len - i) % 3 == 0) try w.writeByte(',');
        try w.writeByte(ch);
    }
}

test {
    std.testing.refAllDecls(@This());
}
