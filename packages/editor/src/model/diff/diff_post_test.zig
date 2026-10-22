//! Post-processing tests: intraline highlights, the slider heuristic and
//! moved blocks.

const std = @import("std");
const diff = @import("../diff.zig");
const script = @import("script.zig");
const intraline = @import("intraline.zig");
const postprocess = @import("postprocess.zig");
const moves = @import("moves.zig");

const gpa = std.testing.allocator;
const Edit = script.Edit;

const Pair = struct {
    a: diff.LineSource,
    b: diff.LineSource,

    fn init(a: []const u8, b: []const u8) !Pair {
        var la = try diff.LineSource.fromBytes(gpa, a);
        errdefer la.deinit(gpa);
        return .{ .a = la, .b = try .fromBytes(gpa, b) };
    }

    fn deinit(p: *Pair) void {
        p.a.deinit(gpa);
        p.b.deinit(gpa);
    }
};

fn highlights(a: []const u8, b: []const u8, mode: intraline.Mode) !struct { [8][]const u8, [8][]const u8, usize, usize } {
    var p = try Pair.init(a, b);
    defer p.deinit();
    const edits = [_]Edit{ .{ .kind = .delete, .a_start = 0, .b_start = 0, .len = 1 }, .{ .kind = .insert, .a_start = 1, .b_start = 0, .len = 1 } };
    const rs = try intraline.intralineEdits(gpa, &edits, &p.a, &p.b, mode);
    defer gpa.free(rs);
    var old: [8][]const u8 = undefined;
    var new: [8][]const u8 = undefined;
    var no: usize = 0;
    var nn: usize = 0;
    for (rs) |r| {
        const s: usize = @intCast(r.range.start);
        const e: usize = @intCast(r.range.end);
        if (r.side == .old) {
            old[no] = a[s..e];
            no += 1;
        } else {
            new[nn] = b[s..e];
            nn += 1;
        }
    }
    return .{ old, new, no, nn };
}

test "intraline: rename one identifier" {
    const h = try highlights("    const total_count = items.len + offset;\n", "    const item_count = items.len + offset;\n", .word);
    try std.testing.expectEqual(@as(usize, 1), h[2]);
    try std.testing.expectEqual(@as(usize, 1), h[3]);
    try std.testing.expectEqualStrings("total_count", h[0][0]);
    try std.testing.expectEqualStrings("item_count", h[1][0]);
}

test "intraline: confetti threshold" {
    const a = "alpha beta gamma delta epsilon zeta\n";
    const b = "one two three four five delta six\n";
    const h = try highlights(a, b, .word);
    try std.testing.expectEqual(@as(usize, 1), h[2]);
    try std.testing.expectEqualStrings(a[0 .. a.len - 1], h[0][0]);
}

test "intraline: CJK and emoji graphemes" {
    const h = try highlights("日本語👍🏽テスト\n", "日本人👍🏽テスト\n", .char);
    try std.testing.expectEqualStrings("語", h[0][0]);
    try std.testing.expectEqualStrings("人", h[1][0]);
    const e = try highlights("ok 👍🏽 done\n", "ok 👍🏿 done\n", .char);
    try std.testing.expectEqualStrings("👍🏽", e[0][0]);
}

test "intraline: similarity pairing" {
    try std.testing.expect(intraline.dice("return value;", "return values;") > 0.8);
    try std.testing.expect(intraline.dice("abcdef", "uvwxyz") < 0.1);
}

fn lineDiff(a: []const u8, b: []const u8, o: diff.DiffOptions) ![]u8 {
    var p = try Pair.init(a, b);
    defer p.deinit();
    var r = try diff.diffLines(gpa, &p.a, &p.b, o);
    defer r.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try diff.unified.writeUnified(&out.writer, r.edits, r.hunks, &p.a, &p.b, .{ "a", "b" });
    return out.toOwnedSlice();
}

