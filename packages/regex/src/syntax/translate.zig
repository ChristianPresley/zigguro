//! AST -> HIR translation: resolves flags (scoped groups and standalone
//! `(?flags)` that last to the end of the enclosing group, carrying across
//! later alternation branches as in Rust `regex`), resolves Unicode
//! properties, computes class set operations, applies simple case folding,
//! expands Perl classes per UTS #18 Annex C, and coalesces literals.
//!
//! Recursion depth is bounded by the parser's nest limit.

const std = @import("std");
const ast = @import("ast.zig");
const hir = @import("hir.zig");
const class = @import("class.zig");
const unicode = @import("unicode.zig");
const casefold = @import("casefold.zig");
const errors = @import("errors.zig");

const Allocator = std.mem.Allocator;
const Ast = ast.Ast;
const Hir = hir.Hir;
const RangeSet = class.RangeSet;
const ByteSet = class.ByteSet;
const Flags = ast.Flags;

/// The translation result.
pub const Result = union(enum) {
    ok: *Hir,
    err: errors.Error,
};

/// Translates `root` starting from `flags` (whose `unicode` bit is normally
/// set). Everything is allocated in `arena`.
pub fn translate(arena: Allocator, root: *const Ast, flags: Flags) Allocator.Error!Result {
    var t: Translator = .{ .arena = arena, .flags = flags };
    const h = t.node(root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Translate => return .{ .err = t.err },
    };
    return .{ .ok = h };
}

const TError = error{Translate} || Allocator.Error;

