//! Prefix literal extraction: a finite set of byte strings such that every
//! match starts with one of them, used to pick a prefilter.
//!
//! Each literal is either exact (it is a whole match of its branch) or a
//! strict prefix; once every literal is inexact, concatenation stops
//! extending. Small classes expand into their members; a repetition that can
//! be skipped contributes the empty string, which disables prefiltering. The
//! set is capped (count and length) so extraction stays cheap.

const std = @import("std");
const hir_mod = @import("../syntax/hir.zig");

const Allocator = std.mem.Allocator;
const Hir = hir_mod.Hir;

/// Maximum number of literals in a set.
pub const max_count = 64;
/// Maximum literal length; longer prefixes are truncated (and inexact).
pub const max_len = 32;
/// Classes with at most this many members are expanded.
pub const max_class = 16;

/// One literal.
pub const Lit = struct { bytes: []const u8, exact: bool };

/// A literal set, or null for "unknown" (anything can start a match).
pub const Seq = ?[]Lit;

/// Extracts the prefix literals of `h` into `arena`.
pub fn prefixes(arena: Allocator, h: *const Hir) Allocator.Error!Seq {
    switch (h.*) {
        .empty, .look => return try one(arena, "", true),
        .literal => |b| {
            if (b.len > max_len) return try one(arena, b[0..max_len], false);
            return try one(arena, b, true);
        },
        .class_bytes => |set| {
            if (set.count() > max_class) return null;
            var out: std.ArrayList(Lit) = .empty;
            for (0..256) |b| if (set.contains(@intCast(b))) {
                try out.append(arena, .{ .bytes = try arena.dupe(u8, &.{@intCast(b)}), .exact = true });
            };
            return out.items;
        },
        .class_unicode => |set| {
            if (set.count() > max_class) return null;
            var out: std.ArrayList(Lit) = .empty;
            for (set.ranges) |r| {
                var cp = r[0];
                while (true) : (cp += 1) {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
                    try out.append(arena, .{ .bytes = try arena.dupe(u8, buf[0..n]), .exact = true });
                    if (cp == r[1]) break;
                }
            }
            return out.items;
        },
        .capture => |c| return prefixes(arena, c.sub),
        .alternation => |items| {
            var out: std.ArrayList(Lit) = .empty;
            for (items) |it| {
                const s = (try prefixes(arena, it)) orelse return null;
                try out.appendSlice(arena, s);
                if (out.items.len > max_count) return null;
            }
            return out.items;
        },
        .repetition => |r| {
            if (r.min == 0) return try one(arena, "", false);
            const s = (try prefixes(arena, r.sub)) orelse return null;
            if (r.min == 1 and r.max != null and r.max.? == 1) return s;
            for (s) |*l| l.exact = false;
            return s;
        },
        .concat => |items| {
            var acc: []Lit = try one(arena, "", true);
            for (items) |it| {
                var any_exact = false;
                for (acc) |l| any_exact = any_exact or l.exact;
                if (!any_exact) break;
                const s = (try prefixes(arena, it)) orelse {
                    for (acc) |*l| l.exact = false;
                    break;
                };
                var out: std.ArrayList(Lit) = .empty;
                var overflow = false;
                for (acc) |a| {
                    if (!a.exact) {
                        try out.append(arena, a);
                        continue;
                    }
                    for (s) |b| {
                        var bytes = try std.mem.concat(arena, u8, &.{ a.bytes, b.bytes });
                        var exact = b.exact;
                        if (bytes.len > max_len) {
                            bytes = bytes[0..max_len];
                            exact = false;
                        }
                        try out.append(arena, .{ .bytes = bytes, .exact = exact });
                    }
                    if (out.items.len > max_count) {
                        overflow = true;
                        break;
                    }
                }
                if (overflow) {
                    for (acc) |*l| l.exact = false;
                    break;
                }
                acc = out.items;
            }
            return acc;
        },
    }
}

fn one(arena: Allocator, bytes: []const u8, exact: bool) Allocator.Error![]Lit {
    const s = try arena.alloc(Lit, 1);
    s[0] = .{ .bytes = bytes, .exact = exact };
    return s;
}

/// The distinct byte strings of `seq`, or null when the set cannot serve as
/// a prefilter (unknown, or containing the empty string).
pub fn prefilterLiterals(arena: Allocator, seq: Seq) Allocator.Error!?[]const []const u8 {
    const lits = seq orelse return null;
    var out: std.ArrayList([]const u8) = .empty;
    for (lits) |l| {
        if (l.bytes.len == 0) return null;
        for (out.items) |o| {
            if (std.mem.eql(u8, o, l.bytes)) break;
        } else try out.append(arena, l.bytes);
    }
    if (out.items.len == 0) return null;
    // A literal that is a prefix of another makes the longer one redundant
    // for finding candidate starts.
    var kept: std.ArrayList([]const u8) = .empty;
    for (out.items, 0..) |l, i| {
        const redundant = for (out.items, 0..) |o, j| {
            if (j != i and o.len < l.len and std.mem.startsWith(u8, l, o)) break true;
        } else false;
        if (!redundant) try kept.append(arena, l);
    }
    return kept.items;
}

test "literal_extract: prefixes" {
    const parse = @import("../syntax/parse.zig");
    const translate = @import("../syntax/translate.zig");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { []const u8, ?[]const []const u8 };
    const cases = [_]Case{
        .{ "foo", &.{"foo"} },
        .{ "foo|bar", &.{ "foo", "bar" } },
        .{ "fo[ox]bar", &.{ "foobar", "foxbar" } },
        .{ "foo\\w+", &.{"foo"} },
        .{ "\\bfoo\\b", &.{"foo"} },
        .{ "(?i)ab", &.{ "AB", "Ab", "aB", "ab" } },
        .{ "a*b", null },
        .{ "\\w+", null },
        .{ "(foo|ba)r", &.{ "foor", "bar" } },
        .{ "x{2,}y", &.{"x"} },
    };
    for (cases) |c| {
        const a = (try parse.parse(arena, c[0], .{})).ok;
        const h = (try translate.translate(arena, a, .{ .unicode = true })).ok;
        const lits = try prefilterLiterals(arena, try prefixes(arena, h));
        if (c[1]) |want| {
            const got = lits orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(want.len, got.len);
            for (want) |w| {
                for (got) |g| {
                    if (std.mem.eql(u8, g, w)) break;
                } else {
                    std.debug.print("{s}: missing {s}\n", .{ c[0], w });
                    return error.TestUnexpectedResult;
                }
            }
        } else try std.testing.expect(lits == null);
    }
}
