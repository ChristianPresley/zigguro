//! Local time without libc (E08.F07.S02.T01). Linux and other Unixes read
//! the TZif zone (`$TZ` naming a zoneinfo file, `:path`, or
//! `/etc/localtime`) with `std.tz` and, past its last transition, apply
//! its POSIX TZ footer rule (`CET-1CEST,M3.5.0,M10.5.0/3`). A `$TZ` that
//! is itself a rule string works too. Windows asks kernel32 for the
//! offset at each instant. Offsets are cached per hour. Unreadable zones
//! fall back to UTC with a warning.
//!
//! If E00/E15 later provide a shared local-time helper, switch to it.

const std = @import("std");
const builtin = @import("builtin");
const datefmt = @import("datefmt.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const LocalTz = struct {
    gpa: Allocator,
    mode: Mode = .utc,
    tz: ?std.tz.Tz = null,
    rule: ?PosixRule = null,
    cache_hour: i64 = std.math.minInt(i64),
    cache_off: i32 = 0,

    pub const Mode = enum { utc, tzif, rule, windows };

    pub fn utc(gpa: Allocator) LocalTz {
        return .{ .gpa = gpa };
    }

    /// The process's local zone.
    pub fn load(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) !LocalTz {
        if (builtin.os.tag == .windows) return .{ .gpa = gpa, .mode = .windows };
        if (env.get("TZ")) |tzv| if (tzv.len > 0) {
            const name = if (tzv[0] == ':') tzv[1..] else tzv;
            const path = if (name.len > 0 and name[0] == '/')
                try gpa.dupe(u8, name)
            else
                try std.fmt.allocPrint(gpa, "/usr/share/zoneinfo/{s}", .{name});
            defer gpa.free(path);
            if (fromFile(gpa, io, path)) |z| return z else |_| {}
            if (tzv[0] != ':') if (PosixRule.parse(tzv)) |r| return .{ .gpa = gpa, .mode = .rule, .rule = r };
            std.log.warn("TZ={s}: unknown zone, using UTC", .{tzv});
            return utc(gpa);
        };
        return fromFile(gpa, io, "/etc/localtime") catch {
            std.log.warn("/etc/localtime unreadable, using UTC", .{});
            return utc(gpa);
        };
    }

    pub fn fromFile(gpa: Allocator, io: Io, path: []const u8) !LocalTz {
        const f = try Io.Dir.openFileAbsolute(io, path, .{});
        defer f.close(io);
        var buf: [4096]u8 = undefined;
        var r = f.reader(io, &buf);
        const bytes = try r.interface.allocRemaining(gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        return fromTzif(gpa, bytes);
    }

    /// From TZif bytes.
    pub fn fromTzif(gpa: Allocator, bytes: []const u8) !LocalTz {
        var r: Io.Reader = .fixed(bytes);
        const tz = try std.tz.Tz.parse(gpa, &r);
        const rule = if (tz.footer) |ft| PosixRule.parse(ft) else null;
        return .{ .gpa = gpa, .mode = .tzif, .tz = tz, .rule = rule };
    }

    pub fn deinit(z: *LocalTz) void {
        if (z.tz) |*t| t.deinit();
        z.* = utc(z.gpa);
    }

    /// Seconds east of UTC at Unix time `unix_s`.
    pub fn offsetAt(z: *LocalTz, unix_s: i64) i32 {
        const hour = @divFloor(unix_s, 3600);
        if (hour == z.cache_hour) return z.cache_off;
        // Transitions may fall inside an hour: cache only whole hours
        // with no transition in them.
        const off = z.compute(unix_s);
        if (z.compute(hour * 3600) == off and z.compute(hour * 3600 + 3599) == off) {
            z.cache_hour = hour;
            z.cache_off = off;
        }
        return off;
    }

    fn compute(z: *const LocalTz, unix_s: i64) i32 {
        return switch (z.mode) {
            .utc => 0,
            .rule => z.rule.?.offsetAt(unix_s),
            .windows => windowsOffset(unix_s),
            .tzif => {
                const tz = z.tz.?;
                const ts = tz.transitions;
                if (ts.len == 0 or unix_s < ts[0].ts) {
                    if (ts.len == 0 and z.rule != null) return z.rule.?.offsetAt(unix_s);
                    return if (tz.timetypes.len > 0) tz.timetypes[0].offset else 0;
                }
                if (unix_s >= ts[ts.len - 1].ts) if (z.rule) |r| return r.offsetAt(unix_s);
                // The last transition at or before `unix_s`.
                var lo: usize = 0;
                var hi: usize = ts.len;
                while (hi - lo > 1) {
                    const mid = (lo + hi) / 2;
                    if (ts[mid].ts <= unix_s) lo = mid else hi = mid;
                }
                return ts[lo].timetype.offset;
            },
        };
    }
};

/// Now, in local time.
pub fn nowLocal(io: Io, tz: *LocalTz) datefmt.DateTime {
    const now = Io.Timestamp.now(io, .real).toSeconds();
    return datefmt.fromUnix(now, tz.offsetAt(now));
}

/// A POSIX TZ rule: `std offset [dst [offset] [,start[/time],end[/time]]]`.
pub const PosixRule = struct {
    /// Seconds east of UTC.
    std_off: i32,
    dst_off: ?i32 = null,
    start: Day = .{},
    start_time: i32 = 7200,
    end: Day = .{},
    end_time: i32 = 7200,

    pub const Day = struct {
        kind: enum { month_week_day, julian1, julian0 } = .month_week_day,
        month: u8 = 3,
        week: u8 = 2,
        wday: u8 = 0,
        n: u16 = 0,
    };

    pub fn parse(s: []const u8) ?PosixRule {
        var i: usize = 0;
        if (!skipName(s, &i)) return null;
        const so = parseOffset(s, &i) orelse return null;
        var r: PosixRule = .{ .std_off = -so };
        if (i == s.len) return r;
        if (!skipName(s, &i)) return null;
        r.dst_off = r.std_off + 3600;
        if (i < s.len and s[i] != ',') r.dst_off = -(parseOffset(s, &i) orelse return null);
        if (i == s.len) {
            // US rules are the POSIX default; no zone relies on it today.
            r.start = .{ .month = 3, .week = 2, .wday = 0 };
            r.end = .{ .month = 11, .week = 1, .wday = 0 };
            return r;
        }
        if (s[i] != ',') return null;
        i += 1;
        r.start = parseDay(s, &i) orelse return null;
        if (i < s.len and s[i] == '/') {
            i += 1;
            r.start_time = parseOffset(s, &i) orelse return null;
        }
        if (i >= s.len or s[i] != ',') return null;
        i += 1;
        r.end = parseDay(s, &i) orelse return null;
        if (i < s.len and s[i] == '/') {
            i += 1;
            r.end_time = parseOffset(s, &i) orelse return null;
        }
        if (i != s.len) return null;
        return r;
    }

    fn skipName(s: []const u8, i: *usize) bool {
        if (i.* < s.len and s[i.*] == '<') {
            const e = std.mem.indexOfScalarPos(u8, s, i.*, '>') orelse return false;
            i.* = e + 1;
            return true;
        }
        const st = i.*;
        while (i.* < s.len and std.ascii.isAlphabetic(s[i.*])) i.* += 1;
        return i.* - st >= 3;
    }

    /// `[+-]hh[:mm[:ss]]` in seconds (as written: west positive).
    fn parseOffset(s: []const u8, i: *usize) ?i32 {
        var sign: i32 = 1;
        if (i.* < s.len and (s[i.*] == '+' or s[i.*] == '-')) {
            if (s[i.*] == '-') sign = -1;
            i.* += 1;
        }
        var total: i32 = 0;
        for ([_]i32{ 3600, 60, 1 }, 0..) |mult, part| {
            const st = i.*;
            var n: i32 = 0;
            while (i.* < s.len and std.ascii.isDigit(s[i.*]) and i.* - st < 3) : (i.* += 1) n = n * 10 + s[i.*] - '0';
            if (i.* == st) return null;
            total += n * mult;
            if (i.* < s.len and s[i.*] == ':' and part < 2) i.* += 1 else break;
        }
        return sign * total;
    }

    fn parseDay(s: []const u8, i: *usize) ?Day {
        var d: Day = .{};
        if (i.* < s.len and s[i.*] == 'M') {
            i.* += 1;
            d.month = @intCast(num(s, i) orelse return null);
            if (i.* >= s.len or s[i.*] != '.') return null;
            i.* += 1;
            d.week = @intCast(num(s, i) orelse return null);
            if (i.* >= s.len or s[i.*] != '.') return null;
            i.* += 1;
            d.wday = @intCast(num(s, i) orelse return null);
            if (d.month < 1 or d.month > 12 or d.week < 1 or d.week > 5 or d.wday > 6) return null;
            return d;
        }
        if (i.* < s.len and s[i.*] == 'J') {
            i.* += 1;
            d.kind = .julian1;
        } else d.kind = .julian0;
        d.n = @intCast(num(s, i) orelse return null);
        return d;
    }

    fn num(s: []const u8, i: *usize) ?u32 {
        const st = i.*;
        var n: u32 = 0;
        while (i.* < s.len and std.ascii.isDigit(s[i.*]) and i.* - st < 4) : (i.* += 1) n = n * 10 + (s[i.*] - '0');
        return if (i.* == st) null else n;
    }

    /// The day (days since the epoch) `d` names in `year`.
    fn dayOf(d: Day, year: i32) i64 {
        const jan1 = datefmt.daysFromCivil(.{ .y = year, .m = 1, .d = 1 });
        switch (d.kind) {
            .julian0 => return jan1 + d.n,
            .julian1 => {
                // 1..365, February 29 never counted.
                var n: i64 = d.n - 1;
                if (n >= 59 and isLeap(year)) n += 1;
                return jan1 + n;
            },
            .month_week_day => {
                const first = datefmt.daysFromCivil(.{ .y = year, .m = @intCast(d.month), .d = 1 });
                const first_wd: i64 = @mod(first + 4, 7);
                var day = first + @mod(@as(i64, d.wday) - first_wd, 7) + (@as(i64, d.week) - 1) * 7;
                const dim = @import("../vault/frontmatter.zig").daysInMonth(year, @intCast(d.month));
                while (day >= first + dim) day -= 7;
                return day;
            },
        }
    }

    fn isLeap(y: i32) bool {
        return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
    }

    pub fn offsetAt(r: PosixRule, unix_s: i64) i32 {
        const dst = r.dst_off orelse return r.std_off;
        const year = datefmt.civilFromDays(@divFloor(unix_s + r.std_off, 86400)).y;
        // Transition instants in UTC: start is written in standard time,
        // end in daylight time.
        const start = dayOf(r.start, year) * 86400 + r.start_time - r.std_off;
        const end = dayOf(r.end, year) * 86400 + r.end_time - dst;
        const in_dst = if (start < end) unix_s >= start and unix_s < end else unix_s >= start or unix_s < end;
        return if (in_dst) dst else r.std_off;
    }
};

// ---- Windows ----

const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

extern "kernel32" fn SystemTimeToTzSpecificLocalTime(tz: ?*const anyopaque, utc: *const SYSTEMTIME, local: *SYSTEMTIME) callconv(.winapi) c_int;
extern "kernel32" fn GetLocalTime(out: *SYSTEMTIME) callconv(.winapi) void;
extern "kernel32" fn GetSystemTime(out: *SYSTEMTIME) callconv(.winapi) void;

fn toSystemTime(unix_s: i64) SYSTEMTIME {
    const dt = datefmt.fromUnix(unix_s, 0);
    return .{ .wYear = @intCast(dt.date.y), .wMonth = dt.date.m, .wDayOfWeek = datefmt.weekday(dt.date), .wDay = dt.date.d, .wHour = dt.h, .wMinute = dt.min, .wSecond = dt.s, .wMilliseconds = 0 };
}

fn fromSystemTime(st: SYSTEMTIME) i64 {
    return datefmt.toUnix(.{ .date = .{ .y = st.wYear, .m = @intCast(st.wMonth), .d = @intCast(st.wDay) }, .h = @intCast(st.wHour), .min = @intCast(st.wMinute), .s = @intCast(st.wSecond), .utc_offset_s = 0 });
}

fn windowsOffset(unix_s: i64) i32 {
    if (builtin.os.tag != .windows) return 0;
    const utc_st = toSystemTime(unix_s);
    var local: SYSTEMTIME = undefined;
    if (SystemTimeToTzSpecificLocalTime(null, &utc_st, &local) == 0) return 0;
    return @intCast(fromSystemTime(local) - unix_s);
}

const testing = std.testing;

test "localtime: tzif parse of a committed fixture DST transitions" {
    const testdata = @import("../testing/testdata.zig");
    var dir = try testdata.openDir("testdata/tz");
    defer dir.close(testing.io);
    const bytes = try dir.readFileAlloc(testing.io, "Europe_Berlin.tzif", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    var z = try LocalTz.fromTzif(testing.allocator, bytes);
    defer z.deinit();
    // 2024-03-31 01:00 UTC: CET → CEST; 2024-10-27 01:00 UTC: back.
    try testing.expectEqual(@as(i32, 3600), z.offsetAt(1711846799));
    try testing.expectEqual(@as(i32, 7200), z.offsetAt(1711846800));
    try testing.expectEqual(@as(i32, 7200), z.offsetAt(1729990799));
    try testing.expectEqual(@as(i32, 3600), z.offsetAt(1729990800));
    // 1980 (before Germany restarted DST): CET.
    try testing.expectEqual(@as(i32, 3600), z.offsetAt(315532800));
    // 2040, past the table: the footer rule.
    try testing.expectEqual(@as(i32, 3600), z.offsetAt(2216250000 - 1));
    try testing.expectEqual(@as(i32, 7200), z.offsetAt(2216250000));
    try testing.expectEqual(@as(i32, 3600), z.offsetAt(2234998800));
    // Cached hours agree.
    try testing.expectEqual(@as(i32, 7200), z.offsetAt(1711846800 + 60));
}

test "localtime: POSIX rules, southern hemisphere and fixed zones" {
    const syd = PosixRule.parse("AEST-10AEDT,M10.1.0,M4.1.0/3").?;
    // 2040-03-31 16:00 UTC: DST ends; 2040-10-06 16:00 UTC: starts.
    try testing.expectEqual(@as(i32, 39600), syd.offsetAt(2216822400 - 1));
    try testing.expectEqual(@as(i32, 36000), syd.offsetAt(2216822400));
    try testing.expectEqual(@as(i32, 36000), syd.offsetAt(2233152000 - 1));
    try testing.expectEqual(@as(i32, 39600), syd.offsetAt(2233152000));
    try testing.expectEqual(@as(i32, -5 * 3600), PosixRule.parse("EST5").?.offsetAt(0));
    try testing.expectEqual(@as(i32, 5 * 3600 + 1800), PosixRule.parse("<+0530>-5:30").?.offsetAt(0));
    try testing.expect(PosixRule.parse("x") == null);
    try testing.expect(PosixRule.parse("CET-1CEST,M13.5.0,M10.5.0") == null);
}

test "localtime: Windows offset matches GetLocalTime" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var z: LocalTz = .{ .gpa = testing.allocator, .mode = .windows };
    var utc_st: SYSTEMTIME = undefined;
    var local_st: SYSTEMTIME = undefined;
    GetSystemTime(&utc_st);
    GetLocalTime(&local_st);
    const now = fromSystemTime(utc_st);
    const diff = fromSystemTime(local_st) - now;
    try testing.expectEqual(@as(i32, @intCast(@divFloor(diff + 30, 60) * 60)), @divFloor(z.offsetAt(now) + 30, 60) * 60);
}
