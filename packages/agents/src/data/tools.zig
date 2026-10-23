//! Data tools for agents (E13.F06.S02.T03), through zg_ai's foreign tool
//! contract: `data_open`, `data_describe`, `data_sample`, `data_query`
//! and `data_value_counts`.
//!
//! All of them are read-only. Results are bounded: at most 200 rows and
//! about 16 k tokens. When a query returns more rows than the tool shows,
//! the full result is saved as a CSV table artifact and its id returned.
//! A dataset path must pass the path policy (E16's, through a port; by
//! default: relative and inside the workspace).

const std = @import("std");
const zg_ai = @import("zg_ai");
const dataset = @import("dataset.zig");
const stats = @import("stats.zig");
const infer = @import("infer.zig");
const query = @import("query/root.zig");
const artifacts = @import("../artifacts/root.zig");
const runs = @import("../runs/root.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const foreign = zg_ai.tools.adapters.foreign;
const Dataset = dataset.Dataset;
const Value = query.exec.Value;

pub const default_rows = 50;
pub const max_rows = 200;
/// The JSON a tool returns stays under this (about 16 k tokens).
pub const max_result_bytes = 48 << 10;
/// Strings in returned rows are cut at this many bytes (the CSV artifact
/// keeps them whole).
pub const max_cell_bytes = 256;
/// The CSV artifact stops before the artifact store's text limit.
pub const max_csv_bytes = artifacts.kinds.max_text - (64 << 10);

pub const schemas = struct {
    pub const open = "{\"type\":\"object\",\"required\":[\"path\"],\"properties\":{" ++
        "\"path\":{\"type\":\"string\",\"description\":\"A CSV, TSV, JSON array or NDJSON file in the workspace.\"}," ++
        "\"name\":{\"type\":\"string\",\"description\":\"The name to query it by (default: from the file name).\"}" ++
        "},\"additionalProperties\":false}";
    pub const describe = "{\"type\":\"object\",\"required\":[\"dataset\"],\"properties\":{" ++
        "\"dataset\":{\"type\":\"string\"}," ++
        "\"columns\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Default: all.\"}" ++
        "},\"additionalProperties\":false}";
    pub const sample = "{\"type\":\"object\",\"required\":[\"dataset\"],\"properties\":{" ++
        "\"dataset\":{\"type\":\"string\"}," ++
        "\"n\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":200,\"description\":\"Default 10.\"}," ++
        "\"where\":{\"type\":\"string\",\"description\":\"A filter expression in the query language.\"}" ++
        "},\"additionalProperties\":false}";
    pub const query_ = "{\"type\":\"object\",\"required\":[\"query\"],\"properties\":{" ++
        "\"query\":{\"type\":\"string\"}," ++
        "\"max_rows\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":200,\"description\":\"Rows to return (default 50); the full result is saved as an artifact.\"}" ++
        "},\"additionalProperties\":false}";
    pub const value_counts = "{\"type\":\"object\",\"required\":[\"dataset\",\"column\"],\"properties\":{" ++
        "\"dataset\":{\"type\":\"string\"}," ++
        "\"column\":{\"type\":\"string\"}," ++
        "\"k\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":200,\"description\":\"Default 10.\"}" ++
        "},\"additionalProperties\":false}";
};

pub const tool_list = [_]foreign.ForeignTool{
    .{ .name = "data_open", .description = "Open a data file (CSV, TSV, JSON array, NDJSON) for querying. Returns its name, columns and types.", .input_schema_json = schemas.open, .read_only = true },
    .{ .name = "data_describe", .description = "Schema and statistics of an open dataset's columns: counts, nulls, distinct values, min, max, mean, quartiles, top values.", .input_schema_json = schemas.describe, .read_only = true },
    .{ .name = "data_sample", .description = "A deterministic sample of an open dataset's rows, optionally filtered.", .input_schema_json = schemas.sample, .read_only = true },
    .{ .name = "data_query", .description = "Run a query over open datasets. " ++ query.tool_summary, .input_schema_json = schemas.query_, .read_only = true },
    .{ .name = "data_value_counts", .description = "The k most frequent values of a column, with counts.", .input_schema_json = schemas.value_counts, .read_only = true },
};

/// E16's path policy: null allows the path, else the reason it doesn't.
pub const PathPolicy = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque, path: []const u8) ?[]const u8,
};

