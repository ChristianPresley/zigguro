//! Regex query planning (Russ Cox, "Regular Expression Matching with a
//! Trigram Index"): a bottom-up walk of a `zg_regex` HIR computing, per
//! node, whether it can match the empty string, its exact match set (when
//! small), prefix and suffix sets, and a `match` query every match
//! satisfies. Information is moved into `match` before a set is dropped
//! or trimmed, so the planned query never excludes a matching document.
//! Strings are ASCII-lowercased, as the postings are.

const std = @import("std");
const zg_regex = @import("zg_regex");
const segment = @import("segment.zig");
const query = @import("query.zig");

const Allocator = std.mem.Allocator;
const Hir = zg_regex.syntax.hir.Hir;
const Query = query.Query;

pub const PlanOptions = struct {
    /// Exact sets larger than this are dropped (into prefix/suffix).
    max_exact: usize = 16,
    /// Prefix/suffix sets larger than this are trimmed.
    max_set: usize = 64,
    /// Classes up to this many code points expand to exact sets.
    max_class: usize = 8,
};

/// The trigram query for `hir`.
pub fn planRegex(arena: Allocator, hir: *const Hir, opts: PlanOptions) !Query {
    var p: Planner = .{ .a = arena, .o = opts };
    const info = try p.walk(hir);
    return absorb(arena, try query.normalize(arena, try p.full(info)));
}

/// Drops an `or` under an `and` when one of its alternatives only needs
/// trigrams the `and` already requires (the `or` is then implied).
fn absorb(a: Allocator, q: Query) !Query {
    switch (q) {
        .all, .none, .tri => return q,
        .or_ => |list| {
            const out = try a.alloc(Query, list.len);
            for (list, out) |c, *o| o.* = try absorb(a, c);
            return .{ .or_ = out };
        },
        .and_ => |list| {
            var out: std.ArrayList(Query) = .empty;
            for (list) |c0| {
                const c = try absorb(a, c0);
                if (c == .or_) {
                    const implied = for (c.or_) |alt| {
                        if (impliedBy(alt, list)) break true;
                    } else false;
                    if (implied) continue;
                }
                try out.append(a, c);
            }
            if (out.items.len == 1) return out.items[0];
            return .{ .and_ = out.items };
        },
    }
}

/// Whether every trigram `alt` needs is a direct trigram of `list`.
fn impliedBy(alt: Query, list: []const Query) bool {
    const need: []const Query = switch (alt) {
        .tri => (&alt)[0..1],
        .and_ => |l| l,
        else => return false,
    };
    for (need) |n| {
        if (n != .tri) return false;
        const found = for (list) |x| {
            if (x == .tri and x.tri == n.tri) break true;
        } else false;
        if (!found) return false;
    }
    return true;
}

/// Parses `pattern` (with zg_regex's syntax and flags) and plans it.
/// A pattern that does not parse plans to `.all` (the search reports the
/// error; the index never hides a document).
pub fn planPattern(arena: Allocator, pattern: []const u8, flags: zg_regex.syntax.ast.Flags, opts: PlanOptions) !Query {
    const ast = switch (try zg_regex.syntax.parse.parse(arena, pattern, .{ .ignore_whitespace = flags.ignore_whitespace })) {
        .ok => |x| x,
        .err => return .all,
    };
    const h = switch (try zg_regex.syntax.translate.translate(arena, ast, flags)) {
        .ok => |x| x,
        .err => return .all,
    };
    return planRegex(arena, h, opts);
}

/// A set of folded strings; null exact means "unknown".
const Set = []const []const u8;

const Info = struct {
    emptyable: bool,
    exact: ?Set,
    prefix: Set,
    suffix: Set,
    match: Query,
};

const empty_str: Set = &.{""};

