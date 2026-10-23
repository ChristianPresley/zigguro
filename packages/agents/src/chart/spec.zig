//! Chart specs (E13.F07.S01.T03): a compact, Vega-Lite-inspired JSON
//! subset that models write reliably — `data`, `mark`, `encoding`,
//! `transform` — read strictly, so every mistake comes back as one
//! message naming its JSON path. The format is in docs/formats/chart.md.

const std = @import("std");
const validate = @import("validate.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Ctx = validate.Ctx;

pub const SpecError = validate.SpecError;
pub const Diagnostic = validate.Diagnostic;

pub const Mark = enum { bar, line, area, point, circle, square, rule, rect, tick, text };
pub const FieldType = enum { quantitative, nominal, ordinal, temporal };
pub const Aggregate = enum { count, sum, mean, median, min, max, distinct };
pub const TimeUnit = enum { year, quarter, month, week, day, hour };
pub const ScaleType = enum { linear, log, time, band, point };
pub const Zone = enum { utc, local };

/// How bars and areas sharing an x combine: on top of each other
/// (`true`), over each other (`false`), or side by side (`"group"`,
/// bars only).
pub const Stack = enum { stacked, overlay, grouped };

pub const MarkDef = struct {
    type: Mark,
    /// Null: stacked for bar and area when a color field splits them.
    stack: ?Stack = null,
    filled: ?bool = null,
    /// `#rrggbb` (default: the first palette colour).
    color: ?[]const u8 = null,
    opacity: ?f32 = null,
    /// Point area in square pixels, or tick and text size.
    size: ?f32 = null,
    stroke_width: ?f32 = null,
    /// Draw points on a line.
    point: bool = false,
};

pub const Bin = struct { maxbins: u32 = 10 };

pub const Sort = enum {
    ascending,
    descending,
    none,
    /// By the other position channel's value.
    by_x,
    by_x_desc,
    by_y,
    by_y_desc,

    pub const json_names = [_][]const u8{ "ascending", "descending", "none", "x", "-x", "y", "-y" };
};

pub const ScaleDef = struct {
    type: ?ScaleType = null,
    /// Include zero (default: for bar and area quantitative axes).
    zero: ?bool = null,
    domain: ?[2]f64 = null,
    zone: Zone = .utc,
};

pub const Format = enum {
    auto,
    /// 1.2k, 3.4M.
    si,
    percent,
    /// As written, no grouping.
    plain,
};

pub const AxisDef = struct {
    title: ?[]const u8 = null,
    grid: ?bool = null,
    format: Format = .auto,
    labels: bool = true,
};

pub const Constant = union(enum) { number: f64, string: []const u8 };

pub const FieldDef = struct {
    field: ?[]const u8 = null,
    type: FieldType = .quantitative,
    aggregate: ?Aggregate = null,
    bin: ?Bin = null,
    time_unit: ?TimeUnit = null,
    sort: Sort = .ascending,
    title: ?[]const u8 = null,
    scale: ScaleDef = .{},
    /// Null hides the axis (`"axis": null`).
    axis: ?AxisDef = .{},
    legend: bool = true,
    format: Format = .auto,
    /// A constant instead of a field (`{"value": 3}`).
    value: ?Constant = null,

    /// The column name this channel reads after transforms.
    pub fn name(f: *const FieldDef) []const u8 {
        return f.field orelse if (f.aggregate == .count) "count" else "";
    }
};

pub const Encoding = struct {
    x: ?FieldDef = null,
    y: ?FieldDef = null,
    x2: ?FieldDef = null,
    y2: ?FieldDef = null,
    color: ?FieldDef = null,
    size: ?FieldDef = null,
    shape: ?FieldDef = null,
    opacity: ?FieldDef = null,
    text: ?FieldDef = null,
    tooltip: []const FieldDef = &.{},
    detail: []const FieldDef = &.{},
};

pub const AggOp = struct { op: Aggregate, field: ?[]const u8 = null, as: []const u8 };

pub const Transform = union(enum) {
    /// An F06 query expression; rows where it is true are kept.
    filter: []const u8,
    calculate: struct { expr: []const u8, as: []const u8 },
    bin: struct { field: []const u8, maxbins: u32, as: []const u8 },
    aggregate: struct { ops: []const AggOp, groupby: []const []const u8 },
    time_unit: struct { unit: TimeUnit, field: []const u8, as: []const u8 },
    /// Wide to long: each listed column becomes a row of (key, value).
    fold: struct { fields: []const []const u8, as: [2][]const u8 },
};

pub const Data = union(enum) {
    /// Inline rows: an array of objects.
    values: []const Value,
    /// A table artifact's id.
    artifact: []const u8,
    /// A workspace file, optionally through an F06 query.
    file: struct { path: []const u8, query: ?[]const u8 },
};

pub const ChartSpec = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    width: ?f32 = null,
    height: ?f32 = null,
    data: Data,
    mark: MarkDef,
    encoding: Encoding = .{},
    transform: []const Transform = &.{},
};

