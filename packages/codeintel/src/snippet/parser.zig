//! The snippet grammar (VS Code's, a superset of the LSP's):
//!
//! ```
//! any         ::= tabstop | placeholder | choice | variable | text
//! tabstop     ::= '$' int | '${' int '}' | '${' int transform '}'
//! placeholder ::= '${' int ':' any '}'
//! choice      ::= '${' int '|' text (',' text)* '|}'
//! variable    ::= '$' var | '${' var '}' | '${' var ':' any '}'
//!               | '${' var transform '}'
//! transform   ::= '/' regex '/' (format | text)+ '/' options
//! format      ::= '$' int | '${' int '}' | '${' int ':' '/' case '}'
//!               | '${' int ':+' if '}' | '${' int ':?' if ':' else '}'
//!               | '${' int ':-' else '}' | '${' int ':' else '}'
//! var         ::= [_a-zA-Z] [_a-zA-Z0-9]*
//! ```
//!
//! `\$`, `\}` and `\\` escape in text (and `\,`, `\|` in choices, `\/`
//! in transforms). Anything that does not parse is kept as text: the
//! parser backtracks to the `$` and moves on one byte.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Snippet = @import("Snippet.zig");
const transform = @import("transform.zig");

const Node = Snippet.Node;
const Transform = transform.Transform;
const FormatItem = transform.FormatItem;

