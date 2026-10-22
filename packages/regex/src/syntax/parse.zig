//! The regex parser: pattern -> `Ast` with spans, or an `Error`.
//!
//! The parser never recurses. Groups and alternations live on an explicit
//! stack of frames (as in Rust's `regex-syntax`), and so do nested classes,
//! so hostile nesting cannot overflow the thread stack. After parsing, an
//! iterative pass enforces the nest limit over groups, classes and
//! repetitions together. Everything is allocated in the caller's arena.

const std = @import("std");
const ast = @import("ast.zig");
const errors = @import("errors.zig");

const Allocator = std.mem.Allocator;
const Ast = ast.Ast;
const Span = ast.Span;
const Flags = ast.Flags;
const ClassItem = ast.ClassItem;
const ClassSet = ast.ClassSet;
pub const Error = errors.Error;
pub const ErrorKind = errors.ErrorKind;

/// Patterns longer than this are rejected with `pattern_too_long`.
pub const max_pattern_len: usize = 1 << 20;
/// Counted repetition bounds above this are rejected (as in RE2).
pub const max_repeat: u32 = 1000;

/// Parser options.
pub const ParseOptions = struct {
    /// Start in `x` mode.
    ignore_whitespace: bool = false,
    /// Maximum depth of nested groups, classes and repetitions.
    nest_limit: u32 = 250,
};

/// The parse result.
pub const Result = union(enum) {
    ok: *Ast,
    err: Error,
};

/// Parses `pattern`. Out of memory is reported as `error.OutOfMemory`.
pub fn parse(arena: Allocator, pattern: []const u8, o: ParseOptions) Allocator.Error!Result {
    if (pattern.len > max_pattern_len) return .{ .err = .{ .kind = .pattern_too_long, .span = .{ .start = 0, .end = 0 } } };
    if (!std.unicode.utf8ValidateSlice(pattern)) {
        const bad = firstInvalidUtf8(pattern);
        return .{ .err = .{ .kind = .pattern_invalid_utf8, .span = .{ .start = bad, .end = bad + 1 } } };
    }
    var p: Parser = .{ .arena = arena, .pattern = pattern, .x = o.ignore_whitespace, .nest_limit = o.nest_limit };
    const root = p.run() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => return .{ .err = p.err },
    };
    if (try checkNesting(arena, root, o.nest_limit)) |e| return .{ .err = e };
    return .{ .ok = root };
}

fn firstInvalidUtf8(s: []const u8) u32 {
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return @intCast(i);
        if (i + n > s.len) return @intCast(i);
        _ = std.unicode.utf8Decode(s[i..][0..n]) catch return @intCast(i);
        i += n;
    }
    return @intCast(s.len);
}

const ParseError = error{Syntax} || Allocator.Error;

const Concat = struct {
    items: std.ArrayList(*Ast) = .empty,
    start: u32,
};

const GroupFrame = struct {
    /// Span of the opener, `(` through `:` or `>`.
    open: Span,
    kind: ast.GroupKind,
    outer: Concat,
    alts: std.ArrayList(*Ast) = .empty,
    old_x: bool,
};

const ClassFrame = struct {
    start: u32,
    negated: bool,
    operands: std.ArrayList(*ClassSet) = .empty,
    ops: std.ArrayList(ast.SetOp) = .empty,
    items: std.ArrayList(ClassItem) = .empty,
    items_start: u32,
};

