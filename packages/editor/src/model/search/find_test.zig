//! Find session tests: viewport-first search, incremental maintenance
//! against a full re-search (and its fuzz target), whole word, smart case,
//! in-selection, multiline matches across pieces, replace-all and
//! literal search.

const std = @import("std");
const find = @import("find.zig");
const Document = @import("../document.zig").Document;
const ChangeSet = @import("../edit/change_set.zig").ChangeSet;
const Range = find.Range;

const gpa = std.testing.allocator;

fn newDoc(text: []const u8) !*Document {
    return Document.initBytes(gpa, @enumFromInt(1), text);
}

fn edit(doc: *Document, s: *find.FindSession, start: u64, end: u64, text: []const u8) !void {
    var cs = try ChangeSet.fromEdits(gpa, doc.len(), &.{.{ .range = .{ .start = start, .end = end }, .text = text }});
    defer cs.deinit();
    try doc.applyChangeSet(&cs, .{ .user = 0 });
    try s.onChangeSet(&cs);
}

/// Every match of a fresh full search.
fn fullSearch(doc: *Document, o: find.FindOptions) !std.ArrayList(Range) {
    var s = try find.FindSession.start(gpa, doc, o, .{ .start = 0, .end = 0 }, null);
    defer s.stop();
    try s.finish();
    var out: std.ArrayList(Range) = .empty;
    try out.appendSlice(gpa, s.index.items.items);
    return out;
}

test "find: viewport first then complete count" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..5000) |i| try text.print(gpa, "line {d} has needle here\n", .{i});
    const doc = try newDoc(text.items);
    defer doc.deinit();
    const vp_start = doc.tree.lineStart(2000);
    var s = try find.FindSession.start(gpa, doc, .{ .pattern = "needle" }, .{ .start = vp_start, .end = doc.tree.lineStart(2050) }, null);
    defer s.stop();
    const c0 = s.matchCount();
    try std.testing.expect(!c0.complete);
    try std.testing.expect(c0.known >= 50 and c0.known <= 52);
    try std.testing.expect(s.next(vp_start).?.start > vp_start);
    while (!try s.step(16 << 10)) {}
    const c1 = s.matchCount();
    try std.testing.expect(c1.complete);
    try std.testing.expectEqual(@as(u64, 5000), c1.known);
    const m = s.next(0).?;
    try std.testing.expectEqual(@as(?u64, 0), s.indexOf(m));
    try std.testing.expectEqual(s.index.nth(4999).start, s.prev(0).?.start); // wraps
}

const Source = struct {
    r: std.Random,
    fn pick(s: *Source, n: usize) usize {
        return if (n <= 1) 0 else s.r.uintLessThan(usize, n);
    }
};

fn incrementalMatchesFull(src: anytype, o: find.FindOptions) !void {
    const alpha = "ab \nx";
    var init: [200]u8 = undefined;
    for (&init) |*c| c.* = alpha[src.pick(alpha.len)];
    const doc = try newDoc(&init);
    defer doc.deinit();
    var s = try find.FindSession.start(gpa, doc, o, .{ .start = 0, .end = 40 }, null);
    defer s.stop();
    for (0..30) |k| {
        if (k == 10) try s.finish();
        const len = doc.len();
        const a = src.pick(len + 1);
        const b = a + src.pick(@min(len - a, 5) + 1);
        var buf: [4]u8 = undefined;
        const n = src.pick(5);
        for (buf[0..n]) |*c| c.* = alpha[src.pick(alpha.len)];
        try edit(doc, s, a, b, buf[0..n]);
    }
    try s.finish();
    var want = try fullSearch(doc, o);
    defer want.deinit(gpa);
    try std.testing.expectEqualSlices(Range, want.items, s.index.items.items);
}

test "find: incremental equals full after random edits" {
    var prng = std.Random.DefaultPrng.init(0xf1d);
    var src: Source = .{ .r = prng.random() };
    for (0..40) |_| {
        try incrementalMatchesFull(&src, .{ .pattern = "ab" });
        try incrementalMatchesFull(&src, .{ .pattern = "a+b?", .regex = true });
        try incrementalMatchesFull(&src, .{ .pattern = "b\\na", .regex = true });
    }
}

test "fuzz: find incremental" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, sm: *std.testing.Smith) anyerror!void {
            const S = struct {
                sm: *std.testing.Smith,
                fn pick(s: *@This(), n: usize) usize {
                    return if (n <= 1) 0 else s.sm.index(n);
                }
            };
            var src: S = .{ .sm = sm };
            try incrementalMatchesFull(&src, .{ .pattern = "a b", .regex = false });
        }
    }.one, .{});
}