pub const Parser = struct {
    gpa: Allocator,
    /// Nodes and strings.
    a: Allocator,
    src: []const u8,
    i: usize = 0,
    transforms: std.ArrayList(*Transform) = .empty,
    /// Transforms by their source text: repeats share one compiled regex.
    seen: std.StringHashMapUnmanaged(*Transform) = .empty,
    has_final: bool = false,
    max_index: u32 = 0,

    const Fail = error{Syntax} || Allocator.Error;

    pub fn parseAll(p: *Parser) Allocator.Error![]const Node {
        return p.parseAny(false);
    }

    fn peek(p: *const Parser, off: usize) ?u8 {
        return if (p.i + off < p.src.len) p.src[p.i + off] else null;
    }

    /// Nodes until the end, or (`in_braces`) an unescaped `}`, which is
    /// left for the caller.
    fn parseAny(p: *Parser, in_braces: bool) Allocator.Error![]const Node {
        var out: std.ArrayList(Node) = .empty;
        var text: std.ArrayList(u8) = .empty;
        while (p.i < p.src.len) {
            const c = p.src[p.i];
            if (c == '}' and in_braces) break;
            if (c == '\\') if (p.peek(1)) |n| if (n == '$' or n == '}' or n == '\\') {
                try text.append(p.a, n);
                p.i += 2;
                continue;
            };
            if (c == '$') {
                const at = p.i;
                const rollback = p.transforms.items.len;
                const final = p.has_final;
                const max = p.max_index;
                if (p.parseDollar()) |n| {
                    if (text.items.len > 0) {
                        try out.append(p.a, .{ .text = try text.toOwnedSlice(p.a) });
                    }
                    try out.append(p.a, n);
                    continue;
                } else |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Syntax => {
                        p.i = at;
                        p.dropTransforms(rollback);
                        p.has_final = final;
                        p.max_index = max;
                    },
                }
            }
            // A run of plain text at once.
            const end = std.mem.indexOfAnyPos(u8, p.src, p.i + 1, "$\\}") orelse p.src.len;
            try text.appendSlice(p.a, p.src[p.i..end]);
            p.i = end;
        }
        if (text.items.len > 0) try out.append(p.a, .{ .text = try text.toOwnedSlice(p.a) });
        return out.toOwnedSlice(p.a);
    }

    fn dropTransforms(p: *Parser, keep: usize) void {
        while (p.transforms.items.len > keep) {
            const t = p.transforms.pop().?;
            var it = p.seen.iterator();
            while (it.next()) |e| if (e.value_ptr.* == t) {
                p.seen.removeByPtr(e.key_ptr);
                break;
            };
            t.deinit(p.gpa);
        }
    }

    fn int(p: *Parser) ?u32 {
        const start = p.i;
        while (p.i < p.src.len and std.ascii.isDigit(p.src[p.i])) p.i += 1;
        if (p.i == start) return null;
        return std.fmt.parseInt(u32, p.src[start..p.i], 10) catch {
            p.i = start;
            return null;
        };
    }

    fn varName(p: *Parser) ?[]const u8 {
        const start = p.i;
        if (p.i >= p.src.len) return null;
        const c0 = p.src[p.i];
        if (!(std.ascii.isAlphabetic(c0) or c0 == '_')) return null;
        p.i += 1;
        while (p.i < p.src.len and (std.ascii.isAlphanumeric(p.src[p.i]) or p.src[p.i] == '_')) p.i += 1;
        return p.src[start..p.i];
    }

    fn eat(p: *Parser, c: u8) bool {
        if (p.peek(0) == c) {
            p.i += 1;
            return true;
        }
        return false;
    }

    fn noteIndex(p: *Parser, index: u32) void {
        if (index == 0) p.has_final = true;
        p.max_index = @max(p.max_index, index);
    }

    /// At a `$`.
    fn parseDollar(p: *Parser) Fail!Node {
        p.i += 1;
        if (p.int()) |n| {
            p.noteIndex(n);
            return .{ .tabstop = .{ .index = n } };
        }
        if (p.varName()) |name| return .{ .variable = .{ .name = name } };
        if (!p.eat('{')) return error.Syntax;
        if (p.int()) |n| {
            if (p.eat('}')) {
                p.noteIndex(n);
                return .{ .tabstop = .{ .index = n } };
            }
            if (p.eat(':')) {
                const children = try p.parseAny(true);
                if (!p.eat('}')) return error.Syntax;
                p.noteIndex(n);
                return .{ .placeholder = .{ .index = n, .children = children } };
            }
            if (p.eat('|')) {
                const options = try p.choiceOptions();
                p.noteIndex(n);
                return .{ .choice = .{ .index = n, .options = options } };
            }
            if (p.peek(0) == '/') {
                const t = try p.parseTransform();
                p.noteIndex(n);
                return .{ .tabstop = .{ .index = n, .transform = t } };
            }
            return error.Syntax;
        }
        const name = p.varName() orelse return error.Syntax;
        if (p.eat('}')) return .{ .variable = .{ .name = name } };
        if (p.eat(':')) {
            const d = try p.parseAny(true);
            if (!p.eat('}')) return error.Syntax;
            return .{ .variable = .{ .name = name, .default = d } };
        }
        if (p.peek(0) == '/') {
            const t = try p.parseTransform();
            return .{ .variable = .{ .name = name, .transform = t } };
        }
        return error.Syntax;
    }

    /// After `${n|`: options up to `|}`.
    fn choiceOptions(p: *Parser) Fail![]const []const u8 {
        var opts: std.ArrayList([]const u8) = .empty;
        var cur: std.ArrayList(u8) = .empty;
        while (p.i < p.src.len) {
            const c = p.src[p.i];
            if (c == '\\') if (p.peek(1)) |n| if (n == ',' or n == '|' or n == '\\' or n == '$' or n == '}') {
                try cur.append(p.a, n);
                p.i += 2;
                continue;
            };
            if (c == ',') {
                try opts.append(p.a, try cur.toOwnedSlice(p.a));
                p.i += 1;
                continue;
            }
            if (c == '|') {
                if (p.peek(1) != '}') return error.Syntax;
                try opts.append(p.a, try cur.toOwnedSlice(p.a));
                p.i += 2;
                return opts.toOwnedSlice(p.a);
            }
            try cur.append(p.a, c);
            p.i += 1;
        }
        return error.Syntax;
    }

    /// Text up to an unescaped `/` (consumed); `\/` is a slash, other
    /// escapes are kept for the regex (`keep_escapes`) or resolved.
    fn slashPart(p: *Parser, keep_escapes: bool) Fail![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        while (p.i < p.src.len) {
            const c = p.src[p.i];
            if (c == '\\') if (p.peek(1)) |n| {
                if (n == '/') {
                    try out.append(p.a, '/');
                } else if (keep_escapes) {
                    try out.appendSlice(p.a, &.{ '\\', n });
                } else try out.append(p.a, n);
                p.i += 2;
                continue;
            };
            if (c == '/') {
                p.i += 1;
                return out.toOwnedSlice(p.a);
            }
            try out.append(p.a, c);
            p.i += 1;
        }
        return error.Syntax;
    }

    /// At `/regex/format/options}`; consumes the closing brace.
    fn parseTransform(p: *Parser) Fail!*Transform {
        const src_start = p.i;
        p.i += 1;
        const regex = try p.slashPart(true);
        const format = try p.formatItems();
        const opts_start = p.i;
        while (p.i < p.src.len and p.src[p.i] != '}') p.i += 1;
        if (p.i >= p.src.len) return error.Syntax;
        const flags = p.src[opts_start..p.i];
        p.i += 1;
        const key = p.src[src_start..p.i];
        if (p.seen.get(key)) |t| return t;
        const t = try p.a.create(Transform);
        t.* = try Transform.init(p.gpa, regex, format, flags);
        p.transforms.append(p.gpa, t) catch |e| {
            t.deinit(p.gpa);
            return e;
        };
        try p.seen.put(p.a, key, t);
        return t;
    }

    /// Format items up to the unescaped `/` (consumed).
    fn formatItems(p: *Parser) Fail![]const FormatItem {
        var items: std.ArrayList(FormatItem) = .empty;
        var text: std.ArrayList(u8) = .empty;
        while (p.i < p.src.len) {
            const c = p.src[p.i];
            if (c == '\\') if (p.peek(1)) |n| if (n == '/' or n == '$' or n == '\\') {
                try text.append(p.a, n);
                p.i += 2;
                continue;
            };
            if (c == '/') {
                p.i += 1;
                if (text.items.len > 0) try items.append(p.a, .{ .text = try text.toOwnedSlice(p.a) });
                return items.toOwnedSlice(p.a);
            }
            if (c == '$') {
                const at = p.i;
                if (try p.formatItem()) |it| {
                    if (text.items.len > 0) try items.append(p.a, .{ .text = try text.toOwnedSlice(p.a) });
                    try items.append(p.a, it);
                    continue;
                }
                p.i = at;
            }
            try text.append(p.a, c);
            p.i += 1;
        }
        return error.Syntax;
    }

    fn formatItem(p: *Parser) Allocator.Error!?FormatItem {
        p.i += 1;
        if (p.int()) |g| return .{ .group = g };
        if (!p.eat('{')) return null;
        const g = p.int() orelse return null;
        if (p.eat('}')) return .{ .group = g };
        if (!p.eat(':')) return null;
        if (p.eat('/')) {
            const name = p.varName() orelse return null;
            if (!p.eat('}')) return null;
            const op = std.meta.stringToEnum(transform.CaseOp, name) orelse return null;
            return .{ .case = .{ .group = g, .op = op } };
        }
        if (p.eat('+')) {
            const t = try p.braceText(false) orelse return null;
            return .{ .if_else = .{ .group = g, .if_text = t, .else_text = null } };
        }
        if (p.eat('?')) {
            const t = try p.braceText(true) orelse return null;
            if (p.peek(0) != ':') return null;
            p.i += 1;
            const e = try p.braceText(false) orelse return null;
            return .{ .if_else = .{ .group = g, .if_text = t, .else_text = e } };
        }
        _ = p.eat('-');
        const e = try p.braceText(false) orelse return null;
        return .{ .if_else = .{ .group = g, .if_text = null, .else_text = e } };
    }

    /// Text up to `}` (consumed), or up to `:` (left) when `stop_colon`;
    /// `\}`, `\:` and `\\` escape.
    fn braceText(p: *Parser, stop_colon: bool) Allocator.Error!?[]const u8 {
        var out: std.ArrayList(u8) = .empty;
        while (p.i < p.src.len) {
            const c = p.src[p.i];
            if (c == '\\') if (p.peek(1)) |n| if (n == '}' or n == ':' or n == '\\' or n == '/') {
                try out.append(p.a, n);
                p.i += 2;
                continue;
            };
            if (c == ':' and stop_colon) return try out.toOwnedSlice(p.a);
            if (c == '/') return null;
            if (c == '}') {
                p.i += 1;
                return try out.toOwnedSlice(p.a);
            }
            try out.append(p.a, c);
            p.i += 1;
        }
        return null;
    }
};
