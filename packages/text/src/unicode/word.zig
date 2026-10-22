//! UAX #29 word boundaries (WB1-WB999, Unicode 18.0.0) over UTF-8, with
//! random-access boundary tests for double-click selection and word-wise
//! cursor motion. Ill-formed bytes decode to U+FFFD (WB=Other). No
//! allocation.

const std = @import("std");
const p = @import("props.zig");
const decode = @import("decode.zig");
const WB = p.WordBreak;

/// A word segment and its kind.
pub const WordSpan = struct {
    start: usize,
    len: usize,
    kind: Kind,

    /// What a segment holds, from its first non-ignorable code point.
    pub const Kind = enum { word, number, space, punct, other };
};

const C = struct {
    wb: WB,
    ext_pict: bool,
    fn of(bytes: []const u8, i: usize) C {
        const u = decode.at(bytes, i);
        if (!u.valid) return .{ .wb = .XX, .ext_pict = false };
        const x = p.props(u.cp);
        return .{ .wb = x.wb, .ext_pict = x.ext_pict };
    }
};

inline fn ignorable(w: WB) bool {
    return w == .Extend or w == .FO or w == .ZWJ;
}

inline fn newline(w: WB) bool {
    return w == .NL or w == .CR or w == .LF;
}

inline fn ahLetter(w: WB) bool {
    return w == .LE or w == .HL;
}

inline fn midNumLetQ(w: WB) bool {
    return w == .MB or w == .SQ;
}

/// The effective previous class at `pos` under WB4: skip Extend/Format/ZWJ
/// back to the character they attach to. Returns that character's start,
/// or null at the start of text. A run of ignorables directly after a
/// newline (or at the start) stands for itself.
fn effPrev(bytes: []const u8, pos: usize) ?usize {
    if (pos == 0) return null;
    var q = decode.prevStart(bytes, pos);
    const first = q;
    while (true) {
        const c = C.of(bytes, q);
        if (!ignorable(c.wb)) return if (newline(c.wb)) first else q;
        if (q == 0) return first;
        q = decode.prevStart(bytes, q);
    }
}

/// The next non-ignorable character at or after `pos`, skipping WB4
/// ignorables, or null at the end.
fn effNext(bytes: []const u8, pos: usize) ?usize {
    var q = pos;
    while (q < bytes.len) {
        const c = C.of(bytes, q);
        if (!ignorable(c.wb)) return q;
        q += decode.at(bytes, q).len;
    }
    return null;
}

fn classAt(bytes: []const u8, pos: ?usize) WB {
    return if (pos) |q| C.of(bytes, q).wb else .XX;
}

/// True if there is a word boundary at byte `pos` (a code point start).
/// The start and end of text are boundaries.
pub fn isBoundary(bytes: []const u8, pos: usize) bool {
    if (pos == 0 or pos >= bytes.len) return true; // WB1, WB2
    const a_pos = decode.prevStart(bytes, pos);
    const a = C.of(bytes, a_pos);
    const b = C.of(bytes, pos);
    if (a.wb == .CR and b.wb == .LF) return false; // WB3
    if (newline(a.wb) or newline(b.wb)) return true; // WB3a, WB3b
    if (a.wb == .ZWJ and b.ext_pict) return false; // WB3c
    if (a.wb == .WSegSpace and b.wb == .WSegSpace) return false; // WB3d
    if (ignorable(b.wb)) return false; // WB4
    const l_pos = effPrev(bytes, pos);
    const l = classAt(bytes, l_pos);
    const r = b.wb;
    if (ahLetter(l) and ahLetter(r)) return false; // WB5
    if (ahLetter(l) and (r == .ML or midNumLetQ(r))) { // WB6
        const rr = classAt(bytes, effNext(bytes, pos + decode.at(bytes, pos).len));
        if (ahLetter(rr)) return false;
    }
    const ll = if (l_pos) |q| classAt(bytes, effPrev(bytes, q)) else WB.XX;
    if ((l == .ML or midNumLetQ(l)) and ahLetter(r) and ahLetter(ll)) return false; // WB7
    if (l == .HL and r == .SQ) return false; // WB7a
    if (l == .HL and r == .DQ) { // WB7b
        const rr = classAt(bytes, effNext(bytes, pos + decode.at(bytes, pos).len));
        if (rr == .HL) return false;
    }
    if (l == .DQ and r == .HL and ll == .HL) return false; // WB7c
    if (l == .NU and r == .NU) return false; // WB8
    if (ahLetter(l) and r == .NU) return false; // WB9
    if (l == .NU and ahLetter(r)) return false; // WB10
    if (ll == .NU and (l == .MN or midNumLetQ(l)) and r == .NU) return false; // WB11
    if (l == .NU and (r == .MN or midNumLetQ(r))) { // WB12
        const rr = classAt(bytes, effNext(bytes, pos + decode.at(bytes, pos).len));
        if (rr == .NU) return false;
    }
    if (l == .KA and r == .KA) return false; // WB13
    if ((ahLetter(l) or l == .NU or l == .KA or l == .EX) and r == .EX) return false; // WB13a
    if (l == .EX and (ahLetter(r) or r == .NU or r == .KA)) return false; // WB13b
    if (l == .RI and r == .RI) { // WB15, WB16: odd number of RIs before
        var n: usize = 0;
        var q = l_pos;
        while (q) |qq| : (q = effPrev(bytes, qq)) {
            if (C.of(bytes, qq).wb != .RI) break;
            n += 1;
        }
        if (n % 2 == 1) return false;
    }
    return true; // WB999
}

