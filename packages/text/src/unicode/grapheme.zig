//! UAX #29 extended grapheme clusters (Unicode 18.0.0 rules GB1-GB999,
//! including GB9c in its rev. 49 form and GB11 emoji ZWJ sequences) over
//! UTF-8. Ill-formed bytes decode to U+FFFD with Control semantics, so each
//! maximal ill-formed subsequence is its own cluster. No allocation.

const std = @import("std");
const p = @import("props.zig");
const decode = @import("decode.zig");
const GraphemeBreak = p.GraphemeBreak;

/// A byte span.
pub const Span = struct { start: usize, len: usize };

/// The class of one code point as the rules see it.
pub const Class = struct {
    gcb: GraphemeBreak,
    incb: p.IndicConjunctBreak,
    ext_pict: bool,

    /// The class of `cp`; `valid = false` (ill-formed input) is Control.
    pub inline fn of(cp: u21, valid: bool) Class {
        if (!valid) return .{ .gcb = .CN, .incb = .None, .ext_pict = false };
        const x = p.props(cp);
        return .{ .gcb = x.gcb, .incb = x.incb, .ext_pict = x.ext_pict };
    }
};

/// Streaming state: the context the rules need from the current cluster.
pub const State = struct {
    prev: GraphemeBreak = .XX,
    /// True when the current cluster has seen an odd number of RIs.
    ri_odd: bool = false,
    /// GB11: ExtPict Extend* (pict) followed by ZWJ (pict_zwj).
    emoji_zwj: enum(u2) { none, pict, pict_zwj } = .none,
    /// GB9c: armed after an InCB=Linker, kept across InCB=Extend.
    incb: enum(u2) { none, consonant, linker } = .none,
    /// False before the first code point (GB1).
    started: bool = false,

    /// Feeds the next code point's class; returns true if a boundary
    /// precedes it, and updates the state.
    pub inline fn feed(s: *State, c: Class) bool {
        const brk = !s.started or s.breakBefore(c);
        if (brk) {
            s.ri_odd = false;
        }
        s.update(c, brk);
        return brk;
    }

    fn breakBefore(s: *const State, c: Class) bool {
        const a = s.prev;
        const b = c.gcb;
        if (a == .CR and b == .LF) return false; // GB3
        if (a == .CN or a == .CR or a == .LF) return true; // GB4
        if (b == .CN or b == .CR or b == .LF) return true; // GB5
        switch (a) { // GB6-GB8
            .L => if (b == .L or b == .V or b == .LV or b == .LVT) return false,
            .LV, .V => if (b == .V or b == .T) return false,
            .LVT, .T => if (b == .T) return false,
            else => {},
        }
        if (b == .EX or b == .ZWJ or b == .SM) return false; // GB9, GB9a
        if (a == .PP) return false; // GB9b
        if (s.incb == .linker and c.incb == .Consonant) return false; // GB9c
        if (s.emoji_zwj == .pict_zwj and c.ext_pict) return false; // GB11
        if (a == .RI and b == .RI and s.ri_odd) return false; // GB12, GB13
        return true; // GB999
    }

    fn update(s: *State, c: Class, brk: bool) void {
        s.started = true;
        s.prev = c.gcb;
        if (c.gcb == .RI) s.ri_odd = !s.ri_odd else s.ri_odd = false;
        s.emoji_zwj = if (c.ext_pict)
            .pict
        else if (c.gcb == .EX and s.emoji_zwj == .pict)
            .pict
        else if (c.gcb == .ZWJ and s.emoji_zwj == .pict)
            .pict_zwj
        else
            .none;
        s.incb = switch (c.incb) {
            .Linker => .linker,
            .Extend => if (s.incb == .linker) .linker else if (brk) .none else s.incb,
            .Consonant => .consonant,
            .None => .none,
        };
    }
};

/// Streaming boundary test for callers that already decode (terminal
/// parser): true if a boundary lies between `prev_cp` and `cp`. Start with
/// `State{}`; the first call always returns true.
pub fn isBoundary(state: *State, prev_cp: u21, cp: u21) bool {
    _ = prev_cp;
    return state.feed(.of(cp, true));
}

/// Iterates grapheme clusters of a UTF-8 slice.
pub const Iterator = struct {
    bytes: []const u8,
    /// Start of the next cluster.
    pos: usize,
    /// Next byte to decode; the state has consumed everything before it.
    i: usize = 0,
    state: State = .{},

    /// Iterates `bytes` from the start.
    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes, .pos = 0 };
    }

    /// The next cluster, or null at the end.
    pub fn next(it: *Iterator) ?Span {
        const bytes = it.bytes;
        if (it.pos >= bytes.len) return null;
        const start = it.pos;
        // The state may already hold the cluster's first code point (fed
        // while finding the previous boundary); `i` is past it then.
        while (it.i < bytes.len) {
            const at = it.i;
            const c = bytes[at];
            var cls: Class = undefined;
            if (c < 0x80) {
                cls = .{ .gcb = asciiGcb(c), .incb = .None, .ext_pict = false };
                it.i = at + 1;
            } else {
                const u = decode.at(bytes, at);
                cls = .of(u.cp, u.valid);
                it.i = at + u.len;
            }
            if (it.state.feed(cls) and at != start) {
                it.pos = at;
                return .{ .start = start, .len = at - start };
            }
        }
        it.pos = bytes.len;
        return .{ .start = start, .len = bytes.len - start };
    }
};

