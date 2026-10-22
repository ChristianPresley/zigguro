//! A small backtracking regex matcher used by schema `pattern`s and
//! when-clause `=~` until `zg_regex` (E05.F03) is available. Supported:
//! literals, `.`, `[...]`/`[^...]` classes with ranges, `\d \w \s \D \W \S`
//! and escaped metacharacters, `* + ?` (greedy), `^ $`, `|` alternation and
//! non-capturing `( )` groups. Not supported (rejected by `compile`):
//! `{m,n}`, lookaround and backreferences. Case-insensitive matching is a flag.
//!
//! Patterns are validated by `compile`; matching interprets the pattern text
//! directly, bounded by a step budget so hostile input cannot hang the UI.

const std = @import("std");

/// A validated pattern.
pub const Regex = struct {
    src: []const u8,
    ignore_case: bool = false,

    /// Validates `src`. Returns the error position on failure.
    pub fn compile(src: []const u8, ignore_case: bool) error{Invalid}!Regex {
        var depth: u32 = 0;
        var i: usize = 0;
        var prev_atom = false;
        while (i < src.len) : (i += 1) {
            switch (src[i]) {
                '\\' => {
                    if (i + 1 >= src.len) return error.Invalid;
                    i += 1;
                    prev_atom = true;
                },
                '[' => {
                    i += 1;
                    if (i < src.len and src[i] == '^') i += 1;
                    if (i < src.len and src[i] == ']') i += 1;
                    while (i < src.len and src[i] != ']') : (i += 1) {
                        if (src[i] == '\\') i += 1;
                    }
                    if (i >= src.len) return error.Invalid;
                    prev_atom = true;
                },
                '(' => {
                    depth += 1;
                    prev_atom = false;
                },
                ')' => {
                    if (depth == 0) return error.Invalid;
                    depth -= 1;
                    prev_atom = true;
                },
                '*', '+', '?' => {
                    if (!prev_atom) return error.Invalid;
                    prev_atom = false;
                },
                '{' => return error.Invalid,
                '|' => prev_atom = false,
                '^', '$' => prev_atom = false,
                else => prev_atom = true,
            }
        }
        if (depth != 0) return error.Invalid;
        return .{ .src = src, .ignore_case = ignore_case };
    }

    /// Whether the pattern matches anywhere in `text` (search semantics).
    pub fn isMatch(re: Regex, text: []const u8) bool {
        var m: Matcher = .{ .re = re.src, .text = text, .ic = re.ignore_case };
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            if (m.alt(0, re.src.len, start, &.{}) != null) return true;
            if (m.budget == 0) return false;
        }
        return false;
    }
};

/// What to match after the current sub-pattern.
const Cont = struct {
    /// Match re[lo..hi], then `next`.
    lo: usize,
    hi: usize,
    next: []const Cont,
    /// When set, this continuation is "repeat the group re[lo..hi] (its
    /// inner text) zero or more times, then match re[rest..rest_hi]"; the
    /// iteration that led here started at `from`.
    star: ?struct { rest: usize, rest_hi: usize, from: usize } = null,
};

/// Position marker for the first entry into a `(x)*` loop.
const star_entry = std.math.maxInt(usize);

