//! UAX #14 line-break opportunities (Unicode 18.0.0, rules LB1-LB31) over
//! UTF-8, as a forward iterator. The rules are evaluated in order over a
//! small context (previous items, the last non-space item, the numeric
//! run of LB25 and regional-indicator parity) instead of a pair table.
//! An optional code/URL tailoring is kept separate (`Options.code_tailoring`).
//! No allocation.

const std = @import("std");
const p = @import("props.zig");
const decode = @import("decode.zig");
const LB = p.LineBreak;

/// A mandatory break (after BK, CR, LF, NL, and at the end of text) or an
/// opportunity the layout may use.
pub const BreakKind = enum { mandatory, allowed };

/// A break: `offset` is the byte index where the next line may start.
pub const Break = struct { offset: usize, kind: BreakKind };

/// Algorithm options; defaults give UAX #14 default behaviour.
pub const Options = struct {
    /// UAX14-C2 code tailoring (see `tailor`): breaks before `?#&=` inside
    /// URL-like runs and never inside two-character operators.
    code_tailoring: bool = false,
    /// LB1 resolves CJ to NS (strict, the UAX #14 default and what
    /// LineBreakTest.txt expects); true resolves CJ to ID (loose/normal
    /// Japanese line breaking).
    loose_cj: bool = false,
};

/// One character's resolved line-break attributes (LB1 applied).
const Item = packed struct(u32) {
    cls: LB,
    /// The code point; the rare attribute tests below look it up again.
    cp: u21 = 0,
    /// Start of text, used as context only.
    sot: bool = false,
    _pad: u4 = 0,

    const start: Item = .{ .cls = .XX, .sot = true };
    const al: Item = .{ .cls = .AL };

    /// LB1 for each class; SA is resolved separately (it needs gc).
    const strict = resolveTable(false);
    const loose = resolveTable(true);

    fn resolveTable(loose_cj: bool) [64]LB {
        var t: [64]LB = undefined;
        for (&t, 0..) |*e, i| e.* = if (i < @typeInfo(LB).@"enum".fields.len) @enumFromInt(i) else .AL;
        t[@intFromEnum(LB.AI)] = .AL;
        t[@intFromEnum(LB.SG)] = .AL;
        t[@intFromEnum(LB.XX)] = .AL;
        t[@intFromEnum(LB.CJ)] = if (loose_cj) .ID else .NS;
        return t;
    }

    inline fn of(cp: u21, valid: bool, opts: Options) Item {
        if (!valid) return al;
        const x = p.props(cp);
        var cls = (if (opts.loose_cj) loose else strict)[@intFromEnum(x.lb)];
        if (x.lb == .SA) cls = if (x.gc == .Mn or x.gc == .Mc) .CM else .AL;
        return .{ .cls = cls, .cp = cp };
    }

    /// East_Asian_Width F, W or H (LB19, LB30).
    inline fn ea(i: Item) bool {
        if (i.sot) return false;
        const w = p.props(i.cp).eaw;
        return w == .F or w == .W or w == .H;
    }

    /// General_Category Pi / Pf (LB15a, LB15b, LB19).
    inline fn pi(i: Item) bool {
        return !i.sot and p.props(i.cp).gc == .Pi;
    }

    inline fn pf(i: Item) bool {
        return !i.sot and p.props(i.cp).gc == .Pf;
    }

    /// Extended_Pictographic and unassigned (LB30b).
    inline fn epu(i: Item) bool {
        if (i.sot) return false;
        const x = p.props(i.cp);
        return x.ext_pict and x.gc == .Cn;
    }

    /// U+25CC DOTTED CIRCLE (LB28a; its class is AL).
    inline fn dotted(i: Item) bool {
        return i.cls == .AL and i.cp == 0x25CC;
    }

    inline fn is(i: Item, c: LB) bool {
        return !i.sot and i.cls == c;
    }

    /// LB9 bases: characters that combining marks attach to.
    inline fn takesMarks(c: LB) bool {
        return switch (c) {
            .BK, .CR, .LF, .NL, .SP, .ZW => false,
            else => true,
        };
    }

    /// LB28a: AK, DOTTED CIRCLE or AS.
    inline fn aksara(i: Item) bool {
        return i.cls == .AK or i.cls == .AS or i.dotted();
    }

    inline fn alhl(i: Item) bool {
        return i.cls == .AL or i.cls == .HL;
    }

    inline fn hangul(i: Item) bool {
        return switch (i.cls) {
            .JL, .JV, .JT, .H2, .H3 => true,
            else => false,
        };
    }
};

const Decision = enum { none, allowed, mandatory };

