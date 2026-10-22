//! The regex abstract syntax tree: a faithful, span-carrying image of the
//! pattern as written. Flags, Unicode property names and assertion meanings
//! are resolved later, by `translate` into HIR.
//!
//! Every node lives in the parser's arena. `print` writes a pattern that
//! re-parses to an equivalent tree, and `dump` writes the indented form the
//! parser goldens use. Both recurse, which is safe because only trees that
//! passed the parser's nest limit reach them.

const std = @import("std");

/// A half-open byte range `[start, end)` in the pattern.
pub const Span = struct {
    start: u32,
    end: u32,

    /// The span covering both `a` and `b`.
    pub fn cover(a: Span, b: Span) Span {
        return .{ .start = @min(a.start, b.start), .end = @max(a.end, b.end) };
    }
};

/// The inline flags `i m s U u x R`.
pub const Flags = packed struct(u8) {
    /// `i`: case-insensitive.
    case_insensitive: bool = false,
    /// `m`: `^` and `$` match at line boundaries.
    multi_line: bool = false,
    /// `s`: `.` matches `\n`.
    dot_all: bool = false,
    /// `U`: swap the meaning of greedy and lazy repetition.
    swap_greed: bool = false,
    /// `u`: Unicode mode (on by default).
    unicode: bool = false,
    /// `x`: ignore whitespace and allow `#` comments.
    ignore_whitespace: bool = false,
    /// `R`: CRLF mode: `\r\n` is a line terminator.
    crlf: bool = false,
    _pad: u1 = 0,

    /// Whether no flag is set.
    pub fn isEmpty(f: Flags) bool {
        return @as(u8, @bitCast(f)) == 0;
    }

    /// The flags set in either operand.
    pub fn merge(a: Flags, b: Flags) Flags {
        return @bitCast(@as(u8, @bitCast(a)) | @as(u8, @bitCast(b)));
    }

    /// `a` with every flag set in `b` cleared.
    pub fn without(a: Flags, b: Flags) Flags {
        return @bitCast(@as(u8, @bitCast(a)) & ~@as(u8, @bitCast(b)));
    }

    /// The flag for letter `c`, or null when `c` is not a flag letter.
    pub fn fromLetter(c: u8) ?Flags {
        return switch (c) {
            'i' => .{ .case_insensitive = true },
            'm' => .{ .multi_line = true },
            's' => .{ .dot_all = true },
            'U' => .{ .swap_greed = true },
            'u' => .{ .unicode = true },
            'x' => .{ .ignore_whitespace = true },
            'R' => .{ .crlf = true },
            else => null,
        };
    }

    /// Writes the flag letters in canonical order.
    pub fn write(f: Flags, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (f.case_insensitive) try w.writeByte('i');
        if (f.multi_line) try w.writeByte('m');
        if (f.dot_all) try w.writeByte('s');
        if (f.swap_greed) try w.writeByte('U');
        if (f.unicode) try w.writeByte('u');
        if (f.ignore_whitespace) try w.writeByte('x');
        if (f.crlf) try w.writeByte('R');
    }
};

/// How a literal was written.
pub const LitKind = enum {
    /// The character itself.
    verbatim,
    /// An escaped meta or punctuation character, e.g. `\.`.
    meta,
    /// `\a \f \t \n \r \v \0`.
    special,
    /// `\x7F`, `\x{..}`, `\u007F`, `\u{..}`, `\U0000007F`, `\U{..}`.
    hex,
};

/// What a zero-width assertion tests. Line anchors are resolved against the
/// `m` and `R` flags during translation.
pub const AssertKind = enum {
    /// `^`
    start_line,
    /// `$`
    end_line,
    /// `\A`
    start_text,
    /// `\z`
    end_text,
    /// `\b`
    word_boundary,
    /// `\B`
    not_word_boundary,
    /// `\b{start}` or `\<`
    word_start,
    /// `\b{end}` or `\>`
    word_end,
    /// `\b{start-half}`
    word_start_half,
    /// `\b{end-half}`
    word_end_half,
};

