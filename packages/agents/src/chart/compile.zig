//! Compiling a chart (E13.F07.S01.T03): the spec's data through its
//! transforms and the encodings' own aggregate, bin and timeUnit, then
//! scales, axes with nice ticks, the legend, the layout, and every mark
//! as pixel geometry ready for `render` and `hitTest`.

const std = @import("std");
const spec = @import("spec.zig");
const transform = @import("transform.zig");
const scale_mod = @import("scale.zig");
const ticks = @import("ticks.zig");
const layout = @import("layout.zig");
const decimate = @import("decimate.zig");
const hit = @import("hit.zig");
const query = @import("../data/query/root.zig");
const tz = @import("../sched/tz.zig");

const Allocator = std.mem.Allocator;
const Lit = query.plan.Lit;
const Table = transform.Table;
const Scale = scale_mod.Scale;
const Rgb = scale_mod.Rgb;
const Box = layout.Box;
const ev = query.expr_eval;

pub const Error = error{ InvalidChart, OutOfMemory };

/// Inside: label writers fail only when allocating fails.
const E = Error || error{WriteFailed};

pub const Diagnostic = struct { message: []const u8 = "" };

/// Where `artifact` and `path` data come from (inline values need none).
pub const DataSource = struct {
    ctx: *anyopaque,
    load: *const fn (ctx: *anyopaque, a: Allocator, data: *const spec.Data) anyerror!Table,
};

pub const Options = struct {
    /// The size when the spec has no width or height (the pane's).
    size: [2]f32 = .{ 600, 320 },
    /// The zone of `"zone": "local"` scales (null: UTC).
    zone: ?*const tz.TimeZone = null,
    palette: []const Rgb = &scale_mod.default_palette,
    ramp: [2]Rgb = scale_mod.default_ramp,
    measure: layout.Measure = .{},
    style: layout.Style = .{},
    source: ?DataSource = null,
};

pub const Tick = struct { pos: f32, label: []const u8, show: bool = true };

pub const Axis = struct {
    scale: Scale,
    ticks: []const Tick,
    title: ?[]const u8,
    grid: bool,
    labels: bool,
};

pub const LegendEntry = struct { label: []const u8, color: Rgb, shape: Shape = .square };

pub const Legend = struct {
    title: []const u8,
    box: Box,
    entries: []const LegendEntry = &.{},
    columns: u32 = 1,
    rows_per_column: u32 = 1,
    column_w: f32 = 0,
    /// A sequential colour legend: the ramp and its end labels.
    gradient: ?struct { ramp: [2]Rgb, lo: []const u8, hi: []const u8 } = null,
};

pub const Shape = enum { circle, square, diamond, triangle_up, triangle_down, cross };

pub const Item = struct {
    color: Rgb,
    opacity: f32 = 1,
    geom: Geom,
};

pub const Geom = union(enum) {
    rect: Box,
    /// NaN points break the line.
    line: struct { points: []const [2]f32, width: f32 },
    area: struct { top: []const [2]f32, base: []const [2]f32 },
    point: struct { x: f32, y: f32, size: f32, shape: Shape, filled: bool },
    rule: struct { x0: f32, y0: f32, x1: f32, y1: f32, width: f32 },
    text: struct { x: f32, y: f32, text: []const u8, size: f32 },
};

pub const TipField = struct { label: []const u8, col: usize, temporal: bool };

pub const CompiledChart = struct {
    width: f32,
    height: f32,
    title: ?[]const u8,
    plot: Box,
    x: ?Axis = null,
    y: ?Axis = null,
    /// The x axis runs along the left (horizontal bars put categories
    /// on y) — y is always the vertical axis.
    legend: ?Legend = null,
    items: []const Item = &.{},
    /// Points were sampled (a badge says so).
    sampled: bool = false,
    style: layout.Style,
    table: Table,
    tips: []const TipField = &.{},
    targets: []const hit.Target = &.{},
    index: hit.Index = .{},
    zone: ticks.Zone = .utc,
};

/// Channels as resolved columns of the compiled table.
const Chan = struct {
    def: spec.FieldDef,
    /// The column it reads, and a second one (a bin's end).
    name: ?[]const u8 = null,
    name2: ?[]const u8 = null,
    col: ?usize = null,
    col2: ?usize = null,

    fn bind(x: *Chan, t: *const Table) void {
        x.col = if (x.name) |n| t.find(n) else null;
        x.col2 = if (x.name2) |n| t.find(n) else null;
    }

    fn values(c: Chan, t: *const Table) ?[]const Lit {
        return if (c.col) |i| t.cols.items[i] else null;
    }
};

const Ctx = struct {
    a: Allocator,
    gpa: Allocator,
    s: *const spec.ChartSpec,
    o: *const Options,
    diag: *Diagnostic,
    zone: ticks.Zone,

    fn fail(c: *Ctx, comptime fmt: []const u8, args: anytype) Error {
        c.diag.message = std.fmt.allocPrint(c.a, fmt, args) catch return error.OutOfMemory;
        return error.InvalidChart;
    }
};

pub fn compile(a: Allocator, gpa: Allocator, s: *const spec.ChartSpec, o: Options, diag: *Diagnostic) Error!CompiledChart {
    return compileInner(a, gpa, s, o, diag) catch |e| switch (e) {
        error.WriteFailed => error.OutOfMemory,
        else => |x| x,
    };
}

fn compileInner(a: Allocator, gpa: Allocator, s: *const spec.ChartSpec, o: Options, diag: *Diagnostic) E!CompiledChart {
    var c: Ctx = .{ .a = a, .gpa = gpa, .s = s, .o = &o, .diag = diag, .zone = .utc };
    // A "local" scale anywhere puts the chart in the app's zone.
    inline for (channel_names) |n| if (@field(s.encoding, n)) |fd| if (fd.scale.zone == .local) {
        c.zone = .{ .tz = o.zone };
    };
    var t = try loadData(&c);
    {
        var td: transform.Diagnostic = .{};
        transform.apply(a, gpa, &t, s.transform, c.zone, &td) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTransform => return c.fail("{s}", .{td.message}),
        };
    }
    var ch = try resolveChannels(&c, &t);
    return build(&c, &t, &ch);
}

fn loadData(c: *Ctx) E!Table {
    switch (c.s.data) {
        .values => |rows| return transform.fromJson(c.a, rows),
        else => {
            const src = c.o.source orelse return c.fail("data: {s} data needs a data source", .{@tagName(c.s.data)});
            return src.load(src.ctx, c.a, &c.s.data) catch |e| switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => c.fail("data: could not load ({s})", .{@errorName(e)}),
            };
        },
    }
}

const channel_names = [_][]const u8{ "x", "y", "x2", "y2", "color", "size", "shape", "opacity", "text" };

const Channels = struct {
    x: ?Chan = null,
    y: ?Chan = null,
    x2: ?Chan = null,
    y2: ?Chan = null,
    color: ?Chan = null,
    size: ?Chan = null,
    shape: ?Chan = null,
    opacity: ?Chan = null,
    text: ?Chan = null,
    detail: []Chan = &.{},
    tooltip: []Chan = &.{},
};