const Matcher = struct {
    re: []const u8,
    text: []const u8,
    ic: bool,
    budget: u32 = 100_000,

    /// Matches alternatives of re[lo..hi] at `pos`, then the continuation.
    fn alt(m: *Matcher, lo: usize, hi: usize, pos: usize, k: []const Cont) ?usize {
        var start = lo;
        var depth: u32 = 0;
        var i = lo;
        while (i < hi) : (i += 1) {
            switch (m.re[i]) {
                '\\' => i += 1,
                '[' => i = classEnd(m.re, i),
                '(' => depth += 1,
                ')' => depth -= 1,
                '|' => if (depth == 0) {
                    if (m.seq(start, i, pos, k)) |e| return e;
                    start = i + 1;
                },
                else => {},
            }
        }
        return m.seq(start, hi, pos, k);
    }

    fn seq(m: *Matcher, lo: usize, hi: usize, pos: usize, k: []const Cont) ?usize {
        if (m.budget == 0) return null;
        m.budget -= 1;
        if (lo >= hi) {
            if (k.len == 0) return pos;
            return m.runCont(k[0], pos);
        }
        const c = m.re[lo];
        if (c == '^') return if (pos == 0) m.seq(lo + 1, hi, pos, k) else null;
        if (c == '$') return if (pos == m.text.len) m.seq(lo + 1, hi, pos, k) else null;
        // The atom re[lo..ae].
        const ae: usize = switch (c) {
            '\\' => lo + 2,
            '[' => classEnd(m.re, lo) + 1,
            '(' => groupEnd(m.re, lo) + 1,
            else => lo + 1,
        };
        const q: u8 = if (ae < hi) m.re[ae] else 0;
        const rest = if (q == '*' or q == '+' or q == '?') ae + 1 else ae;
        if (c == '(') {
            const inner_lo = lo + 1;
            const inner_hi = ae - 1;
            const after = [_]Cont{.{ .lo = rest, .hi = hi, .next = k }};
            const star = [_]Cont{.{ .lo = inner_lo, .hi = inner_hi, .next = k, .star = .{ .rest = rest, .rest_hi = hi, .from = pos } }};
            switch (q) {
                '?' => return m.alt(inner_lo, inner_hi, pos, &after) orelse m.seq(rest, hi, pos, k),
                // `(x)*`: zero or more iterations, greedy.
                '*' => return m.runCont(star[0], star_entry) orelse m.seq(rest, hi, pos, k),
                // `(x)+` == `(x)(x)*`.
                '+' => return m.alt(inner_lo, inner_hi, pos, &star),
                else => return m.alt(inner_lo, inner_hi, pos, &after),
            }
        }
        switch (q) {
            '*', '+' => {
                var n: usize = 0;
                var p = pos;
                while (p < m.text.len and m.atom(lo, p)) : (p += 1) n += 1;
                const min: usize = if (q == '+') 1 else 0;
                while (true) {
                    if (n < min) return null;
                    if (m.seq(rest, hi, pos + n, k)) |e| return e;
                    if (n == 0) return null;
                    n -= 1;
                }
            },
            '?' => {
                if (pos < m.text.len and m.atom(lo, pos)) {
                    if (m.seq(rest, hi, pos + 1, k)) |e| return e;
                }
                return m.seq(rest, hi, pos, k);
            },
            else => {
                if (pos < m.text.len and m.atom(lo, pos)) return m.seq(rest, hi, pos + 1, k);
                return null;
            },
        }
    }

    /// Runs continuation `c` at `pos`.
    fn runCont(m: *Matcher, c: Cont, pos: usize) ?usize {
        const st = c.star orelse return m.alt(c.lo, c.hi, pos, c.next);
        // Star continuation. `pos == star_entry` is the initial entry of `(x)*`.
        const at = if (pos == star_entry) st.from else pos;
        const progressed = pos == star_entry or at != st.from;
        if (progressed) {
            const again = [_]Cont{.{ .lo = c.lo, .hi = c.hi, .next = c.next, .star = .{ .rest = st.rest, .rest_hi = st.rest_hi, .from = at } }};
            if (m.alt(c.lo, c.hi, at, &again)) |e| return e;
        }
        return m.seq(st.rest, st.rest_hi, at, c.next);
    }

    fn eqc(m: *Matcher, a: u8, b: u8) bool {
        return if (m.ic) std.ascii.toLower(a) == std.ascii.toLower(b) else a == b;
    }

    /// Whether the single-char atom at re[lo] matches text[pos].
    fn atom(m: *Matcher, lo: usize, pos: usize) bool {
        const t = m.text[pos];
        return switch (m.re[lo]) {
            '.' => t != '\n',
            '\\' => escMatch(m.re[lo + 1], t) orelse m.eqc(m.re[lo + 1], t),
            '[' => m.classMatch(lo, t),
            else => m.eqc(m.re[lo], t),
        };
    }

    fn classMatch(m: *Matcher, lo: usize, t: u8) bool {
        var i = lo + 1;
        const neg = m.re[i] == '^';
        if (neg) i += 1;
        const end = classEnd(m.re, lo);
        var hit = false;
        var first = true;
        while (i < end) : (first = false) {
            var a = m.re[i];
            if (a == ']' and !first) break;
            if (a == '\\') {
                i += 1;
                if (escMatch(m.re[i], t)) |r| {
                    hit = hit or r;
                    i += 1;
                    continue;
                }
                a = m.re[i];
            }
            if (i + 2 < end and m.re[i + 1] == '-' and m.re[i + 2] != ']') {
                const b = m.re[i + 2];
                const tl = if (m.ic) std.ascii.toLower(t) else t;
                const tu = if (m.ic) std.ascii.toUpper(t) else t;
                hit = hit or (t >= a and t <= b) or (tl >= a and tl <= b) or (tu >= a and tu <= b);
                i += 3;
            } else {
                hit = hit or m.eqc(a, t);
                i += 1;
            }
        }
        return hit != neg;
    }
};

