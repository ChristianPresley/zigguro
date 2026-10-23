//! Parser and canonical printer of the data query language
//! (E13.F06.S02.T01). Recursive descent over pre-lexed tokens; every
//! error has a byte span and a one-line message. Expression depth
//! (parentheses, operator chains, calls) is limited to 128 and input to
//! 64 KiB, so neither the parser nor later tree walks overflow the stack.

const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const infer = @import("../infer.zig");

const Allocator = std.mem.Allocator;
const Span = ast.Span;
const Expr = ast.Expr;
const Token = lexer.Token;
const Tag = lexer.Tag;

pub const ParseError = error{ Syntax, OutOfMemory };

pub const max_depth = 128;

const ms_per_day = 86_400_000;
const min_datetime: i64 = @as(i64, infer.daysFromCivil(0, 1, 1)) * ms_per_day;
const max_datetime: i64 = @as(i64, infer.daysFromCivil(10000, 1, 1)) * ms_per_day;

pub const keywords = [_][]const u8{
    "from", "where", "derive", "select", "group",   "sort", "limit", "join", "on",    "left", "sample",
    "and",  "or",    "not",    "in",     "between", "is",   "null",  "true", "false", "case", "when",
    "then", "else",  "end",
};

pub fn isKeyword(s: []const u8) bool {
    for (keywords) |k| if (std.ascii.eqlIgnoreCase(s, k)) return true;
    return false;
}

pub fn parse(arena: Allocator, src: []const u8, diag: *ast.Diagnostic) ParseError!ast.Ast {
    var p: Parser = .{ .arena = arena, .diag = diag, .src = src };
    if (src.len > lexer.max_len) return p.fail(.{ .start = 0, .end = 0 }, "query longer than 64 KiB");
    var lx: lexer.Lexer = .init(arena, src);
    var toks: std.ArrayList(Token) = .empty;
    while (true) {
        const t = try lx.next();
        if (t.tag == .invalid) return p.fail(t.span, lx.err);
        try toks.append(arena, t);
        if (t.tag == .eof) break;
    }
    p.toks = toks.items;
    return p.query();
}