/// A Perl class `\d \s \w`.
pub const PerlKind = enum { digit, space, word };

/// A POSIX class inside brackets, e.g. `[[:alpha:]]`.
pub const AsciiKind = enum {
    alnum,
    alpha,
    ascii,
    blank,
    cntrl,
    digit,
    graph,
    lower,
    print,
    punct,
    space,
    upper,
    word,
    xdigit,

    /// The kind named `name`, or null.
    pub fn fromName(name: []const u8) ?AsciiKind {
        return std.meta.stringToEnum(AsciiKind, name);
    }
};

/// The kind of a group.
pub const GroupKind = union(enum) {
    /// `( )`, `(?P<name> )` or `(?<name> )`; indices start at 1.
    capture: struct { index: u32, name: ?[]const u8, name_span: ?Span = null },
    /// `(?: )` or `(?flags: )`.
    non_capture: struct { set: Flags = .{}, clear: Flags = .{} },
};

/// One element of a bracketed class.
pub const ClassItem = union(enum) {
    /// A single character.
    literal: struct { span: Span, cp: u21, kind: LitKind },
    /// `a-z`.
    range: struct { span: Span, lo: u21, hi: u21, lo_kind: LitKind, hi_kind: LitKind },
    /// `[:alpha:]` or `[:^alpha:]`.
    ascii: struct { span: Span, kind: AsciiKind, negated: bool },
    /// `\d \s \w` and negations.
    perl: struct { span: Span, kind: PerlKind, negated: bool },
    /// `\pL`, `\p{Greek}`, `\p{sc=Grek}` and negations.
    unicode: Unicode,
    /// A nested `[...]`.
    bracketed: Bracketed,
    /// Juxtaposed items; may be empty only as the operand of nothing.
    union_: struct { span: Span, items: []ClassItem },

    /// The item's span.
    pub fn span(it: ClassItem) Span {
        return switch (it) {
            inline else => |x| x.span,
        };
    }
};

/// A Unicode property class.
pub const Unicode = struct {
    span: Span,
    negated: bool,
    /// `L` in `\pL`, `Greek` in `\p{Greek}`, `sc` in `\p{sc=Grek}`.
    name: []const u8,
    /// `Grek` in `\p{sc=Grek}`; null for one-part forms.
    value: ?[]const u8,
    /// Whether the braced form was used (needed to print `\pL` back).
    braced: bool = true,
};

/// A bracketed class `[...]`.
pub const Bracketed = struct {
    span: Span,
    negated: bool,
    set: *ClassSet,
};

/// A class set: one item or a binary set operation.
pub const ClassSet = union(enum) {
    /// A plain item (often a union).
    item: ClassItem,
    /// `lhs && rhs`, `lhs -- rhs` or `lhs ~~ rhs`.
    binary: struct { op: SetOp, lhs: *ClassSet, rhs: *ClassSet },
};

/// A class set operator.
pub const SetOp = enum { intersection, difference, symmetric_difference };

/// The syntax tree.
pub const Ast = union(enum) {
    /// The empty regex, e.g. either side of `|`.
    empty: Span,
    /// A single character.
    literal: struct { span: Span, cp: u21, kind: LitKind },
    /// `.`
    dot: Span,
    /// A zero-width assertion.
    assertion: struct { span: Span, kind: AssertKind },
    /// `\d \s \w \D \S \W`.
    class_perl: struct { span: Span, kind: PerlKind, negated: bool },
    /// `\pL`, `\p{...}`, `\PL`, `\P{...}`.
    class_unicode: Unicode,
    /// `[...]`.
    class_bracketed: Bracketed,
    /// `x*`, `x{n,m}?` and friends; `max == null` is unbounded.
    repetition: struct { span: Span, op_span: Span, min: u32, max: ?u32, greedy: bool, sub: *Ast },
    /// A group.
    group: struct { span: Span, kind: GroupKind, sub: *Ast },
    /// A standalone `(?im-s)`; applies to the rest of the enclosing group.
    flags: struct { span: Span, set: Flags, clear: Flags },
    /// A sequence.
    concat: struct { span: Span, items: []*Ast },
    /// `a|b|c`.
    alternation: struct { span: Span, items: []*Ast },

    /// The node's span.
    pub fn span(a: *const Ast) Span {
        return switch (a.*) {
            .empty, .dot => |s| s,
            .class_unicode => |u| u.span,
            .class_bracketed => |b| b.span,
            inline else => |x| x.span,
        };
    }
};

