//! A Moment.js-compatible subset of date formatting and parsing
//! (E08.F07.S02.T01), for daily-note paths and template variables.
//! Tokens: YYYY YY M MM MMM MMMM D DD Do d dd ddd dddd H HH h hh m mm s
//! ss A a W WW GGGG Q, and `[literal]`. Unknown letters print as-is.
//! English names only.

const std = @import("std");
const frontmatter = @import("zg_frontmatter").frontmatter;

pub const Date = frontmatter.Date;
pub const DateTime = frontmatter.DateTime;

const Token = enum { YYYY, GGGG, MMMM, dddd, MMM, ddd, YY, MM, DD, Do, dd, HH, hh, mm, ss, WW, M, D, d, H, h, m, s, A, a, W, Q };

/// Longest first, so greedy matching picks `MMMM` over `MM`.
const tokens = blk: {
    const fields = std.meta.fields(Token);
    var list: [fields.len]Token = undefined;
    for (fields, 0..) |f, i| list[i] = @enumFromInt(f.value);
    break :blk list;
};

pub const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
pub const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

fn tokenAt(fmt: []const u8, i: usize) ?Token {
    for (tokens) |t| if (std.mem.startsWith(u8, fmt[i..], @tagName(t))) return t;
    return null;
}

/// Days since 1970-01-01 (proleptic Gregorian).
pub fn daysFromCivil(d: Date) i64 {
    const y: i64 = @as(i64, d.y) - @as(i64, if (d.m <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, d.m) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d.d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn civilFromDays(days: i64) Date {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{ .y = @intCast(y), .m = @intCast(m), .d = @intCast(d) };
}

/// 0 = Sunday (1970-01-01 was a Thursday).
pub fn weekday(d: Date) u3 {
    return @intCast(@mod(daysFromCivil(d) + 4, 7));
}

pub fn addDays(d: Date, n: i64) Date {
    return civilFromDays(daysFromCivil(d) + n);
}

/// ISO 8601 week and week-year: weeks start Monday; week 1 holds the
/// year's first Thursday.
pub fn isoWeek(d: Date) struct { year: i32, week: u8 } {
    const days = daysFromCivil(d);
    const iso_dow: i64 = @mod(days + 3, 7); // 0 = Monday
    const thursday = civilFromDays(days - iso_dow + 3);
    const jan1 = daysFromCivil(.{ .y = thursday.y, .m = 1, .d = 1 });
    const week = @divFloor(days - iso_dow + 3 - jan1, 7) + 1;
    return .{ .year = thursday.y, .week = @intCast(week) };
}

/// The local date and time of a Unix instant at `offset_s` east of UTC.
pub fn fromUnix(unix_s: i64, offset_s: i32) DateTime {
    const local = unix_s + offset_s;
    const days = @divFloor(local, 86400);
    const secs: u32 = @intCast(local - days * 86400);
    return .{
        .date = civilFromDays(days),
        .h = @intCast(secs / 3600),
        .min = @intCast(secs / 60 % 60),
        .s = @intCast(secs % 60),
        .utc_offset_s = offset_s,
    };
}

/// The Unix instant of `dt` (its offset, or UTC when it has none).
pub fn toUnix(dt: DateTime) i64 {
    const days = daysFromCivil(dt.date);
    return days * 86400 + @as(i64, dt.h) * 3600 + @as(i64, dt.min) * 60 + dt.s - (dt.utc_offset_s orelse 0);
}

fn ordinalSuffix(n: u32) []const u8 {
    if (n % 100 >= 11 and n % 100 <= 13) return "th";
    return switch (n % 10) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    };
}

pub fn format(w: *std.Io.Writer, fmt: []const u8, dt: DateTime) std.Io.Writer.Error!void {
    var i: usize = 0;
    const d = dt.date;
    while (i < fmt.len) {
        if (fmt[i] == '[') {
            const end = std.mem.indexOfScalarPos(u8, fmt, i + 1, ']') orelse fmt.len;
            try w.writeAll(fmt[i + 1 .. end]);
            i = @min(end + 1, fmt.len);
            continue;
        }
        const t = tokenAt(fmt, i) orelse {
            try w.writeByte(fmt[i]);
            i += 1;
            continue;
        };
        i += @tagName(t).len;
        const h12: u32 = if (dt.h % 12 == 0) 12 else dt.h % 12;
        switch (t) {
            .YYYY => try w.print("{d:0>4}", .{@as(u32, @intCast(@max(d.y, 0)))}),
            .YY => try w.print("{d:0>2}", .{@as(u32, @intCast(@mod(d.y, 100)))}),
            .M => try w.print("{d}", .{d.m}),
            .MM => try w.print("{d:0>2}", .{d.m}),
            .MMM => try w.writeAll(month_names[d.m - 1][0..3]),
            .MMMM => try w.writeAll(month_names[d.m - 1]),
            .D => try w.print("{d}", .{d.d}),
            .DD => try w.print("{d:0>2}", .{d.d}),
            .Do => try w.print("{d}{s}", .{ d.d, ordinalSuffix(d.d) }),
            .d => try w.print("{d}", .{weekday(d)}),
            .dd => try w.writeAll(day_names[weekday(d)][0..2]),
            .ddd => try w.writeAll(day_names[weekday(d)][0..3]),
            .dddd => try w.writeAll(day_names[weekday(d)]),
            .H => try w.print("{d}", .{dt.h}),
            .HH => try w.print("{d:0>2}", .{dt.h}),
            .h => try w.print("{d}", .{h12}),
            .hh => try w.print("{d:0>2}", .{h12}),
            .m => try w.print("{d}", .{dt.min}),
            .mm => try w.print("{d:0>2}", .{dt.min}),
            .s => try w.print("{d}", .{dt.s}),
            .ss => try w.print("{d:0>2}", .{dt.s}),
            .A => try w.writeAll(if (dt.h < 12) "AM" else "PM"),
            .a => try w.writeAll(if (dt.h < 12) "am" else "pm"),
            .W => try w.print("{d}", .{isoWeek(d).week}),
            .WW => try w.print("{d:0>2}", .{isoWeek(d).week}),
            .GGGG => try w.print("{d:0>4}", .{@as(u32, @intCast(@max(isoWeek(d).year, 0)))}),
            .Q => try w.print("{d}", .{(@as(u32, d.m) - 1) / 3 + 1}),
        }
    }
}

/// `format` into a new string.
pub fn formatAlloc(a: std.mem.Allocator, fmt: []const u8, dt: DateTime) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();
    format(&w.writer, fmt, dt) catch return error.OutOfMemory;
    return w.toOwnedSlice();
}