/// The default policy: relative paths that stay inside the workspace.
pub fn workspaceOnly(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "the path is empty";
    if (std.fs.path.isAbsolute(path) or std.fs.path.isAbsoluteWindows(path)) return "the path is outside the workspace";
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| if (std.mem.eql(u8, part, "..")) return "the path is outside the workspace";
    return null;
}

pub const Deps = struct {
    gpa: Allocator,
    io: Io,
    /// The workspace; paths are opened relative to it.
    workspace: Io.Dir,
    policy: ?PathPolicy = null,
    /// Where full results go (none: results are only cut).
    artifacts: ?*artifacts.ArtifactStore = null,
    run: ?runs.RunId = null,
    session: ?[]const u8 = null,
    threads: u16 = 0,
};

/// Datasets opened by `data_open`, for one session. Must not move after
/// `exporter`.
pub const DataTools = struct {
    deps: Deps,
    mutex: Io.Mutex = .init,
    open: std.ArrayListUnmanaged(Open) = .empty,
    cancel: std.atomic.Value(bool) = .init(false),

    const Open = struct { name: []u8, path: []u8, ds: *Dataset };

    pub fn init(deps: Deps) DataTools {
        return .{ .deps = deps };
    }

    pub fn deinit(t: *DataTools) void {
        for (t.open.items) |o| {
            o.ds.close();
            t.deps.gpa.free(o.name);
            t.deps.gpa.free(o.path);
        }
        t.open.deinit(t.deps.gpa);
    }

    pub fn exporter(t: *DataTools) foreign.Exporter {
        return .{ .name = "data", .kind = .agents, .ctx = t, .list = listFn, .call = callFn };
    }

    fn listFn(_: *anyopaque, arena: Allocator) anyerror![]const foreign.ForeignTool {
        return arena.dupe(foreign.ForeignTool, &tool_list);
    }

    fn callFn(ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!foreign.Result {
        _ = io;
        const t: *DataTools = @ptrCast(@alignCast(ctx));
        const r = try t.run(arena, tool, input_json);
        return .{ .json = r.json };
    }

    /// The dataset named `name`.
    pub fn get(t: *DataTools, name: []const u8) ?*Dataset {
        t.mutex.lockUncancelable(t.deps.io);
        defer t.mutex.unlock(t.deps.io);
        for (t.open.items) |o| if (std.mem.eql(u8, o.name, name)) return o.ds;
        return null;
    }

    fn getFn(ctx: *anyopaque, name: []const u8) ?*Dataset {
        const t: *DataTools = @ptrCast(@alignCast(ctx));
        return t.get(name);
    }

    /// The arena of the call in progress (for schemas the planner asks
    /// for).
    threadlocal var call_arena: ?Allocator = null;

    pub fn run(t: *DataTools, arena: Allocator, tool: []const u8, input_json: []const u8) !Output {
        var msg: []const u8 = "";
        const input = if (input_json.len == 0) "{}" else input_json;
        const out = t.runTool(arena, tool, input, &msg) catch |e| switch (e) {
            error.OutOfMemory, error.UnknownTool => return e,
            error.BadInput => null,
            else => blk: {
                msg = try std.fmt.allocPrint(arena, "{s} failed: {s}", .{ tool, errorText(e) });
                break :blk null;
            },
        };
        const text = out orelse msg;
        const Block = struct { type: []const u8 = "text", text: []const u8 };
        const R = struct { content: []const Block, isError: bool };
        return .{ .json = try std.json.Stringify.valueAlloc(arena, R{ .content = &.{.{ .text = text }}, .isError = out == null }, .{}), .is_error = out == null, .text = text };
    }

    fn runTool(t: *DataTools, a: Allocator, tool: []const u8, input: []const u8, msg: *[]const u8) ![]const u8 {
        const eq = std.mem.eql;
        if (eq(u8, tool, "data_open")) {
            const In = struct { path: []const u8, name: ?[]const u8 = null };
            const in = try parse(In, a, input, msg);
            return t.openTool(a, in.path, in.name, msg);
        }
        if (eq(u8, tool, "data_describe")) {
            const In = struct { dataset: []const u8, columns: ?[]const []const u8 = null };
            const in = try parse(In, a, input, msg);
            return t.describeTool(a, in.dataset, in.columns, msg);
        }
        if (eq(u8, tool, "data_sample")) {
            const In = struct { dataset: []const u8, n: u32 = 10, where: ?[]const u8 = null };
            const in = try parse(In, a, input, msg);
            _ = try t.dataset(a, in.dataset, msg);
            const n = std.math.clamp(in.n, 1, max_rows);
            const q = if (in.where) |w|
                try std.fmt.allocPrint(a, "from {f} | where {s} | sample {d}", .{ quoted(in.dataset), w, n })
            else
                try std.fmt.allocPrint(a, "from {f} | sample {d}", .{ quoted(in.dataset), n });
            return t.queryTool(a, q, n, false, msg);
        }
        if (eq(u8, tool, "data_query")) {
            const In = struct { query: []const u8, max_rows: u32 = default_rows };
            const in = try parse(In, a, input, msg);
            return t.queryTool(a, in.query, std.math.clamp(in.max_rows, 1, max_rows), true, msg);
        }
        if (eq(u8, tool, "data_value_counts")) {
            const In = struct { dataset: []const u8, column: []const u8, k: u32 = 10 };
            const in = try parse(In, a, input, msg);
            const ds = try t.dataset(a, in.dataset, msg);
            if (indexOfColumn(ds, in.column) == null) {
                msg.* = try std.fmt.allocPrint(a, "{s} has no column `{s}`; its columns: {s}", .{ in.dataset, in.column, try columnList(a, ds) });
                return error.BadInput;
            }
            const k = std.math.clamp(in.k, 1, max_rows);
            const q = try std.fmt.allocPrint(a, "from {f} | group {f} {{ count = count() }} | sort -count | limit {d}", .{ quoted(in.dataset), quoted(in.column), k });
            return t.queryTool(a, q, k, false, msg);
        }
        return error.UnknownTool;
    }

    fn dataset(t: *DataTools, a: Allocator, name: []const u8, msg: *[]const u8) !*Dataset {
        if (t.get(name)) |ds| return ds;
        msg.* = try std.fmt.allocPrint(a, "no open dataset `{s}`; open it with data_open first", .{name});
        return error.BadInput;
    }

    fn openTool(t: *DataTools, a: Allocator, path: []const u8, want_name: ?[]const u8, msg: *[]const u8) ![]const u8 {
        const denied = if (t.deps.policy) |p| p.check(p.ctx, path) else workspaceOnly(path);
        if (denied) |why| {
            msg.* = try std.fmt.allocPrint(a, "cannot open `{s}`: {s}", .{ path, why });
            return error.BadInput;
        }
        const gpa = t.deps.gpa;
        const ds = blk: {
            t.mutex.lockUncancelable(t.deps.io);
            defer t.mutex.unlock(t.deps.io);
            for (t.open.items) |o| if (std.mem.eql(u8, o.path, path)) break :blk o.ds;
            const ds = Dataset.open(gpa, t.deps.io, t.deps.workspace, path, null) catch |e| {
                msg.* = try std.fmt.allocPrint(a, "cannot open `{s}`: {s}", .{ path, errorText(e) });
                return error.BadInput;
            };
            errdefer ds.close();
            const name = try t.uniqueName(a, want_name orelse std.fs.path.stem(path));
            const owned_name = try gpa.dupe(u8, name);
            errdefer gpa.free(owned_name);
            const owned_path = try gpa.dupe(u8, path);
            errdefer gpa.free(owned_path);
            try t.open.append(gpa, .{ .name = owned_name, .path = owned_path, .ds = ds });
            break :blk ds;
        };
        try ds.waitIndexed();
        const name = for (t.open.items) |o| {
            if (o.ds == ds) break o.name;
        } else unreachable;
        const Col = struct { name: []const u8, type: []const u8 };
        const cols = try a.alloc(Col, ds.columns.len);
        for (cols, ds.columns, 0..) |*c, n, i| c.* = .{ .name = n, .type = typeName(colType(ds, i)) };
        const R = struct { dataset: []const u8, path: []const u8, format: []const u8, rows: u64, columns: []const Col };
        return std.json.Stringify.valueAlloc(a, R{
            .dataset = name,
            .path = path,
            .format = @tagName(ds.format),
            .rows = rowCount(ds),
            .columns = cols,
        }, .{});
    }

    fn uniqueName(t: *DataTools, a: Allocator, base: []const u8) ![]const u8 {
        var name: std.ArrayList(u8) = .empty;
        for (base) |ch| try name.append(a, if (std.ascii.isAlphanumeric(ch)) std.ascii.toLower(ch) else '_');
        if (name.items.len == 0 or std.ascii.isDigit(name.items[0])) try name.insertSlice(a, 0, "d_");
        const stem = try a.dupe(u8, name.items);
        var n: usize = 2;
        while (for (t.open.items) |o| {
            if (std.mem.eql(u8, o.name, name.items)) break true;
        } else false) : (n += 1) {
            name.clearRetainingCapacity();
            try name.print(a, "{s}_{d}", .{ stem, n });
        }
        return name.items;
    }

    fn describeTool(t: *DataTools, a: Allocator, name: []const u8, want: ?[]const []const u8, msg: *[]const u8) ![]const u8 {
        const ds = try t.dataset(a, name, msg);
        try ds.waitIndexed();
        var cols: std.ArrayList(u32) = .empty;
        if (want) |ws| {
            for (ws) |w| {
                const c = indexOfColumn(ds, w) orelse {
                    msg.* = try std.fmt.allocPrint(a, "{s} has no column `{s}`; its columns: {s}", .{ name, w, try columnList(a, ds) });
                    return error.BadInput;
                };
                try cols.append(a, c);
            }
        } else for (0..ds.columns.len) |c| try cols.append(a, @intCast(c));

        const Top = struct { value: []const u8, count: u64 };
        const Col = struct {
            name: []const u8,
            type: []const u8,
            count: u64,
            nulls: u64,
            distinct: u64,
            min: Cell,
            max: Cell,
            mean: ?f64 = null,
            p25: ?f64 = null,
            median: ?f64 = null,
            p75: ?f64 = null,
            top: []const Top = &.{},
            sampled: bool,
        };
        var out: std.ArrayList(Col) = .empty;
        for (cols.items) |c| {
            const s = try stats.computeStats(t.deps.io, ds, c, a, &t.cancel);
            const tops = try a.alloc(Top, @min(s.top.len, 5));
            for (tops, s.top[0..tops.len]) |*o, e| o.* = .{ .value = clip(e.v), .count = e.n };
            try out.append(a, .{
                .name = ds.columns[c],
                .type = typeName(s.ty),
                .count = s.count,
                .nulls = s.nulls,
                .distinct = s.distinct_est,
                .min = .{ .v = if (s.min) |v| fromInfer(v) else .null_ },
                .max = .{ .v = if (s.max) |v| fromInfer(v) else .null_ },
                .mean = s.mean,
                .p25 = s.quantiles[1],
                .median = s.quantiles[2],
                .p75 = s.quantiles[3],
                .top = if (s.ty == .string or s.ty == .bool_) tops else &.{},
                .sampled = s.sampled,
            });
        }
        const R = struct { dataset: []const u8, rows: u64, columns: []const Col };
        var r: R = .{ .dataset = name, .rows = rowCount(ds), .columns = out.items };
        while (true) {
            const json = try std.json.Stringify.valueAlloc(a, r, .{ .emit_null_optional_fields = false });
            if (json.len <= max_result_bytes or r.columns.len <= 1) return json;
            r.columns = r.columns[0 .. r.columns.len / 2];
        }
    }

    fn queryTool(t: *DataTools, a: Allocator, src: []const u8, keep: u32, save_full: bool, msg: *[]const u8) ![]const u8 {
        var diag: query.Diagnostic = .{};
        const tree = query.parse(a, src, &diag) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => {
                msg.* = try std.fmt.allocPrint(a, "query error: {f}", .{diag});
                return error.BadInput;
            },
        };
        call_arena = a;
        defer call_arena = null;
        const p = query.plan.plan(a, &tree, .{ .ctx = t, .resolve = resolveCall }, &diag) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => {
                msg.* = try std.fmt.allocPrint(a, "query error: {f}", .{diag});
                return error.BadInput;
            },
        };

        var sink: Sink = .{ .a = a, .keep = keep, .csv = save_full and t.deps.artifacts != null };
        if (sink.csv) try writeCsvHeader(a, &sink.text, p.out_schema);
        const start = Io.Clock.awake.now(t.deps.io);
        const st = query.execute(t.deps.io, t.deps.gpa, &p, .{ .ctx = t, .get = getFn }, .{ .ctx = &sink, .batch = Sink.batch }, .{
            .cancel = &t.cancel,
            .threads = t.deps.threads,
        }) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.QueryTooLarge => {
                msg.* = "query error: the query needs too much memory; add a filter (where) or a limit, or group the rows";
                return error.BadInput;
            },
            error.JoinTooLarge => {
                msg.* = "query error: the joined dataset is too large (over 10 M rows, or over 65536 matches for one row)";
                return error.BadInput;
            },
            else => |x| return x,
        };
        const elapsed = start.durationTo(Io.Clock.awake.now(t.deps.io));

        var artifact_id: ?[]const u8 = null;
        if (sink.csv and st.total_rows > sink.rows.items.len) {
            const id = try t.deps.artifacts.?.create(.{
                .kind = .table,
                .title = try std.fmt.allocPrint(a, "Query result: {s}", .{clipTo(src, 80)}),
                .content = sink.text.items,
                .mime = "text/csv",
                .run = t.deps.run,
                .session = t.deps.session,
            });
            artifact_id = try std.fmt.allocPrint(a, "{f}", .{id});
        }

        const Col = struct { name: []const u8, type: []const u8 };
        const cols = try a.alloc(Col, p.out_schema.columns.len);
        for (cols, p.out_schema.columns) |*c, sc| c.* = .{ .name = sc.name, .type = @tagName(sc.ty) };
        const R = struct {
            query: []const u8,
            columns: []const Col,
            rows: []const []const Cell,
            total_rows: u64,
            truncated: bool,
            query_ms: u64,
            artifact_id: ?[]const u8 = null,
            artifact_truncated: ?bool = null,
            approximate: ?bool = null,
        };
        var r: R = .{
            .query = src,
            .columns = cols,
            .rows = sink.rows.items,
            .total_rows = st.total_rows,
            .truncated = st.total_rows > sink.rows.items.len,
            .query_ms = @intCast(@max(0, elapsed.toMilliseconds())),
            .artifact_id = artifact_id,
            .artifact_truncated = if (artifact_id != null and (sink.csv_cut or st.truncated)) true else null,
            .approximate = if (st.approximate) true else null,
        };
        while (true) {
            const json = try std.json.Stringify.valueAlloc(a, r, .{ .emit_null_optional_fields = false });
            if (json.len <= max_result_bytes or r.rows.len == 0) return json;
            r.rows = r.rows[0 .. r.rows.len * 3 / 4];
            r.truncated = true;
        }
    }

    fn resolveCall(ctx: *anyopaque, name: []const u8) ?query.types.Schema {
        const t: *DataTools = @ptrCast(@alignCast(ctx));
        const ds = t.get(name) orelse return null;
        ds.waitIndexed() catch return null;
        return schemaOf(ds, call_arena.?) catch null;
    }
};

