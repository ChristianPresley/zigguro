//! `Merge(T)`: a value that may be conflicted, as an odd-length list
//! alternating adds and removes: `values[0] + (values[2] - values[1]) +
//! (values[4] - values[3]) + ...` (Jujutsu's first-class conflicts). A
//! single value is resolved. Rebasing a conflict substitutes and flattens
//! nested merges, then `simplify` cancels add/remove pairs, so conflicts
//! never nest and rebasing back and forth leaves no trace.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Whether identical changes on several sides count as one (`accept`, as
/// git and Jujutsu do) or as a conflict.
pub const SameChange = enum { accept, reject };

pub const Error = error{InvalidMerge};

/// Equality for `Merge` element types: byte slices by content, optionals
/// of those likewise, IDs by `eql`, everything else by `std.meta.eql`.
pub fn defaultEql(comptime T: type) fn (T, T) bool {
    return struct {
        fn eql(a: T, b: T) bool {
            return eqlAny(T, a, b);
        }
    }.eql;
}

fn eqlAny(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (a == null or b == null) return a == null and b == null;
            return eqlAny(o.child, a.?, b.?);
        },
        .pointer => |p| if (p.size == .slice) return std.mem.eql(p.child, a, b),
        .@"struct" => if (@hasDecl(T, "eql")) return a.eql(b),
        else => {},
    }
    return std.meta.eql(a, b);
}

pub fn Merge(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Odd length; even indexes are adds (sides), odd ones removes
        /// (bases).
        values: []const T,

        /// A resolved merge over a value the caller keeps alive.
        pub fn resolved(v: *const T) Self {
            return .{ .values = v[0..1] };
        }

        /// Wraps a raw slice (e.g. `Change.tree_terms`), checking its
        /// length is odd.
        pub fn fromSlice(values: []const T) Error!Self {
            if (values.len % 2 != 1) return error.InvalidMerge;
            return .{ .values = values };
        }

        pub fn toSlice(m: Self) []const T {
            return m.values;
        }

        pub fn isResolved(m: Self) bool {
            return m.values.len == 1;
        }

        pub fn asResolved(m: Self) ?T {
            return if (m.values.len == 1) m.values[0] else null;
        }

        /// Number of sides (adds).
        pub fn sides(m: Self) usize {
            return (m.values.len + 1) / 2;
        }

        pub fn add(m: Self, i: usize) T {
            return m.values[2 * i];
        }

        pub fn remove(m: Self, i: usize) T {
            return m.values[2 * i + 1];
        }

        /// Substitutes nested merges: an add contributes its terms as they
        /// are, a remove contributes them negated. With alternating signs
        /// that is just their concatenation in order.
        pub fn flatten(gpa: Allocator, nested: Merge(Merge(T))) Allocator.Error!Self {
            var n: usize = 0;
            for (nested.values) |m| n += m.values.len;
            const out = try gpa.alloc(T, n);
            var k: usize = 0;
            for (nested.values) |m| {
                @memcpy(out[k..][0..m.values.len], m.values);
                k += m.values.len;
            }
            return .{ .values = out };
        }

        /// Cancels each remove against the first equal add, until no pair
        /// is left. The result is allocated (free with `gpa.free(values)`)
        /// and keeps the remaining terms in order, so the first add stays
        /// first unless it cancels.
        pub fn simplify(m: Self, gpa: Allocator, comptime eql: fn (T, T) bool) Allocator.Error!Self {
            var adds: std.ArrayList(T) = .empty;
            defer adds.deinit(gpa);
            var removes: std.ArrayList(T) = .empty;
            defer removes.deinit(gpa);
            for (m.values, 0..) |v, i| {
                if (i % 2 == 0) try adds.append(gpa, v) else try removes.append(gpa, v);
            }
            var j: usize = 0;
            while (j < removes.items.len) {
                const r = removes.items[j];
                for (adds.items, 0..) |a, i| {
                    if (eql(a, r)) {
                        _ = adds.orderedRemove(i);
                        _ = removes.orderedRemove(j);
                        break;
                    }
                } else j += 1;
            }
            const out = try gpa.alloc(T, adds.items.len + removes.items.len);
            for (adds.items, 0..) |a, i| out[2 * i] = a;
            for (removes.items, 0..) |r, i| out[2 * i + 1] = r;
            return .{ .values = out };
        }

        /// The value a merge trivially resolves to, if any: terms cancel
        /// out to a single add, or (with `accept`) every surviving add is
        /// the same value.
        pub fn resolveTrivial(m: Self, same_change: SameChange, comptime eql: fn (T, T) bool) ?T {
            const v = m.values;
            if (v.len == 1) return v[0];
            if (v.len == 3) {
                if (eql(v[0], v[2]) and same_change == .accept) return v[0];
                if (eql(v[0], v[1])) return v[2];
                if (eql(v[2], v[1])) return v[0];
                return null;
            }
            // Net count of each distinct value: +1 per add, -1 per remove.
            var distinct: [32]usize = undefined;
            var counts: [32]i32 = undefined;
            var n: usize = 0;
            for (v, 0..) |x, i| {
                const sign: i32 = if (i % 2 == 0) 1 else -1;
                for (distinct[0..n], 0..) |d, k| {
                    if (eql(v[d], x)) {
                        counts[k] += sign;
                        break;
                    }
                } else {
                    if (n == distinct.len) return null;
                    distinct[n] = i;
                    counts[n] = sign;
                    n += 1;
                }
            }
            var nonzero: usize = 0;
            var positive: usize = 0;
            var last_pos: usize = 0;
            var last_one: ?usize = null;
            for (counts[0..n], 0..) |c, k| {
                if (c != 0) nonzero += 1;
                if (c > 0) {
                    positive += 1;
                    last_pos = k;
                }
                if (c == 1) last_one = k;
            }
            if (nonzero == 1) if (last_one) |k| return v[distinct[k]];
            if (same_change == .accept and positive == 1) return v[distinct[last_pos]];
            return null;
        }

        /// Applies `f` to every term (allocated like `simplify`).
        pub fn map(m: Self, gpa: Allocator, comptime U: type, ctx: anytype, comptime f: fn (@TypeOf(ctx), T) U) Allocator.Error!Merge(U) {
            const out = try gpa.alloc(U, m.values.len);
            for (m.values, out) |x, *o| o.* = f(ctx, x);
            return .{ .values = out };
        }
    };
}

