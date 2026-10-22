//! Syllable machines for the syllabic shapers (USE, Indic): a list of
//! regular expressions over a category enum, compiled at comptime into a
//! Thompson automaton with precomputed epsilon closures, and matched the
//! way Ragel scanners (HarfBuzz's `*-machine.rl`) match: the longest match
//! wins, and of equally long matches the rule listed first.
//!
//! Matching steps a set of states per input category, so it is linear in
//! the syllable's length with no limit on it. A state's successors on a
//! category are one precomputed bit set, so a step is a few word ORs per
//! live state.

const std = @import("std");

/// A regular expression over the values of a category enum (each below 64).
pub const Expr = union(enum) {
    /// One category from the set (bit `v` for value `v`).
    set: u64,
    seq: []const Expr,
    alt: []const Expr,
    star: *const Expr,
    opt: *const Expr,
};

/// One of `cats` (enum literals of the category type).
pub fn one(comptime Cat: type, comptime cats: []const Cat) Expr {
    var m: u64 = 0;
    for (cats) |c| m |= @as(u64, 1) << @intFromEnum(c);
    return .{ .set = m };
}

/// Any category.
pub const any: Expr = .{ .set = ~@as(u64, 0) };

/// `es` in sequence.
pub fn seq(comptime es: []const Expr) Expr {
    return .{ .seq = es };
}

/// One of `es`.
pub fn alt(comptime es: []const Expr) Expr {
    return .{ .alt = es };
}

/// `e*`.
pub fn star(comptime e: Expr) Expr {
    return .{ .star = &e };
}

/// `e?`.
pub fn opt(comptime e: Expr) Expr {
    return .{ .opt = &e };
}

/// `e+`.
pub fn plus(comptime e: Expr) Expr {
    return seq(&.{ e, star(e) });
}

/// A match: its length and the index of the rule that matched.
pub const Match = struct { len: usize, rule: u8 };

/// A scanner over `Cat` (an enum whose values are below 64) for `rules`,
/// tried in order.
pub fn Machine(comptime Cat: type, comptime rules: []const Expr) type {
    const nfa = comptime compile(rules);
    const n = nfa.count;
    const W = (n + 63) / 64;
    const Set = [W]u64;
    const tables = comptime blk: {
        @setEvalBranchQuota(50_000_000);
        var closure: [n]Set = undefined;
        for (0..n) |s| closure[s] = closureOf(nfa, s, W);
        var succ: [n]Set = @splat(@splat(0));
        var masks: [n]u64 = @splat(0);
        for (0..n) |s| if (nfa.states[s].mask != 0) {
            masks[s] = nfa.states[s].mask;
            succ[s] = closure[nfa.states[s].next];
        };
        var accept: [rules.len]u16 = undefined;
        for (&accept, nfa.accept[0..rules.len]) |*x, a| x.* = a;
        break :blk .{ .start = closure[nfa.start], .succ = succ, .masks = masks, .accept = accept };
    };
    return struct {
        /// The automaton's state count (for tests and diagnostics).
        pub const state_count = n;

        /// The longest match of a rule at `cats[start..]`, or null when no
        /// rule matches at least one category.
        pub fn longestMatch(cats: []const Cat, start: usize) ?Match {
            var cur: Set = tables.start;
            var best: ?Match = null;
            var i = start;
            while (i < cats.len) : (i += 1) {
                const bit = @as(u64, 1) << @intFromEnum(cats[i]);
                var next: Set = @splat(0);
                var live = false;
                for (cur, 0..) |word, wi| {
                    var w = word;
                    while (w != 0) : (w &= w - 1) {
                        const s = wi * 64 + @ctz(w);
                        if (tables.masks[s] & bit == 0) continue;
                        for (&next, tables.succ[s]) |*x, y| x.* |= y;
                        live = true;
                    }
                }
                if (!live) break;
                cur = next;
                for (tables.accept, 0..) |a, r| {
                    if (cur[a / 64] & (@as(u64, 1) << @intCast(a % 64)) != 0) {
                        best = .{ .len = i + 1 - start, .rule = @intCast(r) };
                        break;
                    }
                }
            }
            return best;
        }
    };
}

const State = struct {
    /// Categories of the one transition (0: epsilon edges only).
    mask: u64 = 0,
    next: u16 = 0,
    eps: [2]?u16 = .{ null, null },
};

const max_states = 2048;

