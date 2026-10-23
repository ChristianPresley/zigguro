//! The cron engine: parsing, the POSIX day rule, the field-wise search
//! against a minute-by-minute brute force, and daylight-saving handling
//! through a fake resolver.

const std = @import("std");
const cron = @import("cron.zig");
const zone = @import("zone.zig");

const testing = std.testing;
const CronExpr = cron.CronExpr;
const LocalDateTime = zone.LocalDateTime;

const Case = struct { []const u8, ?cron.ParseError };

const parse_cases = [_]Case{
    .{ "* * * * *", null },
    .{ "0 0 * * *", null },
    .{ "*/15 * * * *", null },
    .{ "0 9-17 * * 1-5", null },
    .{ "0 9-17/2 * * MON-FRI", null },
    .{ "5,10,15 * * * *", null },
    .{ "0 0 1 jan *", null },
    .{ "0 0 1 JAN-mar *", null },
    .{ "0 0 * * sun", null },
    .{ "0 0 * * 7", null },
    .{ "0 0 * * 0-7", null },
    .{ "30 2 * * Sat,Sun", null },
    .{ "0 0 13 * 5", null },
    .{ "0 0 30 2 *", null },
    .{ "  0  0  *  *  *  ", null },
    .{ "0\t0\t*\t*\t*", null },
    .{ "5/10 * * * *", null },
    .{ "0 0 1-31/2 * *", null },
    .{ "59 23 31 12 6", null },
    .{ "0 0 1,15 * *", null },
    .{ "@yearly", null },
    .{ "@annually", null },
    .{ "@monthly", null },
    .{ "@weekly", null },
    .{ "@daily", null },
    .{ "@midnight", null },
    .{ "@hourly", null },
    .{ "@DAILY", null },
    .{ "0 0 * DEC *", null },
    .{ "0 0 * * fri-sun", error.BadRange },
    // Field counts.
    .{ "", error.FieldCount },
    .{ "* * * *", error.FieldCount },
    .{ "*", error.FieldCount },
    .{ "* * * * * * *", error.FieldCount },
    .{ "0 * * * * *", error.UnsupportedSyntax },
    // Unsupported syntax.
    .{ "0 0 L * *", error.UnsupportedSyntax },
    .{ "0 0 15W * *", error.UnsupportedSyntax },
    .{ "0 0 * * 5#3", error.UnsupportedSyntax },
    .{ "0 0 ? * *", error.UnsupportedSyntax },
    .{ "0 0 * * 5L", error.UnsupportedSyntax },
    .{ "@reboot", error.UnsupportedSyntax },
    // Numbers and ranges.
    .{ "60 * * * *", error.OutOfRange },
    .{ "* 24 * * *", error.OutOfRange },
    .{ "* * 0 * *", error.OutOfRange },
    .{ "* * 32 * *", error.OutOfRange },
    .{ "* * * 0 *", error.OutOfRange },
    .{ "* * * 13 *", error.OutOfRange },
    .{ "* * * * 8", error.OutOfRange },
    .{ "999 * * * *", error.OutOfRange },
    .{ "a * * * *", error.BadName },
    .{ "1x * * * *", error.BadNumber },
    .{ "-1 * * * *", error.BadNumber },
    .{ "5-1 * * * *", error.BadRange },
    .{ "1,,2 * * * *", error.BadNumber },
    .{ "*/0 * * * *", error.BadStep },
    .{ "*/x * * * *", error.BadStep },
    .{ "* * * foo *", error.BadName },
    .{ "* * * * funday", error.BadName },
    .{ "* jan * * *", error.BadName },
    .{ "@fortnightly", error.BadName },
};

