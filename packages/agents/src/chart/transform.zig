//! Chart data and transforms (E13.F07.S01.T03): a column table of query
//! values, built from inline JSON rows or handed over by the app (an
//! artifact table, a file through an F06 query), and the spec's
//! transforms over it: filter and calculate (F06 expressions), bin,
//! aggregate, timeUnit and fold.

const std = @import("std");
const query = @import("../data/query/root.zig");
const infer = @import("../data/infer.zig");
const spec = @import("spec.zig");
const ticks = @import("ticks.zig");

const Allocator = std.mem.Allocator;
pub const Lit = query.plan.Lit;
pub const Type = query.types.Type;
const ev = query.expr_eval;

pub const Table = struct {
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    types: std.ArrayListUnmanaged(Type) = .empty,
    cols: std.ArrayListUnmanaged([]Lit) = .empty,
    rows: usize = 0,

    pub fn find(t: *const Table, name: []const u8) ?usize {
        for (t.names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
        return null;
    }

    /// Adds a column, replacing one of the same name.
    pub fn put(t: *Table, a: Allocator, name: []const u8, ty: Type, values: []Lit) !void {
        std.debug.assert(values.len == t.rows);
        if (t.find(name)) |i| {
            t.types.items[i] = ty;
            t.cols.items[i] = values;
            return;
        }
        try t.names.append(a, name);
        try t.types.append(a, ty);
        try t.cols.append(a, values);
    }

    pub fn column(t: *const Table, name: []const u8) ?[]const Lit {
        return if (t.find(name)) |i| t.cols.items[i] else null;
    }

    pub fn schema(t: *const Table, a: Allocator) !query.types.Schema {
        const cols = try a.alloc(query.types.SchemaCol, t.names.items.len);
        for (cols, t.names.items, t.types.items) |*c, n, ty| c.* = .{ .name = n, .ty = ty };
        return .{ .columns = cols };
    }

    /// The rows at `keep` (in that order) as a new table.
    pub fn select(t: *const Table, a: Allocator, keep: []const u32) !Table {
        var out: Table = .{ .rows = keep.len };
        for (t.names.items, t.types.items, t.cols.items) |n, ty, col| {
            const vals = try a.alloc(Lit, keep.len);
            for (vals, keep) |*v, k| v.* = col[k];
            try out.put(a, n, ty, vals);
        }
        return out;
    }
};

/// A transform failed; `message` names the transform's JSON path.
pub const Error = error{ InvalidTransform, OutOfMemory };

pub const Diagnostic = struct { message: []const u8 = "" };

/// Inline JSON rows as a table: columns in first-seen key order, typed
/// by unifying their values (numbers mixed with text become text).
pub fn fromJson(a: Allocator, rows: []const std.json.Value) !Table {
    var t: Table = .{ .rows = rows.len };
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    for (rows) |r| if (r == .object) {
        var it = r.object.iterator();
        while (it.next()) |e| {
            const gop = try index.getOrPut(a, e.key_ptr.*);
            if (!gop.found_existing) {
                gop.value_ptr.* = names.items.len;
                try names.append(a, e.key_ptr.*);
            }
        }
    };
    for (names.items) |n| {
        const vals = try a.alloc(Lit, rows.len);
        var ty: Type = .null_;
        var mixed = false;
        for (rows, vals) |r, *v| {
            v.* = if (r == .object) if (r.object.get(n)) |x| try lit(a, x) else .null_ else .null_;
            const vt = litType(v.*);
            if (vt == .null_) continue;
            if (ty == .null_) {
                ty = vt;
            } else if (Type.unify(ty, vt)) |u| ty = u else mixed = true;
        }
        if (mixed) {
            ty = .string;
            for (vals) |*v| if (v.* != .null_ and v.* != .string) {
                v.* = .{ .string = try litText(a, v.*) };
            };
        } else for (vals) |*v| v.* = ev.coerce(v.*, ty);
        try t.put(a, n, ty, vals);
    }
    return t;
}

fn lit(a: Allocator, v: std.json.Value) !Lit {
    return switch (v) {
        .null => .null_,
        .bool => |b| .{ .bool_ = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .float = std.fmt.parseFloat(f64, s) catch return .null_ },
        .string => |s| .{ .string = s },
        // Nested values are shown as JSON text.
        .array, .object => .{ .string = try std.json.Stringify.valueAlloc(a, v, .{}) },
    };
}

pub fn litType(v: Lit) Type {
    return switch (v) {
        .null_ => .null_,
        .bool_ => .bool_,
        .int => .int,
        .float => .float,
        .string => .string,
        .date => .date,
        .datetime => .datetime,
    };
}

/// A value as label text.
pub fn litText(a: Allocator, v: Lit) Allocator.Error![]const u8 {
    if (v == .string) return v.string;
    var w: std.Io.Writer.Allocating = .init(a);
    writeLit(&w.writer, v) catch return error.OutOfMemory;
    return w.written();
}

pub fn writeLit(w: *std.Io.Writer, v: Lit) std.Io.Writer.Error!void {
    switch (v) {
        .null_ => try w.writeAll("null"),
        .bool_ => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try ticks.formatValue(w, f),
        .string => |s| try w.writeAll(s),
        .date => |d| try ticks.formatTimestamp(w, @as(i64, d) * ticks.ms_day, .utc),
        .datetime => |t| try ticks.formatTimestamp(w, t, .utc),
    }
}

/// A value as a number (null for text, booleans and nulls).
pub fn toNum(v: Lit) ?f64 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |f| if (std.math.isFinite(f)) f else null,
        .date => |d| @floatFromInt(@as(i64, d) * ticks.ms_day),
        .datetime => |t| @floatFromInt(t),
        else => null,
    };
}