const Nfa = struct {
    states: [max_states]State = undefined,
    count: usize = 0,
    start: u16 = 0,
    accept: [64]u16 = undefined,

    fn add(m: *Nfa, s: State) u16 {
        if (m.count == max_states) @compileError("syllable machine too large");
        m.states[m.count] = s;
        m.count += 1;
        return @intCast(m.count - 1);
    }

    fn link(m: *Nfa, from: u16, to: u16) void {
        const e = &m.states[from].eps;
        if (e[0] == null) {
            e[0] = to;
        } else if (e[1] == null) {
            e[1] = to;
        } else unreachable;
    }

    const Frag = struct { start: u16, end: u16 };

    /// A fragment for `e`: `end` is an epsilon state with no edges yet.
    fn frag(m: *Nfa, e: Expr) Frag {
        switch (e) {
            .set => |mask| {
                const end = m.add(.{});
                return .{ .start = m.add(.{ .mask = mask, .next = end }), .end = end };
            },
            .seq => |es| {
                if (es.len == 0) {
                    const s = m.add(.{});
                    return .{ .start = s, .end = s };
                }
                var f = m.frag(es[0]);
                for (es[1..]) |x| {
                    const g = m.frag(x);
                    m.link(f.end, g.start);
                    f.end = g.end;
                }
                return f;
            },
            .alt => |es| {
                // A chain of two-way splits.
                const start = m.add(.{});
                const end = m.add(.{});
                var split = start;
                for (es, 0..) |x, i| {
                    const g = m.frag(x);
                    m.link(g.end, end);
                    if (i + 1 == es.len) {
                        m.link(split, g.start);
                    } else {
                        m.link(split, g.start);
                        const s2 = m.add(.{});
                        m.link(split, s2);
                        split = s2;
                    }
                }
                return .{ .start = start, .end = end };
            },
            .star => |x| {
                const start = m.add(.{});
                const end = m.add(.{});
                const g = m.frag(x.*);
                m.link(start, g.start);
                m.link(start, end);
                m.link(g.end, g.start);
                m.link(g.end, end);
                return .{ .start = start, .end = end };
            },
            .opt => |x| {
                const start = m.add(.{});
                const end = m.add(.{});
                const g = m.frag(x.*);
                m.link(start, g.start);
                m.link(start, end);
                m.link(g.end, end);
                return .{ .start = start, .end = end };
            },
        }
    }
};

fn compile(comptime rules: []const Expr) Nfa {
    @setEvalBranchQuota(10_000_000);
    if (rules.len > 64) @compileError("too many rules");
    var m: Nfa = .{};
    var split = m.add(.{});
    m.start = split;
    for (rules, 0..) |r, i| {
        const f = m.frag(r);
        m.accept[i] = f.end;
        m.link(split, f.start);
        if (i + 1 < rules.len) {
            const s2 = m.add(.{});
            m.link(split, s2);
            split = s2;
        }
    }
    return m;
}

fn closureOf(comptime nfa: Nfa, comptime s: usize, comptime W: usize) [W]u64 {
    var set: [W]u64 = @splat(0);
    var stack: [max_states]u16 = undefined;
    var sp: usize = 1;
    stack[0] = s;
    set[s / 64] |= @as(u64, 1) << (s % 64);
    while (sp > 0) {
        sp -= 1;
        const t = stack[sp];
        for (nfa.states[t].eps) |e| if (e) |x| {
            if (set[x / 64] & (@as(u64, 1) << (x % 64)) == 0) {
                set[x / 64] |= @as(u64, 1) << (x % 64);
                stack[sp] = x;
                sp += 1;
            }
        };
    }
    return set;
}

test "longest match, earliest rule on ties" {
    const C = enum(u6) { a, b, c };
    const M = Machine(C, &.{
        seq(&.{ one(C, &.{.a}), star(one(C, &.{.b})) }),
        seq(&.{ one(C, &.{.a}), one(C, &.{.b}), one(C, &.{.c}) }),
        any,
    });
    const t = std.testing;
    try t.expectEqual(Match{ .len = 3, .rule = 0 }, M.longestMatch(&.{ .a, .b, .b, .a }, 0).?);
    try t.expectEqual(Match{ .len = 3, .rule = 1 }, M.longestMatch(&.{ .a, .b, .c }, 0).?);
    // `a b` matches rules 0 only; `a` alone ties rule 0 with `any`.
    try t.expectEqual(Match{ .len = 1, .rule = 0 }, M.longestMatch(&.{.a}, 0).?);
    try t.expectEqual(Match{ .len = 1, .rule = 2 }, M.longestMatch(&.{ .a, .b, .c, .c }, 3).?);
    try t.expectEqual(@as(?Match, null), M.longestMatch(&.{}, 0));
}

test "optional and plus" {
    const C = enum(u6) { a, b };
    const M = Machine(C, &.{seq(&.{ opt(one(C, &.{.a})), plus(one(C, &.{.b})) })});
    const t = std.testing;
    try t.expectEqual(@as(?Match, null), M.longestMatch(&.{.a}, 0));
    try t.expectEqual(Match{ .len = 3, .rule = 0 }, M.longestMatch(&.{ .a, .b, .b }, 0).?);
    try t.expectEqual(Match{ .len = 1, .rule = 0 }, M.longestMatch(&.{ .b, .a }, 0).?);
}
