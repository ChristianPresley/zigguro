//! A test-only reference matcher: a direct backtracking interpreter of the
//! HIR, independent of the NFA compiler and the engines. Exponential in the
//! worst case, so it runs only on small inputs with a step budget.
//!
//! Semantics are leftmost-first (Perl). An unbounded loop never re-enters
//! after an iteration that consumed nothing, which matches the NFA engines
//! for match spans; captures can differ only inside such empty iterations,
//! so the differential tests compare captures only for patterns without
//! nullable loop bodies (see `hasNullableLoop`).

const std = @import("std");
const hir_mod = @import("../syntax/hir.zig");
const look_mod = @import("../engine/look.zig");
const Input = @import("../input.zig").Input;

const Hir = hir_mod.Hir;

/// Result of a reference search.
pub const Outcome = union(enum) {
    /// No match.
    none,
    /// A match; `slots` holds `2 * groups` positions (`null` when unset).
    match,
    /// The step budget ran out; the case is inconclusive.
    budget,
};

const Cont = struct {
    kind: union(enum) {
        seq: struct { items: []const *Hir, i: usize },
        capture_end: u32,
        star: struct { rep: *const Hir, iter_start: u64 },
        count: struct { rep: *const Hir, done: u32 },
    },
    next: ?*const Cont,
};

/// The matcher state.
pub const Ref = struct {
    in: Input,
    slots: []?u64,
    steps: usize = 0,
    budget: usize = 200_000,
    end: u64 = 0,

    fn tick(r: *Ref) error{Budget}!void {
        r.steps += 1;
        if (r.steps > r.budget) return error.Budget;
    }

    fn cont(r: *Ref, pos: u64, k: ?*const Cont) error{Budget}!bool {
        try r.tick();
        const c = k orelse {
            r.end = pos;
            return true;
        };
        switch (c.kind) {
            .seq => |s| {
                if (s.i == s.items.len) return r.cont(pos, c.next);
                const nk: Cont = .{ .kind = .{ .seq = .{ .items = s.items, .i = s.i + 1 } }, .next = c.next };
                return r.m(s.items[s.i], pos, &nk);
            },
            .capture_end => |idx| {
                const old = r.slots[idx * 2 + 1];
                r.slots[idx * 2 + 1] = pos;
                if (try r.cont(pos, c.next)) return true;
                r.slots[idx * 2 + 1] = old;
                return false;
            },
            .star => |st| {
                if (pos == st.iter_start) return false; // empty iteration
                return r.loop(st.rep, pos, c.next);
            },
            .count => |ct| return r.counted(ct.rep, ct.done, pos, c.next),
        }
    }

    fn loop(r: *Ref, rep: *const Hir, pos: u64, k: ?*const Cont) error{Budget}!bool {
        const rp = rep.repetition;
        const nk: Cont = .{ .kind = .{ .star = .{ .rep = rep, .iter_start = pos } }, .next = k };
        if (rp.greedy) {
            if (try r.m(rp.sub, pos, &nk)) return true;
            return r.cont(pos, k);
        }
        if (try r.cont(pos, k)) return true;
        return r.m(rp.sub, pos, &nk);
    }

    /// `done` iterations of `rep` have matched; continue.
    fn counted(r: *Ref, rep: *const Hir, done: u32, pos: u64, k: ?*const Cont) error{Budget}!bool {
        const rp = rep.repetition;
        if (done < rp.min) {
            // Mandatory iterations; the last mandatory one of an unbounded
            // repetition hands over to the loop.
            if (rp.max == null and done + 1 == rp.min) {
                const lk: Cont = .{ .kind = .{ .star = .{ .rep = rep, .iter_start = std.math.maxInt(u64) } }, .next = k };
                return r.m(rp.sub, pos, &lk);
            }
            const nk: Cont = .{ .kind = .{ .count = .{ .rep = rep, .done = done + 1 } }, .next = k };
            return r.m(rp.sub, pos, &nk);
        }
        if (rp.max == null) return r.loop(rep, pos, k);
        if (done == rp.max.?) return r.cont(pos, k);
        const nk: Cont = .{ .kind = .{ .count = .{ .rep = rep, .done = done + 1 } }, .next = k };
        if (rp.greedy) {
            if (try r.m(rp.sub, pos, &nk)) return true;
            return r.cont(pos, k);
        }
        if (try r.cont(pos, k)) return true;
        return r.m(rp.sub, pos, &nk);
    }

    fn m(r: *Ref, h: *const Hir, pos: u64, k: ?*const Cont) error{Budget}!bool {
        try r.tick();
        const len = r.in.total_len;
        switch (h.*) {
            .empty => return r.cont(pos, k),
            .literal => |bytes| {
                if (pos + bytes.len > r.in.span.end) return false;
                for (bytes, 0..) |b, i| if (r.in.byteAt(pos + i) != b) return false;
                return r.cont(pos + bytes.len, k);
            },
            .class_bytes => |set| {
                if (pos >= r.in.span.end) return false;
                if (!set.contains(r.in.byteAt(pos))) return false;
                return r.cont(pos + 1, k);
            },
            .class_unicode => |set| {
                if (pos >= r.in.span.end) return false;
                const cp = look_mod.decodeFwd(&r.in, pos) orelse return false;
                const n = std.unicode.utf8CodepointSequenceLength(cp) catch return false;
                if (pos + n > r.in.span.end) return false;
                if (!set.contains(cp)) return false;
                return r.cont(pos + n, k);
            },
            .look => |l| {
                _ = len;
                if (!look_mod.matches(l, &r.in, pos)) return false;
                return r.cont(pos, k);
            },
            .capture => |c| {
                const old0 = r.slots[c.index * 2];
                const old1 = r.slots[c.index * 2 + 1];
                r.slots[c.index * 2] = pos;
                const nk: Cont = .{ .kind = .{ .capture_end = c.index }, .next = k };
                if (try r.m(c.sub, pos, &nk)) return true;
                r.slots[c.index * 2] = old0;
                r.slots[c.index * 2 + 1] = old1;
                return false;
            },
            .concat => |items| {
                const nk: Cont = .{ .kind = .{ .seq = .{ .items = items, .i = 0 } }, .next = k };
                return r.cont(pos, &nk);
            },
            .alternation => |items| {
                for (items) |it| if (try r.m(it, pos, k)) return true;
                return false;
            },
            .repetition => return r.counted(h, 0, pos, k),
        }
    }
};