/// Applies the channels' timeUnit, bin and aggregate, and finds their
/// columns.
fn resolveChannels(c: *Ctx, t: *Table) E!Channels {
    const e = &c.s.encoding;
    // Every named field must exist before anything is derived from it.
    inline for (channel_names) |n| if (@field(e, n)) |fd| if (fd.field) |f| {
        if (t.find(f) == null) return c.fail("encoding.{s}.field: unknown field `{s}`; fields: {s}", .{ n, f, try transform.fieldList(c.a, t) });
    };
    for ([_][]const spec.FieldDef{ e.tooltip, e.detail }, [_][]const u8{ "tooltip", "detail" }) |list, n| for (list, 0..) |fd, i| if (fd.field) |f| {
        if (t.find(f) == null) return c.fail("encoding.{s}[{d}].field: unknown field `{s}`; fields: {s}", .{ n, i, f, try transform.fieldList(c.a, t) });
    };

    var ch: Channels = .{};
    inline for (channel_names) |n| if (@field(e, n)) |fd| {
        @field(ch, n) = try derive(c, t, fd);
    };
    ch.detail = try c.a.alloc(Chan, e.detail.len);
    for (e.detail, ch.detail) |fd, *d| d.* = try derive(c, t, fd);
    ch.tooltip = try c.a.alloc(Chan, e.tooltip.len);
    for (e.tooltip, ch.tooltip) |fd, *d| d.* = try derive(c, t, fd);

    // A binned position spans its bin unless the spec says otherwise.
    if (ch.x) |x| if (x.def.bin != null and ch.x2 == null) {
        ch.x2 = .{ .def = x.def, .name = x.name2 };
    };
    if (ch.y) |y| if (y.def.bin != null and ch.y2 == null) {
        ch.y2 = .{ .def = y.def, .name = y.name2 };
    };

    // Aggregates group by every other field.
    var any_agg = false;
    inline for (channel_names) |n| if (@field(ch, n)) |x| if (x.def.aggregate != null) {
        any_agg = true;
    };
    for (ch.tooltip) |x| any_agg = any_agg or x.def.aggregate != null;
    if (!any_agg) {
        bindAll(&ch, t);
        return ch;
    }

    var groupby: std.ArrayListUnmanaged([]const u8) = .empty;
    var ops: std.ArrayListUnmanaged(spec.AggOp) = .empty;
    const all = try collect(c.a, &ch);
    for (all) |x| {
        if (x.def.aggregate) |op| {
            const as = aggName(c.a, x.def) catch return error.OutOfMemory;
            const exists = for (ops.items) |q| {
                if (std.mem.eql(u8, q.as, as)) break true;
            } else false;
            if (!exists) try ops.append(c.a, .{ .op = op, .field = x.def.field, .as = as });
        } else for ([_]?[]const u8{ x.name, x.name2 }) |maybe| if (maybe) |name| {
            const exists = for (groupby.items) |g| {
                if (std.mem.eql(u8, g, name)) break true;
            } else false;
            if (!exists) try groupby.append(c.a, name);
        };
    }
    var td: transform.Diagnostic = .{};
    t.* = transform.aggregate(c.a, t, groupby.items, ops.items, 0, &td) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidTransform => return c.fail("{s}", .{td.message}),
    };
    // Aggregated channels read their results.
    inline for (channel_names) |n| if (@field(ch, n)) |*x| if (x.def.aggregate != null) {
        x.name = try aggName(c.a, x.def);
    };
    for (ch.tooltip) |*x| if (x.def.aggregate != null) {
        x.name = try aggName(c.a, x.def);
    };
    bindAll(&ch, t);
    return ch;
}

fn bindAll(ch: *Channels, t: *const Table) void {
    inline for (channel_names) |n| if (@field(ch, n)) |*x| x.bind(t);
    for (ch.detail) |*x| x.bind(t);
    for (ch.tooltip) |*x| x.bind(t);
}

fn collect(a: Allocator, ch: *Channels) ![]Chan {
    var out: std.ArrayListUnmanaged(Chan) = .empty;
    inline for (channel_names) |n| if (@field(ch, n)) |x| try out.append(a, x);
    try out.appendSlice(a, ch.detail);
    try out.appendSlice(a, ch.tooltip);
    return out.items;
}

fn aggName(a: Allocator, d: spec.FieldDef) ![]const u8 {
    const op = d.aggregate.?;
    if (d.field) |f| return std.fmt.allocPrint(a, "{s}_{s}", .{ @tagName(op), f });
    return "count";
}

/// A channel's own timeUnit and bin as new columns.
fn derive(c: *Ctx, t: *Table, fd: spec.FieldDef) E!Chan {
    var ch: Chan = .{ .def = fd };
    if (fd.value != null) return ch;
    const f = fd.field orelse return ch; // count: named after aggregation
    var td: transform.Diagnostic = .{};
    if (fd.time_unit) |u| {
        const as = try std.fmt.allocPrint(c.a, "{s} ({s})", .{ f, @tagName(u) });
        if (t.find(as) == null) {
            const col = t.column(f).?;
            const out = try c.a.alloc(Lit, t.rows);
            for (col, out) |v, *o| o.* = if (transform.toTime(v)) |ms| .{ .datetime = transform.truncate(ms, u, c.zone) } else .null_;
            try t.put(c.a, as, .datetime, out);
        }
        ch.name = as;
        return ch;
    }
    if (fd.bin) |b| {
        const as = try std.fmt.allocPrint(c.a, "{s} (binned)", .{f});
        if (t.find(as) == null) transform.binColumn(c.a, t, f, b.maxbins, as, 0, &td) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTransform => return c.fail("{s}", .{td.message}),
        };
        ch.name = as;
        ch.name2 = try std.fmt.allocPrint(c.a, "{s}_end", .{as});
        return ch;
    }
    ch.name = f;
    return ch;
}

fn isDiscrete(k: scale_mod.Kind) bool {
    return k == .band or k == .point;
}

/// The scale kind of a position channel under `mark`.
fn posKind(d: spec.FieldDef, mark: spec.Mark) scale_mod.Kind {
    if (d.scale.type) |t| return switch (t) {
        .linear => .linear,
        .log => .log,
        .time => .time,
        .band => .band,
        .point => .point,
    };
    const barlike = mark == .bar or mark == .rect;
    return switch (d.type) {
        .quantitative => .linear,
        .temporal => if ((barlike or mark == .tick) and d.bin == null) .band else .time,
        .nominal, .ordinal => if (barlike) .band else .point,
    };
}

/// A channel's default title.
pub fn defaultTitle(a: Allocator, d: spec.FieldDef) ![]const u8 {
    if (d.title) |t| return t;
    if (d.aggregate) |op| {
        const names = [_][]const u8{ "Count", "Sum", "Mean", "Median", "Min", "Max", "Distinct" };
        if (d.field) |f| return std.fmt.allocPrint(a, "{s} of {s}", .{ names[@intFromEnum(op)], f });
        return "Count of records";
    }
    const f = d.field orelse return "";
    if (d.bin != null) return std.fmt.allocPrint(a, "{s} (binned)", .{f});
    if (d.time_unit) |u| return std.fmt.allocPrint(a, "{s} ({s})", .{ f, @tagName(u) });
    return f;
}