/// At most this many inline rows.
pub const max_inline_rows = 100_000;

/// Reads a spec; on `error.InvalidSpec`, `diag.message` says where and why.
pub fn parseSpec(arena: Allocator, json: []const u8, diag: *Diagnostic) SpecError!ChartSpec {
    const v = try validate.parseJson(arena, json, diag);
    var c: Ctx = .{ .arena = arena, .diag = diag };
    return readSpec(&c, v);
}

/// Reads a spec from parsed JSON.
pub fn readSpec(c: *Ctx, v: Value) SpecError!ChartSpec {
    const o = try c.object(v, &.{ "$schema", "title", "description", "width", "height", "data", "mark", "encoding", "transform" });
    var s: ChartSpec = .{ .data = undefined, .mark = undefined };
    if (o.get("title")) |t| s.title = try at(c, "title", t, Ctx.string);
    if (o.get("description")) |t| s.description = try at(c, "description", t, Ctx.string);
    if (o.get("width")) |t| s.width = @floatCast(try atRange(c, "width", t, 10, 10_000));
    if (o.get("height")) |t| s.height = @floatCast(try atRange(c, "height", t, 10, 10_000));
    s.data = try at(c, "data", o.get("data") orelse return c.failAt("data", "required", .{}), readData);
    s.mark = try at(c, "mark", o.get("mark") orelse return c.failAt("mark", "required", .{}), readMark);
    if (o.get("encoding")) |e| s.encoding = try at(c, "encoding", e, readEncoding);
    if (o.get("transform")) |t| s.transform = try at(c, "transform", t, readTransforms);
    try check(c, &s);
    return s;
}

/// Reads `v` as `key` of the current object.
fn at(c: *Ctx, key: []const u8, v: Value, comptime f: anytype) ReturnOf(f) {
    const old = c.path.key(key);
    defer c.path.restore(old);
    return f(c, v);
}

fn atRange(c: *Ctx, key: []const u8, v: Value, lo: f64, hi: f64) SpecError!f64 {
    const old = c.path.key(key);
    defer c.path.restore(old);
    return c.range(v, lo, hi);
}

fn atEnum(c: *Ctx, comptime E: type, key: []const u8, v: Value) SpecError!E {
    const old = c.path.key(key);
    defer c.path.restore(old);
    return c.enumOf(E, v);
}