/// Forward scanner: carries the WB4-effective context so each boundary
/// decision costs one decode and one property lookup (plus a lookahead for
/// WB6, WB7b and WB12).
const Scanner = struct {
    bytes: []const u8,
    /// Start of the next code point to decide on.
    pos: usize,
    /// The actual previous code point's class.
    a: WB,
    /// The effective previous (`l`) and the one before it (`ll`).
    l: WB,
    ll: WB,
    /// Whether ignorables attach to `l` (false at sot and after newlines).
    attach: bool,
    /// Consecutive RIs ending at `l`.
    ri: usize,

    /// A scanner positioned at code point start `pos`.
    fn init(bytes: []const u8, pos: usize) Scanner {
        var sc: Scanner = .{ .bytes = bytes, .pos = pos, .a = .XX, .l = .XX, .ll = .XX, .attach = false, .ri = 0 };
        if (pos == 0) return sc;
        sc.a = C.of(bytes, decode.prevStart(bytes, pos)).wb;
        const l_pos = effPrev(bytes, pos);
        sc.l = classAt(bytes, l_pos);
        sc.attach = !ignorable(sc.l) and !newline(sc.l);
        if (l_pos) |q| {
            sc.ll = classAt(bytes, effPrev(bytes, q));
            var n: usize = 0;
            var r: ?usize = q;
            while (r) |rr| : (r = effPrev(bytes, rr)) {
                if (C.of(bytes, rr).wb != .RI) break;
                n += 1;
            }
            sc.ri = n;
        }
        return sc;
    }

    fn lookahead(sc: *const Scanner, after: usize) WB {
        return classAt(sc.bytes, effNext(sc.bytes, after));
    }

    /// Decides the boundary before the code point at `pos` and advances.
    fn step(sc: *Scanner) bool {
        var b: C = undefined;
        var after: usize = undefined;
        const c0 = sc.bytes[sc.pos];
        if (c0 < 0x80) {
            b = .{ .wb = p.props(c0).wb, .ext_pict = false };
            after = sc.pos + 1;
        } else {
            const u = decode.at(sc.bytes, sc.pos);
            b = if (!u.valid) .{ .wb = .XX, .ext_pict = false } else blk: {
                const x = p.props(u.cp);
                break :blk .{ .wb = x.wb, .ext_pict = x.ext_pict };
            };
            after = sc.pos + u.len;
        }
        const brk = sc.decide(b, after);
        // Advance the context.
        if (ignorable(b.wb)) {
            if (!sc.attach) {
                sc.ll = sc.l;
                sc.l = b.wb;
                sc.ri = 0;
            }
        } else {
            sc.ri = if (b.wb == .RI) (if (sc.l == .RI) sc.ri + 1 else 1) else 0;
            sc.ll = sc.l;
            sc.l = b.wb;
            sc.attach = !newline(b.wb);
        }
        sc.a = b.wb;
        sc.pos = after;
        return brk;
    }

    fn decide(sc: *const Scanner, b: C, after: usize) bool {
        if (sc.pos == 0) return true;
        const a = sc.a;
        const r = b.wb;
        if (a == .CR and r == .LF) return false;
        if (newline(a) or newline(r)) return true;
        if (a == .ZWJ and b.ext_pict) return false;
        if (a == .WSegSpace and r == .WSegSpace) return false;
        if (ignorable(r)) return false;
        const l = sc.l;
        const ll = sc.ll;
        if (ahLetter(l) and ahLetter(r)) return false;
        if (ahLetter(l) and (r == .ML or midNumLetQ(r)) and ahLetter(sc.lookahead(after))) return false;
        if ((l == .ML or midNumLetQ(l)) and ahLetter(r) and ahLetter(ll)) return false;
        if (l == .HL and r == .SQ) return false;
        if (l == .HL and r == .DQ and sc.lookahead(after) == .HL) return false;
        if (l == .DQ and r == .HL and ll == .HL) return false;
        if (l == .NU and r == .NU) return false;
        if (ahLetter(l) and r == .NU) return false;
        if (l == .NU and ahLetter(r)) return false;
        if (ll == .NU and (l == .MN or midNumLetQ(l)) and r == .NU) return false;
        if (l == .NU and (r == .MN or midNumLetQ(r)) and sc.lookahead(after) == .NU) return false;
        if (l == .KA and r == .KA) return false;
        if ((ahLetter(l) or l == .NU or l == .KA or l == .EX) and r == .EX) return false;
        if (l == .EX and (ahLetter(r) or r == .NU or r == .KA)) return false;
        if (l == .RI and r == .RI and sc.ri % 2 == 1) return false;
        return true;
    }
};

