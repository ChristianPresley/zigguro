//! When-clauses: VS Code-compatible boolean expressions over context keys,
//! parsed to an AST, compiled to compact bytecode and evaluated without
//! allocation.
//!
//! Grammar (precedence `!` > comparison > `&&` > `||`):
//! ```
//! expr := or ; or := and ('||' and)* ; and := unary ('&&' unary)*
//! unary := '!' unary | cmp
//! cmp := primary [ ('=='|'!='|'==='|'!=='|'<'|'<='|'>'|'>=') value | '=~' regex | ['not'] 'in' key ]
//! primary := '(' expr ')' | 'true' | 'false' | key
//! value := bareword | 'single quoted' | number ; regex := '/' body '/' flags
//! key := [A-Za-z_$][A-Za-z0-9_.:$-]*
//! ```
//! `<`, `<=`, `>`, `>=` need whitespace on both sides so keys may contain
//! `-`. The right side of `==` is always a literal. `config.<setting>`
//! reads the settings snapshot.

const std = @import("std");
const context = @import("context.zig");
const diag = @import("../diag.zig");
const regex_lite = @import("../regex_lite.zig");

const Allocator = std.mem.Allocator;
const CtxValue = context.CtxValue;
const KeyId = context.KeyId;
const ContextKeyService = context.ContextKeyService;
const EvalEnv = context.EvalEnv;
const Diags = diag.Diags;
const Span = diag.Span;

/// Comparison operators.
pub const CmpOp = enum { eq, ne, lt, le, gt, ge };

/// A parsed expression.
pub const Expr = union(enum) {
    true,
    false,
    key: Key,
    not: *const Expr,
    @"and": [2]*const Expr,
    @"or": [2]*const Expr,
    cmp: struct { key: Key, op: CmpOp, lit: []const u8 },
    match: struct { key: Key, regex: u32, src: []const u8 },
    in: struct { key: Key, list: Key, negated: bool },

    /// A key reference.
    pub const Key = struct { name: []const u8, id: ?KeyId };
};

/// Bytecode ops; each word is `op:8 | a:24`.
pub const Op = enum(u8) {
    /// Push key `a` (index into `keys`).
    load_key,
    /// Push setting value for key `a` (a `config.*` key).
    load_config,
    /// Push constant string `a`.
    load_const,
    truthy,
    not,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    /// Pop; push whether it matches regex `a`.
    match,
    in,
    not_in,
    /// If top is false, jump to `a` keeping it; else pop.
    jmp_if_false_keep,
    /// If top is true, jump to `a` keeping it; else pop.
    jmp_if_true_keep,
    push_true,
    push_false,
    ret,
};

/// Maximum evaluation stack depth.
pub const max_stack = 32;

