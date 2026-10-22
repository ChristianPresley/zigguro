//! The revset parser. Precedence, high to low:
//!
//! 1. postfix `x-`, `x+`
//! 2. ranges `::x`, `x::`, `x::y`, `..x`, `x..`, `x..y` (not chainable)
//! 3. prefix `~x`
//! 4. `x & y`
//! 5. `x ~ y`
//! 6. `x | y`
//!
//! Primaries are `(expr)`, calls `name(args)`, patterns `kind:"text"` (or
//! `kind:symbol`), symbols, quoted strings, `@`, `name@` and
//! `name@remote`. `::` alone is every visible commit.

const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const Node = ast.Node;
const Span = ast.Span;
const Token = lexer.Token;
const Allocator = std.mem.Allocator;

/// Where and why parsing (or name checking) failed.
pub const ParseError = struct {
    span: Span = .{ 0, 0 },
    message: []const u8 = "",
    suggestion: ?[]const u8 = null,

    pub fn format(e: ParseError, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}..{d}: {s}", .{ e.span[0], e.span[1], e.message });
        if (e.suggestion) |s| try w.print(" (did you mean `{s}`?)", .{s});
    }
};

pub const Error = error{ ParseFailed, OutOfMemory };

/// Nesting deeper than this is refused (bounds recursion).
pub const max_depth = 256;

/// Parses `src` into a tree allocated in `arena`. On failure `diag` says
/// where and why.
pub fn parse(arena: Allocator, src: []const u8, diag: *ParseError) Error!*Node {
    var p: Parser = .{ .lx = .{ .src = src, .arena = arena }, .arena = arena, .diag = diag };
    try p.advance();
    const n = try p.expr();
    if (p.tok.tag != .eof) return p.fail(p.tok.span, "unexpected {s} after the expression", .{describe(p.tok)});
    return n;
}