const Parser = struct {
    arena: Allocator,
    pattern: []const u8,
    pos: u32 = 0,
    x: bool,
    nest_limit: u32,
    captures: u32 = 0,
    names: std.StringHashMapUnmanaged(Span) = .empty,
    groups: std.ArrayList(GroupFrame) = .empty,
    root_alts: std.ArrayList(*Ast) = .empty,
    err: Error = undefined,

    fn fail(p: *Parser, kind: ErrorKind, span: Span) error{Syntax} {
        p.err = .{ .kind = kind, .span = span };
        return error.Syntax;
    }

    fn failAux(p: *Parser, kind: ErrorKind, span: Span, aux: Span) error{Syntax} {
        p.err = .{ .kind = kind, .span = span, .aux_span = aux };
        return error.Syntax;
    }

    fn eof(p: *const Parser) bool {
        return p.pos >= p.pattern.len;
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.pos < p.pattern.len) p.pattern[p.pos] else null;
    }

    fn peekAt(p: *const Parser, off: u32) ?u8 {
        const i = p.pos + off;
        return if (i < p.pattern.len) p.pattern[i] else null;
    }

    fn span1(p: *const Parser) Span {
        return .{ .start = p.pos, .end = @intCast(@min(p.pos + 1, p.pattern.len)) };
    }

    /// `start` through the current byte (when there is one).
    fn spanThrough(p: *const Parser, start: u32) Span {
        return .{ .start = start, .end = @intCast(@min(p.pos + 1, p.pattern.len)) };
    }

    fn spanFrom(p: *const Parser, start: u32) Span {
        return .{ .start = start, .end = p.pos };
    }

    /// Decodes the code point at `pos` (the pattern is valid UTF-8).
    fn char(p: *const Parser) struct { cp: u21, len: u32 } {
        const b = p.pattern[p.pos];
        const n = std.unicode.utf8ByteSequenceLength(b) catch unreachable;
        const cp = std.unicode.utf8Decode(p.pattern[p.pos..][0..n]) catch unreachable;
        return .{ .cp = cp, .len = n };
    }

    fn node(p: *Parser, v: Ast) Allocator.Error!*Ast {
        const n = try p.arena.create(Ast);
        n.* = v;
        return n;
    }

    fn skipWhitespace(p: *Parser) void {
        if (!p.x) return;
        while (p.pos < p.pattern.len) {
            const c = p.pattern[p.pos];
            if (std.ascii.isWhitespace(c)) {
                p.pos += 1;
            } else if (c == '#') {
                while (p.pos < p.pattern.len and p.pattern[p.pos] != '\n') p.pos += 1;
            } else break;
        }
    }

    fn run(p: *Parser) ParseError!*Ast {
        var concat: Concat = .{ .start = 0 };
        while (true) {
            p.skipWhitespace();
            const c = p.peek() orelse break;
            switch (c) {
                '(' => concat = try p.openGroup(concat),
                ')' => concat = try p.closeGroup(concat),
                '|' => {
                    const alts = if (p.groups.items.len > 0) &p.groups.items[p.groups.items.len - 1].alts else &p.root_alts;
                    try alts.append(p.arena, try p.finishConcat(&concat));
                    p.pos += 1;
                    concat = .{ .start = p.pos };
                },
                '[' => try concat.items.append(p.arena, try p.parseClass()),
                '*', '+', '?' => try p.repetitionOp(&concat),
                '{' => try p.repetitionCounted(&concat),
                else => try concat.items.append(p.arena, try p.primitive()),
            }
        }
        if (p.groups.items.len > 0) {
            const g = p.groups.items[p.groups.items.len - 1];
            return p.fail(.group_unclosed, g.open);
        }
        try p.root_alts.append(p.arena, try p.finishConcat(&concat));
        return p.finishAlternation(&p.root_alts);
    }

    fn finishConcat(p: *Parser, c: *Concat) Allocator.Error!*Ast {
        return switch (c.items.items.len) {
            0 => p.node(.{ .empty = .{ .start = c.start, .end = c.start } }),
            1 => c.items.items[0],
            else => p.node(.{ .concat = .{ .span = .{ .start = c.start, .end = c.items.items[c.items.items.len - 1].span().end }, .items = c.items.items } }),
        };
    }

    fn finishAlternation(p: *Parser, alts: *std.ArrayList(*Ast)) Allocator.Error!*Ast {
        if (alts.items.len == 1) return alts.items[0];
        const first = alts.items[0].span();
        const last = alts.items[alts.items.len - 1].span();
        return p.node(.{ .alternation = .{ .span = .{ .start = first.start, .end = last.end }, .items = alts.items } });
    }

    // -- groups -----------------------------------------------------------

    fn openGroup(p: *Parser, concat: Concat) ParseError!Concat {
        const start = p.pos;
        p.pos += 1; // (
        var kind: ast.GroupKind = undefined;
        if (p.peek() == '?') {
            p.pos += 1;
            const c = p.peek() orelse return p.fail(.group_unclosed, p.spanFrom(start));
            switch (c) {
                'P' => {
                    const n = p.peekAt(1);
                    if (n == '<') {
                        p.pos += 2;
                        kind = try p.captureName(start);
                    } else if (n == '=') {
                        return p.fail(.unsupported_backreference, .{ .start = start, .end = p.pos + 2 });
                    } else if (n == '>') {
                        return p.fail(.unsupported_backreference, .{ .start = start, .end = p.pos + 2 });
                    } else return p.fail(.flag_unknown, p.span1());
                },
                '<' => {
                    const n = p.peekAt(1);
                    if (n == '=' or n == '!') return p.fail(.unsupported_lookaround, .{ .start = start, .end = p.pos + 2 });
                    p.pos += 1;
                    kind = try p.captureName(start);
                },
                '=', '!' => return p.fail(.unsupported_lookaround, .{ .start = start, .end = p.pos + 1 }),
                '>' => return p.fail(.unsupported_atomic, .{ .start = start, .end = p.pos + 1 }),
                else => {
                    var set: Flags = .{};
                    var clear: Flags = .{};
                    const standalone = try p.parseFlags(start, &set, &clear);
                    if (standalone) {
                        const f = try p.node(.{ .flags = .{ .span = p.spanFrom(start), .set = set, .clear = clear } });
                        var cc = concat;
                        try cc.items.append(p.arena, f);
                        if (set.ignore_whitespace) p.x = true;
                        if (clear.ignore_whitespace) p.x = false;
                        return cc;
                    }
                    kind = .{ .non_capture = .{ .set = set, .clear = clear } };
                },
            }
        } else {
            p.captures += 1;
            kind = .{ .capture = .{ .index = p.captures, .name = null } };
        }
        if (p.groups.items.len + 1 > p.nest_limit) return p.fail(.nest_limit_exceeded, p.spanFrom(start));
        try p.groups.append(p.arena, .{ .open = p.spanFrom(start), .kind = kind, .outer = concat, .old_x = p.x });
        switch (kind) {
            .non_capture => |f| {
                if (f.set.ignore_whitespace) p.x = true;
                if (f.clear.ignore_whitespace) p.x = false;
            },
            .capture => {},
        }
        return .{ .start = p.pos };
    }

    /// Parses `name>` after `(?P<` or `(?<`.
    fn captureName(p: *Parser, start: u32) ParseError!ast.GroupKind {
        const name_start = p.pos;
        while (p.peek()) |c| {
            if (c == '>') break;
            p.pos += 1;
        } else return p.fail(.group_name_invalid, .{ .start = name_start, .end = p.pos });
        const name = p.pattern[name_start..p.pos];
        const name_span: Span = .{ .start = name_start, .end = p.pos };
        p.pos += 1; // >
        if (!validName(name)) return p.fail(.group_name_invalid, if (name.len == 0) .{ .start = start, .end = p.pos } else name_span);
        const gop = try p.names.getOrPut(p.arena, name);
        if (gop.found_existing) return p.failAux(.group_name_duplicate, name_span, gop.value_ptr.*);
        gop.value_ptr.* = name_span;
        p.captures += 1;
        return .{ .capture = .{ .index = p.captures, .name = name, .name_span = name_span } };
    }

    /// Parses flags after `(?`; returns true for a standalone `(?flags)`.
    fn parseFlags(p: *Parser, start: u32, set: *Flags, clear: *Flags) ParseError!bool {
        var negated = false;
        var neg_span: Span = undefined;
        var seen: [128]?Span = @splat(null);
        var any = false;
        while (true) {
            const c = p.peek() orelse return p.fail(.group_unclosed, p.spanFrom(start));
            switch (c) {
                ':', ')' => {
                    if (negated and !any_after_neg(set.*, clear.*)) return p.fail(.flag_dangling, neg_span);
                    if (!any and !negated and c == ')') return p.fail(.flag_unknown, p.span1());
                    p.pos += 1;
                    return c == ')';
                },
                '-' => {
                    if (negated) return p.failAux(.flag_duplicate, p.span1(), neg_span);
                    negated = true;
                    neg_span = p.span1();
                    p.pos += 1;
                },
                else => {
                    if (c >= 0x80) return p.fail(.flag_unknown, .{ .start = p.pos, .end = p.pos + p.char().len });
                    const f = Flags.fromLetter(c) orelse return p.fail(.flag_unknown, p.span1());
                    if (seen[c]) |prev| return p.failAux(.flag_duplicate, p.span1(), prev);
                    seen[c] = p.span1();
                    if (negated) clear.* = clear.merge(f) else set.* = set.merge(f);
                    any = true;
                    p.pos += 1;
                },
            }
        }
    }

    fn any_after_neg(_: Flags, clear: Flags) bool {
        return !clear.isEmpty();
    }

    fn closeGroup(p: *Parser, concat_in: Concat) ParseError!Concat {
        if (p.groups.items.len == 0) return p.fail(.group_unopened, p.span1());
        var concat = concat_in;
        var g = p.groups.pop().?;
        try g.alts.append(p.arena, try p.finishConcat(&concat));
        const sub = try p.finishAlternation(&g.alts);
        p.pos += 1; // )
        const n = try p.node(.{ .group = .{ .span = .{ .start = g.open.start, .end = p.pos }, .kind = g.kind, .sub = sub } });
        var outer = g.outer;
        try outer.items.append(p.arena, n);
        p.x = g.old_x;
        return outer;
    }

    // -- repetition -------------------------------------------------------

    fn takeRepeatable(p: *Parser, concat: *Concat, op_span: Span) ParseError!*Ast {
        const last = concat.items.pop() orelse return p.fail(.repetition_missing, op_span);
        if (last.* == .flags) return p.fail(.repetition_missing, op_span);
        return last;
    }

    /// Consumes a trailing `?` (lazy) and rejects a trailing `+`.
    fn greediness(p: *Parser) ParseError!bool {
        if (p.peek() == '?') {
            p.pos += 1;
            return false;
        }
        if (p.peek() == '+') return p.fail(.unsupported_possessive, p.span1());
        return true;
    }

    fn repetitionOp(p: *Parser, concat: *Concat) ParseError!void {
        const op_start = p.pos;
        const c = p.pattern[p.pos];
        const sub = try p.takeRepeatable(concat, p.span1());
        p.pos += 1;
        const greedy = try p.greediness();
        const min: u32, const max: ?u32 = switch (c) {
            '*' => .{ 0, null },
            '+' => .{ 1, null },
            else => .{ 0, 1 },
        };
        try concat.items.append(p.arena, try p.node(.{ .repetition = .{
            .span = .{ .start = sub.span().start, .end = p.pos },
            .op_span = p.spanFrom(op_start),
            .min = min,
            .max = max,
            .greedy = greedy,
            .sub = sub,
        } }));
    }

    fn repetitionCounted(p: *Parser, concat: *Concat) ParseError!void {
        const op_start = p.pos;
        const sub = try p.takeRepeatable(concat, p.span1());
        p.pos += 1; // {
        p.skipWhitespace();
        var min: u32 = 0;
        var max: ?u32 = null;
        const have_min = try p.decimal(&min);
        p.skipWhitespace();
        if (p.peek() == ',') {
            p.pos += 1;
            p.skipWhitespace();
            var m: u32 = 0;
            if (try p.decimal(&m)) max = m;
            if (!have_min and max == null) return p.fail(.repetition_count_invalid, p.spanThrough(op_start));
        } else {
            if (!have_min) return p.fail(.repetition_count_invalid, p.spanThrough(op_start));
            max = min;
        }
        p.skipWhitespace();
        if (p.peek() != '}') return p.fail(.repetition_count_invalid, p.spanThrough(op_start));
        p.pos += 1;
        const op_span = p.spanFrom(op_start);
        if (min > max_repeat or (max != null and max.? > max_repeat)) return p.fail(.repetition_count_too_large, op_span);
        if (max != null and max.? < min) return p.fail(.repetition_count_invalid, op_span);
        const greedy = try p.greediness();
        try concat.items.append(p.arena, try p.node(.{ .repetition = .{
            .span = .{ .start = sub.span().start, .end = p.pos },
            .op_span = p.spanFrom(op_start),
            .min = min,
            .max = max,
            .greedy = greedy,
            .sub = sub,
        } }));
    }

    /// Parses a decimal; saturates far above `max_repeat` so the caller
    /// reports `repetition_count_too_large` rather than overflowing.
    fn decimal(p: *Parser, out: *u32) ParseError!bool {
        const start = p.pos;
        var v: u32 = 0;
        while (p.peek()) |c| {
            if (c < '0' or c > '9') break;
            v = @min(v * 10 + (c - '0'), 1_000_000);
            p.pos += 1;
        }
        out.* = v;
        return p.pos > start;
    }

    // -- primitives and escapes ------------------------------------------

    fn primitive(p: *Parser) ParseError!*Ast {
        const start = p.pos;
        const c = p.pattern[p.pos];
        switch (c) {
            '.' => {
                p.pos += 1;
                return p.node(.{ .dot = p.spanFrom(start) });
            },
            '^' => {
                p.pos += 1;
                return p.node(.{ .assertion = .{ .span = p.spanFrom(start), .kind = .start_line } });
            },
            '$' => {
                p.pos += 1;
                return p.node(.{ .assertion = .{ .span = p.spanFrom(start), .kind = .end_line } });
            },
            '\\' => return switch (try p.escape(false)) {
                .literal => |l| p.node(.{ .literal = .{ .span = l.span, .cp = l.cp, .kind = l.kind } }),
                .perl => |x| p.node(.{ .class_perl = .{ .span = x.span, .kind = x.kind, .negated = x.negated } }),
                .unicode => |u| p.node(.{ .class_unicode = u }),
                .assertion => |a| p.node(.{ .assertion = .{ .span = a.span, .kind = a.kind } }),
            },
            else => {
                const ch = p.char();
                p.pos += ch.len;
                return p.node(.{ .literal = .{ .span = p.spanFrom(start), .cp = ch.cp, .kind = .verbatim } });
            },
        }
    }

    const Escape = union(enum) {
        literal: struct { span: Span, cp: u21, kind: ast.LitKind },
        perl: struct { span: Span, kind: ast.PerlKind, negated: bool },
        unicode: ast.Unicode,
        assertion: struct { span: Span, kind: ast.AssertKind },
    };

    fn escape(p: *Parser, in_class: bool) ParseError!Escape {
        const start = p.pos;
        p.pos += 1; // backslash
        if (p.eof()) return p.fail(.escape_unexpected_eof, p.spanFrom(start));
        const c = p.pattern[p.pos];
        if (c >= 0x80) {
            const ch = p.char();
            return p.fail(.escape_invalid, .{ .start = start, .end = p.pos + ch.len });
        }
        p.pos += 1;
        const sp = p.spanFrom(start);
        const lit = struct {
            fn f(s: Span, cp: u21, k: ast.LitKind) Escape {
                return .{ .literal = .{ .span = s, .cp = cp, .kind = k } };
            }
        }.f;
        switch (c) {
            '0' => {
                if (p.peek()) |n| if (n >= '0' and n <= '9') return p.fail(.unsupported_octal, .{ .start = start, .end = p.pos + 1 });
                return lit(sp, 0, .special);
            },
            '1'...'9' => return p.fail(.unsupported_backreference, sp),
            'a' => return lit(sp, 0x07, .special),
            'f' => return lit(sp, 0x0C, .special),
            't' => return lit(sp, '\t', .special),
            'n' => return lit(sp, '\n', .special),
            'r' => return lit(sp, '\r', .special),
            'v' => return lit(sp, 0x0B, .special),
            'x', 'u', 'U' => {
                const cp = try p.hexEscape(start, c);
                return lit(p.spanFrom(start), cp, .hex);
            },
            'd', 's', 'w', 'D', 'S', 'W' => return .{ .perl = .{
                .span = sp,
                .kind = switch (std.ascii.toLower(c)) {
                    'd' => .digit,
                    's' => .space,
                    else => .word,
                },
                .negated = std.ascii.isUpper(c),
            } },
            'p', 'P' => return .{ .unicode = try p.unicodeClass(start, c == 'P') },
            'G' => return p.fail(.unsupported_backslash_g, sp),
            'k' => return p.fail(.unsupported_backreference, sp),
            'A', 'z', 'B', 'b', '<', '>' => {
                if (in_class) return p.fail(.escape_invalid, sp);
                const kind: ast.AssertKind = switch (c) {
                    'A' => .start_text,
                    'z' => .end_text,
                    'B' => .not_word_boundary,
                    '<' => .word_start,
                    '>' => .word_end,
                    else => p.wordBoundarySpecial(),
                };
                return .{ .assertion = .{ .span = p.spanFrom(start), .kind = kind } };
            },
            else => {
                if (std.ascii.isAlphanumeric(c)) return p.fail(.escape_invalid, sp);
                return lit(sp, c, .meta);
            },
        }
    }

    /// After `\b`: consumes `{start}`, `{end}`, `{start-half}` or
    /// `{end-half}` when present; anything else leaves `{` for repetition.
    fn wordBoundarySpecial(p: *Parser) ast.AssertKind {
        if (p.peek() != '{') return .word_boundary;
        const rest = p.pattern[p.pos..];
        const table = [_]struct { []const u8, ast.AssertKind }{
            .{ "{start}", .word_start },
            .{ "{end}", .word_end },
            .{ "{start-half}", .word_start_half },
            .{ "{end-half}", .word_end_half },
        };
        for (table) |t| if (std.mem.startsWith(u8, rest, t[0])) {
            p.pos += @intCast(t[0].len);
            return t[1];
        };
        return .word_boundary;
    }

    fn hexEscape(p: *Parser, start: u32, c: u8) ParseError!u21 {
        var v: u32 = 0;
        if (p.peek() == '{') {
            p.pos += 1;
            const ds = p.pos;
            while (p.peek()) |d| {
                if (d == '}') break;
                const h = std.fmt.charToDigit(d, 16) catch return p.fail(.escape_hex_invalid, .{ .start = start, .end = p.pos + 1 });
                if (p.pos - ds >= 8) return p.fail(.escape_hex_invalid, .{ .start = start, .end = p.pos + 1 });
                v = v * 16 + h;
                p.pos += 1;
            } else return p.fail(.escape_hex_invalid, p.spanFrom(start));
            if (p.pos == ds) return p.fail(.escape_hex_invalid, .{ .start = start, .end = p.pos + 1 });
            p.pos += 1; // }
        } else {
            const n: u32 = switch (c) {
                'x' => 2,
                'u' => 4,
                else => 8,
            };
            for (0..n) |_| {
                const d = p.peek() orelse return p.fail(.escape_hex_invalid, p.spanFrom(start));
                const h = std.fmt.charToDigit(d, 16) catch return p.fail(.escape_hex_invalid, .{ .start = start, .end = p.pos + 1 });
                v = v * 16 + h;
                p.pos += 1;
            }
        }
        if (v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) return p.fail(.escape_hex_invalid, p.spanFrom(start));
        return @intCast(v);
    }

    fn unicodeClass(p: *Parser, start: u32, negated_in: bool) ParseError!ast.Unicode {
        var negated = negated_in;
        if (p.eof()) return p.fail(.escape_unexpected_eof, p.spanFrom(start));
        if (p.pattern[p.pos] != '{') {
            const ch = p.char();
            if (ch.cp == '}' or ch.cp == '^') return p.fail(.escape_invalid, .{ .start = start, .end = p.pos + ch.len });
            const name = p.pattern[p.pos..][0..ch.len];
            p.pos += ch.len;
            return .{ .span = p.spanFrom(start), .negated = negated, .name = name, .value = null, .braced = false };
        }
        p.pos += 1;
        const body_start = p.pos;
        while (p.peek()) |c| {
            if (c == '}') break;
            p.pos += 1;
        } else return p.fail(.escape_unexpected_eof, p.spanFrom(start));
        var body = p.pattern[body_start..p.pos];
        p.pos += 1; // }
        const sp = p.spanFrom(start);
        if (body.len > 0 and body[0] == '^') {
            negated = !negated;
            body = body[1..];
        }
        var name = body;
        var value: ?[]const u8 = null;
        if (std.mem.indexOf(u8, body, "!=")) |i| {
            negated = !negated;
            name = body[0..i];
            value = body[i + 2 ..];
        } else if (std.mem.indexOfAny(u8, body, "=:")) |i| {
            name = body[0..i];
            value = body[i + 1 ..];
        }
        name = std.mem.trim(u8, name, " \t\n\r");
        if (value) |v| value = std.mem.trim(u8, v, " \t\n\r");
        if (name.len == 0 or (value != null and value.?.len == 0)) return p.fail(.unicode_property_unknown, sp);
        return .{ .span = sp, .negated = negated, .name = name, .value = value };
    }

    // -- classes ----------------------------------------------------------

    fn parseClass(p: *Parser) ParseError!*Ast {
        var frames: std.ArrayList(ClassFrame) = .empty;
        try p.openClassFrame(&frames);
        while (true) {
            const top = &frames.items[frames.items.len - 1];
            const c = p.peek() orelse return p.fail(.class_unclosed, .{ .start = top.start, .end = top.start + 1 });
            switch (c) {
                '[' => {
                    if (try p.asciiClass()) |item| {
                        try p.pushItem(top, item);
                    } else {
                        try p.openClassFrame(&frames);
                    }
                },
                ']' => {
                    var f = frames.pop().?;
                    try p.finishOperand(&f);
                    p.pos += 1;
                    const set = try p.reduce(&f);
                    const b: ast.Bracketed = .{ .span = p.spanFrom(f.start), .negated = f.negated, .set = set };
                    if (frames.items.len == 0) return p.node(.{ .class_bracketed = b });
                    try frames.items[frames.items.len - 1].items.append(p.arena, .{ .bracketed = b });
                },
                '&', '-', '~' => {
                    if (p.peekAt(1) == c) {
                        const op: ast.SetOp = switch (c) {
                            '&' => .intersection,
                            '-' => .difference,
                            else => .symmetric_difference,
                        };
                        try p.finishOperand(top);
                        try top.ops.append(p.arena, op);
                        p.pos += 2;
                        top.items_start = p.pos;
                    } else {
                        try p.classLiteral(top);
                    }
                },
                else => try p.classLiteral(top),
            }
        }
    }

    fn openClassFrame(p: *Parser, frames: *std.ArrayList(ClassFrame)) ParseError!void {
        const start = p.pos;
        if (p.groups.items.len + frames.items.len + 1 > p.nest_limit) return p.fail(.nest_limit_exceeded, p.span1());
        p.pos += 1; // [
        var negated = false;
        if (p.peek() == '^') {
            negated = true;
            p.pos += 1;
        }
        var f: ClassFrame = .{ .start = start, .negated = negated, .items_start = p.pos };
        // A leading `]` is a literal.
        if (p.peek() == ']') {
            try f.items.append(p.arena, .{ .literal = .{ .span = p.span1(), .cp = ']', .kind = .verbatim } });
            p.pos += 1;
        }
        try frames.append(p.arena, f);
    }

    /// Tries `[:name:]` or `[:^name:]`; on no match leaves `pos` unchanged.
    fn asciiClass(p: *Parser) Allocator.Error!?ClassItem {
        if (p.peekAt(1) != ':') return null;
        const start = p.pos;
        var i = p.pos + 2;
        var negated = false;
        if (i < p.pattern.len and p.pattern[i] == '^') {
            negated = true;
            i += 1;
        }
        const name_start = i;
        while (i < p.pattern.len and std.ascii.isLower(p.pattern[i])) i += 1;
        if (i + 1 >= p.pattern.len or p.pattern[i] != ':' or p.pattern[i + 1] != ']') return null;
        const kind = ast.AsciiKind.fromName(p.pattern[name_start..i]) orelse return null;
        p.pos = i + 2;
        return .{ .ascii = .{ .span = p.spanFrom(start), .kind = kind, .negated = negated } };
    }

    fn pushItem(p: *Parser, f: *ClassFrame, item: ClassItem) Allocator.Error!void {
        try f.items.append(p.arena, item);
    }

    /// One class atom, possibly the start of a range.
    fn classLiteral(p: *Parser, f: *ClassFrame) ParseError!void {
        const lo = try p.classAtom();
        switch (lo) {
            .literal => |l| {
                // A range needs `-` followed by something other than `]` or
                // a second `-` (which would be the difference operator).
                if (p.peek() == '-' and p.peekAt(1) != null and p.peekAt(1) != ']' and p.peekAt(1) != '-') {
                    p.pos += 1;
                    const hi = try p.classAtom();
                    if (hi != .literal) return p.fail(.class_range_invalid, .{ .start = l.span.start, .end = p.pos });
                    const h = hi.literal;
                    const sp: Span = .{ .start = l.span.start, .end = h.span.end };
                    if (h.cp < l.cp) return p.fail(.class_range_invalid, sp);
                    return p.pushItem(f, .{ .range = .{ .span = sp, .lo = l.cp, .hi = h.cp, .lo_kind = l.kind, .hi_kind = h.kind } });
                }
                return p.pushItem(f, lo);
            },
            else => return p.pushItem(f, lo),
        }
    }

    fn classAtom(p: *Parser) ParseError!ClassItem {
        const start = p.pos;
        if (p.pattern[p.pos] == '\\') {
            return switch (try p.escape(true)) {
                .literal => |l| .{ .literal = .{ .span = l.span, .cp = l.cp, .kind = l.kind } },
                .perl => |x| .{ .perl = .{ .span = x.span, .kind = x.kind, .negated = x.negated } },
                .unicode => |u| .{ .unicode = u },
                .assertion => unreachable, // rejected in classes
            };
        }
        const ch = p.char();
        p.pos += ch.len;
        return .{ .literal = .{ .span = p.spanFrom(start), .cp = ch.cp, .kind = .verbatim } };
    }

    fn finishOperand(p: *Parser, f: *ClassFrame) ParseError!void {
        const items = f.items.items;
        if (items.len == 0) {
            // `[a&&]`, `[&&a]`: an operator with an empty side. A plain
            // empty class cannot occur (a leading `]` is a literal).
            return p.fail(.class_empty, .{ .start = f.items_start, .end = p.pos });
        }
        const s = try p.arena.create(ClassSet);
        s.* = .{ .item = if (items.len == 1) items[0] else .{ .union_ = .{
            .span = .{ .start = items[0].span().start, .end = items[items.len - 1].span().end },
            .items = items,
        } } };
        try f.operands.append(p.arena, s);
        f.items = .empty;
    }

    /// Folds operands and operators: `&&` binds tightest, then `--`, then
    /// `~~`; each is left-associative.
    fn reduce(p: *Parser, f: *ClassFrame) Allocator.Error!*ClassSet {
        var operands = f.operands.items;
        var ops = f.ops.items;
        for ([_]ast.SetOp{ .intersection, .difference, .symmetric_difference }) |level| {
            var new_operands: std.ArrayList(*ClassSet) = .empty;
            var new_ops: std.ArrayList(ast.SetOp) = .empty;
            try new_operands.append(p.arena, operands[0]);
            for (ops, 0..) |op, k| {
                if (op == level) {
                    const b = try p.arena.create(ClassSet);
                    b.* = .{ .binary = .{ .op = op, .lhs = new_operands.items[new_operands.items.len - 1], .rhs = operands[k + 1] } };
                    new_operands.items[new_operands.items.len - 1] = b;
                } else {
                    try new_ops.append(p.arena, op);
                    try new_operands.append(p.arena, operands[k + 1]);
                }
            }
            operands = new_operands.items;
            ops = new_ops.items;
        }
        std.debug.assert(operands.len == 1);
        return operands[0];
    }
};

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    const c0 = name[0];
    if (!(std.ascii.isAlphabetic(c0) or c0 == '_')) return false;
    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '[' or c == ']')) return false;
    }
    return true;
}

