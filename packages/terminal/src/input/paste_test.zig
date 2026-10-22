//! Paste encoding tests and the `paste_sanitize` fuzz target.

const std = @import("std");
const testing = std.testing;
const ke = @import("key_encode.zig");
const paste = @import("paste.zig");
const gpa = testing.allocator;

fn run(st: ke.EncoderState, text: []const u8, o: paste.PasteOptions, out: *std.ArrayList(u8)) !paste.PasteVerdict {
    return paste.encodePaste(&st, text, o, out, gpa);
}

test "newlines become CR and multi-line unbracketed pastes need confirmation" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try testing.expectEqual(.needs_confirmation, try run(.{}, "a\r\nb\nc", .{}, &out));
    try testing.expectEqualStrings("a\rb\rc", out.items);
    try testing.expectEqual(.send, try run(.{}, "a\nb", .{ .confirm_multiline = false }, &out));
    try testing.expectEqual(.send, try run(.{}, "one line", .{}, &out));
}

test "unsafe controls are stripped" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    _ = try run(.{}, "a\x01\tb\x7f\xc2\x85c\x1b[31m", .{}, &out);
    try testing.expectEqualStrings("a\tbc[31m", out.items);
    _ = try run(.{}, "a\x01\tb", .{ .strip_controls = .all }, &out);
    try testing.expectEqualStrings("ab", out.items);
    _ = try run(.{}, "a\x01\x1b\xc2\x85", .{ .strip_controls = .none }, &out);
    try testing.expectEqualStrings("a\x01\x1b\xc2\x85", out.items);
}

test "bracketed paste wraps and neutralises embedded markers" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const st: ke.EncoderState = .{ .bracketed_paste = true };
    try testing.expectEqual(.send, try run(st, "x\x1b[201~y\nz", .{}, &out));
    try testing.expectEqualStrings("\x1b[200~x[201~y\rz\x1b[201~", out.items);
    // ESC goes even when other controls are kept.
    _ = try run(st, "\x1b[201~", .{ .strip_controls = .none }, &out);
    try testing.expectEqualStrings("\x1b[200~[201~\x1b[201~", out.items);
    // The option can turn bracketing off.
    _ = try run(st, "q", .{ .bracketed = false }, &out);
    try testing.expectEqualStrings("q", out.items);
}

test "too large pastes are refused" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try testing.expectEqual(.too_large, try run(.{}, "abcdef", .{ .max_bytes = 5 }, &out));
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "10 MiB pastes go out in 64 KiB chunks" {
    const big = try gpa.alloc(u8, 10 << 20);
    defer gpa.free(big);
    @memset(big, 'x');
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try testing.expectEqual(.send, try run(.{ .bracketed_paste = true }, big, .{}, &out));
    const Counter = struct {
        chunks: usize = 0,
        bytes: usize = 0,
        fn write(c: *@This(), b: []const u8) anyerror!void {
            try testing.expect(b.len <= 64 << 10);
            c.chunks += 1;
            c.bytes += b.len;
        }
    };
    var c: Counter = .{};
    try paste.writeChunked(out.items, 64 << 10, &c, Counter.write);
    try testing.expectEqual(out.items.len, c.bytes);
    try testing.expectEqual(@as(usize, 161), c.chunks);
}

fn fuzzPaste(_: void, s: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const text = buf[0..s.slice(&buf)];
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const strip = s.valueRangeAtMost(u8, 0, 2);
    const o: paste.PasteOptions = .{ .strip_controls = @enumFromInt(strip) };
    _ = try run(.{ .bracketed_paste = true }, text, o, &out);
    // Exactly one end marker, at the end, and one start marker, at the start.
    try testing.expect(std.mem.startsWith(u8, out.items, paste.start_marker));
    try testing.expect(std.mem.endsWith(u8, out.items, paste.end_marker));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, paste.end_marker));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.items, "\x1b"));
}

test "fuzz: paste_sanitize" {
    try std.testing.fuzz({}, fuzzPaste, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "paste_sanitize") });
}