const Parser = struct {
    arena: Allocator,
    diag: *ast.Diagnostic,
    src: []const u8,
    toks: []const Token = &.{},
    i: usize = 0,
    depth: u32 = 0,

    fn fail(p: *Parser, span: Span, msg: []const u8) ParseError {
        p.diag.* = .{ .span = span, .message = msg };
        return error.Syntax;
    }

    fn failFmt(p: *Parser, span: Span, comptime fmt: []const u8, args: anytype) ParseError {
        return p.fail(span, try std.fmt.allocPrint(p.arena, fmt, args));
    }

    fn peek(p: *const Parser) Token {
        return p.toks[p.i];
    }

    fn peekAt(p: *const Parser, k: usize) Token {
        return p.toks[@min(p.i + k, p.toks.len - 1)];
    }

    fn advance(p: *Parser) Token {
        const t = p.toks[p.i];
        if (t.tag != .eof) p.i += 1;
        return t;
    }

    fn isKw(t: Token, kw: []const u8) bool {
        return t.tag == .ident and std.ascii.eqlIgnoreCase(t.text, kw);
    }

    fn eatKw(p: *Parser, kw: []const u8) bool {
        if (isKw(p.peek(), kw)) {
            _ = p.advance();
            return true;
        }
        return false;
    }

    fn describe(p: *Parser, t: Token) ![]const u8 {
        if (t.tag == .eof) return "end of query";
        return std.fmt.allocPrint(p.arena, "`{s}`", .{p.src[t.span.start..t.span.end]});
    }

    fn expect(p: *Parser, tag: Tag, what: []const u8) ParseError!Token {
        const t = p.peek();
        if (t.tag != tag) return p.failFmt(t.span, "expected {s}, found {s}", .{ what, try p.describe(t) });
        return p.advance();
    }

    fn query(p: *Parser) ParseError!ast.Ast {
        var stages: std.ArrayList(ast.StageNode) = .empty;
        if (p.peek().tag == .eof) return p.fail(p.peek().span, "empty query");
        while (true) {
            try stages.append(p.arena, try p.stage(stages.items.len));
            const t = p.peek();
            if (t.tag == .eof) break;
            if (t.tag != .pipe) return p.failFmt(t.span, "expected `|` or end of query, found {s}", .{try p.describe(t)});
            _ = p.advance();
        }
        return .{ .stages = stages.items };
    }

    fn stage(p: *Parser, index: usize) ParseError!ast.StageNode {
        const t = p.peek();
        if (t.tag != .ident) return p.failFmt(t.span, "expected a stage (from, where, derive, select, group, sort, limit, join, sample), found {s}", .{try p.describe(t)});
        _ = p.advance();
        const start = t.span.start;
        const st: ast.Stage = if (isKw(t, "from")) blk: {
            if (index != 0) return p.fail(t.span, "`from` must be the first stage");
            break :blk .{ .from = .{ .name = (try p.datasetName()).text } };
        } else if (isKw(t, "where"))
            .{ .where = try p.expr() }
        else if (isKw(t, "derive"))
            .{ .derive = try p.bindings(true, .eof) }
        else if (isKw(t, "select"))
            .{ .select = try p.bindings(false, .eof) }
        else if (isKw(t, "group")) blk: {
            var keys: []const ast.SortKey = &.{};
            if (p.peek().tag != .lbrace) keys = try p.keyList(false);
            _ = try p.expect(.lbrace, "`{` and aggregates");
            const aggs = try p.bindings(true, .rbrace);
            _ = try p.expect(.rbrace, "`}`");
            break :blk .{ .group = .{ .keys = keys, .aggs = aggs } };
        } else if (isKw(t, "sort"))
            .{ .sort = try p.keyList(true) }
        else if (isKw(t, "limit"))
            .{ .limit = try p.count() }
        else if (isKw(t, "sample"))
            .{ .sample = try p.count() }
        else if (isKw(t, "join")) blk: {
            const name = try p.datasetName();
            if (!p.eatKw("on")) return p.failFmt(p.peek().span, "expected `on`, found {s}", .{try p.describe(p.peek())});
            const on = try p.expr();
            const left = p.eatKw("left");
            break :blk .{ .join = .{ .name = name.text, .on = on, .left = left } };
        } else return p.failFmt(t.span, "unknown stage `{s}`", .{t.text});
        const end = if (p.i > 0) p.toks[p.i - 1].span.end else t.span.end;
        return .{ .span = .{ .start = start, .end = end }, .stage = st };
    }

    fn datasetName(p: *Parser) ParseError!Token {
        const t = p.peek();
        switch (t.tag) {
            .string, .quoted_ident => {
                if (t.text.len == 0) return p.fail(t.span, "empty dataset name");
                return p.advance();
            },
            .ident => if (!isKeyword(t.text)) return p.advance(),
            else => {},
        }
        return p.failFmt(t.span, "expected a dataset name, found {s}", .{try p.describe(t)});
    }

    fn count(p: *Parser) ParseError!u64 {
        const t = p.peek();
        if (t.tag != .int) return p.failFmt(t.span, "expected a row count, found {s}", .{try p.describe(t)});
        _ = p.advance();
        return std.fmt.parseInt(u64, t.text, 10) catch p.fail(t.span, "number too large");
    }

    /// A column name where only names are allowed: an identifier, a
    /// backtick name or a string.
    fn columnName(p: *Parser) ParseError!Token {
        const t = p.peek();
        switch (t.tag) {
            .quoted_ident, .string => {
                if (t.text.len == 0) return p.fail(t.span, "empty column name");
                return p.advance();
            },
            .ident => if (!isKeyword(t.text)) return p.advance(),
            else => {},
        }
        return p.failFmt(t.span, "expected a column name, found {s}", .{try p.describe(t)});
    }

    fn keyList(p: *Parser, signed: bool) ParseError![]const ast.SortKey {
        var out: std.ArrayList(ast.SortKey) = .empty;
        while (true) {
            var desc = false;
            const start = p.peek().span.start;
            if (signed and (p.peek().tag == .minus or p.peek().tag == .plus)) desc = p.advance().tag == .minus;
            const n = try p.columnName();
            var end = n.span.end;
            // `col desc` / `col asc` read as well as `-col` / `col`.
            if (signed and (isKw(p.peek(), "desc") or isKw(p.peek(), "asc"))) {
                const d = p.advance();
                desc = desc != isKw(d, "desc");
                end = d.span.end;
            }
            try out.append(p.arena, .{ .column = n.text, .span = .{ .start = start, .end = end }, .desc = desc });
            if (p.peek().tag != .comma) break;
            _ = p.advance();
        }
        return out.items;
    }

    /// `name = expr, ...` (names required when `named`); stops before
    /// `close` (or a pipe/end when `close` is eof). A trailing comma is
    /// allowed before `}`.
    fn bindings(p: *Parser, named: bool, close: Tag) ParseError![]const ast.Binding {
        var out: std.ArrayList(ast.Binding) = .empty;
        while (true) {
            if (close == .rbrace and p.peek().tag == .rbrace and out.items.len > 0) break;
            const t = p.peek();
            const is_name = (t.tag == .quoted_ident or (t.tag == .ident and !isKeyword(t.text)) or t.tag == .string) and p.peekAt(1).tag == .assign;
            if (is_name) {
                if (t.text.len == 0) return p.fail(t.span, "empty column name");
                _ = p.advance();
                _ = p.advance();
                try out.append(p.arena, .{ .name = t.text, .name_span = t.span, .expr = try p.expr() });
            } else if (named) {
                if (t.tag == .ident and !isKeyword(t.text) and p.peekAt(1).tag != .assign) {
                    const n = p.peekAt(1);
                    return p.failFmt(n.span, "expected `=` after `{s}`, found {s}", .{ t.text, try p.describe(n) });
                }
                return p.failFmt(t.span, "expected `name = expression`, found {s}", .{try p.describe(t)});
            } else {
                const e = try p.expr();
                try out.append(p.arena, .{ .name = null, .name_span = e.span, .expr = e });
            }
            if (p.peek().tag != .comma) break;
            _ = p.advance();
        }
        return out.items;
    }

    fn node(p: *Parser, span: Span, n: Expr.Node) ParseError!*Expr {
        const e = try p.arena.create(Expr);
        e.* = .{ .span = span, .node = n };
        return e;
    }

    fn enter(p: *Parser, span: Span) ParseError!void {
        p.depth += 1;
        if (p.depth > max_depth) return p.fail(span, "query nested too deeply");
    }

    pub fn expr(p: *Parser) ParseError!*Expr {
        try p.enter(p.peek().span);
        defer p.depth -= 1;
        return p.orExpr();
    }

    /// Each link of an operator chain deepens the (left-leaning) tree, so
    /// it counts toward the depth limit; `leave` undoes the count.
    fn link(p: *Parser, links: *u32) ParseError!void {
        try p.enter(p.peek().span);
        links.* += 1;
    }

    fn leave(p: *Parser, links: u32) void {
        p.depth -= links;
    }

    fn orExpr(p: *Parser) ParseError!*Expr {
        var links: u32 = 0;
        defer p.leave(links);
        var l = try p.andExpr();
        while (p.eatKw("or")) {
            try p.link(&links);
            const r = try p.andExpr();
            l = try p.node(l.span.join(r.span), .{ .binary = .{ .op = .@"or", .l = l, .r = r } });
        }
        return l;
    }

    fn andExpr(p: *Parser) ParseError!*Expr {
        var links: u32 = 0;
        defer p.leave(links);
        var l = try p.notExpr();
        while (p.eatKw("and")) {
            try p.link(&links);
            const r = try p.notExpr();
            l = try p.node(l.span.join(r.span), .{ .binary = .{ .op = .@"and", .l = l, .r = r } });
        }
        return l;
    }

    fn notExpr(p: *Parser) ParseError!*Expr {
        const t = p.peek();
        if (isKw(t, "not")) {
            _ = p.advance();
            try p.enter(t.span);
            defer p.depth -= 1;
            const e = try p.notExpr();
            return p.node(t.span.join(e.span), .{ .unary = .{ .op = .not, .e = e } });
        }
        return p.cmpExpr();
    }

    fn cmpOp(t: Token) ?ast.BinOp {
        return switch (t.tag) {
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => null,
        };
    }

    fn cmpExpr(p: *Parser) ParseError!*Expr {
        const l = try p.addExpr();
        const t = p.peek();
        if (cmpOp(t)) |op| {
            _ = p.advance();
            const r = try p.addExpr();
            if (cmpOp(p.peek()) != null) return p.fail(p.peek().span, "comparisons can't be chained; use `and`");
            return p.node(l.span.join(r.span), .{ .binary = .{ .op = op, .l = l, .r = r } });
        }
        var negated = false;
        if (isKw(t, "not") and (isKw(p.peekAt(1), "in") or isKw(p.peekAt(1), "between"))) {
            _ = p.advance();
            negated = true;
        }
        if (p.eatKw("in")) {
            _ = try p.expect(.lbracket, "`[`");
            var list: std.ArrayList(*Expr) = .empty;
            if (p.peek().tag != .rbracket) while (true) {
                try list.append(p.arena, try p.expr());
                if (p.peek().tag != .comma) break;
                _ = p.advance();
            };
            const close = try p.expect(.rbracket, "`,` or `]`");
            return p.node(l.span.join(close.span), .{ .in_list = .{ .e = l, .list = list.items, .negated = negated } });
        }
        if (p.eatKw("between")) {
            const lo = try p.addExpr();
            if (!p.eatKw("and")) return p.failFmt(p.peek().span, "expected `and` in `between`, found {s}", .{try p.describe(p.peek())});
            const hi = try p.addExpr();
            return p.node(l.span.join(hi.span), .{ .between = .{ .e = l, .lo = lo, .hi = hi, .negated = negated } });
        }
        if (isKw(t, "is")) {
            _ = p.advance();
            const neg = p.eatKw("not");
            const n = p.peek();
            if (!isKw(n, "null")) return p.failFmt(n.span, "expected `null` after `is`, found {s}", .{try p.describe(n)});
            _ = p.advance();
            return p.node(l.span.join(n.span), .{ .is_null = .{ .e = l, .negated = neg } });
        }
        return l;
    }

    fn addExpr(p: *Parser) ParseError!*Expr {
        var links: u32 = 0;
        defer p.leave(links);
        var l = try p.mulExpr();
        while (true) {
            const op: ast.BinOp = switch (p.peek().tag) {
                .plus => .add,
                .minus => .sub,
                else => return l,
            };
            _ = p.advance();
            try p.link(&links);
            const r = try p.mulExpr();
            l = try p.node(l.span.join(r.span), .{ .binary = .{ .op = op, .l = l, .r = r } });
        }
    }

    fn mulExpr(p: *Parser) ParseError!*Expr {
        var links: u32 = 0;
        defer p.leave(links);
        var l = try p.unaryExpr();
        while (true) {
            const op: ast.BinOp = switch (p.peek().tag) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => return l,
            };
            _ = p.advance();
            try p.link(&links);
            const r = try p.unaryExpr();
            l = try p.node(l.span.join(r.span), .{ .binary = .{ .op = op, .l = l, .r = r } });
        }
    }

    fn unaryExpr(p: *Parser) ParseError!*Expr {
        const t = p.peek();
        if (t.tag == .minus) {
            _ = p.advance();
            try p.enter(t.span);
            defer p.depth -= 1;
            const e = try p.unaryExpr();
            return p.node(t.span.join(e.span), .{ .unary = .{ .op = .neg, .e = e } });
        }
        return p.primary();
    }

    fn primary(p: *Parser) ParseError!*Expr {
        const t = p.peek();
        switch (t.tag) {
            .int => {
                _ = p.advance();
                const v = std.fmt.parseInt(i64, t.text, 10) catch return p.fail(t.span, "number too large");
                return p.node(t.span, .{ .int = v });
            },
            .float => {
                _ = p.advance();
                const v = std.fmt.parseFloat(f64, t.text) catch return p.fail(t.span, "invalid number");
                if (std.math.isInf(v)) return p.fail(t.span, "number too large");
                return p.node(t.span, .{ .float = v });
            },
            .string => {
                _ = p.advance();
                return p.node(t.span, .{ .string = t.text });
            },
            .date => {
                _ = p.advance();
                return p.node(t.span, .{ .date = infer.parseIsoDate(t.text).? });
            },
            .datetime => {
                _ = p.advance();
                const v = infer.parseDatetime(t.text).?;
                // Years 0..9999 in UTC, so the value prints back as a literal.
                if (v < min_datetime or v >= max_datetime) return p.fail(t.span, "datetime out of range");
                return p.node(t.span, .{ .datetime = v });
            },
            .quoted_ident => {
                _ = p.advance();
                return p.node(t.span, .{ .column = t.text });
            },
            .lparen => {
                _ = p.advance();
                const e = try p.expr();
                const close = try p.expect(.rparen, "`)`");
                e.span = t.span.join(close.span);
                return e;
            },
            .ident => {
                if (isKw(t, "true") or isKw(t, "false")) {
                    _ = p.advance();
                    return p.node(t.span, .{ .bool_ = isKw(t, "true") });
                }
                if (isKw(t, "null")) {
                    _ = p.advance();
                    return p.node(t.span, .null_);
                }
                if (isKw(t, "case")) return p.caseExpr();
                if (isKeyword(t.text)) return p.failFmt(t.span, "expected an expression, found keyword `{s}`", .{t.text});
                _ = p.advance();
                if (p.peek().tag == .lparen) return p.call(t);
                return p.node(t.span, .{ .column = t.text });
            },
            else => return p.failFmt(t.span, "expected an expression, found {s}", .{try p.describe(t)}),
        }
    }

    fn call(p: *Parser, name: Token) ParseError!*Expr {
        _ = p.advance(); // (
        var args: std.ArrayList(*Expr) = .empty;
        if (p.peek().tag != .rparen) while (true) {
            try args.append(p.arena, try p.expr());
            if (p.peek().tag != .comma) break;
            _ = p.advance();
        };
        const close = try p.expect(.rparen, "`,` or `)`");
        return p.node(name.span.join(close.span), .{ .call = .{ .name = try std.ascii.allocLowerString(p.arena, name.text), .args = args.items } });
    }

    fn caseExpr(p: *Parser) ParseError!*Expr {
        const start = p.advance();
        var whens: std.ArrayList(ast.When) = .empty;
        while (p.eatKw("when")) {
            const cond = try p.expr();
            if (!p.eatKw("then")) return p.failFmt(p.peek().span, "expected `then`, found {s}", .{try p.describe(p.peek())});
            try whens.append(p.arena, .{ .cond = cond, .then = try p.expr() });
        }
        if (whens.items.len == 0) return p.failFmt(p.peek().span, "expected `when`, found {s}", .{try p.describe(p.peek())});
        const else_: ?*Expr = if (p.eatKw("else")) try p.expr() else null;
        const end = p.peek();
        if (!isKw(end, "end")) return p.failFmt(end.span, "expected `end`, found {s}", .{try p.describe(end)});
        _ = p.advance();
        return p.node(start.span.join(end.span), .{ .case = .{ .whens = whens.items, .else_ = else_ } });
    }
};