pub const Output = struct { json: []const u8, is_error: bool = false, text: []const u8 = "" };

/// Collects the first rows for the tool result and, when asked, the
/// whole result as CSV.
const Sink = struct {
    a: Allocator,
    keep: u32,
    rows: std.ArrayListUnmanaged([]const Cell) = .empty,
    csv: bool,
    text: std.ArrayList(u8) = .empty,
    csv_cut: bool = false,

    fn batch(ctx: *anyopaque, cols: []const query.exec.ColumnVec, n: u32) anyerror!void {
        const s: *Sink = @ptrCast(@alignCast(ctx));
        for (0..n) |r| {
            if (s.rows.items.len < s.keep) {
                const row = try s.a.alloc(Cell, cols.len);
                for (cols, row) |c, *o| o.* = .{ .v = try clipValue(s.a, c.values[r]) };
                try s.rows.append(s.a, row);
            }
            if (s.csv and !s.csv_cut) {
                const mark = s.text.items.len;
                for (cols, 0..) |c, i| {
                    if (i > 0) try s.text.append(s.a, ',');
                    try writeCsvValue(s.a, &s.text, c.values[r]);
                }
                try s.text.append(s.a, '\n');
                if (s.text.items.len > max_csv_bytes) {
                    s.text.shrinkRetainingCapacity(mark);
                    s.csv_cut = true;
                }
            }
        }
    }
};