const Planner = struct {
    a: Allocator,
    o: PlanOptions,

    fn anyChar() Info {
        return .{ .emptyable = false, .exact = null, .prefix = empty_str, .suffix = empty_str, .match = .all };
    }

    fn anything() Info {
        return .{ .emptyable = true, .exact = null, .prefix = empty_str, .suffix = empty_str, .match = .all };
    }

    fn exactInfo(s: Set) Info {
        var emptyable = false;
        for (s) |x| if (x.len == 0) {
            emptyable = true;
        };
        return .{ .emptyable = emptyable, .exact = s, .prefix = s, .suffix = s, .match = .all };
    }

    fn walk(p: *Planner, h: *const Hir) error{OutOfMemory}!Info {
        return switch (h.*) {
            .empty, .look => exactInfo(empty_str),
            .literal => |b| exactInfo(try p.one(b)),
            .class_unicode => |s| p.unicodeClass(s),
            .class_bytes => |s| p.byteClass(s),
            .capture => |c| p.walk(c.sub),
            .repetition => |r| p.repeat(r.min, r.max, try p.walk(r.sub)),
            .concat => |items| blk: {
                var acc = exactInfo(empty_str);
                for (items) |it| acc = try p.concat(acc, try p.walk(it));
                break :blk acc;
            },
            .alternation => |items| blk: {
                if (items.len == 0) break :blk .{ .emptyable = false, .exact = &.{}, .prefix = &.{}, .suffix = &.{}, .match = .none };
                var acc = try p.walk(items[0]);
                for (items[1..]) |it| acc = try p.alternate(acc, try p.walk(it));
                break :blk acc;
            },
        };
    }

    fn one(p: *Planner, b: []const u8) !Set {
        const s = try p.a.alloc([]const u8, 1);
        s[0] = try p.folded(b);
        return s;
    }

    fn folded(p: *Planner, b: []const u8) ![]const u8 {
        const out = try p.a.alloc(u8, b.len);
        for (b, out) |c, *o| o.* = segment.fold(c);
        return out;
    }

    fn unicodeClass(p: *Planner, s: zg_regex.syntax.hir.RangeSet) !Info {
        var n: usize = 0;
        for (s.ranges) |r| n += @as(usize, r[1]) - r[0] + 1;
        if (n == 0) return .{ .emptyable = false, .exact = &.{}, .prefix = &.{}, .suffix = &.{}, .match = .none };
        if (n > p.o.max_class) return anyChar();
        var out: std.ArrayList([]const u8) = .empty;
        for (s.ranges) |r| {
            var c: u21 = r[0];
            while (true) : (c += 1) {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &buf) catch return anyChar();
                try addUnique(p.a, &out, try p.folded(buf[0..len]));
                if (c == r[1]) break;
            }
        }
        return exactInfo(out.items);
    }

    fn byteClass(p: *Planner, s: zg_regex.syntax.hir.ByteSet) !Info {
        const n = s.bits.count();
        if (n == 0) return .{ .emptyable = false, .exact = &.{}, .prefix = &.{}, .suffix = &.{}, .match = .none };
        if (n > p.o.max_class) return anyChar();
        var out: std.ArrayList([]const u8) = .empty;
        var it = s.bits.iterator(.{});
        while (it.next()) |b| {
            const c: u8 = @intCast(b);
            try addUnique(p.a, &out, try p.folded(&.{c}));
        }
        return exactInfo(out.items);
    }

    fn repeat(p: *Planner, min: u32, max: ?u32, x: Info) !Info {
        if (min == 1 and max != null and max.? == 1) return x;
        if (max != null and max.? == 0) return exactInfo(empty_str);
        if (min == 0) {
            // x? keeps a small exact set (`colou?r`); x* knows nothing.
            if (max != null and max.? == 1) if (x.exact) |e| return exactInfo(try union_(p.a, e, empty_str));
            return anything();
        }
        // x+ and x{n,m} with n >= 1: every match contains a match of x,
        // starts with a prefix of x and ends with a suffix of x.
        return p.simplify(.{ .emptyable = x.emptyable, .exact = null, .prefix = pre(x), .suffix = suf(x), .match = try p.full(x) });
    }

    fn concat(p: *Planner, x: Info, y: Info) !Info {
        var match = try and2(p.a, x.match, y.match);
        var exact: ?Set = null;
        if (x.exact != null and y.exact != null) {
            const ex = x.exact.?;
            const ey = y.exact.?;
            if (ex.len * ey.len <= p.o.max_exact) {
                exact = try cross(p.a, ex, ey);
            } else {
                // Save what the exact sets knew before dropping them.
                match = try and2(p.a, match, try and2(p.a, try p.trigrams(ex), try p.trigrams(ey)));
            }
        } else {
            if (x.exact) |e| match = try and2(p.a, match, try p.trigrams(e));
            if (y.exact) |e| match = try and2(p.a, match, try p.trigrams(e));
        }
        if (exact) |e| return p.simplify(.{ .emptyable = x.emptyable and y.emptyable, .exact = e, .prefix = e, .suffix = e, .match = match });
        const prefix: Set = if (x.exact) |e|
            (if (e.len * pre(y).len <= p.o.max_set) try cross(p.a, e, pre(y)) else e)
        else if (x.emptyable) try union_(p.a, x.prefix, pre(y)) else x.prefix;
        const suffix: Set = if (y.exact) |e|
            (if (suf(x).len * e.len <= p.o.max_set) try cross(p.a, suf(x), e) else e)
        else if (y.emptyable) try union_(p.a, suf(x), y.suffix) else y.suffix;
        return p.simplify(.{ .emptyable = x.emptyable and y.emptyable, .exact = null, .prefix = prefix, .suffix = suffix, .match = match });
    }

    fn alternate(p: *Planner, x: Info, y: Info) !Info {
        if (x.exact != null and y.exact != null) {
            const u = try union_(p.a, x.exact.?, y.exact.?);
            if (u.len <= p.o.max_exact) return .{ .emptyable = x.emptyable or y.emptyable, .exact = u, .prefix = u, .suffix = u, .match = try or2(p.a, x.match, y.match) };
        }
        return p.simplify(.{
            .emptyable = x.emptyable or y.emptyable,
            .exact = null,
            .prefix = try union_(p.a, pre(x), pre(y)),
            .suffix = try union_(p.a, suf(x), suf(y)),
            .match = try or2(p.a, try p.full(x), try p.full(y)),
        });
    }

    /// Caps the sets: an exact set too big becomes prefix/suffix; prefix
    /// and suffix sets too big have their trigrams saved and are trimmed
    /// to two bytes (so later concatenation can still form trigrams).
    fn simplify(p: *Planner, in: Info) !Info {
        var x = in;
        if (x.exact) |e| if (e.len > p.o.max_exact) {
            x.match = try and2(p.a, x.match, try p.trigrams(e));
            x.prefix = e;
            x.suffix = e;
            x.exact = null;
        };
        if (x.exact != null) return x;
        if (x.prefix.len > p.o.max_set or longest(x.prefix) > 64) {
            x.match = try and2(p.a, x.match, try p.trigrams(x.prefix));
            x.prefix = try trim(p.a, x.prefix, false);
            if (x.prefix.len > p.o.max_set) x.prefix = empty_str;
        }
        if (x.suffix.len > p.o.max_set or longest(x.suffix) > 64) {
            x.match = try and2(p.a, x.match, try p.trigrams(x.suffix));
            x.suffix = try trim(p.a, x.suffix, true);
            if (x.suffix.len > p.o.max_set) x.suffix = empty_str;
        }
        return x;
    }

    /// Everything known about a match of `x` as a query.
    fn full(p: *Planner, x: Info) !Query {
        if (x.exact) |e| return and2(p.a, x.match, try p.trigrams(e));
        return and2(p.a, x.match, try and2(p.a, try p.trigrams(x.prefix), try p.trigrams(x.suffix)));
    }

    /// OR over the strings of AND over each string's trigrams (a string
    /// shorter than 3 bytes makes it `all`; an empty set is `none`).
    fn trigrams(p: *Planner, s: Set) !Query {
        var alts: std.ArrayList(Query) = .empty;
        for (s) |str| {
            if (str.len < 3) return .all;
            const tris = try p.a.alloc(Query, str.len - 2);
            for (tris, 0..) |*t, i| t.* = .{ .tri = segment.trigramAt(str, i) };
            try alts.append(p.a, .{ .and_ = tris });
        }
        return .{ .or_ = alts.items };
    }
};