/// Distinct values of a channel in display order.
fn discreteDomain(c: *Ctx, t: *const Table, x: Chan, other: ?Chan) E![]Lit {
    const a = c.a;
    const vals = x.values(t) orelse return &.{};
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    var out: std.ArrayListUnmanaged(Lit) = .empty;
    var sums: std.ArrayListUnmanaged(f64) = .empty;
    const ov = if (other) |o| o.values(t) else null;
    for (vals, 0..) |v, r| {
        if (v == .null_) continue;
        const k = try transform.litText(a, v);
        const gop = try seen.getOrPut(a, k);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(out.items.len);
            try out.append(a, v);
            try sums.append(a, 0);
        }
        if (ov) |o| if (transform.toNum(o[r])) |n| {
            sums.items[gop.value_ptr.*] += n;
        };
    }
    const Item2 = struct { v: Lit, sum: f64, first: u32 };
    const items = try a.alloc(Item2, out.items.len);
    for (items, out.items, sums.items, 0..) |*it, v, sm, i| it.* = .{ .v = v, .sum = sm, .first = @intCast(i) };
    const Sorter = struct {
        fn asc(_: void, l: Item2, r: Item2) bool {
            if (ev.order(l.v, r.v)) |o| return o == .lt;
            return l.first < r.first;
        }
        fn bySum(_: void, l: Item2, r: Item2) bool {
            if (l.sum != r.sum) return l.sum < r.sum;
            return l.first < r.first;
        }
    };
    switch (x.def.sort) {
        .none => {},
        .ascending => std.mem.sort(Item2, items, {}, Sorter.asc),
        .descending => {
            std.mem.sort(Item2, items, {}, Sorter.asc);
            std.mem.reverse(Item2, items);
        },
        .by_x, .by_y => std.mem.sort(Item2, items, {}, Sorter.bySum),
        .by_x_desc, .by_y_desc => {
            std.mem.sort(Item2, items, {}, Sorter.bySum);
            std.mem.reverse(Item2, items);
        },
    }
    for (out.items, items) |*o, it| o.* = it.v;
    return out.items;
}

/// Labels for discrete values: time units at their precision, others
/// as text.
fn discreteLabels(c: *Ctx, d: spec.FieldDef, vals: []const Lit) E![]const []const u8 {
    const out = try c.a.alloc([]const u8, vals.len);
    for (vals, out) |v, *o| {
        var w: std.Io.Writer.Allocating = .init(c.a);
        if (d.type == .temporal) if (transform.toTime(v)) |ms| {
            try timeLabel(&w.writer, ms, d.time_unit, c.zone);
            o.* = w.written();
            continue;
        };
        try writeValue(&w.writer, v, d.format);
        o.* = w.written();
    }
    return out;
}

fn timeLabel(w: *std.Io.Writer, ms: i64, unit: ?spec.TimeUnit, zone: ticks.Zone) std.Io.Writer.Error!void {
    const u = unit orelse return ticks.formatTimestamp(w, ms, zone);
    switch (u) {
        .year => try ticks.formatTime(w, ms, .y1, zone),
        .quarter => {
            const local = zone.toLocal(ms);
            const cd = @import("../data/infer.zig").civilFromDays(@divFloor(local, ticks.ms_day));
            try w.print("Q{d} {d}", .{ (cd.m - 1) / 3 + 1, cd.y });
        },
        .month => {
            try ticks.formatTime(w, ms, .d1, zone);
            // "Mar 1" → "Mar 2026".
            const local = zone.toLocal(ms);
            const cd = @import("../data/infer.zig").civilFromDays(@divFloor(local, ticks.ms_day));
            const buf = w.buffered();
            if (std.mem.lastIndexOfScalar(u8, buf, ' ')) |sp| w.undo(buf.len - sp);
            try w.print(" {d}", .{cd.y});
        },
        .week, .day => try ticks.formatTime(w, ms, .d1, zone),
        .hour => {
            try ticks.formatTime(w, ms, .d1, zone);
            try w.writeByte(' ');
            try ticks.formatTime(w, ms, .h1, zone);
        },
    }
}

/// A cell for labels and tooltips.
fn writeValue(w: *std.Io.Writer, v: Lit, f: spec.Format) std.Io.Writer.Error!void {
    switch (f) {
        .si => if (transform.toNum(v)) |x| if (v == .int or v == .float) return ticks.formatNumber(w, x, ticks.valueDecimals(x), .si),
        .percent => if (v == .int or v == .float) return ticks.formatNumber(w, transform.toNum(v) orelse 0, ticks.valueDecimals((transform.toNum(v) orelse 0) * 100) + 2, .percent),
        else => {},
    }
    try transform.writeLit(w, v);
}

const Extent = struct {
    lo: f64 = std.math.inf(f64),
    hi: f64 = -std.math.inf(f64),

    fn add(e: *Extent, x: f64) void {
        if (!std.math.isFinite(x)) return;
        e.lo = @min(e.lo, x);
        e.hi = @max(e.hi, x);
    }

    fn empty(e: Extent) bool {
        return !(e.lo <= e.hi);
    }

    fn addCol(e: *Extent, vals: ?[]const Lit, kind: scale_mod.Kind) void {
        for (vals orelse return) |v| {
            if (kind == .time) {
                if (transform.toTime(v)) |ms| e.add(@floatFromInt(ms));
            } else if (transform.toNum(v)) |x| {
                if (kind == .log and x <= 0) continue;
                e.add(x);
            }
        }
    }
};

/// A continuous domain: the spec's, or the extent made nice.
fn contDomain(d: spec.FieldDef, kind: scale_mod.Kind, e_in: Extent, zero_default: bool, target: u8) [2]f64 {
    if (d.scale.domain) |dom| return dom;
    var e = e_in;
    if (e.empty()) return if (kind == .log) .{ 1, 10 } else if (kind == .time) .{ 0, @floatFromInt(ticks.ms_day) } else .{ 0, 1 };
    switch (kind) {
        .linear => {
            if (d.scale.zero orelse zero_default) {
                e.lo = @min(e.lo, 0);
                e.hi = @max(e.hi, 0);
            }
            if (e.lo == e.hi) return ticks.niceDomain(e.lo, e.hi, target);
            return ticks.niceDomain(e.lo, e.hi, target);
        },
        .log => return .{ std.math.pow(f64, 10, @floor(std.math.log10(e.lo))), std.math.pow(f64, 10, @max(@ceil(std.math.log10(e.hi)), @floor(std.math.log10(e.lo)) + 1)) },
        .time => {
            if (e.lo == e.hi) return .{ e.lo - @as(f64, @floatFromInt(ticks.ms_day)), e.hi + @as(f64, @floatFromInt(ticks.ms_day)) };
            return .{ e.lo, e.hi };
        },
        else => unreachable,
    }
}

const Built = struct {
    kind: scale_mod.Kind,
    /// Discrete values and their labels.
    values: []Lit = &.{},
    labels: []const []const u8 = &.{},
    dom: [2]f64 = .{ 0, 1 },
};

fn formatOf(d: spec.FieldDef) spec.Format {
    if (d.axis) |ax| if (ax.format != .auto) return ax.format;
    return d.format;
}

/// An axis's ticks over a finished scale.
fn makeTicks(c: *Ctx, sc: *const Scale, b: Built, d: spec.FieldDef, target: u8, vertical: bool) E![]Tick {
    const a = c.a;
    const st = c.o.style;
    var out: std.ArrayListUnmanaged(Tick) = .empty;
    switch (sc.kind) {
        .band, .point => for (b.labels, 0..) |l, i| try out.append(a, .{ .pos = sc.center(@intCast(i)), .label = l }),
        .linear => {
            const ts = ticks.niceTicks(sc.d0, sc.d1, target);
            const f: ticks.NumFormat = switch (formatOf(d)) {
                .auto => ticks.autoFormat(ts),
                .si => .si,
                .percent => .percent,
                .plain => .fixed,
            };
            for (0..ts.count) |i| {
                const v = ts.value(i);
                var w: std.Io.Writer.Allocating = .init(a);
                try ticks.formatNumber(&w.writer, v, ts.decimals, f);
                try out.append(a, .{ .pos = sc.mapNum(v), .label = w.written() });
            }
        },
        .log => for (try ticks.logTicks(a, sc.d0, sc.d1, target)) |v| {
            var w: std.Io.Writer.Allocating = .init(a);
            if (v >= 1e4) try ticks.formatNumber(&w.writer, v, 0, .si) else try ticks.formatValue(&w.writer, v);
            try out.append(a, .{ .pos = sc.mapNum(v), .label = w.written() });
        },
        .time => {
            const tt = try ticks.timeTicks(a, @intFromFloat(sc.d0), @intFromFloat(sc.d1), target, c.zone);
            for (tt.values) |ms| {
                var w: std.Io.Writer.Allocating = .init(a);
                try ticks.formatTime(&w.writer, ms, tt.step, c.zone);
                try out.append(a, .{ .pos = sc.mapNum(@floatFromInt(ms)), .label = w.written() });
            }
        },
    }
    // Drop every other label until they fit.
    if (out.items.len > 1) {
        const centers = try a.alloc(f32, out.items.len);
        const widths = try a.alloc(f32, out.items.len);
        for (out.items, centers, widths) |tk, *ce, *wi| {
            ce.* = tk.pos;
            wi.* = if (vertical) st.font_size * 1.2 else c.o.measure.width(tk.label, st.font_size, false);
        }
        const stride = ticks.labelStride(centers, widths, if (vertical) 2 else 6);
        for (out.items, 0..) |*tk, i| tk.show = i % stride == 0;
    }
    return out.items;
}

