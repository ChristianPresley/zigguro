//! TextMate scope selectors (E04.F08.S02.T01): the `scope` of a theme's
//! `tokenColors` rule. A selector is a comma-separated group of paths; a
//! path is space-separated elements, each a dotted scope prefix
//! (`string.quoted` matches `string.quoted.double.php`), optionally
//! followed by `- path` exclusions.
//!
//! Ranking follows the TextMate manual: a match is scored by the deepest
//! stack position its last element matched, then how many atoms that
//! element has, then the same for the elements before it. Greedy deepest
//! matching from the last element yields the best score.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A match's rank; higher wins, `.none` never matches.
pub const Score = struct {
    /// (stack depth + 1, atoms) per matched element, last element first.
    parts: [max_parts][2]u16 = @splat(.{ 0, 0 }),
    len: u8 = 0,

    pub const none: Score = .{};
    pub const max_parts = 8;

    pub fn matched(s: Score) bool {
        return s.len > 0;
    }

    /// Lexicographic order over the parts; a longer path breaks ties.
    pub fn order(a: Score, b: Score) std.math.Order {
        const n = @min(a.len, b.len);
        for (a.parts[0..n], b.parts[0..n]) |x, y| {
            if (x[0] != y[0]) return std.math.order(x[0], y[0]);
            if (x[1] != y[1]) return std.math.order(x[1], y[1]);
        }
        return std.math.order(a.len, b.len);
    }
};

/// One space-separated path: its elements' atoms, outermost first.
const Path = struct {
    elems: []const []const u8,
};

const Alternative = struct {
    path: Path,
    excludes: []const Path,
};

/// A parsed selector (slices into the arena it was parsed with).
pub const ScopeSelector = struct {
    alts: []const Alternative,

    /// Parses `src` (allocations go to `arena`).
    pub fn parse(arena: Allocator, src: []const u8) Allocator.Error!ScopeSelector {
        var alts: std.ArrayList(Alternative) = .empty;
        var groups = std.mem.splitScalar(u8, src, ',');
        while (groups.next()) |g| {
            // A '-' inside an atom (`meta.tag-name`) is not an exclusion:
            // exclusions are written " - ".
            var main: std.ArrayList(u8) = .empty;
            var excludes: std.ArrayList(Path) = .empty;
            var first = true;
            var rest = g;
            while (true) {
                const at = std.mem.indexOf(u8, rest, " -") orelse std.mem.indexOf(u8, rest, "- ");
                const chunk = if (at) |a| rest[0..a] else rest;
                if (first) {
                    try main.appendSlice(arena, chunk);
                    first = false;
                } else {
                    const p = try parsePath(arena, chunk);
                    if (p.elems.len > 0) try excludes.append(arena, p);
                }
                const a = at orelse break;
                rest = rest[a + 2 ..];
            }
            const path = try parsePath(arena, main.items);
            if (path.elems.len == 0) continue;
            try alts.append(arena, .{ .path = path, .excludes = excludes.items });
        }
        return .{ .alts = alts.items };
    }

    /// The best score of any alternative against `stack` (outermost
    /// first), or `.none`.
    pub fn match(sel: ScopeSelector, stack: []const []const u8) Score {
        var best: Score = .none;
        for (sel.alts) |alt| {
            const s = matchPath(alt.path, stack);
            if (!s.matched()) continue;
            var excluded = false;
            for (alt.excludes) |ex| if (matchPath(ex, stack).matched()) {
                excluded = true;
                break;
            };
            if (excluded) continue;
            if (s.order(best) == .gt) best = s;
        }
        return best;
    }
};

fn parsePath(arena: Allocator, src: []const u8) Allocator.Error!Path {
    var elems: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, src, " \t\r\n");
    while (it.next()) |e| try elems.append(arena, e);
    return .{ .elems = elems.items };
}

/// Whether selector element `sel` is a dotted prefix of `scope`; its atom
/// count when it is.
fn prefixAtoms(sel: []const u8, scope: []const u8) ?u16 {
    if (sel.len > scope.len or !std.mem.startsWith(u8, scope, sel)) return null;
    if (sel.len < scope.len and scope[sel.len] != '.') return null;
    return @intCast(std.mem.count(u8, sel, ".") + 1);
}

fn matchPath(p: Path, stack: []const []const u8) Score {
    var s: Score = .{};
    var limit = stack.len;
    var e = p.elems.len;
    while (e > 0) {
        e -= 1;
        var found = false;
        var i = limit;
        while (i > 0) {
            i -= 1;
            if (prefixAtoms(p.elems[e], stack[i])) |atoms| {
                if (s.len < Score.max_parts) {
                    s.parts[s.len] = .{ @intCast(@min(i + 1, std.math.maxInt(u16))), atoms };
                    s.len += 1;
                }
                limit = i;
                found = true;
                break;
            }
        }
        if (!found) return .none;
    }
    return s;
}

const testing = std.testing;

fn scoreOf(arena: Allocator, sel: []const u8, stack: []const []const u8) !Score {
    return (try ScopeSelector.parse(arena, sel)).match(stack);
}

test "scope selector ranking" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const stack = [_][]const u8{ "text.html.php", "source.php", "string.quoted.double.php" };
    // The deeper match wins: `string` over `source.php`.
    try testing.expectEqual(std.math.Order.gt, (try scoreOf(a, "string", &stack)).order(try scoreOf(a, "source.php", &stack)));
    // A longer match at the same depth wins.
    try testing.expectEqual(std.math.Order.gt, (try scoreOf(a, "string.quoted", &stack)).order(try scoreOf(a, "string", &stack)));
    // Same last element: the path with more matched parents wins.
    try testing.expectEqual(std.math.Order.gt, (try scoreOf(a, "source.php string", &stack)).order(try scoreOf(a, "string", &stack)));
    try testing.expectEqual(std.math.Order.gt, (try scoreOf(a, "text source string", &stack)).order(try scoreOf(a, "text string", &stack)));
    // Atoms match whole: `str` is not `string`.
    try testing.expect(!(try scoreOf(a, "str", &stack)).matched());
    // Descendants must appear in order.
    try testing.expect(!(try scoreOf(a, "string source", &stack)).matched());
    // Groups take the best alternative.
    try testing.expectEqual(std.math.Order.eq, (try scoreOf(a, "comment, string.quoted", &stack)).order(try scoreOf(a, "string.quoted", &stack)));
}

test "scope selector exclusion" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const php = [_][]const u8{ "source.php", "string.quoted.double.php" };
    const js = [_][]const u8{ "source.js", "string.quoted.double.js" };
    try testing.expect(!(try scoreOf(a, "string - source.php", &php)).matched());
    try testing.expect((try scoreOf(a, "string - source.php", &js)).matched());
    // A hyphen inside an atom is part of the name.
    const tag = [_][]const u8{ "text.html", "entity.name.tag-name" };
    try testing.expect((try scoreOf(a, "entity.name.tag-name", &tag)).matched());
}