test "find: whole word with punctuation-leading pattern" {
    const doc = try newDoc("x.foo .foo a.foobar .foo_x (.foo)");
    defer doc.deinit();
    var s = try find.FindSession.start(gpa, doc, .{ .pattern = ".foo", .whole_word = true }, .{ .start = 0, .end = doc.len() }, null);
    defer s.stop();
    try s.finish();
    // Half boundaries: ".foo" at 6 and in "(.foo)" match; "x.foo" has a
    // word character before it, ".foobar" and ".foo_x" after it.
    try std.testing.expectEqual(@as(u64, 2), s.matchCount().known);
    try std.testing.expectEqual(@as(u64, 6), s.index.nth(0).start);
}

test "find: smart case" {
    const doc = try newDoc("Foo foo FOO");
    defer doc.deinit();
    for ([_]struct { []const u8, u64 }{ .{ "foo", 3 }, .{ "Foo", 1 }, .{ "f[o]+", 3 } }) |c| {
        var s = try find.FindSession.start(gpa, doc, .{ .pattern = c[0], .regex = true }, .{ .start = 0, .end = doc.len() }, null);
        defer s.stop();
        try std.testing.expectEqual(c[1], s.matchCount().known);
    }
    var s = try find.FindSession.start(gpa, doc, .{ .pattern = "foo", .case = .sensitive }, .{ .start = 0, .end = doc.len() }, null);
    defer s.stop();
    try std.testing.expectEqual(@as(u64, 1), s.matchCount().known);
}

test "find: in selection" {
    const doc = try newDoc("ab ab ab ab ab");
    defer doc.deinit();
    const sel = [_]Range{ .{ .start = 2, .end = 8 }, .{ .start = 12, .end = 14 } };
    var s = try find.FindSession.start(gpa, doc, .{ .pattern = "ab", .in_selection = &sel }, .{ .start = 0, .end = doc.len() }, null);
    defer s.stop();
    try s.finish();
    try std.testing.expectEqual(@as(u64, 3), s.matchCount().known);
    // Edits before a scope shift it.
    try edit(doc, s, 0, 0, "zz");
    try std.testing.expectEqual(@as(u64, 3), s.matchCount().known);
    try std.testing.expectEqual(@as(u64, 5), s.index.nth(0).start);
}

test "find: multiline across piece boundaries" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendNTimes(gpa, 'x', 8190);
    try text.appendSlice(gpa, "end\nstart");
    try text.appendNTimes(gpa, 'y', 100);
    const doc = try newDoc(text.items);
    defer doc.deinit();
    try std.testing.expect(doc.tree.pieceAt(8190).base + doc.tree.pieceAt(8190).bytes.len < 8199);
    var s = try find.FindSession.start(gpa, doc, .{ .pattern = "end\\nstart", .regex = true }, .{ .start = 0, .end = 0 }, null);
    defer s.stop();
    try s.finish();
    try std.testing.expectEqual(@as(u64, 1), s.matchCount().known);
    try std.testing.expectEqual(@as(u64, 8190), s.index.nth(0).start);
    // Literal newline in the pattern.
    var l = try find.FindSession.start(gpa, doc, .{ .pattern = "d\ns" }, .{ .start = 0, .end = doc.len() }, null);
    defer l.stop();
    try std.testing.expect(l.matcher.multiline);
    try std.testing.expectEqual(@as(u64, 1), l.matchCount().known);
}

test "find: regex syntax error reports the span" {
    const doc = try newDoc("abc");
    defer doc.deinit();
    var diag: @import("zg_regex").Error = undefined;
    try std.testing.expectError(error.Syntax, find.FindSession.start(gpa, doc, .{ .pattern = "a(b", .regex = true }, .{ .start = 0, .end = 3 }, &diag));
}

test "replace: all is one undo group" {
    const doc = try newDoc("let foo = foo + Foo; FOO();");
    defer doc.deinit();
    var s = try find.FindSession.start(gpa, doc, .{ .pattern = "foo", .preserve_case = true }, .{ .start = 0, .end = doc.len() }, null);
    defer s.stop();
    const v = doc.version;
    try std.testing.expectEqual(@as(u64, 4), try s.replaceAll("bar", .{ .user = 7 }));
    try std.testing.expectEqual(v + 1, doc.version);
    const got = try doc.tree.copyRange(gpa, .{ .start = 0, .end = doc.len() });
    defer gpa.free(got);
    try std.testing.expectEqualStrings("let bar = bar + Bar; BAR();", got);
    try std.testing.expectEqual(@as(u64, 0), s.matchCount().known);
}