const Translator = struct {
    arena: Allocator,
    flags: Flags,
    err: errors.Error = undefined,

    fn fail(t: *Translator, kind: errors.ErrorKind, span: ast.Span) error{Translate} {
        t.err = .{ .kind = kind, .span = span };
        return error.Translate;
    }

    fn new(t: *Translator, v: Hir) Allocator.Error!*Hir {
        const h = try t.arena.create(Hir);
        h.* = v;
        return h;
    }

    fn node(t: *Translator, a: *const Ast) TError!*Hir {
        switch (a.*) {
            .empty => return t.new(.empty),
            .flags => |f| {
                t.flags = t.flags.merge(f.set).without(f.clear);
                return t.new(.empty);
            },
            .literal => |l| return t.literal(l.cp, l.kind, l.span),
            .dot => return t.dot(),
            .assertion => |x| return t.new(.{ .look = t.look(x.kind) }),
            .class_perl => |p| {
                if (t.flags.unicode) {
                    var s = try t.perlUnicode(p.kind);
                    if (p.negated) s = try s.negate(t.arena);
                    return t.unicodeClass(s, false);
                }
                var b = perlAscii(p.kind);
                if (p.negated) b = b.negate();
                return t.new(.{ .class_bytes = b });
            },
            .class_unicode => |u| {
                if (!t.flags.unicode) return t.fail(.unicode_not_allowed, u.span);
                var s = try t.property(u);
                if (t.flags.case_insensitive) s = try s.caseFoldClosure(t.arena);
                return t.unicodeClass(s, false);
            },
            .class_bracketed => |b| return t.bracketed(b),
            .repetition => |r| {
                const sub = try t.node(r.sub);
                if (r.max != null and r.max.? == 0) return t.new(.empty);
                if (r.min == 1 and r.max != null and r.max.? == 1) return sub;
                return t.new(.{ .repetition = .{ .min = r.min, .max = r.max, .greedy = r.greedy != t.flags.swap_greed, .sub = sub } });
            },
            .group => |g| {
                const saved = t.flags;
                defer t.flags = saved;
                switch (g.kind) {
                    .capture => |c| {
                        const sub = try t.node(g.sub);
                        return t.new(.{ .capture = .{ .index = c.index, .name = c.name, .sub = sub } });
                    },
                    .non_capture => |f| {
                        t.flags = t.flags.merge(f.set).without(f.clear);
                        return t.node(g.sub);
                    },
                }
            },
            .concat => |c| {
                var items: std.ArrayList(*Hir) = .empty;
                for (c.items) |it| {
                    const h = try t.node(it);
                    if (h.* == .empty) continue;
                    // Coalesce adjacent literals.
                    if (h.* == .literal and items.items.len > 0 and items.items[items.items.len - 1].* == .literal) {
                        const prev = items.items[items.items.len - 1];
                        prev.literal = try std.mem.concat(t.arena, u8, &.{ prev.literal, h.literal });
                        continue;
                    }
                    if (h.* == .concat) {
                        try items.appendSlice(t.arena, h.concat);
                        continue;
                    }
                    try items.append(t.arena, h);
                }
                return switch (items.items.len) {
                    0 => t.new(.empty),
                    1 => items.items[0],
                    else => t.new(.{ .concat = items.items }),
                };
            },
            .alternation => |c| {
                var items = try t.arena.alloc(*Hir, c.items.len);
                for (c.items, 0..) |it, i| items[i] = try t.node(it);
                return t.new(.{ .alternation = items });
            },
        }
    }

    fn literal(t: *Translator, cp: u21, kind: ast.LitKind, span: ast.Span) TError!*Hir {
        if (!t.flags.unicode) {
            // Hex escapes and escaped ASCII denote single bytes; other
            // characters are their UTF-8 encoding.
            if (cp <= 0x7F or (kind == .hex and cp <= 0xFF)) {
                const b: u8 = @intCast(cp);
                if (t.flags.case_insensitive and std.ascii.isAlphabetic(b)) {
                    var s: ByteSet = .{};
                    s.addRange(std.ascii.toLower(b), std.ascii.toLower(b));
                    return t.new(.{ .class_bytes = s.asciiCaseFold() });
                }
                return t.new(.{ .literal = try t.arena.dupe(u8, &.{b}) });
            }
            if (kind == .hex) return t.fail(.unicode_not_allowed, span);
        }
        if (t.flags.case_insensitive) {
            const orbit = casefold.simpleFoldOrbit(cp);
            if (orbit.len > 1) {
                var rs = try t.arena.alloc([2]u21, orbit.len);
                for (orbit, 0..) |m, i| rs[i] = .{ m, m };
                return t.unicodeClass(try RangeSet.fromRanges(t.arena, rs), false);
            }
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return t.fail(.escape_hex_invalid, span);
        return t.new(.{ .literal = try t.arena.dupe(u8, buf[0..n]) });
    }

    /// A Unicode class node, collapsed to a literal for a single code point.
    fn unicodeClass(t: *Translator, s: RangeSet, _: bool) Allocator.Error!*Hir {
        if (s.ranges.len == 1 and s.ranges[0][0] == s.ranges[0][1]) {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(s.ranges[0][0], &buf) catch unreachable;
            return t.new(.{ .literal = try t.arena.dupe(u8, buf[0..n]) });
        }
        return t.new(.{ .class_unicode = s });
    }

    fn dot(t: *Translator) Allocator.Error!*Hir {
        if (t.flags.unicode) {
            if (t.flags.dot_all) return t.new(.{ .class_unicode = RangeSet.all });
            const s = if (t.flags.crlf)
                try RangeSet.fromRanges(t.arena, &.{ .{ 0, 9 }, .{ 11, 12 }, .{ 14, class.max_cp } })
            else
                try RangeSet.fromRanges(t.arena, &.{ .{ 0, 9 }, .{ 11, class.max_cp } });
            return t.new(.{ .class_unicode = s });
        }
        var b: ByteSet = .{};
        b.addRange(0, 255);
        if (!t.flags.dot_all) {
            b.bits.unset('\n');
            if (t.flags.crlf) b.bits.unset('\r');
        }
        return t.new(.{ .class_bytes = b });
    }

    fn look(t: *Translator, k: ast.AssertKind) hir.Look {
        const u = t.flags.unicode;
        return switch (k) {
            .start_text => .start_text,
            .end_text => .end_text,
            .start_line => if (!t.flags.multi_line) .start_text else if (t.flags.crlf) .start_line_crlf else .start_line,
            .end_line => if (!t.flags.multi_line) .end_text else if (t.flags.crlf) .end_line_crlf else .end_line,
            .word_boundary => if (u) .word_unicode else .word_ascii,
            .not_word_boundary => if (u) .word_unicode_negate else .word_ascii_negate,
            .word_start => if (u) .word_start_unicode else .word_start_ascii,
            .word_end => if (u) .word_end_unicode else .word_end_ascii,
            .word_start_half => if (u) .word_start_half_unicode else .word_start_half_ascii,
            .word_end_half => if (u) .word_end_half_unicode else .word_end_half_ascii,
        };
    }

    fn perlUnicode(t: *Translator, k: ast.PerlKind) Allocator.Error!RangeSet {
        _ = t;
        return .{ .ranges = switch (k) {
            .digit => unicode.perlDigit(),
            .space => unicode.perlSpace(),
            .word => unicode.perlWord(),
        } };
    }

    fn property(t: *Translator, u: ast.Unicode) TError!RangeSet {
        const r = unicode.propertyRanges(u.name, u.value) orelse return t.fail(.unicode_property_unknown, u.span);
        var s: RangeSet = .{ .ranges = r.ranges };
        if (r.negated != u.negated) s = try s.negate(t.arena);
        return s;
    }

    fn bracketed(t: *Translator, b: ast.Bracketed) TError!*Hir {
        if (t.flags.unicode) {
            var s = try t.setUnicode(b.set);
            if (t.flags.case_insensitive) s = try s.caseFoldClosure(t.arena);
            if (b.negated) s = try s.negate(t.arena);
            return t.unicodeClass(s, false);
        }
        var s = try t.setBytes(b.set);
        if (t.flags.case_insensitive) s = s.asciiCaseFold();
        if (b.negated) s = s.negate();
        return t.new(.{ .class_bytes = s });
    }

    fn setUnicode(t: *Translator, s: *const ast.ClassSet) TError!RangeSet {
        switch (s.*) {
            .binary => |bin| {
                const l = try t.setUnicode(bin.lhs);
                const r = try t.setUnicode(bin.rhs);
                return switch (bin.op) {
                    .intersection => l.intersect(r, t.arena),
                    .difference => l.difference(r, t.arena),
                    .symmetric_difference => l.symmetricDifference(r, t.arena),
                };
            },
            .item => |it| return t.itemUnicode(it),
        }
    }

    fn itemUnicode(t: *Translator, it: ast.ClassItem) TError!RangeSet {
        return switch (it) {
            .literal => |l| RangeSet.single(t.arena, l.cp),
            .range => |r| RangeSet.fromRanges(t.arena, &.{.{ r.lo, r.hi }}),
            .ascii => |a| blk: {
                var s = try RangeSet.fromRanges(t.arena, asciiRanges(a.kind));
                if (a.negated) s = try s.negate(t.arena);
                break :blk s;
            },
            .perl => |p| blk: {
                var s = try t.perlUnicode(p.kind);
                if (p.negated) s = try s.negate(t.arena);
                break :blk s;
            },
            .unicode => |u| t.property(u),
            .bracketed => |nb| blk: {
                var s = try t.setUnicode(nb.set);
                if (nb.negated) s = try s.negate(t.arena);
                break :blk s;
            },
            .union_ => |u| blk: {
                var acc: std.ArrayList([2]u21) = .empty;
                for (u.items) |x| {
                    const s = try t.itemUnicode(x);
                    try acc.appendSlice(t.arena, s.ranges);
                }
                break :blk RangeSet.fromRanges(t.arena, acc.items);
            },
        };
    }

    fn setBytes(t: *Translator, s: *const ast.ClassSet) TError!ByteSet {
        switch (s.*) {
            .binary => |bin| {
                const l = try t.setBytes(bin.lhs);
                const r = try t.setBytes(bin.rhs);
                return switch (bin.op) {
                    .intersection => l.intersect(r),
                    .difference => l.difference(r),
                    .symmetric_difference => l.symmetricDifference(r),
                };
            },
            .item => |it| return t.itemBytes(it),
        }
    }

    fn itemBytes(t: *Translator, it: ast.ClassItem) TError!ByteSet {
        var out: ByteSet = .{};
        switch (it) {
            .literal => |l| {
                if (l.cp > 0xFF) return t.fail(.unicode_not_allowed, l.span);
                out.addRange(@intCast(l.cp), @intCast(l.cp));
            },
            .range => |r| {
                if (r.hi > 0xFF) return t.fail(.unicode_not_allowed, r.span);
                out.addRange(@intCast(r.lo), @intCast(r.hi));
            },
            .ascii => |a| {
                for (asciiRanges(a.kind)) |r| out.addRange(@intCast(r[0]), @intCast(r[1]));
                if (a.negated) out = out.negate();
            },
            .perl => |p| {
                out = perlAscii(p.kind);
                if (p.negated) out = out.negate();
            },
            .unicode => |u| return t.fail(.unicode_not_allowed, u.span),
            .bracketed => |nb| {
                out = try t.setBytes(nb.set);
                if (nb.negated) out = out.negate();
            },
            .union_ => |u| for (u.items) |x| {
                out = out.unionWith(try t.itemBytes(x));
            },
        }
        return out;
    }
};

/// The ranges of a POSIX class.
pub fn asciiRanges(k: ast.AsciiKind) []const [2]u21 {
    return switch (k) {
        .alnum => &.{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ 'a', 'z' } },
        .alpha => &.{ .{ 'A', 'Z' }, .{ 'a', 'z' } },
        .ascii => &.{.{ 0, 0x7F }},
        .blank => &.{ .{ '\t', '\t' }, .{ ' ', ' ' } },
        .cntrl => &.{ .{ 0, 0x1F }, .{ 0x7F, 0x7F } },
        .digit => &.{.{ '0', '9' }},
        .graph => &.{.{ '!', '~' }},
        .lower => &.{.{ 'a', 'z' }},
        .print => &.{.{ ' ', '~' }},
        .punct => &.{ .{ '!', '/' }, .{ ':', '@' }, .{ '[', '`' }, .{ '{', '~' } },
        .space => &.{ .{ '\t', '\r' }, .{ ' ', ' ' } },
        .upper => &.{.{ 'A', 'Z' }},
        .word => &.{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ 'a', 'z' } },
        .xdigit => &.{ .{ '0', '9' }, .{ 'A', 'F' }, .{ 'a', 'f' } },
    };
}

