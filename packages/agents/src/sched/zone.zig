//! Local date-times and time zones for the scheduler (E13.F02.S01.T01):
//! `LocalDateTime`, the `ZoneResolver` interface (local wall time to
//! instant, with daylight-saving gaps and overlaps), and the UTC and
//! fixed-offset resolvers. The IANA zones are E13.F02.S01.T04. Pure.

const std = @import("std");

pub const LocalDateTime = struct {
    year: u16,
    month: u4,
    day: u5,
    hour: u5 = 0,
    minute: u6 = 0,
    second: u6 = 0,

    pub fn order(a: LocalDateTime, b: LocalDateTime) std.math.Order {
        return std.math.order(a.key(), b.key());
    }

    fn key(l: LocalDateTime) u64 {
        return (@as(u64, l.year) << 26) | (@as(u64, l.month) << 22) | (@as(u64, l.day) << 17) |
            (@as(u64, l.hour) << 12) | (@as(u64, l.minute) << 6) | l.second;
    }

    /// Seconds since 1970-01-01 00:00 of this wall time read as UTC.
    pub fn toUnixUtc(l: LocalDateTime) i64 {
        return daysFromCivil(l.year, l.month, l.day) * 86_400 + @as(i64, l.hour) * 3600 + @as(i64, l.minute) * 60 + l.second;
    }

    /// The UTC wall time of `unix_s` (years 1970..9999).
    pub fn fromUnixUtc(unix_s: i64) LocalDateTime {
        const days = @divFloor(unix_s, 86_400);
        const secs: u32 = @intCast(unix_s - days * 86_400);
        const c = civilFromDays(days);
        return .{
            .year = c.year,
            .month = c.month,
            .day = c.day,
            .hour = @intCast(secs / 3600),
            .minute = @intCast(secs / 60 % 60),
            .second = @intCast(secs % 60),
        };
    }

    pub fn format(l: LocalDateTime, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ l.year, l.month, l.day, l.hour, l.minute, l.second });
    }
};

/// Days since 1970-01-01 (proleptic Gregorian; H. Hinnant's algorithm).
pub fn daysFromCivil(year: u16, month: u4, day: u5) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

pub fn civilFromDays(days: i64) struct { year: u16, month: u4, day: u5 } {
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @intFromBool(m <= 2);
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
}

/// 0 = Sunday.
pub fn weekday(year: u16, month: u4, day: u5) u3 {
    return @intCast(@mod(daysFromCivil(year, month, day) + 4, 7));
}

pub fn isLeap(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

pub fn daysInMonth(year: u16, month: u4) u5 {
    return switch (month) {
        2 => if (isLeap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// A wall time's instant(s) in a zone.
pub const Resolved = union(enum) {
    unique: i64,
    /// The wall time occurs twice (the clocks went back): both instants,
    /// earlier first.
    ambiguous: [2]i64,
    /// The wall time does not exist (the clocks went forward): the first
    /// valid instant after it.
    gap: i64,
};

pub const ZoneResolver = struct {
    ctx: *const anyopaque,
    fromLocal: *const fn (ctx: *const anyopaque, l: LocalDateTime) Resolved,
    toLocal: *const fn (ctx: *const anyopaque, unix_s: i64) LocalDateTime,
};

pub const FixedZone = struct {
    /// Seconds east of UTC.
    offset_s: i32,

    pub fn resolver(z: *const FixedZone) ZoneResolver {
        return .{ .ctx = z, .fromLocal = fromLocal, .toLocal = toLocal };
    }

    fn fromLocal(ctx: *const anyopaque, l: LocalDateTime) Resolved {
        const z: *const FixedZone = @ptrCast(@alignCast(ctx));
        return .{ .unique = l.toUnixUtc() - z.offset_s };
    }

    fn toLocal(ctx: *const anyopaque, unix_s: i64) LocalDateTime {
        const z: *const FixedZone = @ptrCast(@alignCast(ctx));
        return .fromUnixUtc(unix_s + z.offset_s);
    }
};

const utc_zone: FixedZone = .{ .offset_s = 0 };

pub fn utcZone() ZoneResolver {
    return utc_zone.resolver();
}

const testing = std.testing;

test "civil day round trip and weekdays" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(u3, 4), weekday(1970, 1, 1)); // Thursday
    try testing.expectEqual(@as(u3, 5), weekday(2026, 10, 23)); // Friday
    try testing.expectEqual(@as(u3, 2), weekday(2000, 2, 29)); // Tuesday
    var d: i64 = -1000;
    while (d < 200_000) : (d += 37) {
        if (d < 0) continue;
        const c = civilFromDays(d);
        try testing.expectEqual(d, daysFromCivil(c.year, c.month, c.day));
    }
    const l: LocalDateTime = .{ .year = 2026, .month = 3, .day = 29, .hour = 1, .minute = 30, .second = 5 };
    try testing.expectEqual(l, LocalDateTime.fromUnixUtc(l.toUnixUtc()));
    try testing.expectEqual(@as(u5, 29), daysInMonth(2024, 2));
    try testing.expectEqual(@as(u5, 28), daysInMonth(2100, 2));
}