/// A value in a tool result: numbers in shortest round-trip form, dates
/// and datetimes in ISO 8601.
pub const Cell = struct {
    v: Value,

    pub fn jsonStringify(c: Cell, jw: anytype) !void {
        switch (c.v) {
            .null_ => try jw.write(null),
            .bool_ => |b| try jw.write(b),
            .int => |i| try jw.write(i),
            .float => |f| if (std.math.isFinite(f)) try jw.print("{f}", .{Float{ .x = f }}) else try jw.write(if (std.math.isNan(f)) "NaN" else if (f > 0) "Infinity" else "-Infinity"),
            .string => |s| try jw.write(s),
            .date, .datetime => {
                var buf: [40]u8 = undefined;
                try jw.write(formatTemporal(&buf, c.v));
            },
        }
    }
};

/// A float in shortest round-trip form: plain decimals for everyday
/// magnitudes, else scientific (`1e300`).
pub const Float = struct {
    x: f64,

    pub fn format(v: Float, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const m = @abs(v.x);
        if (m == 0 or (m >= 1e-6 and m < 1e21)) return w.print("{d}", .{v.x});
        return w.print("{e}", .{v.x});
    }
};

/// `2025-01-31`, or `2025-01-31T10:00:00Z` (with milliseconds when there
/// are any).
pub fn formatTemporal(buf: []u8, v: Value) []const u8 {
    switch (v) {
        .date => |d| {
            const c = infer.civilFromDays(d);
            return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(@max(0, c.y))), c.m, c.d }) catch "";
        },
        .datetime => |ms| {
            const days = @divFloor(ms, 86_400_000);
            const rest: u64 = @intCast(@mod(ms, 86_400_000));
            const c = infer.civilFromDays(days);
            const hh = rest / 3_600_000;
            const mm = rest / 60_000 % 60;
            const ss = rest / 1000 % 60;
            const frac = rest % 1000;
            if (frac == 0) return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ @as(u64, @intCast(@max(0, c.y))), c.m, c.d, hh, mm, ss }) catch "";
            return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ @as(u64, @intCast(@max(0, c.y))), c.m, c.d, hh, mm, ss, frac }) catch "";
        },
        else => return "",
    }
}

