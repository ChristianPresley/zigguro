//! A glob matcher with git's wildmatch semantics (`WM_PATHNAME`, optional
//! `WM_CASEFOLD`), as documented in gitignore(5):
//!
//! - `?` matches one byte other than `/`; `*` a run of bytes other than `/`.
//! - `**` is special only as a whole segment: a leading `**/` matches zero or
//!   more directories, `/**/` zero or more directories in between and a
//!   trailing `/**` everything inside. Any other `**` behaves like `*`.
//! - `[...]` classes with `!`/`^` negation, ranges, `\` escapes and the ASCII
//!   POSIX classes. `/` never matches inside a class.
//! - `\x` matches `x` literally. A trailing lone `\` is an invalid pattern.
//!
//! Patterns are compiled once into a short `Op` program. Most gitignore lines
//! (`foo`, `*.o`, `abc*`, `*abc`, `*abc*`) are classified into a fast-path
//! `Kind` that `match` answers with one comparison. The general matcher is the
//! classic recursive star walk with two abort signals: running out of text
//! aborts every pending star, and a single star that hits `/` aborts back to
//! the nearest `**`. Together they keep `*a*a*a*b`-style patterns linear.
//!
//! Case folding is ASCII-only, as in git: non-ASCII bytes compare exactly.
//! Without `pathname`, `*` and `?` also match `/` (git's plain `wildmatch`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Matching flags. `pathname` is fixed when the pattern is compiled;
/// `casefold` is honoured at match time (either side may set it).
pub const Flags = packed struct(u8) {
    /// `WM_PATHNAME`: wildcards never match `/`.
    pathname: bool = true,
    /// `WM_CASEFOLD`: ASCII case-insensitive comparison.
    casefold: bool = false,
    _: u6 = 0,
};

/// One compiled instruction.
pub const Op = union(enum) {
    /// Bytes that must appear verbatim (escapes already removed).
    lit: []const u8,
    /// `?`.
    any_char,
    /// `*` (or a `**` that is not a whole segment): any run without `/` in
    /// pathname mode, any run at all otherwise.
    star,
    /// A whole-segment `**` at the end of the pattern (pathname mode), or any
    /// star run without pathname mode: any run of bytes.
    star_star,
    /// A whole-segment `**/`: zero or more leading directories. The slash is
    /// part of the op.
    star_star_slash,
    /// `[...]`.
    class: Class,
};

/// A compiled bracket expression.
pub const Class = struct {
    /// `[!...]` or `[^...]`.
    negated: bool,
    /// Single bytes in the class.
    chars: []const u8,
    /// Inclusive byte ranges `a-z`.
    ranges: []const [2]u8,
    /// Bitset of `Posix` classes.
    posix: u16,

    fn matches(c: *const Class, t: u8, fold: bool) bool {
        for (c.chars) |ch| if (ch == t) return true;
        for (c.ranges) |r| {
            if (t >= r[0] and t <= r[1]) return true;
            if (fold and std.ascii.isLower(t)) {
                const up = std.ascii.toUpper(t);
                if (up >= r[0] and up <= r[1]) return true;
            }
        }
        if (c.posix != 0) {
            inline for (std.meta.fields(Posix)) |f| {
                if (c.posix & (@as(u16, 1) << f.value) != 0 and posixMatches(@enumFromInt(f.value), t, fold)) return true;
            }
        }
        return false;
    }
};

/// The ASCII POSIX character classes accepted inside `[...]`.
pub const Posix = enum(u4) { alnum, alpha, blank, cntrl, digit, graph, lower, print, punct, space, upper, xdigit };

fn posixMatches(p: Posix, t: u8, fold: bool) bool {
    if (t >= 0x80) return false;
    return switch (p) {
        .alnum => std.ascii.isAlphanumeric(t),
        .alpha => std.ascii.isAlphabetic(t),
        .blank => t == ' ' or t == '\t',
        .cntrl => std.ascii.isControl(t),
        .digit => std.ascii.isDigit(t),
        .graph => std.ascii.isPrint(t) and t != ' ',
        .lower => std.ascii.isLower(t),
        .print => std.ascii.isPrint(t),
        .punct => std.ascii.isPrint(t) and t != ' ' and !std.ascii.isAlphanumeric(t),
        .space => std.ascii.isWhitespace(t),
        .upper => std.ascii.isUpper(t) or (fold and std.ascii.isLower(t)),
        .xdigit => std.ascii.isHex(t),
    };
}

