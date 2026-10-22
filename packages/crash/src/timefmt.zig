//! Allocation-free UTC civil time for crash file names
//! (`YYYYMMDDTHHMMSSmmmZ-<pid>.zgcrash`), using the days-from-civil
//! algorithm. Safe in a signal handler.

const std = @import("std");

/// A UTC civil timestamp with milliseconds.
pub const Civil = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    ms: u16,
};

/// Converts Unix milliseconds to UTC civil time.
pub fn civilFromUnixMs(unix_ms: i64) Civil {
    const ms: u16 = @intCast(@mod(unix_ms, 1000));
    const secs = @divFloor(unix_ms, 1000);
    const days = @divFloor(secs, 86400);
    const sod: u32 = @intCast(secs - days * 86400);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y: i32 = @intCast(yoe + era * 400 + @intFromBool(m <= 2));
    return .{ .year = y, .month = m, .day = d, .hour = @intCast(sod / 3600), .minute = @intCast(sod / 60 % 60), .second = @intCast(sod % 60), .ms = ms };
}

/// Longest report file name: 19-char timestamp, '-', 10-digit pid, ".zgcrash".
pub const max_name_len = 19 + 1 + 10 + 8;

/// Writes `<YYYYMMDDTHHMMSSmmmZ>-<pid>.zgcrash` into `buf`.
pub fn reportName(buf: *[max_name_len]u8, unix_ms: i64, pid: u32) []const u8 {
    const c = civilFromUnixMs(unix_ms);
    const y: u32 = @intCast(std.math.clamp(c.year, 0, 9999));
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}{d:0>3}Z-{d}.zgcrash", .{
        y, c.month, c.day, c.hour, c.minute, c.second, c.ms, pid,
    }) catch unreachable;
}

/// Parses the timestamp prefix of a report name back to Unix ms.
pub fn parseReportName(name: []const u8) ?i64 {
    if (name.len < 19 or name[8] != 'T' or name[18] != 'Z') return null;
    const n = struct {
        fn f(s: []const u8) ?i64 {
            return std.fmt.parseInt(i64, s, 10) catch null;
        }
    }.f;
    const y = n(name[0..4]) orelse return null;
    const mo = n(name[4..6]) orelse return null;
    const d = n(name[6..8]) orelse return null;
    const h = n(name[9..11]) orelse return null;
    const mi = n(name[11..13]) orelse return null;
    const s = n(name[13..15]) orelse return null;
    const ms = n(name[15..18]) orelse return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;
    const yy = y - @intFromBool(mo <= 2);
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const doy = @divFloor(153 * (if (mo > 2) mo - 3 else mo + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return ((days * 86400 + h * 3600 + mi * 60 + s) * 1000) + ms;
}

test "timefmt: civil conversion table" {
    const cases = [_]struct { i64, []const u8 }{
        .{ 0, "19700101T000000000Z-1.zgcrash" },
        .{ 951782400000, "20000229T000000000Z-1.zgcrash" }, // leap day
        .{ 1761016620123, "20251021T031700123Z-1.zgcrash" },
        .{ 2147483648000, "20380119T031408000Z-1.zgcrash" }, // past 2038
        .{ 4102444799999, "20991231T235959999Z-1.zgcrash" },
        .{ -1, "19691231T235959999Z-1.zgcrash" },
    };
    for (cases) |c| {
        var buf: [max_name_len]u8 = undefined;
        const name = reportName(&buf, c[0], 1);
        try std.testing.expectEqualStrings(c[1], name);
        try std.testing.expectEqual(c[0], parseReportName(name).?);
    }
    var buf: [max_name_len]u8 = undefined;
    try std.testing.expectEqualStrings("20251021T031700123Z-4294967295.zgcrash", reportName(&buf, 1761016620123, 4294967295));
    try std.testing.expect(parseReportName("garbage") == null);
}