const Parser = struct {
    lx: lexer.Lexer,
    arena: Allocator,
    diag: *ParseError,
    tok: Token = undefined,
    depth: u32 = 0,

    fn advance(p: *Parser) Error!void {
        p.tok = p.lx.next() catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidCharacter => p.fail(p.lx.err_span, "unexpected character `{s}`", .{p.lx.src[p.lx.err_span[0]..p.lx.err_span[1]]}),
            error.UnterminatedString => p.fail(p.lx.err_span, "unterminated string", .{}),
            error.InvalidEscape => p.fail(p.lx.err_span, "invalid escape in string", .{}),
        };
    }

    fn fail(p: *Parser, span: Span, comptime fmt: []const u8, args: anytype) Error {
        p.diag.* = .{ .span = span, .message = try std.fmt.allocPrint(p.arena, fmt, args) };
        return error.ParseFailed;
    }

    fn node(p: *Parser, span: Span, kind: Node.Kind) Error!*Node {
        const n = try p.arena.create(Node);
        n.* = .{ .span = span, .kind = kind };
        return n;
    }

    fn binary(p: *Parser, op: ast.BinaryOp, lhs: *Node, rhs: *Node) Error!*Node {
        return p.node(.{ lhs.span[0], rhs.span[1] }, .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } });
    }

    fn expr(p: *Parser) Error!*Node {
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > max_depth) return p.fail(p.tok.span, "expression nested too deeply", .{});
        var lhs = try p.diff();
        while (p.tok.tag == .pipe) {
            try p.advance();
            lhs = try p.binary(.@"union", lhs, try p.diff());
        }
        return lhs;
    }

    fn diff(p: *Parser) Error!*Node {
        var lhs = try p.inter();
        while (p.tok.tag == .tilde) {
            try p.advance();
            lhs = try p.binary(.difference, lhs, try p.inter());
        }
        return lhs;
    }

    fn inter(p: *Parser) Error!*Node {
        var lhs = try p.neg();
        while (p.tok.tag == .amp) {
            try p.advance();
            lhs = try p.binary(.intersection, lhs, try p.neg());
        }
        return lhs;
    }

    fn neg(p: *Parser) Error!*Node {
        if (p.tok.tag != .tilde) return p.range();
        const start = p.tok.span[0];
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > max_depth) return p.fail(p.tok.span, "expression nested too deeply", .{});
        try p.advance();
        const operand = try p.neg();
        return p.node(.{ start, operand.span[1] }, .{ .prefix = .{ .op = .negate, .operand = operand } });
    }

    fn startsPrimary(t: lexer.Tag) bool {
        return switch (t) {
            .symbol, .string, .at, .lparen => true,
            else => false,
        };
    }

    fn range(p: *Parser) Error!*Node {
        if (p.tok.tag == .dag or p.tok.tag == .range) {
            const op_tok = p.tok;
            try p.advance();
            if (!startsPrimary(p.tok.tag)) {
                if (op_tok.tag == .dag) return p.node(op_tok.span, .all);
                return p.fail(op_tok.span, "`..` needs an operand", .{});
            }
            const operand = try p.postfix();
            try p.noChain();
            const op: ast.PrefixOp = if (op_tok.tag == .dag) .dag_to else .range_to;
            return p.node(.{ op_tok.span[0], operand.span[1] }, .{ .prefix = .{ .op = op, .operand = operand } });
        }
        const lhs = try p.postfix();
        if (p.tok.tag != .dag and p.tok.tag != .range) return lhs;
        const op_tok = p.tok;
        try p.advance();
        const is_dag = op_tok.tag == .dag;
        if (!startsPrimary(p.tok.tag)) {
            const op: ast.PostfixOp = if (is_dag) .dag_from else .range_from;
            return p.node(.{ lhs.span[0], op_tok.span[1] }, .{ .postfix = .{ .op = op, .operand = lhs } });
        }
        const rhs = try p.postfix();
        try p.noChain();
        return p.binary(if (is_dag) .dag_range else .range, lhs, rhs);
    }

    fn noChain(p: *Parser) Error!void {
        if (p.tok.tag == .dag or p.tok.tag == .range)
            return p.fail(p.tok.span, "ranges cannot be chained; add parentheses", .{});
    }

    fn postfix(p: *Parser) Error!*Node {
        var n = try p.primary();
        while (p.tok.tag == .minus or p.tok.tag == .plus) {
            const op: ast.PostfixOp = if (p.tok.tag == .minus) .parents else .children;
            const end = p.tok.span[1];
            try p.advance();
            n = try p.node(.{ n.span[0], end }, .{ .postfix = .{ .op = op, .operand = n } });
        }
        return n;
    }

    fn primary(p: *Parser) Error!*Node {
        const t = p.tok;
        switch (t.tag) {
            .lparen => {
                try p.advance();
                const inner = try p.expr();
                if (p.tok.tag != .rparen) return p.fail(p.tok.span, "expected `)`, found {s}", .{describe(p.tok)});
                try p.advance();
                return inner;
            },
            .at => {
                try p.advance();
                return p.node(t.span, .{ .working_copy = "" });
            },
            .symbol, .string => {
                try p.advance();
                if (t.tag == .symbol and p.tok.tag == .lparen) return p.call(t);
                if (t.tag == .symbol and p.tok.tag == .colon) {
                    try p.advance();
                    const v = p.tok;
                    if (v.tag != .string and v.tag != .symbol) return p.fail(v.span, "expected a pattern after `{s}:`", .{t.text});
                    try p.advance();
                    return p.node(.{ t.span[0], v.span[1] }, .{ .pattern = .{ .kind = t.text, .text = v.text } });
                }
                if (p.tok.tag == .at and p.tok.span[0] == t.span[1]) {
                    const at_end = p.tok.span[1];
                    try p.advance();
                    if ((p.tok.tag == .symbol or p.tok.tag == .string) and p.tok.span[0] == at_end) {
                        const r = p.tok;
                        try p.advance();
                        return p.node(.{ t.span[0], r.span[1] }, .{ .remote_symbol = .{ .name = t.text, .remote = r.text } });
                    }
                    return p.node(.{ t.span[0], at_end }, .{ .working_copy = t.text });
                }
                return p.node(t.span, .{ .symbol = t.text });
            },
            else => return p.fail(t.span, "expected a revision, found {s}", .{describe(t)}),
        }
    }

    fn call(p: *Parser, name: Token) Error!*Node {
        try p.advance(); // (
        var args: std.ArrayList(*Node) = .empty;
        if (p.tok.tag != .rparen) {
            while (true) {
                try args.append(p.arena, try p.expr());
                if (p.tok.tag == .comma) {
                    try p.advance();
                    continue;
                }
                break;
            }
        }
        if (p.tok.tag != .rparen) return p.fail(p.tok.span, "expected `,` or `)`, found {s}", .{describe(p.tok)});
        const end = p.tok.span[1];
        try p.advance();
        return p.node(.{ name.span[0], end }, .{ .call = .{ .name = name.text, .name_span = name.span, .args = args.items } });
    }
};

fn describe(t: Token) []const u8 {
    return switch (t.tag) {
        .symbol => "a symbol",
        .string => "a string",
        .at => "`@`",
        .colon => "`:`",
        .dag => "`::`",
        .range => "`..`",
        .amp => "`&`",
        .pipe => "`|`",
        .tilde => "`~`",
        .minus => "`-`",
        .plus => "`+`",
        .lparen => "`(`",
        .rparen => "`)`",
        .comma => "`,`",
        .eof => "the end of the input",
    };
}

/// Levenshtein distance, capped: returns `cap + 1` once it is exceeded.
pub fn editDistance(a: []const u8, b: []const u8, comptime cap: usize) usize {
    if (a.len > b.len + cap or b.len > a.len + cap) return cap + 1;
    if (b.len > 64) return cap + 1;
    var prev: [65]usize = undefined;
    var cur: [65]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        var row_min = cur[0];
        for (b, 0..) |cb, j| {
            const sub = prev[j] + @intFromBool(ca != cb);
            cur[j + 1] = @min(sub, @min(prev[j + 1] + 1, cur[j] + 1));
            row_min = @min(row_min, cur[j + 1]);
        }
        if (row_min > cap) return cap + 1;
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// The closest of `candidates` to `name` within distance 2, if any.
pub fn suggest(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: usize = 3;
    for (candidates) |c| {
        const d = editDistance(name, c, 2);
        if (d < best_d) {
            best_d = d;
            best = c;
        }
    }
    return best;
}