/// A value as UTC milliseconds: datetimes, dates, ISO text, and numbers
/// (taken as milliseconds since 1970).
pub fn toTime(v: Lit) ?i64 {
    return switch (v) {
        .datetime => |t| t,
        .date => |d| @as(i64, d) * ticks.ms_day,
        .int => |i| i,
        .float => |f| if (std.math.isFinite(f) and @abs(f) < 1e17) @intFromFloat(f) else null,
        .string => |s| if (infer.parseIsoDate(s)) |d| @as(i64, d) * ticks.ms_day else infer.parseDatetime(s),
        else => null,
    };
}

/// The start of the `unit` containing `t`.
pub fn truncate(t: i64, unit: spec.TimeUnit, zone: ticks.Zone) i64 {
    const step: ticks.TimeStep = switch (unit) {
        .year => .y1,
        .quarter => .mo3,
        .month => .mo1,
        .week => .w1,
        .day => .d1,
        .hour => .h1,
    };
    return ticks.floorTo(t, step, 1, zone);
}

/// Runs the spec's transforms in order.
pub fn apply(a: Allocator, gpa: Allocator, t: *Table, list: []const spec.Transform, zone: ticks.Zone, diag: *Diagnostic) Error!void {
    for (list, 0..) |tr, i| {
        switch (tr) {
            .filter => |e| {
                const vals = try evalColumn(a, gpa, t, e, i, "filter", diag);
                var keep: std.ArrayListUnmanaged(u32) = .empty;
                for (vals.values, 0..) |v, r| if (ev.truthy(v)) try keep.append(a, @intCast(r));
                t.* = try t.select(a, keep.items);
            },
            .calculate => |c| {
                const vals = try evalColumn(a, gpa, t, c.expr, i, "calculate", diag);
                try t.put(a, c.as, vals.ty, vals.values);
            },
            .bin => |b| try binColumn(a, t, b.field, b.maxbins, b.as, i, diag),
            .time_unit => |u| try timeUnitColumn(a, t, u.field, u.unit, u.as, zone, i, diag),
            .aggregate => |g| t.* = try aggregate(a, t, g.groupby, g.ops, i, diag),
            .fold => |f| t.* = try fold(a, t, f.fields, f.as, i, diag),
        }
    }
}

fn fail(a: Allocator, diag: *Diagnostic, i: usize, key: []const u8, comptime fmt: []const u8, args: anytype) Error {
    diag.message = std.fmt.allocPrint(a, "transform[{d}].{s}: " ++ fmt, .{ i, key } ++ args) catch return error.OutOfMemory;
    return error.InvalidTransform;
}

fn missing(a: Allocator, t: *const Table, diag: *Diagnostic, i: usize, key: []const u8, name: []const u8) Error {
    return fail(a, diag, i, key, "unknown field `{s}`; fields: {s}", .{ name, try fieldList(a, t) });
}

pub fn fieldList(a: Allocator, t: *const Table) ![]const u8 {
    return std.mem.join(a, ", ", t.names.items);
}

const Evaluated = struct { ty: Type, values: []Lit };