test "slide: function insertion between similar functions" {
    const a = "fn a() {\n    x();\n}\n\nfn c() {\n    z();\n}\n";
    const b = "fn a() {\n    x();\n}\n\nfn b() {\n    y();\n}\n\nfn c() {\n    z();\n}\n";
    // A misplaced script: the insert starts at the blank line.
    var edits = [_]Edit{
        .{ .kind = .equal, .a_start = 0, .b_start = 0, .len = 3 },
        .{ .kind = .insert, .a_start = 3, .b_start = 3, .len = 4 },
        .{ .kind = .equal, .a_start = 3, .b_start = 7, .len = 4 },
    };
    var p = try Pair.init(a, b);
    defer p.deinit();
    var ia: std.ArrayList(u32) = .empty;
    defer ia.deinit(gpa);
    var ib: std.ArrayList(u32) = .empty;
    defer ib.deinit(gpa);
    try diff.line_ids.intern(gpa, &p.a, &p.b, .none, &ia, &ib);
    try std.testing.expect(script.validate(&edits, ia.items, ib.items));
    const n = postprocess.slideHunks(&edits, ia.items, ib.items, &p.a, &p.b);
    try std.testing.expect(script.validate(edits[0..n], ia.items, ib.items));
    try std.testing.expectEqual(@as(u32, 4), edits[1].b_start);
    try std.testing.expectEqualStrings("fn b() {", p.b.line(edits[1].b_start));
    try std.testing.expectEqualStrings("", p.b.line(edits[1].b_start + 3));
}

test "slide: blank line placement" {
    // Inserting a block that ends with a blank line before an identical
    // blank line: the blank goes at the end of the hunk.
    const a = "x\n\ny\n";
    const b = "x\n\nnew\n\ny\n";
    const got = try lineDiff(a, b, .{ .context_lines = 0, .algorithm = .myers });
    defer gpa.free(got);
    try std.testing.expectEqualStrings("--- a\n+++ b\n@@ -2,0 +3,2 @@\n+new\n+\n", got);
}

test "moves: block moved down detected and linked" {
    const block = "fn helper() {\n    compute_something_long();\n    and_more_work_here();\n}\n";
    const a = block ++ "a\nb\nc\nd\ne\nf\ng\nh\n";
    const b = "a\nb\nc\nd\ne\nf\ng\nh\n" ++ block;
    var p = try Pair.init(a, b);
    defer p.deinit();
    var r = try diff.diffLines(gpa, &p.a, &p.b, .{ .detect_moves = true, .context_lines = 0 });
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), r.moves.len);
    try std.testing.expectEqual(@as(u64, 0), r.moves[0].from.start);
    try std.testing.expectEqual(@as(u64, 8), r.moves[0].to.start);
    try std.testing.expectEqual(@as(usize, 2), r.hunks.len);
    try std.testing.expectEqual(@as(?u32, 0), r.hunks[1].moved_from);
    var moved: usize = 0;
    for (r.hunks) |h| for (h.intraline) |x| {
        if (x.kind == .moved) moved += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), moved);
    // Re-indented blocks still count as moves.
    const c = "a\nb\nc\nd\ne\nf\ng\nh\n" ++ "  fn helper() {\n      compute_something_long();\n      and_more_work_here();\n  }\n";
    const m2 = try diffMoves(a, c);
    try std.testing.expectEqual(@as(usize, 1), m2);
}

fn diffMoves(a: []const u8, b: []const u8) !usize {
    var p = try Pair.init(a, b);
    defer p.deinit();
    var r = try diff.diffLines(gpa, &p.a, &p.b, .{ .detect_moves = true });
    defer r.deinit(gpa);
    return r.moves.len;
}

test "moves: short blocks are not moves" {
    try std.testing.expectEqual(@as(usize, 0), try diffMoves("x\ny\na\nb\nc\n", "a\nb\nc\nx\ny\n"));
}
