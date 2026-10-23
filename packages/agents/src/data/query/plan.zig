//! The logical planner of the data query language (E13.F06.S02.T01).
//!
//! `plan` resolves datasets and columns against a catalog, type-checks
//! every expression (errors like "cannot compare string to int at
//! 34..41"), folds constants, and shapes the stages for execution:
//! * column pruning: `needed_columns` lists the source columns any stage
//!   reads (or the output keeps), so only those are parsed;
//! * predicate pushdown: `where` conjuncts over raw source columns that
//!   come before any stage changing the rows move into `filter`, run on
//!   raw fields before anything is materialized;
//! * `sort … | limit k` becomes one `topk` stage.
//! Column indices in a stage refer to the schema as it is before that
//! stage (the source schema, plus derived and joined columns).

const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Span = ast.Span;
const Type = types.Type;
const Schema = types.Schema;
const SchemaCol = types.SchemaCol;

pub const PlanError = error{ Type, UnknownColumn, UnknownDataset, OutOfMemory };

/// Dataset name → columns and types. The name "" is the default dataset
/// (a query without `from`).
pub const Catalog = struct {
    ctx: *anyopaque,
    resolve: *const fn (ctx: *anyopaque, name: []const u8) ?Schema,
};

pub const Lit = union(enum) {
    null_,
    bool_: bool,
    int: i64,
    float: f64,
    string: []const u8,
    date: i32,
    datetime: i64,
};

pub const TypedWhen = struct { cond: *const TypedExpr, then: *const TypedExpr };

pub const TypedExpr = struct {
    ty: Type,
    span: Span,
    node: Node,

    pub const Node = union(enum) {
        lit: Lit,
        col: u32,
        unary: struct { op: ast.UnOp, e: *const TypedExpr },
        binary: struct { op: ast.BinOp, l: *const TypedExpr, r: *const TypedExpr },
        in_list: struct { e: *const TypedExpr, list: []const *const TypedExpr, negated: bool },
        between: struct { e: *const TypedExpr, lo: *const TypedExpr, hi: *const TypedExpr, negated: bool },
        is_null: struct { e: *const TypedExpr, negated: bool },
        call: struct { func: types.Func, args: []const *const TypedExpr, unit: ?types.Unit = null },
        case: struct { whens: []const TypedWhen, else_: ?*const TypedExpr },
    };
};

pub const DatasetRef = struct { name: []const u8, schema: Schema };

/// `name = expr`, written to column `target` (an existing column it
/// replaces, or the next new one).
pub const Derived = struct { name: []const u8, target: u32, expr: *const TypedExpr };

pub const AggSpec = struct {
    name: []const u8,
    func: types.Agg,
    arg: ?*const TypedExpr,
    /// The quantile of `p(x, q)`.
    q: f64 = 0.5,
    ty: Type,
};

pub const PlanKey = struct { col: u32, desc: bool };

pub const Stage = union(enum) {
    where: *const TypedExpr,
    derive: []const Derived,
    /// The new schema is these, in order.
    select: []const Derived,
    group: struct { keys: []const u32, aggs: []const AggSpec },
    sort: []const PlanKey,
    limit: u64,
    topk: struct { keys: []const PlanKey, k: u64 },
    join: struct { right: DatasetRef, left_col: u32, right_col: u32, left: bool },
    sample: u64,
};

pub const Plan = struct {
    source: DatasetRef,
    /// Source columns to parse, ascending.
    needed_columns: []const u32,
    /// Pushed-down conjuncts (over source columns), all of which must hold.
    filter: ?*const TypedExpr,
    stages: []const Stage,
    out_schema: Schema,
};

pub fn plan(arena: Allocator, tree: *const ast.Ast, catalog: Catalog, diag: *ast.Diagnostic) PlanError!Plan {
    var p: Planner = .{ .arena = arena, .catalog = catalog, .diag = diag };
    return p.run(tree);
}

