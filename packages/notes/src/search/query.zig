//! The note search query language (E08.F06.S03.T01), after Obsidian's:
//! whitespace is AND, `OR` (case-sensitive) is OR, `-x` negates, `( )`
//! groups, `"a phrase"` (with `\"`), `/regex/`, `op:term` or `op:(...)`
//! for `file: path: content: tag: line: block: section: task: task-todo:
//! task-done: match-case: ignore-case:`, and property filters `[prop]`,
//! `[prop:value]`, `[prop:null]`, `[prop:<5]`, `[prop:>2024-01-01]`.
//! Errors carry a byte span for underlining. `format` prints a query that
//! parses back to the same tree.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const OpKind = enum {
    file,
    path,
    content,
    tag,
    line,
    block,
    section,
    task,
    task_todo,
    task_done,
    match_case,
    ignore_case,

    /// The operator as written (`task-todo`).
    pub fn text(k: OpKind) []const u8 {
        return switch (k) {
            .task_todo => "task-todo",
            .task_done => "task-done",
            .match_case => "match-case",
            .ignore_case => "ignore-case",
            else => @tagName(k),
        };
    }

    pub fn parse(s: []const u8) ?OpKind {
        inline for (std.meta.fields(OpKind)) |f| {
            const k: OpKind = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, k.text())) return k;
        }
        return null;
    }
};

pub const Term = struct { text: []const u8 };

pub const PropCmp = enum { exists, eq, lt, gt, is_null };

pub const QueryAst = union(enum) {
    term: Term,
    /// The phrase's whitespace-separated words, as written.
    phrase: []const []const u8,
    regex: []const u8,
    and_: []const QueryAst,
    or_: []const QueryAst,
    not: *const QueryAst,
    op: struct { kind: OpKind, arg: *const QueryAst },
    prop: struct { name: []const u8, cmp: PropCmp, value: ?[]const u8 },
};

pub const ParseError = struct { msg: []const u8, span: [2]u32 };

pub const ParseResult = union(enum) { ok: QueryAst, err: ParseError };

/// Parses `q` into a tree in `arena`. An empty query is an empty AND.
pub fn parseQuery(arena: Allocator, q: []const u8) ParseResult {
    var p: Parser = .{ .a = arena, .src = q };
    const r = p.top() catch |e| switch (e) {
        error.OutOfMemory => return .{ .err = .{ .msg = "out of memory", .span = .{ 0, @intCast(q.len) } } },
        error.Syntax => return .{ .err = p.err },
    };
    return .{ .ok = r };
}