/// An F06 expression over every row.
fn evalColumn(a: Allocator, gpa: Allocator, t: *const Table, src: []const u8, i: usize, key: []const u8, diag: *Diagnostic) Error!Evaluated {
    const q = try std.fmt.allocPrint(a, "from t | derive __v = ({s})", .{src});
    var qd: query.Diagnostic = .{};
    const tree = query.parse(a, q, &qd) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(a, diag, i, key, "{s}", .{qd.message}),
    };
    const Cat = struct {
        s: query.types.Schema,
        fn resolve(ctx: *anyopaque, _: []const u8) ?query.types.Schema {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.s;
        }
    };
    var cat: Cat = .{ .s = try t.schema(a) };
    const p = query.plan.plan(a, &tree, .{ .ctx = &cat, .resolve = Cat.resolve }, &qd) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(a, diag, i, key, "{s}", .{qd.message}),
    };
    const expr = for (p.stages) |st| {
        if (st == .derive) break st.derive[0].expr;
    } else return fail(a, diag, i, key, "not an expression", .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var e: ev.Eval = .init(gpa, a);
    defer e.deinit();
    const out = try a.alloc(Lit, t.rows);
    const row = try arena.allocator().alloc(Lit, t.names.items.len);
    for (out, 0..) |*o, r| {
        for (row, t.cols.items) |*x, col| x.* = col[r];
        o.* = try e.eval(expr, row);
    }
    return .{ .ty = expr.ty, .values = out };
}

/// Bins of a numeric field: `as` holds each bin's start, `as_end` its end.
pub fn binColumn(a: Allocator, t: *Table, field: []const u8, maxbins: u32, as: []const u8, i: usize, diag: *Diagnostic) Error!void {
    const col = t.column(field) orelse return missing(a, t, diag, i, "bin", field);
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    for (col) |v| if (toNum(v)) |x| {
        lo = @min(lo, x);
        hi = @max(hi, x);
    };
    const start = try a.alloc(Lit, t.rows);
    const end = try a.alloc(Lit, t.rows);
    if (!(lo <= hi)) {
        @memset(start, .null_);
        @memset(end, .null_);
    } else {
        const step = binStep(lo, hi, maxbins);
        for (col, start, end) |v, *s, *e| {
            const x = toNum(v) orelse {
                s.* = .null_;
                e.* = .null_;
                continue;
            };
            const b = @floor(x / step) * step;
            s.* = .{ .float = b };
            e.* = .{ .float = b + step };
        }
    }
    try t.put(a, as, .float, start);
    try t.put(a, try std.fmt.allocPrint(a, "{s}_end", .{as}), .float, end);
}

/// A nice bin width giving at most `maxbins` bins over `[lo, hi]`.
pub fn binStep(lo: f64, hi: f64, maxbins: u32) f64 {
    const span = if (hi > lo) hi - lo else @max(@abs(lo), 1);
    var step = ticks.niceStep(span / @as(f64, @floatFromInt(@max(1, maxbins))))[0];
    // The last value lands in a bin of its own when hi is a multiple.
    while (@floor(hi / step) - @floor(lo / step) + 1 > @as(f64, @floatFromInt(maxbins)) + 1e-9) step = ticks.niceStep(step * 1.0001)[0];
    return step;
}

fn timeUnitColumn(a: Allocator, t: *Table, field: []const u8, unit: spec.TimeUnit, as: []const u8, zone: ticks.Zone, i: usize, diag: *Diagnostic) Error!void {
    const col = t.column(field) orelse return missing(a, t, diag, i, "timeUnit", field);
    const out = try a.alloc(Lit, t.rows);
    for (col, out) |v, *o| o.* = if (toTime(v)) |ms| .{ .datetime = truncate(ms, unit, zone) } else .null_;
    try t.put(a, as, .datetime, out);
}

/// Groups by `groupby` (in first-row order) and computes `ops`.
pub fn aggregate(a: Allocator, t: *const Table, groupby: []const []const u8, ops: []const spec.AggOp, i: usize, diag: *Diagnostic) Error!Table {
    const keys = try a.alloc([]const Lit, groupby.len);
    for (groupby, keys) |g, *k| k.* = t.column(g) orelse return missing(a, t, diag, i, "groupby", g);
    const inputs = try a.alloc(?[]const Lit, ops.len);
    for (ops, inputs) |op, *in| in.* = if (op.field) |f| t.column(f) orelse return missing(a, t, diag, i, "aggregate", f) else null;

    // Group ids by key hash (collisions resolved by comparing keys).
    var groups: std.ArrayListUnmanaged(u32) = .empty; // first row of each group
    var of_row = try a.alloc(u32, t.rows);
    var map: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(u32)) = .empty;
    for (0..t.rows) |r| {
        var h: u64 = 0x5EED;
        for (keys) |k| h = ev.hashValue(k[r], h);
        const gop = try map.getOrPut(a, h);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const g = for (gop.value_ptr.items) |cand| {
            const first = groups.items[cand];
            const same = for (keys) |k| {
                if (!ev.sameKey(k[first], k[r])) break false;
            } else true;
            if (same) break cand;
        } else blk: {
            const id: u32 = @intCast(groups.items.len);
            try groups.append(a, @intCast(r));
            try gop.value_ptr.append(a, id);
            break :blk id;
        };
        of_row[r] = g;
    }
    const n = groups.items.len;
    var out: Table = .{ .rows = n };
    for (groupby, keys, 0..) |g, k, gi| {
        const vals = try a.alloc(Lit, n);
        for (vals, groups.items) |*v, first| v.* = k[first];
        try out.put(a, g, t.types.items[t.find(groupby[gi]).?], vals);
    }
    // Rows of each group, for medians and distinct counts.
    var members = try a.alloc(std.ArrayListUnmanaged(u32), n);
    for (members) |*m| m.* = .empty;
    for (of_row, 0..) |g, r| try members[g].append(a, @intCast(r));
    for (ops, inputs) |op, in| {
        const vals = try a.alloc(Lit, n);
        for (vals, members) |*v, m| v.* = try reduce(a, op.op, in, m.items);
        const ty: Type = if (op.op == .count or op.op == .distinct) .int else if ((op.op == .min or op.op == .max) and in != null and t.types.items[t.find(op.field.?).?].temporal()) .datetime else .float;
        try out.put(a, op.as, ty, vals);
    }
    return out;
}