fn escMatch(e: u8, t: u8) ?bool {
    return switch (e) {
        'd' => std.ascii.isDigit(t),
        'D' => !std.ascii.isDigit(t),
        'w' => std.ascii.isAlphanumeric(t) or t == '_',
        'W' => !(std.ascii.isAlphanumeric(t) or t == '_'),
        's' => std.ascii.isWhitespace(t),
        'S' => !std.ascii.isWhitespace(t),
        else => null,
    };
}

/// Index of the `]` closing the class that starts at `lo`.
fn classEnd(re: []const u8, lo: usize) usize {
    var i = lo + 1;
    if (i < re.len and re[i] == '^') i += 1;
    if (i < re.len and re[i] == ']') i += 1;
    while (i < re.len and re[i] != ']') : (i += 1) {
        if (re[i] == '\\') i += 1;
    }
    return i;
}

/// Index of the `)` closing the group that starts at `lo`.
fn groupEnd(re: []const u8, lo: usize) usize {
    var depth: u32 = 0;
    var i = lo;
    while (i < re.len) : (i += 1) switch (re[i]) {
        '\\' => i += 1,
        '[' => i = classEnd(re, i),
        '(' => depth += 1,
        ')' => {
            depth -= 1;
            if (depth == 0) return i;
        },
        else => {},
    };
    return re.len;
}

fn expectMatch(re: []const u8, text: []const u8, want: bool) !void {
    const r = try Regex.compile(re, false);
    if (r.isMatch(text) != want) {
        std.debug.print("regex /{s}/ on '{s}': expected {}\n", .{ re, text, want });
        return error.TestUnexpectedResult;
    }
}

test "regex_lite: basics" {
    try expectMatch("abc", "xxabcxx", true);
    try expectMatch("^abc$", "abc", true);
    try expectMatch("^abc$", "abcd", false);
    try expectMatch("a.c", "abc", true);
    try expectMatch("ab*c", "ac", true);
    try expectMatch("ab+c", "ac", false);
    try expectMatch("ab+c", "abbbc", true);
    try expectMatch("colou?r", "color", true);
    try expectMatch("^[a-z]+\\.zig$", "main.zig", true);
    try expectMatch("^[a-z]+\\.zig$", "Main.zig", false);
    try expectMatch("^[^/]+$", "a/b", false);
    try expectMatch("^\\d+$", "123", true);
    try expectMatch("^(foo|bar)baz$", "barbaz", true);
    try expectMatch("^(foo|bar)baz$", "quxbaz", false);
    try expectMatch("^(ab)*c$", "ababc", true);
    try expectMatch("^(ab)+c$", "c", false);
    try expectMatch("^(ab)+c$", "abc", true);
    try expectMatch("zig|zon", "file.zon", true);
    try expectMatch("^#[0-9a-fA-F]+$", "#ffAA00", true);
    const ic = try Regex.compile("^hello$", true);
    try std.testing.expect(ic.isMatch("HeLLo"));
}

test "regex_lite: invalid patterns" {
    try std.testing.expectError(error.Invalid, Regex.compile("a{2}", false));
    try std.testing.expectError(error.Invalid, Regex.compile("(ab", false));
    try std.testing.expectError(error.Invalid, Regex.compile("*a", false));
    try std.testing.expectError(error.Invalid, Regex.compile("[ab", false));
    try std.testing.expectError(error.Invalid, Regex.compile("ab\\", false));
}

test "fuzz: regex_lite" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) anyerror!void {
            var a: [32]u8 = undefined;
            var b: [64]u8 = undefined;
            const re = a[0..smith.slice(&a)];
            const text = b[0..smith.slice(&b)];
            const r = Regex.compile(re, false) catch return;
            _ = r.isMatch(text);
        }
    }.f, .{});
}
