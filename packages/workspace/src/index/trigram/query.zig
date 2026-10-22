//! Trigram queries: a boolean tree over trigrams, planned from a literal
//! (and, once E05's zg_regex lands, from a regex HIR), and executed against
//! a reader's posting lists. std only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const segment = @import("segment.zig");
const Trigram = segment.Trigram;

/// A candidate filter. `all` means "every document"; `none` means "no
/// document can match".
pub const Query = union(enum) {
    all,
    none,
    tri: Trigram,
    and_: []const Query,
    or_: []const Query,

    /// Writes the query as `and(tri("abc") ...)` (for tests and logs).
    pub fn format(q: Query, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (q) {
            .all => try w.writeAll("all"),
            .none => try w.writeAll("none"),
            .tri => |t| {
                const b = [3]u8{ @truncate(t >> 16), @truncate(t >> 8), @truncate(t) };
                try w.print("\"{s}\"", .{&b});
            },
            .and_, .or_ => |list| {
                try w.writeAll(if (q == .and_) "and(" else "or(");
                for (list, 0..) |c, i| {
                    if (i > 0) try w.writeByte(' ');
                    try c.format(w);
                }
                try w.writeByte(')');
            },
        }
    }
};

/// The trigrams a literal match must contain. With `case_insensitive`,
/// only runs of ASCII bytes contribute (Unicode case folding can change
/// the bytes of other characters); a run shorter than 3 bytes adds nothing.
pub fn planLiteral(arena: Allocator, lit: []const u8, case_insensitive: bool) !Query {
    var tris: std.ArrayList(Query) = .empty;
    var seen: std.AutoHashMapUnmanaged(Trigram, void) = .empty;
    var start: usize = 0;
    while (start < lit.len) {
        var end = start;
        if (case_insensitive) {
            while (end < lit.len and lit[end] < 0x80) end += 1;
        } else end = lit.len;
        const seg_run = lit[start..end];
        if (seg_run.len >= 3) for (0..seg_run.len - 2) |i| {
            const t = segment.trigramAt(seg_run, i);
            if ((try seen.getOrPut(arena, t)).found_existing) continue;
            try tris.append(arena, .{ .tri = t });
        };
        start = end;
        while (start < lit.len and lit[start] >= 0x80) start += 1;
    }
    return normalize(arena, .{ .and_ = tris.items });
}

/// Flattens nested and/or, drops duplicates and absorbs `all` / `none`.
pub fn normalize(arena: Allocator, q: Query) !Query {
    switch (q) {
        .all, .none, .tri => return q,
        .and_, .or_ => |list| {
            const is_and = q == .and_;
            var out: std.ArrayList(Query) = .empty;
            for (list) |c0| {
                const c = try normalize(arena, c0);
                switch (c) {
                    .all => if (is_and) continue else return .all,
                    .none => if (is_and) return .none else continue,
                    .and_ => |sub| if (is_and) {
                        try appendUnique(arena, &out, sub);
                        continue;
                    },
                    .or_ => |sub| if (!is_and) {
                        try appendUnique(arena, &out, sub);
                        continue;
                    },
                    .tri => {},
                }
                try appendUnique(arena, &out, &.{c});
            }
            if (out.items.len == 0) return if (is_and) .all else .none;
            if (out.items.len == 1) return out.items[0];
            return if (is_and) .{ .and_ = out.items } else .{ .or_ = out.items };
        },
    }
}

fn appendUnique(arena: Allocator, out: *std.ArrayList(Query), items: []const Query) !void {
    outer: for (items) |c| {
        if (c == .tri) for (out.items) |o| if (o == .tri and o.tri == c.tri) continue :outer;
        try out.append(arena, c);
    }
}

/// Query results.
pub const Candidates = union(enum) {
    /// Too unselective (or `all`): scan everything.
    all,
    /// Sorted global doc ids.
    docs: []u32,

    /// Frees `docs`.
    pub fn deinit(c: Candidates, gpa: Allocator) void {
        if (c == .docs) gpa.free(c.docs);
    }
};

/// Above this fraction of documents a candidate list is not worth it.
pub const max_selectivity = 0.30;