/// A compiled clause. Owns its memory.
pub const When = struct {
    arena: std.heap.ArenaAllocator,
    code: []const u32,
    consts: []const []const u8,
    keys: []const Expr.Key,
    regexes: []const regex_lite.Regex,
    /// Parsed AST (for DNF and formatting).
    ast: *const Expr,
    /// Canonical text.
    text: []const u8,

    /// Parses and compiles `src`. Errors go to `diags` with byte offsets
    /// into `src`, and return `error.InvalidWhen`.
    pub fn compile(gpa: Allocator, src: []const u8, keys: ?*ContextKeyService, diags: *Diags) error{ OutOfMemory, InvalidWhen }!When {
        var w: When = .{ .arena = .init(gpa), .code = &.{}, .consts = &.{}, .keys = &.{}, .regexes = &.{}, .ast = undefined, .text = "" };
        errdefer w.arena.deinit();
        const a = w.arena.allocator();
        var p: Parser = .{ .a = a, .src = src, .diags = diags, .svc = keys };
        const errors_before = diags.errorCount();
        p.skipWs();
        const ast = p.parseOr() catch |e| switch (e) {
            error.Syntax => return error.InvalidWhen,
            error.OutOfMemory => return error.OutOfMemory,
        };
        p.skipWs();
        if (p.i < src.len) {
            p.err("unexpected '{c}'", .{src[p.i]});
            return error.InvalidWhen;
        }
        if (diags.errorCount() != errors_before) return error.InvalidWhen;
        w.ast = ast;
        w.regexes = p.regexes.items;
        var c: Compiler = .{ .a = a };
        try c.emitExpr(ast);
        try c.op(.ret, 0);
        if (c.max_depth > max_stack) {
            diags.add(.{ .start = 0, .end = @intCast(src.len) }, .err, "expression is nested too deeply", .{});
            return error.InvalidWhen;
        }
        w.code = c.code.items;
        w.consts = c.consts.items;
        w.keys = c.keys.items;
        var aw: std.Io.Writer.Allocating = .init(a);
        formatExpr(ast, &aw.writer, 0) catch return error.OutOfMemory;
        w.text = aw.written();
        return w;
    }

    /// Frees the clause.
    pub fn deinit(w: *When) void {
        w.arena.deinit();
    }

    /// Evaluates against `env`. Never allocates.
    pub fn eval(w: *const When, env: *const EvalEnv) bool {
        var stack: [max_stack]CtxValue = undefined;
        var sp: usize = 0;
        var pc: usize = 0;
        while (true) {
            const word = w.code[pc];
            pc += 1;
            const op: Op = @enumFromInt(word >> 24);
            const a: u32 = word & 0xFF_FFFF;
            switch (op) {
                .load_key => {
                    const k = w.keys[a];
                    stack[sp] = env.lookup(k.name, k.id);
                    sp += 1;
                },
                .load_config => {
                    stack[sp] = env.config(w.keys[a].name["config.".len..]);
                    sp += 1;
                },
                .load_const => {
                    stack[sp] = .{ .str = w.consts[a] };
                    sp += 1;
                },
                .push_true, .push_false => {
                    stack[sp] = .{ .bool = op == .push_true };
                    sp += 1;
                },
                // Compute into a temporary first: assigning a union in place
                // would set the tag before the old payload is read.
                .truthy => {
                    const t = stack[sp - 1].truthy();
                    stack[sp - 1] = .{ .bool = t };
                },
                .not => {
                    const t = !stack[sp - 1].truthy();
                    stack[sp - 1] = .{ .bool = t };
                },
                .eq, .ne, .lt, .le, .gt, .ge => {
                    const r = compare(op, stack[sp - 2], stack[sp - 1]);
                    sp -= 1;
                    stack[sp - 1] = .{ .bool = r };
                },
                .match => {
                    var buf: [64]u8 = undefined;
                    const t = stack[sp - 1].text(&buf);
                    const m = if (t) |s| w.regexes[a].isMatch(s) else false;
                    stack[sp - 1] = .{ .bool = m };
                },
                .in, .not_in => {
                    var buf: [64]u8 = undefined;
                    const item = stack[sp - 2].text(&buf);
                    const hit = if (item) |s| switch (stack[sp - 1]) {
                        .list => |l| for (l) |x| {
                            if (std.mem.eql(u8, x, s)) break true;
                        } else false,
                        else => false,
                    } else false;
                    sp -= 1;
                    stack[sp - 1] = .{ .bool = if (op == .in) hit else !hit };
                },
                .jmp_if_false_keep, .jmp_if_true_keep => {
                    const t = stack[sp - 1].truthy();
                    if (t == (op == .jmp_if_true_keep)) {
                        stack[sp - 1] = .{ .bool = t };
                        pc = a;
                    } else sp -= 1;
                },
                .ret => return stack[sp - 1].truthy(),
            }
        }
    }

    /// Writes the canonical text.
    pub fn format(w: *const When, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(w.text);
    }
};

fn compare(op: Op, l: CtxValue, r: CtxValue) bool {
    switch (op) {
        .eq, .ne => {
            var b1: [64]u8 = undefined;
            var b2: [64]u8 = undefined;
            const lt = l.text(&b1);
            const rt = r.text(&b2);
            const same = lt != null and rt != null and std.mem.eql(u8, lt.?, rt.?);
            return if (op == .eq) same else !same;
        },
        else => {
            const x = l.number() orelse return false;
            const y = r.number() orelse return false;
            return switch (op) {
                .lt => x < y,
                .le => x <= y,
                .gt => x > y,
                .ge => x >= y,
                else => unreachable,
            };
        },
    }
}

