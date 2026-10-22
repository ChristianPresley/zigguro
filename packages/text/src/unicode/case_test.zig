//! Tests for case folding and case mapping.

const std = @import("std");
const testing = std.testing;
const fold = @import("casefold.zig");
const map = @import("casemap.zig");

fn expectOp(comptime op: anytype, input: []const u8, want: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try op(&out, testing.allocator, input);
    testing.expectEqualStrings(want, out.items) catch |e| {
        std.debug.print("input: {s}\n", .{input});
        return e;
    };
}

fn foldFull(out: *std.ArrayList(u8), gpa: std.mem.Allocator, b: []const u8) !void {
    try fold.foldAppend(out, gpa, b, .full);
}

fn foldSimple(out: *std.ArrayList(u8), gpa: std.mem.Allocator, b: []const u8) !void {
    try fold.foldAppend(out, gpa, b, .simple);
}

test "fold ß/ẞ/ﬁ/Σ" {
    try expectOp(foldFull, "Straße", "strasse");
    try expectOp(foldFull, "STRAẞE", "strasse");
    try expectOp(foldFull, "\u{FB01}le", "file");
    try expectOp(foldFull, "ΟΔΟΣ ος", "οδοσ οσ");
    try expectOp(foldSimple, "Straße", "straße");
    try expectOp(foldSimple, "STRAẞE", "straße");
    try expectOp(foldSimple, "\u{FB01}le", "\u{FB01}le");
    try expectOp(foldFull, "Hello, WORLD! 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ", "hello, world! 0123456789 abcdefghijklmnopqrstuvwxyz");
}

test "Folder offsets map back" {
    const s = "aẞ\u{FB01}Σ!";
    var f = fold.Folder.init(s, false);
    const want = [_]fold.Folded{
        .{ .cp = 'a', .src_start = 0, .src_end = 1 },
        .{ .cp = 's', .src_start = 1, .src_end = 4 },
        .{ .cp = 's', .src_start = 1, .src_end = 4 },
        .{ .cp = 'f', .src_start = 4, .src_end = 7 },
        .{ .cp = 'i', .src_start = 4, .src_end = 7 },
        .{ .cp = 0x3C3, .src_start = 7, .src_end = 9 },
        .{ .cp = '!', .src_start = 9, .src_end = 10 },
    };
    for (want) |w| try testing.expectEqual(w, f.next().?);
    try testing.expectEqual(@as(?fold.Folded, null), f.next());
    // The folded stream equals foldAppend's output.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try fold.foldAppend(&out, testing.allocator, s, .full);
    var again: std.ArrayList(u8) = .empty;
    defer again.deinit(testing.allocator);
    var g = fold.Folder.init(s, false);
    while (g.next()) |x| try fold.appendCp(&again, testing.allocator, x.cp);
    try testing.expectEqualStrings(out.items, again.items);
}

test "fold ascii fast path equals slow path" {
    var rng = std.Random.DefaultPrng.init(7);
    const r = rng.random();
    var buf: [517]u8 = undefined;
    for (0..50) |_| {
        for (&buf) |*b| b.* = r.int(u7);
        var fast: std.ArrayList(u8) = .empty;
        defer fast.deinit(testing.allocator);
        try fold.foldAppend(&fast, testing.allocator, &buf, .full);
        var slow: std.ArrayList(u8) = .empty;
        defer slow.deinit(testing.allocator);
        var f = fold.Folder.init(&buf, false);
        while (f.next()) |x| try fold.appendCp(&slow, testing.allocator, x.cp);
        try testing.expectEqualStrings(slow.items, fast.items);
        for (buf, fast.items) |a, b| try testing.expectEqual(std.ascii.toLower(a), b);
    }
}

test "toUpper special casing" {
    try expectOp(map.toUpper, "straße", "STRASSE");
    try expectOp(map.toUpper, "\u{149}", "\u{2BC}N");
    try expectOp(map.toUpper, "\u{FB01}", "FI");
    try expectOp(map.toUpper, "\u{390}", "\u{399}\u{308}\u{301}");
    try expectOp(map.toUpper, "hello, мир", "HELLO, МИР");
}

test "toLower final sigma" {
    try expectOp(map.toLower, "ΟΔΟΣ", "οδος");
    try expectOp(map.toLower, "ΣΑ", "σα");
    try expectOp(map.toLower, "ΑΣ.", "ας.");
    // A Case_Ignorable period between letters: not final.
    try expectOp(map.toLower, "ΑΣ.Β", "ασ.β");
    try expectOp(map.toLower, "Σ", "σ");
    try expectOp(map.toLower, "ΟΔΟΣ ΚΑΙ", "οδος και");
    try expectOp(map.toLower, "HELLO İ", "hello i\u{307}");
}

test "toTitle words" {
    try expectOp(map.toTitle, "hello wORLD", "Hello World");
    try expectOp(map.toTitle, "\u{1C6}emal", "\u{1C5}emal");
    try expectOp(map.toTitle, "ﬁsh and chips", "Fish And Chips");
    // Default title casing: the first cased letter of each word, so a
    // word starting with a digit titlecases its first letter.
    try expectOp(map.toTitle, "o'neil 3rd", "O'neil 3Rd");
}

test "caseShape/applyShape roundtrip" {
    const pairs = [_]struct { []const u8, []const u8, map.CaseShape }{
        .{ "foo", "bar", .lower },
        .{ "Foo", "Bar", .title },
        .{ "FOO", "BAR", .upper },
        .{ "fOo", "bar", .mixed },
        .{ "123", "bar", .uncased },
    };
    for (pairs) |pr| {
        const shape = map.caseShape(pr[0]);
        try testing.expectEqual(pr[2], shape);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try map.applyShape(&out, testing.allocator, pr[1], shape);
        const want: []const u8 = switch (shape) {
            .lower => "bar",
            .title => "Bar",
            .upper => "BAR",
            .mixed, .uncased => pr[1],
        };
        try testing.expectEqualStrings(want, out.items);
    }
    try testing.expectEqual(map.CaseShape.title, map.caseShape("Ǆemal"));
    try testing.expectEqual(map.CaseShape.upper, map.caseShape("X"));
}