// ---------------------------------------------------------------------------
// Printing

/// Writes a pattern that parses to a tree equivalent to `a` (same structure
/// and values; spans may differ).
pub fn print(a: *const Ast, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (a.*) {
        .empty => {},
        .literal => |l| try printLiteral(l.cp, false, w),
        .dot => try w.writeByte('.'),
        .assertion => |s| try w.writeAll(switch (s.kind) {
            .start_line => "^",
            .end_line => "$",
            .start_text => "\\A",
            .end_text => "\\z",
            .word_boundary => "\\b",
            .not_word_boundary => "\\B",
            .word_start => "\\b{start}",
            .word_end => "\\b{end}",
            .word_start_half => "\\b{start-half}",
            .word_end_half => "\\b{end-half}",
        }),
        .class_perl => |p| try printPerl(p.kind, p.negated, w),
        .class_unicode => |u| try printUnicode(u, w),
        .class_bracketed => |b| try printBracketed(b, w),
        .repetition => |r| {
            // A repetition of a concat or alternation needs a group; the
            // parser never produces one, but keep print total.
            const needs_group = switch (r.sub.*) {
                .concat, .alternation, .empty, .flags => true,
                else => false,
            };
            if (needs_group) try w.writeAll("(?:");
            try print(r.sub, w);
            if (needs_group) try w.writeByte(')');
            if (r.min == 0 and r.max == null) {
                try w.writeByte('*');
            } else if (r.min == 1 and r.max == null) {
                try w.writeByte('+');
            } else if (r.min == 0 and r.max != null and r.max.? == 1) {
                try w.writeByte('?');
            } else if (r.max) |m| {
                if (m == r.min) try w.print("{{{d}}}", .{m}) else try w.print("{{{d},{d}}}", .{ r.min, m });
            } else {
                try w.print("{{{d},}}", .{r.min});
            }
            if (!r.greedy) try w.writeByte('?');
        },
        .group => |g| {
            switch (g.kind) {
                .capture => |c| if (c.name) |n| try w.print("(?P<{s}>", .{n}) else try w.writeByte('('),
                .non_capture => |f| {
                    try w.writeAll("(?");
                    try f.set.write(w);
                    if (!f.clear.isEmpty()) {
                        try w.writeByte('-');
                        try f.clear.write(w);
                    }
                    try w.writeByte(':');
                },
            }
            try print(g.sub, w);
            try w.writeByte(')');
        },
        .flags => |f| {
            try w.writeAll("(?");
            try f.set.write(w);
            if (!f.clear.isEmpty()) {
                try w.writeByte('-');
                try f.clear.write(w);
            }
            try w.writeByte(')');
        },
        .concat => |c| for (c.items) |it| try print(it, w),
        .alternation => |alt| for (alt.items, 0..) |it, i| {
            if (i != 0) try w.writeByte('|');
            try print(it, w);
        },
    }
}

