//! Entity and numeric character references (CommonMark 0.31.2 §2.5).

const std = @import("std");
const table = @import("entities_table.zig");

/// The UTF-8 text of a named entity ("amp" → "&"), from the HTML5 table.
pub fn decodeEntity(name: []const u8) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = table.entities.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, table.entities[mid].name, name)) {
            .eq => return table.entities[mid].utf8,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

/// A reference at `s[0]` (`&`): its length and decoded UTF-8 (in `buf`
/// for numeric references), or null when `s` does not start with one.
pub fn match(s: []const u8, buf: *[4]u8) ?struct { len: usize, utf8: []const u8 } {
    if (s.len < 3 or s[0] != '&') return null;
    if (s[1] == '#') {
        var i: usize = 2;
        const hex = i < s.len and (s[i] == 'x' or s[i] == 'X');
        if (hex) i += 1;
        const start = i;
        const max: usize = if (hex) 6 else 7;
        while (i < s.len and i - start < max and (if (hex) std.ascii.isHex(s[i]) else std.ascii.isDigit(s[i]))) i += 1;
        if (i == start or i >= s.len or s[i] != ';') return null;
        var cp = std.fmt.parseInt(u32, s[start..i], if (hex) 16 else 10) catch return null;
        if (cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) cp = 0xFFFD;
        const n = std.unicode.utf8Encode(@intCast(cp), buf) catch return null;
        return .{ .len = i + 1, .utf8 = buf[0..n] };
    }
    var i: usize = 1;
    while (i < s.len and i < 40 and std.ascii.isAlphanumeric(s[i])) i += 1;
    if (i == 1 or i >= s.len or s[i] != ';') return null;
    const u = decodeEntity(s[1..i]) orelse return null;
    return .{ .len = i + 1, .utf8 = u };
}

test "entities: named, decimal, hex and invalid" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("&", match("&amp; x", &buf).?.utf8);
    try std.testing.expectEqualStrings("\u{00C6}", match("&AElig;", &buf).?.utf8);
    try std.testing.expectEqualStrings("#", match("&#35;", &buf).?.utf8);
    try std.testing.expectEqualStrings("\u{1F600}", match("&#x1F600;", &buf).?.utf8);
    try std.testing.expectEqualStrings("\u{FFFD}", match("&#0;", &buf).?.utf8);
    try std.testing.expect(match("&#87654321;", &buf) == null);
    try std.testing.expect(match("&nosuch;", &buf) == null);
    try std.testing.expect(match("&amp", &buf) == null);
    try std.testing.expectEqual(@as(usize, 2125), table.entities.len);
}