fn ReturnOf(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

fn readData(c: *Ctx, v: Value) SpecError!Data {
    const o = try c.object(v, &.{ "values", "artifact", "path", "query" });
    var n: u32 = 0;
    for ([_][]const u8{ "values", "artifact", "path" }) |k| n += @intFromBool(o.contains(k));
    if (n != 1) return c.fail("expected exactly one of values, artifact, path", .{});
    if (o.get("query") != null and !o.contains("path")) return c.failAt("query", "only allowed with path", .{});
    if (o.get("values")) |vals| {
        const rows = try at(c, "values", vals, Ctx.array);
        if (rows.len > max_inline_rows) return c.failAt("values", "at most {d} inline rows, found {d}", .{ max_inline_rows, rows.len });
        const old = c.path.key("values");
        defer c.path.restore(old);
        for (rows, 0..) |r, i| {
            if (r != .object) {
                const o2 = c.path.index(i);
                defer c.path.restore(o2);
                return c.fail("expected an object, found {s}", .{validate.kind(r)});
            }
        }
        return .{ .values = rows };
    }
    if (o.get("artifact")) |a| return .{ .artifact = try at(c, "artifact", a, Ctx.string) };
    return .{ .file = .{
        .path = try at(c, "path", o.get("path").?, Ctx.string),
        .query = if (o.get("query")) |q| try at(c, "query", q, Ctx.string) else null,
    } };
}

fn readMark(c: *Ctx, v: Value) SpecError!MarkDef {
    if (v == .string) return .{ .type = try c.enumOf(Mark, v) };
    if (v != .object) return c.fail("expected a mark name or an object, found {s}", .{validate.kind(v)});
    const o = try c.object(v, &.{ "type", "stack", "filled", "color", "opacity", "size", "strokeWidth", "point" });
    var m: MarkDef = .{ .type = try atEnum(c, Mark, "type", o.get("type") orelse return c.failAt("type", "required", .{})) };
    if (o.get("stack")) |s| {
        const old = c.path.key("stack");
        defer c.path.restore(old);
        m.stack = switch (s) {
            .bool => |b| if (b) .stacked else .overlay,
            .string => |t| if (std.mem.eql(u8, t, "group")) .grouped else return c.fail("expected true, false or \"group\"", .{}),
            else => return c.fail("expected true, false or \"group\"", .{}),
        };
        if (m.type != .bar and m.type != .area) return c.fail("only bar and area marks stack", .{});
        if (m.stack == .grouped and m.type != .bar) return c.fail("only bar marks group", .{});
    }
    if (o.get("filled")) |f| m.filled = try at(c, "filled", f, Ctx.boolean);
    if (o.get("color")) |col| m.color = try at(c, "color", col, readColor);
    if (o.get("opacity")) |x| m.opacity = @floatCast(try atRange(c, "opacity", x, 0, 1));
    if (o.get("size")) |x| m.size = @floatCast(try atRange(c, "size", x, 0, 10_000));
    if (o.get("strokeWidth")) |x| m.stroke_width = @floatCast(try atRange(c, "strokeWidth", x, 0, 100));
    if (o.get("point")) |x| m.point = try at(c, "point", x, Ctx.boolean);
    return m;
}

fn readColor(c: *Ctx, v: Value) SpecError![]const u8 {
    const s = try c.string(v);
    if (parseHex(s) == null) return c.fail("expected a colour like \"#4c78a8\"", .{});
    return s;
}

/// `#rrggbb` (or `#rgb`) as 0xRRGGBB.
pub fn parseHex(s: []const u8) ?u24 {
    if (s.len == 7 and s[0] == '#') return std.fmt.parseInt(u24, s[1..], 16) catch null;
    if (s.len == 4 and s[0] == '#') {
        const short = std.fmt.parseInt(u12, s[1..], 16) catch return null;
        const r: u24 = (short >> 8) & 0xF;
        const g: u24 = (short >> 4) & 0xF;
        const b: u24 = short & 0xF;
        return (r * 0x11) << 16 | (g * 0x11) << 8 | b * 0x11;
    }
    return null;
}

const channels = [_][]const u8{ "x", "y", "x2", "y2", "color", "size", "shape", "opacity", "text", "tooltip", "detail" };

fn readEncoding(c: *Ctx, v: Value) SpecError!Encoding {
    const o = try c.object(v, &channels);
    var e: Encoding = .{};
    inline for (.{ "x", "y", "x2", "y2", "color", "size", "shape", "opacity", "text" }) |ch| {
        if (o.get(ch)) |f| @field(e, ch) = try at(c, ch, f, readFieldDef);
    }
    if (o.get("tooltip")) |t| e.tooltip = try at(c, "tooltip", t, readFieldList);
    if (o.get("detail")) |t| e.detail = try at(c, "detail", t, readFieldList);
    return e;
}

fn readFieldList(c: *Ctx, v: Value) SpecError![]const FieldDef {
    if (v == .object) {
        const one = try c.arena.alloc(FieldDef, 1);
        one[0] = try readFieldDef(c, v);
        return one;
    }
    const items = try c.array(v);
    const out = try c.arena.alloc(FieldDef, items.len);
    for (items, out, 0..) |it, *f, i| {
        const old = c.path.index(i);
        defer c.path.restore(old);
        f.* = try readFieldDef(c, it);
    }
    return out;
}

fn readFieldDef(c: *Ctx, v: Value) SpecError!FieldDef {
    const o = try c.object(v, &.{ "field", "type", "aggregate", "bin", "timeUnit", "sort", "title", "scale", "axis", "legend", "format", "value" });
    var f: FieldDef = .{};
    if (o.get("value")) |val| {
        if (o.count() != 1) return c.fail("a constant (value) takes no other keys", .{});
        const old = c.path.key("value");
        defer c.path.restore(old);
        f.value = switch (val) {
            .string => |s| .{ .string = s },
            else => .{ .number = try c.number(val) },
        };
        return f;
    }
    if (o.get("field")) |x| f.field = try at(c, "field", x, readName);
    if (o.get("aggregate")) |x| f.aggregate = try atEnum(c, Aggregate, "aggregate", x);
    if (o.get("type")) |x| {
        f.type = try atEnum(c, FieldType, "type", x);
    } else if (f.aggregate != .count) {
        return c.failAt("type", "required (one of quantitative|nominal|ordinal|temporal)", .{});
    }
    if (f.field == null and f.aggregate != .count) return c.failAt("field", "required unless aggregate is count", .{});
    if (o.get("bin")) |x| f.bin = try at(c, "bin", x, readBin);
    if (o.get("timeUnit")) |x| f.time_unit = try atEnum(c, TimeUnit, "timeUnit", x);
    if (o.get("sort")) |x| f.sort = try atEnum(c, Sort, "sort", x);
    if (o.get("title")) |x| f.title = try at(c, "title", x, Ctx.string);
    if (o.get("scale")) |x| f.scale = try at(c, "scale", x, readScale);
    if (o.get("axis")) |x| f.axis = if (x == .null) null else try at(c, "axis", x, readAxis);
    if (o.get("legend")) |x| f.legend = x != .null and try at(c, "legend", x, Ctx.boolean);
    if (o.get("format")) |x| f.format = try atEnum(c, Format, "format", x);
    // Combinations that cannot mean anything.
    if (f.bin != null and f.type != .quantitative) return c.failAt("bin", "needs a quantitative field", .{});
    if (f.time_unit != null and f.type != .temporal and f.type != .ordinal) return c.failAt("timeUnit", "needs a temporal field", .{});
    if (f.aggregate) |a| if (a != .count and a != .distinct and f.type != .quantitative) return c.failAt("aggregate", "{s} needs a quantitative field", .{@tagName(a)});
    if (f.bin != null and f.aggregate != null) return c.failAt("bin", "cannot be combined with aggregate on one channel", .{});
    if (f.scale.type) |st| {
        const ok = switch (f.type) {
            .quantitative => st == .linear or st == .log,
            .temporal => st == .time or st == .band or st == .point,
            .nominal, .ordinal => st == .band or st == .point,
        };
        if (!ok) {
            const old = c.path.key("scale");
            defer c.path.restore(old);
            return c.failAt("type", "a {s} field cannot use a {s} scale", .{ @tagName(f.type), @tagName(st) });
        }
    }
    return f;
}

fn readName(c: *Ctx, v: Value) SpecError![]const u8 {
    const s = try c.string(v);
    if (s.len == 0) return c.fail("expected a field name", .{});
    return s;
}

fn readBin(c: *Ctx, v: Value) SpecError!Bin {
    if (v == .bool) return if (v.bool) .{} else c.fail("use no bin key instead of false", .{});
    const o = try c.object(v, &.{"maxbins"});
    var b: Bin = .{};
    if (o.get("maxbins")) |m| b.maxbins = @intFromFloat(try atRange(c, "maxbins", m, 2, 1000));
    return b;
}

fn readScale(c: *Ctx, v: Value) SpecError!ScaleDef {
    const o = try c.object(v, &.{ "type", "zero", "domain", "zone" });
    var s: ScaleDef = .{};
    if (o.get("type")) |x| s.type = try atEnum(c, ScaleType, "type", x);
    if (o.get("zero")) |x| s.zero = try at(c, "zero", x, Ctx.boolean);
    if (o.get("zone")) |x| s.zone = try atEnum(c, Zone, "zone", x);
    if (o.get("domain")) |x| {
        const old = c.path.key("domain");
        defer c.path.restore(old);
        const items = try c.array(x);
        if (items.len != 2) return c.fail("expected [min, max]", .{});
        var d: [2]f64 = undefined;
        for (items, &d, 0..) |it, *o2, i| {
            const old2 = c.path.index(i);
            defer c.path.restore(old2);
            o2.* = try c.number(it);
        }
        if (!(d[0] < d[1])) return c.fail("min must be less than max", .{});
        s.domain = d;
    }
    return s;
}

fn readAxis(c: *Ctx, v: Value) SpecError!AxisDef {
    const o = try c.object(v, &.{ "title", "grid", "format", "labels" });
    var a: AxisDef = .{};
    if (o.get("title")) |x| a.title = try at(c, "title", x, Ctx.string);
    if (o.get("grid")) |x| a.grid = try at(c, "grid", x, Ctx.boolean);
    if (o.get("format")) |x| a.format = try atEnum(c, Format, "format", x);
    if (o.get("labels")) |x| a.labels = try at(c, "labels", x, Ctx.boolean);
    return a;
}

const transform_keys = [_][]const u8{ "filter", "calculate", "bin", "aggregate", "timeUnit", "fold" };

fn readTransforms(c: *Ctx, v: Value) SpecError![]const Transform {
    const items = try c.array(v);
    const out = try c.arena.alloc(Transform, items.len);
    for (items, out, 0..) |it, *t, i| {
        const old = c.path.index(i);
        defer c.path.restore(old);
        t.* = try readTransform(c, it);
    }
    return out;
}

fn readTransform(c: *Ctx, v: Value) SpecError!Transform {
    if (v != .object) return c.fail("expected an object, found {s}", .{validate.kind(v)});
    var which: ?[]const u8 = null;
    for (transform_keys) |k| if (v.object.contains(k)) {
        if (which != null) return c.fail("expected exactly one of {s}", .{comptime validate.join(&transform_keys, ", ")});
        which = k;
    };
    const k = which orelse return c.fail("expected one of {s}", .{comptime validate.join(&transform_keys, ", ")});
    if (std.mem.eql(u8, k, "filter")) {
        const o = try c.object(v, &.{"filter"});
        return .{ .filter = try at(c, "filter", o.get("filter").?, readName) };
    }
    if (std.mem.eql(u8, k, "calculate")) {
        const o = try c.object(v, &.{ "calculate", "as" });
        return .{ .calculate = .{
            .expr = try at(c, "calculate", o.get("calculate").?, readName),
            .as = try at(c, "as", o.get("as") orelse return c.failAt("as", "required", .{}), readName),
        } };
    }
    if (std.mem.eql(u8, k, "bin")) {
        const o = try c.object(v, &.{ "bin", "field", "as" });
        const b = try at(c, "bin", o.get("bin").?, readBin);
        return .{ .bin = .{
            .field = try at(c, "field", o.get("field") orelse return c.failAt("field", "required", .{}), readName),
            .maxbins = b.maxbins,
            .as = try at(c, "as", o.get("as") orelse return c.failAt("as", "required", .{}), readName),
        } };
    }
    if (std.mem.eql(u8, k, "timeUnit")) {
        const o = try c.object(v, &.{ "timeUnit", "field", "as" });
        return .{ .time_unit = .{
            .unit = try atEnum(c, TimeUnit, "timeUnit", o.get("timeUnit").?),
            .field = try at(c, "field", o.get("field") orelse return c.failAt("field", "required", .{}), readName),
            .as = try at(c, "as", o.get("as") orelse return c.failAt("as", "required", .{}), readName),
        } };
    }
    if (std.mem.eql(u8, k, "fold")) {
        const o = try c.object(v, &.{ "fold", "as" });
        const fields = try at(c, "fold", o.get("fold").?, readNames);
        if (fields.len == 0) return c.failAt("fold", "expected at least one field", .{});
        var as: [2][]const u8 = .{ "key", "value" };
        if (o.get("as")) |a| {
            const names = try at(c, "as", a, readNames);
            if (names.len != 2) return c.failAt("as", "expected [key, value] names", .{});
            as = .{ names[0], names[1] };
        }
        return .{ .fold = .{ .fields = fields, .as = as } };
    }
    // aggregate
    const o = try c.object(v, &.{ "aggregate", "groupby" });
    const ops_v = try at(c, "aggregate", o.get("aggregate").?, Ctx.array);
    if (ops_v.len == 0) return c.failAt("aggregate", "expected at least one operation", .{});
    const ops = try c.arena.alloc(AggOp, ops_v.len);
    {
        const old = c.path.key("aggregate");
        defer c.path.restore(old);
        for (ops_v, ops, 0..) |it, *op, i| {
            const old2 = c.path.index(i);
            defer c.path.restore(old2);
            const oo = try c.object(it, &.{ "op", "field", "as" });
            op.* = .{
                .op = try atEnum(c, Aggregate, "op", oo.get("op") orelse return c.failAt("op", "required", .{})),
                .field = if (oo.get("field")) |f| try at(c, "field", f, readName) else null,
                .as = try at(c, "as", oo.get("as") orelse return c.failAt("as", "required", .{}), readName),
            };
            if (op.field == null and op.op != .count) return c.failAt("field", "required unless op is count", .{});
        }
    }
    return .{ .aggregate = .{
        .ops = ops,
        .groupby = if (o.get("groupby")) |g| try at(c, "groupby", g, readNames) else &.{},
    } };
}

fn readNames(c: *Ctx, v: Value) SpecError![]const []const u8 {
    const items = try c.array(v);
    const out = try c.arena.alloc([]const u8, items.len);
    for (items, out, 0..) |it, *n, i| {
        const old = c.path.index(i);
        defer c.path.restore(old);
        n.* = try readName(c, it);
    }
    return out;
}

/// Checks across keys: channels a mark needs, and channels it cannot use.
fn check(c: *Ctx, s: *const ChartSpec) SpecError!void {
    const e = &s.encoding;
    const m = s.mark.type;
    const old = c.path.key("encoding");
    defer c.path.restore(old);
    switch (m) {
        .bar, .line, .area, .point, .circle, .square, .tick => if (e.x == null and e.y == null) return c.fail("{s} needs x or y", .{@tagName(m)}),
        .rule => if (e.x == null and e.y == null) return c.fail("rule needs x or y", .{}),
        .rect => if (e.x == null or e.y == null) return c.fail("rect needs x and y", .{}),
        .text => if (e.text == null) return c.failAt("text", "required for text marks", .{}),
    }
    if (m == .line or m == .area) {
        if (e.x == null or e.y == null) return c.fail("{s} needs x and y", .{@tagName(m)});
    }
    if (e.x2 != null and e.x == null) return c.failAt("x2", "needs x", .{});
    if (e.y2 != null and e.y == null) return c.failAt("y2", "needs y", .{});
    if (e.size != null and !(m == .point or m == .circle or m == .square or m == .text)) return c.failAt("size", "only point, circle, square and text marks have a size", .{});
    if (e.shape != null and m != .point) return c.failAt("shape", "only point marks have a shape", .{});
    if (e.x) |x| if (x.value != null) return c.failAt("x", "position channels need a field", .{});
    if (e.y) |y| if (y.value != null) return c.failAt("y", "position channels need a field", .{});
}

test {
    std.testing.refAllDecls(@This());
}