/// Per-class flags for the hot path.
const f_special: u8 = 1; // handled by LB4-LB10: mandatory breaks, SP, ZW, marks
const f_alhl: u8 = 2; // AL or HL
const f_id: u8 = 4;
const flags: [64]u8 = blk: {
    var t: [64]u8 = @splat(0);
    for ([_]LB{ .BK, .CR, .LF, .NL, .SP, .ZW, .CM, .ZWJ }) |c| t[@intFromEnum(c)] |= f_special;
    t[@intFromEnum(LB.AL)] |= f_alhl;
    t[@intFromEnum(LB.HL)] |= f_alhl;
    t[@intFromEnum(LB.ID)] |= f_id;
    break :blk t;
};

inline fn flagsOf(c: LB) u8 {
    return flags[@intFromEnum(c)];
}

const Num = enum(u2) { none, nu, closed };

/// LB25 run state after an item of each class, from each state.
const num_next: [3][64]Num = blk: {
    var t: [3][64]Num = @splat(@splat(.none));
    for (&t) |*row| row[@intFromEnum(LB.NU)] = .nu;
    for ([_]LB{ .SY, .IS }) |c| t[@intFromEnum(Num.nu)][@intFromEnum(c)] = .nu;
    for ([_]LB{ .CL, .CP }) |c| t[@intFromEnum(Num.nu)][@intFromEnum(c)] = .closed;
    break :blk t;
};

/// Rule context carried across characters.
const State = struct {
    /// Previous character's class (LB1 only; LB4-LB9 look at these).
    raw: LB = .XX,
    /// LB8: a ZW followed by spaces only.
    zw: bool = false,
    /// The previous item (after LB9/LB10) and the one before it.
    a: Item = .start,
    aa: Item = .start,
    /// The last non-SP item and the item before it (LB14-LB17, LB15a).
    nsp: Item = .start,
    nsp_prev: Item = .start,
    /// LB25: inside `NU (SY|IS)*` (nu), or that followed by CL/CP (closed).
    num: Num = .none,
    /// LB30a: the run of RIs ending at `a` has odd length.
    ri_odd: bool = false,

    /// Folds item `b` into the context.
    fn push(s: *State, b: Item) void {
        s.ri_odd = b.cls == .RI and !(s.a.is(.RI) and s.ri_odd);
        s.num = num_next[@intFromEnum(s.num)][@intFromEnum(b.cls)];
        if (b.cls != .SP) {
            s.nsp_prev = s.a;
            s.nsp = b;
        }
        s.aa = s.a;
        s.a = b;
    }
};