test "parse_table" {
    for (parse_cases) |c| {
        const got = CronExpr.parse(c[0]);
        if (c[1]) |want| {
            testing.expectError(want, got) catch |e| {
                std.debug.print("case \"{s}\"\n", .{c[0]});
                return e;
            };
        } else {
            _ = got catch |e| {
                std.debug.print("case \"{s}\": {t}\n", .{ c[0], e });
                return e;
            };
        }
    }
    // Bits.
    const a = try CronExpr.parse("*/15 9-17/4 1,15 jan-mar mon-fri");
    try testing.expectEqual(@as(u64, 1 | 1 << 15 | 1 << 30 | 1 << 45), a.minutes);
    try testing.expectEqual(@as(u32, 1 << 9 | 1 << 13 | 1 << 17), a.hours);
    try testing.expectEqual(@as(u32, 1 << 1 | 1 << 15), a.dom);
    try testing.expectEqual(@as(u16, 0b1110), a.months);
    try testing.expectEqual(@as(u8, 0b0111110), a.dow);
    try testing.expect(!a.dom_star and !a.dow_star);
    // 7 is Sunday.
    try testing.expectEqual(@as(u8, 1), (try CronExpr.parse("0 0 * * 7")).dow);
    try testing.expectEqual(@as(u8, 0x7f), (try CronExpr.parse("0 0 * * 0-7")).dow);
    // `*/2` is not a star.
    const s = try CronExpr.parse("0 0 */2 * *");
    try testing.expect(!s.dom_star and s.dow_star);
    // `N/S` runs to the maximum.
    try testing.expectEqual(@as(u64, 1 << 5 | 1 << 25 | 1 << 45), (try CronExpr.parse("5/20 * * * *")).minutes);
    // Macros equal their expansion.
    try testing.expectEqual(try CronExpr.parse("0 0 * * 0"), try CronExpr.parse("@weekly"));
    // The error names the token.
    var d: cron.Diag = .{};
    try testing.expectError(error.UnsupportedSyntax, CronExpr.parseDiag("0 0 * * 5#3", &d));
    try testing.expectEqualStrings("5#3", d.token);
    d = .{};
    try testing.expectError(error.UnsupportedSyntax, CronExpr.parseDiag("@reboot", &d));
    try testing.expectEqualStrings("@reboot", d.token);
    d = .{};
    try testing.expectError(error.OutOfRange, CronExpr.parseDiag("0 0 * 13 *", &d));
    try testing.expectEqualStrings("13", d.token);
    d = .{};
    try testing.expectError(error.UnsupportedSyntax, CronExpr.parseDiag("0 0 0 * * *", &d));
    try testing.expectEqualStrings("*", d.token);
}

fn ldt(y: u16, mo: u4, d: u5, h: u5, mi: u6) LocalDateTime {
    return .{ .year = y, .month = mo, .day = d, .hour = h, .minute = mi };
}

test "posix_or_rule" {
    const c = try CronExpr.parse("0 0 13 * 5");
    // 2026-11-06 is a Friday; the 13th of November 2026 is a Friday too.
    var t = ldt(2026, 11, 1, 0, 0);
    const want = [_]LocalDateTime{ ldt(2026, 11, 6, 0, 0), ldt(2026, 11, 13, 0, 0), ldt(2026, 11, 20, 0, 0), ldt(2026, 11, 27, 0, 0), ldt(2026, 12, 4, 0, 0), ldt(2026, 12, 11, 0, 0), ldt(2026, 12, 13, 0, 0) };
    for (want) |w| {
        t = c.nextLocal(t).?;
        try testing.expectEqual(w, t);
    }
    // One side `*`: only the other applies.
    const dom_only = try CronExpr.parse("0 0 13 * *");
    try testing.expectEqual(ldt(2026, 12, 13, 0, 0), dom_only.nextLocal(ldt(2026, 11, 13, 0, 0)).?);
    const dow_only = try CronExpr.parse("0 0 * * 5");
    try testing.expectEqual(ldt(2026, 11, 20, 0, 0), dow_only.nextLocal(ldt(2026, 11, 13, 0, 0)).?);
    // `*/1` is restricted: the OR rule applies.
    const step = try CronExpr.parse("0 0 */1 * 5");
    try testing.expect(step.matchesDate(2026, 11, 14, zone.weekday(2026, 11, 14)));
}

test "never_matching_returns_null" {
    const c = try CronExpr.parse("0 0 30 2 *");
    try testing.expectEqual(@as(?LocalDateTime, null), c.nextLocal(ldt(2026, 1, 1, 0, 0)));
    try testing.expectEqual(@as(?i64, null), c.next(zone.utcZone(), 0));
    // 29 February is found across non-leap years.
    const leap = try CronExpr.parse("0 0 29 2 *");
    try testing.expectEqual(ldt(2028, 2, 29, 0, 0), leap.nextLocal(ldt(2025, 3, 1, 0, 0)).?);
    // Near the end of the representable range.
    try testing.expectEqual(@as(?LocalDateTime, null), (try CronExpr.parse("0 0 1 1 *")).nextLocal(ldt(9999, 6, 1, 0, 0)));
}