/// `\d \s \w` in ASCII mode.
pub fn perlAscii(k: ast.PerlKind) ByteSet {
    var s: ByteSet = .{};
    const rs = asciiRanges(switch (k) {
        .digit => .digit,
        .space => .space,
        .word => .word,
    });
    for (rs) |r| s.addRange(@intCast(r[0]), @intCast(r[1]));
    return s;
}

// ---------------------------------------------------------------------------

const parse = @import("parse.zig");

fn translateStr(arena: Allocator, pattern: []const u8) ![]const u8 {
    const a = switch (try parse.parse(arena, pattern, .{})) {
        .ok => |x| x,
        .err => return error.TestUnexpectedResult,
    };
    const h = switch (try translate(arena, a, .{ .unicode = true })) {
        .ok => |x| x,
        .err => |e| return @tagName(e.kind),
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    try hir.dump(h, &out.writer);
    return out.written();
}

test "translate: (?i) literal -> class" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("cls[4B 6B 212A]", try translateStr(arena, "(?i)k"));
    try std.testing.expectEqualStrings("lit(\"1\")", try translateStr(arena, "(?i)1"));
    try std.testing.expectEqualStrings("cat(cls[41 61] lit(\"b\"))", try translateStr(arena, "(?i:a)b"));
    try std.testing.expectEqualStrings("bytes[41 61]", try translateStr(arena, "(?i-u)a"));
    // Flags persist into later branches of the same group.
    try std.testing.expectEqualStrings("alt(lit(\"a\")|cls[42 62])", try translateStr(arena, "a|(?i)b"));
}