const Parser = struct {
    a: Allocator,
    src: []const u8,
    i: usize = 0,
    diags: *Diags,
    svc: ?*ContextKeyService,
    regexes: std.ArrayList(regex_lite.Regex) = .empty,
    depth: u32 = 0,

    const PErr = error{ Syntax, OutOfMemory };

    fn err(p: *Parser, comptime fmt: []const u8, args: anytype) void {
        const end = @min(p.i + 1, p.src.len);
        p.diags.add(.{ .start = @intCast(p.i), .end = @intCast(end) }, .err, fmt, args);
    }

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) PErr {
        p.err(fmt, args);
        return error.Syntax;
    }

    fn skipWs(p: *Parser) void {
        while (p.i < p.src.len and std.ascii.isWhitespace(p.src[p.i])) p.i += 1;
    }

    fn eat(p: *Parser, s: []const u8) bool {
        p.skipWs();
        if (std.mem.startsWith(u8, p.src[p.i..], s)) {
            p.i += s.len;
            return true;
        }
        return false;
    }

    fn node(p: *Parser, e: Expr) PErr!*const Expr {
        const n = try p.a.create(Expr);
        n.* = e;
        return n;
    }

    fn parseOr(p: *Parser) PErr!*const Expr {
        var l = try p.parseAnd();
        while (p.eat("||")) l = try p.node(.{ .@"or" = .{ l, try p.parseAnd() } });
        return l;
    }

    fn parseAnd(p: *Parser) PErr!*const Expr {
        var l = try p.parseUnary();
        while (p.eat("&&")) l = try p.node(.{ .@"and" = .{ l, try p.parseUnary() } });
        return l;
    }

    fn parseUnary(p: *Parser) PErr!*const Expr {
        p.skipWs();
        if (p.i < p.src.len and p.src[p.i] == '!' and !std.mem.startsWith(u8, p.src[p.i..], "!=")) {
            p.i += 1;
            p.depth += 1;
            defer p.depth -= 1;
            if (p.depth > 64) return p.fail("expression is nested too deeply", .{});
            const inner = try p.parseUnary();
            // `!true` / `!false` fold.
            return switch (inner.*) {
                .true => p.node(.false),
                .false => p.node(.true),
                else => p.node(.{ .not = inner }),
            };
        }
        return p.parseCmp();
    }

    fn isKeyStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
    }

    fn isKeyChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == ':' or c == '$' or c == '-';
    }

    fn parseKeyName(p: *Parser) PErr![]const u8 {
        p.skipWs();
        if (p.i >= p.src.len) return p.fail("expected a context key", .{});
        if (!isKeyStart(p.src[p.i])) return p.fail("expected a context key, found '{c}'", .{p.src[p.i]});
        const start = p.i;
        while (p.i < p.src.len and isKeyChar(p.src[p.i])) p.i += 1;
        return p.src[start..p.i];
    }

    fn mkKey(p: *Parser, name: []const u8) PErr!Expr.Key {
        const owned = try p.a.dupe(u8, name);
        const id = if (p.svc) |s| if (std.mem.startsWith(u8, name, "config.")) null else try s.key(name) else null;
        return .{ .name = owned, .id = id };
    }

    fn parseCmp(p: *Parser) PErr!*const Expr {
        p.skipWs();
        if (p.i >= p.src.len) return p.fail("expected an expression", .{});
        if (p.src[p.i] == '(') {
            p.i += 1;
            p.depth += 1;
            defer p.depth -= 1;
            if (p.depth > 64) return p.fail("expression is nested too deeply", .{});
            const e = try p.parseOr();
            if (!p.eat(")")) return p.fail("expected ')'", .{});
            return e;
        }
        const name = try p.parseKeyName();
        if (std.mem.eql(u8, name, "true")) return p.node(.true);
        if (std.mem.eql(u8, name, "false")) return p.node(.false);
        const key = try p.mkKey(name);
        const before_ws = p.i;
        p.skipWs();
        const had_ws = p.i > before_ws;
        const rest = p.src[p.i..];
        const ops = [_]struct { []const u8, CmpOp, bool }{
            .{ "===", .eq, false }, .{ "!==", .ne, false }, .{ "==", .eq, false }, .{ "!=", .ne, false },
            .{ "<=", .le, true },   .{ ">=", .ge, true },   .{ "<", .lt, true },   .{ ">", .gt, true },
        };
        if (std.mem.startsWith(u8, rest, "=~")) {
            p.i += 2;
            return p.parseRegex(key);
        }
        for (ops) |o| if (std.mem.startsWith(u8, rest, o[0])) {
            const op_start = p.i;
            p.i += o[0].len;
            if (o[2]) {
                const after_ws = p.i < p.src.len and std.ascii.isWhitespace(p.src[p.i]);
                if (!had_ws or !after_ws) {
                    p.i = op_start;
                    return p.fail("'{s}' needs whitespace on both sides", .{o[0]});
                }
            }
            const lit = try p.parseValue();
            if (o[2] and !isNumber(lit))
                p.diags.add(.{ .start = @intCast(op_start), .end = @intCast(p.i) }, .warning, "'{s}' compares numbers; '{s}' is not a number", .{ o[0], lit });
            return p.node(.{ .cmp = .{ .key = key, .op = o[1], .lit = lit } });
        };
        // `in` / `not in`.
        const save = p.i;
        var negated = false;
        if (std.mem.startsWith(u8, rest, "not") and rest.len > 3 and std.ascii.isWhitespace(rest[3])) {
            p.i += 3;
            p.skipWs();
            negated = true;
        }
        if (std.mem.startsWith(u8, p.src[p.i..], "in") and (p.i + 2 >= p.src.len or std.ascii.isWhitespace(p.src[p.i + 2]))) {
            p.i += 2;
            const list = try p.mkKey(try p.parseKeyName());
            return p.node(.{ .in = .{ .key = key, .list = list, .negated = negated } });
        }
        if (negated) {
            p.i = save;
            return p.fail("expected 'in' after 'not'", .{});
        }
        p.i = before_ws;
        return p.node(.{ .key = key });
    }

    fn parseValue(p: *Parser) PErr![]const u8 {
        p.skipWs();
        if (p.i >= p.src.len) return p.fail("expected a value", .{});
        if (p.src[p.i] == '\'') {
            const start = p.i + 1;
            const end = std.mem.indexOfScalarPos(u8, p.src, start, '\'') orelse return p.fail("unterminated string", .{});
            p.i = end + 1;
            return p.a.dupe(u8, p.src[start..end]);
        }
        const start = p.i;
        while (p.i < p.src.len and !std.ascii.isWhitespace(p.src[p.i]) and p.src[p.i] != ')' and
            !std.mem.startsWith(u8, p.src[p.i..], "&&") and !std.mem.startsWith(u8, p.src[p.i..], "||")) p.i += 1;
        if (p.i == start) return p.fail("expected a value", .{});
        return p.a.dupe(u8, p.src[start..p.i]);
    }

    fn parseRegex(p: *Parser, key: Expr.Key) PErr!*const Expr {
        p.skipWs();
        if (p.i >= p.src.len or p.src[p.i] != '/') return p.fail("expected '/' to start a regular expression", .{});
        const start = p.i;
        p.i += 1;
        while (p.i < p.src.len and p.src[p.i] != '/') : (p.i += 1) {
            if (p.src[p.i] == '\\') p.i += 1;
        }
        if (p.i >= p.src.len) {
            p.i = start;
            return p.fail("unterminated regular expression", .{});
        }
        const body = p.src[start + 1 .. p.i];
        p.i += 1;
        var ic = false;
        while (p.i < p.src.len and std.ascii.isAlphabetic(p.src[p.i])) : (p.i += 1) switch (p.src[p.i]) {
            'i' => ic = true,
            'm', 's', 'u' => {},
            'g', 'y' => p.diags.add(.{ .start = @intCast(p.i), .end = @intCast(p.i + 1) }, .warning, "regex flag '{c}' is ignored", .{p.src[p.i]}),
            else => return p.fail("unknown regex flag '{c}'", .{p.src[p.i]}),
        };
        const re = regex_lite.Regex.compile(try p.a.dupe(u8, body), ic) catch {
            p.i = start;
            return p.fail("invalid or unsupported regular expression", .{});
        };
        const idx: u32 = @intCast(p.regexes.items.len);
        try p.regexes.append(p.a, re);
        return p.node(.{ .match = .{ .key = key, .regex = idx, .src = try p.a.dupe(u8, p.src[start..p.i]) } });
    }
};