fn build(c: *Ctx, t: *Table, ch: *Channels) E!CompiledChart {
    const a = c.a;
    const s = c.s;
    const st = c.o.style;
    const mark = s.mark.type;
    const W = s.width orelse c.o.size[0];
    const H = s.height orelse c.o.size[1];
    var out: CompiledChart = .{ .width = W, .height = H, .title = s.title, .plot = .{}, .style = st, .table = t.*, .zone = c.zone };

    const point_like = mark == .point or mark == .circle or mark == .square or mark == .text or mark == .tick;
    if (point_like and t.rows > decimate.max_points) {
        t.* = try t.select(a, try decimate.stratified(a, t.rows, decimate.max_points, 0x5A3D));
        out.sampled = true;
    }

    var xb: ?Built = if (ch.x) |x| .{ .kind = posKind(x.def, mark) } else null;
    var yb: ?Built = if (ch.y) |y| .{ .kind = posKind(y.def, mark) } else null;
    const horizontal = yb != null and isDiscrete(yb.?.kind) and (xb == null or !isDiscrete(xb.?.kind));

    // Discrete domains first (stacking and colour need them).
    if (xb) |*b| if (isDiscrete(b.kind)) {
        b.values = try discreteDomain(c, t, ch.x.?, ch.y);
        b.labels = try discreteLabels(c, ch.x.?.def, b.values);
    };
    if (yb) |*b| if (isDiscrete(b.kind)) {
        b.values = try discreteDomain(c, t, ch.y.?, ch.x);
        b.labels = try discreteLabels(c, ch.y.?.def, b.values);
    };

    // Colour.
    var color: scale_mod.ColorScale = .{ .constant = if (s.mark.color) |hex| spec.parseHex(hex).? else st.mark };
    var color_vals: []Lit = &.{};
    if (ch.color) |cc| if (cc.col != null) {
        if (cc.def.type == .quantitative) {
            var e: Extent = .{};
            e.addCol(cc.values(t), .linear);
            color = .{ .sequential = .{ .d0 = if (e.empty()) 0 else e.lo, .d1 = if (e.empty()) 1 else e.hi, .ramp = c.o.ramp } };
        } else {
            color_vals = try discreteDomain(c, t, cc, null);
            color = .{ .categorical = .{ .scale = try scale_mod.discrete(a, .band, color_vals, 0, 1), .palette = c.o.palette } };
        }
    } else if (cc.def.value) |v| if (v == .string) if (spec.parseHex(v.string)) |k| {
        color = .{ .constant = k };
    };

    // Stacking (in data units along the measure axis).
    const measure: ?Chan = if (horizontal) ch.x else ch.y;
    const along: ?Chan = if (horizontal) ch.y else ch.x;
    const stack_mode = s.mark.stack orelse .stacked;
    const stacking = (mark == .bar or mark == .area) and stack_mode == .stacked and measure != null and along != null and
        measure.?.def.type == .quantitative and measure.?.def.bin == null and (if (horizontal) ch.x2 == null else ch.y2 == null);
    var stack0: []f64 = &.{};
    var stack1: []f64 = &.{};
    if (stacking) {
        stack0 = try a.alloc(f64, t.rows);
        stack1 = try a.alloc(f64, t.rows);
        const mv = measure.?.values(t).?;
        const av = along.?.values(t).?;
        const order = try a.alloc(u32, t.rows);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        const cv = if (ch.color) |cc| cc.values(t) else null;
        const Key = struct { ci: u32, row: u32 };
        const keys = try a.alloc(Key, t.rows);
        for (keys, 0..) |*k, r| {
            var ci: u32 = 0;
            if (cv) |vals| if (color == .categorical) {
                ci = color.categorical.scale.index.get(try transform.litText(a, vals[r])) orelse 0;
            };
            k.* = .{ .ci = ci, .row = @intCast(r) };
        }
        std.mem.sort(Key, keys, {}, struct {
            fn lt(_: void, l: Key, r: Key) bool {
                return if (l.ci != r.ci) l.ci < r.ci else l.row < r.row;
            }
        }.lt);
        var pos: std.StringHashMapUnmanaged(f64) = .empty;
        var neg: std.StringHashMapUnmanaged(f64) = .empty;
        for (keys) |k| {
            const r = k.row;
            const v = transform.toNum(mv[r]) orelse {
                stack0[r] = std.math.nan(f64);
                stack1[r] = std.math.nan(f64);
                continue;
            };
            const key = try transform.litText(a, av[r]);
            const m = if (v >= 0) &pos else &neg;
            const gop = try m.getOrPut(a, key);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            stack0[r] = gop.value_ptr.*;
            gop.value_ptr.* += v;
            stack1[r] = gop.value_ptr.*;
        }
    }

    // Continuous domains.
    const est_w = W * 0.8;
    const est_h = H * 0.7;
    const x_target: u8 = @intFromFloat(std.math.clamp(est_w / 80, 2, 12));
    const y_target: u8 = @intFromFloat(std.math.clamp(est_h / 40, 2, 10));
    inline for (.{ "x", "y" }) |name| {
        const b_opt = if (comptime std.mem.eql(u8, name, "x")) &xb else &yb;
        if (b_opt.*) |*b| if (!isDiscrete(b.kind)) {
            const chn = @field(ch, name).?;
            const ch2 = @field(ch, name ++ "2");
            var e: Extent = .{};
            const is_measure = (comptime std.mem.eql(u8, name, "x")) == horizontal;
            if (stacking and is_measure) {
                for (stack0) |v| e.add(v);
                for (stack1) |v| e.add(v);
            } else {
                e.addCol(chn.values(t), b.kind);
                if (ch2) |c2| e.addCol(c2.values(t), b.kind);
            }
            const zero = (mark == .bar or mark == .area) and is_measure and chn.def.bin == null;
            b.dom = contDomain(chn.def, b.kind, e, zero, if (comptime std.mem.eql(u8, name, "x")) x_target else y_target);
        };
    }

    // Legend.
    var legend: ?Legend = null;
    if (ch.color) |cc| if (cc.col != null and cc.def.legend) {
        const title = try defaultTitle(a, cc.def);
        switch (color) {
            .categorical => |cat| {
                const labels = try discreteLabels(c, cc.def, color_vals);
                const entries = try a.alloc(LegendEntry, labels.len);
                var lw: f32 = 0;
                const shape: Shape = if (mark == .point or mark == .circle) .circle else if (mark == .line or mark == .rule) .square else .square;
                for (entries, labels, 0..) |*en, l, i| {
                    en.* = .{ .label = l, .color = cat.palette[i % cat.palette.len], .shape = shape };
                    lw = @max(lw, c.o.measure.width(l, st.font_size, false));
                }
                const lb = layout.legendBox(st, entries.len, lw, c.o.measure.width(title, st.font_size, true), H - 2 * st.padding - (if (s.title != null) st.title_size + 8 else 0));
                legend = .{ .title = title, .box = lb.box, .entries = entries, .columns = lb.columns, .rows_per_column = lb.rows_per_column, .column_w = lb.column_w };
            },
            .sequential => |sq| {
                var lo_w: std.Io.Writer.Allocating = .init(a);
                var hi_w: std.Io.Writer.Allocating = .init(a);
                try ticks.formatValue(&lo_w.writer, sq.d0);
                try ticks.formatValue(&hi_w.writer, sq.d1);
                const w = @max(c.o.measure.width(title, st.font_size, true), 60);
                legend = .{ .title = title, .box = .{ .w = w, .h = st.font_size + 6 + 12 + st.font_size + 4 }, .gradient = .{ .ramp = sq.ramp, .lo = lo_w.written(), .hi = hi_w.written() } };
            },
            .constant => {},
        }
    };

    // Layout: title, legend, axis margins, plot.
    const pad = st.padding;
    var top = pad;
    if (s.title != null) top += st.title_size + 8;
    var right = pad + 6;
    if (legend) |*lg| {
        lg.box.x = W - pad - lg.box.w;
        lg.box.y = top;
        right = pad + lg.box.w + 16;
    }
    const x_title: ?[]const u8 = if (ch.x) |x| if (x.def.axis) |ax| ax.title orelse try defaultTitle(a, x.def) else null else null;
    const y_title: ?[]const u8 = if (ch.y) |y| if (y.def.axis) |ax| ax.title orelse try defaultTitle(a, y.def) else null else null;
    var bottom = pad;
    if (xb != null and ch.x.?.def.axis != null) {
        bottom += st.font_size + st.tick_size + st.label_gap + 2;
        if (x_title) |xt| if (xt.len > 0) {
            bottom += st.axis_title_size + 6;
        };
    }
    // Y labels need the y ticks; a first pass over an estimated scale.
    var left = pad;
    if (yb) |b| if (ch.y.?.def.axis != null) {
        var tmp: Scale = if (isDiscrete(b.kind)) try scale_mod.discrete(a, b.kind, b.values, H - bottom, top) else .{ .kind = b.kind, .d0 = b.dom[0], .d1 = b.dom[1], .r0 = H - bottom, .r1 = top, .zone = c.zone };
        _ = &tmp;
        var maxw: f32 = 0;
        for (try makeTicks(c, &tmp, b, ch.y.?.def, y_target, true)) |tk| maxw = @max(maxw, c.o.measure.width(tk.label, st.font_size, false));
        left += maxw + st.tick_size + st.label_gap;
        if (y_title) |yt| if (yt.len > 0) {
            left += st.axis_title_size + 6;
        };
    };
    if (xb) |b| if (!isDiscrete(b.kind)) {
        // Room for the last x label's overhang.
        right = @max(right, pad + 12);
    };
    out.plot = .{ .x = left, .y = top, .w = @max(10, W - left - right), .h = @max(10, H - top - bottom) };
    const plot = out.plot;
    out.legend = legend;

    // Final scales and axes.
    var xs: ?Scale = null;
    var ys: ?Scale = null;
    if (xb) |b| {
        xs = if (isDiscrete(b.kind)) try scale_mod.discrete(a, b.kind, b.values, plot.x, plot.right()) else .{ .kind = b.kind, .d0 = b.dom[0], .d1 = b.dom[1], .r0 = plot.x, .r1 = plot.right(), .zone = c.zone };
        const d = ch.x.?.def;
        if (d.axis) |ax| out.x = .{
            .scale = xs.?,
            .ticks = try makeTicks(c, &xs.?, b, d, @intFromFloat(std.math.clamp(plot.w / 80, 2, 12)), false),
            .title = x_title,
            .grid = ax.grid orelse !isDiscrete(b.kind),
            .labels = ax.labels,
        };
    }
    if (yb) |b| {
        ys = if (isDiscrete(b.kind)) try scale_mod.discrete(a, b.kind, b.values, plot.y, plot.bottom()) else .{ .kind = b.kind, .d0 = b.dom[0], .d1 = b.dom[1], .r0 = plot.bottom(), .r1 = plot.y, .zone = c.zone };
        const d = ch.y.?.def;
        if (d.axis) |ax| out.y = .{
            .scale = ys.?,
            .ticks = try makeTicks(c, &ys.?, b, d, @intFromFloat(std.math.clamp(plot.h / 40, 2, 10)), true),
            .title = y_title,
            .grid = ax.grid orelse !isDiscrete(b.kind),
            .labels = ax.labels,
        };
    }

    var m: Marks = .{ .c = c, .t = t, .ch = ch, .xs = if (xs) |*x| x else null, .ys = if (ys) |*y| y else null, .color = &color, .plot = plot, .horizontal = horizontal, .stack0 = stack0, .stack1 = stack1, .stacking = stacking, .color_n = @intCast(color_vals.len) };
    try m.prepare();
    switch (mark) {
        .line, .area => try m.series(mark),
        else => for (0..t.rows) |r| try m.row(mark, @intCast(r)),
    }
    out.items = m.items.items;
    out.targets = m.targets.items;
    out.index = try hit.Index.build(a, out.targets, .{ .x = 0, .y = 0, .w = W, .h = H }, 32);
    out.tips = try tipFields(c, t, ch);
    out.table = t.*;
    return out;
}