/// Minute by minute, up to five years.
fn bruteNext(c: *const CronExpr, after: LocalDateTime) ?LocalDateTime {
    var t = @divFloor(after.toUnixUtc(), 60) * 60 + 60;
    const end_year = after.year + cron.max_years;
    while (true) : (t += 60) {
        const l = LocalDateTime.fromUnixUtc(t);
        if (l.year > end_year) return null;
        if (c.minutes & (@as(u64, 1) << l.minute) == 0) continue;
        if (c.hours & (@as(u32, 1) << l.hour) == 0) continue;
        if (c.matchesDate(l.year, l.month, l.day, zone.weekday(l.year, l.month, l.day))) return l;
    }
}

fn randomField(r: std.Random, buf: []u8, lo: u8, hi: u8, names: ?[]const []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const items = 1 + r.uintLessThan(u8, 3);
    for (0..items) |i| {
        if (i > 0) w.writeByte(',') catch unreachable;
        switch (r.uintLessThan(u8, 6)) {
            0 => w.writeAll("*") catch unreachable,
            1 => w.print("*/{d}", .{1 + r.uintLessThan(u8, hi - lo + 1)}) catch unreachable,
            2 => {
                const a = r.intRangeAtMost(u8, lo, hi);
                const b = r.intRangeAtMost(u8, a, hi);
                w.print("{d}-{d}", .{ a, b }) catch unreachable;
                if (r.boolean()) w.print("/{d}", .{1 + r.uintLessThan(u8, 7)}) catch unreachable;
            },
            3 => if (names) |n| {
                w.writeAll(n[r.uintLessThan(usize, n.len)]) catch unreachable;
            } else w.print("{d}", .{r.intRangeAtMost(u8, lo, hi)}) catch unreachable,
            else => w.print("{d}", .{r.intRangeAtMost(u8, lo, hi)}) catch unreachable,
        }
    }
    return w.buffered();
}

test "next_matches_bruteforce" {
    var prng: std.Random.DefaultPrng = .init(0x5eed_c0de);
    const r = prng.random();
    const months = [_][]const u8{ "jan", "FEB", "Mar", "dec" };
    const days = [_][]const u8{ "sun", "MON", "fri", "Sat" };
    const zones = [_]zone.FixedZone{ .{ .offset_s = 0 }, .{ .offset_s = 5 * 3600 + 1800 }, .{ .offset_s = -(5 * 3600 + 1800) } };
    var bufs: [5][48]u8 = undefined;
    var line: [256]u8 = undefined;
    var cases: u32 = 0;
    while (cases < 2000) : (cases += 1) {
        // Mostly broad fields so brute force stays quick; a few sparse ones.
        const fields = [_][]const u8{
            randomField(r, &bufs[0], 0, 59, null),
            randomField(r, &bufs[1], 0, 23, null),
            if (r.uintLessThan(u8, 3) == 0) randomField(r, &bufs[2], 1, 31, null) else "*",
            if (r.uintLessThan(u8, 3) == 0) randomField(r, &bufs[3], 1, 12, &months) else "*",
            if (r.uintLessThan(u8, 3) == 0) randomField(r, &bufs[4], 0, 7, &days) else "*",
        };
        const expr = try std.fmt.bufPrint(&line, "{s} {s} {s} {s} {s}", .{ fields[0], fields[1], fields[2], fields[3], fields[4] });
        const c = CronExpr.parse(expr) catch |e| {
            // Random ranges never invert; names may (fri-sun is not built).
            std.debug.print("expr \"{s}\": {t}\n", .{ expr, e });
            return e;
        };
        // 2000-01-01 .. ~2040.
        const after_s: i64 = 946_684_800 + @as(i64, r.uintLessThan(u32, 40 * 365 * 86_400));
        const z = &zones[cases % zones.len];
        const zr = z.resolver();
        const after = zr.toLocal(zr.ctx, after_s);
        const want = bruteNext(&c, after);
        const got = c.nextLocal(after);
        testing.expectEqual(want, got) catch |e| {
            std.debug.print("expr \"{s}\" after {f}\n", .{ expr, after });
            return e;
        };
        if (got) |g| {
            const inst = c.next(zr, after_s).?;
            try testing.expect(inst > after_s);
            try testing.expectEqual(g.toUnixUtc() - z.offset_s, inst);
        }
    }
}