// ---- canonical printing ----

/// Prints `a` in canonical form: lowercase keywords, single spaces,
/// ` | ` between stages and only the parentheses precedence needs.
pub fn formatQuery(a: *const ast.Ast, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (a.stages, 0..) |s, i| {
        if (i > 0) try w.writeAll(" | ");
        switch (s.stage) {
            .from => |f| {
                try w.writeAll("from ");
                try writeName(w, f.name);
            },
            .where => |e| {
                try w.writeAll("where ");
                try writeExpr(w, e, 0);
            },
            .derive => |bs| {
                try w.writeAll("derive ");
                try writeBindings(w, bs);
            },
            .select => |bs| {
                try w.writeAll("select ");
                try writeBindings(w, bs);
            },
            .group => |g| {
                try w.writeAll("group ");
                if (g.keys.len > 0) {
                    try writeKeys(w, g.keys);
                    try w.writeAll(" ");
                }
                try w.writeAll("{ ");
                try writeBindings(w, g.aggs);
                try w.writeAll(" }");
            },
            .sort => |ks| {
                try w.writeAll("sort ");
                try writeKeys(w, ks);
            },
            .limit => |n| try w.print("limit {d}", .{n}),
            .sample => |n| try w.print("sample {d}", .{n}),
            .join => |j| {
                try w.writeAll("join ");
                try writeName(w, j.name);
                try w.writeAll(" on ");
                try writeExpr(w, j.on, 0);
                if (j.left) try w.writeAll(" left");
            },
        }
    }
}