fn isNumber(s: []const u8) bool {
    _ = std.fmt.parseFloat(f64, s) catch return false;
    return true;
}

const Compiler = struct {
    a: Allocator,
    code: std.ArrayList(u32) = .empty,
    consts: std.ArrayList([]const u8) = .empty,
    keys: std.ArrayList(Expr.Key) = .empty,
    depth: u32 = 0,
    max_depth: u32 = 0,

    fn op(c: *Compiler, o: Op, a: u32) !void {
        std.debug.assert(a < (1 << 24));
        try c.code.append(c.a, (@as(u32, @intFromEnum(o)) << 24) | a);
    }

    fn push(c: *Compiler) void {
        c.depth += 1;
        c.max_depth = @max(c.max_depth, c.depth);
    }

    fn key(c: *Compiler, k: Expr.Key) !u32 {
        for (c.keys.items, 0..) |x, i| if (std.mem.eql(u8, x.name, k.name)) return @intCast(i);
        try c.keys.append(c.a, k);
        return @intCast(c.keys.items.len - 1);
    }

    fn loadKey(c: *Compiler, k: Expr.Key) !void {
        const idx = try c.key(k);
        try c.op(if (std.mem.startsWith(u8, k.name, "config.")) .load_config else .load_key, idx);
        c.push();
    }

    fn emitExpr(c: *Compiler, e: *const Expr) error{OutOfMemory}!void {
        switch (e.*) {
            .true, .false => {
                try c.op(if (e.* == .true) .push_true else .push_false, 0);
                c.push();
            },
            .key => |k| {
                try c.loadKey(k);
                try c.op(.truthy, 0);
            },
            .not => |inner| {
                try c.emitExpr(inner);
                try c.op(.not, 0);
            },
            .@"and", .@"or" => |pair| {
                try c.emitExpr(pair[0]);
                const jmp_at = c.code.items.len;
                try c.op(if (e.* == .@"and") .jmp_if_false_keep else .jmp_if_true_keep, 0);
                c.depth -= 1;
                try c.emitExpr(pair[1]);
                try c.op(.truthy, 0);
                const target: u32 = @intCast(c.code.items.len);
                c.code.items[jmp_at] = (c.code.items[jmp_at] & 0xFF00_0000) | target;
            },
            .cmp => |x| {
                try c.loadKey(x.key);
                try c.consts.append(c.a, x.lit);
                try c.op(.load_const, @intCast(c.consts.items.len - 1));
                c.push();
                try c.op(switch (x.op) {
                    .eq => .eq,
                    .ne => .ne,
                    .lt => .lt,
                    .le => .le,
                    .gt => .gt,
                    .ge => .ge,
                }, 0);
                c.depth -= 1;
            },
            .match => |m| {
                try c.loadKey(m.key);
                try c.op(.match, m.regex);
            },
            .in => |x| {
                try c.loadKey(x.key);
                try c.loadKey(x.list);
                try c.op(if (x.negated) .not_in else .in, 0);
                c.depth -= 1;
            },
        }
    }
};

