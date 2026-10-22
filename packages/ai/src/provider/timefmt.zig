//! Timestamp parsing for rate-limit and retry headers: RFC 3339
//! (`anthropic-ratelimit-*-reset`) and the RFC 9110 IMF-fixdate form of
//! `Retry-After`. Results are Unix milliseconds (UTC).

const std = @import("std");

/// Days from 1970-01-01 to the given civil date (proleptic Gregorian).
pub fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn num(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn toMs(year: i64, month: i64, day: i64, h: i64, mi: i64, sec: i64) ?i64 {
    if (month < 1 or month > 12 or day < 1 or day > 31 or h > 23 or mi > 59 or sec > 60) return null;
    const days = daysFromCivil(year, @intCast(month), @intCast(day));
    return ((days * 24 + h) * 60 + mi) * 60_000 + sec * 1000;
}

/// Parses `2026-10-22T06:30:00Z`, with optional fraction and `±hh:mm` offset.
pub fn parseRfc3339(s: []const u8) ?i64 {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != 't' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return null;
    var ms = toMs(num(s[0..4]) orelse return null, num(s[5..7]) orelse return null, num(s[8..10]) orelse return null, num(s[11..13]) orelse return null, num(s[14..16]) orelse return null, num(s[17..19]) orelse return null) orelse return null;
    var i: usize = 19;
    if (s[i] == '.') {
        i += 1;
        var frac: i64 = 0;
        var digits: u8 = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            if (digits < 3) frac = frac * 10 + (s[i] - '0');
            digits += 1;
        }
        if (digits == 0) return null;
        while (digits < 3) : (digits += 1) frac *= 10;
        ms += frac;
    }
    if (i >= s.len) return null;
    switch (s[i]) {
        'Z', 'z' => return if (i + 1 == s.len) ms else null,
        '+', '-' => {
            if (s.len != i + 6 or s[i + 3] != ':') return null;
            const off = ((num(s[i + 1 .. i + 3]) orelse return null) * 60 + (num(s[i + 4 .. i + 6]) orelse return null)) * 60_000;
            return if (s[i] == '+') ms - off else ms + off;
        },
        else => return null,
    }
}

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// Parses an IMF-fixdate, e.g. `Sun, 06 Nov 1994 08:49:37 GMT`.
pub fn parseHttpDate(s: []const u8) ?i64 {
    if (s.len != 29 or s[3] != ',' or s[4] != ' ' or s[7] != ' ' or s[11] != ' ' or s[16] != ' ' or s[19] != ':' or s[22] != ':' or !std.mem.eql(u8, s[25..], " GMT")) return null;
    const month = for (months, 1..) |m, n| {
        if (std.mem.eql(u8, m, s[8..11])) break n;
    } else return null;
    return toMs(num(s[12..16]) orelse return null, @intCast(month), num(s[5..7]) orelse return null, num(s[17..19]) orelse return null, num(s[20..22]) orelse return null, num(s[23..25]) orelse return null);
}

test "rfc3339" {
    try std.testing.expectEqual(@as(?i64, 0), parseRfc3339("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, 1_792_650_600_000), parseRfc3339("2026-10-22T06:30:00Z"));
    try std.testing.expectEqual(@as(?i64, 1_792_650_600_250), parseRfc3339("2026-10-22T06:30:00.25Z"));
    try std.testing.expectEqual(@as(?i64, 1_792_650_600_000), parseRfc3339("2026-10-22T08:30:00+02:00"));
    try std.testing.expectEqual(@as(?i64, null), parseRfc3339("2026-10-22 garbage"));
    try std.testing.expectEqual(@as(?i64, null), parseRfc3339("2026-13-22T06:30:00Z"));
}

test "http date" {
    try std.testing.expectEqual(@as(?i64, 784_111_777_000), parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT"));
    try std.testing.expectEqual(@as(?i64, null), parseHttpDate("Sunday, 06-Nov-94 08:49:37 GMT"));
    try std.testing.expectEqual(@as(?i64, null), parseHttpDate("Sun, 06 Foo 1994 08:49:37 GMT"));
}
