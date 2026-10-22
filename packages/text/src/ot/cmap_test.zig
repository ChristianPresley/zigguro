//! Handcrafted `cmap` tables covering every format and the selection rules.

const std = @import("std");
const testing = std.testing;
const cmap = @import("cmap.zig");
const Cmap = cmap.Cmap;

/// Big-endian byte builder for test tables.
const B = struct {
    buf: std.ArrayList(u8) = .empty,
    fn u16_(b: *B, v: u16) void {
        b.buf.appendSlice(testing.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, v))) catch unreachable;
    }
    fn u24_(b: *B, v: u24) void {
        var x: [3]u8 = undefined;
        std.mem.writeInt(u24, &x, v, .big);
        b.buf.appendSlice(testing.allocator, &x) catch unreachable;
    }
    fn u32_(b: *B, v: u32) void {
        b.buf.appendSlice(testing.allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, v))) catch unreachable;
    }
    fn u8_(b: *B, v: u8) void {
        b.buf.append(testing.allocator, v) catch unreachable;
    }
    fn deinit(b: *B) void {
        b.buf.deinit(testing.allocator);
    }
};

/// A cmap with the given (pid, eid, subtable) records.
fn table(subs: []const struct { u16, u16, []const u8 }) []u8 {
    var b: B = .{};
    b.u16_(0);
    b.u16_(@intCast(subs.len));
    var off: u32 = @intCast(4 + subs.len * 8);
    for (subs) |s| {
        b.u16_(s[0]);
        b.u16_(s[1]);
        b.u32_(off);
        off += @intCast(s[2].len);
    }
    for (subs) |s| b.buf.appendSlice(testing.allocator, s[2]) catch unreachable;
    return b.buf.toOwnedSlice(testing.allocator) catch unreachable;
}

/// Format 4 with segments: 'A'-'C' via idDelta (+10), 'a'-'c' via
/// idRangeOffset into glyphIdArray {50, 0, 52} with idDelta 1, and 0xFFFF.
fn format4() []u8 {
    var b: B = .{};
    const seg: u16 = 3;
    b.u16_(4);
    b.u16_(0); // length patched below
    b.u16_(0);
    b.u16_(seg * 2);
    b.u16_(4);
    b.u16_(1);
    b.u16_(2);
    for ([_]u16{ 'C', 'c', 0xFFFF }) |v| b.u16_(v); // endCode
    b.u16_(0);
    for ([_]u16{ 'A', 'a', 0xFFFF }) |v| b.u16_(v); // startCode
    for ([_]u16{ 10, 1, 1 }) |v| b.u16_(v); // idDelta
    // idRangeOffset: seg 1 points to glyphIdArray[0]: offset from its own slot = 2 * (seg - 1)
    for ([_]u16{ 0, 4, 0 }) |v| b.u16_(v);
    for ([_]u16{ 50, 0, 52 }) |v| b.u16_(v);
    std.mem.writeInt(u16, b.buf.items[2..4], @intCast(b.buf.items.len), .big);
    return b.buf.toOwnedSlice(testing.allocator) catch unreachable;
}

fn format12(constant: bool) []u8 {
    var b: B = .{};
    b.u16_(if (constant) 13 else 12);
    b.u16_(0);
    b.u32_(16 + 2 * 12);
    b.u32_(0);
    b.u32_(2);
    for ([_][3]u32{ .{ 0x41, 0x43, 5 }, .{ 0x1F600, 0x1F64F, 100 } }) |g| for (g) |v| b.u32_(v);
    return b.buf.toOwnedSlice(testing.allocator) catch unreachable;
}

test "format4 handcrafted" {
    const sub = format4();
    defer testing.allocator.free(sub);
    const t = table(&.{.{ 3, 1, sub }});
    defer testing.allocator.free(t);
    const c = try Cmap.init(t);
    try testing.expectEqual(@as(u16, 4), c.format);
    try testing.expectEqual(@as(u16, 'A' + 10), c.lookup('A'));
    try testing.expectEqual(@as(u16, 'C' + 10), c.lookup('C'));
    try testing.expectEqual(@as(u16, 0), c.lookup('D'));
    try testing.expectEqual(@as(u16, 51), c.lookup('a'));
    try testing.expectEqual(@as(u16, 0), c.lookup('b')); // glyphIdArray 0 stays 0
    try testing.expectEqual(@as(u16, 53), c.lookup('c'));
    try testing.expectEqual(@as(u16, 0), c.lookup(0xFFFF));
    try testing.expectEqual(@as(u16, 0), c.lookup(0x1F600));
}

test "format12 supplementary" {
    const sub = format12(false);
    defer testing.allocator.free(sub);
    const t = table(&.{.{ 3, 10, sub }});
    defer testing.allocator.free(t);
    const c = try Cmap.init(t);
    try testing.expectEqual(@as(u16, 6), c.lookup('B'));
    try testing.expectEqual(@as(u16, 100), c.lookup(0x1F600));
    try testing.expectEqual(@as(u16, 101), c.lookup(0x1F601));
    try testing.expectEqual(@as(u16, 0), c.lookup(0x1F650));
    // Clamped to the glyph count.
    const small = try Cmap.initGlyphs(t, 101);
    try testing.expectEqual(@as(u16, 100), small.lookup(0x1F600));
    try testing.expectEqual(@as(u16, 0), small.lookup(0x1F601));
}

test "format13 constant" {
    const sub = format12(true);
    defer testing.allocator.free(sub);
    const t = table(&.{.{ 0, 6, sub }});
    defer testing.allocator.free(t);
    const c = try Cmap.init(t);
    try testing.expectEqual(@as(u16, 100), c.lookup(0x1F620));
    try testing.expectEqual(@as(u16, 5), c.lookup('C'));
}