const t = std.testing;
const I = Merge(u8);
const eqlU8 = defaultEql(u8);

fn simp(vals: []const u8) ![]const u8 {
    const m = try I.fromSlice(vals);
    return (try m.simplify(t.allocator, eqlU8)).values;
}

test "merge: simplify/flatten identities" {
    const gpa = t.allocator;
    // Each remove cancels the first equal add.
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "a", .out = "a" },
        .{ .in = "aab", .out = "b" },
        .{ .in = "abb", .out = "a" },
        .{ .in = "abc", .out = "abc" },
        .{ .in = "abcbd", .out = "abcbd" },
        .{ .in = "abcad", .out = "cbd" },
        .{ .in = "ababa", .out = "ababa" },
        .{ .in = "aaaab", .out = "b" },
        .{ .in = "abcde", .out = "abcde" },
    };
    for (cases) |c| {
        const got = try simp(c.in);
        defer gpa.free(got);
        try t.expectEqualStrings(c.out, got);
    }
    try t.expectError(error.InvalidMerge, I.fromSlice("ab"));

    // Rebase B (on A) onto C, then onto D: D + (B - A), no trace of C.
    const once = [_]I{ .{ .values = "C" }, .{ .values = "A" }, .{ .values = "B" } };
    const first = try I.flatten(gpa, .{ .values = &once });
    defer gpa.free(first.values);
    try t.expectEqualStrings("CAB", first.values);
    const twice = [_]I{ .{ .values = "D" }, .{ .values = "C" }, first };
    const flat = try I.flatten(gpa, .{ .values = &twice });
    defer gpa.free(flat.values);
    const s = try flat.simplify(gpa, eqlU8);
    defer gpa.free(s.values);
    try t.expectEqualStrings("DAB", s.values);
    // Reverting a conflicted commit (applying its inverse) simplifies away.
    const conflicted: I = .{ .values = "CAB" };
    const revert = [_]I{ conflicted, conflicted, .{ .values = "C" } };
    const r = try I.flatten(gpa, .{ .values = &revert });
    defer gpa.free(r.values);
    const rs = try r.simplify(gpa, eqlU8);
    defer gpa.free(rs.values);
    try t.expectEqualStrings("C", rs.values);
}