fn printLiteral(cp: u21, in_class: bool, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (cp) {
        '\n' => return w.writeAll("\\n"),
        '\t' => return w.writeAll("\\t"),
        '\r' => return w.writeAll("\\r"),
        0 => return w.writeAll("\\0"),
        else => {},
    }
    if (cp < 0x20 or cp == 0x7F) return w.print("\\x{X:0>2}", .{cp});
    if (cp < 0x80) {
        const c: u8 = @intCast(cp);
        const meta = if (in_class) isClassMeta(c) else isMeta(c);
        // `#` and whitespace are escaped so the output also survives `x` mode.
        if (meta or c == ' ' or c == '#') try w.writeByte('\\');
        return w.writeByte(c);
    }
    if (cp >= 0xD800 and cp <= 0xDFFF) return w.print("\\x{{{X}}}", .{cp});
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    try w.writeAll(buf[0..n]);
}

fn printPerl(kind: PerlKind, negated: bool, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const c: u8 = switch (kind) {
        .digit => 'd',
        .space => 's',
        .word => 'w',
    };
    try w.writeByte('\\');
    try w.writeByte(if (negated) std.ascii.toUpper(c) else c);
}

fn printUnicode(u: Unicode, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(if (u.negated) "\\P{" else "\\p{");
    try w.writeAll(u.name);
    if (u.value) |v| {
        try w.writeByte('=');
        try w.writeAll(v);
    }
    try w.writeByte('}');
}

fn printBracketed(b: Bracketed, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('[');
    if (b.negated) try w.writeByte('^');
    try printSet(b.set, w);
    try w.writeByte(']');
}

fn printSet(s: *const ClassSet, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (s.*) {
        .item => |it| try printItem(it, w),
        .binary => |bin| {
            // Operands are bracketed so precedence never matters on re-parse.
            try printOperand(bin.lhs, w);
            try w.writeAll(switch (bin.op) {
                .intersection => "&&",
                .difference => "--",
                .symmetric_difference => "~~",
            });
            try printOperand(bin.rhs, w);
        },
    }
}

fn printOperand(s: *const ClassSet, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (s.*) {
        // Juxtaposition binds tighter than every operator.
        .item => |it| try printItem(it, w),
        .binary => {
            try w.writeByte('[');
            try printSet(s, w);
            try w.writeByte(']');
        },
    }
}

fn printItem(it: ClassItem, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (it) {
        .literal => |l| try printLiteral(l.cp, true, w),
        .range => |r| {
            try printLiteral(r.lo, true, w);
            try w.writeByte('-');
            try printLiteral(r.hi, true, w);
        },
        .ascii => |a| try w.print("[:{s}{s}:]", .{ if (a.negated) "^" else "", @tagName(a.kind) }),
        .perl => |p| try printPerl(p.kind, p.negated, w),
        .unicode => |u| try printUnicode(u, w),
        .bracketed => |b| try printBracketed(b, w),
        .union_ => |u| for (u.items) |x| try printItem(x, w),
    }
}

/// Whether `c` must be escaped outside a class to stand for itself.
pub fn isMeta(c: u8) bool {
    return switch (c) {
        '\\', '.', '+', '*', '?', '(', ')', '|', '[', ']', '{', '}', '^', '$', '#', '&', '-', '~' => true,
        else => false,
    };
}

fn isClassMeta(c: u8) bool {
    return isMeta(c);
}

// ---------------------------------------------------------------------------
// Dumping

/// Writes an indented, one-node-per-line description of `a` with spans.
pub fn dump(a: *const Ast, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try dumpNode(a, 0, w);
}

fn indent(depth: usize, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (0..depth) |_| try w.writeAll("  ");
}

