//! Time zones: the TZif reader against committed tzdata fixtures and
//! `std.tz`, daylight-saving gaps and overlaps, POSIX footer rules,
//! Windows zone information and the embedded set, and cron in a real zone.

const std = @import("std");
const builtin = @import("builtin");
const tz = @import("tz.zig");
const tzif = @import("tzif.zig");
const posix_tz = @import("posix_tz.zig");
const tz_windows = @import("tz_windows.zig");
const tz_embedded = @import("tz_embedded.zig");
const zone = @import("zone.zig");
const cron = @import("cron.zig");

const testing = std.testing;
const gpa = testing.allocator;
const TimeZone = tz.TimeZone;
const PosixRule = posix_tz.PosixRule;
const LocalDateTime = zone.LocalDateTime;

const berlin_bytes = @embedFile("testdata/tz/Europe_Berlin.tzif");
const new_york_bytes = @embedFile("testdata/tz/America_New_York.tzif");
const lord_howe_bytes = @embedFile("testdata/tz/Australia_Lord_Howe.tzif");
const apia_bytes = @embedFile("testdata/tz/Pacific_Apia.tzif");
const utc_bytes = @embedFile("testdata/tz/UTC.tzif");

const fixtures = [_]struct { name: []const u8, bytes: []const u8 }{
    .{ .name = "Europe/Berlin", .bytes = berlin_bytes },
    .{ .name = "America/New_York", .bytes = new_york_bytes },
    .{ .name = "Australia/Lord_Howe", .bytes = lord_howe_bytes },
    .{ .name = "Pacific/Apia", .bytes = apia_bytes },
    .{ .name = "UTC", .bytes = utc_bytes },
};

fn at(y: u16, mo: u4, d: u5, h: u5, mi: u6) i64 {
    return (LocalDateTime{ .year = y, .month = mo, .day = d, .hour = h, .minute = mi }).toUnixUtc();
}

fn ldt(y: u16, mo: u4, d: u5, h: u5, mi: u6) LocalDateTime {
    return .{ .year = y, .month = mo, .day = d, .hour = h, .minute = mi };
}

fn load(bytes: []const u8, name: []const u8) !TimeZone {
    return TimeZone.fromTzif(gpa, bytes, name);
}

test "tzif_v1_v2_v3_v4_headers" {
    for (fixtures) |f| {
        var z = try load(f.bytes, f.name);
        defer z.deinit(gpa);
        try testing.expectEqualStrings(f.name, z.name);
        // The reader keeps at most twice the input.
        try testing.expect(z.allocated() <= 2 * f.bytes.len);
    }
    // Versions 3 and 4 differ only in the version byte (both headers).
    for ("34") |v| {
        const b = try gpa.dupe(u8, berlin_bytes);
        defer gpa.free(b);
        const p1 = try tzif.parse(b);
        b[4] = v;
        b[@intFromPtr(p1.times.ptr) - @intFromPtr(b.ptr) - 44 + 4] = v;
        var z = try load(b, "v");
        defer z.deinit(gpa);
        try testing.expectEqual(@as(i32, 7200), z.offsetAt(at(2026, 7, 1, 0, 0)).utoff);
    }
    // A version-1 file: 32-bit block only, no footer.
    {
        var b: [44 + 4 + 1 + 12 + 8]u8 = @splat(0);
        @memcpy(b[0..4], "TZif");
        std.mem.writeInt(u32, b[32..36], 1, .big); // timecnt
        std.mem.writeInt(u32, b[36..40], 2, .big); // typecnt
        std.mem.writeInt(u32, b[40..44], 8, .big); // charcnt
        std.mem.writeInt(i32, b[44..48], 1_000_000, .big);
        b[48] = 1;
        std.mem.writeInt(i32, b[49..53], 3600, .big);
        b[54] = 0;
        std.mem.writeInt(i32, b[55..59], 7200, .big);
        b[59] = 1;
        b[60] = 4;
        @memcpy(b[61..69], "AAA\x00BBB\x00");
        var z = try load(&b, "v1");
        defer z.deinit(gpa);
        try testing.expect(z.footer == null);
        try testing.expectEqual(@as(i32, 3600), z.offsetAt(0).utoff);
        const o = z.offsetAt(2_000_000);
        try testing.expectEqual(@as(i32, 7200), o.utoff);
        try testing.expectEqualStrings("BBB", o.abbr);
        try testing.expect(z.allocated() <= 2 * b.len + 2);
    }
    // Rejected without panics: bad magic, bad version, every truncation.
    {
        const b = try gpa.dupe(u8, berlin_bytes);
        defer gpa.free(b);
        b[0] = 'X';
        try testing.expectError(error.InvalidTzif, tzif.parse(b));
        b[0] = 'T';
        b[4] = '9';
        try testing.expectError(error.UnsupportedTzifVersion, tzif.parse(b));
    }
    for (0..new_york_bytes.len - 1) |n| {
        if (TimeZone.fromTzif(gpa, new_york_bytes[0..n], "x")) |z| {
            var zz = z;
            zz.deinit(gpa);
        } else |_| {}
    }
}

