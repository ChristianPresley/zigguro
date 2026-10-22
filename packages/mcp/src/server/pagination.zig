//! Opaque list cursors (PAGINATION): base64url of the page offset and the
//! registry version the page was cut from. A cursor from an older version
//! is stale, and the server answers `-32602` so the client restarts.

const std = @import("std");

/// A decoded cursor.
pub const Cursor = struct {
    offset: u32,
    version: u64,
};

const raw_len = 12;
const b64 = std.base64.url_safe_no_pad;

/// Encoded length of every cursor.
pub const encoded_len = b64.Encoder.calcSize(raw_len);

/// Encodes `c` into `buf`.
pub fn encode(buf: *[encoded_len]u8, c: Cursor) []const u8 {
    var raw: [raw_len]u8 = undefined;
    std.mem.writeInt(u32, raw[0..4], c.offset, .little);
    std.mem.writeInt(u64, raw[4..12], c.version, .little);
    return b64.Encoder.encode(buf, &raw);
}

/// Decodes a cursor, or null when it is malformed.
pub fn decode(s: []const u8) ?Cursor {
    if (s.len != encoded_len) return null;
    var raw: [raw_len]u8 = undefined;
    b64.Decoder.decode(&raw, s) catch return null;
    return .{
        .offset = std.mem.readInt(u32, raw[0..4], .little),
        .version = std.mem.readInt(u64, raw[4..12], .little),
    };
}

/// Why a cursor was refused.
pub const CursorError = error{InvalidCursor};

/// The page offset for `cursor` against a list of `len` items at `version`:
/// 0 without a cursor; `InvalidCursor` when malformed, stale or past the end.
pub fn offsetFor(cursor: ?[]const u8, version: u64, len: usize) CursorError!u32 {
    const s = cursor orelse return 0;
    const c = decode(s) orelse return error.InvalidCursor;
    if (c.version != version or c.offset == 0 or c.offset >= len) return error.InvalidCursor;
    return c.offset;
}

/// The items of the page starting at `offset`, and whether more follow.
pub fn page(comptime T: type, items: []const T, offset: u32, size: u32) struct { []const T, bool } {
    const end = @min(items.len, @as(usize, offset) + size);
    return .{ items[offset..end], end < items.len };
}

const testing = std.testing;

test "pagination: cursor round trip" {
    var buf: [encoded_len]u8 = undefined;
    const s = encode(&buf, .{ .offset = 50, .version = 7 });
    try testing.expectEqual(@as(usize, 16), s.len);
    try testing.expectEqual(Cursor{ .offset = 50, .version = 7 }, decode(s).?);
    try testing.expect(decode("not a cursor") == null);
    try testing.expect(decode("!!!!!!!!!!!!!!!!") == null);
}

test "pagination: stale, malformed and past-the-end cursors" {
    var buf: [encoded_len]u8 = undefined;
    try testing.expectEqual(@as(u32, 0), try offsetFor(null, 3, 10));
    try testing.expectEqual(@as(u32, 5), try offsetFor(encode(&buf, .{ .offset = 5, .version = 3 }), 3, 10));
    try testing.expectError(error.InvalidCursor, offsetFor(encode(&buf, .{ .offset = 5, .version = 2 }), 3, 10));
    try testing.expectError(error.InvalidCursor, offsetFor(encode(&buf, .{ .offset = 10, .version = 3 }), 3, 10));
    try testing.expectError(error.InvalidCursor, offsetFor("zzz", 3, 10));
    const items = [_]u8{ 1, 2, 3, 4, 5 };
    const p, const more = page(u8, &items, 3, 2);
    try testing.expectEqualSlices(u8, &.{ 4, 5 }, p);
    try testing.expect(!more);
}
