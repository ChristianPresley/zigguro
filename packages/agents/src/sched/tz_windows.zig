//! Windows time zones (E13.F02.S01.T04). Windows has no TZif files: the
//! system zone's id (`GetDynamicTimeZoneInformation().TimeZoneKeyName`)
//! is mapped to an IANA zone through CLDR's table and read from the
//! embedded set; a zone missing from both becomes a fixed rule built from
//! the `DYNAMIC_TIME_ZONE_INFORMATION` (this year's rule only, so past
//! dates may be off). Also IANA alias resolution, used on every OS.

const std = @import("std");
const builtin = @import("builtin");
const posix_tz = @import("posix_tz.zig");

const Allocator = std.mem.Allocator;
const PosixRule = posix_tz.PosixRule;

const Data = struct {
    tzdata: []const u8,
    cldr: []const u8,
    map: []const [2][]const u8,
    links: []const [2][]const u8,
};

pub const data: Data = @import("tzdata/windows_zones.zon");

/// "W. Europe Standard Time" → "Europe/Berlin".
pub fn ianaForWindows(id: []const u8) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = data.map.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, data.map[mid][0], id)) {
            .eq => return data.map[mid][1],
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

/// Resolves IANA aliases ("Asia/Calcutta" → "Asia/Kolkata").
pub fn canonical(iana: []const u8) []const u8 {
    for (data.links) |l| if (std.mem.eql(u8, l[0], iana)) return l[1];
    return iana;
}

pub const SystemTime = extern struct {
    wYear: u16 = 0,
    wMonth: u16 = 0,
    wDayOfWeek: u16 = 0,
    wDay: u16 = 0,
    wHour: u16 = 0,
    wMinute: u16 = 0,
    wSecond: u16 = 0,
    wMilliseconds: u16 = 0,
};

pub const Dtzi = extern struct {
    Bias: i32 = 0,
    StandardName: [32]u16 = @splat(0),
    StandardDate: SystemTime = .{},
    StandardBias: i32 = 0,
    DaylightName: [32]u16 = @splat(0),
    DaylightDate: SystemTime = .{},
    DaylightBias: i32 = 0,
    TimeZoneKeyName: [128]u16 = @splat(0),
    DynamicDaylightTimeDisabled: u8 = 0,
};

extern "kernel32" fn GetDynamicTimeZoneInformation(info: *Dtzi) callconv(.winapi) u32;

/// The POSIX rule equivalent to a zone's information. Biases are minutes
/// west of UTC; transition dates in "day-in-month" form (`wYear` 0,
/// `wDay` the week, 5 = last) are local standard time for the start and
/// local daylight time for the end, as in POSIX.
pub fn dtziToRule(d: *const Dtzi) PosixRule {
    var r: PosixRule = .{ .std_off = -(d.Bias + d.StandardBias) * 60 };
    abbr(&r.std_abbr, r.std_off);
    if (d.DaylightDate.wMonth == 0 or d.StandardDate.wMonth == 0 or d.DynamicDaylightTimeDisabled != 0) return r;
    const dst = -(d.Bias + d.DaylightBias) * 60;
    r.dst_off = dst;
    abbr(&r.dst_abbr, dst);
    r.start = ruleDate(d.DaylightDate);
    r.end = ruleDate(d.StandardDate);
    return r;
}

fn ruleDate(t: SystemTime) posix_tz.RuleDate {
    return .{
        .kind = .{ .mwd = .{ .month = @intCast(@min(t.wMonth, 12)), .week = @intCast(std.math.clamp(t.wDay, 1, 5)), .day = @intCast(@min(t.wDayOfWeek, 6)) } },
        .time_s = @as(i32, t.wHour) * 3600 + @as(i32, t.wMinute) * 60 + t.wSecond,
    };
}

/// "+01", "-0330", as zic names zones without abbreviations.
fn abbr(out: *[8]u8, off: i32) void {
    const a: u32 = @abs(off);
    const sign: u8 = if (off < 0) '-' else '+';
    _ = if (a % 3600 == 0)
        std.fmt.bufPrint(out, "{c}{d:0>2}", .{ sign, a / 3600 }) catch unreachable
    else
        std.fmt.bufPrint(out, "{c}{d:0>2}{d:0>2}", .{ sign, a / 3600, a / 60 % 60 }) catch unreachable;
}

/// The system zone (Windows only).
pub fn systemZone(gpa: Allocator) !@import("tz.zig").TimeZone {
    const TimeZone = @import("tz.zig").TimeZone;
    if (builtin.os.tag != .windows) return TimeZone.utc();
    var d: Dtzi = .{};
    if (GetDynamicTimeZoneInformation(&d) == 0xFFFF_FFFF) return TimeZone.utc();
    var key: [512]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&key, std.mem.sliceTo(&d.TimeZoneKeyName, 0)) catch 0;
    const id = key[0..n];
    if (ianaForWindows(id)) |iana| {
        if (TimeZone.embedded(gpa, iana)) |z| return z else |e| if (e == error.OutOfMemory) return e;
    }
    return TimeZone.fromRule(gpa, dtziToRule(&d), if (id.len > 0) id else "Local");
}

comptime {
    // sizeof(DYNAMIC_TIME_ZONE_INFORMATION) in the Windows SDK.
    std.debug.assert(@sizeOf(Dtzi) == 432);
}