test "replace: regex captures and current" {
    const doc = try newDoc("a=1, b=2, c=3");
    defer doc.deinit();
    var s = try find.FindSession.start(gpa, doc, .{ .pattern = "(\\w)=(\\d)", .regex = true }, .{ .start = 0, .end = doc.len() }, null);
    defer s.stop();
    const first = s.next(0).?;
    const nxt = (try s.replaceCurrent(first, "$2:$1", .{ .user = 1 })).?;
    try std.testing.expectEqual(@as(u64, 5), nxt.start);
    try std.testing.expectEqual(@as(u64, 2), try s.replaceAll("${2}${1}", .{ .user = 1 }));
    const got = try doc.tree.copyRange(gpa, .{ .start = 0, .end = doc.len() });
    defer gpa.free(got);
    try std.testing.expectEqualStrings("1:a, 2b, 3c", got);
    // Literal mode takes `$` verbatim.
    var l = try find.FindSession.start(gpa, doc, .{ .pattern = "2b" }, .{ .start = 0, .end = doc.len() }, null);
    defer l.stop();
    _ = try l.replaceAll("$1", .{ .user = 1 });
    const got2 = try doc.tree.copyRange(gpa, .{ .start = 0, .end = doc.len() });
    defer gpa.free(got2);
    try std.testing.expectEqualStrings("1:a, $1, 3c", got2);
}

test "find: select all" {
    const doc = try newDoc("x y x y x");
    defer doc.deinit();
    var s = try find.FindSession.start(gpa, doc, .{ .pattern = "x" }, .{ .start = 0, .end = 0 }, null);
    defer s.stop();
    const sels = try s.selectAll(gpa);
    defer gpa.free(sels);
    try std.testing.expectEqual(@as(usize, 3), sels.len);
    try std.testing.expectEqual(@as(u64, 8), sels[2].anchor);
}

test "literalSearch: backward/forward wrap" {
    const doc = try newDoc("foo bar Foo baz foo");
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.release();
    const f = (try find.literalSearch(gpa, &snap, "foo", 1, .{ .case_sensitive = true, .whole_word = true })).?;
    try std.testing.expectEqual(@as(u64, 16), f.start);
    const w = (try find.literalSearch(gpa, &snap, "foo", 17, .{ .case_sensitive = true, .whole_word = true })).?;
    try std.testing.expectEqual(@as(u64, 0), w.start);
    const ci = (try find.literalSearch(gpa, &snap, "foo", 1, .{ .case_sensitive = false, .whole_word = true })).?;
    try std.testing.expectEqual(@as(u64, 8), ci.start);
    const b = (try find.literalSearch(gpa, &snap, "foo", 16, .{ .case_sensitive = true, .whole_word = true, .backward = true })).?;
    try std.testing.expectEqual(@as(u64, 0), b.start);
    const bw = (try find.literalSearch(gpa, &snap, "foo", 0, .{ .case_sensitive = true, .whole_word = true, .backward = true })).?;
    try std.testing.expectEqual(@as(u64, 16), bw.start);
}

test "find: worker batches map through later edits" {
    const doc = try newDoc("ab ab ab");
    defer doc.deinit();
    var s = try find.FindSession.start(gpa, doc, .{ .pattern = "ab" }, .{ .start = 0, .end = 0 }, null);
    defer s.stop();
    var snap = doc.snapshot();
    defer snap.release();
    const Collect = struct {
        list: std.ArrayList(Range) = .empty,
        version: u64 = 0,
        fn batch(ctx: *anyopaque, version: u64, ranges: []const Range) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.version = version;
            c.list.appendSlice(gpa, ranges) catch unreachable;
        }
    };
    var col: Collect = .{};
    defer col.list.deinit(gpa);
    var cache = try s.matcher.re.newCache(gpa);
    defer cache.deinit();
    try std.testing.expectEqual(@as(u64, 3), try find.searchSnapshot(gpa, &s.matcher.re, &cache, &snap, .{ .start = 0, .end = snap.len() }, .{ .ctx = &col, .batchFn = Collect.batch }, 2));
    // An edit lands before the batch is merged.
    try edit(doc, s, 0, 0, "zz ");
    try s.insertBatch(col.version, col.list.items);
    s.markComplete();
    try std.testing.expectEqual(@as(u64, 3), s.matchCount().known);
    try std.testing.expectEqual(@as(u64, 3), s.index.nth(0).start);
}
