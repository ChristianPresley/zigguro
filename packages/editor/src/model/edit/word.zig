//! Word classes for cursor movement: UAX #29 properties tailored for
//! code (UAX #29 §4.2.4). Identifier characters (letters, marks, digits,
//! connector punctuation and a language's extra word characters) form
//! words; runs of punctuation form one word so `->` or `+=` is one stop;
//! CJK and emoji runs are their own class. Subword boundaries split
//! identifiers at case changes, letter/digit changes and `_`/`-`.

const std = @import("std");
const zg_text = @import("zg_text");
const tailoring = @import("word_tailoring.zig");

const u = zg_text.unicode;

/// What a code point is for word movement.
pub const WordClass = enum { space, newline, ident, punct, other };

/// The class of `cp`; `lang_word_chars` are extra identifier characters
/// (`$` in JS, `-` in CSS).
pub fn classify(cp: u21, lang_word_chars: []const u21) WordClass {
    if (cp == '\n' or cp == '\r') return .newline;
    for (lang_word_chars) |c| if (c == cp) return .ident;
    if (cp < 0x80) return tailoring.ascii[cp];
    if (cp == 0xfffd) return .other;
    if (u.aux(cp).white_space) return .space;
    const p = u.props(cp);
    if (p.ext_pict) return .other;
    if (tailoring.isCjkScript(p.script)) return .other;
    return switch (p.gc) {
        .Lu, .Ll, .Lt, .Lm, .Lo, .Mn, .Mc, .Me, .Nd, .Nl, .No, .Pc => .ident,
        .Pd, .Ps, .Pe, .Pi, .Pf, .Po, .Sm, .Sc, .Sk, .So => .punct,
        .Zs, .Zl, .Zp => .space,
        else => .other,
    };
}

/// `_` and `-` end a subword and are skipped between subwords.
pub fn isSubwordSeparator(cp: u21) bool {
    return cp == '_' or cp == '-';
}

const Case = enum { upper, lower, digit, other };

fn caseOf(cp: u21) Case {
    if (cp < 0x80) {
        if (cp >= 'A' and cp <= 'Z') return .upper;
        if (cp >= 'a' and cp <= 'z') return .lower;
        if (cp >= '0' and cp <= '9') return .digit;
        return .other;
    }
    return switch (u.props(cp).gc) {
        .Lu, .Lt => .upper,
        .Ll => .lower,
        .Nd, .Nl, .No => .digit,
        else => .other,
    };
}

/// Whether a subword boundary falls between identifier characters `a`
/// and `b`, with `c` the character after `b` (0 if none): lower→Upper
/// (`fooBar`), Upper→Upper-lower (`HTTP|Server`), letter↔digit.
pub fn subwordBoundary(a: u21, b: u21, c: u21) bool {
    const ca = caseOf(a);
    const cb = caseOf(b);
    if (ca == .lower and cb == .upper) return true;
    if (ca == .upper and cb == .upper and c != 0 and caseOf(c) == .lower) return true;
    if ((ca == .digit) != (cb == .digit) and ca != .other and cb != .other) return true;
    return false;
}