/// Runs `q` against `reader`, which provides `docCount() u32`,
/// `count(Trigram) u32` (an upper bound) and
/// `postings(Trigram, *std.ArrayList(u32), Allocator) !void` (sorted ids).
pub fn execute(reader: anytype, q: Query, gpa: Allocator) !Candidates {
    const limit: usize = @intFromFloat(@ceil(@as(f64, @floatFromInt(reader.docCount())) * max_selectivity));
    const r = try run(reader, q, gpa, limit);
    return switch (r) {
        .all => .all,
        .docs => |d| if (d.items.len > limit and limit > 0) blk: {
            var dd = d;
            dd.deinit(gpa);
            break :blk .all;
        } else .{ .docs = try @constCast(&d).toOwnedSlice(gpa) },
    };
}

const Partial = union(enum) { all, docs: std.ArrayList(u32) };

fn run(reader: anytype, q: Query, gpa: Allocator, limit: usize) !Partial {
    switch (q) {
        .all => return .all,
        .none => return .{ .docs = .empty },
        .tri => |t| {
            var out: std.ArrayList(u32) = .empty;
            errdefer out.deinit(gpa);
            try reader.postings(t, &out, gpa);
            return .{ .docs = out };
        },
        .and_ => |list| {
            // Cheapest first: plain trigrams by posting count, then subtrees.
            const order = try gpa.alloc(Ranked, list.len);
            defer gpa.free(order);
            for (list, order) |c, *o| o.* = .{ .q = c, .cost = if (c == .tri) reader.count(c.tri) else std.math.maxInt(u32) };
            std.mem.sort(Ranked, order, {}, Ranked.lt);
            var acc: ?std.ArrayList(u32) = null;
            errdefer if (acc) |*a| a.deinit(gpa);
            for (order) |o| {
                if (acc) |a| if (a.items.len == 0) break;
                var p = try run(reader, o.q, gpa, limit);
                switch (p) {
                    .all => continue,
                    .docs => |*d| {
                        if (acc) |*a| {
                            intersect(a, d.items);
                            d.deinit(gpa);
                        } else acc = d.*;
                    },
                }
            }
            return if (acc) |a| .{ .docs = a } else .all;
        },
        .or_ => |list| {
            var acc: std.ArrayList(u32) = .empty;
            errdefer acc.deinit(gpa);
            for (list) |c| {
                var p = try run(reader, c, gpa, limit);
                switch (p) {
                    .all => {
                        acc.deinit(gpa);
                        return .all;
                    },
                    .docs => |*d| {
                        defer d.deinit(gpa);
                        try unite(&acc, d.items, gpa);
                        if (limit > 0 and acc.items.len > limit) {
                            acc.deinit(gpa);
                            return .all;
                        }
                    },
                }
            }
            return .{ .docs = acc };
        },
    }
}

const Ranked = struct {
    q: Query,
    cost: u32,
    fn lt(_: void, a: Ranked, b: Ranked) bool {
        return a.cost < b.cost;
    }
};

/// `a = a ∩ b` (both sorted), galloping through the longer list.
fn intersect(a: *std.ArrayList(u32), b: []const u32) void {
    var n: usize = 0;
    var j: usize = 0;
    for (a.items) |x| {
        j = gallop(b, j, x);
        if (j == b.len) break;
        if (b[j] == x) {
            a.items[n] = x;
            n += 1;
        }
    }
    a.shrinkRetainingCapacity(n);
}

/// First index >= `from` with `b[i] >= x`.
fn gallop(b: []const u32, from: usize, x: u32) usize {
    var lo = from;
    var step: usize = 1;
    var hi = from;
    while (hi < b.len and b[hi] < x) {
        lo = hi + 1;
        hi += step;
        step *= 2;
    }
    hi = @min(hi, b.len);
    return lo + std.sort.lowerBound(u32, b[lo..hi], x, struct {
        fn cmp(v: u32, e: u32) std.math.Order {
            return std.math.order(v, e);
        }
    }.cmp);
}