/// Parses `text` written in `fmt` (the whole text must match). Fields the
/// format lacks default to January, the 1st, midnight. The result has no
/// UTC offset.
pub fn parse(fmt: []const u8, text: []const u8) ?DateTime {
    var y: i32 = 1970;
    var mo: u8 = 1;
    var day: u8 = 1;
    var h: u8 = 0;
    var mi: u8 = 0;
    var sec: u8 = 0;
    var pm: ?bool = null;
    var i: usize = 0;
    var j: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '[') {
            const end = std.mem.indexOfScalarPos(u8, fmt, i + 1, ']') orelse fmt.len;
            const lit = fmt[i + 1 .. end];
            if (!std.mem.startsWith(u8, text[j..], lit)) return null;
            j += lit.len;
            i = @min(end + 1, fmt.len);
            continue;
        }
        const t = tokenAt(fmt, i) orelse {
            if (j >= text.len or text[j] != fmt[i]) return null;
            i += 1;
            j += 1;
            continue;
        };
        i += @tagName(t).len;
        switch (t) {
            .YYYY => y = @intCast(digits(text, &j, 4, 4) orelse return null),
            .YY => y = 2000 + @as(i32, @intCast(digits(text, &j, 2, 2) orelse return null)),
            .GGGG => _ = digits(text, &j, 4, 4) orelse return null,
            .M => mo = @intCast(digits(text, &j, 1, 2) orelse return null),
            .MM => mo = @intCast(digits(text, &j, 2, 2) orelse return null),
            .MMM => mo = name(text, &j, &month_names, true) orelse return null,
            .MMMM => mo = name(text, &j, &month_names, false) orelse return null,
            .D => day = @intCast(digits(text, &j, 1, 2) orelse return null),
            .DD => day = @intCast(digits(text, &j, 2, 2) orelse return null),
            .Do => {
                day = @intCast(digits(text, &j, 1, 2) orelse return null);
                if (!std.mem.startsWith(u8, text[j..], ordinalSuffix(day))) return null;
                j += 2;
            },
            .d => _ = digits(text, &j, 1, 1) orelse return null,
            .dd => if (j + 2 <= text.len) {
                j += 2;
            } else return null,
            .ddd => _ = name(text, &j, &day_names, true) orelse return null,
            .dddd => _ = name(text, &j, &day_names, false) orelse return null,
            .H, .h => h = @intCast(digits(text, &j, 1, 2) orelse return null),
            .HH, .hh => h = @intCast(digits(text, &j, 2, 2) orelse return null),
            .m => mi = @intCast(digits(text, &j, 1, 2) orelse return null),
            .mm => mi = @intCast(digits(text, &j, 2, 2) orelse return null),
            .s => sec = @intCast(digits(text, &j, 1, 2) orelse return null),
            .ss => sec = @intCast(digits(text, &j, 2, 2) orelse return null),
            .A, .a => {
                if (j + 2 > text.len) return null;
                const x = text[j .. j + 2];
                if (std.ascii.eqlIgnoreCase(x, "am")) pm = false else if (std.ascii.eqlIgnoreCase(x, "pm")) pm = true else return null;
                j += 2;
            },
            .W => _ = digits(text, &j, 1, 2) orelse return null,
            .WW => _ = digits(text, &j, 2, 2) orelse return null,
            .Q => _ = digits(text, &j, 1, 1) orelse return null,
        }
    }
    if (j != text.len) return null;
    if (pm) |p| {
        if (h < 1 or h > 12) return null;
        h = h % 12 + @as(u8, if (p) 12 else 0);
    }
    if (mo < 1 or mo > 12 or day < 1 or day > frontmatter.daysInMonth(y, @intCast(mo)) or h > 23 or mi > 59 or sec > 59) return null;
    return .{ .date = .{ .y = y, .m = @intCast(mo), .d = @intCast(day) }, .h = @intCast(h), .min = @intCast(mi), .s = @intCast(sec), .utc_offset_s = null };
}

