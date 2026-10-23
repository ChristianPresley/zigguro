//! Position conversion tests: the encoding table, round trips and result
//! ranges mapped through edits.

const std = @import("std");
const zg_editor = @import("zg_editor");
const position = @import("position.zig");

const testing = std.testing;
const Document = zg_editor.model.document.Document;
const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
const pt = zg_editor.model.buffer.piece_tree;

// Line 0: a, e-acute (2 bytes), a CJK ideograph (3), an emoji (4, a
// surrogate pair in UTF-16), b; then CRLF, "x", a lone CR, "y", LF and an
// empty last line.
const text = "a\u{e9}\u{4e2d}\u{1F600}b\r\nx\ry\n";

fn expectByte(m: *position.Mapper, line: u32, ch: u32, want: u64) !void {
    const got = try m.byteOf(.{ .line = line, .character = ch });
    if (got != want) {
        std.debug.print("{t} {d}:{d}: want byte {d}, got {d}\n", .{ m.enc, line, ch, want, got });
        return error.TestUnexpectedResult;
    }
}

fn expectPos(m: *position.Mapper, off: u64, line: u32, ch: u32) !void {
    const p = try m.positionOf(off);
    if (p.line != line or p.character != ch) {
        std.debug.print("{t} byte {d}: want {d}:{d}, got {d}:{d}\n", .{ m.enc, off, line, ch, p.line, p.character });
        return error.TestUnexpectedResult;
    }
}

test "position: table" {
    const doc = try Document.initBytes(testing.allocator, @enumFromInt(1), text);
    defer doc.deinit();
    var m: position.Mapper = .{ .gpa = testing.allocator, .tree = &doc.tree, .enc = .utf16 };
    defer m.deinit();
    // UTF-16: the emoji takes two units; inside it means its start.
    for ([_][3]u64{
        .{ 0, 0, 0 },  .{ 0, 1, 1 },  .{ 0, 2, 3 },   .{ 0, 3, 6 },  .{ 0, 4, 6 },
        .{ 0, 5, 10 }, .{ 0, 6, 11 }, .{ 0, 99, 11 }, .{ 1, 0, 13 }, .{ 1, 1, 14 },
        .{ 1, 5, 14 }, .{ 2, 0, 15 }, .{ 2, 1, 16 },  .{ 3, 0, 17 }, .{ 9, 0, 17 },
        .{ 0, 2, 3 },
    }) |c| try expectByte(&m, @intCast(c[0]), @intCast(c[1]), c[2]);
    for ([_][3]u64{
        .{ 0, 0, 0 },  .{ 6, 0, 3 },  .{ 7, 0, 3 },  .{ 10, 0, 5 }, .{ 11, 0, 6 },
        .{ 12, 0, 6 }, .{ 13, 1, 0 }, .{ 15, 2, 0 }, .{ 17, 3, 0 }, .{ 99, 3, 0 },
    }) |c| try expectPos(&m, c[0], @intCast(c[1]), @intCast(c[2]));

    // UTF-8: columns are bytes; inside a character means its start.
    m.enc = .utf8;
    for ([_][3]u64{ .{ 0, 1, 1 }, .{ 0, 2, 1 }, .{ 0, 3, 3 }, .{ 0, 6, 6 }, .{ 0, 8, 6 }, .{ 0, 10, 10 }, .{ 0, 12, 11 } }) |c|
        try expectByte(&m, @intCast(c[0]), @intCast(c[1]), c[2]);
    try expectPos(&m, 7, 0, 6);
    // UTF-32: columns are code points.
    m.enc = .utf32;
    for ([_][3]u64{ .{ 0, 2, 3 }, .{ 0, 3, 6 }, .{ 0, 4, 10 }, .{ 0, 5, 11 } }) |c|
        try expectByte(&m, @intCast(c[0]), @intCast(c[1]), c[2]);
    try expectPos(&m, 10, 0, 4);

    // Ranges: an inverted one is swapped.
    m.enc = .utf16;
    try testing.expectEqual(position.ByteRange{ .start = 3, .end = 13 }, try m.toRange(.{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 0, .character = 2 } }));
    const r = try m.fromRange(.{ .start = 1, .end = 14 });
    try testing.expectEqual(@as(u32, 1), r.start.character);
    try testing.expectEqual(@as(u32, 1), r.end.line);
}

