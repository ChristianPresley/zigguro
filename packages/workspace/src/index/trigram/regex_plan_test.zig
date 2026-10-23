//! Regex planning tests: the regexp4 article's table, and a property test
//! that no file `zg_regex` matches is missing from the candidates.

const std = @import("std");
const zg_regex = @import("zg_regex");
const index = @import("index.zig");
const regex_plan = @import("regex_plan.zig");
const FileId = @import("../../ids.zig").FileId;

const gpa = std.testing.allocator;
const io = std.testing.io;

fn plan(a: std.mem.Allocator, pattern: []const u8, ci: bool) ![]const u8 {
    const q = try regex_plan.planPattern(a, pattern, .{ .case_insensitive = ci, .unicode = true }, .{});
    return std.fmt.allocPrint(a, "{f}", .{q});
}

test "trigram: planRegex table" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][3][]const u8{
        .{ "Google.*Search", "", "and(\"goo\" \"oog\" \"ogl\" \"gle\" \"sea\" \"ear\" \"arc\" \"rch\")" },
        .{ "ab[cd]e", "", "or(and(\"abc\" \"bce\") and(\"abd\" \"bde\"))" },
        .{ "(abc|cba)def", "", "or(and(\"abc\" \"bcd\" \"cde\" \"def\") and(\"cba\" \"bad\" \"ade\" \"def\"))" },
        .{ "a+bc", "", "\"abc\"" },
        .{ ".*", "", "all" },
        .{ "a.b", "", "all" },
        .{ "colou?r", "", "or(and(\"col\" \"olo\" \"lou\" \"our\") and(\"col\" \"olo\" \"lor\"))" },
        .{ "(?i)Hello", "", "and(\"hel\" \"ell\" \"llo\")" },
        .{ "hello", "i", "and(\"hel\" \"ell\" \"llo\")" },
        .{ "x*yz", "", "all" },
        .{ "\\bfoo\\b", "", "\"foo\"" },
        .{ "abc(", "", "all" },
    };
    for (cases) |c| {
        const got = try plan(a, c[0], c[1].len > 0);
        std.testing.expectEqualStrings(c[2], got) catch |e| {
            std.debug.print("pattern {s}\n", .{c[0]});
            return e;
        };
    }
}

test "trigram: no false negatives (regex property test)" {
    const ix = try index.TrigramIndex.open(gpa, io, null, .{});
    defer ix.deinit();
    var prng: std.Random.DefaultPrng = .init(0x50fa);
    const r = prng.random();
    const alphabet = "abcAB_ \xc3\xa9";
    var docs: [120][48]u8 = undefined;
    for (&docs, 0..) |*d, i| {
        for (d) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        try ix.add(i, .{ .index = @intCast(i), .gen = 1 }, d);
        if (i % 40 == 39) try ix.flush();
    }
    const rd = try ix.reader();
    defer rd.release();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var buf: [96]u8 = undefined;
    for (0..10_000) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        var w: std.Io.Writer = .fixed(&buf);
        genRegex(r, &w, 0) catch continue;
        const pattern = w.buffered();
        const ci = r.uintLessThan(u8, 4) == 0;
        var re = zg_regex.Regex.compile(gpa, pattern, .{ .case_insensitive = ci }) catch continue;
        defer re.deinit(gpa);
        var cache = try re.newCache(gpa);
        defer cache.deinit();
        const q = try regex_plan.planPattern(a, pattern, .{ .case_insensitive = ci, .unicode = true }, .{});
        const c = try rd.execute(q, gpa);
        defer c.deinit(gpa);
        if (c == .all) continue;
        for (docs, 0..) |doc, i| {
            if (!re.isMatch(&cache, .fromSlice(&doc))) continue;
            const hit = for (c.docs) |d| {
                if (rd.docToFile(d)) |f| if (f.index == i) break true;
            } else false;
            if (!hit) {
                std.debug.print("false negative: doc {d} pattern '{s}' ci={} query {f}\n", .{ i, pattern, ci, q });
                return error.TestUnexpectedResult;
            }
        }
    }
}

/// A random regex from a small grammar over the corpus alphabet.
fn genRegex(r: std.Random, w: *std.Io.Writer, depth: u8) std.Io.Writer.Error!void {
    const n = 1 + r.uintLessThan(u8, 4);
    for (0..n) |_| try genAtom(r, w, depth);
}

fn genAtom(r: std.Random, w: *std.Io.Writer, depth: u8) std.Io.Writer.Error!void {
    switch (r.uintLessThan(u8, if (depth > 2) 4 else 7)) {
        0, 1 => try w.writeAll(([_][]const u8{ "a", "b", "c", "A", "B", "_", " ", "\xc3\xa9", "ab", "bca" })[r.uintLessThan(usize, 10)]),
        2 => try w.writeAll(([_][]const u8{ ".", "[ab]", "[^a]", "[a-c]", "\\w", "[Bb_]" })[r.uintLessThan(usize, 6)]),
        3 => try w.writeAll(([_][]const u8{ "\\b", "^", "$", "" })[r.uintLessThan(usize, 4)]),
        4 => {
            try w.writeByte('(');
            try genRegex(r, w, depth + 1);
            try w.writeByte('|');
            try genRegex(r, w, depth + 1);
            try w.writeByte(')');
        },
        else => {
            try w.writeByte('(');
            try genRegex(r, w, depth + 1);
            try w.writeAll(([_][]const u8{ ")*", ")+", ")?", "){2}", "){1,3}" })[r.uintLessThan(usize, 5)]);
        },
    }
}