fn pre(x: Info) Set {
    return x.exact orelse x.prefix;
}

fn suf(x: Info) Set {
    return x.exact orelse x.suffix;
}

fn longest(s: Set) usize {
    var n: usize = 0;
    for (s) |x| n = @max(n, x.len);
    return n;
}

fn and2(a: Allocator, x: Query, y: Query) !Query {
    if (x == .all) return y;
    if (y == .all) return x;
    const l = try a.alloc(Query, 2);
    l[0] = x;
    l[1] = y;
    return .{ .and_ = l };
}

fn or2(a: Allocator, x: Query, y: Query) !Query {
    if (x == .all or y == .all) return .all;
    const l = try a.alloc(Query, 2);
    l[0] = x;
    l[1] = y;
    return .{ .or_ = l };
}

fn addUnique(a: Allocator, out: *std.ArrayList([]const u8), s: []const u8) !void {
    for (out.items) |x| if (std.mem.eql(u8, x, s)) return;
    try out.append(a, s);
}

fn union_(a: Allocator, x: Set, y: Set) !Set {
    var out: std.ArrayList([]const u8) = .empty;
    for (x) |s| try addUnique(a, &out, s);
    for (y) |s| try addUnique(a, &out, s);
    return out.items;
}

fn cross(a: Allocator, x: Set, y: Set) !Set {
    var out: std.ArrayList([]const u8) = .empty;
    for (x) |s| for (y) |t| try addUnique(a, &out, try std.mem.concat(a, u8, &.{ s, t }));
    return out.items;
}

/// Prefixes keep their first two bytes, suffixes their last two.
fn trim(a: Allocator, s: Set, keep_end: bool) !Set {
    var out: std.ArrayList([]const u8) = .empty;
    for (s) |x| {
        const t = if (x.len <= 2) x else if (keep_end) x[x.len - 2 ..] else x[0..2];
        try addUnique(a, &out, t);
    }
    return out.items;
}