test "tzif_matches_std_tz_for_v2_v3" {
    for (fixtures) |f| {
        var r: std.Io.Reader = .fixed(f.bytes);
        var st = try std.tz.Tz.parse(gpa, &r);
        defer st.deinit();
        var z = try load(f.bytes, f.name);
        defer z.deinit(gpa);
        try testing.expectEqual(st.transitions.len, z.transitions.len);
        for (st.transitions, z.transitions) |a, b| {
            try testing.expectEqual(a.ts, b);
            const o = z.offsetAt(b);
            try testing.expectEqual(a.timetype.offset, o.utoff);
            try testing.expectEqual(a.timetype.isDst(), o.is_dst);
            try testing.expectEqualStrings(a.timetype.name(), o.abbr);
        }
        if (st.footer) |ft| try testing.expect(z.footer != null and ft.len > 0);
    }
}

test "dst_gap_and_overlap_berlin_2026" {
    var z = try load(berlin_bytes, "Europe/Berlin");
    defer z.deinit(gpa);
    try testing.expectEqual(@as(i32, 3600), z.offsetAt(at(2026, 1, 15, 12, 0)).utoff);
    try testing.expectEqualStrings("CEST", z.offsetAt(at(2026, 7, 1, 0, 0)).abbr);
    // 02:30 on 29 March does not exist: the first instant after is 03:00
    // CEST (01:00 UTC).
    try testing.expectEqual(zone.Resolved{ .gap = at(2026, 3, 29, 1, 0) }, z.fromLocal(ldt(2026, 3, 29, 2, 30)));
    try testing.expectEqual(ldt(2026, 3, 29, 3, 0), z.toLocal(at(2026, 3, 29, 1, 0)));
    // 02:30 on 25 October happens twice: CEST first.
    try testing.expectEqual(zone.Resolved{ .ambiguous = .{ at(2026, 10, 25, 0, 30), at(2026, 10, 25, 1, 30) } }, z.fromLocal(ldt(2026, 10, 25, 2, 30)));
    try testing.expectEqual(zone.Resolved{ .unique = at(2026, 6, 1, 7, 0) }, z.fromLocal(ldt(2026, 6, 1, 9, 0)));
    try testing.expectEqual(zone.Resolved{ .unique = at(2026, 12, 1, 8, 0) }, z.fromLocal(ldt(2026, 12, 1, 9, 0)));
    // Round trip every 37 minutes over the year.
    var t = at(2026, 1, 1, 0, 0);
    while (t < at(2027, 1, 1, 0, 0)) : (t += 37 * 60) {
        switch (z.fromLocal(z.toLocal(t))) {
            .unique => |u| try testing.expectEqual(t, u),
            .ambiguous => |a| try testing.expect(a[0] == t or a[1] == t),
            .gap => return error.TestUnexpectedResult,
        }
    }
}

test "lord_howe_half_hour_dst" {
    var z = try load(lord_howe_bytes, "Australia/Lord_Howe");
    defer z.deinit(gpa);
    try testing.expectEqual(@as(i32, 39600), z.offsetAt(at(2026, 1, 15, 0, 0)).utoff);
    try testing.expectEqual(@as(i32, 37800), z.offsetAt(at(2026, 7, 15, 0, 0)).utoff);
    // Daylight time starts 4 October 2026 at 02:00: 02:00-02:30 is skipped.
    const start = at(2026, 10, 4, 2, 0) - 37800;
    try testing.expectEqual(zone.Resolved{ .gap = start }, z.fromLocal(ldt(2026, 10, 4, 2, 15)));
    // It ends 5 April 2026 at 02:00 daylight time: 01:30-02:00 repeats.
    const end = at(2026, 4, 5, 2, 0) - 39600;
    try testing.expectEqual(zone.Resolved{ .ambiguous = .{ end - 15 * 60, end + 15 * 60 } }, z.fromLocal(ldt(2026, 4, 5, 1, 45)));
}

