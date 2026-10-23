//! Cron expressions (E13.F02.S01.T01): the five POSIX fields with names,
//! `7` as Sunday and the `@daily`-style macros; the next matching local
//! time found field by field; and the next instant in a time zone, with
//! deterministic daylight-saving rules. No allocation.
//!
//! Day matching follows POSIX (and vixie-cron): when both day-of-month and
//! day-of-week are restricted, a day matches if either does; when one is
//! `*`, only the other applies.
//!
//! Daylight saving: a wall time that occurs twice (clocks back) fires once,
//! at the earlier instant; a wall time that does not exist (clocks forward)
//! fires at the first valid instant after the gap (02:30 in a 02:00 to
//! 03:00 gap fires at 03:00).

const std = @import("std");
const zone = @import("zone.zig");

pub const LocalDateTime = zone.LocalDateTime;
pub const ZoneResolver = zone.ZoneResolver;

pub const ParseError = error{ FieldCount, BadNumber, OutOfRange, BadRange, BadStep, BadName, UnsupportedSyntax };

/// Where a parse failed.
pub const Diag = struct {
    /// The offending token (a view into the input).
    token: []const u8 = "",
};

const Field = enum(u3) {
    minute,
    hour,
    dom,
    month,
    dow,

    fn min(f: Field) u8 {
        return switch (f) {
            .dom, .month => 1,
            else => 0,
        };
    }

    fn max(f: Field) u8 {
        return switch (f) {
            .minute => 59,
            .hour => 23,
            .dom => 31,
            .month => 12,
            .dow => 7,
        };
    }
};

const month_names = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
const dow_names = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };

/// The longest search: five years of local time.
pub const max_years = 5;

pub const CronExpr = struct {
    minutes: u64,
    hours: u32,
    /// Bits 1..31.
    dom: u32,
    /// Bits 1..12.
    months: u16,
    /// Bits 0..6 (0 = Sunday).
    dow: u8,
    /// The field was literally `*` (`*/2` is not).
    dom_star: bool,
    dow_star: bool,

    pub fn parse(s: []const u8) ParseError!CronExpr {
        return parseDiag(s, null);
    }

    pub fn parseDiag(s: []const u8, diag: ?*Diag) ParseError!CronExpr {
        const t = std.mem.trim(u8, s, " \t\r\n");
        if (t.len > 0 and t[0] == '@') return macro(t, diag);
        var fields: [5][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, t, " \t");
        while (it.next()) |f| {
            if (n == 5) {
                // Six fields: a seconds (or year) field.
                if (diag) |d| d.token = f;
                return if (n == 5 and it.next() == null) error.UnsupportedSyntax else error.FieldCount;
            }
            fields[n] = f;
            n += 1;
        }
        if (n != 5) return error.FieldCount;
        var c: CronExpr = undefined;
        c.minutes = try parseField(u64, fields[0], .minute, diag);
        c.hours = try parseField(u32, fields[1], .hour, diag);
        c.dom = try parseField(u32, fields[2], .dom, diag);
        c.months = try parseField(u16, fields[3], .month, diag);
        const dow = try parseField(u16, fields[4], .dow, diag);
        // 7 is Sunday.
        c.dow = @truncate((dow | (dow >> 7)) & 0x7f);
        c.dom_star = std.mem.eql(u8, fields[2], "*");
        c.dow_star = std.mem.eql(u8, fields[4], "*");
        return c;
    }

    fn macro(t: []const u8, diag: ?*Diag) ParseError!CronExpr {
        const name = t[1..];
        const table = [_]struct { []const u8, []const u8 }{
            .{ "yearly", "0 0 1 1 *" },
            .{ "annually", "0 0 1 1 *" },
            .{ "monthly", "0 0 1 * *" },
            .{ "weekly", "0 0 * * 0" },
            .{ "daily", "0 0 * * *" },
            .{ "midnight", "0 0 * * *" },
            .{ "hourly", "0 * * * *" },
        };
        for (table) |e| if (std.ascii.eqlIgnoreCase(name, e[0])) return parse(e[1]);
        if (diag) |d| d.token = t;
        if (std.ascii.eqlIgnoreCase(name, "reboot")) return error.UnsupportedSyntax;
        return error.BadName;
    }

    /// Whether the date matches the day, month and weekday fields.
    pub fn matchesDate(c: *const CronExpr, y: u16, m: u4, d: u5, dow: u3) bool {
        _ = y;
        if (c.months & (@as(u16, 1) << m) == 0) return false;
        const dom_ok = c.dom & (@as(u32, 1) << d) != 0;
        const dow_ok = c.dow & (@as(u8, 1) << dow) != 0;
        if (c.dom_star and c.dow_star) return true;
        if (c.dom_star) return dow_ok;
        if (c.dow_star) return dom_ok;
        return dom_ok or dow_ok;
    }

    /// The first matching minute strictly after `after`, or null when
    /// none comes within five years.
    pub fn nextLocal(c: *const CronExpr, after: LocalDateTime) ?LocalDateTime {
        var y: u16 = after.year;
        var mo: u4 = after.month;
        var d: u5 = after.day;
        var h: u8 = after.hour;
        var mi: u8 = @as(u8, after.minute) + 1;
        if (mi == 60) {
            mi = 0;
            h += 1;
        }
        if (h == 24) {
            h = 0;
            if (!advanceDay(&y, &mo, &d)) return null;
        }
        const limit = after.year +| max_years;
        while (y <= limit) {
            // Month.
            if (c.months & (@as(u16, 1) << mo) == 0) {
                if (nextBit(u16, c.months, @as(u8, mo) + 1)) |m| {
                    mo = @intCast(m);
                } else {
                    if (y >= 9999) return null;
                    y += 1;
                    mo = @intCast(nextBit(u16, c.months, 1) orelse return null);
                }
                d = 1;
                h = 0;
                mi = 0;
                continue;
            }
            // Day.
            if (d > zone.daysInMonth(y, mo) or !c.matchesDate(y, mo, d, zone.weekday(y, mo, d))) {
                if (!advanceDay(&y, &mo, &d)) return null;
                h = 0;
                mi = 0;
                continue;
            }
            // Hour.
            const hour = nextBit(u32, c.hours, h) orelse {
                if (!advanceDay(&y, &mo, &d)) return null;
                h = 0;
                mi = 0;
                continue;
            };
            if (hour != h) {
                h = hour;
                mi = 0;
            }
            // Minute.
            const minute = nextBit(u64, c.minutes, mi) orelse {
                h += 1;
                mi = 0;
                if (h == 24) {
                    h = 0;
                    if (!advanceDay(&y, &mo, &d)) return null;
                }
                continue;
            };
            return .{ .year = y, .month = mo, .day = d, .hour = @intCast(h), .minute = @intCast(minute) };
        }
        return null;
    }

    /// The first fire instant (unix seconds) strictly after `after_unix_s`
    /// in `z`, or null when none comes within five years.
    pub fn next(c: *const CronExpr, z: ZoneResolver, after_unix_s: i64) ?i64 {
        var local = z.toLocal(z.ctx, after_unix_s);
        // Each round moves at least a minute forward in local time.
        var rounds: u32 = 0;
        while (rounds < 100_000) : (rounds += 1) {
            const cand = c.nextLocal(local) orelse return null;
            switch (z.fromLocal(z.ctx, cand)) {
                .unique => |t| if (t > after_unix_s) return t,
                // Runs once: the earlier instant, never the repeat.
                .ambiguous => |ts| if (ts[0] > after_unix_s) return ts[0],
                .gap => |t| if (t > after_unix_s) return t,
            }
            local = cand;
        }
        return null;
    }
};