fn writeCsvHeader(a: Allocator, out: *std.ArrayList(u8), schema: query.types.Schema) !void {
    for (schema.columns, 0..) |c, i| {
        if (i > 0) try out.append(a, ',');
        try writeCsvText(a, out, c.name);
    }
    try out.append(a, '\n');
}

fn writeCsvValue(a: Allocator, out: *std.ArrayList(u8), v: Value) !void {
    switch (v) {
        .null_ => {},
        .bool_ => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .int => |i| try out.print(a, "{d}", .{i}),
        .float => |f| try out.print(a, "{f}", .{Float{ .x = f }}),
        .string => |s| try writeCsvText(a, out, s),
        .date, .datetime => {
            var buf: [40]u8 = undefined;
            try out.appendSlice(a, formatTemporal(&buf, v));
        },
    }
}

/// RFC 4180: quoted when it holds a comma, quote or line break (or is
/// empty, so it doesn't read back as null).
fn writeCsvText(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    if (s.len > 0 and std.mem.indexOfAny(u8, s, ",\"\r\n") == null) return out.appendSlice(a, s);
    try out.append(a, '"');
    for (s) |ch| {
        if (ch == '"') try out.append(a, '"');
        try out.append(a, ch);
    }
    try out.append(a, '"');
}

fn clipValue(a: Allocator, v: Value) !Value {
    return switch (v) {
        .string => |s| .{ .string = try a.dupe(u8, clip(s)) },
        else => v,
    };
}

