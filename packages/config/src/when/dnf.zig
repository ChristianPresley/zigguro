//! Disjunctive normal form of when-clauses for keybinding conflict analysis
//! (E15.F04.S03.T01): negations pushed down, AND distributed over OR, capped
//! at `max_terms`. `mayOverlap` is conservative: it returns false only when
//! the two clauses can provably never be true at the same time.

const std = @import("std");
const when = @import("when.zig");

const Allocator = std.mem.Allocator;
const Expr = when.Expr;

/// One literal of a DNF term.
pub const Literal = struct {
    key: []const u8,
    kind: Kind,
    /// Comparison value (for eq/ne/intervals).
    value: []const u8 = "",

    /// Literal kinds. `opaque` (regex, `in`) never contradicts anything.
    pub const Kind = enum { truthy, falsy, eq, ne, lt, le, gt, ge, @"opaque" };
};

/// An OR of ANDs. With `truncated`, the form over-approximates the clause.
pub const Dnf = struct {
    terms: []const []const Literal,
    truncated: bool,
    /// The clause is constant false (no terms) or constant true (one empty term).
    pub fn isFalse(d: Dnf) bool {
        return d.terms.len == 0 and !d.truncated;
    }
};

/// The DNF of `w` in `arena`, with at most `max_terms` terms (≤ 64).
pub fn toDnf(arena: Allocator, w: *const when.When, max_terms: u16) error{OutOfMemory}!Dnf {
    var b: Builder = .{ .a = arena, .max = @min(max_terms, 64) };
    const terms = try b.build(w.ast, false);
    return .{ .terms = terms, .truncated = b.truncated };
}

/// The DNF of the always-true clause (a binding with no `when`).
pub const always: Dnf = .{ .terms = &.{&.{}}, .truncated = false };

const Builder = struct {
    a: Allocator,
    max: u16,
    truncated: bool = false,

    const Terms = []const []const Literal;

    fn build(b: *Builder, e: *const Expr, neg: bool) error{OutOfMemory}!Terms {
        switch (e.*) {
            .true, .false => {
                const t = (e.* == .true) != neg;
                return if (t) b.one(&.{}) else &.{};
            },
            .key => |k| return b.one(&.{.{ .key = k.name, .kind = if (neg) .falsy else .truthy }}),
            .not => |inner| return b.build(inner, !neg),
            .@"and", .@"or" => |pair| {
                const is_and = (e.* == .@"and") != neg;
                const l = try b.build(pair[0], neg);
                const r = try b.build(pair[1], neg);
                return if (is_and) b.product(l, r) else b.sum(l, r);
            },
            .cmp => |c| {
                const kind: Literal.Kind = switch (c.op) {
                    .eq => if (neg) .ne else .eq,
                    .ne => if (neg) .eq else .ne,
                    .lt => if (neg) .ge else .lt,
                    .le => if (neg) .gt else .le,
                    .gt => if (neg) .le else .gt,
                    .ge => if (neg) .lt else .ge,
                };
                return b.one(&.{.{ .key = c.key.name, .kind = kind, .value = c.lit }});
            },
            .match => |m| return b.one(&.{.{ .key = m.key.name, .kind = .@"opaque" }}),
            .in => |x| return b.one(&.{.{ .key = x.key.name, .kind = .@"opaque" }}),
        }
    }

    fn one(b: *Builder, lits: []const Literal) !Terms {
        const t = try b.a.dupe(Literal, lits);
        const out = try b.a.alloc([]const Literal, 1);
        out[0] = t;
        return out;
    }

    fn sum(b: *Builder, l: Terms, r: Terms) !Terms {
        var out: std.ArrayList([]const Literal) = .empty;
        for ([_]Terms{ l, r }) |side| for (side) |t| {
            if (out.items.len >= b.max) {
                b.truncated = true;
                break;
            }
            try out.append(b.a, t);
        };
        return out.items;
    }

    fn product(b: *Builder, l: Terms, r: Terms) !Terms {
        var out: std.ArrayList([]const Literal) = .empty;
        for (l) |x| for (r) |y| {
            if (out.items.len >= b.max) {
                // Dropping terms would under-approximate; keep one
                // conservative term (the left literals only) instead.
                b.truncated = true;
                break;
            }
            const t = try b.a.alloc(Literal, x.len + y.len);
            @memcpy(t[0..x.len], x);
            @memcpy(t[x.len..], y);
            try out.append(b.a, t);
        };
        return out.items;
    }
};

/// False only if the clauses are provably disjoint. A truncated form always
/// may overlap.
pub fn mayOverlap(a: Dnf, b: Dnf) bool {
    if (a.truncated or b.truncated) return true;
    for (a.terms) |ta| for (b.terms) |tb| {
        if (!contradicts(ta, tb)) return true;
    };
    return false;
}