test "position: roundtrip at character boundaries" {
    var prng: std.Random.DefaultPrng = .init(0x554);
    const rand = prng.random();
    const pieces = [_][]const u8{ "a", "z", " ", "\u{e9}", "\u{4e2d}", "\u{1F600}", "\n", "\r\n", "\r" };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var bounds: std.ArrayList(u64) = .empty;
    defer bounds.deinit(testing.allocator);
    for (0..50) |_| {
        buf.clearRetainingCapacity();
        bounds.clearRetainingCapacity();
        for (0..rand.intRangeAtMost(usize, 0, 400)) |_| {
            const p = pieces[rand.uintLessThan(usize, pieces.len)];
            // The middle of a CRLF is not a character boundary.
            if (!std.mem.eql(u8, p, "\n") or buf.items.len == 0 or buf.items[buf.items.len - 1] != '\r')
                try bounds.append(testing.allocator, buf.items.len);
            try buf.appendSlice(testing.allocator, p);
        }
        try bounds.append(testing.allocator, buf.items.len);
        const doc = try Document.initBytes(testing.allocator, @enumFromInt(1), buf.items);
        defer doc.deinit();
        for ([_]position.Encoding{ .utf8, .utf16, .utf32 }) |enc| {
            var m: position.Mapper = .{ .gpa = testing.allocator, .tree = &doc.tree, .enc = enc };
            defer m.deinit();
            for (0..60) |_| {
                const off = bounds.items[rand.uintLessThan(usize, bounds.items.len)];
                // Offsets just before a line break are the line's end.
                const p = try m.positionOf(off);
                try testing.expectEqual(off, try m.byteOf(p));
            }
        }
    }
}

fn apply(doc: *Document, a: u64, b: u64, t: []const u8) !void {
    var cs = try ChangeSet.fromEdits(testing.allocator, doc.len(), &.{pt.Edit{ .range = .{ .start = a, .end = b }, .text = t }});
    defer cs.deinit();
    try doc.applyChangeSet(&cs, .{ .user = 0 });
}

test "position: mapResultRange through edits" {
    const doc = try Document.initBytes(testing.allocator, @enumFromInt(1), "hello world\n");
    defer doc.deinit();
    const v0 = doc.version;
    try apply(doc, 0, 0, "XX"); // "XXhello world"
    try apply(doc, 8, 11, "W"); // "XXhello Wld"
    const hello: position.ByteRange = .{ .start = 0, .end = 5 };
    const world: position.ByteRange = .{ .start = 6, .end = 11 };
    // Untouched text moves.
    try testing.expectEqual(position.ByteRange{ .start = 2, .end = 7 }, position.mapResultRange(doc, v0, hello, .drop).?);
    // Edited text: dropped, or kept with its ends moved.
    try testing.expect(position.mapResultRange(doc, v0, world, .drop) == null);
    try testing.expectEqual(position.ByteRange{ .start = 8, .end = 11 }, position.mapResultRange(doc, v0, world, .shrink).?);
    // A point after the edit.
    try testing.expectEqual(position.ByteRange{ .start = 11, .end = 11 }, position.mapResultRange(doc, v0, .{ .start = 11, .end = 11 }, .drop).?);
    // An insertion inside drops; deleting all of it drops either way.
    try apply(doc, 4, 4, "_"); // "XXhe_llo Wld"
    try testing.expect(position.mapResultRange(doc, v0, hello, .drop) == null);
    try testing.expectEqual(position.ByteRange{ .start = 2, .end = 8 }, position.mapResultRange(doc, v0, hello, .shrink).?);
    const v3 = doc.version;
    try apply(doc, 2, 8, "");
    try testing.expect(position.mapResultRange(doc, v3, .{ .start = 2, .end = 8 }, .shrink) == null);
    try testing.expectEqual(world, position.mapResultRange(doc, doc.version, world, .drop).?);
}