fn prec(e: *const Expr) u8 {
    return switch (e.*) {
        .@"or" => 1,
        .@"and" => 2,
        else => 3,
    };
}

fn formatExpr(e: *const Expr, w: *std.Io.Writer, parent: u8) std.Io.Writer.Error!void {
    const p = prec(e);
    const paren = p < parent;
    if (paren) try w.writeByte('(');
    switch (e.*) {
        .true => try w.writeAll("true"),
        .false => try w.writeAll("false"),
        .key => |k| try w.writeAll(k.name),
        .not => |inner| {
            try w.writeByte('!');
            try formatExpr(inner, w, 3);
        },
        .@"and" => |pair| {
            try formatExpr(pair[0], w, 2);
            try w.writeAll(" && ");
            try formatExpr(pair[1], w, 3);
        },
        .@"or" => |pair| {
            try formatExpr(pair[0], w, 1);
            try w.writeAll(" || ");
            try formatExpr(pair[1], w, 2);
        },
        .cmp => |x| {
            const op = switch (x.op) {
                .eq => "==",
                .ne => "!=",
                .lt => "<",
                .le => "<=",
                .gt => ">",
                .ge => ">=",
            };
            const bare = x.lit.len > 0 and for (x.lit) |ch| {
                if (std.ascii.isWhitespace(ch) or ch == '\'' or ch == ')' or ch == '&' or ch == '|') break false;
            } else true;
            if (bare) try w.print("{s} {s} {s}", .{ x.key.name, op, x.lit }) else try w.print("{s} {s} '{s}'", .{ x.key.name, op, x.lit });
        },
        .match => |m| try w.print("{s} =~ {s}", .{ m.key.name, m.src }),
        .in => |x| try w.print("{s} {s}in {s}", .{ x.key.name, if (x.negated) "not " else "", x.list.name }),
    }
    if (paren) try w.writeByte(')');
}