fn dumpNode(a: *const Ast, depth: usize, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try indent(depth, w);
    const s = a.span();
    switch (a.*) {
        .empty => try w.print("empty {d}..{d}\n", .{ s.start, s.end }),
        .literal => |l| try w.print("literal U+{X:0>4} {s} {d}..{d}\n", .{ l.cp, @tagName(l.kind), s.start, s.end }),
        .dot => try w.print("dot {d}..{d}\n", .{ s.start, s.end }),
        .assertion => |x| try w.print("assertion {s} {d}..{d}\n", .{ @tagName(x.kind), s.start, s.end }),
        .class_perl => |p| try w.print("perl {s}{s} {d}..{d}\n", .{ if (p.negated) "!" else "", @tagName(p.kind), s.start, s.end }),
        .class_unicode => |u| try w.print("unicode {s}{s}{s}{s} {d}..{d}\n", .{ if (u.negated) "!" else "", u.name, if (u.value != null) "=" else "", u.value orelse "", s.start, s.end }),
        .class_bracketed => |b| {
            try w.print("class{s} {d}..{d}\n", .{ if (b.negated) " negated" else "", s.start, s.end });
            try dumpSet(b.set, depth + 1, w);
        },
        .repetition => |r| {
            if (r.max) |m| {
                try w.print("repetition {{{d},{d}}}{s} {d}..{d}\n", .{ r.min, m, if (r.greedy) "" else " lazy", s.start, s.end });
            } else {
                try w.print("repetition {{{d},}}{s} {d}..{d}\n", .{ r.min, if (r.greedy) "" else " lazy", s.start, s.end });
            }
            try dumpNode(r.sub, depth + 1, w);
        },
        .group => |g| {
            switch (g.kind) {
                .capture => |c| try w.print("group capture {d}{s}{s} {d}..{d}\n", .{ c.index, if (c.name != null) " " else "", c.name orelse "", s.start, s.end }),
                .non_capture => |f| {
                    try w.writeAll("group non_capture ");
                    try f.set.write(w);
                    try w.writeByte('-');
                    try f.clear.write(w);
                    try w.print(" {d}..{d}\n", .{ s.start, s.end });
                },
            }
            try dumpNode(g.sub, depth + 1, w);
        },
        .flags => |f| {
            try w.writeAll("flags ");
            try f.set.write(w);
            try w.writeByte('-');
            try f.clear.write(w);
            try w.print(" {d}..{d}\n", .{ s.start, s.end });
        },
        .concat => |c| {
            try w.print("concat {d}..{d}\n", .{ s.start, s.end });
            for (c.items) |it| try dumpNode(it, depth + 1, w);
        },
        .alternation => |c| {
            try w.print("alternation {d}..{d}\n", .{ s.start, s.end });
            for (c.items) |it| try dumpNode(it, depth + 1, w);
        },
    }
}

fn dumpSet(set: *const ClassSet, depth: usize, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (set.*) {
        .item => |it| try dumpItem(it, depth, w),
        .binary => |b| {
            try indent(depth, w);
            try w.print("{s}\n", .{@tagName(b.op)});
            try dumpSet(b.lhs, depth + 1, w);
            try dumpSet(b.rhs, depth + 1, w);
        },
    }
}

fn dumpItem(it: ClassItem, depth: usize, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try indent(depth, w);
    const s = it.span();
    switch (it) {
        .literal => |l| try w.print("literal U+{X:0>4} {d}..{d}\n", .{ l.cp, s.start, s.end }),
        .range => |r| try w.print("range U+{X:0>4}-U+{X:0>4} {d}..{d}\n", .{ r.lo, r.hi, s.start, s.end }),
        .ascii => |a| try w.print("ascii {s}{s} {d}..{d}\n", .{ if (a.negated) "!" else "", @tagName(a.kind), s.start, s.end }),
        .perl => |p| try w.print("perl {s}{s} {d}..{d}\n", .{ if (p.negated) "!" else "", @tagName(p.kind), s.start, s.end }),
        .unicode => |u| try w.print("unicode {s}{s}{s}{s} {d}..{d}\n", .{ if (u.negated) "!" else "", u.name, if (u.value != null) "=" else "", u.value orelse "", s.start, s.end }),
        .bracketed => |b| {
            try w.print("class{s} {d}..{d}\n", .{ if (b.negated) " negated" else "", s.start, s.end });
            try dumpSet(b.set, depth + 1, w);
        },
        .union_ => |u| {
            try w.print("union {d}..{d}\n", .{ s.start, s.end });
            for (u.items) |x| try dumpItem(x, depth + 1, w);
        },
    }
}