fn tipFields(c: *Ctx, t: *const Table, ch: *const Channels) E![]TipField {
    var out: std.ArrayListUnmanaged(TipField) = .empty;
    if (ch.tooltip.len > 0) {
        for (ch.tooltip) |x| if (x.col) |col| try out.append(c.a, .{ .label = try defaultTitle(c.a, x.def), .col = col, .temporal = x.def.type == .temporal });
        return out.items;
    }
    var list: std.ArrayListUnmanaged(Chan) = .empty;
    inline for (.{ "x", "y", "color", "size", "shape", "opacity", "text" }) |n| if (@field(ch, n)) |x| try list.append(c.a, x);
    try list.appendSlice(c.a, ch.detail);
    for (list.items) |x| {
        const col = x.col orelse continue;
        const dup = for (out.items) |o| {
            if (o.col == col) break true;
        } else false;
        if (dup) continue;
        try out.append(c.a, .{ .label = try defaultTitle(c.a, x.def), .col = col, .temporal = x.def.type == .temporal });
        if (x.col2) |c2| if (x.def.bin != null) try out.append(c.a, .{ .label = try std.fmt.allocPrint(c.a, "{s} (end)", .{try defaultTitle(c.a, x.def)}), .col = c2, .temporal = false });
    }
    _ = t;
    return out.items;
}

const shapes = [_]Shape{ .circle, .square, .diamond, .triangle_up, .triangle_down, .cross };

