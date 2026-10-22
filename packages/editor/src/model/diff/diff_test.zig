//! Diff tests: script validity for every algorithm, minimality against an
//! LCS table, patience and histogram examples, deadlines, whitespace modes,
//! hunks and unified output, plus the fuzz target.

const std = @import("std");
const diff = @import("../diff.zig");
const script = @import("script.zig");
const patience_mod = @import("patience.zig");

const gpa = std.testing.allocator;
const algorithms = [_]diff.Algorithm{ .myers, .minimal, .patience, .histogram };

fn lcsLen(a: []const u32, b: []const u32) !usize {
    const row = try gpa.alloc(usize, b.len + 1);
    defer gpa.free(row);
    @memset(row, 0);
    for (a) |x| {
        var diag: usize = 0;
        for (b, 0..) |y, j| {
            const up = row[j + 1];
            row[j + 1] = if (x == y) diag + 1 else @max(row[j + 1], row[j]);
            diag = up;
        }
    }
    return row[b.len];
}

fn checkAll(a: []const u32, b: []const u32) !void {
    for (algorithms) |alg| {
        const e = try diff.diffTokens(gpa, a, b, alg, null);
        defer gpa.free(e);
        if (!script.validate(e, a, b)) {
            std.debug.print("invalid script for {t}\n", .{alg});
            return error.TestUnexpectedResult;
        }
        if (alg == .minimal) try std.testing.expectEqual(try lcsLen(a, b), script.equalCount(e));
    }
}

fn Source(comptime T: type) type {
    return struct {
        inner: T,
        fn pick(s: *@This(), n: usize) usize {
            if (n <= 1) return 0;
            if (T == std.Random) return s.inner.uintLessThan(usize, n);
            return s.inner.index(n);
        }
    };
}

fn randomPair(src: anytype, a: []u32, b: []u32) struct { []u32, []u32 } {
    const alpha = 1 + src.pick(8);
    const na = src.pick(a.len + 1);
    for (a[0..na]) |*x| x.* = @intCast(src.pick(alpha));
    // b: a mutated copy, so there is structure to find.
    var nb: usize = 0;
    var i: usize = 0;
    while (nb < b.len and (i < na or src.pick(4) == 0)) {
        switch (src.pick(5)) {
            0 => i += 1,
            1 => {
                b[nb] = @intCast(src.pick(alpha));
                nb += 1;
            },
            else => if (i < na) {
                b[nb] = a[i];
                nb += 1;
                i += 1;
            },
        }
        if (i >= na and src.pick(3) == 0) break;
    }
    return .{ a[0..na], b[0..nb] };
}

test "diff: edit script applies and minimal equals LCS" {
    var prng = std.Random.DefaultPrng.init(0xd1ff);
    var src: Source(std.Random) = .{ .inner = prng.random() };
    var ba: [200]u32 = undefined;
    var bb: [200]u32 = undefined;
    for (0..400) |_| {
        const p = randomPair(&src, &ba, &bb);
        try checkAll(p[0], p[1]);
    }
}

test "fuzz: diff scripts" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var src: Source(*std.testing.Smith) = .{ .inner = s };
            var ba: [120]u32 = undefined;
            var bb: [120]u32 = undefined;
            const p = randomPair(&src, &ba, &bb);
            try checkAll(p[0], p[1]);
        }
    }.one, .{});
}

test "diff: cost limit keeps scripts valid on large inputs" {
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    const a = try gpa.alloc(u32, 5000);
    defer gpa.free(a);
    const b = try gpa.alloc(u32, 5000);
    defer gpa.free(b);
    for (a) |*x| x.* = r.uintLessThan(u32, 50);
    for (b) |*x| x.* = r.uintLessThan(u32, 50);
    for (algorithms) |alg| {
        const e = try diff.diffTokens(gpa, a, b, alg, null);
        defer gpa.free(e);
        try std.testing.expect(script.validate(e, a, b));
    }
}

test "diff: patience anchors table" {
    // LIS over b positions.
    const pairs = [_][2]u32{ .{ 0, 3 }, .{ 1, 1 }, .{ 2, 4 }, .{ 3, 2 }, .{ 4, 5 } };
    const got = try patience_mod.lis(gpa, &pairs);
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    for (got[1..], got[0 .. got.len - 1]) |x, y| try std.testing.expect(pairs[x][1] > pairs[y][1]);
    // Unique lines anchor; the moved block is a delete plus an insert.
    const a = [_]u32{ 10, 1, 2, 3, 20, 4, 5 };
    const b = [_]u32{ 10, 4, 5, 20, 1, 2, 3 };
    const e = try diff.diffTokens(gpa, &a, &b, .patience, null);
    defer gpa.free(e);
    try std.testing.expect(script.validate(e, &a, &b));
    try std.testing.expectEqual(@as(usize, 4), script.equalCount(e));
}