/// Iterates break opportunities. Every opportunity is reported once, in
/// order; the last one is the mandatory break at the end of text.
pub const Iterator = struct {
    bytes: []const u8,
    /// Next character to decide on.
    pos: usize,
    state: State = .{},
    opts: Options,
    done: bool = false,

    /// Iterates `bytes` from the start.
    pub fn init(bytes: []const u8, opts: Options) Iterator {
        return initAt(bytes, 0, opts);
    }

    /// Iterates from code point start `at` as if text started there.
    pub fn initAt(bytes: []const u8, at: usize, opts: Options) Iterator {
        var it: Iterator = .{ .bytes = bytes, .pos = at, .opts = opts, .done = at >= bytes.len };
        if (at < bytes.len) {
            // LB2: no break at the start; the first character only sets
            // the context.
            const u = decode.at(bytes, at);
            const ci = Item.of(u.cp, u.valid, opts);
            it.state.raw = ci.cls;
            it.state.zw = ci.cls == .ZW;
            it.state.push(if (ci.cls == .CM or ci.cls == .ZWJ) Item.al else ci);
            it.pos = at + u.len;
        }
        return it;
    }

    /// The next opportunity, or null after the final one.
    pub fn next(self: *Iterator) ?Break {
        return if (self.opts.code_tailoring) self.nextImpl(true) else self.nextImpl(false);
    }

    inline fn nextImpl(it: *Iterator, comptime tailored: bool) ?Break {
        const bytes = it.bytes;
        while (it.pos < bytes.len) {
            const at = it.pos;
            const c0 = bytes[at];
            var len: usize = 1;
            var ci: Item = undefined;
            if (c0 < 0x80) {
                ci = .{ .cls = p.props(c0).lb, .cp = c0 };
            } else {
                const u = decode.at(bytes, at);
                len = u.len;
                ci = .of(u.cp, u.valid, it.opts);
            }
            it.pos = at + len;
            var d = it.step(ci, it.pos);
            if (tailored) d = tailor(bytes, at, d);
            if (d != .none) {
                return .{ .offset = at, .kind = if (d == .mandatory) .mandatory else .allowed };
            }
        }
        if (it.done) return null;
        it.done = true;
        return .{ .offset = bytes.len, .kind = .mandatory };
    }

    /// Decides the break before the character `ci` (ending at `end`) and
    /// advances the context past it.
    inline fn step(it: *Iterator, ci: Item, end: usize) Decision {
        const s = &it.state;
        const c = ci.cls;
        const raw = s.raw;
        // Common case: neither character takes part in LB4-LB10.
        if ((flagsOf(raw) | flagsOf(c)) & f_special == 0 and !s.zw) {
            s.raw = c;
            const d: Decision = if (it.pairRule(ci, end)) .none else .allowed;
            s.push(ci);
            return d;
        }
        s.raw = c;
        const zw = s.zw;
        s.zw = c == .ZW or (zw and c == .SP);
        // LB4-LB8a, on characters.
        if (raw == .BK) return it.newItem(ci, .mandatory);
        if (raw == .CR and c == .LF) return it.newItem(ci, .none);
        if (raw == .CR or raw == .LF or raw == .NL) return it.newItem(ci, .mandatory);
        if (c == .BK or c == .CR or c == .LF or c == .NL) return it.newItem(ci, .none);
        if (c == .SP or c == .ZW) return it.newItem(ci, .none);
        if (zw) return it.newItem(ci, .allowed);
        // LB9: X (CM|ZWJ)* is X; the item and its context do not change.
        if ((c == .CM or c == .ZWJ) and Item.takesMarks(raw)) return .none;
        if (raw == .ZWJ) return it.newItem(ci, .none);
        // LB10: a lone CM or ZWJ is AL.
        const b: Item = if (c == .CM or c == .ZWJ) Item.al else ci;
        const d: Decision = if (it.pairRule(b, end)) .none else .allowed;
        s.push(b);
        return d;
    }

    inline fn newItem(it: *Iterator, ci: Item, d: Decision) Decision {
        it.state.push(if (ci.cls == .CM or ci.cls == .ZWJ) Item.al else ci);
        return d;
    }

    /// LB11-LB31 between the previous item and `b` (whose first character
    /// ends at `end`). True means no break.
    inline fn pairRule(it: *const Iterator, b: Item, end: usize) bool {
        const s = &it.state;
        const a = s.a;
        const bc = b.cls;
        const ac = a.cls;
        // Fast paths for the commonest pairs; each matches what the full
        // rule chain below decides.
        switch (bc) {
            .AL, .HL, .ID => {
                // LB28 (AL|HL) × (AL|HL); ID pairs fall through to LB31.
                const fa = flagsOf(ac);
                if (fa & (f_alhl | f_id) != 0) return fa & flagsOf(bc) & f_alhl != 0;
                // LB18 after a space unless LB14/LB15a hold the break.
                if (ac == .SP and !s.nsp.is(.OP) and !s.nsp.is(.QU)) return false;
            },
            else => {},
        }
        // LB11, LB12, LB12a.
        if (bc == .WJ or ac == .WJ) return true;
        if (ac == .GL) return true;
        if (bc == .GL and ac != .SP and ac != .HY and ac != .HH) return true;
        // LB13.
        switch (bc) {
            .EX, .CL, .CP, .SY => return true,
            else => {},
        }
        // LB14: OP SP* ×
        if (s.nsp.is(.OP)) return true;
        // LB15a: (sot|BK|CR|LF|NL|OP|QU|GL|SP|ZW) QU_Pi SP* ×
        if (s.nsp.is(.QU) and s.nsp.pi()) {
            const q = s.nsp_prev;
            if (q.sot) return true;
            switch (q.cls) {
                .BK, .CR, .LF, .NL, .OP, .QU, .GL, .SP, .ZW => return true,
                else => {},
            }
        }
        // LB15b: × QU_Pf (SP|GL|WJ|CL|QU|CP|EX|IS|SY|BK|CR|LF|NL|ZW|eot)
        if (bc == .QU and b.pf()) {
            const n = peek(it.bytes, it.opts, end);
            if (n.sot) return true; // eot
            switch (n.cls) {
                .SP, .GL, .WJ, .CL, .QU, .CP, .EX, .IS, .SY, .BK, .CR, .LF, .NL, .ZW => return true,
                else => {},
            }
        }
        // LB15c: SP ÷ IS NU; LB15d: × IS
        if (bc == .IS) {
            if (ac == .SP and peek(it.bytes, it.opts, end).is(.NU)) return false;
            return true;
        }
        // LB16, LB17.
        if (bc == .NS and (s.nsp.is(.CL) or s.nsp.is(.CP))) return true;
        if (bc == .B2 and s.nsp.is(.B2)) return true;
        // LB18.
        if (ac == .SP) return false;
        // LB19, LB19a.
        if (bc == .QU and !b.pi()) return true;
        if (ac == .QU and !a.pf()) return true;
        if (bc == .QU) {
            if (!a.ea()) return true;
            const n = peek(it.bytes, it.opts, end);
            if (n.sot or !n.ea()) return true;
        }
        if (ac == .QU) {
            if (!b.ea()) return true;
            if (s.aa.sot or !s.aa.ea()) return true;
        }
        // LB20.
        if (bc == .CB or ac == .CB) return false;
        // LB20a: (sot|BK|CR|LF|NL|SP|ZW|CB|GL) (HY|HH) × (AL|HL)
        if ((ac == .HY or ac == .HH) and b.alhl()) {
            const q = s.aa;
            if (q.sot) return true;
            switch (q.cls) {
                .BK, .CR, .LF, .NL, .SP, .ZW, .CB, .GL => return true,
                else => {},
            }
        }
        // LB21, LB21a, LB21b.
        switch (bc) {
            .BA, .HH, .HY, .NS => return true,
            else => {},
        }
        if (ac == .BB) return true;
        if ((ac == .HY or ac == .HH) and s.aa.is(.HL) and bc != .HL) return true;
        if (ac == .SY and bc == .HL) return true;
        // LB22.
        if (bc == .IN) return true;
        // LB23, LB23a.
        if (a.alhl() and bc == .NU) return true;
        if (ac == .NU and b.alhl()) return true;
        if (ac == .PR and (bc == .ID or bc == .EB or bc == .EM)) return true;
        if ((ac == .ID or ac == .EB or ac == .EM) and bc == .PO) return true;
        // LB24.
        if ((ac == .PR or ac == .PO) and b.alhl()) return true;
        if (a.alhl() and (bc == .PR or bc == .PO)) return true;
        // LB25, as the regex (PR|PO)? (OP|HY)? NU (NU|SY|IS)* (CL|CP)? (PR|PO)?
        if ((bc == .PO or bc == .PR) and s.num != .none) return true;
        if (ac == .PO or ac == .PR) {
            if (bc == .NU) return true;
            if (bc == .OP) {
                const n = peek(it.bytes, it.opts, end);
                if (n.is(.NU)) return true;
                if (n.is(.IS) and peek2(it.bytes, it.opts, end).is(.NU)) return true;
            }
        }
        if ((ac == .HY or ac == .IS) and bc == .NU) return true;
        if (bc == .NU and s.num == .nu) return true;
        // LB26, LB27.
        switch (ac) {
            .JL => if (bc == .JL or bc == .JV or bc == .H2 or bc == .H3) return true,
            .JV, .H2 => if (bc == .JV or bc == .JT) return true,
            .JT, .H3 => if (bc == .JT) return true,
            else => {},
        }
        if (a.hangul() and bc == .PO) return true;
        if (ac == .PR and b.hangul()) return true;
        // LB28, LB28a.
        if (a.alhl() and b.alhl()) return true;
        if (ac == .AP and b.aksara()) return true;
        if ((bc == .VF or bc == .VI) and a.aksara()) return true;
        if (ac == .VI and s.aa.aksara() and !s.aa.sot and (bc == .AK or b.dotted())) return true;
        if (a.aksara() and b.aksara() and peek(it.bytes, it.opts, end).is(.VF)) return true;
        // LB29.
        if (ac == .IS and b.alhl()) return true;
        // LB30.
        if ((a.alhl() or ac == .NU) and bc == .OP and !b.ea()) return true;
        if (ac == .CP and !a.ea() and (b.alhl() or bc == .NU)) return true;
        // LB30a.
        if (ac == .RI and bc == .RI) return s.ri_odd;
        // LB30b.
        if (bc == .EM and (ac == .EB or a.epu())) return true;
        // LB31.
        return false;
    }

    /// The item after the one whose first character ends at `end`
    /// (`Item.start` stands for end of text).
    fn peek(bytes: []const u8, opts: Options, end: usize) Item {
        return itemAt(bytes, opts, skipMarks(bytes, opts, end)).item;
    }

    /// The item after `peek(end)`.
    fn peek2(bytes: []const u8, opts: Options, end: usize) Item {
        const n = itemAt(bytes, opts, skipMarks(bytes, opts, end));
        if (n.item.sot) return n.item;
        return itemAt(bytes, opts, if (Item.takesMarks(n.raw)) skipMarks(bytes, opts, n.end) else n.end).item;
    }

    fn skipMarks(bytes: []const u8, opts: Options, from: usize) usize {
        var q = from;
        while (q < bytes.len) {
            const u = decode.at(bytes, q);
            const c = Item.of(u.cp, u.valid, opts).cls;
            if (c != .CM and c != .ZWJ) break;
            q += u.len;
        }
        return q;
    }

    fn itemAt(bytes: []const u8, opts: Options, q: usize) struct { item: Item, raw: LB, end: usize } {
        if (q >= bytes.len) return .{ .item = .start, .raw = .XX, .end = q };
        const u = decode.at(bytes, q);
        const ci = Item.of(u.cp, u.valid, opts);
        const item = if (ci.cls == .CM or ci.cls == .ZWJ) Item.al else ci;
        return .{ .item = item, .raw = ci.cls, .end = q + u.len };
    }
};