const Planner = struct {
    arena: Allocator,
    catalog: Catalog,
    diag: *ast.Diagnostic,
    schema: std.ArrayList(SchemaCol) = .empty,
    source_len: u32 = 0,
    /// Which of the first `source_len` schema columns still hold the
    /// source's raw values (cleared when replaced or reshaped away).
    live: std.DynamicBitSetUnmanaged = .{},
    needed: std.DynamicBitSetUnmanaged = .{},
    in_group: bool = false,

    fn fail(p: *Planner, comptime e: PlanError, span: Span, comptime fmt: []const u8, args: anytype) PlanError {
        p.diag.* = .{ .span = span, .message = try std.fmt.allocPrint(p.arena, fmt, args) };
        return e;
    }

    fn run(p: *Planner, tree: *const ast.Ast) PlanError!Plan {
        var name: []const u8 = "";
        var name_span: Span = .{ .start = 0, .end = 0 };
        var rest = tree.stages;
        if (rest.len > 0 and rest[0].stage == .from) {
            name = rest[0].stage.from.name;
            name_span = rest[0].span;
            rest = rest[1..];
        }
        const src = p.catalog.resolve(p.catalog.ctx, name) orelse
            return if (name.len == 0) p.fail(error.UnknownDataset, name_span, "the query needs `from <dataset>`", .{}) else p.fail(error.UnknownDataset, name_span, "unknown dataset `{s}`", .{name});
        try p.schema.appendSlice(p.arena, src.columns);
        p.source_len = @intCast(src.columns.len);
        p.needed = try .initEmpty(p.arena, src.columns.len);
        p.live = try .initFull(p.arena, src.columns.len);

        var stages: std.ArrayList(Stage) = .empty;
        for (rest) |node| try stages.append(p.arena, try p.stage(node));
        // Source columns the output still shows are needed too.
        p.needed.setUnion(p.live);

        const filter = try p.pushdown(&stages);
        p.fuseTopk(&stages);

        var needed: std.ArrayList(u32) = .empty;
        var it = p.needed.iterator(.{});
        while (it.next()) |i| try needed.append(p.arena, @intCast(i));
        return .{
            .source = .{ .name = name, .schema = src },
            .needed_columns = needed.items,
            .filter = filter,
            .stages = stages.items,
            .out_schema = .{ .columns = p.schema.items },
        };
    }

    fn stage(p: *Planner, node: ast.StageNode) PlanError!Stage {
        switch (node.stage) {
            .from => return p.fail(error.Type, node.span, "`from` must be the first stage", .{}),
            .where => |e| {
                const t = try p.expr(e);
                if (t.ty != .bool_ and t.ty != .null_) return p.fail(error.Type, e.span, "`where` needs a bool, found {s}", .{t.ty.name()});
                return .{ .where = t };
            },
            .derive => |bs| {
                var out: std.ArrayList(Derived) = .empty;
                for (bs) |b| {
                    const t = try p.expr(b.expr);
                    const n = b.name.?;
                    const target = p.current().find(n) orelse blk: {
                        try p.schema.append(p.arena, .{ .name = n, .ty = t.ty });
                        break :blk @as(u32, @intCast(p.schema.items.len - 1));
                    };
                    if (target < p.schema.items.len) p.schema.items[target].ty = t.ty;
                    // Replacing a source column hides the raw value.
                    if (target < p.source_len) p.live.unset(target);
                    try out.append(p.arena, .{ .name = n, .target = target, .expr = t });
                }
                return .{ .derive = out.items };
            },
            .select => |bs| {
                var out: std.ArrayList(Derived) = .empty;
                var cols: std.ArrayList(SchemaCol) = .empty;
                for (bs, 0..) |b, i| {
                    const t = try p.expr(b.expr);
                    const n = b.name orelse switch (b.expr.node) {
                        .column => |c| c,
                        else => try std.fmt.allocPrint(p.arena, "expr{d}", .{i + 1}),
                    };
                    for (cols.items) |c| if (std.mem.eql(u8, c.name, n))
                        return p.fail(error.Type, b.name_span, "duplicate column `{s}` in `select`", .{n});
                    try cols.append(p.arena, .{ .name = n, .ty = t.ty });
                    try out.append(p.arena, .{ .name = n, .target = @intCast(i), .expr = t });
                }
                p.schema = cols;
                p.live.unsetAll();
                return .{ .select = out.items };
            },
            .group => |g| {
                var keys: std.ArrayList(u32) = .empty;
                var cols: std.ArrayList(SchemaCol) = .empty;
                for (g.keys) |k| {
                    if (k.desc) return p.fail(error.Type, k.span, "group keys can't be descending", .{});
                    const c = try p.column(k.column, k.span);
                    try keys.append(p.arena, c);
                    try cols.append(p.arena, p.schema.items[c]);
                }
                var aggs: std.ArrayList(AggSpec) = .empty;
                for (g.aggs) |b| {
                    const a = try p.aggregate(b.name.?, b.expr);
                    for (cols.items) |c| if (std.mem.eql(u8, c.name, a.name))
                        return p.fail(error.Type, b.name_span, "duplicate column `{s}` in `group`", .{a.name});
                    try aggs.append(p.arena, a);
                    try cols.append(p.arena, .{ .name = a.name, .ty = a.ty });
                }
                p.schema = cols;
                p.live.unsetAll();
                return .{ .group = .{ .keys = keys.items, .aggs = aggs.items } };
            },
            .sort => |ks| {
                var out: std.ArrayList(PlanKey) = .empty;
                for (ks) |k| try out.append(p.arena, .{ .col = try p.column(k.column, k.span), .desc = k.desc });
                return .{ .sort = out.items };
            },
            .limit => |n| return .{ .limit = n },
            .sample => |n| return .{ .sample = n },
            .join => |j| {
                const right = p.catalog.resolve(p.catalog.ctx, j.name) orelse
                    return p.fail(error.UnknownDataset, node.span, "unknown dataset `{s}`", .{j.name});
                const on = j.on;
                if (on.node != .binary or on.node.binary.op != .eq or on.node.binary.l.node != .column or on.node.binary.r.node != .column)
                    return p.fail(error.Type, on.span, "join needs `left_column == right_column`", .{});
                const a = on.node.binary.l.node.column;
                const b = on.node.binary.r.node.column;
                // Either side may name the joined dataset's column.
                const lc, const rc, const lspan, const rspan = if (p.current().find(a) != null and right.find(b) != null)
                    .{ a, b, on.node.binary.l.span, on.node.binary.r.span }
                else
                    .{ b, a, on.node.binary.r.span, on.node.binary.l.span };
                const left_col = try p.column(lc, lspan);
                const right_col = right.find(rc) orelse return p.unknownColumn(rc, rspan, right);
                const lt = p.schema.items[left_col].ty;
                const rt = right.columns[right_col].ty;
                if (!lt.comparable(rt)) return p.fail(error.Type, on.span, "cannot compare {s} to {s}", .{ lt.name(), rt.name() });
                for (right.columns) |c| {
                    var n = c.name;
                    var k: u32 = 2;
                    while (p.current().find(n) != null) : (k += 1) n = try std.fmt.allocPrint(p.arena, "{s}_{d}", .{ c.name, k });
                    // A left join can leave the joined columns empty.
                    try p.schema.append(p.arena, .{ .name = n, .ty = c.ty });
                }
                return .{ .join = .{ .right = .{ .name = j.name, .schema = right }, .left_col = left_col, .right_col = right_col, .left = j.left } };
            },
        }
    }

    fn current(p: *const Planner) Schema {
        return .{ .columns = p.schema.items };
    }

    fn unknownColumn(p: *Planner, n: []const u8, span: Span, s: Schema) PlanError {
        if (s.closest(n)) |c| return p.fail(error.UnknownColumn, span, "unknown column `{s}` (did you mean `{s}`?)", .{ n, c });
        return p.fail(error.UnknownColumn, span, "unknown column `{s}`", .{n});
    }

    fn column(p: *Planner, n: []const u8, span: Span) PlanError!u32 {
        const c = p.current().find(n) orelse return p.unknownColumn(n, span, p.current());
        if (c < p.source_len and p.live.isSet(c)) p.needed.set(c);
        return c;
    }

    fn new(p: *Planner, ty: Type, span: Span, n: TypedExpr.Node) PlanError!*TypedExpr {
        const e = try p.arena.create(TypedExpr);
        e.* = .{ .ty = ty, .span = span, .node = n };
        return e;
    }

    fn lit(p: *Planner, span: Span, l: Lit) PlanError!*TypedExpr {
        const ty: Type = switch (l) {
            .null_ => .null_,
            .bool_ => .bool_,
            .int => .int,
            .float => .float,
            .string => .string,
            .date => .date,
            .datetime => .datetime,
        };
        return p.new(ty, span, .{ .lit = l });
    }

    fn expr(p: *Planner, e: *const ast.Expr) PlanError!*const TypedExpr {
        const s = e.span;
        switch (e.node) {
            .int => |v| return p.lit(s, .{ .int = v }),
            .float => |v| return p.lit(s, .{ .float = v }),
            .string => |v| return p.lit(s, .{ .string = v }),
            .bool_ => |v| return p.lit(s, .{ .bool_ = v }),
            .null_ => return p.lit(s, .null_),
            .date => |v| return p.lit(s, .{ .date = v }),
            .datetime => |v| return p.lit(s, .{ .datetime = v }),
            .column => |n| {
                const c = try p.column(n, s);
                return p.new(p.schema.items[c].ty, s, .{ .col = c });
            },
            .unary => |u| {
                const x = try p.expr(u.e);
                switch (u.op) {
                    .neg => if (!x.ty.numeric() and x.ty != .null_) return p.fail(error.Type, s, "`-` needs a number, found {s}", .{x.ty.name()}),
                    .not => if (x.ty != .bool_ and x.ty != .null_) return p.fail(error.Type, s, "`not` needs a bool, found {s}", .{x.ty.name()}),
                }
                const ty: Type = if (u.op == .not) .bool_ else if (x.ty == .null_) .null_ else x.ty;
                return p.fold(try p.new(ty, s, .{ .unary = .{ .op = u.op, .e = x } }));
            },
            .binary => |b| {
                const l = try p.expr(b.l);
                const r = try p.expr(b.r);
                const ty = try p.binaryType(b.op, l.ty, r.ty, s);
                return p.fold(try p.new(ty, s, .{ .binary = .{ .op = b.op, .l = l, .r = r } }));
            },
            .in_list => |x| {
                const v = try p.expr(x.e);
                const list = try p.arena.alloc(*const TypedExpr, x.list.len);
                for (x.list, list) |item, *o| {
                    o.* = try p.expr(item);
                    if (!v.ty.comparable(o.*.ty)) return p.fail(error.Type, item.span, "cannot compare {s} to {s}", .{ v.ty.name(), o.*.ty.name() });
                }
                return p.new(.bool_, s, .{ .in_list = .{ .e = v, .list = list, .negated = x.negated } });
            },
            .between => |x| {
                const v = try p.expr(x.e);
                const lo = try p.expr(x.lo);
                const hi = try p.expr(x.hi);
                for ([_]*const TypedExpr{ lo, hi }) |b| if (!v.ty.comparable(b.ty))
                    return p.fail(error.Type, s, "cannot compare {s} to {s}", .{ v.ty.name(), b.ty.name() });
                return p.new(.bool_, s, .{ .between = .{ .e = v, .lo = lo, .hi = hi, .negated = x.negated } });
            },
            .is_null => |x| return p.new(.bool_, s, .{ .is_null = .{ .e = try p.expr(x.e), .negated = x.negated } }),
            .call => |c| return p.call(c.name, c.args, s),
            .case => |c| {
                var ty: Type = .null_;
                const whens = try p.arena.alloc(TypedWhen, c.whens.len);
                for (c.whens, whens) |w, *o| {
                    const cond = try p.expr(w.cond);
                    if (cond.ty != .bool_ and cond.ty != .null_) return p.fail(error.Type, w.cond.span, "`when` needs a bool, found {s}", .{cond.ty.name()});
                    const then = try p.expr(w.then);
                    ty = Type.unify(ty, then.ty) orelse return p.fail(error.Type, w.then.span, "case branches have different types: {s} and {s}", .{ ty.name(), then.ty.name() });
                    o.* = .{ .cond = cond, .then = then };
                }
                const else_: ?*const TypedExpr = if (c.else_) |x| try p.expr(x) else null;
                if (else_) |x| ty = Type.unify(ty, x.ty) orelse return p.fail(error.Type, c.else_.?.span, "case branches have different types: {s} and {s}", .{ ty.name(), x.ty.name() });
                return p.new(ty, s, .{ .case = .{ .whens = whens, .else_ = else_ } });
            },
        }
    }

    fn binaryType(p: *Planner, op: ast.BinOp, l: Type, r: Type, s: Span) PlanError!Type {
        if (op.comparison()) {
            if (!l.comparable(r)) return p.fail(error.Type, s, "cannot compare {s} to {s}", .{ l.name(), r.name() });
            return .bool_;
        }
        switch (op) {
            .@"and", .@"or" => {
                for ([_]Type{ l, r }) |t| if (t != .bool_ and t != .null_)
                    return p.fail(error.Type, s, "`{s}` needs bools, found {s} and {s}", .{ op.text(), l.name(), r.name() });
                return .bool_;
            },
            else => {},
        }
        if (l == .null_ or r == .null_) return if (l == .null_) (if (r == .null_) .null_ else r) else l;
        // Date arithmetic: date ± int days, date - date days.
        if (op == .add or op == .sub) {
            if (l.temporal() and r == .int) return l;
            if (op == .add and l == .int and r.temporal()) return r;
            if (op == .sub and l.temporal() and r.temporal()) return .int;
            if (op == .add and l == .string and r == .string) return .string;
        }
        if (!l.numeric() or !r.numeric()) return p.fail(error.Type, s, "`{s}` needs numbers, found {s} and {s}", .{ op.text(), l.name(), r.name() });
        if (op == .div) return .float;
        return if (l == .int and r == .int) .int else .float;
    }

    fn arity(p: *Planner, n: []const u8, args: []const *ast.Expr, lo: usize, hi: usize, s: Span) PlanError!void {
        if (args.len >= lo and args.len <= hi) return;
        if (lo == hi) return p.fail(error.Type, s, "`{s}` takes {d} argument{s}, found {d}", .{ n, lo, if (lo == 1) "" else "s", args.len });
        return p.fail(error.Type, s, "`{s}` takes {d} to {d} arguments, found {d}", .{ n, lo, hi, args.len });
    }

    fn want(p: *Planner, n: []const u8, a: *const TypedExpr, ok: bool, what: []const u8, span: Span) PlanError!void {
        if (ok or a.ty == .null_) return;
        return p.fail(error.Type, span, "`{s}` takes {s}, found {s}", .{ n, what, a.ty.name() });
    }

    fn unitArg(p: *Planner, n: []const u8, e: *const ast.Expr) PlanError!types.Unit {
        if (e.node != .string) return p.fail(error.Type, e.span, "`{s}` needs a unit string like \"month\"", .{n});
        return std.meta.stringToEnum(types.Unit, e.node.string) orelse
            p.fail(error.Type, e.span, "unknown unit \"{s}\" (year, quarter, month, week, day, hour, minute, second)", .{e.node.string});
    }

    fn call(p: *Planner, n: []const u8, args: []const *ast.Expr, s: Span) PlanError!*const TypedExpr {
        if (types.aggOf(n) != null) return p.fail(error.Type, s, "`{s}` is an aggregate; use it inside `group {{ }}`", .{n});
        const f = types.funcOf(n) orelse return p.fail(error.Type, s, "unknown function `{s}`", .{n});
        var unit: ?types.Unit = null;
        // Units are literal strings, not expressions.
        const n_typed = switch (f) {
            .trunc => blk: {
                try p.arity(n, args, 2, 2, s);
                unit = try p.unitArg(n, args[1]);
                break :blk @as(usize, 1);
            },
            .date_diff => blk: {
                try p.arity(n, args, 2, 3, s);
                if (args.len == 3) unit = try p.unitArg(n, args[2]);
                break :blk @as(usize, 2);
            },
            else => args.len,
        };
        const ta = try p.arena.alloc(*const TypedExpr, n_typed);
        for (args[0..n_typed], ta) |a, *o| o.* = try p.expr(a);
        const ty: Type = switch (f) {
            .lower, .upper => blk: {
                try p.arity(n, args, 1, 1, s);
                try p.want(n, ta[0], ta[0].ty == .string, "a string", args[0].span);
                break :blk .string;
            },
            .contains, .starts_with, .ends_with, .regex_match => blk: {
                try p.arity(n, args, 2, 2, s);
                for (ta, args) |a, x| try p.want(n, a, a.ty == .string, "strings", x.span);
                break :blk .bool_;
            },
            .length => blk: {
                try p.arity(n, args, 1, 1, s);
                try p.want(n, ta[0], ta[0].ty == .string, "a string", args[0].span);
                break :blk .int;
            },
            .substr => blk: {
                try p.arity(n, args, 2, 3, s);
                try p.want(n, ta[0], ta[0].ty == .string, "a string", args[0].span);
                for (ta[1..], args[1..]) |a, x| try p.want(n, a, a.ty == .int, "int positions", x.span);
                break :blk .string;
            },
            .year, .month, .day => blk: {
                try p.arity(n, args, 1, 1, s);
                try p.want(n, ta[0], ta[0].ty.temporal(), "a date", args[0].span);
                break :blk .int;
            },
            .trunc => blk: {
                try p.want(n, ta[0], ta[0].ty.temporal(), "a date", args[0].span);
                break :blk if (ta[0].ty == .null_) .date else ta[0].ty;
            },
            .date_diff => blk: {
                for (ta, args[0..2]) |a, x| try p.want(n, a, a.ty.temporal(), "dates", x.span);
                break :blk .int;
            },
            .abs, .round, .floor, .ceil => blk: {
                try p.arity(n, args, 1, if (f == .round) 2 else 1, s);
                try p.want(n, ta[0], ta[0].ty.numeric(), "a number", args[0].span);
                if (ta.len == 2) try p.want(n, ta[1], ta[1].ty == .int, "int digits", args[1].span);
                break :blk if (ta[0].ty == .null_) .null_ else if (f == .round and ta.len == 2) .float else ta[0].ty;
            },
            .log, .sqrt => blk: {
                try p.arity(n, args, 1, 1, s);
                try p.want(n, ta[0], ta[0].ty.numeric(), "a number", args[0].span);
                break :blk .float;
            },
            .coalesce => blk: {
                if (args.len == 0) return p.fail(error.Type, s, "`coalesce` takes at least 1 argument, found 0", .{});
                var ty: Type = .null_;
                for (ta, args) |a, x| ty = Type.unify(ty, a.ty) orelse return p.fail(error.Type, x.span, "`coalesce` arguments have different types: {s} and {s}", .{ ty.name(), a.ty.name() });
                break :blk ty;
            },
        };
        return p.new(ty, s, .{ .call = .{ .func = f, .args = ta, .unit = unit } });
    }

    fn aggregate(p: *Planner, name: []const u8, e: *const ast.Expr) PlanError!AggSpec {
        if (e.node != .call or types.aggOf(e.node.call.name) == null)
            return p.fail(error.Type, e.span, "group values must be aggregates like sum(x)", .{});
        const c = e.node.call;
        const f = types.aggOf(c.name).?;
        const s = e.span;
        switch (f) {
            .count => {
                try p.arity(c.name, c.args, 0, 1, s);
                return .{ .name = name, .func = f, .arg = if (c.args.len == 1) try p.expr(c.args[0]) else null, .ty = .int };
            },
            .count_distinct => {
                try p.arity(c.name, c.args, 1, 1, s);
                return .{ .name = name, .func = f, .arg = try p.expr(c.args[0]), .ty = .int };
            },
            .min, .max => {
                try p.arity(c.name, c.args, 1, 1, s);
                const a = try p.expr(c.args[0]);
                return .{ .name = name, .func = f, .arg = a, .ty = a.ty };
            },
            .sum, .avg, .median, .stddev, .p => {
                try p.arity(c.name, c.args, if (f == .p) 2 else 1, if (f == .p) 2 else 1, s);
                const a = try p.expr(c.args[0]);
                try p.want(c.name, a, a.ty.numeric(), "a number", c.args[0].span);
                var q: f64 = 0.5;
                if (f == .p) {
                    const qa = c.args[1];
                    q = switch (qa.node) {
                        .float => |v| v,
                        .int => |v| @floatFromInt(v),
                        else => return p.fail(error.Type, qa.span, "`p` needs a literal quantile between 0 and 1", .{}),
                    };
                    if (!(q >= 0 and q <= 1)) return p.fail(error.Type, qa.span, "`p` needs a literal quantile between 0 and 1", .{});
                }
                const ty: Type = if (f == .sum) (if (a.ty == .null_) .int else a.ty) else .float;
                return .{ .name = name, .func = f, .arg = a, .q = q, .ty = ty };
            },
        }
    }

    // ---- constant folding ----

    fn litOf(e: *const TypedExpr) ?Lit {
        return if (e.node == .lit) e.node.lit else null;
    }

    fn num(l: Lit) ?f64 {
        return switch (l) {
            .int => |i| @floatFromInt(i),
            .float => |f| f,
            else => null,
        };
    }

    /// Folds an operator whose operands are all literals.
    fn fold(p: *Planner, e: *TypedExpr) PlanError!*const TypedExpr {
        switch (e.node) {
            .unary => |u| {
                const x = litOf(u.e) orelse return e;
                const out: Lit = switch (u.op) {
                    .not => if (x == .bool_) .{ .bool_ = !x.bool_ } else return e,
                    .neg => switch (x) {
                        .int => |i| if (i == std.math.minInt(i64)) return e else .{ .int = -i },
                        .float => |f| .{ .float = -f },
                        else => return e,
                    },
                };
                return p.lit(e.span, out);
            },
            .binary => |b| {
                const l = litOf(b.l) orelse return e;
                const r = litOf(b.r) orelse return e;
                const out: Lit = switch (b.op) {
                    .@"and" => if (l == .bool_ and r == .bool_) .{ .bool_ = l.bool_ and r.bool_ } else return e,
                    .@"or" => if (l == .bool_ and r == .bool_) .{ .bool_ = l.bool_ or r.bool_ } else return e,
                    .add, .sub, .mul, .div, .mod => blk: {
                        if (l == .int and r == .int and b.op != .div) {
                            const x = l.int;
                            const y = r.int;
                            break :blk .{ .int = switch (b.op) {
                                .add => std.math.add(i64, x, y) catch return e,
                                .sub => std.math.sub(i64, x, y) catch return e,
                                .mul => std.math.mul(i64, x, y) catch return e,
                                .mod => if (y == 0) return e else @rem(x, y),
                                else => unreachable,
                            } };
                        }
                        const x = num(l) orelse return e;
                        const y = num(r) orelse return e;
                        break :blk .{ .float = switch (b.op) {
                            .add => x + y,
                            .sub => x - y,
                            .mul => x * y,
                            .div => if (y == 0) return e else x / y,
                            .mod => if (y == 0) return e else @rem(x, y),
                            else => unreachable,
                        } };
                    },
                    .eq, .ne, .lt, .le, .gt, .ge => blk: {
                        const ord = order(l, r) orelse return e;
                        break :blk .{ .bool_ = switch (b.op) {
                            .eq => ord == .eq,
                            .ne => ord != .eq,
                            .lt => ord == .lt,
                            .le => ord != .gt,
                            .gt => ord == .gt,
                            .ge => ord != .lt,
                            else => unreachable,
                        } };
                    },
                };
                return p.lit(e.span, out);
            },
            else => return e,
        }
    }

    fn order(l: Lit, r: Lit) ?std.math.Order {
        if (num(l)) |x| if (num(r)) |y| return std.math.order(x, y);
        return switch (l) {
            .string => |a| if (r == .string) std.mem.order(u8, a, r.string) else null,
            .bool_ => |a| if (r == .bool_) std.math.order(@intFromBool(a), @intFromBool(r.bool_)) else null,
            .date => |a| if (r == .date) std.math.order(a, r.date) else null,
            .datetime => |a| if (r == .datetime) std.math.order(a, r.datetime) else null,
            else => null,
        };
    }

    // ---- pushdown and top-k ----

    fn rawOnly(p: *const Planner, e: *const TypedExpr) bool {
        return switch (e.node) {
            .lit => true,
            .col => |c| c < p.source_len,
            .unary => |u| p.rawOnly(u.e),
            .binary => |b| p.rawOnly(b.l) and p.rawOnly(b.r),
            .in_list => |x| blk: {
                if (!p.rawOnly(x.e)) break :blk false;
                for (x.list) |i| if (!p.rawOnly(i)) break :blk false;
                break :blk true;
            },
            .between => |x| p.rawOnly(x.e) and p.rawOnly(x.lo) and p.rawOnly(x.hi),
            .is_null => |x| p.rawOnly(x.e),
            .call => |c| blk: {
                for (c.args) |a| if (!p.rawOnly(a)) break :blk false;
                break :blk true;
            },
            .case => |c| blk: {
                for (c.whens) |w| if (!p.rawOnly(w.cond) or !p.rawOnly(w.then)) break :blk false;
                break :blk if (c.else_) |x| p.rawOnly(x) else true;
            },
        };
    }

    fn conjuncts(p: *Planner, e: *const TypedExpr, out: *std.ArrayList(*const TypedExpr)) !void {
        if (e.node == .binary and e.node.binary.op == .@"and") {
            try p.conjuncts(e.node.binary.l, out);
            try p.conjuncts(e.node.binary.r, out);
        } else try out.append(p.arena, e);
    }

    fn andAll(p: *Planner, es: []const *const TypedExpr) !?*const TypedExpr {
        if (es.len == 0) return null;
        var acc = es[0];
        for (es[1..]) |e| acc = try p.new(.bool_, acc.span.join(e.span), .{ .binary = .{ .op = .@"and", .l = acc, .r = e } });
        return acc;
    }

    /// Moves raw-column conjuncts of the leading `where`/`derive` run into
    /// the filter; empty `where` stages are dropped.
    fn pushdown(p: *Planner, stages: *std.ArrayList(Stage)) !?*const TypedExpr {
        var pushed: std.ArrayList(*const TypedExpr) = .empty;
        var i: usize = 0;
        var shadowed = false;
        while (i < stages.items.len) {
            switch (stages.items[i]) {
                .derive => |ds| {
                    for (ds) |d| shadowed = shadowed or d.target < p.source_len;
                    i += 1;
                },
                .where => |w| {
                    if (shadowed) break;
                    var parts: std.ArrayList(*const TypedExpr) = .empty;
                    try p.conjuncts(w, &parts);
                    var keep: std.ArrayList(*const TypedExpr) = .empty;
                    for (parts.items) |c| try (if (p.rawOnly(c)) &pushed else &keep).append(p.arena, c);
                    if (try p.andAll(keep.items)) |k| {
                        stages.items[i] = .{ .where = k };
                        i += 1;
                    } else _ = stages.orderedRemove(i);
                },
                else => break,
            }
        }
        return p.andAll(pushed.items);
    }

    fn fuseTopk(p: *Planner, stages: *std.ArrayList(Stage)) void {
        _ = p;
        var i: usize = 0;
        while (i + 1 < stages.items.len) : (i += 1) {
            if (stages.items[i] == .sort and stages.items[i + 1] == .limit) {
                const keys = stages.items[i].sort;
                const k = stages.items[i + 1].limit;
                stages.items[i] = .{ .topk = .{ .keys = keys, .k = k } };
                _ = stages.orderedRemove(i + 1);
            }
        }
    }
};