/// One aggregate over the rows `rows` of `col` (null for count of rows).
pub fn reduce(a: Allocator, op: spec.Aggregate, col: ?[]const Lit, rows: []const u32) !Lit {
    const c = col orelse return .{ .int = @intCast(rows.len) };
    switch (op) {
        .count => {
            var k: i64 = 0;
            for (rows) |r| k += @intFromBool(c[r] != .null_);
            return .{ .int = k };
        },
        .distinct => {
            var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
            for (rows) |r| if (c[r] != .null_) try seen.put(a, ev.hashValue(c[r], 1), {});
            return .{ .int = seen.count() };
        },
        .sum, .mean => {
            var s: f64 = 0;
            var k: usize = 0;
            for (rows) |r| if (toNum(c[r])) |x| {
                s += x;
                k += 1;
            };
            if (op == .mean) return if (k == 0) .null_ else .{ .float = s / @as(f64, @floatFromInt(k)) };
            return .{ .float = s };
        },
        .min, .max => {
            var best: ?Lit = null;
            for (rows) |r| {
                const v = c[r];
                if (v == .null_) continue;
                if (best) |b| {
                    const o = ev.order(v, b) orelse continue;
                    if ((op == .min and o == .lt) or (op == .max and o == .gt)) best = v;
                } else best = v;
            }
            const b = best orelse return .null_;
            return if (b == .date or b == .datetime) .{ .datetime = toTime(b).? } else if (toNum(b)) |x| .{ .float = x } else b;
        },
        .median => {
            var xs: std.ArrayListUnmanaged(f64) = .empty;
            for (rows) |r| if (toNum(c[r])) |x| try xs.append(a, x);
            if (xs.items.len == 0) return .null_;
            std.mem.sort(f64, xs.items, {}, std.sort.asc(f64));
            const m = xs.items.len / 2;
            return .{ .float = if (xs.items.len % 2 == 1) xs.items[m] else (xs.items[m - 1] + xs.items[m]) / 2 };
        },
    }
}

fn fold(a: Allocator, t: *const Table, fields: []const []const u8, as: [2][]const u8, i: usize, diag: *Diagnostic) Error!Table {
    const cols = try a.alloc([]const Lit, fields.len);
    var vty: Type = .null_;
    for (fields, cols) |f, *c| {
        const idx = t.find(f) orelse return missing(a, t, diag, i, "fold", f);
        c.* = t.cols.items[idx];
        const ty = t.types.items[idx];
        vty = if (vty == .null_) ty else Type.unify(vty, ty) orelse .string;
    }
    const n = t.rows * fields.len;
    var out: Table = .{ .rows = n };
    for (t.names.items, t.types.items, t.cols.items) |name, ty, col| {
        const skip = for (fields) |f| {
            if (std.mem.eql(u8, f, name)) break true;
        } else false;
        if (skip) continue;
        const vals = try a.alloc(Lit, n);
        for (0..t.rows) |r| for (0..fields.len) |k| {
            vals[r * fields.len + k] = col[r];
        };
        try out.put(a, name, ty, vals);
    }
    const keys = try a.alloc(Lit, n);
    const values = try a.alloc(Lit, n);
    for (0..t.rows) |r| for (fields, cols, 0..) |f, c, k| {
        keys[r * fields.len + k] = .{ .string = f };
        const v = c[r];
        values[r * fields.len + k] = if (vty == .string and v != .string and v != .null_) .{ .string = try litText(a, v) } else ev.coerce(v, vty);
    };
    try out.put(a, as[0], .string, keys);
    try out.put(a, as[1], vty, values);
    return out;
}

test {
    std.testing.refAllDecls(@This());
}