fn falsyLiteral(v: []const u8) bool {
    return v.len == 0 or std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0");
}

/// Whether the conjunction of `x` and `y` is unsatisfiable.
fn contradicts(x: []const Literal, y: []const Literal) bool {
    const all = [_][]const Literal{ x, y };
    for (all) |s1| for (s1) |p| for (all) |s2| for (s2) |q| {
        if (!std.mem.eql(u8, p.key, q.key)) continue;
        if (pairContradicts(p, q)) return true;
    };
    // Numeric intervals per key.
    for (all) |s1| for (s1) |p| {
        var lo: f64 = -std.math.inf(f64);
        var hi: f64 = std.math.inf(f64);
        var lo_open = false;
        var hi_open = false;
        for (all) |s2| for (s2) |q| {
            if (!std.mem.eql(u8, p.key, q.key)) continue;
            const n = std.fmt.parseFloat(f64, q.value) catch continue;
            switch (q.kind) {
                .gt, .ge => if (n > lo or (n == lo and q.kind == .gt)) {
                    lo = n;
                    lo_open = q.kind == .gt;
                },
                .lt, .le => if (n < hi or (n == hi and q.kind == .lt)) {
                    hi = n;
                    hi_open = q.kind == .lt;
                },
                .eq => {
                    if (n > lo or (n == lo and lo_open)) {
                        lo = n;
                        lo_open = false;
                    }
                    if (n < hi or (n == hi and hi_open)) {
                        hi = n;
                        hi_open = false;
                    }
                },
                else => {},
            }
        };
        if (lo > hi or (lo == hi and (lo_open or hi_open))) return true;
    };
    return false;
}

fn pairContradicts(p: Literal, q: Literal) bool {
    return switch (p.kind) {
        .truthy => q.kind == .falsy or (q.kind == .eq and falsyLiteral(q.value)),
        .falsy => q.kind == .truthy or (q.kind == .eq and !falsyLiteral(q.value)),
        .eq => switch (q.kind) {
            .eq => !std.mem.eql(u8, p.value, q.value),
            .ne => std.mem.eql(u8, p.value, q.value),
            else => false,
        },
        else => false,
    };
}

const testing = std.testing;
const diag = @import("../diag.zig");

fn overlap(a: []const u8, b: []const u8) !bool {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d = diag.Diags.init(testing.allocator);
    defer d.deinit();
    var wa = try when.When.compile(testing.allocator, a, null, &d);
    defer wa.deinit();
    var wb = try when.When.compile(testing.allocator, b, null, &d);
    defer wb.deinit();
    return mayOverlap(try toDnf(arena.allocator(), &wa, 64), try toDnf(arena.allocator(), &wb, 64));
}

test "dnf: shape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d = diag.Diags.init(testing.allocator);
    defer d.deinit();
    var w = try when.When.compile(testing.allocator, "(a || b) && !(c || d)", null, &d);
    defer w.deinit();
    const f = try toDnf(arena.allocator(), &w, 64);
    try testing.expectEqual(@as(usize, 2), f.terms.len);
    try testing.expectEqual(@as(usize, 3), f.terms[0].len);
    try testing.expectEqual(Literal.Kind.falsy, f.terms[0][1].kind);
}

test "dnf: contradictions" {
    try testing.expect(!try overlap("editorTextFocus", "!editorTextFocus"));
    try testing.expect(!try overlap("vim.mode == normal", "vim.mode == insert"));
    try testing.expect(!try overlap("vim.mode == normal", "vim.mode != normal"));
    try testing.expect(!try overlap("a && b", "!a || !b"));
    try testing.expect(!try overlap("lang == zig", "!lang"));
    try testing.expect(try overlap("a", "b"));
    try testing.expect(try overlap("a || c", "!a"));
    try testing.expect(try overlap("vim.mode == normal", "vim.mode != insert"));
    try testing.expect(try overlap("x =~ /a/", "!x"));
}

test "dnf: intervals" {
    try testing.expect(!try overlap("n > 3", "n < 2"));
    try testing.expect(!try overlap("n >= 3", "n < 3"));
    try testing.expect(try overlap("n >= 3", "n <= 3"));
    try testing.expect(!try overlap("n == 1", "n > 1"));
    try testing.expect(try overlap("n > 1", "m < 0"));
}

test "dnf: truncation conservative" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d = diag.Diags.init(testing.allocator);
    defer d.deinit();
    var w = try when.When.compile(testing.allocator, "(a||b) && (c||d) && (e||f) && (g||h) && (i||j) && (k||l) && (m||n)", null, &d);
    defer w.deinit();
    const f = try toDnf(arena.allocator(), &w, 64);
    try testing.expect(f.truncated);
    try testing.expect(mayOverlap(f, .{ .terms = &.{}, .truncated = false }));
}
