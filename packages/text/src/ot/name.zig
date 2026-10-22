//! `name`: naming table. Strings are decoded to UTF-8 from UTF-16BE
//! (Unicode and Windows platforms) or MacRoman (Macintosh, encoding 0).

const std = @import("std");
const reader = @import("reader.zig");

/// Well-known name IDs.
pub const NameId = enum(u16) {
    family = 1,
    subfamily = 2,
    full = 4,
    postscript = 6,
    typographic_family = 16,
    typographic_subfamily = 17,
    _,
};

/// A view of the `name` table; an empty table yields no names.
pub const NameTable = struct {
    data: []const u8 = &.{},

    /// The best record for `id` decoded to UTF-8 in `buf`, or null when
    /// absent. Prefers Windows Unicode English (3,1,0x409), then any Windows
    /// Unicode, then the Unicode platform, then Mac Roman English. Output
    /// longer than `buf` is truncated at a code point boundary.
    pub fn get(n: NameTable, id: NameId, buf: []u8) ?[]const u8 {
        const rec = n.find(@intFromEnum(id)) orelse return null;
        return decode(rec.platform, rec.bytes, buf);
    }

    const Rec = struct { platform: u16, bytes: []const u8 };

    fn find(n: NameTable, id: u16) ?Rec {
        const count = reader.readAt(u16, n.data, 2) catch return null;
        const storage = reader.readAt(u16, n.data, 4) catch return null;
        var best: ?Rec = null;
        var best_rank: u8 = 0;
        for (0..count) |i| {
            const off = 6 + i * 12;
            const pid = reader.readAt(u16, n.data, off) catch return best;
            const eid = reader.readAt(u16, n.data, off + 2) catch return best;
            const lang = reader.readAt(u16, n.data, off + 4) catch return best;
            const nid = reader.readAt(u16, n.data, off + 6) catch return best;
            const len = reader.readAt(u16, n.data, off + 8) catch return best;
            const soff = reader.readAt(u16, n.data, off + 10) catch return best;
            if (nid != id) continue;
            const rank: u8 = switch (pid) {
                3 => if ((eid == 1 or eid == 10) and lang == 0x409) 5 else if (eid == 1 or eid == 10) 4 else 0,
                0 => 3,
                1 => if (eid == 0 and lang == 0) 2 else 0,
                else => 0,
            };
            if (rank <= best_rank) continue;
            const bytes = reader.subLen(n.data, @as(usize, storage) + soff, len) catch continue;
            best = .{ .platform = pid, .bytes = bytes };
            best_rank = rank;
            if (rank == 5) break;
        }
        return best;
    }
};

/// Decodes a name record's bytes for `platform` into UTF-8 in `buf`.
pub fn decode(platform: u16, bytes: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    if (platform == 1) {
        for (bytes) |c| {
            const cp: u21 = if (c < 0x80) c else mac_roman_high[c - 0x80];
            if (!put(buf, &n, cp)) break;
        }
        return buf[0..n];
    }
    var i: usize = 0;
    while (i + 2 <= bytes.len) {
        const u = std.mem.readInt(u16, bytes[i..][0..2], .big);
        i += 2;
        var cp: u21 = u;
        if (u >= 0xD800 and u <= 0xDBFF) {
            if (i + 2 <= bytes.len) {
                const lo = std.mem.readInt(u16, bytes[i..][0..2], .big);
                if (lo >= 0xDC00 and lo <= 0xDFFF) {
                    i += 2;
                    cp = 0x10000 + ((@as(u21, u) - 0xD800) << 10) + (lo - 0xDC00);
                } else cp = 0xFFFD;
            } else cp = 0xFFFD;
        } else if (u >= 0xDC00 and u <= 0xDFFF) cp = 0xFFFD;
        if (!put(buf, &n, cp)) break;
    }
    return buf[0..n];
}

fn put(buf: []u8, n: *usize, cp: u21) bool {
    var tmp: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &tmp) catch std.unicode.utf8Encode(0xFFFD, &tmp) catch unreachable;
    if (buf.len - n.* < len) return false;
    @memcpy(buf[n.*..][0..len], tmp[0..len]);
    n.* += len;
    return true;
}

/// MacRoman bytes 0x80..0xFF as code points.
pub const mac_roman_high = [128]u16{
    0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1,
    0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8,
    0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3,
    0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC,
    0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF,
    0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8,
    0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211,
    0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8,
    0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB,
    0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153,
    0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA,
    0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
    0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1,
    0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4,
    0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC,
    0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7,
};

test "name decoding: UTF-16 surrogates, lone surrogates and MacRoman" {
    var buf: [64]u8 = undefined;
    // "A" U+1F600 lone-high "B"
    const utf16 = [_]u8{ 0, 'A', 0xD8, 0x3D, 0xDE, 0x00, 0xD8, 0x00, 0, 'B' };
    try std.testing.expectEqualStrings("A\u{1F600}\u{FFFD}B", decode(3, &utf16, &buf));
    const mac = [_]u8{ 'C', 'a', 'f', 0x8E, 0xA5 };
    try std.testing.expectEqualStrings("Café•", decode(1, &mac, &buf));
    // Truncation stops at a code point boundary.
    try std.testing.expectEqualStrings("Caf", decode(1, &mac, buf[0..4]));
}

test "name record preference" {
    // Two records for id 1: Mac "Mac", Windows "Win".
    var t: [6 + 24 + 9]u8 = undefined;
    std.mem.writeInt(u16, t[0..2], 0, .big);
    std.mem.writeInt(u16, t[2..4], 2, .big);
    std.mem.writeInt(u16, t[4..6], 30, .big);
    const recs = [_][6]u16{ .{ 1, 0, 0, 1, 3, 0 }, .{ 3, 1, 0x409, 1, 6, 3 } };
    for (recs, 0..) |r, i| for (r, 0..) |v, j| std.mem.writeInt(u16, t[6 + i * 12 + j * 2 ..][0..2], v, .big);
    @memcpy(t[30..33], "Mac");
    @memcpy(t[33..39], &[_]u8{ 0, 'W', 0, 'i', 0, 'n' });
    var buf: [16]u8 = undefined;
    const n: NameTable = .{ .data = &t };
    try std.testing.expectEqualStrings("Win", n.get(.family, &buf).?);
    try std.testing.expect(n.get(.full, &buf) == null);
}