test "format14 default and non-default UVS" {
    var b: B = .{};
    defer b.deinit();
    b.u16_(14);
    b.u32_(0); // length patched
    b.u32_(2);
    // VS1 (U+FE00): default only; VS17 (U+E0100): non-default only.
    b.u24_(0xFE00);
    b.u32_(10 + 22);
    b.u32_(0);
    b.u24_(0xE0100);
    b.u32_(0);
    b.u32_(10 + 22 + 8);
    // DefaultUVS: one range 0x2269..0x2269+1
    b.u32_(1);
    b.u24_(0x2269);
    b.u8_(1);
    // NonDefaultUVS: U+82A6 -> 77
    b.u32_(1);
    b.u24_(0x82A6);
    b.u16_(77);
    std.mem.writeInt(u32, b.buf.items[2..6], @intCast(b.buf.items.len), .big);
    const f4 = format4();
    defer testing.allocator.free(f4);
    const t = table(&.{ .{ 0, 3, f4 }, .{ 0, 5, b.buf.items } });
    defer testing.allocator.free(t);
    const c = try Cmap.init(t);
    try testing.expectEqual(cmap.VariantResult.use_default, c.lookupVariant(0x2269, 0xFE00));
    try testing.expectEqual(cmap.VariantResult.use_default, c.lookupVariant(0x226A, 0xFE00));
    try testing.expectEqual(cmap.VariantResult.not_found, c.lookupVariant(0x226B, 0xFE00));
    try testing.expectEqual(cmap.VariantResult{ .glyph = 77 }, c.lookupVariant(0x82A6, 0xE0100));
    try testing.expectEqual(cmap.VariantResult.not_found, c.lookupVariant(0x82A6, 0xFE01));
}

test "subtable preference" {
    const f4 = format4();
    defer testing.allocator.free(f4);
    const f12 = format12(false);
    defer testing.allocator.free(f12);
    const t = table(&.{ .{ 3, 1, f4 }, .{ 3, 10, f12 } });
    defer testing.allocator.free(t);
    const c = try Cmap.init(t);
    try testing.expectEqual(@as(u16, 12), c.format);
    const none = table(&.{});
    defer testing.allocator.free(none);
    try testing.expectError(error.NoUnicodeSubtable, Cmap.init(none));
}

test "symbol font F000 mapping" {
    var b: B = .{};
    defer b.deinit();
    b.u16_(4);
    b.u16_(0);
    b.u16_(0);
    b.u16_(4);
    b.u16_(4);
    b.u16_(1);
    b.u16_(0);
    for ([_]u16{ 0xF0FF, 0xFFFF }) |v| b.u16_(v);
    b.u16_(0);
    for ([_]u16{ 0xF020, 0xFFFF }) |v| b.u16_(v);
    for ([_]u16{ @truncate(0x10000 - 0xF020 + 3), 1 }) |v| b.u16_(v);
    for ([_]u16{ 0, 0 }) |v| b.u16_(v);
    std.mem.writeInt(u16, b.buf.items[2..4], @intCast(b.buf.items.len), .big);
    const t = table(&.{.{ 3, 0, b.buf.items }});
    defer testing.allocator.free(t);
    const c = try Cmap.init(t);
    try testing.expect(c.symbol);
    try testing.expectEqual(@as(u16, 3), c.lookup(0xF020));
    try testing.expectEqual(@as(u16, 3), c.lookup(0x20));
    try testing.expectEqual(@as(u16, 4), c.lookup('!'));
    var cov = try c.coverage(testing.allocator);
    defer cov.deinit(testing.allocator);
    try testing.expect(cov.contains(0x41));
    try testing.expect(cov.contains(0xF041));
}

test "coverage ranges match forEachMapping" {
    const f12 = format12(false);
    defer testing.allocator.free(f12);
    const t = table(&.{.{ 3, 10, f12 }});
    defer testing.allocator.free(t);
    const c = try Cmap.init(t);
    const cov = try c.coverage(testing.allocator);
    defer cov.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), cov.ranges.len);
    try testing.expectEqual([2]u21{ 0x41, 0x43 }, cov.ranges[0]);
    try testing.expectEqual([2]u21{ 0x1F600, 0x1F64F }, cov.ranges[1]);
    try testing.expect(!cov.contains(0x44));
}

test "page cache equals slow path on a handcrafted table" {
    const f4 = format4();
    defer testing.allocator.free(f4);
    const t = table(&.{.{ 3, 1, f4 }});
    defer testing.allocator.free(t);
    const c = try Cmap.init(t);
    var pc: cmap.BmpPageCache = .init(testing.allocator);
    defer pc.deinit();
    var cp: u21 = 0;
    while (cp < 0x11000) : (cp += 1) try testing.expectEqual(c.lookupSlow(cp), pc.lookup(&c, cp));
}

test "fuzz: ot-cmap" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            const c = Cmap.initGlyphs(input, 500) catch return;
            var cp: u21 = 0;
            while (cp < 0x400) : (cp += 1) try testing.expect(c.lookup(cp) < 500);
            for ([_]u21{ 0x1F600, 0x10FFFF, 0xFFFF }) |x| try testing.expect(c.lookup(x) < 500);
            _ = c.lookupVariant(0x82A6, 0xE0100);
            // coverage() walks the whole code space; only small formats here.
            if (c.format == 4 and input.len < 512) {
                const cov = c.coverage(testing.allocator) catch return;
                cov.deinit(testing.allocator);
            }
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "ot-cmap") });
}