pub fn decodeUnitForBench(bytes: []const u8, at: usize) struct { cls: u32, len: usize } {
    if (bytes[at] < 0x80) return .{ .cls = @intFromEnum(p.props(bytes[at]).lb), .len = 1 };
    const u = decode.at(bytes, at);
    return .{ .cls = @intFromEnum(p.props(u.cp).lb), .len = u.len };
}

/// UAX14-C2 code tailoring of the break before byte `i`:
/// - a break after `/` followed by a letter (AL) is always allowed;
/// - a break is allowed before `?`, `#`, `&` and `=` inside a URL-like run
///   (a whitespace-delimited run containing `://` or starting `www.`);
/// - no break inside `->`, `=>`, `::`, `!=`, `==`, `<=` or `>=`.
/// Mandatory breaks are never changed.
fn tailor(bytes: []const u8, i: usize, d: Decision) Decision {
    if (d == .mandatory or i == 0 or i >= bytes.len) return d;
    const a = bytes[i - 1];
    const b = bytes[i];
    if (isOperator(a, b)) return .none;
    if (d != .none) return d;
    if (a == '/' and b < 0x80 and p.props(b).lb == .AL) return .allowed;
    if ((b == '?' or b == '#' or b == '&' or b == '=') and inUrl(bytes, i)) return .allowed;
    return d;
}