/// A compiled pattern.
pub const Pattern = struct {
    /// Fast-path classification.
    kind: Kind,
    /// The compiled program (used for `.general`).
    ops: []const Op,
    /// The literal for `.literal`, `.extension`, `.prefix`, `.suffix` and
    /// `.contains`.
    literal: []const u8,
    /// Whether the pattern was compiled in pathname mode.
    pathname: bool,

    /// Fast-path classification.
    pub const Kind = enum {
        /// `foo`: the whole text equals the literal.
        literal,
        /// `*.ext`: a suffix starting with `.`, no `/` in the text.
        extension,
        /// `abc*`: a prefix, no `/` after it.
        prefix,
        /// `*abc`: a suffix, no `/` in the text.
        suffix,
        /// `*abc*`: an infix, no `/` in the text.
        contains,
        /// Anything else: run `ops`.
        general,
        /// Matches nothing (an unterminated `[` or an unknown `[:class:]`;
        /// git aborts the match in both cases).
        never,
    };
};

/// Compiles `pattern`. All memory comes from `arena`; `pattern` itself is not
/// retained. Fails with `InvalidPattern` on a trailing lone backslash.
pub fn compile(arena: Allocator, pattern: []const u8, flags: Flags) error{ OutOfMemory, InvalidPattern }!Pattern {
    var ops: std.ArrayList(Op) = .empty;
    var lit: std.ArrayList(u8) = .empty;
    var never = false;
    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];
        switch (c) {
            '\\' => {
                if (i + 1 >= pattern.len) return error.InvalidPattern;
                try lit.append(arena, pattern[i + 1]);
                i += 2;
            },
            '?' => {
                try flushLit(arena, &ops, &lit);
                try ops.append(arena, .any_char);
                i += 1;
            },
            '*' => {
                try flushLit(arena, &ops, &lit);
                const start = i;
                while (i < pattern.len and pattern[i] == '*') i += 1;
                const run = i - start;
                if (!flags.pathname) {
                    try ops.append(arena, .star_star);
                } else if (run >= 2 and (start == 0 or pattern[start - 1] == '/')) {
                    if (i == pattern.len) {
                        try ops.append(arena, .star_star);
                    } else if (pattern[i] == '/') {
                        try ops.append(arena, .star_star_slash);
                        i += 1;
                    } else if (pattern[i] == '\\' and i + 1 < pattern.len and pattern[i + 1] == '/') {
                        try ops.append(arena, .star_star_slash);
                        i += 2;
                    } else {
                        try ops.append(arena, .star);
                    }
                } else {
                    try ops.append(arena, .star);
                }
            },
            '[' => {
                try flushLit(arena, &ops, &lit);
                const r = try compileClass(arena, pattern, i);
                switch (r) {
                    .never => {
                        never = true;
                        break;
                    },
                    .class => |cl| {
                        try ops.append(arena, .{ .class = cl.class });
                        i = cl.end;
                    },
                }
            },
            else => {
                try lit.append(arena, c);
                i += 1;
            },
        }
    }
    try flushLit(arena, &ops, &lit);
    if (never) return .{ .kind = .never, .ops = &.{}, .literal = "", .pathname = flags.pathname };
    return classify(ops.items, flags.pathname);
}

fn flushLit(arena: Allocator, ops: *std.ArrayList(Op), lit: *std.ArrayList(u8)) !void {
    if (lit.items.len == 0) return;
    try ops.append(arena, .{ .lit = try lit.toOwnedSlice(arena) });
}

const ClassResult = union(enum) { never, class: struct { class: Class, end: usize } };