fn writeKeys(w: *std.Io.Writer, ks: []const ast.SortKey) !void {
    for (ks, 0..) |k, i| {
        if (i > 0) try w.writeAll(", ");
        if (k.desc) try w.writeAll("-");
        try writeName(w, k.column);
    }
}

fn writeBindings(w: *std.Io.Writer, bs: []const ast.Binding) !void {
    for (bs, 0..) |b, i| {
        if (i > 0) try w.writeAll(", ");
        if (b.name) |n| {
            try writeName(w, n);
            try w.writeAll(" = ");
        }
        try writeExpr(w, b.expr, 0);
    }
}

pub fn writeName(w: *std.Io.Writer, n: []const u8) !void {
    var plain = n.len > 0 and !std.ascii.isDigit(n[0]) and !isKeyword(n);
    for (n) |c| plain = plain and (std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80);
    if (plain) return w.writeAll(n);
    try w.writeByte('`');
    for (n) |c| {
        if (c == '`') try w.writeByte('`');
        try w.writeByte(c);
    }
    try w.writeByte('`');
}

pub fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

const prec_not = 3;
const prec_cmp = 4;
const prec_unary = 7;

fn exprPrec(e: *const Expr) u8 {
    return switch (e.node) {
        .binary => |b| b.op.precedence(),
        .unary => |u| if (u.op == .not) prec_not else prec_unary,
        .in_list, .between, .is_null => prec_cmp,
        else => 9,
    };
}