/// Enforces the nest limit over groups, bracketed classes (including nested
/// ones) and repetitions, iteratively.
fn checkNesting(arena: Allocator, root: *Ast, limit: u32) Allocator.Error!?Error {
    const Item = struct { n: *const Ast, depth: u32 };
    var stack: std.ArrayList(Item) = .empty;
    try stack.append(arena, .{ .n = root, .depth = 0 });
    const SetItem = struct { s: *const ClassSet, depth: u32 };
    var sets: std.ArrayList(SetItem) = .empty;
    while (stack.pop()) |it| {
        const n = it.n;
        switch (n.*) {
            .group => |g| {
                const d = it.depth + 1;
                if (d > limit) return .{ .kind = .nest_limit_exceeded, .span = g.span };
                try stack.append(arena, .{ .n = g.sub, .depth = d });
            },
            .repetition => |r| {
                const d = it.depth + 1;
                if (d > limit) return .{ .kind = .nest_limit_exceeded, .span = r.span };
                try stack.append(arena, .{ .n = r.sub, .depth = d });
            },
            .concat => |c| for (c.items) |x| try stack.append(arena, .{ .n = x, .depth = it.depth }),
            .alternation => |c| for (c.items) |x| try stack.append(arena, .{ .n = x, .depth = it.depth }),
            .class_bracketed => |b| {
                const d = it.depth + 1;
                if (d > limit) return .{ .kind = .nest_limit_exceeded, .span = b.span };
                try sets.append(arena, .{ .s = b.set, .depth = d });
                while (sets.pop()) |si| {
                    switch (si.s.*) {
                        .binary => |bin| {
                            try sets.append(arena, .{ .s = bin.lhs, .depth = si.depth });
                            try sets.append(arena, .{ .s = bin.rhs, .depth = si.depth });
                        },
                        .item => |item| {
                            var pending: std.ArrayList(ClassItem) = .empty;
                            try pending.append(arena, item);
                            while (pending.pop()) |ci| switch (ci) {
                                .bracketed => |nb| {
                                    const nd = si.depth + 1;
                                    if (nd > limit) return .{ .kind = .nest_limit_exceeded, .span = nb.span };
                                    try sets.append(arena, .{ .s = nb.set, .depth = nd });
                                },
                                .union_ => |u| try pending.appendSlice(arena, u.items),
                                else => {},
                            };
                        },
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

/// Appends `literal` to `out` with every meta character escaped, so the
/// result matches exactly `literal`.
pub fn escape(out: *std.ArrayList(u8), gpa: Allocator, literal: []const u8) Allocator.Error!void {
    for (literal) |c| {
        if (c < 0x80 and (ast.isMeta(c) or c == ' ')) try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
}