/// `s` cut at `max_cell_bytes` (on a UTF-8 boundary).
fn clip(s: []const u8) []const u8 {
    return clipTo(s, max_cell_bytes);
}

fn clipTo(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    var end = n;
    while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
    return s[0..end];
}

fn fromInfer(v: infer.Value) Value {
    return switch (v) {
        .bool_ => |b| .{ .bool_ = b },
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .date => |d| .{ .date = d },
        .datetime => |d| .{ .datetime = d },
        .string => |s| .{ .string = clip(s) },
    };
}

fn colType(ds: *const Dataset, i: usize) infer.ColType {
    return if (i < ds.types.len) ds.types[i] else .string;
}

fn typeName(t: infer.ColType) []const u8 {
    return @tagName(query.types.Type.fromCol(t));
}

fn rowCount(ds: *const Dataset) u64 {
    return switch (ds.rowCount()) {
        inline else => |x| x,
    };
}

fn schemaOf(ds: *const Dataset, a: Allocator) !query.types.Schema {
    const cols = try a.alloc(query.types.SchemaCol, ds.columns.len);
    for (cols, ds.columns, 0..) |*c, n, i| c.* = .{ .name = n, .ty = query.types.Type.fromCol(colType(ds, i)) };
    return .{ .columns = cols };
}

fn indexOfColumn(ds: *const Dataset, name: []const u8) ?u32 {
    for (ds.columns, 0..) |c, i| if (std.mem.eql(u8, c, name)) return @intCast(i);
    return null;
}

fn columnList(a: Allocator, ds: *const Dataset) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (ds.columns, 0..) |c, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, c);
    }
    return out.items;
}

/// A name in backticks (the query language's quoting).
fn quoted(name: []const u8) Quoted {
    return .{ .name = name };
}

const Quoted = struct {
    name: []const u8,

    pub fn format(q: Quoted, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('`');
        for (q.name) |ch| {
            if (ch == '`') try w.writeByte('`');
            try w.writeByte(ch);
        }
        try w.writeByte('`');
    }
};

fn parse(comptime T: type, a: Allocator, input: []const u8, msg: *[]const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, input, .{ .allocate = .alloc_always }) catch |e| {
        msg.* = try std.fmt.allocPrint(a, "invalid input: {t}", .{e});
        return error.BadInput;
    };
}

fn errorText(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "no such file",
        error.AccessDenied, error.PermissionDenied => "access denied",
        error.IsDir => "it is a directory",
        error.Canceled => "canceled",
        else => @errorName(e),
    };
}