test "apia_skipped_day_2011" {
    var z = try load(apia_bytes, "Pacific/Apia");
    defer z.deinit(gpa);
    // 29 December 2011 23:59:59 (-10) was followed by 31 December 00:00 (+14).
    const jump = at(2011, 12, 30, 10, 0);
    try testing.expectEqual(@as(i32, -36000), z.offsetAt(jump - 1).utoff);
    try testing.expectEqual(@as(i32, 50400), z.offsetAt(jump).utoff);
    try testing.expectEqual(zone.Resolved{ .gap = jump }, z.fromLocal(ldt(2011, 12, 30, 12, 0)));
    try testing.expectEqual(ldt(2011, 12, 31, 0, 0), z.toLocal(jump));
    try testing.expectEqual(ldt(2011, 12, 29, 23, 59), z.toLocal(jump - 60));
    // Daily cron at noon: the missing day's run happens once, at the
    // first instant after the gap.
    const c = try cron.CronExpr.parse("0 12 * * *");
    const r = z.resolver();
    const a = c.next(r, at(2011, 12, 29, 0, 0)).?;
    try testing.expectEqual(ldt(2011, 12, 29, 12, 0), z.toLocal(a));
    const b = c.next(r, a).?;
    try testing.expectEqual(ldt(2011, 12, 31, 0, 0), z.toLocal(b));
    try testing.expectEqual(ldt(2011, 12, 31, 12, 0), z.toLocal(c.next(r, b).?));
}

test "footer_rule_after_last_transition" {
    inline for (.{ .{ berlin_bytes, "CET-1CEST,M3.5.0,M10.5.0/3" }, .{ new_york_bytes, "EST5EDT,M3.2.0,M11.1.0" } }) |c| {
        var z = try load(c[0], "z");
        defer z.deinit(gpa);
        const rule = try PosixRule.parse(c[1]);
        // The rule agrees with the table where both apply ...
        var t = at(2008, 1, 1, 0, 0);
        while (t < z.transitions[z.transitions.len - 1]) : (t += 6 * 3600 + 7) {
            try testing.expectEqual(z.offsetAt(t).utoff, rule.offsetAt(t));
        }
        // ... and is used after the table ends.
        t = at(2040, 1, 1, 0, 0);
        while (t < at(2041, 1, 1, 0, 0)) : (t += 3 * 3600 + 11) {
            try testing.expectEqual(rule.offsetAt(t), z.offsetAt(t).utoff);
        }
    }
    var z = try load(berlin_bytes, "Europe/Berlin");
    defer z.deinit(gpa);
    try testing.expectEqual(@as(i32, 3600), z.offsetAt(at(2040, 1, 10, 0, 0)).utoff);
    try testing.expectEqualStrings("CEST", z.offsetAt(at(2040, 7, 10, 0, 0)).abbr);
    // Last Sunday of March 2040 is the 25th.
    try testing.expectEqual(@as(?i64, at(2040, 3, 25, 1, 0)), z.nextTransition(at(2040, 1, 1, 0, 0)));
    try testing.expectEqual(zone.Resolved{ .gap = at(2040, 3, 25, 1, 0) }, z.fromLocal(ldt(2040, 3, 25, 2, 30)));
    try testing.expectEqual(zone.Resolved{ .ambiguous = .{ at(2040, 10, 28, 0, 30), at(2040, 10, 28, 1, 30) } }, z.fromLocal(ldt(2040, 10, 28, 2, 30)));
}