/// Whether `a` and `b` have the same structure and values, ignoring spans.
pub fn eql(a: *const Ast, b: *const Ast) bool {
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    return switch (a.*) {
        .empty, .dot => true,
        .literal => |l| l.cp == b.literal.cp,
        .assertion => |x| x.kind == b.assertion.kind,
        .class_perl => |p| p.kind == b.class_perl.kind and p.negated == b.class_perl.negated,
        .class_unicode => |u| unicodeEql(u, b.class_unicode),
        .class_bracketed => |x| x.negated == b.class_bracketed.negated and setEql(x.set, b.class_bracketed.set),
        .repetition => |r| r.min == b.repetition.min and std.meta.eql(r.max, b.repetition.max) and r.greedy == b.repetition.greedy and eql(r.sub, b.repetition.sub),
        .group => |g| groupKindEql(g.kind, b.group.kind) and eql(g.sub, b.group.sub),
        .flags => |f| f.set == b.flags.set and f.clear == b.flags.clear,
        .concat => |c| itemsEql(c.items, b.concat.items),
        .alternation => |c| itemsEql(c.items, b.alternation.items),
    };
}

fn itemsEql(a: []*Ast, b: []*Ast) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!eql(x, y)) return false;
    return true;
}

fn groupKindEql(a: GroupKind, b: GroupKind) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .capture => |c| c.index == b.capture.index and optStrEql(c.name, b.capture.name),
        .non_capture => |f| f.set == b.non_capture.set and f.clear == b.non_capture.clear,
    };
}

fn unicodeEql(a: Unicode, b: Unicode) bool {
    return a.negated == b.negated and std.mem.eql(u8, a.name, b.name) and optStrEql(a.value, b.value);
}

fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// Whether two class sets have the same structure. A one-item union equals
/// its item and an unnegated `[x]` operand equals `x`, because printing adds
/// brackets around nested operations.
pub fn setEql(a_in: *const ClassSet, b_in: *const ClassSet) bool {
    const a = peel(a_in);
    const b = peel(b_in);
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    return switch (a.*) {
        .item => |it| itemEql(it, b.item),
        .binary => |x| x.op == b.binary.op and setEql(x.lhs, b.binary.lhs) and setEql(x.rhs, b.binary.rhs),
    };
}

fn itemEql(a: ClassItem, b: ClassItem) bool {
    const ua = unwrapUnion(a);
    const ub = unwrapUnion(b);
    if (std.meta.activeTag(ua) != std.meta.activeTag(ub)) return false;
    return switch (ua) {
        .literal => |l| l.cp == ub.literal.cp,
        .range => |r| r.lo == ub.range.lo and r.hi == ub.range.hi,
        .ascii => |x| x.kind == ub.ascii.kind and x.negated == ub.ascii.negated,
        .perl => |p| p.kind == ub.perl.kind and p.negated == ub.perl.negated,
        .unicode => |u| unicodeEql(u, ub.unicode),
        .bracketed => |x| x.negated == ub.bracketed.negated and setEql(x.set, ub.bracketed.set),
        .union_ => |u| blk: {
            if (u.items.len != ub.union_.items.len) break :blk false;
            for (u.items, ub.union_.items) |x, y| if (!itemEql(x, y)) break :blk false;
            break :blk true;
        },
    };
}

// An unnegated bracketed item denotes the same set as its contents.
fn peel(s: *const ClassSet) *const ClassSet {
    var c = s;
    while (c.* == .item and c.item == .bracketed and !c.item.bracketed.negated) c = c.item.bracketed.set;
    return c;
}

fn unwrapUnion(it: ClassItem) ClassItem {
    var cur = it;
    while (cur == .union_ and cur.union_.items.len == 1) cur = cur.union_.items[0];
    return cur;
}