inline fn asciiGcb(c: u8) GraphemeBreak {
    return switch (c) {
        '\r' => .CR,
        '\n' => .LF,
        0...9, 11, 12, 14...31, 127 => .CN,
        else => .XX,
    };
}

const V = @Vector(16, u8);

/// The first boundary after `offset` (which must be a boundary), or
/// `bytes.len`.
pub fn nextBoundary(bytes: []const u8, offset: usize) usize {
    if (offset >= bytes.len) return bytes.len;
    const c0 = bytes[offset];
    if (c0 < 0x80 and offset + 1 < bytes.len and bytes[offset + 1] < 0x80) {
        if (c0 == '\r' and bytes[offset + 1] == '\n') return offset + 2;
        return offset + 1;
    }
    var s: State = .{};
    var i = offset;
    while (i < bytes.len) {
        const u = decode.at(bytes, i);
        if (s.feed(.of(u.cp, u.valid)) and i != offset) return i;
        i += u.len;
    }
    return bytes.len;
}

/// Number of clusters in `bytes`. Pure-ASCII stretches without CR are
/// counted 16 bytes at a time.
pub fn count(bytes: []const u8) usize {
    var n: usize = 0;
    var s: State = .{};
    var i: usize = 0;
    while (i < bytes.len) {
        if (i + 16 <= bytes.len and s.prev != .PP and s.prev != .CR) {
            const v: V = bytes[i..][0..16].*;
            if (@reduce(.And, v < @as(V, @splat(0x80))) and @reduce(.And, v != @as(V, @splat('\r')))) {
                // Each byte starts a cluster (no ASCII byte joins its
                // predecessor except LF after CR, excluded above).
                n += 16;
                i += 16;
                s = .{ .started = true, .prev = asciiGcb(bytes[i - 1]) };
                continue;
            }
        }
        const c = bytes[i];
        if (c < 0x80) {
            if (s.feed(.{ .gcb = asciiGcb(c), .incb = .None, .ext_pict = false })) n += 1;
            i += 1;
            continue;
        }
        const u = decode.at(bytes, i);
        if (s.feed(.of(u.cp, u.valid))) n += 1;
        i += u.len;
    }
    return n;
}

/// Maximum code points `prevBoundary` backs up before giving up; a cluster
/// longer than this gets a boundary at the cap.
pub const max_backup = 64;

fn joinsBefore(prev: Class, x: Class) bool {
    // Conservative: true when a cluster might continue across the position
    // between `prev` and `x`.
    if (prev.gcb == .CN or prev.gcb == .LF) return false;
    if (prev.gcb == .CR) return x.gcb == .LF;
    if (x.gcb == .CN or x.gcb == .CR or x.gcb == .LF) return false;
    if (x.gcb == .EX or x.gcb == .ZWJ or x.gcb == .SM or prev.gcb == .PP) return true;
    switch (x.gcb) {
        .L, .V, .T, .LV, .LVT => switch (prev.gcb) {
            .L, .V, .T, .LV, .LVT => return true,
            else => {},
        },
        .RI => if (prev.gcb == .RI) return true,
        else => {},
    }
    if (x.incb == .Consonant and (prev.incb == .Linker or prev.incb == .Extend)) return true;
    if (x.ext_pict and prev.gcb == .ZWJ) return true;
    return false;
}

/// The last boundary before `offset` (0 when none). `offset` is snapped to
/// a code point start first.
pub fn prevBoundary(bytes: []const u8, offset: usize) usize {
    const end = decode.snap(bytes, @min(offset, bytes.len));
    if (end == 0) return 0;
    // Back up to a position that is certainly a boundary.
    var q = decode.prevStart(bytes, end);
    var steps: usize = 0;
    while (q > 0 and steps < max_backup) : (steps += 1) {
        const ux = decode.at(bytes, q);
        const pq = decode.prevStart(bytes, q);
        const up = decode.at(bytes, pq);
        if (!joinsBefore(.of(up.cp, up.valid), .of(ux.cp, ux.valid))) break;
        q = pq;
    }
    // Walk forward to the last boundary before `end`.
    var b = q;
    while (true) {
        const n = nextBoundary(bytes, b);
        if (n >= end) return b;
        b = n;
    }
}

test {
    _ = @import("segment_test.zig");
}