const testing = std.testing;

fn evalWith(svc: *ContextKeyService, src: []const u8, stack: []const context.KeyContext) !bool {
    var d = Diags.init(testing.allocator);
    defer d.deinit();
    var w = When.compile(testing.allocator, src, svc, &d) catch |e| {
        for (d.items()) |x| std.debug.print("when '{s}': {s}\n", .{ src, x.message });
        return e;
    };
    defer w.deinit();
    const env: EvalEnv = .{ .global = svc, .stack = stack };
    return w.eval(&env);
}

test "when: precedence table" {
    var s = ContextKeyService.init(testing.allocator);
    defer s.deinit();
    try s.setByName("textInputFocus", .{ .bool = true });
    try s.setByName("editorReadonly", .{ .bool = false });
    try s.setByName("foo", .{ .bool = true });
    try s.setByName("bar", .{ .bool = false });
    try s.setByName("baz", .{ .bool = false });
    try testing.expect(try evalWith(&s, "textInputFocus && !editorReadonly", &.{}));
    try testing.expect(try evalWith(&s, "!(editorReadonly || inDebugMode)", &.{}));
    // `foo || bar && baz` is `foo || (bar && baz)`.
    try testing.expect(try evalWith(&s, "foo || bar && baz", &.{}));
    try testing.expect(!try evalWith(&s, "(foo || bar) && baz", &.{}));
    try testing.expect(!try evalWith(&s, "!foo", &.{}));
    try testing.expect(try evalWith(&s, "!!foo", &.{}));
    try testing.expect(try evalWith(&s, "true", &.{}));
    try testing.expect(!try evalWith(&s, "false || !true", &.{}));
}

test "when: comparisons need spaces" {
    var s = ContextKeyService.init(testing.allocator);
    defer s.deinit();
    try s.setByName("workspaceFolderCount", .{ .num = 2 });
    try testing.expect(try evalWith(&s, "workspaceFolderCount > 1", &.{}));
    try testing.expect(!try evalWith(&s, "workspaceFolderCount >= 3", &.{}));
    try testing.expect(try evalWith(&s, "workspaceFolderCount <= 2", &.{}));
    var d = Diags.init(testing.allocator);
    defer d.deinit();
    try testing.expectError(error.InvalidWhen, When.compile(testing.allocator, "workspaceFolderCount>1", &s, &d));
    try testing.expect(d.contains("whitespace"));
    // A key with '-' is fine.
    try s.setByName("my-key", .{ .bool = true });
    try testing.expect(try evalWith(&s, "my-key", &.{}));
}

test "when: equality, string forms and quoting" {
    var s = ContextKeyService.init(testing.allocator);
    defer s.deinit();
    try s.setByName("editorLangId", .{ .str = "zig" });
    try s.setByName("flag", .{ .bool = true });
    try s.setByName("n", .{ .num = 3 });
    try testing.expect(try evalWith(&s, "editorLangId == zig", &.{}));
    try testing.expect(try evalWith(&s, "editorLangId === 'zig'", &.{}));
    try testing.expect(try evalWith(&s, "editorLangId != zon", &.{}));
    try testing.expect(try evalWith(&s, "flag == true", &.{}));
    try testing.expect(try evalWith(&s, "n == 3", &.{}));
    try testing.expect(try evalWith(&s, "missing != x", &.{}));
    try testing.expect(!try evalWith(&s, "missing == x", &.{}));
    try testing.expect(try evalWith(&s, "editorLangId == zig&&flag", &.{}));
}

test "when: regex flags" {
    var s = ContextKeyService.init(testing.allocator);
    defer s.deinit();
    try s.setByName("resourceFilename", .{ .str = "Build.ZIG" });
    try testing.expect(try evalWith(&s, "resourceFilename =~ /\\.zig$/i", &.{}));
    try testing.expect(!try evalWith(&s, "resourceFilename =~ /\\.zig$/", &.{}));
    var d = Diags.init(testing.allocator);
    defer d.deinit();
    var w = try When.compile(testing.allocator, "resourceFilename =~ /a/g", &s, &d);
    w.deinit();
    try testing.expect(d.contains("ignored"));
}