pub fn writeExpr(w: *std.Io.Writer, e: *const Expr, min: u8) std.Io.Writer.Error!void {
    const p = exprPrec(e);
    const paren = p < min;
    if (paren) try w.writeByte('(');
    switch (e.node) {
        .int => |v| try w.print("{d}", .{v}),
        .float => |v| try writeFloat(w, v),
        .string => |s| try writeString(w, s),
        .bool_ => |b| try w.writeAll(if (b) "true" else "false"),
        .null_ => try w.writeAll("null"),
        .date => |d| try writeDate(w, d),
        .datetime => |t| try writeDatetime(w, t),
        .column => |c| try writeName(w, c),
        .unary => |u| {
            if (u.op == .not) {
                try w.writeAll("not ");
                try writeExpr(w, u.e, prec_not);
            } else {
                try w.writeByte('-');
                // `- -x` keeps a space so it doesn't read as one token.
                if (u.e.node == .unary and u.e.node.unary.op == .neg) try w.writeByte(' ');
                try writeExpr(w, u.e, prec_unary);
            }
        },
        .binary => |b| {
            const bp = b.op.precedence();
            const cmp = b.op.comparison();
            try writeExpr(w, b.l, if (cmp) bp + 1 else bp);
            try w.print(" {s} ", .{b.op.text()});
            try writeExpr(w, b.r, bp + 1);
        },
        .in_list => |x| {
            try writeExpr(w, x.e, prec_cmp + 1);
            try w.writeAll(if (x.negated) " not in [" else " in [");
            for (x.list, 0..) |item, i| {
                if (i > 0) try w.writeAll(", ");
                try writeExpr(w, item, 0);
            }
            try w.writeByte(']');
        },
        .between => |x| {
            try writeExpr(w, x.e, prec_cmp + 1);
            try w.writeAll(if (x.negated) " not between " else " between ");
            try writeExpr(w, x.lo, prec_cmp + 1);
            try w.writeAll(" and ");
            try writeExpr(w, x.hi, prec_cmp + 1);
        },
        .is_null => |x| {
            try writeExpr(w, x.e, prec_cmp + 1);
            try w.writeAll(if (x.negated) " is not null" else " is null");
        },
        .call => |c| {
            try w.print("{s}(", .{c.name});
            for (c.args, 0..) |a, i| {
                if (i > 0) try w.writeAll(", ");
                try writeExpr(w, a, 0);
            }
            try w.writeByte(')');
        },
        .case => |c| {
            try w.writeAll("case");
            for (c.whens) |wh| {
                try w.writeAll(" when ");
                try writeExpr(w, wh.cond, 0);
                try w.writeAll(" then ");
                try writeExpr(w, wh.then, 0);
            }
            if (c.else_) |x| {
                try w.writeAll(" else ");
                try writeExpr(w, x, 0);
            }
            try w.writeAll(" end");
        },
    }
    if (paren) try w.writeByte(')');
}