const Marks = struct {
    c: *Ctx,
    t: *const Table,
    ch: *const Channels,
    xs: ?*const Scale,
    ys: ?*const Scale,
    color: *const scale_mod.ColorScale,
    plot: Box,
    horizontal: bool,
    stack0: []const f64,
    stack1: []const f64,
    stacking: bool,
    color_n: u32,
    items: std.ArrayListUnmanaged(Item) = .empty,
    targets: std.ArrayListUnmanaged(hit.Target) = .empty,
    /// Bar thickness on a continuous axis without x2/y2.
    bar_w: f32 = 0,
    size_ext: Extent = .{},
    opacity_ext: Extent = .{},
    shape_scale: ?Scale = null,
    /// Rows of each line or area series (while sorting them).
    series_rows: []std.ArrayListUnmanaged(u32) = &.{},

    fn prepare(m: *Marks) E!void {
        const a = m.c.a;
        if (m.ch.size) |sz| m.size_ext.addCol(sz.values(m.t), .linear);
        if (m.ch.opacity) |op| m.opacity_ext.addCol(op.values(m.t), .linear);
        if (m.ch.shape) |sh| if (sh.col != null) {
            m.shape_scale = try scale_mod.discrete(a, .band, try discreteDomain(m.c, m.t, sh, null), 0, 1);
        };
        // Bars on a continuous axis: 80% of the closest spacing.
        const along = if (m.horizontal) m.ys else m.xs;
        const along_ch = if (m.horizontal) m.ch.y else m.ch.x;
        const mk = m.c.s.mark.type;
        if (mk == .bar or mk == .rect or mk == .tick) if (along) |sc| if (sc.continuous()) {
            var at: std.ArrayListUnmanaged(f32) = .empty;
            for (along_ch.?.values(m.t) orelse &.{}) |v| if (try sc.map(a, v)) |p| try at.append(a, p);
            std.mem.sort(f32, at.items, {}, std.sort.asc(f32));
            var gap: f32 = if (m.horizontal) m.plot.h else m.plot.w;
            for (at.items[0..at.items.len -| 1], at.items[@min(1, at.items.len)..]) |p0, p1| if (p1 - p0 > 0.5) {
                gap = @min(gap, p1 - p0);
            };
            m.bar_w = std.math.clamp(gap * 0.8, 1, 60);
        };
    }

    fn colorOf(m: *Marks, r: u32) E!Rgb {
        const cc = m.ch.color orelse return m.color.map(m.c.a, .null_) catch unreachable;
        const vals = cc.values(m.t) orelse return switch (m.color.*) {
            .constant => |k| k,
            else => 0x999999,
        };
        return m.color.map(m.c.a, vals[r]);
    }

    fn opacityOf(m: *Marks, r: u32, default: f32) f32 {
        const s = m.c.s;
        if (m.ch.opacity) |op| {
            if (op.def.value) |v| if (v == .number) return @floatCast(std.math.clamp(v.number, 0, 1));
            if (op.values(m.t)) |vals| if (transform.toNum(vals[r])) |x| {
                const e = m.opacity_ext;
                const tt = if (e.hi > e.lo) (x - e.lo) / (e.hi - e.lo) else 1;
                return @floatCast(0.25 + 0.75 * tt);
            };
        }
        return s.mark.opacity orelse default;
    }

    fn sizeOf(m: *Marks, r: u32, default: f32, lo: f32, hi: f32) f32 {
        if (m.ch.size) |sz| {
            if (sz.def.value) |v| if (v == .number) return @floatCast(v.number);
            if (sz.values(m.t)) |vals| if (transform.toNum(vals[r])) |x| {
                const e = m.size_ext;
                const tt: f32 = @floatCast(if (e.hi > e.lo) (x - e.lo) / (e.hi - e.lo) else 0.5);
                return lo + (hi - lo) * tt;
            };
        }
        return m.c.s.mark.size orelse default;
    }

    /// The position of row `r` on channel `chn` through `sc`: a band's
    /// start (`center` false) or centre, null when it has none.
    fn pos(m: *Marks, sc: ?*const Scale, chn: ?Chan, r: u32, center: bool) E!?f32 {
        const s = sc orelse return null;
        const vals = (chn orelse return null).values(m.t) orelse return null;
        const p = try s.map(m.c.a, vals[r]) orelse return null;
        return if (center and s.kind == .band) p + s.bandwidth() / 2 else p;
    }

    fn baseline(sc: *const Scale) f32 {
        if (sc.kind == .log) return sc.r0;
        return sc.mapNum(std.math.clamp(0, @min(sc.d0, sc.d1), @max(sc.d0, sc.d1)));
    }

    fn add(m: *Marks, it: Item, r: ?u32, box: [4]f32) E!void {
        const idx: u32 = @intCast(m.items.items.len);
        try m.items.append(m.c.a, it);
        if (r) |rw| try m.targets.append(m.c.a, .{ .x0 = box[0], .y0 = box[1], .x1 = box[2], .y1 = box[3], .row = rw, .item = idx });
    }

    fn row(m: *Marks, mark: spec.Mark, r: u32) E!void {
        const ch = m.ch;
        const col = try m.colorOf(r);
        switch (mark) {
            .bar, .rect => {
                const b = try m.barBox(mark, r) orelse return;
                try m.add(.{ .color = col, .opacity = m.opacityOf(r, 1), .geom = .{ .rect = b } }, r, .{ b.x, b.y, b.right(), b.bottom() });
            },
            .point, .circle, .square => {
                const x = (try m.pos(m.xs, ch.x, r, true)) orelse if (ch.x == null) m.plot.x + m.plot.w / 2 else return;
                const y = (try m.pos(m.ys, ch.y, r, true)) orelse if (ch.y == null) m.plot.y + m.plot.h / 2 else return;
                const area = m.sizeOf(r, 30, 16, 400);
                var shape: Shape = if (mark == .square) .square else .circle;
                if (m.shape_scale) |*ss| if (ch.shape.?.values(m.t)) |vals| if (vals[r] != .null_) {
                    shape = shapes[(ss.index.get(try transform.litText(m.c.a, vals[r])) orelse 0) % shapes.len];
                };
                const filled = m.c.s.mark.filled orelse (mark != .point);
                const rad = @sqrt(area / std.math.pi);
                try m.add(.{ .color = col, .opacity = m.opacityOf(r, if (filled) 0.8 else 1), .geom = .{ .point = .{ .x = x, .y = y, .size = area, .shape = shape, .filled = filled } } }, r, .{ x - rad, y - rad, x + rad, y + rad });
            },
            .tick => {
                const thick: f32 = m.c.s.mark.stroke_width orelse 1.5;
                const ys_disc = m.ys != null and !m.ys.?.continuous();
                if (ys_disc or ch.y == null) {
                    const x = (try m.pos(m.xs, ch.x, r, true)) orelse return;
                    const len: f32 = if (m.ys) |s| if (s.kind == .band) s.bandwidth() * 0.75 else 14 else 14;
                    const cy = (try m.pos(m.ys, ch.y, r, true)) orelse m.plot.y + m.plot.h / 2;
                    const b: Box = .{ .x = x - thick / 2, .y = cy - len / 2, .w = thick, .h = len };
                    try m.add(.{ .color = col, .opacity = m.opacityOf(r, 1), .geom = .{ .rect = b } }, r, .{ b.x, b.y, b.right(), b.bottom() });
                } else {
                    const y = (try m.pos(m.ys, ch.y, r, true)) orelse return;
                    const len: f32 = if (m.xs) |s| if (s.kind == .band) s.bandwidth() * 0.75 else 14 else 14;
                    const cx = (try m.pos(m.xs, ch.x, r, true)) orelse m.plot.x + m.plot.w / 2;
                    const b: Box = .{ .x = cx - len / 2, .y = y - thick / 2, .w = len, .h = thick };
                    try m.add(.{ .color = col, .opacity = m.opacityOf(r, 1), .geom = .{ .rect = b } }, r, .{ b.x, b.y, b.right(), b.bottom() });
                }
            },
            .text => {
                const x = (try m.pos(m.xs, ch.x, r, true)) orelse m.plot.x + m.plot.w / 2;
                const y = (try m.pos(m.ys, ch.y, r, true)) orelse m.plot.y + m.plot.h / 2;
                const tc = ch.text.?;
                var w: std.Io.Writer.Allocating = .init(m.c.a);
                if (tc.def.value) |v| switch (v) {
                    .string => |str| try w.writer.writeAll(str),
                    .number => |n| try ticks.formatValue(&w.writer, n),
                } else if (tc.values(m.t)) |vals| {
                    if (vals[r] == .null_) return;
                    if (tc.def.type == .temporal) {
                        if (transform.toTime(vals[r])) |ms| try timeLabel(&w.writer, ms, tc.def.time_unit, m.c.zone) else try writeValue(&w.writer, vals[r], tc.def.format);
                    } else try writeValue(&w.writer, vals[r], tc.def.format);
                }
                const size = m.sizeOf(r, m.c.o.style.font_size, 8, 24);
                const text_col = if (m.ch.color != null) col else m.c.o.style.title;
                const tw = m.c.o.measure.width(w.written(), size, false);
                try m.add(.{ .color = text_col, .opacity = m.opacityOf(r, 1), .geom = .{ .text = .{ .x = x, .y = y, .text = w.written(), .size = size } } }, r, .{ x - tw / 2, y - size / 2, x + tw / 2, y + size / 2 });
            },
            .rule => {
                const width = m.c.s.mark.stroke_width orelse 1;
                var x0 = try m.pos(m.xs, ch.x, r, true);
                var y0 = try m.pos(m.ys, ch.y, r, true);
                var x1 = x0;
                var y1 = y0;
                if (ch.x2 != null) x1 = try m.pos(m.xs, ch.x2, r, true);
                if (ch.y2 != null) y1 = try m.pos(m.ys, ch.y2, r, true);
                if (ch.x == null or (ch.y != null and ch.x2 == null and ch.y2 == null and x0 == null)) {
                    // A horizontal rule across the plot.
                    x0 = m.plot.x;
                    x1 = m.plot.right();
                } else if (ch.y == null) {
                    y0 = m.plot.y;
                    y1 = m.plot.bottom();
                } else if (ch.x2 == null and ch.y2 == null) {
                    return;
                }
                const ax = x0 orelse return;
                const ay = y0 orelse return;
                const bx = x1 orelse return;
                const by = y1 orelse return;
                try m.add(.{ .color = col, .opacity = m.opacityOf(r, 1), .geom = .{ .rule = .{ .x0 = ax, .y0 = ay, .x1 = bx, .y1 = by, .width = width } } }, r, .{ @min(ax, bx) - 2, @min(ay, by) - 2, @max(ax, bx) + 2, @max(ay, by) + 2 });
            },
            .line, .area => unreachable,
        }
    }

    /// A bar's or rect's box.
    fn barBox(m: *Marks, mark: spec.Mark, r: u32) E!?Box {
        const ch = m.ch;
        var xr: [2]f32 = undefined;
        var yr: [2]f32 = undefined;
        // Along x.
        if (try m.span(m.xs, ch.x, ch.x2, r, m.horizontal and mark == .bar, true)) |sp| xr = sp else return null;
        if (try m.span(m.ys, ch.y, ch.y2, r, !m.horizontal and mark == .bar, false)) |sp| yr = sp else return null;
        // Grouped bars share their band.
        if (mark == .bar and m.c.s.mark.stack == .grouped and m.color_n > 1) {
            const cv = ch.color.?.values(m.t).?;
            const gi = m.color.categorical.scale.index.get(try transform.litText(m.c.a, cv[r])) orelse 0;
            const n: f32 = @floatFromInt(m.color_n);
            const fi: f32 = @floatFromInt(gi);
            if (m.horizontal) {
                const w = (yr[1] - yr[0]) / n;
                const y0 = yr[0];
                yr = .{ y0 + w * fi, y0 + w * (fi + 1) };
            } else {
                const w = (xr[1] - xr[0]) / n;
                const x0 = xr[0];
                xr = .{ x0 + w * fi, x0 + w * (fi + 1) };
            }
        }
        return .{ .x = @min(xr[0], xr[1]), .y = @min(yr[0], yr[1]), .w = @abs(xr[1] - xr[0]), .h = @abs(yr[1] - yr[0]) };
    }

    /// The pixel range of a bar along one axis: a band, a bin (x to x2),
    /// a measure from its baseline or stack, or a thin bar on a
    /// continuous axis.
    fn span(m: *Marks, sc_opt: ?*const Scale, chn: ?Chan, ch2: ?Chan, r: u32, is_measure: bool, is_x: bool) E!?[2]f32 {
        const sc = sc_opt orelse return if (is_x) .{ m.plot.x, m.plot.right() } else .{ m.plot.y, m.plot.bottom() };
        if (sc.kind == .band or sc.kind == .point) {
            const p = (try m.pos(sc, chn, r, false)) orelse return null;
            const bw = if (sc.kind == .band) sc.bandwidth() else @max(sc.step() * 0.8, 1);
            const start = if (sc.kind == .point) p - bw / 2 else p;
            return .{ start, start + bw };
        }
        if (is_measure and m.stacking) {
            if (std.math.isNan(m.stack0[r])) return null;
            return .{ sc.mapNum(m.stack0[r]), sc.mapNum(m.stack1[r]) };
        }
        const p = (try m.pos(sc, chn, r, false)) orelse return null;
        if (ch2 != null) {
            const p2 = (try m.pos(sc, ch2, r, false)) orelse return null;
            // Adjacent bins keep a hairline apart.
            const gap: f32 = if (@abs(p2 - p) > 3) 1 else 0;
            return if (p2 > p) .{ p + gap / 2, p2 - gap / 2 } else .{ p2 + gap / 2, p - gap / 2 };
        }
        if (is_measure) return .{ baseline(sc), p };
        return .{ p - m.bar_w / 2, p + m.bar_w / 2 };
    }

    /// Lines and areas: one item per series, sorted along x.
    fn series(m: *Marks, mark: spec.Mark) E!void {
        const a = m.c.a;
        const ch = m.ch;
        const xv = ch.x.?.values(m.t) orelse return;
        const yv = ch.y.?.values(m.t) orelse return;
        // Series keys: colour, then detail fields (one series when
        // neither has values).
        var keys: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(u32)) = .empty;
        const color_vals = if (ch.color) |cc| cc.values(m.t) else null;
        const has_detail = for (ch.detail) |d| {
            if (d.values(m.t) != null) break true;
        } else false;
        if (color_vals != null or has_detail) for (0..m.t.rows) |r| {
            var kw: std.Io.Writer.Allocating = .init(a);
            if (color_vals) |cv| try transform.writeLit(&kw.writer, cv[r]);
            for (ch.detail) |d| if (d.values(m.t)) |dv| {
                try kw.writer.writeByte(0);
                try transform.writeLit(&kw.writer, dv[r]);
            };
            const gop = try keys.getOrPut(a, kw.written());
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, @intCast(r));
        };
        const single = keys.count() == 0;
        // Series in colour-domain order.
        const order = try a.alloc(u32, if (single) 1 else keys.count());
        for (order, 0..) |*o, i| o.* = @intCast(i);
        if (!single and m.color.* == .categorical) {
            const Sorter = struct {
                m: *Marks,
                fn lt(ctx: @This(), l: u32, r: u32) bool {
                    const cl = ctx.m.colorIndex(ctx.m.keysFirst(l)) catch 0;
                    const cr = ctx.m.colorIndex(ctx.m.keysFirst(r)) catch 0;
                    return if (cl != cr) cl < cr else l < r;
                }
            };
            m.series_rows = keys.values();
            std.mem.sort(u32, order, Sorter{ .m = m }, Sorter.lt);
        }
        const overlay = keys.count() > 1 and !m.stacking;
        const columns: u32 = @intFromFloat(@max(m.plot.w, 1));
        const base0 = baseline(m.ys.?);
        for (order) |si| {
            // Null: every row.
            const rows: ?[]const u32 = if (single) null else keys.values()[si].items;
            const count = if (rows) |rs| rs.len else m.t.rows;
            const decimating = count > decimate.line_factor * @as(usize, columns);
            // Long series already sorted along x (the usual case) are
            // decimated as they are read; others are sorted first.
            var pts: std.ArrayListUnmanaged(Pt) = .empty;
            var decimated = false;
            if (decimating) {
                try pts.ensureTotalCapacity(a, @as(usize, columns) * 4 + 8);
                var st: decimate.M4(Pt) = .init(m.plot.x, m.plot.right(), columns);
                var prev_x = -std.math.inf(f32);
                decimated = for (0..count) |i| {
                    const r: u32 = if (rows) |rs| rs[i] else @intCast(i);
                    const p = (try m.point(r, xv, yv, base0)) orelse continue;
                    if (p.x < prev_x) break false;
                    prev_x = p.x;
                    try st.push(a, &pts, p, p.x, p.y);
                } else true;
                if (decimated) try st.finish(a, &pts) else pts.clearRetainingCapacity();
            }
            if (!decimated) {
                try pts.ensureTotalCapacity(a, count);
                var sorted = true;
                for (0..count) |i| {
                    const r: u32 = if (rows) |rs| rs[i] else @intCast(i);
                    const p = (try m.point(r, xv, yv, base0)) orelse continue;
                    if (pts.items.len > 0 and p.x < pts.items[pts.items.len - 1].x) sorted = false;
                    pts.appendAssumeCapacity(p);
                }
                if (!sorted) std.mem.sort(Pt, pts.items, {}, struct {
                    fn lt(_: void, l: Pt, r: Pt) bool {
                        return if (l.x != r.x) l.x < r.x else l.row < r.row;
                    }
                }.lt);
                if (decimating) {
                    var kept: std.ArrayListUnmanaged(Pt) = .empty;
                    try kept.ensureTotalCapacity(a, @as(usize, columns) * 4 + 8);
                    var st: decimate.M4(Pt) = .init(m.plot.x, m.plot.right(), columns);
                    for (pts.items) |p| try st.push(a, &kept, p, p.x, p.y);
                    try st.finish(a, &kept);
                    pts = kept;
                    decimated = true;
                }
            }
            const n = pts.items.len;
            const line = try a.alloc([2]f32, n);
            const base = try a.alloc([2]f32, n);
            const item_idx: u32 = @intCast(m.items.items.len);
            const first_row = if (rows) |rs| (if (rs.len > 0) rs[0] else 0) else 0;
            const col = try m.colorOf(first_row);
            for (0..n) |i| {
                const p = pts.items[i];
                line[i] = .{ p.x, p.y };
                base[i] = .{ p.x, p.base };
                if (!std.math.isNan(p.y)) try m.targets.append(a, .{ .x0 = p.x, .y0 = p.y, .x1 = p.x, .y1 = p.y, .row = p.row, .item = item_idx });
            }
            if (mark == .line) {
                try m.items.append(a, .{ .color = col, .opacity = m.c.s.mark.opacity orelse 1, .geom = .{ .line = .{ .points = line, .width = m.c.s.mark.stroke_width orelse 2 } } });
                if (m.c.s.mark.point and !decimated) for (pts.items) |p| if (!std.math.isNan(p.y)) {
                    try m.items.append(a, .{ .color = col, .geom = .{ .point = .{ .x = p.x, .y = p.y, .size = 20, .shape = .circle, .filled = true } } });
                };
            } else {
                // Gaps are skipped in areas.
                var top: std.ArrayListUnmanaged([2]f32) = .empty;
                var bot: std.ArrayListUnmanaged([2]f32) = .empty;
                for (line, base) |l, b| if (!std.math.isNan(l[1])) {
                    try top.append(a, l);
                    try bot.append(a, b);
                };
                try m.items.append(a, .{ .color = col, .opacity = m.c.s.mark.opacity orelse if (overlay) 0.6 else 0.85, .geom = .{ .area = .{ .top = top.items, .base = bot.items } } });
            }
        }
    }

    const Pt = struct { x: f32, y: f32, base: f32, row: u32 };

    /// Row `r` of a line or area in pixels (y NaN for a gap); null when
    /// x has no position.
    inline fn point(m: *Marks, r: u32, xv: []const Lit, yv: []const Lit, base0: f32) E!?Pt {
        const xs = m.xs.?;
        const ys = m.ys.?;
        const x = (try posOf(m.c.a, xs, xv[r])) orelse return null;
        var y: f32 = std.math.nan(f32);
        var base = base0;
        if (m.stacking) {
            if (!std.math.isNan(m.stack1[r])) {
                y = ys.mapNum(m.stack1[r]);
                base = ys.mapNum(m.stack0[r]);
            }
        } else if (try posOf(m.c.a, ys, yv[r])) |p| y = p;
        return .{ .x = x, .y = y, .base = base, .row = r };
    }

    /// A value's position on a line: numbers inline, band centres.
    inline fn posOf(a: Allocator, sc: *const Scale, v: Lit) E!?f32 {
        switch (sc.kind) {
            .linear => {
                const x = transform.toNum(v) orelse return null;
                return sc.mapNum(x);
            },
            .band => return if (try sc.map(a, v)) |p| p + sc.bandwidth() / 2 else null,
            else => return sc.map(a, v),
        }
    }

    fn keysFirst(m: *Marks, si: u32) u32 {
        const rows = m.series_rows[si].items;
        return if (rows.len > 0) rows[0] else 0;
    }

    fn colorIndex(m: *Marks, r: u32) !u32 {
        const cc = m.ch.color orelse return 0;
        const vals = cc.values(m.t) orelse return 0;
        return m.color.categorical.scale.index.get(try transform.litText(m.c.a, vals[r])) orelse std.math.maxInt(u32);
    }
};

