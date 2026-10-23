//! The data query language's syntax tree (E13.F06.S02.T01). See
//! docs/formats/data-query.md for the grammar.

const std = @import("std");

pub const Span = struct {
    start: u32,
    end: u32,

    pub fn join(a: Span, b: Span) Span {
        return .{ .start = @min(a.start, b.start), .end = @max(a.end, b.end) };
    }
};

/// Where and why a query was rejected.
pub const Diagnostic = struct {
    span: Span = .{ .start = 0, .end = 0 },
    message: []const u8 = "",

    /// "message at start..end", one line (for tool errors).
    pub fn format(d: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} at {d}..{d}", .{ d.message, d.span.start, d.span.end });
    }
};

pub const UnOp = enum { neg, not };

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    @"and",
    @"or",

    pub fn text(op: BinOp) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .@"and" => "and",
            .@"or" => "or",
        };
    }

    /// Binding strength (higher binds tighter).
    pub fn precedence(op: BinOp) u8 {
        return switch (op) {
            .@"or" => 1,
            .@"and" => 2,
            .eq, .ne, .lt, .le, .gt, .ge => 4,
            .add, .sub => 5,
            .mul, .div, .mod => 6,
        };
    }

    pub fn comparison(op: BinOp) bool {
        return switch (op) {
            .eq, .ne, .lt, .le, .gt, .ge => true,
            else => false,
        };
    }
};

pub const When = struct { cond: *Expr, then: *Expr };

pub const Expr = struct {
    span: Span,
    node: Node,

    pub const Node = union(enum) {
        int: i64,
        float: f64,
        string: []const u8,
        bool_: bool,
        null_,
        /// Days since 1970-01-01.
        date: i32,
        /// Unix milliseconds (UTC).
        datetime: i64,
        column: []const u8,
        unary: struct { op: UnOp, e: *Expr },
        binary: struct { op: BinOp, l: *Expr, r: *Expr },
        in_list: struct { e: *Expr, list: []const *Expr, negated: bool },
        between: struct { e: *Expr, lo: *Expr, hi: *Expr, negated: bool },
        is_null: struct { e: *Expr, negated: bool },
        call: struct { name: []const u8, args: []const *Expr },
        case: struct { whens: []const When, else_: ?*Expr },
    };
};

/// `name = expr` (derive, select, group aggregates); `name` is null for
/// a bare expression in `select`.
pub const Binding = struct { name: ?[]const u8, name_span: Span, expr: *Expr };

pub const SortKey = struct { column: []const u8, span: Span, desc: bool };

pub const Stage = union(enum) {
    from: struct { name: []const u8 },
    where: *Expr,
    derive: []const Binding,
    select: []const Binding,
    group: struct { keys: []const SortKey, aggs: []const Binding },
    sort: []const SortKey,
    limit: u64,
    join: struct { name: []const u8, on: *Expr, left: bool },
    sample: u64,
};

pub const StageNode = struct { span: Span, stage: Stage };

pub const Ast = struct {
    stages: []const StageNode,
};

/// Structural equality, spans ignored (for the format round trip).
pub fn eqlAst(a: Ast, b: Ast) bool {
    if (a.stages.len != b.stages.len) return false;
    for (a.stages, b.stages) |x, y| if (!eqlStage(x.stage, y.stage)) return false;
    return true;
}

fn eqlStage(a: Stage, b: Stage) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .from => |f| std.mem.eql(u8, f.name, b.from.name),
        .where => |e| eqlExpr(e, b.where),
        .derive => |bs| eqlBindings(bs, b.derive),
        .select => |bs| eqlBindings(bs, b.select),
        .group => |g| eqlKeys(g.keys, b.group.keys) and eqlBindings(g.aggs, b.group.aggs),
        .sort => |ks| eqlKeys(ks, b.sort),
        .limit => |n| n == b.limit,
        .join => |j| std.mem.eql(u8, j.name, b.join.name) and j.left == b.join.left and eqlExpr(j.on, b.join.on),
        .sample => |n| n == b.sample,
    };
}

fn eqlKeys(a: []const SortKey, b: []const SortKey) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.desc != y.desc or !std.mem.eql(u8, x.column, y.column)) return false;
    return true;
}

fn eqlBindings(a: []const Binding, b: []const Binding) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if ((x.name == null) != (y.name == null)) return false;
        if (x.name) |n| if (!std.mem.eql(u8, n, y.name.?)) return false;
        if (!eqlExpr(x.expr, y.expr)) return false;
    }
    return true;
}

fn eqlList(a: []const *Expr, b: []const *Expr) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!eqlExpr(x, y)) return false;
    return true;
}

pub fn eqlExpr(a: *const Expr, b: *const Expr) bool {
    if (std.meta.activeTag(a.node) != std.meta.activeTag(b.node)) return false;
    return switch (a.node) {
        .int => |v| v == b.node.int,
        .float => |v| v == b.node.float or (std.math.isNan(v) and std.math.isNan(b.node.float)),
        .string => |v| std.mem.eql(u8, v, b.node.string),
        .bool_ => |v| v == b.node.bool_,
        .null_ => true,
        .date => |v| v == b.node.date,
        .datetime => |v| v == b.node.datetime,
        .column => |v| std.mem.eql(u8, v, b.node.column),
        .unary => |u| u.op == b.node.unary.op and eqlExpr(u.e, b.node.unary.e),
        .binary => |x| x.op == b.node.binary.op and eqlExpr(x.l, b.node.binary.l) and eqlExpr(x.r, b.node.binary.r),
        .in_list => |x| x.negated == b.node.in_list.negated and eqlExpr(x.e, b.node.in_list.e) and eqlList(x.list, b.node.in_list.list),
        .between => |x| x.negated == b.node.between.negated and eqlExpr(x.e, b.node.between.e) and eqlExpr(x.lo, b.node.between.lo) and eqlExpr(x.hi, b.node.between.hi),
        .is_null => |x| x.negated == b.node.is_null.negated and eqlExpr(x.e, b.node.is_null.e),
        .call => |x| std.mem.eql(u8, x.name, b.node.call.name) and eqlList(x.args, b.node.call.args),
        .case => |x| blk: {
            const y = b.node.case;
            if (x.whens.len != y.whens.len or (x.else_ == null) != (y.else_ == null)) break :blk false;
            for (x.whens, y.whens) |p, q| if (!eqlExpr(p.cond, q.cond) or !eqlExpr(p.then, q.then)) break :blk false;
            break :blk if (x.else_) |e| eqlExpr(e, y.else_.?) else true;
        },
    };
}