fn writeFloat(w: *std.Io.Writer, v: f64) !void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{e}", .{v}) catch unreachable;
    // Shortest round-trip form; keep a `.` or exponent so it reads back as
    // a float.
    var dec: [64]u8 = undefined;
    const d = std.fmt.bufPrint(&dec, "{d}", .{v}) catch s;
    const pick = if (d.len <= s.len) d else s;
    try w.writeAll(pick);
    if (std.mem.indexOfAny(u8, pick, ".eEn") == null) try w.writeAll(".0");
}

pub fn writeDate(w: *std.Io.Writer, days: i32) !void {
    const c = infer.civilFromDays(days);
    if (c.y < 0 or c.y > 9999) return w.print("{d}-{d:0>2}-{d:0>2}", .{ c.y, c.m, c.d });
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(c.y)), c.m, c.d });
}

pub fn writeDatetime(w: *std.Io.Writer, ms: i64) !void {
    const secs = @divFloor(ms, 1000);
    const days: i32 = @intCast(@divFloor(secs, 86400));
    try writeDate(w, days);
    const rem: u64 = @intCast(secs - @as(i64, days) * 86400);
    try w.print("T{d:0>2}:{d:0>2}:{d:0>2}", .{ rem / 3600, rem / 60 % 60, rem % 60 });
    const frac = @mod(ms, 1000);
    if (frac != 0) try w.print(".{d:0>3}", .{@as(u64, @intCast(frac))});
    try w.writeByte('Z');
}