/// Parses the bracket expression starting at `pattern[open] == '['` the way
/// git's `dowild` walks it: the first byte after `[`/`[!` is always a member,
/// `a-b` is a range unless `-` is first or last, `[:name:]` is a POSIX class,
/// and `[:` without a closing `:]` is a literal `[`.
fn compileClass(arena: Allocator, pattern: []const u8, open: usize) !ClassResult {
    var chars: std.ArrayList(u8) = .empty;
    var ranges: std.ArrayList([2]u8) = .empty;
    var posix: u16 = 0;
    var p = open + 1;
    if (p >= pattern.len) return .never;
    var negated = false;
    if (pattern[p] == '!' or pattern[p] == '^') {
        negated = true;
        p += 1;
    }
    var prev: ?u8 = null;
    var first = true;
    while (true) {
        if (p >= pattern.len) return .never;
        var ch = pattern[p];
        if (ch == ']' and !first) break;
        first = false;
        if (ch == '\\') {
            p += 1;
            if (p >= pattern.len) return .never;
            ch = pattern[p];
            try chars.append(arena, ch);
            prev = ch;
        } else if (ch == '-' and prev != null and p + 1 < pattern.len and pattern[p + 1] != ']') {
            p += 1;
            var hi = pattern[p];
            if (hi == '\\') {
                p += 1;
                if (p >= pattern.len) return .never;
                hi = pattern[p];
            }
            try ranges.append(arena, .{ prev.?, hi });
            prev = null;
        } else if (ch == '[' and p + 1 < pattern.len and pattern[p + 1] == ':') {
            const s = p + 2;
            var e = s;
            while (e < pattern.len and pattern[e] != ']') e += 1;
            if (e >= pattern.len) return .never;
            if (e < s + 1 or pattern[e - 1] != ':') {
                // No ":]": a literal '[', then keep scanning after it.
                try chars.append(arena, '[');
                prev = '[';
            } else {
                const name = pattern[s .. e - 1];
                const which = std.meta.stringToEnum(Posix, name) orelse return .never;
                posix |= @as(u16, 1) << @intFromEnum(which);
                p = e;
                prev = null;
            }
        } else {
            try chars.append(arena, ch);
            prev = ch;
        }
        p += 1;
    }
    return .{ .class = .{
        .class = .{ .negated = negated, .chars = chars.items, .ranges = ranges.items, .posix = posix },
        .end = p + 1,
    } };
}

fn classify(ops: []const Op, pathname: bool) Pattern {
    var pat: Pattern = .{ .kind = .general, .ops = ops, .literal = "", .pathname = pathname };
    if (!pathname) {
        if (ops.len == 0) {
            pat.kind = .literal;
        } else if (ops.len == 1 and ops[0] == .lit) {
            pat.kind = .literal;
            pat.literal = ops[0].lit;
        }
        return pat;
    }
    const noSlash = struct {
        fn f(s: []const u8) bool {
            return std.mem.indexOfScalar(u8, s, '/') == null;
        }
    }.f;
    switch (ops.len) {
        0 => pat.kind = .literal,
        1 => if (ops[0] == .lit) {
            pat.kind = .literal;
            pat.literal = ops[0].lit;
        },
        2 => if (ops[0] == .star and ops[1] == .lit and noSlash(ops[1].lit)) {
            const l = ops[1].lit;
            pat.kind = if (l.len > 1 and l[0] == '.' and std.mem.indexOfScalar(u8, l[1..], '.') == null) .extension else .suffix;
            pat.literal = l;
        } else if (ops[0] == .lit and ops[1] == .star and noSlash(ops[0].lit)) {
            pat.kind = .prefix;
            pat.literal = ops[0].lit;
        },
        3 => if (ops[0] == .star and ops[1] == .lit and ops[2] == .star and noSlash(ops[1].lit)) {
            pat.kind = .contains;
            pat.literal = ops[1].lit;
        },
        else => {},
    }
    return pat;
}