/// The first word boundary after `offset`, or `bytes.len`.
pub fn nextBoundary(bytes: []const u8, offset: usize) usize {
    const i = decode.snap(bytes, offset);
    if (i >= bytes.len) return bytes.len;
    var sc = Scanner.init(bytes, i);
    _ = sc.step();
    while (sc.pos < bytes.len) {
        const at = sc.pos;
        if (sc.step()) return at;
    }
    return bytes.len;
}

/// The last word boundary before `offset` (0 when none).
pub fn prevBoundary(bytes: []const u8, offset: usize) usize {
    var i = decode.snap(bytes, @min(offset, bytes.len));
    while (i > 0) {
        i = decode.prevStart(bytes, i);
        if (isBoundary(bytes, i)) return i;
    }
    return 0;
}

fn kindOf(bytes: []const u8, start: usize, end: usize) WordSpan.Kind {
    var i = start;
    while (i < end) : (i += decode.at(bytes, i).len) {
        const u = decode.at(bytes, i);
        const x = p.props(u.cp);
        if (ignorable(x.wb) and i + u.len < end) continue;
        if (!u.valid) return .other;
        return switch (x.wb) {
            .LE, .HL, .KA, .EX => .word,
            .NU => .number,
            .WSegSpace, .NL, .CR, .LF => .space,
            else => switch (x.gc) {
                .Lu, .Ll, .Lt, .Lm, .Lo, .Mn, .Mc => .word,
                .Nd, .Nl, .No => .number,
                .Zs => .space,
                .Pc, .Pd, .Ps, .Pe, .Pi, .Pf, .Po => .punct,
                else => if (p.aux(u.cp).white_space) .space else .other,
            },
        };
    }
    return .other;
}

/// Iterates word segments.
pub const WordIterator = struct {
    bytes: []const u8,
    pos: usize = 0,
    sc: Scanner,

    /// Iterates `bytes` from the start.
    pub fn init(bytes: []const u8) WordIterator {
        return .{ .bytes = bytes, .sc = .init(bytes, 0) };
    }

    /// The next segment, or null at the end.
    pub fn next(it: *WordIterator) ?WordSpan {
        if (it.pos >= it.bytes.len) return null;
        const start = it.pos;
        // The scanner has already consumed the segment's first code point
        // (except at the very start).
        while (it.sc.pos < it.bytes.len) {
            const at = it.sc.pos;
            if (it.sc.step() and at != start) {
                it.pos = at;
                return .{ .start = start, .len = at - start, .kind = kindOf(it.bytes, start, at) };
            }
        }
        it.pos = it.bytes.len;
        return .{ .start = start, .len = it.bytes.len - start, .kind = kindOf(it.bytes, start, it.bytes.len) };
    }
};

/// The segment containing `offset` (double-click selection). At the end of
/// text, the last segment.
pub fn wordAt(bytes: []const u8, offset: usize) WordSpan {
    if (bytes.len == 0) return .{ .start = 0, .len = 0, .kind = .other };
    var o = decode.snap(bytes, @min(offset, bytes.len));
    if (o == bytes.len) o = decode.prevStart(bytes, o);
    const start = if (isBoundary(bytes, o)) o else prevBoundary(bytes, o);
    const end = nextBoundary(bytes, o);
    return .{ .start = start, .len = end - start, .kind = kindOf(bytes, start, end) };
}

fn isWordish(k: WordSpan.Kind) bool {
    return k == .word or k == .number;
}

/// The start of the next word or number segment after `offset`, or
/// `bytes.len` (Ctrl+Right).
pub fn nextWordStart(bytes: []const u8, offset: usize) usize {
    var i = nextBoundary(bytes, offset);
    while (i < bytes.len) {
        const end = nextBoundary(bytes, i);
        if (isWordish(kindOf(bytes, i, end))) return i;
        i = end;
    }
    return bytes.len;
}

/// The start of the word or number segment before `offset`, or 0
/// (Ctrl+Left).
pub fn prevWordStart(bytes: []const u8, offset: usize) usize {
    var end = decode.snap(bytes, @min(offset, bytes.len));
    while (end > 0) {
        const start = prevBoundary(bytes, end);
        if (isWordish(kindOf(bytes, start, end))) return start;
        end = start;
    }
    return 0;
}
