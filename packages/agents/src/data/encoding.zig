//! Text encodings of data files (E13.F06.S01.T01): a byte order mark
//! picks UTF-8 or UTF-16 (LE/BE); UTF-16 is transcoded to UTF-8 once at
//! open. A file without a BOM whose first 64 KiB isn't valid UTF-8 is
//! read as Latin-1, converted cell by cell when shown (and flagged).

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Encoding = enum { utf8, utf8_bom, utf16le, utf16be, latin1 };

/// The encoding named by `bytes`' BOM, else UTF-8 or (when the first
/// 64 KiB isn't valid UTF-8) Latin-1.
pub fn detect(bytes: []const u8) Encoding {
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) return .utf8_bom;
    if (std.mem.startsWith(u8, bytes, "\xFF\xFE")) return .utf16le;
    if (std.mem.startsWith(u8, bytes, "\xFE\xFF")) return .utf16be;
    return if (validUtf8Prefix(bytes[0..@min(bytes.len, 64 << 10)], bytes.len > 64 << 10)) .utf8 else .latin1;
}

/// Bytes of the BOM for `e`.
pub fn bomLen(e: Encoding) usize {
    return switch (e) {
        .utf8_bom => 3,
        .utf16le, .utf16be => 2,
        .utf8, .latin1 => 0,
    };
}

/// Whether `s` is valid UTF-8; when `cut` (the sample was cut from a
/// longer file) a sequence broken by the cut is allowed.
pub fn validUtf8Prefix(s: []const u8, cut: bool) bool {
    var end = s.len;
    if (cut) {
        // Drop an incomplete trailing sequence (at most 3 bytes).
        var i = s.len;
        while (i > 0 and s.len - i < 4) {
            i -= 1;
            const c = s[i];
            if (c & 0xC0 == 0x80) continue;
            const need: usize = if (c < 0x80) 1 else if (c >> 5 == 0b110) 2 else if (c >> 4 == 0b1110) 3 else if (c >> 3 == 0b11110) 4 else 1;
            if (i + need > s.len) end = i;
            break;
        }
    }
    return std.unicode.utf8ValidateSlice(s[0..end]);
}

/// UTF-16 (after the BOM) as UTF-8; unpaired surrogates become U+FFFD and
/// an odd trailing byte is dropped.
pub fn utf16ToUtf8(gpa: Allocator, bytes: []const u8, big_endian: bool) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, bytes.len + bytes.len / 2);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i + 1 < bytes.len) {
        const u = unit(bytes, i, big_endian);
        i += 2;
        var cp: u21 = u;
        if (u >= 0xD800 and u <= 0xDBFF) {
            if (i + 1 < bytes.len) {
                const lo = unit(bytes, i, big_endian);
                if (lo >= 0xDC00 and lo <= 0xDFFF) {
                    cp = 0x10000 + ((@as(u21, u) - 0xD800) << 10) + (lo - 0xDC00);
                    i += 2;
                } else cp = 0xFFFD;
            } else cp = 0xFFFD;
        } else if (u >= 0xDC00 and u <= 0xDFFF) cp = 0xFFFD;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

fn unit(bytes: []const u8, i: usize, big_endian: bool) u16 {
    return if (big_endian) @as(u16, bytes[i]) << 8 | bytes[i + 1] else @as(u16, bytes[i + 1]) << 8 | bytes[i];
}

/// Latin-1 text as UTF-8 (ASCII text is returned as is).
pub fn latin1ToUtf8(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var high: usize = 0;
    for (s) |c| high += @intFromBool(c >= 0x80);
    if (high == 0) return s;
    const out = try a.alloc(u8, s.len + high);
    var j: usize = 0;
    for (s) |c| {
        if (c < 0x80) {
            out[j] = c;
            j += 1;
        } else {
            out[j] = 0xC0 | (c >> 6);
            out[j + 1] = 0x80 | (c & 0x3F);
            j += 2;
        }
    }
    return out;
}