/// Leftmost-first search of `h` in `in`. `slots` has `2 * groups` entries
/// (group 0 included) and receives the captures on a match.
pub fn search(h: *const Hir, in: Input, slots: []?u64, budget: usize) Outcome {
    var r: Ref = .{ .in = in, .slots = slots, .budget = budget };
    var start = in.span.start;
    while (start <= in.span.end) : (start += 1) {
        if (in.anchored and start > in.span.start) break;
        @memset(slots, null);
        const ok = r.m(h, start, null) catch return .budget;
        if (ok) {
            slots[0] = start;
            slots[1] = r.end;
            return .match;
        }
    }
    @memset(slots, null);
    return .none;
}

/// Whether `h` has an unbounded repetition whose body can match empty.
pub fn hasNullableLoop(h: *const Hir) bool {
    return switch (h.*) {
        .repetition => |r| (r.max == null and nullable(r.sub)) or hasNullableLoop(r.sub),
        .capture => |c| hasNullableLoop(c.sub),
        .concat, .alternation => |items| for (items) |it| {
            if (hasNullableLoop(it)) break true;
        } else false,
        else => false,
    };
}

/// Whether `h` can match the empty string.
pub fn nullable(h: *const Hir) bool {
    return switch (h.*) {
        .empty, .look => true,
        .literal => |b| b.len == 0,
        .class_unicode, .class_bytes => false,
        .repetition => |r| r.min == 0 or nullable(r.sub),
        .capture => |c| nullable(c.sub),
        .concat => |items| for (items) |it| {
            if (!nullable(it)) break false;
        } else true,
        .alternation => |items| for (items) |it| {
            if (nullable(it)) break true;
        } else false,
    };
}