test "posix_rule_parse_table" {
    {
        const r = try PosixRule.parse("<+0330>-3:30");
        try testing.expectEqual(@as(i32, 12600), r.std_off);
        try testing.expectEqualStrings("+0330", r.stdAbbr());
        try testing.expect(r.dst_off == null);
    }
    {
        const r = try PosixRule.parse("EST5EDT,M3.2.0,M11.1.0");
        try testing.expectEqual(@as(i32, -18000), r.std_off);
        try testing.expectEqual(@as(?i32, -14400), r.dst_off);
        try testing.expectEqualStrings("EDT", r.dstAbbr());
        // 8 March 2026 02:00 EST and 1 November 2026 02:00 EDT.
        const ch = r.changes(2026);
        try testing.expectEqual(at(2026, 3, 8, 7, 0), ch.start);
        try testing.expectEqual(at(2026, 11, 1, 6, 0), ch.end);
    }
    {
        // Julian days: J60 is 1 March even in leap years; 59 is 29 February.
        const r = try PosixRule.parse("AAA0BBB,J60/0,59/0");
        try testing.expectEqual(at(2024, 3, 1, 0, 0), r.changes(2024).start);
        try testing.expectEqual(at(2024, 2, 29, 0, 0) - 3600, r.changes(2024).end);
    }
    {
        // RFC 9636 §3.3.2: rule times from -167 to 167 hours.
        const r = try PosixRule.parse("<-03>3<-02>,M3.5.0/-2,M10.5.0/-1");
        try testing.expectEqual(@as(i32, -7200), r.start.?.time_s);
        const r2 = try PosixRule.parse("XXX3YYY,M3.5.0/167,M10.5.0/-167");
        try testing.expectEqual(@as(i32, 167 * 3600), r2.start.?.time_s);
        try testing.expectEqual(@as(i32, -167 * 3600), r2.end.?.time_s);
        try testing.expectError(error.InvalidTzString, PosixRule.parse("XXX3YYY,M3.5.0/168,M10.5.0"));
    }
    {
        // All-year daylight saving time.
        const r = try PosixRule.parse("EST5EDT,0/0,J365/25");
        var t = at(2026, 1, 1, 0, 0);
        while (t < at(2027, 1, 1, 0, 0)) : (t += 86_400 * 3 + 1) try testing.expect(r.at(t).is_dst);
        try testing.expect(r.nextChange(at(2026, 6, 1, 0, 0)) == null);
    }
    {
        // Southern hemisphere: daylight time spans the new year.
        const r = try PosixRule.parse("AEST-10AEDT,M10.1.0,M4.1.0/3");
        try testing.expect(r.at(at(2026, 1, 15, 0, 0)).is_dst);
        try testing.expect(!r.at(at(2026, 7, 15, 0, 0)).is_dst);
        // No rule: the US default.
        const d = try PosixRule.parse("PST8PDT");
        try testing.expect(d.at(at(2026, 7, 1, 0, 0)).is_dst);
    }
    const bad = [_][]const u8{ "", "E5", "EST", "EST5EDT,M3.2.0", "EST5EDT,M13.1.0,M11.1.0", "EST5EDT,M3.6.0,M11.1.0", "EST5EDT,J0,J365", "<+03", "EST25", "EST5EDT,M3.2.7,M11.1.0", "TOOLONGNAME5" };
    for (bad) |s| {
        if (PosixRule.parse(s)) |_| {
            std.debug.print("accepted: {s}\n", .{s});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "windows_dtzi_to_rule" {
    // W. Europe Standard Time.
    var d: tz_windows.Dtzi = .{
        .Bias = -60,
        .DaylightBias = -60,
        .StandardDate = .{ .wMonth = 10, .wDayOfWeek = 0, .wDay = 5, .wHour = 3 },
        .DaylightDate = .{ .wMonth = 3, .wDayOfWeek = 0, .wDay = 5, .wHour = 2 },
    };
    const r = tz_windows.dtziToRule(&d);
    const want = try PosixRule.parse("CET-1CEST,M3.5.0,M10.5.0/3");
    var t = at(2026, 1, 1, 0, 0);
    while (t < at(2028, 1, 1, 0, 0)) : (t += 3600 * 5 + 13) try testing.expectEqual(want.offsetAt(t), r.offsetAt(t));
    try testing.expectEqualStrings("+01", r.stdAbbr());
    try testing.expectEqualStrings("+02", r.dstAbbr());
    // India: no daylight time, +05:30.
    d = .{ .Bias = -330 };
    const ri = tz_windows.dtziToRule(&d);
    try testing.expectEqual(@as(i32, 19800), ri.std_off);
    try testing.expect(ri.dst_off == null);
    try testing.expectEqualStrings("+0530", ri.stdAbbr());
    var z = try TimeZone.fromRule(gpa, ri, "India Standard Time");
    defer z.deinit(gpa);
    try testing.expectEqual(zone.Resolved{ .unique = at(2026, 1, 1, 3, 30) }, z.fromLocal(ldt(2026, 1, 1, 9, 0)));
}

test "windows_zone_map_lookup" {
    try testing.expectEqualStrings("Europe/Berlin", tz_windows.ianaForWindows("W. Europe Standard Time").?);
    try testing.expectEqualStrings("America/New_York", tz_windows.ianaForWindows("Eastern Standard Time").?);
    try testing.expectEqualStrings("Asia/Kolkata", tz_windows.ianaForWindows("India Standard Time").?);
    try testing.expect(tz_windows.ianaForWindows("Mars Standard Time") == null);
    try testing.expectEqualStrings("Europe/Kyiv", tz_windows.canonical("Europe/Kiev"));
    // Every mapped zone is embedded and readable.
    for (tz_windows.data.map) |row| {
        var z = TimeZone.embedded(gpa, row[1]) catch |e| {
            std.debug.print("{s}: {t}\n", .{ row[1], e });
            return e;
        };
        z.deinit(gpa);
    }
    try testing.expectEqualStrings(tz_windows.data.tzdata, tz_embedded.version());
    var z = try TimeZone.embedded(gpa, "Asia/Calcutta");
    defer z.deinit(gpa);
    try testing.expectEqualStrings("Asia/Kolkata", z.name);
    try testing.expectEqual(@as(i32, 19800), z.offsetAt(at(2026, 1, 1, 0, 0)).utoff);
}

test "local zone discovery" {
    const io = testing.io;
    {
        var z = try TimeZone.fromTzVar(io, gpa, "");
        defer z.deinit(gpa);
        try testing.expectEqualStrings("UTC", z.name);
    }
    {
        // Read from zoneinfo when present, else from the embedded set.
        var z = try TimeZone.fromTzVar(io, gpa, ":Europe/Berlin");
        defer z.deinit(gpa);
        try testing.expectEqualStrings("Europe/Berlin", z.name);
        try testing.expectEqual(@as(i32, 7200), z.offsetAt(at(2026, 7, 1, 0, 0)).utoff);
    }
    {
        var z = try TimeZone.fromTzVar(io, gpa, "EST5EDT,M3.2.0,M11.1.0");
        defer z.deinit(gpa);
        try testing.expectEqual(@as(i32, -14400), z.offsetAt(at(2026, 7, 1, 0, 0)).utoff);
        try testing.expectEqual(@as(i32, -18000), z.offsetAt(at(2026, 1, 1, 0, 0)).utoff);
        try testing.expectEqualStrings("EST", z.offsetAt(at(2026, 1, 1, 0, 0)).abbr);
    }
    {
        var z = try TimeZone.fromTzVar(io, gpa, ":No/Such_Zone");
        defer z.deinit(gpa);
        try testing.expectEqualStrings("UTC", z.name);
    }
    {
        var z = try TimeZone.fromLocaltime(io, gpa, "/nonexistent/localtime");
        defer z.deinit(gpa);
        try testing.expectEqualStrings("UTC", z.name);
    }
    try testing.expectError(error.UnknownTimeZone, TimeZone.named(io, gpa, "../etc/passwd"));
    try testing.expectEqualStrings("Europe/Berlin", tz.ianaFromPath("/usr/share/zoneinfo/Europe/Berlin"));
    var z = try TimeZone.local(io, gpa, null);
    z.deinit(gpa);
}

test "cron weekdays at 09:00 in Berlin across both 2026 transitions" {
    var z = try load(berlin_bytes, "Europe/Berlin");
    defer z.deinit(gpa);
    const c = try cron.CronExpr.parse("0 9 * * 1-5");
    const r = z.resolver();
    var t = at(2026, 1, 1, 0, 0);
    var prev: ?LocalDateTime = null;
    var fires: u32 = 0;
    while (c.next(r, t)) |n| {
        if (n >= at(2027, 1, 1, 0, 0)) break;
        const l = z.toLocal(n);
        try testing.expectEqual(@as(u5, 9), l.hour);
        try testing.expectEqual(@as(u6, 0), l.minute);
        const wd = zone.weekday(l.year, l.month, l.day);
        try testing.expect(wd >= 1 and wd <= 5);
        if (prev) |p| try testing.expect(zone.daysFromCivil(l.year, l.month, l.day) > zone.daysFromCivil(p.year, p.month, p.day));
        prev = l;
        fires += 1;
        t = n;
    }
    // 2026 has 261 weekdays: none skipped, none twice.
    try testing.expectEqual(@as(u32, 261), fires);
}

test "fuzz: tzif" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var raw: [512]u8 = undefined;
            const n = s.slice(&raw);
            var z = TimeZone.fromTzif(gpa, raw[0..n], "f") catch return;
            defer z.deinit(gpa);
            try testing.expect(z.allocated() <= 2 * n + 1);
            for ([_]i64{ std.math.minInt(i64) / 4, -1, 0, 1_800_000_000, std.math.maxInt(i64) / 4 }) |t| _ = z.offsetAt(t);
            _ = z.fromLocal(ldt(2026, 3, 29, 2, 30));
            _ = z.nextTransition(0);
        }
    }.one, .{ .corpus = &.{ utc_bytes, apia_bytes[0..@min(apia_bytes.len, 512)] } });
}