const Parser = struct {
    a: Allocator,
    src: []const u8,
    pos: usize = 0,
    depth: u32 = 0,
    err: ParseError = .{ .msg = "", .span = .{ 0, 0 } },

    const Error = error{ OutOfMemory, Syntax };
    const max_depth = 64;

    fn fail(p: *Parser, msg: []const u8, start: usize, end: usize) Error {
        p.err = .{ .msg = msg, .span = .{ @intCast(start), @intCast(@max(end, start)) } };
        return error.Syntax;
    }

    fn skipWs(p: *Parser) void {
        while (p.pos < p.src.len and isWs(p.src[p.pos])) p.pos += 1;
    }

    fn top(p: *Parser) Error!QueryAst {
        p.skipWs();
        if (p.pos >= p.src.len) return .{ .and_ = &.{} };
        const r = try p.parseOr();
        p.skipWs();
        if (p.pos < p.src.len) return p.fail("unmatched )", p.pos, p.pos + 1);
        return r;
    }

    /// Whether the next token is the `OR` keyword.
    fn atOr(p: *Parser) bool {
        p.skipWs();
        const rest = p.src[p.pos..];
        return std.mem.startsWith(u8, rest, "OR") and (rest.len == 2 or isWs(rest[2]) or rest[2] == '(' or rest[2] == ')');
    }

    fn parseOr(p: *Parser) Error!QueryAst {
        if (p.atOr()) return p.fail("OR needs a term on both sides", p.pos, p.pos + 2);
        var items: std.ArrayList(QueryAst) = .empty;
        try items.append(p.a, (try p.parseAnd()) orelse return p.fail("unmatched )", p.pos, p.pos + 1));
        while (p.atOr()) {
            const at = p.pos;
            p.pos += 2;
            const rhs = (try p.parseAnd()) orelse return p.fail("OR needs a term on both sides", at, at + 2);
            try items.append(p.a, rhs);
        }
        if (items.items.len == 1) return items.items[0];
        return .{ .or_ = items.items };
    }

    /// Null when no term follows (end, `)` or `OR`).
    fn parseAnd(p: *Parser) Error!?QueryAst {
        var items: std.ArrayList(QueryAst) = .empty;
        while (true) {
            p.skipWs();
            if (p.pos >= p.src.len or p.src[p.pos] == ')' or p.atOr()) break;
            try items.append(p.a, try p.parseUnary());
        }
        return switch (items.items.len) {
            0 => null,
            1 => items.items[0],
            else => .{ .and_ = items.items },
        };
    }

    fn parseUnary(p: *Parser) Error!QueryAst {
        if (p.src[p.pos] == '-') {
            const at = p.pos;
            p.pos += 1;
            if (p.pos >= p.src.len or isWs(p.src[p.pos]) or p.src[p.pos] == ')') return p.fail("nothing to negate", at, at + 1);
            if (p.atOr()) return p.fail("nothing to negate", at, at + 1);
            try p.enter(at);
            defer p.depth -= 1;
            const inner = try p.a.create(QueryAst);
            inner.* = try p.parseUnary();
            return .{ .not = inner };
        }
        return p.parsePrimary(false);
    }

    fn enter(p: *Parser, at: usize) Error!void {
        p.depth += 1;
        if (p.depth > max_depth) return p.fail("query nests too deeply", at, at + 1);
    }

    /// `arg`: the argument of an operator (words there are never
    /// operators, properties or `-` negations).
    fn parsePrimary(p: *Parser, arg: bool) Error!QueryAst {
        const start = p.pos;
        switch (p.src[start]) {
            '(' => {
                try p.enter(start);
                defer p.depth -= 1;
                p.pos += 1;
                p.skipWs();
                if (p.pos < p.src.len and p.src[p.pos] == ')') return p.fail("empty group", start, p.pos + 1);
                if (p.pos >= p.src.len) return p.fail("unclosed (", start, start + 1);
                const inner = try p.parseOr();
                p.skipWs();
                if (p.pos >= p.src.len or p.src[p.pos] != ')') return p.fail("unclosed (", start, start + 1);
                p.pos += 1;
                return inner;
            },
            '"' => return p.parsePhrase(),
            '/' => return p.parseRegex(),
            '[' => if (!arg) return p.parseProp(),
            ')' => return p.fail("unmatched )", start, start + 1),
            else => {},
        }
        var end = start;
        while (end < p.src.len and !isWs(p.src[end]) and p.src[end] != '(' and p.src[end] != ')') end += 1;
        const w = p.src[start..end];
        p.pos = end;
        if (!arg) if (std.mem.indexOfScalar(u8, w, ':')) |colon| if (OpKind.parse(w[0..colon])) |kind| {
            p.pos = start + colon + 1;
            if (p.pos >= p.src.len or isWs(p.src[p.pos]) or p.src[p.pos] == ')') return p.fail("operator needs an argument", start, p.pos);
            try p.enter(start);
            defer p.depth -= 1;
            const a = try p.a.create(QueryAst);
            a.* = try p.parsePrimary(true);
            return .{ .op = .{ .kind = kind, .arg = a } };
        };
        return .{ .term = .{ .text = w } };
    }

    fn parsePhrase(p: *Parser) Error!QueryAst {
        const start = p.pos;
        var buf: std.ArrayList(u8) = .empty;
        var i = start + 1;
        while (true) : (i += 1) {
            if (i >= p.src.len) return p.fail("unterminated quote", start, p.src.len);
            const c = p.src[i];
            if (c == '"') break;
            if (c == '\\' and i + 1 < p.src.len and (p.src[i + 1] == '"' or p.src[i + 1] == '\\')) {
                i += 1;
                try buf.append(p.a, p.src[i]);
            } else try buf.append(p.a, c);
        }
        p.pos = i + 1;
        var words: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, buf.items, " \t\r\n");
        while (it.next()) |w| try words.append(p.a, w);
        return .{ .phrase = words.items };
    }

    fn parseRegex(p: *Parser) Error!QueryAst {
        const start = p.pos;
        var buf: std.ArrayList(u8) = .empty;
        var i = start + 1;
        while (true) : (i += 1) {
            if (i >= p.src.len) return p.fail("unterminated regex", start, p.src.len);
            const c = p.src[i];
            if (c == '/') break;
            if (c == '\\' and i + 1 < p.src.len) {
                i += 1;
                if (p.src[i] != '/') try buf.append(p.a, '\\');
                try buf.append(p.a, p.src[i]);
            } else try buf.append(p.a, c);
        }
        if (buf.items.len == 0) return p.fail("empty regex", start, i + 1);
        p.pos = i + 1;
        return .{ .regex = buf.items };
    }

    fn parseProp(p: *Parser) Error!QueryAst {
        const start = p.pos;
        // The closing `]`, outside a quoted value.
        var i = start + 1;
        var in_quote = false;
        while (i < p.src.len) : (i += 1) {
            const c = p.src[i];
            if (in_quote) {
                if (c == '\\' and i + 1 < p.src.len) {
                    i += 1;
                } else if (c == '"') in_quote = false;
            } else if (c == '"') {
                in_quote = true;
            } else if (c == ']') break;
        }
        if (i >= p.src.len) return p.fail("unterminated [property]", start, p.src.len);
        p.pos = i + 1;
        const body = p.src[start + 1 .. i];
        const colon = std.mem.indexOfScalar(u8, body, ':');
        const name = std.mem.trim(u8, body[0 .. colon orelse body.len], " \t");
        if (name.len == 0) return p.fail("property name missing", start, i + 1);
        if (std.mem.indexOfScalar(u8, name, '"') != null) return p.fail("property name cannot hold quotes", start, i + 1);
        const c = colon orelse return .{ .prop = .{ .name = name, .cmp = .exists, .value = null } };
        var v = std.mem.trim(u8, body[c + 1 ..], " \t");
        if (v.len == 0) return .{ .prop = .{ .name = name, .cmp = .exists, .value = null } };
        var cmp: PropCmp = .eq;
        if (v[0] == '<' or v[0] == '>') {
            cmp = if (v[0] == '<') .lt else .gt;
            v = std.mem.trim(u8, v[1..], " \t");
            if (v.len == 0) return p.fail("comparison needs a value", start, i + 1);
        } else if (std.mem.eql(u8, v, "null")) {
            return .{ .prop = .{ .name = name, .cmp = .is_null, .value = null } };
        }
        if (v[0] == '"') {
            if (v.len < 2 or v[v.len - 1] != '"') return p.fail("unterminated quote", start, i + 1);
            var buf: std.ArrayList(u8) = .empty;
            var k: usize = 1;
            while (k < v.len - 1) : (k += 1) {
                if (v[k] == '\\' and k + 1 < v.len - 1) k += 1 else if (v[k] == '"') return p.fail("unexpected quote", start, i + 1);
                try buf.append(p.a, v[k]);
            }
            v = buf.items;
        } else if (std.mem.indexOfScalar(u8, v, '"') != null) return p.fail("unexpected quote", start, i + 1);
        return .{ .prop = .{ .name = name, .cmp = cmp, .value = v } };
    }
};

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Prints `q` so that `parseQuery` reads back the same tree.
pub fn format(q: QueryAst, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (q) {
        .term => |t| try w.writeAll(t.text),
        .phrase => |words| {
            try w.writeByte('"');
            for (words, 0..) |word, i| {
                if (i > 0) try w.writeByte(' ');
                for (word) |c| {
                    if (c == '"' or c == '\\') try w.writeByte('\\');
                    try w.writeByte(c);
                }
            }
            try w.writeByte('"');
        },
        .regex => |r| {
            try w.writeByte('/');
            var i: usize = 0;
            while (i < r.len) : (i += 1) {
                if (r[i] == '\\' and i + 1 < r.len) {
                    try w.writeAll(r[i .. i + 2]);
                    i += 1;
                } else if (r[i] == '/') {
                    try w.writeAll("\\/");
                } else try w.writeByte(r[i]);
            }
            try w.writeByte('/');
        },
        .and_ => |items| for (items, 0..) |it, i| {
            if (i > 0) try w.writeByte(' ');
            try group(it, w, it == .or_ or it == .and_);
        },
        .or_ => |items| for (items, 0..) |it, i| {
            if (i > 0) try w.writeAll(" OR ");
            try group(it, w, it == .or_ or it == .and_);
        },
        .not => |inner| {
            try w.writeByte('-');
            try group(inner.*, w, inner.* == .or_ or inner.* == .and_);
        },
        .op => |o| {
            try w.writeAll(o.kind.text());
            try w.writeByte(':');
            try group(o.arg.*, w, switch (o.arg.*) {
                .term, .phrase, .regex => false,
                else => true,
            });
        },
        .prop => |pr| {
            try w.writeByte('[');
            try w.writeAll(pr.name);
            switch (pr.cmp) {
                .exists => {},
                .is_null => try w.writeAll(":null"),
                .eq, .lt, .gt => {
                    try w.writeByte(':');
                    if (pr.cmp == .lt) try w.writeByte('<');
                    if (pr.cmp == .gt) try w.writeByte('>');
                    try propValue(pr.value.?, w);
                },
            }
            try w.writeByte(']');
        },
    }
}

fn group(q: QueryAst, w: *std.Io.Writer, parens: bool) !void {
    if (parens) try w.writeByte('(');
    try format(q, w);
    if (parens) try w.writeByte(')');
}

fn propValue(v: []const u8, w: *std.Io.Writer) !void {
    const plain = v.len > 0 and v[0] != '<' and v[0] != '>' and !std.mem.eql(u8, v, "null") and
        !isWs(v[0]) and !isWs(v[v.len - 1]) and std.mem.indexOfAny(u8, v, "\"\\]") == null;
    if (plain) return w.writeAll(v);
    try w.writeByte('"');
    for (v) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.writeByte('"');
}

/// `format` into a new string.
pub fn toString(a: Allocator, q: QueryAst) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();
    format(q, &w.writer) catch return error.OutOfMemory;
    return w.toOwnedSlice();
}