/// Reports whether `text` matches `p`. `flags.pathname` is ignored (the mode
/// is fixed by `compile`); `flags.casefold` enables ASCII case folding.
pub fn match(p: *const Pattern, text: []const u8, flags: Flags) bool {
    const fold = flags.casefold;
    const slash_ok = !p.pathname;
    switch (p.kind) {
        .never => return false,
        .literal => return eql(text, p.literal, fold),
        .extension, .suffix => {
            if (text.len < p.literal.len) return false;
            if (!slash_ok and std.mem.indexOfScalar(u8, text, '/') != null) return false;
            return eql(text[text.len - p.literal.len ..], p.literal, fold);
        },
        .prefix => {
            if (text.len < p.literal.len) return false;
            if (!eql(text[0..p.literal.len], p.literal, fold)) return false;
            return slash_ok or std.mem.indexOfScalar(u8, text[p.literal.len..], '/') == null;
        },
        .contains => {
            if (!slash_ok and std.mem.indexOfScalar(u8, text, '/') != null) return false;
            return if (fold) std.ascii.indexOfIgnoreCase(text, p.literal) != null else std.mem.indexOf(u8, text, p.literal) != null;
        },
        .general => return walk(p.ops, text, 0, fold, p.pathname) == .match,
    }
}

fn eql(a: []const u8, b: []const u8, fold: bool) bool {
    return if (fold) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

inline fn lower(c: u8, fold: bool) u8 {
    return if (fold) std.ascii.toLower(c) else c;
}

const Outcome = enum { match, no_match, abort_all, abort_to_star_star };

/// Matches `ops` against `text[ti..]`.
fn walk(ops: []const Op, text: []const u8, start: usize, fold: bool, pathname: bool) Outcome {
    var ti = start;
    for (ops, 0..) |op, oi| {
        switch (op) {
            .lit => |l| {
                for (l) |pc| {
                    if (ti >= text.len) return .abort_all;
                    if (lower(text[ti], fold) != lower(pc, fold)) return .no_match;
                    ti += 1;
                }
            },
            .any_char => {
                if (ti >= text.len) return .abort_all;
                if (pathname and text[ti] == '/') return .no_match;
                ti += 1;
            },
            .class => |*c| {
                if (ti >= text.len) return .abort_all;
                const t = lower(text[ti], fold);
                if (c.matches(t, fold) == c.negated) return .no_match;
                if (pathname and t == '/') return .no_match;
                ti += 1;
            },
            .star, .star_star => {
                const any = op == .star_star or !pathname;
                const rest = ops[oi + 1 ..];
                if (rest.len == 0) {
                    if (!any and std.mem.indexOfScalarPos(u8, text, ti, '/') != null) return .abort_to_star_star;
                    return .match;
                }
                if (!any and rest[0] == .lit and rest[0].lit[0] == '/') {
                    // One star before a slash matches exactly the next segment.
                    ti = std.mem.indexOfScalarPos(u8, text, ti, '/') orelse return .abort_all;
                    return walk(rest, text, ti, fold, pathname);
                }
                return starLoop(rest, text, ti, fold, pathname, any);
            },
            .star_star_slash => {
                const rest = ops[oi + 1 ..];
                if (walk(rest, text, ti, fold, pathname) == .match) return .match;
                // Otherwise `**` swallows one or more segments ending in '/'.
                var j = ti;
                while (std.mem.indexOfScalarPos(u8, text, j, '/')) |slash| {
                    const r = walk(rest, text, slash + 1, fold, pathname);
                    if (r != .no_match and r != .abort_to_star_star) return r;
                    j = slash + 1;
                }
                return .abort_all;
            },
        }
    }
    return if (ti == text.len) .match else .no_match;
}

fn starLoop(rest: []const Op, text: []const u8, start: usize, fold: bool, pathname: bool, any: bool) Outcome {
    var j = start;
    while (j < text.len) {
        if (rest[0] == .lit) {
            // Skip straight to the next occurrence of the literal's first byte.
            const pc = lower(rest[0].lit[0], fold);
            while (j < text.len and (any or text[j] != '/') and lower(text[j], fold) != pc) j += 1;
            if (j >= text.len or lower(text[j], fold) != pc) return if (any) .abort_all else .abort_to_star_star;
        }
        const r = walk(rest, text, j, fold, pathname);
        if (r != .no_match) {
            if (!any or r != .abort_to_star_star) return r;
        } else if (!any and text[j] == '/') {
            return .abort_to_star_star;
        }
        j += 1;
    }
    return .abort_all;
}