fn diffText(a: []const u8, b: []const u8, o: diff.DiffOptions) ![]u8 {
    var la = try diff.LineSource.fromBytes(gpa, a);
    defer la.deinit(gpa);
    var lb = try diff.LineSource.fromBytes(gpa, b);
    defer lb.deinit(gpa);
    var r = try diff.diffLines(gpa, &la, &lb, o);
    defer r.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try diff.unified.writeUnified(&out.writer, r.edits, r.hunks, &la, &lb, .{ "a/f", "b/f" });
    return out.toOwnedSlice();
}

test "diff: histogram output matches git --histogram" {
    // Braces repeat; the unique function names drive the split, so the
    // inserted function comes out as one clean block.
    const a = "int a() {\n  return 1;\n}\n\nint c() {\n  return 3;\n}\n";
    const b = "int a() {\n  return 1;\n}\n\nint b() {\n  return 2;\n}\n\nint c() {\n  return 3;\n}\n";
    const got = try diffText(a, b, .{ .context_lines = 1 });
    defer gpa.free(got);
    try std.testing.expectEqualStrings("--- a/f\n+++ b/f\n@@ -4,2 +4,6 @@\n \n+int b() {\n+  return 2;\n+}\n+\n int c() {\n", got);
}

test "diff: deadline fallback valid" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const past: diff.Deadline = .{ .io = io, .at = .zero };
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    var a: [3000]u32 = undefined;
    var b: [3000]u32 = undefined;
    for (&a) |*x| x.* = r.uintLessThan(u32, 20);
    for (&b) |*x| x.* = r.uintLessThan(u32, 20);
    for (algorithms) |alg| {
        const e = try diff.diffTokens(gpa, &a, &b, alg, past);
        defer gpa.free(e);
        try std.testing.expect(script.validate(e, &a, &b));
    }
}

test "diff: ws modes" {
    const a = "x = 1;  \nif  (y)\tz\n";
    const b = "x = 1;\nif (y) z\n";
    for ([_]struct { diff.WsMode, usize }{ .{ .none, 2 }, .{ .trailing, 1 }, .{ .amount, 0 }, .{ .all, 0 } }) |c| {
        var la = try diff.LineSource.fromBytes(gpa, a);
        defer la.deinit(gpa);
        var lb = try diff.LineSource.fromBytes(gpa, b);
        defer lb.deinit(gpa);
        var r = try diff.diffLines(gpa, &la, &lb, .{ .ignore_ws = c[0], .context_lines = 0 });
        defer r.deinit(gpa);
        var changed: usize = 0;
        for (r.edits) |e| if (e.kind == .delete) {
            changed += e.len;
        };
        try std.testing.expectEqual(c[1], changed);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try std.testing.expectEqualStrings("a b", try diff.line_ids.normalize("  a \t b  ", .amount, &buf, gpa));
    try std.testing.expectEqualStrings("ab", try diff.line_ids.normalize(" a b ", .all, &buf, gpa));
}

test "unified: golden outputs" {
    {
        const got = try diffText("a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n", "a\nb\nC\nd\ne\nf\ng\nh\nI\nj\n", .{});
        defer gpa.free(got);
        try std.testing.expectEqualStrings(
            \\--- a/f
            \\+++ b/f
            \\@@ -1,10 +1,10 @@
            \\ a
            \\ b
            \\-c
            \\+C
            \\ d
            \\ e
            \\ f
            \\ g
            \\ h
            \\-i
            \\+I
            \\ j
            \\
        , got);
    }
    {
        // Far-apart changes give two hunks.
        const got = try diffText("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n", "x\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\ny\n", .{ .context_lines = 2 });
        defer gpa.free(got);
        try std.testing.expectEqualStrings(
            \\--- a/f
            \\+++ b/f
            \\@@ -1,3 +1,3 @@
            \\-1
            \\+x
            \\ 2
            \\ 3
            \\@@ -10,3 +10,3 @@
            \\ 10
            \\ 11
            \\-12
            \\+y
            \\
        , got);
    }
    {
        // No newline at end of file, and an empty old side.
        const got = try diffText("", "only", .{});
        defer gpa.free(got);
        try std.testing.expectEqualStrings(
            \\--- a/f
            \\+++ b/f
            \\@@ -0,0 +1 @@
            \\+only
            \\\ No newline at end of file
            \\
        , got);
    }
    {
        const got = try diffText("a\nb", "a\nb\n", .{});
        defer gpa.free(got);
        try std.testing.expectEqualStrings(
            \\--- a/f
            \\+++ b/f
            \\@@ -1,2 +1,2 @@
            \\ a
            \\-b
            \\\ No newline at end of file
            \\+b
            \\
        , got);
    }
    {
        const got = try diffText("same\n", "same\n", .{});
        defer gpa.free(got);
        try std.testing.expectEqualStrings("", got);
    }
}

test "diff: LineSource splits like the piece tree" {
    var s = try diff.LineSource.fromBytes(gpa, "a\r\nb\rc\n\nd");
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 5), s.count());
    try std.testing.expectEqualStrings("a", s.line(0));
    try std.testing.expectEqualStrings("a\r\n", s.lineWithEol(0));
    try std.testing.expectEqualStrings("b", s.line(1));
    try std.testing.expectEqualStrings("", s.line(3));
    try std.testing.expect(s.missingEol(4));
}
