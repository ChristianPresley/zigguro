//! The revset syntax tree, and a printer whose output parses back to the
//! same tree.

const std = @import("std");

pub const Span = [2]u32;

pub const PrefixOp = enum {
    /// `~x`: everything visible except x.
    negate,
    /// `::x`: ancestors of x, x included.
    dag_to,
    /// `..x`: ancestors of x, except the root commits.
    range_to,
};

pub const PostfixOp = enum {
    /// `x-`: parents.
    parents,
    /// `x+`: children.
    children,
    /// `x::`: descendants of x, x included.
    dag_from,
    /// `x..`: visible commits that are not ancestors of x.
    range_from,
};

pub const BinaryOp = enum {
    @"union",
    intersection,
    difference,
    /// `x::y`: descendants of x that are ancestors of y.
    dag_range,
    /// `x..y`: ancestors of y that are not ancestors of x.
    range,
};

/// A string pattern: `kind:"text"` or a bare string (kind "").
pub const Pattern = struct {
    kind: []const u8,
    text: []const u8,
};

pub const Node = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        /// A bookmark or tag name, an ID prefix, or a quoted string.
        symbol: []const u8,
        /// `@` (`workspace` empty) or `name@`: a working-copy commit.
        working_copy: []const u8,
        /// `name@remote`.
        remote_symbol: struct { name: []const u8, remote: []const u8 },
        pattern: Pattern,
        /// `::` alone: all visible commits.
        all,
        call: struct { name: []const u8, name_span: Span, args: []const *Node },
        prefix: struct { op: PrefixOp, operand: *Node },
        postfix: struct { op: PostfixOp, operand: *Node },
        binary: struct { op: BinaryOp, lhs: *Node, rhs: *Node },
    };
};

/// Whether `a` and `b` are the same tree (spans ignored).
pub fn eql(a: *const Node, b: *const Node) bool {
    if (std.meta.activeTag(a.kind) != std.meta.activeTag(b.kind)) return false;
    const s = std.mem.eql;
    return switch (a.kind) {
        .symbol => |x| s(u8, x, b.kind.symbol),
        .working_copy => |x| s(u8, x, b.kind.working_copy),
        .remote_symbol => |x| s(u8, x.name, b.kind.remote_symbol.name) and s(u8, x.remote, b.kind.remote_symbol.remote),
        .pattern => |x| s(u8, x.kind, b.kind.pattern.kind) and s(u8, x.text, b.kind.pattern.text),
        .all => true,
        .call => |x| blk: {
            const y = b.kind.call;
            if (!s(u8, x.name, y.name) or x.args.len != y.args.len) break :blk false;
            for (x.args, y.args) |p, q| if (!eql(p, q)) break :blk false;
            break :blk true;
        },
        .prefix => |x| x.op == b.kind.prefix.op and eql(x.operand, b.kind.prefix.operand),
        .postfix => |x| x.op == b.kind.postfix.op and eql(x.operand, b.kind.postfix.operand),
        .binary => |x| x.op == b.kind.binary.op and eql(x.lhs, b.kind.binary.lhs) and eql(x.rhs, b.kind.binary.rhs),
    };
}

/// Prints `n` so that it parses back to an equal tree: compound operands
/// are parenthesized and strings are quoted when they are not plain
/// symbols.
pub fn format(n: *const Node, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (n.kind) {
        .symbol => |x| try writeSymbol(w, x),
        .working_copy => |x| {
            if (x.len > 0) try writeSymbol(w, x);
            try w.writeByte('@');
        },
        .remote_symbol => |x| {
            try writeSymbol(w, x.name);
            try w.writeByte('@');
            try writeSymbol(w, x.remote);
        },
        .pattern => |p| {
            try w.writeAll(p.kind);
            try w.writeByte(':');
            try writeQuoted(w, p.text);
        },
        .all => try w.writeAll("::"),
        .call => |c| {
            try w.writeAll(c.name);
            try w.writeByte('(');
            for (c.args, 0..) |a, i| {
                if (i > 0) try w.writeAll(", ");
                try format(a, w);
            }
            try w.writeByte(')');
        },
        .prefix => |p| {
            try w.writeAll(switch (p.op) {
                .negate => "~",
                .dag_to => "::",
                .range_to => "..",
            });
            try operand(p.operand, w);
        },
        .postfix => |p| {
            // `x--` needs no parentheses.
            const chained = (p.op == .parents or p.op == .children) and switch (p.operand.kind) {
                .postfix => |q| q.op == .parents or q.op == .children,
                else => false,
            };
            if (chained) try format(p.operand, w) else try operand(p.operand, w);
            try w.writeAll(switch (p.op) {
                .parents => "-",
                .children => "+",
                .dag_from => "::",
                .range_from => "..",
            });
        },
        .binary => |b| {
            try operand(b.lhs, w);
            try w.writeAll(switch (b.op) {
                .@"union" => " | ",
                .intersection => " & ",
                .difference => " ~ ",
                .dag_range => "::",
                .range => "..",
            });
            try operand(b.rhs, w);
        },
    }
}

fn operand(n: *const Node, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (n.kind) {
        .prefix, .postfix, .binary, .all => {
            try w.writeByte('(');
            try format(n, w);
            try w.writeByte(')');
        },
        else => try format(n, w),
    }
}

/// Whether `text` lexes as one bare symbol.
pub fn isPlainSymbol(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = 0;
    while (i < text.len) {
        if (isSymbolChar(text[i])) {
            i += 1;
            continue;
        }
        // '.', '-' and '+' only between symbol characters.
        if ((text[i] == '.' or text[i] == '-' or text[i] == '+') and i > 0 and i + 1 < text.len and
            isSymbolChar(text[i - 1]) and isSymbolChar(text[i + 1]))
        {
            i += 1;
            continue;
        }
        return false;
    }
    return true;
}

pub fn isSymbolChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '/' or c >= 0x80;
}

fn writeSymbol(w: *std.Io.Writer, text: []const u8) !void {
    if (isPlainSymbol(text)) try w.writeAll(text) else try writeQuoted(w, text);
}

fn writeQuoted(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11...31, 127 => try w.print("\\x{x:0>2}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}