/// Clocks forward 02:00 -> 03:00 on 2026-03-08, back 02:00 -> 01:00 on
/// 2026-11-01 (local wall times; UTC-5 standard, UTC-4 summer).
const FakeDst = struct {
    const spring = ldt(2026, 3, 8, 2, 0);
    const fall = ldt(2026, 11, 1, 1, 0);

    fn resolver() zone.ZoneResolver {
        return .{ .ctx = &spring, .fromLocal = fromLocal, .toLocal = toLocal };
    }

    fn offsetAt(unix_s: i64) i64 {
        // Summer from 2026-03-08 07:00Z to 2026-11-01 06:00Z.
        const start = spring.toUnixUtc() + 5 * 3600;
        const end = ldt(2026, 11, 1, 2, 0).toUnixUtc() + 4 * 3600;
        return if (unix_s >= start and unix_s < end) -4 * 3600 else -5 * 3600;
    }

    fn fromLocal(_: *const anyopaque, l: LocalDateTime) zone.Resolved {
        const w = l.toUnixUtc();
        const as_std = w + 5 * 3600;
        const as_dst = w + 4 * 3600;
        const std_ok = offsetAt(as_std) == -5 * 3600;
        const dst_ok = offsetAt(as_dst) == -4 * 3600;
        if (std_ok and dst_ok) return .{ .ambiguous = .{ @min(as_std, as_dst), @max(as_std, as_dst) } };
        if (std_ok) return .{ .unique = as_std };
        if (dst_ok) return .{ .unique = as_dst };
        // In the gap: the first valid instant is the transition.
        return .{ .gap = spring.toUnixUtc() + 5 * 3600 };
    }

    fn toLocal(_: *const anyopaque, unix_s: i64) LocalDateTime {
        return .fromUnixUtc(unix_s + offsetAt(unix_s));
    }
};

test "gap_and_overlap_with_fake_resolver" {
    const z = FakeDst.resolver();
    // 02:30 does not exist on 8 March: it fires at 03:00 local (07:00Z).
    const c = try CronExpr.parse("30 2 * * *");
    const before_spring = ldt(2026, 3, 8, 0, 0).toUnixUtc() + 5 * 3600;
    const gap_fire = c.next(z, before_spring).?;
    try testing.expectEqual(ldt(2026, 3, 8, 7, 0).toUnixUtc(), gap_fire);
    // The next one is the regular 02:30 the day after (summer time).
    try testing.expectEqual(ldt(2026, 3, 9, 6, 30).toUnixUtc(), c.next(z, gap_fire).?);
    // 01:30 occurs twice on 1 November: fires once, at the earlier one.
    const o = try CronExpr.parse("30 1 * * *");
    const before_fall = ldt(2026, 11, 1, 0, 0).toUnixUtc() + 4 * 3600;
    const first = o.next(z, before_fall).?;
    try testing.expectEqual(ldt(2026, 11, 1, 5, 30).toUnixUtc(), first);
    const second = o.next(z, first).?;
    try testing.expectEqual(ldt(2026, 11, 2, 6, 30).toUnixUtc(), second);
    // From inside the repeated hour (after the first 01:30): not again.
    try testing.expectEqual(second, o.next(z, first + 3600).?);
    // Every minute through the gap: never at or before `after`.
    const every = try CronExpr.parse("* * * * *");
    var t = before_spring + 3600 + 59 * 60;
    for (0..5) |_| {
        const n = every.next(z, t).?;
        try testing.expect(n > t);
        t = n;
    }
    try testing.expectEqual(ldt(2026, 3, 8, 7, 4).toUnixUtc(), t);
}

test "fuzz: cron parse" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var raw: [64]u8 = undefined;
            const n = s.slice(&raw);
            const c = CronExpr.parse(raw[0..n]) catch return;
            const after = ldt(2026, 1, 1, 0, 0);
            if (c.nextLocal(after)) |l| try testing.expect(l.order(after) == .gt);
            var buf: [512]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            @import("describe.zig").describe(&c, &w) catch {};
        }
    }.one, .{});
}