test "when: in / not in with list" {
    var s = ContextKeyService.init(testing.allocator);
    defer s.deinit();
    try s.setByName("resourceExtname", .{ .str = ".zig" });
    try s.setByName("supportedExts", .{ .list = &.{ ".zig", ".zon" } });
    try testing.expect(try evalWith(&s, "resourceExtname in supportedExts", &.{}));
    try testing.expect(!try evalWith(&s, "resourceExtname not in supportedExts", &.{}));
    try testing.expect(!try evalWith(&s, "resourceExtname in nothing", &.{}));
}

test "when: stack lookup innermost wins, attrs, undefined false" {
    var s = ContextKeyService.init(testing.allocator);
    defer s.deinit();
    const stack = [_]context.KeyContext{
        .{ .name = "Workbench" },
        .{ .name = "Editor", .attrs = &.{.{ .key = "vim.mode", .value = "normal" }} },
    };
    try testing.expect(try evalWith(&s, "Editor && vim.mode == normal", &stack));
    try testing.expect(!try evalWith(&s, "Terminal", &stack));
    try testing.expect(!try evalWith(&s, "undefinedKey", &stack));
    try testing.expect(try evalWith(&s, "vim.mode != insert", &stack));
}

test "when: config.editor.tabSize > 2" {
    const store = @import("../store.zig");
    const schema = @import("../schema.zig");
    const st = try store.SettingsStore.init(testing.allocator, testing.io, &schema.test_registry, .{});
    defer st.deinit();
    var s = ContextKeyService.init(testing.allocator);
    defer s.deinit();
    var d = Diags.init(testing.allocator);
    defer d.deinit();
    var w = try When.compile(testing.allocator, "config.editor.tabSize > 2 && config.editor.wordWrap == off", &s, &d);
    defer w.deinit();
    const env: EvalEnv = .{ .global = &s, .settings = st.current() };
    try testing.expect(w.eval(&env));
    const no_settings: EvalEnv = .{ .global = &s };
    try testing.expect(!w.eval(&no_settings));
}

test "when: errors with positions" {
    const cases = [_]struct { []const u8, u32, []const u8 }{
        .{ "a &&", 4, "expected" },
        .{ "(a || b", 7, "')'" },
        .{ "a == ", 5, "value" },
        .{ "a =~ /[/", 5, "regular expression" },
        .{ "a b", 2, "unexpected" },
        .{ "a not b", 2, "'in'" },
        .{ "a =~ x", 5, "'/'" },
    };
    for (cases) |c| {
        var d = Diags.init(testing.allocator);
        defer d.deinit();
        try testing.expectError(error.InvalidWhen, When.compile(testing.allocator, c[0], null, &d));
        const first = d.items()[0];
        if (first.span.start != c[1] or std.mem.indexOf(u8, first.message, c[2]) == null) {
            std.debug.print("'{s}': got {d} '{s}'\n", .{ c[0], first.span.start, first.message });
            return error.TestUnexpectedResult;
        }
    }
}

test "when: format is canonical and recompiles to the same text" {
    const srcs = [_][]const u8{
        "a&&b||c",
        "!(a || b) && c",
        "a == 'x y' || b =~ /^q/i",
        "x not in y && n >= 2",
        "(a || b) && (c || d)",
    };
    const want = [_][]const u8{
        "a && b || c",
        "!(a || b) && c",
        "a == 'x y' || b =~ /^q/i",
        "x not in y && n >= 2",
        "(a || b) && (c || d)",
    };
    for (srcs, want) |src, wt| {
        var d = Diags.init(testing.allocator);
        defer d.deinit();
        var w = try When.compile(testing.allocator, src, null, &d);
        defer w.deinit();
        try testing.expectEqualStrings(wt, w.text);
        var w2 = try When.compile(testing.allocator, w.text, null, &d);
        defer w2.deinit();
        try testing.expectEqualStrings(w.text, w2.text);
    }
}

test "fuzz: when_parse" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [128]u8 = undefined;
            const src = buf[0..smith.slice(&buf)];
            var d = Diags.init(testing.allocator);
            defer d.deinit();
            var w = When.compile(testing.allocator, src, null, &d) catch return;
            defer w.deinit();
            var s = ContextKeyService.init(testing.allocator);
            defer s.deinit();
            const env: EvalEnv = .{ .global = &s };
            _ = w.eval(&env);
            var w2 = try When.compile(testing.allocator, w.text, null, &d);
            defer w2.deinit();
            try testing.expectEqualStrings(w.text, w2.text);
        }
    }.f, .{});
}