pub const Tooltip = struct {
    /// Where it points (the mark's anchor).
    x: f32,
    y: f32,
    row: u32,
    lines: []const TipLine,
};

pub const TipLine = struct { label: []const u8, value: []const u8 };

/// The tooltip of the mark nearest `at` (within 8 px).
pub fn hitTest(c: *const CompiledChart, a: Allocator, at: [2]f32) Allocator.Error!?Tooltip {
    const id = c.index.nearest(at) orelse return null;
    const tg = c.targets[id];
    const lines = try a.alloc(TipLine, c.tips.len);
    for (c.tips, lines) |tip, *l| {
        const v = c.table.cols.items[tip.col][tg.row];
        l.* = .{ .label = tip.label, .value = try tipValue(a, v, tip.temporal, c.zone) };
    }
    return .{ .x = (tg.x0 + tg.x1) / 2, .y = @min(tg.y0, tg.y1), .row = tg.row, .lines = lines };
}

fn tipValue(a: Allocator, v: Lit, temporal: bool, zone: ticks.Zone) Allocator.Error![]const u8 {
    if (!temporal) return transform.litText(a, v);
    const ms = transform.toTime(v) orelse return transform.litText(a, v);
    var w: std.Io.Writer.Allocating = .init(a);
    ticks.formatTimestamp(&w.writer, ms, zone) catch return error.OutOfMemory;
    return w.written();
}

test {
    std.testing.refAllDecls(@This());
}