fn isOperator(a: u8, b: u8) bool {
    return switch (b) {
        '>' => a == '-' or a == '=',
        ':' => a == ':',
        '=' => a == '!' or a == '=' or a == '<' or a == '>',
        else => false,
    };
}

/// Run scans stop after this many bytes either way.
const url_scan_limit = 2048;

fn isRunByte(c: u8) bool {
    return c > ' ' and c != 0x7f;
}

fn inUrl(bytes: []const u8, i: usize) bool {
    var lo = i;
    while (lo > 0 and i - lo < url_scan_limit and isRunByte(bytes[lo - 1])) lo -= 1;
    var hi = i;
    while (hi < bytes.len and hi - i < url_scan_limit and isRunByte(bytes[hi])) hi += 1;
    const run = bytes[lo..hi];
    if (std.mem.startsWith(u8, run, "www.")) return true;
    // The scheme separator must come before `i` for `i` to be inside the URL.
    return std.mem.indexOf(u8, bytes[lo..i], "://") != null;
}

/// How far `lastOpportunityBefore` backs up before scanning forward.
pub const max_backup = 256;

/// The last opportunity at or before `limit` (offset > 0), for wrapping:
/// backs up at most `max_backup` bytes and scans forward. The result
/// equals a full forward scan when a space or hard break precedes the
/// answer within that window (a resynchronisation point); otherwise it is
/// computed as if the text started at the window start.
pub fn lastOpportunityBefore(bytes: []const u8, limit: usize, opts: Options) ?Break {
    const lim = @min(limit, bytes.len);
    if (lim == 0) return null;
    var start: usize = 0;
    if (lim > max_backup) {
        start = decode.snap(bytes, lim - max_backup);
        // Start on a base character: marks and spaces carry context from
        // before the window.
        while (start < lim) {
            const u = decode.at(bytes, start);
            const c = Item.of(u.cp, u.valid, opts).cls;
            if (c != .CM and c != .ZWJ and c != .SP) break;
            start += u.len;
        }
    }
    var it = Iterator.initAt(bytes, start, opts);
    var last: ?Break = null;
    while (it.next()) |b| {
        if (b.offset > lim) break;
        last = b;
    }
    return last;
}

test {
    _ = @import("line_break_test.zig");
}