test "translate: x{0} / x{1} simplifications and literal coalescing" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("lit(\"ac\")", try translateStr(arena, "ab{0}c"));
    try std.testing.expectEqualStrings("lit(\"abc\")", try translateStr(arena, "ab{1}c"));
    try std.testing.expectEqualStrings("lit(\"abc\")", try translateStr(arena, "a(?:b)c"));
    try std.testing.expectEqualStrings("cat(lit(\"a\") cap1(lit(\"b\")) lit(\"c\"))", try translateStr(arena, "a(b)c"));
    try std.testing.expectEqualStrings("lit(\"a\")", try translateStr(arena, "[a]"));
    try std.testing.expectEqualStrings("rep(lit(\"a\")){0,}?", try translateStr(arena, "(?U)a*"));
}

test "translate: classes, dot, looks and errors" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("cls[0-9 B-D7FF E000-10FFFF]", (try translateStr(arena, ".")));
    try std.testing.expectEqualStrings("cls[0-9 B-C E-D7FF E000-10FFFF]", (try translateStr(arena, "(?R).")));
    try std.testing.expectEqualStrings("cls[0-D7FF E000-10FFFF]", (try translateStr(arena, "(?s).")));
    try std.testing.expectEqualStrings("bytes[0-9 B-FF]", (try translateStr(arena, "(?-u).")));
    try std.testing.expectEqualStrings("cls[62-64 66-68 6A-6E 70-74 76-7A]", (try translateStr(arena, "[a-z--[aeiou]]")));
    try std.testing.expectEqualStrings("cls[0-60 7B-D7FF E000-10FFFF]", (try translateStr(arena, "[^a-z]")));
    try std.testing.expectEqualStrings("cls[]", (try translateStr(arena, "[a&&b]")));
    try std.testing.expectEqualStrings("look(start_text)", (try translateStr(arena, "^")));
    try std.testing.expectEqualStrings("look(start_line)", (try translateStr(arena, "(?m)^")));
    try std.testing.expectEqualStrings("look(end_line_crlf)", (try translateStr(arena, "(?mR)$")));
    try std.testing.expectEqualStrings("look(word_ascii)", (try translateStr(arena, "(?-u)\\b")));
    try std.testing.expectEqualStrings("bytes[30-39]", (try translateStr(arena, "(?-u)\\d")));
    try std.testing.expectEqualStrings("lit(\"\\xff\")", (try translateStr(arena, "(?-u)\\xFF")));
    try std.testing.expectEqualStrings("lit(\"\\xc3\\xbf\")", (try translateStr(arena, "\\xFF")));
    try std.testing.expectEqualStrings("unicode_property_unknown", (try translateStr(arena, "\\p{Nope}")));
    try std.testing.expectEqualStrings("unicode_not_allowed", (try translateStr(arena, "(?-u)\\pL")));
    try std.testing.expect(std.mem.startsWith(u8, try translateStr(arena, "\\w"), "cls[30-39 41-5A 5F 61-7A"));
    // (?i) on a class takes the fold closure: KELVIN SIGN joins [k].
    try std.testing.expectEqualStrings("cls[4B 6B 212A]", (try translateStr(arena, "(?i)[k]")));
    try std.testing.expectEqualStrings("cls[0-4A 4C-6A 6C-2129 212B-D7FF E000-10FFFF]", (try translateStr(arena, "(?i)[^k]")));
}