test "merge: resolveTrivial" {
    const cases = [_]struct { in: []const u8, accept: ?u8, reject: ?u8 }{
        .{ .in = "a", .accept = 'a', .reject = 'a' },
        .{ .in = "aba", .accept = 'a', .reject = null },
        .{ .in = "aab", .accept = 'b', .reject = 'b' },
        .{ .in = "abb", .accept = 'a', .reject = 'a' },
        .{ .in = "abc", .accept = null, .reject = null },
        .{ .in = "abaca", .accept = 'a', .reject = null },
        .{ .in = "aabbc", .accept = 'c', .reject = 'c' },
        .{ .in = "abcbd", .accept = null, .reject = null },
        // Removed more than added: not trivially resolvable.
        .{ .in = "abcbb", .accept = null, .reject = null },
    };
    for (cases) |c| {
        const m: I = .{ .values = c.in };
        try t.expectEqual(c.accept, m.resolveTrivial(.accept, eqlU8));
        try t.expectEqual(c.reject, m.resolveTrivial(.reject, eqlU8));
    }
}

test "merge: property tests over small integer merges" {
    const gpa = t.allocator;
    var prng: std.Random.DefaultPrng = .init(1);
    const rng = prng.random();
    for (0..5000) |_| {
        const n = 1 + 2 * rng.uintLessThan(usize, 5);
        var buf: [9]u8 = undefined;
        for (buf[0..n]) |*b| b.* = rng.uintLessThan(u8, 4);
        const m: I = .{ .values = buf[0..n] };
        const s = try m.simplify(gpa, eqlU8);
        defer gpa.free(s.values);
        // Odd length, idempotent, and the same multiset sum.
        try t.expect(s.values.len % 2 == 1);
        const s2 = try s.simplify(gpa, eqlU8);
        defer gpa.free(s2.values);
        try t.expectEqualSlices(u8, s.values, s2.values);
        var net_m: [4]i32 = @splat(0);
        var net_s: [4]i32 = @splat(0);
        for (m.values, 0..) |x, i| net_m[x] += if (i % 2 == 0) 1 else -1;
        for (s.values, 0..) |x, i| net_s[x] += if (i % 2 == 0) 1 else -1;
        try t.expectEqual(net_m, net_s);
        // Trivial resolution agrees with the simplified form.
        if (s.isResolved()) try t.expectEqual(s.values[0], m.resolveTrivial(.reject, eqlU8).?);
        if (m.resolveTrivial(.reject, eqlU8)) |v| {
            // Resolving means the net is exactly one copy of v.
            for (net_m, 0..) |c, x| try t.expectEqual(@as(i32, if (x == v) 1 else 0), c);
        }
        // Rebase identity: (m onto x) onto y == m onto y.
        const x = rng.uintLessThan(u8, 4);
        const y = rng.uintLessThan(u8, 4);
        const base = m.values[0];
        const vx = [_]u8{x};
        const vb = [_]u8{base};
        const vy = [_]u8{y};
        const on_x = try I.flatten(gpa, .{ .values = &.{ .{ .values = &vx }, .{ .values = &vb }, m } });
        defer gpa.free(on_x.values);
        const on_xy = try I.flatten(gpa, .{ .values = &.{ .{ .values = &vy }, .{ .values = &vx }, on_x } });
        defer gpa.free(on_xy.values);
        const direct = try I.flatten(gpa, .{ .values = &.{ .{ .values = &vy }, .{ .values = &vb }, m } });
        defer gpa.free(direct.values);
        const a = try on_xy.simplify(gpa, eqlU8);
        defer gpa.free(a.values);
        const b = try direct.simplify(gpa, eqlU8);
        defer gpa.free(b.values);
        var na: [4]i32 = @splat(0);
        var nb: [4]i32 = @splat(0);
        for (a.values, 0..) |v, i| na[v] += if (i % 2 == 0) 1 else -1;
        for (b.values, 0..) |v, i| nb[v] += if (i % 2 == 0) 1 else -1;
        try t.expectEqual(na, nb);
        try t.expectEqual(a.values.len, b.values.len);
    }
}

test "merge: element equality" {
    const S = Merge(?[]const u8);
    const eql = defaultEql(?[]const u8);
    const vals = [_]?[]const u8{ "x", null, "x" };
    const m: S = .{ .values = &vals };
    try t.expectEqualStrings("x", m.resolveTrivial(.accept, eql).?.?);
    try t.expect(eql(null, null));
    try t.expect(!eql("a", null));
}