/// `a = a ∪ b` (both sorted).
fn unite(a: *std.ArrayList(u32), b: []const u32, gpa: Allocator) !void {
    if (b.len == 0) return;
    const old = try gpa.dupe(u32, a.items);
    defer gpa.free(old);
    a.clearRetainingCapacity();
    try a.ensureTotalCapacity(gpa, old.len + b.len);
    var i: usize = 0;
    var j: usize = 0;
    while (i < old.len or j < b.len) {
        if (j == b.len or (i < old.len and old[i] < b[j])) {
            a.appendAssumeCapacity(old[i]);
            i += 1;
        } else if (i == old.len or b[j] < old[i]) {
            a.appendAssumeCapacity(b[j]);
            j += 1;
        } else {
            a.appendAssumeCapacity(old[i]);
            i += 1;
            j += 1;
        }
    }
}

const TestReader = struct {
    docs: []const []const u8,
    fn docCount(r: *const TestReader) u32 {
        return @intCast(r.docs.len);
    }
    fn count(r: *const TestReader, t: Trigram) u32 {
        var n: u32 = 0;
        for (r.docs) |d| n += @intFromBool(has(d, t));
        return n;
    }
    fn postings(r: *const TestReader, t: Trigram, out: *std.ArrayList(u32), gpa: Allocator) !void {
        for (r.docs, 0..) |d, i| if (has(d, t)) try out.append(gpa, @intCast(i));
    }
    fn has(d: []const u8, t: Trigram) bool {
        if (d.len < 3) return false;
        for (0..d.len - 2) |i| if (segment.trigramAt(d, i) == t) return true;
        return false;
    }
};

fn expectPlan(want: []const u8, q: Query) !void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try q.format(&w);
    try std.testing.expectEqualStrings(want, w.buffered());
}

test "trigram: planLiteral" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectPlan("all", try planLiteral(a, "ab", false));
    try expectPlan("\"abc\"", try planLiteral(a, "ABC", false));
    try expectPlan("and(\"aba\" \"bab\")", try planLiteral(a, "ababab", false));
    // Case-insensitive: the non-ASCII run splits the literal.
    try expectPlan("and(\"caf\" \"bar\")", try planLiteral(a, "caf\u{E9}bar", true));
    try expectPlan("all", try planLiteral(a, "\u{E9}\u{E9}", true));
    try expectPlan("and(\"caf\" \"af\xc3\" \"f\xc3\xa9\" \"\xc3\xa9b\" \"\xa9ba\" \"bar\")", try planLiteral(a, "caf\u{E9}bar", false));
}

test "trigram: normalize absorbs all and none" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Query = .{ .tri = segment.trigramAt("abc", 0) };
    try expectPlan("\"abc\"", try normalize(a, .{ .and_ = &.{ .all, t, t } }));
    try expectPlan("none", try normalize(a, .{ .and_ = &.{ .none, t } }));
    try expectPlan("all", try normalize(a, .{ .or_ = &.{ .all, t } }));
    try expectPlan("\"abc\"", try normalize(a, .{ .or_ = &.{ .none, .{ .and_ = &.{t} } } }));
}

test "trigram: execute and/or with selectivity cutoff" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var docs: [20][]const u8 = @splat("nothing here");
    docs[3] = "hello world";
    docs[7] = "help me";
    docs[11] = "yellow world";
    const r: TestReader = .{ .docs = &docs };
    const hel = try execute(&r, try planLiteral(arena.allocator(), "hello", false), gpa);
    defer hel.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &.{3}, hel.docs);
    const q: Query = .{ .or_ = &.{ try planLiteral(arena.allocator(), "help", false), try planLiteral(arena.allocator(), "world", false) } };
    const c = try execute(&r, q, gpa);
    defer c.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &.{ 3, 7, 11 }, c.docs);
    const common = try execute(&r, try planLiteral(arena.allocator(), "here", false), gpa);
    try std.testing.expect(common == .all);
    const none = try execute(&r, try planLiteral(arena.allocator(), "zzzz", false), gpa);
    defer none.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), none.docs.len);
}

test "trigram: intersect and unite" {
    const gpa = std.testing.allocator;
    var a: std.ArrayList(u32) = .empty;
    defer a.deinit(gpa);
    try a.appendSlice(gpa, &.{ 1, 3, 5, 7, 9, 100 });
    intersect(&a, &.{ 0, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14, 100, 200 });
    try std.testing.expectEqualSlices(u32, &.{ 3, 5, 9, 100 }, a.items);
    try unite(&a, &.{ 0, 5, 101 }, gpa);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 5, 9, 100, 101 }, a.items);
}