/// Steps to the next day; false past year 9999.
fn advanceDay(y: *u16, mo: *u4, d: *u5) bool {
    if (d.* < zone.daysInMonth(y.*, mo.*)) {
        d.* += 1;
        return true;
    }
    d.* = 1;
    if (mo.* < 12) {
        mo.* += 1;
        return true;
    }
    mo.* = 1;
    if (y.* >= 9999) return false;
    y.* += 1;
    return true;
}

/// The lowest set bit of `mask` at or above `from`.
fn nextBit(comptime T: type, mask: T, from: u8) ?u8 {
    if (from >= @bitSizeOf(T)) return null;
    const shifted = mask >> @intCast(from);
    if (shifted == 0) return null;
    return from + @as(u8, @intCast(@ctz(shifted)));
}

fn parseField(comptime T: type, s: []const u8, f: Field, diag: ?*Diag) ParseError!T {
    var mask: T = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |item| {
        errdefer if (diag) |d| if (d.token.len == 0) {
            d.token = item;
        };
        if (item.len == 0) return error.BadNumber;
        for (item) |ch| switch (ch) {
            'L', 'W', '#', '?' => {
                if (diag) |d| d.token = item;
                return error.UnsupportedSyntax;
            },
            else => {},
        };
        var range = item;
        var step: u8 = 1;
        var has_step = false;
        if (std.mem.indexOfScalar(u8, item, '/')) |slash| {
            range = item[0..slash];
            step = std.fmt.parseInt(u8, item[slash + 1 ..], 10) catch return error.BadStep;
            if (step == 0) return error.BadStep;
            has_step = true;
        }
        var lo: u8 = f.min();
        var hi: u8 = f.max();
        if (std.mem.eql(u8, range, "*")) {
            if (f == .dow) hi = 6;
        } else if (std.mem.indexOfScalar(u8, range, '-')) |dash| {
            lo = try value(range[0..dash], f);
            hi = try value(range[dash + 1 ..], f);
            if (lo > hi) return error.BadRange;
        } else {
            lo = try value(range, f);
            // `N/S` runs to the field's maximum.
            hi = if (has_step) (if (f == .dow) 6 else f.max()) else lo;
        }
        var v: u16 = lo;
        while (v <= hi) : (v += step) mask |= @as(T, 1) << @intCast(v);
    }
    return mask;
}

fn value(s: []const u8, f: Field) ParseError!u8 {
    if (s.len == 0) return error.BadNumber;
    if (std.ascii.isAlphabetic(s[0])) {
        const names: []const []const u8 = switch (f) {
            .month => &month_names,
            .dow => &dow_names,
            else => return error.BadName,
        };
        for (names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(s, n)) return @intCast(i + @as(usize, f.min()));
        return error.BadName;
    }
    const v = std.fmt.parseInt(u8, s, 10) catch |e| return switch (e) {
        error.Overflow => error.OutOfRange,
        error.InvalidCharacter => error.BadNumber,
    };
    if (v < f.min() or v > f.max()) return error.OutOfRange;
    return v;
}