fn digits(text: []const u8, j: *usize, min: usize, max: usize) ?u32 {
    var n: u32 = 0;
    var k: usize = 0;
    while (k < max and j.* + k < text.len and std.ascii.isDigit(text[j.* + k])) : (k += 1) n = n * 10 + (text[j.* + k] - '0');
    if (k < min) return null;
    j.* += k;
    return n;
}

/// A 1-based index into `names` (full or 3-letter, case-insensitive).
fn name(text: []const u8, j: *usize, names: []const []const u8, short: bool) ?u8 {
    for (names, 0..) |n, i| {
        const want = if (short) n[0..3] else n;
        if (text.len - j.* >= want.len and std.ascii.eqlIgnoreCase(text[j.*..][0..want.len], want)) {
            j.* += want.len;
            return @intCast(i + 1);
        }
    }
    return null;
}

const testing = std.testing;

fn fmtTest(fmt: []const u8, dt: DateTime) ![]u8 {
    return formatAlloc(testing.allocator, fmt, dt);
}

test "datefmt: token table" {
    const dt: DateTime = .{ .date = .{ .y = 2026, .m = 10, .d = 21 }, .h = 9, .min = 5, .s = 7, .utc_offset_s = 0 };
    const cases = [_][2][]const u8{
        .{ "YYYY", "2026" },             .{ "YY", "26" },                                .{ "M", "10" },  .{ "MM", "10" },
        .{ "MMM", "Oct" },               .{ "MMMM", "October" },                         .{ "D", "21" },  .{ "DD", "21" },
        .{ "Do", "21st" },               .{ "d", "3" },                                  .{ "dd", "We" }, .{ "ddd", "Wed" },
        .{ "dddd", "Wednesday" },        .{ "H", "9" },                                  .{ "HH", "09" }, .{ "h", "9" },
        .{ "hh", "09" },                 .{ "m", "5" },                                  .{ "mm", "05" }, .{ "s", "7" },
        .{ "ss", "07" },                 .{ "A", "AM" },                                 .{ "a", "am" },  .{ "W", "43" },
        .{ "WW", "43" },                 .{ "GGGG", "2026" },                            .{ "Q", "4" },   .{ "[Week] W", "Week 43" },
        .{ "YYYY-MM-DD", "2026-10-21" }, .{ "YYYY/MMMM/DD-ddd", "2026/October/21-Wed" }, .{ "x!", "x!" },
    };
    for (cases) |c| {
        const got = try fmtTest(c[0], dt);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
    // Ordinal suffixes.
    const days = [_]u5{ 1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 31 };
    const want = [_][]const u8{ "1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "31st" };
    for (days, want) |d, w| {
        const got = try fmtTest("Do", .{ .date = .{ .y = 2026, .m = 1, .d = d }, .h = 0, .min = 0, .s = 0, .utc_offset_s = 0 });
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(w, got);
    }
    // PM and 12-hour edges.
    const pm = try fmtTest("h:mm A hh", .{ .date = dt.date, .h = 0, .min = 30, .s = 0, .utc_offset_s = 0 });
    defer testing.allocator.free(pm);
    try testing.expectEqualStrings("12:30 AM 12", pm);
    // ISO weeks at year edges.
    try testing.expectEqual(@as(u8, 53), isoWeek(.{ .y = 2020, .m = 12, .d = 31 }).week);
    try testing.expectEqual(@as(i32, 2020), isoWeek(.{ .y = 2021, .m = 1, .d = 3 }).year);
    try testing.expectEqual(@as(u8, 53), isoWeek(.{ .y = 2021, .m = 1, .d = 3 }).week);
    try testing.expectEqual(@as(u8, 1), isoWeek(.{ .y = 2021, .m = 1, .d = 4 }).week);
    try testing.expectEqual(@as(i32, 2020), isoWeek(.{ .y = 2019, .m = 12, .d = 30 }).year);
    try testing.expectEqual(@as(u8, 1), isoWeek(.{ .y = 2019, .m = 12, .d = 30 }).week);
    // Civil date round trips.
    for ([_]i64{ -719468, -1, 0, 1, 18000, 20748, 2932896 }) |n| try testing.expectEqual(n, daysFromCivil(civilFromDays(n)));
    try testing.expectEqual(@as(u3, 4), weekday(.{ .y = 1970, .m = 1, .d = 1 }));
    const u = fromUnix(1792573507, 7200);
    try testing.expectEqual(@as(u5, 11), u.h);
    try testing.expectEqual(@as(i64, 1792573507), toUnix(u));
}

test "datefmt: parse inverse for daily formats" {
    const formats = [_][]const u8{ "YYYY-MM-DD", "YYYY/MM/YYYY-MM-DD", "DD.MM.YYYY", "YYYY-MM-DD dddd", "MMMM Do, YYYY", "[Daily] YY-M-D", "YYYY-[W]WW", "ddd D MMM YYYY h:mm a" };
    var d: Date = .{ .y = 2024, .m = 1, .d = 1 };
    for (0..400) |k| {
        d = addDays(d, 1);
        const dt: DateTime = .{ .date = d, .h = @intCast(k % 24), .min = @intCast(k % 60), .s = 0, .utc_offset_s = null };
        for (formats) |f| {
            const text = try fmtTest(f, dt);
            defer testing.allocator.free(text);
            const back = parse(f, text) orelse {
                std.debug.print("cannot parse '{s}' as '{s}'\n", .{ text, f });
                return error.TestUnexpectedResult;
            };
            if (std.mem.indexOf(u8, f, "D") != null) try testing.expect(back.date.eql(d));
        }
    }
    try testing.expect(parse("YYYY-MM-DD", "2024-02-30") == null);
    try testing.expect(parse("YYYY-MM-DD", "2024-02-29x") == null);
    try testing.expect(parse("YYYY-MM-DD", "24-02-29") == null);
    try testing.expect(parse("YYYY-MM-DD", "notes") == null);
    const t = parse("h:mm A", "12:05 PM").?;
    try testing.expectEqual(@as(u5, 12), t.h);
}
